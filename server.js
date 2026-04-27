/**
 * ClawMux Lite — Multi-agent Claude Code server
 *
 * VS Code extension webview as chat UI + custom React sidebar.
 * Each agent gets its own Claude CLI subprocess (JSON streaming).
 */

import express from 'express';
import { WebSocketServer } from 'ws';
import { createServer as createHttpServer } from 'http';
import { createServer as createHttpsServer } from 'https';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { existsSync, mkdirSync, writeFileSync, appendFileSync, readFileSync } from 'fs';
import { homedir } from 'os';

import {
  getAgentsMap,
  agentName,
  agentId as cleanAgentId,
  getAgentBackend,
  getAgentModel,
  getAgentEffort,
  setAgentBackend,
  setAgentModel,
  setAgentEffort,
  getFullConfig,
  getBackendsConfig,
  getDefaultBackend,
  getAgentSession,
} from './server/config.js';
import ProviderSession, { monitorBus, rawEventBus, getRawEvents } from './server/provider-session.js';
import { listProviders } from './server/providers/provider.js';
import { startPolling, getLastUsage, onUsageUpdate } from './server/usage-poller.js';
import { updateBackendModels } from './server/config.js';
import { discoverPiModels } from './server/providers/pi-provider.js';
import { discoverCodexModels } from './server/providers/codex-provider.js';
import { buildMigrationPromptFromSession } from './server/session-migration.js';
import { voiceRouter } from './server/voice/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const PORT = process.env.PORT || 3470;
const HOST = process.env.HOST || '127.0.0.1';
const DEV_MODE = process.env.CLAWMUX_DEV === '1';
const VITE_PORT = process.env.VITE_PORT || 5173;
const CLAWMUX_DIR = join(homedir(), '.clawmux');
const AGENTS_DIR = process.env.AGENTS_DIR || join(CLAWMUX_DIR, 'agents');
const MESSAGES_DIR = join(CLAWMUX_DIR, 'messages');
const THREAD_STATE_FILE = join(CLAWMUX_DIR, 'thread-state.json');

if (!existsSync(AGENTS_DIR)) mkdirSync(AGENTS_DIR, { recursive: true });
if (!existsSync(MESSAGES_DIR)) mkdirSync(MESSAGES_DIR, { recursive: true });

function loadThreadState() {
  try {
    if (!existsSync(THREAD_STATE_FILE)) return {};
    const parsed = JSON.parse(readFileSync(THREAD_STATE_FILE, 'utf8'));
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

const closedThreads = loadThreadState();

function saveThreadState() {
  writeFileSync(THREAD_STATE_FILE, JSON.stringify(closedThreads, null, 2));
}

function threadKey(a, b) {
  return [cleanAgentId(a), cleanAgentId(b)].sort().join('::');
}

function getClosedThread(a, b) {
  return closedThreads[threadKey(a, b)] || null;
}

function closeThread(a, b, meta) {
  closedThreads[threadKey(a, b)] = { ...meta, updatedAt: Date.now() };
  saveThreadState();
}

function reopenThread(a, b) {
  const key = threadKey(a, b);
  const existed = !!closedThreads[key];
  if (existed) {
    delete closedThreads[key];
    saveThreadState();
  }
  return existed;
}

function agentWorkDir(agentId) {
  const name = cleanAgentId(agentId);
  const dir = join(AGENTS_DIR, name);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  return dir;
}

function _getLiveSessionId(session) {
  const connEntry = session ? [...(session.connections?.values() || [])][0] : null;
  return connEntry?.sessionId || connEntry?.conn?.threadId || connEntry?.conn?.sessionId || null;
}

// Global agent registry — agentId → { proc, channelId, session }
const agentProcs = new Map();

// ── Express ──────────────────────────────────────────────────────

const app = express();
app.use(express.json());

// Raw body for STT audio uploads (/api/stt)
app.use('/api/stt', express.raw({ type: '*/*', limit: '25mb' }));

// Voice routes (TTS, STT, health)
app.use(voiceRouter);

// Static assets (shim.js)
app.use(express.static(join(__dirname, 'public')));

// Webview bundle (app/dist)
const cleanWebviewDir = join(__dirname, 'app', 'dist');
app.use(
  '/clean-assets',
  express.static(cleanWebviewDir, {
    // Force browsers to revalidate every load — no silent staleness after a build
    setHeaders(res) {
      res.setHeader('Cache-Control', 'no-store, must-revalidate');
    },
  }),
);

// Bump this when webview source changes to force reload of cached assets
const ASSET_VERSION = Date.now().toString(36);

const serveCleanWebview = (req, res) => {
  res.setHeader('Cache-Control', 'no-store, must-revalidate');
  if (DEV_MODE) {
    // In dev mode the Vite dev server hosts the frontend with HMR.
    // Anything that lands on the backend's HTML route gets bounced over.
    const target = `http://${req.hostname}:${VITE_PORT}${req.originalUrl || '/'}`;
    res.status(302).set('Location', target).send(
      `<!DOCTYPE html><meta charset="utf-8"><title>ClawMux dev</title>` +
        `<p>Dev mode — open <a href="${target}">${target}</a> for the Vite dev server (HMR enabled).</p>`,
    );
    return;
  }
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>ClawMux Lite</title>
  <link rel="icon" type="image/svg+xml" href="/clean-assets/favicon.svg">
  <link rel="stylesheet" href="/clean-assets/webview.css?v=${ASSET_VERSION}">
  <style>
    html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: #1e1e1e; color: #ccc; }
    #cmx-loader { display: flex !important; flex-direction: column !important; align-items: center !important; justify-content: center !important; height: 100vh !important; width: 100% !important; position: fixed !important; top: 0; left: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; z-index: 9999; }
    #cmx-loader .bar { width: 120px; height: 3px; background: #333; border-radius: 2px; overflow: hidden; margin-top: 16px; }
    #cmx-loader .bar::after { content: ''; display: block; width: 40%; height: 100%; background: #666; border-radius: 2px; animation: cmx-slide 1.2s ease-in-out infinite; }
    @keyframes cmx-slide { 0% { transform: translateX(-100%); } 100% { transform: translateX(350%); } }
    #cmx-loader .text { font-size: 13px; color: #666; margin-top: 12px; }
    #cmx-loader { opacity: 0; animation: cmx-fadein 0.3s ease 0.2s forwards; }
    @keyframes cmx-fadein { to { opacity: 1; } }
  </style>
</head>
<body>
  <div id="root">
    <div id="cmx-loader">
      <div style="font-size: 18px; font-weight: 600; letter-spacing: 1px;">ClawMux</div>
      <div class="bar"></div>
      <div class="text">Loading...</div>
    </div>
  </div>
  <script>
    // Scrub retired provider names from localStorage (one-time, idempotent)
    try { ['openclaw','glueclaw'].forEach(function(n) {
      for (var i = localStorage.length - 1; i >= 0; i--) {
        var k = localStorage.key(i), v = localStorage.getItem(k) || '';
        if (k.indexOf(n) !== -1 || v.indexOf(n) !== -1) localStorage.removeItem(k);
      }
    }); } catch(_){}
    window.IS_FULL_EDITOR = true;
  </script>
  <script type="module" src="/clean-assets/webview.js?v=${ASSET_VERSION}"></script>
</body>
</html>`);
};
app.get('/', serveCleanWebview);

// ── API ──────────────────────────────────────────────────────────

app.get('/api/agents', (req, res) => res.json(getAgentsMap()));
app.get('/api/config', (req, res) => res.json(getFullConfig()));

app.post('/api/agents/:id/backend', (req, res) => {
  const id = cleanAgentId(req.params.id);
  const { backend } = req.body;
  if (!backend) return res.status(400).json({ error: 'backend required' });
  const backends = getBackendsConfig();
  if (!backends[backend] || backend.startsWith('_'))
    return res.status(400).json({ error: `unknown backend: ${backend}` });
  setAgentBackend(id, backend);
  // Kill active session so next message relaunches with new backend
  const session = [...agentProcs.values()].find((e) => e.session?.agentId === id);
  if (session?.session) session.session.killConnections();
  console.log(`[config] ${agentName(id)} backend → ${backend}`);
  res.json({ ok: true, agent: id, backend });
});

app.post('/api/agents/:id/model', (req, res) => {
  const id = cleanAgentId(req.params.id);
  const { model } = req.body;
  if (!model) return res.status(400).json({ error: 'model required' });
  try {
    setAgentModel(id, model);
  } catch (e) {
    return res.status(400).json({ error: e.message });
  }
  // Kill active session so next message relaunches with new model
  const session = [...agentProcs.values()].find((e) => e.session?.agentId === id);
  if (session?.session) session.session.killConnections();
  console.log(`[config] ${agentName(id)} model → ${model}`);
  res.json({ ok: true, agent: id, model });
});

app.post('/api/agents/:id/effort', (req, res) => {
  const id = cleanAgentId(req.params.id);
  const { effort } = req.body;
  if (!effort) return res.status(400).json({ error: 'effort required' });
  setAgentEffort(id, effort);
  monitorBus.emit('change', id);
  console.log(`[config] ${agentName(id)} effort → ${effort}`);
  res.json({ ok: true, agent: id, effort });
});

app.get('/api/status', (req, res) => {
  const running = {};
  for (const [agentId, entry] of agentProcs) {
    running[agentId] = { name: agentName(agentId), pid: entry.proc?.pid || entry.conn ? 'connected' : null };
  }
  res.json({ running, total: agentProcs.size });
});

app.get('/api/usage', (req, res) => {
  const usage = getLastUsage();
  if (usage) res.json(usage);
  else res.json({ error: 'No usage data yet' });
});

// ── Monitor ─────────────────────────────────────────────────────

function _resolveModelLabel(model, backend) {
  if (!model || model === 'default') {
    const bcfg = getBackendsConfig()[backend];
    const defaultId = bcfg?.defaultModel || bcfg?.models?.[0]?.id;
    const match = bcfg?.models?.find((m) => m.id === defaultId);
    return match?.label || defaultId || backend;
  }
  const bcfg = getBackendsConfig()[backend];
  const match = bcfg?.models?.find((m) => m.id === model);
  return match?.label || model;
}

function getMonitorSnapshot() {
  const agents = getAgentsMap();
  const backends = getBackendsConfig();
  const anthropicUsage = getLastUsage();
  const snapshot = { _usage: {} };

  // Global rate limits
  if (anthropicUsage) {
    snapshot._usage.anthropic = {
      fiveHour: anthropicUsage.fiveHour?.percent,
      weekly: anthropicUsage.weekly?.percent,
    };
  }

  // Collect OpenAI rate limits from codex sessions only
  for (const [, entry] of agentProcs) {
    if (entry.session?.providerName !== 'codex') continue;
    const u = entry.session?.lastUsage;
    if (u?.fiveHour?.percent != null && !snapshot._usage.openai) {
      snapshot._usage.openai = {
        fiveHour: u.fiveHour.percent,
        weekly: u.weekly?.percent,
      };
      break;
    }
  }

  for (const [id, cfg] of Object.entries(agents)) {
    const entry = agentProcs.get(id);
    const session = entry?.session;
    const connEntry = session ? [...(session.connections?.values() || [])][0] : null;
    const usage = session?.lastUsage || {};
    // Prefer live model name from the active connection (pi reports actual model via get_state)
    const liveModel = connEntry?.conn?.modelName;
    snapshot[id] = {
      name: cfg.name,
      backend: cfg.backend,
      model: liveModel || _resolveModelLabel(cfg.model, cfg.backend),
      effort: cfg.effort,
      status: session ? session.state.status : 'offline',
      currentTool: session?.state.currentTool || null,
      lastActivity: session?.state.lastActivity || null,
      sessionId: connEntry?.sessionId || connEntry?.conn?.threadId || connEntry?.conn?.sessionId || null,
      contextPercent: usage.contextPercent != null ? usage.contextPercent : null,
    };
  }
  return snapshot;
}

app.get('/api/monitor', (req, res) => res.json(getMonitorSnapshot()));

app.get('/api/monitor/stream', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });

  // Send full snapshot on connect
  res.write(`data: ${JSON.stringify(getMonitorSnapshot())}\n\n`);

  // Send deltas on state changes
  const onChange = (agentId) => {
    const usage = getMonitorSnapshot()._usage;
    if (agentId === '_usage') {
      res.write(`data: ${JSON.stringify({ _usage: usage })}\n\n`);
      return;
    }
    const agents = getAgentsMap();
    const cfg = agents[agentId];
    if (!cfg) return;
    const entry = agentProcs.get(agentId);
    const session = entry?.session;
    const connEntry2 = session ? [...(session.connections?.values() || [])][0] : null;
    const usage2 = session?.lastUsage || {};
    const delta = {
      [agentId]: {
        name: cfg.name,
        backend: cfg.backend,
        model: cfg.model,
        effort: cfg.effort,
        status: session ? session.state.status : 'offline',
        currentTool: session?.state.currentTool || null,
        lastActivity: session?.state.lastActivity || null,
        sessionId: connEntry2?.sessionId || connEntry2?.conn?.threadId || connEntry2?.conn?.sessionId || null,
        contextPercent: usage2.contextPercent != null ? usage2.contextPercent : null,
      },
      _usage: usage,
    };
    res.write(`data: ${JSON.stringify(delta)}\n\n`);
  };

  monitorBus.on('change', onChange);
  req.on('close', () => monitorBus.off('change', onChange));
});

app.get('/api/agents/:id/raw', (req, res) => {
  const id = cleanAgentId(req.params.id);
  const limit = parseInt(req.query.limit || '200', 10);
  const agents = getAgentsMap();
  if (!agents[id]) return res.status(404).json({ error: `unknown agent: ${req.params.id}` });
  res.json({
    agentId: id,
    backend: getAgentBackend(id),
    events: getRawEvents(id, Number.isFinite(limit) ? limit : 200),
  });
});

app.get('/api/agents/:id/raw/stream', (req, res) => {
  const id = cleanAgentId(req.params.id);
  const limit = parseInt(req.query.limit || '50', 10);
  const agents = getAgentsMap();
  if (!agents[id]) return res.status(404).json({ error: `unknown agent: ${req.params.id}` });

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });

  res.write(
    `data: ${JSON.stringify({
      agentId: id,
      backend: getAgentBackend(id),
      events: getRawEvents(id, Number.isFinite(limit) ? limit : 50),
    })}\n\n`,
  );

  const onRaw = (agentId, event) => {
    if (agentId !== id) return;
    res.write(`data: ${JSON.stringify({ event })}\n\n`);
  };

  rawEventBus.on('event', onRaw);
  req.on('close', () => rawEventBus.off('event', onRaw));
});

app.post('/api/terminate', (req, res) => {
  const { agentId } = req.body;
  const id = cleanAgentId(agentId);
  const entry = agentProcs.get(id);
  if (entry) {
    if (entry.session) {
      entry.session.killConnections();
      entry.session._updateState('offline');
    }
    agentProcs.delete(id);
    console.log(`[terminate] ${agentName(id)} terminated`);
    res.json({ ok: true });
  } else {
    res.json({ error: 'Agent not running' });
  }
});

app.post('/api/launch', (req, res) => {
  const { agentId } = req.body;
  const id = cleanAgentId(agentId);
  const agents = getAgentsMap();
  if (!agents[id]) {
    return res.json({ error: `Unknown agent: ${agentId}` });
  }
  // Terminate existing session if any
  const existing = agentProcs.get(id);
  if (existing?.session) {
    existing.session.killConnections();
    existing.session._updateState('offline');
    agentProcs.delete(id);
  }
  // Launch fresh
  const cwd = agentWorkDir(id);
  const noopSend = () => {};
  const session = new ProviderSession(noopSend, cwd, id, agentProcs);
  const channelId = `cli_${id}_${Date.now()}`;
  const backend = getAgentBackend(id);
  const sessionId = getAgentSession(id, backend);
  session.launchProvider({ channelId, resume: sessionId || undefined, cwd }).then(() => {
    console.log(`[launch] ${agentName(id)} launched via API`);
    res.json({ ok: true, channelId });
  }).catch((err) => {
    console.error(`[launch] Failed to launch ${agentName(id)}: ${err.message}`);
    res.json({ error: err.message });
  });
});

app.get('/api/providers', (req, res) => {
  res.json({ providers: listProviders() });
});

/** Append a message record to an agent's JSONL log. */
function persistMessage(agentId, record) {
  const file = join(MESSAGES_DIR, `${agentId}.jsonl`);
  appendFileSync(file, JSON.stringify(record) + '\n');
}

function broadcastAgentMessage(record) {
  const notification = JSON.stringify({
    type: 'agent_message',
    from: record.from,
    to: record.to,
    text: record.text,
    msgId: record.msgId,
    timestamp: record.timestamp,
    control: record.control || null,
  });
  for (const ws of wss.clients) {
    if (ws.readyState === ws.OPEN) ws.send(notification);
  }
}

app.post('/api/send', (req, res) => {
  const { from, to, text, control } = req.body;
  const normalizedControl = control || null;
  if (normalizedControl && !['close-thread', 'reopen-thread'].includes(normalizedControl)) {
    return res.json({ error: `unknown control: ${normalizedControl}` });
  }
  const toId = cleanAgentId(to);
  const agents = getAgentsMap();
  if (!agents[toId]) {
    return res.json({ error: `unknown agent: ${to}` });
  }
  const target = agentProcs.get(toId);
  const fromId = cleanAgentId(from);
  const fromName = agentName(from);
  const toName = agentName(to);
  const bodyText = typeof text === 'string' ? text : '';
  if (!normalizedControl && !bodyText) {
    return res.json({ error: 'message text required' });
  }
  const msgId = `msg_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  const timestamp = Date.now();
  const controlTag = normalizedControl ? ` ctl:${normalizedControl}` : '';
  const formatted = `[MSG id:${msgId} from:${fromName}${controlTag}] ${bodyText}`.trimEnd();
  const record = { from: fromName, to: toName, text: bodyText, msgId, timestamp, control: normalizedControl };
  persistMessage(fromId, record);
  persistMessage(toId, record);
  broadcastAgentMessage(record);

  if (normalizedControl === 'close-thread') {
    closeThread(fromId, toId, {
      closedBy: fromName,
      closedById: fromId,
      message: bodyText || null,
      closedAt: timestamp,
    });
    return res.json({ ok: true, msgId, control: normalizedControl, closed: true });
  }

  if (normalizedControl === 'reopen-thread') {
    const reopened = reopenThread(fromId, toId);
    if (!bodyText) {
      return res.json({ ok: true, msgId, control: normalizedControl, reopened });
    }
  }

  const closed = getClosedThread(fromId, toId);
  if (closed) {
    return res.json({
      error: `Thread between ${fromName} and ${toName} is closed; use cmx send --reopen-thread ${toId} "..." to resume`,
      closedThread: closed,
    });
  }

  if (!target?.session) {
    return res.json({ error: `${agentName(to)} is not running` });
  }

  // Deliver to recipient
  const channelId = target.channelId;
  target.session.handleMessage({
    type: 'io_message',
    channelId,
    message: {
      type: 'user',
      message: { role: 'user', content: [{ type: 'text', text: formatted }] },
    },
  });

  res.json({ ok: true, msgId });
});

app.post('/api/migrate', async (req, res) => {
  const { agentId, toBackend, maxTokens } = req.body;
  const id = cleanAgentId(agentId);
  const agents = getAgentsMap();
  if (!agents[id]) return res.json({ error: `Unknown agent: ${agentId}` });
  if (!toBackend) return res.json({ error: 'toBackend required' });

  const backends = getBackendsConfig();
  if (!backends[toBackend] || toBackend.startsWith('_')) {
    return res.json({ error: `unknown backend: ${toBackend}` });
  }

  const fromBackend = getAgentBackend(id);
  const fromModel = getAgentModel(id);
  if (fromBackend === toBackend) {
    return res.json({ ok: true, alreadyOnBackend: true, agent: id, backend: toBackend });
  }

  const existing = agentProcs.get(id);
  const liveSession = existing?.session || null;
  if (liveSession && ['thinking', 'responding', 'tool_call'].includes(liveSession.state.status)) {
    return res.json({ error: `${agentName(id)} is busy (${liveSession.state.status}); migrate when idle` });
  }

  const cwd = agentWorkDir(id);
  const sourceSessionId = _getLiveSessionId(liveSession) || getAgentSession(id, fromBackend);
  if (!sourceSessionId) {
    return res.json({ error: `No ${fromBackend} session found for ${agentName(id)}` });
  }

  const session = liveSession || new ProviderSession(() => {}, cwd, id, agentProcs);
  const channelId = existing?.channelId || `migrate_${id}_${Date.now()}`;
  const parsedMaxTokens = maxTokens == null ? null : parseInt(String(maxTokens), 10);
  if (maxTokens != null && !Number.isFinite(parsedMaxTokens)) {
    return res.json({ error: `Invalid maxTokens: ${maxTokens}` });
  }

  try {
    const migration = buildMigrationPromptFromSession({
      sessionId: sourceSessionId,
      cwd,
      sourceBackend: fromBackend,
      targetBackend: toBackend,
      maxTokens: Number.isFinite(parsedMaxTokens) ? parsedMaxTokens : null,
      userMessage:
        'Internal one-time migration step. Load the transcript as prior context. Reply with exactly MIGRATION_READY and nothing else.',
    });

    setAgentBackend(id, toBackend);
    if (liveSession) {
      liveSession.killConnections();
      liveSession._updateState('offline');
    }

    await session.launchProvider({ channelId, resume: undefined, cwd });
    const primeResult = await session.primeMigration(channelId, migration.prompt, { skipLocalPersist: true });
    const targetSessionId = primeResult?.sessionId || _getLiveSessionId(session) || getAgentSession(id, toBackend);

    const payload = JSON.stringify({
      type: 'agent_migrated',
      agentId: id,
      fromBackend,
      toBackend,
      sessionId: targetSessionId,
      estimatedTokens: migration.estimatedTokens,
      tokenBudget: migration.tokenBudget,
      truncated: migration.truncated,
    });
    for (const ws of wss.clients) {
      if (ws.readyState === ws.OPEN) ws.send(payload);
    }

    console.log(
      `[migrate] ${agentName(id)} ${fromBackend} -> ${toBackend} source=${sourceSessionId} target=${targetSessionId || 'new'} tokens≈${migration.estimatedTokens}/${migration.tokenBudget}`,
    );

    res.json({
      ok: true,
      agent: id,
      fromBackend,
      toBackend,
      sourceSessionId,
      targetSessionId,
      estimatedTokens: migration.estimatedTokens,
      tokenBudget: migration.tokenBudget,
      truncated: migration.truncated,
      turnsIncluded: migration.turnsIncluded,
      channelId,
    });
  } catch (err) {
    try {
      session.killConnections();
      session._updateState('offline');
    } catch {}
    try {
      setAgentBackend(id, fromBackend);
      if (fromModel && fromModel !== 'default') {
        setAgentModel(id, fromModel);
      }
    } catch (rollbackErr) {
      console.error(`[migrate] Failed to restore backend config for ${agentName(id)}: ${rollbackErr.message}`);
    }
    if (liveSession) {
      try {
        await session.launchProvider({ channelId, resume: sourceSessionId || undefined, cwd });
      } catch (rollbackErr) {
        console.error(`[migrate] Failed to relaunch ${agentName(id)} on ${fromBackend}: ${rollbackErr.message}`);
      }
    } else {
      agentProcs.delete(id);
    }
    console.error(`[migrate] Failed to migrate ${agentName(id)}: ${err.message}`);
    res.json({ error: err.message });
  }
});

app.get('/api/messages/:agentId', (req, res) => {
  const id = cleanAgentId(req.params.agentId);
  const file = join(MESSAGES_DIR, `${id}.jsonl`);
  if (!existsSync(file)) return res.json([]);
  const lines = readFileSync(file, 'utf-8').trim().split('\n').filter(Boolean);
  const messages = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  res.json(messages.slice(-50));
});

// Agent-specific chat page — serve same SPA, frontend reads agent from path
app.get('/chat/:agentId', serveCleanWebview);

// SPA fallback
app.get('/{*path}', (req, res) => {
  if (req.path.startsWith('/api/') || req.path.startsWith('/ws')) {
    return res.status(404).json({ error: 'Not found' });
  }
  serveCleanWebview(req, res);
});

// ── WebSocket ────────────────────────────────────────────────────

// ── HTTPS via Tailscale cert (optional) ──────────────────────────
const TLS_CERT = join(__dirname, 'workstation.tailee9084.ts.net.crt');
const TLS_KEY  = join(__dirname, 'workstation.tailee9084.ts.net.key');
const HTTPS_PORT = process.env.HTTPS_PORT || 3471;

let httpsServer = null;
if (existsSync(TLS_CERT) && existsSync(TLS_KEY)) {
  const tlsOptions = { cert: readFileSync(TLS_CERT), key: readFileSync(TLS_KEY) };
  httpsServer = createHttpsServer(tlsOptions, app);
}

const server = createHttpServer(app);
const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (request, socket, head) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  if (url.pathname === '/ws/chat') {
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws);
    });
  } else {
    socket.destroy();
  }
});

const HEARTBEAT_INTERVAL = 25000;
setInterval(() => {
  for (const ws of wss.clients) {
    if (ws._isAlive === false) {
      ws.terminate();
      continue;
    }
    ws._isAlive = false;
    ws.ping();
  }
}, HEARTBEAT_INTERVAL);

function isReplayableWsMessage(msg) {
  return msg?.type === 'io_message' || msg?.type === 'close_channel';
}

/** Create a send function that routes through a specific WS. */
function makeSendFn(ws, { paused = false } = {}) {
  const fn = (msg) => {
    if (fn._paused && isReplayableWsMessage(msg)) {
      fn._buffer.push(msg);
      return;
    }
    fn._sendDirect(msg);
  };
  fn._sendDirect = (msg) => {
    if (ws.readyState === ws.OPEN) {
      ws.send(JSON.stringify(msg));
    }
  };
  fn._paused = paused;
  fn._buffer = [];
  fn._resume = (minReplaySeq = 0) => {
    fn._paused = false;
    if (fn._buffer.length === 0) return;
    const buffered = fn._buffer;
    fn._buffer = [];
    for (const msg of buffered) {
      if (isReplayableWsMessage(msg) && Number(msg.replaySeq || 0) <= minReplaySeq) continue;
      fn._sendDirect(msg);
    }
  };
  // Tag with WS reference so we can remove it on close
  fn._ws = ws;
  return fn;
}

/** Get or create a ProviderSession for an agent on this WS. */
function getOrCreateSession(ws, rawAgentId, provider) {
  // Normalize: strip legacy prefix (am_adam → adam)
  const agentId = rawAgentId ? cleanAgentId(rawAgentId) : rawAgentId;
  // Check WS-local sessions first
  let session = ws._sessions.get(agentId);
  if (session) {
    if (provider && provider !== session.providerName) {
      session.setProvider(provider);
    }
    return session;
  }

  // Check global agentProcs for existing session from a previous WS
  const existing = agentId ? agentProcs.get(agentId) : null;
  if (existing?.session) {
    session = existing.session;
    session.setSendFn(makeSendFn(ws, { paused: true }));
    if (provider && provider !== session.providerName) {
      session.setProvider(provider);
    }
    ws._sessions.set(agentId, session);
    console.log(`[ws] Reconnected session: ${agentName(agentId)} provider=${session.providerName}`);
    return session;
  }

  // Create new session
  const clean = agentId ? cleanAgentId(agentId) : null;
  const cwd = clean && getAgentsMap()[clean] ? agentWorkDir(agentId) : AGENTS_DIR;
  session = new ProviderSession(makeSendFn(ws), cwd, agentId, agentProcs);
  if (provider) session.setProvider(provider);
  ws._sessions.set(agentId, session);
  console.log(`[ws] New session: ${agentName(agentId)} provider=${session.providerName} cwd=${cwd}`);
  return session;
}

wss.on('connection', (ws) => {
  ws._isAlive = true;
  ws._sessions = new Map(); // agentId → ProviderSession
  ws._channelToAgent = new Map(); // channelId → agentId
  ws._conversationToAgent = new Map(); // conversationId → agentId
  ws._currentAgent = null;

  ws.on('pong', function () {
    this._isAlive = true;
  });

  ws.on('message', (data) => {
    try {
      const raw = data.toString();
      if (raw === '{"type":"ping"}') {
        ws.send('{"type":"pong"}');
        ws._isAlive = true;
        return;
      }
      if (raw === '{"type":"pong"}') {
        ws._isAlive = true;
        return;
      }
      const msg = JSON.parse(raw);
      msg._ws = ws;
      const agentId = cleanAgentId(msg.agentId || ws._currentAgent || '');

      // Agent switch — just update focus, no WS teardown
      if (msg.type === 'switch_agent') {
        ws._currentAgent = cleanAgentId(msg.agentId || '');
        const prov = msg.provider;
        if (msg.agentId) {
          getOrCreateSession(ws, msg.agentId, prov);
        }
        console.log(`[ws] Agent focus: ${agentName(msg.agentId)} provider=${prov || 'default'}`);
        return;
      }

      // Provider switch — update the current agent's session
      if (msg.type === 'set_provider' && agentId) {
        const session = getOrCreateSession(ws, agentId);
        session.setProvider(msg.provider);
        return;
      }

      // Launch — track channelId → agentId mapping
      if (msg.type === 'launch') {
        if (agentId && msg.channelId) {
          ws._channelToAgent.set(msg.channelId, agentId);
        }
        if (agentId && msg.conversationId) {
          ws._conversationToAgent.set(msg.conversationId, agentId);
        }
        const session = getOrCreateSession(ws, agentId, msg.provider);
        session.handleMessage(msg);
        return;
      }

      // Route all other messages by conversationId first, then channelId,
      // then fall back to the currently focused agent.
      const targetAgent =
        (msg.conversationId && ws._conversationToAgent.get(msg.conversationId)) ||
        ws._channelToAgent.get(msg.channelId) ||
        agentId;
      if (targetAgent) {
        const session = ws._sessions.get(targetAgent);
        if (session) session.handleMessage(msg);
      }
    } catch (err) {
      console.error('[ws] Parse error:', err.message);
    }
  });

  ws.on('close', () => {
    console.log(`[ws] Disconnected (${ws._sessions.size} sessions)`);
    // Remove this WS's send function from all sessions (other browsers keep working)
    for (const [id, session] of ws._sessions) {
      if (session._sendFns) {
        for (const fn of session._sendFns) {
          if (fn._ws === ws) session.removeSendFn(fn);
        }
      }
    }
  });
  ws.on('error', (err) => {
    console.error(`[ws] Error: ${err.message}`);
    for (const [id, session] of ws._sessions) {
      if (session._sendFns) {
        for (const fn of session._sendFns) {
          if (fn._ws === ws) session.removeSendFn(fn);
        }
      }
    }
  });
});

// ── Start ────────────────────────────────────────────────────────

// Share WebSocket upgrade handler with the HTTPS server too
if (httpsServer) {
  httpsServer.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url, `https://${request.headers.host}`);
    if (url.pathname === '/ws/chat') {
      wss.handleUpgrade(request, socket, head, (ws) => { wss.emit('connection', ws); });
    } else {
      socket.destroy();
    }
  });
  httpsServer.listen(HTTPS_PORT, '0.0.0.0', () => {
    console.log(`ClawMux Lite (HTTPS) on https://workstation.tailee9084.ts.net:${HTTPS_PORT}`);
  });
}

server.listen(PORT, HOST, () => {
  console.log(`ClawMux Lite on http://${HOST}:${PORT}`);
  if (DEV_MODE) {
    console.log(`[dev] CLAWMUX_DEV=1 — open http://${HOST}:${VITE_PORT} for the Vite dev server (HMR)`);
  }
  startPolling();

  // Discover available models from each backend CLI
  const piModels = discoverPiModels();
  if (piModels?.length) updateBackendModels('pi', piModels);

  discoverCodexModels().then((codexModels) => {
    if (codexModels?.length) updateBackendModels('codex', codexModels);
  }).catch(() => {});

  // Validate agent configs — fix session/backend mismatches
  {
    const fullCfg = getFullConfig();
    const defaultBackend = fullCfg.agents?.defaults?.backend || 'claude';
    let fixed = 0;
    for (const agent of fullCfg.agents?.agents || []) {
      const backend = agent.backend || defaultBackend;
      const sessions = agent.sessions || {};
      // Remove session IDs that belong to other backends (from backend switches)
      const validKeys = Object.keys(sessions);
      for (const key of validKeys) {
        if (key !== backend && sessions[key] === sessions[backend]) {
          console.log(`[startup] Removing duplicate session for ${agent.name}: ${key} (same as ${backend})`);
          delete sessions[key];
          fixed++;
        }
      }
      // Warn if agent has no session for its current backend
      if (!sessions[backend] && Object.keys(sessions).length > 0) {
        console.log(`[startup] Warning: ${agent.name} is on ${backend} but only has sessions for: ${Object.keys(sessions).join(', ')}`);
      }
    }
    if (fixed > 0) {
      writeFileSync(join(AGENTS_DIR, '..', 'agents.json'), JSON.stringify(fullCfg.agents, null, 2) + '\n');
      console.log(`[startup] Fixed ${fixed} session mismatches`);
    }
  }

  // Auto-resume agents that had active sessions
  if (!process.argv.includes('--hard')) {
    const fullCfg = getFullConfig();
    const defaultBackend = fullCfg.agents?.defaults?.backend || 'claude';
    let resumed = 0;
    for (const agent of fullCfg.agents?.agents || []) {
      const id = agent.name.toLowerCase();
      const backend = agent.backend || defaultBackend;
      const sessionId = agent.sessions?.[backend];
      if (!sessionId) continue;
      const cwd = agentWorkDir(id);
      const noopSend = () => {};
      const session = new ProviderSession(noopSend, cwd, id, agentProcs);
      const channelId = `auto_${id}_${Date.now()}`;
      session.launchProvider({ channelId, resume: sessionId, cwd }).catch((err) => {
        console.error(`[startup] Failed to resume ${agent.name}: ${err.message}`);
      });
      resumed++;
    }
    if (resumed > 0) console.log(`[startup] Auto-resuming ${resumed} agents`);
  }

  // Health check — periodically relaunch crashed/errored agents (every 30s)
  setInterval(() => {
    const agents = getAgentsMap();
    const defaultBackend = getDefaultBackend();
    for (const [id, cfg] of Object.entries(agents)) {
      const entry = agentProcs.get(id);
      const session = entry?.session;
      if (!session) continue; // never launched — don't auto-launch
      const status = session.state.status;
      // Relaunch agents that went offline or hit an explicit error state.
      if (status !== 'offline' && status !== 'error') continue;
      const backend = cfg.backend || defaultBackend;
      const sessionId = getAgentSession(id, backend);
      console.log(`[health] Relaunching ${cfg.name} (status=${status}, backend=${backend})`);
      const cwd = agentWorkDir(id);
      const channelId = entry?.channelId || `health_${id}_${Date.now()}`;
      session.launchProvider({ channelId, resume: sessionId || undefined, cwd }).catch((err) => {
        console.error(`[health] Failed to relaunch ${cfg.name}: ${err.message}`);
      });
    }
  }, 30000);

  onUsageUpdate((usage) => {
    // Broadcast usage to all connected clients
    const msg = JSON.stringify({
      type: 'request',
      channelId: '',
      requestId: crypto.randomUUID(),
      request: { type: 'usage_update', utilization: usage },
    });
    for (const ws of wss.clients) {
      if (ws.readyState === ws.OPEN) ws.send(msg);
    }
    monitorBus.emit('change', '_usage');
  });
});
