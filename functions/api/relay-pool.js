// Cloudflare Pages Function: Relay pool router
// One client WebSocket; this Worker fans out to a small number of shard
// Workers (/api/relay-pool-shard), each holding its own ~250 upstream
// relay sockets. Each shard runs as an independent Worker invocation
// with its own 6-simultaneous-outgoing-connection budget, so the total
// capacity scales with shard count × 6 in-flight opens per shard.
//
// SHARD_SIZE is chosen so the router never needs more than 6 shard
// connections itself — Cloudflare caps outgoing connections at 6 per
// Worker request, and the router is a Worker request too.
//
// Client protocol (unchanged):
//   ["RELAYS", { relays, writeOnly, dmRelays }]
//   ["EVENT", evt] / ["GEO_EVENT", evt, [urls]] / ["DM_EVENT", evt]
//   ["REQ", subId, ...filters] / ["GEO_REQ", [urls], subId, ...filters]
//   ["CLOSE", subId]
// Router → client:
//   ["EVENT", subId, evt] / ["OK", id, ok, msg] / ["EOSE", subId]
//   ["NOTICE", msg] / ["POOL:STATUS", { connected, count, latency, events }]
//   ["POOL:PING", ts]

const SHARD_SIZE = 250;
const MAX_SHARDS = 6;
const SHARD_PATH = '/api/relay-pool-shard';
const SHARD_OPEN_STAGGER_MS = 25;

export async function onRequest(context) {
  const { request } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }

  const shardEndpoint = buildShardEndpoint(request.url);

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  let serverOpen = true;
  const shards = []; // { id, ws, relays, dmRelays, writeOnly, status, connectedRelays, latency, events, _closing, _reconnectAttempts }
  const activeSubscriptions = new Map(); // subId -> raw REQ JSON

  // Cross-shard dedup
  const seenEvents = new Map();
  const seenOKs = new Set();
  const seenEOSE = new Set();
  const DEDUP_MAX = 50000;
  let dedupCounter = 0;
  function trimDedup() {
    if (++dedupCounter < 500) return;
    dedupCounter = 0;
    if (seenEvents.size > DEDUP_MAX) {
      const toDelete = seenEvents.size - DEDUP_MAX;
      let n = 0;
      for (const k of seenEvents.keys()) { if (n >= toDelete) break; seenEvents.delete(k); n++; }
    }
    if (seenOKs.size > 2000) {
      let n = 0;
      for (const k of seenOKs) { if (n >= 1000) break; seenOKs.delete(k); n++; }
    }
    if (seenEOSE.size > 500) {
      let n = 0;
      for (const k of seenEOSE) { if (n >= 250) break; seenEOSE.delete(k); n++; }
    }
  }

  function extractEventId(raw) {
    const braceIdx = raw.indexOf('{');
    if (braceIdx === -1) return null;
    const idx = raw.indexOf('"id":"', braceIdx);
    if (idx === -1) return null;
    const start = idx + 6;
    const end = raw.indexOf('"', start);
    if (end === -1 || end - start !== 64) return null;
    return raw.substring(start, end);
  }
  function extractOKEventId(raw) {
    const start = 6;
    const end = raw.indexOf('"', start);
    if (end === -1 || end - start < 16) return null;
    return raw.substring(start, end);
  }

  function sendToClient(data) {
    if (!serverOpen) return;
    try {
      if (server.readyState === 1) {
        server.send(typeof data === 'string' ? data : JSON.stringify(data));
      }
    } catch { /* noop */ }
  }

  // Aggregate POOL:STATUS across shards and emit to client
  let statusTimer = null;
  function scheduleStatus() {
    if (statusTimer) return;
    statusTimer = setTimeout(() => {
      statusTimer = null;
      const seen = new Set();
      const connected = [];
      const latency = {};
      const events = {};
      for (const sh of shards) {
        if (!sh.connectedRelays) continue;
        for (const url of sh.connectedRelays) {
          if (!seen.has(url)) {
            seen.add(url);
            connected.push(url);
          }
        }
        if (sh.latency) for (const [u, ms] of Object.entries(sh.latency)) latency[u] = ms;
        if (sh.events) for (const [u, c] of Object.entries(sh.events)) events[u] = c;
      }
      sendToClient(JSON.stringify(['POOL:STATUS', {
        connected,
        count: connected.length,
        latency,
        events
      }]));
    }, 300);
  }

  // Keepalive client side
  let keepaliveTimer = setInterval(() => {
    if (!serverOpen) { clearInterval(keepaliveTimer); keepaliveTimer = null; return; }
    try { server.send(JSON.stringify(['POOL:PING', Date.now()])); }
    catch { clearInterval(keepaliveTimer); keepaliveTimer = null; }
  }, 30000);

  // Shard-side keepalive: keep router→shard sockets warm so Cloudflare
  // doesn't idle-kill them when the client is silent
  let shardKeepaliveTimer = setInterval(() => {
    if (!serverOpen) { clearInterval(shardKeepaliveTimer); shardKeepaliveTimer = null; return; }
    const ping = JSON.stringify(['POOL:PING', Date.now()]);
    for (const sh of shards) {
      if (sh.ws && sh.ws.readyState === 1) {
        try { sh.ws.send(ping); } catch { /* noop */ }
      }
    }
  }, 25000);

  function chunkArray(arr, size) {
    const out = [];
    for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
    return out;
  }

  function planShards(config) {
    const relays = Array.isArray(config.relays) ? config.relays.slice() : [];
    const writeOnly = Array.isArray(config.writeOnly) ? config.writeOnly.slice() : [];
    const dmRelays = Array.isArray(config.dmRelays) ? config.dmRelays.slice() : [];

    const combined = [...new Set([...relays, ...writeOnly])];
    // Choose a chunk size that keeps total shards ≤ MAX_SHARDS so the router
    // never tries to hold more than 6 outbound shard WebSockets.
    const chunkSize = Math.max(SHARD_SIZE, Math.ceil(combined.length / MAX_SHARDS));
    const chunks = chunkArray(combined, chunkSize);
    if (chunks.length === 0) chunks.push([]);

    const writeOnlySet = new Set(writeOnly);
    return chunks.map((chunk, i) => ({
      id: `s${i}`,
      relays: chunk.filter(u => !writeOnlySet.has(u)),
      writeOnly: chunk.filter(u => writeOnlySet.has(u)),
      dmRelays: i === 0 ? dmRelays.slice() : []
    }));
  }

  function openShard(plan) {
    const sh = {
      id: plan.id,
      ws: null,
      relays: plan.relays,
      writeOnly: plan.writeOnly,
      dmRelays: plan.dmRelays,
      status: 'connecting',
      connectedRelays: [],
      latency: {},
      events: {},
      _closing: false,
      _reconnectAttempts: 0
    };
    shards.push(sh);
    connectShardWs(sh);
    return sh;
  }

  function connectShardWs(sh) {
    let ws;
    try {
      ws = new WebSocket(shardEndpoint);
    } catch {
      scheduleShardReconnect(sh);
      return;
    }
    sh.ws = ws;

    ws.addEventListener('open', () => {
      sh.status = 'open';
      sh._reconnectAttempts = 0;
      try {
        ws.send(JSON.stringify(['RELAYS', {
          relays: sh.relays,
          writeOnly: sh.writeOnly,
          dmRelays: sh.dmRelays
        }]));
      } catch { /* noop */ }
      for (const [, raw] of activeSubscriptions) {
        try { ws.send(raw); } catch { /* noop */ }
      }
    });

    ws.addEventListener('message', (event) => {
      const raw = event.data;
      if (typeof raw !== 'string' || raw.length < 4) return;

      if (raw.startsWith('["POOL:STATUS"')) {
        try {
          const parsed = JSON.parse(raw);
          const status = parsed[1] || {};
          sh.connectedRelays = Array.isArray(status.connected) ? status.connected : [];
          sh.latency = status.latency || {};
          sh.events = status.events || {};
        } catch { /* noop */ }
        scheduleStatus();
        return;
      }

      if (raw.startsWith('["POOL:PING"')) return;

      if (raw.charCodeAt(2) === 69 && raw.startsWith('["EVENT"')) {
        const eid = extractEventId(raw);
        if (eid) {
          if (seenEvents.has(eid)) return;
          seenEvents.set(eid, 1);
          trimDedup();
        }
        sendToClient(raw);
        return;
      }

      if (raw.charCodeAt(2) === 79 && raw.startsWith('["OK"')) {
        const eid = extractOKEventId(raw);
        if (eid) {
          if (seenOKs.has(eid)) return;
          seenOKs.add(eid);
        }
        sendToClient(raw);
        return;
      }

      if (raw.charCodeAt(2) === 69 && raw.startsWith('["EOSE"')) {
        const m = raw.match(/^\["EOSE","([^"]+)"/);
        if (m) {
          const subId = m[1];
          if (seenEOSE.has(subId)) return;
          seenEOSE.add(subId);
        }
        sendToClient(raw);
        return;
      }

      sendToClient(raw);
    });

    ws.addEventListener('close', () => {
      sh.ws = null;
      sh.status = 'closed';
      sh.connectedRelays = [];
      sh.latency = {};
      sh.events = {};
      scheduleStatus();
      if (!serverOpen || sh._closing) return;
      scheduleShardReconnect(sh);
    });

    ws.addEventListener('error', () => {
      // close handler runs next
    });
  }

  function scheduleShardReconnect(sh) {
    if (!serverOpen || sh._closing) return;
    const attempts = sh._reconnectAttempts || 0;
    sh._reconnectAttempts = attempts + 1;
    const baseDelay = Math.min(1500 * Math.pow(1.7, attempts), 30000);
    const delay = Math.floor(baseDelay * (0.7 + Math.random() * 0.3));
    setTimeout(() => {
      if (!serverOpen || sh._closing) return;
      if (sh.ws && (sh.ws.readyState === 0 || sh.ws.readyState === 1)) return;
      connectShardWs(sh);
    }, delay);
  }

  function broadcastToShards(raw) {
    for (const sh of shards) {
      if (sh.ws && sh.ws.readyState === 1) {
        try { sh.ws.send(raw); } catch { /* noop */ }
      }
    }
  }

  // Client → router messages
  server.addEventListener('message', (event) => {
    const raw = event.data;
    if (typeof raw !== 'string') return;
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (!Array.isArray(msg)) return;
    const t = msg[0];

    if (t === 'RELAYS') {
      const config = msg[1];
      if (!config || typeof config !== 'object') return;

      const plans = planShards(config);
      const planById = new Map(plans.map(p => [p.id, p]));
      const existingById = new Map(shards.map(s => [s.id, s]));

      // Drop shards that no longer exist in the new plan
      for (let i = shards.length - 1; i >= 0; i--) {
        const sh = shards[i];
        if (!planById.has(sh.id)) {
          sh._closing = true;
          try { if (sh.ws) sh.ws.close(); } catch { /* noop */ }
          shards.splice(i, 1);
        }
      }

      // Update existing shards or open new ones (staggered)
      let openIdx = 0;
      for (const plan of plans) {
        const existing = existingById.get(plan.id);
        if (existing) {
          existing.relays = plan.relays;
          existing.writeOnly = plan.writeOnly;
          existing.dmRelays = plan.dmRelays;
          if (existing.ws && existing.ws.readyState === 1) {
            try {
              existing.ws.send(JSON.stringify(['RELAYS', {
                relays: existing.relays,
                writeOnly: existing.writeOnly,
                dmRelays: existing.dmRelays
              }]));
            } catch { /* noop */ }
          }
        } else {
          if (openIdx === 0) {
            openShard(plan);
          } else {
            const p = plan;
            const delay = openIdx * SHARD_OPEN_STAGGER_MS;
            setTimeout(() => {
              if (!serverOpen) return;
              if (shards.find(s => s.id === p.id)) return;
              openShard(p);
            }, delay);
          }
          openIdx++;
        }
      }
      return;
    }

    if (t === 'REQ') {
      const subId = msg[1];
      if (typeof subId === 'string') activeSubscriptions.set(subId, raw);
      broadcastToShards(raw);
      return;
    }

    if (t === 'CLOSE') {
      const subId = msg[1];
      if (typeof subId === 'string') {
        activeSubscriptions.delete(subId);
        seenEOSE.delete(subId);
      }
      broadcastToShards(raw);
      return;
    }

    if (t === 'EVENT' || t === 'GEO_EVENT' || t === 'DM_EVENT' || t === 'GEO_REQ') {
      if (t === 'GEO_REQ' && typeof msg[2] === 'string') {
        activeSubscriptions.set(msg[2], raw);
      }
      broadcastToShards(raw);
      return;
    }
  });

  function cleanup() {
    serverOpen = false;
    if (keepaliveTimer) { clearInterval(keepaliveTimer); keepaliveTimer = null; }
    if (shardKeepaliveTimer) { clearInterval(shardKeepaliveTimer); shardKeepaliveTimer = null; }
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    for (const sh of shards) {
      sh._closing = true;
      try { if (sh.ws) sh.ws.close(); } catch { /* noop */ }
    }
    shards.length = 0;
    activeSubscriptions.clear();
  }

  server.addEventListener('close', cleanup);
  server.addEventListener('error', cleanup);

  return new Response(null, { status: 101, webSocket: client });
}

function buildShardEndpoint(requestUrl) {
  const u = new URL(requestUrl);
  const protocol = u.protocol === 'http:' ? 'ws:' : 'wss:';
  return `${protocol}//${u.host}${SHARD_PATH}`;
}
