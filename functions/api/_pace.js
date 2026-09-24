var PACE_DEFAULT_TPM = 400000;
var PACE_WINDOW_MS = 60000;
var PACE_OUT_ESTIMATE_CAP = 4096;
var PACE_RETRY_AFTER_CAP_MS = 30000;

export function paceProviderOf(modelId) {
  var id = String(modelId || "").trim().toLowerCase();
  if (!id) return "gateway";
  if (/^@cf\//.test(id) || /^@hf\//.test(id) || /^workers-ai\//.test(id)) return "workers-ai";
  var slash = id.indexOf("/");
  if (slash <= 0) return "gateway";
  var vendor = id.slice(0, slash).replace(/[^a-z0-9._-]/g, "").slice(0, 40);
  return vendor || "gateway";
}

export function paceTpmFor(env, provider) {
  var key = "PRO_TPM_" + String(provider || "").toUpperCase().replace(/[^A-Z0-9]/g, "_");
  var own = Number(env && env[key]);
  if (Number.isFinite(own) && own > 0) return Math.floor(own);
  var all = Number(env && env.PRO_TPM);
  if (Number.isFinite(all) && all > 0) return Math.floor(all);
  return PACE_DEFAULT_TPM;
}

export function paceEstimateTokens(messages, tools, maxTokens) {
  var chars = 0;
  try { chars += JSON.stringify(messages || []).length; } catch (e) { }
  try { if (tools && tools.length) chars += JSON.stringify(tools).length; } catch (e) { }
  var out = Math.max(0, Math.min(Number(maxTokens) || 0, PACE_OUT_ESTIMATE_CAP));
  return Math.ceil(chars / 4) + out;
}

export function paceUsageTokens(usage) {
  if (!usage) return 0;
  var n = function (v) { var x = Number(v); return Number.isFinite(x) && x > 0 ? x : 0; };
  return n(usage.fresh) + n(usage.wrote) + n(usage.out);
}

function paceRefill(state, now, tpm) {
  var cap = Math.max(1, Number(tpm) || PACE_DEFAULT_TPM);
  var have = state && Number.isFinite(Number(state.tokens)) ? Number(state.tokens) : cap;
  var at = state && Number(state.at) > 0 ? Number(state.at) : now;
  var gained = Math.max(0, now - at) * cap / PACE_WINDOW_MS;
  return { cap: cap, have: Math.min(cap, have + gained) };
}

export function paceBucketTake(state, now, tokens, tpm, maxWait) {
  var r = paceRefill(state, now, tpm);
  var need = Math.min(Math.max(0, Number(tokens) || 0), r.cap);
  var wait = r.have >= need ? 0 : Math.ceil((need - r.have) * PACE_WINDOW_MS / r.cap);
  var ceiling = Math.max(0, Number(maxWait) || 0);
  if (wait > ceiling) wait = ceiling;
  return { state: { tokens: r.have - need, at: now }, waitMs: wait };
}

export function paceBucketSettle(state, now, delta, tpm) {
  var r = paceRefill(state, now, tpm);
  var back = Number(delta) || 0;
  return { tokens: Math.min(r.cap, r.have + back), at: now };
}

function paceHeader(headers, name) {
  if (!headers) return null;
  if (typeof headers.get === "function") {
    var v = headers.get(name);
    return v == null ? null : String(v);
  }
  var want = name.toLowerCase();
  for (var k in headers) {
    if (Object.prototype.hasOwnProperty.call(headers, k) && k.toLowerCase() === want) {
      return headers[k] == null ? null : String(headers[k]);
    }
  }
  return null;
}

export function paceDurationMs(text) {
  var s = String(text || "").trim();
  if (!s) return null;
  if (/^\d+(\.\d+)?$/.test(s)) return Math.round(Number(s) * 1000);
  var re = /(\d+(?:\.\d+)?)(ms|h|m|s)/g;
  var total = 0;
  var seen = 0;
  var m;
  while ((m = re.exec(s))) {
    var n = Number(m[1]);
    seen += m[0].length;
    if (m[2] === "ms") total += n;
    else if (m[2] === "s") total += n * 1000;
    else if (m[2] === "m") total += n * 60000;
    else total += n * 3600000;
  }
  return seen === s.length ? Math.round(total) : null;
}

export function paceRetryAfterMs(headers, now, cap) {
  var limit = Number(cap) > 0 ? Number(cap) : PACE_RETRY_AFTER_CAP_MS;
  var clock = Number(now) || Date.now();
  var clamp = function (ms) {
    if (!Number.isFinite(ms)) return null;
    return Math.max(0, Math.min(limit, Math.round(ms)));
  };
  var ms = paceHeader(headers, "retry-after-ms");
  if (ms != null && /^\d+(\.\d+)?$/.test(ms.trim())) return clamp(Number(ms));
  var after = paceHeader(headers, "retry-after");
  if (after != null) {
    var t = after.trim();
    if (/^\d+(\.\d+)?$/.test(t)) return clamp(Number(t) * 1000);
    var when = Date.parse(t);
    if (Number.isFinite(when)) return clamp(when - clock);
  }
  var best = null;
  var take = function (v) {
    if (v == null || !Number.isFinite(v)) return;
    if (best == null || v > best) best = v;
  };
  ["x-ratelimit-reset-requests", "x-ratelimit-reset-tokens"].forEach(function (h) {
    var v = paceHeader(headers, h);
    if (v != null) take(paceDurationMs(v));
  });
  ["anthropic-ratelimit-requests-reset", "anthropic-ratelimit-tokens-reset",
    "anthropic-ratelimit-input-tokens-reset", "anthropic-ratelimit-output-tokens-reset"].forEach(function (h) {
    var v = paceHeader(headers, h);
    if (v == null) return;
    var at = Date.parse(v);
    if (Number.isFinite(at)) take(at - clock);
  });
  var reset = paceHeader(headers, "x-ratelimit-reset");
  if (reset != null && /^\d+(\.\d+)?$/.test(reset.trim())) {
    var n = Number(reset);
    take(n > 1e9 ? n * 1000 - clock : n * 1000);
  }
  return best == null ? null : clamp(best);
}
