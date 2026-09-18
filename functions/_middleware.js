import { sessionTicketCookie } from './api/_ticket.js';

export async function onRequest(context) {
  const { request, env, next } = context;
  let path = '';
  try { path = new URL(request.url).pathname; } catch (_) { path = ''; }
  const resp = await next();
  if (request.method !== 'GET' || (path !== '/' && path !== '/index.html')) return resp;
  if (!resp || (resp.status !== 200 && resp.status !== 304)) return resp;
  const cookie = sessionTicketCookie(env, request);
  if (!cookie) return resp;
  const out = new Response(resp.body, resp);
  out.headers.append('Set-Cookie', cookie);
  return out;
}
