const CLIENT_ORIGIN_HOSTS = new Set([
  "nymbot.ai",
  "www.nymbot.ai"
]);

// Extra comma-separated client hostnames from `API_CLIENT_HOSTS`.
function envClientHosts(env) {
  const raw = env && typeof env.API_CLIENT_HOSTS === "string" ? env.API_CLIENT_HOSTS : "";
  if (!raw) return null;
  return new Set(raw.split(",").map((h) => h.trim().toLowerCase()).filter(Boolean));
}

// Allowlisted hosts count only over https (loopback excepted) so plaintext origins can't be minted.
function originIsTrustworthy(url) {
  if (url.protocol === "https:") return true;
  return url.protocol === "http:" &&
    (url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]");
}

function isNymchatClient(request, env) {
  const origin = request.headers.get("Origin") || "";
  if (origin) {
    try {
      const url = new URL(origin);
      const host = url.host.toLowerCase();
      if (host === new URL(request.url).host.toLowerCase()) return true;
      if (originIsTrustworthy(url)) {
        if (CLIENT_ORIGIN_HOSTS.has(host)) return true;
        const extra = envClientHosts(env);
        if (extra && extra.has(host)) return true;
      }
    } catch (_) {}
  }
  const ua = request.headers.get("User-Agent") || "";
  return /Nym(?:chat|bot)App\//i.test(ua) || /\bNYMApp\b/.test(ua);
}

const APP_ORIGIN_HOSTS = new Set([
  "web.nymchat.app",
  "nymchat.app"
]);

function clientOriginAllowed(request, env) {
  const origin = request.headers.get("Origin");
  if (!origin) return true;   // Native clients and same-origin GETs send no Origin.
  try {
    const url = new URL(origin);
    if (url.origin === new URL(request.url).origin) return true;
    if (!originIsTrustworthy(url)) return false;
    const host = url.host.toLowerCase();
    if (APP_ORIGIN_HOSTS.has(host) || CLIENT_ORIGIN_HOSTS.has(host)) return true;
    const extra = envClientHosts(env);
    return !!(extra && extra.has(host));
  } catch (_) {
    return false;
  }
}

function isStandaloneNymbot(request, env) {
  const origin = request.headers.get("Origin") || "";
  if (origin) {
    try {
      const url = new URL(origin);
      const host = url.host.toLowerCase();
      if (originIsTrustworthy(url)) {
        if (CLIENT_ORIGIN_HOSTS.has(host)) return true;
        const extra = envClientHosts(env);
        if (extra && extra.has(host)) return true;
      }
    } catch (_) {}
  }
  return /NymbotApp\//i.test(request.headers.get("User-Agent") || "");
}

function envServeHosts(env) {
  const raw = env && typeof env.API_SERVE_HOSTS === "string" ? env.API_SERVE_HOSTS : "";
  return raw.split(",").map((h) => h.trim().toLowerCase()).filter(Boolean);
}

function isLoopbackHost(hostname) {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]";
}

function servedHostAllowed(request, env) {
  let hostname;
  try {
    hostname = new URL(request.url).hostname.toLowerCase();
  } catch (_) {
    return false;
  }
  if (!hostname) return false;
  if (isLoopbackHost(hostname)) return true;
  if (APP_ORIGIN_HOSTS.has(hostname) || CLIENT_ORIGIN_HOSTS.has(hostname)) return true;
  for (const entry of envServeHosts(env)) {
    if (entry.startsWith("*.")) {
      const suffix = entry.slice(1);
      if (hostname.endsWith(suffix) && hostname.length > suffix.length) return true;
    } else if (entry === hostname) {
      return true;
    }
  }
  return false;
}

export { CLIENT_ORIGIN_HOSTS, APP_ORIGIN_HOSTS, clientOriginAllowed, isNymchatClient, isStandaloneNymbot, servedHostAllowed };
