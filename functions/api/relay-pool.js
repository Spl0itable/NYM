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
//   ["GEO_REQ", ["wss://geo1",...], subId, ...filters] - geo relays first, then all other read relays
//   ["CLOSE", subId]             - fans out to read relays only
//
// Protocol (proxy → client):
//   ["EVENT", subId, eventObj]   - deduplicated via string extraction (no JSON.parse)
//   ["OK", eventId, bool, msg]   - first OK per event ID
//   ["EOSE", subId]              - deduplicated (first per subscription ID)
//   ["NOTICE", msg]              - forwarded as-is
//   ["POOL:STATUS", { connected, failed, count, latency, events, relayTypes }]

export async function onRequest(context) {
  const { request } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  // Relay pool state
  const upstreams = new Map();       // relayUrl -> { ws, type, status, eventCount, handled }
  const activeSubscriptions = new Map(); // subId -> raw JSON string of the REQ message
  const seenEvents = new Map();      // eventId -> 1 (string-based dedup, no JSON.parse)
  const seenOKs = new Set();         // eventId (only forward first OK per event)
  const seenEOSE = new Set();        // subId (only forward first EOSE per subscription)
  const relayLatency = new Map();    // relayUrl -> latency ms
  let writeOnlyRelays = new Set();
  let dmRelays = [];
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

  // Buffered GEO_EVENTs waiting for geo relays to connect
  // Map<relayUrl, Array<geoMsg string>>
  const pendingGeoEvents = new Map();

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
    const failure = failedRelays.get(relayUrl);
    if (failure) {
      const backoff = Math.min(FAILED_COOLDOWN * Math.pow(2, failure.attempts - 1), MAX_BACKOFF);
      if (Date.now() - failure.failedAt < backoff) return true;
      failedRelays.delete(relayUrl);
    }
    return false;
  }

  function trackRelayFailure(relayUrl) {
    const existing = failedRelays.get(relayUrl);
    const attempts = existing ? existing.attempts + 1 : 1;
    failedRelays.set(relayUrl, { failedAt: Date.now(), attempts });
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

  // Connect to a relay immediately (no staggering)
  function queueConnection(relayUrl, type) {
    if (upstreams.has(relayUrl)) return;
    connectUpstream(relayUrl, type);
  }

  function scheduleReconnect(relayUrl, type) {
    if (!serverOpen) return;
    if (pendingReconnect.has(relayUrl)) return;

    const attempts = reconnectAttempts.get(relayUrl) || 0;
    if (attempts >= MAX_RECONNECT_ATTEMPTS) {
      trackRelayFailure(relayUrl);
      reconnectAttempts.delete(relayUrl);
      return;
    }
    reconnectAttempts.set(relayUrl, attempts + 1);

    pendingReconnect.add(relayUrl);

    const baseDelay = 3000;
    const delay = baseDelay * Math.pow(1.5, attempts) + Math.random() * 2000;

    const timerId = setTimeout(() => {
      reconnectTimers.delete(relayUrl);
      pendingReconnect.delete(relayUrl);
      if (serverOpen && !upstreams.has(relayUrl) && !intentionallyClosed.has(relayUrl)) {
        queueConnection(relayUrl, type);
      }
    }, delay);
    reconnectTimers.set(relayUrl, timerId);
  }

  // Replay all active subscriptions to a newly connected relay
  function replaySubscriptions(relayUrl, ws) {
    if (writeOnlyRelays.has(relayUrl)) return;
    for (const [, reqMsg] of activeSubscriptions) {
      try { ws.send(reqMsg); } catch { /* noop */ }
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
      const ws = new WebSocket(relayUrl);
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

        // EOSE, NOTICE, or anything else
        } else {
          // Deduplicate EOSE: only forward the first EOSE per subscription ID
          if (raw.charCodeAt(2) === 69 && raw.startsWith('["EOSE"')) {
            const eoseMatch = raw.match(/^\["EOSE","([^"]+)"/);
            if (eoseMatch) {
              const eoseSubId = eoseMatch[1];
              if (seenEOSE.has(eoseSubId)) return;
              seenEOSE.add(eoseSubId);
            }
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
          } else if (msgType === 'GEO_REQ') {
            // ["GEO_REQ", ["wss://geo1", ...], subId, ...filters]
            // Send REQ to geo relays first, then all other read relays
            const geoList = msg[1] || [];
            const reqMsg = JSON.stringify(['REQ', ...msg.slice(2)]);
            const subId = msg[2];
            activeSubscriptions.set(subId, reqMsg);
            const geoSet = new Set(geoList);
            // Ensure geo relays are connected (they'll get subscription via replaySubscriptions)
            for (const url of geoList) {
              if (!upstreams.has(url) && validateRelayUrl(url)) {
                queueConnection(url, 'read');
              }
            }
            // Geo relays first
            upstreams.forEach((info, url) => {
              if (geoSet.has(url) && info.type !== 'write' && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(reqMsg); } catch { /* noop */ }
              }
            });
            // Then all other read relays
            upstreams.forEach((info, url) => {
              if (!geoSet.has(url) && info.type !== 'write' && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(reqMsg); } catch { /* noop */ }
              }
            });
          } else if (msgType === 'REQ') {
            const subId = msg[1];
            activeSubscriptions.set(subId, event.data);
            sendToUpstreams(event.data, (url, info) => info.type !== 'write');
          } else if (msgType === 'CLOSE') {
            const subId = msg[1];
            activeSubscriptions.delete(subId);
            seenEOSE.delete(subId); // Allow EOSE for future subscriptions with same pattern
            sendToUpstreams(event.data, (url, info) => info.type !== 'write');
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
