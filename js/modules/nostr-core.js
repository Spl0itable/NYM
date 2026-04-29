// nostr-core.js - Event signing, NIP-44/59 encryption, gift wraps, profile fetch, presence, typing indicators
// Methods are attached to NYM.prototype.

const _RX_REGEX_ESCAPE_NC = /[.*+?^${}()|[\]\\]/g;
const _quoteMentionCache = new Map();
function _getQuoteMentionPattern(author) {
    let pattern = _quoteMentionCache.get(author);
    if (pattern) return pattern;
    pattern = new RegExp(`^@${author.replace(_RX_REGEX_ESCAPE_NC, '\\$&')}\\s*`);
    if (_quoteMentionCache.size >= 256) {
        // Evict oldest insertion
        const firstKey = _quoteMentionCache.keys().next().value;
        _quoteMentionCache.delete(firstKey);
    }
    _quoteMentionCache.set(author, pattern);
    return pattern;
}

Object.assign(NYM.prototype, {

    // NIP-13: Validate proof of work
    validatePow(event, minimumDifficulty = 0) {
        if (minimumDifficulty === 0) return true;

        const pow = NostrTools.nip13.getPow(event.id);

        // Check if event has a nonce tag (optional but recommended)
        const nonceTag = event.tags?.find(t => t[0] === 'nonce');

        return pow >= minimumDifficulty;
    },

    async saveToNostrProfile() {
        if (!this.pubkey) return;

        // Skip kind 0 updates for the verified developer - they have their own profile data
        if (this.isVerifiedDeveloper(this.pubkey)) return;

        try {
            let profileToSave;

            if (typeof isNostrLoggedIn === 'function' && isNostrLoggedIn()) {
                // Nostr-logged-in users: merge changes into their existing profile
                // so we don't lose fields the app doesn't manage (nip05, website, etc.)
                let existing = {};
                try {
                    const cached = this._cachedKind0Profile;
                    if (cached && typeof cached === 'object') {
                        existing = { ...cached };
                    }
                } catch (_) { }

                const bio = this.userBios.get(this.pubkey);
                const avatarUrl = this.userAvatars.get(this.pubkey);
                const bannerUrl = this.userBanners.get(this.pubkey);

                // Overwrite fields the app manages, including clearing them
                if (this.nym) {
                    existing.name = this.nym;
                    existing.display_name = this.nym;
                }
                if (bio !== undefined) existing.about = bio;
                // Sync lightning address — clear from profile when user removes it
                if (this.lightningAddress) {
                    existing.lud16 = this.lightningAddress;
                } else {
                    delete existing.lud16;
                }
                // Sync avatar — clear from profile when user removes it
                if (avatarUrl) {
                    existing.picture = avatarUrl;
                } else if (!localStorage.getItem('nym_avatar_url')) {
                    delete existing.picture;
                }
                // Sync banner — clear from profile when user removes it
                if (bannerUrl) {
                    existing.banner = bannerUrl;
                } else if (!localStorage.getItem('nym_banner_url')) {
                    delete existing.banner;
                }

                profileToSave = existing;
                // Update cached profile so subsequent saves merge against latest state
                this._cachedKind0Profile = { ...profileToSave };
            } else {
                // Ephemeral mode - minimal profile
                const bio = this.userBios.get(this.pubkey) || '';
                profileToSave = {
                    name: this.nym,
                    display_name: this.nym,
                    lud16: this.lightningAddress,
                    about: bio || `Nymchat user`
                };

                // Include avatar picture if set
                const avatarUrl = this.userAvatars.get(this.pubkey);
                if (avatarUrl) {
                    profileToSave.picture = avatarUrl;
                }

                // Include banner if set
                const bannerUrl = this.userBanners.get(this.pubkey);
                if (bannerUrl) {
                    profileToSave.banner = bannerUrl;
                }
            }

            const jittered = this.randomNow();
            const minTs = (this._lastKind0Ts || 0) + 1;
            const profileTs = Math.max(jittered, minTs);
            this._lastKind0Ts = profileTs;

            const profileEvent = {
                kind: 0,
                created_at: profileTs,
                tags: [],
                content: JSON.stringify(profileToSave),
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(profileEvent);

            if (signedEvent) {
                this.sendToRelay(["EVENT", signedEvent]);
                // Also publish to DM relays so group chat members see updated profiles
                this.sendDMToRelays(["EVENT", signedEvent]);
            }
        } catch (error) {
        }
    },

    async handleEvent(event) {
        // Normalize against malicious or malformed relay payloads up front so downstream
        if (!event || typeof event !== 'object' || typeof event.pubkey !== 'string') return;
        if (!Array.isArray(event.tags)) event.tags = [];
        if (typeof event.created_at !== 'number' || !Number.isFinite(event.created_at)) {
            event.created_at = Math.floor(Date.now() / 1000);
        }

        // Early deduplication for channel messages to prevent re-processing on reconnect
        if (event.kind === 20000) {
            if (this.processedMessageEventIds.has(event.id)) {
                return; // Already processed this message
            }
            this.processedMessageEventIds.add(event.id);

            // Prune if too large (keep last 5000 event IDs)
            if (this.processedMessageEventIds.size > 5000) {
                const idsArray = Array.from(this.processedMessageEventIds);
                this.processedMessageEventIds = new Set(idsArray.slice(-4000));
            }
        }

        const messageAge = Date.now() - (event.created_at * 1000);
        const isHistorical = messageAge > 10000; // Older than 10 seconds

        if (event.pubkey === this.pubkey) {
            // For geohash channel messages (kind 20000)
            if (event.kind === 20000) {
                // Check if message already displayed in DOM
                if (document.querySelector(`[data-message-id="${event.id}"]`)) {
                    return; // Already displayed optimistically, skip
                }
            }

            // For reactions (kind 7)
            if (event.kind === 7) {
                const eTag = event.tags.find(t => t[0] === 'e');
                const actionTag = event.tags.find(t => t[0] === 'action');
                const isRemoval = actionTag && actionTag[1] === 'remove';
                if (eTag && !isRemoval) {
                    const messageId = eTag[1];
                    const emoji = event.content;

                    // Check if we already have this reaction in state
                    if (this.reactions.has(messageId)) {
                        const messageReactions = this.reactions.get(messageId);
                        if (messageReactions.has(emoji) &&
                            messageReactions.get(emoji).has(this.pubkey)) {
                            return; // Already added optimistically, skip
                        }
                    }
                }
                // Removal events always pass through to handleReaction
                // where timestamp-based ordering resolves conflicts
            }
        }


        if (event.kind === 20000) {
            // Validate PoW (NIP-13)
            if (this.enablePow && !this.validatePow(event, this.powDifficulty)) {
                return;
            }

            // Handle geohash channel messages
            const nymTag = event.tags.find(t => t[0] === 'n');
            const geohashTag = event.tags.find(t => t[0] === 'g');

            // Strip any existing #suffix from n tag (bitchat includes it, Nymchat adds its own)
            const rawNym = nymTag ? this.stripPubkeySuffix(nymTag[1]) : null;
            const nym = rawNym || this.getNymFromPubkey(event.pubkey);
            const geohash = geohashTag ? this.sanitizeChannelName(geohashTag[1]) : '';

            // Block impersonation: drop events using reserved nym "nymbot"
            // unless they come from the verified bot pubkey
            if (nym.toLowerCase() === 'nymbot' && !this.isVerifiedBot(event.pubkey)) {
                return;
            }

            // Track discovered geohash for potential batch loading
            if (geohash && !this.discoveredGeohashes.has(geohash)) {
                this.discoveredGeohashes.add(geohash);
            }

            // Check if user is blocked or message/nickname contains blocked keywords
            if (this.isNymBlocked(nym) || this.hasBlockedKeyword(event.content, nym)) {
                return;
            }

            if (this.isSpamMessage(event.content)) {
                return;
            }

            // Check flooding FOR THIS CHANNEL (only for non-historical messages)
            if (!isHistorical && this.isFlooding(event.pubkey, geohash)) {
                return;
            }

            // Only track flood for new messages in this channel
            if (!isHistorical) {
                this.trackMessage(event.pubkey, geohash, isHistorical);
            }

            // Track notification state for this channel
            const channelKey = geohash;
            if (!this.channelNotificationTracking) {
                this.channelNotificationTracking = new Map();
            }
            if (!this.channelNotificationTracking.has(channelKey)) {
                this.channelNotificationTracking.set(channelKey, new Set());
            }
            const alreadyNotified = this.channelNotificationTracking.get(channelKey).has(event.id);

            // Check for BRB auto-response (UNIVERSAL) - only for NEW messages
            if (!isHistorical && this.isMentioned(event.content) && this.awayMessages.has(this.pubkey)) {
                // Check if we haven't already responded to this user in this session
                const responseKey = `brb_universal_${this.pubkey}_${nym}`;
                if (!sessionStorage.getItem(responseKey)) {
                    sessionStorage.setItem(responseKey, '1');

                    // Send auto-response to the same channel where mentioned
                    const response = `@${nym} [Auto-Reply] ${this.awayMessages.get(this.pubkey)}`;
                    await this.publishMessage(response, geohash, geohash);
                }
            }

            // Add channel if it's new (and not blocked)
            if (geohash && !this.channels.has(geohash) && !this.isChannelBlocked(geohash, geohash)) {
                this.addChannelToList(geohash, geohash);
            }

            // Check if this is a P2P file offer
            const offerTag = event.tags.find(t => t[0] === 'offer');
            let fileOffer = null;
            if (offerTag) {
                try {
                    fileOffer = JSON.parse(offerTag[1]);
                    this.p2pFileOffers.set(fileOffer.offerId, fileOffer);
                } catch (e) {
                    console.error('Error parsing file offer:', e);
                }
            }

            // Fetch kind 0 profile for channel message senders we haven't seen
            if (event.pubkey !== this.pubkey) {
                const lastFetch = this.profileFetchedAt.get(event.pubkey) || 0;
                const stale = Date.now() - lastFetch > 5 * 60 * 1000;
                if (!this.userAvatars.has(event.pubkey) || stale) {
                    this.profileFetchedAt.set(event.pubkey, Date.now());
                    this.queueProfileFetch(event.pubkey);
                }
            }

            // Check if this is an edit of a previous message (has 'edit' tag)
            const editTag = event.tags.find(t => t[0] === 'edit');
            if (editTag && editTag[1]) {
                const originalId = editTag[1];
                this.handleIncomingEdit(originalId, event.content, event.pubkey, event.id);
                return;
            }

            const eventCreatedAt = Math.floor(event.created_at) || 0;
            const nowSec = Math.floor(Date.now() / 1000);

            // Guard against clock skew: cap at current time (no future messages)
            let correctedCreatedAt = Math.min(eventCreatedAt, nowSec);

            // Reconstruct quote display from nymquote tag (NYM-specific quote reply)
            // On the wire, quotes are sent as @mention + nymquote tag so other clients
            // see a normal mention; NYM reconstructs the > @author: blockquote format
            let displayContent = event.content;
            const nymquoteTag = event.tags.find(t => t[0] === 'nymquote');
            if (nymquoteTag && nymquoteTag[1] && nymquoteTag[2]) {
                const qAuthor = nymquoteTag[1];
                const qText = nymquoteTag[2];
                // Strip the @author mention prefix from event content to get user's reply
                const mentionPattern = _getQuoteMentionPattern(qAuthor);
                const userMessage = event.content.replace(mentionPattern, '').trim();
                // Reconstruct > @author: blockquote format for NYM display
                // Strip nested quotes — only show the last message being quoted
                const strippedQText = qText.split('\n').filter(line => !line.startsWith('>')).join('\n').replace(/\n{3,}/g, '\n\n').trim();
                const textLines = strippedQText.split('\n');
                const quoteLine = `> @${qAuthor}: ${textLines[0]}` +
                    (textLines.length > 1 ? '\n' + textLines.slice(1).map(line => `> ${line}`).join('\n') : '');
                displayContent = userMessage ? `${quoteLine}\n\n${userMessage}` : quoteLine;
            }

            const message = {
                id: event.id,
                author: nym,
                pubkey: event.pubkey,
                content: displayContent,
                created_at: correctedCreatedAt,
                _originalCreatedAt: eventCreatedAt,
                _seq: ++this._msgSeq,
                timestamp: new Date(correctedCreatedAt * 1000),
                channel: geohash ? geohash : 'unknown',
                geohash: geohash,
                isOwn: event.pubkey === this.pubkey,
                isHistorical: isHistorical,
                isFileOffer: !!fileOffer,
                fileOffer: fileOffer,
                isBot: this.isVerifiedBot(event.pubkey)
            };

            // Don't display duplicate of own messages
            if (!this.isDuplicateMessage(message)) {
                this.displayMessage(message);
                this.updateUserPresence(nym, event.pubkey, message.channel, geohash, event.created_at);

                // Notification check
                const _notifStorageKey = geohash ? `#${geohash}` : message.channel;
                const _notifCurrentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
                const _isViewingChannel = !this.inPMMode && _notifStorageKey === _notifCurrentKey;

                const shouldNotify = !message.isOwn &&
                    this.isMentioned(message.content) &&
                    !this.isNymBlocked(nym) &&
                    !isHistorical &&
                    !alreadyNotified &&
                    (document.hidden || !_isViewingChannel);

                if (shouldNotify) {
                    // Mark as notified
                    this.channelNotificationTracking.get(channelKey).add(event.id);

                    const channelInfo = {
                        type: 'geohash',
                        channel: geohash,
                        geohash: geohash,
                        id: event.id,
                        pubkey: event.pubkey
                    };
                    this.showNotification(nym, message.content, channelInfo);
                }

                // Silently track historical mentions in notification history
                if (isHistorical && !message.isOwn && this.isMentioned(message.content) && !this.isNymBlocked(nym)) {
                    this._addNotificationToHistory(nym, message.content, {
                        type: 'geohash',
                        channel: geohash,
                        geohash: geohash,
                        id: event.id,
                        pubkey: event.pubkey
                    }, message.timestamp.getTime());
                }
            }
        } else if (event.kind === 30078) {
            const dTag = event.tags.find(t => t[0] === 'd');
            if (!dTag) return;

            // Active items broadcast for everyone
            if (dTag[1] === 'nym-shop-active') {
                try {
                    const items = JSON.parse(event.content || '{}');

                    // For our own events, handle specially
                    if (event.pubkey === this.pubkey) {
                        // Check timestamp to ensure we're using the latest
                        const currentTimestamp = this.shopItemsCache.get(event.pubkey)?.eventCreatedAt || 0;

                        if (event.created_at > currentTimestamp) {
                            // This is newer than what we have, update our state
                            this.activeMessageStyle = items.style || null;
                            this.activeFlair = items.flair || null;
                            this.activeCosmetics = new Set(Array.isArray(items.cosmetics) ? items.cosmetics : []);

                            // Cache locally
                            this.localActiveStyle = this.activeMessageStyle;
                            this.localActiveFlair = this.activeFlair;
                            localStorage.setItem('nym_active_style', this.activeMessageStyle || '');
                            localStorage.setItem('nym_active_flair', this.activeFlair || '');

                            // Update cache timestamp
                            this.cacheShopActiveItems(event.pubkey, {
                                style: this.activeMessageStyle,
                                flair: this.activeFlair,
                                supporter: this.userPurchases.has('supporter-badge'),
                                cosmetics: Array.from(this.activeCosmetics || [])
                            }, event.created_at);

                            // Apply to our messages
                            this.applyShopStylesToOwnMessages();

                            // Refresh shop UI if open
                            if (document.getElementById('shopModal').classList.contains('active') && this.activeShopTab) {
                                this.switchShopTab(this.activeShopTab);
                            }
                        }
                        return;
                    }

                    // For other users
                    // Check if we have a cached version with a newer timestamp
                    const cachedData = this.shopItemsCache.get(event.pubkey);
                    if (cachedData && cachedData.eventCreatedAt >= event.created_at) {
                        // We already have newer or same data, skip update to prevent flicker
                        return;
                    }

                    // Normalize cosmetics to array
                    const normalized = {
                        style: items.style || null,
                        flair: items.flair || null,
                        supporter: !!items.supporter,
                        cosmetics: Array.isArray(items.cosmetics) ? items.cosmetics : []
                    };

                    // Update cache and store
                    this.otherUsersShopItems.set(event.pubkey, normalized);
                    this.cacheShopActiveItems(event.pubkey, normalized, event.created_at);

                    // Only update visible messages if this is actually newer data
                    if (!cachedData || cachedData.eventCreatedAt < event.created_at) {
                        const messages = document.querySelectorAll(`.message[data-pubkey="${event.pubkey}"]`);
                        messages.forEach(msg => {
                            // Remove previous styling classes
                            [...msg.classList].forEach(cls => {
                                if (cls.startsWith('style-') || cls.startsWith('cosmetic-') || cls === 'supporter-style') {
                                    msg.classList.remove(cls);
                                }
                            });
                            // Add new style
                            if (normalized.style) msg.classList.add(normalized.style);
                            if (normalized.supporter) msg.classList.add('supporter-style');
                            if (Array.isArray(normalized.cosmetics)) {
                                normalized.cosmetics.forEach(c => {
                                    if (c === 'cosmetic-aura-gold') {
                                        msg.classList.add('cosmetic-aura-gold');
                                    }
                                    if (c === 'cosmetic-redacted') {
                                        const auth = msg.querySelector('.message-author');
                                        if (auth) auth.classList.add('cosmetic-redacted');

                                        // Apply redacted effect to message content after 10 seconds
                                        const contentEl = msg.querySelector('.message-content');
                                        if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                                            setTimeout(() => {
                                                contentEl.classList.add('cosmetic-redacted-message');
                                                contentEl.textContent = '';
                                            }, 10000);
                                        }
                                    }
                                });
                            }

                            // Update flair badge in author element
                            const authorEl = msg.querySelector('.message-author');
                            if (authorEl) {
                                const existingFlair = authorEl.querySelector('.flair-badge');
                                if (existingFlair) existingFlair.remove();
                                if (normalized.flair) {
                                    const flairItem = this.getShopItemById(normalized.flair);
                                    if (flairItem) {
                                        const flairSpan = document.createElement('span');
                                        flairSpan.className = `flair-badge ${normalized.flair}`;
                                        flairSpan.innerHTML = flairItem.icon;
                                        // Insert flair after nym-suffix, before colon/supporter
                                        const suffix = authorEl.querySelector('.nym-suffix');
                                        if (suffix) {
                                            suffix.after(flairSpan);
                                        }
                                    }
                                }

                                // Update supporter badge
                                const existingSupporter = authorEl.querySelector('.supporter-badge');
                                if (existingSupporter) existingSupporter.remove();
                                if (normalized.supporter) {
                                    const badge = document.createElement('span');
                                    badge.className = 'supporter-badge';
                                    badge.innerHTML = '<span class="supporter-badge-icon">\u{1F3C6}</span><span class="supporter-badge-text">Supporter</span>';
                                    // Insert before the colon at the end
                                    authorEl.insertBefore(badge, authorEl.lastChild);
                                }
                            }
                        });
                    }
                } catch (e) {
                }
                return;
            }

            // Our purchase record
            if (dTag[1] === 'nym-shop-purchases' && event.pubkey === this.pubkey) {
                try {
                    const data = JSON.parse(event.content || '{}');

                    // Check timestamp to prevent overwriting with older data
                    // Use shared timestamp tracker so nostrPurchasesLoad and this handler don't race
                    const currentTimestamp = Math.max(this.shopPurchasesTimestamp || 0, this._lastPurchaseSyncTimestamp || 0);
                    if (event.created_at < currentTimestamp) {
                        return;
                    }

                    this.shopPurchasesTimestamp = event.created_at;
                    this._lastPurchaseSyncTimestamp = event.created_at;
                    this.userPurchases.clear();
                    (data.purchases || []).forEach(p => this.userPurchases.set(p.id, p));

                    // Update active items and cache them
                    // Always sync style/flair from relay purchases (handles cross-device sync)
                    this.activeMessageStyle = data.activeStyle || null;
                    this.localActiveStyle = this.activeMessageStyle;
                    localStorage.setItem('nym_active_style', this.activeMessageStyle || '');

                    this.activeFlair = data.activeFlair || null;
                    this.localActiveFlair = this.activeFlair;
                    localStorage.setItem('nym_active_flair', this.activeFlair || '');

                    if (data.activeCosmetics !== undefined) {
                        this.activeCosmetics = new Set(Array.isArray(data.activeCosmetics) ? data.activeCosmetics : []);
                    }

                    if (data.supporterActive !== undefined) {
                        this.supporterBadgeActive = data.supporterActive;
                        localStorage.setItem('nym_supporter_active', this.supporterBadgeActive ? 'true' : 'false');
                    }

                    // Restore recovery codes from relay data to localStorage
                    if (data.recoveryCodes && typeof data.recoveryCodes === 'object') {
                        Object.entries(data.recoveryCodes).forEach(([code, payload]) => {
                            const key = 'nym_shop_recovery_' + code;
                            if (!localStorage.getItem(key)) {
                                try {
                                    localStorage.setItem(key, JSON.stringify(payload));
                                } catch (_) { }
                            }
                        });
                    }

                    // Cache purchases locally for persistence across ephemeral sessions
                    this._cachePurchases();

                    // After loading, broadcast our current active items so others see it
                    this.publishActiveShopItems();

                    // Apply to our messages immediately
                    this.applyShopStylesToOwnMessages();

                    // Refresh shop UI if open
                    if (document.getElementById('shopModal').classList.contains('active') && this.activeShopTab) {
                        this.switchShopTab(this.activeShopTab);
                    }

                } catch (error) {
                }
            }

            // Shop item transfers (from another user to us)
            if (dTag[1]?.startsWith('nym-shop-transfer-') && event.pubkey !== this.pubkey) {
                this.handleShopTransferEvent(event);
            }

            // Settings transfers (from another user to us)
            if (dTag[1]?.startsWith('nym-settings-transfer-') && event.pubkey !== this.pubkey) {
                this.handleSettingsTransferEvent(event);
            }

            // Presence/away status
            const tTag = event.tags?.find(t => t[0] === 't');
            if (tTag && tTag[1] === 'nym-presence') {
                this.handlePresenceEvent(event);
            } else if (tTag && tTag[1] === 'nym-poll') {
                this.handlePollEvent(event);
            } else if (tTag && tTag[1] === 'nym-poll-vote') {
                this.handlePollVoteEvent(event);
            }
        } else if (event.kind === 7) {
            // Handle reactions (NIP-25)
            this.handleReaction(event);
        } else if (event.kind === 5) {
            // Handle deletion events (NIP-09)
            this.handleDeletionEvent(event);
        } else if (event.kind === 9735) {
            // Check if this is a shop zap receipt
            const pTag = event.tags.find(t => t[0] === 'p');
            const descriptionTag = event.tags.find(t => t[0] === 'description');

            if (pTag && pTag[1] === 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df' && this.currentShopInvoice) {
                // This is a zap to the shop
                try {
                    if (descriptionTag) {
                        const zapRequest = JSON.parse(descriptionTag[1]);

                        // Check if this is our shop purchase
                        const shopPurchaseTag = zapRequest.tags?.find(t => t[0] === 'shop-purchase');
                        const shopItemTag = zapRequest.tags?.find(t => t[0] === 'shop-item');

                        if (shopPurchaseTag && shopItemTag &&
                            zapRequest.pubkey === this.pubkey &&
                            shopItemTag[1] === this.currentPurchaseContext?.itemId) {

                            // This is our shop purchase payment!

                            // Close the subscription
                            if (this.shopZapReceiptSubId) {
                                this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
                                this.shopZapReceiptSubId = null;
                            }

                            // Handle successful payment
                            await this.handleShopPaymentSuccess();
                            return;
                        }
                    }
                } catch (e) {
                }
            }

            // Otherwise, handle as normal zap receipt
            this.handleZapReceipt(event);
        } else if (event.kind === 1059) {
            await this.handleGiftWrapDM(event);
        } else if (event.kind === 10000) {
            // Handle mute list of users/keywords
            this.handleMuteList(event);
        } else if (event.kind === 0) {
            // Handle profile events (kind 0) for lightning addresses and avatars
            try {
                const profile = JSON.parse(event.content);
                const pubkey = event.pubkey;

                // Cache the full kind 0 profile for own user so saveToNostrProfile
                // can merge changes without losing fields the app doesn't manage
                if (pubkey === this.pubkey) {
                    this._cachedKind0Profile = profile;
                    if (typeof event.created_at === 'number' && event.created_at > (this._lastKind0Ts || 0)) {
                        this._lastKind0Ts = event.created_at;
                    }
                }

                // Store lightning address if present
                if (profile.lud16 || profile.lud06) {
                    const lnAddress = profile.lud16 || profile.lud06;
                    this.userLightningAddresses.set(pubkey, lnAddress);
                    this.notifyLightningAddress(pubkey, lnAddress);
                }

                // Extract avatar from profile picture field
                if (profile.picture) {
                    const prevUrl = this.userAvatars.get(pubkey);
                    if (prevUrl !== profile.picture) {
                        const oldBlob = this.avatarBlobCache.get(pubkey);
                        if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(pubkey); }
                        this.userAvatars.set(pubkey, profile.picture);
                        this.cacheAvatarImage(pubkey, profile.picture);
                        this.updateRenderedAvatars(pubkey, profile.picture);
                    } else if (!this.avatarBlobCache.has(pubkey)) {
                        this.userAvatars.set(pubkey, profile.picture);
                        this.cacheAvatarImage(pubkey, profile.picture);
                    }
                }

                // Extract banner image
                if (profile.banner) {
                    const prevBanner = this.userBanners.get(pubkey);
                    if (prevBanner !== profile.banner) {
                        const oldBlob = this.bannerBlobCache.get(pubkey);
                        if (oldBlob) { URL.revokeObjectURL(oldBlob); this.bannerBlobCache.delete(pubkey); }
                        this.userBanners.set(pubkey, profile.banner);
                        this.cacheBannerImage(pubkey, profile.banner);
                    } else if (!this.bannerBlobCache.has(pubkey)) {
                        this.userBanners.set(pubkey, profile.banner);
                        this.cacheBannerImage(pubkey, profile.banner);
                    }
                }

                // Extract bio/about
                if (typeof profile.about === 'string') {
                    const bio = profile.about.substring(0, 150);
                    this.userBios.set(pubkey, bio);
                    if (pubkey === this.pubkey) {
                        localStorage.setItem('nym_bio', bio);
                    }
                }

                // Update nym from kind 0 profile — always accept newer profile data
                const profileName = [profile.name, profile.username, profile.display_name]
                    .find(v => typeof v === 'string' && v.length > 0);
                if (profileName) {
                    const truncatedName = profileName.substring(0, 20);
                    const existingUser = this.users.get(pubkey);
                    // Always update: the kind 0 event is the authoritative source
                    // for a user's display name. Previous code only updated when
                    // nym was missing or "anon", causing stale nicknames.
                    if (!existingUser) {
                        this.users.set(pubkey, {
                            nym: truncatedName,
                            pubkey: pubkey,
                            lastSeen: 0,
                            status: 'online',
                            channels: new Set()
                        });
                    } else if (existingUser.nym !== truncatedName) {
                        existingUser.nym = truncatedName;
                        this.users.set(pubkey, existingUser);
                    }
                    // Update PM sidebar and header if this user has a PM conversation
                    if (pubkey !== this.pubkey) {
                        this.updatePMNicknameFromProfile(pubkey, truncatedName);
                    }
                }

                // Resolve any pending fetchProfileDirect calls for this pubkey
                this._resolveProfileCallbacks(pubkey);
            } catch (e) {
                // Ignore profile parse errors
            }
        } else if (event.kind === 3) {
            // Handle follow list (kind:3 contact list) for Nostr login follow suggestions
            this._handleFollowListEvent(event);
        } else if (event.kind === this.P2P_SIGNALING_KIND) {
            // Handle P2P signaling (WebRTC SDP/ICE)
            this.handleP2PSignalingEvent(event);
        } else if (event.kind === this.P2P_FILE_STATUS_KIND) {
            // Handle P2P file status events (unseeded notifications)
            this.handleP2PFileStatusEvent(event);
        }
    },

    isSpamMessage(content) {
        // Check if spam filter is disabled
        if (this.spamFilterEnabled === false) return false;

        // Remove whitespace to check the core content
        const trimmed = content.trim();

        // Allow empty messages or very short ones
        if (trimmed.length < 20) return false;

        // Block client spam
        if (trimmed.includes('joined the channel via bitchat.land')) return true;

        // Block non-nym client messages
        if (trimmed.includes('["client","chorus"]')) return true;

        // Check if it's a URL (contains :// or starts with www.)
        if (trimmed.includes('://') || trimmed.startsWith('www.')) return false;

        // Check for Lightning invoices (lnbc, lntb, lnts prefixes)
        if (/^ln(bc|tb|ts)/i.test(trimmed)) return false;

        // Check for Cashu tokens
        if (/^cashu/i.test(trimmed)) return false;

        // Check for Nostr identifiers (npub/nsec/note/nevent/naddr)
        if (/^(npub|nsec|note|nevent|naddr)1[a-z0-9]+$/i.test(trimmed)) return false;

        // Check for code blocks or formatted content
        if (trimmed.includes('```') || trimmed.includes('`')) return false;

        const words = trimmed.split(/[\s\u3000\u2000-\u200B\u0020\u00A0.,;!?。、，；！？\n]/);
        const longestWord = Math.max(...words.map(w => w.length));

        if (longestWord > 100) {
            if (trimmed.startsWith('data:image')) return false;

            const hasOnlyAlphaNumeric = /^[a-zA-Z0-9]+$/.test(trimmed);
            if (hasOnlyAlphaNumeric && trimmed.length > 100) {
                return true;
            }

            if (/^[a-zA-Z0-9]+$/.test(words.find(w => w.length > 100))) {
                const longWord = words.find(w => w.length > 100);
                const charFreq = {};
                for (const char of longWord) {
                    charFreq[char] = (charFreq[char] || 0) + 1;
                }

                const frequencies = Object.values(charFreq);
                const avgFreq = longWord.length / Object.keys(charFreq).length;
                const variance = frequencies.reduce((sum, freq) => sum + Math.pow(freq - avgFreq, 2), 0) / frequencies.length;

                if (variance < 2 && longWord.length > 100) {
                    return true;
                }
            }
        }

        return false;
    },

    handleMuteList(event) {
        if (event.pubkey !== this.pubkey || event.kind !== 10000) return;

        // Extract blocked users from 'p' tags
        const mutedPubkeys = event.tags
            .filter(tag => tag[0] === 'p' && tag[1])
            .map(tag => tag[1]);

        if (mutedPubkeys.length > 0) {
            // Replace (not merge) with synced blocked users
            this.blockedUsers = new Set(mutedPubkeys);
            this.saveBlockedUsers();
            this.updateBlockedList();
            this.updateUserList();

            // Hide messages from blocked users after mute list loads
            mutedPubkeys.forEach(pubkey => {
                this.hideMessagesFromBlockedUser(pubkey);
            });
        }

        // Extract blocked keywords from 'word' tags
        const mutedWords = event.tags
            .filter(tag => tag[0] === 'word' && tag[1])
            .map(tag => tag[1]);

        if (mutedWords.length > 0) {
            // Replace (not merge) with synced keywords
            this.blockedKeywords = new Set(mutedWords);
            this.saveBlockedKeywords();
            this.updateKeywordList();

            // Hide messages with blocked keywords after mute list loads
            this.hideMessagesWithBlockedKeywords();
        }

        // Re-render current view to retroactively apply blocks to messages
        // that loaded before the mute list synced
        if (mutedPubkeys.length > 0 || mutedWords.length > 0) {
            this.rerenderCurrentView();
        }
    },

    randomNow() {
        // Randomize timestamp by ±2 hours for NIP-59 metadata protection
        // Previously ±2 days, but bitchat only looks back 24 hours for DMs
        // so large offsets caused messages to fall outside its subscription window
        const TWO_HOURS = 2 * 60 * 60;
        return Math.round(Date.now() / 1000 - Math.random() * TWO_HOURS);
    },

    // Generate UUID v4
    generateUUID() {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
            const r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        }).toUpperCase();
    },

    // Encode message in Bitchat's bitchat1: format
    encodeBitchatMessage(content, recipientPubkey = null) {
        const now = Date.now();
        const messageID = this.generateUUID();
        const messageBytes = new TextEncoder().encode(content);
        const messageIDBytes = new TextEncoder().encode(messageID);

        const tlvParts = [];

        // TLV fields use a 1-byte length when value <= 255 bytes. For longer
        // values we set the high bit of the type byte (0x80) to signal that
        // a 2-byte big-endian length follows. Without this, message content
        // over 255 bytes silently truncates because the length wraps mod 256.
        const pushTlvField = (type, valueBytes) => {
            if (valueBytes.length <= 0xFF) {
                tlvParts.push(type);
                tlvParts.push(valueBytes.length);
            } else {
                tlvParts.push(type | 0x80);
                tlvParts.push((valueBytes.length >> 8) & 0xFF);
                tlvParts.push(valueBytes.length & 0xFF);
            }
            for (const b of valueBytes) tlvParts.push(b);
        };

        // MESSAGE_ID field (type 0x00)
        pushTlvField(0x00, messageIDBytes);

        // CONTENT field (type 0x01)
        pushTlvField(0x01, messageBytes);

        const noisePayload = [];
        noisePayload.push(0x01); // PRIVATE_MESSAGE
        for (const b of tlvParts) noisePayload.push(b);

        const parts = [];

        // Header bytes 0-2
        parts.push(0x01); // version 1
        parts.push(0x11); // type = NOISE_ENCRYPTED
        parts.push(0x07); // TTL 7

        // Timestamp bytes 3-10 (8 bytes, big endian milliseconds)
        const ts = BigInt(now);
        for (let i = 7; i >= 0; i--) {
            parts.push(Number((ts >> BigInt(i * 8)) & 0xFFn));
        }

        // Flags byte 11
        // 0x01 = HAS_RECIPIENT, 0x02 = HAS_SIGNATURE, 0x04 = IS_COMPRESSED
        const hasRecipient = !!recipientPubkey;
        const flags = hasRecipient ? 0x01 : 0x00;
        parts.push(flags);

        // Payload length bytes 12-13 (2 bytes, big-endian)
        const payloadLen = noisePayload.length;
        parts.push((payloadLen >> 8) & 0xFF);
        parts.push(payloadLen & 0xFF);

        // Sender ID bytes 14-21 (first 8 bytes of our pubkey)
        for (let i = 0; i < 8; i++) {
            parts.push(parseInt(this.pubkey.substring(i * 2, i * 2 + 2), 16));
        }

        // Recipient ID bytes 22-29 (if HAS_RECIPIENT flag set)
        if (hasRecipient) {
            for (let i = 0; i < 8; i++) {
                parts.push(parseInt(recipientPubkey.substring(i * 2, i * 2 + 2), 16));
            }
        }

        // Payload (NoisePayload)
        for (const b of noisePayload) parts.push(b);

        // Pad to next block size (256, 512, 1024, 2048) with 0xBE
        const blockSizes = [256, 512, 1024, 2048];
        let targetSize = blockSizes.find(s => s >= parts.length) || 2048;
        while (parts.length < targetSize) {
            parts.push(0xBE);
        }

        // Convert to base64url
        const bytes = new Uint8Array(parts);
        const base64 = btoa(String.fromCharCode(...bytes));
        const base64url = base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

        return { content: 'bitchat1:' + base64url, messageId: messageID };
    },

    // Encode a Bitchat receipt (DELIVERED=0x03 or READ_RECEIPT=0x02)
    encodeBitchatReceipt(messageId, receiptType, recipientPubkey) {
        const messageIdBytes = new TextEncoder().encode(messageId);

        // NoisePayload for receipts: [type][raw messageId] (no TLV wrapper!)
        // Bitchat sends receipts with just the UUID string directly
        const noisePayload = [];
        noisePayload.push(receiptType); // 0x02=READ_RECEIPT, 0x03=DELIVERED
        for (const b of messageIdBytes) noisePayload.push(b);

        // BitchatPacket header
        const parts = [];
        const now = Date.now();

        parts.push(0x01); // version
        parts.push(0x11); // type = NOISE_ENCRYPTED
        parts.push(0x07); // TTL

        // Timestamp (8 bytes big-endian)
        const ts = BigInt(now);
        for (let i = 7; i >= 0; i--) {
            parts.push(Number((ts >> BigInt(i * 8)) & 0xFFn));
        }

        // Flags (include recipient)
        parts.push(0x01); // HAS_RECIPIENT

        // Payload length
        const payloadLen = noisePayload.length;
        parts.push((payloadLen >> 8) & 0xFF);
        parts.push(payloadLen & 0xFF);

        // Sender ID (first 8 bytes of our pubkey)
        for (let i = 0; i < 8; i++) {
            parts.push(parseInt(this.pubkey.substring(i * 2, i * 2 + 2), 16));
        }

        // Recipient ID
        for (let i = 0; i < 8; i++) {
            parts.push(parseInt(recipientPubkey.substring(i * 2, i * 2 + 2), 16));
        }

        // Payload
        for (const b of noisePayload) parts.push(b);

        // Pad to block size
        const blockSizes = [256, 512, 1024, 2048];
        let targetSize = blockSizes.find(s => s >= parts.length) || 2048;
        while (parts.length < targetSize) {
            parts.push(0xBE);
        }

        const bytes = new Uint8Array(parts);
        const base64 = btoa(String.fromCharCode(...bytes));
        const base64url = base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

        return 'bitchat1:' + base64url;
    },

    // Send a receipt (DELIVERED or READ) back to a Bitchat user
    // receiptType: 0x02 = READ_RECEIPT, 0x03 = DELIVERED
    async sendBitchatReceipt(messageId, receiptType, recipientPubkey) {
        if (!this.privkey || !this.bitchatUsers.has(recipientPubkey)) return;

        // Skip READ receipts (0x02) if user has disabled them in settings
        if (receiptType === 0x02 && this.settings?.readReceiptsEnabled === false) {
            return;
        }

        const receiptContent = this.encodeBitchatReceipt(messageId, receiptType, recipientPubkey);

        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            kind: 14,
            created_at: now,
            tags: [],
            content: receiptContent,
            pubkey: this.pubkey
        };

        const wrapped = this.bitchatWrapEvent(rumor, this.privkey, recipientPubkey, null);
        this.sendDMToRelays(['EVENT', wrapped]);
    },

    // Nymchat receipt types: 'delivered' or 'read'
    // Uses NIP-17 gift wrap with a special rumor format for receipts
    // Format: rumor with kind 69420 (custom), content empty, tags include ['x', messageId] and ['receipt', type]
    // Using kind 69420 instead of 14 to avoid showing blank DMs in other NIP-17 clients
    async sendNymReceipt(messageId, receiptType, recipientPubkey) {
        if (!this._canSendGiftWraps()) return;

        // Skip READ receipts if user has disabled them in settings
        if (receiptType === 'read' && this.settings?.readReceiptsEnabled === false) {
            return;
        }

        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            kind: 69420,
            created_at: now,
            tags: [
                ['p', recipientPubkey],
                ['x', messageId],  // Reference to original message
                ['receipt', receiptType]  // 'delivered' or 'read'
            ],
            content: '',  // Empty content for receipts
            pubkey: this.pubkey
        };

        // Wrap using standard NIP-59 format
        if (this.privkey) {
            const wrapped = this.nip59WrapEvent(rumor, this.privkey, recipientPubkey, null);
            this.sendDMToRelays(['EVENT', wrapped]);
        } else {
            await this._sendGiftWrapsAsync([recipientPubkey], rumor, null);
        }
    },

    // Check if a rumor is a typing indicator
    isTypingIndicator(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'typing');
    },

    // Parse typing indicator rumor
    parseTypingIndicator(rumor) {
        if (!rumor || !rumor.tags) return null;
        let status = null;
        let groupId = null;
        for (const tag of rumor.tags) {
            if (Array.isArray(tag)) {
                if (tag[0] === 'typing') status = tag[1]; // 'start' or 'stop'
                if (tag[0] === 'g') groupId = tag[1];
            }
        }

        return status ? { status, groupId, pubkey: rumor.pubkey } : null;
    },

    // Called when input changes in PM/group mode to signal typing
    handleTypingSignal() {
        if (!this._canSendGiftWraps() || !this.inPMMode) return;
        if (this.settings?.typingIndicatorsEnabled === false) return;

        const now = Date.now();
        if (now - this._typingThrottleTime < this._typingSendInterval) return;
        this._typingThrottleTime = now;

        // Clear previous stop timer
        if (this._typingStopTimer) clearTimeout(this._typingStopTimer);

        // Send start
        this._sendTypingEvent('start');

        // Auto-send stop after 4s of no further typing
        this._typingStopTimer = setTimeout(() => {
            this._sendTypingEvent('stop');
        }, 4000);
    },

    // Send typing stop immediately (e.g. when message is sent)
    sendTypingStop() {
        if (!this._canSendGiftWraps() || !this.inPMMode) return;
        if (this.settings?.typingIndicatorsEnabled === false) return;
        if (this._typingStopTimer) clearTimeout(this._typingStopTimer);
        this._typingThrottleTime = 0;
        this._sendTypingEvent('stop');
    },

    // Internal: build and send a typing indicator gift-wrap
    async _sendTypingEvent(status) {
        if (!this._canSendGiftWraps()) return;

        const now = Math.floor(Date.now() / 1000);
        const tags = [['typing', status]];

        if (this.currentGroup) {
            const group = this.groupConversations.get(this.currentGroup);
            if (!group) return;
            tags.push(['g', this.currentGroup]);
            const otherMembers = group.members.filter(pk => pk !== this.pubkey);
            if (otherMembers.length === 0) return;

            const rumor = { kind: 69420, created_at: now, tags, content: '', pubkey: this.pubkey };
            await this._sendGiftWrapsAsync(otherMembers, rumor, null);
        } else if (this.currentPM) {
            tags.push(['p', this.currentPM]);
            const rumor = { kind: 69420, created_at: now, tags, content: '', pubkey: this.pubkey };
            if (this.privkey) {
                const wrapped = this.nip59WrapEvent(rumor, this.privkey, this.currentPM, null);
                this.sendDMToRelays(['EVENT', wrapped]);
            } else {
                await this._sendGiftWrapsAsync([this.currentPM], rumor, null);
            }
        }
    },

    // Handle an incoming typing indicator
    handleTypingIndicatorEvent(parsed, senderPubkey) {
        if (!parsed || senderPubkey === this.pubkey) return;

        // Determine the conversation key for this indicator
        let convKey;
        if (parsed.groupId) {
            convKey = this.getGroupConversationKey(parsed.groupId);
        } else {
            convKey = this.getPMConversationKey(senderPubkey);
        }

        if (!this.typingUsers.has(convKey)) {
            this.typingUsers.set(convKey, new Map());
        }
        const convTypers = this.typingUsers.get(convKey);

        if (parsed.status === 'stop') {
            const entry = convTypers.get(senderPubkey);
            if (entry && entry.timeout) clearTimeout(entry.timeout);
            convTypers.delete(senderPubkey);
        } else {
            // 'start' – add or refresh
            const existing = convTypers.get(senderPubkey);
            if (existing && existing.timeout) clearTimeout(existing.timeout);

            const nym = this.getNymFromPubkey(senderPubkey);

            const timeout = setTimeout(() => {
                convTypers.delete(senderPubkey);
                this.renderTypingIndicator();
            }, this._typingExpireMs);

            convTypers.set(senderPubkey, { nym, timeout, timestamp: Date.now() });
        }

        this.renderTypingIndicator();
    },

    // Render the typing indicator UI for the current conversation
    renderTypingIndicator() {
        const el = document.getElementById('typingIndicator');
        const avatarsEl = document.getElementById('typingIndicatorAvatars');
        const textEl = document.getElementById('typingIndicatorText');
        if (!el || !avatarsEl || !textEl) return;

        // Determine current conversation key
        let convKey = null;
        if (this.inPMMode && this.currentGroup) {
            convKey = this.getGroupConversationKey(this.currentGroup);
        } else if (this.inPMMode && this.currentPM) {
            convKey = this.getPMConversationKey(this.currentPM);
        }

        const convTypers = convKey ? this.typingUsers.get(convKey) : null;

        // Prune stale typing indicators (older than expire window)
        if (convTypers) {
            const now = Date.now();
            for (const [pk, entry] of convTypers) {
                if (now - entry.timestamp > this._typingExpireMs) {
                    if (entry.timeout) clearTimeout(entry.timeout);
                    convTypers.delete(pk);
                }
            }
        }

        const typers = convTypers ? Array.from(convTypers.entries()) : [];

        if (typers.length === 0) {
            el.classList.remove('active');
            return;
        }

        // Build avatars
        const avatarHtml = typers.slice(0, 3).map(([pk]) => {
            const sk = this._safePubkey(pk);
            const src = this.getAvatarUrl(pk);
            return `<img src="${this.escapeHtml(src)}" data-avatar-pubkey="${sk}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${sk}.png?set=set1&size=80x80'">`;
        }).join('');
        avatarsEl.innerHTML = avatarHtml;

        // Build text
        if (typers.length === 1) {
            textEl.textContent = `${typers[0][1].nym} is typing`;
        } else if (typers.length === 2) {
            textEl.textContent = `${typers[0][1].nym} and ${typers[1][1].nym} are typing`;
        } else {
            textEl.textContent = `${typers.length} people are typing`;
        }

        el.classList.add('active');
    },

    // Check if a rumor is a Nymchat receipt
    isNymReceipt(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'receipt' && (t[1] === 'delivered' || t[1] === 'read'));
    },

    // Extract receipt info from a Nymchat receipt rumor
    parseNymReceipt(rumor) {
        if (!rumor || !rumor.tags) return null;

        let messageId = null;
        let receiptType = null;

        for (const tag of rumor.tags) {
            if (Array.isArray(tag)) {
                if (tag[0] === 'x' && tag[1]) {
                    messageId = tag[1];
                } else if (tag[0] === 'receipt' && tag[1]) {
                    receiptType = tag[1];
                }
            }
        }

        if (messageId && receiptType) {
            return { messageId, receiptType };
        }
        return null;
    },

    // Check if a rumor is a Nymchat message (has 'x' tag for message ID)
    isNymMessage(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'x' && t[1] && !this.isNymReceipt(rumor));
    },

    // Extract Nymchat message ID from rumor
    getNymMessageId(rumor) {
        if (!rumor || !rumor.tags) return null;
        const xTag = rumor.tags.find(t => Array.isArray(t) && t[0] === 'x' && t[1]);
        return xTag ? xTag[1] : null;
    },

    // Key derivation: HKDF(full compressed shared point 33 bytes, empty salt, "nip44-v2" info)
    encryptBitchat(plaintext, senderPrivateKey, recipientPublicKey) {
        const NT = window.NostrTools;

        // Get full compressed shared point (33 bytes including prefix)
        // Try 02 prefix first - Bitchat will try both prefixes when decrypting
        const sharedPoint = NT._secp256k1.getSharedSecret(senderPrivateKey, '02' + recipientPublicKey);

        // Bitchat key derivation: HKDF with full compressed point, empty salt, "nip44-v2" as info
        const prk = NT._hkdfExtract(NT._sha256, sharedPoint, new Uint8Array(0)); // truly empty salt
        const info = new TextEncoder().encode('nip44-v2');
        const bitchatKey = NT._hkdfExpand(NT._sha256, prk, info, 32);

        // Generate random 24-byte nonce
        const nonce = crypto.getRandomValues(new Uint8Array(24));

        // Encrypt using XChaCha20-Poly1305
        const plaintextBytes = new TextEncoder().encode(plaintext);
        const ciphertextWithTag = NT._xchacha20poly1305(bitchatKey, nonce).encrypt(plaintextBytes);

        // Combine: nonce || ciphertext || tag
        const payload = new Uint8Array(nonce.length + ciphertextWithTag.length);
        payload.set(nonce, 0);
        payload.set(ciphertextWithTag, nonce.length);

        // Encode as base64url with v2: prefix
        const base64 = btoa(String.fromCharCode(...payload));
        const base64url = base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
        return 'v2:' + base64url;
    },

    // Bitchat-compatible gift wrap (uses raw XChaCha20-Poly1305 instead of NIP-44)
    bitchatWrapEvent(event, senderPrivateKey, recipientPublicKey, expirationTs = null) {
        const NT = window.NostrTools;

        // Rumor (unsigned) with computed id
        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            created_at: now,
            content: '',
            tags: [],
            ...event,
            pubkey: NT.getPublicKey(senderPrivateKey)
        };
        rumor.id = NT.getEventHash(rumor);

        // Bitchat decrypts seal using ECDH(recipient_privkey, seal.pubkey)
        const senderPubkey = NT.getPublicKey(senderPrivateKey);
        const sealedContent = this.encryptBitchat(JSON.stringify(rumor), senderPrivateKey, recipientPublicKey);
        const sealUnsigned = {
            kind: 13,
            content: sealedContent,
            created_at: this.randomNow(),
            tags: []
        };
        const seal = NT.finalizeEvent(sealUnsigned, senderPrivateKey);

        // GiftWrap (kind 1059) with different ephemeral keypair
        const wrapEphSk = NT.generateSecretKey();
        const wrapEphPk = NT.getPublicKey(wrapEphSk);
        const wrapContent = this.encryptBitchat(JSON.stringify(seal), wrapEphSk, recipientPublicKey);
        const wrapUnsigned = {
            kind: 1059,
            content: wrapContent,
            created_at: this.randomNow(),
            tags: [['p', recipientPublicKey]],
            pubkey: wrapEphPk
        };

        return NT.finalizeEvent(wrapUnsigned, wrapEphSk);
    },

    nip59WrapEvent(event, senderPrivateKey, recipientPublicKey, expirationTs = null) {
        const NT = window.NostrTools;

        // Rumor (unsigned) with computed id
        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            created_at: now,
            content: '',
            tags: [],
            ...event,
            pubkey: NT.getPublicKey(senderPrivateKey)
        };
        rumor.id = NT.getEventHash(rumor);

        // Seal (kind 13)
        const ckSeal = NT.nip44.getConversationKey(senderPrivateKey, recipientPublicKey);
        const sealedContent = NT.nip44.encrypt(JSON.stringify(rumor), ckSeal);
        const sealUnsigned = {
            kind: 13,
            content: sealedContent,
            created_at: this.randomNow(),
            tags: []
        };
        const seal = NT.finalizeEvent(sealUnsigned, senderPrivateKey);

        // GiftWrap (kind 1059) with ephemeral keypair
        const ephSk = NT.generateSecretKey();
        const ephPk = NT.getPublicKey(ephSk);
        const ckWrap = NT.nip44.getConversationKey(ephSk, recipientPublicKey);
        const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
        const wrapUnsigned = {
            kind: 1059,
            content: wrapContent,
            created_at: this.randomNow(),
            tags: [['p', recipientPublicKey]],
            pubkey: ephPk
        };

        // Add expiration only if enabled
        if (expirationTs) {
            wrapUnsigned.tags.push(['expiration', String(expirationTs)]);
        }

        return NT.finalizeEvent(wrapUnsigned, ephSk);
    },

    requestUserProfile(pubkey) {
        try {
            // Use the batched profile fetching system
            this.fetchProfileFromRelay(pubkey);
        } catch (_) { }
    },

    // Direct profile fetch - sends REQ and resolves when the kind 0 handler
    // processes the response (or after a timeout fallback).
    // Concurrent calls for the same pubkey share a single REQ via an in-flight
    // promise map; subsequent callers attach a resolver instead of re-issuing.
    async fetchProfileDirect(pubkey) {
        if (!this._profileFetchInFlight) this._profileFetchInFlight = new Map();
        const existing = this._profileFetchInFlight.get(pubkey);
        if (existing) {
            await new Promise(resolve => {
                if (!this.pendingProfileResolvers.has(pubkey)) {
                    this.pendingProfileResolvers.set(pubkey, []);
                }
                // No own timer/CLOSE: piggyback on the in-flight request
                this.pendingProfileResolvers.get(pubkey).push({ resolve, timer: null });
                // Safety: still resolve if the in-flight request never completes
                setTimeout(resolve, 4500);
            });
            return;
        }

        const subId = 'pm-profile-' + Math.random().toString(36).slice(2);
        const req = ["REQ", subId, { kinds: [0], authors: [pubkey], limit: 1 }];

        const inflight = (async () => {
            try { this.sendRequestToFewRelays(req); } catch (_) { }

            await new Promise(resolve => {
                const timer = setTimeout(() => {
                    this._removeProfileResolver(pubkey, entry);
                    resolve();
                }, 4000);
                const entry = { resolve, timer };
                if (!this.pendingProfileResolvers.has(pubkey)) {
                    this.pendingProfileResolvers.set(pubkey, []);
                }
                this.pendingProfileResolvers.get(pubkey).push(entry);
            });

            try { this.sendToRelay(["CLOSE", subId]); } catch (_) { }
        })();

        this._profileFetchInFlight.set(pubkey, inflight);
        try {
            await inflight;
        } finally {
            this._profileFetchInFlight.delete(pubkey);
        }
    },

    // Fetch the Nostr kind:3 contact list (follow list) for a pubkey
    // This allows suggesting followed users when composing new messages
    async fetchNostrFollowList(pubkey) {
        if (this._followListFetched) return;
        this._followListFetched = true;

        const subId = 'follow-list-' + Math.random().toString(36).slice(2);
        const req = ["REQ", subId, { kinds: [3], authors: [pubkey], limit: 1 }];

        try { this.sendRequestToFewRelays(req); } catch (_) {
            // Send failed — allow retry on next call
            this._followListFetched = false;
            return;
        }

        // Listen for the response via a one-time handler
        let received = false;
        const handleFollowList = (event) => {
            if (event.kind !== 3 || event.pubkey !== pubkey) return;
            received = true;
            const followPubkeys = (event.tags || [])
                .filter(t => Array.isArray(t) && t[0] === 'p' && typeof t[1] === 'string' && t[1].length === 64)
                .map(t => t[1]);

            this.nostrFollowList = [...new Set(followPubkeys)];

            // Fetch follow-list profiles via the batched queue, which
            // dedupes against fresh-cached profiles and any in-flight REQs.
            const unknownPubkeys = this.nostrFollowList.filter(pk => !this.users.has(pk));
            for (const pk of unknownPubkeys) {
                this.queueProfileFetch(pk);
            }
        };

        // Register a temporary follow list handler
        this._pendingFollowListHandler = handleFollowList;

        // Auto-close subscription after 6 seconds
        setTimeout(() => {
            try { this.sendToRelay(["CLOSE", subId]); } catch (_) { }
            this._pendingFollowListHandler = null;
            // If no response was received, allow retry on next call
            if (!received) {
                this._followListFetched = false;
            }
        }, 6000);
    },

    // Called from event handler when a kind:3 event arrives
    _handleFollowListEvent(event) {
        if (this._pendingFollowListHandler) {
            this._pendingFollowListHandler(event);
            this._pendingFollowListHandler = null;
        }
    },

    // Resolve all pending profile callbacks for a pubkey (called from kind 0 handler)
    _resolveProfileCallbacks(pubkey) {
        const entries = this.pendingProfileResolvers.get(pubkey);
        if (!entries || entries.length === 0) return;
        this.pendingProfileResolvers.delete(pubkey);
        for (const entry of entries) {
            clearTimeout(entry.timer);
            entry.resolve();
        }
    },

    _removeProfileResolver(pubkey, entry) {
        const entries = this.pendingProfileResolvers.get(pubkey);
        if (!entries) return;
        const idx = entries.indexOf(entry);
        if (idx !== -1) entries.splice(idx, 1);
        if (entries.length === 0) this.pendingProfileResolvers.delete(pubkey);
    },

    // Queue a profile fetch that gets batched with others within 150ms.
    // Returns immediately (fire-and-forget). The kind 0 handler updates
    // rendered avatars/names retroactively when responses arrive.
    queueProfileFetch(pubkey) {
        // Skip if we already have a fresh profile or there's an in-flight
        // direct fetch for this pubkey (avoids redundant relay REQs from
        // multiple rendering paths racing on the same author).
        const lastFetch = this.profileFetchedAt && this.profileFetchedAt.get(pubkey) || 0;
        const fresh = Date.now() - lastFetch < 5 * 60 * 1000;
        if (fresh && this.userAvatars && this.userAvatars.has(pubkey)) return;
        if (this._profileFetchInFlight && this._profileFetchInFlight.has(pubkey)) return;

        if (this._profileBatchSet && this._profileBatchSet.has(pubkey)) return;
        if (!this._profileBatchQueue) this._profileBatchQueue = [];
        if (!this._profileBatchSet) this._profileBatchSet = new Set();
        this._profileBatchQueue.push(pubkey);
        this._profileBatchSet.add(pubkey);
        if (this._profileBatchTimer) return;
        this._profileBatchTimer = setTimeout(() => {
            this._flushProfileBatch();
        }, 150);
    },

    _flushProfileBatch() {
        const pubkeys = this._profileBatchQueue;
        this._profileBatchQueue = [];
        this._profileBatchSet = new Set();
        this._profileBatchTimer = null;
        if (pubkeys.length === 0) return;

        const subId = 'batch-profile-' + Math.random().toString(36).slice(2);
        const req = ["REQ", subId, { kinds: [0], authors: pubkeys, limit: pubkeys.length }];
        try { this.sendRequestToFewRelays(req); } catch (_) { }

        // Close subscription after responses arrive or timeout
        setTimeout(() => {
            try { this.sendToRelay(["CLOSE", subId]); } catch (_) { }
        }, 4000);
    },

    async generateKeypair() {
        try {
            // Generate ephemeral keys using nostr-tools bundle functions
            const sk = window.NostrTools.generateSecretKey();
            const pk = window.NostrTools.getPublicKey(sk);

            this.privkey = sk;
            this.pubkey = pk;


            return { privkey: sk, pubkey: pk };
        } catch (error) {
            throw error;
        }
    },

    async signEvent(event) {
        // NIP-07 extension signing (e.g. nos2x, Alby)
        if (this.nostrLoginMethod === 'extension' && window.nostr?.signEvent) {
            // Extension expects an unsigned event object and returns the signed event
            const unsigned = {
                kind: event.kind,
                created_at: event.created_at,
                tags: event.tags,
                content: event.content,
            };
            const signed = await window.nostr.signEvent(unsigned);
            return signed;
        }
        // NIP-46 remote signer
        if (this.nostrLoginMethod === 'nip46' && _nip46State && _nip46State.connected) {
            return await _nip46SignEvent(event);
        }
        if (this.privkey) {
            return window.NostrTools.finalizeEvent(event, this.privkey);
        } else {
            throw new Error('No signing method available');
        }
    },

    async publishDeletionEvent(messageId, originalKind) {
        try {
            const tags = [['e', messageId]];
            // Add k tag per NIP-09 so relays can filter deletes by kind
            if (originalKind) {
                tags.push(['k', String(originalKind)]);
            }
            const event = {
                kind: 5,
                created_at: Math.floor(Date.now() / 1000),
                tags: tags,
                content: '',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(event);
            this.sendToRelay(['EVENT', signedEvent]);

            // Track deleted event ID
            this.deletedEventIds.add(messageId);

            // Remove message from DOM
            const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
            if (messageEl) {
                messageEl.remove();
            }

            // Remove message from stored channel messages
            this.messages.forEach((msgs, channel) => {
                const idx = msgs.findIndex(m => m.id === messageId);
                if (idx !== -1) {
                    msgs.splice(idx, 1);
                }
            });

            // Remove message from stored PM messages
            this.pmMessages.forEach((msgs, convKey) => {
                const idx = msgs.findIndex(m => m.id === messageId);
                if (idx !== -1) {
                    msgs.splice(idx, 1);
                    this.channelDOMCache.delete(convKey);
                }
            });
        } catch (error) {
            this.displaySystemMessage('Failed to delete message: ' + error.message);
        }
    },

    handleDeletionEvent(event) {
        // NIP-09: Deletion events reference messages to delete via 'e' tags
        const eTags = (event.tags || []).filter(t => Array.isArray(t) && t[0] === 'e' && t[1]);
        if (eTags.length === 0) return;

        for (const eTag of eTags) {
            const deletedId = eTag[1];

            // Track deleted event ID to prevent re-displaying
            this.deletedEventIds.add(deletedId);

            // Prune if too large
            if (this.deletedEventIds.size > 5000) {
                const arr = Array.from(this.deletedEventIds);
                this.deletedEventIds = new Set(arr.slice(-4000));
            }

            // Remove from DOM
            const messageEl = document.querySelector(`[data-message-id="${deletedId}"]`);
            if (messageEl) {
                messageEl.remove();
            }

            // Remove from channel messages
            this.messages.forEach((msgs, channel) => {
                const idx = msgs.findIndex(m => m.id === deletedId);
                if (idx !== -1) {
                    msgs.splice(idx, 1);
                }
            });

            // Remove from PM messages
            this.pmMessages.forEach((msgs, convKey) => {
                const idx = msgs.findIndex(m => m.id === deletedId);
                if (idx !== -1) {
                    msgs.splice(idx, 1);
                    this.channelDOMCache.delete(convKey);
                }
            });
        }
    },

    handleIncomingEdit(originalEventId, newContent, senderPubkey, editEventId) {
        // Always store the edit so it can be applied even if the original arrives later
        // (same pattern as deletedEventIds for out-of-order relay delivery)
        const existing = this.editedMessages.get(originalEventId);
        // Only update if this edit is newer (or first edit seen)
        if (!existing || (editEventId && editEventId !== existing.editEventId)) {
            this.editedMessages.set(originalEventId, {
                newContent,
                editEventId,
                senderPubkey,
                timestamp: new Date()
            });
        }

        // Prune if too large
        if (this.editedMessages.size > 5000) {
            const entries = Array.from(this.editedMessages.entries());
            this.editedMessages = new Map(entries.slice(-4000));
        }

        // Try to apply to already-loaded messages
        let found = false;
        this.messages.forEach((msgs) => {
            const msg = msgs.find(m => m.id === originalEventId);
            if (msg && msg.pubkey === senderPubkey) {
                msg.content = newContent;
                msg.isEdited = true;
                found = true;
            }
        });

        if (found) {
            this.updateMessageInDOM(originalEventId, newContent);
        }
    },

    handleIncomingPMEdit(originalId, newContent, senderPubkey, conversationKey) {
        // Always store the edit so it can be applied even if the original arrives later
        const existing = this.editedMessages.get(originalId);
        if (!existing) {
            this.editedMessages.set(originalId, {
                newContent,
                editEventId: null,
                senderPubkey,
                timestamp: new Date()
            });
        }

        // Prune if too large
        if (this.editedMessages.size > 5000) {
            const entries = Array.from(this.editedMessages.entries());
            this.editedMessages = new Map(entries.slice(-4000));
        }

        // Try to apply to already-loaded messages
        const msgs = this.pmMessages.get(conversationKey);
        if (!msgs) return;

        const msg = msgs.find(m =>
            (m.nymMessageId === originalId || m.id === originalId) && m.pubkey === senderPubkey
        );
        if (!msg) return;

        msg.content = newContent;
        msg.isEdited = true;

        const domId = msg.nymMessageId || msg.id;
        this.updateMessageInDOM(domId, newContent);
    },

    processBatchedProfileFetch() {
        if (this.profileFetchQueue.length === 0) return;

        // Get unique pubkeys and their resolvers
        const batch = this.profileFetchQueue;
        this.profileFetchQueue = [];
        this.profileFetchTimer = null;

        const pubkeyMap = new Map();
        batch.forEach(({ pubkey, resolve }) => {
            if (!pubkeyMap.has(pubkey)) {
                pubkeyMap.set(pubkey, []);
            }
            pubkeyMap.get(pubkey).push(resolve);
        });

        const pubkeys = Array.from(pubkeyMap.keys());
        const resolvers = pubkeyMap;

        // Fetch profiles for pubkeys

        const timeout = setTimeout(() => {
            resolvers.forEach(resolveList => {
                resolveList.forEach(resolve => resolve());
            });
        }, 3000);

        const subId = "profile-batch-" + Math.random().toString(36).substring(7);
        const originalHandler = this.handleRelayMessage.bind(this);
        const foundPubkeys = new Set();

        this.handleRelayMessage = (msg) => {
            if (!Array.isArray(msg)) return;

            const [type, ...data] = msg;

            if (type === 'EVENT' && data[0] === subId) {
                const event = data[1];
                if (event && event.kind === 0 && resolvers.has(event.pubkey)) {
                    foundPubkeys.add(event.pubkey);

                    try {
                        const profile = JSON.parse(event.content);


                        // Get name for own profile
                        if (event.pubkey === this.pubkey && (profile.name || profile.username || profile.display_name)) {
                            const profileName = profile.name || profile.username || profile.display_name;
                            this.nym = profileName.substring(0, 20);
                            document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
                            this.updateSidebarAvatar();
                        }

                        // Extract avatar from profile picture field
                        if (profile.picture) {
                            const prevUrl = this.userAvatars.get(event.pubkey);
                            if (prevUrl !== profile.picture) {
                                const oldBlob = this.avatarBlobCache.get(event.pubkey);
                                if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(event.pubkey); }
                                this.userAvatars.set(event.pubkey, profile.picture);
                                this.cacheAvatarImage(event.pubkey, profile.picture);
                                this.updateRenderedAvatars(event.pubkey, profile.picture);
                            } else if (!this.avatarBlobCache.has(event.pubkey)) {
                                this.userAvatars.set(event.pubkey, profile.picture);
                                this.cacheAvatarImage(event.pubkey, profile.picture);
                            }
                        }

                        // Store and update for OTHER users (Bitchat users, PM contacts)
                        if (event.pubkey !== this.pubkey && (profile.name || profile.username || profile.display_name)) {
                            const profileName = (profile.name || profile.username || profile.display_name).substring(0, 20);
                            // Store in users map
                            if (!this.users.has(event.pubkey) || this.users.get(event.pubkey).nym.startsWith('anon')) {
                                this.users.set(event.pubkey, {
                                    nym: profileName,
                                    pubkey: event.pubkey,
                                    lastSeen: 0,
                                    status: 'online',
                                    channels: new Set()
                                });
                            }
                            // Update PM nickname displays
                            this.updatePMNicknameFromProfile(event.pubkey, profileName);
                        }

                        // Get lightning address
                        if (event.pubkey === this.pubkey && (profile.lud16 || profile.lud06)) {
                            const lnAddress = profile.lud16 || profile.lud06;
                            this.lightningAddress = lnAddress;
                            localStorage.setItem(`nym_lightning_address_${this.pubkey}`, lnAddress);
                            this.updateLightningAddressDisplay();
                        }
                    } catch (e) {
                    }

                    // Resolve all promises for this pubkey
                    const resolveList = resolvers.get(event.pubkey);
                    resolveList.forEach(resolve => resolve());
                    resolvers.delete(event.pubkey);
                }
            } else if (type === 'EOSE' && data[0] === subId) {
                clearTimeout(timeout);
                this.handleRelayMessage = originalHandler;

                // Resolve any remaining unfound profiles
                resolvers.forEach(resolveList => {
                    resolveList.forEach(resolve => resolve());
                });
            }

            originalHandler(msg);
        };

        const subscription = [
            "REQ",
            subId,
            {
                kinds: [0],
                authors: pubkeys, // Array of all pubkeys
                limit: pubkeys.length
            }
        ];

        if (this.connected) {
            this.sendRequestToFewRelays(subscription);
            setTimeout(() => {
                this.sendToRelay(["CLOSE", subId]);
            }, 3500);
        } else {
            this.messageQueue.push(JSON.stringify(subscription));
        }
    },

    async publishMessage(content, channel = this.currentChannel, geohash = this.currentGeohash, quoteData = null) {
        try {
            if (!this.connected) {
                throw new Error('Not connected to relay');
            }

            const now = Math.floor(Date.now() / 1000);
            const tags = [
                ['n', this.nym]
            ];

            const kind = 20000; // Geohash channels use kind 20000
            tags.push(['g', geohash || 'nym']);

            // Build wire content: if quoting, use @mention format instead of > blockquote
            // so other Nostr clients see a normal mention, while NYM reconstructs the quote
            let wireContent = content;
            if (quoteData) {
                tags.push(['nymquote', quoteData.author, quoteData.fullText || quoteData.text]);
                // Extract user's reply text (everything after the > quote block)
                const lines = content.split('\n');
                const nonQuoteLines = [];
                let pastQuote = false;
                for (const line of lines) {
                    if (!pastQuote && line.startsWith('>')) continue;
                    if (!pastQuote && line.trim() === '') { pastQuote = true; continue; }
                    pastQuote = true;
                    nonQuoteLines.push(line);
                }
                const userMessage = nonQuoteLines.join('\n').trim();
                wireContent = userMessage ? `@${quoteData.author} ${userMessage}` : `@${quoteData.author}`;
            }

            let event = {
                kind: kind,
                created_at: now,
                tags: tags,
                content: wireContent,
                pubkey: this.pubkey
            };

            // Mine PoW if enabled (NIP-13)
            if (this.enablePow && this.powDifficulty > 0) {
                event = NostrTools.nip13.minePow(event, this.powDifficulty);
            }

            // Sign event (after mining PoW)
            const signedEvent = await this.signEvent(event);

            const optimisticMessage = {
                id: signedEvent.id, // Use the signed event ID
                content: content,
                author: this.nym,
                pubkey: this.pubkey,
                created_at: signedEvent.created_at,
                _seq: ++this._msgSeq,
                timestamp: new Date(signedEvent.created_at * 1000),
                channel: channel,
                geohash: geohash,
                isOwn: true,
                isHistorical: false,
                isPM: false,
            };

            // Display immediately (optimistic)
            this.displayMessage(optimisticMessage);

            // Send to relay (async - UI already updated)
            this.sendToRelay(["EVENT", signedEvent]);

            // Ensure geo relays for this channel also receive the event
            this.ensureGeoRelayDelivery(signedEvent, geohash);

            // Schedule deletion if redacted cosmetic is active
            if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                const eventIdToDelete = signedEvent.id;
                setTimeout(() => {
                    this.publishDeletionEvent(eventIdToDelete);
                }, 600000); // 10 minutes
            }

            return true;
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
            return false;
        }
    },

    async publishMessageAnonymous(content, channel = this.currentChannel, geohash = this.currentGeohash, quoteData = null) {
        try {
            if (!this.connected) {
                throw new Error('Not connected to relay');
            }

            // Generate a fresh ephemeral keypair for this message
            const ephSk = window.NostrTools.generateSecretKey();
            const ephPk = window.NostrTools.getPublicKey(ephSk);

            // Generate a random nym for the ephemeral identity
            const ephSuffix = ephPk.slice(-4);
            const style = localStorage.getItem('nym_nick_style') || 'fancy';
            let anonNym;
            if (style === 'simple') {
                const randomNum = Math.floor(1000 + Math.random() * 9000);
                anonNym = `nym${randomNum}`;
            } else {
                const adjectives = [
                    'quantum', 'neon', 'cyber', 'shadow', 'plasma',
                    'echo', 'nexus', 'void', 'flux', 'ghost',
                    'phantom', 'stealth', 'cryptic', 'dark', 'neural',
                    'binary', 'matrix', 'digital', 'virtual', 'zero',
                    'null', 'anon', 'masked', 'hidden', 'cipher',
                    'enigma', 'spectral', 'rogue', 'omega', 'alpha'
                ];
                const nouns = [
                    'ghost', 'nomad', 'drift', 'pulse', 'wave',
                    'spark', 'node', 'byte', 'mesh', 'link',
                    'runner', 'hacker', 'coder', 'agent', 'proxy',
                    'daemon', 'virus', 'worm', 'bot', 'droid',
                    'reaper', 'shadow', 'wraith', 'specter', 'shade'
                ];
                const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
                const noun = nouns[Math.floor(Math.random() * nouns.length)];
                anonNym = `${adj}_${noun}`;
            }

            const now = Math.floor(Date.now() / 1000);
            const tags = [
                ['n', anonNym]
            ];

            const kind = 20000;
            tags.push(['g', geohash || 'nym']);

            // Build wire content: if quoting, use @mention format instead of > blockquote
            let wireContent = content;
            if (quoteData) {
                tags.push(['nymquote', quoteData.author, quoteData.fullText || quoteData.text]);
                const lines = content.split('\n');
                const nonQuoteLines = [];
                let pastQuote = false;
                for (const line of lines) {
                    if (!pastQuote && line.startsWith('>')) continue;
                    if (!pastQuote && line.trim() === '') { pastQuote = true; continue; }
                    pastQuote = true;
                    nonQuoteLines.push(line);
                }
                const userMessage = nonQuoteLines.join('\n').trim();
                wireContent = userMessage ? `@${quoteData.author} ${userMessage}` : `@${quoteData.author}`;
            }

            let event = {
                kind: kind,
                created_at: now,
                tags: tags,
                content: wireContent,
                pubkey: ephPk
            };

            // Mine PoW if enabled (NIP-13)
            if (this.enablePow && this.powDifficulty > 0) {
                event = NostrTools.nip13.minePow(event, this.powDifficulty);
            }

            // Sign with the ephemeral key (bypasses Nostr login signing)
            const signedEvent = window.NostrTools.finalizeEvent(event, ephSk);

            const optimisticMessage = {
                id: signedEvent.id,
                content: content,
                author: anonNym,
                pubkey: ephPk,
                created_at: signedEvent.created_at,
                _seq: ++this._msgSeq,
                timestamp: new Date(signedEvent.created_at * 1000),
                channel: channel,
                geohash: geohash,
                isOwn: true,
                isHistorical: false,
                isPM: false,
            };

            // Display immediately (optimistic)
            this.displayMessage(optimisticMessage);

            // Send to relay
            this.sendToRelay(["EVENT", signedEvent]);

            // Ensure geo relays for this channel also receive the event
            this.ensureGeoRelayDelivery(signedEvent, geohash);

            return true;
        } catch (error) {
            this.displaySystemMessage('Failed to send anonymous message: ' + error.message);
            return false;
        }
    },

    async publishPresence(status, awayMessage = '') {
        try {
            if (!this.connected) return;

            const tags = [
                ['d', 'nym-presence'],
                ['t', 'nym-presence'],
                ['n', this.nym],
                ['status', status]
            ];
            if (status === 'away' && awayMessage) {
                tags.push(['away', awayMessage]);
            }

            let event = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: tags,
                content: '',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(event);
            this.sendToRelay(["EVENT", signedEvent]);
        } catch (error) {
            // Silently fail - presence is best-effort
        }
    },

    async publishAvatarUpdate(avatarUrl) {
        try {
            if (!this.connected) return;

            const tags = [
                ['d', 'nym-presence'],
                ['t', 'nym-presence'],
                ['n', this.nym],
                ['status', 'online'],
                ['avatar-update', avatarUrl]
            ];

            let event = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: tags,
                content: '',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(event);
            this.sendToRelay(["EVENT", signedEvent]);
        } catch (error) {
            // Silently fail - avatar update broadcast is best-effort
        }
    },

});
