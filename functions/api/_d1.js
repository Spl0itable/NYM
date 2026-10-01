export function hasD1(db) {
  return !!(db && typeof db.prepare === "function");
}

// Reads go to a replica when available, falling back to the primary transparently.
export function replica(db) {
  if (db && typeof db.withSession === "function") {
    try { return db.withSession("first-unconstrained"); } catch (e) { return db; }
  }
  return db;
}

const EDGE_CACHE_HOST = "https://nym-spam.internal/v1/";

function edgeCache() {
  try { return typeof caches !== "undefined" && caches && caches.default ? caches.default : null; } catch (e) { return null; }
}

function edgeCacheRequest(key) {
  return new Request(EDGE_CACHE_HOST + key, { method: "GET" });
}

export async function edgeCacheGet(key) {
  const cache = edgeCache();
  if (!cache) return undefined;
  try {
    const hit = await cache.match(edgeCacheRequest(key));
    if (!hit) return undefined;
    return await hit.json();
  } catch (e) { return undefined; }
}

export async function edgeCachePut(key, value, ttlSeconds) {
  const cache = edgeCache();
  if (!cache) return;
  try {
    await cache.put(edgeCacheRequest(key), new Response(JSON.stringify(value), {
      headers: { "Content-Type": "application/json", "Cache-Control": "max-age=" + Math.max(1, Math.round(ttlSeconds || 60)) }
    }));
  } catch (e) { }
}

export async function edgeCacheDelete(key) {
  const cache = edgeCache();
  if (!cache) return;
  try { await cache.delete(edgeCacheRequest(key)); } catch (e) { }
}

function parseJson(s, fallback) {
  try { return s ? JSON.parse(s) : fallback; } catch (e) { return fallback; }
}

function blankActive() {
  return { style: null, flair: [], cosmetics: [], supporter: false };
}

export function blankShop() {
  return { owned: {}, active: blankActive(), updatedAt: 0 };
}

export async function shopGet(db, pk, strict) {
  const blank = blankShop();
  if (!hasD1(db)) return blank;
  try {
    const row = await db.prepare("SELECT owned, active, updated_at FROM shop WHERE pubkey = ?").bind(pk).first();
    if (!row) return blank;
    const owned = parseJson(row.owned, null);
    if (!owned || typeof owned !== "object") return blank;
    let active = parseJson(row.active, null);
    if (!active || typeof active !== "object") active = blankActive();
    if (!Array.isArray(active.flair)) active.flair = [];
    if (!Array.isArray(active.cosmetics)) active.cosmetics = [];
    return { owned, active, updatedAt: row.updated_at || 0 };
  } catch (e) {
    if (strict) throw e;
    return blank;
  }
}

export function shopPutStatement(db, pk, data) {
  data.updatedAt = Date.now();
  return db.prepare(
    "INSERT INTO shop (pubkey, owned, active, updated_at) VALUES (?, ?, ?, ?) " +
    "ON CONFLICT(pubkey) DO UPDATE SET owned = excluded.owned, active = excluded.active, updated_at = excluded.updated_at"
  ).bind(pk, JSON.stringify(data.owned || {}), JSON.stringify(data.active || blankActive()), data.updatedAt);
}

export async function shopPut(db, pk, data) {
  await shopPutStatement(db, pk, data).run();
}

export async function shopGetActiveMany(db, pks) {
  const out = {};
  if (!hasD1(db) || pks.length === 0) {
    pks.forEach((pk) => { out[pk] = { active: blankActive(), updatedAt: 0 }; });
    return out;
  }
  const ph = pks.map(() => "?").join(",");
  const rs = await db.prepare("SELECT pubkey, active, updated_at FROM shop WHERE pubkey IN (" + ph + ")").bind(...pks).all();
  const found = new Map();
  for (const r of (rs.results || [])) {
    let active = parseJson(r.active, null);
    if (!active || typeof active !== "object") active = blankActive();
    found.set(r.pubkey, { active, updatedAt: r.updated_at || 0 });
  }
  pks.forEach((pk) => { out[pk] = found.get(pk) || { active: blankActive(), updatedAt: 0 }; });
  return out;
}

export function blankCredits() {
  return { balance: 0, totalPurchased: 0, totalUsed: 0, rl: [], createdAt: Date.now() };
}

export async function creditsGet(db, pk, strict) {
  const blank = blankCredits();
  if (!hasD1(db)) return blank;
  try {
    const row = await db.prepare(
      "SELECT balance, total_purchased, total_used, rl, created_at FROM credits WHERE pubkey = ?"
    ).bind(pk).first();
    if (!row || typeof row.balance !== "number") return blank;
    const rl = parseJson(row.rl, []);
    return {
      balance: row.balance,
      totalPurchased: row.total_purchased || 0,
      totalUsed: row.total_used || 0,
      rl: Array.isArray(rl) ? rl : [],
      createdAt: row.created_at || Date.now()
    };
  } catch (e) {
    if (strict) throw e;
    return blank;
  }
}

export function creditsPutStatement(db, pk, data) {
  data.updatedAt = Date.now();
  return db.prepare(
    "INSERT INTO credits (pubkey, balance, total_purchased, total_used, rl, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) " +
    "ON CONFLICT(pubkey) DO UPDATE SET balance = excluded.balance, total_purchased = excluded.total_purchased, " +
    "total_used = excluded.total_used, rl = excluded.rl, updated_at = excluded.updated_at"
  ).bind(
    pk, Math.floor(data.balance || 0), Math.floor(data.totalPurchased || 0), Math.floor(data.totalUsed || 0),
    JSON.stringify(Array.isArray(data.rl) ? data.rl : []), data.createdAt || Date.now(), data.updatedAt
  );
}

export async function creditsPut(db, pk, data) {
  await creditsPutStatement(db, pk, data).run();
}

export async function invoiceGet(db, kind, state, id) {
  if (!hasD1(db)) return null;
  try {
    const row = await db.prepare("SELECT data FROM invoices WHERE kind = ? AND state = ? AND invoice_id = ?").bind(kind, state, id).first();
    return row ? parseJson(row.data, null) : null;
  } catch (e) { return null; }
}

export async function invoiceHas(db, kind, state, id) {
  if (!hasD1(db)) return false;
  try {
    const row = await db.prepare("SELECT 1 AS x FROM invoices WHERE kind = ? AND state = ? AND invoice_id = ?").bind(kind, state, id).first();
    return !!row;
  } catch (e) { return false; }
}

export async function invoicePut(db, kind, state, id, data) {
  await db.prepare("INSERT OR REPLACE INTO invoices (invoice_id, kind, state, data, created_at) VALUES (?, ?, ?, ?, ?)")
    .bind(id, kind, state, JSON.stringify(data), Date.now()).run();
}

export async function invoiceDelete(db, kind, state, id) {
  try { await db.prepare("DELETE FROM invoices WHERE kind = ? AND state = ? AND invoice_id = ?").bind(kind, state, id).run(); } catch (e) {}
}

export async function codeGet(db, code) {
  if (!hasD1(db)) return null;
  try {
    const row = await db.prepare("SELECT item_id, owner, created_at FROM codes WHERE code = ?").bind(code).first();
    return row ? { itemId: row.item_id, owner: row.owner, createdAt: row.created_at || 0 } : null;
  } catch (e) { return null; }
}

export async function codePut(db, code, itemId, owner, createdAt) {
  await db.prepare("INSERT OR REPLACE INTO codes (code, item_id, owner, created_at) VALUES (?, ?, ?, ?)")
    .bind(code, itemId, owner, createdAt || Date.now()).run();
}

export async function codeDelete(db, code) {
  await db.prepare("DELETE FROM codes WHERE code = ?").bind(code).run();
}

export async function botThreadGet(db, pk) {
  if (!hasD1(db)) return [];
  try {
    const row = await db.prepare("SELECT ids FROM botpm_thread WHERE pubkey = ?").bind(pk).first();
    const ids = row ? parseJson(row.ids, []) : [];
    return Array.isArray(ids) ? ids : [];
  } catch (e) { return []; }
}

export async function botThreadPut(db, pk, ids) {
  await db.prepare(
    "INSERT INTO botpm_thread (pubkey, ids, updated_at) VALUES (?, ?, ?) " +
    "ON CONFLICT(pubkey) DO UPDATE SET ids = excluded.ids, updated_at = excluded.updated_at"
  ).bind(pk, JSON.stringify(ids), Date.now()).run();
}

export async function botThreadDelete(db, pk) {
  try { await db.prepare("DELETE FROM botpm_thread WHERE pubkey = ?").bind(pk).run(); } catch (e) {}
}

export async function botRunsForget(db, pk, prefix) {
  if (!hasD1(db) || !prefix) return;
  var like = String(prefix).replace(/[%_\\]/g, "\\$&") + "%";
  try { await db.prepare("DELETE FROM botpm_turns WHERE pubkey = ? AND thread LIKE ? ESCAPE '\\'").bind(pk, like).run(); } catch (e) { }
  try { await db.prepare("DELETE FROM botpm_runs WHERE pubkey = ? AND thread LIKE ? ESCAPE '\\' AND state != 'running'").bind(pk, like).run(); } catch (e) { }
}

// Created lazily since deployments may not have re-run schema.sql; last status kept per isolate for diagnostics.
var botWrapsDiag = { ok: 0, repaired: 0, err: "" };

export function botWrapsStatus() {
  return { ok: botWrapsDiag.ok, repaired: botWrapsDiag.repaired, err: botWrapsDiag.err };
}

function noteWrapErr(e) {
  botWrapsDiag.err = String((e && e.message) || e || "").slice(0, 160);
}

// Each statement is independently survivable; ALTER throws once the scope columns already exist.
async function repairBotWraps(db) {
  botWrapsDiag.repaired++;
  var ddl = [
    "CREATE TABLE IF NOT EXISTS botpm_wraps (" +
    "pubkey TEXT NOT NULL, id TEXT NOT NULL, json TEXT NOT NULL, " +
    "root TEXT, msg TEXT, misses INTEGER NOT NULL DEFAULT 0, " +
    "created_at INTEGER NOT NULL DEFAULT 0, stored_at INTEGER NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (pubkey, id))",
    "ALTER TABLE botpm_wraps ADD COLUMN root TEXT",
    "ALTER TABLE botpm_wraps ADD COLUMN msg TEXT",
    "ALTER TABLE botpm_wraps ADD COLUMN misses INTEGER NOT NULL DEFAULT 0",
    "CREATE INDEX IF NOT EXISTS botpm_wraps_pubkey ON botpm_wraps (pubkey)",
    "CREATE INDEX IF NOT EXISTS botpm_wraps_root ON botpm_wraps (pubkey, root)"
  ];
  for (var i = 0; i < ddl.length; i++) {
    try { await db.prepare(ddl[i]).run(); } catch (e) { }
  }
}

// Returns `ok` separately: "not stored" and "store unreachable" differ, and only the latter justifies a relay fetch.
export async function botWrapsGet(db, pk, ids) {
  var out = {};
  if (!hasD1(db)) return { ok: false, rows: out };
  if (!ids || ids.length === 0) return { ok: true, rows: out };
  var ph = ids.map(function () { return "?"; }).join(",");
  var sql = "SELECT id, json, root, msg, misses FROM botpm_wraps WHERE pubkey = ? AND id IN (" + ph + ")";
  var rs = null;
  try {
    rs = await db.prepare(sql).bind(pk, ...ids).all();
  } catch (e) {
    // A missing table or missing scope columns is repairable and must not disable the cache.
    noteWrapErr(e);
    await repairBotWraps(db);
    try {
      rs = await db.prepare(sql).bind(pk, ...ids).all();
    } catch (e2) {
      noteWrapErr(e2);
      return { ok: false, rows: out };
    }
  }
  for (var i = 0; i < ((rs && rs.results) || []).length; i++) {
    var row = rs.results[i];
    // A row with no event records a miss (not cached, no relay had it) so it isn't re-requested forever.
    if (!row.json) {
      out[row.id] = { event: null, gone: true, misses: row.misses || 0, labelled: false };
      continue;
    }
    var evt = parseJson(row.json, null);
    if (!evt || evt.id !== row.id) continue;
    out[row.id] = {
      event: evt,
      gone: false,
      misses: 0,
      root: row.root || "",
      msg: row.msg || "",
      labelled: row.root !== null || row.msg !== null
    };
  }
  botWrapsDiag.ok++;
  return { ok: true, rows: out };
}

export async function botWrapsPut(db, pk, entries, keepIds) {
  if (!hasD1(db)) return;
  var list = entries || [];
  var now = Date.now();
  var stmts = [];
  for (var i = 0; i < list.length; i++) {
    var entry = list[i];
    var evt = entry && entry.event;
    if (!evt || typeof evt.id !== "string") continue;
    var json = JSON.stringify(evt);
    if (json.length > 262144) continue;
    stmts.push(db.prepare(
      "INSERT INTO botpm_wraps (pubkey, id, json, root, msg, misses, created_at, stored_at) " +
      "VALUES (?, ?, ?, ?, ?, 0, ?, ?) " +
      "ON CONFLICT(pubkey, id) DO UPDATE SET stored_at = excluded.stored_at, " +
      "json = excluded.json, root = excluded.root, msg = excluded.msg, misses = 0"
    ).bind(pk, evt.id, json, entry.root || "", entry.msg || "",
      evt.created_at || 0, now));
  }
  if (Array.isArray(keepIds) && keepIds.length) {
    var ph = keepIds.map(function () { return "?"; }).join(",");
    stmts.push(db.prepare(
      "CREATE TABLE IF NOT EXISTS botpm_turns (pubkey TEXT NOT NULL, asked TEXT NOT NULL, thread TEXT NOT NULL DEFAULT '', " +
      "ids TEXT NOT NULL DEFAULT '[]', at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (pubkey, asked))"
    ));
    stmts.push(db.prepare(
      "DELETE FROM botpm_wraps WHERE pubkey = ? AND id NOT IN (" + ph + ") " +
      "AND id NOT IN (SELECT j.value FROM (SELECT ids FROM botpm_turns WHERE pubkey = ? ORDER BY at DESC LIMIT 200) t, json_each(t.ids) j)"
    ).bind(pk, ...keepIds, String(pk).toLowerCase()));
  }
  if (!stmts.length) return;
  try {
    await db.batch(stmts);
    botWrapsDiag.ok++;
    return;
  } catch (e) {
    noteWrapErr(e);
  }
  await repairBotWraps(db);
  try {
    await db.batch(stmts);
    botWrapsDiag.ok++;
  } catch (e2) {
    noteWrapErr(e2);
  }
}

// Counted rather than dropped outright, so one bad fetch doesn't lose real thread context.
export async function botWrapsMiss(db, pk, ids) {
  if (!hasD1(db) || !ids || !ids.length) return;
  var now = Date.now();
  var stmts = [];
  for (var i = 0; i < ids.length; i++) {
    stmts.push(db.prepare(
      "INSERT INTO botpm_wraps (pubkey, id, json, root, msg, misses, created_at, stored_at) " +
      "VALUES (?, ?, '', NULL, NULL, 1, 0, ?) " +
      "ON CONFLICT(pubkey, id) DO UPDATE SET misses = botpm_wraps.misses + 1, " +
      "stored_at = excluded.stored_at"
    ).bind(pk, ids[i], now));
  }
  try {
    await db.batch(stmts);
    return;
  } catch (e) { noteWrapErr(e); }
  await repairBotWraps(db);
  try { await db.batch(stmts); } catch (e2) { noteWrapErr(e2); }
}

export async function botWrapsDelete(db, pk) {
  try { await db.prepare("DELETE FROM botpm_wraps WHERE pubkey = ?").bind(pk).run(); } catch (e) {}
}

export async function botWrapsSweep(db, olderThanMs, limit) {
  if (!hasD1(db)) return 0;
  try {
    var res = await db.prepare(
      "DELETE FROM botpm_wraps WHERE rowid IN (" +
      "SELECT rowid FROM botpm_wraps WHERE stored_at < ? ORDER BY stored_at LIMIT ?)"
    ).bind(olderThanMs, limit || 500).run();
    return (res && res.meta && res.meta.changes) || 0;
  } catch (e) { return 0; }
}
