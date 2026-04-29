// messages.js - Message rendering, formatting, sending, edits, quotes, swipe-to-reply, virtual scroll
// Methods are attached to NYM.prototype.

const _RX_REGEX_ESCAPE = /[.*+?^${}()|[\]\\]/g;
const _RX_HTML_TAG = /<[^>]*>/g;
const _RX_DUP_SUFFIX = /@([^@#\s]+)#([0-9a-f]{4})#\2\b/gi;
const _RX_WHITESPACE = /\s/g;
const _EMOJI_UNIT = '(?:[\\u{1F1E0}-\\u{1F1FF}]{2})|(?:[#*0-9]\\u{FE0F}?\\u{20E3})|(?:(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?(?:\\u{200D}(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?)*)(?:[\\u{E0020}-\\u{E007E}]+\\u{E007F})?';
const _RX_EMOJI_ONLY = new RegExp(`^(?:${_EMOJI_UNIT}){1,6}$`, 'u');

// Mention pattern is per-nym; cache so we recompile only when the active nym changes.
let _mentionPatternCache = { nym: null, pattern: null };
function _getMentionPattern(cleanNym) {
    if (_mentionPatternCache.nym === cleanNym) return _mentionPatternCache.pattern;
    const escaped = cleanNym.replace(_RX_REGEX_ESCAPE, '\\$&');
    const pattern = new RegExp(`@${escaped}(#[0-9a-f]{4})?(?:\\b|$)`, 'gi');
    _mentionPatternCache = { nym: cleanNym, pattern };
    return pattern;
}

Object.assign(NYM.prototype, {

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

    trackMessage(pubkey, channel, isHistorical = false) {
        // Don't track historical messages from initial load
        if (isHistorical) {
            return;
        }

        const now = Date.now();
        const channelKey = channel; // Use channel as key for per-channel tracking

        // Create channel-specific tracking
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
            return;
        }

        const tracking = channelTracking.get(pubkey);

        // Reset if more than 2 seconds have passed
        if (now - tracking.firstMessageTime > 2000) {
            tracking.count = 1;
            tracking.firstMessageTime = now;
            tracking.blocked = false;
        } else {
            tracking.count++;

            // Block if more than 10 messages in 2 seconds IN THIS CHANNEL
            if (tracking.count > 10 && !tracking.blocked) {
                tracking.blocked = true;
                tracking.blockedUntil = now + 900000; // 15 minutes

                const nym = this.getNymFromPubkey(pubkey);
            }
        }
    },

    isFlooding(pubkey, channel) {
        const channelTracking = this.floodTracking.get(channel);
        if (!channelTracking) return false;

        const tracking = channelTracking.get(pubkey);
        if (!tracking) return false;

        if (tracking.blocked) {
            const now = Date.now();
            if (now < tracking.blockedUntil) {
                return true;
            } else {
                // Unblock after timeout
                tracking.blocked = false;
                tracking.blockedUntil = null;
            }
        }

        return false;
    },

    isMentioned(content) {
        if (!content || !this.nym) return false;

        // Strip HTML from nym for comparison
        const cleanNym = this.parseNymFromDisplay(this.nym);

        // Cached, per-nym pattern (recompiled only when nym changes)
        const nymPattern = _getMentionPattern(cleanNym);
        nymPattern.lastIndex = 0;

        // Strip HTML from content and deduplicate suffixes for mention detection
        let cleanContent = content.replace(_RX_HTML_TAG, '');
        cleanContent = cleanContent.replace(_RX_DUP_SUFFIX, '@$1#$2');

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
        if (message.blocked || this.blockedUsers.has(message.pubkey) || this.isNymBlocked(message.author)) {
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

            // Always store channel messages in memory regardless of current view
            if (!this.messages.has(storageKey)) {
                this.messages.set(storageKey, []);
            }

            // Check if message already exists
            const exists = this.messages.get(storageKey).some(m => m.id === message.id);
            if (!exists) {
                // Track most recent message time for channel sort ordering
                const msgTime = (message.created_at || 0) * 1000;
                const prevActivity = this.channelLastActivity.get(storageKey) || 0;
                if (msgTime > prevActivity) {
                    this.channelLastActivity.set(storageKey, msgTime);
                    // Debounced sort so discovered/historical channels order by activity
                    if (this._sortDebounceTimer) clearTimeout(this._sortDebounceTimer);
                    this._sortDebounceTimer = setTimeout(() => {
                        this._sortDebounceTimer = null;
                        this.sortChannelsByActivity();
                    }, 300);
                }

                // Add message and sort by raw created_at (integer seconds) for
                // deterministic ordering across relays; arrival sequence breaks ties
                // within the same second (best proxy for actual send order).
                this.messages.get(storageKey).push(message);
                this.messages.get(storageKey).sort((a, b) => {
                    const dt = (a.created_at || 0) - (b.created_at || 0);
                    if (dt !== 0) return dt;
                    return (a._seq || 0) - (b._seq || 0);
                });

                // Prune in-memory messages if exceeding the tier-aware limit
                const messages = this.messages.get(storageKey);
                if (messages && messages.length > this.channelMessageLimit) {
                    this.messages.set(storageKey, messages.slice(-this.channelMessageLimit));
                }

                // Schedule zap receipt subscription update with new event IDs
                this._scheduleZapResubscribe();
            }

            // Now check if we should actually render this message
            if (this.inPMMode) {
                // In PM mode — message is stored but don't render channel messages.
                // Invalidate DOM cache so it re-renders when user switches back.
                this.channelDOMCache.delete(storageKey);
                if (!message.isOwn && !exists && !message.isHistorical) {
                    this.updateUnreadCount(storageKey);
                }
                return;
            }

            // Check if this is for current channel
            const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
            if (storageKey !== currentKey) {
                // Message is for different channel, update unread count but don't display.
                // Invalidate DOM cache so the channel re-renders when user switches to it.
                if (!exists) this.channelDOMCache.delete(storageKey);
                if (!message.isOwn && !exists && !message.isHistorical) {
                    this.updateUnreadCount(storageKey);
                }
                return;
            }
        }

        // Don't re-add if already displayed in DOM
        // For group messages use the shared nymMessageId so duplicates from multiple relays are caught
        const _dedupeId = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
        if (document.querySelector(`[data-message-id="${_dedupeId}"]`)) {
            return;
        }

        // Now actually display the message in the DOM
        const container = document.getElementById('messagesContainer');


        // Check if user is near the bottom BEFORE we add the new message to DOM.
        // We use a generous threshold so rapid message bursts don't lose the "at bottom" state.
        const isNearBottom = container.scrollHeight - container.scrollTop <= container.clientHeight + 150;
        const shouldScroll = !this.virtualScroll.suppressAutoScroll &&
            !this.userScrolledUp && isNearBottom;

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
            ? '<span class="friend-badge" title="Friend"><svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" style="vertical-align: middle; margin-left: 3px; opacity: 0.7;"><circle cx="6" cy="5" r="2.5" /><path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" /><line x1="13" y1="6" x2="13" y2="10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /><line x1="11" y1="8" x2="15" y2="8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg></span>'
            : '';

        const messageEl = document.createElement('div');

        // Check if nym is blocked or message contains blocked keywords or is spam
        if (this.blockedUsers.has(message.author) ||
            this.hasBlockedKeyword(message.content, message.author) ||
            this.isSpamMessage(message.content)) {
            // Don't create the element at all for blocked/spam content
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
            messageEl.className = 'action-message';
            messageEl.dataset.messageId = message.id;
            messageEl.dataset.timestamp = displayTimestamp.getTime();
            messageEl.dataset.createdAt = message.created_at || 0;
            messageEl.dataset.seq = message._seq || 0;

            // Get clean author name and flair
            const cleanAuthor = this.parseNymFromDisplay(message.author);
            const authorFlairHtml = this.getFlairForUser(message.pubkey);
            const actionAvatarSrc = this.getAvatarUrl(message.pubkey);
            const safePk = this._safePubkey(message.pubkey);
            const authorWithFlair = `<img src="${this.escapeHtml(actionAvatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${safePk}.png?set=set1&size=80x80'">${this.escapeHtml(cleanAuthor)}#${this.getPubkeySuffix(message.pubkey)}${authorFlairHtml}`;

            // Get the action content (everything after /me)
            const actionContent = message.content.substring(4);

            // Format the action content but preserve any HTML in mentioned users
            const formattedAction = this.formatMessage(actionContent);

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
            messageEl.dataset.seq = message._seq || 0;
            if (message.isPM) messageEl.dataset.isPM = '1';
            if (message.isGroup && message.groupId) messageEl.dataset.groupId = message.groupId;

            const authorClass = message.isOwn ? 'self' : '';
            const userColorClass = this.getUserColorClass(message.pubkey);

            // Add verified badge if this is the developer or the nymbot
            const verifiedBadge = this.isVerifiedDeveloper(message.pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
                : message.isBot
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
        <button class="reaction-btn" onclick="nym.showReactionPicker('${reactionMsgId}', this)">
            <svg viewBox="0 0 24 24">
                <circle cx="12" cy="12" r="10"></circle>
                <path d="M8 14s1.5 2 4 2 4-2 4-2"></path>
                <circle cx="9" cy="9" r="1"></circle>
                <circle cx="15" cy="9" r="1"></circle>
            </svg>
        </button>
        <button class="translate-msg-btn" onclick="nym.translateHoverMessage(this)" title="Translate">
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
            const displayAuthorBase = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk2}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${safePk2}.png?set=set1&size=80x80'">&lt;${this.escapeHtml(baseNym)}<span class="nym-suffix">#${this.getPubkeySuffix(message.pubkey)}</span>${flairHtml}`;
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
            if (message.isOwn && message.isPM) {
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
                        deliveryCheckmark = `<span class="delivery-status failed" title="Failed to deliver - click to retry" style="cursor:pointer" data-retry-event-id="${message.id}">!</span>`;
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
                                <button class="file-offer-stop-btn" onclick="nym.stopSeeding('${offer.offerId}')" title="Stop seeding">Stop</button>
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
                                <button class="file-offer-btn torrent-btn" onclick="nym.downloadTorrent('${offer.offerId}')">Download (Torrent)</button>
                            ` : `
                                <button class="file-offer-btn" onclick="nym.requestP2PFile('${offer.offerId}')">Download</button>
                            `}
                        </div>
                        <div class="file-offer-progress" id="progress-${offer.offerId}" style="display: none;">
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
            const emojiOnlyClass = !message.isFileOffer && this.isEmojiOnly(message.content) ? ' emoji-only' : '';

            const bubbleTime = time || displayTimestamp.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: this.settings.timeFormat === '12hr' });

            // Check if this message has been edited
            const isEdited = message.isEdited;
            const editedBubble = isEdited ? '<span class="edited-indicator" title="This message has been edited">(edited)</span> ' : '';
            const editedIRC = isEdited ? '<span class="edited-indicator edited-indicator-irc" title="This message has been edited">(edited)</span>' : '';

            messageEl.innerHTML = `
    ${time ? `<span class="message-time ${this.settings.timeFormat === '12hr' ? 'time-12hr' : ''}" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${time}</span>` : ''}
    <span class="message-author ${authorClass} ${userColorClass} ${authorExtraClass}"><span class="bubble-time" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${bubbleTime}</span><span class="author-clickable">${displayAuthor}${verifiedBadge}${supporterBadge}${friendBadge}</span>&gt;</span>
    <span class="message-content ${userColorClass}${emojiOnlyClass}">${messageContentHtml}<span class="bubble-time-inner" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${editedBubble}${bubbleTime}</span></span>
    ${editedIRC}
    ${hoverButtons}
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
                    bq.appendChild(makeReadMoreBtn(inner));
                    bq.classList.add('has-truncation');
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

        // Apply blur to images if settings enabled and not own message
        if (!message.isOwn) {
            const shouldBlur = this.blurOthersImages === true ||
                (this.blurOthersImages === 'friends' && !this.isFriend(message.pubkey));
            if (shouldBlur) {
                const images = messageEl.querySelectorAll('img');
                images.forEach(img => {
                    img.classList.add('blurred');
                });
            }
        }

        // Always insert messages in correct created_at order to prevent out-of-order display.
        // Uses raw created_at (integer seconds) consistent with the in-memory sort;
        // arrival sequence (_seq) breaks ties within the same second.
        {
            const existingMessages = Array.from(container.querySelectorAll('[data-created-at]'));
            const msgCreatedAt = message.created_at || 0;
            const msgSeq = message._seq || 0;

            let insertBefore = null;
            for (const existing of existingMessages) {
                const existingCreatedAt = parseInt(existing.dataset.createdAt) || 0;
                if (msgCreatedAt < existingCreatedAt) {
                    insertBefore = existing;
                    break;
                }
                if (msgCreatedAt === existingCreatedAt) {
                    const existingSeq = parseInt(existing.dataset.seq) || 0;
                    if (msgSeq < existingSeq) {
                        insertBefore = existing;
                        break;
                    }
                }
            }

            if (insertBefore) {
                container.insertBefore(messageEl, insertBefore);
            } else {
                container.appendChild(messageEl);
            }
        }

        // Bind long-press on group-readers span so users can see all viewers
        if (message.isOwn && message.isGroup && message.nymMessageId) {
            const readersEl = messageEl.querySelector('.group-readers');
            if (readersEl) this._bindReaderLongPress(readersEl, message.nymMessageId);
        }

        // Prune oldest messages from DOM to stay within limits
        {
            const domMessages = container.querySelectorAll('[data-message-id]');
            const domLimit = message.isPM ? this.pmStorageLimit : this.channelMessageLimit;
            if (domMessages.length > domLimit) {
                const toRemove = domMessages.length - domLimit;
                let removedHeight = 0;
                for (let i = 0; i < toRemove; i++) {
                    removedHeight += domMessages[i].offsetHeight;
                    domMessages[i].remove();
                }
                if (this.userScrolledUp && removedHeight > 0) {
                    container.scrollTop = Math.max(0, container.scrollTop - removedHeight);
                }
            }
        }

        // Add existing reactions if any (for both channel messages and PMs)
        // For PMs, reactions are keyed by nymMessageId (shared across recipients)
        const reactionKey = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
        if (reactionKey && this.reactions.has(reactionKey)) {
            this.updateMessageReactions(reactionKey);
        }
        // Also check reactions stored under the other key (nymMessageId vs event ID mismatch)
        if (message.isPM && message.nymMessageId && message.nymMessageId !== message.id && this.reactions.has(message.id)) {
            // Merge reactions from event-ID key into nymMessageId key
            const altReactions = this.reactions.get(message.id);
            if (!this.reactions.has(message.nymMessageId)) this.reactions.set(message.nymMessageId, new Map());
            const primary = this.reactions.get(message.nymMessageId);
            for (const [emoji, reactors] of altReactions) {
                if (!primary.has(emoji)) primary.set(emoji, new Map());
                for (const [pk, nym] of reactors) primary.get(emoji).set(pk, nym);
            }
            this.reactions.delete(message.id);
            this.updateMessageReactions(message.nymMessageId);
        }

        // Add zaps display - check if this message has any zaps
        if (message.id && this.zaps.has(message.id)) {
            this.updateMessageZaps(message.id);
        }

        // Scroll handling: use coalesced rAF to batch scroll operations.
        // When images are present, also scroll after they load.
        if (shouldScroll) {
            this._scheduleScrollToBottom();

            // If message has images, schedule another scroll after they load
            const images = messageEl.querySelectorAll('img:not(.avatar-message)');
            if (images.length > 0) {
                let loaded = 0;
                const total = images.length;
                const onLoad = () => {
                    if (++loaded === total && !this.userScrolledUp) {
                        this._scheduleScrollToBottom();
                    }
                };
                images.forEach(img => {
                    if (img.complete) onLoad();
                    else {
                        img.addEventListener('load', onLoad, { once: true });
                        img.addEventListener('error', onLoad, { once: true });
                    }
                });
            }

            // iOS Safari: explicitly load videos inserted via innerHTML and handle scroll.
            // Safari requires Range request support (206) to play videos. If the server
            // doesn't support it, fall back to fetching as a blob URL.
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
                    vid.load();
                    vid.addEventListener('loadedmetadata', () => {
                        if (!this.userScrolledUp) {
                            this._scheduleScrollToBottom();
                        }
                    }, { once: true });
                });
            }
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

    formatMessage(content) {
        let formatted = content;

        // Deduplicate suffixes in mentions from external apps (e.g., @user#abcd#abcd -> @user#abcd)
        formatted = formatted.replace(/@([^@#\s]+)#([0-9a-f]{4})#\2\b/gi, '@$1#$2');

        formatted = formatted
            .replace(/&(?![a-z]+;|#[0-9]+;|#x[0-9a-f]+;)/gi, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');

        // Code blocks and inline code — extract into placeholders so
        // later markdown/mention/channel processing doesn't touch their contents
        const codePlaceholders = [];
        formatted = formatted.replace(/```([\s\S]*?)```/g, (match, code) => {
            const trimmedCode = code.trim();
            const formattedCode = trimmedCode.replace(/\n/g, '<br/>');
            const encodedRaw = btoa(unescape(encodeURIComponent(trimmedCode)));
            const idx = codePlaceholders.length;
            codePlaceholders.push(`<div class="code-block-wrapper"><pre><code>${formattedCode}</code></pre><button class="code-copy-btn" data-code="${encodedRaw}" onclick="try{navigator.clipboard.writeText(decodeURIComponent(escape(atob(this.dataset.code)))).then(()=>{this.textContent='Copied!';setTimeout(()=>this.textContent='Copy',1500)}).catch(()=>{})}catch(e){}">Copy</button></div>`);
            return `\uFDD0${idx}\uFDD1`;
        });
        formatted = formatted.replace(/`([^`]+?)`/g, (match, code) => {
            const idx = codePlaceholders.length;
            codePlaceholders.push(`<code>${code}</code>`);
            return `\uFDD0${idx}\uFDD1`;
        });

        // Bold **text** (asterisks — fine anywhere) or __text__ (underscores — require word boundary)
        formatted = formatted.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
        formatted = formatted.replace(/(?<!\w)__(.+?)__(?!\w)/g, '<strong>$1</strong>');

        // Italic *text* (asterisks — fine anywhere) or _text_ (underscores — require word boundary
        // so that underscores inside names/identifiers like @Cool_User#a1b2 are not treated as italic)
        formatted = formatted.replace(/(?<![:/])\*([^*\s][^*]*)\*/g, '<em>$1</em>');
        formatted = formatted.replace(/(?<![:/\w])_([^_\s][^_]*)_(?!\w)/g, '<em>$1</em>');

        // Strikethrough ~~text~~
        formatted = formatted.replace(/~~(.+?)~~/g, '<del>$1</del>');

        // Blockquotes > text
        formatted = formatted.replace(/^&gt; (.+)$/gm, '<blockquote>$1</blockquote>');

        // Headers
        formatted = formatted.replace(/^### (.+)$/gm, '<h3>$1</h3>');
        formatted = formatted.replace(/^## (.+)$/gm, '<h2>$1</h2>');
        formatted = formatted.replace(/^# (.+)$/gm, '<h1>$1</h1>');

        // Convert video URLs to video players
        // Use __VID_n__ placeholders to prevent the general URL-to-link regex from
        // matching URLs that are already embedded inside video HTML attributes.
        const videoPlaceholders = [];
        formatted = formatted.replace(
            /(https?:\/\/[^\s]+\.(mp4|webm|ogg|mov)(\?[^\s]*)?)/gi,
            (match, url, ext) => {
                const mimeTypes = { mp4: 'video/mp4', webm: 'video/webm', ogg: 'video/ogg', mov: 'video/mp4' };
                const type = mimeTypes[ext.toLowerCase()] || 'video/mp4';
                const proxiedUrl = this.getProxiedMediaUrl(url);
                const idx = videoPlaceholders.length;
                videoPlaceholders.push(`<span class="video-container" onclick="event.stopPropagation()"><video controls playsinline webkit-playsinline preload="metadata" class="message-video"><source src="${proxiedUrl}" type="${type}"></video><button class="video-expand-btn" data-video-src="${proxiedUrl.replace(/"/g, '&quot;')}" onclick="event.stopPropagation(); var v=this.previousElementSibling; nym.expandVideo(v.dataset.blobSrc||this.dataset.videoSrc)">⛶</button></span>`);
                return `__VID_${idx}__`;
            }
        );

        // Convert image URLs to images (proxied through Cloudflare worker for IP privacy)
        formatted = formatted.replace(
            /(https?:\/\/[^\s]+\.(jpg|jpeg|png|gif|webp)(\?[^\s]*)?)/gi,
            (match, url) => {
                const proxiedUrl = this.getProxiedMediaUrl(url);
                return `<img src="${proxiedUrl}" alt="Image" onclick="nym.expandImage(this.dataset.originalSrc || this.src)" data-original-src="${url}" />`;
            }
        );

        // Convert Nymchat app channel links BEFORE general URLs
        formatted = formatted.replace(
            /https?:\/\/app\.nym\.bar\/#([egc]):([^\s<>"]+)/gi,
            (match, prefix, channelId) => {
                return `<span class="channel-link" onclick="event.preventDefault(); event.stopPropagation(); nym.handleChannelLink('${prefix}:${this.escapeHtml(channelId)}', event); return false;">${match}</span>`;
            }
        );

        // Convert other URLs to links (but not placeholders)
        formatted = formatted.replace(
            /(https?:\/\/[^\s]+)(?![^<]*>)(?!__)/g,
            '<a href="$1" target="_blank" rel="noopener">$1</a>'
        );

        // Restore video placeholders
        formatted = formatted.replace(/__VID_(\d+)__/g, (m, idx) => videoPlaceholders[idx]);

        // Process mentions and channel references (both geohash and non-geohash) in one pass.
        // The trailing (?![^<]*>) prevents matches inside HTML attribute values
        // (e.g. inside an <a href="...@user/...">), which would otherwise consume
        // the closing quote and `>` of the tag and break the rendered HTML.
        formatted = formatted.replace(
            /(?:(@[^@#\n]*?(?<!\s)#[0-9a-f]{4}\b)|(@[^@\s][^@\s]*)|(^|\s)(#[a-z0-9_-]+)(?=\s|$|[.,!?]))(?![^<]*>)/gi,
            (match, mentionWithSuffix, simpleMention, whitespace, channel) => {
                if (mentionWithSuffix) {
                    // Wrap the #suffix in nym-suffix span for proper dimming
                    const suffixIdx = mentionWithSuffix.search(/#[0-9a-f]{4}$/i);
                    const namePart = mentionWithSuffix.substring(0, suffixIdx);
                    const suffixPart = mentionWithSuffix.substring(suffixIdx);
                    return `<span style="color: var(--secondary)">${namePart}<span class="nym-suffix">${suffixPart}</span></span>`;
                } else if (simpleMention) {
                    return `<span style="color: var(--secondary)">${simpleMention}</span>`;
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

                    return `${whitespace || ''}<span class="${classes.join(' ')}" style="text-decoration: underline;" title="${title}" onclick="event.preventDefault(); event.stopPropagation(); nym.handleChannelLink('g:${channelName}', event); return false;">${channel}</span>`;
                }
            }
        );

        // Convert emoji shortcodes :emoji:
        formatted = formatted.replace(/:([a-z0-9_]+):/g, (match, code) => {
            const emoji = this.emojiMap[code];
            return emoji || match;
        });

        // Convert simple emoticons to emojis
        formatted = formatted.replace(/(^|\s):\)($|\s)/g, '$1😊$2');
        formatted = formatted.replace(/(^|\s):\(($|\s)/g, '$1😢$2');
        formatted = formatted.replace(/(^|\s):D($|\s)/g, '$1😃$2');
        formatted = formatted.replace(/(^|\s):P($|\s)/g, '$1😛$2');
        formatted = formatted.replace(/(^|\s);-?\)($|\s)/g, '$1😉$2');
        formatted = formatted.replace(/(^|\s):o($|\s)/gi, '$1😮$2');
        formatted = formatted.replace(/(^|\s):\|($|\s)/g, '$1😐$2');
        formatted = formatted.replace(/(^|\s)&lt;3($|\s)/g, '$1❤️$2');
        formatted = formatted.replace(/(^|\s)\/\\($|\s)/g, '$1⚠️$2');

        // Wrap emoji characters in <span class="emoji"> to isolate them from --font-sans
        // This regex matches all Unicode emoji including: emoticons, symbols, dingbats,
        // skin tone modifiers, regional indicator flag sequences, variation selectors,
        // ZWJ sequences, keycap sequences (#️⃣ 0️⃣-9️⃣), and tag flag sequences.
        formatted = formatted.replace(
            /(?:<[^>]+>)|((?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)(?:[\u{E0020}-\u{E007E}]+\u{E007F})?)/gu,
            (match, emoji) => {
                // If this is an HTML tag, skip it
                if (!emoji) return match;
                return `<span class="emoji">${match}</span>`;
            }
        );

        // Restore code placeholders
        formatted = formatted.replace(/\uFDD0(\d+)\uFDD1/g, (m, idx) => codePlaceholders[idx]);

        // Handle game tokens
        formatted = formatted.replace(/\n\[gc:([A-Za-z0-9+/=]+)\]/g, '<span class="game-token" aria-hidden="true">[gc:$1]</span>');

        // Line breaks
        formatted = formatted.replace(/\n/g, '<br>');

        return formatted;
    },

    // Check if a raw message is emoji-only (1-6 emoji, optional whitespace, no other text)
    isEmojiOnly(content) {
        if (!content) return false;
        // Strip whitespace and check if remaining chars are all emoji (up to 6)
        const stripped = content.replace(_RX_WHITESPACE, '');
        return _RX_EMOJI_ONLY.test(stripped);
    },

    expandImage(src) {
        const modalImg = document.getElementById('modalImage');
        const modalVid = document.getElementById('modalVideo');
        modalImg.src = src;
        modalImg.style.display = '';
        modalVid.style.display = 'none';
        modalVid.pause();
        modalVid.removeAttribute('src');
        while (modalVid.firstChild) modalVid.firstChild.remove();
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

    // Coalesced scroll-to-bottom: batches multiple scroll requests into one rAF frame.
    // This prevents layout thrashing when many messages arrive in quick succession.
    _scheduleScrollToBottom(force = false) {
        if (!force && (!this.settings.autoscroll || this.userScrolledUp)) return;
        if (!force && this.virtualScroll.suppressAutoScroll) return;
        if (this._scrollRAF) return; // already scheduled

        this._scrollRAF = requestAnimationFrame(() => {
            this._scrollRAF = null;
            const container = document.getElementById('messagesContainer');
            if (!container) return;
            container.scrollTop = container.scrollHeight;
        });
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

            const geohash = this.currentGeohash || 'nym';

            const now = Math.floor(Date.now() / 1000);
            const tags = [
                ['n', this.nym],
                ['g', geohash],
                ['edit', originalEventId]
            ];

            let event = {
                kind: 20000,
                created_at: now,
                tags: tags,
                content: newContent,
                pubkey: this.pubkey
            };

            if (this.enablePow && this.powDifficulty > 0) {
                event = NostrTools.nip13.minePow(event, this.powDifficulty);
            }

            const signedEvent = await this.signEvent(event);

            // Track this edit locally so it replaces the original visually
            this.editedMessages.set(originalEventId, {
                newContent,
                editEventId: signedEvent.id,
                timestamp: new Date(now * 1000)
            });

            // Update the original message in stored messages
            this.messages.forEach((msgs) => {
                const msg = msgs.find(m => m.id === originalEventId);
                if (msg) {
                    msg.content = newContent;
                    msg.isEdited = true;
                }
            });

            // Update DOM in-place
            this.updateMessageInDOM(originalEventId, newContent);

            // Send to relay
            this.sendToRelay(['EVENT', signedEvent]);

            // Ensure geo relays for this channel also receive the edit
            this.ensureGeoRelayDelivery(signedEvent, geohash);

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
            // Rebuild bubble-time-inner with edited indicator
            const bubbleTimeEl = contentEl.querySelector('.bubble-time-inner');
            const formattedContent = this.formatMessageWithQuotes(newContent);
            if (bubbleTimeEl) {
                // Add edited indicator inside bubble-time-inner (for bubble layout)
                if (!bubbleTimeEl.querySelector('.edited-indicator')) {
                    const bubbleEdited = document.createElement('span');
                    bubbleEdited.className = 'edited-indicator';
                    bubbleEdited.title = 'This message has been edited';
                    bubbleEdited.textContent = '(edited)';
                    bubbleTimeEl.insertBefore(bubbleEdited, bubbleTimeEl.firstChild);
                    bubbleTimeEl.insertBefore(document.createTextNode(' '), bubbleEdited.nextSibling);
                }
                contentEl.innerHTML = formattedContent + bubbleTimeEl.outerHTML;
            } else {
                contentEl.innerHTML = formattedContent;
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

    setupSwipeToReply() {
        const container = document.getElementById('messagesContainer');
        if (!container) return;

        let startX = 0;
        let startY = 0;
        let currentEl = null;
        let isSwiping = false;
        let swipeDistance = 0;
        const SWIPE_THRESHOLD = 60;

        container.addEventListener('touchstart', (e) => {
            const msgEl = e.target.closest('.message');
            if (!msgEl || !msgEl.dataset.messageId) return;

            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
            currentEl = msgEl;
            isSwiping = false;
            swipeDistance = 0;
        }, { passive: true });

        container.addEventListener('touchmove', (e) => {
            if (!currentEl) return;

            const deltaX = startX - e.touches[0].clientX;
            const deltaY = Math.abs(e.touches[0].clientY - startY);

            // Only swipe left (deltaX > 0), and must be more horizontal than vertical
            if (!isSwiping && deltaX > 10 && deltaX > deltaY) {
                isSwiping = true;
            }

            if (!isSwiping) return;

            e.preventDefault();
            // Cap the swipe distance
            swipeDistance = Math.min(Math.max(deltaX, 0), 100);
            currentEl.style.transform = `translateX(-${swipeDistance}px)`;
            currentEl.style.transition = 'none';

            // Show reply indicator when past threshold
            let indicator = currentEl.querySelector('.swipe-reply-indicator');
            if (!indicator) {
                indicator = document.createElement('div');
                indicator.className = 'swipe-reply-indicator';
                indicator.innerHTML = '<svg viewBox="0 0 24 24"><polyline points="9 14 4 9 9 4"></polyline><path d="M20 20v-7a4 4 0 0 0-4-4H4"></path></svg>';
                currentEl.appendChild(indicator);
            }
            indicator.classList.toggle('visible', swipeDistance >= SWIPE_THRESHOLD);
        }, { passive: false });

        const handleTouchEnd = () => {
            if (!currentEl) return;

            if (isSwiping && swipeDistance >= SWIPE_THRESHOLD) {
                // Trigger quote reply
                const msgEl = currentEl;
                const contentSpan = msgEl.querySelector('.message-content');

                if (msgEl.dataset.pubkey) {
                    // Build clean author from data attributes to avoid flair emoji leaking into quote text
                    const baseNym = this.stripPubkeySuffix(msgEl.dataset.author || 'anon');
                    const suffix = this.getPubkeySuffix(msgEl.dataset.pubkey);
                    const authorText = `${baseNym}#${suffix}`;
                    // Use raw content stored on the element to preserve quote structure
                    const cleanContent = msgEl.dataset.rawContent || contentSpan?.textContent.replace(/\d{1,2}:\d{2}\s*(AM|PM)?\s*$/i, '').trim();

                    if (cleanContent) {
                        this.setQuoteReply(authorText, cleanContent);
                    }
                }
            }

            // Snap back
            currentEl.style.transition = 'transform 0.25s ease-out';
            currentEl.style.transform = '';

            // Remove indicator after animation
            const indicator = currentEl.querySelector('.swipe-reply-indicator');
            if (indicator) {
                setTimeout(() => indicator.remove(), 250);
            }

            currentEl = null;
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
            const baseNym = this.stripPubkeySuffix(msgEl.dataset.author || 'anon');
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

        // Hardcore mode: rotate keypair after every sent message
        if (this.connectionMode === 'ephemeral' && localStorage.getItem('nym_keypair_mode') === 'hardcore') {
            await this.generateKeypair();
            this.nym = this.generateRandomNym();
            document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
            this.updateSidebarAvatar();
        }
    },

    async sendMessageAnonymous() {
        const input = document.getElementById('messageInput');
        let content = input.value.trim();

        if (!content && !this.pendingQuote) return;

        if (!this.connected) {
            this.displaySystemMessage('Not connected to relay. Please wait...');
            return;
        }

        // Capture quote context before clearing (for bot reply support)
        const savedQuote = this.pendingQuote ? { author: this.pendingQuote.author, text: this.pendingQuote.text, fullText: this.pendingQuote.fullText } : null;
        const quoteData = savedQuote; // Pass to publishMessageAnonymous for nymquote tag
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
                // Send via ephemeral keypair (anonymous)
                await this.publishMessageAnonymous(content, this.currentGeohash, this.currentGeohash, quoteData);
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
    },

    hideMessagesFromBlockedUser(pubkey) {
        // Hide messages in current DOM
        document.querySelectorAll('.message').forEach(msg => {
            if (msg.dataset.pubkey === pubkey) {
                msg.style.display = 'none';
                msg.classList.add('blocked-user-message');
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
    },

    cacheCurrentContainerDOM() {
        const container = document.getElementById('messagesContainer');
        const previousKey = container.dataset.lastChannel;
        if (!previousKey || container.children.length === 0) return;

        const fragment = document.createDocumentFragment();
        while (container.firstChild) {
            fragment.appendChild(container.firstChild);
        }

        // Get message count and fingerprint for cache invalidation
        const messages = this.messages.get(previousKey) || this.pmMessages.get(previousKey) || [];
        this.channelDOMCache.set(previousKey, {
            fragment,
            messageCount: messages.length,
            messageFingerprint: this._computeMessageFingerprint(messages),
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

        // Try to restore from cache if messages haven't changed
        const channelMessages = this.messages.get(storageKey) || [];
        const cached = this.channelDOMCache.get(storageKey);
        const currentFingerprint = this._computeMessageFingerprint(channelMessages);

        if (cached && cached.messageCount === channelMessages.length &&
            cached.messageFingerprint === currentFingerprint) {
            // Message count unchanged, restore cached DOM instantly
            container.innerHTML = '';
            container.appendChild(cached.fragment);
            this.channelDOMCache.delete(storageKey);

            // Restore virtual scroll state
            this.virtualScroll.currentStartIndex = cached.virtualScrollState.currentStartIndex;
            this.virtualScroll.currentEndIndex = cached.virtualScrollState.currentEndIndex;

            // Scroll to bottom
            if (this.settings.autoscroll) {

                requestAnimationFrame(() => {
                    container.scrollTop = container.scrollHeight;
                    setTimeout(() => {

                    }, 300);
                });
            }
            return;
        }

        // Cache miss or stale (new messages arrived) - render fresh
        this.channelDOMCache.delete(storageKey);
        container.innerHTML = '';

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

    // Initialize virtual scroll for a container

    // Get filtered messages for a storage key (applies block filters)
    getFilteredMessages(storageKey) {
        const messages = this.messages.get(storageKey) || [];

        return messages.filter(msg => {
            if (this.deletedEventIds.has(msg.id)) return false;
            if (this.blockedUsers.has(msg.pubkey) || this.isNymBlocked(msg.author) || msg.blocked) return false;
            if (this.hasBlockedKeyword(msg.content, msg.author)) return false;
            if (this.isSpamMessage(msg.content)) return false;
            return true;
        }).sort((a, b) => {
            const dt = (a.created_at || 0) - (b.created_at || 0);
            if (dt !== 0) return dt;
            return (a._seq || 0) - (b._seq || 0);
        });
    },

    // Render all messages for a channel or PM conversation
    // isPM: if true, uses pmMessages with conversationKey instead of messages with storageKey
    renderMessagesWithVirtualScroll(container, storageKey, scrollToBottom = true, isPM = false) {
        const messages = isPM ? this.getFilteredPMMessages(storageKey) : this.getFilteredMessages(storageKey);

        // Store context for scroll handlers
        container.dataset.virtualScrollKey = storageKey;
        container.dataset.virtualScrollIsPM = isPM ? 'true' : 'false';

        // Clear container
        container.innerHTML = '';

        if (messages.length === 0) {
            return;
        }

        // If this channel has reached the message limit, show a notice at the top
        if (!isPM && messages.length >= this.channelMessageLimit) {
            const notice = document.createElement('div');
            notice.className = 'system-message channel-history-limit';
            notice.textContent = 'You\'ve reached the edge of this channel\'s history. Older messages are lost to the void — only the latest 100 messages are shown.';
            container.appendChild(notice);
        }

        // For PMs/groups, only render the latest pmPageSize messages initially
        // and track the start index for pagination
        let renderMessages = messages;
        if (isPM && messages.length > this.pmPageSize) {
            const startIdx = messages.length - this.pmPageSize;
            renderMessages = messages.slice(startIdx);
            this.pmRenderedStart.set(storageKey, startIdx);
            // Show "load older" notice at top
            const loadNotice = document.createElement('div');
            loadNotice.className = 'system-message pm-load-older';
            loadNotice.textContent = `Scroll up to load older messages (${startIdx} more)`;
            container.appendChild(loadNotice);
        } else if (isPM) {
            this.pmRenderedStart.set(storageKey, 0);
        }

        // Render all messages sorted by timestamp
        this.virtualScroll.suppressAutoScroll = true;



        // Suppress notification sounds during bulk rendering of stored messages
        // (e.g. when opening a conversation) to avoid replaying sounds
        this._suppressSound = true;

        for (let i = 0; i < renderMessages.length; i++) {
            this.displayMessage(renderMessages[i]);
        }

        this._suppressSound = false;
        this.virtualScroll.suppressAutoScroll = false;

        // Scroll to bottom if requested
        if (scrollToBottom && this.settings.autoscroll) {
            requestAnimationFrame(() => {
                container.scrollTop = container.scrollHeight;
                // Clear the suppression after the scroll-to-bottom settles
                setTimeout(() => {

                }, 300);
            });
        } else {
            // Clear suppression after a brief delay if not scrolling
            setTimeout(() => {

            }, 300);
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
