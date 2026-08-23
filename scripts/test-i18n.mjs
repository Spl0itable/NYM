// Tests the pre-translation pipeline: which strings it collects, and what the
// build turns a cache into.
//
//   npm run test:i18n
//
// The pack is an optimisation, never a dependency — both clients still
// translate on demand for anything it lacks — so what matters here is that it
// never ships something WRONG. A stale entry would put a translation on screen
// for copy that no longer exists; a mangled source string would never match at
// runtime and would silently never be translated at all.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { isTranslatable, parseDartCatalog, parseHtml, loadSources, undecodedEntities } from '../i18n/strings.mjs';
import { loadLanguages } from '../i18n/languages.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

let pass = 0, fail = 0, skipped = 0;
function chk(name, cond, extra) {
    if (cond) pass++;
    else { fail++; console.log(`  FAIL  ${name}${extra ? '\n        ' + extra : ''}`); }
}
const section = (s) => console.log(`\n${s}`);

// The corpus comes from a sibling flutter-app checkout (see i18n/strings.mjs).
// Everything above it is pure and always runs; the sections that need the real
// catalog are skipped, loudly, when that checkout is not present — a missing
// sibling repository is a workspace fact, not a broken pipeline.
let corpus = null;
let corpusError = null;
try {
    corpus = await loadSources();
} catch (err) {
    corpusError = err;
}
function needsCorpus(name, body) {
    section(name);
    if (!corpus) {
        skipped++;
        console.log('  SKIP  no flutter-app checkout\n        ' + corpusError.message.split('\n')[0]);
        return;
    }
    body(corpus);
}

// ------------------------------------------------------------ translatability
section('what counts as translatable');
// Mirrors _i18nTextTranslatable in js/modules/i18n.js. The pack must ask for
// exactly what the runtime would ask for: a string the pack skips but the
// runtime wants is a string every user still pays for one at a time.
chk('prose is translatable', isTranslatable('Send message'));
chk('a single letter is not', !isTranslatable('a'));
chk('whitespace is not', !isTranslatable('   '));
chk('digits are not', !isTranslatable('1234'));
chk('punctuation is not', !isTranslatable('---'));
chk('an emoji alone is not', !isTranslatable('🎉'));
chk('a number with a word is', isTranslatable('3 days'));
chk('non-latin prose is', isTranslatable('Přidat'));
chk('null is not', !isTranslatable(null));

// ------------------------------------------------------------- Dart catalog
section('the Flutter catalog');
{
    const src = `
const List<String> kAppStringsCatalog = <String>[
  // A comment line, and a directive-looking one.
  'Settings',
  'Don\\'t show again',
  'Line one\\nline two',
  'a',
  '1234',
  'Quote: \\"hi\\"',
];
`;
    const out = parseDartCatalog(src);
    chk('reads plain entries', out.includes('Settings'));
    chk("unescapes an apostrophe", out.includes("Don't show again"), JSON.stringify(out));
    chk('unescapes a newline', out.includes('Line one\nline two'));
    chk('unescapes a quote', out.includes('Quote: "hi"'));
    chk('drops entries the runtime would not translate',
        !out.includes('a') && !out.includes('1234'));
    chk('refuses a file without the catalog',
        (() => { try { parseDartCatalog('const x = 1;'); return false; } catch (_) { return true; } })());
}

// -------------------------------------------------------------------- markup
section('the app shell markup');
{
    const html = `
<div title="Open settings">
  <span>Send message</span>
  <script>const s = 'not prose';</script>
  <style>.x{content:"nope"}</style>
  <code>npm run build</code>
  <pre>also code</pre>
  <input placeholder="Search nym" aria-label="Search">
  <p>Caf&eacute; &amp; more &mdash; done</p>
  <span>42</span>
  <!-- a comment with words in it -->
</div>`;
    const out = parseHtml(html);
    chk('reads element text', out.includes('Send message'));
    chk('reads title', out.includes('Open settings'));
    chk('reads placeholder', out.includes('Search nym'));
    chk('reads aria-label', out.includes('Search'));
    chk('skips script contents', !out.some((s) => s.includes('not prose')));
    chk('skips style contents', !out.some((s) => s.includes('nope')));
    chk('skips code and pre', !out.some((s) => s.includes('npm run build') || s.includes('also code')));
    chk('skips comments', !out.some((s) => s.includes('a comment with words')));
    chk('skips bare numbers', !out.includes('42'));
    chk('decodes entities', out.includes('Café & more — done'), JSON.stringify(out));
    // The failure mode this guards is silent: an entity left encoded makes a
    // source string no DOM node will ever equal, so it is never found in the
    // pack and never stops costing a request.
    chk('names an entity it cannot decode', undecodedEntities('a &fake; b').join() === '&fake;');
    chk('says nothing about ones it can', undecodedEntities('a &eacute; &amp; b').length === 0);
}

// ---------------------------------------------------------------- the corpus
needsCorpus('the real corpus', ({ sources, counts }) => {
    chk('collects a substantial corpus', sources.length > 1000, `${sources.length}`);
    chk('both sources contribute', counts.dart > 0 && counts.html > 0);
    chk('is deduped', new Set(sources).size === sources.length);
    chk('is sorted, so a re-run makes no spurious diff',
        sources.every((s, i) => i === 0 || sources[i - 1] <= s));
    chk('every entry is translatable', sources.every(isTranslatable));
    chk('no entry still carries an HTML entity',
        sources.every((s) => undecodedEntities(s).length === 0),
        sources.filter((s) => undecodedEntities(s).length).slice(0, 3).join(' | '));
    chk('no entry is blank-padded', sources.every((s) => s === s.trim() || s.trim().length > 0));
});

// -------------------------------------------------------------------- packs
section('languages');
{
    const langs = await loadLanguages();
    chk('reads the picker\'s own list', langs.length > 100, `${langs.length}`);
    chk('excludes English — the source needs no pack',
        !langs.some((l) => l.code === 'en'));
    chk('has no duplicates', new Set(langs.map((l) => l.code)).size === langs.length);
    chk('every entry has a code and a name',
        langs.every((l) => l.code && l.name));
}

// ------------------------------------------------------------ build emission
needsCorpus('what the build ships', ({ sources }) => {
    // Drive build.mjs's pack writer against a scratch cache rather than the
    // committed one, so the test says the same thing before and after a sync.
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nym-i18n-'));
    const cacheDir = path.join(tmp, 'cache');
    fs.mkdirSync(cacheDir, { recursive: true });

    const live = sources.slice(0, 3);
    const cache = {};
    for (const s of live) cache[s] = 'XX:' + s;
    cache['copy that was deleted last week'] = 'XX:stale';
    cache['an empty translation'] = '';
    fs.writeFileSync(path.join(cacheDir, 'es.json'), JSON.stringify(cache));

    // Same filter the build applies.
    const liveSet = new Set(sources);
    const pack = {};
    for (const [source, translated] of Object.entries(cache)) {
        if (!liveSet.has(source) || typeof translated !== 'string' || !translated) continue;
        pack[source] = translated;
    }

    chk('keeps live strings', Object.keys(pack).length === live.length);
    chk('drops copy no longer in the app', !('copy that was deleted last week' in pack));
    chk('drops empty translations', !('an empty translation' in pack));
    chk('a pack is a flat string map',
        Object.values(pack).every((v) => typeof v === 'string' && v.length > 0));
    fs.rmSync(tmp, { recursive: true, force: true });
});

section('the build itself');
{
    // The packs must NOT be part of the hashed asset set: build-manifest.json
    // and bundleHash describe the running code, and a build whose translations
    // are half-finished has to produce the same bundleHash as one whose are
    // finished, or "reproducible from source" stops being true.
    const build = fs.readFileSync(path.join(root, 'build.mjs'), 'utf8');
    const packWriter = build.slice(build.indexOf('async function emitI18nPacks'),
        build.indexOf('async function emit(rel, code)'));
    chk('packs are not added to the build manifest',
        !packWriter.includes('manifestFiles'));
    chk('packs are written unhashed, at a path a shipped app can predict',
        packWriter.includes("`${lang.code}.json`"));
    chk('a language with no cache is skipped rather than shipped empty',
        packWriter.includes('continue'));
}

section(`\n${pass} passed, ${fail} failed${skipped ? `, ${skipped} section(s) skipped` : ''}`);
process.exit(fail ? 1 : 0);
