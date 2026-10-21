export const BRANDS = ['Nymchat', 'Nymbot', 'Nostr', 'bitchat'];

export const GLOSSARY = [
  { term: 'nym', note: 'a user name or identity in the app; keep the word "nym" (plural "nyms") untranslated' },
  { term: 'PM', note: 'a private message between two nyms; keep "PM" (plural "PMs") untranslated' },
  { term: 'zap', note: 'a Bitcoin Lightning tip sent over Nostr; keep "zap" untranslated' },
  { term: 'geohash', note: 'a location channel named by a short geohash code such as #u4pr; keep "geohash" untranslated' },
  { term: 'relay', note: 'a Nostr relay server that stores and forwards messages; use the usual technical word for a relay server, never a sports relay or an electrical relay' },
  { term: 'flair', note: 'a cosmetic badge or effect shown next to a nym; keep "flair" untranslated' },
];

const PLACEHOLDER_SRC = String.raw`\{[A-Za-z0-9_.]+\}|%(?:\d+\$)?[sdif@]|PLH\d+PLH|\$\{[^{}]*\}`;
const PUNCT_END = String.raw`[^\s<>"'()\[\].,;:!?]`;
const PROTECTED_SRC = [
  '`[^`\\n]+`',
  String.raw`https?:\/\/[^\s<>"'()\[\]]*${PUNCT_END}`,
  String.raw`\bwww\.[^\s<>"'()\[\]]*${PUNCT_END}`,
  String.raw`\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:app|com|ai|org|net|io|xyz|chat|dev)\b(?:\/[^\s<>"'()\[\]]*${PUNCT_END})?`,
  String.raw`[#@](?:${PLACEHOLDER_SRC})`,
  String.raw`(?<![\p{L}\p{N}_&])#[\p{L}\p{N}_-]+`,
  String.raw`(?<![\p{L}\p{N}_.])@[A-Za-z][\w-]*`,
  PLACEHOLDER_SRC,
  String.raw`(?<![\p{L}\p{N}_]):[a-z][a-z0-9_+-]*:`,
  String.raw`(?<![\p{L}\p{N}_\/.:<])\/[a-z][a-z0-9_-]*`,
  String.raw`\b(?:${BRANDS.join('|')})\b`,
].join('|');

const placeholderRe = () => new RegExp(PLACEHOLDER_SRC, 'g');
const protectedRe = () => new RegExp(PROTECTED_SRC, 'giu');
const BRAND_ONLY = new RegExp(String.raw`^(?:${BRANDS.join('|')})$`, 'i');

export const TOKEN = (i) => `⟦${i}⟧`;

export function placeholders(text) {
  return (String(text).match(placeholderRe()) || []).sort();
}

export function protectedSpans(text) {
  return String(text).match(protectedRe()) || [];
}

export function protectedTerms(text) {
  const bare = new RegExp(`^(?:${PLACEHOLDER_SRC})$`);
  return protectedSpans(text).filter((span) => !bare.test(span));
}

export function protect(text) {
  const tokens = [];
  const masked = String(text).replace(protectedRe(), (span) => {
    tokens.push(span);
    return TOKEN(tokens.length - 1);
  });
  return { masked, tokens };
}

export function restore(translated, tokens) {
  if (typeof translated !== 'string') return null;
  const text = translated.replace(/⟦\s*(\d+)\s*⟧/g, (_, n) => TOKEN(Number(n)));
  const seen = text.match(/⟦\d+⟧/g) || [];
  if (seen.length !== tokens.length) return null;
  for (let i = 0; i < tokens.length; i++) {
    if (text.split(TOKEN(i)).length !== 2) return null;
  }
  const out = text.replace(/⟦(\d+)⟧/g, (_, n) => tokens[Number(n)]);
  return out.trim() ? out : null;
}

export function hasWords(text) {
  return /\p{L}/u.test(protect(text).masked.replace(/⟦\d+⟧/g, ''));
}

export function isFragment(key) {
  const s = String(key);
  if (/,\s*[\r\n]\s*["'`]|["'`]\s*,\s*[\r\n]|[\r\n]\s*["'`]\s*$|^\s*["'`]\s*[\r\n]|[\r\n]\s*\/\/ /.test(s)) return true;
  if ((s.match(/\{/g) || []).length !== (s.match(/\}/g) || []).length) return true;
  return false;
}

const collapse = (s) => String(s).replace(/\s+/g, ' ').trim();

const WIDE = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;
const visibleLength = (text) => [...collapse(text)].reduce((n, ch) => n + (WIDE.test(ch) ? 3 : 1), 0);

export function lengthOk(source, translated) {
  const s = visibleLength(source);
  const t = visibleLength(translated);
  if (t === 0) return false;
  if (s >= 24) return t >= s * 0.2 && t <= s * 4;
  return t <= s * 4 + 24;
}

function termKept(translated, term) {
  if (BRAND_ONLY.test(term)) return translated.toLowerCase().includes(term.toLowerCase());
  return translated.includes(term);
}

export function validateEntry(source, translated) {
  const problems = [];
  if (isFragment(source)) problems.push('fragment');
  if (typeof translated !== 'string' || !translated.trim()) return [...problems, 'empty'];
  if (placeholders(source).join('\u0000') !== placeholders(translated).join('\u0000')) problems.push('placeholder');
  if (protectedTerms(source).some((term) => !termKept(translated, term))) problems.push('protected');
  if (/[⟦⟧]/.test(translated)) problems.push('token');
  if (!lengthOk(source, translated)) problems.push('length');
  return problems;
}

export function isShortLabel(source) {
  const words = collapse(source).split(' ').filter(Boolean);
  return words.length > 0 && words.length <= 2 && !/[.!?]$/.test(collapse(source));
}

const SHORT_ESCAPES = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', v: '\v', 0: '\0' };

export function decodeEscape(src, at) {
  const next = src[at + 1];
  if (next === undefined) return ['', 1];
  if (next === 'u' && src[at + 2] === '{') {
    const close = src.indexOf('}', at + 3);
    if (close > 0) return [String.fromCodePoint(parseInt(src.slice(at + 3, close), 16)), close - at + 1];
  }
  if (next === 'u' && /^[0-9a-fA-F]{4}$/.test(src.slice(at + 2, at + 6))) {
    return [String.fromCharCode(parseInt(src.slice(at + 2, at + 6), 16)), 6];
  }
  if (next === 'x' && /^[0-9a-fA-F]{2}$/.test(src.slice(at + 2, at + 4))) {
    return [String.fromCharCode(parseInt(src.slice(at + 2, at + 4), 16)), 4];
  }
  if (next === '\n') return ['', 2];
  if (next === '\r') return ['', src[at + 2] === '\n' ? 3 : 2];
  return [Object.prototype.hasOwnProperty.call(SHORT_ESCAPES, next) ? SHORT_ESCAPES[next] : next, 2];
}

function skipBraces(src, at) {
  let depth = 0;
  for (let k = at; k < src.length; k++) {
    const q = src[k];
    if (q === "'" || q === '"' || q === '`') {
      for (k++; k < src.length && src[k] !== q; k++) if (src[k] === '\\') k++;
      continue;
    }
    if (q === '{') depth++;
    else if (src[k] === '}' && --depth === 0) return k + 1;
  }
  return src.length;
}

export function scanLiterals(src, dialect = 'dart') {
  const out = [];
  const n = src.length;
  let i = 0;
  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      const end = src.indexOf('\n', i);
      i = end < 0 ? n : end;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      const end = src.indexOf('*/', i + 2);
      i = end < 0 ? n : end + 2;
      continue;
    }
    const quote = c === "'" || c === '"' || (dialect === 'js' && c === '`');
    if (!quote) { i++; continue; }
    const raw = dialect === 'dart' && src[i - 1] === 'r' && !/[\w$]/.test(src[i - 2] || '');
    const triple = dialect === 'dart' && src.startsWith(c.repeat(3), i);
    const close = triple ? c.repeat(3) : c;
    const multiline = triple || c === '`';
    let j = i + close.length;
    let value = '';
    let interpolated = false;
    let closed = false;
    while (j < n) {
      if (src.startsWith(close, j)) { closed = true; j += close.length; break; }
      const ch = src[j];
      if (ch === '\n' && !multiline) break;
      if (ch === '\\' && !raw) {
        const [text, len] = decodeEscape(src, j);
        value += text;
        j += len;
        continue;
      }
      const dartInterp = dialect === 'dart' && !raw && ch === '$' && /[{A-Za-z_]/.test(src[j + 1] || '');
      const jsInterp = c === '`' && ch === '$' && src[j + 1] === '{';
      if (dartInterp || jsInterp) {
        interpolated = true;
        value += '\u0000';
        if (src[j + 1] === '{') j = skipBraces(src, j + 1);
        else { j++; while (j < n && /\w/.test(src[j])) j++; }
        continue;
      }
      value += ch;
      j++;
    }
    if (closed) out.push({ value, start: raw ? i - 1 : i, end: j, interpolated });
    i = j;
  }
  return out;
}

export function joinAdjacent(literals, src) {
  const out = [];
  for (const lit of literals) {
    const prev = out[out.length - 1];
    if (prev && /^\s*$/.test(src.slice(prev.end, lit.start))) {
      out[out.length - 1] = { ...prev, value: prev.value + lit.value, end: lit.end, interpolated: prev.interpolated || lit.interpolated };
    } else {
      out.push(lit);
    }
  }
  return out;
}

const NAMED_ROLES = [
  [/^(?:ok|cancel|confirm|action|button|submit|primary|secondary|destructive)\w*label$/i, 'button'],
  [/^(?:label|chipLabel|tabLabel)$/i, 'label'],
  [/^(?:title|heading|header|appBarTitle|sectionTitle)$/i, 'title'],
  [/^(?:tooltip|semanticLabel|semanticsLabel|ariaLabel)$/i, 'tooltip or accessibility label'],
  [/^(?:hint|hintText|placeholder|labelText)$/i, 'input placeholder'],
  [/^(?:subtitle|helperText|body|message|warning|errorText|emptyText|description|amberHint|detail)$/i, 'message'],
];

const CALL_ROLES = [
  [/(?:SnackBar|showSnack|snack|[Tt]oast|banner|flash)\w*/, 'toast'],
  [/(?:\w*Button|button|PopupMenuItem|MenuItem)\b/, 'button'],
  [/(?:AppBar|AlertDialog|Dialog|Sheet)\b/, 'title'],
];

const HTML_ROLES = {
  button: 'button', a: 'link', label: 'label', option: 'menu option', title: 'page title',
  h1: 'title', h2: 'title', h3: 'title', h4: 'title', h5: 'title', h6: 'title', summary: 'title',
  th: 'table header', legend: 'title', li: 'list item', small: 'note',
};

export function shapeRole(text) {
  const t = collapse(text);
  if (/[.!?…]$/.test(t) || t.split(' ').length > 6) return 'sentence';
  return 'label';
}

export function roleFor(before, text, kind = 'code') {
  if (kind === 'attr:placeholder') return 'input placeholder';
  if (kind === 'attr:title' || kind === 'attr:aria-label') return 'tooltip or accessibility label';
  if (kind === 'attr:alt') return 'image description';
  if (kind === 'html') {
    const open = /<([a-zA-Z][\w-]*)\b[^>]*>[^<]*$/.exec(before);
    const role = open && HTML_ROLES[open[1].toLowerCase()];
    return role || shapeRole(text);
  }
  const tail = before.slice(-160);
  const named = /([A-Za-z_]\w*)\s*:\s*(?:(?:tr|t|uiText)\s*\(\s*)?$/.exec(tail);
  if (named) {
    for (const [rx, role] of NAMED_ROLES) if (rx.test(named[1])) return role;
  }
  const line = tail.slice(tail.lastIndexOf(';') + 1);
  for (const [rx, role] of CALL_ROLES) if (rx.test(line)) return role;
  return shapeRole(text);
}

function setOnce(map, value, entry) {
  for (const key of [value, collapse(value)]) if (key && !map.has(key)) map.set(key, entry);
}

export function buildContexts(files) {
  const map = new Map();
  for (const { file, text } of files) {
    if (/\.html?$/i.test(file)) {
      for (const m of text.matchAll(/\s(placeholder|title|aria-label|alt)="([^"]+)"/g)) {
        setOnce(map, m[2], { file, role: roleFor('', m[2], `attr:${m[1]}`) });
      }
      for (const m of text.matchAll(/>([^<]+)</g)) {
        const value = collapse(m[1]);
        if (!value) continue;
        setOnce(map, value, { file, role: roleFor(text.slice(Math.max(0, m.index - 400), m.index + 1), value, 'html') });
      }
      continue;
    }
    const dialect = /\.dart$/.test(file) ? 'dart' : 'js';
    for (const lit of joinAdjacent(scanLiterals(text, dialect), text)) {
      if (lit.interpolated || !lit.value.trim()) continue;
      setOnce(map, lit.value, { file, role: roleFor(text.slice(Math.max(0, lit.start - 400), lit.start), lit.value) });
    }
  }
  return map;
}

export function contextFor(map, source) {
  const hit = map.get(source) || map.get(collapse(source));
  return hit ? `${hit.file}, ${hit.role}` : `app interface, ${shapeRole(source)}`;
}

export async function listFiles(dir, ext) {
  const { readdir } = await import('node:fs/promises');
  const out = [];
  let entries = [];
  try { entries = await readdir(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const full = `${dir.replace(/\/$/, '')}/${entry.name}`;
    if (entry.isDirectory()) out.push(...await listFiles(full, ext));
    else if (entry.name.endsWith(ext)) out.push(full);
  }
  return out;
}

export function glossaryText() {
  return GLOSSARY.map((g) => `${g.term}: ${g.note}`).join('; ');
}
