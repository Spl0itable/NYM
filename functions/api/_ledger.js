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
  codePut,
  codeGet,
  codeDelete
} from "./_d1.js";
import { paceBucketTake, paceBucketSettle } from "./_pace.js";
import { GIFT_TTL_MS, GIFT_MAX_OPEN, GIFT_LIST_MAX, GIFT_SWEEP_MAX, giftTier, giftCode, giftId, giftAmount, giftPublic } from "./_gift.js";

const SATS_PER_CREDIT_DEFAULT = 100;
const SHOP_CODE_RE = /^NYM-[0-9A-F]{32}$/;

function shopNewCode() {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return "NYM-" + Array.from(b).map((x) => x.toString(16).padStart(2, "0")).join("").toUpperCase();
}

// An in-flight turn holds its claim on a lease the running attempt heartbeats
// ("turn-touch"), so the claim outlives the slowest model yet lapses seconds
// after the attempt's worker dies.
const BOT_TURN_LEASE_S = 45;
// A finished turn stays replayable well past the retry window.
const BOT_TURN_RESULT_TTL_S = 900;
// Comfortably above a gift-wrapped reply, comfortably below the row limit.
const BOT_TURN_MAX_RESULT_BYTES = 512 * 1024;
// A truncated agent run parks its conversation here so the next turn picks it
// up rather than starting over. Long enough for a person to read the partial
// answer and decide, short enough that abandoned runs cost nothing for long.
const BOT_RESUME_TTL_S = 1800;
const BOT_RESUME_MAX_BYTES = 512 * 1024;
// Progress is advisory and read while the turn is still generating, so it dies
// with the turn rather than outliving it.
const BOT_PROGRESS_TTL_S = 900;
const BOT_PROGRESS_MAX_STEPS = 120;
const BOT_PROGRESS_MAX_BYTES = 128 * 1024;
const BOT_DRAFT_MAX_CHARS = 32000;
const BOT_NOTIFY_MAX_TTL_S = 900;
const BOT_NOTIFY_PER_OWNER = 8;
const BOT_NOTIFY_TOKEN_RE = /^[0-9a-f]{64,200}$/;
const BOT_NOTIFY_CHAT_RE = /^[A-Za-z0-9_-]{1,64}$/;
// Cloudflare documents 300 requests a minute for Workers AI text generation,
// but only 50 a minute — 20 without prepaid gateway credits — for the frontier
// models (kimi-k2.6, kimi-k2.7-code, glm-5.2). 900ms was 67 a minute, over that
// ceiling, so the gate itself was issuing more than the tightest limit allows.
// 1300ms is 46 a minute, under it with room for clock skew between isolates.
const GATE_PACE_MS = 1300;
const GATE_PACE_LIMITED_MS = 4500;
const GATE_LIMIT_MEMORY_MS = 90000;
const GATE_MAX_WAIT_MS = 12000;
const GATE_TOKEN_MAX_WAIT_MS = 30000;

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
    // Limited-edition supply: minted count per item, plus TTL'd reservations
    // (one per pending invoice) that hold a slot until paid or expired.
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS edition_minted (item TEXT PRIMARY KEY, n INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS edition_resv (invoice TEXT PRIMARY KEY, item TEXT NOT NULL, user TEXT, exp INTEGER NOT NULL);"
    );
    // The free tier's daily allowance, one row per key
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS free_usage (pubkey TEXT PRIMARY KEY, day TEXT NOT NULL, used INTEGER NOT NULL);"
    );
    // And one row per address, so a new key does not reset it.
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS free_net (id TEXT PRIMARY KEY, day TEXT NOT NULL, used INTEGER NOT NULL);"
    );
    // One Nymbot PM turn, keyed by the gift wrap it answers. result NULL means
    // an attempt is in flight; a non-null result is the finished response body,
    // replayed verbatim to any retry of the same message.
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS bot_turns (id TEXT PRIMARY KEY, result TEXT, exp INTEGER NOT NULL);"
    );
    // A run that hit its turn cap with work left, parked so the next message
    // continues it. `owner` is the pubkey that paid for it — a token is only
    // ever redeemable by the key that made it, so a leaked token buys nothing.
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS bot_resume (id TEXT PRIMARY KEY, owner TEXT NOT NULL, state TEXT NOT NULL, exp INTEGER NOT NULL);"
    );
    // What the running attempt is doing, for the client watching it. Advisory:
    // losing it costs a progress line, never an answer.
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS bot_progress (id TEXT PRIMARY KEY, steps TEXT NOT NULL, exp INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS bot_draft (id TEXT PRIMARY KEY, text TEXT NOT NULL, seq INTEGER NOT NULL, at INTEGER NOT NULL, exp INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS turn_notify (id TEXT PRIMARY KEY, owner TEXT NOT NULL, token TEXT NOT NULL, env TEXT NOT NULL, chat TEXT NOT NULL, text TEXT, exp INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS gate (id TEXT PRIMARY KEY, next_at INTEGER NOT NULL, limited_at INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS gate_budget (id TEXT PRIMARY KEY, tokens REAL NOT NULL, at INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS credit_dust (pubkey TEXT NOT NULL, tier TEXT NOT NULL, milli INTEGER NOT NULL, PRIMARY KEY (pubkey, tier));"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS credit_holds (id TEXT PRIMARY KEY, pubkey TEXT NOT NULL, tier TEXT NOT NULL, amount INTEGER NOT NULL, exp INTEGER NOT NULL);"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS credit_gifts (id TEXT PRIMARY KEY, owner TEXT NOT NULL, tier TEXT NOT NULL, amount INTEGER NOT NULL, " +
      "created INTEGER NOT NULL, exp INTEGER NOT NULL, state TEXT NOT NULL, redeemer TEXT, done_at INTEGER);"
    );
  }

  // Serialize op handlers so a D1 read-modify-write can't interleave with
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
      case "consume-credits": return this._consumeCredits(a.pubkey, a.cost, a.ts, a.tier, a.milli, a.hold);
      case "credit-hold": return this._creditHold(a);
      case "credit-release": return this._creditRelease(a.id);
      case "dust-peek": return this._dustPeek(a.pubkey);
      case "free-claim": return this._freeClaim(a.pubkey, a.limit, a.net, a.netLimit);
      case "free-peek": return this._freePeek(a.pubkey, a.limit, a.net, a.netLimit);
      case "claim-credits": return this._claimCredits(a);
      case "shop-claim": return this._shopClaim(a);
      case "shop-transfer": return this._shopTransfer(a);
      case "shop-redeem": return this._shopRedeem(a);
      case "shop-reserve": return this._shopReserve(a);
      case "shop-supply": return this._shopSupply(a);
      case "turn-begin": return this._turnBegin(a.key);
      case "turn-poll": return this._turnPoll(a.key);
      case "turn-touch": return this._turnTouch(a.key);
      case "turn-abort": return this._turnAbort(a.key);
      case "turn-finish": return this._turnFinish(a.key, a.result);
      case "notify-put": return this._notifyPut(a);
      case "resume-put": return this._resumePut(a.id, a.owner, a.state);
      case "resume-take": return this._resumeTake(a.id, a.owner);
      case "progress-push": return this._progressPush(a.key, a.step);
      case "progress-read": return this._progressRead(a.key, a.after, a.draftAfter);
      case "progress-draft": return this._progressDraft(a.key, a.text, a.seq);
      case "gate-take": return this._gateTake(a);
      case "gate-limited": return this._gateLimited(a);
      case "gate-settle": return this._gateSettle(a);
      case "gift-create": return this._giftCreate(a);
      case "gift-redeem": return this._giftRedeem(a);
      case "gift-cancel": return this._giftCancel(a);
      case "gift-list": return this._giftList(a);
      case "gift-peek": return this._giftPeek(a);
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

  // Nymbot turn de-duplication.
  _turnSweep(now) {
    this.sql.exec("DELETE FROM bot_turns WHERE exp < ?;", now);
    this._notifySweep(now);
  }

  _turnRow(key) {
    if (typeof key !== "string" || !key || key.length > 256) return { bad: true };
    const now = Math.floor(Date.now() / 1000);
    this._turnSweep(now);
    const rows = this.sql.exec("SELECT result FROM bot_turns WHERE id = ? LIMIT 1;", key).toArray();
    if (!rows.length) return { now, missing: true };
    const raw = rows[0].result;
    if (!raw) return { now, running: true };
    try {
      return { now, result: JSON.parse(raw) };
    } catch {
      // Unreadable row: treat the turn as never having happened rather than
      // stranding the message.
      this.sql.exec("DELETE FROM bot_turns WHERE id = ?;", key);
      return { now, missing: true };
    }
  }

  // Claim a turn. "done" carries the stored response, "running" means another
  // attempt owns it, "claimed" means this caller owns it and should run.
  _turnBegin(key) {
    const row = this._turnRow(key);
    if (row.bad) return { state: "error" };
    if (row.result) return { state: "done", result: row.result };
    if (row.running) return { state: "running" };
    this.sql.exec(
      "INSERT INTO bot_turns (id, result, exp) VALUES (?, NULL, ?);",
      key,
      row.now + BOT_TURN_LEASE_S
    );
    return { state: "claimed" };
  }

  // Push the lease out, so a waiting retry keeps seeing "running" while this
  // attempt really is still generating. "lost": the claim is no longer ours.
  _turnTouch(key) {
    const row = this._turnRow(key);
    if (row.bad) return { ok: false };
    if (row.result) return { ok: false, lost: true, finished: true };
    if (!row.running) return { ok: false, lost: true };
    this.sql.exec(
      "UPDATE bot_turns SET exp = ? WHERE id = ? AND result IS NULL;",
      row.now + BOT_TURN_LEASE_S,
      key
    );
    return { ok: true };
  }

  // Release an unfinished claim (the attempt failed before it charged for an
  // answer). A finished turn is left alone so its result stays replayable.
  _turnAbort(key) {
    if (typeof key !== "string" || !key || key.length > 256) return { ok: false };
    this.sql.exec("DELETE FROM bot_turns WHERE id = ? AND result IS NULL;", key);
    this._draftDrop(key);
    return this._withNotify({ ok: true }, key);
  }

  // Read-only probe used while waiting on an in-flight attempt. "gone" means
  // the claim lapsed (the other attempt died), so the caller may run it.
  _turnPoll(key) {
    const row = this._turnRow(key);
    if (row.bad) return { state: "error" };
    if (row.result) return { state: "done", result: row.result };
    if (row.running) return { state: "running" };
    return { state: "gone" };
  }

  _turnFinish(key, result) {
    if (typeof key !== "string" || !key || key.length > 256) return { ok: false };
    let encoded;
    try {
      encoded = JSON.stringify(result);
    } catch {
      return { ok: false };
    }
    // Never risk the row limit: an unstored result only costs the retry path,
    // it does not break the turn that just succeeded.
    this._draftDrop(key);
    if (!encoded || encoded.length > BOT_TURN_MAX_RESULT_BYTES) {
      this.sql.exec("DELETE FROM bot_turns WHERE id = ?;", key);
      return this._withNotify({ ok: false, tooLarge: true }, key);
    }
    const now = Math.floor(Date.now() / 1000);
    this.sql.exec(
      "INSERT INTO bot_turns (id, result, exp) VALUES (?, ?, ?) " +
      "ON CONFLICT(id) DO UPDATE SET result = excluded.result, exp = excluded.exp;",
      key,
      encoded,
      now + BOT_TURN_RESULT_TTL_S
    );
    return this._withNotify({ ok: true }, key);
  }

  _notifySweep(now) {
    this.sql.exec("DELETE FROM turn_notify WHERE exp < ?;", now);
  }

  _notifyPut(a) {
    const key = a && a.key;
    if (typeof key !== "string" || !key || key.length > 256) return { ok: false, error: "bad key" };
    const owner = typeof a.owner === "string" ? a.owner.toLowerCase() : "";
    if (!/^[0-9a-f]{64}$/.test(owner)) return { ok: false, error: "bad owner" };
    const token = typeof a.token === "string" ? a.token.toLowerCase() : "";
    if (!BOT_NOTIFY_TOKEN_RE.test(token)) return { ok: false, error: "bad token" };
    if (a.env !== "production" && a.env !== "sandbox") return { ok: false, error: "bad env" };
    if (typeof a.chat !== "string" || !BOT_NOTIFY_CHAT_RE.test(a.chat)) return { ok: false, error: "bad chat" };
    const text = typeof a.text === "string" && a.text.trim() ? a.text.trim().slice(0, 80) : null;
    const now = Math.floor(Date.now() / 1000);
    const ttl = Math.max(1, Math.min(BOT_NOTIFY_MAX_TTL_S, Math.floor(Number(a.ttl) || BOT_NOTIFY_MAX_TTL_S)));
    const turn = this._turnRow(key);
    if (turn.bad) return { ok: false, error: "bad key" };
    if (turn.result) return { ok: true, done: true };
    const held = this.sql.exec(
      "SELECT COUNT(*) AS n FROM turn_notify WHERE owner = ? AND id != ?;", owner, key
    ).toArray();
    if ((held.length ? Number(held[0].n) || 0 : 0) >= BOT_NOTIFY_PER_OWNER) return { ok: false, capped: true };
    this.sql.exec(
      "INSERT INTO turn_notify (id, owner, token, env, chat, text, exp) VALUES (?, ?, ?, ?, ?, ?, ?) " +
      "ON CONFLICT(id) DO UPDATE SET owner = excluded.owner, token = excluded.token, env = excluded.env, " +
      "chat = excluded.chat, text = excluded.text, exp = excluded.exp;",
      key, owner, token, a.env, a.chat, text, now + ttl
    );
    return { ok: true, expiresIn: ttl };
  }

  _notifyTake(key) {
    const now = Math.floor(Date.now() / 1000);
    this._notifySweep(now);
    const rows = this.sql.exec(
      "SELECT token, env, chat, text FROM turn_notify WHERE id = ? LIMIT 1;", key
    ).toArray();
    if (!rows.length) return null;
    this.sql.exec("DELETE FROM turn_notify WHERE id = ?;", key);
    const r = rows[0];
    return { token: r.token, env: r.env, chat: r.chat, text: r.text || null };
  }

  _withNotify(out, key) {
    const notify = this._notifyTake(key);
    if (notify) out.notify = notify;
    return out;
  }

  // --- resuming a truncated run -------------------------------------------

  _resumePut(id, owner, state) {
    if (typeof id !== "string" || !/^[0-9a-f]{32,64}$/i.test(id)) return { ok: false };
    if (typeof owner !== "string" || !/^[0-9a-f]{64}$/i.test(owner)) return { ok: false };
    let encoded;
    try {
      encoded = JSON.stringify(state);
    } catch {
      return { ok: false };
    }
    // Too big to park is not an error: the run simply cannot be continued, and
    // the user keeps the partial answer they already paid for.
    if (!encoded || encoded.length > BOT_RESUME_MAX_BYTES) return { ok: false, tooLarge: true };
    const now = Math.floor(Date.now() / 1000);
    this.sql.exec("DELETE FROM bot_resume WHERE exp < ?;", now);
    this.sql.exec(
      "INSERT INTO bot_resume (id, owner, state, exp) VALUES (?, ?, ?, ?) " +
      "ON CONFLICT(id) DO UPDATE SET owner = excluded.owner, state = excluded.state, exp = excluded.exp;",
      id,
      owner.toLowerCase(),
      encoded,
      now + BOT_RESUME_TTL_S
    );
    return { ok: true, expiresIn: BOT_RESUME_TTL_S };
  }

  // Single use: taking a token consumes it, so a resend of the continuing
  // message replays the finished turn rather than continuing the run twice.
  _resumeTake(id, owner) {
    if (typeof id !== "string" || !/^[0-9a-f]{32,64}$/i.test(id)) return { ok: false };
    if (typeof owner !== "string" || !/^[0-9a-f]{64}$/i.test(owner)) return { ok: false };
    const now = Math.floor(Date.now() / 1000);
    this.sql.exec("DELETE FROM bot_resume WHERE exp < ?;", now);
    const rows = this.sql
      .exec("SELECT owner, state FROM bot_resume WHERE id = ? LIMIT 1;", id)
      .toArray();
    if (!rows.length) return { ok: false, missing: true };
    if (rows[0].owner !== owner.toLowerCase()) return { ok: false, missing: true };
    this.sql.exec("DELETE FROM bot_resume WHERE id = ?;", id);
    try {
      return { ok: true, state: JSON.parse(rows[0].state) };
    } catch {
      return { ok: false, missing: true };
    }
  }

  // --- what the running attempt is doing ----------------------------------

  _progressPush(key, step) {
    if (typeof key !== "string" || !key || key.length > 256) return { ok: false };
    if (!step || typeof step !== "object") return { ok: false };
    const now = Math.floor(Date.now() / 1000);
    this.sql.exec("DELETE FROM bot_progress WHERE exp < ?;", now);
    let steps = [];
    const rows = this.sql
      .exec("SELECT steps FROM bot_progress WHERE id = ? LIMIT 1;", key)
      .toArray();
    if (rows.length) {
      try {
        const parsed = JSON.parse(rows[0].steps);
        if (Array.isArray(parsed)) steps = parsed;
      } catch {
        steps = [];
      }
    }
    // Numbered from the highest already handed out, not from the array's length:
    // once trimming starts, length stops growing and a length-derived number is
    const lastN = steps.length ? Number(steps[steps.length - 1].n) || 0 : 0;
    steps.push({ n: lastN + 1, at: Date.now(), ...step });
    // Oldest first out: a watcher that joined late wants the recent picture,
    // and the numbering keeps its "after" cursor meaningful either way.
    if (steps.length > BOT_PROGRESS_MAX_STEPS) {
      steps = steps.slice(steps.length - BOT_PROGRESS_MAX_STEPS);
    }
    let encoded = JSON.stringify(steps);
    while (encoded.length > BOT_PROGRESS_MAX_BYTES && steps.length > 1) {
      steps = steps.slice(1);
      encoded = JSON.stringify(steps);
    }
    this.sql.exec(
      "INSERT INTO bot_progress (id, steps, exp) VALUES (?, ?, ?) " +
      "ON CONFLICT(id) DO UPDATE SET steps = excluded.steps, exp = excluded.exp;",
      key,
      encoded,
      now + BOT_PROGRESS_TTL_S
    );
    return { ok: true, n: steps.length ? steps[steps.length - 1].n : 0 };
  }

  _progressRead(key, after, draftAfter) {
    if (typeof key !== "string" || !key || key.length > 256) return { steps: [] };
    const now = Math.floor(Date.now() / 1000);
    this.sql.exec("DELETE FROM bot_progress WHERE exp < ?;", now);
    const out = { steps: [] };
    const draft = this._draftRead(key, now, draftAfter);
    if (draft) out.draft = draft;
    const rows = this.sql
      .exec("SELECT steps FROM bot_progress WHERE id = ? LIMIT 1;", key)
      .toArray();
    if (!rows.length) return out;
    let steps = [];
    try {
      const parsed = JSON.parse(rows[0].steps);
      if (Array.isArray(parsed)) steps = parsed;
    } catch {
      return out;
    }
    const from = Number(after) || 0;
    out.steps = steps.filter((s) => (s && s.n ? s.n : 0) > from);
    return out;
  }

  _progressDraft(key, text, seq) {
    if (typeof key !== "string" || !key || key.length > 256) return { ok: false };
    const n = Math.floor(Number(seq));
    if (!Number.isFinite(n) || n < 1) return { ok: false };
    const row = this._turnRow(key);
    if (row.bad || !row.running) {
      this._draftDrop(key);
      return { ok: false, closed: true };
    }
    let body = typeof text === "string" ? text : "";
    let cut = false;
    if (body.length > BOT_DRAFT_MAX_CHARS) {
      body = body.slice(0, BOT_DRAFT_MAX_CHARS);
      cut = true;
    }
    const now = Math.floor(Date.now() / 1000);
    this.sql.exec("DELETE FROM bot_draft WHERE exp < ?;", now);
    const held = this.sql.exec("SELECT seq FROM bot_draft WHERE id = ? LIMIT 1;", key).toArray();
    if (held.length && Number(held[0].seq) >= n) return { ok: false, stale: true };
    this.sql.exec(
      "INSERT INTO bot_draft (id, text, seq, at, exp) VALUES (?, ?, ?, ?, ?) " +
      "ON CONFLICT(id) DO UPDATE SET text = excluded.text, seq = excluded.seq, at = excluded.at, exp = excluded.exp;",
      key,
      body,
      n,
      Date.now(),
      now + BOT_PROGRESS_TTL_S
    );
    return { ok: true, seq: n, cut };
  }

  _draftRead(key, now, after) {
    this.sql.exec("DELETE FROM bot_draft WHERE exp < ?;", now);
    const rows = this.sql
      .exec("SELECT text, seq, at FROM bot_draft WHERE id = ? LIMIT 1;", key)
      .toArray();
    if (!rows.length) return null;
    const seq = Number(rows[0].seq) || 0;
    if (seq <= (Number(after) || 0)) return null;
    return { text: String(rows[0].text || ""), seq, at: Number(rows[0].at) || 0 };
  }

  _draftDrop(key) {
    this.sql.exec("DELETE FROM bot_draft WHERE id = ?;", key);
  }

  _gateNum(v, fallback, cap) {
    const n = Number(v);
    if (!isFinite(n) || n < 0) return fallback;
    return Math.min(Math.round(n), cap);
  }

  _gateId(v) {
    const id = typeof v === "string" ? v.replace(/[^A-Za-z0-9._:-]/g, "").slice(0, 64) : "";
    return id || "gateway";
  }

  _gateRow(id) {
    const rows = this.sql
      .exec("SELECT next_at, limited_at FROM gate WHERE id = ? LIMIT 1;", id)
      .toArray();
    return rows.length ? rows[0] : null;
  }

  _gateSave(id, nextAt, limitedAt) {
    this.sql.exec(
      "INSERT INTO gate (id, next_at, limited_at) VALUES (?, ?, ?) " +
      "ON CONFLICT(id) DO UPDATE SET next_at = excluded.next_at, limited_at = excluded.limited_at;",
      id,
      Math.round(nextAt),
      Math.round(limitedAt)
    );
  }

  _gateTake(a) {
    const id = this._gateId(a && a.id);
    const pace = this._gateNum(a && a.pace, GATE_PACE_MS, 20000);
    const limitedPace = Math.max(pace, this._gateNum(a && a.limitedPace, GATE_PACE_LIMITED_MS, 60000));
    const memory = this._gateNum(a && a.memory, GATE_LIMIT_MEMORY_MS, 600000);
    const maxWait = this._gateNum(a && a.maxWait, GATE_MAX_WAIT_MS, 60000);
    const now = Date.now();
    const row = this._gateRow(id);
    const limitedAt = row ? Number(row.limited_at) || 0 : 0;
    const since = now - limitedAt;
    const recent = limitedAt > 0 && since < memory;
    const gap = recent
      ? Math.round(pace + (limitedPace - pace) * (1 - since / memory))
      : pace;
    let at = row && Number(row.next_at) > now ? Number(row.next_at) : now;
    if (at > now + maxWait) at = now + maxWait;
    this._gateSave(id, at + gap, limitedAt);
    const tokenWait = this._gateBudgetTake(id, a, now);
    const paceWait = at - now;
    const out = { ok: true, waitMs: Math.max(paceWait, tokenWait), gap, limited: recent };
    if (tokenWait > 0) out.tokenWaitMs = tokenWait;
    return out;
  }

  _gateBudgetRow(id) {
    const rows = this.sql
      .exec("SELECT tokens, at FROM gate_budget WHERE id = ? LIMIT 1;", id)
      .toArray();
    return rows.length ? { tokens: Number(rows[0].tokens), at: Number(rows[0].at) } : null;
  }

  _gateBudgetSave(id, state) {
    this.sql.exec(
      "INSERT INTO gate_budget (id, tokens, at) VALUES (?, ?, ?) " +
      "ON CONFLICT(id) DO UPDATE SET tokens = excluded.tokens, at = excluded.at;",
      id,
      Number(state.tokens) || 0,
      Math.round(Number(state.at) || Date.now())
    );
  }

  _gateBudgetTake(id, a, now) {
    const tokens = Number(a && a.tokens);
    const tpm = Number(a && a.tpm);
    if (!isFinite(tokens) || tokens <= 0 || !isFinite(tpm) || tpm <= 0) return 0;
    const maxWait = this._gateNum(a && a.tokenMaxWait, GATE_TOKEN_MAX_WAIT_MS, 60000);
    const taken = paceBucketTake(this._gateBudgetRow(id), now, tokens, tpm, maxWait);
    this._gateBudgetSave(id, taken.state);
    return taken.waitMs;
  }

  _gateSettle(a) {
    const id = this._gateId(a && a.id);
    const tpm = Number(a && a.tpm);
    const delta = Number(a && a.delta);
    if (!isFinite(tpm) || tpm <= 0 || !isFinite(delta)) return { ok: false };
    const row = this._gateBudgetRow(id);
    if (!row) return { ok: true };
    this._gateBudgetSave(id, paceBucketSettle(row, Date.now(), delta, tpm));
    return { ok: true };
  }

  _gateLimited(a) {
    const id = this._gateId(a && a.id);
    const penalty = this._gateNum(a && a.penalty, GATE_PACE_LIMITED_MS, 60000);
    const now = Date.now();
    const row = this._gateRow(id);
    const base = row && Number(row.next_at) > now ? Number(row.next_at) : now;
    const next = base + penalty;
    this._gateSave(id, next, now);
    return { ok: true, waitMs: next - now };
  }

  // Limited-edition supply (numbered drops)
  _editionMinted(item) {
    const r = this.sql.exec("SELECT n FROM edition_minted WHERE item = ? LIMIT 1;", item).toArray();
    return r.length ? (r[0].n || 0) : 0;
  }

  _editionLiveReservations(item, now) {
    const r = this.sql.exec("SELECT COUNT(*) AS c FROM edition_resv WHERE item = ? AND exp > ?;", item, now).toArray();
    return r.length ? (r[0].c || 0) : 0;
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
    // Re-reserving the same invoice is idempotent (it already holds a slot).
    const existing = this.sql.exec("SELECT item FROM edition_resv WHERE invoice = ? LIMIT 1;", invoice).toArray();
    if (existing.length) return { ok: true, reused: true };
    // Cap each user to one live reservation per item so nobody can lock up a
    // drop by repeatedly opening the buy dialog. Freeing the old slot first
    // keeps the count honest before we re-check supply.
    if (/^[0-9a-f]{64}$/.test(user)) {
      this.sql.exec("DELETE FROM edition_resv WHERE item = ? AND user = ?;", item, user);
    }
    const minted = this._editionMinted(item);
    const live = this._editionLiveReservations(item, now);
    if (minted + live >= max) return { soldOut: true, remaining: 0 };
    this.sql.exec("INSERT INTO edition_resv (invoice, item, user, exp) VALUES (?, ?, ?, ?);", invoice, item, user || null, now + ttl * 1000);
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
      item, n, n
    );
    return n;
  }

  // D1 credit/shop helpers. Pro credits share the credits table under a
  // "#pro"-suffixed row key ("#" is not hex, so no pubkey collision).
  _creditKey(pk, tier) {
    return tier === "pro" ? pk + "#pro" : pk;
  }

  async _getCredits(pk, tier) {
    return creditsGet(this.env.DB_CREDITS, this._creditKey(pk, tier));
  }

  async _putCredits(pk, data, tier) {
    await creditsPut(this.env.DB_CREDITS, this._creditKey(pk, tier), data);
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

  // Money operations. Transfers move the user's ENTIRE balance — both the
  // standard and Pro pools — to the target pubkey.
  async _transferCredits(from, to) {
    if (!/^[0-9a-f]{64}$/.test(from || "") || !/^[0-9a-f]{64}$/.test(to || "")) {
      return { error: "Invalid pubkey." };
    }
    if (from === to) return { error: "You can't transfer credits to your own pubkey." };
    const source = await this._getCredits(from);
    const proSource = await this._getCredits(from, "pro");
    const held = this._holdsOf(from, "standard", null);
    const proHeld = this._holdsOf(from, "pro", null);
    const moved = Math.max(0, (source.balance || 0) - held);
    const proMoved = Math.max(0, (proSource.balance || 0) - proHeld);
    if (moved <= 0 && proMoved <= 0) {
      if (held > 0 || proHeld > 0) return { error: "Your credits are paying for a reply that is still running. Try again when it finishes." };
      return { error: "No credits to transfer." };
    }
    let targetBalance = 0;
    let targetProBalance = 0;
    if (moved > 0) {
      const dest = await this._getCredits(to);
      dest.balance = (dest.balance || 0) + moved;
      dest.totalPurchased = (dest.totalPurchased || 0) + moved;
      source.balance = (source.balance || 0) - moved;
      await this._putCredits(to, dest);
      await this._putCredits(from, source);
      targetBalance = dest.balance;
    }
    if (proMoved > 0) {
      const proDest = await this._getCredits(to, "pro");
      proDest.balance = (proDest.balance || 0) + proMoved;
      proDest.totalPurchased = (proDest.totalPurchased || 0) + proMoved;
      proSource.balance = (proSource.balance || 0) - proMoved;
      await this._putCredits(to, proDest, "pro");
      await this._putCredits(from, proSource, "pro");
      targetProBalance = proDest.balance;
    }
    return {
      transferred: moved, proTransferred: proMoved, target: to,
      sourceBalance: Math.max(0, (source.balance || 0)), targetBalance, targetProBalance
    };
  }

  _giftRow(id) {
    const rows = this.sql.exec(
      "SELECT id, owner, tier, amount, created, exp, state, redeemer, done_at FROM credit_gifts WHERE id = ? LIMIT 1;", id
    ).toArray();
    return rows.length ? rows[0] : null;
  }

  async _giftRefund(row, state, now) {
    const tier = giftTier(row.tier);
    const rec = await this._getCredits(row.owner, tier);
    rec.balance = (rec.balance || 0) + (Number(row.amount) || 0);
    await this._putCredits(row.owner, rec, tier);
    this.sql.exec("UPDATE credit_gifts SET state = ?, done_at = ? WHERE id = ? AND state = 'open';", state, now, row.id);
    return rec.balance;
  }

  async _giftSweep(owner, now) {
    const rows = owner
      ? this.sql.exec(
        "SELECT id, owner, tier, amount FROM credit_gifts WHERE state = 'open' AND exp <= ? AND owner = ? LIMIT ?;", now, owner, GIFT_SWEEP_MAX
      ).toArray()
      : this.sql.exec(
        "SELECT id, owner, tier, amount FROM credit_gifts WHERE state = 'open' AND exp <= ? LIMIT ?;", now, GIFT_SWEEP_MAX
      ).toArray();
    for (const row of rows) await this._giftRefund(row, "expired", now);
    return rows.length;
  }

  async _giftCreate(a) {
    const owner = String(a.owner || "");
    if (!/^[0-9a-f]{64}$/.test(owner)) return { error: "Invalid pubkey." };
    const tier = giftTier(a.tier);
    const code = giftCode(a.code);
    if (!code) return { error: "Invalid gift code." };
    const sized = giftAmount(a.amount, tier);
    if (sized.error) return { error: sized.error };
    const amount = sized.amount;
    const now = Date.now();
    await this._giftSweep(null, now);
    const id = await giftId(code);
    const known = this._giftRow(id);
    if (known) {
      if (known.owner !== owner || known.tier !== tier || Number(known.amount) !== amount) {
        return { error: "That gift code is already taken. Try again." };
      }
      const same = await this._getCredits(owner, tier);
      return { ok: true, replayed: true, gift: giftPublic(known, owner), code, balance: same.balance || 0 };
    }
    const open = this.sql.exec(
      "SELECT COUNT(*) AS n FROM credit_gifts WHERE owner = ? AND state = 'open';", owner
    ).toArray();
    if (open.length && Number(open[0].n) >= GIFT_MAX_OPEN) {
      return { error: "You have " + GIFT_MAX_OPEN + " gifts nobody has claimed yet. Cancel one, or wait for one to be claimed, before making another.", tooMany: true };
    }
    const rec = await this._getCredits(owner, tier);
    const held = this._holdsOf(owner, tier, null);
    const free = (rec.balance || 0) - held;
    if (free < amount) {
      return { ok: false, insufficient: true, balance: rec.balance || 0, held, available: Math.max(0, free), required: amount, tier };
    }
    rec.balance -= amount;
    await this._putCredits(owner, rec, tier);
    this.sql.exec(
      "INSERT INTO credit_gifts (id, owner, tier, amount, created, exp, state, redeemer, done_at) VALUES (?, ?, ?, ?, ?, ?, 'open', NULL, NULL);",
      id, owner, tier, amount, now, now + GIFT_TTL_MS
    );
    return { ok: true, gift: giftPublic(this._giftRow(id), owner), code, balance: rec.balance };
  }

  async _giftRedeem(a) {
    const user = String(a.user || "");
    if (!/^[0-9a-f]{64}$/.test(user)) return { error: "Invalid pubkey." };
    const code = giftCode(a.code);
    if (!code) return { error: "That is not a gift code.", invalid: true };
    const now = Date.now();
    const row = this._giftRow(await giftId(code));
    if (!row) return { error: "No gift has that code.", unknown: true };
    const tier = giftTier(row.tier);
    const amount = Number(row.amount) || 0;
    if (row.state === "redeemed") {
      if (row.redeemer === user) {
        const mine = await this._getCredits(user, tier);
        return { ok: true, replayed: true, credited: amount, tier, balance: mine.balance || 0 };
      }
      return { error: "This gift has already been claimed.", claimed: true };
    }
    if (row.state === "canceled") return { error: "Whoever made this gift canceled it.", canceled: true };
    if (row.state === "expired") return { error: "This gift expired and went back to whoever made it.", expired: true };
    if (Number(row.exp) <= now) {
      await this._giftRefund(row, "expired", now);
      return { error: "This gift expired and went back to whoever made it.", expired: true };
    }
    if (row.owner === user) {
      return { error: "This is your own gift. Cancel it to put the credits back instead.", own: true };
    }
    const rec = await this._getCredits(user, tier);
    rec.balance = (rec.balance || 0) + amount;
    rec.totalPurchased = (rec.totalPurchased || 0) + amount;
    await this._putCredits(user, rec, tier);
    this.sql.exec(
      "UPDATE credit_gifts SET state = 'redeemed', redeemer = ?, done_at = ? WHERE id = ? AND state = 'open';", user, now, row.id
    );
    return { ok: true, credited: amount, tier, balance: rec.balance };
  }

  async _giftCancel(a) {
    const owner = String(a.owner || "");
    if (!/^[0-9a-f]{64}$/.test(owner)) return { error: "Invalid pubkey." };
    let id = String(a.id || "").toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(id)) {
      const code = giftCode(a.code);
      if (!code) return { error: "Which gift?" };
      id = await giftId(code);
    }
    const row = this._giftRow(id);
    if (!row || row.owner !== owner) return { error: "No gift of yours has that code.", unknown: true };
    const tier = giftTier(row.tier);
    if (row.state === "redeemed") return { error: "This gift has already been claimed, so it cannot be canceled.", claimed: true };
    if (row.state !== "open") {
      const same = await this._getCredits(owner, tier);
      return { ok: true, replayed: true, refunded: 0, tier, state: row.state, balance: same.balance || 0 };
    }
    const now = Date.now();
    const balance = await this._giftRefund(row, Number(row.exp) <= now ? "expired" : "canceled", now);
    return { ok: true, refunded: Number(row.amount) || 0, tier, state: this._giftRow(id).state, balance };
  }

  async _giftList(a) {
    const owner = String(a.owner || "");
    if (!/^[0-9a-f]{64}$/.test(owner)) return { error: "Invalid pubkey." };
    await this._giftSweep(owner, Date.now());
    const rows = this.sql.exec(
      "SELECT id, owner, tier, amount, created, exp, state, redeemer, done_at FROM credit_gifts WHERE owner = ? ORDER BY created DESC LIMIT ?;",
      owner, GIFT_LIST_MAX
    ).toArray();
    return { ok: true, gifts: rows.map((r) => giftPublic(r, owner)) };
  }

  async _giftPeek(a) {
    const user = String(a.user || "");
    const code = giftCode(a.code);
    if (!code) return { error: "That is not a gift code.", invalid: true };
    const row = this._giftRow(await giftId(code));
    if (!row) return { error: "No gift has that code.", unknown: true };
    const view = giftPublic(row, user);
    if (view.state === "open" && view.expiresAt <= Date.now()) view.state = "expired";
    return { ok: true, gift: view };
  }

  // Atomic spend for the paid-PM flow: re-checks balance under the lock so two
  // concurrent messages can't overspend.
  _dustOf(pubkey, tier) {
    const rows = this.sql
      .exec("SELECT milli FROM credit_dust WHERE pubkey = ? AND tier = ? LIMIT 1;", pubkey, tier)
      .toArray();
    return rows.length ? Math.max(0, Number(rows[0].milli) || 0) : 0;
  }

  _dustPeek(pubkey) {
    if (!/^[0-9a-f]{64}$/.test(pubkey || "")) return { error: "Invalid pubkey." };
    return {
      ok: true,
      standard: this._dustOf(pubkey, "standard"),
      pro: this._dustOf(pubkey, "pro")
    };
  }

  _setDust(pubkey, tier, milli) {
    this.sql.exec(
      "INSERT INTO credit_dust (pubkey, tier, milli) VALUES (?, ?, ?) " +
      "ON CONFLICT(pubkey, tier) DO UPDATE SET milli = excluded.milli;",
      pubkey, tier, Math.max(0, Math.floor(milli))
    );
  }

  _holdsOf(pubkey, tierKey, except) {
    const now = Date.now();
    this.sql.exec("DELETE FROM credit_holds WHERE exp <= ?;", now);
    const rows = this.sql.exec(
      "SELECT id, amount FROM credit_holds WHERE pubkey = ? AND tier = ? AND exp > ?;", pubkey, tierKey, now
    ).toArray();
    let held = 0;
    for (const r of rows || []) {
      if (except && r.id === except) continue;
      held += Math.max(0, Number(r.amount) || 0);
    }
    return held;
  }

  _takeHold(id, pubkey, tierKey) {
    if (typeof id !== "string" || !/^[0-9a-f]{32}$/.test(id)) return false;
    const rows = this.sql.exec(
      "SELECT id FROM credit_holds WHERE id = ? AND pubkey = ? AND tier = ? AND exp > ? LIMIT 1;", id, pubkey, tierKey, Date.now()
    ).toArray();
    this.sql.exec("DELETE FROM credit_holds WHERE id = ? AND pubkey = ?;", id, pubkey);
    return !!(rows && rows.length);
  }

  async _creditHold(a) {
    const pubkey = String(a.pubkey || "");
    const id = String(a.id || "");
    if (!/^[0-9a-f]{64}$/.test(pubkey)) return { error: "Invalid pubkey." };
    if (!/^[0-9a-f]{32}$/.test(id)) return { error: "Invalid hold." };
    const tierKey = a.tier === "pro" ? "pro" : "standard";
    const amount = Math.max(0, Math.floor(Number(a.amount) || 0));
    const ttl = Math.min(3600, Math.max(30, Math.floor(Number(a.ttl) || 900)));
    const limit = Math.floor(Number(a.rateLimit) || 0);
    const windowMs = Math.max(1000, Math.floor(Number(a.rateWindowMs) || 60000));
    const now = Date.now();
    if (limit > 0) {
      const cutoff = now - windowMs;
      let recent = 0;
      for (const t of ["standard", "pro"]) {
        const r = await this._getCredits(pubkey, t);
        recent += (Array.isArray(r.rl) ? r.rl : []).filter((x) => x > cutoff).length;
      }
      if (recent >= limit) return { ok: false, rateLimited: true };
    }
    const rec = await this._getCredits(pubkey, tierKey);
    const held = this._holdsOf(pubkey, tierKey, null);
    const free = (rec.balance || 0) - held;
    if (free < amount) return { ok: false, balance: rec.balance || 0, held: held, required: amount };
    this.sql.exec(
      "INSERT OR REPLACE INTO credit_holds (id, pubkey, tier, amount, exp) VALUES (?, ?, ?, ?, ?);",
      id, pubkey, tierKey, amount, now + ttl * 1000
    );
    if (!Array.isArray(rec.rl)) rec.rl = [];
    rec.rl = rec.rl.filter((t) => t > now - 600000);
    rec.rl.push(now);
    await this._putCredits(pubkey, rec, tierKey);
    return { ok: true, balance: rec.balance || 0, held: held + amount };
  }

  _creditRelease(id) {
    if (typeof id !== "string" || !/^[0-9a-f]{32}$/.test(id)) return { ok: false };
    this.sql.exec("DELETE FROM credit_holds WHERE id = ?;", id);
    return { ok: true };
  }

  async _consumeCredits(pubkey, cost, ts, tier, milli, hold) {
    if (!/^[0-9a-f]{64}$/.test(pubkey || "")) return { error: "Invalid pubkey." };
    cost = Math.max(0, Math.floor(Number(cost) || 0));
    const tierKey = tier === "pro" ? "pro" : "standard";
    const counted = hold ? this._takeHold(hold, pubkey, tierKey) : false;
    const heldByOthers = this._holdsOf(pubkey, tierKey, null);
    const owed = Math.max(0, Math.floor(Number(milli) || 0));
    let dust = 0;
    let nextDust = 0;
    if (owed > 0) {
      dust = this._dustOf(pubkey, tierKey);
      const total = dust + owed;
      cost += Math.floor(total / 1000);
      nextDust = total % 1000;
    }
    const rec = await this._getCredits(pubkey, tier);
    if ((rec.balance || 0) - heldByOthers < cost) {
      return { ok: false, balance: rec.balance || 0, required: cost };
    }
    if (owed > 0) this._setDust(pubkey, tierKey, nextDust);
    rec.balance -= cost;
    rec.totalUsed = (rec.totalUsed || 0) + cost;
    if (!counted && Number.isFinite(Number(ts))) {
      if (!Array.isArray(rec.rl)) rec.rl = [];
      // Drop stamps far older than any rate window so the row can't grow forever.
      const rlCutoff = Date.now() - 600000;
      rec.rl = rec.rl.filter((t) => t > rlCutoff);
      rec.rl.push(Number(ts));
    }
    await this._putCredits(pubkey, rec, tier);
    return { ok: true, balance: rec.balance, charged: cost, dust: nextDust };
  }

  // free tier's daily allowance
  _freeDay(at) {
    return new Date(typeof at === "number" ? at : Date.now()).toISOString().slice(0, 10);
  }

  _freeResetsAt() {
    const now = new Date();
    return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  }

  _freeRow(pubkey) {
    const day = this._freeDay();
    const rows = this.sql.exec(
      "SELECT day, used FROM free_usage WHERE pubkey = ? LIMIT 1;", pubkey
    ).toArray();
    const row = rows && rows[0];
    // A row from a day that has passed is not a used-up allowance, it is
    // yesterday's — read as zero rather than migrated, so nothing has to sweep
    // the table at midnight.
    return { day, used: (row && row.day === day) ? (row.used || 0) : 0 };
  }

  _freeLimit(limit) {
    const n = Math.floor(Number(limit) || 0);
    return n > 0 && n <= 1000 ? n : 0;
  }

  _freeNetId(id) {
    return typeof id === "string" && /^[A-Za-z0-9_-]{16,64}$/.test(id) ? id : "";
  }

  _freeNetRow(id) {
    const day = this._freeDay();
    const rows = this.sql.exec(
      "SELECT day, used FROM free_net WHERE id = ? LIMIT 1;", id
    ).toArray();
    const row = rows && rows[0];
    return { day, used: (row && row.day === day) ? (row.used || 0) : 0 };
  }

  /// What is left today, without spending any of it.
  _freePeek(pubkey, limit, net, netLimit) {
    if (!/^[0-9a-f]{64}$/.test(pubkey || "")) return { error: "Invalid pubkey." };
    const cap = this._freeLimit(limit);
    if (!cap) return { error: "Invalid free limit." };
    const at = this._freeRow(pubkey);
    let left = Math.max(0, cap - at.used);
    let netLeft = null;
    const nid = this._freeNetId(net);
    const netCap = this._freeLimit(netLimit);
    if (nid && netCap) {
      const nAt = this._freeNetRow(nid);
      netLeft = Math.max(0, netCap - nAt.used);
      left = Math.min(left, netLeft);
    }
    return {
      ok: true, used: at.used, limit: cap, left: left,
      // Set only when the address is the binding one, so the reader is told which
      // wall they are against rather than a number that will not move.
      netSpent: netLeft === 0,
      resetsAt: this._freeResetsAt()
    };
  }

  /// Takes one off today's allowance, or says there is none left. The read and
  /// the write are one op precisely so two messages sent at once cannot both
  /// see the last one as available.
  _freeClaim(pubkey, limit, net, netLimit) {
    if (!/^[0-9a-f]{64}$/.test(pubkey || "")) return { error: "Invalid pubkey." };
    const cap = this._freeLimit(limit);
    if (!cap) return { error: "Invalid free limit." };
    const at = this._freeRow(pubkey);
    const resetsAt = this._freeResetsAt();
    if (at.used >= cap) {
      return { ok: false, used: at.used, limit: cap, left: 0, resetsAt: resetsAt };
    }
    // The address's own allowance, checked under the same lock.
    const nid = this._freeNetId(net);
    const netCap = this._freeLimit(netLimit);
    let netUsed = 0;
    let netDay = null;
    if (nid && netCap) {
      const nAt = this._freeNetRow(nid);
      if (nAt.used >= netCap) {
        return {
          ok: false, used: at.used, limit: cap, left: 0,
          netSpent: true, resetsAt: resetsAt
        };
      }
      netUsed = nAt.used + 1;
      netDay = nAt.day;
    }
    const used = at.used + 1;
    this.sql.exec(
      "INSERT INTO free_usage (pubkey, day, used) VALUES (?, ?, ?) " +
      "ON CONFLICT(pubkey) DO UPDATE SET day = excluded.day, used = excluded.used;",
      pubkey, at.day, used
    );
    if (nid && netCap) {
      this.sql.exec(
        "INSERT INTO free_net (id, day, used) VALUES (?, ?, ?) " +
        "ON CONFLICT(id) DO UPDATE SET day = excluded.day, used = excluded.used;",
        nid, netDay, netUsed
      );
      // Yesterday's buckets are no longer reachable — the salt folds the day in,
      // so they can never be hit again.
      this.sql.exec("DELETE FROM free_net WHERE day <> ?;", netDay);
    }
    return { ok: true, used: used, limit: cap, left: cap - used, resetsAt: resetsAt };
  }

  // Atomic claim of a paid credit invoice. The caller has already verified
  // payment; this gates the grant on a single-use claim id.
  async _claimCredits(a) {
    const invoiceId = String(a.invoiceId || "");
    const creditTo = String(a.creditTo || "").toLowerCase();
    const credits = Math.max(0, Math.floor(Number(a.credits) || 0));
    const tier = a.tier === "pro" ? "pro" : "standard";
    if (!/^[0-9a-f]{64}$/i.test(invoiceId) || !/^[0-9a-f]{64}$/.test(creditTo) || credits <= 0) {
      return { error: "Invalid claim." };
    }
    if (!this._claimOnce("credits/" + invoiceId, "credits")) {
      return { alreadyClaimed: true };
    }
    const crec = await this._getCredits(creditTo, tier);
    crec.balance = (crec.balance || 0) + credits;
    crec.totalPurchased = (crec.totalPurchased || 0) + credits;
    await this._putCredits(creditTo, crec, tier);
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

    // Bundle: grant each component item, each with its own recovery code.
    if (Array.isArray(a.bundle) && a.bundle.length) {
      const granted = [];
      for (const comp of a.bundle) {
        const cid = String((comp && comp.itemId) || "");
        const ccode = String((comp && comp.code) || "");
        if (!cid) continue;
        crec.owned[cid] = { at: Date.now(), amountSats: 0, gift: !!a.gift, code: ccode, fromBundle: itemId };
        granted.push({ itemId: cid, code: ccode });
      }
      await this._putShop(recipient, crec);
      for (const g of granted) {
        if (g.code) { try { await codePut(this.env.DB_CODES, g.code, g.itemId, recipient, Date.now()); } catch {} }
      }
      try {
        await invoicePut(this.env.DB_INVOICES, "shop", "claimed", invoiceId,
          Object.assign({ itemId, pubkey: recipient, code, bundle: granted, at: Date.now() }, a.claimData || {}));
      } catch {}
      try { await invoiceDelete(this.env.DB_INVOICES, "shop", "pending", invoiceId); } catch {}
      return { itemId, code, recipient, bundle: granted, owned: crec.owned, active: crec.active };
    }

    // Limited edition: consume the reservation and assign a numbered slot.
    let edition = null;
    let editionMax = 0;
    if (a.edition && Number(a.edition.max) > 0) {
      editionMax = Math.floor(Number(a.edition.max));
      edition = this._allocateEdition(itemId, invoiceId, editionMax);
    }

    const entry = { at: Date.now(), amountSats: Number(a.amountSats) || 0, gift: !!a.gift, code };
    if (edition) { entry.edition = edition; entry.editionMax = editionMax; }
    crec.owned[itemId] = entry;
    await this._putShop(recipient, crec);
    try { await codePut(this.env.DB_CODES, code, itemId, recipient, Date.now()); } catch {}
    try {
      await invoicePut(this.env.DB_INVOICES, "shop", "claimed", invoiceId,
        Object.assign({ itemId, pubkey: recipient, code, edition: edition || null, editionMax, at: Date.now() }, a.claimData || {}));
    } catch {}
    try { await invoiceDelete(this.env.DB_INVOICES, "shop", "pending", invoiceId); } catch {}
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
    const newCode = shopNewCode();
    toRec.owned[itemId] = { at: Date.now(), amountSats: entry.amountSats || 0, gift: true, code: newCode, transferredFrom: from };
    // Numbered editions keep their number when traded.
    if (entry.edition) { toRec.owned[itemId].edition = entry.edition; toRec.owned[itemId].editionMax = entry.editionMax || 0; }
    await this._putShop(from, fromRec);
    await this._putShop(to, toRec);
    try { await codePut(this.env.DB_CODES, newCode, itemId, to, Date.now()); } catch {}
    if (entry.code) {
      try { await codeDelete(this.env.DB_CODES, entry.code); } catch {}
    }
    return { ok: true, itemId, owned: fromRec.owned, active: fromRec.active };
  }

  async _shopRedeem(a) {
    const code = String(a.code || "");
    const user = String(a.user || "").toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(user)) return { error: "Invalid pubkey." };
    if (!SHOP_CODE_RE.test(code)) return { error: "Invalid recovery code." };
    const found = await codeGet(this.env.DB_CODES, code);
    if (!found) return { error: "Unknown recovery code.", unknown: true };
    const itemId = String(found.itemId || "");
    if (!itemId || (a.itemId != null && String(a.itemId) !== itemId)) {
      return { error: "That recovery code changed while it was being redeemed. Try again." };
    }
    const prevOwner = String(found.owner || "").toLowerCase();
    if (prevOwner === user) {
      const ownRec = await this._getShop(user);
      return { alreadyOwner: true, itemId, owned: ownRec.owned, active: ownRec.active, prevOwner };
    }
    if (prevOwner && /^[0-9a-f]{64}$/.test(prevOwner)) {
      const prevRec = await this._getShop(prevOwner);
      const held = prevRec.owned[itemId];
      if (!held || (held.code && held.code !== code)) {
        return { error: "This recovery code is no longer valid.", stale: true };
      }
      delete prevRec.owned[itemId];
      this._pruneActive(prevRec);
      await this._putShop(prevOwner, prevRec);
    }
    const rrec = await this._getShop(user);
    rrec.owned[itemId] = { at: Date.now(), amountSats: 0, gift: false, code, redeemed: true };
    await this._putShop(user, rrec);
    try { await codePut(this.env.DB_CODES, code, itemId, user, found.createdAt || Date.now()); } catch {}
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
