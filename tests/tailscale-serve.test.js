import test from 'node:test';
import assert from 'node:assert/strict';

import {
  checkTailscaleServeStatus,
  expectedTailscaleTarget,
  normalizeTailscaleDnsName,
} from '../server/tailscale-serve.js';

test('tailscale serve status checker accepts the expected ClawMux proxy mapping', () => {
  const status = {
    Web: {
      'workstation.tailee9084.ts.net:3471': {
        Handlers: {
          '/': {
            Proxy: 'https+insecure://127.0.0.1:3471',
          },
        },
      },
    },
  };

  const result = checkTailscaleServeStatus(status, {
    dnsName: 'workstation.tailee9084.ts.net.',
    port: 3471,
    target: expectedTailscaleTarget(3471),
  });

  assert.equal(result.ok, true);
  assert.equal(result.url, 'https://workstation.tailee9084.ts.net:3471/');
});

test('tailscale serve status checker reports a wrong proxy target', () => {
  const status = {
    Web: {
      'workstation.tailee9084.ts.net:3471': {
        Handlers: {
          '/': {
            Proxy: 'http://127.0.0.1:3470',
          },
        },
      },
    },
  };

  const result = checkTailscaleServeStatus(status, {
    dnsName: 'workstation.tailee9084.ts.net',
    port: 3471,
    target: expectedTailscaleTarget(3471),
  });

  assert.equal(result.ok, false);
  assert.equal(result.actualTarget, 'http://127.0.0.1:3470');
});

test('tailscale dns names are normalized for serve status keys', () => {
  assert.equal(normalizeTailscaleDnsName('workstation.tailee9084.ts.net.'), 'workstation.tailee9084.ts.net');
  assert.equal(normalizeTailscaleDnsName('workstation.tailee9084.ts.net'), 'workstation.tailee9084.ts.net');
});
