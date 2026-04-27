/**
 * ClawMux Voice — karaoke player hook.
 *
 * Manages Web Audio API playback + requestAnimationFrame word highlighting.
 * RAF loop directly sets CSS classes on DOM spans — no React state updates per word.
 * DOM word spans are injected/removed manually (message content doesn't re-render
 * for completed turns, so this is safe).
 *
 * Supports seek-by-click: clicking any highlighted word seeks to that timestamp.
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

export function useKaraokePlayer() {
  const rafRef    = useRef(null);
  // audioRef: { source, buffer, startTime, words: [{...ts, el}] }
  const audioRef  = useRef(null);
  const activeIdx = useRef(-1);
  const msgElRef  = useRef(null);
  const seekRef   = useRef(null); // kept current so play() can close over it

  const stopPlayback = useCallback(() => {
    if (rafRef.current) { cancelAnimationFrame(rafRef.current); rafRef.current = null; }

    if (audioRef.current?.source) {
      try { audioRef.current.source.onended = null; audioRef.current.source.stop(); } catch {}
    }

    if (activeIdx.current >= 0 && audioRef.current?.words) {
      audioRef.current.words[activeIdx.current]?.el?.classList.remove('karaoke-active');
    }

    if (msgElRef.current) _unwrapKaraokeSpans(msgElRef.current);
    msgElRef.current = null;

    audioRef.current = null;
    activeIdx.current = -1;
    stopSpeaking();
  }, []);

  const tick = useCallback(() => {
    const a = audioRef.current;
    if (!a || !a.words.length) return;

    const elapsed = getAudioCtx().currentTime - a.startTime;

    let newIdx = -1;
    for (let i = 0; i < a.words.length; i++) {
      if (elapsed >= a.words[i].start_time) newIdx = i;
      else break;
    }

    if (newIdx !== activeIdx.current) {
      if (activeIdx.current >= 0) a.words[activeIdx.current]?.el?.classList.remove('karaoke-active');
      if (newIdx >= 0)            a.words[newIdx]?.el?.classList.add('karaoke-active');
      activeIdx.current = newIdx;
    }

    rafRef.current = requestAnimationFrame(tick);
  }, []);

  /** Seek to a specific time offset (seconds) within the current audio. */
  const seek = useCallback((time) => {
    const a = audioRef.current;
    if (!a?.buffer) return;

    // Cancel RAF + stop current source
    if (rafRef.current) { cancelAnimationFrame(rafRef.current); rafRef.current = null; }
    if (activeIdx.current >= 0) a.words[activeIdx.current]?.el?.classList.remove('karaoke-active');
    activeIdx.current = -1;
    try { a.source.onended = null; a.source.stop(); } catch {}

    const ctx = getAudioCtx();
    if (ctx.state === 'suspended') ctx.resume();

    const source = ctx.createBufferSource();
    source.buffer = a.buffer;
    source.connect(ctx.destination);

    const clampedTime = Math.max(0, Math.min(time, a.buffer.duration - 0.01));
    // startTime is adjusted so elapsed = clampedTime at ctx.currentTime
    const startTime = ctx.currentTime - clampedTime;
    audioRef.current = { ...a, source, startTime };

    source.onended = () => setTimeout(stopPlayback, 400);
    source.start(0, clampedTime);
    setPaused(false);
    rafRef.current = requestAnimationFrame(tick);
  }, [tick, stopPlayback]);

  // Keep seekRef current so play() can safely reference it via closure
  useEffect(() => { seekRef.current = seek; }, [seek]);

  /**
   * Play audio with karaoke highlighting.
   * @param {string} audio_b64  Base64 WAV from /api/tts-captioned
   * @param {Array}  rawWords   [{word, start_time, end_time}] from Kokoro
   * @param {string} msgId      Message _uuid — used to find the DOM element
   */
  const play = useCallback(async (audio_b64, rawWords, msgId) => {
    stopPlayback();

    const ctx = getAudioCtx();
    if (ctx.state === 'suspended') await ctx.resume();

    const bytes = Uint8Array.from(atob(audio_b64), c => c.charCodeAt(0));
    const decoded = await ctx.decodeAudioData(bytes.buffer);

    const realWords = rawWords.filter(w => /[\p{L}\p{N}]/u.test(w.word));

    const msgEl = msgId ? document.querySelector(`[data-msg-id="${CSS.escape(msgId)}"]`) : null;
    if (msgEl) {
      msgElRef.current = msgEl;
      _injectKaraokeSpans(msgEl);
      _matchWordSpans(realWords, msgEl.querySelectorAll('.karaoke-word'));
      // Attach click-to-seek handlers — delegate through seekRef so no circular dep
      _addSeekHandlers(realWords, (t) => seekRef.current?.(t));
    }

    setSpeaking(msgId, realWords);

    const source = ctx.createBufferSource();
    source.buffer = decoded;
    source.connect(ctx.destination);

    audioRef.current = { source, buffer: decoded, startTime: ctx.currentTime, words: realWords };
    activeIdx.current = -1;

    source.onended = () => setTimeout(stopPlayback, 400);
    source.start(0);
    rafRef.current = requestAnimationFrame(tick);
  }, [stopPlayback, tick]);

  const pause = useCallback(() => {
    if (rafRef.current) { cancelAnimationFrame(rafRef.current); rafRef.current = null; }
    const ctx = getAudioCtx();
    if (ctx.state === 'running') ctx.suspend();
    setPaused(true);
  }, []);

  const resume = useCallback(() => {
    const ctx = getAudioCtx();
    if (ctx.state === 'suspended') ctx.resume();
    setPaused(false);
    rafRef.current = requestAnimationFrame(tick);
  }, [tick]);

  /** Restart current audio from the beginning. */
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

/** Attach click-to-seek handlers to matched word spans. */
function _addSeekHandlers(words, seekFn) {
  for (const word of words) {
    if (!word.el) continue;
    word.el.style.cursor = 'pointer';
    word.el.onclick = () => seekFn(word.start_time);
  }
}
