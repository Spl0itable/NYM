import { spamEngine } from './_spam.js';
import { verifySignedEvent, spamEngineJob } from './relay-pool.js';

const INGEST_SECRET_HEADER = 'X-Nymchat-Proxy-Secret';
const INGEST_MAX_EVENTS = 500;
const INGEST_MAX_BYTES = 2 * 1024 * 1024;
const INGEST_DEADLINE_MS = 22000;
const INGEST_HOLD_SLACK_MS = 1500;
const INGEST_DRAIN_MS = 20000;
const NO_SIGNALS = { score: 0, copies: 0 };

function json(body, status) {
  return new Response(JSON.stringify(body), { status: status || 200, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
}

async function secretAllowed(request, env) {
  const secret = String((env && env.NYMCHAT_PROXY_SECRET) || '');
  const given = String(request.headers.get(INGEST_SECRET_HEADER) || '');
  if (!secret || !given) return false;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(secret)),
    crypto.subtle.digest('SHA-256', enc.encode(given))
  ]);
  const x = new Uint8Array(a), y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function readEvents(request) {
  const declared = Number(request.headers.get('Content-Length') || 0);
  if (declared > INGEST_MAX_BYTES) return { status: 413 };
  let buf;
  try { buf = await request.arrayBuffer(); } catch { return { status: 400 }; }
  if (buf.byteLength > INGEST_MAX_BYTES) return { status: 413 };
  let body;
  try { body = JSON.parse(new TextDecoder().decode(buf)); } catch { return { status: 400 }; }
  if (!body || !Array.isArray(body.events)) return { status: 400 };
  if (body.events.length > INGEST_MAX_EVENTS) return { status: 413 };
  return { events: body.events };
}

function trackedContext(context) {
  const pending = new Set();
  const ctx = {
    waitUntil(p) {
      const q = Promise.resolve(p).catch(() => { }).finally(() => pending.delete(q));
      pending.add(q);
      if (context && typeof context.waitUntil === 'function') { try { context.waitUntil(q); } catch { } }
    }
  };
  return { ctx, pending };
}

async function drain(spam, pending, waits, until) {
  const stop = new Promise((r) => setTimeout(r, Math.max(0, until - Date.now())));
  const settled = (async () => {
    await Promise.all(waits);
    while (pending.size) await Promise.all(Array.from(pending));
  })();
  await Promise.race([settled, stop]);
  try { await spam.flush(); } catch { }
}

export async function onRequestPost(context) {
  const { request, env } = context;
  if (!(await secretAllowed(request, env))) return new Response('Not found', { status: 404 });
  const read = await readEvents(request);
  if (!read.events) return json({ error: read.status === 413 ? 'too large' : 'bad request' }, read.status);

  const start = Date.now();
  const { ctx, pending } = trackedContext(context);
  const spam = spamEngine(env, ctx);
  await spam.ready();
  if (!spam.active()) {
    spam.close();
    return json({ drop: [], held: 0, timedOut: 0, invalid: 0 });
  }
  try { spam.tick(); } catch { }

  const settings = spam.settings() || {};
  const holdMs = Math.max(0, Number(settings.holdMs) || 0);
  const deadline = start + INGEST_DEADLINE_MS;
  const drop = new Set();
  const seen = new Set();
  const waits = [];
  const backgroundWaits = [];
  let held = 0, timedOut = 0, invalid = 0;

  for (const ev of read.events) {
    if (!ev || (ev.kind !== 20000 && ev.kind !== 23333) || typeof ev.content !== 'string' || !ev.content) continue;
    if (!verifySignedEvent(ev)) { invalid++; continue; }
    if (seen.has(ev.id)) continue;
    seen.add(ev.id);
    const job = spamEngineJob(ev, ev.kind, NO_SIGNALS);
    if (!job.channel) { invalid++; continue; }
    let resolve;
    const outcome = new Promise((r) => { resolve = r; });
    backgroundWaits.push(outcome);
    let verdict;
    try {
      verdict = spam.inspect(Object.assign({
        release: () => { resolve('ok'); return true; },
        retract: () => { resolve('spam'); return true; },
        discard: () => resolve('spam')
      }, job));
    } catch {
      verdict = 'pass';
    }
    if (verdict === 'drop') { drop.add(ev.id); resolve('spam'); continue; }
    if (verdict !== 'hold') { resolve('ok'); continue; }
    held++;
    const limit = Math.min(deadline, Date.now() + holdMs + INGEST_HOLD_SLACK_MS);
    waits.push(new Promise((done) => {
      const timer = setTimeout(() => { timedOut++; done(); }, Math.max(0, limit - Date.now()));
      outcome.then((v) => { clearTimeout(timer); if (v === 'spam') drop.add(ev.id); done(); });
    }));
  }

  await Promise.all(waits);

  const result = { drop: Array.from(drop), held, timedOut, invalid };
  const bg = drain(spam, pending, backgroundWaits, Date.now() + INGEST_DRAIN_MS).finally(() => { try { spam.close(); } catch { } });
  if (context && typeof context.waitUntil === 'function') { try { context.waitUntil(bg); } catch { } }
  return json(result);
}
