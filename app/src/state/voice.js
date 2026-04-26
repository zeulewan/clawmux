/**
 * ClawMux Voice — global voice mode state store.
 * Follows the same pub/sub pattern as sessions.js.
 */

let state = {
  enabled: false,          // global voice mode toggle
  speakingMsgId: null,     // message ID currently being spoken (for karaoke)
  karaokeWords: [],        // [{word, start_time, end_time}] for active playback
  activeWordIdx: -1,       // current highlighted word index
  recording: false,        // mic is recording
  transcribing: false,     // STT in progress
  paused: false,           // playback paused
};

const listeners = new Set();

function notify() {
  for (const fn of listeners) fn();
}

export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function getSnapshot() {
  return state;
}

export function setVoiceEnabled(enabled) {
  state = { ...state, enabled };
  if (!enabled) stopSpeaking();
  notify();
}

export function setSpeaking(msgId, words) {
  state = { ...state, speakingMsgId: msgId, karaokeWords: words, activeWordIdx: -1 };
  notify();
}

export function setActiveWord(idx) {
  if (idx === state.activeWordIdx) return;
  state = { ...state, activeWordIdx: idx };
  notify();
}

export function stopSpeaking() {
  state = { ...state, speakingMsgId: null, karaokeWords: [], activeWordIdx: -1, paused: false };
  notify();
}

export function setRecording(recording) {
  state = { ...state, recording };
  notify();
}

export function setTranscribing(transcribing) {
  state = { ...state, transcribing };
  notify();
}

export function setPaused(paused) {
  state = { ...state, paused };
  notify();
}

export function isVoiceEnabled() {
  return state.enabled;
}
