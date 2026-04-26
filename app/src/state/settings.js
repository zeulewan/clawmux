/**
 * ClawMux — voice/app settings state store.
 * Fetches from /api/voice/settings on init, persists via POST.
 */

let state = {
  voice: 'af_sky',
  speed: 1.0,
  sttProvider: 'local',   // 'local' (Whisper) | 'apple' (Web Speech API)
  kokoroUrl: 'http://127.0.0.1:8880',
  whisperUrl: 'http://127.0.0.1:2022',
  loaded: false,
};

const listeners = new Set();
function notify() { for (const fn of listeners) fn(); }

export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function getSnapshot() { return state; }

export function getVoice() { return state.voice; }
export function getSpeed() { return state.speed; }
export function getSttProvider() { return state.sttProvider; }

export async function loadSettings() {
  try {
    const r = await fetch('/api/voice/settings');
    const data = await r.json();
    state = { ...state, ...data, loaded: true };
    notify();
  } catch {}
}

export async function saveSettings(patch) {
  state = { ...state, ...patch };
  notify();
  try {
    await fetch('/api/voice/settings', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(patch),
    });
  } catch (e) { console.error('[settings] save error:', e); }
}
