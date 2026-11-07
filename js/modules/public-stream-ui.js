Object.assign(NYM.prototype, {

    _psModel() {
        return typeof window !== 'undefined' ? window.NymPublicStream : null;
    },

    _psMode() {
        const P = this._psModel();
        if (!P) return 'list';
        let v = null;
        try { v = localStorage.getItem(P.LOCAL_KEY); } catch (_) { }
        return P.normalizeMode(v);
    },

    _psOn() {
        return this._psMode() === 'stream' && !(this.settings && this.settings.groupChatPMOnlyMode);
    },

    setPublicMode(mode, opts) {
        const P = this._psModel();
        if (!P || !P.isMode(mode)) return false;
        const o = opts || {};
        const prev = this._psMode();
        try { localStorage.setItem(P.LOCAL_KEY, mode); } catch (_) { }
        if (!o.fromSync && typeof this.notePrefChanged === 'function') this.notePrefChanged(P.SETTING);
        if (prev !== mode) {
            if (mode === 'stream') this._psCloseSearch();
            this._psShown = P.FIRST;
            this._psHold = null;
        }
        this._psApply();
        return true;
    },

    _psCloseSearch() {
        if (typeof document === 'undefined' || typeof document.getElementById !== 'function') return;
        const input = document.getElementById('channelSearch');
        const wrap = document.getElementById('channelSearchWrapper');
        const open = !!(wrap && wrap.classList && wrap.classList.contains('active'));
        if ((open || (input && input.value)) && typeof window.clearSearch === 'function') window.clearSearch('channelSearch');
        if (wrap && wrap.classList) wrap.classList.remove('active', 'has-value');
    },

    _psSection() {
        if (typeof document === 'undefined' || typeof document.querySelector !== 'function') return null;
        return document.querySelector('#sidebar .nav-section[data-section="channels"]');
    },

    _psApply() {
        const sec = this._psSection();
        if (!sec) return;
        const mode = this._psMode();
        const on = mode === 'stream';
        sec.classList.toggle('ps-on', on);
        const title = sec.querySelector('.nav-title-text');
        const want = this.uiText(on ? 'Public Stream' : 'Public Channels');
        if (title && title.textContent !== want) title.textContent = want;
        sec.querySelectorAll('.ps-mode [role="radio"]').forEach((b) => {
            const c = b.dataset.psMode === mode;
            b.setAttribute('aria-checked', c ? 'true' : 'false');
            b.tabIndex = c ? 0 : -1;
        });
        const box = document.getElementById('publicStream');
        if (box) box.hidden = !on;
        if (on) this._psSchedule();
        else this._psClear();
    },

    _psClear() {
        const box = typeof document !== 'undefined' && document.getElementById ? document.getElementById('publicStream') : null;
        if (!box) return;
        const list = box.querySelector('.ps-list');
        if (list) list.textContent = '';
        this._psLast = null;
        this._psHold = null;
    },

    _psSchedule() {
        this._psDirty = true;
        if (this._psRaf) return;
        if (!this._psOn() || !this._psShowing()) return;
        const raf = typeof requestAnimationFrame === 'function' ? requestAnimationFrame : (cb) => setTimeout(cb, 16);
        this._psRaf = raf(() => {
            this._psRaf = 0;
            if (this._psDirty) this._psRender();
        });
    },

    _psShowing() {
        if (typeof document === 'undefined') return false;
        if (document.hidden) return false;
        const sec = this._psSection();
        if (!sec || sec.classList.contains('section-collapsed')) return false;
        return true;
    },

    _psKeys() {
        const P = this._psModel();
        const byKey = new Map();
        const keys = [];
        const locked = [];
        for (const [k, e] of (this.channels || new Map())) {
            const bare = (e && (e.geohash || e.channel)) || k;
            if (!bare || byKey.has(bare)) continue;
            const storageKey = e && e.geohash ? '#' + e.geohash : ((e && e.channel) || k);
            byKey.set(bare, storageKey);
            keys.push(bare);
            if (typeof this.isConversationLocked === 'function' && this.isConversationLocked(storageKey)) locked.push(bare);
        }
        if (!byKey.has(P.DEFAULT_CHANNEL) && typeof this.isConversationLocked === 'function' && this.isConversationLocked('#' + P.DEFAULT_CHANNEL)) locked.push(P.DEFAULT_CHANNEL);
        const out = P.streamKeys({
            channels: keys, blocked: this.blockedChannels, hidden: this.hiddenChannels, pinned: this.pinnedChannels,
            locked, hideNonPinned: !!this.hideNonPinned, pmOnly: !!(this.settings && this.settings.groupChatPMOnlyMode),
        });
        return out.map((bare) => ({ bare, storageKey: byKey.get(bare) || '#' + bare }));
    },

    _psVisible(m, list, threadsOn, gates) {
        return !!m && this._channelMsgVisible(m, list, threadsOn, gates);
    },

    _psCompute(nowSec) {
        const P = this._psModel();
        if (!P) return null;
        const keys = this._psKeys();
        const tags = new Map();
        const stores = new Map();
        const lists = [];
        for (const k of keys) {
            const list = (this.messages && this.messages.get(k.storageKey)) || [];
            tags.set(k.storageKey, P.tagLabel(k.bare));
            stores.set(k.storageKey, list);
            lists.push({ key: k.storageKey, msgs: list });
        }
        const threadsOn = typeof this.threadsEnabled === 'function' && this.threadsEnabled();
        const gates = typeof this._clientGatesActive === 'function' && this._clientGatesActive();
        const hold = this._psHold || null;
        const out = P.page(lists, {
            shown: this._psShown || P.FIRST,
            anchor: hold ? hold.anchor : null, tail: hold ? hold.tail : null, frozen: hold ? hold.frozen : [],
        }, {
            nowSec: typeof nowSec === 'number' ? nowSec : Math.floor(Date.now() / 1000),
            at: (m) => this._orderAt(m),
            ms: (m) => { const v = this._orderMs(m); return Number.isFinite(v) ? v : 0; },
            id: (m) => String(m.id || ''),
            visible: (m, key) => this._psVisible(m, stores.get(key) || [], threadsOn, gates),
        });
        out.tags = tags;
        return out;
    },

    _psScroller() {
        return typeof document !== 'undefined' && document.getElementById ? document.getElementById('sidebar') : null;
    },

    _psHeaderBottom(sc) {
        const h = sc && sc.querySelector ? sc.querySelector(':scope > .sidebar-header') : null;
        const top = sc.getBoundingClientRect().top;
        if (!h || !h.getClientRects().length) return { top, height: 0 };
        const r = h.getBoundingClientRect();
        return { top: Math.max(top, r.bottom), height: Math.max(0, r.bottom - top) };
    },

    _psHeldNow(box) {
        const P = this._psModel();
        const list = box.querySelector('.ps-list');
        const head = list && list.firstElementChild;
        const sc = this._psScroller();
        if (!sc) return !!this._psPointer;
        const hb = this._psHeaderBottom(sc);
        const sec = this._psSection();
        const want = Math.round(hb.height) + 'px';
        if (sec && sec.style.getPropertyValue('--ps-head') !== want) sec.style.setProperty('--ps-head', want);
        if (!head) return !!this._psPointer;
        return P.isHeld({ headTop: head.getBoundingClientRect().top, viewTop: hb.top, pointerDown: !!this._psPointer });
    },

    _psEnv() {
        if (typeof document === 'undefined' || !document.body) return '';
        const de = document.documentElement;
        return document.body.className + '|' + (de ? de.className + '|' + (de.getAttribute('data-theme') || '') + '|' + (de.getAttribute('style') || '') : '') + '|' + ((this.settings && this.settings.theme) || '');
    },

    _psClassesOf(m) {
        const cls = ['message'];
        if (m.isOwn) cls.push('self');
        else if (typeof this.isMentioned === 'function' && this.isMentioned(m.content || '')) cls.push('mentioned');
        const shop = typeof this.getUserShopItems === 'function' ? this.getUserShopItems(m.pubkey) : null;
        if (shop && shop.style) cls.push(shop.style);
        if (shop && shop.supporter) cls.push('supporter-style');
        if (shop && Array.isArray(shop.cosmetics)) shop.cosmetics.forEach((c) => { if (c && c !== 'cosmetic-redacted') cls.push(c); });
        return cls.join(' ');
    },

    _psColors(rows) {
        const env = this._psEnv();
        if (this._psColEnv !== env || !this._psColMap) { this._psColEnv = env; this._psColMap = new Map(); }
        const map = this._psColMap;
        const want = new Map();
        for (const r of rows) {
            const m = r.m;
            const ucc = typeof this.getUserColorClass === 'function' ? this.getUserColorClass(m.pubkey) : '';
            const sig = this._psClassesOf(m) + '|' + ucc;
            r._psColSig = sig;
            if (!map.has(sig) && !want.has(sig)) want.set(sig, ucc);
        }
        if (!want.size || typeof document === 'undefined' || typeof getComputedStyle !== 'function') return;
        const host = document.body;
        if (!host) return;
        const wrap = document.createElement('div');
        wrap.setAttribute('aria-hidden', 'true');
        wrap.style.cssText = 'position:absolute;left:-9999px;top:0;width:200px;height:0;overflow:hidden;visibility:hidden;pointer-events:none';
        const probes = [];
        for (const [sig, ucc] of want) {
            const el = document.createElement('div');
            el.className = sig.slice(0, sig.lastIndexOf('|'));
            const c = document.createElement('span');
            c.className = 'message-content' + (ucc ? ' ' + ucc : '');
            c.textContent = 'x';
            el.appendChild(c);
            wrap.appendChild(el);
            probes.push([sig, c]);
        }
        host.appendChild(wrap);
        for (const [sig, c] of probes) {
            map.set(sig, getComputedStyle(c).color);
        }
        wrap.remove();
    },

    _psRender() {
        this._psDirty = false;
        const P = this._psModel();
        const box = typeof document !== 'undefined' && document.getElementById ? document.getElementById('publicStream') : null;
        if (!P || !box) return;
        if (!this._psOn()) { this._psClear(); return; }
        const list = box.querySelector('.ps-list');
        const more = box.querySelector('.ps-more');
        const note = box.querySelector('.ps-note');
        const pill = box.querySelector('.ps-new');
        if (!list) return;
        const label = this.uiText('Public stream, newest first, read only');
        if (list.getAttribute('aria-label') !== label) list.setAttribute('aria-label', label);
        if (document.querySelector('#channelList > .sidebar-skeleton')) {
            if (!list.querySelector('.ps-skel')) {
                list.innerHTML = ['ssk-w3', 'ssk-w1', 'ssk-w4', 'ssk-w2'].map((w) => `<li class="ps-skel sidebar-skeleton ssk-channel ${w}" aria-hidden="true"><span class="sk-bar"></span></li>`).join('');
            }
            if (more) more.hidden = true;
            if (note) note.hidden = true;
            if (pill) pill.hidden = true;
            return;
        }
        list.querySelectorAll(':scope > .ps-skel').forEach((el) => el.remove());
        const held = !this._psRelease && this._psHeldNow(box);
        this._psRelease = false;
        if (held && !this._psHold) this._psHold = P.hold(this._psLast ? this._psLast.rows : [], null);
        if (!held) this._psHold = null;
        const res = this._psCompute();
        if (!res) return;
        this._psColors(res.rows);
        this._psReconcile(list, res);
        if (this._psHold) this._psHold = P.hold(res.rows, this._psHold);
        this._psLast = res;
        if (pill) {
            const pl = P.pillLabel(res.pending);
            pill.hidden = !pl;
            const t = pl ? this.uiText(pl.template, pl.vars.n ? { n: this.abbreviateNumber ? this.abbreviateNumber(pl.vars.n) : pl.vars.n } : undefined) : '';
            if (pill.textContent !== t) pill.textContent = t;
        }
        if (more) {
            const b = res.button;
            more.hidden = !b;
            let t = '';
            if (b) {
                const n = this.abbreviateNumber ? this.abbreviateNumber(b.n) : b.n;
                t = b.kind === 'view' ? this.uiText('View {n} more...', { n }) : b.kind === 'show' ? this.uiText('Show {n} more...', { n }) : this.uiText('Show less');
            }
            if (more.textContent !== t) more.textContent = t;
        }
        if (note) note.hidden = res.rows.length > 0;
    },

    _psRowParts(r, tag, nowMs, hide) {
        const P = this._psModel();
        const m = r.m;
        const LM = window.NymLayoutModel;
        const ui = (s) => this.uiText(s);
        const ms = Number.isFinite(m._ms) && m._ms > 0 ? m._ms : (m.created_at || 0) * 1000;
        const when = LM && typeof LM.relativeTime === 'function' ? LM.relativeTime(nowMs, ms, ui) : '';
        const author = String(m.author || this.uiText('anon'));
        const pk = typeof m.pubkey === 'string' ? m.pubkey : '';
        const base = author.replace(/#[0-9a-f]{4}$/i, '');
        const nym = base + '#' + (pk ? pk.slice(-4) : '????');
        const body = hide ? null : this._psBody(m);
        const text = body ? P.partsText(body) : '';
        const color = (this._psColMap && r._psColSig && this._psColMap.get(r._psColSig)) || '';
        const who = m.isOwn ? '' : (typeof this.getUserColorClass === 'function' ? this.getUserColorClass(pk) : '');
        const blur = this._blursImagesFrom(pk, m.isOwn);
        return { when, author, pk, nym, text, body, color, who, blur };
    },

    _psBody(m) {
        const P = this._psModel();
        const raw = this._previewBody(m.content || '', m.quoted);
        const emo = this.customEmojis instanceof Map ? this.customEmojis : null;
        const key = raw + '\u0001' + (this._formatCtxRev || 0) + '\u0001' + (emo ? emo.size : 0);
        if (!this._psBodyMemo) this._psBodyMemo = new WeakMap();
        const hit = this._psBodyMemo.get(m);
        if (hit && hit.key === key) return hit.out;
        const out = P.parts(raw, { emoji: emo, builtin: this.emojiMap || null });
        this._psBodyMemo.set(m, { key, out });
        return out;
    },

    _psProxied(url, emoji) {
        const base = typeof this._mediaProxyBase === 'function' ? this._mediaProxyBase() : null;
        if (!base) return url;
        return emoji ? `${base}?emoji=1&url=${encodeURIComponent(url)}` : `${base}?url=${encodeURIComponent(url)}`;
    },

    _psBodyHtml(parts) {
        const e = (s) => this.escapeHtml(String(s));
        const emo = this.customEmojis instanceof Map ? this.customEmojis : null;
        let text = '';
        for (const p of parts.body.parts) {
            if (p[0] === 'e') {
                const url = emo && emo.get(p[1]);
                text += url ? `<img class="custom-emoji ps-emoji" src="${e(this._psProxied(url, true))}" alt=":${e(p[1])}:" decoding="async" loading="lazy" draggable="false">` : e(':' + p[1] + ':');
            } else text += this.mentionSuffixHtml(p[1]);
        }
        const fb = (url) => {
            const list = this.mediaFallbacks instanceof Map ? (this.mediaFallbacks.get(url) || []) : [];
            return list.length ? ` data-media-fallbacks="${e(list.map((u) => this._psProxied(u, false)).join('|'))}"` : '';
        };
        const media = parts.body.media.map((x) => x[0] === 'v'
            ? '<span class="ps-media ps-video" aria-hidden="true"><svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="M8 5v14l11-7z" fill="currentColor"/></svg></span>'
            : `<img class="ps-media${parts.blur ? ' blurred' : ''}" src="${e(this._psProxied(x[1], false))}" alt="" decoding="async" loading="lazy" draggable="false"${fb(x[1])}>`).join('');
        return { text: text ? ` <span class="ps-text">${text}</span>` : '', media: media ? `<span class="ps-thumbs">${media}</span>` : '' };
    },

    _psFill(btn, r, parts, tag, hide) {
        const P = this._psModel();
        const e = (s) => this.escapeHtml(String(s));
        const who = this.formatNymWithPubkey(parts.author, parts.pk);
        const body = !hide && parts.body ? this._psBodyHtml(parts) : { text: '', media: '' };
        btn.innerHTML = `<span class="ps-time">${e(parts.when)}</span><span class="ps-line"><span class="ps-tag">${e(tag)}</span> <span class="ps-who${parts.who ? ' ' + e(parts.who) : ''}">${who}</span>${body.text}${body.media}</span>`;
        const tx = parts.color && body.text ? btn.querySelector('.ps-text') : null;
        if (tx) tx.style.setProperty('color', parts.color, 'important');
        if (body.media && typeof this._attachMediaFallbacks === 'function') this._attachMediaFallbacks(btn);
        const lab = P.rowLabel({ time: parts.when, channel: tag, nym: parts.nym, text: parts.text, hide });
        btn.setAttribute('aria-label', this.uiText(lab.template, lab.vars));
    },

    _psReconcile(list, res) {
        const hide = (() => { try { return localStorage.getItem('nym_hide_previews') === '1'; } catch (_) { return false; } })();
        const nowMs = Date.now();
        const lang = typeof this.getUiLanguage === 'function' ? this.getUiLanguage() : '';
        const have = new Map();
        for (const li of Array.from(list.children)) if (li.dataset && li.dataset.mid) have.set(li.dataset.mid, li);
        const keep = new Set();
        let prev = null;
        for (const r of res.rows) {
            const tag = res.tags.get(r.key) || r.key;
            const parts = this._psRowParts(r, tag, nowMs, hide);
            const sig = this._psSigOf(r, parts, tag, hide, lang);
            let li = have.get(r.id);
            if (!li) {
                li = document.createElement('li');
                li.className = 'ps-item';
                li.dataset.mid = r.id;
                const btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'ps-row';
                btn.dataset.mid = r.id;
                btn.dataset.key = r.key;
                btn.setAttribute('data-no-tip', '');
                li.appendChild(btn);
            }
            if (li._psSig !== sig) {
                this._psFill(li.firstElementChild, r, parts, tag, hide);
                li._psSig = sig;
            }
            keep.add(r.id);
            const want = prev ? prev.nextElementSibling : list.firstElementChild;
            if (want !== li) list.insertBefore(li, want);
            prev = li;
        }
        for (const [id, li] of have) if (!keep.has(id)) li.remove();
    },

    _psSigOf(r, parts, tag, hide, lang) {
        const body = parts.body ? JSON.stringify([parts.body.parts, parts.body.media]) : '';
        const base = typeof this._mediaProxyBase === 'function' ? this._mediaProxyBase() : '';
        return [body, parts.author, parts.pk, parts.when, hide ? 1 : 0, lang, tag, parts.color, parts.who, parts.blur ? 1 : 0, base || '', this._formatCtxRev || 0].join('\u0001');
    },

    _psSweepTimes() {
        const res = this._psLast;
        if (!res || !this._psOn() || typeof document === 'undefined' || typeof document.getElementById !== 'function') return;
        const box = document.getElementById('publicStream');
        const list = box && box.querySelector('.ps-list');
        if (!list) return;
        const hide = (() => { try { return localStorage.getItem('nym_hide_previews') === '1'; } catch (_) { return false; } })();
        const lang = typeof this.getUiLanguage === 'function' ? this.getUiLanguage() : '';
        const nowMs = Date.now();
        const byId = new Map(res.rows.map((r) => [r.id, r]));
        for (const li of Array.from(list.children)) {
            const r = li.dataset ? byId.get(li.dataset.mid) : null;
            if (!r) continue;
            const tag = res.tags.get(r.key) || r.key;
            const parts = this._psRowParts(r, tag, nowMs, hide);
            const sig = this._psSigOf(r, parts, tag, hide, lang);
            if (li._psSig === sig) continue;
            this._psFill(li.firstElementChild, r, parts, tag, hide);
            li._psSig = sig;
        }
    },

    _psOpen(key, id) {
        const list = (this.messages && this.messages.get(key)) || [];
        const msg = list.find((m) => m && m.id === id);
        if (!msg || typeof this.unifiedSearchJump !== 'function') return;
        this.unifiedSearchJump(key, msg);
    },

    _psShowNew() {
        this._psHold = null;
        this._psRelease = true;
        const sec = this._psSection();
        const title = sec && sec.querySelector('.nav-title');
        if (title && typeof title.scrollIntoView === 'function') title.scrollIntoView({ block: 'nearest' });
        this._psDirty = true;
        this._psRender();
    },

    _psMore() {
        const P = this._psModel();
        const b = this._psLast && this._psLast.button;
        if (!P || !b) return;
        this._psShown = b.next;
        if (b.kind === 'less') {
            this._psHold = null;
            this._psRelease = true;
            const sec = this._psSection();
            const title = sec && sec.querySelector('.nav-title');
            if (title && typeof title.scrollIntoView === 'function') title.scrollIntoView({ block: 'nearest' });
        }
        this._psDirty = true;
        this._psRender();
    },

    _psModeKey(e) {
        const t = e.target && e.target.closest ? e.target.closest('.ps-mode [role="radio"]') : null;
        if (!t) return;
        const keys = { ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 };
        if (!(e.key in keys)) return;
        e.preventDefault();
        const P = this._psModel();
        const modes = P.MODES;
        const i = modes.indexOf(t.dataset.psMode);
        const next = modes[(i + keys[e.key] + modes.length) % modes.length];
        this.setPublicMode(next);
        const btn = t.parentElement && t.parentElement.querySelector(`[data-ps-mode="${next}"]`);
        if (btn && typeof btn.focus === 'function') btn.focus();
    },

    setupPublicStream() {
        if (typeof document === 'undefined' || typeof document.getElementById !== 'function') return;
        const box = document.getElementById('publicStream');
        const sec = this._psSection();
        if (box && !box._psBound) {
            box._psBound = true;
            box.addEventListener('click', (e) => {
                const t = e.target && e.target.closest ? e.target : null;
                if (!t) return;
                const row = t.closest('.ps-row');
                if (row) { this._psOpen(row.dataset.key, row.dataset.mid); return; }
                if (t.closest('.ps-new')) { this._psShowNew(); return; }
                if (t.closest('.ps-more')) this._psMore();
            });
            const list = box.querySelector('.ps-list');
            if (list) list.addEventListener('pointerdown', () => { this._psPointer = true; }, { passive: true });
            const up = () => {
                if (!this._psPointer) return;
                this._psPointer = false;
                if (this._psHold) this._psSchedule();
            };
            window.addEventListener('pointerup', up, { passive: true });
            window.addEventListener('pointercancel', up, { passive: true });
        }
        if (sec && !sec._psBound) {
            sec._psBound = true;
            sec.addEventListener('keydown', (e) => this._psModeKey(e));
        }
        const sc = this._psScroller();
        if (sc && !sc._psBound) {
            sc._psBound = true;
            sc.addEventListener('scroll', () => { if (this._psHold) this._psSchedule(); }, { passive: true });
        }
        if (!this._psVisBound) {
            this._psVisBound = true;
            document.addEventListener('visibilitychange', () => { if (!document.hidden && this._psDirty) this._psSchedule(); });
            if (typeof MutationObserver === 'function' && document.body) {
                const mo = new MutationObserver(() => { if (this._psOn() && this._psColEnv !== this._psEnv()) this._psSchedule(); });
                mo.observe(document.body, { attributes: true, attributeFilter: ['class', 'style'] });
                if (document.documentElement) mo.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'style', 'data-theme'] });
            }
        }
        this._psApply();
    },
});

(function () {
    if (typeof NYM === 'undefined' || !NYM.prototype) return;
    const proto = NYM.prototype;
    const names = ['_contentFiltersChanged', '_refreshRenderedVisibility', '_hideRenderedKeywordMatches', '_applyEditVisibility',
        'handleDeletionEvent', 'applyHiddenChannels', 'updateChannelPins', 'blockChannel', 'unblockChannel', '_clApply',
        '_clearSidebarSkel', '_applySidebarSectionCollapse', '_channelRestoreGroupFromD1'];
    for (const name of names) {
        const orig = proto[name];
        if (typeof orig !== 'function' || orig._psWrapped) continue;
        const wrapped = function () {
            const r = orig.apply(this, arguments);
            const go = () => { if (typeof this._psSchedule === 'function') this._psSchedule(); };
            if (r && typeof r.then === 'function') r.then(go, go);
            else go();
            return r;
        };
        wrapped._psWrapped = true;
        proto[name] = wrapped;
    }
})();
