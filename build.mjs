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

  // Minify + hash every JS file under js/.
  for (const file of await walk(path.join(root, 'js'))) {
    if (!file.endsWith('.js')) continue;
    const rel = toPosix(path.relative(root, file));
    const src = await fs.readFile(file, 'utf8');
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

  for (const file of await walk(path.join(root, 'static'))) {
    const rel = toPosix(path.relative(root, file));
    if (file.endsWith('.html')) {
      const out = await minifyHtml(rewriteHtml(await fs.readFile(file, 'utf8')), htmlMinifyOptions);
      await emit(rel, out);
      manifestFiles['/' + rel] = sha256b64(Buffer.from(out));
    } else await emit(rel, await fs.readFile(file));
  }

  // robots.txt verbatim.
  await emit('robots.txt', await fs.readFile(path.join(root, 'robots.txt')));

  // Service worker: stamp a per-build cache version so each deploy gets a fresh
  // cache and old ones are pruned on activate.
  const swVersion = sha8([...assetMap.values()].sort().join('|'));

  // Critical shell assets to precache on SW install (hashed names)
  const criticalSources = [
    'css/styles-core.css', 'css/styles-shell.css', 'css/styles-chat.css',
    'css/styles-components.css', 'css/styles-themes-responsive.css', 'css/no-inline.css',
    'js/defer-css.js', 'js/theme-init.js', 'js/setup-modal-init.js',
    'js/modules/inline-bindings.js', 'js/modules/dialog.js', 'js/nostr-tools.js',
    'js/app.js', 'js/nym-crypto.js', 'js/modules/crypto-pool.js',
    'js/modules/persistence.js', 'js/modules/key-vault.js', 'js/modules/panic.js',
    'js/modules/relays.js', 'js/modules/nostr-core.js', 'js/modules/users.js',
    'js/modules/channels.js', 'js/modules/syntax-highlight.js', 'js/modules/messages.js',
    'js/modules/pms.js', 'js/modules/groups.js', 'js/modules/ui-context.js',
    'js/modules/init.js', 'js/modules/build-verify.js', 'js/modules/canary-verify.js',
  ];
  const precache = criticalSources
    .map((rel) => assetMap.get(rel))
    .filter(Boolean)
    .map((hashed) => '/' + hashed);

  const swSrc = await fs.readFile(path.join(root, 'sw.js'), 'utf8');
  await emit('sw.js', swSrc
    .replace('__CACHE_VERSION__', swVersion)
    .replace('__PRECACHE_ASSETS__', JSON.stringify(precache)));

  // Build manifest: lets the app re-hash its own running bundle and lets anyone
  // reproduce bundleHash from source at `commit`. bundleHash is derived only
  // from the content-hashed asset set, so it is identical across reproducible
  // rebuilds of the same source.
  const bundleHash = crypto.createHash('sha256')
    .update(Object.keys(manifestFiles).sort().map((p) => p + ':' + manifestFiles[p]).join('\n'))
    .digest('hex');
  const commit = gitCommit();
  await emit('build-manifest.json', JSON.stringify({
    app: 'nymchat',
    commit,
    builtAt: new Date().toISOString(),
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
/static/*
  Cache-Control: public, max-age=86400
/index.html
  Cache-Control: no-cache
/
  Cache-Control: no-cache
/sw.js
  Cache-Control: no-cache
/build-manifest.json
  Cache-Control: no-cache
`;
  await emit('_headers', headers.replace(/\s*$/, '') + cacheRules);

  console.log(`Built ${assetMap.size} assets to dist/.`);
  console.log(`Build hash: ${bundleHash}`);
  console.log(`Commit: ${commit}`);
}

run().catch((e) => { console.error(e); process.exit(1); });
