// NostrTools crypto shared by the main thread and the crypto worker

(function (root) {
    const NT = () => root.NostrTools;
    const MK = () => root.NymMlKem && root.NymMlKem.ml_kem768;
    const enc = new TextEncoder();
    const dec = new TextDecoder();
    let _ckCache = new Map(), _ckBasis = null;

    // Hybrid post-quantum key agreement (Nymchat <-> Nymchat only).
    const PQ_PREFIX = 'pq1.';
    const PQ_COMBINER_SALT = 'nymchat-pq-v1';
    const PQ_SEED_SALT = 'nym-pq-v1';
    const PQ_KEM_CT_LEN = 1088;
    const PQ_KEM_PK_LEN = 1184;

    function b64uEncode(bytes) {
        let s = '';
        for (let i = 0; i < bytes.length; i += 0x8000) {
            s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    function b64uDecode(str) {
        let s = str.replace(/-/g, '+').replace(/_/g, '/');
        while (s.length % 4) s += '=';
        const bin = atob(s);
        const out = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
    }

    function concatBytes(...arrs) {
        let n = 0;
        for (const a of arrs) n += a.length;
        const out = new Uint8Array(n);
        let o = 0;
        for (const a of arrs) { out.set(a, o); o += a.length; }
        return out;
    }

    function hexToBytes(hex) {
        const out = new Uint8Array(hex.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
        return out;
    }

    // secp256k1 ECDH exactly as NIP-44 does it: lift the x-only pubkey to the
    // even-y point and take the 32-byte big-endian x of the shared point.
    function ecdhSharedX(sk, pubkeyHex) {
        return NT()._secp256k1.getSharedSecret(sk, '02' + pubkeyHex).subarray(1, 33);
    }

    // The hybrid conversation key. Feeds straight into the UNMODIFIED
    // nip44.encrypt/decrypt, which take a 32-byte conversation key.
    //
    // ck = HKDF-Extract(salt="nymchat-pq-v1",
    //                   IKM = ecdh_x || kem_ss || kem_ct || recip_kem_pk
    //                      || sender_secp_pk || recip_secp_pk)
    function pqConversationKey(ecdhX, kemSs, kemCt, recipKemPk, senderSecpPkHex, recipSecpPkHex) {
        const T = NT();
        const ikm = concatBytes(
            ecdhX, kemSs, kemCt, recipKemPk,
            hexToBytes(senderSecpPkHex), hexToBytes(recipSecpPkHex)
        );
        return T._hkdfExtract(T._sha256, ikm, enc.encode(PQ_COMBINER_SALT));
    }

    function isPqPayload(content) {
        return typeof content === 'string' && content.startsWith(PQ_PREFIX);
    }

    // Encrypt `plaintext` to a recipient holding (recipSecpPkHex, recipKemPk).
    // `senderSk` supplies the classical leg; the KEM leg is freshly encapsulated
    // per call, so every message gets an independent PQ shared secret even
    // though the recipient's ML-KEM key is long-lived.
    function pqEncrypt(plaintext, senderSk, recipSecpPkHex, recipKemPk) {
        const T = NT(), kem = MK();
        if (!kem) throw new Error('ml-kem unavailable');
        if (!(recipKemPk instanceof Uint8Array) || recipKemPk.length !== PQ_KEM_PK_LEN) {
            throw new Error('bad ml-kem public key');
        }
        const { cipherText, sharedSecret } = kem.encapsulate(recipKemPk);
        const ck = pqConversationKey(
            ecdhSharedX(senderSk, recipSecpPkHex), sharedSecret, cipherText, recipKemPk,
            T.getPublicKey(senderSk), recipSecpPkHex
        );
        return PQ_PREFIX + b64uEncode(cipherText) + '.' + T.nip44.encrypt(plaintext, ck);
    }

    // Inverse of pqEncrypt. `self` is the recipient's own key material:
    // { sk, kemSk, kemPk }. Throws on any malformed input so callers can treat
    // a throw as "not for us / not decryptable" exactly as they do for NIP-44.
    function pqDecrypt(content, senderSecpPkHex, self) {
        const T = NT(), kem = MK();
        if (!kem) throw new Error('ml-kem unavailable');
        if (!isPqPayload(content)) throw new Error('not a pq payload');
        const dot = content.indexOf('.', PQ_PREFIX.length);
        if (dot < 0) throw new Error('malformed pq payload');
        const cipherText = b64uDecode(content.slice(PQ_PREFIX.length, dot));
        if (cipherText.length !== PQ_KEM_CT_LEN) throw new Error('bad ml-kem ciphertext');
        // ML-KEM decapsulation is designed never to fail: on a malformed
        // ciphertext the FO transform returns an implicit-rejection secret, so a
        // wrong key surfaces as an HMAC failure inside nip44.decrypt below
        // rather than as a distinguishable error here.
        const sharedSecret = kem.decapsulate(cipherText, self.kemSk);
        const ck = pqConversationKey(
            ecdhSharedX(self.sk, senderSecpPkHex), sharedSecret, cipherText, self.kemPk,
            senderSecpPkHex, T.getPublicKey(self.sk)
        );
        return T.nip44.decrypt(content.slice(dot + 1), ck);
    }

    // Deterministic ML-KEM identity key.
    //
    // ML-KEM keygen is a pure function of a 64-byte seed, so the keypair is
    // re-derivable from the nsec on any device: nothing new to back up, and
    // every device sharing an nsec derives the SAME key (which is what makes a
    // single replaceable announcement per identity correct). `epoch` bumps to
    // rotate.
    function pqDeriveSeed(privkey, epoch) {
        const T = NT();
        const prk = T._hkdfExtract(T._sha256, privkey, enc.encode(PQ_SEED_SALT));
        return T._hkdfExpand(T._sha256, prk, enc.encode('mlkem768/epoch/' + (epoch >>> 0)), 64);
    }

    function pqKeygen(seed) {
        const kem = MK();
        if (!kem) throw new Error('ml-kem unavailable');
        return kem.keygen(seed);
    }

    function pqKeypairFromPrivkey(privkey, epoch) {
        return pqKeygen(pqDeriveSeed(privkey, epoch));
    }

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

    // Hybrid post-quantum NIP-59 gift wrap.
    function pqNip59Wrap(event, sk, recipientPub, recipientKemPk, expirationTs) {
        const T = NT();
        const rumor = { created_at: Math.floor(Date.now() / 1000), content: '', tags: [], ...event, pubkey: T.getPublicKey(sk) };
        rumor.id = T.getEventHash(rumor);
        const seal = T.finalizeEvent({
            kind: 13,
            content: pqEncrypt(JSON.stringify(rumor), sk, recipientPub, recipientKemPk),
            created_at: randomNow(),
            tags: []
        }, sk);
        const ephSk = T.generateSecretKey();
        const wrap = {
            kind: 1059,
            content: pqEncrypt(JSON.stringify(seal), ephSk, recipientPub, recipientKemPk),
            created_at: randomNow(),
            tags: [['p', recipientPub]],
            pubkey: T.getPublicKey(ephSk)
        };
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
    // [{ sk, bitchat, selfId?, kemSk?, kemPk? }]. Returns
    // { seal, rumor, isBitchat, isPq, idx } or null.
    //
    // Transport is selected by inspecting the payload, not by trusting a tag:
    // 'pq1.' -> hybrid post-quantum, 'v2:' -> bitchat, otherwise plain NIP-44.
    // A candidate without ML-KEM material simply fails the PQ branch and falls
    // through to the next candidate, so mixed-capability key sets are safe.
    function unwrapGiftWrap(event, candidates) {
        const T = NT();
        const isV2 = (c) => typeof c === 'string' && c.startsWith('v2:');
        for (let i = 0; i < candidates.length; i++) {
            const { sk, bitchat, selfId, kemSk, kemPk } = candidates[i];
            try {
                let seal, rumor, isBitchat = false, isPq = false;
                if (isPqPayload(event.content)) {
                    if (!kemSk || !kemPk) continue;
                    const self = { sk, kemSk, kemPk };
                    seal = JSON.parse(pqDecrypt(event.content, event.pubkey, self));
                    // The seal is expected to be PQ too (pqNip59Wrap writes
                    // both layers), but accept a NIP-44 seal so a future
                    // wrap-only variant stays readable.
                    rumor = JSON.parse(isPqPayload(seal.content)
                        ? pqDecrypt(seal.content, seal.pubkey, self)
                        : T.nip44.decrypt(seal.content, convKey(sk, seal.pubkey, selfId)));
                    isPq = true;
                } else if (bitchat && isV2(event.content)) {
                    seal = JSON.parse(decryptBitchatRaw(event.content, event.pubkey, sk));
                    rumor = JSON.parse(isV2(seal.content)
                        ? decryptBitchatRaw(seal.content, seal.pubkey, sk)
                        : T.nip44.decrypt(seal.content, convKey(sk, seal.pubkey, selfId)));
                    isBitchat = true;
                } else {
                    seal = JSON.parse(T.nip44.decrypt(event.content, convKey(sk, event.pubkey)));
                    rumor = JSON.parse(T.nip44.decrypt(seal.content, convKey(sk, seal.pubkey, selfId)));
                }
                return { seal, rumor, isBitchat, isPq, idx: i };
            } catch (_) { }
        }
        return null;
    }

    root.NymCrypto = {
        randomNow, encryptBitchat, bitchatWrap, nip59Wrap, minePow, unwrapGiftWrap,
        // Hybrid post-quantum surface.
        pqNip59Wrap, pqEncrypt, pqDecrypt, pqConversationKey, isPqPayload,
        pqDeriveSeed, pqKeygen, pqKeypairFromPrivkey,
        pqAvailable: () => !!MK(),
        _b64uEncode: b64uEncode, _b64uDecode: b64uDecode
    };
})(typeof self !== 'undefined' ? self : this);
