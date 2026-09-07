// Which callers may reach the API at all.

const CLIENT_ORIGIN_HOSTS = new Set([
  "nymbot.ai",
  "www.nymbot.ai"
]);

/// Extra hosts for a deployment that needs them (a staging domain, a local
/// build). Comma-separated hostnames in `API_CLIENT_HOSTS`.
function envClientHosts(env) {
  const raw = env && typeof env.API_CLIENT_HOSTS === "string" ? env.API_CLIENT_HOSTS : "";
  if (!raw) return null;
  return new Set(raw.split(",").map((h) => h.trim().toLowerCase()).filter(Boolean));
}

/// An allowlisted host counts only over https, so an origin a network attacker
/// could mint on plaintext is not one of ours. Loopback is the exception, so a
/// local build can be added to API_CLIENT_HOSTS and work.
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

export { CLIENT_ORIGIN_HOSTS, isNymchatClient };
