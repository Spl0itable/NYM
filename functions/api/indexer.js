// Cloudflare Pages Function: R2-backed Nostr event indexer reader
//
// GET /api/indexer?kind=<n>&limit=<n>            - events of a kind
// GET /api/indexer?kind=1059&p=<pubkey>&limit=N  - gift wraps for a recipient
//
// R2 objects are written by /api/relay-pool as it observes deduplicated
// events from upstream relays. Lifecycle on the bucket trims data to 24h.

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

const ALLOWED_KINDS = new Set([0, 5, 7, 1059, 9735, 20000, 23333, 30030, 30078]);
const MAX_LIMIT = 1000;
const FETCH_CONCURRENCY = 32;

function jsonResponse(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
      ...CORS_HEADERS,
      ...extraHeaders,
    },
  });
}

async function fetchBatch(bucket, keys) {
  const out = new Array(keys.length);
  let next = 0;
  async function worker() {
    while (true) {
      const i = next++;
      if (i >= keys.length) return;
      try {
        const obj = await bucket.get(keys[i]);
        if (!obj) { out[i] = null; continue; }
        const text = await obj.text();
        out[i] = text;
      } catch {
        out[i] = null;
      }
    }
  }
  const workers = [];
  for (let w = 0; w < Math.min(FETCH_CONCURRENCY, keys.length); w++) workers.push(worker());
  await Promise.all(workers);
  return out;
}

export async function onRequest(context) {
  const { request, env } = context;

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (request.method !== 'GET') {
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }
  if (!env || !env.R2_BUCKET) {
    return jsonResponse({ error: 'Indexer not configured (missing R2_BUCKET binding)' }, 503);
  }

  const url = new URL(request.url);
  const kind = parseInt(url.searchParams.get('kind'), 10);
  if (!Number.isFinite(kind) || !ALLOWED_KINDS.has(kind)) {
    return jsonResponse({ error: 'invalid or unsupported kind' }, 400);
  }
  const limit = Math.min(MAX_LIMIT, Math.max(1, parseInt(url.searchParams.get('limit'), 10) || 500));
  const p = (url.searchParams.get('p') || '').toLowerCase();

  let prefix;
  if (kind === 1059) {
    if (!/^[a-f0-9]{64}$/.test(p)) {
      return jsonResponse({ error: 'p (recipient pubkey hex) required for kind 1059' }, 400);
    }
    prefix = `idx/1059/p/${p}/`;
  } else {
    prefix = `idx/${kind}/`;
  }

  const keys = [];
  let cursor;
  while (keys.length < limit) {
    const listOpts = { prefix, limit: Math.min(1000, limit - keys.length) };
    if (cursor) listOpts.cursor = cursor;
    const listed = await env.R2_BUCKET.list(listOpts);
    for (const o of listed.objects) {
      keys.push(o.key);
      if (keys.length >= limit) break;
    }
    if (listed.truncated && listed.cursor) cursor = listed.cursor; else break;
  }

  if (keys.length === 0) {
    return jsonResponse({ kind, events: [] });
  }

  const bodies = await fetchBatch(env.R2_BUCKET, keys);
  const events = [];
  for (const text of bodies) {
    if (!text) continue;
    try {
      const ev = JSON.parse(text);
      if (ev && typeof ev === 'object' && typeof ev.id === 'string' && typeof ev.pubkey === 'string') {
        events.push(ev);
      }
    } catch { /* skip */ }
  }

  const msFor = (e) => {
    if (Array.isArray(e && e.tags)) {
      for (const t of e.tags) {
        if (Array.isArray(t) && t[0] === 'ms') {
          const v = Number(t[1]);
          if (Number.isFinite(v) && v > 0) return v;
        }
      }
    }
    return (e && e.created_at || 0) * 1000;
  };
  events.sort((a, b) => {
    const ct = (b.created_at || 0) - (a.created_at || 0);
    if (ct !== 0) return ct;
    return msFor(b) - msFor(a);
  });

  return jsonResponse({ kind, count: events.length, events });
}
