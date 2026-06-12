// Cloudflare Pages Function: WebSocket proxy for Nostr relays
// Proxies client WebSocket connections through Cloudflare Workers so relays
// only see Cloudflare IP addresses instead of end-user IPs.
//
// Client connects to: wss://<host>/api/relay?relay=wss://relay.example.com
// Worker connects to the target relay via new WebSocket() and forwards
// messages bidirectionally through a WebSocketPair.

const APP_RELAY = 'wss://relay.nymchat.app';

function isNymchatClient(request) {
  const origin = request.headers.get('Origin') || '';
  if (origin) {
    try {
      if (new URL(origin).host.toLowerCase() === new URL(request.url).host.toLowerCase()) return true;
    } catch (_) {}
  }
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

function buildUpstreamUrl(targetRelay, request, env) {
  if (targetRelay !== APP_RELAY) return targetRelay;
  if (!env || !env.NYMCHAT_PROXY_SECRET) return targetRelay;
  if (!isNymchatClient(request)) return targetRelay;
  const u = new URL(targetRelay);
  u.searchParams.set('nymchat_proxy', env.NYMCHAT_PROXY_SECRET);
  return u.toString();
}

export async function onRequest(context) {
  const { request, env } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }

  if (!isNymchatClient(request)) {
    return new Response('Forbidden', { status: 403 });
  }

  const url = new URL(request.url);
  const targetRelay = url.searchParams.get('relay');

  if (!targetRelay) {
    return new Response('Missing relay parameter', { status: 400 });
  }

  // Validate the relay URL
  try {
    const relayUrl = new URL(targetRelay);
    if (relayUrl.protocol !== 'wss:' && relayUrl.protocol !== 'ws:') {
      return new Response('Relay URL must use ws:// or wss:// protocol', { status: 400 });
    }
    if (isPrivateRelayHost(relayUrl.hostname)) {
      return new Response('Relay host not allowed', { status: 403 });
    }
  } catch {
    return new Response('Invalid relay URL', { status: 400 });
  }

  // Create the WebSocket pair for the client connection
  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  // Connect to the upstream relay using the WebSocket constructor
  // (the standard way to make outbound WebSocket connections from Workers)
  const upstream = new WebSocket(buildUpstreamUrl(targetRelay, request, env));

  // Buffer messages from the client until the upstream connection is open
  let upstreamOpen = false;
  const pendingMessages = [];

  upstream.addEventListener('open', () => {
    upstreamOpen = true;
    // Flush any messages that arrived while upstream was connecting
    for (const msg of pendingMessages) {
      try { upstream.send(msg); } catch { /* noop */ }
    }
    pendingMessages.length = 0;
  });

  // Forward messages from client to upstream (buffering if not yet open)
  server.addEventListener('message', (event) => {
    context.waitUntil(
      (async () => {
        try {
          if (upstreamOpen && upstream.readyState === WebSocket.OPEN) {
            upstream.send(event.data);
          } else if (!upstreamOpen) {
            pendingMessages.push(event.data);
          }
        } catch {
          // Upstream closed
        }
      })()
    );
  });

  // Forward messages from upstream to client
  upstream.addEventListener('message', (event) => {
    try {
      if (server.readyState === 1) {
        server.send(event.data);
      }
    } catch {
      // Client closed
    }
  });

  // Handle close events
  server.addEventListener('close', (event) => {
    try {
      upstream.close(event.code, event.reason);
    } catch {
      // Already closed
    }
  });

  upstream.addEventListener('close', (event) => {
    try {
      server.close(event.code, event.reason);
    } catch {
      // Already closed
    }
  });

  // Handle errors
  server.addEventListener('error', () => {
    try { upstream.close(1011, 'Client error'); } catch { /* noop */ }
  });

  upstream.addEventListener('error', () => {
    try { server.close(1011, 'Upstream relay error'); } catch { /* noop */ }
  });

  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}
