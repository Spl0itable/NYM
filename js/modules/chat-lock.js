(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const LIMITS = Object.freeze({
        lockMax: 100,
        removedMax: 300,
        removedTtlMs: 180 * 24 * 60 * 60 * 1000,
        codeMin: 4,
        codeMax: 32,
        passcodeMin: 4,
        passcodeMax: 64,
        passcodeIterations: 150000,
        attemptsFree: 5,
        attemptsWaitSec: 30,
        attemptsMaxDoublings: 5,
        relockChoices: [0, 1, 5, 15, 60],
        relockDefault: 1,
    });

    const KEYS = Object.freeze({
        lockedDTag: 'nymchat-locked',
        locked: 'nym_locked_chats',
        lockedPending: 'nym_locked_pending',
        relock: 'nym_chat_lock_relock',
        passcode: 'nym_chat_lock_passcode',
        credential: 'nym_chat_lock_cred',
        attempts: 'nym_chat_lock_attempts',
        screenSecurity: 'nym_screen_security',
        incognitoKeyboard: 'nym_incognito_keyboard',
    });

    const STRINGS = Object.freeze({
        lockChat: 'Lock chat',
        unlockChat: 'Remove chat lock',
        lockedChats: 'Locked chats',
        lockedEmpty: 'No locked chats',
        lockedCount: '{n} unread',
        unlockTitle: 'Unlock locked chats',
        unlockBody: 'Use your device unlock to open locked chats.',
        unlockPasscodeBody: 'Enter your passcode to open locked chats.',
        unlockVaultBody: 'Enter your identity password or PIN to open locked chats.',
        unlock: 'Unlock',
        usePasscode: 'Use passcode',
        useDevice: 'Use device unlock',
        passcode: 'Passcode',
        passcodeConfirm: 'Confirm passcode',
        passcodeWrong: 'Wrong passcode.',
        passcodeWait: 'Too many tries. Wait {n} seconds.',
        passcodeShort: 'Use at least {n} characters.',
        passcodeMismatch: "Passcodes don't match.",
        setupTitle: 'Set a chat lock passcode',
        setupBody: 'This device has no biometric or passkey unlock, so locked chats use a passcode you set here. It stays on this device.',
        deviceFailed: 'Device unlock failed.',
        deviceReason: 'Unlock your locked chats',
        notifTitle: 'Nymchat',
        notifBody: 'New message',
        locked: 'Chat locked. Find it in Locked chats.',
        unlocked: 'Chat lock removed.',
        lockCap: 'You can lock up to {n} chats.',
        defaultLocked: '#nymchat cannot be locked',
        settingsTitle: 'Chat Lock',
        settingsButton: 'Chat lock settings…',
        settingsHint: 'Locked chats leave the main list and open only after Face ID, fingerprint, a passkey or your passcode. Their notifications say only "New message". The list of locked chats syncs to your other devices; each device unlocks on its own.',
        hideEntry: 'Hide the Locked chats entry',
        hideEntryHint: 'Open locked chats by typing your secret code in a sidebar search.',
        secretCode: 'Secret code',
        codeBad: 'Use {min} to {max} characters for the secret code.',
        relockAfter: 'Lock again after leaving the app',
        relockNow: 'Immediately',
        relockOne: 'After 1 minute',
        relockMany: 'After {n} minutes',
        relockHour: 'After 1 hour',
        lockNow: 'Lock now',
        resetPasscode: 'Change passcode',
        screenSecurity: 'Screen Security',
        screenSecurityAndroid: 'Hide chats in the app switcher and block screenshots and screen recording. Always on inside locked chats and view-once media.',
        screenSecurityIos: 'Hide chats in the app switcher and cover them while the screen is recorded or mirrored. iOS does not let apps block screenshots. Always on inside locked chats and view-once media.',
        screenSecurityWeb: 'Blur chats when you switch away from Nymchat. Browsers do not let websites block screenshots or screen recording. Always on inside locked chats and view-once media.',
        screenSecurityDesktop: 'Hide chats while Nymchat is in the background. This system does not let apps block screenshots. Always on inside locked chats and view-once media.',
        incognitoKeyboard: 'Incognito Keyboard',
        incognitoAndroid: 'Ask the keyboard not to learn from what you type, and turn off suggestions and autocorrect in message boxes.',
        incognitoWeb: "Turn off autocomplete, autocorrect and spell check in message boxes. The browser can't ask your keyboard app to stop learning; only Android keyboards support that.",
        incognitoOnlyAndroid: 'Only Android keyboards support this.',
        enabled: 'Enabled',
        disabled: 'Disabled',
        hidden: 'Content hidden',
        captured: 'Screen recording detected. Chats are hidden.',
    });

    const RX_HEX64 = /^[0-9a-f]{64}$/;
    const RX_GROUP = /^[0-9a-f]{16,64}$/;
    const RX_CHANNEL = /^[\p{L}\p{N}]{1,64}$/u;

    function num(v) {
        const n = Number(v);
        return isFinite(n) ? n : 0;
    }

    function cmpStr(a, b) {
        return a < b ? -1 : a > b ? 1 : 0;
    }

    function fill(s, vars) {
        let out = String(s);
        if (vars) for (const k of Object.keys(vars)) out = out.split('{' + k + '}').join(String(vars[k]));
        return out;
    }

    function lockKey(kind, id) {
        const raw = String(id == null ? '' : id).trim();
        if (kind === 'dm') {
            const pk = raw.toLowerCase();
            return RX_HEX64.test(pk) ? 'd:' + pk : '';
        }
        if (kind === 'group') {
            const g = raw.toLowerCase();
            return RX_GROUP.test(g) ? 'g:' + g : '';
        }
        if (kind === 'channel') {
            const c = raw.replace(/^#/, '').toLowerCase();
            return RX_CHANNEL.test(c) ? 'c:' + c : '';
        }
        return '';
    }

    function lockParse(k) {
        const s = String(k || '');
        if (s.indexOf('d:') === 0 && RX_HEX64.test(s.slice(2))) return { kind: 'dm', id: s.slice(2) };
        if (s.indexOf('g:') === 0 && RX_GROUP.test(s.slice(2))) return { kind: 'group', id: s.slice(2) };
        if (s.indexOf('c:') === 0 && RX_CHANNEL.test(s.slice(2))) return { kind: 'channel', id: s.slice(2) };
        return null;
    }

    const chatLockKeyMemo = new Map();

    function lockKeyForChat(chatKey, selfPubkey) {
        const memoKey = String(selfPubkey || '') + '|' + String(chatKey || '');
        const hit = chatLockKeyMemo.get(memoKey);
        if (hit !== undefined) return hit;
        const out = lockKeyForChatUncached(chatKey, selfPubkey);
        if (chatLockKeyMemo.size >= 5000) chatLockKeyMemo.clear();
        chatLockKeyMemo.set(memoKey, out);
        return out;
    }

    function lockKeyForChatUncached(chatKey, selfPubkey) {
        const k = String(chatKey || '');
        if (k.indexOf('pm-') === 0) {
            const parts = k.slice(3).toLowerCase().split('-').filter(Boolean);
            const self = String(selfPubkey || '').toLowerCase();
            const peer = parts.length > 1 ? (parts.find((p) => p !== self) || parts[0]) : parts[0];
            return lockKey('dm', peer);
        }
        if (k.indexOf('group-') === 0) return lockKey('group', k.slice(6));
        return lockKey('channel', k);
    }

    function normCode(code) {
        return String(code == null ? '' : code).trim().toLowerCase();
    }

    function emptyLocks() {
        return { v: 1, items: {}, removed: {}, hide: { on: false, code: '', at: 0 } };
    }

    function normalizeHide(raw) {
        const out = { on: false, code: '', at: 0 };
        if (!raw || typeof raw !== 'object') return out;
        const code = normCode(raw.code);
        out.code = code.length >= LIMITS.codeMin && code.length <= LIMITS.codeMax ? code : '';
        out.on = raw.on === true && !!out.code;
        out.at = Math.max(0, Math.floor(num(raw.at)));
        return out;
    }

    function normalizeLocks(raw) {
        const out = emptyLocks();
        if (!raw || typeof raw !== 'object') return out;
        for (const f of ['items', 'removed']) {
            const src = raw[f];
            if (!src || typeof src !== 'object' || Array.isArray(src)) continue;
            for (const [k, v] of Object.entries(src)) {
                const at = Math.floor(num(v));
                if (lockParse(k) && at > 0) out[f][k] = at;
            }
        }
        out.hide = normalizeHide(raw.hide);
        return finishLocks(out, 0);
    }

    function finishLocks(s, nowMs) {
        const items = {};
        for (const [k, at] of Object.entries(s.items)) if (!(s.removed[k] >= at)) items[k] = at;
        const keys = Object.keys(items).sort((a, b) => (items[b] - items[a]) || cmpStr(a, b));
        if (keys.length > LIMITS.lockMax) for (const k of keys.slice(LIMITS.lockMax)) delete items[k];
        const removed = {};
        const cutoff = num(nowMs) > 0 ? num(nowMs) - LIMITS.removedTtlMs : 0;
        for (const [k, at] of Object.entries(s.removed)) {
            if (items[k] !== undefined) continue;
            if (cutoff > 0 && at < cutoff) continue;
            removed[k] = at;
        }
        const rk = Object.keys(removed);
        if (rk.length > LIMITS.removedMax) {
            rk.sort((a, b) => (removed[b] - removed[a]) || cmpStr(a, b));
            for (const k of rk.slice(LIMITS.removedMax)) delete removed[k];
        }
        return { v: 1, items: sortObj(items), removed: sortObj(removed), hide: Object.assign({}, s.hide) };
    }

    function sortObj(o) {
        const out = {};
        for (const k of Object.keys(o).sort()) out[k] = o[k];
        return out;
    }

    function lockList(state) {
        const s = normalizeLocks(state);
        return Object.keys(s.items).sort((a, b) => (s.items[b] - s.items[a]) || cmpStr(a, b));
    }

    function isLocked(state, k) {
        if (!k) return false;
        const s = state && state.items ? state : normalizeLocks(state);
        const at = s.items[k];
        return at !== undefined && !(s.removed[k] >= at);
    }

    function lockAdd(state, k, nowMs) {
        const s = normalizeLocks(state);
        const p = lockParse(k);
        if (!p) return { state: s, error: 'invalid' };
        if (k === 'c:nymchat') return { state: s, error: 'default' };
        if (isLocked(s, k)) return { state: s, error: null };
        if (Object.keys(s.items).length >= LIMITS.lockMax) return { state: s, error: 'cap' };
        s.items[k] = Math.max(Math.floor(num(nowMs)), (s.removed[k] || 0) + 1, (s.items[k] || 0) + 1);
        delete s.removed[k];
        return { state: finishLocks(s, nowMs), error: null };
    }

    function lockRemove(state, k, nowMs) {
        const s = normalizeLocks(state);
        if (!isLocked(s, k)) return s;
        s.removed[k] = Math.max(Math.floor(num(nowMs)), (s.items[k] || 0) + 1);
        delete s.items[k];
        return finishLocks(s, nowMs);
    }

    function setHidden(state, on, code, nowMs) {
        const s = normalizeLocks(state);
        const c = normCode(code == null ? s.hide.code : code);
        if (on && (c.length < LIMITS.codeMin || c.length > LIMITS.codeMax)) return { state: s, error: 'code' };
        s.hide = { on: !!on, code: on ? c : (c.length >= LIMITS.codeMin && c.length <= LIMITS.codeMax ? c : ''), at: Math.max(Math.floor(num(nowMs)), s.hide.at + 1) };
        return { state: finishLocks(s, nowMs), error: null };
    }

    function mergeLocks(a, b, nowMs) {
        const x = normalizeLocks(a);
        const y = normalizeLocks(b);
        const items = Object.assign({}, x.items);
        for (const [k, at] of Object.entries(y.items)) if (!(items[k] >= at)) items[k] = at;
        const removed = Object.assign({}, x.removed);
        for (const [k, at] of Object.entries(y.removed)) if (!(removed[k] >= at)) removed[k] = at;
        let hide = x.hide;
        if (y.hide.at > x.hide.at || (y.hide.at === x.hide.at && JSON.stringify(y.hide) > JSON.stringify(x.hide))) hide = y.hide;
        return finishLocks({ v: 1, items, removed, hide: Object.assign({}, hide) }, nowMs);
    }

    function trimLockedPayload(p) {
        const s = p && p.lockedChats;
        if (!s || typeof s !== 'object') return false;
        const rk = s.removed ? Object.keys(s.removed) : [];
        if (rk.length > 20) {
            rk.sort((a, b) => (s.removed[a] - s.removed[b]) || cmpStr(a, b));
            for (const k of rk.slice(0, Math.ceil(rk.length / 4))) delete s.removed[k];
            return true;
        }
        const ik = s.items ? Object.keys(s.items) : [];
        if (ik.length > 20) {
            ik.sort((a, b) => (s.items[a] - s.items[b]) || cmpStr(a, b));
            for (const k of ik.slice(0, Math.ceil(ik.length / 4))) delete s.items[k];
            return true;
        }
        return false;
    }

    function secretMatches(state, term) {
        const s = normalizeLocks(state);
        return s.hide.on && !!s.hide.code && normCode(term) === s.hide.code;
    }

    function entryVisible(state, revealed) {
        const s = normalizeLocks(state);
        if (!Object.keys(s.items).length) return false;
        return !s.hide.on || !!revealed;
    }

    function partition(chatKeys, state, selfPubkey) {
        const s = normalizeLocks(state);
        const visible = [];
        const locked = [];
        for (const k of (Array.isArray(chatKeys) ? chatKeys : [])) {
            if (isLocked(s, lockKeyForChat(k, selfPubkey))) locked.push(k);
            else visible.push(k);
        }
        return { visible, locked };
    }

    function badges(entries, state, selfPubkey, revealed) {
        const s = normalizeLocks(state);
        let main = 0;
        let locked = 0;
        for (const e of (Array.isArray(entries) ? entries : [])) {
            const n = Math.max(0, Math.floor(num(e && e.n)));
            if (!n) continue;
            if (isLocked(s, lockKeyForChat(e.key, selfPubkey))) locked += n;
            else main += n;
        }
        const shown = s.hide.on && !revealed ? 0 : locked;
        return { main, locked, shown };
    }

    function notificationLockKeys(type, route, sender) {
        const t = String(type || '');
        const r = String(route == null ? '' : route);
        const out = [];
        const add = (k) => { if (k && out.indexOf(k) < 0) out.push(k); };
        const isPk = RX_HEX64.test(r.toLowerCase());
        if (t === 'pm') {
            add(lockKey('dm', r));
            add(lockKey('dm', sender));
        } else if (t === 'group') {
            add(lockKey('group', r));
        } else if (t === 'channel' || t === 'geohash') {
            add(lockKey('channel', r));
        } else if (t === 'mention') {
            add(isPk ? lockKey('dm', r) : lockKey('channel', r));
        } else if (t === 'call') {
            add(isPk ? lockKey('dm', r) : lockKey('group', r));
            if (!r) add(lockKey('dm', sender));
        } else {
            if (isPk) add(lockKey('dm', r));
            else {
                add(lockKey('group', r));
                add(lockKey('channel', r));
            }
        }
        return out;
    }

    function notificationLocked(state, type, route, sender) {
        const s = normalizeLocks(state);
        return notificationLockKeys(type, route, sender).some((k) => isLocked(s, k));
    }

    function notificationText(title, body, locked, t) {
        if (!locked) return { title: String(title == null ? '' : title), body: String(body == null ? '' : body), locked: false };
        const tr = typeof t === 'function' ? t : (x) => x;
        return { title: tr(STRINGS.notifTitle), body: tr(STRINGS.notifBody), locked: true };
    }

    function sessionIdle() {
        return { unlocked: false, at: 0, bg: 0 };
    }

    function sessionStep(st, ev) {
        const s = Object.assign(sessionIdle(), st || {});
        const e = ev || {};
        const relockMs = Math.max(0, num(e.relock)) * 60000;
        switch (e.t) {
            case 'unlock':
                return { unlocked: true, at: Math.floor(num(e.now)), bg: 0 };
            case 'leave':
            case 'lock':
                return sessionIdle();
            case 'background':
                if (!s.unlocked) return s;
                if (relockMs === 0) return sessionIdle();
                return { unlocked: true, at: s.at, bg: s.bg > 0 ? s.bg : Math.floor(num(e.now)) };
            case 'foreground':
                if (!s.unlocked) return s;
                if (s.bg > 0 && num(e.now) - s.bg >= relockMs) return sessionIdle();
                return { unlocked: true, at: s.at, bg: 0 };
            default:
                return s;
        }
    }

    function sessionAllows(st, state, chatKey, selfPubkey) {
        const k = lockKeyForChat(chatKey, selfPubkey);
        if (!isLocked(state, k)) return true;
        return !!(st && st.unlocked);
    }

    function leavesLocked(state, fromKey, toKey, selfPubkey) {
        const from = isLocked(state, lockKeyForChat(fromKey, selfPubkey));
        const to = isLocked(state, lockKeyForChat(toKey, selfPubkey));
        return from && !to;
    }

    function unlockFactor(opts) {
        const o = opts || {};
        if (o.device) return 'device';
        if (o.vault === 'password' || o.vault === 'pin') return 'vaultPasscode';
        if (o.passcode) return 'passcode';
        return 'setup';
    }

    function fallbackFactor(opts) {
        const o = opts || {};
        if (o.vault === 'password' || o.vault === 'pin') return 'vaultPasscode';
        if (o.passcode) return 'passcode';
        return null;
    }

    function attemptsIdle() {
        return { fails: 0, until: 0 };
    }

    function attemptStep(st, ok, nowMs) {
        const s = Object.assign(attemptsIdle(), st || {});
        if (ok) return attemptsIdle();
        const fails = s.fails + 1;
        const until = fails >= LIMITS.attemptsFree ? Math.floor(num(nowMs)) + LIMITS.attemptsWaitSec * 1000 * Math.pow(2, Math.min(fails - LIMITS.attemptsFree, LIMITS.attemptsMaxDoublings)) : 0;
        return { fails, until };
    }

    function attemptWait(st, nowMs) {
        const s = Object.assign(attemptsIdle(), st || {});
        const left = s.until - num(nowMs);
        return left > 0 ? Math.ceil(left / 1000) : 0;
    }

    function passcodeCheck(code, confirm) {
        const c = String(code == null ? '' : code);
        if (c.length < LIMITS.passcodeMin) return 'short';
        if (c.length > LIMITS.passcodeMax) return 'long';
        if (confirm !== undefined && confirm !== null && String(confirm) !== c) return 'mismatch';
        return null;
    }

    function passcodeError(code, t) {
        const tr = typeof t === 'function' ? t : (x) => x;
        if (code === 'short') return fill(tr(STRINGS.passcodeShort), { n: LIMITS.passcodeMin });
        if (code === 'long') return fill(tr(STRINGS.passcodeShort), { n: LIMITS.passcodeMin });
        if (code === 'mismatch') return tr(STRINGS.passcodeMismatch);
        if (code === 'wrong') return tr(STRINGS.passcodeWrong);
        return '';
    }

    function codeError(t) {
        const tr = typeof t === 'function' ? t : (x) => x;
        return fill(tr(STRINGS.codeBad), { min: LIMITS.codeMin, max: LIMITS.codeMax });
    }

    function relockOptions(t) {
        const tr = typeof t === 'function' ? t : (x) => x;
        return LIMITS.relockChoices.map((n) => ({
            value: n,
            label: n === 0 ? tr(STRINGS.relockNow) : n === 1 ? tr(STRINGS.relockOne) : n === 60 ? tr(STRINGS.relockHour) : fill(tr(STRINGS.relockMany), { n }),
        }));
    }

    function normalizeRelock(v) {
        if (v === null || v === undefined || String(v).trim() === '') return LIMITS.relockDefault;
        const n = Number(v);
        if (!isFinite(n) || Math.floor(n) !== n) return LIMITS.relockDefault;
        return LIMITS.relockChoices.indexOf(n) >= 0 ? n : LIMITS.relockDefault;
    }

    function obscureWanted(o) {
        const x = o || {};
        return !!(x.setting || x.lockedOpen || x.viewOnce);
    }

    function shieldStep(shielded, ev, wanted) {
        if (!wanted) return false;
        if (ev === 'hidden' || ev === 'blur' || ev === 'pagehide' || ev === 'freeze') return true;
        if (ev === 'visible' || ev === 'focus' || ev === 'pageshow' || ev === 'resume') return false;
        return !!shielded;
    }

    function screenSecurityHint(platform) {
        if (platform === 'android') return STRINGS.screenSecurityAndroid;
        if (platform === 'ios') return STRINGS.screenSecurityIos;
        if (platform === 'web') return STRINGS.screenSecurityWeb;
        return STRINGS.screenSecurityDesktop;
    }

    function incognitoSupport(platform) {
        if (platform === 'android') return { mode: 'keyboard', available: true, hint: STRINGS.incognitoAndroid };
        if (platform === 'web') return { mode: 'browser', available: true, hint: STRINGS.incognitoWeb };
        return { mode: 'none', available: false, hint: STRINGS.incognitoOnlyAndroid };
    }

    function inputAttrs(on) {
        if (!on) return {};
        return { autocomplete: 'off', autocorrect: 'off', autocapitalize: 'off', spellcheck: 'false' };
    }

    function textFieldFlags(on, platform) {
        const active = !!on && platform === 'android';
        return { imeLearning: !active, autocorrect: !active, suggestions: !active };
    }

    function b64(bytes) {
        let s = '';
        for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return (typeof btoa === 'function' ? btoa(s) : Buffer.from(s, 'binary').toString('base64'));
    }

    function b64d(str) {
        const s = typeof atob === 'function' ? atob(String(str || '')) : Buffer.from(String(str || ''), 'base64').toString('binary');
        const out = new Uint8Array(s.length);
        for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
        return out;
    }

    async function passcodeHash(code, salt, iterations) {
        const subtle = (G.crypto && G.crypto.subtle) || null;
        if (!subtle) throw new Error('no-crypto');
        const base = await subtle.importKey('raw', new TextEncoder().encode(String(code)), 'PBKDF2', false, ['deriveBits']);
        const bits = await subtle.deriveBits({ name: 'PBKDF2', salt, iterations: Math.max(1, Math.floor(num(iterations))), hash: 'SHA-256' }, base, 256);
        return b64(new Uint8Array(bits));
    }

    async function passcodeRecord(code, salt, iterations) {
        const it = Math.max(1, Math.floor(num(iterations) || LIMITS.passcodeIterations));
        const s = salt || G.crypto.getRandomValues(new Uint8Array(16));
        return { v: 1, it, salt: b64(s), hash: await passcodeHash(code, s, it) };
    }

    async function passcodeVerify(record, code) {
        if (!record || typeof record !== 'object' || !record.salt || !record.hash) return false;
        try {
            const h = await passcodeHash(code, b64d(record.salt), record.it || LIMITS.passcodeIterations);
            if (h.length !== record.hash.length) return false;
            let diff = 0;
            for (let i = 0; i < h.length; i++) diff |= h.charCodeAt(i) ^ record.hash.charCodeAt(i);
            return diff === 0;
        } catch (_) {
            return false;
        }
    }

    G.NymChatLock = {
        LIMITS, KEYS, STRINGS,
        lockKey, lockParse, lockKeyForChat, normCode,
        emptyLocks, normalizeLocks, lockList, isLocked, lockAdd, lockRemove, setHidden, mergeLocks, trimLockedPayload,
        secretMatches, entryVisible, partition, badges,
        notificationLockKeys, notificationLocked, notificationText,
        sessionIdle, sessionStep, sessionAllows, leavesLocked,
        unlockFactor, fallbackFactor, attemptsIdle, attemptStep, attemptWait,
        passcodeCheck, passcodeError, codeError, relockOptions, normalizeRelock,
        obscureWanted, shieldStep, screenSecurityHint, incognitoSupport, inputAttrs, textFieldFlags,
        passcodeHash, passcodeRecord, passcodeVerify, b64, b64d,
    };
})();
