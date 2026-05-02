import { join } from 'path';

export const CLAWMUX_SERVICE_NAME = 'clawmux';
export const CLAWMUX_SERVICE_FILE = `${CLAWMUX_SERVICE_NAME}.service`;
export const CLAWMUX_LAUNCHD_LABEL = 'com.clawmux.server';
export const CLAWMUX_CRON_MARKER = '# clawmux-server';

export function serviceEnvironment({
  port = '3470',
  host = '127.0.0.1',
  httpsPort = '3471',
  httpsHost = '127.0.0.1',
  tailscaleMode = 'ensure',
} = {}) {
  return {
    PORT: String(port),
    HOST: String(host),
    HTTPS_PORT: String(httpsPort),
    HTTPS_HOST: String(httpsHost),
    CLAWMUX_TAILSCALE_SERVE: String(tailscaleMode),
  };
}

export function systemdUnit({ repoDir, nodePath, logPath, env = serviceEnvironment() }) {
  return `[Unit]
Description=ClawMux server
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${repoDir}
${Object.entries(env)
  .map(([key, value]) => `Environment=${key}=${value}`)
  .join('\n')}
ExecStart=${nodePath} ${join(repoDir, 'server.js')}
Restart=on-failure
RestartSec=5
StandardOutput=append:${logPath}
StandardError=append:${logPath}

[Install]
WantedBy=default.target
`;
}

function xmlEscape(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

export function launchdPlist({ repoDir, nodePath, logPath, env = serviceEnvironment() }) {
  const envXml = Object.entries(env)
    .map(([key, value]) => `      <key>${xmlEscape(key)}</key>\n      <string>${xmlEscape(value)}</string>`)
    .join('\n');

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${CLAWMUX_LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xmlEscape(nodePath)}</string>
    <string>${xmlEscape(join(repoDir, 'server.js'))}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${xmlEscape(repoDir)}</string>
  <key>EnvironmentVariables</key>
  <dict>
${envXml}
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${xmlEscape(logPath)}</string>
  <key>StandardErrorPath</key>
  <string>${xmlEscape(logPath)}</string>
</dict>
</plist>
`;
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

export function cronLine({ repoDir, nodePath, logPath, env = serviceEnvironment() }) {
  const envPrefix = Object.entries(env)
    .map(([key, value]) => `${key}=${shellQuote(value)}`)
    .join(' ');
  return `@reboot cd ${shellQuote(repoDir)} && ${envPrefix} ${shellQuote(nodePath)} ${shellQuote(
    join(repoDir, 'server.js'),
  )} >> ${shellQuote(logPath)} 2>&1 ${CLAWMUX_CRON_MARKER}`;
}

export function systemdUnitPath(homeDir) {
  return join(homeDir, '.config', 'systemd', 'user', CLAWMUX_SERVICE_FILE);
}

export function launchdPlistPath(homeDir) {
  return join(homeDir, 'Library', 'LaunchAgents', `${CLAWMUX_LAUNCHD_LABEL}.plist`);
}
