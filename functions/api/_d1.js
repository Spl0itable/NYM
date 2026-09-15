// Shared D1 accessors for the Pages Functions and the NymLedger Durable Object

export function hasD1(db) {
  return !!(db && typeof db.prepare === "function");
}

// Route a read at a read replica when replication is enabled. Falls back to the
// primary transparently when the Sessions API or replication is unavailable.
export function replica(db) {
  if (db && typeof db.withSession === "function") {
    try { return db.withSession("first-unconstrained"); } catch (e) { return db; }
  }
  return db;
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

export async function shopGet(db, pk) {
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
  } catch (e) { return blank; }
}

export async function shopPut(db, pk, data) {
  data.updatedAt = Date.now();
  await db.prepare(
    "INSERT INTO shop (pubkey, owned, active, updated_at) VALUES (?, ?, ?, ?) " +
    "ON CONFLICT(pubkey) DO UPDATE SET owned = excluded.owned, active = excluded.active, updated_at = excluded.updated_at"
  ).bind(pk, JSON.stringify(data.owned || {}), JSON.stringify(data.active || blankActive()), data.updatedAt).run();
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

export async function creditsGet(db, pk) {
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
  } catch (e) { return blank; }
}

export async function creditsPut(db, pk, data) {
  data.updatedAt = Date.now();
  await db.prepare(
    "INSERT INTO credits (pubkey, balance, total_purchased, total_used, rl, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) " +
    "ON CONFLICT(pubkey) DO UPDATE SET balance = excluded.balance, total_purchased = excluded.total_purchased, " +
    "total_used = excluded.total_used, rl = excluded.rl, updated_at = excluded.updated_at"
  ).bind(
    pk, Math.floor(data.balance || 0), Math.floor(data.totalPurchased || 0), Math.floor(data.totalUsed || 0),
    JSON.stringify(Array.isArray(data.rl) ? data.rl : []), data.createdAt || Date.now(), data.updatedAt
  ).run();
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

// Created on first use rather than only by schema.sql: every other table the
// bot needs is made lazily, and a deployment that had not re-run the migration
// lost the cache silently — the missing table was caught, the read came back
// empty, and every turn went to the relays as if nothing had been cached.
// What the cache last did, so a failure is something that can be read rather
// than guessed at. Per isolate, and tiny.
var botWrapsDiag = { ok: 0, repaired: 0, err: "" };

export function botWrapsStatus() {
  return { ok: botWrapsDiag.ok, repaired: botWrapsDiag.repaired, err: botWrapsDiag.err };
}

function noteWrapErr(e) {
  botWrapsDiag.err = String((e && e.message) || e || "").slice(0, 160);
}

// Every statement on its own, every one survivable. A table from an earlier
// deploy is missing the scope columns; ALTER throws once they are there. None
// of it may be allowed to decide that the cache is off for good.
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

// Returns `ok` as well as the rows, because "the store does not have it" and
// "the store could not be asked" are different answers and only the second is
// a reason to go near a relay.
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
    // A table that is not there yet, or one without the scope columns. Both
    // are repairable, and neither is a reason to stop having a cache.
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
    // A row with no event is the memory of having looked: the wrap was not
    // cached and no relay had it. Kept so it is not asked for forever.
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
      "DELETE FROM botpm_wraps WHERE pubkey = ? AND id NOT IN (" + ph + ")"
    ).bind(pk, ...keepIds));
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

// A wrap that is in the thread, is not cached, and that no relay will hand
// over. Counted rather than dropped outright, so one bad fetch does not lose a
// turn of context that was really there.
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
