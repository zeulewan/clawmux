import React, { useState, useRef, useEffect, useCallback, useSyncExternalStore } from 'react';
import { MessageList } from './MessageList.jsx';
import { InputBar } from './InputBar.jsx';
import { LogoIcon } from '../assets/logo.jsx';
import { CrabIcon } from '../assets/crab.jsx';

/**
 * ChatContainer — scrollable message list with input bar.
 */
export function ChatContainer({ session }) {
  const sub = useCallback((fn) => session.subscribe(fn), [session]);
  const messages = useSyncExternalStore(sub, () => session.messages);
  const busy = useSyncExternalStore(sub, () => session.busy);
  const error = useSyncExternalStore(sub, () => session.error);
  const messagesContainerRef = useRef(null);
  const prevMsgCount = useRef(0);
  const userAtBottom = useRef(true);
  const prevSessionRef = useRef(session);

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
      <div className="messagesContainer" ref={messagesContainerRef} onScroll={handleScroll}>
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
            <MessageList messages={messages} busy={busy} />
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
        <InputBar onSubmit={handleSubmit} onInterrupt={handleInterrupt} busy={busy} session={session} />
      </div>
    </div>
  );
}
