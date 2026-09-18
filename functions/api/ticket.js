import { CLIENT_CORS_HEADERS } from './_shared.js';
import { isNymchatClient } from './_client.js';
import { SOCKET_TICKET_TTL_MS, issueSocketTicket, ticketMode, sessionTicketCookie } from './_ticket.js';

const JSON_HEADERS = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...CLIENT_CORS_HEADERS };

function json(body, status = 200, cookie = null) {
  const headers = cookie ? { ...JSON_HEADERS, 'Set-Cookie': cookie } : JSON_HEADERS;
  return new Response(JSON.stringify(body), { status, headers });
}

export async function onRequest(context) {
  const { request, env } = context;
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CLIENT_CORS_HEADERS });
  if (request.method !== 'POST') return json({ error: 'POST required' }, 405);
  if (!isNymchatClient(request, env)) return json({ error: 'Forbidden' }, 403);
  const issued = issueSocketTicket(env, request);
  if (!issued) return json({ error: 'Socket tickets are not configured', mode: ticketMode(env) }, 503);
  return json({ ticket: issued.ticket, expiresAt: issued.expiresAt, ttl: SOCKET_TICKET_TTL_MS, mode: ticketMode(env) }, 200, sessionTicketCookie(env, request));
}
