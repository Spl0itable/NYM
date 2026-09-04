// Reads the live model catalog that Nymbot has access to

import { hasD1, replica } from "./_d1.js";

var CATALOG_BINDINGS = ["DB_MODELS", "DB_BOT", "DB_CREDITS", "DB_CHANNELS"];

// Per-isolate memo of which binding actually holds ai_models, so the probe
// runs once rather than on every message.
var catalogBindingName = null;
var catalogBindingChecked = false;

async function resolveCatalogDb(env) {
  if (catalogBindingChecked) {
    return catalogBindingName && hasD1(env[catalogBindingName]) ? env[catalogBindingName] : null;
  }
  for (var i = 0; i < CATALOG_BINDINGS.length; i++) {
    var name = CATALOG_BINDINGS[i];
    var db = env && env[name];
    if (!hasD1(db)) continue;
    try {
      await replica(db).prepare("SELECT 1 FROM ai_models LIMIT 1").first();
      catalogBindingName = name;
      catalogBindingChecked = true;
      return db;
    } catch (e) { /* table not in this database — try the next binding */ }
  }
  catalogBindingChecked = true;
  catalogBindingName = null;
  return null;
}

// A max-length reply costs base + one credit per outTokensPerCredit of output.
// Mirrors the worker's own charge so the number the picker shows is the number
// the user is actually billed.
export function catalogMaxCredits(entry) {
  var base = entry.baseCredits || 1;
  var per = entry.outTokensPerCredit || 0;
  if (!per) return base;
  return base + Math.ceil((entry.maxTokens || 8192) / per);
}

function parseJson(s, fallback) {
  try { return s ? JSON.parse(s) : fallback; } catch (e) { return fallback; }
}

// One-line blurb for the picker. Cloudflare's descriptions run to three
// sentences; a model list of this size only has room for the first.
export function catalogBlurb(text, limit) {
  var s = String(text || "").replace(/\s+/g, " ").trim();
  if (!s) return "";
  var cap = limit || 120;
  var stop = s.search(/\.\s/);
  if (stop > 24 && stop + 1 <= cap) return s.slice(0, stop + 1);
  if (s.length <= cap) return s;
  var cut = s.slice(0, cap);
  var sp = cut.lastIndexOf(" ");
  return (sp > 40 ? cut.slice(0, sp) : cut) + "…";
}

export function catalogTransport(id, requestFormats, stored) {
  var rf = String(requestFormats || "").toLowerCase();
  if (/^@(?:cf|hf)\//.test(id)) return "wai";
  // Anthropic's own models, and only those, may take the gateway's Anthropic
  // provider route — it forwards to Anthropic and demands an x-api-key.
  if (/^anthropic\//.test(id)) return "anthropic";
  // request_formats is a LIST ("Responses, Chat Completions"), so pick the
  // format we serve best rather than the first one that matches. Chat
  // Completions wins wherever it is offered: it is the route the compat
  // endpoint and the binding both speak, and most models list it alongside a
  // second option they support equally.
  if (/chat completions/.test(rf)) return "compat";
  // Anthropic's body shape from a vendor that is not Anthropic (Tinker's
  // inkling): same body, unified endpoint.
  if (/anthropic\s*messages/.test(rf)) return "anthropic-compat";
  // Responses-only. /v1/chat/completions rejects these outright.
  if (/response/.test(rf)) return "responses";
  if (rf) return "compat";
  // No request_formats on the row: fall back to whatever was stored, but
  // never to a provider-specific route we can't justify from the id.
  var st = String(stored || "");
  if (st === "anthropic") return "compat";
  return st || "compat";
}

var CACHE_MS = 5 * 60 * 1000;
var cache = { at: 0, data: null };

// Frontier (third-party) text models, keyed the way ?model expects. Returns
// null when the catalog isn't reachable — the caller falls back.
export async function catalogProModels(env, opts) {
  var now = Date.now();
  if (!(opts && opts.fresh) && cache.data && now - cache.at < CACHE_MS) return cache.data;

  var db = await resolveCatalogDb(env);
  if (!db) return null;

  var rows, overrides = {};
  try {
    var rs = await replica(db).prepare(
      "SELECT id, slug, name, author, author_slug, description, context_window, " +
      "max_output_tokens, transport, request_formats, vision, function_calling, reasoning, " +
      "base_credits, out_tokens_per_credit, credit_basis, hosting " +
      "FROM ai_models WHERE available = 1 AND deprecated = 0 AND beta = 0 " +
      "AND hosting = 'third-party' AND task_slug IN ('text-generation', 'image-text-to-text') " +
      "ORDER BY author_slug, slug"
    ).all();
    rows = rs.results || [];
  } catch (e) { return null; }
  if (!rows.length) return null;

  try {
    var os = await replica(db).prepare("SELECT id, patch FROM ai_model_overrides").all();
    (os.results || []).forEach(function (r) {
      var p = parseJson(r.patch, null);
      if (p && typeof p === "object") overrides[r.id] = p;
    });
  } catch (e) { /* overrides are optional */ }

  var models = {};
  var byModelId = {};
  var used = {};

  rows.forEach(function (r) {
    var patch = overrides[r.id] || {};
    var pc = patch.credits || {};
    // The bare slug is the key; a collision takes the author prefix. Ordered
    // by (author_slug, slug), so the assignment is stable run to run.
    var key = String(r.slug || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
    if (!key) return;
    if (used[key]) key = (r.author_slug || "x") + "-" + key;
    if (used[key]) key = key + "-" + Object.keys(used).length;
    used[key] = true;

    var maxTokens = Math.min(r.max_output_tokens || 8192,
      r.context_window && r.context_window < 8192 ? r.context_window : 8192);
    var entry = {
      label: patch.name || r.name || r.slug,
      transport: patch.transport ||
        catalogTransport(r.id, r.request_formats, r.transport),
      model: r.id,
      baseCredits: pc.base != null ? pc.base : (r.base_credits != null ? r.base_credits : 1),
      outTokensPerCredit: pc.outTokensPerCredit != null ? pc.outTokensPerCredit
        : (r.out_tokens_per_credit != null ? r.out_tokens_per_credit : 0),
      maxTokens: maxTokens > 0 ? maxTokens : 4096,
      vision: patch.vision != null ? !!patch.vision : !!r.vision,
      reasoning: !!r.reasoning,
      tools: !!r.function_calling,
      context: r.context_window || null,
      author: patch.author || r.author || "",
      authorSlug: r.author_slug || "",
      description: catalogBlurb(patch.description || r.description),
      // A model Cloudflare only prices in its dashboard is charged at the
      // conservative default; the apps grey these rather than hide them.
      priced: (pc.basis || r.credit_basis) !== "default"
    };
    entry.max = catalogMaxCredits(entry);
    models[key] = entry;
    byModelId[r.id] = key;
  });

  cache = { at: now, data: { models: models, byModelId: byModelId, count: rows.length } };
  return cache.data;
}

// Family alias -> newest member, e.g. "claude-opus" -> "claude-opus-5", so a
// key a user pinned before a version bump keeps working.
function familyOf(key) {
  var parts = String(key || "").split("-").filter(Boolean);
  var kept = parts.filter(function (p) {
    return !/^v?[0-9]+$/.test(p) && !/^k[0-9]+$/.test(p);
  });
  return kept.length ? kept.join("-") : String(key || "");
}

function versionScore(key) {
  var nums = String(key || "").match(/[0-9]+/g) || [];
  return nums.reduce(function (acc, n, i) { return acc + parseInt(n, 10) / Math.pow(1000, i); }, 0);
}

// Newest first, by version
export function catalogSortKeys(models, keys) {
  var list = (keys || Object.keys(models)).slice();
  var meta = {};
  list.forEach(function (k) { meta[k] = { fam: familyOf(k), v: versionScore(k) }; });
  list.sort(function (a, b) {
    var ma = meta[a], mb = meta[b];
    if (mb.v !== ma.v) return mb.v - ma.v;
    if (ma.fam !== mb.fam) return ma.fam < mb.fam ? -1 : 1;
    return a < b ? -1 : 1;
  });
  return list;
}

export function catalogAliases(models) {
  var aliases = {};
  var families = {};
  var byAuthor = {};
  Object.keys(models).forEach(function (key) {
    var fam = familyOf(key);
    if (!families[fam] || versionScore(key) > versionScore(families[fam])) families[fam] = key;
    var a = models[key].authorSlug;
    if (a) (byAuthor[a] = byAuthor[a] || []).push(key);
  });
  Object.keys(families).forEach(function (fam) {
    if (fam && fam !== families[fam] && !models[fam]) aliases[fam] = families[fam];
  });
  Object.keys(byAuthor).forEach(function (a) {
    if (byAuthor[a].length === 1 && !models[a] && !aliases[a]) aliases[a] = byAuthor[a][0];
  });
  return aliases;
}
