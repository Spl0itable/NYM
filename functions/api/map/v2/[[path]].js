import { isNymchatClient } from '../../_client.js';
import { META_CACHE, TILE_CACHE, TOO_LARGE_CACHE, parseTilePath, metaBody, tileEtag, edgeKey, buildTileLz, etagMatches } from '../../_maptile.js';
import { MapUnavailable, openPlanet, readCellTiles } from '../../_pmtiles.js';

const READ_TIMEOUT_MS = 20000;
const COMMON = {
  'X-Content-Type-Options': 'nosniff',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Referrer-Policy': 'no-referrer'
};

function refuse(status, body, method, extra) {
  const headers = Object.assign({ 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }, COMMON, extra || {});
  return new Response(method === 'HEAD' ? null : JSON.stringify(body), { status, headers });
}

const unavailable = (method) => refuse(503, { error: 'map-unavailable' }, method, { 'Retry-After': '600' });

function serve(stored, request) {
  const headers = new Headers();
  for (const name of ['Content-Type', 'Cache-Control', 'ETag', 'X-Content-Type-Options', 'Cross-Origin-Resource-Policy', 'Referrer-Policy']) {
    const v = stored.headers.get(name);
    if (v) headers.set(name, v);
  }
  if (stored.status !== 200) return new Response(null, { status: stored.status, headers });
  const etag = headers.get('ETag');
  if (etag && etagMatches(request.headers.get('If-None-Match'), etag)) {
    headers.delete('Content-Type');
    return new Response(null, { status: 304, headers });
  }
  return new Response(request.method === 'HEAD' ? null : stored.body, { status: 200, headers });
}

async function cacheMatch(key) {
  try {
    return (await caches.default.match(key)) || null;
  } catch (_) {
    return null;
  }
}

function withDeadline(work) {
  let timer;
  const deadline = new Promise((_, reject) => { timer = setTimeout(() => reject(new MapUnavailable('timeout')), READ_TIMEOUT_MS); });
  return Promise.race([work, deadline]).finally(() => clearTimeout(timer));
}

export async function onRequest(context) {
  const { request, env } = context;
  const method = request.method;
  if (method !== 'GET' && method !== 'HEAD') return refuse(405, { error: 'method-not-allowed' }, method, { Allow: 'GET, HEAD' });
  if (!isNymchatClient(request, env) && request.headers.get('Sec-Fetch-Site') !== 'same-origin') return refuse(403, { error: 'forbidden' }, method);
  let pathname = '';
  try { pathname = new URL(request.url).pathname; } catch (_) { pathname = ''; }
  const want = parseTilePath(pathname);
  if (!want) return refuse(400, { error: 'bad-path' }, method);
  if (request.url.includes('?')) return refuse(400, { error: 'query-not-allowed' }, method);

  const e = env || {};
  const key = typeof e.MAP_PLANET_KEY === 'string' ? e.MAP_PLANET_KEY : '';
  const build = typeof e.MAP_BUILD === 'string' ? e.MAP_BUILD : '';
  if (!e.MAP_R2 || typeof e.MAP_R2.get !== 'function' || !key || !/^\d{8}$/.test(build)) return unavailable(method);

  let planet;
  try {
    planet = await withDeadline(openPlanet(e, key, build));
  } catch (_) {
    return unavailable(method);
  }

  if (want.meta) {
    return new Response(method === 'HEAD' ? null : metaBody(Number(build)), {
      status: 200,
      headers: Object.assign({ 'Content-Type': 'application/json', 'Cache-Control': META_CACHE }, COMMON)
    });
  }
  if (want.build !== Number(build)) return refuse(404, { error: 'build', build: Number(build) }, method);

  const { z, x, y } = want;
  const ck = edgeKey(build, z, x, y);
  const hit = await cacheMatch(ck);
  if (hit && (hit.status === 200 || hit.status === 413)) return serve(hit, request);

  const pending = [];
  const defer = (p) => {
    if (typeof context.waitUntil === 'function') context.waitUntil(p);
    else pending.push(p);
  };
  let raw;
  try {
    raw = await withDeadline(readCellTiles(e, planet, [[z, x, y]], defer).then((r) => r.tiles[0].raw));
  } catch (_) {
    return unavailable(method);
  }

  let stored;
  try {
    const out = await buildTileLz(raw, z);
    stored = out
      ? new Response(out.bytes, { status: 200, headers: Object.assign({ 'Content-Type': 'application/x-nymchat-tile', 'Cache-Control': TILE_CACHE, ETag: tileEtag(build, z, x, y, out.level) }, COMMON) })
      : new Response(null, { status: 413, headers: Object.assign({ 'Cache-Control': TOO_LARGE_CACHE }, COMMON) });
  } catch (_) {
    return unavailable(method);
  }
  defer(caches.default.put(ck, stored.clone()).catch(() => {}));
  return serve(stored, request);
}
