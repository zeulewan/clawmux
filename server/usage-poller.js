/**
 * Usage poller — polls Anthropic OAuth usage API for 5h/7d utilization.
 * Reads OAuth token from ~/.claude/.credentials.json
 */

import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const CREDENTIALS_PATH = join(homedir(), '.claude', '.credentials.json');
const USAGE_API_URL = 'https://api.anthropic.com/api/oauth/usage';
const POLL_INTERVAL = 300000; // 5 minutes

let lastUsage = null;
let pollTimer = null;

function getToken() {
  try {
    if (!existsSync(CREDENTIALS_PATH)) return null;
    const creds = JSON.parse(readFileSync(CREDENTIALS_PATH, 'utf8'));
    return creds?.claudeAiOauth?.accessToken || null;
  } catch {
    return null;
  }
}

async function fetchUsage() {
  const token = getToken();
  if (!token) return null;
  try {
    const resp = await fetch(USAGE_API_URL, {
      headers: {
        Authorization: `Bearer ${token}`,
        'anthropic-beta': 'oauth-2025-04-20',
      },
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    if (!data.five_hour) return null;
    lastUsage = {
      fiveHour: { percent: Math.round(data.five_hour.utilization), resetsAt: data.five_hour.resets_at },
      weekly: { percent: Math.round(data.seven_day.utilization), resetsAt: data.seven_day.resets_at },
    };
    return lastUsage;
  } catch {
    return null;
  }
}

let _onUpdate = null;

export function getLastUsage() {
  return lastUsage;
}

export function onUsageUpdate(fn) {
  _onUpdate = fn;
}

export function startPolling() {
  fetchUsage().then((u) => {
    if (u) {
      console.log(`[usage] 5h: ${u.fiveHour.percent}%, 7d: ${u.weekly.percent}%`);
      if (_onUpdate) _onUpdate(u);
    }
  });
  pollTimer = setInterval(() => {
    fetchUsage().then((u) => {
      if (u) {
        console.log(`[usage] 5h: ${u.fiveHour.percent}%, 7d: ${u.weekly.percent}%`);
        if (_onUpdate) _onUpdate(u);
      }
    });
  }, POLL_INTERVAL);
}

export function stopPolling() {
  if (pollTimer) clearInterval(pollTimer);
}
