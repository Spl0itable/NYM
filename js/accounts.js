(function () {
    const MAX_ACCOUNTS = 10;
    const INDEX_KEY = 'nymacct:index';
    const NS_PREFIX = 'nymacct:';
    const METHODS = ['nsec', 'extension', 'nip46', 'ephemeral', 'anonymous'];
    const CACHE_DB = 'nym-cache';

    const DEVICE_KEYS = new Set([
        'nym_theme', 'nym_color_mode', 'nym_text_size', 'nym_transparency_enabled',
        'nym_chat_layout', 'nym_chat_view_mode', 'nym_nick_style',
        'nym_timestamps', 'nym_time_format', 'nym_date_format',
        'nym_ui_language', 'nym_ui_language_chosen', 'nym_translate_language',
        'nym_connection_mode', 'nym_relay_url', 'nym_relay_direct_mode', 'nym_relay_direct_ack',
        'nym_low_data_mode', 'nym_mesh_ghost_mode', 'nym_tutorial_seen', 'nym_attest_authority',
        'nym_voice_speed', 'nym_sidebar_section_order', 'nym_sidebar_section_collapsed',
        'nym_settings_sections_collapsed'
    ]);
    const DEVICE_PREFIXES = ['nym_ui_i18n_', 'nym_cmd_i18n_'];
    const VOLATILE_KEYS = new Set(['nym_unfurl_cache', 'nym_nostr_ref_cache', 'nym_msg_verify_status', 'nym_relay_stats']);

    const SETTINGS_SCOPE = {
        device: ['theme', 'colorMode', 'textSize', 'transparency', 'chatLayout', 'chatViewMode', 'nickStyle', 'timestamps', 'timeFormat', 'dateFormat', 'sidebarLayout', 'uiLanguage', 'translateLanguage', 'connectionMode', 'relayTransport', 'lowDataMode', 'meshEnabled', 'meshGhostMode', 'notificationPermission', 'tutorialSeen', 'voiceSpeed'],
        account: ['keys', 'loginMethod', 'vault', 'pqRoot', 'pqDeviceId', 'profile', 'lightningAddress', 'settingsSync', 'pmCache', 'groupCache', 'channelCache', 'unread', 'lastRead', 'chatLocks', 'savedMessages', 'keptMessages', 'drafts', 'mutes', 'blocks', 'friends', 'pinnedChannels', 'hiddenChannels', 'columnsLayout', 'notificationPrefs', 'notificationHistory', 'readReceipts', 'typingIndicators', 'wallpaper', 'emojiFavorites', 'd1Session', 'pushRegistration', 'attestation', 'nymbotCredits', 'nymbotSession', 'purchases', 'outbox', 'depositQueue', 'scheduledMessages', 'meshIdentity', 'meshOutbox', 'anonNymbotKeys', 'notifyInactive']
    };

    function nsKey(id, key) { return NS_PREFIX + id + ':' + key; }

    function dbName(base, account) {
        return account && account.ns ? base + '~' + account.ns : base;
    }

    function classify(key) {
        const k = String(key || '');
        if (k.startsWith(NS_PREFIX)) return 'meta';
        if (DEVICE_KEYS.has(k) || DEVICE_PREFIXES.some((p) => k.startsWith(p))) return 'device';
        if (VOLATILE_KEYS.has(k)) return 'volatile';
        if (k.startsWith('nym_')) return 'account';
        return 'device';
    }

    function methodFromStorage(get) {
        const m = get('nym_nostr_login_method');
        if (m === 'nsec' || m === 'extension' || m === 'nip46') return m;
        if (get('nym_auto_ephemeral') === 'true') {
            return get('nym_random_keypair_per_session') === 'true' ? 'anonymous' : 'ephemeral';
        }
        return '';
    }

    function nymFromStorage(get, method) {
        if (method === 'nsec' || method === 'extension' || method === 'nip46') {
            try {
                const p = JSON.parse(get('nym_nostr_login_profile') || '{}');
                if (p && typeof p.name === 'string') return p.name;
            } catch (_) { }
            return '';
        }
        return get('nym_auto_ephemeral_nick') || '';
    }

    function newAccount(o) {
        return Object.assign({ id: '', ns: '', pubkey: '', method: '', nym: '', avatar: '', addedAt: 0, notifyInactive: false, unread: 0, returnTo: null }, o);
    }

    function emptyIndex() { return { v: 1, active: null, accounts: [], journal: null }; }

    function parseIndex(raw) {
        if (typeof raw !== 'string' || !raw) return null;
        let j;
        try { j = JSON.parse(raw); } catch (_) { return null; }
        if (!j || typeof j !== 'object' || !Array.isArray(j.accounts)) return null;
        const accounts = j.accounts.filter((a) => a && typeof a.id === 'string' && /^[0-9a-z]{1,32}$/.test(a.id)).map((a) => newAccount({
            id: a.id, ns: typeof a.ns === 'string' ? a.ns : a.id,
            pubkey: typeof a.pubkey === 'string' ? a.pubkey : '', method: typeof a.method === 'string' ? a.method : '',
            nym: typeof a.nym === 'string' ? a.nym : '', avatar: typeof a.avatar === 'string' ? a.avatar : '',
            addedAt: Number(a.addedAt) || 0, notifyInactive: a.notifyInactive === true, unread: Math.max(0, Number(a.unread) || 0),
            returnTo: typeof a.returnTo === 'string' ? a.returnTo : null
        }));
        const active = accounts.some((a) => a.id === j.active) ? j.active : null;
        const journal = j.journal && Array.isArray(j.journal.effects) ? { effects: j.journal.effects.map(String), dbs: Array.isArray(j.journal.dbs) ? j.journal.dbs.map(String) : [] } : null;
        return { v: 1, active, accounts, journal };
    }

    function loadOrMigrate(get, id, now) {
        const parsed = parseIndex(get(INDEX_KEY));
        if (parsed) return parsed;
        const method = methodFromStorage(get);
        if (!method) return emptyIndex();
        const pubkey = (method === 'nsec' || method === 'extension' || method === 'nip46') ? (get('nym_nostr_login_pubkey') || '') : '';
        const acct = newAccount({ id, ns: '', pubkey, method, nym: nymFromStorage(get, method), addedAt: now });
        return { v: 1, active: id, accounts: [acct], journal: null };
    }

    function clone(index) { return JSON.parse(JSON.stringify(index)); }

    function refuse(index, error, extra) {
        return Object.assign({ ok: false, error, effects: [], index: clone(index) }, extra || {});
    }

    function activeOf(index) { return index.accounts.find((a) => a.id === index.active) || null; }

    function freeNs(index, id) { return index.accounts.some((a) => a.ns === '') ? id : ''; }

    function isPlaceholder(a) { return !!a && !a.pubkey; }

    function removePlan(index, id) {
        const pos = index.accounts.findIndex((a) => a.id === id);
        if (pos < 0) return refuse(index, 'unknown');
        const gone = index.accounts[pos];
        const rest = index.accounts.filter((a) => a.id !== id).map((a) => (a.returnTo === id ? Object.assign({}, a, { returnTo: null }) : a));
        if (id !== index.active) {
            return { ok: true, effects: ['wipe:' + id], index: { v: 1, active: index.active, accounts: rest, journal: null } };
        }
        let next = null;
        if (isPlaceholder(gone) && gone.returnTo && rest.some((a) => a.id === gone.returnTo)) next = gone.returnTo;
        else if (rest[pos]) next = rest[pos].id;
        else if (rest[pos - 1]) next = rest[pos - 1].id;
        const effects = ['clear', 'wipe:' + id];
        if (next) effects.push('restore:' + next);
        effects.push('reload');
        const accounts = rest.map((a) => (a.id === next ? Object.assign({}, a, { unread: 0 }) : a));
        return { ok: true, effects, index: { v: 1, active: next, accounts, journal: null } };
    }

    function plan(indexIn, op) {
        const index = clone(indexIn);
        index.journal = null;
        const cur = activeOf(index);
        switch (op && op.type) {
            case 'add': {
                if (index.accounts.length >= MAX_ACCOUNTS) return refuse(index, 'cap');
                if (isPlaceholder(cur)) return refuse(index, 'pending');
                const acct = newAccount({ id: op.id, ns: freeNs(index, op.id), addedAt: op.now, returnTo: cur ? cur.id : null });
                const effects = cur ? ['stash:' + cur.id, 'reload'] : ['reload'];
                return { ok: true, effects, index: { v: 1, active: op.id, accounts: index.accounts.concat([acct]), journal: null } };
            }
            case 'register': {
                const info = { pubkey: String(op.pubkey || ''), method: String(op.method || ''), nym: String(op.nym || '') };
                if (!cur) {
                    if (index.accounts.length >= MAX_ACCOUNTS) return refuse(index, 'cap');
                    const acct = newAccount(Object.assign({ id: op.id, ns: freeNs(index, op.id), addedAt: op.now }, info));
                    return { ok: true, result: 'created', effects: [], index: { v: 1, active: op.id, accounts: index.accounts.concat([acct]), journal: null } };
                }
                const dup = info.pubkey ? index.accounts.find((a) => a.id !== cur.id && a.pubkey === info.pubkey) : null;
                if (dup) {
                    if (!isPlaceholder(cur)) return { ok: false, result: 'duplicate', existing: dup.id, effects: [], index };
                    const rest = index.accounts.filter((a) => a.id !== cur.id).map((a) => (a.id === dup.id ? Object.assign({}, a, { unread: 0 }) : a));
                    return { ok: true, result: 'duplicate', existing: dup.id, effects: ['clear', 'wipe:' + cur.id, 'restore:' + dup.id, 'reload'], index: { v: 1, active: dup.id, accounts: rest, journal: null } };
                }
                const accounts = index.accounts.map((a) => (a.id === cur.id ? Object.assign({}, a, info, { returnTo: null }) : a));
                return { ok: true, result: 'updated', effects: [], index: { v: 1, active: cur.id, accounts, journal: null } };
            }
            case 'switch': {
                const target = index.accounts.find((a) => a.id === op.id);
                if (!target) return refuse(index, 'unknown');
                if (cur && target.id === cur.id) return refuse(index, 'active');
                if (isPlaceholder(cur)) {
                    const accounts = index.accounts.filter((a) => a.id !== cur.id).map((a) => (a.id === target.id ? Object.assign({}, a, { unread: 0 }) : a));
                    return { ok: true, effects: ['clear', 'wipe:' + cur.id, 'restore:' + target.id, 'reload'], index: { v: 1, active: target.id, accounts, journal: null } };
                }
                const unread = Math.max(0, Number(op.unread) || 0);
                const accounts = index.accounts.map((a) => {
                    if (cur && a.id === cur.id) return Object.assign({}, a, { unread });
                    if (a.id === target.id) return Object.assign({}, a, { unread: 0 });
                    return a;
                });
                const effects = (cur ? ['stash:' + cur.id] : ['clear']).concat(['restore:' + target.id, 'reload']);
                return { ok: true, effects, index: { v: 1, active: target.id, accounts, journal: null } };
            }
            case 'cancelAdd': {
                if (!isPlaceholder(cur)) return refuse(index, 'none');
                return removePlan(index, cur.id);
            }
            case 'remove':
                return removePlan(index, op.id);
            case 'logout':
                if (!cur) return refuse(index, 'none');
                return removePlan(index, cur.id);
            case 'logoutAll': {
                const effects = ['clear'].concat(index.accounts.map((a) => 'wipe:' + a.id), ['reload']);
                return { ok: true, effects, index: emptyIndex() };
            }
            case 'notify': {
                const target = index.accounts.find((a) => a.id === op.id);
                if (!target) return refuse(index, 'unknown');
                if (op.on && (target.method === 'anonymous' || !target.pubkey)) return refuse(index, 'unsupported');
                const accounts = index.accounts.map((a) => (a.id === op.id ? Object.assign({}, a, { notifyInactive: !!op.on }) : a));
                return { ok: true, effects: [], index: { v: 1, active: index.active, accounts, journal: null } };
            }
            default:
                return refuse(index, 'op');
        }
    }

    function storeKeys(store) {
        const out = [];
        try { for (let i = 0; i < store.length; i++) { const k = store.key(i); if (k !== null) out.push(k); } } catch (_) { }
        return out;
    }

    function runEffects(store, effects) {
        for (const e of effects || []) {
            const at = e.indexOf(':');
            const verb = at < 0 ? e : e.slice(0, at);
            const id = at < 0 ? '' : e.slice(at + 1);
            if (verb === 'stash' && id) {
                for (const k of storeKeys(store)) {
                    const c = classify(k);
                    if (c === 'account') {
                        const v = store.getItem(k);
                        if (v !== null) store.setItem(nsKey(id, k), v);
                        store.removeItem(k);
                    } else if (c === 'volatile') {
                        store.removeItem(k);
                    }
                }
            } else if (verb === 'restore' && id) {
                const pre = nsKey(id, '');
                for (const k of storeKeys(store)) {
                    if (!k.startsWith(pre)) continue;
                    const v = store.getItem(k);
                    const plainKey = k.slice(pre.length);
                    if (v !== null && classify(plainKey) === 'account') store.setItem(plainKey, v);
                    store.removeItem(k);
                }
            } else if (verb === 'clear') {
                for (const k of storeKeys(store)) {
                    const c = classify(k);
                    if (c === 'account' || c === 'volatile') store.removeItem(k);
                }
            } else if (verb === 'wipe' && id) {
                const pre = nsKey(id, '');
                for (const k of storeKeys(store)) if (k.startsWith(pre)) store.removeItem(k);
            }
        }
    }

    function journalDbs(before, effects) {
        const out = [];
        for (const e of effects) {
            if (!e.startsWith('wipe:')) continue;
            const a = before.accounts.find((x) => x.id === e.slice(5));
            if (a) out.push(dbName(CACHE_DB, a));
        }
        return out;
    }

    function commit(store, result, before) {
        if (!result || !result.ok) return null;
        const prev = before || parseIndex(store.getItem(INDEX_KEY)) || emptyIndex();
        const effects = result.effects.filter((e) => e !== 'reload');
        const dbs = journalDbs(prev, effects);
        const next = clone(result.index);
        const deferred = result.effects.includes('reload');
        if (deferred) {
            next.journal = { effects, dbs };
            store.setItem(INDEX_KEY, JSON.stringify(next));
            return { deferred: true, dbs };
        }
        next.journal = null;
        runEffects(store, effects);
        store.setItem(INDEX_KEY, JSON.stringify(next));
        return { deferred: false, dbs };
    }

    function boot(store, opts) {
        const o = opts || {};
        const get = (k) => { try { return store.getItem(k); } catch (_) { return null; } };
        const index = loadOrMigrate(get, o.id ? o.id() : 'x', o.now ? o.now() : 0);
        let dropDbs = [];
        let ranJournal = false;
        if (index.journal) {
            ranJournal = true;
            runEffects(store, index.journal.effects);
            dropDbs = index.journal.dbs.slice();
            index.journal = null;
        }
        if (index.accounts.length || get(INDEX_KEY) !== null) {
            try { store.setItem(INDEX_KEY, JSON.stringify(index)); } catch (_) { }
        }
        return { index, account: activeOf(index), dropDbs, ranJournal };
    }

    function randomId() {
        const b = new Uint8Array(6);
        try { self.crypto.getRandomValues(b); } catch (_) { for (let i = 0; i < 6; i++) b[i] = Math.floor(Math.random() * 256); }
        return Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');
    }

    const api = {
        MAX_ACCOUNTS, INDEX_KEY, NS_PREFIX, METHODS, CACHE_DB, SETTINGS_SCOPE,
        nsKey, dbName, classify, methodFromStorage, nymFromStorage, parseIndex, loadOrMigrate,
        emptyIndex, plan, runEffects, commit, boot, randomId, activeOf
    };
    self.NymAccounts = api;

    if (typeof window === 'undefined' || typeof document === 'undefined') return;
    let ls = null;
    try { ls = window.localStorage; } catch (_) { ls = null; }
    if (!ls) return;
    let booted = null;
    try {
        booted = boot(ls, { id: randomId, now: () => Date.now() });
    } catch (_) {
        booted = { index: emptyIndex(), account: null, dropDbs: [], ranJournal: false };
    }
    if (booted.ranJournal) {
        try { sessionStorage.clear(); } catch (_) { }
    }
    api.page = booted.account ? Object.assign({}, booted.account) : null;
    api.pageId = booted.account ? booted.account.id : null;
    api.pageDb = function (base) { return dbName(base, api.page); };
    api.read = function () { return parseIndex(ls.getItem(INDEX_KEY)) || emptyIndex(); };
    api.frozen = false;
    api.adopt = function (account) {
        api.page = Object.assign({}, account);
        api.pageId = account.id;
    };
    api.update = function (fn) {
        if (api.frozen) return null;
        const idx = api.read();
        if (idx.journal || idx.active !== api.pageId) return null;
        const next = fn(clone(idx));
        if (!next) return null;
        next.journal = null;
        try { ls.setItem(INDEX_KEY, JSON.stringify(next)); } catch (_) { return null; }
        return next;
    };
    api.freeze = function (reloadMs) {
        if (!api.frozen) {
            api.frozen = true;
            const proto = Storage.prototype;
            const set = proto.setItem, rem = proto.removeItem, clr = proto.clear;
            proto.setItem = function (k, v) { if (this === ls && classify(k) !== 'meta') return; return set.call(this, k, v); };
            proto.removeItem = function (k) { if (this === ls && classify(k) !== 'meta') return; return rem.call(this, k); };
            proto.clear = function () { if (this === ls) return; return clr.call(this); };
            try { document.documentElement.classList.add('nym-acct-frozen'); } catch (_) { }
        }
        if (typeof reloadMs === 'number') setTimeout(() => { try { location.reload(); } catch (_) { } }, reloadMs);
    };
    window.addEventListener('storage', (e) => {
        if (api.frozen) return;
        if (e.storageArea && e.storageArea !== ls) return;
        if (e.key !== null && e.key !== INDEX_KEY) return;
        const idx = e.key === null ? null : parseIndex(e.newValue);
        if (idx && !idx.journal && idx.active === api.pageId) return;
        if (!idx && e.key !== null && e.newValue === null && !api.pageId) return;
        api.freeze(1500);
    });
    for (const name of booted.dropDbs) {
        try { indexedDB.deleteDatabase(name); } catch (_) { }
    }
})();
