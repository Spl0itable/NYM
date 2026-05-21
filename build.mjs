import { transform } from 'esbuild';
import { promises as fs } from 'fs';
import path from 'path';
import crypto from 'crypto';

const root = process.cwd();
const dist = path.join(root, 'dist');

const sha8 = (buf) => crypto.createHash('sha256').update(buf).digest('hex').slice(0, 8);
const toPosix = (p) => p.split(path.sep).join('/');

async function walk(dir) {
  const out = [];
  for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...await walk(full));
    else out.push(full);
  }
  return out;
}

function hashedName(rel, content) {
  const ext = path.extname(rel);
  const stem = rel.slice(0, -ext.length);
  return `${stem}.${sha8(content)}${ext}`;
}

async function emit(rel, code) {
  const dest = path.join(dist, rel);
  await fs.mkdir(path.dirname(dest), { recursive: true });
  await fs.writeFile(dest, code);
}

const swRegisterSource = `if ('serviceWorker' in navigator) {
  window.addEventListener('load', function () {
    navigator.serviceWorker.register('/sw.js').catch(function (e) {
      console.error('Service worker registration failed', e);
    });
  });
}
`;

async function run() {
  await fs.rm(dist, { recursive: true, force: true });
  await fs.mkdir(dist, { recursive: true });

  // rel-from-root path -> hashed rel-from-root path
  const assetMap = new Map();

  // Minify + hash every JS file under js/.
  for (const file of await walk(path.join(root, 'js'))) {
    if (!file.endsWith('.js')) continue;
    const rel = toPosix(path.relative(root, file));
    const src = await fs.readFile(file, 'utf8');
    const { code } = await transform(src, { loader: 'js', minify: true, legalComments: 'none' });
    const hashed = hashedName(rel, code);
    await emit(hashed, code);
    assetMap.set(rel, hashed);
  }

  // Minify + hash every CSS file under css/.
  for (const file of await walk(path.join(root, 'css'))) {
    if (!file.endsWith('.css')) continue;
    const rel = toPosix(path.relative(root, file));
    const src = await fs.readFile(file, 'utf8');
    const { code } = await transform(src, { loader: 'css', minify: true, legalComments: 'none' });
    const hashed = hashedName(rel, code);
    await emit(hashed, code);
    assetMap.set(rel, hashed);
  }

  // Service worker registration shim (external, to satisfy strict CSP).
  const swReg = (await transform(swRegisterSource, { loader: 'js', minify: true })).code;
  const swRegRel = hashedName('js/sw-register.js', swReg);
  await emit(swRegRel, swReg);

  // Replace original asset paths with hashed ones in HTML. Longest keys first
  // so shorter paths can't partially shadow longer ones.
  const replacements = [...assetMap.entries()].sort((a, b) => b[0].length - a[0].length);
  const rewriteHtml = (html) => {
    for (const [orig, hashed] of replacements) html = html.split(orig).join(hashed);
    return html;
  };

  let indexHtml = rewriteHtml(await fs.readFile(path.join(root, 'index.html'), 'utf8'));
  indexHtml = indexHtml.replace('</body>', `    <script src="${swRegRel}"></script>\n</body>`);
  await emit('index.html', indexHtml);

  for (const file of await walk(path.join(root, 'static'))) {
    const rel = toPosix(path.relative(root, file));
    if (file.endsWith('.html')) await emit(rel, rewriteHtml(await fs.readFile(file, 'utf8')));
    else await emit(rel, await fs.readFile(file));
  }

  // Precache the full app shell: index, hashed assets, static pages.
  const precache = ['/'];
  for (const hashed of assetMap.values()) precache.push('/' + hashed);
  precache.push('/' + swRegRel);
  for (const file of await walk(path.join(dist, 'static'))) {
    if (file.endsWith('.html')) precache.push('/' + toPosix(path.relative(dist, file)));
  }

  const version = sha8(Buffer.from([...assetMap.values()].sort().join('|')));
  const sw = `const CACHE = 'nym-${version}';
const PRECACHE = ${JSON.stringify(precache)};
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(PRECACHE)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/api/')) return;
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
        return res;
      }).catch(() => caches.match(req).then((r) => r || caches.match('/')))
    );
    return;
  }
  e.respondWith(
    caches.match(req).then((cached) => cached || fetch(req).then((res) => {
      if (res.ok && res.type === 'basic') {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
      }
      return res;
    }))
  );
});
`;
  await emit('sw.js', sw);

  // robots.txt verbatim.
  await emit('robots.txt', await fs.readFile(path.join(root, 'robots.txt')));

  // _headers + immutable caching for hashed assets, no-cache for entry/sw.
  const headers = await fs.readFile(path.join(root, '_headers'), 'utf8');
  const cacheRules = `

/js/*
  Cache-Control: public, max-age=31536000, immutable
/css/*
  Cache-Control: public, max-age=31536000, immutable
/sw.js
  Cache-Control: no-cache
/index.html
  Cache-Control: no-cache
/
  Cache-Control: no-cache
`;
  await emit('_headers', headers.replace(/\s*$/, '') + cacheRules);

  console.log(`Built ${assetMap.size + 1} assets to dist/ (cache nym-${version}, ${precache.length} precached).`);
}

run().catch((e) => { console.error(e); process.exit(1); });
