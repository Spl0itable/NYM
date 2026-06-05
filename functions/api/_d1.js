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
