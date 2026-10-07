(function () {
    const MAX_ACCOUNTS = 10;
    const INDEX_KEY = 'nymacct:index';
    const NS_PREFIX = 'nymacct:';
    const METHODS = ['nsec', 'extension', 'nip46', 'ephemeral', 'anonymous'];
    const CACHE_DB = 'nym-cache';
    const STASH_DB = 'nym-accounts';
    const DROP_KEY = 'nymacct:drop';
    const AVATAR_MAX = 4096;

    const DEVICE_KEYS = new Set([
        'nym_theme', 'nym_color_mode', 'nym_text_size', 'nym_transparency_enabled',
        'nym_chat_layout', 'nym_chat_view_mode', 'nym_nick_style',
        'nym_timestamps', 'nym_time_format', 'nym_date_format',
        'nym_ui_language', 'nym_ui_language_chosen', 'nym_translate_language',
        'nym_connection_mode', 'nym_relay_url', 'nym_relay_direct_mode', 'nym_relay_direct_ack', 'nym_relay_fallback_notice_off',
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
            nym: typeof a.nym === 'string' ? a.nym : '', avatar: typeof a.avatar === 'string' && a.avatar.length <= AVATAR_MAX ? a.avatar : '',
            addedAt: Number(a.addedAt) || 0, notifyInactive: a.notifyInactive === true, unread: Math.max(0, Number(a.unread) || 0),
            returnTo: typeof a.returnTo === 'string' ? a.returnTo : null
        }));
        const active = accounts.some((a) => a.id === j.active) ? j.active : null;
        const journal = j.journal && Array.isArray(j.journal.effects) ? { effects: j.journal.effects.map(String), dbs: Array.isArray(j.journal.dbs) ? j.journal.dbs.map(String) : [] } : null;
        if (journal && j.journal.store === 'idb') journal.store = 'idb';
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

    function isQuota(e) {
        return !!e && (e.name === 'QuotaExceededError' || e.name === 'NS_ERROR_DOM_QUOTA_REACHED' || e.code === 22 || e.code === 1014 || /quota/i.test(String(e.message || '')));
    }

    function failure(e) { return { ok: false, error: isQuota(e) ? 'quota' : 'storage' }; }

    function snapshot(store) {
        const out = {};
        for (const k of storeKeys(store)) {
            if (classify(k) !== 'account') continue;
            const v = store.getItem(k);
            if (v !== null) out[k] = v;
        }
        return out;
    }

    function clearAccount(store) {
        for (const k of storeKeys(store)) {
            const c = classify(k);
            if (c === 'account' || c === 'volatile') store.removeItem(k);
        }
    }

    function writeAll(store, data) {
        for (const k of Object.keys(data || {})) {
            if (classify(k) === 'account' && typeof data[k] === 'string') store.setItem(k, data[k]);
        }
    }

    function legacyStashes(store) {
        const out = {};
        for (const k of storeKeys(store)) {
            if (!k.startsWith(NS_PREFIX) || k === INDEX_KEY) continue;
            const rest = k.slice(NS_PREFIX.length);
            const at = rest.indexOf(':');
            if (at < 1) continue;
            const id = rest.slice(0, at);
            const key = rest.slice(at + 1);
            if (!/^[0-9a-z]{1,32}$/.test(id) || !key) continue;
            if (!out[id]) out[id] = { keys: [], data: {} };
            out[id].keys.push(k);
            const v = store.getItem(k);
            if (v !== null && classify(key) === 'account') out[id].data[key] = v;
        }
        return out;
    }

    async function migrateLegacy(store, stash) {
        const groups = legacyStashes(store);
        const ids = Object.keys(groups);
        if (!ids.length) return 0;
        const idx = parseIndex(store.getItem(INDEX_KEY));
        let moved = 0;
        for (const id of ids) {
            const g = groups[id];
            if (idx && !idx.journal && idx.active === id) {
                for (const k of Object.keys(g.data)) {
                    if (store.getItem(k) === null) store.setItem(k, g.data[k]);
                }
            } else {
                await stash.merge(id, g.data);
            }
            for (const k of g.keys) store.removeItem(k);
            moved += g.keys.length;
        }
        return moved;
    }

    function effectIds(effects) {
        const pick = (verb) => effects.filter((e) => e.startsWith(verb + ':')).map((e) => e.slice(verb.length + 1));
        return { stash: pick('stash'), restore: pick('restore')[0] || null, wipes: pick('wipe'), clear: effects.includes('clear') };
    }

    function mergeDrop(store, dbs) {
        if (!dbs || !dbs.length) return;
        let cur = [];
        try { cur = JSON.parse(store.getItem(DROP_KEY) || '[]'); } catch (_) { cur = []; }
        if (!Array.isArray(cur)) cur = [];
        const all = Array.from(new Set(cur.concat(dbs).map(String)));
        try { store.setItem(DROP_KEY, JSON.stringify(all)); } catch (_) { }
    }

    function swapIn(store, prev, nextIndex, journal, cur, data, curId) {
        const pending = Object.assign(clone(nextIndex), { journal });
        let done = Object.assign(clone(nextIndex), { journal: null });
        const bare = (x) => Object.assign(clone(x), { accounts: x.accounts.map((a) => Object.assign({}, a, { avatar: '' })) });
        try {
            clearAccount(store);
            store.setItem(INDEX_KEY, JSON.stringify(pending));
            try {
                writeAll(store, data);
            } catch (e) {
                if (!isQuota(e)) throw e;
                store.setItem(INDEX_KEY, JSON.stringify(bare(pending)));
                writeAll(store, data);
                done = bare(done);
            }
        } catch (e) {
            let restored = true;
            try { clearAccount(store); writeAll(store, cur); } catch (_) { restored = false; }
            const back = Object.assign(clone(prev), { journal: null });
            if (!restored && curId) back.journal = { effects: ['clear', 'restore:' + curId], dbs: [], store: 'idb' };
            try { store.setItem(INDEX_KEY, JSON.stringify(back)); } catch (_) { }
            return Object.assign(failure(e), { restored });
        }
        try {
            store.setItem(INDEX_KEY, JSON.stringify(done));
        } catch (_) {
            try { store.setItem(INDEX_KEY, JSON.stringify(bare(done))); } catch (__) { return { ok: true, settled: false }; }
        }
        return { ok: true, settled: true };
    }

    async function commit(store, stash, result, before, hooks) {
        if (!result || !result.ok) return null;
        const h = hooks || {};
        const prev = before || parseIndex(store.getItem(INDEX_KEY)) || emptyIndex();
        const effects = result.effects.filter((e) => e !== 'reload');
        const dbs = journalDbs(prev, effects);
        const ids = effectIds(effects);
        if (!result.effects.includes('reload')) {
            const next = Object.assign(clone(result.index), { journal: null });
            try { store.setItem(INDEX_KEY, JSON.stringify(next)); } catch (e) { return failure(e); }
            for (const id of ids.wipes) { try { await stash.del(id); } catch (_) { } }
            return { ok: true, deferred: false, dbs };
        }
        if (!stash) return { ok: false, error: 'storage' };
        const swapping = ids.clear || ids.stash.length > 0 || !!ids.restore;
        const curId = prev.active;
        let cur = {};
        let data = {};
        try {
            await migrateLegacy(store, stash);
            cur = snapshot(store);
            if (swapping && curId) await stash.put(curId, cur);
            if (ids.restore) data = (await stash.get(ids.restore)) || {};
        } catch (e) {
            return failure(e);
        }
        if (h.before) h.before();
        let settled = true;
        if (swapping) {
            const r = swapIn(store, prev, result.index, { effects, dbs, store: 'idb' }, cur, data, curId);
            if (!r.ok) return r;
            settled = r.settled;
        } else {
            try { store.setItem(INDEX_KEY, JSON.stringify(Object.assign(clone(result.index), { journal: null }))); } catch (e) { return failure(e); }
        }
        mergeDrop(store, dbs);
        if (!settled) return { ok: true, deferred: true, dbs };
        for (const id of ids.wipes) { try { await stash.del(id); } catch (_) { } }
        if (ids.restore && !ids.wipes.includes(ids.restore)) { try { await stash.drop(ids.restore); } catch (_) { } }
        return { ok: true, deferred: true, dbs };
    }

    async function recover(store, stash) {
        const idx = parseIndex(store.getItem(INDEX_KEY));
        if (!idx || !idx.journal) return false;
        const j = idx.journal;
        const ids = effectIds(j.effects);
        await migrateLegacy(store, stash);
        if (!j.store) {
            const snap = snapshot(store);
            for (const id of ids.stash) await stash.put(id, Object.assign((await stash.get(id)) || {}, snap));
            store.setItem(INDEX_KEY, JSON.stringify(Object.assign(clone(idx), { journal: Object.assign({}, j, { store: 'idb' }) })));
        }
        const data = ids.restore ? ((await stash.get(ids.restore)) || {}) : {};
        if (ids.clear || ids.stash.length || ids.restore) {
            clearAccount(store);
            writeAll(store, data);
        }
        store.setItem(INDEX_KEY, JSON.stringify(Object.assign(clone(idx), { journal: null })));
        mergeDrop(store, j.dbs);
        for (const id of ids.wipes) { try { await stash.del(id); } catch (_) { } }
        if (ids.restore && !ids.wipes.includes(ids.restore)) { try { await stash.drop(ids.restore); } catch (_) { } }
        return true;
    }

    async function sweep(store, stash, opts) {
        const idx = parseIndex(store.getItem(INDEX_KEY));
        if (!idx || idx.journal) return [];
        const o = opts || {};
        const known = new Set(idx.accounts.map((a) => a.id));
        const gone = [];
        for (const id of await stash.ids()) {
            if (!known.has(id)) { await stash.del(id); gone.push(id); }
            else if (id === idx.active && o.active) { await stash.drop(id); gone.push(id); }
        }
        for (const id of await stash.carryIds()) {
            if (!known.has(id)) { await stash.del(id); if (!gone.includes(id)) gone.push(id); }
        }
        return gone;
    }

    function boot(store, opts) {
        const o = opts || {};
        const get = (k) => { try { return store.getItem(k); } catch (_) { return null; } };
        const index = loadOrMigrate(get, o.id ? o.id() : 'x', o.now ? o.now() : 0);
        const recovering = !!index.journal;
        if (!recovering && index.accounts.length && get(INDEX_KEY) === null) {
            try { store.setItem(INDEX_KEY, JSON.stringify(index)); } catch (_) { }
        }
        let dropDbs = [];
        try { const d = JSON.parse(get(DROP_KEY) || '[]'); if (Array.isArray(d)) dropDbs = d.map(String); } catch (_) { dropDbs = []; }
        return { index, account: activeOf(index), dropDbs, recovering };
    }

    function memStash() {
        const s = new Map();
        const c = new Map();
        return {
            stashMap: s, carryMap: c,
            async put(id, data) { s.set(id, Object.assign({}, data)); },
            async merge(id, data) { s.set(id, Object.assign({}, data, s.get(id) || {})); },
            async get(id) { return s.has(id) ? Object.assign({}, s.get(id)) : null; },
            async key(id, k) { const d = s.get(id); return d && Object.prototype.hasOwnProperty.call(d, k) ? d[k] : null; },
            async drop(id) { s.delete(id); },
            async del(id) { s.delete(id); c.delete(id); },
            async ids() { return [...s.keys()]; },
            async carryIds() { return [...c.keys()]; },
            async carryPut(id, v) { c.set(id, JSON.parse(JSON.stringify(v))); },
            async carryGet(id) { return c.has(id) ? JSON.parse(JSON.stringify(c.get(id))) : null; },
            async carryDel(id) { c.delete(id); }
        };
    }

    function idbStash(idb) {
        let dbp = null;
        const open = () => {
            if (dbp) return dbp;
            dbp = new Promise((resolve, reject) => {
                let r;
                try { r = idb.open(STASH_DB, 1); } catch (e) { reject(e); return; }
                r.onupgradeneeded = () => {
                    const d = r.result;
                    if (!d.objectStoreNames.contains('stash')) d.createObjectStore('stash');
                    if (!d.objectStoreNames.contains('carry')) d.createObjectStore('carry');
                };
                r.onsuccess = () => {
                    const d = r.result;
                    d.onversionchange = () => { try { d.close(); } catch (_) { } dbp = null; };
                    resolve(d);
                };
                r.onerror = () => reject(r.error || new Error('idb'));
                r.onblocked = () => reject(new Error('idb blocked'));
            }).catch((e) => { dbp = null; throw e; });
            return dbp;
        };
        const range = (id) => IDBKeyRange.bound([id, ''], [id, '￿']);
        const run = async (names, mode, fn) => {
            const d = await open();
            return new Promise((resolve, reject) => {
                let t;
                try { t = mode === 'readwrite' ? d.transaction(names, mode, { durability: 'strict' }) : d.transaction(names, mode); } catch (e) { reject(e); return; }
                const box = {};
                try { fn(t, box); } catch (e) { try { t.abort(); } catch (_) { } reject(e); return; }
                t.oncomplete = () => resolve(box.v);
                t.onerror = () => reject(t.error || new Error('idb'));
                t.onabort = () => reject(t.error || new Error('idb abort'));
            });
        };
        const read = (t, box, id) => {
            const st = t.objectStore('stash');
            const kq = st.getAllKeys(range(id));
            const vq = st.getAll(range(id));
            vq.onsuccess = () => {
                const keys = kq.result || [];
                const vals = vq.result || [];
                if (!keys.length) { box.v = null; return; }
                const out = {};
                keys.forEach((k, i) => { out[k[1]] = vals[i]; });
                box.v = out;
            };
        };
        return {
            put: (id, data) => run(['stash'], 'readwrite', (t) => {
                const st = t.objectStore('stash');
                st.delete(range(id));
                for (const k of Object.keys(data || {})) st.put(String(data[k]), [id, k]);
            }),
            merge: (id, data) => run(['stash'], 'readwrite', (t) => {
                const st = t.objectStore('stash');
                for (const k of Object.keys(data || {})) {
                    const q = st.getKey([id, k]);
                    q.onsuccess = () => { if (q.result === undefined) st.put(String(data[k]), [id, k]); };
                }
            }),
            get: (id) => run(['stash'], 'readonly', (t, box) => read(t, box, id)),
            key: (id, k) => run(['stash'], 'readonly', (t, box) => {
                const q = t.objectStore('stash').get([id, k]);
                q.onsuccess = () => { box.v = q.result === undefined ? null : q.result; };
            }),
            drop: (id) => run(['stash'], 'readwrite', (t) => { t.objectStore('stash').delete(range(id)); }),
            del: (id) => run(['stash', 'carry'], 'readwrite', (t) => {
                t.objectStore('stash').delete(range(id));
                t.objectStore('carry').delete(id);
            }),
            ids: () => run(['stash'], 'readonly', (t, box) => {
                const out = new Set();
                const q = t.objectStore('stash').openKeyCursor();
                q.onsuccess = () => {
                    const c = q.result;
                    if (!c) { box.v = [...out]; return; }
                    const id = c.key[0];
                    out.add(id);
                    c.continue([id, '￿￿']);
                };
            }),
            carryIds: () => run(['carry'], 'readonly', (t, box) => {
                const q = t.objectStore('carry').getAllKeys();
                q.onsuccess = () => { box.v = q.result || []; };
            }),
            carryPut: (id, v) => run(['carry'], 'readwrite', (t) => { t.objectStore('carry').put(v, id); }),
            carryGet: (id) => run(['carry'], 'readonly', (t, box) => {
                const q = t.objectStore('carry').get(id);
                q.onsuccess = () => { box.v = q.result === undefined ? null : q.result; };
            }),
            carryDel: (id) => run(['carry'], 'readwrite', (t) => { t.objectStore('carry').delete(id); })
        };
    }

    function randomId() {
        const b = new Uint8Array(6);
        try { self.crypto.getRandomValues(b); } catch (_) { for (let i = 0; i < 6; i++) b[i] = Math.floor(Math.random() * 256); }
        return Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');
    }

    const api = {
        MAX_ACCOUNTS, INDEX_KEY, NS_PREFIX, METHODS, CACHE_DB, STASH_DB, DROP_KEY, AVATAR_MAX, SETTINGS_SCOPE,
        nsKey, dbName, classify, methodFromStorage, nymFromStorage, parseIndex, loadOrMigrate,
        emptyIndex, plan, runEffects, commit, recover, sweep, boot, randomId, activeOf, isQuota,
        snapshot, legacyStashes, migrateLegacy, memStash, idbStash
    };
    self.NymAccounts = api;

    if (typeof window === 'undefined' || typeof document === 'undefined') return;
    let ls = null;
    try { ls = window.localStorage; } catch (_) { ls = null; }
    if (!ls) return;
    const proto = Storage.prototype;
    const nativeSet = proto.setItem, nativeRemove = proto.removeItem, nativeClear = proto.clear;
    const raw = {
        get length() { return ls.length; },
        key: (i) => ls.key(i),
        getItem: (k) => ls.getItem(k),
        setItem: (k, v) => nativeSet.call(ls, k, v),
        removeItem: (k) => nativeRemove.call(ls, k)
    };
    let stash = null;
    try { if (typeof indexedDB !== 'undefined') stash = idbStash(indexedDB); } catch (_) { stash = null; }
    const locked = (fn) => {
        try { if (navigator.locks && navigator.locks.request) return navigator.locks.request('nymacct', fn); } catch (_) { }
        return fn();
    };
    let booted = null;
    try {
        booted = boot(raw, { id: randomId, now: () => Date.now() });
    } catch (_) {
        booted = { index: emptyIndex(), account: null, dropDbs: [], recovering: false };
    }
    api.page = booted.account ? Object.assign({}, booted.account) : null;
    api.pageId = booted.account ? booted.account.id : null;
    api.pageDb = function (base) { return dbName(base, api.page); };
    api.read = function () { return parseIndex(ls.getItem(INDEX_KEY)) || emptyIndex(); };
    api.frozen = false;
    api.stash = stash;
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
        try { raw.setItem(INDEX_KEY, JSON.stringify(next)); } catch (_) { return null; }
        return next;
    };
    api.freeze = function (reloadMs) {
        if (!api.frozen) {
            api.frozen = true;
            proto.setItem = function (k, v) { if (this === ls && classify(k) !== 'meta') return; return nativeSet.call(this, k, v); };
            proto.removeItem = function (k) { if (this === ls && classify(k) !== 'meta') return; return nativeRemove.call(this, k); };
            proto.clear = function () { if (this === ls) return; return nativeClear.call(this); };
            try { document.documentElement.classList.add('nym-acct-frozen'); } catch (_) { }
        }
        if (typeof reloadMs === 'number') setTimeout(() => { try { location.reload(); } catch (_) { } }, reloadMs);
    };
    api.thaw = function () {
        if (!api.frozen || api.frozenByOther) return;
        api.frozen = false;
        proto.setItem = nativeSet;
        proto.removeItem = nativeRemove;
        proto.clear = nativeClear;
        try { document.documentElement.classList.remove('nym-acct-frozen'); } catch (_) { }
    };
    api.apply = function (result, before, hooks) {
        return locked(() => commit(raw, stash, result, before, hooks));
    };
    api.stashKey = async function (id, k) {
        if (!stash) return null;
        try { return await stash.key(id, k); } catch (_) { return null; }
    };
    api.carryPut = async function (id, v) {
        if (!stash || !id) return false;
        try { await stash.carryPut(id, v); return true; } catch (_) { return false; }
    };
    api.carryTake = async function (id) {
        if (!stash || !id) return null;
        try {
            const v = await stash.carryGet(id);
            if (v) await stash.carryDel(id);
            return v;
        } catch (_) { return null; }
    };
    api.carryDel = async function (id) {
        if (!stash || !id) return;
        try { await stash.carryDel(id); } catch (_) { }
    };
    const dropDbs = async (names) => {
        for (const name of names) { try { indexedDB.deleteDatabase(name); } catch (_) { } }
    };
    api.maintain = function () {
        if (!stash) return Promise.resolve();
        return Promise.resolve(locked(async () => {
            if (api.frozen) return;
            try { await migrateLegacy(raw, stash); } catch (_) { }
            try { await sweep(raw, stash, { active: !!(navigator.locks && navigator.locks.request) }); } catch (_) { }
            let drop = [];
            try { drop = JSON.parse(raw.getItem(DROP_KEY) || '[]'); } catch (_) { drop = []; }
            if (Array.isArray(drop) && drop.length) {
                const live = new Set([api.pageDb(CACHE_DB)]);
                await dropDbs(drop.map(String).filter((n) => !live.has(n)));
                try { raw.removeItem(DROP_KEY); } catch (_) { }
            }
        })).catch(() => { });
    };
    window.addEventListener('storage', (e) => {
        if (api.frozen) return;
        if (e.storageArea && e.storageArea !== ls) return;
        if (e.key !== null && e.key !== INDEX_KEY) return;
        const idx = e.key === null ? null : parseIndex(e.newValue);
        if (idx && !idx.journal && idx.active === api.pageId) return;
        let now = null;
        try { now = parseIndex(ls.getItem(INDEX_KEY)); } catch (_) { now = null; }
        if (idx && now && !now.journal && now.active === api.pageId) return;
        if (!idx && e.key !== null && e.newValue === null && !api.pageId) return;
        api.frozenByOther = true;
        api.freeze(1500);
    });
    if (booted.recovering && stash) {
        api.freeze();
        api.recovering = true;
        let tries = 0;
        try { tries = Number(sessionStorage.getItem('nymacct:recover')) || 0; } catch (_) { tries = 0; }
        const finish = () => {
            try { sessionStorage.clear(); } catch (_) { }
            try { sessionStorage.setItem('nymacct:recover', String(tries + 1)); } catch (_) { }
            try { location.reload(); } catch (_) { }
        };
        if (tries >= 2) {
            try {
                const idx = parseIndex(raw.getItem(INDEX_KEY));
                if (idx) raw.setItem(INDEX_KEY, JSON.stringify(Object.assign(idx, { journal: null })));
            } catch (_) { }
            finish();
        } else {
            Promise.resolve(locked(() => recover(raw, stash))).then(finish, finish);
        }
    } else {
        if (booted.recovering) {
            try {
                const idx = parseIndex(raw.getItem(INDEX_KEY));
                if (idx && idx.journal && !idx.journal.store) runEffects(raw, idx.journal.effects);
                if (idx) raw.setItem(INDEX_KEY, JSON.stringify(Object.assign(idx, { journal: null })));
                try { sessionStorage.clear(); } catch (_) { }
            } catch (_) { }
        }
        try { sessionStorage.removeItem('nymacct:recover'); } catch (_) { }
        api.recovering = false;
        setTimeout(() => { api.maintain(); }, 1500);
    }
})();
