// reactions.js - Reaction sending/removal, reactor lists, emoji picker

Object.assign(NYM.prototype, {

    _playReactionBurst(anchorEl, emoji) {
        if (!anchorEl) return;
        const rect = anchorEl.getBoundingClientRect();
        if (!rect.width && !rect.height) return;
        const cx = rect.left + rect.width / 2;
        const cy = rect.top + rect.height / 2;

        const burst = document.createElement('div');
        burst.className = 'reaction-burst';
        burst.style.left = cx + 'px';
        burst.style.top = cy + 'px';
        burst.innerHTML = this.renderReactionEmoji(emoji);

        const sparks = document.createElement('div');
        sparks.className = 'reaction-burst-sparks';
        sparks.style.left = cx + 'px';
        sparks.style.top = cy + 'px';
        const sparkCount = 10;
        for (let i = 0; i < sparkCount; i++) {
            const s = document.createElement('span');
            s.className = 'reaction-spark';
            const angle = (i / sparkCount) * Math.PI * 2 + (Math.random() - 0.5) * 0.4;
            const dist = 22 + Math.random() * 22;
            s.style.setProperty('--dx', (Math.cos(angle) * dist).toFixed(1) + 'px');
            s.style.setProperty('--dy', (Math.sin(angle) * dist).toFixed(1) + 'px');
            s.style.animationDelay = (Math.random() * 40) + 'ms';
            sparks.appendChild(s);
        }

        document.body.appendChild(burst);
        document.body.appendChild(sparks);
        setTimeout(() => {
            if (burst.parentNode) burst.remove();
            if (sparks.parentNode) sparks.remove();
        }, 900);
    },

    _findReactionBadge(messageId, emoji) {
        const badges = document.querySelectorAll(`.reaction-badge[data-message-id="${CSS.escape(messageId)}"]`);
        for (let i = 0; i < badges.length; i++) {
            if (badges[i].dataset.emoji === emoji) return badges[i];
        }
        return null;
    },

    _burstOnBadge(messageId, emoji, fallbackEl) {
        const badge = this._findReactionBadge(messageId, emoji);
        this._playReactionBurst(badge || fallbackEl, emoji);
    },

    _playMessageDisintegration(messageEl) {
        if (!messageEl) return false;
        if (messageEl.dataset.disintegrating === '1') return true;

        const isBubble = document.body.classList.contains('chat-bubbles');
        const group = isBubble ? messageEl.closest('.message-group') : null;
        const stack = group ? group.querySelector(':scope > .message-group-stack') : null;
        const siblingCount = stack ? stack.querySelectorAll(':scope > .message').length : 1;
        const wrapper = (group && siblingCount <= 1) ? group : messageEl;

        const rect = wrapper.getBoundingClientRect();
        if (!rect.width || !rect.height) return false;
        messageEl.dataset.disintegrating = '1';

        const stage = document.createElement('div');
        stage.className = 'msg-disintegrate-stage';
        stage.style.left = rect.left + 'px';
        stage.style.top = rect.top + 'px';
        stage.style.width = rect.width + 'px';
        stage.style.height = rect.height + 'px';

        const aspect = rect.width / rect.height;
        const cols = Math.max(6, Math.min(12, Math.round(Math.sqrt(rect.width * rect.height) / 26)));
        const rows = Math.max(3, Math.min(10, Math.round(cols / Math.max(0.6, aspect))));

        const tileWPct = 100 / cols;
        const tileHPct = 100 / rows;

        for (let r = 0; r < rows; r++) {
            for (let c = 0; c < cols; c++) {
                const tile = wrapper.cloneNode(true);
                tile.removeAttribute('id');
                tile.removeAttribute('data-message-id');
                tile.querySelectorAll('[data-message-id]').forEach(n => n.removeAttribute('data-message-id'));
                tile.querySelectorAll('[id]').forEach(n => n.removeAttribute('id'));
                tile.classList.add('msg-disintegrate-tile');
                tile.style.width = rect.width + 'px';
                tile.style.height = rect.height + 'px';

                const x1 = c * tileWPct;
                const y1 = r * tileHPct;
                const x2 = (c + 1) * tileWPct;
                const y2 = (r + 1) * tileHPct;
                tile.style.clipPath = `polygon(${x1}% ${y1}%, ${x2}% ${y1}%, ${x2}% ${y2}%, ${x1}% ${y2}%)`;

                const dx = (Math.random() - 0.35) * 130;
                const dy = -20 - Math.random() * 110;
                const rot = (Math.random() - 0.5) * 90;
                const sweep = (c / cols) * 280;
                const delay = sweep + Math.random() * 160;
                tile.style.setProperty('--dx', dx.toFixed(1) + 'px');
                tile.style.setProperty('--dy', dy.toFixed(1) + 'px');
                tile.style.setProperty('--rot', rot.toFixed(0) + 'deg');
                tile.style.animationDelay = delay + 'ms';

                stage.appendChild(tile);
            }
        }

        document.body.appendChild(stage);
        wrapper.classList.add('msg-disintegrate-hidden');
        if (messageEl !== wrapper) messageEl.classList.add('msg-disintegrate-hidden');

        setTimeout(() => {
            if (stage.parentNode) stage.remove();
            if (messageEl.parentNode) messageEl.remove();
            if (group && !group.querySelector(':scope > .message-group-stack > .message')) {
                if (group.parentNode) group.remove();
            }
        }, 1400);
        return true;
    },

    loadRecentEmojis() {
        const saved = localStorage.getItem('nym_recent_emojis');
        if (saved) {
            this.recentEmojis = JSON.parse(saved);
        }
    },

    saveRecentEmojis() {
        localStorage.setItem('nym_recent_emojis', JSON.stringify(this.recentEmojis.slice(0, 24)));
        if (typeof this._debouncedNostrSettingsSave === 'function') {
            this._debouncedNostrSettingsSave();
        }
    },

    addToRecentEmojis(emoji) {
        this.recentEmojis = this.recentEmojis.filter(e => e !== emoji);
        this.recentEmojis.unshift(emoji);
        this.recentEmojis = this.recentEmojis.slice(0, 24);
        this._emojiRecentsDirty = true;
        this.saveRecentEmojis();
    },

    _recentEmojisForPicker() {
        const isMobile = window.innerWidth <= 768;
        const limit = isMobile ? 20 : 24;
        return this.recentEmojis.filter(e => {
            if (typeof e !== 'string') return true;
            const m = e.match(/^:([a-zA-Z0-9_]+):$/);
            if (!m) return true;
            return this.customEmojis && this.customEmojis.has(m[1]);
        }).slice(0, limit);
    },

    // Move reaction state from oldId to newId so reaction keys always match the
    // ID the DOM renders with. A message's nymMessageId can be assigned after
    // reactions were already stored under its event ID; without this migration
    // those reactions vanish once the bubble redraws keyed by nymMessageId.
    _migrateReactionKey(oldId, newId) {
        if (!oldId || !newId || oldId === newId) return false;
        let changed = false;

        const old = this.reactions.get(oldId);
        if (old) {
            const target = this.reactions.get(newId);
            if (!target) {
                this.reactions.set(newId, old);
            } else {
                for (const [emoji, reactors] of old) {
                    if (!target.has(emoji)) target.set(emoji, new Map());
                    const merged = target.get(emoji);
                    for (const [pk, nym] of reactors) merged.set(pk, nym);
                }
            }
            this.reactions.delete(oldId);
            changed = true;
        }

        // Rekey timestamp-tracking entries (`${id}:${emoji}:${pubkey}`)
        if (this.reactionLastAction) {
            const prefix = oldId + ':';
            for (const [k, v] of Array.from(this.reactionLastAction.entries())) {
                if (k.startsWith(prefix)) {
                    this.reactionLastAction.delete(k);
                    this.reactionLastAction.set(newId + k.slice(oldId.length), v);
                }
            }
        }

        if (changed && typeof this.persistReactions === 'function') {
            this.persistReactions(oldId);
            this.persistReactions(newId);
        }
        return changed;
    },

    handleReaction(event) {
        if (event && this.blockedUsers && this.blockedUsers.has(event.pubkey)) return;
        // Register any NIP-30 custom emoji declared on this reaction
        this.ingestEmojiTags(event.tags);
        const reactionContent = event.content;
        const eTag = event.tags.find(t => t[0] === 'e');
        const kTag = event.tags.find(t => t[0] === 'k');
        const pTag = event.tags.find(t => t[0] === 'p');
        const actionTag = event.tags.find(t => t[0] === 'action');
        const isRemoval = actionTag && actionTag[1] === 'remove';

        if (!eTag) return;

        // Only process reactions for our supported kinds
        // 20000 = geohash channel, 23333 = named channel, 1059 = NIP-17 gift wraps, 14 = group rumor messages
        if (kTag && !['20000', '23333', '1059', '14'].includes(kTag[1])) {
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
            this.persistReactions(messageId);
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
        const isNewReaction = !messageReactions.get(reactionContent).has(event.pubkey);
        messageReactions.get(reactionContent).set(event.pubkey, reactorNym);
        this.persistReactions(messageId);

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

        // Burst on the badge for live reactions from other users, mirroring our own
        if (reactionApplied && isNewReaction && event.pubkey !== this.pubkey) {
            const reactionAge = Date.now() - (event.created_at * 1000);
            if (reactionAge <= 10000) {
                this._burstOnBadge(messageId, reactionContent, null);
            }
        }

        // Notify if someone reacted to OUR message (not our own reaction)
        if (pTag && pTag[1] === this.pubkey && event.pubkey !== this.pubkey) {
            const messageAge = Date.now() - (event.created_at * 1000);
            const isHistorical = messageAge > 10000;
            const channelInfo = {
                type: 'reaction',
                id: event.id,
                eventId: event.id,
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
                        if (key.startsWith('group-')) {
                            channelInfo.sourceType = 'group';
                            channelInfo.sourceGroupId = key.slice(6);
                        } else if (key.startsWith('pm-')) {
                            channelInfo.sourceType = 'pm';
                            const parts = key.slice(3).split('-');
                            channelInfo.sourcePubkey = parts.find(p => p && p !== this.pubkey) || parts[0];
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
                this.showNotification(reactorNym, body, channelInfo, event.created_at * 1000);
            }
        }
    },

    updateMessageReactions(messageId) {
        const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
        if (!messageEl) return false;

        // Capture scroll state before modifying DOM so we can auto-scroll if needed
        const container = document.getElementById('messagesScroller');
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

            badge.innerHTML = `${this.renderReactionEmoji(emoji)} ${this.abbreviateNumber(reactors.size)}`;

            // No tooltip — long-press shows reactors modal instead

            // Long-press to show reactors modal
            let longPressTimer = null;
            let didLongPress = false;
            let touchActive = false;
            let suppressClickUntil = 0;

            const startLongPress = (e) => {
                // Ignore synthetic mouse events that follow a touch sequence
                if (e.type === 'mousedown' && touchActive) return;
                didLongPress = false;
                longPressTimer = setTimeout(() => {
                    didLongPress = true;
                    suppressClickUntil = Date.now() + 800;
                    window.nymHapticTap && window.nymHapticTap();
                    this.showReactorsModal(messageId, emoji, badge);
                }, 500);
            };

            const cancelLongPress = (e) => {
                if (longPressTimer) {
                    clearTimeout(longPressTimer);
                    longPressTimer = null;
                }
                // If the long press fired, swallow the synthetic click that
                // touchend produces so we don't toggle the user's reaction.
                if (didLongPress && e && e.cancelable) {
                    try { e.preventDefault(); } catch { }
                }
            };

            badge.addEventListener('mousedown', startLongPress);
            badge.addEventListener('touchstart', (e) => { touchActive = true; startLongPress(e); }, { passive: false });
            badge.addEventListener('mouseup', cancelLongPress);
            badge.addEventListener('mouseleave', cancelLongPress);
            badge.addEventListener('touchend', (e) => { cancelLongPress(e); setTimeout(() => { touchActive = false; }, 600); });
            badge.addEventListener('touchcancel', (e) => { cancelLongPress(e); touchActive = false; });
            badge.addEventListener('touchmove', cancelLongPress);

            // Click handler - only fire if not a long press
            badge.onclick = async (e) => {
                e.stopPropagation();
                if (didLongPress || Date.now() < suppressClickUntil) {
                    e.preventDefault();
                    return;
                }
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
<svg viewBox="0 0 20 20" class="nm-react-1">
    <path fill-rule="evenodd" clip-rule="evenodd" d="M15.5 1a.75.75 0 0 1 .75.75v2h2a.75.75 0 0 1 0 1.5h-2v2a.75.75 0 0 1-1.5 0v-2h-2a.75.75 0 0 1 0-1.5h2v-2A.75.75 0 0 1 15.5 1m-13 10a6.5 6.5 0 0 1 7.166-6.466.75.75 0 0 0 .152-1.493 8 8 0 1 0 7.14 7.139.75.75 0 0 0-1.492.152A7 7 0 0 1 15.5 11a6.5 6.5 0 1 1-13 0m4.25-.5a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5m4.5 0a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5M9 15c1.277 0 2.553-.724 3.06-2.173.148-.426-.209-.827-.66-.827H6.6c-.452 0-.808.4-.66.827C6.448 14.276 7.724 15 9 15"></path>
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

        // Build user list, capping the rendered rows so a large reactor list
        // doesn't blow out the modal — overflow is summarised as "+N more".
        const MAX_ROWS = 50;
        const entries = Array.from(reactors.entries());
        const shown = entries.slice(0, MAX_ROWS);
        const userItems = shown.map(([pubkey, nym]) => {
            const isYou = pubkey === this.pubkey;
            const baseNym = this.parseNymFromDisplay(nym);
            const suffix = this.getPubkeySuffix(pubkey);
            const safePk = this._safePubkey(pubkey);
            return `<div class="reactors-modal-user" data-pubkey="${pubkey}">
                <img src="${this.escapeHtml(this.getAvatarUrl(pubkey))}" class="readers-modal-avatar" data-avatar-pubkey="${safePk}" decoding="async" loading="lazy">
                <span class="reactors-modal-nym">${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span></span>
                ${isYou ? '<span class="reactors-modal-you">you</span>' : ''}
            </div>`;
        }).join('');
        const overflow = entries.length - shown.length;
        const overflowItem = overflow > 0
            ? `<div class="reactors-modal-more">+${overflow} more</div>`
            : '';

        const modal = document.createElement('div');
        modal.className = 'reactors-modal';
        modal.innerHTML = `
            <div class="reactors-modal-header"><span class="reactors-modal-emoji">${this.renderReactionEmoji(emoji)}</span> <span class="reactors-modal-count">${reactors.size}</span></div>
            <div class="reactors-modal-list">${userItems}${overflowItem}</div>
        `;

        document.body.appendChild(modal);
        this.reactorsModal = modal;

        if (typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(modal, shown.map(([pk]) => pk));
        }

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

        // Click user row to open their context menu
        modal.querySelectorAll('.reactors-modal-user').forEach((el, i) => {
            el.addEventListener('click', (e) => {
                const [pubkey, nym] = shown[i];
                this.closeReactorsModal();
                const baseNym = this.parseNymFromDisplay(nym);
                const suffix = this.getPubkeySuffix(pubkey);
                this.showContextMenu(e, `${baseNym}#${suffix}`, pubkey, null, null, false);
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

    // The enhanced modal DOM is expensive (~7k nodes), so it's built once,
    // detached on close, and rebuilt only when packs/favorites/recents change.
    _ensureEnhancedEmojiModal() {
        let modal = this._cachedEmojiModal;
        if (modal && this._emojiRecentsDirty && !this._emojiPickerDirty) {
            this._refreshEmojiModalRecents(modal);
            this._emojiRecentsDirty = false;
        }
        if (modal && !this._emojiPickerDirty) {
            this._resetEmojiSearch(modal);
            return modal;
        }
        if (!modal) {
            modal = document.createElement('div');
            modal.className = 'enhanced-emoji-modal active';
            this._bindEmojiModalEvents(modal);
            this._cachedEmojiModal = modal;
        }
        modal.innerHTML = `
<div class="emoji-modal-header">
    <input type="text" class="emoji-search-input" placeholder="Search emoji by name..." id="emojiSearchInput">
    <button class="modal-close emoji-modal-close" data-action="closeEnhancedEmojiModal" aria-label="Close">&#x2715;</button>
</div>
${this._emojiSectionsHtml()}`;
        this._indexEmojiSearch(modal, '.emoji-option', '.emoji-section');
        this._emojiPickerDirty = false;
        this._emojiRecentsDirty = false;
        return modal;
    },

    _refreshEmojiModalRecents(modal) {
        const recents = this._recentEmojisForPicker();
        const section = modal.querySelector('.emoji-section[data-category="recent"]');
        if (!section) {
            if (recents.length > 0) this._emojiPickerDirty = true;
            return;
        }
        const grid = section.querySelector('.emoji-grid');
        if (!grid) return;
        const emojiToNames = this._getEmojiToNames();
        grid.innerHTML = recents.map(e => this.emojiOptionHtml(e, emojiToNames)).join('');
        this._reindexEmojiSection(modal, section);
    },

    _bindEmojiModalEvents(modal) {
        modal.addEventListener('click', async (e) => {
            if (e.target.closest('[data-action]')) return;
            const btn = e.target.closest('.emoji-option');
            if (!btn) return;
            e.stopPropagation();
            const emoji = btn.dataset.emoji;
            if (this._activePickerMode === 'input') {
                this.insertEmoji(emoji);
                this.closeEnhancedEmojiModal();
                return;
            }
            this.addToRecentEmojis(emoji);
            const onSelect = this._activePickerOnSelect;
            const messageId = this._activePickerMessageId;
            if (typeof onSelect === 'function') {
                onSelect(emoji);
            } else {
                await this.sendReaction(messageId, emoji);
            }
            this.closeEnhancedEmojiModal();
        });
        modal.addEventListener('input', (e) => {
            if (!e.target.classList.contains('emoji-search-input')) return;
            const value = e.target.value;
            if (modal._searchTimer) clearTimeout(modal._searchTimer);
            modal._searchTimer = setTimeout(() => {
                modal._searchTimer = null;
                this._applyEmojiSearch(modal, value);
            }, 80);
        });
    },

    _indexEmojiSearch(root, btnSel, sectionSel) {
        const sections = [];
        root.querySelectorAll(sectionSel).forEach(sec => {
            sections.push({ el: sec, items: this._indexEmojiSectionItems(sec, btnSel) });
        });
        root._emojiSearch = { sections, btnSel, active: false };
    },

    _indexEmojiSectionItems(sec, btnSel) {
        const items = [];
        sec.querySelectorAll(btnSel).forEach(btn => {
            items.push({ el: btn, text: btn.textContent, names: (btn.dataset.names || '').toLowerCase() });
        });
        return items;
    },

    _reindexEmojiSection(root, sec) {
        const idx = root._emojiSearch;
        if (!idx) return;
        const entry = idx.sections.find(s => s.el === sec);
        if (entry) entry.items = this._indexEmojiSectionItems(sec, idx.btnSel);
    },

    _applyEmojiSearch(root, value) {
        const idx = root._emojiSearch;
        if (!idx) return;
        const search = (value || '').toLowerCase();
        if (!search && !idx.active) return;
        for (const sec of idx.sections) {
            let visible = 0;
            for (const item of sec.items) {
                const show = !search || item.text.includes(search) || item.names.includes(search);
                item.el.classList.toggle('emoji-hidden', !show);
                if (show) visible++;
            }
            sec.el.classList.toggle('emoji-hidden', visible === 0);
        }
        idx.active = !!search;
    },

    _resetEmojiSearch(root) {
        const input = root.querySelector('.emoji-search-input, .emoji-picker-search-input');
        if (input && input.value) input.value = '';
        this._applyEmojiSearch(root, '');
    },

    showEnhancedReactionPicker(messageId, button, onSelect) {
        // Check if clicking the same button that opened the current modal
        if (this.enhancedEmojiModal && this.activeReactionPickerButton === button) {
            this.closeEnhancedEmojiModal();
            return;
        }

        // Close any existing picker
        this.closeEnhancedEmojiModal();

        // Remember which button opened this and the chosen-emoji callback so
        // toggleEmojiPackFavorite can re-render without changing the mode
        this.activeReactionPickerButton = button;
        this._activePickerOnSelect = onSelect || null;
        this._activePickerMessageId = messageId || null;
        this._activePickerMode = 'reaction';

        const modal = this._ensureEnhancedEmojiModal();

        // Position modal
        const rect = button.getBoundingClientRect();
        let css;
        if (window.innerWidth <= 768) {
            // Center on mobile
            css = 'position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);max-width:90%;max-height:80vh;z-index:10010;';
        } else {
            const spaceBelow = window.innerHeight - rect.bottom;
            const spaceAbove = rect.top;
            const vertical = (spaceBelow > 450 || spaceBelow > spaceAbove)
                ? `top:${rect.bottom + 10}px;bottom:auto;`
                : `bottom:${window.innerHeight - rect.top + 10}px;top:auto;`;
            const horizontal = (rect.left > window.innerWidth * 0.5)
                ? `right:${Math.min(window.innerWidth - rect.right, 10)}px;left:auto;`
                : `left:${Math.max(rect.left, 10)}px;right:auto;`;
            css = `position:fixed;${vertical}${horizontal}max-height:400px;z-index:10010;`;
        }
        modal.style.cssText = css;
        modal.scrollTop = 0;

        document.body.appendChild(modal);
        this.enhancedEmojiModal = modal;
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

        // Track the launch button so category-favorite toggles can re-render
        this.activeReactionPickerButton = button;
        this._activePickerMode = 'input';

        const modal = this._ensureEnhancedEmojiModal();

        // Position near button
        const rect = button.getBoundingClientRect();
        let css;
        if (window.innerWidth <= 768) {
            css = 'position:fixed;bottom:60px;left:50%;transform:translateX(-50%);right:auto;max-width:90%;';
        } else {
            const bottom = (window.innerHeight - rect.top + 10);
            const right = Math.min(window.innerWidth - rect.right + 50, 10);
            css = `position:fixed;bottom:${bottom}px;right:${right}px;`;
        }
        modal.style.cssText = css;
        modal.scrollTop = 0;

        document.body.appendChild(modal);
        this.enhancedEmojiModal = modal;
    },

    closeEnhancedEmojiModal() {
        const wasOpen = !!this.enhancedEmojiModal;
        if (this.enhancedEmojiModal) {
            this.enhancedEmojiModal.remove();
            this.enhancedEmojiModal = null;
        }
        // Clear the button reference
        this.activeReactionPickerButton = null;
        this._activePickerOnSelect = null;
        this._activePickerMessageId = null;
        this._activePickerMode = null;
        if (wasOpen && typeof this._focusMessageInput === 'function') this._focusMessageInput();
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

            window.nymHapticTap && window.nymHapticTap();

            // Add reaction immediately to local state
            messageReactions.get(emoji).set(this.pubkey, this.nym);
            this.persistReactions(messageId);

            // Update UI immediately
            this.updateMessageReactions(messageId);

            this._burstOnBadge(messageId, emoji, messageEl);

            // Bump our own presence so status stays "online".
            this.recordOwnActivity();

            // Infer original kind from message context
            let originalKind = '20000'; // default to geohash channel
            if (messageEl.classList.contains('pm') || messageEl.dataset.isPM === '1') {
                originalKind = '1059'; // NIP-17 gift wrap (covers 1:1 PMs and group messages)
            } else if (this.currentGeohash && !this.isValidGeohash(this.currentGeohash)) {
                originalKind = '23333'; // named (non-geohash) channel
            }

            const reactionTags = [
                ['e', messageId],
                ['p', targetPubkey],
                ['k', originalKind],
                ...this.customEmojiTagsForContent(emoji)
            ];
            const reactionGeohash = (originalKind === '20000' && this.currentGeohash) ? this.currentGeohash : '';
            if (reactionGeohash) {
                reactionTags.push(['g', reactionGeohash]);
            } else if (originalKind === '23333' && this.currentChannel) {
                // Carry the named-channel id so the D1 archive can key the reaction.
                reactionTags.push(['d', this.currentChannel]);
            }

            const event = {
                kind: 7,
                created_at: Math.floor(Date.now() / 1000),
                tags: reactionTags,
                content: emoji,
                pubkey: this.pubkey
            };

            // For group messages: send reaction as gift wrap to all members so it stays private
            const groupId = messageEl.dataset.groupId;
            if (groupId && this._canSendGiftWraps()) {
                const group = this.groupConversations.get(groupId);
                if (group) {
                    const now = Math.floor(Date.now() / 1000);
                    const reactionTags = [['g', groupId], ['e', messageId], ['k', '14'],
                        ...this.customEmojiTagsForContent(emoji)];
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
                    tags: [['e', messageId], ['p', targetPubkey], ['k', '1059'],
                        ...this.customEmojiTagsForContent(emoji)],
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
                if (reactionGeohash) {
                    this.ensureGeoRelayDelivery(signedEvent, reactionGeohash);
                }
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
            this.persistReactions(messageId);

            // Update UI immediately
            this.updateMessageReactions(messageId);

            // Bump our own presence so status stays "online".
            this.recordOwnActivity();

            // Infer original kind from message context
            let originalKind = '20000';
            if (messageEl.classList.contains('pm') || messageEl.dataset.isPM === '1') {
                originalKind = '1059';
            } else if (this.currentGeohash && !this.isValidGeohash(this.currentGeohash)) {
                originalKind = '23333';
            }

            const removeTags = [
                ['e', messageId],
                ['p', targetPubkey],
                ['k', originalKind],
                ['action', 'remove'],
                ...this.customEmojiTagsForContent(emoji)
            ];
            const removeGeohash = (originalKind === '20000' && this.currentGeohash) ? this.currentGeohash : '';
            if (removeGeohash) {
                removeTags.push(['g', removeGeohash]);
            } else if (originalKind === '23333' && this.currentChannel) {
                removeTags.push(['d', this.currentChannel]);
            }

            const event = {
                kind: 7,
                created_at: Math.floor(Date.now() / 1000),
                tags: removeTags,
                content: emoji,
                pubkey: this.pubkey
            };

            // For group messages: send unreact as gift wrap to all members
            const groupId = messageEl.dataset.groupId;
            if (groupId && this._canSendGiftWraps()) {
                const group = this.groupConversations.get(groupId);
                if (group) {
                    const now = Math.floor(Date.now() / 1000);
                    const unreactTags = [['g', groupId], ['e', messageId], ['k', '14'], ['action', 'remove'],
                        ...this.customEmojiTagsForContent(emoji)];
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
                    tags: [['e', messageId], ['p', targetPubkey], ['k', '1059'], ['action', 'remove'],
                        ...this.customEmojiTagsForContent(emoji)],
                    content: emoji,
                    pubkey: this.pubkey
                };
                await this._sendGiftWrapsAsync([this.pubkey, this.currentPM], reactionRumor, null);
                return;
            }

            const signedEvent = await this.signEvent(event);

            if (signedEvent) {
                this.sendToRelay(["EVENT", signedEvent]);
                if (removeGeohash) {
                    this.ensureGeoRelayDelivery(signedEvent, removeGeohash);
                }
            } else {
                // Signing failed - revert the optimistic removal
                if (!this.reactions.has(messageId)) this.reactions.set(messageId, new Map());
                const mr = this.reactions.get(messageId);
                if (!mr.has(emoji)) mr.set(emoji, new Map());
                mr.get(emoji).set(this.pubkey, this.nym);
                this.persistReactions(messageId);
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

    setupEmojiPicker() {
        const picker = document.getElementById('emojiPicker');
        if (!picker) return;

        picker.innerHTML = `<div class="emoji-picker-search">
            <input type="text" class="emoji-picker-search-input" placeholder="Search emoji..." id="emojiPickerSearch">
        </div>` + this._emojiSectionsHtml({
            sectionClass: 'emoji-picker-section',
            titleClass: 'emoji-picker-section-title',
            gridClass: 'emoji-picker-grid',
            btnClass: 'emoji-btn'
        });

        this._indexEmojiSearch(picker, '.emoji-btn', '.emoji-picker-section');

        if (!picker._emojiBound) {
            picker._emojiBound = true;
            picker.addEventListener('click', (e) => {
                if (e.target.closest('[data-action]')) return;
                const btn = e.target.closest('.emoji-btn');
                if (btn) this.insertEmoji(btn.dataset.emoji || btn.textContent);
            });
            picker.addEventListener('input', (e) => {
                if (!e.target.classList.contains('emoji-picker-search-input')) return;
                const value = e.target.value;
                if (picker._searchTimer) clearTimeout(picker._searchTimer);
                picker._searchTimer = setTimeout(() => {
                    picker._searchTimer = null;
                    this._applyEmojiSearch(picker, value);
                }, 80);
            });
        }
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
