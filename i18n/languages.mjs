// The languages the app offers, read from the app itself.

import { readFile } from 'node:fs/promises';

const SOURCE = new URL('../js/modules/translate.js', import.meta.url);

/// Every offered language as `{ code, name }`, English excluded — English is
/// the source, so a pack for it would map every string to itself.
export async function loadLanguages() {
  const src = await readFile(SOURCE, 'utf8');
  const start = src.indexOf('const NYM_TRANSLATE_LANGUAGES = [');
  if (start < 0) throw new Error('NYM_TRANSLATE_LANGUAGES not found in js/modules/translate.js');
  const end = src.indexOf('\n];', start);
  if (end < 0) throw new Error('NYM_TRANSLATE_LANGUAGES is not terminated');
  const block = src.slice(start, end);

  const out = [];
  const seen = new Set();
  const rx = /\{\s*code:\s*'([^']+)'\s*,\s*name:\s*'([^']+)'\s*\}/g;
  let m;
  while ((m = rx.exec(block)) !== null) {
    const [, code, name] = m;
    if (code === 'en' || seen.has(code)) continue;
    seen.add(code);
    out.push({ code, name });
  }
  if (out.length === 0) throw new Error('parsed no languages from js/modules/translate.js');
  return out;
}
