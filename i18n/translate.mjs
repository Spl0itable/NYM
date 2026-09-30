// Build-time translation through this app's own backend

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const PROXY = process.env.NYM_TRANSLATE_PROXY || 'https://web.nymchat.app/api/proxy';
const BUILD_TOKEN = (process.env.NYM_BUILD_TOKEN || '').trim();
const proxyHeaders = () => ({
  'Content-Type': 'application/json',
  'User-Agent': 'NymchatBuild/1 (i18n sync)',
  ...(BUILD_TOKEN ? { 'X-Nym-Build': BUILD_TOKEN } : {}),
});
// Overridable so tests never touch the committed cache.
const CACHE_DIR = process.env.NYM_I18N_CACHE_DIR || new URL('./cache/', import.meta.url).pathname;

// The proxy fans out to Google Translate, so this is polite rather than fast.
const CONCURRENCY = 6;
const RETRIES = 3;

// Base pause after a throttle, doubling per attempt; overridable for tests.
const THROTTLE_MS = Number(process.env.NYM_I18N_THROTTLE_MS || 6000);

// Node's fetch has no default timeout, so a half-open connection would stall the run.
const REQUEST_TIMEOUT_MS = Number(process.env.NYM_I18N_TIMEOUT_MS || 30000);
const signal = () => AbortSignal.timeout(REQUEST_TIMEOUT_MS);

// Module-level hook: a single-run CLI with one consumer.
let notifier = null;
export const onNotice = (fn) => { notifier = fn; };
const notice = (text) => notifier?.(text);

// Mirrors and stays under the backend limits (TRANSLATE_BATCH_MAX / _BYTES in functions/api/proxy.js).
const BATCH_STRINGS = 20;
const BATCH_CHARS = 16000;

export const cachePath = (lang, dir = CACHE_DIR) => path.join(dir, `${lang}.json`);

export async function loadCache(lang, dir = CACHE_DIR) {
  try {
    return JSON.parse(await readFile(cachePath(lang, dir), 'utf8'));
  } catch {
    return {};
  }
}

export async function saveCache(lang, map, dir = CACHE_DIR) {
  await mkdir(dir, { recursive: true });
  // Sorted keys so a re-run produces no spurious diff.
  const sorted = {};
  for (const key of Object.keys(map).sort()) sorted[key] = map[key];
  await writeFile(cachePath(lang, dir), JSON.stringify(sorted, null, 2) + '\n');
}

// Used when a batch comes back short, so one bad string costs only itself.
async function viaProxy(text, target) {
  const res = await fetch(`${PROXY}?action=translate`, {
    method: 'POST',
    headers: proxyHeaders(),
    body: JSON.stringify({ text, source: 'en', target }),
    signal: signal(),
  });
  if (!res.ok) throw new Error(`proxy ${res.status}`);
  const data = await res.json();
  if (data && data.error) throw new Error(data.error);
  return (data && data.translatedText) || '';
}

// Positional results; null is a per-string failure, a wrong-length response throws.
async function viaProxyBatch(texts, target) {
  const res = await fetch(`${PROXY}?action=translate`, {
    method: 'POST',
    headers: proxyHeaders(),
    body: JSON.stringify({ texts, source: 'en', target }),
    signal: signal(),
  });
  if (!res.ok) throw new Error(`proxy ${res.status}`);
  const data = await res.json();
  if (data && data.error) throw new Error(data.error);
  const out = data && Array.isArray(data.translations) ? data.translations : null;
  if (!out || out.length !== texts.length) {
    throw new Error('batch response did not line up with the request');
  }
  return out.map((v) => (typeof v === 'string' && v.trim() ? v : null));
}

// Kept as a function so reporting stays in one place.
let route = null;

function pickRoute() {
  if (!route) {
    notice(`route: ${PROXY}`);
    route = viaProxyBatch;
  }
  return Promise.resolve(route);
}

// The upstream also soft-throttles with a 200 carrying an empty translation.
const isThrottled = (err) => /\b(429|403)\b|empty translation/.test(String(err && err.message));

// Shared cooldown: every worker waits when one request is throttled.
let cooldownUntil = 0;
const cooldown = () => {
  const left = cooldownUntil - Date.now();
  return left > 0 ? new Promise((r) => setTimeout(r, left)) : Promise.resolve();
};

// Pauses much longer when throttled than after a transient 5xx.
async function withRetries(attempt) {
  for (let i = 0; i < RETRIES; i++) {
    await cooldown();
    try {
      return await attempt();
    } catch (err) {
      if (i === RETRIES - 1) throw err;
      const wait = isThrottled(err) ? THROTTLE_MS * Math.pow(2, i) : 400 * Math.pow(2, i);
      if (isThrottled(err)) {
        cooldownUntil = Math.max(cooldownUntil, Date.now() + wait);
        // Every worker is about to block, so say so or it reads as a hang.
        notice(`throttled (${err.message}) — pausing ${wait < 1000 ? `${wait}ms` : `${Math.round(wait / 1000)}s`}`);
      }
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw new Error('unreachable');
}

async function translateOne(text, target) {
  return withRetries(async () => {
    const out = await viaProxy(text, target);
    if (!out.trim()) throw new Error('empty translation');
    return out;
  });
}

function batches(texts) {
  const out = [];
  let current = [];
  let bytes = 0;
  for (const text of texts) {
    const cost = text.slice(0, 5000).length;
    if (current.length > 0 && (current.length >= BATCH_STRINGS || bytes + cost > BATCH_CHARS)) {
      out.push(current);
      current = [];
      bytes = 0;
    }
    current.push(text);
    bytes += cost;
  }
  if (current.length > 0) out.push(current);
  return out;
}

// Remembered for the run: an older deployment answers 400 to every batch.
let batchUnsupported = false;

// Malformed batches retry string by string, sequentially after any cooldown; reasons are recorded per string.
async function translateGroup(texts, target, reasons) {
  await pickRoute();
  const one = async (text) => {
    try { return await translateOne(text, target); }
    catch (err) { reasons.set(text, err.message || String(err)); return null; }
  };
  if (texts.length === 1 || batchUnsupported) {
    const out = [];
    for (const text of texts) out.push(await one(text));
    return out;
  }
  try {
    const out = await withRetries(() => viaProxyBatch(texts, target));
    // Retry just the holes, sequentially.
    for (let i = 0; i < out.length; i++) {
      if (out[i] === null) out[i] = await one(texts[i]);
    }
    return out;
  } catch (err) {
    // A 400 means an older deployment that doesn't know `texts[]`; say so once.
    if (/\b400\b/.test(err.message || '') && !batchUnsupported) {
      batchUnsupported = true;
      notice(`the backend rejected a batch (${err.message}) — this host is `
        + 'probably running an older deployment without the batch endpoint. '
        + 'Falling back to one request per string for the rest of this run.');
    }
    if (isThrottled(err)) cooldownUntil = Math.max(cooldownUntil, Date.now() + THROTTLE_MS);
    // Return null per failed string so the rest of the batch survives.
    const out = [];
    for (const text of texts) out.push(await one(text));
    return out;
  }
}

export const activeRoute = () => (route ? PROXY : 'unknown');

// Drops entries whose English source is no longer in the app.
function prune(cache, sources) {
  const live = new Set(sources);
  const out = {};
  for (const [key, value] of Object.entries(cache)) {
    if (live.has(key)) out[key] = value;
  }
  return out;
}

// The prune deletes every key outside `sources`, so unrelated source sets need their own cacheDir.
export async function translateMissing(lang, sources, { onProgress, cacheDir = CACHE_DIR } = {}) {
  const cache = await loadCache(lang, cacheDir);
  const missing = sources.filter((s) => typeof cache[s] !== 'string');
  if (missing.length === 0) {
    // Still prune: copy may have been removed since the last run.
    const kept = prune(cache, sources);
    if (Object.keys(kept).length !== Object.keys(cache).length) {
      await saveCache(lang, kept, cacheDir);
    }
    return { cache: kept, translated: 0 };
  }

  // Decide the route before splitting the work, since the queue shape follows from it.
  await pickRoute();
  const queue = batches(missing);

  let index = 0;
  let done = 0;
  const failures = [];
  const reasons = new Map();

  const worker = async () => {
    while (index < queue.length) {
      const group = queue[index++];
      try {
        const translated = await translateGroup(group, lang, reasons);
        group.forEach((source, i) => {
          if (typeof translated[i] === 'string') cache[source] = translated[i];
          else failures.push({ source, error: reasons.get(source) || 'no translation returned' });
        });
      } catch (err) {
        for (const source of group) failures.push({ source, error: String(err.message || err) });
      }
      done += group.length;
      onProgress?.(done, missing.length);
    }
  };

  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, queue.length) }, worker));

  // Save partial progress: the app translates missing strings at runtime, and re-runs resume.
  await saveCache(lang, prune(cache, sources), cacheDir);

  if (failures.length > 0) {
    const sample = failures.slice(0, 3).map((f) => `${JSON.stringify(f.source.slice(0, 40))}: ${f.error}`);
    throw new Error(
      `${lang}: ${failures.length}/${missing.length} strings failed to translate`
      + ` (${missing.length - failures.length} kept; re-run to finish)\n  ${sample.join('\n  ')}`);
  }

  return { cache, translated: missing.length };
}
