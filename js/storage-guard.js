(function () {
    const I18N_PREFIXES = ['nym_ui_i18n_', 'nym_cmd_i18n_'];
    const TIERS = [
        ['nym_unfurl_cache', 'nym_nostr_ref_cache', 'nym_relay_stats', 'nym_msg_verify_status', 'nym_shop_active_cache', 'nym_botpm_model_catalog', 'nym_geo_relays', 'nym_geohash_places'],
        'i18n-other',
        ['nym_custom_emojis', 'nym_custom_emoji_packs'],
        'i18n-current',
        ['nym_zap_known']
    ];
    const TRIM = ['nym_channel_activity', 'nym_unread_basis', 'nym_unread_counts', 'nym_channel_last_read'];
    const RANKED = ['nym_unread_basis', 'nym_unread_counts'];
    const RANK_FROM = ['nym_channel_activity', 'nym_channel_last_read'];
    const USER = -1;
    const RETRY_MS = 30000;

    function i18nLang(key) {
        for (const p of I18N_PREFIXES) if (key.startsWith(p)) return key.slice(p.length);
        return null;
    }

    function tierOf(key, currentLang) {
        const k = String(key == null ? '' : key);
        const lang = i18nLang(k);
        for (let i = 0; i < TIERS.length; i++) {
            const t = TIERS[i];
            if (t === 'i18n-other' && lang !== null && lang !== (currentLang || '')) return i;
            if (t === 'i18n-current' && lang !== null && lang === (currentLang || '')) return i;
            if (Array.isArray(t) && t.includes(k)) return i;
        }
        return USER;
    }

    function isQuota(e) {
        return !!e && (e.name === 'QuotaExceededError' || e.name === 'NS_ERROR_DOM_QUOTA_REACHED' || e.code === 22 || e.code === 1014 || /quota/i.test(String(e.message || '')));
    }

    function keysOf(store) {
        const out = [];
        for (let i = 0; i < store.length; i++) {
            const k = store.key(i);
            if (k !== null) out.push(k);
        }
        return out;
    }

    function victims(store, below, keep, currentLang) {
        const list = [];
        for (const k of keysOf(store)) {
            if (k === keep) continue;
            const t = tierOf(k, currentLang);
            if (t === USER || t >= below) continue;
            const v = store.getItem(k);
            list.push({ k, t, size: k.length + (v ? v.length : 0) });
        }
        list.sort((a, b) => (a.t - b.t) || (b.size - a.size) || (a.k < b.k ? -1 : 1));
        return list;
    }

    function recency(v) {
        if (typeof v === 'number' && isFinite(v)) return v;
        if (v && typeof v === 'object') {
            for (const f of ['ts', 'at', 't', 'updatedAt']) if (typeof v[f] === 'number' && isFinite(v[f])) return v[f];
        }
        return 0;
    }

    function rankOf(raws) {
        const out = new Map();
        for (const raw of raws || []) {
            let data;
            try { data = JSON.parse(raw); } catch (_) { continue; }
            if (!data || typeof data !== 'object' || Array.isArray(data)) continue;
            for (const [k, v] of Object.entries(data)) {
                if (typeof v !== 'number' || !isFinite(v)) continue;
                const ms = v < 1e12 ? v * 1000 : v;
                if (ms > (out.get(k) || 0)) out.set(k, ms);
            }
        }
        return out;
    }

    function trimmed(raw, rank) {
        let data;
        try { data = JSON.parse(raw); } catch (_) { return null; }
        if (Array.isArray(data)) return data.length > 1 ? JSON.stringify(data.slice(data.length - Math.floor(data.length / 2))) : null;
        if (!data || typeof data !== 'object') return null;
        const entries = Object.entries(data);
        if (entries.length < 2) return null;
        const score = rank ? (e) => rank.get(e[0]) || 0 : (e) => recency(e[1]);
        entries.sort((a, b) => (score(b) - score(a)) || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
        const out = {};
        for (const [k, v] of entries.slice(0, Math.floor(entries.length / 2))) out[k] = v;
        return JSON.stringify(out);
    }

    function attempt(store, set, k, v) {
        try { set.call(store, k, v); return null; } catch (e) {
            if (!isQuota(e)) throw e;
            return e;
        }
    }

    function write(store, set, remove, key, value, currentLang) {
        const k = String(key);
        const v = String(value);
        const first = attempt(store, set, k, v);
        if (!first) return { ok: true, evicted: [], trimmed: [] };
        const own = tierOf(k, currentLang);
        const evicted = [];
        const cut = [];
        for (const vic of victims(store, own === USER ? TIERS.length : own, k, currentLang)) {
            remove.call(store, vic.k);
            evicted.push(vic.k);
            if (!attempt(store, set, k, v)) return { ok: true, evicted, trimmed: cut };
        }
        if (own === USER) {
            for (let round = 0; round < 32; round++) {
                let changed = false;
                for (const t of TRIM) {
                    if (t === k) continue;
                    const raw = store.getItem(t);
                    if (raw === null) continue;
                    const next = trimmed(raw, RANKED.includes(t) ? rankOf(RANK_FROM.map((r) => store.getItem(r))) : undefined);
                    if (next === null) remove.call(store, t);
                    else if (attempt(store, set, t, next)) continue;
                    cut.push(t);
                    changed = true;
                    if (!attempt(store, set, k, v)) return { ok: true, evicted, trimmed: cut };
                }
                if (!changed) break;
            }
        }
        return { ok: false, evicted, trimmed: cut, user: own === USER, error: first };
    }

    const api = { TIERS, TRIM, RANKED, RANK_FROM, USER, I18N_PREFIXES, tierOf, isQuota, victims, write, trimmed, rankOf, i18nLang };

    function install(proto, store) {
        if (!proto || !store || proto.setItem.__nymGuard) return null;
        const nativeSet = proto.setItem;
        const nativeRemove = proto.removeItem;
        const nativeGet = proto.getItem;
        const nativeClear = proto.clear;
        const held = new Map();
        let timer = null;
        let strict = 0;
        const blocked = () => {
            try {
                const A = self.NymAccounts;
                if (!A) return false;
                if (A.frozen) return true;
                if (typeof A.pageId !== 'string' || !A.INDEX_KEY) return false;
                const idx = JSON.parse((held.has(A.INDEX_KEY) ? held.get(A.INDEX_KEY) : nativeGet.call(store, A.INDEX_KEY)) || 'null');
                return !idx || !!idx.journal || idx.active !== A.pageId;
            } catch (_) { return false; }
        };
        const wiped = () => {
            try {
                const A = self.NymAccounts;
                if (!A || !A.INDEX_KEY) return false;
                if (!A.frozen && typeof A.pageId !== 'string') return false;
                return !held.has(A.INDEX_KEY) && nativeGet.call(store, A.INDEX_KEY) === null;
            } catch (_) { return false; }
        };
        const keep = () => {
            try {
                const A = self.NymAccounts;
                if (A && typeof A.keepHeld === 'function') { A.keepHeld(A.stash, A.pageId); return; }
            } catch (_) { }
            held.clear();
        };
        const lang = () => { try { return nativeGet.call(store, 'nym_ui_language') || ''; } catch (_) { return ''; } };
        const flush = () => {
            if (timer) { clearTimeout(timer); timer = null; }
            if (wiped()) { held.clear(); return; }
            if (blocked()) keep();
            for (const [k, v] of [...held]) {
                let r;
                try { r = write(store, nativeSet, nativeRemove, k, v, lang()); } catch (_) { r = { ok: true }; }
                if (r.ok && held.get(k) === v) held.delete(k);
            }
            if (held.size) arm();
        };
        const arm = () => { if (!timer) timer = setTimeout(flush, RETRY_MS); };
        const guarded = function (key, value) {
            if (this !== store) return nativeSet.call(this, key, value);
            const k = String(key);
            const v = String(value);
            const r = write(store, nativeSet, nativeRemove, k, v, lang());
            if (r.ok) { held.delete(k); return; }
            if (strict && r.user) throw r.error;
            if (!r.user) return;
            held.set(k, v);
            arm();
        };
        guarded.__nymGuard = true;
        proto.setItem = guarded;
        proto.getItem = function (key) {
            if (this === store && held.size) {
                const k = String(key);
                if (held.has(k)) return held.get(k);
            }
            return nativeGet.call(this, key);
        };
        proto.removeItem = function (key) {
            if (this === store && held.size) held.delete(String(key));
            return nativeRemove.call(this, key);
        };
        if (typeof nativeClear === 'function') {
            proto.clear = function () {
                if (this === store) {
                    held.clear();
                    if (timer) { clearTimeout(timer); timer = null; }
                }
                return nativeClear.call(this);
            };
        }
        api.set = function (key, value) {
            try { store.setItem(key, value); return true; } catch (_) { return false; }
        };
        api.held = () => [...held.keys()];
        api.heldEntries = () => [...held];
        api.drop = (pick) => {
            for (const k of [...held.keys()]) if (!pick || pick(k)) held.delete(k);
            if (!held.size && timer) { clearTimeout(timer); timer = null; }
        };
        api.strictly = (fn) => { strict++; try { return fn(); } finally { strict--; } };
        api.flush = flush;
        return guarded;
    }

    api.install = install;
    api.set = function () { return false; };
    api.held = () => [];
    api.heldEntries = () => [];
    api.drop = () => { };
    api.strictly = (fn) => fn();
    api.flush = () => { };
    self.NymStorage = api;

    if (typeof window === 'undefined' || typeof Storage === 'undefined') return;
    let ls = null;
    try { ls = window.localStorage; } catch (_) { ls = null; }
    if (!ls) return;
    install(Storage.prototype, ls);
    const later = () => { try { api.flush(); } catch (_) { } };
    try {
        window.addEventListener('pagehide', later);
        if (typeof document !== 'undefined') document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') later(); });
    } catch (_) { }
})();
