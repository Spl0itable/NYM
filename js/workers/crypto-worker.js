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

// Same shape as NYM.prototype.nip59WrapEvent. Runs entirely off the main
// thread so the typing-indicator path (and any other caller that batches a
// wrap loop) doesn't block input rendering.
function _nip59Wrap(event, senderPrivkey, recipientPubkey, expirationTs) {
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
    const sealUnsigned = {
        kind: 13,
        content: sealedContent,
        created_at: _randomNow(),
        tags: []
    };
    const seal = NT.finalizeEvent(sealUnsigned, senderPrivkey);

    const ephSk = NT.generateSecretKey();
    const ckWrap = NT.nip44.getConversationKey(ephSk, recipientPubkey);
    const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
    const wrapTags = [['p', recipientPubkey]];
    if (expirationTs) wrapTags.push(['expiration', String(expirationTs)]);
    const wrapUnsigned = {
        kind: 1059,
        content: wrapContent,
        created_at: _randomNow(),
        tags: wrapTags
    };
    return NT.finalizeEvent(wrapUnsigned, ephSk);
}

// NIP-59 randomized timestamp tweak (matches NYM.prototype.randomNow):
// up to two days in the past to avoid revealing send time.
function _randomNow() {
    return Math.floor(Date.now() / 1000) - Math.floor(Math.random() * 172800);
}

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
            case 'nip59Wrap':
                result = _nip59Wrap(args.rumor, args.senderPrivkey, args.recipientPubkey, args.expirationTs || null);
                break;
            case 'nip59WrapBatch':
                result = (args.recipients || []).map(r => {
                    try { return { ok: true, wrapped: _nip59Wrap(args.rumor, args.senderPrivkey, r.pubkey, r.expirationTs || null) }; }
                    catch (err) { return { ok: false, error: String(err && err.message || err) }; }
                });
                break;
            case 'signEvent':
                result = NT.finalizeEvent(args.event, args.senderPrivkey);
                break;
            default:
                throw new Error('crypto-worker: unknown op ' + op);
        }
        self.postMessage({ id, result });
    } catch (err) {
        self.postMessage({ id, error: String(err && err.message || err) });
    }
};
