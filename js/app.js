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
                body: 'Tap here to edit the nickname, avatar, banner, and bio for your Nym in this session. View the private key (nsec) of the Nym and save it if you would like to reuse this same Nym identity to login with it across devices.',
                selector: '.nym-display',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Connection',
                body: 'The current relay connection status. Tap here to view network stats such as the average latency, number of received events, and bandwidth use.',
                selector: '.status-indicator',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Main Menu',
                body: 'Get flair addon packs to change the styling of your messages and nickname. Edit settings such as sorting geohash channels by proximity, adding a Bitcoin lightning address, changing the app\'s theme, manage blocked users and keywords, and more. Logout to terminate session and start a new identity.',
                selector: (window.innerWidth > 768 ? '.header-actions' : '.sidebar-actions'),
                onBefore: () => { if (window.innerWidth <= 768) return ensureSidebarOpenOnMobile(); }
            },
            {
                title: 'Channels',
                body: 'Browse and switch geohash or non-geohash channels. Use the search feature to find and join geohash or non-geohash channels. Geohash is for location-based chat using geohash codes (e.g., #w1, #dr5r). These are bridged with Bitchat and can be sorted by proximity to your location.',
                selector: '#channelList',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Explore Geohash',
                body: 'Tap the globe to explore geohash-only channels on a 3D globe.',
                selector: '.discover-icon',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Private Messages',
                body: 'Your end-to-end encrypted one‑on‑one and group chat messages live here. Tap the + symbol to start a new PM or group chat.',
                selector: '#pmList',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Active Nyms',
                body: 'See who is currently active. Tap a nym to PM them and more.',
                selector: '#userList',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Messages',
                body: 'Channel messages appear here. Tap a nym\'s nickname for quick actions such as to react with emoji, zap Bitcoin, PM, mention, block and more from the context menu.',
                selector: '#messagesContainer',
                onBefore: ensureSidebarClosedOnMobile
            },
            {
                title: 'Compose',
                body: 'Type your message, add emoji or upload an image, then SEND. Markdown is supported. You can also type commands for other actions, such as creating an away message and many more.',
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
        state.overlay?.classList.remove('active');
        if (state.overlay) state.overlay.style.display = 'none';
        if (state.highlight) state.highlight.style.display = 'none';

        // Save flag
        if (markSeen) {
            try { localStorage.setItem('nym_tutorial_seen', 'true'); } catch (_) { }
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
     *   geohash-globe        Geohash channels and 3D globe explorer
     *   notifications        Notification history, badges, sounds, settings
     *   settings             User settings: load/save, sync to Nostr, theme/color mode, image blur
     *   ui-context           Context menus, modals, gestures, sidebar, GIF picker, link previews, zap modals, event listeners
     *   init                 App initialization, device capability detection, performance mode
     */

    constructor() {
        this.relayPool = new Map();
        this._isCloudflareHost = this._detectCloudflareHost();
        this.useRelayProxy = true;
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
        // Core default relays - always connected first for fast startup
        this.defaultRelays = [
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
        this.bitchatDMRelays = [
            'wss://relay.nymchat.app',
            'wss://relay.damus.io',
            'wss://nos.lol',
            'wss://relay.primal.net',
            'wss://offchain.pub',
            'wss://relay.0xchat.com',
            'wss://nostr21.com'
        ];
        this.allRelayUrls = new Set(this.defaultRelays);
        this.pendingConnections = new Map();
        this.relayList = [];
        this.maxRelaysForReq = 1000;
        this.relayTimeout = 2000;
        this.eventDeduplication = new Map();
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
        this.connectionMode = 'ephemeral';
        this.currentChannel = 'nym';
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
        this._ephemeralSubIds = [];
        this._dmCatchupReady = Promise.resolve();
        this.currentGroup = null;
        this._newPMRecipients = [];
        this.groupMessageReaders = new Map();
        this._unfurlCache = new Map();
        this.nostrFollowList = [];
        this.nostrFollowProfiles = [];
        this._followListFetched = false;
        this.unreadCounts = new Map();
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
        this.performanceMode = false;
        this._deviceCapabilities = this._detectDeviceCapabilities();
        this._applyPerformanceMode();
        const _tier = this._deviceCapabilities.tier;
        this.channelSubscriptionBatchSize = _tier === 'low' ? 5 : (_tier === 'high' ? 15 : 10);
        this.channelMessageLimit = _tier === 'low' ? 50 : (_tier === 'high' ? 150 : 100);
        this.pmStorageLimit = _tier === 'low' ? 200 : (_tier === 'high' ? 1000 : 500);
        this.pmPageSize = 100;
        this.pmLoadMoreSize = 50;
        this.pmRenderedStart = new Map();
        this.pinnedLandingChannel = this.settings.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' };
        if (this.settings.groupChatPMOnlyMode) {
            // In PM-only mode, don't default to a geohash channel
            this.currentChannel = null;
            this.currentGeohash = null;
        } else if (this.pinnedLandingChannel.type === 'geohash' && this.pinnedLandingChannel.geohash) {
            this.currentChannel = this.pinnedLandingChannel.geohash;
            this.currentGeohash = this.pinnedLandingChannel.geohash;
        } else {
            this.currentChannel = 'nym';
            this.currentGeohash = 'nym';
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
        this.commonGeohashes = ['nym', '9q', 'w2', 'dr5r', '9q8y', 'u4pr', 'gcpv', 'f2m6', 'xn77', 'tjm5'];
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
        this.failedRelays = new Map();
        this.relayRetryDelay = 2 * 60 * 1000;
        this.previouslyConnectedRelays = new Set();
        this.floodTracking = new Map();
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
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun1.l.google.com:19302' },
            { urls: 'stun:stun2.l.google.com:19302' },
            { urls: 'stun:stun.cloudflare.com:3478' }
        ];
        this.P2P_SIGNALING_KIND = 25051;
        this.P2P_FILE_STATUS_KIND = 25052;
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
        this.typingUsers = new Map();
        this._typingThrottleTime = 0;
        this._typingSendInterval = 3000;
        this._typingExpireMs = 5000;
        this._typingStopTimer = null;
        this.notificationHistory = this._loadNotificationHistory();
        this.notificationLastReadTime = parseInt(localStorage.getItem('nym_notification_last_read') || '0');
        this.notificationsEnabled = localStorage.getItem('nym_notifications_enabled') !== 'false';
        this.groupNotifyMentionsOnly = localStorage.getItem('nym_group_notify_mentions_only') === 'true';
        this.notifyFriendsOnly = localStorage.getItem('nym_notify_friends_only') === 'true';
        this.closedPMs = new Set(JSON.parse(localStorage.getItem('nym_closed_pms') || '[]'));
        this.leftGroups = new Set(JSON.parse(localStorage.getItem('nym_left_groups') || '[]'));
        this.recentEmojis = [];
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
        this.bannerBlobCache = new Map();
        this.bannerBlobInflight = new Map();
        this._proxyFetchQueue = [];
        this._proxyFetchActive = 0;
        this._proxyFetchMaxConcurrent = 3;
        this.profileFetchedAt = new Map();
        this.profileFetchQueue = [];
        this.profileFetchTimer = null;
        this.profileFetchBatchDelay = 100;
        this.pendingProfileResolvers = new Map();
        this.localActiveStyle = null;
        this.localActiveFlair = null;
        this.shopItemsLoaded = false;
        this.shopPurchasesTimestamp = 0;
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
        // Seed nymbot into users map so it always appears in sidebar and mention autocomplete
        this.users.set(this.verifiedBot.pubkey, {
            nym: 'Nymbot',
            pubkey: this.verifiedBot.pubkey,
            lastSeen: Date.now(),
            status: 'online',
            channels: new Set()
        });
        // Seed nymbot avatar so it shows in sidebar and user list instead of robohash
        this.userAvatars.set(this.verifiedBot.pubkey, 'https://nymchat.app/images/nymbot-icon.png');
        this.isFlutterWebView = navigator.userAgent.includes('NYMApp') ||
            navigator.userAgent.includes('Flutter');

        if (this.isFlutterWebView) {
        }
        this.shopItems = {
            styles: [
                {
                    id: 'style-satoshi',
                    name: 'Satoshi',
                    description: 'Bitcoin-themed orange glow',
                    price: 21420,
                    preview: 'style-preview-satoshi',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Satoshi (Bitcoin)">
<title>Satoshi (Bitcoin)</title>
<circle cx="12" cy="12" r="9"/>
<path d="M10 6v12"/>
<path d="M10 7H13C15.1 7 16.5 8.2 16.5 9.8C16.5 11.4 15.1 12.5 13 12.5H10"/>
<path d="M10 12.5H13C15.1 12.5 16.5 13.7 16.5 15.3C16.5 16.9 15.1 18 13 18H10"/>
<path d="M12.5 5v2"/>
<path d="M12.5 17v2"/>
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
                    description: 'Shifting neon aurora gradient',
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
                    description: 'Animated rainbow gradient',
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
                    description: 'Sparkling diamond badge',
                    price: 10000,
                    type: 'nickname-flair',
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
<circle cx="12" cy="10" r="5.5"/>
<rect x="8" y="14.5" width="8" height="4" rx="1.2"/>
<circle cx="9.5" cy="10" r="1.2"/>
<circle cx="14.5" cy="10" r="1.2"/>
<path d="M11.2 12.8 12 11.2 12.8 12.8Z"/>
<path d="M10 14.5v2M12 14.5v2M14 14.5v2"/>
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
<polygon points="12 3 15 8 9 8"/>
<rect x="9" y="8" width="6" height="7" rx="3"/>
<circle cx="12" cy="11.5" r="1.6"/>
<polygon points="9 13 6.5 15 9 16"/>
<polygon points="15 13 17.5 15 15 16"/>
<polygon points="12 15.5 10.7 19 12 18 13.3 19"/>
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
<path d="M8 21H16"/>
<path d="M12 17V21"/>
<path d="M7 9h10v2a5 5 0 0 1-5 5a5 5 0 0 1-5-5V9z"/>
<path d="M5 9H3a3 3 0 0 0 3 3"/>
<path d="M19 9h2a3 3 0 0 1-3 3"/>
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
                }
            ]
        };

        this.userPurchases = new Map();
        this.activeShopTab = 'styles';
        this.activeMessageStyle = null;
        this.activeFlair = null;
        this.otherUsersShopItems = new Map();
        this.shopItemsCache = new Map();
        this.activeCosmetics = new Set();
        this.supporterBadgeActive = localStorage.getItem('nym_supporter_active') !== 'false';
        this.loadShopActiveCache();
        this._restorePurchasesFromCache();
        setTimeout(() => {
            const cachedStyle = localStorage.getItem('nym_active_style');
            const cachedFlair = localStorage.getItem('nym_active_flair');

            if (cachedStyle && cachedStyle !== '' && !this.activeMessageStyle) {
                this.activeMessageStyle = cachedStyle;
                this.localActiveStyle = cachedStyle;
            }

            if (cachedFlair && cachedFlair !== '' && !this.activeFlair) {
                this.activeFlair = cachedFlair;
                this.localActiveFlair = cachedFlair;
            }
        }, 0);
    }

}

// Global instance.
// Instantiated inside DOMContentLoaded so that all module files (which attach
// methods to NYM.prototype via Object.assign) have been parsed first.
// The constructor invokes methods like _detectCloudflareHost() and fetchGeoRelays(),
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
    const container = document.getElementById('messagesContainer');
    if (!container) return;

    // User explicitly wants to go to the bottom — clear the scrolled-up flag
    nym.userScrolledUp = false;

    // Cancel any pending coalesced scroll so we can do it immediately
    if (nym._scrollRAF) {
        cancelAnimationFrame(nym._scrollRAF);
        nym._scrollRAF = null;
    }

    // Force scroll to bottom immediately, then again on next frame to handle
    // any pending layout changes (images loading, animations, etc.)
    container.scrollTop = container.scrollHeight;
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

function selectImage() {
    document.getElementById('fileInput').click();
}

function selectP2PFile() {
    document.getElementById('p2pFileInput').click();
}

function closeModal(id) {
    document.getElementById(id).classList.remove('active');
}

function closeImageModal() {
    document.getElementById('imageModal').classList.remove('active');
    const modalVid = document.getElementById('modalVideo');
    modalVid.pause();
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

    if (modalImg.style.display !== 'none' && modalImg.src) {
        src = modalImg.src;
        const ext = src.split('.').pop().split('?')[0].toLowerCase();
        const imageExts = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
        defaultName = 'image.' + (imageExts.includes(ext) ? ext : 'jpg');
    } else if (modalVid.style.display !== 'none') {
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
        <button class="poll-remove-option-btn" onclick="this.parentElement.remove()" title="Remove">✕</button>
    `;
    container.appendChild(row);
    if (existing.length + 1 >= 6) {
        document.getElementById('pollAddOptionBtn').style.display = 'none';
    }
}

function submitPoll() {
    const question = document.getElementById('pollQuestion').value.trim();
    if (!question) {
        alert('Please enter a question.');
        return;
    }
    const optionInputs = document.querySelectorAll('[data-poll-option]');
    const options = [];
    optionInputs.forEach(input => {
        const val = input.value.trim();
        if (val) options.push(val);
    });
    if (options.length < 2) {
        alert('Please add at least 2 options.');
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
    if (privkeyArrow) privkeyArrow.innerHTML = '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" style="vertical-align: middle;"><path d="M 6 3 L 11 8 L 6 13 Z"/></svg>';
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
                localStorage.setItem('nym_dev_nsec', cmdResult.nsec);
            }
        }
        // If cmdNick was cancelled (e.g. reserved nick) but bio/lightning changed,
        // still publish those changes to relays
        if (!cmdResult && profileDirty) {
            await nym.saveToNostrProfile();
        }
        return;
    }

    // Always publish profile to nostr relays when user clicks Change,
    // so avatar, banner, bio, and lightning changes are all persisted
    await nym.saveToNostrProfile();
    closeModal('nickEditModal');
}

function randomizeNick() {
    const generated = nym.generateRandomNym();
    // Extract base name without #suffix
    const baseName = nym.stripPubkeySuffix(generated);
    document.getElementById('newNickInput').value = baseName;

    // Randomize the robohash avatar preview if no custom avatar is set
    if (!nym.userAvatars.has(nym.pubkey)) {
        const preview = document.getElementById('nickEditAvatarPreview');
        if (preview) {
            preview.src = `https://robohash.org/${encodeURIComponent(baseName)}.png?set=set1&size=80x80`;
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
        if (preview) preview.src = 'https://robohash.org/default.png?set=set1&size=80x80';
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
    if (preview) preview.src = 'https://robohash.org/default.png?set=set1&size=80x80';
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

    const isHidden = slideout.style.display === 'none';
    slideout.style.display = isHidden ? 'block' : 'none';
    if (arrow) arrow.innerHTML = isHidden ? '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" style="vertical-align: middle;"><path d="M 3 6 L 8 11 L 13 6 Z"/></svg>' : '<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" style="vertical-align: middle;"><path d="M 6 3 L 11 8 L 6 13 Z"/></svg>';

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

async function changeRelay() {
    const relaySelect = document.getElementById('connectedRelaySelect').value;
    const customRelay = document.getElementById('customConnectedRelay').value;

    const newRelayUrl = relaySelect === 'custom' ? customRelay : relaySelect;

    if (!newRelayUrl) {
        alert('Please select or enter a relay URL');
        return;
    }

    nym.displaySystemMessage('Switching relay...');
    try {
        if (nym.useRelayProxy && nym._isAnyPoolOpen()) {
            // Pool mode: add this relay to the pool config
            if (!nym.allRelayUrls.includes(newRelayUrl)) {
                nym.allRelayUrls.push(newRelayUrl);
            }
            nym._poolSendRelayConfig();
            nym.displaySystemMessage(`Added ${newRelayUrl} to relay pool.`);
        } else {
            await nym.connectToRelay(newRelayUrl);
        }
    } catch (_) {
        nym.displaySystemMessage('Failed to connect to relay.');
    }
}

async function showSettings() {
    nym.updateRelayStatus();

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
        const currentPinned = nym.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' };

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
            pinnedSearchInput.value = '#nym';
            pinnedValueInput.value = JSON.stringify({ type: 'geohash', geohash: 'nym' });
        }

        // Function to render filtered options
        const renderOptions = (filter = '') => {
            const filterLower = filter.toLowerCase().replace(/^#/, '');
            const filtered = filter
                ? channelOptions.filter(opt => opt.searchText.includes(filterLower))
                : channelOptions;

            if (filtered.length === 0) {
                pinnedDropdown.innerHTML = '<div style="padding: 8px 12px; color: var(--text-dim);">No channels found</div>';
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
                html += `<div style="padding: 6px 12px; font-size: 11px; font-weight: bold; color: var(--text-dim); text-transform: uppercase; background: var(--background); margin-top: 4px;">${groupName}</div>`;
                grouped[groupName].forEach(opt => {
                    html += `<div class="channel-dropdown-option" data-value='${JSON.stringify(opt.value)}' style="padding: 8px 12px; cursor: pointer; color: var(--text);">${opt.label}</div>`;
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

    // Show/hide time format option based on timestamp visibility
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

    // Fill in read receipts toggle
    const readReceiptsSel = document.getElementById('readReceiptsSelect');
    if (readReceiptsSel) {
        readReceiptsSel.value = nym.settings.readReceiptsEnabled !== false ? 'true' : 'false';
    }

    // Fill in typing indicators toggle
    const typingIndicatorsSel = document.getElementById('typingIndicatorsSelect');
    if (typingIndicatorsSel) {
        typingIndicatorsSel.value = nym.settings.typingIndicatorsEnabled !== false ? 'true' : 'false';
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

    // Initialize performance mode select
    const perfSelect = document.getElementById('performanceModeSelect');
    if (perfSelect) {
        perfSelect.value = nym.settings.performanceMode || 'auto';
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
async function refreshAppCacheSize() {
    const el = document.getElementById('appCacheSizeDisplay');
    if (!el) return;
    try {
        if (navigator.storage && typeof navigator.storage.estimate === 'function') {
            const est = await navigator.storage.estimate();
            const usage = formatCacheBytes(est.usage || 0);
            const quota = est.quota ? ` of ${formatCacheBytes(est.quota)} available` : '';
            el.textContent = `${usage} cached on device${quota}`;
            return;
        }
    } catch (_) { }
    el.textContent = 'Cache size unavailable on this browser';
}


async function saveSettings() {
    // Get all settings values
    const theme = document.getElementById('themeSelect').value;
    const sound = document.getElementById('soundSelect').value;
    const autoscroll = document.getElementById('autoscrollSelect').value === 'true';
    const showTimestamps = document.getElementById('timestampSelect').value === 'true';
    const timeFormat = document.getElementById('timeFormatSelect').value;
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

    // Apply blur settings
    nym.blurOthersImages = blurImages;
    nym.saveImageBlurSettings();

    // Read and save accept PMs setting
    const acceptPMsEl = document.getElementById('acceptPMsSelect');
    if (acceptPMsEl) {
        nym.settings.acceptPMs = acceptPMsEl.value;
        localStorage.setItem('nym_accept_pms', acceptPMsEl.value);
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

    // Read and save read receipts setting
    const readReceiptsEnabled = document.getElementById('readReceiptsSelect').value === 'true';
    nym.settings.readReceiptsEnabled = readReceiptsEnabled;
    localStorage.setItem('nym_read_receipts_enabled', String(readReceiptsEnabled));

    // Read and save translation language
    const translateLangEl = document.getElementById('translateLanguageSelect');
    if (translateLangEl) {
        nym.settings.translateLanguage = translateLangEl.value;
        localStorage.setItem('nym_translate_language', translateLangEl.value);
    }

    // Read and save typing indicators setting
    const typingIndicatorsEnabled = document.getElementById('typingIndicatorsSelect').value === 'true';
    nym.settings.typingIndicatorsEnabled = typingIndicatorsEnabled;
    localStorage.setItem('nym_typing_indicators_enabled', String(typingIndicatorsEnabled));

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
            localStorage.removeItem('nym_session_nsec');
        } else {
            localStorage.removeItem('nym_random_keypair_per_session');
            // Save current keypair for reuse if not already saved
            if (nym.privkey && !localStorage.getItem('nym_session_nsec')) {
                try {
                    const nsec = window.NostrTools.nip19.nsecEncode(nym.privkey);
                    localStorage.setItem('nym_session_nsec', nsec);
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
            const defaultChannel = { type: 'geohash', geohash: 'nym' };
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

    // Save performance mode
    const perfModeSelect = document.getElementById('performanceModeSelect');
    if (perfModeSelect) {
        const perfMode = perfModeSelect.value;
        const wasPerfMode = nym.settings.performanceMode;
        nym.settings.performanceMode = perfMode;
        localStorage.setItem('nym_performance_mode', perfMode);
        if (perfMode !== wasPerfMode) {
            nym._applyPerformanceMode();
        }
    }

    nym.displaySystemMessage('Settings saved');

    // Sync settings to Nostr relays if logged in
    nostrSettingsSave();

    closeModal('settingsModal');
}

async function clearLocalStorageCache() {
    if (!confirm('Clear all cached settings, preferences, and on-device app cache? This will not log you out.')) {
        return;
    }

    // Wipe the IndexedDB-backed app cache
    try {
        if (typeof nym.resetCache === 'function') {
            await nym.resetCache();
        }
    } catch (_) { }

    // Preserve session identity and shop purchase keys
    const preserveKeys = {};
    for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && (
            key === 'nym_auto_ephemeral' ||
            key === 'nym_auto_ephemeral_nick' ||
            key === 'nym_auto_ephemeral_channel' ||
            key === 'nym_session_nsec' ||
            key === 'nym_random_keypair_per_session' ||
            key === 'nym_dev_nsec' ||
            key === 'nym_translate_language' ||
            key === 'nym_active_style' ||
            key === 'nym_active_flair' ||
            key === 'nym_shop_active_cache' ||
            key === 'nym_purchases_cache' ||
            key.startsWith('nym_shop_recovery_') ||
            key.startsWith('nym_nostr_login_')
        )) {
            preserveKeys[key] = localStorage.getItem(key);
        }
    }

    // Remove all nym_ keys
    const keysToRemove = [];
    for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && key.startsWith('nym_')) {
            keysToRemove.push(key);
        }
    }
    keysToRemove.forEach(key => localStorage.removeItem(key));

    // Restore preserved keys
    for (const [key, value] of Object.entries(preserveKeys)) {
        if (value !== null) {
            localStorage.setItem(key, value);
        }
    }

    // Reset in-memory state to defaults
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

    nym.displaySystemMessage('Local storage cache cleared. Settings reset to defaults.');
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
    customPreview.innerHTML = '<span style="font-size: 10px; color: var(--text-dim);">Uploading...</span>';

    const url = await nym.uploadWallpaper(file);

    if (url) {
        // Update the custom preview thumbnail
        customPreview.innerHTML = '';
        customPreview.style.backgroundImage = `url('${url}')`;

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
            customPreview.style.backgroundImage = `url('${customUrl}')`;
        }
    }
}

function showAbout() {
    const connectedRelays = nym.relayPool.size;
    nym.displaySystemMessage(`
═══ Nymchat v3.59.297 ═══<br/>
Protocol: <a href="https://nostr.com" target="_blank" rel="noopener" style="color: var(--secondary)">Nostr</a> (kind 20000 geohash channels)<br/>
Connected Relays: ${connectedRelays} relays<br/>
Your nym: ${nym.escapeHtml(nym.nym || 'Not set')}<br/>
<br/>
Inspired by and bridged with Jack Dorsey's <a href="https://bitchat.free" target="_blank" rel="noopener" style="color: var(--secondary)">Bitchat</a><br/>
<br/>
Nymchat is FOSS code on <a href="https://github.com/Spl0itable/NYM" target="_blank" rel="noopener" style="color: var(--secondary)">GitHub</a><br/>
Made with ♥ by <a href="https://nostrservices.com" target="_blank" rel="noopener" style="color: var(--secondary)">21 Million LLC</a><br/>
Lead developer: <a href="https://njump.me/npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv" target="_blank" rel="noopener" style="color: var(--secondary)">Luxas#a8df</a><br/>
<a href="static/tos.html" target="_blank" rel="noopener" style="color: var(--secondary)">Terms of Service</a> | <a href="static/pp.html" target="_blank" rel="noopener" style="color: var(--secondary)">Privacy Policy</a><br/>
`, 'system', { html: true });
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

            // Set login method early so UI features (e.g. long-press anon send)
            // recognise the user as logged in even if later async steps fail
            nym.nostrLoginMethod = method;

            let secretKey = null;
            if (method === 'nsec') {
                const nsec = localStorage.getItem('nym_nostr_login_nsec');
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
            nym.nym = 'anon'; // fallback until kind 0 profile is fetched
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

            // Start tutorial if not seen
            window.maybeStartTutorial(false);

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
                const savedNsec = localStorage.getItem('nym_dev_nsec');
                if (savedNsec) {
                    const result = nym.verifyDeveloperNsec(savedNsec);
                    if (result.valid) {
                        nym.applyDeveloperIdentity(result.secretKey, result.pubkey);
                        isDeveloperLogin = true;
                        nym.displaySystemMessage('Auto-starting verified session...');
                    } else {
                        // Invalid saved nsec - clear it and use random nym
                        localStorage.removeItem('nym_dev_nsec');
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
                const savedNsec = localStorage.getItem('nym_session_nsec');
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
                        localStorage.removeItem('nym_session_nsec');
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
                        localStorage.setItem('nym_session_nsec', nsec);
                    } catch (e) { }
                }
            } else {
                // Generate fresh ephemeral keypair each session (random keypair mode)
                await nym.generateKeypair();
                nym.nym = savedNick || nym.generateRandomNym();
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

            // Load synced settings from relay (groups, closed PMs, etc.)
            nostrSettingsLoad();

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

            // Start tutorial if not seen
            window.maybeStartTutorial(false);

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
    // If no saved connection, the setup modal remains visible (default).
}

async function initializeNym() {
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
            // If developer verified, also save nsec for auto-login
            if (nym.isReservedNick(nymInput)) {
                const nsecVal = document.getElementById('devNsecInput').value.trim();
                if (nsecVal) {
                    localStorage.setItem('nym_dev_nsec', nsecVal);
                }
            }
        }

        // Save the generated keypair for reuse across sessions (unless random keypair mode enabled)
        if (!isDeveloperLogin && nym.privkey) {
            try {
                const nsec = window.NostrTools.nip19.nsecEncode(nym.privkey);
                localStorage.setItem('nym_session_nsec', nsec);
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
                    const nsec = localStorage.getItem('nym_nostr_login_nsec');
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

        // Load synced settings from relay (groups, closed PMs, etc.)
        nostrSettingsLoad();

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

        // Start tutorial if not seen yet
        window.maybeStartTutorial(false);

    } catch (error) {
        // Restore button state on error
        enterBtn.disabled = false;
        enterBtn.innerHTML = originalBtnText;
        alert('Failed to initialize: ' + error.message);
    }
}

// Disconnect/logout function
function disconnectNym() {
    // Disconnect from relay
    if (nym && nym.ws) {
        nym.disconnect();
    }

    // Reload page to start fresh
    window.location.reload();
}

// Nostr Login
function isNymchatApp() {
    return /NymchatApp\//i.test(navigator.userAgent);
}

function isNostrLoggedIn() {
    return localStorage.getItem('nym_nostr_login_method') !== null;
}

function openNostrLogin() {
    if (isNostrLoggedIn()) {
        const method = localStorage.getItem('nym_nostr_login_method');
        const npub = localStorage.getItem('nym_nostr_login_npub') || '';
        if (confirm(`Already logged in via ${method}${npub ? ' (' + npub + ')' : ''}.\n\nWould you like to log out of your Nostr identity?`)) {
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
    localStorage.setItem('nym_nostr_login_nsec', nsecInput);
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
        connectDiv.style.display = '';

        // Set connection string
        document.getElementById('nostrLoginBunkerURI').value = connectURI;

        // Generate QR code
        const qrContainer = document.getElementById('nostrLoginRemoteSignerQR');
        qrContainer.innerHTML = '';
        try {
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
            statusEl.innerHTML = `Signer requires authorization. <a href="${safeUrl}" target="_blank" rel="noopener" style="color: var(--secondary)">Open auth page</a>`;
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
        localStorage.setItem('nym_nip46_client_secret', Array.from(state.clientSecretKey).map(b => b.toString(16).padStart(2, '0')).join(''));
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
    const clientSecretHex = localStorage.getItem('nym_nip46_client_secret');
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

    // Fetch Nostr follow list (kind:3 contact list) for search in New Message modal
    nym.fetchNostrFollowList(pubkey);

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

    // Load settings and purchases from relays for this identity
    nostrSettingsLoad();
    nostrPurchasesLoad();
}

function nostrLogout() {
    localStorage.removeItem('nym_nostr_login_method');
    localStorage.removeItem('nym_nostr_login_pubkey');
    localStorage.removeItem('nym_nostr_login_nsec');
    localStorage.removeItem('nym_nostr_login_npub');
    localStorage.removeItem('nym_nostr_login_profile');
    // Clean up NIP-46 remote signer state
    localStorage.removeItem('nym_nip46_client_secret');
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
    if (typeof nym.resetCache === 'function') {
        nym.resetCache().catch(() => { });
    }
    nym.displaySystemMessage('Nostr identity logged out. Settings will no longer sync.');
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
        const settingsPayload = nym._buildSettingsPayload();

        // Include group conversations directly (entire event is encrypted)
        try {
            if (nym.groupConversations && nym.groupConversations.size > 0) {
                const groupData = {};
                for (const [groupId, group] of nym.groupConversations) {
                    groupData[groupId] = {
                        name: group.name,
                        members: group.members,
                        lastMessageTime: group.lastMessageTime,
                        createdBy: group.createdBy
                    };
                }
                settingsPayload.groupConversations = groupData;
            }
        } catch (_) { }

        // Include ephemeral keys for timing-attack mitigation sync
        try {
            if (nym.groupEphemeralKeys && nym.groupEphemeralKeys.size > 0) {
                const ekData = {};
                for (const [groupId, ek] of nym.groupEphemeralKeys) {
                    ekData[groupId] = nym._serializeEphemeralKeys(ek);
                }
                settingsPayload.groupEphemeralKeys = ekData;
            }
        } catch (_) { }

        // Include chat history backup for new-device recovery
        try {
            if (nym.pmMessages && nym.pmMessages.size > 0) {
                const historyData = {};
                for (const [convKey, messages] of nym.pmMessages) {
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
                    settingsPayload.groupMessageHistory = historyData;
                }
            }
        } catch (_) { }

        await nym._publishEncryptedSettings(settingsPayload);
    } catch (err) {
        console.warn('[NostrSync] Failed to save settings to relays:', err.message);
    }
}

// Load shop purchases from Nostr relays on login
function nostrPurchasesLoad() {
    if (!isNostrLoggedIn()) return;
    const pubkey = localStorage.getItem('nym_nostr_login_pubkey');
    if (!pubkey) return;

    // Collect any pre-existing localStorage purchases (from ephemeral sessions)
    // so we can merge them after loading from relays
    let localPurchases = null;
    try {
        const raw = localStorage.getItem('nym_purchases_cache');
        if (raw) {
            const cache = JSON.parse(raw);
            if (cache && cache.purchases && cache.purchases.length > 0) {
                localPurchases = cache;
            }
        }
    } catch (_) { }

    const subId = Math.random().toString(36).substring(2);
    const filter = {
        kinds: [30078],
        authors: [pubkey],
        '#d': ['nym-shop-purchases'],
        limit: 1
    };

    let received = false;

    // Pool mode: send REQ through the multiplexed pool workers
    if (nym.useRelayProxy && nym._isAnyPoolOpen()) {
        const handler = (evt) => {
            try {
                const msg = JSON.parse(evt.data);
                if (msg[0] === 'EVENT' && msg[1] === subId && msg[2]) {
                    if (received) return;
                    received = true;
                    try {
                        const data = JSON.parse(msg[2].content);
                        applyNostrPurchases(data, localPurchases, msg[2].created_at);
                    } catch (_) { }
                }
                if (msg[0] === 'EOSE' && msg[1] === subId) {
                    nym._poolRemoveMessageListener(handler);
                    try { nym._poolSend(['CLOSE', subId]); } catch (_) { }

                    if (!received && localPurchases) {
                        received = true;
                        applyLocalPurchasesToNostr(localPurchases);
                    }
                }
            } catch (_) { }
        };
        nym._poolAddMessageListener(handler);
        nym._poolSend(['REQ', subId, filter]);

        // Cleanup after 10s
        setTimeout(() => {
            nym._poolRemoveMessageListener(handler);
            try { nym._poolSend(['CLOSE', subId]); } catch (_) { }
        }, 10000);
        return;
    }

    // Direct relay mode: send REQ to each relay individually
    nym.relayPool.forEach((relay, url) => {
        if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;

        const handler = (evt) => {
            try {
                const msg = JSON.parse(evt.data);
                if (msg[0] === 'EVENT' && msg[1] === subId && msg[2]) {
                    if (received) return;
                    received = true;
                    try {
                        const data = JSON.parse(msg[2].content);
                        applyNostrPurchases(data, localPurchases, msg[2].created_at);
                    } catch (_) { }
                }
                if (msg[0] === 'EOSE' && msg[1] === subId) {
                    relay.ws.removeEventListener('message', handler);
                    try { relay.ws.send(JSON.stringify(['CLOSE', subId])); } catch (_) { }

                    // If no relay had purchases but we have local ones, push them up
                    if (!received && localPurchases) {
                        received = true;
                        applyLocalPurchasesToNostr(localPurchases);
                    }
                }
            } catch (_) { }
        };
        relay.ws.addEventListener('message', handler);
        relay.ws.send(JSON.stringify(['REQ', subId, filter]));

        // Cleanup after 10s
        setTimeout(() => {
            relay.ws.removeEventListener('message', handler);
            try { relay.ws.send(JSON.stringify(['CLOSE', subId])); } catch (_) { }
        }, 10000);
    });
}

function applyNostrPurchases(data, localPurchases, eventCreatedAt) {
    if (!data || typeof data !== 'object') return;

    // Use created_at to only apply if this is newer than our current state
    const lastPurchaseSync = nym._lastPurchaseSyncTimestamp || 0;
    if (eventCreatedAt && eventCreatedAt <= lastPurchaseSync) return;
    if (eventCreatedAt) nym._lastPurchaseSyncTimestamp = eventCreatedAt;

    const relayPurchaseIds = new Set();

    // Apply purchases from relay
    if (data.purchases && Array.isArray(data.purchases)) {
        data.purchases.forEach(p => {
            nym.userPurchases.set(p.id, p);
            relayPurchaseIds.add(p.id);
        });
    }

    // Merge local purchases that aren't already in relay data
    let hasNewLocal = false;
    if (localPurchases && localPurchases.purchases) {
        localPurchases.purchases.forEach(([id, purchase]) => {
            if (!relayPurchaseIds.has(id)) {
                nym.userPurchases.set(id, purchase);
                hasNewLocal = true;
            }
        });
    }

    // Apply active style/flair from relay (relay takes priority)
    if (data.activeStyle) {
        nym.activeMessageStyle = data.activeStyle;
        nym.localActiveStyle = data.activeStyle;
        localStorage.setItem('nym_active_style', data.activeStyle);
    }

    if (data.activeFlair) {
        nym.activeFlair = data.activeFlair;
        nym.localActiveFlair = data.activeFlair;
        localStorage.setItem('nym_active_flair', data.activeFlair);
    }

    if (data.activeCosmetics !== undefined) {
        nym.activeCosmetics = new Set(Array.isArray(data.activeCosmetics) ? data.activeCosmetics : []);
    }

    if (data.supporterActive !== undefined) {
        nym.supporterBadgeActive = data.supporterActive;
        localStorage.setItem('nym_supporter_active', data.supporterActive ? 'true' : 'false');
    }

    // Restore recovery codes from relay data
    if (data.recoveryCodes && typeof data.recoveryCodes === 'object') {
        Object.entries(data.recoveryCodes).forEach(([code, payload]) => {
            const key = 'nym_shop_recovery_' + code;
            if (!localStorage.getItem(key)) {
                try {
                    localStorage.setItem(key, JSON.stringify(payload));
                } catch (_) { }
            }
        });
    }

    // Cache locally
    nym._cachePurchases();

    // If we merged new local purchases, push the combined set back to relays
    if (hasNewLocal) {
        nym.savePurchaseToNostr();
    }

    // Apply to messages and broadcast
    nym.publishActiveShopItems();
    nym.applyShopStylesToOwnMessages();

    // Refresh the shop UI if it's currently open
    if (document.getElementById('shopModal').classList.contains('active') && nym.activeShopTab) {
        nym.switchShopTab(nym.activeShopTab);
    }

    if (nym.userPurchases.size > 0) {
        nym.displaySystemMessage('Shop purchases synced from Nostr relays.');
    }
}

// Push local ephemeral purchases to Nostr relays when no relay data exists
function applyLocalPurchasesToNostr(localCache) {
    if (!localCache || !localCache.purchases || localCache.purchases.length === 0) return;

    // Restore from local cache
    localCache.purchases.forEach(([id, purchase]) => {
        nym.userPurchases.set(id, purchase);
    });

    if (localCache.activeStyle) {
        nym.activeMessageStyle = localCache.activeStyle;
        nym.localActiveStyle = localCache.activeStyle;
        localStorage.setItem('nym_active_style', localCache.activeStyle);
    }

    if (localCache.activeFlair) {
        nym.activeFlair = localCache.activeFlair;
        nym.localActiveFlair = localCache.activeFlair;
        localStorage.setItem('nym_active_flair', localCache.activeFlair);
    }

    if (localCache.activeCosmetics) {
        nym.activeCosmetics = new Set(localCache.activeCosmetics);
    }

    // Cache and push to relays under the Nostr login pubkey
    nym._cachePurchases();
    nym.savePurchaseToNostr();
    nym.publishActiveShopItems();
    nym.applyShopStylesToOwnMessages();
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
        '#d': ['nymchat-settings'],
        limit: 1
    };

    // Pool mode: send REQ through the multiplexed pool workers
    if (nym.useRelayProxy && nym._isAnyPoolOpen()) {
        const handler = (evt) => {
            try {
                const msg = JSON.parse(evt.data);
                if (msg[0] === 'EVENT' && msg[1] === subId && msg[2]) {
                    nym.handleGiftWrapDM(msg[2]).catch(() => { });
                }
                if (msg[0] === 'EOSE' && msg[1] === subId) {
                    nym._poolRemoveMessageListener(handler);
                    try { nym._poolSend(['CLOSE', subId]); } catch (_) { }
                }
            } catch (_) { }
        };
        nym._poolAddMessageListener(handler);
        nym._poolSend(['REQ', subId, filter]);

        // Cleanup after 10s
        setTimeout(() => {
            nym._poolRemoveMessageListener(handler);
            try { nym._poolSend(['CLOSE', subId]); } catch (_) { }
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
                    nym.handleGiftWrapDM(msg[2]).catch(() => { });
                }
                if (msg[0] === 'EOSE' && msg[1] === subId) {
                    relay.ws.removeEventListener('message', handler);
                    try { relay.ws.send(JSON.stringify(['CLOSE', subId])); } catch (_) { }
                }
            } catch (_) { }
        };
        relay.ws.addEventListener('message', handler);
        relay.ws.send(JSON.stringify(['REQ', subId, filter]));

        // Cleanup after 10s
        setTimeout(() => {
            relay.ws.removeEventListener('message', handler);
            try { relay.ws.send(JSON.stringify(['CLOSE', subId])); } catch (_) { }
        }, 10000);
    });
}

async function applyNostrSettingsAdditive(s) {
    if (!s || typeof s !== 'object') return;

    // Group conversations — additive: only add groups we don't already know about
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
                        author: nym.getNymFromPubkey(m.pubkey) || 'anon',
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
                merged.sort((a, b) => {
                    const dt = (a.created_at || 0) - (b.created_at || 0);
                    if (dt !== 0) return dt;
                    return (a._seq || 0) - (b._seq || 0);
                });
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

    // Read receipts
    if (typeof s.readReceiptsEnabled === 'boolean') {
        nym.settings.readReceiptsEnabled = s.readReceiptsEnabled;
        localStorage.setItem('nym_read_receipts_enabled', String(s.readReceiptsEnabled));
    }

    // Typing indicators
    if (typeof s.typingIndicatorsEnabled === 'boolean') {
        nym.settings.typingIndicatorsEnabled = s.typingIndicatorsEnabled;
        localStorage.setItem('nym_typing_indicators_enabled', String(s.typingIndicatorsEnabled));
    }

    // Nick style
    if (s.nickStyle) {
        nym.settings.nickStyle = s.nickStyle;
        localStorage.setItem('nym_nick_style', s.nickStyle);
    }

    // Wallpaper
    if (s.wallpaperType) {
        localStorage.setItem('nym_wallpaper_type', s.wallpaperType);
        if (typeof selectWallpaper === 'function') {
            selectWallpaper(s.wallpaperType);
        }
    }
    if (s.wallpaperCustomUrl) {
        localStorage.setItem('nym_wallpaper_custom_url', s.wallpaperCustomUrl);
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
        nym.pinnedLandingChannel = s.pinnedLandingChannel;
        nym.settings.pinnedLandingChannel = s.pinnedLandingChannel;
        localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(s.pinnedLandingChannel));
    }

    // Text size
    if (typeof s.textSize === 'number' && s.textSize >= 12 && s.textSize <= 28) {
        nym.settings.textSize = s.textSize;
        localStorage.setItem('nym_text_size', String(s.textSize));
        document.documentElement.style.setProperty('--user-text-size', s.textSize + 'px');
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
        s.userJoinedChannels.forEach(key => {
            nym.userJoinedChannels.add(key);
            if (!nym.channels.has(key)) {
                nym.addChannel(key, key);
            }
        });

        localStorage.setItem('nym_user_joined_channels', JSON.stringify(s.userJoinedChannels));
        localStorage.setItem('nym_user_channels', JSON.stringify(
            s.userJoinedChannels.map(key => ({
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
    }

    // Accept PMs setting
    if (s.acceptPMs) {
        nym.settings.acceptPMs = s.acceptPMs;
        localStorage.setItem('nym_accept_pms', s.acceptPMs);
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
    }

    // Closed PMs — merge with local set so deletions aren't lost by stale relay data
    if (Array.isArray(s.closedPMs)) {
        for (const pk of s.closedPMs) nym.closedPMs.add(pk);
        localStorage.setItem('nym_closed_pms', JSON.stringify([...nym.closedPMs]));
    }

    // Left groups — merge with local set so leaves aren't lost by stale relay data
    if (Array.isArray(s.leftGroups)) {
        for (const gid of s.leftGroups) nym.leftGroups.add(gid);
        nym._saveLeftGroups();
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
                        author: nym.getNymFromPubkey(m.pubkey) || 'anon',
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
                merged.sort((a, b) => {
                    const dt = (a.created_at || 0) - (b.created_at || 0);
                    if (dt !== 0) return dt;
                    return (a._seq || 0) - (b._seq || 0);
                });
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
function signOut() {
    if (confirm('Sign out and disconnect from Nymchat?')) {
        // Clear auto-ephemeral preferences on logout
        localStorage.removeItem('nym_auto_ephemeral');
        localStorage.removeItem('nym_auto_ephemeral_nick');
        localStorage.removeItem('nym_auto_ephemeral_channel');
        localStorage.removeItem('nym_session_nsec');
        localStorage.removeItem('nym_random_keypair_per_session');
        localStorage.removeItem('nym_dev_nsec');
        localStorage.removeItem('nym_color_mode');
        localStorage.removeItem('nym_purchases_cache');
        localStorage.removeItem('nym_active_style');
        localStorage.removeItem('nym_active_flair');
        // Clear Nostr login state
        localStorage.removeItem('nym_nostr_login_method');
        localStorage.removeItem('nym_nostr_login_pubkey');
        localStorage.removeItem('nym_nostr_login_nsec');
        localStorage.removeItem('nym_nostr_login_npub');
        localStorage.removeItem('nym_bio');
        localStorage.removeItem('nym_lightning_address_global');
        localStorage.removeItem('nym_avatar_url');
        localStorage.removeItem('nym_banner_url');
        nym.cmdQuit();
    }
}

// Initialize on load
document.addEventListener('DOMContentLoaded', async () => {
    // Construct the NYM instance now that all module scripts have been parsed
    // and their methods have been attached to NYM.prototype.
    nym = new NYM();

    // Parse URL for channel routing BEFORE initialization
    parseUrlChannel();

    await nym.initialize();

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
            // Skip current channel
            if (channel === currentKey) return;

            // Prune inactive channels to the tier-aware channel limit so
            // low-tier devices recover memory faster.
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
    const scrollToBottomBtn = document.getElementById('scrollToBottomBtn');
    if (messagesContainer && scrollToBottomBtn) {
        messagesContainer.addEventListener('scroll', () => {
            const distanceFromBottom = messagesContainer.scrollHeight - messagesContainer.scrollTop - messagesContainer.clientHeight;

            // When scrolled to the very top, load older messages or show history limit
            if (messagesContainer.scrollTop <= 5) {
                if (nym.inPMMode) {
                    // PM/group pagination: load older messages on scroll-to-top
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
                        }
                    }
                } else {
                    // Channel mode: show history limit notice
                    const storageKey = nym.currentGeohash ? `#${nym.currentGeohash}` : nym.currentChannel;
                    const channelMessages = nym.messages.get(storageKey) || [];
                    if (channelMessages.length >= nym.channelMessageLimit && !messagesContainer.querySelector('.channel-history-limit')) {
                        const notice = document.createElement('div');
                        notice.className = 'system-message channel-history-limit';
                        notice.textContent = 'You\'ve reached the edge of this channel\'s history. Older messages are lost to the void \u2014 only the latest 100 messages are shown.';
                        messagesContainer.insertBefore(notice, messagesContainer.firstChild);
                    }
                }
            }

            // Track whether user has intentionally scrolled away from the bottom
            if (distanceFromBottom > 150) {
                nym.userScrolledUp = true;
            } else {
                nym.userScrolledUp = false;
            }

            // Show/hide scroll-to-bottom button
            if (distanceFromBottom > 150) {
                scrollToBottomBtn.classList.add('visible');
            } else {
                scrollToBottomBtn.classList.remove('visible');
            }
        }, { passive: true });
    }

    // Auto-scroll to bottom when input is focused on mobile (only if near bottom)
    if (messageInput && messagesContainer) {
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
    modal.classList.add('active');
    startRelayStatsLoop();
}

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

let _rsInterval = null;

function startRelayStatsLoop() {
    stopRelayStatsLoop();

    // Reset accumulated events counter so first sample isn't a huge spike
    if (typeof nym !== 'undefined') {
        nym.relayStats.eventsThisSecond = 0;
    }

    // Throughput sampling: once per second, push eventsThisSecond into history
    _rsInterval = setInterval(() => {
        if (typeof nym === 'undefined') return;
        const s = nym.relayStats;
        s.throughputHistory.push(s.eventsThisSecond);
        if (s.throughputHistory.length > 60) s.throughputHistory.shift();
        s.eventsThisSecond = 0;

        // Render on each data update instead of every animation frame
        renderRelayStats();
    }, 1000);

    // Initial render
    renderRelayStats();
}

function stopRelayStatsLoop() {
    if (_rsInterval) { clearInterval(_rsInterval); _rsInterval = null; }
}

function formatBytes(b) {
    if (b < 1024) return b + ' B';
    if (b < 1048576) return (b / 1024).toFixed(1) + ' KB';
    if (b < 1073741824) return (b / 1048576).toFixed(1) + ' MB';
    return (b / 1073741824).toFixed(2) + ' GB';
}

function renderRelayStats() {
    if (typeof nym === 'undefined') return;
    const s = nym.relayStats;
    const pool = nym.relayPool;

    // Count connected — pool mode uses poolConnectedRelays count
    let connected = 0;
    if (nym.useRelayProxy && nym._isAnyPoolOpen()) {
        connected = nym.poolConnectedRelays.length;
    } else {
        pool.forEach((relay) => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN) connected++;
        });
    }

    // Average latency
    let latSum = 0, latCount = 0;
    s.latencyPerRelay.forEach((ms, url) => {
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

    // Build sorted relay entries (no type labels - all relays are read/write)
    const entries = [];

    if (typeof nym !== 'undefined' && nym.useRelayProxy && nym._isAnyPoolOpen()) {
        // Pool mode: only show actually connected relays
        const connectedSet = new Set(nym.poolConnectedRelays);
        connectedSet.forEach(url => {
            if (url === 'relay-pool') return;
            entries.push({
                url,
                write: url === 'wss://sendit.nosflare.com',
                open: true,
                events: stats.eventsPerRelay.get(url) || 0,
                latency: stats.latencyPerRelay.get(url) || null
            });
        });
    } else {
        pool.forEach((relay, url) => {
            const isOpen = relay.ws && relay.ws.readyState === WebSocket.OPEN;
            entries.push({
                url,
                write: relay.type === 'write',
                open: isOpen,
                events: stats.eventsPerRelay.get(url) || 0,
                latency: stats.latencyPerRelay.get(url) || null
            });
        });
    }

    // Sort: connected first, then by events descending
    entries.sort((a, b) => {
        if (a.open !== b.open) return a.open ? -1 : 1;
        return b.events - a.events;
    });

    if (entries.length === 0) {
        listEl.innerHTML = '<div style="padding: 16px; text-align: center; color: var(--text-dim); font-size: 12px;">No relays connected</div>';
        return;
    }

    // Only rebuild DOM if count changed; otherwise update in-place for performance
    const existing = listEl.querySelectorAll('.relay-stats-row');
    if (existing.length !== entries.length) {
        let html = '';
        entries.forEach((e, i) => {
            const shortUrl = e.url.replace('wss://', '').replace('ws://', '');
            html += `<div class="relay-stats-row" data-rs-idx="${i}">` +
                `<span class="relay-stats-dot ${e.open ? 'open' : 'closed'}"></span>` +
                `<span class="relay-stats-url" title="${nym.escapeHtml(e.url)}">${nym.escapeHtml(shortUrl)}</span>` +
                (e.write ? `<span class="relay-stats-type write">write</span>` : '') +
                `<span class="relay-stats-latency">${e.latency !== null ? e.latency + 'ms' : '--'}</span>` +
                `<span class="relay-stats-events">${e.events} evt</span>` +
                `</div>`;
        });
        listEl.innerHTML = html;
    } else {
        // Update in-place
        entries.forEach((e, i) => {
            const row = existing[i];
            if (!row) return;
            const dot = row.querySelector('.relay-stats-dot');
            if (dot) { dot.className = `relay-stats-dot ${e.open ? 'open' : 'closed'}`; }
            const evtEl = row.querySelector('.relay-stats-events');
            if (evtEl) evtEl.textContent = e.events + ' evt';
            const latEl = row.querySelector('.relay-stats-latency');
            if (latEl) latEl.textContent = e.latency !== null ? e.latency + 'ms' : '--';
        });
    }
}