// Fills i18n/cache/<lang>.json for every language the app offers.

import { loadLanguages } from './languages.mjs';
import { loadSources } from './strings.mjs';
import { activeRoute, loadCache, onNotice, translateMissing } from './translate.mjs';

const args = process.argv.slice(2);
const only = (args.find((a) => a.startsWith('--only=')) || '').slice('--only='.length);
const listOnly = args.includes('--list');
const wanted = only ? new Set(only.split(',').map((s) => s.trim())) : null;

const { sources, counts, unknownEntities } = await loadSources();
const languages = await loadLanguages();
const targets = languages.filter((l) => !wanted || wanted.has(l.code));

console.log(
  `${counts.total} source strings `
  + `(${counts.dart} from ${counts.dartPath || 'no Flutter catalog'}, `
  + `${counts.html} from index.html), `
  + `${targets.length} languages`);

// The sync pays for translations, so an incomplete corpus here leaves strings untranslated until the next run.
if (counts.dartKind === 'mirror') {
  console.warn(
    `\nReading the app strings from flutter/, this repository's release`
    + `\nmirror — it can be a release behind, so strings added since the last`
    + `\nmirror update will not be translated. Check out flutter-app beside this`
    + `\nrepository (or set NYM_FLUTTER_CATALOG) to sync against the live catalog.\n`);
} else if (counts.dartKind === 'none') {
  console.warn(
    `\nNo Flutter string catalog found, so only index.html is being translated`
    + `\n(tried: ${counts.triedPaths.join(', ')}).\n`);
}

if (unknownEntities.length > 0) {
  // Left encoded, these never match runtime source strings.
  console.warn(
    `\nindex.html uses HTML entities this extractor does not decode: ${unknownEntities.join(' ')}`
    + `\nAdd them to ENTITIES in i18n/strings.mjs, or those strings will not be pre-translated.\n`);
}

if (listOnly) {
  let complete = 0;
  for (const lang of targets) {
    const cache = await loadCache(lang.code);
    const have = sources.filter((s) => typeof cache[s] === 'string').length;
    if (have === sources.length) complete++;
    else console.log(`  ${lang.code.padEnd(7)} ${have}/${sources.length}  ${lang.name}`);
  }
  console.log(`${complete}/${targets.length} languages fully cached`);
  process.exit(0);
}

// Hours-long and rate-limited, so progress and slow phases must be visible.
console.log(`\ntranslating (${targets.length} languages, ~${sources.length} strings each)\n`);

let line = '';
const draw = (text) => {
  line = text;
  process.stdout.write(`\r${text.padEnd(72)}`);
};
// A notice gets its own row and the progress line is redrawn under it.
onNotice((text) => {
  process.stdout.write(`\r${''.padEnd(72)}\r  ${text}\n`);
  if (line) process.stdout.write(`\r${line.padEnd(72)}`);
});

// Time-based ticks: the batched route advances 20 strings at a time.
const TICK_MS = 400;

// Languages share nothing, so they overlap; per-language batch concurrency nests under this.
const LANG_CONCURRENCY = Number(process.env.NYM_I18N_LANG_CONCURRENCY || 8);

let failed = 0;
let started_ = 0;
let done_ = 0;
const runStarted = Date.now();

async function runLang(lang, i) {
  const at = `[${String(i + 1).padStart(3)}/${targets.length}]`;
  const label = `${lang.code.padEnd(7)}${lang.name}`;
  const started = Date.now();
  try {
    const { translated } = await translateMissing(lang.code, sources);
    const took = Math.round((Date.now() - started) / 1000);
    done_++;
    draw(`  ${at} ${label}  ${translated === 0 ? 'cached' : `+${translated} in ${took}s`}`);
    process.stdout.write('\n');
    line = '';
  } catch (err) {
    failed++;
    done_++;
    draw(`  ${at} ${label}  FAILED`);
    process.stdout.write('\n');
    line = '';
    console.error(`    ${err.message}`);
  }
}

// A shared heartbeat, since per-language progress lines would fight for the same row.
const ticker = setInterval(() => {
  const secs = Math.round((Date.now() - runStarted) / 1000);
  draw(`  ${done_}/${targets.length} languages  ${secs}s elapsed`);
}, TICK_MS * 2);

{
  const queue = targets.map((lang, i) => ({ lang, i }));
  const worker = async () => {
    for (;;) {
      const next = queue.shift();
      if (!next) return;
      started_++;
      await runLang(next.lang, next.i);
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(LANG_CONCURRENCY, queue.length) }, worker));
}
clearInterval(ticker);

console.log(`\nroute: ${activeRoute()}`);
if (failed > 0) {
  // Partial progress is kept, so a re-run resumes rather than restarting.
  console.log(`${failed} language(s) incomplete — re-run to finish; cached strings are not re-sent.`);
  process.exit(1);
}
console.log('All languages cached. Commit i18n/cache/, then ship it to both clients:');
console.log('  npm run build                                              # web: dist/i18n/');
console.log('  npm run i18n:export -- --out ../flutter-app/assets/i18n    # app: bundled assets');
