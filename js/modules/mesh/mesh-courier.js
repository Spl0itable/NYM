// mesh-courier.js - Store-and-forward envelopes carried by other peers.

(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const P = () => G.NymMeshProtocol;
    const C = () => G.NymMeshCrypto;

    // Distinct from the interactive `Noise_XX_…` our sessions use, so an X
    // transcript can never be confused with an XX one.
    const COURIER_PROTOCOL_NAME = 'Noise_X_25519_ChaChaPoly_SHA256';
    const COURIER_PROLOGUE = 'bitchat-courier-v1';
    const PREKEY_PROLOGUE = 'bitchat-prekey-v1';
    const TAG_CONTEXT = 'bitchat-courier-tag-v1';

    const TAG_LENGTH = 16;
    // Couriered messages are text-sized; media is out of scope for mail a
    // stranger carries.
    const MAX_CIPHERTEXT_BYTES = 16 * 1024;
    // Matches the sender outbox's retention.
    const MAX_LIFETIME_MS = 24 * 60 * 60 * 1000;
    // Cap on the budget a depositor can claim, so a malicious envelope cannot
    // turn the courier network into an amplifier.
    const MAX_COPIES = 8;
    // Someone else's mail taking up our storage and airtime, so: a small number.
    const CARRY_CAPACITY = 100;
    // Redundancy buys delivery odds; each extra copy also tells one more person
    // that a message exists.
    const MAX_COURIERS_PER_DEPOSIT = 3;

    const enc = (s) => new TextEncoder().encode(s);
    const hex = (b) => [...b].map(x => x.toString(16).padStart(2, '0')).join('');

    /// Seals `payload` to `recipientStaticKey`.
    ///
    /// Deliberately NOT forward secret — that is what makes it usable at all:
    /// the sender has no session with an offline peer to derive keys from, only
    /// their long-term static key. A later compromise of that key exposes
    /// envelopes captured in transit, which is why an established session is
    /// always preferred when the peer is actually reachable.
    /// `prologue` selects the seal format: omitted for a v1 envelope sealed to
    /// the recipient's long-lived static key, or `prekeyPrologue(id)` for a v2
    /// envelope sealed to a one-time prekey — which IS forward secret, because
    /// the recipient deletes that key after use.
    async function sealCourier(payload, recipientStaticKey, senderPriv, senderPub, prologue) {
        if (!recipientStaticKey || recipientStaticKey.length !== 32) {
            throw new Error('recipient static key must be 32 bytes');
        }
        const sym = C().SymmetricState.initialize(COURIER_PROTOCOL_NAME);
        await sym.mixHash(prologue || enc(COURIER_PROLOGUE));
        // Pre-message: the initiator knows the responder's static key.
        await sym.mixHash(recipientStaticKey);

        const parts = [];
        // e
        const eph = await C().x25519Generate();
        parts.push(eph.publicKey);
        await sym.mixHash(eph.publicKey);
        // es
        await sym.mixKey(await C().x25519Dh(eph.privateKey, recipientStaticKey));
        // s (encrypted)
        parts.push(await sym.encryptAndHash(senderPub));
        // ss
        await sym.mixKey(await C().x25519Dh(senderPriv, recipientStaticKey));
        // payload
        parts.push(await sym.encryptAndHash(payload));
        return C().concat(...parts);
    }

    /// Opens an envelope addressed to our static key, returning
    /// `{ payload, senderStaticKey }` with the sender AUTHENTICATED.
    ///
    /// Throws when the ciphertext is not ours — which is the normal case for a
    /// courier testing mail it merely carries, so callers read a throw as "not
    /// for me", never as an error.
    /// `prologue` must match what the sender used, and for a v2 envelope
    /// `localPriv`/`localPub` are the PREKEY halves, not the identity key.
    async function openCourier(ciphertext, localPriv, localPub, prologue) {
        // e (32) + encrypted static (32 + 16) + encrypted payload (>= 16).
        if (!ciphertext || ciphertext.length < 32 + 48 + 16) {
            throw new Error('courier ciphertext too short');
        }
        const sym = C().SymmetricState.initialize(COURIER_PROTOCOL_NAME);
        await sym.mixHash(prologue || enc(COURIER_PROLOGUE));
        // Pre-message: the responder mixes its OWN static key.
        await sym.mixHash(localPub);

        let off = 0;
        const re = ciphertext.subarray(off, off + 32); off += 32;
        await sym.mixHash(re);
        await sym.mixKey(await C().x25519Dh(localPriv, re));
        const encStatic = ciphertext.subarray(off, off + 48); off += 48;
        const rs = await sym.decryptAndHash(encStatic);
        await sym.mixKey(await C().x25519Dh(localPriv, rs));
        const payload = await sym.decryptAndHash(ciphertext.subarray(off));
        return { payload, senderStaticKey: rs };
    }

    /// Domain separation for a PREKEY-sealed (v2) envelope. Distinct from both
    /// the interactive XX transcripts and the static-sealed courier prologue,
    /// and bound to the specific prekey id — so a ciphertext cannot be replayed
    /// against a different prekey than the one it was sealed to.
    function prekeyPrologue(prekeyId) {
        const id = new Uint8Array(4);
        new DataView(id.buffer).setUint32(0, prekeyId >>> 0, false);
        return C().concat(enc(PREKEY_PROLOGUE), id);
    }

    // recipient tags 
    const epochDayFor = (nowMs) => Math.floor(nowMs / 86400000);

    /// The rotating hint for one day. Computable only by a party that already
    /// knows the static key — which is the point: a courier holding the
    /// envelope cannot work out who it is for.
    async function recipientTagFor(noiseStaticKey, epochDay) {
        const day = new Uint8Array(4);
        new DataView(day.buffer).setUint32(0, epochDay >>> 0, false);
        const mac = await C().hmacSha256(noiseStaticKey, C().concat(enc(TAG_CONTEXT), day));
        return mac.subarray(0, TAG_LENGTH);
    }

    /// The tags to test when asking "is this envelope for this peer?".
    /// Spans the adjacent days so an envelope sealed near midnight — or under
    /// clock skew between two phones that never synchronised with anything —
    /// still matches while being carried.
    async function candidateTagsFor(noiseStaticKey, nowMs) {
        const day = epochDayFor(nowMs);
        const out = [];
        for (const d of [day === 0 ? 0 : day - 1, day, day + 1]) {
            out.push(await recipientTagFor(noiseStaticKey, d));
        }
        return out;
    }

    // the envelope 
    const clampCopies = (n) => Math.min(MAX_COPIES, Math.max(1, n | 0));

    /// TLV (type, length16 BE, value): 0x01 tag, 0x02 expiry, 0x03 ciphertext,
    /// 0x04 copies. Copies is omitted when 1, so a carry-only envelope stays
    /// byte-identical to the pre-spray wire form.
    function encodeEnvelope({ recipientTag, expiryMs, ciphertext, copies, prekeyId }) {
        if (!recipientTag || recipientTag.length !== TAG_LENGTH) return null;
        if (!ciphertext || !ciphertext.length || ciphertext.length > MAX_CIPHERTEXT_BYTES) return null;
        const n = clampCopies(copies === undefined ? 1 : copies);
        const parts = [];
        const tlv = (t, v) => parts.push(new Uint8Array([t, (v.length >> 8) & 0xFF, v.length & 0xFF]), v);
        tlv(0x01, recipientTag);
        const exp = new Uint8Array(8);
        let e = BigInt(expiryMs);
        for (let i = 7; i >= 0; i--) { exp[i] = Number(e & 0xFFn); e >>= 8n; }
        tlv(0x02, exp);
        tlv(0x03, ciphertext);
        if (n > 1) tlv(0x04, new Uint8Array([n]));
        // Omitted for a v1 static-sealed envelope so it stays byte-identical
        // to the pre-prekey wire form.
        if (prekeyId != null) {
            const id = new Uint8Array(4);
            new DataView(id.buffer).setUint32(0, prekeyId >>> 0, false);
            tlv(0x05, id);
        }
        return C().concat(...parts);
    }

    /// Returns null for anything malformed. An unknown TLV is skipped so a
    /// newer bitchat can extend the envelope without our refusing to carry it.
    function decodeEnvelope(data) {
        let off = 0, tag = null, expiry = null, ciphertext = null, copies = 1, prekeyId = null;
        while (off < data.length) {
            const t = data[off]; off += 1;
            if (off + 2 > data.length) return null;
            const len = (data[off] << 8) | data[off + 1]; off += 2;
            if (off + len > data.length) return null;
            const v = data.subarray(off, off + len); off += len;
            if (t === 0x01) { if (len !== TAG_LENGTH) return null; tag = new Uint8Array(v); }
            else if (t === 0x02) {
                if (len !== 8) return null;
                let e = 0n; for (const b of v) e = (e << 8n) | BigInt(b);
                expiry = Number(e);
            } else if (t === 0x03) {
                if (!len || len > MAX_CIPHERTEXT_BYTES) return null;
                ciphertext = new Uint8Array(v);
            } else if (t === 0x04) { if (len !== 1) return null; copies = v[0]; }
            else if (t === 0x05) {
                if (len !== 4) return null;
                let id = 0; for (const b of v) id = (id << 8) | b;
                prekeyId = id >>> 0;
            }
        }
        if (!tag || expiry === null || !ciphertext) return null;
        const out = { recipientTag: tag, expiryMs: expiry, ciphertext, copies: clampCopies(copies) };
        if (prekeyId !== null) out.prekeyId = prekeyId;
        return out;
    }

    /// Whether a message to this recipient may be couriered at all.
    ///
    /// The privacy gate, and deliberately conservative:
    ///  * ghost-pinned — NEVER. The peer met us as a ghost and knows us only as
    ///    that; asking a stranger to carry mail for that conversation is
    ///    exactly the link a ghost identity exists to prevent, and the same
    ///    reason the sender outbox refuses to republish it to Nostr.
    ///  * ghosted sender — NEVER. The deposit outlives the epoch: after we
    ///    rotate, someone is still carrying a message that ties the throwaway
    ///    identity to us.
    ///  * no static key — nothing to seal to.
    function mayDeposit({ isGhostPinned, isGhostMode, hasRecipientStaticKey }) {
        if (isGhostPinned) return false;
        if (isGhostMode) return false;
        if (!hasRecipientStaticKey) return false;
        return true;
    }

    /// Whether a peer may be handed mail to carry. Only a VERIFIED peer: an
    /// unverified one is a radio claiming a name, and handing it an envelope
    /// tells an unknown party that we are sending mail.
    function mayCourier({ isVerified, isSelf, isRecipient }) {
        if (isSelf) return false;
        if (isRecipient) return false; // Delivered directly, not couriered.
        return !!isVerified;
    }

    /// The budget passed on at each hand-off — a binary split, keeping the
    /// larger half. At 1 the holder keeps carrying and hands nothing on, which
    /// is what makes it spray-and-WAIT rather than a flood.
    const sprayShare = (copies) => (copies <= 1 ? 0 : Math.floor(copies / 2));
    const keepShare = (copies) => copies - sprayShare(copies);

    // the carried store 
    class CourierStore {
        constructor(opts) {
            opts = opts || {};
            this.now = opts.now || (() => Date.now());
            this.capacity = opts.capacity || CARRY_CAPACITY;
            this.maxCouriersPerDeposit = opts.maxCouriersPerDeposit || MAX_COURIERS_PER_DEPOSIT;
            // key -> { envelope, receivedAt, handedTo:Set }
            this.carried = new Map();
        }

        get size() { return this.carried.size; }

        accept(envelope, key) {
            const now = this.now();
            if (now >= envelope.expiryMs) return false;
            if (this.carried.has(key)) return false;
            this.carried.set(key, { envelope, receivedAt: now, handedTo: new Set() });
            // Oldest-received first: the newest mail has the best chance of
            // still mattering to somebody.
            while (this.carried.size > this.capacity) {
                this.carried.delete(this.carried.keys().next().value);
            }
            return true;
        }

        setCopies(key, copies) {
            const held = this.carried.get(key);
            if (held) held.envelope = { ...held.envelope, copies: clampCopies(copies) };
        }

        markHandedTo(key, peerID) {
            const held = this.carried.get(key);
            if (held) held.handedTo.add(peerID);
        }

        drop(key) { return this.carried.delete(key); }

        prune() {
            const now = this.now();
            const before = this.carried.size;
            for (const [k, v] of [...this.carried]) if (now >= v.envelope.expiryMs) this.carried.delete(k);
            return this.carried.size !== before;
        }

        /// The mail for a peer we have just met, matched on the rotating tag.
        forTags(tags) {
            const wanted = new Set(tags.map(hex));
            return [...this.carried.entries()].filter(([, v]) => wanted.has(hex(v.envelope.recipientTag)));
        }

        /// Mail that still has budget to hand on, excluding what this peer
        /// already has — re-spraying the same peer burns budget without adding
        /// a carrier.
        sprayableTo(peerID) {
            return [...this.carried.entries()]
                .filter(([, v]) => v.envelope.copies > 1 && !v.handedTo.has(peerID));
        }

        clear() { this.carried.clear(); }
    }

    G.NymMeshCourier = {
        sealCourier, openCourier, prekeyPrologue,
        recipientTagFor, candidateTagsFor, epochDayFor,
        encodeEnvelope, decodeEnvelope,
        mayDeposit, mayCourier, sprayShare, keepShare,
        CourierStore,
        COURIER_PROTOCOL_NAME, COURIER_PROLOGUE, PREKEY_PROLOGUE, TAG_LENGTH,
        MAX_CIPHERTEXT_BYTES, MAX_LIFETIME_MS, MAX_COPIES,
        CARRY_CAPACITY, MAX_COURIERS_PER_DEPOSIT,
    };
})();
