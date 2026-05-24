// init.js - App initialization, device capability detection, performance mode

Object.assign(NYM.prototype, {

    _setManagedInterval(key, fn, ms) {
        if (!this._appIntervals) this._appIntervals = new Map();
        const existing = this._appIntervals.get(key);
        if (existing) clearInterval(existing);
        const id = setInterval(fn, ms);
        this._appIntervals.set(key, id);
        return id;
    },

    _clearManagedInterval(key) {
        if (!this._appIntervals) return;
        const id = this._appIntervals.get(key);
        if (id) {
            clearInterval(id);
            this._appIntervals.delete(key);
        }
    },

    _clearAllManagedIntervals() {
        if (!this._appIntervals) return;
        for (const id of this._appIntervals.values()) clearInterval(id);
        this._appIntervals.clear();
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

    _detectDeviceCapabilities() {
        const caps = { tier: 'high', cores: 4, memory: 8, mobile: false };
        try {
            caps.cores = navigator.hardwareConcurrency || 2;
            caps.memory = navigator.deviceMemory || 4;
            caps.mobile = /Android|iPhone|iPad|iPod|webOS|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
                || (navigator.maxTouchPoints > 1 && window.innerWidth <= 1024);

            if (caps.cores <= 2 || caps.memory <= 2 || (caps.mobile && caps.cores <= 4 && caps.memory <= 4)) {
                caps.tier = 'low';
            } else if (caps.cores <= 4 || caps.memory <= 4) {
                caps.tier = 'mid';
            }
        } catch (e) { /* fallback to defaults */ }
        return caps;
    },

    _applyPerformanceMode() {
        this.performanceMode = true;
        document.body.classList.add('performance-mode');
    },

    async initialize() {
        try {
            if (typeof window.NostrTools === 'undefined') {
                throw new Error('nostr-tools not loaded');
            }

            this._appInitTime = Date.now();
            this.setupEventListeners();
            this.setupCommands();
            this.setupContextMenu();
            this.setupMobileGestures();
            this.setupSidebarSectionCollapse();
            this.setupSidebarItemMenus();
            this.applyColorMode();
            this.setupColorModeListener();
            this.loadBlockedUsers();
            this.loadFriends();
            this.loadBlockedKeywords();
            this.loadBlockedChannels();
            this.loadPinnedChannels();
            this.loadHiddenChannels();
            this.loadWallpaper();
            if (typeof this._hydrateUnreadCounts === 'function') this._hydrateUnreadCounts();
            applyMessageLayout(this.settings.chatLayout);
            document.body.classList.toggle('status-hidden', this.settings.showStatus === false);

            // Defer truly optional UI scaffolding to idle
            this._scheduleIdle(() => {
                this.setupEmojiPicker();
                this.initCustomEmojis();
                this.setupTranslateInput();
                this.populateTranslateLanguageSelect();
                this.setupSidebarSectionReorder();
            }, 800);

            this._hydrationPromise = this.hydrateFromCache()
                .then(() => { this._hydrationComplete = true; this._onHydrationComplete(); })
                .catch(() => { this._hydrationComplete = true; });

            if (typeof this.loadFromIndexer === 'function') {
                this.loadFromIndexer({ includeGiftWraps: false }).catch(() => { });
            }

            await this.loadLightningAddress();
            this.cleanupOldLightningAddress();
            this.setupNetworkMonitoring();
            this.setupVisibilityMonitoring();

        } catch (error) {
            this.showNotification('Error', 'Failed to initialize: ' + error.message);
        }
    },

});
