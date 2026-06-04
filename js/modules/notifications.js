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
        this.notificationHistory.push({
            title: titleToShow,
            body: body,
            channelInfo: channelInfo,
            timestamp: ts,
            receivedAt,
            senderNym: baseTitle,
            senderPubkey: channelInfo?.pubkey || '',
            eventId: eventId || undefined,
            viewed: receivedAt <= (this.notificationLastReadTime || 0)
                || this._notificationAlreadySeen(channelInfo, ts)
        });
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        this.notificationHistory = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
        this._saveNotificationHistory();
        this._updateNotificationBadge();
        this._refreshNotificationsModalIfOpen();
        if (typeof this._debouncedNostrSettingsSave === 'function') {
            this._debouncedNostrSettingsSave(8000);
        }

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
        this.notificationHistory.push({
            title: titleToShow,
            body: body,
            channelInfo: channelInfo,
            timestamp: ts,
            receivedAt,
            senderNym: baseTitle,
            senderPubkey: channelInfo?.pubkey || '',
            eventId: eventId || undefined,
            viewed: receivedAt <= (this.notificationLastReadTime || 0)
                || this._notificationAlreadySeen(channelInfo, ts)
        });
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
            changed = true;
        }
        if (changed) {
            this._saveNotificationHistory();
            this._updateNotificationBadge();
            this._refreshNotificationsModalIfOpen();
            if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(4000);
        }
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

        if (recent.length === 0) {
            body.innerHTML = '<div class="notifications-empty">No notifications in the last 24 hours</div>';
        } else {
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
                    avatarHtml = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" loading="lazy">`;
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
                    changed = true;
                    el.classList.remove('notification-item-unread');
                }
            }
            if (changed) {
                if (typeof this._saveNotificationHistory === 'function') this._saveNotificationHistory();
                this._updateNotificationBadge();
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
