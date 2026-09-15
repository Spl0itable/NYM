// The relay neighbourhood of a geohash, server-side.

const GEO_RELAYS_URL = 'https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv';
const GEO_RELAYS_VETTED_URL = 'https://raw.githubusercontent.com/permissionlesstech/bitchat/refs/heads/main/relays/online_relays_gps.csv';
const GEO_DIRECTORY_TTL_MS = 6 * 3600 * 1000;
const GEOHASH_ALPHABET = '0123456789bcdefghjkmnpqrstuvwxyz';
// bitchat's count, per ranking, before the union.
const CLOSEST_COUNT = 5;

let directoryCache = null;
let directoryInflight = null;

function parseGeoRelaysCsv(csv) {
  const out = [];
  const lines = String(csv || '').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    if (i === 0 && line.toLowerCase().includes('relay url')) continue;
    const parts = line.split(',');
    if (parts.length < 3) continue;
    const host = parts[0].trim()
      .replace(/^https?:\/\//, '').replace(/^wss?:\/\//, '').replace(/\/+$/, '');
    const lat = parseFloat(parts[1]);
    const lng = parseFloat(parts[2]);
    if (!host || !Number.isFinite(lat) || !Number.isFinite(lng)) continue;
    out.push({ url: 'wss://' + host, lat, lng });
  }
  return out;
}

// Centre of the geohash cell, same as the client's decodeGeohash.
function decodeGeohash(geohash) {
  if (typeof geohash !== 'string' || !geohash) return null;
  const gh = geohash.toLowerCase();
  let latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  let isLng = true;
  for (const ch of gh) {
    const idx = GEOHASH_ALPHABET.indexOf(ch);
    if (idx < 0) return null;
    for (let bit = 4; bit >= 0; bit--) {
      const on = (idx >> bit) & 1;
      if (isLng) {
        const mid = (lngMin + lngMax) / 2;
        if (on) lngMin = mid; else lngMax = mid;
      } else {
        const mid = (latMin + latMax) / 2;
        if (on) latMin = mid; else latMax = mid;
      }
      isLng = !isLng;
    }
  }
  return { lat: (latMin + latMax) / 2, lng: (lngMin + lngMax) / 2 };
}

function haversineKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
    + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180)
    * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// The URLs a geohash message may legitimately arrive on. Empty means "cannot
// tell" — an undecodable geohash or a directory we do not have — and every
// caller treats that as admit-everything rather than reject-everything.
function closestRelayUrls(geohash, directory, count = CLOSEST_COUNT) {
  const coords = decodeGeohash(geohash);
  if (!coords || !directory) return [];

  const rank = (list) => (Array.isArray(list) ? list : []).map((relay, index) => ({
    url: relay.url,
    index,
    distance: haversineKm(coords.lat, coords.lng, relay.lat, relay.lng),
  }));

  // Android: distance only. Array.prototype.sort is stable, so ties keep
  // directory order — what Kotlin's stable sortedBy over the same CSV gives.
  const upstream = rank(directory.relays);
  upstream.sort((a, b) => (a.distance - b.distance) || (a.index - b.index));

  // iOS: (distance, host) ascending.
  const vetted = rank(directory.vetted);
  vetted.sort((a, b) => (a.distance - b.distance)
    || (a.url < b.url ? -1 : a.url > b.url ? 1 : 0));

  const out = [];
  const seen = new Set();
  for (const r of [...upstream.slice(0, count), ...vetted.slice(0, count)]) {
    if (seen.has(r.url)) continue;
    seen.add(r.url);
    out.push(r);
  }
  // Closest-first across the union, the same last step the client takes. Order
  // does not change a membership test, but keeping the two byte-identical is
  // what lets one test pin them together.
  out.sort((a, b) => a.distance - b.distance);
  return out.map((r) => r.url);
}

// Fetched once per worker isolate and held for six hours. A failure leaves the
// previous directory in place rather than clearing it: an empty directory means
// "admit everything", so dropping it on a transient fetch error would quietly
// turn the gate off.
async function loadGeoDirectory() {
  const now = Date.now();
  if (directoryCache && now - directoryCache.at < GEO_DIRECTORY_TTL_MS) {
    return directoryCache.dir;
  }
  if (directoryInflight) return directoryInflight;

  directoryInflight = (async () => {
    try {
      const headers = { 'User-Agent': 'NymchatIngest/1.0', Accept: 'text/csv, text/plain' };
      const [up, vet] = await Promise.all([
        fetch(GEO_RELAYS_URL, { headers, cf: { cacheTtl: 3600 } }),
        fetch(GEO_RELAYS_VETTED_URL, { headers, cf: { cacheTtl: 3600 } }).catch(() => null),
      ]);
      if (!up || !up.ok) return directoryCache ? directoryCache.dir : null;
      const relays = parseGeoRelaysCsv(await up.text());
      if (!relays.length) return directoryCache ? directoryCache.dir : null;
      let vetted = [];
      if (vet && vet.ok) {
        try { vetted = parseGeoRelaysCsv(await vet.text()); } catch (_) { /* additive only */ }
      }
      directoryCache = { at: now, dir: { relays, vetted } };
      return directoryCache.dir;
    } catch (_) {
      return directoryCache ? directoryCache.dir : null;
    } finally {
      directoryInflight = null;
    }
  })();
  return directoryInflight;
}

export {
  GEO_RELAYS_URL,
  GEO_RELAYS_VETTED_URL,
  CLOSEST_COUNT,
  parseGeoRelaysCsv,
  decodeGeohash,
  haversineKm,
  closestRelayUrls,
  loadGeoDirectory,
};
