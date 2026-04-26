/**
 * ClawMux Voice — Text processing utilities.
 * Strips markdown to plain speech-friendly text and applies pronunciation overrides.
 */

import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PRONUNCIATION_PATH = join(__dirname, 'pronunciation.json');

function loadPronunciation() {
  try {
    if (!existsSync(PRONUNCIATION_PATH)) return { overrides: {}, patterns: [] };
    const data = JSON.parse(readFileSync(PRONUNCIATION_PATH, 'utf8'));
    return {
      overrides: data.overrides || {},
      patterns: (data.patterns || []).map(p => ({
        find: new RegExp(p.find, 'g'),
        replace: p.replace,
      })),
    };
  } catch {
    return { overrides: {}, patterns: [] };
  }
}

export function applyPronunciation(text) {
  // Always re-read from disk so edits take effect immediately
  const { overrides, patterns } = loadPronunciation();
  for (const [word, replacement] of Object.entries(overrides)) {
    text = text.replace(new RegExp(word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), replacement);
  }
  for (const { find, replace } of patterns) {
    text = text.replace(find, replace);
  }
  return text;
}

/**
 * Convert markdown to plain text suitable for TTS.
 * Strips formatting symbols Kokoro would otherwise read aloud.
 */
export function stripNonSpeakable(text) {
  // Remove fenced code blocks entirely (including content — don't read raw code aloud)
  text = text.replace(/```[\w]*\n[\s\S]*?```/g, '');
  // Catch unclosed or single-line fence markers
  text = text.replace(/```\w*\n?/g, '');
  // Remove display math
  text = text.replace(/\$\$[\s\S]*?\$\$/g, '');
  // Remove inline math
  text = text.replace(/\$([^\$\n]+?)\$/g, '');
  // Remove LaTeX delimiters
  text = text.replace(/\\\[[\s\S]*?\\\]/g, '');
  text = text.replace(/\\\([\s\S]*?\\\)/g, '');
  // Remove inline code backticks but keep text
  text = text.replace(/`([^`]+)`/g, '$1');
  // Remove images — keep alt text
  text = text.replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1');
  // Remove links — keep display text
  text = text.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
  // Remove HTML tags
  text = text.replace(/<[^>]+>/g, '');
  // Remove heading markers
  text = text.replace(/^#{1,6}\s+/gm, '');
  // Remove horizontal rules
  text = text.replace(/^[\s]*[-*_]{3,}\s*$/gm, '');
  // Remove bold/italic but keep text
  text = text.replace(/\*{1,3}([^*]+)\*{1,3}/g, '$1');
  text = text.replace(/_{1,3}([^_]+)_{1,3}/g, '$1');
  // Remove blockquote markers
  text = text.replace(/^>\s?/gm, '');
  // Remove table separator rows
  text = text.replace(/^\|[\s\-:|]+\|\s*$/gm, '');
  // Convert table rows to comma-separated
  text = text.replace(/^\|(.+)\|\s*$/gm, (_, row) =>
    row.split('|').map(c => c.trim()).filter(Boolean).join(', ')
  );
  // Remove bullet markers
  text = text.replace(/^[\s]*[-*+]\s+/gm, '');
  // Remove numbered list markers
  text = text.replace(/^[\s]*\d+\.\s+/gm, '');
  // Collapse multiple blank lines
  text = text.replace(/\n{3,}/g, '\n\n');
  text = applyPronunciation(text);
  return text.trim();
}
