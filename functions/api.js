// Cloudflare Pages Function: D1 storage over a single WebSocket (wss://<host>/api).
// The connection authenticates once (one signed kind 27235 event), then carries
// every storage op so the client doesn't open an HTTP request per fetch/put.
//
// Protocol (client -> worker):
//   ["AUTH", <signed 27235 event>]        - authenticate the socket once
//   ["REQ", id, action, payload]          - run a storage action
// Protocol (worker -> client):
//   ["AUTH_OK"] / ["AUTH_ERR", reason]
//   ["RES", id, status, data]             - JSON result
//   ["ITEM", id, obj] ... ["END", id, status] - streamed (ndjson) result

import { routeStorageAction } from './api/storage.js';
import { handleBotPMAction } from './api/bot.js';
import { verifyClientAuth, isNymchatClient, getPublicKey } from './api/_shared.js';

// Actions handled by the bot worker (Nymbot PM, credits, invoices, Ledger).
const BOT_ACTIONS = {
  'pm': 1, 'clear-history': 1, 'balance': 1,
  'create-invoice': 1, 'check-invoice': 1, 'claim-credits': 1, 'transfer-credits': 1
};

async function forwardResponse(id, resp, send) {
  const status = resp.status || 200;
  const ct = resp.headers.get('Content-Type') || '';
  if (ct.indexOf('application/x-ndjson') >= 0 && resp.body) {
    const reader = resp.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line) { try { send(['ITEM', id, JSON.parse(line)]); } catch { /* skip */ } }
      }
    }
    if (buf.trim()) { try { send(['ITEM', id, JSON.parse(buf)]); } catch { /* skip */ } }
    const hdrs = {};
    resp.headers.forEach((v, k) => { hdrs[k.toLowerCase()] = v; });
    send(['END', id, status, hdrs]);
    return;
  }
  let data = {};
  try { data = await resp.json(); } catch { data = {}; }
  send(['RES', id, status, data]);
}

export async function onRequest(context) {
  const { request, env } = context;

  const upgrade = request.headers.get('Upgrade');
  if (!upgrade || upgrade.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }
  if (!isNymchatClient(request)) {
    return new Response('Forbidden', { status: 403 });
  }

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  const reqUrl = request.url;
  let authedPubkey = null;

  const send = (arr) => {
    try { if (server.readyState === 1) server.send(JSON.stringify(arr)); } catch { /* closed */ }
  };

  const waitUntil = context.waitUntil
    ? context.waitUntil.bind(context)
    : (p) => { try { if (p && p.catch) p.catch(() => {}); } catch { /* noop */ } };

  server.addEventListener('message', async (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    if (!Array.isArray(msg)) return;
    const type = msg[0];

    if (type === 'AUTH') {
      const auth = msg[1];
      if (!auth || typeof auth.pubkey !== 'string' ||
        !verifyClientAuth(auth, auth.pubkey, { action: 'api-ws' })) {
        send(['AUTH_ERR', 'Authentication failed']);
        try { server.close(4001, 'auth'); } catch { /* noop */ }
        return;
      }
      authedPubkey = auth.pubkey.toLowerCase();
      send(['AUTH_OK']);
      return;
    }

    if (type === 'REQ') {
      const id = msg[1];
      const action = msg[2];
      const payload = (msg[3] && typeof msg[3] === 'object') ? msg[3] : {};
      const body = Object.assign({}, payload, { action });
      // Private actions always operate on the socket's authenticated pubkey.
      if (authedPubkey) body.pubkey = authedPubkey;

      const ctx = {
        env,
        request: { url: reqUrl, headers: request.headers },
        waitUntil,
        _wsAuthedPubkey: authedPubkey
      };

      let resp;
      try {
        if (BOT_ACTIONS[action]) {
          const privkey = env.BOT_PRIVKEY;
          let botPubkey = null;
          if (privkey) { try { botPubkey = getPublicKey(privkey); } catch (_) { botPubkey = null; } }
          resp = await handleBotPMAction(ctx, body, privkey, botPubkey);
        } else {
          resp = await routeStorageAction(ctx, body);
        }
      } catch (e) {
        send(['RES', id, 500, { error: 'Internal server error' }]);
        return;
      }
      try {
        await forwardResponse(id, resp, send);
      } catch (e) {
        send(['RES', id, 500, { error: 'Stream failed' }]);
      }
      return;
    }
  });

  return new Response(null, { status: 101, webSocket: client });
}
