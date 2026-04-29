// notifications.js - Notification history, badges, sounds, settings
// Methods are attached to NYM.prototype.

Object.assign(NYM.prototype, {

    showNotification(title, body, channelInfo = null) {
        if (!this.notificationsEnabled) return;

        const baseTitle = this.parseNymFromDisplay(title);

        // Skip notifications from blocked users
        const senderPubkey = channelInfo?.pubkey || '';
        if (senderPubkey && this.blockedUsers.has(senderPubkey)) return;
        if (this.isNymBlocked(baseTitle)) return;

        // Skip notifications from non-friends if friends-only is enabled
        if (this.notifyFriendsOnly && senderPubkey && !this.isFriend(senderPubkey)) return;

        // Skip bot digest messages that mass-mention users
        if (body && body.includes('10 recent messages:')) return;

        // Skip Nymbot quote-reply notifications (bot quotes user's message with @mention)
        if (senderPubkey && this.isVerifiedBot(senderPubkey)) return;

        // If this is a PM notification (we have a pubkey), append plain suffix for readability
        let titleToShow = baseTitle;
        if (channelInfo && channelInfo.pubkey) {
            const suffix = this.getPubkeySuffix(channelInfo.pubkey);
            titleToShow = `${baseTitle}#${suffix}`;
        }

        // Track notification in history for the notifications modal
        this.notificationHistory.push({
            title: titleToShow,
            body: body,
            channelInfo: channelInfo,
            timestamp: Date.now(),
            senderNym: baseTitle,
            senderPubkey: channelInfo?.pubkey || ''
        });
        // Prune notifications older than 24 hours and persist
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        this.notificationHistory = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
        this._saveNotificationHistory();
        this._updateNotificationBadge();

        // Sound
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
    // Used for historical messages from relays that match notification criteria.
    _addNotificationToHistory(title, body, channelInfo, timestamp) {
        if (!this.notificationsEnabled) return;

        const baseTitle = this.parseNymFromDisplay(title);

        // Skip notifications from blocked users
        const senderPubkey = channelInfo?.pubkey || '';
        if (senderPubkey && this.blockedUsers.has(senderPubkey)) return;
        if (this.isNymBlocked(baseTitle)) return;

        // Skip notifications from non-friends if friends-only is enabled
        if (this.notifyFriendsOnly && senderPubkey && !this.isFriend(senderPubkey)) return;

        // Skip bot digest messages that mass-mention users
        if (body && body.includes('10 recent messages:')) return;

        // Skip Nymbot quote-reply notifications (bot quotes user's message with @mention)
        if (senderPubkey && this.isVerifiedBot(senderPubkey)) return;

        let titleToShow = baseTitle;
        if (channelInfo && channelInfo.pubkey) {
            const suffix = this.getPubkeySuffix(channelInfo.pubkey);
            titleToShow = `${baseTitle}#${suffix}`;
        }
        const ts = timestamp || Date.now();
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        // Only track if within the last 24 hours
        if (ts < cutoff24h) return;
        // Deduplicate by checking for same title + body + similar timestamp
        const isDupe = this.notificationHistory.some(
            n => n.title === titleToShow && n.body === body && Math.abs(n.timestamp - ts) < 2000
        );
        if (isDupe) return;
        this.notificationHistory.push({
            title: titleToShow,
            body: body,
            channelInfo: channelInfo,
            timestamp: ts,
            senderNym: baseTitle,
            senderPubkey: channelInfo?.pubkey || ''
        });
        this.notificationHistory = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
        this._saveNotificationHistory();
        // Historical notifications are silently recorded – advance lastReadTime
        // so they never retrigger the unread badge on reload.
        if (ts > this.notificationLastReadTime) {
            this.notificationLastReadTime = ts;
            try { localStorage.setItem('nym_notification_last_read', String(ts)); } catch { }
        }
    },

    _loadNotificationHistory() {
        try {
            const raw = localStorage.getItem('nym_notification_history');
            if (!raw) return [];
            const parsed = JSON.parse(raw);
            const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
            const filtered = [];
            let maxTs = 0;
            for (let i = 0; i < parsed.length; i++) {
                const n = parsed[i];
                if (n.timestamp > cutoff24h) {
                    filtered.push(n);
                    if (n.timestamp > maxTs) maxTs = n.timestamp;
                }
            }
            // Mark all persisted notifications as already seen so they don't
            // retrigger the unread badge on reload. Advance lastReadTime to
            // cover every entry that was already stored.
            if (filtered.length > 0) {
                const stored = parseInt(localStorage.getItem('nym_notification_last_read') || '0');
                if (maxTs > stored) {
                    this.notificationLastReadTime = maxTs;
                    try { localStorage.setItem('nym_notification_last_read', String(maxTs)); } catch { }
                }
            }
            return filtered;
        } catch { return []; }
    },

    _saveNotificationHistory() {
        try {
            const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
            const recent = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
            localStorage.setItem('nym_notification_history', JSON.stringify(recent));
        } catch { }
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
                if (badge) badge.style.display = 'none';
            });
            return;
        }

        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        const unreadCount = this.notificationHistory.filter(n => {
            if (n.timestamp <= cutoff24h || n.timestamp <= this.notificationLastReadTime) return false;
            const pubkey = n.senderPubkey || n.channelInfo?.pubkey || '';
            if (pubkey && this.blockedUsers.has(pubkey)) return false;
            if (n.senderNym && this.isNymBlocked(n.senderNym)) return false;
            return true;
        }).length;

        [desktopBadge, mobileBadge].forEach(badge => {
            if (!badge) return;
            if (unreadCount > 0) {
                badge.textContent = unreadCount > 99 ? '99+' : unreadCount;
                badge.style.display = '';
            } else {
                badge.style.display = 'none';
            }
        });
    },

    openNotificationsModal() {
        // Mark all as read
        this.notificationLastReadTime = Date.now();
        try { localStorage.setItem('nym_notification_last_read', String(this.notificationLastReadTime)); } catch { }
        this._updateNotificationBadge();

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

        // Filter to last 24 hours and exclude blocked users
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        const recent = this.notificationHistory.filter(n => {
            if (n.timestamp <= cutoff24h) return false;
            const pubkey = n.senderPubkey || n.channelInfo?.pubkey || '';
            if (pubkey && this.blockedUsers.has(pubkey)) return false;
            if (n.senderNym && this.isNymBlocked(n.senderNym)) return false;
            return true;
        });

        if (recent.length === 0) {
            body.innerHTML = '<div class="notifications-empty">No notifications in the last 24 hours</div>';
        } else {
            body.innerHTML = '';
            // Show newest first
            for (let i = recent.length - 1; i >= 0; i--) {
                const n = recent[i];
                const item = document.createElement('div');
                item.className = 'notification-item';
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
                    avatarHtml = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${safePk}.png?set=set1&size=80x80'">`;
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
                    authorHtml = `<span class="notification-item-author">&lt;${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>&gt;${flairHtml} ${verifiedBadge}</span>`;
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
                    }
                }

                // Strip quoted lines (> prefixed) to show only the new message
                const rawBody = n.body || '';
                const newMessageLines = rawBody.split('\n').filter(line => !line.startsWith('>'));
                const displayBody = newMessageLines.join(' ').replace(/\s+/g, ' ').trim().slice(0, 200);

                item.innerHTML = `
                    <div class="notification-item-header">
                        ${avatarHtml}
                        <div class="notification-item-meta">
                            <div class="notification-item-title">${authorHtml}</div>
                            <div class="notification-item-body">${this.escapeHtml(displayBody)}</div>
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
                        }
                        this.closeNotificationsModal();
                    };
                }
                body.appendChild(item);
            }
        }

        modal.classList.add('active');
    },

    closeNotificationsModal() {
        const modal = document.getElementById('notificationsModal');
        if (modal) {
            modal.classList.remove('active');
            modal.style.display = '';
        }
    },

    playSound(type) {
        // Deduplicate: don't replay within 2 seconds
        const now = Date.now();
        if (this._lastSoundPlayedAt && now - this._lastSoundPlayedAt < 2000) return;
        this._lastSoundPlayedAt = now;

        const audioContext = new (window.AudioContext || window.webkitAudioContext)();
        const oscillator = audioContext.createOscillator();
        const gainNode = audioContext.createGain();

        oscillator.connect(gainNode);
        gainNode.connect(audioContext.destination);

        switch (type) {
            case 'beep':
                oscillator.frequency.value = 800;
                gainNode.gain.value = 0.1;
                break;
            case 'icq':
                oscillator.frequency.value = 600;
                gainNode.gain.value = 0.15;
                break;
            case 'msn':
                oscillator.frequency.value = 1000;
                gainNode.gain.value = 0.1;
                break;
        }

        oscillator.start();
        oscillator.stop(audioContext.currentTime + 0.1);
    },

});
