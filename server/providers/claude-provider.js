/**
 * Claude Agent SDK provider.
 *
 * Uses the Claude Agent SDK query stream and translates SDK messages
 * into normalized E.* internal events.
 *
 * All events go through the same translation layer as other providers.
 * No _raw passthrough.
 */

import { E } from './events.js';
import { ClaudeSessionRuntime } from './claude-session-runtime.js';

export class ClaudeProvider {
  constructor(options = {}) {
    this.name = 'claude';
    this.SessionRuntime = options.sessionRuntimeClass || ClaudeSessionRuntime;
  }

  async connect(config = {}) {
    const runtime = new this.SessionRuntime(this, config);
    return await runtime.start();
  }

  send(conn, message) {
    conn._runtime?.send(message);
  }

  onEvent(conn, callback) {
    conn.listeners.add(callback);
    return () => conn.listeners.delete(callback);
  }

  respondPermission(conn, requestId, allowed) {
    conn._runtime?.respondPermission(requestId, allowed);
  }

  interrupt(conn) {
    conn._runtime?.interrupt();
  }

  close(conn) {
    conn._runtime?.close();
  }

  setThinkingLevel(conn, level) {
    return conn._runtime?.setThinkingLevel(level);
  }

  setPermissionMode(conn, mode) {
    return conn._runtime?.setPermissionMode(mode);
  }

  // ── Internal ──

  _emit(conn, event) {
    for (const fn of conn.listeners) fn(event);
  }

  _emitRaw(conn, event) {
    this._emit(conn, E.rawEvent(event));
  }

  _handleEvent(conn, parsed) {
    switch (parsed.type) {
      case 'system':
        if (parsed.subtype === 'init' && parsed.session_id) {
          conn.sessionId = parsed.session_id;
          this._emit(conn, E.sessionReady(parsed.session_id));
        }
        break;

      case 'stream_event':
        this._handleStreamEvent(conn, parsed.event);
        break;

      case 'assistant':
        // Final assembled message — skip (already streamed via stream_event deltas)
        break;

      case 'user':
        // Tool results from Claude's internal tool loop
        if (parsed.message?.content) {
          for (const block of parsed.message.content) {
            if (block.type === 'tool_result') {
              const text =
                typeof block.content === 'string'
                  ? block.content
                  : Array.isArray(block.content)
                    ? block.content.map((c) => c.text || '').join('')
                    : '';
              this._emit(conn, E.toolResult(block.tool_use_id, text, block.is_error || false));
            }
          }
        }
        break;

      case 'result': {
        const u = parsed.usage;
        if (u) {
          const contextUsed =
            (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
          this._emit(
            conn,
            E.usageUpdate({
              inputTokens: u.input_tokens,
              outputTokens: u.output_tokens,
              cacheRead: u.cache_read_input_tokens,
              cacheWrite: u.cache_creation_input_tokens,
              totalTokens: contextUsed,
            }),
          );
        }
        // Detect errors: explicit subtype, is_error flag, or API error status
        const isError = parsed.subtype === 'error' || parsed.is_error || parsed.api_error_status;
        if (isError) {
          const errMsg =
            parsed.error ||
            (Array.isArray(parsed.errors) && parsed.errors.length > 0 ? parsed.errors.join('; ') : null) ||
            (typeof parsed.result === 'string' && parsed.result ? parsed.result : null) ||
            (parsed.api_error_status ? `API error (HTTP ${parsed.api_error_status})` : null) ||
            'Unknown error';
          this._emit(conn, E.turnError(errMsg));
        } else {
          this._emit(
            conn,
            E.turnComplete(u ? { inputTokens: u.input_tokens, outputTokens: u.output_tokens } : undefined),
          );
        }
        break;
      }

      case 'rate_limit_event': {
        const rli = parsed.rate_limit_info || {};
        this._emit(
          conn,
          E.usageUpdate({
            fiveHour: rli.status ? { status: rli.status, resetsAt: rli.resetsAt } : undefined,
          }),
        );
        break;
      }

      case 'control_request':
        if (parsed.request?.subtype === 'can_use_tool') {
          this._emit(
            conn,
            E.permissionRequest(parsed.request_id, parsed.request.tool_name, parsed.request.input || {}),
          );
        }
        break;

      case 'control_response':
      case 'keep_alive':
        break;
    }
  }

  _handleStreamEvent(conn, ev) {
    if (!ev?.type) return;

    switch (ev.type) {
      case 'message_start':
        this._emit(conn, E.turnStart());
        break;

      case 'content_block_start': {
        const block = ev.content_block;
        if (!block) break;
        if (block.type === 'tool_use') {
          conn._currentToolId = block.id;
          this._emit(conn, E.toolStart(block.id, block.name, block.input || {}));
        } else if (block.type === 'thinking') {
          conn._thinkingBlockOpen = true;
          console.log(`[claude-prov] thinking block START`);
          this._emit(conn, E.thinkingDelta(''));
        } else if (block.type === 'text') {
          conn._textBlockOpen = true;
        }
        break;
      }

      case 'content_block_delta': {
        const delta = ev.delta;
        if (!delta) break;
        if (delta.type === 'text_delta' && delta.text) {
          this._emit(conn, E.textDelta(delta.text));
        } else if (delta.type === 'thinking_delta' && delta.thinking) {
          console.log(`[claude-prov] thinking_delta len=${delta.thinking.length}`);
          this._emit(conn, E.thinkingDelta(delta.thinking));
        } else if (delta.type === 'input_json_delta' && delta.partial_json && conn._currentToolId) {
          this._emit(conn, E.toolInputDelta(conn._currentToolId, delta.partial_json));
        }
        break;
      }

      case 'content_block_stop':
        if (conn._textBlockOpen) {
          this._emit(conn, E.textDone(''));
          conn._textBlockOpen = false;
        }
        if (conn._thinkingBlockOpen) {
          this._emit(conn, E.thinkingDone(''));
          conn._thinkingBlockOpen = false;
        }
        if (conn._currentToolId) {
          conn._currentToolId = null;
        }
        break;

      case 'message_delta':
        // Contains stop_reason and usage — handled at result level
        break;

      case 'message_stop':
        // End of streaming — turnComplete comes from result event
        break;
    }
  }
}
