(function () {
    const H = () => window.NymSearchHistory;

    function lsGet(k) { try { return localStorage.getItem(k); } catch (_) { return null; } }
    function lsSet(k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (_) { } }

    Object.assign(NYM.prototype, {
        _sh(key, vars) {
            let s = (H() && H().STRINGS[key]) || key;
            s = typeof this.uiText === 'function' ? this.uiText(s) : s;
            if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
            return s;
        },

        _shLocal() {
            return typeof this.savedMode === 'function' && this.savedMode() === 'local';
        },

        _shVaultOn() {
            return typeof this.vaultEnabled === 'function' && this.vaultEnabled();
        },

        _shMode() {
            const local = this._shLocal();
            if (this._shWasLocal !== undefined && this._shWasLocal !== local) {
                this._shGen = (this._shGen || 0) + 1;
                this._shSaveSeq = (this._shSaveSeq || 0) + 1;
                this._shMem = null;
                this._shCache = null;
            }
            this._shWasLocal = local;
            return local;
        },

        _shReady() {
            if (this._shMode()) return true;
            return !!(this.pubkey && this._shCache && this._shCache.pk === this.pubkey && this._shCache.loaded);
        },

        _shItems() {
            if (!H()) return [];
            if (this._shMode()) return this._shMem || (this._shMem = []);
            if (this._shCache && this._shCache.pk === this.pubkey) return this._shCache.items;
            return [];
        },

        _shFresh() {
            if (!H() || this._shMode() || this._shVaultOn() || !this.pubkey) return;
            let raw = null;
            try { raw = localStorage.getItem(H().KEYS.state + this.pubkey); } catch (_) { return; }
            if (raw && String(raw).startsWith('enc:v1:')) return;
            this._shGen = (this._shGen || 0) + 1;
            this._shCache = { pk: this.pubkey, items: H().decode(raw), loaded: true };
        },

        async _shLoad() {
            if (!H()) return false;
            if (this._shMode()) {
                if (!this._shMem) this._shMem = [];
                return true;
            }
            const pk = this.pubkey;
            if (!pk) return false;
            if (this._shReady()) return true;
            const gen = this._shGen || 0;
            let raw = null;
            try { raw = localStorage.getItem(H().KEYS.state + pk); } catch (_) { return false; }
            let migrate = false;
            if (raw && String(raw).startsWith('enc:v1:')) {
                if (!(this._shVaultOn() && this._vaultKey)) return false;
                try { raw = await this._vaultDecrypt(raw); } catch (_) { raw = null; }
            } else if (raw && this._shVaultOn()) {
                if (!this._vaultKey) return false;
                migrate = true;
            }
            if (this.pubkey !== pk || (this._shGen || 0) !== gen || this._shReady()) return this._shReady();
            const items = H().decode(raw);
            this._shCache = { pk, items, loaded: true };
            if (migrate) this._shPersist(items);
            this._shRefresh();
            return true;
        },

        _shPersist(items) {
            if (this._shMode()) { this._shMem = items; return; }
            const pk = this.pubkey;
            if (!pk) return;
            this._shCache = { pk, items, loaded: true };
            const name = H().KEYS.state + pk;
            const seq = (this._shSaveSeq = (this._shSaveSeq || 0) + 1);
            if (!items.length) { lsSet(name, null); return; }
            const json = H().encode(items);
            if (this._shVaultOn()) {
                if (!this._vaultKey || typeof this._vaultEncrypt !== 'function') return;
                this._vaultEncrypt(json).then((blob) => {
                    if (seq !== this._shSaveSeq || this.pubkey !== pk) return;
                    lsSet(name, blob);
                }).catch(() => { });
                return;
            }
            lsSet(name, json);
        },

        _shRefresh() {
            const m = document.getElementById('unifiedSearchModal');
            if (m && m.classList.contains('active') && this._usState && typeof this._usRender === 'function') this._usRender();
        },

        rememberSearches() {
            return !H() || lsGet(H().KEYS.setting) !== H().KEYS.off;
        },

        setRememberSearches(on) {
            if (!H()) return;
            lsSet(H().KEYS.setting, on ? null : H().KEYS.off);
            if (!on) this._shClear();
            const sel = document.getElementById('rememberSearchesToggle');
            if (sel) sel.checked = !!on;
            this._shRefresh();
        },

        _shRecord(raw) {
            if (!H() || !this.rememberSearches()) return false;
            this._shFresh();
            if (!this._shReady()) return false;
            const items = this._shItems();
            const next = H().add(items, raw, Date.now());
            if (next === items) return false;
            this._shPersist(next);
            return true;
        },

        _shRemove(q) {
            if (!H()) return false;
            this._shFresh();
            if (!this._shReady()) return false;
            const items = this._shItems();
            const next = H().remove(items, q);
            if (next === items) return false;
            this._shPersist(next);
            return true;
        },

        _shClear() {
            if (!H()) return false;
            if (this._shMode()) { this._shMem = []; return true; }
            const pk = this.pubkey;
            if (!pk) return false;
            this._shSaveSeq = (this._shSaveSeq || 0) + 1;
            this._shCache = { pk, items: [], loaded: true };
            lsSet(H().KEYS.state + pk, null);
            return true;
        },

        _shExternal() {
            if (!H()) return;
            const K = H().KEYS;
            const pk = this.pubkey;
            const off = lsGet(K.setting) === K.off;
            this._shGen = (this._shGen || 0) + 1;
            if (off || !pk || lsGet(K.state + pk) === null) {
                this._shSaveSeq = (this._shSaveSeq || 0) + 1;
                this._shMem = [];
                this._shCache = pk ? { pk, items: [], loaded: true } : null;
            } else {
                this._shCache = null;
                this._shLoad();
            }
            const sel = document.getElementById('rememberSearchesToggle');
            if (sel) sel.checked = !off;
            this._shRefresh();
        },

        _shAnnounce(text) {
            const el = document.getElementById('usCount');
            if (el) el.textContent = text;
        },
    });

    if (typeof window !== 'undefined' && window.NYM_ACTIONS) {
        const nym = () => window.nym;
        Object.assign(window.NYM_ACTIONS, {
            onRememberSearchesChange: function (_e, t) { nym().setRememberSearches(!!(t && t.checked)); },
        });
    }

    if (typeof document !== 'undefined') {
        const sync = () => {
            const sel = document.getElementById('rememberSearchesToggle');
            if (sel && H()) sel.checked = lsGet(H().KEYS.setting) !== H().KEYS.off;
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => setTimeout(sync, 500));
        else setTimeout(sync, 500);
        window.addEventListener('storage', (e) => {
            const n = window.nym;
            if (!H() || !n || typeof n._shExternal !== 'function') return;
            const K = H().KEYS;
            if (e.key !== null && e.key !== K.setting && !(n.pubkey && e.key === K.state + n.pubkey)) return;
            n._shExternal();
        });
    }
})();
