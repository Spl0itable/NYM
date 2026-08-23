// Tests the composer's attachment strip: the model in rich-compose.js that
// decides what is attached, and the markup it renders for each state.
//
//   npm run test:media
//
// The attachment list is the source of truth for what gets sent. It used to be
// the draft text — URLs were appended to the input as each upload finished and
// the strip reverse-engineered them back out — which is what made a finished
// upload's preview vanish, and what put a wall of links in front of the user
// while they were still typing.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

let pass = 0, fail = 0;
const chk = (name, cond, extra) => {
  if (cond) pass++;
  else { fail++; console.log(`  FAIL  ${name}${extra ? '\n        ' + extra : ''}`); }
};
const section = (s) => console.log(`\n${s}`);

// --------------------------------------------------------------- fake DOM
// The strip only ever needs innerHTML, dataset, classList and textContent.
function fakeStrip() {
  const cls = new Set(['nm-hidden']);
  const node = {
    innerHTML: '',
    dataset: {},
    classList: {
      add: (c) => cls.add(c),
      remove: (c) => cls.delete(c),
      contains: (c) => cls.has(c),
    },
    _classes: cls,
  };
  // Real DOM semantics: emptying textContent removes every child, so the
  // markup goes with it. Without this the fake would report a stale strip.
  Object.defineProperty(node, 'textContent', {
    get: () => node.innerHTML.replace(/<[^>]*>/g, ''),
    set: (v) => { node.innerHTML = v ? String(v) : ''; },
  });
  return node;
}

let revoked = [];
const ctx = {
  console,
  NYM: function () { },
  window: {},
  URL: {
    _n: 0,
    createObjectURL(f) { return 'blob:' + (f && f.name ? f.name : 'x') + '#' + (++ctx.URL._n); },
    revokeObjectURL(u) { revoked.push(u); },
  },
};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(root, 'js/modules/rich-compose.js'), 'utf8'),
  ctx, { filename: 'rich-compose.js' });

function makeApp() {
  revoked = [];
  const strip = fakeStrip();
  const input = { value: '' };
  const app = new ctx.NYM();
  ctx.document = {
    getElementById: (id) => (id === 'mediaPreviewStrip' ? strip
      : id === 'messageInput' ? input : null),
  };
  app.escapeHtml = (s) => String(s == null ? '' : s)
    .replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  app._composerMediaMatches = () => [];
  app._releaseComposerMediaBlobs = () => { };
  app._refreshComposerOffsets = () => { };
  return { app, strip, input };
}

const file = (name, type) => ({ name, type });
const tileCount = (strip) => (strip.innerHTML.match(/class="media-preview-item/g) || []).length;

// ------------------------------------------------------------------ tests
section('what is attached');
{
  const { app, strip } = makeApp();
  const recs = app.addComposerAttachments([file('a.png', 'image/png'), file('b.mp4', 'video/mp4')]);
  chk('a tile appears per picked file, before a byte is up', tileCount(strip) === 2);
  chk('kind comes from the mime type', recs[0].kind === 'image' && recs[1].kind === 'video');
  chk('both start uploading', recs.every(r => r.status === 'uploading'));
  chk('an uploading tile carries the wheel',
    (strip.innerHTML.match(/media-preview-spinner/g) || []).length === 2);
  chk('nothing is contributed to the message yet', app.composerAttachmentUrls().length === 0);
  chk('and the composer knows it is still working', app.composerHasPendingUploads() === true);
}

section('an upload finishing');
{
  const { app, strip } = makeApp();
  const [a] = app.addComposerAttachments([file('a.png', 'image/png')]);
  app.updateComposerAttachment(a.id, { status: 'done', url: 'https://h/a.png' });
  // The reported bug: the preview disappeared the moment the upload completed.
  chk('the tile SURVIVES the upload completing', tileCount(strip) === 1);
  chk('its wheel is gone', !/media-preview-spinner/.test(strip.innerHTML));
  chk('it now contributes its URL', app.composerAttachmentUrls().join() === 'https://h/a.png');
  chk('and nothing is pending', app.composerHasPendingUploads() === false);
  chk('the local blob keeps standing in, so the thumb does not re-fetch',
    app._composerMediaBlobs.get('https://h/a.png') === a.objectUrl);
}

section('an upload failing');
{
  const { app, strip } = makeApp();
  const [a, b] = app.addComposerAttachments([file('a.png', 'image/png'), file('b.png', 'image/png')]);
  app.updateComposerAttachment(a.id, { status: 'done', url: 'https://h/a.png' });
  app.updateComposerAttachment(b.id, { status: 'failed', error: 'server said no' });
  chk('the failed tile stays put', tileCount(strip) === 2);
  chk('it offers a retry', /media-preview-retry/.test(strip.innerHTML));
  chk('and says so', /Tap to retry/.test(strip.innerHTML));
  chk('the reason is on the tile, not in a toast naming a file off screen',
    /server said no/.test(strip.innerHTML));
  // The point of per-file state: one failure must not cost the whole batch.
  chk('the successful sibling still contributes',
    app.composerAttachmentUrls().join() === 'https://h/a.png');
  chk('the failed one contributes nothing', !app.composerAttachmentUrls().includes(''));

  app.updateComposerAttachment(b.id, { status: 'done', url: 'https://h/b.png' });
  chk('a retry that succeeds joins the message, in the original order',
    app.composerAttachmentUrls().join(' ') === 'https://h/a.png https://h/b.png');
}

section('removing and clearing');
{
  const { app, strip } = makeApp();
  const [a, b] = app.addComposerAttachments([file('a.png', 'image/png'), file('b.png', 'image/png')]);
  app.updateComposerAttachment(a.id, { status: 'done', url: 'https://h/a.png' });
  app.removeComposerAttachment(b.id);
  chk('removing drops its tile', tileCount(strip) === 1);
  chk('an un-uploaded blob is released', revoked.includes(b.objectUrl));
  chk('the remaining URL is untouched', app.composerAttachmentUrls().join() === 'https://h/a.png');

  app.removeComposerAttachment(a.id);
  chk('removing an uploaded one drops its URL too', app.composerAttachmentUrls().length === 0);
  chk('but does NOT revoke a blob the thumbnail is still standing on',
    !revoked.includes(a.objectUrl));

  const { app: app2, strip: strip2 } = makeApp();
  app2.addComposerAttachments([file('c.png', 'image/png')]);
  app2.clearComposerAttachments();
  chk('clearing empties the strip', tileCount(strip2) === 0);
  chk('and hides it', strip2._classes.has('nm-hidden'));
  chk('and contributes nothing', app2.composerAttachmentUrls().length === 0);
}

section('re-rendering');
{
  const { app, strip } = makeApp();
  const [a] = app.addComposerAttachments([file('a.png', 'image/png')]);
  const first = strip.dataset.sig;
  app.updateComposerMediaPreviews();
  chk('an unchanged strip is not rebuilt (a rebuild restarts every video preload)',
    strip.dataset.sig === first);
  app.updateComposerAttachment(a.id, { status: 'done', url: 'https://h/a.png' });
  chk('but a status change IS rendered', strip.dataset.sig !== first);
}

section('escaping');
{
  const { app, strip } = makeApp();
  const [a] = app.addComposerAttachments([file('a.png', 'image/png')]);
  app.updateComposerAttachment(a.id, { status: 'failed', error: '<img src=x onerror=alert(1)>' });
  chk('a server-supplied error cannot inject markup',
    !/<img src=x/.test(strip.innerHTML) && /&lt;img/.test(strip.innerHTML));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
