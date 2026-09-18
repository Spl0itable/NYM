import { servedHostAllowed } from './_client.js';
import { apiTicketGate } from './_ticket.js';

export async function onRequest(context) {
  const { request, env, next } = context;
  if (!servedHostAllowed(request, env)) {
    return new Response(JSON.stringify({ error: 'Forbidden' }), {
      status: 403,
      headers: { 'Content-Type': 'application/json' }
    });
  }
  const refused = apiTicketGate(request, env);
  if (refused) return refused;
  return next();
}
