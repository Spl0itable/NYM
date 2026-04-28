// reactions.js - Reaction sending/removal, reactor lists, emoji picker
// Methods are attached to NYM.prototype.

Object.assign(NYM.prototype, {

    loadRecentEmojis() {
        const saved = localStorage.getItem('nym_recent_emojis');
        if (saved) {
            this.recentEmojis = JSON.parse(saved);
        }
    },

    saveRecentEmojis() {
        localStorage.setItem('nym_recent_emojis', JSON.stringify(this.recentEmojis.slice(0, 20)));
    },

    addToRecentEmojis(emoji) {
        // Remove if already exists
        this.recentEmojis = this.recentEmojis.filter(e => e !== emoji);
        // Add to beginning
        this.recentEmojis.unshift(emoji);
        // Keep only 20 recent
        this.recentEmojis = this.recentEmojis.slice(0, 20);
        this.saveRecentEmojis();
    },

    handleReaction(event) {
        const reactionContent = event.content;
        const eTag = event.tags.find(t => t[0] === 'e');
        const kTag = event.tags.find(t => t[0] === 'k');
        const pTag = event.tags.find(t => t[0] === 'p');
        const actionTag = event.tags.find(t => t[0] === 'action');
        const isRemoval = actionTag && actionTag[1] === 'remove';

        if (!eTag) return;

        // Only process reactions for our supported kinds
        // 20000 = channel messages, 1059 = NIP-17 gift wraps, 14 = group rumor messages
        if (kTag && !['20000', '1059', '14'].includes(kTag[1])) {
            return;
        }

        const messageId = eTag[1];

        // When no kTag is present, verify this reaction targets a known Nymchat message
        // to avoid showing notifications for reactions from other Nostr apps
        if (!kTag) {
            const inDom = !!document.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
            let inMessages = false;
            if (!inDom) {
                for (const msgs of this.messages.values()) {
                    if (msgs.some(m => m.id === messageId)) { inMessages = true; break; }
                }
            }
            let inPMs = false;
            if (!inDom && !inMessages) {
                for (const msgs of this.pmMessages.values()) {
                    if (msgs.some(m => m.id === messageId || m.nymMessageId === messageId)) { inPMs = true; break; }
                }
            }
            if (!inDom && !inMessages && !inPMs) return;
        }

        const reactorNym = this.getNymFromPubkey(event.pubkey);

        // Use timestamp tracking to ensure only the latest action wins
        // (handles out-of-order event delivery from relays on reload)
        const actionKey = `${messageId}:${reactionContent}:${event.pubkey}`;
        const lastAction = this.reactionLastAction.get(actionKey);
        const eventTs = event.created_at || 0;
        if (lastAction && lastAction.ts > eventTs) {
            return; // We already processed a newer action for this reaction
        }
        this.reactionLastAction.set(actionKey, { action: isRemoval ? 'remove' : 'add', ts: eventTs });

        // Prune if too large
        if (this.reactionLastAction.size > 5000) {
            const entries = Array.from(this.reactionLastAction.entries());
            this.reactionLastAction = new Map(entries.slice(-4000));
        }

        // Handle reaction removal
        if (isRemoval) {
            const messageReactions = this.reactions.get(messageId);
            if (messageReactions && messageReactions.has(reactionContent)) {
                messageReactions.get(reactionContent).delete(event.pubkey);
                if (messageReactions.get(reactionContent).size === 0) {
                    messageReactions.delete(reactionContent);
                }
                if (messageReactions.size === 0) {
                    this.reactions.delete(messageId);
                }
            }
            const reactionApplied = this.updateMessageReactions(messageId);
            if (!reactionApplied) {
                for (const [key, msgs] of this.messages.entries()) {
                    if (msgs.some(m => m.id === messageId)) {
                        this.channelDOMCache.delete(key);
                        break;
                    }
                }
                for (const [key, msgs] of this.pmMessages.entries()) {
                    if (msgs.some(m => m.id === messageId || m.nymMessageId === messageId)) {
                        this.channelDOMCache.delete(key);
                        break;
                    }
                }
            }
            return;
        }

        // Store reaction with pubkey and nym
        if (!this.reactions.has(messageId)) {
            this.reactions.set(messageId, new Map());
        }

        const messageReactions = this.reactions.get(messageId);
        if (!messageReactions.has(reactionContent)) {
            messageReactions.set(reactionContent, new Map());
        }

        // Store pubkey with nym
        messageReactions.get(reactionContent).set(event.pubkey, reactorNym);

        // Update UI if message is visible, otherwise invalidate DOM cache
        // so the reaction appears when the user switches to that channel
        const reactionApplied = this.updateMessageReactions(messageId);
        if (!reactionApplied) {
            // Message not in current DOM — find which channel owns it and
            // invalidate that channel's cached DOM so it re-renders with the
            // new reaction when the user navigates there.
            for (const [key, msgs] of this.messages.entries()) {
                if (msgs.some(m => m.id === messageId)) {
                    this.channelDOMCache.delete(key);
                    break;
                }
            }
            for (const [key, msgs] of this.pmMessages.entries()) {
                if (msgs.some(m => m.id === messageId || m.nymMessageId === messageId)) {
                    this.channelDOMCache.delete(key);
                    break;
                }
            }
        }

        // Notify if someone reacted to OUR message (not our own reaction)
        if (pTag && pTag[1] === this.pubkey && event.pubkey !== this.pubkey) {
            const messageAge = Date.now() - (event.created_at * 1000);
            const isHistorical = messageAge > 10000;
            const channelInfo = {
                type: 'reaction',
                id: event.id,
                pubkey: event.pubkey,
                messageId: messageId
            };
            // Determine the channel/PM context for navigation
            // Check if the reacted message is in the current channel view
            const msgEl = document.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
            if (msgEl) {
                if (this.inPMMode && this.currentPM) {
                    channelInfo.sourceType = 'pm';
                    channelInfo.sourcePubkey = this.currentPM;
                } else if (this.inPMMode && this.currentGroup) {
                    channelInfo.sourceType = 'group';
                    channelInfo.sourceGroupId = this.currentGroup;
                } else if (this.currentGeohash) {
                    channelInfo.sourceType = 'geohash';
                    channelInfo.sourceChannel = this.currentGeohash;
                    channelInfo.sourceGeohash = this.currentGeohash;
                }
            }
            if (!channelInfo.sourceType) {
                // Search channel message stores
                for (const [key, msgs] of this.messages.entries()) {
                    if (msgs.some(m => m.id === messageId)) {
                        channelInfo.sourceType = 'geohash';
                        const gh = key.startsWith('#') ? key.slice(1) : key;
                        channelInfo.sourceChannel = gh;
                        channelInfo.sourceGeohash = gh;
                        break;
                    }
                }
            }
            if (!channelInfo.sourceType) {
                // Search PM message stores
                for (const [key, msgs] of this.pmMessages.entries()) {
                    if (msgs.some(m => m.id === messageId || m.nymMessageId === messageId)) {
                        // Determine if this is a group PM or 1:1 PM
                        if (key.startsWith('group:')) {
                            channelInfo.sourceType = 'group';
                            channelInfo.sourceGroupId = key.replace('group:', '');
                        } else {
                            channelInfo.sourceType = 'pm';
                            // Extract the peer pubkey from the conversation key
                            const parts = key.split(':');
                            channelInfo.sourcePubkey = parts.find(p => p !== this.pubkey) || parts[0];
                        }
                        break;
                    }
                }
            }
            // Try to find a preview of the original message
            let msgPreview = '';
            if (msgEl) {
                const raw = msgEl.dataset.rawContent;
                if (raw) {
                    msgPreview = raw.split('\n').filter(l => !l.startsWith('>')).join(' ').trim();
                }
            }
            if (!msgPreview) {
                // Search in-memory message stores
                for (const msgs of this.messages.values()) {
                    const found = msgs.find(m => m.id === messageId);
                    if (found) {
                        msgPreview = found.content.split('\n').filter(l => !l.startsWith('>')).join(' ').trim();
                        break;
                    }
                }
            }
            if (!msgPreview) {
                for (const msgs of this.pmMessages.values()) {
                    const found = msgs.find(m => m.id === messageId || m.nymMessageId === messageId);
                    if (found) {
                        msgPreview = found.content.split('\n').filter(l => !l.startsWith('>')).join(' ').trim();
                        break;
                    }
                }
            }
            if (msgPreview && msgPreview.length > 80) msgPreview = msgPreview.slice(0, 80) + '…';
            const body = msgPreview
                ? `reacted ${reactionContent} to: "${msgPreview}"`
                : `reacted ${reactionContent} to your message`;
            if (isHistorical) {
                this._addNotificationToHistory(reactorNym, body, channelInfo, event.created_at * 1000);
            } else {
                this.showNotification(reactorNym, body, channelInfo);
            }
        }
    },

    updateMessageReactions(messageId) {
        const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
        if (!messageEl) return false;

        // Capture scroll state before modifying DOM so we can auto-scroll if needed
        const container = document.getElementById('messagesContainer');
        const wasAtBottom = container && (container.scrollHeight - container.scrollTop <= container.clientHeight + 150);

        const reactions = this.reactions.get(messageId);
        if (!reactions || reactions.size === 0) {
            // Remove reaction badges from DOM but preserve zap badges
            const reactionsRow = messageEl.querySelector('.reactions-row');
            if (reactionsRow) {
                // Remove reaction badges and add-reaction button, keep zap elements
                reactionsRow.querySelectorAll('.reaction-badge, .add-reaction-btn').forEach(el => el.remove());
                // If only zap elements remain (or nothing), clean up empty row
                if (reactionsRow.children.length === 0) {
                    reactionsRow.remove();
                }
            }
            this.updateMessageZaps(messageId);
            return true;
        }

        // Remove existing reactions display but preserve zap badges
        let reactionsRow = messageEl.querySelector('.reactions-row');
        let zapBadge = null;
        let addZapBtn = null;

        if (reactionsRow) {
            // Save zap badge and button if they exist
            zapBadge = reactionsRow.querySelector('.zap-badge');
            if (zapBadge) {
                zapBadge = zapBadge.cloneNode(true);
            }
            addZapBtn = reactionsRow.querySelector('.add-zap-btn');
            if (addZapBtn) {
                addZapBtn = addZapBtn.cloneNode(true);
            }
        }

        if (!reactionsRow) {
            reactionsRow = document.createElement('div');
            reactionsRow.className = 'reactions-row';
            messageEl.appendChild(reactionsRow);
        }

        // Clear and rebuild reactions
        reactionsRow.innerHTML = '';

        // Re-add zap badge first if it exists
        if (zapBadge) {
            reactionsRow.appendChild(zapBadge);
        }

        // Re-add quick zap button ONLY if it already existed (meaning there are zaps)
        if (addZapBtn) {
            reactionsRow.appendChild(addZapBtn);
            // Re-attach the click handler
            const pubkey = messageEl.dataset.pubkey;
            addZapBtn.onclick = async (e) => {
                e.stopPropagation();
                await this.handleQuickZap(messageId, pubkey, messageEl);
            };
        }

        // Clear and rebuild reactions
        reactions.forEach((reactors, emoji) => {
            const badge = document.createElement('span');

            // Check if current user has already reacted with this emoji
            const hasReacted = reactors.has(this.pubkey);

            // Set class based on reaction state
            badge.className = hasReacted ? 'reaction-badge user-reacted' : 'reaction-badge';
            badge.dataset.emoji = emoji;
            badge.dataset.messageId = messageId;

            badge.innerHTML = `${this.escapeHtml(emoji)} ${this.abbreviateNumber(reactors.size)}`;

            // No tooltip — long-press shows reactors modal instead

            // Long-press to show reactors modal
            let longPressTimer = null;
            let didLongPress = false;

            const startLongPress = (e) => {
                didLongPress = false;
                longPressTimer = setTimeout(() => {
                    didLongPress = true;
                    e.preventDefault();
                    this.showReactorsModal(messageId, emoji, badge);
                }, 500);
            };

            const cancelLongPress = () => {
                if (longPressTimer) {
                    clearTimeout(longPressTimer);
                    longPressTimer = null;
                }
            };

            badge.addEventListener('mousedown', startLongPress);
            badge.addEventListener('touchstart', startLongPress, { passive: false });
            badge.addEventListener('mouseup', cancelLongPress);
            badge.addEventListener('mouseleave', cancelLongPress);
            badge.addEventListener('touchend', cancelLongPress);
            badge.addEventListener('touchmove', cancelLongPress);

            // Click handler - only fire if not a long press
            badge.onclick = async (e) => {
                e.stopPropagation();
                if (didLongPress) return;
                if (!hasReacted) {
                    await this.sendReaction(messageId, emoji);
                } else {
                    await this.removeReaction(messageId, emoji);
                }
            };

            reactionsRow.appendChild(badge);
        });

        // Adds "add reaction" badge
        const addBtn = document.createElement('span');
        addBtn.className = 'add-reaction-btn';
        addBtn.innerHTML = `
<svg viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="10"></circle>
    <circle cx="9" cy="9" r="1"></circle>
    <circle cx="15" cy="9" r="1"></circle>
    <path d="M8 14s1.5 2 4 2 4-2 4-2"></path>
    <circle cx="18" cy="6" r="5" fill="var(--text)" stroke="none"></circle>
    <line x1="18" y1="4" x2="18" y2="8" stroke="var(--bg)" stroke-width="1.5" stroke-linecap="round"></line>
    <line x1="16" y1="6" x2="20" y2="6" stroke="var(--bg)" stroke-width="1.5" stroke-linecap="round"></line>
</svg>
`;
        addBtn.title = 'Add reaction';
        addBtn.onclick = (e) => {
            e.stopPropagation();
            this.showEnhancedReactionPicker(messageId, addBtn);
        };
        reactionsRow.appendChild(addBtn);

        // Auto-scroll to keep reactions visible if user was already at the bottom
        if (wasAtBottom) {
            this._scheduleScrollToBottom();
        }
        return true;
    },

    showReactorsModal(messageId, emoji, badge) {
        // Close any existing reactors modal
        this.closeReactorsModal();

        const reactions = this.reactions.get(messageId);
        if (!reactions) return;
        const reactors = reactions.get(emoji);
        if (!reactors || reactors.size === 0) return;

        // Build user list
        const userItems = Array.from(reactors.entries()).map(([pubkey, nym]) => {
            const isYou = pubkey === this.pubkey;
            const baseNym = this.parseNymFromDisplay(nym);
            const suffix = this.getPubkeySuffix(pubkey);
            return `<div class="reactors-modal-user" data-pubkey="${pubkey}">
                <span class="reactors-modal-nym">${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span></span>
                ${isYou ? '<span class="reactors-modal-you">you</span>' : ''}
            </div>`;
        }).join('');

        const modal = document.createElement('div');
        modal.className = 'reactors-modal';
        modal.innerHTML = `
            <div class="reactors-modal-header">${this.escapeHtml(emoji)} <span class="reactors-modal-count">${reactors.size}</span></div>
            <div class="reactors-modal-list">${userItems}</div>
        `;

        document.body.appendChild(modal);
        this.reactorsModal = modal;

        // Position near the badge
        const rect = badge.getBoundingClientRect();
        const modalRect = modal.getBoundingClientRect();
        const spaceAbove = rect.top;
        const spaceBelow = window.innerHeight - rect.bottom;

        // Horizontal: align left edge with badge, but keep within viewport
        let left = rect.left;
        if (left + modalRect.width > window.innerWidth - 10) {
            left = window.innerWidth - modalRect.width - 10;
        }
        if (left < 10) left = 10;
        modal.style.left = left + 'px';

        // Vertical: prefer above, fall back to below
        if (spaceAbove > modalRect.height + 10) {
            modal.style.bottom = (window.innerHeight - rect.top + 6) + 'px';
        } else {
            modal.style.top = (rect.bottom + 6) + 'px';
        }

        // Click user row to open PM
        modal.querySelectorAll('.reactors-modal-user').forEach(el => {
            el.addEventListener('click', (e) => {
                const pubkey = el.dataset.pubkey;
                if (pubkey !== this.pubkey) {
                    const user = this.users.get(pubkey);
                    const baseNym = user ? this.parseNymFromDisplay(user.nym) : `anon`;
                    this.openUserPM(baseNym, pubkey);
                }
                this.closeReactorsModal();
            });
        });
    },

    closeReactorsModal() {
        if (this.reactorsModal) {
            this.reactorsModal.remove();
            this.reactorsModal = null;
        }
    },

    showReactionPicker(messageId, button) {
        // Toggle if clicking same button
        if (this.enhancedEmojiModal && this.activeReactionPickerButton === button) {
            this.closeEnhancedEmojiModal();
            this.activeReactionPickerButton = null;
            return;
        }

        // Remember which button opened this
        this.activeReactionPickerButton = button;

        // Use enhanced picker
        this.showEnhancedReactionPicker(messageId, button);
    },

    showEnhancedReactionPicker(messageId, button) {
        // Check if clicking the same button that opened the current modal
        if (this.enhancedEmojiModal && this.activeReactionPickerButton === button) {
            this.closeEnhancedEmojiModal();
            return;
        }

        // Close any existing picker
        this.closeEnhancedEmojiModal();

        // Remember which button opened this
        this.activeReactionPickerButton = button;

        const modal = document.createElement('div');
        modal.className = 'enhanced-emoji-modal active';

        // Create reverse lookup for emoji names
        const emojiToNames = {};
        Object.entries(this.emojiMap).forEach(([name, emoji]) => {
            if (!emojiToNames[emoji]) {
                emojiToNames[emoji] = [];
            }
            emojiToNames[emoji].push(name);
        });

        modal.innerHTML = `
<div class="emoji-modal-header">
    <input type="text" class="emoji-search-input" placeholder="Search emoji by name..." id="emojiSearchInput">
</div>
${this.recentEmojis.length > 0 ? `
    <div class="emoji-section">
        <div class="emoji-section-title">Recently Used</div>
        <div class="emoji-grid">
            ${this.recentEmojis.map(emoji =>
            `<button class="emoji-option" data-emoji="${emoji}" title="${emojiToNames[emoji] ? emojiToNames[emoji].join(', ') : ''}">${emoji}</button>`
        ).join('')}
        </div>
    </div>
` : ''}
${Object.entries(this.allEmojis).map(([category, emojis]) => `
    <div class="emoji-section" data-category="${category}">
        <div class="emoji-section-title">${category.charAt(0).toUpperCase() + category.slice(1)}</div>
        <div class="emoji-grid">
            ${emojis.map(emoji => {
            const names = emojiToNames[emoji] || [];
            return `<button class="emoji-option" data-emoji="${emoji}" data-names="${names.join(' ')}" title="${names.join(', ')}">${emoji}</button>`;
        }).join('')}
        </div>
    </div>
`).join('')}
`;

        // Position modal
        const rect = button.getBoundingClientRect();
        let css;
        if (window.innerWidth <= 768) {
            // Center on mobile
            css = 'position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);max-width:90%;max-height:80vh;z-index:10000;';
        } else {
            const spaceBelow = window.innerHeight - rect.bottom;
            const spaceAbove = rect.top;
            const vertical = (spaceBelow > 450 || spaceBelow > spaceAbove)
                ? `top:${rect.bottom + 10}px;bottom:auto;`
                : `bottom:${window.innerHeight - rect.top + 10}px;top:auto;`;
            const horizontal = (rect.left > window.innerWidth * 0.5)
                ? `right:${Math.min(window.innerWidth - rect.right, 10)}px;left:auto;`
                : `left:${Math.max(rect.left, 10)}px;right:auto;`;
            css = `position:fixed;${vertical}${horizontal}max-height:400px;`;
        }
        modal.style.cssText = css;

        document.body.appendChild(modal);
        this.enhancedEmojiModal = modal;

        // Add search functionality
        const searchInput = modal.querySelector('#emojiSearchInput');
        let searchDebounceTimer = null;
        searchInput.addEventListener('input', (e) => {
            const value = e.target.value;
            if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
            searchDebounceTimer = setTimeout(() => {
                searchDebounceTimer = null;
                const search = value.toLowerCase();
                modal.querySelectorAll('.emoji-option').forEach(btn => {
                    const emoji = btn.textContent;
                    const names = btn.dataset.names || '';
                    const shouldShow = !search ||
                        emoji.includes(search) ||
                        names.toLowerCase().includes(search);
                    btn.style.display = shouldShow ? '' : 'none';
                });
                // Hide empty sections
                modal.querySelectorAll('.emoji-section').forEach(section => {
                    const hasVisible = Array.from(section.querySelectorAll('.emoji-option'))
                        .some(btn => btn.style.display !== 'none');
                    section.style.display = hasVisible ? '' : 'none';
                });
            }, 80);
        });

        // Add click handlers
        modal.querySelectorAll('.emoji-option').forEach(btn => {
            btn.onclick = async (e) => {
                e.stopPropagation();
                const emoji = btn.dataset.emoji;
                this.addToRecentEmojis(emoji);
                await this.sendReaction(messageId, emoji);
                this.closeEnhancedEmojiModal();
            };
        });

        // Focus search
        searchInput.focus();
    },

    toggleEmojiPicker() {
        // Check if modal already exists
        if (this.enhancedEmojiModal) {
            // Close existing modal
            this.closeEnhancedEmojiModal();
            return;
        }

        // Create modal for emoji picker
        const button = document.querySelector('.icon-btn.input-btn[title="Emoji"]');
        if (button) {
            this.showEnhancedEmojiPickerForInput(button);
        }
    },

    showEnhancedEmojiPickerForInput(button) {
        // Close any existing picker
        this.closeEnhancedEmojiModal();

        const modal = document.createElement('div');
        modal.className = 'enhanced-emoji-modal active';

        // Create reverse lookup for emoji names
        const emojiToNames = {};
        Object.entries(this.emojiMap).forEach(([name, emoji]) => {
            if (!emojiToNames[emoji]) {
                emojiToNames[emoji] = [];
            }
            emojiToNames[emoji].push(name);
        });

        modal.innerHTML = `
<div class="emoji-modal-header">
    <input type="text" class="emoji-search-input" placeholder="Search emoji by name..." id="emojiSearchInput">
</div>
${this.recentEmojis.length > 0 ? `
    <div class="emoji-section">
        <div class="emoji-section-title">Recently Used</div>
        <div class="emoji-grid">
            ${this.recentEmojis.map(emoji =>
            `<button class="emoji-option" data-emoji="${emoji}" title="${emojiToNames[emoji] ? emojiToNames[emoji].join(', ') : ''}">${emoji}</button>`
        ).join('')}
        </div>
    </div>
` : ''}
${Object.entries(this.allEmojis).map(([category, emojis]) => `
    <div class="emoji-section" data-category="${category}">
        <div class="emoji-section-title">${category.charAt(0).toUpperCase() + category.slice(1)}</div>
        <div class="emoji-grid">
            ${emojis.map(emoji => {
            const names = emojiToNames[emoji] || [];
            return `<button class="emoji-option" data-emoji="${emoji}" data-names="${names.join(' ')}" title="${names.join(', ')}">${emoji}</button>`;
        }).join('')}
        </div>
    </div>
`).join('')}
`;

        // Position near button
        const rect = button.getBoundingClientRect();
        modal.style.position = 'fixed';

        // Check if on mobile
        if (window.innerWidth <= 768) {
            modal.style.bottom = '60px';
            modal.style.left = '50%';
            modal.style.transform = 'translateX(-50%)';
            modal.style.right = 'auto';
            modal.style.maxWidth = '90%';
        } else {
            modal.style.bottom = (window.innerHeight - rect.top + 10) + 'px';
            modal.style.right = Math.min(window.innerWidth - rect.right + 50, 10) + 'px';
        }

        document.body.appendChild(modal);
        this.enhancedEmojiModal = modal;

        // Add search functionality
        const searchInput = modal.querySelector('#emojiSearchInput');
        let searchDebounceTimer = null;
        searchInput.addEventListener('input', (e) => {
            const value = e.target.value;
            if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
            searchDebounceTimer = setTimeout(() => {
                searchDebounceTimer = null;
                const search = value.toLowerCase();
                modal.querySelectorAll('.emoji-option').forEach(btn => {
                    const emoji = btn.textContent;
                    const names = btn.dataset.names || '';
                    const shouldShow = !search ||
                        emoji.includes(search) ||
                        names.toLowerCase().includes(search);
                    btn.style.display = shouldShow ? '' : 'none';
                });
                // Hide empty sections
                modal.querySelectorAll('.emoji-section').forEach(section => {
                    const hasVisible = Array.from(section.querySelectorAll('.emoji-option'))
                        .some(btn => btn.style.display !== 'none');
                    section.style.display = hasVisible ? '' : 'none';
                });
            }, 80);
        });

        // Add click handlers for inserting emoji into input
        modal.querySelectorAll('.emoji-option').forEach(btn => {
            btn.onclick = (e) => {
                e.stopPropagation();
                const emoji = btn.dataset.emoji;
                this.insertEmoji(emoji);
                this.closeEnhancedEmojiModal();
            };
        });

        // Focus search
        searchInput.focus();
    },

    closeEnhancedEmojiModal() {
        if (this.enhancedEmojiModal) {
            this.enhancedEmojiModal.remove();
            this.enhancedEmojiModal = null;
        }
        // Clear the button reference
        this.activeReactionPickerButton = null;
    },

    _checkReactionRateLimit(messageId, emoji) {
        const key = `${messageId}:${emoji}`;
        const now = Date.now();
        const windowMs = 30000; // 30 second window
        const maxToggles = 3; // max 3 toggles (react/unreact) per window

        let tracker = this.reactionToggleTracker.get(key);
        if (!tracker) {
            tracker = { timestamps: [], cooldownUntil: 0 };
            this.reactionToggleTracker.set(key, tracker);
        }

        // Check if in cooldown
        if (now < tracker.cooldownUntil) {
            const remaining = Math.ceil((tracker.cooldownUntil - now) / 1000);
            this.displaySystemMessage(`Slow down! You can react again in ${remaining}s`);
            return false;
        }

        // Prune old timestamps outside the window
        tracker.timestamps = tracker.timestamps.filter(ts => now - ts < windowMs);

        // Check if over limit
        if (tracker.timestamps.length >= maxToggles) {
            tracker.cooldownUntil = now + 60000; // 1 minute cooldown
            this.displaySystemMessage('Too many reaction toggles. Try again in 60s');
            return false;
        }

        tracker.timestamps.push(now);
        return true;
    },

    async sendReaction(messageId, emoji) {
        try {
            if (!this._checkReactionRateLimit(messageId, emoji)) return;

            const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
            if (!messageEl) return;

            const targetPubkey = messageEl.dataset.pubkey;
            if (!targetPubkey) return;

            // Ensure local state contains this reaction
            if (!this.reactions.has(messageId)) {
                this.reactions.set(messageId, new Map());
            }
            const messageReactions = this.reactions.get(messageId);
            if (!messageReactions.has(emoji)) {
                messageReactions.set(emoji, new Map());
            }

            // Check if already reacted
            if (messageReactions.get(emoji).has(this.pubkey)) {
                return; // Already reacted with this emoji
            }

            // Add reaction immediately to local state
            messageReactions.get(emoji).set(this.pubkey, this.nym);

            // Update UI immediately
            this.updateMessageReactions(messageId);

            // Infer original kind from message context
            let originalKind = '20000'; // default to geohash channel
            if (messageEl.classList.contains('pm') || messageEl.dataset.isPM === '1') {
                originalKind = '1059'; // NIP-17 gift wrap (covers 1:1 PMs and group messages)
            }

            const event = {
                kind: 7,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['e', messageId],
                    ['p', targetPubkey],
                    ['k', originalKind]
                ],
                content: emoji,
                pubkey: this.pubkey
            };

            // For group messages: send reaction as gift wrap to all members so it stays private
            const groupId = messageEl.dataset.groupId;
            if (groupId && this._canSendGiftWraps()) {
                const group = this.groupConversations.get(groupId);
                if (group) {
                    const now = Math.floor(Date.now() / 1000);
                    const reactionTags = [['g', groupId], ['e', messageId], ['k', '14']];
                    const reactionRumor = {
                        kind: 7,
                        created_at: now,
                        tags: reactionTags,
                        content: emoji,
                        pubkey: this.pubkey
                    };
                    await this._sendGiftWrapsAsync(group.members, reactionRumor, null, groupId);
                    this.addToRecentEmojis(emoji);
                    return;
                }
            }

            // For 1:1 PM messages: send reaction as gift wrap to the peer so it stays private
            if (messageEl.dataset.isPM === '1' && !groupId && this._canSendGiftWraps() && this.currentPM) {
                const now = Math.floor(Date.now() / 1000);
                const reactionRumor = {
                    kind: 7,
                    created_at: now,
                    tags: [['e', messageId], ['p', targetPubkey], ['k', '1059']],
                    content: emoji,
                    pubkey: this.pubkey
                };
                // Gift wrap to both ourselves and the peer
                await this._sendGiftWrapsAsync([this.pubkey, this.currentPM], reactionRumor, null);
                this.addToRecentEmojis(emoji);
                return;
            }

            const signedEvent = await this.signEvent(event);

            if (signedEvent) {
                // Send to relay (async - UI already updated)
                this.sendToRelay(["EVENT", signedEvent]);
                this.addToRecentEmojis(emoji);
            } else {
                // Signing failed - revert the optimistic update
                messageReactions.get(emoji).delete(this.pubkey);
                this.updateMessageReactions(messageId);
                this.displaySystemMessage('Failed to sign reaction');
            }
        } catch (error) {
            // Revert optimistic update on error
            const messageReactions = this.reactions.get(messageId);
            if (messageReactions && messageReactions.has(emoji)) {
                messageReactions.get(emoji).delete(this.pubkey);
                this.updateMessageReactions(messageId);
            }
        }
    },

    async removeReaction(messageId, emoji) {
        try {
            if (!this._checkReactionRateLimit(messageId, emoji)) return;

            const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
            if (!messageEl) return;

            const targetPubkey = messageEl.dataset.pubkey;
            if (!targetPubkey) return;

            // Remove reaction from local state immediately
            const messageReactions = this.reactions.get(messageId);
            if (!messageReactions || !messageReactions.has(emoji)) return;
            messageReactions.get(emoji).delete(this.pubkey);
            if (messageReactions.get(emoji).size === 0) {
                messageReactions.delete(emoji);
            }
            if (messageReactions.size === 0) {
                this.reactions.delete(messageId);
            }

            // Update UI immediately
            this.updateMessageReactions(messageId);

            // Infer original kind from message context
            let originalKind = '20000';
            if (messageEl.classList.contains('pm') || messageEl.dataset.isPM === '1') {
                originalKind = '1059';
            }

            const event = {
                kind: 7,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['e', messageId],
                    ['p', targetPubkey],
                    ['k', originalKind],
                    ['action', 'remove']
                ],
                content: emoji,
                pubkey: this.pubkey
            };

            // For group messages: send unreact as gift wrap to all members
            const groupId = messageEl.dataset.groupId;
            if (groupId && this._canSendGiftWraps()) {
                const group = this.groupConversations.get(groupId);
                if (group) {
                    const now = Math.floor(Date.now() / 1000);
                    const unreactTags = [['g', groupId], ['e', messageId], ['k', '14'], ['action', 'remove']];
                    const reactionRumor = {
                        kind: 7,
                        created_at: now,
                        tags: unreactTags,
                        content: emoji,
                        pubkey: this.pubkey
                    };
                    await this._sendGiftWrapsAsync(group.members, reactionRumor, null, groupId);
                    return;
                }
            }

            // For 1:1 PM messages: send unreact as gift wrap to the peer
            if (messageEl.dataset.isPM === '1' && !groupId && this._canSendGiftWraps() && this.currentPM) {
                const now = Math.floor(Date.now() / 1000);
                const reactionRumor = {
                    kind: 7,
                    created_at: now,
                    tags: [['e', messageId], ['p', targetPubkey], ['k', '1059'], ['action', 'remove']],
                    content: emoji,
                    pubkey: this.pubkey
                };
                await this._sendGiftWrapsAsync([this.pubkey, this.currentPM], reactionRumor, null);
                return;
            }

            const signedEvent = await this.signEvent(event);

            if (signedEvent) {
                this.sendToRelay(["EVENT", signedEvent]);
            } else {
                // Signing failed - revert the optimistic removal
                if (!this.reactions.has(messageId)) this.reactions.set(messageId, new Map());
                const mr = this.reactions.get(messageId);
                if (!mr.has(emoji)) mr.set(emoji, new Map());
                mr.get(emoji).set(this.pubkey, this.nym);
                this.updateMessageReactions(messageId);
                this.displaySystemMessage('Failed to sign reaction removal');
            }
        } catch (error) {
            // Revert optimistic removal on error
            if (!this.reactions.has(messageId)) this.reactions.set(messageId, new Map());
            const mr = this.reactions.get(messageId);
            if (!mr.has(emoji)) mr.set(emoji, new Map());
            mr.get(emoji).set(this.pubkey, this.nym);
            this.updateMessageReactions(messageId);
        }
    },

    closeReactionPicker() {
        if (this.activeReactionPicker) {
            this.activeReactionPicker.remove();
            this.activeReactionPicker = null;
            this.activeReactionPickerButton = null;
        }
    },

    setupEmojiPicker() {
        const picker = document.getElementById('emojiPicker');
        if (!picker) return;

        // Build reverse lookup for names
        const emojiToNames = {};
        Object.entries(this.emojiMap).forEach(([name, emoji]) => {
            if (!emojiToNames[emoji]) emojiToNames[emoji] = [];
            emojiToNames[emoji].push(name);
        });

        let html = `<div class="emoji-picker-search">
            <input type="text" class="emoji-picker-search-input" placeholder="Search emoji..." id="emojiPickerSearch">
        </div>`;

        // Recent emojis section
        if (this.recentEmojis.length > 0) {
            html += `<div class="emoji-picker-section" data-category="recent">
                <div class="emoji-picker-section-title">Recent</div>
                <div class="emoji-picker-grid">
                    ${this.recentEmojis.map(emoji => {
                const names = emojiToNames[emoji] || [];
                return `<button class="emoji-btn" data-emoji="${emoji}" data-names="${names.join(' ')}" title="${names.join(', ')}">${emoji}</button>`;
            }).join('')}
                </div>
            </div>`;
        }

        // All category sections
        Object.entries(this.allEmojis).forEach(([category, emojis]) => {
            html += `<div class="emoji-picker-section" data-category="${category}">
                <div class="emoji-picker-section-title">${category.charAt(0).toUpperCase() + category.slice(1)}</div>
                <div class="emoji-picker-grid">
                    ${emojis.map(emoji => {
                const names = emojiToNames[emoji] || [];
                return `<button class="emoji-btn" data-emoji="${emoji}" data-names="${names.join(' ')}" title="${names.join(', ')}">${emoji}</button>`;
            }).join('')}
                </div>
            </div>`;
        });

        picker.innerHTML = html;

        // Search handler
        const searchInput = picker.querySelector('#emojiPickerSearch');
        if (searchInput) {
            searchInput.addEventListener('input', (e) => {
                const search = e.target.value.toLowerCase();
                picker.querySelectorAll('.emoji-btn').forEach(btn => {
                    const names = btn.dataset.names || '';
                    const shouldShow = !search ||
                        btn.textContent.includes(search) ||
                        names.toLowerCase().includes(search);
                    btn.style.display = shouldShow ? '' : 'none';
                });
                picker.querySelectorAll('.emoji-picker-section').forEach(section => {
                    const hasVisible = Array.from(section.querySelectorAll('.emoji-btn'))
                        .some(btn => btn.style.display !== 'none');
                    section.style.display = hasVisible ? '' : 'none';
                });
            });
        }

        // Click handlers
        picker.querySelectorAll('.emoji-btn').forEach(btn => {
            btn.onclick = () => this.insertEmoji(btn.dataset.emoji || btn.textContent);
        });
    },

    insertEmoji(emoji) {
        const input = document.getElementById('messageInput');
        const start = input.selectionStart;
        const end = input.selectionEnd;
        const text = input.value;

        input.value = text.substring(0, start) + emoji + text.substring(end);
        input.selectionStart = input.selectionEnd = start + emoji.length;
        input.focus();

        this.addToRecentEmojis(emoji);
    },

});
