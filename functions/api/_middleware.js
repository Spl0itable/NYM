import { servedHostAllowed } from './_client.js';

export async function onRequest(context) {
  const { request, env, next } = context;
  if (!servedHostAllowed(request, env)) {
    return new Response(JSON.stringify({ error: 'Forbidden' }), { status: 403, headers: { 'Content-Type': 'application/json' } });
  }
  return next();
}
