const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
const MERC_MAX_LAT = 85.0511287798066;

export const CELL_RE = /^[0-9b-hjkmnp-z]{5}$/;
export const BUDGET = 1572864;
export const HARD_CAP = 3145728;
export const ZMIN = 13;
export const ZMAX = 15;
export const MAX_TILES = 512;
export const LAYER_BITS = Object.freeze({ earth: 1, water: 2, landuse: 4, roads: 8, buildings: 16 });

export function ghBounds(gh) {
  const lat = [-90, 90], lng = [-180, 180];
  let even = true;
  for (const ch of gh) {
    const v = BASE32.indexOf(ch);
    for (let b = 4; b >= 0; b--) {
      const r = even ? lng : lat;
      const mid = (r[0] + r[1]) / 2;
      if ((v >> b) & 1) r[0] = mid; else r[1] = mid;
      even = !even;
    }
  }
  return { s: lat[0], n: lat[1], w: lng[0], e: lng[1] };
}

function mercY(lat) {
  const r = lat * Math.PI / 180;
  return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2;
}

export function cellTilesSpec(gh, zmin, zmax) {
  const b = ghBounds(gh), s = Math.max(b.s, -MERC_MAX_LAT), n = Math.min(b.n, MERC_MAX_LAT), out = [];
  if (s >= n) return out;
  for (let z = zmin; z <= zmax; z++) {
    const N = 2 ** z;
    const x0 = Math.floor((b.w + 180) / 360 * N), x1 = Math.ceil((b.e + 180) / 360 * N) - 1;
    const y0 = Math.max(0, Math.floor(mercY(n) * N)), y1 = Math.min(N - 1, Math.ceil(mercY(s) * N) - 1);
    for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) out.push([z, x, y]);
  }
  return out;
}

const KEEP = {
  earth: [],
  water: ['kind', 'name'],
  landuse: ['kind'],
  roads: ['kind', 'kind_detail', 'name', 'ref', 'is_bridge', 'is_tunnel', 'min_zoom'],
  buildings: []
};
const DROP_RAIL = new Set(['disused', 'miniature', 'workshop', 'station', 'abandoned', 'construction']);

function keepFeature(layer, type, props) {
  const k = props.kind;
  if (layer === 'buildings') return type === 3 && k === 'building';
  if (layer === 'earth' || layer === 'landuse') return type === 3;
  if (layer === 'water') return type !== 1 || (typeof props.name === 'string' && props.name !== '');
  if (layer === 'roads') return type === 2 && !(k === 'rail' && DROP_RAIL.has(props.kind_detail));
  return false;
}

const te = new TextEncoder();
const td = new TextDecoder();

class Reader {
  constructor(b) { this.b = b; this.i = 0; this.dv = new DataView(b.buffer, b.byteOffset, b.byteLength); }
  varint() {
    const b = this.b;
    let v = 0, m = 1, x;
    do {
      if (this.i >= b.length) throw new Error('truncated');
      x = b[this.i++];
      v += (x & 0x7f) * m;
      m *= 128;
    } while (x & 0x80);
    return v;
  }
  skip(wt) {
    if (wt === 0) this.varint();
    else if (wt === 1) this.i += 8;
    else if (wt === 2) { const n = this.varint(); this.i += n; }
    else if (wt === 5) this.i += 4;
    else throw new Error('wire type ' + wt);
    if (this.i > this.b.length) throw new Error('truncated');
  }
  len() {
    const n = this.varint(), s = this.i;
    this.i += n;
    if (this.i > this.b.length) throw new Error('truncated');
    return [s, this.i];
  }
}

function readValue(r, end) {
  let v = null;
  while (r.i < end) {
    const k = r.varint(), f = k >> 3, wt = k & 7;
    if (f === 1) { const [s, e] = r.len(); v = td.decode(r.b.subarray(s, e)); }
    else if (f === 2) { v = r.dv.getFloat32(r.i, true); r.i += 4; }
    else if (f === 3) { v = r.dv.getFloat64(r.i, true); r.i += 8; }
    else if (f === 4) {
      let q = 0n, sh = 0n, x;
      do { x = r.b[r.i++]; q |= BigInt(x & 0x7f) << sh; sh += 7n; } while (x & 0x80);
      v = Number(BigInt.asIntN(64, q));
    }
    else if (f === 5) v = r.varint();
    else if (f === 6) { const z = r.varint(); v = (z % 2) ? -(z + 1) / 2 : z / 2; }
    else if (f === 7) v = r.varint() !== 0;
    else r.skip(wt);
  }
  return v;
}

function vlen(v) {
  let n = 1;
  while (v >= 128) { v = Math.floor(v / 128); n++; }
  return n;
}

class Writer {
  constructor(n) { this.b = new Uint8Array(n || 4096); this.n = 0; }
  room(k) {
    if (this.n + k <= this.b.length) return;
    let cap = this.b.length * 2;
    while (cap < this.n + k) cap *= 2;
    const nb = new Uint8Array(cap);
    nb.set(this.b.subarray(0, this.n));
    this.b = nb;
  }
  varint(v) {
    this.room(10);
    while (v >= 128) { this.b[this.n++] = (v % 128) | 128; v = Math.floor(v / 128); }
    this.b[this.n++] = v;
  }
  bytes(u8) { this.room(u8.length); this.b.set(u8, this.n); this.n += u8.length; }
  field(f, u8) { this.varint((f << 3) | 2); this.varint(u8.length); this.bytes(u8); }
  out() { return this.b.slice(0, this.n); }
}

function encodeValue(v) {
  const w = new Writer(16);
  if (typeof v === 'string') w.field(1, te.encode(v));
  else if (typeof v === 'boolean') { w.varint(7 << 3); w.varint(v ? 1 : 0); }
  else if (Number.isInteger(v) && v >= 0) { w.varint(5 << 3); w.varint(v); }
  else if (Number.isInteger(v)) { w.varint(6 << 3); w.varint(-2 * v - 1); }
  else {
    const d = new Uint8Array(8);
    new DataView(d.buffer).setFloat64(0, v, true);
    w.varint((3 << 3) | 1);
    w.bytes(d);
  }
  return w.out();
}

function slimLayer(b, start, end) {
  const r = new Reader(b);
  r.i = start;
  let name = '', extent = 4096;
  const keys = [], values = [], feats = [];
  while (r.i < end) {
    const t = r.varint(), f = t >> 3, wt = t & 7;
    if (f === 1 && wt === 2) { const [s, e] = r.len(); name = td.decode(b.subarray(s, e)); }
    else if (f === 2 && wt === 2) {
      const [s, e] = r.len();
      const F = { type: 0, tags: null, gs: 0, ge: 0 };
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
        else if (ff === 3) F.type = fr.varint();
        else if (ff === 4 && (q & 7) === 2) { const [gs, ge] = fr.len(); F.gs = gs; F.ge = ge; }
        else fr.skip(q & 7);
      }
      feats.push(F);
    }
    else if (f === 3 && wt === 2) { const [s, e] = r.len(); keys.push(td.decode(b.subarray(s, e))); }
    else if (f === 4 && wt === 2) { const [s, e] = r.len(); const vr = new Reader(b); vr.i = s; values.push(readValue(vr, e)); }
    else if (f === 5 && wt === 0) extent = r.varint();
    else r.skip(wt);
  }
  const keep = Object.prototype.hasOwnProperty.call(KEEP, name) ? KEEP[name] : null;
  if (!keep) return null;
  const wanted = new Set(keep.concat(['kind']));
  const outKeys = [], kIdx = new Map(), outVals = [], vIdx = new Map();
  const body = new Writer(Math.max(256, end - start));
  for (const F of feats) {
    const props = {};
    const tags = F.tags || [];
    for (let j = 0; j + 1 < tags.length; j += 2) {
      const k = keys[tags[j]];
      if (wanted.has(k)) props[k] = values[tags[j + 1]];
    }
    if (!keepFeature(name, F.type, props)) continue;
    const nt = [];
    for (const k of keep) {
      const v = props[k];
      if (v === undefined || v === null || v === false) continue;
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
  lw.field(1, te.encode(name));
  lw.bytes(body.b.subarray(0, body.n));
  for (const k of outKeys) lw.field(3, te.encode(k));
  for (const v of outVals) lw.field(4, encodeValue(v));
  lw.varint(5 << 3);
  lw.varint(extent);
  const cw = new Writer(lw.n + 8);
  cw.field(3, lw.b.subarray(0, lw.n));
  return { name, bytes: cw.out() };
}

export function slimChunks(raw) {
  const r = new Reader(raw), chunks = [];
  while (r.i < raw.length) {
    const k = r.varint();
    if ((k >> 3) !== 3 || (k & 7) !== 2) { r.skip(k & 7); continue; }
    const [s, e] = r.len();
    const c = slimLayer(raw, s, e);
    if (c) chunks.push(c);
  }
  return chunks;
}

function concat(list) {
  let n = 0;
  for (const u of list) n += u.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const u of list) { out.set(u, o); o += u.length; }
  return out;
}

export function slimVariants(raw) {
  const chunks = slimChunks(raw);
  const full = concat(chunks.map((c) => c.bytes));
  const hasB = chunks.some((c) => c.name === 'buildings');
  const noB = hasB ? concat(chunks.filter((c) => c.name !== 'buildings').map((c) => c.bytes)) : full;
  return { full, noB };
}

export function levelPlan(level, z) {
  if (level >= 4 && z !== ZMIN) return null;
  if (level >= 2 && z === 14) return null;
  return { dropBuildings: (level >= 1 && z < 15) || level >= 3 };
}

async function pipe(u8, stream) {
  const w = stream.writable.getWriter();
  w.write(u8).catch(() => {});
  w.close().catch(() => {});
  return new Uint8Array(await new Response(stream.readable).arrayBuffer());
}

export const gzip = (u8) => pipe(u8, new CompressionStream('gzip'));
export const gunzip = (u8) => pipe(u8, new DecompressionStream('gzip'));

export async function buildCellBundle(cell, build, tiles) {
  const items = tiles.map((t) => {
    let v = null;
    if (t.raw && t.raw.length) {
      try { v = slimVariants(t.raw); } catch (_) { v = null; }
    }
    return { z: t.z, x: t.x, y: t.y, v, gz: new Map() };
  }).sort((a, b) => a.z - b.z || a.y - b.y || a.x - b.x);
  const gzOf = (it, drop) => {
    const bytes = drop ? it.v.noB : it.v.full;
    const key = bytes === it.v.full ? 'full' : 'noB';
    if (!it.gz.has(key)) it.gz.set(key, gzip(bytes));
    return it.gz.get(key);
  };
  for (let level = 0; level <= 4; level++) {
    const entries = [];
    let payload = 0, over = false;
    for (const it of items) {
      const plan = levelPlan(level, it.z);
      if (!plan) continue;
      if (!it.v) { entries.push({ it, flags: 1, data: new Uint8Array(0) }); continue; }
      const bytes = plan.dropBuildings ? it.v.noB : it.v.full;
      const dropBit = plan.dropBuildings ? 2 : 0;
      if (!bytes.length) { entries.push({ it, flags: 1 | dropBit, data: new Uint8Array(0) }); continue; }
      const data = await gzOf(it, plan.dropBuildings);
      payload += data.length;
      entries.push({ it, flags: dropBit, data });
      if (payload > BUDGET && level < 4) { over = true; break; }
    }
    if (over) continue;
    const total = 32 + 16 * entries.length + payload;
    if (total > HARD_CAP || entries.length > MAX_TILES) return null;
    const out = new Uint8Array(total);
    const dv = new DataView(out.buffer);
    out.set(te.encode('NMT1'), 0);
    out[4] = 1; out[5] = level; out[6] = ZMIN; out[7] = ZMAX;
    out.set(te.encode(cell), 8);
    out[13] = 1;
    dv.setUint16(14, entries.length, true);
    dv.setUint32(16, build, true);
    dv.setUint32(20, payload, true);
    dv.setUint32(24, 31, true);
    dv.setUint32(28, 0, true);
    let off = 0;
    const base = 32 + 16 * entries.length;
    entries.forEach((e, i) => {
      const o = 32 + i * 16;
      out[o] = e.it.z; out[o + 1] = e.flags;
      dv.setUint16(o + 2, e.it.x, true);
      dv.setUint16(o + 4, e.it.y, true);
      dv.setUint16(o + 6, 0, true);
      dv.setUint32(o + 8, off, true);
      dv.setUint32(o + 12, e.data.length, true);
      out.set(e.data, base + off);
      off += e.data.length;
    });
    return { level, bytes: out, count: entries.length, payload };
  }
  return null;
}
