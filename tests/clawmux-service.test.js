import test from 'node:test';
import assert from 'node:assert/strict';

import {
  CLAWMUX_CRON_MARKER,
  cronLine,
  launchdPlist,
  serviceEnvironment,
  systemdUnit,
} from '../server/clawmux-service.js';

const env = serviceEnvironment({
  port: 3470,
  host: '127.0.0.1',
  httpsPort: 3471,
  httpsHost: '127.0.0.1',
  tailscaleMode: 'ensure',
});

test('systemd unit starts ClawMux with local HTTPS and tailscale ensure mode', () => {
  const unit = systemdUnit({
    repoDir: '/repo/clawmux',
    nodePath: '/usr/bin/node',
    logPath: '/home/zeul/.clawmux/server.log',
    env,
  });

  assert.match(unit, /WorkingDirectory=\/repo\/clawmux/);
  assert.match(unit, /Environment=PORT=3470/);
  assert.match(unit, /Environment=HTTPS_HOST=127\.0\.0\.1/);
  assert.match(unit, /Environment=CLAWMUX_TAILSCALE_SERVE=ensure/);
  assert.match(unit, /ExecStart=\/usr\/bin\/node \/repo\/clawmux\/server\.js/);
  assert.match(unit, /Restart=on-failure/);
});

test('launchd plist preserves environment and log paths', () => {
  const plist = launchdPlist({
    repoDir: '/repo/clawmux',
    nodePath: '/usr/local/bin/node',
    logPath: '/tmp/clawmux.log',
    env,
  });

  assert.match(plist, /<string>com\.clawmux\.server<\/string>/);
  assert.match(plist, /<key>CLAWMUX_TAILSCALE_SERVE<\/key>\n      <string>ensure<\/string>/);
  assert.match(plist, /<key>KeepAlive<\/key>\n  <true\/>/);
  assert.match(plist, /<string>\/tmp\/clawmux\.log<\/string>/);
});

test('cron line is marked and shell quoted', () => {
  const line = cronLine({
    repoDir: "/repo/claw'mux",
    nodePath: '/usr/bin/node',
    logPath: '/tmp/clawmux.log',
    env,
  });

  assert.match(line, /^@reboot /);
  assert.match(line, /CLAWMUX_TAILSCALE_SERVE='ensure'/);
  assert.match(line, /'\/repo\/claw'\\''mux'/);
  assert.ok(line.endsWith(CLAWMUX_CRON_MARKER));
});
