// channels.js - Channel switch/add/remove, joined/pinned/hidden channels, navigation history, unread counts
// Methods are attached to NYM.prototype.

Object.assign(NYM.prototype, {

    async handleChannelLink(channelInput, event) {
        if (event) {
            event.preventDefault();
            event.stopPropagation();
        }

        // Strip legacy g: prefix from old shared URLs
        let channelName = channelInput;
        if (channelInput.startsWith('g:')) {
            channelName = channelInput.substring(2);
        }

        // Sanitize channel name
        channelName = this.sanitizeChannelName(channelName);
        if (!channelName) return;

        if (this.isValidGeohash(channelName)) {
            if (!this.channels.has(channelName)) {
                this.addChannel(channelName, channelName);
            }
            this.switchChannel(channelName, channelName);
            this.userJoinedChannels.add(channelName);
            this.saveUserChannels();
        } else if (channelName) {
            // Non-geohash channel
            if (!this.channels.has(channelName)) {
                this.addChannel(channelName, channelName);
            }
            this.switchChannel(channelName, channelName);
            this.userJoinedChannels.add(channelName);
            this.saveUserChannels();
        }
    },

    addGeohashChannelToGlobe(geohash) {
        // Only add valid geohashes to the globe
        if (!this.isValidGeohash(geohash)) return;
        // If globe is active, update it
        if (this.globe && this.globeAnimationActive) {
            this.globe.updatePoints();
        }
    },

    updateGeohashChannels() {
        this.geohashChannels = [];

        // Get all geohash channels from discovered channels and user channels
        const allGeohashes = new Set();

        // From common geohashes
        this.commonGeohashes.forEach(g => allGeohashes.add(g.toLowerCase()));

        // From user's channels (only valid geohashes)
        this.channels.forEach((value, key) => {
            if (value.geohash && this.isValidGeohash(value.geohash)) {
                allGeohashes.add(value.geohash.toLowerCase());
            }
        });

        // From stored messages
        this.messages.forEach((msgs, channel) => {
            if (channel.startsWith('#') && this.isValidGeohash(channel.substring(1))) {
                allGeohashes.add(channel.substring(1).toLowerCase());
            }
        });

        // Convert to array with coordinates
        allGeohashes.forEach(geohash => {
            try {
                const coords = this.decodeGeohash(geohash);
                const messageCount = (this.messages.get(`#${geohash}`) || []).length;
                this.geohashChannels.push({
                    geohash: geohash.toLowerCase(), // Ensure lowercase
                    lat: coords.lat,
                    lng: coords.lng,
                    messages: messageCount,
                    isJoined: this.channels.has(geohash)
                });
            } catch (e) {
            }
        });
    },

    async selectGeohashChannel(channel) {
        this.selectedGeohash = channel.geohash.toLowerCase();

        // Stop auto-rotation when selecting a channel
        if (this.globe && this.globe.controls) {
            this.globe.controls.autoRotate = false;
            this.globe.autoRotate = false;
        }

        const infoPanel = document.getElementById('geohashInfoPanel');
        const infoTitle = document.getElementById('geohashInfoTitle');
        const infoContent = document.getElementById('geohashInfoContent');
        const joinBtn = document.getElementById('geohashJoinBtn');

        infoTitle.textContent = `#${channel.geohash.toLowerCase()}`;

        const distance = this.userLocation ?
            this.calculateDistance(this.userLocation.lat, this.userLocation.lng, channel.lat, channel.lng).toFixed(1) + ' km away' :
            '';

        // Get city and country from reverse geocoding
        let locationInfo = 'Loading location...';
        infoContent.innerHTML = `
<div class="geohash-info-item">
    <strong>Coordinates:</strong> ${channel.lat.toFixed(4)}, ${channel.lng.toFixed(4)}
</div>
<div class="geohash-info-item" id="locationInfoItem">
    <strong>Location:</strong> ${locationInfo}
</div>
${distance ? `<div class="geohash-info-item"><strong>Distance:</strong> ${distance}</div>` : ''}
<div class="geohash-info-item">
    <strong>Messages:</strong> ${channel.messages}
</div>
`;

        // Update join button
        if (channel.isJoined) {
            joinBtn.textContent = 'Go to Channel';
        } else {
            joinBtn.textContent = 'Join Channel';
        }

        // Set up join button with proper handler
        joinBtn.onclick = () => {
            this.joinSelectedGeohash();
        };

        infoPanel.style.display = 'block';

        // Fetch city and country asynchronously
        try {
            const response = await fetch(`https://nominatim.openstreetmap.org/reverse?format=json&lat=${channel.lat}&lon=${channel.lng}&zoom=10`);
            const data = await response.json();

            const city = data.address.city || data.address.town || data.address.village || data.address.county || '';
            const country = data.address.country || '';

            locationInfo = [city, country].filter(x => x).join(', ') || 'Unknown location';

            // Update the location info element
            const locationInfoItem = document.getElementById('locationInfoItem');
            if (locationInfoItem) {
                locationInfoItem.innerHTML = `<strong>Location:</strong> ${this.escapeHtml(locationInfo)}`;
            }
        } catch (error) {
            const locationInfoItem = document.getElementById('locationInfoItem');
            if (locationInfoItem) {
                locationInfoItem.innerHTML = `<strong>Location:</strong> Unknown`;
            }
        }

    },

    shareChannel() {
        // Generate the share URL with geohash channel
        const baseUrl = window.location.origin + window.location.pathname;
        const channel = this.currentChannel || 'nym';
        const shareUrl = `${baseUrl}#${channel}`;

        // Set the URL in the input
        document.getElementById('shareUrlInput').value = shareUrl;

        // Show the modal
        document.getElementById('shareModal').classList.add('active');

        // Auto-select the text
        setTimeout(() => {
            document.getElementById('shareUrlInput').select();
        }, 100);
    },

    copyShareUrl() {
        const input = document.getElementById('shareUrlInput');
        input.select();

        navigator.clipboard.writeText(input.value).then(() => {
            const btn = document.querySelector('.copy-url-btn');
            const originalText = btn.textContent;
            btn.textContent = 'COPIED!';
            btn.classList.add('copied');

            setTimeout(() => {
                btn.textContent = originalText;
                btn.classList.remove('copied');
            }, 2000);
        }).catch(err => {
            this.displaySystemMessage('Failed to copy URL');
        });
    },

    isValidGeohash(str) {
        return this.geohashRegex.test(str.toLowerCase());
    },

    handleChannelSearch(searchTerm) {
        const term = this.sanitizeChannelName(searchTerm.trim());
        const resultsDiv = document.getElementById('channelSearchResults');

        // Filter existing channels
        this.filterChannels(term);

        // Show create/join prompt if search term exists
        if (term.length > 0) {
            const isGeohash = this.isValidGeohash(term);
            const exists = Array.from(this.channels.keys()).some(k => k.toLowerCase() === term);

            // Clear previous results
            resultsDiv.innerHTML = '';

            if (isGeohash && !exists) {
                // Valid geohash — offer to join as geohash channel
                const location = this.getGeohashLocation(term) || 'Unknown location';
                const prompt = document.createElement('div');
                prompt.className = 'search-create-prompt';
                prompt.style.cssText = 'display: flex; justify-content: space-between; align-items: center;';
                prompt.innerHTML = `
        <span>Join geohash channel "${term}" (${location})</span>
    `;
                prompt.onclick = async () => {
                    this.addChannel(term, term);
                    this.switchChannel(term, term);
                    this.userJoinedChannels.add(term);
                    document.getElementById('channelSearch').value = '';
                    resultsDiv.innerHTML = '';
                    this.filterChannels('');
                    this.saveUserChannels();
                };
                resultsDiv.appendChild(prompt);
            } else if (!isGeohash && !exists) {
                // Not a valid geohash — offer to join as non-geohash channel
                const prompt = document.createElement('div');
                prompt.className = 'search-create-prompt';
                prompt.style.cssText = 'display: flex; justify-content: space-between; align-items: center;';
                prompt.innerHTML = `
        <span>Join channel "${term}"</span>
    `;
                prompt.onclick = async () => {
                    this.addChannel(term, term);
                    this.switchChannel(term, term);
                    this.userJoinedChannels.add(term);
                    document.getElementById('channelSearch').value = '';
                    resultsDiv.innerHTML = '';
                    this.filterChannels('');
                    this.saveUserChannels();
                };
                resultsDiv.appendChild(prompt);
            }
        } else {
            resultsDiv.innerHTML = '';
        }
    },

    // Sanitize channel names: allow letters (including international) and digits only.
    // Strips everything else (spaces, URLs, special chars) and lowercases.
    sanitizeChannelName(name) {
        if (!name) return '';
        const lower = name.toLowerCase();
        // Reject names containing any invalid characters instead of stripping them
        if (!/^[\p{L}\p{N}]+$/u.test(lower)) return '';
        return lower;
    },

    // Push a navigation entry onto the history stack.
    _pushNavigation(entry) {
        if (this._navigating) return;
        // Avoid duplicate adjacent entries
        const current = this.navigationHistory[this.navigationIndex];
        if (current && current.type === entry.type) {
            if (entry.type === 'channel' && current.channel === entry.channel && current.geohash === entry.geohash) return;
            if (entry.type === 'pm' && current.pubkey === entry.pubkey) return;
            if (entry.type === 'group' && current.groupId === entry.groupId) return;
        }
        // Truncate any forward history
        this.navigationHistory = this.navigationHistory.slice(0, this.navigationIndex + 1);
        this.navigationHistory.push(entry);
        // Cap at 50 entries
        if (this.navigationHistory.length > 50) {
            this.navigationHistory.shift();
        }
        this.navigationIndex = this.navigationHistory.length - 1;
        // Sync with browser history so mouse back/forward buttons trigger popstate
        try {
            history.pushState({ _nym_nav: this.navigationIndex }, '');
        } catch {
            // Ignore if pushState fails (e.g. sandboxed iframe)
        }
        this._updateNavButtons();
    },

    // Navigate back in history.
    navigateBack() {
        if (this.navigationIndex <= 0) return;
        this.navigationIndex--;
        this._navigateTo(this.navigationHistory[this.navigationIndex]);
        try { history.replaceState({ _nym_nav: this.navigationIndex }, ''); } catch { }
        this._updateNavButtons();
    },

    // Navigate forward in history.
    navigateForward() {
        if (this.navigationIndex >= this.navigationHistory.length - 1) return;
        this.navigationIndex++;
        this._navigateTo(this.navigationHistory[this.navigationIndex]);
        try { history.replaceState({ _nym_nav: this.navigationIndex }, ''); } catch { }
        this._updateNavButtons();
    },

    // Navigate to a specific history entry without recording it.
    _navigateTo(entry) {
        this._navigating = true;
        try {
            if (entry.type === 'channel') {
                this.switchChannel(entry.channel, entry.geohash);
            } else if (entry.type === 'pm') {
                this.openUserPM(entry.nym, entry.pubkey);
            } else if (entry.type === 'group') {
                this.openGroup(entry.groupId);
            }
        } finally {
            this._navigating = false;
        }
    },

    // Update the enabled/disabled state of the back/forward buttons.
    _updateNavButtons() {
        const backBtn = document.getElementById('channelBackBtn');
        const fwdBtn = document.getElementById('channelForwardBtn');
        if (backBtn) backBtn.disabled = this.navigationIndex <= 0;
        if (fwdBtn) fwdBtn.disabled = this.navigationIndex >= this.navigationHistory.length - 1;
    },

    discoverChannels() {
        // Skip channel discovery in group chat & PM only mode
        if (this.settings.groupChatPMOnlyMode) return;

        // Create a mixed array of geohash channels
        const allChannels = [];

        // Add all geohash channels
        this.commonGeohashes.forEach(geohash => {
            // Don't re-add if already exists or if user-joined
            if (!this.channels.has(geohash) && !this.userJoinedChannels.has(geohash)) {
                allChannels.push({
                    name: geohash,
                    geohash: geohash,
                    type: 'geo',
                    sortKey: Math.random()
                });
            }
        });

        // Sort randomly to mix standard and geo channels
        allChannels.sort((a, b) => a.sortKey - b.sortKey);

        // Add channels to UI in mixed order
        allChannels.forEach(channel => {
            this.addChannel(channel.name, channel.geohash);
        });
    },

    rerenderCurrentView() {
        const container = document.getElementById('messagesContainer');
        if (!container) return;

        if (this.inPMMode) {
            const conversationKey = this.currentGroup
                ? this.getGroupConversationKey(this.currentGroup)
                : this.currentPM;
            if (conversationKey) {
                this.renderMessagesWithVirtualScroll(container, conversationKey, false, true);
            }
        } else {
            const storageKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
            if (storageKey) {
                this.renderMessagesWithVirtualScroll(container, storageKey, false);
            }
        }
    },

    filterChannels(searchTerm) {
        const items = document.querySelectorAll('.channel-item');
        const term = searchTerm.toLowerCase();
        const list = document.getElementById('channelList');

        // Update wrapper has-value class for clear button visibility
        const wrapper = document.getElementById('channelSearchWrapper');
        if (wrapper) {
            wrapper.classList.toggle('has-value', term.length > 0);
        }

        const validChannelPattern = /^#[\p{L}\p{N}]+$/u;
        items.forEach(item => {
            const channelNameEl = item.querySelector('.channel-name');
            const channelName = channelNameEl ? channelNameEl.textContent.toLowerCase() : '';
            // Hide channels with invalid names (spaces, special chars, URLs)
            if (!validChannelPattern.test(channelName)) {
                item.style.display = 'none';
                item.classList.add('search-hidden');
            } else if (term.length === 0 || channelName.includes(term)) {
                item.style.display = 'flex';
                item.classList.remove('search-hidden');
            } else {
                item.style.display = 'none';
                item.classList.add('search-hidden');
            }
        });

        // Hide view more button during search
        const viewMoreBtn = list.querySelector('.view-more-btn');
        if (viewMoreBtn) {
            viewMoreBtn.style.display = term ? 'none' : 'block';
        }
    },

    filterUsers(searchTerm) {
        this.userSearchTerm = searchTerm;
        this.updateUserList();

        // Update wrapper has-value class for clear button visibility
        const wrapper = document.getElementById('userSearchWrapper');
        if (wrapper) {
            wrapper.classList.toggle('has-value', searchTerm.length > 0);
        }

        const list = document.getElementById('userListContent');

        // Hide view more button during search
        const viewMoreBtn = list.querySelector('.view-more-btn');
        if (viewMoreBtn) {
            viewMoreBtn.style.display = searchTerm ? 'none' : 'block';
        }
    },

    togglePin(channel, geohash) {
        // Don't allow pinning/unpinning #nym since it's always at top
        if (geohash === 'nym') {
            this.displaySystemMessage('#nym is always at the top');
            return;
        }

        const key = geohash || channel;

        // Toggle pin status
        if (this.pinnedChannels.has(key)) {
            this.pinnedChannels.delete(key);
        } else {
            this.pinnedChannels.add(key);
        }

        this.savePinnedChannels();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.updateChannelPins();
    },

    updateChannelPins() {
        document.querySelectorAll('.channel-item').forEach(item => {
            let key;

            const channel = item.dataset.channel;
            const geohash = item.dataset.geohash;
            key = geohash || channel;

            const pinBtn = item.querySelector('.pin-btn');

            if (this.pinnedChannels.has(key)) {
                item.classList.add('pinned');
                if (pinBtn) pinBtn.classList.add('pinned');
            } else {
                item.classList.remove('pinned');
                if (pinBtn) pinBtn.classList.remove('pinned');
            }
        });
    },

    savePinnedChannels() {
        localStorage.setItem('nym_pinned_channels', JSON.stringify(Array.from(this.pinnedChannels)));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    loadPinnedChannels() {
        const saved = localStorage.getItem('nym_pinned_channels');
        if (saved) {
            try {
                this.pinnedChannels = new Set(JSON.parse(saved));
            } catch (_) {
                this.pinnedChannels = new Set();
            }
            this._scheduleIdle(() => this.updateChannelPins());
        }
    },

    toggleHideChannel(channel, geohash) {
        if (geohash === 'nym') {
            this.displaySystemMessage('#nym cannot be hidden');
            return;
        }

        const key = geohash || channel;

        if (this.hiddenChannels.has(key)) {
            this.hiddenChannels.delete(key);
        } else {
            this.hiddenChannels.add(key);
        }

        this.saveHiddenChannels();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.applyHiddenChannels();
    },

    applyHiddenChannels() {
        document.querySelectorAll('.channel-item').forEach(item => {
            const channel = item.dataset.channel;
            const geohash = item.dataset.geohash;
            const key = geohash || channel;

            // Don't override search filter visibility
            if (item.classList.contains('search-hidden')) {
                return;
            }

            // Never hide #nym or the active channel
            if (geohash === 'nym' || item.classList.contains('active')) {
                item.style.display = '';
                return;
            }

            // Hide if explicitly hidden
            if (this.hiddenChannels.has(key)) {
                item.style.display = 'none';
                return;
            }

            // Hide if "hide non-pinned" is on and channel is not pinned
            if (this.hideNonPinned && !this.pinnedChannels.has(key)) {
                item.style.display = 'none';
                return;
            }

            item.style.display = '';
        });
    },

    saveHiddenChannels() {
        localStorage.setItem('nym_hidden_channels', JSON.stringify(Array.from(this.hiddenChannels)));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    loadHiddenChannels() {
        const saved = localStorage.getItem('nym_hidden_channels');
        if (saved) {
            try {
                this.hiddenChannels = new Set(JSON.parse(saved));
            } catch (_) {
                this.hiddenChannels = new Set();
            }
        }
        const hideNonPinned = localStorage.getItem('nym_hide_non_pinned');
        this.hideNonPinned = hideNonPinned === 'true';
        this._scheduleIdle(() => this.applyHiddenChannels());
    },

    loadBlockedChannels() {
        const saved = localStorage.getItem('nym_blocked_channels');
        if (saved) {
            this.blockedChannels = new Set(JSON.parse(saved));
        }
    },

    saveBlockedChannels() {
        localStorage.setItem('nym_blocked_channels', JSON.stringify(Array.from(this.blockedChannels)));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    isChannelBlocked(channel, geohash) {
        const key = geohash || channel;
        return this.blockedChannels.has(key);
    },

    blockChannel(channel, geohash) {
        const key = geohash || channel;
        this.blockedChannels.add(key);
        this.saveBlockedChannels();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();

        // Remove from DOM immediately
        const selector = geohash ?
            `[data-geohash="${geohash}"]` :
            `[data-channel="${channel}"][data-geohash=""]`;
        const element = document.querySelector(selector);
        if (element) {
            element.remove();
        }

        // Remove from channels map
        this.channels.delete(key);

        // If currently in this channel, switch to #nym
        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('nym', 'nym');
        }

        // Update view more button after removing
        this.updateViewMoreButton('channelList');
    },

    unblockChannel(channel, geohash) {
        const key = geohash || channel;
        this.blockedChannels.delete(key);
        this.saveBlockedChannels();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();

        // Re-add the channel to the sidebar
        if (geohash) {
            this.addChannel(geohash, geohash);
        } else {
            this.addChannel(channel, '');
        }

        // Update view more button after adding
        this.updateViewMoreButton('channelList');
    },

    updateBlockedChannelsList() {
        const container = document.getElementById('blockedChannelsList');
        if (!container) return;

        if (this.blockedChannels.size === 0) {
            container.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No blocked channels</div>';
        } else {
            container.innerHTML = Array.from(this.blockedChannels).map(key => {
                const displayName = this.isValidGeohash(key) ? `#${key} [GEO]` : `#${key} [EPH]`;
                return `
        <div class="blocked-item">
            <span>${this.escapeHtml(displayName)}</span>
            <button class="unblock-btn" onclick="nym.unblockChannelFromSettings('${this.escapeHtml(key)}')">Unblock</button>
        </div>
    `;
            }).join('');
        }
    },

    unblockChannelFromSettings(key) {
        if (this.isValidGeohash(key)) {
            this.unblockChannel(key, key);
        } else {
            this.unblockChannel(key, '');
        }
        this.updateBlockedChannelsList();
    },

    updateHiddenChannelsList() {
        const container = document.getElementById('hiddenChannelsList');
        if (!container) return;

        if (this.hiddenChannels.size === 0) {
            container.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No hidden channels</div>';
        } else {
            container.innerHTML = Array.from(this.hiddenChannels).map(key => {
                const displayName = `#${key}`;
                const location = this.getGeohashLocation(key);
                const label = location ? `${this.escapeHtml(displayName)} (${this.escapeHtml(location)})` : this.escapeHtml(displayName);
                return `
        <div class="blocked-item">
            <span>${label}</span>
            <button class="unblock-btn" onclick="nym.unhideChannelFromSettings('${this.escapeHtml(key)}')">Unhide</button>
        </div>
    `;
            }).join('');
        }
    },

    unhideChannelFromSettings(key) {
        this.hiddenChannels.delete(key);
        this.saveHiddenChannels();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.applyHiddenChannels();
        this.updateHiddenChannelsList();
    },

    switchChannel(channel, geohash = '') {
        // Store previous state
        const previousChannel = this.currentChannel;
        const previousGeohash = this.currentGeohash;

        // Check if we're actually switching to a different channel
        const isSameChannel = !this.inPMMode &&
            channel === previousChannel &&
            geohash === previousGeohash;

        if (isSameChannel) {
            // Check if the DOM is out of sync with the message store
            // (e.g. too many messages arrived and virtual scroll state is stale)
            const container = document.getElementById('messagesContainer');
            const storageKey = geohash ? `#${geohash}` : channel;
            const storedCount = (this.messages.get(storageKey) || []).length;
            const domCount = container ? container.querySelectorAll('.message[data-message-id]').length : 0;

            // If there are stored messages but none in the DOM, force a re-render
            if (storedCount > 0 && domCount === 0) {
                // Clear lastChannel so loadChannelMessages won't skip
                if (container) container.dataset.lastChannel = '';
                // Fall through to full channel load below
            } else {
                // Still ensure the sidebar active state is correct (for initialization)
                document.querySelectorAll('.channel-item').forEach(item => {
                    const isActive = item.dataset.channel === channel &&
                        item.dataset.geohash === geohash;
                    item.classList.toggle('active', isActive);
                });
                return; // Don't reload the same channel
            }
        }

        this.inPMMode = false;
        this.currentPM = null;
        this.currentChannel = channel;
        this.currentGeohash = geohash;
        this.userScrolledUp = false;
        this.clearQuoteReply();
        if (this.pendingEdit) this.cancelEditMessage();

        // Track navigation history
        this._pushNavigation({ type: 'channel', channel, geohash });

        // Hide typing indicator when leaving PM mode
        this.renderTypingIndicator();

        // Handle geo-relay connections for Bitchat compatibility
        // Clean up previous geo relays if switching away from a geohash channel
        if (previousGeohash && previousGeohash !== geohash) {
            this.cleanupGeoRelays(previousGeohash);
        }

        // Connect to nearby relays for geohash channels (async, non-blocking)
        // connectToGeoRelays handles its own subscription internally after
        // geo relays are configured. The proxy buffers GEO_EVENTs for relays
        // still connecting, so no need to block the channel switch.
        if (geohash) {
            this.connectToGeoRelays(geohash);
        }

        // Always ensure default relays (first 5 broadcast) stay connected
        this.ensureDefaultRelaysConnected();

        // Load channel messages from relays (immediate, uses whatever relays are connected)
        const channelType = (geohash && this.isValidGeohash(geohash)) ? 'geohash' : 'ephemeral';
        const channelKey = geohash || channel;
        this.loadChannelFromRelays(channelKey, channelType);

        // Show share button in channel mode
        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) {
            shareBtn.style.display = 'block';
        }

        const isGeo = geohash && this.isValidGeohash(geohash);
        const displayName = geohash ? `#${this.escapeHtml(geohash)}` : `#${this.escapeHtml(channel)}`;
        let fullTitle = displayName;

        // Add channel type label
        if (isGeo) {
            // Valid geohash channel - add location info and label
            const location = this.getGeohashLocation(geohash);

            if (location) {
                const safeLocation = this.escapeHtml(location);
                const encodedLocation = encodeURIComponent(location);
                fullTitle = `${displayName} <span style="font-size: 12px; color: var(--text-dim);">(Geohash)</span><br/><font size="2" style="color: var(--text-dim);text-shadow:none;"><a style="color: var(--text-dim);text-shadow:none;" href="https://www.openstreetmap.org/search?query=${encodedLocation}&zoom=5&minlon=-138.55957031250003&minlat=11.953349393643416&maxlon=-97.69042968750001&maxlat=55.25407706707272#map=5/47.81/5.63" target="_blank" rel="noopener">${safeLocation}</a></font>`;

                if (this.userLocation && this.settings.sortByProximity) {
                    try {
                        const coords = this.decodeGeohash(geohash);
                        const distance = this.calculateDistance(
                            this.userLocation.lat, this.userLocation.lng,
                            coords.lat, coords.lng
                        );
                        fullTitle = `${displayName} <span style="font-size: 12px; color: var(--text-dim);">(Geohash)</span><br/><font size="2" style="color: var(--text-dim);text-shadow:none;"><a style="color: var(--text-dim);text-shadow:none;" href="https://www.openstreetmap.org/search?query=${encodedLocation}&zoom=5&minlon=-138.55957031250003&minlat=11.953349393643416&maxlon=-97.69042968750001&maxlat=55.25407706707272#map=5/47.81/5.63" target="_blank" rel="noopener">${safeLocation}</a> (${distance.toFixed(1)}km)</font>`;
                    } catch (e) {
                    }
                }
            } else {
                // No location info available, just add label
                fullTitle = `${displayName} <span style="font-size: 12px; color: var(--text-dim);">(Geohash)</span>`;
            }
        } else if (geohash) {
            // Non-geohash channel (g tag with non-geohash name)
            fullTitle = `${displayName} <span style="font-size: 12px; color: var(--text-dim);">(Non-Geohash)</span>`;
        } else {
            // Standard ephemeral channel
            fullTitle = `${displayName} <span style="font-size: 12px; color: var(--text-dim);">(Ephemeral)</span>`;
        }

        document.getElementById('currentChannel').innerHTML = fullTitle;

        // Ensure channel exists in sidebar before updating active state
        if (!document.querySelector(`[data-channel="${channel}"][data-geohash="${geohash}"]`)) {
            this.addChannel(channel, geohash);
        }

        // Update active state
        document.querySelectorAll('.channel-item').forEach(item => {
            const isActive = item.dataset.channel === channel &&
                item.dataset.geohash === geohash;
            item.classList.toggle('active', isActive);
        });

        document.querySelectorAll('.pm-item').forEach(item => {
            item.classList.remove('active');
        });

        // Clear unread count
        const unreadKey = geohash ? `#${geohash}` : channel;
        this.clearUnreadCount(unreadKey);

        // Load channel messages - loadChannelMessages has its own dedup check
        // via container.dataset.lastChannel, so always call it to handle
        // switching back from PM mode to the same channel correctly
        this.loadChannelMessages(displayName);

        // Update user list for this channel
        this.updateUserList();

        // Track current channel for auto-ephemeral session resume
        if (localStorage.getItem('nym_auto_ephemeral') === 'true') {
            localStorage.setItem('nym_auto_ephemeral_channel', JSON.stringify({
                channel: channel,
                geohash: geohash
            }));
        }

        // Close mobile sidebar on mobile
        if (window.innerWidth <= 768) {
            this.closeSidebar();
        }
    },

    addChannel(channel, geohash = '') {
        const list = document.getElementById('channelList');
        const key = geohash || channel;

        // Reject invalid channel names (must be letters and digits only)
        if (key && !/^[\p{L}\p{N}]+$/u.test(key)) {
            return;
        }

        // Don't add blocked channels
        if (this.isChannelBlocked(channel, geohash)) {
            return;
        }

        if (!document.querySelector(`[data-channel="${channel}"][data-geohash="${geohash}"]`)) {
            const item = document.createElement('div');
            item.className = 'channel-item list-item';
            item.dataset.channel = channel;
            item.dataset.geohash = geohash;

            // Check if this is the current active channel
            const isCurrentChannel = !this.inPMMode &&
                this.currentChannel === channel &&
                (this.currentGeohash || '') === geohash;
            if (isCurrentChannel) {
                item.classList.add('active');
            }

            const isGeo = geohash && this.isValidGeohash(geohash);
            const displayName = geohash ? `#${this.escapeHtml(geohash)}` : `#${this.escapeHtml(channel)}`;

            // Get location information for geohash channels
            let locationHint = '';
            if (isGeo) {
                const location = this.getGeohashLocation(geohash);
                if (location) {
                    locationHint = ` title="${this.escapeHtml(location)}"`;
                }
            }

            const isPinned = this.pinnedChannels.has(key);
            if (isPinned) {
                item.classList.add('pinned');
            }

            const safeChannel = this.escapeHtml(channel);
            const safeGeohash = this.escapeHtml(geohash);

            const pinButton = `
    <span class="pin-btn ${isPinned ? 'pinned' : ''}" data-channel="${safeChannel}" data-geohash="${safeGeohash}">
        <svg viewBox="0 0 24 24">
            <path d="M16,12V4H17V2H7V4H8V12L6,14V16H11.2V22H12.8V16H18V14L16,12Z"/>
        </svg>
    </span>
`;

            const hideButton = `
    <span class="hide-btn" data-channel="${safeChannel}" data-geohash="${safeGeohash}" title="Hide channel">
        <svg viewBox="0 0 24 24">
            <path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46A11.8 11.8 0 0 0 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/>
        </svg>
    </span>
`;

            item.innerHTML = `
    <span class="channel-name"${locationHint}>${displayName}</span>
    <div class="channel-badges">
        ${hideButton}
        ${pinButton}
        <span class="unread-badge" style="display:none">0</span>
    </div>
`;

            // Add pin button handler
            const pinBtn = item.querySelector('.pin-btn');
            if (pinBtn) {
                pinBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    e.preventDefault();
                    this.togglePin(channel, geohash);
                });
            }

            // Add hide button handler
            const hideBtn = item.querySelector('.hide-btn');
            if (hideBtn) {
                hideBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    e.preventDefault();
                    this.toggleHideChannel(channel, geohash);
                });
            }

            // Insert before the view more button if it exists
            const viewMoreBtn = list.querySelector('.view-more-btn');
            if (viewMoreBtn) {
                list.insertBefore(item, viewMoreBtn);
            } else {
                list.appendChild(item);
            }

            this.channels.set(key, { channel, geohash });
            this.updateChannelPins();
            this.applyHiddenChannels();

            // Hide new channel if it doesn't match active search filter
            const searchInput = document.getElementById('channelSearch');
            if (searchInput && searchInput.value.trim().length > 0) {
                const term = searchInput.value.toLowerCase();
                const channelNameEl = item.querySelector('.channel-name');
                const channelName = channelNameEl ? channelNameEl.textContent.toLowerCase() : '';
                if (!channelName.includes(term)) {
                    item.style.display = 'none';
                    item.classList.add('search-hidden');
                }
            }

            // Check if we need to add/update view more button
            this.updateViewMoreButton('channelList');
        }
    },

    updateViewMoreButton(listId) {
        const list = document.getElementById(listId);
        if (!list) return;

        // Don't manage view more button if search is active
        const searchWrapper = list.parentElement?.querySelector('.search-input-wrapper');
        const searchInput = searchWrapper?.querySelector('.search-input');
        if (searchInput && searchInput.value.trim().length > 0) {
            // Hide the view-more button during active search
            const existingBtn = list.querySelector('.view-more-btn');
            if (existingBtn) {
                existingBtn.style.display = 'none';
            }
            return;
        }

        const items = list.querySelectorAll('.list-item:not(.search-hidden)');
        let existingBtn = list.querySelector('.view-more-btn');

        // Get current expansion state
        const isExpanded = this.listExpansionStates.get(listId) || false;

        if (items.length > 20) {
            // We need a button
            if (!existingBtn) {
                const btn = document.createElement('div');
                btn.className = 'view-more-btn';
                btn.onclick = () => this.toggleListExpansion(listId);
                list.appendChild(btn);
                existingBtn = btn;
            }

            // Update button text based on state
            if (isExpanded) {
                existingBtn.textContent = 'Show less';
                list.classList.remove('list-collapsed');
                list.classList.add('list-expanded');
            } else {
                existingBtn.textContent = `View ${this.abbreviateNumber(items.length - 20)} more...`;
                list.classList.add('list-collapsed');
                list.classList.remove('list-expanded');
            }

            // Make sure button is visible
            existingBtn.style.display = 'block';
        } else {
            // Don't need a button - remove if exists
            if (existingBtn) {
                existingBtn.remove();
            }
            list.classList.remove('list-collapsed', 'list-expanded');
            // Clear expansion state since button is gone
            this.listExpansionStates.delete(listId);
        }
    },

    toggleListExpansion(listId) {
        const list = document.getElementById(listId);
        if (!list) return;

        let btn = list.querySelector('.view-more-btn');
        const items = list.querySelectorAll('.list-item');

        // Toggle the state
        const currentState = this.listExpansionStates.get(listId) || false;
        const newState = !currentState;
        this.listExpansionStates.set(listId, newState);

        if (newState) {
            // Expanding
            list.classList.remove('list-collapsed');
            list.classList.add('list-expanded');

            // Move button to the end of the list
            if (btn) {
                btn.remove();
                btn = document.createElement('div');
                btn.className = 'view-more-btn';
                btn.textContent = 'Show less';
                btn.onclick = () => this.toggleListExpansion(listId);
                list.appendChild(btn);
            }
        } else {
            // Collapsing
            list.classList.add('list-collapsed');
            list.classList.remove('list-expanded');

            // Move button back to after the 20th item
            if (btn) {
                btn.remove();
                btn = document.createElement('div');
                btn.className = 'view-more-btn';
                btn.textContent = `View ${this.abbreviateNumber(items.length - 20)} more...`;
                btn.onclick = () => this.toggleListExpansion(listId);

                // Insert after the 20th visible item
                if (items.length > 20 && items[19]) {
                    items[19].insertAdjacentElement('afterend', btn);
                } else {
                    list.appendChild(btn);
                }
            }
        }
    },

    removeChannel(channel, geohash = '') {
        const key = geohash || channel;

        // Don't allow removing default channel #nym
        if (key === 'nym') {
            this.displaySystemMessage('Cannot remove the default #nym channel');
            return;
        }

        // Remove from channels map
        this.channels.delete(key);

        // Remove from user-joined set
        this.userJoinedChannels.delete(key);

        // Remove from DOM
        const selector = geohash ?
            `[data-geohash="${geohash}"]` :
            `[data-channel="${channel}"][data-geohash=""]`;
        const element = document.querySelector(selector);
        if (element) {
            element.remove();
        }

        // If we're currently in this channel, switch to #nym
        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('nym', 'nym');
        }

        // Save the updated channel list
        this.saveUserChannels();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();

        this.displaySystemMessage(`Left channel ${geohash ? '#' + geohash : '#' + channel}`);
    },

    saveUserJoinedChannels() {
        const existing = this.loadUserJoinedChannels();
        const combined = new Set([...existing, ...this.userJoinedChannels]);
        localStorage.setItem('nym_user_joined_channels', JSON.stringify(Array.from(combined)));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    loadUserJoinedChannels() {
        const saved = localStorage.getItem('nym_user_joined_channels');
        if (saved) {
            try {
                const channels = JSON.parse(saved);
                // Filter out invalid channel names (legacy data with spaces/special chars/underscores/hyphens)
                return channels.filter(ch => ch && /^[\p{L}\p{N}]+$/u.test(ch));
            } catch (error) {
                return [];
            }
        }
        return [];
    },

    saveUserChannels() {
        const userChannels = [];
        this.channels.forEach((value, key) => {
            if (this.userJoinedChannels.has(key)) {
                userChannels.push({
                    key: key,
                    channel: value.channel,
                    geohash: value.geohash
                });
            }
        });

        // Save the channels
        localStorage.setItem('nym_user_channels', JSON.stringify(userChannels));

        // Also save the joined channels set
        this.saveUserJoinedChannels();
    },

    addChannelToList(channel, geohash) {
        // For geohash channels, ALWAYS use the geohash as the key
        const key = geohash ? geohash : channel;

        // Check if this channel was previously user-joined
        const wasUserJoined = this.userJoinedChannels.has(key);

        // Only add if not already in channels map
        if (geohash) {
            // This is a geohash channel
            if (!this.channels.has(geohash)) {
                this.addChannel(geohash, geohash);
                if (wasUserJoined) {
                    this.userJoinedChannels.add(geohash);
                }
                this.addGeohashChannelToGlobe(geohash);
            }
        } else {
            // This is a standard channel
            if (!this.channels.has(channel)) {
                this.addChannel(channel, '');
                if (wasUserJoined) {
                    this.userJoinedChannels.add(channel);
                }
            }
        }
    },

    updateUnreadCount(channel) {
        const count = (this.unreadCounts.get(channel) || 0) + 1;
        this.unreadCounts.set(channel, count);
        this.channelLastActivity.set(channel, Date.now());

        // Handle PM unread counts using conversation key
        if (channel.startsWith('pm-')) {
            // Extract the other user's pubkey from conversation key
            const keys = channel.substring(3).split('-');
            const otherPubkey = keys.find(k => k !== this.pubkey);
            if (otherPubkey) {
                const badge = document.querySelector(`[data-pubkey="${otherPubkey}"] .unread-badge`);
                if (badge) {
                    badge.textContent = count > 99 ? '99+' : count;
                    badge.style.display = count > 0 ? 'block' : 'none';
                }
            }
        } else if (channel.startsWith('group-')) {
            // Group chat unread counts
            const groupId = channel.substring(6);
            const badge = document.querySelector(`[data-group-id="${groupId}"] .unread-badge`);
            if (badge) {
                badge.textContent = count > 99 ? '99+' : count;
                badge.style.display = count > 0 ? 'block' : 'none';
            }
        } else {
            // Regular channel unread counts
            let selector;
            if (channel.startsWith('#')) {
                // Geohash channel
                selector = `[data-geohash="${channel.substring(1)}"]`;
            } else {
                selector = `[data-channel="${channel}"][data-geohash=""]`;
            }

            const badge = document.querySelector(`${selector} .unread-badge`);
            if (badge) {
                badge.textContent = count > 99 ? '99+' : count;
                badge.style.display = count > 0 ? 'block' : 'none';
            }
        }

        // Re-sort channels by activity (debounced to prevent DOM thrashing
        // that makes channel links unclickable during rapid message bursts)
        if (this._sortDebounceTimer) clearTimeout(this._sortDebounceTimer);
        this._sortDebounceTimer = setTimeout(() => {
            this._sortDebounceTimer = null;
            this.sortChannelsByActivity();
        }, 300);
    },

    sortChannelsByActivity() {
        const channelList = document.getElementById('channelList');
        const channels = Array.from(channelList.querySelectorAll('.channel-item'));

        // Save view more button if it exists
        const viewMoreBtn = channelList.querySelector('.view-more-btn');

        // Store current scroll position
        const scrollTop = channelList.scrollTop;

        channels.sort((a, b) => {
            // #nym is always first
            const aIsDefault = a.dataset.geohash === 'nym';
            const bIsDefault = b.dataset.geohash === 'nym';

            if (aIsDefault) return -1;
            if (bIsDefault) return 1;

            // Active channel is third
            const aIsActive = a.classList.contains('active');
            const bIsActive = b.classList.contains('active');

            if (aIsActive && !bIsActive) return -1;
            if (!aIsActive && bIsActive) return 1;

            // Then sort by pinned status
            const aPinned = a.classList.contains('pinned');
            const bPinned = b.classList.contains('pinned');

            if (aPinned && !bPinned) return -1;
            if (!aPinned && bPinned) return 1;

            // Check if these are valid geohash channels (not just any channel with a geohash field)
            const aIsGeo = !!a.dataset.geohash && a.dataset.geohash !== '' && this.isValidGeohash(a.dataset.geohash);
            const bIsGeo = !!b.dataset.geohash && b.dataset.geohash !== '' && this.isValidGeohash(b.dataset.geohash);

            // If proximity sorting is enabled, sort valid geohash channels by distance
            if (this.settings.sortByProximity && this.userLocation) {
                // If both are valid geohash, sort by distance
                if (aIsGeo && bIsGeo) {
                    try {
                        const coordsA = this.decodeGeohash(a.dataset.geohash);
                        const coordsB = this.decodeGeohash(b.dataset.geohash);

                        const distA = this.calculateDistance(
                            this.userLocation.lat, this.userLocation.lng,
                            coordsA.lat, coordsA.lng
                        );
                        const distB = this.calculateDistance(
                            this.userLocation.lat, this.userLocation.lng,
                            coordsB.lat, coordsB.lng
                        );

                        // Return distance comparison (don't fall through to unread count)
                        return distA - distB;
                    } catch (e) {
                        // Fall through to unread count if error
                    }
                }
                // Non-geohash channels mix in with geohash by unread count — no forced grouping
            }

            // Default: sort by unread count
            const aChannel = a.dataset.geohash ? `#${a.dataset.geohash}` : a.dataset.channel;
            const bChannel = b.dataset.geohash ? `#${b.dataset.geohash}` : b.dataset.channel;

            const aUnread = this.unreadCounts.get(aChannel) || 0;
            const bUnread = this.unreadCounts.get(bChannel) || 0;

            if (aUnread !== bUnread) return bUnread - aUnread;

            // Tiebreaker: sort by most recent activity
            const aActivity = this.channelLastActivity.get(aChannel) || 0;
            const bActivity = this.channelLastActivity.get(bChannel) || 0;
            return bActivity - aActivity;
        });

        // Clear and re-append
        channelList.innerHTML = '';
        channels.forEach(channel => channelList.appendChild(channel));

        // Re-add view more button
        this.updateViewMoreButton('channelList');

        // Apply hidden channel visibility
        this.applyHiddenChannels();

        // Re-apply channel search filter if search is active
        const searchInput = document.getElementById('channelSearch');
        if (searchInput && searchInput.value.trim().length > 0) {
            this.filterChannels(searchInput.value);
        }

        // Restore scroll position
        channelList.scrollTop = scrollTop;
    },

    clearUnreadCount(channel) {
        this.unreadCounts.set(channel, 0);

        // Handle PM unread counts using conversation key
        if (channel.startsWith('pm-')) {
            // Extract the other user's pubkey from conversation key
            const keys = channel.substring(3).split('-');
            const otherPubkey = keys.find(k => k !== this.pubkey);
            if (otherPubkey) {
                const badge = document.querySelector(`[data-pubkey="${otherPubkey}"] .unread-badge`);
                if (badge) {
                    badge.style.display = 'none';
                }
            }
        } else if (channel.startsWith('group-')) {
            // Group chat unread counts
            const groupId = channel.substring(6);
            const badge = document.querySelector(`[data-group-id="${groupId}"] .unread-badge`);
            if (badge) {
                badge.style.display = 'none';
            }
        } else {
            // Regular channel unread counts — match updateUnreadCount selector logic
            let selector;
            if (channel.startsWith('#')) {
                selector = `[data-geohash="${channel.substring(1)}"]`;
            } else {
                selector = `[data-channel="${channel}"][data-geohash=""]`;
            }

            const badge = document.querySelector(`${selector} .unread-badge`);
            if (badge) {
                badge.style.display = 'none';
            }
        }
    },

    navigateHistory(direction) {
        const input = document.getElementById('messageInput');

        if (direction === -1 && this.historyIndex > 0) {
            this.historyIndex--;
            input.value = this.commandHistory[this.historyIndex];
        } else if (direction === 1 && this.historyIndex < this.commandHistory.length - 1) {
            this.historyIndex++;
            input.value = this.commandHistory[this.historyIndex];
        } else if (direction === 1 && this.historyIndex === this.commandHistory.length - 1) {
            this.historyIndex = this.commandHistory.length;
            input.value = '';
        }

        this.autoResizeTextarea(input);
    },

});
