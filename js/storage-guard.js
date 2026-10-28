(function () {
    const I18N_PREFIXES = ['nym_ui_i18n_', 'nym_cmd_i18n_'];
    const TIERS = [
        ['nym_unfurl_cache', 'nym_nostr_ref_cache', 'nym_relay_stats', 'nym_msg_verify_status'],
        'i18n-other',
        ['nym_custom_emojis', 'nym_custom_emoji_packs'],
        'i18n-current',
        ['nym_zap_known']
    ];
    const USER = -1;

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

    function write(store, set, remove, key, value, currentLang) {
        const k = String(key);
        const v = String(value);
        try { set.call(store, k, v); return { ok: true, evicted: [] }; } catch (e) {
            if (!isQuota(e)) throw e;
            const own = tierOf(k, currentLang);
            const evicted = [];
            for (const vic of victims(store, own === USER ? TIERS.length : own, k, currentLang)) {
                remove.call(store, vic.k);
                evicted.push(vic.k);
                try { set.call(store, k, v); return { ok: true, evicted }; } catch (e2) { if (!isQuota(e2)) throw e2; }
            }
            return { ok: false, evicted, user: own === USER, error: e };
        }
    }

    const api = { TIERS, USER, I18N_PREFIXES, tierOf, isQuota, victims, write, i18nLang };

    function install(proto, store, onFull) {
        if (!proto || !store || proto.setItem.__nymGuard) return null;
        const nativeSet = proto.setItem;
        const nativeRemove = proto.removeItem;
        const lang = () => { try { return store.getItem('nym_ui_language') || ''; } catch (_) { return ''; } };
        const guarded = function (key, value) {
            if (this !== store) return nativeSet.call(this, key, value);
            const r = write(store, nativeSet, nativeRemove, key, value, lang());
            if (r.ok) return;
            if (!r.user) return;
            if (onFull) { try { onFull(String(key)); } catch (_) { } }
            throw r.error;
        };
        guarded.__nymGuard = true;
        proto.setItem = guarded;
        api.set = function (key, value) {
            try { store.setItem(key, value); return true; } catch (_) { return false; }
        };
        return guarded;
    }

    api.install = install;
    api.set = function () { return false; };
    self.NymStorage = api;

    if (typeof window === 'undefined' || typeof Storage === 'undefined') return;
    let ls = null;
    try { ls = window.localStorage; } catch (_) { ls = null; }
    if (!ls) return;
    install(Storage.prototype, ls, (key) => {
        try { window.dispatchEvent(new CustomEvent('nym-storage-full', { detail: { key } })); } catch (_) { }
    });
})();
