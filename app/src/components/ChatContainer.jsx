import React, { useState, useRef, useEffect, useCallback, useSyncExternalStore } from 'react';
import { MessageList } from './MessageList.jsx';
import { InputBar } from './InputBar.jsx';
import { VoiceBar } from './VoiceBar.jsx';
import { LogoIcon } from '../assets/logo.jsx';
import { CrabIcon } from '../assets/crab.jsx';
import { useKaraokePlayer, unlockAudioContext } from '../hooks/useKaraoke.js';
import { isVoiceEnabled, subscribe as subscribeVoice, getSnapshot as getVoiceSnapshot } from '../state/voice.js';
import { getVoice, getSpeed } from '../state/settings.js';

/**
 * ChatContainer — scrollable message list with input bar.
 */
export function ChatContainer({ session, effortLevel }) {
  const sub = useCallback((fn) => session.subscribe(fn), [session]);
  const messages = useSyncExternalStore(sub, () => session.messages);
  const busy = useSyncExternalStore(sub, () => session.busy);
  const error = useSyncExternalStore(sub, () => session.error);
  const messagesContainerRef = useRef(null);
  const prevMsgCount = useRef(0);
  const userAtBottom = useRef(true);
  const prevSessionRef = useRef(session);
  const {
    play: karaokePlay,
    stop: karaokeStop,
    pause: karaokePause,
    resume: karaokeResume,
    replay: karaokeReplay,
  } = useKaraokePlayer();
  const lastSpokenMsgRef = useRef(null);
  const voice = useSyncExternalStore(subscribeVoice, getVoiceSnapshot);

  // Reset scroll state when switching sessions
  useEffect(() => {
    if (prevSessionRef.current !== session) {
      prevSessionRef.current = session;
      prevMsgCount.current = 0;
      userAtBottom.current = true;
      const el = messagesContainerRef.current;
      if (el) el.scrollTop = el.scrollHeight;
    }
  }, [session]);

  // Track if user is scrolled to bottom
  const handleScroll = useCallback(() => {
    const el = messagesContainerRef.current;
    if (!el) return;
    userAtBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 50;
  }, []);

  // Auto-scroll on new messages, only if user is at bottom
  React.useLayoutEffect(() => {
    const el = messagesContainerRef.current;
    if (!el) return;
    const isFirstMessage = prevMsgCount.current === 0 && messages.length > 0;
    prevMsgCount.current = messages.length;
    if (isFirstMessage) {
      el.scrollTop = el.scrollHeight;
      userAtBottom.current = true;
      return;
    }
    if (userAtBottom.current) {
      el.scrollTop = el.scrollHeight;
    }
  }, [messages]);

  const handleSubmit = useCallback(
    (text, attachments) => {
      if (!text?.trim() && !attachments?.length) return;
      session.send(text?.trim() || '', attachments);
    },
    [session],
  );

  const handleInterrupt = useCallback(() => {
    session.interrupt();
  }, [session]);

  // TTS auto-play: fire when agent finishes a response (busy flips false)
  const prevBusyRef = useRef(busy);
  useEffect(() => {
    const wasJustBusy = prevBusyRef.current && !busy;
    prevBusyRef.current = busy;
    if (!wasJustBusy) return;
    if (!isVoiceEnabled()) return;

    // Find the last assistant text message
    const lastAssistant = [...messages]
      .reverse()
      .find((m) => m.type === 'assistant' && m.content?.some((b) => b.content?.type === 'text' || b.type === 'text'));
    if (!lastAssistant) return;

    // Don't re-speak the same message
    const msgId = lastAssistant._uuid;
    if (msgId && msgId === lastSpokenMsgRef.current) return;
    lastSpokenMsgRef.current = msgId;

    // Extract text
    const text = (lastAssistant.content || [])
      .map((b) => (b.content?.type === 'text' ? b.content.text : b.type === 'text' ? b.text : ''))
      .join('\n')
      .trim();
    if (!text) return;

    fetch('/api/tts-captioned', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, voice: getVoice(), speed: getSpeed() }),
    })
      .then((r) => r.json())
      .then(({ audio_b64, words }) => {
        if (!isVoiceEnabled()) return; // user may have toggled off while fetching
        karaokePlay(audio_b64, words, msgId);
      })
      .catch((e) => console.error('[voice] TTS error:', e));
  }, [busy, messages, karaokePlay]);

  // Stop audio when session changes
  useEffect(() => {
    karaokeStop();
    lastSpokenMsgRef.current = null;
  }, [session, karaokeStop]);

  const handlePlayMessage = useCallback(
    (msgId, text) => {
      unlockAudioContext();
      return fetch('/api/tts-captioned', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text, voice: getVoice(), speed: getSpeed() }),
      })
        .then((r) => r.json())
        .then(({ audio_b64, words }) => karaokePlay(audio_b64, words, msgId))
        .catch((e) => console.error('[voice] TTS error:', e));
    },
    [karaokePlay],
  );

  // Global Escape to interrupt current response
  useEffect(() => {
    const handler = (e) => {
      if (e.key === 'Escape' && busy) {
        e.preventDefault();
        session.interrupt();
      }
    };
    document.body.addEventListener('keydown', handler);
    return () => document.body.removeEventListener('keydown', handler);
  }, [busy, session]);

  return (
    <div className="chatContainer">
      {/* Messages container — always present for scroll behavior */}
      <div className="messagesContainer stickyMode" ref={messagesContainerRef} onScroll={handleScroll}>
        {messages.length === 0 && !busy ? (
          <div className="emptyState">
            <div className="welcomeContainer">
              <div className="welcomeLogo">
                <div>
                  <LogoIcon />
                </div>
              </div>
              <div className="welcomeMain">
                <div className="hintContainer">
                  <CrabIcon />
                  <div className="hintMessageContainer">
                    <div className="hintMessage">
                      What would you like to do? Ask about the codebase or start writing code.
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        ) : (
          <>
            <MessageList messages={messages} busy={busy} onPlayMessage={handlePlayMessage} />
          </>
        )}
      </div>

      {/* Gradient overlay */}
      <div className="messageGradient" />

      {/* Error */}
      {error && (
        <div className="errorBanner">
          <div className="errorMessage">{error}</div>
          <button
            className="errorDismiss"
            onClick={() => {
              session.error = null;
              session.notify();
            }}
          >
            Dismiss
          </button>
        </div>
      )}

      {/* Input */}
      <div className="inputContainer">
        {voice.enabled ? (
          <VoiceBar
            onSubmit={handleSubmit}
            onInterrupt={handleInterrupt}
            busy={busy}
            stop={karaokeStop}
            pause={karaokePause}
            resume={karaokeResume}
            replay={karaokeReplay}
          />
        ) : (
          <InputBar
            onSubmit={handleSubmit}
            onInterrupt={handleInterrupt}
            busy={busy}
            session={session}
            effortLevel={effortLevel}
          />
        )}
      </div>
    </div>
  );
}
