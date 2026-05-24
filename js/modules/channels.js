// channels.js - Channel switch/add/remove, joined/pinned/hidden channels, navigation history, unread counts

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
        if (!this.isValidGeohash(geohash)) return;
        if (this.geohashMap) {
            this.geohashMap.updatePoints();
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

        const windowHours = (typeof this._geohashActiveWindowHours === 'number' && this._geohashActiveWindowHours > 0)
            ? Math.min(24, this._geohashActiveWindowHours) : 24;
        const cutoffSec = Math.floor(Date.now() / 1000) - windowHours * 3600;

        // Convert to array with coordinates - only channels with messages inside the active window
        allGeohashes.forEach(geohash => {
            try {
                const allMsgs = this.messages.get(`#${geohash}`) || [];
                let recentCount = 0;
                for (const m of allMsgs) {
                    if (m._spamGated) continue;
                    if ((m.created_at || 0) >= cutoffSec) recentCount++;
                }
                if (recentCount < 1) return;
                const coords = this.decodeGeohash(geohash);
                this.geohashChannels.push({
                    geohash: geohash.toLowerCase(),
                    lat: coords.lat,
                    lng: coords.lng,
                    messages: recentCount,
                    isJoined: this.channels.has(geohash)
                });
            } catch (e) {
            }
        });
    },

    setGeohashActiveWindow(hours) {
        let h = parseInt(hours, 10);
        if (!Number.isFinite(h) || h < 1) h = 1;
        if (h > 24) h = 24;
        this._geohashActiveWindowHours = h;
        document.querySelectorAll('.geohash-window-btn').forEach(b => {
            b.classList.toggle('active', parseInt(b.dataset.hours, 10) === h);
        });
        document.querySelectorAll('.geohash-window-select').forEach(s => {
            if (parseInt(s.value, 10) !== h) s.value = String(h);
        });
        if (this.geohashMap) {
            this.geohashMap.updatePoints();
        }
    },

    async selectGeohashChannel(channel) {
        this.selectedGeohash = channel.geohash.toLowerCase();

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
            const data = await this.fetchGeocode(channel.lat, channel.lng, 10);

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
        const channel = this.currentChannel || 'nymchat';
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

    // Wire encoding for a channel. Geohash channels use kind 20000 + `g` tag;
    // named (non-geohash) channels use kind 23333 + `d` tag.
    channelWire(channelKey) {
        const isGeohash = !!channelKey && this.isValidGeohash(channelKey);
        return {
            isGeohash,
            kind: isGeohash ? 20000 : 23333,
            tag: isGeohash ? 'g' : 'd'
        };
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
        if (this._channelFilterRAF) cancelAnimationFrame(this._channelFilterRAF);
        this._channelFilterRAF = requestAnimationFrame(() => {
            this._channelFilterRAF = null;
            this._filterChannelsNow(searchTerm);
        });
    },

    _filterChannelsNow(searchTerm) {
        const items = document.querySelectorAll('.channel-item');
        const term = (searchTerm || '').toLowerCase();
        const list = document.getElementById('channelList');

        const wrapper = document.getElementById('channelSearchWrapper');
        if (wrapper) {
            wrapper.classList.toggle('has-value', term.length > 0);
        }

        const validChannelPattern = /^#[\p{L}\p{N}]+$/u;
        items.forEach(item => {
            let channelName = item._cachedLowerName;
            if (channelName === undefined) {
                const channelNameEl = item.querySelector('.channel-name');
                channelName = channelNameEl ? channelNameEl.textContent.toLowerCase() : '';
                item._cachedLowerName = channelName;
            }
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
        // Don't allow pinning/unpinning #nymchat since it's always at top
        if ((geohash || channel) === 'nymchat') {
            this.displaySystemMessage('#nymchat is always at the top');
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
        this.sortChannelsByActivity();
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
            this._scheduleIdle(() => {
                this.updateChannelPins();
                this.sortChannelsByActivity();
            });
        }
    },

    toggleHideChannel(channel, geohash) {
        if ((geohash || channel) === 'nymchat') {
            this.displaySystemMessage('#nymchat cannot be hidden');
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

            // Never hide #nymchat or the active channel
            if (key === 'nymchat' || item.classList.contains('active')) {
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

        // If currently in this channel, switch to #nymchat
        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('nymchat', 'nymchat');
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
            this.addChannel(channel, channel);
        }

        // Update view more button after adding
        this.updateViewMoreButton('channelList');
    },

    updateBlockedChannelsList() {
        const container = document.getElementById('blockedChannelsList');
        if (!container) return;

        if (this.blockedChannels.size === 0) {
            container.innerHTML = '<div class="nm-dim12">No blocked channels</div>';
        } else {
            container.innerHTML = Array.from(this.blockedChannels).map(key => {
                const displayName = this.isValidGeohash(key) ? `#${key} [GEO]` : `#${key} [EPH]`;
                return `
        <div class="blocked-item">
            <span>${this.escapeHtml(displayName)}</span>
            <button class="unblock-btn" data-action="unblockChannelFromSettings" data-channel-key="${this.escapeHtml(key)}">Unblock</button>
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
            container.innerHTML = '<div class="nm-dim12">No hidden channels</div>';
        } else {
            container.innerHTML = Array.from(this.hiddenChannels).map(key => {
                const displayName = `#${key}`;
                const location = this.getGeohashLocation(key);
                const label = location ? `${this.escapeHtml(displayName)} (${this.escapeHtml(location)})` : this.escapeHtml(displayName);
                return `
        <div class="blocked-item">
            <span>${label}</span>
            <button class="unblock-btn" data-action="unhideChannelFromSettings" data-channel-key="${this.escapeHtml(key)}">Unhide</button>
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

    // Render the current channel title
    _renderChannelTitle(channel, geohash) {
        const titleEl = document.getElementById('currentChannel');
        if (!titleEl) return;

        const safeChannel = this.sanitizeChannelName(channel);
        const safeGeohash = this.sanitizeChannelName(geohash);
        const isGeo = !!safeGeohash && this.isValidGeohash(safeGeohash);
        const displayName = safeGeohash ? `#${safeGeohash}` : `#${safeChannel}`;
        if (!safeChannel && !safeGeohash) {
            titleEl.replaceChildren();
            return;
        }

        const nameNode = document.createTextNode(displayName + ' ');

        const typeLabel = document.createElement('span');
        typeLabel.className = 'channel-type-label';
        typeLabel.textContent = isGeo ? '(Geohash)' : '(Non-Geohash)';

        const nodes = [nameNode, typeLabel];

        if (isGeo) {
            const locWrap = document.createElement('div');
            locWrap.className = 'channel-location';

            const link = document.createElement('a');
            link.setAttribute('href', `https://www.geohash.es/decode?geohash=${encodeURIComponent(safeGeohash.toLowerCase())}`);
            link.setAttribute('target', '_blank');
            link.setAttribute('rel', 'noopener');

            const cached = this._geohashPlaceCache && this._geohashPlaceCache.get(safeGeohash.toLowerCase());
            link.textContent = cached || 'Loading location...';
            locWrap.appendChild(link);

            if (this.userLocation && this.settings.sortByProximity) {
                try {
                    const coords = this.decodeGeohash(safeGeohash);
                    const distance = this.calculateDistance(
                        this.userLocation.lat, this.userLocation.lng,
                        coords.lat, coords.lng
                    );
                    locWrap.appendChild(document.createTextNode(` (${distance.toFixed(1)}km)`));
                } catch (e) { }
            }

            nodes.push(locWrap);

            if (!cached) {
                this._resolveGeohashPlaceName(safeGeohash).then(place => {
                    if (link.isConnected) link.textContent = place;
                }).catch(() => {
                    if (link.isConnected) link.textContent = this.getGeohashLocation(safeGeohash);
                });
            }
        }

        titleEl.replaceChildren(...nodes);
    },

    // Resolve a geohash to a human-readable place name, cached per geohash.
    async _resolveGeohashPlaceName(geohash) {
        if (!this._geohashPlaceCache) this._geohashPlaceCache = new Map();
        const key = geohash.toLowerCase();
        if (this._geohashPlaceCache.has(key)) return this._geohashPlaceCache.get(key);

        const coords = this.decodeGeohash(geohash);
        const data = await this.fetchGeocode(coords.lat, coords.lng, 10);
        const addr = (data && data.address) || {};
        const city = addr.city || addr.town || addr.village || addr.county || '';
        const country = addr.country || '';
        const place = [city, country].filter(x => x).join(', ') || 'Unknown location';

        this._geohashPlaceCache.set(key, place);
        return place;
    },

    // Identifies the active conversation so unsent input can be kept per place.
    _getInputContextKey() {
        if (this.inPMMode && this.currentGroup) return 'g:' + this.currentGroup;
        if (this.inPMMode && this.currentPM) return 'p:' + this.currentPM;
        return 'c:' + (this.currentGeohash || this.currentChannel || '');
    },

    // Stash whatever is in the message input under the current conversation key.
    _saveCurrentDraft() {
        const input = document.getElementById('messageInput');
        if (!input || !input._richInit || !this._activeDraftKey) return;
        if (!this._inputDrafts) this._inputDrafts = new Map();
        const v = input.value || '';
        if (v.trim()) this._inputDrafts.set(this._activeDraftKey, v);
        else this._inputDrafts.delete(this._activeDraftKey);
    },

    // Load the saved draft for the conversation now in view (empty if none).
    _restoreDraftForContext() {
        const input = document.getElementById('messageInput');
        if (!input || !input._richInit) return;
        if (!this._inputDrafts) this._inputDrafts = new Map();
        const key = this._getInputContextKey();
        this._activeDraftKey = key;
        const draft = this._inputDrafts.get(key) || '';
        if ((input.value || '') === draft) return;
        input.value = draft;
        if (typeof this.autoResizeTextarea === 'function') this.autoResizeTextarea(input);
        if (typeof this.updateTranslateInputBtn === 'function') this.updateTranslateInputBtn();
        if (typeof this.handleInputChange === 'function') this.handleInputChange(draft);
    },

    switchChannel(channel, geohash = '') {
        // Keep the current conversation's unsent input before switching away
        this._saveCurrentDraft();
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

        if (!this.inPMMode && previousGeohash && previousGeohash !== geohash &&
            typeof this.sendChannelTypingStop === 'function') {
            this.sendChannelTypingStop(previousGeohash);
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

        // Close the prior channel's REQ on relays unless it's joined/common
        // (keep those alive so background unread counts keep updating)
        const previousKey = previousGeohash || previousChannel;
        const newKey = geohash || channel;
        if (previousKey && previousKey !== newKey && typeof this.closeChannelSubscription === 'function') {
            this.closeChannelSubscription(previousKey);
        }

        // Connect to nearby relays for geohash channels (async, non-blocking)
        // connectToGeoRelays handles its own subscription internally after
        // geo relays are configured. The proxy buffers GEO_EVENTs for relays
        // still connecting, so no need to block the channel switch.
        if (geohash) {
            this.connectToGeoRelays(geohash);
            this.startGeoRelayKeepAlive(geohash);
        } else {
            this.stopGeoRelayKeepAlive();
        }

        // Always ensure default relays (first 5 broadcast) stay connected
        this.ensureDefaultRelaysConnected();

        // Load channel messages from relays (immediate, uses whatever relays are connected)
        const channelType = (geohash && this.isValidGeohash(geohash)) ? 'geohash' : 'non-geohash';
        const channelKey = geohash || channel;
        this.loadChannelFromRelays(channelKey, channelType);

        // Show share button in channel mode
        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) {
            shareBtn.style.display = 'block';
        }

        const displayName = geohash ? `#${geohash}` : `#${channel}`;

        this._renderChannelTitle(channel, geohash);

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

        // Re-sort sidebar so the active channel moves to the top while we're
        // viewing it (and the previous channel falls back to its activity slot)
        this.sortChannelsByActivity();

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

        // Restore any unsent input previously typed for this channel
        this._restoreDraftForContext();

        // Close stale autocomplete dropdowns from the previous channel and
        // restore focus to the input so typing continues without re-clicking.
        this.hideAutocomplete();
        this.hideChannelAutocomplete();
        this.hideEmojiAutocomplete();
        this._focusMessageInput();

        // Close mobile sidebar on mobile
        if (window.innerWidth <= 768) {
            this.closeSidebar();
        }
    },

    _focusMessageInput() {
        if (window.innerWidth <= 768) return;
        // Don't steal focus from another input/editable the user just clicked
        // into (search boxes, modal fields, etc.). Only refocus the message
        // input when focus isn't already on a different focusable control.
        const active = document.activeElement;
        if (active && active.id !== 'messageInput') {
            const tag = active.tagName;
            if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || active.isContentEditable) {
                return;
            }
        }
        const input = document.getElementById('messageInput');
        if (input) input.focus();
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

            item.innerHTML = `
    <span class="channel-name"${locationHint}>${displayName}</span>
    <div class="channel-badges">
        <span class="unread-badge nm-hidden">0</span>
    </div>
`;

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
            if (typeof this.refreshChannelAutocompleteIfOpen === 'function') {
                this.refreshChannelAutocompleteIfOpen();
            }

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

        // Don't allow removing default channel #nymchat
        if (key === 'nymchat') {
            this.displaySystemMessage('Cannot remove the default #nymchat channel');
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

        // If we're currently in this channel, switch to #nymchat
        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('nymchat', 'nymchat');
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
                // and migrate the legacy default channel key to the renamed default.
                return [...new Set(channels
                    .filter(ch => ch && /^[\p{L}\p{N}]+$/u.test(ch))
                    .map(ch => ch === 'nym' ? 'nymchat' : ch))];
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
        const count = this._recomputeUnreadCount(channel);
        this.unreadCounts.set(channel, count);
        this._persistUnreadCounts();
        this._renderUnreadBadge(channel, count);
        this._scheduleChannelSort();
    },

    // Counter is derived from cached messages newer than lastRead so it
    // can't drift from the actual cache contents.
    _recomputeUnreadCount(channel) {
        if (!this.channelLastRead) this.channelLastRead = new Map();
        const lastRead = this.channelLastRead.get(channel) || 0;
        let messages;
        if (channel.startsWith('pm-') || channel.startsWith('group-')) {
            messages = this.pmMessages && this.pmMessages.get(channel);
        } else {
            messages = this.messages && this.messages.get(channel);
        }
        if (!Array.isArray(messages) || messages.length === 0) return 0;
        let count = 0;
        for (const m of messages) {
            if (!m || m.isOwn) continue;
            if (m._spamGated) continue;
            if ((m.created_at || 0) <= lastRead) continue;
            if (this.blockedUsers && m.pubkey && this.blockedUsers.has(m.pubkey)) continue;
            count++;
        }
        return count;
    },

    _markChannelRead(channel, ts) {
        if (!this.channelLastRead) this.channelLastRead = new Map();
        const cur = this.channelLastRead.get(channel) || 0;
        const next = ts || Math.floor(Date.now() / 1000);
        if (next > cur) {
            this.channelLastRead.set(channel, next);
            this._persistUnreadCounts();
        }
    },

    _renderUnreadBadge(channel, count) {
        let item = null;
        if (channel.startsWith('pm-')) {
            const keys = channel.substring(3).split('-');
            const otherPubkey = keys.find(k => k !== this.pubkey);
            if (otherPubkey) item = document.querySelector(`[data-pubkey="${otherPubkey}"]`);
        } else if (channel.startsWith('group-')) {
            const groupId = channel.substring(6);
            item = document.querySelector(`[data-group-id="${groupId}"]`);
        } else if (channel.startsWith('#')) {
            item = document.querySelector(`[data-geohash="${channel.substring(1)}"]`);
        } else {
            item = document.querySelector(`[data-channel="${channel}"][data-geohash=""]`);
        }
        if (!item) return;
        const badge = item.querySelector('.unread-badge');
        if (badge) {
            badge.textContent = count > 99 ? '99+' : count;
            badge.style.display = count > 0 ? 'block' : 'none';
        }
        item.classList.toggle('has-unread', count > 0);
    },

    // Throttle the sidebar sort so it fires immediately on the first call
    _scheduleChannelSort() {
        const SORT_THROTTLE_MS = 300;
        const now = Date.now();
        const last = this._lastChannelSortAt || 0;
        const elapsed = now - last;

        if (elapsed >= SORT_THROTTLE_MS) {
            if (this._sortDebounceTimer) {
                clearTimeout(this._sortDebounceTimer);
                this._sortDebounceTimer = null;
            }
            this._lastChannelSortAt = now;
            this.sortChannelsByActivity();
            return;
        }

        if (this._sortDebounceTimer) return;
        this._sortDebounceTimer = setTimeout(() => {
            this._sortDebounceTimer = null;
            this._lastChannelSortAt = Date.now();
            this.sortChannelsByActivity();
        }, SORT_THROTTLE_MS - elapsed);
    },

    sortChannelsByActivity() {
        const channelList = document.getElementById('channelList');
        const channels = Array.from(channelList.querySelectorAll('.channel-item'));

        // Save view more button if it exists
        const viewMoreBtn = channelList.querySelector('.view-more-btn');

        // Store current scroll position
        const scrollTop = channelList.scrollTop;

        channels.sort((a, b) => {
            // #nymchat is always first
            const aIsDefault = (a.dataset.geohash || a.dataset.channel) === 'nymchat';
            const bIsDefault = (b.dataset.geohash || b.dataset.channel) === 'nymchat';

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

            // Default: sort by most recent activity so live channels float
            // to the top regardless of stale unread counts left over from cache
            const aChannel = a.dataset.geohash ? `#${a.dataset.geohash}` : a.dataset.channel;
            const bChannel = b.dataset.geohash ? `#${b.dataset.geohash}` : b.dataset.channel;

            const aActivity = this.channelLastActivity.get(aChannel) || 0;
            const bActivity = this.channelLastActivity.get(bChannel) || 0;

            if (aActivity !== bActivity) return bActivity - aActivity;

            // Tiebreaker: unread count
            const aUnread = this.unreadCounts.get(aChannel) || 0;
            const bUnread = this.unreadCounts.get(bChannel) || 0;
            return bUnread - aUnread;
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
        if (!this.channelLastRead) this.channelLastRead = new Map();
        let lastTs = Math.floor(Date.now() / 1000);
        let messages;
        if (channel.startsWith('pm-') || channel.startsWith('group-')) {
            messages = this.pmMessages && this.pmMessages.get(channel);
        } else {
            messages = this.messages && this.messages.get(channel);
        }
        if (Array.isArray(messages)) {
            for (const m of messages) {
                if (m && (m.created_at || 0) > lastTs) lastTs = m.created_at;
            }
        }
        this.channelLastRead.set(channel, lastTs);
        this.unreadCounts.set(channel, 0);
        this._persistUnreadCounts(true);
        this._renderUnreadBadge(channel, 0);
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

    // Persist unread counts and last-activity timestamps so the sidebar
    // sort order and badges survive a page reload.
    _persistUnreadCounts(immediate = false) {
        if (immediate) {
            if (this._persistUnreadTimer) {
                clearTimeout(this._persistUnreadTimer);
                this._persistUnreadTimer = null;
            }
            this._writeUnreadCountsToLocalStorage();
            return;
        }
        if (this._persistUnreadTimer) return;
        this._persistUnreadTimer = setTimeout(() => {
            this._persistUnreadTimer = null;
            this._writeUnreadCountsToLocalStorage();
        }, 1000);

        // Flush pending writes on unload so debounced state isn't lost.
        if (!this._unreadUnloadHooked && typeof window !== 'undefined') {
            this._unreadUnloadHooked = true;
            const flush = () => this._persistUnreadCounts(true);
            window.addEventListener('pagehide', flush);
            window.addEventListener('beforeunload', flush);
            document.addEventListener('visibilitychange', () => {
                if (document.hidden) flush();
            });
            window.addEventListener('freeze', flush);
        }
    },

    _writeUnreadCountsToLocalStorage() {
        try {
            const unread = {};
            for (const [k, v] of this.unreadCounts) {
                if (v > 0) unread[k] = v;
            }
            const activity = {};
            for (const [k, v] of this.channelLastActivity) {
                if (v > 0) activity[k] = v;
            }
            const lastRead = {};
            if (this.channelLastRead) {
                for (const [k, v] of this.channelLastRead) {
                    if (v > 0) lastRead[k] = v;
                }
            }
            localStorage.setItem('nym_unread_counts', JSON.stringify(unread));
            localStorage.setItem('nym_channel_activity', JSON.stringify(activity));
            localStorage.setItem('nym_channel_last_read', JSON.stringify(lastRead));
        } catch (_) { }
    },

    _hydrateUnreadCounts() {
        try {
            const u = localStorage.getItem('nym_unread_counts');
            if (u) {
                const parsed = JSON.parse(u);
                for (const [k, v] of Object.entries(parsed || {})) {
                    if (typeof v === 'number' && v > 0) this.unreadCounts.set(k, v);
                }
            }
            const a = localStorage.getItem('nym_channel_activity');
            if (a) {
                const parsed = JSON.parse(a);
                for (const [k, v] of Object.entries(parsed || {})) {
                    if (typeof v === 'number' && v > 0 && !this.channelLastActivity.has(k)) {
                        this.channelLastActivity.set(k, v);
                    }
                }
            }
            if (!this.channelLastRead) this.channelLastRead = new Map();
            const r = localStorage.getItem('nym_channel_last_read');
            if (r) {
                const parsed = JSON.parse(r);
                for (const [k, v] of Object.entries(parsed || {})) {
                    if (typeof v === 'number' && v > 0) this.channelLastRead.set(k, v);
                }
            }
        } catch (_) { }
    },

    recomputeAllUnreadCounts() {
        const keys = new Set();
        if (this.messages) for (const k of this.messages.keys()) keys.add(k);
        if (this.pmMessages) for (const k of this.pmMessages.keys()) keys.add(k);
        if (this.unreadCounts) for (const k of this.unreadCounts.keys()) keys.add(k);
        for (const k of keys) {
            if (!k) continue;
            const count = this._recomputeUnreadCount(k);
            if (count > 0) this.unreadCounts.set(k, count);
            else this.unreadCounts.delete(k);
            this._renderUnreadBadge(k, count);
        }
        this._persistUnreadCounts(true);
    },

});
