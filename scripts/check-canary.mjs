import { readFileSync, appendFileSync } from 'fs';

const doc = JSON.parse(readFileSync('canary.json', 'utf8'));
const c = typeof doc.content === 'string' ? JSON.parse(doc.content) : doc;
const due = c.nextUpdateBy ? Date.parse(c.nextUpdateBy) : NaN;
const days = Number.isFinite(due) ? Math.floor((due - Date.now()) / 86400000) : NaN;
const warn = Number(process.env.WARN_DAYS || 14);

let status = 'ok';
if (!Number.isFinite(days) || days < 0) status = 'overdue';
else if (days <= warn) status = 'soon';

const out = [
    'status=' + status,
    'days=' + (Number.isFinite(days) ? days : ''),
    'due=' + (c.nextUpdateBy || ''),
].join('\n') + '\n';

if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, out);
console.log(out.trim());
