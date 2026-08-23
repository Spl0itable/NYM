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
  + `(${counts.dart} from ${counts.dartPath}, ${counts.html} from index.html), `
  + `${targets.length} languages`);

if (unknownEntities.length > 0) {
  // Left encoded, these produce source strings the runtime will never match,
  // so the containing string is silently never found in the pack.
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

// This run takes hours and spends most of it waiting on a rate-limited upstream,
// so the difference between "working" and "wedged" has to be visible without
// attaching a debugger. Every language prints the moment it starts, progress
// refreshes on a timer rather than at string counts, and the slow parts — route
// selection, throttle backoffs — announce themselves.
console.log(`\ntranslating (${targets.length} languages, ~${sources.length} strings each)\n`);

let line = '';
const draw = (text) => {
  line = text;
  process.stdout.write(`\r${text.padEnd(72)}`);
};
// A notice outlives the progress line it interrupts, so it gets its own row and
// the progress line is redrawn under it.
onNotice((text) => {
  process.stdout.write(`\r${''.padEnd(72)}\r  ${text}\n`);
  if (line) process.stdout.write(`\r${line.padEnd(72)}`);
});

// Progress used to print on `done % 25`, which the batched route steps straight
// over: it advances 20 strings at a time, so most languages printed nothing at
// all until they finished. Time is the honest axis here anyway — what the
// reader wants to know is that something moved recently, not that a round
// number was crossed.
const TICK_MS = 400;

let failed = 0;
for (const [i, lang] of targets.entries()) {
  const at = `[${String(i + 1).padStart(3)}/${targets.length}]`;
  const label = `${lang.code.padEnd(7)}${lang.name}`;
  draw(`  ${at} ${label}  starting…`);
  const started = Date.now();
  let last = 0;
  try {
    const { translated } = await translateMissing(lang.code, sources, {
      onProgress: (done, total) => {
        const now = Date.now();
        if (done !== total && now - last < TICK_MS) return;
        last = now;
        const pct = Math.floor((done / total) * 100);
        draw(`  ${at} ${label}  ${done}/${total} (${pct}%)  ${Math.round((now - started) / 1000)}s`);
      },
    });
    const took = Math.round((Date.now() - started) / 1000);
    draw(`  ${at} ${label}  ${translated === 0 ? 'cached' : `+${translated} in ${took}s`}`);
    process.stdout.write('\n');
    line = '';
  } catch (err) {
    failed++;
    draw(`  ${at} ${label}  FAILED`);
    process.stdout.write('\n');
    line = '';
    console.error(`    ${err.message}`);
  }
}

console.log(`\nroute: ${activeRoute()}`);
if (failed > 0) {
  // Partial progress is kept, so a re-run resumes rather than restarting.
  console.log(`${failed} language(s) incomplete — re-run to finish; cached strings are not re-sent.`);
  process.exit(1);
}
console.log('All languages cached. Commit i18n/cache/, then ship it to both clients:');
console.log('  npm run build                                              # web: dist/i18n/');
console.log('  npm run i18n:export -- --out ../flutter-app/assets/i18n    # app: bundled assets');
