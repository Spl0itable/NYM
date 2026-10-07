(function () {
    'use strict';

    const FORMAT = 'nym-key-backup-v1';
    const CONTEXTS = { google: 'nym-google-backup', apple: 'nym-apple-backup' };
    const ITERATIONS = 600000;
    const DRIVE_SCOPE = 'https://www.googleapis.com/auth/drive.appdata';
    const SCOPES = 'openid ' + DRIVE_SCOPE;
    const GSI_URL = 'https://accounts.google.com/gsi/client';
    const USERINFO_URL = 'https://www.googleapis.com/oauth2/v3/userinfo';
    const FILES_URL = 'https://www.googleapis.com/drive/v3/files';
    const UPLOAD_URL = 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart';
    const NAME_RE = /^nym_bk_[0-9a-f-]{36}\.bin$/;
    const LIMIT_KEY = 'nym_key_backup_failures';
    const MAX_DELAY_S = 300;
    const CLOUDKIT = {
        SCRIPT_URL: 'https://cdn.apple-cloudkit.com/ck/2/cloudkit.js',
        CONTAINER: 'iCloud.com.nym.bar',
        ENVIRONMENT: 'production',
        RECORD_TYPE: 'KeyBackup',
        FIELDS: ['payload', 'format', 'updatedAt'],
        SORT_BY: { fieldName: 'updatedAt', ascending: false },
        NAME_RE: /^nymbk-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
        BUTTON_ID: 'apple-sign-in-button',
        MAX_PAGES: 20,
    };

    const enc = new TextEncoder();

    class BackupError extends Error {
        constructor(code, detail) {
            super(detail ? code + ': ' + detail : code);
            this.code = code;
        }
    }

    function toHex(bytes) {
        let s = '';
        for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, '0');
        return s;
    }

    function fromHex(hex) {
        const out = new Uint8Array(hex.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
        return out;
    }

    function wipe(bytes) {
        if (bytes && typeof bytes.fill === 'function') bytes.fill(0);
    }

    function validPin(pin) {
        return typeof pin === 'string' && /^[0-9]{4,8}$/.test(pin);
    }

    function nip44() {
        const tools = window.NostrTools;
        if (!tools || !tools.nip44 || !tools.nip44.v2) throw new BackupError('crypto');
        return tools.nip44.v2;
    }

    async function backupSalt(context, accountId) {
        if (typeof accountId !== 'string' || !accountId) throw new BackupError('account');
        const k = await crypto.subtle.importKey('raw', enc.encode(context), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
        return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(accountId)));
    }

    async function deriveBackupKey(pin, salt) {
        if (!validPin(pin)) throw new BackupError('pin');
        const base = await crypto.subtle.importKey('raw', enc.encode(pin), 'PBKDF2', false, ['deriveBits']);
        const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: ITERATIONS }, base, 256);
        return new Uint8Array(bits);
    }

    function bundleText(skHex, pq) {
        const out = { v: 1, sk: skHex };
        if (typeof pq === 'string' && pq) out.pq = pq;
        return JSON.stringify(out);
    }

    function parseBundle(text) {
        if (typeof text !== 'string') return null;
        if (/^[0-9a-f]{64}$/.test(text)) return { skHex: text, pq: null };
        let obj;
        try { obj = JSON.parse(text); } catch (_) { return null; }
        if (!obj || typeof obj !== 'object' || Array.isArray(obj) || obj.v !== 1) return null;
        if (typeof obj.sk !== 'string' || !/^[0-9a-f]{64}$/.test(obj.sk)) return null;
        return { skHex: obj.sk, pq: obj.pq === undefined || obj.pq === null ? null : obj.pq };
    }

    function validPq(code) {
        if (typeof code !== 'string' || !code) return false;
        const NC = window.NymCrypto;
        if (!NC || typeof NC.pqRootDecode !== 'function') return false;
        try { NC.pqRootDecode(code); return true; } catch (_) { return false; }
    }

    function checkPq(pq) {
        if (pq === null || pq === undefined) return { pq: null, pqBad: false };
        return validPq(pq) ? { pq, pqBad: false } : { pq: null, pqBad: true };
    }

    function currentPq() {
        try {
            const n = window.nym;
            const code = n && typeof n.pqRootCode === 'function' ? n.pqRootCode() : null;
            return validPq(code) ? code : null;
        } catch (_) { return null; }
    }

    function newPqCode() {
        try {
            const NC = window.NymCrypto;
            if (!NC || typeof NC.pqGenerateRoot !== 'function' || typeof NC.pqRootEncode !== 'function') return null;
            if (typeof NC.pqAvailable === 'function' && !NC.pqAvailable()) return null;
            const code = NC.pqRootEncode(NC.pqGenerateRoot());
            return validPq(code) ? code : null;
        } catch (_) { return null; }
    }

    function encryptBundle(secretKey, pq, key, nonce) {
        if (!(secretKey && secretKey.length === 32)) throw new BackupError('secret');
        return nip44().encrypt(bundleText(toHex(secretKey), pq), key, nonce);
    }

    function decryptBundle(payload, key) {
        let text;
        try { text = nip44().decrypt(String(payload || '').trim(), key); } catch (_) { return null; }
        const b = parseBundle(text);
        if (!b) return null;
        return { secret: fromHex(b.skHex), pq: b.pq };
    }

    function decryptSecret(payload, key) {
        const b = decryptBundle(payload, key);
        return b ? b.secret : null;
    }

    function pubkeyOf(secretKey) {
        try { return window.NostrTools.getPublicKey(secretKey); } catch (_) { return null; }
    }

    function newUuid() {
        let id;
        if (crypto.randomUUID) {
            id = crypto.randomUUID();
        } else {
            const b = crypto.getRandomValues(new Uint8Array(16));
            b[6] = (b[6] & 0x0f) | 0x40;
            b[8] = (b[8] & 0x3f) | 0x80;
            const h = toHex(b);
            id = h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
        }
        return id.toLowerCase();
    }

    function newFileName() {
        return 'nym_bk_' + newUuid() + '.bin';
    }

    function newRecordName() {
        return 'nymbk-' + newUuid();
    }

    function appleFirst(nav) {
        const n = nav || globalThis.navigator || {};
        const data = n.userAgentData;
        if (data && typeof data.platform === 'string' && data.platform) return /^(macOS|iOS)$/i.test(data.platform);
        const ua = String(n.userAgent || '');
        if (/iPhone|iPad|iPod/.test(ua)) return true;
        if (/Macintosh/.test(ua) && Number(n.maxTouchPoints) > 1) return true;
        return /Macintosh/.test(ua);
    }

    function createGoogleAuth(opts) {
        const clientId = opts.clientId;
        const fetchFn = opts.fetch || ((u, i) => window.fetch(u, i));
        const loadScript = opts.loadScript || ((u) => window.loadScriptOnce(u));
        let token = null;
        let sub = null;

        async function loadGsi() {
            try { await loadScript(GSI_URL); } catch (_) { throw new BackupError('gsi'); }
            const g = window.google;
            if (!g || !g.accounts || !g.accounts.oauth2 || typeof g.accounts.oauth2.initTokenClient !== 'function') {
                throw new BackupError('gsi');
            }
            return g.accounts.oauth2;
        }

        async function requestToken() {
            const oauth2 = await loadGsi();
            return new Promise((resolve, reject) => {
                const client = oauth2.initTokenClient({
                    client_id: clientId,
                    scope: SCOPES,
                    callback: (resp) => {
                        if (!resp || resp.error || !resp.access_token) {
                            reject(new BackupError(resp && resp.error === 'access_denied' ? 'cancelled' : 'auth'));
                            return;
                        }
                        const granted = String(resp.scope || '').split(/\s+/);
                        if (!granted.includes(DRIVE_SCOPE)) { reject(new BackupError('scope')); return; }
                        resolve(resp.access_token);
                    },
                    error_callback: (err) => {
                        const type = err && err.type;
                        reject(new BackupError(type === 'popup_closed' ? 'cancelled' : type === 'popup_failed_to_open' ? 'popup' : 'auth'));
                    },
                });
                client.requestAccessToken({ prompt: '' });
            });
        }

        async function getToken(refresh) {
            if (!token || refresh) token = await requestToken();
            return token;
        }

        async function call(url, init) {
            init = init || {};
            for (let attempt = 0; attempt < 2; attempt++) {
                const t = await getToken(attempt > 0);
                let res;
                try {
                    res = await fetchFn(url, Object.assign({}, init, {
                        headers: Object.assign({}, init.headers || {}, { Authorization: 'Bearer ' + t }),
                    }));
                } catch (_) {
                    throw new BackupError('network');
                }
                if (res.status === 401) { token = null; continue; }
                if (!res.ok) throw new BackupError('drive', String(res.status));
                return res;
            }
            throw new BackupError('auth');
        }

        async function accountId() {
            if (sub) return sub;
            const res = await call(USERINFO_URL);
            const info = await res.json();
            if (!info || typeof info.sub !== 'string' || !info.sub) throw new BackupError('auth');
            sub = info.sub;
            return sub;
        }

        function signOut() {
            const g = window.google;
            if (token && g && g.accounts && g.accounts.oauth2 && typeof g.accounts.oauth2.revoke === 'function') {
                try { g.accounts.oauth2.revoke(token, () => { }); } catch (_) { }
            }
            token = null;
            sub = null;
        }

        return { call, accountId, signOut, getToken };
    }

    function createDrive(auth) {
        async function list() {
            const q = new URLSearchParams({
                spaces: 'appDataFolder',
                q: "name contains 'nym_bk_'",
                fields: 'files(id,name,modifiedTime)',
                pageSize: '100',
            });
            const res = await auth.call(FILES_URL + '?' + q.toString());
            const body = await res.json();
            const files = body && Array.isArray(body.files) ? body.files : [];
            return files.filter((f) => f && typeof f.id === 'string' && NAME_RE.test(String(f.name || '')));
        }

        async function download(id) {
            const res = await auth.call(FILES_URL + '/' + encodeURIComponent(id) + '?alt=media');
            return (await res.text()).trim();
        }

        async function upload(payload) {
            const boundary = 'nymbk' + toHex(crypto.getRandomValues(new Uint8Array(12)));
            const meta = { name: newFileName(), parents: ['appDataFolder'] };
            const body =
                '--' + boundary + '\r\n' +
                'Content-Type: application/json; charset=UTF-8\r\n\r\n' +
                JSON.stringify(meta) + '\r\n' +
                '--' + boundary + '\r\n' +
                'Content-Type: application/octet-stream\r\n\r\n' +
                payload + '\r\n' +
                '--' + boundary + '--';
            const res = await auth.call(UPLOAD_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'multipart/related; boundary=' + boundary },
                body,
            });
            const out = await res.json().catch(() => ({}));
            return { id: out && out.id, name: meta.name };
        }

        async function remove(id) {
            await auth.call(FILES_URL + '/' + encodeURIComponent(id), { method: 'DELETE' });
        }

        return { list, download, upload, remove };
    }

    function cloudKitError(e) {
        if (e instanceof BackupError) return e;
        const code = e && e.ckErrorCode;
        if (code === 'AUTHENTICATION_REQUIRED' || code === 'AUTHENTICATION_FAILED' || code === 'ACCESS_DENIED') return new BackupError('auth', code);
        if (code === 'NETWORK_ERROR' || code === 'SERVICE_UNAVAILABLE' || code === 'TRY_AGAIN_LATER' || code === 'THROTTLED') return new BackupError('network', code);
        if (code === 'QUOTA_EXCEEDED') return new BackupError('quota');
        return new BackupError('icloud', code || '');
    }

    function createCloudKitAuth(opts) {
        const ui = opts.ui;
        const containerIdentifier = opts.containerIdentifier || CLOUDKIT.CONTAINER;
        const apiToken = opts.apiToken;
        const environment = opts.environment || CLOUDKIT.ENVIRONMENT;
        const loadScript = opts.loadScript || ((u) => window.loadScriptOnce(u));
        let container = null;
        let recordName = null;

        async function open() {
            if (container) return container;
            try { await loadScript(CLOUDKIT.SCRIPT_URL); } catch (_) { throw new BackupError('ckjs'); }
            const CK = window.CloudKit;
            if (!CK || typeof CK.configure !== 'function') throw new BackupError('ckjs');
            try {
                CK.configure({
                    containers: [{
                        containerIdentifier,
                        apiTokenAuth: { apiToken, persist: false, signInButton: { id: CLOUDKIT.BUTTON_ID, theme: 'black' } },
                        environment,
                    }],
                });
                container = CK.getContainer(containerIdentifier);
            } catch (_) {
                container = null;
            }
            if (!container || typeof container.setUpAuth !== 'function') throw new BackupError('ckjs');
            return container;
        }

        async function accountId() {
            if (recordName) return recordName;
            const c = await open();
            let identity;
            try {
                identity = await ui.appleSignIn({
                    title: t(SA.signInTitle),
                    text: t(SA.signInText),
                    buttonId: CLOUDKIT.BUTTON_ID,
                    start: async () => (await c.setUpAuth()) || c.whenUserSignsIn(),
                });
            } catch (e) {
                throw cloudKitError(e);
            }
            if (identity == null) throw new BackupError('cancelled');
            const name = identity.userRecordName;
            if (typeof name !== 'string' || !name) throw new BackupError('auth');
            recordName = name;
            return name;
        }

        function database() {
            if (!container || !recordName) throw new BackupError('auth');
            return container.privateCloudDatabase;
        }

        function signOut() {
            const c = container;
            recordName = null;
            if (c && typeof c.signOut === 'function') {
                try { c.signOut(); } catch (_) { }
            }
        }

        return { accountId, database, signOut };
    }

    function createCloudKitStore(auth) {
        const cache = new Map();

        async function run(op) {
            let res;
            try { res = await op(); } catch (e) { throw cloudKitError(e); }
            if (res && res.hasErrors) throw cloudKitError((res.errors && res.errors[0]) || null);
            return res;
        }

        function fieldValue(r, name) {
            const f = r && r.fields && r.fields[name];
            return f ? f.value : undefined;
        }

        async function list() {
            const db = auth.database();
            const out = [];
            cache.clear();
            let res = await run(() => db.performQuery(
                { recordType: CLOUDKIT.RECORD_TYPE, sortBy: [Object.assign({}, CLOUDKIT.SORT_BY)] },
                { desiredKeys: CLOUDKIT.FIELDS.slice() },
            ));
            for (let page = 1; ; page++) {
                for (const r of (res && res.records) || []) {
                    const payload = fieldValue(r, 'payload');
                    if (!r || typeof r.recordName !== 'string' || !CLOUDKIT.NAME_RE.test(r.recordName)) continue;
                    if (typeof payload !== 'string' || !payload) continue;
                    const at = Number(fieldValue(r, 'updatedAt'));
                    const modifiedTime = Number.isFinite(at) ? new Date(at).toISOString() : '';
                    cache.set(r.recordName, payload);
                    out.push({ id: r.recordName, modifiedTime, payload });
                }
                if (!(res && res.moreComing) || page >= CLOUDKIT.MAX_PAGES) break;
                const prev = res;
                res = await run(() => db.performQuery(prev));
            }
            return out;
        }

        async function download(id) {
            if (!cache.has(id)) throw new BackupError('icloud', 'missing');
            return cache.get(id);
        }

        async function upload(payload) {
            const db = auth.database();
            const recordName = newRecordName();
            await run(() => db.saveRecords([{
                recordType: CLOUDKIT.RECORD_TYPE,
                recordName,
                fields: {
                    payload: { value: payload },
                    format: { value: FORMAT },
                    updatedAt: { value: Date.now() },
                },
            }]));
            return { id: recordName, name: recordName };
        }

        async function remove(id) {
            const db = auth.database();
            await run(() => db.deleteRecords([{ recordName: id }]));
            cache.delete(id);
        }

        return { list, download, upload, remove };
    }

    async function loadBackups(drive) {
        const files = await drive.list();
        const out = [];
        for (const f of files) {
            try {
                out.push({ id: f.id, modifiedTime: f.modifiedTime || '', payload: typeof f.payload === 'string' ? f.payload : await drive.download(f.id) });
            } catch (e) {
                if (e && (e.code === 'auth' || e.code === 'network' || e.code === 'cancelled' || e.code === 'quota')) throw e;
            }
        }
        return out;
    }

    function matchBackups(backups, key) {
        const byPubkey = new Map();
        for (const b of backups) {
            const opened = decryptBundle(b.payload, key);
            if (!opened) continue;
            const secret = opened.secret;
            const pubkey = pubkeyOf(secret);
            if (!pubkey) { wipe(secret); continue; }
            const have = byPubkey.get(pubkey);
            if (have) {
                have.ids.push(b.id);
                if (b.modifiedTime > have.modifiedTime) {
                    have.modifiedTime = b.modifiedTime;
                    have.pq = opened.pq;
                }
                wipe(secret);
            } else {
                byPubkey.set(pubkey, { pubkey, secret, pq: opened.pq, ids: [b.id], modifiedTime: b.modifiedTime });
            }
        }
        return [...byPubkey.values()];
    }

    function createLimiter(opts) {
        opts = opts || {};
        const storage = opts.storage || (() => { try { return window.localStorage; } catch (_) { return null; } })();
        const now = opts.now || (() => Date.now());
        function read() {
            try {
                const v = JSON.parse((storage && storage.getItem(LIMIT_KEY)) || 'null');
                if (v && Number.isFinite(v.n) && Number.isFinite(v.at)) return v;
            } catch (_) { }
            return { n: 0, at: 0 };
        }
        function delayMs(n) {
            return n <= 0 ? 0 : Math.min(MAX_DELAY_S, Math.pow(2, n - 1)) * 1000;
        }
        return {
            waitMs() {
                const s = read();
                return Math.max(0, s.at + delayMs(s.n) - now());
            },
            fail() {
                const s = read();
                try { storage && storage.setItem(LIMIT_KEY, JSON.stringify({ n: s.n + 1, at: now() })); } catch (_) { }
            },
            reset() {
                try { storage && storage.removeItem(LIMIT_KEY); } catch (_) { }
            },
            delayMs,
        };
    }

    const S = {
        connecting: 'Connecting to Google…',
        checking: 'Checking your backups…',
        unlocking: 'Unlocking…',
        encrypting: 'Encrypting…',
        signingIn: 'Signing in…',
        removing: 'Removing backups…',
        unlockTitle: 'Unlock your backup',
        unlockText: 'Enter the PIN you chose when you backed up your key to Google.',
        createTitle: 'Choose a backup PIN',
        createText: 'Your key stays yours. Google only stores an encrypted copy, which it can\'t read without your PIN.',
        createWarning: 'Your PIN can\'t be recovered. If you forget it, the backup can\'t be opened. Anyone who has both your Google account and your PIN can get your key.',
        pinPlaceholder: 'PIN (4 to 8 digits)',
        pinAgainPlaceholder: 'Enter the PIN again',
        pinFormat: 'Use 4 to 8 digits.',
        pinMismatch: 'The PINs don\'t match.',
        wrongPin: 'Wrong PIN',
        waitOne: 'Too many attempts. Try again in a second.',
        wait: 'Too many attempts. Try again in {n} seconds.',
        unlock: 'Unlock',
        backUp: 'Back up',
        cancel: 'Cancel',
        ok: 'OK',
        pickTitle: 'Choose an identity',
        pickText: 'More than one key opened with this PIN. Choose the one to sign in with.',
        replaceTitle: 'Replace backup',
        replaceText: 'This key already has a backup in your Google account. Replace it with a new one protected by this PIN?',
        replace: 'Replace',
        backedUpTitle: 'Backed up',
        backedUpText: 'Your key is backed up to your Google account. To restore it on another device, choose Continue with Google and enter your PIN.',
        backedUpPqText: 'Your key and your post-quantum recovery code are backed up to your Google account. To restore them on another device, choose Continue with Google and enter your PIN.',
        removeTitle: 'Remove Google backups',
        removeText: 'Enter your backup PIN to find this key\'s backups.',
        removeNone: 'No backups of this key opened with that PIN.',
        removeEmpty: 'There are no Nymchat key backups in this Google account.',
        removeOne: 'Delete this key\'s backup from your Google account?',
        removeMany: 'Delete {n} backups of this key from your Google account?',
        remove: 'Delete',
        removedTitle: 'Backups removed',
        removedText: 'This key\'s backups were deleted from your Google account.',
        errorTitle: 'Google backup',
        errGsi: 'Couldn\'t load Google sign-in. Check your connection and try again.',
        errPopup: 'The Google sign-in window couldn\'t open. Allow pop-ups for this site and try again.',
        errAuth: 'Google sign-in failed or expired. Please try again.',
        errScope: 'Nymchat needs permission to keep its backup in your Google Drive. Please allow it and try again.',
        errNetwork: 'Couldn\'t reach Google Drive. Check your connection and try again.',
        errDrive: 'Google Drive returned an error. Please try again later.',
        errOther: 'Something went wrong with the Google backup. Please try again.',
        pqBadTitle: 'Recovery code not restored',
        pqBad: 'Your backup has a post-quantum recovery code that isn\'t valid, so it was skipped. You\'re signed in. To add the code, paste it in View or Edit Nym\'s Details.',
        pqMismatch: 'The post-quantum recovery code in your backup doesn\'t match this account, so it wasn\'t restored. You\'re signed in. To add the right code, paste it in View or Edit Nym\'s Details.',
    };

    const SA = Object.assign({}, S, {
        connecting: 'Connecting to Apple…',
        signInTitle: 'Sign in with Apple',
        signInText: 'Apple\'s sign-in opens in a new window. Your Apple Account password goes only to Apple, and Nymchat is told only an ID for your iCloud, never your email or name.',
        unlockText: 'Enter the PIN you chose when you backed up your key to Apple.',
        createText: 'Your key stays yours. Apple only stores an encrypted copy, which it can\'t read without your PIN.',
        createWarning: 'Your PIN can\'t be recovered. If you forget it, the backup can\'t be opened. Anyone who has both your Apple account and your PIN can get your key.',
        replaceText: 'This key already has a backup in your Apple account. Replace it with a new one protected by this PIN?',
        backedUpText: 'Your key is backed up to your Apple account. To restore it on another device, choose Continue with Apple and enter your PIN.',
        backedUpPqText: 'Your key and your post-quantum recovery code are backed up to your Apple account. To restore them on another device, choose Continue with Apple and enter your PIN.',
        removeTitle: 'Remove Apple backups',
        removeEmpty: 'There are no Nymchat key backups in this Apple account.',
        removeOne: 'Delete this key\'s backup from your Apple account?',
        removeMany: 'Delete {n} backups of this key from your Apple account?',
        removedText: 'This key\'s backups were deleted from your Apple account.',
        errorTitle: 'Apple backup',
        errLoad: 'Couldn\'t load Apple sign-in. Check your connection and try again.',
        errAuth: 'Apple sign-in failed or expired. Please try again.',
        errNetwork: 'Couldn\'t reach iCloud. Check your connection and try again.',
        errICloud: 'iCloud returned an error. Please try again later.',
        errQuota: 'Your iCloud storage is full. Free up space and try again.',
        errOther: 'Something went wrong with the Apple backup. Please try again.',
    });

    function stringsFor(provider) {
        return provider === 'apple' ? SA : S;
    }

    function t(s, vars) {
        if (!vars) return s;
        return s.replace(/\{(\w+)\}/g, (m, k) => (vars[k] != null ? String(vars[k]) : m));
    }

    function errorText(e, provider) {
        const code = e && e.code;
        if (provider === 'apple') {
            if (code === 'ckjs') return t(SA.errLoad);
            if (code === 'auth' || code === 'account') return t(SA.errAuth);
            if (code === 'network') return t(SA.errNetwork);
            if (code === 'quota') return t(SA.errQuota);
            if (code === 'icloud') return t(SA.errICloud);
            return t(SA.errOther);
        }
        if (code === 'gsi') return t(S.errGsi);
        if (code === 'popup') return t(S.errPopup);
        if (code === 'auth' || code === 'account') return t(S.errAuth);
        if (code === 'scope') return t(S.errScope);
        if (code === 'network') return t(S.errNetwork);
        if (code === 'drive') return t(S.errDrive);
        return t(S.errOther);
    }

    async function askPinChecked(ui, limiter, opts, error) {
        for (;;) {
            const wait = limiter.waitMs();
            const pin = await ui.askPin(Object.assign({}, opts, {
                error,
                waitText: wait <= 0 ? '' : wait <= 1000 ? t(S.waitOne) : t(S.wait, { n: Math.ceil(wait / 1000) }),
                waitMs: wait,
            }));
            if (pin == null) return null;
            if (limiter.waitMs() > 0) continue;
            if (!validPin(pin)) { error = t(S.pinFormat); continue; }
            return pin;
        }
    }

    function providerOf(ctx) {
        return ctx && ctx.provider === 'apple' ? 'apple' : 'google';
    }

    async function restoreFromBackups(ctx) {
        const { ui, limiter, accountId, backups, importKey } = ctx;
        const S = stringsFor(providerOf(ctx));
        const salt = await backupSalt(CONTEXTS[providerOf(ctx)], accountId);
        let error = '';
        for (;;) {
            const pin = await askPinChecked(ui, limiter, {
                mode: 'unlock', title: t(S.unlockTitle), text: t(S.unlockText), okLabel: t(S.unlock),
            }, error);
            if (pin == null) return false;
            ui.busy(t(S.unlocking));
            const key = await deriveBackupKey(pin, salt);
            let candidates;
            try { candidates = matchBackups(backups, key); } finally { wipe(key); }
            if (!candidates.length) {
                limiter.fail();
                error = t(S.wrongPin);
                continue;
            }
            limiter.reset();
            let chosen = candidates[0];
            if (candidates.length > 1) chosen = await ui.pick(candidates);
            for (const c of candidates) if (c !== chosen) wipe(c.secret);
            if (!chosen) return false;
            const hex = toHex(chosen.secret);
            wipe(chosen.secret);
            ui.busy(t(S.signingIn));
            await importKey(hex, checkPq(chosen.pq));
            return true;
        }
    }

    async function createAndBackUp(ctx) {
        const { ui, drive, accountId, importKey, newSecretKey } = ctx;
        const S = stringsFor(providerOf(ctx));
        const makePq = ctx.newPqCode || newPqCode;
        const pin = await ui.askPin({
            mode: 'create', title: t(S.createTitle), text: t(S.createText), warning: t(S.createWarning), okLabel: t(S.backUp),
        });
        if (pin == null || !validPin(pin)) return false;
        ui.busy(t(S.encrypting));
        const secret = newSecretKey();
        const pq = makePq();
        const key = await deriveBackupKey(pin, await backupSalt(CONTEXTS[providerOf(ctx)], accountId));
        let payload;
        try { payload = encryptBundle(secret, pq, key); } finally { wipe(key); }
        try {
            await drive.upload(payload);
        } catch (e) {
            wipe(secret);
            throw e;
        }
        const hex = toHex(secret);
        wipe(secret);
        ui.busy(t(S.signingIn));
        await importKey(hex, { pq, pqBad: false, fresh: true });
        return true;
    }

    async function continueWithGoogle(ctx) {
        const { ui, auth, drive } = ctx;
        const S = stringsFor(providerOf(ctx));
        ui.busy(t(S.connecting));
        const accountId = await auth.accountId();
        ui.busy(t(S.checking));
        const backups = await loadBackups(drive);
        const next = Object.assign({}, ctx, { accountId, backups });
        return backups.length ? restoreFromBackups(next) : createAndBackUp(next);
    }

    async function backUpKey(ctx) {
        const { ui, auth, drive, secretKey, pubkey } = ctx;
        const S = stringsFor(providerOf(ctx));
        const pq = validPq(ctx.pq) ? ctx.pq : null;
        try {
            ui.busy(t(S.connecting));
            const accountId = await auth.accountId();
            const pin = await ui.askPin({
                mode: 'create', title: t(S.createTitle), text: t(S.createText), warning: t(S.createWarning), okLabel: t(S.backUp),
            });
            if (pin == null || !validPin(pin)) return false;
            ui.busy(t(S.encrypting));
            const key = await deriveBackupKey(pin, await backupSalt(CONTEXTS[providerOf(ctx)], accountId));
            try {
                const backups = await loadBackups(drive);
                const same = matchBackups(backups, key).filter((c) => {
                    wipe(c.secret);
                    return c.pubkey === pubkey;
                });
                const oldIds = same.flatMap((c) => c.ids);
                if (oldIds.length) {
                    const ok = await ui.confirm({ title: t(S.replaceTitle), text: t(S.replaceText), okLabel: t(S.replace) });
                    if (!ok) return false;
                    ui.busy(t(S.encrypting));
                }
                await drive.upload(encryptBundle(secretKey, pq, key));
                for (const id of oldIds) await drive.remove(id);
            } finally {
                wipe(key);
            }
            await ui.notice({ title: t(S.backedUpTitle), text: t(pq ? S.backedUpPqText : S.backedUpText) });
            return true;
        } finally {
            wipe(secretKey);
        }
    }

    async function removeBackups(ctx) {
        const { ui, auth, drive, limiter, pubkey } = ctx;
        const S = stringsFor(providerOf(ctx));
        ui.busy(t(S.connecting));
        const accountId = await auth.accountId();
        ui.busy(t(S.checking));
        const backups = await loadBackups(drive);
        if (!backups.length) {
            await ui.notice({ title: t(S.removeTitle), text: t(S.removeEmpty) });
            return false;
        }
        const salt = await backupSalt(CONTEXTS[providerOf(ctx)], accountId);
        let error = '';
        for (;;) {
            const pin = await askPinChecked(ui, limiter, {
                mode: 'unlock', title: t(S.removeTitle), text: t(S.removeText), okLabel: t(S.unlock),
            }, error);
            if (pin == null) return false;
            ui.busy(t(S.unlocking));
            const key = await deriveBackupKey(pin, salt);
            let ids;
            try {
                ids = matchBackups(backups, key).filter((c) => {
                    wipe(c.secret);
                    return c.pubkey === pubkey;
                }).flatMap((c) => c.ids);
            } finally {
                wipe(key);
            }
            if (!ids.length) {
                limiter.fail();
                error = t(S.removeNone);
                continue;
            }
            limiter.reset();
            const ok = await ui.confirm({
                title: t(S.removeTitle),
                text: ids.length === 1 ? t(S.removeOne) : t(S.removeMany, { n: ids.length }),
                okLabel: t(S.remove),
                danger: true,
            });
            if (!ok) return false;
            ui.busy(t(S.removing));
            for (const id of ids) await drive.remove(id);
            await ui.notice({ title: t(S.removedTitle), text: t(S.removedText) });
            return true;
        }
    }

    function signedOutAfter(flow) {
        return async function (ctx) {
            const next = Object.assign({}, ctx, { provider: 'apple' });
            try {
                return await flow(next);
            } finally {
                try { if (ctx.auth && typeof ctx.auth.signOut === 'function') ctx.auth.signOut(); } catch (_) { }
            }
        };
    }

    const continueWithApple = signedOutAfter(continueWithGoogle);
    const appleBackUpKey = signedOutAfter(backUpKey);
    const appleRemoveBackups = signedOutAfter(removeBackups);

    function clientId() {
        try { return typeof GOOGLE_WEB_CLIENT_ID === 'string' ? GOOGLE_WEB_CLIENT_ID.trim() : ''; } catch (_) { return ''; }
    }

    function inNativeShell() {
        try { return typeof isNymchatApp === 'function' && isNymchatApp(); } catch (_) { return false; }
    }

    function enabled() {
        return !!clientId() && !inNativeShell() && !!(window.crypto && crypto.subtle);
    }

    function appleConfig() {
        const read = (f) => { try { const v = f(); return typeof v === 'string' ? v.trim() : ''; } catch (_) { return ''; } };
        return {
            containerIdentifier: read(() => APPLE_CLOUDKIT_CONTAINER),
            apiToken: read(() => APPLE_CLOUDKIT_API_TOKEN),
        };
    }

    function appleEnabled() {
        const c = appleConfig();
        return !!c.containerIdentifier && !!c.apiToken && !inNativeShell() && !!(window.crypto && crypto.subtle);
    }

    function hasLocalKey() {
        const n = window.nym;
        if (!n || !(n.privkey instanceof Uint8Array) || n.privkey.length !== 32) return false;
        return n.nostrLoginMethod !== 'extension' && n.nostrLoginMethod !== 'nip46';
    }

    function el(tag, cls, text) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text != null) e.textContent = text;
        return e;
    }

    function shortNpub(pubkey) {
        let npub = pubkey;
        try { npub = window.NostrTools.nip19.npubEncode(pubkey); } catch (_) { }
        return npub.slice(0, 12) + '…' + npub.slice(-6);
    }

    function localize(root) {
        try {
            const n = window.nym;
            if (n && typeof n.i18nApplyNow === 'function') n.i18nApplyNow(root);
        } catch (_) { }
    }

    function createOverlayUi(defaultTitle) {
        const ov = el('div', 'modal active nm-kb-overlay');
        ov.setAttribute('role', 'dialog');
        ov.setAttribute('aria-modal', 'true');
        const box = el('div', 'modal-content nm-vault-box');
        ov.appendChild(box);
        document.body.appendChild(ov);
        let pending = null;
        let timer = null;
        let title = defaultTitle || t(S.errorTitle);

        function settle(value) {
            if (timer) { clearTimeout(timer); timer = null; }
            const p = pending;
            pending = null;
            if (p) p(value);
        }

        function render(heading, parts, buttons) {
            if (heading) title = heading;
            box.textContent = '';
            box.appendChild(el('div', 'modal-header', title));
            const body = el('div', 'modal-body');
            for (const p of parts) if (p) body.appendChild(p);
            box.appendChild(body);
            if (buttons && buttons.length) {
                const actions = el('div', 'modal-actions');
                for (const b of buttons) actions.appendChild(b);
                box.appendChild(actions);
            }
            localize(box);
        }

        function button(label, cls, onClick) {
            const b = el('button', cls, label);
            b.type = 'button';
            b.onclick = onClick;
            return b;
        }

        function ask(fn) {
            settle(null);
            return new Promise((resolve) => { pending = resolve; fn(); });
        }

        return {
            busy(text) {
                settle(null);
                const line = el('p', 'form-hint nm-vault-text');
                line.appendChild(el('span', 'loader'));
                line.appendChild(document.createTextNode(' ' + text));
                render(null, [line], []);
            },
            askPin(opts) {
                return ask(() => {
                    const create = opts.mode === 'create';
                    const pinInput = () => {
                        const i = el('input', 'form-input');
                        i.type = 'password';
                        i.inputMode = 'numeric';
                        i.autocomplete = 'off';
                        i.maxLength = 8;
                        i.addEventListener('input', () => { i.value = i.value.replace(/[^0-9]/g, ''); });
                        return i;
                    };
                    const p1 = pinInput();
                    p1.placeholder = t(S.pinPlaceholder);
                    const p2 = create ? pinInput() : null;
                    if (p2) p2.placeholder = t(S.pinAgainPlaceholder);
                    const g1 = el('div', 'form-group');
                    g1.appendChild(p1);
                    let g2 = null;
                    if (p2) { g2 = el('div', 'form-group'); g2.appendChild(p2); }
                    const err = el('div', 'nm-h-20');
                    err.setAttribute('role', 'alert');
                    const showErr = (m) => { err.textContent = m || ''; err.classList.toggle('nm-hidden', !m); localize(err); };
                    showErr(opts.error);
                    const waitNote = el('div', 'form-hint nm-h-24', opts.waitText || '');
                    waitNote.classList.toggle('nm-hidden', !opts.waitText);
                    const okBtn = button(opts.okLabel || t(S.ok), 'send-btn', () => {
                        if (okBtn.disabled) return;
                        const a = p1.value;
                        if (!validPin(a)) { showErr(t(S.pinFormat)); return; }
                        if (p2 && p2.value !== a) { showErr(t(S.pinMismatch)); return; }
                        p1.value = '';
                        if (p2) p2.value = '';
                        settle(a);
                    });
                    const cancelBtn = button(t(S.cancel), 'icon-btn', () => { p1.value = ''; if (p2) p2.value = ''; settle(null); });
                    const onKey = (e) => { if (e.key === 'Enter') okBtn.onclick(); };
                    p1.addEventListener('keydown', onKey);
                    if (p2) p2.addEventListener('keydown', onKey);
                    render(opts.title, [
                        el('p', 'form-hint nm-vault-text', opts.text),
                        create && opts.warning ? el('p', 'form-hint nm-vault-text nm-kb-warning', opts.warning) : null,
                        g1, g2, err, waitNote,
                    ], [cancelBtn, okBtn]);
                    if (opts.waitMs > 0) {
                        okBtn.disabled = true;
                        timer = setTimeout(() => { timer = null; okBtn.disabled = false; waitNote.classList.add('nm-hidden'); }, opts.waitMs);
                    }
                    setTimeout(() => { try { p1.focus(); } catch (_) { } }, 30);
                });
            },
            appleSignIn(opts) {
                return new Promise((resolve, reject) => {
                    settle(null);
                    let done = false;
                    const finish = (fn, v) => { if (done) return; done = true; pending = null; fn(v); };
                    pending = (v) => finish(resolve, v);
                    const mount = el('div', 'nm-kb-apple-signin');
                    mount.id = opts.buttonId;
                    render(opts.title, [el('p', 'form-hint nm-vault-text', opts.text), mount],
                        [button(t(S.cancel), 'icon-btn', () => settle(null))]);
                    Promise.resolve().then(opts.start).then((v) => finish(resolve, v), (e) => finish(reject, e));
                });
            },
            pick(candidates) {
                return ask(() => {
                    const list = el('div', 'nm-kb-list');
                    for (const c of candidates) {
                        const b = button('', 'form-select nm-vault-settings-btn nm-kb-choice notranslate', () => settle(c));
                        b.setAttribute('data-no-i18n', '');
                        b.textContent = shortNpub(c.pubkey);
                        b.title = c.pubkey;
                        list.appendChild(b);
                    }
                    render(t(S.pickTitle), [el('p', 'form-hint nm-vault-text', t(S.pickText)), list],
                        [button(t(S.cancel), 'icon-btn', () => settle(null))]);
                });
            },
            confirm(opts) {
                return ask(() => {
                    render(opts.title, [el('p', 'form-hint nm-vault-text', opts.text)], [
                        button(t(S.cancel), 'icon-btn', () => settle(false)),
                        button(opts.okLabel || t(S.ok), opts.danger ? 'send-btn danger' : 'send-btn', () => settle(true)),
                    ]);
                }).then((v) => v === true);
            },
            notice(opts) {
                return ask(() => {
                    render(opts.title, [el('p', 'form-hint nm-vault-text', opts.text)],
                        [button(t(S.ok), 'send-btn', () => settle(true))]);
                });
            },
            close() {
                settle(null);
                try { ov.remove(); } catch (_) { }
            },
        };
    }

    let running = false;
    let sharedAuth = null;

    function googleAuth() {
        const id = clientId();
        if (!sharedAuth || sharedAuth.clientId !== id) {
            sharedAuth = { clientId: id, auth: createGoogleAuth({ clientId: id }) };
        }
        return sharedAuth.auth;
    }

    function note(text) {
        if (typeof window.showAppAlert !== 'function') return;
        try { Promise.resolve(window.showAppAlert(t(text), { title: t(S.pqBadTitle) })).catch(() => { }); } catch (_) { }
    }

    function presetPq(hex, restored) {
        const n = window.nym;
        if (!restored.pq || !n || typeof n.pqRootPresetFor !== 'function') return;
        let secret = null;
        try {
            secret = fromHex(hex);
            n.pqRootPresetFor(window.NostrTools.getPublicKey(secret), restored.pq, !!restored.fresh);
        } catch (_) { } finally { wipe(secret); }
    }

    async function finishSignIn(handoff) {
        const restored = handoff.restored || {};
        presetPq(handoff.hex, restored);
        await window.nostrLoginImportKey(handoff.hex);
        if (restored.fresh) return;
        if (restored.pq && typeof window.restorePqRootFromBackup === 'function') {
            Promise.resolve(window.restorePqRootFromBackup(restored.pq)).then((status) => {
                if (status === 'mismatch' || status === 'invalid') note(S.pqMismatch);
            }).catch(() => { });
        } else if (restored.pqBad) {
            note(S.pqBad);
        }
    }

    async function runWithUi(flow, extra, provider) {
        const apple = provider === 'apple';
        if (running || !(apple ? appleEnabled() : enabled())) return false;
        running = true;
        const strings = stringsFor(provider);
        const ui = createOverlayUi(t(strings.errorTitle));
        let handoff = null;
        let result = false;
        try {
            const auth = apple ? createCloudKitAuth(Object.assign({ ui }, appleConfig())) : googleAuth();
            const ctx = Object.assign({
                ui, auth, drive: apple ? createCloudKitStore(auth) : createDrive(auth), limiter: createLimiter(),
                importKey: async (hex, restored) => { handoff = { hex, restored }; },
            }, extra);
            result = await flow(ctx);
        } catch (e) {
            handoff = null;
            if (!(e && e.code === 'cancelled')) await ui.notice({ title: t(strings.errorTitle), text: errorText(e, provider) });
        } finally {
            ui.close();
            running = false;
        }
        if (handoff) {
            const h = handoff;
            handoff = null;
            try {
                await finishSignIn(h);
            } catch (_) {
                if (typeof window.showAppAlert === 'function') window.showAppAlert(t(S.errOther));
                return false;
            }
        }
        return result;
    }

    function startContinueWithGoogle() {
        return runWithUi(continueWithGoogle, {
            newSecretKey: () => window.NostrTools.generateSecretKey(),
        });
    }

    function startBackUp(provider) {
        if (!hasLocalKey()) return Promise.resolve(false);
        const n = window.nym;
        return runWithUi(provider === 'apple' ? appleBackUpKey : backUpKey,
            { secretKey: new Uint8Array(n.privkey), pubkey: n.pubkey, pq: currentPq() }, provider);
    }

    function startRemove(provider) {
        if (!hasLocalKey()) return Promise.resolve(false);
        return runWithUi(provider === 'apple' ? appleRemoveBackups : removeBackups, { pubkey: window.nym.pubkey }, provider);
    }

    function startContinueWithApple() {
        return runWithUi(continueWithApple, {
            newSecretKey: () => window.NostrTools.generateSecretKey(),
        }, 'apple');
    }

    function passkeyOn() {
        const pk = window.NymPasskeyBackup;
        try { return !!(pk && typeof pk.enabled === 'function' && pk.enabled()); } catch (_) { return false; }
    }

    function refreshGroup() {
        if (typeof document === 'undefined') return;
        const any = hasLocalKey() && (enabled() || appleEnabled() || passkeyOn());
        const group = document.getElementById('keyBackupGroup');
        if (group) group.classList.toggle('nm-hidden', !any);
        const link = document.getElementById('keyBackupSettingsLink');
        if (link) link.classList.toggle('nm-hidden', !any);
    }

    function orderButtons(doc, first) {
        const pairs = [['setupAppleBackup', 'setupGoogleBackup'], ['appleBackupSettings', 'googleBackupSettings']];
        for (const [appleId, googleId] of pairs) {
            const a = doc.getElementById(appleId);
            const g = doc.getElementById(googleId);
            if (!a || !g || !a.parentNode || a.parentNode !== g.parentNode) continue;
            if (first) a.parentNode.insertBefore(a, g);
            else g.parentNode.insertBefore(g, a);
        }
    }

    function refresh() {
        if (typeof document === 'undefined') return;
        const on = enabled();
        const setup = document.getElementById('setupGoogleBackup');
        if (setup) setup.classList.toggle('nm-hidden', !on);
        const settings = document.getElementById('googleBackupSettings');
        if (settings) settings.classList.toggle('nm-hidden', !(on && hasLocalKey()));
        const appleOn = appleEnabled();
        const appleSetup = document.getElementById('setupAppleBackup');
        if (appleSetup) appleSetup.classList.toggle('nm-hidden', !appleOn);
        const appleSettings = document.getElementById('appleBackupSettings');
        if (appleSettings) appleSettings.classList.toggle('nm-hidden', !(appleOn && hasLocalKey()));
        try { orderButtons(document, appleFirst()); } catch (_) { }
        refreshGroup();
    }

    function openBackupDetails() {
        if (typeof document === 'undefined') return;
        try { if (typeof window.closeModal === 'function') window.closeModal('settingsModal'); } catch (_) { }
        if (typeof window.editNick === 'function') window.editNick();
        const group = document.getElementById('keyBackupGroup');
        if (group && typeof group.scrollIntoView === 'function') {
            setTimeout(() => { try { group.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (_) { } }, 50);
        }
    }

    const ACTIONS = (window.NYM_ACTIONS = window.NYM_ACTIONS || {});
    ACTIONS.continueWithGoogle = function () { startContinueWithGoogle(); };
    ACTIONS.googleBackUpKey = function () { startBackUp('google'); };
    ACTIONS.googleRemoveBackups = function () { startRemove('google'); };
    ACTIONS.continueWithApple = function () { startContinueWithApple(); };
    ACTIONS.appleBackUpKey = function () { startBackUp('apple'); };
    ACTIONS.appleRemoveBackups = function () { startRemove('apple'); };
    ACTIONS.openKeyBackupDetails = function () { openBackupDetails(); };

    window.NymKeyBackup = {
        FORMAT, CONTEXTS, ITERATIONS, SCOPES, GSI_URL, NAME_RE,
        BackupError, toHex, fromHex, validPin,
        backupSalt, deriveBackupKey, bundleText, parseBundle, validPq, checkPq, currentPq, newPqCode,
        encryptBundle, decryptBundle, decryptSecret,
        newFileName, createGoogleAuth, createDrive, loadBackups, matchBackups, createLimiter,
        continueWithGoogle, backUpKey, removeBackups, finishSignIn,
        CLOUDKIT, newRecordName, appleFirst, orderButtons, createCloudKitAuth, createCloudKitStore,
        continueWithApple, appleBackUpKey, appleRemoveBackups, appleEnabled, errorText, appleStrings: SA,
        enabled, hasLocalKey, refresh, strings: S,
        shared: {
            t, localize, shortNpub, createOverlayUi, inNativeShell, hasLocalKey, wipe,
            bundleText, parseBundle, checkPq, validPq, currentPq, newPqCode, finishSignIn, refreshGroup,
        },
    };

    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', refresh);
        else refresh();
    }
})();
