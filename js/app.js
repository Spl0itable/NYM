// Guided Tutorial
(function () {
    const state = {
        steps: [],
        idx: 0,
        started: false,
        overlay: null,
        card: null,
        highlight: null,
        elTitle: null,
        elBody: null,
        elProgress: null,
        btnPrev: null,
        btnNext: null,
        btnSkip: null,
        sidebarInitiallyOpen: null,
        _onResize: null,
        _onScroll: null
    };

    function $(sel) { return document.querySelector(sel); }

    function buildSteps() {
        state.steps = [
            {
                title: 'Nymchat Tutorial',
                body: 'Take a quick tour so you know where important functionality is across the app. You can skip anytime. And use our helpful chat bot @Nymbot or the /help command in any channel to learn more.',
                selector: null
            },
            {
                title: 'Your Nym',
                body: 'Tap here to edit the nickname, avatar, banner, bio, and Bitcoin lightning address for your Nym in this session. View the private key (nsec) of the Nym and save it if you would like to reuse this same Nym identity to login with it across devices. Long-pressing this area for 2 seconds will engage Panic Mode, which will encrypt all data with multiple throwaway Nyms, overwrite all data with junk, and logout immediately to make it difficult for anyone to access the data if you need to quickly hide and protect yourself.',
                selector: '.nym-display',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Connection',
                body: 'The current relay connection status. Tap here to view network stats such as the average latency, number of received events, and bandwidth usage.',
                selector: '.status-indicator',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Main Menu',
                body: 'Get flair addon packs to change the styling of your messages and nickname. Edit settings such as changing the app\'s theme, manage blocked users and keywords, sorting geohash channels by proximity, and much more. Logout to terminate the current session and start fresh with a new identity.',
                selector: (window.innerWidth > 768 ? '.header-actions' : '.sidebar-actions'),
                onBefore: () => { if (window.innerWidth <= 768) return ensureSidebarOpenOnMobile(); }
            },
            {
                title: 'Channels',
                body: 'Browse and switch geohash or non-geohash channels. Use the search feature to find and join geohash or non-geohash channels. Geohash is for location-based chat using geohash codes (e.g., #w1, #dr5r). These are bridged with Bitchat and can be sorted by proximity to your location. Long-press a channel to favorite it to the top of the list for easy access, or to hide/block it from the list if you don\'t want to see it.',
                selector: '#channelList',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Explore Geohash',
                body: 'Tap the globe to explore geohash-only channels on a world map. Find interesting channels to join based on location, see where other users are active, and view heatmap, day/night, and geohash grid layers showing where the most popular geohash channels are located around the world.',
                selector: '.discover-icon',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Private Messages',
                body: 'Your end-to-end encrypted one‑on‑one and group chat messages live here. Tap the + symbol to start a new PM or group chat. Long-press an existing PM or group chat to view options such as blocking the user, or to close the conversation if you want to hide it from the list.',
                selector: '#pmList',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Active Nyms',
                body: 'See who is currently active. Tap a nym to PM them and more. This list is based on recent activity and relay presence, not just who you follow. It\'s a great way to discover and connect with active people on the app!',
                selector: '#userList',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Messages',
                body: 'Channel messages appear here. Long-press a message or click on a nym\'s nickname for quick actions such as to react with emoji, edit/delete your own message, zap a Bitcoin tip, start a PM, mention, block and much more from the context menu.',
                selector: '#messagesContainer',
                onBefore: ensureSidebarClosedOnMobile
            },
            {
                title: 'Compose',
                body: 'Type your message, translate it in a different language, add emoji or GIFs, or upload images/videos, share files via P2P, and more. Markdown is supported. You can also type commands for other actions, such as creating an away message and many more. Check out all of the available commands by typing ?help to have our chat bot @Nymbot assist you or the /help command in any channel.',
                selector: '.input-container'
            },
            {
                title: 'Share',
                body: 'Invite others to a channel with a shareable link.',
                selector: '#shareChannelBtn'
            },
            {
                title: 'All set!',
                body: 'That\'s it. Enjoy Nymchat! Check out all of the available commands by typing ?help to have our chat bot @Nymbot assist you or the /help command in any channel.',
                selector: null,
                final: true
            }
        ];
    }

    function ensureSidebarOpenOnMobile() {
        if (window.innerWidth > 768) return Promise.resolve();

        const sidebar = $('#sidebar');
        const overlay = $('#mobileOverlay');
        if (!sidebar) return Promise.resolve();

        // Already open
        if (sidebar.classList.contains('open')) return Promise.resolve();

        // Open it and wait for transition to complete
        sidebar.classList.add('open');
        overlay && overlay.classList.add('active');

        return new Promise((resolve) => {
            let settled = false;

            const done = () => {
                if (settled) return;
                settled = true;
                sidebar.removeEventListener('transitionend', onEnd);
                clearTimeout(timer);
                // small delay to allow layout to settle before measuring
                setTimeout(() => resolve(), 30);
            };

            const onEnd = (e) => {
                if (e.propertyName === 'transform') {
                    done();
                }
            };

            sidebar.addEventListener('transitionend', onEnd, { once: true });
            // Fallback timeout in case transitionend doesn’t fire
            const timer = setTimeout(done, 400);
        });
    }

    // Close the sidebar on mobile and wait for transition
    function ensureSidebarClosedOnMobile() {
        if (window.innerWidth > 768) return Promise.resolve();

        const sidebar = $('#sidebar');
        const overlay = $('#mobileOverlay');
        if (!sidebar) return Promise.resolve();

        // Already closed
        if (!sidebar.classList.contains('open')) {
            overlay && overlay.classList.remove('active');
            return Promise.resolve();
        }

        // Close it and wait for transition to complete
        sidebar.classList.remove('open');
        overlay && overlay.classList.remove('active');

        return new Promise((resolve) => {
            let settled = false;

            const done = () => {
                if (settled) return;
                settled = true;
                sidebar.removeEventListener('transitionend', onEnd);
                clearTimeout(timer);
                // small delay to allow layout to settle before measuring
                setTimeout(() => resolve(), 30);
            };

            const onEnd = (e) => {
                if (e.propertyName === 'transform') {
                    done();
                }
            };

            sidebar.addEventListener('transitionend', onEnd, { once: true });
            // Fallback timeout
            const timer = setTimeout(done, 400);
        });
    }

    function restoreSidebarAfterTutorial() {
        if (window.innerWidth <= 768) {
            const sidebar = $('#sidebar');
            const overlay = $('#mobileOverlay');
            if (!sidebar) return;

            const initiallyOpen = !!state.sidebarInitiallyOpen;
            const currentlyOpen = sidebar.classList.contains('open');

            // Restore to the initial open/closed state
            if (initiallyOpen && !currentlyOpen) {
                sidebar.classList.add('open');
                overlay && overlay.classList.add('active');
            } else if (!initiallyOpen && currentlyOpen) {
                sidebar.classList.remove('open');
                overlay && overlay.classList.remove('active');
            }
        }
    }

    function getTargetEl(step) {
        if (!step.selector) return null;
        if (typeof step.selector === 'function') {
            const resolvedSelector = step.selector();
            return resolvedSelector ? $(resolvedSelector) : null;
        }
        return $(step.selector) || null;
    }

    function positionStep() {
        const step = state.steps[state.idx];
        const target = getTargetEl(step);
        const highlight = state.highlight;
        const card = state.card;

        // Reset display
        highlight.style.display = 'none';

        // If there is a target, try to highlight and position near it
        if (target && target.getBoundingClientRect) {
            const rect = target.getBoundingClientRect();

            // If target is off-screen, scroll into view then re-position
            const fullyOutVert = rect.bottom < 0 || rect.top > window.innerHeight;
            const fullyOutHorz = rect.right < 0 || rect.left > window.innerWidth;
            if (fullyOutVert || fullyOutHorz) {
                try {
                    target.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
                } catch (_) { }
                setTimeout(positionStep, 250);
                return;
            }

            const pad = 8;
            const hlLeft = Math.max(8, rect.left - pad);
            const hlTop = Math.max(8, rect.top - pad);
            const hlWidth = Math.min(window.innerWidth - hlLeft - 8, rect.width + pad * 2);
            const hlHeight = Math.min(window.innerHeight - hlTop - 8, rect.height + pad * 2);

            highlight.style.display = 'block';
            highlight.style.left = `${hlLeft}px`;
            highlight.style.top = `${hlTop}px`;
            highlight.style.width = `${hlWidth}px`;
            highlight.style.height = `${hlHeight}px`;

            // Place card relative to target
            card.style.visibility = 'hidden';
            card.style.left = '12px';
            card.style.top = '12px';

            // Wait a frame to measure
            requestAnimationFrame(() => {
                const cRect = card.getBoundingClientRect();
                const spaceBelow = window.innerHeight - rect.bottom;
                const spaceAbove = rect.top;

                let top;
                if (spaceBelow > cRect.height + 16) {
                    top = rect.bottom + 12;
                } else if (spaceAbove > cRect.height + 16) {
                    top = rect.top - cRect.height - 12;
                } else {
                    // fallback: bottom area
                    top = Math.min(window.innerHeight - cRect.height - 12, Math.max(12, rect.bottom + 12));
                }

                let left = rect.left + (rect.width - cRect.width) / 2;
                left = Math.max(12, Math.min(left, window.innerWidth - cRect.width - 12));

                card.style.left = `${left}px`;
                card.style.top = `${top}px`;
                card.style.visibility = 'visible';
            });
        } else {
            // Center the card for generic/welcome/final steps
            highlight.style.display = 'none';
            card.style.visibility = 'hidden';
            requestAnimationFrame(() => {
                const cRect = card.getBoundingClientRect();
                const left = Math.max(12, (window.innerWidth - cRect.width) / 2);
                const top = Math.max(12, (window.innerHeight - cRect.height) / 2);
                card.style.left = `${left}px`;
                card.style.top = `${top}px`;
                card.style.visibility = 'visible';
            });
        }
    }

    function renderStep() {
        const step = state.steps[state.idx];

        const updateAndPosition = () => {
            state.elTitle.textContent = step.title || 'Nymchat';
            state.elBody.textContent = step.body || '';
            state.elProgress.textContent = `Step ${state.idx + 1} of ${state.steps.length}`;

            state.btnPrev.disabled = state.idx === 0;
            state.btnNext.textContent = (step.final || state.idx === state.steps.length - 1) ? 'Done' : 'Next';

            positionStep();
        };

        if (step.onBefore && typeof step.onBefore === 'function') {
            try {
                const maybe = step.onBefore();
                if (maybe && typeof maybe.then === 'function') {
                    return maybe.then(updateAndPosition);
                }
            } catch (_) {
                // fall through to update
            }
        }
        updateAndPosition();
    }

    function nextStep() {
        const last = state.steps.length - 1;
        if (state.idx >= last) {
            endTutorial(true);
            return;
        }
        state.idx++;
        // Skip steps if target not found
        skipIfTargetMissingForward();
    }

    function prevStep() {
        if (state.idx <= 0) {
            renderStep();
            return;
        }
        state.idx--;
        skipIfTargetMissingBackward();
    }

    function skipIfTargetMissingForward() {
        // Move forward to first step that has a valid target (or no selector)
        let guard = 0;
        while (guard++ < state.steps.length) {
            const step = state.steps[state.idx];
            const target = getTargetEl(step);
            if (!step.selector || (target && target.getBoundingClientRect)) break;
            if (state.idx >= state.steps.length - 1) break;
            state.idx++;
        }
        renderStep();
    }

    function skipIfTargetMissingBackward() {
        // Move backward to first step that has a valid target (or no selector)
        let guard = 0;
        while (guard++ < state.steps.length) {
            const step = state.steps[state.idx];
            const target = getTargetEl(step);
            if (!step.selector || (target && target.getBoundingClientRect)) break;
            if (state.idx <= 0) break;
            state.idx--;
        }
        renderStep();
    }

    function startTutorial() {
        if (state.started) return;
        // Don’t start while the initial setup modal is open
        const setupActive = document.getElementById('setupModal')?.classList.contains('active');
        if (setupActive) return;

        buildSteps();

        state.overlay = document.getElementById('tutorialOverlay');
        state.card = document.getElementById('tutorialCard');
        state.highlight = document.getElementById('tutorialHighlight');
        state.elTitle = document.getElementById('tutorialTitle');
        state.elBody = document.getElementById('tutorialBody');
        state.elProgress = document.getElementById('tutorialProgress');
        state.btnPrev = document.getElementById('tutorialPrevBtn');
        state.btnNext = document.getElementById('tutorialNextBtn');
        state.btnSkip = document.getElementById('tutorialSkipBtn');

        state.sidebarInitiallyOpen = document.getElementById('sidebar')?.classList.contains('open');

        state.overlay.classList.add('active');
        state.overlay.style.display = 'flex';
        state.overlay.removeAttribute('aria-hidden');
        state.started = true;
        state.idx = 0;

        // Wire events
        state.btnPrev.onclick = prevStep;
        state.btnNext.onclick = () => {
            const isFinal = state.idx === state.steps.length - 1 || state.steps[state.idx].final;
            if (isFinal) endTutorial(true);
            else nextStep();
        };
        state.btnSkip.onclick = () => endTutorial(true);
        state._onResize = () => positionStep();
        state._onScroll = () => positionStep();
        window.addEventListener('resize', state._onResize);
        window.addEventListener('scroll', state._onScroll, true);
        document.addEventListener('keydown', keyHandler);

        renderStep();
    }

    function keyHandler(e) {
        if (!state.started) return;
        if (e.key === 'Escape') {
            endTutorial(true);
        } else if (e.key === 'ArrowRight' || e.key === 'Enter') {
            state.btnNext.click();
        } else if (e.key === 'ArrowLeft') {
            state.btnPrev.click();
        }
    }

    function endTutorial(markSeen) {
        // Hide
        if (state.overlay && state.overlay.contains(document.activeElement)) {
            document.activeElement.blur();
        }
        state.overlay?.classList.remove('active');
        if (state.overlay) {
            state.overlay.style.display = 'none';
            state.overlay.setAttribute('aria-hidden', 'true');
        }
        if (state.highlight) state.highlight.style.display = 'none';

        // Save flag and sync it so other devices won't re-prompt
        if (markSeen) {
            try { localStorage.setItem('nym_tutorial_seen', 'true'); } catch (_) { }
            try { if (typeof nostrSettingsSave === 'function') nostrSettingsSave(); } catch (_) { }
        }

        // Clean up
        window.removeEventListener('resize', state._onResize);
        window.removeEventListener('scroll', state._onScroll, true);
        document.removeEventListener('keydown', keyHandler);

        restoreSidebarAfterTutorial();

        state.started = false;
    }

    // Expose helper to app
    window.maybeStartTutorial = function (force = false) {
        try {
            if (!force) {
                const seen = localStorage.getItem('nym_tutorial_seen') === 'true';
                if (seen) return;
            }
            // Delay a bit to let UI settle after login/restore
            setTimeout(() => startTutorial(), 300);
        } catch (_) {
            setTimeout(() => startTutorial(), 300);
        }
    };
})();

class NYM {
    /*
     * NYM is split across module files for maintainability.
     * Each module attaches its methods to NYM.prototype via Object.assign.
     * The constructor and instance state remain here in app.js.
     * Module files are loaded by index.html in dependency order.
     *
     * Modules (see js/modules/):
     *   relays               Relay pool, connection lifecycle, proxy worker, geo-relays, stats, retries
     *   nostr-core           Event signing, NIP-44/59 encryption, gift wraps, profile fetch, presence, typing indicators
     *   users                User identities, blocked users/keywords, friends, avatars, banners, wallpaper, uploads
     *   channels             Channel switch/add/remove, joined/pinned/hidden channels, navigation history, unread counts
     *   messages             Message rendering, formatting, sending, edits, quotes, swipe-to-reply, virtual scroll
     *   reactions            Reaction sending/removal, reactor lists, emoji picker
     *   pms                  Private messages: send, open, conversation list, gift wrap DMs, new-PM modal, retry queue
     *   groups               NIP-17 group chats: create, send, ephemeral keys, members, readers, history
     *   commands             Slash-command parsing and handlers (cmdJoin, cmdNick, cmdZap, ...) plus bot commands and palette
     *   autocomplete         Emoji, channel, mention, and command autocomplete UI
     *   shop                 Shop UI: cosmetics, flair, special items, purchases, transfers, recovery codes
     *   zaps                 Lightning zaps: invoices, modals, receipts, message/profile zaps, wallets
     *   p2p                  Peer-to-peer file sharing: WebRTC data channels, WebTorrent, transfers UI
     *   translate            Message and input translation (auto-detect, language selection)
     *   polls                Poll creation, voting, display, channel poll list
     *   geohash-globe        Geohash channels and world map explorer
     *   notifications        Notification history, badges, sounds, settings
     *   settings             User settings: load/save, sync to Nostr, theme/color mode, image blur
     *   ui-context           Context menus, modals, gestures, sidebar, GIF picker, link previews, zap modals, event listeners
     *   init                 App initialization, device capability detection, performance mode
     */

    constructor() {
        this.relayPool = new Map();
        this.useRelayProxy = !!this._getApiHost();
        this.poolSockets = [];
        this.poolSocket = null;
        this.poolConnectedRelays = [];
        this.poolRelayTypes = {};
        this.poolReady = false;
        this._poolReconnecting = false;
        this._poolReconnectRetries = 0;
        this.RELAYS_PER_WORKER = 25;
        this.blacklistedRelays = new Set();
        this.relayStats = {
            eventsPerRelay: new Map(),
            bytesReceived: 0,
            latencyPerRelay: new Map(),
            throughputHistory: [],
            eventsThisSecond: 0,
            totalEvents: 0,
            startTime: Date.now()
        };
        this._relayStatsInterval = null;
        this._relayStatsAnimFrame = null;
        this.writeOnlyRelays = new Set(['wss://sendit.nosflare.com']);
        // Core default relays - always connected first for fast startup
        this.defaultRelays = [
            'wss://sendit.nosflare.com',
            'wss://relay.nymchat.app',
            'wss://relay.damus.io',
            'wss://offchain.pub',
            'wss://relay.primal.net',
            'wss://nos.lol',
            'wss://nostr21.com',
            'wss://relay.coinos.io',
            'wss://relay.snort.social',
            'wss://relay.nostr.net',
            'wss://nostr-pub.wellorder.net',
            'wss://relay1.nostrchat.io',
            'wss://nostr-01.yakihonne.com',
            'wss://nostr-02.yakihonne.com',
            'wss://relay.0xchat.com',
            'wss://relay.satlantis.io',
            'wss://relay.fountain.fm',
            'wss://nostr.mom'
        ];
        // Geo-located relays populated from bitchat CSV (fallback empty)
        this.geoRelays = [];
        this.geoRelayConnections = new Map();
        this.currentGeoRelays = new Set();
        this.geoRelayCount = 5;
        this._geoRelaysReady = this.fetchGeoRelays();
        this.allRelayUrls = new Set(this.defaultRelays);
        this.pendingConnections = new Map();
        this.relayList = [];
        this.maxRelaysForReq = 1000;
        this.relayTimeout = 2000;
        this.nip66MaxNewRelays = 1000;
        this.monitorRelays = [
            'wss://relay.nostr.watch',
            'wss://history.nostr.watch',
            'wss://relaypag.es'
        ];
        this.relayDiscoveryInterval = 24 * 3600 * 1000;
        this._nip66Running = false;
        this._nip66Done = false;
        this._nip66LastRun = 0;
        this.eventDeduplication = new Map();
        this._shardLastSeenAt = new Map();
        this._reconnectingShards = new Set();
        this._poolEventBaselines = new Map();
        this.reconnectingRelays = new Set();
        this.blacklistedRelays = new Set();
        this.blacklistTimestamps = new Map();
        this.blacklistDuration = 120000;
        this.pubkey = null;
        this.privkey = null;
        this.nym = null;
        this.pendingSettingsTransfers = [];
        this.dismissedTransferEvents = new Set(JSON.parse(localStorage.getItem('nym_dismissed_transfers') || '[]'));
        this.powDifficulty = 12;
        this.enablePow = false;
        this.nymchatPowFloor = 16;
        this.nymchatVouches = new Set();
        this._lastVouchPublishAt = 0;
        this.spamFilterEnabled = true;
        this.spamFilterAggressive = true;
        this.connectionMode = 'ephemeral';
        this.currentChannel = 'nymchat';
        this.currentGeohash = '';
        this.currentPM = null;
        this.navigationHistory = [];
        this.navigationIndex = -1;
        this._navigating = false;
        try { history.replaceState({ _nym_nav: -1 }, ''); } catch { }
        this.messages = new Map();
        this._msgSeq = 0;
        this.channelDOMCache = new Map();
        this.virtualScroll = {
            windowSize: 100,
            currentStartIndex: 0,
            currentEndIndex: 0,
            suppressAutoScroll: false
        };

        this.userScrolledUp = false;
        this._scrollRAF = null;
        this.pmMessages = new Map();
        this.processedPMEventIds = new Set();
        this.deletedEventIds = new Set();
        this._pendingDeletions = new Map();
        this.editedMessages = new Map();
        this.pendingEdit = null;
        this.pendingDMs = new Map();
        this.dmRetryInterval = null;
        this.dmRetryCheckMs = 5000;
        this.dmRetryMaxAttempts = 3;
        this.processedMessageEventIds = new Set();
        this.lastPMSyncTime = Math.floor(Date.now() / 1000) - 604800;
        this.bitchatUsers = new Set();
        this.nymUsers = new Set();
        this.users = new Map();
        this.channelUsers = new Map();
        this.channels = new Map();
        this.pmConversations = new Map();
        this.groupConversations = new Map();
        this.groupEphemeralKeys = new Map();
        this.EPHEMERAL_PREV_KEYS_MAX = 30;
        this._ephemeralSubIds = [];
        this._dmCatchupReady = Promise.resolve();
        this.currentGroup = null;
        this._newPMRecipients = [];
        this.groupMessageReaders = new Map();
        this.channelMessageReaders = new Map();
        this._unfurlCache = new Map();
        this.unreadCounts = new Map();
        this.channelLastRead = new Map();
        this.channelLastActivity = new Map();
        this.blockedUsers = new Set();
        this.friends = new Set();
        this.blockedKeywords = new Set();
        this.blockedChannels = new Set();
        this.discoveredGeohashes = new Set();
        this.channelSubscriptions = new Map();
        this.channelLoadedFromRelays = new Set();
        this.appRelay = 'wss://relay.nymchat.app';
        this.settings = this.loadSettings();
        if (this.settings.textSize && this.settings.textSize !== 15) {
            document.documentElement.style.setProperty('--user-text-size', this.settings.textSize + 'px');
        }
        applyTransparency(this.settings.transparencyEnabled === true);
        this.performanceMode = false;
        this._deviceCapabilities = this._detectDeviceCapabilities();
        this._applyPerformanceMode();
        this.channelSubscriptionBatchSize = 15;
        this.channelMessageLimit = 1000;
        this.channelPageSize = 50;
        this.channelLoadMoreSize = 50;
        this.channelRenderedStart = new Map();
        this.pmStorageLimit = 1000;
        this.pmPageSize = 50;
        this.pmLoadMoreSize = 50;
        this.pmRenderedStart = new Map();
        this.channelDomNodeLimit = 200;
        this.pmDomNodeLimit = 200;
        this.pinnedLandingChannel = this.settings.pinnedLandingChannel || { type: 'geohash', geohash: 'nymchat' };
        if (this.settings.groupChatPMOnlyMode) {
            // In PM-only mode, don't default to a geohash channel
            this.currentChannel = null;
            this.currentGeohash = null;
        } else if (this.pinnedLandingChannel.type === 'geohash' && this.pinnedLandingChannel.geohash) {
            this.currentChannel = this.pinnedLandingChannel.geohash;
            this.currentGeohash = this.pinnedLandingChannel.geohash;
        } else {
            this.currentChannel = 'nymchat';
            this.currentGeohash = 'nymchat';
        }
        this.commandHistory = [];
        this.historyIndex = -1;
        this.pendingQuote = null;
        this.connected = false;
        this.initialConnectionInProgress = false;
        this.messageQueue = [];
        this.autocompleteIndex = -1;
        this.channelAutocompleteIndex = -1;
        this.commandPaletteIndex = -1;
        this.gifPicker = null;
        this.gifSearchTimeout = null;
        this.giphyApiKey = 'G6neFEExTMBM0h3hM2QjQg4vG8jMMLa9';
        this.emojiAutocompleteIndex = -1;
        this.commonGeohashes = ['nymchat', '9q', 'w2', 'dr5r', '9q8y', 'u4pr', 'gcpv', 'f2m6', 'xn77', 'tjm5'];
        this.userJoinedChannels = new Set(this.loadUserJoinedChannels());
        this.inPMMode = false;
        this.userSearchTerm = '';
        this.geohashRegex = /^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/;
        this.pinnedChannels = new Set();
        this.hiddenChannels = new Set();
        this.hideNonPinned = false;
        this.reactions = new Map();
        this.reactionLastAction = new Map();
        this.reactionToggleTracker = new Map();
        this.actionCommandTracker = { timestamps: [], cooldownUntil: 0 };
        this.failedRelays = new Map();
        this.relayRetryDelay = 2 * 60 * 1000;
        this.previouslyConnectedRelays = new Set();
        this.floodTracking = new Map();
        this.nymchatPubkeys = new Set();
        this.pubkeyMsgIds = new Map();
        this.trustedPubkeys = new Set();
        this.activeReactionPicker = null;
        this.activeReactionPickerButton = null;
        this.contextMenuTarget = null;
        this.contextMenuData = null;
        this.p2pConnections = new Map();
        this.p2pDataChannels = new Map();
        this.p2pFileOffers = new Map();
        this.p2pActiveTransfers = new Map();
        this.p2pPendingFiles = new Map();
        this.p2pReceivedChunks = new Map();
        this.p2pSignalingSubscriptions = new Set();
        this.p2pIceServers = [
            // 0xchat public relay (enables calls/transfers behind symmetric NATs)
            { urls: 'stun:rtc.0xchat.com:5349' },
            { urls: 'turn:rtc.0xchat.com:5349', username: '0xchat', credential: 'Prettyvs511' },
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun1.l.google.com:19302' },
            { urls: 'stun:stun2.l.google.com:19302' },
            { urls: 'stun:stun.cloudflare.com:3478' }
        ];
        this.P2P_SIGNALING_KIND = 25051;
        this.P2P_FILE_STATUS_KIND = 25052;
        this.CALL_SIGNALING_KIND = 25053;
        this.activeCall = null;
        this.incomingCall = null;
        this.PRESENCE_KIND = 30078;
        this.POLL_KIND = 30078;
        this.POLL_VOTE_KIND = 30078;
        this.polls = new Map();
        this.pendingPollVotes = new Map();
        this.processedPollVoteIds = new Set();
        this.P2P_CHUNK_SIZE = 16384;
        this.p2pUnseededOffers = new Set();
        this.torrentClient = null;
        this.torrentSeeds = new Map();
        this.awayMessages = new Map();
        this.statusHiddenUsers = new Set();
        this.typingUsers = new Map();
        this._typingThrottleTime = 0;
        this._typingSendInterval = 3000;
        this._typingExpireMs = 5000;
        this._typingStopTimer = null;
        this.notificationHistory = this._loadNotificationHistory();
        this.notificationLastReadTime = parseInt(localStorage.getItem('nym_notification_last_read') || '0');
        this._lastSettingsSyncTs = parseInt(localStorage.getItem('nym_last_settings_sync_ts') || '0', 10) || 0;
        this.notificationsEnabled = localStorage.getItem('nym_notifications_enabled') !== 'false';
        this.groupNotifyMentionsOnly = localStorage.getItem('nym_group_notify_mentions_only') === 'true';
        this.notifyFriendsOnly = localStorage.getItem('nym_notify_friends_only') === 'true';
        this.closedPMs = new Set(JSON.parse(localStorage.getItem('nym_closed_pms') || '[]'));
        this.leftGroups = new Set(JSON.parse(localStorage.getItem('nym_left_groups') || '[]'));
        this.closedPMTimes = new Map(Object.entries(JSON.parse(localStorage.getItem('nym_closed_pm_times') || '{}')));
        this.leftGroupTimes = new Map(Object.entries(JSON.parse(localStorage.getItem('nym_left_group_times') || '{}')));
        this.recentEmojis = [];
        this.customEmojis = new Map();
        this.customEmojiPacks = new Map();
        this.userEmojiPackRefs = new Set();
        this._userEmojiListTs = 0;
        this.allEmojis = {
            'smileys': ['😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '☺️', '😚', '😙', '🥲', '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🫢', '🫣', '🤫', '🤔', '🫡', '🤐', '🤨', '😐', '😑', '😶', '🫥', '😏', '😒', '🙄', '😬', '🤥', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮', '🤧', '🥵', '🥶', '🥴', '😵', '😵‍💫', '🤯', '🤠', '🥳', '🥸', '😎', '🤓', '🧐', '😕', '🫤', '😟', '☹️', '🙁', '😮', '😯', '😲', '😳', '🥺', '🥹', '😦', '😧', '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓', '😩', '😫', '🥱', '😤', '😡', '😠', '🤬', '😈', '👿', '💀', '☠️', '💩', '🤡', '👹', '👺', '👻', '👽', '👾', '🤖', '🎃', '😺', '😸', '😹', '😻', '😼', '😽', '🙀', '😿', '😾'],
            'people': ['👶', '🧒', '👦', '👧', '🧑', '👱', '👨', '🧔', '👩', '🧓', '👴', '👵', '🙍', '🙎', '🙅', '🙆', '💁', '🙋', '🧏', '🙇', '🤦', '🤷', '👮', '🕵️', '💂', '🥷', '👷', '🫅', '🤴', '👸', '👳', '👲', '🧕', '🤵', '👰', '🤰', '🫃', '🫄', '🤱', '👼', '🎅', '🤶', '🦸', '🦹', '🧙', '🧚', '🧛', '🧜', '🧝', '🧞', '🧟', '🧌', '💆', '💇', '🚶', '🧍', '🧎', '🏃', '💃', '🕺', '🕴️', '👯', '🧖', '🧗', '🤸', '🏌️', '🏇', '⛷️', '🏂', '🏋️', '🤼', '🤽', '🤾', '🤺', '⛹️', '🧘', '🛀', '🛌', '👭', '👫', '👬', '💏', '💑', '👪', '👨‍👩‍👦', '👨‍👩‍👧', '👨‍👩‍👧‍👦', '👨‍👩‍👦‍👦', '👨‍👩‍👧‍👧', '🗣️', '👤', '👥', '🫂'],
            'gestures': ['👍', '👎', '👌', '🤌', '🤏', '✌️', '🤞', '🫰', '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️', '🫵', '👋', '🤚', '🖐️', '✋', '🖖', '🫱', '🫲', '🫳', '🫴', '👏', '🙌', '🫶', '👐', '🤲', '🤝', '🙏', '✍️', '💅', '🤳', '💪', '🦾', '🦿', '🦵', '🦶', '👂', '🦻', '👃', '🧠', '🫀', '🫁', '🦷', '🦴', '👀', '👁️', '👅', '👄', '🫦', '💋'],
            'hearts': ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '❤️‍🔥', '❤️‍🩹', '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '♥️'],
            'symbols': ['💯', '💢', '💥', '💫', '💦', '💨', '🕳️', '💣', '💬', '👁️‍🗨️', '🗨️', '🗯️', '💭', '💤', '✨', '🌟', '💫', '⭐', '🌠', '🔥', '☄️', '🎆', '🎇', '🎈', '🎉', '🎊', '🎋', '🎍', '🎎', '🎏', '🎐', '🎑', '🧧', '🎀', '🎁', '🎗️', '🎟️', '🎫', '🔮', '🧿', '🪬', '🎮', '🕹️', '🎰', '🎲', '♟️', '🧩', '🧸', '🪅', '🪩', '🪆', '♠️', '♥️', '♦️', '♣️', '🀄', '🃏', '🔇', '🔈', '🔉', '🔊', '📢', '📣', '📯', '🔔', '🔕', '🎵', '🎶', '🎼', '☮️', '✝️', '☪️', '🕉️', '☸️', '✡️', '🔯', '🕎', '☯️', '☦️', '🛐', '⛎', '♈', '♉', '♊', '♋', '♌', '♍', '♎', '♏', '♐', '♑', '♒', '♓', '🆔', '⚛️', '🉑', '☢️', '☣️', '📴', '📳', '🈶', '🈚', '🈸', '🈺', '🈷️', '✴️', '🆚', '💮', '🉐', '㊙️', '㊗️', '🈴', '🈵', '🈹', '🈲', '🅰️', '🅱️', '🆎', '🆑', '🅾️', '🆘', '❌', '⭕', '🛑', '⛔', '📛', '🚫', '💯', '💢', '♨️', '🚷', '🚯', '🚳', '🚱', '🔞', '📵', '🚭', '❗', '❕', '❓', '❔', '‼️', '⁉️', '🔅', '🔆', '〽️', '⚠️', '🚸', '🔱', '⚜️', '🔰', '♻️', '✅', '🈯', '💹', '❇️', '✳️', '❎', '🌐', '💠', 'Ⓜ️', '🌀', '💤', '🏧', '🚾', '♿', '🅿️', '🛗', '🈳', '🈂️', '🛂', '🛃', '🛄', '🛅', '🚹', '🚺', '🚼', '⚧️', '🚻', '🚮', '🎦', '📶', '🈁', '🔣', 'ℹ️', '🔤', '🔡', '🔠', '🆖', '🆗', '🆙', '🆒', '🆕', '🆓', '0️⃣', '1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣', '🔟', '🔢', '#️⃣', '*️⃣', '⏏️', '▶️', '⏸️', '⏯️', '⏹️', '⏺️', '⏭️', '⏮️', '⏩', '⏪', '⏫', '⏬', '◀️', '🔼', '🔽', '➡️', '⬅️', '⬆️', '⬇️', '↗️', '↘️', '↙️', '↖️', '↕️', '↔️', '↩️', '↪️', '⤴️', '⤵️', '🔀', '🔁', '🔂', '🔄', '🔃', '➕', '➖', '➗', '✖️', '🟰', '♾️', '💲', '💱', '™️', '©️', '®️', '〰️', '➰', '➿', '🔚', '🔙', '🔛', '🔝', '🔜', '✔️', '☑️', '🔘', '🔴', '🟠', '🟡', '🟢', '🔵', '🟣', '⚫', '⚪', '🟤', '🔺', '🔻', '🔸', '🔹', '🔶', '🔷', '🔳', '🔲', '▪️', '▫️', '◾', '◽', '◼️', '◻️', '🟥', '🟧', '🟨', '🟩', '🟦', '🟪', '⬛', '⬜', '🟫', '🔈', '🔉', '🔊', '🔇', '📣', '📢', '🔔', '🔕', '🃏', '🀄', '🎴', '🔁', '🔂', '🔀'],
            'objects': ['⌚', '📱', '📲', '💻', '⌨️', '🖥️', '🖨️', '🖱️', '🖲️', '🕹️', '🗜️', '💽', '💾', '💿', '📀', '📼', '📷', '📸', '📹', '🎥', '📽️', '🎞️', '📞', '☎️', '📟', '📠', '📺', '📻', '🎙️', '🎚️', '🎛️', '⏱️', '⏲️', '⏰', '🕰️', '⌛', '⏳', '📡', '🔋', '🪫', '🔌', '💡', '🔦', '🕯️', '🪔', '🧯', '🛢️', '💸', '💵', '💴', '💶', '💷', '🪙', '💰', '💳', '🪪', '🧾', '💎', '⚖️', '🪜', '🧰', '🪛', '🔧', '🔨', '⚒️', '🛠️', '⛏️', '🪚', '🔩', '⚙️', '🪤', '⛓️', '🧲', '🔫', '💣', '🧨', '🪓', '🔪', '🗡️', '⚔️', '🛡️', '🚬', '⚰️', '🪦', '⚱️', '🏺', '🔮', '📿', '🧿', '🪬', '💈', '⚗️', '🔭', '🔬', '🕳️', '🩻', '🩹', '🩺', '💊', '💉', '🩸', '🌡️', '🧬', '🦠', '🧫', '🧪', '🏷️', '🔖', '🚽', '🪠', '🚿', '🛁', '🛀', '🪥', '🪒', '🧻', '🧼', '🫧', '🪣', '🧽', '🧴', '🛏️', '🛋️', '🪑', '🚪', '🪞', '🪟', '🧹', '🧺', '🧯', '🛒', '🚬', '⚰️', '⚱️', '🗿', '🪧', '🪪'],
            'clothing': ['👓', '🕶️', '🥽', '🥼', '🦺', '👔', '👕', '👖', '🧣', '🧤', '🧥', '🧦', '👗', '👘', '🥻', '🩱', '🩲', '🩳', '👙', '👚', '👛', '👜', '👝', '🛍️', '🎒', '🩴', '👞', '👟', '🥾', '🥿', '👠', '👡', '🩰', '👢', '👑', '👒', '🎩', '🎓', '🧢', '🪖', '⛑️', '📿', '💄', '💍', '💎', '🪭', '🪮'],
            'nature': ['🐵', '🐒', '🦍', '🦧', '🐶', '🐕', '🦮', '🐕‍🦺', '🐩', '🐺', '🦊', '🦝', '🐱', '🐈', '🐈‍⬛', '🦁', '🐯', '🐅', '🐆', '🐴', '🐎', '🦄', '🦓', '🦌', '🫎', '🦬', '🐮', '🐂', '🐃', '🐄', '🐷', '🐖', '🐗', '🐽', '🐏', '🐑', '🐐', '🐪', '🐫', '🦙', '🦒', '🐘', '🦣', '🦏', '🦛', '🐭', '🐁', '🐀', '🐹', '🐰', '🐇', '🐿️', '🦫', '🦔', '🦇', '🐻', '🐻‍❄️', '🐨', '🐼', '🦥', '🦦', '🦨', '🦘', '🦡', '🐾', '🦃', '🐔', '🐓', '🐣', '🐤', '🐥', '🐦', '🐧', '🕊️', '🦅', '🦆', '🦢', '🦉', '🦤', '🪶', '🦩', '🦚', '🦜', '🪽', '🐦‍⬛', '🪿', '🐸', '🐊', '🐢', '🦎', '🐍', '🐲', '🐉', '🦕', '🦖', '🐳', '🐋', '🐬', '🦭', '🐟', '🐠', '🐡', '🦈', '🐙', '🐚', '🪸', '🪼', '🐌', '🦋', '🐛', '🐜', '🐝', '🪲', '🐞', '🦗', '🪳', '🕷️', '🕸️', '🦂', '🦟', '🪰', '🪱', '🦠', '💐', '🌸', '💮', '🏵️', '🌹', '🥀', '🌺', '🌻', '🌼', '🌷', '🪷', '🌱', '🪴', '🌲', '🌳', '🌴', '🌵', '🌾', '🌿', '☘️', '🍀', '🍁', '🍂', '🍃', '🪹', '🪺', '🍄', '🪨', '🪵'],
            'food': ['🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍈', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🥦', '🥬', '🥒', '🌶️', '🫑', '🌽', '🥕', '🧄', '🧅', '🥔', '🍠', '🫘', '🥐', '🥯', '🍞', '🫓', '🥖', '🥨', '🧀', '🥚', '🍳', '🧈', '🥞', '🧇', '🥓', '🥩', '🍗', '🍖', '🦴', '🌭', '🍔', '🍟', '🍕', '🫔', '🥪', '🥙', '🧆', '🌮', '🌯', '🫕', '🥗', '🥘', '🫙', '🥫', '🍝', '🍜', '🍲', '🍛', '🍣', '🍱', '🥟', '🦪', '🍤', '🍙', '🍚', '🍘', '🍥', '🥠', '🥮', '🍢', '🍡', '🍧', '🍨', '🍦', '🥧', '🧁', '🍰', '🎂', '🍮', '🍭', '🍬', '🍫', '🍿', '🍩', '🍪', '🌰', '🥜', '🍯', '🥛', '🍼', '🫗', '☕', '🫖', '🍵', '🧃', '🥤', '🧋', '🍶', '🍺', '🍻', '🥂', '🍷', '🥃', '🍸', '🍹', '🧉', '🍾', '🧊', '🥄', '🍴', '🍽️', '🥣', '🥡', '🥢', '🫙'],
            'activities': ['⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🥏', '🎱', '🪀', '🏓', '🏸', '🏒', '🏑', '🥍', '🏏', '🪃', '🥅', '⛳', '🪁', '🏹', '🎣', '🤿', '🥊', '🥋', '🎽', '🛹', '🛼', '🛷', '⛸️', '🥌', '🎿', '⛷️', '🏂', '🪂', '🏋️', '🤼', '🤸', '🤺', '🤾', '🏌️', '🏇', '🧘', '🏄', '🏊', '🤽', '🚣', '🧗', '🚴', '🚵', '🎪', '🎭', '🎨', '🎬', '🎤', '🎧', '🎼', '🎹', '🥁', '🪘', '🎷', '🎺', '🪗', '🎸', '🪕', '🎻', '🪈', '🎲', '🎯', '🎳', '🎰', '🧩'],
            'travel': ['🚗', '🚕', '🚙', '🚌', '🚎', '🏎️', '🚓', '🚑', '🚒', '🚐', '🛻', '🚚', '🚛', '🚜', '🦯', '🦽', '🦼', '🛴', '🚲', '🛵', '🏍️', '🛺', '🛞', '🚨', '🚔', '🚍', '🚘', '🚖', '🛞', '🚡', '🚠', '🚟', '🚃', '🚋', '🚞', '🚝', '🚄', '🚅', '🚈', '🚂', '🚆', '🚇', '🚊', '🚉', '✈️', '🛫', '🛬', '🛩️', '💺', '🛰️', '🚀', '🛸', '🚁', '🛶', '⛵', '🚤', '🛥️', '🛳️', '⛴️', '🚢', '⚓', '🪝', '⛽', '🚧', '🚦', '🚥', '🚏', '🗺️', '🗿', '🗽', '🗼', '🏰', '🏯', '🏟️', '🎡', '🎢', '🎠', '⛲', '⛱️', '🏖️', '🏝️', '🏜️', '🌋', '⛰️', '🏔️', '🗻', '🏕️', '🛖', '🏠', '🏡', '🏘️', '🏚️', '🏗️', '🏭', '🏢', '🏬', '🏣', '🏤', '🏥', '🏦', '🏨', '🏪', '🏫', '🏩', '💒', '🏛️', '⛪', '🕌', '🕍', '🛕', '🕋', '⛩️', '🛤️', '🛣️', '🗾', '🎑', '🏞️', '🌅', '🌄', '🌠', '🎇', '🎆', '🌇', '🌆', '🏙️', '🌃', '🌌', '🌉', '🌁'],
            'weather': ['☀️', '🌤️', '⛅', '🌥️', '☁️', '🌦️', '🌧️', '⛈️', '🌩️', '🌨️', '❄️', '☃️', '⛄', '🌬️', '💨', '🌪️', '🌫️', '🌈', '☔', '💧', '🌊', '🔥', '🌙', '🌛', '🌜', '🌚', '🌕', '🌖', '🌗', '🌘', '🌑', '🌒', '🌓', '🌔', '🌍', '🌎', '🌏', '🪐', '⭐', '🌟', '✨', '💫', '☄️'],
            'flags': ['🏳️', '🏴', '🏁', '🚩', '🏳️‍🌈', '🏳️‍⚧️', '🏴‍☠️', '🇺🇸', '🇬🇧', '🇨🇦', '🇦🇺', '🇩🇪', '🇫🇷', '🇯🇵', '🇰🇷', '🇨🇳', '🇮🇳', '🇧🇷', '🇲🇽', '🇪🇸', '🇮🇹', '🇷🇺', '🇸🇪', '🇳🇴', '🇩🇰', '🇫🇮', '🇳🇱', '🇧🇪', '🇦🇹', '🇨🇭', '🇵🇱', '🇺🇦', '🇹🇷', '🇬🇷', '🇵🇹', '🇮🇪', '🇿🇦', '🇳🇬', '🇪🇬', '🇰🇪', '🇦🇷', '🇨🇱', '🇨🇴', '🇵🇪', '🇻🇪', '🇹🇭', '🇻🇳', '🇮🇩', '🇵🇭', '🇲🇾', '🇸🇬', '🇳🇿', '🇸🇦', '🇦🇪', '🇮🇱', '🇵🇰', '🇧🇩', '🇭🇰', '🇹🇼', '🇨🇿', '🇭🇺', '🇷🇴', '🇭🇷', '🇷🇸', '🇧🇬', '🇸🇰', '🇸🇮', '🇱🇹', '🇱🇻', '🇪🇪', '🇮🇸', '🇱🇺', '🇲🇹', '🇨🇾', '🇯🇲', '🇹🇹', '🇧🇸', '🇧🇧', '🇵🇷', '🇨🇺', '🇩🇴', '🇭🇹', '🇵🇦', '🇨🇷', '🇬🇹', '🇭🇳', '🇸🇻', '🇳🇮', '🇧🇴', '🇪🇨', '🇺🇾', '🇵🇾', '🇬🇾']
        };
        this.emojiMap = {
            // Smileys & faces
            'grinning': '😀', 'smiley': '😃', 'grin': '😄', 'beaming': '😁', 'laughing': '😆',
            'sweat_smile': '😅', 'rofl': '🤣', 'laugh': '😂', 'slightly_smiling': '🙂', 'upside_down': '🙃',
            'wink': '😉', 'smile': '😊', 'innocent': '😇', 'heart_eyes': '🥰', 'love': '😍',
            'star_struck': '🤩', 'kiss': '😘', 'kissing': '😗', 'relaxed': '☺️', 'kissing_closed': '😚',
            'kissing_smiling': '😙', 'holding_tears': '🥲', 'yum': '😋', 'stuck_out': '😛', 'stuck_out_wink': '😜',
            'zany': '🤪', 'stuck_out_closed': '😝', 'money_face': '🤑', 'hug': '🤗', 'shush': '🤭',
            'peeking': '🫣', 'quiet': '🤫', 'thinking': '🤔', 'salute': '🫡', 'zipper': '🤐',
            'raised_eyebrow': '🤨', 'neutral': '😐', 'expressionless': '😑', 'no_mouth': '😶', 'dotted_face': '🫥',
            'smirk': '😏', 'unamused': '😒', 'eye_roll': '🙄', 'grimace': '😬', 'lying': '🤥',
            'relieved': '😌', 'pensive': '😔', 'sleepy': '😪', 'drool': '🤤', 'sleeping': '😴',
            'mask': '😷', 'thermometer': '🤒', 'bandage': '🤕', 'sick': '🤢', 'vomit': '🤮',
            'sneeze': '🤧', 'hot': '🥵', 'cold': '🥶', 'woozy': '🥴', 'dizzy': '😵',
            'spiral_eyes': '😵‍💫', 'mind_blown': '🤯', 'cowboy': '🤠', 'partying': '🥳', 'disguise': '🥸',
            'cool': '😎', 'nerd': '🤓', 'monocle': '🧐', 'confused': '😕', 'diagonal_mouth': '🫤',
            'worried': '😟', 'frowning': '☹️', 'slightly_frowning': '🙁', 'shocked': '😮', 'surprised': '😯',
            'astonished': '😲', 'flushed': '😳', 'pleading': '🥺', 'face_holding_tears': '🥹', 'anguished': '😧',
            'fearful': '😨', 'anxious': '😰', 'sad': '😥', 'cry': '😢', 'sob': '😭',
            'scream': '😱', 'confounded': '😖', 'persevere': '😣', 'disappointed': '😞', 'sweat': '😓',
            'weary': '😩', 'tired': '😫', 'yawn': '🥱', 'triumph': '😤', 'pouting': '😡',
            'angry': '😠', 'rage': '🤬', 'devil': '😈', 'imp': '👿', 'skull': '💀',
            'skull_crossbones': '☠️', 'poop': '💩', 'clown': '🤡', 'ogre': '👹', 'goblin': '👺',
            'ghost': '👻', 'alien': '👽', 'space_invader': '👾', 'robot': '🤖', 'jack': '🎃',
            'cat_smile': '😺', 'cat_grin': '😸', 'cat_joy': '😹', 'cat_love': '😻', 'cat_smirk': '😼',
            'cat_kiss': '😽', 'cat_scream': '🙀', 'cat_cry': '😿', 'cat_angry': '😾',
            // People
            'baby': '👶', 'child': '🧒', 'boy': '👦', 'girl': '👧', 'person': '🧑',
            'blond': '👱', 'man': '👨', 'bearded': '🧔', 'woman': '👩', 'older_person': '🧓',
            'old_man': '👴', 'old_woman': '👵', 'frowning_person': '🙍', 'pouting_person': '🙎', 'no_good': '🙅',
            'ok_person': '🙆', 'tipping': '💁', 'raising_hand': '🙋', 'deaf_person': '🧏', 'bowing': '🙇',
            'facepalm': '🤦', 'shrug': '🤷', 'police_officer': '👮', 'detective': '🕵️', 'guard': '💂',
            'ninja': '🥷', 'construction': '👷', 'royalty': '🫅', 'prince': '🤴', 'princess': '👸',
            'turban': '👳', 'skullcap': '👲', 'headscarf': '🧕', 'tuxedo': '🤵', 'bride': '👰',
            'pregnant': '🤰', 'pregnant_man': '🫃', 'pregnant_person': '🫄', 'breast_feeding': '🤱', 'angel': '👼',
            'santa': '🎅', 'mrs_claus': '🤶', 'superhero': '🦸', 'supervillain': '🦹', 'mage': '🧙',
            'fairy': '🧚', 'vampire': '🧛', 'merperson': '🧜', 'elf': '🧝', 'genie': '🧞',
            'zombie': '🧟', 'troll': '🧌', 'massage': '💆', 'haircut': '💇', 'walking': '🚶',
            'standing': '🧍', 'kneeling': '🧎', 'running': '🏃', 'dancer': '💃', 'man_dancing': '🕺',
            'levitate': '🕴️', 'people_dancing': '👯', 'sauna': '🧖', 'climbing': '🧗', 'cartwheeling': '🤸',
            'golfer': '🏌️', 'horse_racing': '🏇', 'skier': '⛷️', 'snowboarder': '🏂', 'weight_lifter': '🏋️',
            'wrestlers': '🤼', 'water_polo': '🤽', 'handball': '🤾', 'fencer': '🤺', 'basketball_player': '⛹️',
            'meditating': '🧘', 'bath': '🛀', 'sleeping_person': '🛌', 'women_holding_hands': '👭', 'couple': '👫',
            'men_holding_hands': '👬', 'kiss_couple': '💏', 'couple_heart': '💑', 'family': '👪',
            'speaking_head': '🗣️', 'silhouette': '👤', 'silhouettes': '👥', 'people_hugging': '🫂',
            // Gestures & body
            'thumbsup': '👍', 'thumbsdown': '👎', 'ok_hand': '👌', 'pinched': '🤌', 'pinch': '🤏',
            'peace': '✌️', 'crossed': '🤞', 'hand_with_fingers': '🫰', 'rock': '🤟', 'metal': '🤘',
            'call': '🤙', 'left': '👈', 'right': '👉', 'up': '👆', 'middle_finger': '🖕',
            'down': '👇', 'point': '☝️', 'point_at_you': '🫵', 'wave': '👋', 'backhand': '🤚',
            'fingers_splayed': '🖐️', 'hand': '✋', 'vulcan': '🖖', 'rightward_hand': '🫱', 'leftward_hand': '🫲',
            'palm_down': '🫳', 'palm_up': '🫴', 'clap': '👏', 'raised': '🙌', 'heart_hands': '🫶',
            'open': '👐', 'palms': '🤲', 'handshake': '🤝', 'pray': '🙏', 'writing': '✍️',
            'nail_polish': '💅', 'selfie': '🤳', 'muscle': '💪', 'mechanical_arm': '🦾', 'mechanical_leg': '🦿',
            'leg': '🦵', 'foot': '🦶', 'ear': '👂', 'hearing_aid': '🦻', 'nose': '👃',
            'brain': '🧠', 'anatomical_heart': '🫀', 'lungs': '🫁', 'tooth': '🦷', 'bone': '🦴',
            'eyes': '👀', 'eye': '👁️', 'tongue': '👅', 'lips': '👄', 'biting_lip': '🫦', 'kiss_mark': '💋',
            // Hearts
            'heart': '❤️', 'orange_heart': '🧡', 'yellow_heart': '💛', 'green_heart': '💚',
            'blue_heart': '💙', 'purple_heart': '💜', 'black_heart': '🖤', 'white_heart': '🤍',
            'brown_heart': '🤎', 'heart_on_fire': '❤️‍🔥', 'mending_heart': '❤️‍🩹', 'broken': '💔',
            'exclamation_heart': '❣️', 'two_hearts': '💕', 'revolving': '💞', 'heartbeat': '💓',
            'growing': '💗', 'sparkling': '💖', 'cupid': '💘', 'gift_heart': '💝', 'heart_decoration': '💟',
            // Symbols & misc
            '100': '💯', 'anger': '💢', 'boom': '💥', 'dizzy_symbol': '💫', 'sweat_drops': '💦',
            'dash': '💨', 'hole': '🕳️', 'bomb': '💣', 'speech': '💬', 'eye_speech': '👁️‍🗨️',
            'left_speech': '🗨️', 'right_anger': '🗯️', 'thought': '💭', 'zzz': '💤',
            'sparkles': '✨', 'stars': '🌟', 'star': '⭐', 'shooting_star': '🌠', 'fire': '🔥',
            'comet': '☄️', 'fireworks': '🎆', 'sparkler': '🎇', 'balloon': '🎈', 'party': '🎉',
            'tada': '🎊', 'tanabata': '🎋', 'pine': '🎍', 'dolls': '🎎', 'carp_streamer': '🎏',
            'wind_chime': '🎐', 'moon_viewing': '🎑', 'red_envelope': '🧧', 'ribbon': '🎀', 'gift': '🎁',
            'reminder_ribbon': '🎗️', 'ticket': '🎟️', 'admission': '🎫', 'crystal_ball': '🔮', 'nazar': '🧿',
            'hamsa': '🪬', 'gaming': '🎮', 'joystick': '🕹️', 'slot': '🎰', 'dice': '🎲',
            'chess': '♟️', 'puzzle': '🧩', 'teddy': '🧸', 'pinata': '🪅', 'mirror_ball': '🪩',
            'nesting_dolls': '🪆', 'spades': '♠️', 'hearts_suit': '♥️', 'diamonds': '♦️', 'clubs': '♣️',
            'mahjong': '🀄', 'joker': '🃏', 'music': '🎵', 'notes': '🎶', 'musical_score': '🎼',
            'warning': '⚠️', 'check': '✅', 'x': '❌', 'question': '❓', 'exclamation': '❗',
            'bangbang': '‼️', 'interrobang': '⁉️', 'lightning': '⚡', 'trophy': '🏆', 'medal': '🥇',
            'silver_medal': '🥈', 'bronze_medal': '🥉', 'sports_medal': '🏅', 'military_medal': '🎖️',
            'copyright': '©️', 'registered': '®️', 'tm': '™️', 'infinity': '♾️',
            'peace_symbol': '☮️', 'cross': '✝️', 'star_crescent': '☪️', 'om': '🕉️', 'wheel_dharma': '☸️',
            'star_david': '✡️', 'yin_yang': '☯️', 'atom': '⚛️', 'radioactive': '☢️', 'biohazard': '☣️',
            'recycle': '♻️',
            // Objects
            'watch': '⌚', 'phone': '📱', 'calling': '📲', 'computer': '💻', 'keyboard': '⌨️',
            'desktop': '🖥️', 'printer': '🖨️', 'mouse': '🖱️', 'trackball': '🖲️', 'cd': '💿',
            'dvd': '📀', 'vhs': '📼', 'camera': '📷', 'camera_flash': '📸', 'video': '📹',
            'movie': '🎥', 'projector': '📽️', 'film': '🎞️', 'telephone': '☎️', 'pager': '📟',
            'fax': '📠', 'tv': '📺', 'radio': '📻', 'microphone': '🎙️', 'level_slider': '🎚️',
            'control_knobs': '🎛️', 'stopwatch': '⏱️', 'timer': '⏲️', 'alarm': '⏰', 'mantelpiece_clock': '🕰️',
            'hourglass': '⌛', 'hourglass_flowing': '⏳', 'satellite_dish': '📡', 'battery': '🔋', 'low_battery': '🪫',
            'plug': '🔌', 'bulb': '💡', 'flashlight': '🔦', 'candle': '🕯️', 'lamp': '🪔',
            'fire_extinguisher': '🧯', 'oil': '🛢️', 'dollar': '💵', 'yen': '💴', 'euro': '💶',
            'pound': '💷', 'coin': '🪙', 'money_bag': '💰', 'credit_card': '💳', 'id_card': '🪪',
            'receipt': '🧾', 'gem': '💎', 'balance': '⚖️', 'ladder': '🪜', 'toolbox': '🧰',
            'screwdriver': '🪛', 'wrench': '🔧', 'hammer': '🔨', 'hammer_wrench': '🛠️', 'pick': '⛏️',
            'saw': '🪚', 'nut_bolt': '🔩', 'gear': '⚙️', 'mousetrap': '🪤', 'chains': '⛓️',
            'magnet': '🧲', 'gun': '🔫', 'bomb': '💣', 'firecracker': '🧨', 'axe': '🪓',
            'knife': '🔪', 'dagger': '🗡️', 'crossed_swords': '⚔️', 'shield': '🛡️', 'coffin': '⚰️',
            'headstone': '🪦', 'urn': '⚱️', 'amphora': '🏺', 'barber': '💈', 'alembic': '⚗️',
            'telescope': '🔭', 'microscope': '🔬', 'xray': '🩻', 'adhesive': '🩹', 'stethoscope': '🩺',
            'pill': '💊', 'syringe': '💉', 'drop_blood': '🩸', 'thermometer_obj': '🌡️', 'dna': '🧬',
            'microbe': '🦠', 'petri': '🧫', 'test_tube': '🧪', 'label': '🏷️', 'bookmark': '🔖',
            'toilet': '🚽', 'plunger': '🪠', 'shower': '🚿', 'bathtub': '🛁', 'toothbrush': '🪥',
            'razor': '🪒', 'roll': '🧻', 'soap': '🧼', 'bubbles': '🫧', 'bucket': '🪣',
            'sponge': '🧽', 'lotion': '🧴', 'bed': '🛏️', 'couch': '🛋️', 'chair': '🪑',
            'door': '🚪', 'mirror': '🪞', 'window': '🪟', 'broom': '🧹', 'basket': '🧺',
            'cart': '🛒', 'moai': '🗿', 'placard': '🪧',
            'book': '📖', 'books': '📚', 'newspaper': '📰', 'scroll': '📜', 'memo': '📝',
            'pencil': '✏️', 'pen': '🖊️', 'paintbrush': '🖌️', 'crayon': '🖍️', 'scissors': '✂️',
            'pushpin': '📌', 'paperclip': '📎', 'link': '🔗', 'lock': '🔒', 'unlock': '🔓',
            'key': '🔑', 'old_key': '🗝️', 'mag': '🔍', 'bell': '🔔', 'no_bell': '🔕',
            'speaker': '🔊', 'mute': '🔇',
            // Clothing
            'glasses': '👓', 'sunglasses_obj': '🕶️', 'goggles': '🥽', 'lab_coat': '🥼', 'safety_vest': '🦺',
            'necktie': '👔', 'tshirt': '👕', 'jeans': '👖', 'scarf': '🧣', 'gloves': '🧤',
            'coat': '🧥', 'socks': '🧦', 'dress': '👗', 'kimono': '👘', 'sari': '🥻',
            'swimsuit': '🩱', 'briefs': '🩲', 'shorts': '🩳', 'bikini': '👙', 'blouse': '👚',
            'purse': '👛', 'handbag': '👜', 'pouch': '👝', 'shopping': '🛍️', 'backpack': '🎒',
            'thong_sandal': '🩴', 'shoe': '👞', 'sneaker': '👟', 'hiking_boot': '🥾', 'flat_shoe': '🥿',
            'heel': '👠', 'sandal': '👡', 'ballet': '🩰', 'boot': '👢', 'crown': '👑',
            'womans_hat': '👒', 'top_hat': '🎩', 'graduation': '🎓', 'cap': '🧢', 'helmet': '🪖',
            'rescue_helmet': '⛑️', 'lipstick': '💄', 'ring': '💍',
            // Nature & animals
            'monkey_face': '🐵', 'monkey': '🐒', 'gorilla': '🦍', 'orangutan': '🦧', 'dog': '🐶',
            'dog2': '🐕', 'guide_dog': '🦮', 'service_dog': '🐕‍🦺', 'poodle': '🐩', 'wolf': '🐺',
            'fox': '🦊', 'raccoon': '🦝', 'cat': '🐱', 'cat2': '🐈', 'black_cat': '🐈‍⬛',
            'lion': '🦁', 'tiger': '🐯', 'tiger2': '🐅', 'leopard': '🐆', 'horse': '🐴',
            'horse2': '🐎', 'unicorn': '🦄', 'zebra': '🦓', 'deer': '🦌', 'moose': '🫎',
            'bison': '🦬', 'cow': '🐮', 'ox': '🐂', 'water_buffalo': '🐃', 'cow2': '🐄',
            'pig': '🐷', 'pig2': '🐖', 'boar': '🐗', 'pig_nose': '🐽', 'ram': '🐏',
            'sheep': '🐑', 'goat': '🐐', 'camel': '🐪', 'two_hump_camel': '🐫', 'llama': '🦙',
            'giraffe': '🦒', 'elephant': '🐘', 'mammoth': '🦣', 'rhino': '🦏', 'hippo': '🦛',
            'mouse_face': '🐭', 'mouse2': '🐁', 'rat': '🐀', 'hamster': '🐹', 'rabbit': '🐰',
            'rabbit2': '🐇', 'chipmunk': '🐿️', 'beaver': '🦫', 'hedgehog': '🦔', 'bat': '🦇',
            'bear': '🐻', 'polar_bear': '🐻‍❄️', 'koala': '🐨', 'panda': '🐼', 'sloth': '🦥',
            'otter': '🦦', 'skunk': '🦨', 'kangaroo': '🦘', 'badger': '🦡', 'paw_prints': '🐾',
            'turkey': '🦃', 'chicken': '🐔', 'rooster': '🐓', 'hatching_chick': '🐣', 'baby_chick': '🐤',
            'chick': '🐥', 'bird': '🐦', 'penguin': '🐧', 'dove': '🕊️', 'eagle': '🦅',
            'duck': '🦆', 'swan': '🦢', 'owl': '🦉', 'dodo': '🦤', 'feather': '🪶',
            'flamingo': '🦩', 'peacock': '🦚', 'parrot': '🦜', 'wing': '🪽', 'black_bird': '🐦‍⬛',
            'goose': '🪿', 'frog': '🐸', 'crocodile': '🐊', 'turtle': '🐢', 'lizard': '🦎',
            'snake': '🐍', 'dragon_face': '🐲', 'dragon': '🐉', 'sauropod': '🦕', 'trex': '🦖',
            'whale': '🐳', 'whale2': '🐋', 'dolphin': '🐬', 'seal': '🦭', 'fish': '🐟',
            'tropical_fish': '🐠', 'blowfish': '🐡', 'shark': '🦈', 'octopus': '🐙', 'shell': '🐚',
            'coral': '🪸', 'jellyfish': '🪼', 'snail': '🐌', 'butterfly': '🦋', 'bug': '🐛',
            'ant': '🐜', 'bee': '🐝', 'beetle': '🪲', 'ladybug': '🐞', 'cricket': '🦗',
            'cockroach': '🪳', 'spider': '🕷️', 'web': '🕸️', 'scorpion': '🦂', 'mosquito': '🦟',
            'fly': '🪰', 'worm': '🪱', 'bouquet': '💐', 'cherry_blossom': '🌸', 'flower_white': '💮',
            'rosette': '🏵️', 'rose': '🌹', 'wilted': '🥀', 'hibiscus': '🌺', 'sunflower': '🌻',
            'blossom': '🌼', 'tulip': '🌷', 'lotus': '🪷', 'seedling': '🌱', 'potted_plant': '🪴',
            'evergreen': '🌲', 'deciduous': '🌳', 'palm': '🌴', 'cactus': '🌵', 'rice': '🌾',
            'herb': '🌿', 'shamrock': '☘️', 'four_leaf': '🍀', 'maple_leaf': '🍁', 'fallen_leaf': '🍂',
            'leaves': '🍃', 'nest': '🪹', 'nest_eggs': '🪺', 'mushroom': '🍄', 'rock': '🪨', 'wood': '🪵',
            // Food & drink
            'green_apple': '🍏', 'apple': '🍎', 'pear': '🍐', 'orange': '🍊', 'lemon': '🍋',
            'banana': '🍌', 'watermelon': '🍉', 'grapes': '🍇', 'strawberry': '🍓', 'blueberries': '🫐',
            'melon': '🍈', 'cherry': '🍒', 'peach': '🍑', 'mango': '🥭', 'pineapple': '🍍',
            'coconut': '🥥', 'kiwi': '🥝', 'tomato': '🍅', 'eggplant': '🍆', 'avocado': '🥑',
            'broccoli': '🥦', 'leafy_green': '🥬', 'cucumber': '🥒', 'hot_pepper': '🌶️', 'bell_pepper': '🫑',
            'corn': '🌽', 'carrot': '🥕', 'garlic': '🧄', 'onion': '🧅', 'potato': '🥔',
            'sweet_potato': '🍠', 'beans': '🫘', 'croissant': '🥐', 'bagel': '🥯', 'bread': '🍞',
            'flatbread': '🫓', 'baguette': '🥖', 'pretzel': '🥨', 'cheese': '🧀', 'egg': '🥚',
            'cooking': '🍳', 'butter': '🧈', 'pancakes': '🥞', 'waffle': '🧇', 'bacon': '🥓',
            'steak': '🥩', 'poultry_leg': '🍗', 'meat': '🍖', 'bone': '🦴', 'hotdog': '🌭',
            'hamburger': '🍔', 'fries': '🍟', 'pizza': '🍕', 'tamale': '🫔', 'sandwich': '🥪',
            'pita': '🥙', 'falafel': '🧆', 'taco': '🌮', 'burrito': '🌯', 'fondue': '🫕',
            'salad': '🥗', 'stew': '🥘', 'jar': '🫙', 'canned': '🥫', 'spaghetti': '🍝',
            'ramen': '🍜', 'soup': '🍲', 'curry': '🍛', 'sushi': '🍣', 'bento': '🍱',
            'dumpling': '🥟', 'oyster': '🦪', 'shrimp': '🍤', 'rice_ball': '🍙', 'rice_bowl': '🍚',
            'rice_cracker': '🍘', 'fish_cake': '🍥', 'fortune_cookie': '🥠', 'moon_cake': '🥮', 'oden': '🍢',
            'dango': '🍡', 'ice_shaved': '🍧', 'ice_cream': '🍨', 'cone': '🍦', 'pie': '🥧',
            'cupcake': '🧁', 'cake': '🎂', 'birthday': '🎂', 'custard': '🍮', 'lollipop': '🍭',
            'candy': '🍬', 'chocolate': '🍫', 'popcorn': '🍿', 'donut': '🍩', 'cookie': '🍪',
            'chestnut': '🌰', 'peanuts': '🥜', 'honey': '🍯', 'milk': '🥛', 'baby_bottle': '🍼',
            'pouring_liquid': '🫗', 'coffee': '☕', 'teapot': '🫖', 'tea': '🍵', 'juice': '🧃',
            'cup_straw': '🥤', 'boba': '🧋', 'sake': '🍶', 'beer': '🍺', 'beers': '🍻',
            'clinking': '🥂', 'wine': '🍷', 'tumbler': '🥃', 'cocktail': '🍸', 'tropical': '🍹',
            'mate': '🧉', 'champagne': '🍾', 'ice_cube': '🧊', 'spoon': '🥄', 'fork_knife': '🍴',
            'plate': '🍽️', 'bowl_spoon': '🥣', 'takeout': '🥡', 'chopsticks': '🥢',
            // Activities & sports
            'soccer': '⚽', 'basketball': '🏀', 'football': '🏈', 'baseball': '⚾', 'softball': '🥎',
            'tennis': '🎾', 'volleyball': '🏐', 'rugby': '🏉', 'flying_disc': '🥏', 'pool': '🎱',
            'yo_yo': '🪀', 'ping_pong': '🏓', 'badminton': '🏸', 'hockey': '🏒', 'field_hockey': '🏑',
            'lacrosse': '🥍', 'cricket_game': '🏏', 'boomerang': '🪃', 'goal_net': '🥅', 'golf': '⛳',
            'kite': '🪁', 'bow_arrow': '🏹', 'fishing': '🎣', 'diving_mask': '🤿', 'boxing': '🥊',
            'martial_arts': '🥋', 'running_shirt': '🎽', 'skateboard': '🛹', 'roller_skate': '🛼', 'sled': '🛷',
            'ice_skate': '⛸️', 'curling': '🥌', 'ski': '🎿', 'circus': '🎪', 'performing_arts': '🎭',
            'art': '🎨', 'clapper': '🎬', 'microphone2': '🎤', 'headphones': '🎧', 'piano': '🎹',
            'drum': '🥁', 'long_drum': '🪘', 'sax': '🎷', 'trumpet': '🎺', 'accordion': '🪗',
            'guitar': '🎸', 'banjo': '🪕', 'violin': '🎻', 'flute': '🪈', 'dart': '🎯',
            'bowling': '🎳',
            // Travel & places
            'car': '🚗', 'taxi': '🚕', 'suv': '🚙', 'bus': '🚌', 'trolleybus': '🚎',
            'racing': '🏎️', 'police_car': '🚓', 'ambulance': '🚑', 'firetruck': '🚒', 'minibus': '🚐',
            'pickup_truck': '🛻', 'truck': '🚚', 'articulated': '🚛', 'tractor': '🚜', 'scooter': '🛴',
            'bike': '🚲', 'motor_scooter': '🛵', 'motorcycle': '🏍️', 'auto_rickshaw': '🛺', 'wheel': '🛞',
            'police_light': '🚨', 'oncoming_police': '🚔', 'train': '🚆', 'metro': '🚇', 'tram': '🚊',
            'station': '🚉', 'bullet_train': '🚄', 'high_speed': '🚅', 'monorail': '🚝', 'railway': '🚞',
            'airplane': '✈️', 'departure': '🛫', 'arrival': '🛬', 'small_airplane': '🛩️', 'seat': '💺',
            'satellite': '🛰️', 'rocket': '🚀', 'ufo': '🛸', 'helicopter': '🚁', 'canoe': '🛶',
            'boat': '⛵', 'speedboat': '🚤', 'motor_boat': '🛥️', 'passenger_ship': '🛳️', 'ferry': '⛴️',
            'ship': '🚢', 'anchor': '⚓', 'hook': '🪝', 'fuel_pump': '⛽', 'construction_sign': '🚧',
            'traffic_light': '🚦', 'vertical_traffic': '🚥', 'bus_stop': '🚏', 'world_map': '🗺️',
            'statue_liberty': '🗽', 'tokyo_tower': '🗼', 'castle': '🏰', 'japanese_castle': '🏯',
            'stadium': '🏟️', 'ferris_wheel': '🎡', 'roller_coaster': '🎢', 'carousel': '🎠', 'fountain': '⛲',
            'beach_umbrella': '⛱️', 'beach': '🏖️', 'island': '🏝️', 'desert': '🏜️', 'volcano': '🌋',
            'mountain': '⛰️', 'snow_mountain': '🏔️', 'mount_fuji': '🗻', 'camping': '🏕️', 'hut': '🛖',
            'house': '🏠', 'house_garden': '🏡', 'derelict': '🏚️', 'building_construction': '🏗️', 'factory': '🏭',
            'office': '🏢', 'department_store': '🏬', 'post_office': '🏣', 'hospital': '🏥', 'bank': '🏦',
            'hotel': '🏨', 'convenience': '🏪', 'school': '🏫', 'love_hotel': '🏩', 'wedding': '💒',
            'classical': '🏛️', 'church': '⛪', 'mosque': '🕌', 'synagogue': '🕍', 'hindu_temple': '🛕',
            'kaaba': '🕋', 'shinto_shrine': '⛩️', 'railway_track': '🛤️', 'road': '🛣️',
            'sunrise': '🌅', 'sunrise_city': '🌄', 'night': '🌃', 'milky_way': '🌌', 'bridge_night': '🌉',
            // Weather
            'sun': '☀️', 'sun_clouds': '🌤️', 'partly_cloudy': '⛅', 'sun_behind_cloud': '🌥️', 'cloud': '☁️',
            'sun_rain': '🌦️', 'rain': '🌧️', 'thunder': '⛈️', 'lightning_cloud': '🌩️', 'snow_cloud': '🌨️',
            'snow': '❄️', 'snowman_snow': '☃️', 'snowman': '⛄', 'wind_face': '🌬️', 'wind': '💨',
            'tornado': '🌪️', 'fog': '🌫️', 'rainbow': '🌈', 'umbrella_rain': '☔', 'droplet': '💧',
            'wave': '🌊', 'moon': '🌙', 'crescent_moon': '🌛', 'last_quarter_face': '🌜', 'new_moon_face': '🌚',
            'full_moon': '🌕', 'waning_gibbous': '🌖', 'last_quarter': '🌗', 'waning_crescent': '🌘',
            'new_moon': '🌑', 'waxing_crescent': '🌒', 'first_quarter': '🌓', 'waxing_gibbous': '🌔',
            'earth_africa': '🌍', 'earth_americas': '🌎', 'earth_asia': '🌏', 'ringed_planet': '🪐',
            // Flags
            'white_flag': '🏳️', 'black_flag': '🏴', 'checkered_flag': '🏁', 'triangular_flag': '🚩',
            'rainbow_flag': '🏳️‍🌈', 'transgender_flag': '🏳️‍⚧️', 'pirate_flag': '🏴‍☠️',
            'us': '🇺🇸', 'gb': '🇬🇧', 'ca': '🇨🇦', 'au': '🇦🇺', 'de': '🇩🇪',
            'fr': '🇫🇷', 'jp': '🇯🇵', 'kr': '🇰🇷', 'cn': '🇨🇳', 'india': '🇮🇳',
            'br': '🇧🇷', 'mx': '🇲🇽', 'es': '🇪🇸', 'it': '🇮🇹', 'ru': '🇷🇺',
            'se': '🇸🇪', 'no': '🇳🇴', 'dk': '🇩🇰', 'fi': '🇫🇮', 'nl': '🇳🇱',
            'ch': '🇨🇭', 'pl': '🇵🇱', 'ua': '🇺🇦', 'tr': '🇹🇷', 'gr': '🇬🇷',
            'pt': '🇵🇹', 'ie': '🇮🇪', 'za': '🇿🇦', 'ng': '🇳🇬', 'eg': '🇪🇬',
            'ar': '🇦🇷', 'th': '🇹🇭', 'vn': '🇻🇳', 'id': '🇮🇩', 'ph': '🇵🇭',
            'sg': '🇸🇬', 'nz': '🇳🇿', 'sa': '🇸🇦', 'ae': '🇦🇪', 'il': '🇮🇱',
            'tw': '🇹🇼', 'hk': '🇭🇰', 'pr': '🇵🇷', 'cu': '🇨🇺', 'jm': '🇯🇲',
            // Aliases (restore original shortcodes that were renamed during expansion)
            'ok': '👌', 'money': '🤑', 'hearts': '💕', 'celebrate': '🙌',
            'sunglasses': '😎', 'nauseous': '🤢', 'cold_sweat': '😰',
            'scream_cat': '🙀', 'exploding': '🤯', 'clock': '🕐', 'sunset': '🌆',
            'joy': '😂', '+1': '👍', '-1': '👎', 'thumbs_up': '👍', 'thumbs_down': '👎',
            'fingers_crossed': '🤞', 'raised_hands': '🙌', 'pray_hands': '🙏',
            'flex': '💪', 'eyes_emoji': '👀', 'tongue_out': '😛', 'lol': '😂',
            'crying': '😭', 'smiling': '😊', 'kissing_heart': '😘', 'winking': '😉',
            'grinning_face': '😀', 'happy': '😊', 'smiley_face': '😃',
            'rolling_eyes': '🙄', 'face_palm': '🤦', 'shrugging': '🤷',
            'clapping': '👏', 'wave_hand': '👋', 'fist': '✊', 'punch': '👊',
            'pointing_up': '☝️', 'pointing_down': '👇', 'pointing_left': '👈', 'pointing_right': '👉',
            'red_heart': '❤️', 'love_heart': '❤️', 'heartbreak': '💔',
            'skull_emoji': '💀', 'poo': '💩', 'hundred': '💯', 'flames': '🔥',
            'sparkle': '✨', 'zap': '⚡', 'snow_emoji': '❄️', 'rain_emoji': '🌧️',
            'sun_emoji': '☀️', 'moon_emoji': '🌙', 'earth': '🌍', 'globe': '🌎',
            'usa': '🇺🇸', 'uk': '🇬🇧', 'canada': '🇨🇦', 'japan': '🇯🇵', 'germany': '🇩🇪',
            'france': '🇫🇷', 'brazil': '🇧🇷', 'mexico': '🇲🇽', 'italy': '🇮🇹',
            'pizza_emoji': '🍕', 'beer_emoji': '🍺', 'coffee_emoji': '☕', 'wine_emoji': '🍷',
            'rocket_emoji': '🚀', 'car_emoji': '🚗', 'airplane_emoji': '✈️',
            'money_bag': '💰', 'cash': '💵', 'btc': '₿'
        };
        this.discoveredChannelsIndex = 0;
        this.swipeStartX = null;
        this.swipeThreshold = 50;
        this.enhancedEmojiModal = null;
        this.loadRecentEmojis();
        this.lightningAddress = null;
        this.userLightningAddresses = new Map();
        this.userAvatars = new Map();
        this.userBanners = new Map();
        this.userBios = new Map();
        this.avatarBlobCache = new Map();
        this.avatarBlobInflight = new Map();
        this._avatarSvgCache = new Map();
        this.bannerBlobCache = new Map();
        this.bannerBlobInflight = new Map();
        this._proxyFetchQueue = [];
        this._proxyFetchActive = 0;
        this._proxyFetchMaxConcurrent = 3;
        this.profileFetchedAt = new Map();
        this._r2ProfileCache = new Map();
        this.R2_PROFILE_CACHE_TTL = 5 * 60 * 1000;
        this.profileFetchQueue = [];
        this.profileFetchTimer = null;
        this.profileFetchBatchDelay = 100;
        this.pendingProfileResolvers = new Map();
        this.localActiveStyle = null;
        this.shopItemsLoaded = false;
        this.zaps = new Map();
        this._zapReceiptEventIds = new Set();
        this._zapResubscribeTimer = null;
        this._zapReceiptSubId = null;
        this.currentZapTarget = null;
        this.currentZapInvoice = null;
        this.pendingLightningWaiters = new Map();
        this.zapCheckInterval = null;
        this.zapInvoiceData = null;
        this.listExpansionStates = new Map();
        this.userLocation = null;
        this.userColors = new Map();
        this.blurOthersImages = this.loadImageBlurSettings();
        this.sortByProximity = localStorage.getItem('nym_sort_proximity') === 'true';
        this.verifiedDeveloper = {
            npub: 'npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv',
            pubkey: 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df',
            title: 'Nymchat Developer'
        };
        this.verifiedBot = {
            pubkey: 'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2',
            title: 'Nymchat Bot'
        };
        this.verifiedBotPubkeys = new Set([this.verifiedBot.pubkey]);
        this.nymchatPubkeys.add(this.verifiedDeveloper.pubkey);
        this.nymchatPubkeys.add(this.verifiedBot.pubkey);
        // Seed nymbot into users map so it always appears in sidebar and mention autocomplete
        this.users.set(this.verifiedBot.pubkey, {
            nym: 'Nymbot',
            pubkey: this.verifiedBot.pubkey,
            lastSeen: Date.now(),
            status: 'online',
            channels: new Set()
        });
        // Seed nymbot avatar so it shows in sidebar and user list instead of the generated identicon
        this.userAvatars.set(this.verifiedBot.pubkey, 'https://nymchat.app/images/nymbot-icon.png');
        this.isFlutterWebView = /NymchatApp\//i.test(navigator.userAgent);
        this.shopItems = {
            styles: [
                {
                    id: 'style-satoshi',
                    name: 'Satoshi',
                    description: 'Bitcoin-themed orange glow',
                    price: 21420,
                    preview: 'style-preview-satoshi',
                    type: 'message-style',
                    tier: 'legendary',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Satoshi (Bitcoin)">
<title>Satoshi (Bitcoin)</title>
<circle cx="12" cy="12" r="9"/>
<path d="M9.3 6.8V17.2"/>
<path d="M9.3 6.8H13C15 6.8 16.2 7.9 16.2 9.6C16.2 11.3 15 12 13 12H9.3"/>
<path d="M9.3 12H13.4C15.5 12 16.7 13 16.7 14.6C16.7 16.2 15.5 17.2 13.4 17.2H9.3"/>
<path d="M11.2 5V6.8M13 5V6.8"/>
<path d="M11.2 17.2V19M13 17.2V19"/>
</svg>`
                },
                {
                    id: 'style-glitch',
                    name: 'Glitch',
                    description: 'Digital glitch effect',
                    price: 10101,
                    preview: 'style-preview-glitch',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Glitch">
<title>Glitch</title>
<rect x="3" y="5" width="18" height="12" rx="2"/>
<path d="M6 9H11 M13 9H18 M5 12H12 M14 12H17 M7 15H11 M12 15H18"/>
</svg>`
                },
                {
                    id: 'style-aurora',
                    name: 'Aurora',
                    description: 'Neon aurora gradient',
                    price: 2424,
                    preview: 'style-preview-aurora',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Aurora">
<title>Aurora</title>
<path d="M2 15 Q7 12 12 15 T22 15"/>
<path d="M2 12 Q7 9 12 12 T22 12"/>
<path d="M2 9 Q7 6 12 9 T22 9"/>
</svg>`
                },
                {
                    id: 'style-neon',
                    name: 'Neon',
                    description: 'Cyberpunk neon purple',
                    price: 1984,
                    preview: 'style-preview-neon',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Neon">
<title>Neon</title>
<rect x="3.5" y="5" width="17" height="12" rx="3"/>
<path d="M17 8v2 M16 9h2"/>
</svg>`
                },
                {
                    id: 'style-ghost',
                    name: 'Ghost',
                    description: 'Mysterious ethereal fade',
                    price: 666,
                    preview: 'style-preview-ghost',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Ghost">
<title>Ghost</title>
<path d="M12 4c-3.5 0-6 2.6-6 6v5.5c0 .8.7 1.5 1.5 1.5.7 0 1.3-.4 1.9-.9.6.6 1.4.9 2.6.9s2-.3 2.6-.9c.6.5 1.2.9 1.9.9.8 0 1.5-.7 1.5-1.5V10c0-3.4-2.5-6-6-6Z"/>
<circle cx="9.5" cy="11" r="1" fill="currentColor" stroke="none"/>
<circle cx="14.5" cy="11" r="1" fill="currentColor" stroke="none"/>
</svg>`
                },
                {
                    id: 'style-matrix',
                    name: 'Matrix',
                    description: 'Green terminal glow effect',
                    price: 1337,
                    preview: 'style-preview-matrix',
                    type: 'message-style',
                    tier: 'legendary',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Matrix">
<title>Matrix</title>
<rect x="3" y="5" width="18" height="12" rx="2"/>
<path d="M2 19H22"/>
<path d="M7 9V12 M10 8V12 M13 10V13 M16 8.5V13"/>
</svg>`
                },
                {
                    id: 'style-fire',
                    name: 'Fire',
                    description: 'Burning hot flame effect',
                    price: 911,
                    preview: 'style-preview-fire',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Fire">
<title>Fire</title>
<path d="M12 3c3 3 6 6 6 9.5 0 3.6-2.7 6.5-6 6.5s-6-2.9-6-6.5C6 9 9 6 12 3Z"/>
<path d="M12 8c1.9 1.7 3 3.4 3 5 0 1.9-1.3 3.5-3 3.5s-3-1.6-3-3.5c0-1.6 1.1-3.3 3-5Z"/>
</svg>`
                },
                {
                    id: 'style-ice',
                    name: 'Ice',
                    description: 'Cool frozen text effect',
                    price: 777,
                    preview: 'style-preview-ice',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Ice">
<title>Ice</title>
<path d="M12 2V22"/>
<path d="M2 12H22"/>
<path d="M4.9 6.5L19.1 17.5"/>
<path d="M19.1 6.5L4.9 17.5"/>
</svg>`
                },
                {
                    id: 'style-rainbow',
                    name: 'Rainbow',
                    description: 'Violet text with rainbow-arc watermark',
                    price: 2222,
                    preview: 'style-preview-rainbow',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Rainbow">
<title>Rainbow</title>
<path d="M4 16a8 8 0 0 1 16 0"/>
<path d="M6.5 16a5.5 5.5 0 0 1 11 0"/>
<path d="M9 16a3 3 0 0 1 6 0"/>
</svg>`
                },
                {
                    id: 'style-ocean',
                    name: 'Ocean',
                    description: 'Deep sea blue with waves',
                    price: 1500,
                    preview: 'style-preview-ocean',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Ocean">
<title>Ocean</title>
<path d="M2 8 Q5 5 8 8 T14 8 T20 8 T22 8"/>
<path d="M2 13 Q5 10 8 13 T14 13 T20 13 T22 13"/>
<path d="M2 18 Q5 15 8 18 T14 18 T20 18 T22 18"/>
</svg>`
                },
                {
                    id: 'style-sakura',
                    name: 'Sakura',
                    description: 'Soft pink cherry blossoms',
                    price: 3000,
                    preview: 'style-preview-sakura',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Sakura">
<title>Sakura</title>
<path d="M12 12c0-3-1.5-5-3-6 2 0 4 1.2 4 3.5"/>
<path d="M12 12c2.4-1.7 3-4.1 3-6 1.2 1.6 1.4 4-.5 5.4"/>
<path d="M12 12c2.9.6 5.2-.3 6.8-1.5-.4 2-2.3 3.4-4.6 3.1"/>
<path d="M12 12c1.1 2.7.6 5.1-.5 6.9-1.2-1.6-1.3-4 .2-5.6"/>
<path d="M12 12c-2.6 1.5-3.7 3.8-4.1 5.9-1.2-1.7-.9-4 1-5.3"/>
<circle cx="12" cy="12" r="1.3" fill="currentColor" stroke="none"/>
</svg>`
                },
                {
                    id: 'style-galaxy',
                    name: 'Galaxy',
                    description: 'Cosmic purple starfield',
                    price: 4444,
                    preview: 'style-preview-galaxy',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Galaxy">
<title>Galaxy</title>
<circle cx="12" cy="12" r="5"/>
<ellipse cx="12" cy="12" rx="10" ry="3.5" transform="rotate(-25 12 12)"/>
<circle cx="4" cy="6" r="0.6" fill="currentColor" stroke="none"/>
<circle cx="20" cy="18" r="0.6" fill="currentColor" stroke="none"/>
</svg>`
                },
                {
                    id: 'style-toxic',
                    name: 'Toxic',
                    description: 'Radioactive green hazard glow',
                    price: 1300,
                    preview: 'style-preview-toxic',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Toxic">
<title>Toxic</title>
<circle cx="12" cy="12" r="2.2"/>
<path d="M12 9.8V4.5a7.5 7.5 0 0 0-6.5 3.8l4.6 2.6"/>
<path d="M13.9 13l4.6 2.6A7.5 7.5 0 0 0 18.5 8.3L13.9 11"/>
<path d="M10.1 13l-4.6 2.6A7.5 7.5 0 0 0 12 19.5V14.2"/>
</svg>`
                },
                {
                    id: 'style-gold',
                    name: 'Midas',
                    description: 'Luxurious gold',
                    price: 8888,
                    preview: 'style-preview-gold',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Midas">
<title>Midas</title>
<circle cx="12" cy="12" r="8"/>
<circle cx="12" cy="12" r="5"/>
<path d="M12 9.5v5M10.5 11h2.2a1.2 1.2 0 0 1 0 2.4H10.5"/>
</svg>`
                },
                {
                    id: 'style-vapor',
                    name: 'Vaporwave',
                    description: 'Retro pink and cyan sunset',
                    price: 1995,
                    preview: 'style-preview-vapor',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Vaporwave">
<title>Vaporwave</title>
<path d="M6 11a6 6 0 0 1 12 0"/>
<path d="M7 7.5h10M6.4 9.2h11.2M6 11h12"/>
<path d="M3 15h18M5 18h14M8 21h8"/>
</svg>`
                },
                {
                    id: 'style-blood',
                    name: 'Blood',
                    description: 'Dark crimson blood-drop text',
                    price: 1313,
                    preview: 'style-preview-blood',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Blood">
<title>Blood</title>
<path d="M12 3c4 5 6 8 6 11a6 6 0 0 1-12 0c0-3 2-6 6-11Z"/>
<path d="M12 16a2.5 2.5 0 0 1-2.5-2.5"/>
</svg>`
                },
                {
                    id: 'style-royal',
                    name: 'Royal',
                    description: 'Regal purple with gold accents',
                    price: 6000,
                    preview: 'style-preview-royal',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Royal">
<title>Royal</title>
<path d="M4 8l3 9h10l3-9-4.5 3.5L12 6 8.5 11.5Z"/>
<circle cx="4" cy="8" r="1.2" fill="currentColor" stroke="none"/>
<circle cx="20" cy="8" r="1.2" fill="currentColor" stroke="none"/>
<circle cx="12" cy="6" r="1.2" fill="currentColor" stroke="none"/>
</svg>`
                },
                {
                    id: 'style-circuit',
                    name: 'Circuit',
                    description: 'Cyber circuit-board traces',
                    price: 2048,
                    preview: 'style-preview-circuit',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Circuit">
<title>Circuit</title>
<rect x="8" y="8" width="8" height="8" rx="1"/>
<path d="M12 8V4M12 20v-4M8 12H4M20 12h-4"/>
<circle cx="12" cy="4" r="1" fill="currentColor" stroke="none"/>
<circle cx="4" cy="12" r="1" fill="currentColor" stroke="none"/>
<circle cx="20" cy="12" r="1" fill="currentColor" stroke="none"/>
<circle cx="12" cy="20" r="1" fill="currentColor" stroke="none"/>
</svg>`
                }
            ],
            flair: [
                {
                    id: 'flair-crown',
                    name: 'Crown',
                    description: 'Royal golden crown badge',
                    price: 5000,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Crown">
<title>Crown</title>
<polyline points="3 9 7 13 12 7 17 13 21 9"/>
<path d="M5 18V13l4 2 3-5 3 5 4-2v5"/>
<path d="M4 18h16"/>
</svg>`
                },
                {
                    id: 'flair-diamond',
                    name: 'Diamond',
                    description: 'Brilliant diamond badge',
                    price: 10000,
                    type: 'nickname-flair',
                    tier: 'legendary',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Diamond">
<title>Diamond</title>
<polygon points="12 3 19 9 12 21 5 9"/>
<path d="M5 9h14"/>
<path d="M12 3L9 9M12 3L15 9"/>
</svg>`
                },
                {
                    id: 'flair-skull',
                    name: 'Skull',
                    description: 'Badass skull badge',
                    price: 1666,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Skull">
<title>Skull</title>
<path d="M12 3a8 8 0 0 0-8 8c0 2.6 1.3 4.6 3 5.7V19a1.5 1.5 0 0 0 1.5 1.5h7A1.5 1.5 0 0 0 17 19v-2.3c1.7-1.1 3-3.1 3-5.7a8 8 0 0 0-8-8Z"/>
<circle cx="9" cy="11" r="1.8" fill="currentColor" stroke="none"/>
<circle cx="15" cy="11" r="1.8" fill="currentColor" stroke="none"/>
<path d="M11 15.2 12 13.5l1 1.7Z"/>
<path d="M9.5 20.5v-2.5M12 20.5v-2.5M14.5 20.5v-2.5"/>
</svg>`
                },
                {
                    id: 'flair-star',
                    name: 'Star',
                    description: 'Shining star badge',
                    price: 2500,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Star">
<title>Star</title>
<polygon points="12 2 14.8 8.2 21.5 9 16.5 13.4 17.9 20 12 16.8 6.1 20 7.5 13.4 2.5 9 9.2 8.2"/>
</svg>`
                },
                {
                    id: 'flair-lightning',
                    name: 'Lightning',
                    description: 'Electric lightning bolt badge',
                    price: 2100,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Lightning">
<title>Lightning</title>
<polygon points="13 2 6 12 11 12 9 22 18 10 13 10"/>
</svg>`
                },
                {
                    id: 'flair-heart',
                    name: 'Heart',
                    description: 'Loving heart badge',
                    price: 1111,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Heart">
<title>Heart</title>
<path d="M12 21
    C7 17 4 14 4 10
    C4 7 6 5 9 5
    C11 5 12 7 12 7
    C12 7 13 5 15 5
    C18 5 20 7 20 10
    C20 14 17 17 12 21Z"/>
</svg>`
                },
                {
                    id: 'flair-mask',
                    name: 'Fawkes',
                    description: 'Anonymous mask badge',
                    price: 4200,
                    type: 'nickname-flair',
                    tier: 'legendary',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Mask">
<title>Mask</title>
<path d="M12 4c-4.4 0-8 1.8-8 4v3c0 4.6 3.6 8.6 8 9
    c4.4-.4 8-4.4 8-9V8c0-2.2-3.6-4-8-4Z"/>
<path d="M7.5 11c.9-1.2 2.7-1.2 3.5 0"/>
<path d="M13 11c.9-1.2 2.7-1.2 3.5 0"/>
<path d="M8 14c1.4 1 2.6 1 4 0c1.4 1 2.6 1 4 0"/>
</svg>`
                },
                {
                    id: 'flair-rocket',
                    name: 'Rocket',
                    description: 'To the moon badge',
                    price: 2300,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Rocket">
<title>Rocket</title>
<path d="M12 2.5c2.8 2 4.5 5.2 4.5 9 0 1.6-.3 3.1-.9 4.5H8.4A11 11 0 0 1 7.5 11.5c0-3.8 1.7-7 4.5-9Z"/>
<circle cx="12" cy="10" r="1.8"/>
<path d="M8.4 16 5.5 18l1.8.5L7.5 21l2-1.8"/>
<path d="M15.6 16l2.9 2-1.8.5.2 2.5-2-1.8"/>
</svg>`
                },
                {
                    id: 'flair-shield',
                    name: 'Shield',
                    description: 'Supporter of encryption badge',
                    price: 1900,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Shield">
<title>Shield</title>
<path d="M12 3l7 3v5c0 5-3.3 8.2-7 9.6C8.3 19.2 5 16 5 11V6l7-3Z"/>
<path d="M12 5v13"/>
</svg>`
                },
                {
                    id: 'flair-flame',
                    name: 'Flame',
                    description: 'Blazing fire badge',
                    price: 1200,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Flame">
<title>Flame</title>
<path d="M12 3c3 3 5.5 5.6 5.5 9.5A5.5 5.5 0 0 1 6.5 12.5C6.5 9.5 9 7 12 3Z"/>
<path d="M12 9c1.5 1.5 2.5 2.8 2.5 4.3A2.5 2.5 0 0 1 9.5 13c0-1 .6-2 2.5-4Z"/>
</svg>`
                },
                {
                    id: 'flair-snowflake',
                    name: 'Snowflake',
                    description: 'Frosty winter badge',
                    price: 1400,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Snowflake">
<title>Snowflake</title>
<g transform="rotate(0 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>
<g transform="rotate(60 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>
<g transform="rotate(120 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>
<g transform="rotate(180 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>
<g transform="rotate(240 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>
<g transform="rotate(300 12 12)"><path d="M12 12V2.5"/><path d="M12 5 9.9 3M12 5 14.1 3"/><path d="M12 7.6 10.3 6.1M12 7.6 13.7 6.1"/></g>
</svg>`
                },
                {
                    id: 'flair-moon',
                    name: 'Moon',
                    description: 'Mystic crescent moon badge',
                    price: 1600,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Moon">
<title>Moon</title>
<path d="M20 13.5A8 8 0 1 1 10.5 4a6.5 6.5 0 0 0 9.5 9.5Z"/>
<path d="M17 4.5 17.6 6 19 6.6 17.6 7.2 17 8.7 16.4 7.2 15 6.6 16.4 6Z" fill="currentColor" stroke="none"/>
</svg>`
                },
                {
                    id: 'flair-sun',
                    name: 'Sun',
                    description: 'Radiant sun badge',
                    price: 1500,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Sun">
<title>Sun</title>
<circle cx="12" cy="12" r="4"/>
<path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M19.1 4.9 17 7M7 17l-2.1 2.1"/>
</svg>`
                },
                {
                    id: 'flair-leaf',
                    name: 'Leaf',
                    description: 'Natural green leaf badge',
                    price: 900,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Leaf">
<title>Leaf</title>
<path d="M5 19c0-8 5-13 14-13 0 9-5 14-13 14-1 0-1-1-1-1Z"/>
<path d="M5 19C8 15 12 12 16 10"/>
</svg>`
                },
                {
                    id: 'flair-music',
                    name: 'Music',
                    description: 'Melodic music note badge',
                    price: 1100,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Music">
<title>Music</title>
<circle cx="7" cy="17" r="2.5"/>
<circle cx="17" cy="15" r="2.5"/>
<path d="M9.5 17V6l10-2v11"/>
<path d="M9.5 8.5 19.5 6.5"/>
</svg>`
                },
                {
                    id: 'flair-eye',
                    name: 'All-Seeing',
                    description: 'Watchful all-seeing eye badge',
                    price: 1800,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="All-Seeing Eye">
<title>All-Seeing Eye</title>
<path d="M2 12s4-6.5 10-6.5S22 12 22 12s-4 6.5-10 6.5S2 12 2 12Z"/>
<circle cx="12" cy="12" r="3"/>
<circle cx="12" cy="12" r="1" fill="currentColor" stroke="none"/>
</svg>`
                },
                {
                    id: 'flair-anchor',
                    name: 'Anchor',
                    description: 'Steadfast anchor badge',
                    price: 1000,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Anchor">
<title>Anchor</title>
<circle cx="12" cy="5" r="2"/>
<path d="M12 7v13"/>
<path d="M8 11h8"/>
<path d="M5 13a7 7 0 0 0 14 0"/>
</svg>`
                },
                {
                    id: 'flair-gem',
                    name: 'Ruby',
                    description: 'Precious ruby gem badge',
                    price: 3300,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Ruby">
<title>Ruby</title>
<path d="M7 4h10l4 5-9 11L3 9Z"/>
<path d="M3 9h18M7 4 9 9l3 11 3-11 2-5"/>
</svg>`
                }

            ],
            special: [
                {
                    id: 'supporter-badge',
                    name: 'Nymchat Supporter',
                    description: 'Special supporter badge with golden messages',
                    price: 42069,
                    type: 'supporter',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Trophy">
<title>Trophy</title>
<path d="M7 4h10v6a5 5 0 0 1-10 0V4z"/>
<path d="M7 6H4.5a2.5 2.5 0 0 0 2.5 2.5"/>
<path d="M17 6h2.5a2.5 2.5 0 0 1-2.5 2.5"/>
<path d="M12 15v3"/>
<path d="M9 21h6"/>
<path d="M10 18h4l.5 3h-5z"/>
</svg>`
                },
                {
                    id: 'cosmetic-aura-gold',
                    name: 'Gold Aura',
                    description: 'Golden glow around your messages',
                    price: 3500,
                    type: 'cosmetic',
                    cssClass: 'cosmetic-aura-gold',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Gold Aura">
<title>Gold Aura</title>
<circle cx="12" cy="12" r="8"/>
<circle cx="12" cy="12" r="5"/>
</svg>`
                },
                {
                    id: 'cosmetic-redacted',
                    name: 'Redacted',
                    description: 'Remove each message after 10 seconds',
                    price: 2800,
                    type: 'cosmetic',
                    cssClass: 'cosmetic-redacted',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Redacted">
<title>Redacted</title>
<line x1="4" y1="8" x2="20" y2="8"/>
<line x1="4" y1="12" x2="16" y2="12"/>
<line x1="4" y1="16" x2="18" y2="16"/>
</svg>`
                },
                {
                    id: 'cosmetic-aura-neon',
                    name: 'Neon Aura',
                    description: 'Electric cyan glow around your messages',
                    price: 3200,
                    type: 'cosmetic',
                    cssClass: 'cosmetic-aura-neon',
                    benefits: ['Neon-cyan glow', 'Stands out in any channel'],
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Neon Aura">
<title>Neon Aura</title>
<rect x="6" y="6" width="12" height="12" rx="3"/>
<path d="M3 9V5a2 2 0 0 1 2-2h4M21 9V5a2 2 0 0 0-2-2h-4M3 15v4a2 2 0 0 0 2 2h4M21 15v4a2 2 0 0 1-2 2h-4"/>
</svg>`
                },
                {
                    id: 'cosmetic-aura-rainbow',
                    name: 'Prism Aura',
                    description: 'Legendary rainbow ring that wraps your whole message',
                    price: 11000,
                    type: 'cosmetic',
                    tier: 'legendary',
                    cssClass: 'cosmetic-aura-rainbow',
                    benefits: ['Full rainbow ring', 'Legendary tier flex'],
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Prism Aura">
<title>Prism Aura</title>
<path d="M12 4 19 17H5Z"/>
<path d="M2 10.5 9 12.4"/>
<path d="M13.4 12.6 21.5 10.2"/>
<path d="M13.7 13.9 21.5 13.4"/>
<path d="M13.9 15.2 21.5 16.6"/>
<path d="M14.1 16.4 20.5 19.4"/>
</svg>`
                },
                {
                    id: 'cosmetic-frost',
                    name: 'Frostbite',
                    description: 'Frosted-glass message with icy snowflake accents',
                    price: 2600,
                    type: 'cosmetic',
                    cssClass: 'cosmetic-frost',
                    benefits: ['Frosted-glass message backdrop', 'Subtle snowflake pattern'],
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Frostbite">
<title>Frostbite</title>
<rect x="4" y="6" width="16" height="12" rx="2"/>
<path d="M12 8.5v7M9 10l6 3.5M15 10l-6 3.5"/>
</svg>`
                },
                {
                    id: 'cosmetic-aura-phoenix',
                    name: 'Phoenix Aura',
                    description: 'Legendary rising-flame aura around your messages',
                    price: 12000,
                    type: 'cosmetic',
                    tier: 'legendary',
                    cssClass: 'cosmetic-aura-phoenix',
                    benefits: ['Rising-ember glow', 'Legendary tier flex'],
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Phoenix Aura">
<title>Phoenix Aura</title>
<path d="M12 6.2a1.7 1.7 0 0 1 1.7-1.7c0 .8-.3 1.4-.9 1.8"/>
<path d="M12 6.8C9 4.2 5.4 4 3 5.8c2 .3 2.9 1.6 2.7 3.3 1.7-1.1 3.4-.8 4.5.8"/>
<path d="M12 6.8C15 4.2 18.6 4 21 5.8c-2 .3-2.9 1.6-2.7 3.3-1.7-1.1-3.4-.8-4.5.8"/>
<path d="M12 7v7"/>
<path d="M12 14c-1.9 1.3-2.5 3.3-1.7 5.2.8-.6 1.2-1.1 1.7-2.1.5 1 .9 1.5 1.7 2.1.8-1.9.2-3.9-1.7-5.2z"/>
</svg>`
                },
                {
                    id: 'cosmetic-aura-cosmic',
                    name: 'Cosmic Aura',
                    description: 'Starfield aura around your messages',
                    price: 5000,
                    type: 'cosmetic',
                    cssClass: 'cosmetic-aura-cosmic',
                    benefits: ['Starfield halo', 'Deep-space glow'],
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Cosmic Aura">
<title>Cosmic Aura</title>
<circle cx="11" cy="12" r="4.5"/>
<ellipse cx="11" cy="12" rx="9" ry="3" transform="rotate(-22 11 12)"/>
<path d="M19 5.5 19.6 7.1 21.2 7.7 19.6 8.3 19 9.9 18.4 8.3 16.8 7.7 18.4 7.1Z" fill="currentColor" stroke="none"/>
<circle cx="4.5" cy="6" r="0.7" fill="currentColor" stroke="none"/>
</svg>`
                },
                {
                    id: 'cosmetic-bubble-hologram',
                    name: 'Holographic',
                    description: 'Legendary holographic finish on your whole message',
                    price: 13500,
                    type: 'cosmetic',
                    tier: 'legendary',
                    cssClass: 'cosmetic-bubble-hologram',
                    benefits: ['Iridescent holographic bubble', 'Legendary tier flex'],
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Hologram Bubble">
<title>Holographic</title>
<path d="M5 5h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-7l-4 4v-4H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z"/>
<path d="M8 9.5h8M8 12.5h5"/>
</svg>`
                }
            ],
            limited: [
                {
                    id: 'flair-genesis',
                    name: 'Genesis',
                    description: 'Founders-only numbered emblem. Only 100 will ever exist.',
                    price: 25000,
                    type: 'nickname-flair',
                    tier: 'legendary',
                    maxSupply: 100,
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Genesis">
<title>Genesis</title>
<path d="M12 2.5 22 21H2Z"/>
</svg>`
                },
                {
                    id: 'style-eclipse',
                    name: 'Eclipse',
                    description: 'A rare eclipse-themed message style. Limited drop of 1,000.',
                    price: 9000,
                    type: 'message-style',
                    maxSupply: 1000,
                    startsAt: 1735689600000,
                    endsAt: 1798761600000,
                    preview: 'style-preview-eclipse',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Eclipse">
<title>Eclipse</title>
<circle cx="12" cy="12" r="8"/>
<path d="M15 5.2a8 8 0 0 1 0 13.6 8 8 0 0 0 0-13.6Z" fill="currentColor" stroke="none"/>
</svg>`
                },
                {
                    id: 'style-crt',
                    name: 'CRT',
                    description: 'A limited drop of 250. Amber-phosphor terminal text with scanlines.',
                    price: 12000,
                    type: 'message-style',
                    tier: 'legendary',
                    maxSupply: 250,
                    startsAt: 1735689600000,
                    endsAt: 1798761600000,
                    preview: 'style-preview-crt',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="CRT monitor">
<title>CRT</title>
<rect x="3" y="4" width="18" height="13" rx="2"/>
<path d="M8 21h8M12 17v4"/>
<path d="M6 7.5h9M6 10.5h7M6 13.5h5"/>
</svg>`
                }
            ],
            bundles: [
                {
                    id: 'bundle-starter',
                    name: 'Starter Pack',
                    description: 'Flame flair, Ice style and Frostbite cosmetic at a discount.',
                    price: 3000,
                    type: 'bundle',
                    bundle: ['flair-flame', 'style-ice', 'cosmetic-frost'],
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Starter Pack">
<title>Starter Pack</title>
<path d="M4 8h16v3H4zM5 11h14v9H5zM12 8v12"/>
<path d="M12 8C10 8 8 7 8 5.5S10 4 12 8ZM12 8c2 0 4-1 4-2.5S14 4 12 8Z"/>
</svg>`
                },
                {
                    id: 'bundle-legendary',
                    name: 'Legendary Vault',
                    description: 'All three legendary cosmetics together — best value.',
                    price: 30000,
                    type: 'bundle',
                    bundle: ['cosmetic-aura-phoenix', 'cosmetic-aura-rainbow', 'cosmetic-bubble-hologram'],
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Legendary Vault">
<title>Legendary Vault</title>
<path d="M4 9h16v3H4zM5 12h14v8H5zM12 9v11"/>
<path d="M6 9 9 4l3 5 3-5 3 5"/>
</svg>`
                },
                {
                    id: 'bundle-everything',
                    name: 'Everything Pack',
                    description: 'Every message style, flair and special item in one go — the ultimate discount. (Excludes limited numbered editions.)',
                    price: 149999,
                    type: 'bundle',
                    // Components filled in below from the full catalog.
                    bundle: [],
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Everything Pack">
<title>Everything Pack</title>
<path d="M3 8h18v3H3zM4 11h16v9H4zM12 8v12"/>
<path d="M12 8C9.5 8 7 6.8 7 5S9.5 3 12 8ZM12 8c2.5 0 5-1.2 5-3S14.5 3 12 8Z"/>
<path d="M9 14.5l1.5 1.5L9 17.5M15 14.5l-1.5 1.5 1.5 1.5"/>
</svg>`
                }
            ]
        };

        // The Everything Pack grants every non-limited, non-bundle item. Build
        // its component list from the catalog so it can't drift out of sync.
        const _everythingIds = [
            ...this.shopItems.styles,
            ...this.shopItems.flair,
            ...this.shopItems.special
        ].filter(it => !it.maxSupply).map(it => it.id);
        const _everything = this.shopItems.bundles.find(b => b.id === 'bundle-everything');
        if (_everything) _everything.bundle = _everythingIds;

        this.userPurchases = new Map();
        this.activeShopTab = 'styles';
        this.activeMessageStyle = null;
        this.activeFlairs = new Set();
        this.otherUsersShopItems = new Map();
        this.shopItemsCache = new Map();
        this.activeCosmetics = new Set();
        this.supporterBadgeActive = true;
        this.loadShopActiveCache();
        this._restoreShopRecordFromCache();
    }

}

// Global instance.
// Instantiated inside DOMContentLoaded so that all module files (which attach
// methods to NYM.prototype via Object.assign) have been parsed first.
// The constructor invokes methods like _getApiHost() and fetchGeoRelays(),
// so those methods must be present on the prototype before `new NYM()` runs.
let nym;

// Global functions for onclick handlers
function toggleSidebar() {
    nym.toggleSidebar();
}

function toggleSearch(inputId) {
    const wrapper = document.getElementById(inputId + 'Wrapper');
    const search = document.getElementById(inputId);
    if (wrapper) {
        wrapper.classList.toggle('active');
        if (wrapper.classList.contains('active')) {
            search.focus();
        } else {
            // Clear search when hiding
            clearSearch(inputId);
        }
    } else {
        // Fallback for inputs without wrapper
        search.classList.toggle('active');
        if (search.classList.contains('active')) {
            search.focus();
        }
    }
}

function toggleSectionCollapse(sectionId) {
    if (nym && typeof nym.toggleSidebarSectionCollapse === 'function') {
        nym.toggleSidebarSectionCollapse(sectionId);
    }
}

function clearSearch(inputId) {
    const search = document.getElementById(inputId);
    const wrapper = document.getElementById(inputId + 'Wrapper');
    if (search) {
        search.value = '';
        if (wrapper) {
            wrapper.classList.remove('has-value', 'active');
        }
        // Trigger the appropriate filter to reset the list
        if (inputId === 'pmSearch') {
            nym.filterPMs('');
        } else if (inputId === 'channelSearch') {
            nym.handleChannelSearch('');
        } else if (inputId === 'userSearch') {
            nym.filterUsers('');
        }
    }
}

function scrollToBottom() {
    const scroller = document.getElementById('messagesScroller');
    if (!scroller) return;

    nym.userScrolledUp = false;

    if (nym._scrollRAF) {
        cancelAnimationFrame(nym._scrollRAF);
        nym._scrollRAF = null;
    }

    // Trim any lazy-loaded older history so the DOM bottom is the real latest.
    if (nym.inPMMode) {
        const convKey = nym.currentGroup
            ? nym.getGroupConversationKey(nym.currentGroup)
            : (nym.currentPM ? nym.getPMConversationKey(nym.currentPM) : null);
        if (convKey && typeof nym.collapsePMToLatest === 'function') {
            nym.collapsePMToLatest(convKey);
        }
    } else {
        const storageKey = nym.currentGeohash ? `#${nym.currentGeohash}` : nym.currentChannel;
        if (storageKey && typeof nym.collapseChannelToLatest === 'function') {
            nym.collapseChannelToLatest(storageKey);
        }
    }

    scroller.scrollTop = 0;
    nym._scheduleScrollToBottom(true);
}

function sendMessage() {
    nym.sendMessage();
}

function previewTextSize(value) {
    const label = document.getElementById('textSizeValue');
    if (label) label.textContent = value + 'px';
    document.documentElement.style.setProperty('--user-text-size', value + 'px');
}

function commitTextSize(value) {
    const size = parseInt(value, 10);
    nym.settings.textSize = size;
    localStorage.setItem('nym_text_size', String(size));
    document.documentElement.style.setProperty('--user-text-size', size + 'px');
    nostrSettingsSave();
}

function resetTextSize() {
    const slider = document.getElementById('textSizeSlider');
    const label = document.getElementById('textSizeValue');
    if (slider) slider.value = 15;
    if (label) label.textContent = '15px';
    document.documentElement.style.setProperty('--user-text-size', '15px');
    nym.settings.textSize = 15;
    localStorage.setItem('nym_text_size', '15');
    nostrSettingsSave();
}

function applyTransparency(enabled) {
    if (enabled) {
        document.body.classList.remove('solid-ui');
    } else {
        document.body.classList.add('solid-ui');
    }
}

function onTransparencyChange(value) {
    const enabled = value === 'true' || value === true;
    nym.settings.transparencyEnabled = enabled;
    localStorage.setItem('nym_transparency_enabled', String(enabled));
    applyTransparency(enabled);
    // Block stale settings echoes from older relay-cached events from
    // overriding the user's new choice and causing the UI to flicker.
    nym._lastSettingsSyncTs = Math.floor(Date.now() / 1000);
    try { localStorage.setItem('nym_last_settings_sync_ts', String(nym._lastSettingsSyncTs)); } catch (_) { }
    nostrSettingsSave();
}

function nymSuppressLongPressForFileDialog() {
    window.__nymFileDialogActive = true;
    const clear = () => {
        // Small delay so trailing touch events that leak through as the native
        // sheet dismisses are still suppressed.
        setTimeout(() => { window.__nymFileDialogActive = false; }, 400);
        window.removeEventListener('focus', clear);
        document.removeEventListener('visibilitychange', onVisible);
    };
    const onVisible = () => { if (document.visibilityState === 'visible') clear(); };
    window.addEventListener('focus', clear, { once: true });
    document.addEventListener('visibilitychange', onVisible);
    // Safety net in case neither focus nor visibilitychange ever fires.
    setTimeout(() => { window.__nymFileDialogActive = false; }, 10000);
}

function selectImage() {
    nymSuppressLongPressForFileDialog();
    document.getElementById('fileInput').click();
}

function selectP2PFile() {
    nymSuppressLongPressForFileDialog();
    document.getElementById('p2pFileInput').click();
}

function closeModal(id) {
    document.getElementById(id).classList.remove('active');
}

function closeImageModal() {
    document.getElementById('imageModal').classList.remove('active');
    if (window.resetImageModalZoom) window.resetImageModalZoom();
    window._imageModalGallery = null;
    if (typeof window.updateImageModalGalleryNav === 'function') window.updateImageModalGalleryNav();
    const modalVid = document.getElementById('modalVideo');
    modalVid.pause();
    if (modalVid.dataset.ownBlob) {
        URL.revokeObjectURL(modalVid.dataset.ownBlob);
        delete modalVid.dataset.ownBlob;
        delete modalVid.dataset.blobLoaded;
    }
    modalVid.removeAttribute('src');
    while (modalVid.firstChild) modalVid.firstChild.remove();
    modalVid.load();
}

function downloadModalMedia(event) {
    event.stopPropagation();
    const modalImg = document.getElementById('modalImage');
    const modalVid = document.getElementById('modalVideo');
    let src = '';
    let defaultName = 'download';

    if (getComputedStyle(modalImg).display !== 'none' && modalImg.src) {
        src = modalImg.src;
        const ext = src.split('.').pop().split('?')[0].toLowerCase();
        const imageExts = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
        defaultName = 'image.' + (imageExts.includes(ext) ? ext : 'jpg');
    } else if (getComputedStyle(modalVid).display !== 'none') {
        src = modalVid.src || (modalVid.querySelector('source') && modalVid.querySelector('source').src) || '';
        const ext = src.split('.').pop().split('?')[0].toLowerCase();
        const videoExts = ['mp4', 'webm', 'ogg', 'mov'];
        defaultName = 'video.' + (videoExts.includes(ext) ? ext : 'mp4');
    }

    if (!src) return;

    fetch(src)
        .then(resp => resp.blob())
        .then(blob => {
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = defaultName;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
        })
        .catch(() => {
            // Fallback: open in new tab
            window.open(src, '_blank');
        });
}

// Image modal pinch-to-zoom and swipe-to-close gestures
(function () {
    const MIN_SCALE = 1;
    const MAX_SCALE = 5;
    let img, modal;
    let scale = 1, tx = 0, ty = 0;
    let startScale = 1, startTx = 0, startTy = 0;
    let startDist = 0, startMidX = 0, startMidY = 0;
    let startX = 0, startY = 0;
    let mode = null;
    let moved = false;
    let lastTap = 0;

    function apply(animate) {
        img.classList.toggle('gesture-animating', !!animate);
        img.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
    }

    function reset(animate) {
        scale = 1; tx = 0; ty = 0;
        if (img) {
            apply(animate);
            modal.style.background = '';
        }
    }
    window.resetImageModalZoom = function () { reset(false); };

    function clampPan() {
        const maxX = Math.max(0, (img.offsetWidth * scale - img.offsetWidth) / 2);
        const maxY = Math.max(0, (img.offsetHeight * scale - img.offsetHeight) / 2);
        tx = Math.min(maxX, Math.max(-maxX, tx));
        ty = Math.min(maxY, Math.max(-maxY, ty));
    }

    function dist(t) {
        return Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);
    }

    function onStart(e) {
        const t = e.touches;
        moved = false;
        if (t.length === 2) {
            mode = 'pinch';
            startScale = scale;
            startTx = tx; startTy = ty;
            startDist = dist(t);
            startMidX = (t[0].clientX + t[1].clientX) / 2;
            startMidY = (t[0].clientY + t[1].clientY) / 2;
        } else if (t.length === 1) {
            startX = t[0].clientX;
            startY = t[0].clientY;
            startTx = tx; startTy = ty;
            mode = scale > MIN_SCALE ? 'pan' : 'swipe';
        }
        img.classList.remove('gesture-animating');
    }

    function onMove(e) {
        const t = e.touches;
        if (mode === 'pinch' && t.length === 2) {
            e.preventDefault();
            moved = true;
            scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, startScale * (dist(t) / startDist)));
            const midX = (t[0].clientX + t[1].clientX) / 2;
            const midY = (t[0].clientY + t[1].clientY) / 2;
            tx = startTx + (midX - startMidX);
            ty = startTy + (midY - startMidY);
            apply(false);
        } else if (mode === 'pan' && t.length === 1) {
            e.preventDefault();
            moved = true;
            tx = startTx + (t[0].clientX - startX);
            ty = startTy + (t[0].clientY - startY);
            apply(false);
        } else if (mode === 'swipe' && t.length === 1) {
            const dx = t[0].clientX - startX;
            const dy = t[0].clientY - startY;
            if (Math.hypot(dx, dy) > 6) moved = true;
            tx = dx; ty = dy;
            const progress = Math.min(1, Math.hypot(dx, dy) / 300);
            modal.style.background = `rgba(0, 0, 0, ${0.4 * (1 - progress)})`;
            apply(false);
        }
    }

    function updateGalleryNavButtons() {
        const prev = document.getElementById('imageModalPrev');
        const next = document.getElementById('imageModalNext');
        if (!prev || !next) return;
        const g = window._imageModalGallery;
        if (!g || g.sources.length <= 1) {
            prev.style.display = 'none';
            next.style.display = 'none';
            return;
        }
        prev.style.display = g.index > 0 ? '' : 'none';
        next.style.display = g.index < g.sources.length - 1 ? '' : 'none';
    }
    window.updateImageModalGalleryNav = updateGalleryNavButtons;

    function navigateGallery(delta) {
        const g = window._imageModalGallery;
        if (!g) return false;
        const next = g.index + delta;
        if (next < 0 || next >= g.sources.length) return false;
        g.index = next;
        const newSrc = g.sources[next];
        scale = 1; tx = 0; ty = 0;
        img.style.transition = 'opacity 0.12s linear, transform 0.18s ease';
        img.style.opacity = '0';
        img.style.transform = 'translate(0,0) scale(1)';
        modal.style.background = '';
        setTimeout(() => {
            img.src = newSrc;
            img.style.opacity = '';
            updateGalleryNavButtons();
            setTimeout(() => { img.style.transition = ''; }, 200);
        }, 120);
        return true;
    }
    window.navigateImageModalGallery = navigateGallery;

    function onEnd(e) {
        if (mode === 'swipe') {
            const g = window._imageModalGallery;
            const hasGallery = g && g.sources.length > 1;
            const horizontal = Math.abs(tx) > Math.abs(ty);
            if (hasGallery && horizontal) {
                if (Math.abs(tx) > 60) {
                    const delta = tx < 0 ? 1 : -1;
                    if (navigateGallery(delta)) return;
                }
                reset(true);
                return;
            }
            const closeDist = hasGallery ? Math.abs(ty) : Math.hypot(tx, ty);
            if (closeDist > 100) {
                window.closeImageModal();
                return;
            }
            reset(true);
        } else if (mode === 'pinch' || mode === 'pan') {
            if (scale <= MIN_SCALE) {
                reset(true);
            } else {
                clampPan();
                apply(true);
            }
        }
        if (e.touches.length === 0) mode = null;
    }

    function onDoubleTap(e) {
        const now = Date.now();
        if (now - lastTap < 300 && e.changedTouches.length === 1) {
            e.preventDefault();
            if (scale > MIN_SCALE) reset(true);
            else { scale = 2.5; apply(true); }
        }
        lastTap = now;
    }

    function setup() {
        img = document.getElementById('modalImage');
        modal = document.getElementById('imageModal');
        if (!img || !modal) return;
        img.addEventListener('touchstart', onStart, { passive: false });
        img.addEventListener('touchmove', onMove, { passive: false });
        img.addEventListener('touchend', onEnd);
        img.addEventListener('touchcancel', onEnd);
        img.addEventListener('touchend', onDoubleTap, { passive: false });
        img.addEventListener('click', (e) => {
            if (moved || scale > MIN_SCALE) {
                e.stopPropagation();
                moved = false;
            }
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', setup);
    } else {
        setup();
    }
})();

function addPollOption() {
    const container = document.getElementById('pollOptionsContainer');
    const existing = container.querySelectorAll('[data-poll-option]');
    if (existing.length >= 6) {
        document.getElementById('pollAddOptionBtn').style.display = 'none';
        return;
    }
    const row = document.createElement('div');
    row.className = 'poll-option-input-row';
    row.innerHTML = `
        <input type="text" class="form-input" placeholder="Option ${existing.length + 1}" maxlength="100" data-poll-option>
        <button class="poll-remove-option-btn" data-action="removeParent" title="Remove">✕</button>
    `;
    container.appendChild(row);
    if (existing.length + 1 >= 6) {
        document.getElementById('pollAddOptionBtn').style.display = 'none';
    }
}

function submitPoll() {
    const question = document.getElementById('pollQuestion').value.trim();
    if (!question) {
        window.showAppAlert('Please enter a question.');
        return;
    }
    const optionInputs = document.querySelectorAll('[data-poll-option]');
    const options = [];
    optionInputs.forEach(input => {
        const val = input.value.trim();
        if (val) options.push(val);
    });
    if (options.length < 2) {
        window.showAppAlert('Please add at least 2 options.');
        return;
    }
    nym.publishPoll(question, options);
    closeModal('pollModal');
}

function editNick() {
    // Only show the base nym (without #suffix) in the editable field
    const baseNym = nym.parseNymFromDisplay(nym.nym);
    document.getElementById('newNickInput').value = baseNym;
    // Show the non-editable suffix next to the input
    const suffix = nym.getPubkeySuffix(nym.pubkey);
    const suffixEl = document.getElementById('nickSuffixDisplay');
    suffixEl.textContent = `#${suffix}`;
    suffixEl.title = 'Click to view full pubkey';

    // Click handler to toggle full pubkey slide-out
    suffixEl.onclick = (e) => {
        e.stopPropagation();
        const slideout = document.getElementById('pubkeySlideout');
        if (!slideout) return;
        const valueEl = document.getElementById('pubkeySlideoutValue');
        const copyBtn = document.getElementById('pubkeySlideoutCopy');
        if (valueEl) valueEl.textContent = nym.pubkey;
        if (copyBtn) {
            copyBtn.textContent = 'Copy';
            copyBtn.onclick = (ev) => {
                ev.stopPropagation();
                navigator.clipboard.writeText(nym.pubkey);
                copyBtn.textContent = 'Copied!';
                setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1200);
            };
        }
        slideout.classList.toggle('open');
    };

    // Reset pubkey slide-out state
    const pubkeySlideout = document.getElementById('pubkeySlideout');
    if (pubkeySlideout) pubkeySlideout.classList.remove('open');

    // Show current avatar in edit modal and reset upload UI state
    const preview = document.getElementById('nickEditAvatarPreview');
    if (preview) {
        preview.src = nym.getAvatarUrl(nym.pubkey);
    }
    const hasCustom = nym.userAvatars.has(nym.pubkey);
    setAvatarUploadState('nickEdit', {
        spinning: false, statusText: '', statusType: '',
        btnText: 'Change photo', btnDisabled: false, showRemove: hasCustom
    });

    // Show current banner in edit modal
    const bannerPreview = document.getElementById('nickEditBannerPreview');
    const bannerPlaceholder = document.getElementById('nickEditBannerPlaceholder');
    const bannerUrl = nym.getBannerUrl(nym.pubkey);
    if (bannerUrl) {
        if (bannerPreview) { bannerPreview.src = bannerUrl; bannerPreview.style.display = 'block'; }
        if (bannerPlaceholder) bannerPlaceholder.style.display = 'none';
        setBannerUploadState({
            spinning: false, statusText: '', statusType: '',
            btnText: 'Change banner', btnDisabled: false, showRemove: true
        });
    } else {
        if (bannerPreview) { bannerPreview.src = ''; bannerPreview.style.display = 'none'; }
        if (bannerPlaceholder) bannerPlaceholder.style.display = 'flex';
        setBannerUploadState({
            spinning: false, statusText: '', statusType: '',
            btnText: 'Choose banner', btnDisabled: false, showRemove: false
        });
    }

    // Show current bio in edit modal
    const bioInput = document.getElementById('nickEditBioInput');
    if (bioInput) {
        const currentBio = nym.getBio(nym.pubkey);
        bioInput.value = currentBio;
        updateBioCharCount();
    }

    // Show current lightning address in edit modal
    const lnInput = document.getElementById('nickEditLightningInput');
    if (lnInput) {
        lnInput.value = nym.lightningAddress || '';
    }

    // Reset private key reveal state
    const privkeySlideout = document.getElementById('privkeySlideout');
    if (privkeySlideout) privkeySlideout.style.display = 'none';
    const privkeyArrow = document.getElementById('revealPrivkeyArrow');
    if (privkeyArrow) privkeyArrow.innerHTML = '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" class="nm-vam"><path d="M 6 3 L 11 8 L 6 13 Z"/></svg>';
    const nsecInput = document.getElementById('revealedNsecValue');
    if (nsecInput) { nsecInput.value = ''; nsecInput.type = 'password'; }
    // Hide reveal privkey option for extension login (no local privkey)
    const revealGroup = document.getElementById('revealPrivkeyGroup');
    if (revealGroup) {
        revealGroup.style.display = (nym.nostrLoginMethod === 'extension') ? 'none' : 'block';
    }

    document.getElementById('nickEditModal').classList.add('active');
}

function updateBioCharCount() {
    const bioInput = document.getElementById('nickEditBioInput');
    const charCount = document.getElementById('nickEditBioCharCount');
    if (!bioInput || !charCount) return;
    const len = bioInput.value.length;
    const max = 150;
    charCount.textContent = `${len}/${max}`;
    charCount.classList.remove('warning', 'limit');
    if (len >= max) {
        charCount.classList.add('limit');
    } else if (len >= max * 0.8) {
        charCount.classList.add('warning');
    }
}

async function changeNick() {
    const newNick = document.getElementById('newNickInput').value.trim();
    // Strip any # suffix the user may have typed - the suffix is derived from pubkey
    const baseNick = nym.parseNymFromDisplay(newNick);
    const currentBase = nym.parseNymFromDisplay(nym.nym);

    const nickAlsoChanging = baseNick && baseNick !== currentBase;
    let profileDirty = false;

    // Save bio regardless of nick change
    const bioInput = document.getElementById('nickEditBioInput');
    if (bioInput) {
        const newBio = bioInput.value.trim().substring(0, 150);
        const currentBio = nym.getBio(nym.pubkey);
        if (newBio !== currentBio) {
            nym.userBios.set(nym.pubkey, newBio);
            localStorage.setItem('nym_bio', newBio);
            profileDirty = true;
        }
    }

    // Save lightning address regardless of nick change
    const lnInput = document.getElementById('nickEditLightningInput');
    if (lnInput) {
        const newLn = lnInput.value.trim();
        if (newLn !== (nym.lightningAddress || '')) {
            if (newLn) {
                nym.lightningAddress = newLn;
                localStorage.setItem(`nym_lightning_address_${nym.pubkey}`, newLn);
                localStorage.setItem('nym_lightning_address_global', newLn);
            } else {
                nym.lightningAddress = null;
                localStorage.removeItem(`nym_lightning_address_${nym.pubkey}`);
                localStorage.removeItem('nym_lightning_address_global');
            }
            nym.updateLightningAddressDisplay();
            profileDirty = true;
        }
    }

    if (nickAlsoChanging) {
        // cmdNick will publish the kind 0 profile (which includes bio + lightning changes)
        closeModal('nickEditModal');
        const cmdResult = await nym.cmdNick(baseNick);
        // If auto-ephemeral is enabled, persist the new nickname so it's reused on next session
        if (localStorage.getItem('nym_auto_ephemeral') === 'true') {
            localStorage.setItem('nym_auto_ephemeral_nick', baseNick);
            // For reserved (developer) nicks, also save the verified nsec for auto-login
            if (cmdResult && cmdResult.nsec) {
                nymSecretSet('nym_dev_nsec', cmdResult.nsec);
            }
        }
        // If cmdNick was cancelled (e.g. reserved nick) but bio/lightning changed,
        // still publish those changes to relays
        if (!cmdResult && profileDirty) {
            await nym.saveToNostrProfile();
        }
        nym.displaySystemMessage("Nym's profile changes saved");
        return;
    }

    // Always publish profile to nostr relays when user clicks Change,
    // so avatar, banner, bio, and lightning changes are all persisted
    await nym.saveToNostrProfile();
    closeModal('nickEditModal');
    nym.displaySystemMessage("Nym's profile changes saved");
}

function randomizeNick() {
    const generated = nym.generateRandomNym();
    // Extract base name without #suffix
    const baseName = nym.stripPubkeySuffix(generated);
    document.getElementById('newNickInput').value = baseName;

    // Randomize the generated avatar preview if no custom avatar is set
    if (!nym.userAvatars.has(nym.pubkey)) {
        const preview = document.getElementById('nickEditAvatarPreview');
        if (preview) {
            preview.src = nym.generateAvatarSvg(baseName);
        }
    }
}

// Pre-generated keypair from setup modal avatar upload (reused in initializeNym)
let setupKeypair = null;
// Uploaded avatar URL from setup modal (applied to profile in initializeNym)
let setupAvatarUrl = null;
// Uploaded banner URL from setup modal
let setupBannerUrl = null;

function setAvatarUploadState(prefix, { spinning, statusText, statusType, btnText, btnDisabled, showRemove }) {
    const spinner = document.getElementById(prefix + 'AvatarSpinner');
    const status = document.getElementById(prefix + 'AvatarStatus');
    const uploadBtn = document.getElementById(prefix + 'AvatarUploadBtn');
    const removeBtn = document.getElementById(prefix + 'AvatarRemoveBtn');
    if (spinner) spinner.classList.toggle('active', !!spinning);
    if (status) {
        status.textContent = statusText || '';
        status.className = 'avatar-upload-status' + (statusType ? ' ' + statusType : '');
    }
    if (uploadBtn && btnText !== undefined) {
        uploadBtn.textContent = btnText;
        uploadBtn.disabled = !!btnDisabled;
    }
    if (removeBtn && showRemove !== undefined) {
        removeBtn.style.display = showRemove ? 'inline-flex' : 'none';
    }
}

async function handleSetupAvatarSelect(event) {
    const file = event?.target?.files?.[0];
    if (!file) return;

    if (file.type && !file.type.startsWith('image/')) {
        setAvatarUploadState('setup', { statusText: 'Please select an image file', statusType: 'error' });
        return;
    }
    if (file.size > 5 * 1024 * 1024) {
        setAvatarUploadState('setup', { statusText: 'Image must be under 5MB', statusType: 'error' });
        return;
    }

    const preview = document.getElementById('setupAvatarPreview');

    // Show local preview immediately using object URL (like wallpaper uploader)
    if (preview) {
        preview.src = URL.createObjectURL(file);
    }

    // Show uploading state
    setAvatarUploadState('setup', {
        spinning: true,
        statusText: 'Uploading avatar...',
        statusType: 'uploading',
        btnText: 'Uploading...',
        btnDisabled: true,
        showRemove: false
    });

    // Generate keypair in background if not already done
    if (!setupKeypair) {
        setupKeypair = await nym.generateKeypair();
    }

    const url = await nym.uploadAvatar(file);

    if (url) {
        setupAvatarUrl = url;
        if (preview) preview.src = url;
        setAvatarUploadState('setup', {
            spinning: false,
            statusText: 'Avatar uploaded successfully',
            statusType: 'success',
            btnText: 'Change photo',
            btnDisabled: false,
            showRemove: true
        });
    } else {
        if (preview) preview.src = nym.generateAvatarSvg(setupKeypair?.pubkey || 'default');
        setAvatarUploadState('setup', {
            spinning: false,
            statusText: 'Upload failed — try again',
            statusType: 'error',
            btnText: 'Choose photo',
            btnDisabled: false,
            showRemove: false
        });
    }

    // Reset file input
    event.target.value = '';
}

function removeSetupAvatar() {
    setupAvatarUrl = null;
    if (setupKeypair) {
        const oldBlob = nym.avatarBlobCache.get(nym.pubkey);
        if (oldBlob) { URL.revokeObjectURL(oldBlob); nym.avatarBlobCache.delete(nym.pubkey); }
        nym.userAvatars.delete(nym.pubkey);
        localStorage.removeItem('nym_avatar_url');
    }
    const preview = document.getElementById('setupAvatarPreview');
    if (preview) preview.src = nym.generateAvatarSvg(setupKeypair?.pubkey || 'default');
    setAvatarUploadState('setup', {
        spinning: false, statusText: '', statusType: '',
        btnText: 'Choose photo', btnDisabled: false, showRemove: false
    });
}

// Banner upload handler for setup modal
async function handleSetupBannerSelect(event) {
    const file = event?.target?.files?.[0];
    if (!file) return;

    if (file.type && !file.type.startsWith('image/')) {
        setSetupBannerUploadState({ statusText: 'Please select an image file', statusType: 'error' });
        return;
    }
    if (file.size > 10 * 1024 * 1024) {
        setSetupBannerUploadState({ statusText: 'Image must be under 10MB', statusType: 'error' });
        return;
    }

    const preview = document.getElementById('setupBannerPreview');
    const placeholder = document.getElementById('setupBannerPlaceholder');

    if (preview) {
        preview.src = URL.createObjectURL(file);
        preview.style.display = 'block';
    }
    if (placeholder) placeholder.style.display = 'none';

    setSetupBannerUploadState({
        spinning: true,
        statusText: 'Uploading banner...',
        statusType: 'uploading',
        btnText: 'Uploading...',
        btnDisabled: true,
        showRemove: false
    });

    // Generate keypair in background if not already done
    if (!setupKeypair) {
        setupKeypair = await nym.generateKeypair();
    }

    const url = await nym.uploadBanner(file);

    if (url) {
        setupBannerUrl = url;
        if (preview) preview.src = url;
        setSetupBannerUploadState({
            spinning: false,
            statusText: 'Banner uploaded successfully',
            statusType: 'success',
            btnText: 'Change banner',
            btnDisabled: false,
            showRemove: true
        });
    } else {
        if (preview) { preview.style.display = 'none'; }
        if (placeholder) placeholder.style.display = 'flex';
        setSetupBannerUploadState({
            spinning: false,
            statusText: 'Upload failed — try again',
            statusType: 'error',
            btnText: 'Choose banner',
            btnDisabled: false,
            showRemove: false
        });
    }

    event.target.value = '';
}

function setSetupBannerUploadState({ spinning, statusText, statusType, btnText, btnDisabled, showRemove }) {
    const spinner = document.getElementById('setupBannerSpinner');
    const status = document.getElementById('setupBannerStatus');
    const uploadBtn = document.getElementById('setupBannerUploadBtn');
    const removeBtn = document.getElementById('setupBannerRemoveBtn');
    if (spinner) spinner.classList.toggle('active', !!spinning);
    if (status) {
        status.textContent = statusText || '';
        status.className = 'avatar-upload-status' + (statusType ? ' ' + statusType : '');
    }
    if (uploadBtn && btnText !== undefined) {
        uploadBtn.textContent = btnText;
        uploadBtn.disabled = !!btnDisabled;
    }
    if (removeBtn && showRemove !== undefined) {
        removeBtn.style.display = showRemove ? 'inline-flex' : 'none';
    }
}

function removeSetupBanner() {
    setupBannerUrl = null;
    const preview = document.getElementById('setupBannerPreview');
    const placeholder = document.getElementById('setupBannerPlaceholder');
    if (preview) { preview.src = ''; preview.style.display = 'none'; }
    if (placeholder) placeholder.style.display = 'flex';
    localStorage.removeItem('nym_banner_url');
    setSetupBannerUploadState({
        spinning: false, statusText: '', statusType: '',
        btnText: 'Choose banner', btnDisabled: false, showRemove: false
    });
}

function updateSetupBioCharCount() {
    const input = document.getElementById('setupBioInput');
    const counter = document.getElementById('setupBioCharCount');
    if (input && counter) {
        counter.textContent = input.value.length + '/150';
    }
}

// Reveal private key functions for nick edit modal
function toggleRevealPrivkey() {
    const slideout = document.getElementById('privkeySlideout');
    const arrow = document.getElementById('revealPrivkeyArrow');
    if (!slideout) return;

    const isHidden = getComputedStyle(slideout).display === 'none';
    slideout.style.display = isHidden ? 'block' : 'none';
    if (arrow) arrow.innerHTML = isHidden ? '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" class="nm-vam"><path d="M 3 6 L 8 11 L 13 6 Z"/></svg>' : '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" class="nm-vam"><path d="M 6 3 L 11 8 L 6 13 Z"/></svg>';

    if (isHidden) {
        // Populate the nsec value
        const nsecInput = document.getElementById('revealedNsecValue');
        if (nsecInput && nym.privkey) {
            try {
                const nsec = window.NostrTools.nip19.nsecEncode(nym.privkey);
                nsecInput.value = nsec;
            } catch (e) {
                nsecInput.value = 'Unable to encode private key';
            }
        } else if (nsecInput) {
            nsecInput.value = 'No private key available (using browser extension)';
        }
    }
}

function toggleNsecVisibility() {
    const input = document.getElementById('revealedNsecValue');
    if (!input) return;
    input.type = input.type === 'password' ? 'text' : 'password';
}

function copyRevealedNsec() {
    const input = document.getElementById('revealedNsecValue');
    if (!input) return;
    navigator.clipboard.writeText(input.value).then(() => {
        const btn = document.getElementById('nsecCopyBtn');
        if (btn) {
            const orig = btn.innerHTML;
            btn.textContent = 'Copied!';
            setTimeout(() => { btn.innerHTML = orig; }, 2000);
        }
    });
}

// Avatar upload handler for nick edit modal (uploads immediately since keypair exists)
async function handleNickEditAvatarSelect(event) {
    const file = event?.target?.files?.[0];
    if (!file) return;

    if (file.type && !file.type.startsWith('image/')) {
        setAvatarUploadState('nickEdit', { statusText: 'Please select an image file', statusType: 'error' });
        return;
    }
    if (file.size > 5 * 1024 * 1024) {
        setAvatarUploadState('nickEdit', { statusText: 'Image must be under 5MB', statusType: 'error' });
        return;
    }

    const preview = document.getElementById('nickEditAvatarPreview');

    // Show local preview immediately using object URL (like wallpaper uploader)
    if (preview) {
        preview.src = URL.createObjectURL(file);
    }

    // Show uploading state
    setAvatarUploadState('nickEdit', {
        spinning: true,
        statusText: 'Uploading avatar...',
        statusType: 'uploading',
        btnText: 'Uploading...',
        btnDisabled: true,
        showRemove: false
    });

    const url = await nym.uploadAvatar(file);

    if (url) {
        if (preview) preview.src = url;
        setAvatarUploadState('nickEdit', {
            spinning: false,
            statusText: 'Avatar updated successfully',
            statusType: 'success',
            btnText: 'Change photo',
            btnDisabled: false,
            showRemove: true
        });
    } else {
        if (preview) preview.src = nym.getAvatarUrl(nym.pubkey);
        setAvatarUploadState('nickEdit', {
            spinning: false,
            statusText: 'Upload failed — try again',
            statusType: 'error',
            btnText: 'Change photo',
            btnDisabled: false
        });
    }

    // Reset file input
    event.target.value = '';
}

function removeNickEditAvatar() {
    nym.removeAvatar();
    const preview = document.getElementById('nickEditAvatarPreview');
    if (preview) {
        preview.src = nym.getAvatarUrl(nym.pubkey);
    }
    setAvatarUploadState('nickEdit', {
        spinning: false, statusText: '', statusType: '',
        btnText: 'Change photo', btnDisabled: false, showRemove: false
    });
}

// Banner upload handler for nick edit modal
async function handleNickEditBannerSelect(event) {
    const file = event?.target?.files?.[0];
    if (!file) return;

    if (file.type && !file.type.startsWith('image/')) {
        setBannerUploadState({ statusText: 'Please select an image file', statusType: 'error' });
        return;
    }
    if (file.size > 10 * 1024 * 1024) {
        setBannerUploadState({ statusText: 'Image must be under 10MB', statusType: 'error' });
        return;
    }

    const preview = document.getElementById('nickEditBannerPreview');
    const placeholder = document.getElementById('nickEditBannerPlaceholder');

    if (preview) {
        preview.src = URL.createObjectURL(file);
        preview.style.display = 'block';
    }
    if (placeholder) placeholder.style.display = 'none';

    setBannerUploadState({
        spinning: true,
        statusText: 'Uploading banner...',
        statusType: 'uploading',
        btnText: 'Uploading...',
        btnDisabled: true,
        showRemove: false
    });

    const url = await nym.uploadBanner(file);

    if (url) {
        if (preview) preview.src = url;
        setBannerUploadState({
            spinning: false,
            statusText: 'Banner uploaded successfully',
            statusType: 'success',
            btnText: 'Change banner',
            btnDisabled: false,
            showRemove: true
        });
    } else {
        if (preview) { preview.style.display = 'none'; }
        if (placeholder) placeholder.style.display = 'flex';
        setBannerUploadState({
            spinning: false,
            statusText: 'Upload failed — try again',
            statusType: 'error',
            btnText: 'Choose banner',
            btnDisabled: false,
            showRemove: false
        });
    }

    event.target.value = '';
}

function setBannerUploadState({ spinning, statusText, statusType, btnText, btnDisabled, showRemove }) {
    const spinner = document.getElementById('nickEditBannerSpinner');
    const status = document.getElementById('nickEditBannerStatus');
    const uploadBtn = document.getElementById('nickEditBannerUploadBtn');
    const removeBtn = document.getElementById('nickEditBannerRemoveBtn');
    if (spinner) spinner.classList.toggle('active', !!spinning);
    if (status) {
        status.textContent = statusText || '';
        status.className = 'avatar-upload-status' + (statusType ? ' ' + statusType : '');
    }
    if (uploadBtn && btnText !== undefined) {
        uploadBtn.textContent = btnText;
        uploadBtn.disabled = !!btnDisabled;
    }
    if (removeBtn && showRemove !== undefined) {
        removeBtn.style.display = showRemove ? 'inline-flex' : 'none';
    }
}

function removeNickEditBanner() {
    nym.removeBanner();
    const preview = document.getElementById('nickEditBannerPreview');
    const placeholder = document.getElementById('nickEditBannerPlaceholder');
    if (preview) { preview.src = ''; preview.style.display = 'none'; }
    if (placeholder) placeholder.style.display = 'flex';
    setBannerUploadState({
        spinning: false, statusText: '', statusType: '',
        btnText: 'Choose banner', btnDisabled: false, showRemove: false
    });
}

// Developer nsec verification modal state
let devNsecResolve = null;
let devNsecContext = null;

function showDevNsecModal(context) {
    return new Promise((resolve) => {
        devNsecResolve = resolve;
        devNsecContext = context;
        document.getElementById('devNsecInput').value = '';
        document.getElementById('devNsecError').style.display = 'none';
        document.getElementById('devNsecModal').classList.add('active');
    });
}

function cancelDevNsec() {
    closeModal('devNsecModal');
    if (devNsecResolve) {
        devNsecResolve(null);
        devNsecResolve = null;
    }
}

function verifyDevNsec() {
    const nsec = document.getElementById('devNsecInput').value.trim();
    const result = nym.verifyDeveloperNsec(nsec);
    if (result.valid) {
        document.getElementById('devNsecError').style.display = 'none';
        closeModal('devNsecModal');
        if (devNsecResolve) {
            devNsecResolve({ ...result, nsec });
            devNsecResolve = null;
        }
    } else {
        document.getElementById('devNsecError').style.display = 'block';
    }
}

async function showSettings() {
    nym.updateRelayStatus();
    window.restoreSettingsSectionState();

    // Load color mode setting (auto-save and auto-apply on click)
    const colorModeGroup = document.getElementById('colorModeGroup');
    if (colorModeGroup) {
        const currentMode = nym.getColorMode();
        colorModeGroup.querySelectorAll('.color-mode-btn').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.mode === currentMode);
            btn.onclick = () => {
                colorModeGroup.querySelectorAll('.color-mode-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                localStorage.setItem('nym_color_mode', btn.dataset.mode);
                nym.applyColorMode();
                nostrSettingsSave();
            };
        });
    }

    // Load proximity sorting setting
    const proximitySelect = document.getElementById('proximitySelect');
    if (proximitySelect) {
        proximitySelect.value = nym.settings.sortByProximity ? 'true' : 'false';
    }

    // Load blur settings
    const blurSelect = document.getElementById('blurImagesSelect');
    if (blurSelect) {
        blurSelect.value = nym.blurOthersImages === 'friends' ? 'friends' : (nym.blurOthersImages ? 'true' : 'false');
    }

    // Load auto-ephemeral setting (hidden, kept for compatibility)
    const autoEphemeralSelect = document.getElementById('autoEphemeralSelect');
    if (autoEphemeralSelect) {
        const autoEphemeral = localStorage.getItem('nym_auto_ephemeral') === 'true';
        autoEphemeralSelect.value = autoEphemeral ? 'true' : 'false';
    }

    // Load random keypair per session setting
    const randomKeypairSelect = document.getElementById('randomKeypairSelect');
    if (randomKeypairSelect) {
        if (isNostrLoggedIn()) {
            // Disable keypair rotation for logged-in users — it would conflict with their identity
            randomKeypairSelect.value = 'persistent';
            randomKeypairSelect.disabled = true;
            randomKeypairSelect.title = 'Not available while logged in with a Nostr identity';
        } else {
            randomKeypairSelect.disabled = false;
            randomKeypairSelect.title = '';
            const keypairMode = localStorage.getItem('nym_keypair_mode');
            if (keypairMode) {
                randomKeypairSelect.value = keypairMode;
            } else {
                // Migrate legacy boolean setting
                const randomKeypair = localStorage.getItem('nym_random_keypair_per_session') === 'true';
                randomKeypairSelect.value = randomKeypair ? 'random' : 'persistent';
            }
        }
        const hardcoreWarning = document.getElementById('hardcoreKeypairWarning');
        if (hardcoreWarning) hardcoreWarning.style.display = randomKeypairSelect.value === 'hardcore' ? 'block' : 'none';
    }

    // Load translation language setting
    const translateLangSelect = document.getElementById('translateLanguageSelect');
    if (translateLangSelect) {
        translateLangSelect.value = nym.settings.translateLanguage || '';
    }

    const gesturesEnabledSelect = document.getElementById('gesturesEnabledSelect');
    const swipeLeftSelect = document.getElementById('swipeLeftActionSelect');
    const swipeRightSelect = document.getElementById('swipeRightActionSelect');
    const swipeThresholdSelect = document.getElementById('swipeThresholdSelect');
    const swipeLeftGroup = document.getElementById('swipeLeftActionGroup');
    const swipeRightGroup = document.getElementById('swipeRightActionGroup');
    const swipeThresholdGroup = document.getElementById('swipeThresholdGroup');
    const swipeReactEmojiGroup = document.getElementById('swipeReactEmojiGroup');
    const swipeReactEmojiBtn = document.getElementById('swipeReactEmojiBtn');
    const swipeReactEmojiPreview = document.getElementById('swipeReactEmojiPreview');
    if (gesturesEnabledSelect) {
        gesturesEnabledSelect.value = nym.settings.gesturesEnabled !== false ? 'true' : 'false';
    }
    if (swipeLeftSelect) swipeLeftSelect.value = nym.settings.swipeLeftAction || 'quote';
    if (swipeRightSelect) swipeRightSelect.value = nym.settings.swipeRightAction || 'translate';
    if (swipeThresholdSelect) {
        const t = String(nym.settings.swipeThreshold || 60);
        swipeThresholdSelect.value = ['40', '60', '80', '100'].includes(t) ? t : '60';
    }
    let pendingReactEmoji = nym.settings.swipeReactEmoji || '❤️';
    const renderEmojiPreview = (emoji) => {
        if (!swipeReactEmojiPreview) return;
        const m = typeof emoji === 'string' && emoji.match(/^:([a-zA-Z0-9_]+):$/);
        if (m && nym.customEmojis && nym.customEmojis.has(m[1])) {
            swipeReactEmojiPreview.innerHTML = nym.renderCustomEmojiImg(m[1], 'swipe-react-emoji-preview-img') || nym.escapeHtml(emoji);
        } else {
            swipeReactEmojiPreview.textContent = emoji;
        }
    };
    renderEmojiPreview(pendingReactEmoji);
    const openSwipeReactEmojiPicker = () => {
        if (!swipeReactEmojiBtn || typeof nym.showEnhancedReactionPicker !== 'function') return;
        nym.showEnhancedReactionPicker(null, swipeReactEmojiBtn, (emoji) => {
            pendingReactEmoji = emoji;
            nym.settings.swipeReactEmoji = emoji;
            localStorage.setItem('nym_swipe_react_emoji', emoji);
            renderEmojiPreview(emoji);
        });
    };
    if (swipeReactEmojiBtn) swipeReactEmojiBtn.onclick = openSwipeReactEmojiPicker;

    const updateSwipeSubsettings = () => {
        const show = !gesturesEnabledSelect || gesturesEnabledSelect.value === 'true';
        if (swipeLeftGroup) swipeLeftGroup.style.display = show ? '' : 'none';
        if (swipeRightGroup) swipeRightGroup.style.display = show ? '' : 'none';
        if (swipeThresholdGroup) swipeThresholdGroup.style.display = show ? '' : 'none';
        const needsEmoji = show && (swipeLeftSelect?.value === 'react' || swipeRightSelect?.value === 'react');
        if (swipeReactEmojiGroup) swipeReactEmojiGroup.style.display = needsEmoji ? '' : 'none';
    };
    updateSwipeSubsettings();
    if (gesturesEnabledSelect) gesturesEnabledSelect.onchange = updateSwipeSubsettings;

    const handleSwipeActionChange = (selectEl) => {
        if (!selectEl) return;
        const prev = selectEl.dataset.prevValue || nym.settings[selectEl.id === 'swipeLeftActionSelect' ? 'swipeLeftAction' : 'swipeRightAction'] || '';
        if (selectEl.value === 'react' && prev !== 'react' && !localStorage.getItem('nym_swipe_react_emoji')) {
            openSwipeReactEmojiPicker();
        }
        selectEl.dataset.prevValue = selectEl.value;
        updateSwipeSubsettings();
    };
    if (swipeLeftSelect) {
        swipeLeftSelect.dataset.prevValue = swipeLeftSelect.value;
        swipeLeftSelect.onchange = () => handleSwipeActionChange(swipeLeftSelect);
    }
    if (swipeRightSelect) {
        swipeRightSelect.dataset.prevValue = swipeRightSelect.value;
        swipeRightSelect.onchange = () => handleSwipeActionChange(swipeRightSelect);
    }

    // Load nickname style setting
    const nickStyleSelect = document.getElementById('nickStyleSelect');
    if (nickStyleSelect) {
        nickStyleSelect.value = nym.settings.nickStyle || 'fancy';
    }

    // Load hide non-pinned channels setting
    const hideNonPinnedSelect = document.getElementById('hideNonPinnedSelect');
    if (hideNonPinnedSelect) {
        hideNonPinnedSelect.value = nym.hideNonPinned ? 'true' : 'false';
    }

    // Populate hidden channels list
    nym.updateHiddenChannelsList();

    // Initialize pinned landing channel searchable dropdown
    const pinnedSearchInput = document.getElementById('pinnedLandingChannelSearch');
    const pinnedValueInput = document.getElementById('pinnedLandingChannelValue');
    const pinnedDropdown = document.getElementById('pinnedLandingChannelDropdown');

    if (pinnedSearchInput && pinnedValueInput && pinnedDropdown) {
        // Get current pinned value
        const currentPinned = nym.pinnedLandingChannel || { type: 'geohash', geohash: 'nymchat' };

        // Build geohash channel options only
        const channelOptions = [];

        // Add common geohashes
        nym.commonGeohashes.forEach(geohash => {
            const location = nym.getGeohashLocation(geohash);
            channelOptions.push({
                group: 'Common Geohash Channels',
                label: location ? `#${geohash} (${location})` : `#${geohash}`,
                value: { type: 'geohash', geohash: geohash },
                searchText: (geohash + ' ' + (location || '')).toLowerCase()
            });
        });

        // Add user's joined geohash channels (excluding already listed ones)
        Array.from(nym.channels.entries())
            .filter(([key, val]) => nym.isValidGeohash(key) && !nym.commonGeohashes.includes(key))
            .forEach(([geohash]) => {
                const location = nym.getGeohashLocation(geohash);
                channelOptions.push({
                    group: 'Joined Geohash Channels',
                    label: location ? `#${geohash} (${location})` : `#${geohash}`,
                    value: { type: 'geohash', geohash: geohash },
                    searchText: (geohash + ' ' + (location || '')).toLowerCase()
                });
            });

        // Set current value
        const currentOption = channelOptions.find(opt =>
            JSON.stringify(opt.value) === JSON.stringify(currentPinned)
        );
        if (currentOption) {
            pinnedSearchInput.value = currentOption.label;
            pinnedValueInput.value = JSON.stringify(currentOption.value);
        } else {
            pinnedSearchInput.value = '#nymchat';
            pinnedValueInput.value = JSON.stringify({ type: 'geohash', geohash: 'nymchat' });
        }

        // Function to render filtered options
        const renderOptions = (filter = '') => {
            const filterLower = filter.toLowerCase().replace(/^#/, '');
            const filtered = filter
                ? channelOptions.filter(opt => opt.searchText.includes(filterLower))
                : channelOptions;

            if (filtered.length === 0) {
                pinnedDropdown.innerHTML = '<div class="nm-app-1">No channels found</div>';
                return;
            }

            // Group options
            const grouped = {};
            filtered.forEach(opt => {
                if (!grouped[opt.group]) grouped[opt.group] = [];
                grouped[opt.group].push(opt);
            });

            // Render grouped options
            let html = '';
            Object.keys(grouped).forEach(groupName => {
                html += `<div class="nm-app-2">${groupName}</div>`;
                grouped[groupName].forEach(opt => {
                    html += `<div class="channel-dropdown-option nm-app-3" data-value='${JSON.stringify(opt.value)}'>${opt.label}</div>`;
                });
            });

            pinnedDropdown.innerHTML = html;

            // Add click handlers
            pinnedDropdown.querySelectorAll('.channel-dropdown-option').forEach(option => {
                option.addEventListener('mouseenter', function () {
                    this.style.background = 'var(--background)';
                });
                option.addEventListener('mouseleave', function () {
                    this.style.background = 'transparent';
                });
                option.addEventListener('click', function () {
                    const valueData = JSON.parse(this.dataset.value);
                    pinnedSearchInput.value = this.textContent;
                    pinnedValueInput.value = this.dataset.value;
                    pinnedDropdown.style.display = 'none';
                });
            });
        };

        // Show dropdown on focus
        pinnedSearchInput.addEventListener('focus', () => {
            renderOptions(pinnedSearchInput.value);
            pinnedDropdown.style.display = 'block';
        });

        // Filter on input
        pinnedSearchInput.addEventListener('input', () => {
            renderOptions(pinnedSearchInput.value);
            pinnedDropdown.style.display = 'block';
        });

        // Hide dropdown on blur (with delay for click to register)
        pinnedSearchInput.addEventListener('blur', () => {
            setTimeout(() => {
                pinnedDropdown.style.display = 'none';
            }, 200);
        });

        // Prevent dropdown from closing when clicking inside it
        pinnedDropdown.addEventListener('mousedown', (e) => {
            e.preventDefault();
        });
    }

    const themeSelect = document.getElementById('themeSelect');
    themeSelect.value = nym.settings.theme;
    themeSelect.onchange = function () {
        nym.settings.theme = this.value;
        nym.applyTheme(this.value);
        nym.saveSettings();
        nostrSettingsSave();
    };

    document.getElementById('soundSelect').value = nym.settings.sound;
    document.getElementById('autoscrollSelect').value = nym.settings.autoscroll;
    document.getElementById('timestampSelect').value = nym.settings.showTimestamps;
    document.getElementById('timeFormatSelect').value = nym.settings.timeFormat;
    const dateFormatSelectEl = document.getElementById('dateFormatSelect');
    if (dateFormatSelectEl) dateFormatSelectEl.value = nym.settings.dateFormat || 'default';

    // Show/hide time format option based on timestamp visibility
    const dateFormatGroup = document.getElementById('dateFormatGroup');
    if (dateFormatGroup) {
        dateFormatGroup.style.display = nym.settings.showTimestamps ? 'block' : 'none';
    }
    const timeFormatGroup = document.getElementById('timeFormatGroup');
    if (timeFormatGroup) {
        timeFormatGroup.style.display = nym.settings.showTimestamps ? 'block' : 'none';
    }

    nym.updateBlockedList();
    nym.updateFriendsList();
    nym.updateKeywordList();
    nym.updateBlockedChannelsList();

    // Fill in accept PMs setting
    const acceptPMsSel = document.getElementById('acceptPMsSelect');
    if (acceptPMsSel) {
        acceptPMsSel.value = nym.settings.acceptPMs || 'enabled';
    }

    const acceptCallsSel = document.getElementById('acceptCallsSelect');
    if (acceptCallsSel) {
        acceptCallsSel.value = nym.settings.acceptCalls || 'enabled';
    }

    // Fill in disappearing message controls
    const dmEnabledSel = document.getElementById('dmForwardSecrecySelect');
    const dmTtlSel = document.getElementById('dmTTLSelect');
    const dmTtlGroup = document.getElementById('dmTTLGroup');

    if (dmEnabledSel && dmTtlSel && dmTtlGroup) {
        dmEnabledSel.value = nym.settings.dmForwardSecrecyEnabled ? 'true' : 'false';
        dmTtlSel.value = String(nym.settings.dmTTLSeconds || 86400);
        dmTtlGroup.style.display = nym.settings.dmForwardSecrecyEnabled ? 'block' : 'none';

        dmEnabledSel.onchange = () => {
            dmTtlGroup.style.display = dmEnabledSel.value === 'true' ? 'block' : 'none';
        };
    }

    const VALID_INDICATOR_SCOPES = ['disabled', 'pms', 'groups', 'pms-groups', 'everywhere'];
    const readReceiptsSel = document.getElementById('readReceiptsSelect');
    if (readReceiptsSel) {
        const scope = nym.settings.readReceiptsScope;
        readReceiptsSel.value = VALID_INDICATOR_SCOPES.includes(scope) ? scope : 'everywhere';
    }

    const typingIndicatorsSel = document.getElementById('typingIndicatorsSelect');
    if (typingIndicatorsSel) {
        const scope = nym.settings.typingIndicatorsScope;
        typingIndicatorsSel.value = VALID_INDICATOR_SCOPES.includes(scope) ? scope : 'everywhere';
    }

    // Fill in show-status toggle
    const showStatusSel = document.getElementById('showStatusSelect');
    if (showStatusSel) {
        showStatusSel.value = nym.settings.showStatus !== false ? 'true' : 'false';
    }

    // Fill in cache-PMs toggle
    const cachePMsSel = document.getElementById('cachePMsSelect');
    if (cachePMsSel) {
        cachePMsSel.value = nym.settings.cachePMs !== false ? 'true' : 'false';
    }

    // Initialize wallpaper UI selection
    initWallpaperUI();

    // Initialize message layout selection
    const currentLayout = nym.settings.chatLayout || 'irc';
    document.querySelectorAll('.layout-option').forEach(opt => {
        opt.classList.toggle('selected', opt.dataset.layout === currentLayout);
    });

    // Initialize transparency toggle
    const transparencySel = document.getElementById('transparencySelect');
    if (transparencySel) {
        transparencySel.value = nym.settings.transparencyEnabled === true ? 'true' : 'false';
    }

    // Initialize text size slider
    const textSizeSlider = document.getElementById('textSizeSlider');
    const textSizeValue = document.getElementById('textSizeValue');
    if (textSizeSlider) {
        const currentSize = nym.settings.textSize || 15;
        textSizeSlider.value = currentSize;
        if (textSizeValue) textSizeValue.textContent = currentSize + 'px';
    }

    // Initialize group chat & PM only mode toggle
    const gcPmOnlySelect = document.getElementById('groupChatPMOnlySelect');
    if (gcPmOnlySelect) {
        gcPmOnlySelect.value = nym.settings.groupChatPMOnlyMode ? 'true' : 'false';
        // Show/hide geohash-related settings based on current mode
        const geohashSettings = document.querySelectorAll('[data-geohash-setting]');
        geohashSettings.forEach(el => {
            el.style.display = nym.settings.groupChatPMOnlyMode ? 'none' : '';
        });
        gcPmOnlySelect.onchange = function () {
            const enabled = this.value === 'true';
            geohashSettings.forEach(el => {
                el.style.display = enabled ? 'none' : '';
            });
        };
    }

    // Initialize low data mode select
    const lowDataSelect = document.getElementById('lowDataModeSelect');
    if (lowDataSelect) {
        lowDataSelect.value = nym.settings.lowDataMode ? 'true' : 'false';
    }

    const powDifficultySelect = document.getElementById('powDifficultySelect');
    if (powDifficultySelect) {
        powDifficultySelect.value = localStorage.getItem('nym_pow_difficulty') || '0';
    }

    // Render pending settings transfers
    nym.renderPendingSettingsTransfers();

    // Refresh the app cache size display
    refreshAppCacheSize();

    document.getElementById('settingsModal').classList.add('active');
}

// Format a byte count into a short human-readable string (e.g. 1.2 MB).
function formatCacheBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    let i = 0;
    let n = bytes;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return `${n.toFixed(n >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

// Update the cache size readout in the settings modal
async function countAppCacheItems() {
    const counts = { profiles: 0, channels: 0, pms: 0, reactions: 0, totalBytes: 0 };
    if (!nym || typeof nym._cacheGetAll !== 'function') return counts;
    try {
        const [profiles, channels, pms, reactions] = await Promise.all([
            nym._cacheGetAll('profiles'),
            nym._cacheGetAll('channels'),
            nym._cacheGetAll('pms'),
            nym._cacheGetAll('reactions')
        ]);
        counts.profiles = profiles.length;
        counts.channels = channels.length;
        counts.pms = pms.length;
        counts.reactions = reactions.length;
        const all = [].concat(profiles, channels, pms, reactions);
        for (const r of all) {
            try { counts.totalBytes += JSON.stringify(r).length; } catch (_) { }
        }
    } catch (_) { }
    return counts;
}

async function probeAppCacheWritable() {
    if (!nym || typeof nym._cachePut !== 'function' || typeof nym._cacheGetAll !== 'function') {
        return { ok: false, reason: 'no cache module' };
    }
    if (nym._cacheDisabled) return { ok: false, reason: 'cache disabled' };
    const marker = `probe-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    try {
        await nym._cachePut('meta', { key: '__probe__', marker });
        const all = await nym._cacheGetAll('meta');
        const found = all.find(r => r && r.key === '__probe__');
        if (found && found.marker === marker) return { ok: true };
        return { ok: false, reason: 'write did not persist' };
    } catch (e) {
        return { ok: false, reason: (e && e.message) || 'exception' };
    }
}

// Update the cache size readout in the settings modal
async function refreshAppCacheSize() {
    const el = document.getElementById('appCacheSizeDisplay');
    if (!el) return;
    el.textContent = 'Calculating…';
    let estimateUsage = 0;
    try {
        if (navigator.storage && typeof navigator.storage.estimate === 'function') {
            const est = await navigator.storage.estimate();
            if (Number.isFinite(est.usage) && est.usage > 0) {
                estimateUsage = est.usage;
            }
        }
    } catch (_) { }

    const counts = await countAppCacheItems();
    const totalItems = counts.profiles + counts.channels + counts.pms + counts.reactions;
    const sizeBytes = estimateUsage > 0 ? estimateUsage : counts.totalBytes;

    if (totalItems === 0 && sizeBytes === 0) {
        const probe = await probeAppCacheWritable();
        if (!probe.ok) {
            el.textContent = `IndexedDB unavailable (${probe.reason}) — cache disabled in this app`;
        } else {
            el.textContent = 'No cached data on device yet';
        }
        return;
    }

    const sizeStr = formatCacheBytes(sizeBytes);
    const breakdown =
        `${counts.channels} channel${counts.channels === 1 ? '' : 's'}, ` +
        `${counts.pms} PM/group thread${counts.pms === 1 ? '' : 's'}, ` +
        `${counts.profiles} profile${counts.profiles === 1 ? '' : 's'}, ` +
        `${counts.reactions} reaction record${counts.reactions === 1 ? '' : 's'}`;
    el.textContent = `${sizeStr} cached on device — ${breakdown}`;
}


async function saveSettings() {
    // Get all settings values
    const theme = document.getElementById('themeSelect').value;
    const sound = document.getElementById('soundSelect').value;
    const autoscroll = document.getElementById('autoscrollSelect').value === 'true';
    const showTimestamps = document.getElementById('timestampSelect').value === 'true';
    const timeFormat = document.getElementById('timeFormatSelect').value;
    const dateFormatEl = document.getElementById('dateFormatSelect');
    const dateFormat = dateFormatEl ? dateFormatEl.value : (nym.settings.dateFormat || 'default');
    const sortByProximity = document.getElementById('proximitySelect').value === 'true';
    const blurImagesVal = document.getElementById('blurImagesSelect').value;
    const blurImages = blurImagesVal === 'friends' ? 'friends' : blurImagesVal === 'true';
    const nickStyle = document.getElementById('nickStyleSelect').value;

    // Save color mode
    const colorModeGroup = document.getElementById('colorModeGroup');
    const activeColorBtn = colorModeGroup ? colorModeGroup.querySelector('.color-mode-btn.active') : null;
    const colorMode = activeColorBtn ? activeColorBtn.dataset.mode : 'auto';
    localStorage.setItem('nym_color_mode', colorMode);
    nym.applyColorMode();

    // Save nickname style
    nym.settings.nickStyle = nickStyle;
    localStorage.setItem('nym_nick_style', nickStyle);

    // Apply all settings
    nym.settings.theme = theme;
    nym.settings.sound = sound;
    nym.settings.autoscroll = autoscroll;
    nym.settings.showTimestamps = showTimestamps;
    nym.settings.timeFormat = timeFormat;
    nym.settings.dateFormat = dateFormat;

    // Apply blur settings
    nym.blurOthersImages = blurImages;
    nym.saveImageBlurSettings();

    // Read and save accept PMs setting
    const acceptPMsEl = document.getElementById('acceptPMsSelect');
    if (acceptPMsEl) {
        nym.settings.acceptPMs = acceptPMsEl.value;
        localStorage.setItem('nym_accept_pms', acceptPMsEl.value);
    }

    const acceptCallsEl = document.getElementById('acceptCallsSelect');
    if (acceptCallsEl) {
        nym.settings.acceptCalls = acceptCallsEl.value;
        localStorage.setItem('nym_accept_calls', acceptCallsEl.value);
    }

    // Read disappearing message controls
    const dmEnabled = document.getElementById('dmForwardSecrecySelect').value === 'true';
    const dmTTL = parseInt(document.getElementById('dmTTLSelect').value || '86400', 10);

    // Apply in memory
    nym.settings.dmForwardSecrecyEnabled = dmEnabled;
    nym.settings.dmTTLSeconds = isFinite(dmTTL) && dmTTL > 0 ? dmTTL : 86400;

    // Persist locally
    localStorage.setItem('nym_dm_fwdsec_enabled', String(nym.settings.dmForwardSecrecyEnabled));
    localStorage.setItem('nym_dm_ttl_seconds', String(nym.settings.dmTTLSeconds));

    const SAVE_INDICATOR_SCOPES = ['disabled', 'pms', 'groups', 'pms-groups', 'everywhere'];
    const rrRaw = document.getElementById('readReceiptsSelect').value;
    const readReceiptsScope = SAVE_INDICATOR_SCOPES.includes(rrRaw) ? rrRaw : 'everywhere';
    nym.settings.readReceiptsScope = readReceiptsScope;
    nym.settings.readReceiptsEnabled = readReceiptsScope !== 'disabled';
    localStorage.setItem('nym_read_receipts_scope', readReceiptsScope);
    localStorage.setItem('nym_read_receipts_enabled', String(readReceiptsScope !== 'disabled'));

    // Read and save translation language
    const translateLangEl = document.getElementById('translateLanguageSelect');
    if (translateLangEl) {
        nym.settings.translateLanguage = translateLangEl.value;
        localStorage.setItem('nym_translate_language', translateLangEl.value);
    }

    const VALID_SWIPE_ACTIONS = ['quote', 'translate', 'copy', 'react', 'zap', 'slap', 'hug', 'none'];
    const gesturesEnabledEl = document.getElementById('gesturesEnabledSelect');
    if (gesturesEnabledEl) {
        const on = gesturesEnabledEl.value === 'true';
        nym.settings.gesturesEnabled = on;
        localStorage.setItem('nym_gestures_enabled', String(on));
    }
    const swipeLeftEl = document.getElementById('swipeLeftActionSelect');
    if (swipeLeftEl && VALID_SWIPE_ACTIONS.includes(swipeLeftEl.value)) {
        nym.settings.swipeLeftAction = swipeLeftEl.value;
        localStorage.setItem('nym_swipe_left_action', swipeLeftEl.value);
    }
    const swipeRightEl = document.getElementById('swipeRightActionSelect');
    if (swipeRightEl && VALID_SWIPE_ACTIONS.includes(swipeRightEl.value)) {
        nym.settings.swipeRightAction = swipeRightEl.value;
        localStorage.setItem('nym_swipe_right_action', swipeRightEl.value);
    }
    const swipeThresholdEl = document.getElementById('swipeThresholdSelect');
    if (swipeThresholdEl) {
        const t = parseInt(swipeThresholdEl.value, 10);
        if (Number.isFinite(t) && t >= 30 && t <= 120) {
            nym.settings.swipeThreshold = t;
            localStorage.setItem('nym_swipe_threshold', String(t));
        }
    }
    if (!nym.settings.swipeReactEmoji) {
        nym.settings.swipeReactEmoji = '❤️';
        localStorage.setItem('nym_swipe_react_emoji', '❤️');
    }

    const tiRaw = document.getElementById('typingIndicatorsSelect').value;
    const typingIndicatorsScope = SAVE_INDICATOR_SCOPES.includes(tiRaw) ? tiRaw : 'everywhere';
    nym.settings.typingIndicatorsScope = typingIndicatorsScope;
    nym.settings.typingIndicatorsEnabled = typingIndicatorsScope !== 'disabled';
    localStorage.setItem('nym_typing_indicators_scope', typingIndicatorsScope);
    localStorage.setItem('nym_typing_indicators_enabled', String(typingIndicatorsScope !== 'disabled'));

    // Read and save status indicator visibility setting. When changed,
    // broadcast to other clients so they suppress this user's status dot.
    const showStatusEl = document.getElementById('showStatusSelect');
    if (showStatusEl) {
        const showStatus = showStatusEl.value === 'true';
        const wasShown = nym.settings.showStatus !== false;
        nym.settings.showStatus = showStatus;
        localStorage.setItem('nym_show_status', String(showStatus));
        document.body.classList.toggle('status-hidden', !showStatus);
        if (wasShown !== showStatus && typeof nym.publishStatusVisibility === 'function') {
            nym.publishStatusVisibility(!showStatus);
        }
    }

    // Read and save PM/group cache opt-out. When the user turns it off,
    // wipe the existing cache so we don't leave decrypted content at rest.
    const cachePMsEl = document.getElementById('cachePMsSelect');
    if (cachePMsEl) {
        const wasOn = nym.settings.cachePMs !== false;
        const nowOn = cachePMsEl.value === 'true';
        nym.settings.cachePMs = nowOn;
        localStorage.setItem('nym_cache_pms', String(nowOn));
        if (wasOn && !nowOn && typeof nym.clearPMCache === 'function') {
            nym.clearPMCache().catch(() => { });
        }
    }

    // Handle auto-ephemeral setting (hidden, kept for compatibility)
    const autoEphemeral = document.getElementById('autoEphemeralSelect').value === 'true';
    if (autoEphemeral) {
        localStorage.setItem('nym_auto_ephemeral', 'true');
    } else {
        localStorage.removeItem('nym_auto_ephemeral');
        localStorage.removeItem('nym_auto_ephemeral_nick');
        localStorage.removeItem('nym_auto_ephemeral_channel');
    }

    // Handle random keypair per session setting (skip for logged-in users)
    const randomKeypairEl = document.getElementById('randomKeypairSelect');
    if (randomKeypairEl && !isNostrLoggedIn()) {
        const keypairMode = randomKeypairEl.value; // 'persistent', 'random', or 'hardcore'
        localStorage.setItem('nym_keypair_mode', keypairMode);
        if (keypairMode === 'random' || keypairMode === 'hardcore') {
            localStorage.setItem('nym_random_keypair_per_session', 'true');
            // Clear saved session keypair so next reload generates fresh one
            nymSecretRemove('nym_session_nsec');
        } else {
            localStorage.removeItem('nym_random_keypair_per_session');
            // Save current keypair for reuse if not already saved
            if (nym.privkey && !nymSecretGet('nym_session_nsec')) {
                try {
                    const nsec = window.NostrTools.nip19.nsecEncode(nym.privkey);
                    nymSecretSet('nym_session_nsec', nsec);
                } catch (e) { }
            }
        }
    }

    // Handle hide non-pinned channels setting
    const hideNonPinned = document.getElementById('hideNonPinnedSelect').value === 'true';
    nym.hideNonPinned = hideNonPinned;
    localStorage.setItem('nym_hide_non_pinned', String(hideNonPinned));
    nym.applyHiddenChannels();

    // Save pinned landing channel
    const pinnedValueInput = document.getElementById('pinnedLandingChannelValue');
    if (pinnedValueInput && pinnedValueInput.value) {
        try {
            const pinnedLandingChannel = JSON.parse(pinnedValueInput.value);
            nym.pinnedLandingChannel = pinnedLandingChannel;
            nym.settings.pinnedLandingChannel = pinnedLandingChannel;
            localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(pinnedLandingChannel));
        } catch (e) {
            // Fallback to default
            const defaultChannel = { type: 'geohash', geohash: 'nymchat' };
            nym.pinnedLandingChannel = defaultChannel;
            nym.settings.pinnedLandingChannel = defaultChannel;
            localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(defaultChannel));
        }
    }

    // Handle proximity sorting
    if (sortByProximity) {
        if (!nym.userLocation) {
            // Request location permission
            navigator.geolocation.getCurrentPosition(
                async (position) => {
                    nym.userLocation = {
                        lat: position.coords.latitude,
                        lng: position.coords.longitude
                    };
                    nym.settings.sortByProximity = true;
                    localStorage.setItem('nym_sort_proximity', 'true');

                    // Re-sort immediately after getting location
                    nym.sortChannelsByActivity();

                    nym.displaySystemMessage('Location access granted. Geohash channels sorted by proximity.');
                },
                (error) => {
                    nym.displaySystemMessage('Location access denied. Proximity sorting disabled.');
                    nym.settings.sortByProximity = false;
                    localStorage.setItem('nym_sort_proximity', 'false');
                    document.getElementById('proximitySelect').value = 'false';
                }
            );
        } else {
            // Already have location
            nym.settings.sortByProximity = true;
            localStorage.setItem('nym_sort_proximity', 'true');
            nym.sortChannelsByActivity(); // Re-sort
        }
    } else {
        // Disabling
        nym.settings.sortByProximity = false;
        localStorage.setItem('nym_sort_proximity', 'false');
        nym.userLocation = null;
        nym.sortChannelsByActivity(); // Re-sort to default
    }

    // Save theme and other settings
    nym.applyTheme(theme);
    nym.saveSettings();
    localStorage.setItem('nym_time_format', timeFormat);
    localStorage.setItem('nym_date_format', dateFormat);

    // Refresh messages to apply new time format
    nym.refreshMessageTimestamps();

    // Save text size
    const textSize = parseInt(document.getElementById('textSizeSlider').value || '15', 10);
    nym.settings.textSize = textSize;
    localStorage.setItem('nym_text_size', String(textSize));
    document.documentElement.style.setProperty('--user-text-size', textSize + 'px');

    // Save group chat & PM only mode
    const gcPmOnlySelect = document.getElementById('groupChatPMOnlySelect');
    if (gcPmOnlySelect) {
        const gcPmOnlyMode = gcPmOnlySelect.value === 'true';
        const wasGcPmOnly = nym.settings.groupChatPMOnlyMode;
        nym.settings.groupChatPMOnlyMode = gcPmOnlyMode;
        localStorage.setItem('nym_groupchat_pm_only_mode', String(gcPmOnlyMode));

        if (gcPmOnlyMode !== wasGcPmOnly) {
            nym.applyGroupChatPMOnlyMode(gcPmOnlyMode);
        }
    }

    // Save low data mode
    const lowDataMode = document.getElementById('lowDataModeSelect').value === 'true';
    const wasLowData = nym.settings.lowDataMode;
    nym.settings.lowDataMode = lowDataMode;
    localStorage.setItem('nym_low_data_mode', String(lowDataMode));
    if (lowDataMode !== wasLowData) {
        nym.applyLowDataMode(lowDataMode);
    }

    nym.displaySystemMessage('Settings saved');

    // Sync settings to Nostr relays if logged in
    nostrSettingsSave();

    closeModal('settingsModal');
}

// Clears the on-device app cache only
async function clearLocalStorageCache() {
    if (!(await window.showAppConfirm('Clear cached channel history, PMs, group chats, profiles, and reactions? This will not log you out or change your settings.', { danger: true, okLabel: 'Clear' }))) {
        return;
    }

    // Wipe the IndexedDB-backed app cache
    try {
        if (typeof nym.resetCache === 'function') {
            await nym.resetCache();
        }
    } catch (_) { }

    // Mirror the wipe in-memory so the UI immediately reflects the cleared
    // state instead of showing stale data until the next reload.
    try {
        if (nym.messages && typeof nym.messages.clear === 'function') nym.messages.clear();
        if (nym.pmMessages && typeof nym.pmMessages.clear === 'function') nym.pmMessages.clear();
        if (nym.reactions && typeof nym.reactions.clear === 'function') nym.reactions.clear();
        if (nym.userBios && typeof nym.userBios.clear === 'function') nym.userBios.clear();
        if (nym.channelDOMCache && typeof nym.channelDOMCache.clear === 'function') nym.channelDOMCache.clear();
        if (nym.processedPMEventIds && typeof nym.processedPMEventIds.clear === 'function') nym.processedPMEventIds.clear();
        if (nym.deletedEventIds && typeof nym.deletedEventIds.clear === 'function') nym.deletedEventIds.clear();
    } catch (_) { }

    // Force the currently-rendered conversation to re-render from the now-empty
    // in-memory store so the user sees the cache cleared.
    try {
        const messagesEl = document.getElementById('messages');
        if (messagesEl) messagesEl.innerHTML = '';
    } catch (_) { }

    nym.displaySystemMessage('Local storage cache cleared. Settings, group memberships, and login preserved.');
    closeModal('settingsModal');
}

// Resets user preferences/settings to defaults. Preserves identity (login
// keys, nicknames), group memberships, PM history, ephemeral keys, and the
// app cache. Useful when the user wants to start over visually without
// nuking conversations.
async function resetSettings() {
    if (!(await window.showAppConfirm('Reset all settings and preferences to defaults? This will reset theme, layout, wallpaper, sound, favorited/hidden/blocked channels, blocked users, and blocked keywords. Your login, group memberships, and PMs will be preserved.', { danger: true, okLabel: 'Reset' }))) {
        return;
    }

    // Settings keys that should be wiped on a settings reset. Anything not
    // in this list (identity, login, group metadata, ephemeral keys, PMs,
    // shop purchases, nicknames, profile fields, etc.) is preserved.
    const SETTINGS_KEY_EXACT = new Set([
        'nym_theme', 'nym_color_mode',
        'nym_chat_layout',
        'nym_wallpaper_type', 'nym_wallpaper_custom_url',
        'nym_text_size', 'nym_transparency_enabled', 'nym_nick_style', 'nym_show_status',
        'nym_autoscroll', 'nym_timestamps', 'nym_time_format', 'nym_date_format',
        'nym_sound', 'nym_notifications_enabled', 'nym_notify_friends_only',
        'nym_sort_proximity',
        'nym_dm_fwdsec_enabled', 'nym_dm_ttl_seconds',
        'nym_read_receipts_enabled', 'nym_typing_indicators_enabled',
        'nym_accept_pms', 'nym_cache_pms', 'nym_sync_mls_history',
        'nym_groupchat_pm_only_mode', 'nym_low_data_mode',
        'nym_pow_difficulty',
        'nym_pinned_channels', 'nym_pinned_landing_channel',
        'nym_hidden_channels', 'nym_hide_non_pinned',
        'nym_blocked', 'nym_blocked_channels', 'nym_blocked_keywords',
        'nym_image_blur',
        'nym_group_notify_mentions_only',
        'nym_recent_emojis',
        'nym_user_channels', 'nym_user_joined_channels',
        'nym_relay_url',
        'nym_nav',
        'nym_tutorial_seen', 'nym_botpm_welcomed',
        'nym_notification_history', 'nym_notification_last_read'
    ]);
    const SETTINGS_KEY_PREFIXES = ['nym_image_blur_'];

    const keysToRemove = [];
    for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (!key) continue;
        if (SETTINGS_KEY_EXACT.has(key) || SETTINGS_KEY_PREFIXES.some(p => key.startsWith(p))) {
            keysToRemove.push(key);
        }
    }
    keysToRemove.forEach(key => localStorage.removeItem(key));

    // Reset in-memory settings state to defaults
    nym.pinnedChannels = new Set();
    nym.hiddenChannels = new Set();
    nym.hideNonPinned = false;
    nym.blockedUsers = new Set();
    nym.blockedChannels = new Set();
    nym.blockedKeywords = new Set();
    nym.settings = nym.loadSettings();

    // Re-apply defaults visually
    nym.applyColorMode();
    nym.applyWallpaper('none');
    applyMessageLayout('bubbles');
    nym.updateChannelPins();
    nym.applyHiddenChannels();

    nym.displaySystemMessage('Settings reset to defaults. Cache, group memberships, and login preserved.');
    closeModal('settingsModal');
}

// Message Layout Functions
function selectMessageLayout(layout) {
    document.querySelectorAll('.layout-option').forEach(opt => {
        opt.classList.toggle('selected', opt.dataset.layout === layout);
    });
    nym.settings.chatLayout = layout;
    localStorage.setItem('nym_chat_layout', layout);
    applyMessageLayout(layout);
    nostrSettingsSave();
}

function applyMessageLayout(layout) {
    document.body.classList.toggle('chat-bubbles', layout === 'bubbles');
    if (typeof nym !== 'undefined' && typeof nym._recomputeAllBubbleGrouping === 'function') {
        const container = document.getElementById('messagesContainer');
        if (container) nym._recomputeAllBubbleGrouping(container);
    }
    if (layout === 'bubbles' && typeof nym !== 'undefined') {
        if (typeof nym._refreshBubbleRelativeTimes === 'function') nym._refreshBubbleRelativeTimes();
        if (typeof nym._ensureBubbleRelativeTimer === 'function') nym._ensureBubbleRelativeTimer();
    } else if (layout !== 'bubbles' && typeof nym !== 'undefined') {
        document.querySelectorAll('.bubble-time-inner > .bubble-time-text').forEach(el => {
            const msgEl = el.closest('[data-timestamp]');
            const ts = msgEl ? parseInt(msgEl.dataset.timestamp) : 0;
            if (!ts) return;
            const d = new Date(ts);
            el.textContent = d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: nym.settings.timeFormat === '12hr' });
        });
    }
}

// Wallpaper Functions
function selectWallpaper(type) {
    // Update selection UI
    document.querySelectorAll('.wallpaper-option').forEach(opt => {
        opt.classList.toggle('selected', opt.dataset.wallpaper === type);
    });

    // If it's not custom, apply immediately
    if (type !== 'custom') {
        nym.applyWallpaper(type);
        nym.saveWallpaper(type);
        nostrSettingsSave();
    }
}

function triggerSetupAvatarUpload() {
    document.getElementById('setupAvatarInput').click();
}

function triggerNickEditAvatarUpload() {
    document.getElementById('nickEditAvatarInput').click();
}

function triggerWallpaperUpload() {
    document.getElementById('wallpaperFileInput').click();
}

async function handleWallpaperUpload(event) {
    const file = event.target.files[0];
    if (!file) return;

    // Show uploading state
    const customOption = document.getElementById('customWallpaperOption');
    const customPreview = document.getElementById('customWallpaperPreview');
    const originalContent = customPreview.innerHTML;
    customPreview.innerHTML = '<span class="nm-app-4">Uploading...</span>';

    const url = await nym.uploadWallpaper(file);

    if (url) {
        // Update the custom preview thumbnail
        customPreview.innerHTML = '';
        customPreview.style.backgroundImage = `url('${nym.wallpaperBlobUrl || url}')`;

        // Select custom wallpaper
        document.querySelectorAll('.wallpaper-option').forEach(opt => {
            opt.classList.toggle('selected', opt.dataset.wallpaper === 'custom');
        });

        nym.applyWallpaper('custom', url);
        nym.saveWallpaper('custom', url);
        nostrSettingsSave();
        nym.displaySystemMessage('Wallpaper uploaded and applied.');
    } else {
        customPreview.innerHTML = originalContent;
    }

    // Reset file input
    event.target.value = '';
}

function initWallpaperUI() {
    const { type, customUrl } = nym.loadWallpaper();

    // Highlight saved selection in settings grid
    document.querySelectorAll('.wallpaper-option').forEach(opt => {
        opt.classList.toggle('selected', opt.dataset.wallpaper === type);
    });

    // If custom, update the preview thumbnail
    if (type === 'custom' && customUrl) {
        const customPreview = document.getElementById('customWallpaperPreview');
        if (customPreview) {
            customPreview.innerHTML = '';
            customPreview.style.backgroundImage = `url('${nym.wallpaperBlobUrl || customUrl}')`;
        }
    }
}

const NYMCHAT_VERSION = 'v3.69.459';

function showAbout(prefill) {
    const modal = document.getElementById('aboutModal');
    if (!modal) return;

    const verEl = document.getElementById('aboutVersion');
    if (verEl) verEl.textContent = NYMCHAT_VERSION;

    const relayEl = document.getElementById('aboutRelayCount');
    if (relayEl) relayEl.textContent = String(nym.relayPool.size);

    const nymEl = document.getElementById('aboutNym');
    if (nymEl) nymEl.textContent = nym.nym || 'Not set';

    const status = document.getElementById('aboutContactStatus');
    if (status) {
        status.textContent = '';
        status.style.color = '';
    }

    const typeEl = document.getElementById('aboutContactType');
    const msgEl = document.getElementById('aboutContactMessage');
    if (prefill && typeof prefill === 'object') {
        if (typeEl && prefill.topic) {
            const opt = Array.from(typeEl.options).find(o => o.value === prefill.topic);
            if (opt) typeEl.value = prefill.topic;
        }
        if (msgEl && typeof prefill.message === 'string') {
            msgEl.value = prefill.message;
        }
    }

    modal.classList.add('active');
    if (prefill && msgEl) {
        try { msgEl.focus(); } catch (_) { }
    }
}

function reportSpamFalsePositive(content) {
    const body = content
        ? `The following message was incorrectly flagged by the spam filter:\n\n\`\`\`\n${content}\n\`\`\``
        : 'A message was incorrectly flagged by the spam filter.';
    showAbout({ topic: 'Spam false positive', message: body });
}

async function sendAboutContact() {
    const btn = document.getElementById('aboutContactSendBtn');
    const typeEl = document.getElementById('aboutContactType');
    const msgEl = document.getElementById('aboutContactMessage');
    const status = document.getElementById('aboutContactStatus');

    const setStatus = (text, ok) => {
        if (!status) return;
        status.textContent = text;
        status.style.color = ok ? 'var(--secondary)' : 'var(--danger)';
    };

    const text = (msgEl?.value || '').trim();
    if (!text) {
        setStatus('Please enter a message.', false);
        return;
    }
    if (!nym.connected) {
        setStatus('Not connected to relay. Try again once connected.', false);
        return;
    }

    const topic = typeEl?.value || 'General feedback';
    const body = `[Nymchat contact — ${topic}]\n\n${text}`;

    if (btn) {
        btn.disabled = true;
        btn.textContent = 'Sending...';
    }
    setStatus('', true);

    try {
        const ok = await nym.sendPM(body, nym.verifiedDeveloper.pubkey);
        if (ok) {
            setStatus('Message sent. Thanks for reaching out!', true);
            if (msgEl) msgEl.value = '';
        } else {
            setStatus('Failed to send. Please try again.', false);
        }
    } catch (e) {
        setStatus('Failed to send. Please try again.', false);
    } finally {
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'Send Message';
        }
    }
}

// Function to check for saved connection on page load
async function checkSavedConnection() {
    // Clear any legacy persistent login data
    localStorage.removeItem('nym_connection_mode');
    localStorage.removeItem('nym_nsec');
    localStorage.removeItem('nym_bunker_uri');
    localStorage.removeItem('nym_relay_url');

    // Nostr login takes priority — auto-connect with stored persistent identity
    // so the user doesn't have to go through the setup modal again.
    if (isNostrLoggedIn()) {
        try {
            const method = localStorage.getItem('nym_nostr_login_method');
            const pubkey = localStorage.getItem('nym_nostr_login_pubkey');
            if (!pubkey) throw new Error('No stored pubkey');

            // Set login method early so UI features (e.g. long-press nym send)
            // recognise the user as logged in even if later async steps fail
            nym.nostrLoginMethod = method;

            let secretKey = null;
            if (method === 'nsec') {
                const nsec = nymSecretGet('nym_nostr_login_nsec');
                if (nsec) secretKey = nym.decodeNsec(nsec);
            }

            // For extension login, wait for NIP-07 extension to inject window.nostr
            if (method === 'extension') {
                for (let attempt = 0; attempt < 10; attempt++) {
                    if (window.nostr?.getPublicKey) break;
                    await new Promise(r => setTimeout(r, 300));
                }
            }

            // For NIP-46 remote signer, restore the WebSocket session
            if (method === 'nip46') {
                await _nip46RestoreSession();
            }

            // Hide setup modal
            const setupModal = document.getElementById('setupModal');
            setupModal.classList.remove('active');

            // Generate base ephemeral keypair (needed for internal crypto ops),
            // then immediately override with the nostr identity BEFORE connecting
            await nym.generateKeypair();
            nym.pubkey = pubkey;
            if (secretKey) {
                nym.privkey = secretKey;
            } else {
                // Extension login — clear ephemeral privkey so signEvent() uses the extension
                nym.privkey = null;
            }
            nym.nostrLoginPubkey = pubkey;
            nym.nostrLoginSecretKey = secretKey;
            nym.nostrLoginMethod = method;

            // Apply cached profile immediately for instant UI (name + avatar)
            // before relays connect; fresh data will overwrite later
            nym.nym = 'nym'; // fallback until kind 0 profile is fetched
            try {
                const cached = JSON.parse(localStorage.getItem('nym_nostr_login_profile') || '{}');
                if (cached.name) nym.nym = cached.name;
                if (cached.avatar) {
                    nym.userAvatars.set(pubkey, cached.avatar);
                    nym.cacheAvatarImage(pubkey, cached.avatar);
                }
            } catch (_) { }

            document.getElementById('currentNym').innerHTML = nym.formatNymWithPubkey(nym.nym, nym.pubkey);
            nym.updateSidebarAvatar();

            // Connect to relays using the nostr identity (correct pubkey for DM subs)
            await nym.connectToRelays();

            // Apply cached shop items
            nym.applyCachedShopItemsToNewIdentity();

            // Fetch kind 0 profile and settings now that relays are connected
            applyNostrLogin(pubkey, secretKey, method);

            // Request notification permission
            if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
                Notification.requestPermission();
            }

            // Start tutorial / send the Nymbot welcome once synced settings load,
            // so a returning user logging in elsewhere isn't re-prompted.
            startOnboardingWhenHydrated();

            // Resume to last channel from previous session (skip in PM-only mode)
            if (nym.settings.groupChatPMOnlyMode) {
                // In PM-only mode, navigate to latest PM/group after relays settle
                setTimeout(() => nym.navigateToLatestPMOrGroup(), 500);
            } else {
                const savedChannel = localStorage.getItem('nym_auto_ephemeral_channel');
                if (savedChannel) {
                    try {
                        const { channel, geohash } = JSON.parse(savedChannel);
                        if (channel && channel !== nym.currentChannel) {
                            if (geohash) nym.addChannel(channel, geohash);
                            nym.switchChannel(channel, geohash || '');
                        }
                    } catch (e) { }
                }
            }

            // Route to channel from URL if present (overrides saved channel)
            await routeToUrlChannel();

            return; // Exit early — nostr login handled
        } catch (error) {
            // Nostr login restoration failed, fall through to auto-ephemeral or setup modal
            nym.nostrLoginMethod = null;
        }
    }

    // Auto-ephemeral preference (or saved session keypair)
    const autoEphemeral = localStorage.getItem('nym_auto_ephemeral');
    if (autoEphemeral === 'true') {
        try {
            // Hide setup modal
            const setupModal = document.getElementById('setupModal');
            setupModal.classList.remove('active');

            let isDeveloperLogin = false;
            const randomKeypairPerSession = localStorage.getItem('nym_random_keypair_per_session') === 'true';

            // Use saved custom nickname if available, otherwise random
            const savedNick = localStorage.getItem('nym_auto_ephemeral_nick');
            if (savedNick && nym.isReservedNick(savedNick)) {
                // Reserved nick - check for saved nsec to auto-verify
                const savedNsec = nymSecretGet('nym_dev_nsec');
                if (savedNsec) {
                    const result = nym.verifyDeveloperNsec(savedNsec);
                    if (result.valid) {
                        nym.applyDeveloperIdentity(result.secretKey, result.pubkey);
                        isDeveloperLogin = true;
                        nym.displaySystemMessage('Auto-starting verified session...');
                    } else {
                        // Invalid saved nsec - clear it and use random nym
                        nymSecretRemove('nym_dev_nsec');
                        await nym.generateKeypair();
                        nym.nym = nym.generateRandomNym();
                        nym.connectionMode = 'ephemeral';
                    }
                } else {
                    await nym.generateKeypair();
                    nym.nym = nym.generateRandomNym();
                    nym.connectionMode = 'ephemeral';
                }
            } else if (!randomKeypairPerSession) {
                // Reuse saved keypair if available (persistent session)
                const savedNsec = nymSecretGet('nym_session_nsec');
                if (savedNsec) {
                    try {
                        const secretKey = nym.decodeNsec(savedNsec);
                        const pubkey = window.NostrTools.getPublicKey(secretKey);
                        nym.privkey = secretKey;
                        nym.pubkey = pubkey;
                        nym.nym = savedNick || nym.generateRandomNym();
                        nym.connectionMode = 'ephemeral';
                    } catch (e) {
                        // Saved keypair invalid, generate fresh
                        nymSecretRemove('nym_session_nsec');
                        await nym.generateKeypair();
                        nym.nym = savedNick || nym.generateRandomNym();
                        nym.connectionMode = 'ephemeral';
                    }
                } else {
                    // No saved keypair yet, generate and save
                    await nym.generateKeypair();
                    nym.nym = savedNick || nym.generateRandomNym();
                    nym.connectionMode = 'ephemeral';
                    // Save the generated keypair for reuse
                    try {
                        const nsec = window.NostrTools.nip19.nsecEncode(nym.privkey);
                        nymSecretSet('nym_session_nsec', nsec);
                    } catch (e) { }
                }
                // Persist the auto-generated nick so it survives reload
                if (!savedNick && nym.nym) {
                    try { localStorage.setItem('nym_auto_ephemeral_nick', nym.nym); } catch (e) { }
                }
            } else {
                // Generate fresh ephemeral keypair each session (random/hardcore keypair mode).
                // Rotate the nick too — users opted in to a fresh identity each session.
                await nym.generateKeypair();
                nym.nym = nym.generateRandomNym();
                nym.connectionMode = 'ephemeral';
            }
            document.getElementById('currentNym').innerHTML = nym.formatNymWithPubkey(nym.nym, nym.pubkey);
            nym.updateSidebarAvatar();

            // Connect to relays
            await nym.connectToRelays();

            // Apply cached shop items (styles/flairs) to the new ephemeral identity
            nym.applyCachedShopItemsToNewIdentity();

            // Restore persisted group conversations and ephemeral keys for this keypair
            nym._loadGroupConversations();
            nym._loadEphemeralKeys();
            nym._loadLastPMSyncTime();
            nym._loadLeftGroups();

            // Load synced settings from R2 (encrypted), falling back to relays
            settingsLoad();

            if (isDeveloperLogin) {
                // Developer login - load lightning address from their kind 0 profile
                await nym.loadLightningAddress();
            } else {
                // Restore lightning address from global localStorage to new session
                const globalLnAddress = localStorage.getItem('nym_lightning_address_global');
                if (globalLnAddress) {
                    nym.lightningAddress = globalLnAddress;
                    localStorage.setItem(`nym_lightning_address_${nym.pubkey}`, globalLnAddress);
                    nym.updateLightningAddressDisplay();
                }

                // Restore avatar from localStorage for ephemeral sessions
                const savedAvatarUrl = localStorage.getItem('nym_avatar_url');
                if (savedAvatarUrl) {
                    nym.userAvatars.set(nym.pubkey, savedAvatarUrl);
                    nym.cacheAvatarImage(nym.pubkey, savedAvatarUrl);
                    nym.updateSidebarAvatar();
                }

                // Restore banner from localStorage for ephemeral sessions
                const savedBannerUrl = localStorage.getItem('nym_banner_url');
                if (savedBannerUrl) {
                    nym.userBanners.set(nym.pubkey, savedBannerUrl);
                }

                // Restore bio from localStorage for ephemeral sessions
                const savedBio = localStorage.getItem('nym_bio');
                if (savedBio) {
                    nym.userBios.set(nym.pubkey, savedBio);
                }

                // Publish profile with restored avatar and lightning address
                await nym.saveToNostrProfile();

                // Re-publish profile after more relays connect
                setTimeout(() => { nym.saveToNostrProfile(); }, 5000);
            }

            // Request notification permission
            if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
                Notification.requestPermission();
            }

            // Start tutorial / send the Nymbot welcome once synced settings load,
            // so a returning user logging in elsewhere isn't re-prompted.
            startOnboardingWhenHydrated();

            // Resume to last channel from previous auto-ephemeral session (skip in PM-only mode)
            if (nym.settings.groupChatPMOnlyMode) {
                setTimeout(() => nym.navigateToLatestPMOrGroup(), 500);
            } else {
                const savedChannel = localStorage.getItem('nym_auto_ephemeral_channel');
                if (savedChannel) {
                    try {
                        const { channel, geohash } = JSON.parse(savedChannel);
                        if (channel && channel !== nym.currentChannel) {
                            if (geohash) {
                                nym.addChannel(channel, geohash);
                            }
                            nym.switchChannel(channel, geohash || '');
                        }
                    } catch (e) { }
                }
            }

            // Route to channel from URL if present (overrides saved channel)
            await routeToUrlChannel();

            return; // Exit early
        } catch (error) {
            // Clear the preference and show setup modal
            localStorage.removeItem('nym_auto_ephemeral');
            localStorage.removeItem('nym_auto_ephemeral_nick');
            document.getElementById('setupModal').classList.add('active');
            return;
        }
    }
    // No saved connection (or restoration failed) — show the setup modal.
    document.getElementById('setupModal').classList.add('active');
}

async function initializeNym() {
    if (!window.nym) {
        for (let i = 0; i < 100 && !window.nym; i++) await new Promise(r => setTimeout(r, 30));
        if (!window.nym) return;
    }

    // Show loading state on button
    const enterBtn = document.getElementById('enterNymBtn');
    const originalBtnText = enterBtn.innerHTML;
    enterBtn.disabled = true;
    enterBtn.innerHTML = '<span class="loader"></span> Connecting...';

    try {
        // Get or generate nym first
        const nymInput = document.getElementById('nymInput').value.trim();
        let isDeveloperLogin = false;

        // Check if reserved nickname
        if (nymInput && nym.isReservedNick(nymInput)) {
            const result = await showDevNsecModal('init');
            if (!result) {
                enterBtn.disabled = false;
                enterBtn.innerHTML = originalBtnText;
                return;
            }
            // Verified developer - use their persistent keypair (discard any setup modal keypair)
            setupKeypair = null;
            setupAvatarUrl = null;
            nym.applyDeveloperIdentity(result.secretKey, result.pubkey);
            isDeveloperLogin = true;
            localStorage.removeItem('nym_connection_mode');
        } else {
            // Generate ephemeral keypair (reuse if already created from avatar upload)
            nym.connectionMode = 'ephemeral';
            if (!setupKeypair) {
                await nym.generateKeypair();
            }
            nym.nym = nymInput || nym.generateRandomNym();
            document.getElementById('currentNym').innerHTML = nym.formatNymWithPubkey(nym.nym, nym.pubkey);
            nym.updateSidebarAvatar();
            localStorage.removeItem('nym_connection_mode');
        }

        // Always enable auto-login on next session (replaces old auto-ephemeral checkbox)
        localStorage.setItem('nym_auto_ephemeral', 'true');
        if (nymInput) {
            localStorage.setItem('nym_auto_ephemeral_nick', nymInput);
            // Mark this as a user-chosen nick so it qualifies for R2 mirroring
            try { localStorage.setItem('nym_custom_nick', nym.parseNymFromDisplay(nymInput)); } catch (e) { }
            // If developer verified, also save nsec for auto-login
            if (nym.isReservedNick(nymInput)) {
                const nsecVal = document.getElementById('devNsecInput').value.trim();
                if (nsecVal) {
                    nymSecretSet('nym_dev_nsec', nsecVal);
                }
            }
        }

        // Save the generated keypair for reuse across sessions (unless random keypair mode enabled)
        if (!isDeveloperLogin && nym.privkey) {
            try {
                const nsec = window.NostrTools.nip19.nsecEncode(nym.privkey);
                nymSecretSet('nym_session_nsec', nsec);
            } catch (e) { }
        }

        // Save bio from setup modal
        const setupBioVal = document.getElementById('setupBioInput');
        if (setupBioVal && setupBioVal.value.trim()) {
            localStorage.setItem('nym_bio', setupBioVal.value.trim());
        }

        // If nostr logged in, apply identity keys BEFORE connecting to relays
        // so that relay subscriptions (especially DMs) use the correct pubkey.
        const nostrLoginActive = isNostrLoggedIn();
        let nostrPubkey = null, nostrSecretKey = null, nostrMethod = null;
        if (nostrLoginActive) {
            nostrMethod = localStorage.getItem('nym_nostr_login_method');
            nostrPubkey = localStorage.getItem('nym_nostr_login_pubkey');
            if (nostrMethod === 'nsec') {
                try {
                    const nsec = nymSecretGet('nym_nostr_login_nsec');
                    if (nsec) nostrSecretKey = nym.decodeNsec(nsec);
                } catch (_) { }
            }
            if (nostrPubkey) {
                nym.pubkey = nostrPubkey;
                if (nostrSecretKey) {
                    nym.privkey = nostrSecretKey;
                } else {
                    // Extension login — clear ephemeral privkey so signEvent() uses the extension
                    nym.privkey = null;
                }
                nym.nostrLoginPubkey = nostrPubkey;
                nym.nostrLoginSecretKey = nostrSecretKey;
                nym.nostrLoginMethod = nostrMethod;
            }
        }

        // Connect to relays
        await nym.connectToRelays();

        // Apply cached shop items (styles/flairs) to the new ephemeral identity
        nym.applyCachedShopItemsToNewIdentity();

        // Restore persisted group conversations and ephemeral keys for this keypair
        nym._loadGroupConversations();
        nym._loadEphemeralKeys();
        nym._loadLastPMSyncTime();
        nym._loadLeftGroups();

        // Load synced settings from R2 (encrypted), falling back to relays
        settingsLoad();

        if (isDeveloperLogin) {
            // Developer login - load lightning address from their kind 0 profile
            await nym.loadLightningAddress();
        } else if (!nostrLoginActive) {
            // Restore lightning address from global localStorage to new session
            const globalLnAddress = localStorage.getItem('nym_lightning_address_global');
            if (globalLnAddress) {
                nym.lightningAddress = globalLnAddress;
                localStorage.setItem(`nym_lightning_address_${nym.pubkey}`, globalLnAddress);
                nym.updateLightningAddressDisplay();
            }

            // Apply avatar: either from setup modal upload or from localStorage
            if (setupAvatarUrl) {
                nym.userAvatars.set(nym.pubkey, setupAvatarUrl);
                nym.cacheAvatarImage(nym.pubkey, setupAvatarUrl);
                localStorage.setItem('nym_avatar_url', setupAvatarUrl);
                nym.updateSidebarAvatar();
                setupAvatarUrl = null;
                setupKeypair = null;
            } else {
                const savedAvatarUrl = localStorage.getItem('nym_avatar_url');
                if (savedAvatarUrl) {
                    nym.userAvatars.set(nym.pubkey, savedAvatarUrl);
                    nym.cacheAvatarImage(nym.pubkey, savedAvatarUrl);
                    nym.updateSidebarAvatar();
                }
            }

            // Apply banner: either from setup modal upload or from localStorage
            if (setupBannerUrl) {
                nym.userBanners.set(nym.pubkey, setupBannerUrl);
                localStorage.setItem('nym_banner_url', setupBannerUrl);
                setupBannerUrl = null;
            } else {
                const savedBannerUrl2 = localStorage.getItem('nym_banner_url');
                if (savedBannerUrl2) {
                    nym.userBanners.set(nym.pubkey, savedBannerUrl2);
                }
            }

            // Apply bio: either from setup modal or from localStorage
            const setupBioInput = document.getElementById('setupBioInput');
            if (setupBioInput && setupBioInput.value.trim()) {
                nym.userBios.set(nym.pubkey, setupBioInput.value.trim());
                localStorage.setItem('nym_bio', setupBioInput.value.trim());
            } else {
                const savedBio2 = localStorage.getItem('nym_bio');
                if (savedBio2) {
                    nym.userBios.set(nym.pubkey, savedBio2);
                }
            }

            // Publish profile
            await nym.saveToNostrProfile();

            // Re-publish profile after more relays connect
            setTimeout(() => { nym.saveToNostrProfile(); }, 5000);
        }

        // Request notification permission
        if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
            Notification.requestPermission();
        }

        // Restore button state
        enterBtn.disabled = false;
        enterBtn.innerHTML = originalBtnText;

        // Close setup modal
        closeModal('setupModal');

        // Now that relays are connected, fetch kind 0 profile and load settings
        if (nostrLoginActive && nostrPubkey) {
            applyNostrLogin(nostrPubkey, nostrSecretKey, nostrMethod);
        }

        // Route to channel from URL if present
        await routeToUrlChannel();

        // Start tutorial / send the Nymbot welcome once synced settings load,
        // so a returning user logging in elsewhere isn't re-prompted.
        startOnboardingWhenHydrated();

    } catch (error) {
        // Restore button state on error
        enterBtn.disabled = false;
        enterBtn.innerHTML = originalBtnText;
        window.showAppAlert('Failed to initialize: ' + error.message);
    }
}

// Disconnect/logout function
// Nostr Login
function isNymchatApp() {
    return /NymchatApp\//i.test(navigator.userAgent);
}

function isNostrLoggedIn() {
    return localStorage.getItem('nym_nostr_login_method') !== null;
}

async function openNostrLogin() {
    if (isNostrLoggedIn()) {
        const method = localStorage.getItem('nym_nostr_login_method');
        const npub = localStorage.getItem('nym_nostr_login_npub') || '';
        if (await window.showAppConfirm(`Already logged in via ${method}${npub ? ' (' + npub + ')' : ''}.\n\nWould you like to log out of your Nostr identity?`, { okLabel: 'Log out', danger: true })) {
            nostrLogout();
        }
        return;
    }
    // Hide extension option when inside the NymchatApp webview shell
    const extOption = document.getElementById('nostrLoginExtensionOption');
    const divider = document.getElementById('nostrLoginDivider');
    if (isNymchatApp()) {
        extOption.style.display = 'none';
        divider.style.display = 'none';
    } else {
        extOption.style.display = '';
        divider.style.display = '';
    }
    // Reset state
    document.getElementById('nostrLoginNsecInput').value = '';
    document.getElementById('nostrLoginError').style.display = 'none';
    // Reset remote signer UI
    document.getElementById('nostrLoginRemoteSignerConnect').style.display = 'none';
    document.getElementById('nostrLoginRemoteSignerBtn').style.display = '';
    document.getElementById('nostrLoginRemoteSignerBtn').disabled = false;
    document.getElementById('nostrLoginRemoteSignerBtn').textContent = 'Login with Remote Signer';
    document.getElementById('nostrLoginModal').classList.add('active');
}

async function nostrLoginWithExtension() {
    const errorEl = document.getElementById('nostrLoginError');
    errorEl.style.display = 'none';
    const btn = document.getElementById('nostrLoginExtensionBtn');
    btn.disabled = true;
    btn.textContent = 'Connecting...';
    try {
        if (!window.nostr) {
            throw new Error('No NIP-07 extension detected. Install Alby, nos2x, or another Nostr signer.');
        }
        const pubkey = await window.nostr.getPublicKey();
        if (!pubkey || typeof pubkey !== 'string' || pubkey.length !== 64) {
            throw new Error('Extension returned an invalid public key.');
        }
        // Store login state
        localStorage.setItem('nym_nostr_login_method', 'extension');
        localStorage.setItem('nym_nostr_login_pubkey', pubkey);
        try {
            const npub = window.NostrTools.nip19.npubEncode(pubkey);
            localStorage.setItem('nym_nostr_login_npub', npub);
        } catch (_) { }

        // Apply identity to current session
        applyNostrLogin(pubkey, null, 'extension');

        closeModal('nostrLoginModal');

        // If the setup modal is still showing, bypass it and connect
        if (document.getElementById('setupModal')?.classList.contains('active')) {
            await nostrLoginBypassSetup();
        } else {
            nym.displaySystemMessage('Logged in with Nostr extension.');
        }
    } catch (err) {
        errorEl.textContent = err.message;
        errorEl.style.display = 'block';
    } finally {
        btn.disabled = false;
        btn.textContent = 'Login with Browser Extension';
    }
}

async function nostrLoginWithNsec() {
    const errorEl = document.getElementById('nostrLoginError');
    errorEl.style.display = 'none';
    const nsecInput = document.getElementById('nostrLoginNsecInput').value.trim();
    if (!nsecInput) {
        errorEl.textContent = 'Please enter your nsec.';
        errorEl.style.display = 'block';
        return;
    }
    let secretKey, pubkey;
    try {
        secretKey = nym.decodeNsec(nsecInput);
        pubkey = window.NostrTools.getPublicKey(secretKey);
    } catch (err) {
        errorEl.textContent = 'Invalid nsec key. Please check and try again.';
        errorEl.style.display = 'block';
        return;
    }

    // Store login state (nsec stored so we can sign events and sync settings)
    localStorage.setItem('nym_nostr_login_method', 'nsec');
    localStorage.setItem('nym_nostr_login_pubkey', pubkey);
    nymSecretSet('nym_nostr_login_nsec', nsecInput);
    try {
        const npub = window.NostrTools.nip19.npubEncode(pubkey);
        localStorage.setItem('nym_nostr_login_npub', npub);
    } catch (_) { }

    applyNostrLogin(pubkey, secretKey, 'nsec');

    closeModal('nostrLoginModal');

    // If the setup modal is still showing, bypass it and connect
    if (document.getElementById('setupModal')?.classList.contains('active')) {
        await nostrLoginBypassSetup();
    } else {
        nym.displaySystemMessage('Logged in with Nostr identity.');
    }
}

// NIP-46 Remote Signer (Nostr Connect) Support
let _nip46State = null; // holds active connection state during login flow

function nostrLoginStartRemoteSigner() {
    const errorEl = document.getElementById('nostrLoginError');
    errorEl.style.display = 'none';
    const btn = document.getElementById('nostrLoginRemoteSignerBtn');
    btn.disabled = true;
    btn.textContent = 'Connecting...';

    try {
        // Generate ephemeral keypair for NIP-46 communication
        const clientSecretKey = window.NostrTools.generateSecretKey();
        const clientPubkey = window.NostrTools.getPublicKey(clientSecretKey);

        // Generate a random secret for the connection
        const secretBytes = new Uint8Array(32);
        crypto.getRandomValues(secretBytes);
        const secret = Array.from(secretBytes).map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 16);

        // Use a well-known relay for NIP-46 communication
        const relayUrl = 'wss://relay.primal.net';

        // Build nostrconnect:// URI per NIP-46
        const params = new URLSearchParams();
        params.set('relay', relayUrl);
        params.set('metadata', JSON.stringify({ name: 'Nymchat' }));
        params.set('secret', secret);
        const connectURI = `nostrconnect://${clientPubkey}?${params.toString()}`;

        // Show the connection UI
        btn.style.display = 'none';
        const connectDiv = document.getElementById('nostrLoginRemoteSignerConnect');
        connectDiv.classList.remove('nm-hidden');
        connectDiv.style.display = '';

        // Set connection string
        document.getElementById('nostrLoginBunkerURI').value = connectURI;

        // Generate QR code
        const qrContainer = document.getElementById('nostrLoginRemoteSignerQR');
        qrContainer.innerHTML = '';
        (async () => {
            try {
                if (typeof QRCode === 'undefined') await window.loadScriptOnce(window.NYM_CDN.qrcode);
                new QRCode(qrContainer, {
                    text: connectURI,
                    width: 220,
                    height: 220,
                    colorDark: '#000000',
                    colorLight: '#ffffff',
                    correctLevel: QRCode.CorrectLevel.L
                });
            } catch (qrErr) {
                qrContainer.textContent = 'QR code generation failed';
            }
        })();

        // Store state for the connection flow
        _nip46State = {
            clientSecretKey,
            clientPubkey,
            relayUrl,
            secret,
            ws: null,
            remotePubkey: null,
            subId: 'nip46-auth-' + Date.now(),
            pendingRequests: new Map(),
            connected: false
        };

        // Open WebSocket to relay and listen for the signer's connect response
        _nip46OpenRelay();
    } catch (err) {
        errorEl.textContent = 'Failed to start remote signer connection: ' + err.message;
        errorEl.style.display = 'block';
        btn.disabled = false;
        btn.textContent = 'Login with Remote Signer';
        btn.style.display = '';
    }
}

function _nip46OpenRelay() {
    const state = _nip46State;
    if (!state) return;

    const ws = new WebSocket(state.relayUrl);
    state.ws = ws;

    ws.onopen = () => {
        // Subscribe to kind 24133 events addressed to our client pubkey
        const filter = {
            kinds: [24133],
            '#p': [state.clientPubkey],
            since: Math.floor(Date.now() / 1000) - 10
        };
        ws.send(JSON.stringify(['REQ', state.subId, filter]));
    };

    ws.onmessage = async (evt) => {
        try {
            const msg = JSON.parse(evt.data);
            if (msg[0] === 'EVENT' && msg[1] === state.subId) {
                await _nip46HandleEvent(msg[2]);
            }
        } catch (_) { }
    };

    ws.onerror = () => {
        const statusEl = document.getElementById('nostrLoginRemoteSignerStatus');
        if (statusEl) statusEl.textContent = 'Relay connection error. Try again.';
    };

    ws.onclose = () => {
        // Reconnect if still waiting for signer
        if (_nip46State && !_nip46State.connected) {
            setTimeout(() => {
                if (_nip46State && !_nip46State.connected) {
                    _nip46OpenRelay();
                }
            }, 3000);
        }
    };
}

async function _nip46HandleEvent(event) {
    const state = _nip46State;
    if (!state) return;

    try {
        // Decrypt the NIP-44 encrypted content from the remote signer
        const { nip44 } = window.NostrTools;
        const ck = nip44.getConversationKey(state.clientSecretKey, event.pubkey);
        const decrypted = nip44.decrypt(event.content, ck);
        const response = JSON.parse(decrypted);

        if (response.result === 'auth_url') {
            // Remote signer requires auth — show URL to user
            const statusEl = document.getElementById('nostrLoginRemoteSignerStatus');
            const safeUrl = (response.error && /^https?:\/\//i.test(response.error)) ? response.error.replace(/[&<>"']/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;' })[m]) : '#';
            statusEl.innerHTML = `Signer requires authorization. <a href="${safeUrl}" target="_blank" rel="noopener" class="nm-secondary">Open auth page</a>`;
            return;
        }

        if (response.method === 'connect') {
            // This is the signer's connect acknowledgement
            state.remotePubkey = event.pubkey;
            state.connected = true;
            await _nip46CompleteLogin(event.pubkey);
            return;
        }

        if (response.id && response.result !== undefined) {
            // Handle response to connect or ack
            if (!state.remotePubkey) {
                // First response — this is the connect ack
                state.remotePubkey = event.pubkey;

                // Verify the secret if the signer echoed it back
                if (response.result && response.result !== 'ack' && response.result !== state.secret) {
                    // Secret mismatch; could be a replay
                    const statusEl = document.getElementById('nostrLoginRemoteSignerStatus');
                    statusEl.textContent = 'Connection secret mismatch. Try again.';
                    return;
                }

                state.connected = true;
                await _nip46CompleteLogin(event.pubkey);
                return;
            }

            // Response to a pending request (sign_event, etc.)
            const pending = state.pendingRequests.get(response.id);
            if (pending) {
                state.pendingRequests.delete(response.id);
                if (response.error) {
                    pending.reject(new Error(response.error));
                } else {
                    pending.resolve(response.result);
                }
            }
        }
    } catch (err) {
        console.warn('[NIP-46] Failed to handle event:', err.message);
    }
}

async function _nip46CompleteLogin(remotePubkey) {
    const state = _nip46State;
    if (!state) return;

    const statusEl = document.getElementById('nostrLoginRemoteSignerStatus');
    statusEl.textContent = 'Connected! Fetching public key...';

    try {
        // Request the signer's public key via get_public_key
        const pubkey = await _nip46SendRequest('get_public_key', []);

        if (!pubkey || typeof pubkey !== 'string' || pubkey.length !== 64) {
            throw new Error('Remote signer returned an invalid public key.');
        }

        // Store login state
        localStorage.setItem('nym_nostr_login_method', 'nip46');
        localStorage.setItem('nym_nostr_login_pubkey', pubkey);
        // Store NIP-46 connection details for session restoration
        nymSecretSet('nym_nip46_client_secret', Array.from(state.clientSecretKey).map(b => b.toString(16).padStart(2, '0')).join(''));
        localStorage.setItem('nym_nip46_remote_pubkey', remotePubkey);
        localStorage.setItem('nym_nip46_relay', state.relayUrl);
        try {
            const npub = window.NostrTools.nip19.npubEncode(pubkey);
            localStorage.setItem('nym_nostr_login_npub', npub);
        } catch (_) { }

        // Close the subscription but keep the WebSocket alive for signing
        if (state.ws && state.ws.readyState === WebSocket.OPEN) {
            state.ws.send(JSON.stringify(['CLOSE', state.subId]));
            // Resubscribe with a persistent filter for ongoing NIP-46 communication
            const persistentSubId = 'nip46-session-' + Date.now();
            state.subId = persistentSubId;
            state.ws.send(JSON.stringify(['REQ', persistentSubId, {
                kinds: [24133],
                '#p': [state.clientPubkey],
                since: Math.floor(Date.now() / 1000) - 5
            }]));
        }

        // Apply identity to current session (no local secret key)
        applyNostrLogin(pubkey, null, 'nip46');

        closeModal('nostrLoginModal');

        // If the setup modal is still showing, bypass it and connect
        if (document.getElementById('setupModal')?.classList.contains('active')) {
            await nostrLoginBypassSetup();
        } else {
            nym.displaySystemMessage('Logged in with remote signer (NIP-46).');
        }
    } catch (err) {
        statusEl.textContent = 'Login failed: ' + err.message;
        console.error('[NIP-46] Login failed:', err);
    }
}

function _nip46SendRequest(method, params) {
    const state = _nip46State;
    if (!state || !state.ws || state.ws.readyState !== WebSocket.OPEN || !state.remotePubkey) {
        return Promise.reject(new Error('NIP-46 remote signer not connected'));
    }

    const id = Math.random().toString(36).slice(2) + Date.now().toString(36);
    const request = JSON.stringify({ id, method, params });

    // Encrypt with NIP-44 to the remote signer
    const { nip44 } = window.NostrTools;
    const ck = nip44.getConversationKey(state.clientSecretKey, state.remotePubkey);
    const encrypted = nip44.encrypt(request, ck);

    // Build and sign the event with our ephemeral client key
    const event = {
        kind: 24133,
        created_at: Math.floor(Date.now() / 1000),
        tags: [['p', state.remotePubkey]],
        content: encrypted,
        pubkey: state.clientPubkey
    };

    const signed = window.NostrTools.finalizeEvent(event, state.clientSecretKey);
    state.ws.send(JSON.stringify(['EVENT', signed]));

    return new Promise((resolve, reject) => {
        state.pendingRequests.set(id, { resolve, reject });
        // Timeout after 60 seconds (remote signer may prompt user)
        setTimeout(() => {
            if (state.pendingRequests.has(id)) {
                state.pendingRequests.delete(id);
                reject(new Error('Remote signer request timed out'));
            }
        }, 60000);
    });
}

// Send a sign_event request to the remote signer
async function _nip46SignEvent(event) {
    const unsigned = {
        kind: event.kind,
        created_at: event.created_at,
        tags: event.tags,
        content: event.content,
        pubkey: event.pubkey || localStorage.getItem('nym_nostr_login_pubkey')
    };
    const resultStr = await _nip46SendRequest('sign_event', [JSON.stringify(unsigned)]);
    // The result is the signed event JSON string
    const signed = typeof resultStr === 'string' ? JSON.parse(resultStr) : resultStr;
    return signed;
}

// NIP-44 encrypt via remote signer
async function _nip46Encrypt(thirdPartyPubkey, plaintext) {
    return await _nip46SendRequest('nip44_encrypt', [thirdPartyPubkey, plaintext]);
}

// NIP-44 decrypt via remote signer
async function _nip46Decrypt(thirdPartyPubkey, ciphertext) {
    return await _nip46SendRequest('nip44_decrypt', [thirdPartyPubkey, ciphertext]);
}

function nostrLoginCopyBunkerURI() {
    const input = document.getElementById('nostrLoginBunkerURI');
    if (!input) return;
    navigator.clipboard.writeText(input.value).then(() => {
        const btn = input.nextElementSibling;
        if (btn) {
            btn.textContent = 'Copied!';
            setTimeout(() => { btn.textContent = 'Copy'; }, 2000);
        }
    }).catch(() => {
        // Fallback: select and copy
        input.select();
        document.execCommand('copy');
    });
}

function nostrLoginCancelRemoteSigner() {
    // Clean up WebSocket and state
    if (_nip46State) {
        if (_nip46State.ws) {
            try { _nip46State.ws.close(); } catch (_) { }
        }
        _nip46State = null;
    }
    // Reset UI
    document.getElementById('nostrLoginRemoteSignerConnect').style.display = 'none';
    document.getElementById('nostrLoginRemoteSignerBtn').style.display = '';
    document.getElementById('nostrLoginRemoteSignerBtn').disabled = false;
    document.getElementById('nostrLoginRemoteSignerBtn').textContent = 'Login with Remote Signer';
    document.getElementById('nostrLoginRemoteSignerQR').innerHTML = '';
    document.getElementById('nostrLoginRemoteSignerStatus').textContent = 'Waiting for remote signer...';
}

// Restore NIP-46 session from localStorage on page reload
async function _nip46RestoreSession() {
    const clientSecretHex = nymSecretGet('nym_nip46_client_secret');
    const remotePubkey = localStorage.getItem('nym_nip46_remote_pubkey');
    const relayUrl = localStorage.getItem('nym_nip46_relay');
    if (!clientSecretHex || !remotePubkey || !relayUrl) return false;

    try {
        // Reconstruct the secret key from hex
        const clientSecretKey = new Uint8Array(clientSecretHex.match(/.{1,2}/g).map(b => parseInt(b, 16)));
        const clientPubkey = window.NostrTools.getPublicKey(clientSecretKey);

        _nip46State = {
            clientSecretKey,
            clientPubkey,
            relayUrl,
            secret: null,
            ws: null,
            remotePubkey,
            subId: 'nip46-session-' + Date.now(),
            pendingRequests: new Map(),
            connected: true
        };

        // Open WebSocket for ongoing signing requests
        const ws = new WebSocket(relayUrl);
        _nip46State.ws = ws;

        ws.onopen = () => {
            ws.send(JSON.stringify(['REQ', _nip46State.subId, {
                kinds: [24133],
                '#p': [clientPubkey],
                since: Math.floor(Date.now() / 1000) - 10
            }]));
        };

        ws.onmessage = async (evt) => {
            try {
                const msg = JSON.parse(evt.data);
                if (msg[0] === 'EVENT' && msg[1] === _nip46State.subId) {
                    await _nip46HandleEvent(msg[2]);
                }
            } catch (_) { }
        };

        ws.onclose = () => {
            // Reconnect if session is still active
            if (_nip46State && _nip46State.connected) {
                setTimeout(() => {
                    if (_nip46State && _nip46State.connected) {
                        const newWs = new WebSocket(_nip46State.relayUrl);
                        _nip46State.ws = newWs;
                        newWs.onopen = ws.onopen;
                        newWs.onmessage = ws.onmessage;
                        newWs.onclose = ws.onclose;
                    }
                }, 3000);
            }
        };

        return true;
    } catch (err) {
        console.warn('[NIP-46] Failed to restore session:', err.message);
        return false;
    }
}

async function nostrLoginBypassSetup() {
    await initializeNym();
}

function applyNostrLogin(pubkey, secretKey, method) {
    // Store on the nym instance for settings sync
    nym.nostrLoginPubkey = pubkey;
    nym.nostrLoginSecretKey = secretKey; // null for extension
    nym.nostrLoginMethod = method;

    // Clear ephemeral profile data so it doesn't overwrite the persistent identity
    localStorage.removeItem('nym_avatar_url');
    localStorage.removeItem('nym_banner_url');

    // Switch the active keypair to the persistent identity
    if (secretKey) {
        nym.privkey = secretKey;
    } else {
        // Extension login — clear ephemeral privkey so signEvent() uses the extension
        nym.privkey = null;
    }
    nym.pubkey = pubkey;

    // Helper to update sidebar with profile name/avatar and load lightning address
    function updateSidebarFromProfile() {
        const user = nym.users.get(pubkey);
        if (user && user.nym) {
            nym.nym = user.nym;
        }
        if (nym.nym) {
            document.getElementById('currentNym').innerHTML = nym.formatNymWithPubkey(nym.nym, nym.pubkey);
        }
        nym.updateSidebarAvatar();
        // Pull lightning address from the kind 0 profile into settings
        nym.loadLightningAddress();

        // Cache profile data for instant restore on next refresh
        const avatarUrl = nym.userAvatars.get(pubkey);
        if (nym.nym || avatarUrl) {
            try {
                localStorage.setItem('nym_nostr_login_profile', JSON.stringify({
                    name: nym.nym || null,
                    avatar: avatarUrl || null
                }));
            } catch (_) { }
        }
    }

    nym.fetchProfileDirect(pubkey).then(() => {
        updateSidebarFromProfile();
        // If profile wasn't found on first try, retry after more relays have connected
        if (!nym.users.has(pubkey) || !nym.users.get(pubkey).nym) {
            setTimeout(() => {
                nym.fetchProfileDirect(pubkey).then(() => {
                    updateSidebarFromProfile();
                }).catch(() => {
                    updateSidebarFromProfile();
                });
            }, 3000);
        }
    }).catch(() => {
        updateSidebarFromProfile();
        // Retry after delay on failure
        setTimeout(() => {
            nym.fetchProfileDirect(pubkey).then(() => {
                updateSidebarFromProfile();
            }).catch(() => {
                updateSidebarFromProfile();
            });
        }, 3000);
    });

    // Reload blur setting now that pubkey is known
    nym.blurOthersImages = nym.loadImageBlurSettings();

    // Restore persisted groups and ephemeral keys for this identity before relay history arrives
    nym._loadGroupConversations();
    nym._loadEphemeralKeys();
    nym._loadLastPMSyncTime();
    nym._loadLeftGroups();

    // Update notification badge from persisted history
    nym._updateNotificationBadge();

    // Update isOwn for messages that were loaded before this identity was applied
    nym.messages.forEach(channelMessages => {
        channelMessages.forEach(msg => {
            const shouldBeOwn = msg.pubkey === pubkey;
            if (msg.isOwn !== shouldBeOwn) {
                msg.isOwn = shouldBeOwn;
                const el = document.querySelector(`[data-message-id="${msg.id}"]`);
                if (el) el.classList.toggle('self', shouldBeOwn);
            }
        });
    });
    nym.pmMessages?.forEach(pmMessages => {
        pmMessages.forEach(msg => {
            const shouldBeOwn = msg.pubkey === pubkey;
            if (msg.isOwn !== shouldBeOwn) {
                msg.isOwn = shouldBeOwn;
                const pmDomId = (msg.isPM && msg.nymMessageId) ? msg.nymMessageId : msg.id;
                const el = document.querySelector(`[data-message-id="${pmDomId}"]`);
                if (el) el.classList.toggle('self', shouldBeOwn);
            }
        });
    });

    // Refresh relay subscriptions with the new pubkey so purchase/flair
    // events for this identity flow through the main event handler
    nym.resubscribeAllRelays();

    // Load settings (R2-first, relay fallback) and shop purchases for this identity
    settingsLoad();
    nym.loadShopFromServer();
    // Restore PMs archived in R2 so private messages reappear across devices.
    if (typeof nym.pmRestoreFromR2 === 'function') {
        nym.pmRestoreFromR2().catch(() => { });
    }
}

function nostrLogout() {
    localStorage.removeItem('nym_nostr_login_method');
    localStorage.removeItem('nym_nostr_login_pubkey');
    nymSecretRemove('nym_nostr_login_nsec');
    localStorage.removeItem('nym_nostr_login_npub');
    localStorage.removeItem('nym_nostr_login_profile');
    // Clean up NIP-46 remote signer state
    nymSecretRemove('nym_nip46_client_secret');
    localStorage.removeItem('nym_nip46_remote_pubkey');
    localStorage.removeItem('nym_nip46_relay');
    // Wipe profile fields that aren't pubkey-scoped
    localStorage.removeItem('nym_bio');
    localStorage.removeItem('nym_lightning_address_global');
    localStorage.removeItem('nym_avatar_url');
    localStorage.removeItem('nym_banner_url');
    localStorage.removeItem('nym_auto_ephemeral_nick');
    if (_nip46State) {
        if (_nip46State.ws) {
            try { _nip46State.ws.close(); } catch (_) { }
        }
        _nip46State = null;
    }
    nym.nostrLoginPubkey = null;
    nym.nostrLoginSecretKey = null;
    nym.nostrLoginMethod = null;
    nym.nym = null;
    nym.lightningAddress = null;
    nym.userBios = new Map();
    nym.userBanners = new Map();
    nym.userAvatars = new Map();
    nym._r2ProfileCache = new Map();
    if (typeof nym.resetCache === 'function') {
        nym.resetCache().catch(() => { });
    }
    nym.displaySystemMessage('Nostr identity logged out. Settings will no longer sync.');
}


// Defer the tutorial and the proactive Nymbot welcome PM until synced settings
// have loaded, then let each self-gate on its (now device-spanning) flag.
function startOnboardingWhenHydrated() {
    const run = () => {
        window.maybeStartTutorial(false);
        if (nym && typeof nym._maybeSendBotWelcomePM === 'function') nym._maybeSendBotWelcomePM();
    };
    if (nym && typeof nym._onSettingsHydrated === 'function') nym._onSettingsHydrated(run);
    else run();
}

async function nostrSettingsSave() {
    // For ephemeral users, delegate to the instance method which handles all modes
    if (!isNostrLoggedIn()) {
        if (nym && typeof nym.saveSyncedSettings === 'function') {
            nym.saveSyncedSettings();
        }
        return;
    }
    if (!nym || !nym.pubkey) return;

    try {
        await nym._publishEncryptedSettings(nym._buildSettingsPayload());
    } catch (err) {
        console.warn('[NostrSync] Failed to save settings to relays:', err.message);
    }
}

// Load settings from R2 first, falling back to the Nostr
// gift-wrap load only when R2 can't be read or has no record yet.
async function settingsLoad() {
    let loaded = false;
    if (nym && typeof nym.settingsLoadFromR2 === 'function') {
        try { loaded = await nym.settingsLoadFromR2(); } catch (_) { loaded = false; }
    }
    if (!loaded) nostrSettingsLoad();
    // Safety net: never block saves indefinitely if neither source responds.
    if (nym && typeof nym._markSettingsHydrated === 'function') {
        setTimeout(() => nym._markSettingsHydrated(), 10000);
    }
}

function nostrSettingsLoad() {
    const pubkey = isNostrLoggedIn()
        ? localStorage.getItem('nym_nostr_login_pubkey')
        : (nym && nym.pubkey);
    if (!pubkey) return;

    const subId = Math.random().toString(36).substring(2);
    const filter = {
        kinds: [1059],
        '#p': [pubkey],
        '#d': ['nymchat-settings', 'nymchat-keys', 'nymchat-groups', 'nymchat-history', 'nymchat-notifications'],
        limit: 24
    };

    // Buffer settings events during the initial REQ
    nym._settingsLoadBuffer = nym._settingsLoadBuffer || new Map();
    nym._settingsLoadBuffer.set(subId, { newestSettings: null, newestTs: 0 });

    // Pool mode: send REQ through the multiplexed pool workers
    if (nym.useRelayProxy && nym._isAnyPoolOpen()) {
        const handler = (evt) => {
            try {
                const msg = JSON.parse(evt.data);
                if (msg[0] === 'EVENT' && msg[1] === subId && msg[2]) {
                    nym.handleGiftWrapDM(msg[2], { settingsLoadSubId: subId }).catch(() => { });
                }
                if (msg[0] === 'EOSE' && msg[1] === subId) {
                    nym._poolRemoveMessageListener(handler);
                    try { nym._poolSend(['CLOSE', subId]); } catch (_) { }
                    nym._flushSettingsLoadBuffer(subId);
                }
            } catch (_) { }
        };
        nym._poolAddMessageListener(handler);
        nym._poolSend(['REQ', subId, filter]);

        // Cleanup after 10s
        setTimeout(() => {
            nym._poolRemoveMessageListener(handler);
            try { nym._poolSend(['CLOSE', subId]); } catch (_) { }
            nym._flushSettingsLoadBuffer(subId);
        }, 10000);
        return;
    }

    // Direct relay mode: try to load from any connected relay
    nym.relayPool.forEach((relay, url) => {
        if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;

        const handler = (evt) => {
            try {
                const msg = JSON.parse(evt.data);
                if (msg[0] === 'EVENT' && msg[1] === subId && msg[2]) {
                    nym.handleGiftWrapDM(msg[2], { settingsLoadSubId: subId }).catch(() => { });
                }
                if (msg[0] === 'EOSE' && msg[1] === subId) {
                    relay.ws.removeEventListener('message', handler);
                    try { relay.ws.send(JSON.stringify(['CLOSE', subId])); } catch (_) { }
                    nym._flushSettingsLoadBuffer(subId);
                }
            } catch (_) { }
        };
        relay.ws.addEventListener('message', handler);
        relay.ws.send(JSON.stringify(['REQ', subId, filter]));

        // Cleanup after 10s
        setTimeout(() => {
            relay.ws.removeEventListener('message', handler);
            try { relay.ws.send(JSON.stringify(['CLOSE', subId])); } catch (_) { }
            nym._flushSettingsLoadBuffer(subId);
        }, 10000);
    });
}

async function applyNostrSettingsAdditive(s) {
    if (!s || typeof s !== 'object') return;

    // Notification read-state
    if (typeof s.notificationLastReadTime === 'number'
        && s.notificationLastReadTime > (nym.notificationLastReadTime || 0)) {
        nym.notificationLastReadTime = s.notificationLastReadTime;
        try { localStorage.setItem('nym_notification_last_read', String(s.notificationLastReadTime)); } catch (_) { }
        if (Array.isArray(nym.notificationHistory)) {
            let retroChanged = false;
            for (const n of nym.notificationHistory) {
                if (!n || n.viewed === true) continue;
                const observedAt = n.receivedAt || n.timestamp || 0;
                if (observedAt <= nym.notificationLastReadTime) {
                    n.viewed = true;
                    retroChanged = true;
                }
            }
            if (retroChanged && typeof nym._saveNotificationHistory === 'function') {
                nym._saveNotificationHistory();
            }
        }
        if (typeof nym._updateNotificationBadge === 'function') nym._updateNotificationBadge();
    }

    // Cross-device notification sync. Match on eventId when available,
    // otherwise on (senderPubkey, body, ~minute timestamp) so duplicates
    // across devices and live/replay paths collapse into one entry.
    if (Array.isArray(s.notificationHistory) && s.notificationHistory.length > 0) {
        try {
            const cutoff = Date.now() - 24 * 60 * 60 * 1000;
            const findLocalMatch = (n) => {
                const evId = n.eventId || n.channelInfo?.eventId || '';
                if (evId) {
                    for (const m of nym.notificationHistory) {
                        const mid = m.eventId || m.channelInfo?.eventId || '';
                        if (mid && mid === evId) return m;
                    }
                }
                for (const m of nym.notificationHistory) {
                    if (m.body !== n.body) continue;
                    if ((m.senderPubkey || '') !== (n.senderPubkey || '')) continue;
                    if (Math.abs((m.timestamp || 0) - (n.timestamp || 0)) > 60000) continue;
                    return m;
                }
                return null;
            };
            let changed = false;
            for (const n of s.notificationHistory) {
                if (!n || typeof n.timestamp !== 'number') continue;
                if (n.timestamp <= cutoff) continue;
                const existing = findLocalMatch(n);
                if (existing) {
                    if (n.viewed && !existing.viewed) {
                        existing.viewed = true;
                        changed = true;
                    }
                    if (!existing.eventId && (n.eventId || n.channelInfo?.eventId)) {
                        existing.eventId = n.eventId || n.channelInfo?.eventId;
                        changed = true;
                    }
                    continue;
                }
                const pk = n.senderPubkey || n.channelInfo?.pubkey || '';
                if (pk && nym.blockedUsers && nym.blockedUsers.has(pk)) continue;
                // Don't re-add a missed-call entry for a call that's been
                // answered (here or elsewhere); the answered status is the tombstone.
                const evId = n.eventId || n.channelInfo?.eventId || '';
                if (evId.indexOf('missed-call-') === 0 && typeof nym._callStatus === 'function'
                    && nym._callStatus(evId.slice(12)) === 'answered') continue;
                // Use receivedAt when present (set on the device that observed
                // the notification) so synced notifications keep their original
                // unread status. Fall back to timestamp for legacy entries.
                const observedAt = (typeof n.receivedAt === 'number' && n.receivedAt > 0) ? n.receivedAt : n.timestamp;
                const viewedFromLastRead = observedAt <= (nym.notificationLastReadTime || 0);
                nym.notificationHistory.push({
                    title: n.title || '',
                    body: n.body || '',
                    channelInfo: n.channelInfo || null,
                    timestamp: n.timestamp,
                    receivedAt: observedAt,
                    senderNym: n.senderNym || '',
                    senderPubkey: pk,
                    eventId: n.eventId || n.channelInfo?.eventId || undefined,
                    viewed: !!n.viewed || viewedFromLastRead
                });
                changed = true;
            }
            if (changed) {
                nym.notificationHistory = nym.notificationHistory
                    .filter(n => n && n.timestamp > cutoff)
                    .sort((a, b) => a.timestamp - b.timestamp);
                if (typeof nym._saveNotificationHistory === 'function') nym._saveNotificationHistory();
                if (typeof nym._updateNotificationBadge === 'function') nym._updateNotificationBadge();
            }
        } catch (_) { }
    }

    if (Array.isArray(s.closedPMs)) {
        for (const pk of s.closedPMs) nym.closedPMs.add(pk);
        try { localStorage.setItem('nym_closed_pms', JSON.stringify([...nym.closedPMs])); } catch (_) { }
    }
    if (s.closedPMTimes && typeof s.closedPMTimes === 'object') {
        if (!nym.closedPMTimes) nym.closedPMTimes = new Map();
        for (const [pk, v] of Object.entries(s.closedPMTimes)) {
            if (typeof v !== 'number' || v <= 0) continue;
            const cur = nym.closedPMTimes.get(pk) || 0;
            if (v > cur) nym.closedPMTimes.set(pk, v);
        }
        try { localStorage.setItem('nym_closed_pm_times', JSON.stringify(Object.fromEntries(nym.closedPMTimes))); } catch (_) { }
    }

    if (Array.isArray(s.leftGroups)) {
        for (const gid of s.leftGroups) nym.leftGroups.add(gid);
        if (typeof nym._saveLeftGroups === 'function') nym._saveLeftGroups();
    }
    if (s.leftGroupTimes && typeof s.leftGroupTimes === 'object') {
        if (!nym.leftGroupTimes) nym.leftGroupTimes = new Map();
        for (const [gid, v] of Object.entries(s.leftGroupTimes)) {
            if (typeof v !== 'number' || v <= 0) continue;
            const cur = nym.leftGroupTimes.get(gid) || 0;
            if (v > cur) nym.leftGroupTimes.set(gid, v);
        }
        try { localStorage.setItem('nym_left_group_times', JSON.stringify(Object.fromEntries(nym.leftGroupTimes))); } catch (_) { }
    }

    if (s.channelLastRead && typeof s.channelLastRead === 'object') {
        if (!nym.channelLastRead) nym.channelLastRead = new Map();
        let lrChanged = false;
        for (const [ch, v] of Object.entries(s.channelLastRead)) {
            if (typeof v !== 'number' || v <= 0) continue;
            const cur = nym.channelLastRead.get(ch) || 0;
            if (v > cur) { nym.channelLastRead.set(ch, v); lrChanged = true; }
        }
        if (lrChanged && typeof nym._persistUnreadCounts === 'function') {
            nym._persistUnreadCounts(true);
            if (typeof nym.recomputeAllUnreadCounts === 'function') nym.recomputeAllUnreadCounts();
        }
    }

    // Group conversations
    const applyGroupData = (groupData) => {
        for (const [groupId, group] of Object.entries(groupData)) {
            if (!nym.groupConversations.has(groupId)) {
                nym.addGroupConversation(groupId, group.name, group.members || [], group.lastMessageTime || Date.now(), { createdBy: group.createdBy });
                const g = nym.groupConversations.get(groupId);
                if (g) {
                    if (group.createdBy) g.createdBy = group.createdBy;
                    g.mods = Array.isArray(group.mods) ? [...group.mods] : [];
                    g.banned = Array.isArray(group.banned) ? [...group.banned] : [];
                    g.modLog = Array.isArray(group.modLog) ? [...group.modLog] : [];
                }
            } else {
                // Merge role data so a moderator change made on another device
                // becomes visible without a full reload.
                const g = nym.groupConversations.get(groupId);
                if (g) {
                    if (!g.createdBy && group.createdBy) g.createdBy = group.createdBy;
                    if (Array.isArray(group.mods)) {
                        const cur = new Set(Array.isArray(g.mods) ? g.mods : []);
                        for (const pk of group.mods) cur.add(pk);
                        g.mods = [...cur];
                    }
                    if (Array.isArray(group.banned)) {
                        const cur = new Set(Array.isArray(g.banned) ? g.banned : []);
                        for (const pk of group.banned) cur.add(pk);
                        g.banned = [...cur];
                    }
                    if (Array.isArray(group.modLog) && group.modLog.length > 0) {
                        const seen = new Set((g.modLog || []).map(e => `${e.type}:${e.actor}:${e.target}:${e.ts}`));
                        const merged = [...(g.modLog || [])];
                        for (const e of group.modLog) {
                            const k = `${e.type}:${e.actor}:${e.target}:${e.ts}`;
                            if (!seen.has(k)) { merged.push(e); seen.add(k); }
                        }
                        merged.sort((a, b) => (a.ts || 0) - (b.ts || 0));
                        g.modLog = merged.slice(-50);
                    }
                }
            }
        }
        nym._saveGroupConversations();
        nym.updateViewMoreButton('pmList');
    };

    if (s.groupConversations && typeof s.groupConversations === 'object') {
        try { applyGroupData(s.groupConversations); } catch (_) { }
    }

    // Ephemeral keys — always merge from every settings event so no device's
    // keys are silently dropped when events arrive out of timestamp order
    if (s.groupEphemeralKeys && typeof s.groupEphemeralKeys === 'object') {
        try {
            const beforePks = new Set(nym._getAllKnownEphemeralPubkeys());
            for (const [groupId, entry] of Object.entries(s.groupEphemeralKeys)) {
                nym._mergeEphemeralKeys(groupId, entry);
            }
            nym._saveEphemeralKeys();
            const afterPks = nym._getAllKnownEphemeralPubkeys();
            const newPks = afterPks.filter(pk => !beforePks.has(pk));
            if (newPks.length > 0 && nym.connected) {
                nym._refreshEphemeralSubscriptions();
                nym._recoverEphemeralHistory(newPks);
            }
        } catch (_) { }
    }

    // Group message history — always merge from every settings event so older
    // device saves that contain unique messages are never discarded
    if (s.groupMessageHistory && typeof s.groupMessageHistory === 'object') {
        try {
            const refreshedConvKeys = new Set();
            for (const [groupConvKey, backupMessages] of Object.entries(s.groupMessageHistory)) {
                if (!Array.isArray(backupMessages) || backupMessages.length === 0) continue;

                const inflated = backupMessages.map(m => {
                    if (m.conversationKey && m.isPM) return m;
                    return Object.assign({
                        author: nym.getNymFromPubkey(m.pubkey) || 'nym',
                        timestamp: new Date((m.created_at || 0) * 1000),
                        isPM: true,
                        isGroup: true,
                        conversationKey: groupConvKey,
                        isHistorical: true,
                        _seq: ++nym._msgSeq
                    }, m);
                });

                const existing = nym.pmMessages.get(groupConvKey) || [];
                const existingIds = new Set(existing.map(m => m.id));
                const newMsgs = inflated.filter(m => m.id && !existingIds.has(m.id));

                if (newMsgs.length === 0) continue;

                const merged = [...existing, ...newMsgs];
                merged.sort((a, b) => nym._compareMessages(a, b));
                const capped = merged.length > nym.pmStorageLimit
                    ? merged.slice(-nym.pmStorageLimit)
                    : merged;

                nym.pmMessages.set(groupConvKey, capped);
                nym.channelDOMCache.delete(groupConvKey);
                refreshedConvKeys.add(groupConvKey);
            }

            if (refreshedConvKeys.size > 0 && nym.inPMMode && nym.currentGroup) {
                const activeKey = nym.getGroupConversationKey(nym.currentGroup);
                if (refreshedConvKeys.has(activeKey)) {
                    nym.loadPMMessages(activeKey);
                }
            }
        } catch (_) { }
    }
}

async function applyNostrSettings(s) {
    if (!s || typeof s !== 'object') return;

    // Tutorial / bot-welcome state — only ever flip on, so once a user has
    // seen them on any device they stay suppressed everywhere.
    if (s.tutorialSeen === true) {
        try { localStorage.setItem('nym_tutorial_seen', 'true'); } catch (_) { }
    }
    if (s.botPmWelcomed === true) {
        try { localStorage.setItem('nym_botpm_welcomed', 'true'); } catch (_) { }
    }

    // Cross-device preference for identity-encryption-at-rest
    if (s.encryptAtRestPreferred === true) {
        try { localStorage.setItem('nym_encrypt_at_rest_pref', '1'); } catch (_) { }
    }

    // Theme
    if (s.theme && typeof s.theme === 'string') {
        nym.settings.theme = s.theme;
        nym.applyTheme(s.theme);
        localStorage.setItem('nym_theme', s.theme);
    }

    // Color mode
    if (s.colorMode) {
        localStorage.setItem('nym_color_mode', s.colorMode);
        nym.applyColorMode();
    }

    // Sound
    if (s.sound) {
        nym.settings.sound = s.sound;
        localStorage.setItem('nym_sound', s.sound);
    }

    // Autoscroll
    if (typeof s.autoscroll === 'boolean') {
        nym.settings.autoscroll = s.autoscroll;
        localStorage.setItem('nym_autoscroll', String(s.autoscroll));
    }

    // Timestamps
    if (typeof s.showTimestamps === 'boolean') {
        nym.settings.showTimestamps = s.showTimestamps;
        localStorage.setItem('nym_timestamps', String(s.showTimestamps));
    }

    // Time format
    if (s.timeFormat) {
        nym.settings.timeFormat = s.timeFormat;
        localStorage.setItem('nym_time_format', s.timeFormat);
    }

    // Date format
    if (s.dateFormat) {
        nym.settings.dateFormat = s.dateFormat;
        localStorage.setItem('nym_date_format', s.dateFormat);
    }

    // Sort by proximity
    if (typeof s.sortByProximity === 'boolean') {
        nym.settings.sortByProximity = s.sortByProximity;
        localStorage.setItem('nym_sort_proximity', String(s.sortByProximity));
    }

    // DM forward secrecy
    if (typeof s.dmForwardSecrecyEnabled === 'boolean') {
        nym.settings.dmForwardSecrecyEnabled = s.dmForwardSecrecyEnabled;
        localStorage.setItem('nym_dm_fwdsec_enabled', String(s.dmForwardSecrecyEnabled));
    }
    if (s.dmTTLSeconds) {
        nym.settings.dmTTLSeconds = s.dmTTLSeconds;
        localStorage.setItem('nym_dm_ttl_seconds', String(s.dmTTLSeconds));
    }

    const VALID_SCOPES = ['disabled', 'pms', 'groups', 'pms-groups', 'everywhere'];
    if (typeof s.readReceiptsScope === 'string' && VALID_SCOPES.includes(s.readReceiptsScope)) {
        nym.settings.readReceiptsScope = s.readReceiptsScope;
        nym.settings.readReceiptsEnabled = s.readReceiptsScope !== 'disabled';
        localStorage.setItem('nym_read_receipts_scope', s.readReceiptsScope);
        localStorage.setItem('nym_read_receipts_enabled', String(s.readReceiptsScope !== 'disabled'));
    } else if (typeof s.readReceiptsEnabled === 'boolean') {
        const scope = s.readReceiptsEnabled ? 'everywhere' : 'disabled';
        nym.settings.readReceiptsScope = scope;
        nym.settings.readReceiptsEnabled = s.readReceiptsEnabled;
        localStorage.setItem('nym_read_receipts_scope', scope);
        localStorage.setItem('nym_read_receipts_enabled', String(s.readReceiptsEnabled));
    }

    if (typeof s.typingIndicatorsScope === 'string' && VALID_SCOPES.includes(s.typingIndicatorsScope)) {
        nym.settings.typingIndicatorsScope = s.typingIndicatorsScope;
        nym.settings.typingIndicatorsEnabled = s.typingIndicatorsScope !== 'disabled';
        localStorage.setItem('nym_typing_indicators_scope', s.typingIndicatorsScope);
        localStorage.setItem('nym_typing_indicators_enabled', String(s.typingIndicatorsScope !== 'disabled'));
    } else if (typeof s.typingIndicatorsEnabled === 'boolean') {
        const scope = s.typingIndicatorsEnabled ? 'everywhere' : 'disabled';
        nym.settings.typingIndicatorsScope = scope;
        nym.settings.typingIndicatorsEnabled = s.typingIndicatorsEnabled;
        localStorage.setItem('nym_typing_indicators_scope', scope);
        localStorage.setItem('nym_typing_indicators_enabled', String(s.typingIndicatorsEnabled));
    }

    // Show status indicators
    if (typeof s.showStatus === 'boolean') {
        nym.settings.showStatus = s.showStatus;
        localStorage.setItem('nym_show_status', String(s.showStatus));
        document.body.classList.toggle('status-hidden', !s.showStatus);
    }

    // Nick style
    if (s.nickStyle) {
        nym.settings.nickStyle = s.nickStyle;
        localStorage.setItem('nym_nick_style', s.nickStyle);
    }

    const VALID_SWIPE_ACTIONS = ['quote', 'translate', 'copy', 'react', 'zap', 'slap', 'hug', 'none'];
    if (typeof s.gesturesEnabled === 'boolean') {
        nym.settings.gesturesEnabled = s.gesturesEnabled;
        localStorage.setItem('nym_gestures_enabled', String(s.gesturesEnabled));
    }
    if (typeof s.swipeLeftAction === 'string' && VALID_SWIPE_ACTIONS.includes(s.swipeLeftAction)) {
        nym.settings.swipeLeftAction = s.swipeLeftAction;
        localStorage.setItem('nym_swipe_left_action', s.swipeLeftAction);
    }
    if (typeof s.swipeRightAction === 'string' && VALID_SWIPE_ACTIONS.includes(s.swipeRightAction)) {
        nym.settings.swipeRightAction = s.swipeRightAction;
        localStorage.setItem('nym_swipe_right_action', s.swipeRightAction);
    }
    if (typeof s.swipeThreshold === 'number' && s.swipeThreshold >= 30 && s.swipeThreshold <= 120) {
        nym.settings.swipeThreshold = s.swipeThreshold;
        localStorage.setItem('nym_swipe_threshold', String(s.swipeThreshold));
    }
    if (typeof s.swipeReactEmoji === 'string' && s.swipeReactEmoji.length > 0 && s.swipeReactEmoji.length <= 8) {
        nym.settings.swipeReactEmoji = s.swipeReactEmoji;
        localStorage.setItem('nym_swipe_react_emoji', s.swipeReactEmoji);
    }

    // Wallpaper
    if (s.wallpaperCustomUrl) {
        localStorage.setItem('nym_wallpaper_custom_url', s.wallpaperCustomUrl);
    }
    if (s.wallpaperType) {
        const prevType = localStorage.getItem('nym_wallpaper_type') || '';
        const prevUrl = localStorage.getItem('nym_wallpaper_custom_url') || '';
        const sameAsCurrent = prevType === s.wallpaperType
            && (s.wallpaperType !== 'custom' || prevUrl === (s.wallpaperCustomUrl || ''));
        localStorage.setItem('nym_wallpaper_type', s.wallpaperType);
        if (s.wallpaperType === 'custom' && s.wallpaperCustomUrl) {
            if (!sameAsCurrent || !nym.wallpaperBlobUrl) {
                nym.applyWallpaper('custom', s.wallpaperCustomUrl);
                nym.saveWallpaper('custom', s.wallpaperCustomUrl);
                nym._ensureWallpaperCached(s.wallpaperCustomUrl);
            }
        } else if (!sameAsCurrent && typeof selectWallpaper === 'function') {
            selectWallpaper(s.wallpaperType);
        }
    }

    // Chat layout
    if (s.chatLayout) {
        nym.settings.chatLayout = s.chatLayout;
        localStorage.setItem('nym_chat_layout', s.chatLayout);
        if (typeof applyMessageLayout === 'function') {
            applyMessageLayout(s.chatLayout);
        }
    }

    // Lightning address
    if (s.lightningAddress) {
        localStorage.setItem('nym_lightning_address_global', s.lightningAddress);
        nym.lightningAddress = s.lightningAddress;
    }

    // PoW difficulty
    if (typeof s.powDifficulty === 'number') {
        nym.powDifficulty = s.powDifficulty;
        nym.enablePow = s.powDifficulty > 0;
        localStorage.setItem('nym_pow_difficulty', String(s.powDifficulty));
    }

    // Hide non-pinned
    if (typeof s.hideNonPinned === 'boolean') {
        nym.hideNonPinned = s.hideNonPinned;
        localStorage.setItem('nym_hide_non_pinned', String(s.hideNonPinned));
    }

    // Blur images (supports boolean or 'friends')
    if (typeof s.blurOthersImages === 'boolean' || s.blurOthersImages === 'friends') {
        nym.blurOthersImages = s.blurOthersImages;
        localStorage.setItem('nym_image_blur', String(s.blurOthersImages));
        if (nym.pubkey) {
            localStorage.setItem(`nym_image_blur_${nym.pubkey}`, String(s.blurOthersImages));
        }
    }

    // Pinned landing channel
    if (s.pinnedLandingChannel && typeof s.pinnedLandingChannel === 'object') {
        const landing = s.pinnedLandingChannel.geohash === 'nym'
            ? { type: 'geohash', geohash: 'nymchat' }
            : s.pinnedLandingChannel;
        nym.pinnedLandingChannel = landing;
        nym.settings.pinnedLandingChannel = landing;
        localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(landing));
    }

    // Text size
    if (typeof s.textSize === 'number' && s.textSize >= 12 && s.textSize <= 28) {
        nym.settings.textSize = s.textSize;
        localStorage.setItem('nym_text_size', String(s.textSize));
        document.documentElement.style.setProperty('--user-text-size', s.textSize + 'px');
    }

    // Visual transparency
    if (typeof s.transparencyEnabled === 'boolean') {
        nym.settings.transparencyEnabled = s.transparencyEnabled;
        localStorage.setItem('nym_transparency_enabled', String(s.transparencyEnabled));
        applyTransparency(s.transparencyEnabled);
    }

    // Low data mode
    if (typeof s.lowDataMode === 'boolean') {
        nym.settings.lowDataMode = s.lowDataMode;
        localStorage.setItem('nym_low_data_mode', String(s.lowDataMode));
    }

    // Group chat & PM only mode — only apply navigation side-effects when
    // the mode actually changes, to avoid kicking the user out of the
    // channel they just navigated to (settings sync is async).
    if (typeof s.groupChatPMOnlyMode === 'boolean') {
        const changed = nym.settings.groupChatPMOnlyMode !== s.groupChatPMOnlyMode;
        nym.settings.groupChatPMOnlyMode = s.groupChatPMOnlyMode;
        localStorage.setItem('nym_groupchat_pm_only_mode', String(s.groupChatPMOnlyMode));
        if (changed) {
            nym.applyGroupChatPMOnlyMode(s.groupChatPMOnlyMode);
        }
    }

    // Pinned channels
    if (Array.isArray(s.pinnedChannels)) {
        nym.pinnedChannels = new Set(s.pinnedChannels);
        localStorage.setItem('nym_pinned_channels', JSON.stringify(s.pinnedChannels));
    }

    // Blocked channels
    if (Array.isArray(s.blockedChannels)) {
        nym.blockedChannels = new Set(s.blockedChannels);
        localStorage.setItem('nym_blocked_channels', JSON.stringify(s.blockedChannels));
    }

    // User joined channels
    if (Array.isArray(s.userJoinedChannels)) {
        // Migrate the legacy default channel key to the renamed default.
        const joined = [...new Set(s.userJoinedChannels.map(key => key === 'nym' ? 'nymchat' : key))];
        joined.forEach(key => {
            nym.userJoinedChannels.add(key);
            if (!nym.channels.has(key)) {
                nym.addChannel(key, key);
            }
        });

        localStorage.setItem('nym_user_joined_channels', JSON.stringify(joined));
        localStorage.setItem('nym_user_channels', JSON.stringify(
            joined.map(key => ({
                key: key,
                channel: key,
                geohash: key
            }))
        ));
    }

    // Hidden channels
    if (Array.isArray(s.hiddenChannels)) {
        nym.hiddenChannels = new Set(s.hiddenChannels);
        localStorage.setItem('nym_hidden_channels', JSON.stringify(s.hiddenChannels));
        if (typeof nym.applyHiddenChannels === 'function') {
            nym.applyHiddenChannels();
        }
    }

    // Blocked users
    if (Array.isArray(s.blockedUsers)) {
        nym.blockedUsers = new Set(s.blockedUsers);
        localStorage.setItem('nym_blocked', JSON.stringify(s.blockedUsers));
    }

    // Friends
    if (Array.isArray(s.friends)) {
        nym.friends = new Set(s.friends);
        localStorage.setItem('nym_friends', JSON.stringify(s.friends));
        if (typeof nym.reapplyImageBlur === 'function') nym.reapplyImageBlur();
        if (typeof nym.updateFriendsList === 'function') nym.updateFriendsList();
        nym._userListSig = '';
        if (typeof nym.updateUserList === 'function') nym.updateUserList();
    }

    // Accept PMs setting
    if (s.acceptPMs) {
        nym.settings.acceptPMs = s.acceptPMs;
        localStorage.setItem('nym_accept_pms', s.acceptPMs);
    }

    // Accept calls setting
    if (s.acceptCalls) {
        nym.settings.acceptCalls = s.acceptCalls;
        localStorage.setItem('nym_accept_calls', s.acceptCalls);
        const acceptCallsSel = document.getElementById('acceptCallsSelect');
        if (acceptCallsSel) acceptCallsSel.value = s.acceptCalls;
    }

    // Seen calls (cross-device call dedup)
    if (s.seenCalls && typeof nym._mergeSeenCalls === 'function') {
        nym._mergeSeenCalls(s.seenCalls);
    }

    // Blocked keywords
    if (Array.isArray(s.blockedKeywords)) {
        nym.blockedKeywords = new Set(s.blockedKeywords);
        localStorage.setItem('nym_blocked_keywords', JSON.stringify(s.blockedKeywords));
    }

    // Translation language
    if (typeof s.translateLanguage === 'string') {
        nym.settings.translateLanguage = s.translateLanguage;
        localStorage.setItem('nym_translate_language', s.translateLanguage);
        if (typeof nym.populateTranslateLanguageSelect === 'function') nym.populateTranslateLanguageSelect();
    }

    // Favorite translation languages
    if (Array.isArray(s.translateFavoriteLanguages)) {
        nym._translateFavorites = s.translateFavoriteLanguages.slice();
        localStorage.setItem('nym_translate_favorites', JSON.stringify(nym._translateFavorites));
        if (typeof nym._renderTranslateDropdownList === 'function') nym._renderTranslateDropdownList();
    }

    // Favorite custom emoji packs
    if (Array.isArray(s.emojiPackFavorites)) {
        nym._emojiPackFavorites = s.emojiPackFavorites.filter(k => typeof k === 'string');
        localStorage.setItem('nym_emoji_pack_favorites', JSON.stringify(nym._emojiPackFavorites));
    }

    // Favorite GIFs — merge the remote set into the local one so favorites sync
    // across devices without an empty or stale remote list wiping local picks.
    if (Array.isArray(s.favoriteGifs) && s.favoriteGifs.length) {
        const remote = s.favoriteGifs
            .filter(g => g && typeof g.url === 'string')
            .map(g => ({ url: g.url, title: typeof g.title === 'string' ? g.title : '' }));
        const local = typeof nym._getFavoriteGifs === 'function' ? nym._getFavoriteGifs() : (nym._favoriteGifs || []);
        const merged = [];
        const seen = new Set();
        for (const g of [...local, ...remote]) {
            if (seen.has(g.url)) continue;
            seen.add(g.url);
            merged.push(g);
        }
        nym._favoriteGifs = merged.slice(0, 100);
        localStorage.setItem('nym_favorite_gifs', JSON.stringify(nym._favoriteGifs));
    }

    // Favorited default emoji categories — replace with remote set so an
    // unfavorite on one device propagates to others.
    if (Array.isArray(s.emojiCategoryFavorites)) {
        const allCats = nym.allEmojis ? new Set(Object.keys(nym.allEmojis)) : null;
        nym._defaultCategoryFavorites = s.emojiCategoryFavorites
            .filter(c => typeof c === 'string' && (!allCats || allCats.has(c)));
        localStorage.setItem('nym_emoji_category_favorites', JSON.stringify(nym._defaultCategoryFavorites));
    }

    // Recently used emoji — merge most-recent-first, dedupe by emoji
    if (Array.isArray(s.recentEmojis) && s.recentEmojis.length > 0) {
        const seen = new Set();
        const merged = [];
        for (const e of s.recentEmojis) {
            if (typeof e === 'string' && !seen.has(e)) { seen.add(e); merged.push(e); }
        }
        for (const e of (nym.recentEmojis || [])) {
            if (typeof e === 'string' && !seen.has(e)) { seen.add(e); merged.push(e); }
        }
        nym.recentEmojis = merged.slice(0, 24);
        nym.saveRecentEmojis();
    }

    // Sidebar section order
    if (Array.isArray(s.sidebarSectionOrder) && typeof nym._applySidebarSectionOrder === 'function') {
        nym._applySidebarSectionOrder(s.sidebarSectionOrder);
    }

    // Cache PMs & group chats on device
    if (typeof s.cachePMs === 'boolean') {
        const wasOn = nym.settings.cachePMs !== false;
        nym.settings.cachePMs = s.cachePMs;
        localStorage.setItem('nym_cache_pms', String(s.cachePMs));
        if (wasOn && !s.cachePMs && typeof nym.clearPMCache === 'function') {
            nym.clearPMCache().catch(() => { });
        }
    }

    // MLS history sync preference
    if (typeof s.syncMLSHistory === 'boolean') {
        nym.settings.syncMLSHistory = s.syncMLSHistory;
        localStorage.setItem('nym_sync_mls_history', String(s.syncMLSHistory));
    }

    // Notifications enabled
    if (typeof s.notificationsEnabled === 'boolean') {
        nym.notificationsEnabled = s.notificationsEnabled;
        localStorage.setItem('nym_notifications_enabled', String(s.notificationsEnabled));
    }
    if (typeof s.groupNotifyMentionsOnly === 'boolean') {
        nym.groupNotifyMentionsOnly = s.groupNotifyMentionsOnly;
        localStorage.setItem('nym_group_notify_mentions_only', String(s.groupNotifyMentionsOnly));
    }
    if (typeof s.notifyFriendsOnly === 'boolean') {
        nym.notifyFriendsOnly = s.notifyFriendsOnly;
        localStorage.setItem('nym_notify_friends_only', String(s.notifyFriendsOnly));
    }

    // Notification last read time (take the later of local vs relay)
    if (typeof s.notificationLastReadTime === 'number' && s.notificationLastReadTime > nym.notificationLastReadTime) {
        nym.notificationLastReadTime = s.notificationLastReadTime;
        localStorage.setItem('nym_notification_last_read', String(s.notificationLastReadTime));
        nym._updateNotificationBadge();
    }

    if (Array.isArray(s.closedPMs)) {
        for (const pk of s.closedPMs) nym.closedPMs.add(pk);
        localStorage.setItem('nym_closed_pms', JSON.stringify([...nym.closedPMs]));
    }
    if (s.closedPMTimes && typeof s.closedPMTimes === 'object') {
        if (!nym.closedPMTimes) nym.closedPMTimes = new Map();
        for (const [pk, v] of Object.entries(s.closedPMTimes)) {
            if (typeof v !== 'number' || v <= 0) continue;
            const cur = nym.closedPMTimes.get(pk) || 0;
            if (v > cur) nym.closedPMTimes.set(pk, v);
        }
        try { localStorage.setItem('nym_closed_pm_times', JSON.stringify(Object.fromEntries(nym.closedPMTimes))); } catch { }
    }

    if (Array.isArray(s.leftGroups)) {
        for (const gid of s.leftGroups) nym.leftGroups.add(gid);
        nym._saveLeftGroups();
    }
    if (s.leftGroupTimes && typeof s.leftGroupTimes === 'object') {
        if (!nym.leftGroupTimes) nym.leftGroupTimes = new Map();
        for (const [gid, v] of Object.entries(s.leftGroupTimes)) {
            if (typeof v !== 'number' || v <= 0) continue;
            const cur = nym.leftGroupTimes.get(gid) || 0;
            if (v > cur) nym.leftGroupTimes.set(gid, v);
        }
        try { localStorage.setItem('nym_left_group_times', JSON.stringify(Object.fromEntries(nym.leftGroupTimes))); } catch { }
    }

    // Channel read state — keep the later timestamp per channel so badges
    // on a new device don't surface messages already read elsewhere.
    if (s.channelLastRead && typeof s.channelLastRead === 'object') {
        if (!nym.channelLastRead) nym.channelLastRead = new Map();
        let lrChanged = false;
        for (const [ch, v] of Object.entries(s.channelLastRead)) {
            if (typeof v !== 'number' || v <= 0) continue;
            const cur = nym.channelLastRead.get(ch) || 0;
            if (v > cur) { nym.channelLastRead.set(ch, v); lrChanged = true; }
        }
        if (lrChanged && typeof nym._persistUnreadCounts === 'function') {
            nym._persistUnreadCounts(true);
            if (typeof nym.recomputeAllUnreadCounts === 'function') nym.recomputeAllUnreadCounts();
        }
    }

    // Group conversations encrypted inside a gift wrap
    const applyGroupData = (groupData) => {
        for (const [groupId, group] of Object.entries(groupData)) {
            if (!nym.groupConversations.has(groupId)) {
                nym.addGroupConversation(groupId, group.name, group.members || [], group.lastMessageTime || Date.now());
                const g = nym.groupConversations.get(groupId);
                if (g) {
                    if (group.createdBy) g.createdBy = group.createdBy;
                }
            }
        }
        nym._saveGroupConversations();
        nym.updateViewMoreButton('pmList');
    };

    if (s.groupConversations && typeof s.groupConversations === 'object') {
        try { applyGroupData(s.groupConversations); } catch (_) { }
    }

    if (s.groupEphemeralKeys && typeof s.groupEphemeralKeys === 'object') {
        try {
            const beforePks = new Set(nym._getAllKnownEphemeralPubkeys());
            for (const [groupId, entry] of Object.entries(s.groupEphemeralKeys)) {
                nym._mergeEphemeralKeys(groupId, entry);
            }
            nym._saveEphemeralKeys();
            const afterPks = nym._getAllKnownEphemeralPubkeys();
            const newPks = afterPks.filter(pk => !beforePks.has(pk));
            if (newPks.length > 0 && nym.connected) {
                nym._refreshEphemeralSubscriptions();
                nym._recoverEphemeralHistory(newPks);
            }
        } catch (_) { }
    }

    // Restore chat history backup from encrypted settings sync
    if (s.groupMessageHistory && typeof s.groupMessageHistory === 'object') {
        try {
            const refreshedConvKeys = new Set();
            for (const [groupConvKey, backupMessages] of Object.entries(s.groupMessageHistory)) {
                if (!Array.isArray(backupMessages) || backupMessages.length === 0) continue;

                // Inflate stripped backup messages with the fields required for
                // display and filtering (conversationKey, isGroup, isPM, timestamp, author)
                const inflated = backupMessages.map(m => {
                    if (m.conversationKey && m.isPM) return m; // already full-fidelity
                    return Object.assign({
                        author: nym.getNymFromPubkey(m.pubkey) || 'nym',
                        timestamp: new Date((m.created_at || 0) * 1000),
                        isPM: true,
                        isGroup: true,
                        conversationKey: groupConvKey,
                        isHistorical: true,
                        _seq: ++nym._msgSeq
                    }, m);
                });

                const existing = nym.pmMessages.get(groupConvKey) || [];
                const existingIds = new Set(existing.map(m => m.id));

                // Find backup messages that are genuinely new to this device
                const newMsgs = inflated.filter(m => m.id && !existingIds.has(m.id));

                if (newMsgs.length === 0) continue; // nothing to merge

                const merged = [...existing, ...newMsgs];
                merged.sort((a, b) => nym._compareMessages(a, b));
                // Cap to storage limit after merge
                const capped = merged.length > nym.pmStorageLimit
                    ? merged.slice(-nym.pmStorageLimit)
                    : merged;

                nym.pmMessages.set(groupConvKey, capped);
                nym.channelDOMCache.delete(groupConvKey);
                refreshedConvKeys.add(groupConvKey);
            }

            // If the user is currently viewing a group that received new backup
            // messages, re-render it so the merged messages appear immediately.
            if (refreshedConvKeys.size > 0 && nym.inPMMode && nym.currentGroup) {
                const activeKey = nym.getGroupConversationKey(nym.currentGroup);
                if (refreshedConvKeys.has(activeKey)) {
                    nym.loadPMMessages(activeKey);
                }
            }
        } catch (_) { }
    }

    // Retroactively remove left groups that were re-added by early-arriving
    // gift-wrapped messages before this settings sync completed (e.g. new device)
    if (nym.leftGroups.size > 0) {
        let groupsChanged = false;
        for (const gid of nym.leftGroups) {
            if (nym.groupConversations.has(gid)) {
                nym.groupConversations.delete(gid);
                const groupConvKey = nym.getGroupConversationKey(gid);
                nym.pmMessages.delete(groupConvKey);
                nym.channelDOMCache.delete(groupConvKey);
                const pmList = document.getElementById('pmList');
                const item = pmList?.querySelector(`[data-group-id="${gid}"]`);
                if (item) item.remove();
                groupsChanged = true;
            }
        }
        if (groupsChanged) {
            nym._saveGroupConversations();
            nym.updateViewMoreButton('pmList');
        }
    }

    // Retroactively remove closed PMs that were re-added by early-arriving
    // gift-wrapped messages before this settings sync completed (e.g. new device)
    if (nym.closedPMs.size > 0) {
        for (const pk of nym.closedPMs) {
            if (nym.pmConversations.has(pk)) {
                nym.pmConversations.delete(pk);
                const convKey = nym.getPMConversationKey(pk);
                nym.pmMessages.delete(convKey);
                const item = document.querySelector(`[data-pubkey="${pk}"]`);
                if (item) item.remove();
            }
        }
        nym.updateViewMoreButton('pmList');
    }

    nym._updateNotificationBadge();
    if (!nym._settingsSyncMessageShown) {
        nym._settingsSyncMessageShown = true;
    }
}

// Sign-out button
async function signOut() {
    if (!(await window.showAppConfirm('Sign out and disconnect from Nymchat?', { okLabel: 'Sign out', danger: true }))) return;
    // Clear auto-ephemeral preferences on logout
    localStorage.removeItem('nym_auto_ephemeral');
    localStorage.removeItem('nym_auto_ephemeral_nick');
    localStorage.removeItem('nym_auto_ephemeral_channel');
    nymSecretRemove('nym_session_nsec');
    localStorage.removeItem('nym_random_keypair_per_session');
    nymSecretRemove('nym_dev_nsec');
    localStorage.removeItem('nym_color_mode');
    localStorage.removeItem('nym_purchases_cache');
    localStorage.removeItem('nym_active_style');
    localStorage.removeItem('nym_active_flair');
    // Clear Nostr login state
    localStorage.removeItem('nym_nostr_login_method');
    localStorage.removeItem('nym_nostr_login_pubkey');
    nymSecretRemove('nym_nostr_login_nsec');
    localStorage.removeItem('nym_nostr_login_npub');
    localStorage.removeItem('nym_bio');
    localStorage.removeItem('nym_lightning_address_global');
    localStorage.removeItem('nym_avatar_url');
    localStorage.removeItem('nym_banner_url');
    nym.cmdQuit();
}

// Native-app "Open Wallet" compatibility
function installNativeWalletBridgeCompat(n) {
    if (!n || typeof n.openInWallet !== 'function') return;
    try {
        if (n._openInWalletOverridden) {
            // Bridge already wrapped it — restore the real launcher it saved.
            if (typeof n._originalOpenInWallet === 'function') {
                n.openInWallet = n._originalOpenInWallet;
            }
        } else {
            // Pre-empt the bridge: expose the real launcher and mark the wrap as
            // already done so the bridge calls through instead of re-wrapping.
            n._originalOpenInWallet = n.openInWallet.bind(n);
            n._openInWalletOverridden = true;
        }
    } catch (e) { /* non-fatal: fall back to native bridge behavior */ }
}

// Initialize on load
document.addEventListener('DOMContentLoaded', async () => {
    // Construct the NYM instance now that all module scripts have been parsed
    // and their methods have been attached to NYM.prototype.
    nym = new NYM();
    window.nym = nym;
    installNativeWalletBridgeCompat(nym);

    // If the user enabled identity encryption, unlock (decrypt the stored
    // secrets into memory) before any identity-restore code reads them.
    try { await nym.unlockVaultAtBoot(); } catch (e) { /* proceed; secrets read as absent */ }

    // Parse URL for channel routing BEFORE initialization
    parseUrlChannel();

    await nym.initialize();
    startRelayStatsSampling();

    // Apply group chat & PM only mode on startup (hide channels section)
    if (nym.settings.groupChatPMOnlyMode) {
        const channelsSection = document.querySelector('#channelList')?.closest('.nav-section');
        if (channelsSection) channelsSection.style.display = 'none';
    }

    // Pre-select auto-ephemeral checkbox if previously enabled
    if (localStorage.getItem('nym_auto_ephemeral') === 'true') {
        const cb = document.getElementById('autoEphemeralCheckbox');
        if (cb) cb.checked = true;
    }

    // Pre-connect to a broadcast relay for instant connection
    async function preConnect() {
        // Pool mode: pool handles all connections after login
        if (nym.useRelayProxy) return;
        for (const relayUrl of nym.defaultRelays) {
            await nym.connectToRelay(relayUrl, 'relay');
            const r = nym.relayPool.get(relayUrl);
            if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                nym.updateConnectionStatus('Ready');
                return; // Stop after first successful connection
            }
        }
    }

    preConnect();

    // Auto-focus nickname input
    document.getElementById('nymInput').focus();

    // Add listener to show/hide time format option
    document.getElementById('timestampSelect').addEventListener('change', (e) => {
        const timeFormatGroup = document.getElementById('timeFormatGroup');
        if (timeFormatGroup) {
            timeFormatGroup.style.display = e.target.value === 'true' ? 'block' : 'none';
        }
        const dateFormatGroup = document.getElementById('dateFormatGroup');
        if (dateFormatGroup) {
            dateFormatGroup.style.display = e.target.value === 'true' ? 'block' : 'none';
        }
    });

    // Check if proximity sorting was enabled
    setTimeout(() => {
        if (nym.settings.sortByProximity === true) {
            navigator.geolocation.getCurrentPosition(
                (position) => {
                    nym.userLocation = {
                        lat: position.coords.latitude,
                        lng: position.coords.longitude
                    };
                    // Re-sort channels with location
                    nym.sortChannelsByActivity();
                },
                (error) => {
                    nym.settings.sortByProximity = false;
                    localStorage.setItem('nym_sort_proximity', 'false');
                }
            );
        }
    }, 1000);

    // Wake the page once per second
    nym._setManagedInterval('connectionHealth', () => {
        if (nym.initialConnectionInProgress) return;
        if (nym.connected) {
            nym.updateConnectionStatus();
        }
        if (nym.connected || nym.relayPool.size > 0) {
            nym.checkConnectionHealth();
        }
    }, 1000);

    // Check for saved connection AFTER initialization is complete
    setTimeout(() => {
        checkSavedConnection();
    }, 100);

    // Periodically update user list
    nym._setManagedInterval('userListRefresh', () => {
        if (nym.connected) {
            nym.updateUserList();
        }
    }, 5000);

    // Once connected, broadcast our status-visibility preference
    nym._initialStatusVisibilityBroadcast = false;
    nym._setManagedInterval('initialStatusVisibility', () => {
        if (nym._initialStatusVisibilityBroadcast) return;
        if (!nym.connected || !nym.pubkey) return;
        nym._initialStatusVisibilityBroadcast = true;
        if (nym.settings.showStatus === false && typeof nym.publishStatusVisibility === 'function') {
            nym.publishStatusVisibility(true);
        }
    }, 2000);

    // Override the existing search functions to handle collapsed lists properly
    const originalHandleChannelSearch = nym.handleChannelSearch;
    nym.handleChannelSearch = function (searchTerm) {
        // First expand the list to make all items searchable
        const channelList = document.getElementById('channelList');
        const wasCollapsed = channelList.classList.contains('list-collapsed');

        if (wasCollapsed && searchTerm.length > 0) {
            channelList.classList.remove('list-collapsed');
            channelList.classList.add('list-expanded');
        }

        // Call original search function
        originalHandleChannelSearch.call(this, searchTerm);

        // Restore collapsed state if search is cleared
        if (wasCollapsed && searchTerm.length === 0) {
            channelList.classList.add('list-collapsed');
            channelList.classList.remove('list-expanded');
        }
    };

    const originalFilterPMs = nym.filterPMs;
    nym.filterPMs = function (searchTerm) {
        // First expand the list to make all items searchable
        const pmList = document.getElementById('pmList');
        const wasCollapsed = pmList.classList.contains('list-collapsed');

        if (wasCollapsed && searchTerm.length > 0) {
            pmList.classList.remove('list-collapsed');
            pmList.classList.add('list-expanded');
        }

        // Call original filter function
        originalFilterPMs.call(this, searchTerm);

        // Restore collapsed state if search is cleared
        if (wasCollapsed && searchTerm.length === 0) {
            pmList.classList.add('list-collapsed');
            pmList.classList.remove('list-expanded');
        }
    };

    const originalFilterUsers = nym.filterUsers;
    nym.filterUsers = function (searchTerm) {
        // First expand the list to make all items searchable
        const userList = document.getElementById('userListContent');
        const wasCollapsed = userList.classList.contains('list-collapsed');

        if (wasCollapsed && searchTerm.length > 0) {
            userList.classList.remove('list-collapsed');
            userList.classList.add('list-expanded');
        }

        // Call original filter function
        originalFilterUsers.call(this, searchTerm);

        // Restore collapsed state if search is cleared
        if (wasCollapsed && searchTerm.length === 0) {
            userList.classList.add('list-collapsed');
            userList.classList.remove('list-expanded');
        }
    };

    // Background message cleanup
    nym._setManagedInterval('messageCleanup', () => {
        // Clean up stored messages for inactive channels
        const currentKey = nym.currentGeohash ? `#${nym.currentGeohash}` : nym.currentChannel;

        nym.messages.forEach((messages, channel) => {
            if (channel === currentKey) return;
            if (messages.length > nym.channelMessageLimit) {
                nym.messages.set(channel, messages.slice(-nym.channelMessageLimit));
            }
        });

        // Prune inactive PM conversations to pmStorageLimit messages max
        const currentPMKey = nym.currentPM ? nym.getPMConversationKey(nym.currentPM) : null;
        const currentGroupKey = nym.currentGroup ? nym.getGroupConversationKey(nym.currentGroup) : null;
        nym.pmMessages.forEach((messages, convKey) => {
            if (convKey === currentPMKey || convKey === currentGroupKey) return;
            if (messages.length > nym.pmStorageLimit) {
                nym.pmMessages.set(convKey, messages.slice(-nym.pmStorageLimit));
            }
        });

        // Prune event deduplication if too large (keep recent entries for proper deduplication)
        if (nym.eventDeduplication.size > 10000) {
            const entriesToDelete = nym.eventDeduplication.size - 7500;
            let deleted = 0;
            for (const key of nym.eventDeduplication.keys()) {
                if (deleted >= entriesToDelete) break;
                nym.eventDeduplication.delete(key);
                deleted++;
            }
        }
    }, 60000);

    // Periodically check and clear expired blacklists
    nym._setManagedInterval('blacklistExpiry', () => {
        if (nym.connected) {
            // Check all blacklisted relays for expiration
            const expiredRelays = [];
            nym.blacklistedRelays.forEach(relayUrl => {
                if (nym.isBlacklistExpired(relayUrl)) {
                    expiredRelays.push(relayUrl);
                }
            });

            // Try to reconnect to expired blacklisted relays (direct mode only)
            if (!nym.useRelayProxy) {
                expiredRelays.forEach(relayUrl => {
                    if (nym.defaultRelays.includes(relayUrl) && !nym.relayPool.has(relayUrl)) {
                        nym.connectToRelay(relayUrl, 'relay').then(() => {
                            const r = nym.relayPool.get(relayUrl);
                            if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                                nym.subscribeToSingleRelay(relayUrl);
                                nym.updateConnectionStatus();
                            }
                        });
                    }
                });
            }
        }
    }, 60000); // Check every minute

    // Scroll-to-bottom button and mobile input-buttons hide on scroll
    const messageInput = document.getElementById('messageInput');
    const messagesContainer = document.getElementById('messagesContainer');
    const messagesScroller = document.getElementById('messagesScroller');
    const scrollToBottomBtn = document.getElementById('scrollToBottomBtn');
    if (messagesScroller && scrollToBottomBtn) {
        // rAF-coalesce: scroll fires up to the display refresh rate; doing the
        // layout reads (scrollTop/scrollHeight/clientHeight) + branching once per
        // frame avoids forced reflows on every tick during fast mobile scrolling.
        let _scrollRafPending = false;
        const processScroll = () => {
            _scrollRafPending = false;
            // Reverse-column container: scrollTop is 0 at the bottom (newest)
            // and negative scrolling up. Math.abs gives distance from bottom.
            const distanceFromBottom = Math.abs(messagesScroller.scrollTop);
            const distanceFromTop = (messagesScroller.scrollHeight - messagesScroller.clientHeight) - distanceFromBottom;

            if (distanceFromTop <= 5) {
                if (nym.inPMMode) {
                    const convKey = nym.currentGroup
                        ? nym.getGroupConversationKey(nym.currentGroup)
                        : (nym.currentPM ? nym.getPMConversationKey(nym.currentPM) : null);
                    if (convKey && !nym._pmLoadingOlder) {
                        const startIdx = nym.pmRenderedStart.get(convKey);
                        if (startIdx !== undefined && startIdx > 0) {
                            nym._pmLoadingOlder = true;
                            requestAnimationFrame(() => {
                                nym.loadOlderPMMessages(convKey);
                                nym._pmLoadingOlder = false;
                            });
                        } else if ((startIdx === 0 || startIdx === undefined)
                            && typeof nym.pmLazyLoadOlderForConversation === 'function'
                            && !nym._pmR2NoMore && !nym._pmR2Loading) {
                            nym._pmLoadingOlder = true;
                            nym.pmLazyLoadOlderForConversation(convKey)
                                .catch(() => { })
                                .finally(() => { nym._pmLoadingOlder = false; });
                        }
                    }
                } else if (messagesContainer && !nym._channelLoadingOlder) {
                    const storageKey = nym.currentGeohash ? `#${nym.currentGeohash}` : nym.currentChannel;
                    const startIdx = nym.channelRenderedStart.get(storageKey);
                    if (startIdx !== undefined && startIdx > 0) {
                        nym._channelLoadingOlder = true;
                        requestAnimationFrame(() => {
                            nym.loadOlderChannelMessages(storageKey);
                            nym._channelLoadingOlder = false;
                        });
                    }
                }
            }

            const wasScrolledUp = nym.userScrolledUp;
            nym.userScrolledUp = distanceFromBottom > 150;
            if (wasScrolledUp && !nym.userScrolledUp && !nym.inPMMode &&
                typeof nym.markVisibleChannelMessagesRead === 'function') {
                nym.markVisibleChannelMessagesRead();
            }

            if (distanceFromBottom < 50) {
                if (nym.inPMMode) {
                    const collapseKey = nym.currentGroup
                        ? nym.getGroupConversationKey(nym.currentGroup)
                        : (nym.currentPM ? nym.getPMConversationKey(nym.currentPM) : null);
                    if (collapseKey) {
                        clearTimeout(nym._pmCollapseTimer);
                        nym._pmCollapseTimer = setTimeout(() => {
                            if (Math.abs(messagesScroller.scrollTop) < 50) nym.collapsePMToLatest(collapseKey);
                        }, 600);
                    }
                } else {
                    const storageKey = nym.currentGeohash ? `#${nym.currentGeohash}` : nym.currentChannel;
                    if (storageKey) {
                        clearTimeout(nym._channelCollapseTimer);
                        nym._channelCollapseTimer = setTimeout(() => {
                            if (Math.abs(messagesScroller.scrollTop) < 50) nym.collapseChannelToLatest(storageKey);
                        }, 600);
                    }
                }
            }

            // Show/hide scroll-to-bottom button
            if (distanceFromBottom > 150) {
                scrollToBottomBtn.classList.add('visible');
            } else {
                scrollToBottomBtn.classList.remove('visible');
            }
        };
        messagesScroller.addEventListener('scroll', () => {
            if (_scrollRafPending) return;
            _scrollRafPending = true;
            requestAnimationFrame(processScroll);
        }, { passive: true });
    }

    // Auto-scroll to bottom when input is focused on mobile (only if near bottom)
    if (messageInput && messagesScroller) {
        messageInput.addEventListener('focus', function () {
            if (window.innerWidth <= 768 && !nym.userScrolledUp) {
                setTimeout(() => {
                    nym._scheduleScrollToBottom();
                }, 300);
            }
        });
    }
});

// Parse URL for channel routing
function parseUrlChannel() {
    const hash = window.location.hash;
    if (hash && hash.length > 1) {
        const channelFromUrl = hash.substring(1).toLowerCase();

        // Store for use after initialization
        window.pendingChannel = channelFromUrl;
    }
}

// Handle channel routing after initialization
async function routeToUrlChannel() {
    if (window.pendingChannel) {
        window.urlChannelRouted = true;
        const channelInput = window.pendingChannel;
        delete window.pendingChannel;

        // Strip legacy g: prefix from old shared URLs
        let channelName = channelInput;
        if (channelInput.startsWith('g:')) {
            channelName = channelInput.substring(2);
        }
        // Sanitize channel name
        channelName = nym.sanitizeChannelName(channelName);
        if (nym.isValidGeohash(channelName)) {
            nym.addChannel(channelName, channelName);
            nym.switchChannel(channelName, channelName);
            nym.userJoinedChannels.add(channelName);
            nym.saveUserChannels();
            nym.displaySystemMessage(`Joined geohash channel #${channelName} from URL`);
        } else {
            nym.displaySystemMessage(`Invalid geohash channel: ${channelName}`);
        }

        // Clear the URL hash to clean up
        history.replaceState(null, null, window.location.pathname);
    }
}

// Relay Stats Modal
function openRelayStats() {
    const modal = document.getElementById('relayStatsModal');
    if (!modal) return;
    syncLowDataToggleFromState();
    modal.classList.add('active');
    startRelayStatsLoop();
}

function syncLowDataToggleFromState() {
    const toggle = document.getElementById('rsLowDataToggle');
    if (!toggle || typeof nym === 'undefined') return;
    toggle.checked = !!(nym.settings && nym.settings.lowDataMode);
}

function toggleLowDataModeFromStats(e) {
    if (typeof nym === 'undefined') return;
    const enabled = !!(e && e.target && e.target.checked);
    const wasEnabled = !!(nym.settings && nym.settings.lowDataMode);
    if (enabled === wasEnabled) return;

    nym.settings.lowDataMode = enabled;
    localStorage.setItem('nym_low_data_mode', String(enabled));

    const settingsSelect = document.getElementById('lowDataModeSelect');
    if (settingsSelect) settingsSelect.value = enabled ? 'true' : 'false';

    nym.applyLowDataMode(enabled);
    nym.displaySystemMessage(enabled ? 'Low Data Mode enabled' : 'Low Data Mode disabled');
}

window.toggleLowDataModeFromStats = toggleLowDataModeFromStats;

function closeRelayStatsModal() {
    stopRelayStatsLoop();
    closeModal('relayStatsModal');
}

// Wire up close button and backdrop click
(function () {
    const observer = new MutationObserver(() => {
        const modal = document.getElementById('relayStatsModal');
        if (!modal) return;
        observer.disconnect();

        // Close when clicking backdrop
        modal.addEventListener('click', (e) => {
            if (e.target === modal) closeRelayStatsModal();
        });

        // Override close button
        const closeBtn = modal.querySelector('.modal-close');
        if (closeBtn) {
            closeBtn.onclick = (e) => { e.stopPropagation(); closeRelayStatsModal(); };
        }

        // Stop stats loop when modal is hidden
        const mo = new MutationObserver(() => {
            if (!modal.classList.contains('active')) stopRelayStatsLoop();
        });
        mo.observe(modal, { attributes: true, attributeFilter: ['class'] });
    });
    observer.observe(document.body, { childList: true, subtree: true });
    // Also try immediately
    const modal = document.getElementById('relayStatsModal');
    if (modal) {
        modal.addEventListener('click', (e) => {
            if (e.target === modal) closeRelayStatsModal();
        });
        const closeBtn = modal.querySelector('.modal-close');
        if (closeBtn) {
            closeBtn.onclick = (e) => { e.stopPropagation(); closeRelayStatsModal(); };
        }
        const mo = new MutationObserver(() => {
            if (!modal.classList.contains('active')) stopRelayStatsLoop();
        });
        mo.observe(modal, { attributes: true, attributeFilter: ['class'] });
    }
})();

let _rsSampleInterval = null;
let _rsRenderInterval = null;

function startRelayStatsSampling() {
    if (_rsSampleInterval) return;
    _rsSampleInterval = setInterval(() => {
        if (document.hidden) return;
        if (typeof nym === 'undefined') return;
        const s = nym.relayStats;
        s.throughputHistory.push(s.eventsThisSecond);
        if (s.throughputHistory.length > 60) s.throughputHistory.shift();
        s.eventsThisSecond = 0;
    }, 1000);
}

function startRelayStatsLoop() {
    startRelayStatsSampling();
    if (_rsRenderInterval) clearInterval(_rsRenderInterval);
    _rsRenderInterval = setInterval(renderRelayStats, 1000);
    renderRelayStats();
}

function stopRelayStatsLoop() {
    if (_rsRenderInterval) { clearInterval(_rsRenderInterval); _rsRenderInterval = null; }
}

function formatBytes(b) {
    if (b < 1024) return b + ' B';
    if (b < 1048576) return (b / 1024).toFixed(1) + ' KB';
    if (b < 1073741824) return (b / 1048576).toFixed(1) + ' MB';
    return (b / 1073741824).toFixed(2) + ' GB';
}

function renderRelayStats() {
    if (typeof nym === 'undefined') return;
    // Skip the per-second DOM reads + canvas redraw while the tab is hidden; the
    // loop is already modal-scoped, but a backgrounded tab need not wake the CPU.
    if (document.hidden) return;
    syncLowDataToggleFromState();
    const s = nym.relayStats;
    const pool = nym.relayPool;
    const writeOnly = nym.writeOnlyRelays || new Set();

    // Count connected — pool mode uses poolConnectedRelays count
    let connected = 0;
    if (nym.useRelayProxy && nym._isAnyPoolOpen()) {
        connected = nym.poolConnectedRelays.filter(u => !writeOnly.has(u)).length;
    } else {
        pool.forEach((relay, url) => {
            if (writeOnly.has(url)) return;
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN) connected++;
        });
    }

    // Average latency
    let latSum = 0, latCount = 0;
    s.latencyPerRelay.forEach((ms, url) => {
        if (writeOnly.has(url)) return;
        if (nym.useRelayProxy || pool.has(url)) { latSum += ms; latCount++; }
    });
    const avgLat = latCount > 0 ? Math.round(latSum / latCount) : null;

    // Update summary cards
    const elConn = document.getElementById('rsConnected');
    const elLat = document.getElementById('rsLatency');
    const elEvt = document.getElementById('rsEventsTotal');
    const elData = document.getElementById('rsDataTransfer');

    if (elConn) elConn.textContent = connected;
    if (elLat) elLat.textContent = avgLat !== null ? avgLat + 'ms' : '--';
    if (elEvt) elEvt.textContent = s.totalEvents > 9999 ? (s.totalEvents / 1000).toFixed(1) + 'k' : s.totalEvents;
    if (elData) elData.textContent = formatBytes(s.bytesReceived);

    // Draw throughput graph
    drawThroughputGraph(s.throughputHistory);

    // Relay list
    renderRelayList(pool, s);
}

function drawThroughputGraph(history) {
    const canvas = document.getElementById('rsThroughputCanvas');
    if (!canvas) return;
    const ctx = canvas.getContext('2d');

    // High-DPI (cap at 1x in performance mode to reduce fill rate)
    const rect = canvas.getBoundingClientRect();
    const dpr = (typeof nym !== 'undefined' && nym.performanceMode) ? 1 : (window.devicePixelRatio || 1);
    const w = rect.width;
    const h = rect.height;
    if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
        canvas.width = w * dpr;
        canvas.height = h * dpr;
        ctx.scale(dpr, dpr);
    }

    ctx.clearRect(0, 0, w, h);

    const data = history.length > 0 ? history : [0];
    const maxVal = Math.max(1, ...data);
    const points = 60;
    const stepX = w / (points - 1);

    // Get the primary color from CSS
    const primaryColor = getComputedStyle(document.documentElement).getPropertyValue('--primary').trim() || '#00ff00';

    // Fill gradient
    const grad = ctx.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0, hexToRgba(primaryColor, 0.25));
    grad.addColorStop(1, hexToRgba(primaryColor, 0.02));

    ctx.beginPath();
    const startIdx = Math.max(0, points - data.length);
    ctx.moveTo(startIdx * stepX, h);
    for (let i = 0; i < data.length; i++) {
        const x = (startIdx + i) * stepX;
        const y = h - (data[i] / maxVal) * (h - 4) - 2;
        if (i === 0) ctx.lineTo(x, y);
        else ctx.lineTo(x, y);
    }
    ctx.lineTo((startIdx + data.length - 1) * stepX, h);
    ctx.closePath();
    ctx.fillStyle = grad;
    ctx.fill();

    // Line
    ctx.beginPath();
    for (let i = 0; i < data.length; i++) {
        const x = (startIdx + i) * stepX;
        const y = h - (data[i] / maxVal) * (h - 4) - 2;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = primaryColor;
    ctx.lineWidth = 1.5;
    ctx.lineJoin = 'round';
    ctx.stroke();

    // Scale labels
    ctx.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--text-dim').trim() || '#8a8a9a';
    ctx.font = '9px monospace';
    ctx.textAlign = 'right';
    ctx.fillText(maxVal + '/s', w - 2, 10);
    ctx.fillText('0', w - 2, h - 2);
}

function hexToRgba(hex, alpha) {
    // Handle common CSS color values
    if (hex.startsWith('rgb')) {
        const match = hex.match(/[\d.]+/g);
        if (match && match.length >= 3) {
            return `rgba(${match[0]}, ${match[1]}, ${match[2]}, ${alpha})`;
        }
    }
    hex = hex.replace('#', '');
    if (hex.length === 3) hex = hex.split('').map(c => c + c).join('');
    const r = parseInt(hex.substring(0, 2), 16);
    const g = parseInt(hex.substring(2, 4), 16);
    const b = parseInt(hex.substring(4, 6), 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function renderRelayList(pool, stats) {
    const listEl = document.getElementById('rsRelayList');
    if (!listEl) return;

    const writeOnly = (typeof nym !== 'undefined' && nym.writeOnlyRelays) ? nym.writeOnlyRelays : new Set();
    const entries = [];

    if (typeof nym !== 'undefined' && nym.useRelayProxy && nym._isAnyPoolOpen()) {
        // Pool mode: render every known relay (connected + recently-seen) so
        // a single shard hiccup doesn't make rows disappear and reappear.
        const connectedSet = new Set(nym.poolConnectedRelays);
        const known = new Set([...connectedSet]);
        if (nym._poolRelayLastSeen) {
            nym._poolRelayLastSeen.forEach((_, url) => known.add(url));
        }
        known.forEach(url => {
            if (url === 'relay-pool') return;
            if (writeOnly.has(url)) return;
            entries.push({
                url,
                open: connectedSet.has(url),
                events: stats.eventsPerRelay.get(url) || 0,
                latency: stats.latencyPerRelay.get(url) || null
            });
        });
    } else {
        pool.forEach((relay, url) => {
            if (writeOnly.has(url)) return;
            const isOpen = relay.ws && relay.ws.readyState === WebSocket.OPEN;
            entries.push({
                url,
                open: isOpen,
                events: stats.eventsPerRelay.get(url) || 0,
                latency: stats.latencyPerRelay.get(url) || null
            });
        });
    }

    entries.sort((a, b) => {
        if (a.open !== b.open) return a.open ? -1 : 1;
        return b.events - a.events;
    });

    if (entries.length === 0) {
        listEl.innerHTML = '<div class="nm-app-5">No relays connected</div>';
        return;
    }

    const existing = new Map();
    listEl.querySelectorAll('.relay-stats-row').forEach(row => {
        const url = row.dataset.rsUrl;
        if (url) existing.set(url, row);
    });

    const seen = new Set();
    let prevRow = null;
    entries.forEach(e => {
        seen.add(e.url);
        let row = existing.get(e.url);
        const shortUrl = e.url.replace('wss://', '').replace('ws://', '');
        if (!row) {
            row = document.createElement('div');
            row.className = 'relay-stats-row';
            row.dataset.rsUrl = e.url;
            row.innerHTML =
                `<span class="relay-stats-dot ${e.open ? 'open' : 'closed'}"></span>` +
                `<span class="relay-stats-url" title="${nym.escapeHtml(e.url)}">${nym.escapeHtml(shortUrl)}</span>` +
                `<span class="relay-stats-latency">${e.latency !== null ? e.latency + 'ms' : '--'}</span>` +
                `<span class="relay-stats-events">${e.events} evt</span>`;
        } else {
            const dot = row.querySelector('.relay-stats-dot');
            if (dot) dot.className = `relay-stats-dot ${e.open ? 'open' : 'closed'}`;
            const evtEl = row.querySelector('.relay-stats-events');
            if (evtEl) evtEl.textContent = e.events + ' evt';
            const latEl = row.querySelector('.relay-stats-latency');
            if (latEl) latEl.textContent = e.latency !== null ? e.latency + 'ms' : '--';
        }
        // Move into the correct sort position
        if (prevRow) {
            if (prevRow.nextElementSibling !== row) {
                prevRow.parentNode.insertBefore(row, prevRow.nextElementSibling);
            }
        } else if (listEl.firstElementChild !== row) {
            listEl.insertBefore(row, listEl.firstElementChild);
        }
        prevRow = row;
    });

    existing.forEach((row, url) => { if (!seen.has(url)) row.remove(); });
}