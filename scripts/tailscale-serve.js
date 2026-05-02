#!/usr/bin/env node

import { checkTailscaleServe, ensureTailscaleServe, expectedTailscaleTarget } from '../server/tailscale-serve.js';

const mode = process.argv[2] || 'check';
const port = process.env.HTTPS_PORT || 3471;
const localHost = process.env.CLAWMUX_TAILSCALE_TARGET_HOST || '127.0.0.1';
const target = process.env.CLAWMUX_TAILSCALE_TARGET || expectedTailscaleTarget(port, localHost);

if (!['check', 'ensure'].includes(mode)) {
  console.error('Usage: node scripts/tailscale-serve.js [check|ensure]');
  process.exit(2);
}

const result =
  mode === 'ensure' ? await ensureTailscaleServe({ port, target }) : await checkTailscaleServe({ port, target });

if (!result.ok) {
  console.error(
    `[tailscale] mismatch for ${result.webKey || `:${port}`}: expected ${result.expectedTarget}, found ${
      result.actualTarget || 'nothing'
    }`,
  );
  process.exit(1);
}

console.log(`[tailscale] ok: ${result.url} -> ${result.expectedTarget}${result.changed ? ' (updated)' : ''}`);
