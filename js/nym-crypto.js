// NostrTools crypto shared by the main thread and the crypto worker

(function (root) {
    const NT = () => root.NostrTools;
    const MK = () => root.NymMlKem && root.NymMlKem.ml_kem768;
    const enc = new TextEncoder();
    const dec = new TextDecoder();
    let _ckCache = new Map(), _ckBasis = null;

    // Hybrid post-quantum key agreement (Nymchat <-> Nymchat only).
    const PQ_PREFIX = 'pq1.';
    const PQ2_PREFIX = 'pq2.';
    const PQ2_SALT = 'nymchat-pq2-v1';
    const PQ2_LABEL = 'nymchat-pq2';
    const PQ_COMBINER_SALT = 'nymchat-pq-v1';
    const PQ_SEED_SALT = 'nym-pq-v1';
    const PQ_KEM_CT_LEN = 1088;
    const PQ_KEM_PK_LEN = 1184;

    // v2 root secret
    const PQ_ROOT_SEED_SALT = 'nym-pq-root-v2';
    const PQ_ROOT_LEN = 32;
    const PQ_ROOT_HRP = 'nympq';
    const PQ_ROOT_FP_SALT = 'nym-pq-root-fp-v1';
    const PQ_ROOT_FP_LEN = 8;
    const PQ_ROOT_PRF_INFO = 'nym-pq-root-prf-v1';

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

    // pq2: layered, so a signer login can take part 
    // pq1 mixes the ECDH secret and the KEM secret into one key. An extension
    // or NIP-46 signer never returns the raw ECDH x, so it could not join.
    // Here NIP-44 is the inner layer (any signer does it) and the KEM keys an
    // outer AEAD (needs only the root). Both must break. See PQ-ROOT-SPEC A2.

    function isPq2Payload(content) {
        return typeof content === 'string' && content.startsWith(PQ2_PREFIX);
    }

    /// Outer-layer key, nonce and AAD. `ss` is fresh per message so the key is
    /// never reused and a derived nonce is safe.
    function pq2LayerKeys(ss, kemCt, recipKemPk, senderPkHex, recipPkHex) {
        const T = NT();
        const info = concatBytes(
            enc.encode(PQ2_LABEL), hexToBytes(senderPkHex), hexToBytes(recipPkHex),
            kemCt, recipKemPk
        );
        const prk = T._hkdfExtract(T._sha256, ss, enc.encode(PQ2_SALT));
        return {
            key: T._hkdfExpand(T._sha256, prk, concatBytes(info, enc.encode('key')), 32),
            nonce: T._hkdfExpand(T._sha256, prk, concatBytes(info, enc.encode('nonce')), 12),
            aad: info
        };
    }

    /// Wraps an already-encrypted NIP-44 payload in the post-quantum layer.
    /// The caller produced `inner` however it can — local key or signer.
    function pq2Seal(inner, senderPkHex, recipSecpPkHex, recipKemPk) {
        const kem = MK();
        if (!kem) throw new Error('ml-kem unavailable');
        if (!(recipKemPk instanceof Uint8Array) || recipKemPk.length !== PQ_KEM_PK_LEN) {
            throw new Error('bad ml-kem public key');
        }
        if (typeof inner !== 'string' || !inner) throw new Error('bad inner payload');
        const { cipherText, sharedSecret } = kem.encapsulate(recipKemPk);
        const k = pq2LayerKeys(sharedSecret, cipherText, recipKemPk, senderPkHex, recipSecpPkHex);
        const outer = NT()._chacha20poly1305(k.key, k.nonce, k.aad).encrypt(enc.encode(inner));
        return PQ2_PREFIX + b64uEncode(cipherText) + '.' + b64uEncode(outer);
    }

    /// Strips the post-quantum layer, returning the NIP-44 payload inside.
    /// `self` is { kemSk, kemPk }; no secp key is needed here.
    function pq2Open(content, senderPkHex, recipPkHex, self) {
        const kem = MK();
        if (!kem) throw new Error('ml-kem unavailable');
        if (!isPq2Payload(content)) throw new Error('not a pq2 payload');
        const dot = content.indexOf('.', PQ2_PREFIX.length);
        if (dot < 0) throw new Error('malformed pq2 payload');
        const cipherText = b64uDecode(content.slice(PQ2_PREFIX.length, dot));
        if (cipherText.length !== PQ_KEM_CT_LEN) throw new Error('bad ml-kem ciphertext');
        const sharedSecret = kem.decapsulate(cipherText, self.kemSk);
        const k = pq2LayerKeys(sharedSecret, cipherText, self.kemPk, senderPkHex, recipPkHex);
        const outer = b64uDecode(content.slice(dot + 1));
        return dec.decode(NT()._chacha20poly1305(k.key, k.nonce, k.aad).decrypt(outer));
    }

    /// Local-key convenience: both layers here.
    function pq2Encrypt(plaintext, senderSk, recipSecpPkHex, recipKemPk) {
        const T = NT();
        const inner = T.nip44.encrypt(plaintext, T.nip44.getConversationKey(senderSk, recipSecpPkHex));
        return pq2Seal(inner, T.getPublicKey(senderSk), recipSecpPkHex, recipKemPk);
    }

    function pq2Decrypt(content, senderSecpPkHex, self) {
        const T = NT();
        const recipPkHex = T.getPublicKey(self.sk);
        const inner = pq2Open(content, senderSecpPkHex, recipPkHex, self);
        return T.nip44.decrypt(inner, T.nip44.getConversationKey(self.sk, senderSecpPkHex));
    }

    /// pq2 gift wrap: both NIP-59 layers, each layered rather than combined.
    /// The seal's inner NIP-44 is the only part a signer must perform; the
    /// wrap's is keyed to an ephemeral key we mint here.
    function pq2Nip59Wrap(event, sk, recipientPub, recipientKemPk, expirationTs) {
        const T = NT();
        const rumor = { created_at: Math.floor(Date.now() / 1000), content: '', tags: [], ...event, pubkey: T.getPublicKey(sk) };
        rumor.id = T.getEventHash(rumor);
        const seal = T.finalizeEvent({
            kind: 13,
            content: pq2Encrypt(JSON.stringify(rumor), sk, recipientPub, recipientKemPk),
            created_at: randomNow(),
            tags: []
        }, sk);
        const ephSk = T.generateSecretKey();
        const wrap = {
            kind: 1059,
            content: pq2Encrypt(JSON.stringify(seal), ephSk, recipientPub, recipientKemPk),
            created_at: randomNow(),
            tags: [['p', recipientPub]],
            pubkey: T.getPublicKey(ephSk)
        };
        if (expirationTs) wrap.tags.push(['expiration', String(expirationTs)]);
        return T.finalizeEvent(wrap, ephSk);
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

    // v2 root secret. The v1 pair above is never removed — spec §4 keeps it
    // for the life of the identity.

    function pqIsRoot(bytes) {
        return bytes instanceof Uint8Array && bytes.length === PQ_ROOT_LEN;
    }

    function pqAssertRoot(bytes) {
        if (!pqIsRoot(bytes)) throw new Error('bad pq root');
        return bytes;
    }

    /// 32 CSPRNG bytes, generated once per identity.
    function pqGenerateRoot() {
        return crypto.getRandomValues(new Uint8Array(PQ_ROOT_LEN));
    }

    /// seed = HKDF-Expand(HKDF-Extract(salt="nym-pq-root-v2", IKM=pqRoot),
    ///                    info="mlkem768/epoch/" || epoch, 64)
    function pqRootDeriveSeed(rootBytes, epoch) {
        const T = NT();
        pqAssertRoot(rootBytes);
        const prk = T._hkdfExtract(T._sha256, rootBytes, enc.encode(PQ_ROOT_SEED_SALT));
        return T._hkdfExpand(T._sha256, prk, enc.encode('mlkem768/epoch/' + (epoch >>> 0)), 64);
    }

    function pqKeypairFromRoot(rootBytes, epoch) {
        return pqKeygen(pqRootDeriveSeed(rootBytes, epoch));
    }

    /// Public, non-invertible tag: "is the root I hold the one this record
    /// is about?", answerable without any wrap.
    function pqRootFingerprint(rootBytes) {
        const T = NT();
        pqAssertRoot(rootBytes);
        const prk = T._hkdfExtract(T._sha256, rootBytes, enc.encode(PQ_ROOT_FP_SALT));
        const out = T._hkdfExpand(T._sha256, prk, enc.encode('fp'), PQ_ROOT_FP_LEN);
        return Array.from(out).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    // bech32 with a custom HRP. Encoding is nip19.encodeBytes per the spec;
    // decoding is not, because nip19.decode throws `unknown prefix nympq`
    // (checked, see the bech32 tests). So: plain BIP-173 below.
    const BECH32_CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

    function bech32Polymod(values) {
        const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
        let chk = 1;
        for (let i = 0; i < values.length; i++) {
            const top = chk >>> 25;
            chk = ((chk & 0x1ffffff) << 5) ^ values[i];
            for (let j = 0; j < 5; j++) if ((top >>> j) & 1) chk ^= GEN[j];
        }
        return chk >>> 0;
    }

    function bech32HrpExpand(hrp) {
        const out = [];
        for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) >>> 5);
        out.push(0);
        for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) & 31);
        return out;
    }

    /// { prefix, words }, checksum words stripped. Throws on anything
    /// malformed: a bad checksum must never surface as key material.
    function bech32Decode(str, limit) {
        if (typeof str !== 'string') throw new Error('bech32: not a string');
        const s = str.trim();
        if (s.length < 8 || s.length > (limit || 2000)) throw new Error('bech32: bad length');
        const lower = s.toLowerCase();
        if (s !== lower && s !== s.toUpperCase()) throw new Error('bech32: mixed case');
        const sep = lower.lastIndexOf('1');
        if (sep < 1 || sep + 7 > lower.length) throw new Error('bech32: no separator');
        const hrp = lower.slice(0, sep);
        for (let i = 0; i < hrp.length; i++) {
            const c = hrp.charCodeAt(i);
            if (c < 33 || c > 126) throw new Error('bech32: bad hrp');
        }
        const words = [];
        for (let i = sep + 1; i < lower.length; i++) {
            const v = BECH32_CHARSET.indexOf(lower[i]);
            if (v < 0) throw new Error('bech32: bad character');
            words.push(v);
        }
        if (bech32Polymod(bech32HrpExpand(hrp).concat(words)) !== 1) {
            throw new Error('bech32: bad checksum');
        }
        return { prefix: hrp, words: words.slice(0, words.length - 6) };
    }

    /// 5-bit words back to bytes, rejecting non-canonical padding.
    function bech32FromWords(words) {
        let acc = 0, bits = 0;
        const out = [];
        for (let i = 0; i < words.length; i++) {
            const w = words[i];
            if (!Number.isInteger(w) || w < 0 || w > 31) throw new Error('bech32: bad word');
            acc = ((acc << 5) | w) >>> 0;
            bits += 5;
            while (bits >= 8) { bits -= 8; out.push((acc >>> bits) & 0xff); }
        }
        if (bits >= 5 || ((acc << (8 - bits)) & 0xff) !== 0) throw new Error('bech32: bad padding');
        return new Uint8Array(out);
    }

    /// The user-visible form: `nympq1...`. Handled like the nsec.
    function pqRootEncode(rootBytes) {
        pqAssertRoot(rootBytes);
        const T = NT();
        if (!T || !T.nip19 || typeof T.nip19.encodeBytes !== 'function') {
            throw new Error('nip19 unavailable');
        }
        return T.nip19.encodeBytes(PQ_ROOT_HRP, rootBytes);
    }

    function pqRootDecode(str) {
        const { prefix, words } = bech32Decode(str);
        if (prefix !== PQ_ROOT_HRP) throw new Error('not a ' + PQ_ROOT_HRP + ' code');
        const bytes = bech32FromWords(words);
        if (bytes.length !== PQ_ROOT_LEN) throw new Error('bad ' + PQ_ROOT_HRP + ' length');
        return bytes;
    }

    // Root wraps (spec §5). AES-GCM-256 either way; the paths differ only in
    // where the 256-bit key comes from.

    async function aesGcmKey(raw, usages) {
        return crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, usages);
    }

    async function aesGcmSeal(keyRaw, rootBytes, ivIn) {
        const iv = ivIn || crypto.getRandomValues(new Uint8Array(12));
        const key = await aesGcmKey(keyRaw, ['encrypt']);
        const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, rootBytes));
        return { iv, ct };
    }

    async function aesGcmOpen(keyRaw, iv, ct) {
        const key = await aesGcmKey(keyRaw, ['decrypt']);
        const pt = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, ct));
        if (pt.length !== PQ_ROOT_LEN) throw new Error('unwrapped root has the wrong length');
        return pt;
    }

    function readWrapField(wrap, name, len) {
        const v = wrap && wrap[name];
        if (typeof v !== 'string') throw new Error('wrap missing ' + name);
        const b = b64uDecode(v);
        if (len && b.length !== len) throw new Error('wrap has a bad ' + name);
        return b;
    }

    /// AES-GCM(HKDF(prf_output), pqRoot). The caller passes the raw PRF
    /// output; the WebAuthn plumbing stays in the UI layer.
    function prfKeyRaw(prfOutput, salt) {
        const T = NT();
        if (!(prfOutput instanceof Uint8Array) || prfOutput.length < 16) {
            throw new Error('bad prf output');
        }
        const prk = T._hkdfExtract(T._sha256, prfOutput, salt);
        return T._hkdfExpand(T._sha256, prk, enc.encode(PQ_ROOT_PRF_INFO), 32);
    }

    async function pqRootWrapPrf(rootBytes, prfOutput, opts) {
        pqAssertRoot(rootBytes);
        const o = opts || {};
        const salt = o.salt || crypto.getRandomValues(new Uint8Array(16));
        const { iv, ct } = await aesGcmSeal(prfKeyRaw(prfOutput, salt), rootBytes, o.iv);
        return {
            v: 1, kind: 'prf', kdf: 'hkdf-sha256', info: PQ_ROOT_PRF_INFO,
            salt: b64uEncode(salt), iv: b64uEncode(iv), ct: b64uEncode(ct)
        };
    }

    async function pqRootUnwrapPrf(wrap, prfOutput) {
        if (!wrap || wrap.kdf !== 'hkdf-sha256') throw new Error('not a prf wrap');
        const salt = readWrapField(wrap, 'salt', 16);
        const iv = readWrapField(wrap, 'iv', 12);
        const ct = readWrapField(wrap, 'ct');
        return aesGcmOpen(prfKeyRaw(prfOutput, salt), iv, ct);
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
                if (isPq2Payload(event.content)) {
                    if (!kemSk || !kemPk) continue;
                    const self = { sk, kemSk, kemPk };
                    const selfPk = T.getPublicKey(sk);
                    seal = JSON.parse(pq2Decrypt(event.content, event.pubkey, self));
                    rumor = JSON.parse(isPq2Payload(seal.content)
                        ? pq2Decrypt(seal.content, seal.pubkey, self)
                        : T.nip44.decrypt(seal.content, convKey(sk, seal.pubkey, selfId)));
                    isPq = true;
                } else if (isPqPayload(event.content)) {
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
        isPq2Payload, pq2Seal, pq2Open, pq2Encrypt, pq2Decrypt, pq2LayerKeys,
        pq2Nip59Wrap,
        pqDeriveSeed, pqKeygen, pqKeypairFromPrivkey,
        // v2 root secret; v1 above stays forever (spec §4).
        pqGenerateRoot, pqRootDeriveSeed, pqKeypairFromRoot, pqRootFingerprint,
        pqRootEncode, pqRootDecode, pqIsRoot,
        pqRootWrapPrf, pqRootUnwrapPrf,
        PQ_ROOT_HRP, PQ_ROOT_LEN,
        pqAvailable: () => !!MK(),
        _b64uEncode: b64uEncode, _b64uDecode: b64uDecode
    };
})(typeof self !== 'undefined' ? self : this);
