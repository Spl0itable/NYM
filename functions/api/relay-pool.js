// Cloudflare Pages Function: Multiplexed WebSocket relay pool proxy
// Single WebSocket from client, fans out to many upstream Nostr relays.
// Deduplicates events server-side before forwarding to client.
//
// Client connects to: wss://<host>/api/relay-pool
//
// Protocol (client → proxy):
//   ["RELAYS", { relays: ["wss://relay1.com", ...], writeOnly: ["wss://sendit.nosflare.com"], dmRelays: ["wss://relay.damus.io", ...] }]
//   ["EVENT", eventObj]          - fans out to all connected relays
//   ["GEO_EVENT", eventObj, ["wss://geo1", ...]]  - fans out to listed geo relays first, then all others
//   ["DM_EVENT", eventObj]       - fans out to DM relays first, then all others
//   ["REQ", subId, ...filters]   - fans out to read relays only
//   ["CLOSE", subId]             - fans out to read relays only
//
// Protocol (proxy → client):
//   ["EVENT", subId, eventObj]   - deduplicated
//   ["OK", eventId, bool, msg]   - first OK response from any relay
//   ["EOSE", subId]              - sent once all read relays respond or after 3s timeout
//   ["NOTICE", msg]              - forwarded from any relay
//   ["POOL:STATUS", { connected: [...], failed: [...], count: N }]

export async function onRequest(context) {
  const { request } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  // Relay pool state
  const upstreams = new Map();       // relayUrl -> { ws, type, status }
  const seenEvents = new Map();      // eventId -> true (dedup)
  const seenOKs = new Set();         // eventId (only forward first OK)
  const eoseTracker = new Map();     // subId -> { expected: Set, received: Set, sent, timer }
  const activeSubscriptions = new Map(); // subId -> raw JSON string of the REQ message
  const relayLatency = new Map();    // relayUrl -> latency ms
  const relayEvents = new Map();     // relayUrl -> event count
  let writeOnlyRelays = new Set();
  let dmRelays = [];
  let serverOpen = true;

  // Keepalive: send periodic POOL:PING to prevent Cloudflare idle timeout
  // Cloudflare Workers WebSocket connections can be terminated after ~100s idle
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
  }, 30000); // Every 30 seconds

  // Track failed relays to avoid wasting cycles
  const failedRelays = new Map();      // relayUrl -> { failedAt, attempts }
  const FAILED_COOLDOWN = 60000;       // 1 minute before retrying a failed relay
  const MAX_BACKOFF = 180000;          // 3 minute max backoff

  // Track reconnection attempts separately from failure cooldown
  const reconnectAttempts = new Map(); // relayUrl -> number of consecutive reconnects
  const MAX_RECONNECT_ATTEMPTS = 5;   // Stop reconnecting after this many consecutive failures

  // Connection staggering for large relay sets
  let connectionQueue = [];
  let connectionTimer = null;
  const CONNECTION_STAGGER_MS = 100;   // 100ms between relay connections
  const MAX_CONCURRENT = 20;           // Max simultaneous connecting relays

  // Track relays pending reconnection to avoid duplicate queue entries
  const pendingReconnect = new Set();  // relayUrls scheduled for reconnect
  const reconnectTimers = new Map();   // relayUrl -> timeoutId (so we can cancel them)
  const intentionallyClosed = new Set(); // relays closed by RELAYS config update (no reconnect)

  // Throttle pool status updates: guaranteed delivery every 300ms at most
  let statusTimer = null;
  function schedulePoolStatus() {
    if (statusTimer) return; // Already scheduled — will fire soon
    statusTimer = setTimeout(() => {
      statusTimer = null;
      sendPoolStatus();
    }, 300);
  }

  // Clean old dedup entries periodically
  const DEDUP_MAX = 5000;

  function trimDedup() {
    if (seenEvents.size > DEDUP_MAX) {
      const toDelete = seenEvents.size - DEDUP_MAX;
      let deleted = 0;
      for (const key of seenEvents.keys()) {
        if (deleted >= toDelete) break;
        seenEvents.delete(key);
        deleted++;
      }
    }
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
    const failed = [];
    const latency = {};
    const events = {};
    const relayTypes = {};
    upstreams.forEach((info, url) => {
      if (info.status === 'connected') connected.push(url);
      else if (info.status === 'failed') failed.push(url);
      relayTypes[url] = info.type;
    });
    relayLatency.forEach((ms, url) => { latency[url] = ms; });
    relayEvents.forEach((count, url) => { events[url] = count; });
    sendToClient(JSON.stringify(['POOL:STATUS', {
      connected,
      failed,
      count: connected.length,
      latency,
      events,
      relayTypes,
      skippedFailed: failedRelays.size
    }]));
  }

  function shouldSkipRelay(relayUrl) {
    // Check if relay is in failed cooldown with exponential backoff
    const failure = failedRelays.get(relayUrl);
    if (failure) {
      const backoff = Math.min(FAILED_COOLDOWN * Math.pow(2, failure.attempts - 1), MAX_BACKOFF);
      if (Date.now() - failure.failedAt < backoff) return true;
      // Cooldown expired, allow retry
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

  // Stagger relay connections to avoid overwhelming the worker
  function queueConnection(relayUrl, type) {
    if (upstreams.has(relayUrl)) return;
    // Avoid duplicate entries in the queue
    if (connectionQueue.some(item => item.url === relayUrl)) return;
    connectionQueue.push({ url: relayUrl, type });
    drainConnectionQueue();
  }

  function drainConnectionQueue() {
    if (connectionTimer) return;
    if (connectionQueue.length === 0) return;

    // Count currently connecting relays
    let connecting = 0;
    upstreams.forEach(info => { if (info.status === 'connecting') connecting++; });
    if (connecting >= MAX_CONCURRENT) {
      // Wait and retry
      connectionTimer = setTimeout(() => { connectionTimer = null; drainConnectionQueue(); }, CONNECTION_STAGGER_MS);
      return;
    }

    const next = connectionQueue.shift();
    if (next) {
      connectUpstream(next.url, next.type);
    }

    if (connectionQueue.length > 0) {
      connectionTimer = setTimeout(() => { connectionTimer = null; drainConnectionQueue(); }, CONNECTION_STAGGER_MS);
    }
  }

  // Schedule a reconnection through the queue with jittered delay
  function scheduleReconnect(relayUrl, type) {
    if (!serverOpen) return;
    if (pendingReconnect.has(relayUrl)) return;

    // Check reconnect attempt limit
    const attempts = reconnectAttempts.get(relayUrl) || 0;
    if (attempts >= MAX_RECONNECT_ATTEMPTS) {
      trackRelayFailure(relayUrl);
      reconnectAttempts.delete(relayUrl);
      return;
    }
    reconnectAttempts.set(relayUrl, attempts + 1);

    pendingReconnect.add(relayUrl);

    // Jittered exponential delay: base 3s, grows with attempts, plus random jitter
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
    // Block relay.nosflare.com entirely
    if (relayUrl === 'wss://relay.nosflare.com') return;
    // Skip relays in failed cooldown
    if (shouldSkipRelay(relayUrl)) return;

    const info = { ws: null, type, status: 'connecting', handled: false };
    upstreams.set(relayUrl, info);

    const connectStartTime = Date.now();

    try {
      const ws = new WebSocket(relayUrl);
      info.ws = ws;

      // Connection timeout — 8s to accommodate slower geo relays
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
        // Clear reconnect attempt counter on successful connection
        reconnectAttempts.delete(relayUrl);
        relayLatency.set(relayUrl, Date.now() - connectStartTime);
        // Replay active subscriptions so this relay starts sending events
        replaySubscriptions(relayUrl, ws);
        schedulePoolStatus();
      });

      ws.addEventListener('message', (event) => {
        context.waitUntil(
          (async () => {
            try {
              const msg = JSON.parse(event.data);
              if (!Array.isArray(msg)) return;

              const msgType = msg[0];

              if (msgType === 'EVENT') {
                // Track per-relay event count
                relayEvents.set(relayUrl, (relayEvents.get(relayUrl) || 0) + 1);

                const eventObj = msg[2];
                if (eventObj && eventObj.id) {
                  // Deduplicate
                  if (seenEvents.has(eventObj.id)) return;
                  seenEvents.set(eventObj.id, true);
                  trimDedup();
                }
                // Forward to client with source relay for stats
                sendToClient(JSON.stringify(['EVENT', msg[1], eventObj, relayUrl]));

              } else if (msgType === 'OK') {
                const eventId = msg[1];
                // Only forward the first OK per event
                if (seenOKs.has(eventId)) return;
                seenOKs.add(eventId);
                // Clean up old OKs
                if (seenOKs.size > 1000) {
                  let deleted = 0;
                  for (const key of seenOKs) {
                    if (deleted >= 500) break;
                    seenOKs.delete(key);
                    deleted++;
                  }
                }
                sendToClient(event.data);
              } else if (msgType === 'EOSE') {
                const subId = msg[1];
                const tracker = eoseTracker.get(subId);
                if (tracker) {
                  tracker.received.add(relayUrl);
                  if (!tracker.sent && tracker.received.size >= tracker.expected.size) {
                    tracker.sent = true;
                    if (tracker.timer) clearTimeout(tracker.timer);
                    sendToClient(event.data);
                    eoseTracker.delete(subId);
                  }
                }
                // For late-connecting relays, EOSE is expected but no tracker — just ignore
              } else if (msgType === 'NOTICE') {
                sendToClient(event.data);
              }
            } catch {
              // Parse error, ignore
            }
          })()
        );
      });

      ws.addEventListener('close', () => {
        clearTimeout(timeout);
        // Guard against double-handling from error+close both firing
        if (info.handled) return;
        info.handled = true;

        const wasConnected = info.status === 'connected';
        info.status = 'closed';
        upstreams.delete(relayUrl);
        schedulePoolStatus();

        // Don't reconnect relays that were intentionally removed by a RELAYS config update
        if (intentionallyClosed.has(relayUrl)) {
          intentionallyClosed.delete(relayUrl);
          return;
        }

        if (wasConnected) {
          // Was a healthy connection that dropped — schedule reconnection
          // through the queue with jitter to avoid thundering herd
          scheduleReconnect(relayUrl, type);
        } else {
          // Never fully connected — track as failure
          trackRelayFailure(relayUrl);
        }
      });

      ws.addEventListener('error', () => {
        clearTimeout(timeout);
        // Guard against double-handling from error+close both firing
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
    context.waitUntil(
      (async () => {
        try {
          const msg = JSON.parse(event.data);
          if (!Array.isArray(msg)) return;

          const msgType = msg[0];

          if (msgType === 'RELAYS') {
            // Configure relay pool
            const config = msg[1];
            if (!config || typeof config !== 'object') return;

            const relays = config.relays || [];
            const writeOnly = config.writeOnly || [];
            dmRelays = config.dmRelays || [];

            writeOnlyRelays = new Set(writeOnly);

            // Disconnect relays no longer in the list
            const newRelaySet = new Set([...relays, ...writeOnly]);
            for (const [url, info] of upstreams) {
              if (!newRelaySet.has(url)) {
                // Mark as intentional so close handler doesn't schedule reconnection
                intentionallyClosed.add(url);
                try { if (info.ws) info.ws.close(); } catch { /* noop */ }
                upstreams.delete(url);
              }
            }

            // Cancel ALL pending reconnect timers (not just clear the Set)
            for (const [url, timerId] of reconnectTimers) {
              clearTimeout(timerId);
            }
            reconnectTimers.clear();
            connectionQueue = [];
            pendingReconnect.clear();
            if (connectionTimer) { clearTimeout(connectionTimer); connectionTimer = null; }

            // Connect new relays with staggering to avoid overwhelming the worker
            for (const url of relays) {
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
            // Fan out EVENT to all connected relays
            sendToUpstreams(event.data);
          } else if (msgType === 'GEO_EVENT') {
            // Rewrite as EVENT for the wire protocol
            const geoMsg = JSON.stringify(['EVENT', msg[1]]);
            const geoSet = new Set(msg[2] || []);
            // Send to geo relays first for lowest latency to bitchat users
            upstreams.forEach((info, url) => {
              if (geoSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(geoMsg); } catch { /* noop */ }
              }
            });
            // Then all others
            upstreams.forEach((info, url) => {
              if (!geoSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(geoMsg); } catch { /* noop */ }
              }
            });
          } else if (msgType === 'DM_EVENT') {
            // Rewrite as EVENT for the wire protocol
            const dmMsg = JSON.stringify(['EVENT', msg[1]]);
            // Send to DM relays first, then all others
            const dmSet = new Set(dmRelays);
            // Send to DM priority relays
            upstreams.forEach((info, url) => {
              if (dmSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(dmMsg); } catch { /* noop */ }
              }
            });
            // Then all others
            upstreams.forEach((info, url) => {
              if (!dmSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(dmMsg); } catch { /* noop */ }
              }
            });
          } else if (msgType === 'REQ') {
            // Store subscription for replay to late-connecting relays
            const subId = msg[1];
            activeSubscriptions.set(subId, event.data);

            // Track EOSE for currently-connected read relays only
            const expectedRelays = new Set();
            upstreams.forEach((info, url) => {
              if (info.type !== 'write' && info.status === 'connected') {
                expectedRelays.add(url);
              }
            });
            if (expectedRelays.size > 0) {
              const tracker = { expected: expectedRelays, received: new Set(), sent: false, timer: null };
              tracker.timer = setTimeout(() => {
                if (!tracker.sent) {
                  tracker.sent = true;
                  sendToClient(JSON.stringify(['EOSE', subId]));
                  eoseTracker.delete(subId);
                }
              }, 3000);
              eoseTracker.set(subId, tracker);
            } else {
              // No relays connected yet — send EOSE after timeout
              const tracker = { expected: new Set(), received: new Set(), sent: false, timer: null };
              tracker.timer = setTimeout(() => {
                if (!tracker.sent) {
                  tracker.sent = true;
                  sendToClient(JSON.stringify(['EOSE', subId]));
                  eoseTracker.delete(subId);
                }
              }, 3000);
              eoseTracker.set(subId, tracker);
            }
            // Fan out to currently connected read relays
            sendToUpstreams(event.data, (url, info) => info.type !== 'write');
          } else if (msgType === 'CLOSE') {
            const subId = msg[1];
            activeSubscriptions.delete(subId);
            eoseTracker.delete(subId);
            sendToUpstreams(event.data, (url, info) => info.type !== 'write');
          }
        } catch {
          // Parse error
        }
      })()
    );
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
