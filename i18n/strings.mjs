// The app's translatable strings, assembled from the two places they live.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const HTML = new URL('../index.html', import.meta.url);

/// Where the Flutter catalog is read from. Defaults to a sibling checkout of
/// the flutter-app repository, which is the usual layout; override with
/// NYM_FLUTTER_CATALOG to point somewhere else.
export const flutterCatalogPath = () =>
  process.env.NYM_FLUTTER_CATALOG
  || fileURLToPath(new URL(
    '../../flutter-app/lib/features/i18n/app_strings_catalog.dart', import.meta.url));

/// Elements whose contents are never prose. Mirrors the runtime's skip list
/// (`NYM_I18N_SKIP_SELECTOR`, js/modules/i18n.js) for the cases a regex can see.
const SKIP_ELEMENTS = ['script', 'style', 'svg', 'pre', 'code', 'kbd', 'samp'];

/// Attributes carrying visible UI text. Same list the runtime translates
/// (`NYM_I18N_ATTRS`).
const TEXT_ATTRIBUTES = ['placeholder', 'data-placeholder', 'title', 'aria-label'];

/// The runtime's own test for whether a string is worth translating
/// (`_i18nTextTranslatable`): real words, not just digits or punctuation.
export function isTranslatable(text) {
  if (typeof text !== 'string') return false;
  const t = text.trim();
  if (t.length < 2) return false;
  if (!/\p{L}/u.test(t)) return false;
  return true;
}

/// The `kAppStringsCatalog` entries. Parsed rather than evaluated: the file is a
/// flat list of single-quoted Dart literals, and running a Dart toolchain to
/// read a list of strings would be a lot of machinery for no more accuracy.
export function parseDartCatalog(source) {
  const start = source.indexOf('kAppStringsCatalog = <String>[');
  if (start < 0) throw new Error('kAppStringsCatalog not found');
  const end = source.indexOf('\n];', start);
  if (end < 0) throw new Error('kAppStringsCatalog is not terminated');
  const body = source.slice(start, end);

  const out = [];
  // A single-quoted Dart literal, honouring \' escapes. Comment lines have no
  // quoted literal on them, so they fall out for free.
  const rx = /'((?:[^'\\]|\\.)*)'/g;
  let m;
  while ((m = rx.exec(body)) !== null) {
    const literal = m[1]
      .replace(/\\'/g, "'")
      .replace(/\\"/g, '"')
      .replace(/\\n/g, '\n')
      .replace(/\\t/g, '\t')
      .replace(/\\\\/g, '\\');
    if (isTranslatable(literal)) out.push(literal);
  }
  return out;
}

/// The visible text and translatable attributes in the app shell's markup.
export function parseHtml(source) {
  let html = source;
  for (const tag of SKIP_ELEMENTS) {
    html = html.replace(new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*?</${tag}>`, 'gi'), ' ');
    // Self-closing / unterminated forms leave the opening tag behind; the tag
    // stripper below removes it.
  }
  html = html.replace(/<!--[\s\S]*?-->/g, ' ');

  const out = [];

  // Attributes first, before the tags are stripped away.
  for (const attr of TEXT_ATTRIBUTES) {
    const rx = new RegExp(`\\b${attr}="([^"]*)"`, 'gi');
    let m;
    while ((m = rx.exec(html)) !== null) {
      const value = decodeEntities(m[1]);
      if (isTranslatable(value)) out.push(value.trim());
    }
  }

  // Then the text between tags. Split on tags rather than parsing: this is one
  // hand-written document, and each run between two tags is what the runtime
  // sees as a text node.
  for (const chunk of html.split(/<[^>]*>/)) {
    const value = decodeEntities(chunk).trim();
    if (isTranslatable(value)) out.push(value);
  }
  return out;
}

/// Named entities, decoded so the extracted string matches what the runtime
/// sees. This is the one place a mistake is silent rather than loud: an entity
/// left encoded produces a source string no DOM text node will ever equal, so
/// that string is never found in the pack and is quietly translated one request
/// at a time forever. [undecodedEntities] exists to make that loud instead.
const ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0',
  copy: '\u00a9', reg: '\u00ae', trade: '\u2122', deg: '\u00b0', plusmn: '\u00b1',
  ndash: '\u2013', mdash: '\u2014', hellip: '\u2026', times: '\u00d7', divide: '\u00f7',
  middot: '\u00b7', bull: '\u2022', dagger: '\u2020', para: '\u00b6', sect: '\u00a7',
  laquo: '\u00ab', raquo: '\u00bb', lsquo: '\u2018', rsquo: '\u2019',
  ldquo: '\u201c', rdquo: '\u201d', larr: '\u2190', rarr: '\u2192', harr: '\u2194',
  check: '\u2713', euro: '\u20ac', pound: '\u00a3', yen: '\u00a5', cent: '\u00a2',
  // Latin-1 letters — the ones a UI string realistically carries.
  agrave: '\u00e0', aacute: '\u00e1', acirc: '\u00e2', atilde: '\u00e3',
  auml: '\u00e4', aring: '\u00e5', aelig: '\u00e6', ccedil: '\u00e7',
  egrave: '\u00e8', eacute: '\u00e9', ecirc: '\u00ea', euml: '\u00eb',
  igrave: '\u00ec', iacute: '\u00ed', icirc: '\u00ee', iuml: '\u00ef',
  ntilde: '\u00f1', ograve: '\u00f2', oacute: '\u00f3', ocirc: '\u00f4',
  otilde: '\u00f5', ouml: '\u00f6', oslash: '\u00f8', ugrave: '\u00f9',
  uacute: '\u00fa', ucirc: '\u00fb', uuml: '\u00fc', yacute: '\u00fd',
  yuml: '\u00ff', szlig: '\u00df',
  Agrave: '\u00c0', Aacute: '\u00c1', Acirc: '\u00c2', Atilde: '\u00c3',
  Auml: '\u00c4', Aring: '\u00c5', AElig: '\u00c6', Ccedil: '\u00c7',
  Egrave: '\u00c8', Eacute: '\u00c9', Ecirc: '\u00ca', Euml: '\u00cb',
  Igrave: '\u00cc', Iacute: '\u00cd', Icirc: '\u00ce', Iuml: '\u00cf',
  Ntilde: '\u00d1', Ograve: '\u00d2', Oacute: '\u00d3', Ocirc: '\u00d4',
  Otilde: '\u00d5', Ouml: '\u00d6', Oslash: '\u00d8', Ugrave: '\u00d9',
  Uacute: '\u00da', Ucirc: '\u00db', Uuml: '\u00dc', Yacute: '\u00dd',
};

/// Named entities present in [text] that this file does not know how to decode.
/// The sync reports them so an unfamiliar entity is caught when it is added,
/// rather than by nobody noticing one string is never translated.
export function undecodedEntities(text) {
  const out = new Set();
  for (const m of text.matchAll(/&([a-zA-Z][a-zA-Z0-9]*);/g)) {
    if (!(m[1] in ENTITIES)) out.add(m[0]);
  }
  return [...out];
}

function decodeEntities(text) {
  return text
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCodePoint(parseInt(code, 16)))
    .replace(/&([a-z]+);/gi, (whole, name) => ENTITIES[name] ?? whole);
}

/// Every source string, deduped and sorted so a re-run produces no spurious
/// diff in the committed cache.
export async function loadSources({ catalogPath } = {}) {
  const dartPath = catalogPath || flutterCatalogPath();
  let dartSrc;
  try {
    dartSrc = await readFile(dartPath, 'utf8');
  } catch (err) {
    throw new Error(
      `cannot read the Flutter string catalog at ${dartPath}\n`
      + `  It lives in the flutter-app repository — check it out beside this one,\n`
      + `  or set NYM_FLUTTER_CATALOG to its app_strings_catalog.dart.\n`
      + `  (android-ios-app/ in this repo is a read-only release mirror and is\n`
      + `  deliberately NOT used: packs built from it would be a release behind.)`);
  }
  const htmlSrc = await readFile(HTML, 'utf8');
  const fromDart = parseDartCatalog(dartSrc);
  const fromHtml = parseHtml(htmlSrc);
  const all = new Set([...fromDart, ...fromHtml]);
  return {
    sources: [...all].sort(),
    counts: {
      dart: fromDart.length,
      html: fromHtml.length,
      total: all.size,
      dartPath,
    },
    unknownEntities: undecodedEntities(htmlSrc),
  };
}
