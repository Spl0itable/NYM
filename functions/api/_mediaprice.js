export const MEDIA_USD = {
  "google/nano-banana-pro": { perImage: 0.15, perInputImage: 0.002, basis: "Cloudflare: $120 per 1M output tokens, about 1,120 tokens for a 1K image, plus $2 per 1M input tokens" },
  "google/nano-banana-2": { perImage: 0.07, perInputImage: 0.001, basis: "Cloudflare: $60 per 1M output tokens, about 1,120 tokens for a 1K image, plus $0.50 per 1M input tokens" },
  "black-forest-labs/flux-2-max": { perImage: 0.075, perInputImage: 0.06, basis: "Cloudflare: $0.07 first output megapixel, $0.03 each further one, $0.03 per input megapixel" },
  "black-forest-labs/flux-2-pro-preview": { perImage: 0.035, perInputImage: 0.03, basis: "Cloudflare: $0.03 first output megapixel, $0.015 each further one, $0.015 per input megapixel" },
  "bytedance/seedream-5-pro": { perImage: 0.045, perInputImage: 0.03, basis: "Cloudflare: $0.045 per image, $0.03 per input image" },
  "openai/gpt-image-2": { perImage: 0.22, perInputImage: 0.02, basis: "Cloudflare: $30 per 1M output image tokens; a high-quality 1024x1024 image is about $0.21, an edit about $0.22" },
  "xai/grok-imagine-image": { perImage: 0.02, perInputImage: 0.002, basis: "Cloudflare: $0.02 per image, $0.002 per input image" },
  "recraft/recraftv4-pro": { perImage: 0.25, basis: "Cloudflare: $0.25 per image" },
  "google/veo-3.1": { seconds: 8, field: "resolution", tiers: [["720p", "720p", 0.40], ["1080p", "1080p", 0.40]], basis: "Cloudflare: $0.40 per second with audio at 720p and at 1080p" },
  "google/veo-3.1-fast": { seconds: 8, field: "resolution", tiers: [["720p", "720p", 0.10], ["1080p", "1080p", 0.12]], basis: "Cloudflare: $0.10 per second with audio at 720p, $0.12 at 1080p" },
  "bytedance/seedance-2.5": { seconds: 8, field: "resolution", tiers: [["720p", "720p", 0.473]], basis: "Not listed on Cloudflare; $0.473 per second at 720p is the fal.ai list price, used as a conservative figure" },
  "bytedance/seedance-2.0-fast": { seconds: 8, field: "resolution", tiers: [["480p", "480p", 0.06], ["720p", "720p", 0.12]], basis: "Cloudflare: $0.06 per second at 480p, $0.12 at 720p, without video input" },
  "bytedance/seedance-2.0-mini": { seconds: 8, field: "resolution", tiers: [["480p", "480p", 0.04], ["720p", "720p", 0.09]], basis: "Cloudflare: $0.04 per second at 480p, $0.09 at 720p, without video input" },
  "minimax/hailuo-2.3": { seconds: 6, field: "resolution", tiers: [["768p", "768P", 0.28 / 6], ["1080p", "1080P", 0.49 / 6]], basis: "Cloudflare: $0.28 for 6 seconds at 768p, $0.49 at 1080p" },
  "minimax/hailuo-2.3-fast": { seconds: 6, field: "resolution", tiers: [["768p", "768P", 0.19 / 6], ["1080p", "1080P", 0.33 / 6]], basis: "Cloudflare: $0.19 for 6 seconds at 768p, $0.33 at 1080p" },
  "alibaba/wan-3.0": { seconds: 5, field: "resolution", tiers: [["480p", "480P", 0.05], ["720p", "720P", 0.10], ["1080p", "1080P", 0.20]], basis: "Cloudflare: $0.05 per second at 480P, $0.10 at 720P, $0.20 at 1080P" },
  "alibaba/hh1.1-t2v": { seconds: 5, field: "resolution", tiers: [["720p", "720P", 0.14], ["1080p", "1080P", 0.18]], basis: "Cloudflare: $0.14 per second at 720P, $0.18 at 1080P" },
  "xai/grok-imagine-video": { seconds: 5, field: "resolution", tiers: [["480p", "480p", 0.05], ["720p", "720p", 0.07]], basis: "Cloudflare: $0.05 per second at 480p, $0.07 at 720p" },
  "pixverse/v6": { seconds: 6, field: "quality", tiers: [["360p", "360p", 0.035], ["540p", "540p", 0.045], ["720p", "720p", 0.06], ["1080p", "1080p", 0.115]], basis: "Cloudflare, with audio: $0.035 per second at 360p, $0.045 at 540p, $0.06 at 720p, $0.115 at 1080p" },
  "lightricks/ltx-2-5-fast": { seconds: 5, field: "resolution", tiers: [["720p", "1280x720", 0.09], ["1080p", "1920x1080", 0.15], ["1440p", "2560x1440", 0.19], ["4K", "3840x2160", 0.37]], basis: "Cloudflare: $0.09 per second at 720p, $0.15 at 1080p, $0.19 at 2k, $0.37 at 4k" },
  "vidu/q3-turbo": { seconds: 6, field: "resolution", tiers: [["540p", "540p", 0.04], ["720p", "720p", 0.06], ["1080p", "1080p", 0.07]], basis: "Cloudflare: $0.04 per second at 540p, $0.06 at 720p, $0.07 at 1080p" },
  "black-forest-labs/flux-3-video": { seconds: 5, field: "resolution", tiers: [["720p", "hd", 0.17], ["1080p", "fhd", 0.29]], basis: "Cloudflare lists hd at $0.17 and fhd at $0.29 without a unit; charged per second, the conservative reading" },
  "runwayml/gen-4.5": { seconds: 5, field: "ratio", tiers: [["720p", "1280:720", 0.12]], basis: "Cloudflare: $0.12 per second" },
  "@cf/deepgram/aura-2-en": { perKChar: 0.030, basis: "Workers AI: $0.030 per 1k characters" },
  "@cf/myshell-ai/melotts": { perKChar: 0.0005, basis: "Workers AI: $0.0002 per audio minute; about a minute per 1k characters, rounded up" },
  "@cf/openai/whisper-large-v3-turbo": { perMinute: 0.0005, basis: "Workers AI: $0.0005 per audio minute" }
};

export const MEDIA_USD_FALLBACK = {
  image: { perImage: 0.25, perInputImage: 0.03, basis: "No verified price; the dearest image rate in the table" },
  video: { perSecond: 0.60, seconds: 10, basis: "No verified price; Veo 3.1 at 4k with audio, the dearest per-second rate in the table" },
  speech: { perKChar: 0.030, basis: "No verified price; the Aura 2 rate" }
};

function pos(v) {
  var n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

export function mediaResHeight(v) {
  var t = String(v == null ? "" : v).trim().toLowerCase();
  if (!t) return 0;
  if (t === "4k" || t === "uhd") return 2160;
  if (t === "2k" || t === "qhd") return 1440;
  if (t === "fhd") return 1080;
  if (t === "hd") return 720;
  var wh = /^(\d{3,4})\s*[x:*]\s*(\d{3,4})$/.exec(t);
  if (wh) return Math.min(Number(wh[1]), Number(wh[2]));
  var p = /^(\d{3,4})\s*p?$/.exec(t);
  return p ? Number(p[1]) : 0;
}

export function mediaTiers(model) {
  var own = MEDIA_USD[String((model && model.model) || "")];
  if (!own || !Array.isArray(own.tiers)) return [];
  return own.tiers.map(function (t) {
    return { res: t[0], value: t[1], perSecond: t[2], height: mediaResHeight(t[0]) };
  });
}

export function mediaTier(model, want) {
  var tiers = mediaTiers(model);
  if (!tiers.length) return null;
  if (want == null || want === "") return tiers[tiers.length - 1];
  var h = mediaResHeight(want);
  for (var i = 0; i < tiers.length; i++) {
    if (h && tiers[i].height === h) return tiers[i];
    if (String(tiers[i].value).toLowerCase() === String(want).trim().toLowerCase()) return tiers[i];
  }
  return null;
}

function tierOfBody(model, own, body) {
  var tiers = mediaTiers(model);
  if (!tiers.length) return null;
  var sent = body && own.field ? body[own.field] : null;
  if (sent != null) {
    for (var i = 0; i < tiers.length; i++) {
      if (String(tiers[i].value).toLowerCase() === String(sent).toLowerCase()) return tiers[i];
    }
  }
  return tiers.reduce(function (a, b) { return b.perSecond > a.perSecond ? b : a; });
}

export function mediaRate(kind, model, opts) {
  var id = String((model && model.model) || "");
  var own = MEDIA_USD[id];
  if (own && Array.isArray(own.tiers)) {
    var o = opts || {};
    var tier = o.res ? mediaTier(model, o.res) : null;
    if (!tier) tier = o.body ? tierOfBody(model, own, o.body) : mediaTier(model, "");
    return { verified: true, perSecond: tier.perSecond, seconds: own.seconds, res: tier.res, field: own.field, value: tier.value, basis: own.basis };
  }
  if (own) return Object.assign({ verified: true }, own);
  var live = model && model.usd;
  if (live && kind === "image" && pos(live.perImage)) {
    return { perImage: pos(live.perImage), perInputImage: pos(live.perInputImage) || MEDIA_USD_FALLBACK.image.perInputImage, verified: true, basis: "catalog" };
  }
  if (live && kind === "video" && pos(live.perSecond)) {
    return { perSecond: pos(live.perSecond), seconds: MEDIA_USD_FALLBACK.video.seconds, verified: true, basis: "catalog" };
  }
  return Object.assign({ verified: false }, MEDIA_USD_FALLBACK[kind === "speak" ? "speech" : kind] || MEDIA_USD_FALLBACK.image);
}

export function mediaSeconds(body, rate) {
  var d = body ? (body.duration != null ? body.duration : body.duration_seconds) : null;
  var n = typeof d === "string" ? parseFloat(d) : Number(d);
  if (Number.isFinite(n) && n > 0) return Math.ceil(n);
  return pos(rate && rate.seconds) || MEDIA_USD_FALLBACK.video.seconds;
}

export function mediaUsd(kind, model, o) {
  var opts = o || {};
  var rate = mediaRate(kind, model, opts);
  if (kind === "video") {
    var secs = opts.seconds > 0 ? opts.seconds : mediaSeconds(opts.body, rate);
    return { usd: rate.perSecond * secs, seconds: secs, rate: rate };
  }
  if (kind === "speak" || kind === "speech") {
    var chars = Math.max(1, Math.floor(Number(opts.chars) || 0));
    return { usd: rate.perKChar * chars / 1000, chars: chars, rate: rate };
  }
  var refs = Math.max(0, Math.floor(Number(opts.refs) || 0));
  return { usd: rate.perImage + pos(rate.perInputImage) * refs, refs: refs, rate: rate };
}

export function transcribeUsd(seconds) {
  var rate = MEDIA_USD["@cf/openai/whisper-large-v3-turbo"];
  return Math.max(0, Number(seconds) || 0) / 60 * rate.perMinute;
}
