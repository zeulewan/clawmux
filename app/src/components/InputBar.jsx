import React, { useState, useRef, useCallback, useEffect, useSyncExternalStore } from 'react';
import { ModesMenu, MODES } from './ModesMenu.jsx';
import { subscribe as subscribeVoice, getSnapshot as getVoiceSnapshot, isVoiceEnabled, setRecording } from '../state/voice.js';

const MODE_ICONS = {};
for (const m of MODES) MODE_ICONS[m.id] = m.icon;

function ModeIcon({ mode }) {
  const icon = MODE_ICONS[mode];
  if (!icon) return null;
  return (
    <svg width="1em" height="1em" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style={{ display: 'inline-block', verticalAlign: 'middle' }}>
      {icon}
    </svg>
  );
}

/**
 * InputBar — chat input with contenteditable, slash commands, and file attachments.
 * Uses <fieldset>, contenteditable div, and proper footer with add/menu/send buttons.
 * CSS classes: inputBarContainer, inputFooter, addButton, sendButton
 */
export function InputBar({ onSubmit, onInterrupt, busy, session, effortLevel: liveEffortLevel = 'medium' }) {
  const inputRef = useRef(null);
  const fileInputRef = useRef(null);
  const addButtonRef = useRef(null);
  const slashButtonRef = useRef(null);
  const modesButtonRef = useRef(null);
  const [text, setText] = useState('');
  const [showModesMenu, setShowModesMenu] = useState(false);
  const [showAddMenu, setShowAddMenu] = useState(false);
  const [showSlashMenu, setShowSlashMenu] = useState(false);
  const [addMenuPos, setAddMenuPos] = useState(null);
  const [slashMenuPos, setSlashMenuPos] = useState(null);
  const [modesMenuPos, setModesMenuPos] = useState(null);

  const calcPos = (ref, align = 'left') => {
    if (!ref.current) return null;
    const r = ref.current.getBoundingClientRect();
    const bottom = window.innerHeight - r.top + 4;
    if (align === 'right') {
      return { bottom, right: window.innerWidth - r.right, left: 'auto' };
    }
    return { bottom, left: Math.max(8, r.left) };
  };
  const [permissionMode, setPermissionMode] = useState('bypassPermissions');
  const [selectedEffortLevel, _setEffortLevel] = useState(liveEffortLevel);
  const setEffortLevel = useCallback((level) => {
    _setEffortLevel(level);
    if (session) {
      session.effortLevel = level;
      session.notify?.();
    }
    // Send to server so it's used on next turn
    import('../lib/protocol.js').then(({ request }) => {
      request('apply_settings', { settings: { effortLevel: level } }).catch(() => {});
    });
  }, [session]);
  useEffect(() => {
    _setEffortLevel(liveEffortLevel);
  }, [liveEffortLevel]);
  const [showModelPicker, setShowModelPicker] = useState(false);
  const [attachments, setAttachments] = useState([]);
  const [dragging, setDragging] = useState(false);
  const voice = useSyncExternalStore(subscribeVoice, getVoiceSnapshot);
  const mediaRecorderRef = useRef(null);
  const audioChunksRef = useRef([]);

  const handleFiles = useCallback((files) => {
    for (const file of files) {
      const reader = new FileReader();
      reader.onload = (e) => {
        const data = e.target.result;
        const isImage = file.type.startsWith('image/');
        setAttachments((prev) => [
          ...prev,
          {
            name: file.name,
            type: file.type,
            size: file.size,
            isImage,
            data, // base64 data URL
          },
        ]);
      };
      reader.readAsDataURL(file);
    }
  }, []);

  const handleDrop = useCallback(
    (e) => {
      e.preventDefault();
      e.stopPropagation();
      setDragging(false);
      if (e.dataTransfer?.files?.length) handleFiles(e.dataTransfer.files);
    },
    [handleFiles],
  );

  const handleDragOver = useCallback((e) => {
    e.preventDefault();
    e.stopPropagation();
    setDragging(true);
  }, []);

  const handleDragLeave = useCallback((e) => {
    e.preventDefault();
    setDragging(false);
  }, []);

  const removeAttachment = useCallback((idx) => {
    setAttachments((prev) => prev.filter((_, i) => i !== idx));
  }, []);

  const openFilePicker = useCallback(() => {
    setShowAddMenu(false);
    requestAnimationFrame(() => fileInputRef.current?.click());
  }, []);

  const handleSubmit = useCallback(() => {
    const currentText = inputRef.current?.textContent || text;
    if (!currentText.trim() && attachments.length === 0) return;

    onSubmit(currentText.trim(), attachments);
    if (inputRef.current) inputRef.current.textContent = '';
    setText('');
    setAttachments([]);
  }, [text, onSubmit, attachments]);

  const MODES = ['acceptEdits', 'auto', 'plan', 'bypassPermissions'];
  const MODE_LABELS = {
    acceptEdits: 'Ask before edits',
    auto: 'Edit automatically',
    plan: 'Plan mode',
    bypassPermissions: 'Bypass permissions',
  };

  const handleKeyDown = useCallback(
    (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        handleSubmit();
      }
      if (e.key === 'Escape' && busy) {
        e.preventDefault();
        onInterrupt();
        // If there's a pending message, it'll send once busy clears
      }
      // Shift+Tab cycles permission modes
      if (e.key === 'Tab' && e.shiftKey) {
        e.preventDefault();
        setPermissionMode((prev) => {
          const idx = MODES.indexOf(prev);
          return MODES[(idx + 1) % MODES.length];
        });
        setShowModesMenu(false);
        setShowAddMenu(false);
        setShowSlashMenu(false);
      }
    },
    [handleSubmit, busy, onInterrupt],
  );

  const handleInput = useCallback((e) => {
    setText(e.target.textContent || '');
  }, []);

  useEffect(() => {
    // Don't auto-focus on mobile — prevents keyboard popping up
    if (!busy && window.innerWidth >= 768) inputRef.current?.focus();
  }, [busy]);

  useEffect(() => {
    if (liveEffortLevel) _setEffortLevel(liveEffortLevel);
  }, [liveEffortLevel]);

  const startRecording = useCallback(async () => {
    if (voice.recording) return;
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const PREFERRED = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/mp4'];
      const mimeType = PREFERRED.find(t => MediaRecorder.isTypeSupported(t)) || '';
      const mr = new MediaRecorder(stream, mimeType ? { mimeType } : {});
      audioChunksRef.current = [];
      mr.ondataavailable = (e) => { if (e.data.size > 0) audioChunksRef.current.push(e.data); };
      mr.onstop = async () => {
        stream.getTracks().forEach(t => t.stop());
        setRecording(false);
        const blob = new Blob(audioChunksRef.current, { type: mr.mimeType || 'audio/webm' });
        const buf = await blob.arrayBuffer();
        try {
          const res = await fetch('/api/stt', { method: 'POST', body: buf, headers: { 'Content-Type': blob.type } });
          const { text } = await res.json();
          if (text && inputRef.current) {
            const prev = inputRef.current.textContent || '';
            inputRef.current.textContent = prev + (prev && !prev.endsWith(' ') ? ' ' : '') + text;
            setText(inputRef.current.textContent);
          }
        } catch (e) { console.error('[voice] STT error:', e); }
      };
      mr.start(250);
      mediaRecorderRef.current = mr;
      setRecording(true);
    } catch (e) { console.error('[voice] mic error:', e); }
  }, [voice.recording]);

  const stopRecording = useCallback(() => {
    mediaRecorderRef.current?.stop();
    mediaRecorderRef.current = null;
  }, []);

  // Close all popups on click outside
  useEffect(() => {
    const handler = () => {
      setShowAddMenu(false);
      setShowSlashMenu(false);
      setShowModesMenu(false);
      setShowModelPicker(false);
    };
    document.addEventListener('click', handler);
    return () => document.removeEventListener('click', handler);
  }, []);

  const placeholder = busy ? 'Processing…' : 'Type a message…';

  return (
    <fieldset
      className={`inputBarContainer ${dragging ? 'input-drag-active' : ''}`}
      data-permission-mode={permissionMode}
      onDrop={handleDrop}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
    >
      <input
        ref={fileInputRef}
        type="file"
        multiple
        tabIndex={-1}
        aria-hidden="true"
        style={{ display: 'none' }}
        onChange={(e) => {
          if (e.target.files?.length) handleFiles(e.target.files);
          e.target.value = '';
        }}
      />
      {dragging && <div className="drop-overlay">Drop files here</div>}
      <div className="inputContainerBackground" />
      {attachments.length > 0 && (
        <div className="attachment-preview">
          {attachments.map((a, i) => (
            <div key={i} className="attachment-item">
              {a.isImage ? (
                <img src={a.data} alt={a.name} className="attachment-thumb" />
              ) : (
                <span className="attachment-file">{a.name}</span>
              )}
              <button className="attachment-remove" onClick={() => removeAttachment(i)} title="Remove">
                x
              </button>
            </div>
          ))}
        </div>
      )}
      <div className="messageInputContainer">
        <div
          ref={inputRef}
          contentEditable="plaintext-only"
          className="messageInput"
          role="textbox"
          aria-label="Message input"
          aria-multiline="true"
          data-placeholder={placeholder}
          onKeyDown={handleKeyDown}
          onInput={handleInput}
          suppressContentEditableWarning
        />
        <div className="mentionMirror" aria-hidden="true" />
      </div>
      <div className="inputFooter inputFooterV2">
        {/* Add button */}
        <div className="addButtonContainer">
          {showAddMenu && addMenuPos && (
            <div
              className="menuPopup menuPopupV2"
              onClick={(e) => e.stopPropagation()}
              style={{ position: 'fixed', ...addMenuPos, zIndex: 1000 }}
            >
              <button type="button" className="menuItemV2" onClick={openFilePicker}>
                <span className="menuItemText">
                  <span className="menuItemLabel">Attach file</span>
                </span>
              </button>
              <button type="button" className="menuItemV2" onClick={() => setShowAddMenu(false)}>
                <span className="menuItemText">
                  <span className="menuItemLabel">@mention file</span>
                </span>
              </button>
            </div>
          )}
          <button
            ref={addButtonRef}
            type="button"
            className="addButton addButtonSquare"
            title="Add"
            onClick={(e) => {
              e.stopPropagation();
              setAddMenuPos(calcPos(addButtonRef, 'left'));
              setShowAddMenu(!showAddMenu);
              setShowSlashMenu(false);
              setShowModesMenu(false);
            }}
          >
            <svg
              width="20"
              height="20"
              viewBox="0 0 20 20"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
              style={{ display: 'block' }}
            >
              <path
                d="M10 5C10.2761 5 10.5 5.22386 10.5 5.5V9.5H14.5C14.7761 9.5 15 9.72386 15 10C15 10.2417 14.8286 10.4437 14.6006 10.4902L14.5 10.5H10.5V14.5C10.5 14.7761 10.2761 15 10 15C9.72386 15 9.5 14.7761 9.5 14.5V10.5H5.5L5.39941 10.4902C5.17145 10.4437 5 10.2417 5 10C5 9.75829 5.17145 9.55629 5.39941 9.50977L5.5 9.5H9.5V5.5C9.5 5.22386 9.72386 5 10 5Z"
                fill="currentColor"
              />
            </svg>
          </button>
        </div>
        {/* Slash command menu button */}
        <div>
          {showSlashMenu && slashMenuPos && (
            <div
              className="menuPopup menuPopupV2"
              onClick={(e) => e.stopPropagation()}
              style={{ position: 'fixed', ...slashMenuPos, zIndex: 1000 }}
            >
              <div className="menuHeader">
                <span className="menuHeaderTitle">Commands</span>
              </div>
              {/* Built-in commands */}
              <button
                type="button"
                className="menuItemV2"
                onClick={async () => {
                  setShowSlashMenu(false);
                  const { createNewSession } = await import('../state/sessions.js');
                  createNewSession();
                }}
              >
                <span className="menuItemText">
                  <span className="menuItemLabel">/new</span>
                  <span className="menuItemDescription">Start fresh conversation</span>
                </span>
              </button>
              <button
                type="button"
                className="menuItemV2"
                onClick={async () => {
                  setShowSlashMenu(false);
                  const { createNewSession } = await import('../state/sessions.js');
                  createNewSession();
                }}
              >
                <span className="menuItemText">
                  <span className="menuItemLabel">/clear</span>
                  <span className="menuItemDescription">Clear chat and start over</span>
                </span>
              </button>
              <button
                type="button"
                className="menuItemV2"
                onClick={() => {
                  setShowSlashMenu(false);
                  setShowModelPicker(true);
                }}
              >
                <span className="menuItemText">
                  <span className="menuItemLabel">/model</span>
                  <span className="menuItemDescription">Switch model</span>
                </span>
              </button>
              <div className="menuDivider" />
              {window._clawmuxCommands && window._clawmuxCommands.length > 0 ? (
                window._clawmuxCommands.map(({ cmd, desc, action }) => (
                  <button
                    key={cmd}
                    type="button"
                    className="menuItemV2"
                    onClick={() => {
                      setShowSlashMenu(false);
                      if (action === 'send') {
                        onSubmit(cmd);
                      } else {
                        if (inputRef.current) inputRef.current.textContent = cmd + ' ';
                        setText(cmd + ' ');
                      }
                    }}
                  >
                    <span className="menuItemText">
                      <span className="menuItemLabel">{cmd}</span>
                      <span className="menuItemDescription">{desc}</span>
                    </span>
                  </button>
                ))
              ) : (
                <div className="menuItemV2" style={{ opacity: 0.5, cursor: 'default' }}>
                  <span className="menuItemText">
                    <span className="menuItemLabel">No commands available</span>
                  </span>
                </div>
              )}
            </div>
          )}
          <button
            ref={slashButtonRef}
            type="button"
            className="footerMenuButton"
            title="Show command menu (/)"
            onClick={(e) => {
              e.stopPropagation();
              setSlashMenuPos(calcPos(slashButtonRef, 'left'));
              setShowSlashMenu(!showSlashMenu);
              setShowAddMenu(false);
              setShowModesMenu(false);
            }}
          >
            <svg
              width="20"
              height="20"
              viewBox="0 0 24 24"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
              style={{ display: 'block' }}
            >
              <path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z" fill="currentColor" />
            </svg>
          </button>
        </div>
        <div className="spacer" />
        {/* Mic button — only shown when voice mode is enabled */}
        {voice.enabled && (
          <button
            type="button"
            className={`micButton ${voice.recording ? 'micButtonActive' : ''}`}
            title={voice.recording ? 'Stop recording' : 'Record voice message'}
            onClick={voice.recording ? stopRecording : startRecording}
          >
            {voice.recording ? (
              <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                <rect x="6" y="6" width="12" height="12" rx="2" />
              </svg>
            ) : (
              <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm-1-9c0-.55.45-1 1-1s1 .45 1 1v6c0 .55-.45 1-1 1s-1-.45-1-1V5zm6 6c0 2.76-2.24 5-5 5s-5-2.24-5-5H5c0 3.53 2.61 6.43 6 6.92V21h2v-3.08c3.39-.49 6-3.39 6-6.92h-2z"/>
              </svg>
            )}
          </button>
        )}
        {/* Permission mode button */}
        <div className="menuContainer">
          {showModesMenu && modesMenuPos && (
            <ModesMenu
              currentMode={permissionMode}
              onSelect={setPermissionMode}
              onClose={() => setShowModesMenu(false)}
              effortLevel={selectedEffortLevel}
              onEffortChange={setEffortLevel}
              style={{ position: 'fixed', ...modesMenuPos, zIndex: 1000 }}
            />
          )}
          <button
            ref={modesButtonRef}
            type="button"
            className="footerButton footerButtonPrimary"
            title="Click to change mode, or press Shift+Tab to cycle."
            onClick={(e) => {
              e.stopPropagation();
              setModesMenuPos(calcPos(modesButtonRef, 'right'));
              setShowModesMenu(!showModesMenu);
              setShowAddMenu(false);
              setShowSlashMenu(false);
            }}
          >
            <ModeIcon mode={permissionMode} />
            <span>
              {MODE_LABELS[permissionMode] || 'Bypass permissions'}
            </span>
          </button>
        </div>
        {/* Send / Stop button */}
        {busy ? (
          <button
            type="button"
            className="sendButton stopButton"
            title="Stop (Esc)"
            onClick={onInterrupt}
          >
            <svg
              width="20"
              height="20"
              viewBox="0 0 20 20"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
              style={{ display: 'block' }}
            >
              <rect x="6" y="6" width="8" height="8" rx="1.5" fill="currentColor" />
            </svg>
          </button>
        ) : (
          <button
            type="submit"
            className="sendButton"
            title="Send (Enter)"
            onClick={handleSubmit}
            disabled={busy}
            data-permission-mode={permissionMode}
          >
            <svg
              width="20"
              height="20"
              viewBox="0 0 20 20"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
              className="sendIcon"
            >
              <path
                d="M10 3C10.1326 3.00003 10.2598 3.05274 10.3535 3.14648L15.3536 8.14648C15.5486 8.34174 15.5487 8.6583 15.3536 8.85352C15.1583 9.04873 14.8418 9.04863 14.6465 8.85352L10.5 4.70703V16.5C10.5 16.7761 10.2761 16.9999 10 17C9.72389 17 9.50003 16.7761 9.50003 16.5V4.70703L5.35353 8.85352C5.15827 9.04862 4.84172 9.04868 4.6465 8.85352C4.45128 8.6583 4.45138 8.34176 4.6465 8.14648L9.64651 3.14648L9.72268 3.08398C9.8042 3.02967 9.90062 3 10 3Z"
                fill="currentColor"
              />
            </svg>
          </button>
        )}
      </div>
      {/* Model picker popup */}
      {showModelPicker && (
        <div
          className="menuPopup menuPopupV2"
          onClick={(e) => e.stopPropagation()}
          style={{
            position: 'absolute',
            bottom: '100%',
            left: '50%',
            transform: 'translateX(-50%)',
            marginBottom: 4,
            minWidth: 280,
            zIndex: 20,
          }}
        >
          <div className="menuHeader">
            <span className="menuHeaderTitle">Select Model</span>
          </div>
          {(session?._models || window._clawmuxModels || []).map((m) => (
            <button
              key={m.id}
              type="button"
              className="menuItemV2"
              onClick={async () => {
                setShowModelPicker(false);
                const { changeModel, getCurrentAgent } = await import('../state/sessions.js');
                const agent = getCurrentAgent();
                if (agent) await changeModel(agent, m.id);
              }}
            >
              <span className="menuItemText">
                <span className="menuItemLabel">{m.label}</span>
              </span>
            </button>
          ))}
        </div>
      )}
    </fieldset>
  );
}
