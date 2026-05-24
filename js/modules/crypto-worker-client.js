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
            return call('nip44Decrypt', { ciphertext, key });
        },
        nip44DecryptBatch(items) {
            return call('nip44DecryptBatch', { items });
        },
        isAvailable() {
            return !disabled && typeof Worker !== 'undefined';
        }
    };
})();
