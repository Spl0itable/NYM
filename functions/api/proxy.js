// Cloudflare Pages Function: HTTP proxy for privacy-preserving fetches
// Routes media, translation requests, and URL unfurling through Cloudflare
// so the user's real IP is never exposed to third-party services.
//
// Endpoints:
//   GET  /api/proxy?url=<encoded-url>            — Proxy any allowed media/resource
//   POST /api/proxy?action=translate             — Translate text
//   GET  /api/proxy?action=unfurl&url=<url>      — Fetch Open Graph metadata for URL preview

const ALLOWED_MEDIA_TYPES = new Set([
  'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif', 'image/svg+xml',
  'video/mp4', 'video/webm', 'video/ogg', 'video/quicktime',
  'audio/mpeg', 'audio/ogg', 'audio/wav', 'audio/webm',
]);

// No hard size limit — rely on Cloudflare's streaming and Range request support
// to handle large files without buffering the entire response into memory.

// Max size for unfurl HTML fetch (512 KB)
const MAX_UNFURL_SIZE = 512 * 1024;

// Translate endpoint
const GOOGLE_TRANSLATE_URL = 'https://translate.googleapis.com/translate_a/single';

// Timeout for translation requests
const TRANSLATE_TIMEOUT = 8000;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Range',
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
      return await handleUnfurl(url.searchParams.get('url'));
    } else {
      return await handleMediaProxy(url.searchParams.get('url'), request);
    }
  } catch (err) {
    return jsonResponse({ error: err.message || 'Internal error' }, 500);
  }
}

// Media Proxy — supports Range requests for video/audio streaming
async function handleMediaProxy(targetUrl, request) {
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

  const resp = await fetch(targetUrl, {
    headers: upstreamHeaders,
    redirect: 'follow',
  });

  if (!resp.ok && resp.status !== 206) {
    return jsonResponse({ error: `Upstream returned ${resp.status}` }, 502);
  }

  const contentType = (resp.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  const contentRange = resp.headers.get('content-range');

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
  headers.set('Cache-Control', 'public, max-age=86400, s-maxage=604800');
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

// URL Unfurling (Open Graph)
async function handleUnfurl(targetUrl) {
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

  const resp = await fetch(targetUrl, {
    headers: {
      'User-Agent': 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
      'Accept': 'text/html,application/xhtml+xml',
    },
    redirect: 'follow',
  });

  if (!resp.ok) {
    return jsonResponse({ error: `Upstream returned ${resp.status}` }, 502);
  }

  const contentType = (resp.headers.get('content-type') || '').toLowerCase();
  if (!contentType.includes('text/html')) {
    return jsonResponse({ error: 'Not an HTML page' }, 422);
  }

  // Read limited HTML
  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let html = '';
  let bytesRead = 0;

  while (bytesRead < MAX_UNFURL_SIZE) {
    const { done, value } = await reader.read();
    if (done) break;
    bytesRead += value.length;
    html += decoder.decode(value, { stream: true });
    // Stop early once we have </head> — OG tags are always in <head>
    if (html.includes('</head>')) break;
  }
  reader.cancel();

  const meta = extractOpenGraph(html, targetUrl);
  return jsonResponse(meta);
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

function isPrivateUrl(urlStr) {
  try {
    const parsed = new URL(urlStr);
    const host = parsed.hostname;
    if (host === 'localhost' || host === '127.0.0.1' || host === '::1') return true;
    if (host.startsWith('10.') || host.startsWith('192.168.')) return true;
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(host)) return true;
    if (host.endsWith('.local') || host.endsWith('.internal')) return true;
    // Block non-http(s) schemes
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return true;
  } catch {
    return true;
  }
  return false;
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...CORS_HEADERS,
    },
  });
}
