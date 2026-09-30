// settings.js - User settings: load/save, sync to Nostr, theme/color mode, image blur

const INDICATOR_SCOPES = ['disabled', 'pms', 'groups', 'pms-groups', 'everywhere'];

// Settings key -> modal section, for per-section gift wraps; unmapped keys fall through to "misc".
const NYM_SETTINGS_SECTION_KEYS = {
    appearance: ['theme', 'sound', 'autoscroll', 'showTimestamps', 'timeFormat', 'dateFormat',
        'blurOthersImages', 'chatLayout', 'chatViewMode', 'columnsLayout', 'nickStyle', 'colorMode',
        'wallpaperType', 'wallpaperCustomUrl', 'textSize', 'transparencyEnabled', 'columnsWallpaper',
        'sidebarSectionOrder', 'uiLanguage'],
    privacy: ['blockedUsers', 'friends', 'blockedKeywords', 'blockedChannels', 'hiddenChannels',
        'lightningAddress', 'dmForwardSecrecyEnabled', 'dmTTLSeconds', 'readReceiptsEnabled',
        'readReceiptsScope', 'typingIndicatorsEnabled', 'typingIndicatorsScope', 'acceptPMs',
        'acceptCalls', 'showStatus', 'powDifficulty', 'appVerifiedFilter', 'filterPacks',
        'encryptAtRestPreferred'],
    messaging: ['groupChatPMOnlyMode', 'threadsEnabled', 'translateLanguage', 'translateFavoriteLanguages',
        'emojiPackFavorites', 'emojiCategoryFavorites', 'favoriteGifs', 'recentEmojis',
        'gesturesEnabled', 'swipeLeftAction', 'swipeRightAction', 'swipeThreshold',
        'swipeReactEmoji', 'notificationsEnabled', 'groupNotifyMentionsOnly',
        'threadNotifyMentionsOnly', 'notifyFriendsOnly',
        'syncMLSHistory', 'seenCalls'],
    channels: ['pinnedChannels', 'userJoinedChannels', 'sortByProximity', 'pinnedLandingChannel',
        'hideNonPinned', 'closedPMs', 'leftGroups', 'closedPMTimes',
        'leftGroupTimes'],
    data: ['lowDataMode', 'cachePMs', 'tutorialSeen', 'botPmWelcomed', 'botPmClearedAt']
};

// Sealed classically, never to the root-derived key (a circular lock). Spec §5.1.
const NYM_PQ_ROOT_CATEGORY = 'nymchat-pq-root';

// pq2 framing for the size budget: `pq2.` plus a fixed 1088-byte ML-KEM ciphertext, base64url.
const PQ2_PREFIX_LEN = 4;
const ML_KEM_CIPHERTEXT_BYTES = 1088;

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

        // Skip sync for hardcore mode (keypair changes every message) and random-per-session.
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
            powDifficulty: (typeof normalizePowDifficulty === 'function')
                ? normalizePowDifficulty(localStorage.getItem('nym_pow_difficulty'))
                : parseInt(localStorage.getItem('nym_pow_difficulty') || '0', 10),
            appVerifiedFilter: (typeof normalizeAppVerifiedFilter === 'function')
                ? normalizeAppVerifiedFilter(localStorage.getItem('nym_app_verified_filter'))
                : (localStorage.getItem('nym_app_verified_filter') || 'off'),
            filterPacks: Array.isArray(this.filterPacks) ? this.filterPacks : [],
            hideNonPinned: localStorage.getItem('nym_hide_non_pinned') === 'true',
            textSize: this.settings.textSize || parseInt(localStorage.getItem('nym_text_size') || '15', 10),
            transparencyEnabled: this.settings.transparencyEnabled === true && localStorage.getItem('nym_transparency_enabled') === 'true',
            lowDataMode: this.settings.lowDataMode || localStorage.getItem('nym_low_data_mode') === 'true',
            groupChatPMOnlyMode: this.settings.groupChatPMOnlyMode || false,
            threadsEnabled: this.settings.threadsEnabled !== false,
            botAnonEnabled: typeof this.botAnonEnabled === 'function' ? this.botAnonEnabled() : false,
            translateLanguage: this.settings.translateLanguage || '',
            translateFavoriteLanguages: this._getTranslateFavorites(),
            uiLanguage: this.settings.uiLanguage || '',
            emojiPackFavorites: this._getEmojiPackFavorites(),
            emojiCategoryFavorites: this._getDefaultCategoryFavorites(),
            ...(this._getFavoriteGifs().length ? { favoriteGifs: this._getFavoriteGifs().slice(0, 100) } : {}),
            recentEmojis: this.sanitizeRecentEmojis(this.recentEmojis),
            gesturesEnabled: this.settings.gesturesEnabled !== false,
            swipeLeftAction: this.settings.swipeLeftAction || 'quote',
            swipeRightAction: this.settings.swipeRightAction || 'translate',
            swipeThreshold: this.settings.swipeThreshold || 60,
            ...(localStorage.getItem('nym_swipe_react_emoji')
                ? { swipeReactEmoji: localStorage.getItem('nym_swipe_react_emoji') }
                : {}),
            sidebarSectionOrder: this._getSidebarSectionOrder(),
            notificationsEnabled: this.notificationsEnabled !== false,
            groupNotifyMentionsOnly: this.groupNotifyMentionsOnly || false,
            threadNotifyMentionsOnly: this.threadNotifyMentionsOnly || false,
            notifyFriendsOnly: this.notifyFriendsOnly || false,
            closedPMs: Array.from(this.closedPMs || []),
            leftGroups: Array.from(this.leftGroups || []),
            closedPMTimes: this.closedPMTimes ? Object.fromEntries(this.closedPMTimes) : {},
            leftGroupTimes: this.leftGroupTimes ? Object.fromEntries(this.leftGroupTimes) : {},
            acceptPMs: this.settings.acceptPMs || 'enabled',
            acceptCalls: this.settings.acceptCalls || 'enabled',
            seenCalls: this._seenCallsForSync(),
            syncMLSHistory: this.settings.syncMLSHistory !== false,
            showStatus: this.settings.showStatus === false ? false : (this.settings.showStatus === 'friends' ? 'friends' : true),
            cachePMs: this.settings.cachePMs !== false,
            tutorialSeen: localStorage.getItem('nym_tutorial_seen') === 'true',
            botPmWelcomed: localStorage.getItem('nym_botpm_welcomed') === 'true',
            botPmClearedAt: this._getBotPmClearedAt() || 0,
            encryptAtRestPreferred: localStorage.getItem('nym_encrypt_at_rest_pref') === '1'
        };
    },

    // Lowercased UUID is regex-safe.
    _groupSyncDTag(prefix, groupId) {
        return `${prefix}-${String(groupId).toLowerCase()}`;
    },

    // Relays only see this digest, so members' self-sync wraps don't share a d-tag exposing group membership.
    async _syncOuterDTag(dTag) {
        const data = new TextEncoder().encode(`${this.pubkey}:${dTag}`);
        const buf = await crypto.subtle.digest('SHA-256', data);
        const b = new Uint8Array(buf);
        let s = '';
        for (let i = 0; i < b.length; i++) s += b[i].toString(16).padStart(2, '0');
        return s;
    },

    // Opaque so the row key can't be joined across members to reveal group membership.
    async _d1Category(dTag) {
        return `nymchat-${await this._syncOuterDTag('d1:' + dTag)}`;
    },

    // Clear the ephemeral keys (security-relevant) but keep history wraps so the user's backlog stays in D1.
    _clearGroupSyncData(groupId) {
        try { this._saveSettingsBlobToD1(this._groupSyncDTag('nymchat-keys', groupId), JSON.stringify({})); } catch (_) { }
    },

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

    // Coalesces rapid state changes (e.g. incoming group messages) into a single Nostr publish.
    _debouncedNostrSettingsSave(delayMs = 5000) {
        if (this._applyingRemoteSettings) return;
        if (this._restoreFromD1Depth > 0) return;
        if (this._settingsSaveTimer) clearTimeout(this._settingsSaveTimer);
        this._settingsSaveTimer = setTimeout(() => {
            this._settingsSaveTimer = null;
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        }, delayMs);
    },

    // Flushes one reconcile save if a save was suppressed while loading.
    _markSettingsHydrated() {
        if (this._settingsHydrated) return;
        this._settingsHydrated = true;
        if (this._settingsSavePending) {
            this._settingsSavePending = false;
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        } else {
            // Snapshot so a no-op background save won't re-publish and trigger a self-echo reload.
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
        if (typeof this.maybePromptEncryptAtRest === 'function') {
            setTimeout(() => { try { this.maybePromptEncryptAtRest(); } catch (_) { } }, 2500);
        }
    },

    // Device-spanning flags (tutorial seen, bot welcome sent) must apply before onboarding decides.
    _onSettingsHydrated(cb) {
        if (typeof cb !== 'function') return;
        if (this._settingsHydrated) { try { cb(); } catch (_) { } return; }
        if (!this._onHydratedCbs) this._onHydratedCbs = [];
        this._onHydratedCbs.push(cb);
    },

    // Hydration waits for the applied settings so device-spanning flags land before the tutorial decides.
    _flushSettingsLoadBuffer(subId) {
        const buf = (this._settingsLoadBuffer && subId) ? this._settingsLoadBuffer.get(subId) : null;
        if (buf) this._settingsLoadBuffer.delete(subId);
        // Sections are authoritative; legacy blob only when none exist; apply oldest-to-newest.
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
        this._markSettingsHydrated();
    },

    _buildGroupConversationsSync() {
        if (!this.groupConversations || this.groupConversations.size === 0) return null;
        const data = {};
        for (const [groupId, group] of this.groupConversations) {
            data[groupId] = {
                name: group.name,
                members: group.members,
                lastMessageTime: group.lastMessageTime,
                createdBy: group.createdBy,
                admins: Array.isArray(group.admins) ? group.admins : [],
                genesisOwner: group.genesisOwner || null,
                genesisNonce: group.genesisNonce || null,
                mods: Array.isArray(group.mods) ? group.mods : [],
                banned: Array.isArray(group.banned) ? group.banned : [],
                banner: group.banner || null,
                avatar: group.avatar || null,
                description: group.description || null,
                allowMemberInvites: group.allowMemberInvites !== false,
                inviteEnabled: group.inviteEnabled === true,
                inviteEpoch: group.inviteEpoch || 0,
                shareHistory: group.shareHistory === true,
                metaUpdatedAt: group.metaUpdatedAt || 0,
                metaUpdatedBy: group.metaUpdatedBy || null,
                modLog: Array.isArray(group.modLog) ? group.modLog.slice(-50) : []
            };
        }
        return data;
    },

    // No per-group cap: history is time-bucketed into month-sized gift wraps at publish time.
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

    // YYYYMM bucket id for a unix-seconds timestamp.
    _historyBucketId(tsSeconds) {
        const d = new Date((tsSeconds || 0) * 1000);
        return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
    },

    _nip44PaddedLen(len) {
        if (len <= 32) return 32;
        const nextPower = 1 << (Math.floor(Math.log2(len - 1)) + 1);
        const chunk = nextPower <= 256 ? 32 : nextPower / 8;
        return chunk * (Math.floor((len - 1) / chunk) + 1);
    },

    // NIP-44 v2 payload length: base64(version | nonce | ciphertext | mac).
    _nip44PayloadLen(plaintextBytes) {
        const raw = 1 + 32 + (2 + this._nip44PaddedLen(plaintextBytes)) + 32;
        return Math.ceil(raw / 3) * 4;
    },

    // Exact: prefix + base64url 1088-byte KEM ciphertext + dot + base64url AEAD (inner + 16-byte tag).
    _pq2PayloadLen(innerLen) {
        const b64u = (n) => Math.ceil(n * 4 / 3);
        return PQ2_PREFIX_LEN + b64u(ML_KEM_CIPHERTEXT_BYTES) + 1 + b64u(innerLen + 16);
    },

    // pq2 adds ~1.5 KB and inflates both layers by a third, so budget against it or shards overflow.
    _wrappedSizeForRumor(rumorBytes, pq2 = false) {
        const SEAL_OVERHEAD = 200;   // kind/created_at/tags/pubkey/id/sig
        const WRAP_OVERHEAD = 320;   // same, plus the p/d/k tags added here
        const layer = (n) => pq2
            ? this._pq2PayloadLen(this._nip44PayloadLen(n))
            : this._nip44PayloadLen(n);
        const sealJson = layer(rumorBytes) + SEAL_OVERHEAD;
        return layer(sealJson) + WRAP_OVERHEAD + 10;
    },

    // Largest rumor whose wrapped event still clears the relay gate; memoized.
    _maxRumorBytesForWrap(limit = 65000, pq2 = false) {
        if (!this._maxRumorCache) this._maxRumorCache = {};
        const key = `${limit}:${pq2 ? 2 : 0}`;
        const hit = this._maxRumorCache[key];
        if (hit) return hit;
        let lo = 32, hi = 64 * 1024, best = 32;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            if (this._wrappedSizeForRumor(mid, pq2) <= limit) { best = mid; lo = mid + 1; }
            else hi = mid - 1;
        }
        this._maxRumorCache[key] = best;
        return best;
    },

    // Whether a self-addressed wrap published now will carry the pq2 layer.
    _selfWrapUsesPq2() {
        return !!(typeof this.pqSelfKeyFor === 'function' && this.pqSelfKeyFor()
            && typeof this.pqSelfUsesPq2 === 'function' && this.pqSelfUsesPq2());
    },

    async _publishCategoryWrap(payload, dTag, createdAt, trimFns) {
        const RUMOR_OVERHEAD = 256;
        const MAX_RUMOR_BYTES =
            this._maxRumorBytesForWrap(65000, this._selfWrapUsesPq2());
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
            return false;
        }

        // Skip byte-identical republishes so unchanged sections don't flood relays with sync wraps.
        if (!this._publishedSectionJson) this._publishedSectionJson = {};
        const finalJson = JSON.stringify(payload);
        if (this._publishedSectionJson[dTag] === finalJson) return false;

        // Mark as published only after it succeeds, so a failed write is retried.
        const ok = await this._publishWrappedNostrEvent(payload, dTag, createdAt);
        if (!ok) {
            delete this._publishedSectionJson[dTag];
            return false;
        }
        this._publishedSectionJson[dTag] = finalJson;
        // Only ping other devices when something changed.
        return true;
    },

    // A write replaces the whole row, so carry forward keys this client doesn't know about.
    _mergeUnknownSectionKeys(dTag, payload) {
        const prev = this._lastInboundSections && this._lastInboundSections[dTag];
        if (!prev || typeof prev !== 'object') return payload;
        const out = { ...payload };
        for (const [k, v] of Object.entries(prev)) {
            if (k === 'v' || k === '__cat') continue;
            if (!(k in out)) out[k] = v;
        }
        return out;
    },

    async _publishEncryptedSettings(settingsData) {
        // In-memory state is defaults when stored settings were unreadable; writing would destroy them.
        if (this._settingsRestoreUnreadable) return;
        // An early save on a fresh device would clobber D1/relay with defaults before the load lands.
        if (!this._settingsHydrated) {
            this._settingsSavePending = true;
            return;
        }
        const now = Math.floor(Date.now() / 1000);

        // Category data is published separately, never bundled into core settings.
        delete settingsData.groupEphemeralKeys;
        delete settingsData.groupConversations;
        delete settingsData.groupMessageHistory;
        delete settingsData.notificationHistory;
        delete settingsData.notificationLastReadTime;

        if (now > (this._lastSettingsSyncTs || 0)) {
            this._lastSettingsSyncTs = now;
            try { localStorage.setItem('nym_last_settings_sync_ts', String(now)); } catch (_) { }
        }

        // Published per group as nymchat-keys-<groupId> so one big group can't exceed the NIP-44 cap.
        if (this.groupEphemeralKeys && this.groupEphemeralKeys.size > 0) {
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

        if (this._botAnon && this._botAnon.current) {
            try {
                await this._publishCategoryWrap(
                    { botAnon: this.botAnonSerialize() },
                    'nymchat-botanon',
                    now,
                    []
                );
            } catch (_) { }
        }

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
                const BUDGET = Math.floor(
                    this._maxRumorBytesForWrap(65000, this._selfWrapUsesPq2()) * 0.628);
                const entryBytes = (g) => JSON.stringify(g).length + 80;
                const inline = {};
                const oversized = [];
                for (const [groupId, g] of Object.entries(groupConversations)) {
                    if (entryBytes(g) > BUDGET) oversized.push([groupId, g]);
                    else inline[groupId] = g;
                }
                if (Object.keys(inline).length) {
                    await this._publishCategoryWrap({ groupConversations: inline },
                        'nymchat-groups', now, [trimGroupModLogs]);
                }
                for (const [groupId, g] of oversized) {
                    const base = this._groupSyncDTag('nymchat-groups', groupId);
                    const members = Array.isArray(g.members) ? g.members : [];
                    const head = { ...g, members: [] };
                    const perShard = Math.max(1,
                        Math.floor((BUDGET - entryBytes(head)) / 70));
                    let shard = 0;
                    for (let i = 0; i < members.length; i += perShard) {
                        const chunk = members.slice(i, i + perShard);
                        const payload = shard === 0
                            ? { ...head, members: chunk }
                            : { members: chunk };
                        await this._publishCategoryWrap(
                            { groupConversations: { [groupId]: payload } },
                            `${base}-${shard}`, now, [trimGroupModLogs]);
                        shard++;
                    }
                }
            }
        } catch (_) { }

        // nymchat-history-<groupId>-<YYYYMM>-<shard>: month buckets packed into byte-bounded shards.
        try {
            const groupMessageHistory = this._buildGroupHistorySync();
            if (groupMessageHistory) {
                // The rumor carries JSON escaped; 0.628 of the (PQ-dependent) rumor ceiling leaves room for escaping.
                const SHARD_BUDGET = Math.floor(
                    this._maxRumorBytesForWrap(65000, this._selfWrapUsesPq2()) * 0.628);
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

        // Notification history + seen keys -> nymchat-notifications.
        try {
            const notificationHistory = this._serialiseNotificationsForSync();
            const lastRead = this.notificationLastReadTime || 0;
            this._pruneSeenNotificationKeys();
            const seenNotifications = (this.seenNotificationKeys && this.seenNotificationKeys.size > 0)
                ? Object.fromEntries(this.seenNotificationKeys)
                : null;
            if (notificationHistory.length > 0 || lastRead > 0 || seenNotifications) {
                const trimOldestNotifications = (p) => {
                    const arr = p.notificationHistory;
                    if (!Array.isArray(arr) || arr.length <= 1) return false;
                    p.notificationHistory = arr.slice(Math.max(1, Math.ceil(arr.length * 0.1)));
                    return true;
                };
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
        const changed = [];
        for (const [section, rawPayload] of Object.entries(sections)) {
            const dTag = `nymchat-settings-${section}`;
            const payload = this._mergeUnknownSectionKeys(dTag, rawPayload);
            // Bound: the trimmer reads channelLastActivity to decide what to drop.
            const trimFns = section === 'channels'
                ? [this._trimChannelsReadState.bind(this)]
                : null;
            if (await this._publishCategoryWrap(payload, dTag, now, trimFns)) {
                changed.push(section);
            }
        }
        await this._publishSettingsChangedPing(changed, now);
    },

    _onSettingsChangedPing(ping, rumorTs) {
        if (!ping || typeof ping !== 'object') return;
        if (ping.src && ping.src === this._syncInstanceId()) return;
        if (this._applyingRemoteSettings) return;

        const ts = Number(ping.ts) || rumorTs || 0;
        if (ts && ts <= (this._lastSyncPingTs || 0)) return;
        this._lastSyncPingTs = ts;

        if (this._syncPingTimer) clearTimeout(this._syncPingTimer);
        this._syncPingTimer = setTimeout(async () => {
            this._syncPingTimer = null;
            try {
                if (typeof this.settingsLoadFromD1 === 'function') {
                    await this.settingsLoadFromD1();
                }
            } catch (_) {
                // A failed pull just leaves the next scheduled read to catch up.
            }
        }, 1200);
    },

    // Session-scoped id so a device ignores the echo of its own ping.
    _syncInstanceId() {
        if (!this.__syncInstanceId) {
            this.__syncInstanceId = Math.random().toString(36).slice(2) +
                Date.now().toString(36);
        }
        return this.__syncInstanceId;
    },

    async _publishSettingsChangedPing(sections, createdAt) {
        if (!Array.isArray(sections) || sections.length === 0) return;
        if (!this.pubkey) return;
        try {
            await this._publishWrappedNostrEvent(
                { src: this._syncInstanceId(), sections, ts: createdAt },
                'nymchat-sync-ping',
                createdAt,
                { skipD1: true }
            );
        } catch (_) {
            // Best-effort: on failure the other device waits for its next D1 read.
        }
    },

    // Trim auto-growing state so the payload fits instead of being skipped.
    _trimChannelsReadState(p) {
        const joined = p.userJoinedChannels;
        if (Array.isArray(joined) && joined.length > 20) {
            const activity = this.channelLastActivity instanceof Map
                ? this.channelLastActivity
                : new Map();
            const ordered = [...joined].sort(
                (a, b) => (activity.get(a) || 0) - (activity.get(b) || 0));
            const drop = new Set(ordered.slice(0, Math.max(1, Math.floor(ordered.length * 0.25))));
            p.userJoinedChannels = joined.filter(c => !drop.has(c));
            return true;
        }

        const pairs = [['closedPMs', 'closedPMTimes'], ['leftGroups', 'leftGroupTimes']];
        for (const [setKey, timeKey] of pairs) {
            const arr = p[setKey];
            const times = (p[timeKey] && typeof p[timeKey] === 'object' && !Array.isArray(p[timeKey]))
                ? p[timeKey] : null;
            if (Array.isArray(arr) && arr.length > 30) {
                const ordered = [...arr].sort(
                    (a, b) => (Number(times?.[a]) || 0) - (Number(times?.[b]) || 0));
                const drop = new Set(ordered.slice(0, Math.max(1, Math.floor(ordered.length * 0.25))));
                p[setKey] = arr.filter(x => !drop.has(x));
                // Keep the companion map in step so it cannot outlive its set.
                if (times) for (const k of drop) delete times[k];
                return true;
            }
        }

        for (const key of ['closedPMTimes', 'leftGroupTimes']) {
            const m = p[key];
            if (m && typeof m === 'object' && !Array.isArray(m)) {
                const entries = Object.entries(m);
                if (entries.length > 30) {
                    entries.sort((a, b) => (Number(a[1]) || 0) - (Number(b[1]) || 0));
                    const drop = Math.max(1, Math.floor(entries.length * 0.25));
                    for (let i = 0; i < drop; i++) delete m[entries[i][0]];
                    return true;
                }
            }
        }
        return false;
    },

    _sendWrappedIfFits(wrapped, dTag) {
        if (JSON.stringify(['EVENT', wrapped]).length > 65000) {
            console.warn(`[NostrSync] ${dTag} wrapped event too large for relays; skipping publish`);
            return;
        }
        this.sendDMToRelays(['EVENT', wrapped]);
    },

    // Returns whether settings reached a durable source; false leaves the section dirty for retry.
    async _publishWrappedNostrEvent(payload, dTag, createdAt, opts = {}) {
        const NT = window.NostrTools;
        const now = createdAt || Math.floor(Date.now() / 1000);
        // Pings aren't written to D1; awaited because D1 is authoritative in proxy-pool mode.
        let d1Ok = false;
        if (!opts.skipD1) {
            try { d1Ok = await this._saveSettingsBlobToD1(dTag, JSON.stringify(payload)); }
            catch (_) { d1Ok = false; }
        } else {
            d1Ok = true;
        }
        // Durable means the source this client reads back from: D1 under proxy mode, the relay wrap in direct mode.
        const d1Available = !!(this._getApiHost && this._getApiHost());
        const durable = () => (d1Available ? d1Ok : true);

        const rumor = {
            kind: 30078,
            created_at: now,
            tags: [['d', dTag]],
            content: JSON.stringify(payload),
            pubkey: this.pubkey
        };
        rumor.id = NT.getEventHash(rumor);

        const enc = new TextEncoder();
        const rumorJson = JSON.stringify(rumor);
        if (enc.encode(rumorJson).length > 65535) {
            console.warn(`[NostrSync] ${dTag} payload exceeds NIP-44 plaintext limit; skipping publish`);
            return d1Ok;
        }

        const outerTags = [['p', this.pubkey], ['d', await this._syncOuterDTag(dTag)], ['k', 'nym-sync']];

        if (this.privkey) {
            // Returns null when the sealed plaintext outgrows what NIP-44 can carry.
            const build = (seal, wrap) => {
                const sealUnsigned = { kind: 13, content: seal(rumorJson), created_at: this.randomNow(), tags: [] };
                const sealed = NT.finalizeEvent(sealUnsigned, this.privkey);
                const sealJson = JSON.stringify(sealed);
                if (enc.encode(sealJson).length > 65535) return null;
                const ephSk = NT.generateSecretKey();
                const wrapUnsigned = {
                    kind: 1059, content: wrap(sealJson, ephSk),
                    created_at: this.randomNow(), tags: outerTags
                };
                return NT.finalizeEvent(wrapUnsigned, ephSk);
            };
            const classical = () => build(
                (pt) => NT.nip44.encrypt(pt, NT.nip44.getConversationKey(this.privkey, this.pubkey)),
                (pt, ephSk) => NT.nip44.encrypt(pt, NT.nip44.getConversationKey(ephSk, this.pubkey))
            );

            // Settings reveal more than most messages, so seal them post-quantum too.
            const selfKemPk = typeof this.pqSelfKeyFor === 'function' ? this.pqSelfKeyFor() : null;
            if (selfKemPk) {
                const NC = window.NymCrypto;
                // Layered unless a device on this account can only open the combined form (pqSelfUsesPq2).
                const pq2 = this.pqSelfUsesPq2();
                const wrapped = pq2
                    ? build(
                        (pt) => NC.pq2Encrypt(pt, this.privkey, this.pubkey, selfKemPk),
                        (pt, ephSk) => NC.pq2Encrypt(pt, ephSk, this.pubkey, selfKemPk)
                    )
                    : build(
                        (pt) => NC.pqEncrypt(pt, this.privkey, this.pubkey, selfKemPk),
                        (pt, ephSk) => NC.pqEncrypt(pt, ephSk, this.pubkey, selfKemPk)
                    );
                // The ~1.5 KB/layer KEM overhead can exceed the relay cap; fall back rather than skip the sync.
                if (wrapped && JSON.stringify(['EVENT', wrapped]).length <= 65000) {
                    this.sendDMToRelays(['EVENT', wrapped]);
                    return durable();
                }
                if (wrapped) {
                    console.warn(`[NostrSync] ${dTag} too large for a post-quantum wrap; falling back to NIP-44`);
                }
            }

            const wrapped = classical();
            if (!wrapped) {
                console.warn(`[NostrSync] ${dTag} sealed payload exceeds NIP-44 plaintext limit; skipping publish`);
                return d1Ok;
            }
            this._sendWrappedIfFits(wrapped, dTag);
            return durable();
        }

        const useExt = !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent);
        const useN46 = this.nostrLoginMethod === 'nip46' && _nip46State && _nip46State.connected;
        // No signer can seal a relay wrap; the D1 row is authoritative, so its result decides.
        if (!useExt && !useN46) return d1Ok;

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
            return d1Ok;
        }
        const ephSk = NT.generateSecretKey();
        const ckWrap = NT.nip44.getConversationKey(ephSk, this.pubkey);
        const wrapContent = NT.nip44.encrypt(sealJson, ckWrap);
        const wrapUnsigned = { kind: 1059, content: wrapContent, created_at: this.randomNow(), tags: outerTags };
        const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);
        this._sendWrappedIfFits(wrapped, dTag);
        return durable();
    },

    // Encrypts to self via local nsec, NIP-07 or NIP-46; post-quantum where possible (harvest-now-decrypt-later).
    async _encryptSettingsBlob(plaintext, opts) {
        const NT = window.NostrTools;
        const NC = window.NymCrypto;
        // Not a fallback: for the root category this is required (spec §5.1).
        const classicalOnly = !!(opts && opts.classical);
        const selfKemPk = (!classicalOnly && typeof this.pqSelfKeyFor === 'function')
            ? this.pqSelfKeyFor() : null;
        const usePq2 = !!selfKemPk && typeof this.pqSelfUsesPq2 === 'function'
            && this.pqSelfUsesPq2();
        try {
            if (this.privkey) {
                if (selfKemPk) {
                    try {
                        return usePq2
                            ? NC.pq2Encrypt(plaintext, this.privkey, this.pubkey, selfKemPk)
                            : NC.pqEncrypt(plaintext, this.privkey, this.pubkey, selfKemPk);
                    } catch (_) { /* fall through to NIP-44 */ }
                }
                const ck = NT.nip44.getConversationKey(this.privkey, this.pubkey);
                return NT.nip44.encrypt(plaintext, ck);
            }
            // Signer logins: NIP-44 from the signer, then our own ML-KEM layer around it.
            const inner = await this._signerEncryptToSelf(plaintext);
            if (inner == null) return null;
            if (!usePq2) return inner;
            try {
                return NC.pq2Seal(inner, this.pubkey, this.pubkey, selfKemPk);
            } catch (_) { return inner; }
        } catch (_) { }
        return null;
    },

    async _signerEncryptToSelf(plaintext) {
        if (window.nostr?.nip44?.encrypt) {
            return await window.nostr.nip44.encrypt(this.pubkey, plaintext);
        }
        if (this.nostrLoginMethod === 'nip46' && typeof _nip46State !== 'undefined'
            && _nip46State && _nip46State.connected) {
            return await _nip46Encrypt(this.pubkey, plaintext);
        }
        return null;
    },

    // Reads both formats; the prefix says which, so no migration is needed.
    async _decryptSettingsBlob(ciphertext) {
        const NT = window.NostrTools;
        const NC = window.NymCrypto;
        try {
            // The layered format first: it is the only one a signer can open.
            if (NC && NC.isPq2Payload(ciphertext)) {
                const keys = typeof this.pqSelfKeys === 'function' ? this.pqSelfKeys() : null;
                const cands = typeof this.pqSelfCandidates === 'function'
                    ? this.pqSelfCandidates()
                    : [];
                const tried = cands.length
                    ? cands
                    : (keys ? [{ kemSk: keys.secretKey, kemPk: keys.publicKey }] : []);
                for (const c of tried) {
                    if (!c.kemSk) continue;
                    let inner;
                    try {
                        inner = NC.pq2Open(ciphertext, this.pubkey, this.pubkey,
                            { kemSk: c.kemSk, kemPk: c.kemPk });
                    } catch (_) { continue; }
                    try {
                        if (this.privkey) {
                            return NT.nip44.decrypt(inner,
                                NT.nip44.getConversationKey(this.privkey, this.pubkey));
                        }
                        return await this._signerDecryptFromSelf(inner);
                    } catch (_) { }
                }
                return null;
            }
            if (this.privkey) {
                if (NC && NC.isPqPayload(ciphertext)) {
                    // Try every epoch we hold keys for; pre-rotation blobs need the older keypair.
                    const keys = typeof this.pqSelfKeys === 'function' ? this.pqSelfKeys() : null;
                    const candidates = typeof this.pqUnwrapCandidates === 'function'
                        ? this.pqUnwrapCandidates([this.privkey])
                        : (keys ? [{ sk: this.privkey, kemSk: keys.secretKey, kemPk: keys.publicKey }] : []);
                    for (const c of candidates) {
                        if (!c.kemSk) continue;
                        try {
                            return NC.pqDecrypt(ciphertext, this.pubkey, c);
                        } catch (_) { }
                    }
                    return null;
                }
                const ck = NT.nip44.getConversationKey(this.privkey, this.pubkey);
                return NT.nip44.decrypt(ciphertext, ck);
            }
            return await this._signerDecryptFromSelf(ciphertext);
        } catch (_) { }
        return null;
    },

    async _signerDecryptFromSelf(ciphertext) {
        if (window.nostr?.nip44?.decrypt) {
            return await window.nostr.nip44.decrypt(this.pubkey, ciphertext);
        }
        if (this.nostrLoginMethod === 'nip46' && typeof _nip46State !== 'undefined'
            && _nip46State && _nip46State.connected) {
            return await _nip46Decrypt(this.pubkey, ciphertext);
        }
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

    // pq root recovery wraps. docs/PQ-ROOT-SPEC.md §5–§7.

    PQ_ROOT_CATEGORY: NYM_PQ_ROOT_CATEGORY,

    // Checked by d-tag, before it is hashed into an opaque D1 column.
    _isPqRootCategory(dTag) {
        return dTag === NYM_PQ_ROOT_CATEGORY;
    },

    // Decided without decrypting: a row we cannot read is still proof a root exists.
    async _pqRootRowPresent(cats) {
        return !!(await this._pqRootRowBlob(cats));
    },

    async _pqRootRowBlob(cats) {
        if (!cats || typeof cats !== 'object') return null;
        let hashed = null;
        try { hashed = await this._d1Category(NYM_PQ_ROOT_CATEGORY); } catch (_) { }
        for (const name of [hashed, NYM_PQ_ROOT_CATEGORY]) {
            if (!name) continue;
            const entry = cats[name];
            if (entry && typeof entry.blob === 'string' && entry.blob) return entry.blob;
        }
        return null;
    },

    // Runs spec §6 against the root record; `adopted` signals retrying the rows sealed to the root.
    async _pqRootApplyFromDecoded(decoded, rowPresent, rowBlob) {
        if (typeof this.pqRootEnsure !== 'function') return { found: false, adopted: false };
        let record = null;
        // Lifted out of `decoded`: key material, not a settings payload.
        for (let i = decoded.length - 1; i >= 0; i--) {
            if (decoded[i] && decoded[i].realCat === NYM_PQ_ROOT_CATEGORY) {
                record = decoded[i].payload;
                decoded.splice(i, 1);
            }
        }
        const status = this.pqRootEnsure(record, rowPresent);
        // The boot notice fired before settings arrived, so tell the user now.
        if (status === 'locked' || status === 'generated') {
            if (typeof this.maybeShowPqUpgradeNotice === 'function') {
                try { this.maybeShowPqUpgradeNotice(); } catch (_) { }
            }
        }
        // Only §6.4 writes, plus repairing a missing record row; a locked device must never publish one.
        const NC = window.NymCrypto;
        const hybridRow = status === 'adopted' && typeof rowBlob === 'string' && !!NC
            && ((typeof NC.isPqPayload === 'function' && NC.isPqPayload(rowBlob))
                || (typeof NC.isPq2Payload === 'function' && NC.isPq2Payload(rowBlob)));
        if (status === 'generated' || status === 'publish-record' || hybridRow) {
            try { await this.pqRootPublishRecord(); } catch (_) { }
        }
        // The boot announcement went out without a key; publish the real one.
        if (status === 'adopted' || status === 'generated' || status === 'publish-record') {
            try { await this.publishPqAnnouncement(); } catch (_) { }
        }
        return {
            // A row we could not open still counts: the branch below destroys rows when it believes nothing opened.
            found: !!record || !!rowPresent,
            adopted: status === 'adopted' || status === 'generated' || status === 'publish-record'
        };
    },

    // _saveSettingsBlobToD1 forces the record classical.
    async pqRootPublishRecord(wraps) {
        if (typeof this.pqRootBuildRecord !== 'function') return false;
        const carried = Array.isArray(wraps) ? wraps : this.pqRootRecordWraps();
        const record = this.pqRootBuildRecord(carried);
        if (!record) return false;
        // Keep the in-memory copy in step so a later wrap builds on this one.
        this._pqRootRecord = record;
        return this._saveSettingsBlobToD1(NYM_PQ_ROOT_CATEGORY, JSON.stringify(record));
    },

    // The passkey-PRF seam (spec §5): the UI passes the raw PRF output; nothing else crosses this line.
    async pqRootSetPrf(prfOutput) {
        const root = typeof this.pqRoot === 'function' ? this.pqRoot() : null;
        if (!root) throw new Error('This device does not hold the post-quantum root.');
        const wrap = await window.NymCrypto.pqRootWrapPrf(root, prfOutput);
        const kept = this.pqRootRecordWraps().filter(w => w && w.kind !== 'prf');
        return this.pqRootPublishRecord(kept.concat([wrap]));
    },

    async pqRootUnlockWithPrf(prfOutput) {
        return this._pqRootUnlockWith('prf',
            (w) => window.NymCrypto.pqRootUnwrapPrf(w, prfOutput));
    },

    async _pqRootUnlockWith(kind, open) {
        const wraps = typeof this.pqRootRecordWraps === 'function' ? this.pqRootRecordWraps() : [];
        for (const w of wraps) {
            if (!w || w.kind !== kind) continue;
            let root = null;
            try { root = await open(w); } catch (_) { continue; }
            if (!root) continue;
            if (!this.pqRootAdopt(root)) continue;
            this._settingsRestoreUnreadable = false;
            return true;
        }
        return false;
    },

    pqRootLinkVerdict(code) {
        const NC = window.NymCrypto;
        let bytes;
        try { bytes = NC.pqRootDecode(String(code || '').trim()); } catch (_) { return 'invalid'; }
        const rec = this._pqRootRecord;
        if (rec && rec.fp && NC.pqRootFingerprint(bytes) !== rec.fp) return 'mismatch';
        return 'ok';
    },

    // Checked against the record's fingerprint so a code from another identity is refused.
    pqRootLinkWithCode(code) {
        const NC = window.NymCrypto;
        let bytes;
        try { bytes = NC.pqRootDecode(String(code || '').trim()); } catch (_) { return false; }
        const rec = this._pqRootRecord;
        if (rec && rec.fp && NC.pqRootFingerprint(bytes) !== rec.fp) return false;
        if (!this.pqRootAdopt(bytes)) return false;
        this._settingsRestoreUnreadable = false;
        this._pqRootSettled = true;
        if (typeof this._pqRootClearRetry === 'function') this._pqRootClearRetry();
        if (!rec && this._pqRootRowUnreadable) {
            this._pqRootRowUnreadable = false;
            this._pqRootPendingPublish = this.pqRootPublishRecord([]).catch(() => false);
        }
        return true;
    },

    async pqRootReplaceWithCode(code) {
        const NC = window.NymCrypto;
        let bytes;
        try { bytes = NC.pqRootDecode(String(code || '').trim()); } catch (_) { return false; }
        if (!this.pubkey || !this.pqRootAdopt(bytes)) return false;
        this._pqRootRecord = null;
        this._pqRootRowUnreadable = false;
        this._pqRootSettled = true;
        this._settingsRestoreUnreadable = false;
        if (typeof this._pqRootClearRetry === 'function') this._pqRootClearRetry();
        try {
            const category = await this._d1Category(NYM_PQ_ROOT_CATEGORY);
            this._clearSettingsContentHashes([category]);
        } catch (_) { }
        const written = await this.pqRootPublishRecord([]);
        if (!written) return false;
        try { await this.publishPqAnnouncement(); } catch (_) { }
        await this.reloadSettingsAfterPqLink();
        return true;
    },

    // Drops content hashes first so a byte-identical republish under the new key isn't skipped.
    async reloadSettingsAfterPqLink() {
        if (this._pqRootPendingPublish) {
            try { await this._pqRootPendingPublish; } catch (_) { }
            this._pqRootPendingPublish = null;
        }
        try {
            for (const k of Object.keys(localStorage)) {
                if (k.startsWith(`nym_settings_hash_${this.pubkey}_`)) {
                    try { localStorage.removeItem(k); } catch (_) { }
                }
            }
        } catch (_) { }
        this._settingsRestoreUnreadable = false;
        try { await this.settingsLoadFromD1(); } catch (_) { }
    },

    async _saveSettingsBlobToD1(dTag, plaintext) {
        if (!this.pubkey) return false;
        // See _publishEncryptedSettings: never write over rows we could not read.
        if (this._settingsRestoreUnreadable) return false;
        try {
            // The real category rides in the encrypted blob so the D1 column can be an opaque hash.
            let toStore = plaintext;
            try {
                const obj = JSON.parse(plaintext);
                if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
                    obj.__cat = dTag;
                    toStore = JSON.stringify(obj);
                }
            } catch (_) { }

            const category = await this._d1Category(dTag);
            const classical = this._isPqRootCategory(dTag);
            // The mode is in the hash basis so a policy flip forces a rewrite.
            const mode = (!classical && typeof this.pqSelfKeyFor === 'function' && this.pqSelfKeyFor())
                ? 'pq' : 'c';
            const hash = await this._sha256Hex(`${this.pubkey}|${mode}|${toStore}`);
            const hashKey = `nym_settings_hash_${this.pubkey}_${category}`;
            if (hash) {
                let lastHash = null;
                try { lastHash = localStorage.getItem(hashKey); } catch (_) { }
                if (lastHash === hash) return true; // unchanged — nothing to write
            }
            const blob = await this._encryptSettingsBlob(toStore, { classical });
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

    _syncReadStateToD1(immediate = false) {
        if (!this.pubkey) return;
        if (!this._getApiHost || !this._getApiHost()) return;
        const flush = () => {
            this._readStateSyncTimer = null;
            if (!this.channelLastRead || this.channelLastRead.size === 0) return;
            let entries = [];
            for (const [k, v] of this.channelLastRead) {
                if (typeof k === 'string' && typeof v === 'number' && v > 0) entries.push([k, v]);
            }
            if (entries.length === 0) return;
            // Bound the payload: keep the most-recently-read conversations.
            const MAX_ENTRIES = 2000;
            if (entries.length > MAX_ENTRIES) {
                entries.sort((a, b) => b[1] - a[1]);
                entries.length = MAX_ENTRIES;
            }
            const channelLastRead = {};
            for (const [k, v] of entries) channelLastRead[k] = v;
            this._saveSettingsBlobToD1('nymchat-readstate', JSON.stringify({ channelLastRead }));
        };
        if (immediate) {
            if (this._readStateSyncTimer) { clearTimeout(this._readStateSyncTimer); this._readStateSyncTimer = null; }
            flush();
            return;
        }
        if (this._readStateSyncTimer) return;
        this._readStateSyncTimer = setTimeout(flush, 5000);
    },

    // Returns 'loaded', 'empty' (no rows), or 'failed' (no answer or unreadable; saving stays off).
    settingsLoadFromD1() {
        const pubkey = this.pubkey;
        if (!pubkey) return Promise.resolve('failed');
        const inflight = this._settingsLoadInFlight;
        if (inflight && inflight.pubkey === pubkey) return inflight.promise;
        const promise = this._settingsLoadFromD1Run(pubkey).finally(() => {
            if (this._settingsLoadInFlight && this._settingsLoadInFlight.promise === promise) {
                this._settingsLoadInFlight = null;
            }
        });
        this._settingsLoadInFlight = { pubkey, promise };
        return promise;
    },

    async _settingsLoadFromD1Run(pubkey) {
        let data;
        try {
            data = await this._storageApiRequest('settings-get', {});
        } catch (_) {
            return 'failed';
        }
        if (this.pubkey !== pubkey) return 'failed';
        const cats = data && data.categories;
        if (!cats || typeof cats !== 'object') return 'failed';

        // Real category rides inside the blob as __cat; legacy rows fall back to the cleartext column.
        const decoded = [];
        let storedBlobs = 0;
        const pending = [];
        const decodeOne = async ([cat, entry]) => {
            try {
                const plain = await this._decryptSettingsBlob(entry.blob);
                if (!plain) return false;
                const payload = JSON.parse(plain);
                if (!payload || typeof payload !== 'object') return false;
                const realCat = typeof payload.__cat === 'string' ? payload.__cat : cat;
                delete payload.__cat;
                // Kept so a later write can carry forward unknown keys (_mergeUnknownSectionKeys).
                if (!this._lastInboundSections) this._lastInboundSections = {};
                this._lastInboundSections[realCat] = { ...payload };
                decoded.push({ realCat, payload, updatedAt: entry.updatedAt || 0 });
                return true;
            } catch (_) { return false; }
        };

        for (const [cat, entry] of Object.entries(cats)) {
            if (!entry || !entry.blob) continue;
            storedBlobs++;
            if (!await decodeOne([cat, entry])) pending.push([cat, entry]);
        }
        if (this.pubkey !== pubkey) return 'failed';

        // Other categories may be sealed to the root key; adopt the classical root row, then retry failures.
        const rootRow = await this._pqRootApplyFromDecoded(
            decoded, await this._pqRootRowPresent(cats), await this._pqRootRowBlob(cats));
        if (rootRow.adopted && pending.length) {
            const retry = pending.splice(0, pending.length);
            for (const e of retry) { if (!await decodeOne(e)) pending.push(e); }
        }

        if (storedBlobs === 0) {
            // A fresh account has to be able to save, so this is not a failure.
            this._settingsRestoreUnreadable = false;
            return 'empty';
        }

        // The root row still counts as "something opened".
        if (decoded.length === 0 && !rootRow.found) {
            // With a local nsec, unopenable rows are final; let the next save replace them.
            if (this.privkey) {
                this._settingsRestoreUnreadable = false;
                this._clearSettingsContentHashes(Object.keys(cats));
                console.warn(`[NostrSync] ${storedBlobs} stored settings categories cannot be decrypted `
                    + 'with this identity; they will be replaced on the next save');
                return 'empty';
            }
            // A signer may be slow or locked, so this is transient; keep saving off.
            this._settingsRestoreUnreadable = true;
            console.warn(`[NostrSync] ${storedBlobs} stored settings categories could not be decrypted; `
                + 'saving is disabled until a load succeeds so they are not overwritten');
            return 'failed';
        }

        // Something opened, so whatever blocked an earlier attempt is over.
        this._settingsRestoreUnreadable = false;

        // Rows sealed to an unreachable root are recoverable by linking, so keep saving off.
        if (pending.length && typeof this.pqRootLocked === 'function' && this.pqRootLocked()) {
            this._settingsRestoreUnreadable = true;
            console.warn(`[NostrSync] ${pending.length} settings categories are sealed to a `
                + 'post-quantum root this device does not hold; saving is disabled until it is linked');
        }

        const isCore = (c) => c === 'nymchat-settings' || c.startsWith('nymchat-settings-');

        // Non-core additive categories first so lists exist before core settings.
        for (const d of decoded) {
            if (isCore(d.realCat)) continue;
            try { await applyNostrSettingsAdditive(d.payload); } catch (_) { }
        }

        // Apply sections oldest-to-newest; legacy monolithic blob only when no sections exist.
        const coreEntries = decoded.filter(d => isCore(d.realCat));
        const sectionEntries = coreEntries
            .filter(d => d.realCat !== 'nymchat-settings')
            .sort((a, b) => (a.updatedAt || 0) - (b.updatedAt || 0));
        const toApply = sectionEntries.length
            ? sectionEntries
            : coreEntries.filter(d => d.realCat === 'nymchat-settings');
        // Per-section on purpose: it merges lists by union.
        let coreApplied = 0, newestCoreTs = 0;
        const merged = {};
        for (const d of toApply) {
            try {
                await applyNostrSettingsAdditive(d.payload);
                // Sections are disjoint (bar `v`), so a newest-last merge equals applying them in order.
                Object.assign(merged, d.payload);
                coreApplied++;
                const ts = d.updatedAt ? Math.floor(d.updatedAt / 1000) : Math.floor(Date.now() / 1000);
                if (ts > newestCoreTs) newestCoreTs = ts;
            } catch (_) { }
        }
        // One apply, not one per section: applyNostrSettings is the costliest boot-path call.
        if (coreApplied > 0) {
            try { await applyNostrSettings(merged); } catch (_) { coreApplied = 0; }
        }

        // Non-core rows were read, so a save carries them forward.
        if (coreApplied === 0) return 'empty';
        if (newestCoreTs > (this._lastSettingsSyncTs || 0)) {
            this._lastSettingsSyncTs = newestCoreTs;
            try { localStorage.setItem('nym_last_settings_sync_ts', String(newestCoreTs)); } catch (_) { }
        }
        // D1 had real settings and we applied them, so saving is safe from here.
        this._markSettingsHydrated();
        return 'loaded';
    },

    // Unreadable rows invalidate the hash gate, which could skip the recovering write.
    _clearSettingsContentHashes(categories) {
        if (!this.pubkey || !Array.isArray(categories)) return;
        for (const category of categories) {
            try { localStorage.removeItem(`nym_settings_hash_${this.pubkey}_${category}`); } catch (_) { }
        }
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
            // Wallpaper patterns tint themselves from these RGB components.
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
        return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
    },

    applyColorMode(mode) {
        const resolved = mode || this.resolveColorMode();
        if (resolved === 'light') {
            document.body.classList.add('light-mode');
        } else {
            document.body.classList.remove('light-mode');
        }
        this.applyTheme(this.settings.theme);

        this.loadWallpaper();

        const themeColor = resolved === 'light' ? '#f5f5f2' : '#000000';
        const metaTheme = document.querySelector('meta[name="theme-color"]');
        if (metaTheme) {
            metaTheme.content = themeColor;
        }

        // Keep the Flutter shell's native status bar in sync with the app theme.
        try {
            if (window.FlutterTheme && typeof window.FlutterTheme.postMessage === 'function') {
                window.FlutterTheme.postMessage(JSON.stringify({
                    backgroundColor: themeColor,
                    isLightMode: resolved === 'light'
                }));
            }
        } catch (_) {}
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
        for (const k of ['nym_auto_translate', 'nym_auto_translate_channels', 'nym_auto_translate_pms', 'nym_auto_translate_groups']) {
            try { localStorage.removeItem(k); } catch (_) { }
        }
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
            threadsEnabled: localStorage.getItem('nym_threads_enabled') !== 'false',
            translateLanguage: localStorage.getItem('nym_translate_language') || '',
            uiLanguage: localStorage.getItem('nym_ui_language') || '',
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
        // Per-pubkey key first, then the global key (ephemeral pubkeys change each session); true, false, or 'friends'.
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
        return true;
    },

    saveImageBlurSettings() {
        // Always save a global key so ephemeral users keep their preference.
        const val = String(this.blurOthersImages);
        localStorage.setItem('nym_image_blur', val);
        if (this.pubkey) {
            localStorage.setItem(`nym_image_blur_${this.pubkey}`, val);
        }
    },

    reapplyImageBlur() {
        document.querySelectorAll('.message img').forEach(img => {
            if (img.classList.contains('custom-emoji')) return;
            // Inline mention/quote avatars are UI chrome, not posted media; never blur them.
            if (img.classList.contains('avatar-message')) return;
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
        const powDifficulty = (typeof normalizePowDifficulty === 'function')
            ? normalizePowDifficulty(document.getElementById('powDifficultySelect').value)
            : parseInt(document.getElementById('powDifficultySelect').value);
        this.powDifficulty = powDifficulty;
        this.enablePow = powDifficulty > 0;
        localStorage.setItem('nym_pow_difficulty', powDifficulty.toString());
        const packBoxes = document.querySelectorAll('[data-filter-pack]');
        if (packBoxes.length && typeof this.setFilterPacks === 'function') {
            this.setFilterPacks(Array.from(packBoxes)
                .filter((b) => b.checked)
                .map((b) => b.dataset.filterPack));
        }
        const appVerifiedEl = document.getElementById('appVerifiedSelect');
        if (appVerifiedEl) {
            const mode = (typeof normalizeAppVerifiedFilter === 'function')
                ? normalizeAppVerifiedFilter(appVerifiedEl.value) : 'off';
            this.appVerifiedFilter = mode;
            localStorage.setItem('nym_app_verified_filter', mode);
        }
    },

});
