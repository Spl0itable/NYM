// mesh-crypto.js - Noise_XX_25519_ChaChaPoly_SHA256 for the Bluetooth mesh.

(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const P = () => G.NymMeshProtocol;

    const subtle = () => (G.crypto && G.crypto.subtle) || null;
    const NOISE_PROTOCOL_NAME = 'Noise_XX_25519_ChaChaPoly_SHA256';
    const HASH_LEN = 32, DH_LEN = 32, TAG_LEN = 16;

    // support probe
    let _supportPromise = null;
    // Web Bluetooth is Chromium-only and X25519/Ed25519 in WebCrypto arrived in
    // recent Chrome, so both are probed rather than assumed.
    function cryptoSupported() {
        if (_supportPromise) return _supportPromise;
        _supportPromise = (async () => {
            const s = subtle();
            if (!s) return false;
            const NT = G.NostrTools;
            if (!NT || !NT._chacha20poly1305) return false;
            try {
                await s.generateKey({ name: 'X25519' }, true, ['deriveBits']);
                await s.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
                return true;
            } catch (_) {
                return false;
            }
        })();
        return _supportPromise;
    }

    // hash / hmac / hkdf
    async function sha256(data) {
        return new Uint8Array(await subtle().digest('SHA-256', data));
    }

    async function hmacSha256(key, data) {
        const k = await subtle().importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
        return new Uint8Array(await subtle().sign('HMAC', k, data));
    }

    function concat(...parts) {
        let len = 0;
        for (const p of parts) len += p.length;
        const out = new Uint8Array(len);
        let pos = 0;
        for (const p of parts) { out.set(p, pos); pos += p.length; }
        return out;
    }

    // Noise HKDF: 1-3 outputs of 32 bytes each.
    async function noiseHkdf(chainingKey, ikm, numOutputs) {
        const tempKey = await hmacSha256(chainingKey, ikm);
        const out1 = await hmacSha256(tempKey, new Uint8Array([0x01]));
        if (numOutputs === 1) return [out1];
        const out2 = await hmacSha256(tempKey, concat(out1, new Uint8Array([0x02])));
        if (numOutputs === 2) return [out1, out2];
        const out3 = await hmacSha256(tempKey, concat(out2, new Uint8Array([0x03])));
        return [out1, out2, out3];
    }

    // X25519 / Ed25519
    async function x25519Generate() {
        const kp = await subtle().generateKey({ name: 'X25519' }, true, ['deriveBits']);
        const pub = new Uint8Array(await subtle().exportKey('raw', kp.publicKey));
        return { privateKey: kp.privateKey, publicKey: pub };
    }

    async function x25519Dh(privateKey, remotePublicBytes) {
        const pub = await subtle().importKey('raw', remotePublicBytes, { name: 'X25519' }, false, []);
        return new Uint8Array(await subtle().deriveBits({ name: 'X25519', public: pub }, privateKey, 256));
    }

    async function ed25519Generate() {
        const kp = await subtle().generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
        const pub = new Uint8Array(await subtle().exportKey('raw', kp.publicKey));
        return { privateKey: kp.privateKey, publicKey: pub };
    }

    async function ed25519Sign(privateKey, message) {
        return new Uint8Array(await subtle().sign({ name: 'Ed25519' }, privateKey, message));
    }

    async function ed25519Verify(publicKeyBytes, signature, message) {
        try {
            const key = await subtle().importKey('raw', publicKeyBytes, { name: 'Ed25519' }, false, ['verify']);
            return await subtle().verify({ name: 'Ed25519' }, key, signature, message);
        } catch (_) {
            return false;
        }
    }

    // AEAD
    // The 12-byte IETF nonce for Noise counter n: four zero bytes then the
    // little-endian 64-bit counter.
    function nonce12(n) {
        const out = new Uint8Array(12);
        let v = n;
        for (let i = 4; i < 12; i++) { out[i] = v & 0xFF; v = Math.floor(v / 256); }
        return out;
    }

    // The AAD is a constructor argument in noble's AEAD, not an encrypt() one.
    const aead = (key, n, ad) => G.NostrTools._chacha20poly1305(key, nonce12(n), ad && ad.length ? ad : undefined);

    function aeadEncrypt(key, n, ad, plaintext) {
        return aead(key, n, ad).encrypt(plaintext);
    }
    function aeadDecrypt(key, n, ad, ciphertext) {
        if (ciphertext.length < TAG_LEN) throw new Error('ciphertext shorter than tag');
        return aead(key, n, ad).decrypt(ciphertext);
    }

    // Noise state machine
    class CipherState {
        constructor(k) { this.k = k || null; this.n = 0; }
        get hasKey() { return this.k !== null; }
        initializeKey(key) { this.k = key; this.n = 0; }
        setNonce(n) { this.n = n; }
        encryptWithAd(ad, plaintext) {
            if (!this.k) return plaintext;
            const ct = aeadEncrypt(this.k, this.n, ad, plaintext);
            this.n++;
            return ct;
        }
        decryptWithAd(ad, ciphertext) {
            if (!this.k) return ciphertext;
            const pt = aeadDecrypt(this.k, this.n, ad, ciphertext);
            this.n++;
            return pt;
        }
    }

    class SymmetricState {
        constructor(ck, h) { this.ck = ck; this.h = h; this.cipher = new CipherState(); }
        static initialize(protocolName) {
            const name = P().utf8.encode(protocolName);
            const h = new Uint8Array(HASH_LEN);
            h.set(name.subarray(0, HASH_LEN));
            return new SymmetricState(h.slice(), h);
        }
        get hasKey() { return this.cipher.hasKey; }
        async mixKey(ikm) {
            const out = await noiseHkdf(this.ck, ikm, 2);
            this.ck = out[0];
            this.cipher.initializeKey(out[1]);
        }
        async mixHash(data) { this.h = await sha256(concat(this.h, data)); }
        async encryptAndHash(plaintext) {
            const ct = this.cipher.encryptWithAd(this.h, plaintext);
            await this.mixHash(ct);
            return ct;
        }
        async decryptAndHash(ciphertext) {
            const pt = this.cipher.decryptWithAd(this.h, ciphertext);
            await this.mixHash(ciphertext);
            return pt;
        }
        async split() {
            const out = await noiseHkdf(this.ck, new Uint8Array(0), 2);
            return [new CipherState(out[0]), new CipherState(out[1])];
        }
    }

    // XX: -> e | <- e, ee, s, es | -> s, se
    const XX_PATTERNS = [['e'], ['e', 'ee', 's', 'es'], ['s', 'se']];

    class HandshakeState {
        constructor(isInitiator, sym, staticPrivate, staticPublic) {
            this.isInitiator = isInitiator;
            this.sym = sym;
            this.sPriv = staticPrivate;
            this.sPub = staticPublic;
            this.ePriv = null;
            this.re = null;
            this.rs = null;
            this.msgIndex = 0;
        }
        static async xx(isInitiator, staticPrivate, staticPublic) {
            const sym = SymmetricState.initialize(NOISE_PROTOCOL_NAME);
            await sym.mixHash(new Uint8Array(0)); // empty prologue, still mixed
            return new HandshakeState(isInitiator, sym, staticPrivate, staticPublic);
        }
        get isComplete() { return this.msgIndex >= XX_PATTERNS.length; }
        get remoteStaticPublicKey() { return this.rs; }
        get handshakeHash() { return this.sym.h; }

        async _token(token) {
            if (token === 'ee') return this.sym.mixKey(await x25519Dh(this.ePriv, this.re));
            if (token === 'es') {
                return this.sym.mixKey(this.isInitiator
                    ? await x25519Dh(this.ePriv, this.rs)
                    : await x25519Dh(this.sPriv, this.re));
            }
            if (token === 'se') {
                return this.sym.mixKey(this.isInitiator
                    ? await x25519Dh(this.sPriv, this.re)
                    : await x25519Dh(this.ePriv, this.rs));
            }
        }

        async writeMessage() {
            const pattern = XX_PATTERNS[this.msgIndex];
            const parts = [];
            for (const token of pattern) {
                if (token === 'e') {
                    const kp = await x25519Generate();
                    this.ePriv = kp.privateKey;
                    parts.push(kp.publicKey);
                    await this.sym.mixHash(kp.publicKey);
                } else if (token === 's') {
                    parts.push(await this.sym.encryptAndHash(this.sPub));
                } else {
                    await this._token(token);
                }
            }
            parts.push(await this.sym.encryptAndHash(new Uint8Array(0)));
            this.msgIndex++;
            return concat(...parts);
        }

        async readMessage(message) {
            const pattern = XX_PATTERNS[this.msgIndex];
            let offset = 0;
            for (const token of pattern) {
                if (token === 'e') {
                    this.re = message.slice(offset, offset + DH_LEN);
                    offset += DH_LEN;
                    await this.sym.mixHash(this.re);
                } else if (token === 's') {
                    const len = DH_LEN + (this.sym.hasKey ? TAG_LEN : 0);
                    const temp = message.slice(offset, offset + len);
                    offset += len;
                    this.rs = await this.sym.decryptAndHash(temp);
                } else {
                    await this._token(token);
                }
            }
            const payload = message.slice(offset);
            const clear = await this.sym.decryptAndHash(payload);
            this.msgIndex++;
            return clear;
        }

        split() { return this.sym.split(); }
    }

    // session
    const NONCE_SIZE = 4, REPLAY_WINDOW_SIZE = 1024, REPLAY_WINDOW_BYTES = 128;
    const UINT32_MAX = 0xFFFFFFFF;

    class NoiseSession {
        constructor(peerID, isInitiator, staticPrivate, staticPublic) {
            this.peerID = peerID;
            this.isInitiator = isInitiator;
            this.staticPrivate = staticPrivate;
            this.staticPublic = staticPublic;
            this.handshake = null;
            this.sendCipher = null;
            this.receiveCipher = null;
            this.remoteStaticPublicKey = null;
            this.state = 'uninitialized';
            this.messagesSent = 0;
            this.highestReceivedNonce = 0;
            this.replayWindow = new Uint8Array(REPLAY_WINDOW_BYTES);
            this.createdAt = Date.now();
        }
        get isEstablished() { return this.state === 'established'; }

        async startHandshake() {
            if (!this.isInitiator) throw new Error('Only the initiator can start a handshake');
            this.handshake = await HandshakeState.xx(true, this.staticPrivate, this.staticPublic);
            this.state = 'handshaking';
            return this.handshake.writeMessage();
        }

        async processHandshakeMessage(data) {
            if (!this.handshake) {
                this.handshake = await HandshakeState.xx(this.isInitiator, this.staticPrivate, this.staticPublic);
                this.state = 'handshaking';
            }
            await this.handshake.readMessage(data);
            if (this.handshake.isComplete) { await this._complete(); return null; }
            const response = await this.handshake.writeMessage();
            if (this.handshake.isComplete) await this._complete();
            return response;
        }

        async _complete() {
            const hs = this.handshake;
            this.remoteStaticPublicKey = hs.remoteStaticPublicKey;
            const [c1, c2] = await hs.split();
            this.sendCipher = this.isInitiator ? c1 : c2;
            this.receiveCipher = this.isInitiator ? c2 : c1;
            this.messagesSent = 0;
            this.highestReceivedNonce = 0;
            this.replayWindow = new Uint8Array(REPLAY_WINDOW_BYTES);
            this.handshake = null;
            this.state = 'established';
        }

        // Transport frame: <4-byte BE counter><ciphertext||tag>.
        encrypt(data) {
            if (!this.isEstablished) throw new Error('Session not established');
            if (this.messagesSent >= UINT32_MAX) throw new Error('Nonce exhausted');
            const nonce = this.messagesSent;
            this.sendCipher.setNonce(nonce);
            const ct = this.sendCipher.encryptWithAd(new Uint8Array(0), data);
            this.messagesSent++;
            const out = new Uint8Array(NONCE_SIZE + ct.length);
            out[0] = (nonce >>> 24) & 0xFF; out[1] = (nonce >>> 16) & 0xFF;
            out[2] = (nonce >>> 8) & 0xFF; out[3] = nonce & 0xFF;
            out.set(ct, NONCE_SIZE);
            return out;
        }

        decrypt(payload) {
            if (!this.isEstablished) throw new Error('Session not established');
            if (payload.length < NONCE_SIZE) throw new Error('Transport frame too small');
            const nonce = ((payload[0] << 24) >>> 0) + (payload[1] << 16) + (payload[2] << 8) + payload[3];
            if (!this._validNonce(nonce)) throw new Error('Replay detected');
            this.receiveCipher.setNonce(nonce);
            const pt = this.receiveCipher.decryptWithAd(new Uint8Array(0), payload.slice(NONCE_SIZE));
            this._markSeen(nonce);
            return pt;
        }

        _validNonce(nonce) {
            if (nonce + REPLAY_WINDOW_SIZE <= this.highestReceivedNonce) return false;
            if (nonce > this.highestReceivedNonce) return true;
            const offset = this.highestReceivedNonce - nonce;
            return (this.replayWindow[offset >> 3] & (1 << (offset % 8))) === 0;
        }

        _markSeen(nonce) {
            if (nonce > this.highestReceivedNonce) {
                const shift = nonce - this.highestReceivedNonce;
                if (shift >= REPLAY_WINDOW_SIZE) {
                    this.replayWindow = new Uint8Array(REPLAY_WINDOW_BYTES);
                } else {
                    const next = new Uint8Array(REPLAY_WINDOW_BYTES);
                    for (let i = REPLAY_WINDOW_BYTES - 1; i >= 0; i--) {
                        const src = i - (shift >> 3);
                        let b = 0;
                        if (src >= 0) {
                            b = (this.replayWindow[src] & 0xFF) >>> (shift % 8);
                            if (src > 0 && shift % 8 !== 0) b |= (this.replayWindow[src - 1] & 0xFF) << (8 - shift % 8);
                        }
                        next[i] = b & 0xFF;
                    }
                    this.replayWindow = next;
                }
                this.highestReceivedNonce = nonce;
                this.replayWindow[0] |= 1;
            } else {
                const offset = this.highestReceivedNonce - nonce;
                this.replayWindow[offset >> 3] |= (1 << (offset % 8));
            }
        }
    }

    class NoiseSessionManager {
        constructor(identity) { this.identity = identity; this.sessions = new Map(); }
        isEstablished(peerID) { const s = this.sessions.get(peerID); return !!s && s.isEstablished; }
        isHandshaking(peerID) { const s = this.sessions.get(peerID); return !!s && s.state === 'handshaking'; }
        session(peerID) { return this.sessions.get(peerID); }
        remove(peerID) { this.sessions.delete(peerID); }
        clear() { this.sessions.clear(); }

        async initiateHandshake(peerID) {
            const s = new NoiseSession(peerID, true, this.identity.staticPrivate, this.identity.staticPublic);
            this.sessions.set(peerID, s);
            return s.startHandshake();
        }

        async handleHandshake(peerID, data) {
            const existing = this.sessions.get(peerID);
            // Both sides opened at once: settle it by peerID so exactly one
            // stays the initiator.
            if (existing && existing.isInitiator && existing.state === 'handshaking' && data.length === 32) {
                if (this.identity.peerID > peerID) return null;
                this.sessions.delete(peerID);
            }
            let s = this.sessions.get(peerID);
            if (!s) {
                s = new NoiseSession(peerID, false, this.identity.staticPrivate, this.identity.staticPublic);
                this.sessions.set(peerID, s);
            }
            const response = await s.processHandshakeMessage(data);
            if (s.isEstablished) {
                const remote = s.remoteStaticPublicKey;
                if (!remote || !(await matchesClaimedPeerID(peerID, remote))) {
                    this.sessions.delete(peerID);
                    throw new Error('Noise peerID binding failed for ' + peerID);
                }
            }
            return response;
        }

        encrypt(peerID, plaintext) {
            const s = this.sessions.get(peerID);
            if (!s || !s.isEstablished) throw new Error('No established session');
            return s.encrypt(plaintext);
        }
        decrypt(peerID, payload) {
            const s = this.sessions.get(peerID);
            if (!s || !s.isEstablished) throw new Error('No established session');
            return s.decrypt(payload);
        }
    }

    // public-key recovery from a seed
    // WebCrypto will not hand back the public half of an imported private key,
    // so it is recomputed: X25519 by a scalar multiplication against the base
    // point (via a throwaway JWK round trip), Ed25519 by signing nothing and
    // reading the key back out of a generated pair. Both go through the same
    // JWK export path the platform already supports.
    async function x25519PublicFromSeed(seed) {
        const jwk = {
            kty: 'OKP', crv: 'X25519',
            d: b64url(seed), x: b64url(await x25519BasePoint(seed)),
            key_ops: ['deriveBits'], ext: true,
        };
        const key = await subtle().importKey('jwk', jwk, { name: 'X25519' }, true, ['deriveBits']);
        const pub = await subtle().exportKey('jwk', key);
        return b64urlDecode(pub.x);
    }

    // Curve25519 scalar multiplication by the base point (9), enough to derive
    // a public key from a private seed.
    function x25519BasePoint(seed) {
        const p = (1n << 255n) - 19n;
        const k = Uint8Array.from(seed);
        k[0] &= 248; k[31] &= 127; k[31] |= 64;
        let scalar = 0n;
        for (let i = 31; i >= 0; i--) scalar = (scalar << 8n) | BigInt(k[i]);
        const inv = (a) => {
            let r = 1n, b = a % p, e = p - 2n;
            while (e > 0n) { if (e & 1n) r = (r * b) % p; b = (b * b) % p; e >>= 1n; }
            return r;
        };
        let x1 = 9n, x2 = 1n, z2 = 0n, x3 = 9n, z3 = 1n, swap = 0n;
        for (let t = 254; t >= 0; t--) {
            const kt = (scalar >> BigInt(t)) & 1n;
            swap ^= kt;
            if (swap) { [x2, x3] = [x3, x2]; [z2, z3] = [z3, z2]; }
            swap = kt;
            const a = (x2 + z2) % p, aa = (a * a) % p;
            const b = (x2 - z2 + p) % p, bb = (b * b) % p;
            const e = (aa - bb + p) % p;
            const c = (x3 + z3) % p, d = (x3 - z3 + p) % p;
            const da = (d * a) % p, cb = (c * b) % p;
            x3 = (da + cb) % p; x3 = (x3 * x3) % p;
            z3 = (da - cb + p) % p; z3 = (z3 * z3) % p; z3 = (z3 * x1) % p;
            x2 = (aa * bb) % p;
            z2 = (e * ((aa + 121665n * e) % p)) % p;
        }
        if (swap) { [x2, x3] = [x3, x2]; [z2, z3] = [z3, z2]; }
        const out = (x2 * inv(z2)) % p;
        const bytes = new Uint8Array(32);
        let v = out;
        for (let i = 0; i < 32; i++) { bytes[i] = Number(v & 0xFFn); v >>= 8n; }
        return bytes;
    }

    async function ed25519PublicFromSeed(seed) {
        const key = await subtle().importKey('pkcs8', MeshIdentity._pkcs8(seed, 0x70), { name: 'Ed25519' }, true, ['sign']);
        const jwk = await subtle().exportKey('jwk', key);
        return b64urlDecode(jwk.x);
    }

    const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    function b64urlDecode(s) {
        let t = String(s).replace(/-/g, '+').replace(/_/g, '/');
        while (t.length % 4) t += '=';
        return Uint8Array.from(atob(t), c => c.charCodeAt(0));
    }

    // identity
    const IDENTITY_STORAGE_KEY = 'nym_mesh_identity_v1';

    const b64 = {
        encode: (bytes) => btoa(String.fromCharCode(...bytes)),
        decode: (s) => Uint8Array.from(atob(s), c => c.charCodeAt(0)),
    };

    async function derivePeerID(noiseStaticPublicKey) {
        return P().toHex(await sha256(noiseStaticPublicKey)).substring(0, 16);
    }

    async function matchesClaimedPeerID(claimedPeerID, noiseKey) {
        return String(claimedPeerID).toLowerCase() === (await derivePeerID(noiseKey));
    }

    // The device's mesh identity: an X25519 static key (the Noise static, whose
    // hash is the peerID) plus an Ed25519 key that signs announcements.
    class MeshIdentity {
        constructor(fields) { Object.assign(this, fields); }

        static async fromKeys(staticPrivate, staticPublic, signPrivate, signPublic) {
            const fingerprint = P().toHex(await sha256(staticPublic));
            return new MeshIdentity({
                staticPrivate, staticPublic, signPrivate, signPublic,
                fingerprint, peerID: fingerprint.substring(0, 16),
            });
        }

        // RFC 8410 PKCS#8 wrappers, so a raw 32-byte seed can be imported as a
        // WebCrypto key. Lets a stored seed (and a test vector) round-trip.
        static _pkcs8(seed, oidByte) {
            const out = new Uint8Array(48);
            out.set([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, oidByte, 0x04, 0x22, 0x04, 0x20]);
            out.set(seed, 16);
            return out;
        }

        static async fromSeeds(staticSeed, signSeed) {
            const s = subtle();
            const staticPrivate = await s.importKey('pkcs8', MeshIdentity._pkcs8(staticSeed, 0x6e), { name: 'X25519' }, true, ['deriveBits']);
            const signPrivate = await s.importKey('pkcs8', MeshIdentity._pkcs8(signSeed, 0x70), { name: 'Ed25519' }, true, ['sign']);
            // WebCrypto cannot re-derive a public key from a private one, so
            // both are recovered by re-importing as a JWK-less round trip.
            const staticPublic = await x25519PublicFromSeed(staticSeed);
            const signPublic = await ed25519PublicFromSeed(signSeed);
            return MeshIdentity.fromKeys(staticPrivate, staticPublic, signPrivate, signPublic);
        }

        static async generate() {
            const x = await x25519Generate();
            const ed = await ed25519Generate();
            return MeshIdentity.fromKeys(x.privateKey, x.publicKey, ed.privateKey, ed.publicKey);
        }

        // Held in memory only — Ghost Mode mints one per epoch so nothing it
        // advertises ties back to the durable identity.
        static ephemeral() { return MeshIdentity.generate(); }

        static async loadOrCreate() {
            try {
                const raw = localStorage.getItem(IDENTITY_STORAGE_KEY);
                if (raw) {
                    const j = JSON.parse(raw);
                    const s = subtle();
                    const staticPrivate = await s.importKey('pkcs8', b64.decode(j.xPriv), { name: 'X25519' }, true, ['deriveBits']);
                    const signPrivate = await s.importKey('pkcs8', b64.decode(j.edPriv), { name: 'Ed25519' }, true, ['sign']);
                    return MeshIdentity.fromKeys(staticPrivate, b64.decode(j.xPub), signPrivate, b64.decode(j.edPub));
                }
            } catch (_) { /* regenerate below */ }
            const id = await MeshIdentity.generate();
            await id.persist();
            return id;
        }

        async persist() {
            const s = subtle();
            const xPriv = new Uint8Array(await s.exportKey('pkcs8', this.staticPrivate));
            const edPriv = new Uint8Array(await s.exportKey('pkcs8', this.signPrivate));
            try {
                localStorage.setItem(IDENTITY_STORAGE_KEY, JSON.stringify({
                    xPriv: b64.encode(xPriv), xPub: b64.encode(this.staticPublic),
                    edPriv: b64.encode(edPriv), edPub: b64.encode(this.signPublic),
                }));
            } catch (_) { /* storage full or blocked — identity stays in memory */ }
        }

        static forget() {
            try { localStorage.removeItem(IDENTITY_STORAGE_KEY); } catch (_) { }
        }

        get peerIdBytes() { return P().fromHex(this.peerID); }
        sign(message) { return ed25519Sign(this.signPrivate, message); }
    }

    // nostr link
    // Binds a mesh identity to a Nostr identity: a BIP340 signature by the Nostr
    // key over SHA-256("nymmesh-link-v1:" || noiseStaticPublicKey). Only the
    // holder of the Nostr key can produce it, so the link cannot be spoofed.
    const NostrLink = {
        domain: 'nymmesh-link-v1:',
        length: 96,
        async messageHex(noiseStaticPublicKey) {
            const domain = P().utf8.encode(NostrLink.domain);
            return P().toHex(await sha256(concat(domain, noiseStaticPublicKey)));
        },
        build(nostrPubkeyHex, signatureHex) {
            const out = new Uint8Array(NostrLink.length);
            out.set(P().fromHex(nostrPubkeyHex.padStart(64, '0')), 0);
            out.set(P().fromHex(signatureHex.padStart(128, '0')), 32);
            return out;
        },
        async verify(value, noiseStaticPublicKey) {
            if (!value || value.length !== NostrLink.length) return null;
            try {
                const pubkeyHex = P().toHex(value.subarray(0, 32));
                const sigHex = P().toHex(value.subarray(32, 96));
                const msgHex = await NostrLink.messageHex(noiseStaticPublicKey);
                const ok = G.NostrTools._secp256k1.schnorr.verify(sigHex, msgHex, pubkeyHex);
                return ok ? pubkeyHex : null;
            } catch (_) {
                return null;
            }
        },
    };

    G.NymMeshCrypto = {
        cryptoSupported, sha256, hmacSha256, noiseHkdf, concat,
        x25519Generate, x25519Dh, ed25519Generate, ed25519Sign, ed25519Verify,
        nonce12, aeadEncrypt, aeadDecrypt,
        CipherState, SymmetricState, HandshakeState, NoiseSession, NoiseSessionManager,
        MeshIdentity, derivePeerID, matchesClaimedPeerID, NostrLink,
        NOISE_PROTOCOL_NAME, IDENTITY_STORAGE_KEY,
    };
})();
