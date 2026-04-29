/**
 * ClawMux Voice — karaoke player hook.
 *
 * Ported faithfully from v0.8.0 audio.js:
 * - RAF loop uses range-based timing (start_time ≤ elapsed < end_time)
 * - Only iterates words that have a matched DOM span (.el)
 * - Active class is `.active` on `.karaoke-word` spans (matches v0.8 CSS)
 * - Pause does NOT suspend AudioContext — stores offset, stops source, resumes
 *   by creating a new source. AudioContext stays running so auto-play works.
 */

import { useRef, useCallback, useEffect } from 'react';
import { setSpeaking, stopSpeaking, setPaused } from '../state/voice.js';

// Shared AudioContext — created once, reused across playbacks
let _audioCtx = null;
function getAudioCtx() {
  if (!_audioCtx || _audioCtx.state === 'closed') {
    _audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  }
  return _audioCtx;
}

/**
 * Unlock AudioContext during a user gesture so subsequent auto-play works.
 * Also wires a one-time document touchstart/click handler as belt-and-suspenders
 * for mobile browsers that auto-suspend on page load.
 */
export function unlockAudioContext() {
  const ctx = getAudioCtx();
  // Resume if suspended
  if (ctx.state === 'suspended') ctx.resume().catch(() => {});
  // Start+stop a silent 1-sample buffer — required on iOS/Safari to truly unlock
  try {
    const buf = ctx.createBuffer(1, 1, 22050);
    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.connect(ctx.destination);
    src.start(0);
  } catch {}
}

// Belt-and-suspenders: unlock on first user interaction anywhere on the page
function _installGlobalUnlock() {
  const unlock = () => {
    unlockAudioContext();
    document.removeEventListener('touchstart', unlock, true);
    document.removeEventListener('mousedown', unlock, true);
  };
  document.addEventListener('touchstart', unlock, { capture: true, passive: true });
  document.addEventListener('mousedown', unlock, { capture: true, passive: true });
}
_installGlobalUnlock();

export function useKaraokePlayer() {
  const rafRef    = useRef(null);
  const audioRef  = useRef(null); // { source, buffer, startTime, words: [{...ts, el}] }
  const pauseRef  = useRef(null); // { buffer, offset, words } saved across pause
  const activeIdx = useRef(-1);
  const msgElRef  = useRef(null);
  const seekRef   = useRef(null);

  // ── Stop all playback and clean up DOM ──────────────────────────────────
  const stopPlayback = useCallback(() => {
    if (rafRef.current) { cancelAnimationFrame(rafRef.current); rafRef.current = null; }

    if (audioRef.current?.source) {
      try { audioRef.current.source.onended = null; audioRef.current.source.stop(); } catch {}
    }

    // Remove active class from current word
    if (activeIdx.current >= 0 && audioRef.current?.words) {
      audioRef.current.words[activeIdx.current]?.el?.classList.remove('active');
    }

    if (msgElRef.current) _unwrapKaraokeSpans(msgElRef.current);
    msgElRef.current = null;

    audioRef.current = null;
    pauseRef.current = null;
    activeIdx.current = -1;
    stopSpeaking();
  }, []);

  // ── RAF loop — mirrors v0.8.0 _karaokeFrame exactly ────────────────────
  const tick = useCallback(() => {
    const a = audioRef.current;
    if (!a) return; // stopped — don't reschedule

    const elapsed = getAudioCtx().currentTime - a.startTime;

    // Only iterate words with matched spans (activeWords)
    let newIdx = -1;
    for (let i = 0; i < a.words.length; i++) {
      const w = a.words[i];
      if (elapsed >= w.start_time && elapsed < w.end_time) { newIdx = i; break; }
    }

    // Only update on positive match — keeps previous word lit during inter-word gaps
    if (newIdx >= 0 && newIdx !== activeIdx.current) {
      if (activeIdx.current >= 0) a.words[activeIdx.current]?.el?.classList.remove('active');
      a.words[newIdx].el.classList.add('active');
      activeIdx.current = newIdx;
    }

    rafRef.current = requestAnimationFrame(tick);
  }, []);

  // ── Seek to absolute time offset ────────────────────────────────────────
  const seek = useCallback((time) => {
    const a = audioRef.current || (pauseRef.current ? { ...pauseRef.current, source: null } : null);
    if (!a?.buffer) return;

    if (rafRef.current) { cancelAnimationFrame(rafRef.current); rafRef.current = null; }
    if (activeIdx.current >= 0 && audioRef.current?.words) {
      audioRef.current.words[activeIdx.current]?.el?.classList.remove('active');
    }
    activeIdx.current = -1;
    try { audioRef.current?.source?.onended && (audioRef.current.source.onended = null); audioRef.current?.source?.stop(); } catch {}

    const ctx = getAudioCtx();
    const clampedTime = Math.max(0, Math.min(time, a.buffer.duration - 0.01));
    const source = ctx.createBufferSource();
    source.buffer = a.buffer;
    source.connect(ctx.destination);

    const startTime = ctx.currentTime - clampedTime;
    audioRef.current = { source, buffer: a.buffer, startTime, words: a.words };
    pauseRef.current = null;

    source.onended = () => setTimeout(stopPlayback, 400);
    source.start(0, clampedTime);
    setPaused(false);
    rafRef.current = requestAnimationFrame(tick);
  }, [tick, stopPlayback]);

  useEffect(() => { seekRef.current = seek; }, [seek]);

  // ── Play ─────────────────────────────────────────────────────────────────
  const play = useCallback(async (audio_b64, rawWords, msgId) => {
    stopPlayback();

    const ctx = getAudioCtx();
    if (ctx.state === 'suspended') {
      try { await ctx.resume(); } catch (e) { console.error('[karaoke] ctx.resume failed:', e); }
    }

    let decoded;
    try {
      const bytes = Uint8Array.from(atob(audio_b64), c => c.charCodeAt(0));
      decoded = await ctx.decodeAudioData(bytes.buffer);
    } catch (e) {
      console.error('[karaoke] decodeAudioData failed:', e);
      return;
    }

    // Filter to words that contain at least one letter/number
    const realWords = rawWords.filter(w => /[\p{L}\p{N}]/u.test(w.word));

    const msgEl = msgId ? document.querySelector(`[data-msg-id="${CSS.escape(msgId)}"]`) : null;
    if (msgEl) {
      msgElRef.current = msgEl;
      _injectKaraokeSpans(msgEl);
      _matchWordSpans(realWords, msgEl.querySelectorAll('.karaoke-word'));
      _addSeekHandlers(realWords, (t) => seekRef.current?.(t));
    }

    // Only track words that have a matched span — mirrors v0.8.0 activeWords filter
    const activeWords = realWords.filter(w => w.el);

    setSpeaking(msgId, realWords);

    const source = ctx.createBufferSource();
    source.buffer = decoded;
    source.connect(ctx.destination);

    audioRef.current = { source, buffer: decoded, startTime: ctx.currentTime, words: activeWords };
    activeIdx.current = -1;

    source.onended = () => setTimeout(stopPlayback, 400);
    try {
      source.start(0);
    } catch (e) {
      console.error('[karaoke] source.start failed:', e, 'ctx.state:', ctx.state);
      return;
    }
    rafRef.current = requestAnimationFrame(tick);
  }, [stopPlayback, tick]);

  // ── Pause — stops source, stores offset. Does NOT suspend AudioContext. ──
  const pause = useCallback(() => {
    const a = audioRef.current;
    if (!a) return;
    if (rafRef.current) { cancelAnimationFrame(rafRef.current); rafRef.current = null; }

    const ctx = getAudioCtx();
    const offset = ctx.currentTime - a.startTime;

    try { a.source.onended = null; a.source.stop(); } catch {}

    // Save state for resume
    pauseRef.current = { buffer: a.buffer, offset, words: a.words };
    audioRef.current = null;
    setPaused(true);
    // AudioContext stays running — no ctx.suspend()
  }, []);

  // ── Resume — creates new source from saved offset ────────────────────────
  const resume = useCallback(() => {
    const p = pauseRef.current;
    if (!p) return;

    const ctx = getAudioCtx();
    const source = ctx.createBufferSource();
    source.buffer = p.buffer;
    source.connect(ctx.destination);

    const clampedOffset = Math.max(0, Math.min(p.offset, p.buffer.duration - 0.01));
    const startTime = ctx.currentTime - clampedOffset;
    audioRef.current = { source, buffer: p.buffer, startTime, words: p.words };
    pauseRef.current = null;

    source.onended = () => setTimeout(stopPlayback, 400);
    source.start(0, clampedOffset);
    setPaused(false);
    rafRef.current = requestAnimationFrame(tick);
  }, [tick, stopPlayback]);

  const replay = useCallback(() => seek(0), [seek]);

  useEffect(() => () => stopPlayback(), [stopPlayback]);

  return { play, stop: stopPlayback, pause, resume, seek, replay };
}

// ---------------------------------------------------------------------------
// DOM helpers
// ---------------------------------------------------------------------------

const SKIP_TAGS = new Set(['CODE', 'PRE', 'SCRIPT', 'STYLE', 'KBD', 'MATH']);

function _injectKaraokeSpans(msgEl) {
  const walker = document.createTreeWalker(msgEl, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      let p = node.parentElement;
      while (p && p !== msgEl) {
        if (SKIP_TAGS.has(p.tagName)) return NodeFilter.FILTER_REJECT;
        p = p.parentElement;
      }
      return node.textContent.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
    },
  });

  const textNodes = [];
  let node;
  while ((node = walker.nextNode())) textNodes.push(node);

  for (const textNode of textNodes) {
    const text = textNode.textContent;
    if (!text.trim()) continue;

    const frag = document.createDocumentFragment();
    const parts = text.split(/(\s+)/);
    for (const part of parts) {
      if (/^\s+$/.test(part)) {
        frag.appendChild(document.createTextNode(part));
      } else if (part) {
        const span = document.createElement('span');
        span.className = 'karaoke-word';
        span.textContent = part;
        frag.appendChild(span);
      }
    }
    textNode.replaceWith(frag);
  }
}

function _unwrapKaraokeSpans(msgEl) {
  const spans = msgEl.querySelectorAll('.karaoke-word');
  for (const span of spans) {
    span.replaceWith(document.createTextNode(span.textContent));
  }
  try { msgEl.normalize(); } catch {}
}

function _matchWordSpans(words, spans) {
  if (!spans.length || !words.length) return;
  let wordIdx = 0;

  for (const span of spans) {
    if (wordIdx >= words.length) break;
    const spanText = span.textContent.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
    if (!spanText) continue;

    const limit = Math.min(wordIdx + 8, words.length);
    let matched = false;
    for (let i = wordIdx; i < limit; i++) {
      const wText = words[i].word.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
      if (!wText) continue;
      if (spanText === wText || spanText.startsWith(wText) || wText.startsWith(spanText)) {
        words[i].el = span;
        wordIdx = i + 1;
        matched = true;
        break;
      }
    }
    if (!matched) {
      const wide = Math.min(wordIdx + 200, words.length);
      for (let i = limit; i < wide; i++) {
        const wText = words[i].word.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
        if (!wText) continue;
        if (spanText === wText || spanText.startsWith(wText) || wText.startsWith(spanText)) {
          words[i].el = span;
          wordIdx = i + 1;
          break;
        }
      }
    }
  }
}

function _addSeekHandlers(words, seekFn) {
  for (const word of words) {
    if (!word.el) continue;
    word.el.style.cursor = 'pointer';
    word.el.onclick = () => seekFn(word.start_time);
  }
}
