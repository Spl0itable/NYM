import { isNymchatClient } from '../../_client.js';
import { CELL_RE, ZMIN, ZMAX, cellTilesSpec, buildCellBundle } from '../../_mapbundle.js';
import { MapUnavailable, openPlanet, readCellTiles } from '../../_pmtiles.js';

const CACHE_ORIGIN = 'https://nym-map-cache.invalid';
const READ_TIMEOUT_MS = 20000;
const BUNDLE_CACHE = 'public, max-age=604800, no-transform';
const TOO_LARGE_CACHE = 'public, max-age=86400';

const COMMON = {
  'X-Content-Type-Options': 'nosniff',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Referrer-Policy': 'no-referrer'
};

function refuse(status, error, method, extra) {
  const headers = Object.assign({ 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }, COMMON, extra || {});
  return new Response(method === 'HEAD' ? null : JSON.stringify({ error }), { status, headers });
}

const unavailable = (method) => refuse(503, 'map-unavailable', method, { 'Retry-After': '600' });

function etagMatches(header, etag) {
  if (!header) return false;
  return header.split(',').some((t) => {
    const v = t.trim().replace(/^W\//, '');
    return v === '*' || v === etag;
  });
}

function bundleResponse(bytes, etag) {
  return new Response(bytes, {
    status: 200,
    headers: Object.assign({ 'Content-Type': 'application/x-nymchat-map', 'Cache-Control': BUNDLE_CACHE, ETag: etag }, COMMON)
  });
}

function tooLargeResponse() {
  return new Response(null, { status: 413, headers: Object.assign({ 'Cache-Control': TOO_LARGE_CACHE }, COMMON) });
}

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
  const { request, env, params } = context;
  const method = request.method;
  if (method !== 'GET' && method !== 'HEAD') return refuse(405, 'method-not-allowed', method, { Allow: 'GET, HEAD' });
  if (!isNymchatClient(request, env) && request.headers.get('Sec-Fetch-Site') !== 'same-origin') return refuse(403, 'forbidden', method);
  const cell = params && typeof params.cell === 'string' ? params.cell : '';
  if (!CELL_RE.test(cell)) return refuse(400, 'bad-cell', method);
  if (request.url.includes('?')) return refuse(400, 'query-not-allowed', method);

  const e = env || {};
  const key = typeof e.MAP_PLANET_KEY === 'string' ? e.MAP_PLANET_KEY : '';
  const build = typeof e.MAP_BUILD === 'string' ? e.MAP_BUILD : '';
  if (!e.MAP_R2 || typeof e.MAP_R2.get !== 'function' || !key || !/^\d{8}$/.test(build)) return unavailable(method);

  const cacheKey = `${CACHE_ORIGIN}/v1/${build}/${cell}`;
  const hit = await cacheMatch(cacheKey);
  if (hit && (hit.status === 200 || hit.status === 413)) return serve(hit, request);

  const pending = [];
  const defer = (p) => {
    if (typeof context.waitUntil === 'function') context.waitUntil(p);
    else pending.push(p);
  };
  let tiles;
  try {
    tiles = await withDeadline((async () => {
      const planet = await openPlanet(e, key, build);
      const spec = cellTilesSpec(cell, ZMIN, ZMAX);
      if (!spec.length) return [];
      return (await readCellTiles(e, planet, spec, defer)).tiles;
    })());
  } catch (_) {
    return unavailable(method);
  }

  let stored;
  try {
    const bundle = await buildCellBundle(cell, Number(build), tiles);
    stored = bundle ? bundleResponse(bundle.bytes, `"nmt1-${build}-${cell}-${bundle.level}"`) : tooLargeResponse();
  } catch (_) {
    return unavailable(method);
  }
  defer(caches.default.put(cacheKey, stored.clone()).catch(() => {}));
  return serve(stored, request);
}
