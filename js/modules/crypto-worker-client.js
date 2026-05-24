(function () {
    'use strict';
    if (window.cryptoWorkerClient) return;

    let worker = null;
    let nextId = 1;
    const pending = new Map();
    let disabled = false;

    function ensureWorker() {
        if (worker || disabled) return worker;
        try {
            worker = new Worker('js/workers/crypto-worker.js');
            worker.onmessage = (e) => {
                const { id, result, error } = e.data || {};
                const entry = pending.get(id);
                if (!entry) return;
                pending.delete(id);
                if (error) entry.reject(new Error(error));
                else entry.resolve(result);
            };
            worker.onerror = () => {
                disabled = true;
                worker = null;
                for (const entry of pending.values()) entry.reject(new Error('crypto-worker errored'));
                pending.clear();
            };
        } catch (e) {
            disabled = true;
        }
        return worker;
    }

    function call(op, args) {
        const w = ensureWorker();
        if (!w) return Promise.reject(new Error('crypto-worker unavailable'));
        const id = 'c' + (nextId++);
        return new Promise((resolve, reject) => {
            pending.set(id, { resolve, reject });
            w.postMessage({ id, op, args });
        });
    }

    // Same wrap logic as the worker, for the main-thread fallback path when
    // the worker isn't available (private mode, Worker errored, etc.).
    function _mainThreadWrap(event, senderPrivkey, recipientPubkey, expirationTs) {
        const NT = window.NostrTools;
        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            created_at: now,
            content: '',
            tags: [],
            ...event,
            pubkey: NT.getPublicKey(senderPrivkey)
        };
        rumor.id = NT.getEventHash(rumor);
        const ckSeal = NT.nip44.getConversationKey(senderPrivkey, recipientPubkey);
        const sealedContent = NT.nip44.encrypt(JSON.stringify(rumor), ckSeal);
        const seal = NT.finalizeEvent({
            kind: 13,
            content: sealedContent,
            created_at: Math.floor(Date.now() / 1000) - Math.floor(Math.random() * 172800),
            tags: []
        }, senderPrivkey);
        const ephSk = NT.generateSecretKey();
        const ckWrap = NT.nip44.getConversationKey(ephSk, recipientPubkey);
        const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
        const wrapTags = [['p', recipientPubkey]];
        if (expirationTs) wrapTags.push(['expiration', String(expirationTs)]);
        return NT.finalizeEvent({
            kind: 1059,
            content: wrapContent,
            created_at: Math.floor(Date.now() / 1000) - Math.floor(Math.random() * 172800),
            tags: wrapTags
        }, ephSk);
    }

    window.cryptoWorkerClient = {
        verifyEvent(event) {
            return call('verifyEvent', { event }).catch(() => {
                try { return window.NostrTools.verifyEvent(event); } catch (_) { return false; }
            });
        },
        verifyEvents(events) {
            return call('verifyEvents', { events }).catch(() => events.map(ev => {
                try { return window.NostrTools.verifyEvent(ev); } catch (_) { return false; }
            }));
        },
        nip44Decrypt(ciphertext, key) {
            return call('nip44Decrypt', { ciphertext, key }).catch(() => {
                return window.NostrTools.nip44.decrypt(ciphertext, key);
            });
        },
        nip44DecryptBatch(items) {
            return call('nip44DecryptBatch', { items }).catch(() => items.map(it => {
                try { return { ok: true, plaintext: window.NostrTools.nip44.decrypt(it.ciphertext, it.key) }; }
                catch (err) { return { ok: false, error: String(err && err.message || err) }; }
            }));
        },
        // Off-main-thread NIP-59 wrap for a single recipient. ~10 crypto ops
        // per wrap; the typing-indicator path used to run these synchronously
        // and stall the input event before the next paint.
        nip59Wrap(rumor, senderPrivkey, recipientPubkey, expirationTs) {
            return call('nip59Wrap', { rumor, senderPrivkey, recipientPubkey, expirationTs: expirationTs || null })
                .catch(() => _mainThreadWrap(rumor, senderPrivkey, recipientPubkey, expirationTs));
        },
        // Batched wrap for groups — one postMessage round-trip for N members
        // instead of N. Returns [{ ok, wrapped } | { ok: false, error }].
        nip59WrapBatch(rumor, senderPrivkey, recipients) {
            return call('nip59WrapBatch', { rumor, senderPrivkey, recipients })
                .catch(() => recipients.map(r => {
                    try { return { ok: true, wrapped: _mainThreadWrap(rumor, senderPrivkey, r.pubkey, r.expirationTs || null) }; }
                    catch (err) { return { ok: false, error: String(err && err.message || err) }; }
                }));
        },
        signEvent(event, senderPrivkey) {
            return call('signEvent', { event, senderPrivkey })
                .catch(() => window.NostrTools.finalizeEvent(event, senderPrivkey));
        },
        isAvailable() {
            return !disabled && typeof Worker !== 'undefined';
        }
    };
})();
