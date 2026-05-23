// messages.js - Message rendering, formatting, sending, edits, quotes, swipe-to-reply, virtual scroll

const _RX_REGEX_ESCAPE = /[.*+?^${}()|[\]\\]/g;
const _RX_HTML_TAG = /<[^>]*>/g;
const _RX_DUP_SUFFIX = /@([^@#\s]+)#([0-9a-f]{4})#\2\b/gi;
const _RX_WHITESPACE = /\s/g;
const _EMOJI_UNIT = '(?:[\\u{1F1E0}-\\u{1F1FF}]{2})|(?:[#*0-9]\\u{FE0F}?\\u{20E3})|(?:(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?(?:\\u{200D}(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?)*)(?:[\\u{E0020}-\\u{E007E}]+\\u{E007F})?';
const _RX_EMOJI_ONLY = new RegExp(`^(?:${_EMOJI_UNIT}){1,6}$`, 'u');

// Mention pattern is per-identity; cache so we recompile only when the active nym changes.
// A "@nym#xxxx" mention only counts as ours when xxxx is our own pubkey suffix, so
// identically-named users with different pubkeys aren't cross-notified.
let _mentionPatternCache = { key: null, pattern: null };
function _getMentionPattern(cleanNym, suffix) {
    const key = JSON.stringify([cleanNym, suffix || '']);
    if (_mentionPatternCache.key === key) return _mentionPatternCache.pattern;
    const escaped = cleanNym.replace(_RX_REGEX_ESCAPE, '\\$&');
    const sfx = (suffix || '').replace(_RX_REGEX_ESCAPE, '\\$&');
    const tail = sfx
        ? `(?:#${sfx}\\b|(?!#[0-9a-f]{4})(?:\\b|$))`
        : `(?!#[0-9a-f]{4})(?:\\b|$)`;
    const pattern = new RegExp(`@${escaped}${tail}`, 'gi');
    _mentionPatternCache = { key, pattern };
    return pattern;
}

// Detects a quote-reply addressed to us ("> @ourNym#xxxx: ...").
let _quoteToMePatternCache = { key: null, pattern: null };
function _getQuoteToMePattern(cleanNym, suffix) {
    const key = JSON.stringify([cleanNym, suffix || '']);
    if (_quoteToMePatternCache.key === key) return _quoteToMePatternCache.pattern;
    const escaped = cleanNym.replace(_RX_REGEX_ESCAPE, '\\$&');
    const sfx = (suffix || '').replace(_RX_REGEX_ESCAPE, '\\$&');
    const pattern = new RegExp(`^\\s*>+\\s*@${escaped}(?:#${sfx})?\\s*:`, 'im');
    _quoteToMePatternCache = { key, pattern };
    return pattern;
}

// Presence test for any emoji-bearing codepoint (pictographs, regional indicators,
// keycap combiner). Lets formatMessage skip the heavy emoji-wrapping regex on plain text.
const _RX_HAS_EMOJI = /\p{Extended_Pictographic}|[\u{1F1E6}-\u{1F1FF}]|\u{20E3}/u;

// LRU cache for formatMessage output. Invalidated when the identity/channel context
// changes, since that context can alter the rendered HTML (e.g. active-channel class).
const _FORMAT_CACHE_MAX = 200;
const _formatCache = new Map();
let _formatCacheSig = null;
let _formatCacheEpoch = 0;

Object.assign(NYM.prototype, {

    // Millisecond sort key for a message. NYM clients stamp outgoing events with
    // an 'ms' tag (Date.now()) since Nostr created_at only has second resolution.
    // Falls back to the second boundary so events without the tag still order sanely.
    _messageMs(m) {
        if (m && Number.isFinite(m._ms) && m._ms > 0) return m._ms;
        return (m && m.created_at || 0) * 1000;
    },

    // Reads the 'ms' tag off an event/rumor, capped at now to absorb clock skew.
    _extractEventMs(eventOrRumor, createdAtSec) {
        const tags = eventOrRumor && eventOrRumor.tags;
        if (Array.isArray(tags)) {
            const t = tags.find(x => Array.isArray(x) && x[0] === 'ms');
            if (t) {
                const v = Number(t[1]);
                if (Number.isFinite(v) && v > 0) return Math.min(v, Date.now());
            }
        }
        return (createdAtSec || 0) * 1000;
    },

    // Chronological message comparator: created_at seconds, then millisecond
    // 'ms' stamp, then local arrival sequence as a final tiebreaker.
    _compareMessages(a, b) {
        const dt = (a.created_at || 0) - (b.created_at || 0);
        if (dt !== 0) return dt;
        const dm = this._messageMs(a) - this._messageMs(b);
        if (dm !== 0) return dm;
        return (a._seq || 0) - (b._seq || 0);
    },

    _insertMessageSorted(arr, msg) {
        if (arr.length === 0 || this._compareMessages(arr[arr.length - 1], msg) <= 0) {
            arr.push(msg);
            return arr.length - 1;
        }
        let lo = 0, hi = arr.length;
        while (lo < hi) {
            const mid = (lo + hi) >>> 1;
            if (this._compareMessages(arr[mid], msg) <= 0) lo = mid + 1;
            else hi = mid;
        }
        arr.splice(lo, 0, msg);
        return lo;
    },

    _indexMessage(convKey, msg) {
        if (!msg) return;
        if (msg.id) this.messageIndex.set(msg.id, { convKey, msg });
        if (msg.nymMessageId && msg.nymMessageId !== msg.id) {
            this.messageIndex.set(msg.nymMessageId, { convKey, msg });
        }
        if (msg.bitchatMessageId) {
            this.messageIndex.set('bc:' + String(msg.bitchatMessageId).toUpperCase(), { convKey, msg });
        }
        if (msg.nymMessageId) {
            this.messageIndex.set('nm:' + String(msg.nymMessageId).toUpperCase(), { convKey, msg });
        }
    },

    _unindexMessage(msg) {
        if (!msg) return;
        if (msg.id) this.messageIndex.delete(msg.id);
        if (msg.nymMessageId && msg.nymMessageId !== msg.id) {
            this.messageIndex.delete(msg.nymMessageId);
        }
        if (msg.bitchatMessageId) {
            this.messageIndex.delete('bc:' + String(msg.bitchatMessageId).toUpperCase());
        }
        if (msg.nymMessageId) {
            this.messageIndex.delete('nm:' + String(msg.nymMessageId).toUpperCase());
        }
    },

    _replaceOptimisticMessage(tempId, signedEvent, storageKey, isPM) {
        const arr = isPM ? this.pmMessages.get(storageKey) : this.messages.get(storageKey);
        if (!arr) return;
        const idx = arr.findIndex(m => m && m.id === tempId);
        if (idx < 0) return;
        const msg = arr[idx];
        const oldCreated = msg.created_at || 0;
        msg.id = signedEvent.id;
        msg.created_at = signedEvent.created_at;
        msg.timestamp = new Date(signedEvent.created_at * 1000);
        delete msg._optimistic;

        const idSet = isPM ? null : this.channelMessageIds.get(storageKey);
        if (idSet) idSet.add(signedEvent.id);
        if (typeof this._indexMessage === 'function') this._indexMessage(storageKey, msg);
        if (this.processedMessageEventIds) this.processedMessageEventIds.add(signedEvent.id);
        if (this.renderedMessageIds) {
            this.renderedMessageIds.delete(tempId);
            this.renderedMessageIds.add(signedEvent.id);
        }

        if (oldCreated !== msg.created_at) {
            arr.splice(idx, 1);
            this._insertMessageSorted(arr, msg);
        }

        const el = document.querySelector(`[data-message-id="${tempId.replace(/"/g, '\\"')}"]`);
        if (el) {
            el.dataset.messageId = signedEvent.id;
            el.dataset.createdAt = String(signedEvent.created_at || 0);
            el.classList.remove('optimistic-pending');

            if (oldCreated !== msg.created_at) {
                const container = el.parentNode;
                if (container) {
                    const insertBefore = this._findDomInsertionPoint(container, msg.created_at, msg._ms || msg.created_at * 1000, msg._seq || 0);
                    if (insertBefore !== el && insertBefore !== el.nextSibling) {
                        if (insertBefore) container.insertBefore(el, insertBefore);
                        else container.appendChild(el);
                    }
                }
            }
        }
    },

    _markOptimisticFailed(tempId, storageKey, err) {
        const el = document.querySelector(`[data-message-id="${tempId.replace(/"/g, '\\"')}"]`);
        if (el) el.classList.add('optimistic-failed');
        if (typeof this.displaySystemMessage === 'function') {
            this.displaySystemMessage('Failed to send message: ' + (err && err.message || err));
        }
    },

    _findDomInsertionPoint(container, msgCreatedAt, msgMs, msgSeq) {
        const nodes = container.children;
        const n = nodes.length;
        if (n === 0) return null;
        const last = nodes[n - 1];
        if (last.dataset && last.dataset.createdAt !== undefined) {
            const lc = parseInt(last.dataset.createdAt) || 0;
            const lm = parseInt(last.dataset.ms) || (lc * 1000);
            const ls = parseInt(last.dataset.seq) || 0;
            if (msgCreatedAt > lc
                || (msgCreatedAt === lc && msgMs > lm)
                || (msgCreatedAt === lc && msgMs === lm && msgSeq >= ls)) {
                return null;
            }
        }
        let lo = 0, hi = n;
        while (lo < hi) {
            const mid = (lo + hi) >>> 1;
            const node = nodes[mid];
            if (!node.dataset || node.dataset.createdAt === undefined) { lo = mid + 1; continue; }
            const ec = parseInt(node.dataset.createdAt) || 0;
            const em = parseInt(node.dataset.ms) || (ec * 1000);
            const es = parseInt(node.dataset.seq) || 0;
            if (ec < msgCreatedAt
                || (ec === msgCreatedAt && em < msgMs)
                || (ec === msgCreatedAt && em === msgMs && es < msgSeq)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo < n ? nodes[lo] : null;
    },

    hasBlockedKeyword(text, nickname) {
        const lowerText = text.toLowerCase();
        const lowerNick = nickname ? this.parseNymFromDisplay(nickname).toLowerCase() : '';
        return Array.from(this.blockedKeywords).some(keyword =>
            lowerText.includes(keyword) || (lowerNick && lowerNick.includes(keyword))
        );
    },

    // Extract conversation context from a quote chain for bot replies
    // Parses nested quotes (> @Author: text) into an ordered conversation array
    _extractQuoteChain(quoteContext) {
        const conversation = [];
        if (!quoteContext || !quoteContext.text) return conversation;
        // Use fullText (preserves nested quotes) for bot conversation context
        const rawText = quoteContext.fullText || quoteContext.text;
        // Parse the quoted text to extract nested quote layers
        const lines = rawText.split('\n');
        let currentAuthor = null;
        let currentText = [];
        for (const line of lines) {
            // Match quote lines: "> @Author#xxxx: text" or "> continuation"
            const authorMatch = line.match(/^>\s*@([^:]+):\s*(.*)/);
            if (authorMatch) {
                // Save previous entry if exists
                if (currentAuthor !== null) {
                    conversation.push({ author: currentAuthor, text: currentText.join('\n').trim() });
                }
                currentAuthor = authorMatch[1].trim();
                currentText = [authorMatch[2]];
            } else if (line.startsWith('>') && currentAuthor !== null) {
                // Continuation of current quote
                currentText.push(line.replace(/^>\s?/, ''));
            } else if (currentAuthor !== null) {
                // Non-quoted line after quotes — this is the replier's own text
                conversation.push({ author: currentAuthor, text: currentText.join('\n').trim() });
                currentAuthor = null;
                currentText = [];
            }
        }
        // Push final entry
        if (currentAuthor !== null) {
            conversation.push({ author: currentAuthor, text: currentText.join('\n').trim() });
        }
        // If quoteContext has non-quoted text remainder, add it as the replier's text
        // (this is the previous reply before the current user's input)
        const nonQuotedText = lines.filter(l => !l.startsWith('>')).join('\n').trim();
        if (nonQuotedText && (conversation.length === 0 || conversation[conversation.length - 1].text !== nonQuotedText)) {
            conversation.push({ author: quoteContext.author, text: nonQuotedText });
        }
        return conversation;
    },

    trackMessage(pubkey, channel, isHistorical = false, content = '') {
        if (isHistorical) return;

        const now = Date.now();
        const channelKey = channel;

        if (!this.floodTracking.has(channelKey)) {
            this.floodTracking.set(channelKey, new Map());
        }
        const channelTracking = this.floodTracking.get(channelKey);

        if (!channelTracking.has(pubkey)) {
            channelTracking.set(pubkey, {
                count: 1,
                firstMessageTime: now,
                blocked: false
            });
        } else {
            const tracking = channelTracking.get(pubkey);
            if (now - tracking.firstMessageTime > 2000) {
                tracking.count = 1;
                tracking.firstMessageTime = now;
                tracking.blocked = false;
            } else {
                tracking.count++;
                if (tracking.count > 10 && !tracking.blocked) {
                    tracking.blocked = true;
                    tracking.blockedUntil = now + 900000;
                }
            }
        }

        if (content) {
            this._trackContent(pubkey, content, now);
        }
    },

    _hashContent(s) {
        // FNV-1a 32-bit
        let h = 0x811c9dc5;
        for (let i = 0; i < s.length; i++) {
            h ^= s.charCodeAt(i);
            h = Math.imul(h, 0x01000193);
        }
        return h >>> 0;
    },

    _trackContent(pubkey, content, now) {
        if (!this.contentFloodTracking) this.contentFloodTracking = new Map();
        const normalized = content.replace(/\s+/g, ' ').trim().toLowerCase();
        if (normalized.length < 6) return;

        let entry = this.contentFloodTracking.get(pubkey);
        if (!entry) {
            entry = { hashes: new Map(), blockedUntil: 0 };
            this.contentFloodTracking.set(pubkey, entry);
        }

        const WINDOW = 120000;
        for (const [h, info] of entry.hashes) {
            if (now - info.lastSeen > WINDOW) entry.hashes.delete(h);
        }

        const hash = this._hashContent(normalized);
        let info = entry.hashes.get(hash);
        if (!info) {
            info = { count: 0, lastSeen: now };
            entry.hashes.set(hash, info);
        }
        info.count++;
        info.lastSeen = now;

        if (info.count >= 3) {
            entry.blockedUntil = now + 900000;
        }
    },

    isContentFlooding(pubkey) {
        if (!this.contentFloodTracking) return false;
        const entry = this.contentFloodTracking.get(pubkey);
        if (!entry) return false;
        if (Date.now() < entry.blockedUntil) return true;
        entry.blockedUntil = 0;
        return false;
    },

    isFlooding(pubkey, channel) {
        if (this.isContentFlooding(pubkey)) return true;

        const channelTracking = this.floodTracking.get(channel);
        if (!channelTracking) return false;

        const tracking = channelTracking.get(pubkey);
        if (!tracking) return false;

        if (tracking.blocked) {
            const now = Date.now();
            if (now < tracking.blockedUntil) {
                return true;
            } else {
                tracking.blocked = false;
                tracking.blockedUntil = null;
            }
        }

        return false;
    },

    _trackPubkeyMessage(pubkey, eventId, silent) {
        if (!pubkey || !eventId || this.trustedPubkeys.has(pubkey)) return;
        let ids = this.pubkeyMsgIds.get(pubkey);
        if (!ids) {
            ids = new Set();
            this.pubkeyMsgIds.set(pubkey, ids);
            if (this.pubkeyMsgIds.size > 20000) {
                this.pubkeyMsgIds.delete(this.pubkeyMsgIds.keys().next().value);
            }
        }
        ids.add(eventId);
        if (ids.size >= 2) {
            this.pubkeyMsgIds.delete(pubkey);
            this.trustedPubkeys.add(pubkey);
            if (this.trustedPubkeys.size > 50000) {
                this.trustedPubkeys.delete(this.trustedPubkeys.values().next().value);
            }
            if (!silent) this._revealGatedPubkey(pubkey);
        }
    },

    _isPubkeyGated(pubkey) {
        if (this.verifiedDeveloper && pubkey === this.verifiedDeveloper.pubkey) return false;
        if (this.verifiedBotPubkeys && this.verifiedBotPubkeys.has(pubkey)) return false;
        return !this.trustedPubkeys.has(pubkey);
    },

    _markNymchatPubkey(pubkey) {
        if (!pubkey || this.nymchatPubkeys.has(pubkey)) return;
        this.nymchatPubkeys.add(pubkey);
        if (this.nymchatPubkeys.size > 5000) {
            this.nymchatPubkeys = new Set(Array.from(this.nymchatPubkeys).slice(-4000));
        }
        if (typeof this._persistDedupSets === 'function') this._persistDedupSets();
        this._revealGatedPubkey(pubkey);
    },

    // Insert messages in place
    _revealGatedPubkey(pubkey) {
        const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
        this.messages.forEach((msgs, key) => {
            let hadGated = false;
            let maxTime = 0;
            for (const m of msgs) {
                if (m.pubkey === pubkey && m._spamGated) {
                    m._spamGated = false;
                    hadGated = true;
                    const t = (m.created_at || 0) * 1000;
                    if (t > maxTime) maxTime = t;
                }
            }
            if (!hadGated) return;
            // Newly revealed messages now count toward channel sort ordering
            if (maxTime > (this.channelLastActivity.get(key) || 0)) {
                this.channelLastActivity.set(key, maxTime);
            }
            if (!this.inPMMode && key === currentKey) {
                for (const m of msgs) {
                    if (m.pubkey === pubkey) this.displayMessage(m);
                }
            } else {
                this.channelDOMCache.delete(key);
            }
            if (typeof this.updateUnreadCount === 'function') {
                this.updateUnreadCount(key);
            }
            if (this.geohashMap && key.startsWith('#') &&
                this.isValidGeohash && this.isValidGeohash(key.substring(1))) {
                this._scheduleGeohashMapUpdate();
            }
        });
    },

    isMentioned(content) {
        if (!content || !this.nym) return false;

        // Strip HTML from nym for comparison
        const cleanNym = this.parseNymFromDisplay(this.nym);
        const mySuffix = this.getPubkeySuffix(this.pubkey);

        // Cached, per-identity pattern (recompiled only when nym/suffix changes)
        const nymPattern = _getMentionPattern(cleanNym, mySuffix);
        nymPattern.lastIndex = 0;

        // Strip HTML from content and deduplicate suffixes for mention detection
        let cleanContent = content.replace(_RX_HTML_TAG, '');
        cleanContent = cleanContent.replace(_RX_DUP_SUFFIX, '@$1#$2');

        // A quote-reply addressed to us counts as a mention even though the
        // "> @ourNym: ..." line is itself a blockquote.
        if (_getQuoteToMePattern(cleanNym, mySuffix).test(cleanContent)) return true;

        // Strip blockquoted lines so mentions inside quoted text don't trigger notifications
        cleanContent = cleanContent.split('\n').filter(line => !line.trimStart().startsWith('>')).join('\n');

        return nymPattern.test(cleanContent);
    },

    isDuplicateMessage(message) {
        const displayChannel = message.geohash ? `#${message.geohash}` : message.channel;
        const channelMessages = this.messages.get(displayChannel) || [];
        return channelMessages.some(m =>
            m.id === message.id ||
            (m.content === message.content &&
                m.author === message.author &&
                Math.abs(m.timestamp - message.timestamp) < 2000)
        );
    },

    displayMessage(message) {
        // Check if message has been deleted (kind 5)
        if (this.deletedEventIds.has(message.id)) {
            return; // Don't display deleted messages
        }

        // Apply pending edits that arrived before the original message
        const editLookupId = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
        const pendingEdit = this.editedMessages.get(editLookupId);
        if (pendingEdit && pendingEdit.senderPubkey === message.pubkey) {
            message.content = pendingEdit.newContent;
            message.isEdited = true;
        }

        // Check if message is from a blocked user (from stored state OR by pubkey)
        if (message.blocked || this.blockedUsers.has(message.pubkey)) {
            return; // Don't display blocked messages
        }

        // Handle PM messages differently
        if (message.isPM) {
            if (message.isGroup) {
                // Group message: only display when viewing the correct group
                if (!this.inPMMode || this.currentGroup !== message.groupId) return;
                if (message.conversationKey !== this.getGroupConversationKey(this.currentGroup)) return;
            } else {
                // 1:1 PM: only display when viewing the correct conversation
                if (!this.inPMMode || this.currentPM !== message.conversationPubkey) return;
                const currentConversationKey = this.getPMConversationKey(this.currentPM);
                if (message.conversationKey !== currentConversationKey) return;
            }
        } else {
            // Regular geohash channel message
            const storageKey = message.geohash ? `#${message.geohash}` : message.channel;

            const isGated = !message.isOwn && !this.isFriend(message.pubkey) &&
                !this.nymchatPubkeys.has(message.pubkey) &&
                this._isPubkeyGated(message.pubkey);

            if (!this.messages.has(storageKey)) {
                this.messages.set(storageKey, []);
                this.channelMessageIds.set(storageKey, new Set());
            }
            const idSet = this.channelMessageIds.get(storageKey);
            const exists = idSet.has(message.id);
            if (!exists) {
                const msgTime = (message.created_at || 0) * 1000;
                const prevActivity = this.channelLastActivity.get(storageKey) || 0;
                if (!isGated && msgTime > prevActivity) {
                    this.channelLastActivity.set(storageKey, msgTime);
                    if (typeof this._persistUnreadCounts === 'function') {
                        this._persistUnreadCounts();
                    }
                    if (typeof this._scheduleChannelSort === 'function') {
                        this._scheduleChannelSort();
                    }
                }

                const arr = this.messages.get(storageKey);
                if (arr.length >= this.channelMessageLimit && arr.length > 0
                    && (message.created_at || 0) < (arr[0].created_at || 0)) {
                    return;
                }
                this._insertMessageSorted(arr, message);
                idSet.add(message.id);
                this._indexMessage(storageKey, message);

                if (arr.length > this.channelMessageLimit) {
                    const drop = arr.length - this.channelMessageLimit;
                    for (let i = 0; i < drop; i++) {
                        const removed = arr[i];
                        if (removed && removed.id) {
                            idSet.delete(removed.id);
                            this._unindexMessage(removed);
                        }
                    }
                    arr.splice(0, drop);
                }

                this.persistChannelMessages(storageKey);
                this._scheduleZapResubscribe();

                if (this.geohashMap && message.geohash && this.isValidGeohash && this.isValidGeohash(message.geohash)) {
                    this._scheduleGeohashMapUpdate();
                }
            }

            if (isGated) {
                message._spamGated = true;
                return;
            }

            // Now check if we should actually render this message
            if (this.inPMMode) {
                // In PM mode — message is stored but don't render channel
                // messages. Leave the cached DOM alone; loadChannelMessages
                // does a partial-cache restore that appends trailing new
                // messages on switch back, avoiding a full re-render.
                if (!message.isOwn && !exists && !message.isHistorical) {
                    this.updateUnreadCount(storageKey);
                }
                return;
            }

            // Check if this is for current channel
            const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
            if (storageKey !== currentKey) {
                // Message is for different channel — same partial-cache
                // strategy as the PM branch above; no cache invalidation
                // needed.
                if (!message.isOwn && !exists && !message.isHistorical) {
                    this.updateUnreadCount(storageKey);
                }
                return;
            }
            if (typeof this._markChannelRead === 'function' && message.created_at) {
                this._markChannelRead(storageKey, message.created_at);
            }

            // Send a public read receipt (kind 24421) only for messages the
            // user can actually see: fresh, in the current channel, tab
            // visible, and not scrolled away from the bottom.
            const canBeSeen = !document.hidden && !this.userScrolledUp;
            if (canBeSeen && !message.isOwn && !message.isHistorical && message.geohash &&
                message.id && /^[0-9a-f]{64}$/i.test(message.id) &&
                typeof this.sendChannelReadReceipt === 'function') {
                this.sendChannelReadReceipt(message.id, message.pubkey, message.geohash);
            }
        }

        const _dedupeId = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
        if (this.renderedMessageIds.has(_dedupeId)) {
            return;
        }

        // Now actually display the message in the DOM
        const container = document.getElementById('messagesContainer');

        // Clamp timestamp to now so messages never appear in the future
        const now = new Date();
        const displayTimestamp = message.timestamp > now ? now : message.timestamp;

        const time = this.settings.showTimestamps ?
            displayTimestamp.toLocaleTimeString('en-US', {
                hour: '2-digit',
                minute: '2-digit',
                hour12: this.settings.timeFormat === '12hr'
            }) : '';

        // Get user's shop items for styling
        const userShopItems = this.getUserShopItems(message.pubkey);
        const flairHtml = this.getFlairForUser(message.pubkey);
        const supporterBadge = userShopItems?.supporter ?
            '<span class="supporter-badge"><span class="supporter-badge-icon">🏆</span><span class="supporter-badge-text">Supporter</span></span>' : '';
        const friendBadge = !message.isOwn && this.isFriend(message.pubkey)
            ? '<span class="friend-badge" title="Friend"><svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" class="nm-msg-1"><circle cx="6" cy="5" r="2.5" /><path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" /><line x1="13" y1="6" x2="13" y2="10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /><line x1="11" y1="8" x2="15" y2="8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg></span>'
            : '';

        const messageEl = document.createElement('div');

        // Check if nym is blocked or message contains blocked keywords or is spam.
        // For our own outgoing messages, surface a system message so the sender
        // knows why their message disappeared (it was still sent to relays).
        const keywordHit = this.hasBlockedKeyword(message.content, message.author);
        const spamHit = this.isSpamMessage(message.content);
        if (this.blockedUsers.has(message.pubkey) || keywordHit || spamHit) {
            if (message.isOwn) {
                const reason = keywordHit
                    ? 'matched one of your blocked keywords'
                    : spamHit
                        ? 'was flagged by the spam filter'
                        : 'matched a block rule';
                this.displaySystemMessage(`Your message ${reason} and was hidden locally. It was still sent.`);
            }
            return;
        }

        // Check if nym is flooding in THIS CHANNEL (but not for PMs and not for historical messages)
        const channelToCheck = message.geohash || message.channel;
        if (!message.isPM && !message.isHistorical && this.isFlooding(message.pubkey, channelToCheck)) {
            messageEl.className = 'message flooded';
        }

        // Check if message mentions the user
        const isMentioned = !message.isOwn && this.isMentioned(message.content);

        // Check for action messages
        if (message.content.startsWith('/me ')) {
            messageEl.className = 'system-message me-message';
            messageEl.dataset.messageId = message.id;
            messageEl.dataset.timestamp = displayTimestamp.getTime();
            messageEl.dataset.createdAt = message.created_at || 0;
            messageEl.dataset.ms = this._messageMs(message);
            messageEl.dataset.seq = message._seq || 0;

            // Get clean author name and flair
            const cleanAuthor = this.parseNymFromDisplay(message.author);
            const authorFlairHtml = this.getFlairForUser(message.pubkey);
            const actionAvatarSrc = this.getAvatarUrl(message.pubkey);
            const safePk = this._safePubkey(message.pubkey);
            const authorWithFlair = `<img src="${this.escapeHtml(actionAvatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" loading="lazy">${this.escapeHtml(cleanAuthor)}#${this.getPubkeySuffix(message.pubkey)}${authorFlairHtml}`;

            // Get the action content (everything after /me)
            const actionContent = message.content.substring(4);

            // Format the action content but preserve any HTML in mentioned users
            const formattedAction = this._enrichActionMentions(this.formatMessage(actionContent));

            messageEl.innerHTML = `* ${authorWithFlair} ${formattedAction} *`;
        } else {
            const classes = ['message'];

            if (message.isOwn) {
                classes.push('self');
            } else if (message.isPM) {
                classes.push('pm');
            } else if (isMentioned) {
                classes.push('mentioned');
            }

            // Apply shop styles (message-level)
            if (userShopItems?.style) {
                classes.push(userShopItems.style);
            }
            if (userShopItems?.supporter) {
                classes.push('supporter-style');
            }
            // Apply cosmetics (message-level glow)
            if (Array.isArray(userShopItems?.cosmetics)) {
                if (userShopItems.cosmetics.includes('cosmetic-aura-gold')) {
                    classes.push('cosmetic-aura-gold');
                }
            }

            messageEl.className = classes.join(' ');
            // For PM messages use nymMessageId as the stable shared key (gift wrap IDs differ per recipient)
            messageEl.dataset.messageId = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
            messageEl.dataset.author = message.author;
            messageEl.dataset.pubkey = message.pubkey;
            messageEl.dataset.rawContent = message.content;
            messageEl.dataset.timestamp = displayTimestamp.getTime();
            messageEl.dataset.createdAt = message.created_at || 0;
            messageEl.dataset.ms = this._messageMs(message);
            messageEl.dataset.seq = message._seq || 0;
            if (message.isPM) messageEl.dataset.isPM = '1';
            if (message.isGroup && message.groupId) messageEl.dataset.groupId = message.groupId;

            const authorClass = message.isOwn ? 'self' : '';
            const userColorClass = this.getUserColorClass(message.pubkey);

            // Add verified badge if this is the developer or the nymbot
            const verifiedBadge = this.isVerifiedDeveloper(message.pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
                : (message.isBot || this.isVerifiedBot(message.pubkey))
                    ? '<span class="verified-badge" title="Nymchat Bot">✓</span>'
                    : '';

            // Check if this is a valid event ID (not temporary PM ID)
            // PM messages use nymMessageId (UUID) as the shared reaction key, so accept those too
            const isValidEventId = (message.isPM && message.nymMessageId)
                || (message.id && /^[0-9a-f]{64}$/i.test(message.id));
            const reactionMsgId = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
            const isMobile = window.innerWidth <= 768;

            // Show reaction & translate buttons for all messages with valid IDs (including PMs)
            const hoverButtons = isValidEventId && !isMobile ? `
    <div class="msg-hover-buttons">
        <button class="reaction-btn" data-action="reactionShowPicker" data-message-id="${reactionMsgId}">
            <svg viewBox="0 0 20 20" class="nm-msg-2">
                <path fill-rule="evenodd" clip-rule="evenodd" d="M15.5 1a.75.75 0 0 1 .75.75v2h2a.75.75 0 0 1 0 1.5h-2v2a.75.75 0 0 1-1.5 0v-2h-2a.75.75 0 0 1 0-1.5h2v-2A.75.75 0 0 1 15.5 1m-13 10a6.5 6.5 0 0 1 7.166-6.466.75.75 0 0 0 .152-1.493 8 8 0 1 0 7.14 7.139.75.75 0 0 0-1.492.152A7 7 0 0 1 15.5 11a6.5 6.5 0 1 1-13 0m4.25-.5a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5m4.5 0a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5M9 15c1.277 0 2.553-.724 3.06-2.173.148-.426-.209-.827-.66-.827H6.6c-.452 0-.808.4-.66.827C6.448 14.276 7.724 15 9 15"></path>
            </svg>
        </button>
        <button class="translate-msg-btn" data-action="translateHoverMessage" title="Translate">
            <svg viewBox="0 0 24 24">
                <path d="m12.87 15.07-2.54-2.51.03-.03A17.52 17.52 0 0 0 14.07 6H17V4h-7V2H8v2H1v1.99h11.17C11.5 7.92 10.44 9.75 9 11.35 8.07 10.32 7.3 9.19 6.69 8h-2c.73 1.63 1.73 3.17 2.98 4.56l-5.09 5.02L4 19l5-5 3.11 3.11.76-2.04zM18.5 10h-2L12 22h2l1.12-3h4.75L21 22h2l-4.5-12zm-2.62 7 1.62-4.33L19.12 17h-3.24z"/>
            </svg>
        </button>
    </div>
` : '';

            // Build the initial HTML with quote detection
            const formattedContent = this.formatMessageWithQuotes(message.content);

            const baseNym = this.parseNymFromDisplay(message.author);
            const avatarSrc = this.getAvatarUrl(message.pubkey);
            const safePk2 = this._safePubkey(message.pubkey);
            const displayAuthorBase = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk2}" alt="" loading="lazy">&lt;${this.escapeHtml(baseNym)}<span class="nym-suffix">#${this.getPubkeySuffix(message.pubkey)}</span>${flairHtml}`;
            let displayAuthor = displayAuthorBase; // string used in HTML
            let authorExtraClass = '';
            if (Array.isArray(userShopItems?.cosmetics) && userShopItems.cosmetics.includes('cosmetic-redacted')) {
                authorExtraClass = 'cosmetic-redacted';
            }

            const escapedAuthorBase = this.escapeHtml(this.stripPubkeySuffix(message.author));
            const authorWithHtml = `${escapedAuthorBase}<span class="nym-suffix">#${this.getPubkeySuffix(message.pubkey)}</span>`;

            // Prepare full timestamp for tooltip
            const fullTimestamp = displayTimestamp.toLocaleString('en-US', {
                year: 'numeric',
                month: 'short',
                day: 'numeric',
                hour: '2-digit',
                minute: '2-digit',
                second: '2-digit',
                hour12: this.settings.timeFormat === '12hr'
            });

            // Delivery status for own PM messages
            let deliveryCheckmark = '';
            if (message.isOwn && !message.isPM && message.geohash &&
                message.id && /^[0-9a-f]{64}$/i.test(message.id) &&
                typeof this._buildChannelReadersHtml === 'function') {
                const avatarHtml = this._buildChannelReadersHtml(message.id);
                deliveryCheckmark = `<span class="channel-readers" data-msg-id="${message.id}">${avatarHtml}</span>`;
            } else if (message.isOwn && message.isPM) {
                if (message.isGroup && message.nymMessageId) {
                    // Group messages: show stacked reader avatars instead of checkmarks
                    const avatarHtml = this._buildGroupReadersHtml(message.nymMessageId);
                    deliveryCheckmark = `<span class="group-readers" data-nym-msg-id="${message.nymMessageId}">${avatarHtml}</span>`;
                } else if (message.deliveryStatus) {
                    if (message.deliveryStatus === 'read') {
                        deliveryCheckmark = '<span class="delivery-status read" title="Read">✓✓</span>';
                    } else if (message.deliveryStatus === 'delivered') {
                        deliveryCheckmark = '<span class="delivery-status delivered" title="Delivered">✓</span>';
                    } else if (message.deliveryStatus === 'failed') {
                        deliveryCheckmark = `<span class="delivery-status failed nm-pointer" title="Failed to deliver - click to retry" data-retry-event-id="${message.id}">!</span>`;
                    } else if (message.deliveryStatus === 'sent') {
                        deliveryCheckmark = '<span class="delivery-status sent" title="Sent">○</span>';
                    }
                }
            }

            // Check if this is a file offer and render special UI
            let messageContentHtml;
            if (message.isFileOffer && message.fileOffer) {
                const offer = message.fileOffer;
                const fileCategory = this.getFileTypeCategory(offer.name, offer.type);
                const isOwnOffer = message.isOwn;
                const isUnseeded = this.p2pUnseededOffers.has(offer.offerId) || (isOwnOffer && !this.p2pPendingFiles.has(offer.offerId) && message.isHistorical);
                const isTorrent = !!offer.magnetURI;

                let statusHtml;
                if (isOwnOffer) {
                    if (isUnseeded) {
                        statusHtml = `
                            <div class="file-offer-unseeded">
                                <div class="file-offer-unseeded-dot"></div>
                                <span>No longer seeding</span>
                            </div>
                        `;
                    } else {
                        statusHtml = `
                            <div class="file-offer-seeding">
                                <div class="file-offer-seeding-dot"></div>
                                <span>Seeding - available for download</span>
                                <button class="file-offer-stop-btn" data-action="stopSeeding" data-offer-id="${offer.offerId}" title="Stop seeding">Stop</button>
                            </div>
                        `;
                    }
                } else if (isUnseeded) {
                    statusHtml = `
                        <div class="file-offer-unseeded">
                            <div class="file-offer-unseeded-dot"></div>
                            <span>No longer available</span>
                        </div>
                    `;
                } else {
                    statusHtml = `
                        <div class="file-offer-actions">
                            ${isTorrent ? `
                                <button class="file-offer-btn torrent-btn" data-action="downloadTorrent" data-offer-id="${offer.offerId}">Download (Torrent)</button>
                            ` : `
                                <button class="file-offer-btn" data-action="requestP2PFile" data-offer-id="${offer.offerId}">Download</button>
                            `}
                        </div>
                        <div class="file-offer-progress nm-hidden" id="progress-${offer.offerId}">
                            <div class="file-offer-progress-bar">
                                <div class="file-offer-progress-fill" id="progress-fill-${offer.offerId}"></div>
                            </div>
                            <div class="file-offer-progress-text" id="progress-text-${offer.offerId}">Connecting...</div>
                        </div>
                    `;
                }

                messageContentHtml = `
                    <div class="file-offer${isTorrent ? ' torrent' : ''}" data-offer-id="${offer.offerId}">
                        <div class="file-offer-header">
                            <div class="file-offer-icon ${fileCategory}">
                                <svg viewBox="0 0 24 24" stroke-width="2">
                                    <path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"></path>
                                    <polyline points="13 2 13 9 20 9"></polyline>
                                </svg>
                            </div>
                            <div class="file-offer-info">
                                <div class="file-offer-name" title="${this.escapeHtml(offer.name)}">${this.escapeHtml(offer.name)}</div>
                                <div class="file-offer-meta">${this.formatFileSize(offer.size)} • ${this.escapeHtml(offer.type || 'Unknown type')}${isTorrent ? ' • Torrent' : ''}</div>
                            </div>
                        </div>
                        ${statusHtml}
                    </div>
                `;
            } else {
                messageContentHtml = formattedContent;
            }

            // Detect emoji-only messages (1-6 emoji with optional whitespace, no other text)
            const emojiOnlyClass = !message.isFileOffer &&
                (this.isEmojiOnly(message.content) || this.isCustomEmojiOnly(message.content)) ? ' emoji-only' : '';

            const bubbleTime = time || displayTimestamp.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: this.settings.timeFormat === '12hr' });

            // Check if this message has been edited
            const isEdited = message.isEdited;
            const editedBubble = isEdited ? '<span class="edited-indicator" title="This message has been edited">(edited)</span> ' : '';
            const editedIRC = isEdited ? '<span class="edited-indicator edited-indicator-irc" title="This message has been edited">(edited)</span>' : '';

            messageEl.innerHTML = `
    ${time ? `<span class="message-time ${this.settings.timeFormat === '12hr' ? 'time-12hr' : ''}" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${time}</span>` : ''}
    <span class="message-author ${authorClass} ${userColorClass} ${authorExtraClass}"><span class="bubble-time" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${bubbleTime}</span><span class="author-clickable">${displayAuthor}${verifiedBadge}${supporterBadge}${friendBadge}</span>&gt;</span>
    <span class="message-content ${userColorClass}${emojiOnlyClass}">${messageContentHtml}<span class="bubble-time-inner" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${editedBubble}${bubbleTime}</span>${hoverButtons}</span>
    ${editedIRC}
    ${deliveryCheckmark}
`;

            const authorClickable = messageEl.querySelector('.author-clickable');
            if (authorClickable) {
                authorClickable.style.cursor = 'pointer';
                authorClickable.addEventListener('click', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    const ctxReactionId = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
                    this.showContextMenu(e, displayAuthor, message.pubkey, message.content, message.id, false, ctxReactionId);
                    return false;
                });
            }
        }

        // Truncate long messages with "Read more" toggle
        // Mobile: 400 chars, Desktop: 600 chars
        // Quotes and replies are truncated independently so a short reply to a
        // long quote stays fully visible while only the quote collapses.
        const isMobileTruncate = window.innerWidth <= 768;
        const truncateThreshold = isMobileTruncate ? 400 : 600;
        let truncationTargets = [];
        if (!message.isFileOffer && message.content) {
            const contentEl = messageEl.querySelector('.message-content') || messageEl;
            const bubbleTimeInner = contentEl.querySelector(':scope > .bubble-time-inner');

            const makeReadMoreBtn = (inner) => {
                const btn = document.createElement('button');
                btn.className = 'read-more-btn';
                btn.textContent = 'Read more';
                btn.addEventListener('click', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    const isExpanded = inner.classList.toggle('truncated-expanded');
                    btn.textContent = isExpanded ? 'Show less' : 'Read more';
                });
                return btn;
            };

            // Truncate each long top-level blockquote in place
            contentEl.querySelectorAll(':scope > blockquote').forEach(bq => {
                if ((bq.textContent || '').length > truncateThreshold) {
                    const inner = document.createElement('span');
                    inner.className = 'truncated-inner';
                    while (bq.firstChild) inner.appendChild(bq.firstChild);
                    bq.appendChild(inner);
                    const btn = makeReadMoreBtn(inner);
                    bq.appendChild(btn);
                    bq.classList.add('has-truncation');
                    truncationTargets.push({ inner, btn, host: bq });
                }
            });

            // Truncate the reply (non-quoted) portion if it's long on its own
            const replyText = message.content
                .split('\n')
                .filter(line => !line.startsWith('>'))
                .join('\n')
                .trim();
            if (replyText.length > truncateThreshold) {
                const replyNodes = [];
                Array.from(contentEl.childNodes).forEach(node => {
                    if (node === bubbleTimeInner) return;
                    if (node.nodeType === 1 && node.tagName === 'BLOCKQUOTE') return;
                    if (node.nodeType === 1 && node.classList.contains('msg-hover-buttons')) return;
                    replyNodes.push(node);
                });
                if (replyNodes.length) {
                    const inner = document.createElement('span');
                    inner.className = 'truncated-inner';
                    replyNodes.forEach(n => inner.appendChild(n));
                    const btn = makeReadMoreBtn(inner);
                    if (bubbleTimeInner) {
                        contentEl.insertBefore(inner, bubbleTimeInner);
                        contentEl.insertBefore(btn, bubbleTimeInner);
                    } else {
                        contentEl.appendChild(inner);
                        contentEl.appendChild(btn);
                    }
                    contentEl.classList.add('has-truncation');
                    truncationTargets.push({ inner, btn, host: contentEl });
                }
            }
        }

        // Apply shop styles for own messages (load from cache if needed)
        if (message.pubkey === this.pubkey) {
            // Use cached values if shop items haven't loaded yet
            const activeStyle = this.activeMessageStyle || this.localActiveStyle;
            const activeFlair = this.activeFlair || this.localActiveFlair;

            if (activeStyle) {
                messageEl.classList.add(activeStyle);
            }
            if (this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false) {
                messageEl.classList.add('supporter-style');
            }
            if (this.activeCosmetics && this.activeCosmetics.size > 0) {
                this.activeCosmetics.forEach(c => {
                    if (c === 'cosmetic-aura-gold') {
                        messageEl.classList.add('cosmetic-aura-gold');
                    }
                    if (c === 'cosmetic-redacted') {
                        const auth = messageEl.querySelector('.message-author');
                        if (auth) auth.classList.add('cosmetic-redacted');

                        // Apply redacted effect to message content after 10 seconds
                        const contentEl = messageEl.querySelector('.message-content');
                        if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                            setTimeout(() => {
                                contentEl.classList.add('cosmetic-redacted-message');
                                contentEl.textContent = '';
                            }, 10000);
                        }
                    }
                });
            }
        }

        // Apply cosmetics from OTHER users to their messages
        if (message.pubkey !== this.pubkey && userShopItems?.cosmetics) {
            userShopItems.cosmetics.forEach(c => {
                if (c === 'cosmetic-redacted') {
                    const auth = messageEl.querySelector('.message-author');
                    if (auth) auth.classList.add('cosmetic-redacted');

                    // Apply redacted effect to message content after 10 seconds
                    const contentEl = messageEl.querySelector('.message-content');
                    if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                        setTimeout(() => {
                            contentEl.classList.add('cosmetic-redacted-message');
                            contentEl.textContent = '';
                        }, 10000);
                    }
                }
            });
        }

        // Apply blur to images (including quoted images) when the message is
        // not our own and the blur setting applies to this sender.
        if (!message.isOwn) {
            const shouldBlur = this.blurOthersImages === true ||
                (this.blurOthersImages === 'friends' && !this.isFriend(message.pubkey));
            if (shouldBlur) {
                messageEl.querySelectorAll('img').forEach(img => {
                    img.classList.add('blurred');
                });
            }
        }

        if (this._pendingFragment) {
            this._pendingFragment.appendChild(messageEl);
        } else {
            const msgCreatedAt = message.created_at || 0;
            const msgMs = this._messageMs(message);
            const msgSeq = message._seq || 0;
            const insertBefore = this._findDomInsertionPoint(container, msgCreatedAt, msgMs, msgSeq);
            if (insertBefore && insertBefore.parentNode) {
                insertBefore.parentNode.insertBefore(messageEl, insertBefore);
            } else {
                container.appendChild(messageEl);
            }
        }

        this.renderedMessageIds.add(_dedupeId);
        this._updateBubbleGrouping(messageEl);

        // Sending your own channel message should always jump to the latest,
        // even if you'd scrolled up — reverse-column auto-pinning only holds
        // when already at the bottom, so force the scroll here.
        if (message.isOwn && !message.isPM && !message.isHistorical) {
            this._scheduleScrollToBottom(true);
        }

        // The char-count threshold only flags candidates; the collapse itself is
        // height-based, so drop the toggle for content that already fits.
        for (const t of truncationTargets) {
            if (t.inner.clientHeight > 0 && t.inner.scrollHeight <= t.inner.clientHeight + 2) {
                t.btn.remove();
                t.host.classList.remove('has-truncation');
                t.inner.classList.add('truncated-expanded');
            }
        }

        // Bind long-press on group-readers span so users can see all viewers
        if (message.isOwn && message.isGroup && message.nymMessageId) {
            const readersEl = messageEl.querySelector('.group-readers');
            if (readersEl) this._bindReaderLongPress(readersEl, message.nymMessageId);
        }

        if (!this._pendingFragment) {
            const domMessages = container.querySelectorAll('.message[data-message-id]');
            const domLimit = message.isPM ? this.pmStorageLimit : this.channelMessageLimit;
            if (domMessages.length > domLimit) {
                const toRemove = domMessages.length - domLimit;
                for (let i = 0; i < toRemove; i++) {
                    const removed = domMessages[i];
                    const rid = removed.dataset && removed.dataset.messageId;
                    if (rid) this.renderedMessageIds.delete(rid);
                    removed.remove();
                }
                const firstAfterPrune = container.querySelector('.message[data-message-id]');
                if (firstAfterPrune) this._updateBubbleGrouping(firstAfterPrune);
            }
        }

        const reactionKey = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
        if (reactionKey && this.reactions.has(reactionKey)) {
            this.updateMessageReactions(reactionKey, messageEl);
        }
        if (message.isPM && message.nymMessageId && message.nymMessageId !== message.id) {
            if (this._migrateReactionKey(message.id, message.nymMessageId)) {
                this.updateMessageReactions(message.nymMessageId, messageEl);
            }
        }

        if (message.id && this.zaps.has(message.id)) {
            this.updateMessageZaps(message.id, messageEl);
        }

        const videos = messageEl.querySelectorAll('video.message-video');
        if (videos.length > 0) {
            videos.forEach(vid => {
                const source = vid.querySelector('source');
                if (source) {
                    const blobFallback = async () => {
                        if (vid.dataset.blobLoaded) return;
                        vid.dataset.blobLoaded = 'true';
                        try {
                            const resp = await fetch(source.src);
                            const blob = await resp.blob();
                            const blobUrl = URL.createObjectURL(blob);
                            vid.dataset.blobSrc = blobUrl;
                            vid.removeAttribute('src');
                            source.src = blobUrl;
                            source.type = 'video/mp4';
                            vid.load();
                        } catch (e) {
                            console.warn('Video blob fallback failed:', e);
                        }
                    };
                    source.addEventListener('error', blobFallback, { once: true });
                    vid.addEventListener('error', blobFallback, { once: true });
                }
                this._observeLazyVideo(vid);
            });
        }

        // Play notification sound for mentions and PMs (but not for historical messages, own messages, or bot messages)
        // Skip sound when bulk-rendering stored messages (e.g. opening an unread conversation)
        if (!this._suppressSound && !message.isHistorical && !message.isOwn && !message.isBot && this.settings.sound) {
            if (isMentioned || message.isPM) {
                this.playSound(this.settings.sound);
            }
        }

        // Attach rich link previews for URLs in the message (async, non-blocking)
        this._attachLinkPreviews(messageEl);

        // Wire Blossom mirror fallbacks for media that fails to load from its primary host
        this._attachMediaFallbacks(messageEl);
    },

    _attachMediaFallbacks(root) {
        if (!root) return;
        const imgs = root.querySelectorAll('img[data-media-fallbacks]');
        imgs.forEach(img => {
            if (img._fbBound) return;
            img._fbBound = true;
            const list = (img.getAttribute('data-media-fallbacks') || '').split('|').filter(Boolean);
            let idx = 0;
            img.addEventListener('error', () => {
                if (idx >= list.length) return;
                img.src = list[idx++];
            });
        });
        const vids = root.querySelectorAll('.video-container[data-media-fallbacks]');
        vids.forEach(container => {
            if (container._fbBound) return;
            container._fbBound = true;
            const list = (container.getAttribute('data-media-fallbacks') || '').split('|').filter(Boolean);
            let idx = 0;
            const video = container.querySelector('video');
            const source = container.querySelector('source');
            if (!video || !source) return;
            const tryNext = () => {
                if (idx >= list.length) return;
                const next = list[idx++];
                source.src = next;
                const btn = container.querySelector('.video-expand-btn');
                if (btn) btn.setAttribute('data-video-src', next);
                video.load();
            };
            source.addEventListener('error', tryNext);
            video.addEventListener('error', tryNext);
        });
    },

    formatMessageWithQuotes(content, depth = 0) {
        const MAX_QUOTE_DEPTH = 5;

        // Split content into lines and group consecutive > lines into quote blocks
        const lines = content.split('\n');
        let html = '';
        let i = 0;

        while (i < lines.length) {
            if (lines[i].startsWith('>')) {
                // Collect all consecutive > lines into one quote block
                const quoteLines = [];
                while (i < lines.length && lines[i].startsWith('>')) {
                    quoteLines.push(lines[i].substring(1).trim());
                    i++;
                }

                // If we've reached the max depth, strip the nested quote entirely
                if (depth >= MAX_QUOTE_DEPTH) {
                    continue;
                }

                // First line may have author attribution
                const firstLine = quoteLines[0];
                const authorMatch = firstLine.match(/^@([^:]+):\s*(.*)/);

                if (authorMatch) {
                    const quotedAuthor = authorMatch[1].trim();
                    // Remaining text after author on first line, plus all continuation lines
                    const messageParts = [];
                    if (authorMatch[2]) messageParts.push(authorMatch[2]);
                    for (let j = 1; j < quoteLines.length; j++) {
                        messageParts.push(quoteLines[j]);
                    }
                    const quotedMessage = messageParts.join('\n');

                    // Clean the author name of HTML, entities, and deduplicate suffixes for comparison
                    let cleanAuthor = quotedAuthor.replace(/<[^>]*>/g, '').replace(/&lt;/g, '').replace(/&gt;/g, '').trim();
                    cleanAuthor = cleanAuthor.replace(/^([^#]+)#([0-9a-f]{4})#\2$/i, '$1#$2');

                    // Look up the author's pubkey
                    let authorPubkey = null;
                    this.users.forEach((user, pubkey) => {
                        const userNym = this.parseNymFromDisplay(user.nym);
                        const fullNym = `${userNym}#${this.getPubkeySuffix(pubkey)}`;
                        if (fullNym === cleanAuthor || userNym === cleanAuthor) {
                            authorPubkey = pubkey;
                        }
                    });

                    // Get author's flair if found
                    const flairHtml = authorPubkey ? this.getFlairForUser(authorPubkey) : '';
                    // Wrap the #suffix in nym-suffix span for proper dimming
                    const suffixMatch = cleanAuthor.match(/^(.+)(#[0-9a-f]{4})$/i);
                    const displayAuthor = suffixMatch
                        ? `${this.escapeHtml(suffixMatch[1])}<span class="nym-suffix">${this.escapeHtml(suffixMatch[2])}</span>${flairHtml}`
                        : `${this.escapeHtml(cleanAuthor)}${flairHtml}`;

                    html += `<blockquote><span class="quote-author">@${displayAuthor}:</span> ${this.formatMessageWithQuotes(quotedMessage, depth + 1)}</blockquote>`;
                } else {
                    // Regular quote without author
                    const quotedMessage = quoteLines.join('\n');
                    html += `<blockquote>${this.formatMessageWithQuotes(quotedMessage, depth + 1)}</blockquote>`;
                }
            } else if (lines[i].trim() === '') {
                // Skip empty lines adjacent to quotes
                i++;
            } else {
                // Collect consecutive non-quote, non-empty lines
                const textLines = [];
                while (i < lines.length && !lines[i].startsWith('>')) {
                    textLines.push(lines[i]);
                    i++;
                }
                const text = textLines.join('\n').replace(/^\n+/, '').replace(/\n+$/, '');
                if (text) {
                    html += this.formatMessage(text);
                }
            }
        }

        if (!html) {
            return this.formatMessage(content);
        }

        return html;
    },

    _enrichActionMentions(html) {
        if (!html || typeof html !== 'string') return html;
        if (!this._suffixIndex) this._suffixIndex = new Map();
        // Rebuild the suffix index lazily — we want it fresh enough but not
        // every call. The Map size approximates user count; rebuild when it
        // disagrees materially with the live users map.
        const usersSize = this.users ? this.users.size : 0;
        if (this._suffixIndex.size === 0 || Math.abs(this._suffixIndex.size - usersSize) > 8) {
            this._suffixIndex.clear();
            this.users.forEach((_, pubkey) => {
                if (typeof pubkey === 'string' && pubkey.length >= 4) {
                    const sfx = pubkey.slice(-4).toLowerCase();
                    if (!this._suffixIndex.has(sfx)) this._suffixIndex.set(sfx, pubkey);
                }
            });
        }
        const escapeHtml = (s) => this.escapeHtml(s);
        // Match the mention HTML produced by formatMessage:
        //   <span class="nm-mention">@name<span class="nym-suffix">#abcd</span></span>
        return html.replace(
            /<span class="nm-mention">(@[^<]*?)<span class="nym-suffix">(#[0-9a-f]{4})<\/span><\/span>/gi,
            (match, namePart, suffixPart) => {
                const sfx = suffixPart.slice(1).toLowerCase();
                const pubkey = this._suffixIndex.get(sfx);
                if (!pubkey) return match; // No known user — keep plain rendering
                const safePk = this._safePubkey(pubkey) || '';
                const avatarSrc = this.getAvatarUrl(pubkey);
                const flairHtml = this.getFlairForUser(pubkey) || '';
                return `<span class="action-mention nm-mention">`
                    + `<img src="${escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" loading="lazy">`
                    + `${namePart}<span class="nym-suffix">${suffixPart}</span>${flairHtml}`
                    + `</span>`;
            }
        );
    },

    formatMessage(content) {
        // LRU cache: reuse rendered HTML for identical content under the same
        // identity/channel context. The signature invalidates the whole cache when
        // that context changes (active-channel class etc. depends on it).
        const sig = (this.pubkey || '') + '|' + (this.currentChannel || '') + '|' + (this.currentGeohash || '') + '|' + _formatCacheEpoch;
        if (sig !== _formatCacheSig) {
            _formatCache.clear();
            _formatCacheSig = sig;
        }
        const cacheKey = content + '|' + (this.pubkey || '');
        const cachedHit = _formatCache.get(cacheKey);
        if (cachedHit !== undefined) {
            _formatCache.delete(cacheKey);
            _formatCache.set(cacheKey, cachedHit);
            return cachedHit;
        }

        let formatted = content;

        // Deduplicate suffixes in mentions from external apps (e.g., @user#abcd#abcd -> @user#abcd)
        if (formatted.includes('@') && formatted.includes('#')) {
            formatted = formatted.replace(/@([^@#\s]+)#([0-9a-f]{4})#\2\b/gi, '@$1#$2');
        }

        if (formatted.includes('&')) formatted = formatted.replace(/&(?![a-z]+;|#[0-9]+;|#x[0-9a-f]+;)/gi, '&amp;');
        if (formatted.includes('<')) formatted = formatted.replace(/</g, '&lt;');
        if (formatted.includes('>')) formatted = formatted.replace(/>/g, '&gt;');
        if (formatted.includes('"')) formatted = formatted.replace(/"/g, '&quot;');

        // Code blocks and inline code — extract into placeholders so
        // later markdown/mention/channel processing doesn't touch their contents
        const codePlaceholders = [];
        const splitCodeLang = (body) => {
            const m = body.match(/^[ \t]*([A-Za-z0-9_+#.-]{1,20})[ \t]*\r?\n/);
            return m ? { lang: m[1], body: body.slice(m[0].length) } : { lang: null, body: body };
        };
        const pushCodeBlock = (code) => {
            const { lang, body } = splitCodeLang(code);
            const trimmedCode = body.replace(/^\s*\n/, '').replace(/\s+$/, '');
            const rawCode = trimmedCode
                .replace(/&lt;/g, '<')
                .replace(/&gt;/g, '>')
                .replace(/&quot;/g, '"')
                .replace(/&amp;/g, '&');
            const hl = window.NymHighlight;
            const normLang = hl ? hl.normalize(lang) : null;
            const codeHtml = hl && normLang
                ? hl.highlight(rawCode, normLang)
                : trimmedCode;
            const langClass = normLang ? ` class="language-${normLang}"` : '';
            const langLabel = normLang ? `<span class="code-lang-label">${normLang}</span>` : '';
            const encodedRaw = btoa(unescape(encodeURIComponent(rawCode)));
            const idx = codePlaceholders.length;
            codePlaceholders.push(`<div class="code-block-wrapper">${langLabel}<pre><code${langClass}>${codeHtml}</code></pre><button class="code-copy-btn" data-code="${encodedRaw}" data-action="codeBlockCopy">Copy</button></div>`);
            return `\uFDD0${idx}\uFDD1`;
        };
        if (formatted.includes('```')) {
            formatted = formatted.replace(/```([\s\S]*?)```/g, (match, code) => pushCodeBlock(code));
            // Unterminated fence (e.g. a truncated bot reply): render the remainder as a block
            formatted = formatted.replace(/```([\s\S]+)$/, (match, code) => pushCodeBlock(code));
        }
        if (formatted.includes('`')) {
            formatted = formatted.replace(/`([^`]+?)`/g, (match, code) => {
                const idx = codePlaceholders.length;
                codePlaceholders.push(`<code>${code}</code>`);
                return `\uFDD0${idx}\uFDD1`;
            });
        }

        // Bold **text** (asterisks — fine anywhere) or __text__ (underscores — require word boundary)
        if (formatted.includes('**')) formatted = formatted.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
        if (formatted.includes('__')) formatted = formatted.replace(/(?<!\w)__(.+?)__(?!\w)/g, '<strong>$1</strong>');

        // Italic *text* (asterisks — fine anywhere) or _text_ (underscores — require word boundary
        // so that underscores inside names/identifiers like @Cool_User#a1b2 are not treated as italic)
        if (formatted.includes('*')) formatted = formatted.replace(/(?<![:/])\*([^*\s][^*]*)\*/g, '<em>$1</em>');
        if (formatted.includes('_')) formatted = formatted.replace(/(?<![:/\w])_([^_\s][^_]*)_(?!\w)/g, '<em>$1</em>');

        // Strikethrough ~~text~~
        if (formatted.includes('~~')) formatted = formatted.replace(/~~(.+?)~~/g, '<del>$1</del>');

        // Blockquotes > text
        if (formatted.includes('&gt; ')) formatted = formatted.replace(/^&gt; (.+)$/gm, '<blockquote>$1</blockquote>');

        // Headers (#, ##, ### collapsed into one pass)
        if (formatted.includes('# ')) {
            formatted = formatted.replace(/^(#{1,3}) (.+)$/gm, (match, hashes, text) => {
                const level = hashes.length;
                return `<h${level}>${text}</h${level}>`;
            });
        }

        // Media + URL handling all require a scheme; skip the whole group otherwise.
        if (formatted.includes('://')) {
            // Convert video URLs to video players
            // Use __VID_n__ placeholders to prevent the general URL-to-link regex from
            // matching URLs that are already embedded inside video HTML attributes.
            const mediaPlaceholders = [];
            const buildFallbackAttr = (url) => {
                const mirrors = this.mediaFallbacks ? this.mediaFallbacks.get(url) : null;
                if (!mirrors || !mirrors.length) return '';
                const proxied = mirrors.map(m => this.getProxiedMediaUrl(m));
                return ` data-media-fallbacks="${this.escapeHtml(proxied.join('|'))}"`;
            };
            if (/\.(?:mp4|webm|ogg|mov)/i.test(formatted)) {
                formatted = formatted.replace(
                    /(https?:\/\/[^\s]+\.(mp4|webm|ogg|mov)(\?[^\s]*)?)/gi,
                    (match, url, ext) => {
                        const mimeTypes = { mp4: 'video/mp4', webm: 'video/webm', ogg: 'video/ogg', mov: 'video/mp4' };
                        const type = mimeTypes[ext.toLowerCase()] || 'video/mp4';
                        const proxiedUrl = this.getProxiedMediaUrl(url);
                        const fbAttr = buildFallbackAttr(url);
                        const idx = mediaPlaceholders.length;
                        mediaPlaceholders.push({
                            kind: 'video',
                            html: `<span class="video-container" data-action="stopPropagation"${fbAttr}><video controls playsinline webkit-playsinline preload="metadata" class="message-video"><source src="${proxiedUrl}" type="${type}"></video><button class="video-expand-btn" data-video-src="${proxiedUrl.replace(/"/g, '&quot;')}" data-action="expandVideoFromContainer">⛶</button></span>`
                        });
                        return `﷒${idx}﷓`;
                    }
                );
            }

            // Convert image URLs to images (proxied through Cloudflare worker for IP privacy)
            if (/\.(?:jpg|jpeg|png|gif|webp)/i.test(formatted)) {
                formatted = formatted.replace(
                    /(https?:\/\/[^\s]+\.(jpg|jpeg|png|gif|webp)(\?[^\s]*)?)/gi,
                    (match, url) => {
                        const proxiedUrl = this.getProxiedMediaUrl(url);
                        const fbAttr = buildFallbackAttr(url);
                        const idx = mediaPlaceholders.length;
                        mediaPlaceholders.push({
                            kind: 'image',
                            html: `<img src="${proxiedUrl}" alt="Image" data-action="expandImageFromData"${fbAttr} />`
                        });
                        return `﷒${idx}﷓`;
                    }
                );
            }

            // Convert Nymchat app channel links BEFORE general URLs
            if (formatted.includes('app.nym.bar')) {
                formatted = formatted.replace(
                    /https?:\/\/app\.nym\.bar\/#([egc]):([^\s<>"]+)/gi,
                    (match, prefix, channelId) => {
                        return `<span class="channel-link" data-action="channelLink" data-channel-ref="${prefix}:${this.escapeHtml(channelId)}">${match}</span>`;
                    }
                );
            }

            // Convert other URLs to links (but not placeholders)
            formatted = formatted.replace(
                /(https?:\/\/[^\s]+)(?![^<]*>)(?!__)/g,
                '<a href="$1" target="_blank" rel="noopener">$1</a>'
            );

            // Restore media placeholders; collapse runs of 2+ media items into a gallery
            if (mediaPlaceholders.length) {
                formatted = formatted.replace(
                    /(?:﷒(\d+)﷓)(?:[ \t\r\n]*﷒(\d+)﷓)+/g,
                    (run) => {
                        const indices = [];
                        run.replace(/﷒(\d+)﷓/g, (_m, idx) => { indices.push(parseInt(idx, 10)); return ''; });
                        const inner = indices.map(i => mediaPlaceholders[i].html).join('');
                        const count = indices.length;
                        const sizeClass = count === 2 ? 'gallery-2' : count === 3 ? 'gallery-3' : 'gallery-4plus';
                        return `<div class="message-gallery ${sizeClass}" data-count="${count}">${inner}</div>`;
                    }
                );
                formatted = formatted.replace(/﷒(\d+)﷓/g, (_m, idx) => mediaPlaceholders[parseInt(idx, 10)].html);
            }
        }

        // Process mentions and channel references (both geohash and non-geohash) in one pass.
        // The trailing (?![^<]*>) prevents matches inside HTML attribute values
        // (e.g. inside an <a href="...@user/...">), which would otherwise consume
        // the closing quote and `>` of the tag and break the rendered HTML.
        if (formatted.includes('@') || formatted.includes('#')) {
        formatted = formatted.replace(
            /(?:(@[^@#\n]*?(?<!\s)#[0-9a-f]{4}\b)|(@[^@\s][^@\s]*)|(^|\s)(#[a-z0-9_-]+)(?=\s|$|[.,!?]))(?![^<]*>)/gi,
            (match, mentionWithSuffix, simpleMention, whitespace, channel) => {
                if (mentionWithSuffix) {
                    // Wrap the #suffix in nym-suffix span for proper dimming
                    const suffixIdx = mentionWithSuffix.search(/#[0-9a-f]{4}$/i);
                    const namePart = mentionWithSuffix.substring(0, suffixIdx);
                    const suffixPart = mentionWithSuffix.substring(suffixIdx);
                    return `<span class="nm-mention">${namePart}<span class="nym-suffix">${suffixPart}</span></span>`;
                } else if (simpleMention) {
                    return `<span class="nm-mention">${simpleMention}</span>`;
                } else if (channel) {
                    const channelName = channel.substring(1).trim().toLowerCase();

                    if (!channelName) {
                        return match;
                    }

                    const isGeohash = this.isValidGeohash(channelName);
                    const isActive = isGeohash
                        ? this.currentGeohash === channelName
                        : this.currentChannel === channelName;
                    const classes = ['channel-reference'];
                    if (isGeohash) classes.push('geohash-reference');
                    if (isActive) classes.push('active-channel');

                    let title;
                    if (isGeohash) {
                        const location = this.getGeohashLocation(channelName);
                        title = `Geohash channel`;
                        if (location) {
                            title += `: ${this.escapeHtml(location)}`;
                        }
                    } else {
                        title = `Channel: #${channelName}`;
                    }

                    return `${whitespace || ''}<span class="${classes.join(' ')} nm-underline" title="${title}" data-action="channelLink" data-channel-ref="g:${channelName}">${channel}</span>`;
                }
            }
        );
        }

        // Convert emoji shortcodes :emoji: — built-in unicode first, then NIP-30 custom emoji
        if (formatted.includes(':')) {
            formatted = formatted.replace(/:([a-zA-Z0-9_]+):/g, (match, code) => {
                const emoji = this.emojiMap[code.toLowerCase()];
                if (emoji) return emoji;
                if (this.customEmojis && this.customEmojis.has(code)) {
                    return this.renderCustomEmojiImg(code) || match;
                }
                return match;
            });
        }

        // Convert simple emoticons to emojis
        if (formatted.includes(':)')) formatted = formatted.replace(/(^|\s):\)($|\s)/g, '$1😊$2');
        if (formatted.includes(':(')) formatted = formatted.replace(/(^|\s):\(($|\s)/g, '$1😢$2');
        if (formatted.includes(':D')) formatted = formatted.replace(/(^|\s):D($|\s)/g, '$1😃$2');
        if (formatted.includes(':P')) formatted = formatted.replace(/(^|\s):P($|\s)/g, '$1😛$2');
        if (formatted.includes(';')) formatted = formatted.replace(/(^|\s);-?\)($|\s)/g, '$1😉$2');
        if (formatted.includes(':o') || formatted.includes(':O')) formatted = formatted.replace(/(^|\s):o($|\s)/gi, '$1😮$2');
        if (formatted.includes(':|')) formatted = formatted.replace(/(^|\s):\|($|\s)/g, '$1😐$2');
        if (formatted.includes('&lt;3')) formatted = formatted.replace(/(^|\s)&lt;3($|\s)/g, '$1❤️$2');
        if (formatted.includes('/\\')) formatted = formatted.replace(/(^|\s)\/\\($|\s)/g, '$1⚠️$2');

        // Wrap emoji characters in <span class="emoji"> to isolate them from --font-sans
        // This regex matches all Unicode emoji including: emoticons, symbols, dingbats,
        // skin tone modifiers, regional indicator flag sequences, variation selectors,
        // ZWJ sequences, keycap sequences (#️⃣ 0️⃣-9️⃣), and tag flag sequences.
        if (_RX_HAS_EMOJI.test(formatted)) {
            formatted = formatted.replace(
                /(?:<[^>]+>)|((?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)(?:[\u{E0020}-\u{E007E}]+\u{E007F})?)/gu,
                (match, emoji) => {
                    // If this is an HTML tag, skip it
                    if (!emoji) return match;
                    return `<span class="emoji">${match}</span>`;
                }
            );
        }

        // Restore code placeholders
        if (codePlaceholders.length) formatted = formatted.replace(/\uFDD0(\d+)\uFDD1/g, (m, idx) => codePlaceholders[idx]);

        // Handle game tokens
        if (formatted.includes('[gc:')) formatted = formatted.replace(/\n\[gc:([A-Za-z0-9+/=]+)\]/g, '<span class="game-token" aria-hidden="true">[gc:$1]</span>');

        // Line breaks
        if (formatted.includes('\n')) formatted = formatted.replace(/\n/g, '<br>');

        _formatCache.set(cacheKey, formatted);
        if (_formatCache.size > _FORMAT_CACHE_MAX) {
            _formatCache.delete(_formatCache.keys().next().value);
        }
        return formatted;
    },

    // Bump the formatMessage cache epoch so previously rendered content is
    // recomputed. Call when state that formatMessage reads — but isn't part of
    // the cache key — changes (custom emoji registration, media fallbacks).
    invalidateFormatCache() {
        _formatCacheEpoch++;
    },

    // Check if a raw message is emoji-only (1-6 emoji, optional whitespace, no other text)
    isEmojiOnly(content) {
        if (!content) return false;
        // Strip whitespace and check if remaining chars are all emoji (up to 6)
        const stripped = content.replace(_RX_WHITESPACE, '');
        return _RX_EMOJI_ONLY.test(stripped);
    },

    expandImage(src, context) {
        const modalImg = document.getElementById('modalImage');
        const modalVid = document.getElementById('modalVideo');
        if (window.resetImageModalZoom) window.resetImageModalZoom();
        modalImg.src = src;
        modalImg.style.display = '';
        modalVid.style.display = 'none';
        modalVid.pause();
        modalVid.removeAttribute('src');
        while (modalVid.firstChild) modalVid.firstChild.remove();
        if (context && Array.isArray(context.gallery) && context.gallery.length > 1) {
            window._imageModalGallery = { sources: context.gallery.slice(), index: context.index || 0 };
        } else {
            window._imageModalGallery = null;
        }
        if (typeof window.updateImageModalGalleryNav === 'function') window.updateImageModalGalleryNav();
        document.getElementById('imageModal').classList.add('active');
    },

    expandVideo(src) {
        const modalImg = document.getElementById('modalImage');
        const modalVid = document.getElementById('modalVideo');
        modalImg.style.display = 'none';
        modalImg.src = '';
        // Clear existing sources
        modalVid.removeAttribute('src');
        while (modalVid.firstChild) modalVid.firstChild.remove();

        const ext = src.split('.').pop().split('?')[0].toLowerCase();
        const mimeTypes = { mp4: 'video/mp4', webm: 'video/webm', ogg: 'video/ogg', mov: 'video/mp4' };
        const mimeType = mimeTypes[ext] || 'video/mp4';

        // If src is already a blob URL (from inline player fallback), use directly
        if (src.startsWith('blob:')) {
            modalVid.src = src;
        } else {
            // Try direct source first, fall back to blob URL for Safari compatibility
            const source = document.createElement('source');
            source.src = src;
            source.type = mimeType;
            modalVid.appendChild(source);

            const blobFallback = async () => {
                if (modalVid.dataset.blobLoaded === src) return;
                modalVid.dataset.blobLoaded = src;
                try {
                    const resp = await fetch(src);
                    const blob = await resp.blob();
                    modalVid.removeAttribute('src');
                    while (modalVid.firstChild) modalVid.firstChild.remove();
                    modalVid.src = URL.createObjectURL(blob);
                    modalVid.load();
                } catch (e) {
                    console.warn('Modal video blob fallback failed:', e);
                }
            };
            source.addEventListener('error', blobFallback, { once: true });
            modalVid.addEventListener('error', blobFallback, { once: true });
        }

        modalVid.load();
        modalVid.style.display = '';
        document.getElementById('imageModal').classList.add('active');
    },

    displaySystemMessage(content, type = 'system', { html = false } = {}) {
        const container = document.getElementById('messagesContainer');
        const messageEl = document.createElement('div');
        messageEl.className = type === 'action' ? 'action-message' : 'system-message';
        if (html) {
            messageEl.innerHTML = content;
        } else {
            messageEl.textContent = content;
        }
        container.appendChild(messageEl);

        this._scheduleScrollToBottom();
    },

    // The scroll viewport that wraps the message list.
    _getMessagesScroller() {
        return document.getElementById('messagesScroller');
    },

    // Coalesced scroll-to-bottom: batches multiple scroll requests into one rAF frame.
    _scheduleScrollToBottom(force = false) {
        if (!force && (!this.settings.autoscroll || this.userScrolledUp)) return;
        if (!force && this.virtualScroll.suppressAutoScroll) return;
        if (this._scrollRAF) return; // already scheduled

        this._scrollRAF = requestAnimationFrame(() => {
            this._scrollRAF = null;
            const scroller = this._getMessagesScroller();
            // The list lives in a reverse-column flex container, so scrollTop
            // is 0 at the bottom (newest) and negative scrolling up.
            if (scroller) scroller.scrollTop = 0;
        });
    },

    _applyBubbleGroupingTo(el) {
        if (!el || !el.classList || !el.dataset || !el.dataset.pubkey) return;
        const groupWindowMs = 5 * 60 * 1000;
        const prev = el.previousElementSibling;
        const samePrev = prev
            && prev.dataset
            && prev.dataset.pubkey === el.dataset.pubkey
            && !!el.dataset.messageId
            && !!prev.dataset.messageId;
        const ts = parseInt(el.dataset.timestamp) || 0;
        const prevTs = prev ? (parseInt(prev.dataset.timestamp) || 0) : 0;
        const inWindow = samePrev && ts && prevTs && Math.abs(ts - prevTs) <= groupWindowMs;
        el.classList.toggle('bubble-grouped', !!inWindow);
    },

    _updateBubbleGrouping(messageEl) {
        if (!messageEl) return;
        if (this._suppressBubbleRewrap) return;
        const container = document.getElementById('messagesContainer');
        if (container && (container.contains(messageEl) || messageEl.parentNode === null)) {
            this._rewrapBubbleGroups(container);
            const messages = container.querySelectorAll('[data-message-id]');
            for (let i = 0; i < messages.length; i++) {
                this._applyBubbleGroupingTo(messages[i]);
            }
            return;
        }
        this._applyBubbleGroupingTo(messageEl);
        this._applyBubbleGroupingTo(messageEl.nextElementSibling);
    },

    _recomputeAllBubbleGrouping(container) {
        if (!container) return;
        this._rewrapBubbleGroups(container);
        const messages = container.querySelectorAll('[data-message-id]');
        for (let i = 0; i < messages.length; i++) {
            this._applyBubbleGroupingTo(messages[i]);
        }
    },

    _rewrapBubbleGroups(container) {
        if (!container) return;
        const isBubble = document.body.classList.contains('chat-bubbles');

        const wrappers = Array.from(container.children).filter(c => c.classList && c.classList.contains('message-group'));
        const salvagedAvatars = new Map();
        for (const wrapper of wrappers) {
            if (this._sharedGroupRO && wrapper._observedStack) {
                this._sharedGroupRO.unobserve(wrapper._observedStack);
                wrapper._observedStack = null;
            }
            const pk = wrapper.dataset.pubkey || '';
            const avatarImg = wrapper.querySelector(':scope > .message-group-avatar > img.avatar-bubble');
            if (pk && avatarImg) {
                let bin = salvagedAvatars.get(pk);
                if (!bin) { bin = []; salvagedAvatars.set(pk, bin); }
                bin.push(avatarImg);
            }
            const stack = wrapper.querySelector(':scope > .message-group-stack');
            if (stack) {
                const msgs = Array.from(stack.children);
                for (const m of msgs) container.insertBefore(m, wrapper);
            }
            wrapper.remove();
        }

        if (!isBubble) return;

        const groupWindowMs = 5 * 60 * 1000;
        const children = Array.from(container.children);
        let currentGroup = null;
        let lastPubkey = null;
        let lastTs = 0;

        for (const child of children) {
            const isMessage = child.classList && child.classList.contains('message')
                && child.dataset && child.dataset.pubkey && child.dataset.messageId;
            if (!isMessage) {
                currentGroup = null;
                lastPubkey = null;
                lastTs = 0;
                continue;
            }
            if (child.classList.contains('blocked-user-message')) {
                currentGroup = null;
                lastPubkey = null;
                lastTs = 0;
                continue;
            }
            const ts = parseInt(child.dataset.timestamp) || 0;
            const pk = child.dataset.pubkey;
            const sameAuthor = pk === lastPubkey;
            const inWindow = sameAuthor && lastTs && ts && Math.abs(ts - lastTs) <= groupWindowMs;

            if (!inWindow || !currentGroup) {
                const bin = salvagedAvatars.get(pk);
                const reusableImg = (bin && bin.length) ? bin.shift() : null;
                currentGroup = this._createMessageGroupWrapper(child, reusableImg);
                container.insertBefore(currentGroup, child);
            }
            currentGroup.querySelector(':scope > .message-group-stack').appendChild(child);
            lastPubkey = pk;
            lastTs = ts;
        }

        const finalWrappers = container.querySelectorAll(':scope > .message-group');
        for (const wrapper of finalWrappers) {
            this._scheduleGroupAvatarSync(wrapper);
        }
    },

    _syncMessageGroupAvatarOffset(wrapper) {
        if (!wrapper) return;
        const avatarBox = wrapper.querySelector(':scope > .message-group-avatar');
        const stack = wrapper.querySelector(':scope > .message-group-stack');
        if (!avatarBox || !stack) return;
        const lastMsg = stack.lastElementChild;
        if (!lastMsg) {
            avatarBox.style.marginBottom = '';
            return;
        }
        const contentEl = lastMsg.querySelector(':scope > .message-content');
        if (!contentEl) {
            avatarBox.style.marginBottom = '';
            return;
        }
        const wrapperRect = wrapper.getBoundingClientRect();
        const contentRect = contentEl.getBoundingClientRect();
        const below = wrapperRect.bottom - contentRect.bottom;
        avatarBox.style.marginBottom = below > 0 ? below + 'px' : '';
    },

    _scheduleGroupAvatarSync(wrapper) {
        if (!wrapper) return;
        if (!this._pendingAvatarSyncs) this._pendingAvatarSyncs = new Set();
        this._pendingAvatarSyncs.add(wrapper);
        if (this._avatarSyncRAF) return;
        this._avatarSyncRAF = requestAnimationFrame(() => {
            this._avatarSyncRAF = null;
            const wrappers = this._pendingAvatarSyncs;
            this._pendingAvatarSyncs = new Set();
            for (const w of wrappers) {
                if (w.isConnected) this._syncMessageGroupAvatarOffset(w);
            }
        });
    },

    _ensureSharedGroupResizeObserver() {
        if (this._sharedGroupRO || typeof ResizeObserver === 'undefined') return this._sharedGroupRO;
        this._sharedGroupRO = new ResizeObserver(entries => {
            for (const entry of entries) {
                const stack = entry.target;
                const wrapper = stack.closest && stack.closest('.message-group');
                if (wrapper) this._scheduleGroupAvatarSync(wrapper);
            }
        });
        return this._sharedGroupRO;
    },

    _ensureLazyVideoObserver() {
        if (this._lazyVideoIO || typeof IntersectionObserver === 'undefined') return this._lazyVideoIO;
        this._lazyVideoIO = new IntersectionObserver(entries => {
            for (const e of entries) {
                if (!e.isIntersecting) continue;
                const vid = e.target;
                this._lazyVideoIO.unobserve(vid);
                if (!vid.dataset.lazyLoaded) {
                    vid.dataset.lazyLoaded = '1';
                    try { vid.load(); } catch (_) {}
                }
            }
        }, { rootMargin: '300px 0px' });
        return this._lazyVideoIO;
    },

    _observeLazyVideo(vid) {
        const io = this._ensureLazyVideoObserver();
        if (io) io.observe(vid);
        else { try { vid.load(); } catch (_) {} }
    },

    _createMessageGroupWrapper(firstMessageEl, reusableAvatarImg = null) {
        const wrapper = document.createElement('div');
        wrapper.className = 'message-group';
        const pubkey = firstMessageEl.dataset.pubkey || '';
        wrapper.dataset.pubkey = pubkey;
        if (firstMessageEl.classList.contains('self')) wrapper.classList.add('group-self');
        if (firstMessageEl.classList.contains('pm')) wrapper.classList.add('group-pm');

        const avatarBox = document.createElement('div');
        avatarBox.className = 'message-group-avatar';
        const safePk = this._safePubkey(pubkey);
        let img;
        if (reusableAvatarImg) {
            img = reusableAvatarImg;
        } else {
            img = document.createElement('img');
            img.className = 'avatar-bubble';
            img.alt = '';
            img.loading = 'lazy';
            if (safePk) img.dataset.avatarPubkey = safePk;
            img.src = this.getAvatarUrl(pubkey);
            const fallback = this.generateAvatarSvg(safePk);
            img.onerror = function () { this.onerror = null; this.src = fallback; };
        }
        avatarBox.appendChild(img);
        avatarBox.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            const stackEl = wrapper.querySelector(':scope > .message-group-stack');
            const lastMsg = stackEl && stackEl.lastElementChild;
            if (!lastMsg) return;
            const author = lastMsg.dataset.author || '';
            const content = lastMsg.dataset.rawContent || '';
            const msgId = lastMsg.dataset.messageId || '';
            this.showContextMenu(e, author, pubkey, content, msgId, false, msgId);
        });

        const stack = document.createElement('div');
        stack.className = 'message-group-stack';

        wrapper.appendChild(avatarBox);
        wrapper.appendChild(stack);

        const ro = this._ensureSharedGroupResizeObserver();
        if (ro) {
            ro.observe(stack);
            wrapper._observedStack = stack;
        }

        return wrapper;
    },

    setQuoteReply(author, text) {
        // Strip all nested quotes — only keep the last message being quoted
        const MAX_NESTED = 1;
        const strippedLines = [];
        for (const line of text.split('\n')) {
            let depth = 0;
            let tmp = line;
            while (tmp.startsWith('>')) {
                depth++;
                tmp = tmp.substring(1).trimStart();
            }
            if (depth < MAX_NESTED) {
                strippedLines.push(line);
            }
        }
        const strippedText = strippedLines.join('\n').replace(/\n{3,}/g, '\n\n').trim();
        this.pendingQuote = { author, text: strippedText, fullText: text };
        const preview = document.getElementById('quotePreview');
        const authorEl = document.getElementById('quotePreviewAuthor');
        const textEl = document.getElementById('quotePreviewText');
        authorEl.textContent = `@${author}`;
        // Strip markdown/HTML and truncate for preview
        const cleanText = text.replace(/<[^>]*>/g, '').replace(/[*_~`>#]/g, '');
        textEl.textContent = cleanText.length > 120 ? cleanText.substring(0, 120) + '...' : cleanText;
        preview.style.display = 'flex';
        const input = document.getElementById('messageInput');
        input.focus();
    },

    clearQuoteReply() {
        this.pendingQuote = null;
        const preview = document.getElementById('quotePreview');
        if (preview) preview.style.display = 'none';
    },

    startEditMessage(contextData) {
        const { messageId, content, pubkey } = contextData;
        if (!messageId || !content || pubkey !== this.pubkey) return;

        // Determine message context for later sending
        let isPM = false;
        let isGroup = false;
        let groupId = null;
        let conversationKey = null;
        let nymMessageId = null;

        if (this.inPMMode && this.currentGroup) {
            isPM = true;
            isGroup = true;
            groupId = this.currentGroup;
            conversationKey = this.getGroupConversationKey(this.currentGroup);
            // Find the nymMessageId from stored messages
            const msgs = this.pmMessages.get(conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.nymMessageId === messageId || m.id === messageId);
                if (msg) nymMessageId = msg.nymMessageId;
            }
        } else if (this.inPMMode && this.currentPM) {
            isPM = true;
            conversationKey = this.getPMConversationKey(this.currentPM);
            const msgs = this.pmMessages.get(conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.nymMessageId === messageId || m.id === messageId);
                if (msg) nymMessageId = msg.nymMessageId;
            }
        }

        this.pendingEdit = { messageId, content, pubkey, isPM, isGroup, groupId, conversationKey, nymMessageId };

        // Clear any pending quote
        this.clearQuoteReply();

        // Show edit preview bar
        const preview = document.getElementById('editPreview');
        const textEl = document.getElementById('editPreviewText');
        const cleanText = content.replace(/<[^>]*>/g, '').replace(/[*_~`>#]/g, '');
        textEl.textContent = cleanText.length > 120 ? cleanText.substring(0, 120) + '...' : cleanText;
        preview.style.display = 'flex';

        // Populate input with original content
        const input = document.getElementById('messageInput');
        input.value = content;
        input.focus();
        this.autoResizeTextarea(input);
    },

    cancelEditMessage() {
        this.pendingEdit = null;
        const preview = document.getElementById('editPreview');
        if (preview) preview.style.display = 'none';
        const input = document.getElementById('messageInput');
        input.value = '';
        this.autoResizeTextarea(input);
    },

    async publishEditedChannelMessage(newContent, originalEventId) {
        try {
            if (!this.connected) throw new Error('Not connected to relay');

            const channelKey = this.currentGeohash || 'nymchat';
            const wire = this.channelWire(channelKey);

            const now = Math.floor(Date.now() / 1000);
            const tags = [
                ['n', this.nym],
                [wire.tag, channelKey],
                ['edit', originalEventId]
            ];

            let event = {
                kind: wire.kind,
                created_at: now,
                tags: tags,
                content: newContent,
                pubkey: this.pubkey
            };

            const editDifficulty = this._effectivePowDifficulty();
            if (editDifficulty > 0) {
                event = await this._minePow(event, editDifficulty);
            }

            const signedEvent = await this.signEvent(event);

            // Track this edit locally so it replaces the original visually
            this.editedMessages.set(originalEventId, {
                newContent,
                editEventId: signedEvent.id,
                timestamp: new Date(now * 1000)
            });

            // Update the original message in stored messages
            this.messages.forEach((msgs, channel) => {
                const msg = msgs.find(m => m.id === originalEventId);
                if (msg) {
                    msg.content = newContent;
                    msg.isEdited = true;
                    msg._dirty = true;
                    this.persistChannelMessages(channel);
                }
            });

            // Update DOM in-place
            this.updateMessageInDOM(originalEventId, newContent);

            // Send to relay
            this.sendToRelay(['EVENT', signedEvent]);

            // Ensure geo relays for this channel also receive the edit
            if (wire.isGeohash) this.ensureGeoRelayDelivery(signedEvent, channelKey);

            // Schedule deletion if redacted cosmetic is active
            if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                setTimeout(() => { this.publishDeletionEvent(signedEvent.id); }, 600000);
            }

            return true;
        } catch (error) {
            this.displaySystemMessage('Failed to edit message: ' + error.message);
            return false;
        }
    },

    updateMessageInDOM(messageId, newContent) {
        const msgEl = this.findMessageElementAnywhere(messageId);
        if (!msgEl) return;

        // Update raw content data attribute
        msgEl.dataset.rawContent = newContent;

        // Find the message-content element and update its content
        const contentEl = msgEl.querySelector('.message-content');
        if (contentEl) {
            const bubbleTimeEl = contentEl.querySelector('.bubble-time-inner');
            const hoverButtonsEl = contentEl.querySelector('.msg-hover-buttons');
            const formattedContent = this.formatMessageWithQuotes(newContent);
            if (bubbleTimeEl) {
                if (!bubbleTimeEl.querySelector('.edited-indicator')) {
                    const bubbleEdited = document.createElement('span');
                    bubbleEdited.className = 'edited-indicator';
                    bubbleEdited.title = 'This message has been edited';
                    bubbleEdited.textContent = '(edited)';
                    bubbleTimeEl.insertBefore(bubbleEdited, bubbleTimeEl.firstChild);
                    bubbleTimeEl.insertBefore(document.createTextNode(' '), bubbleEdited.nextSibling);
                }
                contentEl.innerHTML = formattedContent + bubbleTimeEl.outerHTML + (hoverButtonsEl ? hoverButtonsEl.outerHTML : '');
            } else {
                contentEl.innerHTML = formattedContent + (hoverButtonsEl ? hoverButtonsEl.outerHTML : '');
            }
        }

        // Add IRC-style edited indicator after message-content (for IRC layout)
        if (!msgEl.querySelector('.edited-indicator-irc')) {
            const ircIndicator = document.createElement('span');
            ircIndicator.className = 'edited-indicator edited-indicator-irc';
            ircIndicator.title = 'This message has been edited';
            ircIndicator.textContent = '(edited)';
            // Insert after message-content
            if (contentEl && contentEl.nextSibling) {
                msgEl.insertBefore(ircIndicator, contentEl.nextSibling);
            } else {
                msgEl.appendChild(ircIndicator);
            }
        }
    },

    _getSwipeActionConfig(action) {
        const ACTIONS = {
            quote: {
                icon: '<svg viewBox="0 0 24 24"><polyline points="9 14 4 9 9 4"></polyline><path d="M20 20v-7a4 4 0 0 0-4-4H4"></path></svg>',
                run: (msgEl) => {
                    if (!msgEl.dataset.pubkey) return;
                    const baseNym = this.stripPubkeySuffix(msgEl.dataset.author || 'nym');
                    const suffix = this.getPubkeySuffix(msgEl.dataset.pubkey);
                    const authorText = `${baseNym}#${suffix}`;
                    const cleanContent = msgEl.dataset.rawContent || msgEl.querySelector('.message-content')?.textContent.replace(/\d{1,2}:\d{2}\s*(AM|PM)?\s*$/i, '').trim();
                    if (cleanContent) this.setQuoteReply(authorText, cleanContent);
                }
            },
            translate: {
                icon: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="m12.87 15.07-2.54-2.51.03-.03A17.52 17.52 0 0 0 14.07 6H17V4h-7V2H8v2H1v1.99h11.17C11.5 7.92 10.44 9.75 9 11.35 8.07 10.32 7.3 9.19 6.69 8h-2c.73 1.63 1.73 3.17 2.98 4.56l-5.09 5.02L4 19l5-5 3.11 3.11.76-2.04zM18.5 10h-2L12 22h2l1.12-3h4.75L21 22h2l-4.5-12zm-2.62 7 1.62-4.33L19.12 17h-3.24z"/></svg>',
                run: (msgEl) => {
                    const messageId = msgEl.dataset.messageId;
                    const content = msgEl.dataset.rawContent || msgEl.querySelector('.message-content')?.textContent.replace(/\d{1,2}:\d{2}\s*(AM|PM)?\s*$/i, '').trim();
                    if (content) this.translateMessage(content, messageId);
                }
            },
            copy: {
                icon: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="14" rx="1"></rect><path d="M5 16V4a1 1 0 0 1 1-1h10"></path></svg>',
                run: async (msgEl) => {
                    const content = msgEl.dataset.rawContent || msgEl.querySelector('.message-content')?.textContent.replace(/\d{1,2}:\d{2}\s*(AM|PM)?\s*$/i, '').trim();
                    if (!content) return;
                    try {
                        await navigator.clipboard.writeText(content);
                        this.displaySystemMessage('Message copied to clipboard');
                    } catch (_) {
                        this.displaySystemMessage('Failed to copy message');
                    }
                }
            },
            react: {
                icon: (() => {
                    const emoji = (this.settings && this.settings.swipeReactEmoji) || '❤️';
                    const m = typeof emoji === 'string' && emoji.match(/^:([a-zA-Z0-9_]+):$/);
                    if (m && this.customEmojis && this.customEmojis.has(m[1])) {
                        const img = this.renderCustomEmojiImg(m[1], 'swipe-react-emoji-img');
                        if (img) return img;
                    }
                    return `<span class="swipe-react-emoji">${this.escapeHtml(emoji)}</span>`;
                })(),
                run: (msgEl) => {
                    const messageId = msgEl.dataset.messageId;
                    if (!messageId) return;
                    const emoji = (this.settings && this.settings.swipeReactEmoji) || '❤️';
                    if (typeof this.sendReaction === 'function') {
                        this.sendReaction(messageId, emoji);
                    }
                }
            },
            zap: {
                icon: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M13 2 L4 14 H10 L10 22 L20 10 H14 Z"/></svg>',
                run: async (msgEl) => {
                    const messageId = msgEl.dataset.messageId;
                    const targetPubkey = msgEl.dataset.pubkey;
                    if (!messageId || !targetPubkey) return;
                    if (targetPubkey === this.pubkey) {
                        this.displaySystemMessage('Cannot zap your own message');
                        return;
                    }
                    const baseNym = this.stripPubkeySuffix(msgEl.dataset.author || 'nym');
                    this.displaySystemMessage(`Checking if @${baseNym} can receive zaps...`);
                    try {
                        const lnAddress = await this.fetchLightningAddressForUser(targetPubkey);
                        if (lnAddress) {
                            this.showZapModal(messageId, targetPubkey, baseNym);
                        } else {
                            this.displaySystemMessage(`@${baseNym} cannot receive zaps (no lightning address set)`);
                        }
                    } catch (_) {
                        this.displaySystemMessage(`Failed to check if @${baseNym} can receive zaps`);
                    }
                }
            },
            slap: {
                icon: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M 1 8 Q 3 4 8 4 Q 11 4 13 6 L 15 4.5 L 15 11.5 L 13 10 Q 11 12 8 12 Q 3 12 1 8 Z" /><circle cx="5" cy="7.5" r="0.7" fill="currentColor" /><path d="M 9 6.5 Q 10 8 9 9.5" stroke-linecap="round" /></svg>',
                run: (msgEl) => {
                    const targetPubkey = msgEl.dataset.pubkey;
                    if (!targetPubkey || targetPubkey === this.pubkey) return;
                    if (typeof this.cmdSlap === 'function') this.cmdSlap(targetPubkey);
                }
            },
            hug: {
                icon: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="6" cy="5" r="2" /><circle cx="10" cy="5" r="2" /><path d="M 2 14 C 2 10 4 9 6 9 C 7 9 7.5 9.5 8 10 C 8.5 9.5 9 9 10 9 C 12 9 14 10 14 14" stroke-linecap="round" stroke-linejoin="round" /><path d="M 4 11.5 Q 8 9 12 11.5" stroke-linecap="round" /></svg>',
                run: (msgEl) => {
                    const targetPubkey = msgEl.dataset.pubkey;
                    if (!targetPubkey || targetPubkey === this.pubkey) return;
                    if (typeof this.cmdHug === 'function') this.cmdHug(targetPubkey);
                }
            },
            none: { icon: '', run: () => {} }
        };
        return ACTIONS[action] || null;
    },

    setupSwipeToReply() {
        const container = document.getElementById('messagesContainer');
        if (!container) return;

        let startX = 0;
        let startY = 0;
        let currentEl = null;
        let avatarEl = null;
        let direction = 0;
        let isSwiping = false;
        let swipeDistance = 0;
        let thresholdHapticFired = false;

        const getActions = () => {
            const enabled = this.settings && this.settings.gesturesEnabled !== false;
            return {
                enabled,
                left: enabled ? (this.settings?.swipeLeftAction || 'quote') : 'none',
                right: enabled ? (this.settings?.swipeRightAction || 'translate') : 'none',
                threshold: Math.max(30, Math.min(120, parseInt(this.settings?.swipeThreshold || 60, 10) || 60))
            };
        };

        // For bubble layout: find the sibling avatar when the swiped message
        // sits next to it (the last bubble in its group's stack).
        const findGroupAvatar = (msgEl) => {
            const stack = msgEl.parentElement;
            if (!stack || !stack.classList.contains('message-group-stack')) return null;
            if (stack.lastElementChild !== msgEl) return null;
            const group = stack.parentElement;
            if (!group || !group.classList.contains('message-group')) return null;
            return group.querySelector(':scope > .message-group-avatar');
        };

        container.addEventListener('touchstart', (e) => {
            const cfg = getActions();
            if (!cfg.enabled) return;
            const msgEl = e.target.closest('.message');
            if (!msgEl || !msgEl.dataset.messageId) return;

            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
            currentEl = msgEl;
            avatarEl = findGroupAvatar(msgEl);
            direction = 0;
            isSwiping = false;
            swipeDistance = 0;
            thresholdHapticFired = false;
        }, { passive: true });

        // Edge zone reserved for the sidebar-open gesture; right swipes that
        // start inside it defer to the sidebar so the message gesture doesn't
        // partially trigger.
        const EDGE_ZONE = 50;
        // Require a slightly larger initial horizontal travel before we
        // claim the gesture, which makes accidental drags less likely.
        const SWIPE_START_THRESHOLD = 16;

        container.addEventListener('touchmove', (e) => {
            if (!currentEl) return;
            const cfg = getActions();

            const dx = e.touches[0].clientX - startX;
            const absDx = Math.abs(dx);
            const dy = Math.abs(e.touches[0].clientY - startY);

            if (!isSwiping && absDx > SWIPE_START_THRESHOLD && absDx > dy * 1.5) {
                direction = dx < 0 ? -1 : 1;
                // Defer to sidebar-open gesture: it runs on right swipes that
                // begin within EDGE_ZONE of the left edge.
                if (direction > 0 && startX < EDGE_ZONE) {
                    currentEl = null;
                    return;
                }
                const action = direction < 0 ? cfg.left : cfg.right;
                if (!action || action === 'none' || !this._getSwipeActionConfig(action)) {
                    currentEl = null;
                    return;
                }
                isSwiping = true;
            }
            if (!isSwiping) return;

            e.preventDefault();
            swipeDistance = Math.min(absDx, 100);
            const signed = direction < 0 ? -swipeDistance : swipeDistance;
            currentEl.style.transform = `translateX(${signed}px)`;
            currentEl.style.transition = 'none';
            if (avatarEl) {
                avatarEl.style.transform = `translateX(${signed}px)`;
                avatarEl.style.transition = 'none';
            }

            const isRightSwipeWithAvatar = direction > 0 && !!avatarEl;
            const indicatorClass = direction < 0
                ? 'swipe-reply-indicator'
                : 'swipe-reply-indicator swipe-reply-indicator-left' +
                    (isRightSwipeWithAvatar ? ' swipe-reply-indicator-past-avatar' : '');
            let indicator = currentEl.querySelector('.swipe-reply-indicator');
            if (!indicator) {
                indicator = document.createElement('div');
                indicator.className = indicatorClass;
                const action = direction < 0 ? cfg.left : cfg.right;
                const actionCfg = this._getSwipeActionConfig(action);
                indicator.innerHTML = actionCfg ? actionCfg.icon : '';
                currentEl.appendChild(indicator);
            } else {
                indicator.className = indicatorClass;
            }
            const pastThreshold = swipeDistance >= cfg.threshold;
            indicator.classList.toggle('visible', pastThreshold);
            if (pastThreshold && !thresholdHapticFired) {
                thresholdHapticFired = true;
                window.nymHapticTap && window.nymHapticTap();
            } else if (!pastThreshold) {
                thresholdHapticFired = false;
            }
        }, { passive: false });

        const handleTouchEnd = () => {
            if (!currentEl) return;
            const cfg = getActions();

            if (isSwiping && swipeDistance >= cfg.threshold) {
                const action = direction < 0 ? cfg.left : cfg.right;
                const actionCfg = this._getSwipeActionConfig(action);
                if (actionCfg) actionCfg.run(currentEl);
            }

            currentEl.style.transition = 'transform 0.25s ease-out';
            currentEl.style.transform = '';
            if (avatarEl) {
                avatarEl.style.transition = 'transform 0.25s ease-out';
                avatarEl.style.transform = '';
            }

            const indicator = currentEl.querySelector('.swipe-reply-indicator');
            if (indicator) {
                setTimeout(() => indicator.remove(), 250);
            }

            currentEl = null;
            avatarEl = null;
            direction = 0;
            isSwiping = false;
            swipeDistance = 0;
        };

        container.addEventListener('touchend', handleTouchEnd, { passive: true });
        container.addEventListener('touchcancel', handleTouchEnd, { passive: true });
    },

    setupDoubleClickToReply() {
        const container = document.getElementById('messagesContainer');
        if (!container) return;

        container.addEventListener('dblclick', (e) => {
            // Skip if on mobile (swipe handles it)
            if ('ontouchstart' in window) return;

            const msgEl = e.target.closest('.message');
            if (!msgEl || !msgEl.dataset.messageId) return;

            // Don't trigger on author name clicks (context menu) or links
            if (e.target.closest('a') || e.target.closest('.message-author')) return;

            if (!msgEl.dataset.pubkey) return;

            // Build clean author from data attributes to avoid flair emoji leaking into quote text
            const baseNym = this.stripPubkeySuffix(msgEl.dataset.author || 'nym');
            const suffix = this.getPubkeySuffix(msgEl.dataset.pubkey);
            const authorText = `${baseNym}#${suffix}`;
            const cleanContent = msgEl.dataset.rawContent || msgEl.querySelector('.message-content')?.textContent.replace(/\d{1,2}:\d{2}\s*(AM|PM)?\s*$/i, '').trim();

            if (cleanContent) {
                // Clear any text selection caused by the double-click
                window.getSelection()?.removeAllRanges();
                this.setQuoteReply(authorText, cleanContent);
            }
        });
    },

    async sendMessage() {
        const input = document.getElementById('messageInput');
        let content = input.value.trim();

        if (!content && !this.pendingQuote) return;

        if (!this.connected) {
            this.displaySystemMessage('Not connected to relay. Please wait...');
            return;
        }

        // Handle edit mode: send edited message instead of new one
        if (this.pendingEdit) {
            const edit = this.pendingEdit;
            this.cancelEditMessage();

            if (content === edit.content) {
                // No changes made
                return;
            }

            if (edit.isGroup && edit.groupId) {
                await this.sendEditedGroupMessage(content, edit.messageId, edit.groupId, edit.nymMessageId);
            } else if (edit.isPM && this.currentPM) {
                await this.sendEditedPM(content, edit.messageId, this.currentPM, edit.nymMessageId);
            } else if (!edit.isPM) {
                await this.publishEditedChannelMessage(content, edit.messageId);
            }

            input.value = '';
            this.autoResizeTextarea(input);
            this.hideCommandPalette();
            this.hideAutocomplete();
            this.hideEmojiAutocomplete();
            this.sendTypingStop();
            this.sendChannelTypingStop();
            input.focus();
            return;
        }

        // Capture quote context before clearing (for bot reply support)
        const savedQuote = this.pendingQuote ? { author: this.pendingQuote.author, text: this.pendingQuote.text, fullText: this.pendingQuote.fullText } : null;
        const quoteData = savedQuote; // Pass to publishMessage for nymquote tag
        const rawInput = content; // User's typed text before quote prepend

        // Prepend quote if there's a pending quote reply
        if (this.pendingQuote) {
            const textLines = this.pendingQuote.text.split('\n');
            const quoteLine = `> @${this.pendingQuote.author}: ${textLines[0]}` +
                (textLines.length > 1 ? '\n' + textLines.slice(1).map(line => `> ${line}`).join('\n') : '');
            content = content ? `${quoteLine}\n\n${content}` : quoteLine;
            this.clearQuoteReply();
        }

        // Add to history
        this.commandHistory.push(content);
        this.historyIndex = this.commandHistory.length;

        if (content.startsWith('/')) {
            this.handleCommand(content);
        } else {
            if (this.inPMMode && this.currentGroup) {
                // Send to private group
                await this.sendGroupMessage(content, this.currentGroup);
            } else if (this.inPMMode && this.currentPM) {
                // Send 1:1 PM
                await this.sendPM(content, this.currentPM);
            } else if (this.currentGeohash) {
                // Send to geohash channel (kind 20000)
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash, quoteData);
                // Check for bot commands (? prefix or @Nymbot mention)
                // Use rawInput for trigger detection since quote prepend may hide the prefix
                const isBotCmd = rawInput.startsWith('?') || /@nymbot(?:#[a-f0-9]{4})?(?:\s|$)/i.test(rawInput);
                const isNymbotReply = savedQuote && /^nymbot(?:#[a-f0-9]{4})?$/i.test(savedQuote.author);
                if (isBotCmd || isNymbotReply) {
                    this._handleBotCommand(rawInput, this.currentGeohash, savedQuote, content);
                }
            }
        }

        input.value = '';
        this.autoResizeTextarea(input);
        this.hideCommandPalette();
        this.hideAutocomplete();
        this.hideEmojiAutocomplete();
        this.sendTypingStop();
        this.sendChannelTypingStop();
        input.focus();

        // Hardcore mode: rotate keypair after every sent message
        if (this.connectionMode === 'ephemeral' && localStorage.getItem('nym_keypair_mode') === 'hardcore') {
            await this.generateKeypair();
            this.nym = this.generateRandomNym();
            document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
            this.updateSidebarAvatar();
        }
    },

    async sendMessagePseudonymous() {
        const input = document.getElementById('messageInput');
        let content = input.value.trim();

        if (!content && !this.pendingQuote) return;

        if (!this.connected) {
            this.displaySystemMessage('Not connected to relay. Please wait...');
            return;
        }

        // Capture quote context before clearing (for bot reply support)
        const savedQuote = this.pendingQuote ? { author: this.pendingQuote.author, text: this.pendingQuote.text, fullText: this.pendingQuote.fullText } : null;
        const quoteData = savedQuote; // Pass to publishMessagePseudonymous for nymquote tag
        const rawInput = content;

        // Prepend quote if there's a pending quote reply
        if (this.pendingQuote) {
            const textLines = this.pendingQuote.text.split('\n');
            const quoteLine = `> @${this.pendingQuote.author}: ${textLines[0]}` +
                (textLines.length > 1 ? '\n' + textLines.slice(1).map(line => `> ${line}`).join('\n') : '');
            content = content ? `${quoteLine}\n\n${content}` : quoteLine;
            this.clearQuoteReply();
        }

        // Add to history
        this.commandHistory.push(content);
        this.historyIndex = this.commandHistory.length;

        if (content.startsWith('/')) {
            this.handleCommand(content);
        } else {
            if (this.inPMMode && this.currentGroup) {
                // Group messages always use the logged-in key
                await this.sendGroupMessage(content, this.currentGroup);
            } else if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentGeohash) {
                // Send via ephemeral keypair (pseudonymous)
                await this.publishMessagePseudonymous(content, this.currentGeohash, this.currentGeohash, quoteData);
                // Check for bot commands (? prefix or @Nymbot mention)
                const isBotCmd = rawInput.startsWith('?') || /@nymbot(?:#[a-f0-9]{4})?(?:\s|$)/i.test(rawInput);
                const isNymbotReply = savedQuote && /^nymbot(?:#[a-f0-9]{4})?$/i.test(savedQuote.author);
                if (isBotCmd || isNymbotReply) {
                    this._handleBotCommand(rawInput, this.currentGeohash, savedQuote, content);
                }
            }
        }

        input.value = '';
        this.autoResizeTextarea(input);
        this.hideCommandPalette();
        this.hideAutocomplete();
        this.hideEmojiAutocomplete();
        this.sendTypingStop();
        this.sendChannelTypingStop();
        input.focus();
    },

    hideMessagesFromBlockedUser(pubkey) {
        // Hide messages in current DOM
        document.querySelectorAll('.message').forEach(msg => {
            if (msg.dataset.pubkey === pubkey) {
                msg.style.display = 'none';
                msg.classList.add('blocked-user-message');
            }
        });

        // Hide bubble-mode group wrappers (so the avatar disappears too)
        document.querySelectorAll('.message-group').forEach(group => {
            if (group.dataset.pubkey === pubkey) {
                group.style.display = 'none';
                group.classList.add('blocked-user-group');
            }
        });

        // Mark messages as blocked in stored messages
        this.messages.forEach((channelMessages, channel) => {
            channelMessages.forEach(msg => {
                if (msg.pubkey === pubkey) {
                    msg.blocked = true;
                }
            });
        });

        // Mark PM messages as blocked
        this.pmMessages.forEach((conversationMessages, conversationKey) => {
            conversationMessages.forEach(msg => {
                if (msg.pubkey === pubkey) {
                    msg.blocked = true;
                }
            });
        });
    },

    hideMessagesWithBlockedKeywords() {
        // Hide messages in current DOM that contain blocked keywords (check both content and nickname)
        document.querySelectorAll('.message').forEach(msg => {
            const content = msg.querySelector('.message-content');
            const author = msg.dataset.author || '';
            const contentText = content ? content.textContent.toLowerCase() : '';
            const cleanNick = this.parseNymFromDisplay(author).toLowerCase();
            const hasBlocked = Array.from(this.blockedKeywords).some(kw =>
                contentText.includes(kw) || (cleanNick && cleanNick.includes(kw))
            );

            if (hasBlocked) {
                msg.style.display = 'none';
                msg.classList.add('blocked');
            }
        });

        // Mark messages as blocked in stored messages
        this.messages.forEach((channelMessages, channel) => {
            channelMessages.forEach(msg => {
                if (this.hasBlockedKeyword(msg.content, msg.author)) {
                    msg.blocked = true;
                }
            });
        });

        // Mark PM messages as blocked
        this.pmMessages.forEach((conversationMessages, conversationKey) => {
            conversationMessages.forEach(msg => {
                if (this.hasBlockedKeyword(msg.content, msg.author)) {
                    msg.blocked = true;
                }
            });
        });
    },

    showMessagesFromUnblockedUser(pubkey) {
        // Unmark messages in stored messages FIRST
        this.messages.forEach((channelMessages, channel) => {
            channelMessages.forEach(msg => {
                if (msg.pubkey === pubkey) {
                    delete msg.blocked;
                }
            });
        });

        // Unmark PM messages
        this.pmMessages.forEach((conversationMessages, conversationKey) => {
            conversationMessages.forEach(msg => {
                if (msg.pubkey === pubkey) {
                    delete msg.blocked;
                }
            });
        });

        // Show messages in current DOM (unless blocked by keywords)
        document.querySelectorAll('.message.blocked-user-message').forEach(msg => {
            if (msg.dataset.pubkey === pubkey) {
                const content = msg.querySelector('.message-content');
                if (!content || !this.hasBlockedKeyword(content.textContent)) {
                    msg.style.display = '';
                    msg.classList.remove('blocked-user-message');
                }
            }
        });

        // Restore bubble-mode group wrappers
        document.querySelectorAll('.message-group.blocked-user-group').forEach(group => {
            if (group.dataset.pubkey === pubkey) {
                group.style.display = '';
                group.classList.remove('blocked-user-group');
            }
        });
    },

    cacheCurrentContainerDOM() {
        const container = document.getElementById('messagesContainer');
        const previousKey = container.dataset.lastChannel;
        if (!previousKey || container.children.length === 0) return;

        const fragment = document.createDocumentFragment();
        while (container.firstChild) {
            fragment.appendChild(container.firstChild);
        }
        this.renderedMessageIds.clear();

        // Get message count and fingerprint for cache invalidation
        const messages = this.messages.get(previousKey) || this.pmMessages.get(previousKey) || [];
        this.channelDOMCache.set(previousKey, {
            fragment,
            messageCount: messages.length,
            messageFingerprint: this._computeMessageFingerprint(messages),
            bubbleMode: document.body.classList.contains('chat-bubbles'),
            virtualScrollState: {
                currentStartIndex: this.virtualScroll.currentStartIndex,
                currentEndIndex: this.virtualScroll.currentEndIndex
            }
        });

        // Limit cache to 5 channels to prevent memory bloat
        if (this.channelDOMCache.size > 5) {
            const oldestKey = this.channelDOMCache.keys().next().value;
            this.channelDOMCache.delete(oldestKey);
        }
    },

    // Compute a fingerprint of messages for cache invalidation
    _computeMessageFingerprint(messages) {
        if (!messages || messages.length === 0) return '';
        return messages.map(m => `${m.id}:${m._originalCreatedAt || m.created_at || 0}:${m.isEdited ? 'e' : ''}`).join('|');
    },

    findMessageElementAnywhere(messageId) {
        if (!messageId) return null;
        const safeId = String(messageId).replace(/"/g, '\\"');
        const live = document.querySelector(`[data-message-id="${safeId}"]`);
        if (live) return live;
        if (this.channelDOMCache && this.channelDOMCache.size > 0) {
            for (const cached of this.channelDOMCache.values()) {
                if (cached && cached.fragment) {
                    const el = cached.fragment.querySelector(`[data-message-id="${safeId}"]`);
                    if (el) return el;
                }
            }
        }
        return null;
    },

    loadChannelMessages(displayName) {
        const container = document.getElementById('messagesContainer');
        const storageKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;

        // Check if we're loading the same channel
        if (container.dataset.lastChannel === storageKey) {
            return;
        }

        // Cancel any in-progress batched render for the previous channel
        if (this._renderAbortKey) {
            this._renderAbortKey = null;
        }

        // Cache current container DOM before switching
        this.cacheCurrentContainerDOM();
        container.dataset.lastChannel = storageKey;

        // Try to restore from cache
        const channelMessages = this.messages.get(storageKey) || [];
        const cached = this.channelDOMCache.get(storageKey);

        if (cached && this._tryRestoreCachedDOM(container, cached, storageKey, channelMessages, false)) {
            return;
        }

        this.channelDOMCache.delete(storageKey);
        container.innerHTML = '';
        this.renderedMessageIds.clear();

        if (channelMessages.length === 0) {
            this.displaySystemMessage(`Joined ${displayName}`);
            this.renderChannelPolls();
            return;
        }

        // Use virtual scrolling for efficient rendering (batched to prevent freeze)
        this.renderMessagesWithVirtualScroll(container, storageKey, true);

        // Re-render any polls for this channel
        this.renderChannelPolls();
    },

    // Restore a cached DOM fragment into the container
    _tryRestoreCachedDOM(container, cached, storageKey, currentMessages, isPM) {
        const cachedCount = cached.messageCount || 0;
        const currentLen = currentMessages.length;

        if (cachedCount > currentLen) return false;

        const compareList = cachedCount === currentLen
            ? currentMessages
            : currentMessages.slice(0, cachedCount);
        const compareFp = this._computeMessageFingerprint(compareList);
        if (compareFp !== cached.messageFingerprint) return false;

        container.innerHTML = '';
        this.renderedMessageIds.clear();
        container.appendChild(cached.fragment);
        const restored = container.querySelectorAll('[data-message-id]');
        for (let i = 0; i < restored.length; i++) {
            const rid = restored[i].dataset && restored[i].dataset.messageId;
            if (rid) this.renderedMessageIds.add(rid);
        }
        this.channelDOMCache.delete(storageKey);

        if (cached.virtualScrollState) {
            this.virtualScroll.currentStartIndex = cached.virtualScrollState.currentStartIndex;
            this.virtualScroll.currentEndIndex = cached.virtualScrollState.currentEndIndex;
        }
        container.dataset.virtualScrollKey = storageKey;
        container.dataset.virtualScrollIsPM = isPM ? 'true' : 'false';

        // Partial hit: render trailing messages that arrived while we were away.
        let appendedTrailing = false;
        if (cachedCount < currentLen) {
            const trailing = currentMessages.slice(cachedCount);
            this.virtualScroll.suppressAutoScroll = true;
            this._suppressSound = true;
            this._suppressBubbleRewrap = true;
            for (let i = 0; i < trailing.length; i++) {
                this.displayMessage(trailing[i]);
            }
            this._suppressSound = false;
            this._suppressBubbleRewrap = false;
            this.virtualScroll.suppressAutoScroll = false;
            appendedTrailing = trailing.length > 0;
        }

        const currentBubbleMode = document.body.classList.contains('chat-bubbles');
        const bubbleModeMatches = cached.bubbleMode === currentBubbleMode;
        if (!bubbleModeMatches || appendedTrailing) {
            requestAnimationFrame(() => this._recomputeAllBubbleGrouping(container));
        }

        if (this.settings.autoscroll) {
            this.userScrolledUp = false;
            const scroller = this._getMessagesScroller();
            if (scroller) {
                scroller.scrollTop = 0;
                requestAnimationFrame(() => {
                    scroller.scrollTop = 0;
                });
            }
        }
        return true;
    },

    // Initialize virtual scroll for a container

    getFilteredMessages(storageKey) {
        const messages = this.messages.get(storageKey) || [];

        return messages.filter(msg => {
            if (this.deletedEventIds.has(msg.id)) return false;
            if (!msg.isOwn && !this.isFriend(msg.pubkey) &&
                !this.nymchatPubkeys.has(msg.pubkey) && this._isPubkeyGated(msg.pubkey)) {
                return false;
            }
            if (this.blockedUsers.has(msg.pubkey) || msg.blocked) return false;
            if (this.hasBlockedKeyword(msg.content, msg.author)) return false;
            if (this.isSpamMessage(msg.content)) return false;
            return true;
        });
    },

    renderMessagesWithVirtualScroll(container, storageKey, scrollToBottom = true, isPM = false) {
        const messages = isPM ? this.getFilteredPMMessages(storageKey) : this.getFilteredMessages(storageKey);

        container.dataset.virtualScrollKey = storageKey;
        container.dataset.virtualScrollIsPM = isPM ? 'true' : 'false';

        container.innerHTML = '';
        this.renderedMessageIds.clear();

        if (messages.length === 0) {
            return;
        }

        const fragment = document.createDocumentFragment();

        if (!isPM && messages.length >= this.channelMessageLimit) {
            const notice = document.createElement('div');
            notice.className = 'system-message channel-history-limit';
            notice.textContent = `You've reached the edge of this channel's history. Older messages are lost to the void — only the latest ${this.channelMessageLimit} messages are shown.`;
            fragment.appendChild(notice);
        }

        let renderMessages = messages;
        if (isPM && messages.length > this.pmPageSize) {
            const startIdx = messages.length - this.pmPageSize;
            renderMessages = messages.slice(startIdx);
            this.pmRenderedStart.set(storageKey, startIdx);
            const loadNotice = document.createElement('div');
            loadNotice.className = 'system-message pm-load-older';
            loadNotice.textContent = `Scroll up to load older messages (${startIdx} more)`;
            fragment.appendChild(loadNotice);
        } else if (isPM) {
            this.pmRenderedStart.set(storageKey, 0);
        }

        this.virtualScroll.suppressAutoScroll = true;
        this._suppressSound = true;
        this._suppressBubbleRewrap = true;
        this._pendingFragment = fragment;

        for (let i = 0; i < renderMessages.length; i++) {
            this.displayMessage(renderMessages[i]);
        }

        this._pendingFragment = null;
        container.appendChild(fragment);

        this._suppressSound = false;
        this._suppressBubbleRewrap = false;
        this.virtualScroll.suppressAutoScroll = false;

        requestAnimationFrame(() => this._recomputeAllBubbleGrouping(container));

        // Scroll to bottom if requested. The reverse-column container keeps
        // the bottom pinned as media loads afterwards, so no follow-up is needed.
        if (scrollToBottom && this.settings.autoscroll) {
            this.userScrolledUp = false;
            const scroller = this._getMessagesScroller();
            if (scroller) {
                scroller.scrollTop = 0;
                requestAnimationFrame(() => {
                    scroller.scrollTop = 0;
                });
            }
        }
    },

    refreshMessages() {
        // Clear user colors cache when theme changes
        this.userColors.clear();

        // Remove stale dynamic bitchat style elements so they regenerate for current mode
        this.cleanupBitchatStyles();

        // Re-display all messages to apply new colors
        const container = document.getElementById('messagesContainer');
        const messages = container.querySelectorAll('.message');

        messages.forEach(msg => {
            const pubkey = msg.dataset.pubkey;
            const authorElement = msg.querySelector('.message-author');
            const contentElement = msg.querySelector('.message-content');

            // Helper to swap bitchat classes on an element
            const updateBitchatClass = (el) => {
                if (!el) return;
                const classesToRemove = [];
                el.classList.forEach(cls => {
                    if (cls.startsWith('bitchat-user-') || cls === 'bitchat-theme') {
                        classesToRemove.push(cls);
                    }
                });
                classesToRemove.forEach(cls => el.classList.remove(cls));

                const colorClass = this.getUserColorClass(pubkey);
                if (colorClass) {
                    el.classList.add(colorClass);
                }
            };

            updateBitchatClass(authorElement);
            updateBitchatClass(contentElement);
        });

        // Also refresh user list
        this.updateUserList();
    },

    refreshMessageTimestamps() {
        // Update all visible timestamps to use new format
        document.querySelectorAll('.message-time').forEach(timeEl => {
            const timestamp = parseInt(timeEl.closest('.message').dataset.timestamp);
            if (timestamp) {
                const date = new Date(timestamp);
                const newTime = date.toLocaleTimeString('en-US', {
                    hour: '2-digit',
                    minute: '2-digit',
                    hour12: this.settings.timeFormat === '12hr'
                });
                timeEl.textContent = newTime;

                // Update class for spacing
                if (this.settings.timeFormat === '12hr') {
                    timeEl.classList.add('time-12hr');
                } else {
                    timeEl.classList.remove('time-12hr');
                }
            }
        });
    },

    cleanupBitchatStyles() {
        // Remove all dynamically created bitchat styles
        document.querySelectorAll('style[id^="bitchat-user-"]').forEach(style => {
            style.remove();
        });
    },

});
