import { runScheduled } from "./_schedule.js";

const SECRET_HEADER = "X-Nymchat-Proxy-Secret";

async function secretAllowed(request, env) {
  const secret = String((env && env.NYMCHAT_PROXY_SECRET) || "");
  const given = String(request.headers.get(SECRET_HEADER) || "");
  if (!secret || !given) return false;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(secret)),
    crypto.subtle.digest("SHA-256", enc.encode(given))
  ]);
  const x = new Uint8Array(a), y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function proxyHostOf(request, env) {
  if (env && env.NYMCHAT_PROXY_HOST) return String(env.NYMCHAT_PROXY_HOST);
  try { return new URL(request.url).hostname; } catch { return ""; }
}

export async function onRequestPost(context) {
  const { request, env } = context;
  if (!(await secretAllowed(request, env))) return new Response("Not found", { status: 404 });
  let now;
  if (env && env.SCHEDULE_TEST_HOOKS === "1") {
    try {
      const body = await request.json();
      if (body && Number.isSafeInteger(body.now)) now = body.now;
    } catch { }
  }
  const summary = await runScheduled(env, { now, context, proxyHost: proxyHostOf(request, env) });
  return new Response(JSON.stringify(summary), {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" }
  });
}

export async function onRequest(context) {
  if (context.request.method === "POST") return onRequestPost(context);
  return new Response("Not found", { status: 404 });
}
