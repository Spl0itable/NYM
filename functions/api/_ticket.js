import { hmac, sha256, utf8ToBytes, bytesToHex } from './_shared.js';

const TICKET_VERSION = '1';
const SOCKET_TICKET_TTL_MS = 120000;
const SOCKET_TICKET_SKEW_MS = 5000;

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

function issueSocketTicket(env, request, now) {
  const secret = ticketSecret(env);
  if (!secret) return null;
  const exp = (typeof now === 'number' ? now : Date.now()) + SOCKET_TICKET_TTL_MS;
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
  if (exp - t > SOCKET_TICKET_TTL_MS + SOCKET_TICKET_SKEW_MS) return { ok: false, reason: 'malformed' };
  if (!sameString(parts[2], sign(secret, exp, ticketSubject(request)))) return { ok: false, reason: 'signature' };
  return { ok: true, expiresAt: exp };
}

function socketTicketGate(request, env, label) {
  const mode = ticketMode(env);
  if (mode === 'off' || !ticketSecret(env)) return null;
  let ticket = '';
  try { ticket = new URL(request.url).searchParams.get('t') || ''; } catch (_) { }
  const verdict = verifySocketTicket(env, request, ticket);
  if (verdict.ok) return null;
  const ip = request.headers.get('CF-Connecting-IP') || '-';
  const ua = (request.headers.get('User-Agent') || '-').slice(0, 120);
  console.log(`Socket ticket ${mode === 'enforce' ? 'refused' : 'would refuse'} ${label} (${verdict.reason}) ip=${ip} ua="${ua}"`);
  if (mode !== 'enforce') return null;
  return new Response('Forbidden', { status: 403 });
}

export { SOCKET_TICKET_TTL_MS, ticketSecret, ticketMode, ticketSubject, issueSocketTicket, verifySocketTicket, socketTicketGate };
