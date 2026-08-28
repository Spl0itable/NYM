import { transform } from 'esbuild';
import { minify as minifyHtml } from 'html-minifier-terser';
import { promises as fs } from 'fs';
import { execSync } from 'child_process';
import path from 'path';
import crypto from 'crypto';

const root = process.cwd();
const dist = path.join(root, 'dist');

const sha8 = (buf) => crypto.createHash('sha256').update(buf).digest('hex').slice(0, 8);
const sha256b64 = (buf) => 'sha256-' + crypto.createHash('sha256').update(buf).digest('base64');
const toPosix = (p) => p.split(path.sep).join('/');

function gitCommit() {
  const env = process.env.CF_PAGES_COMMIT_SHA || process.env.GITHUB_SHA || process.env.COMMIT_SHA;
  if (env) return env.trim();
  try { return execSync('git rev-parse HEAD').toString().trim(); } catch (_) { return 'unknown'; }
}

function gitCommitTime() {
  try { return execSync('git log -1 --format=%cI').toString().trim(); } catch (_) { return ''; }
}

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

const htmlMinifyOptions = {
  collapseWhitespace: true,
  conservativeCollapse: true,
  removeComments: true,
  removeRedundantAttributes: true,
  minifyCSS: true,
  minifyJS: true,
};

// Writes one pack per language whose cache covers at least one source string.
// Returns a short line for the build summary.
async function emitI18nPacks() {
  let languages;
  let sources;
  try {
    ({ sources } = await (await import('./i18n/strings.mjs')).loadSources());
    languages = await (await import('./i18n/languages.mjs')).loadLanguages();
  } catch (err) {
    return `i18n packs: skipped (${err.message})`;
  }

  const live = new Set(sources);
  let written = 0;
  let complete = 0;
  let bytes = 0;
  for (const lang of languages) {
    let cache;
    try {
      cache = JSON.parse(await fs.readFile(path.join(root, 'i18n', 'cache', `${lang.code}.json`), 'utf8'));
    } catch {
      continue; // No cache for this language yet.
    }
    // Only strings still in the app: a stale entry would ship a translation for
    // copy that no longer exists, and grow the pack every user downloads.
    const pack = {};
    let have = 0;
    for (const [source, translated] of Object.entries(cache)) {
      if (!live.has(source) || typeof translated !== 'string' || !translated) continue;
      pack[source] = translated;
      have++;
    }
    if (have === 0) continue;
    const body = JSON.stringify(pack);
    await emit(path.join('i18n', `${lang.code}.json`), body);
    written++;
    bytes += body.length;
    if (have === sources.length) complete++;
  }
  if (written === 0) return 'i18n packs: none (run `npm run i18n`)';
  return `i18n packs: ${written} languages (${complete} complete), `
    + `${(bytes / written / 1024).toFixed(0)} KB each on average`;
}

async function emit(rel, code) {
  const dest = path.join(dist, rel);
  await fs.mkdir(path.dirname(dest), { recursive: true });
  await fs.writeFile(dest, code);
}

async function run() {
  await fs.rm(dist, { recursive: true, force: true });
  await fs.mkdir(dist, { recursive: true });

  // rel-from-root path -> hashed rel-from-root path
  const assetMap = new Map();
  // public path ('/js/app.<hash>.js') -> 'sha256-<base64>' of the served bytes
  const manifestFiles = {};

  // Compact + hash vendored data files under data/ first so '/data/...'
  // references in JS get rewritten to hashed names.
  for (const file of await walk(path.join(root, 'data'))) {
    if (!file.endsWith('.json')) continue;
    const rel = toPosix(path.relative(root, file));
    const code = JSON.stringify(JSON.parse(await fs.readFile(file, 'utf8')));
    const hashed = hashedName(rel, code);
    await emit(hashed, code);
    assetMap.set(rel, hashed);
    manifestFiles['/' + hashed] = sha256b64(Buffer.from(code));
  }

  // Minify + hash every JS file under js/. Some JS references other JS by
  // absolute path ('/js/...': worker scripts, importScripts, vendored libs),
  // so leaves are processed first and those references rewritten to the
  // hashed names before hashing the referrer.
  const jsWave = (rel) => {
    if (rel === 'js/nostr-tools.js' || rel.startsWith('js/vendor/')) return 0;
    // Worker dependencies are imported by their workers, so they must be hashed
    // before the worker; the workers must be hashed before their referrers.
    if (rel === 'js/modules/syntax-highlight.js' || rel === 'js/geo-decode.js'
        || rel === 'js/modules/message-format.js') return 1;
    if (rel === 'js/verify-worker.js' || rel === 'js/highlight-worker.js'
        || rel === 'js/geo-decode-worker.js' || rel === 'js/format-worker.js') return 2;
    return 3;
  };
  const jsFiles = (await walk(path.join(root, 'js')))
    .filter((f) => f.endsWith('.js'))
    .sort((a, b) => jsWave(toPosix(path.relative(root, a))) - jsWave(toPosix(path.relative(root, b))));
  for (const file of jsFiles) {
    const rel = toPosix(path.relative(root, file));
    let src = await fs.readFile(file, 'utf8');
    for (const [orig, hashed] of assetMap) src = src.split('/' + orig).join('/' + hashed);
    const { code } = await transform(src, { loader: 'js', minify: true, legalComments: 'none' });
    const hashed = hashedName(rel, code);
    await emit(hashed, code);
    assetMap.set(rel, hashed);
    manifestFiles['/' + hashed] = sha256b64(Buffer.from(code));
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
    manifestFiles['/' + hashed] = sha256b64(Buffer.from(code));
  }

  // Replace original asset paths with hashed ones in HTML. Longest keys first
  // so shorter paths can't partially shadow longer ones.
  const replacements = [...assetMap.entries()].sort((a, b) => b[0].length - a[0].length);
  const rewriteHtml = (html) => {
    for (const [orig, hashed] of replacements) html = html.split(orig).join(hashed);
    return html;
  };

  const indexHtml = rewriteHtml(await fs.readFile(path.join(root, 'index.html'), 'utf8'));
  const indexOut = await minifyHtml(indexHtml, htmlMinifyOptions);
  await emit('index.html', indexOut);
  manifestFiles['/index.html'] = sha256b64(Buffer.from(indexOut));

  // 404.html
  const notFoundHtml = rewriteHtml(await fs.readFile(path.join(root, '404.html'), 'utf8'));
  const notFoundOut = await minifyHtml(notFoundHtml, htmlMinifyOptions);
  await emit('404.html', notFoundOut);

  // robots.txt verbatim.
  await emit('robots.txt', await fs.readFile(path.join(root, 'robots.txt')));

  // sitemap.xml verbatim — one URL, because the app is one page. The site's
  // real sitemap is on the apex domain.
  await emit('sitemap.xml', await fs.readFile(path.join(root, 'sitemap.xml')));

  // llms.txt verbatim — the markdown pointer file for AI agents and other
  // automated readers. This origin is one page of client code, so a crawler
  // finds nothing useful; llms.txt says what the app is and links to the
  // documentation, source and protocol details that live elsewhere.
  await emit('llms.txt', await fs.readFile(path.join(root, 'llms.txt')));

  // _redirects verbatim — the retired /static/*.html pages point at their
  // replacements on the apex domain, which app builds already in users' hands
  // still link to.
  await emit('_redirects', await fs.readFile(path.join(root, '_redirects')));

  // Vulnerability-disclosure pointer (RFC 9116) verbatim.
  await emit('.well-known/security.txt', await fs.readFile(path.join(root, '.well-known', 'security.txt')));

  // version.json — the app version (NYMCHAT_VERSION, the single source of truth
  // in js/app.js) as a tiny fetchable endpoint, so the native iOS/Android apps
  // can display the LIVE main-project version instead of a hardcoded string.
  const appJsSource = await fs.readFile(path.join(root, 'js', 'app.js'), 'utf8');
  const versionMatch = appJsSource.match(/NYMCHAT_VERSION\s*=\s*['"]([^'"]+)['"]/);
  const appVersion = versionMatch ? versionMatch[1] : 'unknown';
  await emit('version.json', JSON.stringify({ version: appVersion }));

  const packSummary = await emitI18nPacks();

  // Service worker: stamp a per-build cache version so each deploy gets a fresh
  // cache and old ones are pruned on activate.
  const swVersion = sha8([...assetMap.values()].sort().join('|'));

  // Critical shell assets to precache on SW install (hashed names)
  const criticalSources = [
    'css/styles-core.css', 'css/styles-shell.css', 'css/styles-chat.css',
    'css/styles-components.css', 'css/styles-themes-responsive.css', 'css/styles-columns.css',
    'css/no-inline.css',
    'js/defer-css.js', 'js/theme-init.js', 'js/setup-modal-init.js',
    'js/modules/inline-bindings.js', 'js/modules/dialog.js', 'js/nostr-tools.js',
    'js/app.js', 'js/vendor/ml-kem.js', 'js/nym-crypto.js', 'js/modules/crypto-pool.js',
    'js/modules/pq.js',
    'js/modules/persistence.js', 'js/modules/key-vault.js', 'js/modules/panic.js',
    'js/modules/relays.js', 'js/modules/nostr-core.js', 'js/modules/users.js',
    'js/modules/channels.js', 'js/modules/syntax-highlight.js', 'js/modules/messages.js',
    'js/modules/pms.js', 'js/modules/groups.js', 'js/modules/ui-context.js',
    'js/modules/init.js', 'js/modules/build-verify.js', 'js/modules/canary-verify.js',
    'js/modules/columns.js', 'js/modules/threads.js',
  ];
  const precache = criticalSources
    .map((rel) => assetMap.get(rel))
    .filter(Boolean)
    .map((hashed) => '/' + hashed);

  const swSrc = await fs.readFile(path.join(root, 'sw.js'), 'utf8');
  const swOut = swSrc
    .replace('__CACHE_VERSION__', swVersion)
    .replace('__PRECACHE_ASSETS__', JSON.stringify(precache));
  await emit('sw.js', swOut);
  manifestFiles['/sw.js'] = sha256b64(Buffer.from(swOut));

  // Build manifest: lets the app re-hash its own running bundle and lets anyone
  // reproduce bundleHash from source at `commit`. bundleHash is derived only
  // from the content-hashed asset set, and builtAt is the commit time rather
  // than the build time, so rebuilds of the same source are byte-identical and
  // the deployed manifest matches the digest attested by the provenance Action.
  const bundleHash = crypto.createHash('sha256')
    .update(Object.keys(manifestFiles).sort().map((p) => p + ':' + manifestFiles[p]).join('\n'))
    .digest('hex');
  const commit = gitCommit();
  await emit('bundle-hash.txt', bundleHash + '\n');
  await emit('build-manifest.json', JSON.stringify({
    app: 'nymchat',
    commit,
    builtAt: gitCommitTime(),
    algo: 'sha256',
    bundleHash,
    files: manifestFiles,
  }, null, 2));

  // _headers + immutable caching for hashed assets, no-cache for entry.
  const headers = await fs.readFile(path.join(root, '_headers'), 'utf8');
  const cacheRules = `

/js/*
  Cache-Control: public, max-age=31536000, immutable
/css/*
  Cache-Control: public, max-age=31536000, immutable
/data/*
  Cache-Control: public, max-age=31536000, immutable
/i18n/*
  Cache-Control: public, max-age=86400
/index.html
  Cache-Control: no-cache
/404.html
  Cache-Control: no-cache
/
  Cache-Control: no-cache
/sw.js
  Cache-Control: no-cache
/build-manifest.json
  Cache-Control: no-cache
/version.json
  Cache-Control: public, max-age=300
/llms.txt
  Cache-Control: public, max-age=3600
`;
  await emit('_headers', headers.replace(/\s*$/, '') + cacheRules);

  console.log(`Built ${assetMap.size} assets to dist/.`);
  console.log(packSummary);
  console.log(`Build hash: ${bundleHash}`);
  console.log(`Commit: ${commit}`);
}

run().catch((e) => { console.error(e); process.exit(1); });
