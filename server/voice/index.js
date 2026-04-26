/**
 * ClawMux Voice — Provider router + Express routes.
 *
 * Routes:
 *   POST /api/tts            → MP3 audio bytes
 *   POST /api/tts-captioned  → { audio_b64, words }
 *   POST /api/stt            → { text }
 *   GET  /api/voice/health   → { tts, stt, provider }
 *   GET  /api/voice/settings → { voice, speed, sttProvider, kokoroUrl, whisperUrl }
 *   POST /api/voice/settings → save settings
 */

import { Router } from 'express';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
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
// Voice settings persistence
// ---------------------------------------------------------------------------

const VOICE_SETTINGS_PATH = join(homedir(), '.clawmux', 'voice.json');

function readVoiceSettings() {
  try {
    if (existsSync(VOICE_SETTINGS_PATH)) {
      return JSON.parse(readFileSync(VOICE_SETTINGS_PATH, 'utf8'));
    }
  } catch {}
  return {};
}

function writeVoiceSettings(settings) {
  mkdirSync(join(homedir(), '.clawmux'), { recursive: true });
  writeFileSync(VOICE_SETTINGS_PATH, JSON.stringify(settings, null, 2));
}

// ---------------------------------------------------------------------------
// Express router
// ---------------------------------------------------------------------------

export const voiceRouter = Router();

voiceRouter.get('/api/voice/settings', (req, res) => {
  const defaults = {
    voice: 'af_sky',
    speed: 1.0,
    sttProvider: 'local',
    kokoroUrl: process.env.CLAWMUX_KOKORO_URL || 'http://127.0.0.1:8880',
    whisperUrl: process.env.CLAWMUX_WHISPER_URL || 'http://127.0.0.1:2022',
  };
  res.json({ ...defaults, ...readVoiceSettings() });
});

voiceRouter.post('/api/voice/settings', (req, res) => {
  const allowed = ['voice', 'speed', 'sttProvider', 'kokoroUrl', 'whisperUrl'];
  const update = {};
  for (const k of allowed) {
    if (req.body[k] !== undefined) update[k] = req.body[k];
  }
  const current = readVoiceSettings();
  const merged = { ...current, ...update };
  writeVoiceSettings(merged);
  res.json({ ok: true, settings: merged });
});

voiceRouter.post('/api/tts', async (req, res) => {
  const saved = readVoiceSettings();
  const { text, voice = saved.voice || 'af_sky', speed = saved.speed || 1.0 } = req.body || {};
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
  const saved = readVoiceSettings();
  const { text, voice = saved.voice || 'af_sky', speed = saved.speed || 1.0 } = req.body || {};
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
