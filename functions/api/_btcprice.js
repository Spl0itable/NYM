import { hasD1 } from "./_d1.js";

export const BTC_PRICE_MIN_USD = 1000;
export const BTC_PRICE_MAX_USD = 10000000;
export const BTC_PRICE_REFRESH_MS = 5 * 60 * 1000;
export const BTC_PRICE_MAX_AGE_MS = 2 * 60 * 60 * 1000;
export const BTC_PRICE_TIMEOUT_MS = 2500;
export const BTC_PRICE_RETRY_MS = 30 * 1000;
export const BTC_PRICE_FAIL_RETRY_MS = 10 * 1000;
export const BTC_PRICE_OUTLIER = 0.05;
export const BTC_PRICE_SOLO_DRIFT = 0.2;
export const BTC_PRICE_CACHE_KEY = "https://nymbot.internal/btc-price/v1";

function krakenLast(j) {
  var r = j && j.result;
  if (!r || typeof r !== "object") return null;
  var keys = Object.keys(r);
  for (var i = 0; i < keys.length; i++) {
    var c = r[keys[i]] && r[keys[i]].c;
    if (Array.isArray(c) && c.length) return c[0];
  }
  return null;
}

export const BTC_PRICE_SOURCES = [
  { name: "mempool", url: "https://mempool.space/api/v1/prices", read: function (j) { return j && j.USD; } },
  { name: "coinbase", url: "https://api.coinbase.com/v2/prices/BTC-USD/spot", read: function (j) { return j && j.data && j.data.amount; } },
  { name: "kraken", url: "https://api.kraken.com/0/public/Ticker?pair=XBTUSD", read: krakenLast },
  { name: "bitstamp", url: "https://www.bitstamp.net/api/v2/ticker/btcusd/", read: function (j) { return j && j.last; } },
  { name: "coingecko", url: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd", read: function (j) { return j && j.bitcoin && j.bitcoin.usd; } }
];

export class BtcPriceUnavailable extends Error {
  constructor(message) {
    super(message || "The Bitcoin price could not be checked right now, so nothing that is priced in dollars can be charged. Nothing was charged. Please try again in a minute.");
    this.name = "BtcPriceUnavailable";
    this.code = "price_unavailable";
    this.retryable = true;
  }
}

export function btcPriceSane(v) {
  var n = typeof v === "string" ? Number(v.trim()) : Number(v);
  return Number.isFinite(n) && n >= BTC_PRICE_MIN_USD && n <= BTC_PRICE_MAX_USD ? n : null;
}

function median(list) {
  var s = list.slice().sort(function (a, b) { return a - b; });
  var mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

export function btcPriceConsensus(values, anchor) {
  var ok = [];
  (values || []).forEach(function (v) {
    var n = btcPriceSane(v);
    if (n != null) ok.push(n);
  });
  if (!ok.length) return null;
  if (ok.length === 1) {
    var near = btcPriceSane(anchor);
    if (near != null && Math.abs(ok[0] - near) / near > BTC_PRICE_SOLO_DRIFT) return null;
    return { usd: ok[0], used: 1, of: 1 };
  }
  var mid = median(ok);
  var kept = ok.filter(function (v) { return Math.abs(v - mid) / mid <= BTC_PRICE_OUTLIER; });
  if (kept.length * 2 <= ok.length) return null;
  return { usd: median(kept), used: kept.length, of: ok.length };
}

async function readSource(src, fetcher, timeoutMs) {
  var ctl = typeof AbortController === "function" ? new AbortController() : null;
  var timer = null;
  try {
    var timeout = new Promise(function (_, reject) {
      timer = setTimeout(function () {
        if (ctl) { try { ctl.abort(); } catch (e) { } }
        reject(new Error("timeout"));
      }, timeoutMs);
    });
    var res = await Promise.race([
      fetcher(src.url, { headers: { "Accept": "application/json", "User-Agent": "nymbot-price/1.0" }, signal: ctl ? ctl.signal : undefined }),
      timeout
    ]);
    if (!res || !res.ok) return null;
    var body = await Promise.race([res.json(), timeout]);
    return btcPriceSane(src.read(body));
  } catch (e) {
    return null;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export async function btcPriceFetch(opts) {
  var o = opts || {};
  var fetcher = o.fetch || (typeof fetch === "function" ? fetch : null);
  if (!fetcher) return null;
  var sources = o.sources || BTC_PRICE_SOURCES;
  var timeoutMs = Number(o.timeoutMs) > 0 ? Number(o.timeoutMs) : BTC_PRICE_TIMEOUT_MS;
  var got = await Promise.all(sources.map(function (s) { return readSource(s, fetcher, timeoutMs); }));
  var names = [];
  var values = [];
  got.forEach(function (v, i) {
    if (v != null) { values.push(v); names.push(sources[i].name); }
  });
  var agreed = btcPriceConsensus(values, o.anchor);
  if (!agreed) return null;
  return { usd: agreed.usd, sources: names, used: agreed.used, of: agreed.of };
}

var memory = { usd: 0, at: 0, sources: [] };
var lastTry = 0;
var inflight = null;

export function btcPriceReset() {
  memory = { usd: 0, at: 0, sources: [] };
  lastTry = 0;
  inflight = null;
}

export function btcPriceKnown() {
  return memory.usd > 0 ? { usd: memory.usd, at: memory.at, sources: memory.sources.slice() } : null;
}

function cacheStore(o) {
  if (o && o.cache !== undefined) return o.cache;
  try {
    if (typeof caches !== "undefined" && caches && caches.default) return caches.default;
  } catch (e) { }
  return null;
}

function nowOf(o) {
  return o && typeof o.now === "function" ? o.now() : Date.now();
}

function adopt(rec) {
  var usd = btcPriceSane(rec && rec.usd);
  var at = Number(rec && rec.at);
  if (usd == null || !Number.isFinite(at) || at <= 0) return false;
  if (at <= memory.at) return false;
  memory = { usd: usd, at: at, sources: Array.isArray(rec.sources) ? rec.sources.slice(0, 8) : [] };
  return true;
}

async function ensureTable(db) {
  await db.prepare("CREATE TABLE IF NOT EXISTS bot_price (id TEXT PRIMARY KEY, usd REAL NOT NULL, at INTEGER NOT NULL, sources TEXT)").run();
}

async function readStored(env, o) {
  var cache = cacheStore(o);
  if (cache) {
    try {
      var hit = await cache.match(BTC_PRICE_CACHE_KEY);
      if (hit) adopt(await hit.json());
    } catch (e) { }
  }
  var db = env && env.DB_BOT;
  if (hasD1(db)) {
    try {
      var row = await db.prepare("SELECT usd, at, sources FROM bot_price WHERE id = ?").bind("BTCUSD").first();
      if (row) {
        var src = [];
        try { src = JSON.parse(row.sources || "[]"); } catch (e) { src = []; }
        adopt({ usd: row.usd, at: row.at, sources: src });
      }
    } catch (e) { }
  }
}

async function writeStored(env, o, rec) {
  var cache = cacheStore(o);
  if (cache) {
    try {
      await cache.put(BTC_PRICE_CACHE_KEY, new Response(JSON.stringify(rec), {
        headers: { "Content-Type": "application/json", "Cache-Control": "max-age=" + Math.floor(BTC_PRICE_MAX_AGE_MS / 1000) }
      }));
    } catch (e) { }
  }
  var db = env && env.DB_BOT;
  if (hasD1(db)) {
    var put = function () {
      return db.prepare("INSERT INTO bot_price (id, usd, at, sources) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET usd = excluded.usd, at = excluded.at, sources = excluded.sources WHERE excluded.at > bot_price.at")
        .bind("BTCUSD", rec.usd, rec.at, JSON.stringify(rec.sources || [])).run();
    };
    try {
      await put();
    } catch (e) {
      try { await ensureTable(db); await put(); } catch (e2) { }
    }
  }
}

async function refresh(env, o, now) {
  lastTry = now;
  var got = await btcPriceFetch({ fetch: o.fetch, anchor: memory.usd > 0 && now - memory.at < BTC_PRICE_MAX_AGE_MS ? memory.usd : 0, timeoutMs: o.timeoutMs, sources: o.sources });
  if (!got) return false;
  var rec = { usd: got.usd, at: now, sources: got.sources };
  adopt(rec);
  await writeStored(env, o, rec);
  return true;
}

export async function btcPriceGet(env, opts) {
  var o = opts || {};
  var now = nowOf(o);
  var maxAge = Number(o.maxAgeMs) > 0 ? Number(o.maxAgeMs) : BTC_PRICE_MAX_AGE_MS;
  if (!(memory.usd > 0) || now - memory.at >= BTC_PRICE_REFRESH_MS) await readStored(env, o);
  if (!(memory.usd > 0) || now - memory.at >= BTC_PRICE_REFRESH_MS) {
    var usable = memory.usd > 0 && now - memory.at < maxAge;
    var wait = usable ? BTC_PRICE_RETRY_MS : BTC_PRICE_FAIL_RETRY_MS;
    if (lastTry === 0 || now - lastTry >= wait || now < lastTry) {
      if (!inflight) {
        inflight = refresh(env, o, now).finally(function () { inflight = null; });
      }
      try { await inflight; } catch (e) { }
    }
  }
  if (memory.usd > 0 && now - memory.at < maxAge) {
    return { usd: memory.usd, at: memory.at, ageMs: Math.max(0, now - memory.at), sources: memory.sources.slice() };
  }
  throw new BtcPriceUnavailable();
}
