// Durable Object: NymLedger
// Serializes the money-critical mutations

import {
  creditsGet,
  creditsPut,
  shopGet,
  shopPut,
  invoicePut,
  invoiceDelete,
  invoiceGet,
  codePut
} from "./_d1.js";

const SATS_PER_CREDIT_DEFAULT = 100;

export class NymLedger {
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
  }

  // Serialize op handlers so an R2 read-modify-write can't interleave with
  // another op on the same instance.
  _exclusive(fn) {
    const run = this._chain.then(fn, fn);
    this._chain = run.then(() => {}, () => {});
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
      case "replay": return this._replay(a.id, a.ttl);
      case "transfer-credits": return this._transferCredits(a.from, a.to);
      case "consume-credits": return this._consumeCredits(a.pubkey, a.cost, a.ts);
      case "claim-credits": return this._claimCredits(a);
      case "shop-claim": return this._shopClaim(a);
      case "shop-transfer": return this._shopTransfer(a);
      case "shop-redeem": return this._shopRedeem(a);
      default: return { error: "unknown op" };
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
    const now = Math.floor(Date.now() / 1000);
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
    // Mark the invoice claimed so check-invoice's claimed read still works.
    try {
      await invoicePut(this.env.DB_INVOICES, "credits", "claimed", invoiceId,
        Object.assign({ at: Date.now() }, a.claimData || {}));
    } catch {}
    try { await invoiceDelete(this.env.DB_INVOICES, "credits", "pending", invoiceId); } catch {}
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
      // Already granted — return the prior marker so the client can recover.
      let prev = null;
      try { prev = await invoiceGet(this.env.DB_INVOICES, "shop", "claimed", invoiceId); } catch {}
      return { alreadyClaimed: true, prev };
    }
    const crec = await this._getShop(recipient);
    crec.owned[itemId] = { at: Date.now(), amountSats: Number(a.amountSats) || 0, gift: !!a.gift, code };
    await this._putShop(recipient, crec);
    try { await codePut(this.env.DB_CODES, code, itemId, recipient, Date.now()); } catch {}
    try {
      await invoicePut(this.env.DB_INVOICES, "shop", "claimed", invoiceId,
        Object.assign({ itemId, pubkey: recipient, code, at: Date.now() }, a.claimData || {}));
    } catch {}
    try { await invoiceDelete(this.env.DB_INVOICES, "shop", "pending", invoiceId); } catch {}
    return { itemId, code, recipient, owned: crec.owned, active: crec.active };
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
    await this._putShop(from, fromRec);
    await this._putShop(to, toRec);
    if (entry.code) {
      try { await codePut(this.env.DB_CODES, entry.code, itemId, to, Date.now()); } catch {}
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
    try { await codePut(this.env.DB_CODES, code, itemId, user, a.createdAt || Date.now()); } catch {}
    return { itemId, owned: rrec.owned, active: rrec.active, prevOwner };
  }
}

// Small helper used by the Pages Functions to call the single global ledger
// instance. All money mutations funnel through one instance so cross-pubkey
// operations (transfers) are globally serialized.
export async function ledgerCall(env, payload) {
  if (!env || !env.NYM_LEDGER) {
    return { error: "Ledger not configured (missing NYM_LEDGER binding)." , _noLedger: true };
  }
  const id = env.NYM_LEDGER.idFromName("global-v1");
  const stub = env.NYM_LEDGER.get(id);
  const resp = await stub.fetch("https://ledger/op", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  return await resp.json();
}
