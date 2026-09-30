// The app's translatable strings, assembled from the two places they live.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const HTML = new URL('../index.html', import.meta.url);
const COMMANDS = new URL('../js/modules/commands.js', import.meta.url);
const COMMAND_I18N = new URL('../js/modules/command-i18n.js', import.meta.url);

// Missing files are not fatal; the corpus simply loses that section.
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

// Sibling flutter-app checkout first, then the in-repo mirror CI can see; NYM_FLUTTER_CATALOG overrides.
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
      '../flutter/lib/features/i18n/app_strings_catalog.dart', import.meta.url)),
  });
  return out;
}

// The catalog the next [loadSources] would read.
export const flutterCatalogPath = () => catalogCandidates()[0].path;

// Mirrors the runtime's skip list (`NYM_I18N_SKIP_SELECTOR`, js/modules/i18n.js).
const SKIP_ELEMENTS = ['script', 'style', 'svg', 'pre', 'code', 'kbd', 'samp'];

// Same list the runtime translates (`NYM_I18N_ATTRS`).
const TEXT_ATTRIBUTES = ['placeholder', 'data-placeholder', 'title', 'aria-label'];

// Mirrors the runtime's `_i18nTextTranslatable`: real words, not just digits or punctuation.
export function isTranslatable(text) {
  if (typeof text !== 'string') return false;
  const t = text.trim();
  if (t.length < 2) return false;
  if (!/\p{L}/u.test(t)) return false;
  return true;
}

// Parsed rather than evaluated: the file is a flat list of single-quoted Dart literals.
export function parseDartCatalog(source) {
  const start = source.indexOf('kAppStringsCatalog = <String>[');
  if (start < 0) throw new Error('kAppStringsCatalog not found');
  const end = source.indexOf('\n];', start);
  if (end < 0) throw new Error('kAppStringsCatalog is not terminated');
  const body = source.slice(start, end);

  const out = [];
  // A single-quoted Dart literal, honoring \' escapes; comment lines fall out for free.
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

export function parseHtml(source) {
  let html = source;
  // Skipped elements become a tag, not a space, since the browser sees separate text nodes.
  for (const tag of SKIP_ELEMENTS) {
    html = html.replace(new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*?</${tag}>`, 'gi'), '<skipped/>');
    // Self-closing / unterminated forms leave the opening tag behind; the tag stripper removes it.
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

  // Each run between two tags is what the runtime sees as a text node.
  for (const chunk of html.split(/<[^>]*>/)) {
    const value = decodeEntities(chunk).trim();
    if (isTranslatable(value)) out.push(value);
  }
  return out;
}

// Pre-translates `cmdI18nEnsure`'s phrases; mirrors `_cmdI18nCanonical` (aliases and 1-char tokens skipped).
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
    // Anchored at the indentation so tokens inside handler bodies aren't mistaken for commands.
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

// An entity left encoded silently never matches the DOM; [undecodedEntities] makes that loud.
const ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0',
  copy: '\u00a9', reg: '\u00ae', trade: '\u2122', deg: '\u00b0', plusmn: '\u00b1',
  ndash: '\u2013', mdash: '\u2014', hellip: '\u2026', times: '\u00d7', divide: '\u00f7',
  middot: '\u00b7', bull: '\u2022', dagger: '\u2020', para: '\u00b6', sect: '\u00a7',
  laquo: '\u00ab', raquo: '\u00bb', lsquo: '\u2018', rsquo: '\u2019',
  ldquo: '\u201c', rdquo: '\u201d', larr: '\u2190', rarr: '\u2192', harr: '\u2194',
  check: '\u2713', euro: '\u20ac', pound: '\u00a3', yen: '\u00a5', cent: '\u00a2',
  // Latin-1 letters, the ones a UI string realistically carries.
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

// The sync reports them so an unfamiliar entity is caught when it is added.
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

// Served markup is minified with `collapseWhitespace`, so keys must match.
export const collapseSpace = (text) => String(text).replace(/\s+/g, ' ').trim();

// One pass so a just-written sentinel is never re-tokenized; mirrors NYM_I18N_TOKEN_RE in js/modules/i18n.js.
const TOKEN_RE = /\{[^}]+\}|\d[\d.,:/%+-]*/g;

// Matches `_i18nMakeKey` (js/modules/i18n.js): whitespace collapsed, placeholders/numbers become PLH sentinels.
export function makeKey(core) {
  const tokens = [];
  const key = collapseSpace(core).replace(TOKEN_RE, (m) => {
    tokens.push(m);
    return `PLH${tokens.length - 1}PLH`;
  });
  return { key, tokens };
}

// `[key, template]`; null when the translation can't be templated, so the client translates live instead.
export function packEntry(source, translated) {
  if (typeof source !== 'string' || typeof translated !== 'string') return null;
  const { key, tokens } = makeKey(source);
  const value = collapseSpace(translated);
  if (!key || !value) return null;
  if (tokens.length === 0) return [key, value];

  // Match the literal tokens (digit-guarded); translations may reorder them.
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
    // The translator dropped or localized a placeholder; let the client translate live.
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

// Deduped and sorted for stable diffs; without a Flutter catalog, markup strings only (`counts.dartKind`).
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
