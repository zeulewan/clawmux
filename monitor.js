#!/usr/bin/env node

/**
 * ClawMux Monitor — real-time agent status dashboard.
 *
 * Connects to the server's SSE endpoint and renders a flicker-free live
 * ANSI table. Overwrites lines in place (cursor home + line clears) so
 * the scrollback buffer never grows.
 *
 * Keys: f filter active-only, s sort, c compact, b cycle backend,
 *       / search by name (enter to commit, esc to clear), q quit
 *
 * Usage: node monitor.js [--port 3470]
 *        cmx monitor
 */

import http from 'http';

const PORT = process.argv.includes('--port')
  ? process.argv[process.argv.indexOf('--port') + 1]
  : process.env.PORT || '3470';

const HOST = process.env.HOST || 'localhost';

// ── ANSI helpers ──

const ESC = '\x1b[';
const HOME = `${ESC}H`;
const ERASE_DOWN = `${ESC}J`;
const ERASE_LINE = `${ESC}2K`;
const HIDE_CURSOR = `${ESC}?25l`;
const SHOW_CURSOR = `${ESC}?25h`;
const BOLD = `${ESC}1m`;
const DIM = `${ESC}2m`;
const RESET = `${ESC}0m`;
const FG_RESET = `${ESC}39m`; // reset fg only — keeps bg (zebra) intact mid-row
const BG_RESET = `${ESC}49m`;
const ALT_SCREEN = `${ESC}?1049h`;
const MAIN_SCREEN = `${ESC}?1049l`;

const colors = {
  green: `${ESC}32m`,
  yellow: `${ESC}33m`,
  red: `${ESC}31m`,
  cyan: `${ESC}36m`,
  magenta: `${ESC}35m`,
  gray: `${ESC}90m`,
  white: `${ESC}37m`,
  blue: `${ESC}34m`,
};

// 24-bit colors (foreground)
const fg = (r, g, b) => `${ESC}38;2;${r};${g};${b}m`;
// 24-bit background
const bg = (r, g, b) => `${ESC}48;2;${r};${g};${b}m`;

// Backend brand colors
const backendColor = {
  claude: fg(74, 158, 255), // #4A9EFF
  codex: fg(16, 163, 127), // OpenAI green #10A37F
  pi: fg(195, 100, 197), // Pi pink/magenta
  opencode: colors.cyan,
};

// No background highlights — works in both light and dark terminal modes.
// Visual rhythm comes from thin separator lines between rows instead of zebra shading.
// Row flash on state change is foreground-only (highlights agent name, not bg).
const FLASH_FG = `${ESC}36m`; // bright cyan for transient highlight

// Explicit gray fg for "dim" content inside rows — DIM attribute is unreliable across terminals.
const DIM_FG = `${ESC}38;5;245m`; // medium gray, readable on both modes

// Differentiated status icons
const statusStyle = {
  responding: { color: colors.green, icon: '\u25cf', label: 'responding' }, // ●
  thinking: { color: colors.yellow, icon: '\u25d0', label: 'thinking' }, // ◐
  tool_call: { color: colors.magenta, icon: '\u25c6', label: 'tool_call' }, // ◆
  idle: { color: `${ESC}38;5;110m`, icon: '\u25cb', label: 'idle' }, // ○ soft blue-gray (alive but quiet)
  offline: { color: `${ESC}38;5;240m`, icon: '\u00b7', label: 'offline' }, // · very dim gray (absent)
  error: { color: colors.red, icon: '\u2715', label: 'error' }, // ✕
};

// ── State ──

let agents = {};
let usage = {};
let lastLineCount = 0;

// Per-agent: previous status (for flash detection) and flash-until timestamp
const prevStatus = {};
const flashUntil = {};
const FLASH_MS = 600;

// Usage history for projection
const usageHistory = []; // {ts, anth5h, anth7d, oai5h, oai7d}
const USAGE_HISTORY_MS = 30 * 60 * 1000; // keep 30 min

// View state
const view = {
  filterActive: false, // f
  sort: 'alpha', // s: 'alpha' | 'recent'
  compact: false, // c
  backendFilter: 'all', // b: 'all' | 'claude' | 'codex' | 'pi' | 'opencode'
  search: '', // / committed query
  searchMode: false, // /  in input mode
  searchBuffer: '', //    pending input
};

const BACKENDS = ['all', 'claude', 'codex', 'pi', 'opencode'];

// ── Rendering helpers ──

// Pad-only — never truncate. Column widths grow monotonically to fit data,
// so truncation here would just hide content. If a string overflows, let it.
function pad(str, len) {
  if (str.length >= len) return str;
  return str + ' '.repeat(len - str.length);
}

function padRight(str, len) {
  if (str.length >= len) return str;
  return ' '.repeat(len - str.length) + str;
}

function timeAgo(ts) {
  if (!ts) return '';
  const secs = Math.floor((Date.now() - ts) / 1000);
  if (secs < 5) return 'just now';
  if (secs < 60) return `${secs}s ago`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  return `${Math.floor(secs / 3600)}h ago`;
}

// 10-segment bar like [█████░░░░░] colored by threshold
function usageBar(pct, width = 10) {
  if (pct == null) return ' '.repeat(width + 2);
  const filled = Math.round((pct / 100) * width);
  const color = pct > 80 ? colors.red : pct > 50 ? colors.yellow : colors.green;
  const bar = '█'.repeat(filled) + '░'.repeat(width - filled);
  return `${color}[${bar}]${RESET}`;
}

// Color-only ctx percent (right-aligned), no bracket
// Uses FG_RESET so the row's zebra bg stays intact.
function ctxPct(pct, width) {
  if (pct == null) return ' '.repeat(width);
  const color = pct > 80 ? colors.red : pct > 50 ? colors.yellow : colors.green;
  const text = `${pct}%`;
  return `${color}${padRight(text, width)}${FG_RESET}`;
}

// MCP tool names are huge: mcp__server__method → server.method
function shortenTool(t) {
  if (!t) return '';
  const m = t.match(/^mcp__([^_]+)__(.+)$/);
  if (m) return `${m[1]}.${m[2]}`;
  return t;
}

function shortenModel(m) {
  if (!m) return '';
  return m.replace('Claude ', 'C.').replace('Default (', '(').replace('Google ', '').replace('opencode', 'oc');
}

// Project hours-to-limit from rate of change; null if not enough history
function projectHours(field) {
  if (usageHistory.length < 2) return null;
  const recent = usageHistory[usageHistory.length - 1];
  const old = usageHistory[0];
  const v1 = recent[field];
  const v0 = old[field];
  if (v1 == null || v0 == null) return null;
  const dPct = v1 - v0;
  const dHours = (recent.ts - old.ts) / 3600000;
  if (dHours <= 0 || dPct <= 0) return null;
  const ratePerHour = dPct / dHours;
  const remaining = 100 - v1;
  return remaining / ratePerHour;
}

function formatProjection(hours) {
  if (hours == null || !isFinite(hours)) return '';
  if (hours < 1) return `~${Math.round(hours * 60)}m to limit`;
  if (hours < 48) return `~${hours.toFixed(1)}h to limit`;
  return `~${Math.round(hours / 24)}d to limit`;
}

// ── Filter & sort ──

function visibleRows() {
  let rows = Object.entries(agents);
  if (view.backendFilter !== 'all') {
    rows = rows.filter(([, a]) => (a.backend || '') === view.backendFilter);
  }
  if (view.filterActive) {
    rows = rows.filter(([, a]) => a.status !== 'offline' && a.status !== 'idle');
  }
  if (view.search) {
    const q = view.search.toLowerCase();
    rows = rows.filter(([, a]) => (a.name || '').toLowerCase().includes(q));
  }
  if (view.sort === 'recent') {
    rows.sort((a, b) => (b[1].lastActivity || 0) - (a[1].lastActivity || 0));
  } else {
    rows.sort((a, b) => a[1].name.localeCompare(b[1].name));
  }
  return rows;
}

// ── Render ──

// Visual width of a row (pre-padding) — used to pad with bg-bearing spaces so the zebra
// stripe runs cleanly to the terminal edge. Sum of column widths + per-column separators.
function rowVisibleWidth(cols) {
  // 1 leading space + sum(col + trailing space) for each col
  return 1 + Object.values(cols).reduce((acc, n) => acc + n + 1, 0);
}

// Monotonic per-column widths — columns only grow, never shrink, so they don't
// twitch frame-to-frame as data changes. Also seeded with sensible minimums so
// the very first frame already approximates the steady-state layout.
const colMaxFull = {
  name: 'AGENT'.length,
  backend: 'opencode'.length, // longest known backend name
  model: 'MODEL'.length,
  effort: 'THINK'.length,
  ctx: '100%'.length, // ctx never wider than this
  status: 'responding'.length + 2, // longest label + icon + space
  tool: 'TOOL'.length,
  session: 16, // we slice sessionId to 16 chars
  activity: 'just now'.length, // longest typical timeAgo string
};
const colMaxCompact = {
  name: 'AGENT'.length,
  status: 'responding'.length,
  tool: 'TOOL'.length,
  activity: 'just now'.length,
};

function computeCols(rows, compact) {
  const c = compact ? colMaxCompact : colMaxFull;
  if (compact) {
    for (const [, a] of rows) {
      c.name = Math.max(c.name, (a.name || '').length);
      const lbl = (statusStyle[a.status] || statusStyle.offline).label;
      c.status = Math.max(c.status, lbl.length);
      c.tool = Math.max(c.tool, shortenTool(a.currentTool || '').length);
      if (a.status !== 'offline') c.activity = Math.max(c.activity, timeAgo(a.lastActivity).length);
    }
    return c;
  }
  for (const [, a] of rows) {
    c.name = Math.max(c.name, (a.name || '').length);
    c.backend = Math.max(c.backend, (a.backend || '-').length);
    c.model = Math.max(c.model, shortenModel(a.model || '').length);
    c.effort = Math.max(c.effort, (a.effort || '').length);
    const lbl = (statusStyle[a.status] || statusStyle.offline).label;
    c.status = Math.max(c.status, lbl.length + 2);
    c.tool = Math.max(c.tool, shortenTool(a.currentTool || '').length);
    if (a.status !== 'offline') c.activity = Math.max(c.activity, timeAgo(a.lastActivity).length);
  }
  return c;
}

function renderRow(agent, idx, cols, compact) {
  const st = statusStyle[agent.status] || statusStyle.offline;
  const flashing = flashUntil[agent.name] && flashUntil[agent.name] > Date.now();
  const bcol = backendColor[agent.backend] || colors.white;
  const tool = shortenTool(agent.currentTool);
  const activity = agent.status === 'offline' ? '' : timeAgo(agent.lastActivity);
  // Foreground-only flash on state change: agent name flips to bright cyan briefly.
  const nameColor = flashing ? FLASH_FG : '';

  if (compact) {
    let line = ` ${st.color}${st.icon}${FG_RESET} `;
    line += `${nameColor}${pad(agent.name, cols.name)}${FG_RESET} `;
    line += `${st.color}${pad(st.label, cols.status)}${FG_RESET} `;
    line += `${agent.currentTool ? colors.magenta : ''}${pad(tool, cols.tool)}${FG_RESET} `;
    line += `${DIM_FG}${padRight(activity, cols.activity)}${FG_RESET}`;
    return line + RESET;
  }

  const model = shortenModel(agent.model);
  const sid = agent.sessionId ? agent.sessionId.slice(0, 16) : '';
  const effort = agent.effort || '';
  const ctx = ctxPct(agent.status !== 'offline' ? agent.contextPercent : null, cols.ctx);

  let line = ` ${nameColor}${pad(agent.name, cols.name)}${FG_RESET} `;
  line += `${bcol}${pad(agent.backend || '-', cols.backend)}${FG_RESET} `;
  line += `${pad(model, cols.model)} `;
  line += `${DIM_FG}${pad(effort, cols.effort)}${FG_RESET} `;
  line += `${ctx} `;
  line += `${st.color}${st.icon} ${pad(st.label, cols.status - 2)}${FG_RESET} `;
  line += `${agent.currentTool ? colors.magenta : ''}${pad(tool, cols.tool)}${FG_RESET} `;
  line += `${DIM_FG}${pad(sid, cols.session)}${FG_RESET} `;
  line += `${DIM_FG}${padRight(activity, cols.activity)}${FG_RESET}`;

  return line + RESET;
}

function render() {
  const rows = visibleRows();
  const lines = [];

  // Health-driven header tint
  const allRows = Object.values(agents);
  const anyError = allRows.some((a) => a.status === 'error');
  const anyHigh = (usage.anthropic && usage.anthropic.fiveHour > 80) || (usage.openai && usage.openai.fiveHour > 80);
  const headerColor =
    anyError || anyHigh
      ? colors.red
      : (usage.anthropic && usage.anthropic.fiveHour > 50) || (usage.openai && usage.openai.fiveHour > 50)
        ? colors.yellow
        : colors.cyan;

  // Active count for header summary
  const active = allRows.filter((a) => a.status !== 'offline' && a.status !== 'idle').length;
  const online = allRows.filter((a) => a.status !== 'offline').length;

  // Header
  let header = `${BOLD}${headerColor} ClawMux Monitor${RESET}`;
  header += `${DIM}  port ${PORT}  ${active} active  ${online} online  ${rows.length}/${allRows.length} shown${RESET}`;
  // View state badges
  const badges = [];
  if (view.filterActive) badges.push('active-only');
  if (view.sort === 'recent') badges.push('recent-sort');
  if (view.compact) badges.push('compact');
  if (view.backendFilter !== 'all') badges.push(`backend:${view.backendFilter}`);
  if (view.search) badges.push(`search:"${view.search}"`);
  if (badges.length) header += `  ${colors.cyan}[${badges.join(' ')}]${RESET}`;
  lines.push(header);
  lines.push('');

  // Dynamic column widths — derived from header label and the longest value in each column.
  // Keeps things "wide enough" so we never truncate, regardless of model name length etc.
  const cols = computeCols(rows, view.compact);
  const totalWidth = rowVisibleWidth(cols);

  if (view.compact) {
    lines.push(
      ` ${DIM}  ${pad('AGENT', cols.name)} ${pad('STATUS', cols.status)} ${pad('TOOL', cols.tool)} ${padRight('ACTIVITY', cols.activity)}${RESET}`,
    );
    lines.push(` ${DIM}${'─'.repeat(totalWidth)}${RESET}`);
  } else {
    lines.push(
      ` ${DIM}${pad('AGENT', cols.name)} ${pad('BACKEND', cols.backend)} ${pad('MODEL', cols.model)} ${pad('THINK', cols.effort)} ${padRight('CTX', cols.ctx)} ${pad('STATUS', cols.status)} ${pad('TOOL', cols.tool)} ${pad('SESSION', cols.session)} ${padRight('ACTIVITY', cols.activity)}${RESET}`,
    );
    lines.push(` ${DIM}${'─'.repeat(totalWidth)}${RESET}`);
  }

  rows.forEach(([, agent], idx) => {
    lines.push(renderRow(agent, idx, cols, view.compact));
  });

  // Rate limits footer
  lines.push('');
  if (usage.anthropic) {
    const proj = formatProjection(projectHours('anth5h'));
    lines.push(
      ` ${BOLD}Anthropic${RESET}  ${DIM}5h${RESET} ${usageBar(usage.anthropic.fiveHour)} ${padRight((usage.anthropic.fiveHour ?? '?') + '%', 4)}   ${DIM}7d${RESET} ${usageBar(usage.anthropic.weekly)} ${padRight((usage.anthropic.weekly ?? '?') + '%', 4)}   ${DIM}${proj}${RESET}`,
    );
  }
  if (usage.openai) {
    const proj = formatProjection(projectHours('oai5h'));
    lines.push(
      ` ${BOLD}OpenAI${RESET}     ${DIM}5h${RESET} ${usageBar(usage.openai.fiveHour)} ${padRight((usage.openai.fiveHour ?? '?') + '%', 4)}   ${DIM}7d${RESET} ${usageBar(usage.openai.weekly)} ${padRight((usage.openai.weekly ?? '?') + '%', 4)}   ${DIM}${proj}${RESET}`,
    );
  }

  // Keybinding hints
  lines.push('');
  if (view.searchMode) {
    lines.push(` ${colors.cyan}/${view.searchBuffer}${RESET}${DIM}  enter=apply  esc=cancel${RESET}`);
  } else {
    lines.push(
      ` ${DIM}[${RESET}f${DIM}]ilter [${RESET}s${DIM}]ort [${RESET}c${DIM}]ompact [${RESET}b${DIM}]ackend [${RESET}/${DIM}]search [${RESET}q${DIM}]uit${RESET}`,
    );
  }

  // Write in place
  let out = HOME;
  for (const line of lines) {
    out += ERASE_LINE + line + '\n';
  }
  if (lastLineCount > lines.length) {
    for (let i = 0; i < lastLineCount - lines.length; i++) {
      out += ERASE_LINE + '\n';
    }
  }
  out += ERASE_DOWN;
  lastLineCount = lines.length;

  process.stdout.write(out);
}

// ── Render loop (3 Hz) ──

const FRAME_MS = 333;

function scheduleRender() {
  setInterval(() => {
    render();
  }, FRAME_MS);
}

// ── State change tracking (for row flash) ──

function trackStateChanges(incoming) {
  for (const [id, a] of Object.entries(incoming)) {
    const name = a?.name;
    if (!name) continue;
    const prev = prevStatus[name];
    if (prev !== undefined && prev !== a.status) {
      flashUntil[name] = Date.now() + FLASH_MS;
    }
    prevStatus[name] = a.status;
  }
}

// ── Usage history snapshot (for projection) ──

function snapshotUsage() {
  if (!usage || (!usage.anthropic && !usage.openai)) return;
  const now = Date.now();
  usageHistory.push({
    ts: now,
    anth5h: usage.anthropic?.fiveHour ?? null,
    anth7d: usage.anthropic?.weekly ?? null,
    oai5h: usage.openai?.fiveHour ?? null,
    oai7d: usage.openai?.weekly ?? null,
  });
  // Trim
  while (usageHistory.length && now - usageHistory[0].ts > USAGE_HISTORY_MS) {
    usageHistory.shift();
  }
}
setInterval(snapshotUsage, 30000); // sample every 30s

// ── SSE connection ──

function connect() {
  const req = http.get(`http://${HOST}:${PORT}/api/monitor/stream`, (res) => {
    if (res.statusCode !== 200) {
      setTimeout(connect, 3000);
      return;
    }

    let buf = '';
    res.on('data', (chunk) => {
      buf += chunk.toString();
      const lines = buf.split('\n');
      buf = lines.pop();

      for (const line of lines) {
        if (line.startsWith('data: ')) {
          try {
            const data = JSON.parse(line.slice(6));
            if (data._usage) {
              usage = data._usage;
              delete data._usage;
            }
            trackStateChanges(data);
            Object.assign(agents, data);
          } catch {}
        }
      }
    });

    res.on('end', () => {
      process.stdout.write(`\n${colors.yellow}Connection lost. Reconnecting...${RESET}\n`);
      setTimeout(connect, 2000);
    });
  });

  req.on('error', (err) => {
    if (err.code === 'ECONNREFUSED') {
      process.stdout.write(`${colors.red}Cannot connect to ClawMux on port ${PORT}. Is the server running?${RESET}\n`);
      setTimeout(connect, 3000);
    } else {
      console.error(err.message);
      setTimeout(connect, 3000);
    }
  });
}

// ── Input handling ──

function cycleBackend() {
  const i = BACKENDS.indexOf(view.backendFilter);
  view.backendFilter = BACKENDS[(i + 1) % BACKENDS.length];
}

function handleKey(key) {
  // Ctrl-C anywhere
  if (key[0] === 0x03) {
    cleanup();
    process.exit(0);
  }

  if (view.searchMode) {
    if (key[0] === 0x1b) {
      // Esc: cancel
      view.searchMode = false;
      view.searchBuffer = '';
      view.search = '';
      return;
    }
    if (key[0] === 0x0d || key[0] === 0x0a) {
      // Enter: commit
      view.search = view.searchBuffer;
      view.searchMode = false;
      return;
    }
    if (key[0] === 0x7f || key[0] === 0x08) {
      // Backspace
      view.searchBuffer = view.searchBuffer.slice(0, -1);
      return;
    }
    // Printable
    const ch = key.toString('utf8');
    if (ch >= ' ' && ch.charCodeAt(0) < 0x7f) {
      view.searchBuffer += ch;
    }
    return;
  }

  const ch = String.fromCharCode(key[0]);
  switch (ch) {
    case 'q':
      cleanup();
      process.exit(0);
      break;
    case 'f':
      view.filterActive = !view.filterActive;
      break;
    case 's':
      view.sort = view.sort === 'alpha' ? 'recent' : 'alpha';
      break;
    case 'c':
      view.compact = !view.compact;
      break;
    case 'b':
      cycleBackend();
      break;
    case '/':
      view.searchMode = true;
      view.searchBuffer = view.search;
      break;
  }
}

if (process.stdin.isTTY) {
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.on('data', handleKey);
}

// ── Lifecycle ──

function cleanup() {
  process.stdout.write(MAIN_SCREEN + SHOW_CURSOR);
}

process.stdout.write(ALT_SCREEN + HIDE_CURSOR);
process.on('exit', cleanup);
process.on('SIGINT', () => {
  cleanup();
  process.exit(0);
});
process.on('SIGTERM', () => {
  cleanup();
  process.exit(0);
});

scheduleRender();
connect();
