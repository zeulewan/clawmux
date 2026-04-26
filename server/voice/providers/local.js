/**
 * ClawMux Voice — Local provider (Kokoro TTS + whisper.cpp STT).
 *
 * Kokoro:  HTTP server, OpenAI-compatible TTS endpoints.
 * Whisper: whisper.cpp HTTP server, OpenAI-compatible /v1/audio/transcriptions.
 */

import { homedir } from 'os';

const KOKORO_URL = process.env.CLAWMUX_KOKORO_URL || 'http://127.0.0.1:8880';
const WHISPER_URL = process.env.CLAWMUX_WHISPER_URL || 'http://127.0.0.1:2022';

// ---------------------------------------------------------------------------
// TTS — plain audio
// ---------------------------------------------------------------------------

/**
 * @param {string} text  Plain text (already stripped of markdown)
 * @param {object} opts  { voice, speed }
 * @returns {Promise<Buffer>} MP3 bytes
 */
export async function tts(text, { voice = 'af_sky', speed = 1.0 } = {}) {
  const lastErr = await _retry(3, async () => {
    const res = await fetch(`${KOKORO_URL}/v1/audio/speech`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'tts-1', input: text, voice, response_format: 'mp3', speed }),
    });
    if (!res.ok) throw new Error(`Kokoro TTS ${res.status}: ${await res.text()}`);
    return Buffer.from(await res.arrayBuffer());
  });
  return lastErr; // _retry returns value on success, throws on exhaustion
}

// ---------------------------------------------------------------------------
// TTS — captioned (with word timestamps for karaoke)
// ---------------------------------------------------------------------------

/**
 * @returns {Promise<{ audio_b64: string, words: Array<{word,start_time,end_time}> }>}
 */
export async function ttsCaptioned(text, { voice = 'af_sky', speed = 1.0 } = {}) {
  // At higher speeds Kokoro clips the first word. Prepend a dummy prefix so
  // the real content starts after the warmup, then strip it from the result.
  let prefix = null;
  if (speed >= 2.0)      prefix = 'Hmm, well,';
  else if (speed >= 1.5) prefix = 'Hmm,';
  const input = prefix ? `${prefix} ${text}` : text;

  const result = await _retry(3, async () => {
    const res = await fetch(`${KOKORO_URL}/dev/captioned_speech`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        input,
        voice,
        speed,
        stream: false,
        return_timestamps: true,
        response_format: 'wav',
      }),
    });
    if (!res.ok) throw new Error(`Kokoro captioned ${res.status}: ${await res.text()}`);
    return res.json();
  });

  let { audio: audio_b64, timestamps: words = [] } = result;

  if (prefix && words.length) {
    ({ audio_b64, words } = _stripPrefixAudio(audio_b64, words, prefix));
  }

  return { audio_b64, words };
}

// ---------------------------------------------------------------------------
// STT — speech to text
// ---------------------------------------------------------------------------

// Whisper hallucinations to always suppress
const HALLUCINATIONS_ALWAYS = new Set([
  'thanks for watching', 'thank you for watching',
  'please like, comment, and subscribe', 'please subscribe',
  'subscribe to my channel', 'please like and subscribe',
  'thank you for watching and i\'ll see you in the next one',
]);
// Short hallucinations only suppressed for short/silent audio
const HALLUCINATIONS_SHORT = new Set(['thank you', 'thanks', 'you', '.']);
const MIN_AUDIO_BYTES = 8000; // ~0.5s of real speech

/**
 * @param {Buffer} audioBuffer  Raw audio bytes (webm/wav/mp3)
 * @returns {Promise<string>}  Transcribed text, empty string if silence/hallucination
 */
export async function stt(audioBuffer) {
  const text = await _retry(3, async () => {
    const form = new FormData();
    form.append('file', new Blob([audioBuffer], { type: 'audio/webm' }), 'recording.webm');
    form.append('model', 'whisper-1');
    form.append('response_format', 'json');

    const prompt = _getSttPrompt();
    if (prompt) form.append('prompt', prompt);

    const res = await fetch(`${WHISPER_URL}/v1/audio/transcriptions`, {
      method: 'POST',
      body: form,
    });
    if (!res.ok) throw new Error(`Whisper STT ${res.status}: ${await res.text()}`);
    const data = await res.json();
    return (data.text || '').trim();
  });

  if (_isHallucination(text, audioBuffer.length)) return '';
  return text;
}

// ---------------------------------------------------------------------------
// Health check
// ---------------------------------------------------------------------------

export async function health() {
  const [kokoroOk, whisperOk] = await Promise.all([
    fetch(`${KOKORO_URL}/v1/models`).then(r => r.ok).catch(() => false),
    fetch(`${WHISPER_URL}/health`).then(r => r.ok).catch(() => false),
  ]);
  return { tts: kokoroOk, stt: whisperOk };
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

async function _retry(n, fn) {
  let lastErr;
  for (let i = 0; i < n; i++) {
    try { return await fn(); } catch (e) {
      lastErr = e;
      if (i < n - 1) await _sleep(1000 * (i + 1));
    }
  }
  throw lastErr;
}

function _sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function _getSttPrompt() {
  return process.env.CLAWMUX_STT_PROMPT || '';
}

function _isHallucination(text, audioSize) {
  const norm = text.toLowerCase().replace(/[ .!?,]+$/, '');
  if (HALLUCINATIONS_ALWAYS.has(norm)) return true;
  if (audioSize < MIN_AUDIO_BYTES && HALLUCINATIONS_SHORT.has(norm)) return true;
  return false;
}

/**
 * Strip the prefix warmup from audio bytes and word timestamps.
 * Returns { audio_b64, words } with prefix removed and times adjusted.
 */
function _stripPrefixAudio(audio_b64, timestamps, prefix) {
  const prefixTokens = new Set(prefix.toLowerCase().match(/\w+|[^\w\s]/g) || []);
  let cutIdx = 0;
  for (let i = 0; i < timestamps.length; i++) {
    const w = timestamps[i].word.trim().toLowerCase();
    if (prefixTokens.has(w) || /^[.,!?;:\-—]+$/.test(w) || w === '') {
      cutIdx = i + 1;
    } else {
      break;
    }
  }
  if (cutIdx === 0) return { audio_b64, words: timestamps };

  const cutTime = Math.max(0, (timestamps[cutIdx]?.start_time ?? 0) - 0.05);
  const raw = Buffer.from(audio_b64, 'base64');

  // Parse WAV header
  if (raw.toString('ascii', 0, 4) !== 'RIFF' || raw.toString('ascii', 8, 12) !== 'WAVE') {
    return { audio_b64, words: timestamps };
  }

  let pos = 12, sampleRate = 24000, bitsPerSample = 16, numChannels = 1, dataStart = 0, fmtChunk = null;
  while (pos < raw.length - 8) {
    const id = raw.toString('ascii', pos, pos + 4);
    const size = raw.readUInt32LE(pos + 4);
    if (id === 'fmt ') {
      numChannels = raw.readUInt16LE(pos + 10);
      sampleRate = raw.readUInt32LE(pos + 12);
      bitsPerSample = raw.readUInt16LE(pos + 22);
      fmtChunk = raw.slice(pos, pos + 8 + size);
    } else if (id === 'data') {
      dataStart = pos + 8;
      break;
    }
    pos += 8 + size + (size % 2);
  }
  if (!dataStart || !fmtChunk) return { audio_b64, words: timestamps };

  const frameSize = numChannels * (bitsPerSample / 8);
  const cutBytes = Math.floor(cutTime * sampleRate) * frameSize;
  const pcm = raw.slice(dataStart);
  if (cutBytes >= pcm.length) return { audio_b64, words: timestamps };

  const trimmedPcm = pcm.slice(cutBytes);
  const wav = Buffer.concat([
    Buffer.from('RIFF'), _u32le(trimmedPcm.length + fmtChunk.length + 8 + 4),
    Buffer.from('WAVE'), fmtChunk,
    Buffer.from('data'), _u32le(trimmedPcm.length), trimmedPcm,
  ]);

  const shifted = timestamps.slice(cutIdx).map(ts => ({
    ...ts,
    start_time: Math.max(0, ts.start_time - cutTime),
    end_time: ts.end_time - cutTime,
  }));

  return { audio_b64: wav.toString('base64'), words: shifted };
}

function _u32le(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n, 0);
  return b;
}
