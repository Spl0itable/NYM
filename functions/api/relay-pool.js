// Cloudflare Pages Function: Multiplexed WebSocket relay pool proxy
// Single WebSocket from client, fans out to many upstream Nostr relays.
// Uses string-based deduplication (no JSON.parse) to minimize CPU usage.
//
// Client connects to: wss://<host>/api/relay-pool
//
// Protocol (client → proxy):
//   ["RELAYS", { relays: [...], dmRelays: [...] }]
//   ["EVENT", eventObj]          - fans out to all connected relays
//   ["GEO_EVENT", eventObj, ["wss://geo1", ...]]  - fans out to listed geo relays first, then all others
//   ["DM_EVENT", eventObj]       - fans out to DM relays first, then all others
//   ["REQ", subId, ...filters]   - fans out to all relays
//   ["CLOSE", subId]             - fans out to all relays
//   ["KIND_BLACKLIST", { "wss://relay": [kind, ...], ... }] - skip relay for REQs whose kinds are all in its set
//
// Protocol (proxy → client):
//   ["EVENT", subId, eventObj]   - deduplicated via string extraction (no JSON.parse)
//   ["OK", eventId, bool, msg]   - first OK per event ID
//   ["EOSE", subId]              - deduplicated (first per subscription ID)
//   ["NOTICE", reason, relayUrl] - attributed to originating relay
//   ["CLOSED", subId, reason, relayUrl] - attributed to originating relay
//   ["POOL:RELAY_BAN", relayUrl, reason] - relay permanently dropped (auth, restricted, etc.)
//   ["POOL:STATUS", { connected, count, latency, events }]

const NYMCHAT_APP_ORIGINS = new Set([
  'https://web.nymchat.app',
  'https://nym-staging.pages.dev'
]);

function isNymchatClient(request) {
  const origin = (request.headers.get('Origin') || '').toLowerCase();
  if (NYMCHAT_APP_ORIGINS.has(origin)) return true;
  const ua = request.headers.get('User-Agent') || '';
  return /NymchatApp\//i.test(ua) || /\bNYMApp\b/.test(ua);
}

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

export async function onRequest(context) {
  const { request, env } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }

  const clientIsNymchat = isNymchatClient(request);
  const proxySecret = env && env.NYMCHAT_PROXY_SECRET ? env.NYMCHAT_PROXY_SECRET : null;

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  // Relay pool state
  const upstreams = new Map();       // relayUrl -> { ws, type, status, eventCount, handled }
  const activeSubscriptions = new Map(); // subId -> raw JSON string of the REQ message
  const subRelays = new Map();       // subId -> Set<relayUrl> the REQ was sent to
  const splitChildren = new Map();   // parentSubId -> [{ childSubId, rawChild, filter }, ...]
  const childToParent = new Map();   // childSubId -> parentSubId
  const seenEvents = new Map();      // eventId -> 1 (string-based dedup, no JSON.parse)
  const seenOKs = new Set();         // eventId (only forward first OK per event)
  const seenEOSE = new Set();        // subId (only forward first EOSE per subscription)
  const relayLatency = new Map();    // relayUrl -> latency ms
  let dmRelays = [];
  const kindBlacklist = new Map();
  const closedKindRetries = new Map();   // relayUrl+'\n'+parentSubId -> resend count
  let serverOpen = true;

  // Dedup housekeeping — increased capacity for high relay counts
  const DEDUP_MAX = 50000;
  let dedupCounter = 0;

  const CHANNELS_DB = env && env.DB_CHANNELS;
  const archiveEnabled = !!(CHANNELS_DB && typeof CHANNELS_DB.prepare === 'function');
  const CHANNEL_EVENT_MAX = 64 * 1024;
  const ARCHIVE_FLUSH_MAX = 400;
  const ARCHIVE_BATCH = 100;
  const archiveBuf = new Map();   // eventId -> { id, channel, kind, pubkey, created_at, json }
  const ARCHIVE_SEEN_HOST = 'https://nymchat-archive.invalid';
  const ARCHIVE_SEEN_TTL = 600;

  function archiveSeenCache() {
    try { return (typeof caches !== 'undefined' && caches.default) ? caches.default : null; }
    catch { return null; }
  }

  function archiveSeenRequest(id) {
    return new Request(ARCHIVE_SEEN_HOST + '/' + id, { method: 'GET' });
  }

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
        runArchive(flushArchive());
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
  const MAX_RECONNECT_ATTEMPTS = 5;

  // Track relays pending reconnection
  const pendingReconnect = new Set();
  const reconnectTimers = new Map();
  const intentionallyClosed = new Set();
  // Relays that returned auth-required / unsupported-query CLOSED; never reconnect
  const permanentlySkipped = new Set();

  // Buffered GEO_EVENTs waiting for geo relays to connect
  // Map<relayUrl, Array<geoMsg string>>
  const pendingGeoEvents = new Map();

  // Connection batching state (used in cleanup)
  let connectionTimer = null;
  let connectionQueue = [];

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
    const events = {};
    upstreams.forEach((info, url) => {
      if (info.status === 'connected') {
        connected.push(url);
        events[url] = info.eventCount;
      }
    });
    // Only include latency for connected relays
    relayLatency.forEach((ms, url) => {
      if (connected.includes(url)) latency[url] = ms;
    });
    sendToClient(JSON.stringify(['POOL:STATUS', {
      connected,
      count: connected.length,
      latency,
      events
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

  const MAX_CHILDREN_PER_PARENT = 10;

  function buildChildrenForParent(parentSubId, msg) {
    if (!Array.isArray(msg)) return null;
    const filterCount = msg.length - 2;
    if (filterCount <= 1) return null;
    const children = [];
    if (filterCount <= MAX_CHILDREN_PER_PARENT) {
      for (let i = 2; i < msg.length; i++) {
        const childSubId = `${parentSubId}~c${i - 2}`;
        const rawChild = JSON.stringify(['REQ', childSubId, msg[i]]);
        children.push({ childSubId, rawChild, filters: [msg[i]] });
      }
    } else {
      const singleCount = MAX_CHILDREN_PER_PARENT - 1;
      for (let i = 0; i < singleCount; i++) {
        const f = msg[2 + i];
        const childSubId = `${parentSubId}~c${i}`;
        const rawChild = JSON.stringify(['REQ', childSubId, f]);
        children.push({ childSubId, rawChild, filters: [f] });
      }
      const bundle = [];
      for (let i = 2 + singleCount; i < msg.length; i++) bundle.push(msg[i]);
      const lastSubId = `${parentSubId}~c${singleCount}`;
      const rawLast = JSON.stringify(['REQ', lastSubId, ...bundle]);
      children.push({ childSubId: lastSubId, rawChild: rawLast, filters: bundle });
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
    if (attempts >= 5) {
      markPermanentlySkipped(relayUrl, 'connection-failed: repeated failures');
    }
  }

  function clearRelayFailure(relayUrl) {
    failedRelays.delete(relayUrl);
  }

  function validateRelayUrl(url) {
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== 'wss:' && parsed.protocol !== 'ws:') return false;
      if (isPrivateRelayHost(parsed.hostname)) return false;
      return true;
    } catch {
      return false;
    }
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

  // Extract OK event ID: ["OK","<eventId>",...]
  // The event ID is the second element, starts at position 6
  function extractOKEventId(raw) {
    // ["OK","  = positions 0-5, event ID starts at 6
    const start = 6;
    const end = raw.indexOf('"', start);
    if (end === -1 || end - start < 16) return null;
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
    return null;
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
    return name.trim().toLowerCase().replace(/[^\p{L}\p{N}_\-.]/gu, '').slice(0, 80);
  }

  const isArchivableChannelKind = (k) => k === 20000 || k === 23333 || k === 7;

  // Channel name for an event: 'g' for geohash (20000), 'd' for named (23333),
  // either for reactions (7).
  function channelFromTags(getTag, kind) {
    if (kind === 20000) return getTag('g');
    if (kind === 23333) return getTag('d');
    return getTag('g') || getTag('d');
  }

  function runArchive(work) {
    if (context && context.waitUntil) { try { context.waitUntil(work); } catch { /* noop */ } }
  }

  function bufferArchive(channel, eventId, kind, pubkey, createdAt, objJson) {
    if (!channel || !eventId || !objJson || objJson.length > CHANNEL_EVENT_MAX) return;
    if (archiveBuf.has(eventId)) return;
    archiveBuf.set(eventId, { id: eventId, channel, kind, pubkey: pubkey || null, created_at: createdAt || 0, json: objJson });
    if (archiveBuf.size >= ARCHIVE_FLUSH_MAX) runArchive(flushArchive());
  }

  // Inbound event from a relay (string frame).
  function archiveInboundEvent(raw, kind, eventId) {
    if (!archiveEnabled || !eventId) return;
    const channel = sanitizeChannelKey(channelFromTags((n) => extractTagValue(raw, n), kind));
    if (!channel) return;
    const objJson = extractEventObjectJson(raw);
    if (!objJson) return;
    bufferArchive(channel, eventId, kind, extractEventStringField(raw, 'pubkey'), extractEventCreatedAt(raw), objJson);
  }

  // Outbound event the client is publishing — archived immediately so sends
  // land in D1 without waiting for the relay echo (deduped, so saved once).
  function archiveOutgoingEvent(ev) {
    if (!archiveEnabled || !ev || typeof ev.id !== 'string' || !isArchivableChannelKind(ev.kind)) return;
    const tags = Array.isArray(ev.tags) ? ev.tags : [];
    const getTag = (n) => { const t = tags.find((x) => Array.isArray(x) && x[0] === n); return t ? t[1] : null; };
    const channel = sanitizeChannelKey(channelFromTags(getTag, ev.kind));
    if (!channel) return;
    bufferArchive(channel, ev.id, ev.kind, typeof ev.pubkey === 'string' ? ev.pubkey : null,
      typeof ev.created_at === 'number' ? ev.created_at : 0, JSON.stringify(ev));
  }

  // Flush buffered events as batched INSERT OR IGNORE statements. The id primary
  // key drops duplicates; an occasional failed flush is backfilled by relays.
  async function flushArchive() {
    if (!archiveEnabled || archiveBuf.size === 0) return;
    const rows = Array.from(archiveBuf.values());
    archiveBuf.clear();

    // Per-colo dedup: skip events another connection in this colo already
    // archived. Fail-open — a miss still inserts, and the id PK guards races.
    const cache = archiveSeenCache();
    let pending = rows;
    if (cache) {
      try {
        const hits = await Promise.all(rows.map(
          (r) => cache.match(archiveSeenRequest(r.id)).then((h) => !!h).catch(() => false)
        ));
        pending = rows.filter((_, i) => !hits[i]);
      } catch { pending = rows; }
    }
    if (pending.length === 0) return;

    const stmt = CHANNELS_DB.prepare(
      'INSERT OR IGNORE INTO events (id, channel, kind, pubkey, created_at, json, stored_at) VALUES (?, ?, ?, ?, ?, ?, ?)'
    );
    const now = Date.now();
    const inserted = [];
    for (let i = 0; i < pending.length; i += ARCHIVE_BATCH) {
      const slice = pending.slice(i, i + ARCHIVE_BATCH);
      const chunk = slice.map(
        (r) => stmt.bind(r.id, r.channel, r.kind, r.pubkey, r.created_at, r.json, now)
      );
      try { await CHANNELS_DB.batch(chunk); for (const r of slice) inserted.push(r); } catch { /* best-effort */ }
    }

    if (cache && inserted.length) {
      const headers = new Headers();
      headers.set('Cache-Control', 'public, max-age=' + ARCHIVE_SEEN_TTL);
      try {
        await Promise.all(inserted.map(
          (r) => cache.put(archiveSeenRequest(r.id), new Response('1', { headers })).catch(() => {})
        ));
      } catch { /* best-effort */ }
    }
  }

  // Mirror of the client-side _looksLikeRandomToken heuristic.
  // Recognises nanoid-style spam strings like "IBLm9lyTuP", "AJvgLLPASR".
  function looksLikeRandomToken(token) {
    if (!token || token.length < 8) return false;
    if (!/^[A-Za-z0-9]+$/.test(token)) return false;

    const hasUpper = /[A-Z]/.test(token);
    const hasLower = /[a-z]/.test(token);

    const half = Math.floor(token.length / 2);
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
      for (let unit = 4; unit <= Math.floor(t.length / 2); unit++) {
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
  function isSpamContent(content) {
    if (typeof content !== 'string') return false;
    const trimmed = content.trim();
    if (trimmed.includes('joined the channel via bitchat.land')) return true;
    if (trimmed.includes('["client","chorus"]')) return true;
    if (trimmed.length < 6) return false;
    if (trimmed.includes('://') || trimmed.startsWith('www.')) return false;
    if (/^ln(bc|tb|ts)/i.test(trimmed)) return false;
    if (/^cashu/i.test(trimmed)) return false;
    if (/^(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+$/i.test(trimmed)) return false;
    if (/^[0-9a-fA-F]{64}$/.test(trimmed)) return false;
    if (trimmed.includes('```') || trimmed.includes('`')) return false;
    if (trimmed.startsWith('data:image')) return false;
    const scrubbed = trimmed
      .split('\n').filter(line => !line.trimStart().startsWith('>')).join('\n')
      .replace(/@\S+/g, ' ')
      .replace(/(nostr:)?(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+/gi, ' ')
      .replace(/\b[0-9a-fA-F]{64}\b/g, ' ')
      .trim();
    return spamScore(scrubbed) >= 3;
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

  // Channel spam suppression at the pool boundary
  const RX_BLOCKED_CONTENT_BLOB = /"content":"(?:bitchat1|encmedia|enc):[A-Za-z0-9+\/=_-]{24,}"/;
  function hasBlockedContentPrefix(raw) {
    return RX_BLOCKED_CONTENT_BLOB.test(raw);
  }

  let droppedSpamCount = 0;
  function isSpamEventFrame(raw) {
    const kind = extractEventKind(raw);
    if (kind !== 20000) return false;
    const content = extractEventStringField(raw, 'content');
    if (content && isSpamContent(content)) return true;
    const nymTag = extractTagValue(raw, 'n');
    if (nymTag) {
      const cleanNym = nymTag.replace(/#[a-fA-F0-9]{4}$/, '');
      if (isSpamNym(cleanNym)) return true;
    }
    const pubkey = extractEventStringField(raw, 'pubkey');
    if (pubkey && content) {
      const now = Date.now();
      if (isContentFlooding(pubkey, now)) return true;
      trackContentFlood(pubkey, content, now);
    }
    return false;
  }

  // Connect to a relay immediately (no staggering)
  function queueConnection(relayUrl, type) {
    if (upstreams.has(relayUrl)) return;
    connectUpstream(relayUrl, type);
  }

  // The app relay and the client's curated default relays (sent as dmRelays)
  // must never be permanently skipped — they always stay reconnectable.
  function isProtectedRelay(relayUrl) {
    return relayUrl === APP_RELAY || dmRelays.includes(relayUrl);
  }

  function markPermanentlySkipped(relayUrl, reason) {
    if (!relayUrl || permanentlySkipped.has(relayUrl)) return;
    if (isProtectedRelay(relayUrl)) return;
    permanentlySkipped.add(relayUrl);
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

    const isProtected = isProtectedRelay(relayUrl);
    const attempts = reconnectAttempts.get(relayUrl) || 0;
    if (!isProtected && attempts >= MAX_RECONNECT_ATTEMPTS) {
      trackRelayFailure(relayUrl);
      reconnectAttempts.delete(relayUrl);
      markPermanentlySkipped(relayUrl, 'connection-failed: max reconnect attempts');
      return;
    }
    reconnectAttempts.set(relayUrl, attempts + 1);

    pendingReconnect.add(relayUrl);

    const baseDelay = 3000;
    const maxAttemptsForBackoff = isProtected ? 6 : attempts;
    const delay = baseDelay * Math.pow(1.5, Math.min(attempts, maxAttemptsForBackoff)) + Math.random() * 2000;

    const timerId = setTimeout(() => {
      reconnectTimers.delete(relayUrl);
      pendingReconnect.delete(relayUrl);
      if (serverOpen && !upstreams.has(relayUrl) && !intentionallyClosed.has(relayUrl)) {
        queueConnection(relayUrl, type);
      }
    }, delay);
    reconnectTimers.set(relayUrl, timerId);
  }

  function sendSubscriptionToRelay(relayUrl, ws, parentSubId) {
    if (WRITE_ONLY_RELAYS.has(relayUrl)) return;
    const blocked = kindBlacklist.get(relayUrl);
    const children = splitChildren.get(parentSubId);
    let anySent = false;
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

  function connectUpstream(relayUrl, type) {
    if (upstreams.has(relayUrl)) return;
    if (!validateRelayUrl(relayUrl)) return;
    if (relayUrl === 'wss://relay.nosflare.com') return;
    if (shouldSkipRelay(relayUrl)) return;

    const info = { ws: null, type, status: 'connecting', eventCount: 0, handled: false };
    upstreams.set(relayUrl, info);

    const connectStartTime = Date.now();

    try {
      let upstreamUrl = relayUrl;
      if (relayUrl === APP_RELAY && clientIsNymchat && proxySecret) {
        const u = new URL(relayUrl);
        u.searchParams.set('nymchat_proxy', proxySecret);
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
          schedulePoolStatus();
        }
      }, 8000);

      ws.addEventListener('open', () => {
        clearTimeout(timeout);
        info.status = 'connected';
        clearRelayFailure(relayUrl);
        reconnectAttempts.delete(relayUrl);
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

      // String-based dedup: extract event IDs without JSON.parse to minimize CPU
      ws.addEventListener('message', (event) => {
        const raw = event.data;
        if (typeof raw !== 'string' || raw.length < 10) return;

        // Detect message type from raw string prefix (avoids JSON.parse)
        // EVENT: ["EVENT","subId",{...}]
        if (raw.charCodeAt(2) === 69 && raw.startsWith('["EVENT"')) {
          const eventId = extractEventId(raw);
          if (eventId) {
            if (seenEvents.has(eventId)) return;
            seenEvents.set(eventId, 1);
            trimDedup();
          }
          if (hasBlockedContentPrefix(raw) || isSpamEventFrame(raw)) {
            droppedSpamCount++;
            return;
          }
          info.eventCount++;
          if (archiveEnabled) {
            const archiveKind = extractEventKind(raw);
            if (isArchivableChannelKind(archiveKind)) archiveInboundEvent(raw, archiveKind, eventId);
          }
          const relayTail = ',"' + relayUrl + '"]';
          if (childToParent.size > 0) {
            const subEnd = raw.indexOf('"', 10);
            if (subEnd !== -1) {
              const childSubId = raw.substring(10, subEnd);
              const parent = childToParent.get(childSubId);
              if (parent && parent !== childSubId) {
                const body = raw.substring(subEnd, raw.length - 1);
                sendToClient('["EVENT","' + parent + body + relayTail);
                return;
              }
            }
          }
          sendToClient(raw.slice(0, -1) + relayTail);

        // OK: ["OK","eventId",bool,"msg"]
        } else if (raw.charCodeAt(2) === 79 && raw.startsWith('["OK"')) {
          const eventId = extractOKEventId(raw);
          if (eventId) {
            if (seenOKs.has(eventId)) return;
            seenOKs.add(eventId);
          }
          const okMatch = raw.match(/^\["OK",(?:"([^"]*)"|null),\s*(true|false)\s*,\s*"((?:[^"\\]|\\.)*)"/);
          if (okMatch) {
            const okId = okMatch[1] || null;
            const acceptedFlag = okMatch[2] === 'true';
            const reason = okMatch[3];
            if (isUnsupportedKind(reason)) {
              sendToClient(JSON.stringify(['OK', okId, acceptedFlag, reason, relayUrl]));
              return;
            }
            if (isRelayWideRejection(reason)) {
              markPermanentlySkipped(relayUrl, `event-rejected: ${reason}`);
              sendToClient(JSON.stringify(['OK', okId, acceptedFlag, reason, relayUrl]));
              return;
            }
            if (!acceptedFlag && isPermanentRejection(reason)) {
              sendToClient(JSON.stringify(['OK', okId, false, reason, relayUrl]));
              return;
            }
          }
          sendToClient(raw);

        // EOSE, AUTH, NOTICE, CLOSED, or anything else
        } else {
          if (raw.charCodeAt(2) === 69 && raw.startsWith('["EOSE"')) {
            const eoseMatch = raw.match(/^\["EOSE","([^"]+)"/);
            if (eoseMatch) {
              const eoseSubId = eoseMatch[1];
              const parent = childToParent.get(eoseSubId) || eoseSubId;
              if (seenEOSE.has(parent)) return;
              seenEOSE.add(parent);
              if (parent !== eoseSubId) {
                sendToClient('["EOSE","' + parent + '"]');
                return;
              }
            }
            sendToClient(raw);
            return;
          }

          if (raw.startsWith('["AUTH"')) {
            // NIP-42 challenge only; we don't authenticate. Most relays still
            // serve reads after sending it, so don't skip — a real auth wall
            // arrives as a CLOSED/NOTICE rejection and is handled there.
            return;
          }

          if (raw.startsWith('["NOTICE"')) {
            const m = raw.match(/^\["NOTICE",\s*"((?:[^"\\]|\\.)*)"/);
            const reason = m ? m[1] : '';
            if (/no such sub|unknown subscription/i.test(reason)) return;
            if (m && isUnsupportedKind(reason)) {
              sendToClient(JSON.stringify(['NOTICE', reason, relayUrl]));
              return;
            }
            if (m && isRelayWideRejection(reason)) {
              markPermanentlySkipped(relayUrl, reason);
              return;
            }
            sendToClient(JSON.stringify(['NOTICE', reason, relayUrl]));
            return;
          }

          if (raw.startsWith('["CLOSED"')) {
            const m = raw.match(/^\["CLOSED","([^"]+)",\s*"((?:[^"\\]|\\.)*)"/);
            const closedSubId = m ? m[1] : '';
            const reason = m ? m[2] : '';
            const parentSubId = childToParent.get(closedSubId) || closedSubId;
            if (m && isRelayWideRejection(reason)) {
              markPermanentlySkipped(relayUrl, reason);
              sendToClient(JSON.stringify(['CLOSED', parentSubId, reason, relayUrl]));
              return;
            }
            if (m && isUnsupportedKind(reason)) {
              const rejectedKind = extractRejectedKind(reason);
              if (rejectedKind !== null) {
                let bl = kindBlacklist.get(relayUrl);
                if (!bl) { bl = new Set(); kindBlacklist.set(relayUrl, bl); }
                bl.add(rejectedKind);
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
            return;
          }

          sendToClient(raw);
        }
      });

      ws.addEventListener('close', () => {
        clearTimeout(timeout);
        if (info.handled) return;
        info.handled = true;

        const wasConnected = info.status === 'connected';
        info.status = 'closed';
        upstreams.delete(relayUrl);
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
          scheduleReconnect(relayUrl, type);
        } else {
          trackRelayFailure(relayUrl);
        }
      });

      ws.addEventListener('error', () => {
        clearTimeout(timeout);
        if (info.handled) return;
        info.handled = true;

        info.status = 'failed';
        trackRelayFailure(relayUrl);
        upstreams.delete(relayUrl);
        schedulePoolStatus();
      });
    } catch {
      info.handled = true;
      info.status = 'failed';
      trackRelayFailure(relayUrl);
      upstreams.delete(relayUrl);
      schedulePoolStatus();
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

  // Handle messages from client
  server.addEventListener('message', (event) => {
    try {
      const msg = JSON.parse(event.data);
      if (!Array.isArray(msg)) return;

      const msgType = msg[0];

          if (msgType === 'RELAYS') {
            const config = msg[1];
            if (!config || typeof config !== 'object') return;

            dmRelays = config.dmRelays || [];

            const requestedRelays = config.relays || [];

            const newRelaySet = new Set(requestedRelays);
            for (const [url, info] of upstreams) {
              if (!newRelaySet.has(url)) {
                intentionallyClosed.add(url);
                try { if (info.ws) info.ws.close(); } catch { /* noop */ }
                upstreams.delete(url);
              }
            }

            for (const [, timerId] of reconnectTimers) {
              clearTimeout(timerId);
            }
            reconnectTimers.clear();
            pendingReconnect.clear();

            for (const url of requestedRelays) {
              if (!upstreams.has(url)) {
                queueConnection(url, 'read');
              }
            }
          } else if (msgType === 'EVENT') {
            const evtKind = msg[1] && typeof msg[1].kind === 'number' ? msg[1].kind : -1;
            if (archiveEnabled) archiveOutgoingEvent(msg[1]);
            sendToUpstreams(event.data, (url) => {
              if (evtKind < 0) return true;
              const blocked = kindBlacklist.get(url);
              return !(blocked && blocked.has(evtKind));
            });
          } else if (msgType === 'GEO_EVENT') {
            const geoEvt = msg[1];
            const evtKind = geoEvt && typeof geoEvt.kind === 'number' ? geoEvt.kind : -1;
            if (archiveEnabled) archiveOutgoingEvent(geoEvt);
            const isBlockedFor = (url) => {
              if (evtKind < 0) return false;
              const blocked = kindBlacklist.get(url);
              return !!(blocked && blocked.has(evtKind));
            };
            const geoMsg = JSON.stringify(['EVENT', geoEvt]);
            const geoUrls = msg[2] || [];
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
            for (const url of geoUrls) {
              if (sentGeo.has(url)) continue;
              if (isBlockedFor(url)) continue;
              const info = upstreams.get(url);
              if (info && info.status === 'connecting') {
                if (!pendingGeoEvents.has(url)) pendingGeoEvents.set(url, []);
                pendingGeoEvents.get(url).push(geoMsg);
              } else if (!info && validateRelayUrl(url)) {
                queueConnection(url, 'read');
                if (!pendingGeoEvents.has(url)) pendingGeoEvents.set(url, []);
                pendingGeoEvents.get(url).push(geoMsg);
              }
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
              if (!dmSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN && !isBlockedFor(url)) {
                try { info.ws.send(dmMsg); } catch { /* noop */ }
              }
            });
          } else if (msgType === 'REQ') {
            const subId = msg[1];
            activeSubscriptions.set(subId, event.data);
            subRelays.set(subId, new Set());

            const children = buildChildrenForParent(subId, msg);
            if (children) {
              splitChildren.set(subId, children);
              for (const child of children) childToParent.set(child.childSubId, subId);
            }

            upstreams.forEach((info, url) => {
              if (info.status !== 'connected' || !info.ws || info.ws.readyState !== 1) return;
              sendSubscriptionToRelay(url, info.ws, subId);
            });
          } else if (msgType === 'KIND_BLACKLIST') {
            const config = msg[1];
            if (!config || typeof config !== 'object') return;
            kindBlacklist.clear();
            for (const relay of Object.keys(config)) {
              const kinds = config[relay];
              if (Array.isArray(kinds) && kinds.length > 0) {
                kindBlacklist.set(relay, new Set(kinds.filter(k => typeof k === 'number')));
              }
            }
          } else if (msgType === 'CLOSE') {
            const subId = msg[1];
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
              sendToUpstreams(event.data, (url) => targets.has(url));
            }
            activeSubscriptions.delete(subId);
            subRelays.delete(subId);
            seenEOSE.delete(subId);
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
    if (connectionTimer) { clearTimeout(connectionTimer); connectionTimer = null; }
    connectionQueue = [];
    for (const [, timerId] of reconnectTimers) clearTimeout(timerId);
    reconnectTimers.clear();
    pendingReconnect.clear();
    intentionallyClosed.clear();
    if (keepaliveTimer) { clearInterval(keepaliveTimer); keepaliveTimer = null; }
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    upstreams.forEach((info) => {
      try { if (info.ws) info.ws.close(); } catch { /* noop */ }
    });
    upstreams.clear();
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
