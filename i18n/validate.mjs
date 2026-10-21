import { readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { validateEntry } from './guard.mjs';

export function audit(map) {
  const failing = [];
  const reasons = {};
  for (const [source, translated] of Object.entries(map)) {
    const problems = validateEntry(source, translated);
    if (problems.length === 0) continue;
    failing.push([source, problems]);
    for (const p of problems) reasons[p] = (reasons[p] || 0) + 1;
  }
  return { total: Object.keys(map).length, failing, reasons };
}

export function dropFailing(map) {
  const out = {};
  for (const [source, translated] of Object.entries(map)) {
    if (validateEntry(source, translated).length === 0) out[source] = translated;
  }
  return out;
}

async function auditDir(dir, fix) {
  const rows = [];
  let names = [];
  try { names = (await readdir(dir)).filter((n) => n.endsWith('.json') && n !== 'index.json').sort(); } catch { return rows; }
  for (const name of names) {
    const file = path.join(dir, name);
    const text = await readFile(file, 'utf8');
    let map;
    try { map = JSON.parse(text); } catch { continue; }
    if (!map || typeof map !== 'object' || Array.isArray(map)) continue;
    const result = audit(map);
    rows.push({ lang: name.slice(0, -5), ...result });
    if (fix && result.failing.length > 0) {
      const kept = dropFailing(map);
      const pretty = text.startsWith('{\n');
      const body = pretty ? JSON.stringify(kept, null, 2) : JSON.stringify(kept);
      await writeFile(file, body + (text.endsWith('\n') ? '\n' : ''));
    }
  }
  return rows;
}

function report(label, rows) {
  const total = rows.reduce((n, r) => n + r.failing.length, 0);
  const entries = rows.reduce((n, r) => n + r.total, 0);
  console.log(`${label}: ${total} of ${entries} entries fail across ${rows.length} languages`);
  for (const r of [...rows].sort((a, b) => b.failing.length - a.failing.length || a.lang.localeCompare(b.lang))) {
    if (r.failing.length === 0) continue;
    const why = Object.entries(r.reasons).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join(', ');
    console.log(`  ${r.lang.padEnd(7)} ${String(r.failing.length).padStart(5)} / ${String(r.total).padEnd(5)} ${why}`);
  }
  return total;
}

async function main() {
  const args = process.argv.slice(2);
  const fix = args.includes('--fix');
  const pick = (flag) => args.filter((a) => a.startsWith(`${flag}=`)).map((a) => a.slice(flag.length + 1));
  const cacheDir = pick('--cache')[0] || fileURLToPath(new URL('./cache/', import.meta.url));
  const jsonOut = pick('--json')[0];
  const sample = args.includes('--sample');
  const dirs = [cacheDir, ...pick('--packs')];
  const summary = {};
  let failing = 0;
  for (const dir of dirs) {
    const rows = await auditDir(dir, fix);
    failing += report(dir, rows);
    if (sample) {
      for (const r of rows.filter((x) => x.lang === 'fr' || x.lang === 'de')) {
        for (const [source, problems] of r.failing.slice(0, 5)) console.log(`    ${r.lang} ${problems.join('+')}: ${JSON.stringify(source).slice(0, 90)}`);
      }
    }
    summary[dir] = Object.fromEntries(rows.map((r) => [r.lang, { total: r.total, failing: r.failing.length, reasons: r.reasons }]));
  }
  if (jsonOut) await writeFile(jsonOut, JSON.stringify(summary, null, 2) + '\n');
  if (fix) console.log(failing > 0 ? `removed ${failing} failing entries; they show in English until the next translation run` : 'nothing to remove');
  else if (failing > 0) process.exit(1);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) await main();
