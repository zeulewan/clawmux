import { existsSync, readFileSync } from 'fs';
import { resolve } from 'path';
import { readSessionMessages } from './sessions.js';
import { getBackendsConfig } from './config.js';

export const MIGRATION_BEGIN = '[CLAWMUX_SESSION_MIGRATION_V1]';
export const MIGRATION_END = '[/CLAWMUX_SESSION_MIGRATION_V1]';

export function estimateTokens(text) {
  return Math.ceil((text || '').length / 4);
}

function _readJsonl(filePath) {
  if (!existsSync(filePath)) throw new Error(`No such file: ${filePath}`);
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

function _detectProvider(entries) {
  for (const entry of entries) {
    if (entry.type === 'session_meta' && entry.provider) return entry.provider;
  }
  return 'claude';
}

function _flattenText(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map((item) => _flattenText(item)).filter(Boolean).join('\n');
  if (value && typeof value === 'object') {
    if (typeof value.text === 'string') return value.text;
    if (value.content != null) return _flattenText(value.content);
  }
  return '';
}

function _normalizeBlock(block, role) {
  if (!block || typeof block !== 'object') return '';
  switch (block.type) {
    case 'text':
      return _flattenText(block.text);
    case 'tool_use':
      return role === 'assistant' ? `[Tool use: ${block.name || 'tool'}]` : '';
    case 'tool_result': {
      const text = _flattenText(block.content).trim();
      return text ? `[Tool result] ${text}` : '[Tool result]';
    }
    case 'thinking':
      return '';
    case 'image':
      return '[Image omitted]';
    default:
      return _flattenText(block.text || block.content || '');
  }
}

function _normalizeMessage(entry) {
  const role = entry.message?.role || (entry.type === 'user' ? 'user' : entry.type === 'assistant' ? 'assistant' : null);
  if (!role) return null;

  let content = entry.message?.content || entry.content || [];
  if (typeof content === 'string') {
    try {
      const parsed = JSON.parse(content);
      if (parsed.message?.content) content = parsed.message.content;
      else if (Array.isArray(parsed)) content = parsed;
      else content = [];
    } catch {
      content = [];
    }
  }
  if (!Array.isArray(content)) content = [];

  const parts = content
    .map((block) => _normalizeBlock(block, role))
    .map((text) => text.replace(/\s+\n/g, '\n').trim())
    .filter(Boolean);

  const text = parts.join('\n').trim();
  if (!text) return null;
  return { role, text };
}

function _mergeConsecutive(messages) {
  const merged = [];
  for (const message of messages) {
    const last = merged[merged.length - 1];
    if (last && last.role === message.role) {
      last.text = `${last.text}\n${message.text}`.trim();
    } else {
      merged.push({ ...message });
    }
  }
  return merged;
}

function _truncateMessages(messages, maxTurns, maxChars) {
  const kept = [];
  let totalChars = 0;
  for (let i = messages.length - 1; i >= 0; i--) {
    const candidate = `${messages[i].role === 'user' ? 'User' : 'Assistant'}: ${messages[i].text}`;
    if (kept.length >= maxTurns) break;
    if (kept.length > 0 && totalChars + candidate.length > maxChars) break;
    kept.unshift(messages[i]);
    totalChars += candidate.length + 2;
  }
  return {
    messages: kept,
    truncated: kept.length < messages.length,
  };
}

function _formatTranscript(messages) {
  return messages
    .map((message) => `${message.role === 'user' ? 'User' : 'Assistant'}: ${message.text}`)
    .join('\n\n');
}

function _tokenBudget(targetBackend, explicitMaxTokens) {
  if (explicitMaxTokens) return explicitMaxTokens;
  const cfg = getBackendsConfig()?.[targetBackend];
  const contextWindow = cfg?.models?.[0]?.contextWindow || 200000;
  return Math.max(12000, Math.floor(contextWindow * 0.45));
}

function _charBudgetFromTokens(tokenBudget) {
  return tokenBudget * 4;
}

export function buildMigrationPrompt({ messages, sourceBackend = 'unknown', targetBackend = 'codex', sourceSessionId = null, maxTurns = 40, maxChars = null, maxTokens = null, userMessage = '' }) {
  const normalized = _mergeConsecutive(messages.map(_normalizeMessage).filter(Boolean));
  const tokenBudget = _tokenBudget(targetBackend, maxTokens);
  const charBudget = maxChars || _charBudgetFromTokens(tokenBudget);
  const { messages: kept, truncated } = _truncateMessages(normalized, maxTurns, charBudget);
  const transcript = _formatTranscript(kept);

  const prefix = [
    MIGRATION_BEGIN,
    `Source backend: ${sourceBackend}`,
    `Target backend: ${targetBackend}`,
    `Source session: ${sourceSessionId || 'unknown'}`,
    'Instructions:',
    '- Treat the transcript below as prior conversation context migrated from another backend.',
    '- Continue naturally from it.',
    '- Tool calls, hidden reasoning, and some low-value details may be omitted or summarized.',
    '- Do not restate the full transcript unless asked.',
    '',
    `Transcript (${kept.length} turns${truncated ? ', truncated for size' : ''}):`,
    transcript || '[No conversational content found.]',
    MIGRATION_END,
  ].join('\n');

  return {
    sourceBackend,
    targetBackend,
    sourceSessionId,
    tokenBudget,
    charBudget,
    estimatedTokens: estimateTokens(prefix),
    turnsIncluded: kept.length,
    truncated,
    prefix,
    prompt: userMessage ? `${prefix}\n\n${userMessage}` : prefix,
  };
}

export function buildMigrationPromptFromSession({ sessionId, cwd, targetBackend = 'codex', sourceBackend = 'unknown', maxTurns = 40, maxChars = null, maxTokens = null, userMessage = '' }) {
  const messages = readSessionMessages(sessionId, cwd);
  return buildMigrationPrompt({
    messages,
    sourceBackend,
    targetBackend,
    sourceSessionId: sessionId,
    maxTurns,
    maxChars,
    maxTokens,
    userMessage,
  });
}

export function buildMigrationPromptFromFile({ filePath, targetBackend = 'codex', sourceBackend = null, maxTurns = 40, maxChars = null, maxTokens = null, userMessage = '' }) {
  const absolutePath = resolve(filePath);
  const entries = _readJsonl(absolutePath);
  const detectedProvider = sourceBackend || _detectProvider(entries);
  const sourceSessionId = absolutePath.split('/').pop()?.replace(/\.jsonl$/, '') || null;
  return buildMigrationPrompt({
    messages: entries,
    sourceBackend: detectedProvider,
    targetBackend,
    sourceSessionId,
    maxTurns,
    maxChars,
    maxTokens,
    userMessage,
  });
}
