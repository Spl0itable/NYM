// WebSocket relay proxy so relays see Cloudflare IPs, not users': /api/relay?relay=wss://...

import { isNymchatClient } from './_client.js';
import { ipv6Blocked, earlyHoldTake, earlyHoldGive } from './_shared.js';
import { filterSet, frameHit, eventHit, noteReport, reportEventIds, reportIdsCheckable, reportTargetsArchived } from './_filters.js';
import { reviewSpamReport, spamEngine, frameBadgeRefused } from './_spam.js';
import { verifySignedEvent, clientIpKey, connectLimiter, CONNECT_LIMIT_CODE, CONNECT_LIMIT_REASON, eventBudget } from './relay-pool.js';
import { isEncryptedBlobChannelEvent } from './_encrypted-blob.js';
import { isBridgeBlockedEvent, isBridgeBlockedFrame } from './_bridge-block.js';

const RX_BLOB_KIND_FRAME = /"kind"\s*:\s*(?:20000|23333)\b/;
const RX_REPORT_KIND_FRAME = /"kind"\s*:\s*1984\b/;
const relayConnects = connectLimiter('relay-connect');

function reportOf(data) {
  if (typeof data !== 'string' || !RX_REPORT_KIND_FRAME.test(data)) return null;
  try {
    const arr = JSON.parse(data);
    const ev = Array.isArray(arr) && arr[0] === 'EVENT' ? arr[1] : null;
    const ids = reportEventIds(ev);
    return ids ? { ev, ids } : null;
  } catch {
    return null;
  }
}

function isBlobFrame(data) {
  if (typeof data !== 'string' || !RX_BLOB_KIND_FRAME.test(data)) return false;
  try {
    const arr = JSON.parse(data);
    return Array.isArray(arr) && isEncryptedBlobChannelEvent(arr[2]);
  } catch {
    return false;
  }
}

const APP_RELAY = 'wss://relay.nymchat.app';
const RELAY_EARLY_FRAMES_MAX = 1000;
const RELAY_EARLY_CHARS_MAX = 2 * 1024 * 1024;

// Reject private/loopback/link-local relay hosts so the proxy can't reach internal services (SSRF).
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

const APP_RELAY_HOST = new URL(APP_RELAY).hostname;

function isAppRelayHost(hostname) {
  const h = (hostname || '').toLowerCase().replace(/\.$/, '');
  return h === APP_RELAY_HOST;
}

export { isPrivateRelayHost };

export async function onRequest(context) {
  const { request, env } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }

  if (!isNymchatClient(request, env)) {
    return new Response('Forbidden', { status: 403 });
  }
  const ipKey = clientIpKey(request);

  const url = new URL(request.url);
  const targetRelay = url.searchParams.get('relay');

  if (!targetRelay) {
    return new Response('Missing relay parameter', { status: 400 });
  }

  try {
    const relayUrl = new URL(targetRelay);
    if (relayUrl.protocol !== 'wss:' && relayUrl.protocol !== 'ws:') {
      return new Response('Relay URL must use ws:// or wss:// protocol', { status: 400 });
    }
    if (isPrivateRelayHost(relayUrl.hostname)) {
      return new Response('Relay host not allowed', { status: 403 });
    }
    if (isAppRelayHost(relayUrl.hostname)) {
      return new Response('The app relay is only reachable through /api/relay-pool', { status: 403 });
    }
  } catch {
    return new Response('Invalid relay URL', { status: 400 });
  }

  if (relayConnects.knownOver(ipKey)) {
    const { 0: client, 1: server } = new WebSocketPair();
    server.accept();
    try { server.close(CONNECT_LIMIT_CODE, CONNECT_LIMIT_REASON); } catch {}
    return new Response(null, { status: 101, webSocket: client });
  }

  const gateLoad = filterSet(env);
  let gate = null;
  const spam = spamEngine(env, context);
  let sockHeld = null;
  const gateTimer = setInterval(() => { filterSet(env).then((s) => { gate = s; }, () => { }); }, 30000);

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  let gateOpen = false;
  let clientGone = false;
  const early = [];
  let earlyChars = 0;

  function heldOutbound(data) {
    if (typeof data !== 'string') return false;
    let ev = null;
    try { const arr = JSON.parse(data); ev = Array.isArray(arr) && arr[0] === 'EVENT' ? arr[1] : null; } catch { return false; }
    if (!ev) return false;
    if (isBridgeBlockedEvent(ev)) {
      if (typeof ev.id === 'string') {
        try { server.send(JSON.stringify(['OK', ev.id, false, 'blocked: not accepted'])); } catch {}
      }
      return true;
    }
    if (isEncryptedBlobChannelEvent(ev)) {
      if (typeof ev.id === 'string') {
        try { server.send(JSON.stringify(['OK', ev.id, false, 'blocked: encrypted blob'])); } catch {}
      }
      return true;
    }
    if (ev.kind === 1984) context.waitUntil(noteReport(env, ev, 'relay').then((ok) => (ok ? reviewSpamReport(env, ev) : null)).catch(() => null));
    let mode = sockHeld;
    if (!mode) {
      mode = eventHit(gate, ev);
      if (mode && typeof ev.pubkey === 'string' && gate.p.has(ev.pubkey.toLowerCase())) sockHeld = mode;
    }
    if (!mode) return false;
    if (typeof ev.id === 'string') {
      try {
        server.send(JSON.stringify(mode === 'reject'
          ? ['OK', ev.id, false, 'blocked: not accepted']
          : ['OK', ev.id, true, '']));
      } catch {}
    }
    return true;
  }

  let upstream = null;
  let upstreamOpen = false;
  const pendingMessages = [];
  const reportBudget = eventBudget();

  function reportForwardable(report) {
    if (!reportIdsCheckable(report.ids) || !reportBudget.take() || !verifySignedEvent(report.ev)) return Promise.resolve(false);
    return reportTargetsArchived(env, report.ids);
  }

  function fromClient(event) {
    context.waitUntil(
      (async () => {
        try {
          if (heldOutbound(event.data)) return;
          const report = reportOf(event.data);
          if (report && !(await reportForwardable(report))) {
            if (typeof report.ev.id === 'string') {
              try { server.send(JSON.stringify(['OK', report.ev.id, true, ''])); } catch {}
            }
            return;
          }
          if (upstreamOpen && upstream.readyState === WebSocket.OPEN) {
            upstream.send(event.data);
          } else if (!upstreamOpen) {
            pendingMessages.push(event.data);
          }
        } catch {
        }
      })()
    );
  }

  function fromUpstream(event) {
    try {
      if (typeof event.data === 'string' && event.data.startsWith('["EVENT"') && frameHit(gate, event.data)) return;
      if (isBlobFrame(event.data)) return;
      if (isBridgeBlockedFrame(event.data)) return;
      if (frameBadgeRefused(env, spam, event.data, verifySignedEvent)) return;
      if (server.readyState === 1) {
        server.send(event.data);
      }
    } catch {
    }
  }

  function dropEarly() {
    early.length = 0;
    earlyHoldGive(earlyChars);
    earlyChars = 0;
  }

  function refuseEarly(code, reason) {
    clientGone = true;
    dropEarly();
    clearInterval(gateTimer);
    try { server.close(code, reason); } catch {}
    try { if (upstream) upstream.close(1000, 'client refused'); } catch {}
  }

  function holdUntilGate(handle, event) {
    if (clientGone) return;
    const size = typeof event.data === 'string' ? event.data.length : ((event.data && event.data.byteLength) || 0);
    if (early.length >= RELAY_EARLY_FRAMES_MAX || earlyChars + size > RELAY_EARLY_CHARS_MAX) {
      refuseEarly(1008, 'too many frames before the relay was ready');
      return;
    }
    if (!earlyHoldTake(size)) {
      refuseEarly(1013, 'relay busy, reconnect shortly');
      return;
    }
    early.push([handle, event]);
    earlyChars += size;
  }

  function closeFromUpstream(event) {
    try {
      server.close(event.code, event.reason);
    } catch {
    }
  }

  function upstreamEnded(event) {
    if (gateOpen || clientGone) closeFromUpstream(event);
    else early.push([closeFromUpstream, event]);
  }

  server.addEventListener('message', (event) => {
    if (gateOpen) fromClient(event);
    else holdUntilGate(fromClient, event);
  });

  function dial() {
    upstream = new WebSocket(targetRelay);
    upstream.addEventListener('open', () => {
      upstreamOpen = true;
      for (const msg of pendingMessages) {
        try { upstream.send(msg); } catch {}
      }
      pendingMessages.length = 0;
    });
    upstream.addEventListener('message', (event) => {
      if (gateOpen) fromUpstream(event);
      else holdUntilGate(fromUpstream, event);
    });
    upstream.addEventListener('close', (event) => {
      clearInterval(gateTimer);
      upstreamEnded(event);
    });
    upstream.addEventListener('error', () => {
      upstreamEnded({ code: 1011, reason: 'Upstream relay error' });
    });
  }

  context.waitUntil(relayConnects.allowed(ipKey).then((ok) => {
    if (clientGone) return;
    if (!ok) { refuseEarly(CONNECT_LIMIT_CODE, CONNECT_LIMIT_REASON); return; }
    dial();
    return gateLoad.then((set) => {
      if (!gate) gate = set;
      gateOpen = true;
      const queued = early.splice(0);
      earlyHoldGive(earlyChars);
      earlyChars = 0;
      if (clientGone) return;
      for (const [handle, event] of queued) {
        try { handle(event); } catch {}
      }
    });
  }).catch(() => {
    clientGone = true;
    dropEarly();
    try { server.close(1011, 'relay unavailable'); } catch {}
    try { if (upstream) upstream.close(1011, 'relay unavailable'); } catch {}
  }));

  server.addEventListener('close', (event) => {
    clientGone = true;
    dropEarly();
    clearInterval(gateTimer);
    try {
      if (upstream) upstream.close(event.code, event.reason);
    } catch {
    }
  });

  server.addEventListener('error', () => {
    try { if (upstream) upstream.close(1011, 'Client error'); } catch {}
  });

  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}
