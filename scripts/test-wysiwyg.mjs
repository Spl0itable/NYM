// Tests the composer's live formatting: the markdown parser in rich-compose.js
// and the DOM layer in ui-context.js that renders it into the message input.
//
//   npm run test:wysiwyg
//
// The point of these tests is the caret coordinate system. Hidden markers mean
// the field's visible text no longer matches the draft, so every offset the
// rest of the app hands the input (selectionStart, setSelectionRange, the
// toolbar's slice arithmetic) has to keep addressing the draft, not the
// rendering. Each case below therefore checks the same three things: the DOM
// serializes back to the exact draft, its measured length equals the draft's,
// and every model offset maps to a DOM position that maps back to itself.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// ------------------------------------------------------------------ fake DOM
// Just enough of the DOM for the input renderer: the serializer and the caret
// math only ever touch nodeType, childNodes, nodeValue, tagName and dataset.
const TEXT_NODE = 3, ELEMENT_NODE = 1;

class FakeNode {
    constructor(type) { this.nodeType = type; this.childNodes = []; }
    appendChild(child) {
        if (child instanceof FakeFragment) {
            for (const c of child.childNodes.slice()) this.appendChild(c);
            child.childNodes.length = 0;
            return child;
        }
        this.childNodes.push(child);
        child.parentNode = this;
        return child;
    }
    insertBefore(child, ref) {
        const at = ref == null ? this.childNodes.length : this.childNodes.indexOf(ref);
        this.childNodes.splice(at < 0 ? this.childNodes.length : at, 0, child);
        child.parentNode = this;
        return child;
    }
    get nextSibling() {
        const kids = this.parentNode ? this.parentNode.childNodes : null;
        if (!kids) return null;
        return kids[kids.indexOf(this) + 1] || null;
    }
}
class FakeText extends FakeNode {
    constructor(v) { super(TEXT_NODE); this.nodeValue = v; }
}
class FakeFragment extends FakeNode {
    constructor() { super(ELEMENT_NODE); this.tagName = '#fragment'; }
}
class FakeElement extends FakeNode {
    constructor(tag) {
        super(ELEMENT_NODE);
        this.tagName = tag.toUpperCase();
        this.dataset = {};
        this.className = '';
        this.attrs = {};
    }
    setAttribute(k, v) { this.attrs[k] = String(v); }
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
    set textContent(v) {
        this.childNodes.length = 0;
        if (v) this.childNodes.push(new FakeText(String(v)));
    }
    get textContent() {
        let out = '';
        const walk = (n) => {
            if (n.nodeType === TEXT_NODE) { out += n.nodeValue; return; }
            for (const c of n.childNodes) walk(c);
        };
        walk(this);
        return out;
    }
}

globalThis.Node = { TEXT_NODE, ELEMENT_NODE };
globalThis.document = {
    createElement: (t) => new FakeElement(t),
    createTextNode: (v) => new FakeText(v),
    createDocumentFragment: () => new FakeFragment()
};

// ------------------------------------------------------------- load the code
function NYM() { }
globalThis.NYM = NYM;
for (const rel of ['js/modules/rich-compose.js', 'js/modules/ui-context.js']) {
    vm.runInThisContext(fs.readFileSync(path.join(root, rel), 'utf8'), { filename: rel });
}
const nym = new NYM();
nym.customEmojis = new Map();
nym._pubkeyForSuffix = () => null;

let pass = 0, fail = 0;
function chk(name, cond, extra) {
    if (cond) pass++;
    else { fail++; console.log(`  FAIL  ${name}${extra ? '\n        ' + extra : ''}`); }
}
function section(s) { console.log(`\n${s}`); }

// ------------------------------------------------------------------- helpers
function render(text, sel) {
    const el = new FakeElement('div');
    nym._renderRichInput(el, text, sel);
    return el;
}

// The model offset of a DOM position, walking the tree the way
// _richSelectionOffset's range clone + _richNodeLength does in a real browser.
function modelOffsetOf(root, node, offset) {
    let acc = 0, done = false, result = 0;
    const visit = (n) => {
        if (done) return;
        if (n === node) {
            if (n.nodeType === TEXT_NODE) result = acc + offset;
            else {
                for (let i = 0; i < offset; i++) acc += nym._richNodeLength(n.childNodes[i]);
                result = acc;
            }
            done = true;
            return;
        }
        if (n.nodeType === TEXT_NODE) { acc += n.nodeValue.length; return; }
        const tok = nym._richAtomicToken(n);
        if (tok != null) { acc += tok.length; return; }
        for (const c of n.childNodes) { visit(c); if (done) return; }
    };
    visit(root);
    return done ? result : null;
}

// The [start, end) spans of every hidden marker, in model coordinates. A caret
// offset strictly inside one of these has no DOM position of its own.
function hiddenSpans(root) {
    const spans = [];
    let acc = 0;
    const visit = (n) => {
        if (n.nodeType === TEXT_NODE) { acc += n.nodeValue.length; return; }
        const tok = nym._richAtomicToken(n);
        if (tok != null) {
            if (typeof n.dataset.mark === 'string') spans.push([acc, acc + tok.length]);
            acc += tok.length;
            return;
        }
        for (const c of n.childNodes) visit(c);
    };
    visit(root);
    return spans;
}

// Every invariant the rest of the app relies on, for one draft and one caret.
function checkDraft(label, text, sel) {
    const el = render(text, sel);
    const got = nym._serializeRichInput(el);
    chk(`${label}: round-trips`, got === text, `want ${JSON.stringify(text)}\n        got  ${JSON.stringify(got)}`);
    chk(`${label}: measures ${text.length}`, nym._richNodeLength(el) === text.length,
        `got ${nym._richNodeLength(el)}`);

    const hidden = hiddenSpans(el);
    const insideHidden = (t) => hidden.some(([a, b]) => t > a && t < b);
    let bad = null, snapped = null;
    for (let t = 0; t <= text.length; t++) {
        const loc = nym._richLocate(el, t);
        const back = modelOffsetOf(el, loc.node, loc.offset);
        if (insideHidden(t)) {
            // No DOM position exists inside a hidden marker; the caret must
            // still land on a stable offset at one of its edges.
            const span = hidden.find(([a, b]) => t > a && t < b);
            if (back !== span[0] && back !== span[1]) snapped = snapped || `${t} -> ${back}`;
        } else if (back !== t) {
            bad = bad || `${t} -> ${back}`;
        }
    }
    chk(`${label}: every offset maps to itself`, bad === null, bad);
    chk(`${label}: hidden markers are never split`, snapped === null, snapped);
    return el;
}

// The parse tree covers the draft exactly: no gap, no overlap, no invented text.
function checkTree(label, text) {
    const problems = [];
    const walk = (nodes, from, to) => {
        let pos = from;
        for (const n of nodes) {
            if (n.start !== pos) problems.push(`gap/overlap at ${n.start}, expected ${pos}`);
            if (n.kind !== 'text') {
                const innerStart = n.start + (n.open || '').length;
                const innerEnd = n.end - (n.close || '').length;
                if (innerEnd < innerStart) problems.push(`negative body at ${n.start}`);
                if (text.slice(n.start, innerStart) !== (n.open || '')) problems.push(`open marker mismatch at ${n.start}`);
                if (text.slice(innerEnd, n.end) !== (n.close || '')) problems.push(`close marker mismatch at ${n.end}`);
                walk(n.children || [], innerStart, innerEnd);
            }
            pos = n.end;
        }
        if (pos !== to) problems.push(`tail gap: ended at ${pos}, expected ${to}`);
    };
    walk(nym._richParseFormat(text), 0, text.length);
    chk(`${label}: tree covers the draft`, problems.length === 0, problems.join('\n        '));
}

const _types = (runs) => {
    const out = [];
    const walk = (nodes) => {
        for (const n of nodes) {
            if (n.kind === 'text') continue;
            out.push(n.type);
            walk(n.children || []);
        }
    };
    walk(runs);
    return out;
};

const classes = (el) => {
    const out = [];
    const walk = (n) => {
        if (n.nodeType !== ELEMENT_NODE) return;
        if (n.className) out.push(n.className);
        for (const c of n.childNodes) walk(c);
    };
    for (const c of el.childNodes) walk(c);
    return out;
};
const has = (el, cls) => classes(el).some(c => c.split(' ').includes(cls));

// What the user actually sees: text nodes plus any revealed markers, with the
// hidden markers left out. This is the half the round-trip tests can't see.
function visibleText(root) {
    let out = '';
    const walk = (n) => {
        if (n.nodeType === TEXT_NODE) { out += n.nodeValue; return; }
        if (n.dataset && typeof n.dataset.mark === 'string') return;
        if (n.tagName === 'IMG') { out += n.getAttribute('alt') || ''; return; }
        for (const c of n.childNodes) walk(c);
    };
    walk(root);
    return out;
}

// --------------------------------------------------------------- what it sees
section('grammar');
const grammar = [
    ['bold', '**bold**', 'rich-md-bold'],
    ['bold underscores', '__bold__', 'rich-md-bold'],
    ['italic', '*it*', 'rich-md-italic'],
    ['italic underscore', '_it_', 'rich-md-italic'],
    ['strike', '~~gone~~', 'rich-md-strike'],
    ['inline code', '`x = 1`', 'rich-md-code'],
    ['code fence', '```\nx = 1\n```', 'rich-md-codeblock'],
    ['heading 1', '# Title', 'rich-md-h1'],
    ['heading 2', '## Title', 'rich-md-h2'],
    ['heading 3', '### Title', 'rich-md-h3'],
    ['quote', '> quoted', 'rich-md-quote']
];
for (const [label, text, cls] of grammar) {
    chk(`${label} renders as ${cls}`, has(render(text, null), cls));
}

section('markers disappear');
// The whole delimiter has to vanish, not part of it: a marker the parser
// mis-sizes would still round-trip, it would just leave a stray "~" on screen.
const visible = [
    ['**bold**', 'bold'],
    ['__bold__', 'bold'],
    ['*it*', 'it'],
    ['_it_', 'it'],
    ['~~gone~~', 'gone'],
    ['`x = 1`', 'x = 1'],
    ['```\nx = 1\n```', '\nx = 1\n'],
    ['```js\nx\n```', 'js\nx\n'],
    ['# Title', 'Title'],
    ['## Title', 'Title'],
    ['### Title', 'Title'],
    ['> quoted', 'quoted'],
    ['a **b** c *d* e', 'a b c d e'],
    ['**bold with *italic* inside**', 'bold with italic inside'],
    ['# A **bold** heading', 'A bold heading'],
    ['plain text', 'plain text'],
    ['a * b', 'a * b'],
    ['#hashtag', '#hashtag']
];
for (const [text, want] of visible) {
    const got = visibleText(render(text, null));
    chk(`${JSON.stringify(text)} shows ${JSON.stringify(want)}`, got === want, `got ${JSON.stringify(got)}`);
}
// No marker ever comes back, wherever the caret is. Revealing a run while the
// caret was inside it meant the markers were on screen for the whole time the
// user was typing that run — the caret is always inside what you are currently
// writing — so in practice the field showed markdown almost all the time, which
// is the one thing a WYSIWYG composer must not do.
for (const [text, want] of visible) {
    for (const sel of [{ start: 0, end: 0 }, { start: 0, end: text.length },
                       { start: text.length, end: text.length }]) {
        const got = visibleText(render(text, sel));
        chk(`${JSON.stringify(text)} hides its markers at ${sel.start}-${sel.end}`,
            got === want, `want ${JSON.stringify(want)}\n        got  ${JSON.stringify(got)}`);
    }
}

// Things the message formatter leaves alone must stay plain here too, or the
// field would show formatting the recipient never gets.
section('non-matches stay plain');
const plain = [
    ['bare asterisk', 'a * b'],
    ['spaced emphasis', 'a *  b'],
    ['url with underscores', 'https://x.test/a_b_c'],
    ['snake_case word', 'some_var_name here'],
    ['mid-line hash', 'not # a heading'],
    ['hash with no space', '#hashtag'],
    ['emoji-ish colon', 'ratio 3:4 *and* more']
];
for (const [label, text] of plain) {
    const el = render(text, null);
    const md = classes(el).filter(c => c.startsWith('rich-md') && c !== 'rich-md-open');
    if (label !== 'emoji-ish colon') {
        chk(`${label} is not formatted`, md.length === 0, md.join(','));
    }
    chk(`${label} round-trips`, nym._serializeRichInput(el) === text);
}

// ------------------------------------------------------------ caret integrity
section('caret and round-trip');
const drafts = [
    ['plain', 'hello world'],
    ['bold', 'a **bold** b'],
    ['bold at both ends', '**b** and **c**'],
    ['italic', 'a *it* b'],
    ['strike', 'x ~~y~~ z'],
    ['inline code', 'run `npm test` now'],
    ['nested', '**bold with *italic* inside**'],
    ['nested three deep', '**a ~~b *c* d~~ e**'],
    ['heading', '# Big title'],
    ['heading with bold', '## A **bold** title'],
    ['quote', '> quoted **text**'],
    ['multiline', '# Title\nbody **bold**\n> quote'],
    ['fence', '```\nlet x = 1;\n```'],
    ['fence with language', '```js\nlet x = 1;\n```'],
    ['unterminated fence', '```js\nlet x = 1;'],
    ['bare fence', '```'],
    ['empty closed fence', '``````'],
    ['text then a bare fence', 'intro\n```'],
    ['fence then text', '```\ncode\n```\nafter **that**'],
    ['adjacent markers', '**a**~~b~~'],
    ['empty lines', 'a\n\n**b**\n\nc'],
    ['trailing newline', '**bold**\n'],
    ['leading newline', '\n**bold**'],
    ['unmatched markers', '**a * b ~~ c'],
    ['underscore emphasis', 'an _emphasised_ word'],
    ['url in bold', '**see https://x.test/a.png**'],
    ['colon before star', 'time 3:00*x*']
];
for (const [label, text] of drafts) {
    checkTree(label, text);
    checkDraft(label, text, null);
}

section('caret and round-trip at every offset');
for (const [label, text] of drafts) {
    // A caret at every offset in turn: whatever it reveals, the draft and the
    // offsets have to survive it.
    for (let t = 0; t <= text.length; t++) {
        const el = render(text, { start: t, end: t });
        if (nym._serializeRichInput(el) !== text || nym._richNodeLength(el) !== text.length) {
            chk(`${label}: survives caret at ${t}`, false,
                JSON.stringify(nym._serializeRichInput(el)));
            break;
        }
    }
    chk(`${label}: survives a caret at every offset`, true);
    checkDraft(`${label} (all selected)`, text, { start: 0, end: text.length });
}

section('markers stay hidden');
{
    // The regression this guards: typing "**bold**" leaves the caret at offset
    // 10, inside the run, and the field used to show the asterisks there.
    const text = 'a **bold** b';
    for (const t of [0, 3, 5, 10, text.length]) {
        const el = render(text, { start: t, end: t });
        chk(`bold markers stay hidden with the caret at ${t}`,
            hiddenSpans(el).length === 2 && !has(el, 'rich-mark-shown'),
            visibleText(el));
        chk(`caret at ${t} does not change the length`,
            nym._richNodeLength(el) === text.length);
        chk(`caret at ${t} does not change the draft`,
            nym._serializeRichInput(el) === text);
    }
}
{
    const text = '# A long heading';
    for (const t of [0, 1, 2, 10, text.length]) {
        chk(`heading prefix stays hidden with the caret at ${t}`,
            hiddenSpans(render(text, { start: t, end: t })).length === 1);
    }
}

section('code blocks');
{
    // Slack's behaviour, and what the toolbar's own code-block tool produces
    // once you delete its body: three backticks open a block immediately,
    // before there is anything to put in it.
    const blank = render('```', null);
    chk('three backticks open a block', has(blank, 'rich-md-codeblock'));
    chk('an empty block is marked so it can still be seen', has(blank, 'rich-md-blank'));
    chk('an empty block shows nothing', visibleText(blank) === '');
    chk('an empty block still holds its backticks', nym._serializeRichInput(blank) === '```');
    chk('an empty block measures 3', nym._richNodeLength(blank) === 3);

    const typed = render('```x', null);
    chk('the first character lands inside the block', visibleText(typed) === 'x');
    chk('a block with a body is not marked blank', !has(typed, 'rich-md-blank'));

    // The class above is only half the contract: it was emitted and asserted
    // here for weeks while no stylesheet rule consumed it, so an empty block
    // had nothing to give it height and rendered as a 4px sliver. Every
    // character it contains is a hidden marker, so the height has to come from
    // CSS or from nowhere.
    const css = fs.readFileSync(path.join(root, 'css/styles-chat.css'), 'utf8');
    const blankRule = css.slice(css.indexOf('.rich-md-codeblock.rich-md-blank'));
    chk('the stylesheet has a rule for an empty block',
        css.includes('.rich-md-codeblock.rich-md-blank'));
    chk('and it gives the empty block a height',
        blankRule.slice(0, blankRule.indexOf('}')).includes('min-height'));

    // Wrapping by going back and adding a fence above or below.
    chk('a fence added in front wraps what follows',
        visibleText(render('```code here', null)) === 'code here');
    chk('a fence added after closes the block',
        visibleText(render('```code here```', null)) === 'code here');
    chk('a fence on its own line above wraps the lines below',
        visibleText(render('```\nline one\nline two', null)) === '\nline one\nline two');

    // A bare fence mid-draft opens a block for the rest, like the renderer.
    chk('text before a fence stays outside it',
        _types(nym._richParseFormat('intro\n```\ncode')).join(',') === 'codeblock');
}

section('deleting a hidden block marker');
{
    const del = (t, c, f) => nym._richMarkerDelete(t, c, !!f);
    const eq = (got, text, caret) => got && got.text === text && got.caret === caret;

    // Backspace at the start of a heading's body takes the whole prefix, not
    // the invisible space in front of it.
    chk('backspace at the start of a heading removes the prefix',
        eq(del('# Title', 2, false), 'Title', 0));
    chk('backspace at the start of an h3 removes the whole prefix',
        eq(del('### Title', 4, false), 'Title', 0));
    chk('backspace at the start of a quote removes the prefix',
        eq(del('> quoted', 2, false), 'quoted', 0));
    chk('forward-delete at the head of the line removes the prefix',
        eq(del('# Title', 0, true), 'Title', 0));
    chk('a heading on the second line is found too',
        eq(del('intro\n# Title', 8, false), 'intro\nTitle', 6));

    // A fence unwraps whole — one press, both fences, the code kept.
    chk('backspace inside an empty block removes it',
        eq(del('```', 3, false), '', 0));
    chk('backspace at the head of a block unwraps it',
        eq(del('```\ncode\n```', 3, false), '\ncode\n', 0));
    chk('backspace at the tail of a block unwraps it, caret on the kept text',
        eq(del('```\ncode\n```', 12, false), '\ncode\n', 6));
    chk('forward-delete at the head of a block unwraps it',
        eq(del('```\ncode\n```', 0, true), '\ncode\n', 0));
    chk('an unterminated block unwraps its one fence',
        eq(del('```code', 3, false), 'code', 0));

    // Everywhere else the plain character delete stands.
    for (const [label, t, c] of [
        ['mid-heading', '# Title', 4],
        ['end of a heading', '# Title', 7],
        ['inside a block body', '```\ncode\n```', 6],
        ['plain text', 'hello', 3],
        ['at the very start of plain text', 'hello', 0]
    ]) {
        chk(`${label}: left to the normal delete`, del(t, c, false) === null);
    }

    // An inline run unwraps the same way a fence does, and for the same reason:
    // its markers are hidden, so a plain Backspace would silently eat one half
    // of the pair and leave the other behind as literal text.
    chk('backspace at the start of a bold body unwraps it',
        eq(del('a **bold** b', 4, false), 'a bold b', 2));
    chk('backspace just past a bold run unwraps it, caret on the kept text',
        eq(del('a **bold** b', 10, false), 'a bold b', 6));
    chk('forward-delete before a bold run unwraps it',
        eq(del('a **bold** b', 2, true), 'a bold b', 2));
    chk('forward-delete at the end of a bold body unwraps it',
        eq(del('a **bold** b', 8, true), 'a bold b', 6));
    chk('italic unwraps too', eq(del('a *it* b', 3, false), 'a it b', 2));
    chk('strike unwraps too', eq(del('a ~~s~~ b', 4, false), 'a s b', 2));
    chk('inline code unwraps too', eq(del('a `c` b', 3, false), 'a c b', 2));
    // Innermost first: one press drops one level of formatting, not both.
    chk('a nested run unwraps the tightest level',
        eq(del('**a *b* c**', 5, false), '**a b c**', 4));
    chk('mid-body is still left to the normal delete',
        del('a **bold** b', 6, false) === null);
    chk('out of range is refused', del('# Title', 99, false) === null);
    chk('an empty draft is refused', del('', 0, false) === null);
}

section('signature');
{
    // The signature is what decides whether a keystroke re-renders the field.
    const sig = (t, sel) => nym._richTreeSig(nym._richParseFormat(t), sel);
    const caretAtEnd = (t) => ({ start: t.length, end: t.length });
    chk('typing inside a run does not change the signature',
        sig('a **bold** b', null) === sig('a **bolder** b', null));
    chk('typing before a run does not change the signature',
        sig('a **bold** b', null) === sig('aa **bold** b', null));
    chk('completing a run changes the signature',
        sig('a **bold* b', null) !== sig('a **bold** b', null));
    chk('breaking a run changes the signature',
        sig('a **bold** b', null) !== sig('a **bold* b', null));
    // Nothing reveals any more, so the caret cannot change what is rendered —
    // which also means simply moving it never re-renders the field.
    chk('moving the caret into a run does not change the signature',
        sig('a **bold** b', { start: 0, end: 0 }) === sig('a **bold** b', { start: 5, end: 5 }));
    chk('an empty draft has an empty signature', sig('', null) === '');
    chk('no caret position reveals a run',
        !sig('**bold**', caretAtEnd('**bold**')).includes('!')
        && !sig('**bold**', { start: 3, end: 3 }).includes('!'));
}

section('atomic markers');
{
    // The mechanism the whole scheme rests on: a hidden marker is one
    // indivisible unit whose length is its source text.
    const el = render('**hi**', null);
    const mark = el.childNodes[0].childNodes[0];
    chk('a hidden marker is atomic', nym._richAtomicToken(mark) === '**');
    chk('a hidden marker measures its source', nym._richNodeLength(mark) === 2);
    // ...wherever the caret is, now that nothing reveals.
    const withCaret = render('**hi**', { start: 3, end: 3 }).childNodes[0].childNodes[0];
    chk('a marker stays atomic with the caret inside the run',
        nym._richAtomicToken(withCaret) === '**');
    chk('a marker measures the same with the caret inside',
        nym._richNodeLength(withCaret) === 2);
}

section('caret at a run boundary');
{
    // The bug this guards let a completed run swallow everything typed after
    // it: "**bold**" then " x" became "**bold x**". A hidden closing marker
    // takes up no space, so the browser reports the caret INSIDE the run, and
    // the next character was inserted before the marker instead of after it.
    // _richOutwardSkip is what turns that inner reading into the outer one.
    const el = render('a *it*', null);
    // el = [ text("a "), wrap[ mark, text("it"), mark ], text("") ]
    const wrap = el.childNodes[1];
    const body = wrap.childNodes[1];
    chk('the body text node is where it should be', body.nodeValue === 'it');

    chk('the end of a run body resolves outside the run',
        nym._richOutwardSkip(el, body, 2) === 1);
    chk('mid-body is left alone',
        nym._richOutwardSkip(el, body, 1) === 0);
    chk('the start of a body is left alone',
        nym._richOutwardSkip(el, body, 0) === 0);


    // A two-character marker skips two.
    const bold = render('**b**', null);
    const boldBody = bold.childNodes[0].childNodes[1];
    chk('a two-character closing marker skips two',
        nym._richOutwardSkip(bold, boldBody, 1) === 2);

    // Real content after the run stops the walk: only the run's own closing
    // marker is skipped, never the text that follows it.
    const mid = render('a *it* b', null);
    const midBody = mid.childNodes[1].childNodes[1];
    chk('a run followed by text skips only its own closing marker',
        nym._richOutwardSkip(mid, midBody, 2) === 1);

    // A run nested inside a heading has to walk out through both wrappers to
    // find the marker that ends it.
    const head = render('# a *it*', null);
    let deep = null;
    (function find(n) {
        for (const c of n.childNodes || []) {
            if (c.nodeType === 3 && c.nodeValue === 'it') { deep = c; return; }
            find(c);
            if (deep) return;
        }
    })(head);
    chk('the nested body was found', deep !== null);
    chk('a run inside a heading still resolves outward',
        deep !== null && nym._richOutwardSkip(head, deep, 2) === 1,
        deep === null ? 'not found' : String(nym._richOutwardSkip(head, deep, 2)));

}

section('every wrapper has a landing spot after it');
{
    // The empty text node _richPadBoundaries adds is what gives the caret an
    // outside position to occupy at all.
    for (const text of ['**b**', 'a *it*', '`c`', '**a** **b**']) {
        const el = render(text, null);
        const kids = el.childNodes;
        let ok = true;
        for (let i = 0; i < kids.length; i++) {
            const k = kids[i];
            if (k.nodeType !== 1 || nym._richAtomicToken(k) != null) continue;
            const next = kids[i + 1];
            if (!next || next.nodeType !== 3) ok = false;
        }
        chk(`${JSON.stringify(text)}: every wrapper is followed by a text node`, ok);
        chk(`${JSON.stringify(text)}: padding does not change the draft`,
            nym._serializeRichInput(el) === text);
        chk(`${JSON.stringify(text)}: padding does not change the length`,
            nym._richNodeLength(el) === text.length);
    }
}

section(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
