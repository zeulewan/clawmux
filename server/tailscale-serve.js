import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const DEFAULT_TAILSCALE_CMD = process.env.TAILSCALE_CMD || 'tailscale';
const DEFAULT_TAILSCALE_TIMEOUT_MS = Number(process.env.TAILSCALE_TIMEOUT_MS || 5000);

export function normalizeTailscaleDnsName(name) {
  return typeof name === 'string' && name ? name.replace(/\.$/, '') : null;
}

export function expectedTailscaleTarget(port, host = '127.0.0.1') {
  return `https+insecure://${host}:${port}`;
}

export function checkTailscaleServeStatus(status, { dnsName, port, target }) {
  const host = normalizeTailscaleDnsName(dnsName);
  const webKey = host ? `${host}:${port}` : null;
  const actualTarget = webKey ? status?.Web?.[webKey]?.Handlers?.['/']?.Proxy || null : null;
  return {
    ok: actualTarget === target,
    url: host ? `https://${host}:${port}/` : null,
    webKey,
    expectedTarget: target,
    actualTarget,
  };
}

async function execJson(args, execFileImpl = execFileAsync) {
  const { stdout } = await execFileImpl(DEFAULT_TAILSCALE_CMD, args, {
    maxBuffer: 1024 * 1024 * 10,
    timeout: DEFAULT_TAILSCALE_TIMEOUT_MS,
  });
  return JSON.parse(stdout);
}

export async function getTailscaleDnsName({ execFileImpl } = {}) {
  const status = await execJson(['status', '--json'], execFileImpl);
  return normalizeTailscaleDnsName(status?.Self?.DNSName);
}

export async function checkTailscaleServe({ port, target, dnsName, execFileImpl } = {}) {
  const resolvedDnsName = normalizeTailscaleDnsName(dnsName) || (await getTailscaleDnsName({ execFileImpl }));
  const status = await execJson(['serve', 'status', '--json'], execFileImpl);
  return checkTailscaleServeStatus(status, { dnsName: resolvedDnsName, port, target });
}

export async function ensureTailscaleServe({ port, target, dnsName, execFileImpl = execFileAsync } = {}) {
  const before = await checkTailscaleServe({ port, target, dnsName, execFileImpl });
  if (before.ok) return { ...before, changed: false };

  await execFileImpl(DEFAULT_TAILSCALE_CMD, ['serve', '--yes', '--bg', '--https', String(port), target], {
    maxBuffer: 1024 * 1024 * 10,
    timeout: DEFAULT_TAILSCALE_TIMEOUT_MS,
  });

  const after = await checkTailscaleServe({ port, target, dnsName, execFileImpl });
  return { ...after, changed: after.ok };
}

export async function maybeConfigureTailscaleServe({ port, localHost = '127.0.0.1', mode, log = console } = {}) {
  const configuredMode = mode || process.env.CLAWMUX_TAILSCALE_SERVE || 'check';
  if (configuredMode === 'off' || configuredMode === '0' || configuredMode === 'false') return null;

  const target = process.env.CLAWMUX_TAILSCALE_TARGET || expectedTailscaleTarget(port, localHost);
  try {
    const result =
      configuredMode === 'ensure'
        ? await ensureTailscaleServe({ port, target })
        : await checkTailscaleServe({ port, target });

    if (result.ok) {
      log.log(`[tailscale] serve ok: ${result.url} -> ${result.expectedTarget}`);
    } else {
      log.warn(
        `[tailscale] serve mismatch for ${result.webKey || `:${port}`}: expected ${result.expectedTarget}, found ${
          result.actualTarget || 'nothing'
        }. Run npm run tailscale:ensure to repair it.`,
      );
    }
    return result;
  } catch (err) {
    log.warn(`[tailscale] serve check failed: ${err.message}`);
    return null;
  }
}
