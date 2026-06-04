// NostrTools crypto shared by the main thread and the crypto worker

(function (root) {
    const NT = () => root.NostrTools;
    const enc = new TextEncoder();
    const dec = new TextDecoder();
    let _ckCache = new Map(), _ckBasis = null;

    // ±2h jitter for NIP-59 metadata protection. Uses a CSPRNG so the jitter
    // can't be predicted/stripped by an observer 
    function randomNow() {
        const r = crypto.getRandomValues(new Uint32Array(1))[0] / 4294967296;
        return Math.round(Date.now() / 1000 - r * 7200);
    }

    // Bitchat: HKDF(33-byte compressed shared point, empty salt, "nip44-v2") + XChaCha20-Poly1305
    function encryptBitchat(plaintext, sk, recipientPub) {
        const T = NT();
        const sharedPoint = T._secp256k1.getSharedSecret(sk, '02' + recipientPub);
        const prk = T._hkdfExtract(T._sha256, sharedPoint, new Uint8Array(0));
        const key = T._hkdfExpand(T._sha256, prk, enc.encode('nip44-v2'), 32);
        const nonce = crypto.getRandomValues(new Uint8Array(24));
        const ct = T._xchacha20poly1305(key, nonce).encrypt(enc.encode(plaintext));
        const payload = new Uint8Array(nonce.length + ct.length);
        payload.set(nonce, 0);
        payload.set(ct, nonce.length);
        const b64 = btoa(String.fromCharCode(...payload));
        return 'v2:' + b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    function bitchatWrap(event, sk, recipientPub) {
        const T = NT();
        const rumor = { created_at: Math.floor(Date.now() / 1000), content: '', tags: [], ...event, pubkey: T.getPublicKey(sk) };
        rumor.id = T.getEventHash(rumor);
        const seal = T.finalizeEvent({ kind: 13, content: encryptBitchat(JSON.stringify(rumor), sk, recipientPub), created_at: randomNow(), tags: [] }, sk);
        const ephSk = T.generateSecretKey();
        const wrap = { kind: 1059, content: encryptBitchat(JSON.stringify(seal), ephSk, recipientPub), created_at: randomNow(), tags: [['p', recipientPub]], pubkey: T.getPublicKey(ephSk) };
        return T.finalizeEvent(wrap, ephSk);
    }

    function nip59Wrap(event, sk, recipientPub, expirationTs) {
        const T = NT();
        const rumor = { created_at: Math.floor(Date.now() / 1000), content: '', tags: [], ...event, pubkey: T.getPublicKey(sk) };
        rumor.id = T.getEventHash(rumor);
        const ckSeal = T.nip44.getConversationKey(sk, recipientPub);
        const seal = T.finalizeEvent({ kind: 13, content: T.nip44.encrypt(JSON.stringify(rumor), ckSeal), created_at: randomNow(), tags: [] }, sk);
        const ephSk = T.generateSecretKey();
        const ckWrap = T.nip44.getConversationKey(ephSk, recipientPub);
        const wrap = { kind: 1059, content: T.nip44.encrypt(JSON.stringify(seal), ckWrap), created_at: randomNow(), tags: [['p', recipientPub]], pubkey: T.getPublicKey(ephSk) };
        if (expirationTs) wrap.tags.push(['expiration', String(expirationTs)]);
        return T.finalizeEvent(wrap, ephSk);
    }

    // NIP-13 miner. Off-thread it can grind without yielding.
    function minePow(event, difficulty) {
        if (!difficulty || difficulty <= 0) return event;
        const T = NT();
        let i = event.tags.findIndex(t => Array.isArray(t) && t[0] === 'nonce');
        if (i < 0) { event.tags.push(['nonce', '0', String(difficulty)]); i = event.tags.length - 1; }
        else event.tags[i] = ['nonce', '0', String(difficulty)];
        let nonce = 0;
        while (true) {
            event.tags[i][1] = String(nonce);
            event.id = T.getEventHash(event);
            if (T.nip13.getPow(event.id) >= difficulty) return event;
            nonce++;
        }
    }

    // NIP-44 conversation key, cached by sender pubkey for the real key (selfId set).
    function convKey(sk, pubkey, selfId) {
        const T = NT();
        if (!selfId) return T.nip44.getConversationKey(sk, pubkey);
        if (_ckBasis !== selfId) { _ckCache = new Map(); _ckBasis = selfId; }
        let v = _ckCache.get(pubkey);
        if (v) return v;
        v = T.nip44.getConversationKey(sk, pubkey);
        if (_ckCache.size >= 1000) _ckCache.delete(_ckCache.keys().next().value);
        _ckCache.set(pubkey, v);
        return v;
    }

    function decryptBitchatRaw(content, senderPub, sk) {
        const T = NT();
        if (content.startsWith('v2:')) content = content.slice(3);
        content = content.replace(/-/g, '+').replace(/_/g, '/');
        while (content.length % 4) content += '=';
        const payload = Uint8Array.from(atob(content), c => c.charCodeAt(0));
        const info = enc.encode('nip44-v2');
        const nonce = payload.subarray(0, 24), ct = payload.subarray(24);
        for (const pre of ['02', '03']) {
            try {
                const sp = T._secp256k1.getSharedSecret(sk, pre + senderPub);
                const prk = T._hkdfExtract(T._sha256, sp, new Uint8Array(0));
                const key = T._hkdfExpand(T._sha256, prk, info, 32);
                return dec.decode(T._xchacha20poly1305(key, nonce).decrypt(ct));
            } catch (_) { }
        }
        throw new Error('bitchat decrypt failed');
    }

    // Decrypt + verify a gift wrap against ordered candidate keys
    // [{ sk, bitchat, selfId? }]. Returns { seal, rumor, isBitchat, idx } or null.
    function unwrapGiftWrap(event, candidates) {
        const T = NT();
        const isV2 = (c) => typeof c === 'string' && c.startsWith('v2:');
        for (let i = 0; i < candidates.length; i++) {
            const { sk, bitchat, selfId } = candidates[i];
            try {
                let seal, rumor, isBitchat = false;
                if (bitchat && isV2(event.content)) {
                    seal = JSON.parse(decryptBitchatRaw(event.content, event.pubkey, sk));
                    rumor = JSON.parse(isV2(seal.content)
                        ? decryptBitchatRaw(seal.content, seal.pubkey, sk)
                        : T.nip44.decrypt(seal.content, convKey(sk, seal.pubkey, selfId)));
                    isBitchat = true;
                } else {
                    seal = JSON.parse(T.nip44.decrypt(event.content, convKey(sk, event.pubkey)));
                    rumor = JSON.parse(T.nip44.decrypt(seal.content, convKey(sk, seal.pubkey, selfId)));
                }
                return { seal, rumor, isBitchat, idx: i };
            } catch (_) { }
        }
        return null;
    }

    root.NymCrypto = { randomNow, encryptBitchat, bitchatWrap, nip59Wrap, minePow, unwrapGiftWrap };
})(typeof self !== 'undefined' ? self : this);
