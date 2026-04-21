#!/usr/bin/env node

import { execSync, spawn } from 'child_process';
import { readFileSync, existsSync, openSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { homedir } from 'os';
import http from 'http';
import { buildMigrationPromptFromFile } from './server/session-migration.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const cmd = process.argv[2];
const PORT = process.env.PORT || '3470';
const BASE = `http://localhost:${PORT}`;
const LOG_PATH = join(homedir(), '.clawmux', 'server.log');

// ── Helpers ──

// Find node processes listening on PORT. Returns [{ pid, line }] or [].
// Tries lsof first, falls back to ss + /proc for systems without lsof.
function findListeners() {
  // Try lsof first
  try {
    const lines = execSync(`lsof -i:${PORT} 2>/dev/null`, { encoding: 'utf8' }).trim().split('\n');
    const results = [];
    for (const line of lines) {
      if (line.includes('LISTEN') && line.startsWith('node')) {
        const pid = parseInt(line.split(/\s+/)[1]);
        if (pid) results.push({ pid, line });
      }
    }
    return results;
  } catch {}

  // Fallback: ss + /proc to find node processes on this port (Linux only — macOS always has lsof)
  if (process.platform !== 'darwin') {
    try {
      const out = execSync(`ss -tlnp sport = :${PORT} 2>/dev/null`, { encoding: 'utf8' });
      const results = [];
      const pidRe = /pid=(\d+)/g;
      let match;
      while ((match = pidRe.exec(out)) !== null) {
        const pid = parseInt(match[1]);
        // Verify it's a node process
        try {
          const cmdline = readFileSync(`/proc/${pid}/cmdline`, 'utf8');
          if (cmdline.includes('node')) results.push({ pid, line: `node (PID ${pid})` });
        } catch {}
      }
      return results;
    } catch {}
  }

  return [];
}

function isPortInUse() {
  return findListeners().length > 0;
}

function stop() {
  const listeners = findListeners();
  let killed = false;
  for (const { pid } of listeners) {
    try {
      process.kill(pid, 'SIGTERM');
      killed = true;
    } catch {}
  }
  return killed;
}

function serverStatus() {
  const listeners = findListeners();
  if (listeners.length > 0) {
    console.log(`Running (PID ${listeners[0].pid})`);
    return true;
  }
  console.log('Not running');
  return false;
}

function api(path) {
  return new Promise((resolve, reject) => {
    http
      .get(`${BASE}${path}`, (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(body));
          } catch {
            reject(new Error(`Bad JSON from ${path}`));
          }
        });
      })
      .on('error', (e) => reject(e));
  });
}

function postApi(path, data) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(data);
    const req = http.request(
      `${BASE}${path}`,
      { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } },
      (res) => {
        let out = '';
        res.on('data', (c) => (out += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(out));
          } catch {
            reject(new Error(`Bad JSON from ${path}`));
          }
        });
      },
    );
    req.on('error', reject);
    req.end(body);
  });
}

function pad(s, n) {
  return s.length >= n ? s.slice(0, n) : s + ' '.repeat(n - s.length);
}

// Strip ANSI when stdout isn't a TTY so colors don't leak as raw escape codes
// when output is captured/piped (e.g. by other agents or scripts).
const COLOR = process.stdout.isTTY && process.env.NO_COLOR !== '1';
const DIM = COLOR ? '\x1b[2m' : '';
const BOLD = COLOR ? '\x1b[1m' : '';
const RESET = COLOR ? '\x1b[0m' : '';
const GREEN = COLOR ? '\x1b[32m' : '';
const RED = COLOR ? '\x1b[31m' : '';
const YELLOW = COLOR ? '\x1b[33m' : '';
const CYAN = COLOR ? '\x1b[36m' : '';
const GRAY = COLOR ? '\x1b[90m' : '';
const MAGENTA = COLOR ? '\x1b[35m' : '';

// ── Commands ──

if (!cmd || cmd === 'start') {
  if (serverStatus()) {
    console.log('Already running. Use cmx restart to restart.');
    process.exit(0);
  }
  const logFd = openSync(LOG_PATH, 'a');
  const child = spawn('node', [join(__dirname, 'server.js')], {
    stdio: ['ignore', logFd, logFd],
    cwd: __dirname,
    detached: true,
    env: { ...process.env, PORT },
  });
  child.unref();
  console.log(`Started (PID ${child.pid}), log: ${LOG_PATH}`);
} else if (cmd === 'stop') {
  if (stop()) console.log('Stopped');
  else console.log('Not running');
} else if (cmd === 'restart') {
  const hard = process.argv.includes('--hard');
  stop();
  const wait = () => {
    if (isPortInUse()) {
      setTimeout(wait, 200);
    } else {
      const serverArgs = [join(__dirname, 'server.js')];
      if (hard) serverArgs.push('--hard');
      const logFd2 = openSync(LOG_PATH, 'a');
      const c = spawn('node', serverArgs, {
        stdio: ['ignore', logFd2, logFd2],
        cwd: __dirname,
        detached: true,
        env: { ...process.env, PORT },
      });
      c.unref();
      console.log(`Started (PID ${c.pid})`);
    }
  };
  setTimeout(wait, 200);
} else if (cmd === 'update') {
  const env = { ...process.env, PATH: `${dirname(process.execPath)}:${process.env.PATH}` };
  execSync('git stash 2>/dev/null; git pull', { stdio: 'inherit', cwd: __dirname, env });
  execSync('npm install --omit=dev', { stdio: 'inherit', cwd: __dirname, env });
  execSync('npm install', { stdio: 'inherit', cwd: join(__dirname, 'app'), env });
  execSync('npm run build', { stdio: 'inherit', cwd: __dirname, env });
  if (stop()) {
    for (let i = 0; i < 20; i++) {
      if (!isPortInUse()) break;
      execSync('sleep 0.3');
    }
    const logFd3 = openSync(LOG_PATH, 'a');
    const c = spawn('node', [join(__dirname, 'server.js')], {
      stdio: ['ignore', logFd3, logFd3],
      cwd: __dirname,
      detached: true,
      env: { ...process.env, PORT },
    });
    c.unref();
    console.log(`Updated and restarted (PID ${c.pid})`);
  } else {
    console.log('Updated (server was not running)');
  }
} else if (cmd === 'status') {
  serverStatus();
} else if (cmd === 'monitor') {
  import('./monitor.js');

  // ── agents ──

} else if (cmd === 'agents') {
  try {
    const agents = await api('/api/agents');
    const monitor = await api('/api/monitor');
    const sorted = Object.entries(agents).sort((a, b) => a[1].name.localeCompare(b[1].name));

    console.log(
      `${DIM}${pad('AGENT', 12)} ${pad('BACKEND', 10)} ${pad('MODEL', 24)} ${pad('EFFORT', 8)} ${pad('STATUS', 12)}${RESET}`,
    );
    console.log(`${DIM}${'─'.repeat(68)}${RESET}`);

    for (const [id, agent] of sorted) {
      const st = monitor[id]?.status || 'offline';
      const stColor = st === 'offline' ? RED : st === 'idle' ? GRAY : GREEN;
      let model = agent.model || '';
      model = model.replace('claude-', 'c-').replace('anthropic/', '').replace('openai/', '');
      console.log(
        `${pad(agent.name, 12)} ${pad(agent.backend, 10)} ${pad(model, 24)} ${pad(agent.effort, 8)} ${stColor}${st}${RESET}`,
      );
    }
    console.log(`\n${DIM}${sorted.length} agents${RESET}`);
  } catch (e) {
    console.error(`Cannot connect to server: ${e.message}`);
    process.exit(1);
  }

  // ── send ──

} else if (cmd === 'send') {
  if (process.argv[3] === '--help' || process.argv[3] === '-h') {
    console.log(`Usage: cmx send <agent> <message>

Send a message to an agent. The sender is auto-detected:
  - CMX_AGENT env var (set automatically for claude/pi backends)
  - .cmx-agent file in cwd (codex backends)
  - cwd path inside ~/.clawmux/agents/<name>/
  - Falls back to "cli" (human at terminal)

Examples:
  cmx send sky "hello"          Send to sky as cli (human)
  cmx send puck "got it"        Agent sends to puck (auto-detected)

Agents: Adam, Alice, Alloy, Aoede, Bella, Daniel, Echo, Emma, Eric,
  Fable, Fenrir, George, Heart, Jadzia, Jessica, Kore, Lewis, Liam,
  Lily, Michael, Nicole, Nova, Onyx, Puck, River, Sarah, Sky`);
    process.exit(0);
  }
  const target = process.argv[3];
  const message = process.argv.slice(4).join(' ');
  if (!target || !message) {
    console.log('Usage: cmx send <agent> <message> (try --help for details)');
    process.exit(1);
  }
  // Auto-detect sender: CMX_AGENT env > .cmx-agent file in cwd > cwd path detection > 'cli'
  let from = process.env.CMX_AGENT || '';
  if (!from) {
    const idFile = join(process.cwd(), '.cmx-agent');
    if (existsSync(idFile)) from = readFileSync(idFile, 'utf8').trim();
  }
  if (!from) {
    const agentsDir = join(process.env.HOME, '.clawmux', 'agents') + '/';
    const cwd = process.cwd() + '/';
    if (cwd.startsWith(agentsDir)) {
      const relative = cwd.slice(agentsDir.length);
      from = relative.split('/')[0] || '';
    }
  }
  if (!from) from = 'cli';
  try {
    const res = await postApi('/api/send', { to: target, text: message, from });
    if (res.ok) console.log(`${GREEN}Sent to ${target}${RESET}`);
    else console.log(`${RED}${res.error || 'Failed'}${RESET}`);
  } catch (e) {
    console.error(`Cannot connect to server: ${e.message}`);
    process.exit(1);
  }

  // ── launch ──

} else if (cmd === 'launch') {
  const target = process.argv[3];
  if (!target || target === '--help' || target === '-h') {
    console.log(`Usage: cmx launch <agent>

Launch or restart an agent. If the agent is already running, it will be
terminated and relaunched fresh. If it has a saved session, it resumes.

Examples:
  cmx launch river        Launch river
  cmx launch heart        Launch heart after fixing config`);
    process.exit(target ? 0 : 1);
  }
  try {
    const res = await postApi('/api/launch', { agentId: target });
    if (res.ok) console.log(`${GREEN}Launched ${target}${RESET}`);
    else console.log(`${RED}${res.error || 'Failed'}${RESET}`);
  } catch (e) {
    console.error(`Cannot connect to server: ${e.message}`);
    process.exit(1);
  }

  // ── terminate ──

} else if (cmd === 'terminate') {
  const target = process.argv[3];
  if (!target || target === '--help' || target === '-h') {
    console.log('Usage: cmx terminate <agent>');
    process.exit(target ? 0 : 1);
  }
  try {
    const res = await postApi('/api/terminate', { agentId: target });
    if (res.ok) console.log(`${GREEN}Terminated ${target}${RESET}`);
    else console.log(`${RED}${res.error || 'Failed'}${RESET}`);
  } catch (e) {
    console.error(`Cannot connect to server: ${e.message}`);
    process.exit(1);
  }

  // ── migrate ──

} else if (cmd === 'migrate') {
  const target = process.argv[3];
  const args = process.argv.slice(4);
  const toIdx = args.indexOf('--to');
  const maxTokensIdx = args.indexOf('--max-tokens');
  const toBackend = toIdx !== -1 ? args[toIdx + 1] : null;
  const maxTokens = maxTokensIdx !== -1 ? parseInt(args[maxTokensIdx + 1], 10) : null;

  if (!target || target === '--help' || target === '-h' || args.includes('--help') || args.includes('-h')) {
    console.log(`Usage: cmx migrate <agent> --to <backend> [--max-tokens N]

Convert an agent's current session into a fresh session on another backend.
The source session is compacted into a migration prompt, the old live backend
connection is stopped, and the target backend is primed invisibly so the next
message can continue almost seamlessly.

Examples:
  cmx migrate puck --to codex
  cmx migrate river --to claude --max-tokens 90000`);
    process.exit(target ? 0 : 1);
  }

  if (!toBackend) {
    console.log('Usage: cmx migrate <agent> --to <backend> [--max-tokens N]');
    process.exit(1);
  }
  if (maxTokensIdx !== -1 && !Number.isFinite(maxTokens)) {
    console.log(`${RED}Invalid --max-tokens value${RESET}`);
    process.exit(1);
  }

  try {
    const res = await postApi('/api/migrate', {
      agentId: target,
      toBackend,
      maxTokens: Number.isFinite(maxTokens) ? maxTokens : null,
    });
    if (res.alreadyOnBackend) {
      console.log(`${YELLOW}${target} already on ${res.backend}${RESET}`);
      process.exit(0);
    }
    if (!res.ok) {
      console.log(`${RED}${res.error || 'Failed'}${RESET}`);
      process.exit(1);
    }

    console.log(`${GREEN}Migrated ${target} ${res.fromBackend} → ${res.toBackend}${RESET}`);
    console.log(`  Source session: ${res.sourceSessionId}`);
    console.log(`  Target session: ${res.targetSessionId || 'pending'}`);
    console.log(`  Context budget: ~${res.estimatedTokens}/${res.tokenBudget} tokens${res.truncated ? ' (truncated)' : ''}`);
    console.log(`  Turns included: ${res.turnsIncluded}`);
  } catch (e) {
    console.error(`Cannot connect to server: ${e.message}`);
    process.exit(1);
  }

  // ── logs ──

} else if (cmd === 'logs') {
  if (!existsSync(LOG_PATH)) {
    console.log(`No log file yet. Start the server first: cmx start`);
    process.exit(0);
  }
  const tail = spawn('tail', ['-f', '-n', '100', LOG_PATH], { stdio: 'inherit' });
  tail.on('exit', () => process.exit(0));

  // ── config ──

} else if (cmd === 'config') {
  try {
    const cfg = await api('/api/config');
    const agents = cfg.agents?.agents || [];
    const backends = Object.keys(cfg.backends || {}).filter((k) => !k.startsWith('_'));
    const defaultBackend = cfg.backends?._default || 'claude';

    console.log(`${BOLD}ClawMux Config${RESET}`);
    console.log(`${DIM}─────────────────────────────${RESET}`);
    console.log(`Agents:          ${agents.length}`);
    console.log(`Default backend: ${defaultBackend}`);
    console.log(`Backends:        ${backends.join(', ')}`);
    console.log(`Default model:   ${cfg.agents?.defaults?.model || '-'}`);
    console.log(`Default effort:  ${cfg.agents?.defaults?.effort || '-'}`);
    console.log();

    // Backend details
    for (const name of backends) {
      const b = cfg.backends[name];
      const models = (b.models || []).map((m) => m.label || m.id).join(', ');
      const enabled = b.enabled !== false ? `${GREEN}enabled${RESET}` : `${RED}disabled${RESET}`;
      console.log(`${BOLD}${name}${RESET} ${DIM}(${enabled}${DIM})${RESET}`);
      console.log(`  Models: ${models || 'none'}`);
      if (b.effortLevels?.length) console.log(`  Effort: ${b.effortLevels.join(', ')}`);
      console.log();
    }
  } catch (e) {
    console.error(`Cannot connect to server: ${e.message}`);
    process.exit(1);
  }

  // ── version ──

} else if (cmd === 'version' || cmd === '-v' || cmd === '--version') {
  const pkg = JSON.parse(readFileSync(join(__dirname, 'package.json'), 'utf8'));
  let commit = 'unknown';
  try {
    commit = execSync('git rev-parse --short HEAD', { cwd: __dirname, encoding: 'utf8' }).trim();
  } catch {}
  let dirty = false;
  try {
    execSync('git diff --quiet HEAD', { cwd: __dirname, stdio: 'ignore' });
  } catch {
    dirty = true;
  }
  console.log(`clawmux-lite v${pkg.version} (${commit}${dirty ? ' dirty' : ''})`);
  for (const bin of ['claude', 'codex', 'pi', 'opencode']) {
    try {
      const ver = execSync(`${bin} --version 2>&1 || echo not found`, {
        encoding: 'utf8',
        timeout: 5000,
      }).trim();
      console.log(`  ${bin}: ${ver}`);
    } catch {
      console.log(`  ${bin}: not found`);
    }
  }

  // ── help ──

} else if (cmd === 'doctor') {
  console.log(`${BOLD}ClawMux Doctor${RESET}\n`);
  let issues = 0;

  // 1. Server status
  const listeners = findListeners();
  if (listeners.length > 0) {
    console.log(`${GREEN}✓${RESET} Server running (PID ${listeners[0].pid})`);
  } else {
    console.log(`${RED}✗${RESET} Server not running`);
    issues++;
    console.log(`\n${issues} issue(s) found. Run ${BOLD}cmx start${RESET} first.`);
    process.exit(1);
  }

  try {
    const monitor = await api('/api/monitor');
    const agents = await api('/api/agents');

    // 2. Agent health
    const agentList = Object.entries(agents).sort((a, b) => a[1].name.localeCompare(b[1].name));
    const online = agentList.filter(([id]) => monitor[id]?.status && monitor[id].status !== 'offline');
    const offline = agentList.filter(([id]) => !monitor[id]?.status || monitor[id].status === 'offline');
    const errored = agentList.filter(([id]) => monitor[id]?.status === 'error');
    const stale = agentList.filter(([id]) => {
      const m = monitor[id];
      if (!m || !['thinking', 'responding', 'tool_call'].includes(m.status)) return false;
      return m.lastActivity && (Date.now() - m.lastActivity > 60000);
    });

    console.log(`${GREEN}✓${RESET} ${online.length}/${agentList.length} agents online`);
    if (offline.length > 0) {
      console.log(`${RED}✗${RESET} ${offline.length} offline: ${offline.map(([, a]) => a.name).join(', ')}`);
      issues += offline.length;
    }
    if (errored.length > 0) {
      console.log(`${RED}✗${RESET} ${errored.length} errored: ${errored.map(([, a]) => a.name).join(', ')}`);
      issues += errored.length;
    }
    if (stale.length > 0) {
      console.log(`${YELLOW}!${RESET} ${stale.length} stale (active >60s no events): ${stale.map(([, a]) => a.name).join(', ')}`);
      issues += stale.length;
    }

    // 3. Context % warnings
    const highCtx = agentList.filter(([id]) => (monitor[id]?.contextPercent || 0) > 80);
    if (highCtx.length > 0) {
      console.log(`${YELLOW}!${RESET} High context: ${highCtx.map(([id, a]) => `${a.name} ${monitor[id].contextPercent}%`).join(', ')}`);
    } else {
      console.log(`${GREEN}✓${RESET} No agents above 80% context`);
    }

    // 4. Backend daemons
    const backends = new Set(agentList.map(([, a]) => a.backend));
    for (const b of ['codex', 'opencode']) {
      if (!backends.has(b)) continue;
      const port = b === 'codex' ? 4500 : 4499;
      try {
        const endpoint = b === 'codex' ? `http://127.0.0.1:${port}/readyz` : `http://127.0.0.1:${port}/global/health`;
        const r = await fetch(endpoint);
        if (r.ok) {
          console.log(`${GREEN}✓${RESET} ${b} daemon running (port ${port})`);
        } else {
          console.log(`${RED}✗${RESET} ${b} daemon unhealthy (port ${port})`);
          issues++;
        }
      } catch {
        console.log(`${RED}✗${RESET} ${b} daemon not reachable (port ${port})`);
        issues++;
      }
    }

    // 5. Rate limits
    const usage = monitor._usage || {};
    if (usage.anthropic?.fiveHour > 80) {
      console.log(`${YELLOW}!${RESET} Anthropic 5h rate limit: ${usage.anthropic.fiveHour}%`);
    }
    if (usage.openai?.fiveHour > 80) {
      console.log(`${YELLOW}!${RESET} OpenAI 5h rate limit: ${usage.openai.fiveHour}%`);
    }

    // 6. Config health
    const config = await api('/api/config');
    const agentsCfg = config.agents?.agents || [];
    for (const a of agentsCfg) {
      const sessions = a.sessions || {};
      const backend = a.backend || 'claude';
      if (!sessions[backend] && Object.keys(sessions).length > 0) {
        console.log(`${YELLOW}!${RESET} ${a.name}: on ${backend} but no ${backend} session (has: ${Object.keys(sessions).join(', ')})`);
        issues++;
      }
    }

    console.log(`\n${issues === 0 ? `${GREEN}All clear.${RESET}` : `${RED}${issues} issue(s) found.${RESET}`}`);
  } catch (e) {
    console.error(`Cannot connect to server: ${e.message}`);
    process.exit(1);
  }

} else if (cmd === 'migration-prompt') {
  const args = process.argv.slice(3);
  const filePath = args.find((arg) => !arg.startsWith('--'));
  const targetIdx = args.indexOf('--to');
  const maxTokensIdx = args.indexOf('--max-tokens');
  const maxCharsIdx = args.indexOf('--max-chars');
  const maxTurnsIdx = args.indexOf('--max-turns');
  const userIdx = args.indexOf('--user');
  const targetBackend = targetIdx !== -1 ? args[targetIdx + 1] : 'codex';
  const maxTokens = maxTokensIdx !== -1 ? parseInt(args[maxTokensIdx + 1], 10) : null;
  const maxChars = maxCharsIdx !== -1 ? parseInt(args[maxCharsIdx + 1], 10) : null;
  const maxTurns = maxTurnsIdx !== -1 ? parseInt(args[maxTurnsIdx + 1], 10) : 40;
  const userMessage = userIdx !== -1 ? args[userIdx + 1] : '';

  if (!filePath || args.includes('--help') || args.includes('-h')) {
    console.log(`Usage: cmx migration-prompt <session.jsonl> [--to codex|claude] [--max-tokens N] [--max-chars N] [--max-turns N] [--user "message"]

Build a migration-ready prompt from a Claude or Codex JSONL session file.

Examples:
  cmx migration-prompt ~/.claude/projects/.../4018b24b-....jsonl
  cmx migration-prompt ~/.claude/projects/.../019da1ec-....jsonl --to claude
  cmx migration-prompt ~/.claude/projects/.../session.jsonl --to codex --user "Continue from here"
`);
    process.exit(filePath ? 0 : 1);
  }

  try {
    const result = buildMigrationPromptFromFile({
      filePath,
      targetBackend,
      maxTokens: Number.isFinite(maxTokens) ? maxTokens : null,
      maxChars: Number.isFinite(maxChars) ? maxChars : null,
      maxTurns: Number.isFinite(maxTurns) ? maxTurns : 40,
      userMessage,
    });
    process.stdout.write(result.prompt + '\n');
  } catch (e) {
    console.error(`${RED}${e.message}${RESET}`);
    process.exit(1);
  }

} else if (cmd === 'help' || cmd === '-h' || cmd === '--help') {
  console.log(`${BOLD}cmx${RESET} — ClawMux Lite CLI\n`);
  console.log('Commands:');
  console.log(`  ${BOLD}start${RESET}              Start the server (default)`);
  console.log(`  ${BOLD}stop${RESET}               Stop the server`);
  console.log(`  ${BOLD}restart${RESET}            Restart the server`);
  console.log(`  ${BOLD}status${RESET}             Check if server is running`);
  console.log(`  ${BOLD}monitor${RESET}            Live agent status dashboard`);
  console.log(`  ${BOLD}agents${RESET}             List all agents`);
  console.log(`  ${BOLD}send${RESET} <agent> <msg> Send a message to an agent`);
  console.log(`  ${BOLD}launch${RESET} <agent>     Launch or restart an agent`);
  console.log(`  ${BOLD}terminate${RESET} <agent>  Stop a running agent`);
  console.log(`  ${BOLD}migrate${RESET} <agent>    Migrate an agent session to another backend`);
  console.log(`  ${BOLD}config${RESET}             Show config summary`);
  console.log(`  ${BOLD}logs${RESET}               Run server in foreground`);
  console.log(`  ${BOLD}update${RESET}             Git pull + rebuild + restart`);
  console.log(`  ${BOLD}doctor${RESET}             System health check`);
  console.log(`  ${BOLD}migration-prompt${RESET}   Build a chunky migration prompt from a session JSONL`);
  console.log(`  ${BOLD}version${RESET}            Show versions`);
  console.log(`  ${BOLD}help${RESET}               This help`);
} else {
  console.log(`Unknown command: ${cmd}. Run ${BOLD}cmx help${RESET} for usage.`);
  process.exit(1);
}
