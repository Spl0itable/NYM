// pms.js - Private messages: send, open, conversation list, gift wrap DMs, new-PM modal, retry queue
// Methods are attached to NYM.prototype.

Object.assign(NYM.prototype, {

    // Track a sent DM for retry if delivery receipt is not received
    trackPendingDM(eventId, wrappedEvents, recipientPubkey, conversationKey) {
        this.pendingDMs.set(eventId, {
            wrappedEvents, // Array of ['EVENT', wrapped] messages to re-send
            recipientPubkey,
            conversationKey,
            attempts: 0,
            lastAttempt: Date.now(),
            maxAttempts: this.dmRetryMaxAttempts
        });

        // Start the retry checker if not already running
        if (!this.dmRetryInterval) {
            this.dmRetryInterval = setInterval(() => this.retryPendingDMs(), this.dmRetryCheckMs);
        }
    },

    // Retry sending DMs that haven't received a delivery receipt
    retryPendingDMs() {
        if (this.pendingDMs.size === 0) {
            // No pending DMs, stop the interval
            if (this.dmRetryInterval) {
                clearInterval(this.dmRetryInterval);
                this.dmRetryInterval = null;
            }
            return;
        }

        const now = Date.now();

        for (const [eventId, pending] of this.pendingDMs) {
            // Check if this message has been delivered (status upgraded from 'sent')
            const msgs = this.pmMessages.get(pending.conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.id === eventId);
                if (msg && msg.deliveryStatus !== 'sent') {
                    // Delivered or read - remove from pending
                    this.pendingDMs.delete(eventId);
                    continue;
                }
            }

            // Only retry if enough time has passed since last attempt
            if (now - pending.lastAttempt < this.dmRetryCheckMs) continue;

            // Check if max attempts reached
            if (pending.attempts >= pending.maxAttempts) {
                // Mark as failed in the message list
                if (msgs) {
                    const msg = msgs.find(m => m.id === eventId);
                    if (msg && msg.deliveryStatus === 'sent') {
                        msg.deliveryStatus = 'failed';
                        // Invalidate cached DOM for this conversation since status changed
                        this.channelDOMCache.delete(pending.conversationKey);
                        // Update the UI checkmark if visible
                        if (this.inPMMode && this.currentPM === pending.recipientPubkey) {
                            const msgEl = document.querySelector(`[data-message-id="${eventId}"]`);
                            if (msgEl) {
                                let statusEl = msgEl.querySelector('.delivery-status');
                                if (statusEl) {
                                    statusEl.className = 'delivery-status failed';
                                    statusEl.title = 'Failed to deliver - click to retry';
                                    statusEl.textContent = '!';
                                    statusEl.style.cursor = 'pointer';
                                    statusEl.onclick = () => this.manualRetryDM(eventId);
                                }
                            }
                        }
                    }
                }
                this.pendingDMs.delete(eventId);
                continue;
            }

            // Retry: re-send all wrapped events to relays
            pending.attempts++;
            pending.lastAttempt = now;

            for (const wrappedMsg of pending.wrappedEvents) {
                this.sendDMToRelays(wrappedMsg);
            }
        }
    },

    // Manual retry for a failed DM (triggered by clicking the ! indicator)
    manualRetryDM(eventId) {
        const msgs = this.pmMessages.get(this.getPMConversationKey(this.currentPM));
        if (!msgs) return;
        const msg = msgs.find(m => m.id === eventId);
        if (!msg) return;

        // Re-send the original message content
        msg.deliveryStatus = 'sent';

        // Update UI immediately
        const msgEl = document.querySelector(`[data-message-id="${eventId}"]`);
        if (msgEl) {
            let statusEl = msgEl.querySelector('.delivery-status');
            if (statusEl) {
                statusEl.className = 'delivery-status sent';
                statusEl.title = 'Sent';
                statusEl.textContent = '○';
                statusEl.style.cursor = '';
                statusEl.onclick = null;
            }
        }

        // Re-send by composing a new PM to the same recipient
        this.sendNIP17PM(msg.content, msg.conversationPubkey);
    },

    // Called on relay reconnection to retry any pending DMs and catch missed gift wraps
    retryPendingDMsOnReconnect() {
        // Re-request gift wraps since our last known PM to catch any missed during disconnect
        let resolveCatchup;
        this._dmCatchupReady = new Promise(r => { resolveCatchup = r; });

        if (this.pubkey && this.lastPMSyncTime) {
            const since = Math.max(
                this.lastPMSyncTime - 300, // 5-min buffer before last known event
                Math.floor(Date.now() / 1000) - 604800 // at most 7 days back
            );
            const mkSubId = () => Math.random().toString(36).substring(2);

            // Real pubkey catch-up REQ
            const realFilter = { kinds: [1059], '#p': [this.pubkey], since, limit: 200 };

            // Ephemeral pubkey catch-up REQs (independent to prevent linking)
            const ephPks = this._getAllSelfEphemeralPubkeys();

            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                // Pool mode: send through pool proxy to critical shards
                this._poolSendToRole('critical', ['REQ', mkSubId(), realFilter]);
                for (const pk of ephPks) {
                    this._poolSendToRole('critical', ['REQ', mkSubId(), { kinds: [1059], '#p': [pk], since, limit: 100 }]);
                }
            } else {
                // Direct mode: send to all connected relays
                const realReq = JSON.stringify(['REQ', mkSubId(), realFilter]);
                const ephReqs = ephPks.map(pk => JSON.stringify(['REQ', mkSubId(),
                    { kinds: [1059], '#p': [pk], since, limit: 100 }
                ]));
                this.relayPool.forEach(relay => {
                    if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        try { relay.ws.send(realReq); } catch (_) { }
                        for (const req of ephReqs) {
                            try { relay.ws.send(req); } catch (_) { }
                        }
                    }
                });
            }
        }

        // Allow 3 seconds for relays to deliver missed gift wraps (and update ephemeral keys)
        // before allowing outbound group messages to proceed.
        setTimeout(() => resolveCatchup(), 3000);

        if (this.pendingDMs.size === 0) return;

        for (const [eventId, pending] of this.pendingDMs) {
            // Check if already delivered
            const msgs = this.pmMessages.get(pending.conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.id === eventId);
                if (msg && msg.deliveryStatus !== 'sent') {
                    this.pendingDMs.delete(eventId);
                    continue;
                }
            }

            // Re-send all wrapped events
            for (const wrappedMsg of pending.wrappedEvents) {
                this.sendDMToRelays(wrappedMsg);
            }
            pending.lastAttempt = Date.now();
        }
    },

    // Send PM using NIP-17 (GiftWrap 1059) and optional forward secrecy
    async sendNIP17PM(content, recipientPubkey) {
        const now = Math.floor(Date.now() / 1000);

        // Generate message ID for delivery receipts (Nymchat format)
        const nymMessageId = this.generateUUID();

        const rumor = {
            kind: 14,
            created_at: now,
            tags: [
                ['p', recipientPubkey],
                ['x', nymMessageId]  // Nymchat message ID for delivery receipts
            ],
            content,
            pubkey: this.pubkey
        };

        // Optional expiration (NIP-40) on gift wrap level
        const expirationTs = (this.settings?.dmForwardSecrecyEnabled && this.settings?.dmTTLSeconds > 0)
            ? Math.floor(Date.now() / 1000) + this.settings.dmTTLSeconds
            : null;

        // Local key available (ephemeral/nsec)
        if (this.privkey) {
            const NT = window.NostrTools;
            const isKnownBitchat = this.bitchatUsers.has(recipientPubkey);
            const isKnownNym = this.nymUsers.has(recipientPubkey);
            const isUnknownPeer = !isKnownBitchat && !isKnownNym;
            let wrapped;
            let bitchatMessageId = null;
            const sentWrappedEvents = []; // Track wrapped events for retry

            // For known bitchat users OR unknown peers, send bitchat-format wrap
            // This ensures bitchat app users can always decrypt our messages
            if (isKnownBitchat || isUnknownPeer) {
                const encoded = this.encodeBitchatMessage(content, recipientPubkey);
                bitchatMessageId = encoded.messageId;

                const bitchatRumor = {
                    kind: 14,
                    created_at: now,
                    tags: [['x', nymMessageId]],  // Include nymMessageId so reactions match across formats
                    content: encoded.content,
                    pubkey: this.pubkey
                };
                const bitchatWrapped = this.bitchatWrapEvent(bitchatRumor, this.privkey, recipientPubkey, expirationTs);
                this.sendDMToRelays(['EVENT', bitchatWrapped]);
                sentWrappedEvents.push(['EVENT', bitchatWrapped]);
                wrapped = bitchatWrapped;

                // Schedule deletion if redacted cosmetic is active
                if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(bitchatWrapped.id, 1059); }, 600000);
                }
            }

            // For known nymchat users OR unknown peers, send nymchat-format wrap
            // Unknown peers get BOTH formats so either app can decrypt
            if (isKnownNym || isUnknownPeer) {
                const nymWrapped = this.nip59WrapEvent(rumor, this.privkey, recipientPubkey, expirationTs);
                this.sendDMToRelays(['EVENT', nymWrapped]);
                sentWrappedEvents.push(['EVENT', nymWrapped]);
                wrapped = nymWrapped;

                // Schedule deletion if redacted cosmetic is active
                if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(nymWrapped.id, 1059); }, 600000);
                }
            }

            // Send a self-wrap so our own message is retrievable from relays after reload.
            // The outer gift wrap has #p = our pubkey, so our subscription picks it up.
            if (recipientPubkey !== this.pubkey) {
                const selfWrapped = this.nip59WrapEvent(rumor, this.privkey, this.pubkey, expirationTs);
                this.sendDMToRelays(['EVENT', selfWrapped]);
            }

            const conversationKey = this.getPMConversationKey(recipientPubkey);
            if (!this.pmMessages.has(conversationKey)) this.pmMessages.set(conversationKey, []);
            const pmList = this.pmMessages.get(conversationKey);
            pmList.push({
                id: wrapped.id,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                created_at: now,
                _seq: ++this._msgSeq,
                timestamp: new Date(now * 1000),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                bitchatMessageId,  // For tracking Bitchat delivery/read receipts
                nymMessageId,  // Always store for reaction matching (peer may react using nymMessageId from x tag)
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });
            pmList.sort((a, b) => {
                const dt = (a.created_at || 0) - (b.created_at || 0);
                if (dt !== 0) return dt;
                return (a._seq || 0) - (b._seq || 0);
            });
            // Cap PM conversations at pmStorageLimit messages
            if (pmList.length > this.pmStorageLimit) {
                this.pmMessages.set(conversationKey, pmList.slice(-this.pmStorageLimit));
            }

            // Track for automatic retry if delivery receipt not received
            this.trackPendingDM(wrapped.id, sentWrappedEvents, recipientPubkey, conversationKey);

            this.addPMConversation(this.getNymFromPubkey(recipientPubkey), recipientPubkey, Date.now());
            this.movePMToTop(recipientPubkey);

            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(this.pmMessages.get(conversationKey).slice(-1)[0]);
                // Force auto-scroll to bottom after sending own PM
                this._scheduleScrollToBottom();
            }
            return true;
        }

        // Extension or NIP-46 remote signer path (seal via signer, wrap locally)
        const _useExt = !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent);
        const _useN46 = this.nostrLoginMethod === 'nip46' && _nip46State && _nip46State.connected;
        if (_useExt || _useN46) {
            const NT = window.NostrTools;

            rumor.id = NT.getEventHash(rumor);

            // Seal (kind 13) signed by identity via extension or remote signer
            const sealContent = _useExt
                ? await window.nostr.nip44.encrypt(recipientPubkey, JSON.stringify(rumor))
                : await _nip46Encrypt(recipientPubkey, JSON.stringify(rumor));
            const sealUnsigned = {
                kind: 13, content: sealContent, created_at: this.randomNow(), tags: []
            };
            const seal = _useExt
                ? await window.nostr.signEvent(sealUnsigned)
                : await _nip46SignEvent(sealUnsigned);

            // GiftWrap (kind 1059) with local ephemeral
            const ephSk = NT.generateSecretKey();
            const ckWrap = NT.nip44.getConversationKey(ephSk, recipientPubkey);
            const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
            const wrapUnsigned = {
                kind: 1059,
                content: wrapContent,
                created_at: this.randomNow(),
                tags: [['p', recipientPubkey]]
            };

            // Add expiration only if enabled
            if (expirationTs) {
                wrapUnsigned.tags.push(['expiration', String(expirationTs)]);
            }

            const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);

            const sentWrappedEvents = [['EVENT', wrapped]];
            this.sendDMToRelays(['EVENT', wrapped]);

            // Schedule deletion if redacted cosmetic is active
            if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                const eventIdToDelete = wrapped.id;
                setTimeout(() => {
                    this.publishDeletionEvent(eventIdToDelete, 1059);
                }, 600000); // 10 minutes
            }

            // Send a self-wrap so our own message is retrievable from relays after reload.
            if (recipientPubkey !== this.pubkey) {
                try {
                    const selfSealContent = _useExt
                        ? await window.nostr.nip44.encrypt(this.pubkey, JSON.stringify(rumor))
                        : await _nip46Encrypt(this.pubkey, JSON.stringify(rumor));
                    const selfSealUnsigned = {
                        kind: 13, content: selfSealContent, created_at: this.randomNow(), tags: []
                    };
                    const selfSeal = _useExt
                        ? await window.nostr.signEvent(selfSealUnsigned)
                        : await _nip46SignEvent(selfSealUnsigned);
                    const selfEphSk = NT.generateSecretKey();
                    const selfCkWrap = NT.nip44.getConversationKey(selfEphSk, this.pubkey);
                    const selfWrapContent = NT.nip44.encrypt(JSON.stringify(selfSeal), selfCkWrap);
                    const selfWrapUnsigned = {
                        kind: 1059,
                        content: selfWrapContent,
                        created_at: this.randomNow(),
                        tags: [['p', this.pubkey]]
                    };
                    if (expirationTs) selfWrapUnsigned.tags.push(['expiration', String(expirationTs)]);
                    const selfWrapped = NT.finalizeEvent(selfWrapUnsigned, selfEphSk);
                    this.sendDMToRelays(['EVENT', selfWrapped]);
                } catch (_) { /* Self-wrap failed — non-critical */ }
            }

            // Show locally — reuse the rumor's created_at (now) so the local
            // message sorts identically to how the recipient sees it.
            const conversationKey = this.getPMConversationKey(recipientPubkey);
            if (!this.pmMessages.has(conversationKey)) this.pmMessages.set(conversationKey, []);
            const extPmList = this.pmMessages.get(conversationKey);
            extPmList.push({
                id: wrapped.id,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                created_at: now,
                _seq: ++this._msgSeq,
                timestamp: new Date(now * 1000),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                nymMessageId,  // For tracking Nymchat delivery/read receipts
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });
            extPmList.sort((a, b) => {
                const dt = (a.created_at || 0) - (b.created_at || 0);
                if (dt !== 0) return dt;
                return (a._seq || 0) - (b._seq || 0);
            });
            // Cap PM conversations at pmStorageLimit messages
            if (extPmList.length > this.pmStorageLimit) {
                this.pmMessages.set(conversationKey, extPmList.slice(-this.pmStorageLimit));
            }

            // Track for automatic retry if delivery receipt not received
            this.trackPendingDM(wrapped.id, sentWrappedEvents, recipientPubkey, conversationKey);

            this.addPMConversation(this.getNymFromPubkey(recipientPubkey), recipientPubkey, Date.now());
            this.movePMToTop(recipientPubkey);

            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(this.pmMessages.get(conversationKey).slice(-1)[0]);
                // Force auto-scroll to bottom after sending own PM
                this._scheduleScrollToBottom();
            }
            return true;
        }

        throw new Error('No signing/encryption available for NIP-17 (need local privkey, extension, or remote signer)');
    },

    // Receive NIP-17 (GiftWrap 1059): unwrap, verify, store
    async handleGiftWrapDM(event) {
        try {
            const NT = window.NostrTools;

            // Process only gift wraps addressed to me (real pubkey or any ephemeral pubkey)
            if (this.pubkey) {
                const wrapRecipients = [];
                for (const t of event.tags || []) {
                    if (Array.isArray(t) && t[0] === 'p' && typeof t[1] === 'string') {
                        wrapRecipients.push(t[1]);
                    }
                }
                if (wrapRecipients.length > 0) {
                    // Use ALL known ephemeral pubkeys (not the subscription-limited set)
                    // so messages to older keys aren't dropped before decryption.
                    const myEphPks = this._getAllKnownEphemeralPubkeys();
                    const isForMe = wrapRecipients.includes(this.pubkey) ||
                        wrapRecipients.some(r => myEphPks.includes(r));
                    if (!isForMe) return; // not for me
                }
            }

            // Early deduplication - check before expensive decryption
            if (this.processedPMEventIds.has(event.id)) {
                return; // Already processed this event
            }
            this.processedPMEventIds.add(event.id);

            // Update lastPMSyncTime to track newest received PM
            if (event.created_at && event.created_at > this.lastPMSyncTime) {
                this.lastPMSyncTime = event.created_at;
            }

            // Limit Set size to prevent memory leaks (keep last 5000 events)
            if (this.processedPMEventIds.size > 5000) {
                const idsArray = Array.from(this.processedPMEventIds);
                this.processedPMEventIds = new Set(idsArray.slice(-2500));
            }

            // Bitchat uses XChaCha20-Poly1305 with HKDF key derivation
            // Format: v2: + base64url(nonce(24) || ciphertext || tag(16))
            // Key: HKDF(full compressed shared point 33 bytes, salt=empty, info="nip44-v2")
            const decryptBitchat = (content, senderPubkey) => {
                // Strip v2: prefix
                if (content.startsWith('v2:')) {
                    content = content.slice(3);
                }
                // Convert base64url to standard base64
                content = content.replace(/-/g, '+').replace(/_/g, '/');
                while (content.length % 4) content += '=';

                const payload = Uint8Array.from(atob(content), c => c.charCodeAt(0));
                const info = new TextEncoder().encode('nip44-v2');
                const nonce = payload.subarray(0, 24);
                const ciphertextWithTag = payload.subarray(24);

                // Bitchat tries both 02 (even Y) and 03 (odd Y) prefixes for x-only pubkeys
                for (const prefix of ['02', '03']) {
                    try {
                        const sharedPoint = NT._secp256k1.getSharedSecret(this.privkey, prefix + senderPubkey);

                        // Method 5: Full compressed point (33 bytes) -> HKDF
                        const prk = NT._hkdfExtract(NT._sha256, sharedPoint, new Uint8Array(0));
                        const key = NT._hkdfExpand(NT._sha256, prk, info, 32);

                        const plaintext = NT._xchacha20poly1305(key, nonce).decrypt(ciphertextWithTag);
                        return new TextDecoder().decode(plaintext);
                    } catch (e) {
                        // Try other prefix
                    }
                }

                throw new Error('Bitchat decryption failed');
            };

            // Parse Bitchat message format: bitchat1:<base64url payload>
            // Returns { type, content } where type is NoisePayloadType
            // NoisePayloadType: 0x01=PRIVATE_MESSAGE, 0x02=READ_RECEIPT, 0x03=DELIVERED
            const parseBitchatMessage = (content) => {
                if (!content.startsWith('bitchat1:')) {
                    return { type: 0x01, content }; // Not bitchat format, treat as message
                }

                try {
                    // Strip prefix and decode base64url
                    let b64 = content.slice(9); // Remove 'bitchat1:'
                    b64 = b64.replace(/-/g, '+').replace(/_/g, '/');
                    while (b64.length % 4) b64 += '=';

                    const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));

                    // Parse BitchatPacket header to find NoisePayloadType
                    // Header: version(1) + type(1) + TTL(1) + timestamp(8) + flags(1) + payloadLen(2) = 14 bytes
                    // Then: senderID(8) + recipientID(8 if HAS_RECIPIENT) + payload
                    const flags = bytes[11];
                    const hasRecipient = (flags & 0x01) !== 0;
                    const payloadStart = 14 + 8 + (hasRecipient ? 8 : 0); // header + senderID + recipientID?

                    const noisePayloadType = bytes[payloadStart];

                    // For receipts (READ_RECEIPT=0x02, DELIVERED=0x03), extract messageId
                    // Bitchat sends receipts as: [NoisePayloadType][raw messageId string] (no TLV!)
                    if (noisePayloadType !== 0x01) {
                        let pos = payloadStart + 1;
                        let end = bytes.length;
                        while (end > 0 && bytes[end - 1] === 0xBE) end--;

                        let messageId = null;
                        // Check if it's TLV format (starts with 0x00) or raw string
                        if (pos < end && bytes[pos] === 0x00 && pos + 2 < end) {
                            // TLV format: [0x00][len][messageID]
                            const idLen = bytes[pos + 1];
                            if (pos + 2 + idLen <= end) {
                                try {
                                    messageId = new TextDecoder().decode(bytes.subarray(pos + 2, pos + 2 + idLen));
                                } catch (e) { }
                            }
                        } else {
                            // Raw string format (Bitchat sends UUIDs directly)
                            // UUID format: 8-4-4-4-12 = 36 chars (e.g., "07DFE7B7-151D-40D8-BA38-B93...")
                            try {
                                const rawBytes = bytes.subarray(pos, Math.min(pos + 36, end));
                                messageId = new TextDecoder().decode(rawBytes);
                                // Validate it looks like a UUID
                                if (!/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i.test(messageId)) {
                                    messageId = null;
                                }
                            } catch (e) { }
                        }
                        return { type: noisePayloadType, content: null, messageId };
                    }

                    // For PRIVATE_MESSAGE, extract the content and messageId from TLV
                    // TLV format after NoisePayloadType: [0x00][len][messageID][0x01][len][content]
                    let pos = payloadStart + 1; // Skip NoisePayloadType byte
                    let messageContent = null;
                    let messageId = null;

                    // Strip trailing padding (0xBE bytes) for bounds checking
                    let end = bytes.length;
                    while (end > 0 && bytes[end - 1] === 0xBE) end--;

                    // Parse TLV fields
                    while (pos < end - 2) {
                        const fieldType = bytes[pos];
                        const fieldLen = bytes[pos + 1];
                        if (pos + 2 + fieldLen > end) break;

                        if (fieldType === 0x00) { // MESSAGE_ID field
                            try {
                                messageId = new TextDecoder().decode(bytes.subarray(pos + 2, pos + 2 + fieldLen));
                            } catch (e) { }
                        } else if (fieldType === 0x01) { // CONTENT field
                            try {
                                messageContent = new TextDecoder().decode(bytes.subarray(pos + 2, pos + 2 + fieldLen));
                            } catch (e) { }
                        }
                        pos += 2 + fieldLen;
                    }

                    return { type: noisePayloadType, content: messageContent || '', messageId };
                } catch (e) {
                    return { type: 0x01, content };
                }
            };

            // Check if content is Bitchat format (v2: prefix)
            const isBitchatFormat = (content) => content.startsWith('v2:');

            // Unwrap local privkey path
            const unwrapWithLocal = () => {
                let sealJson, seal, rumorJson, rumor;

                if (isBitchatFormat(event.content)) {
                    // Bitchat raw XChaCha20-Poly1305 format
                    sealJson = decryptBitchat(event.content, event.pubkey);
                    seal = JSON.parse(sealJson);

                    if (isBitchatFormat(seal.content)) {
                        rumorJson = decryptBitchat(seal.content, seal.pubkey);
                    } else {
                        const ckSeal = NT.nip44.getConversationKey(this.privkey, seal.pubkey);
                        rumorJson = NT.nip44.decrypt(seal.content, ckSeal);
                    }
                    rumor = JSON.parse(rumorJson);
                } else {
                    // Standard NIP-44 format
                    const ckWrap = NT.nip44.getConversationKey(this.privkey, event.pubkey);
                    sealJson = NT.nip44.decrypt(event.content, ckWrap);
                    seal = JSON.parse(sealJson);

                    const ckSeal = NT.nip44.getConversationKey(this.privkey, seal.pubkey);
                    rumorJson = NT.nip44.decrypt(seal.content, ckSeal);
                    rumor = JSON.parse(rumorJson);
                }

                return { seal, rumor };
            };

            // Unwrap extension-only path (only works for standard NIP-44, not Bitchat)
            const unwrapWithExtension = async () => {
                // Extensions can't do raw ECDH, so Bitchat format won't work
                if (isBitchatFormat(event.content)) {
                    throw new Error('Bitchat format requires local key');
                }

                const sealJson = await window.nostr.nip44.decrypt(event.pubkey, event.content);
                const seal = JSON.parse(sealJson);

                const rumorJson = await window.nostr.nip44.decrypt(seal.pubkey, seal.content);
                const rumor = JSON.parse(rumorJson);

                return { seal, rumor };
            };

            let seal, rumor;
            if (this.privkey) {
                try {
                    ({ seal, rumor } = unwrapWithLocal());
                } catch (_realKeyErr) {
                    // Real privkey failed — try ephemeral keys (timing-attack mitigation scheme)
                    const ephResult = this._tryDecryptWithEphemeralKeys(event);
                    if (ephResult) {
                        ({ seal, rumor } = ephResult);
                    } else {
                        throw _realKeyErr; // re-throw original error
                    }
                }
            } else if (window.nostr?.nip44?.decrypt) {
                try {
                    ({ seal, rumor } = await unwrapWithExtension());
                } catch (_extErr) {
                    // Extension decrypt failed — try ephemeral keys if we have local privkey
                    // (extension can't use ephemeral keys, but we store them locally)
                    const ephResult = this._tryDecryptWithEphemeralKeys(event);
                    if (ephResult) {
                        ({ seal, rumor } = ephResult);
                    } else {
                        throw _extErr;
                    }
                }
            } else {
                return; // no way to decrypt
            }

            // Validate rumor and identity
            // Accept kind 14 (DM), kind 15 (file), kind 69420 (Nymchat receipt),
            // kind 7 (group reaction gift-wrapped to the group),
            // and kind 30078 (encrypted settings sync)
            if (!rumor || (rumor.kind !== 14 && rumor.kind !== 15 && rumor.kind !== 69420 && rumor.kind !== 7 && rumor.kind !== 30078)) {
                return;
            }

            // Route encrypted settings events to settings handler
            if (rumor.kind === 30078) {
                const isOwn = !!this.pubkey && rumor.pubkey === this.pubkey;
                if (isOwn) {
                    try {
                        const s = JSON.parse(rumor.content);
                        const rumorTs = rumor.created_at || 0;
                        // Always merge additive data (group history, ephemeral keys, group list)
                        // from every settings event regardless of timestamp order — older saves
                        // may contain unique messages or keys absent from the newest event.
                        await applyNostrSettingsAdditive(s);
                        // Only apply state-replacing preferences from events newer than what we've seen
                        if (rumorTs > (this._lastSettingsSyncTs || 0)) {
                            this._lastSettingsSyncTs = rumorTs;
                            await applyNostrSettings(s);
                        }
                    } catch (_) { }
                }
                return;
            }
            if (typeof rumor.content !== 'string') {
                return;
            }
            // Note: Bitchat uses ephemeral key for seal, so seal.pubkey may differ from rumor.pubkey
            // We only require rumor.pubkey to be present (the actual sender identity)
            if (!rumor.pubkey) {
                return;
            }

            const senderPubkey = rumor.pubkey;
            const isOwn = !!this.pubkey && senderPubkey === this.pubkey;

            // Track if this user uses Bitchat format (for replies)
            const isBitchatUser = isBitchatFormat(event.content) || rumor.content?.startsWith('bitchat1:');
            if (isBitchatUser && !isOwn) {
                this.bitchatUsers.add(senderPubkey);
            }

            // Track if this user uses Nymchat format with delivery receipts (has 'x' tag)
            const isNymUser = this.isNymMessage(rumor) || this.isNymReceipt(rumor);
            if (isNymUser && !isOwn) {
                this.nymUsers.add(senderPubkey);
            }

            // Handle typing indicators immediately (lightweight, no profile fetch needed)
            // Discard stale typing indicators — they are ephemeral signals, not historical data
            if (this.isTypingIndicator(rumor)) {
                const rumorAge = Math.floor(Date.now() / 1000) - (rumor.created_at || 0);
                if (rumorAge > this._typingExpireMs / 1000) return; // Older than expire window — stale
                const parsed = this.parseTypingIndicator(rumor);
                this.handleTypingIndicatorEvent(parsed, senderPubkey);
                return;
            }

            // Handle Nymchat delivery/read receipts early — before creating any
            // PM conversation state — so group receipts (which lack a 'g' tag)
            // don't accidentally create phantom 1:1 PM entries.
            if (this.isNymReceipt(rumor)) {
                const nymReceipt = this.parseNymReceipt(rumor);
                if (nymReceipt && nymReceipt.messageId) {
                    const receiptId = nymReceipt.messageId.toUpperCase();
                    const receiptType = nymReceipt.receiptType;

                    for (const [convKey, messages] of this.pmMessages) {
                        const msg = messages.find(m => m.nymMessageId?.toUpperCase() === receiptId);
                        if (msg && msg.isOwn) {
                            const statusOrder = { sent: 0, delivered: 1, read: 2 };
                            if ((statusOrder[receiptType] || 0) >= (statusOrder[msg.deliveryStatus] || 0)) {
                                msg.deliveryStatus = receiptType;
                                this.pendingDMs.delete(msg.id);
                                this.channelDOMCache.delete(convKey);

                                if (msg.isGroup && msg.nymMessageId && receiptType === 'read') {
                                    // Group read receipt: store the reader's avatar instead of checkmarks
                                    if (!this.groupMessageReaders.has(msg.nymMessageId)) {
                                        this.groupMessageReaders.set(msg.nymMessageId, new Map());
                                    }
                                    const readerNym = this.getNymFromPubkey(senderPubkey);
                                    this.groupMessageReaders.get(msg.nymMessageId).set(senderPubkey, readerNym);
                                    this.updateGroupReaderAvatars(msg.nymMessageId);
                                } else {
                                    // 1:1 PM: update checkmark in-place
                                    const domId = msg.nymMessageId || msg.id;
                                    const msgEl = document.querySelector(`[data-message-id="${domId}"]`);
                                    if (msgEl) {
                                        let statusEl = msgEl.querySelector('.delivery-status');
                                        if (!statusEl) {
                                            statusEl = document.createElement('span');
                                            msgEl.appendChild(statusEl);
                                        }
                                        statusEl.className = `delivery-status ${receiptType}`;
                                        statusEl.title = receiptType.charAt(0).toUpperCase() + receiptType.slice(1);
                                        statusEl.textContent = receiptType === 'read' ? '✓✓' : '✓';
                                    }
                                }
                            }
                            break;
                        }
                    }
                }
                return;
            }

            // Handle Bitchat delivery/read receipts early (same reason as above)
            if (rumor.content?.startsWith('bitchat1:')) {
                const parsedEarly = parseBitchatMessage(rumor.content);
                if (parsedEarly.type === 0x02 || parsedEarly.type === 0x03) {
                    const receiptType = parsedEarly.type === 0x02 ? 'read' : 'delivered';
                    const receiptId = parsedEarly.messageId?.toUpperCase();

                    if (receiptId) {
                        for (const [convKey, messages] of this.pmMessages) {
                            const msg = messages.find(m => m.bitchatMessageId?.toUpperCase() === receiptId);
                            if (msg && msg.isOwn) {
                                const statusOrder = { sent: 0, delivered: 1, read: 2 };
                                if ((statusOrder[receiptType] || 0) >= (statusOrder[msg.deliveryStatus] || 0)) {
                                    msg.deliveryStatus = receiptType;
                                    this.pendingDMs.delete(msg.id);
                                    this.channelDOMCache.delete(convKey);
                                    const domId = msg.nymMessageId || msg.id;
                                    const msgEl = document.querySelector(`[data-message-id="${domId}"]`);
                                    if (msgEl) {
                                        let statusEl = msgEl.querySelector('.delivery-status');
                                        if (!statusEl) {
                                            statusEl = document.createElement('span');
                                            msgEl.appendChild(statusEl);
                                        }
                                        statusEl.className = `delivery-status ${receiptType}`;
                                        statusEl.title = receiptType.charAt(0).toUpperCase() + receiptType.slice(1);
                                        statusEl.textContent = receiptType === 'read' ? '✓✓' : '✓';
                                    }
                                }
                                break;
                            }
                        }
                    }
                    return;
                }
            }

            // Kind 69420 is exclusively for receipts and typing indicators (handled above).
            // If it reaches here, it's malformed — drop it so it doesn't appear as a PM.
            if (rumor.kind === 69420) {
                return;
            }

            // Fetch profile for any PM sender we don't have (await to get nickname)
            if (!isOwn && !this.users.has(senderPubkey)) {
                await this.fetchProfileDirect(senderPubkey);
            }

            // Route group messages before 1:1 PM logic
            const groupTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'g' && typeof t[1] === 'string');
            if (groupTag) {
                await this.handleGroupMessage(rumor, event, senderPubkey, isOwn);
                return;
            }

            // Handle 1:1 PM reactions (kind 7 gift-wrapped without group tag)
            if (rumor.kind === 7) {
                const eTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'e' && t[1]);
                if (eTag) {
                    const reactionMessageId = eTag[1];
                    const emoji = rumor.content;
                    if (!emoji) { return; }
                    const actionTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'action');
                    const isRemoval = actionTag && actionTag[1] === 'remove';

                    // Timestamp-based dedup for out-of-order delivery
                    const actionKey = `${reactionMessageId}:${emoji}:${senderPubkey}`;
                    const lastAction = this.reactionLastAction.get(actionKey);
                    const eventTs = rumor.created_at || 0;
                    if (lastAction && lastAction.ts > eventTs) { return; }
                    this.reactionLastAction.set(actionKey, { action: isRemoval ? 'remove' : 'add', ts: eventTs });

                    if (isRemoval) {
                        const msgReactions = this.reactions.get(reactionMessageId);
                        if (msgReactions && msgReactions.has(emoji)) {
                            msgReactions.get(emoji).delete(senderPubkey);
                            if (msgReactions.get(emoji).size === 0) msgReactions.delete(emoji);
                            if (msgReactions.size === 0) this.reactions.delete(reactionMessageId);
                        }
                        this.updateMessageReactions(reactionMessageId);
                    } else {
                        const reactorNym = this.getNymFromPubkey(senderPubkey);
                        if (!this.reactions.has(reactionMessageId)) this.reactions.set(reactionMessageId, new Map());
                        const msgReactions = this.reactions.get(reactionMessageId);
                        if (!msgReactions.has(emoji)) msgReactions.set(emoji, new Map());
                        msgReactions.get(emoji).set(senderPubkey, reactorNym);
                        this.updateMessageReactions(reactionMessageId);
                    }
                }
                return;
            }

            // Determine the peer for the conversation
            const rumorPTags = (rumor.tags || []).filter(t => Array.isArray(t) && t[0] === 'p' && typeof t[1] === 'string').map(t => t[1]);
            let peerPubkey = null;
            if (isOwn) {
                peerPubkey = rumorPTags.find(pk => pk !== this.pubkey) || rumorPTags[0] || null;
            } else {
                peerPubkey = senderPubkey;
            }
            if (!peerPubkey) return; // can't place the message without a peer

            // Re-open closed PMs when a new message arrives from the peer
            if (this.closedPMs.has(peerPubkey)) {
                this.closedPMs.delete(peerPubkey);
                try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
                this._debouncedNostrSettingsSave();
            }

            const conversationKey = this.getPMConversationKey(peerPubkey);
            if (!this.pmMessages.has(conversationKey)) this.pmMessages.set(conversationKey, []);

            // Deduplicate within the correct conversation
            let list = this.pmMessages.get(conversationKey);
            if (list.some(m => m.id === event.id)) return;

            const nowSec = Math.floor(Date.now() / 1000);
            const originalTsSec = Math.floor(rumor.created_at) || nowSec;
            let tsSec = originalTsSec;

            // Guard against clock skew: cap at current time (no future messages)
            tsSec = Math.min(tsSec, nowSec);

            // Parse bitchat1: format if present to extract actual message
            const parsed = parseBitchatMessage(rumor.content);

            // Non-message bitchat types (receipts handled above, skip unknown types)
            if (parsed.type !== 0x01) return;

            let messageContent = parsed.content;

            // Drop messages whose content is raw ciphertext from other NIP-17
            if (messageContent && messageContent.length > 80 &&
                !/\s/.test(messageContent) && /^[A-Za-z0-9+/=_-]+$/.test(messageContent) &&
                !/^(lnbc|lnurl|lntb|lntbs|cashu|npub1|nsec1|nprofile1|nevent1|naddr1|note1|bc1|tb1|bitcoin:)/i.test(messageContent)) {
                return;
            }

            // Block blank/empty PM content
            if (!messageContent || !messageContent.trim()) return;

            // Check if this is an edit of a previous message (has 'edit' tag in rumor)
            const pmEditTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'edit' && t[1]);
            if (pmEditTag) {
                const originalId = pmEditTag[1];
                this.handleIncomingPMEdit(originalId, messageContent, senderPubkey, conversationKey);
                return;
            }

            // Content-based dedup for dual-wrapped messages: when nymchat sends
            // both bitchat + nymchat format to unknown peers, the recipient may
            // decrypt both. Deduplicate by sender + content + close timestamp.
            // If the existing message is missing nymMessageId (arrived as bitchat format
            // first), backfill it from the nymchat duplicate so reactions can match.
            const nymMsgIdFromRumor = this.getNymMessageId(rumor);
            const dupMsg = list.find(m => m.pubkey === senderPubkey && m.content === messageContent && Math.abs((m.timestamp?.getTime() / 1000 || 0) - tsSec) < 5);
            if (dupMsg) {
                if (!dupMsg.nymMessageId && nymMsgIdFromRumor) {
                    dupMsg.nymMessageId = nymMsgIdFromRumor;
                    // Update the DOM element's data-message-id to use nymMessageId
                    const oldEl = document.querySelector(`[data-message-id="${dupMsg.id}"]`);
                    if (oldEl) {
                        oldEl.dataset.messageId = nymMsgIdFromRumor;
                    }
                    this.channelDOMCache.delete(conversationKey);
                }
                return;
            }

            // Silently drop channel invitations for blocked channels
            if (messageContent && messageContent.includes('Channel Invitation:')) {
                const inviteMatch = messageContent.match(/join\s+#([a-z0-9]+)/i);
                if (inviteMatch) {
                    const invitedChannel = inviteMatch[1];
                    if (this.isChannelBlocked(invitedChannel, invitedChannel)) {
                        return;
                    }
                }
            }

            // Filter PMs based on acceptPMs setting
            if (!isOwn && this.settings.acceptPMs !== 'enabled') {
                if (this.settings.acceptPMs === 'disabled') return;
                if (this.settings.acceptPMs === 'friends' && !this.isFriend(senderPubkey)) return;
            }

            // Get sender name from kind 0 profile (not from rumor tags)
            const senderName = this.getNymFromPubkey(senderPubkey);

            // Use nymMessageId already extracted above (during dedup check)
            const nymMsgId = nymMsgIdFromRumor;

            const msg = {
                id: event.id,                                  // keep outer id for reactions/zaps
                author: isOwn ? this.nym : senderName,
                pubkey: senderPubkey,
                content: messageContent,
                created_at: tsSec,
                _originalCreatedAt: originalTsSec,
                _seq: ++this._msgSeq,
                timestamp: new Date(tsSec * 1000),
                isOwn,
                isPM: true,
                conversationKey,
                conversationPubkey: peerPubkey,
                eventKind: 1059,
                isHistorical: (Math.floor(Date.now() / 1000) - tsSec) > 10,
                bitchatMessageId: parsed.messageId,  // For sending Bitchat read receipts
                nymMessageId: nymMsgId  // For sending Nymchat read receipts
            };

            list.push(msg);
            list.sort((a, b) => {
                const dt = (a.created_at || 0) - (b.created_at || 0);
                if (dt !== 0) return dt;
                return (a._seq || 0) - (b._seq || 0);
            });
            // Cap PM conversations at pmStorageLimit messages to prevent memory bloat
            if (list.length > this.pmStorageLimit) {
                list = list.slice(-this.pmStorageLimit);
            }
            this.pmMessages.set(conversationKey, list);

            // Send DELIVERED receipt back to Bitchat user
            if (!isOwn && parsed.messageId && this.bitchatUsers.has(senderPubkey)) {
                this.sendBitchatReceipt(parsed.messageId, 0x03, senderPubkey); // 0x03 = DELIVERED
            }

            // Send DELIVERED receipt back to Nymchat user
            if (!isOwn && nymMsgId && this.nymUsers.has(senderPubkey)) {
                this.sendNymReceipt(nymMsgId, 'delivered', senderPubkey);
            }

            // Use sender's profile name for conversation
            const peerName = this.getNymFromPubkey(peerPubkey);
            this.addPMConversation(peerName, peerPubkey, tsSec * 1000);
            this.movePMToTop(peerPubkey, tsSec * 1000);

            // Clear typing indicator for sender (they sent a message, so they stopped typing)
            if (!isOwn) {
                const convTypers = this.typingUsers.get(conversationKey);
                if (convTypers && convTypers.has(senderPubkey)) {
                    const entry = convTypers.get(senderPubkey);
                    if (entry.timeout) clearTimeout(entry.timeout);
                    convTypers.delete(senderPubkey);
                    this.renderTypingIndicator();
                }
            }

            if (this.inPMMode && this.currentPM === peerPubkey) {
                this.displayMessage(msg);
                // Force auto-scroll to bottom for PM messages
                this._scheduleScrollToBottom();
                // Send READ receipt if viewing the conversation
                if (!isOwn && parsed.messageId && this.bitchatUsers.has(senderPubkey)) {
                    this.sendBitchatReceipt(parsed.messageId, 0x02, senderPubkey); // 0x02 = READ
                }
                // Send READ receipt for Nymchat users
                if (!isOwn && nymMsgId && this.nymUsers.has(senderPubkey)) {
                    this.sendNymReceipt(nymMsgId, 'read', senderPubkey);
                }
            } else {
                // Not viewing this conversation — invalidate DOM cache so it
                // re-renders fresh when the user opens this PM.
                this.channelDOMCache.delete(conversationKey);
                if (!isOwn) {
                    const pmSenderBlocked = this.blockedUsers.has(peerPubkey) || this.isNymBlocked(msg.author) || this.hasBlockedKeyword(msg.content, msg.author);
                    if (!msg.isHistorical) {
                        // Live message: full notification with sound/popup
                        this.updateUnreadCount(conversationKey);
                        if (!pmSenderBlocked) {
                            this.showNotification(`PM from ${msg.author}`, messageContent, {
                                type: 'pm',
                                nym: msg.author,
                                pubkey: peerPubkey,
                                id: conversationKey
                            });
                        }
                    } else {
                        // Historical message: silently add to notification history
                        if (!pmSenderBlocked) {
                            this._addNotificationToHistory(`PM from ${msg.author}`, messageContent, {
                                type: 'pm',
                                nym: msg.author,
                                pubkey: peerPubkey,
                                id: conversationKey
                            }, msg.timestamp.getTime());
                        }
                    }
                }
            }
        } catch (err) {
            // Log decryption failures for debugging
        }
    },

    getPMConversationKey(otherPubkey) {
        // Create a unique key for this PM conversation between two users
        const keys = [this.pubkey, otherPubkey].sort();
        return `pm-${keys.join('-')}`;
    },

    async sendPM(content, recipientPubkey) {
        try {
            if (!this.connected) throw new Error('Not connected to relay');
            if (!content || !content.trim()) return false;

            const wrapped = await this.sendNIP17PM(content, recipientPubkey);
            return !!wrapped;
        } catch (error) {
            // Store the failed message in pmMessages so it persists across navigation
            const conversationKey = this.getPMConversationKey(recipientPubkey);
            if (!this.pmMessages.has(conversationKey)) this.pmMessages.set(conversationKey, []);
            const failedId = 'failed-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
            const _nowFail = Math.floor(Date.now() / 1000);
            const failedMsg = {
                id: failedId,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                created_at: _nowFail,
                _seq: ++this._msgSeq,
                timestamp: new Date(_nowFail * 1000),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                deliveryStatus: 'failed'
            };
            const failList = this.pmMessages.get(conversationKey);
            failList.push(failedMsg);
            failList.sort((a, b) => {
                const dt = (a.created_at || 0) - (b.created_at || 0);
                if (dt !== 0) return dt;
                return (a._seq || 0) - (b._seq || 0);
            });
            // Invalidate cached DOM for this conversation
            this.channelDOMCache.delete(conversationKey);
            // Display the failed message if currently viewing this PM
            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(failedMsg);
            }
            return false;
        }
    },

    movePMToTop(pubkey, messageTimestamp) {
        const pmList = document.getElementById('pmList');
        const pmItem = pmList.querySelector(`[data-pubkey="${pubkey}"]`);

        if (pmItem) {
            // Use the message timestamp if provided, otherwise use current time
            const ts = messageTimestamp || Date.now();
            const currentTs = parseInt(pmItem.dataset.lastMessageTime || '0');
            // Only update if the new timestamp is newer
            const newTs = Math.max(ts, currentTs);
            pmItem.dataset.lastMessageTime = newTs;

            // Update in memory
            const conversation = this.pmConversations.get(pubkey);
            if (conversation) {
                conversation.lastMessageTime = newTs;
            }

            // Remove and re-insert in correct order
            pmItem.remove();
            this.insertPMInOrder(pmItem, pmList);

            // Re-apply search filter if search is active
            const searchInput = document.getElementById('pmSearch');
            if (searchInput && searchInput.value.trim().length > 0) {
                const term = searchInput.value.toLowerCase();
                const pmNameEl = pmItem.querySelector('.pm-name');
                const pmName = pmNameEl ? pmNameEl.textContent.toLowerCase() : '';
                if (!pmName.includes(term)) {
                    pmItem.style.display = 'none';
                    pmItem.classList.add('search-hidden');
                }
            }
        }
    },

    updatePMNicknameFromProfile(pubkey, profileName) {
        if (!profileName) return;
        const clean = this.parseNymFromDisplay(profileName).substring(0, 20);

        // Update memory
        if (this.pmConversations.has(pubkey)) {
            this.pmConversations.get(pubkey).nym = clean;
        }

        // Update sidebar DOM item if present
        const item = document.querySelector(`.pm-item[data-pubkey="${pubkey}"]`);
        if (item) {
            const suffix = this.getPubkeySuffix(pubkey);
            const verifiedBadge = this.isVerifiedDeveloper(pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
                : '';
            const pmNameEl = item.querySelector('.pm-name');
            if (pmNameEl) {
                pmNameEl.innerHTML = `@${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span> ${verifiedBadge}`;
            }
        }

        // Update displayed messages from this user
        const suffix = this.getPubkeySuffix(pubkey);
        const verifiedBadge = this.isVerifiedDeveloper(pubkey)
            ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
            : this.isVerifiedBot(pubkey)
                ? '<span class="verified-badge" title="Nymchat Bot">✓</span>'
                : '';
        const flairHtml = this.getFlairForUser(pubkey);
        const avatarSrc = this.getAvatarUrl(pubkey);
        const userShopItems = this.getUserShopItems(pubkey);
        const supporterBadge = userShopItems?.supporter ?
            '<span class="supporter-badge"><span class="supporter-badge-icon">🏆</span></span>' : '';
        document.querySelectorAll(`.message[data-pubkey="${pubkey}"] .message-author`).forEach(el => {
            // Update only the author-clickable inner span to preserve bubble-time and click handler
            const clickable = el.querySelector('.author-clickable');
            if (clickable) {
                clickable.innerHTML = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">&lt;${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${supporterBadge}`;
            } else {
                // Fallback: full rewrite with author-clickable wrapper for older messages missing it
                const bubbleTime = el.querySelector('.bubble-time');
                const bubbleHtml = bubbleTime ? bubbleTime.outerHTML : '';
                el.innerHTML = `${bubbleHtml}<span class="author-clickable"><img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">&lt;${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${supporterBadge}</span>&gt;`;
                const newClickable = el.querySelector('.author-clickable');
                if (newClickable) {
                    newClickable.style.cursor = 'pointer';
                    const msgEl = el.closest('.message');
                    const msgId = msgEl ? msgEl.dataset.messageId : null;
                    const rawContent = msgEl ? msgEl.dataset.rawContent : null;
                    const isPM = msgEl ? !!msgEl.dataset.isPM : false;
                    newClickable.addEventListener('click', (e) => {
                        e.preventDefault();
                        e.stopPropagation();
                        const displayAuthor = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">&lt;${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${flairHtml}`;
                        this.showContextMenu(e, displayAuthor, pubkey, rawContent, msgId, false, isPM ? msgId : null);
                        return false;
                    });
                }
            }
        });

        // Update PM header title if currently viewing this user's PM
        if (this.inPMMode && this.currentPM === pubkey) {
            const pmAvatarSrc = this.getAvatarUrl(pubkey);
            const displayNym = `${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>`;
            const pmHeaderHtml = `<img src="${this.escapeHtml(pmAvatarSrc)}" class="avatar-message" data-avatar-pubkey="${pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">@${displayNym} <span style="font-size: 12px; color: var(--text-dim);">(PM)</span>`;
            const channelEl = document.getElementById('currentChannel');
            if (channelEl) channelEl.innerHTML = pmHeaderHtml;
        }

        // Update any visible notification banner from this user
        const notif = document.querySelector(`.notification[data-pubkey="${pubkey}"] .notification-title`);
        if (notif) {
            notif.textContent = `PM from ${clean}#${suffix}`;
        }
    },

    addPMConversation(nym, pubkey, timestamp = Date.now()) {
        // Prefer known profile name if available
        let baseNym = this.users.has(pubkey)
            ? this.parseNymFromDisplay(this.users.get(pubkey).nym)
            : this.parseNymFromDisplay(nym);

        if (!this.pmConversations.has(pubkey)) {
            // Re-open closed PMs when a new conversation is initiated
            if (this.closedPMs.has(pubkey)) {
                this.closedPMs.delete(pubkey);
                try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
                this._debouncedNostrSettingsSave();
            }

            this.pmConversations.set(pubkey, {
                nym: baseNym,
                lastMessageTime: timestamp
            });

            const pmList = document.getElementById('pmList');
            const item = document.createElement('div');
            item.className = 'pm-item list-item';
            item.dataset.pubkey = pubkey;
            item.dataset.lastMessageTime = timestamp;

            const suffix = this.getPubkeySuffix(pubkey);
            const verifiedBadge = this.isVerifiedDeveloper(pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
                : '';

            // Get user's shop items for flair
            const userShopItems = this.getUserShopItems(pubkey);
            const flairHtml = this.getFlairForUser(pubkey);

            // Clean the base nym of any HTML for display
            const cleanBaseNym = this.parseNymFromDisplay(baseNym);

            const pmAvatarSrc = this.getAvatarUrl(pubkey);
            item.innerHTML = `
<img src="${this.escapeHtml(pmAvatarSrc)}" class="avatar-pm" data-avatar-pubkey="${pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">
<span class="pm-name">@${this.escapeHtml(cleanBaseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml} ${verifiedBadge}</span>
<div class="channel-badges">
<span class="delete-pm" onclick="event.stopPropagation(); nym.deletePM('${pubkey}')">✕</span>
<span class="unread-badge" style="display:none">0</span>
</div>
`;
            item.onclick = () => this.openPM(cleanBaseNym, pubkey);

            this.insertPMInOrder(item, pmList);

            // Hide new item if it doesn't match active search filter
            const searchInput = document.getElementById('pmSearch');
            if (searchInput && searchInput.value.trim().length > 0) {
                const term = searchInput.value.toLowerCase();
                const pmNameEl = item.querySelector('.pm-name');
                const pmName = pmNameEl ? pmNameEl.textContent.toLowerCase() : '';
                if (!pmName.includes(term)) {
                    item.style.display = 'none';
                    item.classList.add('search-hidden');
                }
            }

            this.updateViewMoreButton('pmList');

            // Proactively request their profile
            if (!this.users.has(pubkey) || /^anon$/i.test(cleanBaseNym)) {
                this.requestUserProfile(pubkey);
            }
        }
    },

    insertPMInOrder(newItem, pmList) {
        const newTime = parseInt(newItem.dataset.lastMessageTime);
        const existingItems = Array.from(pmList.querySelectorAll('.pm-item'));
        const viewMoreBtn = pmList.querySelector('.view-more-btn');

        // Find the correct position to insert (most recent first)
        let insertBefore = null;
        for (const item of existingItems) {
            const itemTime = parseInt(item.dataset.lastMessageTime || '0');
            if (newTime > itemTime) {
                insertBefore = item;
                break;
            }
        }

        // If we found a position, insert there
        if (insertBefore) {
            pmList.insertBefore(newItem, insertBefore);
        } else if (viewMoreBtn) {
            // If no position found but there's a view more button, insert before it
            pmList.insertBefore(newItem, viewMoreBtn);
        } else {
            // Otherwise append to the end
            pmList.appendChild(newItem);
        }
    },

    deletePM(pubkey) {
        if (confirm('Delete this PM conversation?')) {
            // Remove from conversations
            this.pmConversations.delete(pubkey);

            // Remove messages
            const conversationKey = this.getPMConversationKey(pubkey);
            this.pmMessages.delete(conversationKey);

            // Persist closed state so PM doesn't reappear on reload
            this.closedPMs.add(pubkey);
            try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();

            // Remove from UI
            const item = document.querySelector(`[data-pubkey="${pubkey}"]`);
            if (item) item.remove();

            // If currently viewing this PM, switch to bar
            if (this.inPMMode && this.currentPM === pubkey) {
                this.switchChannel('nym', 'nym');
            }

            this.displaySystemMessage('PM conversation deleted');
        }
    },

    // Delete a PM without confirmation (used by /leave command)
    deletePMDirect(pubkey) {
        this.pmConversations.delete(pubkey);
        const conversationKey = this.getPMConversationKey(pubkey);
        this.pmMessages.delete(conversationKey);
        this.closedPMs.add(pubkey);
        try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        const item = document.querySelector(`[data-pubkey="${pubkey}"]`);
        if (item) item.remove();
        if (this.inPMMode && this.currentPM === pubkey) {
            this.switchChannel('nym', 'nym');
        }
        this.displaySystemMessage('PM conversation deleted');
    },

    openPM(nym, pubkey) {
        this.inPMMode = true;
        this.currentPM = pubkey;
        this.currentGroup = null;
        this.currentChannel = null;
        this.currentGeohash = null;
        this.userScrolledUp = false;
        if (this.pendingEdit) this.cancelEditMessage();

        // Track navigation history
        this._pushNavigation({ type: 'pm', nym, pubkey });

        // Re-render typing indicator for the new conversation
        this.renderTypingIndicator();

        // Format the nym with pubkey suffix for display
        const known = this.users.get(pubkey);
        const baseNym = known ? this.parseNymFromDisplay(known.nym) : this.parseNymFromDisplay(nym);
        const suffix = this.getPubkeySuffix(pubkey);
        const pmAvatarSrc = this.getAvatarUrl(pubkey);
        const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
        const pmHeaderHtml = `<img src="${this.escapeHtml(pmAvatarSrc)}" class="avatar-message" data-avatar-pubkey="${pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">@${displayNym} <span style="font-size: 12px; color: var(--text-dim);">(PM)</span>`;

        // Update UI with formatted nym
        document.getElementById('currentChannel').innerHTML = pmHeaderHtml;
        const lockSvgPM = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px;margin-right:4px"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>';
        document.getElementById('channelMeta').innerHTML = `${lockSvgPM}End-to-end encrypted private message`;

        // Hide share button in PM mode
        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) {
            shareBtn.style.display = 'none';
        }

        // Update active states
        document.querySelectorAll('.channel-item').forEach(item => {
            item.classList.remove('active');
        });
        document.querySelectorAll('.pm-item').forEach(item => {
            item.classList.toggle('active', item.dataset.pubkey === pubkey);
        });

        // Clear unread count
        const conversationKey = this.getPMConversationKey(pubkey);
        this.clearUnreadCount(conversationKey);

        // Load PM messages
        this.loadPMMessages(conversationKey);

        // Send READ receipts for all unread messages from this peer
        const pmMsgs = this.pmMessages.get(conversationKey) || [];
        for (const msg of pmMsgs) {
            if (!msg.isOwn) {
                // Send Bitchat READ receipt if applicable
                if (msg.bitchatMessageId && this.bitchatUsers.has(msg.pubkey)) {
                    this.sendBitchatReceipt(msg.bitchatMessageId, 0x02, msg.pubkey);
                }
                // Send Nymchat READ receipt if applicable
                if (msg.nymMessageId && this.nymUsers.has(msg.pubkey)) {
                    this.sendNymReceipt(msg.nymMessageId, 'read', msg.pubkey);
                }
            }
        }

        // Close mobile sidebar on mobile
        if (window.innerWidth <= 768) {
            this.closeSidebar();
        }
    },

    loadPMMessages(conversationKey) {
        const container = document.getElementById('messagesContainer');

        // Skip reload if already viewing this PM conversation,
        // but force re-render if DOM is empty while we have stored messages
        if (container.dataset.lastChannel === conversationKey) {
            const storedCount = (this.pmMessages.get(conversationKey) || []).length;
            const domCount = container.querySelectorAll('.message[data-message-id]').length;
            if (storedCount === 0 || domCount > 0) {
                return;
            }
            // Messages exist but DOM is empty — fall through to re-render
        }

        // Cache current channel/PM DOM before switching
        this.cacheCurrentContainerDOM();
        container.dataset.lastChannel = conversationKey;

        // Try to restore from DOM cache if messages haven't changed
        const pmMessages = this.pmMessages.get(conversationKey) || [];
        const cached = this.channelDOMCache.get(conversationKey);
        const currentFingerprint = this._computeMessageFingerprint(pmMessages);

        if (cached && cached.messageCount === pmMessages.length &&
            cached.messageFingerprint === currentFingerprint) {
            // Message count unchanged, restore cached DOM instantly
            container.innerHTML = '';
            container.appendChild(cached.fragment);
            this.channelDOMCache.delete(conversationKey);

            // Restore virtual scroll state
            this.virtualScroll.currentStartIndex = cached.virtualScrollState.currentStartIndex;
            this.virtualScroll.currentEndIndex = cached.virtualScrollState.currentEndIndex;

            // Re-init virtual scroll handler (isPM = true)
            container.dataset.virtualScrollKey = conversationKey;
            container.dataset.virtualScrollIsPM = 'true';

            // Scroll to bottom
            if (this.settings.autoscroll) {

                setTimeout(() => {
                    container.scrollTop = container.scrollHeight;
                    setTimeout(() => {

                    }, 300);
                }, 0);
            }
            return;
        }

        // Cache miss or stale (new messages arrived) - render fresh
        this.channelDOMCache.delete(conversationKey);

        // Get filtered messages
        const filteredMessages = this.getFilteredPMMessages(conversationKey);

        if (filteredMessages.length === 0) {
            container.innerHTML = '';
            this.displaySystemMessage('Start of private message');
            return;
        }

        // Use virtual scrolling for efficient rendering (isPM = true)
        this.renderMessagesWithVirtualScroll(container, conversationKey, true, true);
    },

    openUserPM(nym, pubkey) {
        // Don't open PM with yourself
        if (pubkey === this.pubkey) {
            this.displaySystemMessage("You can't send private messages to yourself");
            return;
        }

        // Don't open PM with the bot — it only lives in channels
        if (this.isVerifiedBot(pubkey)) {
            this.displaySystemMessage("Nymbot doesn't accept private messages. Use ?ask or @Nymbot in a channel instead.");
            return;
        }

        // Extract base nym if it has a suffix
        const baseNym = this.stripPubkeySuffix(nym);

        // Clear closed state so user can re-open a previously closed PM
        if (this.closedPMs.has(pubkey)) {
            this.closedPMs.delete(pubkey);
            try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
            this._debouncedNostrSettingsSave();
        }

        // Add to PM conversations if not exists
        this.addPMConversation(baseNym, pubkey);
        // Open the PM
        this.openPM(baseNym, pubkey);

        // Proactively fetch kind 0 profile to update nickname/avatar
        const known = this.users.get(pubkey);
        if (!known || /^anon$/i.test(this.parseNymFromDisplay(known.nym))) {
            this.fetchProfileDirect(pubkey);
        }
    },

    filterPMs(searchTerm) {
        const items = document.querySelectorAll('.pm-item');
        const term = searchTerm.toLowerCase();
        const list = document.getElementById('pmList');

        // Update wrapper has-value class for clear button visibility
        const wrapper = document.getElementById('pmSearchWrapper');
        if (wrapper) {
            wrapper.classList.toggle('has-value', term.length > 0);
        }

        items.forEach(item => {
            const pmNameEl = item.querySelector('.pm-name');
            const pmName = pmNameEl ? pmNameEl.textContent.toLowerCase() : '';
            if (term.length === 0 || pmName.includes(term)) {
                item.style.display = 'flex';
                item.classList.remove('search-hidden');
            } else {
                item.style.display = 'none';
                item.classList.add('search-hidden');
            }
        });

        // Hide view more button during search
        const viewMoreBtn = list.querySelector('.view-more-btn');
        if (viewMoreBtn) {
            viewMoreBtn.style.display = term ? 'none' : 'block';
        }
    },

    async sendEditedPM(newContent, originalMessageId, recipientPubkey, originalNymMessageId) {
        try {
            if (!this.connected) throw new Error('Not connected to relay');

            const now = Math.floor(Date.now() / 1000);
            const nymMessageId = this.generateUUID();

            const rumor = {
                kind: 14,
                created_at: now,
                tags: [
                    ['p', recipientPubkey],
                    ['x', nymMessageId],
                    ['edit', originalNymMessageId || originalMessageId] // Reference the original message
                ],
                content: newContent,
                pubkey: this.pubkey
            };

            const expirationTs = (this.settings?.dmForwardSecrecyEnabled && this.settings?.dmTTLSeconds > 0)
                ? now + this.settings.dmTTLSeconds : null;

            if (this.privkey) {
                const NT = window.NostrTools;
                const isKnownBitchat = this.bitchatUsers.has(recipientPubkey);
                const isKnownNym = this.nymUsers.has(recipientPubkey);
                const isUnknownPeer = !isKnownBitchat && !isKnownNym;

                if (isKnownNym || isUnknownPeer) {
                    const nymWrapped = this.nip59WrapEvent(rumor, this.privkey, recipientPubkey, expirationTs);
                    this.sendDMToRelays(['EVENT', nymWrapped]);
                }

                // Self-wrap so edit is retrievable on reload
                if (recipientPubkey !== this.pubkey) {
                    const selfWrapped = this.nip59WrapEvent(rumor, this.privkey, this.pubkey, expirationTs);
                    this.sendDMToRelays(['EVENT', selfWrapped]);
                }
            } else if (window.nostr?.nip44?.encrypt && window.nostr?.signEvent) {
                // Extension path: create seal + wrap via extension
                const NT = window.NostrTools;
                const sealContent = await window.nostr.nip44.encrypt(recipientPubkey, JSON.stringify(rumor));
                const sealUnsigned = { kind: 13, content: sealContent, created_at: this.randomNow(), tags: [] };
                const seal = await window.nostr.signEvent(sealUnsigned);
                const ephSk = NT.generateSecretKey();
                const ephPk = NT.getPublicKey(ephSk);
                const ckWrap = NT.nip44.getConversationKey(ephSk, recipientPubkey);
                const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
                const wrapUnsigned = { kind: 1059, content: wrapContent, created_at: this.randomNow(), tags: [['p', recipientPubkey]], pubkey: ephPk };
                if (expirationTs) wrapUnsigned.tags.push(['expiration', String(expirationTs)]);
                const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);
                this.sendDMToRelays(['EVENT', wrapped]);

                // Self-wrap so our own edit is retrievable from relays after reload
                if (recipientPubkey !== this.pubkey) {
                    try {
                        const selfSealContent = await window.nostr.nip44.encrypt(this.pubkey, JSON.stringify(rumor));
                        const selfSealUnsigned = { kind: 13, content: selfSealContent, created_at: this.randomNow(), tags: [] };
                        const selfSeal = await window.nostr.signEvent(selfSealUnsigned);
                        const selfEphSk = NT.generateSecretKey();
                        const selfCkWrap = NT.nip44.getConversationKey(selfEphSk, this.pubkey);
                        const selfWrapContent = NT.nip44.encrypt(JSON.stringify(selfSeal), selfCkWrap);
                        const selfWrapUnsigned = { kind: 1059, content: selfWrapContent, created_at: this.randomNow(), tags: [['p', this.pubkey]] };
                        if (expirationTs) selfWrapUnsigned.tags.push(['expiration', String(expirationTs)]);
                        const selfWrapped = NT.finalizeEvent(selfWrapUnsigned, selfEphSk);
                        this.sendDMToRelays(['EVENT', selfWrapped]);
                    } catch (_) { /* Self-wrap failed — non-critical */ }
                }
            }

            // Track edit locally
            const lookupId = originalNymMessageId || originalMessageId;
            this.editedMessages.set(lookupId, {
                newContent,
                editEventId: nymMessageId,
                timestamp: new Date(now * 1000)
            });

            // Update stored PM messages
            const conversationKey = this.getPMConversationKey(recipientPubkey);
            const msgs = this.pmMessages.get(conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.nymMessageId === lookupId || m.id === lookupId);
                if (msg) {
                    msg.content = newContent;
                    msg.isEdited = true;
                }
            }
            this.channelDOMCache.delete(conversationKey);

            // Update DOM in-place
            this.updateMessageInDOM(lookupId, newContent);

            return true;
        } catch (error) {
            this.displaySystemMessage('Failed to edit message: ' + error.message);
            return false;
        }
    },

    async cmdPM(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /pm nym, /pm nym#xxxx, or /pm [pubkey]');
            return;
        }

        const targetInput = args.trim().replace(/^@/, '');

        // Check if input is a pubkey (64 hex characters)
        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            const targetPubkey = targetInput.toLowerCase();

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't send private messages to yourself");
                return;
            }

            // Get nym from pubkey
            const targetNym = this.getNymFromPubkey(targetPubkey);
            this.openUserPM(targetNym, targetPubkey);
            return;
        }

        // Handle both nym and nym#xxxx formats
        let searchNym = targetInput;
        let searchSuffix = null;

        const hashIndex = targetInput.indexOf('#');
        if (hashIndex !== -1) {
            searchNym = targetInput.substring(0, hashIndex);
            searchSuffix = targetInput.substring(hashIndex + 1);
        }

        // Find user by nym, considering suffix if provided
        const matches = [];
        this.users.forEach((user, pubkey) => {
            const baseNym = this.stripPubkeySuffix(user.nym);
            if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                if (searchSuffix) {
                    // If suffix provided, only match exact pubkey suffix
                    if (pubkey.endsWith(searchSuffix)) {
                        matches.push({ nym: user.nym, pubkey: pubkey });
                    }
                } else {
                    // No suffix provided, collect all matches
                    matches.push({ nym: user.nym, pubkey: pubkey });
                }
            }
        });

        if (matches.length === 0) {
            this.displaySystemMessage(`User ${targetInput} not found`);
            return;
        }

        if (matches.length > 1 && !searchSuffix) {
            // Multiple users with same nym, show them
            const matchList = matches.map(m =>
                `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
            ).join(', ');
            this.displaySystemMessage(`Multiple users found with nym "${this.escapeHtml(searchNym)}": ${matchList}`, 'system', { html: true });
            this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
            return;
        }

        // Single match or exact suffix match
        const targetPubkey = matches[0].pubkey;
        const targetNym = matches[0].nym;

        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You can't send private messages to yourself");
            return;
        }

        this.openUserPM(targetNym, targetPubkey);
    },

    openNewPMModal() {
        this._newPMRecipients = [];
        document.getElementById('pmRecipientChips').innerHTML = '';
        document.getElementById('pmRecipientInput').value = '';
        document.getElementById('pmSuggestions').style.display = 'none';
        document.getElementById('pmGroupNameGroup').style.display = 'none';
        document.getElementById('pmGroupNameInput').value = '';
        document.getElementById('pmInitialMessage').value = '';
        document.getElementById('pmStartBtn').disabled = true;
        document.getElementById('newPMModal').classList.add('active');
        setTimeout(() => {
            document.getElementById('pmRecipientInput').focus();
            // Show follow list suggestions when Nostr-logged-in user opens the modal
            if (this.nostrFollowList.length > 0) {
                this._showFollowListSuggestions('');
            } else if (this.pubkey) {
                // Follow list not loaded yet — retry fetch and show when ready
                this.fetchNostrFollowList(this.pubkey);
            }
        }, 80);
        if (window.innerWidth <= 768) this.closeSidebar();
    },

    // Show follow list suggestions in the New Message modal
    _showFollowListSuggestions(query) {
        const suggestions = document.getElementById('pmSuggestions');
        if (!suggestions) return;

        const followMatches = [];
        for (const pk of this.nostrFollowList) {
            if (pk === this.pubkey) continue;
            if (this._newPMRecipients.some(r => r.pubkey === pk)) continue;
            const user = this.users.get(pk);
            const name = user ? this.stripPubkeySuffix(user.nym) : pk.slice(0, 12) + '...';
            if (query && !name.toLowerCase().includes(query)) continue;
            followMatches.push({ nym: name, pubkey: pk, isFollow: true });
        }

        if (followMatches.length === 0) return;

        const header = query ? '' : '<div class="pm-suggestion-header">From your Nostr follows</div>';
        const html = header + followMatches.slice(0, 10).map(m => {
            const suffix = this.getPubkeySuffix(m.pubkey);
            const avatarSrc = this.escapeHtml(this.getAvatarUrl(m.pubkey));
            return `<div class="pm-suggestion-item" data-pubkey="${m.pubkey}" data-nym="${this.escapeHtml(m.nym)}"><img src="${avatarSrc}" class="pm-suggestion-avatar" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${m.pubkey}.png?set=set1&size=80x80'"><span class="pm-suggestion-nym">${this.escapeHtml(m.nym)}</span><span class="pm-suggestion-suffix">#${suffix}</span><span class="pm-suggestion-follow-badge">following</span></div>`;
        }).join('');

        suggestions.innerHTML = html;
        suggestions.querySelectorAll('.pm-suggestion-item[data-pubkey]').forEach(el => {
            el.addEventListener('click', () => this.addNewPMRecipient(el.dataset.pubkey, el.dataset.nym));
        });
        suggestions.style.display = 'block';
    },

    onNewPMRecipientInput(value) {
        const suggestions = document.getElementById('pmSuggestions');
        const query = value.trim().replace(/^@/, '').toLowerCase();
        if (!query) {
            // Show follow list when input is empty (if Nostr-logged-in)
            if (this.nostrFollowList.length > 0) {
                this._showFollowListSuggestions('');
            } else {
                suggestions.style.display = 'none';
            }
            return;
        }

        // Direct pubkey paste
        if (/^[0-9a-f]{64}$/i.test(query)) {
            const pk = query;
            if (!this._newPMRecipients.some(r => r.pubkey === pk) && pk !== this.pubkey) {
                const renderPubkeySuggestion = () => {
                    const nym = this.stripPubkeySuffix(this.getNymFromPubkey(pk));
                    const suffix = this.getPubkeySuffix(pk);
                    const avatarSrc = this.escapeHtml(this.getAvatarUrl(pk));
                    suggestions.innerHTML = `<div class="pm-suggestion-item" data-pubkey="${pk}" data-nym="${this.escapeHtml(nym)}"><img src="${avatarSrc}" class="pm-suggestion-avatar" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pk}.png?set=set1&size=80x80'"><span class="pm-suggestion-nym">${this.escapeHtml(nym)}</span><span class="pm-suggestion-suffix">#${suffix}</span></div>`;
                    suggestions.querySelector('.pm-suggestion-item').addEventListener('click', () => this.addNewPMRecipient(pk, nym));
                    suggestions.style.display = 'block';
                };
                renderPubkeySuggestion();
                // If profile isn't cached yet, fetch kind:0 and refresh the suggestion
                if (!this.users.has(pk)) {
                    this.fetchProfileDirect(pk).then(() => {
                        // Only refresh if the input still shows this pubkey
                        const currentInput = document.getElementById('pmRecipientInput')?.value.trim().replace(/^@/, '').toLowerCase();
                        if (currentInput === pk) renderPubkeySuggestion();
                    }).catch(() => { });
                }
            } else {
                suggestions.style.display = 'none';
            }
            return;
        }

        // Search active users
        const matches = [];
        const matchedPubkeys = new Set();
        this.users.forEach((user, pubkey) => {
            if (pubkey === this.pubkey) return;
            if (this.isVerifiedBot(pubkey)) return;
            if (this._newPMRecipients.some(r => r.pubkey === pubkey)) return;
            const baseNym = this.stripPubkeySuffix(user.nym).toLowerCase();
            if (baseNym.includes(query)) {
                matches.push({ nym: this.stripPubkeySuffix(user.nym), pubkey, isFollow: this.nostrFollowList.includes(pubkey) });
                matchedPubkeys.add(pubkey);
            }
        });

        // Also search follow list for users not in active users
        if (this.nostrFollowList.length > 0) {
            for (const pk of this.nostrFollowList) {
                if (pk === this.pubkey || matchedPubkeys.has(pk)) continue;
                if (this._newPMRecipients.some(r => r.pubkey === pk)) continue;
                const user = this.users.get(pk);
                const name = user ? this.stripPubkeySuffix(user.nym) : pk.slice(0, 12) + '...';
                if (name.toLowerCase().includes(query)) {
                    matches.push({ nym: name, pubkey: pk, isFollow: true });
                }
            }
        }

        if (matches.length === 0) { suggestions.style.display = 'none'; return; }

        // Sort: follows first, then by name
        matches.sort((a, b) => (b.isFollow ? 1 : 0) - (a.isFollow ? 1 : 0));

        suggestions.innerHTML = matches.slice(0, 10).map(m => {
            const suffix = this.getPubkeySuffix(m.pubkey);
            const avatarSrc = this.escapeHtml(this.getAvatarUrl(m.pubkey));
            const followBadge = m.isFollow ? '<span class="pm-suggestion-follow-badge">following</span>' : '';
            return `<div class="pm-suggestion-item" data-pubkey="${m.pubkey}" data-nym="${this.escapeHtml(m.nym)}"><img src="${avatarSrc}" class="pm-suggestion-avatar" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${m.pubkey}.png?set=set1&size=80x80'"><span class="pm-suggestion-nym">${this.escapeHtml(m.nym)}</span><span class="pm-suggestion-suffix">#${suffix}</span>${followBadge}</div>`;
        }).join('');
        suggestions.querySelectorAll('.pm-suggestion-item[data-pubkey]').forEach(el => {
            el.addEventListener('click', () => this.addNewPMRecipient(el.dataset.pubkey, el.dataset.nym));
        });
        suggestions.style.display = 'block';
    },

    onNewPMRecipientKeydown(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            const val = event.target.value.trim().replace(/^@/, '');
            if (!val) return;
            const pubkey = this.resolvePubkeyFromNym(val);
            if (pubkey && pubkey !== this.pubkey) {
                this.addNewPMRecipient(pubkey, this.stripPubkeySuffix(this.getNymFromPubkey(pubkey)));
            }
        } else if (event.key === 'Backspace' && !event.target.value && this._newPMRecipients.length > 0) {
            this.removeNewPMRecipient(this._newPMRecipients[this._newPMRecipients.length - 1].pubkey);
        }
    },

    addNewPMRecipient(pubkey, nym) {
        if (this._newPMRecipients.some(r => r.pubkey === pubkey)) return;
        if (this.isVerifiedBot(pubkey)) {
            this.displaySystemMessage("Nymbot doesn't accept private messages or group chats. Use ?ask or @Nymbot in a channel instead.");
            return;
        }
        this._newPMRecipients.push({ pubkey, nym });
        this._renderNewPMRecipientChips();
        document.getElementById('pmRecipientInput').value = '';
        document.getElementById('pmSuggestions').style.display = 'none';
        document.getElementById('pmGroupNameGroup').style.display =
            this._newPMRecipients.length >= 2 ? 'block' : 'none';
        document.getElementById('pmStartBtn').disabled = false;
        document.getElementById('pmRecipientInput').focus();

        // If this user's kind:0 profile isn't cached yet, fetch it and refresh the
        // chip once it arrives so the real display name and avatar appear.
        if (!this.users.has(pubkey)) {
            this.fetchProfileDirect(pubkey).then(() => {
                const r = this._newPMRecipients.find(x => x.pubkey === pubkey);
                if (r && this.users.has(pubkey)) {
                    const u = this.users.get(pubkey);
                    r.nym = u ? this.stripPubkeySuffix(u.nym) : r.nym;
                    this._renderNewPMRecipientChips();
                }
            }).catch(() => { });
        }
    },

    removeNewPMRecipient(pubkey) {
        this._newPMRecipients = this._newPMRecipients.filter(r => r.pubkey !== pubkey);
        this._renderNewPMRecipientChips();
        document.getElementById('pmGroupNameGroup').style.display =
            this._newPMRecipients.length >= 2 ? 'block' : 'none';
        document.getElementById('pmStartBtn').disabled = this._newPMRecipients.length === 0;
    },

    _renderNewPMRecipientChips() {
        document.getElementById('pmRecipientChips').innerHTML = this._newPMRecipients.map(r => {
            const suffix = this.getPubkeySuffix(r.pubkey);
            const baseNym = this.stripPubkeySuffix(this.parseNymFromDisplay(r.nym));
            return `<span class="pm-recipient-chip">${this.escapeHtml(baseNym)}<span class="pm-chip-suffix">#${suffix}</span><button class="pm-chip-remove" onclick="nym.removeNewPMRecipient('${r.pubkey}')" type="button">×</button></span>`;
        }).join('');
    },

    async startNewPMFromModal() {
        if (this._newPMRecipients.length === 0) return;
        const initialMsg = document.getElementById('pmInitialMessage').value.trim();
        closeModal('newPMModal');

        if (this._newPMRecipients.length === 1) {
            const { nym, pubkey } = this._newPMRecipients[0];
            this.openUserPM(nym, pubkey);
            if (initialMsg) {
                setTimeout(() => this.sendPM(initialMsg, pubkey), 400);
            }
        } else {
            const groupName = document.getElementById('pmGroupNameInput').value.trim() ||
                [this.getNymFromPubkey(this.pubkey), ...this._newPMRecipients.slice(0, 2).map(r => r.nym)].join(', ');
            const memberPubkeys = this._newPMRecipients.map(r => r.pubkey);
            this.displaySystemMessage(`Creating group "${groupName}"...`);
            const groupId = await this.createGroup(groupName, memberPubkeys);
            if (groupId && initialMsg) {
                this.sendGroupMessage(initialMsg, groupId);
            }
        }
    },

    // Get filtered PM messages for a conversation key
    getFilteredPMMessages(conversationKey) {
        const pmMessages = this.pmMessages.get(conversationKey) || [];

        return pmMessages.filter(msg => {
            // Check if message has been deleted
            if (this.deletedEventIds.has(msg.id)) return false;
            // Check if message is from blocked user
            if (this.blockedUsers.has(msg.pubkey) || msg.blocked) return false;
            // Check if message content or nickname matches blocked keywords
            if (this.hasBlockedKeyword(msg.content, msg.author)) return false;
            // Check if message content is spam
            if (this.isSpamMessage(msg.content)) return false;
            if (msg.conversationKey !== conversationKey) return false;
            // For 1:1 PMs, restrict to the two participants. Group messages have
            // multiple senders so skip this check for them.
            if (!msg.isGroup && msg.pubkey !== this.pubkey && msg.pubkey !== this.currentPM) return false;
            return true;
        }).sort((a, b) => {
            const dt = (a.created_at || 0) - (b.created_at || 0);
            if (dt !== 0) return dt;
            return (a._seq || 0) - (b._seq || 0);
        });
    },

    // Load older PM/group messages when user scrolls to top
    loadOlderPMMessages(conversationKey) {
        const container = document.getElementById('messagesContainer');
        if (!container) return false;

        const currentStart = this.pmRenderedStart.get(conversationKey);
        if (currentStart === undefined || currentStart <= 0) return false;

        const messages = this.getFilteredPMMessages(conversationKey);
        if (messages.length === 0) return false;

        const newStart = Math.max(0, currentStart - this.pmLoadMoreSize);
        if (newStart === currentStart) return false;

        // Remember scroll position before re-rendering
        const prevScrollHeight = container.scrollHeight;
        const prevScrollTop = container.scrollTop;

        // Update start index and invalidate DOM cache
        this.pmRenderedStart.set(conversationKey, newStart);
        this.channelDOMCache.delete(conversationKey);

        // Re-render with the expanded message window
        container.innerHTML = '';
        const renderMessages = messages.slice(newStart);

        if (newStart > 0) {
            const loadNotice = document.createElement('div');
            loadNotice.className = 'system-message pm-load-older';
            loadNotice.textContent = `Scroll up to load older messages (${newStart} more)`;
            container.appendChild(loadNotice);
        } else {
            const topNotice = document.createElement('div');
            topNotice.className = 'system-message pm-history-start';
            topNotice.textContent = 'Beginning of conversation history';
            container.appendChild(topNotice);
        }

        this.virtualScroll.suppressAutoScroll = true;
        this._suppressSound = true;

        for (let i = 0; i < renderMessages.length; i++) {
            this.displayMessage(renderMessages[i]);
        }

        this._suppressSound = false;
        this.virtualScroll.suppressAutoScroll = false;

        // Restore scroll position so user stays at the same place
        requestAnimationFrame(() => {
            const newScrollHeight = container.scrollHeight;
            container.scrollTop = prevScrollTop + (newScrollHeight - prevScrollHeight);
        });

        return true;
    },

    applyGroupChatPMOnlyMode(enabled) {
        // Hide or show the channels section in the sidebar
        const channelsSection = document.querySelector('#channelList')?.closest('.nav-section');
        if (channelsSection) {
            channelsSection.style.display = enabled ? 'none' : '';
        }

        if (enabled) {
            // Navigate to the latest PM/group chat, or show empty state
            this.navigateToLatestPMOrGroup();
        } else {
            // Restore default channel view
            const pinned = this.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' };
            if (pinned.type === 'geohash' && pinned.geohash) {
                this.switchChannel(pinned.geohash, pinned.geohash);
            } else {
                this.switchChannel('nym', 'nym');
            }
            // Re-discover and subscribe to channels
            this.discoverChannels();
            this.loadJoinedChannelsFromRelays();
        }

        // Update active nyms list
        this.updateUserList();
    },

    navigateToLatestPMOrGroup() {
        // Find the most recent PM or group chat by looking at the PM list DOM order
        const pmList = document.getElementById('pmList');
        if (pmList) {
            const firstItem = pmList.querySelector('.pm-item');
            if (firstItem) {
                const groupId = firstItem.dataset.groupId;
                const pubkey = firstItem.dataset.pubkey;
                if (groupId) {
                    this.openGroup(groupId);
                } else if (pubkey) {
                    const nym = firstItem.querySelector('.pm-name')?.textContent || 'Unknown';
                    this.openPM(nym, pubkey);
                }
                return;
            }
        }

        // No PM or group chat found - show empty state
        this.showPMOnlyEmptyState();
    },

    showPMOnlyEmptyState() {
        this.inPMMode = true;
        this.currentPM = null;
        this.currentGroup = null;
        this.currentChannel = null;
        this.currentGeohash = null;

        document.getElementById('currentChannel').innerHTML = '<span style="color: var(--text-dim);">No conversation selected</span>';
        document.getElementById('channelMeta').textContent = '';

        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) shareBtn.style.display = 'none';

        document.querySelectorAll('.channel-item').forEach(i => i.classList.remove('active'));
        document.querySelectorAll('.pm-item').forEach(i => i.classList.remove('active'));

        const container = document.getElementById('messagesContainer');
        if (container) {
            container.innerHTML = `
                <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; color: var(--text-dim); text-align: center; padding: 40px;">
                    <div style="font-size: 48px; margin-bottom: 16px; opacity: 0.5;">+</div>
                    <div style="font-size: 16px; margin-bottom: 8px;">No conversations yet</div>
                    <div style="font-size: 13px; opacity: 0.7;">Click the <strong>+</strong> button in the Private Messages section to start a new group chat or private message.</div>
                </div>`;
        }
    },

});
