import { hasD1, replica } from "./_d1.js";

var CATALOG_BINDINGS = ["DB_MODELS", "DB_BOT", "DB_CREDITS", "DB_CHANNELS"];

// Per-isolate memo of which binding holds ai_models, so the probe runs once.
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
    } catch (e) {}
  }
  catalogBindingChecked = true;
  catalogBindingName = null;
  return null;
}

// Mirrors the worker's charge (base + one credit per outTokensPerCredit) so the picker shows the billed price.
export function catalogMaxCredits(entry) {
  var base = entry.baseCredits || 1;
  var per = entry.outTokensPerCredit || 0;
  if (!per) return base;
  return base + Math.ceil((entry.maxTokens || 8192) / per);
}

function parseJson(s, fallback) {
  try { return s ? JSON.parse(s) : fallback; } catch (e) { return fallback; }
}

// Cloudflare's descriptions run to three sentences; the picker has room for the first.
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
  // Only Anthropic's own models may use the gateway's Anthropic route; it demands an x-api-key.
  if (/^anthropic\//.test(id)) return "anthropic";
  // request_formats is a list; prefer Chat Completions, which both the compat endpoint and the binding speak.
  if (/chat completions/.test(rf)) return "compat";
  // Anthropic body shape from a non-Anthropic vendor: same body, unified endpoint.
  if (/anthropic\s*messages/.test(rf)) return "anthropic-compat";
  // Responses-only; /v1/chat/completions rejects these.
  if (/response/.test(rf)) return "responses";
  if (rf) return "compat";
  // No request_formats: use the stored value, but never a provider-specific route not justified by the id.
  var st = String(stored || "");
  if (st === "anthropic") return "compat";
  return st || "compat";
}

export function catalogMaxTokensField(paramsJson, id) {
  var p = parseJson(paramsJson, null);
  if (p && typeof p === "object") {
    if (p.max_completion_tokens) return "max_completion_tokens";
    if (p.max_tokens) return "max_tokens";
  }
  // Nothing declared: OpenAI's newer models reject max_tokens, everyone else still takes it.
  return /^openai\//.test(String(id || "")) ? "max_completion_tokens" : "max_tokens";
}

// Recomputed on read so rows predating the column still answer; mirrors apiPathFor() in the catalog worker.
export function catalogApiPath(transport) {
  if (transport === "responses") return "responses";
  if (transport === "anthropic" || transport === "anthropic-compat") return "messages";
  return "chat/completions";
}

var CACHE_MS = 5 * 60 * 1000;
var cache = { at: 0, data: null };

// Returns null when the catalog isn't reachable so the caller falls back.
function catalogRate(override, stored) {
  var pick = override != null ? override : stored;
  var n = Number(pick);
  return Number.isFinite(n) && n > 0 ? n : null;
}

export async function catalogProModels(env, opts) {
  var now = Date.now();
  if (!(opts && opts.fresh) && cache.data && now - cache.at < CACHE_MS) return cache.data;

  var db = await resolveCatalogDb(env);
  if (!db) return null;

  var rows, overrides = {};
  try {
    var rs = await replica(db).prepare(
      "SELECT * FROM ai_models WHERE available = 1 AND deprecated = 0 AND beta = 0 " +
      "AND hosting IN ('third-party', 'cloudflare-hosted') " +
      "AND task_slug IN ('text-generation', 'image-text-to-text') " +
      "ORDER BY (hosting = 'third-party') DESC, author_slug, slug"
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
  } catch (e) {}

  var models = {};
  var byModelId = {};
  var redirects = {};
  var hiddenIds = {};
  var used = {};
  rows.forEach(function (r) {
    var patch = overrides[r.id] || {};
    var pc = patch.credits || {};
    var transport = patch.transport ||
      catalogTransport(r.id, r.request_formats, r.transport);
    var key = String(r.slug || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
    if (!key) return;
    if (used[key]) {
      key = (r.hosting === "cloudflare-hosted" ? "cf" : (r.author_slug || "x")) + "-" + key;
    }
    if (used[key]) key = key + "-" + Object.keys(used).length;
    used[key] = true;

    if (patch.hidden || patch.available === false) {
      if (patch.replacedBy) {
        redirects[key] = String(patch.replacedBy);
        hiddenIds[r.id] = key;
      }
      return;
    }

    var maxTokens = Math.min(r.max_output_tokens || 8192,
      r.context_window && r.context_window < 8192 ? r.context_window : 8192);
    var entry = {
      label: patch.name || r.name || r.slug,
      transport: transport,
      model: r.id,
      baseCredits: pc.base != null ? pc.base : (r.base_credits != null ? r.base_credits : 1),
      inUsdPerMTok: catalogRate(pc.inUsdPerMTok, r.price_in_usd_mtok),
      outUsdPerMTok: catalogRate(pc.outUsdPerMTok, r.price_out_usd_mtok),
      cacheReadUsdPerMTok: catalogRate(pc.cacheReadUsdPerMTok, r.price_cache_read_usd_mtok),
      cacheWriteUsdPerMTok: catalogRate(pc.cacheWriteUsdPerMTok, r.price_cache_write_usd_mtok),
      outTokensPerCredit: pc.outTokensPerCredit != null ? pc.outTokensPerCredit
        : (r.out_tokens_per_credit != null ? r.out_tokens_per_credit : 0),
      maxTokens: maxTokens > 0 ? maxTokens : 4096,
      vision: patch.vision != null ? !!patch.vision : !!r.vision,
      visionPinned: patch.vision != null,
      reasoning: !!r.reasoning,
      tools: !!r.function_calling,
      context: r.context_window || null,
      author: patch.author || r.author || "",
      authorSlug: r.author_slug || "",
      hosting: r.hosting || "",
      description: catalogBlurb(patch.description || r.description),
      // The output-cap field this model's docs declare; the provider prefix is not a reliable guide.
      maxTokensField: catalogMaxTokensField(r.params, r.id),
      // Per-model request path under whichever base URL the worker picks.
      apiPath: r.api_path || catalogApiPath(transport),
      params: parseJson(r.params, null),
      // Dashboard-only-priced models are charged the conservative default; apps gray them rather than hide them.
      priced: (pc.basis || r.credit_basis) !== "default"
    };
    entry.max = catalogMaxCredits(entry);
    models[key] = entry;
    byModelId[r.id] = key;
  });

  // Redirects naming a model id resolve once every key is known; unresolvable ones are dropped.
  Object.keys(redirects).forEach(function (k) {
    var target = redirects[k];
    if (models[target]) return;
    if (byModelId[target] && models[byModelId[target]]) { redirects[k] = byModelId[target]; return; }
    delete redirects[k];
  });
  // A pin written as the hidden model's full id lands on the replacement too.
  Object.keys(hiddenIds).forEach(function (id) {
    var to = redirects[hiddenIds[id]];
    if (to && models[to] && !byModelId[id]) byModelId[id] = to;
  });

  cache = { at: now, data: { models: models, byModelId: byModelId, redirects: redirects, count: rows.length } };
  return cache.data;
}

function isSizeToken(part) {
  return /^(?:a?[0-9]+(?:x[0-9]+)?b|[0-9]+x[0-9]+|fp[0-9]+|bf[0-9]+|int[0-9]+|[0-9]+[ke])$/
    .test(part);
}

function slugParts(key) {
  return String(key || "").split("-").filter(function (p) {
    return p && !isSizeToken(p);
  });
}

// Family alias -> newest member so keys pinned before a version bump keep working.
function familyOf(key) {
  var kept = slugParts(key).filter(function (p) {
    return !/^v?[0-9]+$/.test(p) && !/^k[0-9]+$/.test(p);
  });
  return kept.length ? kept.join("-") : String(key || "");
}

function versionScore(key) {
  var nums = slugParts(key).join("-").match(/[0-9]+/g) || [];
  return nums.reduce(function (acc, n, i) { return acc + parseInt(n, 10) / Math.pow(1000, i); }, 0);
}

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

export function catalogAliases(models, redirects) {
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
  // An explicit overrides-table replacedBy outranks aliases derived from key names.
  Object.keys(redirects || {}).forEach(function (k) {
    if (models[redirects[k]] && !models[k]) aliases[k] = redirects[k];
  });
  return aliases;
}

var MEDIA_TASKS = [
  "text-to-image", "image-to-image", "text-to-video", "image-to-video",
  "text-to-speech", "text-to-audio"
];

var mediaCache = { at: 0, data: null };

export async function catalogMediaParams(env, opts) {
  var now = Date.now();
  if (!(opts && opts.fresh) && mediaCache.data && now - mediaCache.at < CACHE_MS) {
    return mediaCache.data;
  }
  var db = await resolveCatalogDb(env);
  if (!db) return null;
  var rows;
  try {
    var rs = await replica(db).prepare(
      "SELECT * FROM ai_models WHERE available = 1 AND deprecated = 0 " +
      "AND task_slug IN (" + MEDIA_TASKS.map(function () { return "?"; }).join(", ") + ")"
    ).bind(...MEDIA_TASKS).all();
    rows = rs.results || [];
  } catch (e) { return null; }
  if (!rows.length) return null;

  var byModelId = {};
  rows.forEach(function (r) {
    var params = parseJson(r.params, null);
    if (!params || typeof params !== "object") return;
    byModelId[r.id] = {
      params: params,
      task: r.task || "",
      taskSlug: r.task_slug || "",
      docUrl: r.doc_url || ""
    };
  });
  if (!Object.keys(byModelId).length) return null;
  var out = { byModelId: byModelId, count: Object.keys(byModelId).length };
  mediaCache = { at: now, data: out };
  return out;
}

var GENERATOR_TASKS = {
  "text-to-image": "image",
  "text-to-video": "video",
  "image-to-video": "video"
};

var GENERATOR_FAMILIES = {
  video: {
    google: "veo", bytedance: "seedance", minimax: "hailuo", alibaba: "wan",
    xai: "grok", pixverse: "pixverse", lightricks: "ltx", vidu: "vidu",
    "black-forest-labs": "bfl", runwayml: "runway"
  },
  image: { google: "google", "black-forest-labs": "bfl" }
};

export function catalogGeneratorFamily(kind, modelId) {
  var id = String(modelId || "").toLowerCase();
  var vendor = id.split("/")[0];
  var slug = id.split("/").pop();
  if (kind === "video" && vendor === "alibaba" && /^hh/.test(slug)) return "hh";
  var table = GENERATOR_FAMILIES[kind] || {};
  if (table[vendor]) return table[vendor];
  return kind === "image" ? "openai" : "";
}

function generatorKey(slug) {
  return String(slug || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

var generatorCache = { at: 0, data: null };

export async function catalogGenerators(env, opts) {
  var now = Date.now();
  if (!(opts && opts.fresh) && generatorCache.data && now - generatorCache.at < CACHE_MS) {
    return generatorCache.data;
  }
  var db = await resolveCatalogDb(env);
  if (!db) return null;
  var tasks = Object.keys(GENERATOR_TASKS);
  var rows, overrides = {};
  try {
    var rs = await replica(db).prepare(
      "SELECT * FROM ai_models WHERE available = 1 AND deprecated = 0 AND beta = 0 " +
      "AND hosting = 'third-party' AND task_slug IN (" +
      tasks.map(function () { return "?"; }).join(", ") + ") ORDER BY author_slug, slug"
    ).bind(...tasks).all();
    rows = rs.results || [];
  } catch (e) { return null; }
  if (!rows.length) return null;
  try {
    var os = await replica(db).prepare("SELECT id, patch FROM ai_model_overrides").all();
    (os.results || []).forEach(function (r) {
      var p = parseJson(r.patch, null);
      if (p && typeof p === "object") overrides[r.id] = p;
    });
  } catch (e) { }

  var out = { image: {}, video: {} };
  rows.forEach(function (r) {
    var kind = GENERATOR_TASKS[r.task_slug];
    if (!kind) return;
    var patch = overrides[r.id] || {};
    if (patch.hidden || patch.available === false) return;
    var key = generatorKey(r.slug);
    if (!key) return;
    var vendor = String(r.id || "").split("/")[0].toLowerCase();
    if (out[kind][key]) key = (r.author_slug || vendor || "x") + "-" + key;
    if (out[kind][key]) key = key + "-" + Object.keys(out[kind]).length;
    var pc = patch.credits || {};
    var basis = pc.basis || r.credit_basis || "";
    var priced = pc.media != null || (basis !== "" && basis !== "default" && basis !== "unknown");
    var credits = pc.media != null ? Number(pc.media)
      : (priced && r.media_credits > 0 ? Number(r.media_credits) : null);
    out[kind][key] = {
      label: patch.name || r.name || r.slug,
      model: r.id,
      family: patch.family || catalogGeneratorFamily(kind, r.id),
      credits: Number.isFinite(credits) && credits > 0 ? Math.ceil(credits) : null,
      priced: !!(priced && credits > 0),
      needsImage: r.task_slug === "image-to-video",
      taskSlug: r.task_slug || "",
      author: patch.author || r.author || "",
      authorSlug: r.author_slug || vendor,
      description: catalogBlurb(patch.description || r.description),
      source: "catalog"
    };
  });
  if (!Object.keys(out.image).length && !Object.keys(out.video).length) return null;
  generatorCache = { at: now, data: out };
  return out;
}

export function catalogMergeGenerators(builtin, live, defaults) {
  var out = {};
  ["image", "video"].forEach(function (kind) {
    var table = {};
    var byModel = {};
    var stat = (builtin && builtin[kind]) || {};
    Object.keys(stat).forEach(function (k) {
      table[k] = Object.assign({ priced: true, source: "builtin" }, stat[k]);
      byModel[stat[k].model] = k;
    });
    var fallback = (defaults && defaults[kind]) || 1;
    var add = (live && live[kind]) || {};
    Object.keys(add).forEach(function (k) {
      var m = add[k];
      if (!m || !m.model) return;
      var held = byModel[m.model] ? table[byModel[m.model]] : null;
      if (held) {
        if (!held.description && m.description) held.description = m.description;
        if (held.needsImage == null && m.needsImage != null) held.needsImage = m.needsImage;
        if (!held.author && m.author) held.author = m.author;
        return;
      }
      var key = k;
      if (table[key]) key = (m.authorSlug ? m.authorSlug + "-" : "x-") + k;
      if (table[key]) key = key + "-" + Object.keys(table).length;
      var priced = !!(m.priced && m.credits > 0);
      table[key] = Object.assign({}, m, {
        credits: priced ? Math.max(1, Math.ceil(m.credits)) : fallback,
        priced: priced
      });
    });
    out[kind] = table;
  });
  return out;
}
