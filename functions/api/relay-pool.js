// Cloudflare Pages Function: Multiplexed WebSocket relay pool proxy
// Single WebSocket from client, fans out to many upstream Nostr relays.
// Deduplicates events server-side before forwarding to client.
//
// Client connects to: wss://<host>/api/relay-pool
//
// Protocol (client → proxy):
//   ["RELAYS", { relays: ["wss://relay1.com", ...], writeOnly: ["wss://sendit.nosflare.com"], dmRelays: ["wss://relay.damus.io", ...] }]
//   ["EVENT", eventObj]          - fans out to all connected relays
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

  // Debounce pool status updates to avoid flooding client during startup
  let statusTimer = null;
  function schedulePoolStatus() {
    if (statusTimer) return;
    statusTimer = setTimeout(() => {
      statusTimer = null;
      sendPoolStatus();
    }, 500);
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
    upstreams.forEach((info, url) => {
      if (info.status === 'connected') connected.push(url);
      else if (info.status === 'failed') failed.push(url);
    });
    relayLatency.forEach((ms, url) => { latency[url] = ms; });
    relayEvents.forEach((count, url) => { events[url] = count; });
    sendToClient(JSON.stringify(['POOL:STATUS', {
      connected,
      failed,
      count: connected.length,
      latency,
      events
    }]));
  }

  function validateRelayUrl(url) {
    try {
      const parsed = new URL(url);
      return parsed.protocol === 'wss:' || parsed.protocol === 'ws:';
    } catch {
      return false;
    }
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

    const info = { ws: null, type, status: 'connecting' };
    upstreams.set(relayUrl, info);

    const connectStartTime = Date.now();

    try {
      const ws = new WebSocket(relayUrl);
      info.ws = ws;

      // Connection timeout
      const timeout = setTimeout(() => {
        if (info.status === 'connecting') {
          info.status = 'failed';
          try { ws.close(); } catch { /* noop */ }
          schedulePoolStatus();
        }
      }, 5000);

      ws.addEventListener('open', () => {
        clearTimeout(timeout);
        info.status = 'connected';
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
        info.status = 'closed';
        schedulePoolStatus();
        // Attempt reconnection after 5 seconds
        setTimeout(() => {
          if (serverOpen) {
            upstreams.delete(relayUrl);
            connectUpstream(relayUrl, type);
          }
        }, 5000);
      });

      ws.addEventListener('error', () => {
        clearTimeout(timeout);
        info.status = 'failed';
        schedulePoolStatus();
      });
    } catch {
      info.status = 'failed';
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
                try { if (info.ws) info.ws.close(); } catch { /* noop */ }
                upstreams.delete(url);
              }
            }

            // Connect new relays
            for (const url of relays) {
              if (!upstreams.has(url)) {
                connectUpstream(url, writeOnlyRelays.has(url) ? 'write' : 'read');
              }
            }
            for (const url of writeOnly) {
              if (!upstreams.has(url)) {
                connectUpstream(url, 'write');
              }
            }
          } else if (msgType === 'EVENT') {
            // Fan out EVENT to all connected relays
            sendToUpstreams(event.data);
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
  server.addEventListener('close', () => {
    serverOpen = false;
    upstreams.forEach((info) => {
      try { if (info.ws) info.ws.close(); } catch { /* noop */ }
    });
    upstreams.clear();
  });

  server.addEventListener('error', () => {
    serverOpen = false;
    upstreams.forEach((info) => {
      try { if (info.ws) info.ws.close(); } catch { /* noop */ }
    });
    upstreams.clear();
  });

  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}
