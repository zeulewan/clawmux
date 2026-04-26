import React, { useRef, useCallback, useSyncExternalStore } from 'react';
import { subscribe, getSnapshot, setRecording, setTranscribing } from '../state/voice.js';

/**
 * VoiceBar — replaces InputBar when voice mode is active.
 * One big button that cycles through: idle → recording → transcribing → thinking → speaking → paused
 */
export function VoiceBar({ onSubmit, onInterrupt, busy, play, stop, pause, resume }) {
  const voice = useSyncExternalStore(subscribe, getSnapshot);
  const mediaRecorderRef = useRef(null);
  const audioChunksRef = useRef([]);

  const startRecording = useCallback(async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });

      // Pick the best supported mimeType — order of preference
      const PREFERRED = [
        'audio/webm;codecs=opus',
        'audio/webm',
        'audio/ogg;codecs=opus',
        'audio/mp4',
      ];
      const mimeType = PREFERRED.find(t => MediaRecorder.isTypeSupported(t)) || '';
      console.log('[voice] recording mimeType:', mimeType || '(browser default)');

      const mr = new MediaRecorder(stream, mimeType ? { mimeType } : {});
      audioChunksRef.current = [];
      mr.ondataavailable = (e) => { if (e.data.size > 0) audioChunksRef.current.push(e.data); };
      mr.onerror = (e) => console.error('[voice] MediaRecorder error:', e);
      mr.onstop = async () => {
        stream.getTracks().forEach(t => t.stop());
        setRecording(false);

        if (audioChunksRef.current.length === 0) {
          console.warn('[voice] no audio chunks captured');
          return;
        }

        setTranscribing(true);
        try {
          const blob = new Blob(audioChunksRef.current, { type: mr.mimeType || 'audio/webm' });
          console.log('[voice] sending audio blob:', blob.size, 'bytes, type:', blob.type);
          const buf = await blob.arrayBuffer();
          const res = await fetch('/api/stt', {
            method: 'POST',
            body: buf,
            headers: { 'Content-Type': blob.type || 'audio/webm' },
          });
          const { text, error } = await res.json();
          console.log('[voice] STT result:', JSON.stringify(text), error || '');
          if (text?.trim()) {
            onSubmit(text.trim(), []);
          }
        } catch (e) {
          console.error('[voice] STT error:', e);
        } finally {
          setTranscribing(false);
        }
      };
      mr.start(250); // 250ms timeslice — ensures ondataavailable fires regularly
      mediaRecorderRef.current = mr;
      setRecording(true);
    } catch (e) {
      console.error('[voice] mic error:', e);
    }
  }, [onSubmit]);

  const stopRecording = useCallback(() => {
    mediaRecorderRef.current?.stop();
    mediaRecorderRef.current = null;
  }, []);

  // Determine current state
  const voiceState = voice.recording ? 'recording'
    : voice.transcribing ? 'transcribing'
    : busy ? 'thinking'
    : voice.speakingMsgId && voice.paused ? 'paused'
    : voice.speakingMsgId ? 'speaking'
    : 'idle';

  const handleMainButton = useCallback(() => {
    if (voiceState === 'recording') return stopRecording();
    if (voiceState === 'speaking') return pause();
    if (voiceState === 'paused') return resume();
    if (voiceState === 'idle') return startRecording();
  }, [voiceState, stopRecording, pause, resume, startRecording]);

  const handleStop = useCallback(() => {
    stop();
    if (busy) onInterrupt();
  }, [stop, busy, onInterrupt]);

  return (
    <div className="voiceBar">
      {/* Transcribing / thinking label */}
      {(voiceState === 'transcribing' || voiceState === 'thinking') && (
        <div className="voiceBarStatus">
          {voiceState === 'transcribing' ? 'Transcribing…' : 'Thinking…'}
        </div>
      )}

      <div className="voiceBarControls">
        {/* Stop button — visible when speaking, paused, or thinking */}
        {(voiceState === 'speaking' || voiceState === 'paused' || voiceState === 'thinking') && (
          <button className="voiceBarStopBtn" onClick={handleStop} title="Stop">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
              <rect x="6" y="6" width="12" height="12" rx="2" />
            </svg>
          </button>
        )}

        {/* Main state button */}
        <button
          className={`voiceBarMainBtn voiceBarMainBtn--${voiceState}`}
          onClick={handleMainButton}
          disabled={voiceState === 'transcribing' || voiceState === 'thinking'}
          title={
            voiceState === 'recording' ? 'Stop recording'
            : voiceState === 'speaking' ? 'Pause'
            : voiceState === 'paused' ? 'Resume'
            : voiceState === 'transcribing' ? 'Transcribing…'
            : voiceState === 'thinking' ? 'Thinking…'
            : 'Click to speak'
          }
        >
          {voiceState === 'recording' && (
            // Stop (square) — recording active
            <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
              <rect x="6" y="6" width="12" height="12" rx="2" />
            </svg>
          )}
          {voiceState === 'speaking' && (
            // Pause icon
            <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
              <rect x="6" y="5" width="4" height="14" rx="1" />
              <rect x="14" y="5" width="4" height="14" rx="1" />
            </svg>
          )}
          {voiceState === 'paused' && (
            // Play icon
            <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
              <path d="M8 5v14l11-7z" />
            </svg>
          )}
          {(voiceState === 'transcribing' || voiceState === 'thinking') && (
            // Spinner
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
              <circle cx="12" cy="12" r="9" strokeOpacity="0.2" />
              <path d="M12 3a9 9 0 0 1 9 9" strokeLinecap="round">
                <animateTransform attributeName="transform" type="rotate" from="0 12 12" to="360 12 12" dur="0.8s" repeatCount="indefinite" />
              </path>
            </svg>
          )}
          {voiceState === 'idle' && (
            // Mic icon
            <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm-1-9c0-.55.45-1 1-1s1 .45 1 1v6c0 .55-.45 1-1 1s-1-.45-1-1V5zm6 6c0 2.76-2.24 5-5 5s-5-2.24-5-5H5c0 3.53 2.61 6.43 6 6.92V21h2v-3.08c3.39-.49 6-3.39 6-6.92h-2z"/>
            </svg>
          )}
        </button>
      </div>

      <div className="voiceBarHint">
        {voiceState === 'idle' && 'Tap to speak'}
        {voiceState === 'recording' && 'Listening…'}
        {voiceState === 'speaking' && 'Playing response'}
        {voiceState === 'paused' && 'Paused'}
      </div>
    </div>
  );
}
