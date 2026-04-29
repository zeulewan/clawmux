import React, { useRef, useCallback, useEffect, useSyncExternalStore } from 'react';
import { subscribe, getSnapshot, setRecording, setTranscribing } from '../state/voice.js';
import { subscribe as subscribeSettings, getSnapshot as getSettingsSnapshot } from '../state/settings.js';
import { unlockAudioContext } from '../hooks/useKaraoke.js';

/**
 * VoiceBar — fixed 3-button layout matching ClawMux v0.8:
 *
 *   [ PAUSE/CANCEL ]  [ MIC (always) ]  [ STOP (always) ]
 *
 * Left slot:
 *   - recording  → Cancel X
 *   - playing    → Pause ⏸
 *   - paused     → Resume ▶  (replay ↺ on long-press would be nice but skip for now)
 *   - else       → invisible (space reserved)
 *
 * Center (always clickable, even during thinking):
 *   - idle/thinking/transcribing → Mic icon → start recording
 *   - recording                  → Send icon (Whisper) / Cancel (Apple)
 *   - playing                    → Interrupt icon → stop TTS + start recording
 *   - paused                     → Mic icon → resume from pause? No — start new recording
 *
 * Right slot (always visible):
 *   - Stop/interrupt agent ■
 */
export function VoiceBar({ onSubmit, onInterrupt, busy, stop, pause, resume, replay }) {
  const voice    = useSyncExternalStore(subscribe, getSnapshot);
  const settings = useSyncExternalStore(subscribeSettings, getSettingsSnapshot);

  const mediaRecorderRef = useRef(null);
  const audioChunksRef   = useRef([]);
  const recognizerRef    = useRef(null);
  const streamRef        = useRef(null);

  const isApple   = settings.sttProvider === 'apple';
  const isPlaying = !!voice.speakingMsgId && !voice.paused;
  const isPaused  = !!voice.speakingMsgId && voice.paused;

  // ── Apple STT ─────────────────────────────────────────────────────────────
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
    rec.onstart  = () => setRecording(true);
    rec.onend    = () => { setRecording(false); recognizerRef.current = null; };
    rec.onerror  = (e) => { console.error('[voice] SR error:', e); setRecording(false); recognizerRef.current = null; };
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

  // ── Local (Whisper) STT ────────────────────────────────────────────────────
  const startLocalSTT = useCallback(async () => {
    if (!navigator.mediaDevices?.getUserMedia) {
      alert('Microphone access requires HTTPS. Connect via https://workstation.tailee9084.ts.net:3471');
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;
      const PREFERRED = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/mp4'];
      const mimeType = PREFERRED.find(t => MediaRecorder.isTypeSupported(t)) || '';
      const mr = new MediaRecorder(stream, mimeType ? { mimeType } : {});
      audioChunksRef.current = [];
      mr.ondataavailable = (e) => { if (e.data.size > 0) audioChunksRef.current.push(e.data); };
      mr.onerror = (e) => console.error('[voice] MediaRecorder error:', e);
      mr.onstop = async () => {
        streamRef.current = null;
        stream.getTracks().forEach(t => t.stop());
        setRecording(false);
        if (audioChunksRef.current.length === 0) { console.warn('[voice] no audio chunks'); return; }
        setTranscribing(true);
        try {
          const blob = new Blob(audioChunksRef.current, { type: mr.mimeType || 'audio/webm' });
          const buf  = await blob.arrayBuffer();
          const res  = await fetch('/api/stt', {
            method: 'POST', body: buf,
            headers: { 'Content-Type': blob.type || 'audio/webm' },
          });
          const { text } = await res.json();
          if (text?.trim()) onSubmit(text.trim(), []);
        } catch (e) { console.error('[voice] STT error:', e); }
        finally     { setTranscribing(false); }
      };
      mr.start(250);
      mediaRecorderRef.current = mr;
      setRecording(true);
    } catch (e) { console.error('[voice] mic error:', e); }
  }, [onSubmit]);

  const sendLocalSTT = useCallback(() => {
    mediaRecorderRef.current?.stop();
    mediaRecorderRef.current = null;
  }, []);

  const cancelLocalSTT = useCallback(() => {
    const mr = mediaRecorderRef.current;
    if (!mr) return;
    mr.onstop = null;
    try { mr.stop(); } catch {}
    mediaRecorderRef.current = null;
    audioChunksRef.current = [];
    streamRef.current = null;
    setRecording(false);
  }, []);

  const startRecording  = isApple ? startAppleSTT  : startLocalSTT;
  const sendRecording   = isApple ? cancelAppleSTT  : sendLocalSTT;   // Apple auto-sends; send = cancel
  const cancelRecording = isApple ? cancelAppleSTT  : cancelLocalSTT;

  // ── Handlers ───────────────────────────────────────────────────────────────
  const handleMic = useCallback(() => {
    unlockAudioContext();
    if (voice.recording) {
      // Send (Whisper) or cancel (Apple — result fires on its own)
      return isApple ? cancelRecording() : sendRecording();
    }
    // If TTS is playing, stop it first then record
    if (voice.speakingMsgId) stop();
    startRecording();
  }, [voice.recording, voice.speakingMsgId, isApple, cancelRecording, sendRecording, stop, startRecording]);

  const handleLeftBtn = useCallback(() => {
    unlockAudioContext();
    if (voice.recording)        return cancelRecording();
    if (isPaused)               return resume();
    if (isPlaying)              return pause();
  }, [voice.recording, isPaused, isPlaying, cancelRecording, resume, pause]);

  const handleStop = useCallback(() => {
    unlockAudioContext();
    stop();
    if (busy) onInterrupt();
  }, [stop, busy, onInterrupt]);

  // ── Left slot content ──────────────────────────────────────────────────────
  const showLeft = voice.recording || isPlaying || isPaused;
  const leftIcon = voice.recording ? (
    // Cancel X
    <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
      <path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/>
    </svg>
  ) : isPaused ? (
    // Resume ▶
    <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
      <path d="M8 5v14l11-7z"/>
    </svg>
  ) : (
    // Pause ⏸
    <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
      <rect x="6" y="5" width="4" height="14" rx="1"/>
      <rect x="14" y="5" width="4" height="14" rx="1"/>
    </svg>
  );

  // ── Center mic icon ────────────────────────────────────────────────────────
  const micState = voice.recording ? 'recording' : isPlaying ? 'playing' : isPaused ? 'paused' : 'idle';

  return (
    <div className="voiceBar">
      <div className="voiceBarControls">

        {/* ── LEFT — pause / cancel / resume ── */}
        <div className="voiceBarSide voiceBarSide--left">
          {showLeft && (
            <button
              className={`voiceBarSideBtn${voice.recording ? ' voiceBarSideBtn--cancel' : ''}`}
              onClick={handleLeftBtn}
              title={voice.recording ? 'Cancel' : isPaused ? 'Resume' : 'Pause'}
            >
              {leftIcon}
            </button>
          )}
        </div>

        {/* ── CENTER — mic (always clickable) ── */}
        <button
          className={`voiceBarMainBtn voiceBarMainBtn--${micState}`}
          onClick={handleMic}
          title={
            micState === 'recording' ? (isApple ? 'Cancel' : 'Send')
            : micState === 'playing' ? 'Tap to speak (interrupts)'
            : 'Tap to speak'
          }
        >
          {micState === 'recording' && <LiveWaveformBars stream={streamRef.current} />}

          {micState === 'playing' && (
            // v0.8 MIC_INTERRUPT_SVG — small centered square
            <svg viewBox="0 0 24 24" fill="currentColor" width="22" height="22">
              <rect x="7" y="7" width="10" height="10" rx="2"/>
            </svg>
          )}

          {(micState === 'idle' || micState === 'paused') && (
            // v0.8 MIC_SVG
            <svg viewBox="0 0 24 24" fill="currentColor" width="22" height="22">
              <path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3z"/>
              <path d="M17 11c0 2.76-2.24 5-5 5s-5-2.24-5-5H5c0 3.53 2.61 6.43 6 6.92V21h2v-3.08c3.39-.49 6-3.39 6-6.92h-2z"/>
            </svg>
          )}
        </button>

        {/* ── RIGHT — stop agent (always visible) ── */}
        <div className="voiceBarSide voiceBarSide--right">
          <button
            className="voiceBarSideBtn voiceBarSideBtn--stop"
            onClick={handleStop}
            title="Stop"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
              <rect x="6" y="6" width="12" height="12" rx="2"/>
            </svg>
          </button>
        </div>

      </div>

      <div className="voiceBarHint">
        {micState === 'idle'      && !busy && !voice.transcribing && 'Tap to speak'}
        {micState === 'recording' && 'Listening…'}
        {micState === 'playing'   && 'Playing — tap mic to interrupt'}
        {micState === 'paused'    && 'Paused'}
        {voice.transcribing       && !voice.recording && 'Transcribing…'}
        {busy                     && !voice.recording && !voice.transcribing && 'Thinking…'}
      </div>
    </div>
  );
}

// ── Live waveform (real mic audio levels via AnalyserNode) ────────────────────
function LiveWaveformBars({ stream }) {
  const barsRef = useRef(null);
  const rafRef  = useRef(null);

  useEffect(() => {
    const bars = barsRef.current?.children;
    if (!bars || !stream) return;

    let ctx;
    try { ctx = new AudioContext(); } catch { return; }
    const source   = ctx.createMediaStreamSource(stream);
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 128;
    source.connect(analyser);
    const data  = new Uint8Array(analyser.frequencyBinCount);
    const BANDS = [[1,3],[3,7],[6,14],[10,18],[2,6]];

    function draw() {
      analyser.getByteFrequencyData(data);
      for (let i = 0; i < bars.length; i++) {
        const [lo, hi] = BANDS[i];
        let sum = 0;
        for (let j = lo; j < hi; j++) sum += data[j];
        const avg = sum / (hi - lo);
        bars[i].style.height  = `${4 + (avg / 255) * 24}px`;
        bars[i].style.opacity = `${0.4 + (avg / 255) * 0.6}`;
      }
      rafRef.current = requestAnimationFrame(draw);
    }
    draw();

    return () => { cancelAnimationFrame(rafRef.current); ctx.close(); };
  }, [stream]);

  return (
    <span className="voiceWaveform" ref={barsRef} aria-hidden="true">
      {[0,1,2,3,4].map(i => <span key={i} className="voiceWaveBar" />)}
    </span>
  );
}
