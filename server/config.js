/**
 * Config — reads ~/.clawmux/agents.json + backends.json.
 * Single source of truth for per-agent settings (backend, model, effort, sessions).
 * Auto-creates default config files on first run.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const CONFIG_DIR = join(homedir(), '.clawmux');
const AGENTS_PATH = join(CONFIG_DIR, 'agents.json');
const BACKENDS_PATH = join(CONFIG_DIR, 'backends.json');

// ── Default configs (written on first run if files don't exist) ──

const DEFAULT_AGENTS = {
  defaults: {
    backend: 'claude',
    model: 'claude-opus-4-7',
    effort: 'high',
    permissionMode: 'bypassPermissions',
  },
  agents: [{ name: 'Agent', backend: 'claude', model: 'claude-opus-4-7' }],
};

const DEFAULT_BACKENDS = {
  _default: 'claude',
  claude: {
    enabled: true,
    bin: 'claude',
    label: 'Claude',
    models: [
      { id: 'claude-opus-4-7', label: 'Claude Opus 4.7', contextWindow: 1000000 },
      { id: 'claude-sonnet-4-6', label: 'Claude Sonnet 4.6', contextWindow: 200000 },
      { id: 'claude-haiku-4-5', label: 'Claude Haiku 4.5', contextWindow: 200000 },
    ],
    defaultModel: 'claude-opus-4-7',
    effortLevels: ['low', 'medium', 'high', 'max'],
    permissionModes: [
      { id: 'acceptEdits', label: 'Ask before edits' },
      { id: 'auto', label: 'Edit automatically' },
      { id: 'plan', label: 'Plan mode' },
      { id: 'bypassPermissions', label: 'Bypass permissions' },
    ],
    commands: [
      { name: '/compact', description: 'Compact conversation context' },
      { name: '/review', description: 'Review recent changes' },
      { name: '/init', description: 'Initialize project config' },
      { name: '/cost', description: 'Show token usage and cost' },
      { name: '/memory', description: 'Edit CLAUDE.md memory' },
      { name: '/permissions', description: 'View permission settings' },
    ],
  },
  codex: {
    enabled: true,
    bin: 'codex',
    label: 'Codex',
    port: 4500,
    models: [
      { id: 'default', label: 'Default (codex)', contextWindow: 272000 },
    ],
    defaultModel: 'default',
    effortLevels: ['low', 'medium', 'high', 'xhigh'],
    permissionModes: [],
    commands: [],
  },
  pi: {
    enabled: true,
    bin: 'pi',
    label: 'Pi',
    mode: 'rpc',
    models: [
      { id: 'default', label: 'Default (pi)', contextWindow: 200000 },
    ],
    defaultModel: 'default',
    effortLevels: ['low', 'medium', 'high', 'xhigh'],
    permissionModes: [],
    commands: [],
  },
  opencode: {
    enabled: true,
    bin: 'opencode',
    label: 'OpenCode',
    port: 4499,
    models: [
      { id: 'default', label: 'Default (opencode)', contextWindow: 200000 },
    ],
    defaultModel: 'default',
    effortLevels: [],
    permissionModes: [],
    commands: [],
  },
};

// ── Seed missing config files ──

function _ensureConfig(path, defaults) {
  if (!existsSync(path)) {
    if (!existsSync(CONFIG_DIR)) mkdirSync(CONFIG_DIR, { recursive: true });
    writeFileSync(path, JSON.stringify(defaults, null, 2) + '\n');
    console.log(`[config] Created ${path}`);
  }
}

_ensureConfig(AGENTS_PATH, DEFAULT_AGENTS);
_ensureConfig(BACKENDS_PATH, DEFAULT_BACKENDS);

const REQUIRED_EFFORT_LEVELS = {
  claude: ['low', 'medium', 'high', 'max'],
  codex: ['low', 'medium', 'high', 'xhigh'],
  pi: ['low', 'medium', 'high', 'xhigh'],
};

const EFFORT_ALIASES = {
  claude: { xhigh: 'max' },
  codex: { max: 'xhigh' },
  pi: { max: 'xhigh' },
};

function _normalizeEffortForBackend(backend, effort, fallback = 'high') {
  const cfg = getBackendsConfig();
  const valid = cfg?.[backend]?.effortLevels || REQUIRED_EFFORT_LEVELS[backend] || [];
  if (valid.length === 0) return effort || fallback;

  const normalized = EFFORT_ALIASES[backend]?.[effort] || effort;
  if (normalized && valid.includes(normalized)) return normalized;
  if (fallback && valid.includes(fallback)) return fallback;
  return valid.includes('high') ? 'high' : valid[valid.length - 1];
}

function _normalizeAgentsConfig(config) {
  let changed = false;
  const defaultBackend = config.defaults?.backend || getDefaultBackend();
  const defaultEffort = config.defaults?.effort || 'high';
  const normalizedDefaultEffort = _normalizeEffortForBackend(defaultBackend, defaultEffort, 'high');
  if (config.defaults && config.defaults.effort !== normalizedDefaultEffort) {
    config.defaults.effort = normalizedDefaultEffort;
    changed = true;
  }

  for (const agent of config.agents || []) {
    const backend = agent.backend || defaultBackend;
    const rawEffort = agent.effort || normalizedDefaultEffort;
    const normalizedEffort = _normalizeEffortForBackend(backend, rawEffort, normalizedDefaultEffort);
    if (agent.effort !== normalizedEffort) {
      agent.effort = normalizedEffort;
      changed = true;
    }
  }

  return changed;
}

function _normalizeBackendsConfig(config) {
  let changed = false;
  for (const [backend, required] of Object.entries(REQUIRED_EFFORT_LEVELS)) {
    const current = config?.[backend]?.effortLevels;
    if (!config?.[backend]) continue;
    if (!Array.isArray(current) || current.length === 0) {
      config[backend].effortLevels = [...required];
      changed = true;
      continue;
    }
    const merged = [...current];
    let backendChanged = false;
    for (const level of required) {
      if (!merged.includes(level)) {
        merged.push(level);
        backendChanged = true;
      }
    }
    if (backendChanged) {
      config[backend].effortLevels = merged;
      changed = true;
    }
  }
  return changed;
}

// Migrate: merge sessions.json into agents.json if it exists
const _oldSessionsPath = join(CONFIG_DIR, 'sessions.json');
if (existsSync(_oldSessionsPath)) {
  try {
    const sessions = JSON.parse(readFileSync(_oldSessionsPath, 'utf8'));
    const config = JSON.parse(readFileSync(AGENTS_PATH, 'utf8'));
    for (const agent of config.agents || []) {
      const id = agent.name.toLowerCase();
      if (sessions[id]) {
        agent.sessions = { ...(agent.sessions || {}), ...sessions[id] };
      }
    }
    writeFileSync(AGENTS_PATH, JSON.stringify(config, null, 2) + '\n');
    unlinkSync(_oldSessionsPath);
    console.log('[config] Migrated sessions.json into agents.json');
  } catch (err) {
    console.error('[config] Failed to migrate sessions.json:', err.message);
  }
}

// ── Loaders (lazy, invalidated on write) ──

let _agentsConfig = null;
function getAgentsConfig() {
  if (!_agentsConfig) {
    _agentsConfig = JSON.parse(readFileSync(AGENTS_PATH, 'utf8'));
    if (_normalizeAgentsConfig(_agentsConfig)) {
      writeFileSync(AGENTS_PATH, JSON.stringify(_agentsConfig, null, 2) + '\n');
    }
  }
  return _agentsConfig;
}

let _backendsConfig = null;
export function getBackendsConfig() {
  if (!_backendsConfig) {
    _backendsConfig = JSON.parse(readFileSync(BACKENDS_PATH, 'utf8'));
    if (_normalizeBackendsConfig(_backendsConfig)) {
      writeFileSync(BACKENDS_PATH, JSON.stringify(_backendsConfig, null, 2) + '\n');
    }
  }
  return _backendsConfig;
}

// ── Defaults ──

export function getDefaultBackend() {
  const cfg = getBackendsConfig();
  if (cfg._default && cfg[cfg._default]?.enabled !== false) return cfg._default;
  for (const [name, v] of Object.entries(cfg)) {
    if (name.startsWith('_')) continue;
    if (typeof v === 'object' && v.enabled !== false) return name;
  }
  return 'claude';
}

// ── Agent map ──

let _agentsMap = null;
function _buildAgentsMap() {
  const config = getAgentsConfig();
  const map = {};
  for (const agent of config.agents || []) {
    const id = agent.name.toLowerCase();
    const backend = agent.backend || config.defaults?.backend || getDefaultBackend();
    const fallbackEffort = config.defaults?.effort || 'high';
    map[id] = {
      name: agent.name,
      backend,
      model: agent.model || config.defaults?.model || 'default',
      effort: _normalizeEffortForBackend(backend, agent.effort || fallbackEffort, fallbackEffort),
      permissionMode: agent.permissionMode || config.defaults?.permissionMode || 'bypassPermissions',
    };
  }
  return map;
}

export function getAgentsMap() {
  if (!_agentsMap) _agentsMap = _buildAgentsMap();
  return _agentsMap;
}

// ── Per-agent getters ──

export function agentName(id) {
  const clean = _cleanId(id);
  const map = getAgentsMap();
  return map[clean]?.name || map[id]?.name || id;
}

export function agentId(id) {
  return _cleanId(id);
}

export function getAgentBackend(id) {
  return getAgentsMap()[_cleanId(id)]?.backend || getDefaultBackend();
}

export function getAgentModel(id) {
  return getAgentsMap()[_cleanId(id)]?.model || 'default';
}

export function getAgentEffort(id) {
  return getAgentsMap()[_cleanId(id)]?.effort || 'high';
}

// ── Per-agent setters (persist to agents.json) ──

function _setAgentField(id, field, value) {
  const clean = _cleanId(id);
  const config = getAgentsConfig();
  const agent = (config.agents || []).find((a) => a.name.toLowerCase() === clean);
  if (agent) agent[field] = value;
  writeFileSync(AGENTS_PATH, JSON.stringify(config, null, 2) + '\n');
  _invalidate();
}

export function setAgentBackend(id, backend) {
  const currentEffort = getAgentEffort(id);
  _setAgentField(id, 'backend', backend);
  // Reset model to 'default' — let the backend pick its own default
  _setAgentField(id, 'model', 'default');
  const normalizedEffort = _normalizeEffortForBackend(backend, currentEffort);
  _setAgentField(id, 'effort', normalizedEffort);
}

export function setAgentModel(id, model) {
  // Validate model belongs to agent's backend
  const backend = getAgentBackend(id);
  const bcfg = getBackendsConfig()[backend];
  if (bcfg?.models) {
    const valid = bcfg.models.map((m) => m.id);
    if (!valid.includes(model)) {
      throw new Error(`Model "${model}" not valid for backend "${backend}". Valid: ${valid.join(', ')}`);
    }
  }
  _setAgentField(id, 'model', model);
}

export function setAgentEffort(id, effort) {
  const backend = getAgentBackend(id);
  _setAgentField(id, 'effort', _normalizeEffortForBackend(backend, effort));
}

// ── Session registry (stored per-agent in agents.json) ──

export function getAgentSession(agentId, backend) {
  const clean = _cleanId(agentId);
  const config = getAgentsConfig();
  const agent = (config.agents || []).find((a) => a.name.toLowerCase() === clean);
  return agent?.sessions?.[backend] || null;
}

export function setAgentSession(agentId, backend, sessionId) {
  const clean = _cleanId(agentId);
  const config = getAgentsConfig();
  const agent = (config.agents || []).find((a) => a.name.toLowerCase() === clean);
  if (agent) {
    if (!agent.sessions) agent.sessions = {};
    agent.sessions[backend] = sessionId;
    writeFileSync(AGENTS_PATH, JSON.stringify(config, null, 2) + '\n');
    _invalidate();
  }
}

export function getAllSessions() {
  const config = getAgentsConfig();
  const sessions = {};
  for (const agent of config.agents || []) {
    if (agent.sessions) {
      sessions[agent.name.toLowerCase()] = agent.sessions;
    }
  }
  return sessions;
}

// ── Model discovery (update backends.json with actual available models) ──

export function updateBackendModels(backendName, models) {
  if (!models?.length) return;
  const cfg = getBackendsConfig();
  if (!cfg[backendName]) return;
  cfg[backendName].models = models;
  // Set defaultModel to first available if current default isn't in the new list
  const currentDefault = cfg[backendName].defaultModel;
  if (!models.find((m) => m.id === currentDefault)) {
    cfg[backendName].defaultModel = models[0].id;
  }
  _backendsConfig = cfg;
  writeFileSync(BACKENDS_PATH, JSON.stringify(cfg, null, 2) + '\n');
  console.log(`[config] Updated ${backendName} models: ${models.length} available`);
}

// ── Full config (served to frontend) ──

export function getFullConfig() {
  return { agents: getAgentsConfig(), backends: getBackendsConfig(), sessions: getAllSessions() };
}

// ── Internals ──

function _cleanId(id) {
  return id.replace(/^[abf][fm]_/, '').toLowerCase();
}

function _invalidate() {
  _agentsConfig = null;
  _agentsMap = null;
}
