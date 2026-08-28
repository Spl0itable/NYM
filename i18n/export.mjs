// Writes the translated packs out as files

import { mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { loadLanguages } from './languages.mjs';
import { loadSources } from './strings.mjs';
import { cachePath } from './translate.mjs';

const args = process.argv.slice(2);
const flagged = args.indexOf('--out');
const outArg = (args.find((a) => a.startsWith('--out=')) || '').slice('--out='.length)
  || (flagged >= 0 ? args[flagged + 1] : '');
if (!outArg || outArg.startsWith('--')) {
  console.error('usage: npm run i18n:export -- --out <directory>');
  console.error('  e.g. npm run i18n:export -- --out ../flutter-app/assets/i18n');
  process.exit(1);
}
const outDir = path.resolve(outArg);

const { sources, counts } = await loadSources();
const languages = await loadLanguages();
const live = new Set(sources);

await mkdir(outDir, { recursive: true });

// Clear packs for languages that no longer exist, so a removed language does
// not linger in the app bundle forever.
const known = new Set(languages.map((l) => `${l.code}.json`));
for (const name of await readdir(outDir).catch(() => [])) {
  if (name.endsWith('.json') && !known.has(name)) {
    await rm(path.join(outDir, name));
    console.log(`  removed ${name} (no longer an offered language)`);
  }
}

let written = 0;
let complete = 0;
let bytes = 0;
const partial = [];

for (const lang of languages) {
  let cache;
  try {
    cache = JSON.parse(await readFile(cachePath(lang.code), 'utf8'));
  } catch {
    continue; // Nothing translated for this language yet.
  }
  // Only strings still in the app: a stale entry ships a translation for copy
  // nobody can reach, and grows every install.
  const pack = {};
  let have = 0;
  for (const [source, translated] of Object.entries(cache)) {
    if (!live.has(source) || typeof translated !== 'string' || !translated) continue;
    pack[source] = translated;
    have++;
  }
  if (have === 0) continue;
  const body = JSON.stringify(pack);
  await writeFile(path.join(outDir, `${lang.code}.json`), body);
  written++;
  bytes += Buffer.byteLength(body);
  if (have === sources.length) complete++;
  else partial.push(`${lang.code} ${have}/${sources.length}`);
}

console.log(`${counts.total} source strings -> ${outDir}`);
// These packs are keyed by the raw English string, which is what the Flutter
// runtime looks up — unlike the web packs the build writes, which are keyed the
// way js/modules/i18n.js keys its cache. Do not converge the two.
if (counts.dartKind === 'mirror') {
  console.warn(
    `  read from android-ios-app/, this repository's release mirror — it can be a`
    + `\n  release behind. Check out flutter-app beside this repository (or set`
    + `\n  NYM_FLUTTER_CATALOG) to export against the live catalog.`);
} else if (counts.dartKind === 'none') {
  console.warn('  no Flutter string catalog found — exporting index.html strings only.');
}
if (written === 0) {
  console.log('  nothing to export — run `npm run i18n` first.');
  process.exit(1);
}
console.log(`  ${written} languages, ${complete} complete`);
if (partial.length) {
  // Not a failure: the app falls back to translating on demand for whatever a
  // pack is missing. Worth naming so a half-finished run is not mistaken for a
  // finished one.
  console.log(`  partial: ${partial.slice(0, 8).join(', ')}${partial.length > 8 ? ` (+${partial.length - 8} more)` : ''}`);
}
console.log(`  ${(bytes / 1024 / 1024).toFixed(1)} MB total, ${(bytes / written / 1024).toFixed(0)} KB per language`);
