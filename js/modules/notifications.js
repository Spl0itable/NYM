// notifications.js - Notification history, badges, sounds, settings

const NYM_NOTIFICATION_ICON = 'https://nymchat.app/images/NYM-icon.png';

// Clamp to the stable first-seen time (observedAt), never Date.now(), so re-runs are idempotent.
function _clampNotifTs(timestamp, observedAt) {
    const ceiling = (typeof observedAt === 'number' && observedAt > 0)
        ? observedAt : Date.now();
    const ts = (typeof timestamp === 'number' && timestamp > 0) ? timestamp : ceiling;
    return ts > ceiling ? ceiling : ts;
}

const NYM_NOTIF_ROUTE_KEYS = ['type', 'pubkey', 'groupId', 'channel', 'geohash', 'sourceType', 'sourcePubkey', 'sourceGroupId', 'sourceChannel', 'sourceGeohash'];

function _nymNotifRoute(info, nym) {
    const r = {};
    for (const k of NYM_NOTIF_ROUTE_KEYS) {
        const v = info && info[k];
        if (typeof v === 'string' && v) r[k] = v;
    }
    if (nym) r.nym = nym;
    return r;
}

function _nymOpenRouteWhenReady(route, tries) {
    const n = typeof window !== 'undefined' ? window.nym : null;
    if (n && n.pubkey && typeof n._notifOpenRoute === 'function') {
        n._notifOpenRoute(route);
        return;
    }
    if (tries < 60) setTimeout(() => _nymOpenRouteWhenReady(route, tries + 1), 500);
}

if (typeof navigator !== 'undefined' && navigator.serviceWorker && typeof navigator.serviceWorker.addEventListener === 'function') {
    navigator.serviceWorker.addEventListener('message', (e) => {
        const d = e && e.data;
        if (!d || d.type !== 'nym-notification-click' || !d.route) return;
        _nymOpenRouteWhenReady(d.route, 0);
    });
}

Object.assign(NYM.prototype, {

    showNotification(title, body, channelInfo = null, timestamp = null) {
        const origBody = typeof body === 'string' ? body : '';
        const rawBody = this._notifCleanBody(body);
        body = this._notifPreviewText(rawBody);
        if (!this.notificationsEnabled) return;

        const baseTitle = this.parseNymFromDisplay(title);

        const senderPubkey = channelInfo?.pubkey || '';
        if (senderPubkey && this.blockedUsers.has(senderPubkey)) return;
        if (this._notifEntryHidden({ senderPubkey, body: origBody, channelInfo, title: baseTitle })) return;
        if (this.notifyFriendsOnly && senderPubkey && !this.isFriend(senderPubkey)) return;
        if (body && body.includes('10 recent messages:')) return;
        if (senderPubkey && this.isVerifiedBot(senderPubkey)) return;

        let titleToShow = baseTitle;
        if (channelInfo && channelInfo.pubkey) {
            const suffix = this.getPubkeySuffix(channelInfo.pubkey);
            titleToShow = `${baseTitle}#${suffix}`;
        }
        const lockedChat = typeof this._clNotifLocked === 'function' && this._clNotifLocked(channelInfo);
        if (lockedChat) {
            const redacted = this._clRedactText();
            titleToShow = redacted.title;
            body = redacted.body;
        }

        // Received time is both the viewed-cutoff and the stable clamp ceiling (see _clampNotifTs).
        const receivedAt = Date.now();
        const ts = _clampNotifTs(timestamp, receivedAt);
        const eventId = channelInfo?.eventId || '';

        // Live and replay paths can both call this for the same event.
        const isDupe = this._notifIsDupe({ eventId, title: titleToShow, body, sender: channelInfo?.pubkey || '', ts, exact: !!lockedChat });
        if (isDupe) {
            this._updateNotificationBadge();
            return;
        }

        const entry = {
            title: titleToShow,
            body: body,
            channelInfo: channelInfo,
            timestamp: ts,
            receivedAt,
            senderNym: lockedChat ? '' : baseTitle,
            senderPubkey: channelInfo?.pubkey || '',
            eventId: eventId || undefined
        };
        if (lockedChat) entry.locked = true;
        entry.live = true;
        const previouslySeen = this._isNotificationSeen(entry);
        const seenNow = this._notifSees(channelInfo);
        entry.viewed = previouslySeen
            || seenNow
            || receivedAt <= (this.notificationLastReadTime || 0)
            || this._notificationAlreadySeen(channelInfo, this._notifReadTs(entry), true);
        if (entry.viewed) this._rememberNotificationSeen(entry);
        if (seenNow) this._noteThreadRead(channelInfo, ts);
        this.notificationHistory.push(entry);
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        this.notificationHistory = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
        this._saveNotificationHistorySoon();
        this._updateNotificationBadge();
        this._refreshNotificationsModalIfOpen();
        if (typeof this._debouncedNostrSettingsSave === 'function') {
            this._debouncedNostrSettingsSave(8000);
        }

        if (entry.viewed) return;

        const toastDecision = typeof this._etConsider === 'function' ? this._etConsider(entry, false) : null;

        if (this.settings.sound !== 'none') {
            this.playSound(this.settings.sound);
        }

        if ((!toastDecision || toastDecision.system) && typeof Notification !== 'undefined' && Notification.permission === 'granted') {
            const route = channelInfo ? _nymNotifRoute(channelInfo, lockedChat || channelInfo.type !== 'pm' ? '' : (channelInfo.nym || baseTitle)) : null;
            const nymFilter = {
                sender: senderPubkey,
                body: lockedChat ? '' : origBody,
                channel: this._notifChannelKey(channelInfo),
                subject: channelInfo && typeof channelInfo.subject === 'string' ? channelInfo.subject : ''
            };
            this._notifSystemShow(this._notifSystemTitle(entry), {
                body: this._notifSystemBody(entry),
                icon: NYM_NOTIFICATION_ICON,
                tag: this._notifTag(channelInfo),
                renotify: true,
                requireInteraction: false,
                data: route ? { nymRoute: route } : {}
            }, route, nymFilter);
        }

    },

    _notifSyncedInfo(n) {
        if (!n || n.channelInfo) return null;
        const route = typeof n.route === 'string' ? n.route : '';
        const peer = /^[0-9a-f]{64}$/i.test(route);
        const inThread = typeof n.threadRoot === 'string' && !!n.threadRoot;
        switch (n.type) {
            case 'pm': return { type: 'pm', inThread };
            case 'group': return route ? { type: 'group', groupId: route, inThread } : null;
            case 'channel':
            case 'geohash': return route ? { type: 'geohash', geohash: route, inThread } : null;
            case 'mention': return route && !peer ? { type: 'geohash', geohash: route, inThread } : { type: 'mention' };
            case 'reaction': return { type: 'reaction' };
            case 'call': return { type: 'call', isGroup: !!route && !peer, groupId: route && !peer ? route : null };
            default: return null;
        }
    },

    _notifTag(info) {
        const i = info || {};
        if ((i.type === 'geohash' || i.type === 'channel') && (i.geohash || i.channel)) {
            return 'channel-' + String(i.geohash || i.channel).toLowerCase();
        }
        if (i.type === 'reaction') {
            const byGroup = i.sourceType === 'group' && i.sourceGroupId && !i.zapMessageId;
            const route = byGroup ? i.sourceGroupId : i.pubkey;
            if (route) return 'reaction-' + route;
        }
        return i.id || 'nym-notification';
    },

    _notifPreviewsHidden() {
        try { return localStorage.getItem('nym_hide_previews') === '1'; } catch (_) { return false; }
    },

    _notifSystemTitle(entry) {
        const E = typeof self !== 'undefined' ? self.NymEventToasts : null;
        if (!entry) return '';
        if (!E || typeof E.systemTitle !== 'function') return String(entry.title || '');
        const info = entry.channelInfo || {};
        const tr = (s, p) => (typeof this._etTr === 'function' ? this._etTr(s, p) : E.fill(s, p));
        return E.systemTitle({ title: entry.title, topic: E.topicOf(info.eventId || entry.eventId), locked: !!entry.locked }, { hidePreviews: this._notifPreviewsHidden() }, tr);
    },

    _notifSystemBody(entry) {
        if (entry && !entry.channelInfo) return String(entry.body || '');
        try {
            const shown = typeof this._etSystemBody === 'function' ? this._etSystemBody(entry) : null;
            if (typeof shown === 'string') return shown;
        } catch (_) { }
        let hidden = true;
        try { hidden = localStorage.getItem('nym_hide_previews') === '1'; } catch (_) { }
        return hidden && !entry.locked ? '' : entry.body;
    },

    _notifFilterHidden(f) {
        const F = window.NymContentFilter;
        if (!f || typeof f !== 'object' || !F || typeof this._cfCtx !== 'function') return false;
        const sender = typeof f.sender === 'string' ? f.sender : '';
        const nym = sender && typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(sender) : '';
        return F.entryHidden(this._cfCtx(), {
            sender,
            nym,
            body: typeof f.body === 'string' ? f.body : '',
            channel: typeof f.channel === 'string' ? f.channel : '',
            subject: typeof f.subject === 'string' ? f.subject : ''
        });
    },

    _closeHiddenSystemNotifications() {
        const byTag = this._notifTagFilters;
        const hidden = (n) => {
            if (!n) return false;
            const info = n._nymFilter || (byTag && n.tag ? byTag.get(n.tag) : null);
            if (info && this._notifFilterHidden(info)) return true;
            const r = n.data && n.data.nymRoute;
            if (!r || typeof r !== 'object') return false;
            return this._notifFilterHidden({ sender: r.type === 'pm' ? (r.pubkey || '') : '', channel: this._notifChannelKey(r) });
        };
        if (Array.isArray(this._postedNotifications)) {
            this._postedNotifications = this._postedNotifications.filter((n) => {
                if (!n || n._nymClosed) return false;
                if (!hidden(n)) return true;
                try { n.close(); } catch (_) { }
                return false;
            });
        }
        const sw = typeof navigator !== 'undefined' ? navigator.serviceWorker : null;
        if (!sw || typeof sw.getRegistration !== 'function') return;
        Promise.resolve()
            .then(() => sw.getRegistration())
            .then((reg) => (reg && typeof reg.getNotifications === 'function' ? reg.getNotifications() : []))
            .then((list) => {
                for (const n of list || []) {
                    if (hidden(n)) { try { n.close(); } catch (_) { } }
                }
            })
            .catch(() => { });
    },

    _notifSystemShow(title, opts, route, filterInfo) {
        if (filterInfo && opts && opts.tag) {
            if (!this._notifTagFilters) this._notifTagFilters = new Map();
            this._notifTagFilters.delete(opts.tag);
            this._notifTagFilters.set(opts.tag, filterInfo);
            if (this._notifTagFilters.size > 200) this._notifTagFilters.delete(this._notifTagFilters.keys().next().value);
        }
        const page = () => {
            try {
                const notification = new Notification(title, opts);
                if (filterInfo) notification._nymFilter = filterInfo;
                if (!Array.isArray(this._postedNotifications)) this._postedNotifications = [];
                this._postedNotifications.push(notification);
                if (this._postedNotifications.length > 50) this._postedNotifications.splice(0, this._postedNotifications.length - 50);
                try { notification.addEventListener && notification.addEventListener('close', () => { notification._nymClosed = true; }); } catch (_) { }
                if (route) {
                    notification.onclick = (event) => {
                        event.preventDefault();
                        window.focus();
                        this._notifOpenRoute(route);
                        notification.close();
                    };
                }
            } catch (_) { }
        };
        const sw = typeof navigator !== 'undefined' ? navigator.serviceWorker : null;
        if (!sw || typeof sw.getRegistration !== 'function') {
            page();
            return;
        }
        Promise.resolve()
            .then(() => sw.getRegistration())
            .then((reg) => {
                if (!reg || typeof reg.showNotification !== 'function') throw new Error('no registration');
                return reg.showNotification(title, opts);
            })
            .catch(page);
    },

    _notifOpenRoute(r) {
        if (!r || typeof r !== 'object') return;
        const nymOf = (pk) => (typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(pk) : '');
        if (r.type === 'pm') {
            this.openUserPM(r.nym || nymOf(r.pubkey), r.pubkey);
        } else if (r.type === 'group') {
            this.openGroup(r.groupId);
        } else if (r.type === 'geohash') {
            this.switchChannel(r.channel, r.geohash);
        } else if (r.type === 'reaction') {
            if (r.sourceType === 'pm' && r.sourcePubkey) {
                this.openUserPM(nymOf(r.sourcePubkey), r.sourcePubkey);
            } else if (r.sourceType === 'group' && r.sourceGroupId) {
                this.openGroup(r.sourceGroupId);
            } else if (r.sourceType === 'geohash' && r.sourceGeohash) {
                this.switchChannel(r.sourceChannel, r.sourceGeohash);
            }
        }
    },

    _notifCleanBody(body) {
        const F = window.NymContentFilter;
        if (typeof body !== 'string' || !F || typeof this._cfCtx !== 'function') return body;
        return F.stripBlockedQuotes(this._cfCtx(), body);
    },

    _notifChannelKey(info) {
        const i = info || {};
        if (i.type === 'geohash' || i.type === 'channel') return i.geohash || i.channel || '';
        if (i.sourceType === 'geohash' || i.sourceType === 'channel') return i.sourceGeohash || i.sourceChannel || '';
        return '';
    },

    _notifEntryHidden(entry) {
        const F = window.NymContentFilter;
        const e = entry || {};
        if (!F || typeof this._cfCtx !== 'function') {
            const pk = e.senderPubkey || (e.channelInfo && e.channelInfo.pubkey) || '';
            return !!(pk && this.blockedUsers && this.blockedUsers.has(pk));
        }
        const info = e.channelInfo || (typeof this._notifSyncedInfo === 'function' && this._notifSyncedInfo(e)) || {};
        const sender = e.senderPubkey || info.pubkey || '';
        const nym = sender && typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(sender) : '';
        return F.entryHidden(this._cfCtx(), {
            sender,
            nym,
            body: typeof e.body === 'string' ? e.body : '',
            channel: this._notifChannelKey(info) || (typeof e.channel === 'string' ? e.channel : ''),
            subject: typeof info.subject === 'string' ? info.subject : (typeof e.subject === 'string' ? e.subject : '')
        });
    },

    _addNotificationToHistory(title, body, channelInfo, timestamp) {
        const origBody = typeof body === 'string' ? body : '';
        const rawBody = this._notifCleanBody(body);
        body = this._notifPreviewText(rawBody);
        if (!this.notificationsEnabled) return;

        const baseTitle = this.parseNymFromDisplay(title);

        const senderPubkey = channelInfo?.pubkey || '';
        if (senderPubkey && this.blockedUsers.has(senderPubkey)) return;
        if (this._notifEntryHidden({ senderPubkey, body: origBody, channelInfo, title: baseTitle })) return;
        if (this.notifyFriendsOnly && senderPubkey && !this.isFriend(senderPubkey)) return;
        if (body && body.includes('10 recent messages:')) return;
        if (senderPubkey && this.isVerifiedBot(senderPubkey)) return;

        let titleToShow = baseTitle;
        if (channelInfo && channelInfo.pubkey) {
            const suffix = this.getPubkeySuffix(channelInfo.pubkey);
            titleToShow = `${baseTitle}#${suffix}`;
        }
        const lockedChat = typeof this._clNotifLocked === 'function' && this._clNotifLocked(channelInfo);
        if (lockedChat) {
            const redacted = this._clRedactText();
            titleToShow = redacted.title;
            body = redacted.body;
        }
        const receivedAt = Date.now();
        const ts = _clampNotifTs(timestamp, receivedAt);
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        if (ts < cutoff24h) return;
        const eventId = channelInfo?.eventId || '';
        const isDupe = this._notifIsDupe({ eventId, title: titleToShow, body, sender: channelInfo?.pubkey || '', ts, exact: !!lockedChat });
        if (isDupe) return;
        const entry = {
            title: titleToShow,
            body: body,
            channelInfo: channelInfo,
            timestamp: ts,
            receivedAt,
            senderNym: lockedChat ? '' : baseTitle,
            senderPubkey: channelInfo?.pubkey || '',
            eventId: eventId || undefined
        };
        if (lockedChat) entry.locked = true;
        entry.viewed = this._isNotificationSeen(entry)
            || receivedAt <= (this.notificationLastReadTime || 0)
            || this._notificationAlreadySeen(channelInfo, ts);
        if (entry.viewed) this._rememberNotificationSeen(entry);
        this.notificationHistory.push(entry);
        this.notificationHistory = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
        this._saveNotificationHistorySoon();
        this._updateNotificationBadge();
        this._refreshNotificationsModalIfOpen();
        if (!entry.viewed && typeof this._etConsider === 'function') this._etConsider(entry, true);
    },

    _notifIsDupe(a) {
        const V = typeof self !== 'undefined' ? self.NymNotifyView : null;
        return (this.notificationHistory || []).some(n => (V ? V.sameAlert(a, {
            eventId: n.eventId || '', title: n.title, body: n.body, sender: n.senderPubkey || '', ts: n.timestamp || 0
        }) : !!(a.eventId && n.eventId === a.eventId)));
    },

    _notifReadTs(n) {
        const V = typeof self !== 'undefined' ? self.NymNotifyView : null;
        return V ? V.readTs(n.timestamp || 0, n.receivedAt || 0, n.live === true) : (n.timestamp || 0);
    },

    _openNotificationTarget(n) {
        const info = n && n.channelInfo;
        if (!info) return;
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
        if (info.threadRoot && typeof this.openThreadFromNotification === 'function') {
            this.openThreadFromNotification(info);
        }
        this.closeNotificationsModal();
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

    _maybeRefreshZapNotif(messageId) {
        if (!messageId || !this.notificationHistory) return;
        const matches = this.notificationHistory.some(n =>
            n && n.channelInfo && n.channelInfo.zapMessageId === messageId);
        if (!matches) return;
        if (typeof this._refreshNotificationsModalIfOpen === 'function') {
            this._refreshNotificationsModalIfOpen();
        }
    },

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
        let preview = this._notifPreviewText(content.split('\n').filter(l => !l.startsWith('>')).join(' ').trim());
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
            // Clamp against each entry's own receivedAt; entries lacking it are left to age out.
            for (const n of parsed) {
                if (!n || typeof n.timestamp !== 'number') continue;
                if (typeof n.receivedAt !== 'number' || n.receivedAt <= 0) continue;
                n.timestamp = _clampNotifTs(n.timestamp, n.receivedAt);
            }
            return parsed.filter(n => n.timestamp > cutoff24h);
        } catch { return []; }
    },

    _saveNotificationHistorySoon() {
        if (typeof this._schedulePersist === 'function') {
            this._schedulePersist('nh', 'history', () => this._saveNotificationHistory());
            return;
        }
        this._saveNotificationHistory();
    },

    _saveNotificationHistory() {
        try {
            const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
            const recent = this.notificationHistory.filter(n => n.timestamp > cutoff24h);
            localStorage.setItem('nym_notification_history', JSON.stringify(recent));
        } catch { }
    },

    // Keyed by a stable identity so replayed/resynced events can't re-trigger the badge.
    _notificationSeenKey(n) {
        if (!n) return null;
        const evId = n.eventId || n.channelInfo?.eventId || '';
        if (evId) return `e:${evId}`;
        const pk = n.senderPubkey || n.channelInfo?.pubkey || '';
        const ts = n.timestamp || 0;
        if (!pk && !ts) return null;
        // Body prefix stays short of the 240-char sync truncation so local and synced keys match.
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

    _notifColumnOnScreen(c) {
        const strip = this._cvStrip;
        if (!c || !c.el || !strip || typeof c.el.getBoundingClientRect !== 'function') return false;
        const r = c.el.getBoundingClientRect();
        const s = strip.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && r.right > s.left && r.left < s.right;
    },

    _notifView(banner) {
        const focused = typeof document === 'undefined' || !document.hidden;
        const keys = [];
        if (this._cvActive && Array.isArray(this._cvColumns)) {
            for (const c of this._cvColumns) {
                if (!c || !c.key) continue;
                if (c.id === this._cvFocusedId || (banner === true && this._notifColumnOnScreen(c))) keys.push(c.key);
            }
        } else if (this.inPMMode) {
            if (this.currentGroup) keys.push(this.getGroupConversationKey(this.currentGroup));
            else if (this.currentPM) keys.push(this.getPMConversationKey(this.currentPM));
        } else {
            const k = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
            if (k) keys.push(k);
        }
        const at = this.activeThread;
        const threadsOn = typeof this.threadsEnabled !== 'function' || this.threadsEnabled();
        const thread = (threadsOn && at && at.rootId && at.ctx && at.ctx.storageKey &&
            this._threadContainer && keys.includes(at.ctx.storageKey))
            ? { key: at.ctx.storageKey, root: at.rootId } : null;
        return { focused, keys, thread };
    },

    _notifThreadRootOf(channelInfo) {
        if (!channelInfo || !channelInfo.threadRoot) return '';
        if (typeof this.threadsEnabled === 'function' && !this.threadsEnabled()) return '';
        return String(channelInfo.threadRoot);
    },

    _notifEvent(channelInfo) {
        const key = this._notificationConvKey(channelInfo) || '';
        let root = this._notifThreadRootOf(channelInfo);
        if (root && key && typeof this.threadKeyForMessage === 'function') {
            const list = key.startsWith('pm-') || key.startsWith('group-')
                ? (this.pmMessages && this.pmMessages.get(key))
                : (this.messages && this.messages.get(key));
            const known = Array.isArray(list) && list.some(m => m && !m.threadRoot && this.threadKeyForMessage(m) === root);
            if (!known) root = '';
        }
        return { key, root };
    },

    _notifSees(channelInfo, banner) {
        const V = typeof self !== 'undefined' ? self.NymNotifyView : null;
        if (!V || !channelInfo) return false;
        return V.sees(this._notifView(banner === true), this._notifEvent(channelInfo));
    },

    _threadReadKey(convKey, root) {
        return `${convKey}|${root}`;
    },

    _loadThreadLastRead() {
        const map = new Map();
        try {
            const raw = localStorage.getItem('nym_thread_last_read');
            const parsed = raw ? JSON.parse(raw) : null;
            const cutoff = Math.floor(Date.now() / 1000) - 48 * 60 * 60;
            if (parsed && typeof parsed === 'object') {
                for (const [k, v] of Object.entries(parsed)) {
                    if (typeof v === 'number' && v > cutoff) map.set(k, v);
                }
            }
        } catch (_) { }
        return map;
    },

    _threadLastReadMap() {
        if (!this.threadLastRead) this.threadLastRead = this._loadThreadLastRead();
        return this.threadLastRead;
    },

    _setThreadLastRead(convKey, root, tsSec) {
        if (!convKey || !root) return false;
        const map = this._threadLastReadMap();
        const k = this._threadReadKey(convKey, root);
        if ((map.get(k) || 0) >= tsSec) return false;
        map.set(k, tsSec);
        if (map.size > 500) {
            const newest = [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, 500);
            this.threadLastRead = new Map(newest);
        }
        try { localStorage.setItem('nym_thread_last_read', JSON.stringify(Object.fromEntries(this.threadLastRead))); } catch (_) { }
        if (typeof this._syncReadStateToD1 === 'function') this._syncReadStateToD1();
        return true;
    },

    _noteThreadRead(channelInfo, tsMs) {
        const root = this._notifThreadRootOf(channelInfo);
        const key = this._notificationConvKey(channelInfo);
        if (!root || !key) return;
        const sec = Math.max(Math.floor((tsMs || 0) / 1000), Math.floor(Date.now() / 1000));
        this._setThreadLastRead(key, root, sec);
    },

    _markThreadNotificationsSeen(convKey, root) {
        if (!convKey || !root) return;
        const nowSec = Math.floor(Date.now() / 1000);
        this._setThreadLastRead(convKey, root, nowSec);
        let changed = false;
        for (const n of (this.notificationHistory || [])) {
            if (!n || n.viewed) continue;
            if (this._notifThreadRootOf(n.channelInfo) !== root) continue;
            if (this._notificationConvKey(n.channelInfo) !== convKey) continue;
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
        if (typeof this._refreshThreadNewMarks === 'function') this._refreshThreadNewMarks();
    },

    _threadHasUnreadNotif(convKey, root) {
        if (!convKey || !root) return false;
        return this._unreadNotifications().some(n =>
            this._notifThreadRootOf(n.channelInfo) === root &&
            this._notificationConvKey(n.channelInfo) === convKey);
    },

    _notificationAlreadySeen(channelInfo, tsMs, live) {
        const { key, root } = this._notifEvent(channelInfo);
        const sec = Math.floor((tsMs || 0) / 1000);
        const before = (t) => (live === true ? sec < t : sec <= t);
        if (key && root) {
            const t = this._threadLastReadMap().get(this._threadReadKey(key, root)) || 0;
            return !!t && before(t);
        }
        if (!key || !this.channelLastRead) return false;
        const seen = this.channelLastRead.get(key) || 0;
        if (!seen) return false;
        return before(seen);
    },

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

    _markConversationNotificationsSeen(convKey, tsSec) {
        if (!convKey) return;
        const V = typeof self !== 'undefined' ? self.NymNotifyView : null;
        const view = this._notifView();
        if (view.focused && view.thread && view.thread.key === convKey) {
            this._setThreadLastRead(convKey, view.thread.root, tsSec);
        }
        if (!Array.isArray(this.notificationHistory) || !this.notificationHistory.length) return;
        let changed = false;
        for (const n of this.notificationHistory) {
            if (n.viewed) continue;
            if (this._notificationConvKey(n.channelInfo) !== convKey) continue;
            const root = this._notifEvent(n.channelInfo).root;
            if (root && !(V && V.sees(view, { key: convKey, root }))) continue;
            if (Math.floor(this._notifReadTs(n) / 1000) > tsSec) continue;
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
        this._scheduleAppBadge();
        // Coalesce burst calls into a single DOM update per animation frame.
        if (this._notifBadgeRafPending) return;
        this._notifBadgeRafPending = true;
        const raf = window.requestAnimationFrame || (cb => setTimeout(cb, 16));
        raf(() => {
            this._notifBadgeRafPending = false;
            this._doUpdateNotificationBadge();
        });
    },

    _unreadNotifications() {
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        const lastRead = this.notificationLastReadTime || 0;
        return (this.notificationHistory || []).filter(n => {
            if (n.timestamp <= cutoff24h) return false;
            if (n.viewed === true) return false;
            const observedAt = n.receivedAt || n.timestamp || 0;
            if (observedAt <= lastRead) return false;
            if (this._notificationAlreadySeen(n.channelInfo, this._notifReadTs(n), n.live === true)) return false;
            if (this._notifEntryHidden(n)) return false;
            return true;
        });
    },

    _appBadgeCount() {
        if (!this.notificationsEnabled) return 0;
        return this._unreadNotifications().length;
    },

    _scheduleAppBadge() {
        if (typeof document !== 'undefined' && document.hidden) {
            if (this._appBadgeQueued) return;
            this._appBadgeQueued = true;
            Promise.resolve().then(() => {
                this._appBadgeQueued = false;
                this._applyAppBadge();
            });
            return;
        }
        if (this._appBadgeTimer) return;
        this._appBadgeTimer = setTimeout(() => {
            this._appBadgeTimer = null;
            this._applyAppBadge();
        }, 250);
    },

    _applyAppBadge() {
        if (this._readStateKnown === false) return;
        let count = 0;
        try { count = this._appBadgeCount(); } catch (_) { return; }
        this._renderBellCount(count);
        this._applyTitleCount(count);
        if (count === this._appBadgeShown) return;
        this._appBadgeShown = count;
        this._sendAppBadge(count);
    },

    _applyTitleCount(count) {
        if (typeof document === 'undefined') return;
        const base = String(document.title || '').replace(/^\(\d+\+?\) /, '');
        const next = count > 0 ? `(${count > 99 ? '99+' : count}) ${base}` : base;
        if (document.title !== next) document.title = next;
    },

    _sendAppBadge(count) {
        const nav = typeof navigator !== 'undefined' ? navigator : null;
        if (!nav || typeof nav.setAppBadge !== 'function' || typeof nav.clearAppBadge !== 'function') return;
        try {
            const done = count > 0 ? nav.setAppBadge(count) : nav.clearAppBadge();
            if (done && typeof done.catch === 'function') done.catch(() => { });
        } catch (_) { }
    },

    _resetAppBadge() {
        this._appBadgeShown = 0;
        this._applyTitleCount(0);
        this._sendAppBadge(0);
    },

    _doUpdateNotificationBadge() {
        if (typeof this._refreshThreadNewMarks === 'function') this._refreshThreadNewMarks();
        this._renderBellCount(this._appBadgeCount());
    },

    _renderBellCount(count) {
        if (typeof document === 'undefined') return;
        for (const id of ['notifBadgeDesktop', 'notifBadgeMobile', 'notifBadgeSidebar', 'notifBadgeIdentity']) {
            const badge = document.getElementById(id);
            if (!badge) continue;
            if (count > 0) {
                badge.textContent = count > 99 ? '99+' : count;
                badge.classList.remove('nm-hidden');
            } else {
                badge.classList.add('nm-hidden');
            }
        }
    },

    openNotificationsModal() {
        const modal = document.getElementById('notificationsModal');
        const body = document.getElementById('notificationsModalBody');
        if (!modal || !body) return;

        const checkbox = document.getElementById('enableNotificationsCheckbox');
        if (checkbox) checkbox.checked = this.notificationsEnabled;
        const mentionsCheckbox = document.getElementById('groupMentionsOnlyCheckbox');
        if (mentionsCheckbox) mentionsCheckbox.checked = this.groupNotifyMentionsOnly;
        const threadMentionsCheckbox = document.getElementById('threadMentionsOnlyCheckbox');
        if (threadMentionsCheckbox) threadMentionsCheckbox.checked = this.threadNotifyMentionsOnly;
        const friendsOnlyCheckbox = document.getElementById('notifyFriendsOnlyCheckbox');
        if (friendsOnlyCheckbox) friendsOnlyCheckbox.checked = this.notifyFriendsOnly;
        const notifSound = document.getElementById('notifSoundSelect');
        const settingsSound = document.getElementById('soundSelect');
        if (notifSound) {
            if (settingsSound && notifSound.options.length !== settingsSound.options.length) notifSound.innerHTML = settingsSound.innerHTML;
            notifSound.value = this.settings.sound;
        }

        // Sort ascending since replay and sync merges can leave the array out of order.
        const cutoff24h = Date.now() - 24 * 60 * 60 * 1000;
        const recent = this.notificationHistory.filter(n => {
            if (n.timestamp <= cutoff24h) return false;
            if (this._notifEntryHidden(n)) return false;
            return true;
        }).sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));

        const markAllBtn = document.getElementById('markAllNotificationsReadBtn');
        if (markAllBtn) markAllBtn.classList.toggle('nm-hidden', !recent.some(n => !n.viewed));

        if (recent.length === 0) {
            body.innerHTML = '<div class="notifications-empty">No notifications in the last 24 hours</div>';
        } else {
            // Fetch missing kind 0 profiles; the kind 0 handler refreshes the open modal in place.
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
            const ET = typeof self !== 'undefined' ? self.NymEventToasts : null;
            const hidePreviews = this._notifPreviewsHidden();
            const etTr = (s, p) => (typeof this._etTr === 'function' ? this._etTr(s, p) : (ET ? ET.fill(s, p) : s));
            const groupName = (id) => {
                const g = id && this.groupConversations && this.groupConversations.get(id);
                return g ? (typeof this._groupLabel === 'function' ? this._groupLabel(g) : (g.name || 'Group')) : this.uiText('Group');
            };
            for (let i = recent.length - 1; i >= 0; i--) {
                const n = recent[i];
                const info = n.channelInfo || this._notifSyncedInfo(n);
                const system = !n.channelInfo && !n.senderPubkey && !n.eventId && !n.route;
                const item = document.createElement('div');
                item.className = 'notification-item';
                item._notif = n;
                if (!n.viewed) item.classList.add('notification-item-unread');
                if (n.channelInfo) item.style.cursor = 'pointer';
                const dt = new Date(n.timestamp);
                const time = dt.toLocaleString([], {
                    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
                    hour12: this.settings.timeFormat === '12hr'
                });

                const hiddenChat = typeof this._clNotifHidden === 'function' && this._clNotifHidden(n);
                const pubkey = hiddenChat ? '' : (n.senderPubkey || n.channelInfo?.pubkey || '');
                const topic = ET ? ET.entryTopic(n.channelInfo?.eventId || n.eventId, n.title, etTr) : '';
                const textHidden = hidePreviews && !hiddenChat && !system;
                const shownTitle = (t) => (ET ? ET.systemTitle({ title: t, topic }, { hidePreviews }, etTr) : String(t || ''));
                let avatarHtml = '';
                let authorHtml = '';
                if (hiddenChat) {
                    authorHtml = `<span class="notification-item-author">${this.escapeHtml(this._clRedactText().title)}</span>`;
                } else if (pubkey) {
                    const avatarSrc = this.getAvatarUrl(pubkey);
                    const safePk = this._safePubkey(pubkey);
                    avatarHtml = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy">`;
                    const baseNym = this.resolveDisplayNym(pubkey, shownTitle(n.senderNym || ''));
                    const suffix = this.getPubkeySuffix(pubkey);
                    const flairHtml = this.getFlairForUser(pubkey);
                    const verifiedBadge = this.isVerifiedDeveloper(pubkey)
                        ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
                        : this.isVerifiedBot(pubkey)
                            ? '<span class="verified-badge" title="Nymchat Bot">✓</span>'
                            : '';
                    authorHtml = `<span class="notification-item-author" data-notif-pubkey="${this.escapeHtml(pubkey)}"><span class="nym-bracket">&lt;</span>${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span><span class="nym-bracket">&gt;</span>${flairHtml} ${verifiedBadge}</span>`;
                } else if (n.title) {
                    authorHtml = `<span class="notification-item-author"><span class="nym-bracket">&lt;</span>${this.escapeHtml(shownTitle(n.title))}<span class="nym-bracket">&gt;</span></span>`;
                }

                let contextHtml = '';
                if (hiddenChat) {
                    contextHtml = `<span class="notification-item-context">${this.escapeHtml(this._cl(window.NymChatLock.STRINGS.lockedChats))}</span>`;
                } else if (info) {
                    const inThread = !!info.inThread;
                    if (info.type === 'geohash') {
                        const where = `#${this.escapeHtml(info.geohash)}`;
                        contextHtml = inThread
                            ? `<span class="notification-item-context">in a thread in ${where}</span>`
                            : `<span class="notification-item-context">in ${where}</span>`;
                    } else if (info.type === 'group') {
                        const where = this.escapeHtml(groupName(info.groupId || String(info.id || '').replace(/^group-/, '')));
                        contextHtml = inThread
                            ? `<span class="notification-item-context">in a thread in ${where}</span>`
                            : `<span class="notification-item-context">in ${where}</span>`;
                    } else if (info.type === 'pm') {
                        const dmLabel = this.escapeHtml(this.uiText(inThread ? 'Private message thread' : 'Private message'));
                        contextHtml = `<span class="notification-item-context">${dmLabel}</span>`;
                    } else if (info.type === 'reaction') {
                        const zap = !!info.zapMessageId || String(n.body || '').trim().indexOf('⚡') === 0;
                        contextHtml = `<span class="notification-item-context">${this.escapeHtml(this.uiText(zap ? 'Zap' : 'Reaction'))}</span>`;
                    } else if (info.type === 'mention') {
                        contextHtml = `<span class="notification-item-context">${this.escapeHtml(this.uiText('Mention'))}</span>`;
                    } else if (info.type === 'call' && ET) {
                        const evId = String(info.eventId || n.eventId || '');
                        const label = ET.callLabel({
                            topic,
                            missed: evId.indexOf('missed-call-') === 0,
                            video: info.callKind ? info.callKind === 'video' : ET.callIsVideo(n.body, etTr),
                            chat: textHidden && info.isGroup && info.groupId ? groupName(info.groupId) : '',
                        }, etTr);
                        contextHtml = `<span class="notification-item-context">${this.escapeHtml(label)}</span>`;
                    }
                }

                let rawBody = hiddenChat ? this._clRedactText().body : (n.body || '');

                if (!hiddenChat && n.channelInfo && n.channelInfo.zapMessageId) {
                    const enriched = this._enrichZapBody(n.channelInfo.zapMessageId, n.channelInfo.zapSats);
                    if (enriched) rawBody = enriched;
                }

                const newMessageLines = this._notifPreviewText(rawBody).split('\n').filter(line => !line.startsWith('>'));
                let displayBody = newMessageLines.join(' ').replace(/\s+/g, ' ').trim().slice(0, 200);
                if (!hiddenChat && hidePreviews) {
                    displayBody = ET ? ET.listBody({ body: displayBody, viewOnce: ET.isViewOnce(displayBody, etTr), system }, { hidePreviews }, etTr) : (system ? displayBody : '');
                }
                const bodyHtml = displayBody || !hidePreviews
                    ? `<div class="notification-item-body">${this.renderCustomEmojiInEscapedText((pubkey && this.isVerifiedBot(pubkey) ? window.NymSuffix.dimHtml(this.escapeHtml(displayBody), '*') : this.nymTextHtml(displayBody, pubkey ? [pubkey] : [])))}</div>`
                    : '';

                item.innerHTML = `
                    <div class="notification-item-header">
                        ${avatarHtml}
                        <div class="notification-item-meta">
                            <div class="notification-item-title">${authorHtml}</div>
                            ${bodyHtml}
                            <div class="notification-item-footer">${contextHtml} <span class="notification-item-time">${time}</span></div>
                        </div>
                    </div>
                `;
                if (n.channelInfo) {
                    item.onclick = () => this._openNotificationTarget(n);
                }
                body.appendChild(item);
            }
        }

        modal.classList.add('active');
        this._setupNotificationSeenObserver(body);
    },

    // Mark viewed as items scroll into view so the badge deducts per item.
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

    updateNotificationModalProfile(pubkey, profileName) {
        const modal = document.getElementById('notificationsModal');
        if (!modal || !modal.classList.contains('active')) return;
        const baseNym = this.resolveDisplayNym(pubkey, profileName || '').substring(0, 20);
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

    // Notes: f Hz, d seconds, f2 glide target, gap silence after, chord simultaneous, g gain, a attack, noise+q.
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
        // Exact APU frequencies from the SMB sound engine data (PowerUpGrabFreqData).
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
        // Exact Game Boy frequencies from the pokered disassembly (Music_PkmnHealed_Ch2).
        pokeheal: {
            wave: 'square', gain: 0.06,
            notes: [
                { f: 985.5, d: 0.45 }, { f: 985.5, d: 0.45 }, { f: 985.5, d: 0.23 },
                { f: 829.6, d: 0.23 }, { f: 1310.7, d: 0.9 }
            ]
        },
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

    _soundContext() {
        const AC = typeof window !== 'undefined' ? (window.AudioContext || window.webkitAudioContext) : null;
        if (!AC) return null;
        let c = this._audioCtx;
        if (!c || c.state === 'closed') {
            try { c = new AC(); } catch (_) { return null; }
            this._audioCtx = c;
            this._soundArmResume();
        }
        this._soundResume();
        return c;
    },

    _soundResume() {
        const c = this._audioCtx;
        if (!c || c.state !== 'suspended' || typeof c.resume !== 'function') return;
        try {
            const p = c.resume();
            if (p && typeof p.catch === 'function') p.catch(() => { });
        } catch (_) { }
    },

    _soundArmResume() {
        if (this._soundResumeArmed || typeof document === 'undefined' || typeof document.addEventListener !== 'function') return;
        this._soundResumeArmed = true;
        const wake = () => this._soundResume();
        for (const t of ['pointerdown', 'keydown', 'touchend']) document.addEventListener(t, wake, { capture: true, passive: true });
    },

    playSound(type) {
        const now = Date.now();
        if (this._lastSoundPlayedAt && now - this._lastSoundPlayedAt < 2000) return;
        this._lastSoundPlayedAt = now;

        // Legacy values from before the sounds were relabeled.
        const legacy = { icq: 'uhoh', msn: 'msnding' };
        const sound = this.NOTIFICATION_SOUNDS[legacy[type] || type];
        if (!sound) return;

        const audioContext = this._soundContext();
        if (!audioContext) return;
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
                // Too short for a decay envelope; hold and release to avoid clicks.
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
