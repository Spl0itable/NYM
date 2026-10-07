(function () {
    const L = () => window.NymDayLabels;

    const ROW_SEL = ':scope > .message[data-message-id], :scope > .message-group > .message-group-stack > .message[data-message-id]';

    Object.assign(NYM.prototype, {
        _dsNow() {
            return Math.floor(Date.now() / 1000);
        },

        _dsLocale() {
            const lang = typeof this.getUiLanguage === 'function' ? this.getUiLanguage() : '';
            if (lang) return lang;
            return (typeof navigator !== 'undefined' && navigator.language) || 'en';
        },

        _dsText(s) {
            return typeof this.uiText === 'function' ? this.uiText(s) : s;
        },

        _dsRowAt(row) {
            return Math.floor(Number(row && row.dataset && row.dataset.createdAt) || 0);
        },

        _dsKeyOf(row, now) {
            const at = this._dsRowAt(row);
            return at > 0 ? L().dayKey(at, now) : '';
        },

        _dsRows(list) {
            const shown = list.offsetParent !== null || list.getClientRects().length > 0;
            return Array.from(list.querySelectorAll(ROW_SEL)).filter((r) => {
                if (r.hidden || r.style.display === 'none' || r.classList.contains('nm-hidden') || r.classList.contains('blocked') || r.classList.contains('blocked-user-message')) return false;
                return !shown || r.getClientRects().length > 0;
            });
        },

        _dsLists() {
            if (!this._dsBound) this._dsBound = [];
            this._dsBound = this._dsBound.filter((b) => b.list.isConnected);
            return this._dsBound;
        },

        _dsBind(sc, list) {
            if (!L() || !sc || !list || list._dsBound) return;
            const bound = { sc, list, scrolling: false, lastScroll: 0, timer: null, idle: null, raf: 0 };
            list._dsBound = bound;
            this._dsLists().push(bound);
            if (typeof MutationObserver !== 'undefined') {
                const relevant = (nodes) => {
                    for (const n of nodes) {
                        if (n.nodeType !== 1) continue;
                        if (n.classList.contains('message') || n.classList.contains('message-group') || n.classList.contains('cn-divider')) return true;
                    }
                    return false;
                };
                const HIDERS = /(^|\s)(nm-hidden|blocked|blocked-user-message|blocked-user-group)(\s|$)/;
                const toggled = (r) => {
                    const t = r.target;
                    if (!t || t.nodeType !== 1 || !(t.classList.contains('message') || t.classList.contains('message-group'))) return false;
                    if (r.attributeName !== 'class') return true;
                    return HIDERS.test(r.oldValue || '') !== HIDERS.test(t.className || '');
                };
                new MutationObserver((records) => {
                    for (const r of records) {
                        if (r.type === 'childList' ? (relevant(r.addedNodes) || relevant(r.removedNodes)) : toggled(r)) {
                            this._dsSchedule(bound);
                            return;
                        }
                    }
                }).observe(list, { childList: true, subtree: true, attributes: true, attributeOldValue: true, attributeFilter: ['class', 'style', 'hidden'] });
            }
            sc.addEventListener('scroll', () => {
                bound.scrolling = true;
                bound.lastScroll = Date.now();
                clearTimeout(bound.idle);
                bound.idle = setTimeout(() => {
                    bound.scrolling = false;
                    this._dsFloatUpdate(bound);
                }, 150);
                this._dsFloatSchedule(bound);
            }, { passive: true });
            this._dsArmMidnight();
            this._dsSync(list);
        },

        _dsSchedule(bound) {
            if (bound.pending) return;
            bound.pending = true;
            requestAnimationFrame(() => {
                bound.pending = false;
                if (bound.list.isConnected) this._dsSync(bound.list);
            });
        },

        _dsSlot(row) {
            const stack = row.parentElement;
            if (stack && stack.classList.contains('message-group-stack')) {
                const wrapper = stack.parentElement;
                if (stack.firstElementChild === row && wrapper) return wrapper;
                return row;
            }
            return row;
        },

        _dsBefore(slot) {
            let at = slot;
            while (at.previousElementSibling && at.previousElementSibling.classList.contains('cn-divider')) at = at.previousElementSibling;
            return at;
        },

        _dsMake(key, label) {
            const el = document.createElement('div');
            el.className = 'day-separator';
            el.setAttribute('role', 'separator');
            el.dataset.day = key;
            this._dsLabel(el, label);
            return el;
        },

        _dsLabel(el, label) {
            if (el.dataset.label === label) return;
            el.dataset.label = label;
            el.setAttribute('aria-label', label);
            let span = el.firstElementChild;
            if (!span) {
                span = document.createElement('span');
                el.appendChild(span);
            }
            span.textContent = label;
        },

        _dsSync(list) {
            if (!L() || !list) return;
            const now = this._dsNow();
            const locale = this._dsLocale();
            const t = (s) => this._dsText(s);
            const keep = new Set();
            let regroup = false;
            let prev = null;
            const rows = this._dsRows(list);
            const bound = list._dsBound;
            if (bound) bound.rows = rows;
            const anchor = bound && bound.sc && Math.abs(bound.sc.scrollTop) >= 2 ? this._dsTopRow(bound) : null;
            const anchorTop = anchor ? anchor.getBoundingClientRect().top : 0;
            let changed = false;
            for (const row of rows) {
                const key = this._dsKeyOf(row, now);
                if (!key || key === prev) {
                    if (key) prev = key;
                    continue;
                }
                prev = key;
                const slot = this._dsSlot(row);
                if (slot === row && row.parentElement && row.parentElement.classList.contains('message-group-stack')) regroup = true;
                const before = this._dsBefore(slot);
                const label = L().label(this._dsRowAt(row), now, undefined, locale, t);
                const existing = before.previousElementSibling;
                if (existing && existing.classList.contains('day-separator') && existing.dataset.day === key && !keep.has(existing)) {
                    this._dsLabel(existing, label);
                    keep.add(existing);
                    continue;
                }
                const el = this._dsMake(key, label);
                before.parentNode.insertBefore(el, before);
                keep.add(el);
                changed = true;
            }
            for (const el of list.querySelectorAll('.day-separator')) {
                if (!keep.has(el)) {
                    el.remove();
                    changed = true;
                }
            }
            if (regroup && typeof this._recomputeAllBubbleGrouping === 'function') this._recomputeAllBubbleGrouping(list);
            if (changed && anchor && anchor.isConnected) {
                const delta = anchor.getBoundingClientRect().top - anchorTop;
                if (Math.abs(delta) >= 1) bound.sc.scrollTop += delta;
            }
            if (list._dsBound) this._dsFloatUpdate(list._dsBound);
        },

        _dsRelabelAll() {
            for (const b of this._dsLists()) this._dsSync(b.list);
        },

        _dsArmMidnight() {
            if (this._dsMidnight) return;
            const wait = Math.max(1000, L().nextMidnightMs(Date.now()) - Date.now() + 1000);
            this._dsMidnight = setTimeout(() => {
                this._dsMidnight = null;
                this._dsRelabelAll();
                this._dsArmMidnight();
            }, Math.min(wait, 6 * 3600 * 1000));
        },

        _dsFloatEl(bound) {
            let el = bound.float;
            if (el && el.isConnected) return el;
            const host = bound.sc.parentElement;
            if (!host) return null;
            el = document.createElement('div');
            el.className = 'day-float';
            el.setAttribute('aria-hidden', 'true');
            el.appendChild(document.createElement('span'));
            host.insertBefore(el, bound.sc.nextSibling);
            bound.float = el;
            return el;
        },

        _dsFloatSchedule(bound) {
            if (bound.raf) return;
            bound.raf = requestAnimationFrame(() => {
                bound.raf = 0;
                this._dsFloatUpdate(bound);
            });
        },

        _dsTopRow(bound) {
            const rows = (bound.rows && bound.rows.every((r, i) => i > 2 || r.isConnected)) ? bound.rows : this._dsRows(bound.list);
            if (!rows.length) return null;
            const viewTop = bound.sc.getBoundingClientRect().top;
            let lo = 0, hi = rows.length - 1, hit = -1;
            while (lo <= hi) {
                const mid = (lo + hi) >> 1;
                if (rows[mid].getBoundingClientRect().bottom > viewTop) { hit = mid; hi = mid - 1; } else lo = mid + 1;
            }
            return hit < 0 ? null : rows[hit];
        },

        _dsFloatUpdate(bound) {
            const { sc, list } = bound;
            if (!sc.isConnected || !list.isConnected) return;
            const row = this._dsTopRow(bound);
            const now = this._dsNow();
            const key = row ? this._dsKeyOf(row, now) : '';
            const viewTop = sc.getBoundingClientRect().top;
            const inline = key ? list.querySelector('.day-separator[data-day="' + key + '"]') : null;
            const idleMs = bound.lastScroll ? Date.now() - bound.lastScroll : Infinity;
            const mark = sc.querySelector('.cn-divider');
            const cover = mark ? mark.getBoundingClientRect() : null;
            const show = L().floatVisible({
                key,
                inlineKey: inline ? key : null,
                inlineTop: inline ? inline.getBoundingClientRect().top : null,
                viewTop,
                atBottom: Math.abs(sc.scrollTop) <= 48,
                scrolling: bound.scrolling,
                idleMs,
                coverTop: cover && cover.height > 0 ? cover.top : null,
                coverBottom: cover && cover.height > 0 ? cover.bottom : null,
            });
            if (!show && !bound.float) return;
            const el = this._dsFloatEl(bound);
            if (!el) return;
            if (show) {
                const label = L().label(this._dsRowAt(row), now, undefined, this._dsLocale(), (s) => this._dsText(s));
                const span = el.firstElementChild;
                if (span.textContent !== label) span.textContent = label;
                el.dataset.day = key;
                el.style.top = (sc.offsetTop + L().CONFIG.floatTopPx) + 'px';
                el.style.left = (sc.offsetLeft + sc.clientWidth / 2) + 'px';
            }
            el.classList.toggle('visible', show);
            clearTimeout(bound.timer);
            if (show && !bound.scrolling) {
                bound.timer = setTimeout(() => this._dsFloatUpdate(bound), Math.max(50, L().CONFIG.floatIdleMs - idleMs + 20));
            }
        },
    });
})();
