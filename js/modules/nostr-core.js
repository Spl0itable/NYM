// nostr-core.js - Event signing, NIP-44/59 encryption, gift wraps, profile fetch, presence, typing indicators

// Stripped from message text rather than dropping the message, which would hide the surrounding conversation.
const _MALICIOUS_DOMAINS = ['glub.chat'];
// Scheme, subdomains and trailing path optional, so `https://www.glub.chat/x?y` and `glub.chat` match.
const _RX_MALICIOUS_DOMAIN = new RegExp(
    '(?:https?:\\/\\/)?(?:[\\w-]+\\.)*(?:'
    + _MALICIOUS_DOMAINS.map(d => d.replace(/\./g, '\\.')).join('|')
    + ')\\b(?:\\/[^\\s]*)?', 'gi');
const _RX_BLOCKED_CONTENT_BLOB = /^(?:(?:bitchat1|encmedia|enc):[A-Za-z0-9+\/=_-]{24,}|test_\d+_\d+)$/;
const _RX_REGEX_ESCAPE_NC = /[.*+?^${}()|[\]\\]/g;
const _quoteMentionCache = new Map();
function _getQuoteMentionPattern(author) {
    let pattern = _quoteMentionCache.get(author);
    if (pattern) return pattern;
    pattern = new RegExp(`^@${author.replace(_RX_REGEX_ESCAPE_NC, '\\$&')}\\s*`);
    if (_quoteMentionCache.size >= 256) {
        const firstKey = _quoteMentionCache.keys().next().value;
        _quoteMentionCache.delete(firstKey);
    }
    _quoteMentionCache.set(author, pattern);
    return pattern;
}

Object.assign(NYM.prototype, {

    _notifPreviewText(text) {
        const MN = window.NymMediaNotes;
        if (MN && typeof text === 'string' && text.indexOf('#nym:') !== -1) {
            text = MN.previewText(text, (s) => (typeof this.uiText === 'function' ? this.uiText(s) : s));
        }
        if (typeof text === 'string' && text.indexOf('nympoll:') !== -1 && typeof this._dpPreview === 'function') {
            text = this._dpPreview(text);
        }
        const GT = window.NymGroupTools;
        if (GT && typeof text === 'string') {
            const pv = GT.previewText(text);
            text = (pv === 'Location' || pv === 'Live location') && typeof this.uiText === 'function' ? this.uiText(pv) : pv;
        }
        const F = window.NymFormat;
        return F && typeof F.stripForPreview === 'function' ? F.stripForPreview(text) : text;
    },

    // NIP-13 committed difficulty, or null without a nonce tag; achieved zero bits alone don't prove work.
    _powTargetFromEvent(event) {
        const tag = event && Array.isArray(event.tags)
            ? event.tags.find(t => Array.isArray(t) && t[0] === 'nonce')
            : null;
        if (!tag) return null;
        const target = parseInt(tag[2], 10);
        return Number.isFinite(target) && target > 0 ? target : 0;
    },

    // Leading zero bits of an event id (NIP-13).
    powBitsForId(id) {
        if (typeof id !== 'string' || !/^[0-9a-f]{64}$/i.test(id)) return 0;
        try {
            if (window.NostrTools && window.NostrTools.nip13 &&
                typeof window.NostrTools.nip13.getPow === 'function') {
                return window.NostrTools.nip13.getPow(id);
            }
        } catch (_) { /* fall through to the local count */ }
        // Local equivalent, so the popup still works if nostr-tools is absent.
        let bits = 0;
        for (let i = 0; i < id.length; i++) {
            const nibble = parseInt(id[i], 16);
            if (nibble === 0) { bits += 4; continue; }
            bits += Math.clz32(nibble) - 28;
            break;
        }
        return bits;
    },

    // NIP-13: only the committed target counts; no commitment, or an id short of it, scores 0.
    validatedPowBits(event) {
        const tags = Array.isArray(event && event.tags) ? event.tags : [];
        let committed = 0;
        // Last wins, matching the miner: re-mining rewrites the tag in place.
        for (const t of tags) {
            if (Array.isArray(t) && t[0] === 'nonce' && t.length >= 3) {
                const n = parseInt(t[2], 10);
                if (Number.isFinite(n)) committed = n;
            }
        }
        if (!(committed > 0) || committed > 256) return 0;
        let actual;
        try { actual = NostrTools.nip13.getPow(event.id); } catch (_) { return 0; }
        return actual >= committed ? committed : 0;
    },

    // Automatic spam heuristics run only in direct mode (the pool already filters); user choices apply in both.
    _clientGatesActive() {
        return !(this.useRelayProxy && !this._poolFallbackActive);
    },

    validatePow(event, minimumDifficulty = 0) {
        if (minimumDifficulty === 0) return true;
        return this.validatedPowBits(event) >= minimumDifficulty;
    },

    // NIP-13 miner: offloaded to the crypto worker; cooperative main-thread fallback.
    async _minePow(event, difficulty) {
        if (!difficulty || difficulty <= 0) return event;
        return this._cryptoCall('minePow', [event, difficulty], () => this._minePowMainThread(event, difficulty));
    },

    // Hashes for ~4ms, yields to the event loop, then resumes.
    async _minePowMainThread(event, difficulty) {
        if (!difficulty || difficulty <= 0) return event;
        let nonceIdx = event.tags.findIndex(t => Array.isArray(t) && t[0] === 'nonce');
        if (nonceIdx < 0) {
            event.tags.push(['nonce', '0', String(difficulty)]);
            nonceIdx = event.tags.length - 1;
        } else {
            event.tags[nonceIdx] = ['nonce', '0', String(difficulty)];
        }
        let nonce = 0;
        while (true) {
            const start = performance.now();
            while (performance.now() - start < 4) {
                event.tags[nonceIdx][1] = String(nonce);
                event.id = NostrTools.getEventHash(event);
                if (NostrTools.nip13.getPow(event.id) >= difficulty) return event;
                nonce++;
            }
            await new Promise(r => setTimeout(r, 0));
        }
    },

    _effectivePowDifficulty() {
        const userPow = (this.enablePow && this.powDifficulty > 0) ? this.powDifficulty : 0;
        const floor = this.nymchatPowFloor || 0;
        return Math.max(userPow, floor);
    },

    async saveToNostrProfile() {
        if (!this.pubkey) return;

        try {
            let profileToSave;

            const ownsRealProfile = (typeof isNostrLoggedIn === 'function' && isNostrLoggedIn())
                || this.isVerifiedDeveloper(this.pubkey);

            if (ownsRealProfile) {
                // Merge into the existing profile so fields the app doesn't manage (nip05, website, etc.) survive.
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

                // Overwrite fields the app manages, including clearing them.
                if (this.nym) {
                    existing.name = this.nym;
                    existing.display_name = this.nym;
                }
                if (bio !== undefined) existing.about = bio;
                if (this.lightningAddress) {
                    existing.lud16 = this.lightningAddress;
                } else {
                    delete existing.lud16;
                }
                if (avatarUrl) {
                    existing.picture = avatarUrl;
                } else if (!localStorage.getItem('nym_avatar_url')) {
                    delete existing.picture;
                }
                if (bannerUrl) {
                    existing.banner = bannerUrl;
                } else if (!localStorage.getItem('nym_banner_url')) {
                    delete existing.banner;
                }

                profileToSave = existing;
                this._cachedKind0Profile = { ...profileToSave };
            } else {
                const bio = this.userBios.get(this.pubkey) || '';
                profileToSave = {
                    name: this.nym,
                    display_name: this.nym,
                    lud16: this.lightningAddress,
                    about: bio || `Nymchat user`
                };

                const avatarUrl = this.userAvatars.get(this.pubkey);
                if (avatarUrl) {
                    profileToSave.picture = avatarUrl;
                }

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
                // Also publish to DM relays so group chat members see updated profiles.
                this.sendDMToRelays(["EVENT", signedEvent]);
                // Autogenerated throwaway identities are kept off D1.
                if (this._hasCustomProfileData()) {
                    this._saveProfileToD1(signedEvent);
                }
            }
        } catch (error) {
        }
    },

    _hasCustomProfileData() {
        const pk = this.pubkey;
        if (!pk) return false;
        if (typeof isNostrLoggedIn === 'function' && isNostrLoggedIn()) return true;
        if (this.isVerifiedDeveloper(pk)) return true;
        if (this.userAvatars && this.userAvatars.has(pk)) return true;
        if (this.userBanners && this.userBanners.has(pk)) return true;
        const bio = this.userBios && this.userBios.get(pk);
        if (bio && bio.trim()) return true;
        if (this.lightningAddress) return true;
        try {
            const customNick = localStorage.getItem('nym_custom_nick');
            if (customNick && this.nym && this.parseNymFromDisplay(this.nym) === customNick) return true;
        } catch (_) { }
        return false;
    },

    async _saveProfileToD1(signedEvent) {
        if (!signedEvent || !this.pubkey) return;
        // Dedup so duplicate relay receipts of the same kind 0 don't re-POST it.
        if (signedEvent.id) this._lastMirroredOwnProfileId = signedEvent.id;
        try {
            await this._storageApiRequest('profile-set', { event: signedEvent });
            this._cacheD1Profile(this.pubkey, signedEvent);
        } catch (_) { }
    },

    // A newer kind 0 refreshes the entry; entries expire after the TTL.
    _cacheD1Profile(pubkey, event) {
        if (!pubkey) return;
        if (!this._d1ProfileCache) this._d1ProfileCache = new Map();
        this._d1ProfileCache.set(pubkey, { event: event || null, at: Date.now() });
    },

    // Applied through the kind 0 handler so _kind0Ts keeps live relay updates authoritative; returns pubkeys served.
    async _fetchProfilesFromD1(pubkeys) {
        const found = new Set();
        const apiHost = this._getApiHost && this._getApiHost();
        if (!apiHost) return found;
        if (!this._d1ProfileCache) this._d1ProfileCache = new Map();
        const ttl = this.D1_PROFILE_CACHE_TTL || (5 * 60 * 1000);
        const now = Date.now();
        const toFetch = [];
        for (const pk of pubkeys) {
            if (!/^[0-9a-f]{64}$/.test(pk)) continue;
            const cached = this._d1ProfileCache.get(pk);
            if (cached && (now - cached.at) < ttl) {
                found.add(pk);
                continue;
            }
            toFetch.push(pk);
        }
        if (!toFetch.length) return found;
        // profile-get caps a request at 100 pubkeys (storage.js), so walk the whole list in batches.
        const records = [];
        for (let start = 0; start < toFetch.length; start += 100) {
            const batch = toFetch.slice(start, start + 100);
            try {
                const resp = await this._storageApiStream('profile-get', { pubkeys: batch }, false);
                await this._readNdjsonStream(resp, (item) => {
                    if (!Array.isArray(item) || item.length < 2) return;
                    const pk = item[0];
                    const rec = item[1];
                    if (!rec || !rec.event) return;
                    records.push([pk, rec]);
                });
            } catch (_) {
                // Leave this batch "missing" so the caller's relay fallback picks it up.
                break;
            }
        }
        // Verify in small slices so a 100-profile batch doesn't block the main thread.
        for (let i = 0; i < records.length; i++) {
            const [pk, rec] = records[i];
            if (!(await this._verifyRelayEventAsync(rec.event))) continue;
            if (pk === this.pubkey && rec.event.id) this._lastMirroredOwnProfileId = rec.event.id;
            try {
                await this.handleEvent(rec.event);
                if (this.profileFetchedAt) this.profileFetchedAt.set(pk, Date.now());
                this._cacheD1Profile(pk, rec.event);
                found.add(pk);
            } catch (_) { }
            if ((i + 1) % 10 === 0 && i + 1 < records.length && typeof this._yieldToIdle === 'function') {
                await this._yieldToIdle();
            }
        }
        return found;
    },

    async handleEvent(event) {
        // Normalize malicious or malformed relay payloads up front.
        if (!event || typeof event !== 'object' || typeof event.pubkey !== 'string') return;
        if (!Array.isArray(event.tags)) event.tags = [];
        if (typeof event.created_at !== 'number' || !Number.isFinite(event.created_at)) {
            event.created_at = Math.floor(Date.now() / 1000);
        }

        if (this.hasBlockedContentPrefix(event.content)) return;
        if (typeof event.content === 'string') {
            event.content = this.stripMaliciousDomains(event.content);
        }

        // Early dedup so reconnects don't re-process channel messages.
        if (event.kind === 20000 || event.kind === 23333) {
            if (this.processedMessageEventIds.has(event.id)) {
                return;
            }
            this.processedMessageEventIds.add(event.id);

            if (this.processedMessageEventIds.size > 5000) {
                const idsArray = Array.from(this.processedMessageEventIds);
                this.processedMessageEventIds = new Set(idsArray.slice(-4000));
            }
        }

        // D1 backfill tags events with the pool's receipt time (stored_at, ms).
        const _storedAtMs = (Number.isFinite(event.stored_at) && event.stored_at > 0)
            ? event.stored_at : 0;
        const _eventMs = event.created_at * 1000;
        const _effectiveMs = (_storedAtMs && _storedAtMs < _eventMs) ? _storedAtMs : _eventMs;
        const messageAge = Date.now() - _effectiveMs;
        const isHistorical = messageAge > 10000; // Older than 10 seconds

        if (event.pubkey === this.pubkey) {
            if (event.kind === 20000 || event.kind === 23333) {
                if (document.querySelector(`[data-message-id="${event.id}"]`)) {
                    return;
                }
            }

            if (event.kind === 7) {
                const eTag = event.tags.find(t => t[0] === 'e');
                const actionTag = event.tags.find(t => t[0] === 'action');
                const isRemoval = actionTag && actionTag[1] === 'remove';
                if (eTag && !isRemoval) {
                    const messageId = eTag[1];
                    const emoji = event.content;

                    if (this.reactions.has(messageId)) {
                        const messageReactions = this.reactions.get(messageId);
                        if (messageReactions.has(emoji) &&
                            messageReactions.get(emoji).has(this.pubkey)) {
                            return;
                        }
                    }
                }
                // Removals pass through; handleReaction orders by timestamp.
            }
        }


        if (event.kind === 20000 || event.kind === 23333) {
            // Nymbot is exempt: it doesn't mine, and filtering it would silently hide its replies.
            if (this.enablePow &&
                !this.isVerifiedBot(event.pubkey) &&
                !this.validatePow(event, this.powDifficulty)) {
                return;
            }

            // Geohash channels use a `g` tag (kind 20000); named channels a `d` tag (kind 23333).
            const nymTag = event.tags.find(t => t[0] === 'n');
            const channelTagName = event.kind === 20000 ? 'g' : 'd';
            const channelTag = event.tags.find(t => t[0] === channelTagName);

            // Strip any existing #suffix (bitchat includes it; Nymchat adds its own).
            const rawNym = nymTag ? this.stripPubkeySuffix(nymTag[1]) : null;
            const nym = rawNym || this.getNymFromPubkey(event.pubkey);
            const geohash = channelTag ? this.sanitizeChannelName(channelTag[1]) : '';

            if (!geohash) {
                return;
            }

            if (this.isValidGeohash(geohash) !== (event.kind === 20000)) {
                return;
            }

            // `['nymmesh', <id>]` marks a replay of a mesh message; registering the id drops the second copy.
            const meshReplayTag = event.tags.find(t => t[0] === 'nymmesh' && t[1]);
            if (meshReplayTag) {
                if (!this._meshReplayIds) this._meshReplayIds = new Set();
                if (this._meshReplayIds.has(meshReplayTag[1])) return;
                this._meshReplayIds.add(meshReplayTag[1]);
                // Bounded: this only ever grows on replayed events.
                if (this._meshReplayIds.size > 2000) {
                    this._meshReplayIds = new Set([...this._meshReplayIds].slice(-1000));
                }
            }

            // Drop messages to blocked channels so they never get cached in the DOM.
            if (this.isChannelBlocked(geohash, geohash)) {
                return;
            }

            // Reserved nym "nymbot" is only allowed from the verified bot pubkey.
            if (nym.toLowerCase() === 'nymbot' && !this.isVerifiedBot(event.pubkey)) {
                return;
            }

            // Automatic heuristics run only in direct mode; the relay-pool proxy already filters.
            const clientGates = this._clientGatesActive();
            if (clientGates && event.pubkey !== this.pubkey && !this.isFriend?.(event.pubkey) &&
                this.isGibberishNym(nym)) {
                return;
            }

            if (geohash && !this.discoveredGeohashes.has(geohash)) {
                this.discoveredGeohashes.add(geohash);
            }

            if (this.blockedUsers.has(event.pubkey) || this.hasBlockedKeyword(event.content, nym, event.pubkey)) {
                return;
            }

            if (clientGates && typeof this.isAutoMuted === 'function' && this.isAutoMuted(event.pubkey)) {
                return;
            }

            if (clientGates && this.isSpamMessage(event.content)) {
                return;
            }

            if (typeof this.ingestAttestBadge === 'function') this.ingestAttestBadge(event);

            if (typeof this.passesAppVerifiedFilter === 'function'
                && !this.passesAppVerifiedFilter(event.pubkey)) {
                return;
            }

            if (event.pubkey !== this.pubkey) {
                this._trackPubkeyMessage(event.pubkey, event.id);
                // NIP-13 PoW meeting the nymchat floor counts as self-attestation of a nymchat client.
                if (this.nymchatPowFloor > 0 && this.validatePow(event, this.nymchatPowFloor)) {
                    this._markNymchatPubkey(event.pubkey);
                    if (typeof this._observeNymchatPubkey === 'function') {
                        this._observeNymchatPubkey(event.pubkey);
                    }
                }
            }

            if (clientGates && !isHistorical && this.isFlooding(event.pubkey, geohash)) {
                return;
            }

            if (clientGates
                && event.pubkey !== this.pubkey
                && !this.isFriend?.(event.pubkey)
                && !this.isVerifiedBot(event.pubkey)
                && typeof this.checkCampaign === 'function') {
                const verdict = this.checkCampaign(
                    event.content, event.pubkey, (Math.floor(event.created_at) || 0) * 1000);
                if (verdict.mute) this.autoMute(event.pubkey);
                if (verdict.flood || verdict.mute) return;
            }

            if (clientGates && !isHistorical) {
                this.trackMessage(event.pubkey, geohash, isHistorical, event.content);
            }

            const channelKey = geohash;
            if (!this.channelNotificationTracking) {
                this.channelNotificationTracking = new Map();
            }
            if (!this.channelNotificationTracking.has(channelKey)) {
                this.channelNotificationTracking.set(channelKey, new Set());
            }
            const alreadyNotified = this.channelNotificationTracking.get(channelKey).has(event.id);

            // BRB auto-response, only for new messages.
            if (!isHistorical && this.isMentioned(event.content) && this.awayMessages.has(this.pubkey)) {
                const responseKey = `brb_universal_${this.pubkey}_${nym}`;
                if (!sessionStorage.getItem(responseKey)) {
                    sessionStorage.setItem(responseKey, '1');

                    const response = `@${nym} [Auto-Reply] ${this.awayMessages.get(this.pubkey)}`;
                    await this.publishMessage(response, geohash, geohash);
                }
            }

            if (geohash && !this.channels.has(geohash) && !this.isChannelBlocked(geohash, geohash)) {
                this.addChannelToList(geohash, geohash);
            }

            const fileOffer = this.parseFileOfferTag(event.tags, event.pubkey);

            if (event.pubkey !== this.pubkey) {
                // Timestamp only, so avatar-less senders don't queue a profile fetch on every message.
                const lastFetch = this.profileFetchedAt.get(event.pubkey) || 0;
                if (Date.now() - lastFetch > 5 * 60 * 1000) {
                    this.profileFetchedAt.set(event.pubkey, Date.now());
                    this.queueProfileFetch(event.pubkey);
                }
            }

            const editTag = event.tags.find(t => t[0] === 'edit');
            if (editTag && editTag[1]) {
                const originalId = editTag[1];
                this.handleIncomingEdit(originalId, event.content, event.pubkey, event.id, event.created_at);
                return;
            }

            const eventCreatedAt = Math.floor(event.created_at) || 0;
            const nowSec = Math.floor(Date.now() / 1000);

            // Guard against clock skew.
            let correctedCreatedAt = eventCreatedAt;
            if (eventCreatedAt > nowSec) {
                const candidateMs = _storedAtMs
                    ? Math.min(eventCreatedAt * 1000, _storedAtMs)
                    : eventCreatedAt * 1000;
                correctedCreatedAt = Math.floor(this._stableClampMs(event.id, candidateMs) / 1000);
            }

            // Something already outside the 24-hour window landed; request the sweep now.
            if (typeof this._channelWindowFloorSec === 'function' &&
                correctedCreatedAt < this._channelWindowFloorSec() &&
                typeof this._scheduleChannelWindowPrune === 'function') {
                this._scheduleChannelWindowPrune();
            }

            // Quotes travel as @mention + nymquote tag so other clients see a normal mention; rebuild the blockquote here.
            let displayContent = event.content;
            const nymquoteTag = event.tags.find(t => t[0] === 'nymquote');
            if (nymquoteTag && nymquoteTag[1] && nymquoteTag[2]) {
                const qAuthor = nymquoteTag[1];
                const qText = nymquoteTag[2];
                const mentionPattern = _getQuoteMentionPattern(qAuthor);
                const userMessage = event.content.replace(mentionPattern, '').trim();
                // Show only the last quoted message (strip nested quotes).
                const strippedQText = qText.split('\n').filter(line => !line.startsWith('>')).join('\n').replace(/\n{3,}/g, '\n\n').trim();
                const textLines = strippedQText.split('\n');
                const quoteLine = `> @${qAuthor}: ${textLines[0]}` +
                    (textLines.length > 1 ? '\n' + textLines.slice(1).map(line => `> ${line}`).join('\n') : '');
                displayContent = userMessage ? `${quoteLine}\n\n${userMessage}` : quoteLine;
            }

            // NIP-30 custom emoji.
            this.ingestEmojiTags(event.tags);

            // NIP-92 Blossom mirror URLs.
            if (typeof this.ingestImetaTags === 'function') {
                this.ingestImetaTags(event.tags);
            }

            const message = {
                id: event.id,
                author: nym,
                pubkey: event.pubkey,
                content: displayContent,
                created_at: correctedCreatedAt,
                _originalCreatedAt: eventCreatedAt,
                _ms: this._extractEventMs(event, correctedCreatedAt),
                _seq: ++this._msgSeq,
                timestamp: new Date(correctedCreatedAt * 1000),
                channel: geohash,
                geohash: geohash,
                isOwn: event.pubkey === this.pubkey,
                isHistorical: isHistorical,
                isFileOffer: !!fileOffer,
                fileOffer: fileOffer,
                isBot: this.isVerifiedBot(event.pubkey),
                // NIP-10 marked root reference (threads.js).
                threadRoot: (typeof this.threadRootFromChannelTags === 'function')
                    ? this.threadRootFromChannelTags(event.tags) : null,
                // Committed NIP-13 target, or null without a nonce tag; proven work is recomputed from the id.
                powTarget: this._powTargetFromEvent(event)
            };

            if (!this.isDuplicateMessage(message)) {
                if (message.isBot && typeof this._setBotChannelThinking === 'function') {
                    this._setBotChannelThinking(false);
                }
                this.displayMessage(message);
                if (!message._spamGated) {
                    this.updateUserPresence(nym, event.pubkey, message.channel, geohash, event.created_at);
                }

                const _notifStorageKey = geohash ? `#${geohash}` : message.channel;
                const _notifCurrentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
                // Collapsed thread replies are off screen, so they must not count as already seen.
                const _threadHidden = typeof this._threadReplyHidden === 'function' &&
                    this._threadReplyHidden(message);
                const _isViewingChannel = !this.inPMMode &&
                    _notifStorageKey === _notifCurrentKey && !_threadHidden;

                // Channels notify on @mention, plus replies in threads the user started (unless threadNotifyMentionsOnly).
                const _threadElevated = typeof this._threadReplyElevated === 'function' &&
                    this._threadReplyElevated(message);
                const _threadSuppressed = typeof this._threadReplySuppressed === 'function' &&
                    this._threadReplySuppressed(message);
                const _channelAddressesMe = !_threadSuppressed &&
                    (this.isMentioned(message.content) || _threadElevated);
                // Name the thread as well as the channel in the bell footer.
                const _notifInThread = !!(message.threadRoot &&
                    typeof this.threadsEnabled === 'function' && this.threadsEnabled());
                const _channelNotifInfo = () => ({
                    type: 'geohash',
                    channel: geohash,
                    geohash: geohash,
                    id: event.id,
                    eventId: event.id,
                    pubkey: event.pubkey,
                    ...(_notifInThread ? { inThread: true, threadRoot: message.threadRoot } : {})
                });

                const shouldNotify = !message.isOwn &&
                    !message._spamGated &&
                    _channelAddressesMe &&
                    !this.blockedUsers.has(event.pubkey) &&
                    !isHistorical &&
                    !alreadyNotified &&
                    (document.hidden || !_isViewingChannel);

                if (shouldNotify) {
                    this.channelNotificationTracking.get(channelKey).add(event.id);
                    // `message._ms` (skew-corrected) so the bell agrees with the list and future stamps don't pin to the top.
                    this.showNotification(nym, this._notifPreviewText(message.content), _channelNotifInfo(),
                        message._ms || message.timestamp.getTime());
                }

                if (isHistorical && !message.isOwn && !message._spamGated &&
                    _channelAddressesMe && !this.blockedUsers.has(event.pubkey)) {
                    this._addNotificationToHistory(nym, this._notifPreviewText(message.content),
                        _channelNotifInfo(), message.timestamp.getTime());
                }
            }
        } else if (event.kind === 30078) {
            const dTag = event.tags.find(t => t[0] === 'd');
            if (!dTag) return;

            if (dTag[1]?.startsWith('nym-settings-transfer-') && event.pubkey !== this.pubkey) {
                this.handleSettingsTransferEvent(event);
            }

            const tTag = event.tags?.find(t => t[0] === 't');
            if (tTag && tTag[1] === 'nym-presence') {
                this.handlePresenceEvent(event);
            } else if (tTag && tTag[1] === 'nym-poll') {
                this.handlePollEvent(event);
            } else if (tTag && tTag[1] === 'nym-poll-vote') {
                this.handlePollVoteEvent(event);
            } else if (tTag && tTag[1] === 'nym-vouches') {
                this.handleVouchEvent(event);
            } else if (tTag && tTag[1] === this.PQ_D_TAG) {
                this.handlePqAnnouncement(event);
            }
        } else if (event.kind === 24420) {
            this.handleChannelTypingEvent(event);
        } else if (event.kind === 24421) {
            this.handleChannelReadReceipt(event);
        } else if (event.kind === 7) {
            // NIP-25.
            this.handleReaction(event);
        } else if (event.kind === 5) {
            // NIP-09.
            this.handleDeletionEvent(event);
        } else if (event.kind === 9735) {
            this.handleZapReceipt(event);
        } else if (event.kind === 1059) {
            this._enqueueGiftWrapDM(event);
        } else if (event.kind === 10000) {
            this.handleMuteList(event);
        } else if (event.kind === 30030) {
            // NIP-30 custom emoji pack.
            this.handleEmojiPackEvent(event);
        } else if (event.kind === 10030) {
            // NIP-30 user emoji list.
            this.handleUserEmojiListEvent(event);
        } else if (event.kind === 0) {
            try {
                const profile = JSON.parse(event.content);
                const pubkey = event.pubkey;

                const eventTs = (typeof event.created_at === 'number') ? event.created_at : 0;
                if (!this._kind0Ts) this._kind0Ts = new Map();
                const lastTs = this._kind0Ts.get(pubkey) || 0;
                if (eventTs && lastTs && eventTs < lastTs) {
                    this._resolveProfileCallbacks(pubkey);
                    return;
                }
                if (eventTs > lastTs) this._kind0Ts.set(pubkey, eventTs);

                // Keep the D1 read cache fresh.
                this._cacheD1Profile(pubkey, event);

                // Cache our own full kind 0 so saveToNostrProfile can merge without losing unmanaged fields.
                if (pubkey === this.pubkey) {
                    this._cachedKind0Profile = profile;
                    if (eventTs > (this._lastKind0Ts || 0)) {
                        this._lastKind0Ts = eventTs;
                    }
                    // Mirror our signed profile to D1; gated by _hasCustomProfileData and deduped by event id.
                    if (event.id && event.sig && event.id !== this._lastMirroredOwnProfileId
                        && this._hasCustomProfileData()) {
                        this._saveProfileToD1(event);
                    }
                }

                if (profile.lud16 || profile.lud06) {
                    const lnAddress = profile.lud16 || profile.lud06;
                    this.userLightningAddresses.set(pubkey, lnAddress);
                    this.notifyLightningAddress(pubkey, lnAddress);
                } else if (pubkey !== this.pubkey) {
                    this.userLightningAddresses.delete(pubkey);
                }

                const pickPictureUrl = (p) => {
                    const candidates = [p && p.picture, p && p.image, p && p.avatar];
                    for (const c of candidates) {
                        if (typeof c !== 'string') continue;
                        const trimmed = c.trim().replace(/^['"]|['"]$/g, '');
                        if (!trimmed) continue;
                        if (/^(https?:|data:image\/)/i.test(trimmed)) return trimmed;
                    }
                    return null;
                };
                const pictureUrl = pickPictureUrl(profile);
                if (pictureUrl) {
                    const prevUrl = this.userAvatars.get(pubkey);
                    if (prevUrl !== pictureUrl) {
                        const oldBlob = this.avatarBlobCache.get(pubkey);
                        if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(pubkey); }
                        if (typeof this.deleteCachedAvatar === 'function') this.deleteCachedAvatar(pubkey);
                        this.userAvatars.set(pubkey, pictureUrl);
                        this.cacheAvatarImage(pubkey, pictureUrl);
                        this.updateRenderedAvatars(pubkey, pictureUrl);
                    } else if (!this.avatarBlobCache.has(pubkey)) {
                        this.userAvatars.set(pubkey, pictureUrl);
                        this.cacheAvatarImage(pubkey, pictureUrl);
                    }
                } else if (pubkey !== this.pubkey && this.userAvatars.has(pubkey)) {
                    const oldBlob = this.avatarBlobCache.get(pubkey);
                    if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(pubkey); }
                    if (typeof this.deleteCachedAvatar === 'function') this.deleteCachedAvatar(pubkey);
                    this.userAvatars.delete(pubkey);
                    this.updateRenderedAvatars(pubkey, this.getAvatarUrl(pubkey));
                }

                if (profile.banner) {
                    const prevBanner = this.userBanners.get(pubkey);
                    if (prevBanner !== profile.banner) {
                        const oldBlob = this.bannerBlobCache.get(pubkey);
                        if (oldBlob) { URL.revokeObjectURL(oldBlob); this.bannerBlobCache.delete(pubkey); }
                        if (typeof this.deleteCachedBanner === 'function') this.deleteCachedBanner(pubkey);
                        this.userBanners.set(pubkey, profile.banner);
                        this.cacheBannerImage(pubkey, profile.banner);
                    } else if (!this.bannerBlobCache.has(pubkey)) {
                        this.userBanners.set(pubkey, profile.banner);
                        this.cacheBannerImage(pubkey, profile.banner);
                    }
                } else if (pubkey !== this.pubkey && this.userBanners.has(pubkey)) {
                    const oldBlob = this.bannerBlobCache.get(pubkey);
                    if (oldBlob) { URL.revokeObjectURL(oldBlob); this.bannerBlobCache.delete(pubkey); }
                    if (typeof this.deleteCachedBanner === 'function') this.deleteCachedBanner(pubkey);
                    this.userBanners.delete(pubkey);
                    if (typeof this.updateRenderedBanner === 'function') {
                        this.updateRenderedBanner(pubkey);
                    }
                }

                if (typeof profile.about === 'string') {
                    const bio = profile.about.substring(0, 150);
                    this.userBios.set(pubkey, bio);
                    if (pubkey === this.pubkey) {
                        localStorage.setItem('nym_bio', bio);
                    }
                }

                const profileName = [profile.name, profile.username, profile.display_name]
                    .find(v => typeof v === 'string' && v.length > 0);
                if (profileName) {
                    const truncatedName = profileName.substring(0, 20);
                    const existingUser = this.users.get(pubkey);
                    // The kind 0 event is authoritative for display names.
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
                    this.persistProfile(pubkey);
                    if (typeof this.updateStoredNymsForPubkey === 'function') {
                        this.updateStoredNymsForPubkey(pubkey, truncatedName);
                    }
                    this.updatePMNicknameFromProfile(pubkey, truncatedName);
                    if (pubkey === this.pubkey) {
                        this._updateOwnSidebarProfile();
                    } else if (typeof this.updateGroupMembershipDisplay === 'function') {
                        this.updateGroupMembershipDisplay(pubkey);
                    }
                    if (typeof this.updateNotificationModalProfile === 'function') {
                        this.updateNotificationModalProfile(pubkey, truncatedName);
                    }

                    if (typeof this.updateUserList === 'function') {
                        this.updateUserList();
                    }
                }

                // Placed after all fields are stored so one call refreshes the whole open card.
                if (typeof this.updateRenderedProfileCard === 'function') {
                    this.updateRenderedProfileCard(pubkey);
                }

                this._resolveProfileCallbacks(pubkey);
            } catch (e) {
            }
        } else if (event.kind === this.P2P_SIGNALING_KIND) {
            this.handleP2PSignalingEvent(event);
        } else if (event.kind === this.P2P_FILE_STATUS_KIND) {
            this.handleP2PFileStatusEvent(event);
        }
    },

    _looksLikeRandomToken(token) {
        if (!token || token.length < 8) return false;
        if (!/^[A-Za-z0-9]+$/.test(token)) return false;

        const hasUpper = /[A-Z]/.test(token);
        const hasLower = /[a-z]/.test(token);

        const half = Math.floor(token.length / 2);
        for (let unit = 3; unit <= half; unit++) {
            const head = token.substring(0, unit);
            if (token.substring(unit, unit * 2) === head) {
                if (new Set(head).size >= 3) return true;
            }
        }

        if (hasUpper && hasLower) {
            let interiorUpper = 0;
            for (let i = 1; i < token.length; i++) {
                const c = token.charCodeAt(i);
                if (c >= 65 && c <= 90) interiorUpper++;
            }
            const interiorUpperRatio = interiorUpper / (token.length - 1);
            if (interiorUpper >= 3 && interiorUpperRatio >= 0.3) return true;
        }

        return false;
    },

    _hasRepeatedTokenSpam(trimmed) {
        const tokens = trimmed.split(/\s+/).filter(Boolean);
        if (tokens.length >= 2) {
            const first = tokens[0];
            if (first.length >= 6 && /^[A-Za-z0-9]+$/.test(first) &&
                tokens.every(t => t === first)) {
                return true;
            }
            const baseLen = Math.min(...tokens.map(t => t.length));
            if (baseLen >= 6) {
                const base = tokens.find(t => t.length === baseLen);
                if (base && /^[A-Za-z0-9]+$/.test(base) && tokens.every(t => {
                    if (t.length % baseLen !== 0) return false;
                    for (let i = 0; i < t.length; i += baseLen) {
                        if (t.substring(i, i + baseLen) !== base) return false;
                    }
                    return true;
                })) {
                    return true;
                }
            }
        }
        if (tokens.length === 1 && tokens[0].length >= 12 && /^[A-Za-z0-9]+$/.test(tokens[0])) {
            const t = tokens[0];
            for (let unit = 4; unit <= Math.floor(t.length / 2); unit++) {
                const head = t.substring(0, unit);
                if (t.substring(unit, unit * 2) === head && new Set(head).size >= 3) return true;
            }
        }
        return false;
    },

    _RX_ZERO_WIDTH: /[\u200B\u200C\u200E\u200F\u202A-\u202E\u2060-\u206F\uFEFF]/g,
    _RARE_BIGRAMS: ['xw','xz','xj','xk','wx','wz','wj','wq','jq','jx','jz','kq','kx','kz','vq','vx','vz','zx','zk','zp','pq','pz','fq','fz','gq','gz','hq','hz'],

    _scoreSingleAlphanumWord(token) {
        if (!/^[A-Za-z0-9]{8,}$/.test(token)) return 0;
        let score = 1;
        const lower = token.toLowerCase();
        const hasDigit = /[0-9]/.test(token);
        if (hasDigit && /[A-Za-z]/.test(token)) score += 1;
        const interiorUpper = (token.substring(1).match(/[A-Z]/g) || []).length;
        if (interiorUpper >= 3) score += 1;
        const vowelCount = (lower.match(/[aeiou]/g) || []).length;
        const vowelRatio = vowelCount / token.length;
        if (vowelRatio <= 0.2) score += 1;
        // English 'q' is almost always followed by 'u'.
        if (/q(?!u)/i.test(token)) score += 2;
        let rare = 0;
        for (const bg of this._RARE_BIGRAMS) {
            if (lower.includes(bg)) rare++;
        }
        if (rare > 0) score += Math.min(rare, 2);
        return score;
    },

    _hasMixedScriptToken(text) {
        for (const tok of text.split(/\s+/)) {
            if (tok.length < 4) continue;
            const hasLatin = /[A-Za-z]/.test(tok);
            const hasCyrillic = /[Ѐ-ӿ]/.test(tok);
            const hasGreek = /[Ͱ-Ͽ]/.test(tok);
            const scripts = (hasLatin ? 1 : 0) + (hasCyrillic ? 1 : 0) + (hasGreek ? 1 : 0);
            if (scripts < 2) continue;
            const letterCount = (tok.match(/[A-Za-zЀ-ӿͰ-Ͽ]/g) || []).length;
            if (letterCount / tok.length < 0.6) continue;
            return true;
        }
        return false;
    },

    _spamScore(trimmed) {
        let score = 0;

        trimmed = trimmed.replace(this._RX_ZERO_WIDTH, '');
        if (this._hasRepeatedTokenSpam(trimmed)) score += 3;
        if (this._hasMixedScriptToken(trimmed)) score += 2;

        const tokens = trimmed.split(/\s+/).filter(Boolean);
        if (tokens.length === 1) {
            if (this._looksLikeRandomToken(tokens[0])) score += 3;
            score += this._scoreSingleAlphanumWord(tokens[0]);
            if (tokens[0].length >= 12) {
                const alnum = (tokens[0].match(/[A-Za-z0-9]/g) || []).length;
                if (alnum / tokens[0].length >= 0.5) score += 1;
            }
        } else {
            let gibberish = 0, analyzable = 0;
            for (const tok of tokens) {
                if (tok.length < 6) continue;
                analyzable++;
                if (this._looksLikeRandomToken(tok)) gibberish++;
            }
            if (analyzable > 0 && gibberish / analyzable >= 0.5) score += 3;
        }

        const digitCount = (trimmed.match(/[0-9]/g) || []).length;
        const letterCount = (trimmed.match(/[A-Za-z]/g) || []).length;
        if (trimmed.length >= 8 && letterCount > 0 && digitCount / trimmed.length > 0.5) score += 1;

        // A lone emoji is normal chat and never trips this.
        const emojiMatches = trimmed.match(/\p{Extended_Pictographic}/gu) || [];
        if (emojiMatches.length >= 4 && letterCount > 0) score += 1;

        return score;
    },

    // Relayed media/encoded blobs we never render: drop them outright.
    hasBlockedContentPrefix(content) {
        if (typeof content !== 'string') return false;
        return _RX_BLOCKED_CONTENT_BLOB.test(content.trimStart());
    },

    stripMaliciousDomains(content) {
        if (typeof content !== 'string' || !content) return content;
        _RX_MALICIOUS_DOMAIN.lastIndex = 0;
        if (!_RX_MALICIOUS_DOMAIN.test(content)) return content;
        _RX_MALICIOUS_DOMAIN.lastIndex = 0;
        // Collapse the gap the link leaves behind.
        return content.replace(_RX_MALICIOUS_DOMAIN, '')
            .replace(/[ \t]{2,}/g, ' ')
            .replace(/[ \t]+([.,!?;:])/g, '$1')
            .trim();
    },

    isSpamMessage(content) {
        if (this.spamFilterEnabled === false) return false;
        if (typeof content !== 'string') return false;

        const trimmed = content.trim();

        if (trimmed.includes('["client","chorus"]')) return true;

        if (this.spamFilterAggressive === false) return false;

        if (trimmed.length < 6) return false;

        if (trimmed.includes('://') || trimmed.startsWith('www.')) return false;
        if (/^ln(bc|tb|ts)/i.test(trimmed)) return false;
        if (/^cashu/i.test(trimmed)) return false;
        if (/^(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+$/i.test(trimmed)) return false;
        if (/^[0-9a-fA-F]{64}$/.test(trimmed)) return false;
        if (trimmed.includes('```') || trimmed.includes('`')) return false;
        if (trimmed.startsWith('data:image')) return false;

        const filteredWords = trimmed
            .split(/[\s\u3000\u2000-\u200B\u0020\u00A0.,;!?。、，；！？\n]/)
            .filter(Boolean);
        const longestWord = filteredWords.reduce((m, w) => Math.max(m, w.length), 0);

        if (longestWord > 100) {
            const hasOnlyAlphaNumeric = /^[a-zA-Z0-9]+$/.test(trimmed);
            if (hasOnlyAlphaNumeric && trimmed.length > 100) return true;

            const longWord = filteredWords.find(w => w.length > 100);
            if (longWord && /^[a-zA-Z0-9]+$/.test(longWord)) {
                const charFreq = {};
                for (const char of longWord) {
                    charFreq[char] = (charFreq[char] || 0) + 1;
                }
                const frequencies = Object.values(charFreq);
                const avgFreq = longWord.length / Object.keys(charFreq).length;
                const variance = frequencies.reduce((sum, freq) => sum + Math.pow(freq - avgFreq, 2), 0) / frequencies.length;
                if (variance < 2 && longWord.length > 100) return true;
            }
        }

        // Score the user's own text only: @mention suffixes and quoted lines would skew the heuristics.
        const scrubbed = trimmed
            .split('\n').filter(line => !line.trimStart().startsWith('>')).join('\n')
            .replace(/@\S+/g, ' ')
            .replace(/(nostr:)?(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+/gi, ' ')
            .replace(/\b[0-9a-fA-F]{64}\b/g, ' ')
            .trim();

        return this._spamScore(scrubbed) >= 3;
    },

    isGibberishNym(nym) {
        if (this.spamFilterEnabled === false) return false;
        if (this.spamFilterAggressive === false) return false;
        if (typeof nym !== 'string') return false;
        const n = nym.trim();
        if (!n || n.length < 8) return false;
        return this._looksLikeRandomToken(n);
    },

    handleMuteList(event) {
        if (event.pubkey !== this.pubkey || event.kind !== 10000) return;

        const mutedPubkeys = event.tags
            .filter(tag => tag[0] === 'p' && tag[1])
            .map(tag => tag[1]);

        if (mutedPubkeys.length > 0) {
            // Replace (not merge) with synced blocked users.
            this.blockedUsers = new Set(mutedPubkeys);
            this.saveBlockedUsers();
            this.updateBlockedList();
            this.updateUserList();

            mutedPubkeys.forEach(pubkey => {
                this.hideMessagesFromBlockedUser(pubkey);
            });
        }

        const mutedWords = event.tags
            .filter(tag => tag[0] === 'word' && tag[1])
            .map(tag => tag[1]);

        if (mutedWords.length > 0) {
            // Replace (not merge) with synced keywords.
            this.blockedKeywords = new Set(mutedWords);
            this.saveBlockedKeywords();
            this.updateKeywordList();

            this.hideMessagesWithBlockedKeywords();
        }

        // Re-render so blocks apply to messages that loaded before the mute list synced.
        if (mutedPubkeys.length > 0 || mutedWords.length > 0) {
            this.rerenderCurrentView();
        }
    },

    randomNow() {
        // ±2 hours NIP-59 jitter; bitchat only looks back 24 hours for DMs.
        const TWO_HOURS = 2 * 60 * 60;
        // CSPRNG so the privacy jitter can't be predicted/stripped by an observer.
        const r = crypto.getRandomValues(new Uint32Array(1))[0] / 4294967296;
        return Math.round(Date.now() / 1000 - r * TWO_HOURS);
    },

    // Used only by Bitchat's TLV encoder, which parses UUID format.
    generateUUID() {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
            const r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        }).toUpperCase();
    },

    _generateSharedEventId() {
        const bytes = new Uint8Array(32);
        crypto.getRandomValues(bytes);
        let s = '';
        for (let i = 0; i < bytes.length; i++) {
            s += bytes[i].toString(16).padStart(2, '0');
        }
        return s;
    },

    // Bitchat caps a TLV value at 255 bytes (1-byte length), so long text is sent as several messages.
    BITCHAT_MAX_CONTENT_BYTES: 255,

    // Never cuts a multi-byte character; mirrors the mesh `_chunk` (mesh-service.js).
    chunkBitchatContent(content) {
        const bytes = new TextEncoder().encode(content);
        const max = this.BITCHAT_MAX_CONTENT_BYTES;
        if (bytes.length <= max) return [content];
        const dec = new TextDecoder();
        const out = [];
        let start = 0;
        while (start < bytes.length) {
            let end = Math.min(start + max, bytes.length);
            while (end > start && end < bytes.length && (bytes[end] & 0xC0) === 0x80) end--;
            out.push(dec.decode(bytes.subarray(start, end)));
            start = end;
        }
        return out;
    },

    encodeBitchatMessage(content, recipientPubkey = null) {
        const now = Date.now();
        const messageID = this.generateUUID();
        const messageBytes = new TextEncoder().encode(content);
        const messageIDBytes = new TextEncoder().encode(messageID);

        const tlvParts = [];

        // One-byte lengths only: bitchat's decoder discards packets with any other length encoding.
        const pushTlvField = (type, valueBytes) => {
            if (valueBytes.length > 0xFF) {
                throw new Error('bitchat TLV value over 255 bytes — chunk first');
            }
            tlvParts.push(type);
            tlvParts.push(valueBytes.length);
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

        // Header bytes 0-2.
        parts.push(0x01); // version 1
        parts.push(0x11); // type = NOISE_ENCRYPTED
        parts.push(0x07); // TTL 7

        // Timestamp bytes 3-10 (8 bytes, big-endian milliseconds).
        const ts = BigInt(now);
        for (let i = 7; i >= 0; i--) {
            parts.push(Number((ts >> BigInt(i * 8)) & 0xFFn));
        }

        // Flags byte 11: 0x01 = HAS_RECIPIENT, 0x02 = HAS_SIGNATURE, 0x04 = IS_COMPRESSED.
        const hasRecipient = !!recipientPubkey;
        const flags = hasRecipient ? 0x01 : 0x00;
        parts.push(flags);

        // Payload length bytes 12-13 (2 bytes, big-endian).
        const payloadLen = noisePayload.length;
        parts.push((payloadLen >> 8) & 0xFF);
        parts.push(payloadLen & 0xFF);

        // Sender ID bytes 14-21 (first 8 bytes of our pubkey).
        for (let i = 0; i < 8; i++) {
            parts.push(parseInt(this.pubkey.substring(i * 2, i * 2 + 2), 16));
        }

        // Recipient ID bytes 22-29 (if HAS_RECIPIENT flag set).
        if (hasRecipient) {
            for (let i = 0; i < 8; i++) {
                parts.push(parseInt(recipientPubkey.substring(i * 2, i * 2 + 2), 16));
            }
        }

        for (const b of noisePayload) parts.push(b);

        // Pad to the next block size (256, 512, 1024, 2048) with 0xBE.
        const blockSizes = [256, 512, 1024, 2048];
        let targetSize = blockSizes.find(s => s >= parts.length) || 2048;
        while (parts.length < targetSize) {
            parts.push(0xBE);
        }

        // base64url.
        const bytes = new Uint8Array(parts);
        const base64 = btoa(String.fromCharCode(...bytes));
        const base64url = base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

        return { content: 'bitchat1:' + base64url, messageId: messageID };
    },

    // DELIVERED=0x03 or READ_RECEIPT=0x02.
    encodeBitchatReceipt(messageId, receiptType, recipientPubkey) {
        const messageIdBytes = new TextEncoder().encode(messageId);

        // Receipts carry [type][raw messageId] with no TLV wrapper, as Bitchat sends them.
        const noisePayload = [];
        noisePayload.push(receiptType); // 0x02=READ_RECEIPT, 0x03=DELIVERED
        for (const b of messageIdBytes) noisePayload.push(b);

        const parts = [];
        const now = Date.now();

        parts.push(0x01); // version
        parts.push(0x11); // type = NOISE_ENCRYPTED
        parts.push(0x07); // TTL

        // Timestamp (8 bytes big-endian).
        const ts = BigInt(now);
        for (let i = 7; i >= 0; i--) {
            parts.push(Number((ts >> BigInt(i * 8)) & 0xFFn));
        }

        parts.push(0x01); // HAS_RECIPIENT

        const payloadLen = noisePayload.length;
        parts.push((payloadLen >> 8) & 0xFF);
        parts.push(payloadLen & 0xFF);

        // Sender ID (first 8 bytes of our pubkey).
        for (let i = 0; i < 8; i++) {
            parts.push(parseInt(this.pubkey.substring(i * 2, i * 2 + 2), 16));
        }

        for (let i = 0; i < 8; i++) {
            parts.push(parseInt(recipientPubkey.substring(i * 2, i * 2 + 2), 16));
        }

        for (const b of noisePayload) parts.push(b);

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

    async sendBitchatReceipt(messageId, receiptType, recipientPubkey) {
        if (!this.privkey || !this.bitchatUsers.has(recipientPubkey)) return;

        if (receiptType === 0x02 && !this.isReadReceiptAllowedFor('pm')) {
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

        const wrapped = await this.bitchatWrapEventAsync(rumor, this.privkey, recipientPubkey, null);
        this.sendDMToRelays(['EVENT', wrapped]);
    },

    // NIP-17 rumor of custom kind 69420 (not 14, so other clients show no blank DMs) with x and receipt tags.
    async sendNymReceipt(messageId, receiptType, recipientPubkey, context = 'pm', groupId = null) {
        if (!this._canSendGiftWraps()) return;
        if (context !== 'group' && this.botAnonSuppressSendTo && this.botAnonSuppressSendTo(recipientPubkey)) return;

        if (receiptType === 'read' && !this.isReadReceiptAllowedFor(context)) {
            return;
        }

        const messageIds = Array.isArray(messageId) ? messageId : [messageId];
        if (!messageIds.length) return;
        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            kind: 69420,
            created_at: now,
            tags: [
                ['p', recipientPubkey],
                ...messageIds.map(id => ['x', id]),
                ['receipt', receiptType]  // 'delivered' or 'read'
            ],
            content: '',
            pubkey: this.pubkey
        };

        // Group receipts go to the ephemeral key so they don't expose the real-pubkey membership set.
        if (context === 'group' && groupId) {
            await this._sendGiftWrapsAsync([recipientPubkey], rumor, null, groupId);
            return;
        }

        if (this.privkey) {
            const wrapped = await this._pmSignalWrapAsync(rumor, recipientPubkey);
            this.sendDMToRelays(['EVENT', wrapped]);
        } else {
            await this._sendGiftWrapsAsync([recipientPubkey], rumor, null);
        }
    },

    async _pmSignalWrapAsync(rumor, recipientPubkey) {
        const plan = typeof this.pqPmPlan === 'function' ? this.pqPmPlan(recipientPubkey) : null;
        return plan && plan.kemPk
            ? this.pqWrapForPeerAsync(plan.pq2, rumor, this.privkey, recipientPubkey, plan.kemPk, null)
            : this.nip59WrapEventAsync(rumor, this.privkey, recipientPubkey, null);
    },

    isTypingIndicator(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'typing');
    },

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

        const ttlTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'ttl' && t[1]);
        const ttl = ttlTag ? parseInt(ttlTag[1], 10) : 0;
        return status ? { status, groupId, ttl: ttl > 0 ? ttl : 0, pubkey: rumor.pubkey } : null;
    },

    handleTypingSignal() {
        if (!this._canSendGiftWraps() || !this.inPMMode) return;
        const context = this.currentGroup ? 'group' : 'pm';
        if (!this.isTypingIndicatorAllowedFor(context)) return;

        const now = Date.now();
        const convKey = this.currentGroup ? `group:${this.currentGroup}` : `pm:${this.currentPM}`;
        if (!this._pmTypingStartedFor) this._pmTypingStartedFor = new Set();
        const already = this._pmTypingStartedFor.has(convKey);

        if (this._typingStopTimer) clearTimeout(this._typingStopTimer);
        this._typingStopTimer = setTimeout(() => {
            if (this._typingStartTimer) { clearTimeout(this._typingStartTimer); this._typingStartTimer = null; }
            if (!this._pmTypingStartedFor || !this._pmTypingStartedFor.delete(convKey)) return;
            this._sendTypingEvent('stop');
        }, this._typingStopDelay);

        if (already) {
            if (now - this._typingThrottleTime < this._typingSendInterval) return;
            this._typingThrottleTime = now;
            this._sendTypingEvent('start');
            return;
        }
        if (this._typingStartTimer) return;
        this._typingStartTimer = setTimeout(() => {
            this._typingStartTimer = null;
            this._typingThrottleTime = Date.now();
            this._pmTypingStartedFor.add(convKey);
            this._sendTypingEvent('start');
        }, this._typingStartDebounce);
    },

    sendTypingStop() {
        if (!this._canSendGiftWraps() || !this.inPMMode) return;
        const context = this.currentGroup ? 'group' : 'pm';
        if (!this.isTypingIndicatorAllowedFor(context)) return;
        const convKey = this.currentGroup ? `group:${this.currentGroup}` : `pm:${this.currentPM}`;
        if (this._typingStartTimer) { clearTimeout(this._typingStartTimer); this._typingStartTimer = null; }
        if (!this._pmTypingStartedFor || !this._pmTypingStartedFor.has(convKey)) return;
        if (this._typingStopTimer) clearTimeout(this._typingStopTimer);
        this._typingThrottleTime = 0;
        this._pmTypingStartedFor.delete(convKey);
        this._sendTypingEvent('stop');
    },

    async _sendTypingEvent(status) {
        if (!this._canSendGiftWraps()) return;

        const now = Math.floor(Date.now() / 1000);
        const tags = [['typing', status]];
        if (status === 'start') tags.push(['ttl', String(Math.floor(this._typingExpireMs / 1000))]);

        if (this.currentGroup) {
            const group = this.groupConversations.get(this.currentGroup);
            if (!group) return;
            tags.push(['g', this.currentGroup]);
            const otherMembers = group.members.filter(pk => pk !== this.pubkey);
            if (otherMembers.length === 0) return;

            const rumor = { kind: 69420, created_at: now, tags, content: '', pubkey: this.pubkey };
            // Ephemeral keys so typing wraps don't expose the real-pubkey membership set to relays.
            await this._sendGiftWrapsAsync(otherMembers, rumor, null, this.currentGroup);
        } else if (this.currentPM) {
            if (this.botAnonSuppressSendTo && this.botAnonSuppressSendTo(this.currentPM)) return;
            tags.push(['p', this.currentPM]);
            const rumor = { kind: 69420, created_at: now, tags, content: '', pubkey: this.pubkey };
            if (this.privkey) {
                const wrapped = await this._pmSignalWrapAsync(rumor, this.currentPM);
                this.sendDMToRelays(['EVENT', wrapped]);
            } else {
                await this._sendGiftWrapsAsync([this.currentPM], rumor, null);
            }
        }
    },

    handleTypingIndicatorEvent(parsed, senderPubkey, senderVerified = true) {
        if (!parsed || senderPubkey === this.pubkey) return;
        if (senderVerified !== true) return;
        if (parsed.groupId) {
            const group = this.groupConversations && this.groupConversations.get(parsed.groupId);
            if (!group) return;
            const isMember = group.createdBy === senderPubkey
                || (Array.isArray(group.members) && group.members.includes(senderPubkey));
            if (!isMember) return;
        }

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
            const existing = convTypers.get(senderPubkey);
            if (existing && existing.timeout) clearTimeout(existing.timeout);

            const nym = this.getNymFromPubkey(senderPubkey);

            const ttlMs = parsed.ttl ? Math.min(parsed.ttl * 1000, this._typingExpireMax)
                : this._typingExpireMs;
            const timeout = setTimeout(() => {
                convTypers.delete(senderPubkey);
                this.renderTypingIndicator();
            }, ttlMs);

            convTypers.set(senderPubkey, { nym, timeout, timestamp: Date.now(), ttlMs });
        }

        this.renderTypingIndicator();
    },

    renderTypingIndicator() {
        if (this._cvActive && typeof this._cvRenderTyping === 'function') { this._cvRenderTyping(); return; }
        this._renderTypingInto(
            document.getElementById('typingIndicator'),
            document.getElementById('typingIndicatorAvatars'),
            document.getElementById('typingIndicatorText'),
            this._activeTypingConvKey()
        );
    },

    _activeTypingConvKey() {
        if (this.inPMMode && this.currentGroup) return this.getGroupConversationKey(this.currentGroup);
        if (this.inPMMode && this.currentPM) return this.getPMConversationKey(this.currentPM);
        if (!this.inPMMode && this.currentGeohash) return `channel-${this.currentGeohash}`;
        return null;
    },

    _renderTypingInto(el, avatarsEl, textEl, convKey) {
        if (!el || !avatarsEl || !textEl) return;

        const convTypers = convKey ? this.typingUsers.get(convKey) : null;

        if (convTypers) {
            const now = Date.now();
            for (const [pk, entry] of convTypers) {
                if (now - entry.timestamp > (entry.ttlMs || this._typingExpireMs)) {
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

        // Diff against existing avatars so re-renders don't refetch and flicker.
        const visibleTypers = typers.slice(0, 3);
        const desiredKeys = visibleTypers.map(([pk]) => pk);
        const existing = Array.from(avatarsEl.querySelectorAll('img[data-avatar-pubkey]'));
        const existingKeys = existing.map(img => img.dataset.avatarPubkey || '');
        const sameLength = existingKeys.length === desiredKeys.length;
        const sameOrder = sameLength && desiredKeys.every((pk, i) => this._safePubkey(pk) === existingKeys[i]);
        if (!sameOrder) {
            const byKey = new Map();
            for (const img of existing) byKey.set(img.dataset.avatarPubkey, img);
            avatarsEl.innerHTML = '';
            for (const pk of desiredKeys) {
                const sk = this._safePubkey(pk);
                const reuse = byKey.get(sk);
                if (reuse) {
                    avatarsEl.appendChild(reuse);
                } else {
                    const img = document.createElement('img');
                    img.src = this.getAvatarUrl(pk);
                    img.dataset.avatarPubkey = sk;
                    img.alt = '';
                    img.loading = 'lazy';
                    avatarsEl.appendChild(img);
                }
            }
        }

        const fmtTyper = (pk, nym) => {
            const flair = (typeof this.getFlairForUser === 'function' && this.getFlairForUser(pk)) || '';
            const m = String(nym || '').match(/#([0-9a-f]{4})$/i);
            if (!m) return `${this.escapeHtml(nym || '')}${flair}`;
            return `${this.escapeHtml(nym.slice(0, -5))}<span class="nym-suffix">#${m[1]}</span>${flair}`;
        };
        if (typers.length === 1) {
            const verb = this.isVerifiedBot(typers[0][0]) ? 'thinking' : 'typing';
            textEl.innerHTML = `${fmtTyper(typers[0][0], typers[0][1].nym)} is ${verb}`;
        } else if (typers.length === 2) {
            textEl.innerHTML = `${fmtTyper(typers[0][0], typers[0][1].nym)} and ${fmtTyper(typers[1][0], typers[1][1].nym)} are typing`;
        } else {
            textEl.textContent = `${typers.length} people are typing`;
        }

        el.classList.add('active');
    },

    isNymReceipt(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'receipt' && (t[1] === 'delivered' || t[1] === 'read'));
    },

    parseNymReceipt(rumor) {
        if (!rumor || !rumor.tags) return null;

        const messageIds = [];
        let receiptType = null;

        for (const tag of rumor.tags) {
            if (Array.isArray(tag)) {
                if (tag[0] === 'x' && tag[1]) {
                    messageIds.push(tag[1]);
                } else if (tag[0] === 'receipt' && tag[1]) {
                    receiptType = tag[1];
                }
            }
        }

        if (messageIds.length && receiptType) {
            return { messageId: messageIds[0], messageIds, receiptType };
        }
        return null;
    },

    // Kinds 24420 (typing) and 24421 (read receipts) are ephemeral; relays don't store them.
    _canPublishChannelEvent() {
        if (!this.connected || !this.pubkey) return false;
        return !!this.privkey
            || !!(window.nostr?.signEvent)
            || (this.nostrLoginMethod === 'nip46' && typeof _nip46State !== 'undefined' && _nip46State && _nip46State.connected);
    },

    async _sendChannelTypingEvent(status, geohash) {
        if (!geohash || !this._canPublishChannelEvent()) return;
        const wire = this.channelWire(geohash);
        const event = {
            kind: 24420,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['typing', status],
                [wire.tag, geohash],
                ['n', this.nym]
            ],
            content: '',
            pubkey: this.pubkey
        };
        try {
            const signed = await this.signEvent(event);
            this.sendToRelay(["EVENT", signed]);
            if (wire.isGeohash) this.ensureGeoRelayDelivery(signed, geohash);
        } catch (_) { }
    },

    handleChannelTypingSignal() {
        if (!this.isTypingIndicatorAllowedFor('channel')) return;
        if (this.inPMMode || !this.currentGeohash) return;
        if (!this._canPublishChannelEvent()) return;

        const now = Date.now();
        if (now - this._typingThrottleTime < this._typingSendInterval) return;
        this._typingThrottleTime = now;

        if (this._typingStopTimer) clearTimeout(this._typingStopTimer);
        const geohash = this.currentGeohash;
        if (!this._channelTypingStartedFor) this._channelTypingStartedFor = new Set();
        this._channelTypingStartedFor.add(geohash);
        this._sendChannelTypingEvent('start', geohash);
        this._typingStopTimer = setTimeout(() => {
            if (this._channelTypingStartedFor) this._channelTypingStartedFor.delete(geohash);
            this._sendChannelTypingEvent('stop', geohash);
        }, 4000);
    },

    sendChannelTypingStop(geohash) {
        const targetGeohash = geohash || this.currentGeohash;
        if (!targetGeohash) return;
        // Only emit 'stop' if we emitted a 'start' for this geohash.
        if (!this._channelTypingStartedFor || !this._channelTypingStartedFor.has(targetGeohash)) return;
        if (!this.isTypingIndicatorAllowedFor('channel')) return;
        if (!this._canPublishChannelEvent()) return;
        if (this._typingStopTimer) clearTimeout(this._typingStopTimer);
        this._typingThrottleTime = 0;
        this._channelTypingStartedFor.delete(targetGeohash);
        this._sendChannelTypingEvent('stop', targetGeohash);
    },

    handleChannelTypingEvent(event) {
        if (!event || event.pubkey === this.pubkey) return;
        if (!this.isTypingIndicatorAllowedFor('channel')) return;

        const ageMs = Date.now() - (event.created_at || 0) * 1000;
        if (ageMs > this._typingExpireMs) return;

        let status = null, geohash = null, rawNym = null;
        for (const tag of event.tags) {
            if (!Array.isArray(tag)) continue;
            if (tag[0] === 'typing') status = tag[1];
            else if (tag[0] === 'g' || tag[0] === 'd') geohash = tag[1];
            else if (tag[0] === 'n') rawNym = tag[1];
        }
        if (!status || !geohash) return;
        const baseNym = this.stripPubkeySuffix(rawNym || this.getNymFromPubkey(event.pubkey));
        const displayNym = `${baseNym}#${this.getPubkeySuffix(event.pubkey)}`;
        if (this.blockedUsers.has(event.pubkey)) return;

        const convKey = `channel-${geohash}`;
        if (!this.typingUsers.has(convKey)) this.typingUsers.set(convKey, new Map());
        const convTypers = this.typingUsers.get(convKey);

        if (status === 'stop') {
            const entry = convTypers.get(event.pubkey);
            if (entry && entry.timeout) clearTimeout(entry.timeout);
            convTypers.delete(event.pubkey);
        } else {
            const existing = convTypers.get(event.pubkey);
            if (existing && existing.timeout) clearTimeout(existing.timeout);
            const timeout = setTimeout(() => {
                convTypers.delete(event.pubkey);
                this.renderTypingIndicator();
            }, this._typingExpireMs);
            convTypers.set(event.pubkey, { nym: displayNym, timeout, timestamp: Date.now() });
        }
        this.renderTypingIndicator();
    },

    async sendChannelReadReceipt(messageId, authorPubkey, geohash) {
        if (!this.isReadReceiptAllowedFor('channel')) return;
        if (!messageId || !authorPubkey || !geohash) return;
        if (authorPubkey === this.pubkey) return;
        if (!this._canPublishChannelEvent()) return;

        if (!this._sentChannelReadReceipts) this._sentChannelReadReceipts = new Set();
        if (this._sentChannelReadReceipts.has(messageId)) return;
        this._sentChannelReadReceipts.add(messageId);
        if (this._sentChannelReadReceipts.size > 2000) {
            const arr = Array.from(this._sentChannelReadReceipts);
            this._sentChannelReadReceipts = new Set(arr.slice(-1500));
        }

        const wire = this.channelWire(geohash);
        const event = {
            kind: 24421,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['e', messageId],
                ['p', authorPubkey],
                [wire.tag, geohash],
                ['n', this.nym]
            ],
            content: '',
            pubkey: this.pubkey
        };
        try {
            const signed = await this.signEvent(event);
            this.sendToRelay(["EVENT", signed]);
        } catch (_) { }
    },

    markVisibleChannelMessagesRead() {
        if (this.inPMMode || !this.currentGeohash) return;
        if (document.hidden || this.userScrolledUp) return;
        if (!this.isReadReceiptAllowedFor('channel')) return;
        if (!this._canPublishChannelEvent()) return;
        const messages = this.messages.get(`#${this.currentGeohash}`);
        if (!messages || !messages.length) return;
        const geohash = this.currentGeohash;
        for (const m of messages.slice(-this.channelPageSize)) {
            if (!m || m.isOwn || m.isHistorical) continue;
            if (!m.id || !/^[0-9a-f]{64}$/i.test(m.id)) continue;
            this.sendChannelReadReceipt(m.id, m.pubkey, m.geohash || geohash);
        }
    },

    handleChannelReadReceipt(event) {
        if (!event || event.pubkey === this.pubkey) return;

        const ageMs = Date.now() - (event.created_at || 0) * 1000;
        if (ageMs > 5 * 60 * 1000) return;

        let messageId = null, geohash = null, rawNym = null;
        for (const tag of event.tags) {
            if (!Array.isArray(tag)) continue;
            if (tag[0] === 'e') messageId = tag[1];
            else if (tag[0] === 'g' || tag[0] === 'd') geohash = tag[1];
            else if (tag[0] === 'n') rawNym = tag[1];
        }
        if (!messageId || !geohash) return;
        const readerName = this.stripPubkeySuffix(rawNym || this.getNymFromPubkey(event.pubkey));
        if (this.blockedUsers.has(event.pubkey)) return;

        this._markNymchatPubkey(event.pubkey);
        if (typeof this._observeNymchatPubkey === 'function') {
            this._observeNymchatPubkey(event.pubkey);
        }

        if (!this.channelMessageReaders.has(messageId)) {
            this.channelMessageReaders.set(messageId, new Map());
        }
        this.channelMessageReaders.get(messageId).set(event.pubkey, readerName);

        // Keyed by the receipt's geohash so this works regardless of which channel is focused.
        if (this.channelDOMCache) this.channelDOMCache.delete(`#${geohash}`);
        if (typeof this.updateChannelReaderAvatars === 'function') {
            this.updateChannelReaderAvatars(messageId, geohash);
        }
    },

    isNymMessage(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'x' && t[1] && !this.isNymReceipt(rumor));
    },

    getNymMessageId(rumor) {
        if (!rumor || !rumor.tags) return null;
        const xTag = rumor.tags.find(t => Array.isArray(t) && t[0] === 'x' && t[1]);
        return xTag ? xTag[1] : null;
    },

    encryptBitchat(plaintext, senderPrivateKey, recipientPublicKey) {
        return window.NymCrypto.encryptBitchat(plaintext, senderPrivateKey, recipientPublicKey);
    },

    nip59WrapEvent(event, senderPrivateKey, recipientPublicKey, expirationTs = null) {
        return window.NymCrypto.nip59Wrap(event, senderPrivateKey, recipientPublicKey, expirationTs);
    },

    // `expirationTs` is accepted and NOT forwarded; see bitchatWrap.
    async bitchatWrapEventAsync(event, senderPrivateKey, recipientPublicKey, expirationTs = null) {
        return this._cryptoCall('bitchatWrap', [event, senderPrivateKey, recipientPublicKey],
            () => window.NymCrypto.bitchatWrap(event, senderPrivateKey, recipientPublicKey));
    },

    async nip59WrapEventAsync(event, senderPrivateKey, recipientPublicKey, expirationTs = null, extraTags = null) {
        const args = [event, senderPrivateKey, recipientPublicKey, expirationTs ?? null];
        if (Array.isArray(extraTags) && extraTags.length) args.push(extraTags);
        return this._cryptoCall('nip59Wrap', args, () => window.NymCrypto.nip59Wrap(...args));
    },

    // Offloaded because group fan-out does one ML-KEM encapsulation per member.
    async pqNip59WrapEventAsync(event, senderPrivateKey, recipientPublicKey, recipientKemPublicKey, expirationTs = null, extraTags = null) {
        const args = [event, senderPrivateKey, recipientPublicKey, recipientKemPublicKey, expirationTs ?? null];
        if (Array.isArray(extraTags) && extraTags.length) args.push(extraTags);
        return this._cryptoCall('pqNip59Wrap', args, () => window.NymCrypto.pqNip59Wrap(...args));
    },

    // The layered wrap; only the framing differs.
    async pq2Nip59WrapEventAsync(event, senderPrivateKey, recipientPublicKey, recipientKemPublicKey, expirationTs = null, extraTags = null) {
        const args = [event, senderPrivateKey, recipientPublicKey, recipientKemPublicKey, expirationTs ?? null];
        if (Array.isArray(extraTags) && extraTags.length) args.push(extraTags);
        return this._cryptoCall('pq2Nip59Wrap', args, () => window.NymCrypto.pq2Nip59Wrap(...args));
    },

    // `usePq2` comes from the recipient's announcement, never from a guess.
    async pqWrapForPeerAsync(usePq2, event, senderPrivateKey, recipientPublicKey, recipientKemPublicKey, expirationTs = null, extraTags = null) {
        return usePq2
            ? this.pq2Nip59WrapEventAsync(event, senderPrivateKey, recipientPublicKey, recipientKemPublicKey, expirationTs, extraTags)
            : this.pqNip59WrapEventAsync(event, senderPrivateKey, recipientPublicKey, recipientKemPublicKey, expirationTs, extraTags);
    },

    requestUserProfile(pubkey) {
        try {
            this.fetchProfileFromRelay(pubkey);
        } catch (_) { }
    },

    // The main subscription excludes kind 0, so poll when the user opens or receives a PM.
    refreshUserProfileThrottled(pubkey, throttleMs = 60000) {
        if (!pubkey) return;
        if (!this._profileRefreshAttempts) this._profileRefreshAttempts = new Map();
        const now = Date.now();
        const last = this._profileRefreshAttempts.get(pubkey) || 0;
        if (now - last < throttleMs) return;
        this._profileRefreshAttempts.set(pubkey, now);
        try { this.fetchProfileFromRelay(pubkey); } catch (_) { }
    },

    // Routes through the batched queue so concurrent callers share one REQ (per-relay concurrency limits).
    async fetchProfileDirect(pubkey) {
        if (!pubkey) return;

        const lastFetch = (this.profileFetchedAt && this.profileFetchedAt.get(pubkey)) || 0;
        if (Date.now() - lastFetch < 5 * 60 * 1000) return;

        return new Promise(resolve => {
            if (!this.pendingProfileResolvers.has(pubkey)) {
                this.pendingProfileResolvers.set(pubkey, []);
            }
            const timer = setTimeout(() => {
                this._removeProfileResolver(pubkey, entry);
                resolve();
            }, 2500);
            const entry = { resolve, timer };
            this.pendingProfileResolvers.get(pubkey).push(entry);
            try { this.queueProfileFetch(pubkey); } catch (_) { resolve(); }
        });
    },

    // D1 first, then a direct relay REQ, so a Nostr user new to Nymchat doesn't show the "nym" fallback.
    async fetchOwnProfileFromRelaysOneShot() {
        const pubkey = this.pubkey;
        if (!pubkey || !/^[0-9a-f]{64}$/.test(pubkey)) return;

        try {
            const found = await this._fetchProfilesFromD1([pubkey]);
            if (found && found.has(pubkey)) { this._updateOwnSidebarProfile(); return; }
        } catch (_) { }

        // sendRequestToFewRelays routes through the pool in proxy mode and directly otherwise.
        if (!this.connected) {
            if (!this._ownProfileFetchRetries) this._ownProfileFetchRetries = 0;
            if (this._ownProfileFetchRetries++ < 8) {
                setTimeout(() => { this.fetchOwnProfileFromRelaysOneShot(); }, 1500);
            }
            return;
        }

        const subId = 'own-profile-' + Math.random().toString(36).slice(2);
        if (!this._subscriptionHandlers) this._subscriptionHandlers = new Map();

        let settled = false;
        const cleanup = () => {
            if (settled) return;
            settled = true;
            this._subscriptionHandlers.delete(subId);
            try { this.closeFewRelaysSub(subId); } catch (_) { }
            if (typeof this._oneShotReqDone === 'function') this._oneShotReqDone();
        };

        const handler = (type, data) => {
            if (type === 'EVENT' && data[0] === subId) {
                const event = data[1];
                if (event && event.kind === 0 && event.pubkey === pubkey) {
                    // Refresh the sidebar after the dispatcher's synchronous handleEvent completes.
                    setTimeout(() => this._updateOwnSidebarProfile(), 0);
                    cleanup();
                }
            } else if (type === 'EOSE' && data[0] === subId) {
                cleanup();
            }
        };
        this._subscriptionHandlers.set(subId, handler);

        const req = ['REQ', subId, { kinds: [0], authors: [pubkey], limit: 1 }];
        const run = () => {
            try { this.sendRequestToFewRelays(req); } catch (_) { }
            setTimeout(cleanup, 3000);
        };
        if (typeof this._oneShotReqAcquire === 'function') this._oneShotReqAcquire(run);
        else run();
    },

    _updateOwnSidebarProfile() {
        const pubkey = this.pubkey;
        if (!pubkey) return;
        const user = this.users.get(pubkey);
        if (user && user.nym) this.nym = user.nym;
        if (this.nym) {
            const el = document.getElementById('currentNym');
            if (el) el.innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
        }
        if (typeof this.updateSidebarAvatar === 'function') this.updateSidebarAvatar();
        if (typeof this.loadLightningAddress === 'function') this.loadLightningAddress();
        try {
            const avatarUrl = this.userAvatars.get(pubkey);
            if (this.nym || avatarUrl) {
                localStorage.setItem('nym_nostr_login_profile', JSON.stringify({
                    name: this.nym || null,
                    avatar: avatarUrl || null
                }));
            }
        } catch (_) { }
    },

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

    // Batched within 150ms, fire-and-forget; the kind 0 handler updates renders retroactively.
    queueProfileFetch(pubkey) {
        const lastFetch = this.profileFetchedAt && this.profileFetchedAt.get(pubkey) || 0;
        const fresh = Date.now() - lastFetch < 5 * 60 * 1000;
        const appliedKind0 = this._kind0Ts && this._kind0Ts.has(pubkey);
        if (fresh && appliedKind0 && this.userAvatars && this.userAvatars.has(pubkey)
            && this.hasResolvedNym(pubkey)) return;

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

    async _flushProfileBatch() {
        const pubkeys = this._profileBatchQueue;
        this._profileBatchQueue = [];
        this._profileBatchSet = new Set();
        this._profileBatchTimer = null;
        if (pubkeys.length === 0) return;

        // D1 first; fall back to a relay REQ for anyone not stored there.
        let missing = pubkeys;
        try {
            const found = await this._fetchProfilesFromD1(pubkeys);
            if (found && found.size) {
                missing = pubkeys.filter(pk => !found.has(pk) || !this.hasResolvedNym(pk));
            }
        } catch (_) { }
        if (missing.length === 0) return;

        // D1 only holds owner-mirrored profiles, so a miss is normal; relay REQs are rate-limited per pubkey.
        if (!this._profileRelayAttemptAt) this._profileRelayAttemptAt = new Map();
        const nowMs = Date.now();
        missing = missing.filter(pk => nowMs - (this._profileRelayAttemptAt.get(pk) || 0) >= 5 * 60 * 1000);
        if (missing.length === 0) return;
        for (const pk of missing) this._profileRelayAttemptAt.set(pk, nowMs);
        // Map keeps insertion order, so the oldest attempt is evicted.
        while (this._profileRelayAttemptAt.size > 5000) {
            this._profileRelayAttemptAt.delete(this._profileRelayAttemptAt.keys().next().value);
        }

        const run = () => {
            const subId = 'batch-profile-' + Math.random().toString(36).slice(2);
            const req = ["REQ", subId, { kinds: [0], authors: missing, limit: missing.length }];
            try { this.sendRequestToFewRelays(req); } catch (_) { }

            setTimeout(() => {
                try { this.closeFewRelaysSub(subId); } catch (_) { }
                if (typeof this._oneShotReqDone === 'function') this._oneShotReqDone();
            }, 2500);
        };

        if (typeof this._oneShotReqAcquire === 'function') {
            this._oneShotReqAcquire(run);
        } else {
            run();
        }
    },

    async generateKeypair() {
        try {
            const sk = window.NostrTools.generateSecretKey();
            const pk = window.NostrTools.getPublicKey(sk);

            const switched = this.pubkey !== pk;
            this.privkey = sk;
            this.pubkey = pk;
            if (switched && typeof this.pqResetIdentityState === 'function') this.pqResetIdentityState();


            return { privkey: sk, pubkey: pk };
        } catch (error) {
            throw error;
        }
    },

    async signEvent(event) {
        // NIP-07 extension signing (e.g. nos2x, Alby).
        if (this.nostrLoginMethod === 'extension' && window.nostr?.signEvent) {
            const unsigned = {
                kind: event.kind,
                created_at: event.created_at,
                tags: event.tags,
                content: event.content,
            };
            const signed = await window.nostr.signEvent(unsigned);
            return signed;
        }
        // NIP-46 remote signer.
        if (this.nostrLoginMethod === 'nip46' && _nip46State && _nip46State.connected) {
            return await _nip46SignEvent(event);
        }
        if (this.privkey) {
            return window.NostrTools.finalizeEvent(event, this.privkey);
        } else {
            throw new Error('No signing method available');
        }
    },

    // Channel objects are author-verified via the signed kind 5; PM objects sit under our own prefix.
    async _propagateDeletionToD1(deletionEvent, messageId, originalKind) {
        try {
            if (!this._getApiHost || !this._getApiHost()) return;

            let channelName = null;
            if (this.messages) {
                for (const [key, msgs] of this.messages.entries()) {
                    if (Array.isArray(msgs) && msgs.some(m => m && m.id === messageId)) {
                        channelName = key.startsWith('#') ? key.slice(1) : key;
                        break;
                    }
                }
            }
            if (channelName) {
                this._storageApiRequest('channel-delete', { channel: channelName, deletionEvent }, false).catch(() => { });
            }

            // PM/group wraps we archived are keyed by their gift-wrap event ids.
            if (originalKind === 1059 && this._pmArchiveAllowed && this._pmArchiveAllowed()) {
                const ids = new Set([messageId]);
                const wraps = this._giftWrapsForSharedId && this._giftWrapsForSharedId.get(messageId);
                if (wraps) for (const w of wraps) ids.add(w);
                this._storageApiRequest('pm-delete', { ids: Array.from(ids) }).catch(() => { });
            }
        } catch (_) { }
    },

    async publishDeletionEvent(messageId, originalKind) {
        try {
            const tags = [['e', messageId]];
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

            // Mirror to D1 so the event doesn't resurrect on reload or another device.
            this._propagateDeletionToD1(signedEvent, messageId, originalKind);

            this.deletedEventIds.add(messageId);

            // Capture both ids (bubbles use nymMessageId) so a late re-render can't resurrect it.
            this.pmMessages.forEach(msgs => {
                for (const m of msgs) {
                    if (m.id === messageId || m.nymMessageId === messageId) {
                        if (m.id) this.deletedEventIds.add(m.id);
                        if (m.nymMessageId) this.deletedEventIds.add(m.nymMessageId);
                    }
                }
            });
            if (typeof this.persistDedupSets === 'function') this.persistDedupSets();

            // Delete every gift-wrap event id sent for this shared id so relays drop them from storage.
            if (originalKind === 1059 && this._giftWrapsForSharedId) {
                const wrapIds = this._giftWrapsForSharedId.get(messageId);
                if (wrapIds && wrapIds.size > 0) {
                    for (const wrapId of wrapIds) {
                        if (wrapId === messageId) continue;
                        if (this.deletedEventIds.has(wrapId)) continue;
                        const wrapEvent = {
                            kind: 5,
                            created_at: Math.floor(Date.now() / 1000),
                            tags: [['e', wrapId], ['k', '1059']],
                            content: '',
                            pubkey: this.pubkey
                        };
                        try {
                            const signedWrapDelete = await this.signEvent(wrapEvent);
                            this.sendToRelay(['EVENT', signedWrapDelete]);
                            this.deletedEventIds.add(wrapId);
                        } catch (_) { }
                    }
                    this._giftWrapsForSharedId.delete(messageId);
                }
            }

            const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
            if (messageEl) {
                if (typeof this._playMessageDisintegration !== 'function' || !this._playMessageDisintegration(messageEl)) {
                    messageEl.remove();
                }
            }

            this.messages.forEach((msgs, channel) => {
                const idx = msgs.findIndex(m => m.id === messageId);
                if (idx !== -1) {
                    msgs.splice(idx, 1);
                    this.persistChannelMessages(channel);
                }
            });

            this.pmMessages.forEach((msgs, convKey) => {
                let removed = false;
                for (let i = msgs.length - 1; i >= 0; i--) {
                    if (msgs[i].id === messageId || msgs[i].nymMessageId === messageId) {
                        msgs.splice(i, 1);
                        removed = true;
                    }
                }
                if (removed) {
                    this.channelDOMCache.delete(convKey);
                    this.persistPMMessages(convKey);
                }
            });
        } catch (error) {
            this.displaySystemMessage('Failed to delete message: ' + error.message);
        }
    },

    handleDeletionEvent(event) {
        // NIP-09: only the original author may delete an event.
        const eTags = (event.tags || []).filter(t => Array.isArray(t) && t[0] === 'e' && t[1]);
        if (eTags.length === 0) return;
        const requesterPubkey = event.pubkey;
        if (!requesterPubkey) return;

        for (const eTag of eTags) {
            const deletedId = eTag[1];
            const originalAuthor = this._findMessageAuthor(deletedId, requesterPubkey);

            if (!originalAuthor) {
                if (!this._pendingDeletions) this._pendingDeletions = new Map();
                let claimants = this._pendingDeletions.get(deletedId);
                if (!claimants) {
                    claimants = new Set();
                    this._pendingDeletions.set(deletedId, claimants);
                }
                claimants.add(requesterPubkey);
                if (this._pendingDeletions.size > 5000) {
                    const entries = Array.from(this._pendingDeletions.entries());
                    this._pendingDeletions = new Map(entries.slice(-4000));
                }
                continue;
            }

            this._applyVerifiedDeletion(deletedId, requesterPubkey);
        }
    },

    _findMessageAuthor(id, pubkey) {
        if (!id) return null;
        const matches = (m, byNymId) => m && (m.id === id || (byNymId && m.nymMessageId === id))
            && (!pubkey || m.pubkey === pubkey);
        if (this.messages) {
            for (const msgs of this.messages.values()) {
                for (const m of msgs) {
                    if (matches(m, false)) return m.pubkey || null;
                }
            }
        }
        if (this.pmMessages) {
            for (const msgs of this.pmMessages.values()) {
                for (const m of msgs) {
                    if (matches(m, true)) return m.pubkey || null;
                }
            }
        }
        return null;
    },

    _authorDeletionKey(pubkey, id) {
        return `${pubkey}:${id}`;
    },

    _isMessageDeleted(m) {
        if (!m || !this.deletedEventIds) return false;
        if (m.id && this.deletedEventIds.has(m.id)) return true;
        if (!m.nymMessageId) return false;
        if (this.deletedEventIds.has(m.nymMessageId)) return true;
        return !!m.pubkey && this.deletedEventIds.has(this._authorDeletionKey(m.pubkey, m.nymMessageId));
    },

    _applyVerifiedDeletion(deletedId, authorPubkey) {
        const scoped = typeof authorPubkey === 'string' && authorPubkey.length > 0;
        const channelMatch = (m) => m && m.id === deletedId && (!scoped || m.pubkey === authorPubkey);
        const pmMatch = (m) => m && (scoped
            ? ((m.id === deletedId || m.nymMessageId === deletedId) && m.pubkey === authorPubkey)
            : m.id === deletedId);

        if (!scoped) this.deletedEventIds.add(deletedId);

        const domIds = new Set();
        this.messages.forEach(msgs => {
            for (const m of msgs) {
                if (channelMatch(m)) {
                    this.deletedEventIds.add(m.id);
                    domIds.add(m.id);
                }
            }
        });
        this.pmMessages.forEach(msgs => {
            for (const m of msgs) {
                if (!pmMatch(m)) continue;
                if (m.id) this.deletedEventIds.add(m.id);
                if (m.nymMessageId) {
                    this.deletedEventIds.add(this._authorDeletionKey(m.pubkey, m.nymMessageId));
                }
                domIds.add(m.nymMessageId || m.id);
            }
        });
        if (scoped && domIds.size === 0) {
            this.deletedEventIds.add(this._authorDeletionKey(authorPubkey, deletedId));
        }

        if (typeof this.persistDedupSets === 'function') this.persistDedupSets();

        if (this.deletedEventIds.size > 5000) {
            const arr = Array.from(this.deletedEventIds);
            this.deletedEventIds = new Set(arr.slice(-4000));
        }

        if (!scoped) domIds.add(deletedId);
        if (typeof document !== 'undefined' && document.querySelectorAll) {
            for (const domId of domIds) {
                const sel = `[data-message-id="${(typeof CSS !== 'undefined' && CSS.escape) ? CSS.escape(domId) : domId}"]`;
                document.querySelectorAll(sel).forEach(messageEl => {
                    if (scoped && messageEl.dataset && messageEl.dataset.pubkey !== authorPubkey) return;
                    if (typeof this._playMessageDisintegration !== 'function' || !this._playMessageDisintegration(messageEl)) {
                        messageEl.remove();
                    }
                });
            }
        }

        this.messages.forEach((msgs, channel) => {
            const idx = msgs.findIndex(channelMatch);
            if (idx !== -1) {
                msgs.splice(idx, 1);
                this.persistChannelMessages(channel);
                // Re-derive rather than bump: updateUnreadCount would add one for a removed message.
                if (typeof this.refreshUnreadCount === 'function') {
                    this.refreshUnreadCount(channel);
                }
            }
        });

        this.pmMessages.forEach((msgs, convKey) => {
            let removed = false;
            for (let i = msgs.length - 1; i >= 0; i--) {
                if (pmMatch(msgs[i])) {
                    msgs.splice(i, 1);
                    removed = true;
                }
            }
            if (removed) {
                this.channelDOMCache.delete(convKey);
                this.persistPMMessages(convKey);
                if (typeof this.refreshUnreadCount === 'function') {
                    this.refreshUnreadCount(convKey);
                }
            }
        });
    },

    _consumePendingDeletion(message) {
        if (!this._pendingDeletions || !message || !message.pubkey) return false;
        const ids = [message.id];
        if (message.nymMessageId) ids.push(message.nymMessageId);
        for (const id of ids) {
            if (!id) continue;
            const claimants = this._pendingDeletions.get(id);
            if (claimants && claimants.has(message.pubkey)) {
                claimants.delete(message.pubkey);
                if (claimants.size === 0) this._pendingDeletions.delete(id);
                if (message.id) this.deletedEventIds.add(message.id);
                if (message.nymMessageId) {
                    this.deletedEventIds.add(this._authorDeletionKey(message.pubkey, message.nymMessageId));
                }
                if (typeof this.persistDedupSets === 'function') this.persistDedupSets();
                return true;
            }
        }
        return false;
    },

    _takeEdit(key, senderPubkey, cand, msg) {
        const T = window.NymChatTools;
        const existing = this.editedMessages.get(key);
        const mine = existing && existing.senderPubkey === senderPubkey ? existing : null;
        const cur = mine ? { text: mine.newContent, at: Number(mine.editAt) || 0, id: mine.editEventId || '' } : null;
        const verdict = T ? T.editVerdict(cur, cand, msg ? msg.created_at : 0) : 'apply';
        if (verdict === 'apply') {
            const stale = mine && Array.isArray(mine.stale) ? mine.stale.slice() : [];
            if (cur && !msg) stale.push({ text: cur.text, at: cur.at });
            const max = T ? T.LIMITS.editVersionsMax : 20;
            this.editedMessages.set(key, {
                newContent: cand.text,
                editEventId: cand.id || null,
                senderPubkey,
                senderVerified: true,
                timestamp: new Date(),
                editAt: cand.at,
                stale: stale.slice(-max)
            });
        } else if (verdict === 'stale') {
            if (msg) {
                if (typeof this._noteStaleEdit === 'function') this._noteStaleEdit(msg, cand.text, cand.at);
            } else {
                const max = T ? T.LIMITS.editVersionsMax : 20;
                mine.stale = (Array.isArray(mine.stale) ? mine.stale : []).concat([{ text: cand.text, at: cand.at }]).slice(-max);
            }
        }

        if (this.editedMessages.size > 5000) {
            const entries = Array.from(this.editedMessages.entries());
            this.editedMessages = new Map(entries.slice(-4000));
        }
        return verdict === 'apply' || verdict === 'same';
    },

    handleIncomingEdit(originalEventId, newContent, senderPubkey, editEventId, editAt) {
        if (!originalEventId || !senderPubkey) return;
        const targets = [];
        this.messages.forEach((msgs, channel) => {
            const msg = msgs.find(m => m.id === originalEventId);
            if (msg && msg.pubkey === senderPubkey) targets.push([msg, channel]);
        });

        const cand = { text: newContent, at: Number(editAt) || 0, id: editEventId || '' };
        if (!this._takeEdit(`${senderPubkey}:${originalEventId}`, senderPubkey, cand, targets.length ? targets[0][0] : null)) return;
        if (!targets.length) return;

        for (const [msg, channel] of targets) {
            if (typeof this._noteEdit === 'function') this._noteEdit(msg, newContent, editAt);
            msg.content = newContent;
            msg.isEdited = true;
            this.persistChannelMessages(channel);
        }
        this.updateMessageInDOM(originalEventId, newContent);
    },

    handleIncomingPMEdit(originalId, newContent, senderPubkey, conversationKey, senderVerified = true, editAt = 0, editId = '') {
        if (senderVerified !== true || !originalId || !senderPubkey) return;
        const msgs = this.pmMessages.get(conversationKey);
        const msg = msgs ? msgs.find(m =>
            (m.nymMessageId === originalId || m.id === originalId) && m.pubkey === senderPubkey
        ) : null;

        const cand = { text: newContent, at: Number(editAt) || 0, id: editId || '' };
        if (!this._takeEdit(`${senderPubkey}:${originalId}`, senderPubkey, cand, msg)) return;
        if (!msg) return;

        if (typeof this._noteEdit === 'function') this._noteEdit(msg, newContent, editAt);
        msg.content = newContent;
        msg.isEdited = true;
        this.persistPMMessages(conversationKey);

        const domId = msg.nymMessageId || msg.id;
        this.updateMessageInDOM(domId, newContent);
    },

    async processBatchedProfileFetch() {
        if (this.profileFetchQueue.length === 0) return;

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

        try {
            const fromD1 = await this._fetchProfilesFromD1(Array.from(pubkeyMap.keys()));
            for (const pk of fromD1) {
                if (!this.hasResolvedNym(pk)) continue;
                const list = pubkeyMap.get(pk);
                if (list) { list.forEach(r => r()); pubkeyMap.delete(pk); }
            }
        } catch (_) { }
        // Bitchat users carry their nickname in the `n` tag and have no kind 0, so don't relay-fetch them.
        if (this.bitchatUsers) {
            for (const pk of [...pubkeyMap.keys()]) {
                if (this.bitchatUsers.has(pk)) {
                    const list = pubkeyMap.get(pk);
                    if (list) { list.forEach(r => r()); pubkeyMap.delete(pk); }
                }
            }
        }
        if (pubkeyMap.size === 0) return;

        if (!this._profileRelayAttemptAt) this._profileRelayAttemptAt = new Map();
        const attemptNow = Date.now();
        for (const pk of Array.from(pubkeyMap.keys())) {
            if (attemptNow - (this._profileRelayAttemptAt.get(pk) || 0) < 5 * 60 * 1000) {
                const list = pubkeyMap.get(pk);
                if (list) { list.forEach(r => r()); pubkeyMap.delete(pk); }
            }
        }
        if (pubkeyMap.size === 0) return;
        for (const pk of pubkeyMap.keys()) this._profileRelayAttemptAt.set(pk, attemptNow);
        while (this._profileRelayAttemptAt.size > 5000) {
            this._profileRelayAttemptAt.delete(this._profileRelayAttemptAt.keys().next().value);
        }

        const pubkeys = Array.from(pubkeyMap.keys());
        const resolvers = pubkeyMap;

        const subId = "profile-batch-" + Math.random().toString(36).substring(7);

        const timeout = setTimeout(() => {
            if (this._subscriptionHandlers) this._subscriptionHandlers.delete(subId);
            resolvers.forEach(resolveList => {
                resolveList.forEach(resolve => resolve());
            });
        }, 3000);
        if (!this._subscriptionHandlers) this._subscriptionHandlers = new Map();

        // A side-handler keyed by subId; normal event processing still runs.
        const profileHandler = (type, data) => {
            if (type === 'EVENT' && data[0] === subId) {
                const event = data[1];
                if (event && event.kind === 0 && resolvers.has(event.pubkey)) {
                    try {
                        const profile = JSON.parse(event.content);

                        const eventTs = (typeof event.created_at === 'number') ? event.created_at : 0;
                        if (!this._kind0Ts) this._kind0Ts = new Map();
                        const lastTs = this._kind0Ts.get(event.pubkey) || 0;
                        if (eventTs && lastTs && eventTs < lastTs) {
                            this._resolveProfileCallbacks(event.pubkey);
                            return;
                        }
                        if (eventTs > lastTs) this._kind0Ts.set(event.pubkey, eventTs);

                        this._cacheD1Profile(event.pubkey, event);

                        // Mirror our own profile to D1 so edits from other Nostr clients propagate.
                        if (event.pubkey === this.pubkey && event.id && event.sig
                            && event.id !== this._lastMirroredOwnProfileId && this._hasCustomProfileData()) {
                            this._saveProfileToD1(event);
                        }

                        if (event.pubkey === this.pubkey && (profile.name || profile.username || profile.display_name)) {
                            const profileName = profile.name || profile.username || profile.display_name;
                            this.nym = profileName.substring(0, 20);
                            const ownUser = this.users.get(this.pubkey);
                            if (ownUser) {
                                ownUser.nym = this.nym;
                            } else {
                                this.users.set(this.pubkey, {
                                    nym: this.nym,
                                    pubkey: this.pubkey,
                                    lastSeen: 0,
                                    status: 'online',
                                    channels: new Set()
                                });
                            }
                            const currentNymEl = document.getElementById('currentNym');
                            if (currentNymEl) currentNymEl.innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
                            this.updateSidebarAvatar();
                            if (typeof this.updateStoredNymsForPubkey === 'function') {
                                this.updateStoredNymsForPubkey(this.pubkey, this.nym);
                            }
                            this.updatePMNicknameFromProfile(this.pubkey, this.nym);
                        }

                        const _pickPic = (p) => {
                            const candidates = [p && p.picture, p && p.image, p && p.avatar];
                            for (const c of candidates) {
                                if (typeof c !== 'string') continue;
                                const trimmed = c.trim().replace(/^['"]|['"]$/g, '');
                                if (!trimmed) continue;
                                if (/^(https?:|data:image\/)/i.test(trimmed)) return trimmed;
                            }
                            return null;
                        };
                        const pictureUrl = _pickPic(profile);
                        if (pictureUrl) {
                            const prevUrl = this.userAvatars.get(event.pubkey);
                            if (prevUrl !== pictureUrl) {
                                const oldBlob = this.avatarBlobCache.get(event.pubkey);
                                if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(event.pubkey); }
                                if (typeof this.deleteCachedAvatar === 'function') this.deleteCachedAvatar(event.pubkey);
                                this.userAvatars.set(event.pubkey, pictureUrl);
                                this.cacheAvatarImage(event.pubkey, pictureUrl);
                                this.updateRenderedAvatars(event.pubkey, pictureUrl);
                            } else if (!this.avatarBlobCache.has(event.pubkey)) {
                                this.userAvatars.set(event.pubkey, pictureUrl);
                                this.cacheAvatarImage(event.pubkey, pictureUrl);
                            }
                        }

                        if (event.pubkey !== this.pubkey && (profile.name || profile.username || profile.display_name)) {
                            const profileName = (profile.name || profile.username || profile.display_name).substring(0, 20);
                            // Always accept the newer kind 0 as authoritative.
                            const existingUser = this.users.get(event.pubkey);
                            if (!existingUser) {
                                this.users.set(event.pubkey, {
                                    nym: profileName,
                                    pubkey: event.pubkey,
                                    lastSeen: 0,
                                    status: 'online',
                                    channels: new Set()
                                });
                                this.persistProfile(event.pubkey);
                            } else if (existingUser.nym !== profileName) {
                                existingUser.nym = profileName;
                                this.users.set(event.pubkey, existingUser);
                                this.persistProfile(event.pubkey);
                            }
                            if (typeof this.updateStoredNymsForPubkey === 'function') {
                                this.updateStoredNymsForPubkey(event.pubkey, profileName);
                            }
                            this.updatePMNicknameFromProfile(event.pubkey, profileName);
                            if (typeof this.updateGroupMembershipDisplay === 'function') {
                                this.updateGroupMembershipDisplay(event.pubkey);
                            }
                            if (typeof this.updateNotificationModalProfile === 'function') {
                                this.updateNotificationModalProfile(event.pubkey, profileName);
                            }
                            if (typeof this.updateRenderedProfileCard === 'function') {
                                this.updateRenderedProfileCard(event.pubkey);
                            }
                            if (typeof this.updateUserList === 'function') {
                                this.updateUserList();
                            }
                        }

                        if (event.pubkey === this.pubkey && (profile.lud16 || profile.lud06)) {
                            const lnAddress = profile.lud16 || profile.lud06;
                            this.lightningAddress = lnAddress;
                            localStorage.setItem(`nym_lightning_address_${this.pubkey}`, lnAddress);
                            this.updateLightningAddressDisplay();
                        }
                    } catch (e) {
                    }

                    const resolveList = resolvers.get(event.pubkey);
                    resolveList.forEach(resolve => resolve());
                    resolvers.delete(event.pubkey);
                }
            } else if (type === 'EOSE' && data[0] === subId) {
                clearTimeout(timeout);
                this._subscriptionHandlers.delete(subId);

                resolvers.forEach(resolveList => {
                    resolveList.forEach(resolve => resolve());
                });
            }
        };

        this._subscriptionHandlers.set(subId, profileHandler);

        const subscription = [
            "REQ",
            subId,
            {
                kinds: [0],
                authors: pubkeys,
                limit: pubkeys.length
            }
        ];

        if (this.connected) {
            const run = () => {
                this.sendRequestToFewRelays(subscription);
                setTimeout(() => {
                    try { this.closeFewRelaysSub(subId); } catch (_) { }
                    if (typeof this._oneShotReqDone === 'function') this._oneShotReqDone();
                }, 2500);
            };
            if (typeof this._oneShotReqAcquire === 'function') this._oneShotReqAcquire(run);
            else run();
        } else {
            this.messageQueue.push(JSON.stringify(subscription));
        }
    },

    // opts is the mesh-outbox.js replay seam; buildOnly returns the signed event without publishing.
    async publishMessage(content, channel = this.currentChannel, geohash = this.currentGeohash, quoteData = null, threadRoot = null, opts = null) {
        try {
            const buildOnly = !!(opts && opts.buildOnly);
            if (!this.connected && !buildOnly) {
                throw new Error('Not connected to relay');
            }

            const replayAt = opts && typeof opts.createdAt === 'number' && opts.createdAt > 0
                ? opts.createdAt : 0;
            const nowMs = replayAt ? replayAt * 1000 : Date.now();
            const now = replayAt || Math.floor(nowMs / 1000);
            const tags = [
                ['n', this.nym],
                ['ms', String(nowMs)]
            ];

            const channelKey = geohash || 'nymchat';
            const wire = this.channelWire(channelKey);
            const kind = wire.kind;
            tags.push([wire.tag, channelKey]);

            // NIP-10 marked root reference; other clients see a normal channel message.
            if (threadRoot && /^[0-9a-f]{64}$/i.test(threadRoot)) {
                tags.push(['e', threadRoot, '', 'root']);
            } else {
                threadRoot = null;
            }

            // Quotes go out as an @mention so other Nostr clients see a normal mention.
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

            // NIP-30 custom emoji.
            tags.push(...this.customEmojiTagsForContent(wireContent));

            // NIP-92 Blossom mirror URLs.
            if (typeof this.imetaTagsForContent === 'function') {
                tags.push(...this.imetaTagsForContent(wireContent));
            }

            if (opts && Array.isArray(opts.extraTags)) tags.push(...opts.extraTags);

            let event = {
                kind: kind,
                created_at: now,
                tags: tags,
                content: wireContent,
                pubkey: this.pubkey
            };

            const replayId = opts && typeof opts.localId === 'string' && opts.localId
                ? opts.localId : '';
            const tempId = replayId
                || ('_optim_' + Math.random().toString(36).slice(2) + nowMs.toString(36));
            const storageKey = geohash ? `#${geohash}` : channel;
            const optimisticMessage = {
                id: tempId,
                content: content,
                author: this.nym,
                pubkey: this.pubkey,
                created_at: now,
                _ms: nowMs,
                _seq: ++this._msgSeq,
                timestamp: new Date(now * 1000),
                channel: channel,
                geohash: geohash,
                isOwn: true,
                isHistorical: false,
                isPM: false,
                threadRoot: threadRoot || undefined,
                _optimistic: true,
                _storageKey: storageKey
            };

            if (buildOnly) {
                // The caller owns delivery; PoW still applies since a gateway publishes this event for us.
                if (typeof this.attachAttestTag === 'function') this.attachAttestTag(event);
                const difficulty = this._effectivePowDifficulty();
                if (difficulty > 0) event = await this._minePow(event, difficulty);
                return await this.signEvent(event);
            }

            // A replay already has its bubble from the mesh send.
            if (!replayId) this.displayMessage(optimisticMessage);
            this.recordOwnActivity();

            (async () => {
                try {
                    if (!replayId && typeof this.awaitAttestBadge === 'function') {
                        try { await this.awaitAttestBadge(); } catch (_) { }
                    }
                    if (typeof this.attachAttestTag === 'function') this.attachAttestTag(event);
                    const difficulty = this._effectivePowDifficulty();
                    if (difficulty > 0) event = await this._minePow(event, difficulty);
                    const signedEvent = await this.signEvent(event);
                    if (typeof this.recordEventProvenanceSource === 'function') {
                        this.recordEventProvenanceSource(signedEvent, 'THIS CLIENT');
                    }
                    this._replaceOptimisticMessage(tempId, signedEvent, storageKey, false);
                    this.sendToRelay(["EVENT", signedEvent]);
                    if (wire.isGeohash) this.ensureGeoRelayDelivery(signedEvent, channelKey);

                    if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                        const eventIdToDelete = signedEvent.id;
                        setTimeout(() => this.publishDeletionEvent(eventIdToDelete), 600000);
                    }
                } catch (err) {
                    this._markOptimisticFailed(tempId, storageKey, err);
                }
            })();

            return true;
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
            return false;
        }
    },

    async publishMessagePseudonymous(content, channel = this.currentChannel, geohash = this.currentGeohash, quoteData = null, threadRoot = null) {
        try {
            if (!this.connected) {
                throw new Error('Not connected to relay');
            }

            const ephSk = window.NostrTools.generateSecretKey();
            const ephPk = window.NostrTools.getPublicKey(ephSk);

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
                    'null', 'nym', 'masked', 'hidden', 'cipher',
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

            const nowMs = Date.now();
            const now = Math.floor(nowMs / 1000);
            const tags = [
                ['n', anonNym],
                ['ms', String(nowMs)]
            ];

            const channelKey = geohash || 'nymchat';
            const wire = this.channelWire(channelKey);
            const kind = wire.kind;
            tags.push([wire.tag, channelKey]);

            // NIP-10 marked root reference (threads.js).
            if (threadRoot && /^[0-9a-f]{64}$/i.test(threadRoot)) {
                tags.push(['e', threadRoot, '', 'root']);
            } else {
                threadRoot = null;
            }

            // Quotes go out as an @mention so other Nostr clients see a normal mention.
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

            // NIP-30 custom emoji.
            tags.push(...this.customEmojiTagsForContent(wireContent));

            // NIP-92 Blossom mirror URLs.
            if (typeof this.imetaTagsForContent === 'function') {
                tags.push(...this.imetaTagsForContent(wireContent));
            }

            let event = {
                kind: kind,
                created_at: now,
                tags: tags,
                content: wireContent,
                pubkey: ephPk
            };

            const tempId = '_optim_' + Math.random().toString(36).slice(2) + nowMs.toString(36);
            const storageKey = geohash ? `#${geohash}` : channel;
            const optimisticMessage = {
                id: tempId,
                content: content,
                author: anonNym,
                pubkey: ephPk,
                created_at: now,
                _ms: nowMs,
                _seq: ++this._msgSeq,
                timestamp: new Date(now * 1000),
                channel: channel,
                geohash: geohash,
                isOwn: true,
                isHistorical: false,
                isPM: false,
                threadRoot: threadRoot || undefined,
                _optimistic: true,
                _storageKey: storageKey
            };

            this.userScrolledUp = false;
            this.displayMessage(optimisticMessage);
            this._scheduleScrollToBottom(true);
            this.recordOwnActivity();

            (async () => {
                try {
                    const psDifficulty = this._effectivePowDifficulty();
                    if (psDifficulty > 0) event = await this._minePow(event, psDifficulty);
                    const signedEvent = window.NostrTools.finalizeEvent(event, ephSk);
                    this._replaceOptimisticMessage(tempId, signedEvent, storageKey, false);
                    this.sendToRelay(["EVENT", signedEvent]);
                    if (wire.isGeohash) this.ensureGeoRelayDelivery(signedEvent, channelKey);
                } catch (err) {
                    this._markOptimisticFailed(tempId, storageKey, err);
                }
            })();

            return true;
        } catch (error) {
            this.displaySystemMessage('Failed to send pseudonymous message: ' + error.message);
            return false;
        }
    },

    // Valid PoW or a read receipt; drives transitive trust via the kind-30078 vouch list.
    _observeNymchatPubkey(pubkey) {
        if (!pubkey || pubkey === this.pubkey) return;
        if (!this.nymchatVouches) this.nymchatVouches = new Set();
        if (this.nymchatVouches.has(pubkey)) return;
        this.nymchatVouches.add(pubkey);
        if (this.nymchatVouches.size > 5000) {
            this.nymchatVouches = new Set(Array.from(this.nymchatVouches).slice(-4000));
        }
        if (typeof this._persistDedupSets === 'function') this._persistDedupSets();
        this._scheduleVouchPublish();
    },

    _scheduleVouchPublish() {
        if (this._vouchPublishTimer) return;
        const sinceLast = Date.now() - (this._lastVouchPublishAt || 0);
        const delay = sinceLast < 60000 ? 60000 - sinceLast : 5000;
        this._vouchPublishTimer = setTimeout(() => {
            this._vouchPublishTimer = null;
            this.publishNymchatVouches();
        }, delay);
    },

    async publishNymchatVouches() {
        try {
            if (!this.connected || !this.pubkey) return;
            const list = Array.from(this.nymchatVouches || []);
            if (list.length === 0) return;
            const event = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [['d', 'nym-vouches'], ['t', 'nym-vouches']],
                content: JSON.stringify(list),
                pubkey: this.pubkey
            };
            const signed = await this.signEvent(event);
            this.sendToRelay(['EVENT', signed]);
            this._lastVouchPublishAt = Date.now();
        } catch (_) {}
    },

    handleVouchEvent(event) {
        if (!event || event.pubkey === this.pubkey) return;
        // Only accept vouches from trusted peers so the graph stays rooted in the seeded pubkeys.
        if (!this.nymchatPubkeys || !this.nymchatPubkeys.has(event.pubkey)) return;
        let list;
        try { list = JSON.parse(event.content || '[]'); }
        catch (_) { return; }
        if (!Array.isArray(list)) return;
        let added = false;
        for (const pk of list) {
            if (typeof pk !== 'string' || !/^[0-9a-f]{64}$/i.test(pk)) continue;
            if (pk === this.pubkey) continue;
            if (!this.nymchatPubkeys.has(pk)) added = true;
            this._markNymchatPubkey(pk);
        }
        // Expand the web of trust one hop via a heavily debounced resubscribe.
        if (added) this._scheduleVouchExpansion();
    },

    _scheduleVouchExpansion() {
        if (this._vouchExpansionTimer) return;
        this._vouchExpansionTimer = setTimeout(() => {
            this._vouchExpansionTimer = null;
            if (typeof this._scheduleCriticalResubscribe === 'function') {
                this._scheduleCriticalResubscribe();
            }
        }, 15000);
    },

    // Hard cap on how much of the vouch archive (D1 'nym-vouches') one pass ingests.
    VOUCH_D1_MAX_EVENTS: 5000,

    async _fetchVouchesFromD1() {
        if (!this._getApiHost || !this._getApiHost()) return;
        if (typeof this._storageApiStream !== 'function') return;
        const events = [];
        const cap = this.VOUCH_D1_MAX_EVENTS;
        try {
            const resp = await this._storageApiStream('channel-get', { channel: 'nym-vouches' }, false);
            await this._readNdjsonStream(resp, (ev) => {
                if (ev && ev.kind === 30078) events.push(ev);
                // Stop the stream rather than parse the rest just to drop it.
                if (events.length >= cap) return false;
            });
        } catch (_) { return; }
        if (events.length === 0) return;

        // Verification is lazy and the whole walk is time-sliced.
        const applied = new Set();
        let changed = true;
        let guard = 0;
        let sliceStart = Date.now();
        const breathe = async () => {
            if (Date.now() - sliceStart <= 16) return;
            if (typeof this._yieldToIdle === 'function') await this._yieldToIdle();
            sliceStart = Date.now();
        };
        while (changed && guard++ < 20) {
            const before = this.nymchatPubkeys ? this.nymchatPubkeys.size : 0;
            for (let i = 0; i < events.length; i++) {
                if (applied.has(i)) continue;
                const ev = events[i];
                // Skip untrusted authors without a signature check; a later pass reconsiders them.
                if (!ev || !this.nymchatPubkeys || !this.nymchatPubkeys.has(ev.pubkey)) continue;
                const cached = this._verifiedIdCheck(ev);
                const ok = (cached !== undefined) ? cached : await this._verifyRelayEventAsync(ev);
                applied.add(i);
                if (ok) { try { this.handleVouchEvent(ev); } catch (_) { } }
                await breathe();
            }
            const after = this.nymchatPubkeys ? this.nymchatPubkeys.size : 0;
            changed = after !== before;
            await breathe();
        }
    },

    // 'enabled' (everyone), 'friends' (private gift wraps to friends), or 'disabled'.
    _statusMode() {
        const s = this.settings ? this.settings.showStatus : true;
        if (s === false) return 'disabled';
        if (s === 'friends') return 'friends';
        return 'enabled';
    },

    async publishPresence(status, awayMessage = '') {
        try {
            if (!this.connected) return;

            const mode = this._statusMode();
            // Non-enabled modes broadcast 'hidden' publicly.
            const publicStatus = mode === 'enabled' ? status : 'hidden';

            const tags = [
                ['d', 'nym-presence'],
                ['t', 'nym-presence'],
                ['n', this.nym],
                ['status', publicStatus]
            ];
            if (mode === 'enabled' && status === 'away' && awayMessage) {
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
            this._lastPresenceBroadcast = Date.now();

            if (mode === 'friends') this._sendFriendPresence(status, awayMessage);
        } catch (error) {
        }
    },

    // Gift-wrapped so only friends can read it.
    async _sendFriendPresence(status, awayMessage = '') {
        try {
            if (!this._canSendGiftWraps()) return;
            if (!this.friends || this.friends.size === 0) return;
            const recipients = Array.from(this.friends).filter(pk => pk && pk !== this.pubkey);
            if (recipients.length === 0) return;

            const tags = [['status', status], ['n', this.nym]];
            if (status === 'away' && awayMessage) tags.push(['away', awayMessage]);
            const rumor = {
                kind: this.FRIEND_PRESENCE_KIND,
                created_at: Math.floor(Date.now() / 1000),
                tags,
                content: '',
                pubkey: this.pubkey
            };
            await this._sendGiftWrapsAsync(recipients, rumor, null);
        } catch (_) {
        }
    },

    recordOwnActivity() {
        if (!this.pubkey) return;

        const now = Date.now();
        const existing = this.users.get(this.pubkey);
        if (existing) {
            existing.lastSeen = now;
            // Leave away alone; only /back clears it.
            if (existing.status !== 'away' && !(this.awayMessages && this.awayMessages.has(this.pubkey))) {
                existing.status = 'online';
            }
        } else {
            this.users.set(this.pubkey, {
                nym: this.nym,
                pubkey: this.pubkey,
                lastSeen: now,
                status: (this.awayMessages && this.awayMessages.has(this.pubkey)) ? 'away' : 'online',
                channels: new Set()
            });
        }

        if (typeof this.updateUserList === 'function') this.updateUserList();

        // Never re-assert presence when disabled, or a send would undo the hidden state.
        if (this._statusMode() === 'disabled') return;

        // Skipped while away (cmdAway/cmdBack handle those transitions).
        const PRESENCE_BROADCAST_THROTTLE_MS = 60000;
        const lastBroadcast = this._lastPresenceBroadcast || 0;
        if (now - lastBroadcast < PRESENCE_BROADCAST_THROTTLE_MS) return;
        if (this.awayMessages && this.awayMessages.has(this.pubkey)) return;
        this.publishPresence('online');
    },

    async publishStatusVisibility() {
        const away = this.awayMessages && this.awayMessages.has(this.pubkey);
        const awayMsg = away ? (this.awayMessages.get(this.pubkey) || '') : '';
        return this.publishPresence(away ? 'away' : 'online', awayMsg);
    },

    async publishAvatarUpdate(avatarUrl) {
        try {
            if (!this.connected) return;

            const tags = [
                ['d', 'nym-presence'],
                ['t', 'nym-presence'],
                ['n', this.nym],
                ['status', this._statusMode() === 'enabled' ? 'online' : 'hidden'],
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
        }
    },

    // Other clients drop their cached record and re-fetch instead of waiting out the cache.
    async publishShopUpdate() {
        try {
            if (!this.connected) return;

            const tags = [
                ['d', 'nym-presence'],
                ['t', 'nym-presence'],
                ['n', this.nym],
                ['status', this._statusMode() === 'enabled' ? 'online' : 'hidden'],
                ['shop-update', '1']
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
        }
    },

});
