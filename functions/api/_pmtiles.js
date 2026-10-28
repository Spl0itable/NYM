import { gunzip } from './_mapbundle.js';

export const HEADER_BYTES = 16384;
export const COALESCE_GAP = 65536;
export const MAX_RUN = 8388608;
export const LEAF_CACHE_BYTES = 16777216;
export const LEAF_MAX_AGE = 2592000;
const CACHE_ORIGIN = 'https://nym-map-cache.invalid';

export class MapUnavailable extends Error {}

const planets = new Map();
const leaves = new Map();
const leafLoads = new Map();
let leafBytes = 0;

const dirBytes = (d) => d.ids.byteLength + d.runs.byteLength + d.lens.byteLength + d.offs.byteLength;

export function leafCacheStats() {
  return { count: leaves.size, bytes: leafBytes };
}

function keepLeaf(lk, dir) {
  const size = dirBytes(dir);
  if (size > LEAF_CACHE_BYTES || leaves.has(lk)) return;
  leaves.set(lk, dir);
  leafBytes += size;
  while (leafBytes > LEAF_CACHE_BYTES) {
    const [k, d] = leaves.entries().next().value;
    leaves.delete(k);
    leafBytes -= dirBytes(d);
  }
}

function rotate(n, xy, rx, ry) {
  if (ry === 0) {
    if (rx === 1) { xy[0] = n - 1 - xy[0]; xy[1] = n - 1 - xy[1]; }
    const t = xy[0]; xy[0] = xy[1]; xy[1] = t;
  }
}

export function zxyToTileId(z, x, y) {
  const acc = (4 ** z - 1) / 3, xy = [x, y];
  let d = 0;
  for (let s = 2 ** (z - 1); s >= 1; s /= 2) {
    const rx = (xy[0] & s) > 0 ? 1 : 0, ry = (xy[1] & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    rotate(s, xy, rx, ry);
  }
  return acc + d;
}

export function parseDirectory(raw) {
  let i = 0;
  const rv = () => {
    let v = 0, m = 1, x;
    do {
      if (i >= raw.length) throw new MapUnavailable('directory');
      x = raw[i++];
      v += (x & 0x7f) * m;
      m *= 128;
    } while (x & 0x80);
    return v;
  };
  const n = rv();
  const ids = new Float64Array(n), runs = new Uint32Array(n), lens = new Uint32Array(n), offs = new Float64Array(n);
  let last = 0;
  for (let k = 0; k < n; k++) { last += rv(); ids[k] = last; }
  for (let k = 0; k < n; k++) runs[k] = rv();
  for (let k = 0; k < n; k++) lens[k] = rv();
  for (let k = 0; k < n; k++) {
    const v = rv();
    offs[k] = (v === 0 && k > 0) ? offs[k - 1] + lens[k - 1] : v - 1;
  }
  return { ids, runs, lens, offs, n };
}

export function findEntry(dir, id) {
  let lo = 0, hi = dir.n - 1;
  while (lo <= hi) {
    const m = (lo + hi) >> 1;
    if (dir.ids[m] < id) lo = m + 1;
    else if (dir.ids[m] > id) hi = m - 1;
    else return { id: dir.ids[m], run: dir.runs[m], len: dir.lens[m], off: dir.offs[m] };
  }
  if (hi >= 0) {
    const run = dir.runs[hi];
    if (run === 0 || id - dir.ids[hi] < run) return { id: dir.ids[hi], run, len: dir.lens[hi], off: dir.offs[hi] };
  }
  return null;
}

async function r2Range(env, key, offset, length) {
  let obj;
  try {
    obj = await env.MAP_R2.get(key, { range: { offset, length } });
  } catch (_) {
    throw new MapUnavailable('r2');
  }
  if (!obj) throw new MapUnavailable('missing');
  return new Uint8Array(await obj.arrayBuffer());
}

async function decompress(h, bytes) {
  if (h.internalCompression === 1) return bytes;
  try { return await gunzip(bytes); } catch (_) { throw new MapUnavailable('internal'); }
}

const u64 = (dv, o) => Number(dv.getBigUint64(o, true));

export function parseHeader(b) {
  if (b.length < 127) throw new MapUnavailable('header');
  const magic = String.fromCharCode(...b.subarray(0, 7));
  if (magic !== 'PMTiles' || b[7] !== 3) throw new MapUnavailable('header');
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return {
    rootOff: u64(dv, 8), rootLen: u64(dv, 16), metaOff: u64(dv, 24), metaLen: u64(dv, 32),
    leafOff: u64(dv, 40), leafLen: u64(dv, 48), dataOff: u64(dv, 56), dataLen: u64(dv, 64),
    clustered: b[96], internalCompression: b[97], tileCompression: b[98], tileType: b[99], minZoom: b[100], maxZoom: b[101]
  };
}

export async function openPlanet(env, key, build) {
  const pk = build + '|' + key;
  const cached = planets.get(pk);
  if (cached) return cached;
  const head = await r2Range(env, key, 0, HEADER_BYTES);
  const h = parseHeader(head);
  if (h.clustered !== 1 || h.tileType !== 1 || h.tileCompression !== 2) throw new MapUnavailable('format');
  if (h.internalCompression !== 1 && h.internalCompression !== 2) throw new MapUnavailable('format');
  const rootRaw = h.rootOff + h.rootLen <= head.length ? head.subarray(h.rootOff, h.rootOff + h.rootLen) : await r2Range(env, key, h.rootOff, h.rootLen);
  const root = parseDirectory(await decompress(h, rootRaw));
  let meta;
  try {
    const mraw = h.metaOff + h.metaLen <= head.length ? head.subarray(h.metaOff, h.metaOff + h.metaLen) : await r2Range(env, key, h.metaOff, h.metaLen);
    meta = JSON.parse(new TextDecoder().decode(await decompress(h, mraw)));
  } catch (e) {
    if (e instanceof MapUnavailable) throw e;
    throw new MapUnavailable('meta');
  }
  if (!meta || typeof meta.version !== 'string' || !meta.version.startsWith('4.')) throw new MapUnavailable('schema');
  const planet = { key, build, h, root };
  planets.set(pk, planet);
  while (planets.size > 4) planets.delete(planets.keys().next().value);
  return planet;
}

async function loadLeaf(env, planet, off, len, defer) {
  const cacheKey = `${CACHE_ORIGIN}/leaf/${planet.build}/${off}`;
  let raw = null;
  try {
    const res = await caches.default.match(cacheKey);
    if (res && res.status === 200) raw = new Uint8Array(await res.arrayBuffer());
  } catch (_) {
    raw = null;
  }
  if (!raw || raw.length !== len) {
    raw = await r2Range(env, planet.key, planet.h.leafOff + off, len);
    const put = new Response(raw.slice(), { status: 200, headers: { 'Content-Type': 'application/octet-stream', 'Cache-Control': `public, max-age=${LEAF_MAX_AGE}` } });
    defer(caches.default.put(cacheKey, put).catch(() => {}));
  }
  return parseDirectory(await decompress(planet.h, raw));
}

function leafDir(env, planet, off, len, defer) {
  const lk = planet.build + '|' + planet.key + '|' + off;
  const hit = leaves.get(lk);
  if (hit) {
    leaves.delete(lk);
    leaves.set(lk, hit);
    return Promise.resolve(hit);
  }
  let load = leafLoads.get(lk);
  if (!load) {
    load = loadLeaf(env, planet, off, len, defer).then((dir) => {
      leafLoads.delete(lk);
      keepLeaf(lk, dir);
      return dir;
    }, (e) => {
      leafLoads.delete(lk);
      throw e;
    });
    leafLoads.set(lk, load);
  }
  return load;
}

export async function lookupTile(env, planet, z, x, y, defer, memo) {
  const id = zxyToTileId(z, x, y);
  let dir = planet.root;
  for (let depth = 0; depth < 4; depth++) {
    const e = findEntry(dir, id);
    if (!e) return null;
    if (e.run > 0) return e.len ? { off: planet.h.dataOff + e.off, len: e.len } : null;
    const mk = String(e.off);
    if (!memo.has(mk)) memo.set(mk, leafDir(env, planet, e.off, e.len, defer));
    dir = await memo.get(mk);
  }
  return null;
}

export function coalesce(list, gap, maxRun) {
  const s = list.filter(Boolean).slice().sort((a, b) => a.off - b.off), runs = [];
  for (const t of s) {
    const r = runs[runs.length - 1];
    const end = t.off + t.len;
    if (r && t.off <= r.end + gap && Math.max(r.end, end) - r.off <= maxRun) r.end = Math.max(r.end, end);
    else runs.push({ off: t.off, end });
  }
  return runs;
}

export async function readCellTiles(env, planet, spec, defer) {
  const memo = new Map();
  const locs = await Promise.all(spec.map(([z, x, y]) => lookupTile(env, planet, z, x, y, defer, memo)));
  const runs = coalesce(locs, COALESCE_GAP, MAX_RUN);
  const datas = await Promise.all(runs.map((r) => r2Range(env, planet.key, r.off, r.end - r.off)));
  const tiles = await Promise.all(spec.map(async ([z, x, y], i) => {
    const loc = locs[i];
    if (!loc) return { z, x, y, raw: null };
    let k = runs.length - 1;
    while (k > 0 && runs[k].off > loc.off) k--;
    const r = runs[k], d = datas[k];
    const s = loc.off - r.off;
    if (s < 0 || s + loc.len > d.length) throw new MapUnavailable('short-read');
    let raw = null;
    try { raw = await gunzip(d.subarray(s, s + loc.len)); } catch (_) { raw = null; }
    return { z, x, y, raw };
  }));
  return { tiles, reads: runs.length };
}
