// Cloudflare Pages Function: Multiplexed WebSocket relay pool proxy
// Single WebSocket from client, fans out to many upstream Nostr relays.
// Uses string-based deduplication (no JSON.parse) to minimize CPU usage.
//
// Client connects to: wss://<host>/api/relay-pool
//
// Protocol (client → proxy):
//   ["RELAYS", { relays: [...], writeOnly: [...], dmRelays: [...] }]
//   ["EVENT", eventObj]          - fans out to all connected relays
//   ["GEO_EVENT", eventObj, ["wss://geo1", ...]]  - fans out to listed geo relays first, then all others
//   ["DM_EVENT", eventObj]       - fans out to DM relays first, then all others
//   ["REQ", subId, ...filters]   - fans out to read relays only
//   ["CLOSE", subId]             - fans out to read relays only
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
  'https://web.nymchat.app'
]);

function isNymchatClient(request) {
  const origin = (request.headers.get('Origin') || '').toLowerCase();
  if (NYMCHAT_APP_ORIGINS.has(origin)) return true;
  const ua = request.headers.get('User-Agent') || '';
  return /NymchatApp\//i.test(ua) || /\bNYMApp\b/.test(ua);
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
  const seenEvents = new Map();      // eventId -> 1 (string-based dedup, no JSON.parse)
  const seenOKs = new Set();         // eventId (only forward first OK per event)
  const seenEOSE = new Set();        // subId (only forward first EOSE per subscription)
  const relayLatency = new Map();    // relayUrl -> latency ms
  let writeOnlyRelays = new Set();
  let dmRelays = [];
  const kindBlacklist = new Map();
  let serverOpen = true;

  // Dedup housekeeping — increased capacity for high relay counts
  const DEDUP_MAX = 50000;
  let dedupCounter = 0;

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
      || /\binvalid query\b/i.test(reason);
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
      return parsed.protocol === 'wss:' || parsed.protocol === 'ws:';
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

  const RX_ZERO_WIDTH = /[​-‏‪-‮⁠-⁯﻿]/;
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
      if ((hasLatin && hasCyrillic) || (hasLatin && hasGreek) || (hasCyrillic && hasGreek)) {
        return true;
      }
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

    if (RX_ZERO_WIDTH.test(trimmed)) score += 3;
    if (hasRepeatedTokenSpam(trimmed)) score += 3;
    if (hasMixedScriptToken(trimmed)) score += 2;

    const tokens = trimmed.split(/\s+/).filter(Boolean);
    if (tokens.length === 1) {
      if (looksLikeRandomToken(tokens[0])) score += 3;
      score += scoreSingleAlphanumWord(tokens[0]);
      if (tokens[0].length >= 12) score += 1;
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
    if (/^(npub|nsec|note|nevent|naddr)1[a-z0-9]+$/i.test(trimmed)) return false;
    if (trimmed.includes('```') || trimmed.includes('`')) return false;
    if (trimmed.startsWith('data:image')) return false;
    return spamScore(trimmed) >= 3;
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

  function markPermanentlySkipped(relayUrl, reason) {
    if (!relayUrl || permanentlySkipped.has(relayUrl)) return;
    if (relayUrl === APP_RELAY) return;
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

    const isAppRelay = relayUrl === APP_RELAY;
    const attempts = reconnectAttempts.get(relayUrl) || 0;
    if (!isAppRelay && attempts >= MAX_RECONNECT_ATTEMPTS) {
      trackRelayFailure(relayUrl);
      reconnectAttempts.delete(relayUrl);
      markPermanentlySkipped(relayUrl, 'connection-failed: max reconnect attempts');
      return;
    }
    reconnectAttempts.set(relayUrl, attempts + 1);

    pendingReconnect.add(relayUrl);

    const baseDelay = 3000;
    const maxAttemptsForBackoff = isAppRelay ? 6 : attempts;
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

  function replaySubscriptions(relayUrl, ws) {
    if (writeOnlyRelays.has(relayUrl)) return;
    for (const [subId, reqMsg] of activeSubscriptions) {
      try {
        ws.send(reqMsg);
        let targets = subRelays.get(subId);
        if (!targets) { targets = new Set(); subRelays.set(subId, targets); }
        targets.add(relayUrl);
      } catch { /* noop */ }
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
            if (seenEvents.has(eventId)) return; // Dedup
            seenEvents.set(eventId, 1);
            trimDedup();
          }
          // Drop channel spam server-side so the client never has to render
          // a flood of gibberish kind-20000 events.
          if (isSpamEventFrame(raw)) {
            droppedSpamCount++;
            return;
          }
          info.eventCount++;
          sendToClient(raw);

        // OK: ["OK","eventId",bool,"msg"]
        } else if (raw.charCodeAt(2) === 79 && raw.startsWith('["OK"')) {
          const eventId = extractOKEventId(raw);
          if (eventId) {
            if (seenOKs.has(eventId)) return;
            seenOKs.add(eventId);
          }
          sendToClient(raw);

        // EOSE, AUTH, NOTICE, CLOSED, or anything else
        } else {
          // EOSE dedup: only forward the first per subId
          if (raw.charCodeAt(2) === 69 && raw.startsWith('["EOSE"')) {
            const eoseMatch = raw.match(/^\["EOSE","([^"]+)"/);
            if (eoseMatch) {
              const eoseSubId = eoseMatch[1];
              if (seenEOSE.has(eoseSubId)) return;
              seenEOSE.add(eoseSubId);
            }
            sendToClient(raw);
            return;
          }

          if (raw.startsWith('["AUTH"')) {
            markPermanentlySkipped(relayUrl, 'auth-required');
            return;
          }

          if (raw.startsWith('["NOTICE"')) {
            const m = raw.match(/^\["NOTICE",\s*"((?:[^"\\]|\\.)*)"/);
            const reason = m ? m[1] : '';
            if (/no such sub|unknown subscription/i.test(reason)) return;
            if (m && isPermanentRejection(reason)) {
              markPermanentlySkipped(relayUrl, reason);
              return;
            }
            sendToClient(JSON.stringify(['NOTICE', reason, relayUrl]));
            return;
          }

          if (raw.startsWith('["CLOSED"')) {
            const m = raw.match(/^\["CLOSED","([^"]+)",\s*"((?:[^"\\]|\\.)*)"/);
            const subId = m ? m[1] : '';
            const reason = m ? m[2] : '';
            if (m && isPermanentRejection(reason)) {
              markPermanentlySkipped(relayUrl, reason);
              sendToClient(JSON.stringify(['CLOSED', subId, reason, relayUrl]));
              return;
            }
            sendToClient(JSON.stringify(['CLOSED', subId, reason, relayUrl]));
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
    upstreams.forEach((info, url) => {
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

            const writeOnly = config.writeOnly || [];
            dmRelays = config.dmRelays || [];
            writeOnlyRelays = new Set(writeOnly);

            const requestedRelays = config.relays || [];

            // Disconnect relays no longer in the list
            const newRelaySet = new Set([...requestedRelays, ...writeOnly]);
            for (const [url, info] of upstreams) {
              if (!newRelaySet.has(url)) {
                intentionallyClosed.add(url);
                try { if (info.ws) info.ws.close(); } catch { /* noop */ }
                upstreams.delete(url);
              }
            }

            // Cancel ALL pending reconnect timers
            for (const [, timerId] of reconnectTimers) {
              clearTimeout(timerId);
            }
            reconnectTimers.clear();
            pendingReconnect.clear();

            // Connect all relays immediately (geo relays first in the array)
            for (const url of requestedRelays) {
              if (!upstreams.has(url)) {
                queueConnection(url, writeOnlyRelays.has(url) ? 'write' : 'read');
              }
            }
            for (const url of writeOnly) {
              if (!upstreams.has(url)) {
                queueConnection(url, 'write');
              }
            }
          } else if (msgType === 'EVENT') {
            sendToUpstreams(event.data);
          } else if (msgType === 'GEO_EVENT') {
            const geoMsg = JSON.stringify(['EVENT', msg[1]]);
            const geoUrls = msg[2] || [];
            const geoSet = new Set(geoUrls);
            const sentGeo = new Set();
            // Send to connected geo relays first
            upstreams.forEach((info, url) => {
              if (geoSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(geoMsg); sentGeo.add(url); } catch { /* noop */ }
              }
            });
            // For geo relays that aren't connected yet, ensure they get connected
            // and buffer the event so it gets sent when they open
            // (critical for ephemeral kind 20000 which relays don't store)
            for (const url of geoUrls) {
              if (sentGeo.has(url)) continue;
              const info = upstreams.get(url);
              if (info && info.status === 'connecting') {
                // Relay is connecting — buffer this event for delivery on open
                if (!pendingGeoEvents.has(url)) pendingGeoEvents.set(url, []);
                pendingGeoEvents.get(url).push(geoMsg);
              } else if (!info && validateRelayUrl(url)) {
                // Relay not in upstreams at all — queue connection and buffer
                queueConnection(url, 'read');
                if (!pendingGeoEvents.has(url)) pendingGeoEvents.set(url, []);
                pendingGeoEvents.get(url).push(geoMsg);
              }
            }
            // Then send to all other connected relays
            upstreams.forEach((info, url) => {
              if (!geoSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(geoMsg); } catch { /* noop */ }
              }
            });
          } else if (msgType === 'DM_EVENT') {
            const dmMsg = JSON.stringify(['EVENT', msg[1]]);
            const dmSet = new Set(dmRelays);
            upstreams.forEach((info, url) => {
              if (dmSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(dmMsg); } catch { /* noop */ }
              }
            });
            upstreams.forEach((info, url) => {
              if (!dmSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(dmMsg); } catch { /* noop */ }
              }
            });
          } else if (msgType === 'REQ') {
            const subId = msg[1];
            activeSubscriptions.set(subId, event.data);
            const reqTargets = new Set();
            subRelays.set(subId, reqTargets);
            const reqKinds = new Set();
            for (let i = 2; i < msg.length; i++) {
              const f = msg[i];
              if (f && Array.isArray(f.kinds)) {
                for (const k of f.kinds) reqKinds.add(k);
              }
            }
            sendToUpstreams(event.data, (url, info) => {
              if (info.type === 'write') return false;
              if (reqKinds.size > 0) {
                const blocked = kindBlacklist.get(url);
                if (blocked && blocked.size > 0) {
                  let allBlocked = true;
                  for (const k of reqKinds) {
                    if (!blocked.has(k)) { allBlocked = false; break; }
                  }
                  if (allBlocked) return false;
                }
              }
              reqTargets.add(url);
              return true;
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
            activeSubscriptions.delete(subId);
            subRelays.delete(subId);
            seenEOSE.delete(subId);
            if (targets && targets.size > 0) {
              sendToUpstreams(event.data, (url, info) => info.type !== 'write' && targets.has(url));
            }
          }
    } catch {
      // Parse error
    }
  });

  // Handle client disconnect
  function cleanupAll() {
    serverOpen = false;
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
  }

  server.addEventListener('close', cleanupAll);
  server.addEventListener('error', cleanupAll);

  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}
