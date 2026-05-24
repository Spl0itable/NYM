/* eslint-env worker */

let NT = null;
let ready = (async () => {
    try {
        importScripts('../nostr-tools.js');
        NT = self.NostrTools || NostrTools;
    } catch (e) {
        self.postMessage({ id: 'init', error: 'crypto-worker: nostr-tools load failed: ' + (e && e.message || e) });
    }
})();

self.onmessage = async (e) => {
    const { id, op, args } = e.data || {};
    if (!id || !op) return;
    try {
        await ready;
        if (!NT) throw new Error('NostrTools not available in worker');
        let result;
        switch (op) {
            case 'verifyEvent':
                result = NT.verifyEvent(args.event);
                break;
            case 'verifyEvents':
                result = (args.events || []).map(ev => NT.verifyEvent(ev));
                break;
            case 'nip44Decrypt':
                result = NT.nip44.decrypt(args.ciphertext, args.key);
                break;
            case 'nip44DecryptBatch':
                result = (args.items || []).map(it => {
                    try { return { ok: true, plaintext: NT.nip44.decrypt(it.ciphertext, it.key) }; }
                    catch (err) { return { ok: false, error: String(err && err.message || err) }; }
                });
                break;
            default:
                throw new Error('crypto-worker: unknown op ' + op);
        }
        self.postMessage({ id, result });
    } catch (err) {
        self.postMessage({ id, error: String(err && err.message || err) });
    }
};
