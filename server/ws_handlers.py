"""WebSocket handlers — browser connection and wait-for-message WS.

Contains the browser WebSocket (multiplexes audio, text, interjections)
and the wait WebSocket (push-based inbox delivery for CLI agents).
"""

import asyncio
import base64
import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

import inbox
from state_machine import AgentState
from voice import tts, tts_captioned, stt, strip_non_speakable
from hub_state import (
    session_mgr, history, send_to_browser, _flush_browser_queue,
    _session_status_msg, _save_activity, _load_settings,
    browser_clients, _gen_msg_id, _hist_prefix, _active_model_id,
)
from message_injection import inbox_write_and_notify

log = logging.getLogger("hub.ws")
router = APIRouter()


# ── Browser WebSocket ─────────────────────────────────────────────────────────

@router.websocket("/ws")
async def browser_websocket(ws: WebSocket):
    await ws.accept()
    browser_clients.add(ws)
    log.info("Client connected (%d total)", len(browser_clients))

    try:
        await ws.send_json({
            "type": "session_list",
            "sessions": session_mgr.list_sessions(),
        })
        await _flush_browser_queue(ws)

        while True:
            data = await ws.receive_json()
            await handle_browser_message(data)
    except WebSocketDisconnect:
        log.info("Client disconnected")
    except Exception as e:
        log.error("Client WS error: %s: %s", type(e).__name__, e)
    finally:
        browser_clients.discard(ws)
        log.info("Clients remaining: %d", len(browser_clients))
        if not browser_clients:
            for session in session_mgr.sessions.values():
                if session.playback_done:
                    session.playback_done.set()


async def handle_browser_message(data: dict) -> None:
    """Route browser messages to the correct session."""
    session_id = data.get("session_id")
    msg_type = data.get("type")

    if not session_id:
        log.warning("Browser message without session_id: %s", msg_type)
        return

    session = session_mgr.sessions.get(session_id)
    if not session:
        log.warning("Browser message for unknown session: %s", session_id)
        return

    session.touch()

    if msg_type == "playback_done":
        log.info("[%s] playback_done from browser", session_id)
        session.playback_done.set()

    elif msg_type == "audio":
        payload = data.get("data", "")
        if not payload:
            log.info("[%s] Empty audio from browser, skipping", session_id)
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})
            return
        audio_bytes = base64.b64decode(payload)
        log.info("[%s] Audio from browser: %d bytes", session_id, len(audio_bytes))
        if not _load_settings().get("stt_enabled", True):
            log.info("[%s] STT disabled, skipping transcription", session_id)
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})
            return
        await send_to_browser({"session_id": session_id, "type": "status", "text": "Transcribing..."})
        text = await stt(audio_bytes)
        if text:
            log.info("[%s] Audio STT: %s", session_id, text[:100])
            umid = _gen_msg_id()
            await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "msg_id": umid})
            await asyncio.to_thread(history.append, session.voice, session.label, "user", text, _hist_prefix(session), msg_id=umid, model_id=_active_model_id(session))
            if session.work_dir:
                await inbox_write_and_notify(session, {
                    "id": umid,
                    "from": "user",
                    "type": "voice",
                    "content": text,
                })
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})
        else:
            log.info("[%s] Audio STT: empty result", session_id)
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})

    elif msg_type == "text":
        text = data.get("text", "").strip()
        if text:
            log.info("[%s] Text from browser: %s", session_id, text[:100])
            umid = _gen_msg_id()
            await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "msg_id": umid})
            await asyncio.to_thread(history.append, session.voice, session.label, "user", text, _hist_prefix(session), msg_id=umid, model_id=_active_model_id(session))
            if session.work_dir:
                await inbox_write_and_notify(session, {
                    "id": umid,
                    "from": "user",
                    "type": "text",
                    "content": text,
                })
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})

    elif msg_type == "interjection":
        payload = data.get("data", "")
        text = data.get("text", "").strip()
        if text:
            log.info("[%s] Text interjection: %s", session_id, text[:100])
        elif payload:
            audio_bytes = base64.b64decode(payload)
            log.info("[%s] Audio interjection: %d bytes, transcribing...", session_id, len(audio_bytes))
            if not _load_settings().get("stt_enabled", True):
                log.info("[%s] STT disabled, skipping interjection transcription", session_id)
                return
            await send_to_browser({"session_id": session_id, "type": "status", "text": "Transcribing..."})
            text = await stt(audio_bytes)
            log.info("[%s] Interjection STT: %s", session_id, text[:100] if text else "(empty)")
        if text:
            session.interjections.append(text)
            umid = _gen_msg_id()
            await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "interjection": True, "msg_id": umid})
            await asyncio.to_thread(history.save_interjections, session.voice, session.interjections, _hist_prefix(session))
            await asyncio.to_thread(history.append, session.voice, session.label, "user", text, _hist_prefix(session), msg_id=umid, model_id=_active_model_id(session))

            if session.state == AgentState.IDLE and session.work_dir:
                log.info("[%s] Agent in wait, pushing voice message via inbox", session_id)
                combined = " ... ".join(session.interjections)
                session.interjections.clear()
                await asyncio.to_thread(history.clear_interjections, session.voice, _hist_prefix(session))
                await inbox_write_and_notify(session, {
                    "id": umid,
                    "from": "user",
                    "type": "voice",
                    "content": combined,
                })
            elif session.work_dir:
                await inbox_write_and_notify(session, {
                    "id": umid,
                    "from": "user",
                    "type": "voice",
                    "content": text,
                })
                log.info("[%s] Voice interjection written to inbox for hook delivery", session_id)
                await send_to_browser({"session_id": session_id, "type": "done", "processing": False})

    elif msg_type == "set_mode":
        mode = data.get("mode", "voice")
        session.text_mode = (mode == "text")
        log.info("[%s] Mode set to %s", session_id, mode)

    elif msg_type == "set_model":
        model = data.get("model", "")
        if model in ("opus", "sonnet", "haiku", ""):
            session.model = model
            log.info("[%s] Model set to %s", session_id, model or "(global default)")

    elif msg_type == "restart_model":
        backend = session_mgr._get_backend(session.backend)
        if not backend.supports_model_restart:
            log.warning("[%s] restart_model ignored for backend %s", session_id, session.backend)
        else:
            model = data.get("model", "")
            if model:
                if model in ("opus", "sonnet", "haiku"):
                    session.model = model
                else:
                    session.model_id = model
                log.info("[%s] Model restart requested: %s", session_id, model)
                asyncio.create_task(session_mgr.restart_claude_with_model(session_id))

    elif msg_type == "restart_effort":
        backend = session_mgr._get_backend(session.backend)
        if not backend.supports_effort:
            log.warning("[%s] restart_effort ignored for backend %s", session_id, session.backend)
        else:
            effort = data.get("effort", "")
            if effort in ("minimal", "low", "medium", "high", "max", "xhigh"):
                session.effort = effort
                log.info("[%s] Effort restart requested: %s", session_id, effort)
                asyncio.create_task(session_mgr.restart_claude_with_model(session_id))

    elif msg_type == "user_ack":
        msg_id = data.get("msg_id", "")
        if msg_id:
            ack_id = _gen_msg_id()
            log.info("[%s] User ack on %s", session_id, msg_id)
            await asyncio.to_thread(history.append, session.voice, session.label, "user", "",
                           _hist_prefix(session), msg_id=ack_id,
                           parent_id=msg_id, bare_ack=True)
            await send_to_browser({
                "session_id": session_id,
                "type": "user_ack",
                "msg_id": msg_id,
                "ack_id": ack_id,
            })
            if session.work_dir:
                await inbox_write_and_notify(session, {
                    "from": "user",
                    "type": "ack",
                    "content": "",
                    "parent_id": msg_id,
                })


# ── Wait WebSocket ────────────────────────────────────────────────────────────

@router.websocket("/ws/wait/{session_id}")
async def wait_websocket(ws: WebSocket, session_id: str):
    """Push-based inbox delivery. CLI connects, blocks until a message arrives."""
    await ws.accept()
    session = session_mgr.sessions.get(session_id)
    if not session:
        await ws.close(code=4004, reason="Session not found")
        return

    log.info("[%s] Wait WS connected", session_id)
    session.activity = ""
    session.tool_name = ""
    session.tool_input = {}
    session.set_state(AgentState.IDLE)
    await _save_activity(session, "Idle")

    await send_to_browser({"session_id": session_id, "type": "listening", "state": "idle"})
    await send_to_browser(_session_status_msg(session))

    if not hasattr(session, "_wait_queue"):
        session._wait_queue = asyncio.Queue()

    try:
        if session.work_dir:
            messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
            if messages:
                await ws.send_json({"type": "messages", "messages": messages})
                await send_to_browser({
                    "type": "inbox_update",
                    "session_id": session_id,
                    "count": 0,
                })
                return

        while True:
            try:
                msg = await asyncio.wait_for(session._wait_queue.get(), timeout=5)
                if session.work_dir:
                    await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
                await ws.send_json({"type": "messages", "messages": [msg]})
                return
            except asyncio.TimeoutError:
                if session.work_dir:
                    messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
                    if messages:
                        await ws.send_json({"type": "messages", "messages": messages})
                        await send_to_browser({
                            "type": "inbox_update",
                            "session_id": session_id,
                            "count": 0,
                        })
                        return
                try:
                    await ws.send_json({"type": "ping"})
                except Exception:
                    break
    except WebSocketDisconnect:
        log.info("[%s] Wait WS disconnected", session_id)
    except Exception as e:
        log.warning("[%s] Wait WS error: %s", session_id, e)
    finally:
        session.activity = ""
        session.tool_name = ""
        session.tool_input = {}
        session.set_state(AgentState.PROCESSING)
        await _save_activity(session, "Processing")
        await send_to_browser(_session_status_msg(session))
        if hasattr(session, "_wait_queue"):
            del session._wait_queue
