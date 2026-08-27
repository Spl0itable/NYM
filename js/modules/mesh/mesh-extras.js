// mesh-extras.js - Three more bitchat wire formats.

(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const P = () => G.NymMeshProtocol;
    const C = () => G.NymMeshCrypto;

    const enc = (s) => new TextEncoder().encode(s);

    // PING / PONG 
    const PING_NONCE_LENGTH = 8;

    /// 9 bytes: an 8-byte nonce, then the TTL the packet was LAUNCHED with, so
    /// the far end can derive the hop count from the TTL that arrives.
    function encodePing(nonce, originTtl) {
        if (!nonce || nonce.length !== PING_NONCE_LENGTH) return null;
        const out = new Uint8Array(PING_NONCE_LENGTH + 1);
        out.set(nonce, 0);
        out[PING_NONCE_LENGTH] = originTtl & 0xFF;
        return out;
    }

    /// Accepts trailing bytes so a future revision can extend the format
    /// without older clients refusing to answer.
    function decodePing(data) {
        if (!data || data.length < PING_NONCE_LENGTH + 1) return null;
        return {
            nonce: data.subarray(0, PING_NONCE_LENGTH),
            originTtl: data[PING_NONCE_LENGTH],
        };
    }

    /// Links crossed: the TTL decrements plus the final delivery link, so a
    /// directly connected peer is 1 hop away. Null when the pair is impossible
    /// (received above origin), which means the packet was rewritten rather
    /// than relayed.
    function hopCount(originTtl, receivedTtl) {
        if (originTtl < receivedTtl) return null;
        return (originTtl - receivedTtl) + 1;
    }

    // NOSTR_CARRIER 
    const CARRIER_DIRECTION = {
        toGateway: 0x01,    // mesh-only peer → gateway: publish this for me
        fromGateway: 0x02,  // gateway → mesh: here is what the relays say
        toBridge: 0x03,
        fromBridge: 0x04,
    };
    const CARRIER_MAX_EVENT_BYTES = 16 * 1024;
    const CARRIER_MAX_GEOHASH = 12;

    /// TLV with 2-byte big-endian lengths — a signed event's JSON does not fit
    /// the 1-byte range the smaller packets use.
    function encodeCarrier(direction, geohash, eventJson) {
        const geoBytes = enc(geohash || '');
        if (!geoBytes.length || geoBytes.length > CARRIER_MAX_GEOHASH) return null;
        if (!eventJson || !eventJson.length || eventJson.length > CARRIER_MAX_EVENT_BYTES) return null;
        const parts = [];
        const tlv = (t, v) => parts.push(new Uint8Array([t, (v.length >> 8) & 0xFF, v.length & 0xFF]), v);
        tlv(0x01, new Uint8Array([direction]));
        tlv(0x02, geoBytes);
        tlv(0x03, eventJson);
        return C().concat(...parts);
    }

    /// Null for anything malformed, INCLUDING trailing bytes: a carrier is
    /// published on somebody's behalf, so a payload that does not parse exactly
    /// is refused rather than guessed at.
    function decodeCarrier(data) {
        let off = 0, direction = null, geohash = null, eventJson = null;
        const known = new Set(Object.values(CARRIER_DIRECTION));
        while (off + 3 <= data.length) {
            const t = data[off];
            const len = (data[off + 1] << 8) | data[off + 2];
            off += 3;
            if (off + len > data.length) return null;
            const v = data.subarray(off, off + len);
            off += len;
            if (t === 0x01) {
                if (len !== 1 || !known.has(v[0])) return null;
                direction = v[0];
            } else if (t === 0x02) {
                try { geohash = new TextDecoder('utf-8', { fatal: true }).decode(v); }
                catch (_) { return null; }
            } else if (t === 0x03) {
                eventJson = new Uint8Array(v);
            }
            // Unknown TLV: skipped for forward compatibility.
        }
        if (off !== data.length) return null;
        if (direction === null || geohash === null || eventJson === null) return null;
        if (!geohash.length || geohash.length > CARRIER_MAX_GEOHASH) return null;
        if (!eventJson.length || eventJson.length > CARRIER_MAX_EVENT_BYTES) return null;
        return { direction, geohash, eventJson };
    }

    /// The carried event as an object. The caller MUST still verify the
    /// signature before publishing or displaying it: this parses, it does not
    /// vouch.
    function carrierEvent(carrier) {
        try {
            const parsed = JSON.parse(new TextDecoder().decode(carrier.eventJson));
            return (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) ? parsed : null;
        } catch (_) { return null; }
    }

    // PREKEY_BUNDLE 
    const PREKEY_KEY_LENGTH = 32;
    const PREKEY_SIGNATURE_LENGTH = 64;
    const PREKEY_MAX = 8;
    const PREKEY_ENTRY_LENGTH = 4 + PREKEY_KEY_LENGTH;
    // Domain separation, so a bundle signature can never be mistaken for an
    // announce or packet signature.
    const PREKEY_SIGNING_CONTEXT = 'bitchat-prekey-bundle-v1';

    const beU32 = (v) => {
        const out = new Uint8Array(4);
        new DataView(out.buffer).setUint32(0, v >>> 0, false);
        return out;
    };
    const beU64 = (v) => {
        const out = new Uint8Array(8);
        let n = BigInt(v);
        for (let i = 7; i >= 0; i--) { out[i] = Number(n & 0xFFn); n >>= 8n; }
        return out;
    };
    const padKey = (k) => {
        if (k.length >= PREKEY_KEY_LENGTH) return k.subarray(0, PREKEY_KEY_LENGTH);
        const out = new Uint8Array(PREKEY_KEY_LENGTH);
        out.set(k, 0);
        return out;
    };

    /// The canonical bytes the signature covers. Encoders and verifiers must
    /// derive these identically or every bundle looks forged.
    function prekeySignableBytes(bundle) {
        const ctx = enc(PREKEY_SIGNING_CONTEXT);
        const parts = [new Uint8Array([Math.min(ctx.length, 255)]), ctx.subarray(0, 255),
            padKey(bundle.noiseStaticPublicKey), new Uint8Array([Math.min(bundle.prekeys.length, 255)])];
        for (const pk of bundle.prekeys.slice(0, 255)) {
            parts.push(beU32(pk.id), padKey(pk.publicKey));
        }
        parts.push(beU64(bundle.generatedAtMs));
        return C().concat(...parts);
    }

    function encodePrekeyBundle(bundle) {
        if (!bundle.noiseStaticPublicKey || bundle.noiseStaticPublicKey.length !== PREKEY_KEY_LENGTH) return null;
        if (!bundle.signature || bundle.signature.length !== PREKEY_SIGNATURE_LENGTH) return null;
        if (!bundle.prekeys.length || bundle.prekeys.length > PREKEY_MAX) return null;
        if (bundle.prekeys.some(p => p.publicKey.length !== PREKEY_KEY_LENGTH)) return null;
        const entries = [];
        for (const pk of bundle.prekeys) entries.push(beU32(pk.id), pk.publicKey);
        const packed = C().concat(...entries);
        const parts = [];
        const tlv = (t, v) => parts.push(new Uint8Array([t, (v.length >> 8) & 0xFF, v.length & 0xFF]), v);
        tlv(0x01, bundle.noiseStaticPublicKey);
        tlv(0x02, packed);
        tlv(0x03, beU64(bundle.generatedAtMs));
        tlv(0x04, bundle.signature);
        return C().concat(...parts);
    }

    function decodePrekeyBundle(data) {
        let off = 0, owner = null, prekeys = null, generatedAt = null, signature = null;
        while (off < data.length) {
            const t = data[off]; off += 1;
            if (off + 2 > data.length) return null;
            const len = (data[off] << 8) | data[off + 1]; off += 2;
            if (off + len > data.length) return null;
            const v = data.subarray(off, off + len); off += len;
            if (t === 0x01) {
                if (len !== PREKEY_KEY_LENGTH) return null;
                owner = new Uint8Array(v);
            } else if (t === 0x02) {
                if (!len || len % PREKEY_ENTRY_LENGTH !== 0) return null;
                if (len / PREKEY_ENTRY_LENGTH > PREKEY_MAX) return null;
                const parsed = [];
                for (let i = 0; i < len; i += PREKEY_ENTRY_LENGTH) {
                    let id = 0;
                    for (let j = 0; j < 4; j++) id = (id * 256) + v[i + j];
                    parsed.push({ id, publicKey: new Uint8Array(v.subarray(i + 4, i + PREKEY_ENTRY_LENGTH)) });
                }
                prekeys = parsed;
            } else if (t === 0x03) {
                if (len !== 8) return null;
                let g = 0n; for (const b of v) g = (g << 8n) | BigInt(b);
                generatedAt = Number(g);
            } else if (t === 0x04) {
                if (len !== PREKEY_SIGNATURE_LENGTH) return null;
                signature = new Uint8Array(v);
            }
            // Unknown TLV: skipped for forward compatibility.
        }
        if (!owner || !prekeys || generatedAt === null || !signature) return null;
        if (!prekeys.length) return null;
        // Duplicate ids would let one consumed key shadow another, steering a
        // sender onto a prekey the owner has already thrown away.
        if (new Set(prekeys.map(p => p.id)).size !== prekeys.length) return null;
        return { noiseStaticPublicKey: owner, prekeys, generatedAtMs: generatedAt, signature };
    }

    // How long a consumed key's private half survives. Spray-and-wait means
    // several couriers carry copies of the SAME envelope and arrive whenever
    // their carriers happen to meet us; deleting on first open would make every
    // later copy look like lost mail. 48h, matching bitchat.
    const PREKEY_GRACE_MS = 48 * 60 * 60 * 1000;

    class LocalPrekeys {
        constructor(opts) {
            opts = opts || {};
            this.now = opts.now || (() => Date.now());
            this.batchSize = opts.batchSize || PREKEY_MAX;
            this.graceMs = opts.graceMs || PREKEY_GRACE_MS;
            this.keys = [];
            this.nextId = 1;
        }

        // `== null` rather than falsy: a key consumed at epoch 0 (fake clocks
        // in tests, a device with no time yet) is still a consumed key.
        get available() { return this.keys.filter(k => k.consumedAt == null); }

        /// Mints until `batchSize` unused keys exist. Returns whether anything
        /// was minted, so the caller re-gossips only a bundle that changed.
        async replenish() {
            let minted = false;
            while (this.available.length < this.batchSize) {
                const kp = await C().x25519Generate();
                this.keys.push({ id: this.nextId++, publicKey: kp.publicKey, privateKey: kp.privateKey, consumedAt: null });
                minted = true;
            }
            return minted;
        }

        privateKeyFor(id) {
            const k = this.keys.find(k => k.id === id);
            if (!k) return null;
            if (k.consumedAt != null && this.now() - k.consumedAt > this.graceMs) return null;
            return k.privateKey;
        }

        publicKeyFor(id) {
            const k = this.keys.find(k => k.id === id);
            return k ? k.publicKey : null;
        }

        /// True only on the FIRST open, so the shrunken bundle is republished
        /// once rather than on every redelivery of the same message.
        markConsumed(id) {
            const k = this.keys.find(k => k.id === id);
            if (!k || k.consumedAt != null) return false;
            k.consumedAt = this.now();
            return true;
        }

        /// Deletes consumed keys past their grace window. This is where forward
        /// secrecy actually happens — everything before it is bookkeeping.
        prune() {
            const now = this.now();
            const before = this.keys.length;
            this.keys = this.keys.filter(k => !(k.consumedAt != null && now - k.consumedAt > this.graceMs));
            return this.keys.length !== before;
        }

        /// Random rather than first: two senders picking the same key would burn
        /// it twice, and the second envelope would then depend on the grace
        /// window to open at all.
        chooseFrom(published) {
            if (!published || !published.length) return null;
            return published[Math.floor(Math.random() * published.length)];
        }

        /// Async because a prekey's private half is a WebCrypto key, not
        /// bytes — it has to be exported before it can be written down. Both
        /// halves are stored: WebCrypto cannot re-derive a public key from a
        /// private one, so a restart that kept only the private half could no
        /// longer say which prekey it was.
        async encode() {
            // Byte-at-a-time rather than spreading into fromCharCode: a typed
            // array from another realm is not always spreadable, and a spread
            // blows the call stack on a large array anyway.
            const b64 = (u8) => {
                let s = '';
                for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]);
                return btoa(s);
            };
            const s = G.crypto.subtle;
            const rows = [];
            for (const k of this.keys) {
                let priv;
                try {
                    priv = new Uint8Array(await s.exportKey('pkcs8', k.privateKey));
                } catch (_) {
                    // A key we cannot export is a key we cannot restore. Drop
                    // it from the record rather than write a row that decodes
                    // into mail we can never open.
                    continue;
                }
                rows.push({
                    id: k.id, pub: b64(k.publicKey), priv: b64(priv),
                    ...(k.consumedAt != null ? { used: k.consumedAt } : {}),
                });
            }
            return JSON.stringify({ next: this.nextId, keys: rows });
        }

        async decode(raw) {
            this.keys = [];
            this.nextId = 1;
            if (!raw) return;
            const un = (str) => { const b = atob(str); const u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return u; };
            try {
                const obj = JSON.parse(raw);
                if (!obj || typeof obj !== 'object') return;
                if (typeof obj.next === 'number') this.nextId = obj.next;
                if (!Array.isArray(obj.keys)) return;
                const s = G.crypto.subtle;
                for (const row of obj.keys) {
                    if (!row || typeof row.id !== 'number' || typeof row.pub !== 'string' || typeof row.priv !== 'string') continue;
                    let privateKey;
                    try {
                        privateKey = await s.importKey('pkcs8', un(row.priv), { name: 'X25519' }, true, ['deriveBits']);
                    } catch (_) { continue; }
                    this.keys.push({
                        id: row.id, publicKey: un(row.pub), privateKey,
                        consumedAt: typeof row.used === 'number' ? row.used : null,
                    });
                }
            } catch (_) {
                // A corrupt blob costs the batch, which is replenished on next
                // use — never the launch.
                this.keys = [];
            }
            // Never re-issue an id: a repeat would let new mail be sealed under
            // an id whose private half we already deleted.
            for (const k of this.keys) if (k.id >= this.nextId) this.nextId = k.id + 1;
        }

        clear() { this.keys = []; this.nextId = 1; }
    }

    G.NymMeshExtras = {
        PING_NONCE_LENGTH, encodePing, decodePing, hopCount,
        CARRIER_DIRECTION, CARRIER_MAX_EVENT_BYTES, CARRIER_MAX_GEOHASH,
        encodeCarrier, decodeCarrier, carrierEvent,
        PREKEY_KEY_LENGTH, PREKEY_SIGNATURE_LENGTH, PREKEY_MAX,
        PREKEY_SIGNING_CONTEXT, PREKEY_GRACE_MS,
        prekeySignableBytes, encodePrekeyBundle, decodePrekeyBundle,
        LocalPrekeys,
    };
})();
