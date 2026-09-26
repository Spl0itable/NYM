import { getEventHash, schnorr } from './_shared.js';
import { hasD1, replica } from './_d1.js';

const REFRESH_MS = 60000;
const HEX64 = /^[0-9a-f]{64}$/;
const REPORT_TARGET_JSON_MAX = 16384;

const NOPE_DDL = [
  "CREATE TABLE IF NOT EXISTS nope (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, value TEXT NOT NULL, " +
  "mode TEXT NOT NULL DEFAULT 'shadow', reason TEXT, note TEXT, created_at INTEGER NOT NULL, created_by TEXT, " +
  "expires_at INTEGER NOT NULL DEFAULT 0, report_id TEXT, UNIQUE (kind, value))",
  "CREATE INDEX IF NOT EXISTS nope_kind ON nope (kind)"
];

const REPORT_DDL = [
  "CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, reporter TEXT NOT NULL, target_pubkey TEXT, target_event TEXT, " +
  "report_type TEXT, content TEXT, created_at INTEGER NOT NULL, received_at INTEGER NOT NULL, source TEXT, " +
  "channel TEXT, target_kind INTEGER, target_json TEXT, status TEXT NOT NULL DEFAULT 'open', attempts INTEGER NOT NULL DEFAULT 0, " +
  "handled_at INTEGER NOT NULL DEFAULT 0, handled_by TEXT, verdict TEXT, notified_at INTEGER NOT NULL DEFAULT 0, " +
  "group_key TEXT, raw TEXT)",
  "CREATE INDEX IF NOT EXISTS reports_status ON reports (status, received_at)",
  "CREATE INDEX IF NOT EXISTS reports_target ON reports (target_pubkey)",
  "CREATE INDEX IF NOT EXISTS reports_reporter ON reports (reporter, received_at)"
];

function emptySet() {
  return { p: new Map(), e: new Map(), m: [], d: [], t: [], n: 0, at: 0 };
}

let cache = emptySet();
let loading = null;

async function readSet(env) {
  const db = env && env.DB_NOPE;
  const out = emptySet();
  out.at = Date.now();
  if (!hasD1(db)) return out;
  let rs;
  try {
    rs = await replica(db).prepare("SELECT kind, value, mode, expires_at FROM nope").all();
  } catch (e) {
    try {
      for (const ddl of NOPE_DDL) { try { await db.prepare(ddl).run(); } catch (_) { } }
      rs = await db.prepare("SELECT kind, value, mode, expires_at FROM nope").all();
    } catch (e2) { return out; }
  }
  const now = Date.now();
  for (const r of (rs && rs.results) || []) {
    if (r.expires_at && r.expires_at > 0 && r.expires_at < now) continue;
    const v = String(r.value || "").trim().toLowerCase();
    if (!v) continue;
    const mode = r.mode === "reject" ? "reject" : "shadow";
    if (r.kind === "pubkey" && HEX64.test(v)) out.p.set(v, mode);
    else if (r.kind === "event" && HEX64.test(v)) out.e.set(v, mode);
    else if (r.kind === "media") out.m.push(v);
    else if (r.kind === "domain") out.d.push(v.replace(/^https?:\/\//, "").replace(/\/.*$/, "").replace(/^www\./, ""));
    else if (r.kind === "term" && v.length >= 3) out.t.push(v);
  }
  out.n = out.p.size + out.e.size + out.m.length + out.d.length + out.t.length;
  return out;
}

export function filterSet(env) {
  const now = Date.now();
  if (now - cache.at < REFRESH_MS) return Promise.resolve(cache);
  if (!loading) {
    loading = readSet(env).then((s) => { cache = s; loading = null; return s; }, () => { loading = null; cache.at = now; return cache; });
  }
  return cache.at ? Promise.resolve(cache) : loading;
}

export function filterSetSync() {
  return cache;
}

function afterBrace(raw) {
  const i = raw.indexOf("{");
  return i === -1 ? -1 : i;
}

export function rawField(raw, name, max) {
  const b = afterBrace(raw);
  if (b === -1) return null;
  const key = '"' + name + '":"';
  const idx = raw.indexOf(key, b);
  if (idx === -1) return null;
  let i = idx + key.length;
  let out = "";
  const lim = Math.min(raw.length, i + (max || 4096));
  while (i < lim) {
    const c = raw.charCodeAt(i);
    if (c === 92) {
      const n = raw.charCodeAt(i + 1);
      if (n === 110) out += "\n";
      else if (n === 116) out += "\t";
      else if (n === 114) out += "\r";
      else if (n === 117) { out += String.fromCharCode(parseInt(raw.substring(i + 2, i + 6), 16) || 0); i += 6; continue; }
      else out += raw[i + 1];
      i += 2; continue;
    }
    if (c === 34) return out;
    out += raw[i];
    i++;
  }
  return out;
}

export function rawKind(raw) {
  const b = afterBrace(raw);
  if (b === -1) return -1;
  const idx = raw.indexOf('"kind":', b);
  if (idx === -1) return -1;
  let i = idx + 7;
  while (raw.charCodeAt(i) === 32) i++;
  let n = 0, saw = false;
  while (i < raw.length) {
    const c = raw.charCodeAt(i);
    if (c < 48 || c > 57) break;
    n = n * 10 + (c - 48); saw = true; i++;
  }
  return saw ? n : -1;
}

function hostHit(text, host) {
  let from = 0;
  while (true) {
    const i = text.indexOf(host, from);
    if (i === -1) return false;
    const before = i >= 3 ? text.substring(i - 3, i) : "";
    const prev = i > 0 ? text.charCodeAt(i - 1) : 0;
    const next = i + host.length < text.length ? text.charCodeAt(i + host.length) : 0;
    const boundaryBefore = before === "://" || prev === 46 || prev === 0 || prev === 32 || prev === 64;
    const boundaryAfter = next === 0 || next === 47 || next === 58 || next === 34 || next === 32 || next === 63 || next === 35 || next === 41 || next === 10;
    if (boundaryBefore && boundaryAfter) return true;
    from = i + host.length;
  }
}

export function textHit(set, text) {
  if (!text || (set.m.length === 0 && set.d.length === 0 && set.t.length === 0)) return false;
  const low = text.toLowerCase();
  for (let i = 0; i < set.m.length; i++) if (low.indexOf(set.m[i]) !== -1) return true;
  for (let i = 0; i < set.d.length; i++) if (hostHit(low, set.d[i])) return true;
  for (let i = 0; i < set.t.length; i++) if (low.indexOf(set.t[i]) !== -1) return true;
  return false;
}

export function frameHit(set, raw) {
  if (!set || !set.n) return false;
  if (set.p.size) {
    const pk = rawField(raw, "pubkey", 80);
    if (pk && set.p.has(pk.toLowerCase())) return true;
  }
  if (set.e.size) {
    const id = rawField(raw, "id", 80);
    if (id && set.e.has(id.toLowerCase())) return true;
  }
  if (set.m.length || set.d.length || set.t.length) {
    const k = rawKind(raw);
    if (k === 1059 || k === 1060 || k === 13) return false;
    if (textHit(set, rawField(raw, "content", 16384))) return true;
  }
  return false;
}

export function eventHit(set, ev) {
  if (!set || !set.n || !ev || typeof ev !== "object") return null;
  const pk = typeof ev.pubkey === "string" ? ev.pubkey.toLowerCase() : "";
  if (pk && set.p.has(pk)) return set.p.get(pk);
  const id = typeof ev.id === "string" ? ev.id.toLowerCase() : "";
  if (id && set.e.has(id)) return set.e.get(id);
  if (ev.kind !== 1059 && ev.kind !== 1060 && ev.kind !== 13 && typeof ev.content === "string" && textHit(set, ev.content)) return "shadow";
  return null;
}

export function pubkeyHit(set, pk) {
  if (!set || !set.p.size || typeof pk !== "string") return null;
  return set.p.get(pk.toLowerCase()) || null;
}

export function rowHit(set, row) {
  if (!set || !set.n || !row) return false;
  if (row.pubkey && set.p.has(String(row.pubkey).toLowerCase())) return true;
  if (row.id && set.e.has(String(row.id).toLowerCase())) return true;
  if (typeof row.json === "string" && (set.m.length || set.d.length || set.t.length)) {
    return textHit(set, rawField(row.json, "content", 16384));
  }
  return false;
}

export function listPayload(set) {
  return { p: Array.from(set.p.keys()), e: Array.from(set.e.keys()), at: set.at };
}

function tagVals(tags, name) {
  const out = [];
  for (const t of tags) {
    if (Array.isArray(t) && t[0] === name && typeof t[1] === "string") out.push(t);
  }
  return out;
}

let reportSchemaReady = false;
async function ensureReports(db) {
  if (reportSchemaReady) return;
  for (const ddl of REPORT_DDL) { try { await db.prepare(ddl).run(); } catch (_) { } }
  reportSchemaReady = true;
}

export async function noteReport(env, ev, source) {
  try {
    const db = env && env.DB_REPORT;
    if (!hasD1(db) || !ev || ev.kind !== 1984) return false;
    if (typeof ev.id !== "string" || typeof ev.sig !== "string" || typeof ev.pubkey !== "string" || !Array.isArray(ev.tags)) return false;
    if (getEventHash(ev) !== ev.id || !schnorr.verify(ev.sig, ev.id, ev.pubkey)) return false;
    const reporter = ev.pubkey.toLowerCase();
    const ps = tagVals(ev.tags, "p");
    const es = tagVals(ev.tags, "e");
    const targetPubkey = ps.length && HEX64.test(ps[0][1].toLowerCase()) ? ps[0][1].toLowerCase() : null;
    const targetEvent = es.length && HEX64.test(es[0][1].toLowerCase()) ? es[0][1].toLowerCase() : null;
    if (!targetPubkey && !targetEvent) return false;
    const type = String((es[0] && es[0][2]) || (ps[0] && ps[0][2]) || "other").slice(0, 32);
    const content = typeof ev.content === "string" ? ev.content.slice(0, 4000) : "";
    const now = Date.now();
    await ensureReports(db);
    try {
      const recent = await replica(db).prepare("SELECT COUNT(*) AS n FROM reports WHERE reporter = ? AND received_at > ?")
        .bind(reporter, now - 3600000).first();
      if (recent && Number(recent.n) >= 30) return false;
    } catch (_) { }
    let channel = null, targetKind = null, targetJson = null, resolvedPubkey = targetPubkey;
    if (targetEvent && hasD1(env.DB_CHANNELS)) {
      try {
        const row = await replica(env.DB_CHANNELS).prepare("SELECT channel, kind, pubkey, json FROM events WHERE id = ?").bind(targetEvent).first();
        if (row) {
          channel = row.channel || null;
          targetKind = typeof row.kind === "number" ? row.kind : null;
          targetJson = typeof row.json === "string" && row.json.length <= REPORT_TARGET_JSON_MAX ? row.json : null;
          if (!resolvedPubkey && typeof row.pubkey === "string") resolvedPubkey = row.pubkey.toLowerCase();
        }
      } catch (_) { }
    }
    const groupKey = targetEvent ? "e:" + targetEvent : "p:" + resolvedPubkey;
    let raw = null;
    try { raw = JSON.stringify(ev); if (raw.length > 16384) raw = null; } catch (_) { raw = null; }
    const res = await db.prepare(
      "INSERT OR IGNORE INTO reports (id, reporter, target_pubkey, target_event, report_type, content, created_at, received_at, source, " +
      "channel, target_kind, target_json, status, group_key, raw) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?)"
    ).bind(ev.id.toLowerCase(), reporter, resolvedPubkey, targetEvent, type, content, ev.created_at || 0, now, source || null,
      channel, targetKind, targetJson, groupKey, raw).run();
    const changes = res && res.meta && typeof res.meta.changes === "number" ? res.meta.changes : 1;
    return changes > 0;
  } catch (e) {
    return false;
  }
}
