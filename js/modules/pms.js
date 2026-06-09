// pms.js - Private messages: send, open, conversation list, gift wrap DMs, new-PM modal, retry queue

Object.assign(NYM.prototype, {

    _pmHeaderAvatarHtml(pubkey, avatarSrc, safePk) {
        const status = (typeof this.getEffectiveUserStatus === 'function')
            ? this.getEffectiveUserStatus(pubkey) : 'offline';
        const isHidden = (this.settings && this.settings.showStatus === false) || status === 'hidden';
        const dotStatus = isHidden ? 'offline' : status;
        return `<span class="user-avatar-wrap pm-header-avatar${isHidden ? ' no-status' : ''}"><img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy"><span class="user-status-dot status-${dotStatus}"></span></span>`;
    },

    refreshPMHeaderStatus() {
        if (!this.inPMMode || !this.currentPM) return;
        const channelEl = document.getElementById('currentChannel');
        if (!channelEl) return;
        const dot = channelEl.querySelector('.pm-header-avatar .user-status-dot');
        if (dot) {
            const status = (typeof this.getEffectiveUserStatus === 'function')
                ? this.getEffectiveUserStatus(this.currentPM) : 'offline';
            const isHidden = (this.settings && this.settings.showStatus === false) || status === 'hidden';
            const dotStatus = isHidden ? 'offline' : status;
            const wrap = dot.parentElement;
            if (wrap) wrap.classList.toggle('no-status', isHidden);
            dot.className = `user-status-dot status-${dotStatus}`;
        }
        // Keep the "Last seen …" presence line in sync with the contact's status.
        const seenEl = channelEl.querySelector('.pm-last-seen .loc-country');
        if (seenEl) {
            seenEl.textContent = this._pmLastSeenText(this.currentPM);
        }
    },

    // Human-readable presence line for a 1:1 PM header. Shows live status when
    // the contact is active/away, otherwise the relative time we last saw them.
    _pmLastSeenText(pubkey) {
        if (this.isVerifiedBot(pubkey)) return 'Always at your service';
        if (this.settings && this.settings.showStatus === false) return '';
        const status = (typeof this.getEffectiveUserStatus === 'function')
            ? this.getEffectiveUserStatus(pubkey) : 'offline';
        if (status === 'hidden') return '';
        if (status === 'online') return 'Active now';
        if (status === 'away') return 'Away';
        const user = this.users.get(pubkey);
        const lastSeen = user ? (user.lastSeen || 0) : 0;
        if (lastSeen > 0 && typeof this._formatRelativeTime === 'function') {
            return `Last seen ${this._formatRelativeTime(lastSeen)}`;
        }
        return 'Last seen unknown';
    },

    _pmLastSeenHtml(pubkey) {
        return `<div class="channel-location pm-last-seen"><span class="loc-country">${this.escapeHtml(this._pmLastSeenText(pubkey))}</span></div>`;
    },

    _ensurePMHeaderTimer() {
        if (typeof this._setManagedInterval !== 'function') return;
        this._setManagedInterval('pm-header-status', () => {
            if (this.inPMMode && this.currentPM) this.refreshPMHeaderStatus();
        }, 30000);
    },

    // Update the delivery checkmark on a PM message in-place
    _updateDeliveryStatusEl(messageId, receiptType) {
        const msgEl = this.findMessageElementAnywhere(messageId);
        if (!msgEl) return;
        let statusEl = msgEl.querySelector('.delivery-status');
        if (!statusEl) {
            statusEl = document.createElement('span');
            msgEl.appendChild(statusEl);
        }
        statusEl.className = `delivery-status ${receiptType}`;
        statusEl.title = receiptType.charAt(0).toUpperCase() + receiptType.slice(1);
        statusEl.textContent = receiptType === 'read' ? '✓✓' : '✓';
    },

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
                        // Update the failed checkmark in-place
                        const msgEl = this.findMessageElementAnywhere(eventId);
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

        // Update UI immediately (live DOM or any cached fragment)
        const msgEl = this.findMessageElementAnywhere(eventId);
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

    // Persist the newest gift-wrap timestamp we've processed
    _persistLastPMSyncTime() {
        if (!this.pubkey || !this.lastPMSyncTime) return;
        if (this._lastPMSyncTimeWriteAt && Date.now() - this._lastPMSyncTimeWriteAt < 5000) return;
        this._lastPMSyncTimeWriteAt = Date.now();
        try {
            localStorage.setItem(`nym_last_pm_sync_${this.pubkey}`, String(this.lastPMSyncTime));
        } catch (_) { }
    },

    _loadLastPMSyncTime() {
        if (!this.pubkey) return;
        try {
            const raw = localStorage.getItem(`nym_last_pm_sync_${this.pubkey}`);
            if (!raw) {
                this._isFreshDevice = true;
                return;
            }
            const parsed = parseInt(raw, 10);
            if (Number.isFinite(parsed) && parsed > this.lastPMSyncTime) {
                this.lastPMSyncTime = parsed;
            }
            this._isFreshDevice = false;
        } catch (_) { }
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

            // Real pubkey catch-up — fires immediately
            const realFilter = { kinds: [1059], '#p': [this.pubkey], since, limit: 200 };
            const realSubId = mkSubId();
            this._registerBackfillSub(realSubId);
            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                this._poolSendToRole('critical', ['REQ', realSubId, realFilter]);
            } else {
                const req = JSON.stringify(this._normalizeReqPayload(['REQ', realSubId, realFilter]));
                this.relayPool.forEach(relay => {
                    if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        this._safeWsSend(relay.ws, req, { critical: true });
                    }
                });
            }

            // Ephemeral pubkey catch-up — single batched REQ with all keys
            const ephPks = this._getAllSelfEphemeralPubkeys();
            if (ephPks.length) {
                const subId = mkSubId();
                const filter = { kinds: [1059], '#p': ephPks, since, limit: 100 * ephPks.length };
                this._registerBackfillSub(subId);
                if (this.useRelayProxy && this._isAnyPoolOpen()) {
                    this._poolSendToRole('critical', ['REQ', subId, filter]);
                } else {
                    const req = JSON.stringify(this._normalizeReqPayload(['REQ', subId, filter]));
                    this.relayPool.forEach(relay => {
                        if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                            this._safeWsSend(relay.ws, req, { critical: true });
                        }
                    });
                }
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
        const nowMs = Date.now();
        const now = Math.floor(nowMs / 1000);

        // Generate message ID for delivery receipts (Nymchat format)
        const nymMessageId = this._generateSharedEventId();

        const rumor = {
            kind: 14,
            created_at: now,
            tags: [
                ['p', recipientPubkey],
                ['x', nymMessageId],  // Nymchat message ID for delivery receipts
                ['ms', String(nowMs)],  // Millisecond send time for sub-second ordering
                ...this.customEmojiTagsForContent(content),
                ...(typeof this.imetaTagsForContent === 'function' ? this.imetaTagsForContent(content) : [])
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
                const bitchatWrapped = await this.bitchatWrapEventAsync(bitchatRumor, this.privkey, recipientPubkey, expirationTs);
                this.sendDMToRelays(['EVENT', bitchatWrapped]);
                sentWrappedEvents.push(['EVENT', bitchatWrapped]);
                wrapped = bitchatWrapped;
                this._recordGiftWrapId(nymMessageId, bitchatWrapped.id);

                if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(bitchatWrapped.id, 1059); }, 600000);
                }
            }

            if (isKnownNym || isUnknownPeer) {
                const nymWrapped = await this.nip59WrapEventAsync(rumor, this.privkey, recipientPubkey, expirationTs);
                this.sendDMToRelays(['EVENT', nymWrapped]);
                sentWrappedEvents.push(['EVENT', nymWrapped]);
                wrapped = nymWrapped;
                this._recordGiftWrapId(nymMessageId, nymWrapped.id);

                if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(nymWrapped.id, 1059); }, 600000);
                }
            }

            if (recipientPubkey !== this.pubkey) {
                const selfWrapped = await this.nip59WrapEventAsync(rumor, this.privkey, this.pubkey, expirationTs);
                this.sendDMToRelays(['EVENT', selfWrapped]);
                this._recordGiftWrapId(nymMessageId, selfWrapped.id);
                // Archive our own self-addressed copy so sent messages also
                // restore across devices, without waiting for the relay echo.
                this._archivePMEvent(selfWrapped);
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
                _ms: nowMs,
                _seq: ++this._msgSeq,
                timestamp: new Date(now * 1000),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                bitchatMessageId,  // For tracking Bitchat delivery/read receipts
                nymMessageId,  // Always store for reaction matching (peer may react using nymMessageId from x tag)
                senderVerified: true,
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });
            pmList.sort((a, b) => {
                return this._compareMessages(a, b);
            });
            // Cap PM conversations at pmStorageLimit messages
            if (pmList.length > this.pmStorageLimit) {
                this.pmMessages.set(conversationKey, pmList.slice(-this.pmStorageLimit));
            }
            this.persistPMMessages(conversationKey);

            // Track for automatic retry if delivery receipt not received
            this.trackPendingDM(wrapped.id, sentWrappedEvents, recipientPubkey, conversationKey);

            this.addPMConversation(this.getNymFromPubkey(recipientPubkey), recipientPubkey, Date.now());
            this.movePMToTop(recipientPubkey);

            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(this.pmMessages.get(conversationKey).slice(-1)[0]);
                // Force auto-scroll to bottom after sending own PM
                this._scheduleScrollToBottom();
            }
            return wrapped.id;
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
                _ms: nowMs,
                _seq: ++this._msgSeq,
                timestamp: new Date(now * 1000),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                nymMessageId,  // For tracking Nymchat delivery/read receipts
                senderVerified: true,
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });
            extPmList.sort((a, b) => {
                return this._compareMessages(a, b);
            });
            // Cap PM conversations at pmStorageLimit messages
            if (extPmList.length > this.pmStorageLimit) {
                this.pmMessages.set(conversationKey, extPmList.slice(-this.pmStorageLimit));
            }
            this.persistPMMessages(conversationKey);

            // Track for automatic retry if delivery receipt not received
            this.trackPendingDM(wrapped.id, sentWrappedEvents, recipientPubkey, conversationKey);

            this.addPMConversation(this.getNymFromPubkey(recipientPubkey), recipientPubkey, Date.now());
            this.movePMToTop(recipientPubkey);

            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(this.pmMessages.get(conversationKey).slice(-1)[0]);
                // Force auto-scroll to bottom after sending own PM
                this._scheduleScrollToBottom();
            }
            return wrapped.id;
        }

        throw new Error('No signing/encryption available for NIP-17 (need local privkey, extension, or remote signer)');
    },

    // Receive NIP-17 (GiftWrap 1059): unwrap, verify, store
    _isGiftWrapBacklog() {
        if (this._giftWrapInitialSyncDone) return false;
        if (this._appInitTime && Date.now() - this._appInitTime > 20000) {
            this._giftWrapInitialSyncDone = true;
            return false;
        }
        if (!this._giftWrapSyncTimer) {
            this._giftWrapSyncTimer = setTimeout(() => {
                this._giftWrapInitialSyncDone = true;
            }, 12000);
        }
        return true;
    },

    // Drop wraps with no valid 'p' tag or none addressed to us (NIP-59).
    _giftWrapIsForMe(event) {
        if (!this.pubkey) return true;
        const wrapRecipients = [];
        for (const t of (event && event.tags) || []) {
            if (Array.isArray(t) && t[0] === 'p' && typeof t[1] === 'string') {
                wrapRecipients.push(t[1]);
            }
        }
        if (wrapRecipients.length === 0) return false;
        const myEphPks = this._getAllKnownEphemeralPubkeys();
        return wrapRecipients.includes(this.pubkey) ||
            wrapRecipients.some(r => myEphPks.includes(r));
    },

    // Bounded dispatcher: caps concurrent decryptions and yields between them.
    _enqueueGiftWrapDM(event, opts) {
        if (!this._giftWrapIsForMe(event)) return;
        if (!this._decryptQueue) {
            this._decryptQueue = [];
            this._decryptActive = 0;
        }
        this._decryptQueue.push({ event, opts });
        this._pumpDecryptQueue();
    },

    _pumpDecryptQueue() {
        const MAX_PARALLEL_DECRYPTS = 3;
        while (this._decryptActive < MAX_PARALLEL_DECRYPTS && this._decryptQueue.length) {
            const { event, opts } = this._decryptQueue.shift();
            this._decryptActive++;
            Promise.resolve()
                .then(() => this.handleGiftWrapDM(event, opts))
                .catch(() => { })
                .then(() => this._yieldToIdle())
                .then(() => {
                    this._decryptActive--;
                    this._pumpDecryptQueue();
                });
        }
    },

    async handleGiftWrapDM(event, opts) {
        try {
            const NT = window.NostrTools;

            if (!this._giftWrapIsForMe(event)) return;

            const fromD1 = !!(opts && opts.fromD1);

            // Early deduplication before expensive decryption
            if (!fromD1 && this.processedPMEventIds.has(event.id)) {
                return;
            }
            this.processedPMEventIds.add(event.id);
            if (typeof this.persistDedupSets === 'function') this.persistDedupSets();

            // Update lastPMSyncTime to track newest received PM
            if (event.created_at && event.created_at > this.lastPMSyncTime) {
                this.lastPMSyncTime = event.created_at;
                this._persistLastPMSyncTime();
            }

            // Limit Set size to prevent memory leaks (keep last 5000 events)
            if (this.processedPMEventIds.size > 5000) {
                const idsArray = Array.from(this.processedPMEventIds);
                this.processedPMEventIds = new Set(idsArray.slice(-2500));
            }

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

                    // For PRIVATE_MESSAGE, extract the content and messageId from TLV.
                    // TLV format after NoisePayloadType: [type][len][value], repeated.
                    // For values <= 255 bytes the length is 1 byte; for longer values
                    // the type byte has its high bit set (0x80) and length is 2 bytes
                    // big-endian. Without the extended-length form, content over 255
                    // bytes wraps mod 256 and the message is silently truncated.
                    let pos = payloadStart + 1; // Skip NoisePayloadType byte
                    let messageContent = null;
                    let messageId = null;

                    // Strip trailing padding (0xBE bytes) for bounds checking
                    let end = bytes.length;
                    while (end > 0 && bytes[end - 1] === 0xBE) end--;

                    // Parse TLV fields
                    while (pos < end - 1) {
                        const rawType = bytes[pos];
                        const fieldType = rawType & 0x7F;
                        const isExtendedLen = (rawType & 0x80) !== 0;
                        let fieldLen;
                        let valueStart;
                        if (isExtendedLen) {
                            if (pos + 3 > end) break;
                            fieldLen = (bytes[pos + 1] << 8) | bytes[pos + 2];
                            valueStart = pos + 3;
                        } else {
                            if (pos + 2 > end) break;
                            fieldLen = bytes[pos + 1];
                            valueStart = pos + 2;
                        }
                        if (valueStart + fieldLen > end) break;

                        if (fieldType === 0x00) { // MESSAGE_ID field
                            try {
                                messageId = new TextDecoder().decode(bytes.subarray(valueStart, valueStart + fieldLen));
                            } catch (e) { }
                        } else if (fieldType === 0x01) { // CONTENT field
                            try {
                                messageContent = new TextDecoder().decode(bytes.subarray(valueStart, valueStart + fieldLen));
                            } catch (e) { }
                        }
                        pos = valueStart + fieldLen;
                    }

                    return { type: noisePayloadType, content: messageContent || '', messageId };
                } catch (e) {
                    return { type: 0x01, content };
                }
            };

            // Check if content is Bitchat format (v2: prefix)
            const isBitchatFormat = (content) => content.startsWith('v2:');

            // Remote-signer unwrap (NIP-07 extension or NIP-46): standard NIP-44
            // only, not Bitchat (which needs raw ECDH only a local key can do).
            const unwrapWithRemoteSigner = async (decryptFn) => {
                if (isBitchatFormat(event.content)) {
                    throw new Error('Bitchat format requires local key');
                }
                const sealJson = await decryptFn(event.pubkey, event.content);
                const seal = JSON.parse(sealJson);
                const rumorJson = await decryptFn(seal.pubkey, seal.content);
                const rumor = JSON.parse(rumorJson);
                return { seal, rumor };
            };

            // Pick the active remote-signer NIP-44 decrypt (extension or NIP-46).
            const _extDecrypt = window.nostr?.nip44?.decrypt
                ? (peer, ct) => window.nostr.nip44.decrypt(peer, ct) : null;
            const _n46Decrypt = (this.nostrLoginMethod === 'nip46'
                && typeof _nip46State !== 'undefined' && _nip46State && _nip46State.connected)
                ? (peer, ct) => _nip46Decrypt(peer, ct) : null;
            const remoteDecrypt = _extDecrypt || _n46Decrypt;

            let seal, rumor;
            if (this.privkey) {
                // Real key (Bitchat + NIP-44) first, then ephemeral keys (NIP-44).
                const candidates = [{ sk: this.privkey, bitchat: true, selfId: this.pubkey },
                    ...this._ephemeralCandidateSks(event).map(sk => ({ sk, bitchat: false }))];
                const res = await this._cryptoCall('unwrapGiftWrap', [event, candidates],
                    () => window.NymCrypto.unwrapGiftWrap(event, candidates));
                if (!res) return;
                ({ seal, rumor } = res);
            } else if (remoteDecrypt) {
                try {
                    ({ seal, rumor } = await unwrapWithRemoteSigner(remoteDecrypt));
                } catch (_remErr) {
                    // Remote signer can't use our locally-stored ephemeral keys, so
                    // fall back to those for group messages addressed to them.
                    const ephResult = this._tryDecryptWithEphemeralKeys(event);
                    if (ephResult) {
                        ({ seal, rumor } = ephResult);
                    } else {
                        throw _remErr;
                    }
                }
            } else {
                return; // no way to decrypt
            }

            // Validate rumor and identity
            // Accept kind 14 (DM), kind 15 (file), kind 69420 (Nymchat receipt),
            // kind 7 (group reaction gift-wrapped to the group),
            // kind 30078 (encrypted settings sync), and CALL_SIGNALING_KIND (audio/video call signaling)
            if (!rumor || (rumor.kind !== 14 && rumor.kind !== 15 && rumor.kind !== 69420 && rumor.kind !== 7 && rumor.kind !== 30078 && rumor.kind !== this.CALL_SIGNALING_KIND && rumor.kind !== this.FRIEND_PRESENCE_KIND)) {
                return;
            }

            // NIP-59 sender auth: a native seal is signed by the sender's
            // identity key, so its signer must match the claimed author or the
            // event is forged. Bitchat seals use a throwaway key and can't be
            // authenticated — decrypt but flag unverified.
            if (!rumor.pubkey) return;
            const isBitchatWrap = isBitchatFormat(event.content);
            let senderVerified = true;
            if (isBitchatWrap) {
                senderVerified = false;
            } else if (!seal || seal.pubkey !== rumor.pubkey || !NT.verifyEvent(seal)) {
                return;
            }

            // Route private friend-presence rumors (status shared by a friend
            // who runs in "Friends only" mode). Verified senders only.
            if (rumor.kind === this.FRIEND_PRESENCE_KIND) {
                if (senderVerified) this.handleFriendPresenceRumor(rumor, rumor.pubkey);
                return;
            }

            // Route audio/video call signaling rumors
            if (rumor.kind === this.CALL_SIGNALING_KIND) {
                if (!senderVerified) return;
                this.handleCallSignalingEvent({
                    id: event.id,
                    kind: rumor.kind,
                    pubkey: rumor.pubkey,
                    content: rumor.content,
                    created_at: rumor.created_at,
                    tags: rumor.tags || []
                });
                return;
            }

            // Route encrypted settings events to settings handler
            if (rumor.kind === 30078) {
                const dTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'd' && t[1])?.[1];
                const isOwn = !!this.pubkey && rumor.pubkey === this.pubkey;

                if (dTag && dTag.startsWith('nym-settings-transfer-') && rumor.pubkey !== this.pubkey) {
                    this.handleSettingsTransferEvent({
                        id: event.id,
                        kind: rumor.kind,
                        pubkey: rumor.pubkey,
                        created_at: rumor.created_at,
                        tags: rumor.tags || [],
                        content: rumor.content,
                        sig: '',
                        _giftWrapped: true
                    });
                    return;
                }

                if (isOwn) {
                    try {
                        const s = JSON.parse(rumor.content);
                        const rumorTs = rumor.created_at || 0;
                        // Core settings now arrive split across nymchat-settings-<section>
                        // gift wraps; treat every such section as core.
                        const isCoreSettings = dTag === 'nymchat-settings' || dTag.startsWith('nymchat-settings-');
                        await applyNostrSettingsAdditive(s);
                        if (isCoreSettings) {
                            const subId = opts && opts.settingsLoadSubId;
                            const buf = subId && this._settingsLoadBuffer && this._settingsLoadBuffer.get(subId);
                            if (buf) {
                                // Buffer the newest payload per d-tag so each section
                                // applies once, after the initial REQ completes.
                                if (!buf.byTag) buf.byTag = {};
                                const prev = buf.byTag[dTag];
                                if (!prev || rumorTs > prev.ts) buf.byTag[dTag] = { ts: rumorTs, settings: s };
                                if (rumorTs > buf.newestTs) buf.newestTs = rumorTs;
                            } else {
                                // Live path: apply each section's newest payload once
                                // (per d-tag) so a multi-section save all at the same
                                // timestamp applies fully, without re-applying echoes.
                                const appliedTs = (this._appliedSectionTs || (this._appliedSectionTs = {}));
                                // Per-d-tag newest, and never older than the newest core
                                // settings already applied, so a stale legacy blob can't
                                // clobber newer split sections.
                                if (rumorTs > (appliedTs[dTag] || 0) && rumorTs >= (this._lastSettingsSyncTs || 0)) {
                                    appliedTs[dTag] = rumorTs;
                                    if (rumorTs > (this._lastSettingsSyncTs || 0)) {
                                        this._lastSettingsSyncTs = rumorTs;
                                        try { localStorage.setItem('nym_last_settings_sync_ts', String(rumorTs)); } catch (_) { }
                                    }
                                    await applyNostrSettings(s);
                                }
                            }
                        }
                    } catch (_) { }
                }
                return;
            }
            if (typeof rumor.content !== 'string') {
                return;
            }

            // Register any NIP-30 custom emoji declared on this rumor
            this.ingestEmojiTags(rumor.tags);

            // NIP-92: register Blossom mirror URLs for media in this rumor
            if (typeof this.ingestImetaTags === 'function') {
                this.ingestImetaTags(rumor.tags);
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

                    if (receiptType === 'read') this.recordUserActivity(senderPubkey);

                    for (const [convKey, messages] of this.pmMessages) {
                        const msg = messages.find(m => m.nymMessageId?.toUpperCase() === receiptId);
                        if (msg && msg.isOwn) {
                            const statusOrder = { sent: 0, delivered: 1, read: 2 };
                            if ((statusOrder[receiptType] || 0) >= (statusOrder[msg.deliveryStatus] || 0)) {
                                msg.deliveryStatus = receiptType;
                                this.pendingDMs.delete(msg.id);

                                if (msg.isGroup && msg.nymMessageId && receiptType === 'read') {
                                    // Group read receipt: store the reader's avatar instead of checkmarks
                                    if (!this.groupMessageReaders.has(msg.nymMessageId)) {
                                        this.groupMessageReaders.set(msg.nymMessageId, new Map());
                                    }
                                    const readerNym = this.getNymFromPubkey(senderPubkey);
                                    this.groupMessageReaders.get(msg.nymMessageId).set(senderPubkey, readerNym);
                                    if (this.inPMMode && this.currentGroup &&
                                        convKey === this.getGroupConversationKey(this.currentGroup)) {
                                        this.updateGroupReaderAvatars(msg.nymMessageId);
                                    } else {
                                        this.channelDOMCache.delete(convKey);
                                    }
                                } else {
                                    const domId = msg.nymMessageId || msg.id;
                                    this._updateDeliveryStatusEl(domId, receiptType);
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

                    if (receiptType === 'read') this.recordUserActivity(senderPubkey);

                    if (receiptId) {
                        for (const [, messages] of this.pmMessages) {
                            const msg = messages.find(m => m.bitchatMessageId?.toUpperCase() === receiptId);
                            if (msg && msg.isOwn) {
                                const statusOrder = { sent: 0, delivered: 1, read: 2 };
                                if ((statusOrder[receiptType] || 0) >= (statusOrder[msg.deliveryStatus] || 0)) {
                                    msg.deliveryStatus = receiptType;
                                    this.pendingDMs.delete(msg.id);
                                    const domId = msg.nymMessageId || msg.id;
                                    this._updateDeliveryStatusEl(domId, receiptType);
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

            // Archive only durable content; settings/signaling/typing/receipts already returned.
            if (!fromD1) this._archivePMEvent(event);

            // Fetch profile for any PM sender we don't have (await to get nickname)
            if (!isOwn && !this.users.has(senderPubkey)) {
                await this.fetchProfileDirect(senderPubkey);
            }

            // Route group messages before 1:1 PM logic
            const groupTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'g' && typeof t[1] === 'string');
            if (groupTag) {
                await this.handleGroupMessage(rumor, event, senderPubkey, isOwn, senderVerified);
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
                        this.persistReactions(reactionMessageId);
                        this.updateMessageReactions(reactionMessageId);
                    } else {
                        const reactorNym = this.getNymFromPubkey(senderPubkey);
                        if (!this.reactions.has(reactionMessageId)) this.reactions.set(reactionMessageId, new Map());
                        const msgReactions = this.reactions.get(reactionMessageId);
                        if (!msgReactions.has(emoji)) msgReactions.set(emoji, new Map());
                        msgReactions.get(emoji).set(senderPubkey, reactorNym);
                        this.persistReactions(reactionMessageId);
                        this.updateMessageReactions(reactionMessageId);

                        if (senderPubkey !== this.pubkey) {
                            this._notifyPmReactionToOurMessage(reactionMessageId, emoji, senderPubkey, event, rumor);
                        }
                    }
                    // If the target bubble isn't in the current DOM, drop its
                    // cached render so the reaction shows after channel switch.
                    if (!document.querySelector(`[data-message-id="${CSS.escape(reactionMessageId)}"]`)) {
                        for (const [key, msgs] of this.pmMessages.entries()) {
                            if (msgs.some(m => m.id === reactionMessageId || m.nymMessageId === reactionMessageId)) {
                                this.channelDOMCache.delete(key);
                                break;
                            }
                        }
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

            if (this.verifiedBot && peerPubkey === this.verifiedBot.pubkey) {
                const clearedAt = this._getBotPmClearedAt();
                if (clearedAt && (rumor.created_at || 0) <= clearedAt) return;
            }

            // Re-open closed PMs only when the incoming message is newer than
            // the close timestamp. Stale relay backlog must not resurrect a
            // conversation the user just deleted.
            if (this.closedPMs.has(peerPubkey)) {
                const closedAt = this.closedPMTimes?.get(peerPubkey) || 0;
                const msgTs = Math.floor(rumor.created_at || 0);
                if (msgTs > closedAt) {
                    this.closedPMs.delete(peerPubkey);
                    if (this.closedPMTimes) this.closedPMTimes.delete(peerPubkey);
                    try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
                    try { localStorage.setItem('nym_closed_pm_times', JSON.stringify(Object.fromEntries(this.closedPMTimes || new Map()))); } catch { }
                    this._debouncedNostrSettingsSave();
                } else {
                    return;
                }
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
            // implementations. Exempt our own self-wraps
            if (!isOwn && messageContent && messageContent.length > 80 &&
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

            // Dedup for dual-wrapped messages: when nymchat sends both bitchat +
            // nymchat format to unknown peers, the recipient may decrypt both.
            // Match first on the shared nymMessageId from the `x` tag (set on
            // both wraps), since older senders truncate bitchat content over
            // 255 bytes and content-equality would miss those duplicates.
            // Fall back to sender + content + close-timestamp for legacy events
            // that lacked the `x` tag.
            const nymMsgIdFromRumor = this.getNymMessageId(rumor);
            let dupMsg = null;
            if (nymMsgIdFromRumor) {
                dupMsg = list.find(m => m.pubkey === senderPubkey && m.nymMessageId === nymMsgIdFromRumor);
            }
            if (!dupMsg) {
                dupMsg = list.find(m => m.pubkey === senderPubkey && m.content === messageContent && Math.abs((m.timestamp?.getTime() / 1000 || 0) - tsSec) < 5);
            }
            if (dupMsg) {
                let needsRerender = false;
                if (!dupMsg.nymMessageId && nymMsgIdFromRumor) {
                    // Reactions stored under the event ID must follow the message
                    // to its nymMessageId, which is the ID the DOM renders with.
                    this._migrateReactionKey(dupMsg.id, nymMsgIdFromRumor);
                    dupMsg.nymMessageId = nymMsgIdFromRumor;
                    // Update the DOM element's data-message-id to use nymMessageId
                    const oldEl = document.querySelector(`[data-message-id="${dupMsg.id}"]`);
                    if (oldEl) {
                        oldEl.dataset.messageId = nymMsgIdFromRumor;
                    }
                    this.updateMessageReactions(nymMsgIdFromRumor);
                    needsRerender = true;
                }
                // If the duplicate carries longer content, prefer it — the existing
                // copy may be a bitchat wrap with content truncated by an older sender.
                if (messageContent && messageContent.length > (dupMsg.content || '').length) {
                    dupMsg.content = messageContent;
                    needsRerender = true;
                }
                if (senderVerified === true && dupMsg.senderVerified !== true) {
                    dupMsg.senderVerified = true;
                    // Flip the on-screen lock immediately so the verified copy
                    // wins even when the unverified Bitchat copy rendered first.
                    this._setMessageVerifiedDOM(dupMsg.nymMessageId || dupMsg.id, true);
                    needsRerender = true;
                }
                if (needsRerender) {
                    this.channelDOMCache.delete(conversationKey);
                    this.persistPMMessages(conversationKey);
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
                _ms: this._extractEventMs(rumor, tsSec),
                _seq: ++this._msgSeq,
                timestamp: new Date(tsSec * 1000),
                isOwn,
                isPM: true,
                conversationKey,
                conversationPubkey: peerPubkey,
                eventKind: 1059,
                isHistorical: this._isGiftWrapBacklog(),
                senderVerified,
                bitchatMessageId: parsed.messageId,  // For sending Bitchat read receipts
                nymMessageId: nymMsgId  // For sending Nymchat read receipts
            };

            list.push(msg);
            list.sort((a, b) => {
                return this._compareMessages(a, b);
            });
            // Cap PM conversations at pmStorageLimit messages to prevent memory bloat
            if (list.length > this.pmStorageLimit) {
                list = list.slice(-this.pmStorageLimit);
            }
            this.pmMessages.set(conversationKey, list);
            this.persistPMMessages(conversationKey);

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
                if (typeof this._markChannelRead === 'function') {
                    this._markChannelRead(conversationKey, msg.created_at);
                }
                // Send READ receipt if viewing the conversation, and mark
                // the message so openPM doesn't re-send on next open.
                if (!isOwn) {
                    let sent = false;
                    if (parsed.messageId && this.bitchatUsers.has(senderPubkey)) {
                        this.sendBitchatReceipt(parsed.messageId, 0x02, senderPubkey); // 0x02 = READ
                        sent = true;
                    }
                    if (nymMsgId && this.nymUsers.has(senderPubkey)) {
                        this.sendNymReceipt(nymMsgId, 'read', senderPubkey);
                        sent = true;
                    }
                    if (sent) msg.readReceiptSent = true;
                    this.recordOwnActivity();
                }
            } else {
                // Not viewing this conversation — leave the cached DOM in
                // place. loadPMMessages does a partial-cache restore that
                // appends the trailing new messages to the cached fragment,
                // avoiding a full re-render of long PM threads.
                if (!isOwn) {
                    const pmSenderBlocked = this.blockedUsers.has(peerPubkey) || this.hasBlockedKeyword(msg.content, msg.author);
                    const ageMs = Date.now() - (tsSec * 1000);
                    const treatAsHistorical = msg.isHistorical || ageMs > 30000;
                    const pmChannelInfo = {
                        type: 'pm',
                        nym: msg.author,
                        pubkey: peerPubkey,
                        id: conversationKey,
                        eventId: event.id
                    };
                    this.updateUnreadCount(conversationKey);
                    if (!pmSenderBlocked) {
                        if (!treatAsHistorical) {
                            this.showNotification(`PM from ${msg.author}`, messageContent, pmChannelInfo, tsSec * 1000);
                        } else {
                            this._addNotificationToHistory(`PM from ${msg.author}`, messageContent, pmChannelInfo, tsSec * 1000);
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

    // Only durable (logged-in) identities mirror PMs to D1 for cross-device restore.
    _pmArchiveAllowed() {
        if (!this.pubkey) return false;
        if (!this._getApiHost || !this._getApiHost()) return false;
        if (typeof isNostrLoggedIn === 'function' && !isNostrLoggedIn()) return false;
        return true;
    },

    // Queue a gift wrap (kind 1059, addressed to us) for batched upload to D1.
    _archivePMEvent(event) {
        if (!event || typeof event.id !== 'string') return;
        if (!this._pmArchiveAllowed()) return;
        // The server only stores wraps addressed to the authenticated pubkey.
        const addressedToMe = (event.tags || []).some(t =>
            Array.isArray(t) && t[0] === 'p' && t[1] === this.pubkey);
        if (!addressedToMe) return;
        if (!this._pmArchivedIds) this._pmArchivedIds = new Set();
        if (this._pmArchivedIds.has(event.id)) return;
        this._pmArchivedIds.add(event.id);
        if (this._pmArchivedIds.size > 6000) {
            this._pmArchivedIds = new Set(Array.from(this._pmArchivedIds).slice(-4000));
        }
        if (!this._pmArchiveQueue) this._pmArchiveQueue = [];
        this._pmArchiveQueue.push(event);
        if (this._pmArchiveQueue.length > 300) this._pmArchiveQueue.shift();
        if (this._pmArchiveFlushTimer) return;
        this._pmArchiveFlushTimer = setTimeout(() => {
            this._pmArchiveFlushTimer = null;
            this._flushPMArchive();
        }, 4000);
    },

    async _flushPMArchive() {
        if (!this._pmArchiveQueue || this._pmArchiveQueue.length === 0) return;
        const batch = this._pmArchiveQueue.splice(0, 100);
        try {
            await this._storageApiRequest('pm-put', { events: batch });
        } catch (_) {
            // Best-effort: drop on failure rather than risk an upload loop.
        }
        if (this._pmArchiveQueue.length > 0 && !this._pmArchiveFlushTimer) {
            this._pmArchiveFlushTimer = setTimeout(() => {
                this._pmArchiveFlushTimer = null;
                this._flushPMArchive();
            }, 4000);
        }
    },

    _yieldToIdle() {
        return new Promise(resolve => {
            if (typeof requestIdleCallback === 'function') {
                try { requestIdleCallback(() => resolve(), { timeout: 50 }); return; } catch (_) { }
            }
            if (typeof requestAnimationFrame === 'function') {
                requestAnimationFrame(() => resolve());
            } else {
                setTimeout(resolve, 0);
            }
        });
    },

    async pmRestoreFromD1() {
        if (!this._pmArchiveAllowed()) return;
        this._pmD1OldestTs = null;
        this._pmD1NoMore = false;
        this._pmD1InitialPageSize = 200;
        const maxPages = 5;
        let before = 0;
        for (let page = 0; page < maxPages; page++) {
            const got = await this._pmRestoreD1Page({ before, limit: this._pmD1InitialPageSize });
            if (!got || this._pmD1NoMore || !this._pmD1OldestTs) break;
            before = this._pmD1OldestTs;
        }
    },

    async pmLoadOlderFromD1() {
        if (this._pmD1NoMore) return false;
        if (!this._pmD1OldestTs) return false;
        return this._pmRestoreD1Page({ before: this._pmD1OldestTs, limit: 200 });
    },

    async _pmRestoreD1Page({ before = 0, limit = 200 } = {}) {
        if (!this._pmArchiveAllowed()) return false;
        if (this._pmD1Loading) return false;
        this._pmD1Loading = true;
        const events = [];
        let hasMore = false;
        try {
            const resp = await this._storageApiStream('pm-get', { since: 0, before, limit });
            hasMore = resp.headers.get('X-Has-More') === '1';
            await this._readNdjsonStream(resp, (ev) => events.push(ev));
        } catch (_) {
            this._pmD1Loading = false;
            return false;
        }
        if (!hasMore || events.length < limit) this._pmD1NoMore = true;
        events.sort((a, b) => (a.created_at || 0) - (b.created_at || 0));
        if (events.length) {
            const oldest = events[0].created_at || 0;
            if (oldest && (!this._pmD1OldestTs || oldest < this._pmD1OldestTs)) {
                this._pmD1OldestTs = oldest;
            }
        }
        if (!this._pmArchivedIds) this._pmArchivedIds = new Set();
        const CHUNK = 10;
        for (let i = 0; i < events.length; i += CHUNK) {
            const end = Math.min(i + CHUNK, events.length);
            for (let k = i; k < end; k++) {
                const ev = events[k];
                if (!ev || typeof ev.id !== 'string') continue;
                if (this._pmArchivedIds.has(ev.id)) continue;
                this._pmArchivedIds.add(ev.id);
                try { await this.handleGiftWrapDM(ev, { fromD1: true }); } catch (_) { }
            }
            if (end < events.length) await this._yieldToIdle();
        }
        this._pmD1Loading = false;
        return events.length > 0;
    },

    async pmLazyLoadOlderForConversation(conversationKey) {
        if (!conversationKey) return false;
        if (this._pmD1NoMore || this._pmD1Loading) return false;
        const beforeLen = this.getFilteredPMMessages(conversationKey).length;
        const fetched = await this.pmLoadOlderFromD1();
        if (!fetched) return false;
        const afterLen = this.getFilteredPMMessages(conversationKey).length;
        const added = afterLen - beforeLen;
        if (added <= 0) return false;
        const cur = this.pmRenderedStart.get(conversationKey) || 0;
        this.pmRenderedStart.set(conversationKey, cur + added);
        return this.loadOlderPMMessages(conversationKey);
    },

    async sendPM(content, recipientPubkey) {
        try {
            if (!this.connected) throw new Error('Not connected to relay');
            if (!content || !content.trim()) return false;

            const wrapped = await this.sendNIP17PM(content, recipientPubkey);
            this.recordOwnActivity();
            if (this.isVerifiedBot(recipientPubkey)) {
                this._handleBotPM(content, typeof wrapped === 'string' ? wrapped : null);
            }
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
                _ms: Date.now(),
                _seq: ++this._msgSeq,
                timestamp: new Date(_nowFail * 1000),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                senderVerified: true,
                deliveryStatus: 'failed'
            };
            const failList = this.pmMessages.get(conversationKey);
            failList.push(failedMsg);
            failList.sort((a, b) => {
                return this._compareMessages(a, b);
            });
            // Invalidate cached DOM for this conversation
            this.channelDOMCache.delete(conversationKey);
            this.persistPMMessages(conversationKey);
            // Display the failed message if currently viewing this PM
            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(failedMsg);
            }
            return false;
        }
    },

    // Sign a short-lived NIP-98-style auth event so the bot worker can verify
    // that the caller actually controls the pubkey it claims (prevents draining
    // someone else's credits or reading their balance).
    // Sign a NIP-98-style (kind 27235) auth event BOUND to the specific
    // endpoint + method + action so the worker can reject a captured signature
    // replayed against a different request/action. Money actions are signed
    // fresh each time (the worker enforces single-use for them); routine
    // actions reuse a short-lived per-action signature so extension/remote
    // signers aren't re-prompted on every write.
    async _signBotAuth(action, endpoint) {
        endpoint = endpoint || 'bot';
        const apiHost = this._getApiHost();
        const url = apiHost ? `https://${apiHost}/api/${endpoint}` : '';
        const nowSec = Math.floor(Date.now() / 1000);
        const MONEY = {
            'transfer-credits': 1, 'create-invoice': 1, 'claim-credits': 1,
            'shop-buy-invoice': 1, 'shop-claim': 1, 'shop-transfer': 1, 'shop-redeem': 1
        };
        const sensitive = !!MONEY[action];
        const cacheKey = (action || '') + '|' + url;
        if (!(this._botAuthCache instanceof Map)) this._botAuthCache = new Map();
        if (!sensitive) {
            const cached = this._botAuthCache.get(cacheKey);
            // Stay well under the worker's 120s window to avoid edge-of-window rejects.
            if (cached && cached.pubkey === this.pubkey && (nowSec - cached.auth.created_at) < 90) {
                return cached.auth;
            }
        }
        const tags = [['domain', 'nymbot-pm'], ['method', 'POST']];
        if (url) tags.push(['u', url]);
        if (action) tags.push(['action', action]);
        const event = {
            kind: 27235,
            created_at: nowSec,
            tags,
            content: 'nymbot-pm-auth',
            pubkey: this.pubkey
        };
        const auth = await this.signEvent(event);
        if (!sensitive) this._botAuthCache.set(cacheKey, { pubkey: this.pubkey, auth });
        return auth;
    },

    // Ask the worker to wipe the server-side gift-wrap thread it uses for AI context
    async _clearBotServerThread() {
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) return;
            const auth = await this._signBotAuth('clear-history');
            await fetch(`https://${apiHost}/api/bot`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'clear-history', pubkey: this.pubkey, auth })
            });
        } catch { /* best effort */ }
    },

    _getBotPmClearedAt() {
        if (typeof this._botPmClearedAt === 'number') return this._botPmClearedAt;
        try {
            const v = parseInt(localStorage.getItem('nym_botpm_cleared_at') || '0', 10);
            this._botPmClearedAt = Number.isFinite(v) ? v : 0;
        } catch { this._botPmClearedAt = 0; }
        return this._botPmClearedAt;
    },

    _setBotPmClearedAt(ts) {
        this._botPmClearedAt = ts;
        try { localStorage.setItem('nym_botpm_cleared_at', String(ts)); } catch { }
    },

    // First-person Nymbot introduction shown when a user first opens the premium chat
    _botWelcomeHtml() {
        return [
            'Hey, I\'m <strong>Nymbot</strong> 👋 — your private, end-to-end encrypted 1:1 AI assistant.',
            '',
            'I\'m smarter than the free public-channel bot. I read each message, figure out the type of task (coding, reasoning/math, creative writing, translation, or general chat) and route it to the best AI model for the job — so my answers are sharper.',
            '',
            '<strong>Here\'s how to get the most out of me:</strong>',
            '• Just type normally — I use our whole conversation as context.',
            '• Start a message with <code>!</code> to get a one-off answer that ignores all earlier chat history (e.g. <code>!what is 2+2</code>).',
            '• Quote-reply any message to ask a follow-up about it — I\'ll see what you\'re replying to.',
            '• <code>?clear</code> — wipe this chat and start fresh.',
            '• <code>?balance</code> — check your credit balance (also shown in the header).',
            '• <code>?buy</code> — purchase more credits. <code>?gift @nym#xxxx</code> — gift credits to someone.',
            '• <code>?transfer @nym#xxxx confirm</code> — move ALL your credits to another pubkey (great for switching nyms).',
            '',
            '<strong>Pricing:</strong> general chat, creative writing, and translation replies cost <strong>1 credit</strong>. Coding and reasoning/math replies cost <strong>2 credits</strong> (they use larger models). Credits are tied to your nym — save your nsec so you don\'t lose them.',
            '',
            'So, what can I help you with?'
        ].join('<br>');
    },

    // Render the Nymbot welcome as a message bubble from Nymbot itself
    _displayBotWelcomeMessage() {
        const container = document.getElementById('messagesContainer');
        if (!container || !this.verifiedBot) return;
        const pubkey = this.verifiedBot.pubkey;
        const botNym = this.parseNymFromDisplay(this.getNymFromPubkey(pubkey));
        const suffix = this.getPubkeySuffix(pubkey);
        const avatarSrc = this.getAvatarUrl(pubkey);
        const safePk = this._safePubkey(pubkey);
        const userColorClass = this.getUserColorClass(pubkey);
        const now = new Date();
        const fullTimestamp = now.toLocaleString('en-US', {
            year: 'numeric', month: 'short', day: 'numeric',
            hour: '2-digit', minute: '2-digit', second: '2-digit',
            hour12: this.settings.timeFormat === '12hr'
        });
        const bubbleTime = now.toLocaleTimeString('en-US', {
            hour: '2-digit', minute: '2-digit', hour12: this.settings.timeFormat === '12hr'
        });
        const time = this.settings.showTimestamps ? bubbleTime : '';
        const verifiedBadge = '<span class="verified-badge" title="Nymchat Bot">✓</span>';
        const displayAuthor = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy"><span class="nym-bracket">&lt;</span>${this.escapeHtml(botNym)}<span class="nym-suffix">#${suffix}</span>`;

        const el = document.createElement('div');
        el.className = 'message pm';
        el.dataset.pubkey = pubkey;
        el.dataset.messageId = 'nymbot-welcome';
        el.dataset.author = botNym;
        el.dataset.timestamp = now.getTime();
        el.innerHTML = `
    ${time ? `<span class="message-time ${this.settings.timeFormat === '12hr' ? 'time-12hr' : ''}" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${time}</span>` : ''}
    <span class="message-author ${userColorClass}"><span class="bubble-time" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${bubbleTime}</span><span class="author-clickable">${displayAuthor}${verifiedBadge}</span><span class="nym-bracket">&gt;</span></span>
    <span class="message-content ${userColorClass}">${this._botWelcomeHtml()}<span class="bubble-time-inner" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${bubbleTime}</span></span>
`;
        container.appendChild(el);
        this._updateBubbleGrouping(el);
        this._scheduleScrollToBottom();
    },

    // Slightly-edited welcome used for the proactive first-contact PM that brand-new
    // users receive. Written in markdown so it renders through the normal pipeline.
    _botFirstContactText() {
        return [
            'Welcome to **Nymchat** 👋 — I\'m **Nymbot**, your built-in AI assistant.',
            '',
            'In any public channel you can ask me anything for **free** — just type `?ask <your question>` or mention `@Nymbot`. Type `?help` in a channel to see everything I can do.',
            '',
            'Right here in our private 1:1 chat is the **premium** tier: it\'s end-to-end encrypted and I route each message to the best AI model for the job (coding, reasoning/math, creative writing, translation, or general chat). These private replies cost **credits** — general chat, creative writing, and translation cost 1 credit each; coding and reasoning/math cost 2 credits each.',
            '',
            'Type `?buy` to get credits and `?balance` to check your balance. Credits are tied to your nym, so save your nsec to keep them.',
            '',
            'So, what can I help you with?'
        ].join('\n');
    },

    // Brand-new users get a proactive PM from Nymbot so a highlighted conversation
    // appears in their sidebar from the start. Sent locally, once per device.
    _maybeSendBotWelcomePM() {
        try {
            if (localStorage.getItem('nym_botpm_welcomed') === 'true') return;
        } catch { }
        const bot = this.verifiedBot;
        if (!bot || !bot.pubkey || !this.pubkey) return;
        const conversationKey = this.getPMConversationKey(bot.pubkey);
        const list = this.pmMessages.get(conversationKey) || [];
        if (list.length > 0) {
            try { localStorage.setItem('nym_botpm_welcomed', 'true'); } catch { }
            return;
        }
        const botNym = this.parseNymFromDisplay(this.getNymFromPubkey(bot.pubkey));
        const nowSec = Math.floor(Date.now() / 1000);
        const msg = {
            id: 'nymbot-welcome-' + nowSec,
            author: botNym,
            pubkey: bot.pubkey,
            content: this._botFirstContactText(),
            created_at: nowSec,
            _ms: Date.now(),
            _seq: ++this._msgSeq,
            timestamp: new Date(nowSec * 1000),
            isOwn: false,
            isPM: true,
            conversationKey,
            conversationPubkey: bot.pubkey,
            eventKind: 1059,
            isBot: true,
            senderVerified: true
        };
        list.push(msg);
        this.pmMessages.set(conversationKey, list);
        this.persistPMMessages(conversationKey);
        this.addPMConversation(botNym, bot.pubkey, nowSec * 1000);
        this.movePMToTop(bot.pubkey, nowSec * 1000);
        this.updateUnreadCount(conversationKey);
        try { localStorage.setItem('nym_botpm_welcomed', 'true'); } catch { }
        if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(2000);
    },

    // Wipe the Nymbot conversation and start fresh (premium ?clear command)
    _clearBotPMHistory() {
        const pubkey = this.verifiedBot && this.verifiedBot.pubkey;
        if (!pubkey) return;
        const conversationKey = this.getPMConversationKey(pubkey);
        this._setBotPmClearedAt(Math.floor(Date.now() / 1000));
        this._clearBotServerThread();
        this.pmMessages.set(conversationKey, []);
        this.channelDOMCache.delete(conversationKey);
        if (typeof this._cacheDelete === 'function') this._cacheDelete('pms', conversationKey);
        this.persistPMMessages(conversationKey);
        if (this.inPMMode && this.currentPM === pubkey) {
            const container = document.getElementById('messagesContainer');
            if (container) {
                container.innerHTML = '';
                container.dataset.lastChannel = '';
            }
            this.loadPMMessages(conversationKey, true);
        }
        this.displaySystemMessage('Nymbot chat cleared — starting fresh. Earlier messages are no longer used as context.');
    },

    async _handleBotTransferCommand(trimmed) {
        const raw = trimmed.replace(/^\?transfer\b/i, '').trim();
        const parts = raw.split(/\s+/).filter(Boolean);
        const confirming = parts.length && /^confirm$/i.test(parts[parts.length - 1]);
        const targetArg = (confirming ? parts.slice(0, -1) : parts).join(' ').trim().replace(/^@/, '');
        if (!targetArg) {
            this.displaySystemMessage('Usage: ?transfer @nym#xxxx or ?transfer <npub/hex pubkey> — moves your entire Nymbot credit balance to another pubkey. Append "confirm" to execute (e.g. ?transfer @friend#a1b2 confirm).');
            return;
        }
        let targetPubkey = null;
        if (/^[0-9a-f]{64}$/i.test(targetArg)) {
            targetPubkey = targetArg.toLowerCase();
        } else if (/^npub1/i.test(targetArg) && window.NostrTools && window.NostrTools.nip19) {
            try {
                const decoded = window.NostrTools.nip19.decode(targetArg);
                if (decoded && decoded.type === 'npub') targetPubkey = String(decoded.data).toLowerCase();
            } catch (e) { }
        }
        if (!targetPubkey) targetPubkey = this.resolvePubkeyFromNym(targetArg);
        if (!targetPubkey) {
            this.displaySystemMessage(`Could not resolve "${targetArg}". Try ?transfer with a full nym (e.g. ?transfer @friend#a1b2 confirm), an npub, or a 64-char hex pubkey.`);
            return;
        }
        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You can't transfer credits to your own pubkey.");
            return;
        }
        const targetNym = this.stripPubkeySuffix(this.getNymFromPubkey(targetPubkey)) || targetPubkey.slice(0, 8);
        if (!confirming) {
            const balance = await this._checkBotCredits(false);
            const have = typeof balance === 'number' ? balance : (this._lastBotCredits || 0);
            if (!have || have <= 0) {
                this.displaySystemMessage('You have no Nymbot credits to transfer.');
                return;
            }
            this.displaySystemMessage(`Transfer ALL ${have} credit${have === 1 ? '' : 's'} to @${targetNym}? This empties your balance. To confirm, type: ?transfer @${targetNym}#${this.getPubkeySuffix(targetPubkey)} confirm`);
            return;
        }
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) return;
            const auth = await this._signBotAuth('transfer-credits');
            const resp = await fetch(`https://${apiHost}/api/bot`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'transfer-credits', pubkey: this.pubkey, auth, targetPubkey })
            });
            const data = await resp.json().catch(() => ({}));
            if (!resp.ok || !data || data.error) {
                this.displaySystemMessage('Transfer failed: ' + ((data && data.error) || 'request failed'));
                return;
            }
            this._setBotCreditDisplay(0);
            this.displaySystemMessage(`Transferred ${data.transferred} credit${data.transferred === 1 ? '' : 's'} to @${targetNym}. Your balance is now 0.`);
        } catch (e) {
            this.displaySystemMessage('Transfer failed. Please try again.');
        }
    },

    // Show/clear a synthetic "Nymbot is typing" indicator in the bot PM
    _setBotTyping(on) {
        const convKey = this.getPMConversationKey(this.verifiedBot.pubkey);
        if (!this.typingUsers.has(convKey)) this.typingUsers.set(convKey, new Map());
        const typers = this.typingUsers.get(convKey);
        const botPk = this.verifiedBot.pubkey;
        const existing = typers.get(botPk);
        if (existing && existing.timeout) clearTimeout(existing.timeout);
        if (on) {
            const timeout = setTimeout(() => { typers.delete(botPk); this.renderTypingIndicator(); }, 30000);
            typers.set(botPk, { nym: 'Nymbot', timeout, timestamp: Date.now() });
        } else {
            typers.delete(botPk);
        }
        this.renderTypingIndicator();
    },

    _findMessageById(messageId) {
        for (const [key, msgs] of this.pmMessages.entries()) {
            const m = msgs.find(x => x.id === messageId || x.nymMessageId === messageId);
            if (m) return { msg: m, convKey: key, store: 'pm' };
        }
        for (const [key, msgs] of this.messages.entries()) {
            const m = msgs.find(x => x.id === messageId);
            if (m) return { msg: m, convKey: key, store: 'channel' };
        }
        return null;
    },

    _notifyPmReactionToOurMessage(messageId, emoji, reactorPubkey, event, rumor) {
        const found = this._findMessageById(messageId);
        if (!found || found.store !== 'pm') return;
        if (found.msg.pubkey !== this.pubkey) return;

        const convKeyBody = found.convKey.startsWith('pm-') ? found.convKey.slice(3) : found.convKey;
        const peer = convKeyBody.split('-').find(p => p && p !== this.pubkey) || convKeyBody;
        const reactorNym = this.getNymFromPubkey(reactorPubkey);
        const eventId = (event && event.id) || (rumor && rumor.id) || '';
        const ts = (rumor && rumor.created_at ? rumor.created_at * 1000 : Date.now());
        const msgPreview = (found.msg.content || '').split('\n').filter(l => !l.startsWith('>')).join(' ').trim();
        const preview = msgPreview.length > 80 ? msgPreview.slice(0, 80) + '…' : msgPreview;
        const body = preview ? `reacted ${emoji} to: "${preview}"` : `reacted ${emoji} to your message`;
        const channelInfo = {
            type: 'reaction',
            id: eventId,
            eventId,
            pubkey: reactorPubkey,
            messageId,
            sourceType: 'pm',
            sourcePubkey: peer
        };
        const isHistorical = (Date.now() - ts) > 10000;
        if (isHistorical) this._addNotificationToHistory(reactorNym, body, channelInfo, ts);
        else this.showNotification(reactorNym, body, channelInfo, ts);
    },

    _notifyGroupReactionToOurMessage(messageId, emoji, reactorPubkey, groupId, rumor) {
        const found = this._findMessageById(messageId);
        if (!found || found.store !== 'pm') return;
        if (found.msg.pubkey !== this.pubkey) return;

        const reactorNym = this.getNymFromPubkey(reactorPubkey);
        const ts = (rumor && rumor.created_at ? rumor.created_at * 1000 : Date.now());
        const eventId = (rumor && rumor.id) || '';
        const msgPreview = (found.msg.content || '').split('\n').filter(l => !l.startsWith('>')).join(' ').trim();
        const preview = msgPreview.length > 80 ? msgPreview.slice(0, 80) + '…' : msgPreview;
        const body = preview ? `reacted ${emoji} to: "${preview}"` : `reacted ${emoji} to your message`;
        const channelInfo = {
            type: 'reaction',
            id: eventId,
            eventId,
            pubkey: reactorPubkey,
            messageId,
            sourceType: 'group',
            sourceGroupId: groupId
        };
        const isHistorical = (Date.now() - ts) > 10000;
        if (isHistorical) this._addNotificationToHistory(reactorNym, body, channelInfo, ts);
        else this.showNotification(reactorNym, body, channelInfo, ts);
    },

    // Advance sent/read receipts for our messages in the Nymbot chat
    _markBotPMReceipts(status) {
        const convKey = this.getPMConversationKey(this.verifiedBot.pubkey);
        const messages = this.pmMessages.get(convKey);
        if (!messages) return;
        const statusOrder = { sent: 0, delivered: 1, read: 2 };
        let changed = false;
        for (const msg of messages) {
            if (!msg.isOwn || msg.deliveryStatus === 'failed') continue;
            if ((statusOrder[status] || 0) > (statusOrder[msg.deliveryStatus] || 0)) {
                msg.deliveryStatus = status;
                this.pendingDMs.delete(msg.id);
                this._updateDeliveryStatusEl(msg.nymMessageId || msg.id, status);
                changed = true;
            }
        }
        if (changed) this.channelDOMCache.delete(convKey);
    },

    // Update the cached Nymbot credit count and the chat-header indicator
    _setBotCreditDisplay(balance) {
        if (typeof balance === 'number') this._lastBotCredits = balance;
        const el = document.getElementById('botCreditMeta');
        if (el && typeof this._lastBotCredits === 'number') {
            el.textContent = `${this._lastBotCredits} credit${this._lastBotCredits === 1 ? '' : 's'} left`;
        }
    },

    // Paint the header credit indicator for the open Nymbot chat, then refresh it
    async _refreshBotCreditMeta() {
        this._setBotCreditDisplay();
        const bal = await this._checkBotCredits(false);
        if (bal === null && typeof this._lastBotCredits !== 'number') {
            const el = document.getElementById('botCreditMeta');
            if (el) el.textContent = 'credits unavailable';
        }
    },

    // Process a message the user sent to Nymbot in a private chat
    async _handleBotPM(content, wrapId) {
        const trimmed = (content || '').trim();
        this._markBotPMReceipts('delivered');
        if (/^\?balance\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this._checkBotCredits(true);
            return;
        }
        if (/^\?buy\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this.showBotCreditsModal();
            return;
        }
        if (/^\?clear\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this._clearBotPMHistory();
            return;
        }
        if (/^\?transfer\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this._handleBotTransferCommand(trimmed);
            return;
        }
        if (/^\?gift\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            const arg = trimmed.replace(/^\?gift\b/i, '').trim().replace(/^@/, '');
            if (!arg) {
                this.displaySystemMessage('Usage: ?gift @nym#xxxx — gift Nymbot credits to another user.');
                return;
            }
            const giftPubkey = this.resolvePubkeyFromNym(arg);
            if (!giftPubkey) {
                this.displaySystemMessage(`Could not find user "${arg}". Try ?gift with their full nym (e.g. ?gift @cyber_wolf#a3f2).`);
                return;
            }
            const giftNym = this.stripPubkeySuffix(this.getNymFromPubkey(giftPubkey));
            this.showBotCreditsModal({ pubkey: giftPubkey, nym: giftNym });
            return;
        }
        if (!wrapId) {
            this.displaySystemMessage('Nymbot: could not publish your encrypted message. Please try again.');
            return;
        }
        this._setBotTyping(true);
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) { this._setBotTyping(false); return; }
            const auth = await this._signBotAuth('pm');
            const isFresh = /^\s*!\s*\S/.test(content);
            // Send only the current message's wrap ID; the worker maintains the
            // ordered thread server-side. fresh (!) tells it to skip history.
            const resp = await fetch(`https://${apiHost}/api/bot`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'pm', pubkey: this.pubkey, auth, eventId: wrapId, fresh: isFresh })
            });
            const data = await resp.json().catch(() => ({}));
            this._setBotTyping(false);
            this._markBotPMReceipts('read');
            if (data && data.noCredits) {
                const msg = data.error
                    || `You're out of Nymbot credits (${data.balance || 0} left). Zap Nymbot or type ?buy to purchase more.`;
                this.displaySystemMessage(msg);
                if (typeof data.balance === 'number') this._setBotCreditDisplay(data.balance);
                this.showBotCreditsModal();
                return;
            }
            if (!resp.ok || !data || data.error) {
                this.displaySystemMessage('Nymbot: ' + ((data && data.error) || 'request failed'));
                return;
            }
            if (data.event) {
                this.sendDMToRelays(['EVENT', data.event]);
                this.handleGiftWrapDM(data.event, {});
            }
            // Publish the bot's self-addressed copy to the relays so the worker
            // can re-fetch and decrypt its own reply as context on later turns.
            if (data.selfEvent && /^[0-9a-f]{64}$/i.test(data.selfEvent.id || '')) {
                this.sendDMToRelays(['EVENT', data.selfEvent]);
            }
            if (typeof data.balance === 'number') {
                this._setBotCreditDisplay(data.balance);
                if (data.cost && data.cost > 1) {
                    this.displaySystemMessage(`${data.taskType || 'Heavy'} reply used ${data.cost} credits. Balance: ${data.balance}.`);
                }
                if (data.lowBalance) {
                    this.displaySystemMessage(`Nymbot credits running low: ${data.balance} credit${data.balance === 1 ? '' : 's'} left. Type ?buy to top up.`);
                }
            }
        } catch (e) {
            this._setBotTyping(false);
            this.displaySystemMessage('Nymbot is unavailable right now. Please try again.');
        }
    },

    // Check the user's Nymbot credit balance; optionally show it as a message
    async _checkBotCredits(display) {
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) return null;
            const auth = await this._signBotAuth('balance');
            const resp = await fetch(`https://${apiHost}/api/bot`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'balance', pubkey: this.pubkey, auth })
            });
            const data = await resp.json().catch(() => ({}));
            if (!resp.ok || !data || data.error) {
                if (display) this.displaySystemMessage('Nymbot: ' + ((data && data.error) || 'could not check balance'));
                return null;
            }
            this._setBotCreditDisplay(data.balance);
            if (display) {
                const b = data.balance || 0;
                this.displaySystemMessage(`Nymbot credit balance: ${b} private message${b === 1 ? '' : 's'} remaining.` + (b <= 0 ? ' Type ?buy to purchase more.' : ''));
            }
            return data.balance;
        } catch (e) {
            if (display) this.displaySystemMessage('Could not reach Nymbot to check your balance.');
            return null;
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
                : this.isVerifiedBot(pubkey)
                    ? `<span class="verified-badge" title="${this.verifiedBot.title}">✓</span>`
                    : '';
            const sidebarFlair = this.getFlairForUser(pubkey);
            const sidebarFriendBadge = this.getFriendBadgeHtml(pubkey);
            const pmNameEl = item.querySelector('.pm-name');
            if (pmNameEl) {
                pmNameEl.innerHTML = `${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${sidebarFlair} ${verifiedBadge}${sidebarFriendBadge}`;
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
            `<span class="supporter-badge"><span class="supporter-badge-icon">${this.getSupporterTrophyIcon()}</span></span>` : '';
        const safePk = this._safePubkey(pubkey);
        const authorSig = `${clean}|${suffix}|${flairHtml}|${verifiedBadge}|${supporterBadge}`;
        document.querySelectorAll(`.message[data-pubkey="${safePk}"] .message-author`).forEach(el => {
            // Update only the author-clickable inner span to preserve bubble-time and click handler
            const clickable = el.querySelector('.author-clickable');
            if (clickable) {
                if (clickable.dataset.authorSig === authorSig) return;
                clickable.dataset.authorSig = authorSig;
                clickable.innerHTML = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy"><span class="nym-bracket">&lt;</span>${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${supporterBadge}`;
            } else {
                // Fallback: full rewrite with author-clickable wrapper for older messages missing it
                const bubbleTime = el.querySelector('.bubble-time');
                const bubbleHtml = bubbleTime ? bubbleTime.outerHTML : '';
                el.innerHTML = `${bubbleHtml}<span class="author-clickable"><img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy"><span class="nym-bracket">&lt;</span>${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${supporterBadge}</span><span class="nym-bracket">&gt;</span>`;
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
                        const displayAuthor = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy"><span class="nym-bracket">&lt;</span>${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${flairHtml}`;
                        this.showContextMenu(e, displayAuthor, pubkey, rawContent, msgId, false, isPM ? msgId : null);
                        return false;
                    });
                }
            }
        });

        // Update PM header title if currently viewing this user's PM
        if (this.inPMMode && this.currentPM === pubkey) {
            const pmAvatarSrc = this.getAvatarUrl(pubkey);
            const flairHtml = this.getFlairForUser(pubkey);
            const friendBadge = this.getFriendBadgeHtml(pubkey);
            const verifiedBadge = this.isVerifiedDeveloper(pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
                : this.isVerifiedBot(pubkey)
                    ? `<span class="verified-badge" title="${this.verifiedBot.title}">✓</span>`
                    : '';
            const pmHeaderSig = `${safePk}|${clean}|${suffix}|${flairHtml}|${verifiedBadge}|${friendBadge}`;
            const channelEl = document.getElementById('currentChannel');
            if (channelEl && channelEl.dataset.pmHeaderSig !== pmHeaderSig) {
                const displayNym = `<span class="pm-name-text">${this.escapeHtml(clean)}</span><span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${friendBadge}`;
                const pmHeaderHtml = `<span class="pm-header-row">${this._pmHeaderAvatarHtml(pubkey, pmAvatarSrc, safePk)}${displayNym}</span>`;
                channelEl.innerHTML = pmHeaderHtml;
                channelEl.dataset.pmHeaderSig = pmHeaderSig;
            }
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
            if (this.closedPMs.has(pubkey)) {
                this.closedPMs.delete(pubkey);
                if (this.closedPMTimes) this.closedPMTimes.delete(pubkey);
                try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
                try { localStorage.setItem('nym_closed_pm_times', JSON.stringify(Object.fromEntries(this.closedPMTimes || new Map()))); } catch { }
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
                : this.isVerifiedBot(pubkey)
                    ? `<span class="verified-badge" title="${this.verifiedBot.title}">✓</span>`
                    : '';

            // Get user's shop items for flair
            const userShopItems = this.getUserShopItems(pubkey);
            const flairHtml = this.getFlairForUser(pubkey);
            const friendBadge = this.getFriendBadgeHtml(pubkey);

            // Clean the base nym of any HTML for display
            const cleanBaseNym = this.parseNymFromDisplay(baseNym);

            const pmAvatarSrc = this.getAvatarUrl(pubkey);
            const safePk = this._safePubkey(pubkey);
            item.innerHTML = `
<img src="${this.escapeHtml(pmAvatarSrc)}" class="avatar-pm" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy">
<span class="pm-name">${this.escapeHtml(cleanBaseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml} ${verifiedBadge}${friendBadge}</span>
<div class="channel-badges">
<span class="unread-badge nm-hidden">0</span>
</div>
`;
            item.dataset.action = 'openPMItem';
            item.dataset.nym = cleanBaseNym;

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

            // Proactively request their profile. Unknown/nym contacts get
            // an immediate fetch; known contacts go through the throttled
            // refresh so we still pick up nickname/avatar updates without
            // hammering relays on every PM message.
            if (!this.users.has(pubkey) || /^nym$/i.test(cleanBaseNym)) {
                this.requestUserProfile(pubkey);
            } else if (typeof this.refreshUserProfileThrottled === 'function') {
                this.refreshUserProfileThrottled(pubkey);
            }

            // The critical subscription includes a kind 0 filter scoped to
            // PM contacts so nickname/avatar updates push in real-time. A
            // new contact needs the subscription rebuilt so the relay starts
            // forwarding their kind 0 events. Debounce against burst churn
            // (e.g. hydration adding many PMs in quick succession).
            if (typeof this._scheduleCriticalResubscribe === 'function') {
                this._scheduleCriticalResubscribe();
            }
        } else {
            // PM already exists — sync the displayed nym from the users map
            // in case the profile was updated after the entry was created.
            const cached = this.pmConversations.get(pubkey);
            if (cached && cached.nym !== baseNym) {
                this.updatePMNicknameFromProfile(pubkey, baseNym);
            }
            // Also poll for a fresh kind 0 since there is no ongoing
            // subscription for contact profile updates.
            if (typeof this.refreshUserProfileThrottled === 'function') {
                this.refreshUserProfileThrottled(pubkey);
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

    async deletePM(pubkey) {
        if (!(await window.showAppConfirm('Delete this PM conversation?', { danger: true, okLabel: 'Delete' }))) return;
        this.pmConversations.delete(pubkey);

        const conversationKey = this.getPMConversationKey(pubkey);
        this.pmMessages.delete(conversationKey);
        if (typeof this._cacheDelete === 'function') this._cacheDelete('pms', conversationKey);
        if (this.channelLastRead) {
            this.channelLastRead.set(conversationKey, Math.floor(Date.now() / 1000));
        }
        if (this.unreadCounts) this.unreadCounts.delete(conversationKey);
        if (typeof this._persistUnreadCounts === 'function') this._persistUnreadCounts(true);

        this.closedPMs.add(pubkey);
        if (!this.closedPMTimes) this.closedPMTimes = new Map();
        this.closedPMTimes.set(pubkey, Math.floor(Date.now() / 1000));
        try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
        try { localStorage.setItem('nym_closed_pm_times', JSON.stringify(Object.fromEntries(this.closedPMTimes))); } catch { }
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();

        // Remove from UI
        const item = document.querySelector(`[data-pubkey="${pubkey}"]`);
        if (item) item.remove();

        // If currently viewing this PM, switch to bar
        if (this.inPMMode && this.currentPM === pubkey) {
            this.switchChannel('nymchat', 'nymchat');
        }

        this.displaySystemMessage('PM conversation deleted');
    },

    deletePMDirect(pubkey) {
        this.pmConversations.delete(pubkey);
        const conversationKey = this.getPMConversationKey(pubkey);
        this.pmMessages.delete(conversationKey);
        if (typeof this._cacheDelete === 'function') this._cacheDelete('pms', conversationKey);
        if (this.channelLastRead) {
            this.channelLastRead.set(conversationKey, Math.floor(Date.now() / 1000));
        }
        if (this.unreadCounts) this.unreadCounts.delete(conversationKey);
        if (typeof this._persistUnreadCounts === 'function') this._persistUnreadCounts(true);
        this.closedPMs.add(pubkey);
        if (!this.closedPMTimes) this.closedPMTimes = new Map();
        this.closedPMTimes.set(pubkey, Math.floor(Date.now() / 1000));
        try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
        try { localStorage.setItem('nym_closed_pm_times', JSON.stringify(Object.fromEntries(this.closedPMTimes))); } catch { }
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        const item = document.querySelector(`[data-pubkey="${pubkey}"]`);
        if (item) item.remove();
        if (this.inPMMode && this.currentPM === pubkey) {
            this.switchChannel('nymchat', 'nymchat');
        }
        this.displaySystemMessage('PM conversation deleted');
    },

    openPM(nym, pubkey) {
        this._saveCurrentDraft();
        const prevChannelKey = this.currentGeohash || this.currentChannel;
        if (prevChannelKey && typeof this.closeChannelSubscription === 'function') {
            this.closeChannelSubscription(prevChannelKey);
        }
        this.inPMMode = true;
        this.currentPM = pubkey;
        this.currentGroup = null;
        this.currentChannel = null;
        this.currentGeohash = null;
        this.userScrolledUp = false;
        if (this.pendingEdit) this.cancelEditMessage();

        // Close the mobile sidebar as soon as the switch is committed so the
        // UI feels responsive even while messages load.
        if (window.innerWidth <= 768) {
            this.closeSidebar();
        }

        // Pull a fresh kind 0 so the header/sidebar reflect any profile
        // updates the contact has published since we last fetched.
        if (typeof this.refreshUserProfileThrottled === 'function') {
            this.refreshUserProfileThrottled(pubkey);
        }

        // Track navigation history
        this._pushNavigation({ type: 'pm', nym, pubkey });

        // Re-render typing indicator for the new conversation
        this.renderTypingIndicator();

        // Format the nym with pubkey suffix for display
        const known = this.users.get(pubkey);
        const baseNym = known ? this.parseNymFromDisplay(known.nym) : this.parseNymFromDisplay(nym);
        const suffix = this.getPubkeySuffix(pubkey);
        const pmAvatarSrc = this.getAvatarUrl(pubkey);
        const safePk = this._safePubkey(pubkey);
        const flairHtml = this.getFlairForUser(pubkey);
        const friendBadge = this.getFriendBadgeHtml(pubkey);
        const verifiedBadge = this.isVerifiedDeveloper(pubkey)
            ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
            : this.isVerifiedBot(pubkey)
                ? `<span class="verified-badge" title="${this.verifiedBot.title}">✓</span>`
                : '';
        const displayNym = `<span class="pm-name-text">${this.escapeHtml(baseNym)}</span><span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${friendBadge}`;
        const lastSeenHtml = this._pmLastSeenHtml(pubkey);
        const pmHeaderHtml = `<span class="pm-header-row">${this._pmHeaderAvatarHtml(pubkey, pmAvatarSrc, safePk)}${displayNym}</span>${lastSeenHtml}`;

        // Update UI with formatted nym
        const _pmHeaderEl = document.getElementById('currentChannel');
        _pmHeaderEl.innerHTML = pmHeaderHtml;
        _pmHeaderEl.dataset.pmHeaderSig = `${safePk}|${baseNym}|${suffix}|${flairHtml}|${verifiedBadge}|${friendBadge}`;
        delete _pmHeaderEl.dataset.groupHeaderSig;

        // Click the header to open this contact's profile context menu.
        const _pmHeaderRow = _pmHeaderEl.querySelector('.pm-header-row');
        if (_pmHeaderRow) {
            _pmHeaderRow.classList.add('header-clickable');
            _pmHeaderRow.onclick = (e) => this.showContextMenu(e, `${baseNym}#${suffix}`, pubkey, null, null, true);
        }
        const lockSvgPM = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="nm-pms-2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>';
        if (this.isVerifiedBot(pubkey)) {
            document.getElementById('channelMeta').innerHTML =
                `${lockSvgPM}E2E encrypted · <span id="botCreditMeta">checking credits…</span>`;
            this._refreshBotCreditMeta();
        } else {
            document.getElementById('channelMeta').innerHTML = `${lockSvgPM}End-to-end encrypted private message`;
        }

        // Keep the "Last seen …" line ticking while this conversation is open.
        this._ensurePMHeaderTimer();

        // Hide share button in PM mode
        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) {
            shareBtn.style.display = 'none';
        }
        const favBtn = document.getElementById('favoriteChannelBtn');
        if (favBtn) favBtn.style.display = 'none';
        if (typeof this._refreshCallButtons === 'function') this._refreshCallButtons();

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

        // Send READ receipts only for messages we haven't acknowledged
        const pmMsgs = this.pmMessages.get(conversationKey) || [];
        for (const msg of pmMsgs) {
            if (msg.isOwn || msg.readReceiptSent) continue;
            let sent = false;
            if (msg.bitchatMessageId && this.bitchatUsers.has(msg.pubkey)) {
                this.sendBitchatReceipt(msg.bitchatMessageId, 0x02, msg.pubkey);
                sent = true;
            }
            if (msg.nymMessageId && this.nymUsers.has(msg.pubkey)) {
                this.sendNymReceipt(msg.nymMessageId, 'read', msg.pubkey);
                sent = true;
            }
            if (sent) msg.readReceiptSent = true;
        }
        this.recordOwnActivity();

        // Restore any unsent input previously typed for this conversation
        this._restoreDraftForContext();

        this.hideAutocomplete();
        this.hideChannelAutocomplete();
        this.hideEmojiAutocomplete();
        this._focusMessageInput();
    },

    loadPMMessages(conversationKey, skipBotWelcome = false) {
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

        // Try to restore from DOM cache (compare against filtered set so the
        // cached fragment and the current visible set stay aligned)
        const filteredMessages = this.getFilteredPMMessages(conversationKey);
        const cached = this.channelDOMCache.get(conversationKey);

        if (cached && this._tryRestoreCachedDOM(container, cached, conversationKey, filteredMessages, true)) {
            return;
        }

        // Cache miss or stale - render fresh
        this.channelDOMCache.delete(conversationKey);

        if (filteredMessages.length === 0) {
            container.innerHTML = '';
            this.displaySystemMessage('Start of private message');
            if (this.isVerifiedBot(this.currentPM)) {
                if (!skipBotWelcome) {
                    this._displayBotWelcomeMessage();
                }
                this._checkBotCredits(false);
            }
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

        // Extract base nym if it has a suffix
        const baseNym = this.stripPubkeySuffix(nym);

        if (this.closedPMs.has(pubkey)) {
            this.closedPMs.delete(pubkey);
            if (this.closedPMTimes) this.closedPMTimes.delete(pubkey);
            try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
            try { localStorage.setItem('nym_closed_pm_times', JSON.stringify(Object.fromEntries(this.closedPMTimes || new Map()))); } catch { }
            this._debouncedNostrSettingsSave();
        }

        // Add to PM conversations if not exists
        this.addPMConversation(baseNym, pubkey);
        // Open the PM
        this.openPM(baseNym, pubkey);

        // Proactively fetch kind 0 profile to update nickname/avatar
        const known = this.users.get(pubkey);
        if (!known || /^nym$/i.test(this.parseNymFromDisplay(known.nym))) {
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
            const nymMessageId = this._generateSharedEventId();

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
                    const nymWrapped = await this.nip59WrapEventAsync(rumor, this.privkey, recipientPubkey, expirationTs);
                    this.sendDMToRelays(['EVENT', nymWrapped]);
                    this._recordGiftWrapId(nymMessageId, nymWrapped.id);
                }

                if (recipientPubkey !== this.pubkey) {
                    const selfWrapped = await this.nip59WrapEventAsync(rumor, this.privkey, this.pubkey, expirationTs);
                    this.sendDMToRelays(['EVENT', selfWrapped]);
                    this._recordGiftWrapId(nymMessageId, selfWrapped.id);
                }
            } else if (this._canSendGiftWraps()) {
                // Extension or NIP-46 remote signer path: seal via signer, wrap locally.
                const NT = window.NostrTools;
                const _useExt = !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent);
                const enc44 = (peer, text) => _useExt ? window.nostr.nip44.encrypt(peer, text) : _nip46Encrypt(peer, text);
                const signEvt = (u) => _useExt ? window.nostr.signEvent(u) : _nip46SignEvent(u);

                const sealContent = await enc44(recipientPubkey, JSON.stringify(rumor));
                const sealUnsigned = { kind: 13, content: sealContent, created_at: this.randomNow(), tags: [] };
                const seal = await signEvt(sealUnsigned);
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
                        const selfSealContent = await enc44(this.pubkey, JSON.stringify(rumor));
                        const selfSealUnsigned = { kind: 13, content: selfSealContent, created_at: this.randomNow(), tags: [] };
                        const selfSeal = await signEvt(selfSealUnsigned);
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
        this._addMembersGroupId = null;
        this._newGroupAvatar = null;
        this._newGroupBanner = null;
        document.getElementById('pmRecipientChips').innerHTML = '';
        document.getElementById('pmRecipientInput').value = '';
        document.getElementById('pmSuggestions').style.display = 'none';
        document.getElementById('pmGroupNameInput').value = '';
        document.getElementById('newGroupDescInput').value = '';
        if (typeof updateFieldCharCount === 'function') {
            updateFieldCharCount(document.getElementById('pmGroupNameInput'));
            updateFieldCharCount(document.getElementById('newGroupDescInput'));
        }
        const allowInvitesEl = document.getElementById('newGroupAllowInvites');
        if (allowInvitesEl) allowInvitesEl.checked = true;
        document.getElementById('pmInitialMessage').value = '';
        document.getElementById('pmInitialMessage').closest('.form-group').style.display = '';
        document.getElementById('pmStartBtn').disabled = true;
        document.getElementById('pmStartBtn').textContent = 'Start';
        this._resetNewGroupMediaPreview();
        this._toggleNewGroupFields();
        this._updateNewPMModalTitle();
        document.getElementById('newPMModal').classList.add('active');
        setTimeout(() => {
            document.getElementById('pmRecipientInput').focus();
            this._showRecentlySeenSuggestions('');
        }, 80);
        if (window.innerWidth <= 768) this.closeSidebar();
    },

    // Open the recipient picker in "add members to an existing group" mode.
    openAddMembersModal(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        this.openNewPMModal();
        this._addMembersGroupId = groupId;
        document.getElementById('pmInitialMessage').closest('.form-group').style.display = 'none';
        document.getElementById('pmStartBtn').textContent = 'Add';
        this._toggleNewGroupFields();
        this._updateNewPMModalTitle();
    },

    // Group name + avatar/banner controls show only when composing a group
    // (2+ recipients) and not when adding members to an existing group.
    _toggleNewGroupFields() {
        const groupMode = !this._addMembersGroupId && this._newPMRecipients.length >= 2;
        document.getElementById('pmGroupNameGroup').style.display = groupMode ? 'block' : 'none';
        document.getElementById('newGroupMediaGroup').style.display = groupMode ? 'block' : 'none';
        document.getElementById('newGroupDescGroup').style.display = groupMode ? 'block' : 'none';
        document.getElementById('newGroupAllowInvitesGroup').style.display = groupMode ? 'block' : 'none';
    },

    // Title reflects the current mode: add-members, group (2+), or 1:1.
    _updateNewPMModalTitle() {
        const el = document.getElementById('newPMModalTitle');
        if (!el) return;
        if (this._addMembersGroupId) el.textContent = 'Add Members';
        else el.textContent = this._newPMRecipients.length >= 2 ? 'New Group' : 'New Message';
    },

    _resetNewGroupMediaPreview() {
        const banner = document.getElementById('newGroupBannerPreview');
        const avatar = document.getElementById('newGroupAvatarPreview');
        if (banner) {
            banner.style.backgroundImage = '';
            banner.classList.remove('has-image');
        }
        if (avatar) {
            avatar.style.backgroundImage = '';
            avatar.classList.remove('has-image');
        }
    },

    // Pick + upload a group avatar/banner from the New Group modal, showing the
    // modal-local progress bar. The resulting URL is stored until the group is
    // created.
    newGroupPickAvatar() { this._pickNewGroupMedia('avatar'); },
    newGroupPickBanner() { this._pickNewGroupMedia('banner'); },

    _pickNewGroupMedia(kind) {
        const input = document.getElementById(kind === 'avatar' ? 'newGroupAvatarInput' : 'newGroupBannerInput');
        if (!input) return;
        input.onchange = async () => {
            const file = input.files && input.files[0];
            input.value = '';
            if (!file) return;
            try {
                const { url } = await this._uploadFileWithProgress(
                    file,
                    kind === 'avatar' ? 'Uploading group avatar…' : 'Uploading group banner…',
                    {
                        container: document.getElementById('newGroupUploadProgress'),
                        fill: document.getElementById('newGroupProgressFill'),
                        labelEl: document.getElementById('newGroupUploadLabel')
                    }
                );
                const proxied = this.getProxiedMediaUrl(url);
                if (kind === 'avatar') {
                    this._newGroupAvatar = url;
                    const el = document.getElementById('newGroupAvatarPreview');
                    if (el) { el.style.backgroundImage = `url("${proxied}")`; el.classList.add('has-image'); }
                } else {
                    this._newGroupBanner = url;
                    const el = document.getElementById('newGroupBannerPreview');
                    if (el) { el.style.backgroundImage = `url("${proxied}")`; el.classList.add('has-image'); }
                }
            } catch (error) {
                if (!(error && error.name === 'AbortError')) {
                    this.displaySystemMessage('Failed to upload image: ' + (error?.message || error));
                }
            }
        };
        input.click();
    },

    // Show recently seen users in the New Message modal (sorted most-recent first)
    _showRecentlySeenSuggestions(query) {
        const suggestions = document.getElementById('pmSuggestions');
        if (!suggestions) return;

        const matches = [];
        this.users.forEach((user, pubkey) => {
            if (!user || !user.nym) return;
            if (pubkey === this.pubkey) return;
            if (this.isVerifiedBot && this.isVerifiedBot(pubkey)) return;
            if (this.blockedUsers && this.blockedUsers.has(pubkey)) return;
            if (this._newPMRecipients.some(r => r.pubkey === pubkey)) return;
            const name = this.stripPubkeySuffix(user.nym);
            if (query && !name.toLowerCase().includes(query)) return;
            matches.push({ nym: name, pubkey, lastSeen: user.lastSeen || 0 });
        });

        if (matches.length === 0) {
            suggestions.style.display = 'none';
            suggestions.textContent = '';
            return;
        }

        matches.sort((a, b) => b.lastSeen - a.lastSeen);
        const top = matches.slice(0, 10);

        suggestions.textContent = '';
        if (!query) {
            const header = document.createElement('div');
            header.className = 'pm-suggestion-header';
            header.textContent = 'Recently seen users';
            suggestions.appendChild(header);
        }

        for (const m of top) {
            suggestions.appendChild(this._buildPMSuggestionItem(m.pubkey, m.nym));
        }
        suggestions.style.display = 'block';
    },

    // Build a pm-suggestion-item DOM node (no innerHTML).
    _buildPMSuggestionItem(pubkey, nym) {
        const safePk = this._safePubkey(pubkey);
        const item = document.createElement('div');
        item.className = 'pm-suggestion-item';
        item.dataset.pubkey = safePk;
        item.dataset.nym = nym;

        const img = document.createElement('img');
        img.className = 'pm-suggestion-avatar';
        img.dataset.avatarPubkey = safePk;
        img.loading = 'lazy';
        img.alt = '';
        img.src = this.getAvatarUrl(pubkey);

        const nymSpan = document.createElement('span');
        nymSpan.className = 'pm-suggestion-nym';
        nymSpan.textContent = nym;

        const suffixSpan = document.createElement('span');
        suffixSpan.className = 'pm-suggestion-suffix';
        suffixSpan.textContent = '#' + this.getPubkeySuffix(pubkey);

        item.appendChild(img);
        item.appendChild(nymSpan);
        item.appendChild(suffixSpan);

        item.addEventListener('click', () => this.addNewPMRecipient(safePk, nym));
        return item;
    },

    onNewPMRecipientInput(value) {
        const suggestions = document.getElementById('pmSuggestions');
        const query = value.trim().replace(/^@/, '').toLowerCase();
        if (!query) {
            this._showRecentlySeenSuggestions('');
            return;
        }

        // Direct pubkey paste
        if (/^[0-9a-f]{64}$/i.test(query)) {
            const pk = query;
            if (!this._newPMRecipients.some(r => r.pubkey === pk) && pk !== this.pubkey) {
                const renderPubkeySuggestion = () => {
                    const nym = this.stripPubkeySuffix(this.getNymFromPubkey(pk));
                    suggestions.textContent = '';
                    suggestions.appendChild(this._buildPMSuggestionItem(pk, nym));
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

        // Search recently seen / active users by nym substring
        this._showRecentlySeenSuggestions(query);
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
        // Nymbot can be messaged 1:1 but never added to a group chat
        if (this.isVerifiedBot(pubkey) && this._newPMRecipients.length > 0) {
            this.displaySystemMessage("Nymbot can only be messaged 1:1, not added to a group chat.");
            return;
        }
        if (!this.isVerifiedBot(pubkey) && this._newPMRecipients.some(r => this.isVerifiedBot(r.pubkey))) {
            this.displaySystemMessage("Nymbot can only be messaged 1:1, not added to a group chat.");
            return;
        }
        this._newPMRecipients.push({ pubkey, nym });
        this._renderNewPMRecipientChips();
        document.getElementById('pmRecipientInput').value = '';
        document.getElementById('pmSuggestions').style.display = 'none';
        this._toggleNewGroupFields();
        this._updateNewPMModalTitle();
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
        this._toggleNewGroupFields();
        this._updateNewPMModalTitle();
        document.getElementById('pmStartBtn').disabled = this._newPMRecipients.length === 0;
    },

    _renderNewPMRecipientChips() {
        document.getElementById('pmRecipientChips').innerHTML = this._newPMRecipients.map(r => {
            const suffix = this.getPubkeySuffix(r.pubkey);
            const baseNym = this.stripPubkeySuffix(this.parseNymFromDisplay(r.nym));
            return `<span class="pm-recipient-chip">${this.escapeHtml(baseNym)}<span class="pm-chip-suffix">#${suffix}</span><button class="pm-chip-remove" data-action="removeNewPMRecipient" data-pubkey="${r.pubkey}" type="button">×</button></span>`;
        }).join('');
    },

    async startNewPMFromModal() {
        if (this._newPMRecipients.length === 0) return;

        // Add-members mode: append the selected users to the existing group.
        if (this._addMembersGroupId) {
            const groupId = this._addMembersGroupId;
            const recipients = [...this._newPMRecipients];
            this._addMembersGroupId = null;
            closeModal('newPMModal');
            for (const r of recipients) {
                await this.addMemberToGroup(groupId, r.pubkey);
            }
            return;
        }

        const initialMsg = document.getElementById('pmInitialMessage').value.trim();
        closeModal('newPMModal');

        if (this._newPMRecipients.length === 1) {
            const { nym, pubkey } = this._newPMRecipients[0];
            this.openUserPM(nym, pubkey);
            if (initialMsg) {
                setTimeout(() => this.sendPM(initialMsg, pubkey), 400);
            }
        } else {
            const groupName = this.sanitizeGroupName(document.getElementById('pmGroupNameInput').value) ||
                [this.getNymFromPubkey(this.pubkey), ...this._newPMRecipients.slice(0, 2).map(r => r.nym)].join(', ');
            const memberPubkeys = this._newPMRecipients.map(r => r.pubkey);
            const groupDesc = this.sanitizeGroupDescription(document.getElementById('newGroupDescInput').value) || null;
            const allowMemberInvites = document.getElementById('newGroupAllowInvites')?.checked !== false;
            const groupOpts = { avatar: this._newGroupAvatar || null, banner: this._newGroupBanner || null, description: groupDesc, allowMemberInvites };
            this._newGroupAvatar = null;
            this._newGroupBanner = null;
            this.displaySystemMessage(`Creating group "${groupName}"...`);
            const groupId = await this.createGroup(groupName, memberPubkeys, groupOpts);
            if (groupId && initialMsg) {
                this.sendGroupMessage(initialMsg, groupId);
            }
        }
    },

    // Get filtered PM messages for a conversation key
    getFilteredPMMessages(conversationKey) {
        const pmMessages = this.pmMessages.get(conversationKey) || [];

        return pmMessages.filter(msg => {
            if (this.deletedEventIds.has(msg.id)) return false;
            if (msg.nymMessageId && this.deletedEventIds.has(msg.nymMessageId)) return false;
            if (typeof this._consumePendingDeletion === 'function' && this._consumePendingDeletion(msg)) return false;
            const isOwn = msg.pubkey === this.pubkey;
            if (!isOwn && (this.blockedUsers.has(msg.pubkey) || msg.blocked)) return false;
            if (!isOwn && this.hasBlockedKeyword(msg.content, msg.author)) return false;
            if (!isOwn && this.isSpamMessage(msg.content)) return false;
            if (msg.conversationKey !== conversationKey) return false;
            // For 1:1 PMs, restrict to the two participants. Group messages have
            // multiple senders so skip this check for them.
            if (!msg.isGroup && msg.pubkey !== this.pubkey && msg.pubkey !== this.currentPM) return false;
            return true;
        }).sort((a, b) => this._compareMessages(a, b));
    },

    // Load older PM/group messages when user scrolls to top
    loadOlderPMMessages(conversationKey) {
        const container = document.getElementById('messagesContainer');
        const scroller = this._getMessagesScroller();
        if (!container || !scroller) return false;

        const currentStart = this.pmRenderedStart.get(conversationKey);
        if (currentStart === undefined || currentStart <= 0) return false;

        const messages = this.getFilteredPMMessages(conversationKey);
        if (messages.length === 0) return false;

        const newStart = Math.max(0, currentStart - this.pmLoadMoreSize);
        if (newStart === currentStart) return false;

        this.pmRenderedStart.set(conversationKey, newStart);
        this.channelDOMCache.delete(conversationKey);

        const olderMessages = messages.slice(newStart, currentStart);
        const scrollTopBefore = scroller.scrollTop;

        this.virtualScroll.suppressAutoScroll = true;
        this._suppressSound = true;
        this._suppressBubbleRewrap = true;
        const frag = document.createDocumentFragment();
        this._bulkContainer = frag;
        this._bulkAppending = true;

        for (let i = 0; i < olderMessages.length; i++) {
            this.displayMessage(olderMessages[i]);
        }

        this._bulkAppending = false;
        this._bulkContainer = null;
        this._suppressSound = false;
        this._suppressBubbleRewrap = false;
        this.virtualScroll.suppressAutoScroll = false;

        container.insertBefore(frag, container.firstChild);

        if (newStart === 0 && !container.querySelector('.pm-history-start')) {
            const topNotice = document.createElement('div');
            topNotice.className = 'system-message pm-history-start';
            topNotice.textContent = 'You\'ve reached the edge of this conversation\'s history.';
            container.insertBefore(topNotice, container.firstChild);
        }

        this._recomputeAllBubbleGrouping(container);

        scroller.scrollTop = scrollTopBefore;
        requestAnimationFrame(() => { scroller.scrollTop = scrollTopBefore; });

        return true;
    },

    collapsePMToLatest(conversationKey) {
        const container = document.getElementById('messagesContainer');
        if (!container) return false;
        const msgEls = container.querySelectorAll('.message');
        const excess = msgEls.length - this.pmPageSize;
        if (excess <= 0) return false;
        for (let i = 0; i < excess; i++) {
            msgEls[i].remove();
        }

        const messages = this.getFilteredPMMessages(conversationKey);
        const newStart = Math.max(0, messages.length - this.pmPageSize);
        this.pmRenderedStart.set(conversationKey, newStart);
        this.channelDOMCache.delete(conversationKey);

        const existingNotice = container.querySelector('.pm-history-start, .pm-load-older');
        if (newStart === 0) {
            if (!existingNotice) {
                const notice = document.createElement('div');
                notice.className = 'system-message pm-history-start';
                notice.textContent = 'You\'ve reached the edge of this conversation\'s history.';
                container.insertBefore(notice, container.firstChild);
            }
        } else if (existingNotice) {
            existingNotice.remove();
        }
        this._recomputeAllBubbleGrouping(container);
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
            const pinned = this.pinnedLandingChannel || { type: 'geohash', geohash: 'nymchat' };
            if (pinned.type === 'geohash' && pinned.geohash) {
                this.switchChannel(pinned.geohash, pinned.geohash);
            } else {
                this.switchChannel('nymchat', 'nymchat');
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
        const prevChannelKey = this.currentGeohash || this.currentChannel;
        if (prevChannelKey && typeof this.closeChannelSubscription === 'function') {
            this.closeChannelSubscription(prevChannelKey);
        }
        this.inPMMode = true;
        this.currentPM = null;
        this.currentGroup = null;
        this.currentChannel = null;
        this.currentGeohash = null;

        document.getElementById('currentChannel').innerHTML = '<span class="nm-dim">No conversation selected</span>';
        document.getElementById('channelMeta').textContent = '';

        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) shareBtn.style.display = 'none';
        const favBtn = document.getElementById('favoriteChannelBtn');
        if (favBtn) favBtn.style.display = 'none';

        document.querySelectorAll('.channel-item').forEach(i => i.classList.remove('active'));
        document.querySelectorAll('.pm-item').forEach(i => i.classList.remove('active'));

        const container = document.getElementById('messagesContainer');
        if (container) {
            container.innerHTML = `
                <div class="nm-pms-3">
                    <div class="nm-pms-4">+</div>
                    <div class="nm-pms-5">No conversations yet</div>
                    <div class="nm-pms-6">Click the <strong>+</strong> button in the Private Messages section to start a new group chat or private message.</div>
                </div>`;
        }
    },

});
