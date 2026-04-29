/**
 * Claude CLI session discovery — find and read session .jsonl files
 */

import { existsSync, readFileSync, readdirSync, statSync, openSync, readSync, closeSync } from 'fs';
import { getDefaultBackend } from './config.js';
import { join } from 'path';
import { homedir } from 'os';

const CLAUDE_CONFIG_DIR = (process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude')).normalize('NFC');
const CLAUDE_PROJECTS_DIR = join(CLAUDE_CONFIG_DIR, 'projects');
const PI_SESSIONS_DIR = join(process.env.PI_CODING_AGENT_DIR || join(homedir(), '.pi', 'agent'), 'sessions');
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function hashProjectPath(p) {
  const MAX_LEN = 200;
  const sanitized = p.replace(/[^a-zA-Z0-9]/g, '-');
  if (sanitized.length <= MAX_LEN) return sanitized;
  let hash = 0;
  for (let i = 0; i < p.length; i++) {
    hash = ((hash << 5) - hash + p.charCodeAt(i)) | 0;
  }
  return `${sanitized.slice(0, MAX_LEN)}-${Math.abs(hash).toString(36)}`;
}

function readHeadTail(filePath) {
  const CHUNK = 65536;
  try {
    const fd = openSync(filePath, 'r');
    try {
      const stat = statSync(filePath);
      if (stat.size <= CHUNK * 2) return readFileSync(filePath, 'utf8');
      const headBuf = Buffer.alloc(CHUNK);
      const tailBuf = Buffer.alloc(CHUNK);
      readSync(fd, headBuf, 0, CHUNK, 0);
      readSync(fd, tailBuf, 0, CHUNK, stat.size - CHUNK);
      return headBuf.toString('utf8') + '\n...\n' + tailBuf.toString('utf8');
    } finally {
      closeSync(fd);
    }
  } catch {
    return '';
  }
}

export function listClaudeCliSessions(cwd) {
  const hashed = hashProjectPath(cwd);
  const projectDir = join(CLAUDE_PROJECTS_DIR, hashed);
  if (!existsSync(projectDir)) return [];
  const sessions = [];
  for (const file of readdirSync(projectDir)) {
    if (!file.endsWith('.jsonl')) continue;
    const sessionId = file.replace('.jsonl', '');
    if (!UUID_RE.test(sessionId)) continue;
    const filePath = join(projectDir, file);
    const stat = statSync(filePath);
    const content = readHeadTail(filePath);
    let summary = 'Untitled';
    const lines = content.split('\n').filter(Boolean);
    // Scan in reverse for summary lines first (renames append to end)
    let foundSummary = false;
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const obj = JSON.parse(lines[i]);
        if (obj.type === 'summary' && obj.summary) {
          summary = obj.summary;
          foundSummary = true;
          break;
        }
      } catch {}
    }
    // Fall back to first user message if no explicit summary
    if (!foundSummary) {
      for (const line of lines) {
        try {
          const obj = JSON.parse(line);
          if (obj.message?.role === 'user') {
            let text = '';
            const c = obj.message.content;
            if (typeof c === 'string') {
              text = c;
            } else if (Array.isArray(c)) {
              text = c.map((b) => b.text || '').join('');
            }
            text = text.replace(/<[^>]+>/g, '').trim();
            if (text) {
              summary = text.slice(0, 80);
              break;
            }
          }
        } catch {}
      }
    }
    // Detect provider from session_meta line
    let provider = getDefaultBackend();
    for (const line of lines) {
      try {
        const obj = JSON.parse(line);
        if (obj.type === 'session_meta' && obj.provider) {
          provider = obj.provider;
          break;
        }
      } catch {}
    }
    sessions.push({ sessionId, filePath, lastModified: stat.mtimeMs, fileSize: stat.size, summary, provider });
  }
  return sessions.sort((a, b) => b.lastModified - a.lastModified);
}

/**
 * List Codex CLI sessions from ~/.codex/sessions/
 */
export function readSessionMessages(sessionId, cwd) {
  const hashed = hashProjectPath(cwd);
  const filePath = join(CLAUDE_PROJECTS_DIR, hashed, `${sessionId}.jsonl`);

  let all = _readJsonl(filePath);

  // For pi sessions, prefer pi's native session files (they have full history)
  const piMessages = _readPiSession(sessionId, cwd);
  if (piMessages.length > all.length) all = piMessages;

  // Collect thinking_cache entries — Claude redacts thinking from its JSONL,
  // so we save it separately and merge it back into assistant messages on load.
  const thinkingCaches = [];
  for (const entry of all) {
    if (entry.type === 'thinking_cache' && entry.blocks?.length > 0) {
      thinkingCaches.push(entry);
    }
  }

  // Return the last 50 conversation turns (user/assistant/tool_result)
  const conversational = [];
  let thinkingIdx = 0;
  for (let i = all.length - 1; i >= 0 && conversational.length < 50; i--) {
    const t = all[i].type;
    const r = all[i].message?.role;
    if (t === 'user' || t === 'assistant' || t === 'tool_result' || r === 'user' || r === 'assistant') {
      conversational.unshift(all[i]);
    }
  }

  // Merge thinking content into assistant messages that have redacted thinking blocks
  if (thinkingCaches.length > 0) {
    let cacheIdx = 0;
    for (const msg of conversational) {
      if (cacheIdx >= thinkingCaches.length) break;
      const content = msg.message?.content;
      if (!Array.isArray(content)) continue;
      const hasRedactedThinking = content.some((b) => b.type === 'thinking' && !b.thinking);
      if (!hasRedactedThinking) continue;
      // Match: this assistant message has empty thinking, fill from cache
      const cache = thinkingCaches[cacheIdx];
      for (const block of content) {
        if (block.type === 'thinking' && !block.thinking) {
          const cached = cache.blocks.find((cb) => cb.type === 'thinking' && cb.thinking);
          if (cached) block.thinking = cached.thinking;
        }
      }
      cacheIdx++;
    }
  }

  return conversational;
}

function _readJsonl(filePath) {
  if (!existsSync(filePath)) return [];
  return readFileSync(filePath, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

// Read from pi's native session dir (~/.pi/agent/sessions/)
function _readPiSession(sessionId, cwd) {
  try {
    // Pi uses --path-- format for session dirs (e.g. --home-zeul-.clawmux-agents-alloy--)
    const piHash = '--' + cwd.slice(1).replace(/\//g, '-') + '--';
    const piDir = join(PI_SESSIONS_DIR, piHash);
    if (!existsSync(piDir)) return [];
    // Find the file matching this sessionId
    const files = readdirSync(piDir).filter((f) => f.endsWith('.jsonl') && f.includes(sessionId));
    if (files.length === 0) return [];
    return _readJsonl(join(piDir, files[0]));
  } catch {
    return [];
  }
}
