/**
 * ClawMux Voice — Provider router + Express routes.
 *
 * Routes:
 *   POST /api/tts            → MP3 audio bytes
 *   POST /api/tts-captioned  → { audio_b64, words }
 *   POST /api/stt            → { text }
 *   GET  /api/voice/health   → { tts, stt, provider }
 */

import { Router } from 'express';
import { stripNonSpeakable } from './text.js';
import * as localProvider from './providers/local.js';

// ---------------------------------------------------------------------------
// Provider selection (extensible for xAI, ElevenLabs, etc.)
// ---------------------------------------------------------------------------

const PROVIDERS = { local: localProvider };

function getProvider() {
  const name = process.env.CLAWMUX_VOICE_PROVIDER || 'local';
  return PROVIDERS[name] || localProvider;
}

// ---------------------------------------------------------------------------
// Express router
// ---------------------------------------------------------------------------

export const voiceRouter = Router();

voiceRouter.post('/api/tts', async (req, res) => {
  const { text, voice, speed } = req.body || {};
  if (!text?.trim()) return res.status(400).json({ error: 'no text' });
  try {
    const audio = await getProvider().tts(stripNonSpeakable(text), { voice, speed });
    res.set('Content-Type', 'audio/mpeg').send(audio);
  } catch (e) {
    console.error('[voice] TTS error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

voiceRouter.post('/api/tts-captioned', async (req, res) => {
  const { text, voice, speed } = req.body || {};
  if (!text?.trim()) return res.status(400).json({ error: 'no text' });
  try {
    const result = await getProvider().ttsCaptioned(stripNonSpeakable(text), { voice, speed });
    res.json(result);
  } catch (e) {
    console.error('[voice] TTS captioned error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

voiceRouter.post('/api/stt', async (req, res) => {
  const audio = req.body;
  if (!audio || audio.length < 100) return res.json({ text: '' });
  try {
    const text = await getProvider().stt(audio);
    res.json({ text });
  } catch (e) {
    console.error('[voice] STT error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

voiceRouter.get('/api/voice/health', async (req, res) => {
  try {
    const name = process.env.CLAWMUX_VOICE_PROVIDER || 'local';
    const status = await getProvider().health();
    res.json({ provider: name, ...status });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});
