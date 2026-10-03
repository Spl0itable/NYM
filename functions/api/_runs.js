import { hasD1 } from "./_d1.js";

export var RUN_DEFAULT = 3;
export var RUN_CEILING = 10;
export var RUN_FREE = 1;
export var RUN_LIVE_MS = 45000;
export var RUN_WAITING_MS = 1800000;
export var RUN_PARKED_MS = 600000;
export var RUN_AWAITING_MS = 86400000;
export var RUN_RESULT_KEEP_MS = 2 * 3600 * 1000;
export var RUN_TURN_KEEP_MS = 90 * 86400 * 1000;
export var RUN_ROW_KEEP_MS = 86400 * 1000;
export var RUN_LOCK_LEASE_MS = 60000;
export var RUN_LABEL_CHARS = 80;
export var RUN_PROGRESS_CHARS = 200;
export var RUN_STEER_CHARS = 2000;
export var RUN_STEER_STATUS_MAX = 20;
export var RUN_RESULT_MAX_BYTES = 512 * 1024;

var RUN_DDL = [
  "CREATE TABLE IF NOT EXISTS botpm_turns (pubkey TEXT NOT NULL, asked TEXT NOT NULL, thread TEXT NOT NULL DEFAULT '', " +
  "ids TEXT NOT NULL DEFAULT '[]', at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (pubkey, asked))",
  "CREATE INDEX IF NOT EXISTS botpm_turns_at ON botpm_turns (pubkey, at)",
  "CREATE INDEX IF NOT EXISTS botpm_turns_thread ON botpm_turns (thread)",
  "CREATE TABLE IF NOT EXISTS botpm_runs (pubkey TEXT NOT NULL, asked TEXT NOT NULL, thread TEXT NOT NULL DEFAULT '', " +
  "kind TEXT NOT NULL DEFAULT 'chat', label TEXT NOT NULL DEFAULT '', progress TEXT NOT NULL DEFAULT '', " +
  "state TEXT NOT NULL DEFAULT 'running', cancel INTEGER NOT NULL DEFAULT 0, resume TEXT, " +
  "started_at INTEGER NOT NULL DEFAULT 0, beat_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (pubkey, asked))",
  "CREATE INDEX IF NOT EXISTS botpm_runs_live ON botpm_runs (pubkey, state, beat_at)",
  "CREATE TABLE IF NOT EXISTS botpm_results (pubkey TEXT NOT NULL, id TEXT NOT NULL, result TEXT NOT NULL, " +
  "at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (pubkey, id))",
  "CREATE INDEX IF NOT EXISTS botpm_results_at ON botpm_results (at)",
  "CREATE TABLE IF NOT EXISTS botpm_steer (pubkey TEXT NOT NULL, asked TEXT NOT NULL, id TEXT NOT NULL, " +
  "text TEXT NOT NULL, at INTEGER NOT NULL DEFAULT 0, applied_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (pubkey, asked, id))",
  "CREATE TABLE IF NOT EXISTS botpm_locks (pubkey TEXT NOT NULL, lock TEXT NOT NULL, asked TEXT NOT NULL, " +
  "beat_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (pubkey, lock))",
  "CREATE TABLE IF NOT EXISTS botpm_summary (pubkey TEXT NOT NULL, thread TEXT NOT NULL, text TEXT NOT NULL, " +
  "upto_at INTEGER NOT NULL DEFAULT 0, at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (pubkey, thread))"
];

async function runsRepair(db) {
  for (var i = 0; i < RUN_DDL.length; i++) {
    try { await db.prepare(RUN_DDL[i]).run(); } catch (e) { }
  }
}

async function withTables(db, fn, fallback) {
  if (!hasD1(db)) return fallback;
  try {
    return await fn();
  } catch (e) {
    await runsRepair(db);
    try { return await fn(); } catch (e2) { return fallback; }
  }
}

function parseIds(raw) {
  try {
    var v = JSON.parse(raw);
    return Array.isArray(v) ? v.filter(function (x) { return typeof x === "string" && /^[0-9a-f]{64}$/i.test(x); }) : [];
  } catch (e) { return []; }
}

export function runMaxRuns(raw) {
  var n = Number(raw);
  if (!Number.isInteger(n) || n < 1) return RUN_DEFAULT;
  return Math.min(n, RUN_CEILING);
}

export function runLabel(text) {
  var s = String(text || "").replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069]/g, " ")
    .replace(/\s+/g, " ").trim();
  return s.length > RUN_LABEL_CHARS ? s.slice(0, RUN_LABEL_CHARS - 1).trimEnd() + "…" : s;
}

function clipLine(s) {
  var t = String(s || "").replace(/\s+/g, " ").trim();
  return t.length > RUN_PROGRESS_CHARS ? t.slice(0, RUN_PROGRESS_CHARS - 1) + "…" : t;
}

var STAGE_LINES = {
  reading: "reading your message",
  opening: "opening your message",
  sealing: "sealing the reply"
};
var RESEARCH_LINES = {
  plan: "planning",
  planned: "planned the searches",
  search: "searching",
  read: "reading pages",
  note: "taking notes",
  write: "writing the report",
  pause: "pausing to carry on",
  resume: "carrying on"
};
var LEAD_LINES = {
  split: "splitting the question",
  plan: "planning the work",
  assigned: "handing out the work",
  reconcile: "comparing the findings",
  contradictions: "checking contradictions",
  review: "reviewing the work",
  "send-back": "sending work back",
  write: "writing the report",
  approval: "waiting for your approval",
  tool: "using its tools",
  pause: "pausing to carry on",
  resume: "carrying on"
};

export function runProgressLine(state, step) {
  var st = state || {};
  var s = step || {};
  var line = null;
  switch (s.kind) {
    case "stage":
      line = STAGE_LINES[s.stage] || null;
      break;
    case "routing":
      if (Number(s.team) > 0) {
        st.teamWorkers = Math.floor(Number(s.team));
        st.teamDone = {};
        line = "team of " + st.teamWorkers + " workers starting";
      } else {
        line = s.resumed ? "carrying on" : "started";
      }
      break;
    case "model":
      if (Number(s.call) > 0 && Number(s.of) > 0) line = "model step " + Math.floor(Number(s.call)) + " of " + Math.floor(Number(s.of));
      else line = "waiting for the model";
      break;
    case "route":
      line = "writing the reply";
      break;
    case "effort":
      line = s.stage === "planning" ? "planning the answer" : (s.stage === "checking" ? "checking the answer" : null);
      break;
    case "search":
      line = "searching the web";
      break;
    case "page":
      line = "reading a linked page";
      break;
    case "vision":
      line = "looking at the pictures";
      break;
    case "tool":
      line = s.connector ? "using a connector" : "using repository tools";
      break;
    case "server-run":
      line = s.stage === "done" ? "a server run finished" : "running code on a server";
      break;
    case "research": {
      var what = RESEARCH_LINES[s.stage];
      if (!what) break;
      var round = Number(s.round) > 0 && Number(s.of) > 0 ? "round " + Math.floor(Number(s.round)) + " of " + Math.floor(Number(s.of)) + ", " : "";
      if (Number(s.round) > 0) st.researchRound = round;
      if (s.stage === "read" || s.stage === "search") round = st.researchRound || "";
      line = "research: " + round + what;
      break;
    }
    case "team": {
      var lane = Math.floor(Number(s.lane) || 0);
      if (!st.teamDone) st.teamDone = {};
      if (lane > 0 && s.stage === "done") st.teamDone[lane] = true;
      var total = st.teamWorkers || Object.keys(st.teamDone).length;
      var done = Object.keys(st.teamDone).length;
      var lead = lane === 0 ? (LEAD_LINES[s.stage] || null) : null;
      if (lead) st.teamLead = lead;
      line = "team: " + done + " of " + total + " workers done" + (st.teamLead ? "; lead is " + st.teamLead : "");
      break;
    }
    case "steer":
      line = "applied your update";
      break;
    case "plan": {
      var items = Array.isArray(s.items) ? s.items : [];
      if (!items.length) break;
      var doneN = items.filter(function (it) { return it && it.state === "done"; }).length;
      line = "plan: " + doneN + " of " + items.length + " steps done";
      break;
    }
    case "waiting-repo":
      line = "waiting for another task on this repository";
      break;
    case "approval":
      line = "waiting for your approval";
      break;
    default:
      line = null;
  }
  return line == null ? null : clipLine(line);
}

export function runHistoryPlan(legacy, rows, thread, max) {
  var cap = Math.max(1, Math.floor(Number(max) || 40));
  var sorted = (rows || []).slice().sort(function (a, b) { return (a.at || 0) - (b.at || 0); });
  var want = String(thread || "");
  var covered = {};
  var mine = [];
  for (var i = 0; i < sorted.length; i++) {
    var ids = parseIds(sorted[i].ids);
    for (var j = 0; j < ids.length; j++) covered[ids[j]] = true;
    var inScope = thread == null ? true : (want ? (sorted[i].thread === want || sorted[i].asked === want) : !sorted[i].thread);
    if (inScope) mine.push.apply(mine, ids);
  }
  var out = [];
  var seen = {};
  var push = function (id) {
    if (seen[id]) return;
    seen[id] = true;
    out.push(id);
  };
  (legacy || []).forEach(function (id) { if (!covered[id]) push(id); });
  mine.forEach(push);
  return out.length > cap ? out.slice(out.length - cap) : out;
}

export function runToolBatches(calls, isReadOnly, width) {
  var w = Math.max(1, Math.floor(Number(width) || 4));
  var out = [];
  var cur = null;
  for (var i = 0; i < (calls || []).length; i++) {
    var c = calls[i];
    if (isReadOnly(c)) {
      if (!cur || cur.length >= w) { cur = []; out.push(cur); }
      cur.push(c);
    } else {
      cur = null;
      out.push([c]);
    }
  }
  return out;
}

export async function runBatched(calls, isReadOnly, width, exec) {
  var results = new Array(calls.length);
  var batches = runToolBatches(calls.map(function (c, i) { return { c: c, i: i }; }), function (x) { return isReadOnly(x.c); }, width);
  for (var b = 0; b < batches.length; b++) {
    var batch = batches[b];
    var outs = await Promise.all(batch.map(function (x) { return exec(x.c, x.i); }));
    for (var k = 0; k < batch.length; k++) results[batch[k].i] = outs[k];
  }
  return results;
}

export function runRepoLockKey(cfg) {
  var c = cfg || {};
  return [String(c.provider || ""), String(c.host || ""), String(c.repo || "").toLowerCase(), String(c.branch || "")].join("|").slice(0, 400);
}

export async function runLockTake(db, pk, lock, asked, now) {
  var at = now || Date.now();
  return withTables(db, async function () {
    await db.prepare(
      "INSERT INTO botpm_locks (pubkey, lock, asked, beat_at) VALUES (?, ?, ?, ?) " +
      "ON CONFLICT(pubkey, lock) DO UPDATE SET asked = excluded.asked, beat_at = excluded.beat_at " +
      "WHERE botpm_locks.asked = excluded.asked OR botpm_locks.beat_at < ?"
    ).bind(pk, lock, asked, at, at - RUN_LOCK_LEASE_MS).run();
    var row = await db.prepare("SELECT asked FROM botpm_locks WHERE pubkey = ? AND lock = ?").bind(pk, lock).first();
    if (!row || row.asked === asked) return { ok: true };
    return { ok: false, holder: row.asked };
  }, { ok: true });
}

export async function runLockBeat(db, pk, asked, now) {
  return withTables(db, async function () {
    await db.prepare("UPDATE botpm_locks SET beat_at = ? WHERE pubkey = ? AND asked = ?").bind(now || Date.now(), pk, asked).run();
    return true;
  }, false);
}

export async function runLockDrop(db, pk, lock, asked) {
  return withTables(db, async function () {
    if (lock) await db.prepare("DELETE FROM botpm_locks WHERE pubkey = ? AND lock = ? AND asked = ?").bind(pk, lock, asked).run();
    else await db.prepare("DELETE FROM botpm_locks WHERE pubkey = ? AND asked = ?").bind(pk, asked).run();
    return true;
  }, false);
}

export async function runTurnsRecent(db, pk, limit) {
  return withTables(db, async function () {
    var rs = await db.prepare("SELECT asked, thread, ids, at FROM botpm_turns WHERE pubkey = ? ORDER BY at DESC LIMIT ?")
      .bind(pk, limit || 120).all();
    return (rs && rs.results) || [];
  }, []);
}

export async function runTurnsThread(db, pk, thread, limit) {
  return withTables(db, async function () {
    var rs = await db.prepare("SELECT asked, thread, ids, at FROM botpm_turns WHERE pubkey = ? AND (thread = ? OR asked = ?) ORDER BY at DESC LIMIT ?")
      .bind(pk, thread || "", thread || "\u0000", limit || 200).all();
    return (rs && rs.results) || [];
  }, []);
}

export async function runThreadHolders(db, pk, thread) {
  if (!thread) return { mine: false, other: false };
  return withTables(db, async function () {
    var mine = await db.prepare("SELECT 1 AS x FROM botpm_turns WHERE pubkey = ? AND (thread = ? OR asked = ?) LIMIT 1")
      .bind(pk, thread, thread).first();
    var other = await db.prepare("SELECT 1 AS x FROM botpm_turns WHERE thread = ? AND pubkey != ? LIMIT 1")
      .bind(thread, pk).first();
    return { mine: !!mine, other: !!other };
  }, { mine: false, other: false });
}

export async function runTurnsCopy(db, pk, rows) {
  if (!rows || !rows.length) return false;
  return withTables(db, async function () {
    await db.batch(rows.map(function (r) {
      return db.prepare("INSERT OR IGNORE INTO botpm_turns (pubkey, asked, thread, ids, at) VALUES (?, ?, ?, ?, ?)")
        .bind(pk, r.asked, r.thread || "", typeof r.ids === "string" ? r.ids : JSON.stringify(r.ids || []), r.at || 0);
    }));
    return true;
  }, false);
}

export async function runTurnAdd(db, pk, asked, thread, ids, at) {
  return withTables(db, async function () {
    await db.prepare(
      "INSERT INTO botpm_turns (pubkey, asked, thread, ids, at) VALUES (?, ?, ?, ?, ?) " +
      "ON CONFLICT(pubkey, asked) DO UPDATE SET ids = excluded.ids, thread = excluded.thread"
    ).bind(pk, asked, thread || "", JSON.stringify(ids || []), at || Date.now()).run();
    return true;
  }, false);
}

export async function runWrapsPrune(db, wrapsPk, pk, keepIds, now) {
  var keep = (keepIds || []).filter(function (x) { return typeof x === "string"; }).slice(0, 60);
  var ph = keep.map(function () { return "?"; }).join(",");
  return withTables(db, async function () {
    var sql = "DELETE FROM botpm_wraps WHERE pubkey = ? AND stored_at < ?" +
      (keep.length ? " AND id NOT IN (" + ph + ")" : "") +
      " AND id NOT IN (SELECT j.value FROM (SELECT ids FROM botpm_turns WHERE pubkey = ? ORDER BY at DESC LIMIT 200) t, json_each(t.ids) j)";
    var st = db.prepare(sql);
    await st.bind.apply(st, [wrapsPk, (now || Date.now()) - 600000].concat(keep, [pk])).run();
    return true;
  }, false);
}

export async function runResultPut(db, pk, keys, result, at) {
  var encoded;
  try { encoded = JSON.stringify(result); } catch (e) { return false; }
  if (!encoded || encoded.length > RUN_RESULT_MAX_BYTES) return false;
  var ids = (keys || []).filter(Boolean);
  if (!ids.length) return false;
  return withTables(db, async function () {
    await db.batch(ids.map(function (k) {
      return db.prepare("INSERT INTO botpm_results (pubkey, id, result, at) VALUES (?, ?, ?, ?) " +
        "ON CONFLICT(pubkey, id) DO UPDATE SET result = excluded.result, at = excluded.at").bind(pk, k, encoded, at || Date.now());
    }));
    return true;
  }, false);
}

export async function runResultGet(db, pk, key) {
  return withTables(db, async function () {
    var row = await db.prepare("SELECT result FROM botpm_results WHERE pubkey = ? AND id = ?").bind(pk, key).first();
    if (!row) return null;
    try { return JSON.parse(row.result); } catch (e) { return null; }
  }, null);
}

export async function runResultDrop(db, pk, key) {
  var k = String(key || "");
  if (!k) return false;
  return withTables(db, async function () {
    if (k.slice(-1) === ":") await db.prepare("DELETE FROM botpm_results WHERE pubkey = ? AND id LIKE ?").bind(pk, k + "%").run();
    else await db.prepare("DELETE FROM botpm_results WHERE pubkey = ? AND id = ?").bind(pk, k).run();
    return true;
  }, false);
}

var RUN_COLS = "asked, thread, kind, label, progress, state, cancel, resume, started_at, beat_at";

export async function runGet(db, pk, asked) {
  return withTables(db, async function () {
    return await db.prepare("SELECT " + RUN_COLS + " FROM botpm_runs WHERE pubkey = ? AND asked = ?").bind(pk, asked).first();
  }, null);
}

export async function runByResume(db, pk, token) {
  return withTables(db, async function () {
    return await db.prepare("SELECT " + RUN_COLS + " FROM botpm_runs WHERE pubkey = ? AND resume = ?").bind(pk, token).first();
  }, null);
}

export async function runCountLive(db, pk, now) {
  return withTables(db, async function () {
    var row = await db.prepare("SELECT COUNT(*) AS n FROM botpm_runs WHERE pubkey = ? AND state = 'running' AND beat_at > ?")
      .bind(pk, (now || Date.now()) - RUN_LIVE_MS).first();
    return row ? Number(row.n) || 0 : 0;
  }, 0);
}

export async function runStart(db, pk, run, limit, now) {
  var at = now || Date.now();
  return withTables(db, async function () {
    var res = await db.prepare(
      "INSERT OR IGNORE INTO botpm_runs (pubkey, asked, thread, kind, label, progress, state, cancel, resume, started_at, beat_at) " +
      "SELECT ?, ?, ?, ?, ?, ?, 'running', 0, NULL, ?, ? " +
      "WHERE (SELECT COUNT(*) FROM botpm_runs WHERE pubkey = ? AND state = 'running' AND beat_at > ?) < ?"
    ).bind(pk, run.asked, run.thread || "", run.kind || "chat", run.label || "", run.progress || "", at, at,
      pk, at - RUN_LIVE_MS, limit).run();
    var changed = res && res.meta ? Number(res.meta.changes) || 0 : 0;
    if (changed > 0) return { ok: true };
    var row = await db.prepare("SELECT state, cancel FROM botpm_runs WHERE pubkey = ? AND asked = ?").bind(pk, run.asked).first();
    if (row) {
      await runResumeRow(db, pk, run, at);
      return { ok: true, existing: true, cancel: !!row.cancel };
    }
    return { ok: false };
  }, { ok: true, unavailable: true });
}

async function runResumeRow(db, pk, run, at) {
  await db.prepare(
    "UPDATE botpm_runs SET state = 'running', beat_at = ?, kind = ?, progress = ?, " +
    "label = CASE WHEN label = '' THEN ? ELSE label END, thread = CASE WHEN thread = '' THEN ? ELSE thread END, " +
    "started_at = CASE WHEN started_at = 0 THEN ? ELSE started_at END WHERE pubkey = ? AND asked = ?"
  ).bind(at, run.kind || "chat", run.progress || "", run.label || "", run.thread || "", at, pk, run.asked).run();
}

export async function runContinue(db, pk, run, now) {
  var at = now || Date.now();
  return withTables(db, async function () {
    var row = await db.prepare("SELECT state FROM botpm_runs WHERE pubkey = ? AND asked = ?").bind(pk, run.asked).first();
    if (row) {
      await runResumeRow(db, pk, run, at);
      return { ok: true };
    }
    await db.prepare(
      "INSERT OR IGNORE INTO botpm_runs (pubkey, asked, thread, kind, label, progress, state, cancel, resume, started_at, beat_at) " +
      "VALUES (?, ?, ?, ?, ?, ?, 'running', 0, NULL, ?, ?)"
    ).bind(pk, run.asked, run.thread || "", run.kind || "chat", run.label || "", run.progress || "", at, at).run();
    return { ok: true };
  }, { ok: true, unavailable: true });
}

export async function runBeat(db, pk, asked, progress, now) {
  return withTables(db, async function () {
    if (progress != null) {
      await db.prepare("UPDATE botpm_runs SET beat_at = ?, progress = ? WHERE pubkey = ? AND asked = ? AND state = 'running'")
        .bind(now || Date.now(), progress, pk, asked).run();
    } else {
      await db.prepare("UPDATE botpm_runs SET beat_at = ? WHERE pubkey = ? AND asked = ? AND state = 'running'")
        .bind(now || Date.now(), pk, asked).run();
    }
    return true;
  }, false);
}

export async function runEnd(db, pk, asked, state, resume, progress, now) {
  return withTables(db, async function () {
    await db.prepare("UPDATE botpm_runs SET state = ?, resume = ?, beat_at = ?, progress = COALESCE(?, progress) WHERE pubkey = ? AND asked = ?")
      .bind(state, resume || null, now || Date.now(), progress == null ? null : progress, pk, asked).run();
    return true;
  }, false);
}

export async function runCancelFlag(db, pk, asked, now) {
  var at = now || Date.now();
  return withTables(db, async function () {
    var row = await db.prepare("SELECT state FROM botpm_runs WHERE pubkey = ? AND asked = ?").bind(pk, asked).first();
    if (!row) {
      await db.prepare(
        "INSERT OR IGNORE INTO botpm_runs (pubkey, asked, state, cancel, started_at, beat_at) VALUES (?, ?, 'pending', 1, 0, ?)"
      ).bind(pk, asked, at).run();
      return "pending";
    }
    await db.prepare("UPDATE botpm_runs SET cancel = 1 WHERE pubkey = ? AND asked = ?").bind(pk, asked).run();
    return row.state;
  }, null);
}

export async function runCanceled(db, pk, asked) {
  return withTables(db, async function () {
    var row = await db.prepare("SELECT cancel FROM botpm_runs WHERE pubkey = ? AND asked = ?").bind(pk, asked).first();
    return !!(row && row.cancel);
  }, false);
}

export async function runLive(db, pk, thread, exclude, now, limit) {
  var at = now || Date.now();
  return withTables(db, async function () {
    var rs = await db.prepare(
      "SELECT " + RUN_COLS + " FROM botpm_runs WHERE pubkey = ? AND thread = ? AND asked != ? AND cancel = 0 AND (" +
      "(state = 'running' AND beat_at > ?) OR (state = 'waiting' AND beat_at > ?) OR (state = 'parked' AND beat_at > ?) OR (state = 'awaiting' AND beat_at > ?)) " +
      "ORDER BY started_at LIMIT ?"
    ).bind(pk, thread || "", exclude || "", at - RUN_LIVE_MS, at - RUN_WAITING_MS, at - RUN_PARKED_MS, at - RUN_AWAITING_MS, limit || 8).all();
    return (rs && rs.results) || [];
  }, []);
}

export async function runListRecent(db, pk, now, limit) {
  var at = now || Date.now();
  return withTables(db, async function () {
    var rs = await db.prepare(
      "SELECT " + RUN_COLS + " FROM botpm_runs WHERE pubkey = ? AND ((beat_at > ? AND state IN ('running', 'parked', 'waiting')) " +
      "OR (beat_at > ? AND state = 'awaiting')) ORDER BY started_at DESC LIMIT ?"
    ).bind(pk, at - 3600000, at - RUN_AWAITING_MS, limit || 20).all();
    return (rs && rs.results) || [];
  }, []);
}

export async function runListSince(db, pk, since, limit) {
  return withTables(db, async function () {
    var rs = await db.prepare(
      "SELECT " + RUN_COLS + " FROM botpm_runs WHERE pubkey = ? AND beat_at > ? AND (state IN ('done', 'stopped', 'failed', 'parked', 'waiting', 'awaiting', 'expired') OR cancel = 1) " +
      "AND state != 'pending' ORDER BY beat_at DESC LIMIT ?"
    ).bind(pk, Number(since) || 0, limit || 50).all();
    return (rs && rs.results) || [];
  }, []);
}

export async function runSteerAdd(db, pk, asked, id, text, now) {
  return withTables(db, async function () {
    await db.prepare("INSERT INTO botpm_steer (pubkey, asked, id, text, at, applied_at) VALUES (?, ?, ?, ?, ?, 0)")
      .bind(pk, asked, id, text, now || Date.now()).run();
    return true;
  }, false);
}

export async function runSteerList(db, pk, asked) {
  return withTables(db, async function () {
    var rs = await db.prepare("SELECT id, text, at, applied_at FROM botpm_steer WHERE pubkey = ? AND asked = ? ORDER BY at LIMIT 20")
      .bind(pk, asked).all();
    return (rs && rs.results) || [];
  }, []);
}

export async function runSteerMark(db, pk, asked, ids, now) {
  if (!ids || !ids.length) return false;
  return withTables(db, async function () {
    await db.batch(ids.map(function (id) {
      return db.prepare("UPDATE botpm_steer SET applied_at = ? WHERE pubkey = ? AND asked = ? AND id = ? AND applied_at = 0")
        .bind(now || Date.now(), pk, asked, id);
    }));
    return true;
  }, false);
}

export async function runSteerMiss(db, pk, asked, ids, now) {
  if (!ids || !ids.length) return false;
  return withTables(db, async function () {
    await db.batch(ids.map(function (id) {
      return db.prepare("UPDATE botpm_steer SET applied_at = ? WHERE pubkey = ? AND asked = ? AND id = ? AND applied_at = 0")
        .bind(-(now || Date.now()), pk, asked, id);
    }));
    return true;
  }, false);
}

export async function runSteerStatus(db, pk, ids) {
  var want = (ids || []).slice(0, RUN_STEER_STATUS_MAX);
  var out = {};
  want.forEach(function (id) { out[id] = "unknown"; });
  if (!want.length) return out;
  return withTables(db, async function () {
    var st = db.prepare(
      "SELECT s.id AS id, s.applied_at AS applied_at, r.state AS state, r.cancel AS cancel FROM botpm_steer s " +
      "LEFT JOIN botpm_runs r ON r.pubkey = s.pubkey AND r.asked = s.asked WHERE s.pubkey = ? AND s.id IN (" +
      want.map(function () { return "?"; }).join(", ") + ")"
    );
    var rs = await st.bind.apply(st, [pk].concat(want)).all();
    ((rs && rs.results) || []).forEach(function (r) {
      var applied = Number(r.applied_at) || 0;
      if (applied > 0) out[r.id] = "applied";
      else if (applied < 0 || (r.state === "done" && !Number(r.cancel))) out[r.id] = "missed";
      else out[r.id] = "pending";
    });
    return out;
  }, out);
}

export async function runSummaryGet(db, pk, thread) {
  return withTables(db, async function () {
    return await db.prepare("SELECT text, upto_at FROM botpm_summary WHERE pubkey = ? AND thread = ?").bind(pk, thread || "").first();
  }, null);
}

export async function runSummaryPut(db, pk, thread, text, uptoAt, now) {
  return withTables(db, async function () {
    await db.prepare(
      "INSERT INTO botpm_summary (pubkey, thread, text, upto_at, at) VALUES (?, ?, ?, ?, ?) " +
      "ON CONFLICT(pubkey, thread) DO UPDATE SET text = excluded.text, upto_at = excluded.upto_at, at = excluded.at " +
      "WHERE excluded.upto_at > botpm_summary.upto_at"
    ).bind(pk, thread || "", text, uptoAt || 0, now || Date.now()).run();
    return true;
  }, false);
}

export async function runForget(db, pk) {
  return withTables(db, async function () {
    await db.batch([
      db.prepare("DELETE FROM botpm_turns WHERE pubkey = ?").bind(pk),
      db.prepare("DELETE FROM botpm_results WHERE pubkey = ?").bind(pk),
      db.prepare("DELETE FROM botpm_steer WHERE pubkey = ?").bind(pk),
      db.prepare("DELETE FROM botpm_summary WHERE pubkey = ?").bind(pk),
      db.prepare("DELETE FROM botpm_runs WHERE pubkey = ? AND state != 'running'").bind(pk)
    ]);
    return true;
  }, false);
}

export async function runSweep(db, now, limit) {
  var at = now || Date.now();
  var n = limit || 500;
  return withTables(db, async function () {
    await db.batch([
      db.prepare("DELETE FROM botpm_turns WHERE rowid IN (SELECT rowid FROM botpm_turns WHERE at < ? LIMIT ?)").bind(at - RUN_TURN_KEEP_MS, n),
      db.prepare("DELETE FROM botpm_results WHERE rowid IN (SELECT rowid FROM botpm_results WHERE at < ? LIMIT ?)").bind(at - RUN_RESULT_KEEP_MS, n),
      db.prepare("DELETE FROM botpm_runs WHERE rowid IN (SELECT rowid FROM botpm_runs WHERE beat_at < ? LIMIT ?)").bind(at - RUN_ROW_KEEP_MS, n),
      db.prepare("DELETE FROM botpm_steer WHERE rowid IN (SELECT rowid FROM botpm_steer WHERE (applied_at < 0 AND applied_at > ?) OR (applied_at >= 0 AND at < ?) LIMIT ?)")
        .bind(-(at - RUN_RESULT_KEEP_MS), at - RUN_ROW_KEEP_MS, n),
      db.prepare("DELETE FROM botpm_locks WHERE beat_at < ?").bind(at - RUN_ROW_KEEP_MS),
      db.prepare("DELETE FROM botpm_summary WHERE rowid IN (SELECT rowid FROM botpm_summary WHERE at < ? LIMIT ?)").bind(at - RUN_TURN_KEEP_MS, n)
    ]);
    return true;
  }, false);
}
