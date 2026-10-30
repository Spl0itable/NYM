import { Reader, Writer, readValue, encodeValue, vlen, gzip } from './_mapbundle.js';

export const LZ = Object.freeze({ minZ: 5, maxZ: 15, budget: 262144, hardCap: 524288, buildingsMinZ: 14, landuseAllMinZ: 12, areaMaxZ: 11, minArea: 16384, roadDetailMinZ: 12 });
export const GREEN = new Set(['park', 'forest', 'wood', 'grass', 'garden', 'cemetery', 'golf_course', 'nature_reserve', 'playground', 'pitch', 'recreation_ground', 'village_green', 'meadow', 'scrub', 'allotments']);
export const ROAD_KINDS = new Set(['highway', 'major_road', 'minor_road', 'path', 'rail']);
const DROP_RAIL = new Set(['disused', 'miniature', 'workshop', 'station', 'abandoned', 'construction']);
const ROAD_PROPS = ['kind', 'kind_detail', 'name', 'ref', 'is_bridge', 'is_tunnel', 'min_zoom'];
const ROAD_PROPS_LO = ['kind', 'name', 'ref', 'min_zoom'];
const READ_PROPS = new Set(ROAD_PROPS);

export const TILE_RE = /^\/api\/map\/v2\/([1-9][0-9]{7})\/(0|[1-9][0-9]?)\/(0|[1-9][0-9]{0,4})\/(0|[1-9][0-9]{0,4})$/;
export const META_PATH = '/api/map/v2/meta';
export const TILE_CACHE = 'public, max-age=31536000, immutable, no-transform';
export const META_CACHE = 'public, max-age=3600';
export const TOO_LARGE_CACHE = 'public, max-age=86400';

export function parseTilePath(p) {
  if (p === META_PATH) return { meta: true };
  const m = TILE_RE.exec(p);
  if (!m) return null;
  const build = +m[1], z = +m[2], x = +m[3], y = +m[4];
  if (z < LZ.minZ || z > LZ.maxZ || x >= 2 ** z || y >= 2 ** z) return null;
  return { build, z, x, y };
}

export function chooseLevel(sizes) {
  for (let l = 0; l < sizes.length; l++) if (sizes[l] <= LZ.budget) return l;
  return sizes[sizes.length - 1] <= LZ.hardCap ? sizes.length - 1 : 413;
}

export const metaBody = (build) => JSON.stringify({ v: 2, build, minzoom: LZ.minZ, maxzoom: LZ.maxZ });
export const tileEtag = (build, z, x, y, level) => `"t2-${build}-${z}-${x}-${y}-${level}"`;
export const edgeKey = (build, z, x, y) => `https://nym-map-cache.invalid/v2/${build}/${z}/${x}/${y}`;

export function propsLz(layer, z) {
  if (layer === 'earth' || layer === 'buildings') return [];
  if (layer === 'water') return ['kind', 'name'];
  if (layer === 'landuse') return ['kind'];
  if (layer === 'roads') return z >= LZ.roadDetailMinZ ? ROAD_PROPS : ROAD_PROPS_LO;
  return null;
}

export function polyArea(b, start = 0, end = b.length) {
  const r = new Reader(b);
  r.i = start;
  let a = 0, x = 0, y = 0, fx = 0, fy = 0, px = 0, py = 0, open = false;
  while (r.i < end) {
    const c = r.varint(), id = c & 7, n = Math.floor(c / 8);
    if (id === 7) {
      if (open) { a += px * fy - fx * py; px = fx; py = fy; }
      continue;
    }
    for (let k = 0; k < n; k++) {
      const dx = r.varint(), dy = r.varint();
      x += (dx >>> 1) ^ -(dx & 1);
      y += (dy >>> 1) ^ -(dy & 1);
      if (id === 1) { fx = x; fy = y; open = true; }
      else if (open) a += px * y - x * py;
      px = x; py = y;
    }
  }
  return Math.abs(a) / 2;
}

function areaOf(b, F) {
  if (F.area === undefined) F.area = polyArea(b, F.gs, F.ge);
  return F.area;
}

function keepLz(b, layer, F, z, level) {
  const k = F.props.kind;
  if (layer === 'earth') return F.type === 3;
  if (layer === 'buildings') return level === 0 && z >= LZ.buildingsMinZ && F.type === 3 && k === 'building';
  if (layer === 'water') {
    if (F.type === 1) return typeof F.props.name === 'string' && F.props.name !== '';
    if (F.type === 3 && z <= LZ.areaMaxZ) return areaOf(b, F) >= LZ.minArea;
    return F.type === 2 || F.type === 3;
  }
  if (layer === 'landuse') {
    if (F.type !== 3) return false;
    if ((z < LZ.landuseAllMinZ || level >= 2) && !GREEN.has(k)) return false;
    return z > LZ.areaMaxZ || areaOf(b, F) >= LZ.minArea;
  }
  if (layer === 'roads') {
    if (F.type !== 2 || !ROAD_KINDS.has(k)) return false;
    if (k === 'rail' && DROP_RAIL.has(F.props.kind_detail)) return false;
    if (level >= 2 && k === 'path') return false;
    return true;
  }
  return false;
}

function parseLayer(b, start, end) {
  const r = new Reader(b);
  r.i = start;
  let name = '', extent = 4096;
  const keys = [], values = [], feats = [];
  while (r.i < end) {
    const t = r.varint(), f = t >> 3, wt = t & 7;
    if (f === 1 && wt === 2) { const [s, e] = r.len(); name = new TextDecoder().decode(b.subarray(s, e)); }
    else if (f === 2 && wt === 2) {
      const [s, e] = r.len();
      const F = { type: 0, tags: null, gs: 0, ge: 0, props: null };
      const fr = new Reader(b);
      fr.i = s;
      while (fr.i < e) {
        const q = fr.varint(), ff = q >> 3;
        if (ff === 2 && (q & 7) === 2) {
          const [ts, tend] = fr.len(), tags = [], tr = new Reader(b);
          tr.i = ts;
          while (tr.i < tend) tags.push(tr.varint());
          F.tags = tags;
        }
        else if (ff === 3 && (q & 7) === 0) F.type = fr.varint();
        else if (ff === 4 && (q & 7) === 2) { const [gs, ge] = fr.len(); F.gs = gs; F.ge = ge; }
        else fr.skip(q & 7);
      }
      feats.push(F);
    }
    else if (f === 3 && wt === 2) { const [s, e] = r.len(); keys.push(new TextDecoder().decode(b.subarray(s, e))); }
    else if (f === 4 && wt === 2) { const [s, e] = r.len(); const vr = new Reader(b); vr.i = s; values.push(readValue(vr, e)); }
    else if (f === 5 && wt === 0) extent = r.varint();
    else r.skip(wt);
  }
  for (const F of feats) {
    const props = {};
    const tags = F.tags || [];
    for (let j = 0; j + 1 < tags.length; j += 2) {
      const k = keys[tags[j]];
      if (READ_PROPS.has(k)) props[k] = values[tags[j + 1]];
    }
    F.props = props;
  }
  return { name, extent, feats };
}

export function parseTileLz(raw) {
  const r = new Reader(raw), layers = [];
  while (r.i < raw.length) {
    const k = r.varint();
    if ((k >> 3) !== 3 || (k & 7) !== 2) { r.skip(k & 7); continue; }
    const [s, e] = r.len();
    layers.push(parseLayer(raw, s, e));
  }
  return layers;
}

const te = new TextEncoder();

function encodeLayer(b, L, z, level) {
  const keep = propsLz(L.name, z);
  if (!keep) return null;
  const outKeys = [], kIdx = new Map(), outVals = [], vIdx = new Map();
  const body = new Writer(4096);
  for (const F of L.feats) {
    if (!keepLz(b, L.name, F, z, level)) continue;
    const nt = [];
    for (const k of keep) {
      const v = F.props[k];
      if (v === undefined || v === null || v === false || v === '') continue;
      if (!kIdx.has(k)) { kIdx.set(k, outKeys.length); outKeys.push(k); }
      const vk = typeof v + ':' + v;
      if (!vIdx.has(vk)) { vIdx.set(vk, outVals.length); outVals.push(v); }
      nt.push(kIdx.get(k), vIdx.get(vk));
    }
    let tagsLen = 0;
    for (const x of nt) tagsLen += vlen(x);
    const glen = F.ge - F.gs;
    const flen = (nt.length ? 1 + vlen(tagsLen) + tagsLen : 0) + 1 + vlen(F.type) + 1 + vlen(glen) + glen;
    body.varint((2 << 3) | 2);
    body.varint(flen);
    if (nt.length) { body.varint((2 << 3) | 2); body.varint(tagsLen); for (const x of nt) body.varint(x); }
    body.varint(3 << 3);
    body.varint(F.type);
    body.varint((4 << 3) | 2);
    body.varint(glen);
    body.bytes(b.subarray(F.gs, F.ge));
  }
  if (!body.n) return null;
  const lw = new Writer(body.n + 256);
  lw.varint(15 << 3);
  lw.varint(2);
  lw.field(1, te.encode(L.name));
  lw.bytes(body.b.subarray(0, body.n));
  for (const k of outKeys) lw.field(3, te.encode(k));
  for (const v of outVals) lw.field(4, encodeValue(v));
  lw.varint(5 << 3);
  lw.varint(L.extent);
  const cw = new Writer(lw.n + 8);
  cw.field(3, lw.b.subarray(0, lw.n));
  return cw.out();
}

function encodeTile(raw, layers, z, level) {
  const chunks = new Map();
  for (const L of layers) {
    const c = encodeLayer(raw, L, z, level);
    if (c) chunks.set(L.name, c);
  }
  let n = 0;
  for (const c of chunks.values()) n += c.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const c of chunks.values()) { out.set(c, o); o += c.length; }
  return out;
}

export function slimLz(raw, z, level = 0) {
  return encodeTile(raw, parseTileLz(raw), z, level);
}

export async function buildTileLz(raw, z) {
  const empty = { level: 0, bytes: new Uint8Array(0) };
  if (!raw || !raw.length) return empty;
  let layers;
  try { layers = parseTileLz(raw); } catch (_) { return empty; }
  let last = null;
  for (let level = 0; level <= 2; level++) {
    const slim = encodeTile(raw, layers, z, level);
    if (!slim.length) return { level, bytes: new Uint8Array(0) };
    const gz = await gzip(slim);
    if (gz.length <= LZ.budget) return { level, bytes: gz };
    last = gz;
  }
  return last.length <= LZ.hardCap ? { level: 2, bytes: last } : null;
}

export function etagMatches(header, etag) {
  if (!header) return false;
  return header.split(',').some((t) => {
    const v = t.trim().replace(/^W\//, '');
    return v === '*' || v === etag;
  });
}
