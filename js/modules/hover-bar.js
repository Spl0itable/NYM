(function () {
    const HIDE_DELAY_MS = 150;
    const ABOVE = 14;
    const OVERLAP_X = 8;
    const EDGE = 4;
    const BUTTON = Object.freeze({ width: 34, height: 26, gap: 4 });
    const ICONS = {
        react: '<svg viewBox="0 0 20 20" class="nm-msg-2"><path fill-rule="evenodd" clip-rule="evenodd" d="M15.5 1a.75.75 0 0 1 .75.75v2h2a.75.75 0 0 1 0 1.5h-2v2a.75.75 0 0 1-1.5 0v-2h-2a.75.75 0 0 1 0-1.5h2v-2A.75.75 0 0 1 15.5 1m-13 10a6.5 6.5 0 0 1 7.166-6.466.75.75 0 0 0 .152-1.493 8 8 0 1 0 7.14 7.139.75.75 0 0 0-1.492.152A7 7 0 0 1 15.5 11a6.5 6.5 0 1 1-13 0m4.25-.5a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5m4.5 0a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5M9 15c1.277 0 2.553-.724 3.06-2.173.148-.426-.209-.827-.66-.827H6.6c-.452 0-.808.4-.66.827C6.448 14.276 7.724 15 9 15"></path></svg>',
        reply: '<svg viewBox="0 0 16 16"><path d="M 3 6 C 3 4.5 4 3 6 3 C 6 4.5 5 5 4 5.5 C 3.5 5.8 3 6.3 3 7 L 3 9 L 6 9 L 6 6 Z" /><path d="M 9 6 C 9 4.5 10 3 12 3 C 12 4.5 11 5 10 5.5 C 9.5 5.8 9 6.3 9 7 L 9 9 L 12 9 L 12 6 Z" /></svg>',
        thread: '<svg viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 3a7 7 0 1 0 3.394 13.124.75.75 0 0 1 .542-.074l2.794.68-.68-2.794a.75.75 0 0 1 .073-.542A7 7 0 0 0 10 3m-8.5 7a8.5 8.5 0 1 1 16.075 3.859l.904 3.714a.75.75 0 0 1-.906.906l-3.714-.904A8.5 8.5 0 0 1 1.5 10M6 8.25a.75.75 0 0 1 .75-.75h6.5a.75.75 0 0 1 0 1.5h-6.5A.75.75 0 0 1 6 8.25M6.75 11a.75.75 0 0 0 0 1.5h4.5a.75.75 0 0 0 0-1.5z" clip-rule="evenodd"></path></svg>',
    };
    const LABELS = { react: 'React', reply: 'Reply', thread: 'Reply in Thread', more: 'More' };

    function barWidth(n) {
        return n > 0 ? n * BUTTON.width + (n - 1) * BUTTON.gap : 0;
    }

    function buttons(sheetActions, hasId, availablePx) {
        const acts = Array.isArray(sheetActions) ? sheetActions : [];
        const full = [];
        if (hasId) full.push('react');
        if (acts.indexOf('reply') >= 0) full.push('reply');
        if (acts.indexOf('thread') >= 0) full.push('thread');
        full.push('more');
        if (barWidth(full.length) <= availablePx) return full;
        return hasId ? ['react', 'more'] : ['more'];
    }

    function sheetActionsFor(facts) {
        const A = window.NymMessageActions;
        return A && typeof A.buildMessageActions === 'function' ? A.buildMessageActions(facts) : [];
    }
    let active = null;
    let pending = null;
    let timer = 0;

    function rowOf(target) {
        const row = target && target.closest ? target.closest('.message') : null;
        return row && row.querySelector('.msg-hover-buttons') ? row : null;
    }

    function barOf(row) {
        return row ? row.querySelector('.msg-hover-buttons') : null;
    }

    function clipRect(el) {
        let r = { left: 0, top: 0, right: window.innerWidth, bottom: window.innerHeight };
        for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
            const cs = getComputedStyle(p);
            if (/(auto|scroll|hidden|clip)/.test(cs.overflowY + ' ' + cs.overflowX)) {
                const pr = p.getBoundingClientRect();
                const l = pr.left + p.clientLeft;
                const t = pr.top + p.clientTop;
                r = { left: Math.max(r.left, l), top: Math.max(r.top, t), right: Math.min(r.right, l + p.clientWidth), bottom: Math.min(r.bottom, t + p.clientHeight) };
            }
        }
        return r;
    }

    function textLineRect(content) {
        const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
        let best = null;
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            if (!n.textContent.trim()) continue;
            const pe = n.parentElement;
            if (pe && pe.closest('.msg-hover-buttons, .bubble-time-inner, .bubble-time, .reactions-row')) continue;
            const rg = document.createRange();
            rg.selectNodeContents(n);
            const rects = rg.getClientRects();
            if (!rects.length) continue;
            const first = rects[0];
            if (!best) best = { left: first.left, top: first.top, right: first.right, bottom: first.bottom };
            else if (Math.abs(first.top - best.top) < 4) best.right = Math.max(best.right, first.right);
            else break;
        }
        return best;
    }

    function overlapArea(a, b) {
        const w = Math.min(a.right, b.right) - Math.max(a.left, b.left);
        const h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
        return w > 0.5 && h > 0.5 ? w * h : 0;
    }

    function spot(bubble, clip, bw, bh, self, columns) {
        let x;
        if (self) x = bubble.left + OVERLAP_X - bw;
        else if (columns) x = clip.right - EDGE - bw;
        else x = bubble.right - OVERLAP_X;
        x = Math.max(clip.left + EDGE, Math.min(x, clip.right - EDGE - bw));
        const y = Math.max(bubble.top - ABOVE, clip.top + EDGE);
        return { x: Math.round(x), y: Math.round(y) };
    }

    function bubbleSpot(row, anchor, clip, bw, bh, self) {
        const columns = !!row.closest('.cv-list');
        const s = spot(anchor, clip, bw, bh, self, columns);
        const col = row.closest('.cv-column');
        const jump = col ? col.querySelector('.cv-scroll-bottom.visible') : null;
        const jr = jump ? jump.getBoundingClientRect() : null;
        if (jr && jr.width && overlapArea(jr, { left: s.x, top: s.y, right: s.x + bw, bottom: s.y + bh })) s.x = Math.max(clip.left + EDGE, jr.left - EDGE - bw);
        return s;
    }

    function moveBar(bar, row, x, y) {
        const op = bar.offsetParent || row;
        const opr = op.getBoundingClientRect();
        bar.style.left = Math.round(x - opr.left - op.clientLeft) + 'px';
        bar.style.top = Math.round(y - opr.top - op.clientTop) + 'px';
        bar.style.right = 'auto';
        bar.style.bottom = 'auto';
    }

    function place(row) {
        const bar = barOf(row);
        if (!bar) return;
        bar.style.left = '';
        bar.style.top = '';
        bar.style.right = '';
        bar.style.bottom = '';
        const content = row.querySelector(':scope > .message-content') || row.querySelector('.message-content');
        if (!content) return;
        const bubbles = document.body.classList.contains('chat-bubbles');
        const self = row.classList.contains('self');
        const cr = content.getBoundingClientRect();
        let anchor = { left: cr.left, top: cr.top, right: cr.right, bottom: cr.bottom };
        if (!bubbles) {
            const line = textLineRect(content);
            if (line) anchor = { left: line.left, top: line.top, right: line.right, bottom: line.bottom };
        }
        const clip0 = clipRect(row);
        const ids = (bar.dataset.hbFull || '').split(' ').filter(Boolean);
        if (ids.length) {
            const keep = buttons(ids, ids.indexOf('react') >= 0, clip0.right - clip0.left - 2 * EDGE);
            bar.querySelectorAll('[data-hb]').forEach((b) => { b.hidden = keep.indexOf(b.dataset.hb) < 0; });
        }
        const bw = bar.offsetWidth;
        const bh = bar.offsetHeight;
        const clip = clip0;
        const rr = row.getBoundingClientRect();
        const rcs = getComputedStyle(row);
        const top = Math.max(clip.top + EDGE, rr.top);
        const time = !bubbles && row.closest('.cv-list') ? row.querySelector(':scope > .message-time') : null;
        const tr = time ? time.getBoundingClientRect() : null;
        let x;
        let y;
        if (tr && tr.height) {
            x = rr.right - parseFloat(rcs.paddingRight || '0') - bw;
            y = tr.top + tr.height / 2 - bh / 2;
        } else if (bubbles) {
            const at = bubbleSpot(row, anchor, clip, bw, bh, self);
            moveBar(bar, row, at.x, at.y);
            return;
        } else {
            x = anchor.right + OVERLAP_X;
            y = anchor.top - bh + 8;
        }
        x = Math.min(x, clip.right - EDGE - bw);
        x = Math.max(x, clip.left + EDGE);
        y = Math.max(y, top);
        y = Math.min(y, rr.bottom - bh);
        y = Math.max(y, rr.top);
        moveBar(bar, row, x, y);
    }

    function activate(row) {
        clearTimeout(timer);
        timer = 0;
        pending = null;
        if (row === active) return;
        if (active) active.classList.remove('msg-hover-active');
        active = row && row.isConnected ? row : null;
        if (active) {
            place(active);
            active.classList.add('msg-hover-active');
        }
    }

    function schedule(row) {
        if (row === active) {
            clearTimeout(timer);
            timer = 0;
            pending = null;
            return;
        }
        if (!active || !active.isConnected) {
            activate(row);
            return;
        }
        if (timer && pending === row) return;
        clearTimeout(timer);
        pending = row;
        timer = setTimeout(() => activate(pending), HIDE_DELAY_MS);
    }

    function isMouse(e) {
        return !e.pointerType || e.pointerType === 'mouse' || e.pointerType === 'pen';
    }

    function onOver(e) {
        if (!isMouse(e)) return;
        schedule(rowOf(e.target));
    }

    function onOut(e) {
        if (!isMouse(e)) return;
        if (!e.relatedTarget) schedule(null);
    }

    function onFocusIn(e) {
        const row = rowOf(e.target);
        if (row && row !== active) place(row);
    }

    function onMouseDown(e) {
        if (e.button === 0 && e.target && e.target.closest && e.target.closest('.msg-hover-buttons')) e.preventDefault();
    }

    function install() {
        document.addEventListener('mousedown', onMouseDown, true);
        document.addEventListener('pointerover', onOver, true);
        document.addEventListener('pointerout', onOut, true);
        document.addEventListener('focusin', onFocusIn, true);
    }

    function barHtml(nym, reactionId, facts) {
        const t = (s) => (nym && typeof nym.uiText === 'function' ? (nym.uiText(s) || s) : s);
        const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
        const ids = buttons(sheetActionsFor(Object.assign({ id: true }, facts || {})), true, Infinity);
        const btn = (id) => {
            const label = esc(t(LABELS[id]));
            const action = id === 'react' ? 'reactionShowPicker' : 'hoverBarAction';
            const extra = id === 'react' ? ` data-message-id="${esc(reactionId)}"` : '';
            return `<button type="button" class="hover-bar-btn${id === 'react' ? ' reaction-btn' : ''}" data-hb="${id}" data-action="${action}"${extra} aria-label="${label}" title="${label}">${id === 'more' ? window.NymMenuDotsIcon.svg() : ICONS[id]}</button>`;
        };
        return `<div class="msg-hover-buttons" data-hb-full="${ids.join(' ')}">${ids.map(btn).join('')}</div>`;
    }

    function run(nym, btn) {
        const id = btn && btn.dataset ? btn.dataset.hb : '';
        const msgEl = btn && btn.closest ? btn.closest('.message[data-message-id]') : null;
        if (!nym || !msgEl) return;
        if (id === 'more') {
            const r = btn.getBoundingClientRect();
            if (typeof nym.openMessageActions === 'function') nym.openMessageActions(msgEl, { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 });
            return;
        }
        if (typeof nym.messageActionItems !== 'function') return;
        const item = nym.messageActionItems(msgEl).items.find((i) => i.id === id);
        if (item && typeof item.action === 'function') item.action();
    }

    if (typeof NYM !== 'undefined') {
        Object.assign(NYM.prototype, {
            _hoverBarHtml(reactionId, facts) { return barHtml(this, reactionId, facts); },
            hoverBarAction(btn) { run(this, btn); },
        });
    }

    window.NymHoverBar = { HIDE_DELAY_MS, BUTTON, ABOVE, OVERLAP_X, EDGE, barWidth, buttons, spot, place, activate, get active() { return active; } };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install);
    else install();
})();
