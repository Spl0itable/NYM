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

        // From D1 activity counts (channels we know of but may never have opened,
        // so the explorer reflects real activity without loading their messages).
        if (this._geohashD1Activity) {
            this._geohashD1Activity.forEach((_buckets, name) => {
                if (this.isValidGeohash(name)) allGeohashes.add(name.toLowerCase());
            });
        }

        const windowHours = (typeof this._geohashActiveWindowHours === 'number' && this._geohashActiveWindowHours > 0)
            ? Math.min(24, this._geohashActiveWindowHours) : 24;
        const nowSec = Math.floor(Date.now() / 1000);

        // Convert to array with coordinates - only channels with activity inside the active window
        allGeohashes.forEach(geohash => {
            try {
                // Bucket locally stored messages into 24 hourly slots aligned with
                // the D1 activity buckets (index 0 = the most recent hour).
                const localBuckets = new Array(24).fill(0);
                const allMsgs = this.messages.get(`#${geohash}`) || [];
                for (const m of allMsgs) {
                    if (m._spamGated) continue;
                    const ts = m.created_at || 0;
                    if (!ts) continue;
                    let ageH = Math.floor((nowSec - ts) / 3600);
                    if (ageH < 0) ageH = 0;
                    if (ageH < 24) localBuckets[ageH]++;
                }
                // Mix local + D1 counts
                const recentCount = this._combineGeohashActivity(geohash, localBuckets, windowHours);
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

    // Combine locally stored and D1-archived activity for a geohash
    _combineGeohashActivity(geohash, localBuckets, windowHours) {
        const d1 = this._geohashD1Activity
            ? this._geohashD1Activity.get(String(geohash).toLowerCase())
            : null;
        const n = Math.max(1, Math.min(24, windowHours | 0));
        let total = 0;
        for (let i = 0; i < n; i++) {
            const local = (localBuckets && localBuckets[i]) || 0;
            const d1c = (Array.isArray(d1) && d1[i]) || 0;
            total += Math.max(local, d1c);
        }
        return total;
    },

    // Quietly fetch recent-activity counts for all known geohash channels
    async fetchGeohashActivityFromD1() {
        if (!this._getApiHost || !this._getApiHost()) return;
        if (typeof this._storageApiRequest !== 'function') return;
        const now = Date.now();
        if (this._geohashActivityFetchedAt && now - this._geohashActivityFetchedAt < 30000) return;
        this._geohashActivityFetchedAt = now;

        // Gather every geohash we know about: common geohashes, sidebar
        // channels, and any geohash with stored messages.
        const names = new Set();
        const add = (g) => { if (g && this.isValidGeohash(g)) names.add(String(g).toLowerCase()); };
        this.commonGeohashes.forEach(add);
        this.channels.forEach((value) => { if (value && value.geohash) add(value.geohash); });
        this.messages.forEach((_msgs, channel) => {
            if (channel.startsWith('#')) add(channel.substring(1));
        });
        const list = [...names];

        try {
            if (!this._geohashD1Activity) this._geohashD1Activity = new Map();
            if (!this._d1ChannelLast) this._d1ChannelLast = new Map();
            const [discovered, known] = await Promise.all([
                this._storageApiRequest('channel-active', {}, false).catch(() => null),
                list.length ? this._storageApiRequest('channel-activity', { channels: list }, false).catch(() => null) : null
            ]);
            const hasDiscovered = discovered && discovered.activity && Object.keys(discovered.activity).length > 0;
            const target = hasDiscovered ? new Map() : this._geohashD1Activity;
            if (discovered && discovered.activity && typeof discovered.activity === 'object') {
                for (const [name, buckets] of Object.entries(discovered.activity)) {
                    if (Array.isArray(buckets) && this.isValidGeohash(name)) {
                        target.set(String(name).toLowerCase(), buckets);
                    }
                }
            }
            this._mergeD1Last(discovered && discovered.last);
            this._geohashD1Activity = target;
            this._mergeUnreadBuckets(known);
            const added = this._populateSidebarFromD1Activity();
            this._seedUnreadFromD1Activity();
            this._fetchUnreadBucketsFor(added);
            if (this.geohashMap && typeof this.geohashMap.updatePoints === 'function') {
                this.geohashMap.updatePoints();
            }
        } catch (_) {
            // Best-effort; the explorer still works from locally stored messages.
            this._geohashActivityFetchedAt = 0;
        }
    },

    _mergeUnreadBuckets(data) {
        if (!data || !data.activity || typeof data.activity !== 'object') return;
        if (!this._d1UnreadBuckets) this._d1UnreadBuckets = new Map();
        for (const [name, buckets] of Object.entries(data.activity)) {
            if (Array.isArray(buckets)) this._d1UnreadBuckets.set(String(name).toLowerCase(), buckets);
        }
        this._mergeD1Last(data.last);
    },

    // Merge a { channel: lastCreatedAtSec } map from D1 into _d1ChannelLast.
    _mergeD1Last(last) {
        if (!last || typeof last !== 'object') return;
        if (!this._d1ChannelLast) this._d1ChannelLast = new Map();
        for (const [name, ts] of Object.entries(last)) {
            const sec = Number(ts) || 0;
            if (sec <= 0) continue;
            const k = String(name).toLowerCase();
            if (sec > (this._d1ChannelLast.get(k) || 0)) this._d1ChannelLast.set(k, sec);
        }
    },

    // Precise last-activity (ms) for a channel from D1, falling back to an
    // hourly-bucket approximation (index 0 = current hour) when no exact
    // timestamp is available.
    _d1ChannelLastActivityMs(name, buckets) {
        const exact = this._d1ChannelLast && this._d1ChannelLast.get(String(name).toLowerCase());
        if (exact) return exact * 1000;
        if (!Array.isArray(buckets)) return 0;

        const anchor = Math.floor(
            (this._geohashActivityFetchedAt || Date.now()) / 1000);

        for (let h = 0; h < buckets.length && h < 24; h++) {
            if ((buckets[h] || 0) > 0) {

                return (anchor - (h + 1) * 3600) * 1000;
            }
        }
        return 0;
    },

    // Populate the sidebar with channels discovered via D1 activity (geohash
    // kind 20000 and named kind 23333). The relay proxy pool relies on D1
    // instead of a relay backfill, so without this the sidebar never learns
    // about active channels it hasn't joined.
    _populateSidebarFromD1Activity() {
        if (!this.useRelayProxy) return [];
        // The explorer can plot thousands of channels, but the sidebar should
        // only surface the most recently active discovered ones. Never fewer
        // than the collapsed row budget, so every row on screen can carry a
        // badge; expanding the list raises it.
        const expanded = this.listExpansionStates && this.listExpansionStates.get('channelList');
        const SIDEBAR_DISCOVER_LIMIT = Math.max(
            this.COLLAPSED_LIST_VISIBLE, expanded ? 120 : 30);
        const added = [];
        const candidates = [];
        const consider = (name, buckets) => {
            const nm = String(name).toLowerCase();
            if (!nm || !/^[\p{L}\p{N}]+$/u.test(nm)) return;
            const ts = this._d1ChannelLastActivityMs(nm, buckets);
            const key = '#' + nm;
            if (this.channels.has(nm)) {
                if (ts > (this.channelLastActivity.get(key) || 0)) {
                    this.channelLastActivity.set(key, ts);
                }
                return;
            }
            if (this.isChannelBlocked(nm, nm)) return;
            candidates.push({ nm, key, ts });
        };
        if (this._geohashD1Activity) this._geohashD1Activity.forEach((b, n) => { if (this.isValidGeohash(n)) consider(n, b); });
        if (this._namedChannelActivity) this._namedChannelActivity.forEach((b, n) => { if (!this.isValidGeohash(n)) consider(n, b); });
        candidates.sort((a, b) => b.ts - a.ts);
        this._withBulkChannelAdd(() => {
            for (let i = 0; i < candidates.length && i < SIDEBAR_DISCOVER_LIMIT; i++) {
                const c = candidates[i];
                this.addChannelToList(c.nm, c.nm);
                if (c.ts > 0) this.channelLastActivity.set(c.key, c.ts);
                added.push(c.nm);
            }
        });
        if (added.length) this._persistUnreadCounts();
        this._scheduleChannelSort();
        return added;
    },

    // Discovery hands us raw activity, which includes spam the client hides, so
    // it can't seed a badge. Pull the spam-aware buckets for rows we just added
    // and seed them now instead of leaving them blank until the next sweep.
    async _fetchUnreadBucketsFor(names) {
        if (!Array.isArray(names) || names.length === 0) return;
        if (typeof this._storageApiRequest !== 'function') return;
        if (!this._d1UnreadBuckets) this._d1UnreadBuckets = new Map();
        const missing = names.filter(n => n && !this._d1UnreadBuckets.has(n));
        if (missing.length === 0) return;
        try {
            const data = await this._storageApiRequest('channel-activity', { channels: missing }, false);
            if (!data) return;
            this._mergeUnreadBuckets(data);
            this._seedUnreadFromD1Activity();
        } catch (_) { }
    },

    // Seed sidebar unread badges from the spam-aware per-channel activity so the
    // floor matches what the client actually renders (no spam/poll inflation).
    _seedUnreadFromD1Activity() {
        const act = this._d1UnreadBuckets;
        if (!act || act.size === 0 || !this.channels) return;
        if (!this.channelLastRead) this.channelLastRead = new Map();
        if (!this._d1Unread) this._d1Unread = new Map();
        const now = Math.floor(Date.now() / 1000);
        let changed = false;
        const seedKey = (unreadKey, buckets) => {
            if (!Array.isArray(buckets)) return;
            const lastRead = this.channelLastRead.get(unreadKey) || 0;
            // Buckets are hourly, index 0 = current hour. Sum the hours that fall
            // after lastRead (whole channel when never read).
            const span = lastRead > 0
                ? Math.min(24, Math.max(0, Math.ceil((now - lastRead) / 3600)))
                : 24;
            let count = 0;
            for (let h = 0; h < span; h++) count += (buckets[h] || 0);
            // D1 is the archive of record: keep it as a floor so a stale or
            // already-read local cache can't drop the badge below real activity.
            this._d1Unread.set(unreadKey, count);
            if (count > (this.unreadCounts.get(unreadKey) || 0)) {
                this._setUnreadCount(unreadKey, count);
                this._renderUnreadBadge(unreadKey, count);
                changed = true;
            }
        };
        this.channels.forEach((value) => {
            if (!value) return;
            const name = String(value.geohash || value.channel || '').toLowerCase();
            if (!name) return;
            seedKey('#' + name, act.get(name));
        });
        if (changed) this._persistUnreadCounts();
    },

    // Discover recently-active NAMED channels (kind 23333) and fetch activity
    // buckets for known ones into a map separate from the geohash explorer's,
    // then surface them in the sidebar and seed their unread badges.
    async fetchNamedChannelActivityFromD1() {
        if (!this._getApiHost || !this._getApiHost()) return;
        if (typeof this._storageApiRequest !== 'function') return;
        const now = Date.now();
        if (this._namedActivityFetchedAt && now - this._namedActivityFetchedAt < 30000) return;
        this._namedActivityFetchedAt = now;
        const names = new Set();
        this.channels.forEach((value) => {
            const nm = value ? String(value.geohash || value.channel || '').toLowerCase() : '';
            if (nm && !this.isValidGeohash(nm)) names.add(nm);
        });
        const list = [...names];
        try {
            if (!this._namedChannelActivity) this._namedChannelActivity = new Map();
            if (!this._d1ChannelLast) this._d1ChannelLast = new Map();
            const [discovered, known] = await Promise.all([
                this._storageApiRequest('channel-active-named', {}, false).catch(() => null),
                list.length ? this._storageApiRequest('channel-activity', { channels: list }, false).catch(() => null) : null
            ]);

            const hasDiscovered = discovered && discovered.activity && Object.keys(discovered.activity).length > 0;
            const target = hasDiscovered ? new Map() : this._namedChannelActivity;
            if (discovered && discovered.activity && typeof discovered.activity === 'object') {
                for (const [name, buckets] of Object.entries(discovered.activity)) {
                    if (Array.isArray(buckets) && !this.isValidGeohash(name)) {
                        target.set(String(name).toLowerCase(), buckets);
                    }
                }
            }
            this._mergeD1Last(discovered && discovered.last);
            this._namedChannelActivity = target;
            // Spam-aware activity feeds unread floors only.
            this._mergeUnreadBuckets(known);
            const added = this._populateSidebarFromD1Activity();
            this._seedUnreadFromD1Activity();
            this._fetchUnreadBucketsFor(added);
        } catch (_) {
            this._namedActivityFetchedAt = 0;
        }
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

            locationInfo = [city, country].filter(x => x).join(', ')
                || this.getGeohashLocation(channel.geohash) || 'Unknown location';

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
            if (entry.type === 'thread' && current.rootId === entry.rootId) return;
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
            if (entry.type === 'thread') {
                if (typeof this._navOpenThread === 'function') this._navOpenThread(entry);
                return;
            }
            // Leaving a thread entry (or jumping conversations) exits the
            // thread view, restoring its conversation in place.
            if (typeof this.closeThreadView === 'function') this.closeThreadView({ nav: false });
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
        this._withBulkChannelAdd(() => {
            allChannels.forEach(channel => {
                this.addChannel(channel.name, channel.geohash);
            });
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
        this._refreshFavoriteChannelBtn();
    },

    _refreshFavoriteChannelBtn() {
        if (typeof this._refreshCallButtons === 'function') this._refreshCallButtons();
        const btn = document.getElementById('favoriteChannelBtn');
        if (!btn) return;
        const key = this.currentGeohash || this.currentChannel;
        const inChannel = !this.inPMMode && !!key;
        if (!inChannel) {
            btn.style.display = 'none';
            return;
        }
        btn.style.display = 'block';
        if (key === 'nymchat') {
            btn.disabled = true;
            btn.classList.remove('active');
            btn.title = '#nymchat is always favorited';
            return;
        }
        btn.disabled = false;
        const isFav = this.pinnedChannels && this.pinnedChannels.has(key);
        btn.classList.toggle('active', !!isFav);
        btn.title = isFav ? 'Unfavorite channel' : 'Favorite channel';
        btn.setAttribute('aria-label', btn.title);
    },

    toggleFavoriteCurrentChannel() {
        if (this.inPMMode) return;
        const channel = this.currentChannel;
        const geohash = this.currentGeohash;
        if (!channel && !geohash) return;
        this.togglePin(channel, geohash);
        this._refreshFavoriteChannelBtn();
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
        if (localStorage.getItem('nym_pinned_channels')) {
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

    _withBulkChannelAdd(fn) {
        const outer = !this._bulkChannelAdd;
        if (outer) this._bulkChannelAdd = true;
        try {
            return fn();
        } finally {
            // Never leave the flag set on a throw — later addChannel calls would
            // silently stop refreshing pins and hidden state.
            if (outer) this._flushBulkChannelAdd();
        }
    },

    /// Runs the per-add sidebar refreshes that _bulkChannelAdd suppressed.
    _flushBulkChannelAdd() {
        this._bulkChannelAdd = false;
        this.updateChannelPins();
        this.applyHiddenChannels();
        // After applyHiddenChannels, so the overflow marking sees settled
        // display state rather than recomputing against stale rows.
        this.updateViewMoreButton('channelList');
        if (typeof this.refreshChannelAutocompleteIfOpen === 'function') {
            this.refreshChannelAutocompleteIfOpen();
        }
    },

    /// Rows a collapsed list shows before "View N more...".
    COLLAPSED_LIST_VISIBLE: 20,

    _markListOverflow(listId) {
        const list = document.getElementById(listId);
        if (!list) return [];
        const visible = Array.from(list.querySelectorAll('.list-item:not(.search-hidden)'))
            .filter(el => el.style.display !== 'none');
        const isExpanded = this.listExpansionStates.get(listId) || false;
        const cap = this.COLLAPSED_LIST_VISIBLE;
        list.querySelectorAll('.list-overflow').forEach(el => el.classList.remove('list-overflow'));
        if (!isExpanded) {
            for (let i = cap; i < visible.length; i++) visible[i].classList.add('list-overflow');
        }
        return visible;
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
        this.hideNonPinned = localStorage.getItem('nym_hide_non_pinned') === 'true';
        this._scheduleIdle(() => this.applyHiddenChannels());
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
        if (typeof this._hideBotControlBar === 'function') this._hideBotControlBar();
        delete titleEl.dataset.pmHeaderSig;
        delete titleEl.dataset.groupHeaderSig;

        const safeChannel = this.sanitizeChannelName(channel);
        const safeGeohash = this.sanitizeChannelName(geohash);
        const isGeo = !!safeGeohash && this.isValidGeohash(safeGeohash);
        const displayName = safeGeohash ? `#${safeGeohash}` : `#${safeChannel}`;
        if (!safeChannel && !safeGeohash) {
            titleEl.replaceChildren();
            return;
        }

        const titleLine = document.createElement('span');
        titleLine.className = 'channel-title-line';
        titleLine.appendChild(document.createTextNode(displayName));

        const nodes = [titleLine];

        if (!isGeo) {
            const locWrap = document.createElement('div');
            locWrap.className = 'channel-location';
            const notGeo = document.createElement('span');
            notGeo.className = 'loc-country';
            notGeo.textContent = 'Not a geohash';
            locWrap.appendChild(notGeo);
            nodes.push(locWrap);
        }

        if (isGeo) {
            const locWrap = document.createElement('div');
            locWrap.className = 'channel-location';

            const link = document.createElement('a');
            link.setAttribute('href', `https://www.geohash.es/decode?geohash=${encodeURIComponent(safeGeohash.toLowerCase())}`);
            link.setAttribute('target', '_blank');
            link.setAttribute('rel', 'noopener');

            const cached = this._loadGeohashPlaceCache().get(safeGeohash.toLowerCase());
            this._fillLocationLink(link, cached || 'Loading location...');
            locWrap.appendChild(link);

            if (this.userLocation && this.settings.sortByProximity) {
                try {
                    const coords = this.decodeGeohash(safeGeohash);
                    const distance = this.calculateDistance(
                        this.userLocation.lat, this.userLocation.lng,
                        coords.lat, coords.lng
                    );
                    const distSpan = document.createElement('span');
                    distSpan.className = 'channel-location-dist';
                    distSpan.textContent = ` (${distance.toFixed(1)}km)`;
                    locWrap.appendChild(distSpan);
                } catch (e) { }
            }

            nodes.push(locWrap);

            if (!cached) {
                this._resolveGeohashPlaceName(safeGeohash).then(place => {
                    if (link.isConnected) this._fillLocationLink(link, place);
                }).catch(() => {
                    if (link.isConnected) this._fillLocationLink(link, this.getGeohashLocation(safeGeohash));
                });
            }
        }

        titleEl.replaceChildren(...nodes);
    },

    _fillLocationLink(link, place) {
        this._fillLocationParts(link, place);
    },

    // Split "City, Region, Country" into a shrinkable city part and a country
    // part that never truncates, so a narrow container eats the city and still
    // shows which country the channel is in. Shared by the channel header and
    // the sidebar subtext.
    _fillLocationParts(el, place) {
        el.replaceChildren();
        const idx = place.lastIndexOf(', ');
        if (idx > 0 && idx < place.length - 2) {
            const city = document.createElement('span');
            city.className = 'loc-city';
            city.textContent = place.slice(0, idx);
            const country = document.createElement('span');
            country.className = 'loc-country';
            country.textContent = place.slice(idx);
            el.appendChild(city);
            el.appendChild(country);
        } else {
            // No country to protect — one run, free to ellipsize.
            const only = document.createElement('span');
            only.className = 'loc-city';
            only.textContent = place;
            el.appendChild(only);
        }
    },

    // Resolve a geohash to a human-readable place name, cached per geohash.

    /// localStorage key for the persisted geohash → "City, Country" map.
    _GEO_PLACE_KEY: 'nym_geohash_places',
    /// Bound on the persisted map. Entries are ~30 bytes, so this is tiny.
    _GEO_PLACE_MAX: 500,
    /// Nominatim's documented rate limit, plus a little headroom. Applies to
    /// the direct-to-Nominatim fallback, where this browser is the API client.
    _GEO_PLACE_MIN_INTERVAL_MS: 1100,
    _GEO_PLACE_RETRY_BASE_MS: 45 * 1000,
    _GEO_PLACE_RETRY_MAX_MS: 30 * 60 * 1000,
    _GEO_PLACE_MAX_ATTEMPTS: 4,

    // When a miss may be retried again.
    _geoPlaceRetryAt(key) {
        const miss = this._geoPlaceMisses && this._geoPlaceMisses.get(key);
        if (!miss) return 0;
        if (miss.attempts >= this._GEO_PLACE_MAX_ATTEMPTS) return Infinity;
        const backoff = Math.min(
            this._GEO_PLACE_RETRY_MAX_MS,
            this._GEO_PLACE_RETRY_BASE_MS * Math.pow(3, miss.attempts - 1));
        return miss.at + backoff;
    },

    _geoPlaceNoteMiss(key) {
        if (!this._geoPlaceMisses) this._geoPlaceMisses = new Map();
        const prev = this._geoPlaceMisses.get(key);
        this._geoPlaceMisses.set(key, { at: Date.now(), attempts: (prev ? prev.attempts : 0) + 1 });
        if (!this._geoPlacePending) this._geoPlacePending = new Set();
        this._geoPlacePending.add(key);
        this._scheduleGeoPlaceSweep();
    },

    // Re-resolves rows still showing a fallback and repaints them in place.
    // Without this nothing ever re-triggers a lookup, so a row that lost the
    // race once kept its coordinates until the sidebar happened to rebuild.
    _scheduleGeoPlaceSweep() {
        if (this._geoPlaceSweepTimer || !this._geoPlacePending || this._geoPlacePending.size === 0) return;
        // Only keys that can still fire automatically are worth a timer; the
        // exhausted ones stay in `pending` waiting for a forced retry (an app
        // resume), so scheduling on their behalf would spin forever.
        const anyRetryable = [...this._geoPlacePending]
            .some(k => this._geoPlaceRetryAt(k) !== Infinity);
        if (!anyRetryable) return;
        this._geoPlaceSweepTimer = setTimeout(() => {
            this._geoPlaceSweepTimer = null;
            this.refreshUnresolvedPlaces();
            this._scheduleGeoPlaceSweep();
        }, this._GEO_PLACE_RETRY_BASE_MS);
    },

    refreshUnresolvedPlaces(force) {
        const pending = this._geoPlacePending;
        if (!pending || pending.size === 0) return;
        const cache = this._loadGeohashPlaceCache();
        const now = Date.now();
        for (const key of [...pending]) {
            if (cache.has(key)) { pending.delete(key); continue; }
            const retryAt = this._geoPlaceRetryAt(key);
            if (retryAt === Infinity) {
                // Out of automatic attempts: SKIP it, don't drop it. Dropping
                // is what broke the "an explicit retry still gets one more
                // chance" contract — the sweep evicted the key, so the
                // visibilitychange retry below found an empty set and the row
                // kept its raw coordinates for the rest of the session.
                if (!force) continue;
                this._geoPlaceMisses.delete(key);
            } else if (now < retryAt && !force) {
                continue;
            }
            this._resolveGeohashPlaceName(key)
                .then(place => { if (place) this._paintPlaceEverywhere(key, place); })
                .catch(() => { });
        }
    },

    // Updates every surface showing this geohash: its sidebar row and, when it
    // is the open channel, the header.
    _paintPlaceEverywhere(key, place) {
        document.querySelectorAll(`.channel-item[data-geohash="${CSS.escape(key)}"] .channel-sub`)
            .forEach(el => this._fillLocationParts(el, place));
        if (String(this.currentGeohash || '').toLowerCase() === key) {
            const link = document.querySelector('.channel-location-link');
            if (link) this._fillLocationParts(link, place);
        }
    },
    /// Lookups allowed in flight at once when going through our proxy, which
    /// edge-caches for a day and is itself Nominatim's client. Keeps a sidebar
    /// full of geohashes resolving in a couple of round trips instead of one
    /// per second, which is what made the coordinates linger.
    _GEO_PLACE_CONCURRENCY: 4,

    _loadGeohashPlaceCache() {
        if (this._geohashPlaceCache) return this._geohashPlaceCache;
        this._geohashPlaceCache = new Map();
        try {
            const raw = localStorage.getItem(this._GEO_PLACE_KEY);
            if (raw) {
                const obj = JSON.parse(raw);
                for (const k in obj) {
                    if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
                    if (typeof obj[k] !== 'string') continue;
                    // Drop negatives written by earlier builds so a row stuck on
                    // "Unknown location" can resolve for real on this run.
                    if (obj[k] === 'Unknown location') continue;
                    this._geohashPlaceCache.set(k, obj[k]);
                }
            }
        } catch (_) { /* corrupt or unavailable — start empty */ }
        return this._geohashPlaceCache;
    },

    _saveGeohashPlaceCache() {
        if (this._geoPlaceSaveTimer) return;
        this._geoPlaceSaveTimer = setTimeout(() => {
            this._geoPlaceSaveTimer = null;
            try {
                const m = this._geohashPlaceCache;
                if (!m) return;
                let entries = [...m.entries()];
                if (entries.length > this._GEO_PLACE_MAX) {
                    // Keep the most recently resolved; Map preserves insertion order.
                    entries = entries.slice(-this._GEO_PLACE_MAX);
                    this._geohashPlaceCache = new Map(entries);
                }
                localStorage.setItem(this._GEO_PLACE_KEY, JSON.stringify(Object.fromEntries(entries)));
            } catch (_) { /* quota or private mode — cache stays in memory */ }
        }, 1000);
    },

    async _resolveGeohashPlaceName(geohash) {
        const key = String(geohash || '').toLowerCase();
        if (!key) return 'Unknown location';
        const cache = this._loadGeohashPlaceCache();
        if (cache.has(key)) return cache.get(key);
        // A recorded miss short-circuits only while its backoff is unexpired.
        if (Date.now() < this._geoPlaceRetryAt(key)) {
            return this.getGeohashLocation(geohash) || '';
        }

        // Collapse concurrent callers for the same geohash (the header and its
        // sidebar row resolve the same place on channel switch).
        if (!this._geoPlaceInflight) this._geoPlaceInflight = new Map();
        const existing = this._geoPlaceInflight.get(key);
        if (existing) return existing;

        const p = this._geoPlaceRun(async () => {
            const coords = this.decodeGeohash(geohash);
            const data = await this.fetchGeocode(coords.lat, coords.lng, 10);
            const addr = (data && data.address) || {};
            const city = addr.city || addr.town || addr.village || addr.county || '';
            const country = addr.country || '';
            return [city, country].filter(x => x).join(', ');
        })
            .then(place => {
                this._geoPlaceInflight.delete(key);
                // A geocode with no city/country is a NON-answer, not a place.
                // Caching it permanently is what left a row reading "Unknown
                // location" while the header, resolved on a luckier attempt,
                // showed the real one. Fall back to the decoded coordinates and
                // let a later attempt still find a name.
                if (!place) {
                    this._geoPlaceNoteMiss(key);
                    return this.getGeohashLocation(geohash) || '';
                }
                cache.set(key, place);
                this._saveGeohashPlaceCache();
                if (this._geoPlaceMisses) this._geoPlaceMisses.delete(key);
                if (this._geoPlacePending) this._geoPlacePending.delete(key);
                return place;
            })
            .catch(err => {
                this._geoPlaceInflight.delete(key);
                // A hard failure is a miss too, so it earns a retry instead of
                // leaving the row with nothing to trigger another attempt.
                this._geoPlaceNoteMiss(key);
                throw err;
            });
        this._geoPlaceInflight.set(key, p);
        return p;
    },

    // Run one geocode lookup under whichever rate policy actually binds.
    //
    // Through the proxy the worker is Nominatim's client and its answers are
    // edge-cached for a day, so a handful of lookups can be in flight at once
    // — that is what lets a sidebar of geohashes resolve in a round trip or
    // two instead of one per second. On the direct fallback this browser *is*
    // the API client, so requests stay strictly serialised with the documented
    // ≥1s gap between them.
    async _geoPlaceRun(fn) {
        const viaProxy = typeof this._getProxyBaseUrl === 'function' && !!this._getProxyBaseUrl();

        if (!viaProxy) {
            const mine = (this._geoPlaceQueue || Promise.resolve()).then(async () => {
                const gap = (this._geoPlaceLastAt || 0) + this._GEO_PLACE_MIN_INTERVAL_MS - Date.now();
                if (gap > 0) await new Promise(r => setTimeout(r, gap));
                this._geoPlaceLastAt = Date.now();
                return fn();
            });
            // Keep the chain alive after a rejection so one failure doesn't
            // wedge every queued lookup behind it.
            this._geoPlaceQueue = mine.catch(() => { });
            return mine;
        }

        if (!this._geoPlaceWaiters) this._geoPlaceWaiters = [];
        if (!this._geoPlaceActive) this._geoPlaceActive = 0;
        if (this._geoPlaceActive >= this._GEO_PLACE_CONCURRENCY) {
            await new Promise(resolve => this._geoPlaceWaiters.push(resolve));
        }
        this._geoPlaceActive++;
        try {
            return await fn();
        } finally {
            this._geoPlaceActive--;
            const next = this._geoPlaceWaiters.shift();
            if (next) next();
        }
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

    // Replay a channel's archived events (messages, reactions, edits) through
    // handleEvent, which dedupes. Oldest-first so edits and reaction add/remove
    // net correctly. Throttled per channel.
    async channelRestoreFromD1(channelName, opts = {}) {
        if (!channelName) return;
        return this.channelRestoreManyFromD1([channelName], opts);
    },

    // Batch several channels' archived events into one channel-get
    async channelRestoreManyFromD1(channelNames, opts = {}) {
        if (!Array.isArray(channelNames) || channelNames.length === 0) return;
        if (!this._getApiHost || !this._getApiHost()) return;
        if (!this._channelD1FetchedAt) this._channelD1FetchedAt = new Map();
        const force = !!opts.force;
        const now = Date.now();
        const names = [];
        const seen = new Set();
        for (const cn of channelNames) {
            if (!cn) continue;
            const name = String(cn).toLowerCase();
            if (seen.has(name)) continue;
            if (!force && (this._channelD1FetchedAt.get(name) || 0) > now - 60000) continue;
            seen.add(name);
            this._channelD1FetchedAt.set(name, now);
            names.push(name);
            if (names.length >= 50) break;
        }
        if (names.length === 0) return;
        let resp;
        try {
            resp = await this._storageApiStream('channel-get', { channels: names }, false);
        } catch (_) {
            return;
        }

        let applied = false;
        const applyBatch = async (batch) => {
            if (!batch.length) return;
            // Warm the formatter cache for this batch before rendering.
            if (typeof this._preformatBatch === 'function') {
                for (const ev of batch) {
                    if (typeof this.ingestEmojiTags === 'function') this.ingestEmojiTags(ev.tags);
                    if (typeof this.ingestImetaTags === 'function') this.ingestImetaTags(ev.tags);
                }
                try { await this._preformatBatch(batch.map(ev => ev && ev.content)); } catch (_) { }
            }
            for (const ev of batch) {
                if (await this._verifyRelayEventAsync(ev)) {
                    try { await this.handleEvent(ev); applied = true; } catch (_) { }
                }
            }
            // Let the browser paint this batch before the next one.
            if (typeof this._yieldToIdle === 'function') await this._yieldToIdle();
        };

        const FLUSH = 30;
        let batch = [];
        try {
            if (resp && resp._wsItems) {
                for (const ev of resp._wsItems) {
                    batch.push(ev);
                    if (batch.length >= FLUSH) { const b = batch; batch = []; await applyBatch(b); }
                }
            } else if (resp && resp.body) {
                const reader = resp.body.getReader();
                const decoder = new TextDecoder();
                let buf = '';
                while (true) {
                    const { value, done } = await reader.read();
                    if (done) break;
                    buf += decoder.decode(value, { stream: true });
                    let nl;
                    while ((nl = buf.indexOf('\n')) >= 0) {
                        const line = buf.slice(0, nl);
                        buf = buf.slice(nl + 1);
                        if (line) { try { batch.push(JSON.parse(line)); } catch (_) { } }
                    }
                    if (batch.length >= FLUSH) { const b = batch; batch = []; await applyBatch(b); }
                }
                buf += decoder.decode();
                if (buf) { try { batch.push(JSON.parse(buf)); } catch (_) { } }
            }
            await applyBatch(batch);
        } catch (_) { }

        // If the active channel was waiting on this restore (its view settled to
        // an empty note before the archive arrived), paint it now.
        if (applied) this._repaintActiveChannelIfEmpty(names);
    },

    // Force a re-render of the active channel when its container is empty but the
    // message store has been populated (e.g. by a D1 restore landing late).
    _repaintActiveChannelIfEmpty(names) {
        if (this.inPMMode || this._cvActive) return;
        const activeKey = this.currentGeohash || this.currentChannel;
        if (!activeKey || !names.includes(String(activeKey).toLowerCase())) return;
        const storageKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
        if (!this.getFilteredMessages(storageKey).length) return;
        const container = document.getElementById('messagesContainer');
        if (!container) return;
        if (container.querySelectorAll('.message[data-message-id]').length > 0) return;
        if (typeof this._clearMessageSkeleton === 'function') this._clearMessageSkeleton(container);
        container.dataset.lastChannel = '';
        this.channelDOMCache.delete(storageKey);
        this.loadChannelMessages(this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel);
    },

    switchChannel(channel, geohash = '') {
        if (this._cvActive) { this._cvOpenConversation({ type: 'channel', channel, geohash: geohash || '' }); return; }
        // In single view a thread belongs to the conversation on screen.
        if (typeof this._closeThreadViewOnSwitch === 'function') this._closeThreadViewOnSwitch();
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

        // Hydrate recent history from the D1 channel archive (best-effort). This
        // feeds the same event handler as the relays, so the two merge and sort
        // by created_at + the millisecond 'ms' tag.
        if (typeof this.channelRestoreFromD1 === 'function') {
            this.channelRestoreFromD1(geohash || channel, { force: true });
        }
        this.clearQuoteReply();
        if (this.pendingEdit) this.cancelEditMessage();

        // Close the mobile sidebar as soon as the switch is committed so the
        // UI feels responsive even while the channel loads. Anything that
        // throws later won't leave the sidebar stuck open.
        if (window.innerWidth <= 1024) {
            this.closeSidebar();
        }

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
        this._refreshFavoriteChannelBtn();

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

        // Report receipts for messages that piled up here while we were away
        if (typeof this.markVisibleChannelMessagesRead === 'function') {
            this.markVisibleChannelMessagesRead();
        }

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

        // Duplicate guard keyed on the logical channel identity (geohash || channel)
        const alreadyPresent = list &&
            Array.from(list.querySelectorAll('.channel-item'))
                .some(el => (el.dataset.geohash || el.dataset.channel) === key);

        if (!alreadyPresent) {
            this._clearSidebarSkel('channelList');
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

            // Location subtext. A geohash paints its coordinates immediately
            // (decoded locally, no network) and upgrades in place to the
            // human-readable place once the queued lookup lands; a named
            // channel just says it isn't one. Mirrors the channel header.
            const subText = isGeo
                ? (this._loadGeohashPlaceCache().get(geohash.toLowerCase()) || this.getGeohashLocation(geohash) || '')
                : 'Not a geohash';

            item.innerHTML = `
    <span class="channel-name"${locationHint}>${displayName}<span class="channel-sub"></span></span>
    <div class="channel-badges">
        <span class="unread-badge nm-hidden">0</span>
        <button class="row-menu-btn" data-action="sidebarRowMenu" aria-label="Channel menu" title="More" type="button"><svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="12" cy="5" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="12" cy="19" r="1.8"/></svg></button>
    </div>
`;

            // Upgrade the coordinates to a place name once the queued lookup
            // returns. Only fires for a geohash we have never resolved — a
            // cached one already rendered its place above and costs no request.
            // Only a resolved place name has the "City, Country" shape worth
            // splitting; raw coordinates and 'Not a geohash' stay one run.
            const cachedPlace = isGeo ? this._loadGeohashPlaceCache().get(geohash.toLowerCase()) : null;
            const subEl = item.querySelector('.channel-sub');
            if (subEl) {
                if (cachedPlace) {
                    this._fillLocationParts(subEl, cachedPlace);
                } else {
                    // Wrapped rather than set as bare text: .channel-sub is a
                    // flex container, and an anonymous flex item can't ellipsize.
                    const only = document.createElement('span');
                    only.className = 'loc-city';
                    only.textContent = subText;
                    subEl.appendChild(only);
                }
            }
            if (isGeo && !this._loadGeohashPlaceCache().has(geohash.toLowerCase())) {
                this._resolveGeohashPlaceName(geohash).then(place => {
                    if (place && subEl && subEl.isConnected) this._fillLocationParts(subEl, place);
                }).catch(() => { /* keep the coordinates */ });
            }

            // Insert before the view more button if it exists
            const viewMoreBtn = list.querySelector('.view-more-btn');
            if (viewMoreBtn) {
                list.insertBefore(item, viewMoreBtn);
            } else {
                list.appendChild(item);
            }

            this.channels.set(key, { channel, geohash });
            // The row template above hardcodes a hidden zero badge. Sidebar rows
            // are built as channels are discovered, which is often AFTER the
            // counts were restored and painted, so seed from the live count or
            // the badge stays blank until the next message in that channel.
            const unreadKey = geohash ? `#${geohash}` : channel;
            const standingUnread = (this.unreadCounts && this.unreadCounts.get(unreadKey)) || 0;
            if (standingUnread > 0) this._renderUnreadBadge(unreadKey, standingUnread);
            // updateChannelPins and applyHiddenChannels each sweep the whole
            // list with querySelectorAll, so doing them per add makes bulk
            // population O(n^2) in DOM queries. During a bulk add the caller
            // runs them ONCE at the end (_flushBulkChannelAdd).
            if (!this._bulkChannelAdd) {
                this.updateChannelPins();
                this.applyHiddenChannels();
                if (typeof this.refreshChannelAutocompleteIfOpen === 'function') {
                    this.refreshChannelAutocompleteIfOpen();
                }
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

            // Check if we need to add/update view more button. Suppressed during
            // a bulk add for the same reason as the sweeps above, and it is the
            // expensive one: _markListOverflow reads style.display on every row
            // (forcing a style recalc) and rewrites the .list-overflow class
            // across the list, so running it per add was the real O(n^2) —
            // _flushBulkChannelAdd runs it once at the end instead.
            if (!this._bulkChannelAdd) this.updateViewMoreButton('channelList');
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

        // Only rows that can actually be SEEN count toward the collapsed budget.
        // The CSS used to do this with `.list-collapsed .list-item:nth-child(n+21)`,
        // but nth-child counts every sibling — including rows already hidden by
        // the hidden/blocked-channel filter — so those silently ate slots and the
        // collapsed list showed fewer than 20. Channels with unread badges that
        // should have been on screen were pushed out of view by rows that were
        // not even rendered. Mark the overflow explicitly instead.
        const items = this._markListOverflow(listId);
        let existingBtn = list.querySelector('.view-more-btn');

        // Get current expansion state
        const isExpanded = this.listExpansionStates.get(listId) || false;

        if (items.length > this.COLLAPSED_LIST_VISIBLE) {
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
                existingBtn.textContent = `View ${this.abbreviateNumber(items.length - this.COLLAPSED_LIST_VISIBLE)} more...`;
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
        // Rows revealed by expanding have no badge yet: re-run the D1 seed so
        // they pick one up, and refresh the archive floors behind it.
        if (newState && listId === 'channelList') {
            if (typeof this._seedUnreadFromD1Activity === 'function') {
                this._seedUnreadFromD1Activity();
            }
            this._geohashActivityFetchedAt = 0;
            this._namedActivityFetchedAt = 0;
            if (typeof this.fetchGeohashActivityFromD1 === 'function') {
                this.fetchGeohashActivityFromD1().catch(() => { });
            }
            if (typeof this.fetchNamedChannelActivityFromD1 === 'function') {
                this.fetchNamedChannelActivityFromD1().catch(() => { });
            }
        }
        // Re-mark for the new state: expanding clears every overflow mark,
        // collapsing re-applies them to whatever is currently visible.
        this._markListOverflow(listId);

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
                const cap = this.COLLAPSED_LIST_VISIBLE;
                const visible = Array.from(list.querySelectorAll('.list-item:not(.search-hidden)'))
                    .filter(el => el.style.display !== 'none');
                btn.textContent = `View ${this.abbreviateNumber(visible.length - cap)} more...`;
                btn.onclick = () => this.toggleListExpansion(listId);

                // Insert after the last VISIBLE row of the collapsed window —
                // counting raw items would place it behind hidden rows.
                if (visible.length > cap && visible[cap - 1]) {
                    visible[cap - 1].insertAdjacentElement('afterend', btn);
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

    /// Cap on the joined-channel set.
    MAX_JOINED_CHANNELS: 300,

    saveUserJoinedChannels() {
        // No union with the stored copy: app.js seeds this.userJoinedChannels
        // from localStorage at construction, so the in-memory set is already
        // authoritative — merging the old list back in only undid removals,
        // which is why leaving a channel never actually shrank this.
        this._capUserJoinedChannels();
        localStorage.setItem('nym_user_joined_channels',
            JSON.stringify(Array.from(this.userJoinedChannels)));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    /// Trims the joined set to MAX_JOINED_CHANNELS, dropping least-recently-
    /// active first. Pinned channels and the current one are never dropped.
    _capUserJoinedChannels() {
        const set = this.userJoinedChannels;
        if (!set || set.size <= this.MAX_JOINED_CHANNELS) return;
        const activity = this.channelLastActivity instanceof Map
            ? this.channelLastActivity : new Map();
        const current = this.currentGeohash || this.currentChannel || '';
        const keep = (k) =>
            k === 'nymchat' || k === current ||
            (this.pinnedChannels && this.pinnedChannels.has(k));
        const at = (k) => activity.get('#' + k) || activity.get(k) || 0;

        const droppable = [...set].filter(k => !keep(k)).sort((a, b) => at(a) - at(b));
        let over = set.size - this.MAX_JOINED_CHANNELS;
        for (const k of droppable) {
            if (over-- <= 0) break;
            set.delete(k);
        }
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

    // Every caller gates this on `!message.isHistorical`, so it always means
    // "one more LIVE unread message arrived".
    updateUnreadCount(channel) {
        let count = this._recomputeUnreadCount(channel);
        // Don't let a partial local cache drop the badge below the D1 archive.
        if (this._d1Unread) count = Math.max(count, this._d1Unread.get(channel) || 0);
        // The cache may hold only a slice of what is unread, so the recompute
        // alone would stomp a larger standing count back down. A live arrival
        // means the true total is one MORE than whatever already stood.
        if (this._unreadCountStillValid(channel)) {
            count = Math.max(count, (this.unreadCounts.get(channel) || 0) + 1);
        }
        this._setUnreadCount(channel, count);
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
            if (typeof this._syncReadStateToD1 === 'function') this._syncReadStateToD1();
            if (typeof this._markConversationNotificationsSeen === 'function') {
                this._markConversationNotificationsSeen(channel, next);
            }
        }
    },

    _renderUnreadBadge(channel, count) {
        let item = null;
        const pmList = document.getElementById('pmList');
        const channelList = document.getElementById('channelList');
        if (channel.startsWith('pm-')) {
            const keys = channel.substring(3).split('-');
            const otherPubkey = keys.find(k => k !== this.pubkey) || keys[0];
            if (otherPubkey) item = pmList?.querySelector(`.pm-item[data-pubkey="${otherPubkey}"]`);
        } else if (channel.startsWith('group-')) {
            const groupId = channel.substring(6);
            item = pmList?.querySelector(`[data-group-id="${groupId}"]`);
        } else if (channel.startsWith('#')) {
            item = channelList?.querySelector(`[data-geohash="${channel.substring(1)}"]`);
        } else {
            item = channelList?.querySelector(`[data-channel="${channel}"][data-geohash=""]`);
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

        // Hidden/blocked channels first: updateViewMoreButton counts only rows
        // that are actually visible, so their display state has to be settled
        // before the collapsed budget is worked out.
        this.applyHiddenChannels();

        // Re-add view more button
        this.updateViewMoreButton('channelList');

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
        let lastTs = Math.max(Math.floor(Date.now() / 1000), this.channelLastRead.get(channel) || 0);
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
        this._setUnreadCount(channel, 0);
        // Drop the D1 archive floor — it was relative to the old lastRead and
        // would otherwise resurrect the badge on the next recompute.
        if (this._d1Unread) this._d1Unread.delete(channel);
        this._persistUnreadCounts(true);
        if (typeof this._syncReadStateToD1 === 'function') this._syncReadStateToD1();
        this._renderUnreadBadge(channel, 0);
        if (typeof this._markConversationNotificationsSeen === 'function') {
            this._markConversationNotificationsSeen(channel, lastTs);
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
            const flush = () => {
                this._persistUnreadCounts(true);
                if (typeof this._syncReadStateToD1 === 'function') this._syncReadStateToD1(true);
            };
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
            // The lastRead each stored count was computed against. Without it a
            // reload cannot tell "this count is still valid, the local cache is
            // just thin" from "this count is stale, the channel has been read",
            // and a partial cache silently wipes the badge.
            const basis = {};
            if (this._unreadBasisRead) {
                for (const [k, v] of this._unreadBasisRead) {
                    if (unread[k] !== undefined) basis[k] = v;
                }
            }
            localStorage.setItem('nym_unread_counts', JSON.stringify(unread));
            localStorage.setItem('nym_channel_activity', JSON.stringify(activity));
            localStorage.setItem('nym_channel_last_read', JSON.stringify(lastRead));
            localStorage.setItem('nym_unread_basis', JSON.stringify(basis));
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
            if (!this._unreadBasisRead) this._unreadBasisRead = new Map();
            const b = localStorage.getItem('nym_unread_basis');
            if (b) {
                const parsed = JSON.parse(b);
                for (const [k, v] of Object.entries(parsed || {})) {
                    if (typeof v === 'number' && v >= 0) this._unreadBasisRead.set(k, v);
                }
            }
        } catch (_) { }
    },

    /// Store an unread count and stamp the lastRead it was derived from.
    _setUnreadCount(channel, count) {
        if (!this._unreadBasisRead) this._unreadBasisRead = new Map();
        if (count > 0) {
            this.unreadCounts.set(channel, count);
            this._unreadBasisRead.set(channel, (this.channelLastRead && this.channelLastRead.get(channel)) || 0);
        } else {
            this.unreadCounts.delete(channel);
            this._unreadBasisRead.delete(channel);
        }
    },

    /// Newest activity we know of for [channel], in seconds. channelLastActivity
    /// is stored in ms; the cache is consulted too because activity may not have
    /// loaded yet. Returns 0 when nothing is known.
    _channelActivityTime(channel) {
        let ts = 0;
        const ms = (this.channelLastActivity && this.channelLastActivity.get(channel)) || 0;
        if (ms > 0) ts = Math.floor(ms / 1000);
        const isConv = channel.startsWith('pm-') || channel.startsWith('group-');
        const store = isConv ? this.pmMessages : this.messages;
        const cached = store && store.get(channel);
        if (Array.isArray(cached)) {
            for (const m of cached) {
                if (m && (m.created_at || 0) > ts) ts = m.created_at;
            }
        }
        return ts;
    },

    /// True when the stored count for [channel] still stands. Counts with no
    /// stamp (written before this existed, or by an older build) are treated as
    /// still valid so an upgrade does not wipe every badge once.
    _unreadCountStillValid(channel) {
        const lastRead = (this.channelLastRead && this.channelLastRead.get(channel)) || 0;
        const basis = this._unreadBasisRead && this._unreadBasisRead.get(channel);
        if (basis === undefined) return true;
        if (lastRead <= basis) return true;
        // The read mark moved past the stamp. That only means the channel was
        // actually read when it reaches the newest activity we know of. A stamp
        // taken before the read state finished loading would otherwise look
        // stale for every channel at once and wipe the whole sidebar.
        const activity = this._channelActivityTime(channel);
        if (activity <= 0) return true;
        return activity > lastRead;
    },

    recomputeAllUnreadCounts() {
        const keys = new Set();
        if (this.messages) for (const k of this.messages.keys()) keys.add(k);
        if (this.pmMessages) for (const k of this.pmMessages.keys()) keys.add(k);
        if (this.unreadCounts) for (const k of this.unreadCounts.keys()) keys.add(k);
        const d1Floor = this._d1Unread || new Map();
        for (const k of keys) {
            if (!k) continue;
            const isConv = k.startsWith('pm-') || k.startsWith('group-');
            const store = isConv ? this.pmMessages : this.messages;
            const cached = store && store.get(k);
            const persisted = this.unreadCounts.get(k) || 0;
            let count;
            if (Array.isArray(cached) && cached.length > 0) {
                count = this._recomputeUnreadCount(k);
            } else {
                // No cached messages to derive from — keep the persisted count
                count = persisted;
            }
            const floor = d1Floor.get(k);
            if (isConv) {
                // PM/group history is restored in full before recompute, so the
                // cache count is authoritative (lets cross-device reads clear).
                count = Math.max(count, floor || 0);
            } else {
                // A public channel's local cache is a PARTIAL view: D1 restore
                // brings back recent history, most of which is usually already
                // read, so recomputing from it undercounts badly. Keep the
                // stored count as a floor while it is still valid — only a read
                // (here or on another device, which advances lastRead past the
                // stamp) may lower the badge.
                count = Math.max(count, floor || 0);
                if (this._unreadCountStillValid(k)) count = Math.max(count, persisted);
            }
            this._setUnreadCount(k, count);
            this._renderUnreadBadge(k, count);
        }
        this._persistUnreadCounts(true);
    },

});
