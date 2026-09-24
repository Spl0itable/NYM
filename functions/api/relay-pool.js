// Cloudflare Pages Function: Multiplexed WebSocket relay pool proxy
// Single WebSocket from client, fans out to many upstream Nostr relays.
// Uses string-based deduplication (no JSON.parse) to minimize CPU usage.
//
// Client connects to: wss://<host>/api/relay-pool
//
// Protocol (client → proxy):
//   ["RELAYS", { critical: [...], geo: [...], dmRelays: [...] }] - relay set tagged by role
//   ["EVENT", eventObj]          - fans out to all connected relays
//   ["GEO_EVENT", eventObj, ["wss://geo1", ...]]  - fans out to listed geo relays first, then all others
//   ["DM_EVENT", eventObj]       - fans out to DM relays first, then all others
//   ["REQ", subId, ...filters]   - fans out to all relays
//   ["CLOSE", subId]             - fans out to all relays
//   ["ROLE", role, <inner msg>]  - routes REQ/CLOSE only to relays tagged with that role
//   ["KIND_BLACKLIST", { "wss://relay": [kind, ...], ... }] - skip relay for REQs whose kinds are all in its set
//
// Protocol (proxy → client):
//   ["EVENT", subId, eventObj]   - deduplicated via string extraction (no JSON.parse)
//   ["OK", eventId, bool, msg]   - first OK per event ID
//   ["EOSE", subId]              - deduplicated (first per subscription ID)
//   ["NOTICE", reason, relayUrl] - attributed to originating relay
//   ["CLOSED", subId, reason, relayUrl] - attributed to originating relay
//   ["POOL:RELAY_BAN", relayUrl, reason] - relay permanently dropped (auth, restricted, etc.)
//   ["POOL:RETRACT", eventId, reason] - an event forwarded earlier was judged spam; remove it
//   ["POOL:STATUS", { connected, count, latency, events }]

import { getEventHash, schnorr, ipv6Blocked, ipv6NetKey, cacheRateTake } from './_shared.js';
import { isNymchatClient, clientOriginAllowed } from './_client.js';
import { closestRelayUrls, loadGeoDirectory } from './_georelays.js';
import { filterSet, frameHit, eventHit, noteReport } from './_filters.js';
import { spamEngine, reviewSpamReport, hiddenEventIds, badgeGateRefuses, badgeTierFor } from './_spam.js';
import { verifyBadge, authorityPubkey } from './_attest.js';


// Reject relay hostnames that resolve to private/loopback/link-local space so
// the proxy can't be used to reach internal services (SSRF).
function isPrivateRelayHost(hostname) {
  let host = (hostname || '').toLowerCase().replace(/\.$/, '');
  if (!host) return true;
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  if (host.endsWith('.local') || host.endsWith('.internal')) return true;
  let h6 = host;
  if (h6.startsWith('[') && h6.endsWith(']')) h6 = h6.slice(1, -1);
  if (host.includes(':') || h6.includes(':')) {
    if (h6 === '::1' || h6 === '::' || h6 === '0:0:0:0:0:0:0:1') return true;
    if (ipv6Blocked(h6)) return true;
    if (/^f[cd][0-9a-f]{2}:/.test(h6)) return true;     // fc00::/7
    if (/^fe[89ab][0-9a-f]:/.test(h6)) return true;     // fe80::/10
    const m = h6.match(/^::(?:ffff:)?(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
    if (m) host = m[1]; else return false;
  }
  const m = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (m) {
    const a = +m[1], b = +m[2];
    if (a === 0 || a === 10 || a === 127) return true;
    if (a === 169 && b === 254) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 100 && b >= 64 && b <= 127) return true;
    if (a >= 224) return true;
  }
  return false;
}

const POOL_MAX_UPSTREAMS = 64;

function canonicalRelayUrl(url) {
  if (typeof url !== 'string' || url.length > 512) return null;
  let parsed;
  try { parsed = new URL(url); } catch { return null; }
  if (parsed.protocol !== 'wss:') return null;
  if (parsed.username || parsed.password || parsed.search || parsed.hash) return null;
  if (parsed.port && parsed.port !== '443') return null;
  if (isPrivateRelayHost(parsed.hostname)) return null;
  const path = parsed.pathname === '/' ? '' : parsed.pathname.replace(/\/+$/, '');
  return 'wss://' + parsed.hostname + path;
}

class TokenBucket {
  constructor(capacity, perMinute, now) {
    this.capacity = capacity;
    this.rate = perMinute / 60000;
    this.tokens = capacity;
    this.at = typeof now === 'number' ? now : Date.now();
  }

  take(n, now) {
    const t = typeof now === 'number' ? now : Date.now();
    const units = typeof n === 'number' ? n : 1;
    this.tokens = Math.min(this.capacity, this.tokens + Math.max(0, t - this.at) * this.rate);
    this.at = t;
    if (this.tokens < units) return false;
    this.tokens -= units;
    return true;
  }
}

const EVENT_FRAME_KEYS = ['id', 'pubkey', 'created_at', 'kind', 'tags', 'content', 'sig'];
const RX_EVENT_KEY = /"(id|pubkey|created_at|kind|tags|content|sig)"(\s*):(\s*)/g;

function eventFrameCanonical(raw) {
  if (typeof raw !== 'string' || !raw.startsWith('["EVENT","')) return false;
  const n = raw.length;
  if (raw.charCodeAt(n - 1) !== 93 || raw.charCodeAt(n - 2) !== 125) return false;
  let i = 10;
  while (i < n) {
    const c = raw.charCodeAt(i);
    if (c === 34) break;
    if (c === 92 || c === 123) return false;
    i++;
  }
  if (raw.charCodeAt(i + 1) !== 44 || raw.charCodeAt(i + 2) !== 123) return false;
  const seen = new Set();
  RX_EVENT_KEY.lastIndex = i + 2;
  let m;
  while ((m = RX_EVENT_KEY.exec(raw)) !== null) {
    if (m[2] || m[3] || seen.has(m[1])) return false;
    seen.add(m[1]);
  }
  return seen.size === EVENT_FRAME_KEYS.length;
}

function canonicalEventFrame(raw) {
  if (eventFrameCanonical(raw)) return raw;
  let msg;
  try { msg = JSON.parse(raw); } catch { return null; }
  if (!Array.isArray(msg) || msg.length !== 3 || msg[0] !== 'EVENT' || typeof msg[1] !== 'string') return null;
  const ev = msg[2];
  if (!ev || typeof ev !== 'object' || Array.isArray(ev)) return null;
  const out = JSON.stringify(['EVENT', msg[1], ev]);
  return eventFrameCanonical(out) ? out : null;
}

const RELAY_MESSAGE_TYPES = new Set(['EVENT', 'OK', 'EOSE', 'NOTICE', 'CLOSED', 'AUTH']);

function reframeRelayMessage(raw) {
  let msg;
  try { msg = JSON.parse(raw); } catch { return null; }
  if (!Array.isArray(msg) || typeof msg[0] !== 'string' || !RELAY_MESSAGE_TYPES.has(msg[0])) return null;
  return JSON.stringify(msg);
}

const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;
const VERIFIED_SIG_MAX = 20000;
const verifiedSigs = new Map();

function wellFormedEvent(ev) {
  if (!ev || typeof ev !== 'object' || Array.isArray(ev)) return false;
  if (typeof ev.id !== 'string' || !HEX64.test(ev.id)) return false;
  if (typeof ev.pubkey !== 'string' || !HEX64.test(ev.pubkey)) return false;
  if (typeof ev.sig !== 'string' || !HEX128.test(ev.sig)) return false;
  if (!Number.isSafeInteger(ev.kind) || ev.kind < 0) return false;
  if (!Number.isSafeInteger(ev.created_at) || ev.created_at < 0) return false;
  if (typeof ev.content !== 'string' || !Array.isArray(ev.tags)) return false;
  for (const t of ev.tags) {
    if (!Array.isArray(t)) return false;
    for (const v of t) if (typeof v !== 'string') return false;
  }
  return true;
}

function verifySignedEvent(ev) {
  if (!wellFormedEvent(ev)) return false;
  try {
    if (getEventHash(ev) !== ev.id) return false;
    if (verifiedSigs.get(ev.id) === ev.sig) return true;
    if (!schnorr.verify(ev.sig, ev.id, ev.pubkey)) return false;
  } catch { return false; }
  verifiedSigs.set(ev.id, ev.sig);
  if (verifiedSigs.size > VERIFIED_SIG_MAX) verifiedSigs.delete(verifiedSigs.keys().next().value);
  return true;
}

function verifiedEventJson(objJson, expectId) {
  if (typeof objJson !== 'string') return null;
  let ev;
  try { ev = JSON.parse(objJson); } catch { return null; }
  if (expectId && (!ev || ev.id !== expectId)) return null;
  return verifySignedEvent(ev) ? ev : null;
}

function validatedPowBits(ev) {
  if (!ev || typeof ev.id !== 'string' || !Array.isArray(ev.tags)) return 0;
  const nonce = ev.tags.find((t) => Array.isArray(t) && t[0] === 'nonce');
  if (!nonce || typeof nonce[2] !== 'string' || !/^\d{1,3}$/.test(nonce[2])) return 0;
  const target = parseInt(nonce[2], 10);
  if (target <= 0 || target > 64) return 0;
  let bits = 0;
  for (let i = 0; i < ev.id.length; i++) {
    const v = parseInt(ev.id[i], 16);
    if (v === 0) { bits += 4; continue; }
    bits += Math.clz32(v) - 28;
    break;
  }
  return bits >= target ? target : 0;
}

const ARCHIVE_RATE_WINDOW_MS = 60000;
const ARCHIVE_RATE_MAX_KEYS = 5000;
const ARCHIVE_RATE_LIMITS = { channel: 30, reaction: 60, record: 20, emoji: 6 };
const archiveRates = new Map();

function archiveRateClass(kind) {
  if (kind === 20000 || kind === 23333) return 'channel';
  if (kind === 7) return 'reaction';
  if (kind === 30030 || kind === 10030) return 'emoji';
  return 'record';
}

function archiveRateOk(pubkey, kind, eventId, now) {
  if (typeof pubkey !== 'string' || !pubkey || typeof eventId !== 'string' || eventId.length < 8) return false;
  const cls = archiveRateClass(kind);
  const t = typeof now === 'number' ? now : Date.now();
  const window = Math.floor(t / ARCHIVE_RATE_WINDOW_MS);
  const key = cls + ':' + pubkey;
  let entry = archiveRates.get(key);
  if (!entry || entry.window !== window) {
    if (entry) archiveRates.delete(key);
    entry = { window, ids: new Set() };
    archiveRates.set(key, entry);
    if (archiveRates.size > ARCHIVE_RATE_MAX_KEYS) archiveRates.delete(archiveRates.keys().next().value);
  }
  let tag = 0x811c9dc5;
  for (let i = 0; i < eventId.length; i++) {
    tag ^= eventId.charCodeAt(i);
    tag = Math.imul(tag, 0x01000193);
  }
  if (entry.ids.has(tag)) return true;
  if (entry.ids.size >= ARCHIVE_RATE_LIMITS[cls]) return false;
  entry.ids.add(tag);
  return true;
}

const ARCHIVE_JSON_MAX = { 20000: 32768, 23333: 32768, 7: 4096, 30078: 32768, 30030: 65536, 10030: 65536 };
const VOUCH_JSON_MAX = 65536;
const ARCHIVE_FUTURE_SKEW_S = 600;

function clientIpKey(request) {
  let ip = '';
  try { ip = (request && request.headers && request.headers.get('CF-Connecting-IP')) || ''; } catch { ip = ''; }
  ip = String(ip).trim().slice(0, 64);
  if (!ip) return '';
  if (ip.includes(':')) return ipv6NetKey(ip) || ip;
  return ip;
}

const POOL_CONNECTS_PER_IP_MIN = 120;
const POOL_EVENTS_PER_IP_MIN = 1200;
const POOL_IP_CHARGE_BATCH = 20;

export {
  isPrivateRelayHost, POOL_MAX_UPSTREAMS, canonicalRelayUrl, TokenBucket, eventFrameCanonical,
  canonicalEventFrame, reframeRelayMessage, verifySignedEvent, verifiedEventJson, validatedPowBits,
  archiveRateOk, clientIpKey
};

export async function onRequest(context) {
  const { request, env } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }
  if (!clientOriginAllowed(request, env)) {
    return new Response('Forbidden', { status: 403 });
  }
  const ipKey = clientIpKey(request);
  if (ipKey && !(await cacheRateTake('pool-connect', ipKey, 1, POOL_CONNECTS_PER_IP_MIN, 60000))) {
    return new Response('Too Many Requests', { status: 429 });
  }

  const clientIsNymchat = isNymchatClient(request, env);
  function proxyHost(req) {
    try { return new URL(req.url).hostname.toLowerCase().slice(0, 120); } catch { return ''; }
  }
  const proxySecret = env && env.NYMCHAT_PROXY_SECRET ? env.NYMCHAT_PROXY_SECRET : null;
  let gate = await filterSet(env);
  const spam = spamEngine(env, context);
  let sockHeld = null;

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  // Relay pool state
  const upstreams = new Map();       // relayUrl -> { ws, type, status, eventCount, handled }
  const activeSubscriptions = new Map(); // subId -> raw JSON string of the REQ message
  const subRelays = new Map();       // subId -> Set<relayUrl> the REQ was sent to
  const seenEvents = new Map();      // eventId -> 1 (string-based dedup, no JSON.parse)
  const seenOKs = new Set();         // eventId (only forward first OK per event)
  const seenEOSE = new Set();        // subId (only forward first EOSE per subscription)
  const relayLatency = new Map();    // relayUrl -> latency ms
  let dmRelays = [];
  const relayRole = new Map();       // relayUrl -> 'critical' | 'geo'
  const subRole = new Map();         // subId -> 'critical' | 'geo' | 'all'
  const splitChildren = new Map();   // parentSubId -> [{ childSubId, rawChild, filters }, ...]
  const childToParent = new Map();   // childSubId -> parentSubId
  const kindBlacklist = new Map();
  const closedKindRetries = new Map();   // relayUrl+'\n'+parentSubId -> resend count
  let serverOpen = true;

  const CLIENT_FRAME_MAX = 512 * 1024;
  const UPSTREAM_FRAME_MAX = 1024 * 1024;
  const MAX_ACTIVE_SUBS = 64;
  const MAX_REQ_FILTERS = 30;
  const MAX_SUB_ID = 128;
  const MAX_RELAY_LIST = 256;
  const MAX_KIND_BLACKLIST_RELAYS = 256;
  const MAX_KIND_BLACKLIST_KINDS = 64;
  const PENDING_GEO_PER_RELAY = 50;
  const MAX_PERMANENTLY_SKIPPED = 1000;
  const FORGED_FRAME_LIMIT = 10;
  const eventBucket = new TokenBucket(200, 120);
  const reqBucket = new TokenBucket(200, 120);
  const relaysBucket = new TokenBucket(10, 10);
  const connectBucket = new TokenBucket(128, 64);
  const subActivity = new Map();
  const forgedByRelay = new Map();
  let ipEventUnits = 0;
  let ipEventBlockedUntil = 0;

  // Dedup housekeeping
  const DEDUP_MAX = 50000;
  let dedupCounter = 0;

  const CHANNELS_DB = env && env.DB_CHANNELS;
  const archiveEnabled = !!(CHANNELS_DB && typeof CHANNELS_DB.prepare === 'function');
  const CHANNEL_EVENT_MAX = 64 * 1024;
  const ARCHIVE_FLUSH_MAX = 400;
  const ARCHIVE_BATCH = 100;
  const archiveBuf = new Map();   // eventId -> { id, channel, kind, pubkey, created_at, json }

  // NIP-30 emoji lists (kind 30030 packs, 10030 user lists)
  const EMOJI_EVENT_MAX = 64 * 1024;
  const emojiBuf = new Map();     // coord -> { coord, kind, pubkey, d, created_at, json }
  let emojiSchemaReady = false;
  const isArchivableEmojiKind = (k) => k === 30030 || k === 10030;

  function trimDedup() {
    if (++dedupCounter < 500) return;
    dedupCounter = 0;
    if (seenEvents.size > DEDUP_MAX) {
      const toDelete = seenEvents.size - DEDUP_MAX;
      let deleted = 0;
      for (const key of seenEvents.keys()) {
        if (deleted >= toDelete) break;
        seenEvents.delete(key);
        deleted++;
      }
    }
    if (seenOKs.size > 2000) {
      let deleted = 0;
      for (const key of seenOKs) {
        if (deleted >= 1000) break;
        seenOKs.delete(key);
        deleted++;
      }
    }
    if (seenEOSE.size > 500) {
      let deleted = 0;
      for (const key of seenEOSE) {
        if (deleted >= 250) break;
        seenEOSE.delete(key);
        deleted++;
      }
    }
  }

  // Keepalive: send periodic POOL:PING to prevent Cloudflare idle timeout
  let keepaliveTimer = setInterval(() => {
    try {
      if (serverOpen && server.readyState === 1) {
        server.send(JSON.stringify(['POOL:PING', Date.now()]));
        filterSet(env).then((s) => { gate = s; }, () => { });
        runArchive(flushArchive());
        runArchive(flushEmojiArchive());
      } else {
        clearInterval(keepaliveTimer);
        keepaliveTimer = null;
      }
    } catch {
      clearInterval(keepaliveTimer);
      keepaliveTimer = null;
    }
  }, 30000);

  // Relays that must never be banned, skipped, or backed off
  const APP_RELAY = 'wss://relay.nymchat.app';
  const WRITE_ONLY_RELAYS = new Set(['wss://sendit.nosflare.com']);

  // Track failed relays to avoid wasting cycles
  const failedRelays = new Map();      // relayUrl -> { failedAt, attempts }
  const FAILED_COOLDOWN = 60000;
  const MAX_BACKOFF = 180000;

  // Track reconnection attempts
  const reconnectAttempts = new Map();
  const everConnected = new Set();
  const STABLE_SESSION_MS = 15000;
  const RECONNECT_BASE_MS = 3000;
  const RECONNECT_CAP_MS = 120000;

  // Track relays pending reconnection
  const pendingReconnect = new Set();
  const reconnectTimers = new Map();
  const intentionallyClosed = new Set();
  // Relays that returned auth-required / unsupported-query CLOSED; never reconnect
  const permanentlySkipped = new Set();

  // Buffered GEO_EVENTs waiting for geo relays to connect
  // Map<relayUrl, Array<geoMsg string>>
  const pendingGeoEvents = new Map();

  // Bounded connection establishment. Cloudflare allows only 6 connections to
  // be establishing (waiting for headers) at once; with the whole relay set on
  // one socket we must not fire every WebSocket synchronously or queued ones
  // would hit their connect timeout before they even start.
  let connectionTimer = null;
  let connectionQueue = [];
  const MAX_CONCURRENT_CONNECTS = 6;
  const MAX_UPSTREAMS = POOL_MAX_UPSTREAMS;
  let inFlightConnects = 0;
  const pendingConnect = new Set();

  // Throttle pool status updates
  let statusTimer = null;
  function schedulePoolStatus() {
    if (statusTimer) return;
    statusTimer = setTimeout(() => {
      statusTimer = null;
      sendPoolStatus();
    }, 300);
  }

  function sendToClient(data) {
    try {
      if (serverOpen && server.readyState === 1) {
        server.send(typeof data === 'string' ? data : JSON.stringify(data));
      }
    } catch {
      // Client disconnected
    }
  }

  function sendPoolStatus() {
    const connected = [];
    const latency = {};
    upstreams.forEach((info, url) => {
      if (info.status === 'connected') connected.push(url);
    });
    // Only include latency for connected relays. Per-relay event counts are
    // omitted — the client tracks its own post-dedup counts.
    relayLatency.forEach((ms, url) => {
      if (connected.includes(url)) latency[url] = ms;
    });
    sendToClient(JSON.stringify(['POOL:STATUS', {
      connected,
      count: connected.length,
      latency,
      badgeGate: spam.badgeGate(),
      unbadged: droppedUnbadgedCount,
      droppedSpam: droppedSpamCount,
      droppedForged: droppedForgedCount
    }]));
  }

  function shouldSkipRelay(relayUrl) {
    if (relayUrl === APP_RELAY) return false;
    // Permanent skip: relays that have rejected us with auth-required,
    // unsupported filter shape, etc. won't recover, don't retry.
    if (permanentlySkipped.has(relayUrl)) return true;
    const failure = failedRelays.get(relayUrl);
    if (failure) {
      const backoff = Math.min(FAILED_COOLDOWN * Math.pow(2, failure.attempts - 1), MAX_BACKOFF);
      if (Date.now() - failure.failedAt < backoff) return true;
      failedRelays.delete(relayUrl);
    }
    return false;
  }

  function isPermanentRejection(reason) {
    if (typeof reason !== 'string') return false;
    return /auth[\s\-_:]*required/i.test(reason)
      || /\bauthentic/i.test(reason)
      || /nip-?42/i.test(reason)
      || /\bblocked\b/i.test(reason)
      || /\bbanned\b/i.test(reason)
      || /\brestricted\b/i.test(reason)
      || /\bforbidden\b/i.test(reason)
      || /\bunauthorized\b/i.test(reason)
      || /\bunsupported\b/i.test(reason)
      || /payment[\s\-_:]*required/i.test(reason)
      || /\bpaid\b/i.test(reason)
      || /\bpow\b/i.test(reason)
      || /\bprotected\b/i.test(reason)
      || /must have ['"]?h['"]?,?\s*['"]?e['"]?\s*or\s*['"]?a['"]?\s*tag/i.test(reason)
      || /\binvalid query\b/i.test(reason)
      || /\bNIP[\s\-_:]*\d+\b/i.test(reason)
      || /\bnot\s+whitelisted\b/i.test(reason)
      || /\bauthor[\s\-_]+banned\b/i.test(reason)
      || /\bnot\s+allowed\b/i.test(reason)
      || /(does\s+not\s+have\s+permission|no\s+permission|permission\s+to\s+write)/i.test(reason)
      || /\bonly\s+members\b/i.test(reason)
      || /out\s+of\s+time\b/i.test(reason)
      || /\btop[\s\-]?up\b/i.test(reason)
      || /\baccepted\s+(repository|event)\b/i.test(reason)
      || /\bmust\s+reference\b/i.test(reason)
      || /\bweb\s+of\s+trust\b/i.test(reason)
      || /\bpolicy\s+violated\b/i.test(reason)
      || /\blow\s+trust\b/i.test(reason);
  }

  function isUnsupportedKind(reason) {
    if (typeof reason !== 'string') return false;
    return /kinds?\s*not\s*supported/i.test(reason)
      || /\bNIP[\s\-_:]*\d+\b/i.test(reason)
      || /\bkinds?[\s\-_:]*\d+\b/i.test(reason);
  }

  function extractRejectedKind(reason) {
    if (typeof reason !== 'string') return null;
    let m = reason.match(/\bNIP[\s\-_:]*(\d+)\b/i);
    if (m) return parseInt(m[1], 10);
    m = reason.match(/\bkinds?[\s\-_:]*(\d+)\b/i);
    if (m) return parseInt(m[1], 10);
    return null;
  }

  function stripKindsFromReq(rawReq, blockedKinds) {
    try {
      const reqMsg = JSON.parse(rawReq);
      if (!Array.isArray(reqMsg) || reqMsg[0] !== 'REQ') return null;
      const newFilters = [];
      let modified = false;
      for (let i = 2; i < reqMsg.length; i++) {
        const f = reqMsg[i];
        if (f && Array.isArray(f.kinds)) {
          const kept = f.kinds.filter(k => !blockedKinds.has(k));
          if (kept.length === f.kinds.length) {
            newFilters.push(f);
          } else if (kept.length > 0) {
            newFilters.push({ ...f, kinds: kept });
            modified = true;
          } else {
            modified = true;
          }
        } else {
          newFilters.push(f);
        }
      }
      if (!modified) return null;
      if (newFilters.length === 0) return '';
      return JSON.stringify(['REQ', reqMsg[1], ...newFilters]);
    } catch { return null; }
  }

  // Upstream relays reject REQs with more than ~10 filters ("too many filters").
  // Split an over-sized REQ into child subscriptions of <= MAX_FILTERS_PER_REQ
  // filters each so no single upstream REQ trips that limit.
  const MAX_FILTERS_PER_REQ = 10;

  function buildChildrenForParent(parentSubId, msg) {
    if (!Array.isArray(msg)) return null;
    const filters = msg.slice(2);
    if (filters.length <= MAX_FILTERS_PER_REQ) return null;
    const children = [];
    for (let i = 0; i < filters.length; i += MAX_FILTERS_PER_REQ) {
      const chunk = filters.slice(i, i + MAX_FILTERS_PER_REQ);
      const childSubId = `${parentSubId}~c${i / MAX_FILTERS_PER_REQ}`;
      const rawChild = JSON.stringify(['REQ', childSubId, ...chunk]);
      children.push({ childSubId, rawChild, filters: chunk });
    }
    return children;
  }

  function buildChildPayload(child, blockedKinds) {
    const filters = child.filters;
    if (!filters || filters.length === 0) return null;
    if (!blockedKinds || blockedKinds.size === 0) return child.rawChild;
    const newFilters = [];
    let modified = false;
    for (const f of filters) {
      if (f && Array.isArray(f.kinds)) {
        const kept = f.kinds.filter(k => !blockedKinds.has(k));
        if (kept.length === 0) { modified = true; continue; }
        if (kept.length < f.kinds.length) {
          newFilters.push({ ...f, kinds: kept });
          modified = true;
        } else {
          newFilters.push(f);
        }
      } else {
        newFilters.push(f);
      }
    }
    if (newFilters.length === 0) return null;
    if (!modified) return child.rawChild;
    return JSON.stringify(['REQ', child.childSubId, ...newFilters]);
  }

  function isRelayWideRejection(reason) {
    if (typeof reason !== 'string') return false;
    return /auth[\s\-_:]*required/i.test(reason)
      || /\bauthentic/i.test(reason)
      || /nip-?42/i.test(reason)
      || /\bblocked\b/i.test(reason)
      || /\brestricted\b/i.test(reason)
      || /\bbanned\b/i.test(reason)
      || /\bforbidden\b/i.test(reason)
      || /\bunauthorized\b/i.test(reason)
      || /payment[\s\-_:]*required/i.test(reason)
      || /\bpaid\b/i.test(reason)
      || /must have ['"]?h['"]?,?\s*['"]?e['"]?\s*or\s*['"]?a['"]?\s*tag/i.test(reason)
      || /\binvalid query\b/i.test(reason)
      || /\bnot\s+whitelisted\b/i.test(reason)
      || /\bauthor[\s\-_]+banned\b/i.test(reason)
      || /\bnot\s+allowed\b/i.test(reason)
      || /(does\s+not\s+have\s+permission|no\s+permission|permission\s+to\s+write)/i.test(reason)
      || /\bonly\s+members\b/i.test(reason)
      || /out\s+of\s+time\b/i.test(reason)
      || /\btop[\s\-]?up\b/i.test(reason)
      || /\baccepted\s+(repository|event)\b/i.test(reason)
      || /\bmust\s+reference\b/i.test(reason)
      || /\bweb\s+of\s+trust\b/i.test(reason)
      || /\bpolicy\s+violated\b/i.test(reason)
      || /\bonly\s+(serves|accepts|supports)\b/i.test(reason)
      || /\blow\s+trust\b/i.test(reason);
  }

  function trackRelayFailure(relayUrl) {
    if (relayUrl === APP_RELAY) return;
    const existing = failedRelays.get(relayUrl);
    const attempts = existing ? existing.attempts + 1 : 1;
    failedRelays.set(relayUrl, { failedAt: Date.now(), attempts });
    if (attempts >= 5 && !everConnected.has(relayUrl)) {
      markPermanentlySkipped(relayUrl, 'connection-failed: repeated failures');
    }
  }

  function retryAfterFailure(relayUrl, type) {
    if (isProtectedRelay(relayUrl) || everConnected.has(relayUrl)) {
      scheduleReconnect(relayUrl, type);
    }
  }

  function clearRelayFailure(relayUrl) {
    failedRelays.delete(relayUrl);
  }

  function validateRelayUrl(url) {
    return canonicalRelayUrl(url) === url;
  }

  // Extract Nostr event ID from raw JSON string without JSON.parse.
  // Searches for "id":" AFTER the first '{' (start of the event object)
  // to avoid false matches in subscription IDs or other envelope fields.
  // Validates the extracted ID is exactly 64 characters (Nostr event ID length).
  function extractEventId(raw) {
    const braceIdx = raw.indexOf('{');
    if (braceIdx === -1) return null;
    const idx = raw.indexOf('"id":"', braceIdx);
    if (idx === -1) return null;
    const start = idx + 6;
    const end = raw.indexOf('"', start);
    if (end === -1 || end - start !== 64) return null; // Nostr event IDs are exactly 64 hex chars
    return raw.substring(start, end);
  }

  // Extract a JSON string field from an event object embedded in a raw frame.
  // Limited to the substring after the first '{' so it skips envelope fields.
  // Returns the decoded value (handling common \" / \\ / \n escapes) or null.
  function extractEventStringField(raw, fieldName) {
    const braceIdx = raw.indexOf('{');
    if (braceIdx === -1) return null;
    const key = '"' + fieldName + '":"';
    const idx = raw.indexOf(key, braceIdx);
    if (idx === -1) return null;
    let i = idx + key.length;
    let out = '';
    const max = Math.min(raw.length, i + 4096);
    while (i < max) {
      const c = raw.charCodeAt(i);
      if (c === 92) {
        const n = raw.charCodeAt(i + 1);
        if (n === 110) out += '\n';
        else if (n === 116) out += '\t';
        else if (n === 114) out += '\r';
        else if (n === 117) {
          out += String.fromCharCode(parseInt(raw.substring(i + 2, i + 6), 16) || 0);
          i += 6; continue;
        } else out += raw[i + 1];
        i += 2; continue;
      }
      if (c === 34) return out;
      out += raw[i];
      i++;
    }
    return out;
  }

  function extractEventKind(raw) {
    const braceIdx = raw.indexOf('{');
    if (braceIdx === -1) return -1;
    const idx = raw.indexOf('"kind":', braceIdx);
    if (idx === -1) return -1;
    let i = idx + 7;
    while (raw.charCodeAt(i) === 32) i++;
    let n = 0;
    let saw = false;
    while (i < raw.length) {
      const c = raw.charCodeAt(i);
      if (c < 48 || c > 57) break;
      n = n * 10 + (c - 48);
      saw = true;
      i++;
    }
    return saw ? n : -1;
  }

  // Find a tag value in the raw "tags":[["n","<value>"], ...] structure.
  // Conservative pattern match keyed on `["<tagName>","` — no JSON.parse.
  function extractTagValue(raw, tagName) {
    const braceIdx = raw.indexOf('{');
    if (braceIdx === -1) return null;
    const tagsIdx = raw.indexOf('"tags":', braceIdx);
    if (tagsIdx === -1) return null;
    const needle = '["' + tagName + '","';
    const idx = raw.indexOf(needle, tagsIdx);
    if (idx === -1) return null;
    const start = idx + needle.length;
    const end = raw.indexOf('"', start);
    if (end === -1 || end - start > 256) return null;
    return raw.substring(start, end);
  }

  function tagNeedleIndex(raw, tagName) {
    const braceIdx = raw.indexOf('{');
    if (braceIdx === -1) return -1;
    const tagsIdx = raw.indexOf('"tags":', braceIdx);
    if (tagsIdx === -1) return -1;
    return raw.indexOf('["' + tagName + '","', tagsIdx);
  }

  function hasTag(raw, tagName) {
    return tagNeedleIndex(raw, tagName) !== -1;
  }

  function countTags(raw, tagName) {
    let idx = tagNeedleIndex(raw, tagName);
    if (idx === -1) return 0;
    const needle = '["' + tagName + '","';
    let n = 0;
    while (idx !== -1 && n < 64) {
      n++;
      idx = raw.indexOf(needle, idx + needle.length);
    }
    return n;
  }

  // Numeric created_at from an event frame, without JSON.parse.
  function extractEventCreatedAt(raw) {
    const braceIdx = raw.indexOf('{');
    if (braceIdx === -1) return 0;
    const idx = raw.indexOf('"created_at":', braceIdx);
    if (idx === -1) return 0;
    let i = idx + 13;
    while (raw.charCodeAt(i) === 32) i++;
    let n = 0, saw = false;
    while (i < raw.length) {
      const c = raw.charCodeAt(i);
      if (c < 48 || c > 57) break;
      n = n * 10 + (c - 48); saw = true; i++;
    }
    return saw ? n : 0;
  }

  // The event object is the last element of ["EVENT","subId",{...}].
  function extractEventObjectJson(raw) {
    const start = raw.indexOf('{');
    if (start === -1) return null;
    const end = raw.lastIndexOf('}');
    if (end <= start) return null;
    return raw.substring(start, end + 1);
  }

  function sanitizeChannelKey(name) {
    if (typeof name !== 'string') return '';
    if (/\s/.test(name)) return '';
    return name.toLowerCase().replace(/[^\p{L}\p{N}_\-.]/gu, '').slice(0, 80);
  }

  const isArchivableChannelKind = (k) => k === 20000 || k === 23333 || k === 7 || k === 30078;
  const ARCHIVE_RECORD_TOPICS = new Set(['nym-poll', 'nym-poll-vote', 'nym-vouches', 'nym-pq']);
  const RX_GEOHASH_KEY = /^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/;

  // Channel name for an event: 'g' for geohash (20000), 'd' for named (23333),
  // either for reactions (7) and polls (30078).
  function channelFromTags(getTag, kind) {
    if (kind === 20000) return getTag('g');
    if (kind === 23333) return getTag('d');
    return getTag('g') || getTag('d');
  }

  function channelKeyFor(kind, getTag) {
    if (kind === 20000) {
      const key = sanitizeChannelKey(getTag('g'));
      return RX_GEOHASH_KEY.test(key) ? key : '';
    }
    if (kind === 23333) {
      const key = sanitizeChannelKey(getTag('d'));
      return key && !RX_GEOHASH_KEY.test(key) ? key : '';
    }
    const g = getTag('g');
    if (g) {
      const key = sanitizeChannelKey(g);
      return RX_GEOHASH_KEY.test(key) ? key : '';
    }
    return sanitizeChannelKey(getTag('d'));
  }

  function archiveChannelOf(kind, getTag) {
    if (!isArchivableChannelKind(kind)) return '';
    if (kind === 30078 && !ARCHIVE_RECORD_TOPICS.has(getTag('t'))) return '';
    return channelKeyFor(kind, getTag);
  }

  function archiveJsonMax(kind, getTag) {
    if (kind === 30078 && getTag('t') === 'nym-vouches') return VOUCH_JSON_MAX;
    return ARCHIVE_JSON_MAX[kind] || CHANNEL_EVENT_MAX;
  }

  function evTagReader(ev) {
    const tags = ev && Array.isArray(ev.tags) ? ev.tags : [];
    return (n) => {
      const t = tags.find((x) => Array.isArray(x) && x[0] === n && typeof x[1] === 'string');
      return t ? t[1] : null;
    };
  }

  // How many extra relays one event reports before the notes stop. Past a
  // handful the list tells a reader nothing new, and the cap is what keeps a
  // widely-relayed event from costing one frame per relay.
  const SEEN_REPORT_CAP = 8;
  // Only the kinds a person can open the details panel on.
  const isSeenReportKind = (k) => k === 20000 || k === 23333 || k === 7;

  const APP_RELAY_ONLY_CHANNEL = 'nymchat';
  // Every kind that names a channel and shows up in it: the message itself, and
  // the reactions, polls, typing strips and read receipts that hang off it.
  // Gating only the messages would leave four other ways to put a nym and a
  // payload in front of everyone in #nymchat.
  const APP_RELAY_ONLY_KINDS = new Set([23333, 7, 30078, 24420, 24421]);

  function isAppChannelOnly(kind, getTag) {
    if (!APP_RELAY_ONLY_KINDS.has(kind)) return false;
    // Same derivation as channelFromTags: 'd' names a named channel, and the
    // hangers-on may carry either tag.
    const name = kind === 23333 ? getTag('d') : (getTag('g') || getTag('d'));
    return !!name && name.toLowerCase() === APP_RELAY_ONLY_CHANNEL;
  }

  function isForeignAppChannelEvent(raw, relayUrl) {
    if (relayUrl === APP_RELAY) return false;
    return isAppChannelOnly(extractEventKind(raw), (n) => extractTagValue(raw, n));
  }

  function isAppRelayOnlyEvent(ev) {
    if (!ev || typeof ev.kind !== 'number') return false;
    return isAppChannelOnly(ev.kind, evTagReader(ev));
  }

  const PENDING_APP_ARCHIVE_MAX = 200;
  const pendingAppArchive = new Map();
  const ARCHIVE_VETO_MAX = 2000;
  const archiveVetoed = new Set();
  const OUTBOUND_ARCHIVED_MAX = 500;
  const outboundArchived = new Map();

  function runArchive(work) {
    if (context && context.waitUntil) { try { context.waitUntil(work); } catch { /* noop */ } }
  }

  function bufferArchive(channel, eventId, kind, pubkey, createdAt, objJson) {
    if (!channel || !eventId || !objJson || objJson.length > CHANNEL_EVENT_MAX) return false;
    if (archiveBuf.has(eventId) || archiveVetoed.has(eventId)) return false;
    archiveBuf.set(eventId, { id: eventId, channel, kind, pubkey: pubkey || null, created_at: createdAt || 0, json: objJson });
    if (archiveBuf.size >= ARCHIVE_FLUSH_MAX) runArchive(flushArchive());
    return true;
  }

  function vetoArchive(eventId) {
    if (!eventId) return;
    archiveBuf.delete(eventId);
    archiveVetoed.add(eventId);
    if (archiveVetoed.size > ARCHIVE_VETO_MAX) archiveVetoed.delete(archiveVetoed.values().next().value);
    const pubkey = outboundArchived.get(eventId);
    if (pubkey === undefined) return;
    outboundArchived.delete(eventId);
    if (archiveEnabled) {
      runArchive(CHANNELS_DB.prepare('DELETE FROM events WHERE id = ? AND pubkey = ?').bind(eventId, pubkey).run().catch(() => null));
    }
  }

  // The relay directory, loaded once per isolate. Held in a plain variable so
  // the archive path can stay synchronous; null until the first load lands,
  // and null means admit everything.
  let geoDirectory = null;
  runArchive((async () => { geoDirectory = await loadGeoDirectory(); })());
  const GEO_ALLOW_CACHE_MAX = 512;
  let geoAllowCache = new Map();
  let geoAllowDirectory = null;

  function geoAllowSet(geohash) {
    if (geoAllowDirectory !== geoDirectory) {
      geoAllowCache = new Map();
      geoAllowDirectory = geoDirectory;
    }
    let allow = geoAllowCache.get(geohash);
    if (!allow) {
      allow = new Set(closestRelayUrls(geohash, geoDirectory));
      geoAllowCache.set(geohash, allow);
      if (geoAllowCache.size > GEO_ALLOW_CACHE_MAX) geoAllowCache.delete(geoAllowCache.keys().next().value);
    }
    return allow;
  }

  // Fails open on an unloaded directory or an undecodable geohash. In proxy
  // mode the pool holds the whole directory, so the neighbourhood is always
  // connected and there is no third case to fail open on.
  function geoOriginAllowsFrame(raw, kind, relayUrl) {
    if (kind !== 20000) return true;
    if (!geoDirectory || typeof relayUrl !== 'string' || !relayUrl) return true;
    const geohash = extractTagValue(raw, 'g');
    if (!geohash) return true;
    const allow = geoAllowSet(geohash.toLowerCase());
    if (!allow.size) return true;
    return allow.has(relayUrl);
  }

  // Inbound event from a relay (string frame).
  function archiveInboundEvent(raw, kind, eventId) {
    if (!archiveEnabled || !eventId) return;
    const getTag = (n) => extractTagValue(raw, n);
    const channel = archiveChannelOf(kind, getTag);
    if (!channel) return;
    const objJson = extractEventObjectJson(raw);
    if (!objJson || objJson.length > archiveJsonMax(kind, getTag)) return;
    if (archiveBuf.has(eventId) || archiveVetoed.has(eventId)) return;
    const pubkey = extractEventStringField(raw, 'pubkey');
    if (!archiveRateOk(pubkey, kind, eventId)) return;
    bufferArchive(channel, eventId, kind, pubkey, extractEventCreatedAt(raw), objJson);
  }

  // A NIP-09 deletion (kind 5) removes the referenced events from the channel
  // archive so they don't resurface in D1 backfill. Verified, and scoped to the
  // deleter's own events.
  function deleteArchivedFromDeletion(raw) {
    if (!archiveEnabled) return;
    const objJson = extractEventObjectJson(raw);
    if (objJson) runArchive(applyArchiveDeletion(objJson));
  }

  async function applyArchiveDeletion(objJson) {
    try {
      const ev = verifiedEventJson(objJson);
      if (!ev || ev.kind !== 5) return;
      const targets = ev.tags
        .filter((t) => Array.isArray(t) && t[0] === 'e' && typeof t[1] === 'string')
        .map((t) => t[1].toLowerCase())
        .filter((t) => /^[0-9a-f]{64}$/.test(t))
        .slice(0, 100);
      if (!targets.length) return;
      const ph = targets.map(() => '?').join(',');
      await CHANNELS_DB.prepare(
        'DELETE FROM events WHERE pubkey = ? AND id IN (' + ph + ')'
      ).bind(ev.pubkey, ...targets).run();
    } catch { /* best-effort */ }
  }

  function outboundChannelRefused(ev) {
    if (ev.kind !== 20000 && ev.kind !== 23333) return false;
    if (typeof ev.content !== 'string' || typeof ev.pubkey !== 'string') return true;
    if (spam.isHidden(ev.id) || spam.isMuted(ev.pubkey)) return true;
    const frame = JSON.stringify(['EVENT', '', ev]);
    if (hasBlockedContentPrefix(frame) || isGlubClientFrame(frame)) return true;
    return isSpamEventFrame(frame, false);
  }

  // Outbound event the client is publishing — archived immediately so sends
  // land in D1 without waiting for the relay echo (deduped, so saved once).
  function archiveOutgoingEvent(ev) {
    if (!archiveEnabled || !ev || typeof ev.id !== 'string' || !isArchivableChannelKind(ev.kind)) return;
    if (typeof ev.pubkey !== 'string') return;
    const getTag = evTagReader(ev);
    const channel = archiveChannelOf(ev.kind, getTag);
    if (!channel) return;
    if (archiveBuf.has(ev.id) || archiveVetoed.has(ev.id)) return;
    const json = JSON.stringify(ev);
    if (json.length > archiveJsonMax(ev.kind, getTag)) return;
    if (outboundChannelRefused(ev)) return;
    if (isAppRelayOnlyEvent(ev)) {
      if (pendingAppArchive.size >= PENDING_APP_ARCHIVE_MAX) {
        pendingAppArchive.delete(pendingAppArchive.keys().next().value);
      }
      pendingAppArchive.set(ev.id, { channel, ev });
      return;
    }
    if (!archiveRateOk(ev.pubkey, ev.kind, ev.id)) return;
    if (bufferArchive(channel, ev.id, ev.kind, ev.pubkey,
      typeof ev.created_at === 'number' ? ev.created_at : 0, json)) {
      outboundArchived.set(ev.id, ev.pubkey);
      if (outboundArchived.size > OUTBOUND_ARCHIVED_MAX) outboundArchived.delete(outboundArchived.keys().next().value);
    }
  }

  function settleAppArchive(eventId, accepted) {
    const held = pendingAppArchive.get(eventId);
    if (!held) return false;
    pendingAppArchive.delete(eventId);
    if (!accepted) return false;
    const ev = held.ev;
    if (!archiveRateOk(ev.pubkey, ev.kind, ev.id)) return false;
    return bufferArchive(held.channel, ev.id, ev.kind, typeof ev.pubkey === 'string' ? ev.pubkey : null,
      typeof ev.created_at === 'number' ? ev.created_at : 0, JSON.stringify(ev));
  }

  // Verify id hash + schnorr signature before persisting so forged events can't
  // be archived to D1. Bounded work: runs once per unique event in the
  // background flush.
  function archiveRowFrom(buffered, nowSec) {
    const ev = verifiedEventJson(buffered.json, buffered.id);
    if (!ev || ev.created_at > nowSec + ARCHIVE_FUTURE_SKEW_S) return null;
    const getTag = evTagReader(ev);
    const channel = archiveChannelOf(ev.kind, getTag);
    if (!channel || channel !== buffered.channel) return null;
    const json = JSON.stringify(ev);
    if (json.length > archiveJsonMax(ev.kind, getTag)) return null;
    return { id: ev.id, channel, kind: ev.kind, pubkey: ev.pubkey, created_at: ev.created_at, json };
  }

  // Flush buffered events as batched INSERT OR IGNORE statements. The id primary
  // key drops duplicates; an occasional failed flush is backfilled by relays.
  async function flushArchive() {
    if (!archiveEnabled || archiveBuf.size === 0) return;
    const buffered = Array.from(archiveBuf.values());
    archiveBuf.clear();

    // INSERT OR IGNORE dedupes on the id PK; no Cache layer needed.
    const stmt = CHANNELS_DB.prepare(
      'INSERT OR IGNORE INTO events (id, channel, kind, pubkey, created_at, json, stored_at) VALUES (?, ?, ?, ?, ?, ?, ?)'
    );
    const now = Date.now();
    const nowSec = Math.floor(now / 1000);
    for (let i = 0; i < buffered.length; i += ARCHIVE_BATCH) {
      const slice = [];
      for (const b of buffered.slice(i, i + ARCHIVE_BATCH)) {
        if (spam.isHidden(b.id) || archiveVetoed.has(b.id)) continue;
        const row = archiveRowFrom(b, nowSec);
        if (row) slice.push(row);
      }
      if (slice.length === 0) continue;
      const hidden = await hiddenEventIds(env, slice.map((r) => r.id));
      const keep = hidden.size ? slice.filter((r) => !hidden.has(r.id)) : slice;
      if (keep.length === 0) continue;
      const chunk = keep.map(
        (r) => stmt.bind(r.id, r.channel, r.kind, r.pubkey, r.created_at, r.json, now)
      );
      try { await CHANNELS_DB.batch(chunk); } catch { /* best-effort */ }
    }
  }

  function bufferEmoji(coord, kind, pubkey, dTag, createdAt, objJson, eventId) {
    if (!coord || !objJson || objJson.length > EMOJI_EVENT_MAX) return;
    const existing = emojiBuf.get(coord);
    if (existing && existing.created_at >= createdAt) return;
    if (!archiveRateOk(pubkey, kind, eventId)) return;
    emojiBuf.set(coord, { coord, kind, pubkey, d: dTag || null, created_at: createdAt || 0, json: objJson });
    if (emojiBuf.size >= 200) runArchive(flushEmojiArchive());
  }

  function emojiCoord(kind, pubkey, dTag) {
    if (!pubkey) return null;
    if (typeof dTag === 'string' && /\s/.test(dTag)) return null;
    return kind + ':' + pubkey + ':' + (kind === 30030 ? (dTag || '') : '');
  }

  function archiveInboundEmoji(raw, kind) {
    if (!archiveEnabled) return;
    const pubkey = extractEventStringField(raw, 'pubkey');
    const coord = emojiCoord(kind, pubkey, extractTagValue(raw, 'd'));
    if (!coord) return;
    const objJson = extractEventObjectJson(raw);
    if (!objJson) return;
    bufferEmoji(coord, kind, pubkey, extractTagValue(raw, 'd'), extractEventCreatedAt(raw), objJson, extractEventId(raw));
  }

  function archiveOutgoingEmoji(ev) {
    if (!archiveEnabled || !ev || !isArchivableEmojiKind(ev.kind) || typeof ev.pubkey !== 'string') return;
    const dTag = evTagReader(ev)('d');
    const coord = emojiCoord(ev.kind, ev.pubkey, dTag);
    if (!coord) return;
    bufferEmoji(coord, ev.kind, ev.pubkey, dTag, typeof ev.created_at === 'number' ? ev.created_at : 0, JSON.stringify(ev), ev.id);
  }

  async function ensureEmojiSchema() {
    if (emojiSchemaReady) return;
    await CHANNELS_DB.prepare(
      'CREATE TABLE IF NOT EXISTS emoji_packs (coord TEXT PRIMARY KEY, kind INTEGER NOT NULL, ' +
      'pubkey TEXT NOT NULL, d TEXT, created_at INTEGER NOT NULL, json TEXT NOT NULL, stored_at INTEGER NOT NULL)'
    ).run();
    emojiSchemaReady = true;
  }

  function emojiRowFrom(buffered, nowSec) {
    const ev = verifiedEventJson(buffered.json);
    if (!ev || !isArchivableEmojiKind(ev.kind) || ev.created_at > nowSec + ARCHIVE_FUTURE_SKEW_S) return null;
    const dTag = evTagReader(ev)('d');
    const coord = emojiCoord(ev.kind, ev.pubkey, dTag);
    if (!coord || coord !== buffered.coord) return null;
    const json = JSON.stringify(ev);
    if (json.length > EMOJI_EVENT_MAX) return null;
    return { coord, kind: ev.kind, pubkey: ev.pubkey, d: dTag || null, created_at: ev.created_at, json };
  }

  // Newest-wins upsert keyed by replaceable-event coordinate.
  async function flushEmojiArchive() {
    if (!archiveEnabled || emojiBuf.size === 0) return;
    const nowSec = Math.floor(Date.now() / 1000);
    const rows = Array.from(emojiBuf.values()).map((b) => emojiRowFrom(b, nowSec)).filter(Boolean);
    emojiBuf.clear();
    if (rows.length === 0) return;
    try { await ensureEmojiSchema(); } catch { return; }
    const stmt = CHANNELS_DB.prepare(
      'INSERT INTO emoji_packs (coord, kind, pubkey, d, created_at, json, stored_at) VALUES (?, ?, ?, ?, ?, ?, ?) ' +
      'ON CONFLICT(coord) DO UPDATE SET kind = excluded.kind, d = excluded.d, created_at = excluded.created_at, ' +
      'json = excluded.json, stored_at = excluded.stored_at WHERE emoji_packs.created_at < excluded.created_at'
    );
    const now = Date.now();
    for (let i = 0; i < rows.length; i += ARCHIVE_BATCH) {
      const chunk = rows.slice(i, i + ARCHIVE_BATCH).map(
        (r) => stmt.bind(r.coord, r.kind, r.pubkey, r.d, r.created_at, r.json, now)
      );
      try { await CHANNELS_DB.batch(chunk); } catch { /* best-effort */ }
    }
  }

  // Mirror of the client-side _looksLikeRandomToken heuristic.
  // Recognizes nanoid-style spam strings like "IBLm9lyTuP", "AJvgLLPASR".
  function looksLikeRandomToken(token) {
    if (!token || token.length < 8) return false;
    if (!/^[A-Za-z0-9]+$/.test(token)) return false;

    const hasUpper = /[A-Z]/.test(token);
    const hasLower = /[a-z]/.test(token);

    const half = Math.floor(Math.min(token.length, REPEAT_SCAN_MAX) / 2);
    for (let unit = 3; unit <= half; unit++) {
      const head = token.substring(0, unit);
      if (token.substring(unit, unit * 2) === head) {
        if (new Set(head).size >= 3) return true;
      }
    }

    if (hasUpper && hasLower) {
      let interiorUpper = 0;
      for (let i = 1; i < token.length; i++) {
        const c = token.charCodeAt(i);
        if (c >= 65 && c <= 90) interiorUpper++;
      }
      if ((interiorUpper / (token.length - 1)) >= 0.2) return true;
    }

    return false;
  }

  const REPEAT_SCAN_MAX = 256;
  const RX_ZERO_WIDTH = /[\u200B\u200C\u200E\u200F\u202A-\u202E\u2060-\u206F\uFEFF]/g;
  const RARE_BIGRAMS = ['xw','xz','xj','xk','wx','wz','wj','wq','jq','jx','jz','kq','kx','kz','vq','vx','vz','zx','zk','zp','pq','pz','fq','fz','gq','gz','hq','hz'];

  function scoreSingleAlphanumWord(token) {
    if (!/^[A-Za-z0-9]{8,}$/.test(token)) return 0;
    let score = 1;
    const lower = token.toLowerCase();
    const hasDigit = /[0-9]/.test(token);
    if (hasDigit && /[A-Za-z]/.test(token)) score += 1;
    if (/[A-Z]/.test(token.substring(1))) score += 1;
    if (/[a-z][A-Z]/.test(token)) score += 1;
    const vowelCount = (lower.match(/[aeiou]/g) || []).length;
    if (vowelCount / token.length <= 0.2) score += 1;
    if (/q(?!u)/i.test(token)) score += 2;
    let rare = 0;
    for (const bg of RARE_BIGRAMS) {
      if (lower.includes(bg)) rare++;
    }
    if (rare > 0) score += Math.min(rare, 2);
    return score;
  }

  function hasMixedScriptToken(text) {
    for (const tok of text.split(/\s+/)) {
      if (tok.length < 4) continue;
      const hasLatin = /[A-Za-z]/.test(tok);
      const hasCyrillic = /[Ѐ-ӿ]/.test(tok);
      const hasGreek = /[Ͱ-Ͽ]/.test(tok);
      const scripts = (hasLatin ? 1 : 0) + (hasCyrillic ? 1 : 0) + (hasGreek ? 1 : 0);
      if (scripts < 2) continue;
      const letterCount = (tok.match(/[A-Za-zЀ-ӿͰ-Ͽ]/g) || []).length;
      if (letterCount / tok.length < 0.6) continue;
      return true;
    }
    return false;
  }

  function hasRepeatedTokenSpam(trimmed) {
    const tokens = trimmed.split(/\s+/).filter(Boolean);
    if (tokens.length >= 2) {
      const first = tokens[0];
      if (first.length >= 6 && /^[A-Za-z0-9]+$/.test(first) &&
          tokens.every(t => t === first)) {
        return true;
      }
      const baseLen = Math.min(...tokens.map(t => t.length));
      if (baseLen >= 6) {
        const base = tokens.find(t => t.length === baseLen);
        if (base && /^[A-Za-z0-9]+$/.test(base) && tokens.every(t => {
          if (t.length % baseLen !== 0) return false;
          for (let i = 0; i < t.length; i += baseLen) {
            if (t.substring(i, i + baseLen) !== base) return false;
          }
          return true;
        })) {
          return true;
        }
      }
    }
    if (tokens.length === 1 && tokens[0].length >= 12 && /^[A-Za-z0-9]+$/.test(tokens[0])) {
      const t = tokens[0];
      for (let unit = 4; unit <= Math.floor(Math.min(t.length, REPEAT_SCAN_MAX) / 2); unit++) {
        const head = t.substring(0, unit);
        if (t.substring(unit, unit * 2) === head && new Set(head).size >= 3) return true;
      }
    }
    return false;
  }

  function spamScore(trimmed) {
    let score = 0;

    trimmed = trimmed.replace(RX_ZERO_WIDTH, '');
    if (hasRepeatedTokenSpam(trimmed)) score += 3;
    if (hasMixedScriptToken(trimmed)) score += 2;

    const tokens = trimmed.split(/\s+/).filter(Boolean);
    if (tokens.length === 1) {
      if (looksLikeRandomToken(tokens[0])) score += 3;
      score += scoreSingleAlphanumWord(tokens[0]);
      if (tokens[0].length >= 12) {
        const alnum = (tokens[0].match(/[A-Za-z0-9]/g) || []).length;
        if (alnum / tokens[0].length >= 0.5) score += 1;
      }
    } else {
      let gibberish = 0, analyzable = 0;
      for (const tok of tokens) {
        if (tok.length < 6) continue;
        analyzable++;
        if (looksLikeRandomToken(tok)) gibberish++;
      }
      if (analyzable > 0 && gibberish / analyzable >= 0.5) score += 3;
    }

    const digitCount = (trimmed.match(/[0-9]/g) || []).length;
    const letterCount = (trimmed.match(/[A-Za-z]/g) || []).length;
    if (trimmed.length >= 8 && letterCount > 0 && digitCount / trimmed.length > 0.5) score += 1;

    const emojiMatches = trimmed.match(/\p{Extended_Pictographic}/gu) || [];
    if (emojiMatches.length >= 4 && letterCount > 0) score += 1;

    return score;
  }

  // Drop gibberish channel events before they reach the client
  function contentSpamScore(content) {
    if (typeof content !== 'string') return 0;
    const trimmed = content.trim();
    if (trimmed.includes('["client","chorus"]')) return 99;
    if (trimmed.length < 6) return 0;
    if (trimmed.includes('://') || trimmed.startsWith('www.')) return 0;
    if (/^ln(bc|tb|ts)/i.test(trimmed)) return 0;
    if (/^cashu/i.test(trimmed)) return 0;
    if (/^(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+$/i.test(trimmed)) return 0;
    if (/^[0-9a-fA-F]{64}$/.test(trimmed)) return 0;
    if (trimmed.includes('```') || trimmed.includes('`')) return 0;
    if (trimmed.startsWith('data:image')) return 0;
    const scrubbed = trimmed
      .split('\n').filter(line => !line.trimStart().startsWith('>')).join('\n')
      .replace(/@\S+/g, ' ')
      .replace(/(nostr:)?(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+/gi, ' ')
      .replace(/\b[0-9a-fA-F]{64}\b/g, ' ')
      .trim();
    return spamScore(scrubbed);
  }

  function isSpamContent(content) {
    return contentSpamScore(content) >= 3;
  }

  function isSpamNym(nym) {
    if (typeof nym !== 'string') return false;
    const n = nym.trim();
    if (!n || n.length < 8) return false;
    return looksLikeRandomToken(n);
  }

  // FNV-1a 32-bit
  function hashContent(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 0x01000193);
    }
    return h >>> 0;
  }

  // Per-pubkey content flood
  const contentFloodTracking = new Map();
  const CONTENT_FLOOD_MAX_KEYS = 5000;
  const AUTO_MUTED_MAX = 5000;
  const CONTENT_FLOOD_WINDOW_MS = 120000;
  const CONTENT_FLOOD_BLOCK_MS = 900000;
  const CONTENT_FLOOD_THRESHOLD = 3;

  function trackContentFlood(pubkey, content, now) {
    const normalized = content.replace(/\s+/g, ' ').trim().toLowerCase();
    if (normalized.length < 6) return false;

    let entry = contentFloodTracking.get(pubkey);
    if (!entry) {
      entry = { hashes: new Map(), blockedUntil: 0 };
      contentFloodTracking.set(pubkey, entry);
      if (contentFloodTracking.size > CONTENT_FLOOD_MAX_KEYS) {
        contentFloodTracking.delete(contentFloodTracking.keys().next().value);
      }
    }

    for (const [h, info] of entry.hashes) {
      if (now - info.lastSeen > CONTENT_FLOOD_WINDOW_MS) entry.hashes.delete(h);
    }

    const hash = hashContent(normalized);
    let info = entry.hashes.get(hash);
    if (!info) {
      info = { count: 0, lastSeen: now };
      entry.hashes.set(hash, info);
    }
    info.count++;
    info.lastSeen = now;

    if (info.count >= CONTENT_FLOOD_THRESHOLD) {
      entry.blockedUntil = now + CONTENT_FLOOD_BLOCK_MS;
    }
    return false;
  }

  function isContentFlooding(pubkey, now) {
    const entry = contentFloodTracking.get(pubkey);
    if (!entry) return false;
    if (now < entry.blockedUntil) return true;
    if (entry.blockedUntil) entry.blockedUntil = 0;
    return false;
  }

  const CAMPAIGN_WINDOW_MS = 900000;
  const CAMPAIGN_ALLOWANCE = 3;
  const CAMPAIGN_SENDER_REPEAT = 3;
  const CAMPAIGN_MIN_LENGTH = 24;
  const CAMPAIGN_MIN_SHINGLES = 8;
  const CAMPAIGN_SIMILARITY = 0.6;
  const CAMPAIGN_MAX_CLUSTERS = 2000;
  const CAMPAIGN_MAX_HITS = 64;
  const AUTO_MUTE_MS = 86400000;
  const campaignClusters = new Set();
  const campaignByKey = new Map();
  const campaignByShingle = new Map();
  const autoMuted = new Map();

  function campaignTokens(content) {
    if (typeof content !== 'string') return [];
    const out = [];
    for (let w of content.toLowerCase().split(/\s+/)) {
      if (!w) continue;
      if (/^(https?:\/\/|www\.)/.test(w)) {
        w = w.replace(/[?#].*$/, '').replace(/[^\p{L}\p{N}\/]+$/u, '');
        if (w) out.push(w);
        continue;
      }
      w = w.replace(/^[^\p{L}\p{N}@#]+|[^\p{L}\p{N}]+$/gu, '');
      if (!w || w[0] === '@' || /\p{N}/u.test(w)) continue;
      out.push(w);
    }
    return out;
  }

  function campaignShingles(tokens) {
    const set = new Set();
    if (tokens.length === 1) { set.add(hashContent(tokens[0])); return set; }
    for (let i = 0; i + 1 < tokens.length; i++) set.add(hashContent(tokens[i] + ' ' + tokens[i + 1]));
    return set;
  }

  function campaignMatch(key, shingles) {
    const exact = campaignByKey.get(key);
    if (exact) return exact;
    if (shingles.size < CAMPAIGN_MIN_SHINGLES) return null;
    const votes = new Map();
    for (const s of shingles) {
      const owners = campaignByShingle.get(s);
      if (!owners) continue;
      for (const c of owners) votes.set(c, (votes.get(c) || 0) + 1);
    }
    let best = null, bestScore = 0;
    for (const [c, v] of votes) {
      if (c.shingles.size < CAMPAIGN_MIN_SHINGLES) continue;
      const score = v / (shingles.size + c.shingles.size - v);
      if (score > bestScore) { bestScore = score; best = c; }
    }
    return bestScore >= CAMPAIGN_SIMILARITY ? best : null;
  }

  function campaignDrop(cluster) {
    campaignClusters.delete(cluster);
    for (const k of cluster.keys) if (campaignByKey.get(k) === cluster) campaignByKey.delete(k);
    for (const s of cluster.shingles) {
      const owners = campaignByShingle.get(s);
      if (!owners) continue;
      owners.delete(cluster);
      if (owners.size === 0) campaignByShingle.delete(s);
    }
  }

  function campaignEvict(now) {
    for (const c of campaignClusters) if (now - c.last >= CAMPAIGN_WINDOW_MS * 2) campaignDrop(c);
    if (campaignClusters.size < CAMPAIGN_MAX_CLUSTERS) return;
    let oldest = null;
    for (const c of campaignClusters) if (!oldest || c.last < oldest.last) oldest = c;
    if (oldest) campaignDrop(oldest);
  }

  function checkCampaign(content, pubkey, createdAtMs, now) {
    const tokens = campaignTokens(content);
    const text = tokens.join(' ');
    if (text.length < CAMPAIGN_MIN_LENGTH) return { flood: false, mute: false, copies: 0 };
    const t = now;
    const created = createdAtMs > 0 ? createdAtMs : t;
    const key = hashContent(text);
    const shingles = campaignShingles(tokens);
    let cluster = campaignMatch(key, shingles);
    if (!cluster) {
      if (campaignClusters.size >= CAMPAIGN_MAX_CLUSTERS) campaignEvict(t);
      cluster = { keys: new Set(), shingles, hits: [], last: t };
      campaignClusters.add(cluster);
      for (const s of shingles) {
        let owners = campaignByShingle.get(s);
        if (!owners) { owners = new Set(); campaignByShingle.set(s, owners); }
        owners.add(cluster);
      }
    }
    if (!cluster.keys.has(key)) { cluster.keys.add(key); campaignByKey.set(key, cluster); }
    cluster.last = t;
    const hits = cluster.hits.filter((h) => t - h.at <= CAMPAIGN_WINDOW_MS);
    hits.push({ pubkey: pubkey || '', at: t, created });
    if (hits.length > CAMPAIGN_MAX_HITS) hits.splice(0, hits.length - CAMPAIGN_MAX_HITS);
    cluster.hits = hits;
    let copies = 0, mine = 0;
    for (const h of hits) {
      if (Math.abs(h.at - t) > CAMPAIGN_WINDOW_MS && Math.abs(h.created - created) > CAMPAIGN_WINDOW_MS) continue;
      copies++;
      if (pubkey && h.pubkey === pubkey) mine++;
    }
    const flood = copies > CAMPAIGN_ALLOWANCE;
    const mute = !!pubkey && mine >= CAMPAIGN_SENDER_REPEAT;
    return { flood, mute, copies };
  }

  function isAutoMuted(pubkey, now) {
    const until = autoMuted.get(pubkey);
    if (until === undefined) return false;
    if (now < until) return true;
    autoMuted.delete(pubkey);
    return false;
  }

  function extractCreatedAtMs(raw) {
    const m = /"created_at"\s*:\s*(\d+)/.exec(raw);
    return m ? parseInt(m[1], 10) * 1000 : 0;
  }

  // Channel spam suppression at the pool boundary
  const RX_BLOCKED_CONTENT_BLOB = /"content":"(?:(?:bitchat1|encmedia|enc):[A-Za-z0-9+\/=_-]{24,}|test_\d+_\d+)"/;
  function hasBlockedContentPrefix(raw) {
    return RX_BLOCKED_CONTENT_BLOB.test(raw);
  }

  let droppedSpamCount = 0;
  let droppedGeoOriginCount = 0;
  let droppedUnbadgedCount = 0;
  let droppedForgedCount = 0;
  const RX_GLUB_CLIENT = /\[\s*"client"\s*,\s*"glub\.chat"/i;
  const RX_GLUB_TAG = /\[\s*"glub"\s*,/i;

  function isGlubClientFrame(raw) {
    const tagsIdx = raw.indexOf('"tags":');
    if (tagsIdx === -1) return false;
    const tags = raw.slice(tagsIdx);
    return RX_GLUB_CLIENT.test(tags) || RX_GLUB_TAG.test(tags);
  }

  const RX_MACHINE_OBJECT = /^\{\s*"[^"\n]{1,64}"\s*:/;
  const RX_MACHINE_ARRAY = /^\[\s*(?:\{\s*"[^"\n]{1,64}"\s*:|"[^"\n]*"\s*[,\]])/;
  function isMachinePayload(content) {
    if (typeof content !== 'string') return false;
    const t = content.trim();
    if (t.length < 8) return false;
    const last = t.charCodeAt(t.length - 1);
    if (t.charCodeAt(0) === 123 && last === 125) return RX_MACHINE_OBJECT.test(t);
    if (t.charCodeAt(0) === 91 && last === 93) return RX_MACHINE_ARRAY.test(t);
    return false;
  }

  let lastSignals = null;

  function noteAutoMuted(pubkey, until) {
    autoMuted.delete(pubkey);
    autoMuted.set(pubkey, until);
    if (autoMuted.size > AUTO_MUTED_MAX) autoMuted.delete(autoMuted.keys().next().value);
  }

  function isSpamEventFrame(raw, observe) {
    lastSignals = null;
    const kind = extractEventKind(raw);
    if (kind !== 20000 && kind !== 23333) return false;
    const content = extractEventStringField(raw, 'content');
    const pubkey = extractEventStringField(raw, 'pubkey');
    const now = Date.now();
    const signals = { pubkey, content, score: 0, copies: 0 };
    lastSignals = signals;
    if (content === null || !pubkey) return true;
    if (content && isMachinePayload(content)) return true;
    if (pubkey && isAutoMuted(pubkey, now)) return true;
    if (kind === 20000) {
      if (content) {
        signals.score = contentSpamScore(content);
        if (signals.score >= 3) return true;
      }
      const nymTag = extractTagValue(raw, 'n');
      if (nymTag) {
        const cleanNym = nymTag.replace(/#[a-fA-F0-9]{4}$/, '');
        if (isSpamNym(cleanNym)) return true;
      }
      if (pubkey && content) {
        if (isContentFlooding(pubkey, now)) return true;
        if (observe !== false) trackContentFlood(pubkey, content, now);
      }
    } else if (content) {
      signals.score = contentSpamScore(content);
    }
    if (pubkey && content && observe !== false) {
      const verdict = checkCampaign(content, pubkey, extractCreatedAtMs(raw), now);
      signals.copies = verdict.copies;
      if (verdict.mute) noteAutoMuted(pubkey, now + AUTO_MUTE_MS);
      if (verdict.flood || verdict.mute) return true;
    }
    return false;
  }

  function badgeGateRefused(raw, kind) {
    if (kind !== 20000 && kind !== 23333) return false;
    const mode = spam.badgeGate();
    if (mode === 'off') return false;
    const pubkey = extractEventStringField(raw, 'pubkey');
    if (!pubkey || spam.isExempt(pubkey)) return false;
    if (!badgeGateRefuses(mode, badgeTierFor(env, pubkey, extractTagValue(raw, 'nymattest') || ''))) return false;
    droppedUnbadgedCount++;
    spam.noteUnbadged();
    return true;
  }

  function lacksChannel(raw, kind) {
    if (kind !== 20000 && kind !== 23333) return false;
    return !channelKeyFor(kind, (n) => extractTagValue(raw, n));
  }

  function noteForgedFrame(relayUrl) {
    droppedForgedCount++;
    if (forgedByRelay.size > MAX_RELAY_LIST) forgedByRelay.clear();
    const n = (forgedByRelay.get(relayUrl) || 0) + 1;
    forgedByRelay.set(relayUrl, n);
    if (n >= FORGED_FRAME_LIMIT) markPermanentlySkipped(relayUrl, 'invalid: event signatures do not verify');
  }

  function touchSubscription(raw) {
    const end = raw.indexOf('"', 10);
    if (end < 0) return;
    const subId = raw.substring(10, end);
    const parent = childToParent.get(subId) || subId;
    if (subActivity.has(parent)) subActivity.set(parent, Date.now());
  }

  function spamEngineVerdict(raw, eventId, kind, relayTail, ev) {
    if ((kind !== 20000 && kind !== 23333) || !eventId || !spam.active()) return 'pass';
    if (!ev || ev.id !== eventId || typeof ev.content !== 'string') return 'drop';
    if (!ev.content) return 'pass';
    const sig = lastSignals || { score: 0, copies: 0 };
    const getTag = evTagReader(ev);
    const nymTag = getTag('n');
    let mentions = 0;
    for (const t of ev.tags) if (t[0] === 'p' && mentions < 64) mentions++;
    return spam.inspect({
      release: () => sendToClient(raw.slice(0, -1) + relayTail),
      retract: () => sendToClient(JSON.stringify(['POOL:RETRACT', eventId, 'spam'])),
      id: eventId,
      kind,
      pubkey: ev.pubkey,
      content: ev.content,
      verified: true,
      pow: validatedPowBits(ev),
      nym: nymTag ? nymTag.replace(/#[a-fA-F0-9]{4}$/, '') : '',
      badgeTag: getTag('nymattest') || '',
      reply: ev.tags.some((t) => t[0] === 'e'),
      quote: ev.tags.some((t) => t[0] === 'nymquote'),
      mentions,
      channel: channelKeyFor(kind, getTag),
      createdAt: ev.created_at * 1000,
      localScore: sig.score,
      copies: sig.copies
    });
  }

  // Enqueue a connection, capping concurrent establishment to MAX_CONCURRENT_CONNECTS.
  function queueConnection(relayUrl, type) {
    if (upstreams.has(relayUrl) || pendingConnect.has(relayUrl)) return;
    if (upstreams.size + pendingConnect.size >= MAX_UPSTREAMS) return;
    pendingConnect.add(relayUrl);
    connectionQueue.push({ relayUrl, type });
    pumpConnectQueue();
  }

  function pumpConnectQueue() {
    while (inFlightConnects < MAX_CONCURRENT_CONNECTS && connectionQueue.length > 0) {
      const { relayUrl, type } = connectionQueue[0];
      if (upstreams.has(relayUrl) || !validateRelayUrl(relayUrl)
        || relayUrl === 'wss://relay.nosflare.com' || shouldSkipRelay(relayUrl)) {
        connectionQueue.shift();
        pendingConnect.delete(relayUrl);
        continue;
      }
      if (relayUrl !== APP_RELAY && !connectBucket.take()) {
        if (!connectionTimer && serverOpen) {
          connectionTimer = setTimeout(() => {
            connectionTimer = null;
            if (serverOpen) pumpConnectQueue();
          }, 1000);
        }
        return;
      }
      connectionQueue.shift();
      pendingConnect.delete(relayUrl);
      inFlightConnects++;
      connectUpstream(relayUrl, type);
    }
  }

  // The app relay and the client's curated default relays (sent as dmRelays)
  // must never be permanently skipped — they always stay reconnectable.
  function isProtectedRelay(relayUrl) {
    return relayUrl === APP_RELAY || dmRelays.includes(relayUrl);
  }

  function markPermanentlySkipped(relayUrl, reason) {
    if (!relayUrl || permanentlySkipped.has(relayUrl)) return;
    if (isProtectedRelay(relayUrl)) return;
    if (permanentlySkipped.size >= MAX_PERMANENTLY_SKIPPED) {
      permanentlySkipped.delete(permanentlySkipped.values().next().value);
    }
    permanentlySkipped.add(relayUrl);
    pendingGeoEvents.delete(relayUrl);
    intentionallyClosed.add(relayUrl);
    const pendingTimer = reconnectTimers.get(relayUrl);
    if (pendingTimer) {
      clearTimeout(pendingTimer);
      reconnectTimers.delete(relayUrl);
    }
    pendingReconnect.delete(relayUrl);
    const info = upstreams.get(relayUrl);
    if (info && info.ws) {
      try { info.ws.close(); } catch { /* noop */ }
    }
    upstreams.delete(relayUrl);
    for (const targets of subRelays.values()) targets.delete(relayUrl);
    sendToClient(JSON.stringify(['POOL:RELAY_BAN', relayUrl, reason]));
    schedulePoolStatus();
  }

  function scheduleReconnect(relayUrl, type) {
    if (!serverOpen) return;
    if (pendingReconnect.has(relayUrl)) return;
    if (permanentlySkipped.has(relayUrl)) return;

    const attempts = reconnectAttempts.get(relayUrl) || 0;
    reconnectAttempts.set(relayUrl, attempts + 1);
    pendingReconnect.add(relayUrl);

    const delay = Math.min(RECONNECT_BASE_MS * Math.pow(1.5, attempts), RECONNECT_CAP_MS)
      + Math.random() * 2000;

    const timerId = setTimeout(() => {
      reconnectTimers.delete(relayUrl);
      pendingReconnect.delete(relayUrl);
      if (!serverOpen || upstreams.has(relayUrl) || intentionallyClosed.has(relayUrl)) return;
      failedRelays.delete(relayUrl);
      queueConnection(relayUrl, type);
    }, delay);
    reconnectTimers.set(relayUrl, timerId);
  }

  function sendSubscriptionToRelay(relayUrl, ws, parentSubId) {
    if (WRITE_ONLY_RELAYS.has(relayUrl)) return;
    const role = subRole.get(parentSubId);
    if (role && role !== 'all' && relayRole.get(relayUrl) !== role) return;
    const blocked = kindBlacklist.get(relayUrl);
    let anySent = false;
    const children = splitChildren.get(parentSubId);
    if (children) {
      for (const child of children) {
        const payload = buildChildPayload(child, blocked);
        if (payload === null) continue;
        try { ws.send(payload); anySent = true; } catch { /* noop */ }
      }
    } else {
      const rawReq = activeSubscriptions.get(parentSubId);
      if (!rawReq) return;
      let payload = rawReq;
      if (blocked && blocked.size > 0) {
        const stripped = stripKindsFromReq(rawReq, blocked);
        if (stripped === '') return;
        if (stripped !== null) payload = stripped;
      }
      try { ws.send(payload); anySent = true; } catch { /* noop */ }
    }
    if (anySent) {
      let targets = subRelays.get(parentSubId);
      if (!targets) { targets = new Set(); subRelays.set(parentSubId, targets); }
      targets.add(relayUrl);
    }
  }

  function replaySubscriptions(relayUrl, ws) {
    for (const subId of activeSubscriptions.keys()) {
      sendSubscriptionToRelay(relayUrl, ws, subId);
    }
  }

  // Fan a new subscription out to relays in small batches instead of blasting
  // all ~150 at once, which destabilizes the relays and the client socket.
  function staggerSubscribe(subId) {
    const targets = [];
    upstreams.forEach((info, url) => {
      if (info.status === 'connected' && info.ws && info.ws.readyState === 1) targets.push(url);
    });
    let i = 0;
    const BATCH = 20, DELAY = 60;
    const pump = () => {
      if (!serverOpen || !activeSubscriptions.has(subId)) return;
      const end = Math.min(i + BATCH, targets.length);
      for (; i < end; i++) {
        const info = upstreams.get(targets[i]);
        if (info && info.status === 'connected' && info.ws && info.ws.readyState === 1) {
          sendSubscriptionToRelay(targets[i], info.ws, subId);
        }
      }
      if (i < targets.length) setTimeout(pump, DELAY);
    };
    pump();
  }

  // Caller (pumpConnectQueue) has already incremented inFlightConnects and
  // validated the relay; this releases that establishment slot exactly once.
  function connectUpstream(relayUrl, type) {
    let slotReleased = false;
    const releaseSlot = () => {
      if (slotReleased) return;
      slotReleased = true;
      inFlightConnects--;
      pumpConnectQueue();
    };

    if (upstreams.has(relayUrl)) { releaseSlot(); return; }

    const info = { ws: null, type, status: 'connecting', eventCount: 0, handled: false };
    upstreams.set(relayUrl, info);

    const connectStartTime = Date.now();

    try {
      let upstreamUrl = relayUrl;
      if (relayUrl === APP_RELAY && clientIsNymchat && proxySecret) {
        const u = new URL(relayUrl);
        u.searchParams.set('nymchat_proxy', proxySecret);
        const host = proxyHost(request);
        if (host) u.searchParams.set('nymchat_proxy_host', host);
        if (ipKey) u.searchParams.set('nymchat_proxy_ip', ipKey);
        upstreamUrl = u.toString();
      }
      const ws = new WebSocket(upstreamUrl);
      info.ws = ws;

      const timeout = setTimeout(() => {
        if (info.status === 'connecting') {
          info.handled = true;
          info.status = 'failed';
          trackRelayFailure(relayUrl);
          try { ws.close(); } catch { /* noop */ }
          upstreams.delete(relayUrl);
          pendingGeoEvents.delete(relayUrl);
          releaseSlot();
          retryAfterFailure(relayUrl, type);
          schedulePoolStatus();
        }
      }, 8000);

      ws.addEventListener('open', () => {
        clearTimeout(timeout);
        releaseSlot();
        info.status = 'connected';
        info.openedAt = Date.now();
        everConnected.add(relayUrl);
        clearRelayFailure(relayUrl);
        relayLatency.set(relayUrl, Date.now() - connectStartTime);
        replaySubscriptions(relayUrl, ws);
        // Flush any buffered GEO_EVENTs that were waiting for this relay
        const buffered = pendingGeoEvents.get(relayUrl);
        if (buffered && buffered.length > 0) {
          for (const geoMsg of buffered) {
            try { ws.send(geoMsg); } catch { /* noop */ }
          }
          pendingGeoEvents.delete(relayUrl);
        }
        schedulePoolStatus();
      });

      ws.addEventListener('message', (event) => {
        let raw = event.data;
        if (typeof raw !== 'string' || raw.length < 10 || raw.length > UPSTREAM_FRAME_MAX) return;
        if (raw.charCodeAt(0) !== 91 || raw.charCodeAt(1) !== 34) {
          raw = reframeRelayMessage(raw);
          if (!raw) return;
        }

        if (raw.startsWith('["EVENT",')) {
          raw = canonicalEventFrame(raw);
          if (!raw) return;
          if (isForeignAppChannelEvent(raw, relayUrl)) return;
          const eventId = extractEventId(raw);
          if (!eventId) return;
          const prior = seenEvents.get(eventId);
          if (prior !== undefined) {
            // The whole event is a duplicate and is not forwarded again, but
            // WHICH relays carried it is information the first copy could not
            // contain — the client's event-details panel has no other way to
            // learn it, because this dedup is exactly what hides it. A 40-byte
            // note costs far less than the event and answers the question.
            const dupKind = extractEventKind(raw);
            if (prior < SEEN_REPORT_CAP && isSeenReportKind(dupKind) && geoOriginAllowsFrame(raw, dupKind, relayUrl)) {
              seenEvents.set(eventId, prior + 1);
              sendToClient(JSON.stringify(['POOL:SEEN', eventId, relayUrl]));
            }
            return;
          }
          if (!geoOriginAllowsFrame(raw, extractEventKind(raw), relayUrl)) {
            droppedGeoOriginCount++;
            return;
          }
          if (frameHit(gate, raw)) return;
          const evKind = extractEventKind(raw);
          if (lacksChannel(raw, evKind)) return;
          let verified = null;
          if (evKind === 20000 || evKind === 23333) {
            verified = verifiedEventJson(extractEventObjectJson(raw), eventId);
            if (!verified) {
              noteForgedFrame(relayUrl);
              return;
            }
          }
          seenEvents.set(eventId, 1);
          trimDedup();
          if (hasBlockedContentPrefix(raw) || isGlubClientFrame(raw) || isSpamEventFrame(raw)) {
            droppedSpamCount++;
            vetoArchive(eventId);
            return;
          }
          if (badgeGateRefused(raw, evKind)) return;
          const relayTail = ',' + JSON.stringify(relayUrl) + ']';
          const spamVerdict = spamEngineVerdict(raw, eventId, evKind, relayTail, verified);
          if (spamVerdict === 'drop') {
            droppedSpamCount++;
            vetoArchive(eventId);
            return;
          }
          // Drop settings wraps off the relay stream (loaded from D1).
          if (evKind === 1059) {
            const kTag = extractTagValue(raw, 'k');
            const dTag = kTag === 'nym-sync' ? null : extractTagValue(raw, 'd');
            if (kTag === 'nym-sync' || (dTag && dTag.startsWith('nymchat-'))) return;
          }
          info.eventCount++;
          if (archiveEnabled) {
            if (isArchivableChannelKind(evKind)) archiveInboundEvent(raw, evKind, eventId);
            else if (isArchivableEmojiKind(evKind)) archiveInboundEmoji(raw, evKind);
            else if (evKind === 5) deleteArchivedFromDeletion(raw);
          }
          if (spamVerdict === 'hold') return;
          touchSubscription(raw);
          sendToClient(raw.slice(0, -1) + relayTail);

        // OK: ["OK","eventId",bool,"msg"]
        } else if (raw.startsWith('["OK",')) {
          const okMatch = raw.match(/^\["OK",\s*(?:"([^"\\]{0,128})"|null),\s*(true|false)\s*(?:,\s*"((?:[^"\\]|\\.)*)")?/);
          if (!okMatch) return;
          const okId = okMatch[1] || null;
          const acceptedFlag = okMatch[2] === 'true';
          const reason = okMatch[3] || '';
          if (okId && relayUrl === APP_RELAY && pendingAppArchive.has(okId)) {
            if (settleAppArchive(okId, acceptedFlag)) runArchive(flushArchive());
          }
          if (okId) {
            if (relayUrl !== APP_RELAY && seenOKs.has(okId)) return;
            seenOKs.add(okId);
          }
          if (isRelayWideRejection(reason) && !isUnsupportedKind(reason)) {
            markPermanentlySkipped(relayUrl, `event-rejected: ${reason}`);
          }
          sendToClient(JSON.stringify(['OK', okId, acceptedFlag, reason, relayUrl]));

        } else if (raw.startsWith('["EOSE",')) {
          const eoseMatch = raw.match(/^\["EOSE",\s*"([^"\\]{1,128})"/);
          if (!eoseMatch) return;
          const eoseSubId = eoseMatch[1];
          const parent = childToParent.get(eoseSubId) || eoseSubId;
          if (seenEOSE.has(parent)) return;
          seenEOSE.add(parent);
          if (subActivity.has(parent)) subActivity.set(parent, Date.now());
          sendToClient(JSON.stringify(['EOSE', parent]));

        } else if (raw.startsWith('["AUTH",')) {
          // NIP-42 challenge only; we don't authenticate. Most relays still
          // serve reads after sending it, so don't skip — a real auth wall
          // arrives as a CLOSED/NOTICE rejection and is handled there.
          return;

        } else if (raw.startsWith('["NOTICE",')) {
          const m = raw.match(/^\["NOTICE",\s*"((?:[^"\\]|\\.)*)"/);
          if (!m) return;
          const reason = m[1];
          if (/no such sub|unknown subscription/i.test(reason)) return;
          if (isUnsupportedKind(reason)) {
            sendToClient(JSON.stringify(['NOTICE', reason, relayUrl]));
            return;
          }
          if (isRelayWideRejection(reason)) {
            markPermanentlySkipped(relayUrl, reason);
            return;
          }
          sendToClient(JSON.stringify(['NOTICE', reason, relayUrl]));

        } else if (raw.startsWith('["CLOSED",')) {
          const m = raw.match(/^\["CLOSED",\s*"([^"\\]{1,128})",\s*"((?:[^"\\]|\\.)*)"/);
          if (!m) return;
          const closedSubId = m[1];
          const reason = m[2];
          const parentSubId = childToParent.get(closedSubId) || closedSubId;
          if (isRelayWideRejection(reason)) {
            markPermanentlySkipped(relayUrl, reason);
            sendToClient(JSON.stringify(['CLOSED', parentSubId, reason, relayUrl]));
            return;
          }
          if (isUnsupportedKind(reason)) {
            const rejectedKind = extractRejectedKind(reason);
            if (rejectedKind !== null) {
              let bl = kindBlacklist.get(relayUrl);
              if (!bl) { bl = new Set(); kindBlacklist.set(relayUrl, bl); }
              if (bl.size < MAX_KIND_BLACKLIST_KINDS) bl.add(rejectedKind);
            }
            const blockedSet = kindBlacklist.get(relayUrl);
            const children = splitChildren.get(parentSubId);
            const upstreamInfo = upstreams.get(relayUrl);
            const retryKey = relayUrl + '\n' + parentSubId;
            const retries = closedKindRetries.get(retryKey) || 0;
            const ready = upstreamInfo && upstreamInfo.ws && upstreamInfo.ws.readyState === 1;
            let resent = false;
            // Resend only if the request actually changed, capped, to avoid loops
            if (ready && retries < 3) {
              if (children) {
                const child = children.find(c => c.childSubId === closedSubId);
                if (child) {
                  const newPayload = buildChildPayload(child, blockedSet);
                  if (newPayload && newPayload !== child.rawChild) {
                    try { upstreamInfo.ws.send(newPayload); resent = true; } catch { /* noop */ }
                  }
                }
              } else if (activeSubscriptions.has(parentSubId) && blockedSet && blockedSet.size > 0) {
                const rawReq = activeSubscriptions.get(parentSubId);
                const stripped = stripKindsFromReq(rawReq, blockedSet);
                if (stripped && stripped !== rawReq) {
                  try { upstreamInfo.ws.send(stripped); resent = true; } catch { /* noop */ }
                }
              }
            }
            if (resent) {
              if (closedKindRetries.size > 5000) closedKindRetries.clear();
              closedKindRetries.set(retryKey, retries + 1);
            } else {
              const targets = subRelays.get(parentSubId);
              if (targets) targets.delete(relayUrl);
            }
            sendToClient(JSON.stringify(['CLOSED', parentSubId, reason, relayUrl]));
            return;
          }
          sendToClient(JSON.stringify(['CLOSED', parentSubId, reason, relayUrl]));
        }
      });

      ws.addEventListener('close', () => {
        clearTimeout(timeout);
        releaseSlot();
        if (info.handled) return;
        info.handled = true;

        const wasConnected = info.status === 'connected';
        info.status = 'closed';
        upstreams.delete(relayUrl);
        pendingGeoEvents.delete(relayUrl);
        for (const targets of subRelays.values()) targets.delete(relayUrl);
        for (const k of closedKindRetries.keys()) {
          if (k.startsWith(relayUrl + '\n')) closedKindRetries.delete(k);
        }
        schedulePoolStatus();

        if (intentionallyClosed.has(relayUrl)) {
          intentionallyClosed.delete(relayUrl);
          return;
        }

        if (wasConnected) {
          if (Date.now() - (info.openedAt || 0) >= STABLE_SESSION_MS) {
            reconnectAttempts.delete(relayUrl);
          }
          scheduleReconnect(relayUrl, type);
        } else {
          trackRelayFailure(relayUrl);
          retryAfterFailure(relayUrl, type);
        }
      });

      ws.addEventListener('error', () => {
        clearTimeout(timeout);
        releaseSlot();
        if (info.handled) return;
        info.handled = true;

        info.status = 'failed';
        trackRelayFailure(relayUrl);
        upstreams.delete(relayUrl);
        pendingGeoEvents.delete(relayUrl);
        retryAfterFailure(relayUrl, type);
        schedulePoolStatus();
      });
    } catch {
      info.handled = true;
      info.status = 'failed';
      trackRelayFailure(relayUrl);
      upstreams.delete(relayUrl);
      pendingGeoEvents.delete(relayUrl);
      releaseSlot();
      retryAfterFailure(relayUrl, type);
      schedulePoolStatus();
    }
  }

  function heldOutbound(ev) {
    if (ev && ev.kind === 1984) runArchive(noteReport(env, ev, 'pool').then((ok) => (ok ? reviewSpamReport(env, ev, { context }) : null)).catch(() => null));
    let mode = sockHeld;
    if (!mode) {
      mode = eventHit(gate, ev);
      if (mode && ev && typeof ev.pubkey === 'string' && gate.p.has(ev.pubkey.toLowerCase())) sockHeld = mode;
    }
    if (!mode) return false;
    if (ev && typeof ev.id === 'string') {
      sendToClient(JSON.stringify(mode === 'reject'
        ? ['OK', ev.id, false, 'blocked: not accepted']
        : ['OK', ev.id, true, '']));
    }
    return true;
  }

  const BADGE_GATED_KINDS = new Set([20000, 23333]);
  const poolBadgeMode = (() => {
    const raw = env && typeof env.NYMCHAT_POOL_BADGE_MODE === 'string' ? env.NYMCHAT_POOL_BADGE_MODE.trim().toLowerCase() : '';
    return raw === 'off' || raw === 'enforce' ? raw : 'log';
  })();
  const poolBadgeAuthority = poolBadgeMode === 'off' ? null : authorityPubkey(env);

  function outboundBadgeRefused(ev) {
    if (poolBadgeMode === 'off' || !poolBadgeAuthority) return false;
    if (!ev || typeof ev !== 'object' || !BADGE_GATED_KINDS.has(ev.kind)) return false;
    const tags = Array.isArray(ev.tags) ? ev.tags : [];
    const tag = tags.find((t) => Array.isArray(t) && t[0] === 'nymattest' && typeof t[1] === 'string');
    const verified = tag ? verifyBadge(tag[1], ev.pubkey, poolBadgeAuthority, Date.now()) : null;
    if (verified) return false;
    const why = tag ? 'invalid badge' : 'no badge';
    console.log(`Pool ${poolBadgeMode === 'enforce' ? 'refused' : 'would refuse'} event ${ev.id || '-'} (${why}) kind=${ev.kind} pubkey=${ev.pubkey || '-'}`);
    if (poolBadgeMode !== 'enforce') return false;
    if (typeof ev.id === 'string') {
      sendToClient(JSON.stringify(['OK', ev.id, false, `restricted: attestation badge required (${why})`]));
    }
    return true;
  }

  function queuePendingGeo(url, msg) {
    let list = pendingGeoEvents.get(url);
    if (!list) { list = []; pendingGeoEvents.set(url, list); }
    if (list.length >= PENDING_GEO_PER_RELAY) list.shift();
    list.push(msg);
  }

  function sendAppRelayOnly(msg) {
    const info = upstreams.get(APP_RELAY);
    if (!info) return;
    if (info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
      try { info.ws.send(msg); } catch {}
      return;
    }
    if (info.status === 'connecting') {
      queuePendingGeo(APP_RELAY, msg);
    }
  }

  function sendToUpstreams(data, filter) {
    const msg = typeof data === 'string' ? data : JSON.stringify(data);
    WRITE_ONLY_RELAYS.forEach((url) => {
      const info = upstreams.get(url);
      if (!info || info.status !== 'connected' || !info.ws || info.ws.readyState !== WebSocket.OPEN) return;
      if (filter && !filter(url, info)) return;
      try { info.ws.send(msg); } catch { /* noop */ }
    });
    upstreams.forEach((info, url) => {
      if (WRITE_ONLY_RELAYS.has(url)) return;
      if (info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        if (!filter || filter(url, info)) {
          try { info.ws.send(msg); } catch { /* noop */ }
        }
      }
    });
  }

  function refuseEvent(ev, reason) {
    if (ev && typeof ev.id === 'string') sendToClient(JSON.stringify(['OK', ev.id, false, reason]));
  }

  function outboundRateOk(ev) {
    const now = Date.now();
    if (now < ipEventBlockedUntil || !eventBucket.take(1, now)) {
      refuseEvent(ev, 'rate-limited: slow down');
      return false;
    }
    if (ipKey && ++ipEventUnits >= POOL_IP_CHARGE_BATCH) {
      const units = ipEventUnits;
      ipEventUnits = 0;
      runArchive(cacheRateTake('pool-events', ipKey, units, POOL_EVENTS_PER_IP_MIN, 60000).then((ok) => {
        if (!ok) ipEventBlockedUntil = Date.now() + 60000;
      }, () => null));
    }
    return true;
  }

  function canonicalRelayList(list, max) {
    const out = [];
    if (!Array.isArray(list)) return out;
    const seen = new Set();
    for (const url of list.slice(0, MAX_RELAY_LIST)) {
      const c = canonicalRelayUrl(url);
      if (!c || seen.has(c)) continue;
      seen.add(c);
      out.push(c);
      if (out.length >= max) break;
    }
    return out;
  }

  function closeSubscription(subId) {
    const targets = subRelays.get(subId);
    const children = splitChildren.get(subId);
    if (children) {
      if (targets && targets.size > 0) {
        for (const child of children) {
          sendToUpstreams(JSON.stringify(['CLOSE', child.childSubId]), (url) => targets.has(url));
        }
      }
      for (const child of children) childToParent.delete(child.childSubId);
      splitChildren.delete(subId);
    } else if (targets && targets.size > 0) {
      sendToUpstreams(JSON.stringify(['CLOSE', subId]), (url) => targets.has(url));
    }
    activeSubscriptions.delete(subId);
    subRole.delete(subId);
    subRelays.delete(subId);
    seenEOSE.delete(subId);
    subActivity.delete(subId);
  }

  function evictIdlestSubscription() {
    let victim = null;
    let oldest = Infinity;
    for (const [subId, at] of subActivity) {
      if (at < oldest) { oldest = at; victim = subId; }
    }
    if (victim === null) victim = activeSubscriptions.keys().next().value;
    if (victim === undefined || victim === null) return;
    closeSubscription(victim);
    sendToClient(JSON.stringify(['CLOSED', victim, 'closed: subscription limit reached']));
  }

  let pendingRelaysConfig = null;
  let relaysTimer = null;

  function applyRelaysConfig(config) {
    dmRelays = canonicalRelayList(config.dmRelays, MAX_RELAY_LIST);
    const criticalRelays = canonicalRelayList(config.critical || config.relays, MAX_RELAY_LIST);
    const geoRelays = canonicalRelayList(config.geo, MAX_RELAY_LIST);

    relayRole.clear();
    for (const url of criticalRelays) relayRole.set(url, 'critical');
    for (const url of geoRelays) if (!relayRole.has(url)) relayRole.set(url, 'geo');

    const requestedRelays = [...relayRole.keys()].slice(0, MAX_UPSTREAMS);
    const newRelaySet = new Set(requestedRelays);
    for (const url of [...relayRole.keys()]) if (!newRelaySet.has(url)) relayRole.delete(url);

    for (const [url, info] of upstreams) {
      if (!newRelaySet.has(url)) {
        intentionallyClosed.add(url);
        try { if (info.ws) info.ws.close(); } catch { /* noop */ }
        upstreams.delete(url);
      }
    }
    for (const url of [...pendingGeoEvents.keys()]) {
      if (!newRelaySet.has(url)) pendingGeoEvents.delete(url);
    }
    connectionQueue = connectionQueue.filter((entry) => {
      if (newRelaySet.has(entry.relayUrl)) return true;
      pendingConnect.delete(entry.relayUrl);
      return false;
    });

    for (const [url, timerId] of reconnectTimers) {
      if (newRelaySet.has(url)) continue;
      clearTimeout(timerId);
      reconnectTimers.delete(url);
      pendingReconnect.delete(url);
      reconnectAttempts.delete(url);
      everConnected.delete(url);
    }

    for (const url of requestedRelays) {
      if (!upstreams.has(url) && !pendingReconnect.has(url)) {
        queueConnection(url, 'read');
      }
    }
  }

  // Handle messages from client
  server.addEventListener('message', (event) => {
    try {
      if (typeof event.data !== 'string' || event.data.length > CLIENT_FRAME_MAX) return;
      let msg = JSON.parse(event.data);
      if (!Array.isArray(msg)) return;

      // Role-scoped envelope: ["ROLE", role, <inner message...>] routes the
      // inner message only to relays tagged with that role.
      let routedRole = null;
      if (msg[0] === 'ROLE') {
        routedRole = msg[1];
        if (routedRole !== 'critical' && routedRole !== 'geo' && routedRole !== 'all') return;
        msg = msg.slice(2);
        if (!Array.isArray(msg) || msg.length === 0) return;
      }
      const rawMsg = routedRole ? JSON.stringify(msg) : event.data;

      const msgType = msg[0];

          if (msgType === 'RELAYS') {
            const config = msg[1];
            if (!config || typeof config !== 'object') return;
            if (!relaysBucket.take()) {
              pendingRelaysConfig = config;
              if (!relaysTimer) {
                relaysTimer = setTimeout(() => {
                  relaysTimer = null;
                  const next = pendingRelaysConfig;
                  pendingRelaysConfig = null;
                  if (next && serverOpen) applyRelaysConfig(next);
                }, 6000);
              }
              return;
            }
            pendingRelaysConfig = null;
            applyRelaysConfig(config);
          } else if (msgType === 'EVENT') {
            if (!msg[1] || typeof msg[1] !== 'object') return;
            if (!outboundRateOk(msg[1])) return;
            if (heldOutbound(msg[1])) return;
            if (outboundBadgeRefused(msg[1])) return;
            const evtKind = msg[1] && typeof msg[1].kind === 'number' ? msg[1].kind : -1;
            if (archiveEnabled) { archiveOutgoingEvent(msg[1]); archiveOutgoingEmoji(msg[1]); }
            if (isAppRelayOnlyEvent(msg[1])) { sendAppRelayOnly(rawMsg); return; }
            sendToUpstreams(rawMsg, (url) => {
              if (evtKind < 0) return true;
              const blocked = kindBlacklist.get(url);
              return !(blocked && blocked.has(evtKind));
            });
          } else if (msgType === 'GEO_EVENT') {
            const geoEvt = msg[1];
            if (!geoEvt || typeof geoEvt !== 'object') return;
            if (!outboundRateOk(geoEvt)) return;
            if (heldOutbound(geoEvt)) return;
            if (outboundBadgeRefused(geoEvt)) return;
            const evtKind = geoEvt && typeof geoEvt.kind === 'number' ? geoEvt.kind : -1;
            if (archiveEnabled) archiveOutgoingEvent(geoEvt);
            if (isAppRelayOnlyEvent(geoEvt)) { sendAppRelayOnly(JSON.stringify(['EVENT', geoEvt])); return; }
            const isBlockedFor = (url) => {
              if (evtKind < 0) return false;
              const blocked = kindBlacklist.get(url);
              return !!(blocked && blocked.has(evtKind));
            };
            const geoMsg = JSON.stringify(['EVENT', geoEvt]);
            const geoUrls = canonicalRelayList(msg[2], MAX_UPSTREAMS);
            const geoSet = new Set(geoUrls);
            const sentGeo = new Set();
            WRITE_ONLY_RELAYS.forEach((url) => {
              const info = upstreams.get(url);
              if (!info || info.status !== 'connected' || !info.ws || info.ws.readyState !== WebSocket.OPEN) return;
              if (isBlockedFor(url)) return;
              try { info.ws.send(geoMsg); sentGeo.add(url); } catch { /* noop */ }
            });
            upstreams.forEach((info, url) => {
              if (WRITE_ONLY_RELAYS.has(url)) return;
              if (geoSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN && !isBlockedFor(url)) {
                try { info.ws.send(geoMsg); sentGeo.add(url); } catch { /* noop */ }
              }
            });
            // Buffer for target relays this worker is still connecting to. New
            // connections are driven by the RELAYS config (which shards relays),
            // so a worker never reaches outside its assigned set here.
            for (const url of geoUrls) {
              if (sentGeo.has(url)) continue;
              if (isBlockedFor(url)) continue;
              const info = upstreams.get(url);
              if (info && info.status === 'connecting') queuePendingGeo(url, geoMsg);
            }
            upstreams.forEach((info, url) => {
              if (WRITE_ONLY_RELAYS.has(url)) return;
              if (sentGeo.has(url)) return;
              if (!geoSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN && !isBlockedFor(url)) {
                try { info.ws.send(geoMsg); } catch { /* noop */ }
              }
            });
          } else if (msgType === 'DM_EVENT') {
            const dmEvt = msg[1];
            if (!dmEvt || typeof dmEvt !== 'object') return;
            if (!outboundRateOk(dmEvt)) return;
            if (heldOutbound(dmEvt)) return;
            if (isAppRelayOnlyEvent(dmEvt)) { sendAppRelayOnly(JSON.stringify(['EVENT', dmEvt])); return; }
            const evtKind = dmEvt && typeof dmEvt.kind === 'number' ? dmEvt.kind : -1;
            const isBlockedFor = (url) => {
              if (evtKind < 0) return false;
              const blocked = kindBlacklist.get(url);
              return !!(blocked && blocked.has(evtKind));
            };
            const dmMsg = JSON.stringify(['EVENT', dmEvt]);
            const dmSet = new Set(dmRelays);
            WRITE_ONLY_RELAYS.forEach((url) => {
              const info = upstreams.get(url);
              if (!info || info.status !== 'connected' || !info.ws || info.ws.readyState !== WebSocket.OPEN) return;
              if (isBlockedFor(url)) return;
              try { info.ws.send(dmMsg); } catch { /* noop */ }
            });
            upstreams.forEach((info, url) => {
              if (WRITE_ONLY_RELAYS.has(url)) return;
              if (dmSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN && !isBlockedFor(url)) {
                try { info.ws.send(dmMsg); } catch { /* noop */ }
              }
            });
            upstreams.forEach((info, url) => {
              if (WRITE_ONLY_RELAYS.has(url)) return;
              if (dmSet.has(url)) return;
              if (info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN && !isBlockedFor(url)) {
                try { info.ws.send(dmMsg); } catch { /* noop */ }
              }
            });
          } else if (msgType === 'REQ') {
            const subId = msg[1];
            if (typeof subId !== 'string' || !subId || subId.length > MAX_SUB_ID) return;
            const filters = msg.slice(2);
            if (filters.length === 0 || filters.length > MAX_REQ_FILTERS
              || !filters.every((f) => f && typeof f === 'object' && !Array.isArray(f))) {
              sendToClient(JSON.stringify(['CLOSED', subId, 'closed: filter limit reached']));
              return;
            }
            if (!reqBucket.take()) {
              sendToClient(JSON.stringify(['CLOSED', subId, 'closed: request limit reached']));
              return;
            }
            if (activeSubscriptions.has(subId)) closeSubscription(subId);
            while (activeSubscriptions.size >= MAX_ACTIVE_SUBS) evictIdlestSubscription();
            activeSubscriptions.set(subId, rawMsg);
            subActivity.set(subId, Date.now());
            subRole.set(subId, routedRole || 'all');
            subRelays.set(subId, new Set());
            const children = buildChildrenForParent(subId, msg);
            if (children) {
              splitChildren.set(subId, children);
              for (const child of children) childToParent.set(child.childSubId, subId);
            }
            staggerSubscribe(subId);
          } else if (msgType === 'KIND_BLACKLIST') {
            const config = msg[1];
            if (!config || typeof config !== 'object') return;
            kindBlacklist.clear();
            for (const relay of Object.keys(config).slice(0, MAX_KIND_BLACKLIST_RELAYS)) {
              const url = canonicalRelayUrl(relay);
              const kinds = config[relay];
              if (!url || !Array.isArray(kinds) || kinds.length === 0) continue;
              const set = new Set(kinds.filter(k => Number.isSafeInteger(k)).slice(0, MAX_KIND_BLACKLIST_KINDS));
              if (set.size > 0) kindBlacklist.set(url, set);
            }
          } else if (msgType === 'CLOSE') {
            const subId = msg[1];
            if (typeof subId !== 'string' || !subId) return;
            closeSubscription(subId);
          }
    } catch {
      // Parse error
    }
  });

  // Handle client disconnect
  function cleanupAll() {
    serverOpen = false;
    // Final flush of any buffered channel events.
    if (archiveEnabled && archiveBuf.size > 0) {
      const finalFlush = flushArchive().catch(() => { });
      if (context && context.waitUntil) { try { context.waitUntil(finalFlush); } catch { /* noop */ } }
    }
    if (archiveEnabled && emojiBuf.size > 0) {
      const finalEmojiFlush = flushEmojiArchive().catch(() => { });
      if (context && context.waitUntil) { try { context.waitUntil(finalEmojiFlush); } catch { /* noop */ } }
    }
    if (connectionTimer) { clearTimeout(connectionTimer); connectionTimer = null; }
    connectionQueue = [];
    pendingConnect.clear();
    inFlightConnects = 0;
    for (const [, timerId] of reconnectTimers) clearTimeout(timerId);
    reconnectTimers.clear();
    pendingReconnect.clear();
    intentionallyClosed.clear();
    if (keepaliveTimer) { clearInterval(keepaliveTimer); keepaliveTimer = null; }
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    if (relaysTimer) { clearTimeout(relaysTimer); relaysTimer = null; }
    pendingRelaysConfig = null;
    pendingGeoEvents.clear();
    pendingAppArchive.clear();
    activeSubscriptions.clear();
    subActivity.clear();
    subRelays.clear();
    upstreams.forEach((info) => {
      try { if (info.ws) info.ws.close(); } catch { /* noop */ }
    });
    upstreams.clear();
    relayRole.clear();
    subRole.clear();
    splitChildren.clear();
    childToParent.clear();
  }

  server.addEventListener('close', cleanupAll);
  server.addEventListener('error', cleanupAll);

  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}
