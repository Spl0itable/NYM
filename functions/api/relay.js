// Cloudflare Pages Function: WebSocket proxy for Nostr relays
// Proxies client WebSocket connections through Cloudflare Workers so relays
// only see Cloudflare IP addresses instead of end-user IPs.
//
// Client connects to: wss://<host>/api/relay?relay=wss://relay.example.com
// Worker connects to the target relay via new WebSocket() and forwards
// messages bidirectionally through a WebSocketPair.

export async function onRequest(context) {
  const { request } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
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
  } catch {
    return new Response('Invalid relay URL', { status: 400 });
  }

  // Create the WebSocket pair for the client connection
  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  // Connect to the upstream relay using the WebSocket constructor
  // (the standard way to make outbound WebSocket connections from Workers)
  const upstream = new WebSocket(targetRelay);

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
