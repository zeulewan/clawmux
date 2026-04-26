/**
 * ClawMux Voice — karaoke player hook.
 *
 * Manages Web Audio API playback + requestAnimationFrame word highlighting.
 * RAF loop directly sets CSS classes on DOM spans — no React state updates per word.
 * DOM word spans are injected/removed manually (message content doesn't re-render
 * for completed turns, so this is safe).
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
  const audioRef  = useRef(null); // { source, startTime, words: [{...ts, el}] }
  const activeIdx = useRef(-1);
  const msgElRef  = useRef(null); // DOM element with karaoke spans

  const stopPlayback = useCallback(() => {
    if (rafRef.current) { cancelAnimationFrame(rafRef.current); rafRef.current = null; }

    // Stop audio source
    if (audioRef.current?.source) {
      try { audioRef.current.source.onended = null; audioRef.current.source.stop(); } catch {}
    }

    // Remove active highlight
    if (activeIdx.current >= 0 && audioRef.current?.words) {
      audioRef.current.words[activeIdx.current]?.el?.classList.remove('karaoke-active');
    }

    // Unwrap all karaoke spans back to plain text
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

    // Find active word: last one whose start_time <= elapsed
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

    // Filter to real words (skip punctuation-only tokens)
    const realWords = rawWords.filter(w => /[\p{L}\p{N}]/u.test(w.word));

    // Inject karaoke spans into the message DOM element
    const msgEl = msgId ? document.querySelector(`[data-msg-id="${CSS.escape(msgId)}"]`) : null;
    if (msgEl) {
      msgElRef.current = msgEl;
      _injectKaraokeSpans(msgEl);
      _matchWordSpans(realWords, msgEl.querySelectorAll('.karaoke-word'));
    }

    setSpeaking(msgId, realWords);

    const source = ctx.createBufferSource();
    source.buffer = decoded;
    source.connect(ctx.destination);

    audioRef.current = { source, startTime: ctx.currentTime, words: realWords };
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

  useEffect(() => () => stopPlayback(), [stopPlayback]);

  return { play, stop: stopPlayback, pause, resume };
}

// ---------------------------------------------------------------------------
// DOM helpers
// ---------------------------------------------------------------------------

const SKIP_TAGS = new Set(['CODE', 'PRE', 'SCRIPT', 'STYLE', 'KBD', 'MATH']);

/**
 * Walk all text nodes in msgEl (skipping code/pre) and wrap each word
 * in <span class="karaoke-word">. Words are runs of non-whitespace chars.
 */
function _injectKaraokeSpans(msgEl) {
  const walker = document.createTreeWalker(msgEl, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      // Skip text inside code/pre/etc.
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
    // Split by whitespace runs, preserving whitespace as text nodes
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

/**
 * Remove all .karaoke-word spans, replacing each with its text content.
 */
function _unwrapKaraokeSpans(msgEl) {
  const spans = msgEl.querySelectorAll('.karaoke-word');
  for (const span of spans) {
    span.replaceWith(document.createTextNode(span.textContent));
  }
  // Normalize adjacent text nodes
  try { msgEl.normalize(); } catch {}
}

/**
 * Match TTS word timestamps to DOM spans by text content.
 * Attaches .el ref to each matched word object.
 */
function _matchWordSpans(words, spans) {
  if (!spans.length || !words.length) return;
  let wordIdx = 0;

  for (const span of spans) {
    if (wordIdx >= words.length) break;
    const spanText = span.textContent.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
    if (!spanText) continue;

    // Try matching within a small lookahead window first
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
    // Wider fallback for gaps caused by code blocks or TTS-specific symbol pronunciation
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
