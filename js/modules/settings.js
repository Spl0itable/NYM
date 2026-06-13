// settings.js - User settings: load/save, sync to Nostr, theme/color mode, image blur

const INDICATOR_SCOPES = ['disabled', 'pms', 'groups', 'pms-groups', 'everywhere'];

// Maps core settings keys to the settings-modal section that owns them, used to
// split the synced settings into smaller per-section gift wraps. Unmapped keys
// fall through to a "misc" section so future settings still sync.
const NYM_SETTINGS_SECTION_KEYS = {
    appearance: ['theme', 'sound', 'autoscroll', 'showTimestamps', 'timeFormat', 'dateFormat',
        'blurOthersImages', 'chatLayout', 'chatViewMode', 'columnsLayout', 'nickStyle', 'colorMode',
        'wallpaperType', 'wallpaperCustomUrl', 'textSize', 'transparencyEnabled', 'columnsWallpaper', 'sidebarSectionOrder'],
    privacy: ['blockedUsers', 'friends', 'blockedKeywords', 'blockedChannels', 'hiddenChannels',
        'lightningAddress', 'dmForwardSecrecyEnabled', 'dmTTLSeconds', 'readReceiptsEnabled',
        'readReceiptsScope', 'typingIndicatorsEnabled', 'typingIndicatorsScope', 'acceptPMs',
        'acceptCalls', 'showStatus', 'powDifficulty', 'encryptAtRestPreferred', 'keypairMode'],
    messaging: ['groupChatPMOnlyMode', 'translateLanguage', 'translateFavoriteLanguages',
        'emojiPackFavorites', 'emojiCategoryFavorites', 'favoriteGifs', 'recentEmojis',
        'gesturesEnabled', 'swipeLeftAction', 'swipeRightAction', 'swipeThreshold',
        'swipeReactEmoji', 'notificationsEnabled', 'groupNotifyMentionsOnly', 'notifyFriendsOnly',
        'syncMLSHistory', 'seenCalls'],
    channels: ['pinnedChannels', 'userJoinedChannels', 'sortByProximity', 'pinnedLandingChannel',
        'hideNonPinned', 'channelLastRead', 'closedPMs', 'leftGroups', 'closedPMTimes',
        'leftGroupTimes'],
    data: ['lowDataMode', 'cachePMs', 'tutorialSeen', 'botPmWelcomed', 'botPmClearedAt']
};

function _normalizeIndicatorScope(value, fallback = 'pms-groups') {
    if (value === true || value === 'true') return 'everywhere';
    if (value === false || value === 'false') return 'disabled';
    if (typeof value === 'string' && INDICATOR_SCOPES.includes(value)) return value;
    return fallback;
}

Object.assign(NYM.prototype, {

    isIndicatorAllowedFor(scope, context) {
        const s = _normalizeIndicatorScope(scope);
        if (s === 'disabled') return false;
        if (s === 'everywhere') return true;
        if (s === 'pms') return context === 'pm';
        if (s === 'groups') return context === 'group';
        if (s === 'pms-groups') return context === 'pm' || context === 'group';
        return true;
    },

    isReadReceiptAllowedFor(context) {
        return this.isIndicatorAllowedFor(this.settings?.readReceiptsScope, context);
    },

    isTypingIndicatorAllowedFor(context) {
        return this.isIndicatorAllowedFor(this.settings?.typingIndicatorsScope, context);
    },

    async saveSyncedSettings() {
        if (!this.pubkey) return;

        // Skip sync for hardcore mode (keypair changes every message) and random-per-session
        if (this.connectionMode === 'ephemeral') {
            const keypairMode = localStorage.getItem('nym_keypair_mode') || (localStorage.getItem('nym_random_keypair_per_session') === 'true' ? 'random' : 'persistent');
            if (keypairMode === 'random' || keypairMode === 'hardcore') return;
        }

        try {
            await this._publishEncryptedSettings(this._buildSettingsPayload());
        } catch (error) {
        }
    },

    _serialiseNotificationsForSync() {
        try {
            if (!Array.isArray(this.notificationHistory) || this.notificationHistory.length === 0) return [];
            const cutoff = Date.now() - 24 * 60 * 60 * 1000;
            return this.notificationHistory
                .filter(n => n && n.timestamp > cutoff)
                .slice(-100)
                .map(n => ({
                    title: n.title,
                    body: typeof n.body === 'string' ? n.body.slice(0, 240) : '',
                    timestamp: n.timestamp,
                    receivedAt: (typeof n.receivedAt === 'number' && n.receivedAt > 0) ? n.receivedAt : undefined,
                    senderNym: n.senderNym,
                    senderPubkey: n.senderPubkey,
                    channelInfo: n.channelInfo || null,
                    eventId: n.eventId || n.channelInfo?.eventId || undefined,
                    viewed: !!n.viewed
                }));
        } catch (_) { return []; }
    },

    // Build the settings payload object shared by both save paths
    _buildSettingsPayload() {
        return {
            v: 2,
            theme: this.settings.theme,
            sound: this.settings.sound,
            autoscroll: this.settings.autoscroll,
            showTimestamps: this.settings.showTimestamps,
            timeFormat: this.settings.timeFormat,
            dateFormat: this.settings.dateFormat || 'default',
            sortByProximity: this.settings.sortByProximity,
            blurOthersImages: this.blurOthersImages,
            pinnedChannels: Array.from(this.pinnedChannels),
            blockedChannels: Array.from(this.blockedChannels),
            userJoinedChannels: Array.from(this.userJoinedChannels),
            hiddenChannels: Array.from(this.hiddenChannels || []),
            blockedUsers: Array.from(this.blockedUsers || []),
            friends: Array.from(this.friends || []),
            blockedKeywords: Array.from(this.blockedKeywords || []),
            lightningAddress: this.lightningAddress,
            dmForwardSecrecyEnabled: !!this.settings.dmForwardSecrecyEnabled,
            dmTTLSeconds: this.settings.dmTTLSeconds || 86400,
            readReceiptsEnabled: _normalizeIndicatorScope(this.settings.readReceiptsScope) !== 'disabled',
            readReceiptsScope: _normalizeIndicatorScope(this.settings.readReceiptsScope),
            typingIndicatorsEnabled: _normalizeIndicatorScope(this.settings.typingIndicatorsScope) !== 'disabled',
            typingIndicatorsScope: _normalizeIndicatorScope(this.settings.typingIndicatorsScope),
            pinnedLandingChannel: this.pinnedLandingChannel || { type: 'geohash', geohash: 'nymchat' },
            chatLayout: this.settings.chatLayout || 'irc',
            chatViewMode: this.settings.chatViewMode === 'columns' ? 'columns' : 'single',
            columnsWallpaper: this.settings.columnsWallpaper === true,
            columnsLayout: Array.isArray(this.columnsLayout) ? this.columnsLayout : [],
            nickStyle: this.settings.nickStyle || 'fancy',
            colorMode: localStorage.getItem('nym_color_mode') || 'auto',
            wallpaperType: localStorage.getItem('nym_wallpaper_type') || 'geometric',
            wallpaperCustomUrl: localStorage.getItem('nym_wallpaper_custom_url') || '',
            powDifficulty: parseInt(localStorage.getItem('nym_pow_difficulty') || '0', 10),
            hideNonPinned: localStorage.getItem('nym_hide_non_pinned') === 'true',
            textSize: this.settings.textSize || parseInt(localStorage.getItem('nym_text_size') || '15', 10),
            transparencyEnabled: this.settings.transparencyEnabled === true && localStorage.getItem('nym_transparency_enabled') === 'true',
            lowDataMode: this.settings.lowDataMode || localStorage.getItem('nym_low_data_mode') === 'true',
            groupChatPMOnlyMode: this.settings.groupChatPMOnlyMode || false,
            translateLanguage: this.settings.translateLanguage || '',
            translateFavoriteLanguages: this._getTranslateFavorites(),
            emojiPackFavorites: this._getEmojiPackFavorites(),
            emojiCategoryFavorites: this._getDefaultCategoryFavorites(),
            ...(this._getFavoriteGifs().length ? { favoriteGifs: this._getFavoriteGifs().slice(0, 100) } : {}),
            recentEmojis: Array.isArray(this.recentEmojis) ? this.recentEmojis.slice(0, 24) : [],
            gesturesEnabled: this.settings.gesturesEnabled !== false,
            swipeLeftAction: this.settings.swipeLeftAction || 'quote',
            swipeRightAction: this.settings.swipeRightAction || 'translate',
            swipeThreshold: this.settings.swipeThreshold || 60,
            swipeReactEmoji: this.settings.swipeReactEmoji || '❤️',
            sidebarSectionOrder: this._getSidebarSectionOrder(),
            notificationsEnabled: this.notificationsEnabled !== false,
            groupNotifyMentionsOnly: this.groupNotifyMentionsOnly || false,
            notifyFriendsOnly: this.notifyFriendsOnly || false,
            closedPMs: Array.from(this.closedPMs || []),
            leftGroups: Array.from(this.leftGroups || []),
            closedPMTimes: this.closedPMTimes ? Object.fromEntries(this.closedPMTimes) : {},
            leftGroupTimes: this.leftGroupTimes ? Object.fromEntries(this.leftGroupTimes) : {},
            channelLastRead: this.channelLastRead ? Object.fromEntries(this.channelLastRead) : {},
            acceptPMs: this.settings.acceptPMs || 'enabled',
            acceptCalls: this.settings.acceptCalls || 'enabled',
            seenCalls: this._seenCallsForSync(),
            syncMLSHistory: this.settings.syncMLSHistory !== false,
            showStatus: this.settings.showStatus === false ? false : (this.settings.showStatus === 'friends' ? 'friends' : true),
            cachePMs: this.settings.cachePMs !== false,
            tutorialSeen: localStorage.getItem('nym_tutorial_seen') === 'true',
            botPmWelcomed: localStorage.getItem('nym_botpm_welcomed') === 'true',
            botPmClearedAt: this._getBotPmClearedAt() || 0,
            keypairMode: localStorage.getItem('nym_keypair_mode') || 'persistent',
            // Non-sensitive preference only: "I protect my identity key at rest
            // on my devices." No key material, salt, or credential is ever
            // synced — each device sets up its own factor locally. Lets a new
            // device offer to enable encryption too. Monotonic (only flips on).
            encryptAtRestPreferred: localStorage.getItem('nym_encrypt_at_rest_pref') === '1'
        };
    },

    // d-tag for a per-group sync category (lowercased UUID is regex-safe).
    _groupSyncDTag(prefix, groupId) {
        return `${prefix}-${String(groupId).toLowerCase()}`;
    },

    // Opaque per-account token for the OUTER gift-wrap tags. The real routing
    // d-tag stays in the encrypted seal; relays only see this digest, so two
    // members' self-sync wraps for the same group do not share a d-tag that
    // would expose group membership.
    async _syncOuterDTag(dTag) {
        const data = new TextEncoder().encode(`${this.pubkey}:${dTag}`);
        const buf = await crypto.subtle.digest('SHA-256', data);
        const b = new Uint8Array(buf);
        let s = '';
        for (let i = 0; i < b.length; i++) s += b[i].toString(16).padStart(2, '0');
        return s;
    },

    // Opaque per-account D1 storage category so the row key can't be joined
    // across members to reveal group membership.
    async _d1Category(dTag) {
        return `nymchat-${await this._syncOuterDTag('d1:' + dTag)}`;
    },

    // On leaving a group, clear its ephemeral keys blob (security-relevant) but
    // keep the time-bucketed history wraps so the user's own backlog stays
    // durable and isn't dropped from D1.
    _clearGroupSyncData(groupId) {
        try { this._saveSettingsBlobToD1(this._groupSyncDTag('nymchat-keys', groupId), JSON.stringify({})); } catch (_) { }
    },

    // Partition the core settings payload into the settings-modal sections.
    // Keys not in the map land in "misc" so newly added settings still sync.
    _splitSettingsBySection(settingsData) {
        const map = NYM_SETTINGS_SECTION_KEYS;
        const lookup = this._settingsSectionLookup || (this._settingsSectionLookup = (() => {
            const o = {};
            for (const [section, keys] of Object.entries(map)) for (const k of keys) o[k] = section;
            return o;
        })());
        const out = {};
        for (const [key, val] of Object.entries(settingsData)) {
            const section = lookup[key] || 'misc';
            (out[section] || (out[section] = { v: settingsData.v || 2 }))[key] = val;
        }
        return out;
    },

    // Debounced nostrSettingsSave — coalesces rapid state changes (e.g. incoming
    // group messages) into a single Nostr publish.  Delay defaults to 5 seconds.
    _debouncedNostrSettingsSave(delayMs = 5000) {
        if (this._applyingRemoteSettings) return;
        if (this._settingsSaveTimer) clearTimeout(this._settingsSaveTimer);
        this._settingsSaveTimer = setTimeout(() => {
            this._settingsSaveTimer = null;
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        }, delayMs);
    },

    // Marks the initial settings load complete so saves may begin. Flushes one
    // reconcile save if a save was suppressed while loading.
    _markSettingsHydrated() {
        if (this._settingsHydrated) return;
        this._settingsHydrated = true;
        if (this._settingsSavePending) {
            this._settingsSavePending = false;
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        } else {
            // Snapshot the just-loaded section content so a no-op background save
            // won't re-publish it and trigger a self-echo that reloads the lists.
            try {
                const sections = this._splitSettingsBySection(this._buildSettingsPayload());
                this._publishedSectionJson = {};
                for (const [section, payload] of Object.entries(sections)) {
                    this._publishedSectionJson[`nymchat-settings-${section}`] = JSON.stringify(payload);
                }
            } catch (_) { }
        }
        if (Array.isArray(this._onHydratedCbs)) {
            const cbs = this._onHydratedCbs;
            this._onHydratedCbs = null;
            for (const cb of cbs) { try { cb(); } catch (_) { } }
        }
        // Synced prefs (incl. encryptAtRestPreferred) are now applied, so offer
        // to set up identity encryption here if the user uses it elsewhere.
        if (typeof this.maybePromptEncryptAtRest === 'function') {
            setTimeout(() => { try { this.maybePromptEncryptAtRest(); } catch (_) { } }, 2500);
        }
    },

    // Run cb once synced settings have loaded — so device-spanning flags
    // (tutorial seen, bot welcome sent) are applied before we decide to
    // trigger the tutorial or welcome PM.
    _onSettingsHydrated(cb) {
        if (typeof cb !== 'function') return;
        if (this._settingsHydrated) { try { cb(); } catch (_) { } return; }
        if (!this._onHydratedCbs) this._onHydratedCbs = [];
        this._onHydratedCbs.push(cb);
    },

    // Apply only the newest buffered settings event from an initial REQ.
    // Hydration (which fires onboarding) is deferred until the applied settings
    // land so device-spanning flags are in place before the tutorial decides.
    _flushSettingsLoadBuffer(subId) {
        const buf = (this._settingsLoadBuffer && subId) ? this._settingsLoadBuffer.get(subId) : null;
        if (buf) this._settingsLoadBuffer.delete(subId);
        // Sections are authoritative: drop the legacy monolithic blob whenever
        // any section is present, falling back to it only when none exist. Apply
        // oldest-to-newest so the newest section values win.
        let tagged = (buf && buf.byTag) ? Object.entries(buf.byTag) : [];
        if (tagged.some(([t]) => t !== 'nymchat-settings')) {
            tagged = tagged.filter(([t]) => t !== 'nymchat-settings');
        }
        tagged.sort((a, b) => (a[1].ts || 0) - (b[1].ts || 0));
        if (tagged.length && buf.newestTs && buf.newestTs > (this._lastSettingsSyncTs || 0)) {
            this._lastSettingsSyncTs = buf.newestTs;
            try { localStorage.setItem('nym_last_settings_sync_ts', String(buf.newestTs)); } catch (_) { }
            if (typeof applyNostrSettings === 'function') {
                (async () => { for (const [, sec] of tagged) await applyNostrSettings(sec.settings); })()
                    .catch(() => { })
                    .finally(() => this._markSettingsHydrated());
                return;
            }
        }
        // No newer settings to apply — resolve hydration now.
        this._markSettingsHydrated();
    },

    // Serialize group conversation metadata for cross-device sync
    _buildGroupConversationsSync() {
        if (!this.groupConversations || this.groupConversations.size === 0) return null;
        const data = {};
        for (const [groupId, group] of this.groupConversations) {
            data[groupId] = {
                name: group.name,
                members: group.members,
                lastMessageTime: group.lastMessageTime,
                createdBy: group.createdBy,
                mods: Array.isArray(group.mods) ? group.mods : [],
                banned: Array.isArray(group.banned) ? group.banned : [],
                banner: group.banner || null,
                avatar: group.avatar || null,
                description: group.description || null,
                inviteEnabled: group.inviteEnabled === true,
                inviteEpoch: group.inviteEpoch || 0,
                metaUpdatedAt: group.metaUpdatedAt || 0,
                modLog: Array.isArray(group.modLog) ? group.modLog.slice(-50) : []
            };
        }
        return data;
    },

    // Serialize group message history for new-device recovery. No per-group
    // cap: history is time-bucketed into month-sized gift wraps at publish time,
    // so the full backlog is preserved across many small wraps in D1.
    _buildGroupHistorySync() {
        if (!this.pmMessages || this.pmMessages.size === 0) return null;
        const data = {};
        for (const [convKey, messages] of this.pmMessages) {
            if (convKey.startsWith('group-') && messages.length > 0) {
                data[convKey] = messages.map(m => ({
                    id: m.id,
                    pubkey: m.pubkey,
                    content: m.content,
                    created_at: m.created_at,
                    isOwn: m.isOwn,
                    groupId: m.groupId,
                    nymMessageId: m.nymMessageId
                }));
            }
        }
        return Object.keys(data).length > 0 ? data : null;
    },

    // YYYYMM bucket id for a unix-seconds timestamp, used to time-bucket
    // group history so each gift wrap holds at most one month of messages.
    _historyBucketId(tsSeconds) {
        const d = new Date((tsSeconds || 0) * 1000);
        return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
    },

    // Publish one data category as its own self-addressed gift wrap
    async _publishCategoryWrap(payload, dTag, createdAt, trimFns) {
        const RUMOR_OVERHEAD = 256;
        const MAX_RUMOR_BYTES = Math.floor((65535 - 512) / 1.7);
        const encoder = new TextEncoder();
        const rumorByteSize = (p) => {
            const json = JSON.stringify(p);
            return encoder.encode(JSON.stringify(json)).length + RUMOR_OVERHEAD;
        };

        if (Array.isArray(trimFns) && trimFns.length) {
            let guard = 0;
            while (rumorByteSize(payload) > MAX_RUMOR_BYTES && guard++ < 500) {
                let trimmed = false;
                for (const fn of trimFns) {
                    if (fn(payload)) { trimmed = true; break; }
                }
                if (!trimmed) break;
            }
        }

        if (rumorByteSize(payload) > MAX_RUMOR_BYTES) {
            console.warn(`[NostrSync] ${dTag} exceeds NIP-44 plaintext limit after trimming; skipping publish`);
            return;
        }

        await this._publishWrappedNostrEvent(payload, dTag, createdAt);
    },

    async _publishEncryptedSettings(settingsData) {
        // Don't overwrite stored settings until we've loaded them. On a fresh
        // device an early save (e.g. from an incoming group message) would
        // otherwise clobber D1/relay with default state before the load lands.
        if (!this._settingsHydrated) {
            this._settingsSavePending = true;
            return;
        }
        const now = Math.floor(Date.now() / 1000);

        // Category data is published separately, never bundled into core settings
        delete settingsData.groupEphemeralKeys;
        delete settingsData.groupConversations;
        delete settingsData.groupMessageHistory;
        delete settingsData.notificationHistory;
        delete settingsData.notificationLastReadTime;

        // Bump the sync timestamp before publishing
        if (now > (this._lastSettingsSyncTs || 0)) {
            this._lastSettingsSyncTs = now;
            try { localStorage.setItem('nym_last_settings_sync_ts', String(now)); } catch (_) { }
        }

        // Group ephemeral keys, published per group as nymchat-keys-<groupId> so
        // one big group can't push the keys payload past the NIP-44 cap. Skips
        // left groups and drops stale member entries.
        if (this.groupEphemeralKeys && this.groupEphemeralKeys.size > 0) {
            // Trim the oldest quarter of one group's prev keys when oversized.
            const trimEphemeralPrevKeys = (p) => {
                const map = p.groupEphemeralKeys || {};
                const entry = Object.values(map)[0];
                const prev = entry?.self?.prev;
                if (!Array.isArray(prev) || prev.length === 0) return false;
                const dropCount = Math.max(1, Math.ceil(prev.length * 0.25));
                entry.self.prev = prev.slice(0, prev.length - dropCount);
                if (entry.self.prev.length === 0) delete entry.self.prev;
                return true;
            };
            const trimMemberKeyTs = (p) => {
                const entry = Object.values(p.groupEphemeralKeys || {})[0];
                if (entry && entry.memberKeyTs) { delete entry.memberKeyTs; return true; }
                return false;
            };
            for (const [groupId, ek] of this.groupEphemeralKeys) {
                if (this.leftGroups && this.leftGroups.has(groupId)) continue;
                try {
                    const entry = this._serializeEphemeralKeys(ek);
                    // Drop members not in the current member list to keep it bounded.
                    const group = this.groupConversations?.get(groupId);
                    if (group && Array.isArray(group.members) && entry.members) {
                        const memberSet = new Set(group.members);
                        for (const realPk of Object.keys(entry.members)) {
                            if (!memberSet.has(realPk)) {
                                delete entry.members[realPk];
                                if (entry.memberKeyTs) delete entry.memberKeyTs[realPk];
                            }
                        }
                    }
                    await this._publishCategoryWrap(
                        { groupEphemeralKeys: { [groupId]: entry } },
                        this._groupSyncDTag('nymchat-keys', groupId),
                        now,
                        [trimEphemeralPrevKeys, trimMemberKeyTs]
                    );
                } catch (_) { }
            }
        }

        // Group conversation metadata → nymchat-groups
        try {
            const groupConversations = this._buildGroupConversationsSync();
            if (groupConversations) {
                const trimGroupModLogs = (p) => {
                    let trimmed = false;
                    for (const g of Object.values(p.groupConversations || {})) {
                        if (g && Array.isArray(g.modLog) && g.modLog.length > 0) {
                            g.modLog = g.modLog.slice(Math.ceil(g.modLog.length / 2));
                            trimmed = true;
                        }
                    }
                    return trimmed;
                };
                await this._publishCategoryWrap({ groupConversations }, 'nymchat-groups', now, [trimGroupModLogs]);
            }
        } catch (_) { }

        // Group message history → nymchat-history-<groupId>-<YYYYMM>-<shard>.
        // Messages are bucketed by month (stable, intrinsic key) and, within a
        // month, packed into byte-bounded shards so even a very busy period
        // (hundreds of messages/day) splits into multiple small wraps instead of
        // overflowing one. A past month's shards become immutable once its
        // messages stop changing, so the backlog accumulates durably in D1.
        try {
            const groupMessageHistory = this._buildGroupHistorySync();
            if (groupMessageHistory) {
                // ~30 KB of message JSON per shard, well under the NIP-44 cap.
                const SHARD_BUDGET = 30000;
                // Last-resort guard if a single message is itself enormous.
                const trimOldestHistory = (p) => {
                    const hist = p.groupMessageHistory || {};
                    const k = Object.keys(hist)[0];
                    const arr = k && hist[k];
                    if (!Array.isArray(arr) || arr.length <= 1) return false;
                    const next = arr.slice(Math.max(1, Math.ceil(arr.length * 0.1)));
                    if (next.length === 0) delete hist[k]; else hist[k] = next;
                    return true;
                };
                for (const [convKey, arr] of Object.entries(groupMessageHistory)) {
                    const groupId = convKey.startsWith('group-') ? convKey.slice(6) : convKey;
                    const base = this._groupSyncDTag('nymchat-history', groupId);
                    // Partition into month buckets.
                    const buckets = {};
                    for (const m of arr) {
                        const b = this._historyBucketId(m.created_at);
                        (buckets[b] || (buckets[b] = [])).push(m);
                    }
                    for (const [bucket, msgs] of Object.entries(buckets)) {
                        // Sort ascending so shard boundaries are stable across saves.
                        msgs.sort((a, b) => (a.created_at - b.created_at)
                            || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
                        let shard = 0, shardMsgs = [], shardBytes = 0;
                        const flush = async () => {
                            if (!shardMsgs.length) return;
                            await this._publishCategoryWrap(
                                { groupMessageHistory: { [convKey]: shardMsgs } },
                                `${base}-${bucket}-${shard}`, now, [trimOldestHistory]);
                            shard++; shardMsgs = []; shardBytes = 0;
                        };
                        for (const m of msgs) {
                            const sz = JSON.stringify(m).length + 4;
                            if (shardBytes + sz > SHARD_BUDGET && shardMsgs.length) await flush();
                            shardMsgs.push(m); shardBytes += sz;
                        }
                        await flush();
                    }
                }
            }
        } catch (_) { }

        // Notification history + seen keys → nymchat-notifications
        try {
            const notificationHistory = this._serialiseNotificationsForSync();
            const lastRead = this.notificationLastReadTime || 0;
            this._pruneSeenNotificationKeys();
            const seenNotifications = (this.seenNotificationKeys && this.seenNotificationKeys.size > 0)
                ? Object.fromEntries(this.seenNotificationKeys)
                : null;
            if (notificationHistory.length > 0 || lastRead > 0 || seenNotifications) {
                // Drop the oldest 10% of notifications
                const trimOldestNotifications = (p) => {
                    const arr = p.notificationHistory;
                    if (!Array.isArray(arr) || arr.length <= 1) return false;
                    p.notificationHistory = arr.slice(Math.max(1, Math.ceil(arr.length * 0.1)));
                    return true;
                };
                // Drop the oldest 25% of seen keys
                const trimOldestSeen = (p) => {
                    const o = p.seenNotifications;
                    const keys = o ? Object.keys(o) : [];
                    if (keys.length <= 1) return false;
                    keys.sort((a, b) => o[a] - o[b]);
                    for (const k of keys.slice(0, Math.max(1, Math.ceil(keys.length * 0.25)))) delete o[k];
                    return true;
                };
                const payload = { notificationHistory, notificationLastReadTime: lastRead };
                if (seenNotifications) payload.seenNotifications = seenNotifications;
                await this._publishCategoryWrap(
                    payload, 'nymchat-notifications', now, [trimOldestNotifications, trimOldestSeen]);
            }
        } catch (_) { }

        const sections = this._splitSettingsBySection(settingsData);
        if (!this._publishedSectionJson) this._publishedSectionJson = {};
        for (const [section, payload] of Object.entries(sections)) {
            const dTag = `nymchat-settings-${section}`;
            const json = JSON.stringify(payload);
            if (this._publishedSectionJson[dTag] === json) continue;
            this._publishedSectionJson[dTag] = json;
            await this._publishCategoryWrap(payload, dTag, now);
        }
    },

    // Wrap an arbitrary settings payload as a NIP-59 self-addressed gift wrap
    // (kind 1059 outer, kind 30078 inner) with the given d-tag.
    async _publishWrappedNostrEvent(payload, dTag, createdAt) {
        const NT = window.NostrTools;
        const now = createdAt || Math.floor(Date.now() / 1000);

        // Primary persistence: encrypted blob in D1. The Nostr gift wrap below
        // is kept as a fallback copy that loads only when D1 can't be read.
        this._saveSettingsBlobToD1(dTag, JSON.stringify(payload));

        const rumor = {
            kind: 30078,
            created_at: now,
            tags: [['d', dTag]],
            content: JSON.stringify(payload),
            pubkey: this.pubkey
        };
        rumor.id = NT.getEventHash(rumor);

        // NIP-44 caps each encryption stage at 65535 plaintext bytes. Skip
        // rather than throw if the rumor or its sealed form exceeds the cap.
        const enc = new TextEncoder();
        const rumorJson = JSON.stringify(rumor);
        if (enc.encode(rumorJson).length > 65535) {
            console.warn(`[NostrSync] ${dTag} payload exceeds NIP-44 plaintext limit; skipping publish`);
            return;
        }

        // 'k' marker lets the Nostr fallback REQ match every settings gift wrap
        // with one filter; the d-tag is digested so it can't be correlated
        // across accounts (the real d-tag rides encrypted in the inner rumor).
        const outerTags = [['p', this.pubkey], ['d', await this._syncOuterDTag(dTag)], ['k', 'nym-sync']];

        if (this.privkey) {
            const ckSeal = NT.nip44.getConversationKey(this.privkey, this.pubkey);
            const sealContent = NT.nip44.encrypt(rumorJson, ckSeal);
            const sealUnsigned = { kind: 13, content: sealContent, created_at: this.randomNow(), tags: [] };
            const seal = NT.finalizeEvent(sealUnsigned, this.privkey);

            const sealJson = JSON.stringify(seal);
            if (enc.encode(sealJson).length > 65535) {
                console.warn(`[NostrSync] ${dTag} sealed payload exceeds NIP-44 plaintext limit; skipping publish`);
                return;
            }
            const ephSk = NT.generateSecretKey();
            const ckWrap = NT.nip44.getConversationKey(ephSk, this.pubkey);
            const wrapContent = NT.nip44.encrypt(sealJson, ckWrap);
            const wrapUnsigned = {
                kind: 1059, content: wrapContent, created_at: this.randomNow(),
                tags: outerTags
            };
            const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);
            this.sendDMToRelays(['EVENT', wrapped]);
            return;
        }

        const useExt = !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent);
        const useN46 = this.nostrLoginMethod === 'nip46' && _nip46State && _nip46State.connected;
        if (!useExt && !useN46) return;

        const sealContent = useExt
            ? await window.nostr.nip44.encrypt(this.pubkey, rumorJson)
            : await _nip46Encrypt(this.pubkey, rumorJson);
        const sealUnsigned = { kind: 13, content: sealContent, created_at: this.randomNow(), tags: [] };
        const seal = useExt
            ? await window.nostr.signEvent(sealUnsigned)
            : await _nip46SignEvent(sealUnsigned);

        const sealJson = JSON.stringify(seal);
        if (enc.encode(sealJson).length > 65535) {
            console.warn(`[NostrSync] ${dTag} sealed payload exceeds NIP-44 plaintext limit; skipping publish`);
            return;
        }
        const ephSk = NT.generateSecretKey();
        const ckWrap = NT.nip44.getConversationKey(ephSk, this.pubkey);
        const wrapContent = NT.nip44.encrypt(sealJson, ckWrap);
        const wrapUnsigned = {
            kind: 1059, content: wrapContent, created_at: this.randomNow(),
            tags: outerTags
        };
        const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);
        this.sendDMToRelays(['EVENT', wrapped]);
    },

    // Encrypt a settings payload to the user themselves (NIP-44) using whichever
    // signer is active: local nsec, NIP-07 extension, or NIP-46 remote signer.
    async _encryptSettingsBlob(plaintext) {
        const NT = window.NostrTools;
        try {
            if (this.privkey) {
                const ck = NT.nip44.getConversationKey(this.privkey, this.pubkey);
                return NT.nip44.encrypt(plaintext, ck);
            }
            if (window.nostr?.nip44?.encrypt) {
                return await window.nostr.nip44.encrypt(this.pubkey, plaintext);
            }
            if (this.nostrLoginMethod === 'nip46' && typeof _nip46State !== 'undefined' && _nip46State && _nip46State.connected) {
                return await _nip46Encrypt(this.pubkey, plaintext);
            }
        } catch (_) { }
        return null;
    },

    async _decryptSettingsBlob(ciphertext) {
        const NT = window.NostrTools;
        try {
            if (this.privkey) {
                const ck = NT.nip44.getConversationKey(this.privkey, this.pubkey);
                return NT.nip44.decrypt(ciphertext, ck);
            }
            if (window.nostr?.nip44?.decrypt) {
                return await window.nostr.nip44.decrypt(this.pubkey, ciphertext);
            }
            if (this.nostrLoginMethod === 'nip46' && typeof _nip46State !== 'undefined' && _nip46State && _nip46State.connected) {
                return await _nip46Decrypt(this.pubkey, ciphertext);
            }
        } catch (_) { }
        return null;
    },

    // SHA-256 hex of a string (used to gate redundant settings writes).
    async _sha256Hex(str) {
        try {
            const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(str));
            return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
        } catch (_) {
            return null;
        }
    },

    async _saveSettingsBlobToD1(dTag, plaintext) {
        if (!this.pubkey) return false;
        try {
            // Embed the real category in the (encrypted) blob so the cleartext
            // D1 column can be an opaque per-account hash.
            let toStore = plaintext;
            try {
                const obj = JSON.parse(plaintext);
                if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
                    obj.__cat = dTag;
                    toStore = JSON.stringify(obj);
                }
            } catch (_) { }

            const category = await this._d1Category(dTag);
            const hash = await this._sha256Hex(`${this.pubkey}|${toStore}`);
            const hashKey = `nym_settings_hash_${this.pubkey}_${category}`;
            if (hash) {
                let lastHash = null;
                try { lastHash = localStorage.getItem(hashKey); } catch (_) { }
                if (lastHash === hash) return true; // unchanged — nothing to write
            }
            const blob = await this._encryptSettingsBlob(toStore);
            if (!blob) return false;
            const resp = await this._storageApiRequest('settings-set', { category, blob, contentHash: hash || undefined });
            if (hash && resp) {
                try { localStorage.setItem(hashKey, hash); } catch (_) { }
            }
            return true;
        } catch (_) {
            return false;
        }
    },

    // Load encrypted settings categories from D1 and apply them. Returns true
    // when core settings were applied; false (e.g. fetch error, no record) tells
    // the caller to fall back to the Nostr gift-wrap load.
    async settingsLoadFromD1() {
        const pubkey = (typeof isNostrLoggedIn === 'function' && isNostrLoggedIn())
            ? localStorage.getItem('nym_nostr_login_pubkey')
            : this.pubkey;
        if (!pubkey) return false;

        let data;
        try {
            data = await this._storageApiRequest('settings-get', {});
        } catch (_) {
            return false;
        }
        const cats = data && data.categories;
        if (!cats || typeof cats !== 'object') return false;

        // Decrypt each category once. The real category name rides inside the
        // encrypted blob as __cat (the D1 column is an opaque per-account hash);
        // legacy rows fall back to the cleartext column name.
        const decoded = [];
        for (const [cat, entry] of Object.entries(cats)) {
            if (!entry || !entry.blob) continue;
            try {
                const plain = await this._decryptSettingsBlob(entry.blob);
                if (!plain) continue;
                const payload = JSON.parse(plain);
                if (!payload || typeof payload !== 'object') continue;
                const realCat = typeof payload.__cat === 'string' ? payload.__cat : cat;
                delete payload.__cat;
                decoded.push({ realCat, payload, updatedAt: entry.updatedAt || 0 });
            } catch (_) { }
        }

        const isCore = (c) => c === 'nymchat-settings' || c.startsWith('nymchat-settings-');

        // Non-core additive categories first so lists exist before core settings.
        for (const d of decoded) {
            if (isCore(d.realCat)) continue;
            try { await applyNostrSettingsAdditive(d.payload); } catch (_) { }
        }

        // Sections are authoritative: apply them oldest-to-newest so the most
        // recently saved values win, and fall back to the legacy monolithic
        // blob only when no section blobs exist.
        const coreEntries = decoded.filter(d => isCore(d.realCat));
        const sectionEntries = coreEntries
            .filter(d => d.realCat !== 'nymchat-settings')
            .sort((a, b) => (a.updatedAt || 0) - (b.updatedAt || 0));
        const toApply = sectionEntries.length
            ? sectionEntries
            : coreEntries.filter(d => d.realCat === 'nymchat-settings');
        let coreApplied = 0, newestCoreTs = 0;
        for (const d of toApply) {
            try {
                await applyNostrSettingsAdditive(d.payload);
                await applyNostrSettings(d.payload);
                coreApplied++;
                const ts = d.updatedAt ? Math.floor(d.updatedAt / 1000) : Math.floor(Date.now() / 1000);
                if (ts > newestCoreTs) newestCoreTs = ts;
            } catch (_) { }
        }

        if (coreApplied === 0) return false;
        if (newestCoreTs > (this._lastSettingsSyncTs || 0)) {
            this._lastSettingsSyncTs = newestCoreTs;
            try { localStorage.setItem('nym_last_settings_sync_ts', String(newestCoreTs)); } catch (_) { }
        }
        // D1 had real settings and we applied them — safe to save from here.
        this._markSettingsHydrated();
        return true;
    },

    toggleNotificationsEnabled(enabled) {
        this.notificationsEnabled = enabled;
        localStorage.setItem('nym_notifications_enabled', String(enabled));
        this._updateNotificationBadge();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    toggleNotifyFriendsOnly(enabled) {
        this.notifyFriendsOnly = enabled;
        localStorage.setItem('nym_notify_friends_only', String(enabled));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    applyTheme(theme) {
        document.body.classList.remove('theme-ghost', 'theme-bitchat');

        if (theme === 'ghost') {
            document.body.classList.add('theme-ghost');
        } else if (theme === 'bitchat') {
            document.body.classList.add('theme-bitchat');
        }

        const isLight = document.body.classList.contains('light-mode');

        const themes = {
            matrix: {
                dark: {
                    primary: '#00ff00',
                    secondary: '#00ffff',
                    text: '#00ff00',
                    textDim: '#00BD00',
                    textBright: '#00ffaa',
                    lightning: '#f7931a'
                },
                light: {
                    primary: '#007a00',
                    secondary: '#007a7a',
                    text: '#006600',
                    textDim: '#558855',
                    textBright: '#004d00',
                    lightning: '#c47a15'
                }
            },
            amber: {
                dark: {
                    primary: '#ffb000',
                    secondary: '#ffd700',
                    text: '#ffb000',
                    textDim: '#cc8800',
                    textBright: '#ffcc00',
                    lightning: '#ffa500'
                },
                light: {
                    primary: '#9a6a00',
                    secondary: '#8a7200',
                    text: '#7a5500',
                    textDim: '#8a7a55',
                    textBright: '#5a3a00',
                    lightning: '#b87300'
                }
            },
            cyber: {
                dark: {
                    primary: '#ff00ff',
                    secondary: '#00ffff',
                    text: '#ff00ff',
                    textDim: '#DB16DB',
                    textBright: '#ff66ff',
                    lightning: '#ffaa00'
                },
                light: {
                    primary: '#990099',
                    secondary: '#007a7a',
                    text: '#880088',
                    textDim: '#885588',
                    textBright: '#660066',
                    lightning: '#b87300'
                }
            },
            hacker: {
                dark: {
                    primary: '#00ffff',
                    secondary: '#00ff00',
                    text: '#00ffff',
                    textDim: '#01c2c2',
                    textBright: '#66ffff',
                    lightning: '#00ff88'
                },
                light: {
                    primary: '#007a7a',
                    secondary: '#007a00',
                    text: '#006666',
                    textDim: '#558888',
                    textBright: '#004d4d',
                    lightning: '#009955'
                }
            },
            ghost: {
                dark: {
                    primary: '#ffffff',
                    secondary: '#cccccc',
                    text: '#ffffff',
                    textDim: '#cccccc',
                    textBright: '#ffffff',
                    lightning: '#dddddd'
                },
                light: {
                    primary: '#333333',
                    secondary: '#555555',
                    text: '#222222',
                    textDim: '#777777',
                    textBright: '#000000',
                    lightning: '#999999'
                }
            },
            bitchat: {
                dark: {
                    primary: '#00ff00',
                    secondary: '#00ffff',
                    text: '#00ff00',
                    textDim: '#cccccc',
                    textBright: '#00ffaa',
                    lightning: '#f7931a'
                },
                light: {
                    primary: '#007a00',
                    secondary: '#007a7a',
                    text: '#006600',
                    textDim: '#666666',
                    textBright: '#004d00',
                    lightning: '#c47a15'
                }
            }
        };

        // Clear any stale inline theme vars from both documentElement and body
        ['--primary', '--secondary', '--text', '--text-dim', '--text-bright', '--lightning'].forEach(v => {
            document.documentElement.style.removeProperty(v);
            document.body.style.removeProperty(v);
        });

        const mode = isLight ? 'light' : 'dark';
        const selectedTheme = themes[theme] && themes[theme][mode];
        if (selectedTheme) {
            Object.entries(selectedTheme).forEach(([key, value]) => {
                const cssVar = `--${key.replace(/([A-Z])/g, '-$1').toLowerCase()}`;
                document.body.style.setProperty(cssVar, value);
            });
            // Derive RGB components from the primary color so the built-in
            // wallpaper patterns can tint themselves to match the active theme.
            const rgb = this._hexToRgb(selectedTheme.primary);
            if (rgb) {
                document.body.style.setProperty('--wp-r', rgb.r);
                document.body.style.setProperty('--wp-g', rgb.g);
                document.body.style.setProperty('--wp-b', rgb.b);
            }
        }
        this.refreshMessages();
    },

    _hexToRgb(hex) {
        if (typeof hex !== 'string') return null;
        let h = hex.trim().replace(/^#/, '');
        if (h.length === 3) h = h.split('').map(c => c + c).join('');
        if (!/^[0-9a-f]{6}$/i.test(h)) return null;
        return {
            r: parseInt(h.slice(0, 2), 16),
            g: parseInt(h.slice(2, 4), 16),
            b: parseInt(h.slice(4, 6), 16)
        };
    },

    getColorMode() {
        return localStorage.getItem('nym_color_mode') || 'auto';
    },

    resolveColorMode() {
        const mode = this.getColorMode();
        if (mode === 'light') return 'light';
        if (mode === 'dark') return 'dark';
        // auto: use system preference
        return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
    },

    applyColorMode(mode) {
        const resolved = mode || this.resolveColorMode();
        if (resolved === 'light') {
            document.body.classList.add('light-mode');
        } else {
            document.body.classList.remove('light-mode');
        }
        // Re-apply current theme to pick up light/dark color variants
        this.applyTheme(this.settings.theme);

        // Re-apply wallpaper so custom overlays match the new mode
        this.loadWallpaper();

        // Update meta theme-color to match the mode
        const themeColor = resolved === 'light' ? '#f5f5f2' : '#000000';
        const metaTheme = document.querySelector('meta[name="theme-color"]');
        if (metaTheme) {
            metaTheme.content = themeColor;
        }

        // Keep the Flutter shell's native status bar in sync with the app theme
        try {
            if (window.FlutterTheme && typeof window.FlutterTheme.postMessage === 'function') {
                window.FlutterTheme.postMessage(JSON.stringify({
                    backgroundColor: themeColor,
                    isLightMode: resolved === 'light'
                }));
            }
        } catch (_) { /* ignore */ }
    },

    setupColorModeListener() {
        this._colorModeMediaQuery = window.matchMedia('(prefers-color-scheme: light)');
        this._colorModeHandler = () => {
            if (this.getColorMode() === 'auto') {
                this.applyColorMode();
            }
        };
        this._colorModeMediaQuery.addEventListener('change', this._colorModeHandler);
    },

    loadSettings() {
        let pinnedLandingChannel;
        try {
            const saved = localStorage.getItem('nym_pinned_landing_channel');
            pinnedLandingChannel = saved ? JSON.parse(saved) : { type: 'geohash', geohash: 'nymchat' };
        } catch (e) {
            pinnedLandingChannel = { type: 'geohash', geohash: 'nymchat' };
        }
        // Migrate the legacy default channel key to the renamed default.
        if (pinnedLandingChannel && pinnedLandingChannel.geohash === 'nym') {
            pinnedLandingChannel = { type: 'geohash', geohash: 'nymchat' };
            try { localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(pinnedLandingChannel)); } catch (_) { }
        }

        // Migrate legacy sound values to their relabeled equivalents.
        const savedSound = localStorage.getItem('nym_sound') || 'beep';
        const sound = { icq: 'uhoh', msn: 'msnding' }[savedSound] || savedSound;

        return {
            theme: localStorage.getItem('nym_theme') || 'bitchat',
            sound: sound,
            autoscroll: localStorage.getItem('nym_autoscroll') !== 'false',
            showTimestamps: localStorage.getItem('nym_timestamps') !== 'false',
            sortByProximity: localStorage.getItem('nym_sort_proximity') === 'true',
            timeFormat: localStorage.getItem('nym_time_format') || '12hr',
            dateFormat: localStorage.getItem('nym_date_format') || 'default',
            dmForwardSecrecyEnabled: localStorage.getItem('nym_dm_fwdsec_enabled') === 'true',
            dmTTLSeconds: parseInt(localStorage.getItem('nym_dm_ttl_seconds') || '86400', 10),
            readReceiptsScope: _normalizeIndicatorScope(
                localStorage.getItem('nym_read_receipts_scope'),
                localStorage.getItem('nym_read_receipts_enabled') === 'false' ? 'disabled' : 'everywhere'
            ),
            typingIndicatorsScope: _normalizeIndicatorScope(
                localStorage.getItem('nym_typing_indicators_scope'),
                localStorage.getItem('nym_typing_indicators_enabled') === 'false' ? 'disabled' : 'everywhere'
            ),
            pinnedLandingChannel: pinnedLandingChannel,
            nickStyle: localStorage.getItem('nym_nick_style') || 'fancy',
            chatLayout: localStorage.getItem('nym_chat_layout') || 'bubbles',
            chatViewMode: localStorage.getItem('nym_chat_view_mode') === 'columns' ? 'columns' : 'single',
            columnsWallpaper: localStorage.getItem('nym_columns_wallpaper') === 'true',
            lowDataMode: localStorage.getItem('nym_low_data_mode') === 'true',
            textSize: parseInt(localStorage.getItem('nym_text_size') || '15', 10),
            transparencyEnabled: localStorage.getItem('nym_transparency_enabled') === 'true',
            groupChatPMOnlyMode: localStorage.getItem('nym_groupchat_pm_only_mode') === 'true',
            translateLanguage: localStorage.getItem('nym_translate_language') || '',
            gesturesEnabled: localStorage.getItem('nym_gestures_enabled') !== 'false',
            swipeLeftAction: localStorage.getItem('nym_swipe_left_action') || 'quote',
            swipeRightAction: localStorage.getItem('nym_swipe_right_action') || 'translate',
            swipeThreshold: parseInt(localStorage.getItem('nym_swipe_threshold') || '60', 10),
            swipeReactEmoji: localStorage.getItem('nym_swipe_react_emoji') || '❤️',
            acceptPMs: localStorage.getItem('nym_accept_pms') || 'enabled',
            acceptCalls: localStorage.getItem('nym_accept_calls') || 'enabled',
            cachePMs: localStorage.getItem('nym_cache_pms') !== 'false', // default true
            syncMLSHistory: localStorage.getItem('nym_sync_mls_history') !== 'false', // default true
            showStatus: (() => {
                const v = localStorage.getItem('nym_show_status');
                return v === 'false' ? false : (v === 'friends' ? 'friends' : true); // default true
            })()
        };
    },

    loadImageBlurSettings() {
        // Try per-pubkey key first, then fall back to global key (for ephemeral
        // users whose pubkeys change each session).
        // Returns true, false, or 'friends'
        if (this.pubkey) {
            const saved = localStorage.getItem(`nym_image_blur_${this.pubkey}`);
            if (saved !== null) {
                if (saved === 'friends') return 'friends';
                return saved === 'true';
            }
        }
        const global = localStorage.getItem('nym_image_blur');
        if (global !== null) {
            if (global === 'friends') return 'friends';
            return global === 'true';
        }
        return true; // Default to blur
    },

    saveImageBlurSettings() {
        // Always save a global key so ephemeral users keep their preference
        const val = String(this.blurOthersImages);
        localStorage.setItem('nym_image_blur', val);
        if (this.pubkey) {
            localStorage.setItem(`nym_image_blur_${this.pubkey}`, val);
        }
    },

    reapplyImageBlur() {
        document.querySelectorAll('.message img').forEach(img => {
            if (img.classList.contains('custom-emoji')) return;
            const messageEl = img.closest('.message');
            if (!messageEl) return;
            const isSelfMessage = messageEl.classList.contains('self');
            const pubkey = messageEl.dataset.pubkey;
            const shouldBlur = !isSelfMessage && (
                this.blurOthersImages === true ||
                (this.blurOthersImages === 'friends' && !this.isFriend(pubkey))
            );
            if (shouldBlur) {
                img.classList.add('blurred');
            } else {
                img.classList.remove('blurred');
            }
        });
    },

    saveSettings() {
        localStorage.setItem('nym_theme', this.settings.theme);
        localStorage.setItem('nym_sound', this.settings.sound);
        localStorage.setItem('nym_autoscroll', this.settings.autoscroll);
        localStorage.setItem('nym_timestamps', this.settings.showTimestamps);
        localStorage.setItem('nym_sort_proximity', this.settings.sortByProximity);
        const powDifficulty = parseInt(document.getElementById('powDifficultySelect').value);
        this.powDifficulty = powDifficulty;
        this.enablePow = powDifficulty > 0;
        localStorage.setItem('nym_pow_difficulty', powDifficulty.toString());
    },

});
