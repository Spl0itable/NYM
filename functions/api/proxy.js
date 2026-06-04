// Cloudflare Pages Function: HTTP proxy for privacy-preserving fetches
// Routes media, translation requests, and URL unfurling through Cloudflare
// so the user's real IP is never exposed to third-party services.
//
// Endpoints:
//   GET  /api/proxy?url=<encoded-url>            — Proxy any allowed media/resource
//   POST /api/proxy?action=translate             — Translate text
//   GET  /api/proxy?action=unfurl&url=<url>      — Fetch Open Graph metadata for URL preview
//   PUT  /api/proxy?action=upload&server=<host>  — Upload a blob to a Blossom host (Nostr auth header)
//   PUT  /api/proxy?action=mirror&server=<host>  — Ask a Blossom host to mirror a blob from a source URL
//   GET  /api/proxy?action=geo-relays            — Fetch bitchat geo-relay CSV (edge-cached)
//   GET/POST /api/proxy?action=json&url=<url>    — Proxy a JSON request (LNURL, Nominatim, etc.)

const ALLOWED_MEDIA_TYPES = new Set([
  'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif', 'image/svg+xml',
  'video/mp4', 'video/webm', 'video/ogg', 'video/quicktime',
  'audio/mpeg', 'audio/ogg', 'audio/wav', 'audio/webm',
]);

// No hard size limit — rely on Cloudflare's streaming and Range request support
// to handle large files without buffering the entire response into memory.

// Custom emoji images are effectively immutable, so cache them for 30 days.
const EMOJI_CACHE_TTL = 2592000;

// Max size for unfurl HTML fetch (512 KB)
const MAX_UNFURL_SIZE = 512 * 1024;

// Max size for JSON proxy responses (512 KB)
const MAX_JSON_SIZE = 512 * 1024;

// Max size for proxied media (100 MB) — caps bandwidth/memory amplification.
const MAX_MEDIA_SIZE = 100 * 1024 * 1024;

const GEO_RELAYS_URL = 'https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv';
const GEO_RELAYS_CACHE_TTL = 300;

// Translate endpoint
const GOOGLE_TRANSLATE_URL = 'https://translate.googleapis.com/translate_a/single';

// Timeout for translation requests
const TRANSLATE_TIMEOUT = 8000;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Range, Authorization',
  'Access-Control-Expose-Headers': 'Content-Range, Accept-Ranges, Content-Length',
};

export async function onRequest(context) {
  const { request } = context;

  // Handle CORS preflight
  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  const url = new URL(request.url);
  const action = url.searchParams.get('action');

  try {
    if (action === 'translate') {
      return await handleTranslate(request);
    } else if (action === 'unfurl') {
      return await handleUnfurl(url.searchParams.get('url'), context);
    } else if (action === 'upload') {
      return await handleBlossomUpload(request, url.searchParams.get('server'));
    } else if (action === 'mirror') {
      return await handleBlossomMirror(request, url.searchParams.get('server'));
    } else if (action === 'geo-relays') {
      return await handleGeoRelays(context);
    } else if (action === 'geocode') {
      return await handleGeocode(url.searchParams, context);
    } else if (action === 'giphy') {
      return await handleGiphy(url.searchParams, context);
    } else if (action === 'json') {
      return await handleJsonProxy(url.searchParams.get('url'), request);
    } else {
      return await handleMediaProxy(url.searchParams.get('url'), request, url.searchParams.get('emoji') === '1');
    }
  } catch (err) {
    return jsonResponse({ error: err.message || 'Internal error' }, 500);
  }
}

const CACHE_HOST = 'https://nymchat-edge-cache.invalid';

async function readEdgeCache(path) {
  const cached = await caches.default.match(new Request(`${CACHE_HOST}${path}`, { method: 'GET' }));
  if (!cached) return null;
  const headers = new Headers(cached.headers);
  for (const [k, v] of Object.entries(CORS_HEADERS)) headers.set(k, v);
  headers.set('X-Edge-Cache', 'HIT');
  return new Response(cached.body, { status: cached.status, headers });
}

function writeEdgeCache(context, path, body, contentType, ttl) {
  const headers = new Headers(CORS_HEADERS);
  headers.set('Content-Type', contentType);
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('Cache-Control', `public, max-age=${ttl}, s-maxage=${ttl}`);
  headers.set('X-Edge-Cache', 'MISS');
  const resp = new Response(body, { status: 200, headers });
  const op = caches.default.put(new Request(`${CACHE_HOST}${path}`, { method: 'GET' }), resp.clone());
  if (context && context.waitUntil) context.waitUntil(op);
  return resp;
}

// Geo-relay CSV proxy with Cloudflare edge cache.
// Parses the bitchat CSV server-side and returns JSON so the client doesn't
// have to do the work and the cached payload stays compact.
async function handleGeoRelays(context) {
  const cacheKey = new Request(GEO_RELAYS_URL + '#json', { method: 'GET' });
  const cache = caches.default;

  let cached = await cache.match(cacheKey);
  if (cached) {
    const headers = new Headers(cached.headers);
    for (const [k, v] of Object.entries(CORS_HEADERS)) headers.set(k, v);
    headers.set('X-Edge-Cache', 'HIT');
    return new Response(cached.body, { status: cached.status, headers });
  }

  const upstream = await fetch(GEO_RELAYS_URL, {
    headers: { 'User-Agent': 'NymchatProxy/1.0', 'Accept': 'text/csv, text/plain' },
  });
  if (!upstream.ok) {
    return jsonResponse({ error: `Upstream returned ${upstream.status}` }, 502);
  }

  const csv = await upstream.text();
  const relays = parseGeoRelaysCsv(csv);

  const headers = new Headers(CORS_HEADERS);
  headers.set('Content-Type', 'application/json');
  headers.set('Cache-Control', `public, max-age=${GEO_RELAYS_CACHE_TTL}, s-maxage=${GEO_RELAYS_CACHE_TTL}`);
  headers.set('X-Edge-Cache', 'MISS');

  const resp = new Response(JSON.stringify({ relays }), { status: 200, headers });
  if (context && context.waitUntil) {
    context.waitUntil(cache.put(cacheKey, resp.clone()));
  } else {
    await cache.put(cacheKey, resp.clone());
  }
  return resp;
}

function parseGeoRelaysCsv(csv) {
  const parsed = [];
  const lines = csv.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    if (i === 0 && line.toLowerCase().includes('relay url')) continue;
    const parts = line.split(',');
    if (parts.length < 3) continue;
    const host = parts[0].trim()
      .replace('https://', '').replace('http://', '')
      .replace('wss://', '').replace('ws://', '')
      .replace(/\/+$/, '');
    const lat = parseFloat(parts[1]);
    const lng = parseFloat(parts[2]);
    if (!host || isNaN(lat) || isNaN(lng)) continue;
    // Only emit plausible hostnames (optionally :port) — reject embedded paths,
    // credentials, query strings, whitespace or control chars that could inject
    // an attacker-chosen relay endpoint into every client's relay set.
    if (!/^[a-z0-9.-]+(:\d{1,5})?$/i.test(host)) continue;
    parsed.push({ url: `wss://${host}`, lat, lng });
  }
  return parsed;
}

// Generic JSON proxy for external HTTP APIs (LNURL, Nominatim, Giphy, NIP-11, etc.)
async function handleJsonProxy(targetUrl, request) {
  if (!targetUrl) {
    return jsonResponse({ error: 'Missing url parameter' }, 400);
  }

  try {
    new URL(targetUrl);
  } catch {
    return jsonResponse({ error: 'Invalid URL' }, 400);
  }

  if (isPrivateUrl(targetUrl)) {
    return jsonResponse({ error: 'Blocked: private/local addresses not allowed' }, 403);
  }

  const method = request.method === 'POST' ? 'POST' : 'GET';
  const upstreamHeaders = new Headers({
    'User-Agent': 'NymchatProxy/1.0',
    'Accept': 'application/json, text/plain, */*',
  });

  let body;
  if (method === 'POST') {
    const ct = request.headers.get('Content-Type');
    if (ct) upstreamHeaders.set('Content-Type', ct);
    body = await request.text();
  }

  let resp;
  try {
    resp = await ssrfSafeFetch(targetUrl, { method, headers: upstreamHeaders, body });
  } catch (err) {
    if (err.ssrfBlocked) return jsonResponse({ error: 'Blocked: private/local addresses not allowed' }, 403);
    throw err;
  }

  const ct = (resp.headers.get('content-type') || '').toLowerCase();
  const allowed = ct.includes('json') || ct.includes('text/plain') || ct === '';
  if (!allowed) {
    return jsonResponse({ error: 'Upstream content-type not allowed: ' + ct }, 415);
  }

  const text = await readBounded(resp, MAX_JSON_SIZE);
  if (text === null) {
    return jsonResponse({ error: 'Upstream response too large' }, 502);
  }

  const headers = new Headers(CORS_HEADERS);
  headers.set('Content-Type', resp.headers.get('content-type') || 'application/json');
  headers.set('X-Content-Type-Options', 'nosniff');
  return new Response(text, { status: resp.status, headers });
}

const ALLOWED_BLOSSOM_HOSTS = new Set([
  'blossom.band',
  'blossom.primal.net',
  'nostr.download',
]);
const DEFAULT_BLOSSOM_HOST = 'https://blossom.band';
const ALLOWED_UPLOAD_PREFIXES = ['image/', 'video/', 'audio/'];
const UPLOAD_OCTET_STREAM = 'application/octet-stream';

function resolveBlossomBase(serverParam) {
  if (!serverParam) return DEFAULT_BLOSSOM_HOST;
  try {
    const u = new URL(serverParam);
    // Require HTTPS — the client's Nostr auth header is forwarded upstream and
    // must never travel over cleartext HTTP.
    if (u.protocol !== 'https:') return null;
    if (!ALLOWED_BLOSSOM_HOSTS.has(u.hostname)) return null;
    return `https://${u.hostname}`;
  } catch {
    return null;
  }
}

async function handleBlossomUpload(request, serverParam) {
  if (request.method !== 'PUT' && request.method !== 'POST') {
    return jsonResponse({ error: 'PUT required' }, 405);
  }

  const base = resolveBlossomBase(serverParam);
  if (!base) {
    return jsonResponse({ error: 'Unknown Blossom server' }, 400);
  }

  const auth = request.headers.get('Authorization');
  if (!auth || !auth.startsWith('Nostr ')) {
    return jsonResponse({ error: 'Missing Nostr auth' }, 401);
  }

  const contentType = (request.headers.get('Content-Type') || UPLOAD_OCTET_STREAM).split(';')[0].trim().toLowerCase();
  const allowed = contentType === UPLOAD_OCTET_STREAM ||
    ALLOWED_UPLOAD_PREFIXES.some(p => contentType.startsWith(p));
  if (!allowed) {
    return jsonResponse({ error: 'Content type not allowed: ' + contentType }, 415);
  }

  const upstreamHeaders = new Headers({
    'Authorization': auth,
    'Content-Type': contentType,
    'User-Agent': 'NymchatProxy/1.0',
    'Accept': 'application/json',
  });
  const contentLength = request.headers.get('Content-Length');
  if (contentLength) upstreamHeaders.set('Content-Length', contentLength);

  const resp = await fetch(`${base}/upload`, {
    method: 'PUT',
    headers: upstreamHeaders,
    body: request.body,
  });

  const respHeaders = new Headers(CORS_HEADERS);
  const respCT = resp.headers.get('content-type');
  if (respCT) respHeaders.set('Content-Type', respCT);

  return new Response(resp.body, { status: resp.status, headers: respHeaders });
}

async function handleBlossomMirror(request, serverParam) {
  if (request.method !== 'PUT' && request.method !== 'POST') {
    return jsonResponse({ error: 'PUT required' }, 405);
  }

  const base = resolveBlossomBase(serverParam);
  if (!base) {
    return jsonResponse({ error: 'Unknown Blossom server' }, 400);
  }

  const auth = request.headers.get('Authorization');
  if (!auth || !auth.startsWith('Nostr ')) {
    return jsonResponse({ error: 'Missing Nostr auth' }, 401);
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: 'Invalid JSON body' }, 400);
  }
  if (!body || typeof body.url !== 'string' || !body.url) {
    return jsonResponse({ error: 'Missing source url' }, 400);
  }
  if (isPrivateUrl(body.url)) {
    return jsonResponse({ error: 'Blocked: private/local addresses not allowed' }, 403);
  }

  const resp = await fetch(`${base}/mirror`, {
    method: 'PUT',
    headers: {
      'Authorization': auth,
      'Content-Type': 'application/json',
      'User-Agent': 'NymchatProxy/1.0',
      'Accept': 'application/json',
    },
    body: JSON.stringify({ url: body.url }),
  });

  const respHeaders = new Headers(CORS_HEADERS);
  const respCT = resp.headers.get('content-type');
  if (respCT) respHeaders.set('Content-Type', respCT);
  return new Response(resp.body, { status: resp.status, headers: respHeaders });
}

// Media Proxy — supports Range requests for video/audio streaming
async function handleMediaProxy(targetUrl, request, isEmoji = false) {
  if (!targetUrl) {
    return jsonResponse({ error: 'Missing url parameter' }, 400);
  }

  try {
    new URL(targetUrl);
  } catch {
    return jsonResponse({ error: 'Invalid URL' }, 400);
  }

  // Block local/private IPs
  if (isPrivateUrl(targetUrl)) {
    return jsonResponse({ error: 'Blocked: private/local addresses not allowed' }, 403);
  }

  // Forward Range header to upstream if present (for video/audio streaming)
  const upstreamHeaders = {
    'User-Agent': 'NymchatProxy/1.0',
    'Accept': 'image/*, video/*, audio/*',
  };
  const rangeHeader = request.headers.get('Range');
  if (rangeHeader) {
    upstreamHeaders['Range'] = rangeHeader;
  }

  // Cache full-body fetches on Cloudflare's edge so the same avatar/banner/
  // upload is served cross-user without re-hitting the origin. Skip caching
  // for Range requests since partial responses cache poorly and need streaming.
  const fetchInit = {
    headers: upstreamHeaders,
  };
  if (!rangeHeader) {
    if (isEmoji) {
      // Long-lived edge cache for custom emoji. cacheTtlByStatus keeps failed
      // fetches uncached so a missing image is retried until it delivers.
      fetchInit.cf = {
        cacheEverything: true,
        cacheTtlByStatus: { '200-299': EMOJI_CACHE_TTL, '300-399': 0, '400-599': 0 },
      };
    } else {
      fetchInit.cf = { cacheTtl: 604800, cacheEverything: true };
    }
  }
  // Follow redirects manually so an allowed public URL can't 30x-redirect into
  // an internal/private address after the initial isPrivateUrl check.
  let resp;
  try {
    resp = await ssrfSafeFetch(targetUrl, fetchInit);
  } catch (err) {
    if (err.ssrfBlocked) return jsonResponse({ error: 'Blocked: private/local addresses not allowed' }, 403);
    throw err;
  }

  if (!resp.ok && resp.status !== 206) {
    return jsonResponse({ error: `Upstream returned ${resp.status}` }, 502);
  }

  const contentType = (resp.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  const contentRange = resp.headers.get('content-range');

  // Reject responses larger than MAX_MEDIA_SIZE (bandwidth/memory amplification)
  const declaredLen = parseInt(resp.headers.get('content-length') || '', 10);
  if (Number.isFinite(declaredLen) && declaredLen > MAX_MEDIA_SIZE) {
    return jsonResponse({ error: 'Upstream media too large' }, 413);
  }

  // Allow media types and also common types that might serve images/video
  const isAllowed = ALLOWED_MEDIA_TYPES.has(contentType) ||
    contentType.startsWith('image/') ||
    contentType.startsWith('video/') ||
    contentType.startsWith('audio/') ||
    contentType === 'application/octet-stream';

  if (!isAllowed) {
    return jsonResponse({ error: 'Content type not allowed: ' + contentType }, 403);
  }

  const headers = new Headers(CORS_HEADERS);
  headers.set('Content-Type', resp.headers.get('content-type') || 'application/octet-stream');
  // The proxy is served from the app's own origin, so prevent any proxied
  // body from being interpreted as an executable document (SVG/HTML script,
  // MIME sniffing) when navigated to directly.
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; sandbox");
  if (contentType === 'image/svg+xml') {
    // SVG can carry inline script; force download semantics on direct navigation.
    headers.set('Content-Disposition', 'inline; filename="image.svg"');
  }
  if (isEmoji) {
    headers.set('Cache-Control', `public, max-age=${EMOJI_CACHE_TTL}, s-maxage=${EMOJI_CACHE_TTL}, immutable`);
  } else {
    headers.set('Cache-Control', 'public, max-age=86400, s-maxage=604800');
  }
  headers.set('Accept-Ranges', 'bytes');

  if (resp.headers.has('content-length')) {
    headers.set('Content-Length', resp.headers.get('content-length'));
  }

  // Pass through range response headers for 206 Partial Content
  if (resp.status === 206) {
    if (contentRange) {
      headers.set('Content-Range', contentRange);
    }
    return new Response(resp.body, { status: 206, headers });
  }

  return new Response(resp.body, { status: 200, headers });
}

// Translation
async function handleTranslate(request) {
  if (request.method !== 'POST') {
    return jsonResponse({ error: 'POST required' }, 405);
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: 'Invalid JSON body' }, 400);
  }

  const { text, source, target } = body;
  if (!text || !target) {
    return jsonResponse({ error: 'Missing text or target language' }, 400);
  }

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TRANSLATE_TIMEOUT);

    const params = new URLSearchParams({
      client: 'gtx',
      sl: source || 'auto',
      tl: target,
      dt: 't',
      q: text.slice(0, 5000),
    });

    const resp = await fetch(`${GOOGLE_TRANSLATE_URL}?${params}`, {
      signal: controller.signal,
    });
    clearTimeout(timer);

    if (!resp.ok) {
      return jsonResponse({ error: `Google Translate returned ${resp.status}` }, 502);
    }

    const data = await resp.json();

    // Response format: [[["translated text","original text",null,null,10],...],null,"detected_lang"]
    let translatedText = '';
    if (Array.isArray(data[0])) {
      translatedText = data[0].map(seg => seg[0] || '').join('');
    }

    const detectedLanguage = data[2] || source || 'auto';

    return jsonResponse({ translatedText, detectedLanguage });
  } catch (err) {
    const msg = err.name === 'AbortError' ? 'timeout' : err.message;
    return jsonResponse({ error: 'Translation failed: ' + msg }, 502);
  }
}

// URL Unfurling (Open Graph), edge-cached for 1 hour
async function handleUnfurl(targetUrl, context) {
  if (!targetUrl) {
    return jsonResponse({ error: 'Missing url parameter' }, 400);
  }

  try {
    new URL(targetUrl);
  } catch {
    return jsonResponse({ error: 'Invalid URL' }, 400);
  }

  if (isPrivateUrl(targetUrl)) {
    return jsonResponse({ error: 'Blocked: private/local addresses not allowed' }, 403);
  }

  const cachePath = `/unfurl?url=${encodeURIComponent(targetUrl)}`;
  const cached = await readEdgeCache(cachePath);
  if (cached) return cached;

  let resp;
  try {
    resp = await ssrfSafeFetch(targetUrl, {
      headers: {
        'User-Agent': 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
        'Accept': 'text/html,application/xhtml+xml',
      },
    });
  } catch (err) {
    if (err.ssrfBlocked) return jsonResponse({ error: 'Blocked: private/local addresses not allowed' }, 403);
    throw err;
  }

  if (!resp.ok) {
    return jsonResponse({ error: `Upstream returned ${resp.status}` }, 502);
  }

  const contentType = (resp.headers.get('content-type') || '').toLowerCase();
  if (!contentType.includes('text/html')) {
    return jsonResponse({ error: 'Not an HTML page' }, 422);
  }

  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let html = '';
  let bytesRead = 0;

  while (bytesRead < MAX_UNFURL_SIZE) {
    const { done, value } = await reader.read();
    if (done) break;
    bytesRead += value.length;
    html += decoder.decode(value, { stream: true });
    if (html.includes('</head>')) break;
  }
  reader.cancel();

  const meta = extractOpenGraph(html, targetUrl);
  return writeEdgeCache(context, cachePath, JSON.stringify(meta), 'application/json', 3600);
}

// Reverse-geocode lat/lng via Nominatim, edge-cached for 1 day. Results are
// always requested in English so address fields stay consistent for users.
async function handleGeocode(searchParams, context) {
  const lat = parseFloat(searchParams.get('lat'));
  const lng = parseFloat(searchParams.get('lng'));
  const zoomRaw = parseInt(searchParams.get('zoom') || '10', 10);
  const zoom = Number.isFinite(zoomRaw) ? Math.min(18, Math.max(0, zoomRaw)) : 10;
  const langRaw = (searchParams.get('lang') || 'en').toLowerCase();
  const lang = /^[a-z]{2}(-[a-z]{2})?$/.test(langRaw) ? langRaw : 'en';
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    return jsonResponse({ error: 'Invalid lat/lng' }, 400);
  }

  const latKey = lat.toFixed(4);
  const lngKey = lng.toFixed(4);
  const cachePath = `/geocode?lat=${latKey}&lng=${lngKey}&zoom=${zoom}&lang=${lang}`;
  const cached = await readEdgeCache(cachePath);
  if (cached) return cached;

  const upstreamUrl = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${latKey}&lon=${lngKey}&zoom=${zoom}&accept-language=${lang}`;
  const upstream = await fetch(upstreamUrl, {
    headers: {
      'User-Agent': 'NymchatProxy/1.0',
      'Accept': 'application/json',
      'Accept-Language': lang,
    },
  });
  if (!upstream.ok) {
    return jsonResponse({ error: `Upstream returned ${upstream.status}` }, 502);
  }
  const text = await upstream.text();
  return writeEdgeCache(context, cachePath, text, 'application/json', 86400);
}

// Giphy trending/search proxy, edge-cached for 60s
async function handleGiphy(searchParams, context) {
  const apiKey = searchParams.get('api_key');
  const q = searchParams.get('q') || '';
  const trending = searchParams.get('trending') === '1';
  if (!apiKey) {
    return jsonResponse({ error: 'Missing api_key' }, 400);
  }

  const cachePath = trending
    ? '/giphy?trending=1'
    : `/giphy?q=${encodeURIComponent(q.toLowerCase().trim())}`;
  const cached = await readEdgeCache(cachePath);
  if (cached) return cached;

  const upstreamUrl = trending
    ? `https://api.giphy.com/v1/gifs/trending?api_key=${encodeURIComponent(apiKey)}&limit=20&rating=g`
    : `https://api.giphy.com/v1/gifs/search?api_key=${encodeURIComponent(apiKey)}&q=${encodeURIComponent(q)}&limit=20&rating=g`;

  const upstream = await fetch(upstreamUrl, {
    headers: { 'User-Agent': 'NymchatProxy/1.0', 'Accept': 'application/json' },
  });
  if (!upstream.ok) {
    return jsonResponse({ error: `Upstream returned ${upstream.status}` }, 502);
  }
  const text = await upstream.text();
  return writeEdgeCache(context, cachePath, text, 'application/json', 60);
}

// Extract Open Graph and fallback meta tags from HTML head
function extractOpenGraph(html, pageUrl) {
  const get = (property) => {
    // Try og: tags first
    const ogMatch = html.match(new RegExp(`<meta[^>]+property=["']og:${property}["'][^>]+content=["']([^"']+)["']`, 'i'))
      || html.match(new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:${property}["']`, 'i'));
    if (ogMatch) return ogMatch[1];

    // Try twitter: tags
    const twMatch = html.match(new RegExp(`<meta[^>]+name=["']twitter:${property}["'][^>]+content=["']([^"']+)["']`, 'i'))
      || html.match(new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+name=["']twitter:${property}["']`, 'i'));
    if (twMatch) return twMatch[1];

    return null;
  };

  const title = get('title')
    || (html.match(/<title[^>]*>([^<]+)<\/title>/i) || [])[1]
    || '';

  const description = get('description')
    || (html.match(/<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']/i) || [])[1]
    || '';

  const image = get('image') || '';
  const siteName = get('site_name') || '';
  const type = get('type') || '';

  // Resolve relative image URLs
  let resolvedImage = image;
  if (image && !image.startsWith('http')) {
    try {
      resolvedImage = new URL(image, pageUrl).href;
    } catch { resolvedImage = ''; }
  }

  // Extract favicon
  let favicon = '';
  const faviconMatch = html.match(/<link[^>]+rel=["'](?:icon|shortcut icon)["'][^>]+href=["']([^"']+)["']/i)
    || html.match(/<link[^>]+href=["']([^"']+)["'][^>]+rel=["'](?:icon|shortcut icon)["']/i);
  if (faviconMatch) {
    favicon = faviconMatch[1];
    if (!favicon.startsWith('http')) {
      try { favicon = new URL(favicon, pageUrl).href; } catch { favicon = ''; }
    }
  }

  return {
    url: pageUrl,
    title: decodeEntities(title).slice(0, 300),
    description: decodeEntities(description).slice(0, 500),
    image: resolvedImage,
    siteName: decodeEntities(siteName),
    type,
    favicon,
  };
}

function decodeEntities(str) {
  return str
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#x27;/g, "'")
    .replace(/&#x2F;/g, '/');
}

// Parse a hostname that may be an IPv4 address in dotted/decimal/octal/hex
// form (inet_aton semantics, as browsers and fetch resolvers accept) into a
// canonical 32-bit integer, or null if it is not an IPv4 literal.
function ipv4ToInt(host) {
  const parts = host.split('.');
  if (parts.length === 0 || parts.length > 4) return null;
  const nums = [];
  for (const p of parts) {
    if (p === '') return null;
    let n;
    if (/^0x[0-9a-f]+$/i.test(p)) n = parseInt(p, 16);
    else if (/^0[0-7]+$/.test(p)) n = parseInt(p, 8);
    else if (/^[0-9]+$/.test(p)) n = parseInt(p, 10);
    else return null; // not a pure-numeric component => not an IPv4 literal
    if (!Number.isFinite(n) || n < 0) return null;
    nums.push(n);
  }
  // inet_aton: the final part absorbs the remaining bytes.
  const n = nums.length;
  if (nums.slice(0, n - 1).some(x => x > 255)) return null;
  const last = nums[n - 1];
  const maxLast = Math.pow(256, 4 - (n - 1));
  if (last >= maxLast) return null;
  let value = last;
  for (let i = 0; i < n - 1; i++) value += nums[i] * Math.pow(256, 3 - i);
  return value >>> 0;
}

function ipv4IntIsPrivate(v) {
  const a = (v >>> 24) & 0xff, b = (v >>> 16) & 0xff;
  if (a === 0) return true;                       // 0.0.0.0/8
  if (a === 10) return true;                       // 10.0.0.0/8
  if (a === 127) return true;                      // 127.0.0.0/8 loopback
  if (a === 169 && b === 254) return true;         // 169.254.0.0/16 link-local (cloud metadata)
  if (a === 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
  if (a === 192 && b === 168) return true;         // 192.168.0.0/16
  if (a === 100 && b >= 64 && b <= 127) return true; // 100.64.0.0/10 CGNAT
  if (a === 192 && b === 0 && ((v >>> 8) & 0xff) === 0) return true; // 192.0.0.0/24
  if (a === 198 && (b === 18 || b === 19)) return true; // 198.18.0.0/15 benchmarking
  if (a >= 224) return true;                       // 224.0.0.0/4 multicast + 240/4 reserved
  return false;
}

function ipv6IsPrivate(host) {
  let h = host.toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
  // Strip zone id
  const pct = h.indexOf('%');
  if (pct !== -1) h = h.slice(0, pct);
  if (h === '::1' || h === '::' || h === '0:0:0:0:0:0:0:1') return true;
  // IPv4-mapped/compat ::ffff:a.b.c.d or ::a.b.c.d
  const mapped = h.match(/^::(?:ffff:)?(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
  if (mapped) {
    const v = ipv4ToInt(mapped[1]);
    if (v !== null && ipv4IntIsPrivate(v)) return true;
  }
  if (/^f[cd][0-9a-f]{2}:/.test(h)) return true; // fc00::/7 unique local
  if (/^fe[89ab][0-9a-f]:/.test(h)) return true; // fe80::/10 link-local
  return false;
}

function isPrivateUrl(urlStr) {
  try {
    const parsed = new URL(urlStr);
    // Block non-http(s) schemes (file:, gopher:, ftp:, data:, etc.)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return true;
    // Reject embedded credentials (userinfo@host smuggling)
    if (parsed.username || parsed.password) return true;
    let host = parsed.hostname.toLowerCase().replace(/\.$/, ''); // strip trailing dot
    if (!host) return true;
    if (host === 'localhost' || host.endsWith('.localhost')) return true;
    if (host.endsWith('.local') || host.endsWith('.internal')) return true;
    if (host.includes(':')) return ipv6IsPrivate(parsed.hostname.toLowerCase());
    const v = ipv4ToInt(host);
    if (v !== null) return ipv4IntIsPrivate(v);
    return false; // a regular DNS hostname; resolved-IP safety handled by safeFetch
  } catch {
    return true;
  }
}

// Fetch that follows redirects manually, re-validating every hop against the
// SSRF blocklist so a public URL cannot 30x-redirect into an internal address
// (the redirect:'follow' TOCTOU). Caps the redirect chain.
async function ssrfSafeFetch(targetUrl, init = {}, maxRedirects = 4) {
  let current = targetUrl;
  for (let i = 0; i <= maxRedirects; i++) {
    if (isPrivateUrl(current)) {
      const e = new Error('Blocked: private/local address in redirect chain');
      e.ssrfBlocked = true;
      throw e;
    }
    const resp = await fetch(current, { ...init, redirect: 'manual' });
    const status = resp.status;
    if (status === 301 || status === 302 || status === 303 || status === 307 || status === 308) {
      const loc = resp.headers.get('location');
      if (!loc) return resp;
      try {
        current = new URL(loc, current).toString();
      } catch {
        const e = new Error('Invalid redirect location');
        e.ssrfBlocked = true;
        throw e;
      }
      continue;
    }
    return resp;
  }
  const e = new Error('Too many redirects');
  e.ssrfBlocked = true;
  throw e;
}

// Read a response body as text, aborting once maxBytes is exceeded instead of
// buffering the entire (potentially huge) body into memory first.
async function readBounded(resp, maxBytes) {
  const cl = parseInt(resp.headers.get('content-length') || '', 10);
  if (Number.isFinite(cl) && cl > maxBytes) return null;
  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let out = '';
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > maxBytes) {
      try { reader.cancel(); } catch { /* noop */ }
      return null;
    }
    out += decoder.decode(value, { stream: true });
  }
  out += decoder.decode();
  return out;
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json',
      'X-Content-Type-Options': 'nosniff',
      ...CORS_HEADERS,
    },
  });
}
