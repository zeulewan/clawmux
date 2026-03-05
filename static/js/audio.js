// ClawMux — Audio Module
// Extracted from hub.html Phase 2 refactor.
// All functions and variables remain global (window-scoped).
//
// Dependencies (defined in state.js and hub.html inline script):
//   state.js: sessions, activeSessionId, recording, micMuted, autoMode,
//             vadEnabled, vadInterval, vadDetectedSpeech, currentAudio,
//             currentBufferedPlayer, persistentStream, autoInterruptEnabled,
//             playbackVadInterval, playbackVadCtx, thinkingSoundsEnabled,
//             audioCuesEnabled, voiceResponsesEnabled, playbackPaused,
//             pausedBuffer, pauseOffset, pausedSessionId, playbackStartTime,
//             recordingSessionId, mediaRecorder, audioChunks,
//             pendingListenSessionId, spawningVoices
//   hub.html: chatArea, setStatus, renderSidebar, setSessionSidebarState,
//             setSessionState, getSessionState, setToggle, voiceColor,
//             _checkPendingListen, _handleListeningUI, controls, inputMode

// --- Waveform & Audio Cues (from hub.html) ---
// --- Waveform visualizer ---
const waveCanvas = document.getElementById('waveform');
const waveCtx = waveCanvas.getContext('2d');
let waveAnalyser = null;
let waveAnimFrame = null;
let waveAudioCtxVis = null;

function startWaveform(stream) {
  waveCanvas.style.display = 'block';
  const topRow = document.getElementById('controls-top');
  if (topRow) topRow.style.display = 'flex';
  // Scroll chat to bottom since waveform takes space
  requestAnimationFrame(() => { chatScrollToBottom(true); });
  const dpr = window.devicePixelRatio || 1;
  const rect = waveCanvas.getBoundingClientRect();
  waveCanvas.width = rect.width * dpr;
  waveCanvas.height = rect.height * dpr;
  waveCtx.scale(dpr, dpr);
  // Reset history for fresh recording
  waveHistory = [];
  waveLastSample = 0;
  // Use a separate AudioContext for visualization (don't interfere with cues)
  if (!waveAudioCtxVis) waveAudioCtxVis = new (window.AudioContext || window.webkitAudioContext)();
  const source = waveAudioCtxVis.createMediaStreamSource(stream);
  waveAnalyser = waveAudioCtxVis.createAnalyser();
  waveAnalyser.fftSize = 256;
  source.connect(waveAnalyser);
  drawWaveform();
}

// Scrolling timeline waveform — shows audio history progressing over time
let waveHistory = [];
let waveLastSample = 0;
const WAVE_SAMPLE_INTERVAL = 50; // ms between samples

function drawWaveform() {
  if (!waveAnalyser) return;
  waveAnimFrame = requestAnimationFrame(drawWaveform);

  const now = performance.now();
  const rect = waveCanvas.getBoundingClientRect();
  const w = rect.width;
  const h = rect.height;

  // Sample audio level at intervals
  if (now - waveLastSample >= WAVE_SAMPLE_INTERVAL) {
    waveLastSample = now;
    const bufLen = waveAnalyser.frequencyBinCount;
    const data = new Uint8Array(bufLen);
    waveAnalyser.getByteTimeDomainData(data);
    // Calculate RMS level
    let sum = 0;
    for (let i = 0; i < bufLen; i++) {
      const v = (data[i] - 128) / 128;
      sum += v * v;
    }
    const rms = Math.sqrt(sum / bufLen);
    const level = Math.min(1, rms * 7); // amplify for visibility
    waveHistory.push(level);

    // Keep only enough bars to fill the width
    const barWidth = 3;
    const barGap = 2;
    const maxBars = Math.ceil(w / (barWidth + barGap)) + 2;
    if (waveHistory.length > maxBars) {
      waveHistory = waveHistory.slice(-maxBars);
    }
  }

  // Draw
  waveCtx.clearRect(0, 0, waveCanvas.width, waveCanvas.height);
  const s = sessions.get(activeSessionId);
  const color = s ? voiceColor(s.voice) : '#34d399';

  const barWidth = 3;
  const barGap = 2;
  const totalBars = waveHistory.length;
  // Draw from the right edge, scrolling left
  const startX = w - totalBars * (barWidth + barGap);

  for (let i = 0; i < totalBars; i++) {
    const level = waveHistory[i];
    const barHeight = Math.max(2, level * (h - 4));
    const x = startX + i * (barWidth + barGap);
    const y = (h - barHeight) / 2;

    if (x + barWidth < 0) continue; // offscreen left

    waveCtx.fillStyle = color;
    waveCtx.globalAlpha = 0.35 + level * 0.65;
    waveCtx.beginPath();
    waveCtx.roundRect(x, y, barWidth, barHeight, 1.5);
    waveCtx.fill();
  }
  waveCtx.globalAlpha = 1;
}

function stopWaveform() {
  if (waveAnimFrame) { cancelAnimationFrame(waveAnimFrame); waveAnimFrame = null; }
  waveAnalyser = null;
  waveCanvas.style.display = 'none';
  const topRow = document.getElementById('controls-top');
  if (topRow) topRow.style.display = 'none';
}

// --- Audio cues ---
const audioCtx = new (window.AudioContext || window.webkitAudioContext)();

function playTone(freq, duration, startDelay = 0, gain = 0.15) {
  const osc = audioCtx.createOscillator();
  const vol = audioCtx.createGain();
  osc.type = 'sine';
  osc.frequency.value = freq;
  vol.gain.value = gain;
  // Fade out
  vol.gain.setValueAtTime(gain, audioCtx.currentTime + startDelay);
  vol.gain.exponentialRampToValueAtTime(0.001, audioCtx.currentTime + startDelay + duration);
  osc.connect(vol);
  vol.connect(audioCtx.destination);
  osc.start(audioCtx.currentTime + startDelay);
  osc.stop(audioCtx.currentTime + startDelay + duration);
}

let lastCueTime = 0;
function cueListening() {
  if (!audioCuesEnabled) return;
  const now = Date.now();
  if (now - lastCueTime < 2000) return; // cooldown: skip if played within 2s
  lastCueTime = now;
  // Ascending two-tone: your turn to speak
  playTone(660, 0.12, 0);
  playTone(880, 0.15, 0.1);
}

function cueProcessing() {
  if (!audioCuesEnabled) return;
  // Single soft low tone: thinking
  playTone(440, 0.2, 0, 0.08);
}

function cueSessionReady() {
  if (!audioCuesEnabled) return;
  // Three-note chime: connected
  playTone(523, 0.1, 0);
  playTone(659, 0.1, 0.1);
  playTone(784, 0.15, 0.2);
}


// --- stopActiveAudio (from hub.html) ---
function stopActiveAudio({ stashForResume = false } = {}) {

  // Stop currently playing audio (Web Audio sources can't be paused/resumed)
  const stoppedSessionId = (currentAudio && currentAudio.sessionId) ||
                           (currentBufferedPlayer && currentBufferedPlayer.sessionId) || null;

  // Stash remaining audio so it can be replayed when switching back to the tab
  if (stashForResume && stoppedSessionId) {
    const sess = sessions.get(stoppedSessionId);
    if (sess) {
      const remaining = [];
      if (currentBufferedPlayer) {
        // Buffered playback: stash current chunk (from offset) + remaining chunks
        const idx = currentBufferedPlayer.chunkIndex;
        const chunks = currentBufferedPlayer.chunks;
        // For the current chunk, note how far in we are so resume can seek
        if (currentAudio && currentAudio.b64data && currentAudio._startTime != null) {
          const elapsed = audioCtx.currentTime - currentAudio._startTime;
          remaining.push({ b64data: currentAudio.b64data, offset: elapsed });
        } else if (idx < chunks.length) {
          remaining.push(chunks[idx]);
        }
        remaining.push(...chunks.slice(idx + 1));
      } else if (currentAudio && currentAudio.b64data) {
        // Single chunk playback: stash with seek offset
        if (currentAudio._startTime != null) {
          const elapsed = audioCtx.currentTime - currentAudio._startTime;
          remaining.push({ b64data: currentAudio.b64data, offset: elapsed });
        } else {
          remaining.push(currentAudio.b64data);
        }
      }
      // Stash queued chunks (no offset needed)
      const queued = _audioPlayQueue.get(stoppedSessionId) || [];
      remaining.push(...queued);
      if (remaining.length > 0) {
        sess.audioBuffer = [...remaining, ...(sess.audioBuffer || [])];
      }
      // Save karaoke words (strip DOM refs — they'll be stale after renderChat)
      if (_karaokeWords && _karaokeWords.length > 0) {
        sess.karaokeWords = _karaokeWords.map(w => ({ word: w.word, start_time: w.start_time, end_time: w.end_time }));
      }
    }
  }

  if (currentAudio) {
    if (currentAudio.source) { try { currentAudio.source.onended = null; currentAudio.source.stop(); } catch(e) {} }
    currentAudio = null;
  }
  if (currentBufferedPlayer) {
    currentBufferedPlayer.stop();
    currentBufferedPlayer = null;
  }
  _audioPlayQueue.clear();
  _audioPlaying = false;
  playbackPaused = false;
  pausedBuffer = null;
  pauseOffset = 0;
  pausedSessionId = null;
  _pausedKaraokeWords = null;
  stopTTSPlayback();
  karaokeStop();
  // Update sidebar state — but not if stashing for resume (session will still be 'speaking')
  if (!stashForResume && stoppedSessionId) {
    const st = getSessionState(stoppedSessionId);
    if (st === 'processing') {
      setSessionSidebarState(stoppedSessionId, 'working');
    } else if (st === 'speaking') {
      // Audio stopped, transition to idle
      setSessionState(stoppedSessionId, 'idle');
    } else {
      setSessionSidebarState(stoppedSessionId, 'idle');
    }
  }
  updateMicUI();
}

// --- TTS Playback (from hub.html) ---
// --- TTS playback for messages ---
let _ttsPlayingBtn = null;
let _ttsPlaybackId = null; // tracks which playback the button belongs to
function stopTTSPlayback() {
  if (_ttsPlayingBtn) { _ttsPlayingBtn.textContent = '▶'; _ttsPlayingBtn.classList.remove('playing'); _ttsPlayingBtn = null; }
  _ttsPlaybackId = null;
}
async function playMessageTTS(btn, text, voiceId) {
  // If already playing this button, stop it
  if (_ttsPlayingBtn === btn) {
    stopActiveAudio();
    stopTTSPlayback();
    updateTransportBar();
    return;
  }
  // Stop any existing playback
  stopActiveAudio();
  stopTTSPlayback();
  updateTransportBar();

  btn.textContent = '…';
  btn.classList.add('playing');
  _ttsPlayingBtn = btn;

  // Get session speed for playback
  const s = activeSessionId ? sessions.get(activeSessionId) : null;
  const speed = s ? (s.speed || 1.0) : 1.0;
  try {
    const resp = await fetch('/api/tts-captioned', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, voice: voiceId || 'af_sky', speed }),
    });
    if (!resp.ok) throw new Error('TTS failed');
    const { audio_b64, words } = await resp.json();
    const bytes = Uint8Array.from(atob(audio_b64), c => c.charCodeAt(0));

    // Set up karaoke on the message element (btn's ancestor .msg)
    const msgEl = btn.closest('.msg');
    const realWords = words ? words.filter(w => /\w/.test(w.word)) : [];
    if (msgEl && realWords.length) _applyKaraokeSpans(msgEl, realWords);

    // Decode and play via AudioContext (integrates with transport bar)
    const ready = audioCtx.state === 'suspended' ? audioCtx.resume() : Promise.resolve();
    await ready;
    const decoded = await audioCtx.decodeAudioData(bytes.buffer);
    // Cache buffer on message element for word-click seek without re-fetching TTS
    if (msgEl) msgEl._ttsCache = { decoded, words: realWords };

    const playbackId = Symbol();
    _ttsPlaybackId = playbackId;
    const source = audioCtx.createBufferSource();
    source.buffer = decoded;
    source.connect(audioCtx.destination);
    const startT = audioCtx.currentTime;
    currentAudio = { source, sessionId: activeSessionId || '__tts__', decodedBuffer: decoded, playbackId, b64data: audio_b64, _startTime: startT };
    playbackStartTime = startT;
    playbackPaused = false;

    if (realWords.length) karaokeStart(currentAudio, realWords);

    btn.textContent = '■';

    const _ttsOnEnded = () => {
      if (!playbackPaused) {
        karaokeStop();
        currentAudio = null;
        if (_ttsPlaybackId === playbackId) stopTTSPlayback();
        updateTransportBar();
        updateMicUI();
      }
    };
    source.onended = _ttsOnEnded;
    currentAudio._onended = _ttsOnEnded;
    source.start(0);
    updateTransportBar();
  } catch (e) {
    console.error('TTS playback error:', e);
    stopTTSPlayback();
    updateTransportBar();
  }
}

function _wrapWordsInSpans(container, text) {
  // Wrap each word in a karaoke-word span (without timestamps) for hover effects
  const frag = document.createDocumentFragment();
  const words = text.split(/(\s+)/); // split keeping whitespace
  for (const part of words) {
    if (/^\s+$/.test(part)) {
      frag.appendChild(document.createTextNode(part));
    } else if (part) {
      const span = document.createElement('span');
      span.className = 'karaoke-word';
      span.textContent = part;
      frag.appendChild(span);
    }
  }
  container.appendChild(frag);
}

function _wrapTextNodesInKaraokeSpans(container) {
  // Walk text nodes in rendered markdown and wrap words in karaoke-word spans
  // Skip <pre>, <code>, <katex> elements
  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const p = node.parentElement;
      if (!p) return NodeFilter.FILTER_REJECT;
      if (p.closest('pre, code, .katex, .katex-display')) return NodeFilter.FILTER_REJECT;
      if (!node.textContent.trim()) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    }
  });
  const textNodes = [];
  while (walker.nextNode()) textNodes.push(walker.currentNode);
  for (const tn of textNodes) {
    const frag = document.createDocumentFragment();
    const words = tn.textContent.split(/(\s+)/);
    for (const part of words) {
      if (/^\s+$/.test(part)) {
        frag.appendChild(document.createTextNode(part));
      } else if (part) {
        const span = document.createElement('span');
        span.className = 'karaoke-word';
        span.textContent = part;
        frag.appendChild(span);
      }
    }
    tn.parentNode.replaceChild(frag, tn);
  }
}

// --- VAD, Transport, Thinking (from hub.html) ---
// --- VAD (voice activity detection) ---
function toggleVAD() {
  vadEnabled = !vadEnabled;
  setToggle('auto_end', vadEnabled);
  fetch('/api/settings', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ auto_end: vadEnabled }) }).catch(() => {});
}

function startVAD(stream) {
  if (vadInterval) { clearInterval(vadInterval); vadInterval = null; }
  vadDetectedSpeech = false;

  const vadCtx = new AudioContext();
  const source = vadCtx.createMediaStreamSource(stream);
  const analyser = vadCtx.createAnalyser();
  analyser.fftSize = 512;
  source.connect(analyser);

  const data = new Uint8Array(analyser.frequencyBinCount);
  const SILENCE_THRESHOLD = 10; // RMS level below which = silence
  const SILENCE_DURATION = 3000; // ms of silence before auto-stop
  let silenceStart = null;

  vadInterval = setInterval(() => {
    if (!recording) {
      clearInterval(vadInterval);
      vadInterval = null;
      vadCtx.close();
      return;
    }

    analyser.getByteTimeDomainData(data);
    // Calculate RMS
    let sum = 0;
    for (let i = 0; i < data.length; i++) {
      const v = (data[i] - 128) / 128;
      sum += v * v;
    }
    const rms = Math.sqrt(sum / data.length) * 200;

    if (rms < SILENCE_THRESHOLD) {
      if (!silenceStart) silenceStart = Date.now();
      else if (vadDetectedSpeech && Date.now() - silenceStart > SILENCE_DURATION) {
        // Speech was heard, now silence — auto-stop
        stopRecording();
        clearInterval(vadInterval);
        vadInterval = null;
        vadCtx.close();
      }
    } else {
      silenceStart = null;
      vadDetectedSpeech = true;
    }
  }, 100);
}

// --- Auto Interrupt (voice-based interrupt during playback) ---
function toggleAutoInterrupt() {
  autoInterruptEnabled = !autoInterruptEnabled;
  setToggle('auto_interrupt', autoInterruptEnabled);
  fetch('/api/settings', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ auto_interrupt: autoInterruptEnabled }) }).catch(() => {});
}

function toggleThinkingSounds() {
  thinkingSoundsEnabled = !thinkingSoundsEnabled;
  setToggle('thinking_sounds', thinkingSoundsEnabled);
  if (!thinkingSoundsEnabled) stopThinkingSound();
  fetch('/api/settings', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ thinking_sounds: thinkingSoundsEnabled }) }).catch(() => {});
}

function toggleAudioCues() {
  audioCuesEnabled = !audioCuesEnabled;
  setToggle('audio_cues', audioCuesEnabled);
  fetch('/api/settings', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ audio_cues: audioCuesEnabled }) }).catch(() => {});
}

// --- Transport controls (pause/resume, skip) ---
function updateTransportBar() {
  const isPlaying = !!(currentAudio || currentBufferedPlayer);
  const pauseBtn = document.getElementById('transport-pause');
  if (pauseBtn) {
    if (isPlaying || playbackPaused) {
      pauseBtn.style.display = 'flex';
      pauseBtn.innerHTML = playbackPaused ? '&#9654;' : '&#9208;';
      pauseBtn.title = playbackPaused ? 'Resume' : 'Pause';
    } else {
      pauseBtn.style.display = 'none';
    }
  }
}

function transportPause() {
  if (playbackPaused) {
    // Resume from paused state
    if (!pausedBuffer || !pausedSessionId) return;
    const source = audioCtx.createBufferSource();
    source.buffer = pausedBuffer;
    source.connect(audioCtx.destination);
    const resumeSess = sessions.get(pausedSessionId);
    const resumeRate = resumeSess ? (resumeSess.speed || 1.0) : 1.0;
    currentAudio = { source, sessionId: pausedSessionId, decodedBuffer: pausedBuffer, _startTime: audioCtx.currentTime - pauseOffset };
    playbackStartTime = audioCtx.currentTime - pauseOffset;
    // Restore karaoke: if the RAF loop is still alive (frozen during pause), just update the ref.
    // Otherwise restart from scratch.
    if (_pausedKaraokeWords) {
      if (_karaokeRaf && _karaokeWords) {
        _karaokeAudioRef = currentAudio; // RAF loop resumes using new audio ref
      } else {
        karaokeStart(currentAudio, _pausedKaraokeWords);
      }
      _pausedKaraokeWords = null;
    }
    playbackPaused = false;
    const _transportOnEnded = () => {
      if (!playbackPaused) {
        currentAudio = null;
        pausedBuffer = null;
        // If part of buffered playback, continue to next chunk
        if (currentBufferedPlayer) {
          currentBufferedPlayer.skipNext();
        } else {
          // Single-chunk playback done
          if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ session_id: pausedSessionId, type: 'playback_done' }));
          }
          stopPlaybackVAD();
          updateMicUI();
          updateTransportBar();
        }
      }
    };
    source.onended = _transportOnEnded;
    if (currentAudio) currentAudio._onended = _transportOnEnded;
    source.start(0, pauseOffset);
    updateTransportBar();
    updateMicUI();
  } else {
    // Pause current playback
    if (!currentAudio || !currentAudio.source) return;
    pauseOffset = audioCtx.currentTime - playbackStartTime;
    pausedBuffer = currentAudio.decodedBuffer || null;
    pausedSessionId = currentAudio.sessionId;
    _pausedKaraokeWords = _karaokeWords ? [..._karaokeWords] : null;
    playbackPaused = true;
    try { currentAudio.source.onended = null; currentAudio.source.stop(); } catch(e) {}
    currentAudio = null;
    updateTransportBar();
    updateMicUI();
  }
}

function transportNext() {
  playbackPaused = false;
  pausedBuffer = null;
  if (currentBufferedPlayer) {
    currentBufferedPlayer.skipNext();
  } else if (currentAudio) {
    const sid = currentAudio.sessionId;
    stopActiveAudio();
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ session_id: sid, type: 'playback_done' }));
    }
  } else {
    // Was paused on single chunk — just end
    if (pausedSessionId && ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ session_id: pausedSessionId, type: 'playback_done' }));
    }
    pausedSessionId = null;
    updateTransportBar();
    updateMicUI();
  }
}

function transportPrev() {
  playbackPaused = false;
  pausedBuffer = null;
  if (currentBufferedPlayer) {
    currentBufferedPlayer.skipPrev();
  } else if (currentAudio && currentAudio.decodedBuffer) {
    // Restart current single chunk from beginning
    try { currentAudio.source.onended = null; currentAudio.source.stop(); } catch(e) {}
    const decoded = currentAudio.decodedBuffer;
    const sid = currentAudio.sessionId;
    const source = audioCtx.createBufferSource();
    source.buffer = decoded;
    source.connect(audioCtx.destination);
    currentAudio = { source, sessionId: sid, decodedBuffer: decoded };
    playbackStartTime = audioCtx.currentTime;
    source.onended = () => {
      if (!playbackPaused) {
        stopPlaybackVAD();
        currentAudio = null;
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ session_id: sid, type: 'playback_done' }));
        }
        updateMicUI();
        updateTransportBar();
      }
    };
    source.start(0);
  }
}

function startPlaybackVAD(sessionId) {
  stopPlaybackVAD();
  getMicStream().then(stream => {
    playbackVadCtx = new AudioContext();
    const source = playbackVadCtx.createMediaStreamSource(stream);
    const analyser = playbackVadCtx.createAnalyser();
    analyser.fftSize = 512;
    source.connect(analyser);

    const data = new Uint8Array(analyser.frequencyBinCount);
    const SPEECH_THRESHOLD = 25; // higher than auto-end to avoid speaker bleed
    const SPEECH_DURATION = 300; // ms of sustained speech before triggering
    let speechStart = null;

    playbackVadInterval = setInterval(() => {
      // Stop if no longer playing
      if (!currentAudio && !currentBufferedPlayer) {
        stopPlaybackVAD();
        return;
      }

      analyser.getByteTimeDomainData(data);
      let sum = 0;
      for (let i = 0; i < data.length; i++) {
        const v = (data[i] - 128) / 128;
        sum += v * v;
      }
      const rms = Math.sqrt(sum / data.length) * 200;

      if (rms >= SPEECH_THRESHOLD) {
        if (!speechStart) speechStart = Date.now();
        else if (Date.now() - speechStart >= SPEECH_DURATION) {
          // Sustained speech detected — interrupt and record
          const sid = sessionId;
          stopPlaybackVAD();
          interruptPlayback(sid);
          startRecording(sid);
        }
      } else {
        speechStart = null;
      }
    }, 50); // check every 50ms for responsiveness
  }).catch(err => {
    console.warn('Playback VAD mic error:', err);
  });
}

function stopPlaybackVAD() {
  if (playbackVadInterval) {
    clearInterval(playbackVadInterval);
    playbackVadInterval = null;
  }
  if (playbackVadCtx) {
    playbackVadCtx.close().catch(() => {});
    playbackVadCtx = null;
  }
}

// --- Thinking VAD (auto-record interjections while agent is processing) ---
let thinkingVadInterval = null;
let thinkingVadCtx = null;
let thinkingVadSessionId = null;

function startThinkingVAD(sessionId) {
  if (!autoMode || micMuted) return;
  stopThinkingVAD();
  thinkingVadSessionId = sessionId;

  getMicStream().then(stream => {
    thinkingVadCtx = new AudioContext();
    const source = thinkingVadCtx.createMediaStreamSource(stream);
    const analyser = thinkingVadCtx.createAnalyser();
    analyser.fftSize = 512;
    source.connect(analyser);

    const data = new Uint8Array(analyser.frequencyBinCount);
    const SPEECH_THRESHOLD = 20;
    const SPEECH_DURATION = 300; // ms of sustained speech before triggering
    let speechStart = null;

    thinkingVadInterval = setInterval(() => {
      // Stop if session is no longer thinking, or we're already recording
      const s = sessions.get(sessionId);
      if (!s || s.sessionState === 'listening' || s.sessionState === 'idle' || recording) {
        stopThinkingVAD();
        return;
      }

      analyser.getByteTimeDomainData(data);
      let sum = 0;
      for (let i = 0; i < data.length; i++) {
        const v = (data[i] - 128) / 128;
        sum += v * v;
      }
      const rms = Math.sqrt(sum / data.length) * 200;

      if (rms >= SPEECH_THRESHOLD) {
        if (!speechStart) speechStart = Date.now();
        else if (Date.now() - speechStart >= SPEECH_DURATION) {
          // Speech detected — start recording interjection
          stopThinkingVAD();
          interjectionMode = true;
          startRecording(sessionId);
        }
      } else {
        speechStart = null;
      }
    }, 50);
  }).catch(err => {
    console.warn('Thinking VAD mic error:', err);
  });
}

function stopThinkingVAD() {
  if (thinkingVadInterval) {
    clearInterval(thinkingVadInterval);
    thinkingVadInterval = null;
  }
  if (thinkingVadCtx) {
    thinkingVadCtx.close().catch(() => {});
    thinkingVadCtx = null;
  }
  thinkingVadSessionId = null;
}

// --- Status indicator stubs ---
// Live status indicator removed — activity log entries are the only display.
// These no-ops remain so callers don't need updating.
function showStatusIndicator() {}
function updateStatusIndicator() {}
function hideStatusIndicator() {}
function showThinking(sessionId) { const s = sessions.get(sessionId); if (s) s.isThinking = true; }
function hideThinking(sessionId) { const s = sessions.get(sessionId); if (s) s.isThinking = false; }
function updateThinkingLabel() {}
function showIdleStatus() {}
function hideIdleStatus() {}

// --- Session state machine ---
// States: 'idle' | 'listening' | 'processing' | 'speaking'
// Replaces overlapping booleans: awaitingInput, isThinking, userSpokeThisCycle
function setSessionState(sessionId, newState) {
  const s = sessions.get(sessionId);
  if (!s) return;
  const prev = s.sessionState || 'idle';
  if (prev === newState) return;
  s.sessionState = newState;

  // Sync legacy boolean flags (for any code not yet migrated)
  s.awaitingInput = (newState === 'listening');
  s.isThinking = (newState === 'processing');
  s.userSpokeThisCycle = false;

  // Side effects per state
  if (newState === 'idle') {
    stopThinkingSound();
    stopThinkingVAD();
    showIdleStatus(sessionId);  // renders activity log + idle status indicator
    setSessionSidebarState(sessionId, 'idle');
    if (sessionId === activeSessionId) {
      setStatus('Ready', sessionId);
      micBtn.disabled = false;
      updateMicUI();
    }
  } else if (newState === 'listening') {
    hideStatusIndicator(sessionId);
    stopThinkingSound();
    stopThinkingVAD();
    // Promote interjection messages (agent is now listening = acknowledged them)
    if (sessionId === activeSessionId) {
      chatArea.querySelectorAll('.msg.interjection').forEach(el => el.classList.remove('interjection'));
    }
    s.messages.forEach(m => { if (m.role === 'user interjection') m.role = 'user'; });
    setSessionSidebarState(sessionId, 'idle');  // listening is browser-only; sidebar shows idle
    if (sessionId === activeSessionId) {
      micBtn.disabled = false;
      updateMicUI();
    }
  } else if (newState === 'processing') {
    showThinking(sessionId);  // reuses status indicator, switches to processing style
    startThinkingSound(sessionId);
    setSessionSidebarState(sessionId, 'working');
    if (sessionId === activeSessionId) {
      setStatus('Thinking...', sessionId);
      startThinkingVAD(sessionId);
    }
  } else if (newState === 'speaking') {
    hideStatusIndicator(sessionId);
    stopThinkingSound();
    stopThinkingVAD();
    // Sidebar reflects server state only — don't set 'speaking' on sidebar
    if (sessionId === activeSessionId) {
      setStatus('Speaking...', sessionId);
    }
  }
}

function getSessionState(sessionId) {
  const s = sessions.get(sessionId);
  return s ? (s.sessionState || 'idle') : 'idle';
}

function _handleListeningUI(session_id, s) {
  // Set up recording/input UI when entering listening state
  if (recording && recordingSessionId === session_id) {
    // Already recording for this session
  } else if (pendingListenSessionId === session_id) {
    // Already waiting for manual mic click
  } else if (inputMode === 'typing') {
    if (session_id === activeSessionId) {
      setStatus('Type your message', session_id);
      textInput.focus();
    } else {
      s.pendingListen = true;
      s.statusText = 'Waiting...';
    }
  } else if (micMuted) {
    sendSilentAudio(session_id);
  } else if (session_id === activeSessionId && autoMode && inputMode === 'voice') {
    cueListening();
    startRecording(session_id);
  } else if (session_id === activeSessionId && inputMode === 'voice' && !autoMode) {
    cueListening();
    pendingListenSessionId = session_id;
    updateMicUI();
    setStatus(isMobile ? 'Tap to Record' : 'Tap or Hold Space');
  } else {
    s.pendingListen = true;
    s.statusText = 'Waiting...';
  }
}

function _checkPendingListen(sessionId) {
  // Called after audio playback completes — check if a listening transition was deferred
  const s = sessions.get(sessionId);
  if (s && s.pendingListenAfterPlayback) {
    s.pendingListenAfterPlayback = false;
    setSessionState(sessionId, 'listening');
    _handleListeningUI(sessionId, s);
  }
}

// --- Thinking sound ---
let thinkingSoundTimer = null;
let thinkingSoundSessionId = null;

function startThinkingSound(sessionId) {
  stopThinkingSound();
  thinkingSoundSessionId = sessionId;
  if (!thinkingSoundsEnabled) return;
  if (!activeSessionId || sessionId !== activeSessionId) return; // only play for focused session tab
  const tick = () => {
    // Double-tick pattern: two quick soft clicks
    playTone(1200, 0.03, 0, 0.06);
    playTone(900, 0.03, 0.08, 0.04);
  };
  tick();
  thinkingSoundTimer = setInterval(tick, 800);
}

function stopThinkingSound() {
  if (thinkingSoundTimer) {
    clearInterval(thinkingSoundTimer);
    thinkingSoundTimer = null;
  }
  thinkingSoundSessionId = null;
}

// --- Audio Playback, Karaoke, Buffered (from hub.html) ---
// --- Audio playback (Web Audio API for Safari autoplay compatibility) ---
// Per-session playback queue: if audio is already playing, queue the next chunk
const _audioPlayQueue = new Map(); // sessionId -> [b64data, ...]
let _audioPlaying = false; // true while a playAudio decode+play is active

function enqueueAudio(sessionId, b64data) {
  // Buffer audio while user is recording — play after they stop
  if (recording) {
    if (!_audioPlayQueue.has(sessionId)) _audioPlayQueue.set(sessionId, []);
    _audioPlayQueue.get(sessionId).push(b64data);
    return;
  }
  if (!_audioPlaying && !currentAudio) {
    // Nothing playing — play immediately
    _audioPlaying = true;
    playAudio(sessionId, b64data);
  } else {
    // Something is playing — queue it
    if (!_audioPlayQueue.has(sessionId)) _audioPlayQueue.set(sessionId, []);
    _audioPlayQueue.get(sessionId).push(b64data);
  }
}

function _playNextQueued(sessionId) {
  const queue = _audioPlayQueue.get(sessionId);
  if (queue && queue.length > 0) {
    const next = queue.shift();
    if (queue.length === 0) _audioPlayQueue.delete(sessionId);
    _audioPlaying = true;
    playAudio(sessionId, next);
  } else {
    _audioPlaying = false;
    _audioPlayQueue.delete(sessionId);
  }
}

function playAudio(sessionId, b64data, startOffset = 0) {
  const bytes = Uint8Array.from(atob(b64data), c => c.charCodeAt(0));
  const buffer = bytes.buffer;

  // Track this playback instance so we can detect if it's been superseded
  const playbackId = Symbol();
  currentAudio = { playbackId, sessionId, source: null, b64data, _startTime: null };
  if (sessionId === activeSessionId) updateMicUI();

  // Capture pending karaoke words NOW (synchronously) before async decode,
  // to avoid race where a new message's karaokeSetupMessage overwrites them
  const capturedKaraokeWords = _pendingKaraokeWords.get(sessionId) || null;
  if (capturedKaraokeWords) _pendingKaraokeWords.delete(sessionId);

  const cleanup = () => {
    if (currentAudio && currentAudio.playbackId === playbackId) currentAudio = null;
    updateMicUI();
  };

  const sendDone = () => {
    cleanup();
    // Check if there's more queued audio to play before sending playback_done
    const queue = _audioPlayQueue.get(sessionId);
    if (queue && queue.length > 0) {
      _playNextQueued(sessionId);
      return; // Don't send playback_done yet — more audio to play
    }
    _audioPlaying = false;
    // Use state machine for transition after playback
    const st = getSessionState(sessionId);
    if (st === 'speaking') {
      setSessionState(sessionId, 'idle');
    } else if (st === 'processing') {
      setSessionSidebarState(sessionId, 'working');
    }
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ session_id: sessionId, type: 'playback_done' }));
    }
    _checkPendingListen(sessionId);
  };

  // Resume audioCtx if suspended (Safari suspends until user gesture)
  const ready = audioCtx.state === 'suspended' ? audioCtx.resume() : Promise.resolve();
  ready.then(() => audioCtx.decodeAudioData(buffer.slice(0)))
    .then(decoded => {
      if (currentAudio && currentAudio.playbackId !== playbackId) return; // superseded
      // Pad audio for starts near the beginning to prevent first-word cutoff
      const sess_ = sessions.get(sessionId);
      const padSec = getAudioPadSec(sess_ ? sess_.speed : 1);
      const usePad = startOffset < padSec * 2;
      const buf = usePad ? padAudioBuffer(decoded, padSec) : decoded;
      const source = audioCtx.createBufferSource();
      source.buffer = buf;
      source.connect(audioCtx.destination);
      if (currentAudio) { currentAudio.source = source; currentAudio.decodedBuffer = buf; currentAudio._startTime = audioCtx.currentTime - startOffset; currentAudio._padOffset = usePad ? padSec : 0; }
      playbackStartTime = audioCtx.currentTime;
      playbackPaused = false;
      // Start karaoke if we captured pending words for this playback (shift timestamps for padding)
      if (capturedKaraokeWords) {
        if (usePad) capturedKaraokeWords.forEach(w => { w.start_time += padSec; w.end_time += padSec; });
        karaokeStart(currentAudio, capturedKaraokeWords);
      }
      const _onended = () => { if (!playbackPaused) { stopPlaybackVAD(); karaokeStop(); sendDone(); } };
      source.onended = _onended;
      if (currentAudio) currentAudio._onended = _onended;
      source.start(0, startOffset);
      updateTransportBar();
      if (autoInterruptEnabled && !micMuted) startPlaybackVAD(sessionId);
    })
    .catch(() => { stopPlaybackVAD(); sendDone(); setStatus('Audio error'); });
}

// --- Audio padding: prepend silence to prevent first-word cutoff ---
const AUDIO_PAD_BASE = 0.15; // base silence padding (seconds) at 1x speed
function getAudioPadSec(speed) { return AUDIO_PAD_BASE * Math.max(1, speed || 1); }
function padAudioBuffer(decoded, padSec) {
  const padSamples = Math.floor(decoded.sampleRate * padSec);
  const padded = audioCtx.createBuffer(decoded.numberOfChannels, decoded.length + padSamples, decoded.sampleRate);
  for (let ch = 0; ch < decoded.numberOfChannels; ch++) {
    padded.getChannelData(ch).set(decoded.getChannelData(ch), padSamples);
  }
  return padded;
}

// --- Karaoke word highlighting ---
let _karaokeRaf = null;
let _karaokeWords = null;   // [{word, start_time, end_time, el}] for real words with span refs
let _karaokeAudioRef = null; // reference to currentAudio at karaoke start
let _pausedKaraokeWords = null; // saved karaoke words across transport pause/resume
let _karaokeActiveIdx = -1;

// Per-session pending words (waiting for audio to start)
const _pendingKaraokeWords = new Map(); // sessionId -> words[]

function karaokeSetupMessage(sessionId, words) {
  // Filter to real (non-punctuation) words only
  const realWords = words.filter(w => /\w/.test(w.word));
  if (realWords.length === 0) return;
  _pendingKaraokeWords.set(sessionId, realWords);

  // Find the last assistant message element for this session and apply spans
  if (sessionId !== activeSessionId) return;
  const msgs = chatArea.querySelectorAll('.msg.assistant');
  if (!msgs.length) return;
  const msgEl = msgs[msgs.length - 1];
  _applyKaraokeSpans(msgEl, realWords);
}

function _applyKaraokeSpans(msgEl, realWords) {
  const mdContent = msgEl.querySelector('.md-content');

  // If message has markdown-rendered content, apply timestamps to existing karaoke-word spans
  if (mdContent) {
    const existingSpans = mdContent.querySelectorAll('.karaoke-word');
    if (existingSpans.length > 0) {
      let wordIdx = 0;
      for (const span of existingSpans) {
        if (wordIdx >= realWords.length) break;
        const spanText = span.textContent.toLowerCase().replace(/[^\w]/g, '');
        if (!spanText) continue; // skip empty/punctuation spans
        // Find matching word — small look-ahead first, then wider search to skip code blocks
        let matched = false;
        const searchLimit = Math.min(wordIdx + 5, realWords.length);
        for (let i = wordIdx; i < searchLimit; i++) {
          const w = realWords[i];
          const wText = w.word.toLowerCase().replace(/[^\w]/g, '');
          if (spanText === wText || spanText.startsWith(wText) || wText.startsWith(spanText)) {
            span.dataset.start = w.start_time;
            w.el = span;
            wordIdx = i + 1;
            matched = true;
            break;
          }
        }
        // If small look-ahead failed, scan further — TTS words from skipped code blocks
        // create gaps between DOM spans and TTS word indices
        if (!matched) {
          const wideLimit = Math.min(wordIdx + 200, realWords.length);
          for (let i = searchLimit; i < wideLimit; i++) {
            const w = realWords[i];
            const wText = w.word.toLowerCase().replace(/[^\w]/g, '');
            if (spanText === wText || spanText.startsWith(wText) || wText.startsWith(spanText)) {
              span.dataset.start = w.start_time;
              w.el = span;
              wordIdx = i + 1;
              break;
            }
          }
        }
      }
    }
    return;
  }

  // Plain text fallback — original behavior
  const actionsEl = msgEl.querySelector('.msg-actions');
  // Get original text — prefer stored data attribute, fall back to DOM content
  const text = msgEl.dataset.text || Array.from(msgEl.childNodes)
    .filter(n => n !== actionsEl)
    .map(n => n.textContent).join('');
  // Always clear and rebuild from scratch (avoids stale span/text-node fragments)
  Array.from(msgEl.childNodes).forEach(n => { if (n !== actionsEl) msgEl.removeChild(n); });
  const textNode = document.createTextNode(text);
  if (actionsEl) msgEl.insertBefore(textNode, actionsEl);
  else msgEl.appendChild(textNode);

  // Greedy forward match: find each word in the text in order (case-insensitive)
  // Uses word-boundary-aware matching to avoid matching inside other words
  const frag = document.createDocumentFragment();
  const textLower = text.toLowerCase();
  let pos = 0;
  const isWordChar = c => /\w/.test(c);
  for (const w of realWords) {
    const wordLower = w.word.toLowerCase();
    let idx = pos;
    // Find next occurrence that isn't embedded inside another word
    while (true) {
      idx = textLower.indexOf(wordLower, idx);
      if (idx === -1) break;
      const before = idx > 0 ? textLower[idx - 1] : ' ';
      const after = idx + wordLower.length < textLower.length ? textLower[idx + wordLower.length] : ' ';
      // Accept if at word boundaries (not embedded inside another word)
      if (!isWordChar(before) && !isWordChar(after)) break;
      idx++; // skip this partial match, try next
    }
    if (idx === -1) { w.el = null; continue; }
    // Text before this word
    if (idx > pos) frag.appendChild(document.createTextNode(text.slice(pos, idx)));
    // Word span — use original text casing, not TTS casing
    const span = document.createElement('span');
    span.className = 'karaoke-word';
    span.dataset.start = w.start_time;
    span.textContent = text.slice(idx, idx + w.word.length);
    w.el = span;
    frag.appendChild(span);
    pos = idx + w.word.length;
  }
  // Remaining text
  if (pos < text.length) frag.appendChild(document.createTextNode(text.slice(pos)));

  textNode.replaceWith(frag);
}

function karaokeStart(audioRef, words) {
  karaokeStop();
  if (!words || !words.length) return;
  const activeWords = words.filter(w => w.el);
  if (!activeWords.length) return;
  _karaokeWords = activeWords;
  _karaokeAudioRef = audioRef;
  _karaokeActiveIdx = -1;
  _karaokeRaf = requestAnimationFrame(_karaokeFrame);
}

function _karaokeFrame() {
  if (!_karaokeAudioRef || !_karaokeWords) { karaokeStop(); return; }
  // During transport pause: keep current word highlighted, freeze loop
  if (playbackPaused) { _karaokeRaf = requestAnimationFrame(_karaokeFrame); return; }
  // If audio changed (new playback started), stop
  if (currentAudio !== _karaokeAudioRef && currentBufferedPlayer === null) { karaokeStop(); return; }
  const startTime = _karaokeAudioRef._startTime;
  if (startTime == null) { _karaokeRaf = requestAnimationFrame(_karaokeFrame); return; }
  const elapsed = audioCtx.currentTime - startTime;

  // Find active word — keep previous active until a new one starts (no gap flash)
  let newIdx = -1;
  for (let i = 0; i < _karaokeWords.length; i++) {
    const w = _karaokeWords[i];
    if (elapsed >= w.start_time && elapsed < w.end_time) { newIdx = i; break; }
  }
  // Only update when we have a new positive match (don't clear on gap between words)
  if (newIdx >= 0 && newIdx !== _karaokeActiveIdx) {
    if (_karaokeActiveIdx >= 0 && _karaokeWords[_karaokeActiveIdx].el) {
      _karaokeWords[_karaokeActiveIdx].el.classList.remove('active');
    }
    _karaokeWords[newIdx].el.classList.add('active');
    _karaokeActiveIdx = newIdx;
  }
  _karaokeRaf = requestAnimationFrame(_karaokeFrame);
}

function karaokeStop() {
  if (_karaokeRaf) { cancelAnimationFrame(_karaokeRaf); _karaokeRaf = null; }
  if (_karaokeActiveIdx >= 0 && _karaokeWords && _karaokeWords[_karaokeActiveIdx]?.el) {
    _karaokeWords[_karaokeActiveIdx].el.classList.remove('active');
  }
  _karaokeWords = null;
  _karaokeAudioRef = null;
  _karaokeActiveIdx = -1;
}

// --- Karaoke word-click seek ---
function karaokeSeekTo(startTime) {
  if (!currentAudio || !currentAudio.decodedBuffer) return false;
  const { decodedBuffer, sessionId, b64data, _onended, _padOffset } = currentAudio;
  const pad = _padOffset || 0;
  const maxTime = decodedBuffer.duration - pad - 0.05;
  const offset = Math.max(0, Math.min(startTime, maxTime));

  // Stop current source (suppress onended)
  try { currentAudio.source.onended = null; currentAudio.source.stop(); } catch(e) {}

  // Create new source from same buffer
  const source = audioCtx.createBufferSource();
  source.buffer = decodedBuffer;
  source.connect(audioCtx.destination);

  currentAudio = { source, sessionId, decodedBuffer, b64data, _startTime: audioCtx.currentTime - offset, _onended, _padOffset: pad };
  playbackStartTime = audioCtx.currentTime - offset;

  // Update karaoke audio ref so the RAF loop follows the new source
  if (_karaokeAudioRef) _karaokeAudioRef = currentAudio;

  if (_onended) source.onended = _onended;
  source.start(0, offset + pad);
  return true;
}

// Play message TTS from a specific offset (or beginning). Uses cached buffer if available.
async function karaokePlayFromWord(msgEl, startTime, fetchId, clickedWord = false, clickedWordText = null) {
  const voiceId = msgEl.dataset.voice || (activeSessionId ? sessions.get(activeSessionId)?.voice : null) || 'af_sky';
  const s = activeSessionId ? sessions.get(activeSessionId) : null;
  const speed = s ? (s.speed || 1.0) : 1.0;

  let decoded, realWords;
  if (msgEl._ttsCache) {
    ({ decoded, words: realWords } = msgEl._ttsCache);
  } else {
    const text = msgEl.dataset.text;
    if (!text) return;
    try {
      const resp = await fetch('/api/tts-captioned', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text, voice: voiceId, speed }),
      });
      if (!resp.ok) throw new Error('TTS failed');
      const { audio_b64, words } = await resp.json();
      const bytes = Uint8Array.from(atob(audio_b64), c => c.charCodeAt(0));
      const ready = audioCtx.state === 'suspended' ? audioCtx.resume() : Promise.resolve();
      await ready;
      decoded = await audioCtx.decodeAudioData(bytes.buffer);
      realWords = words ? words.filter(w => /\w/.test(w.word)) : [];
      msgEl._ttsCache = { decoded, words: realWords };
    } catch(e) { console.error('TTS failed:', e); return; }
  }
  // If a newer click arrived while we were fetching, bail out
  if (fetchId !== undefined && fetchId !== _karaokeFetchId) return;
  if (realWords.length) _applyKaraokeSpans(msgEl, realWords);

  // If startTime was 0 because the span had no timestamp yet (first click),
  // resolve it now from the fetched word timestamps.
  // Use the clicked span's position to find the correct occurrence (not just first match).
  if (startTime === 0 && clickedWordText && realWords.length) {
    // Count which occurrence of this word was clicked by checking DOM order
    const allSpans = msgEl.querySelectorAll('.karaoke-word');
    const clickedSpan = Array.from(allSpans).find(s => s === e?.target?.closest?.('.karaoke-word'));
    let occurrenceIdx = 0;
    if (clickedSpan) {
      for (const s of allSpans) {
        if (s === clickedSpan) break;
        if (s.textContent.toLowerCase() === clickedWordText.toLowerCase()) occurrenceIdx++;
      }
    }
    // Find the nth occurrence in realWords
    let found = 0;
    for (const w of realWords) {
      if (w.word.toLowerCase() === clickedWordText.toLowerCase()) {
        if (found === occurrenceIdx) { startTime = w.start_time; break; }
        found++;
      }
    }
  }

  stopActiveAudio();
  const sessionId = activeSessionId || '__tts__';
  const offset = Math.max(0, Math.min(startTime || 0, decoded.duration - 0.05));
  const source = audioCtx.createBufferSource();
  source.buffer = decoded;
  source.connect(audioCtx.destination);
  currentAudio = { source, sessionId, decodedBuffer: decoded, _startTime: audioCtx.currentTime - offset };
  playbackStartTime = audioCtx.currentTime - offset;
  playbackPaused = false;
  if (realWords.length) karaokeStart(currentAudio, realWords);
  const _onended = () => { if (!playbackPaused) { karaokeStop(); currentAudio = null; updateTransportBar(); updateMicUI(); } };
  source.onended = _onended;
  currentAudio._onended = _onended;
  source.start(0, offset);
  updateTransportBar();
  updateMicUI();
}

// Event delegation — click on assistant message to TTS from that word (or beginning)
let _karaokeFetchId = 0; // incremented on each new click to cancel stale async fetches
chatArea.addEventListener('click', async (e) => {
  // On mobile, skip if a long-press context menu just fired
  if (isMobile && _longPressFired) { _longPressFired = false; return; }
  const msgEl = e.target.closest('.msg.assistant');
  if (!msgEl) return;
  if (e.target.closest('.msg-actions')) return; // let action buttons handle themselves
  if (window.getSelection && window.getSelection().toString().length > 0) return; // don't interfere with text selection

  const wordEl = e.target.closest('.karaoke-word');
  const clickedWordText = wordEl ? wordEl.textContent : null;
  // dataset.start may not exist on first click (hover-only spans without timestamps)
  const startTime = wordEl && wordEl.dataset.start != null ? parseFloat(wordEl.dataset.start) : 0;

  // Only seek if clicking the message that's currently playing karaoke
  const currentKaraokeMsgEl = (_karaokeWords && _karaokeWords.length > 0)
    ? (_karaokeWords[0].el?.closest('.msg.assistant') || null) : null;
  const isCurrentKaraokeMsg = currentKaraokeMsgEl === msgEl;

  if (wordEl && currentAudio && currentAudio.decodedBuffer && isCurrentKaraokeMsg) {
    // Audio is playing this message — seek to clicked word (sync, no guard needed)
    e.stopPropagation();
    karaokeSeekTo(isNaN(startTime) ? 0 : startTime);
  } else {
    // New TTS play — increment fetch ID to cancel any in-flight fetch for a different message
    const fetchId = ++_karaokeFetchId;
    e.stopPropagation();
    await karaokePlayFromWord(msgEl, isNaN(startTime) ? 0 : startTime, fetchId, !!wordEl, clickedWordText);
  }
});

// --- Buffered playback ---
function playBufferedAudio(sessionId, chunks) {
  if (chunks.length === 0) return;
  let i = 0;
  let stopped = false;

  currentBufferedPlayer = {
    sessionId,
    chunks,
    get chunkIndex() { return i; },
    set chunkIndex(v) { i = v; },
    stop() { stopped = true; stopPlaybackVAD(); if (currentAudio && currentAudio.source) { try { currentAudio.source.stop(); } catch(e) {} } },
    skipNext() { if (currentAudio && currentAudio.source) { try { currentAudio.source.onended = null; currentAudio.source.stop(); } catch(e) {} } currentAudio = null; playNext(); },
    skipPrev() { i = Math.max(0, i - 2); if (currentAudio && currentAudio.source) { try { currentAudio.source.onended = null; currentAudio.source.stop(); } catch(e) {} } currentAudio = null; playNext(); },
  };
  updateMicUI();
  updateTransportBar();
  if (autoInterruptEnabled && !micMuted) startPlaybackVAD(sessionId);

  function playNext() {
    if (stopped || i >= chunks.length) {
      currentBufferedPlayer = null;
      currentAudio = null;
      playbackPaused = false;
      updateMicUI();
      updateTransportBar();
      // Use state machine for transition after playback
      const st = getSessionState(sessionId);
      if (st === 'speaking') {
        setSessionState(sessionId, 'idle');
      } else if (st === 'processing') {
        setSessionSidebarState(sessionId, 'working');
      }
      if (!stopped && ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ session_id: sessionId, type: 'playback_done' }));
      }
      _checkPendingListen(sessionId);
      return;
    }
    const chunk = chunks[i++];
    const b64data = (typeof chunk === 'string') ? chunk : chunk.b64data;
    const startOffset = (typeof chunk === 'object' && chunk.offset) ? chunk.offset : 0;
    const bytes = Uint8Array.from(atob(b64data), c => c.charCodeAt(0));
    const buffer = bytes.buffer;

    const ready = audioCtx.state === 'suspended' ? audioCtx.resume() : Promise.resolve();
    ready.then(() => audioCtx.decodeAudioData(buffer.slice(0)))
      .then(decoded => {
        if (stopped) return;
        // Clamp offset to valid range
        const offset = Math.min(startOffset, decoded.duration - 0.05);
        const source = audioCtx.createBufferSource();
        source.buffer = decoded;
        source.connect(audioCtx.destination);
        currentAudio = { source, sessionId, decodedBuffer: decoded, b64data, _startTime: audioCtx.currentTime - offset };
        playbackStartTime = audioCtx.currentTime;
        playbackPaused = false;
        // Start karaoke if pending words exist (e.g. restored after tab switch)
        const pendingWords = _pendingKaraokeWords.get(sessionId);
        if (pendingWords) { _pendingKaraokeWords.delete(sessionId); karaokeStart(currentAudio, pendingWords); }
        const _onended = () => { if (!playbackPaused) { currentAudio = null; playNext(); } };
        source.onended = _onended;
        currentAudio._onended = _onended;
        source.start(0, offset > 0 ? offset : 0);
        updateTransportBar();
        updateMicUI();
      })
      .catch(() => { currentAudio = null; playNext(); });
  }

  playNext();
}

// --- Mic UI, Recording, PTT (from hub.html) ---
// --- Mic UI state management ---
// --- SVG icons for mic button states ---
const MIC_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" width="22" height="22"><path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3z"/><path d="M17 11c0 2.76-2.24 5-5 5s-5-2.24-5-5H5c0 3.53 2.61 6.43 6 6.92V21h2v-3.08c3.39-.49 6-3.39 6-6.92h-2z"/></svg>';
const MIC_SEND_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" width="24" height="24"><path d="M3.4 20.4l17.45-7.48a1 1 0 000-1.84L3.4 3.6a.993.993 0 00-1.39.91L2 9.12c0 .5.37.93.87.99L17 12 2.87 13.88c-.5.07-.87.5-.87 1l.01 4.61c0 .71.73 1.2 1.39.91z"/></svg>';
const MIC_INTERRUPT_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" width="22" height="22"><rect x="7" y="7" width="10" height="10" rx="2"/></svg>';

function updateMicUI() {
  const isPlaying = !!(currentAudio || currentBufferedPlayer);
  updateTransportBar();

  micBtn.classList.remove('recording', 'interruptable', 'processing', 'connecting');

  if (isPlaying) {
    // During playback: mic = interrupt/stop
    micBtn.style.display = 'flex';
    micBtn.disabled = false;
    micBtn.classList.add('interruptable');
    micBtn.innerHTML = MIC_INTERRUPT_SVG;
    micCancelBtn.style.display = 'none';
  } else if (recording) {
    // Recording: mic = send, cancel visible, pause hidden
    const pauseBtn = document.getElementById('transport-pause');
    if (pauseBtn) pauseBtn.style.display = 'none';
    micBtn.style.display = 'flex';
    micBtn.classList.add('recording');
    micBtn.innerHTML = MIC_SEND_SVG;
    micBtn.disabled = false;
    micCancelBtn.style.display = 'flex';
  } else {
    // Idle or paused: mic = record
    micCancelBtn.style.display = 'none';
    micBtn.style.display = 'flex';
    micBtn.innerHTML = MIC_SVG;
    micBtn.disabled = false;
  }
}

// --- Persistent mic stream ---
async function getMicStream() {
  if (persistentStream) {
    // Check if tracks are still alive
    const tracks = persistentStream.getAudioTracks();
    if (tracks.length > 0 && tracks[0].readyState === 'live') {
      return persistentStream;
    }
  }
  persistentStream = await navigator.mediaDevices.getUserMedia({ audio: true });
  // Apply current mute state
  persistentStream.getAudioTracks().forEach(t => { t.enabled = !micMuted; });
  return persistentStream;
}

// --- Recording ---
async function startRecording(sessionId) {
  recordingSessionId = sessionId;
  // Interrupt any ongoing playback so voice doesn't continue while recording
  if (currentAudio || currentBufferedPlayer) {
    interruptPlayback(sessionId);
  }
  // Show connecting state immediately (before async mic permission on iOS)
  micBtn.classList.remove('recording', 'interruptable', 'processing', 'connecting');
  micBtn.classList.add('connecting');
  micBtn.disabled = true;
  setStatus('Connecting mic...');
  try {
    const stream = await getMicStream();
    mediaRecorder = new MediaRecorder(stream, { mimeType: 'audio/webm;codecs=opus' });
    audioChunks = [];
    mediaRecorder.ondataavailable = e => { if (e.data.size > 0) audioChunks.push(e.data); };
    mediaRecorder.onstop = () => {
      // Don't stop persistent stream tracks — keep them alive
      if (discardRecording) {
        discardRecording = false;
      } else {
        sendAudio(sessionId);
      }
    };
    mediaRecorder.start();
    recording = true;
    updateMicUI();
    startWaveform(stream);
    setStatus('Recording...');
    if (vadEnabled) startVAD(stream);
  } catch (err) {
    micBtn.classList.remove('connecting');
    micBtn.disabled = false;
    updateMicUI();
    setStatus('Microphone access denied');
  }
}

let discardRecording = false;
let _pendingAudioSend = null; // { sessionId, blob, isInterjection } — stashed when WS disconnected

function stopRecording(discard = false) {
  discardRecording = discard;
  if (mediaRecorder && mediaRecorder.state === 'recording') {
    mediaRecorder.stop();
  }
  recording = false;
  stopWaveform();
  updateMicUI();
  // Drain any audio that was buffered while recording
  if (activeSessionId && !currentAudio && !_audioPlaying) {
    const queue = _audioPlayQueue.get(activeSessionId);
    if (queue && queue.length > 0) {
      _audioPlaying = true;
      _playNextQueued(activeSessionId);
    }
  }
}

function cancelRecording() {
  if (recording) {
    stopRecording(true); // discard audio
    if (recordingSessionId) sendSilentAudio(recordingSessionId);
    setStatus('Recording cancelled');
  }
}

let interjectionMode = false;  // true when recording an interjection (agent is busy)

function sendAudio(sessionId) {
  const isInterjection = interjectionMode;
  interjectionMode = false;
  const blob = new Blob(audioChunks, { type: 'audio/webm' });

  if (!ws || ws.readyState !== WebSocket.OPEN) {
    // Stash audio for retry after reconnect instead of dropping it
    _pendingAudioSend = { sessionId, blob, isInterjection };
    setStatus('Reconnecting — audio saved...');
    return;
  }
  if (isInterjection) {
    setStatus('Transcribing...', sessionId);
  } else {
    cueProcessing();
    setStatus('Processing...');
  }
  micBtn.classList.add('processing');
  micBtn.innerHTML = '<svg viewBox="0 0 24 24" fill="currentColor" width="22" height="22" style="animation:spin 1s linear infinite"><circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2" stroke-dasharray="31.4 31.4"/></svg>';
  micBtn.disabled = true;

  const reader = new FileReader();
  reader.onload = () => {
    const b64 = reader.result.split(',')[1];
    const msgType = isInterjection ? 'interjection' : 'audio';
    ws.send(JSON.stringify({ session_id: sessionId, type: msgType, data: b64 }));
    if (isInterjection) {
      // Re-enable mic after sending interjection (agent is still busy)
      setTimeout(() => {
        micBtn.classList.remove('processing');
        micBtn.disabled = false;
        updateMicUI();
        // Restart thinking VAD to listen for more interjections
        const s = sessions.get(sessionId);
        if (s && s.sessionState === 'processing' && sessionId === activeSessionId) {
          startThinkingVAD(sessionId);
        }
      }, 500);
    }
  };
  reader.onerror = () => {
    setStatus('Error reading audio');
    updateMicUI();
  };
  reader.readAsDataURL(blob);
}

function _flushPendingAudio() {
  if (!_pendingAudioSend || !ws || ws.readyState !== WebSocket.OPEN) return;
  const { sessionId, blob } = _pendingAudioSend;
  _pendingAudioSend = null;
  console.log('[flushPendingAudio] Sending stashed audio as interjection for', sessionId);
  // Send as interjection — hub will transcribe and queue it properly
  // (regular audio would be drained as stale by the wait handler)
  const reader = new FileReader();
  reader.onload = () => {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const b64 = reader.result.split(',')[1];
    ws.send(JSON.stringify({ session_id: sessionId, type: 'interjection', data: b64 }));
    setStatus('Transcribing...', sessionId);
  };
  reader.readAsDataURL(blob);
}

// --- Silent audio for muted sessions ---
function sendSilentAudio(sessionId) {
  // Send a minimal valid webm audio blob (silence)
  // The hub will STT it and get [BLANK_AUDIO], triggering the retry prompt
  // To avoid that, we send an empty data payload — hub should treat empty audio as "skip"
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ session_id: sessionId, type: 'audio', data: '' }));
  }
}

// --- Interrupt playback ---
function interruptPlayback(sessionId) {
  stopPlaybackVAD();
  // Stop current audio immediately
  if (currentAudio) {
    if (currentAudio.source) { try { currentAudio.source.onended = null; currentAudio.source.stop(); } catch(e) {} }
    currentAudio = null;
  }
  if (currentBufferedPlayer) {
    currentBufferedPlayer.stop();
    currentBufferedPlayer = null;
  }
  // Clear audio queue on interrupt
  _audioPlayQueue.delete(sessionId);
  _audioPlaying = false;
  updateMicUI();
  setStatus('Ready', sessionId);

  // Send playback_done to notify hub that audio finished
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ session_id: sessionId, type: 'playback_done' }));
  }
  _checkPendingListen(sessionId);
}

// --- Mic button ---
let pttActive = false; // true while PTT button is held down

micBtn.addEventListener('click', (e) => {
  // If PTT is active (spacebar held), ignore click events
  if (pttActive) return;
  if (micBtn.disabled) return;

  // Interrupt: tap during playback → stop audio, hub sends listening next
  if (currentAudio || currentBufferedPlayer) {
    const sid = (currentAudio && currentAudio.sessionId) ||
                (currentBufferedPlayer && currentBufferedPlayer.sessionId) ||
                activeSessionId;
    interruptPlayback(sid);
    return;
  }

  // Send: tap during recording → stop and send audio
  if (recording) {
    stopRecording();
    return;
  }

  // Record: tap when idle or agent busy → start recording
  if (pendingListenSessionId) {
    const sid = pendingListenSessionId;
    pendingListenSessionId = null;
    startRecording(sid);
  } else if (activeSessionId) {
    // Check if agent is NOT awaiting input — record as interjection
    const s = sessions.get(activeSessionId);
    if (s && s.sessionState !== 'listening') {
      interjectionMode = true;
    }
    startRecording(activeSessionId);
  }
});

// --- Push-to-Talk: hold to record, release to send ---
function pttStart(e) {
  if (inputMode !== 'voice' || micBtn.disabled) return;
  e.preventDefault();
  // Stop auto-recording if active so PTT takes over cleanly
  if (recording && !pttActive) stopRecording(true);
  pttActive = true;

  // Interrupt playback if playing
  if (currentAudio || currentBufferedPlayer) {
    const sid = (currentAudio && currentAudio.sessionId) ||
                (currentBufferedPlayer && currentBufferedPlayer.sessionId) ||
                activeSessionId;
    interruptPlayback(sid);
    return;
  }

  const sid = pendingListenSessionId || activeSessionId;
  if (!sid) return;
  if (pendingListenSessionId) pendingListenSessionId = null;

  // Check if agent is NOT listening — record as interjection
  const s = sessions.get(sid);
  if (s && s.sessionState !== 'listening') {
    interjectionMode = true;
  }
  startRecording(sid);
}

function pttEnd(e) {
  if (inputMode !== 'voice' || !pttActive) return;
  e.preventDefault();
  pttActive = false;
  if (recording) {
    stopRecording();
  }
}

// PTT on mic button removed — mic button is click-to-toggle only.
// PTT is spacebar-only (see keydown/keyup handlers below).

// Spacebar PTT: hold Space to record, release to send (works in voice mode)
// Use capture phase to intercept Space before browser scrolls (critical for Firefox)
function _isTextTarget(el) {
  return el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable;
}
document.addEventListener('keydown', (e) => {
  if ((e.code !== 'Space' && e.key !== ' ') || e.repeat) return;
  if (_isTextTarget(e.target)) return;
  e.preventDefault();
  e.stopPropagation();
  if (inputMode !== 'voice') return;
  if (recording && !pttActive) { stopRecording(true); }
  pttStart(e);
}, true); // capture phase
document.addEventListener('keyup', (e) => {
  if (e.code !== 'Space' && e.key !== ' ') return;
  if (_isTextTarget(e.target)) return;
  e.preventDefault();
  e.stopPropagation();
  if (inputMode !== 'voice') return;
  pttEnd(e);
}, true); // capture phase
// Also capture keypress for Firefox legacy scroll
document.addEventListener('keypress', (e) => {
  if ((e.key === ' ' || e.code === 'Space') && !_isTextTarget(e.target)) {
    e.preventDefault();
  }
}, true); // capture phase

