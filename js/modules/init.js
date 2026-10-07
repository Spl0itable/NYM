Object.assign(NYM.prototype, {

    _setManagedInterval(key, fn, ms) {
        if (!this._appIntervals) this._appIntervals = new Map();
        const existing = this._appIntervals.get(key);
        if (existing) clearInterval(existing);
        const id = setInterval(fn, ms);
        this._appIntervals.set(key, id);
        return id;
    },

    _clearSidebarSkel(listId) {
        const list = document.getElementById(listId);
        if (!list) return;
        list.querySelectorAll(':scope > .sidebar-skeleton').forEach(el => el.remove());
    },

    _clearNymIdentitySkel() {
        const el = document.querySelector('.nym-identity.is-loading');
        if (el) el.classList.remove('is-loading');
    },

    _clearAllSidebarSkel() {
        this._clearSidebarSkel('channelList');
        this._clearSidebarSkel('pmList');
        this._clearSidebarSkel('userListContent');
        this._clearNymIdentitySkel();
    },

    _scheduleIdle(fn, timeout = 1000) {
        if (typeof window.requestIdleCallback === 'function') {
            return window.requestIdleCallback(fn, { timeout });
        }
        if (typeof window.requestAnimationFrame === 'function') {
            return window.requestAnimationFrame(fn);
        }
        return setTimeout(fn, 0);
    },

    async initialize() {
        try {
            if (typeof window.NostrTools === 'undefined') {
                throw new Error('nostr-tools not loaded');
            }

            this._appInitTime = Date.now();

            if (typeof this._ensureCryptoPool === 'function') this._ensureCryptoPool();

            this.setupEventListeners();
            this.setupCommands();
            this.setupContextMenu();
            this.setupMobileGestures();
            this.setupTranslateInput();
            this.setupFormatToolbar();
            this.setupComposerMediaPreviews();
            if (typeof this.setupMediaNotesUI === 'function') this.setupMediaNotesUI();
            if (typeof this.setupComposerControls === 'function') this.setupComposerControls();
            this.syncComposerInlineActions();
            this.populateTranslateLanguageSelect();
            this.populateUiLanguageSelect();
            this.setupUiLanguage();
            this._maybeFirstRunLanguagePicker();
            this.setupSidebarSectionReorder();
            this.setupSidebarSectionCollapse();
            this.setupSidebarItemMenus();
            this.bindNymPanicGesture();

            this.applyColorMode();
            this.setupColorModeListener();
            this.loadBlockedUsers();
            this.loadFriends();
            this.loadBlockedKeywords();
            this.loadPinnedChannels();
            this.loadHiddenChannels();
            this.loadWallpaper();
            if (typeof this._awaitReadState === 'function' && typeof this._getApiHost === 'function' && this._getApiHost()) {
                this._awaitReadState(20000);
            }
            if (typeof this._hydrateUnreadCounts === 'function') this._hydrateUnreadCounts();
            if (typeof this.initMeshUI === 'function') this.initMeshUI();
            // Returning to the app is when to retry place names that failed earlier, including abandoned ones.
            document.addEventListener('visibilitychange', () => {
                if (document.visibilityState === 'visible' &&
                    typeof this.refreshUnresolvedPlaces === 'function') {
                    this.refreshUnresolvedPlaces(true);
                }
                if (document.visibilityState === 'visible' &&
                    typeof this._threadMarkOpenSeen === 'function') {
                    this._threadMarkOpenSeen();
                }
                if (document.visibilityState === 'hidden' &&
                    typeof this.flushPendingGroupReactions === 'function') {
                    this.flushPendingGroupReactions();
                }
            });
            applyMessageLayout(this.settings.chatLayout);

            // Paint placeholder columns now so the strip isn't blank until columns activate.
            if (localStorage.getItem('nym_chat_view_mode') === 'columns' && typeof this._renderColumnSkeletons === 'function') {
                this._renderColumnSkeletons();
            }

            // Restore dedup/skip meta sets first, unraced, so the post-connect relay replay doesn't reprocess history.
            try { await this._hydrateDedupSets(); } catch (_) { }

            try {
                await Promise.race([
                    this.hydrateFromCache(),
                    new Promise(r => setTimeout(r, 1500))
                ]);
            } catch (_) { }

            await this.loadLightningAddress();

            this.cleanupOldLightningAddress();

            this.setupNetworkMonitoring();

            this.setupVisibilityMonitoring();

            this._sidebarSkelTimer = setTimeout(() => this._clearAllSidebarSkel(), 8000);
            if (typeof this._leBindAll === 'function') this._leBindAll();

        } catch (error) {
            this.showNotification('Error', 'Failed to initialize: ' + error.message);
        }
    },

});
