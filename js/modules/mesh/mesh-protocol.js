// mesh-protocol.js - bitchat wire format for the Bluetooth mesh.

(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const MeshConst = {
        serviceUuid: 'f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5c',
        characteristicUuid: 'a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d',
        messageTtl: 7,
        // Web Bluetooth caps a GATT write at 512 bytes, and padding rounds a
        // frame UP to the next block, so the fragment threshold is set where
        // padding still lands on 512 (480 + 16 = 496). Purely a send-side
        // choice: peers reassemble whatever fragmentation they are handed.
        fragmentSizeThreshold: 480,
        maxFragmentSize: 469,
        maxFrameBytes: 512,
        seenPacketCapacity: 1000,
        seenPacketTtlMs: 5 * 60 * 1000,
        stalePeerTimeoutMs: 3 * 60 * 1000,
        announceIntervalMs: 30 * 1000,
        announceJitterMs: 8 * 1000,
        announceIntervalIdleMs: 90 * 1000,
        fragmentTimeoutMs: 30 * 1000,
        relayJitterMinMs: 10,
        relayJitterMaxMs: 220,
        interFragmentDelayMs: 20,
    };

    const MsgType = {
        announce: 0x01,
        message: 0x02,
        leave: 0x03,
        // Store-and-forward envelope carried by another peer on the sender's
        // behalf. Opaque to whoever carries it (mesh-courier.js).
        courierEnvelope: 0x04,
        noiseHandshake: 0x10,
        noiseEncrypted: 0x11,
        fragment: 0x20,
        requestSync: 0x21,
        fileTransfer: 0x22,
        // A signed batch of one-time prekeys, gossiped mesh-wide so courier
        // mail can be sealed to a key its owner DELETES after use.
        prekeyBundle: 0x24,
        // Directed echo request / reply — mesh diagnostics.
        ping: 0x26,
        pong: 0x27,
        // Gateway mode: a signed Nostr event ferried between a mesh-only peer
        // and a peer that has internet.
        nostrCarrier: 0x28,
        voiceFrame: 0x29,
        nymProfileRequest: 0x50,
        nymProfileResponse: 0x51,
        nymTyping: 0x52,
        nymReaction: 0x53,
        nymChannelMessage: 0x54,
    };

    const NoisePayloadType = {
        privateMessage: 0x01,
        readReceipt: 0x02,
        delivered: 0x03,
        fileTransfer: 0x20,
        authenticatedPeerState: 0x21,
        reaction: 0x70,
    };

    const BROADCAST_RECIPIENT = new Uint8Array(8).fill(0xFF);

    // byte helpers
    const toHex = (b) => Array.from(b, x => x.toString(16).padStart(2, '0')).join('');
    function fromHex(h) {
        const clean = String(h || '').replace(/[^0-9a-fA-F]/g, '');
        const out = new Uint8Array(clean.length >> 1);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.substr(i * 2, 2), 16);
        return out;
    }
    const utf8 = new TextEncoder();
    const utf8d = new TextDecoder('utf-8', { fatal: false });
    const bytesEqual = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

    class Writer {
        constructor(capacity) { this.buf = new Uint8Array(capacity || 512); this.pos = 0; }
        _ensure(n) {
            if (this.pos + n <= this.buf.length) return;
            let len = this.buf.length * 2;
            while (len < this.pos + n) len *= 2;
            const next = new Uint8Array(len);
            next.set(this.buf.subarray(0, this.pos));
            this.buf = next;
        }
        u8(v) { this._ensure(1); this.buf[this.pos++] = v & 0xFF; }
        u16(v) { this._ensure(2); this.buf[this.pos++] = (v >>> 8) & 0xFF; this.buf[this.pos++] = v & 0xFF; }
        u32(v) { this._ensure(4); this.buf[this.pos++] = (v >>> 24) & 0xFF; this.buf[this.pos++] = (v >>> 16) & 0xFF; this.buf[this.pos++] = (v >>> 8) & 0xFF; this.buf[this.pos++] = v & 0xFF; }
        // Millisecond timestamps exceed 2^32, so the high word goes through
        // division rather than a shift (>>> truncates to 32 bits).
        u64(v) {
            this._ensure(8);
            const hi = Math.floor(v / 4294967296);
            const lo = v >>> 0;
            this.buf[this.pos++] = (hi >>> 24) & 0xFF; this.buf[this.pos++] = (hi >>> 16) & 0xFF;
            this.buf[this.pos++] = (hi >>> 8) & 0xFF; this.buf[this.pos++] = hi & 0xFF;
            this.buf[this.pos++] = (lo >>> 24) & 0xFF; this.buf[this.pos++] = (lo >>> 16) & 0xFF;
            this.buf[this.pos++] = (lo >>> 8) & 0xFF; this.buf[this.pos++] = lo & 0xFF;
        }
        bytes(src) { this._ensure(src.length); this.buf.set(src, this.pos); this.pos += src.length; }
        bytesFixed(src, size) {
            this._ensure(size);
            const n = Math.min(src.length, size);
            this.buf.set(src.subarray(0, n), this.pos);
            for (let i = n; i < size; i++) this.buf[this.pos + i] = 0;
            this.pos += size;
        }
        toBytes() { return this.buf.slice(0, this.pos); }
    }

    class Reader {
        constructor(buf) { this.buf = buf; this.offset = 0; }
        u8() { return this.buf[this.offset++]; }
        u16() { const v = (this.buf[this.offset] << 8) | this.buf[this.offset + 1]; this.offset += 2; return v; }
        u32() {
            const b = this.buf, o = this.offset;
            const v = ((b[o] << 24) >>> 0) + (b[o + 1] << 16) + (b[o + 2] << 8) + b[o + 3];
            this.offset += 4; return v;
        }
        u64() {
            const hi = this.u32(), lo = this.u32();
            return hi * 4294967296 + lo;
        }
        take(n) { const out = this.buf.slice(this.offset, this.offset + n); this.offset += n; return out; }
        get remaining() { return this.buf.length - this.offset; }
    }

    // PKCS#7 privacy padding 
    const MessagePadding = {
        blockSizes: [256, 512, 1024, 2048],
        optimalBlockSize(dataSize) {
            const total = dataSize + 16;
            for (const b of MessagePadding.blockSizes) if (total <= b) return b;
            return dataSize;
        },
        pad(data, targetSize) {
            if (data.length >= targetSize) return data;
            const need = targetSize - data.length;
            if (need <= 0 || need > 255) return data;
            const out = new Uint8Array(targetSize);
            out.set(data);
            out.fill(need, data.length);
            return out;
        },
        unpad(data) {
            if (data.length === 0) return data;
            const n = data[data.length - 1];
            if (n <= 0 || n > data.length) return data;
            for (let i = data.length - n; i < data.length; i++) if (data[i] !== n) return data;
            return data.slice(0, data.length - n);
        },
    };

    // packet
    const HEADER_V1 = 14, HEADER_V2 = 16;
    const SENDER_ID_SIZE = 8, RECIPIENT_ID_SIZE = 8, SIGNATURE_SIZE = 64;
    const MAX_PAYLOAD = 10 * 1024 * 1024;
    const FLAG_HAS_RECIPIENT = 0x01, FLAG_HAS_SIGNATURE = 0x02,
        FLAG_IS_COMPRESSED = 0x04, FLAG_HAS_ROUTE = 0x08;

    const headerSize = (v) => (v === 1 ? HEADER_V1 : HEADER_V2);

    function makePacket(o) {
        return {
            version: o.version || 1,
            type: o.type,
            senderID: o.senderID,
            recipientID: o.recipientID || null,
            timestamp: o.timestamp,
            payload: o.payload,
            signature: o.signature || null,
            ttl: o.ttl,
            route: o.route || null,
        };
    }

    const isBroadcast = (p) => !p.recipientID || bytesEqual(p.recipientID, BROADCAST_RECIPIENT);

    function encodePacket(packet, padding) {
        if (padding === undefined) padding = true;
        const payload = packet.payload;
        if (payload.length > MAX_PAYLOAD) return null;

        const version = packet.version;
        const hasRecipient = !!packet.recipientID;
        const hasSignature = !!packet.signature;
        const hasRoute = version >= 2 && packet.route && packet.route.length > 0;
        const routeBytes = hasRoute ? 1 + Math.min(packet.route.length, 255) * SENDER_ID_SIZE : 0;
        const capacity = headerSize(version) + SENDER_ID_SIZE +
            (hasRecipient ? RECIPIENT_ID_SIZE : 0) + routeBytes + payload.length +
            (hasSignature ? SIGNATURE_SIZE : 0) + 16;

        const w = new Writer(Math.max(capacity, 512));
        w.u8(version);
        w.u8(packet.type);
        w.u8(packet.ttl);
        w.u64(packet.timestamp);

        let flags = 0;
        if (hasRecipient) flags |= FLAG_HAS_RECIPIENT;
        if (hasSignature) flags |= FLAG_HAS_SIGNATURE;
        if (hasRoute) flags |= FLAG_HAS_ROUTE;
        w.u8(flags);

        if (version >= 2) w.u32(payload.length);
        else { if (payload.length > 0xFFFF) return null; w.u16(payload.length); }

        w.bytesFixed(packet.senderID, SENDER_ID_SIZE);
        if (hasRecipient) w.bytesFixed(packet.recipientID, RECIPIENT_ID_SIZE);
        if (hasRoute) {
            const count = Math.min(packet.route.length, 255);
            w.u8(count);
            for (let i = 0; i < count; i++) w.bytesFixed(packet.route[i], SENDER_ID_SIZE);
        }
        w.bytes(payload);
        if (hasSignature) w.bytesFixed(packet.signature, SIGNATURE_SIZE);

        const result = w.toBytes();
        return padding ? MessagePadding.pad(result, MessagePadding.optimalBlockSize(result.length)) : result;
    }

    // The bytes an Ed25519 signature covers: no signature, TTL zeroed (it
    // mutates on relay), padded — matching bitchat's toBinaryDataForSigning.
    function packetSigningBytes(packet) {
        return encodePacket(makePacket({
            version: packet.version,
            type: packet.type,
            senderID: packet.senderID,
            recipientID: packet.recipientID,
            timestamp: packet.timestamp,
            payload: packet.payload,
            signature: null,
            ttl: 0,
            route: packet.route,
        }), true);
    }

    function decodePacket(data) {
        const direct = decodePacketCore(data);
        if (direct) return direct;
        const unpadded = MessagePadding.unpad(data);
        if (unpadded.length === data.length) return null;
        return decodePacketCore(unpadded);
    }

    function decodePacketCore(raw) {
        try {
            if (raw.length < HEADER_V1 + SENDER_ID_SIZE) return null;
            const r = new Reader(raw);
            const version = r.u8();
            if (version !== 1 && version !== 2) return null;
            const type = r.u8();
            const ttl = r.u8();
            const timestamp = r.u64();
            const flags = r.u8();
            const hasRecipient = (flags & FLAG_HAS_RECIPIENT) !== 0;
            const hasSignature = (flags & FLAG_HAS_SIGNATURE) !== 0;
            const isCompressed = (flags & FLAG_IS_COMPRESSED) !== 0;
            const hasRoute = version >= 2 && (flags & FLAG_HAS_ROUTE) !== 0;

            const payloadLength = version >= 2 ? r.u32() : r.u16();
            if (payloadLength > MAX_PAYLOAD) return null;

            let expected = headerSize(version) + SENDER_ID_SIZE + payloadLength;
            if (hasRecipient) expected += RECIPIENT_ID_SIZE;
            let routeCount = 0;
            if (hasRoute) {
                let routeOffset = r.offset + SENDER_ID_SIZE;
                if (hasRecipient) routeOffset += RECIPIENT_ID_SIZE;
                if (raw.length >= routeOffset + 1) routeCount = raw[routeOffset];
                expected += 1 + routeCount * SENDER_ID_SIZE;
            }
            if (hasSignature) expected += SIGNATURE_SIZE;
            if (raw.length < expected) return null;

            const senderID = r.take(SENDER_ID_SIZE);
            const recipientID = hasRecipient ? r.take(RECIPIENT_ID_SIZE) : null;

            let route = null;
            if (hasRoute) {
                const count = r.u8();
                if (count > 0) {
                    route = [];
                    for (let i = 0; i < count; i++) route.push(r.take(SENDER_ID_SIZE));
                }
            }

            // bitchat may compress a payload. Inflation is async in the
            // browser, so the compressed bytes are carried out and expanded by
            // decodePacketAsync before the packet is used.
            let payload, compressed = null;
            if (isCompressed) {
                const lenFieldBytes = version >= 2 ? 4 : 2;
                if (payloadLength < lenFieldBytes) return null;
                const originalSize = version >= 2 ? r.u32() : r.u16();
                if (originalSize <= 0 || originalSize > MAX_PAYLOAD) return null;
                const compressedSize = payloadLength - lenFieldBytes;
                if (compressedSize <= 0) return null;
                // Decompression-bomb guard, same ratio bitchat uses.
                if (originalSize / compressedSize > 50000) return null;
                compressed = { originalSize, bytes: r.take(compressedSize) };
                payload = new Uint8Array(0);
            } else {
                payload = r.take(payloadLength);
            }
            const signature = hasSignature ? r.take(SIGNATURE_SIZE) : null;

            const packet = makePacket({ version, type, senderID, recipientID, timestamp, payload, signature, ttl, route });
            if (compressed) packet._compressed = compressed;
            return packet;
        } catch (_) {
            return null;
        }
    }

    async function inflateRaw(bytes) {
        if (typeof DecompressionStream === 'undefined') return null;
        try {
            const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
            return new Uint8Array(await new Response(stream).arrayBuffer());
        } catch (_) {
            return null;
        }
    }

    // Decodes a frame, expanding a compressed payload. Use this on the receive
    // path; decodePacket alone leaves a compressed packet with an empty payload.
    async function decodePacketAsync(data) {
        const packet = decodePacket(data);
        if (!packet || !packet._compressed) return packet;
        const { originalSize, bytes } = packet._compressed;
        const expanded = await inflateRaw(bytes);
        if (!expanded || expanded.length !== originalSize) return null;
        packet.payload = expanded;
        delete packet._compressed;
        return packet;
    }

    // identity announcement TLV 
    const TLV_NICKNAME = 0x01, TLV_NOISE_PUB = 0x02, TLV_SIGNING_PUB = 0x03,
        TLV_CAPABILITIES = 0x05, TLV_NOSTR_LINK = 0x50;

    function encodeAnnouncement(a) {
        const nick = utf8.encode(a.nickname);
        if (nick.length > 255 || a.noisePublicKey.length > 255 || a.signingPublicKey.length > 255) return null;
        const w = new Writer(256);
        const tlv = (t, v) => { w.u8(t); w.u8(v.length); w.bytes(v); };
        tlv(TLV_NICKNAME, nick);
        tlv(TLV_NOISE_PUB, a.noisePublicKey);
        tlv(TLV_SIGNING_PUB, a.signingPublicKey);
        if (a.capabilities && a.capabilities.length <= 255) tlv(TLV_CAPABILITIES, a.capabilities);
        if (a.nostrLink && a.nostrLink.length <= 255) tlv(TLV_NOSTR_LINK, a.nostrLink);
        for (const t of (a.unknownTlvs || [])) tlv(t.type, t.value);
        return w.toBytes();
    }

    function decodeAnnouncement(data) {
        let offset = 0;
        const out = { nickname: null, noisePublicKey: null, signingPublicKey: null, capabilities: null, nostrLink: null, unknownTlvs: [] };
        while (offset + 2 <= data.length) {
            const type = data[offset], length = data[offset + 1];
            offset += 2;
            if (offset + length > data.length) return null;
            const value = data.slice(offset, offset + length);
            offset += length;
            if (type === TLV_NICKNAME) out.nickname = utf8d.decode(value);
            else if (type === TLV_NOISE_PUB) out.noisePublicKey = value;
            else if (type === TLV_SIGNING_PUB) out.signingPublicKey = value;
            else if (type === TLV_CAPABILITIES) out.capabilities = value;
            else if (type === TLV_NOSTR_LINK) out.nostrLink = value;
            else out.unknownTlvs.push({ type, value });
        }
        if (!out.nickname || !out.noisePublicKey || !out.signingPublicKey) return null;
        return out;
    }

    // BitchatMessage TLV (named/encrypted channel messages) 
    const MSG_FLAG_RELAY = 0x01, MSG_FLAG_PRIVATE = 0x02, MSG_FLAG_ORIG_SENDER = 0x04,
        MSG_FLAG_RECIPIENT_NICK = 0x08, MSG_FLAG_SENDER_PEER = 0x10,
        MSG_FLAG_MENTIONS = 0x20, MSG_FLAG_CHANNEL = 0x40, MSG_FLAG_ENCRYPTED = 0x80;

    function encodeBitchatMessage(m) {
        const w = new Writer(256);
        let flags = 0;
        if (m.isRelay) flags |= MSG_FLAG_RELAY;
        if (m.isPrivate) flags |= MSG_FLAG_PRIVATE;
        if (m.originalSender != null) flags |= MSG_FLAG_ORIG_SENDER;
        if (m.recipientNickname != null) flags |= MSG_FLAG_RECIPIENT_NICK;
        if (m.senderPeerID != null) flags |= MSG_FLAG_SENDER_PEER;
        if (m.mentions && m.mentions.length) flags |= MSG_FLAG_MENTIONS;
        if (m.channel != null) flags |= MSG_FLAG_CHANNEL;
        if (m.isEncrypted) flags |= MSG_FLAG_ENCRYPTED;
        w.u8(flags);
        w.u64(m.timestampMs);
        const p8 = (s) => { const b = utf8.encode(s); w.u8(b.length); w.bytes(b); };
        p8(m.id);
        p8(m.sender);
        const body = (m.isEncrypted && m.encryptedContent) ? m.encryptedContent : utf8.encode(m.content || '');
        w.u16(body.length); w.bytes(body);
        if (m.originalSender != null) p8(m.originalSender);
        if (m.recipientNickname != null) p8(m.recipientNickname);
        if (m.senderPeerID != null) p8(m.senderPeerID);
        if (m.mentions && m.mentions.length) {
            const list = m.mentions.slice(0, 255);
            w.u8(list.length);
            for (const x of list) p8(x);
        }
        if (m.channel != null) p8(m.channel);
        return w.toBytes();
    }

    function decodeBitchatMessage(data) {
        try {
            if (data.length < 13) return null;
            const r = new Reader(data);
            const flags = r.u8();
            const isEncrypted = (flags & MSG_FLAG_ENCRYPTED) !== 0;
            const timestampMs = r.u64();
            const str8 = () => { const n = r.u8(); if (r.remaining < n) return null; return utf8d.decode(r.take(n)); };
            const id = str8(); if (id === null) return null;
            const sender = str8(); if (sender === null) return null;
            const contentLength = r.u16();
            if (r.remaining < contentLength) return null;
            let content = '', encryptedContent = null;
            if (isEncrypted) encryptedContent = r.take(contentLength);
            else content = utf8d.decode(r.take(contentLength));
            const originalSender = (flags & MSG_FLAG_ORIG_SENDER) ? str8() : null;
            const recipientNickname = (flags & MSG_FLAG_RECIPIENT_NICK) ? str8() : null;
            const senderPeerID = (flags & MSG_FLAG_SENDER_PEER) ? str8() : null;
            let mentions = null;
            if ((flags & MSG_FLAG_MENTIONS) && r.remaining > 0) {
                const count = r.u8();
                mentions = [];
                for (let i = 0; i < count && r.remaining > 0; i++) {
                    const v = str8(); if (v === null) break;
                    mentions.push(v);
                }
            }
            const channel = (flags & MSG_FLAG_CHANNEL) && r.remaining > 0 ? str8() : null;
            return { id, sender, content, timestampMs, isEncrypted, encryptedContent, originalSender, recipientNickname, senderPeerID, mentions, channel };
        } catch (_) { return null; }
    }

    // fragments 
    const FRAGMENT_HEADER_SIZE = 13, FRAGMENT_ID_SIZE = 8;

    function encodeFragment(f) {
        const out = new Uint8Array(FRAGMENT_HEADER_SIZE + f.data.length);
        out.set(f.fragmentID, 0);
        out[8] = (f.index >> 8) & 0xFF; out[9] = f.index & 0xFF;
        out[10] = (f.total >> 8) & 0xFF; out[11] = f.total & 0xFF;
        out[12] = f.originalType & 0xFF;
        out.set(f.data, FRAGMENT_HEADER_SIZE);
        return out;
    }

    function decodeFragment(payload) {
        if (payload.length < FRAGMENT_HEADER_SIZE) return null;
        return {
            fragmentID: payload.slice(0, FRAGMENT_ID_SIZE),
            index: (payload[8] << 8) | payload[9],
            total: (payload[10] << 8) | payload[11],
            originalType: payload[12],
            data: payload.slice(FRAGMENT_HEADER_SIZE),
        };
    }

    function fragmentPacket(packet) {
        if (packet.type === MsgType.fragment) return [packet];
        const full = encodePacket(packet, false);
        if (!full) return [];
        if (full.length <= MeshConst.fragmentSizeThreshold) return [packet];

        const hasRoute = packet.route && packet.route.length > 0;
        const overhead = (hasRoute ? 15 : 13) + 8 +
            (packet.recipientID ? 8 : 0) +
            (hasRoute ? 1 + packet.route.length * 8 : 0) +
            FRAGMENT_HEADER_SIZE + 16;
        let maxDataSize = Math.min(MeshConst.fragmentSizeThreshold - overhead, MeshConst.maxFragmentSize);
        if (maxDataSize <= 0) return [];

        const fragmentID = crypto.getRandomValues(new Uint8Array(FRAGMENT_ID_SIZE));
        const chunks = [];
        for (let offset = 0; offset < full.length; offset += maxDataSize) {
            chunks.push(full.slice(offset, Math.min(offset + maxDataSize, full.length)));
        }
        if (chunks.length > 256) return [];

        return chunks.map((chunk, i) => makePacket({
            version: hasRoute ? 2 : 1,
            type: MsgType.fragment,
            senderID: packet.senderID,
            recipientID: packet.recipientID,
            timestamp: packet.timestamp,
            payload: encodeFragment({ fragmentID, index: i, total: chunks.length, originalType: packet.type, data: chunk }),
            ttl: packet.ttl,
            route: packet.route,
        }));
    }

    class FragmentReassembler {
        constructor() { this.assemblies = new Map(); }
        accept(fragment) {
            this._evict();
            if (fragment.total < 1 || fragment.index < 0 || fragment.index >= fragment.total || fragment.total > 256) return null;
            const key = toHex(fragment.fragmentID);
            let a = this.assemblies.get(key);
            if (!a) { a = { total: fragment.total, startedAt: Date.now(), chunks: new Map() }; this.assemblies.set(key, a); }
            if (a.total !== fragment.total) return null;
            a.chunks.set(fragment.index, fragment.data);
            if (a.chunks.size !== a.total) return null;
            let size = 0;
            for (let i = 0; i < a.total; i++) {
                const c = a.chunks.get(i);
                if (!c) return null;
                size += c.length;
            }
            const out = new Uint8Array(size);
            let pos = 0;
            for (let i = 0; i < a.total; i++) { const c = a.chunks.get(i); out.set(c, pos); pos += c.length; }
            this.assemblies.delete(key);
            return out;
        }
        _evict() {
            const now = Date.now();
            for (const [k, a] of this.assemblies) {
                if (now - a.startedAt > MeshConst.fragmentTimeoutMs) this.assemblies.delete(k);
            }
        }
        clear() { this.assemblies.clear(); }
    }

    // dedup 
    class SeenPackets {
        constructor(capacity, ttlMs) {
            this.capacity = capacity || MeshConst.seenPacketCapacity;
            this.ttl = ttlMs || MeshConst.seenPacketTtlMs;
            this.seen = new Map();
        }
        // Keyed on the identity-bearing fields only; TTL mutates on relay, so a
        // relayed copy must dedup against the original.
        static keyFor(type, senderID, timestamp, payload) {
            let h1 = 0x811c9dc5, h2 = 0x01000193;
            const mix = (b) => {
                h1 = (h1 ^ b) >>> 0; h1 = Math.imul(h1, 0x01000193) >>> 0;
                h2 = (h2 + b) >>> 0; h2 = Math.imul(h2, 0x85ebca6b) >>> 0;
            };
            mix(type);
            for (const b of senderID) mix(b);
            mix((timestamp >>> 24) & 0xFF); mix((timestamp >>> 16) & 0xFF);
            mix((timestamp >>> 8) & 0xFF); mix(timestamp & 0xFF);
            for (const b of payload) mix(b);
            return h1.toString(16) + ':' + h2.toString(16) + ':' + payload.length;
        }
        checkAndAdd(key) {
            this._evict();
            const existing = this.seen.get(key);
            if (existing !== undefined && Date.now() - existing < this.ttl) return false;
            this.seen.delete(key);
            this.seen.set(key, Date.now());
            while (this.seen.size > this.capacity) this.seen.delete(this.seen.keys().next().value);
            return true;
        }
        _evict() {
            const now = Date.now();
            for (const [k, t] of this.seen) {
                if (now - t >= this.ttl) this.seen.delete(k); else break;
            }
        }
        clear() { this.seen.clear(); }
    }

    // noise payload envelope 
    function encodeNoisePayload(type, data) {
        const out = new Uint8Array(1 + data.length);
        out[0] = type & 0xFF;
        out.set(data, 1);
        return out;
    }
    function decodeNoisePayload(bytes) {
        if (!bytes.length) return null;
        return { type: bytes[0], data: bytes.slice(1) };
    }

    const PM_TLV_ID = 0x00, PM_TLV_CONTENT = 0x01;
    const PM_MAX_CONTENT_BYTES = 255;

    function encodePrivateMessage(messageID, content) {
        const id = utf8.encode(messageID), body = utf8.encode(content);
        if (id.length > 255 || body.length > 255) return null;
        const w = new Writer(id.length + body.length + 4);
        w.u8(PM_TLV_ID); w.u8(id.length); w.bytes(id);
        w.u8(PM_TLV_CONTENT); w.u8(body.length); w.bytes(body);
        return w.toBytes();
    }

    function decodePrivateMessage(data) {
        let offset = 0, messageID = null, content = null;
        while (offset + 2 <= data.length) {
            const type = data[offset], length = data[offset + 1];
            offset += 2;
            if (offset + length > data.length) return null;
            const value = data.slice(offset, offset + length);
            offset += length;
            if (type === PM_TLV_ID) messageID = utf8d.decode(value);
            else if (type === PM_TLV_CONTENT) content = utf8d.decode(value);
            else return null;
        }
        if (messageID === null || content === null) return null;
        return { messageID, content };
    }

    G.NymMeshProtocol = {
        MeshConst, MsgType, NoisePayloadType, BROADCAST_RECIPIENT,
        toHex, fromHex, bytesEqual, utf8, utf8d, Writer, Reader,
        MessagePadding, makePacket, isBroadcast, encodePacket, decodePacket, decodePacketAsync,
        inflateRaw, packetSigningBytes,
        encodeAnnouncement, decodeAnnouncement,
        encodeBitchatMessage, decodeBitchatMessage,
        encodeFragment, decodeFragment, fragmentPacket, FragmentReassembler,
        SeenPackets,
        encodeNoisePayload, decodeNoisePayload,
        encodePrivateMessage, decodePrivateMessage, PM_MAX_CONTENT_BYTES,
    };
})();
