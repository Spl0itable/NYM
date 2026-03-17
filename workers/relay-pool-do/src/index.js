// Durable Object-based relay pool for NYM
//
// Multiple clients share the same relay connections. Subscriptions are
// namespaced per-client so relay responses route to the correct client.
//
// Protocol (client → DO): identical to relay-pool.js
//   ["RELAYS", { relays, writeOnly, dmRelays }]
//   ["EVENT", eventObj]
//   ["GEO_EVENT", eventObj, ["wss://geo1", ...]]
//   ["DM_EVENT", eventObj]
//   ["REQ", subId, ...filters]
//   ["GEO_REQ", ["wss://geo1",...], subId, ...filters]
//   ["CLOSE", subId]
//
// Protocol (DO → client): identical to relay-pool.js
//   ["EVENT", subId, eventObj]
//   ["OK", eventId, bool, msg]
//   ["EOSE", subId]
//   ["NOTICE", msg]
//   ["POOL:PING", timestamp]
//   ["POOL:STATUS", { connected, count, latency, events }]

// Worker entry point
export default {
  async fetch(request, env) {
    // Handle CORS preflight for cross-origin WebSocket upgrades
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Headers': 'Upgrade, Sec-WebSocket-Key, Sec-WebSocket-Version, Sec-WebSocket-Protocol',
          'Access-Control-Allow-Methods': 'GET',
        },
      });
    }

    const upgradeHeader = request.headers.get('Upgrade');
    if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
      return new Response('NYM Relay Pool DO — connect via WebSocket', { status: 200 });
    }

    // Single global DO instance — all clients share it
    const id = env.RELAY_POOL.idFromName('global');
    const stub = env.RELAY_POOL.get(id);
    return stub.fetch(request);
  },
};

// Durable Object
export class RelayPoolDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;

    // Client tracking: clientId → ClientInfo
    this.clients = new Map();
    this.clientCounter = 0;

    // Shared relay connections: relayUrl → UpstreamInfo
    this.upstreams = new Map();

    // Subscription routing: namespacedSubId → { clientId, originalSubId }
    this.subToClient = new Map();

    // OK routing: eventId → clientId (who published it)
    this.eventSender = new Map();

    this.seenOKs = new Set();

    // Relay health tracking
    this.failedRelays = new Map();
    this.reconnectAttempts = new Map();
    this.reconnectTimers = new Map();
    this.pendingReconnect = new Set();
    this.relayLatency = new Map();
    this.pendingGeoEvents = new Map();

    // Dedup housekeeping
    this.dedupCounter = 0;

    // Grace period: keep relays alive after last client disconnects
    this.graceTimer = null;

    // Keepalive timer
    this.keepaliveTimer = null;

    // Status timer
    this.statusTimer = null;
  }

  async fetch(request) {
    const upgradeHeader = request.headers.get('Upgrade');
    if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
      return new Response('Expected WebSocket upgrade', { status: 426 });
    }

    const { 0: client, 1: server } = new WebSocketPair();
    server.accept();

    const clientId = `c${++this.clientCounter}`;
    const prefix = clientId + ':';

    const clientInfo = {
      ws: server,
      prefix,
      writeOnly: new Set(),
      dmRelays: [],
      subs: new Map(),          // originalSubId → namespacedSubId
      requestedRelays: new Set(),
      seenEvents: new Set(),    // per-client event dedup
    };
    this.clients.set(clientId, clientInfo);

    // Cancel grace timer — a client is here
    if (this.graceTimer) {
      clearTimeout(this.graceTimer);
      this.graceTimer = null;
    }

    // Start keepalive if not running
    this._ensureKeepalive();

    // Send immediate pool status so client knows which relays are already warm
    this._sendPoolStatusTo(clientId);

    // Wire up client message handler
    server.addEventListener('message', (event) => {
      this._handleClientMessage(clientId, event.data);
    });

    server.addEventListener('close', () => {
      this._handleClientClose(clientId);
    });

    server.addEventListener('error', () => {
      this._handleClientClose(clientId);
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  // Client message handling
  _handleClientMessage(clientId, rawData) {
    const client = this.clients.get(clientId);
    if (!client) return;

    let msg;
    try {
      msg = JSON.parse(rawData);
      if (!Array.isArray(msg)) return;
    } catch {
      return;
    }

    const msgType = msg[0];

    if (msgType === 'RELAYS') {
      this._handleRelays(clientId, msg[1]);
    } else if (msgType === 'EVENT') {
      this._handleEvent(clientId, msg[1]);
    } else if (msgType === 'GEO_EVENT') {
      this._handleGeoEvent(clientId, msg[1], msg[2] || []);
    } else if (msgType === 'DM_EVENT') {
      this._handleDmEvent(clientId, msg[1]);
    } else if (msgType === 'REQ') {
      this._handleReq(clientId, msg);
    } else if (msgType === 'GEO_REQ') {
      this._handleGeoReq(clientId, msg);
    } else if (msgType === 'CLOSE') {
      this._handleClose(clientId, msg[1]);
    }
  }

  _handleRelays(clientId, config) {
    if (!config || typeof config !== 'object') return;
    const client = this.clients.get(clientId);
    if (!client) return;

    const writeOnly = config.writeOnly || [];
    client.dmRelays = config.dmRelays || [];
    client.writeOnly = new Set(writeOnly);

    const requestedRelays = config.relays || [];
    const newRelaySet = new Set([...requestedRelays, ...writeOnly]);

    // Track which relays this client wants
    const oldRelays = client.requestedRelays;
    client.requestedRelays = newRelaySet;

    // Decrement refcount for relays this client no longer needs
    for (const url of oldRelays) {
      if (!newRelaySet.has(url)) {
        this._decrementRelayRef(url, clientId);
      }
    }

    // Connect new relays (or increment refcount for existing ones)
    for (const url of requestedRelays) {
      this._ensureRelayConnected(url, client.writeOnly.has(url) ? 'write' : 'read', clientId);
    }
    for (const url of writeOnly) {
      this._ensureRelayConnected(url, 'write', clientId);
    }

    this._schedulePoolStatus();
  }

  _handleEvent(clientId, eventObj) {
    const eventMsg = JSON.stringify(['EVENT', eventObj]);
    // Track sender for OK routing
    if (eventObj && eventObj.id) {
      this.eventSender.set(eventObj.id, clientId);
      this._trimEventSender();
    }
    this._sendToUpstreams(eventMsg);
  }

  _handleGeoEvent(clientId, eventObj, geoUrls) {
    const geoMsg = JSON.stringify(['EVENT', eventObj]);
    if (eventObj && eventObj.id) {
      this.eventSender.set(eventObj.id, clientId);
    }

    const geoSet = new Set(geoUrls);
    const sentGeo = new Set();

    // Send to connected geo relays first
    this.upstreams.forEach((info, url) => {
      if (geoSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        try { info.ws.send(geoMsg); sentGeo.add(url); } catch { /* noop */ }
      }
    });

    // Buffer for geo relays still connecting
    for (const url of geoUrls) {
      if (sentGeo.has(url)) continue;
      const info = this.upstreams.get(url);
      if (info && info.status === 'connecting') {
        if (!this.pendingGeoEvents.has(url)) this.pendingGeoEvents.set(url, []);
        this.pendingGeoEvents.get(url).push(geoMsg);
      } else if (!info && this._validateRelayUrl(url)) {
        this._connectUpstream(url, 'read');
        if (!this.pendingGeoEvents.has(url)) this.pendingGeoEvents.set(url, []);
        this.pendingGeoEvents.get(url).push(geoMsg);
      }
    }

    // Then all other relays
    this.upstreams.forEach((info, url) => {
      if (!geoSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        try { info.ws.send(geoMsg); } catch { /* noop */ }
      }
    });
  }

  _handleDmEvent(clientId, eventObj) {
    const dmMsg = JSON.stringify(['EVENT', eventObj]);
    if (eventObj && eventObj.id) {
      this.eventSender.set(eventObj.id, clientId);
    }

    const client = this.clients.get(clientId);
    const dmSet = new Set(client ? client.dmRelays : []);

    // DM relays first
    this.upstreams.forEach((info, url) => {
      if (dmSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        try { info.ws.send(dmMsg); } catch { /* noop */ }
      }
    });
    // Then the rest
    this.upstreams.forEach((info, url) => {
      if (!dmSet.has(url) && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        try { info.ws.send(dmMsg); } catch { /* noop */ }
      }
    });
  }

  _handleReq(clientId, msg) {
    const client = this.clients.get(clientId);
    if (!client) return;

    const originalSubId = msg[1];
    const namespacedSubId = client.prefix + originalSubId;

    // Track subscription mapping
    client.subs.set(originalSubId, namespacedSubId);
    this.subToClient.set(namespacedSubId, { clientId, originalSubId });

    // Build namespaced REQ and cache for replay
    const namespacedReq = JSON.stringify(['REQ', namespacedSubId, ...msg.slice(2)]);
    this._cacheReq(namespacedSubId, namespacedReq);

    // Send to all read relays
    this.upstreams.forEach((info, url) => {
      if (info.type !== 'write' && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        try { info.ws.send(namespacedReq); } catch { /* noop */ }
      }
    });
  }

  _handleGeoReq(clientId, msg) {
    const client = this.clients.get(clientId);
    if (!client) return;

    // ["GEO_REQ", ["wss://geo1", ...], subId, ...filters]
    const geoList = msg[1] || [];
    const originalSubId = msg[2];
    const namespacedSubId = client.prefix + originalSubId;

    client.subs.set(originalSubId, namespacedSubId);
    this.subToClient.set(namespacedSubId, { clientId, originalSubId });

    const namespacedReq = JSON.stringify(['REQ', namespacedSubId, ...msg.slice(3)]);
    this._cacheReq(namespacedSubId, namespacedReq);
    const geoSet = new Set(geoList);

    // Ensure geo relays are connected
    for (const url of geoList) {
      if (!this.upstreams.has(url) && this._validateRelayUrl(url)) {
        this._connectUpstream(url, 'read');
      }
    }

    // Geo relays first
    this.upstreams.forEach((info, url) => {
      if (geoSet.has(url) && info.type !== 'write' && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        try { info.ws.send(namespacedReq); } catch { /* noop */ }
      }
    });
    // Then all others
    this.upstreams.forEach((info, url) => {
      if (!geoSet.has(url) && info.type !== 'write' && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        try { info.ws.send(namespacedReq); } catch { /* noop */ }
      }
    });
  }

  _handleClose(clientId, originalSubId) {
    const client = this.clients.get(clientId);
    if (!client) return;

    const namespacedSubId = client.subs.get(originalSubId);
    if (!namespacedSubId) return;

    client.subs.delete(originalSubId);
    this.subToClient.delete(namespacedSubId);
    if (this._reqCache) this._reqCache.delete(namespacedSubId);

    const closeMsg = JSON.stringify(['CLOSE', namespacedSubId]);
    this.upstreams.forEach((info) => {
      if (info.type !== 'write' && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        try { info.ws.send(closeMsg); } catch { /* noop */ }
      }
    });
  }

  // Client disconnect
  _handleClientClose(clientId) {
    const client = this.clients.get(clientId);
    if (!client) return;

    // Clean up all subscriptions for this client
    for (const [originalSubId, namespacedSubId] of client.subs) {
      this.subToClient.delete(namespacedSubId);
      if (this._reqCache) this._reqCache.delete(namespacedSubId);
      // Send CLOSE to relays
      const closeMsg = JSON.stringify(['CLOSE', namespacedSubId]);
      this.upstreams.forEach((info) => {
        if (info.type !== 'write' && info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
          try { info.ws.send(closeMsg); } catch { /* noop */ }
        }
      });
    }

    // Decrement relay refcounts
    for (const url of client.requestedRelays) {
      this._decrementRelayRef(url, clientId);
    }

    this.clients.delete(clientId);

    // If no clients left, start grace period (keep relays alive for 2 min)
    if (this.clients.size === 0) {
      this.graceTimer = setTimeout(() => {
        this.graceTimer = null;
        if (this.clients.size === 0) {
          this._closeAllRelays();
        }
      }, 120000);
    }

    this._schedulePoolStatus();
  }

  // Relay connection management
  _ensureRelayConnected(relayUrl, type, clientId) {
    const existing = this.upstreams.get(relayUrl);
    if (existing) {
      // Already connected or connecting — just add this client as a ref
      if (!existing.clientRefs) existing.clientRefs = new Set();
      existing.clientRefs.add(clientId);
      return;
    }
    this._connectUpstream(relayUrl, type, clientId);
  }

  _decrementRelayRef(relayUrl, clientId) {
    const info = this.upstreams.get(relayUrl);
    if (!info || !info.clientRefs) return;
    info.clientRefs.delete(clientId);
    // Don't disconnect immediately — other clients may still need it,
    // and the grace timer handles cleanup when all clients are gone
  }

  _connectUpstream(relayUrl, type, clientId) {
    if (this.upstreams.has(relayUrl)) return;
    if (!this._validateRelayUrl(relayUrl)) return;
    if (relayUrl === 'wss://relay.nosflare.com') return;
    if (this._shouldSkipRelay(relayUrl)) return;

    const clientRefs = new Set();
    if (clientId) clientRefs.add(clientId);

    const info = { ws: null, type, status: 'connecting', eventCount: 0, handled: false, clientRefs };
    this.upstreams.set(relayUrl, info);

    const connectStartTime = Date.now();

    try {
      const ws = new WebSocket(relayUrl);
      info.ws = ws;

      const timeout = setTimeout(() => {
        if (info.status === 'connecting') {
          info.handled = true;
          info.status = 'failed';
          this._trackRelayFailure(relayUrl);
          try { ws.close(); } catch { /* noop */ }
          this.upstreams.delete(relayUrl);
          this._schedulePoolStatus();
        }
      }, 8000);

      ws.addEventListener('open', () => {
        clearTimeout(timeout);
        info.status = 'connected';
        this._clearRelayFailure(relayUrl);
        this.reconnectAttempts.delete(relayUrl);
        this.relayLatency.set(relayUrl, Date.now() - connectStartTime);

        // Replay subscriptions for all clients that need this relay
        this._replaySubscriptionsForRelay(relayUrl, ws);

        // Flush buffered GEO_EVENTs
        const buffered = this.pendingGeoEvents.get(relayUrl);
        if (buffered && buffered.length > 0) {
          for (const geoMsg of buffered) {
            try { ws.send(geoMsg); } catch { /* noop */ }
          }
          this.pendingGeoEvents.delete(relayUrl);
        }

        this._schedulePoolStatus();
      });

      ws.addEventListener('message', (event) => {
        this._handleRelayMessage(relayUrl, event.data, info);
      });

      ws.addEventListener('close', () => {
        clearTimeout(timeout);
        if (info.handled) return;
        info.handled = true;

        const wasConnected = info.status === 'connected';
        info.status = 'closed';
        this.upstreams.delete(relayUrl);
        this._schedulePoolStatus();

        // Only reconnect if there are clients that need this relay
        if (wasConnected && this._anyClientNeedsRelay(relayUrl)) {
          this._scheduleReconnect(relayUrl, type);
        } else if (!wasConnected) {
          this._trackRelayFailure(relayUrl);
        }
      });

      ws.addEventListener('error', () => {
        clearTimeout(timeout);
        if (info.handled) return;
        info.handled = true;
        info.status = 'failed';
        this._trackRelayFailure(relayUrl);
        this.upstreams.delete(relayUrl);
        this._schedulePoolStatus();
      });
    } catch {
      info.handled = true;
      info.status = 'failed';
      this._trackRelayFailure(relayUrl);
      this.upstreams.delete(relayUrl);
      this._schedulePoolStatus();
    }
  }

  _anyClientNeedsRelay(relayUrl) {
    for (const [, client] of this.clients) {
      if (client.requestedRelays.has(relayUrl)) return true;
    }
    return false;
  }

  _replaySubscriptionsForRelay(relayUrl, ws) {
    // For each client that has this relay in their set, replay their subs
    for (const [clientId, client] of this.clients) {
      if (!client.requestedRelays.has(relayUrl)) continue;
      if (client.writeOnly.has(relayUrl)) continue;

      for (const [originalSubId, namespacedSubId] of client.subs) {
        // We need the original REQ filters — reconstruct from subToClient
        // We don't store the full REQ, but we can find it in subToClient
        // Actually we need to store the full REQ. Let me use a reqCache.
        const cached = this._reqCache && this._reqCache.get(namespacedSubId);
        if (cached) {
          try { ws.send(cached); } catch { /* noop */ }
        }
      }
    }
  }

  // Relay message handling
  _handleRelayMessage(relayUrl, raw, info) {
    if (typeof raw !== 'string' || raw.length < 10) return;

    // EVENT: ["EVENT","namespacedSubId",{...}]
    if (raw.startsWith('["EVENT"')) {
      this._handleRelayEvent(relayUrl, raw, info);

    // OK: ["OK","eventId",...]
    } else if (raw.startsWith('["OK"')) {
      this._handleRelayOK(raw);

    // EOSE: ["EOSE","namespacedSubId"]
    } else if (raw.startsWith('["EOSE"')) {
      this._handleRelayEOSE(raw);

    // NOTICE or anything else — broadcast to all clients
    } else {
      this._broadcastToClients(raw);
    }
  }

  _handleRelayEvent(relayUrl, raw, info) {
    info.eventCount++;

    // Extract the namespaced subId to route to correct client
    const subId = this._extractSubId(raw);
    if (!subId) return;

    const mapping = this.subToClient.get(subId);
    if (!mapping) return; // Unknown sub — ignore

    const { clientId, originalSubId } = mapping;
    const client = this.clients.get(clientId);
    if (!client) return;

    // Global event dedup (by event ID)
    const eventId = this._extractEventId(raw);
    if (eventId) {
      if (client.seenEvents.has(eventId)) return;
      client.seenEvents.add(eventId);
      this._trimClientDedup(client);
    }

    // Rewrite the sub ID: replace namespaced with original
    const rewritten = this._rewriteSubId(raw, subId, originalSubId);
    this._sendToClient(clientId, rewritten);
  }

  _handleRelayOK(raw) {
    // Extract event ID from OK
    const eventId = this._extractOKEventId(raw);
    if (!eventId) return;

    // Dedup OKs globally
    if (this.seenOKs.has(eventId)) return;
    this.seenOKs.add(eventId);

    // Route to the client that sent this event
    const clientId = this.eventSender.get(eventId);
    if (clientId) {
      this._sendToClient(clientId, raw);
      this.eventSender.delete(eventId);
    }

    this._trimOKDedup();
  }

  _handleRelayEOSE(raw) {
    const subId = this._extractEOSESubId(raw);
    if (!subId) return;

    const mapping = this.subToClient.get(subId);
    if (!mapping) return;

    const { clientId, originalSubId } = mapping;
    // Rewrite EOSE with original sub ID
    const rewritten = JSON.stringify(['EOSE', originalSubId]);
    this._sendToClient(clientId, rewritten);
  }

  // Extract sub ID from EVENT: ["EVENT","subId",{...}]
  // The sub ID is the second quoted string
  _extractSubId(raw) {
    // Find second quoted string: after ["EVENT","
    const firstComma = raw.indexOf(',');
    if (firstComma === -1) return null;
    const openQuote = raw.indexOf('"', firstComma);
    if (openQuote === -1) return null;
    const closeQuote = raw.indexOf('"', openQuote + 1);
    if (closeQuote === -1) return null;
    return raw.substring(openQuote + 1, closeQuote);
  }

  // Extract sub ID from EOSE: ["EOSE","subId"]
  _extractEOSESubId(raw) {
    // ["EOSE"," — subId starts after the comma and quote
    const start = raw.indexOf(',"');
    if (start === -1) return null;
    const openQuote = start + 2;
    const closeQuote = raw.indexOf('"', openQuote);
    if (closeQuote === -1) return null;
    return raw.substring(openQuote, closeQuote);
  }

  // Extract event ID from EVENT payload without JSON.parse
  _extractEventId(raw) {
    const braceIdx = raw.indexOf('{');
    if (braceIdx === -1) return null;
    const idx = raw.indexOf('"id":"', braceIdx);
    if (idx === -1) return null;
    const start = idx + 6;
    const end = raw.indexOf('"', start);
    if (end === -1 || end - start !== 64) return null;
    return raw.substring(start, end);
  }

  // Extract event ID from OK: ["OK","eventId",...]
  _extractOKEventId(raw) {
    const start = 6; // ["OK","
    const end = raw.indexOf('"', start);
    if (end === -1 || end - start < 16) return null;
    return raw.substring(start, end);
  }

  // Rewrite sub ID in a raw EVENT message
  // Replace the namespaced sub ID with the original one
  _rewriteSubId(raw, namespacedSubId, originalSubId) {
    // Find the namespaced sub ID in the raw string and replace it
    // It appears as: ["EVENT","c1:originalSubId",{...}]
    // We need to replace "c1:originalSubId" with "originalSubId"
    const searchStr = '"' + namespacedSubId + '"';
    const replaceStr = '"' + originalSubId + '"';
    // Only replace the first occurrence (the sub ID field)
    const idx = raw.indexOf(searchStr);
    if (idx === -1) return raw;
    return raw.substring(0, idx) + replaceStr + raw.substring(idx + searchStr.length);
  }

  // Client communication
  _sendToClient(clientId, data) {
    const client = this.clients.get(clientId);
    if (!client) return;
    try {
      if (client.ws.readyState === 1) {
        client.ws.send(typeof data === 'string' ? data : JSON.stringify(data));
      }
    } catch {
      // Client disconnected
    }
  }

  _broadcastToClients(data) {
    const msg = typeof data === 'string' ? data : JSON.stringify(data);
    for (const [clientId, client] of this.clients) {
      try {
        if (client.ws.readyState === 1) {
          client.ws.send(msg);
        }
      } catch { /* noop */ }
    }
  }

  _sendToUpstreams(data, filter) {
    const msg = typeof data === 'string' ? data : JSON.stringify(data);
    this.upstreams.forEach((info, url) => {
      if (info.status === 'connected' && info.ws && info.ws.readyState === WebSocket.OPEN) {
        if (!filter || filter(url, info)) {
          try { info.ws.send(msg); } catch { /* noop */ }
        }
      }
    });
  }

  // Pool status & keepalive 
  _ensureKeepalive() {
    if (this.keepaliveTimer) return;
    this.keepaliveTimer = setInterval(() => {
      if (this.clients.size === 0) {
        clearInterval(this.keepaliveTimer);
        this.keepaliveTimer = null;
        return;
      }
      const ping = JSON.stringify(['POOL:PING', Date.now()]);
      this._broadcastToClients(ping);
    }, 30000);
  }

  _schedulePoolStatus() {
    if (this.statusTimer) return;
    this.statusTimer = setTimeout(() => {
      this.statusTimer = null;
      this._broadcastPoolStatus();
    }, 300);
  }

  _broadcastPoolStatus() {
    for (const [clientId] of this.clients) {
      this._sendPoolStatusTo(clientId);
    }
  }

  _sendPoolStatusTo(clientId) {
    const connected = [];
    const latency = {};
    const events = {};
    this.upstreams.forEach((info, url) => {
      if (info.status === 'connected') {
        connected.push(url);
        events[url] = info.eventCount;
      }
    });
    this.relayLatency.forEach((ms, url) => {
      if (connected.includes(url)) latency[url] = ms;
    });
    this._sendToClient(clientId, JSON.stringify(['POOL:STATUS', {
      connected,
      count: connected.length,
      latency,
      events
    }]));
  }

  // Relay health
  _shouldSkipRelay(relayUrl) {
    const failure = this.failedRelays.get(relayUrl);
    if (failure) {
      const backoff = Math.min(60000 * Math.pow(2, failure.attempts - 1), 180000);
      if (Date.now() - failure.failedAt < backoff) return true;
      this.failedRelays.delete(relayUrl);
    }
    return false;
  }

  _trackRelayFailure(relayUrl) {
    const existing = this.failedRelays.get(relayUrl);
    const attempts = existing ? existing.attempts + 1 : 1;
    this.failedRelays.set(relayUrl, { failedAt: Date.now(), attempts });
  }

  _clearRelayFailure(relayUrl) {
    this.failedRelays.delete(relayUrl);
  }

  _scheduleReconnect(relayUrl, type) {
    if (this.clients.size === 0) return;
    if (this.pendingReconnect.has(relayUrl)) return;

    const attempts = this.reconnectAttempts.get(relayUrl) || 0;
    if (attempts >= 5) {
      this._trackRelayFailure(relayUrl);
      this.reconnectAttempts.delete(relayUrl);
      return;
    }
    this.reconnectAttempts.set(relayUrl, attempts + 1);
    this.pendingReconnect.add(relayUrl);

    const delay = 3000 * Math.pow(1.5, attempts) + Math.random() * 2000;
    const timerId = setTimeout(() => {
      this.reconnectTimers.delete(relayUrl);
      this.pendingReconnect.delete(relayUrl);
      if (this.clients.size > 0 && !this.upstreams.has(relayUrl) && this._anyClientNeedsRelay(relayUrl)) {
        this._connectUpstream(relayUrl, type);
      }
    }, delay);
    this.reconnectTimers.set(relayUrl, timerId);
  }

  _validateRelayUrl(url) {
    try {
      const parsed = new URL(url);
      return parsed.protocol === 'wss:' || parsed.protocol === 'ws:';
    } catch {
      return false;
    }
  }

  // Cleanup
  _closeAllRelays() {
    for (const [, timerId] of this.reconnectTimers) clearTimeout(timerId);
    this.reconnectTimers.clear();
    this.pendingReconnect.clear();

    if (this.keepaliveTimer) { clearInterval(this.keepaliveTimer); this.keepaliveTimer = null; }
    if (this.statusTimer) { clearTimeout(this.statusTimer); this.statusTimer = null; }

    this.upstreams.forEach((info) => {
      try { if (info.ws) info.ws.close(); } catch { /* noop */ }
    });
    this.upstreams.clear();

    // Clear dedup state
    this.seenOKs.clear();
    this.eventSender.clear();
    this.subToClient.clear();
    this.pendingGeoEvents.clear();
  }

  // Dedup housekeeping
  _trimClientDedup(client) {
    if (client.seenEvents.size > 5000) {
      let deleted = 0;
      const toDelete = client.seenEvents.size - 5000;
      for (const key of client.seenEvents) {
        if (deleted >= toDelete) break;
        client.seenEvents.delete(key);
        deleted++;
      }
    }
  }

  _trimOKDedup() {
    if (this.seenOKs.size > 1000) {
      let deleted = 0;
      for (const key of this.seenOKs) {
        if (deleted >= 500) break;
        this.seenOKs.delete(key);
        deleted++;
      }
    }
  }

  _trimEventSender() {
    if (this.eventSender.size > 500) {
      let deleted = 0;
      for (const key of this.eventSender.keys()) {
        if (deleted >= 200) break;
        this.eventSender.delete(key);
        deleted++;
      }
    }
  }

  // Store REQ messages so we can replay them to newly connected relays
  _cacheReq(namespacedSubId, reqMsg) {
    if (!this._reqCache) this._reqCache = new Map();
    this._reqCache.set(namespacedSubId, reqMsg);
    // Trim cache
    if (this._reqCache.size > 500) {
      let deleted = 0;
      for (const key of this._reqCache.keys()) {
        if (deleted >= 100) break;
        this._reqCache.delete(key);
        deleted++;
      }
    }
  }
}
