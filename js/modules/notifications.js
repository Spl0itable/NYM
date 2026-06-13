// notifications.js - Notification history, badges, sounds, settings

Object.assign(NYM.prototype, {

    showNotification(title, body, channelInfo = null, timestamp = null) {
        if (!this.notificationsEnabled) return;

        const baseTitle = this.parseNymFromDisplay(title);

        const senderPubkey = channelInfo?.pubkey || '';
        if (senderPubkey && this.blockedUsers.has(senderPubkey)) return;
        if (this.notifyFriendsOnly && senderPubkey && !this.isFriend(senderPubkey)) return;
        if (body && body.includes('10 recent messages:')) return;
        if (senderPubkey && this.isVerifiedBot(senderPubkey)) return;

        let titleToShow = baseTitle;
        if (channelInfo && channelInfo.pubkey) {
            const suffix = this.getPubkeySuffix(channelInfo.pubkey);
            titleToShow = `${baseTitle}#${suffix}`;
        }

        const ts = (typeof timestamp === 'number' && timestamp > 0) ? timestamp : Date.now();
        const eventId = channelInfo?.eventId || '';

        // Dedup against existing history before adding (live + replay paths
        // can both call this for the same underlying event).
        const isDupe = this.notificationHistory.some(n => {
            if (eventId && n.eventId && n.eventId === eventId) return true;
            if (n.title === titleToShow && n.body === body
                && n.senderPubkey === (channelInfo?.pubkey || '')
                && Math.abs((n.timestamp || 0) - ts) < 60000) return true;
            return false;
        });
        if (isDupe) {
            this._updateNotificationBadge();
            return;
        }

        // viewed compares against when WE received the notification, not the
        // event's created_at — otherwise a delayed event with an older
        // created_at would be auto-marked viewed after the modal was opened.
        const receivedAt = Date.now();
        const entry = {
            title: titleToShow,
            body: body,
            channelInfo: channelInfo,
            timestamp: ts,
            receivedAt,
            senderNym: baseTitle,
            senderPubkey: channelInfo?.pubkey || '',
            eventId: eventId || undefined
        };
        const previouslySeen = this._isNotificationSeen(entry);
        entry.viewed = previouslySeen
            || receivedAt <= (this.notificationLastReadTime || 0)
            || this._notificationAlreadySeen(channelInfo, ts);
        if (entry.viewed) this._rememberNotificationSeen(entry);
        this.notificationHistory.push(entry);
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        this.notificationHistory = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
        this._saveNotificationHistory();
        this._updateNotificationBadge();
        this._refreshNotificationsModalIfOpen();
        if (typeof this._debouncedNostrSettingsSave === 'function') {
            this._debouncedNostrSettingsSave(8000);
        }

        // Already seen on this or another device; record it silently.
        if (previouslySeen) return;

        if (this.settings.sound !== 'none') {
            this.playSound(this.settings.sound);
        }

        // Browser notification
        if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
            try {
                const notification = new Notification(titleToShow, {
                    body: body,
                    icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="%23000"/><text x="50" y="55" font-size="24" fill="%230ff" text-anchor="middle" font-family="monospace">Nymchat</text></svg>',
                    tag: channelInfo ? (channelInfo.id || 'nym-notification') : 'nym-notification',
                    requireInteraction: false,
                    data: { channelInfo: channelInfo }
                });

                if (channelInfo) {
                    notification.onclick = (event) => {
                        event.preventDefault();
                        window.focus();

                        if (channelInfo.type === 'pm') {
                            this.openUserPM(channelInfo.nym || baseTitle, channelInfo.pubkey);
                        } else if (channelInfo.type === 'group') {
                            this.openGroup(channelInfo.groupId);
                        } else if (channelInfo.type === 'geohash') {
                            this.switchChannel(channelInfo.channel, channelInfo.geohash);
                        } else if (channelInfo.type === 'reaction') {
                            if (channelInfo.sourceType === 'pm' && channelInfo.sourcePubkey) {
                                this.openUserPM(this.getNymFromPubkey(channelInfo.sourcePubkey), channelInfo.sourcePubkey);
                            } else if (channelInfo.sourceType === 'group' && channelInfo.sourceGroupId) {
                                this.openGroup(channelInfo.sourceGroupId);
                            } else if (channelInfo.sourceType === 'geohash' && channelInfo.sourceGeohash) {
                                this.switchChannel(channelInfo.sourceChannel, channelInfo.sourceGeohash);
                            }
                        }

                        notification.close();
                    };
                }
            } catch (error) {
            }
        }

    },

    // Silently add a notification to history without triggering sound/popup/browser notification.
    _addNotificationToHistory(title, body, channelInfo, timestamp) {
        if (!this.notificationsEnabled) return;

        const baseTitle = this.parseNymFromDisplay(title);

        const senderPubkey = channelInfo?.pubkey || '';
        if (senderPubkey && this.blockedUsers.has(senderPubkey)) return;
        if (this.notifyFriendsOnly && senderPubkey && !this.isFriend(senderPubkey)) return;
        if (body && body.includes('10 recent messages:')) return;
        if (senderPubkey && this.isVerifiedBot(senderPubkey)) return;

        let titleToShow = baseTitle;
        if (channelInfo && channelInfo.pubkey) {
            const suffix = this.getPubkeySuffix(channelInfo.pubkey);
            titleToShow = `${baseTitle}#${suffix}`;
        }
        const ts = (typeof timestamp === 'number' && timestamp > 0) ? timestamp : Date.now();
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        if (ts < cutoff24h) return;
        const eventId = channelInfo?.eventId || '';
        const isDupe = this.notificationHistory.some(n => {
            if (eventId && n.eventId && n.eventId === eventId) return true;
            if (n.title === titleToShow && n.body === body
                && n.senderPubkey === (channelInfo?.pubkey || '')
                && Math.abs((n.timestamp || 0) - ts) < 60000) return true;
            return false;
        });
        if (isDupe) return;
        const receivedAt = Date.now();
        const entry = {
            title: titleToShow,
            body: body,
            channelInfo: channelInfo,
            timestamp: ts,
            receivedAt,
            senderNym: baseTitle,
            senderPubkey: channelInfo?.pubkey || '',
            eventId: eventId || undefined
        };
        entry.viewed = this._isNotificationSeen(entry)
            || receivedAt <= (this.notificationLastReadTime || 0)
            || this._notificationAlreadySeen(channelInfo, ts);
        if (entry.viewed) this._rememberNotificationSeen(entry);
        this.notificationHistory.push(entry);
        this.notificationHistory = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
        this._saveNotificationHistory();
        this._updateNotificationBadge();
        this._refreshNotificationsModalIfOpen();
    },

    _refreshNotificationsModalIfOpen() {
        const modal = document.getElementById('notificationsModal');
        if (!modal || !modal.classList.contains('active')) return;
        if (this._refreshNotifModalTimer) return;
        this._refreshNotifModalTimer = setTimeout(() => {
            this._refreshNotifModalTimer = null;
            const m = document.getElementById('notificationsModal');
            if (!m || !m.classList.contains('active')) return;
            this.openNotificationsModal();
        }, 150);
    },

    // Called when a message lands in storage. If an open zap notification was
    // waiting for that messageId's text, re-render the modal so it shows.
    _maybeRefreshZapNotif(messageId) {
        if (!messageId || !this.notificationHistory) return;
        const matches = this.notificationHistory.some(n =>
            n && n.channelInfo && n.channelInfo.zapMessageId === messageId);
        if (!matches) return;
        if (typeof this._refreshNotificationsModalIfOpen === 'function') {
            this._refreshNotificationsModalIfOpen();
        }
    },

    // Look up the zapped message text fresh from storage and build the
    // enriched body. Returns null if the message still isn't available.
    _enrichZapBody(messageId, sats) {
        if (!messageId || !sats) return null;
        let content = '';
        const msgEl = document.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
        if (msgEl) content = msgEl.dataset.rawContent || '';
        if (!content) {
            for (const msgs of this.messages.values()) {
                const found = msgs.find(m => m.id === messageId);
                if (found) { content = found.content || ''; break; }
            }
        }
        if (!content && this.pmMessages) {
            for (const msgs of this.pmMessages.values()) {
                const found = msgs.find(m => m.id === messageId || m.nymMessageId === messageId);
                if (found) { content = found.content || ''; break; }
            }
        }
        if (!content) return null;
        let preview = content.split('\n').filter(l => !l.startsWith('>')).join(' ').trim();
        if (!preview) return null;
        if (preview.length > 80) preview = preview.slice(0, 80) + '…';
        return `⚡ zapped ${sats} sats to: "${preview}"`;
    },

    _loadNotificationHistory() {
        try {
            const raw = localStorage.getItem('nym_notification_history');
            if (!raw) return [];
            const parsed = JSON.parse(raw);
            const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
            return parsed.filter(n => n.timestamp > cutoff24h);
        } catch { return []; }
    },

    _saveNotificationHistory() {
        try {
            const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
            const recent = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
            localStorage.setItem('nym_notification_history', JSON.stringify(recent));
        } catch { }
    },

    // Durable record of which notifications the user has already seen, keyed by
    // a stable identity so replayed/resynced events can't re-trigger the badge.
    // Synced via the nymchat-notifications wrap for cross-device read state.
    _notificationSeenKey(n) {
        if (!n) return null;
        const evId = n.eventId || n.channelInfo?.eventId || '';
        if (evId) return `e:${evId}`;
        const pk = n.senderPubkey || n.channelInfo?.pubkey || '';
        const ts = n.timestamp || 0;
        if (!pk && !ts) return null;
        // body prefix kept short of the 240-char sync truncation so the key
        // matches across local (full body) and synced (truncated) copies
        return `f:${pk}:${Math.floor(ts / 60000)}:${(n.body || '').slice(0, 40)}`;
    },

    _loadSeenNotificationKeys() {
        try {
            const raw = localStorage.getItem('nym_notification_seen');
            if (!raw) return new Map();
            const parsed = JSON.parse(raw);
            const cutoff = Date.now() - 48 * 60 * 60 * 1000;
            const map = new Map();
            for (const [k, ts] of Object.entries(parsed)) {
                if (typeof ts === 'number' && ts > cutoff) map.set(k, ts);
            }
            return map;
        } catch { return new Map(); }
    },

    _pruneSeenNotificationKeys() {
        if (!this.seenNotificationKeys) { this.seenNotificationKeys = new Map(); return; }
        const cutoff = Date.now() - 48 * 60 * 60 * 1000;
        for (const [k, ts] of this.seenNotificationKeys) {
            if (!(ts > cutoff)) this.seenNotificationKeys.delete(k);
        }
        const MAX_SEEN_KEYS = 500;
        if (this.seenNotificationKeys.size > MAX_SEEN_KEYS) {
            const newest = [...this.seenNotificationKeys.entries()]
                .sort((a, b) => b[1] - a[1])
                .slice(0, MAX_SEEN_KEYS);
            this.seenNotificationKeys = new Map(newest);
        }
    },

    _saveSeenNotificationKeys() {
        try {
            this._pruneSeenNotificationKeys();
            localStorage.setItem('nym_notification_seen',
                JSON.stringify(Object.fromEntries(this.seenNotificationKeys)));
        } catch { }
    },

    _isNotificationSeen(n) {
        if (!this.seenNotificationKeys) return false;
        const key = this._notificationSeenKey(n);
        return !!(key && this.seenNotificationKeys.has(key));
    },

    _rememberNotificationSeen(n, save = true) {
        const key = this._notificationSeenKey(n);
        if (!key) return false;
        if (!this.seenNotificationKeys) this.seenNotificationKeys = new Map();
        if (this.seenNotificationKeys.has(key)) return false;
        this.seenNotificationKeys.set(key, n.timestamp || Date.now());
        if (save) this._saveSeenNotificationKeys();
        return true;
    },

    // Canonical conversation key for a notification, matching channelLastRead keys
    _notificationConvKey(channelInfo) {
        if (!channelInfo) return null;
        if (channelInfo.type === 'geohash') {
            const g = channelInfo.geohash || channelInfo.channel;
            return g ? `#${g}` : null;
        }
        if (channelInfo.type === 'pm') {
            return channelInfo.id || (channelInfo.pubkey ? this.getPMConversationKey(channelInfo.pubkey) : null);
        }
        if (channelInfo.type === 'group') {
            return channelInfo.id || (channelInfo.groupId ? `group-${channelInfo.groupId}` : null);
        }
        return null;
    },

    // True when the user has already read the conversation up to this message,
    // so it shouldn't count as an unread notification.
    _notificationAlreadySeen(channelInfo, tsMs) {
        const key = this._notificationConvKey(channelInfo);
        if (!key || !this.channelLastRead) return false;
        const seen = this.channelLastRead.get(key) || 0;
        if (!seen) return false;
        return Math.floor((tsMs || 0) / 1000) <= seen;
    },

    // Remove a missed-call notification, e.g. once the call was answered elsewhere.
    _retractMissedCallNotification(callId) {
        if (!callId || !Array.isArray(this.notificationHistory)) return;
        const tag = `missed-call-${callId}`;
        const before = this.notificationHistory.length;
        this.notificationHistory = this.notificationHistory.filter(n =>
            !(n && n.channelInfo && n.channelInfo.eventId === tag));
        if (this.notificationHistory.length === before) return;
        this._saveNotificationHistory();
        this._updateNotificationBadge();
        this._refreshNotificationsModalIfOpen();
        if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(2000);
    },

    // When a conversation is read up to tsSec, retroactively mark its pending
    // notifications viewed so the badge clears without opening the modal.
    _markConversationNotificationsSeen(convKey, tsSec) {
        if (!convKey || !Array.isArray(this.notificationHistory) || !this.notificationHistory.length) return;
        let changed = false;
        for (const n of this.notificationHistory) {
            if (n.viewed) continue;
            if (this._notificationConvKey(n.channelInfo) !== convKey) continue;
            if (Math.floor((n.timestamp || 0) / 1000) > tsSec) continue;
            n.viewed = true;
            this._rememberNotificationSeen(n, false);
            changed = true;
        }
        if (changed) {
            this._saveSeenNotificationKeys();
            this._saveNotificationHistory();
            this._updateNotificationBadge();
            this._refreshNotificationsModalIfOpen();
            if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(4000);
        }
    },

    markAllNotificationsRead() {
        if (!Array.isArray(this.notificationHistory)) return;
        let changed = false;
        for (const n of this.notificationHistory) {
            if (!n || n.viewed === true) continue;
            n.viewed = true;
            this._rememberNotificationSeen(n, false);
            changed = true;
        }
        const btn = document.getElementById('markAllNotificationsReadBtn');
        if (btn) btn.classList.add('nm-hidden');
        if (!changed) return;
        this._saveSeenNotificationKeys();
        this._saveNotificationHistory();
        this._updateNotificationBadge();
        if (this._notifSeenObserver) {
            this._notifSeenObserver.disconnect();
            this._notifSeenObserver = null;
        }
        const body = document.getElementById('notificationsModalBody');
        if (body) {
            body.querySelectorAll('.notification-item-unread')
                .forEach(el => el.classList.remove('notification-item-unread'));
        }
        if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(2000);
    },

    _updateNotificationBadge() {
        // Coalesce burst calls (every incoming PM/mention triggers one) into a
        // single DOM update per animation frame.
        if (this._notifBadgeRafPending) return;
        this._notifBadgeRafPending = true;
        const raf = window.requestAnimationFrame || (cb => setTimeout(cb, 16));
        raf(() => {
            this._notifBadgeRafPending = false;
            this._doUpdateNotificationBadge();
        });
    },

    _doUpdateNotificationBadge() {
        const desktopBadge = document.getElementById('notifBadgeDesktop');
        const mobileBadge = document.getElementById('notifBadgeMobile');

        if (!this.notificationsEnabled) {
            [desktopBadge, mobileBadge].forEach(badge => {
                if (badge) badge.classList.add('nm-hidden');
            });
            return;
        }

        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        const lastRead = this.notificationLastReadTime || 0;
        const unreadCount = this.notificationHistory.filter(n => {
            if (n.timestamp <= cutoff24h) return false;
            if (n.viewed === true) return false;
            const observedAt = n.receivedAt || n.timestamp || 0;
            if (observedAt <= lastRead) return false;
            if (this._notificationAlreadySeen(n.channelInfo, n.timestamp)) return false;
            const pubkey = n.senderPubkey || n.channelInfo?.pubkey || '';
            if (pubkey && this.blockedUsers.has(pubkey)) return false;
            return true;
        }).length;

        [desktopBadge, mobileBadge].forEach(badge => {
            if (!badge) return;
            if (unreadCount > 0) {
                badge.textContent = unreadCount > 99 ? '99+' : unreadCount;
                badge.classList.remove('nm-hidden');
            } else {
                badge.classList.add('nm-hidden');
            }
        });
    },

    openNotificationsModal() {
        const modal = document.getElementById('notificationsModal');
        const body = document.getElementById('notificationsModalBody');
        if (!modal || !body) return;

        // Sync checkbox state
        const checkbox = document.getElementById('enableNotificationsCheckbox');
        if (checkbox) checkbox.checked = this.notificationsEnabled;
        const mentionsCheckbox = document.getElementById('groupMentionsOnlyCheckbox');
        if (mentionsCheckbox) mentionsCheckbox.checked = this.groupNotifyMentionsOnly;
        const friendsOnlyCheckbox = document.getElementById('notifyFriendsOnlyCheckbox');
        if (friendsOnlyCheckbox) friendsOnlyCheckbox.checked = this.notifyFriendsOnly;

        // Filter to last 24 hours and exclude blocked users, then sort by
        // timestamp ascending so the descending-iteration below renders
        // newest first regardless of insertion order (historical replay,
        // remote sync merges, etc. can leave the array out of order).
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        const recent = this.notificationHistory.filter(n => {
            if (n.timestamp <= cutoff24h) return false;
            const pubkey = n.senderPubkey || n.channelInfo?.pubkey || '';
            if (pubkey && this.blockedUsers.has(pubkey)) return false;
            return true;
        }).sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));

        const markAllBtn = document.getElementById('markAllNotificationsReadBtn');
        if (markAllBtn) markAllBtn.classList.toggle('nm-hidden', !recent.some(n => !n.viewed));

        if (recent.length === 0) {
            body.innerHTML = '<div class="notifications-empty">No notifications in the last 24 hours</div>';
        } else {
            // Pull fresh kind 0 profiles for any sender we don't already have
            // cached, so default nyms/avatars get replaced once the events
            // land (the kind 0 handler refreshes the open modal in place).
            if (typeof this.queueProfileFetch === 'function') {
                const seenPubkeys = new Set();
                for (const n of recent) {
                    const pk = n.senderPubkey || n.channelInfo?.pubkey || '';
                    if (!pk || seenPubkeys.has(pk) || pk === this.pubkey) continue;
                    seenPubkeys.add(pk);
                    if (this.users.has(pk) && this.userAvatars && this.userAvatars.has(pk)) continue;
                    try { this.queueProfileFetch(pk); } catch (_) { }
                }
            }
            body.innerHTML = '';
            // Show newest first
            for (let i = recent.length - 1; i >= 0; i--) {
                const n = recent[i];
                const item = document.createElement('div');
                item.className = 'notification-item';
                item._notif = n;
                if (!n.viewed) item.classList.add('notification-item-unread');
                if (n.channelInfo) item.style.cursor = 'pointer';
                const dt = new Date(n.timestamp);
                const time = dt.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

                // Build avatar + nym + flair like channel messages
                const pubkey = n.senderPubkey || n.channelInfo?.pubkey || '';
                let avatarHtml = '';
                let authorHtml = '';
                if (pubkey) {
                    const avatarSrc = this.getAvatarUrl(pubkey);
                    const safePk = this._safePubkey(pubkey);
                    avatarHtml = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy">`;
                    // Use live profile lookup, fall back to stored senderNym
                    const user = this.users.get(pubkey);
                    const baseNym = user
                        ? this.parseNymFromDisplay(user.nym)
                        : this.parseNymFromDisplay(this.getNymFromPubkey(pubkey));
                    const suffix = this.getPubkeySuffix(pubkey);
                    const flairHtml = this.getFlairForUser(pubkey);
                    const verifiedBadge = this.isVerifiedDeveloper(pubkey)
                        ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
                        : this.isVerifiedBot(pubkey)
                            ? '<span class="verified-badge" title="Nymchat Bot">✓</span>'
                            : '';
                    authorHtml = `<span class="notification-item-author" data-notif-pubkey="${this.escapeHtml(pubkey)}"><span class="nym-bracket">&lt;</span>${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span><span class="nym-bracket">&gt;</span>${flairHtml} ${verifiedBadge}</span>`;
                }

                // Channel/context label
                let contextHtml = '';
                if (n.channelInfo) {
                    if (n.channelInfo.type === 'geohash') {
                        contextHtml = `<span class="notification-item-context">in #${this.escapeHtml(n.channelInfo.geohash)}</span>`;
                    } else if (n.channelInfo.type === 'group') {
                        const groupName = n.title.split(':')[0] || 'Group';
                        contextHtml = `<span class="notification-item-context">in ${this.escapeHtml(groupName)}</span>`;
                    } else if (n.channelInfo.type === 'pm') {
                        contextHtml = `<span class="notification-item-context">PM</span>`;
                    } else if (n.channelInfo.type === 'reaction') {
                        contextHtml = `<span class="notification-item-context">Reaction</span>`;
                    } else if (n.channelInfo.type === 'call') {
                        const label = n.channelInfo.callKind === 'video' ? 'Missed video call' : 'Missed audio call';
                        contextHtml = `<span class="notification-item-context">${label}</span>`;
                    }
                }

                // Strip quoted lines (> prefixed) to show only the new message
                let rawBody = n.body || '';

                // If this is a zap notification and the original message is
                // now in storage, re-render the body with the actual text.
                if (n.channelInfo && n.channelInfo.zapMessageId) {
                    const enriched = this._enrichZapBody(n.channelInfo.zapMessageId, n.channelInfo.zapSats);
                    if (enriched) rawBody = enriched;
                }

                const newMessageLines = rawBody.split('\n').filter(line => !line.startsWith('>'));
                const displayBody = newMessageLines.join(' ').replace(/\s+/g, ' ').trim().slice(0, 200);

                item.innerHTML = `
                    <div class="notification-item-header">
                        ${avatarHtml}
                        <div class="notification-item-meta">
                            <div class="notification-item-title">${authorHtml}</div>
                            <div class="notification-item-body">${this.renderCustomEmojiInEscapedText(this.escapeHtml(displayBody))}</div>
                            <div class="notification-item-footer">${contextHtml} <span class="notification-item-time">${time}</span></div>
                        </div>
                    </div>
                `;
                if (n.channelInfo) {
                    const info = n.channelInfo;
                    item.onclick = () => {
                        if (info.type === 'pm') {
                            this.openUserPM(info.nym || n.senderNym || n.title, info.pubkey);
                        } else if (info.type === 'group') {
                            this.openGroup(info.groupId);
                        } else if (info.type === 'geohash') {
                            this.switchChannel(info.channel, info.geohash);
                        } else if (info.type === 'reaction') {
                            if (info.sourceType === 'pm' && info.sourcePubkey) {
                                this.openUserPM(this.getNymFromPubkey(info.sourcePubkey), info.sourcePubkey);
                            } else if (info.sourceType === 'group' && info.sourceGroupId) {
                                this.openGroup(info.sourceGroupId);
                            } else if (info.sourceType === 'geohash' && info.sourceGeohash) {
                                this.switchChannel(info.sourceChannel, info.sourceGeohash);
                            }
                        } else if (info.type === 'call') {
                            if (info.isGroup && info.groupId) {
                                this.openGroup(info.groupId);
                            } else if (info.pubkey) {
                                this.openUserPM(info.nym || n.senderNym || n.title, info.pubkey);
                            }
                        }
                        this.closeNotificationsModal();
                    };
                }
                body.appendChild(item);
            }
        }

        modal.classList.add('active');
        this._setupNotificationSeenObserver(body);
    },

    // Mark notifications viewed only as they actually scroll into view, so the
    // unread badge deducts per-item rather than zeroing on open.
    _setupNotificationSeenObserver(body) {
        if (this._notifSeenObserver) {
            this._notifSeenObserver.disconnect();
            this._notifSeenObserver = null;
        }
        if (!body) return;
        const items = Array.from(body.querySelectorAll('.notification-item'))
            .filter(el => el._notif && !el._notif.viewed);
        if (items.length === 0) return;

        const markSeen = (els) => {
            let changed = false;
            for (const el of els) {
                const n = el._notif;
                if (n && !n.viewed) {
                    n.viewed = true;
                    this._rememberNotificationSeen(n, false);
                    changed = true;
                    el.classList.remove('notification-item-unread');
                }
            }
            if (changed) {
                this._saveSeenNotificationKeys();
                if (typeof this._saveNotificationHistory === 'function') this._saveNotificationHistory();
                this._updateNotificationBadge();
                const btn = document.getElementById('markAllNotificationsReadBtn');
                if (btn && !body.querySelector('.notification-item-unread')) btn.classList.add('nm-hidden');
                if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(2000);
            }
        };

        if (!('IntersectionObserver' in window)) {
            markSeen(items);
            return;
        }
        const obs = new IntersectionObserver((entries) => {
            const seen = [];
            for (const entry of entries) {
                if (!entry.isIntersecting) continue;
                seen.push(entry.target);
                obs.unobserve(entry.target);
            }
            if (seen.length) markSeen(seen);
        }, { root: body, threshold: 0.6 });
        items.forEach(el => obs.observe(el));
        this._notifSeenObserver = obs;
    },

    // Refresh author name/avatar in the notifications modal when a kind 0 profile arrives
    updateNotificationModalProfile(pubkey, profileName) {
        const modal = document.getElementById('notificationsModal');
        if (!modal || !modal.classList.contains('active')) return;
        const baseNym = this.parseNymFromDisplay(
            profileName || this.getNymFromPubkey(pubkey)
        ).substring(0, 20);
        const suffix = this.getPubkeySuffix(pubkey);
        const flairHtml = this.getFlairForUser(pubkey);
        const verifiedBadge = this.isVerifiedDeveloper(pubkey)
            ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
            : this.isVerifiedBot(pubkey)
                ? '<span class="verified-badge" title="Nymchat Bot">✓</span>'
                : '';
        modal.querySelectorAll(`.notification-item-author[data-notif-pubkey="${this.escapeHtml(pubkey)}"]`).forEach(el => {
            el.innerHTML = `<span class="nym-bracket">&lt;</span>${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span><span class="nym-bracket">&gt;</span>${flairHtml} ${verifiedBadge}`;
        });
    },

    closeNotificationsModal() {
        if (this._notifSeenObserver) {
            this._notifSeenObserver.disconnect();
            this._notifSeenObserver = null;
        }
        const modal = document.getElementById('notificationsModal');
        if (modal) {
            modal.classList.remove('active');
            modal.style.display = '';
        }
    },

    // Each sound is a sequence of notes (f = frequency in Hz, d = duration in seconds,
    // optional f2 = glide target, gap = silence after the note, chord = simultaneous
    // frequencies, g = gain override, a = attack ramp time, noise = bandpass-filtered
    // white noise at f with resonance q). The game jingles use square waves to match
    // the original sound chips.
    NOTIFICATION_SOUNDS: {
        beep: { wave: 'sine', gain: 0.1, notes: [{ f: 800, d: 0.15 }] },
        low: { wave: 'sine', gain: 0.15, notes: [{ f: 600, d: 0.15 }] },
        high: { wave: 'sine', gain: 0.1, notes: [{ f: 1000, d: 0.15 }] },
        uhoh: {
            wave: 'sawtooth', gain: 0.08,
            notes: [{ f: 587, f2: 523, d: 0.16, gap: 0.08 }, { f: 494, f2: 392, d: 0.28 }]
        },
        msnding: {
            wave: 'sine', gain: 0.12,
            notes: [{ f: 880, d: 0.1 }, { f: 1318.51, d: 0.45 }]
        },
        nudge: {
            wave: 'sawtooth', gain: 0.1,
            notes: [
                { f: 130, f2: 90, d: 0.15 }, { f: 130, f2: 90, d: 0.15 }, { f: 130, f2: 90, d: 0.15 }
            ]
        },
        nokia: {
            wave: 'square', gain: 0.05,
            notes: [
                { f: 1396.91, d: 0.07, gap: 0.07 }, { f: 1396.91, d: 0.07, gap: 0.07 },
                { f: 1396.91, d: 0.07, gap: 0.21 },
                { f: 1396.91, d: 0.21, gap: 0.07 }, { f: 1396.91, d: 0.21, gap: 0.21 },
                { f: 1396.91, d: 0.07, gap: 0.07 }, { f: 1396.91, d: 0.07, gap: 0.07 },
                { f: 1396.91, d: 0.07 }
            ]
        },
        nokiatune: {
            wave: 'square', gain: 0.05,
            notes: [
                { f: 1318.51, d: 0.13 }, { f: 1174.66, d: 0.13 }, { f: 739.99, d: 0.26 }, { f: 830.61, d: 0.26 },
                { f: 1108.73, d: 0.13 }, { f: 987.77, d: 0.13 }, { f: 587.33, d: 0.26 }, { f: 659.25, d: 0.26 },
                { f: 987.77, d: 0.13 }, { f: 880.00, d: 0.13 }, { f: 554.37, d: 0.26 }, { f: 659.25, d: 0.26 },
                { f: 880.00, d: 0.65 }
            ]
        },
        dialup: {
            wave: 'sine', gain: 0.06,
            notes: [
                { chord: [350, 440], d: 0.4, gap: 0.05 },
                { chord: [770, 1209], d: 0.09, gap: 0.04 },
                { chord: [852, 1336], d: 0.09, gap: 0.04 },
                { chord: [697, 1477], d: 0.09, gap: 0.25 },
                { f: 2225, d: 0.35, gap: 0.05 },
                { f: 1270, d: 0.06 }, { f: 2225, d: 0.06 }, { f: 1270, d: 0.06 },
                { f: 2225, d: 0.06 }, { f: 1270, d: 0.06 }, { f: 2225, d: 0.06 },
                { chord: [1270, 2225], d: 0.4 }
            ]
        },
        tetris: {
            wave: 'square', gain: 0.06,
            notes: [
                { f: 659.25, d: 0.2 }, { f: 493.88, d: 0.1 }, { f: 523.25, d: 0.1 },
                { f: 587.33, d: 0.2 }, { f: 523.25, d: 0.1 }, { f: 493.88, d: 0.1 },
                { f: 440.00, d: 0.2 }, { f: 440.00, d: 0.1 }, { f: 523.25, d: 0.1 },
                { f: 659.25, d: 0.2 }, { f: 587.33, d: 0.1 }, { f: 523.25, d: 0.1 },
                { f: 493.88, d: 0.3 }, { f: 523.25, d: 0.1 }, { f: 587.33, d: 0.2 },
                { f: 659.25, d: 0.2 }, { f: 523.25, d: 0.2 }, { f: 440.00, d: 0.2 },
                { f: 440.00, d: 0.4 }
            ]
        },
        chirp: {
            wave: 'sine', gain: 0.1,
            notes: [{ f: 900, f2: 2200, d: 0.08, gap: 0.06 }, { f: 900, f2: 2200, d: 0.08 }]
        },
        coin: {
            wave: 'square', gain: 0.06,
            notes: [{ f: 987.77, d: 0.08 }, { f: 1318.51, d: 0.65 }]
        },
        // Exact APU frequencies decoded from the SMB sound engine data
        // (PowerUpGrabFreqData): rising C, Ab, Bb major arpeggios, one tone per 2 frames.
        powerup: {
            wave: 'square', gain: 0.06,
            notes: [
                { f: 522.7, d: 0.033 }, { f: 391.1, d: 0.033 }, { f: 522.7, d: 0.033 },
                { f: 658.0, d: 0.033 }, { f: 782.2, d: 0.033 }, { f: 1045.4, d: 0.033 },
                { f: 782.2, d: 0.033 }, { f: 414.3, d: 0.033 }, { f: 522.7, d: 0.033 },
                { f: 621.4, d: 0.033 }, { f: 828.6, d: 0.033 }, { f: 621.4, d: 0.033 },
                { f: 828.6, d: 0.033 }, { f: 1045.4, d: 0.033 }, { f: 1242.9, d: 0.033 },
                { f: 1645.0, d: 0.033 }, { f: 1242.9, d: 0.033 }, { f: 466.1, d: 0.033 },
                { f: 585.7, d: 0.033 }, { f: 694.8, d: 0.033 }, { f: 932.2, d: 0.033 },
                { f: 694.8, d: 0.033 }, { f: 932.2, d: 0.033 }, { f: 1165.2, d: 0.033 },
                { f: 1381.0, d: 0.033 }, { f: 1864.3, d: 0.033 }, { f: 1381.0, d: 0.15 }
            ]
        },
        // Lead channel of the Gen 1 "Pokemon healed" fanfare, exact Game Boy
        // frequencies decoded from the pokered disassembly (Music_PkmnHealed_Ch2).
        pokeheal: {
            wave: 'square', gain: 0.06,
            notes: [
                { f: 985.5, d: 0.45 }, { f: 985.5, d: 0.45 }, { f: 985.5, d: 0.23 },
                { f: 829.6, d: 0.23 }, { f: 1310.7, d: 0.9 }
            ]
        },
        // Measured from a recording of the broadcast bumper: a 1044Hz crescendo
        // swell, then 781/1174/985Hz beeps (no static, despite how it's heard).
        f1: {
            wave: 'sine', gain: 0.14,
            notes: [
                { f: 1044, d: 0.12, a: 0.11, g: 0.06 },
                { f: 781, d: 0.09, h: 0.05, g: 0.14 },
                { f: 1174, d: 0.09, h: 0.05, g: 0.12 },
                { f: 985, d: 0.1, h: 0.06, g: 0.11 }
            ]
        },
        oneup: {
            wave: 'square', gain: 0.06,
            notes: [
                { f: 659.25, d: 0.13 }, { f: 783.99, d: 0.13 }, { f: 1318.51, d: 0.13 },
                { f: 1046.50, d: 0.13 }, { f: 1174.66, d: 0.13 }, { f: 1567.98, d: 0.4 }
            ]
        },
        secret: {
            wave: 'square', gain: 0.06,
            notes: [
                { f: 783.99, d: 0.11 }, { f: 739.99, d: 0.11 }, { f: 622.25, d: 0.11 },
                { f: 440.00, d: 0.11 }, { f: 415.30, d: 0.11 }, { f: 659.25, d: 0.11 },
                { f: 830.61, d: 0.11 }, { f: 1046.50, d: 0.4 }
            ]
        },
        gameboy: {
            wave: 'square', gain: 0.06,
            notes: [{ f: 1046.50, d: 0.1 }, { f: 2093.00, d: 0.5 }]
        },
    },

    playSound(type) {
        // Deduplicate: don't replay within 2 seconds
        const now = Date.now();
        if (this._lastSoundPlayedAt && now - this._lastSoundPlayedAt < 2000) return;
        this._lastSoundPlayedAt = now;

        // Legacy values from before the sounds were relabeled
        const legacy = { icq: 'uhoh', msn: 'msnding' };
        const sound = this.NOTIFICATION_SOUNDS[legacy[type] || type];
        if (!sound) return;

        const audioContext = new (window.AudioContext || window.webkitAudioContext)();
        let t = audioContext.currentTime;
        for (const note of sound.notes) {
            const gainNode = audioContext.createGain();
            const gain = note.g || sound.gain;
            if (note.a) {
                gainNode.gain.setValueAtTime(0.0001, t);
                gainNode.gain.linearRampToValueAtTime(gain, t + note.a);
                gainNode.gain.exponentialRampToValueAtTime(0.001, t + note.d);
            } else if (note.h) {
                gainNode.gain.setValueAtTime(gain, t);
                gainNode.gain.setValueAtTime(gain, t + note.h);
                gainNode.gain.exponentialRampToValueAtTime(0.001, t + note.d);
            } else if (note.d < 0.06) {
                // Too short for a decay envelope; hold and release to avoid clicks
                gainNode.gain.setValueAtTime(gain, t);
                gainNode.gain.setValueAtTime(gain, t + note.d - 0.01);
                gainNode.gain.linearRampToValueAtTime(0.0001, t + note.d);
            } else {
                gainNode.gain.setValueAtTime(gain, t);
                gainNode.gain.exponentialRampToValueAtTime(0.001, t + note.d);
            }
            gainNode.connect(audioContext.destination);
            if (note.noise) {
                const buffer = audioContext.createBuffer(1, Math.ceil(audioContext.sampleRate * note.d), audioContext.sampleRate);
                const data = buffer.getChannelData(0);
                for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;
                const source = audioContext.createBufferSource();
                source.buffer = buffer;
                const filter = audioContext.createBiquadFilter();
                filter.type = 'bandpass';
                filter.frequency.value = note.f;
                filter.Q.value = note.q || 1;
                source.connect(filter);
                filter.connect(gainNode);
                source.start(t);
            } else {
                for (const f of (note.chord || [note.f])) {
                    const oscillator = audioContext.createOscillator();
                    oscillator.type = sound.wave;
                    oscillator.frequency.setValueAtTime(f, t);
                    if (note.f2) oscillator.frequency.exponentialRampToValueAtTime(note.f2, t + note.d);
                    oscillator.connect(gainNode);
                    oscillator.start(t);
                    oscillator.stop(t + note.d);
                }
            }
            t += note.d + (note.gap || 0);
        }
    },

});
