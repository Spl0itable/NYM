// D1 storage over one authenticated WebSocket: AUTH once (kind 27235), then REQ/RES/ITEM/END frames per op.

import { routeStorageAction } from './api/storage.js';
import { handleBotPMAction, botReleaseStrandedTurn } from './api/bot.js';
import { verifyClientAuth, getPublicKey, AUTH_REPLAY_TTL_S } from './api/_shared.js';
import { ledgerCall } from './api/_ledger.js';
import { isNymchatClient, servedHostAllowed } from './api/_client.js';

const BOT_ACTIONS = {
  'pm': 1, 'pm-claim': 1, 'pm-cancel': 1, 'pm-steer': 1, 'pm-steer-status': 1, 'pm-runs': 1, 'clear-history': 1, 'balance': 1,
  'create-invoice': 1, 'check-invoice': 1, 'claim-credits': 1, 'transfer-credits': 1,
  'voucher-keys': 1, 'voucher-issue': 1
};

export function wsAuthHostOk(auth, reqUrl) {
  const tags = auth && Array.isArray(auth.tags) ? auth.tags : [];
  const tag = tags.find((t) => Array.isArray(t) && t[0] === 'u');
  if (!tag) return false;
  try {
    return new URL(String(tag[1])).host === new URL(reqUrl).host;
  } catch {
    return false;
  }
}

export async function wsAuthFresh(env, auth) {
  try {
    const rp = await ledgerCall(env, { op: 'replay', id: auth && auth.id, ttl: AUTH_REPLAY_TTL_S });
    if (rp && rp._noLedger) return true;
    return !!(rp && rp.fresh);
  } catch {
    return false;
  }
}

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
        if (line) { try { send(['ITEM', id, JSON.parse(line)]); } catch {} }
      }
    }
    if (buf.trim()) { try { send(['ITEM', id, JSON.parse(buf)]); } catch {} }
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

  if (!servedHostAllowed(request, env)) {
    return new Response('Forbidden', { status: 403 });
  }
  const upgrade = request.headers.get('Upgrade');
  if (!upgrade || upgrade.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }
  if (!isNymchatClient(request, env)) {
    return new Response('Forbidden', { status: 403 });
  }

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  const reqUrl = request.url;
  let authedPubkey = null;

  const send = (arr) => {
    try { if (server.readyState === 1) server.send(JSON.stringify(arr)); } catch {}
  };

  const waitUntil = context.waitUntil
    ? context.waitUntil.bind(context)
    : (p) => { try { if (p && p.catch) p.catch(() => {}); } catch {} };

  server.addEventListener('message', async (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    if (!Array.isArray(msg)) return;
    const type = msg[0];

    if (type === 'AUTH') {
      const auth = msg[1];
      if (!auth || typeof auth.pubkey !== 'string' ||
        !verifyClientAuth(auth, auth.pubkey, { action: 'api-ws' }) ||
        !wsAuthHostOk(auth, reqUrl) || !(await wsAuthFresh(env, auth))) {
        send(['AUTH_ERR', 'Authentication failed']);
        try { server.close(4001, 'auth'); } catch {}
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
        // Release a crashed turn's de-duplication claim.
        await botReleaseStrandedTurn(ctx);
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

  // Keep the invocation open for the socket's lifetime; an idle WS worker is otherwise reaped as "hung".
  let endLifetime;
  const lifetime = new Promise((resolve) => { endLifetime = resolve; });
  const closeLifetime = () => { try { endLifetime(); } catch {} };
  server.addEventListener('close', closeLifetime);
  server.addEventListener('error', closeLifetime);
  setTimeout(closeLifetime, 280000);
  waitUntil(lifetime);

  return new Response(null, { status: 101, webSocket: client });
}
