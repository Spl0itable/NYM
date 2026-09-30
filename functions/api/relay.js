// WebSocket relay proxy so relays see Cloudflare IPs, not users': /api/relay?relay=wss://...

import { isNymchatClient } from './_client.js';
import { ipv6Blocked } from './_shared.js';
import { filterSet, frameHit, eventHit, noteReport } from './_filters.js';
import { reviewSpamReport, spamEngine, frameBadgeRefused } from './_spam.js';

const APP_RELAY = 'wss://relay.nymchat.app';

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

  let gate = await filterSet(env);
  const spam = spamEngine(env, context);
  let sockHeld = null;
  const gateTimer = setInterval(() => { filterSet(env).then((s) => { gate = s; }, () => { }); }, 30000);

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  function heldOutbound(data) {
    if (typeof data !== 'string' || !data.startsWith('["EVENT"')) return false;
    let ev = null;
    try { const arr = JSON.parse(data); ev = Array.isArray(arr) ? arr[1] : null; } catch { return false; }
    if (!ev) return false;
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

  const upstream = new WebSocket(targetRelay);

  let upstreamOpen = false;
  const pendingMessages = [];

  upstream.addEventListener('open', () => {
    upstreamOpen = true;
    for (const msg of pendingMessages) {
      try { upstream.send(msg); } catch {}
    }
    pendingMessages.length = 0;
  });

  server.addEventListener('message', (event) => {
    context.waitUntil(
      (async () => {
        try {
          if (heldOutbound(event.data)) return;
          if (upstreamOpen && upstream.readyState === WebSocket.OPEN) {
            upstream.send(event.data);
          } else if (!upstreamOpen) {
            pendingMessages.push(event.data);
          }
        } catch {
        }
      })()
    );
  });

  upstream.addEventListener('message', (event) => {
    try {
      if (typeof event.data === 'string' && event.data.startsWith('["EVENT"') && frameHit(gate, event.data)) return;
      if (frameBadgeRefused(env, spam, event.data)) return;
      if (server.readyState === 1) {
        server.send(event.data);
      }
    } catch {
    }
  });

  server.addEventListener('close', (event) => {
    clearInterval(gateTimer);
    try {
      upstream.close(event.code, event.reason);
    } catch {
    }
  });

  upstream.addEventListener('close', (event) => {
    clearInterval(gateTimer);
    try {
      server.close(event.code, event.reason);
    } catch {
    }
  });

  server.addEventListener('error', () => {
    try { upstream.close(1011, 'Client error'); } catch {}
  });

  upstream.addEventListener('error', () => {
    try { server.close(1011, 'Upstream relay error'); } catch {}
  });

  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}
