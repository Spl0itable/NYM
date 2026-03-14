// Cloudflare Pages Function: Multiplexed WebSocket relay pool proxy
// Single WebSocket from client, fans out to many upstream Nostr relays.
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
  const upstreams = new Map();       // relayUrl -> { ws, type, status, msgCount, handled }
  const activeSubscriptions = new Map(); // subId -> raw JSON string of the REQ message
  let writeOnlyRelays = new Set();
  let dmRelays = [];
  let serverOpen = true;

  // Keepalive to send periodic ping to prevent Cloudflare idle timeout
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

  // Connection staggering for large relay sets
  let connectionQueue = [];
  let connectionTimer = null;
  const CONNECTION_STAGGER_MS = 200;
  const MAX_CONCURRENT = 6;

  // Track relays pending reconnection
  const pendingReconnect = new Set();
  const reconnectTimers = new Map();
  const intentionallyClosed = new Set();

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
    const failed = [];
    const events = {};
    const relayTypes = {};
    upstreams.forEach((info, url) => {
      if (info.status === 'connected') connected.push(url);
      else if (info.status === 'failed') failed.push(url);
      relayTypes[url] = info.type;
      events[url] = info.msgCount;
    });
    sendToClient(JSON.stringify(['POOL:STATUS', {
      connected,
      failed,
      count: connected.length,
      events,
      relayTypes,
      skippedFailed: failedRelays.size
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

  // Stagger relay connections to avoid overwhelming the worker
  function queueConnection(relayUrl, type) {
    if (upstreams.has(relayUrl)) return;
    if (connectionQueue.some(item => item.url === relayUrl)) return;
    connectionQueue.push({ url: relayUrl, type });
    drainConnectionQueue();
  }

  function drainConnectionQueue() {
    if (connectionTimer) return;
    if (connectionQueue.length === 0) return;

    let connecting = 0;
    upstreams.forEach(info => { if (info.status === 'connecting') connecting++; });
    if (connecting >= MAX_CONCURRENT) {
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

    const info = { ws: null, type, status: 'connecting', msgCount: 0, handled: false };
    upstreams.set(relayUrl, info);

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
        replaySubscriptions(relayUrl, ws);
        schedulePoolStatus();
      });

      // Thin passthrough forward raw upstream messages to client
      ws.addEventListener('message', (event) => {
        info.msgCount++;
        sendToClient(event.data);
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
            connectionQueue = [];
            pendingReconnect.clear();
            if (connectionTimer) { clearTimeout(connectionTimer); connectionTimer = null; }

            // Connect new relays with staggering
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
            const geoSet = new Set(msg[2] || []);
            upstreams.forEach((info, url) => {
              if (geoSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
                try { info.ws.send(geoMsg); } catch { /* noop */ }
              }
            });
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
            // Fan out to read relays — EOSE handling moved to client
            sendToUpstreams(event.data, (url, info) => info.type !== 'write');
          } else if (msgType === 'CLOSE') {
            const subId = msg[1];
            activeSubscriptions.delete(subId);
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
