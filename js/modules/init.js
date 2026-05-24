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
        const caps = { tier: 'high', cores: 4, memory: 8, mobile: false, ios: false };
        try {
            caps.cores = navigator.hardwareConcurrency || 2;
            caps.memory = navigator.deviceMemory || 4;
            const ua = navigator.userAgent || '';
            caps.ios = /iPad|iPhone|iPod/.test(ua)
                // iPadOS 13+ reports as desktop Safari; the touch-Mac combo is the tell.
                || (ua.includes('Macintosh') && navigator.maxTouchPoints > 1);
            caps.mobile = caps.ios
                || /Android|webOS|BlackBerry|IEMobile|Opera Mini/i.test(ua)
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
        const tier = this._deviceCapabilities && this._deviceCapabilities.tier;
        const mobile = this._deviceCapabilities && this._deviceCapabilities.mobile;
        this._channelDOMCacheLimit = mobile
            ? (tier === 'low' ? 5 : tier === 'mid' ? 8 : 12)
            : (tier === 'low' ? 20 : tier === 'mid' ? 50 : 100);
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
                .then(() => {
                    this._hydrationComplete = true;
                    this._onHydrationComplete();
                    // First age-sweep after hydration; drops anything older than
                    // messageMaxAgeMs (24h) from memory, cache, and storage.
                    if (typeof this.pruneOldMessages === 'function') {
                        try { this.pruneOldMessages(); } catch (_) { }
                    }
                })
                .catch(() => { this._hydrationComplete = true; });

            // Recurring sweep — every 30 minutes the app drops anything that
            // crossed the age cutoff while the tab was open.
            if (typeof this.pruneOldMessages === 'function') {
                this._setManagedInterval('msgAgeSweep', () => {
                    try { this.pruneOldMessages(); } catch (_) { }
                }, 30 * 60 * 1000);
            }

            // Also run when the tab returns to the foreground after being
            // backgrounded for a while — covers the case where a phone sat
            // overnight on the chat screen.
            document.addEventListener('visibilitychange', () => {
                if (document.visibilityState !== 'visible') return;
                if (typeof this.pruneOldMessages === 'function') {
                    try { this.pruneOldMessages(); } catch (_) { }
                }
            });

            await this.loadLightningAddress();
            this.cleanupOldLightningAddress();
            this.setupNetworkMonitoring();
            this.setupVisibilityMonitoring();

        } catch (error) {
            this.showNotification('Error', 'Failed to initialize: ' + error.message);
        }
    },

});
