import { hasD1, replica } from './_d1.js';
import { verifyBadge, authorityPubkey } from './_attest.js';

export const SPAM_DDL = [
  "CREATE TABLE IF NOT EXISTS spam_config (key TEXT PRIMARY KEY, value TEXT)",
  "CREATE TABLE IF NOT EXISTS spam_events (id TEXT PRIMARY KEY, pubkey TEXT NOT NULL, nym TEXT, channel TEXT, kind INTEGER, " +
  "content TEXT, sim_key INTEGER NOT NULL, b0 INTEGER, b1 INTEGER, b2 INTEGER, b3 INTEGER, created_at INTEGER NOT NULL, " +
  "seen_at INTEGER NOT NULL, verdict TEXT NOT NULL, confidence REAL NOT NULL DEFAULT 0, category TEXT, reason TEXT, " +
  "model TEXT, action TEXT, source TEXT, local_score INTEGER NOT NULL DEFAULT 0, nym_key TEXT, lang TEXT, badge TEXT)",
  "CREATE INDEX IF NOT EXISTS spam_events_seen ON spam_events (seen_at)",
  "CREATE INDEX IF NOT EXISTS spam_events_pubkey ON spam_events (pubkey, seen_at)",
  "CREATE INDEX IF NOT EXISTS spam_events_sim ON spam_events (sim_key, seen_at)",
  "CREATE INDEX IF NOT EXISTS spam_events_b0 ON spam_events (b0, seen_at)",
  "CREATE INDEX IF NOT EXISTS spam_events_b1 ON spam_events (b1, seen_at)",
  "CREATE INDEX IF NOT EXISTS spam_events_b2 ON spam_events (b2, seen_at)",
  "CREATE INDEX IF NOT EXISTS spam_events_b3 ON spam_events (b3, seen_at)",
  "ALTER TABLE spam_events ADD COLUMN nym_key TEXT",
  "ALTER TABLE spam_events ADD COLUMN lang TEXT",
  "ALTER TABLE spam_events ADD COLUMN badge TEXT",
  "CREATE INDEX IF NOT EXISTS spam_events_nym ON spam_events (nym_key, seen_at)",
  "CREATE TABLE IF NOT EXISTS spam_pubkeys (pubkey TEXT PRIMARY KEY, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, " +
  "audits INTEGER NOT NULL DEFAULT 0, spam INTEGER NOT NULL DEFAULT 0, ham INTEGER NOT NULL DEFAULT 0, strikes INTEGER NOT NULL DEFAULT 0, " +
  "score REAL NOT NULL DEFAULT 0, channels TEXT, nyms TEXT, last_reason TEXT, muted_until INTEGER NOT NULL DEFAULT 0, " +
  "cleared_at INTEGER NOT NULL DEFAULT 0, cleared_by TEXT)",
  "CREATE INDEX IF NOT EXISTS spam_pubkeys_score ON spam_pubkeys (score)",
  "CREATE INDEX IF NOT EXISTS spam_pubkeys_last ON spam_pubkeys (last_seen)"
];

export const SPAM_SETTINGS_KEY = "settings";
export const SPAM_ACTOR = "ai-spam";
export const DEFAULT_SPAM_MODEL = "@cf/qwen/qwen3-30b-a3b-fp8";
const NO_THINK_SUFFIX = "\n\n/no_think";

export const BUILTIN_EXEMPT_PUBKEYS = [
  "d49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df",
  "fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2"
];

const HEX64 = /^[0-9a-f]{64}$/;
const SETTINGS_REFRESH_MS = 60000;
const SIMILAR_WINDOW_MS = 48 * 3600000;
const EXACT_CACHE_MS = 6 * 3600000;
const EXACT_CACHE_MAX = 4000;
const SEEN_MAX = 20000;
const MUTED_MAX = 5000;
const MAX_CONCURRENT = 2;
const MAX_QUEUE = 200;
let RATE_LIMIT_COOLDOWN_MS = 20000;
export function _setRateLimitCooldownMs(ms) { RATE_LIMIT_COOLDOWN_MS = ms; }
const CONTENT_MAX = 1200;
const LIST_CAP = 12;
const MIN_REUSE_TOKENS = 5;
const NYM_STEM_LEN = 5;
const GENERIC_NYMS = new Set(["anon", "anonymous", "user", "guest", "nym", "null", "none", "test"]);
const LEET = { "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "$": "s", "@": "a", "|": "l", "!": "i" };

export function defaultSpamSettings(env) {
  return {
    enabled: false,
    model: (env && typeof env.SPAM_MODEL === "string" && env.SPAM_MODEL.trim()) || DEFAULT_SPAM_MODEL,
    auditScope: "all",
    auditBudgetPerMinute: 60,
    autoEnforce: false,
    minConfidence: 0.9,
    strikesToMute: 2,
    campaignCopies: 3,
    muteHours: 24,
    blockEvents: true,
    mode: "shadow",
    holdMs: 5000,
    exemptPubkeys: []
  };
}

function clampNum(v, lo, hi, fallback) {
  const n = Number(v);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(lo, Math.min(hi, n));
}

export function normalizeSpamSettings(input, base) {
  const out = Object.assign({}, base, { exemptPubkeys: Array.from(base.exemptPubkeys || []) });
  if (!input || typeof input !== "object") return out;
  if (typeof input.enabled === "boolean") out.enabled = input.enabled;
  if (typeof input.model === "string" && input.model.trim()) out.model = input.model.trim().slice(0, 120);
  if (input.auditScope === "all" || input.auditScope === "flagged") out.auditScope = input.auditScope;
  if (input.auditBudgetPerMinute != null) out.auditBudgetPerMinute = Math.round(clampNum(input.auditBudgetPerMinute, 1, 600, out.auditBudgetPerMinute));
  if (typeof input.autoEnforce === "boolean") out.autoEnforce = input.autoEnforce;
  if (input.minConfidence != null) {
    const c = Number(input.minConfidence);
    if (Number.isFinite(c)) out.minConfidence = clampNum(c > 1 ? c / 100 : c, 0.5, 1, out.minConfidence);
  }
  if (input.strikesToMute != null) out.strikesToMute = Math.round(clampNum(input.strikesToMute, 1, 20, out.strikesToMute));
  if (input.campaignCopies != null) out.campaignCopies = Math.round(clampNum(input.campaignCopies, 2, 50, out.campaignCopies));
  if (input.muteHours != null) out.muteHours = clampNum(input.muteHours, 1, 24 * 365, out.muteHours);
  if (typeof input.blockEvents === "boolean") out.blockEvents = input.blockEvents;
  if (input.mode === "reject" || input.mode === "shadow") out.mode = input.mode;
  if (input.holdMs != null) out.holdMs = Math.round(clampNum(input.holdMs, 0, 15000, out.holdMs));
  if (Array.isArray(input.exemptPubkeys)) {
    const set = new Set();
    for (const p of input.exemptPubkeys) {
      const v = String(p || "").trim().toLowerCase();
      if (HEX64.test(v)) set.add(v);
    }
    out.exemptPubkeys = Array.from(set).slice(0, 500);
  }
  return out;
}

export function isExemptPubkey(settings, pubkey) {
  if (typeof pubkey !== "string") return false;
  const pk = pubkey.toLowerCase();
  if (BUILTIN_EXEMPT_PUBKEYS.includes(pk)) return true;
  return !!(settings && Array.isArray(settings.exemptPubkeys) && settings.exemptPubkeys.includes(pk));
}

export function hash32(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

export function spamTokens(content) {
  if (typeof content !== "string") return [];
  const out = [];
  for (let w of content.toLowerCase().split(/\s+/)) {
    if (!w) continue;
    if (/^(https?:\/\/|www\.)/.test(w)) {
      w = w.replace(/[?#].*$/, "").replace(/[^\p{L}\p{N}\/]+$/u, "");
      if (w) out.push(w);
      continue;
    }
    if (/^(nostr:)?(npub|note|nevent|naddr|nprofile)1[a-z0-9]+$/.test(w)) continue;
    if (w[0] === "@") continue;
    w = w.replace(/^[^\p{L}\p{N}#]+|[^\p{L}\p{N}]+$/gu, "");
    if (!w || /^\p{N}+$/u.test(w)) continue;
    out.push(w);
  }
  return out;
}

export function nymKey(nym) {
  if (typeof nym !== "string") return "";
  let s = nym.replace(/#[a-fA-F0-9]{4}$/, "").toLowerCase().replace(/^[^\p{L}]+|[^\p{L}]+$/gu, "");
  s = s.replace(/[0134578$@|!]/g, (c) => LEET[c]);
  s = s.replace(/[^\p{L}]+/gu, "");
  if (s.length < 4 || GENERIC_NYMS.has(s)) return "";
  return s;
}

export function nymStem(key) {
  return key && key.length > NYM_STEM_LEN ? key.slice(0, NYM_STEM_LEN) : "";
}

const REPORT_REVIEWS_PER_REPORTER_HOUR = 5;
const REPORT_REVIEW_COOLDOWN_MS = 3600000;
const REPORT_WINDOW_MS = 86400000;
const REPORT_USER_MESSAGES = 3;
const CHATTER_MAX_CHARS = 24;
const CHATTER_MAX_TOKENS = 3;
const LINKISH = /https?:\/\/|www\.|\.(com|net|org|io|app|xyz|me|to|ly|gg)(\/|\b)|(nostr:)?(npub|note|nevent|naddr|nprofile)1[a-z0-9]{10,}/i;
const APP_ACTIONS = [
  /^\/me\s+slaps\s+\S+(\s+\S+)?\s+around a bit with a large trout\b/i,
  /^\/me\s+gives\s+\S+(\s+\S+)?\s+a warm hug\b/i
];

export function isAppAction(content) {
  if (typeof content !== "string") return false;
  const t = content.trim();
  if (t.length > 160 || LINKISH.test(t)) return false;
  return APP_ACTIONS.some((re) => re.test(t));
}

export function isShortChatter(content) {
  if (typeof content !== "string") return false;
  const t = content.trim();
  if (!t || t.length > CHATTER_MAX_CHARS || LINKISH.test(t)) return false;
  const words = t.split(/\s+/).filter((w) => w[0] !== "@");
  if (words.length > CHATTER_MAX_TOKENS) return false;
  return /\p{L}|\p{Emoji_Presentation}|\p{Extended_Pictographic}/u.test(t) || /^[?!.]+$/.test(t) === false;
}

export function innocuousKind(content) {
  if (isAppAction(content)) return "action";
  if (isShortChatter(content)) return "chatter";
  return "";
}

export function senderSuspicious(job, dossier) {
  if ((job.localScore || 0) > 0) return true;
  const rec = dossier && dossier.record;
  if (rec && (Number(rec.spam) > 0 || Number(rec.strikes) > 0)) return true;
  return false;
}

export function badgeTier(env, job, now) {
  if (!job || typeof job.badgeTag !== "string" || !job.badgeTag) return "none";
  const authority = env ? authorityPubkey(env) : null;
  if (!authority) return "unverified";
  const v = verifyBadge(job.badgeTag, job.pubkey, authority, now || Date.now());
  return v ? v.tier : "invalid";
}

export function verdictReusable(fp) {
  return !!(fp && fp.simKey && fp.tokens >= MIN_REUSE_TOKENS);
}

const BAND_SEEDS = [0x9e3779b9, 0x85ebca6b, 0xc2b2ae35, 0x27d4eb2f];

export function fingerprint(content) {
  const tokens = spamTokens(content);
  const text = tokens.join(" ");
  const shingles = [];
  if (tokens.length === 1) shingles.push(hash32(tokens[0]));
  for (let i = 0; i + 1 < tokens.length; i++) shingles.push(hash32(tokens[i] + " " + tokens[i + 1]));
  const bands = [null, null, null, null];
  if (shingles.length >= 3) {
    for (let b = 0; b < 4; b++) {
      let min = 0xffffffff;
      for (const s of shingles) {
        const v = Math.imul(s ^ BAND_SEEDS[b], 0x9e3779b1) >>> 0;
        if (v < min) min = v;
      }
      bands[b] = min;
    }
  }
  return { text, tokens: tokens.length, simKey: text ? hash32(text) : 0, bands };
}

export function parseSpamVerdict(text) {
  if (!text) return null;
  let s = String(text).trim();
  s = s.replace(/<think>[\s\S]*?<\/think>/gi, "").trim();
  s = s.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  const start = s.indexOf("{");
  const end = s.lastIndexOf("}");
  if (start === -1 || end <= start) return null;
  let obj = null;
  try { obj = JSON.parse(s.slice(start, end + 1)); } catch (e) { return null; }
  if (!obj || typeof obj !== "object") return null;
  let spam = obj.spam;
  if (typeof spam !== "boolean") spam = obj.is_spam;
  if (typeof spam !== "boolean") {
    if (typeof obj.verdict === "string") spam = obj.verdict.toLowerCase() === "spam";
    else return null;
  }
  return {
    spam,
    confidence: Math.max(0, Math.min(1, Number(obj.confidence) || 0)),
    category: String(obj.category || (spam ? "spam" : "ok")).slice(0, 40).toLowerCase(),
    language: String(obj.language || obj.lang || "").trim().slice(0, 16).toLowerCase(),
    messageAlone: typeof obj.message_alone === "boolean" ? obj.message_alone : (typeof obj.messageAlone === "boolean" ? obj.messageAlone : null),
    reason: String(obj.reason || obj.summary || "").slice(0, 400)
  };
}

export const SPAM_SYSTEM_PROMPT = `You are the spam filter for Nymchat, an ephemeral, pseudonymous chat over public Nostr relays. Channels are geohash areas or named rooms; users pick a throwaway nym and post short messages. Public relays are flooded by bot networks that post into many channels: profane insult "personas" that address nobody, gibberish or random tokens, ads, crypto and link spam, the same text under several nyms and pubkeys, machine-written filler in several languages, and messages that repeat with small variations.

Messages come in any language and script (Turkish, Russian, Ukrainian, Spanish, Portuguese, German, Arabic, Persian, Hindi, Indonesian, Chinese, Japanese and more), often colloquial, misspelled, slang, dialect or a regional spelling ("geliyom", "toletini temizle", "q tal", "wsg"). First work out which language the message is in. "gibberish" means random characters, keyboard mashing or token soup with no reading in ANY language; a word or phrase you do not recognise is far more likely a real language you know less well than gibberish, so never use the gibberish category unless you are sure the text has no meaning anywhere. A message of one or two ordinary words is chatter whatever the language, and a sender whose earlier messages were judged ok has a good record, not a bad one.

Some senders carry proof of the client they use. An "attested" badge is hardware-backed by Apple App Attest or Google Play Integrity and cannot be minted by a bot farm; "challenged" is a browser that solved a proof-of-work challenge; "origin" is a plain browser; "invalid" is a forged, lifted or expired badge and a bad sign. The #nymchat channel is reachable only through the Nymchat app relay. A badge and posting in #nymchat make a real person much more likely, and you should weigh the message accordingly, but they are context, not an exemption: a badged sender posting an ad, a scam or a persona flood is still spam.

Some audits are re-reviews because another user reported the message or its sender as spam. A report means someone in the room objected; it is unverified and reports can be filed out of spite or as a weapon, so treat it as a slight nudge to look again, never as evidence: a clean message stays ok however many reports it gathers, and a report changes nothing about a message you would already call spam.

Decide whether ONE message is bot spam that should be muted. Judge the evidence: the message itself, local heuristics, the sender's history, similar prior messages with their verdicts, and prior senders whose nyms resemble this one. Repetition across channels, nyms or pubkeys, and prior spam verdicts on similar text, are strong evidence. Bot networks reuse nyms with small variations (case, digits, leetspeak, a suffix or a longer form of the same name), so a nym close to nyms recently judged spam under other pubkeys can corroborate a verdict when this message reads like that family's spam. It never convicts on its own: real people pick common names, copy names, and get impersonated, so a message that would pass on its own must pass even if the nym matches a spammer's exactly. Judge the text first, then let the nym only confirm what the text already shows. A rude, crude, sexual or angry message from a human talking to the room is NOT spam. Short chatter ("gm", "anyone here?"), links shared in a conversation, non-English human talk, and jokes are NOT spam. Be conservative: when the evidence is thin, answer spam=false with low confidence.

Respond with ONE JSON object and nothing else, exactly this shape:
{"spam": true|false, "confidence": 0.0-1.0, "message_alone": true|false, "language": "<ISO 639-1 code of the message, or unknown>", "category": "<one of: bot-flood, gibberish, ad, scam, link-spam, persona-bot, repeat, other, ok>", "reason": "<one sentence>"}
message_alone answers: would this message text be spam from a brand-new nym with no history, no similar prior messages and no similar nyms?`;

function short(pk) { return pk ? pk.slice(0, 8) + "…" + pk.slice(-4) : "?"; }
function when(ms) { return ms ? new Date(ms).toISOString().replace(/\.\d+Z$/, "Z") : "?"; }
function clip(s, n) { s = String(s == null ? "" : s).replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n) + "…" : s; }

export function buildSpamPrompt(job, dossier) {
  const lines = [];
  lines.push("MESSAGE");
  lines.push("channel: " + (job.channel || "?") + " (kind " + job.kind + ")");
  lines.push("nym: " + (job.nym || "?") + (job.nymKey ? " (normalised: " + job.nymKey + ")" : ""));
  lines.push("pubkey: " + short(job.pubkey));
  lines.push("posted: " + when(job.createdAt || job.seenAt));
  lines.push("content: " + JSON.stringify(clip(job.content, CONTENT_MAX)));
  if (job.report) {
    lines.push("");
    lines.push("USER REPORTS (unverified; a slight nudge, never evidence)");
    lines.push("this is a re-review: reported as spam by " + (job.report.reporters || 1) + " distinct user" + ((job.report.reporters || 1) === 1 ? "" : "s") + " in the last 24h" + (job.report.onSender ? " (the report named the sender, not this message)" : ""));
  }
  lines.push("");
  lines.push("SENDER PROOF");
  lines.push("attestation badge: " + (job.badge || "none"));
  lines.push("posting in #nymchat (app relay only): " + (job.kind === 23333 && String(job.channel || "").toLowerCase() === "nymchat" ? "yes" : "no"));
  lines.push("");
  lines.push("LOCAL HEURISTICS");
  lines.push("gibberish score: " + (job.localScore || 0) + " (3+ is drop-worthy on its own)");
  lines.push("near-identical copies seen by this proxy in the last 15 min: " + (job.copies || 0));
  const rec = dossier.record;
  lines.push("");
  lines.push("SENDER RECORD");
  if (!rec) lines.push("no prior audits of this pubkey");
  else {
    lines.push("audits: " + rec.audits + ", judged spam: " + rec.spam + ", judged ok: " + rec.ham + ", strikes: " + rec.strikes + ", score: " + Number(rec.score || 0).toFixed(2));
    lines.push("first seen: " + when(rec.first_seen) + ", last seen: " + when(rec.last_seen));
    lines.push("channels posted in: " + (rec.channels || "?"));
    lines.push("nyms used: " + (rec.nyms || "?"));
    if (rec.last_reason) lines.push("last verdict reason: " + clip(rec.last_reason, 200));
  }
  if (dossier.recent && dossier.recent.length) {
    lines.push("recent messages by this pubkey:");
    for (const r of dossier.recent.slice(0, 8)) lines.push("- [" + (r.channel || "?") + (r.nym ? " as " + r.nym : "") + "] " + JSON.stringify(clip(r.content, 140)) + (r.verdict ? " (" + r.verdict + ")" : ""));
  }
  lines.push("");
  lines.push("SIMILAR PRIOR MESSAGES (last 48h)");
  const sim = dossier.similar || [];
  if (!sim.length) lines.push("none");
  else {
    lines.push("count: " + sim.length + ", distinct pubkeys: " + dossier.similarPubkeys + ", judged spam: " + dossier.similarSpam);
    for (const s of sim.slice(0, LIST_CAP)) {
      lines.push("- " + when(s.seen_at) + " [" + (s.channel || "?") + "] " + (s.nym || "?") + " " + short(s.pubkey) + (s.pubkey === job.pubkey ? " (same sender)" : "") + ": " + JSON.stringify(clip(s.content, 120)) + " → " + s.verdict + (s.confidence ? " " + Math.round(s.confidence * 100) + "%" : ""));
    }
  }
  lines.push("");
  lines.push("OTHER SENDERS WITH A SIMILAR NYM (last 48h; a shared or similar nym is never spam by itself)");
  const nyms = dossier.nymMatches || [];
  if (!job.nymKey) lines.push("n/a (generic or empty nym)");
  else if (!nyms.length) lines.push("none");
  else {
    lines.push("count: " + nyms.length + ", distinct pubkeys: " + dossier.nymPubkeys + ", judged spam: " + dossier.nymSpam + " (from " + dossier.nymSpamPubkeys + " pubkeys)");
    for (const s of nyms.slice(0, LIST_CAP)) {
      lines.push("- " + when(s.seen_at) + " [" + (s.channel || "?") + "] " + (s.nym || "?") + " " + short(s.pubkey) + ": " + JSON.stringify(clip(s.content, 120)) + " → " + s.verdict + (s.confidence ? " " + Math.round(s.confidence * 100) + "%" : ""));
    }
  }
  return lines.join("\n");
}

function gatewayIds(env) {
  let acct = env.AI_GATEWAY_ACCOUNT_ID || "";
  let name = env.AI_GATEWAY_NAME || "";
  const m = /^https:\/\/gateway\.ai\.cloudflare\.com\/v1\/([^/]+)\/([^/]+)\//.exec(env.AI_GATEWAY_URL || "");
  if (m) { if (!acct) acct = m[1]; if (!name) name = m[2]; }
  return { acct, name };
}

function gatewayUrl(env) {
  const ids = gatewayIds(env);
  if (!ids.acct || !ids.name) return null;
  return "https://gateway.ai.cloudflare.com/v1/" + ids.acct + "/" + ids.name + "/compat/chat/completions";
}

function messageText(payload) {
  const choice = payload && Array.isArray(payload.choices) ? payload.choices[0] : null;
  const msg = choice && choice.message;
  if (msg) {
    if (typeof msg.content === "string") return msg.content;
    if (Array.isArray(msg.content)) return msg.content.map((b) => (b && typeof b.text === "string" ? b.text : "")).join("\n");
  }
  if (payload && typeof payload.response === "string") return payload.response;
  if (payload && payload.result && typeof payload.result.response === "string") return payload.result.response;
  return "";
}

export function spamTransports(env, model) {
  const out = [];
  const m = model || DEFAULT_SPAM_MODEL;
  const bound = !!(env && env.AI && typeof env.AI.run === "function");
  const gw = env ? gatewayUrl(env) : null;
  if (m.startsWith("@cf/")) {
    if (bound) out.push({ kind: "bound", model: m });
    if (gw) out.push({ kind: "gateway", model: "workers-ai/" + m, url: gw });
  } else {
    if (gw) out.push({ kind: "gateway", model: m, url: gw });
    if (bound) out.push({ kind: "bound", model: DEFAULT_SPAM_MODEL });
  }
  return out;
}

function needsNoThink(model) {
  return /qwen3/i.test(String(model || ""));
}

function transportMessages(t, messages) {
  if (!needsNoThink(t.model)) return messages;
  const out = messages.slice();
  const last = out[out.length - 1];
  if (last && last.role === "user" && typeof last.content === "string" && !last.content.endsWith(NO_THINK_SUFFIX)) {
    out[out.length - 1] = { role: "user", content: last.content + NO_THINK_SUFFIX };
  }
  return out;
}

async function callTransport(env, t, rawMessages) {
  const messages = transportMessages(t, rawMessages);
  if (t.kind === "bound") {
    const opts = String(env.SPAM_VIA_GATEWAY || "") === "1" && env.AI_GATEWAY_NAME ? { gateway: { id: env.AI_GATEWAY_NAME } } : undefined;
    const body = { messages, max_tokens: 300, temperature: 0 };
    const res = opts ? await env.AI.run(t.model, body, opts) : await env.AI.run(t.model, body);
    return messageText(res);
  }
  const headers = { "Content-Type": "application/json" };
  if (env.AI_GATEWAY_TOKEN) headers["cf-aig-authorization"] = "Bearer " + env.AI_GATEWAY_TOKEN;
  const token = env.CF_API_TOKEN || env.AI_GATEWAY_API_TOKEN;
  if (token) headers["Authorization"] = "Bearer " + token;
  const res = await fetch(t.url, { method: "POST", headers, body: JSON.stringify({ model: t.model, messages, max_tokens: 300, temperature: 0 }) });
  const raw = await res.text();
  let data = null;
  try { data = JSON.parse(raw); } catch (e) { data = null; }
  if (!res.ok) throw new Error("gateway HTTP " + res.status + ": " + raw.slice(0, 160));
  return messageText(data);
}

export function isRateLimitError(e) {
  const m = String(e && e.message || e || "");
  return /\b429\b|rate.?limit|"code":\s*2003|too many requests/i.test(m);
}

export async function askSpamModel(env, settings, prompt) {
  const transports = spamTransports(env, settings.model);
  if (!transports.length) throw new Error("no AI transport configured");
  const messages = [{ role: "system", content: SPAM_SYSTEM_PROMPT }, { role: "user", content: prompt }];
  let lastErr = null;
  const failures = [];
  for (const t of transports) {
    try {
      const text = await callTransport(env, t, messages);
      const v = parseSpamVerdict(text);
      if (!v) throw new Error("unparseable verdict: " + String(text).slice(0, 120));
      v.model = t.model;
      return v;
    } catch (e) {
      lastErr = e;
      failures.push(t.kind + " " + t.model + ": " + String(e && e.message || e).slice(0, 220));
      if (isRateLimitError(e)) break;
    }
  }
  if (isRateLimitError(lastErr)) {
    state.cooldownUntil = Date.now() + RATE_LIMIT_COOLDOWN_MS;
    state.counters.rateLimited++;
  }
  if (failures.length > 1) throw new Error(failures.join(" | "));
  throw lastErr || new Error("model failed");
}

function mergeList(existing, value, cap) {
  const list = [];
  const seen = new Set();
  const push = (v) => { v = String(v || "").trim(); if (!v || seen.has(v)) return; seen.add(v); list.push(v); };
  push(value);
  for (const v of String(existing || "").split(",")) push(v);
  return list.slice(0, cap || 10).join(",");
}

const state = {
  settings: null,
  settingsAt: 0,
  settingsLoading: null,
  schemaReady: false,
  seen: new Map(),
  exact: new Map(),
  muted: new Map(),
  hidden: new Set(),
  dropped: new Map(),
  pending: new Map(),
  queue: [],
  running: 0,
  budgetMinute: 0,
  budgetUsed: 0,
  lastAuditAt: 0,
  lastError: null,
  lastErrorAt: 0,
  statusAt: 0,
  cooldownUntil: 0,
  counters: { inspected: 0, queued: 0, held: 0, audited: 0, cached: 0, dropped: 0, retracted: 0, timedOut: 0, muted: 0, skippedBudget: 0, skippedCooldown: 0, rateLimited: 0, nymOnly: 0, chatter: 0, reportReviews: 0, raced: 0, errors: 0 }
};

export function _resetSpamState() {
  state.settings = null; state.settingsAt = 0; state.settingsLoading = null; state.schemaReady = false;
  state.seen.clear(); state.exact.clear(); state.muted.clear(); state.hidden.clear(); state.dropped.clear();
  for (const pend of state.pending.values()) if (pend.timer) clearTimeout(pend.timer);
  state.pending.clear();
  state.queue = []; state.running = 0; state.budgetMinute = 0; state.budgetUsed = 0;
  state.lastAuditAt = 0; state.lastError = null; state.lastErrorAt = 0; state.statusAt = 0; state.cooldownUntil = 0;
  for (const k of Object.keys(state.counters)) state.counters[k] = 0;
}

export function isCoolingDown(now) {
  return (now || Date.now()) < state.cooldownUntil;
}

export function isSpamHidden(id) { return state.hidden.has(id); }

function noteDropped(id) {
  state.dropped.set(id, 1);
  trimMap(state.dropped, SEEN_MAX);
}

function settle(id, drop) {
  const pend = state.pending.get(id);
  if (!pend) return;
  state.pending.delete(id);
  if (pend.timer) clearTimeout(pend.timer);
  for (const w of pend.waiters) {
    try {
      if (drop) {
        if (w.released) { state.counters.retracted++; if (typeof w.retract === "function") w.retract(); }
        else state.counters.dropped++;
      } else if (!w.released) {
        w.released = true;
        if (typeof w.release === "function") w.release();
      }
    } catch (_) { }
  }
}

function releaseAll(id) {
  const pend = state.pending.get(id);
  if (!pend) return;
  pend.released = true;
  for (const w of pend.waiters) {
    if (w.released) continue;
    w.released = true;
    try { if (typeof w.release === "function") w.release(); } catch (_) { }
  }
}

async function noteStatus(env) {
  const now = Date.now();
  if (now - state.statusAt < SETTINGS_REFRESH_MS) return;
  state.statusAt = now;
  const db = env && env.DB_NOPE;
  if (!hasD1(db)) return;
  try {
    await ensureSchema(db);
    await db.prepare("INSERT INTO spam_config (key, value) VALUES ('status', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
      .bind(JSON.stringify({
        at: now, model: state.settings ? state.settings.model : null, lastAuditAt: state.lastAuditAt,
        lastError: state.lastError, lastErrorAt: state.lastErrorAt, pending: state.pending.size, queue: state.queue.length,
        cooldownUntil: state.cooldownUntil, viaGateway: String(env.SPAM_VIA_GATEWAY || "") === "1" && !!env.AI_GATEWAY_NAME,
        counters: Object.assign({}, state.counters)
      })).run();
  } catch (_) { }
}

export function spamCounters() { return Object.assign({}, state.counters); }

async function ensureSchema(db) {
  if (state.schemaReady) return;
  for (const ddl of SPAM_DDL) { try { await db.prepare(ddl).run(); } catch (_) { } }
  state.schemaReady = true;
}

export async function readSpamSettings(env) {
  const base = defaultSpamSettings(env);
  const db = env && env.DB_NOPE;
  if (!hasD1(db)) return base;
  try {
    let row;
    try {
      row = await replica(db).prepare("SELECT value FROM spam_config WHERE key = ?").bind(SPAM_SETTINGS_KEY).first();
    } catch (e) {
      await ensureSchema(db);
      row = await db.prepare("SELECT value FROM spam_config WHERE key = ?").bind(SPAM_SETTINGS_KEY).first();
    }
    if (!row || !row.value) return base;
    return normalizeSpamSettings(JSON.parse(row.value), base);
  } catch (e) { return base; }
}

export async function writeSpamSettings(env, settings) {
  const db = env.DB_NOPE;
  await ensureSchema(db);
  await db.prepare("INSERT INTO spam_config (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
    .bind(SPAM_SETTINGS_KEY, JSON.stringify(settings)).run();
  state.settings = settings;
  state.settingsAt = Date.now();
}

function settingsSync(env) {
  const now = Date.now();
  if (now - state.settingsAt >= SETTINGS_REFRESH_MS && !state.settingsLoading) {
    state.settingsLoading = readSpamSettings(env).then((s) => { state.settings = s; state.settingsAt = Date.now(); state.settingsLoading = null; },
      () => { state.settingsLoading = null; state.settingsAt = Date.now(); });
  }
  return state.settings;
}

function trimMap(map, max) {
  if (map.size <= max) return;
  let n = map.size - max;
  for (const k of map.keys()) { if (n-- <= 0) break; map.delete(k); }
}

function noteSeen(id) {
  if (state.seen.has(id)) return false;
  state.seen.set(id, 1);
  trimMap(state.seen, SEEN_MAX);
  return true;
}

export function isSpamMuted(pubkey, now) {
  const until = state.muted.get(pubkey);
  if (until === undefined) return false;
  if ((now || Date.now()) < until) return true;
  state.muted.delete(pubkey);
  return false;
}

export function muteLocally(pubkey, until) {
  state.muted.set(pubkey, until);
  trimMap(state.muted, MUTED_MAX);
}

function budgetOk(settings) {
  const minute = Math.floor(Date.now() / 60000);
  if (minute !== state.budgetMinute) { state.budgetMinute = minute; state.budgetUsed = 0; }
  if (state.budgetUsed >= settings.auditBudgetPerMinute) return false;
  state.budgetUsed++;
  return true;
}

function exactVerdict(simKey, now) {
  const e = state.exact.get(simKey);
  if (!e) return null;
  if (now - e.at > EXACT_CACHE_MS) { state.exact.delete(simKey); return null; }
  return e;
}

function rememberExact(fp, v, now) {
  if (!verdictReusable(fp)) return;
  const simKey = fp.simKey;
  state.exact.set(simKey, { spam: v.spam, confidence: v.confidence, category: v.category, reason: v.reason, model: v.model, at: now });
  trimMap(state.exact, EXACT_CACHE_MAX);
}

function isCandidate(job, settings, dossier) {
  if (settings.auditScope === "all") return true;
  if ((job.localScore || 0) >= 1) return true;
  if ((job.copies || 0) >= 2) return true;
  if (dossier && dossier.similarSpam > 0) return true;
  if (dossier && dossier.nymSpam > 0) return true;
  if (job.fp.simKey && state.exact.has(job.fp.simKey)) return true;
  if (job.nym && /^[A-Za-z0-9]{8,}$/.test(job.nym) && /[a-z][A-Z]/.test(job.nym)) return true;
  return job.pubkeyUnknown;
}

async function loadDossier(env, job, settings) {
  const db = env.DB_NOPE;
  const r = replica(db);
  const now = job.seenAt;
  const since = now - SIMILAR_WINDOW_MS;
  const out = { self: null, record: null, recent: [], similar: [], similarPubkeys: 0, similarSpam: 0, similarSpamPubkeys: 0, exact: null, nymMatches: [], nymPubkeys: 0, nymSpam: 0, nymSpamPubkeys: 0 };
  const reusable = verdictReusable(job.fp);
  if (!job.force) {
    try {
      out.self = await r.prepare("SELECT verdict, confidence, category, reason, model, action, lang FROM spam_events WHERE id = ?").bind(job.id).first();
    } catch (e) { out.self = null; }
  }
  try {
    out.record = await r.prepare("SELECT * FROM spam_pubkeys WHERE pubkey = ?").bind(job.pubkey).first();
  } catch (e) { out.record = null; }
  try {
    const rs = await r.prepare("SELECT channel, nym, content, verdict FROM spam_events WHERE pubkey = ? AND id != ? ORDER BY seen_at DESC LIMIT 8")
      .bind(job.pubkey, job.id).all();
    out.recent = (rs && rs.results) || [];
  } catch (e) { out.recent = []; }
  if (job.fp.simKey) {
    const b = job.fp.bands;
    const clauses = ["sim_key = ?"];
    const binds = [job.fp.simKey];
    for (let i = 0; i < 4; i++) if (b[i] != null) { clauses.push("b" + i + " = ?"); binds.push(b[i]); }
    try {
      const rs = await r.prepare("SELECT id, pubkey, nym, channel, content, verdict, confidence, seen_at, sim_key FROM spam_events WHERE (" + clauses.join(" OR ") +
        ") AND seen_at > ? AND id != ? ORDER BY seen_at DESC LIMIT 40").bind(...binds, since, job.id).all();
      const rows = (rs && rs.results) || [];
      const pks = new Set();
      const spamPks = new Set();
      for (const row of rows) {
        pks.add(row.pubkey);
        if (row.verdict === "spam") { out.similarSpam++; spamPks.add(row.pubkey); }
        if (reusable && !out.exact && row.sim_key === job.fp.simKey && row.verdict === "spam" && Number(row.confidence) >= settings.minConfidence && row.pubkey !== job.pubkey) out.exact = row;
      }
      out.similar = rows;
      out.similarPubkeys = pks.size;
      out.similarSpamPubkeys = spamPks.size;
    } catch (e) { out.similar = []; }
  }
  if (job.nymKey) {
    const stem = nymStem(job.nymKey);
    const clauses = ["nym_key = ?"];
    const binds = [job.nymKey];
    if (stem) { clauses.push("nym_key LIKE ?"); binds.push(stem + "%"); }
    try {
      const rs = await r.prepare("SELECT id, pubkey, nym, channel, content, verdict, confidence, seen_at FROM spam_events WHERE (" + clauses.join(" OR ") +
        ") AND pubkey != ? AND seen_at > ? ORDER BY seen_at DESC LIMIT 30").bind(...binds, job.pubkey, since).all();
      const rows = (rs && rs.results) || [];
      const pks = new Set();
      const spamPks = new Set();
      for (const row of rows) {
        pks.add(row.pubkey);
        if (row.verdict === "spam") { out.nymSpam++; spamPks.add(row.pubkey); }
      }
      out.nymMatches = rows;
      out.nymPubkeys = pks.size;
      out.nymSpamPubkeys = spamPks.size;
    } catch (e) { out.nymMatches = []; }
  }
  return out;
}

async function recentArchive(env, job) {
  const db = env.DB_CHANNELS;
  if (!hasD1(db)) return [];
  try {
    const rs = await replica(db).prepare("SELECT channel, json FROM events WHERE pubkey = ? AND kind IN (20000, 23333) AND id != ? ORDER BY created_at DESC LIMIT 6")
      .bind(job.pubkey, job.id).all();
    const out = [];
    for (const row of (rs && rs.results) || []) {
      try {
        const ev = JSON.parse(row.json);
        const n = Array.isArray(ev.tags) ? ev.tags.find((t) => Array.isArray(t) && t[0] === "n") : null;
        out.push({ channel: row.channel, nym: n ? n[1] : "", content: typeof ev.content === "string" ? ev.content : "" });
      } catch (_) { }
    }
    return out;
  } catch (e) { return []; }
}

async function persist(env, job, v, dossier, action) {
  const db = env.DB_NOPE;
  await ensureSchema(db);
  const rec = dossier.record;
  const spam = v.spam ? 1 : 0;
  const strong = v.spam && v.confidence >= job.settings.minConfidence;
  const prevScore = rec ? Number(rec.score) || 0 : 0;
  const score = v.spam ? prevScore + v.confidence : Math.max(0, prevScore - 0.5);
  const strikes = (rec ? Number(rec.strikes) || 0 : 0) + (strong ? 1 : 0);
  const insert = db.prepare("INSERT INTO spam_events (id, pubkey, nym, channel, kind, content, sim_key, b0, b1, b2, b3, created_at, seen_at, verdict, confidence, category, reason, model, action, source, local_score, nym_key, lang, badge) " +
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)" +
      (job.source === "report"
        ? " ON CONFLICT(id) DO UPDATE SET seen_at = excluded.seen_at, verdict = excluded.verdict, confidence = excluded.confidence, category = excluded.category, reason = excluded.reason, model = excluded.model, action = excluded.action, source = excluded.source, lang = excluded.lang, badge = excluded.badge"
        : " ON CONFLICT(id) DO NOTHING"))
      .bind(job.id, job.pubkey, clip(job.nym, 80) || null, clip(job.channel, 80) || null, job.kind, clip(job.content, 4000), job.fp.simKey,
        job.fp.bands[0], job.fp.bands[1], job.fp.bands[2], job.fp.bands[3], job.createdAt || job.seenAt, job.seenAt,
        v.spam ? "spam" : "ok", v.confidence, v.category || null, v.reason || null, v.model || null, action, job.source || "pool", job.localScore || 0, job.nymKey || null, v.language || null, job.badge && job.badge !== "none" ? job.badge : null);
  const res = await insert.run();
  const changes = res && res.meta && typeof res.meta.changes === "number" ? res.meta.changes : 1;
  if (changes === 0 && job.source !== "report" && !job.force) return { lost: true, strikes: 0, score: prevScore };
  await db.prepare("INSERT INTO spam_pubkeys (pubkey, first_seen, last_seen, audits, spam, ham, strikes, score, channels, nyms, last_reason) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?) " +
      "ON CONFLICT(pubkey) DO UPDATE SET last_seen = excluded.last_seen, audits = audits + 1, spam = spam + excluded.spam, ham = ham + excluded.ham, " +
      "strikes = ?, score = ?, channels = ?, nyms = ?, last_reason = excluded.last_reason")
      .bind(job.pubkey, job.seenAt, job.seenAt, spam, 1 - spam, strikes, score,
        mergeList(rec && rec.channels, job.channel), mergeList(rec && rec.nyms, job.nym), v.spam ? clip(v.reason, 300) : (rec && rec.last_reason) || null,
        strikes, score, mergeList(rec && rec.channels, job.channel), mergeList(rec && rec.nyms, job.nym)).run();
  return { strikes, score };
}

function adoptPeer(row, job) {
  const v = { spam: row.verdict === "spam", confidence: Number(row.confidence) || 0, category: row.category || (row.verdict === "spam" ? "spam" : "ok"), language: row.lang || "", reason: row.reason || "", model: "peer" };
  const action = row.action || (v.spam ? "flagged" : "ok");
  if (/event-hidden/.test(action)) { noteDropped(job.id); state.hidden.add(job.id); }
  state.counters.cached++;
  return { verdict: v, action, strikes: 0, score: 0, similar: 0, similarPubkeys: 0, similarNyms: 0, nymSpam: 0, peer: true };
}

async function enforce(env, job, v, dossier, strikes) {
  const s = job.settings;
  const db = env.DB_NOPE;
  const now = job.seenAt;
  const nymFamily = dossier.nymSpamPubkeys + 1 >= s.campaignCopies;
  const campaign = dossier.similarSpamPubkeys + 1 >= s.campaignCopies || (dossier.similarPubkeys + 1 >= s.campaignCopies && (job.copies || 0) >= 2) || nymFamily;
  const shortFloor = !!innocuousKind(job.content) && strikes < 2;
  const muteNow = (strikes >= s.strikesToMute && !shortFloor) || campaign;
  const actions = [];
  noteDropped(job.id);
  if (s.blockEvents) {
    state.hidden.add(job.id);
    if (state.hidden.size > SEEN_MAX) state.hidden.delete(state.hidden.values().next().value);
    if (hasD1(env.DB_CHANNELS)) {
      try { await env.DB_CHANNELS.prepare("DELETE FROM events WHERE id = ?").bind(job.id).run(); actions.push("event-hidden"); } catch (_) { }
    }
  }
  if (!muteNow) { actions.push("strike"); return actions; }
  const until = now + Math.round(s.muteHours * 3600000);
  const why = campaign ? (nymFamily && dossier.similarSpamPubkeys + 1 < s.campaignCopies ? "nym family" : "campaign") : strikes + " strikes";
  const reason = "spam engine: " + (v.category || "spam") + " (" + Math.round(v.confidence * 100) + "%, " + why + ")";
  const note = clip(v.reason, 300) + "\nnym: " + (job.nym || "?") + " · channel: " + (job.channel || "?") + "\n" + clip(job.content, 240);
  try {
    await db.prepare("INSERT INTO nope (kind, value, mode, reason, note, created_at, created_by, expires_at) VALUES ('pubkey', ?, ?, ?, ?, ?, ?, ?) " +
      "ON CONFLICT(kind, value) DO UPDATE SET mode = CASE WHEN nope.created_by = ? THEN excluded.mode ELSE nope.mode END, " +
      "expires_at = CASE WHEN nope.created_by = ? THEN excluded.expires_at ELSE nope.expires_at END, " +
      "reason = CASE WHEN nope.created_by = ? THEN excluded.reason ELSE nope.reason END, note = CASE WHEN nope.created_by = ? THEN excluded.note ELSE nope.note END")
      .bind(job.pubkey, s.mode, reason, note, now, SPAM_ACTOR, until, SPAM_ACTOR, SPAM_ACTOR, SPAM_ACTOR, SPAM_ACTOR).run();
    await db.prepare("UPDATE spam_pubkeys SET muted_until = ? WHERE pubkey = ?").bind(until, job.pubkey).run();
    try {
      await db.prepare("INSERT INTO audit (at, actor, action, kind, value, detail) VALUES (?, ?, 'spam.mute', 'pubkey', ?, ?)")
        .bind(now, SPAM_ACTOR, job.pubkey, JSON.stringify({ reason, until, event: job.id, channel: job.channel, nym: job.nym, strikes, campaign })).run();
    } catch (_) { }
    muteLocally(job.pubkey, until);
    state.counters.muted++;
    actions.push("muted");
  } catch (e) {
    actions.push("mute-failed");
  }
  return actions;
}

export function nymIsOnlyEvidence(job, dossier, v) {
  if (!v || !v.spam || v.messageAlone !== false) return false;
  if (!dossier || !(dossier.nymSpam > 0)) return false;
  if (dossier.similarSpam > 0) return false;
  if ((job.copies || 0) >= 2 || (job.localScore || 0) > 0) return false;
  const rec = dossier.record;
  if (rec && (Number(rec.spam) > 0 || Number(rec.strikes) > 0)) return false;
  return true;
}

export async function auditNow(env, job) {
  const settings = job.settings || state.settings || defaultSpamSettings(env);
  job.settings = settings;
  const now = job.seenAt || Date.now();
  job.seenAt = now;
  if (!job.fp) job.fp = fingerprint(job.content);
  if (job.nymKey == null) job.nymKey = nymKey(job.nym);
  const dossier = await loadDossier(env, job, settings);
  if (dossier.self) return adoptPeer(dossier.self, job);
  if (!dossier.recent.length) dossier.recent = await recentArchive(env, job);
  job.pubkeyUnknown = !dossier.record;
  if (job.badge == null) job.badge = badgeTier(env, job, now);
  let v = null;
  const innocuous = job.force ? "" : innocuousKind(job.content);
  const cached = verdictReusable(job.fp) ? exactVerdict(job.fp.simKey, now) : null;
  if (innocuous && !senderSuspicious(job, dossier)) {
    v = { spam: false, confidence: 0.1, category: "ok", language: "", model: innocuous, reason: innocuous === "action" ? "app action (/slap, /hug) from a sender with a clean record" : "short chatter from a sender with a clean record" };
    state.counters.chatter++;
  } else if (cached && cached.spam) {
    v = Object.assign({}, cached, { model: "cache", reason: "same text already judged spam: " + cached.reason });
    state.counters.cached++;
  } else if (dossier.exact) {
    v = { spam: true, confidence: Number(dossier.exact.confidence) || 0, category: "repeat", model: "cross-ref", reason: "identical text from " + short(dossier.exact.pubkey) + " was judged spam at " + when(dossier.exact.seen_at) };
    state.counters.cached++;
  } else {
    if (!job.force && !isCandidate(job, settings, dossier)) return { skipped: "not a candidate" };
    if (!job.force && !budgetOk(settings)) { state.counters.skippedBudget++; return { skipped: "budget" }; }
    if (!job.force && isCoolingDown(now)) { state.counters.skippedCooldown++; return { skipped: "cooldown" }; }
    const prompt = buildSpamPrompt(job, dossier);
    v = await askSpamModel(env, settings, prompt);
    state.counters.audited++;
    if (nymIsOnlyEvidence(job, dossier, v)) {
      v = Object.assign({}, v, { spam: false, category: "ok", confidence: Math.min(v.confidence, 0.5), reason: "let through: the message is not spam on its own and only the nym resembles prior spam (model: " + clip(v.reason, 200) + ")" });
      state.counters.nymOnly++;
    }
    rememberExact(job.fp, v, now);
  }
  const strong = v.spam && v.confidence >= settings.minConfidence;
  let action = v.spam ? (strong ? "flagged" : "suspect") : "ok";
  let strikes = 0;
  const persisted = await persist(env, job, v, dossier, action);
  if (persisted.lost) {
    state.counters.raced++;
    let row = null;
    try { row = await env.DB_NOPE.prepare("SELECT verdict, confidence, category, reason, model, action, lang FROM spam_events WHERE id = ?").bind(job.id).first(); } catch (_) { row = null; }
    if (row) return adoptPeer(row, job);
    return { verdict: v, action: "ok", strikes: 0, score: 0, similar: 0, similarPubkeys: 0, similarNyms: 0, nymSpam: 0, peer: true };
  }
  strikes = persisted.strikes;
  let actions = [];
  if (strong && settings.autoEnforce) {
    actions = await enforce(env, job, v, dossier, strikes);
    action = actions.join(",");
    try { await env.DB_NOPE.prepare("UPDATE spam_events SET action = ? WHERE id = ?").bind(action, job.id).run(); } catch (_) { }
  }
  return { verdict: v, action, strikes, score: persisted.score, similar: dossier.similar.length, similarPubkeys: dossier.similarPubkeys, similarNyms: dossier.nymMatches.length, nymSpam: dossier.nymSpam };
}

function verdictDrops(job, res) {
  const s = job.settings || state.settings;
  return !!(res && res.verdict && res.verdict.spam && s && s.autoEnforce && res.verdict.confidence >= s.minConfidence);
}

function pump(env, context) {
  while (state.running < MAX_CONCURRENT && state.queue.length) {
    const job = state.queue.shift();
    state.running++;
    const work = auditNow(env, job).then((res) => {
      state.lastAuditAt = Date.now();
      settle(job.id, verdictDrops(job, res));
    }, (e) => {
      state.counters.errors++;
      state.lastError = String(e && e.message || e).slice(0, 300);
      state.lastErrorAt = Date.now();
      console.error("[spam] audit failed for " + job.id + ": " + state.lastError);
      settle(job.id, false);
    }).then(() => noteStatus(env)).then(() => { state.running--; pump(env, context); });
    if (context && typeof context.waitUntil === "function") { try { context.waitUntil(work); } catch (_) { } }
  }
}

function reportTag(tags, name) {
  const t = Array.isArray(tags) ? tags.find((x) => Array.isArray(x) && x[0] === name && typeof x[1] === "string") : null;
  return t || null;
}

function jobFromArchivedRow(row, extra) {
  let ev = null;
  try { ev = JSON.parse(row.json); } catch (_) { return null; }
  if (!ev || typeof ev.id !== "string" || typeof ev.pubkey !== "string" || typeof ev.content !== "string") return null;
  const n = reportTag(ev.tags, "n");
  const badge = reportTag(ev.tags, "nymattest");
  return Object.assign({
    id: ev.id.toLowerCase(), kind: ev.kind, pubkey: ev.pubkey.toLowerCase(), content: ev.content,
    nym: n ? n[1].replace(/#[a-fA-F0-9]{4}$/, "") : "", channel: row.channel || "", createdAt: (Number(ev.created_at) || 0) * 1000,
    badgeTag: badge ? badge[1] : "", localScore: 0, copies: 0, source: "report", force: true
  }, extra || {});
}

export async function reviewSpamReport(env, ev, opts) {
  const now = (opts && opts.now) || Date.now();
  if (!ev || ev.kind !== 1984 || typeof ev.pubkey !== "string" || !Array.isArray(ev.tags)) return { skipped: "not a report" };
  const e = reportTag(ev.tags, "e");
  const p = reportTag(ev.tags, "p");
  const type = String((e && e[2]) || (p && p[2]) || "").toLowerCase();
  if (type !== "spam") return { skipped: "not a spam report" };
  if (!hasD1(env && env.DB_NOPE) || !hasD1(env && env.DB_CHANNELS) || !hasD1(env && env.DB_REPORT)) return { skipped: "no database" };
  const settings = await readSpamSettings(env);
  if (!settings || !settings.enabled) return { skipped: "disabled" };
  const reporter = ev.pubkey.toLowerCase();
  const targetEvent = e && HEX64.test(e[1].toLowerCase()) ? e[1].toLowerCase() : null;
  let targetPubkey = p && HEX64.test(p[1].toLowerCase()) ? p[1].toLowerCase() : null;
  if (!targetEvent && !targetPubkey) return { skipped: "no target" };
  if (targetPubkey) {
    if (targetPubkey === reporter) return { skipped: "self report" };
    if (isExemptPubkey(settings, targetPubkey)) return { skipped: "exempt" };
    if (isSpamMuted(targetPubkey, now)) return { skipped: "already muted" };
  }
  const reports = replica(env.DB_REPORT);
  try {
    const mine = await reports.prepare("SELECT COUNT(*) AS n FROM reports WHERE reporter = ? AND report_type = 'spam' AND received_at > ?")
      .bind(reporter, now - 3600000).first();
    if (mine && Number(mine.n) > REPORT_REVIEWS_PER_REPORTER_HOUR) return { skipped: "reporter rate" };
  } catch (_) { }
  const channels = replica(env.DB_CHANNELS);
  let rows = [];
  try {
    if (targetEvent) {
      const row = await channels.prepare("SELECT id, channel, kind, pubkey, json FROM events WHERE id = ? AND kind IN (20000, 23333)").bind(targetEvent).first();
      if (row) rows = [row];
    } else {
      const rs = await channels.prepare("SELECT id, channel, kind, pubkey, json FROM events WHERE pubkey = ? AND kind IN (20000, 23333) AND created_at > ? ORDER BY created_at DESC LIMIT ?")
        .bind(targetPubkey, Math.floor((now - REPORT_WINDOW_MS) / 1000), REPORT_USER_MESSAGES).all();
      rows = (rs && rs.results) || [];
    }
  } catch (_) { rows = []; }
  if (!rows.length) return { skipped: "nothing archived" };
  if (!targetPubkey && typeof rows[0].pubkey === "string") targetPubkey = rows[0].pubkey.toLowerCase();
  if (targetPubkey === reporter) return { skipped: "self report" };
  if (isExemptPubkey(settings, targetPubkey)) return { skipped: "exempt" };
  if (isSpamMuted(targetPubkey, now)) return { skipped: "already muted" };
  let reporters = 1;
  try {
    const groupKey = targetEvent ? "e:" + targetEvent : "p:" + targetPubkey;
    const r = await reports.prepare("SELECT COUNT(DISTINCT reporter) AS n FROM reports WHERE group_key = ? AND report_type = 'spam' AND received_at > ?")
      .bind(groupKey, now - REPORT_WINDOW_MS).first();
    reporters = Math.max(1, Number(r && r.n) || 0);
  } catch (_) { }
  const nope = replica(env.DB_NOPE);
  const results = [];
  for (const row of rows) {
    let prior = null;
    try { prior = await nope.prepare("SELECT verdict, source, seen_at FROM spam_events WHERE id = ?").bind(row.id).first(); } catch (_) { prior = null; }
    if (prior && prior.verdict === "spam") { results.push({ id: row.id, skipped: "already judged spam" }); continue; }
    if (prior && prior.source === "report" && now - Number(prior.seen_at) < REPORT_REVIEW_COOLDOWN_MS) { results.push({ id: row.id, skipped: "reviewed recently" }); continue; }
    const job = jobFromArchivedRow(row, { seenAt: now, settings, report: { reporters, onSender: !targetEvent } });
    if (!job) { results.push({ id: row.id, skipped: "unreadable" }); continue; }
    if (isExemptPubkey(settings, job.pubkey)) { results.push({ id: row.id, skipped: "exempt" }); continue; }
    try {
      const res = await auditNow(env, job);
      state.counters.reportReviews++;
      results.push({ id: row.id, verdict: res.verdict, action: res.action });
    } catch (err) {
      state.counters.errors++;
      state.lastError = String(err && err.message || err).slice(0, 300);
      state.lastErrorAt = Date.now();
      results.push({ id: row.id, error: state.lastError });
    }
  }
  return { reporter, targetPubkey, targetEvent, reporters, results };
}

export function spamEngine(env, context) {
  const db = env && env.DB_NOPE;
  const usable = hasD1(db);
  if (usable) settingsSync(env);
  return {
    active() {
      if (!usable) return false;
      const s = settingsSync(env);
      return !!(s && s.enabled);
    },
    settings() { return state.settings; },
    isHidden(id) { return state.hidden.has(id); },
    inspect(job) {
      const s = state.settings;
      if (!s || !s.enabled || !job || typeof job.pubkey !== "string" || !job.id) return "pass";
      const pubkey = job.pubkey.toLowerCase();
      const now = Date.now();
      state.counters.inspected++;
      if (isExemptPubkey(s, pubkey)) return "pass";
      if (isSpamMuted(pubkey, now)) { state.counters.dropped++; return "drop"; }
      if (state.dropped.has(job.id) || state.hidden.has(job.id)) { state.counters.dropped++; return "drop"; }
      if (typeof job.content !== "string" || !job.content.trim()) return "pass";
      if (isCoolingDown(now)) { state.counters.skippedCooldown++; return "pass"; }
      const pend = state.pending.get(job.id);
      if (pend) {
        const w = { release: job.release, retract: job.retract, released: false };
        pend.waiters.push(w);
        if (pend.released) { w.released = true; try { if (typeof w.release === "function") w.release(); } catch (_) { } }
        return "hold";
      }
      if (!noteSeen(job.id)) return "pass";
      if (state.queue.length >= MAX_QUEUE) return "pass";
      const fp = fingerprint(job.content);
      const queued = Object.assign({}, job, { pubkey, fp, nymKey: nymKey(job.nym), seenAt: now, settings: s, source: "pool" });
      delete queued.release;
      delete queued.retract;
      if (s.autoEnforce && verdictReusable(fp) && !innocuousKind(job.content)) {
        const cached = exactVerdict(fp.simKey, now);
        if (cached && cached.spam && cached.confidence >= s.minConfidence) {
          noteDropped(job.id);
          state.queue.push(queued);
          pump(env, context);
          state.counters.dropped++;
          return "drop";
        }
      }
      state.queue.push(queued);
      state.counters.queued++;
      let verdict = "pass";
      if (s.autoEnforce && s.holdMs > 0 && typeof job.release === "function") {
        const entry = { waiters: [{ release: job.release, retract: job.retract, released: false }], released: false, timer: null, at: now };
        entry.timer = setTimeout(() => { entry.timer = null; state.counters.timedOut++; releaseAll(job.id); }, s.holdMs);
        state.pending.set(job.id, entry);
        state.counters.held++;
        verdict = "hold";
      }
      pump(env, context);
      return verdict;
    }
  };
}
