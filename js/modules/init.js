// init.js - App initialization, device capability detection, performance mode
// Methods are attached to NYM.prototype.

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
        const caps = { tier: 'high', cores: 4, memory: 8, mobile: false, weakGPU: false };
        try {
            caps.cores = navigator.hardwareConcurrency || 2;
            caps.memory = navigator.deviceMemory || 4;
            caps.mobile = /Android|iPhone|iPad|iPod|webOS|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
                || (navigator.maxTouchPoints > 1 && window.innerWidth <= 1024);

            // Check for weak GPU via canvas test
            try {
                const canvas = document.createElement('canvas');
                const gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
                if (gl) {
                    const debugInfo = gl.getExtension('WEBGL_debug_renderer_info');
                    if (debugInfo) {
                        const renderer = gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL).toLowerCase();
                        caps.weakGPU = /swiftshader|llvmpipe|softpipe|mesa|intel.*hd(?!.*[6-9]\d{2,})/.test(renderer);
                    }
                    const ext = gl.getExtension('WEBGL_lose_context');
                    if (ext) ext.loseContext();
                }
                canvas.remove();
            } catch (e) {
                caps.weakGPU = true;
            }

            // Determine tier
            if (caps.cores <= 2 || caps.memory <= 2 || (caps.mobile && caps.cores <= 4 && caps.memory <= 4)) {
                caps.tier = 'low';
            } else if (caps.cores <= 4 || caps.memory <= 4 || caps.weakGPU) {
                caps.tier = 'mid';
            }
        } catch (e) { /* fallback to defaults */ }
        return caps;
    },

    _applyPerformanceMode() {
        const setting = this.settings.performanceMode || 'auto';
        if (setting === 'auto') {
            const prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
            this.performanceMode = this._deviceCapabilities.tier === 'low' || prefersReduced;
        } else {
            this.performanceMode = setting === 'enabled';
        }

        if (this.performanceMode) {
            document.body.classList.add('performance-mode');
        } else {
            document.body.classList.remove('performance-mode');
        }
    },

    async initialize() {
        try {
            // Check if nostr-tools is loaded
            if (typeof window.NostrTools === 'undefined') {
                throw new Error('nostr-tools not loaded');
            }

            // Setup event listeners
            this.setupEventListeners();
            this.setupCommands();
            this.setupEmojiPicker();
            this.setupContextMenu();
            this.setupMobileGestures();
            this.setupTranslateInput();

            // Load saved preferences
            this.applyColorMode();
            this.setupColorModeListener();
            this.loadBlockedUsers();
            this.loadFriends();
            this.loadBlockedKeywords();
            this.loadBlockedChannels();
            this.loadPinnedChannels();
            this.loadHiddenChannels();
            this.loadWallpaper();
            applyMessageLayout(this.settings.chatLayout);

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
