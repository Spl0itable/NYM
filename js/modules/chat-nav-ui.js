(function () {
    const N = () => window.NymChatNav;
    const nowSec = () => Math.floor(Date.now() / 1000);
    const ico = (p, size) => `<svg width="${size || 16}" height="${size || 16}" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" class="nm-ico8">${p}</svg>`;
    const ICONS = {
        up: ico('<polyline points="4 10 8 6 12 10"/>'),
        down: ico('<polyline points="4 6 8 10 12 6"/>'),
        star: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg>',
        starFilled: '<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg>',
        clock: ico('<circle cx="8" cy="8" r="6"/><polyline points="8 4.5 8 8 10.5 9.5"/>'),
        arrowUp: '<svg class="cn-ico" width="8.26" height="10" viewBox="3.25 2.25 9.5 11.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="8" y1="13" x2="8" y2="3"/><polyline points="4 7 8 3 12 7"/></svg>',
        arrowDown: '<svg class="cn-ico" width="8.26" height="10" viewBox="3.25 2.25 9.5 11.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="8" y1="3" x2="8" y2="13"/><polyline points="4 9 8 13 12 9"/></svg>',
        at: '<svg class="cn-ico cn-at" width="10" height="10" viewBox="0.625 0.625 22.75 22.75" fill="none" stroke="currentColor" stroke-width="2.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"/></svg>',
        anon: ico('<circle cx="8" cy="6" r="3"/><path d="M2.5 14c.8-2.6 2.9-4 5.5-4s4.7 1.4 5.5 4"/><line x1="2.5" y1="2.5" x2="13.5" y2="13.5"/>'),
    };
    const MENTION_SAVE_MS = 400;
    const SCHEDULE_REFRESH_MS = 30000;
    const HTTP_ADD_BYTES = 200000;

    Object.assign(NYM.prototype, {

        _cn(text, vars) {
            let s = typeof this.uiText === 'function' ? this.uiText(text) : text;
            if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
            return s;
        },

        _cnNotice(text) {
            if (typeof this.displaySystemMessage === 'function') this.displaySystemMessage(text);
        },

        _cnDomId(m) {
            return (m && m.isPM && m.nymMessageId) ? m.nymMessageId : (m && m.id);
        },

        _cnSelector(id) {
            const v = (typeof CSS !== 'undefined' && CSS.escape) ? CSS.escape(String(id)) : String(id).replace(/"/g, '');
            return `[data-message-id="${v}"]`;
        },

        _cnSingleKey() {
            if (this.inPMMode) {
                if (this.currentGroup) return this.getGroupConversationKey(this.currentGroup);
                if (this.currentPM) return this.getPMConversationKey(this.currentPM);
                return null;
            }
            return this.currentGeohash ? `#${this.currentGeohash}` : (this.currentChannel || null);
        },

        _cnIsConv(key) {
            const k = String(key || '');
            return k.startsWith('pm-') || k.startsWith('group-');
        },

        _cnStoreList(key) {
            if (this._cnIsConv(key)) {
                return typeof this.getFilteredPMMessages === 'function' ? this.getFilteredPMMessages(key) : (this.pmMessages.get(key) || []);
            }
            return typeof this.getFilteredMessages === 'function' ? this.getFilteredMessages(key) : (this.messages.get(key) || []);
        },

        _cnIsMention(m) {
            if (!m || m.isOwn || !m.pubkey || typeof m.content !== 'string') return false;
            if (m.isGroup && typeof this._gtGroupRowMentioned === 'function') return this._gtGroupRowMentioned(m);
            return typeof this.isMentioned === 'function' && this.isMentioned(m.content);
        },

        _cnRow(m) {
            return {
                id: this._cnDomId(m),
                at: this._cnAt(m),
                own: !!m.isOwn || (!!this.pubkey && m.pubkey === this.pubkey),
                sys: !m.pubkey || m.isSystem === true,
            };
        },

        _cnEntries() {
            if (!this._cnEntryMap) this._cnEntryMap = new Map();
            return this._cnEntryMap;
        },

        _cnCapture(key) {
            if (!key) return null;
            const map = this._cnEntries();
            if (map.has(key)) return map.get(key);
            const lastRead = (this.channelLastRead && this.channelLastRead.get(key)) || 0;
            const openedAt = nowSec();
            const mark = N().markMax(this._cnStoredMark(key), N().markFloor(lastRead));
            const entry = { key, lastRead, openedAt, openedMs: Date.now(), info: null, placed: false, landed: false, landing: false, scrolled: false, mark, base: mark.at };
            map.set(key, entry);
            this._cnScanMentionsOnOpen(entry);
            return entry;
        },

        _cnRelease(key) {
            if (!key) return;
            const entry = this._cnEntries().get(key);
            if (entry) this._cnSaveMark(key, entry.mark);
            this._cnEntries().delete(key);
            if (typeof document === 'undefined') return;
            const containers = [document.getElementById('messagesContainer')];
            const col = this._cvActive && typeof this._cvColumnForKey === 'function' ? this._cvColumnForKey(key) : null;
            if (col && col.listEl) containers.push(col.listEl);
            for (const c of containers) {
                if (c && c.dataset && (c.dataset.virtualScrollKey === key || c === (col && col.listEl))) {
                    c.querySelectorAll('.cn-divider').forEach((d) => d.remove());
                }
            }
        },

        _cnMarkKey() {
            return N().KEYS.seenMarks + ':' + (this.pubkey || 'anon');
        },

        _cnMarkStore() {
            if (this._cnMarkCache && this._cnMarkCache.pk === this.pubkey) return this._cnMarkCache.map;
            let map = {};
            try {
                const raw = localStorage.getItem(this._cnMarkKey());
                if (raw) map = N().markStoreNorm(JSON.parse(raw));
            } catch (_) { map = {}; }
            this._cnMarkCache = { pk: this.pubkey, map };
            return map;
        },

        _cnStoredMark(key) {
            return N().markNorm(this._cnMarkStore()[key]);
        },

        _cnSaveMark(key, mark) {
            if (!key || !(N().markNorm(mark).at > 0)) return;
            const store = this._cnMarkStore();
            const prev = N().markNorm(store[key]);
            const m = N().markMax(prev, mark);
            if (prev.at === m.at && prev.ids.length === m.ids.length) return;
            store[key] = { at: m.at, ids: m.ids, t: Date.now() };
            if (this._cnMarkTimer) return;
            this._cnMarkTimer = setTimeout(() => {
                this._cnMarkTimer = null;
                try { localStorage.setItem(this._cnMarkKey(), JSON.stringify(N().markStoreNorm(this._cnMarkStore()))); } catch (_) { }
                if (typeof this._syncReadStateToD1 === 'function') this._syncReadStateToD1();
            }, MENTION_SAVE_MS);
        },

        _cnSetMark(entry, mark) {
            entry.mark = mark;
            this._cnSaveMark(entry.key, mark);
        },

        _cnContextFor(key) {
            if (typeof document === 'undefined') return null;
            if (this._cvActive) {
                const col = typeof this._cvColumnForKey === 'function' ? this._cvColumnForKey(key) : null;
                if (!col || !col.listEl) return null;
                return { key, container: col.listEl, scroller: col.scrollerEl, host: col.el, col };
            }
            if (key !== this._cnSingleKey()) return null;
            const container = document.getElementById('messagesContainer');
            const scroller = typeof this._getMessagesScroller === 'function' ? this._getMessagesScroller() : null;
            if (!container || !scroller) return null;
            return { key, container, scroller, host: null, col: null };
        },

        _cnRaw(key) {
            const conv = this._cnIsConv(key);
            return (conv ? (this.pmMessages && this.pmMessages.get(key)) : (this.messages && this.messages.get(key))) || [];
        },

        _cnAt(m) {
            return Math.floor(Number(typeof this._orderAt === 'function' ? this._orderAt(m) : m.created_at) || 0);
        },

        _cnShown(key, from) {
            const raw = this._cnRaw(key);
            const tail = [];
            for (let i = raw.length - 1; i >= 0; i--) {
                const x = raw[i];
                if (x && this._cnAt(x) >= from) tail.push(x);
            }
            if (!tail.length) return [];
            tail.reverse();
            let shown;
            if (this._cnIsConv(key)) shown = typeof this.getFilteredPMMessages === 'function' ? this.getFilteredPMMessages(key, tail) : tail;
            else shown = typeof this.getFilteredMessages === 'function' ? this.getFilteredMessages(key, tail) : tail;
            return shown.map((x) => this._cnRow(x));
        },

        _cnUnseen(entry) {
            const m = entry && entry.mark;
            if (!m || !(m.at > 0)) return [];
            return N().unseenRows(this._cnShown(entry.key, m.at), m);
        },

        _cnPlaceDivider(key) {
            const entry = this._cnEntries().get(key);
            const ctx = this._cnContextFor(key);
            if (!entry || !ctx) return;
            entry.placed = true;
            ctx.container.querySelectorAll('.cn-divider').forEach((d) => d.remove());
            if (!entry.info && !entry.landed && entry.base > 0 && entry.mark.at > 0) {
                const rows = this._cnShown(key, entry.mark.at);
                const first = N().unseenFirst(rows, entry.mark);
                const row = first ? rows.find((r) => r.id === first) : null;
                if (row && row.at <= entry.openedAt) entry.info = { id: first };
            }
            const info = entry.info;
            if (info) {
                const wanted = !entry.landed && !entry.scrolled && Date.now() - (entry.openedMs || 0) < 8000;
                const find = () => this._cnFindMessage(ctx, info.id);
                let el = find();
                for (let i = 0; wanted && !el && i < 40; i++) {
                    const before = ctx.container.querySelectorAll('[data-message-id]').length;
                    this._cnLoadOlder(ctx, key);
                    el = find();
                    if (ctx.container.querySelectorAll('[data-message-id]').length === before) break;
                }
                if (wanted && !el) entry.landed = true;
                if (el && el.parentNode) {
                    const divider = document.createElement('div');
                    divider.className = 'cn-divider';
                    divider.setAttribute('role', 'separator');
                    divider.dataset.cnKey = key;
                    divider.innerHTML = `<span>${this.escapeHtml(this._cn(N().STRINGS.newMessages))}</span>`;
                    el.parentNode.insertBefore(divider, el);
                    if (typeof this._recomputeAllBubbleGrouping === 'function') this._recomputeAllBubbleGrouping(ctx.container);
                    if (wanted) {
                        entry.landed = true;
                        entry.landing = true;
                        if (ctx.col) ctx.col._atBottom = false;
                        else this.userScrolledUp = true;
                        requestAnimationFrame(() => {
                            entry.landing = false;
                            const now = this._cnContextFor(key);
                            const mark = now && now.container.querySelector('.cn-divider');
                            if (mark) {
                                const sc = now.scroller;
                                if (sc) sc.scrollTop += mark.getBoundingClientRect().top - sc.getBoundingClientRect().top;
                                if (ctx.col) ctx.col._atBottom = false;
                                else this.userScrolledUp = true;
                            }
                            this._cnUpdateFabs(key);
                        });
                    }
                }
            }
            this._cnUpdateFabs(key);
        },

        _cnFindMessage(ctx, id) {
            if (!id) return null;
            return ctx.container.querySelector('.message' + this._cnSelector(id));
        },

        _cnRows(ctx) {
            return ctx.container.querySelectorAll('.message[data-message-id]:not(.blocked-user-message):not(.blocked)');
        },

        _cnRowAt(el) {
            return Math.floor(Number(el && el.dataset.createdAt) || 0);
        },

        _cnMarkAt(key, rows, i) {
            const at = this._cnRowAt(rows[i]);
            const id = rows[i].dataset.messageId;
            const same = this._cnShown(key, at).filter((r) => r.at === at);
            const k = same.findIndex((r) => r.id === id);
            if (k >= 0) return { at, ids: same.slice(Math.max(0, k + 1 - N().JUMP.markMax), k + 1).map((r) => r.id) };
            const ids = [];
            for (let j = i; j >= 0 && ids.length < N().JUMP.markMax && this._cnRowAt(rows[j]) === at; j--) ids.push(rows[j].dataset.messageId);
            return { at, ids };
        },

        _cnTrack(key) {
            if (typeof document === 'undefined' || document.hidden) return;
            const ctx = this._cnContextFor(key);
            if (!ctx || !ctx.scroller) return;
            const entry = this._cnEntries().get(key);
            if (!entry || !entry.placed || entry.landing) return;
            const sc = ctx.scroller;
            if (sc._cnKeep && sc._cnKeep.shift && Math.abs(sc._cnKeep.shift()) >= 1) return;
            const v = sc.getBoundingClientRect();
            if (!(v.height > 0)) return;
            const rows = this._cnRows(ctx);
            const n = rows.length;
            const bottom = N().atBottom(sc.scrollTop);
            const i = bottom ? n - 1 : N().markIndex((k) => rows[k].getBoundingClientRect().bottom, v.top, v.bottom + 1, n);
            let mark = entry.mark;
            if (i >= 0) {
                const hit = this._cnMarkAt(key, rows, i);
                mark = N().markAdvance(mark, hit.at, hit.ids);
            }
            if (bottom && mark.at > 0) {
                const shown = this._cnShown(key, mark.at);
                const last = shown.length ? shown[shown.length - 1].at : 0;
                if (last > 0) mark = N().markAdvance(mark, last, shown.filter((r) => r.at === last).map((r) => r.id));
            }
            if (mark !== entry.mark) this._cnSetMark(entry, mark);
            const ms = this._cnMentions();
            const mc = ms.chats[key];
            if (!mc || !mc.ids.length) return;
            const next = bottom ? N().mentionClear(ms, key, Date.now()) : N().mentionMark(ms, key, entry.mark, Date.now());
            if (N().mentionCount(next, key) === mc.ids.length) return;
            this._cnSweeping = true;
            try {
                this._cnSetMentions(next, [key]);
            } finally {
                this._cnSweeping = false;
            }
        },

        _cnOpenKeys() {
            if (this._cvActive) return (this._cvColumns || []).map((c) => c.key).filter(Boolean);
            const k = this._cnSingleKey();
            return k ? [k] : [];
        },

        _cnLoadOlder(ctx, k) {
            const prev = this._cvLoadCtx;
            if (ctx.col) this._cvLoadCtx = { container: ctx.container, scroller: ctx.scroller };
            try {
                if (this._cnIsConv(k)) {
                    if (typeof this.loadOlderPMMessages === 'function') this.loadOlderPMMessages(k);
                } else if (typeof this.loadOlderChannelMessages === 'function') {
                    this.loadOlderChannelMessages(k);
                }
            } finally {
                this._cvLoadCtx = prev;
            }
        },

        _cnAnchor(ctx, entry, id) {
            const el = this._cnFindMessage(ctx, id);
            if (!el) return null;
            const divider = ctx.container.querySelector('.cn-divider');
            return divider && entry && entry.info && entry.info.id === id && divider.nextElementSibling === el ? divider : el;
        },

        _cnJumpDir(ctx, entry, id) {
            const anchor = this._cnAnchor(ctx, entry, id);
            if (anchor) return N().jumpDir({ top: anchor.getBoundingClientRect().top, viewTop: ctx.scroller.getBoundingClientRect().top });
            const hit = this._cnRaw(entry.key).find((x) => this._cnDomId(x) === id);
            const first = ctx.container.querySelector('.message[data-message-id]');
            const firstAt = first ? this._cnRowAt(first) : 0;
            return N().jumpDir({ at: hit ? this._cnAt(hit) : firstAt, firstAt });
        },

        _cnFabHost(ctx) {
            if (ctx.col) {
                if (!ctx.col._cnFabs) {
                    const wrap = document.createElement('div');
                    wrap.className = 'cn-fabs cn-fabs-col';
                    if (ctx.col.scrollBtn) wrap.appendChild(ctx.col.scrollBtn);
                    ctx.col.el.appendChild(wrap);
                    ctx.col._cnFabs = wrap;
                }
                return ctx.col._cnFabs;
            }
            let wrap = document.getElementById('cnFabs');
            if (!wrap) {
                const anchor = document.getElementById('scrollToBottomBtn');
                if (!anchor || !anchor.parentNode) return null;
                wrap = document.createElement('div');
                wrap.id = 'cnFabs';
                wrap.className = 'cn-fabs';
                anchor.parentNode.insertBefore(wrap, anchor);
                wrap.appendChild(anchor);
            }
            return wrap;
        },

        _cnFabButtons(host) {
            let jump = host.querySelector('.cn-jump');
            if (!jump) {
                jump = document.createElement('button');
                jump.type = 'button';
                jump.className = 'cn-jump nm-hidden';
                jump.dataset.action = 'cnJumpFirstUnread';
                host.appendChild(jump);
            }
            let at = host.querySelector('.cn-mention-fab');
            if (!at) {
                at = document.createElement('button');
                at.type = 'button';
                at.className = 'cn-mention-fab nm-hidden';
                at.dataset.action = 'cnJumpMention';
                at.innerHTML = ICONS.at + '<span class="cn-at-count"></span>';
                host.appendChild(at);
            }
            const slots = { mention: at, jump, bottom: host.querySelector('.scroll-to-bottom-btn, .cv-scroll-bottom') };
            const want = N().fabRow(slots);
            const have = [...host.children].filter((el) => want.some((k) => slots[k] === el));
            if (have.some((el, i) => el !== slots[want[i]])) for (const k of want) host.appendChild(slots[k]);
            return { jump, at };
        },

        _cnSchedule(key) {
            if (!key) return;
            if (!this._cnDue) this._cnDue = new Set();
            this._cnDue.add(key);
            if (this._cnDueRaf) return;
            this._cnDueRaf = requestAnimationFrame(() => {
                this._cnDueRaf = null;
                const keys = [...this._cnDue];
                this._cnDue.clear();
                for (const k of keys) this._cnUpdateFabs(k);
            });
        },

        _cnUpdateFabs(key) {
            const ctx = this._cnContextFor(key);
            if (!ctx) return;
            const host = this._cnFabHost(ctx);
            if (!host) return;
            host.dataset.cnKey = key;
            if (!this._cnSweeping) this._cnTrack(key);
            const { jump, at } = this._cnFabButtons(host);
            const entry = this._cnEntries().get(key);
            const unseen = entry ? this._cnUnseen(entry) : [];
            const showJump = unseen.length > 0;
            if (showJump) {
                const label = N().jumpText(unseen.length, (s) => this._cn(s));
                const dir = this._cnJumpDir(ctx, entry, unseen[0]);
                if (jump.dataset.cnLabel !== label || jump.dataset.cnDir !== dir) {
                    jump.dataset.cnLabel = label;
                    jump.dataset.cnDir = dir;
                    jump.innerHTML = `${dir === 'down' ? ICONS.arrowDown : ICONS.arrowUp}<span>${this.escapeHtml(label)}</span>`;
                }
                jump.title = this._cn(N().STRINGS.jumpFirst);
                jump.setAttribute('aria-label', label);
            } else {
                delete jump.dataset.cnLabel;
                delete jump.dataset.cnDir;
            }
            jump.classList.toggle('nm-hidden', !showJump);
            const n = N().mentionCount(this._cnMentions(), key);
            at.classList.toggle('nm-hidden', n <= 0);
            at.querySelector('.cn-at-count').textContent = n > 0 ? String(n) : '';
            at.setAttribute('aria-label', this._cn(N().STRINGS.mentions) + (n ? ' (' + n + ')' : ''));
        },

        _cnKeepAnchor(sc, list) {
            if (!sc || !list || sc._cnKeep || typeof ResizeObserver === 'undefined' || typeof this._scrollAnchorFor !== 'function') return;
            sc.style.overflowAnchor = 'none';
            const keep = sc._cnKeep = { top: sc.scrollTop, el: null, at: 0, shift: null };
            keep.shift = () => (keep.el && keep.el.isConnected && Math.abs(sc.scrollTop) >= 2
                ? keep.el.getBoundingClientRect().top - keep.at + (sc.scrollTop - keep.top) : 0);
            const settle = () => {
                const d = keep.shift();
                if (Math.abs(d) >= 1) sc.scrollTop += d;
                keep.top = sc.scrollTop;
                const a = this._scrollAnchorFor(list);
                keep.el = a ? a.el : null;
                keep.at = a ? a.top : 0;
            };
            sc.addEventListener('scroll', settle, { passive: true });
            new ResizeObserver(settle).observe(list);
            settle();
        },

        _cnBindScroll(ctx) {
            const sc = ctx.scroller;
            this._cnKeepAnchor(sc, ctx.container);
            if (typeof this._dsBind === 'function') this._dsBind(sc, ctx.container);
            if (!sc || sc._cnBound) return;
            sc._cnBound = true;
            let pending = false;
            const mark = () => {
                const k = ctx.col ? ctx.col.key : this._cnSingleKey();
                const e = this._cnEntries().get(k);
                if (e) {
                    e.scrolled = true;
                    e.pin = null;
                }
            };
            sc.addEventListener('wheel', mark, { passive: true });
            sc.addEventListener('touchmove', mark, { passive: true });
            sc.addEventListener('pointerdown', mark, { passive: true });
            sc.addEventListener('keydown', mark, { passive: true });
            sc.addEventListener('scroll', () => {
                if (pending) return;
                pending = true;
                requestAnimationFrame(() => {
                    pending = false;
                    const k = ctx.col ? ctx.col.key : this._cnSingleKey();
                    if (k) this._cnUpdateFabs(k);
                });
            }, { passive: true });
        },

        _cnAfterRender(key) {
            if (!key) return;
            const ctx = this._cnContextFor(key);
            if (!ctx) return;
            this._cnBindScroll(ctx);
            if (!this._cnEntries().has(key)) {
                this._cnUpdateFabs(key);
                return;
            }
            this._cnPlaceDivider(key);
            this._cnCenter(key);
        },

        async jumpToFirstUnread(key) {
            const k = key || this._cnActiveKey();
            const entry = this._cnEntries().get(k);
            const ctx = this._cnContextFor(k);
            if (!entry || !ctx) return false;
            entry.placed = true;
            entry.landing = false;
            entry.landed = true;
            this._cnTrack(k);
            entry.scrolled = true;
            const target = this._cnUnseen(entry)[0] || null;
            let el = this._cnFindMessage(ctx, target);
            for (let i = 0; target && !el && i < 40; i++) {
                const before = ctx.container.querySelectorAll('[data-message-id]').length;
                this._cnLoadOlder(ctx, k);
                el = this._cnFindMessage(ctx, target);
                if (ctx.container.querySelectorAll('[data-message-id]').length === before) break;
            }
            if (el) {
                if (ctx.col) ctx.col._atBottom = false;
                else this.userScrolledUp = true;
                entry.pin = { id: target, until: Date.now() + 1500 };
                this._cnCenter(k);
                requestAnimationFrame(() => this._cnCenter(k));
                setTimeout(() => this._cnCenter(k), 300);
                setTimeout(() => this._cnCenter(k), 900);
            }
            this._cnUpdateFabs(k);
            return !!el;
        },

        _cnCenter(key) {
            const entry = this._cnEntries().get(key);
            const ctx = this._cnContextFor(key);
            const pin = entry && entry.pin;
            if (!ctx || !pin || Date.now() > pin.until) return;
            const anchor = this._cnAnchor(ctx, entry, pin.id);
            if (!anchor) return;
            const want = anchor.getBoundingClientRect().top - ctx.scroller.getBoundingClientRect().top - N().JUMP.landPx;
            if (Math.abs(want) < 2) return;
            ctx.scroller.scrollTop += want;
            if (ctx.col) ctx.col._atBottom = false;
            else this.userScrolledUp = true;
        },

        _cnActiveKey() {
            if (this._cvActive) {
                const col = this._cvColumns && this._cvColumns.find((c) => c.id === this._cvFocusedId);
                return col ? col.key : null;
            }
            return this._cnSingleKey();
        },

        _cnMentionKey() {
            return 'nym_unread_mentions:' + (this.pubkey || 'anon');
        },

        _cnMentions() {
            if (this._cnMentionCache && this._cnMentionCache.pk === this.pubkey) return this._cnMentionCache.state;
            let state = N().emptyMentions();
            try {
                const raw = localStorage.getItem(this._cnMentionKey());
                if (raw) state = N().normalizeMentions(JSON.parse(raw));
            } catch (_) { state = N().emptyMentions(); }
            this._cnMentionCache = { pk: this.pubkey, state };
            return state;
        },

        _cnSetMentions(state, keys) {
            this._cnMentionCache = { pk: this.pubkey, state };
            if (!this._cnMentionTimer) {
                this._cnMentionTimer = setTimeout(() => {
                    this._cnMentionTimer = null;
                    try { localStorage.setItem(this._cnMentionKey(), JSON.stringify(this._cnMentions())); } catch (_) { }
                }, MENTION_SAVE_MS);
            }
            for (const k of (keys || [])) {
                this._cnRenderMentionBadge(k);
                this._cnUpdateFabs(k);
            }
        },

        _cnPruneHiddenMentions() {
            if (typeof this.isContentHidden !== 'function') return;
            let state = this._cnMentions();
            const changed = [];
            for (const key of Object.keys((state && state.chats) || {})) {
                const ids = ((state.chats[key] || {}).ids || []).map((e) => e.id);
                if (!ids.length) continue;
                const store = this._cnIsConv(key) ? this.pmMessages : this.messages;
                const list = (store && store.get(key)) || [];
                const byId = new Map();
                for (const m of list) {
                    if (!m) continue;
                    if (m.id) byId.set(m.id, m);
                    if (m.nymMessageId) byId.set(m.nymMessageId, m);
                }
                const gone = ids.filter((id) => byId.has(id) && this.isContentHidden(byId.get(id)));
                if (!gone.length) continue;
                state = N().mentionDrop(state, key, gone);
                changed.push(key);
            }
            if (changed.length) this._cnSetMentions(state, changed);
        },

        unreadMentionCount(key) {
            return N().mentionCount(this._cnMentions(), key);
        },

        _cnScanMentionsOnOpen(entry) {
            const list = this._cnStoreList(entry.key).map((m) => Object.assign(this._cnRow(m), { mention: this._cnIsMention(m) }));
            const items = N().mentionScan(list, entry.lastRead, entry.openedAt);
            if (items.length) this._cnSetMentions(N().mentionAdd(this._cnMentions(), entry.key, items, Date.now()), [entry.key]);
        },

        _cnScanClosed(key) {
            if (!key) return;
            if (!this._cnScanQueue) this._cnScanQueue = new Set();
            this._cnScanQueue.add(key);
            if (this._cnScanTimer) return;
            this._cnScanTimer = setTimeout(() => {
                this._cnScanTimer = null;
                const keys = [...this._cnScanQueue];
                this._cnScanQueue.clear();
                let state = this._cnMentions();
                const changed = [];
                for (const k of keys) {
                    if (this._cnContextFor(k)) continue;
                    const floor = (this.channelLastRead && this.channelLastRead.get(k)) || 0;
                    const list = this._cnStoreList(k).map((m) => Object.assign(this._cnRow(m), { mention: this._cnIsMention(m) }));
                    const items = N().mentionScan(list, floor, 0);
                    if (!items.length) continue;
                    const next = N().mentionAdd(state, k, items, Date.now());
                    if (next !== state) { state = next; changed.push(k); }
                }
                if (changed.length) this._cnSetMentions(state, changed);
            }, 200);
        },

        _cnOnDisplayed(message) {
            if (!message || message._threadRender) return;
            const key = message.isPM ? message.conversationKey : (message.geohash ? `#${message.geohash}` : message.channel);
            if (!key) return;
            const ctx = this._cnContextFor(key);
            if (!ctx) return;
            const entry = this._cnEntries().get(key);
            const row = this._cnRow(message);
            if (row.own) {
                if (entry && !this._bulkAppending && !message.isHistorical) {
                    const rows = [...this._cnRows(ctx)];
                    const i = rows.findIndex((el) => el.dataset.messageId === row.id);
                    const hit = i >= 0 ? this._cnMarkAt(key, rows, i) : { at: row.at, ids: [row.id] };
                    this._cnSetMark(entry, N().markAdvance(entry.mark, hit.at, hit.ids));
                    this._cnSchedule(key);
                }
                return;
            }
            if (entry && !entry.info && !entry.landed && entry.base > 0 && row.at <= entry.openedAt) {
                if (!this._cnLatePlace) this._cnLatePlace = new Set();
                this._cnLatePlace.add(key);
                if (!this._cnLateTimer) {
                    this._cnLateTimer = setTimeout(() => {
                        this._cnLateTimer = null;
                        const keys = [...this._cnLatePlace];
                        this._cnLatePlace.clear();
                        for (const k of keys) {
                            const e = this._cnEntries().get(k);
                            if (e && !e.info && !e.landed) {
                                const m = this._cnStoreList(k).map((x) => Object.assign(this._cnRow(x), { mention: this._cnIsMention(x) }));
                                const items = N().mentionScan(m, e.lastRead, e.openedAt);
                                if (items.length) this._cnSetMentions(N().mentionAdd(this._cnMentions(), k, items, Date.now()), [k]);
                                this._cnPlaceDivider(k);
                            }
                        }
                    }, 150);
                }
            }
            if (!this._bulkAppending && !message.isHistorical && entry && !N().markUnder(entry.mark, row.at, row.id) && this._cnIsMention(message)
                && (document.hidden || !N().atBottom(ctx.scroller.scrollTop))) {
                this._cnSetMentions(N().mentionAdd(this._cnMentions(), key, [{ id: row.id, at: row.at }], Date.now()), [key]);
            }
            this._cnSchedule(key);
        },

        async jumpToNextMention(key) {
            const k = key || this._cnActiveKey();
            const ctx = this._cnContextFor(k);
            if (!ctx) return false;
            for (let guard = 0; guard < 200; guard++) {
                const id = N().mentionNext(this._cnMentions(), k);
                if (!id) { this._cnUpdateFabs(k); return false; }
                let el = ctx.container.querySelector('.message' + this._cnSelector(id));
                for (let i = 0; !el && i < 20; i++) {
                    const inStore = this._cnStoreList(k).some((m) => this._cnDomId(m) === id);
                    if (!inStore) break;
                    const before = ctx.container.querySelectorAll('[data-message-id]').length;
                    this._cnLoadOlder(ctx, k);
                    el = ctx.container.querySelector('.message' + this._cnSelector(id));
                    if (ctx.container.querySelectorAll('[data-message-id]').length === before) break;
                }
                if (!el) {
                    this._cnSetMentions(N().mentionDrop(this._cnMentions(), k, [id]), [k]);
                    continue;
                }
                const entry = this._cnEntries().get(k);
                if (entry) entry.scrolled = true;
                el.scrollIntoView({ block: 'center', behavior: 'smooth' });
                el.classList.remove('cn-flash');
                void el.offsetWidth;
                el.classList.add('cn-flash');
                setTimeout(() => el.classList.remove('cn-flash'), 1600);
                if (ctx.col) ctx.col._atBottom = false;
                else this.userScrolledUp = true;
                this._cnSetMentions(N().mentionSeen(this._cnMentions(), k, id, Date.now()), [k]);
                return true;
            }
            return false;
        },

        _cnSidebarItem(key) {
            if (typeof document === 'undefined') return null;
            const k = String(key || '');
            if (k.startsWith('pm-')) {
                const parts = k.slice(3).split('-');
                const other = parts.find((p) => p && p !== this.pubkey) || parts[0];
                return other ? document.querySelector(`#pmList .pm-item[data-pubkey="${other}"]`) : null;
            }
            if (k.startsWith('group-')) return document.querySelector(`#pmList [data-group-id="${k.slice(6)}"]`);
            const name = k.replace(/^#/, '');
            return document.querySelector(`#channelList .channel-item[data-geohash="${name}"]`)
                || document.querySelector(`#channelList .channel-item[data-channel="${name}"]`);
        },

        _cnRenderMentionBadge(key) {
            const item = this._cnSidebarItem(key);
            if (!item) return;
            const n = N().mentionCount(this._cnMentions(), key);
            let badge = item.querySelector('.cn-mention-badge');
            if (n <= 0) { if (badge) badge.remove(); return; }
            if (!badge) {
                badge = document.createElement('span');
                badge.className = 'cn-mention-badge';
                badge.textContent = '@';
                const unread = item.querySelector('.unread-badge');
                if (unread && unread.parentNode) unread.parentNode.insertBefore(badge, unread);
                else item.appendChild(badge);
            }
            badge.title = this._cn(N().STRINGS.mentions) + ' (' + n + ')';
            badge.setAttribute('aria-label', badge.title);
        },

        _cnRenderAllMentionBadges() {
            const st = this._cnMentions();
            for (const k of Object.keys(st.chats)) this._cnRenderMentionBadge(k);
        },

        _cnPruneRemoteRead(changes) {
            if (!changes || !changes.length) return;
            let state = this._cnMentions();
            const keys = [];
            for (const [k, v] of changes) {
                if (this._cnContextFor(k)) continue;
                const next = N().mentionPrune(state, k, v);
                if (next !== state) { state = next; keys.push(k); }
            }
            if (keys.length) this._cnSetMentions(state, keys);
        },

        _pinStorageKey() {
            return N().KEYS.pinned + ':' + (this.pubkey || 'anon');
        },

        _pinPendingKey() {
            return N().KEYS.pinnedPending + ':' + (this.pubkey || 'anon');
        },

        _pinState() {
            if (this._pinCache && this._pinCache.pk === this.pubkey) return this._pinCache.state;
            let state = N().emptyPins();
            try {
                const raw = localStorage.getItem(this._pinStorageKey());
                if (raw) state = N().normalizePins(JSON.parse(raw));
            } catch (_) { state = N().emptyPins(); }
            this._pinCache = { pk: this.pubkey, state };
            return state;
        },

        _pinPersist(state) {
            this._pinCache = { pk: this.pubkey, state };
            try { localStorage.setItem(this._pinStorageKey(), JSON.stringify(state)); } catch (_) { }
        },

        _pinPending() {
            try { return localStorage.getItem(this._pinPendingKey()) === '1'; } catch (_) { return false; }
        },

        _pinSetPending(on) {
            try {
                if (on) localStorage.setItem(this._pinPendingKey(), '1');
                else localStorage.removeItem(this._pinPendingKey());
            } catch (_) { }
        },

        _pinSyncAllowed() {
            return typeof this.savedMode !== 'function' || this.savedMode() === 'sync';
        },

        pinnedChatKeys() {
            return N().pinList(this._pinState());
        },

        isChatPinned(pinKey) {
            return N().isPinned(this._pinState(), pinKey);
        },

        _pinChatNameHtml(p) {
            const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
            if (p.kind === 'dm') {
                return typeof this.getNymHtmlFromPubkey === 'function' ? this.getNymHtmlFromPubkey(p.id) : esc(p.id.slice(0, 8));
            }
            const g = this.groupConversations && this.groupConversations.get(p.id);
            return esc(g ? (typeof this._groupLabel === 'function' ? this._groupLabel(g) : (g.name || p.id.slice(0, 8))) : p.id.slice(0, 8));
        },

        _pinKeyForItem(itemEl) {
            if (!itemEl) return '';
            if (itemEl.classList.contains('channel-item')) return N().pinKey('channel', itemEl.dataset.geohash || itemEl.dataset.channel);
            if (itemEl.dataset.groupId) return N().pinKey('group', itemEl.dataset.groupId);
            if (itemEl.dataset.pubkey) return N().pinKey('dm', itemEl.dataset.pubkey);
            return '';
        },

        togglePinChat(pinKey) {
            const N_ = N();
            if (!N_.pinParse(pinKey)) return false;
            if (pinKey === 'c:nymchat') {
                this._cnNotice(this._cn('#nymchat is always at the top'));
                return false;
            }
            const now = Date.now();
            let state = this._pinState();
            if (N_.isPinned(state, pinKey)) {
                const index = N_.pinList(state).indexOf(pinKey);
                this._pinCommit(N_.pinRemove(state, pinKey, now));
                const p = N_.pinParse(pinKey);
                if (typeof this.showUndoToast === 'function') {
                    const undo = () => this.restorePinChat(pinKey, index);
                    if (p.kind === 'channel') this.showUndoToast(this._cn(N_.STRINGS.unfavorited, { channel: p.id }), undo);
                    else this.showUndoToast(this._cn(N_.STRINGS.unfavoritedChat, { name: this._pinChatNameHtml(p) }), undo, { html: true });
                }
                return true;
            } else {
                const r = N_.pinAdd(state, pinKey, now);
                if (r.error === 'cap') {
                    this._cnNotice(this._cn(N_.pinParse(pinKey).kind === 'channel' ? N_.STRINGS.favoriteCap : N_.STRINGS.favoriteChatCap, { n: N_.LIMITS.pinMax }));
                    return false;
                }
                state = r.state;
            }
            this._pinCommit(state);
            return true;
        },

        restorePinChat(pinKey, index) {
            const N_ = N();
            const state = this._pinState();
            if (N_.isPinned(state, pinKey)) return;
            const r = N_.pinAdd(state, pinKey, Date.now());
            if (r.error) return;
            this._pinCommit(N_.pinMove(r.state, pinKey, index, Date.now()));
            if (typeof this._refreshFavoriteChannelBtn === 'function') this._refreshFavoriteChannelBtn();
        },

                movePinnedChat(pinKey, dir) {
            const state = this._pinState();
            const order = N().pinList(state);
            const p = N().pinParse(pinKey);
            if (!p) return;
            const sameList = order.filter((k) => {
                const q = N().pinParse(k);
                return q && ((p.kind === 'channel') === (q.kind === 'channel'));
            });
            const i = sameList.indexOf(pinKey);
            const j = i + dir;
            if (i < 0 || j < 0 || j >= sameList.length) return;
            const next = sameList.slice();
            next.splice(i, 1);
            next.splice(j, 0, pinKey);
            this._pinCommit(N().pinReorderWithin(state, next, Date.now()));
        },

        _pinCommit(state) {
            this._pinPersist(state);
            this._pinRev = (this._pinRev || 0) + 1;
            this._pinSetPending(this._pinSyncAllowed());
            this._pinApply(true);
            this._pinSync();
        },

        _pinApply(saveLegacy) {
            const channels = N().pinChannels(this._pinState());
            const before = JSON.stringify([...(this.pinnedChannels || [])].sort());
            this.pinnedChannels = new Set(channels);
            if (saveLegacy && before !== JSON.stringify([...channels].sort())) {
                try { localStorage.setItem('nym_pinned_channels', JSON.stringify(channels)); } catch (_) { }
                if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
            }
            if (typeof document === 'undefined') return;
            if (typeof this.updateChannelPins === 'function') this.updateChannelPins();
            if (typeof this.sortChannelsByActivity === 'function' && document.getElementById('channelList')) this.sortChannelsByActivity();
            this._pinOrderPmList();
            if (typeof this._refreshFavoriteChannelBtn === 'function') this._refreshFavoriteChannelBtn();
            if (typeof this.applyHiddenChannels === 'function') this.applyHiddenChannels();
        },

        _pinAfterLegacyChange() {
            const legacy = [...(this.pinnedChannels || [])];
            const state = this._pinState();
            const next = N().pinImportLegacy(state, legacy, Date.now());
            if (next !== state) {
                this._pinPersist(next);
                this._pinRev = (this._pinRev || 0) + 1;
                this._pinSetPending(this._pinSyncAllowed());
                setTimeout(() => this._pinSync(), 0);
            }
            this._pinApply(false);
        },

        _pinChannelIndex(el) {
            if (!el) return -1;
            if (!this._pinChanIdx || this._pinChanIdx.rev !== this._pinRev || this._pinChanIdx.pk !== this.pubkey) {
                const map = new Map();
                N().pinChannels(this._pinState()).forEach((c, i) => map.set(c, i));
                this._pinChanIdx = { rev: this._pinRev, pk: this.pubkey, map };
            }
            const k = String(el.dataset.geohash || el.dataset.channel || '').toLowerCase();
            return this._pinChanIdx.map.has(k) ? this._pinChanIdx.map.get(k) : -1;
        },

        _pinMarkChannelRows() {
            if (typeof document === 'undefined') return;
            document.querySelectorAll('#channelList .channel-item').forEach((row) => this._pinMarkRow(row, this._pinChannelIndex(row) >= 0));
        },

        _pinOrderPmList() {
            const list = typeof document !== 'undefined' ? document.getElementById('pmList') : null;
            if (!list) return;
            const order = N().pinList(this._pinState());
            const rows = Array.from(list.querySelectorAll('.pm-item'));
            const pinned = [];
            for (const row of rows) {
                const k = this._pinKeyForItem(row);
                const idx = order.indexOf(k);
                row.classList.toggle('chat-pinned', idx >= 0);
                this._pinMarkRow(row, idx >= 0);
                if (idx >= 0) pinned.push({ row, idx });
            }
            pinned.sort((a, b) => a.idx - b.idx);
            let ref = list.firstElementChild;
            for (const { row } of pinned) {
                if (row === ref) ref = ref.nextElementSibling;
                else list.insertBefore(row, ref);
            }
            if (typeof this._markListOverflow === 'function') this._markListOverflow('pmList');
        },

        _pinMarkRow(row, on) {
            let icon = row.querySelector('.chat-pin-icon');
            row.draggable = !!on;
            if (on && !icon) {
                icon = document.createElement('span');
                icon.className = 'chat-pin-icon';
                icon.innerHTML = ICONS.starFilled;
                icon.title = this._cn(N().STRINGS.favorited);
                const badges = row.querySelector('.channel-badges');
                if (badges) badges.insertBefore(icon, badges.firstChild);
                else row.appendChild(icon);
            } else if (!on && icon) {
                icon.remove();
            }
            if (on) this._pinBindDrag(row);
        },

        _pinBindDrag(row) {
            if (row._pinDragBound) return;
            row._pinDragBound = true;
            const pinnedRow = () => this.isChatPinned(this._pinKeyForItem(row));
            row.addEventListener('dragstart', (e) => {
                if (!pinnedRow() || (this._pinG && this._pinG.phase !== 'idle')) { e.preventDefault(); return; }
                this._pinDragKey = this._pinKeyForItem(row);
                row.classList.add('chat-pin-dragging');
                try { e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', this._pinDragKey); } catch (_) { }
            });
            row.addEventListener('dragend', () => {
                row.classList.remove('chat-pin-dragging');
                this._pinDragKey = null;
            });
            row.addEventListener('dragover', (e) => {
                if (!this._pinDragKey || !this._pinCanDrop(this._pinDragKey, this._pinKeyForItem(row))) return;
                e.preventDefault();
            });
            row.addEventListener('drop', (e) => {
                const from = this._pinDragKey;
                const to = this._pinKeyForItem(row);
                if (!from || !this._pinCanDrop(from, to)) return;
                e.preventDefault();
                this._pinDropOn(from, to);
            });
        },

        _pinCanDrop(fromKey, toKey) {
            if (!fromKey || !toKey || fromKey === toKey) return false;
            if (!this.isChatPinned(fromKey) || !this.isChatPinned(toKey)) return false;
            const fp = N().pinParse(fromKey);
            const tp = N().pinParse(toKey);
            return !!fp && !!tp && ((fp.kind === 'channel') === (tp.kind === 'channel'));
        },

        _pinDropOn(fromKey, toKey) {
            if (!this._pinCanDrop(fromKey, toKey)) return;
            const state = this._pinState();
            const fp = N().pinParse(fromKey);
            const sameList = N().pinList(state).filter((k) => ((N().pinParse(k).kind === 'channel') === (fp.kind === 'channel')));
            const next = sameList.filter((k) => k !== fromKey);
            next.splice(next.indexOf(toKey), 0, fromKey);
            this._pinCommit(N().pinReorderWithin(state, next, Date.now()));
        },

        _pinScroller(list) {
            for (let el = list; el && el !== document.body; el = el.parentElement) {
                const oy = getComputedStyle(el).overflowY;
                if ((oy === 'auto' || oy === 'scroll') && el.scrollHeight > el.clientHeight) return el;
            }
            return null;
        },

        _pinTouchEnd(keepClickShut) {
            const g = this._pinTouch;
            this._pinTouch = null;
            if (!g) return;
            clearTimeout(g.timer);
            if (g.raf) cancelAnimationFrame(g.raf);
            if (g.row) {
                g.row.classList.remove('chat-pin-armed', 'chat-pin-dragging', 'chat-pin-touch-drag');
                g.row.style.transform = '';
            }
            if (g.target) g.target.classList.remove('chat-pin-drop');
            if (g.scroller) g.scroller.classList.remove('chat-pin-lock');
            if (keepClickShut) this._pinClickShutUntil = Date.now() + 700;
        },

        _pinTouchOver(x, y) {
            const g = this._pinTouch;
            if (!g || !g.row) return;
            const scrolled = g.scroller ? g.scroller.scrollTop - g.scroll0 : 0;
            g.row.style.transform = `translateY(${(y - g.y0) + scrolled}px)`;
            const under = document.elementFromPoint(x, y);
            const row = under && under.closest ? under.closest('.channel-item, .pm-item') : null;
            const ok = row && row !== g.row && this._pinCanDrop(g.key, this._pinKeyForItem(row)) ? row : null;
            if (g.target && g.target !== ok) g.target.classList.remove('chat-pin-drop');
            if (ok) ok.classList.add('chat-pin-drop');
            g.target = ok;
        },

        _pinTouchScrollLoop() {
            const g = this._pinTouch;
            if (!g || !g.scroller || this._pinG.phase !== 'dragging') return;
            const r = g.scroller.getBoundingClientRect();
            const step = N().pinAutoScroll(g.y, r.top, r.bottom);
            if (step) {
                g.scroller.scrollTop += step;
                this._pinTouchOver(g.x, g.y);
            }
            g.raf = requestAnimationFrame(() => this._pinTouchScrollLoop());
        },

        _pinTouchApply(fx) {
            for (const f of fx) {
                const g = this._pinTouch;
                if (f.t === 'wait' && g) {
                    g.timer = setTimeout(() => this._pinTouchEvent({ t: 'arm' }), f.ms);
                } else if (f.t === 'armed' && g) {
                    if (window.nymHaptic) window.nymHaptic('selection');
                    g.row.classList.add('chat-pin-armed');
                    if (g.scroller) g.scroller.classList.add('chat-pin-lock');
                } else if (f.t === 'start' && g) {
                    g.row.classList.add('chat-pin-dragging', 'chat-pin-touch-drag');
                    g.raf = requestAnimationFrame(() => this._pinTouchScrollLoop());
                } else if (f.t === 'over' && g) {
                    g.x = f.x;
                    g.y = f.y;
                    this._pinTouchOver(f.x, f.y);
                } else if (f.t === 'drop' && g) {
                    const target = g.target;
                    const from = g.key;
                    this._pinTouchEnd(true);
                    if (target) this._pinDropOn(from, this._pinKeyForItem(target));
                } else if (f.t === 'menu' && g) {
                    const row = g.row;
                    this._pinTouchEnd(true);
                    const items = this._buildSidebarMenuItems(row);
                    if (items.length) {
                        if (window.nymHaptic) window.nymHaptic('selection');
                        this._showSidebarActionMenu(items, f.x, f.y);
                    }
                } else if (f.t === 'abort') {
                    this._pinTouchEnd(true);
                }
            }
        },

        _pinTouchEvent(ev, row) {
            const prev = this._pinG || N().pinGestureIdle();
            const r = N().pinGestureStep(prev, ev);
            this._pinG = r.state;
            if (ev.t === 'down') {
                this._pinTouchEnd(false);
                if (r.state.phase === 'pending') {
                    const list = row.closest('#channelList, #pmList');
                    const scroller = list ? this._pinScroller(list) : null;
                    this._pinTouch = { row, key: r.state.key, y0: ev.y, x: ev.x, y: ev.y, scroller, scroll0: scroller ? scroller.scrollTop : 0, target: null, timer: null, raf: 0 };
                }
            }
            this._pinTouchApply(r.fx);
            if (r.state.phase === 'idle' && ev.t !== 'down' && this._pinTouch) this._pinTouchEnd(false);
        },

        _pinBindTouch() {
            if (typeof document === 'undefined' || this._pinTouchBound) return;
            const lists = ['channelList', 'pmList'].map((id) => document.getElementById(id)).filter(Boolean);
            if (!lists.length) return;
            this._pinTouchBound = true;
            for (const list of lists) {
                list.addEventListener('pointerdown', (e) => {
                    if (e.pointerType === 'mouse' || !e.isPrimary) return;
                    const row = e.target.closest && e.target.closest('.channel-item, .pm-item');
                    if (!row || !list.contains(row) || e.target.closest('.row-menu-btn')) return;
                    const key = this._pinKeyForItem(row);
                    this._pinTouchEvent({ t: 'down', x: e.clientX, y: e.clientY, key: this.isChatPinned(key) ? key : '', pointer: e.pointerType }, row);
                }, { passive: true });
                list.addEventListener('pointermove', (e) => {
                    if (!this._pinTouch || e.pointerType === 'mouse') return;
                    this._pinTouchEvent({ t: 'move', x: e.clientX, y: e.clientY });
                }, { passive: true });
                list.addEventListener('pointerup', (e) => {
                    if (!this._pinTouch || e.pointerType === 'mouse') return;
                    this._pinTouchEvent({ t: 'up', x: e.clientX, y: e.clientY });
                });
                list.addEventListener('pointercancel', () => {
                    if (this._pinTouch) this._pinTouchEvent({ t: 'cancel' });
                });
                list.addEventListener('touchmove', (e) => {
                    if (N().pinGestureLocks(this._pinG) && e.cancelable) e.preventDefault();
                }, { passive: false });
                list.addEventListener('touchend', (e) => {
                    if (Date.now() < (this._pinClickShutUntil || 0) && e.cancelable) e.preventDefault();
                }, { passive: false });
                list.addEventListener('contextmenu', (e) => {
                    if (N().pinGestureLocks(this._pinG)) e.preventDefault();
                });
                list.addEventListener('click', (e) => {
                    if (Date.now() < (this._pinClickShutUntil || 0)) {
                        e.preventDefault();
                        e.stopPropagation();
                    }
                }, true);
            }
        },

        _pinMenuItems(itemEl) {
            if (N().pinGestureLocks(this._pinG)) return [];
            const k = this._pinKeyForItem(itemEl);
            if (!k || k === 'c:nymchat') return [];
            const pinned = this.isChatPinned(k);
            const isChannel = N().pinParse(k).kind === 'channel';
            const items = isChannel
                ? [{ label: this._cn(pinned ? N().STRINGS.unfavorite : N().STRINGS.favorite), svg: pinned ? ICONS.starFilled : ICONS.star, action: () => this.togglePinChat(k) }]
                : [{ label: this._cn(pinned ? N().STRINGS.unfavoriteChat : N().STRINGS.favoriteChat), svg: pinned ? ICONS.starFilled : ICONS.star, action: () => this.togglePinChat(k) }];
            if (pinned) {
                const same = this.pinnedChatKeys().filter((x) => (N().pinParse(x).kind === 'channel') === isChannel);
                const i = same.indexOf(k);
                if (i > 0) items.push({ label: this._cn(N().STRINGS.moveUp), svg: ICONS.up, action: () => this.movePinnedChat(k, -1) });
                if (i >= 0 && i < same.length - 1) items.push({ label: this._cn(N().STRINGS.moveDown), svg: ICONS.down, action: () => this.movePinnedChat(k, 1) });
            }
            return items;
        },

        async _pinSync() {
            if (!this._pinSyncAllowed()) return 'local';
            if (!this._pinPending()) return 'synced';
            const online = typeof this._ctOnline === 'function' ? this._ctOnline() : !!this.connected;
            if (!this.pubkey || !online || !this._settingsHydrated) return 'pending';
            if (this._pinSyncing) { this._pinResync = true; return 'pending'; }
            this._pinSyncing = true;
            this._pinResync = false;
            const rev = this._pinRev || 0;
            let ok = false;
            try {
                const dTag = N().KEYS.pinnedDTag;
                const payload = { pinnedChats: JSON.parse(JSON.stringify(this._pinState())) };
                if (!this._publishedSectionJson) this._publishedSectionJson = {};
                ok = this._publishedSectionJson[dTag] === JSON.stringify(payload);
                if (!ok && typeof this._publishCategoryWrap === 'function') {
                    const now = nowSec();
                    const changed = await this._publishCategoryWrap(payload, dTag, now, [N().trimPinnedPayload]);
                    ok = !!changed || this._publishedSectionJson[dTag] === JSON.stringify(payload);
                    if (changed && typeof this._publishSettingsChangedPing === 'function') {
                        await this._publishSettingsChangedPing(['pinned'], now);
                    }
                }
            } catch (_) {
                ok = false;
            } finally {
                this._pinSyncing = false;
            }
            if (ok && rev === (this._pinRev || 0)) this._pinSetPending(false);
            if (this._pinResync || (ok && rev !== (this._pinRev || 0))) {
                this._pinResync = false;
                return this._pinSync();
            }
            return this._pinPending() ? 'pending' : 'synced';
        },

        applySyncedPinned(remote) {
            if (!remote || typeof remote !== 'object') return;
            const local = this._pinState();
            const merged = N().mergePins(local, remote, Date.now());
            const remoteNorm = N().mergePins(remote, null, Date.now());
            this._pinPersist(merged);
            this._pinRev = (this._pinRev || 0) + 1;
            if (JSON.stringify(merged) !== JSON.stringify(remoteNorm) && this._pinSyncAllowed()) {
                this._pinSetPending(true);
                setTimeout(() => { this._pinSync(); }, 0);
            }
            this._pinApply(true);
        },

        _slItemsCache() {
            if (!this._slCache || this._slCache.pk !== this.pubkey) {
                let items = [];
                try {
                    const raw = localStorage.getItem(N().KEYS.scheduled + ':' + (this.pubkey || 'anon'));
                    if (raw) items = JSON.parse(raw);
                } catch (_) { items = []; }
                this._slCache = { pk: this.pubkey, items: Array.isArray(items) ? items : [] };
            }
            return this._slCache.items;
        },

        _slSetItems(items) {
            this._slCache = { pk: this.pubkey, items };
            try { localStorage.setItem(N().KEYS.scheduled + ':' + (this.pubkey || 'anon'), JSON.stringify(items)); } catch (_) { }
            this._slRenderBar();
            this._slRenderList();
        },

        _slChatKeyForView() {
            return this._cnActiveKey();
        },

        _slCanon(key) {
            const k = String(key || '');
            if (!k) return '';
            if (k.startsWith('pm-')) {
                const peer = this._ctPeerFromKey ? this._ctPeerFromKey(k) : k.slice(3);
                return peer ? 'pm-' + peer.toLowerCase() : '';
            }
            if (k.startsWith('group-')) return k;
            return '#' + k.replace(/^#/, '').toLowerCase();
        },

        _slMeshOnly(key) {
            const k = String(key || '');
            if (k.startsWith('pm-')) {
                const peer = this._ctPeerFromKey ? this._ctPeerFromKey(k) : '';
                if (/^mesh:/.test(peer)) return true;
                return !this.connected && typeof this.meshPmPeerId === 'function' && !!this.meshPmPeerId(peer);
            }
            if (k.startsWith('group-')) return false;
            const name = k.replace(/^#/, '');
            return typeof this.meshShouldCarry === 'function' && this.meshShouldCarry(name);
        },

        sendLaterBlockReason(key) {
            const k = key || this._slChatKeyForView();
            if (!k) return this._cn(N().STRINGS.serverBlocked);
            const kind = k.startsWith('pm-') ? 'dm' : k.startsWith('group-') ? 'group' : 'channel';
            const online = !!this.connected && !(typeof navigator !== 'undefined' && navigator.onLine === false);
            const reason = N().scheduleBlockReason({
                meshOnly: this._slMeshOnly(k),
                server: !!(typeof this._getApiHost === 'function' && this._getApiHost()) && !!this.pubkey,
                online,
                kind,
                localKey: !!this.privkey,
            });
            return reason ? this._cn(reason) : null;
        },

        _slOffsetMin() {
            return -new Date().getTimezoneOffset();
        },

        _slFormatTime(at) {
            return typeof this._formatFullTimestamp === 'function' ? this._formatFullTimestamp(at * 1000) : new Date(at * 1000).toLocaleString();
        },

        _slPresetLabel(id, at) {
            const time = new Date(at * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
            const map = { hour: 'In 1 hour', tonight: 'Tonight at {time}', tomorrow: 'Tomorrow at {time}', monday: 'Monday at {time}' };
            return this._cn(map[id] || '{time}', { time });
        },

        async _slEncryptNote(json) {
            const NT = window.NostrTools;
            if (this.privkey && NT && NT.nip44) {
                return NT.nip44.encrypt(json, NT.nip44.getConversationKey(this.privkey, this.pubkey));
            }
            if (window.nostr && window.nostr.nip44 && window.nostr.nip44.encrypt) return window.nostr.nip44.encrypt(this.pubkey, json);
            if (this.nostrLoginMethod === 'nip46' && typeof _nip46Encrypt === 'function') return _nip46Encrypt(this.pubkey, json);
            throw new Error('no-encrypt');
        },

        async _slDecryptNote(blob) {
            if (!blob) return null;
            if (!this._slNoteCache) this._slNoteCache = new Map();
            if (this._slNoteCache.has(blob)) return this._slNoteCache.get(blob);
            let json = null;
            try {
                const NT = window.NostrTools;
                if (this.privkey && NT && NT.nip44) json = NT.nip44.decrypt(blob, NT.nip44.getConversationKey(this.privkey, this.pubkey));
                else if (window.nostr && window.nostr.nip44 && window.nostr.nip44.decrypt) json = await window.nostr.nip44.decrypt(this.pubkey, blob);
                else if (this.nostrLoginMethod === 'nip46' && typeof _nip46Decrypt === 'function') json = await _nip46Decrypt(this.pubkey, blob);
            } catch (_) { json = null; }
            const parsed = json ? N().scheduleNoteParse(json) : null;
            this._slNoteCache.set(blob, parsed);
            return parsed;
        },

        _slRelays(kind, geohash) {
            const list = [];
            if (kind === 20000 && geohash && typeof this.getClosestRelaysForGeohash === 'function') {
                for (const r of this.getClosestRelaysForGeohash(geohash)) list.push(r.url);
            }
            for (const r of (this.defaultRelays || [])) list.push(r);
            return N().scheduleRelays(list);
        },

        _slWrap(rumor, recipient, kem, pq2, expiration, extraTags, at) {
            const C = window.NymCrypto;
            const tags = Array.isArray(extraTags) && extraTags.length ? extraTags : null;
            if (kem) return pq2 ? C.pq2Nip59Wrap(rumor, this.privkey, recipient, kem, expiration, tags, at) : C.pqNip59Wrap(rumor, this.privkey, recipient, kem, expiration, tags, at);
            return C.nip59Wrap(rumor, this.privkey, recipient, expiration, tags, at);
        },

        async _slBuild(key, text, at, opts) {
            const o = opts || {};
            const atMs = at * 1000;
            if (key.startsWith('pm-')) {
                const peer = this._ctPeerFromKey(key);
                if (typeof this.ensurePqAnnouncement === 'function') { try { await this.ensurePqAnnouncement(peer); } catch (_) { } }
                const plan = this.pqPmPlan(peer);
                const nid = this._generateSharedEventId();
                const tags = [['p', peer], ['x', nid], ['ms', String(atMs)]];
                if (o.threadRoot) tags.push(['nymthread', o.threadRoot]);
                tags.push(...this.customEmojiTagsForContent(text));
                if (typeof this.imetaTagsForContent === 'function') tags.push(...this.imetaTagsForContent(text));
                const rumor = { kind: 14, created_at: at, tags, content: text, pubkey: this.pubkey };
                const support = typeof this.pmSupportTokenFor === 'function' ? this.pmSupportTokenFor(peer) : null;
                if (support) rumor.tags.push(['nymbot-support', support]);
                const wrapTags = support ? [['t', support]] : null;
                const ttl = this.settings && this.settings.dmForwardSecrecyEnabled && this.settings.dmTTLSeconds > 0 ? this.settings.dmTTLSeconds : 0;
                const exp = ttl ? at + ttl : null;
                const events = [];
                if (plan.bitchat) {
                    for (const chunk of this.chunkBitchatContent(text)) {
                        const enc = this.encodeBitchatMessage(chunk, peer);
                        events.push({ e: window.NymCrypto.bitchatWrap({ kind: 14, created_at: at, tags: [], content: enc.content, pubkey: this.pubkey }, this.privkey, peer, at), r: 'pub' });
                    }
                }
                if (plan.nym) events.push({ e: this._slWrap(rumor, peer, plan.kemPk, plan.pq2, exp, wrapTags, at), r: 'dep' });
                const selfKem = typeof this.pqSelfKeyFor === 'function' ? this.pqSelfKeyFor() : null;
                events.push({ e: this._slWrap(rumor, this.pubkey, selfKem, selfKem && this.pqSelfUsesPq2(), exp, wrapTags, at), r: 'self' });
                return { events, relays: this._slRelays(1059), nid };
            }
            if (key.startsWith('group-')) {
                const gid = key.slice(6);
                const group = this.groupConversations && this.groupConversations.get(gid);
                if (!group) throw new Error('group');
                const nid = this._generateSharedEventId();
                const tags = [['g', gid], ...N().groupSubjectTags(group.name), ['x', nid], ['ms', String(atMs)]];
                tags.push(...this.customEmojiTagsForContent(text));
                if (typeof this.imetaTagsForContent === 'function') tags.push(...this.imetaTagsForContent(text));
                if (o.threadRoot) tags.push(['nymthread', o.threadRoot]);
                const rumor = { kind: 14, created_at: at, tags, content: text, pubkey: this.pubkey };
                const ttl = this.settings && this.settings.dmForwardSecrecyEnabled && this.settings.dmTTLSeconds > 0 ? this.settings.dmTTLSeconds : 0;
                const exp = ttl ? at + ttl : null;
                const events = [];
                const members = [...new Set((group.members || []).concat([this.pubkey]))];
                for (const pk of members) {
                    const kem = pk === this.pubkey ? (typeof this.pqSelfKeyFor === 'function' ? this.pqSelfKeyFor() : null) : (typeof this._pqWrapKeyFor === 'function' ? this._pqWrapKeyFor(pk) : null);
                    const pq2 = kem ? (pk === this.pubkey ? this.pqSelfUsesPq2() : this._pqWrapUsesPq2(pk)) : false;
                    events.push({ e: this._slWrap(rumor, pk, kem, pq2, exp, null, at), r: pk === this.pubkey ? 'self' : 'dep' });
                }
                return { events, relays: this._slRelays(1059), nid };
            }
            const name = key.replace(/^#/, '');
            const geohash = this.channels && this.channels.get(name) && this.channels.get(name).geohash ? this.channels.get(name).geohash : name;
            const channel = this.channels && this.channels.get(name) ? this.channels.get(name).channel : name;
            const ev = await this.publishMessage(text, channel, geohash, o.quote || null, o.threadRoot || null, { buildOnly: true, createdAt: at });
            if (!ev || !ev.sig) throw new Error('sign');
            return { events: [{ e: ev, r: 'pub' }], relays: this._slRelays(ev.kind, ev.kind === 20000 ? geohash : null), nid: ev.id };
        },

        async _slApi(action, extra) {
            const size = JSON.stringify(extra || {}).length;
            if (action !== 'schedule-add' || size < HTTP_ADD_BYTES) return this._storageApiRequest(action, extra);
            const apiHost = this._getApiHost();
            const body = Object.assign({ action }, extra || {});
            body.pubkey = this.pubkey;
            body.auth = await this._signBotAuth(action, 'storage', await this._authPayloadHash(body));
            const resp = await this._edgeFetch(`https://${apiHost}/api/storage`, {
                method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
            });
            const data = await resp.json().catch(() => ({}));
            if (!resp.ok || (data && data.error)) {
                const err = new Error((data && data.error) || `Request failed (${resp.status})`);
                err.code = data && data.code;
                throw err;
            }
            return data;
        },

        async scheduleMessage(text, at, opts) {
            const o = opts || {};
            const key = o.key || this._slChatKeyForView();
            const content = String(text || '').trim();
            if (!content) return { ok: false };
            const block = this.sendLaterBlockReason(key);
            if (block) { this._cnNotice(block); return { ok: false, reason: block }; }
            if (content.startsWith('/')) {
                const msg = this._cn("Commands can't be scheduled.");
                this._cnNotice(msg);
                return { ok: false, reason: msg };
            }
            const check = N().scheduleCheck(at, nowSec());
            if (check) { const msg = N().scheduleErrorText(check, (s) => this._cn(s)); this._cnNotice(msg); return { ok: false, reason: msg }; }
            if (key.startsWith('group-') && typeof this._gtGroupSendBlocked === 'function') {
                const blocked = this._gtGroupSendBlocked(content, key.slice(6));
                if (blocked) { this._cnNotice(blocked); return { ok: false, reason: blocked }; }
            }
            let built;
            try {
                built = await this._slBuild(key, content, at, o);
            } catch (_) {
                const msg = this._cn("Couldn't prepare the message to schedule.");
                this._cnNotice(msg);
                return { ok: false, reason: msg };
            }
            const chat = N().scheduleChatOf(this._slCanon(key));
            let note;
            try { note = await this._slEncryptNote(N().scheduleNoteJson(content, chat)); } catch (_) {
                const msg = this._cn(N().STRINGS.signerBlocked);
                this._cnNotice(msg);
                return { ok: false, reason: msg };
            }
            const size = N().scheduleSizeError(built.events, note.length);
            if (size) { const msg = this._cn(N().STRINGS.tooBig); this._cnNotice(msg); return { ok: false, reason: msg }; }
            const id = N().scheduleId(crypto.getRandomValues(new Uint8Array(16)));
            const body = { id, at, events: built.events, relays: built.relays, note };
            if (o.replaces) body.replaces = o.replaces;
            try {
                await this._slApi('schedule-add', body);
            } catch (err) {
                const code = err && err.code;
                const msg = code ? N().scheduleErrorText(code, (s) => this._cn(s)) : '';
                const text2 = msg || this._cn("Couldn't schedule it: {error}", { error: (err && err.message) || 'error' });
                this._cnNotice(text2);
                return { ok: false, reason: text2 };
            }
            const items = this._slItemsCache().filter((x) => x.id !== o.replaces);
            items.push({ id, at, chat, status: 'pending', attempts: 0, error: '', sentAt: 0, note, text: content });
            this._slSetItems(N().scheduleNormalize(items).map((x) => Object.assign(x, { text: (items.find((y) => y.id === x.id) || {}).text })));
            this._cnNotice(this._cn('Scheduled for {time}. Held by Nymchat until it sends.', { time: this._slFormatTime(at) }));
            this._slScheduleRefresh();
            return { ok: true, id };
        },

        async refreshScheduled() {
            if (!this.pubkey || typeof this._getApiHost !== 'function' || !this._getApiHost()) return this._slItemsCache();
            let data;
            try { data = await this._slApi('schedule-list', {}); } catch (_) { return this._slItemsCache(); }
            const prev = new Map(this._slItemsCache().map((x) => [x.id, x]));
            const out = [];
            for (const it of N().scheduleNormalize((data && data.items) || [])) {
                const old = prev.get(it.id);
                let text = old && old.text;
                let chat = old && old.chat && old.chat.t ? old.chat : null;
                if (!text || !chat) {
                    const parsed = await this._slDecryptNote(it.note);
                    if (parsed) { text = parsed.text; chat = parsed.chat; }
                }
                if (!chat) continue;
                out.push(Object.assign(it, { chat, text: text || '' }));
            }
            this._slSetItems(out);
            this._slScheduleRefresh();
            return out;
        },

        _slScheduleRefresh() {
            if (this._slRefreshTimer) clearTimeout(this._slRefreshTimer);
            const now = nowSec();
            const open = this._slItemsCache().filter((x) => x.status === 'pending' || x.status === 'sending');
            if (!open.length) return;
            const next = Math.min(...open.map((x) => x.at));
            const wait = Math.max(5000, Math.min(SCHEDULE_REFRESH_MS * 2, (next - now) * 1000 + 15000));
            this._slRefreshTimer = setTimeout(() => { this._slRefreshTimer = null; this.refreshScheduled(); }, wait);
        },

        async cancelScheduled(id) {
            try {
                const r = await this._slApi('schedule-cancel', { id });
                if (r && (r.removed || r.status === 'gone')) {
                    this._slSetItems(this._slItemsCache().filter((x) => x.id !== id));
                    return true;
                }
            } catch (err) {
                this._cnNotice(this._cn("Couldn't cancel it: {error}", { error: (err && err.message) || 'error' }));
                this.refreshScheduled();
                return false;
            }
            return false;
        },

        async sendScheduledNow(id) {
            const it = this._slItemsCache().find((x) => x.id === id);
            if (!it) return false;
            const key = N().scheduleChatKey(it.chat);
            if (!this.connected) {
                this._cnNotice(this._cn("You're offline. Try again when you're back online."));
                return false;
            }
            if (!(await this.cancelScheduled(id))) return false;
            const text = it.text || '';
            if (!text) return false;
            if (key.startsWith('pm-')) return !!(await this.sendPM(text, this._ctPeerFromKey(key)));
            if (key.startsWith('group-')) return !!(await this.sendGroupMessage(text, key.slice(6)));
            const name = key.replace(/^#/, '');
            const reg = this.channels && this.channels.get(name);
            return !!(await this.publishMessage(text, reg ? reg.channel : name, reg && reg.geohash ? reg.geohash : name));
        },

        async rescheduleItem(id, at) {
            const it = this._slItemsCache().find((x) => x.id === id);
            if (!it || !it.text) return { ok: false };
            return this.scheduleMessage(it.text, at, { key: N().scheduleChatKey(it.chat), replaces: id });
        },

        openSendLater(opts) {
            const o = opts || {};
            const key = o.key || this._slChatKeyForView();
            const input = document.getElementById('messageInput');
            let draft = o.text;
            let quote = null;
            if (draft == null) {
                if (typeof this.composerHasPendingUploads === 'function' && this.composerHasPendingUploads()) {
                    this._cnNotice(this._cn('Still uploading — send again once the attachments finish.'));
                    return;
                }
                draft = input ? String(input.value || '').trim() : '';
                const urls = typeof this.composerAttachmentUrls === 'function' ? this.composerAttachmentUrls() : [];
                if (urls.length) draft = (draft ? draft + ' ' : '') + urls.join(' ');
                if (this.pendingQuote) {
                    quote = { author: this.pendingQuote.author, text: this.pendingQuote.text, fullText: this.pendingQuote.fullText };
                    const lines = String(this.pendingQuote.text || '').split('\n');
                    const quoteLine = `> @${this.pendingQuote.author}: ${lines[0]}` + (lines.length > 1 ? '\n' + lines.slice(1).map((l) => `> ${l}`).join('\n') : '');
                    draft = draft ? `${quoteLine}\n\n${draft}` : quoteLine;
                }
            }
            const { body } = this._ctModal('sendLaterModal', this._cn(N().STRINGS.sendLater));
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            const block = this.sendLaterBlockReason(key);
            this._slPicker = { key, draft: String(draft || ''), replaces: o.replaces || null, quote };
            const presets = N().schedulePresets(Date.now(), this._slOffsetMin());
            const defAt = o.at || presets[0].at;
            const preview = String(draft || '').trim();
            body.innerHTML = `<div class="sl-sheet">
                ${preview ? `<div class="sl-preview">${esc(preview.length > 280 ? preview.slice(0, 280) + '…' : preview)}</div>` : `<div class="sl-preview sl-empty">${esc(this._cn('Write a message first.'))}</div>`}
                ${block ? `<div class="sl-block" role="alert">${esc(block)}</div>` : ''}
                <div class="sl-presets">${presets.map((p) => `<button type="button" class="ct-btn sl-preset" data-action="slPreset" data-at="${p.at}" ${block || !preview ? 'disabled' : ''}>${esc(this._slPresetLabel(p.id, p.at))}</button>`).join('')}</div>
                <label class="sl-custom"><span>${esc(this._cn('Pick a date and time'))}</span><input type="datetime-local" id="slWhen" value="${esc(N().scheduleInputValue(defAt, this._slOffsetMin()))}" ${block || !preview ? 'disabled' : ''}></label>
                <div class="sl-error nm-hidden" id="slError" role="alert"></div>
                <div class="sl-actions"><button type="button" class="send-btn" data-action="slConfirm" ${block || !preview ? 'disabled' : ''}>${esc(this._cn('Schedule'))}</button></div>
                <div class="sl-held">${ICONS.clock}<span>${esc(this._cn(N().STRINGS.held))}</span></div>
                <div class="sl-held-detail">${esc(this._cn(N().STRINGS.heldDetail))}</div>
            </div>`;
        },

        async _slConfirm(at) {
            const p = this._slPicker;
            if (!p) return;
            const err = document.getElementById('slError');
            const when = at || N().scheduleParseInput((document.getElementById('slWhen') || {}).value, this._slOffsetMin());
            const check = N().scheduleCheck(when, nowSec());
            if (check) {
                if (err) { err.textContent = N().scheduleErrorText(check, (s) => this._cn(s)); err.classList.remove('nm-hidden'); }
                return;
            }
            const threadRoot = !p.replaces && typeof this._threadRootForSend === 'function' ? this._threadRootForSend() : null;
            const res = p.replaces ? await this.rescheduleItem(p.replaces, when) : await this.scheduleMessage(p.draft, when, { key: p.key, quote: p.quote, threadRoot });
            if (res && res.ok) {
                this._ctCloseModal('sendLaterModal');
                if (!p.replaces) {
                    this._slClearComposer();
                    if (p.quote && typeof this.clearQuoteReply === 'function') this.clearQuoteReply();
                }
            } else if (err && res && res.reason) {
                err.textContent = res.reason;
                err.classList.remove('nm-hidden');
            }
        },

        _slClearComposer() {
            const input = document.getElementById('messageInput');
            if (!input) return;
            if ('value' in input) input.value = '';
            else input.textContent = '';
            if (typeof this.clearComposerAttachments === 'function') this.clearComposerAttachments();
            if (typeof this.autoResizeTextarea === 'function') this.autoResizeTextarea(input);
        },

        openScheduledList(key) {
            this._slListKey = key || this._slChatKeyForView();
            this._ctModal('scheduledListModal', this._cn(N().STRINGS.scheduled));
            this._slRenderList();
            this.refreshScheduled();
        },

        _slErrorText(it) {
            const map = { spam: "The spam filter held it back.", relays: "No relay accepted it.", late: 'It was too late to send.', partial: 'Some copies may not have arrived.', retry: 'Retrying.' };
            return it.error && map[it.error] ? this._cn(map[it.error]) : '';
        },

        _slRenderList() {
            const modal = typeof document !== 'undefined' ? document.getElementById('scheduledListModal') : null;
            if (!modal || !modal.classList.contains('active')) return;
            const body = modal.querySelector('.ct-modal-body');
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            const items = N().scheduleForChat(this._slItemsCache(), this._slCanon(this._slListKey)).map((x) => Object.assign(x, { text: (this._slItemsCache().find((y) => y.id === x.id) || {}).text || '' }));
            const rows = items.map((it) => {
                const open = it.status === 'pending' || it.status === 'failed';
                return `<div class="sl-item sl-${esc(it.status)}" data-sl-id="${esc(it.id)}">
                    <div class="sl-item-head"><span class="sl-clock">${ICONS.clock}</span><span class="sl-time">${esc(this._slFormatTime(it.at))}</span><span class="sl-status">${esc(N().scheduleStatusText(it.status, (s) => this._cn(s)))}</span></div>
                    <div class="sl-text message-content">${typeof this.formatMessageWithQuotes === 'function' ? this.formatMessageWithQuotes(it.text, 0) : esc(it.text)}</div>
                    ${this._slErrorText(it) ? `<div class="sl-item-error">${esc(this._slErrorText(it))}</div>` : ''}
                    ${open ? `<div class="sl-item-actions">
                        <button type="button" class="ct-btn" data-action="slEdit" data-sl-id="${esc(it.id)}">${esc(this._cn(N().STRINGS.editTime))}</button>
                        <button type="button" class="ct-btn" data-action="slSendNow" data-sl-id="${esc(it.id)}">${esc(this._cn(N().STRINGS.sendNow))}</button>
                        <button type="button" class="ct-btn danger" data-action="slCancel" data-sl-id="${esc(it.id)}">${esc(this._cn(N().STRINGS.cancel))}</button>
                    </div>` : ''}
                </div>`;
            }).join('');
            body.innerHTML = `${rows || `<div class="ct-empty">${esc(this._cn('Nothing scheduled in this chat.'))}</div>`}
                <div class="sl-held">${ICONS.clock}<span>${esc(this._cn(N().STRINGS.held))}</span></div>`;
        },

        _slRenderBar() {
            if (typeof document === 'undefined') return;
            const key = this._slChatKeyForView();
            const n = key ? N().scheduleOpenCount(this._slItemsCache(), this._slCanon(key)) : 0;
            let bar = document.getElementById('slBar');
            if (!bar) {
                const wrap = document.querySelector('.input-container .input-wrapper');
                if (!wrap) return;
                bar = document.createElement('button');
                bar.type = 'button';
                bar.id = 'slBar';
                bar.className = 'sl-bar nm-hidden';
                bar.dataset.action = 'slOpenList';
                wrap.insertBefore(bar, wrap.firstChild);
            }
            bar.classList.toggle('nm-hidden', n <= 0);
            if (n > 0) bar.innerHTML = `${ICONS.clock}<span>${this.escapeHtml(this._cn(n === 1 ? '1 scheduled message' : '{n} scheduled messages', { n }))}</span>`;
        },

        _slSendMenu(x, y) {
            if (typeof this.openComposerSendMenu === 'function') { this.openComposerSendMenu(); return; }
            const items = [{ label: this._cn(N().STRINGS.sendLater), svg: ICONS.clock, action: () => this.openSendLater() }];
            if (typeof this._composerCanSendAnon === 'function' && this._composerCanSendAnon()) {
                items.push({ label: this._cn('Send anonymously'), svg: ICONS.anon, action: () => this.sendMessagePseudonymous() });
            }
            if (typeof this._showSidebarActionMenu === 'function') this._showSidebarActionMenu(items, x, y);
        },

        _slBindSend() {
            if (typeof document === 'undefined' || this._slSendBound) return;
            const btn = document.getElementById('sendBtn');
            if (!btn) return;
            this._slSendBound = true;
            let timer = null;
            let fired = false;
            const open = (x, y) => {
                fired = true;
                window._slSuppressSendUntil = Date.now() + 800;
                try { btn.dispatchEvent(new Event('mouseleave')); } catch (_) { }
                if (window.nymHaptic) window.nymHaptic('selection');
                this._slSendMenu(x, y);
            };
            const start = (e) => {
                if (e.type === 'mousedown' && e.button !== 0) return;
                fired = false;
                const pt = e.touches && e.touches[0] ? e.touches[0] : e;
                const x = pt.clientX, y = pt.clientY;
                clearTimeout(timer);
                timer = setTimeout(() => { timer = null; open(x, y - 60); }, 500);
            };
            const stop = (e) => {
                if (timer) { clearTimeout(timer); timer = null; }
                if (fired && e && e.cancelable) { e.preventDefault(); e.stopPropagation(); }
            };
            btn.addEventListener('mousedown', start, true);
            btn.addEventListener('touchstart', start, { capture: true, passive: true });
            btn.addEventListener('mouseup', stop, true);
            btn.addEventListener('mouseleave', stop, true);
            btn.addEventListener('touchend', stop, true);
            btn.addEventListener('touchcancel', stop, true);
            btn.addEventListener('click', (e) => {
                if (fired || Date.now() < (window._slSuppressSendUntil || 0)) {
                    e.preventDefault();
                    e.stopImmediatePropagation();
                    fired = false;
                }
            }, true);
            btn.addEventListener('contextmenu', (e) => {
                e.preventDefault();
                e.stopImmediatePropagation();
                if (timer) { clearTimeout(timer); timer = null; }
                this._slSendMenu(e.clientX, e.clientY - 60);
            }, true);
        },

        _cnStart() {
            if (this._cnStarted) return;
            this._cnStarted = true;
            this._slBindSend();
            this._pinBindTouch();
            this._cnRenderAllMentionBadges();
            this._pinAfterLegacyChange();
            setInterval(() => { try { if (this._pinPending()) this._pinSync(); } catch (_) { } }, 10000);
            if (typeof document !== 'undefined' && document.addEventListener) {
                document.addEventListener('visibilitychange', () => {
                    if (document.hidden) return;
                    for (const k of this._cnOpenKeys()) this._cnUpdateFabs(k);
                });
            }
            if (typeof window !== 'undefined' && window.addEventListener) {
                window.addEventListener('online', () => setTimeout(() => { this._pinSync(); this.refreshScheduled(); }, 1500));
            }
            setTimeout(() => { this.refreshScheduled(); }, 4000);
        },
    });

    const wrap = (name, after, before) => {
        const orig = NYM.prototype[name];
        if (typeof orig !== 'function') return;
        NYM.prototype[name] = function () {
            let pre;
            try { pre = before ? before.apply(this, arguments) : undefined; } catch (_) { }
            const r = orig.apply(this, arguments);
            try { if (after) after.call(this, arguments, r, pre); } catch (_) { }
            return r;
        };
    };

    const singleSwitch = function (nextKey) {
        if (this._cvActive || !nextKey) return null;
        const prev = this._cnSingleKey();
        if (prev === nextKey) return null;
        if (prev) this._cnRelease(prev);
        this._cnCapture(nextKey);
        return nextKey;
    };

    wrap('switchChannel', function (args, r, key) { if (key) this._cnAfterRender(key); this._slRenderBar(); },
        function (channel, geohash) { return singleSwitch.call(this, geohash ? `#${geohash}` : channel); });
    wrap('openPM', function (args, r, key) { if (key) this._cnAfterRender(key); this._slRenderBar(); },
        function (nym, pubkey) { return pubkey && pubkey !== this.pubkey ? singleSwitch.call(this, this.getPMConversationKey(pubkey)) : null; });
    wrap('openGroup', function (args, r, key) { if (key) this._cnAfterRender(key); this._slRenderBar(); },
        function (groupId) { return this.groupConversations && this.groupConversations.has(groupId) ? singleSwitch.call(this, this.getGroupConversationKey(groupId)) : null; });
    wrap('renderMessagesWithVirtualScroll', function (args) {
        const container = args[0];
        const key = args[1];
        if (!container || !key) return;
        if (this._cvActive || container.id === 'messagesContainer') this._cnAfterRender(key);
    });
    wrap('_tryRestoreCachedDOM', function (args, r) { if (r) this._cnAfterRender(args[2]); });
    wrap('cacheCurrentContainerDOM', null, function () {
        const c = document.getElementById('messagesContainer');
        if (c) c.querySelectorAll('.cn-divider').forEach((d) => d.remove());
    });
    wrap('displayMessage', function (args) { this._cnOnDisplayed(args[0]); });
    wrap('hideMessagesFromBlockedUser', function () { for (const k of this._cnOpenKeys()) this._cnSchedule(k); });
    wrap('handleDeletionEvent', function () { for (const k of this._cnOpenKeys()) this._cnSchedule(k); });
    wrap('updateUnreadCount', function (args) { this._cnScanClosed(args[0]); });
    wrap('refreshUnreadCount', function (args) { this._cnScanClosed(args[0]); });
    wrap('_renderUnreadBadge', function (args) { this._cnRenderMentionBadge(args[0]); });
    wrap('_cvRenderColumn', function (args) {
        const col = args[0];
        if (col && col.key) this._cnAfterRender(col.key);
    }, function (col) {
        if (col && col.key) this._cnCapture(col.key);
    });
    wrap('_cvNavigateColumn', null, function (col) { if (col && col.key) this._cnRelease(col.key); });
    wrap('cvRemoveColumn', null, function (id) {
        const col = this._cvColumns && this._cvColumns.find((c) => c.id === id);
        if (col && col.key) this._cnRelease(col.key);
    });
    wrap('_cvFocusColumn', function () { this._slRenderBar(); });
    wrap('insertPMInOrder', function () { this._pinOrderPmList(); });
    wrap('updateChannelPins', function () { this._pinMarkChannelRows(); });
    wrap('loadPinnedChannels', function () { this._pinAfterLegacyChange(); });

    const origToggle = NYM.prototype.togglePin;
    NYM.prototype.togglePin = function (channel, geohash) {
        const key = N().pinKey('channel', geohash || channel);
        if (!key) return origToggle ? origToggle.apply(this, arguments) : undefined;
        this.togglePinChat(key);
        if (typeof this._refreshFavoriteChannelBtn === 'function') this._refreshFavoriteChannelBtn();
    };

    const origMenu = NYM.prototype._buildSidebarMenuItems;
    if (typeof origMenu === 'function') {
        NYM.prototype._buildSidebarMenuItems = function (itemEl) {
            if (window.NymChatNav.pinGestureLocks(this._pinG)) return [];
            const base = origMenu.apply(this, arguments) || [];
            let pins = [];
            try { pins = this._pinMenuItems(itemEl); } catch (_) { pins = []; }
            const isChannel = itemEl && itemEl.classList && itemEl.classList.contains('channel-item');
            const rest = isChannel && pins.length ? base.slice(1) : base;
            return pins.concat(rest);
        };
    }

    if (typeof window !== 'undefined' && window.NYM_ACTIONS) {
        const nym = () => window.nym;
        Object.assign(window.NYM_ACTIONS, {
            cnJumpFirstUnread: function (_e, t) {
                const host = t.closest('.cn-fabs');
                nym().jumpToFirstUnread(host && host.dataset.cnKey);
            },
            cnJumpMention: function (_e, t) {
                const host = t.closest('.cn-fabs');
                nym().jumpToNextMention(host && host.dataset.cnKey);
            },
            slPreset: function (_e, t) { nym()._slConfirm(parseInt(t.dataset.at, 10)); },
            slConfirm: function () { nym()._slConfirm(); },
            slOpenList: function () { nym().openScheduledList(); },
            slCancel: function (_e, t) { nym().cancelScheduled(t.dataset.slId); },
            slSendNow: function (_e, t) { nym().sendScheduledNow(t.dataset.slId); },
            slEdit: function (_e, t) {
                const n = nym();
                const it = n._slItemsCache().find((x) => x.id === t.dataset.slId);
                if (!it) return;
                n._ctCloseModal('scheduledListModal');
                n.openSendLater({ key: window.NymChatNav.scheduleChatKey(it.chat), text: it.text, replaces: it.id, at: it.at });
            },
        });
        let tries = 0;
        const boot = () => {
            const n = window.nym;
            if (n && n.pubkey && typeof n._cnStart === 'function') n._cnStart();
            else if (++tries < 120) setTimeout(boot, 1000);
        };
        setTimeout(boot, 1200);
    }
})();
