import { hmac, sha256, utf8ToBytes, bytesToHex } from './_shared.js';

const TICKET_VERSION = '1';
const SOCKET_TICKET_TTL_MS = 120000;
const SESSION_TICKET_TTL_MS = 86400000;
const SOCKET_TICKET_SKEW_MS = 5000;
const SESSION_COOKIE = 'nym_ticket';

function ticketSecret(env) {
  const raw = env && typeof env.NYMCHAT_SOCKET_TICKET_SECRET === 'string' ? env.NYMCHAT_SOCKET_TICKET_SECRET.trim() : '';
  return raw || null;
}

function ticketMode(env) {
  const raw = env && typeof env.NYMCHAT_SOCKET_TICKET_MODE === 'string' ? env.NYMCHAT_SOCKET_TICKET_MODE.trim().toLowerCase() : '';
  return raw === 'off' || raw === 'enforce' ? raw : 'log';
}

function ticketSubject(request) {
  const ua = (request && request.headers && request.headers.get('User-Agent')) || '';
  return bytesToHex(sha256(utf8ToBytes(ua))).slice(0, 16);
}

function sign(secret, exp, subject) {
  return bytesToHex(hmac(sha256, utf8ToBytes(secret), utf8ToBytes(`${exp}:${subject}`)));
}

function sameString(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function issueSocketTicket(env, request, now, ttlMs) {
  const secret = ticketSecret(env);
  if (!secret) return null;
  const life = typeof ttlMs === 'number' && ttlMs > 0 ? Math.min(ttlMs, SESSION_TICKET_TTL_MS) : SOCKET_TICKET_TTL_MS;
  const exp = (typeof now === 'number' ? now : Date.now()) + life;
  return { ticket: `${TICKET_VERSION}.${exp}.${sign(secret, exp, ticketSubject(request))}`, expiresAt: exp };
}

function verifySocketTicket(env, request, ticket, now) {
  const secret = ticketSecret(env);
  if (!secret) return { ok: false, reason: 'unconfigured' };
  if (typeof ticket !== 'string' || !ticket) return { ok: false, reason: 'missing' };
  const parts = ticket.split('.');
  if (parts.length !== 3 || parts[0] !== TICKET_VERSION) return { ok: false, reason: 'malformed' };
  const exp = Number(parts[1]);
  if (!Number.isFinite(exp)) return { ok: false, reason: 'malformed' };
  const t = typeof now === 'number' ? now : Date.now();
  if (t > exp + SOCKET_TICKET_SKEW_MS) return { ok: false, reason: 'expired' };
  if (exp - t > SESSION_TICKET_TTL_MS + SOCKET_TICKET_SKEW_MS) return { ok: false, reason: 'malformed' };
  if (!sameString(parts[2], sign(secret, exp, ticketSubject(request)))) return { ok: false, reason: 'signature' };
  return { ok: true, expiresAt: exp };
}

function cookieValue(request, name) {
  const raw = (request && request.headers && request.headers.get('Cookie')) || '';
  for (const part of raw.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return '';
}

function ticketFromRequest(request) {
  const header = request && request.headers && request.headers.get('X-Nym-Ticket');
  if (typeof header === 'string' && header) return header;
  let fromQuery = '';
  try { fromQuery = new URL(request.url).searchParams.get('t') || ''; } catch (_) { fromQuery = ''; }
  if (fromQuery) return fromQuery;
  return cookieValue(request, SESSION_COOKIE);
}

function sessionTicketCookie(env, request, now) {
  if (ticketMode(env) === 'off') return null;
  const issued = issueSocketTicket(env, request, now, SESSION_TICKET_TTL_MS);
  if (!issued) return null;
  return `${SESSION_COOKIE}=${issued.ticket}; Path=/; Max-Age=${Math.floor(SESSION_TICKET_TTL_MS / 1000)}; Secure; HttpOnly; SameSite=Lax`;
}

function buildTokenOk(request, env) {
  const want = env && typeof env.NYM_BUILD_TOKEN === 'string' ? env.NYM_BUILD_TOKEN.trim() : '';
  if (!want) return false;
  const got = (request && request.headers && request.headers.get('X-Nym-Build')) || '';
  return sameString(got, want);
}

function proxyWriteGate(request, env, action) {
  const mode = ticketMode(env);
  if (mode === 'off' || !ticketSecret(env)) return null;
  if (buildTokenOk(request, env)) return null;
  const verdict = verifySocketTicket(env, request, ticketFromRequest(request));
  if (verdict.ok) return null;
  const ip = request.headers.get('CF-Connecting-IP') || '-';
  const ua = (request.headers.get('User-Agent') || '-').slice(0, 120);
  console.log(`Proxy ticket ${mode === 'enforce' ? 'refused' : 'would refuse'} ${request.method} ${action || '-'} (${verdict.reason}) ip=${ip} ua="${ua}"`);
  if (mode !== 'enforce') return null;
  return new Response(JSON.stringify({ error: 'Ticket required' }), { status: 403, headers: { 'Content-Type': 'application/json' } });
}

function socketTicketGate(request, env, label) {
  const mode = ticketMode(env);
  if (mode === 'off' || !ticketSecret(env)) return null;
  const ticket = ticketFromRequest(request);
  const verdict = verifySocketTicket(env, request, ticket);
  if (verdict.ok) return null;
  const ip = request.headers.get('CF-Connecting-IP') || '-';
  const ua = (request.headers.get('User-Agent') || '-').slice(0, 120);
  console.log(`Ticket ${mode === 'enforce' ? 'refused' : 'would refuse'} ${request.method} ${label} (${verdict.reason}) ip=${ip} ua="${ua}"`);
  if (mode !== 'enforce') return null;
  return new Response(JSON.stringify({ error: 'Ticket required' }), { status: 403, headers: { 'Content-Type': 'application/json' } });
}

function apiTicketGate(request, env) {
  const method = request.method || 'GET';
  if (method === 'OPTIONS') return null;
  let path = '';
  let action = '';
  try { const u = new URL(request.url); path = u.pathname; action = u.searchParams.get('action') || ''; } catch (_) { return null; }
  if (path === '/api/ticket') return null;
  if (path === '/api/proxy') {
    if (method === 'GET' || method === 'HEAD') return null;
    return proxyWriteGate(request, env, action);
  }
  return socketTicketGate(request, env, path);
}

export { SOCKET_TICKET_TTL_MS, SESSION_TICKET_TTL_MS, SESSION_COOKIE, ticketSecret, ticketMode, ticketSubject, issueSocketTicket, verifySocketTicket, socketTicketGate, ticketFromRequest, buildTokenOk, proxyWriteGate, apiTicketGate, cookieValue, sessionTicketCookie };
