import React, { useRef, useCallback, useEffect, useSyncExternalStore } from 'react';
import { subscribe, getSnapshot, setRecording, setTranscribing } from '../state/voice.js';
import { subscribe as subscribeSettings, getSnapshot as getSettingsSnapshot } from '../state/settings.js';

/**
 * VoiceBar — replaces InputBar when voice mode is active.
 *
 * Layout mirrors the old ClawMux v0.8 controls:
 *   idle:        [         ] [  MIC  ] [       ]
 *   recording:   [CANCEL X] [WAVEFRM] [ SEND ↑]
 *   transcribing/thinking: spinner, no interaction
 *   speaking:    [REPLAY ↺] [ PAUSE ] [ STOP  ]
 *   paused:      [REPLAY ↺] [RESUME ] [ STOP  ]
 */
export function VoiceBar({ onSubmit, onInterrupt, busy, stop, pause, resume, replay }) {
  const voice = useSyncExternalStore(subscribe, getSnapshot);
  const settings = useSyncExternalStore(subscribeSettings, getSettingsSnapshot);
  const mediaRecorderRef = useRef(null);
  const audioChunksRef = useRef([]);
  const recognizerRef = useRef(null);

  // ── Determine current state ──────────────────────────────────────────────
  const voiceState = voice.recording ? 'recording'
    : voice.transcribing ? 'transcribing'
    : busy ? 'thinking'
    : voice.speakingMsgId && voice.paused ? 'paused'
    : voice.speakingMsgId ? 'speaking'
    : 'idle';

  // ── Apple STT ────────────────────────────────────────────────────────────
  const startAppleSTT = useCallback(() => {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) {
      alert('Web Speech API not available. Use Safari on iOS/macOS or switch to Local STT in settings.');
      return;
    }
    const rec = new SR();
    recognizerRef.current = rec;
    rec.continuous = false;
    rec.interimResults = false;
    rec.lang = 'en-US';
    rec.onstart = () => setRecording(true);
    rec.onend = () => { setRecording(false); recognizerRef.current = null; };
    rec.onerror = (e) => { console.error('[voice] SpeechRecognition error:', e); setRecording(false); recognizerRef.current = null; };
    rec.onresult = (e) => {
      const text = Array.from(e.results).map(r => r[0].transcript).join(' ').trim();
      if (text) onSubmit(text, []);
    };
    rec.start();
  }, [onSubmit]);

  const cancelAppleSTT = useCallback(() => {
    if (recognizerRef.current) { try { recognizerRef.current.abort(); } catch {} recognizerRef.current = null; }
    setRecording(false);
  }, []);

  // ── Local (Whisper) STT ──────────────────────────────────────────────────
  const startLocalSTT = useCallback(async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const PREFERRED = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/mp4'];
      const mimeType = PREFERRED.find(t => MediaRecorder.isTypeSupported(t)) || '';
      const mr = new MediaRecorder(stream, mimeType ? { mimeType } : {});
      audioChunksRef.current = [];
      mr.ondataavailable = (e) => { if (e.data.size > 0) audioChunksRef.current.push(e.data); };
      mr.onerror = (e) => console.error('[voice] MediaRecorder error:', e);
      mr.onstop = async () => {
        stream.getTracks().forEach(t => t.stop());
        setRecording(false);
        if (audioChunksRef.current.length === 0) { console.warn('[voice] no audio chunks'); return; }
        setTranscribing(true);
        try {
          const blob = new Blob(audioChunksRef.current, { type: mr.mimeType || 'audio/webm' });
          const buf = await blob.arrayBuffer();
          const res = await fetch('/api/stt', {
            method: 'POST',
            body: buf,
            headers: { 'Content-Type': blob.type || 'audio/webm' },
          });
          const { text, error } = await res.json();
          if (text?.trim()) onSubmit(text.trim(), []);
        } catch (e) {
          console.error('[voice] STT error:', e);
        } finally {
          setTranscribing(false);
        }
      };
      mr.start(250);
      mediaRecorderRef.current = mr;
      setRecording(true);
    } catch (e) {
      console.error('[voice] mic error:', e);
    }
  }, [onSubmit]);

  const stopLocalSTT = useCallback(() => {
    mediaRecorderRef.current?.stop();
    mediaRecorderRef.current = null;
  }, []);

  const cancelLocalSTT = useCallback(() => {
    const mr = mediaRecorderRef.current;
    if (!mr) return;
    mr.onstop = null; // suppress transcription
    try { mr.stop(); } catch {}
    mediaRecorderRef.current = null;
    audioChunksRef.current = [];
    setRecording(false);
  }, []);

  // ── Dispatch ─────────────────────────────────────────────────────────────
  const startRecording = settings.sttProvider === 'apple' ? startAppleSTT : startLocalSTT;
  const sendRecording  = settings.sttProvider === 'apple' ? () => {} : stopLocalSTT;
  const cancelRecording = settings.sttProvider === 'apple' ? cancelAppleSTT : cancelLocalSTT;

  // ── Button handlers ───────────────────────────────────────────────────────
  const handleMainBtn = useCallback(() => {
    if (voiceState === 'idle')      return startRecording();
    if (voiceState === 'recording') return settings.sttProvider === 'apple' ? cancelRecording() : sendRecording();
    if (voiceState === 'speaking')  return pause();
    if (voiceState === 'paused')    return resume();
  }, [voiceState, startRecording, sendRecording, cancelRecording, pause, resume, settings.sttProvider]);

  const handleStop = useCallback(() => {
    stop();
    if (busy) onInterrupt();
  }, [stop, busy, onInterrupt]);

  const isSpinner = voiceState === 'transcribing' || voiceState === 'thinking';
  const showSides = voiceState !== 'idle' && !isSpinner;

  return (
    <div className="voiceBar">
      {isSpinner && (
        <div className="voiceBarStatus">
          {voiceState === 'transcribing' ? 'Transcribing…' : 'Thinking…'}
        </div>
      )}

      <div className="voiceBarControls">

        {/* ── LEFT BUTTON ── */}
        <div className="voiceBarSide voiceBarSide--left">
          {voiceState === 'recording' && (
            <button className="voiceBarSideBtn" onClick={cancelRecording} title="Cancel">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
                <path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/>
              </svg>
            </button>
          )}
          {(voiceState === 'speaking' || voiceState === 'paused') && replay && (
            <button className="voiceBarSideBtn" onClick={replay} title="Replay from start">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 5V1L7 6l5 5V7c3.31 0 6 2.69 6 6s-2.69 6-6 6-6-2.69-6-6H4c0 4.42 3.58 8 8 8s8-3.58 8-8-3.58-8-8-8z"/>
              </svg>
            </button>
          )}
        </div>

        {/* ── MAIN CENTER BUTTON ── */}
        <button
          className={`voiceBarMainBtn voiceBarMainBtn--${voiceState}`}
          onClick={handleMainBtn}
          disabled={isSpinner}
          title={
            voiceState === 'recording'     ? 'Send'
            : voiceState === 'speaking'    ? 'Pause'
            : voiceState === 'paused'      ? 'Resume'
            : voiceState === 'transcribing'? 'Transcribing…'
            : voiceState === 'thinking'    ? 'Thinking…'
            : 'Click to speak'
          }
        >
          {voiceState === 'recording' && <WaveformBars />}

          {voiceState === 'speaking' && (
            <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
              <rect x="6" y="5" width="4" height="14" rx="1" />
              <rect x="14" y="5" width="4" height="14" rx="1" />
            </svg>
          )}
          {voiceState === 'paused' && (
            <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
              <path d="M8 5v14l11-7z" />
            </svg>
          )}
          {isSpinner && (
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
              <circle cx="12" cy="12" r="9" strokeOpacity="0.2" />
              <path d="M12 3a9 9 0 0 1 9 9" strokeLinecap="round">
                <animateTransform attributeName="transform" type="rotate" from="0 12 12" to="360 12 12" dur="0.8s" repeatCount="indefinite" />
              </path>
            </svg>
          )}
          {voiceState === 'idle' && (
            <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm-1-9c0-.55.45-1 1-1s1 .45 1 1v6c0 .55-.45 1-1 1s-1-.45-1-1V5zm6 6c0 2.76-2.24 5-5 5s-5-2.24-5-5H5c0 3.53 2.61 6.43 6 6.92V21h2v-3.08c3.39-.49 6-3.39 6-6.92h-2z"/>
            </svg>
          )}
        </button>

        {/* ── RIGHT BUTTON ── */}
        <div className="voiceBarSide voiceBarSide--right">
          {voiceState === 'recording' && settings.sttProvider !== 'apple' && (
            <button className="voiceBarSideBtn voiceBarSideBtn--send" onClick={sendRecording} title="Send">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
                <path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/>
              </svg>
            </button>
          )}
          {(voiceState === 'speaking' || voiceState === 'paused' || voiceState === 'thinking') && (
            <button className="voiceBarSideBtn voiceBarSideBtn--stop" onClick={handleStop} title="Stop">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
                <rect x="6" y="6" width="12" height="12" rx="2" />
              </svg>
            </button>
          )}
        </div>

      </div>

      <div className="voiceBarHint">
        {voiceState === 'idle'        && 'Tap to speak'}
        {voiceState === 'recording'   && 'Listening…'}
        {voiceState === 'speaking'    && 'Playing response'}
        {voiceState === 'paused'      && 'Paused'}
      </div>
    </div>
  );
}

/** Animated waveform bars shown during recording. */
function WaveformBars() {
  return (
    <span className="voiceWaveform" aria-hidden="true">
      {[0, 1, 2, 3, 4].map(i => (
        <span key={i} className="voiceWaveBar" style={{ animationDelay: `${i * 0.1}s` }} />
      ))}
    </span>
  );
}
