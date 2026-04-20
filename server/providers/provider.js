/**
 * Provider registry — auto-discovers provider files in this directory.
 *
 * Convention: each `*-provider.js` exports a class whose `.name` property
 * matches the backend key in backends.json.  Drop a new file here and add
 * a backends.json entry — zero edits to this registry needed.
 */

import { readdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { getDefaultBackend } from '../config.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Auto-discover *-provider.js files and import them
const providers = {};

const files = readdirSync(__dirname).filter((f) => f.endsWith('-provider.js') && f !== 'provider.js');

for (const file of files) {
  const mod = await import(join(__dirname, file));
  // Find the exported class (first PascalCase export with a prototype)
  const ProviderClass = Object.values(mod).find(
    (v) => typeof v === 'function' && v.prototype && v.prototype.constructor === v,
  );
  if (ProviderClass) {
    const instance = new ProviderClass();
    providers[instance.name] = ProviderClass;
  }
}

// Retired provider names that gracefully fall back to the configured default
// (so stale client state doesn't break sessions on reload).
const RETIRED_ALIASES = {
  openclaw: null, // resolved lazily to getDefaultBackend()
  glueclaw: null,
};

/**
 * Get a provider instance by name.
 * @param {string} name
 * @returns {Provider}
 */
export function getProvider(name) {
  if (name in RETIRED_ALIASES) {
    const target = RETIRED_ALIASES[name] || getDefaultBackend();
    console.warn(`[providers] retired provider "${name}" → falling back to "${target}"`);
    name = target;
  }
  const Provider = providers[name];
  if (!Provider) throw new Error(`Unknown provider: ${name}. Available: ${Object.keys(providers).join(', ')}`);
  return new Provider();
}

/**
 * List available provider names.
 */
export function listProviders() {
  return Object.keys(providers);
}
