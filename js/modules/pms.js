// pms.js - Private messages: send, open, conversation list, gift wrap DMs, new-PM modal, retry queue

const NYMBOT_TURN_IN = 3000;
const NYMBOT_TURN_OUT = 700;

Object.assign(NYM.prototype, {

    _pmHeaderAvatarHtml(pubkey, avatarSrc, safePk) {
        const status = (typeof this.getEffectiveUserStatus === 'function')
            ? this.getEffectiveUserStatus(pubkey) : 'offline';
        const isHidden = status === 'hidden';
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
            const isHidden = status === 'hidden';
            const dotStatus = isHidden ? 'offline' : status;
            const wrap = dot.parentElement;
            if (wrap) wrap.classList.toggle('no-status', isHidden);
            dot.className = `user-status-dot status-${dotStatus}`;
        }
        const seenEl = channelEl.querySelector('.pm-last-seen .loc-country');
        if (seenEl) {
            seenEl.textContent = this._pmLastSeenText(this.currentPM);
        }
    },

    // Live status when active/away, otherwise the relative time we last saw them.
    _pmLastSeenText(pubkey) {
        if (this.isVerifiedBot(pubkey)) return 'Always at your service';
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

    // Keyed by uppercased nym/bitchat message id, keeping the highest status per id.
    _bufferEarlyReceipt(receiptId, receiptType, senderPubkey) {
        if (!this._earlyReceipts) this._earlyReceipts = new Map();
        const order = { sent: 0, delivered: 1, read: 2 };
        const cur = this._earlyReceipts.get(receiptId);
        if (!cur || (order[receiptType] || 0) > (order[cur.receiptType] || 0)) {
            this._earlyReceipts.set(receiptId, { receiptType, senderPubkey, at: Date.now() });
        }
        if (this._earlyReceipts.size > 1000) {
            const keys = [...this._earlyReceipts.keys()].slice(0, 500);
            for (const k of keys) this._earlyReceipts.delete(k);
        }
    },

    _applyEarlyReceipt(msg, convKey) {
        if (!this._earlyReceipts || !this._earlyReceipts.size || !msg || !msg.isOwn) return;
        const order = { sent: 0, delivered: 1, read: 2 };
        for (const rawId of [msg.nymMessageId, msg.bitchatMessageId]) {
            if (!rawId) continue;
            const id = rawId.toUpperCase();
            const entry = this._earlyReceipts.get(id);
            if (!entry) continue;
            this._earlyReceipts.delete(id);
            if ((order[entry.receiptType] || 0) < (order[msg.deliveryStatus] || 0)) continue;
            msg.deliveryStatus = entry.receiptType;
            this.pendingDMs.delete(msg.id);
            if (msg.isGroup && msg.nymMessageId && entry.receiptType === 'read') {
                if (!this.groupMessageReaders.has(msg.nymMessageId)) {
                    this.groupMessageReaders.set(msg.nymMessageId, new Map());
                }
                this.groupMessageReaders.get(msg.nymMessageId).set(entry.senderPubkey, this.resolveDisplayNym(entry.senderPubkey, ''));
            } else {
                this._updateDeliveryStatusEl(msg.nymMessageId || msg.id, entry.receiptType);
            }
            this.persistPMMessages(convKey);
        }
    },

    trackPendingDM(eventId, wrappedEvents, recipientPubkey, conversationKey) {
        this.pendingDMs.set(eventId, {
            wrappedEvents, // Array of ['EVENT', wrapped] messages to re-send
            recipientPubkey,
            conversationKey,
            attempts: 0,
            lastAttempt: Date.now(),
            maxAttempts: this.dmRetryMaxAttempts
        });

        if (!this.dmRetryInterval) {
            this.dmRetryInterval = setInterval(() => this.retryPendingDMs(), this.dmRetryCheckMs);
        }
    },

    retryPendingDMs() {
        if (this.pendingDMs.size === 0) {
            if (this.dmRetryInterval) {
                clearInterval(this.dmRetryInterval);
                this.dmRetryInterval = null;
            }
            return;
        }

        const now = Date.now();

        for (const [eventId, pending] of this.pendingDMs) {
            const msgs = this.pmMessages.get(pending.conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.id === eventId);
                if (msg && msg.deliveryStatus !== 'sent') {
                    this.pendingDMs.delete(eventId);
                    continue;
                }
            }

            if (now - pending.lastAttempt < this.dmRetryCheckMs) continue;

            // Stay 'sent' after max re-sends: a missing receipt means the recipient is offline, not a failure.
            if (pending.attempts >= pending.maxAttempts) {
                this.pendingDMs.delete(eventId);
                continue;
            }

            pending.attempts++;
            pending.lastAttempt = now;

            for (const wrappedMsg of pending.wrappedEvents) {
                this.sendDMToRelays(wrappedMsg);
            }
        }
    },

    manualRetryDM(eventId) {
        if (!this.currentPM) return;
        const conversationKey = this.getPMConversationKey(this.currentPM);
        const msgs = this.pmMessages.get(conversationKey);
        if (!msgs) return;
        const idx = msgs.findIndex(m => m.id === eventId);
        if (idx === -1) return;
        const msg = msgs[idx];
        const recipient = msg.conversationPubkey || this.currentPM;

        msgs.splice(idx, 1);
        this.channelDOMCache.delete(conversationKey);
        this.persistPMMessages(conversationKey);
        const msgEl = this.findMessageElementAnywhere(msg.nymMessageId || msg.id);
        if (msgEl) msgEl.remove();

        this.sendPM(msg.content, recipient);
    },

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

    retryPendingDMsOnReconnect() {
        let resolveCatchup;
        this._dmCatchupReady = new Promise(r => { resolveCatchup = r; });

        const d1Available = !!(this._getApiHost && this._getApiHost());
        if (this.pubkey && this.lastPMSyncTime && !d1Available) {
            const since = Math.max(
                this.lastPMSyncTime - 300,
                Math.floor(Date.now() / 1000) - 604800
            );
            const mkSubId = () => Math.random().toString(36).substring(2);

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

        // Give relays 3s to deliver missed gift wraps (and ephemeral keys) before outbound group sends.
        setTimeout(() => resolveCatchup(), 3000);

        // Re-exchange group ephemeral keys in case missed rotations expired off relays while offline.
        this._dmCatchupReady.then(() => {
            try { this._maybeSendGroupKeyResyncs(); } catch (_) { }
            // This only runs on re-connect; connectToRelays announces on the first connect.
            try { this.schedulePqAnnouncement(); } catch (_) { }
        });

        if (this.pendingDMs.size === 0) return;

        for (const [eventId, pending] of this.pendingDMs) {
            const msgs = this.pmMessages.get(pending.conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.id === eventId);
                if (msg && msg.deliveryStatus !== 'sent') {
                    this.pendingDMs.delete(eventId);
                    continue;
                }
            }

            for (const wrappedMsg of pending.wrappedEvents) {
                this.sendDMToRelays(wrappedMsg);
            }
            pending.lastAttempt = Date.now();
        }
    },

    async sendNIP17PM(content, recipientPubkey, options = {}) {
        const nowMs = Date.now();
        const now = Math.floor(nowMs / 1000);

        const nymMessageId = this._generateSharedEventId();

        const fileOffer = options.fileOffer || null;
        // Rides inside the rumor and references the root's shared nymMessageId, since wrap ids differ per recipient.
        const threadRoot = options.threadRoot || null;

        const rumor = {
            kind: 14,
            created_at: now,
            tags: [
                ['p', recipientPubkey],
                ['x', nymMessageId],  // Nymchat message ID for delivery receipts
                ['ms', String(nowMs)],  // Millisecond send time for sub-second ordering
                ...(threadRoot ? [['nymthread', threadRoot]] : []),
                ...(fileOffer ? [['offer', JSON.stringify(fileOffer)]] : []),
                ...this.customEmojiTagsForContent(content),
                ...(typeof this.imetaTagsForContent === 'function' ? this.imetaTagsForContent(content) : [])
            ],
            content,
            pubkey: this.pubkey
        };

        const supportToken = this.pmSupportTokenFor(recipientPubkey);
        if (supportToken) rumor.tags.push(['nymbot-support', supportToken]);
        const supportWrapTags = supportToken ? [['t', supportToken]] : null;

        // Optional NIP-40 expiration on the gift wrap.
        const expirationTs = (this.settings?.dmForwardSecrecyEnabled && this.settings?.dmTTLSeconds > 0)
            ? Math.floor(Date.now() / 1000) + this.settings.dmTTLSeconds
            : null;

        if (typeof this.botAnonEnabled === 'function' && this.botAnonEnabled() &&
            this._botAnonSenderFor(recipientPubkey)) {
            return await this._sendAnonBotPM(content, recipientPubkey, options);
        }

        if (this.privkey) {
            const NT = window.NostrTools;
            // Ensure at least one announcement lookup, for sends that skip opening the conversation.
            if (typeof this.ensurePqAnnouncement === 'function') {
                try { await this.ensurePqAnnouncement(recipientPubkey); } catch (_) { }
            }
            // See pqPmPlan (pq.js) for why post-quantum replaces rather than accompanies the others.
            const plan = this.pqPmPlan(recipientPubkey);
            const recipientKemPk = plan.kemPk;
            let wrapped;
            let bitchatMessageId = null;
            let pqEncrypted = false;
            let pqRoot = false;
            const sentWrappedEvents = [];

            // Known bitchat users and unknown peers get a bitchat-format wrap so bitchat apps can decrypt.
            if (plan.bitchat) {
                // Bitchat caps a TLV value at 255 bytes, so send one wrap per chunk.
                const chunks = this.chunkBitchatContent(content);
                for (const chunk of chunks) {
                    const encoded = this.encodeBitchatMessage(chunk, recipientPubkey);
                    // The first chunk's id is what a bitchat receipt refers to, matching the mesh path.
                    if (bitchatMessageId === null) bitchatMessageId = encoded.messageId;

                    const bitchatRumor = {
                        kind: 14,
                        created_at: now,
                        tags: [],
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
            }

            if (plan.nym) {
                const nymWrapped = recipientKemPk
                    ? await this.pqWrapForPeerAsync(plan.pq2, rumor, this.privkey, recipientPubkey, recipientKemPk, expirationTs, supportWrapTags)
                    : await this.nip59WrapEventAsync(rumor, this.privkey, recipientPubkey, expirationTs, supportWrapTags);
                this.sendDMToRelays(['EVENT', nymWrapped]);
                sentWrappedEvents.push(['EVENT', nymWrapped]);
                wrapped = nymWrapped;
                pqEncrypted = !!recipientKemPk;
                pqRoot = pqEncrypted && plan.rootSeeded && this.pqHasRoot();
                this._recordGiftWrapId(nymMessageId, nymWrapped.id);
                this._depositPMEvent(nymWrapped);

                if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(nymWrapped.id, 1059); }, 600000);
                }
            }

            if (recipientPubkey !== this.pubkey) {
                // Post-quantum when possible so the archive isn't the weakest link.
                const selfKemPk = this.pqSelfKeyFor();
                const selfWrapped = selfKemPk
                    ? await this.pqWrapForPeerAsync(this.pqSelfUsesPq2(), rumor, this.privkey, this.pubkey, selfKemPk, expirationTs, supportWrapTags)
                    : await this.nip59WrapEventAsync(rumor, this.privkey, this.pubkey, expirationTs, supportWrapTags);
                this.sendDMToRelays(['EVENT', selfWrapped]);
                this._recordGiftWrapId(nymMessageId, selfWrapped.id);
                // Archive our self-addressed copy so sent messages restore across devices without the relay echo.
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
                threadRoot: threadRoot || undefined,
                senderVerified: true,
                pqEncrypted,
                pqRoot,
                isFileOffer: !!fileOffer,
                fileOffer,
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });
            pmList.sort((a, b) => {
                return this._compareMessages(a, b);
            });
            if (pmList.length > this.pmStorageLimit) {
                this.pmMessages.set(conversationKey, pmList.slice(-this.pmStorageLimit));
            }
            this.persistPMMessages(conversationKey);

            this.trackPendingDM(wrapped.id, sentWrappedEvents, recipientPubkey, conversationKey);

            this.addPMConversation(this.getNymFromPubkey(recipientPubkey), recipientPubkey, Date.now());
            this.movePMToTop(recipientPubkey);

            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(this.pmMessages.get(conversationKey).slice(-1)[0]);
                this._scheduleScrollToBottom();
            }
            return wrapped.id;
        }

        // Extension or NIP-46 remote signer path (seal via signer, wrap locally)
        const _useExt = !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent);
        const _useN46 = this.nostrLoginMethod === 'nip46' && _nip46State && _nip46State.connected;
        if (_useExt || _useN46) {
            const NT = window.NostrTools;
            // The signer seals, but the wrap is ours and can be hybridized; see pqSendCapable (pq.js).
            const plan = this.pqPmPlan(recipientPubkey);
            const recipientKemPk = plan.kemPk;

            rumor.id = NT.getEventHash(rumor);

            // Seal (kind 13) signed by identity via extension or remote signer.
            const sealContent = _useExt
                ? await window.nostr.nip44.encrypt(recipientPubkey, JSON.stringify(rumor))
                : await _nip46Encrypt(recipientPubkey, JSON.stringify(rumor));
            const sealUnsigned = {
                kind: 13, content: sealContent, created_at: this.randomNow(), tags: []
            };
            const seal = _useExt
                ? await window.nostr.signEvent(sealUnsigned)
                : await _nip46SignEvent(sealUnsigned);

            // GiftWrap (kind 1059) with local ephemeral key.
            const ephSk = NT.generateSecretKey();
            // Use the format the recipient announced; a `pk2`-only peer can't open a combined wrap.
            const wrapContent = recipientKemPk
                ? (plan.pq2
                    ? window.NymCrypto.pq2Encrypt(JSON.stringify(seal), ephSk, recipientPubkey, recipientKemPk)
                    : window.NymCrypto.pqEncrypt(JSON.stringify(seal), ephSk, recipientPubkey, recipientKemPk))
                : NT.nip44.encrypt(JSON.stringify(seal), NT.nip44.getConversationKey(ephSk, recipientPubkey));
            const wrapUnsigned = {
                kind: 1059,
                content: wrapContent,
                created_at: this.randomNow(),
                tags: [['p', recipientPubkey], ...(supportWrapTags || [])]
            };

            if (expirationTs) {
                wrapUnsigned.tags.push(['expiration', String(expirationTs)]);
            }

            const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);

            const sentWrappedEvents = [['EVENT', wrapped]];
            this.sendDMToRelays(['EVENT', wrapped]);
            this._depositPMEvent(wrapped);

            if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                const eventIdToDelete = wrapped.id;
                setTimeout(() => {
                    this.publishDeletionEvent(eventIdToDelete, 1059);
                }, 600000); // 10 minutes
            }

            // Self-wrap so our own message is retrievable from relays after reload.
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
                    const selfKemPk = (typeof this.pqSelfKeyFor === 'function' && this.pqSelfUsesPq2())
                        ? this.pqSelfKeyFor() : null;
                    const selfWrapContent = selfKemPk
                        ? window.NymCrypto.pq2Encrypt(JSON.stringify(selfSeal), selfEphSk, this.pubkey, selfKemPk)
                        : NT.nip44.encrypt(JSON.stringify(selfSeal), NT.nip44.getConversationKey(selfEphSk, this.pubkey));
                    const selfWrapUnsigned = {
                        kind: 1059,
                        content: selfWrapContent,
                        created_at: this.randomNow(),
                        tags: [['p', this.pubkey], ...(supportWrapTags || [])]
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
                threadRoot: threadRoot || undefined,
                senderVerified: true,
                pqEncrypted: !!recipientKemPk,
                pqRoot: !!recipientKemPk && plan.rootSeeded && this.pqHasRoot(),
                isFileOffer: !!fileOffer,
                fileOffer,
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });
            extPmList.sort((a, b) => {
                return this._compareMessages(a, b);
            });
            if (extPmList.length > this.pmStorageLimit) {
                this.pmMessages.set(conversationKey, extPmList.slice(-this.pmStorageLimit));
            }
            this.persistPMMessages(conversationKey);

            this.trackPendingDM(wrapped.id, sentWrappedEvents, recipientPubkey, conversationKey);

            this.addPMConversation(this.getNymFromPubkey(recipientPubkey), recipientPubkey, Date.now());
            this.movePMToTop(recipientPubkey);

            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(this.pmMessages.get(conversationKey).slice(-1)[0]);
                this._scheduleScrollToBottom();
            }
            return wrapped.id;
        }

        throw new Error('No signing/encryption available for NIP-17 (need local privkey, extension, or remote signer)');
    },

    // Receive NIP-17 (GiftWrap 1059): unwrap, verify, store.
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

    // Whether a wrap's payload is post-quantum, in either framing.
    _isPqPayload(content) {
        const NC = window.NymCrypto;
        if (!NC || typeof content !== 'string') return false;
        return !!((NC.isPq2Payload && NC.isPq2Payload(content))
            || (NC.isPqPayload && NC.isPqPayload(content)));
    },

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

    // Only set after a successful decrypt, so a wrap that failed (e.g. signer not ready) stays retryable.
    _noteWrapDecrypted(id) {
        if (!id) return;
        if (!this._decryptedWrapIds) this._decryptedWrapIds = new Set();
        this._decryptedWrapIds.add(id);
        // Only reached after an unwrap returned, so a wrap we could not open stays retryable.
        if (this.processedPMEventIds) {
            this.processedPMEventIds.add(id);
            if (this.processedPMEventIds.size > 5000) {
                this.processedPMEventIds = new Set(
                    Array.from(this.processedPMEventIds).slice(-2500));
            }
            if (typeof this.persistDedupSets === 'function') this.persistDedupSets();
        }
        // Bounded well above 5000 because boot seeds the whole cached PM history; eviction only costs a decrypt.
        if (this._decryptedWrapIds.size > 50000) {
            this._decryptedWrapIds = new Set(Array.from(this._decryptedWrapIds).slice(-25000));
        }
    },

    _unverifiedWrapAllowed(rumor, parseBitchat) {
        if (!rumor || rumor.kind !== 14 || typeof rumor.content !== 'string') return false;
        if (!rumor.pubkey || rumor.pubkey === this.pubkey) return false;
        if (typeof this.isBotAnonPubkey === 'function' && this.isBotAnonPubkey(rumor.pubkey)) return false;
        const blocked = new Set(['g', 'edit', 'typing', 'receipt', 'offer']);
        if ((rumor.tags || []).some(t => Array.isArray(t) && blocked.has(t[0]))) return false;
        if (rumor.content.startsWith('bitchat1:') && typeof parseBitchat === 'function') {
            const parsed = parseBitchat(rumor.content);
            if (!parsed || parsed.type !== 0x01) return false;
        }
        return true;
    },

    async handleGiftWrapDM(event, opts) {
        try {
            const NT = window.NostrTools;

            if (!this._giftWrapIsForMe(event)) return;

            const fromD1 = !!(opts && opts.fromD1);

            // Already decrypted this run; skip the redundant ML-KEM + NIP-44 work.
            if (!this._decryptedWrapIds) this._decryptedWrapIds = new Set();
            if (this._decryptedWrapIds.has(event.id)) return;

            if (!fromD1 && this.processedPMEventIds.has(event.id)) {
                return;
            }
            // In-flight guard only; the persisted mark waits for success, and D1 replays (the retry) skip it.
            if (!this._pmWrapAttempted) this._pmWrapAttempted = new Set();
            if (!fromD1 && this._pmWrapAttempted.has(event.id)) return;
            this._pmWrapAttempted.add(event.id);
            if (this._pmWrapAttempted.size > 50000) {
                this._pmWrapAttempted = new Set(Array.from(this._pmWrapAttempted).slice(-25000));
            }

            if (event.created_at && event.created_at > this.lastPMSyncTime) {
                this.lastPMSyncTime = event.created_at;
                this._persistLastPMSyncTime();
            }

            // bitchat1:<base64url>; returns { type, content } with NoisePayloadType 0x01=MSG, 0x02=READ, 0x03=DELIVERED.
            const parseBitchatMessage = (content) => {
                if (!content.startsWith('bitchat1:')) {
                    return { type: 0x01, content };
                }

                try {
                    let b64 = content.slice(9); // Remove 'bitchat1:'
                    b64 = b64.replace(/-/g, '+').replace(/_/g, '/');
                    while (b64.length % 4) b64 += '=';

                    const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));

                    // Header: version, type, TTL, timestamp(8), flags, payloadLen(2) = 14 bytes; then senderID(8), recipientID?(8).
                    const flags = bytes[11];
                    const hasRecipient = (flags & 0x01) !== 0;
                    const payloadStart = 14 + 8 + (hasRecipient ? 8 : 0); // header + senderID + recipientID?

                    const noisePayloadType = bytes[payloadStart];

                    // Bitchat sends receipts as [NoisePayloadType][raw messageId string] (no TLV).
                    if (noisePayloadType !== 0x01) {
                        let pos = payloadStart + 1;
                        let end = bytes.length;
                        while (end > 0 && bytes[end - 1] === 0xBE) end--;

                        let messageId = null;
                        if (pos < end && bytes[pos] === 0x00 && pos + 2 < end) {
                            // TLV format: [0x00][len][messageID].
                            const idLen = bytes[pos + 1];
                            if (pos + 2 + idLen <= end) {
                                try {
                                    messageId = new TextDecoder().decode(bytes.subarray(pos + 2, pos + 2 + idLen));
                                } catch (e) { }
                            }
                        } else {
                            // Raw UUID string (8-4-4-4-12, 36 chars), as Bitchat sends it.
                            try {
                                const rawBytes = bytes.subarray(pos, Math.min(pos + 36, end));
                                messageId = new TextDecoder().decode(rawBytes);
                                if (!/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i.test(messageId)) {
                                    messageId = null;
                                }
                            } catch (e) { }
                        }
                        return { type: noisePayloadType, content: null, messageId };
                    }

                    // TLV [type][len][value]; a high-bit type (0x80) marks a 2-byte big-endian length.
                    let pos = payloadStart + 1; // Skip NoisePayloadType byte
                    let messageContent = null;
                    let messageId = null;

                    // Strip trailing 0xBE padding for bounds checking.
                    let end = bytes.length;
                    while (end > 0 && bytes[end - 1] === 0xBE) end--;

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

            // Bitchat format uses the v2: prefix.
            const isBitchatFormat = (content) => content.startsWith('v2:');

            // Remote signers get standard NIP-44 only; Bitchat needs raw ECDH that only a local key can do.
            const unwrapWithRemoteSigner = async (decryptFn) => {
                if (isBitchatFormat(event.content)) {
                    throw new Error('Bitchat format requires local key');
                }
                const NC = window.NymCrypto;
                // Layered format works with a signer: ML-KEM uses our root-derived key, the inner NIP-44 goes to the signer.
                const pTag = (event.tags || []).find(t => Array.isArray(t) && t[0] === 'p' && t[1]);
                // Both layers were sealed to the p-tag target: identity key for PMs/self-copies, a rotating key for groups.
                const recipPk = (pTag && pTag[1]) || this.pubkey;
                let selfKems = null;
                let usedPq = false;
                const openPq2 = (content, senderPkHex) => {
                    if (!NC.isPq2Payload(content)) return content;
                    if (!selfKems) {
                        const cands = typeof this.pqSelfCandidates === 'function' ? this.pqSelfCandidates() : [];
                        selfKems = cands.filter(c => c && c.kemSk && c.kemPk);
                        if (!selfKems.length) {
                            const keys = this.pqSelfKeys();
                            if (keys) selfKems = [{ kemSk: keys.secretKey, kemPk: keys.publicKey }];
                        }
                        if (!selfKems.length) throw new Error('no post-quantum key for this identity');
                    }
                    let lastErr = null;
                    for (const kem of selfKems) {
                        try {
                            const inner = NC.pq2Open(content, senderPkHex, recipPk, kem);
                            usedPq = true;
                            return inner;
                        } catch (e) { lastErr = e; }
                    }
                    throw lastErr || new Error('post-quantum layer did not open');
                };

                const sealJson = await decryptFn(event.pubkey,
                    openPq2(event.content, event.pubkey));
                const seal = JSON.parse(sealJson);
                const rumorJson = await decryptFn(seal.pubkey,
                    openPq2(seal.content, seal.pubkey));
                const rumor = JSON.parse(rumorJson);
                return { seal, rumor, isPq: usedPq };
            };

            // Pick the active remote-signer NIP-44 decrypt (extension or NIP-46).
            const _extDecrypt = window.nostr?.nip44?.decrypt
                ? (peer, ct) => window.nostr.nip44.decrypt(peer, ct) : null;
            const _n46Decrypt = (this.nostrLoginMethod === 'nip46'
                && typeof _nip46State !== 'undefined' && _nip46State && _nip46State.connected)
                ? (peer, ct) => _nip46Decrypt(peer, ct) : null;
            const remoteDecrypt = _extDecrypt || _n46Decrypt;

            const anonCandidates = typeof this.botAnonCandidatesFor === 'function'
                ? this.botAnonCandidatesFor(event) : [];
            let seal, rumor;
            // Confidentiality (this) is orthogonal to authentication (senderVerified).
            let isPqWrap = false;
            if (anonCandidates.length) {
                const anonRes = await this._cryptoCall('unwrapGiftWrap', [event, anonCandidates],
                    () => window.NymCrypto.unwrapGiftWrap(event, anonCandidates));
                if (!anonRes) return;
                ({ seal, rumor } = anonRes);
                isPqWrap = !!anonRes.isPq;
                this._noteWrapDecrypted(event.id);
                if (!fromD1) this._botAnonArchive(event);
            } else if (this.privkey) {
                // Real key (Bitchat + NIP-44) first, then ephemeral keys (NIP-44).
                const ephSks = this._ephemeralCandidateSks(event);
                // The p-tag match leads so the common case costs one ML-KEM decapsulation; classical wraps fall through.
                const pTag = (event.tags || []).find(t => Array.isArray(t) && t[0] === 'p' && t[1]);
                const addressedToSelf = pTag && pTag[1] === this.pubkey;
                const orderedSks = addressedToSelf
                    ? [this.privkey, ...ephSks]
                    : [...ephSks, this.privkey];
                const candidates = [
                    ...this.pqUnwrapCandidates(orderedSks),
                    { sk: this.privkey, bitchat: true, selfId: this.pubkey },
                    ...ephSks.map(sk => ({ sk, bitchat: false }))
                ];
                let res = await this._cryptoCall('unwrapGiftWrap', [event, candidates],
                    () => window.NymCrypto.unwrapGiftWrap(event, candidates));
                // A worker without ML-KEM returns null for PQ wraps, so try this thread, which has it.
                if (!res && this._isPqPayload(event.content)) {
                    try { res = window.NymCrypto.unwrapGiftWrap(event, candidates); }
                    catch (_) { res = null; }
                }
                if (!res) return;
                ({ seal, rumor } = res);
                isPqWrap = !!res.isPq;
                this._noteWrapDecrypted(event.id);
            } else if (remoteDecrypt) {
                try {
                    const r = await unwrapWithRemoteSigner(remoteDecrypt);
                    ({ seal, rumor } = r);
                    isPqWrap = !!r.isPq;
                } catch (_remErr) {
                    // Remote signers can't use our local ephemeral keys, so try them here for group messages.
                    const ephResult = this._tryDecryptWithEphemeralKeys(event);
                    if (ephResult) {
                        ({ seal, rumor } = ephResult);
                    } else {
                        throw _remErr;
                    }
                }
                this._noteWrapDecrypted(event.id);
            } else {
                return;
            }

            // Accept kinds 14, 15, 69420 (receipt), 7, 9735, 30078 (settings sync) and CALL_SIGNALING_KIND.
            if (!rumor || (rumor.kind !== 14 && rumor.kind !== 15 && rumor.kind !== 69420 && rumor.kind !== 7 && rumor.kind !== 9735 && rumor.kind !== 30078 && rumor.kind !== this.CALL_SIGNALING_KIND && rumor.kind !== this.FRIEND_PRESENCE_KIND)) {
                return;
            }

            // NIP-59: the seal signer must match the claimed author; Bitchat seals use a throwaway key (unverified).
            if (!rumor.pubkey) return;
            const isBitchatWrap = isBitchatFormat(event.content);
            let senderVerified = true;
            if (isBitchatWrap) {
                senderVerified = false;
            } else if (!seal || seal.pubkey !== rumor.pubkey || !NT.verifyEvent(seal)) {
                return;
            }
            if (!senderVerified && typeof this.isVerifiedBot === 'function' && this.isVerifiedBot(rumor.pubkey)) return;
            if (!senderVerified && !this._unverifiedWrapAllowed(rumor, parseBitchatMessage)) return;

            // Friend-presence rumors ("Friends only" mode); verified senders only.
            if (rumor.kind === this.FRIEND_PRESENCE_KIND) {
                if (senderVerified) this.handleFriendPresenceRumor(rumor, rumor.pubkey);
                return;
            }

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

            if (rumor.kind === 30078) {
                if (!senderVerified) return;
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
                    // Cross-device ping with no settings content: pull the authoritative values from D1.
                    if (dTag === 'nymchat-sync-ping') {
                        try {
                            const ping = JSON.parse(rumor.content);
                            this._onSettingsChangedPing(ping, rumor.created_at || 0);
                        } catch (_) { }
                        return;
                    }
                    try {
                        const s = JSON.parse(rumor.content);
                        const rumorTs = rumor.created_at || 0;
                        // Core settings arrive split across nymchat-settings-<section> wraps.
                        const isCoreSettings = dTag === 'nymchat-settings' || dTag.startsWith('nymchat-settings-');
                        await applyNostrSettingsAdditive(s);
                        if (isCoreSettings) {
                            const subId = opts && opts.settingsLoadSubId;
                            const buf = subId && this._settingsLoadBuffer && this._settingsLoadBuffer.get(subId);
                            if (buf) {
                                // Buffer the newest payload per d-tag so each section applies once, after the initial REQ.
                                if (!buf.byTag) buf.byTag = {};
                                const prev = buf.byTag[dTag];
                                if (!prev || rumorTs > prev.ts) buf.byTag[dTag] = { ts: rumorTs, settings: s };
                                if (rumorTs > buf.newestTs) buf.newestTs = rumorTs;
                            } else if (dTag !== 'nymchat-settings') {
                                const appliedTs = (this._appliedSectionTs || (this._appliedSectionTs = {}));
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

            // NIP-30 custom emoji.
            this.ingestEmojiTags(rumor.tags);

            // NIP-92 Blossom mirror URLs.
            if (typeof this.ingestImetaTags === 'function') {
                this.ingestImetaTags(rumor.tags);
            }

            const senderPubkey = (typeof this.isBotAnonPubkey === 'function' && this.isBotAnonPubkey(rumor.pubkey))
                ? this.pubkey : rumor.pubkey;
            const isOwn = !!this.pubkey && senderPubkey === this.pubkey;

            const isBitchatUser = isBitchatFormat(event.content) || rumor.content?.startsWith('bitchat1:');
            if (isBitchatUser && !isOwn) {
                // With a timestamp: the PQ send plan must not let older evidence win (see `_pqPmPlan`).
                this.noteBitchatFormatSeen(senderPubkey,
                    (rumor && rumor.created_at) || (event && event.created_at) || 0);
            }

            const isNymUser = this.isNymMessage(rumor) || this.isNymReceipt(rumor);
            if (isNymUser && !isOwn) {
                this.nymUsers.add(senderPubkey);
            }

            // Typing indicators are ephemeral; discard stale ones.
            if (this.isTypingIndicator(rumor)) {
                if (!senderVerified) return;
                const rumorAge = Math.floor(Date.now() / 1000) - (rumor.created_at || 0);
                if (rumorAge > this._typingExpireMs / 1000) return;
                const parsed = this.parseTypingIndicator(rumor);
                this.handleTypingIndicatorEvent(parsed, senderPubkey, senderVerified);
                return;
            }

            // Before any PM state so group receipts (no 'g' tag) don't create phantom 1:1 PMs.
            if (this.isNymReceipt(rumor)) {
                if (!senderVerified) return;
                const nymReceipt = this.parseNymReceipt(rumor);
                const receiptIds = (nymReceipt && nymReceipt.messageIds) || [];
                if (nymReceipt && receiptIds.length) {
                    const receiptType = nymReceipt.receiptType;
                    if (receiptType === 'read') this.recordUserActivity(senderPubkey);
                    for (const rawId of receiptIds) {
                    const receiptId = rawId.toUpperCase();

                    let receiptMatched = false;
                    for (const [convKey, messages] of this.pmMessages) {
                        const msg = messages.find(m => m.nymMessageId?.toUpperCase() === receiptId);
                        if (msg && msg.isOwn) {
                            receiptMatched = true;
                            if (msg.isGroup && msg.groupId && typeof this._groupSenderAdmitted === 'function'
                                && !this._groupSenderAdmitted(msg.groupId, senderPubkey, null)) break;
                            const statusOrder = { sent: 0, delivered: 1, read: 2 };
                            if ((statusOrder[receiptType] || 0) >= (statusOrder[msg.deliveryStatus] || 0)) {
                                msg.deliveryStatus = receiptType;
                                this.pendingDMs.delete(msg.id);
                                this.persistPMMessages(convKey);

                                if (msg.isGroup && msg.nymMessageId && receiptType === 'read') {
                                    if (!this.groupMessageReaders.has(msg.nymMessageId)) {
                                        this.groupMessageReaders.set(msg.nymMessageId, new Map());
                                    }
                                    const readerNym = this.getNymFromPubkey(senderPubkey);
                                    this.groupMessageReaders.get(msg.nymMessageId).set(senderPubkey, readerNym);
                                    // Keyed by the receipt's conversation so it works regardless of which group is focused.
                                    if (this.channelDOMCache) this.channelDOMCache.delete(convKey);
                                    this.updateGroupReaderAvatars(msg.nymMessageId, convKey);
                                } else {
                                    const domId = msg.nymMessageId || msg.id;
                                    this._updateDeliveryStatusEl(domId, receiptType);
                                }
                            }
                            break;
                        }
                    }
                    // Receipt decrypted before its message; buffer it for when the message arrives.
                    if (!receiptMatched) this._bufferEarlyReceipt(receiptId, receiptType, senderPubkey);
                    }
                }
                return;
            }

            if (rumor.content?.startsWith('bitchat1:')) {
                const parsedEarly = parseBitchatMessage(rumor.content);
                if (parsedEarly.type === 0x02 || parsedEarly.type === 0x03) {
                    if (!senderVerified) return;
                    const receiptType = parsedEarly.type === 0x02 ? 'read' : 'delivered';
                    const receiptId = parsedEarly.messageId?.toUpperCase();

                    if (receiptType === 'read') this.recordUserActivity(senderPubkey);

                    if (receiptId) {
                        let receiptMatched = false;
                        for (const [convKey, messages] of this.pmMessages) {
                            const msg = messages.find(m => m.bitchatMessageId?.toUpperCase() === receiptId);
                            if (msg && msg.isOwn) {
                                receiptMatched = true;
                                const statusOrder = { sent: 0, delivered: 1, read: 2 };
                                if ((statusOrder[receiptType] || 0) >= (statusOrder[msg.deliveryStatus] || 0)) {
                                    msg.deliveryStatus = receiptType;
                                    this.pendingDMs.delete(msg.id);
                                    this.persistPMMessages(convKey);
                                    const domId = msg.nymMessageId || msg.id;
                                    this._updateDeliveryStatusEl(domId, receiptType);
                                }
                                break;
                            }
                        }
                        if (!receiptMatched) this._bufferEarlyReceipt(receiptId, receiptType, senderPubkey);
                    }
                    return;
                }
            }

            // Kind 69420 is only receipts and typing (handled above); anything else is malformed.
            if (rumor.kind === 69420) {
                return;
            }

            if (!isOwn && this.blockedUsers && this.blockedUsers.has(senderPubkey)) return;

            if (!isOwn && senderVerified === true && rumor.kind === 14
                && !(rumor.tags || []).some(t => Array.isArray(t) && t[0] === 'g')) {
                this._notePmSupportToken(senderPubkey, rumor);
            }

            // Archive only durable content; settings/signaling/typing/receipts already returned.
            if (!fromD1) this._archivePMEvent(event);

            if (!isOwn && !this.users.has(senderPubkey)) {
                await this.fetchProfileDirect(senderPubkey);
            }

            // Route group messages before 1:1 PM logic.
            const groupTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'g' && typeof t[1] === 'string');
            if (groupTag) {
                if (!senderVerified) return;
                await this.handleGroupMessage(rumor, event, senderPubkey, isOwn, senderVerified, isPqWrap);
                return;
            }

            if (rumor.kind === 7) {
                if (!senderVerified) return;
                const eTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'e' && t[1]);
                if (eTag) {
                    const reactionMessageId = eTag[1];
                    const emoji = rumor.content;
                    if (!this.isValidReactionEmoji(emoji)) { return; }
                    const actionTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'action');
                    const isRemoval = actionTag && actionTag[1] === 'remove';

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
                    // Drop the cached render so the reaction shows after a channel switch.
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

            if (rumor.kind === 9735) {
                if (!senderVerified) return;
                const eTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'e' && t[1]);
                const boltTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'bolt11' && t[1]);
                if (eTag && boltTag) {
                    const zapMessageId = eTag[1];
                    const amount = this.parseAmountFromBolt11(boltTag[1]);
                    const dedupKey = 'b:' + boltTag[1].toLowerCase();
                    const existing = this.zaps.get(zapMessageId);
                    if (amount && !(existing && existing.receipts.has(dedupKey))) {
                        const isLive = (Date.now() - ((rumor.created_at || 0) * 1000)) <= 10000;
                        this._recordMessageZap(zapMessageId, senderPubkey, amount, dedupKey, isLive, senderVerified);

                        const pTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'p' && t[1]);
                        if (senderPubkey !== this.pubkey && pTag && pTag[1] === this.pubkey) {
                            this._notifyZapToOurMessage(zapMessageId, amount, senderPubkey, { id: event.id, created_at: rumor.created_at });
                        }
                    }
                }
                return;
            }

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

            // Stale relay backlog must not resurrect a conversation the user just deleted.
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

            let list = this.pmMessages.get(conversationKey);
            if (list.some(m => m.id === event.id)) return;

            const nowSec = Math.floor(Date.now() / 1000);
            const originalTsSec = Math.floor(rumor.created_at) || nowSec;
            let tsSec = originalTsSec;

            // Guard against clock skew: no future messages.
            tsSec = Math.min(tsSec, nowSec);

            const parsed = parseBitchatMessage(rumor.content);

            if (parsed.type !== 0x01) return;

            let messageContent = parsed.content;

            // Drop raw ciphertext from other NIP-17 implementations; exempt our own self-wraps.
            if (!isOwn && messageContent && messageContent.length > 80 &&
                !/\s/.test(messageContent) && /^[A-Za-z0-9+/=_-]+$/.test(messageContent) &&
                !/^(lnbc|lnurl|lntb|lntbs|cashu|npub1|nsec1|nprofile1|nevent1|naddr1|note1|bc1|tb1|bitcoin:)/i.test(messageContent)) {
                return;
            }

            if (!messageContent || !messageContent.trim()) return;

            const pmEditTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'edit' && t[1]);
            if (pmEditTag) {
                if (!senderVerified) return;
                const originalId = pmEditTag[1];
                this.handleIncomingPMEdit(originalId, messageContent, senderPubkey, conversationKey, senderVerified);
                return;
            }

            // Dual-wrapped duplicates: match on the shared `x` nymMessageId, else sender + content + close timestamp.
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
                const dupMayRewrite = senderVerified === true || dupMsg.senderVerified !== true;
                if (dupMayRewrite && !dupMsg.nymMessageId && nymMsgIdFromRumor) {
                    // Reactions follow the message to its nymMessageId, the ID the DOM renders with.
                    this._migrateReactionKey(dupMsg.id, nymMsgIdFromRumor);
                    dupMsg.nymMessageId = nymMsgIdFromRumor;
                    const oldEl = document.querySelector(`[data-message-id="${dupMsg.id}"]`);
                    if (oldEl) {
                        oldEl.dataset.messageId = nymMsgIdFromRumor;
                    }
                    this.updateMessageReactions(nymMsgIdFromRumor);
                    needsRerender = true;
                }
                // Prefer longer content; an older sender may have truncated the bitchat copy.
                if (dupMayRewrite && messageContent && messageContent.length > (dupMsg.content || '').length) {
                    dupMsg.content = messageContent;
                    needsRerender = true;
                }
                // Never for our own sent message.
                if (isPqWrap && !dupMsg.pqEncrypted && !dupMsg.isOwn) {
                    dupMsg.pqEncrypted = true;
                    dupMsg.pqRoot = this.pqSealIsRootSeeded(peerPubkey);
                    // Flip the shield immediately in case the classical copy rendered first.
                    if (typeof this.refreshMessagePqBadge === 'function') {
                        this.refreshMessagePqBadge(dupMsg.nymMessageId || dupMsg.id);
                    }
                    needsRerender = true;
                }
                if (senderVerified === true && dupMsg.senderVerified !== true) {
                    dupMsg.senderVerified = true;
                    // Flip the lock immediately so the verified copy wins over an unverified Bitchat copy.
                    this._setMessageVerifiedDOM(dupMsg.nymMessageId || dupMsg.id, true);
                    this._recordMsgVerification(dupMsg.nymMessageId, true);
                    needsRerender = true;
                }
                if (needsRerender) {
                    this.channelDOMCache.delete(conversationKey);
                    this.persistPMMessages(conversationKey);
                }
                return;
            }

            if (messageContent && messageContent.includes('Channel Invitation:')) {
                const inviteMatch = messageContent.match(/join\s+#([a-z0-9]+)/i);
                if (inviteMatch) {
                    const invitedChannel = inviteMatch[1];
                    if (this.isChannelBlocked(invitedChannel, invitedChannel)) {
                        return;
                    }
                }
            }

            if (!isOwn && this.settings.acceptPMs !== 'enabled') {
                if (this.settings.acceptPMs === 'disabled') return;
                if (this.settings.acceptPMs === 'friends' && !this.isFriend(senderPubkey)) return;
            }

            const senderName = this.getNymFromPubkey(senderPubkey);

            // Split a leading <think> block into its own field for previews and a collapsible section.
            let botThinking = null;
            if (this.isVerifiedBot(senderPubkey)) {
                const tm = /^\s*<think>([\s\S]*?)<\/think>\s*/i.exec(messageContent);
                if (tm && messageContent.slice(tm[0].length).trim()) {
                    botThinking = tm[1].trim();
                    messageContent = messageContent.slice(tm[0].length);
                }
            }

            const nymMsgId = nymMsgIdFromRumor;

            const pmFileOffer = senderVerified ? this.parseFileOfferTag(rumor.tags, senderPubkey) : null;

            // Our own archive copy is sealed to our key, so ask the recipient's plan instead of trusting isPqWrap.
            const pmIsPq = isOwn ? !!this.pqLayeredKeyFor(peerPubkey) : isPqWrap;

            const msg = {
                id: event.id,
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
                // Confidentiality, orthogonal to senderVerified.
                pqEncrypted: pmIsPq,
                pqRoot: pmIsPq && this.pqSealRootVerdict(peerPubkey) === true,
                isFileOffer: !!pmFileOffer,
                fileOffer: pmFileOffer,
                thinking: botThinking || undefined,
                anonWrap: anonCandidates.length ? true : undefined,
                bitchatMessageId: parsed.messageId,  // For sending Bitchat read receipts
                nymMessageId: nymMsgId,  // For sending Nymchat read receipts
                threadRoot: (typeof this.threadRootFromRumorTags === 'function')
                    ? this.threadRootFromRumorTags(rumor.tags) : null,
                deliveryStatus: isOwn ? 'sent' : undefined
            };
            // The announcement may still be in flight; fill the verdict in later.
            if (pmIsPq) {
                this.pqResolveRootVerdict(peerPubkey, nymMsgId || msg.id,
                    (v) => { msg.pqRoot = v; });
            }
            this._recordMsgVerification(nymMsgId, senderVerified);

            if (this._botThreadForeign(msg, list)) {
                this._holdBotThreadOrphan(msg);
                return;
            }
            list.push(msg);
            list.sort((a, b) => {
                return this._compareMessages(a, b);
            });
            if (list.length > this.pmStorageLimit) {
                list = list.slice(-this.pmStorageLimit);
            }
            this.pmMessages.set(conversationKey, list);
            this._adoptBotThreadOrphans(msg, conversationKey);
            this.persistPMMessages(conversationKey);
            if (isOwn) this._applyEarlyReceipt(msg, conversationKey);

            if (!isOwn && parsed.messageId && this.bitchatUsers.has(senderPubkey)) {
                this.sendBitchatReceipt(parsed.messageId, 0x03, senderPubkey); // 0x03 = DELIVERED
            }

            if (!isOwn && nymMsgId && this.nymUsers.has(senderPubkey)) {
                this.sendNymReceipt(nymMsgId, 'delivered', senderPubkey);
            }

            const peerName = this.getNymFromPubkey(peerPubkey);
            this.addPMConversation(peerName, peerPubkey, tsSec * 1000);
            this.movePMToTop(peerPubkey, tsSec * 1000);

            if (!isOwn) {
                const convTypers = this.typingUsers.get(conversationKey);
                if (convTypers && convTypers.has(senderPubkey)) {
                    const entry = convTypers.get(senderPubkey);
                    if (entry.timeout) clearTimeout(entry.timeout);
                    convTypers.delete(senderPubkey);
                    this.renderTypingIndicator();
                }
            }

            // Collapsed thread replies must neither advance the read watermark nor count as seen.
            const pmThreadHidden = typeof this._threadReplyHidden === 'function' &&
                this._threadReplyHidden(msg);
            const notifyForPM = () => {
                if (this.blockedUsers.has(peerPubkey) || this.hasBlockedKeyword(msg.content, msg.author, peerPubkey)) return;
                // `threadNotifyMentionsOnly` applies to PM threads too.
                if (this._threadReplySuppressed(msg)) return;
                const ageMs = Date.now() - (tsSec * 1000);
                const treatAsHistorical = msg.isHistorical || ageMs > 30000;
                const pmChannelInfo = {
                    type: 'pm',
                    nym: msg.author,
                    pubkey: peerPubkey,
                    id: conversationKey,
                    eventId: event.id,
                    // Names the thread in the bell footer ("PM thread").
                    ...(msg.threadRoot && this.threadsEnabled()
                        ? { inThread: true, threadRoot: msg.threadRoot } : {})
                };
                if (!treatAsHistorical) {
                    this.showNotification(`PM from ${msg.author}`, messageContent, pmChannelInfo, tsSec * 1000);
                } else {
                    this._addNotificationToHistory(`PM from ${msg.author}`, messageContent, pmChannelInfo, tsSec * 1000);
                }
            };
            if (this.inPMMode && this.currentPM === peerPubkey) {
                this.displayMessage(msg);
                this._scheduleScrollToBottom();
                if (typeof this._markChannelRead === 'function' && !pmThreadHidden) {
                    this._markChannelRead(conversationKey, msg.created_at);
                }
                if (!isOwn && pmThreadHidden) notifyForPM();
                // Mark it so openPM doesn't re-send the receipt.
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
                // Column view: render into the conversation's open column even when unfocused.
                const cvShown = this._cvActive && this._cvListForKey(conversationKey);
                if (cvShown) this.displayMessage(msg);
                // Leave the cached DOM; loadPMMessages appends new messages to the cached fragment.
                if (!isOwn) {
                    if (!(cvShown && this._cvMarkColumnRead(conversationKey))) this.updateUnreadCount(conversationKey, msg.created_at);
                    notifyForPM();
                }
            }
        } catch (err) {
        } finally {
            // Never reached _noteWrapDecrypted, so release it for the next delivery.
            if (this._pmWrapAttempted && event && event.id
                && !(this._decryptedWrapIds && this._decryptedWrapIds.has(event.id))) {
                this._pmWrapAttempted.delete(event.id);
            }
        }
    },

    getPMConversationKey(otherPubkey) {
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

    // Deposited into the recipient's D1 inbox so they can restore it even if offline when sent.
    _depositPMEvent(event) {
        if (!event || typeof event.id !== 'string') return;
        if (!this._pmArchiveAllowed()) return;
        const pTag = (event.tags || []).find(t =>
            Array.isArray(t) && t[0] === 'p' && typeof t[1] === 'string');
        if (!pTag || pTag[1] === this.pubkey) return;
        if (!this._pmDepositedIds) this._pmDepositedIds = new Set();
        if (this._pmDepositedIds.has(event.id)) return;
        this._pmDepositedIds.add(event.id);
        if (this._pmDepositedIds.size > 6000) {
            this._pmDepositedIds = new Set(Array.from(this._pmDepositedIds).slice(-4000));
        }
        if (!this._pmDepositQueue) this._pmDepositQueue = [];
        this._pmDepositQueue.push(event);
        const depositCap = this.MAX_PM_DEPOSIT_QUEUE || 600;
        while (this._pmDepositQueue.length > depositCap) {
            this._pmDepositQueue.splice(this._pmSecureRandomInt(this._pmDepositQueue.length), 1);
            this._pmDepositDropped = (this._pmDepositDropped || 0) + 1;
            if (!this._pmDepositDropWarnTs || Date.now() - this._pmDepositDropWarnTs > 30000) {
                this._pmDepositDropWarnTs = Date.now();
                console.warn('[PM] deposit queue full; dropped', this._pmDepositDropped, 'wraps');
            }
        }
        if (this._pmDepositFlushTimer) return;
        this._pmDepositFlushTimer = setTimeout(() => {
            this._pmDepositFlushTimer = null;
            this._flushPMDeposit();
        }, this._pmDepositDelay(false));
    },

    _pmSecureRandomInt(n) {
        const range = Math.floor(n);
        if (!(range > 1)) return 0;
        const limit = Math.floor(0x100000000 / range) * range;
        const buf = new Uint32Array(1);
        do { crypto.getRandomValues(buf); } while (buf[0] >= limit);
        return buf[0] % range;
    },

    _pmDepositDelay(backlog) {
        const base = backlog
            ? (this.PM_DEPOSIT_BACKLOG_MS || 600)
            : (this.PM_DEPOSIT_FLUSH_MS || 4000);
        const jitter = this.PM_DEPOSIT_FLUSH_JITTER_MS || 0;
        return base + this._pmSecureRandomInt(jitter + 1);
    },

    _pmDepositBatchSize() {
        const min = this.PM_DEPOSIT_BATCH_MIN || 40;
        const max = this.PM_DEPOSIT_BATCH_MAX || 100;
        if (max <= min) return max;
        return min + this._pmSecureRandomInt(max - min + 1);
    },

    _shufflePmDepositQueue() {
        const q = this._pmDepositQueue;
        for (let i = q.length - 1; i > 0; i--) {
            const j = this._pmSecureRandomInt(i + 1);
            const tmp = q[i];
            q[i] = q[j];
            q[j] = tmp;
        }
    },

    async _flushPMDeposit() {
        if (!this._pmDepositQueue || this._pmDepositQueue.length === 0) return;
        this._shufflePmDepositQueue();
        const batch = this._pmDepositQueue.splice(0, this._pmDepositBatchSize());
        try {
            await this._storageApiRequest('pm-deposit', { events: batch });
        } catch (_) {
            // Best-effort: drop on failure rather than risk an upload loop.
        }
        if (this._pmDepositQueue.length > 0 && !this._pmDepositFlushTimer) {
            this._pmDepositFlushTimer = setTimeout(() => {
                this._pmDepositFlushTimer = null;
                this._flushPMDeposit();
            }, this._pmDepositDelay(true));
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
        // Suppress the settings save the replay would otherwise trigger.
        this._restoreFromD1Depth = (this._restoreFromD1Depth || 0) + 1;
        try {
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
        } finally {
            this._restoreFromD1Depth = Math.max(0, (this._restoreFromD1Depth || 1) - 1);
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

    async sendPM(content, recipientPubkey, options = {}) {
        try {
            if (this.isVerifiedBot(recipientPubkey) &&
                /^\s*\?(help|commands|balance|buy|clear|transfer|gift|model|anon|git|github)\b/i.test(content || '')) {
                this._handleBotPM(String(content).trim(), null);
                return true;
            }
            if (!this.connected) throw new Error('Not connected to relay');
            if (!content || !content.trim()) return false;
            if (this.isVerifiedBot(recipientPubkey) && this.botAnonEnabled && this.botAnonEnabled()) {
                const blocked = this.botAnonBlockedReason();
                if (blocked) {
                    this.displaySystemMessage('Anonymous Nymbot chat: ' + blocked);
                    return false;
                }
            }

            const wrapped = await this.sendNIP17PM(content, recipientPubkey, options);
            this.recordOwnActivity();
            if (this.isVerifiedBot(recipientPubkey)) {
                this._handleBotPM(content, typeof wrapped === 'string' ? wrapped : null);
            }
            return !!wrapped;
        } catch (error) {
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
            this.channelDOMCache.delete(conversationKey);
            this.persistPMMessages(conversationKey);
            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(failedMsg);
            }
            return false;
        }
    },

    // NIP-98-style (kind 27235) auth bound to endpoint + method + action; money actions are signed fresh.
    async _authPayloadHash(body) {
        const canonical = {};
        for (const k of Object.keys(body || {}).filter((k) => k !== 'auth').sort()) canonical[k] = body[k];
        const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(canonical)));
        return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
    },

    async _signBotAuth(action, endpoint, payloadHash) {
        endpoint = endpoint || 'bot';
        const apiHost = this._getApiHost();
        const url = apiHost ? `https://${apiHost}/api/${endpoint}` : '';
        const nowSec = Math.floor(Date.now() / 1000);
        const MONEY = {
            'transfer-credits': 1, 'create-invoice': 1, 'claim-credits': 1,
            'shop-buy-invoice': 1, 'shop-claim': 1, 'shop-transfer': 1, 'shop-redeem': 1,
            'voucher-issue': 1
        };
        const sensitive = !!MONEY[action] || action === 'clear-history' || action === 'account-purge' || action === 'api-ws';
        const cacheKey = (action || '') + '|' + url;
        if (!(this._botAuthCache instanceof Map)) this._botAuthCache = new Map();
        if (!sensitive && !payloadHash) {
            const cached = this._botAuthCache.get(cacheKey);
            // Stay well under the worker's 120s window to avoid edge-of-window rejects.
            if (cached && cached.pubkey === this.pubkey && (nowSec - cached.auth.created_at) < 90) {
                return cached.auth;
            }
        }
        const tags = [['domain', 'nymbot-pm'], ['method', 'POST']];
        if (url) tags.push(['u', url]);
        if (action) tags.push(['action', action]);
        if (payloadHash) tags.push(['payload', payloadHash]);
        const event = {
            kind: 27235,
            created_at: nowSec,
            tags,
            content: 'nymbot-pm-auth',
            pubkey: this.pubkey
        };
        const auth = await this.signEvent(event);
        if (!sensitive && !payloadHash) this._botAuthCache.set(cacheKey, { pubkey: this.pubkey, auth });
        return auth;
    },

    async _clearBotServerThread() {
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) return;
            await this._botMoneyRequest('clear-history', {});
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

    _botWelcomeHtml() {
        return [
            'Hey, I\'m <strong>Nymbot</strong> 👋 — your private, end-to-end encrypted 1:1 AI assistant.',
            '',
            'I\'m smarter than the free public-channel bot. I read each message, figure out the type of task (coding, reasoning/math, creative writing, translation, or general chat) and route it to the best AI model for the job — so my answers are sharper.',
            '',
            '<strong>Here\'s how to get the most out of me:</strong>',
            '• <code>?help</code> — full guide to premium vs Pro, credits, and every command (free).',
            '• Just type normally — I use our whole conversation as context.',
            '• Start a message with <code>!</code> to get a one-off answer that ignores all earlier chat history (e.g. <code>!what is 2+2</code>).',
            '• Quote-reply any message to ask a follow-up about it — I\'ll see what you\'re replying to.',
            '• <code>?clear</code> — wipe this chat and start fresh.',
            '• <code>?balance</code> — check your credit balance (also shown in the header).',
            '• <code>?buy</code> — purchase more credits. <code>?gift @nym#xxxx</code> — gift credits to someone.',
            '• <code>?model</code> — go <strong>Pro</strong>: pick a specific frontier model (Claude Fable 5, Claude Opus/Sonnet/Haiku, GPT-5.6 Sol, Gemini, Grok, Kimi K3, Qwen, MiniMax) for every reply, paid with separate Pro credits.',
            '• <code>?image &lt;description&gt;</code> — generate a picture. On Pro, add <code>--model &lt;name&gt;</code> to pick a frontier generator (Nano Banana Pro, Imagen 4, FLUX 2, Seedream, GPT Image 2, Grok Imagine, Recraft) — <code>?image models</code> lists them free.',
            '• <code>?speak &lt;text&gt;</code> — get it read aloud as a voice clip.',
            '• Send or link a picture — models that can see will look at the image itself, not just the link.',
            '• <code>?transfer @nym#xxxx confirm</code> — move ALL your credits to another pubkey (great for switching nyms).',
            '',
            '<strong>Pricing:</strong> replies are metered on the tokens they actually use and charged in thousandths of a credit, so a short question costs a fraction of one and a long answer more. Coding and reasoning/math cost more per token because they use larger models, and repeated context is billed at a cached rate. Pro replies work the same way on separate Pro credits — the per-million-token rates are in <code>?model</code>. <code>?image</code> costs <strong>5 credits</strong> (2 Pro) and <code>?speak</code> <strong>3 credits</strong> (1 Pro), charged per generation — nothing is charged if it fails. Credits are tied to your nym — save your nsec so you don\'t lose them.',
            '',
            'So, what can I help you with?'
        ].join('<br>');
    },

    _displayBotPmHelp() {
        const proModel = this._getBotProModel();
        const std = this._lastBotCredits;
        const pro = this._lastBotProCredits;
        // Samples the catalog; the live list can run to dozens of models.
        const allProModels = this._botProModelList();
        const modelLines = allProModels.slice(0, 8).map(m =>
            `&nbsp;&nbsp;<code>${m.key}</code> — ${this.escapeHtml(m.label)}, ${this._botProPriceLabel(m)}`);
        if (allProModels.length > 8) {
            modelLines.push(`&nbsp;&nbsp;…and ${allProModels.length - 8} more — type <code>?model</code> or tap the model button.`);
        }
        const statusBits = [];
        if (typeof std === 'number') statusBits.push(this._creditWord(std, 'standard credit'));
        if (typeof pro === 'number') statusBits.push(this._creditWord(pro, 'Pro credit'));
        statusBits.push(proModel ? `Pro model: ${this.escapeHtml(proModel.label)}` : 'Pro model: off (standard routing)');
        this._displayBotInfoMessage([
            '<strong>📖 Nymbot premium guide</strong>',
            `<em>You right now: ${statusBits.join(' · ')}.</em>`,
            '',
            '<strong>1. Standard premium (this chat)</strong>',
            'Each message is auto-routed to the best AI model for its task. Replies are metered on the tokens they actually use and charged in thousandths of a <strong>standard credit</strong> (10 sats each, bulk bonuses from 500 sats) — a short question costs a fraction of one, a long answer more, and coding or reasoning routes cost more per token because they use bigger models. Repeated context is billed at a cached rate, so a long chat does not re-pay for its own history.',
            '',
            '<strong>2. Nymbot Pro</strong>',
            'Pin every reply to a specific frontier model instead of auto-routing. Pro replies spend separate <strong>Pro credits</strong> (100 sats each, bulk bonuses from 5K sats), metered the same way — these are the per-million-token rates you are charged:',
            ...modelLines,
            'Pick with <code>?model &lt;name&gt;</code> (e.g. <code>?model claude-opus</code>), back to standard with <code>?model off</code>. Buy Pro credits via <code>?buy</code> → Pro switch.',
            '',
            '<strong>3. Credits</strong>',
            '<code>?balance</code> shows both balances · <code>?buy</code> purchases over Lightning (Standard/Pro switch) · <code>?gift @nym#xxxx</code> gifts credits · <code>?transfer @nym#xxxx confirm</code> moves your ENTIRE balance (both pools) to another pubkey.',
            'Credits are tied to your nym — save your nsec (sidebar → your nym → Reveal private key) so they survive a new session.',
            '',
            '<strong>4. Chat tricks</strong>',
            'Start a message with <code>!</code> for a one-off answer that ignores history · <code>?clear</code> wipes the conversation · quote-reply any message to ask a follow-up about it.',
            '',
            'This guide is free — type <code>?help</code> anytime.'
        ].join('<br>'), 'nymbot-help-' + Date.now());
    },

    // Local-only, never persisted.
    _displayBotInfoMessage(html, messageId) {
        if (!messageId) messageId = 'nymbot-info-' + Date.now() + '-' + Math.random().toString(36).slice(2, 7);
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
        el.dataset.messageId = messageId;
        el.dataset.author = botNym;
        el.dataset.timestamp = now.getTime();
        el.innerHTML = `
    ${time ? `<span class="message-time ${this.settings.timeFormat === '12hr' ? 'time-12hr' : ''}" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${time}</span>` : ''}
    <span class="message-author ${userColorClass}"><span class="bubble-time" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${bubbleTime}</span><span class="author-clickable">${displayAuthor}${verifiedBadge}</span><span class="nym-bracket">&gt;</span></span>
    <span class="message-content ${userColorClass}">${html}<span class="bubble-time-inner" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${bubbleTime}</span></span>
`;
        container.appendChild(el);
        this._updateBubbleGrouping(el);
        this._scheduleScrollToBottom();
        return el;
    },

    _displayBotWelcomeMessage() {
        const html = this._botWelcomeHtml();
        const el = this._displayBotInfoMessage(html, 'nymbot-welcome');
        if (el && typeof this.translateBotWelcomeBubble === 'function') {
            this.translateBotWelcomeBubble(el, html);
        }
    },

    // Markdown so it renders through the normal pipeline.
    _botFirstContactText() {
        return [
            'Welcome to **Nymchat** 👋 — I\'m **Nymbot**, your built-in AI assistant.',
            '',
            'In any public channel you can ask me anything for **free** — just type `?ask <your question>` or mention `@Nymbot`. Type `?help` in a channel to see everything I can do.',
            '',
            'Right here in our private 1:1 chat is the **premium** tier: it\'s end-to-end encrypted and I route each message to the best AI model for the job (coding, reasoning/math, creative writing, translation, or general chat). These private replies cost **credits**, metered on the tokens each reply uses — a short question costs a fraction of a credit, a long answer more, and the coding and reasoning routes cost more per token because they use bigger models.',
            '',
            'Want even more power? **Nymbot Pro** lets you pick a specific frontier model — Claude Fable 5, Claude Opus, GPT-5.1, and more — for every reply. Type `?model` to see them; Pro replies use separate Pro credits.',
            '',
            'Type `?buy` to get credits (Standard or Pro) and `?balance` to check your balance. Credits are tied to your nym, so save your nsec to keep them. Type `?help` here anytime for the full free guide to premium, Pro, and credits.',
            '',
            'So, what can I help you with?'
        ].join('\n');
    },

    // Sent locally, once per device.
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
        this.updateUnreadCount(conversationKey, msg.created_at);
        try { localStorage.setItem('nym_botpm_welcomed', 'true'); } catch { }
        if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(2000);
    },

    async _purgeBotPMArchive(conversationKey) {
        const anonReady = typeof this.botAnonReady === 'function' && this.botAnonReady();
        const msgs = this.pmMessages.get(conversationKey) || [];
        const anonIds = new Set();
        const ownIds = new Set();
        for (const m of msgs) {
            if (!m) continue;
            const bucket = (m.anonSender || m.anonWrap) ? anonIds : ownIds;
            if (typeof m.id === 'string' && /^[0-9a-f]{64}$/i.test(m.id)) bucket.add(m.id);
            const shared = m.nymMessageId && this._giftWrapsForSharedId
                ? this._giftWrapsForSharedId.get(m.nymMessageId) : null;
            if (shared) for (const wid of shared) bucket.add(wid);
        }
        const send = async (ids, viaAnon) => {
            const list = Array.from(ids);
            for (let i = 0; i < list.length; i += 200) {
                const chunk = list.slice(i, i + 200);
                try {
                    if (viaAnon) await this._botAnonPost('storage', 'pm-delete', { ids: chunk });
                    else await this._storageApiRequest('pm-delete', { ids: chunk });
                } catch (_) { }
            }
        };
        if (anonReady && anonIds.size) await send(anonIds, true);
        if (this._pmArchiveAllowed() && ownIds.size) await send(ownIds, false);
    },

    _clearBotPMHistory() {
        const pubkey = this.verifiedBot && this.verifiedBot.pubkey;
        if (!pubkey) return;
        const conversationKey = this.getPMConversationKey(pubkey);
        this._setBotPmClearedAt(Math.floor(Date.now() / 1000));
        this._clearBotServerThread();
        this._purgeBotPMArchive(conversationKey);
        // Sync the cleared-at marker so other devices filter archived wraps too.
        if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(2000);
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
        let targetPubkey = this.normalizePubkeyInput(targetArg);
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
            const havePro = this._lastBotProCredits || 0;
            if ((!have || have <= 0) && havePro <= 0) {
                this.displaySystemMessage('You have no Nymbot credits to transfer.');
                return;
            }
            const parts = [];
            if (have > 0) parts.push(this._creditWord(have, 'credit'));
            if (havePro > 0) parts.push(this._creditWord(havePro, 'Pro credit'));
            this.displaySystemMessage(`Transfer ALL ${parts.join(' and ')} to @${targetNym}? This empties your balance. To confirm, type: ?transfer @${targetNym}#${this.getPubkeySuffix(targetPubkey)} confirm`);
            return;
        }
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) return;
            const { status, data } = await this._botMoneyRequest('transfer-credits', { targetPubkey });
            if (status >= 400 || !data || data.error) {
                this.displaySystemMessage('Transfer failed: ' + ((data && data.error) || 'request failed'));
                return;
            }
            this._setBotCreditDisplay(0);
            this._setBotProCreditDisplay(0);
            const moved = [];
            if (data.transferred > 0) moved.push(`${data.transferred} credit${data.transferred === 1 ? '' : 's'}`);
            if (data.proTransferred > 0) moved.push(`${data.proTransferred} Pro credit${data.proTransferred === 1 ? '' : 's'}`);
            this.displaySystemMessage(`Transferred ${moved.join(' and ') || '0 credits'} to @${targetNym}. Your balance is now 0.`);
        } catch (e) {
            this.displaySystemMessage('Transfer failed. Please try again.');
        }
    },

    _setBotTyping(on) {
        const convKey = this.getPMConversationKey(this.verifiedBot.pubkey);
        if (!this.typingUsers.has(convKey)) this.typingUsers.set(convKey, new Map());
        const typers = this.typingUsers.get(convKey);
        const botPk = this.verifiedBot.pubkey;
        const existing = typers.get(botPk);
        if (existing && existing.timeout) clearTimeout(existing.timeout);
        if (this._botTypingHeartbeat) {
            clearInterval(this._botTypingHeartbeat);
            this._botTypingHeartbeat = null;
        }
        if (on) {
            const arm = () => {
                const prev = typers.get(botPk);
                if (prev && prev.timeout) clearTimeout(prev.timeout);
                const timeout = setTimeout(() => {
                    typers.delete(botPk);
                    if (this._botTypingHeartbeat) {
                        clearInterval(this._botTypingHeartbeat);
                        this._botTypingHeartbeat = null;
                    }
                    this.renderTypingIndicator();
                }, 30000);
                typers.set(botPk, { nym: 'Nymbot', timeout, timestamp: Date.now() });
            };
            arm();
            this._botTypingHeartbeat = setInterval(arm, 20000);
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
        if (changed) {
            this.channelDOMCache.delete(convKey);
            this.persistPMMessages(convKey);
        }
    },

    // Mirrors BOT_PRO_MODELS in functions/api/bot.js; renders until the live D1-backed catalog loads.
    _botProModelsFallback: [
        { key: 'claude-fable', label: 'Claude Fable 5', credits: 2, max: 16 },
        { key: 'claude-opus', label: 'Claude Opus 5', credits: 1, max: 8 },
        { key: 'claude-sonnet', label: 'Claude Sonnet 5', credits: 1, max: 6 },
        { key: 'claude-haiku', label: 'Claude Haiku 4.5', credits: 1, max: 1 },
        { key: 'gpt-5', label: 'GPT-5.6 Sol', credits: 1, max: 6 },
        { key: 'gpt-5-mini', label: 'GPT-5.4 mini', credits: 1, max: 1 },
        { key: 'gemini-pro', label: 'Gemini 3.1 Pro', credits: 1, max: 5 },
        { key: 'gemini-flash', label: 'Gemini 3.6 Flash', credits: 1, max: 3 },
        { key: 'grok', label: 'Grok 4.6', credits: 1, max: 6 },
        { key: 'kimi', label: 'Kimi K3', credits: 1, max: 3 },
        { key: 'qwen', label: 'Qwen 3.5', credits: 1, max: 3 },
        { key: 'minimax', label: 'MiniMax M3', credits: 1, max: 3 },
        { key: 'deepseek-v4-pro', label: 'DeepSeek V4 Pro', credits: 1, max: 3, hosting: 'cloudflare-hosted', reasoning: true, tools: true },
        { key: 'deepseek-v4-flash', label: 'DeepSeek V4 Flash', credits: 1, max: 1, hosting: 'cloudflare-hosted', reasoning: true, tools: true },
        { key: 'deepseek-r1-distill-qwen-32b', label: 'DeepSeek R1 Distill Qwen 32B', credits: 1, max: 3, hosting: 'cloudflare-hosted', reasoning: true }
    ],

    // { models: [...], groups: [...], aliases: {} }.
    _botProCatalog: null,
    _botProCatalogAt: 0,

    // Degrades to the built-in list instead of an empty picker.
    _botProModelList() {
        const live = ((this._botProCatalog && this._botProCatalog.models) || [])
            .filter(m => m && (!m.kind || m.kind === 'chat') && !m.command);
        return live.length ? live : this._botProModelsFallback;
    },

    _botProGroups() {
        const live = this._botProCatalog;
        const groups = ((live && live.groups) || []).filter(g => g && (!g.kind || g.kind === 'chat'));
        if (groups.length) return groups;
        return [{ author: '', authorSlug: '', keys: this._botProModelsFallback.map(m => m.key) }];
    },

    _botGeneratorList() {
        return ((this._botProCatalog && this._botProCatalog.models) || [])
            .filter(m => m && (m.kind === 'image' || m.kind === 'video') && m.key);
    },

    _botGeneratorGroups() {
        return ((this._botProCatalog && this._botProCatalog.groups) || [])
            .filter(g => g && (g.kind === 'image' || g.kind === 'video') && Array.isArray(g.keys));
    },

    _botPriceUnavailable() {
        const cat = this._botProCatalog;
        return !!(cat && (cat.priceUnavailable || cat.usdPerCredit === null));
    },

    _botGeneratorDefaultRes(g) {
        const res = Array.isArray(g && g.resolutions) ? g.resolutions : [];
        return (g && g.resolution) || (res.length ? res[res.length - 1].res : '');
    },

    _botGeneratorCredits(v) {
        if (this._botPriceUnavailable() || v === null || v === undefined) return null;
        const n = Number(v);
        return Number.isFinite(n) && n > 0 ? n : null;
    },

    // Resolves a pre-bump pinned key ("claude-opus") to the current name ("claude-opus-5").
    _botProResolveKey(key) {
        const k = String(key || '').trim().toLowerCase();
        if (!k) return '';
        const list = this._botProModelList();
        if (list.some(m => m.key === k)) return k;
        const aliases = (this._botProCatalog && this._botProCatalog.aliases) || {};
        if (aliases[k] && list.some(m => m.key === aliases[k])) return aliases[k];
        return '';
    },

    // Cached for 6h in localStorage so the picker opens instantly and works offline.
    async _loadBotProCatalog(force) {
        const TTL = 6 * 60 * 60 * 1000;
        const now = Date.now();
        if (!force && this._botProCatalog && now - this._botProCatalogAt < TTL) return this._botProCatalog;
        if (!force) {
            try {
                const raw = localStorage.getItem('nym_botpm_model_catalog');
                if (raw) {
                    const cached = JSON.parse(raw);
                    if (cached && Array.isArray(cached.models) && cached.models.length) {
                        this._botProCatalog = cached;
                        this._botProCatalogAt = cached.at || 0;
                        if (now - (cached.at || 0) < TTL) return cached;
                    }
                }
            } catch { }
        }
        const apiHost = typeof this._getApiHost === 'function' ? this._getApiHost() : '';
        if (!apiHost) return this._botProCatalog;
        try {
            const resp = await this._edgeFetch(`https://${apiHost}/api/bot`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'models' })
            });
            const data = await resp.json().catch(() => null);
            if (!resp.ok || !data || !Array.isArray(data.models) || !data.models.length) {
                return this._botProCatalog;
            }
            const cat = {
                models: data.models, groups: data.groups || [], aliases: data.aliases || {},
                source: data.source || '', at: now,
                usdPerCredit: data.usdPerCredit, standardUsdPerCredit: data.standardUsdPerCredit,
                priceUnavailable: !!data.priceUnavailable,
                standardRoutes: data.standardRoutes || [], minChargeCredits: data.minChargeCredits,
                metered: !!data.metered
            };
            this._botProCatalog = cat;
            this._botProCatalogAt = now;
            try { localStorage.setItem('nym_botpm_model_catalog', JSON.stringify(cat)); } catch { }
            return cat;
        } catch {
            return this._botProCatalog;
        }
    },

    // Falls back to the flat per-reply price when the catalog has no published rate.
    _replyBalance(data) {
        if (!data) return null;
        if (typeof data.balanceCredits === 'number') return data.balanceCredits;
        return typeof data.balance === 'number' ? data.balance : null;
    },

    _replyCost(data) {
        if (!data) return 0;
        if (typeof data.costCredits === 'number') return data.costCredits;
        return typeof data.cost === 'number' ? data.cost : 0;
    },

    _creditFigure(v) {
        const n = Number(v);
        if (!Number.isFinite(n)) return '…';
        if (Number.isInteger(n)) return String(n);
        if (n > 0 && n < 0.01) return '<0.01';
        return n.toFixed(2).replace(/0+$/, '').replace(/\.$/, '');
    },

    _creditWord(v, word) {
        const n = Number(v);
        const one = Number.isFinite(n) && n === 1;
        return `${this._creditFigure(v)} ${word}${one ? '' : 's'}`;
    },

    _botProTurnCredits(m) {
        const cat = this._botProCatalog;
        const usd = (cat && !cat.priceUnavailable && Number(cat.usdPerCredit)) || 0;
        const pin = Number(m && m.inUsdPerMTok);
        const pout = Number(m && m.outUsdPerMTok);
        if (!(usd > 0) || !(pin > 0) || !(pout > 0)) return null;
        const spend = (NYMBOT_TURN_IN * pin + NYMBOT_TURN_OUT * pout) / 1e6 / usd;
        const floor = Number(cat.minChargeCredits) || 0;
        return spend < floor ? floor : spend;
    },

    _botProPriceLabel(m) {
        const turn = this._botProTurnCredits(m);
        if (turn !== null) {
            const n = this._creditFigure(turn);
            return `~${n} credit${n === '1' ? '' : 's'} a turn · $${m.inUsdPerMTok}/M in, $${m.outUsdPerMTok}/M out`
                + (Number(m.cacheReadUsdPerMTok) > 0 ? `, $${m.cacheReadUsdPerMTok}/M cached` : '');
        }
        if (m && Number(m.inUsdPerMTok) > 0 && Number(m.outUsdPerMTok) > 0) {
            return `$${m.inUsdPerMTok}/M in, $${m.outUsdPerMTok}/M out`
                + (Number(m.cacheReadUsdPerMTok) > 0 ? `, $${m.cacheReadUsdPerMTok}/M cached` : '');
        }
        const base = `${m.credits} Pro credit${m.credits === 1 ? '' : 's'}`;
        return m.max > m.credits ? `from ${base}, up to ${m.max} for max-length replies` : `${base}/reply`;
    },

    _getBotProModel() {
        try {
            const key = localStorage.getItem('nym_botpm_pro_model') || '';
            if (!key) return null;
            const list = this._botProModelList();
            return list.find(m => m.key === key)
                || list.find(m => m.key === this._botProResolveKey(key))
                || null;
        } catch { return null; }
    },

    _setBotProModel(key) {
        try {
            if (key) localStorage.setItem('nym_botpm_pro_model', key);
            else localStorage.removeItem('nym_botpm_pro_model');
        } catch { }
        this._renderBotCreditMeta();
    },

    _handleBotModelCommand(trimmed) {
        const arg = trimmed.replace(/^\?model\b/i, '').trim().toLowerCase();
        const current = this._getBotProModel();
        const plural = n => n === 1 ? '' : 's';
        if (!arg) {
            this._loadBotProCatalog();
            const all = this._botProModelList();
            // List at most a provider's worth; the rest go to the picker.
            const groups = this._botProGroups();
            const lines = groups.length > 1
                ? groups.map(g => {
                    const names = g.keys.slice(0, 6).map(k => `<code>${k}</code>`).join(', ');
                    const more = g.keys.length > 6 ? ` +${g.keys.length - 6} more` : '';
                    return `• <strong>${this.escapeHtml(g.author || 'Other')}</strong> — ${names}${more}`;
                }).concat([`<em>${all.length} models available. Tap the model button for the full list with prices.</em>`])
                : all.map(m =>
                    `• <code>${m.key}</code>${current && current.key === m.key ? ' ✓' : ''} — ${this.escapeHtml(m.label)}, ${this._botProPriceLabel(m)}`);
            this._displayBotInfoMessage([
                current
                    ? `Nymbot Pro model: <strong>${this.escapeHtml(current.label)}</strong> (${this._botProPriceLabel(current)}).`
                    : 'Nymbot Pro is off — replies use standard multi-model routing and standard credits.',
                ...lines,
                'Short replies cost the base price; long replies scale with length. The maximum is reserved from your balance per message and only the actual cost is charged.',
                'Use <code>?model &lt;name&gt;</code> to select one, or <code>?model off</code> for standard routing. Pro credits: <code>?buy</code> → Pro.'
            ].join('<br>'));
            return;
        }
        if (arg === 'off' || arg === 'standard' || arg === 'none') {
            this._setBotProModel(null);
            this.displaySystemMessage('Nymbot Pro off — back to standard multi-model routing (standard credits).');
            return;
        }
        const resolved = this._botProResolveKey(arg) || arg;
        const picked = this._botProModelList().find(m => m.key === resolved);
        if (!picked) {
            this.displaySystemMessage(`Unknown model "${arg}". Type ?model to see the available Pro models.`);
            return;
        }
        this._setBotProModel(picked.key);
        this.displaySystemMessage(`Nymbot Pro model set to ${picked.label} — every reply now uses it (${this._botProPriceLabel(picked)}). Type ?model off to switch back.`);
    },

    _botCheckSvg() {
        return '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>';
    },

    _showBotControlBar() {
        const bar = document.getElementById('botControlBar');
        if (!bar) return;
        bar.classList.remove('nm-hidden');
        this._refreshBotControlBar();
        this._loadBotProCatalog().then(() => this._refreshBotControlBar()).catch(() => { });
    },

    _hideBotControlBar() {
        const bar = document.getElementById('botControlBar');
        if (bar) bar.classList.add('nm-hidden');
    },

    // Never toggles visibility, so it's safe to call after any state change.
    _refreshBotControlBar() {
        const bar = document.getElementById('botControlBar');
        if (!bar) return;
        const proModel = this._getBotProModel();
        const isPro = !!proModel;
        bar.querySelectorAll('.bot-tier-btn').forEach(btn => {
            const active = (btn.dataset.tier === 'pro') === isPro;
            btn.classList.toggle('active', active);
            btn.setAttribute('aria-selected', active ? 'true' : 'false');
        });
        const modelBtn = document.getElementById('botModelBtn');
        const modelLabel = document.getElementById('botModelBtnLabel');
        if (modelLabel) {
            modelLabel.textContent = proModel ? proModel.label : 'Auto-routed';
            // A pinned model is a brand name and is never localized.
            modelLabel.toggleAttribute('data-no-i18n', !!proModel);
        }
        if (modelBtn) modelBtn.classList.toggle('active', isPro);
        const anonBtn = document.getElementById('botAnonBtn');
        const anonOn = typeof this.botAnonEnabled === 'function' && this.botAnonEnabled();
        if (anonBtn) {
            anonBtn.classList.toggle('active', anonOn);
            anonBtn.title = anonOn
                ? 'Anonymous: Nymbot sees a throwaway key, not your nym'
                : 'Chat from a throwaway key Nymbot cannot link to your nym';
        }
    },

    // Standard drops to multi-model routing; Pro opens the picker (matches the Flutter tabs).
    botSetTier(tier) {
        if (tier === 'pro') {
            this.openBotModelModal();
            return;
        }
        if (this._getBotProModel()) {
            this._setBotProModel(null);
            this.displaySystemMessage('Nymbot Pro off — back to standard multi-model routing (standard credits).');
        }
        this._refreshBotControlBar();
    },

    openBotCreditsModal() {
        this.showBotCreditsModal(null, this._getBotProModel() ? 'pro' : 'standard');
    },

    openBotModelModal() {
        const list = document.getElementById('botModelList');
        const modal = document.getElementById('botModelModal');
        if (!list || !modal) return;
        const search = document.getElementById('botModelSearch');
        if (search) {
            search.value = '';
            if (!search.dataset.bound) {
                search.dataset.bound = '1';
                search.addEventListener('input', () => this._renderBotModelList(search.value));
            }
        }
        this._renderBotModelList('');
        modal.classList.add('active');
        this._loadBotProCatalog(true).then((cat) => {
            if (cat && modal.classList.contains('active')) {
                this._renderBotModelList(search ? search.value : '');
            }
        }).catch(() => { });
    },

    // `filter` matches name, key, provider and blurb.
    _renderBotModelList(filter) {
        const list = document.getElementById('botModelList');
        if (!list) return;
        const q = String(filter || '').trim().toLowerCase();
        const current = this._getBotProModel();
        const check = this._botCheckSvg();
        const byKey = new Map(this._botProModelList().map(m => [m.key, m]));
        const rows = [];

        if (this._botPriceUnavailable()) {
            rows.push('<div class="bot-modal-status warn bot-model-notice">The Bitcoin price can’t be checked right now, so credit estimates are hidden. Paid messages will wait until it’s back.</div>');
        }

        if (!q) {
            rows.push(`<button class="bot-model-row${!current ? ' selected' : ''}" type="button" data-action="botSelectModel" data-model="">
                <span class="bot-model-row-main">
                    <span class="bot-model-row-name">Standard <span class="bot-model-row-tag">auto-routed</span></span>
                    <span class="bot-model-row-desc">Best model per task · 10 sats each (standard credits)</span>
                </span>
                <span class="bot-model-check">${!current ? check : ''}</span>
            </button>`);
        }

        const matches = (m) => !q || [m.key, m.label, m.author, m.description, m.kind === 'chat' ? '' : m.kind]
            .some(v => String(v || '').toLowerCase().includes(q));

        let shown = 0;
        for (const g of this._botProGroups()) {
            const models = g.keys.map(k => byKey.get(k)).filter(m => m && matches(m));
            if (!models.length) continue;
            if (g.author) {
                const marks = window.NymbotBrands;
                const tile = marks && g.authorSlug ? marks.markup(g.authorSlug, 16) : '';
                rows.push(`<div class="bot-model-group" data-no-i18n>${tile}${this.escapeHtml(g.author)}</div>`);
            }
            for (const m of models) {
                shown++;
                const sel = !!(current && current.key === m.key);
                const tags = [];
                if (m.vision) tags.push('vision');
                if (m.reasoning) tags.push('reasoning');
                if (m.tools) tags.push('tools');
                // Cloudflare-hosted weights run on the AI binding with no gateway hop.
                if (m.hosting === 'cloudflare-hosted') tags.push('cloudflare');
                const meta = [this._botProPriceLabel(m)].concat(tags.length ? [tags.join(' · ')] : []).join(' — ');
                rows.push(`<button class="bot-model-row bot-model-row-pro${sel ? ' selected' : ''}" type="button" data-action="botSelectModel" data-model="${this.escapeHtml(m.key)}">
                <span class="bot-model-row-main">
                    <span class="bot-model-row-name" data-no-i18n>${this.escapeHtml(m.label)}</span>
                    ${m.description ? `<span class="bot-model-row-about" data-no-i18n>${this.escapeHtml(m.description)}</span>` : ''}
                    <span class="bot-model-row-desc">${this.escapeHtml(meta)}</span>
                </span>
                <span class="bot-model-check">${sel ? check : ''}</span>
            </button>`);
            }
        }
        shown += this._renderBotGeneratorRows(rows, matches, current);
        if (!shown && q) {
            rows.push(`<div class="bot-model-empty">No model matches “${this.escapeHtml(filter)}”.</div>`);
        }
        list.innerHTML = rows.join('');
    },

    _renderBotGeneratorRows(rows, matches, current) {
        const byKey = new Map(this._botGeneratorList().map(m => [m.key, m]));
        if (!byKey.size) return 0;
        const groups = this._botGeneratorGroups();
        const grouped = new Set(groups.flatMap(g => g.keys));
        const loose = [...byKey.keys()].filter(k => !grouped.has(k));
        const all = loose.length ? groups.concat([{ author: '', authorSlug: '', keys: loose }]) : groups;
        const kindWord = { image: 'image', video: 'video' };
        const out = [];
        let shown = 0;
        for (const g of all) {
            const gens = g.keys.map(k => byKey.get(k)).filter(m => m && matches(m));
            if (!gens.length) continue;
            if (g.author) {
                const marks = window.NymbotBrands;
                const tile = marks && g.authorSlug ? marks.markup(g.authorSlug, 16) : '';
                const kind = kindWord[g.kind] ? ` <span class="bot-model-group-kind">${kindWord[g.kind]}</span>` : '';
                out.push(`<div class="bot-model-group">${tile}<span data-no-i18n>${this.escapeHtml(g.author)}</span>${kind}</div>`);
            }
            for (const m of gens) {
                shown++;
                out.push(this._botGeneratorRowHtml(m, current));
            }
        }
        if (!shown) return 0;
        rows.push('<div class="bot-model-section">Generators</div>');
        rows.push(...out);
        return shown;
    },

    _botGeneratorRowHtml(m, current) {
        const key = this.escapeHtml(m.key);
        const credits = this._botGeneratorCredits(m.credits);
        const price = credits === null ? 'price unavailable' : this._creditWord(credits, 'Pro credit');
        const meta = [price];
        if (m.needsImage) meta.push(m.kind === 'video' ? 'Animates a picture you send' : 'Edits a picture you send');
        const tag = current ? '' : ' <span class="bot-model-row-tag">Needs a Pro model</span>';
        const res = Array.isArray(m.resolutions) ? m.resolutions.filter(r => r && r.res) : [];
        const def = this._botGeneratorDefaultRes(m);
        const chips = m.kind === 'video' && res.length > 1
            ? `<span class="bot-gen-res">${res.map(r => {
                const sel = r.res === def;
                const c = this._botGeneratorCredits(r.credits);
                const label = c === null ? this.escapeHtml(r.res) : `${this.escapeHtml(r.res)} · ${this._creditFigure(c)}`;
                const aria = c === null ? `${r.res}, price unavailable` : `${r.res}, ${this._creditWord(c, 'Pro credit')}`;
                return `<button class="bot-gen-res-chip${sel ? ' selected' : ''}" type="button" data-action="botPickGenerator" data-generator="${key}" data-res="${this.escapeHtml(r.res)}" aria-pressed="${sel ? 'true' : 'false'}" aria-label="${this.escapeHtml(aria)}">${label}</button>`;
            }).join('')}</span>`
            : '';
        return `<div class="bot-model-row bot-gen-row">
                <button class="bot-gen-pick" type="button" data-action="botPickGenerator" data-generator="${key}">
                    <span class="bot-model-row-main">
                        <span class="bot-model-row-name"><span data-no-i18n>${this.escapeHtml(m.label)}</span>${tag}</span>
                        ${m.description ? `<span class="bot-model-row-about" data-no-i18n>${this.escapeHtml(m.description)}</span>` : ''}
                        <span class="bot-model-row-desc">${this.escapeHtml(meta.join(' · '))}</span>
                    </span>
                </button>
                ${chips}
            </div>`;
    },

    _botPickGenerator(key, res) {
        const g = this._botGeneratorList().find(m => m.key === key);
        if (!g) return;
        const base = g.command || `?${g.kind} --model ${String(g.key).split(':').pop()}`;
        const def = this._botGeneratorDefaultRes(g);
        const pick = g.kind === 'video' && res && res !== def ? ` --res ${res}` : '';
        const text = `${base}${pick} `;
        window.closeModal('botModelModal');
        const input = document.getElementById('messageInput');
        if (!input) return;
        input.value = text;
        input.focus();
        input.selectionStart = text.length;
        if (typeof this.autoResizeTextarea === 'function') this.autoResizeTextarea(input);
        if (typeof this.handleInputChange === 'function') this.handleInputChange(text);
    },

    _botSelectModel(key) {
        const prev = this._getBotProModel();
        const picked = key
            ? this._botProModelList().find(m => m.key === (this._botProResolveKey(key) || key))
            : null;
        if (key && !picked) return;
        this._setBotProModel(picked ? picked.key : null);
        if (picked) {
            this.displaySystemMessage(`Nymbot Pro model set to ${picked.label} — every reply now uses it (${this._botProPriceLabel(picked)}). Type ?model off to switch back.`);
        } else if (prev) {
            this.displaySystemMessage('Nymbot Pro off — back to standard multi-model routing (standard credits).');
        }
        this._refreshBotControlBar();
        window.closeModal('botModelModal');
    },

    _setBotCreditDisplay(balance) {
        if (typeof balance === 'number') this._lastBotCredits = balance;
        this._renderBotCreditMeta();
    },

    _setBotProCreditDisplay(balance) {
        if (typeof balance === 'number') this._lastBotProCredits = balance;
        this._renderBotCreditMeta();
    },

    _renderBotCreditMeta() {
        this._refreshBotControlBar();
        const el = document.getElementById('botCreditMeta');
        if (!el) return;
        const proModel = this._getBotProModel();
        const std = this._lastBotCredits;
        const pro = this._lastBotProCredits;
        const anonTag = (typeof this.botAnonEnabled === 'function' && this.botAnonEnabled()) ? 'anonymous · ' : '';
        if (proModel) {
            const proText = typeof pro === 'number' ? this._creditFigure(pro) : '…';
            el.textContent = `${anonTag}${proText} Pro credit${pro === 1 ? '' : 's'} · ${proModel.label}`;
            return;
        }
        if (typeof std !== 'number') return;
        el.textContent = (typeof pro === 'number' && pro > 0)
            ? `${anonTag}${this._creditFigure(std)} standard · ${this._creditFigure(pro)} Pro credits left`
            : `${anonTag}${this._creditWord(std, 'credit')} left`;
    },

    async _refreshBotCreditMeta() {
        this._setBotCreditDisplay();
        const bal = await this._checkBotCredits(false);
        if (bal === null && typeof this._lastBotCredits !== 'number') {
            const el = document.getElementById('botCreditMeta');
            if (el) el.textContent = 'credits unavailable';
        }
    },

    async _handleBotPM(content, wrapId) {
        // Fold a localized leading command back to English before ?command matching.
        const trimmed = this.canonicalizeCommandInput((content || '').trim());
        this._markBotPMReceipts('delivered');
        if (/^\?(help|commands)\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this._displayBotPmHelp();
            return;
        }
        if (/^\?balance\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this._checkBotCredits(true);
            return;
        }
        if (/^\?buy\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this.showBotCreditsModal(null, this._getBotProModel() ? 'pro' : 'standard');
            return;
        }
        if (/^\?model\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this._handleBotModelCommand(trimmed);
            return;
        }
        if (/^\?(git|github)\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this.displaySystemMessage('Repositories are in the Nymbot apps, not in Nymchat. Nothing you typed after ?git was sent. Connect a repository at nymbot.ai.');
            return;
        }
        if (/^\?anon\b/i.test(trimmed)) {
            this._markBotPMReceipts('read');
            this.openBotAnonModal();
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
            const isFresh = /^\s*!\s*\S/.test(content);
            const proModel = this._getBotProModel();
            // The worker keeps the ordered thread server-side; fresh skips history.
            const reqExtra = { eventId: wrapId, fresh: isFresh };
            // Our signed nym-pq announcement lets the worker seal its reply post-quantum without a lookup.
            const anonRouted = typeof this.botAnonReady === 'function' && this.botAnonReady();
            const anonAnnouncement = anonRouted ? this._botAnonAnnouncement() : null;
            if (anonAnnouncement) {
                reqExtra.pqAnnouncement = anonAnnouncement;
            } else if (!anonRouted && this._pqSelfSignedAnnouncement) {
                reqExtra.pqAnnouncement = this._pqSelfSignedAnnouncement;
            }
            const cmdAlias = this.commandAliasHint(content);
            if (cmdAlias) reqExtra.cmdAlias = cmdAlias;
            if (proModel) reqExtra.proModel = proModel.key;
            // `pending`: retry with the same event id to collect the in-flight reply instead of paying for a second.
            let status, data;
            for (let tries = 0; ; tries++) {
                ({ status, data } = await this._botMoneyRequest('pm', reqExtra, { timeout: 180000 }));
                if (!data || !data.pending || tries >= 5) break;
                this._setBotTyping(true);  // keep the "thinking" strip up
                await new Promise(r => setTimeout(r, 3000));
            }
            this._setBotTyping(false);
            this._markBotPMReceipts('read');
            if (data && data.pending) {
                this.displaySystemMessage(data.message ||
                    'Nymbot is still working on that message — its reply will arrive shortly.');
                return;
            }
            if (data && data.noCredits) {
                const msg = data.error
                    || (data.pro
                        ? `You're out of Nymbot Pro credits (${this._creditFigure((data.balanceCredits != null ? data.balanceCredits : data.balance) || 0)} left). Type ?buy and switch to Pro, or ?model off for standard replies.`
                        : `You're out of Nymbot credits (${this._creditFigure(this._replyBalance(data) || 0)} left). Zap Nymbot or type ?buy to purchase more.`);
                this.displaySystemMessage(msg);
                if (this._replyBalance(data) !== null) {
                    if (data.pro) this._setBotProCreditDisplay(this._replyBalance(data));
                    else this._setBotCreditDisplay(this._replyBalance(data));
                }
                if (typeof this.botAnonReady === 'function' && this.botAnonReady()) this.openBotAnonModal();
                else this.showBotCreditsModal(null, data.pro ? 'pro' : 'standard');
                return;
            }
            if (data && data.priceUnavailable) {
                this._showBotPriceRetry(content, wrapId);
                return;
            }
            if (status >= 400 || !data || data.error) {
                this.displaySystemMessage('Nymbot: ' + ((data && data.error) || 'request failed'));
                return;
            }
            if (data.event) {
                this.sendDMToRelays(['EVENT', data.event]);
                this.handleGiftWrapDM(data.event, {});
            }
            // The worker re-fetches its own reply as context on later turns.
            if (data.selfEvent && /^[0-9a-f]{64}$/i.test(data.selfEvent.id || '')) {
                this.sendDMToRelays(['EVENT', data.selfEvent]);
            }
            const replyBalance = this._replyBalance(data);
            if (replyBalance !== null) {
                const replyCost = this._replyCost(data);
                if (data.pro) this._setBotProCreditDisplay(replyBalance);
                else this._setBotCreditDisplay(replyBalance);
                if (data.pro && replyCost) {
                    const sel = this._getBotProModel();
                    if (sel && replyCost > (sel.credits || 1)) {
                        this.displaySystemMessage(`Long reply used ${this._creditFigure(replyCost)} Pro credits. Pro balance: ${this._creditFigure(replyBalance)}.`);
                    }
                } else if (!data.pro && replyCost > 1) {
                    this.displaySystemMessage(`${data.taskType || 'Heavy'} reply used ${this._creditFigure(replyCost)} credits. Balance: ${this._creditFigure(replyBalance)}.`);
                }
                if (data.lowBalance) {
                    this.displaySystemMessage(data.pro
                        ? `Nymbot Pro credits running low: ${this._creditFigure(replyBalance)} left. Type ?buy and switch to Pro to top up.`
                        : `Nymbot credits running low: ${this._creditFigure(replyBalance)} credit${replyBalance === 1 ? '' : 's'} left. Type ?buy to top up.`);
                }
            }
        } catch (e) {
            this._setBotTyping(false);
            this.displaySystemMessage('Nymbot is unavailable right now. Please try again.');
        }
    },

    _showBotPriceRetry(content, wrapId) {
        if (!this._botPriceRetries) this._botPriceRetries = new Map();
        const id = 'bpr-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
        this._botPriceRetries.set(id, { content, wrapId });
        this.displaySystemMessage(
            `Nymbot can’t check the Bitcoin price right now, so it couldn’t price that message. Nothing was charged. <button class="bot-retry-btn" type="button" data-action="botRetryPM" data-retry-id="${id}">Retry</button>`,
            'system', { html: true });
    },

    async _botRetryPM(id) {
        const entry = this._botPriceRetries && this._botPriceRetries.get(id);
        if (!entry) return;
        this._botPriceRetries.delete(id);
        const btn = typeof document.querySelector === 'function'
            ? document.querySelector(`[data-retry-id="${id}"]`)
            : null;
        if (btn) btn.remove();
        await this._handleBotPM(entry.content, entry.wrapId);
    },

    async _checkBotCredits(display) {
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) return null;
            const { status, data } = await this._botMoneyRequest('balance', {});
            if (status >= 400 || !data || data.error) {
                if (display) this.displaySystemMessage('Nymbot: ' + ((data && data.error) || 'could not check balance'));
                return null;
            }
            this._setBotCreditDisplay(
                data.balanceCredits != null ? data.balanceCredits : data.balance);
            const proLeft = data.proBalanceCredits != null ? data.proBalanceCredits : data.proBalance;
            if (typeof proLeft === 'number') this._setBotProCreditDisplay(proLeft);
            if (display) {
                const b = (data.balanceCredits != null ? data.balanceCredits : data.balance) || 0;
                const p = (data.proBalanceCredits != null ? data.proBalanceCredits : data.proBalance) || 0;
                const anon = typeof this.botAnonReady === 'function' && this.botAnonReady();
                this._displayBotInfoMessage((anon ? 'Your anonymous balance: ' : 'Your balance: ') +
                    `<strong>${this._creditFigure(b)}</strong> standard credit${b === 1 ? '' : 's'} · <strong>${this._creditFigure(p)}</strong> Pro credit${p === 1 ? '' : 's'}.` +
                    (anon ? ' Type <code>?anon</code> to move more credits across from your nym.' : '') +
                    (b <= 0 && p <= 0 ? ' Type <code>?buy</code> to purchase more.' : ''));
            }
            return data.balanceCredits != null ? data.balanceCredits : data.balance;
        } catch (e) {
            if (display) this.displaySystemMessage('Could not reach Nymbot to check your balance.');
            return null;
        }
    },

    movePMToTop(pubkey, messageTimestamp) {
        const pmList = document.getElementById('pmList');
        const pmItem = pmList.querySelector(`[data-pubkey="${pubkey}"]`);

        if (pmItem) {
            const ts = messageTimestamp || Date.now();
            const currentTs = parseInt(pmItem.dataset.lastMessageTime || '0');
            const newTs = Math.max(ts, currentTs);
            pmItem.dataset.lastMessageTime = newTs;

            const conversation = this.pmConversations.get(pubkey);
            if (conversation) {
                conversation.lastMessageTime = newTs;
            }

            pmItem.remove();
            this.insertPMInOrder(pmItem, pmList);

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

    // Shared so every caller produces identical markup and no badge is dropped.
    _renderPMHeaderForPubkey(pubkey, displayName) {
        if (!(this.inPMMode && this.currentPM === pubkey)) return;
        const channelEl = document.getElementById('currentChannel');
        if (!channelEl) return;
        const baseNym = this.resolveDisplayNym(pubkey, displayName || '').substring(0, 20);
        const suffix = this.getPubkeySuffix(pubkey);
        const safePk = this._safePubkey(pubkey);
        const flairHtml = this.getFlairForUser(pubkey);
        const friendBadge = this.getFriendBadgeHtml(pubkey);
        const verifiedBadge = this.isVerifiedDeveloper(pubkey)
            ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
            : this.isVerifiedBot(pubkey)
                ? `<span class="verified-badge" title="${this.verifiedBot.title}">✓</span>`
                : '';
        const pmHeaderSig = `${safePk}|${baseNym}|${suffix}|${flairHtml}|${verifiedBadge}|${friendBadge}`;
        if (channelEl.dataset.pmHeaderSig === pmHeaderSig) return;
        const pmAvatarSrc = this.getAvatarUrl(pubkey);
        const lastSeenHtml = typeof this._pmLastSeenHtml === 'function' ? this._pmLastSeenHtml(pubkey) : '';
        const displayNym = `<span class="pm-name-text">${this.escapeHtml(baseNym)}</span><span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${friendBadge}`;
        channelEl.innerHTML = `<span class="pm-header-row">${this._pmHeaderAvatarHtml(pubkey, pmAvatarSrc, safePk)}${displayNym}</span>${lastSeenHtml}`;
        channelEl.dataset.pmHeaderSig = pmHeaderSig;
        // Preserve the header's click-to-open-profile behavior across rebuilds.
        const row = channelEl.querySelector('.pm-header-row');
        if (row) {
            row.classList.add('header-clickable');
            row.onclick = (e) => this.showContextMenu(e, `${baseNym}#${suffix}`, pubkey, null, null, true);
        }
    },

    updatePMNicknameFromProfile(pubkey, profileName) {
        if (!profileName) return;
        const clean = this.parseNymFromDisplay(profileName).substring(0, 20);

        if (this.pmConversations.has(pubkey)) {
            this.pmConversations.get(pubkey).nym = clean;
        }

        // Column view composes its title once, so refresh it after the memory update above.
        if (typeof this._cvRefreshColumnTitles === 'function') {
            this._cvRefreshColumnTitles(pubkey);
        }

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

        const suffix = this.getPubkeySuffix(pubkey);
        const verifiedBadge = this.isVerifiedDeveloper(pubkey)
            ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
            : this.isVerifiedBot(pubkey)
                ? '<span class="verified-badge" title="Nymchat Bot">✓</span>'
                : '';
        const flairHtml = this.getFlairForUser(pubkey);
        const avatarSrc = this.getAvatarUrl(pubkey);
        const userShopItems = this.getUserShopItems(pubkey);
        const friendBadge = this.getFriendBadgeHtml(pubkey);
        const safePk = this._safePubkey(pubkey);
        let supporterBadge = userShopItems?.supporter ? this._supporterBadgeMarkup() : '';
        // Shop data may not be loaded yet; keep an on-screen supporter badge until it confirms.
        if (!userShopItems && safePk &&
            document.querySelector(`.message[data-pubkey="${safePk}"] .author-clickable .supporter-badge`)) {
            supporterBadge = this._supporterBadgeMarkup();
        }
        const authorSig = `${clean}|${suffix}|${flairHtml}|${verifiedBadge}|${supporterBadge}|${friendBadge}`;
        document.querySelectorAll(`.message[data-pubkey="${safePk}"] .message-author`).forEach(el => {
            // Update only the inner span to preserve bubble-time and the click handler.
            const clickable = el.querySelector('.author-clickable');
            const avatarHtml = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy">`;
            if (clickable) {
                if (clickable.dataset.authorSig === authorSig) return;
                clickable.dataset.authorSig = authorSig;
                const existingAvatar = clickable.querySelector('img.avatar-message');
                clickable.innerHTML = `<span class="nym-bracket">&lt;</span>${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${supporterBadge}${friendBadge}`;
                if (existingAvatar) clickable.prepend(existingAvatar);
                else clickable.insertAdjacentHTML('afterbegin', avatarHtml);
                if (typeof this._dedupeAuthorBadges === 'function') this._dedupeAuthorBadges(el);
            } else {
                // Fallback: full rewrite for older messages missing the author-clickable wrapper.
                const bubbleTime = el.querySelector('.bubble-time');
                const bubbleHtml = bubbleTime ? bubbleTime.outerHTML : '';
                const existingAvatar = el.querySelector('img.avatar-message');
                el.innerHTML = `${bubbleHtml}<span class="author-clickable"><span class="nym-bracket">&lt;</span>${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${supporterBadge}${friendBadge}</span><span class="nym-bracket">&gt;</span>`;
                const newClickable = el.querySelector('.author-clickable');
                if (newClickable) {
                    if (existingAvatar) newClickable.prepend(existingAvatar);
                    else newClickable.insertAdjacentHTML('afterbegin', avatarHtml);
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

        this._renderPMHeaderForPubkey(pubkey, clean);

        const notif = document.querySelector(`.notification[data-pubkey="${pubkey}"] .notification-title`);
        if (notif) {
            notif.textContent = `PM from ${clean}#${suffix}`;
        }
    },

    _pmSupportTokenStore() {
        const owner = this.pubkey || '';
        if (this._pmSupportTokenCache && this._pmSupportTokenCache.owner === owner) return this._pmSupportTokenCache.map;
        const map = new Map();
        try {
            const raw = JSON.parse(localStorage.getItem(`nym_pm_support_tokens_${owner}`) || '{}');
            for (const [pk, list] of Object.entries(raw && typeof raw === 'object' ? raw : {})) {
                if (!/^[0-9a-f]{64}$/.test(pk) || !Array.isArray(list)) continue;
                const clean = list.filter(e => e && typeof e.t === 'string' && /^[0-9a-f]{64}$/.test(e.t) && Number.isFinite(e.ts))
                    .slice(0, this.PM_SUPPORT_TOKENS_PER_PEER);
                if (clean.length) map.set(pk, clean);
            }
        } catch (_) { }
        this._pmSupportTokenCache = { owner, map };
        return map;
    },

    PM_SUPPORT_TOKENS_PER_PEER: 4,
    PM_SUPPORT_TOKEN_PEERS: 256,

    pmSupportTokensFor(pubkey) {
        const list = pubkey ? this._pmSupportTokenStore().get(pubkey) : null;
        return list ? list.map(e => e.t) : [];
    },

    pmSupportTokenFor(pubkey) {
        return this.pmSupportTokensFor(pubkey)[0] || null;
    },

    _notePmSupportToken(peerPubkey, rumor) {
        if (!rumor || rumor.kind !== 14 || !Array.isArray(rumor.tags)) return false;
        if (typeof peerPubkey !== 'string' || !/^[0-9a-f]{64}$/.test(peerPubkey)) return false;
        const tag = rumor.tags.find(t => Array.isArray(t) && t[0] === 'nymbot-support' && typeof t[1] === 'string');
        const token = tag ? tag[1].toLowerCase() : '';
        if (!/^[0-9a-f]{64}$/.test(token)) return false;
        const ts = Number.isFinite(rumor.created_at) ? rumor.created_at : 0;
        const map = this._pmSupportTokenStore();
        const prior = map.get(peerPubkey) || [];
        const existing = prior.find(e => e.t === token);
        const next = [{ t: token, ts: Math.max(ts, existing ? existing.ts : 0) }, ...prior.filter(e => e.t !== token)];
        next.sort((a, b) => b.ts - a.ts);
        map.delete(peerPubkey);
        map.set(peerPubkey, next.slice(0, this.PM_SUPPORT_TOKENS_PER_PEER));
        while (map.size > this.PM_SUPPORT_TOKEN_PEERS) map.delete(map.keys().next().value);
        try {
            localStorage.setItem(`nym_pm_support_tokens_${this.pubkey || ''}`, JSON.stringify(Object.fromEntries(map)));
        } catch (_) { }
        if (prior.length === 0) this._refreshPmSupportBadge(peerPubkey);
        return true;
    },

    _pmSupportBadgeHtml(pubkey) {
        return this.pmSupportTokenFor(pubkey) ? '<span class="std-badge pm-support-badge">Nymbot support</span>' : '';
    },

    _refreshPmSupportBadge(pubkey) {
        if (typeof document === 'undefined' || !document.querySelector) return;
        const safePk = this._safePubkey ? this._safePubkey(pubkey) : pubkey;
        const badges = document.querySelector(`.pm-item[data-pubkey="${safePk}"] .channel-badges`);
        if (!badges || badges.querySelector('.pm-support-badge')) return;
        badges.insertAdjacentHTML('afterbegin', this._pmSupportBadgeHtml(pubkey));
    },

    addPMConversation(nym, pubkey, timestamp = Date.now()) {
        let baseNym = this.resolveDisplayNym(pubkey, nym);

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

            const userShopItems = this.getUserShopItems(pubkey);
            const flairHtml = this.getFlairForUser(pubkey);
            const friendBadge = this.getFriendBadgeHtml(pubkey);

            const cleanBaseNym = this.parseNymFromDisplay(baseNym);

            const pmAvatarSrc = this.getAvatarUrl(pubkey);
            const safePk = this._safePubkey(pubkey);
            item.innerHTML = `
<img src="${this.escapeHtml(pmAvatarSrc)}" class="avatar-pm" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy">
<span class="pm-name">${this.escapeHtml(cleanBaseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml} ${verifiedBadge}${friendBadge}</span>
<div class="channel-badges">
${this._pmSupportBadgeHtml(pubkey)}<span class="unread-badge nm-hidden">0</span>
<button class="row-menu-btn" data-action="sidebarRowMenu" aria-label="Conversation menu" title="More" type="button"><svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="12" cy="5" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="12" cy="19" r="1.8"/></svg></button>
</div>
`;
            item.dataset.action = 'openPMItem';
            item.dataset.nym = cleanBaseNym;

            this.insertPMInOrder(item, pmList);

            const convKey = this.getPMConversationKey(pubkey);
            const unread = this.unreadCounts.get(convKey) || 0;
            if (unread > 0) this._renderUnreadBadge(convKey, unread);

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

            // Unknown contacts fetch immediately; known ones go through the throttled refresh.
            if (!this.users.has(pubkey) || /^nym$/i.test(cleanBaseNym)) {
                this.requestUserProfile(pubkey);
            } else if (typeof this.refreshUserProfileThrottled === 'function') {
                this.refreshUserProfileThrottled(pubkey);
            }

            // The critical subscription's kind 0 filter covers PM contacts, so rebuild it (debounced) for new ones.
            if (typeof this._scheduleCriticalResubscribe === 'function') {
                this._scheduleCriticalResubscribe();
            }
        } else {
            const cached = this.pmConversations.get(pubkey);
            if (cached && cached.nym !== baseNym) {
                this.updatePMNicknameFromProfile(pubkey, baseNym);
            }
            // No ongoing subscription covers this contact's profile updates.
            if (typeof this.refreshUserProfileThrottled === 'function') {
                this.refreshUserProfileThrottled(pubkey);
            }
        }
    },

    insertPMInOrder(newItem, pmList) {
        this._clearSidebarSkel('pmList');
        const newTime = parseInt(newItem.dataset.lastMessageTime);
        const existingItems = Array.from(pmList.querySelectorAll('.pm-item'));
        const viewMoreBtn = pmList.querySelector('.view-more-btn');

        let insertBefore = null;
        for (const item of existingItems) {
            const itemTime = parseInt(item.dataset.lastMessageTime || '0');
            if (newTime > itemTime) {
                insertBefore = item;
                break;
            }
        }

        if (insertBefore) {
            pmList.insertBefore(newItem, insertBefore);
        } else if (viewMoreBtn) {
            pmList.insertBefore(newItem, viewMoreBtn);
        } else {
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

        const item = document.getElementById('pmList')?.querySelector(`.pm-item[data-pubkey="${pubkey}"]`);
        if (item) item.remove();

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
        const item = document.getElementById('pmList')?.querySelector(`.pm-item[data-pubkey="${pubkey}"]`);
        if (item) item.remove();
        if (this.inPMMode && this.currentPM === pubkey) {
            this.switchChannel('nymchat', 'nymchat');
        }
        this.displaySystemMessage('PM conversation deleted');
    },

    _renderPMHeader(nym, pubkey) {
        const baseNym = this.resolveDisplayNym(pubkey, nym);
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

        const _pmHeaderEl = document.getElementById('currentChannel');
        _pmHeaderEl.innerHTML = pmHeaderHtml;
        _pmHeaderEl.dataset.pmHeaderSig = `${safePk}|${baseNym}|${suffix}|${flairHtml}|${verifiedBadge}|${friendBadge}`;
        delete _pmHeaderEl.dataset.groupHeaderSig;

        const _pmHeaderRow = _pmHeaderEl.querySelector('.pm-header-row');
        if (_pmHeaderRow) {
            _pmHeaderRow.classList.add('header-clickable');
            _pmHeaderRow.onclick = (e) => this.showContextMenu(e, `${baseNym}#${suffix}`, pubkey, null, null, true);
        }
        const lockSvgPM = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="nm-pms-2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>';
        if (this.isVerifiedBot(pubkey)) {
            document.getElementById('channelMeta').innerHTML =
                `${lockSvgPM}E2E encrypted · <span id="botCreditMeta">checking credits…</span>`;
            this._showBotControlBar();
            this._refreshBotCreditMeta();
        } else {
            document.getElementById('channelMeta').innerHTML = `${lockSvgPM}End-to-end encrypted private message`;
            this._hideBotControlBar();
        }

        this._ensurePMHeaderTimer();

        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) shareBtn.style.display = 'none';
        const favBtn = document.getElementById('favoriteChannelBtn');
        if (favBtn) favBtn.style.display = 'none';
        if (typeof this._refreshCallButtons === 'function') this._refreshCallButtons();
    },

    openPM(nym, pubkey) {
        // Warm the peer's ML-KEM key; the standing subscription only covers contacts known at connect.
        if (typeof this.ensurePqAnnouncement === 'function') {
            this.ensurePqAnnouncement(pubkey);
        }
        if (this._cvActive) { this._cvOpenConversation({ type: 'pm', pubkey, nym }); return; }
        // In single view a thread belongs to the conversation on screen.
        if (typeof this._closeThreadViewOnSwitch === 'function') this._closeThreadViewOnSwitch();
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

        if (window.innerWidth <= 1024) {
            this.closeSidebar();
        }

        if (typeof this.refreshUserProfileThrottled === 'function') {
            this.refreshUserProfileThrottled(pubkey);
        }


        this._pushNavigation({ type: 'pm', nym, pubkey });

        this.renderTypingIndicator();

        this._renderPMHeader(nym, pubkey);

        document.querySelectorAll('.channel-item').forEach(item => {
            item.classList.remove('active');
        });
        document.querySelectorAll('.pm-item').forEach(item => {
            item.classList.toggle('active', item.dataset.pubkey === pubkey);
        });

        const conversationKey = this.getPMConversationKey(pubkey);
        this.clearUnreadCount(conversationKey);

        this.loadPMMessages(conversationKey);

        // Gate on ids stored with the message; bitchatUsers/nymUsers are empty for cache-hydrated messages.
        const pmMsgs = this.pmMessages.get(conversationKey) || [];
        for (const msg of pmMsgs) {
            if (msg.isOwn || msg.readReceiptSent) continue;
            let sent = false;
            if (msg.bitchatMessageId && (this.bitchatUsers.has(msg.pubkey) || !msg.nymMessageId)) {
                this.sendBitchatReceipt(msg.bitchatMessageId, 0x02, msg.pubkey);
                sent = true;
            }
            if (msg.nymMessageId) {
                this.sendNymReceipt(msg.nymMessageId, 'read', msg.pubkey);
                sent = true;
            }
            if (sent) msg.readReceiptSent = true;
        }
        this.recordOwnActivity();

        this._restoreDraftForContext();

        this.hideAutocomplete();
        this.hideChannelAutocomplete();
        this.hideEmojiAutocomplete();
        this._focusMessageInput();
    },

    loadPMMessages(conversationKey, skipBotWelcome = false) {
        const container = document.getElementById('messagesContainer');

        if (container.dataset.lastChannel === conversationKey) {
            const storedCount = (this.pmMessages.get(conversationKey) || []).length;
            const domCount = container.querySelectorAll('.message[data-message-id]').length;
            if (storedCount === 0 || domCount > 0) {
                return;
            }
            // Messages exist but the DOM is empty; fall through to re-render.
        }

        this._clearMessageSkeleton(container);

        this.cacheCurrentContainerDOM();
        container.dataset.lastChannel = conversationKey;

        // Compare against the filtered set so the cached fragment stays aligned.
        const filteredMessages = this.getFilteredPMMessages(conversationKey);
        const cached = this.channelDOMCache.get(conversationKey);

        if (cached && this._tryRestoreCachedDOM(container, cached, conversationKey, filteredMessages, true)) {
            return;
        }

        this.channelDOMCache.delete(conversationKey);

        if (filteredMessages.length === 0) {
            container.innerHTML = '';
            const isBot = this.isVerifiedBot(this.currentPM);
            const renderEmpty = () => {
                this.displaySystemMessage('Start of private message');
                if (isBot) {
                    // A ?clear-ed chat is empty but not new; don't re-welcome.
                    if (!skipBotWelcome && !this._getBotPmClearedAt()) {
                        this._displayBotWelcomeMessage();
                    }
                    this._checkBotCredits(false);
                }
            };
            // Bots greet immediately; other empty chats shimmer first.
            if (isBot) renderEmpty();
            else this._showMessageSkeleton(container, renderEmpty);
            return;
        }

        this.renderMessagesWithVirtualScroll(container, conversationKey, true, true);
    },

    openUserPM(nym, pubkey) {
        if (pubkey === this.pubkey) {
            this.displaySystemMessage("You can't send private messages to yourself");
            return;
        }

        const baseNym = this.stripPubkeySuffix(nym);

        if (this.closedPMs.has(pubkey)) {
            this.closedPMs.delete(pubkey);
            if (this.closedPMTimes) this.closedPMTimes.delete(pubkey);
            try { localStorage.setItem('nym_closed_pms', JSON.stringify([...this.closedPMs])); } catch { }
            try { localStorage.setItem('nym_closed_pm_times', JSON.stringify(Object.fromEntries(this.closedPMTimes || new Map()))); } catch { }
            this._debouncedNostrSettingsSave();
        }

        this.addPMConversation(baseNym, pubkey);
        this.openPM(baseNym, pubkey);

        const known = this.users.get(pubkey);
        if (!known || /^nym$/i.test(this.parseNymFromDisplay(known.nym))) {
            this.fetchProfileDirect(pubkey);
        }
    },

    filterPMs(searchTerm) {
        const items = document.querySelectorAll('.pm-item');
        const term = searchTerm.toLowerCase();
        const list = document.getElementById('pmList');

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

        const viewMoreBtn = list.querySelector('.view-more-btn');
        if (viewMoreBtn) {
            viewMoreBtn.style.display = term ? 'none' : 'block';
        }
    },

    async sendEditedPM(newContent, originalMessageId, recipientPubkey, originalNymMessageId) {
        try {
            if (!this.connected) throw new Error('Not connected to relay');
            if (this.botAnonSuppressSendTo && this.botAnonSuppressSendTo(recipientPubkey)) {
                this.displaySystemMessage('Editing is off in the anonymous Nymbot chat — an edit would be signed by your real key. Send a new message instead.');
                return false;
            }

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
                // Same rule as the original send; see pqPmPlan (pq.js).
                const plan = this.pqPmPlan(recipientPubkey);
                const recipientKemPk = plan.kemPk;

                if (plan.nym) {
                    const nymWrapped = recipientKemPk
                        ? await this.pqWrapForPeerAsync(plan.pq2, rumor, this.privkey, recipientPubkey, recipientKemPk, expirationTs)
                        : await this.nip59WrapEventAsync(rumor, this.privkey, recipientPubkey, expirationTs);
                    this.sendDMToRelays(['EVENT', nymWrapped]);
                    this._recordGiftWrapId(nymMessageId, nymWrapped.id);
                    this._depositPMEvent(nymWrapped);
                }

                if (recipientPubkey !== this.pubkey) {
                    const selfKemPk = this.pqSelfKeyFor();
                    const selfWrapped = selfKemPk
                        ? await this.pqWrapForPeerAsync(this.pqSelfUsesPq2(), rumor, this.privkey, this.pubkey, selfKemPk, expirationTs)
                        : await this.nip59WrapEventAsync(rumor, this.privkey, this.pubkey, expirationTs);
                    this.sendDMToRelays(['EVENT', selfWrapped]);
                    this._recordGiftWrapId(nymMessageId, selfWrapped.id);
                }
            } else if (this._canSendGiftWraps()) {
                // Extension or NIP-46 remote signer path: seal via signer, wrap locally.
                const NT = window.NostrTools;
                const _useExt = !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent);
                const enc44 = (peer, text) => _useExt ? window.nostr.nip44.encrypt(peer, text) : _nip46Encrypt(peer, text);
                const signEvt = (u) => _useExt ? window.nostr.signEvent(u) : _nip46SignEvent(u);

                // Hybrid on the wrap only (see pqSendCapable); this branch needs its own plan.
                const editPlan = this.pqPmPlan(recipientPubkey);
                const editKemPk = editPlan.kemPk;
                const sealContent = await enc44(recipientPubkey, JSON.stringify(rumor));
                const sealUnsigned = { kind: 13, content: sealContent, created_at: this.randomNow(), tags: [] };
                const seal = await signEvt(sealUnsigned);
                const ephSk = NT.generateSecretKey();
                const ephPk = NT.getPublicKey(ephSk);
                const wrapContent = editKemPk
                    ? (editPlan.pq2
                        ? window.NymCrypto.pq2Encrypt(JSON.stringify(seal), ephSk, recipientPubkey, editKemPk)
                        : window.NymCrypto.pqEncrypt(JSON.stringify(seal), ephSk, recipientPubkey, editKemPk))
                    : NT.nip44.encrypt(JSON.stringify(seal), NT.nip44.getConversationKey(ephSk, recipientPubkey));
                const wrapUnsigned = { kind: 1059, content: wrapContent, created_at: this.randomNow(), tags: [['p', recipientPubkey]], pubkey: ephPk };
                if (expirationTs) wrapUnsigned.tags.push(['expiration', String(expirationTs)]);
                const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);
                this.sendDMToRelays(['EVENT', wrapped]);
                this._depositPMEvent(wrapped);

                // Self-wrap so our own edit is retrievable from relays after reload.
                if (recipientPubkey !== this.pubkey) {
                    try {
                        const selfSealContent = await enc44(this.pubkey, JSON.stringify(rumor));
                        const selfSealUnsigned = { kind: 13, content: selfSealContent, created_at: this.randomNow(), tags: [] };
                        const selfSeal = await signEvt(selfSealUnsigned);
                        const selfEphSk = NT.generateSecretKey();
                        const selfKemPk = typeof this.pqSelfKeyFor === 'function' ? this.pqSelfKeyFor() : null;
                        const selfWrapContent = selfKemPk
                            ? window.NymCrypto.pq2Encrypt(JSON.stringify(selfSeal), selfEphSk, this.pubkey, selfKemPk)
                            : NT.nip44.encrypt(JSON.stringify(selfSeal), NT.nip44.getConversationKey(selfEphSk, this.pubkey));
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

            const conversationKey = this.getPMConversationKey(recipientPubkey);
            const msgs = this.pmMessages.get(conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.nymMessageId === lookupId || m.id === lookupId);
                if (msg) {
                    msg.content = newContent;
                    msg.isEdited = true;
                }
            }

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

        // Hex or npub (`normalizePubkeyInput`, users.js), otherwise a nym to look up.
        const targetInput = this.normalizePubkeyInput(args) || args.trim().replace(/^@/, '');

        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            const targetPubkey = targetInput.toLowerCase();

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't send private messages to yourself");
                return;
            }

            const targetNym = this.getNymFromPubkey(targetPubkey);
            this.openUserPM(targetNym, targetPubkey);
            return;
        }

        let searchNym = targetInput;
        let searchSuffix = null;

        const hashIndex = targetInput.indexOf('#');
        if (hashIndex !== -1) {
            searchNym = targetInput.substring(0, hashIndex);
            searchSuffix = targetInput.substring(hashIndex + 1);
        }

        const matches = [];
        this.users.forEach((user, pubkey) => {
            const baseNym = this.stripPubkeySuffix(user.nym);
            if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                if (searchSuffix) {
                    if (pubkey.endsWith(searchSuffix)) {
                        matches.push({ nym: user.nym, pubkey: pubkey });
                    }
                } else {
                    matches.push({ nym: user.nym, pubkey: pubkey });
                }
            }
        });

        if (matches.length === 0) {
            this.displaySystemMessage(`User ${targetInput} not found`);
            return;
        }

        if (matches.length > 1 && !searchSuffix) {
            const matchList = matches.map(m =>
                `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
            ).join(', ');
            this.displaySystemMessage(`Multiple users found with nym "${this.escapeHtml(searchNym)}": ${matchList}`, 'system', { html: true });
            this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
            return;
        }

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
        if (window.innerWidth <= 1024) this.closeSidebar();
    },

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

    startGroupFromPM(extraPubkey = null) {
        const seeds = [];
        const consider = (pk) => {
            if (!pk || pk === this.pubkey || seeds.includes(pk)) return;
            if (this.isVerifiedBot(pk)) {
                this.displaySystemMessage("Nymbot can only be messaged 1:1, not added to a group chat.");
                return;
            }
            seeds.push(pk);
        };
        if (this.inPMMode && this.currentPM) consider(this.currentPM);
        consider(extraPubkey);
        if (seeds.length === 0) return;
        this.openNewPMModal();
        for (const pk of seeds) {
            this.addNewPMRecipient(pk, this.stripPubkeySuffix(this.getNymFromPubkey(pk)));
        }
        this._updateNewPMModalTitle();
    },

    // Shown only when composing a new group (2+ recipients).
    _toggleNewGroupFields() {
        const groupMode = !this._addMembersGroupId && this._newPMRecipients.length >= 2;
        document.getElementById('pmGroupNameGroup').style.display = groupMode ? 'block' : 'none';
        document.getElementById('newGroupMediaGroup').style.display = groupMode ? 'block' : 'none';
        document.getElementById('newGroupDescGroup').style.display = groupMode ? 'block' : 'none';
        document.getElementById('newGroupAllowInvitesGroup').style.display = groupMode ? 'block' : 'none';
    },

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

    // The uploaded URL is stored until the group is created.
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

    _buildGroupInviteSuggestionItem(invite) {
        const item = document.createElement('div');
        item.className = 'pm-suggestion-item';

        const icon = document.createElement('span');
        icon.className = 'pm-suggestion-avatar group-suggestion-ico';
        icon.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;

        const nameSpan = document.createElement('span');
        nameSpan.className = 'pm-suggestion-nym';
        nameSpan.textContent = this.sanitizeGroupName(invite.n || '') || 'Group';

        const suffixSpan = document.createElement('span');
        suffixSpan.className = 'pm-suggestion-suffix';
        suffixSpan.textContent = 'Join group';

        item.appendChild(icon);
        item.appendChild(nameSpan);
        item.appendChild(suffixSpan);

        item.addEventListener('click', () => {
            closeModal('newPMModal');
            this.requestJoinGroupViaInvite(invite);
        });
        return item;
    },

    onNewPMRecipientInput(value) {
        const suggestions = document.getElementById('pmSuggestions');
        const query = value.trim().replace(/^@/, '').toLowerCase();
        if (!query) {
            this._showRecentlySeenSuggestions('');
            return;
        }

        const invite = this.parseGroupInviteInput(value.trim());
        if (invite) {
            suggestions.textContent = '';
            suggestions.appendChild(this._buildGroupInviteSuggestionItem(invite));
            suggestions.style.display = 'block';
            return;
        }

        const pastedPubkey = this.normalizePubkeyInput(query);
        if (pastedPubkey) {
            const pk = pastedPubkey;
            if (!this._newPMRecipients.some(r => r.pubkey === pk) && pk !== this.pubkey) {
                const renderPubkeySuggestion = () => {
                    const nym = this.stripPubkeySuffix(this.getNymFromPubkey(pk));
                    suggestions.textContent = '';
                    suggestions.appendChild(this._buildPMSuggestionItem(pk, nym));
                    suggestions.style.display = 'block';
                };
                renderPubkeySuggestion();
                if (!this.users.has(pk)) {
                    this.fetchProfileDirect(pk).then(() => {
                        const currentInput = document.getElementById('pmRecipientInput')?.value.trim().replace(/^@/, '').toLowerCase();
                        if (currentInput === pk) renderPubkeySuggestion();
                    }).catch(() => { });
                }
            } else {
                suggestions.style.display = 'none';
            }
            return;
        }

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
        // Nymbot can be messaged 1:1 but never added to a group chat.
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

    getFilteredPMMessages(conversationKey) {
        const pmMessages = this.pmMessages.get(conversationKey) || [];

        // With threads enabled, replies are hidden from the flat view when the root exists locally.
        const _threadsOn = typeof this.threadsEnabled === 'function' && this.threadsEnabled();
        let _threadRoots = null;
        if (_threadsOn) {
            _threadRoots = new Set();
            for (const m of pmMessages) {
                if (!m || m.threadRoot) continue;
                const k = m.nymMessageId || m.id;
                if (k) _threadRoots.add(k);
            }
        }

        return pmMessages.filter(msg => {
            if (_threadsOn && msg.threadRoot && _threadRoots.has(msg.threadRoot)) return false;
            if (this._botThreadForeign(msg, pmMessages)) return false;
            if (this.deletedEventIds.has(msg.id)) return false;
            if (msg.nymMessageId && this.deletedEventIds.has(msg.nymMessageId)) return false;
            if (typeof this._isMessageDeleted === 'function' && this._isMessageDeleted(msg)) return false;
            if (typeof this._consumePendingDeletion === 'function' && this._consumePendingDeletion(msg)) return false;
            const isOwn = msg.pubkey === this.pubkey;
            if (!isOwn && (this.blockedUsers.has(msg.pubkey) || msg.blocked)) return false;
            if (!isOwn && this.hasBlockedKeyword(msg.content, msg.author, msg.pubkey)) return false;
            if (!isOwn && this.isSpamMessage(msg.content)) return false;
            if (msg.conversationKey !== conversationKey) return false;
            // Derive the peer from the conversation key so column view renders every PM column correctly.
            if (!msg.isGroup && msg.pubkey !== this.pubkey && this.getPMConversationKey(msg.pubkey) !== conversationKey) return false;
            return true;
        }).sort((a, b) => this._compareMessages(a, b));
    },

    loadOlderPMMessages(conversationKey) {
        if (this.activeThread) return false;
        const container = this._cvLoadCtx?.container || document.getElementById('messagesContainer');
        const scroller = this._cvLoadCtx?.scroller || this._getMessagesScroller();
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
        if (enabled) {
            if (typeof this.stopGeoRelayKeepAlive === 'function') this.stopGeoRelayKeepAlive();
            if (this.useRelayProxy) {
                if (this._isAnyPoolOpen()) this._poolSendRelayConfig();
            } else {
                const keepRelays = new Set(this.defaultRelays);
                for (const [url, relay] of this.relayPool) {
                    if (!keepRelays.has(url) && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        relay.ws.close();
                        this.relayPool.delete(url);
                    }
                }
                this.currentGeoRelays.clear();
                this.geoRelayConnections.clear();
                this.updateConnectionStatus();
            }
        } else {
            if (this.useRelayProxy) {
                if (this._isAnyPoolOpen()) this._poolSendRelayConfig();
            } else if (!this.settings.lowDataMode) {
                this.geoRelays.forEach((relay, index) => {
                    const relayUrl = relay.url;
                    if (!this.relayPool.has(relayUrl) && this.shouldRetryRelay(relayUrl)) {
                        setTimeout(() => {
                            this.connectToRelayWithTimeout(relayUrl, 'relay', 3000).then(() => {
                                const r = this.relayPool.get(relayUrl);
                                if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                                    this.subscribeToSingleRelay(relayUrl);
                                    this.updateConnectionStatus();
                                }
                            });
                        }, index * 50);
                    }
                });
            }
        }

        const channelsSection = document.querySelector('#channelList')?.closest('.nav-section');
        if (channelsSection) {
            channelsSection.style.display = enabled ? 'none' : '';
        }

        if (enabled) {
            if (this._cvActive && Array.isArray(this._cvColumns)) {
                for (const col of [...this._cvColumns]) {
                    if (col.type === 'channel') this.cvRemoveColumn(col.id);
                }
            }
            this.navigateToLatestPMOrGroup();
        } else {
            const pinned = this.pinnedLandingChannel || { type: 'geohash', geohash: 'nymchat' };
            if (pinned.type === 'geohash' && pinned.geohash) {
                this.switchChannel(pinned.geohash, pinned.geohash);
            } else {
                this.switchChannel('nymchat', 'nymchat');
            }
            this.discoverChannels();
            this.loadJoinedChannelsFromRelays();
        }

        this.updateUserList();
    },

    navigateToLatestPMOrGroup() {
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
