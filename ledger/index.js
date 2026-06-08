// nym-ledger Worker - standalone host for the NymLedger Durable Object

var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// functions/api/_d1.js
function hasD1(db) {
  return !!(db && typeof db.prepare === "function");
}
__name(hasD1, "hasD1");
function parseJson(s, fallback) {
  try {
    return s ? JSON.parse(s) : fallback;
  } catch (e) {
    return fallback;
  }
}
__name(parseJson, "parseJson");
function blankActive() {
  return { style: null, flair: [], cosmetics: [], supporter: false };
}
__name(blankActive, "blankActive");
function blankShop() {
  return { owned: {}, active: blankActive(), updatedAt: 0 };
}
__name(blankShop, "blankShop");
async function shopGet(db, pk) {
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
    return blank;
  }
}
__name(shopGet, "shopGet");
async function shopPut(db, pk, data) {
  data.updatedAt = Date.now();
  await db.prepare(
    "INSERT INTO shop (pubkey, owned, active, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(pubkey) DO UPDATE SET owned = excluded.owned, active = excluded.active, updated_at = excluded.updated_at"
  ).bind(pk, JSON.stringify(data.owned || {}), JSON.stringify(data.active || blankActive()), data.updatedAt).run();
}
__name(shopPut, "shopPut");
function blankCredits() {
  return { balance: 0, totalPurchased: 0, totalUsed: 0, rl: [], createdAt: Date.now() };
}
__name(blankCredits, "blankCredits");
async function creditsGet(db, pk) {
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
    return blank;
  }
}
__name(creditsGet, "creditsGet");
async function creditsPut(db, pk, data) {
  data.updatedAt = Date.now();
  await db.prepare(
    "INSERT INTO credits (pubkey, balance, total_purchased, total_used, rl, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(pubkey) DO UPDATE SET balance = excluded.balance, total_purchased = excluded.total_purchased, total_used = excluded.total_used, rl = excluded.rl, updated_at = excluded.updated_at"
  ).bind(
    pk,
    Math.floor(data.balance || 0),
    Math.floor(data.totalPurchased || 0),
    Math.floor(data.totalUsed || 0),
    JSON.stringify(Array.isArray(data.rl) ? data.rl : []),
    data.createdAt || Date.now(),
    data.updatedAt
  ).run();
}
__name(creditsPut, "creditsPut");
async function invoiceGet(db, kind, state, id) {
  if (!hasD1(db)) return null;
  try {
    const row = await db.prepare("SELECT data FROM invoices WHERE kind = ? AND state = ? AND invoice_id = ?").bind(kind, state, id).first();
    return row ? parseJson(row.data, null) : null;
  } catch (e) {
    return null;
  }
}
__name(invoiceGet, "invoiceGet");
async function invoicePut(db, kind, state, id, data) {
  await db.prepare("INSERT OR REPLACE INTO invoices (invoice_id, kind, state, data, created_at) VALUES (?, ?, ?, ?, ?)").bind(id, kind, state, JSON.stringify(data), Date.now()).run();
}
__name(invoicePut, "invoicePut");
async function invoiceDelete(db, kind, state, id) {
  try {
    await db.prepare("DELETE FROM invoices WHERE kind = ? AND state = ? AND invoice_id = ?").bind(kind, state, id).run();
  } catch (e) {
  }
}
__name(invoiceDelete, "invoiceDelete");
async function codePut(db, code, itemId, owner, createdAt) {
  await db.prepare("INSERT OR REPLACE INTO codes (code, item_id, owner, created_at) VALUES (?, ?, ?, ?)").bind(code, itemId, owner, createdAt || Date.now()).run();
}
__name(codePut, "codePut");

// functions/api/_ledger.js
var NymLedger = class {
  static {
    __name(this, "NymLedger");
  }
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.sql = state.storage.sql;
    this._chain = Promise.resolve();
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS replay (id TEXT PRIMARY KEY, exp INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS claims (id TEXT PRIMARY KEY, kind TEXT NOT NULL, at INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS edition_minted (item TEXT PRIMARY KEY, n INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS edition_resv (invoice TEXT PRIMARY KEY, item TEXT NOT NULL, user TEXT, exp INTEGER NOT NULL);"
    );
  }
  // Serialize op handlers so an R2 read-modify-write can't interleave with
  // another op on the same instance.
  _exclusive(fn) {
    const run = this._chain.then(fn, fn);
    this._chain = run.then(() => {
    }, () => {
    });
    return run;
  }
  async fetch(request) {
    let body;
    try {
      body = await request.json();
    } catch {
      return this._json({ error: "bad request" }, 400);
    }
    const op = body && body.op;
    try {
      const result = await this._exclusive(() => this._dispatch(op, body));
      return this._json(result);
    } catch (e) {
      return this._json({ error: "ledger error" }, 500);
    }
  }
  async _dispatch(op, a) {
    switch (op) {
      case "replay":
        return this._replay(a.id, a.ttl);
      case "transfer-credits":
        return this._transferCredits(a.from, a.to);
      case "consume-credits":
        return this._consumeCredits(a.pubkey, a.cost, a.ts);
      case "claim-credits":
        return this._claimCredits(a);
      case "shop-claim":
        return this._shopClaim(a);
      case "shop-transfer":
        return this._shopTransfer(a);
      case "shop-redeem":
        return this._shopRedeem(a);
      case "shop-reserve":
        return this._shopReserve(a);
      case "shop-supply":
        return this._shopSupply(a);
      default:
        return { error: "unknown op" };
    }
  }
  _json(obj, status = 200) {
    return new Response(JSON.stringify(obj), {
      status,
      headers: { "Content-Type": "application/json" }
    });
  }
  // Single-use auth replay store. Returns { fresh: true } the first time an
  // id is seen within its TTL, { fresh: false } on any reuse.
  _replay(id, ttl) {
    if (typeof id !== "string" || !/^[0-9a-f]{64}$/i.test(id)) return { fresh: false };
    const now = Math.floor(Date.now() / 1e3);
    this.sql.exec("DELETE FROM replay WHERE exp < ?;", now);
    const existing = this.sql.exec("SELECT id FROM replay WHERE id = ? LIMIT 1;", id).toArray();
    if (existing.length) return { fresh: false };
    this.sql.exec("INSERT INTO replay (id, exp) VALUES (?, ?);", id, now + (Number(ttl) || 130));
    return { fresh: true };
  }
  // Atomically record a claim id. Returns true if newly inserted, false if it
  // already existed (i.e. this invoice was already claimed).
  _claimOnce(id, kind) {
    const existing = this.sql.exec("SELECT id FROM claims WHERE id = ? LIMIT 1;", id).toArray();
    if (existing.length) return false;
    this.sql.exec("INSERT INTO claims (id, kind, at) VALUES (?, ?, ?);", id, kind, Date.now());
    return true;
  }
  // Limited-edition supply (numbered drops)
  _editionMinted(item) {
    const r = this.sql.exec("SELECT n FROM edition_minted WHERE item = ? LIMIT 1;", item).toArray();
    return r.length ? r[0].n || 0 : 0;
  }
  _editionLiveReservations(item, now) {
    const r = this.sql.exec("SELECT COUNT(*) AS c FROM edition_resv WHERE item = ? AND exp > ?;", item, now).toArray();
    return r.length ? r[0].c || 0 : 0;
  }
  // Hold a supply slot for a pending invoice. Counts existing mints + live
  // reservations against maxSupply so a drop can never oversell.
  _shopReserve(a) {
    const item = String(a.itemId || a.item || "");
    const max = Math.floor(Number(a.max) || 0);
    const invoice = String(a.invoiceId || a.invoice || "");
    const user = String(a.user || "").toLowerCase();
    const ttl = Math.floor(Number(a.ttl) || 1800);
    if (!item || max <= 0 || !/^[0-9a-f]{64}$/i.test(invoice)) return { error: "Invalid reservation." };
    const now = Date.now();
    this.sql.exec("DELETE FROM edition_resv WHERE exp <= ?;", now);
    const existing = this.sql.exec("SELECT item FROM edition_resv WHERE invoice = ? LIMIT 1;", invoice).toArray();
    if (existing.length) return { ok: true, reused: true };
    if (/^[0-9a-f]{64}$/.test(user)) {
      this.sql.exec("DELETE FROM edition_resv WHERE item = ? AND user = ?;", item, user);
    }
    const minted = this._editionMinted(item);
    const live = this._editionLiveReservations(item, now);
    if (minted + live >= max) return { soldOut: true, remaining: 0 };
    this.sql.exec("INSERT INTO edition_resv (invoice, item, user, exp) VALUES (?, ?, ?, ?);", invoice, item, user || null, now + ttl * 1e3);
    return { ok: true, remaining: Math.max(0, max - minted - live - 1) };
  }
  // Read minted + live reservation counts for display ("X left").
  _shopSupply(a) {
    const ids = Array.isArray(a.itemIds) ? a.itemIds.slice(0, 50) : [];
    const now = Date.now();
    this.sql.exec("DELETE FROM edition_resv WHERE exp <= ?;", now);
    const counts = {};
    ids.forEach((raw) => {
      const item = String(raw);
      counts[item] = { minted: this._editionMinted(item), reserved: this._editionLiveReservations(item, now) };
    });
    return { counts };
  }
  // Consume a paid invoice's reservation and assign the next edition number.
  // Returns the number, or null if no slot remains (degrades to unnumbered so a
  // paid claim never fails — only possible if the reservation expired first).
  _allocateEdition(item, invoice, max) {
    this.sql.exec("DELETE FROM edition_resv WHERE invoice = ?;", invoice);
    const minted = this._editionMinted(item);
    if (max > 0 && minted >= max) return null;
    const n = minted + 1;
    this.sql.exec(
      "INSERT INTO edition_minted (item, n) VALUES (?, ?) ON CONFLICT(item) DO UPDATE SET n = ?;",
      item,
      n,
      n
    );
    return n;
  }
  // D1 credit/shop helpers
  async _getCredits(pk) {
    return creditsGet(this.env.DB_CREDITS, pk);
  }
  async _putCredits(pk, data) {
    await creditsPut(this.env.DB_CREDITS, pk, data);
  }
  async _getShop(pk) {
    return shopGet(this.env.DB_SHOP, pk);
  }
  async _putShop(pk, data) {
    await shopPut(this.env.DB_SHOP, pk, data);
  }
  _pruneActive(rec) {
    const a = rec.active || {};
    if (a.style && !rec.owned[a.style]) a.style = null;
    if (Array.isArray(a.flair)) a.flair = a.flair.filter((id) => rec.owned[id]);
    if (Array.isArray(a.cosmetics)) a.cosmetics = a.cosmetics.filter((id) => rec.owned[id]);
    if (a.supporter && !rec.owned["supporter-badge"]) a.supporter = false;
    rec.active = a;
  }
  // Money operations
  async _transferCredits(from, to) {
    if (!/^[0-9a-f]{64}$/.test(from || "") || !/^[0-9a-f]{64}$/.test(to || "")) {
      return { error: "Invalid pubkey." };
    }
    if (from === to) return { error: "You can't transfer credits to your own pubkey." };
    const source = await this._getCredits(from);
    if (!source.balance || source.balance <= 0) return { error: "No credits to transfer." };
    const moved = source.balance;
    const dest = await this._getCredits(to);
    dest.balance = (dest.balance || 0) + moved;
    dest.totalPurchased = (dest.totalPurchased || 0) + moved;
    source.balance = 0;
    await this._putCredits(to, dest);
    await this._putCredits(from, source);
    return { transferred: moved, target: to, sourceBalance: 0, targetBalance: dest.balance };
  }
  // Atomic spend for the paid-PM flow: re-checks balance under the lock so two
  // concurrent messages can't overspend.
  async _consumeCredits(pubkey, cost, ts) {
    if (!/^[0-9a-f]{64}$/.test(pubkey || "")) return { error: "Invalid pubkey." };
    cost = Math.max(0, Math.floor(Number(cost) || 0));
    const rec = await this._getCredits(pubkey);
    if ((rec.balance || 0) < cost) {
      return { ok: false, balance: rec.balance || 0, required: cost };
    }
    rec.balance -= cost;
    rec.totalUsed = (rec.totalUsed || 0) + cost;
    if (Number.isFinite(Number(ts))) {
      if (!Array.isArray(rec.rl)) rec.rl = [];
      rec.rl.push(Number(ts));
    }
    await this._putCredits(pubkey, rec);
    return { ok: true, balance: rec.balance };
  }
  // Atomic claim of a paid credit invoice. The caller has already verified
  // payment; this gates the grant on a single-use claim id.
  async _claimCredits(a) {
    const invoiceId = String(a.invoiceId || "");
    const creditTo = String(a.creditTo || "").toLowerCase();
    const credits = Math.max(0, Math.floor(Number(a.credits) || 0));
    if (!/^[0-9a-f]{64}$/i.test(invoiceId) || !/^[0-9a-f]{64}$/.test(creditTo) || credits <= 0) {
      return { error: "Invalid claim." };
    }
    if (!this._claimOnce("credits/" + invoiceId, "credits")) {
      return { alreadyClaimed: true };
    }
    const crec = await this._getCredits(creditTo);
    crec.balance = (crec.balance || 0) + credits;
    crec.totalPurchased = (crec.totalPurchased || 0) + credits;
    await this._putCredits(creditTo, crec);
    try {
      await invoicePut(
        this.env.DB_INVOICES,
        "credits",
        "claimed",
        invoiceId,
        Object.assign({ at: Date.now() }, a.claimData || {})
      );
    } catch {
    }
    try {
      await invoiceDelete(this.env.DB_INVOICES, "credits", "pending", invoiceId);
    } catch {
    }
    return { credited: credits, balance: crec.balance, recipient: creditTo };
  }
  async _shopClaim(a) {
    const invoiceId = String(a.invoiceId || "");
    const recipient = String(a.recipient || "").toLowerCase();
    const itemId = String(a.itemId || "");
    const code = String(a.code || "");
    if (!/^[0-9a-f]{64}$/i.test(invoiceId) || !/^[0-9a-f]{64}$/.test(recipient)) {
      return { error: "Invalid claim." };
    }
    if (!this._claimOnce("shop/" + invoiceId, "shop")) {
      let prev = null;
      try {
        prev = await invoiceGet(this.env.DB_INVOICES, "shop", "claimed", invoiceId);
      } catch {
      }
      return { alreadyClaimed: true, prev };
    }
    const crec = await this._getShop(recipient);
    if (Array.isArray(a.bundle) && a.bundle.length) {
      const granted = [];
      for (const comp of a.bundle) {
        const cid = String(comp && comp.itemId || "");
        const ccode = String(comp && comp.code || "");
        if (!cid) continue;
        crec.owned[cid] = { at: Date.now(), amountSats: 0, gift: !!a.gift, code: ccode, fromBundle: itemId };
        granted.push({ itemId: cid, code: ccode });
      }
      await this._putShop(recipient, crec);
      for (const g of granted) {
        if (g.code) {
          try {
            await codePut(this.env.DB_CODES, g.code, g.itemId, recipient, Date.now());
          } catch {
          }
        }
      }
      try {
        await invoicePut(
          this.env.DB_INVOICES,
          "shop",
          "claimed",
          invoiceId,
          Object.assign({ itemId, pubkey: recipient, code, bundle: granted, at: Date.now() }, a.claimData || {})
        );
      } catch {
      }
      try {
        await invoiceDelete(this.env.DB_INVOICES, "shop", "pending", invoiceId);
      } catch {
      }
      return { itemId, code, recipient, bundle: granted, owned: crec.owned, active: crec.active };
    }
    let edition = null;
    let editionMax = 0;
    if (a.edition && Number(a.edition.max) > 0) {
      editionMax = Math.floor(Number(a.edition.max));
      edition = this._allocateEdition(itemId, invoiceId, editionMax);
    }
    const entry = { at: Date.now(), amountSats: Number(a.amountSats) || 0, gift: !!a.gift, code };
    if (edition) {
      entry.edition = edition;
      entry.editionMax = editionMax;
    }
    crec.owned[itemId] = entry;
    await this._putShop(recipient, crec);
    try {
      await codePut(this.env.DB_CODES, code, itemId, recipient, Date.now());
    } catch {
    }
    try {
      await invoicePut(
        this.env.DB_INVOICES,
        "shop",
        "claimed",
        invoiceId,
        Object.assign({ itemId, pubkey: recipient, code, edition: edition || null, editionMax, at: Date.now() }, a.claimData || {})
      );
    } catch {
    }
    try {
      await invoiceDelete(this.env.DB_INVOICES, "shop", "pending", invoiceId);
    } catch {
    }
    return { itemId, code, recipient, edition: edition ? { n: edition, max: editionMax } : null, owned: crec.owned, active: crec.active };
  }
  async _shopTransfer(a) {
    const from = String(a.from || "").toLowerCase();
    const to = String(a.to || "").toLowerCase();
    const itemId = String(a.itemId || "");
    if (!/^[0-9a-f]{64}$/.test(from) || !/^[0-9a-f]{64}$/.test(to)) return { error: "Invalid pubkey." };
    if (from === to) return { error: "Cannot transfer to yourself." };
    const fromRec = await this._getShop(from);
    const entry = fromRec.owned[itemId];
    if (!entry) return { error: "You do not own this item." };
    delete fromRec.owned[itemId];
    this._pruneActive(fromRec);
    const toRec = await this._getShop(to);
    toRec.owned[itemId] = { at: Date.now(), amountSats: entry.amountSats || 0, gift: true, code: entry.code, transferredFrom: from };
    if (entry.edition) {
      toRec.owned[itemId].edition = entry.edition;
      toRec.owned[itemId].editionMax = entry.editionMax || 0;
    }
    await this._putShop(from, fromRec);
    await this._putShop(to, toRec);
    if (entry.code) {
      try {
        await codePut(this.env.DB_CODES, entry.code, itemId, to, Date.now());
      } catch {
      }
    }
    return { ok: true, itemId, owned: fromRec.owned, active: fromRec.active, code: entry.code || null };
  }
  async _shopRedeem(a) {
    const code = String(a.code || "");
    const itemId = String(a.itemId || "");
    const user = String(a.user || "").toLowerCase();
    const prevOwner = String(a.prevOwner || "").toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(user)) return { error: "Invalid pubkey." };
    if (prevOwner === user) {
      const ownRec = await this._getShop(user);
      return { alreadyOwner: true, owned: ownRec.owned, active: ownRec.active };
    }
    if (prevOwner && /^[0-9a-f]{64}$/.test(prevOwner)) {
      const prevRec = await this._getShop(prevOwner);
      if (prevRec.owned[itemId]) {
        delete prevRec.owned[itemId];
        this._pruneActive(prevRec);
        await this._putShop(prevOwner, prevRec);
      }
    }
    const rrec = await this._getShop(user);
    rrec.owned[itemId] = { at: Date.now(), amountSats: 0, gift: false, code, redeemed: true };
    await this._putShop(user, rrec);
    try {
      await codePut(this.env.DB_CODES, code, itemId, user, a.createdAt || Date.now());
    } catch {
    }
    return { itemId, owned: rrec.owned, active: rrec.active, prevOwner };
  }
};

// ledger/src/index.js
var index_default = {
  async fetch() {
    return new Response("nym-ledger", { status: 200 });
  }
};
export {
  NymLedger,
  index_default as default
};
