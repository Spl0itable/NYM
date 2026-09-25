(function () {
    'use strict';

    const FORMAT = 'nym-passkey-backup-v1';
    const PRF_SALT_LABEL = 'nym-key-backup-v1';
    const ENC_INFO = 'nym-passkey-enc';
    const LOCATOR_INFO = 'nym-passkey-locator';
    const KIND = 30078;
    const D_TAG = 'nym-key-backup';
    const FIXED_RELAYS = [
        'wss://relay.damus.io',
        'wss://nos.lol',
        'wss://relay.primal.net',
        'wss://relay.nostr.band',
        'wss://nostr.mom',
    ];
    const SECP256K1_N = BigInt('0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141');
    const APP_NAME = 'Nymchat';

    const enc = new TextEncoder();

    class PasskeyBackupError extends Error {
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

    function bytes(buf) {
        if (!buf) return null;
        if (buf instanceof Uint8Array) return new Uint8Array(buf);
        if (ArrayBuffer.isView(buf)) return new Uint8Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
        return new Uint8Array(buf);
    }

    function tools() {
        const t = window.NostrTools;
        if (!t || !t.nip44 || !t.nip44.v2) throw new PasskeyBackupError('crypto');
        return t;
    }

    async function prfSalt() {
        return new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(PRF_SALT_LABEL)));
    }

    async function hkdf(ikm, info) {
        const base = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
        const bits = await crypto.subtle.deriveBits(
            { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: enc.encode(info) }, base, 256);
        return new Uint8Array(bits);
    }

    function validScalar(sk) {
        const n = BigInt('0x' + toHex(sk));
        return n > 0n && n < SECP256K1_N;
    }

    async function deriveKeys(prfOutput) {
        const encKey = await hkdf(prfOutput, ENC_INFO);
        const locatorSecret = await hkdf(prfOutput, LOCATOR_INFO);
        if (!validScalar(locatorSecret)) {
            wipe(encKey);
            wipe(locatorSecret);
            throw new PasskeyBackupError('locator');
        }
        return { encKey, locatorSecret, locatorPubkey: tools().getPublicKey(locatorSecret) };
    }

    function bundleLib() {
        const kb = window.NymKeyBackup;
        if (!kb || typeof kb.bundleText !== 'function' || typeof kb.parseBundle !== 'function') throw new PasskeyBackupError('crypto');
        return kb;
    }

    function encryptBundle(secretKey, pq, encKey, nonce) {
        if (!(secretKey && secretKey.length === 32)) throw new PasskeyBackupError('secret');
        return tools().nip44.v2.encrypt(bundleLib().bundleText(toHex(secretKey), pq), encKey, nonce);
    }

    function decryptBundle(payload, encKey) {
        let text;
        try { text = tools().nip44.v2.decrypt(String(payload || '').trim(), encKey); } catch (_) { return null; }
        const b = bundleLib().parseBundle(text);
        return b ? { secret: fromHex(b.skHex), pq: b.pq } : null;
    }

    function decryptSecret(payload, encKey) {
        const b = decryptBundle(payload, encKey);
        return b ? b.secret : null;
    }

    function backupEvent(content, locatorSecret, createdAt) {
        return tools().finalizeEvent({
            kind: KIND,
            created_at: createdAt || Math.floor(Date.now() / 1000),
            tags: [['d', D_TAG]],
            content,
        }, locatorSecret);
    }

    function isBackupEvent(ev, locatorPubkey) {
        try {
            if (!ev || ev.kind !== KIND || ev.pubkey !== locatorPubkey) return false;
            if (!Array.isArray(ev.tags) || !ev.tags.some((t) => Array.isArray(t) && t[0] === 'd' && t[1] === D_TAG)) return false;
            const plain = { id: ev.id, pubkey: ev.pubkey, created_at: ev.created_at, kind: ev.kind, tags: ev.tags, content: ev.content, sig: ev.sig };
            return tools().verifyEvent(plain) === true;
        } catch (_) { return false; }
    }

    function blobFor(secretKey, pq) {
        return enc.encode(bundleLib().bundleText(toHex(secretKey), pq));
    }

    function bundleFromBlob(blob) {
        let text;
        try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes(blob)); } catch (_) { return null; }
        if (!/^\s*\{/.test(text)) return null;
        const b = bundleLib().parseBundle(text);
        return b ? { secret: fromHex(b.skHex), pq: b.pq } : null;
    }

    function secretFromBlob(blob) {
        const b = bundleFromBlob(blob);
        return b ? b.secret : null;
    }

    function relayList(nym) {
        const own = nym && Array.isArray(nym.defaultRelays) ? nym.defaultRelays : [];
        return [...new Set([...own, ...FIXED_RELAYS])].filter((u) => typeof u === 'string' && /^wss:\/\//.test(u));
    }

    function readableRelays(nym) {
        const writeOnly = nym && nym.writeOnlyRelays instanceof Set ? nym.writeOnlyRelays : new Set();
        return relayList(nym).filter((u) => !writeOnly.has(u));
    }

    function createRelayClient(opts) {
        opts = opts || {};
        const WS = opts.WebSocket || window.WebSocket;
        const mapUrl = opts.mapUrl || ((u) => u);
        const timeoutMs = opts.timeoutMs || 8000;
        const graceMs = opts.graceMs || 1500;

        function connect(url, onOpen, onMessage, onDone) {
            const first = mapUrl(url);
            let ws = null;
            let finished = false;
            const finish = () => {
                if (finished) return;
                finished = true;
                try { if (ws) ws.close(); } catch (_) { }
                onDone();
            };
            const attempt = (target, canFallback) => {
                let opened = false;
                try { ws = new WS(target); } catch (_) {
                    if (canFallback) { attempt(url, false); return; }
                    finish();
                    return;
                }
                ws.onopen = () => { opened = true; onOpen(ws); };
                ws.onmessage = (e) => {
                    let msg;
                    try { msg = JSON.parse(e.data); } catch (_) { return; }
                    if (Array.isArray(msg)) onMessage(msg, finish);
                };
                ws.onerror = () => { };
                ws.onclose = () => {
                    if (finished) return;
                    if (!opened && canFallback) { attempt(url, false); return; }
                    finish();
                };
            };
            attempt(first, first !== url);
            return finish;
        }

        function publish(event, urls) {
            return new Promise((resolve) => {
                let pending = urls.length;
                let ok = 0;
                const closers = [];
                let graceTimer = null;
                const done = () => {
                    clearTimeout(deadline);
                    if (graceTimer) clearTimeout(graceTimer);
                    for (const c of closers) c();
                    resolve(ok);
                };
                const deadline = setTimeout(done, timeoutMs);
                if (!pending) { done(); return; }
                for (const url of urls) {
                    closers.push(connect(url,
                        (ws) => { try { ws.send(JSON.stringify(['EVENT', event])); } catch (_) { } },
                        (msg, finish) => {
                            if (msg[0] === 'OK' && msg[1] === event.id) {
                                if (msg[2] === true) {
                                    ok++;
                                    if (!graceTimer) graceTimer = setTimeout(done, graceMs);
                                }
                                finish();
                            }
                        },
                        () => { if (--pending === 0) done(); }));
                }
            });
        }

        function query(filter, urls) {
            return new Promise((resolve) => {
                let pending = urls.length;
                const events = [];
                const closers = [];
                let graceTimer = null;
                const subId = 'nymbk' + toHex(crypto.getRandomValues(new Uint8Array(6)));
                const done = () => {
                    clearTimeout(deadline);
                    if (graceTimer) clearTimeout(graceTimer);
                    for (const c of closers) c();
                    resolve(events);
                };
                const deadline = setTimeout(done, timeoutMs);
                if (!pending) { done(); return; }
                for (const url of urls) {
                    closers.push(connect(url,
                        (ws) => { try { ws.send(JSON.stringify(['REQ', subId, filter])); } catch (_) { } },
                        (msg, finish) => {
                            if (msg[0] === 'EVENT' && msg[1] === subId && msg[2]) events.push(msg[2]);
                            else if ((msg[0] === 'EOSE' && msg[1] === subId) || (msg[0] === 'CLOSED' && msg[1] === subId)) {
                                if (events.length && !graceTimer) graceTimer = setTimeout(done, graceMs);
                                finish();
                            }
                        },
                        () => { if (--pending === 0) done(); }));
                }
            });
        }

        return { publish, query };
    }

    function extResults(cred) {
        try { return (cred && typeof cred.getClientExtensionResults === 'function' && cred.getClientExtensionResults()) || {}; } catch (_) { return {}; }
    }

    function prfFirst(ext) {
        return ext && ext.prf && ext.prf.results && ext.prf.results.first ? bytes(ext.prf.results.first) : null;
    }

    function webauthnError(e) {
        if (e instanceof PasskeyBackupError) return e;
        const name = e && e.name;
        if (name === 'NotAllowedError' || name === 'AbortError') return new PasskeyBackupError('cancelled');
        if (name === 'InvalidStateError') return new PasskeyBackupError('exists');
        if (name === 'SecurityError') return new PasskeyBackupError('rp');
        return new PasskeyBackupError('webauthn', name || '');
    }

    function shortNpubOf(pubkey) {
        let npub = pubkey;
        try { npub = tools().nip19.npubEncode(pubkey); } catch (_) { }
        return npub.slice(0, 12) + '…' + npub.slice(-6);
    }

    const S = {
        title: 'Passkey backup',
        waiting: 'Waiting for your passkey…',
        saving: 'Saving your backup…',
        looking: 'Looking for your backup…',
        signingIn: 'Signing in…',
        backedUpTitle: 'Backed up',
        backedUpText: 'Your key is backed up with this passkey. Your key stays yours: the backup is encrypted, and only this passkey can unlock it. To restore it on another device where the passkey is available, choose Continue with a passkey.',
        backedUpPqText: 'Your key and your post-quantum recovery code are backed up with this passkey. Your key stays yours: the backup is encrypted, and only this passkey can unlock it. To restore them on another device where the passkey is available, choose Continue with a passkey.',
        notFound: 'No key backup is linked to this passkey.',
        unsupported: 'This passkey provider can\'t hold a key backup. Try a different passkey provider, or use Continue with Google.',
        blobFailed: 'The passkey didn\'t save the backup. Try again, or use a different passkey provider.',
        publishFailed: 'Couldn\'t reach any relay to save the backup. Check your connection and try again.',
        rp: 'Passkeys aren\'t available on this address.',
        exists: 'This passkey is already registered here. Choose another one.',
        other: 'Something went wrong with the passkey backup. Please try again.',
        ok: 'OK',
        offerAfterNotFound: 'No key backup is linked to this passkey. Create a new key and back it up with a passkey?',
        offerAfterCancel: 'No passkey was chosen. Create a new key and back it up with a passkey?',
        createLabel: 'Create new key',
        createIncomplete: 'Your new key was created, but its passkey backup didn\'t complete. You\'ll be signed in now. To try again, open View or Edit Nym\'s Details and choose Back up with a passkey.',
    };

    async function backUpWithPasskey(ctx) {
        const { ui, credentials, relays, relayUrls, rpId, secretKey, pubkey, quiet } = ctx;
        const pq = bundleLib().validPq(ctx.pq) ? ctx.pq : null;
        const salt = await prfSalt();
        let prfOut = null;
        let keys = null;
        try {
            ui.busy(S.waiting);
            const label = APP_NAME + ' key backup · ' + shortNpubOf(pubkey);
            let cred;
            try {
                cred = await credentials.create({
                    publicKey: {
                        challenge: crypto.getRandomValues(new Uint8Array(32)),
                        rp: { id: rpId, name: APP_NAME },
                        user: { id: crypto.getRandomValues(new Uint8Array(16)), name: label, displayName: label },
                        pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
                        authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
                        timeout: 60000,
                        extensions: { prf: { eval: { first: salt } }, largeBlob: { support: 'preferred' } },
                    },
                });
            } catch (e) { throw webauthnError(e); }
            if (!cred) throw new PasskeyBackupError('cancelled');
            const created = extResults(cred);
            const allow = [{ type: 'public-key', id: bytes(cred.rawId) }];
            prfOut = prfFirst(created);
            if (!prfOut && created.prf && created.prf.enabled === true) {
                let assertion;
                try {
                    assertion = await credentials.get({
                        publicKey: {
                            challenge: crypto.getRandomValues(new Uint8Array(32)),
                            rpId,
                            allowCredentials: allow,
                            userVerification: 'required',
                            timeout: 60000,
                            extensions: { prf: { eval: { first: salt } } },
                        },
                    });
                } catch (e) { throw webauthnError(e); }
                prfOut = prfFirst(extResults(assertion));
            }
            if (prfOut) {
                ui.busy(S.saving);
                keys = await deriveKeys(prfOut);
                const event = backupEvent(encryptBundle(secretKey, pq, keys.encKey), keys.locatorSecret);
                const ok = await relays.publish(event, relayUrls);
                if (!ok) throw new PasskeyBackupError('publish');
            } else if (created.largeBlob && created.largeBlob.supported === true) {
                let assertion;
                const blob = blobFor(secretKey, pq);
                try {
                    assertion = await credentials.get({
                        publicKey: {
                            challenge: crypto.getRandomValues(new Uint8Array(32)),
                            rpId,
                            allowCredentials: allow,
                            userVerification: 'required',
                            timeout: 60000,
                            extensions: { largeBlob: { write: blob } },
                        },
                    });
                } catch (e) { throw webauthnError(e); } finally { wipe(blob); }
                const res = extResults(assertion);
                if (!(res.largeBlob && res.largeBlob.written === true)) throw new PasskeyBackupError('blob');
            } else {
                throw new PasskeyBackupError('unsupported');
            }
            if (!quiet) await ui.notice({ title: S.backedUpTitle, text: pq ? S.backedUpPqText : S.backedUpText });
            return true;
        } finally {
            wipe(prfOut);
            if (keys) { wipe(keys.encKey); wipe(keys.locatorSecret); }
            wipe(secretKey);
        }
    }

    async function findPrfBackup(prfOut, relays, relayUrls) {
        const keys = await deriveKeys(prfOut);
        try {
            const events = await relays.query({ kinds: [KIND], authors: [keys.locatorPubkey], '#d': [D_TAG] }, relayUrls);
            const valid = events.filter((ev) => isBackupEvent(ev, keys.locatorPubkey))
                .sort((a, b) => b.created_at - a.created_at);
            for (const ev of valid) {
                const found = decryptBundle(ev.content, keys.encKey);
                if (found) return found;
            }
            return null;
        } finally {
            wipe(keys.encKey);
            wipe(keys.locatorSecret);
        }
    }

    async function restoreWithPasskey(ctx) {
        const { ui, credentials, relays, rpId, importKey } = ctx;
        const relayUrls = ctx.queryUrls || ctx.relayUrls;
        const salt = await prfSalt();
        ui.busy(S.waiting);
        let assertion;
        try {
            assertion = await credentials.get({
                publicKey: {
                    challenge: crypto.getRandomValues(new Uint8Array(32)),
                    rpId,
                    userVerification: 'required',
                    timeout: 60000,
                    extensions: { prf: { eval: { first: salt } }, largeBlob: { read: true } },
                },
            });
        } catch (e) { throw webauthnError(e); }
        if (!assertion) throw new PasskeyBackupError('cancelled');
        const ext = extResults(assertion);
        const prfOut = prfFirst(ext);
        let found = null;
        try {
            if (prfOut) {
                ui.busy(S.looking);
                found = await findPrfBackup(prfOut, relays, relayUrls);
            }
        } finally {
            wipe(prfOut);
        }
        if (!found && ext.largeBlob && ext.largeBlob.blob) found = bundleFromBlob(ext.largeBlob.blob);
        if (!found) throw new PasskeyBackupError('notfound');
        let hex;
        try {
            tools().getPublicKey(found.secret);
            hex = toHex(found.secret);
        } catch (_) {
            throw new PasskeyBackupError('notfound');
        } finally {
            wipe(found.secret);
        }
        ui.busy(S.signingIn);
        await importKey(hex, bundleLib().checkPq(found.pq));
        return true;
    }

    async function createWithPasskey(ctx) {
        const { ui, importKey, newSecretKey } = ctx;
        const secret = newSecretKey();
        const pubkey = tools().getPublicKey(secret);
        const pq = (ctx.newPqCode || bundleLib().newPqCode)();
        let failed = false;
        try {
            await backUpWithPasskey(Object.assign({}, ctx, { secretKey: new Uint8Array(secret), pubkey, pq, quiet: true }));
        } catch (_) {
            failed = true;
        }
        const hex = toHex(secret);
        wipe(secret);
        if (failed) await ui.notice({ title: S.title, text: S.createIncomplete });
        ui.busy(S.signingIn);
        await importKey(hex, { pq, pqBad: false, fresh: true });
        return true;
    }

    async function continueWithPasskey(ctx) {
        try {
            return await restoreWithPasskey(ctx);
        } catch (e) {
            const code = e && e.code;
            if (code !== 'cancelled' && code !== 'notfound') throw e;
            const ok = await ctx.ui.confirm({
                title: S.title,
                text: code === 'notfound' ? S.offerAfterNotFound : S.offerAfterCancel,
                okLabel: S.createLabel,
            });
            if (!ok) return false;
            return createWithPasskey(ctx);
        }
    }

    function errorText(e) {
        const code = e && e.code;
        if (code === 'notfound') return S.notFound;
        if (code === 'unsupported') return S.unsupported;
        if (code === 'blob') return S.blobFailed;
        if (code === 'publish') return S.publishFailed;
        if (code === 'rp') return S.rp;
        if (code === 'exists') return S.exists;
        return S.other;
    }

    function shared() {
        return window.NymKeyBackup && window.NymKeyBackup.shared;
    }

    function rpId() {
        const n = window.nym;
        if (n && typeof n._webauthnRpId === 'function') return n._webauthnRpId();
        return location.hostname;
    }

    function enabled() {
        const n = window.nym;
        const sh = shared();
        if (!sh || sh.inNativeShell()) return false;
        if (!(window.crypto && crypto.subtle)) return false;
        if (n && typeof n.webauthnAvailable === 'function') return n.webauthnAvailable();
        return !!(window.PublicKeyCredential && navigator.credentials && navigator.credentials.create && navigator.credentials.get);
    }

    function mapUrl(url) {
        try {
            const n = window.nym;
            if (n && typeof n._getProxiedRelayUrl === 'function') return n._getProxiedRelayUrl(url);
        } catch (_) { }
        return url;
    }

    let running = false;

    async function runWithUi(flow, extra) {
        const sh = shared();
        if (running || !sh || !enabled()) return false;
        running = true;
        const tr = (s) => sh.t(s);
        const ui = sh.createOverlayUi(tr(S.title));
        const uiT = {
            busy: (s) => ui.busy(tr(s)),
            notice: (o) => ui.notice({ title: tr(o.title), text: tr(o.text) }),
            confirm: (o) => ui.confirm({ title: tr(o.title), text: tr(o.text), okLabel: tr(o.okLabel) }),
        };
        let handoff = null;
        let result = false;
        try {
            const ctx = Object.assign({
                ui: uiT,
                credentials: navigator.credentials,
                relays: createRelayClient({ mapUrl }),
                rpId: rpId(),
                importKey: async (hex, restored) => { handoff = { hex, restored }; },
            }, extra);
            result = await flow(ctx);
        } catch (e) {
            handoff = null;
            if (!(e && e.code === 'cancelled')) await ui.notice({ title: tr(S.title), text: tr(errorText(e)) });
        } finally {
            ui.close();
            running = false;
        }
        if (handoff) {
            const h = handoff;
            handoff = null;
            try {
                await sh.finishSignIn(h);
            } catch (_) {
                if (typeof window.showAppAlert === 'function') window.showAppAlert(tr(S.other));
                return false;
            }
        }
        return result;
    }

    function newKeyDeps() {
        return {
            relayUrls: relayList(window.nym),
            queryUrls: readableRelays(window.nym),
            newSecretKey: () => tools().generateSecretKey(),
        };
    }

    function startRestore() {
        return runWithUi(continueWithPasskey, newKeyDeps());
    }

    function startCreate() {
        return runWithUi(createWithPasskey, newKeyDeps());
    }

    function startBackUp() {
        const sh = shared();
        if (!sh || !sh.hasLocalKey()) return Promise.resolve(false);
        const n = window.nym;
        return runWithUi(backUpWithPasskey, {
            relayUrls: relayList(n),
            secretKey: new Uint8Array(n.privkey),
            pubkey: n.pubkey,
            pq: sh.currentPq(),
        });
    }

    function refresh() {
        if (typeof document === 'undefined') return;
        const on = enabled();
        const sh = shared();
        const setupBtn = document.getElementById('setupPasskeyBackup');
        if (setupBtn) setupBtn.classList.toggle('nm-hidden', !on);
        const createBtn = document.getElementById('setupPasskeyCreate');
        if (createBtn) createBtn.classList.toggle('nm-hidden', !on);
        const settings = document.getElementById('passkeyBackupSettings');
        if (settings) settings.classList.toggle('nm-hidden', !(on && sh && sh.hasLocalKey()));
        if (sh && typeof sh.refreshGroup === 'function') sh.refreshGroup();
    }

    const ACTIONS = (window.NYM_ACTIONS = window.NYM_ACTIONS || {});
    ACTIONS.continueWithPasskey = function () { startRestore(); };
    ACTIONS.passkeyBackUpKey = function () { startBackUp(); };
    ACTIONS.createWithPasskey = function () { startCreate(); };

    window.NymPasskeyBackup = {
        FORMAT, PRF_SALT_LABEL, ENC_INFO, LOCATOR_INFO, KIND, D_TAG, FIXED_RELAYS,
        PasskeyBackupError, toHex, fromHex,
        prfSalt, deriveKeys, encryptBundle, decryptBundle, decryptSecret, backupEvent, isBackupEvent,
        blobFor, bundleFromBlob, secretFromBlob, relayList, readableRelays, createRelayClient,
        backUpWithPasskey, restoreWithPasskey, createWithPasskey, continueWithPasskey,
        enabled, refresh, strings: S,
    };

    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', refresh);
        else refresh();
    }
})();
