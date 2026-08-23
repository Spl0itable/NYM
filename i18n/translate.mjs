// Build-time translation through this app's own backend

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const PROXY = process.env.NYM_TRANSLATE_PROXY || 'https://web.nymchat.app/api/proxy';
// Overridable so tests never touch the committed cache.
const CACHE_DIR = process.env.NYM_I18N_CACHE_DIR || new URL('./cache/', import.meta.url).pathname;

/// Concurrent requests. The proxy fans out to Google Translate, so this is
/// polite rather than fast.
const CONCURRENCY = 6;
const RETRIES = 3;

/// Base pause after a throttle, doubling per attempt. Overridable so the tests
/// can exercise the retry path without waiting out a real backoff.
const THROTTLE_MS = Number(process.env.NYM_I18N_THROTTLE_MS || 6000);

/// A request that never answers must not stall the run forever. Node's fetch
/// has no default timeout, so without this a half-open connection looks exactly
/// like slow progress — and this job runs long enough that "looks stuck" and
/// "is stuck" have to be distinguishable.
const REQUEST_TIMEOUT_MS = Number(process.env.NYM_I18N_TIMEOUT_MS || 30000);
const signal = () => AbortSignal.timeout(REQUEST_TIMEOUT_MS);

/// Out-of-band progress: which route was chosen, and when the run is sitting
/// out a throttle. A module-level hook rather than a parameter threaded through
/// five functions, because this is a single-run CLI with exactly one consumer —
/// and a backoff nobody can see is the whole reason this exists.
let notifier = null;
export const onNotice = (fn) => { notifier = fn; };
const notice = (text) => notifier?.(text);

/// How many strings go in one request. Both limits mirror the backend's
/// (TRANSLATE_BATCH_MAX / TRANSLATE_BATCH_BYTES in functions/api/proxy.js) and
/// sit under them, so an over-large batch is a bug here rather than a 400 from
/// there. The payload is JSON now, not a query string, so the bound is on the
/// text itself.
const BATCH_STRINGS = 20;
const BATCH_CHARS = 16000;

export const cachePath = (lang) => path.join(CACHE_DIR, `${lang}.json`);

export async function loadCache(lang) {
  try {
    return JSON.parse(await readFile(cachePath(lang), 'utf8'));
  } catch {
    return {};
  }
}

export async function saveCache(lang, map) {
  await mkdir(CACHE_DIR, { recursive: true });
  // Sorted keys so a re-run produces no spurious diff.
  const sorted = {};
  for (const key of Object.keys(map).sort()) sorted[key] = map[key];
  await writeFile(cachePath(lang), JSON.stringify(sorted, null, 2) + '\n');
}

/// One string. Used when a batch comes back short, so a single bad string
/// costs itself rather than its nineteen neighbours.
async function viaProxy(text, target) {
  const res = await fetch(`${PROXY}?action=translate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, source: 'en', target }),
    signal: signal(),
  });
  if (!res.ok) throw new Error(`proxy ${res.status}`);
  const data = await res.json();
  if (data && data.error) throw new Error(data.error);
  return (data && data.translatedText) || '';
}

/// Many strings, one request. The backend still runs one inference per string;
/// what this saves is the round trip, which is most of the wall clock when
/// there are two hundred thousand of them to get through.
///
/// Returns translations positionally. A `null` is a string the backend could
/// not translate — reported rather than hidden, so the caller can retry just
/// that one. A response of the wrong LENGTH is different and throws: there is
/// no way to tell which translation belongs to which source, so none of it is
/// usable.
async function viaProxyBatch(texts, target) {
  const res = await fetch(`${PROXY}?action=translate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
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

/// The one route there is. Kept as a function so the reporting stays in one
/// place and the shape survives if a second backend ever appears.
let route = null;

function pickRoute() {
  if (!route) {
    notice(`route: ${PROXY}`);
    route = viaProxyBatch;
  }
  return Promise.resolve(route);
}

/// What throttling looks like on this upstream.
///
/// A 429 or a 403 is the obvious form. The one that is not obvious, and cost
/// three languages a full run, is a 200 carrying an EMPTY translation: the
/// endpoint soft-throttles by answering successfully with nothing in it. Read
/// as "transient error" that gets a few hundred milliseconds of backoff, which
/// under throttling is no wait at all, and the retries are spent for nothing.
const isThrottled = (err) => /\b(429|403)\b|empty translation/.test(String(err && err.message));

/// When one request is throttled, every worker waits. Six workers each backing
/// off privately still means six requests a second at a server that has just
/// asked for fewer, so the pause is shared.
let cooldownUntil = 0;
const cooldown = () => {
  const left = cooldownUntil - Date.now();
  return left > 0 ? new Promise((r) => setTimeout(r, left)) : Promise.resolve();
};

/// Retries [attempt] a few times, pausing much longer when throttled than after
/// a transient 5xx.
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
        // Every worker is about to block on this, so the run goes silent for
        // `wait` ms. Say so, or it reads as a hang.
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

/// Splits [texts] into requests the backend will accept.
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

/// Translates a group of strings, as one request where the route allows it.
/// A batch that comes back malformed is retried string by string rather than
/// failing the language: one unlucky response should not cost a whole run.
///
/// The fallback is SEQUENTIAL, and waits out any cooldown first. Fanning a
/// failed batch of twenty into twenty concurrent requests is the worst possible
/// response to being throttled, and it is why failures arrived in exact
/// multiples of the batch size: one throttled batch became twenty throttled
/// strings, all of them spending their retries inside the same bad window.
async function translateGroup(texts, target) {
  await pickRoute();
  if (texts.length === 1) {
    try { return [await translateOne(texts[0], target)]; }
    catch { return [null]; }
  }
  try {
    const out = await withRetries(() => viaProxyBatch(texts, target));
    // A batch that came back with holes in it: retry just those, sequentially,
    // rather than re-sending the whole group.
    if (out.some((v) => v === null)) {
      for (let i = 0; i < out.length; i++) {
        if (out[i] !== null) continue;
        try { out[i] = await translateOne(texts[i], target); }
        catch { out[i] = null; }
      }
    }
    return out;
  } catch (err) {
    if (isThrottled(err)) cooldownUntil = Math.max(cooldownUntil, Date.now() + THROTTLE_MS);
    // One string's failure is one string's failure. Returning `null` for it
    // keeps the other nineteen, and lets the caller name the string that
    // actually failed instead of blaming the batch it happened to be in.
    const out = [];
    for (const text of texts) {
      try { out.push(await translateOne(text, target)); }
      catch { out.push(null); }
    }
    return out;
  }
}

/// The route actually in use, for the CLI to report.
export const activeRoute = () => (route ? PROXY : 'unknown');

/// Translates every source string missing from [lang]'s cache and returns the
/// merged map. Strings already cached cost nothing.
/// Drops entries whose English source is no longer in the app, so the committed
/// cache tracks the interface instead of growing forever.
function prune(cache, sources) {
  const live = new Set(sources);
  const out = {};
  for (const [key, value] of Object.entries(cache)) {
    if (live.has(key)) out[key] = value;
  }
  return out;
}

export async function translateMissing(lang, sources, { onProgress } = {}) {
  const cache = await loadCache(lang);
  const missing = sources.filter((s) => typeof cache[s] !== 'string');
  if (missing.length === 0) {
    // Still prune: copy may have been removed since the last run.
    const kept = prune(cache, sources);
    if (Object.keys(kept).length !== Object.keys(cache).length) await saveCache(lang, kept);
    return { cache: kept, translated: 0 };
  }

  // Decide the route before splitting the work: the proxy takes one string per
  // request, the fallback takes many, and the shape of the queue follows from
  // which one is answering.
  await pickRoute();
  const queue = batches(missing);

  let index = 0;
  let done = 0;
  const failures = [];

  const worker = async () => {
    while (index < queue.length) {
      const group = queue[index++];
      try {
        const translated = await translateGroup(group, lang);
        group.forEach((source, i) => {
          if (typeof translated[i] === 'string') cache[source] = translated[i];
          else failures.push({ source, error: 'no translation returned' });
        });
      } catch (err) {
        for (const source of group) failures.push({ source, error: String(err.message || err) });
      }
      done += group.length;
      onProgress?.(done, missing.length);
    }
  };

  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, queue.length) }, worker));

  // What succeeded is written even when something failed. It used to be
  // discarded: a language that lost one string to a transient upstream error
  // threw away the other fifteen hundred translations of that run, so the next
  // attempt started from the same place, did the same work, hit the same wall
  // and discarded it again. Three languages sat at 440/1960 through several
  // runs for exactly that reason — "re-run to retry, cached strings are not
  // re-sent" was a promise the code could not keep.
  //
  // A partial cache is still useful here, unlike on the landing page: the app
  // falls back to translating at runtime for anything the pack is missing, so
  // shipping 1200 of 1300 strings is 1200 strings the user does not wait for.
  // Saving progress is therefore always right.
  await saveCache(lang, prune(cache, sources));

  if (failures.length > 0) {
    const sample = failures.slice(0, 3).map((f) => `${JSON.stringify(f.source.slice(0, 40))}: ${f.error}`);
    throw new Error(
      `${lang}: ${failures.length}/${missing.length} strings failed to translate`
      + ` (${missing.length - failures.length} kept; re-run to finish)\n  ${sample.join('\n  ')}`);
  }

  return { cache, translated: missing.length };
}
