import { CLIENT_CORS_HEADERS, cacheRateTake } from "./_shared.js";
import { hasD1 } from "./_d1.js";
import { verifySignedEvent, isPrivateRelayHost, spamEngineJob } from "./relay-pool.js";
import { spamEngine } from "./_spam.js";
import { filterSet, pubkeyHit } from "./_filters.js";

export const SCHEDULE_LIMITS = Object.freeze({
  minLeadSec: 30,
  maxAheadSec: 30 * 24 * 60 * 60,
  aheadSlackSec: 300,
  maxPending: 50,
  maxEvents: 260,
  maxEventBytes: 70000,
  maxItemBytes: 1000000,
  maxUserBytes: 5000000,
  maxRelays: 16,
  noteMax: 16000,
  attempts: 4,
  retrySec: 60,
  keepDoneSec: 7 * 24 * 60 * 60,
  leaseSec: 300,
  lateSec: 6 * 60 * 60,
  wrapJitterSec: 7200,
  wrapSlackSec: 120,
  addPerMinute: 30,
  runBatch: 20,
  relayTimeoutMs: 8000
});

export const SCHEDULE_DDL = [
  "CREATE TABLE IF NOT EXISTS scheduled (" +
  "pubkey TEXT NOT NULL, id TEXT NOT NULL, publish_at INTEGER NOT NULL, events TEXT NOT NULL, relays TEXT NOT NULL, " +
  "note TEXT NOT NULL DEFAULT '', bytes INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, " +
  "next_try INTEGER NOT NULL, lease_until INTEGER NOT NULL DEFAULT 0, error TEXT NOT NULL DEFAULT '', " +
  "created_at INTEGER NOT NULL, sent_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (pubkey, id))",
  "CREATE INDEX IF NOT EXISTS scheduled_due ON scheduled (status, next_try)"
];

const APP_RELAY = "wss://relay.nymchat.app";
const APP_RELAY_ONLY_KINDS = new Set([23333, 7, 30078, 24420, 24421]);
const APP_RELAY_ONLY_CHANNEL = "nymchat";
const CHANNEL_KINDS = new Set([20000, 23333]);
const ROUTES = new Set(["pub", "dep", "self", "arch"]);
const RX_ID = /^[0-9a-f]{32}$/;
const RX_HEX64 = /^[0-9a-f]{64}$/;

const tablesReady = new WeakSet();

export function scheduleDb(env) {
  if (env && hasD1(env.DB_SCHEDULE)) return env.DB_SCHEDULE;
  if (env && hasD1(env.DB_PM)) return env.DB_PM;
  return null;
}

export async function ensureScheduleTables(db) {
  if (!db || tablesReady.has(db)) return;
  await db.batch(SCHEDULE_DDL.map((s) => db.prepare(s)));
  tablesReady.add(db);
}

function nowSec() {
  return Math.floor(Date.now() / 1000);
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
  });
}

function tagValue(ev, name) {
  if (!ev || !Array.isArray(ev.tags)) return null;
  for (const t of ev.tags) if (Array.isArray(t) && t[0] === name && typeof t[1] === "string") return t[1];
  return null;
}

function wrapRecipient(ev) {
  const ps = (ev.tags || []).filter((t) => Array.isArray(t) && t[0] === "p");
  if (ps.length !== 1 || typeof ps[0][1] !== "string") return null;
  const p = ps[0][1].toLowerCase();
  return RX_HEX64.test(p) ? p : null;
}

export function isAppRelayOnly(ev) {
  if (!ev || !APP_RELAY_ONLY_KINDS.has(ev.kind)) return false;
  const name = ev.kind === 23333 ? tagValue(ev, "d") : (tagValue(ev, "g") || tagValue(ev, "d"));
  return !!name && name.toLowerCase() === APP_RELAY_ONLY_CHANNEL;
}

export function normalizeRelays(list) {
  const out = [];
  for (const raw of Array.isArray(list) ? list : []) {
    if (typeof raw !== "string" || raw.length > 256) continue;
    let u;
    try { u = new URL(raw.trim()); } catch { continue; }
    if (u.protocol !== "wss:" || u.username || u.password) continue;
    if (isPrivateRelayHost(u.hostname)) continue;
    const path = u.pathname && u.pathname !== "/" ? u.pathname.replace(/\/+$/, "") : "";
    const s = "wss://" + u.host.toLowerCase() + path;
    if (out.indexOf(s) < 0) out.push(s);
    if (out.length >= SCHEDULE_LIMITS.maxRelays) break;
  }
  return out;
}

export function validateScheduleItem(body, owner, now) {
  const L = SCHEDULE_LIMITS;
  const id = typeof body.id === "string" ? body.id.toLowerCase() : "";
  if (!RX_ID.test(id)) return { error: "Invalid id.", status: 400 };
  const at = Number(body.at);
  if (!Number.isSafeInteger(at)) return { error: "Invalid time.", status: 400 };
  if (at < now + L.minLeadSec) return { error: "That time has passed.", code: "past", status: 400 };
  if (at > now + L.maxAheadSec + L.aheadSlackSec) return { error: "You can schedule up to 30 days ahead.", code: "far", status: 400 };
  const raw = Array.isArray(body.events) ? body.events : null;
  if (!raw || !raw.length) return { error: "Nothing to send.", status: 400 };
  if (raw.length > L.maxEvents) return { error: "Too many events.", code: "big", status: 413 };
  const note = typeof body.note === "string" ? body.note : "";
  if (note.length > L.noteMax) return { error: "Note too large.", code: "big", status: 413 };
  const events = [];
  const seen = new Set();
  let bytes = note.length;
  let relayed = 0;
  for (const item of raw) {
    if (!item || typeof item !== "object") return { error: "Invalid event.", status: 400 };
    const ev = item.e;
    const r = typeof item.r === "string" ? item.r : "";
    if (!ROUTES.has(r)) return { error: "Invalid route.", status: 400 };
    if (!ev || typeof ev !== "object") return { error: "Invalid event.", status: 400 };
    const size = JSON.stringify(ev).length;
    if (size > L.maxEventBytes) return { error: "An event is too large.", code: "big", status: 413 };
    bytes += size;
    if (!verifySignedEvent(ev)) return { error: "An event is not validly signed.", status: 400 };
    if (seen.has(ev.id)) return { error: "Duplicate event.", status: 400 };
    seen.add(ev.id);
    if (CHANNEL_KINDS.has(ev.kind)) {
      if (r !== "pub") return { error: "Invalid route.", status: 400 };
      if (ev.pubkey !== owner) return { error: "Channel messages must be signed by you.", status: 403 };
      if (ev.created_at !== at) return { error: "The message must be dated at the scheduled time.", status: 400 };
    } else if (ev.kind === 1059) {
      if (ev.created_at > at || ev.created_at < at - L.wrapJitterSec - L.wrapSlackSec) {
        return { error: "A wrap is not dated near the scheduled time.", status: 400 };
      }
      const p = wrapRecipient(ev);
      if (!p) return { error: "A wrap needs exactly one recipient.", status: 400 };
      if ((r === "self" || r === "arch") && p !== owner) return { error: "Invalid route.", status: 400 };
      if (r === "dep" && p === owner) return { error: "Invalid route.", status: 400 };
      if (tagValue(ev, "d") !== null) return { error: "Invalid wrap.", status: 400 };
    } else {
      return { error: "That kind of event can't be scheduled.", status: 400 };
    }
    if (r !== "arch") relayed++;
    events.push({ e: ev, r });
  }
  if (!relayed) return { error: "Nothing to publish.", status: 400 };
  if (bytes > L.maxItemBytes) return { error: "This message is too large to schedule.", code: "big", status: 413 };
  const relays = normalizeRelays(body.relays);
  const needsOpen = events.some((x) => x.r !== "arch" && !isAppRelayOnly(x.e));
  if (needsOpen && !relays.some((u) => u !== APP_RELAY)) return { error: "No relays to publish to.", status: 400 };
  const replaces = typeof body.replaces === "string" && RX_ID.test(body.replaces.toLowerCase()) ? body.replaces.toLowerCase() : null;
  return { id, at, events, relays, note, bytes, replaces };
}

function rowView(r) {
  let count = 0;
  try { count = JSON.parse(r.events).length; } catch { count = 0; }
  return {
    id: r.id,
    at: Number(r.publish_at) || 0,
    status: r.status,
    attempts: Number(r.attempts) || 0,
    error: r.error || "",
    sentAt: Number(r.sent_at) || 0,
    note: r.note || "",
    count
  };
}

export async function handleScheduleAction(context, body, authOk) {
  const env = context.env;
  const db = scheduleDb(env);
  if (!db) return json({ error: "Scheduled messages are not configured on this server." }, 503);
  let owner = body.pubkey;
  if (!owner || !RX_HEX64.test(String(owner).toLowerCase())) return json({ error: "Invalid pubkey" }, 400);
  owner = String(owner).toLowerCase();
  if (!authOk(context, body, owner)) return json({ error: "Authentication failed" }, 401);
  await ensureScheduleTables(db);
  const now = nowSec();

  if (body.action === "schedule-list") {
    let rows = [];
    try {
      rows = (await db.prepare("SELECT id, publish_at, events, note, status, attempts, error, sent_at FROM scheduled WHERE pubkey = ? ORDER BY publish_at ASC, id ASC").bind(owner).all()).results || [];
    } catch { rows = []; }
    return json({ ok: true, now, items: rows.map(rowView) });
  }

  if (body.action === "schedule-cancel") {
    const id = typeof body.id === "string" ? body.id.toLowerCase() : "";
    if (!RX_ID.test(id)) return json({ error: "Invalid id." }, 400);
    const row = await db.prepare("SELECT status FROM scheduled WHERE pubkey = ? AND id = ?").bind(owner, id).first();
    if (!row) return json({ ok: true, removed: false, status: "gone" });
    if (row.status === "sending") return json({ ok: false, removed: false, status: "sending", error: "It is being sent right now." }, 409);
    if (row.status === "sent") return json({ ok: false, removed: false, status: "sent", error: "It was already sent." }, 409);
    const res = await db.prepare("DELETE FROM scheduled WHERE pubkey = ? AND id = ? AND status IN ('pending', 'failed')").bind(owner, id).run();
    const removed = ((res && res.meta && res.meta.changes) || 0) > 0;
    return json({ ok: removed, removed, status: removed ? "cancelled" : "sending" }, removed ? 200 : 409);
  }

  if (body.action === "schedule-add") {
    if (pubkeyHit(await filterSet(env), owner)) return json({ error: "Not allowed." }, 403);
    if (!(await cacheRateTake("schedule-add", owner, 1, SCHEDULE_LIMITS.addPerMinute, 60000))) {
      return json({ error: "Too many scheduled messages at once. Try again in a minute." }, 429);
    }
    const v = validateScheduleItem(body, owner, now);
    if (v.error) return json({ error: v.error, code: v.code || "" }, v.status);
    let replacing = null;
    if (v.replaces) {
      replacing = await db.prepare("SELECT status, bytes FROM scheduled WHERE pubkey = ? AND id = ?").bind(owner, v.replaces).first();
      if (!replacing) return json({ error: "The scheduled message to change is gone.", code: "gone" }, 404);
      if (replacing.status !== "pending" && replacing.status !== "failed") {
        return json({ error: replacing.status === "sent" ? "It was already sent." : "It is being sent right now.", code: replacing.status }, 409);
      }
    }
    const dup = await db.prepare("SELECT status FROM scheduled WHERE pubkey = ? AND id = ?").bind(owner, v.id).first();
    if (dup && v.id !== v.replaces) return json({ ok: true, id: v.id, at: v.at, duplicate: true });
    const agg = await db.prepare("SELECT COUNT(*) AS n, COALESCE(SUM(bytes), 0) AS b FROM scheduled WHERE pubkey = ? AND status IN ('pending', 'sending', 'failed')").bind(owner).first();
    let pending = Number(agg && agg.n) || 0;
    let bytes = Number(agg && agg.b) || 0;
    if (replacing) { pending--; bytes -= Number(replacing.bytes) || 0; }
    if (pending >= SCHEDULE_LIMITS.maxPending) return json({ error: "You have too many scheduled messages. Cancel one first.", code: "full" }, 429);
    if (bytes + v.bytes > SCHEDULE_LIMITS.maxUserBytes) return json({ error: "Your scheduled messages are using all their space. Cancel one first.", code: "full" }, 413);
    const stmts = [];
    if (replacing) stmts.push(db.prepare("DELETE FROM scheduled WHERE pubkey = ? AND id = ? AND status IN ('pending', 'failed')").bind(owner, v.replaces));
    stmts.push(db.prepare(
      "INSERT INTO scheduled (pubkey, id, publish_at, events, relays, note, bytes, status, attempts, next_try, lease_until, error, created_at, sent_at) " +
      "VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, 0, '', ?, 0)"
    ).bind(owner, v.id, v.at, JSON.stringify(v.events), JSON.stringify(v.relays), v.note, v.bytes, v.at, now));
    await db.batch(stmts);
    return json({ ok: true, id: v.id, at: v.at });
  }

  return json({ error: "Unknown action" }, 400);
}

function connectUrlFor(env, url, proxyHost) {
  if (url !== APP_RELAY) return url;
  const secret = env && env.NYMCHAT_PROXY_SECRET;
  if (!secret) return null;
  try {
    const u = new URL(url);
    u.searchParams.set("nymchat_proxy", secret);
    const host = String(proxyHost || env.NYMCHAT_PROXY_HOST || "web.nymchat.app").trim().toLowerCase();
    if (host) u.searchParams.set("nymchat_proxy_host", host);
    return u.toString();
  } catch {
    return null;
  }
}

function sendToRelay(connectUrl, events, timeoutMs) {
  return new Promise((resolve) => {
    const accepted = new Set();
    const answered = new Set();
    const want = new Set(events.map((e) => e.id));
    let ws = null;
    let done = false;
    let timer = null;
    const finish = () => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      try { if (ws) ws.close(); } catch { }
      resolve(accepted);
    };
    timer = setTimeout(finish, timeoutMs);
    try { ws = new WebSocket(connectUrl); } catch { finish(); return; }
    ws.addEventListener("open", () => {
      for (const ev of events) {
        try { ws.send(JSON.stringify(["EVENT", ev])); } catch { }
      }
    });
    ws.addEventListener("message", (m) => {
      let msg;
      try { msg = JSON.parse(typeof m.data === "string" ? m.data : ""); } catch { return; }
      if (!Array.isArray(msg) || msg[0] !== "OK" || typeof msg[1] !== "string" || !want.has(msg[1])) return;
      answered.add(msg[1]);
      const reason = typeof msg[3] === "string" ? msg[3] : "";
      if (msg[2] === true || /^duplicate:/i.test(reason)) accepted.add(msg[1]);
      if (answered.size >= want.size) finish();
    });
    ws.addEventListener("error", finish);
    ws.addEventListener("close", finish);
  });
}

export function relayPublisher(env, opts) {
  const o = opts || {};
  const timeoutMs = o.timeoutMs || SCHEDULE_LIMITS.relayTimeoutMs;
  return async function publish(relays, events) {
    const counts = new Map(events.map((e) => [e.id, 0]));
    const appOnly = events.filter((e) => isAppRelayOnly(e));
    const open = events.filter((e) => !isAppRelayOnly(e));
    const plan = [];
    const list = relays.slice();
    if (appOnly.length && list.indexOf(APP_RELAY) < 0) list.push(APP_RELAY);
    for (const url of list) {
      const batch = url === APP_RELAY ? appOnly.concat(open) : open;
      if (!batch.length) continue;
      const connectUrl = connectUrlFor(env, url, o.proxyHost);
      if (!connectUrl) continue;
      plan.push(sendToRelay(connectUrl, batch, timeoutMs).then((acc) => {
        for (const id of acc) counts.set(id, (counts.get(id) || 0) + 1);
      }));
    }
    await Promise.all(plan);
    return counts;
  };
}

export async function judgeChannelEvents(env, context, events, deadlineMs) {
  const dropped = new Set();
  const list = events.filter((e) => CHANNEL_KINDS.has(e.kind) && typeof e.content === "string" && e.content);
  if (!list.length) return dropped;
  const pending = new Set();
  const ctx = {
    waitUntil(p) {
      const q = Promise.resolve(p).catch(() => { }).finally(() => pending.delete(q));
      pending.add(q);
      if (context && typeof context.waitUntil === "function") { try { context.waitUntil(q); } catch { } }
    }
  };
  const spam = spamEngine(env, ctx);
  try {
    await spam.ready();
    if (!spam.active()) return dropped;
    try { spam.tick(); } catch { }
    const settings = spam.settings() || {};
    const holdMs = Math.max(0, Number(settings.holdMs) || 0);
    const limit = Date.now() + Math.min(Math.max(0, deadlineMs || 15000), holdMs + 1500);
    const waits = [];
    for (const ev of list) {
      const job = spamEngineJob(ev, ev.kind, { score: 0, copies: 0 });
      if (!job.channel) continue;
      let resolve;
      const outcome = new Promise((r) => { resolve = r; });
      let verdict;
      try {
        verdict = spam.inspect(Object.assign({
          release: () => { resolve("ok"); return true; },
          retract: () => { resolve("spam"); return true; },
          discard: () => resolve("spam")
        }, job));
      } catch {
        verdict = "pass";
      }
      if (verdict === "drop") { dropped.add(ev.id); continue; }
      if (verdict !== "hold") continue;
      waits.push(new Promise((done) => {
        const timer = setTimeout(done, Math.max(0, limit - Date.now()));
        outcome.then((v) => { clearTimeout(timer); if (v === "spam") dropped.add(ev.id); done(); });
      }));
    }
    await Promise.all(waits);
  } finally {
    try { await spam.flush(); } catch { }
    try { spam.close(); } catch { }
  }
  return dropped;
}

async function storeWraps(env, owner, events, now) {
  const db = env && hasD1(env.DB_PM) ? env.DB_PM : null;
  if (!db) return 0;
  const stmt = db.prepare("INSERT OR IGNORE INTO pm (pubkey, id, created_at, event, stored_at) VALUES (?, ?, ?, ?, ?)");
  const batch = [];
  const nowMs = now * 1000;
  for (const { e, r } of events) {
    if (e.kind !== 1059) continue;
    if (r === "self" || r === "arch") batch.push(stmt.bind(owner, e.id, Math.min(e.created_at, now), JSON.stringify(e), nowMs));
    else if (r === "dep") {
      const p = wrapRecipient(e);
      if (p && p !== owner) batch.push(stmt.bind(p, e.id, Math.min(e.created_at, now), JSON.stringify(e), nowMs));
    }
  }
  if (!batch.length) return 0;
  try {
    const res = await db.batch(batch);
    return res.reduce((n, x) => n + ((x && x.meta && x.meta.changes) || 0), 0);
  } catch {
    return 0;
  }
}

async function settle(db, row, fields) {
  const sets = Object.keys(fields).map((k) => k + " = ?");
  await db.prepare("UPDATE scheduled SET " + sets.join(", ") + " WHERE pubkey = ? AND id = ?")
    .bind(...Object.values(fields), row.pubkey, row.id).run();
}

export async function runScheduled(env, opts) {
  const o = opts || {};
  const db = scheduleDb(env);
  const summary = { due: 0, sent: 0, partial: 0, failed: 0, retry: 0, spam: 0, late: 0, purged: 0 };
  if (!db) return Object.assign(summary, { error: "no-db" });
  await ensureScheduleTables(db);
  const now = Number.isSafeInteger(o.now) ? o.now : nowSec();
  const L = SCHEDULE_LIMITS;
  const publish = o.publish || relayPublisher(env, { proxyHost: o.proxyHost });
  const judge = o.judge || ((events) => judgeChannelEvents(env, o.context, events, 15000));
  try {
    const p = await db.prepare("DELETE FROM scheduled WHERE status IN ('sent', 'failed') AND MAX(sent_at, next_try, publish_at) < ?").bind(now - L.keepDoneSec).run();
    summary.purged = (p && p.meta && p.meta.changes) || 0;
  } catch { }
  await db.prepare("UPDATE scheduled SET status = 'pending', lease_until = 0 WHERE status = 'sending' AND lease_until < ?").bind(now).run();
  const due = (await db.prepare("SELECT pubkey, id FROM scheduled WHERE status = 'pending' AND next_try <= ? ORDER BY next_try ASC LIMIT ?").bind(now, o.limit || L.runBatch).all()).results || [];
  for (const d of due) {
    const claim = await db.prepare("UPDATE scheduled SET status = 'sending', lease_until = ?, attempts = attempts + 1 WHERE pubkey = ? AND id = ? AND status = 'pending' AND next_try <= ?")
      .bind(now + L.leaseSec, d.pubkey, d.id, now).run();
    if (!((claim && claim.meta && claim.meta.changes) > 0)) continue;
    summary.due++;
    const row = await db.prepare("SELECT * FROM scheduled WHERE pubkey = ? AND id = ?").bind(d.pubkey, d.id).first();
    if (!row) continue;
    if (now > row.publish_at + L.lateSec) {
      await settle(db, row, { status: "failed", error: "late", lease_until: 0, events: "[]", bytes: 0, next_try: now });
      summary.late++;
      summary.failed++;
      continue;
    }
    let items = [];
    let relays = [];
    try { items = JSON.parse(row.events); relays = JSON.parse(row.relays); } catch { items = []; }
    const all = items.map((x) => x.e);
    const dropped = await judge(all);
    if (dropped && dropped.size) {
      await settle(db, row, { status: "failed", error: "spam", lease_until: 0, events: "[]", bytes: 0, next_try: now });
      summary.spam++;
      summary.failed++;
      continue;
    }
    const toRelay = items.filter((x) => x.r !== "arch").map((x) => x.e);
    let counts = new Map();
    try { counts = await publish(relays, toRelay); } catch { counts = new Map(); }
    await storeWraps(env, row.pubkey, items, now);
    const okAll = toRelay.every((e) => (counts.get(e.id) || 0) > 0);
    const okAny = toRelay.some((e) => (counts.get(e.id) || 0) > 0);
    const attempts = Number(row.attempts) || 1;
    if (okAll) {
      await settle(db, row, { status: "sent", error: "", lease_until: 0, events: "[]", bytes: 0, sent_at: now });
      summary.sent++;
    } else if (attempts >= L.attempts) {
      if (okAny) {
        await settle(db, row, { status: "sent", error: "partial", lease_until: 0, events: "[]", bytes: 0, sent_at: now });
        summary.partial++;
      } else {
        await settle(db, row, { status: "failed", error: "relays", lease_until: 0, events: "[]", bytes: 0, next_try: now });
        summary.failed++;
      }
    } else {
      await settle(db, row, { status: "pending", error: "retry", lease_until: 0, next_try: now + L.retrySec * Math.pow(2, attempts - 1) });
      summary.retry++;
    }
  }
  return summary;
}
