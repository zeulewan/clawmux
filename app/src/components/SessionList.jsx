import React, { useState, useEffect, useCallback, useRef } from 'react';
import { resumeSession, getSessions, activateSession } from '../state/sessions.js';
import { listSessions as listSessionsRPC } from '../lib/protocol.js';

export function SessionList({ onClose }) {
  const [savedSessions, setSavedSessions] = useState([]);
  const [search, setSearch] = useState('');
  const [loading, setLoading] = useState(true);
  const [focusedIdx, setFocusedIdx] = useState(0);
  const ref = useRef(null);

  useEffect(() => {
    listSessionsRPC().then((saved) => {
      setSavedSessions(saved || []);
      setLoading(false);
    });
  }, []);

  useEffect(() => {
    const handler = (e) => {
      if (ref.current && !ref.current.contains(e.target)) onClose();
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [onClose]);

  useEffect(() => {
    const handler = (e) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [onClose]);

  // Merge in-memory sessions with saved ones
  const inMemory = getSessions();
  const allSessions = [
    ...inMemory.map((s) => ({
      id: s.conversationId || s.sessionId || s.channelId,
      summary: s.summary || 'New conversation',
      lastModified: s.lastModified || Date.now(),
      session: s,
    })),
    ...savedSessions
      .filter((s) => !inMemory.some((m) => m.sessionId === s.id))
      .map((s) => ({ id: s.id, summary: s.summary || 'Untitled', lastModified: s.lastModified, session: null })),
  ].sort((a, b) => b.lastModified - a.lastModified);

  const filtered = search
    ? allSessions.filter((s) => (s.summary || '').toLowerCase().includes(search.toLowerCase()))
    : allSessions;

  const handleSelect = useCallback(
    (item) => {
      if (item.session) {
        activateSession(item.session);
      } else {
        resumeSession(item.id, item.summary);
      }
      onClose();
    },
    [onClose],
  );

  function timeAgo(ts) {
    if (!ts) return '';
    const diff = Date.now() - ts;
    if (diff < 60000) return 'now';
    if (diff < 3600000) return Math.floor(diff / 60000) + 'm';
    if (diff < 86400000) return Math.floor(diff / 3600000) + 'h';
    return Math.floor(diff / 86400000) + 'd';
  }

  return (
    <div
      ref={ref}
      className="dropdown_Wc_2Bg"
      tabIndex={-1}
      style={{ position: 'absolute', top: 38, right: 38, zIndex: 100 }}
    >
      <div className="sessionListRoot">
        <div className="searchRow">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
            aria-hidden="true"
            className="searchIcon"
          >
            <path
              fillRule="evenodd"
              d="M9.965 11.026a5 5 0 1 1 1.06-1.06l2.755 2.754a.75.75 0 1 1-1.06 1.06l-2.755-2.754ZM10.5 7a3.5 3.5 0 1 1-7 0 3.5 3.5 0 0 1 7 0Z"
              clipRule="evenodd"
            />
          </svg>
          <input
            placeholder="Search sessions…"
            className="filterInput searchInput"
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            autoFocus
          />
        </div>
        <div className="sessionContent">
          <div className="sessionsList">
            {loading && allSessions.length === 0 ? (
              <div style={{ padding: 12, opacity: 0.5 }}>Loading...</div>
            ) : filtered.length === 0 ? (
              <div style={{ padding: 12, opacity: 0.5 }}>{search ? 'No matches' : 'No sessions'}</div>
            ) : (
              filtered.map((item, i) => (
                <button
                  key={item.id}
                  className={`sessionItem ${i === focusedIdx ? 'focused' : ''} ${item.session === inMemory[0] ? 'active' : ''}`}
                  onClick={() => handleSelect(item)}
                  onMouseEnter={() => setFocusedIdx(i)}
                >
                  <span className="sessionName">{item.summary}</span>
                  <span className="sessionMeta">
                    <span className="sessionTime">{timeAgo(item.lastModified)}</span>
                  </span>
                </button>
              ))
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
