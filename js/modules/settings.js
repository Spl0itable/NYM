// settings.js - User settings: load/save, sync to Nostr, theme/color mode, image blur
// Methods are attached to NYM.prototype.

Object.assign(NYM.prototype, {

    async saveSyncedSettings() {
        if (!this.pubkey) return;

        // Skip sync for hardcore mode (keypair changes every message) and random-per-session
        if (this.connectionMode === 'ephemeral') {
            const keypairMode = localStorage.getItem('nym_keypair_mode') || (localStorage.getItem('nym_random_keypair_per_session') === 'true' ? 'random' : 'persistent');
            if (keypairMode === 'random' || keypairMode === 'hardcore') return;
        }

        try {
            const settingsData = this._buildSettingsPayload();

            // Include group conversations directly in the payload
            try {
                if (this.groupConversations && this.groupConversations.size > 0) {
                    const groupData = {};
                    for (const [groupId, group] of this.groupConversations) {
                        groupData[groupId] = {
                            name: group.name,
                            members: group.members,
                            lastMessageTime: group.lastMessageTime,
                            createdBy: group.createdBy
                        };
                    }
                    settingsData.groupConversations = groupData;
                }
            } catch (_) { }

            // Include ephemeral keys for timing-attack mitigation sync.
            // Keys are stored encrypted (settings are gift-wrapped to self).
            try {
                if (this.groupEphemeralKeys && this.groupEphemeralKeys.size > 0) {
                    const ekData = {};
                    for (const [groupId, ek] of this.groupEphemeralKeys) {
                        ekData[groupId] = this._serializeEphemeralKeys(ek);
                    }
                    settingsData.groupEphemeralKeys = ekData;
                }
            } catch (_) { }

            // Include group message history backup for new-device recovery
            try {
                if (this.pmMessages && this.pmMessages.size > 0) {
                    const historyData = {};
                    for (const [convKey, messages] of this.pmMessages) {
                        if (convKey.startsWith('group-') && messages.length > 0) {
                            historyData[convKey] = messages.slice(-200).map(m => ({
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
                    if (Object.keys(historyData).length > 0) {
                        settingsData.groupMessageHistory = historyData;
                    }
                }
            } catch (_) { }

            await this._publishEncryptedSettings(settingsData);
        } catch (error) {
        }
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
            readReceiptsEnabled: this.settings.readReceiptsEnabled !== false,
            typingIndicatorsEnabled: this.settings.typingIndicatorsEnabled !== false,
            pinnedLandingChannel: this.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' },
            chatLayout: this.settings.chatLayout || 'irc',
            nickStyle: this.settings.nickStyle || 'fancy',
            colorMode: localStorage.getItem('nym_color_mode') || 'auto',
            wallpaperType: localStorage.getItem('nym_wallpaper_type') || 'geometric',
            wallpaperCustomUrl: localStorage.getItem('nym_wallpaper_custom_url') || '',
            powDifficulty: parseInt(localStorage.getItem('nym_pow_difficulty') || '0', 10),
            hideNonPinned: localStorage.getItem('nym_hide_non_pinned') === 'true',
            textSize: this.settings.textSize || parseInt(localStorage.getItem('nym_text_size') || '15', 10),
            lowDataMode: this.settings.lowDataMode || localStorage.getItem('nym_low_data_mode') === 'true',
            groupChatPMOnlyMode: this.settings.groupChatPMOnlyMode || false,
            translateLanguage: this.settings.translateLanguage || '',
            notificationsEnabled: this.notificationsEnabled !== false,
            groupNotifyMentionsOnly: this.groupNotifyMentionsOnly || false,
            notifyFriendsOnly: this.notifyFriendsOnly || false,
            notificationLastReadTime: this.notificationLastReadTime || 0,
            closedPMs: Array.from(this.closedPMs || []),
            leftGroups: Array.from(this.leftGroups || []),
            acceptPMs: this.settings.acceptPMs || 'enabled',
            syncMLSHistory: this.settings.syncMLSHistory !== false
        };
    },

    // Debounced nostrSettingsSave — coalesces rapid state changes (e.g. incoming
    // group messages) into a single Nostr publish.  Delay defaults to 5 seconds.
    _debouncedNostrSettingsSave(delayMs = 5000) {
        if (this._settingsSaveTimer) clearTimeout(this._settingsSaveTimer);
        this._settingsSaveTimer = setTimeout(() => {
            this._settingsSaveTimer = null;
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        }, delayMs);
    },

    // Encrypt settings into a self-addressed gift wrap (kind 1059) and publish.
    // Adds a d-tag on the outer wrap so relays can be queried for it.
    async _publishEncryptedSettings(settingsData) {
        const NT = window.NostrTools;
        const now = Math.floor(Date.now() / 1000);

        // NIP-44 max plaintext is 65535 bytes. Content is encrypted twice
        const MAX_PLAINTEXT = 28000;
        let content = JSON.stringify(settingsData);
        if (content.length > MAX_PLAINTEXT) {
            delete settingsData.groupMessageHistory;
            content = JSON.stringify(settingsData);
        }
        if (content.length > MAX_PLAINTEXT) {
            delete settingsData.groupConversations;
            content = JSON.stringify(settingsData);
        }
        if (content.length > MAX_PLAINTEXT) {
            delete settingsData.groupEphemeralKeys;
            content = JSON.stringify(settingsData);
        }

        const rumor = {
            kind: 30078,
            created_at: now,
            tags: [['d', 'nymchat-settings']],
            content,
            pubkey: this.pubkey
        };
        rumor.id = NT.getEventHash(rumor);

        const outerTags = [['p', this.pubkey], ['d', 'nymchat-settings']];

        if (this.privkey) {
            // Local privkey fast path
            const ckSeal = NT.nip44.getConversationKey(this.privkey, this.pubkey);
            const sealContent = NT.nip44.encrypt(JSON.stringify(rumor), ckSeal);
            const sealUnsigned = { kind: 13, content: sealContent, created_at: this.randomNow(), tags: [] };
            const seal = NT.finalizeEvent(sealUnsigned, this.privkey);

            const ephSk = NT.generateSecretKey();
            const ckWrap = NT.nip44.getConversationKey(ephSk, this.pubkey);
            const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
            const wrapUnsigned = {
                kind: 1059, content: wrapContent, created_at: this.randomNow(),
                tags: outerTags
            };
            const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);
            this.sendDMToRelays(['EVENT', wrapped]);
            return;
        }

        // Extension or NIP-46 remote signer path
        const useExt = !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent);
        const useN46 = this.nostrLoginMethod === 'nip46' && _nip46State && _nip46State.connected;
        if (!useExt && !useN46) return;

        const sealContent = useExt
            ? await window.nostr.nip44.encrypt(this.pubkey, JSON.stringify(rumor))
            : await _nip46Encrypt(this.pubkey, JSON.stringify(rumor));
        const sealUnsigned = { kind: 13, content: sealContent, created_at: this.randomNow(), tags: [] };
        const seal = useExt
            ? await window.nostr.signEvent(sealUnsigned)
            : await _nip46SignEvent(sealUnsigned);

        const ephSk = NT.generateSecretKey();
        const ckWrap = NT.nip44.getConversationKey(ephSk, this.pubkey);
        const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
        const wrapUnsigned = {
            kind: 1059, content: wrapContent, created_at: this.randomNow(),
            tags: outerTags
        };
        const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);
        this.sendDMToRelays(['EVENT', wrapped]);
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
        }
        this.refreshMessages();
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
        const metaTheme = document.querySelector('meta[name="theme-color"]');
        if (metaTheme) {
            metaTheme.content = resolved === 'light' ? '#f5f5f2' : '#000000';
        }
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
            pinnedLandingChannel = saved ? JSON.parse(saved) : { type: 'geohash', geohash: 'nym' };
        } catch (e) {
            pinnedLandingChannel = { type: 'geohash', geohash: 'nym' };
        }

        return {
            theme: localStorage.getItem('nym_theme') || 'bitchat',
            sound: localStorage.getItem('nym_sound') || 'beep',
            autoscroll: localStorage.getItem('nym_autoscroll') !== 'false',
            showTimestamps: localStorage.getItem('nym_timestamps') !== 'false',
            sortByProximity: localStorage.getItem('nym_sort_proximity') === 'true',
            timeFormat: localStorage.getItem('nym_time_format') || '12hr',
            dmForwardSecrecyEnabled: localStorage.getItem('nym_dm_fwdsec_enabled') === 'true',
            dmTTLSeconds: parseInt(localStorage.getItem('nym_dm_ttl_seconds') || '86400', 10),
            readReceiptsEnabled: localStorage.getItem('nym_read_receipts_enabled') !== 'false',  // Enabled by default
            typingIndicatorsEnabled: localStorage.getItem('nym_typing_indicators_enabled') !== 'false',  // Enabled by default
            pinnedLandingChannel: pinnedLandingChannel,
            nickStyle: localStorage.getItem('nym_nick_style') || 'fancy',
            chatLayout: localStorage.getItem('nym_chat_layout') || 'bubbles',
            lowDataMode: localStorage.getItem('nym_low_data_mode') === 'true',
            textSize: parseInt(localStorage.getItem('nym_text_size') || '15', 10),
            groupChatPMOnlyMode: localStorage.getItem('nym_groupchat_pm_only_mode') === 'true',
            translateLanguage: localStorage.getItem('nym_translate_language') || '',
            performanceMode: localStorage.getItem('nym_performance_mode') || 'auto',
            acceptPMs: localStorage.getItem('nym_accept_pms') || 'enabled',
            syncMLSHistory: localStorage.getItem('nym_sync_mls_history') !== 'false' // default true
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
            const messageEl = img.closest('.message');
            if (messageEl && !messageEl.classList.contains('self')) {
                const pubkey = messageEl.dataset.pubkey;
                const shouldBlur = this.blurOthersImages === true ||
                    (this.blurOthersImages === 'friends' && !this.isFriend(pubkey));
                if (shouldBlur) {
                    img.classList.add('blurred');
                } else {
                    img.classList.remove('blurred');
                }
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
