// The app's translatable strings, assembled from the two places they live.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const HTML = new URL('../index.html', import.meta.url);
const COMMANDS = new URL('../js/modules/commands.js', import.meta.url);
const COMMAND_I18N = new URL('../js/modules/command-i18n.js', import.meta.url);

/// The command phrases, read from the two modules that define them. Missing
/// files are not fatal — the corpus simply loses that section.
async function loadCommandVocabulary() {
  try {
    const [commands, i18n] = await Promise.all([
      readFile(COMMANDS, 'utf8'),
      readFile(COMMAND_I18N, 'utf8'),
    ]);
    return parseCommandVocabulary(commands, i18n);
  } catch (_) {
    return [];
  }
}

/// Where the Flutter catalog is read from, best first. A sibling checkout of
/// the flutter-app repository is the authoring layout and always wins; the
/// release mirror in this repository is the fallback, because a build machine
/// (CI, Cloudflare Pages) only ever checks out this repository — and a build
/// that cannot see a catalog used to ship NO packs at all, which is far worse
/// than shipping ones a release behind. Override either with
/// NYM_FLUTTER_CATALOG.
export function catalogCandidates() {
  const out = [];
  if (process.env.NYM_FLUTTER_CATALOG) {
    out.push({ kind: 'override', path: process.env.NYM_FLUTTER_CATALOG });
  }
  out.push({
    kind: 'sibling',
    path: fileURLToPath(new URL(
      '../../flutter-app/lib/features/i18n/app_strings_catalog.dart', import.meta.url)),
  });
  out.push({
    kind: 'mirror',
    path: fileURLToPath(new URL(
      '../android-ios-app/lib/features/i18n/app_strings_catalog.dart', import.meta.url)),
  });
  return out;
}

/// The catalog the next [loadSources] would read. Kept for callers that only
/// want to name the file.
export const flutterCatalogPath = () => catalogCandidates()[0].path;

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
  // Skipped elements become a TAG, not a space. A space merged the text on
  // either side into one source string, but the browser sees two text nodes —
  // so a sentence with an inline <code> in it ("… two spellings — <code>npub1…
  // </code> and hex — …") was extracted as one string the DOM could never ask
  // for, and every fragment of it was translated live, forever.
  for (const tag of SKIP_ELEMENTS) {
    html = html.replace(new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*?</${tag}>`, 'gi'), '<skipped/>');
    // Self-closing / unterminated forms leave the opening tag behind; the tag
    // stripper below removes it.
  }
  html = html.replace(/<!--[\s\S]*?-->/g, '<skipped/>');

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

/// The slash/question command vocabulary, as the runtime asks for it.
///
/// `cmdI18nEnsure` (js/modules/command-i18n.js) translates one short phrase per
/// canonical command to build typeable aliases — "help", "private message",
/// "nickname". Sixty-odd of them, and nothing pre-translated them, so choosing a
/// language fired sixty requests at the proxy before the app had said anything.
/// Mirrors `_cmdI18nCanonical`: alias entries and one-character tokens are not
/// translated, and NYM_CMD_SOURCE decides the phrase (null means "leave it").
export function parseCommandVocabulary(commandsSource, commandI18nSource) {
  const overrides = new Map();
  const start = commandI18nSource.indexOf('const NYM_CMD_SOURCE = {');
  if (start >= 0) {
    const block = commandI18nSource.slice(start, commandI18nSource.indexOf('\n};', start));
    for (const m of block.matchAll(/'([^']+)'\s*:\s*(?:'((?:[^'\\]|\\.)*)'|(null))/g)) {
      overrides.set(m[1], m[3] ? null : m[2].replace(/\\'/g, "'"));
    }
  }

  const out = [];
  const seen = new Set();
  for (const table of ['botCommands', 'botPMCommands', 'commands']) {
    const at = commandsSource.indexOf(`this.${table} = {`);
    if (at < 0) continue;
    const block = commandsSource.slice(at, commandsSource.indexOf('\n        };', at));
    // One entry per line, anchored at the indentation, so a token that appears
    // inside a handler body is not mistaken for a command.
    for (const m of block.matchAll(/^\s+'([/?][^']+)':(.*)$/gm)) {
      const [, token, rest] = m;
      if (/\baliasOf\b/.test(rest)) continue;
      if (token.length <= 2) continue;
      if (seen.has(token)) continue;
      seen.add(token);
      const phrase = overrides.has(token) ? overrides.get(token) : token.slice(1);
      if (phrase && isTranslatable(phrase)) out.push(phrase);
    }
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

/// Whitespace, as the runtime sees it. The served markup is minified with
/// `collapseWhitespace`, so a string the author wrapped over three source lines
/// reaches the DOM as one space-separated run. Extracting it verbatim produced a
/// key no text node could ever equal, so those strings — the long onboarding
/// paragraphs, mostly — were never found in the pack.
export const collapseSpace = (text) => String(text).replace(/\s+/g, ' ').trim();

/// Placeholders and embedded numbers, matched in ONE pass so a sentinel this
/// replacement just wrote is never itself tokenised — two passes turned
/// "+{n} more" into "+PLHPLH1PLHPLH more", which no fill could put a number
/// back into. Mirrors NYM_I18N_TOKEN_RE in js/modules/i18n.js.
const TOKEN_RE = /\{[^}]+\}|\d[\d.,:/%+-]*/g;

/// A source string as the runtime KEYS it (`_i18nMakeKey`, js/modules/i18n.js):
/// whitespace collapsed, then {placeholders} and embedded numbers swapped for
/// PLH sentinels so "42 active nyms" and "43 active nyms" share one entry.
/// The cache is keyed by the raw English string — that is what the Flutter app
/// and the sync both use — so the conversion happens here, when the pack is
/// built, rather than in either client.
export function makeKey(core) {
  const tokens = [];
  const key = collapseSpace(core).replace(TOKEN_RE, (m) => {
    tokens.push(m);
    return `PLH${tokens.length - 1}PLH`;
  });
  return { key, tokens };
}

/// One cache entry as the pack ships it: `[key, template]`, both in the form the
/// runtime looks up and fills in. Returns null when the translation cannot be
/// templated — a translator that localised a numeral or dropped a {placeholder}
/// leaves nothing to substitute back, and a template that renders a sentinel or
/// a stale number on screen is worse than the live translation the client falls
/// back to.
export function packEntry(source, translated) {
  if (typeof source !== 'string' || typeof translated !== 'string') return null;
  const { key, tokens } = makeKey(source);
  const value = collapseSpace(translated);
  if (!key || !value) return null;
  if (tokens.length === 0) return [key, value];

  // Find each of the source's tokens in the translation and put a sentinel where
  // it sits. Matching the literal token rather than re-tokenising the
  // translation keeps the near misses a translator introduces — a trailing full
  // stop on a year, an ellipsis after a number — and the digit guard stops a
  // short token from being found inside a longer number. Position is not
  // assumed: a translation is free to reorder what it was given.
  const claimed = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    let at = -1;
    for (let from = 0; from <= value.length - token.length;) {
      const found = value.indexOf(token, from);
      if (found < 0) break;
      const end_ = found + token.length;
      const splitsANumber = /\d/.test(value[found - 1] || '') || /\d/.test(value[end_] || '');
      const taken = claimed.some((c) => found < c.end && end_ > c.at);
      if (!splitsANumber && !taken) { at = found; break; }
      from = found + 1;
    }
    // Nowhere to substitute back into: the translator dropped the placeholder
    // ("Added {nym} as a friend" -> "Agregado como un amigo") or localised it
    // ("{options}" -> "{opciones}"). Shipping that would put a name-less or
    // sentinel-carrying string on screen, so the client translates it live —
    // where the sentinel form is what gets sent, and survives.
    if (at < 0) return null;
    claimed.push({ at, end: at + token.length, index: i });
  }

  claimed.sort((a, b) => a.at - b.at);
  let template = '';
  let cursor = 0;
  for (const slot of claimed) {
    template += value.slice(cursor, slot.at) + `PLH${slot.index}PLH`;
    cursor = slot.end;
  }
  return [key, template + value.slice(cursor)];
}

/// Every source string, deduped and sorted so a re-run produces no spurious
/// diff in the committed cache.
///
/// The Flutter catalog is looked for in each of [catalogCandidates] in turn.
/// Missing entirely, this returns the markup's strings alone rather than
/// throwing: a pack covering half the app still spares every user half the
/// translation requests, and `counts.dartKind` tells the caller what it got so
/// it can say so.
export async function loadSources({ catalogPath } = {}) {
  const candidates = catalogPath
    ? [{ kind: 'override', path: catalogPath }]
    : catalogCandidates();

  let dartSrc = null;
  let dartPath = null;
  let dartKind = 'none';
  const tried = [];
  for (const candidate of candidates) {
    try {
      dartSrc = await readFile(candidate.path, 'utf8');
      dartPath = candidate.path;
      dartKind = candidate.kind;
      break;
    } catch (_) {
      tried.push(candidate.path);
    }
  }

  const htmlSrc = await readFile(HTML, 'utf8');
  const fromDart = dartSrc ? parseDartCatalog(dartSrc) : [];
  const fromHtml = parseHtml(htmlSrc);
  const fromCommands = await loadCommandVocabulary();
  const all = new Set([...fromDart, ...fromHtml, ...fromCommands]);
  return {
    sources: [...all].sort(),
    counts: {
      dart: fromDart.length,
      html: fromHtml.length,
      commands: fromCommands.length,
      total: all.size,
      dartPath,
      dartKind,
      triedPaths: tried,
    },
    unknownEntities: undecodedEntities(htmlSrc),
  };
}
