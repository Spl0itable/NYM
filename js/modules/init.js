// init.js - App initialization

Object.assign(NYM.prototype, {

    _setManagedInterval(key, fn, ms) {
        if (!this._appIntervals) this._appIntervals = new Map();
        const existing = this._appIntervals.get(key);
        if (existing) clearInterval(existing);
        const id = setInterval(fn, ms);
        this._appIntervals.set(key, id);
        return id;
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
            // Check if nostr-tools is loaded
            if (typeof window.NostrTools === 'undefined') {
                throw new Error('nostr-tools not loaded');
            }

            this._appInitTime = Date.now();

            // Warm up the crypto worker pool (no-op fallback if unsupported)
            if (typeof this._ensureCryptoPool === 'function') this._ensureCryptoPool();

            // Setup event listeners
            this.setupEventListeners();
            this.setupCommands();
            this.setupContextMenu();
            this.setupMobileGestures();
            this.setupTranslateInput();
            this.populateTranslateLanguageSelect();
            this.setupSidebarSectionReorder();
            this.setupSidebarSectionCollapse();
            this.setupSidebarItemMenus();
            this.bindNymPanicGesture();

            // Load saved preferences
            this.applyColorMode();
            this.setupColorModeListener();
            this.loadBlockedUsers();
            this.loadFriends();
            this.loadBlockedKeywords();
            this.loadPinnedChannels();
            this.loadHiddenChannels();
            this.loadWallpaper();
            if (typeof this._hydrateUnreadCounts === 'function') this._hydrateUnreadCounts();
            applyMessageLayout(this.settings.chatLayout);

            // Column view: paint placeholder columns now so the strip isn't blank
            // until the real columns activate after connection.
            if (localStorage.getItem('nym_chat_view_mode') === 'columns' && typeof this._renderColumnSkeletons === 'function') {
                this._renderColumnSkeletons();
            }

            // Hydrate channel/PM/profile/reaction caches from IndexedDB
            try {
                await Promise.race([
                    this.hydrateFromCache(),
                    new Promise(r => setTimeout(r, 1500))
                ]);
            } catch (_) { }

            // Load lightning address
            await this.loadLightningAddress();

            // Clean up old localStorage format
            this.cleanupOldLightningAddress();

            // Network change detection
            this.setupNetworkMonitoring();

            // Visibility change detection
            this.setupVisibilityMonitoring();

        } catch (error) {
            this.showNotification('Error', 'Failed to initialize: ' + error.message);
        }
    },

});
