// ClawMux — Shared State
// Extracted from hub.html Phase 1 refactor.
// These are global variables shared across all modules.

// --- State ---
const sessions = new Map(); // session_id -> { label, status, messages[], el }
const isMobile = /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent) || ('ontouchstart' in window && window.innerWidth < 768);
let activeSessionId = null;
let recordingSessionId = null;
let ws = null;
let mediaRecorder = null;
let audioChunks = [];
let recording = false;
let micMuted = false;
let autoMode = false;
let pendingListenSessionId = null; // session waiting for manual mic click
let vadEnabled = true;
let vadInterval = null; // silence detection interval
let vadDetectedSpeech = false; // did we hear any speech this recording?
let currentAudio = null; // { source, sessionId, playbackId } — currently playing Web Audio source
let currentBufferedPlayer = null; // { sessionId, stop() } — active buffered playback
let persistentStream = null; // persistent mic MediaStream, acquired once
let autoInterruptEnabled = false; // voice-based interrupt during playback
let playbackVadInterval = null; // VAD interval during playback for auto-interrupt
let playbackVadCtx = null; // AudioContext for playback VAD
const spawningVoices = new Set(); // voice IDs currently being spawned
let thinkingSoundsEnabled = true; // thinking tick sounds
let audioCuesEnabled = true; // listening/processing/ready cues
let ttsEnabled = true; // text-to-speech — play buttons, karaoke, voice output
let sttEnabled = true; // speech-to-text — mic recording, VAD, voice input
let showAgentMessages = true; // show inter-agent messages in chat
let playbackPaused = false; // transport: is playback paused?
let pausedBuffer = null; // transport: decoded AudioBuffer for resume
let pauseOffset = 0; // transport: seconds into buffer when paused
let pausedSessionId = null; // transport: session that was paused
let playbackStartTime = 0; // transport: audioCtx.currentTime when source started
let _longPressFired = false; // mobile: set by long-press handler, cleared by click handler
