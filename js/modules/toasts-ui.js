(function () {
    const T = () => window.NymToasts;

    Object.assign(NYM.prototype, {
        showToast(content, opts = {}) {
            if (!T() || typeof document === 'undefined' || !document.body) return null;
            const raw = String(content == null ? '' : content);
            if (!raw.trim()) return null;
            if (!opts._released && typeof this._toastShouldHold === 'function' && this._toastShouldHold()) {
                if (!this._toastHeld) this._toastHeld = [];
                this._toastHeld.push({ content: raw, opts: Object.assign({}, opts), at: Date.now() });
                this._toastWatchHeld();
                return null;
            }
            const html = !!opts.html;
            const plain = html ? this._toastPlain(raw) : raw;
            const source = typeof this.uiSourceOf === 'function' ? this.uiSourceOf(plain) : plain;
            const kind = opts.kind || T().classify(source);
            const now = Date.now();
            const action = opts.action && typeof opts.onAction === 'function' ? String(opts.action) : null;
            const r = T().push(this._toastQueue || T().emptyQueue(), plain, kind, now, action);
            this._toastQueue = r.state;
            for (const id of r.evicted) this._toastDrop(id);
            if (!r.deduped) {
                if (action) {
                    if (!this._toastActions) this._toastActions = new Map();
                    this._toastActions.set(r.id, opts.onAction);
                }
                this._toastMount(r.id, raw, html);
            }
            this._toastArm();
            return r.id;
        },

        showUndoToast(text, onUndo, opts = {}) {
            const label = typeof this.uiText === 'function' ? this.uiText('Undo') : 'Undo';
            return this.showToast(text, Object.assign({ kind: 'info' }, opts, { action: label, onAction: onUndo }));
        },

        runToastAction(id) {
            const fn = this._toastActions && this._toastActions.get(id);
            if (this._toastActions) this._toastActions.delete(id);
            this.dismissToast(id);
            if (typeof fn === 'function') {
                try { fn(); } catch (_) { }
            }
        },

        _toastDrop(id) {
            if (this._toastActions) this._toastActions.delete(id);
            this._toastRemoveEl(id);
        },

        dismissToast(id) {
            if (!this._toastQueue) return;
            this._toastQueue = T().dismiss(this._toastQueue, id);
            this._toastDrop(id);
            this._toastArm();
        },

        _toastPlain(html) {
            const d = document.createElement('div');
            d.innerHTML = html;
            return d.textContent || '';
        },

        _toastHost() {
            if (typeof this._etStack === 'function') {
                try { this._etStack(); this._etPlace(); } catch (_) { }
            }
            let host = document.getElementById('nymToasts');
            if (!host) {
                host = document.createElement('div');
                host.id = 'nymToasts';
                host.className = 'nym-toasts';
                document.body.appendChild(host);
            }
            return host;
        },

        _toastMount(id, raw, html) {
            const t = this._toastQueue.toasts.find((x) => x.id === id);
            if (!t) return;
            const el = document.createElement('div');
            el.className = 'nym-toast nym-toast-' + t.kind;
            el.dataset.toastId = String(id);
            el.dataset.kind = t.kind;
            const assertive = t.kind === 'error';
            el.setAttribute('role', assertive ? 'alert' : 'status');
            el.setAttribute('aria-live', assertive ? 'assertive' : 'polite');
            el.setAttribute('aria-atomic', 'true');
            const body = document.createElement('div');
            body.className = 'nym-toast-text';
            const shown = typeof this.localizeCommandTokensIn === 'function' ? this.localizeCommandTokensIn(raw) : raw;
            if (html) body.innerHTML = shown;
            else body.textContent = shown;
            const close = document.createElement('button');
            close.type = 'button';
            close.className = 'nym-toast-close';
            const label = typeof this.uiText === 'function' ? this.uiText('Dismiss') : 'Dismiss';
            close.setAttribute('aria-label', label);
            close.title = label;
            close.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"></path></svg>';
            el.appendChild(body);
            if (t.action) {
                const act = document.createElement('button');
                act.type = 'button';
                act.className = 'nym-toast-action';
                act.textContent = t.action;
                act.addEventListener('click', (e) => {
                    e.stopPropagation();
                    this.runToastAction(id);
                });
                el.appendChild(act);
                el.classList.add('has-action');
            }
            el.appendChild(close);
            this._toastWire(el, id);
            this._toastHost().appendChild(el);
            requestAnimationFrame(() => el.classList.add('visible'));
        },

        _toastWire(el, id) {
            const pause = () => {
                if (!this._toastQueue) return;
                this._toastQueue = T().pause(this._toastQueue, id, Date.now());
                this._toastArm();
            };
            const resume = () => {
                if (!this._toastQueue || el.matches(':hover') || el.contains(document.activeElement)) return;
                this._toastQueue = T().resume(this._toastQueue, id, Date.now());
                this._toastArm();
            };
            el.addEventListener('mouseenter', pause);
            el.addEventListener('mouseleave', () => setTimeout(resume, 0));
            el.addEventListener('focusin', pause);
            el.addEventListener('focusout', () => setTimeout(resume, 0));
            let start = null;
            let dx = 0;
            el.addEventListener('pointerdown', (e) => {
                if (e.button !== undefined && e.button !== 0) return;
                start = { x: e.clientX, y: e.clientY, id: e.pointerId };
                dx = 0;
            });
            el.addEventListener('pointermove', (e) => {
                if (!start || e.pointerId !== start.id) return;
                dx = e.clientX - start.x;
                if (Math.abs(dx) > 6 && Math.abs(dx) > Math.abs(e.clientY - start.y)) {
                    el.classList.add('dragging');
                    el.style.transform = 'translateX(' + dx + 'px)';
                    el.style.opacity = String(Math.max(0.2, 1 - Math.abs(dx) / 200));
                }
            });
            const end = (e) => {
                if (!start || (e && e.pointerId !== start.id)) return;
                start = null;
                const swiped = Math.abs(dx) >= T().CONFIG.swipeDismissPx;
                el.classList.remove('dragging');
                if (swiped) {
                    el.dataset.swiped = '1';
                    this.dismissToast(id);
                    return;
                }
                el.style.transform = '';
                el.style.opacity = '';
            };
            el.addEventListener('pointerup', end);
            el.addEventListener('pointercancel', end);
            el.addEventListener('click', (e) => {
                if (el.dataset.swiped) return;
                if (Math.abs(dx) > 6) { dx = 0; return; }
                if (e.target.closest('.nym-toast-action')) return;
                if (e.target.closest('a, [data-action]:not(.nym-toast-close)') && !e.target.closest('.nym-toast-close')) return;
                this.dismissToast(id);
            });
        },

        _toastRemoveEl(id) {
            const el = document.querySelector('#nymToasts .nym-toast[data-toast-id="' + id + '"]');
            if (!el) return;
            el.classList.remove('visible');
            el.classList.add('leaving');
            el.setAttribute('aria-hidden', 'true');
            const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
            if (reduce) { el.remove(); return; }
            setTimeout(() => el.remove(), 200);
        },

        _toastArm() {
            clearTimeout(this._toastTimer);
            this._toastTimer = null;
            if (!this._toastQueue) return;
            const next = T().nextExpiry(this._toastQueue);
            if (next === null) return;
            this._toastTimer = setTimeout(() => {
                this._toastTimer = null;
                const r = T().expire(this._toastQueue, Date.now());
                this._toastQueue = r.state;
                for (const id of r.expired) this._toastDrop(id);
                this._toastArm();
            }, Math.max(0, next - Date.now()) + 5);
        },
    });
})();
