import React, { useSyncExternalStore, useState } from 'react';
import { subscribe, getSnapshot, saveSettings } from '../state/settings.js';

const VOICES = [
  { id: 'af_sky',     name: 'Sky (F)' },
  { id: 'af_nova',    name: 'Nova (F)' },
  { id: 'af_bella',   name: 'Bella (F)' },
  { id: 'af_heart',   name: 'Heart (F)' },
  { id: 'af_jessica', name: 'Jessica (F)' },
  { id: 'af_kore',    name: 'Kore (F)' },
  { id: 'af_river',   name: 'River (F)' },
  { id: 'af_sarah',   name: 'Sarah (F)' },
  { id: 'af_alloy',   name: 'Alloy (F)' },
  { id: 'af_aoede',   name: 'Aoede (F)' },
  { id: 'am_puck',    name: 'Puck (M)' },
  { id: 'am_adam',    name: 'Adam (M)' },
  { id: 'am_echo',    name: 'Echo (M)' },
  { id: 'am_eric',    name: 'Eric (M)' },
  { id: 'am_onyx',    name: 'Onyx (M)' },
  { id: 'am_michael', name: 'Michael (M)' },
  { id: 'am_liam',    name: 'Liam (M)' },
  { id: 'bm_fable',   name: 'Fable (M)' },
  { id: 'bm_daniel',  name: 'Daniel (M)' },
  { id: 'bm_george',  name: 'George (M)' },
  { id: 'bf_emma',    name: 'Emma (F)' },
  { id: 'bf_lily',    name: 'Lily (F)' },
  { id: 'bf_alice',   name: 'Alice (F)' },
];

export function SettingsPanel({ onClose }) {
  const settings = useSyncExternalStore(subscribe, getSnapshot);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  const set = (key, value) => {
    setSaved(false);
    saveSettings({ [key]: value });
  };

  const hasAppleSpeech = !!(window.SpeechRecognition || window.webkitSpeechRecognition);

  return (
    <div className="settingsOverlay" onClick={onClose}>
      <div className="settingsPanel" onClick={e => e.stopPropagation()}>
        <div className="settingsPanelHeader">
          <span className="settingsPanelTitle">Settings</span>
          <button className="settingsPanelClose" onClick={onClose}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
              <path d="M18 6 6 18M6 6l12 12" strokeLinecap="round"/>
            </svg>
          </button>
        </div>

        <div className="settingsPanelBody">

          {/* ── Voice section ── */}
          <div className="settingsSection">
            <div className="settingsSectionTitle">Voice</div>

            {/* STT Provider */}
            <div className="settingsRow">
              <label className="settingsLabel">Speech recognition</label>
              <div className="settingsDescription">Where your voice is transcribed</div>
              <div className="settingsSegmented">
                <button
                  className={`settingsSegBtn ${settings.sttProvider !== 'apple' ? 'active' : ''}`}
                  onClick={() => set('sttProvider', 'local')}
                >
                  Local (Whisper)
                </button>
                <button
                  className={`settingsSegBtn ${settings.sttProvider === 'apple' ? 'active' : ''} ${!hasAppleSpeech ? 'disabled' : ''}`}
                  onClick={() => hasAppleSpeech && set('sttProvider', 'apple')}
                  title={!hasAppleSpeech ? 'Not available in this browser — use Safari on iOS/macOS' : 'Use Apple\'s built-in speech recognition'}
                >
                  Apple
                  {!hasAppleSpeech && <span className="settingsBadge">Safari only</span>}
                </button>
              </div>
              {settings.sttProvider === 'apple' && (
                <div className="settingsNote">Apple STT processes audio on-device via Safari's Web Speech API. No audio is sent to the server.</div>
              )}
            </div>

            {/* TTS Voice */}
            <div className="settingsRow">
              <label className="settingsLabel">Voice</label>
              <div className="settingsDescription">Kokoro TTS voice for responses</div>
              <select
                className="settingsSelect"
                value={settings.voice}
                onChange={e => set('voice', e.target.value)}
              >
                {VOICES.map(v => (
                  <option key={v.id} value={v.id}>{v.name}</option>
                ))}
              </select>
            </div>

            {/* Speed */}
            <div className="settingsRow">
              <label className="settingsLabel">Speed — {settings.speed}×</label>
              <div className="settingsDescription">Playback speed for TTS</div>
              <input
                type="range"
                className="settingsSlider"
                min="0.5"
                max="2.0"
                step="0.1"
                value={settings.speed}
                onChange={e => set('speed', parseFloat(e.target.value))}
              />
              <div className="settingsSliderLabels">
                <span>0.5×</span>
                <span>1.0×</span>
                <span>2.0×</span>
              </div>
            </div>
          </div>

          {/* ── Advanced section ── */}
          <div className="settingsSection">
            <div className="settingsSectionTitle">Advanced</div>

            {/* Kokoro URL */}
            <div className="settingsRow">
              <label className="settingsLabel">Kokoro URL</label>
              <div className="settingsDescription">Local TTS server address</div>
              <input
                type="text"
                className="settingsInput"
                value={settings.kokoroUrl}
                onChange={e => set('kokoroUrl', e.target.value)}
                placeholder="http://127.0.0.1:8880"
              />
            </div>

            {/* Whisper URL */}
            {settings.sttProvider !== 'apple' && (
              <div className="settingsRow">
                <label className="settingsLabel">Whisper URL</label>
                <div className="settingsDescription">Local STT server address</div>
                <input
                  type="text"
                  className="settingsInput"
                  value={settings.whisperUrl}
                  onChange={e => set('whisperUrl', e.target.value)}
                  placeholder="http://127.0.0.1:2022"
                />
              </div>
            )}
          </div>

        </div>
      </div>
    </div>
  );
}
