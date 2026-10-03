Object.assign(NYM.prototype, {

    async handleChannelLink(channelInput, event) {
        if (event) {
            event.preventDefault();
            event.stopPropagation();
        }

        // Strip legacy g: prefix from old shared URLs.
        let channelName = channelInput;
        if (channelInput.startsWith('g:')) {
            channelName = channelInput.substring(2);
        }

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

        const allGeohashes = new Set();

        this.commonGeohashes.forEach(g => allGeohashes.add(g.toLowerCase()));

        this.channels.forEach((value, key) => {
            if (value.geohash && this.isValidGeohash(value.geohash)) {
                allGeohashes.add(value.geohash.toLowerCase());
            }
        });

        this.messages.forEach((msgs, channel) => {
            if (channel.startsWith('#') && this.isValidGeohash(channel.substring(1))) {
                allGeohashes.add(channel.substring(1).toLowerCase());
            }
        });

        // From D1 activity counts, so the explorer reflects channels never opened here.
        if (this._geohashD1Activity) {
            this._geohashD1Activity.forEach((_buckets, name) => {
                if (this.isValidGeohash(name)) allGeohashes.add(name.toLowerCase());
            });
        }

        const windowHours = (typeof this._geohashActiveWindowHours === 'number' && this._geohashActiveWindowHours > 0)
            ? Math.min(24, this._geohashActiveWindowHours) : 24;
        const nowSec = Math.floor(Date.now() / 1000);

        allGeohashes.forEach(geohash => {
            try {
                // 24 hourly slots aligned with the D1 activity buckets (index 0 = the most recent hour).
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

    async fetchGeohashActivityFromD1() {
        if (!this._getApiHost || !this._getApiHost()) return;
        if (typeof this._storageApiRequest !== 'function') return;
        const now = Date.now();
        if (this._geohashActivityFetchedAt && now - this._geohashActivityFetchedAt < 30000) return;
        this._geohashActivityFetchedAt = now;

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
            this._geohashActivityFetchedAt = 0;
        }
    },

    _mergeUnreadBuckets(data) {
        if (!data || !data.activity || typeof data.activity !== 'object') return;
        if (!this._d1UnreadBuckets) this._d1UnreadBuckets = new Map();
        for (const [name, buckets] of Object.entries(data.activity)) {
            if (Array.isArray(buckets)) this._d1UnreadBuckets.set(String(name).toLowerCase(), buckets);
        }
        if (data.last && typeof data.last === 'object') {
            if (!this._d1UnreadLast) this._d1UnreadLast = new Map();
            for (const [name, ts] of Object.entries(data.last)) {
                const sec = Number(ts) || 0;
                const k = String(name).toLowerCase();
                if (sec > (this._d1UnreadLast.get(k) || 0)) this._d1UnreadLast.set(k, sec);
            }
        }
        this._mergeD1Last(data.last);
    },

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

    // Precise last-activity (ms) from D1, falling back to hourly buckets (index 0 = current hour).
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

    // The relay proxy pool relies on D1 instead of relay backfill, so this is how the sidebar learns of active channels.
    _populateSidebarFromD1Activity() {
        if (!this._getApiHost()) return [];
        // Never fewer than the collapsed row budget, so every visible row can carry a badge.
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

    // Discovery activity includes spam, so seed badges from the spam-aware buckets instead.
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

    _seedUnreadFromD1Activity() {
        const act = this._d1UnreadBuckets;
        if (!act || act.size === 0 || !this.channels) return;
        if (!this.channelLastRead) this.channelLastRead = new Map();
        if (!this._d1Unread) this._d1Unread = new Map();
        const now = Math.floor(Date.now() / 1000);
        let changed = false;
        const seedKey = (unreadKey, name, buckets) => {
            if (!Array.isArray(buckets)) return;
            const lastRead = this.channelLastRead.get(unreadKey) || 0;
            // Buckets are hourly, index 0 = the hour ending now; the boundary bucket is prorated.
            const newest = (this._d1ChannelLast && this._d1ChannelLast.get(name)) || 0;
            let count = 0;
            if (!(lastRead > 0 && newest > 0 && newest <= lastRead)) {
                const windowSec = lastRead > 0 ? Math.max(0, now - lastRead) : 24 * 3600;
                const whole = Math.min(24, Math.floor(windowSec / 3600));
                for (let h = 0; h < whole; h++) count += (buckets[h] || 0);
                if (whole < 24) {
                    const fraction = (windowSec - whole * 3600) / 3600;
                    if (fraction > 0) count += Math.floor((buckets[whole] || 0) * fraction);
                }
                const unreadNewest = (this._d1UnreadLast && this._d1UnreadLast.get(name)) || 0;
                if (count === 0 && lastRead > 0 && unreadNewest > lastRead) count = 1;
            }
            // D1 is the archive of record: keep it as a floor so a stale local cache can't drop the badge.
            this._d1Unread.set(unreadKey, count);
            if (!this._d1UnreadBasis) this._d1UnreadBasis = new Map();
            this._d1UnreadBasis.set(unreadKey, lastRead);
            const standing = this.unreadCounts.get(unreadKey) || 0;
            if (count > standing) {
                this._setUnreadCount(unreadKey, count);
                this._renderUnreadBadge(unreadKey, count);
                changed = true;
            } else if (count === 0 && standing > 0 && this._recomputeUnreadCount(unreadKey) === 0) {
                this._setUnreadCount(unreadKey, 0);
                this._renderUnreadBadge(unreadKey, 0);
                changed = true;
            }
        };
        this.channels.forEach((value) => {
            if (!value) return;
            const name = String(value.geohash || value.channel || '').toLowerCase();
            if (!name) return;
            if (this.blockedChannels && this.blockedChannels.has(name)) return;
            // Never badge the conversation on screen; collapsed thread replies don't advance the read watermark.
            if (this._channelIsOnScreen('#' + name)) return;
            seedKey('#' + name, name, act.get(name));
        });
        if (changed) this._persistUnreadCounts();
    },

    // Under column view this is the focused, visible, bottom-pinned column (as in _cvMarkColumnRead).
    _channelIsOnScreen(unreadKey) {
        if (typeof document !== 'undefined' && document.hidden) return false;
        if (this._cvActive) {
            const col = typeof this._cvColumnForKey === 'function'
                ? this._cvColumnForKey(unreadKey) : null;
            return !!col && this._cvFocusedId === col.id && col._atBottom !== false;
        }
        if (this.inPMMode) return false;
        return unreadKey === (this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel);
    },

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

        if (channel.isJoined) {
            joinBtn.textContent = 'Go to Channel';
        } else {
            joinBtn.textContent = 'Join Channel';
        }

        joinBtn.onclick = () => {
            this.joinSelectedGeohash();
        };

        infoPanel.style.display = 'block';

        try {
            const data = await this.fetchGeocode(channel.lat, channel.lng, 10);

            const city = data.address.city || data.address.town || data.address.village || data.address.county || '';
            const country = data.address.country || '';

            locationInfo = [city, country].filter(x => x).join(', ')
                || this.getGeohashLocation(channel.geohash) || 'Unknown location';

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
        const baseUrl = window.location.origin + window.location.pathname;
        const channel = this.currentChannel || 'nymchat';
        const shareUrl = `${baseUrl}#${channel}`;

        document.getElementById('shareUrlInput').value = shareUrl;

        document.getElementById('shareModal').classList.add('active');

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

    // Derived from the name rather than trusting callers, many of which pass a named channel as the geohash.
    channelGeohashKey(channel, geohash) {
        const g = this.sanitizeChannelName(geohash || '');
        if (g && this.isValidGeohash(g)) return g;
        const c = this.sanitizeChannelName(channel || '');
        return (c && this.isValidGeohash(c)) ? c : '';
    },

    // Geohash channels use kind 20000 + `g` tag; named channels use kind 23333 + `d` tag.
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

        this.filterChannels(term);

        if (term.length > 0) {
            const isGeohash = this.isValidGeohash(term);
            const exists = Array.from(this.channels.keys()).some(k => k.toLowerCase() === term);

            resultsDiv.innerHTML = '';

            if (isGeohash && !exists) {
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

    sanitizeChannelName(name) {
        if (!name) return '';
        const lower = name.toLowerCase();
        if (!/^[\p{L}\p{N}]+$/u.test(lower)) return '';
        return lower;
    },

    truncateText(text, max) {
        const s = typeof text === 'string' ? text : String(text ?? '');
        if (s.length <= max) return s;
        let end = max;
        const last = s.charCodeAt(end - 1);
        if (last >= 0xD800 && last <= 0xDBFF) end--;
        return s.slice(0, end);
    },

    isValidChannelTag(value) {
        return typeof value === 'string' && value.length > 0 && !/\s/.test(value);
    },

    isValidBotChannelEvent(event) {
        if (!event || !Array.isArray(event.tags)) return false;
        if (event.kind !== 20000 && event.kind !== 23333) return true;
        const tagName = event.kind === 20000 ? 'g' : 'd';
        const tag = event.tags.find(t => Array.isArray(t) && t[0] === tagName);
        return !!tag && this.isValidChannelTag(tag[1]);
    },

    _pushNavigation(entry) {
        if (this._navigating) return;
        const current = this.navigationHistory[this.navigationIndex];
        if (current && current.type === entry.type) {
            if (entry.type === 'channel' && current.channel === entry.channel && current.geohash === entry.geohash) return;
            if (entry.type === 'pm' && current.pubkey === entry.pubkey) return;
            if (entry.type === 'group' && current.groupId === entry.groupId) return;
            if (entry.type === 'thread' && current.rootId === entry.rootId) return;
        }
        this.navigationHistory = this.navigationHistory.slice(0, this.navigationIndex + 1);
        this.navigationHistory.push(entry);
        if (this.navigationHistory.length > 50) {
            this.navigationHistory.shift();
        }
        this.navigationIndex = this.navigationHistory.length - 1;
        // Sync with browser history so mouse back/forward buttons trigger popstate.
        try {
            history.pushState({ _nym_nav: this.navigationIndex }, '');
        } catch {
            // pushState can fail, e.g. in a sandboxed iframe.
        }
        this._updateNavButtons();
    },

    navigateBack() {
        if (this.navigationIndex <= 0) return;
        this.navigationIndex--;
        this._navigateTo(this.navigationHistory[this.navigationIndex]);
        try { history.replaceState({ _nym_nav: this.navigationIndex }, ''); } catch { }
        this._updateNavButtons();
    },

    navigateForward() {
        if (this.navigationIndex >= this.navigationHistory.length - 1) return;
        this.navigationIndex++;
        this._navigateTo(this.navigationHistory[this.navigationIndex]);
        try { history.replaceState({ _nym_nav: this.navigationIndex }, ''); } catch { }
        this._updateNavButtons();
    },

    _navigateTo(entry) {
        this._navigating = true;
        try {
            if (entry.type === 'thread') {
                if (typeof this._navOpenThread === 'function') this._navOpenThread(entry);
                return;
            }
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

    _updateNavButtons() {
        const backBtn = document.getElementById('channelBackBtn');
        const fwdBtn = document.getElementById('channelForwardBtn');
        if (backBtn) backBtn.disabled = this.navigationIndex <= 0;
        if (fwdBtn) fwdBtn.disabled = this.navigationIndex >= this.navigationHistory.length - 1;
    },

    discoverChannels() {
        if (this.settings.groupChatPMOnlyMode) return;

        const allChannels = [];

        this.commonGeohashes.forEach(geohash => {
            if (!this.channels.has(geohash) && !this.userJoinedChannels.has(geohash)) {
                allChannels.push({
                    name: geohash,
                    geohash: geohash,
                    type: 'geo',
                    sortKey: Math.random()
                });
            }
        });

        allChannels.sort((a, b) => a.sortKey - b.sortKey);

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

        const wrapper = document.getElementById('channelSearchWrapper');
        if (wrapper) {
            wrapper.classList.toggle('has-value', term.length > 0);
        }

        const validChannelPattern = /^#[\p{L}\p{N}]+$/u;
        items.forEach(item => {
            // Match on the row's identity, not its text, which includes the location subline.
            const key = (item.dataset.geohash || item.dataset.channel || '').toLowerCase();
            const channelName = key ? `#${key}` : '';
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

        const wrapper = document.getElementById('userSearchWrapper');
        if (wrapper) {
            wrapper.classList.toggle('has-value', searchTerm.length > 0);
        }

        const list = document.getElementById('userListContent');

        const viewMoreBtn = list.querySelector('.view-more-btn');
        if (viewMoreBtn) {
            viewMoreBtn.style.display = searchTerm ? 'none' : 'block';
        }
    },

    togglePin(channel, geohash) {
        if ((geohash || channel) === 'nymchat') {
            this.displaySystemMessage('#nymchat is always at the top');
            return;
        }

        const key = geohash || channel;

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
            btn.title = typeof this.uiText === 'function' ? this.uiText('#nymchat is always at the top') : '#nymchat is always at the top';
            return;
        }
        btn.disabled = false;
        const isFav = this.pinnedChannels && this.pinnedChannels.has(key);
        btn.classList.toggle('active', !!isFav);
        const pinLabel = isFav ? 'Unpin channel' : 'Pin channel';
        btn.title = typeof this.uiText === 'function' ? this.uiText(pinLabel) : pinLabel;
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
            // Never leave the flag set on a throw, or later addChannel calls stop refreshing pins and hidden state.
            if (outer) this._flushBulkChannelAdd();
        }
    },

    // Runs the per-add sidebar refreshes that _bulkChannelAdd suppressed.
    _flushBulkChannelAdd() {
        this._bulkChannelAdd = false;
        this.updateChannelPins();
        this.applyHiddenChannels();
        // After applyHiddenChannels, so overflow marking sees settled display state.
        this.updateViewMoreButton('channelList');
        if (typeof this.refreshChannelAutocompleteIfOpen === 'function') {
            this.refreshChannelAutocompleteIfOpen();
        }
    },

    // Rows a collapsed list shows before "View N more...".
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

            if (item.classList.contains('search-hidden')) {
                return;
            }

            if (key === 'nymchat' || item.classList.contains('active')) {
                item.style.display = '';
                return;
            }

            if (this.hiddenChannels.has(key)) {
                item.style.display = 'none';
                return;
            }

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

        const selector = geohash ?
            `[data-geohash="${geohash}"]` :
            `[data-channel="${channel}"][data-geohash=""]`;
        const element = document.querySelector(selector);
        if (element) {
            element.remove();
        }

        this.channels.delete(key);

        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('nymchat', 'nymchat');
        }

        this.updateViewMoreButton('channelList');
    },

    unblockChannel(channel, geohash) {
        const key = geohash || channel;
        this.blockedChannels.delete(key);
        this.saveBlockedChannels();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();

        if (geohash) {
            this.addChannel(geohash, geohash);
        } else {
            this.addChannel(channel, channel);
        }

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

    _renderChannelTitle(channel, geohash) {
        const titleEl = document.getElementById('currentChannel');
        if (!titleEl) return;
        if (typeof this._hideBotControlBar === 'function') this._hideBotControlBar();
        delete titleEl.dataset.pmHeaderSig;
        delete titleEl.dataset.groupHeaderSig;

        const safeChannel = this.sanitizeChannelName(channel);
        const safeGeohash = this.channelGeohashKey(channel, geohash);
        const isGeo = !!safeGeohash;
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

            // Opens our own explorer zoomed to this cell rather than an external geohash site.
            const link = document.createElement('a');
            // The class _paintPlaceEverywhere looks the header up by.
            link.className = 'channel-location-link';
            const ghLower = safeGeohash.toLowerCase();
            link.setAttribute('href', `#${encodeURIComponent(ghLower)}`);
            link.setAttribute('title', 'Show this location on the map');
            link.addEventListener('click', (e) => {
                e.preventDefault();
                if (typeof this.showGeohashExplorer === 'function') {
                    this.showGeohashExplorer(ghLower);
                }
            });

            const cached = this._loadGeohashPlaceCache().get(ghLower);
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

    // The country part never truncates, so a narrow container ellipsizes the city instead.
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
            const only = document.createElement('span');
            only.className = 'loc-city';
            only.textContent = place;
            el.appendChild(only);
        }
    },

    // localStorage key for the persisted geohash → "City, Country" map.
    _GEO_PLACE_KEY: 'nym_geohash_places',
    _GEO_PLACE_MAX: 500,
    // Nominatim's documented rate limit plus headroom, for the direct fallback path.
    _GEO_PLACE_MIN_INTERVAL_MS: 1100,
    _GEO_PLACE_RETRY_BASE_MS: 45 * 1000,
    _GEO_PLACE_RETRY_MAX_MS: 30 * 60 * 1000,
    _GEO_PLACE_MAX_ATTEMPTS: 4,

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
    _scheduleGeoPlaceSweep() {
        if (this._geoPlaceSweepTimer || !this._geoPlacePending || this._geoPlacePending.size === 0) return;
        // Exhausted keys stay pending for a forced retry, so scheduling for them would spin forever.
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
                // Out of automatic attempts: skip it, don't drop it, so an explicit retry still gets one more chance.
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

    _paintPlaceEverywhere(key, place) {
        document.querySelectorAll(`.channel-item[data-geohash="${CSS.escape(key)}"] .channel-sub`)
            .forEach(el => this._fillLocationParts(el, place));
        if (String(this.currentGeohash || '').toLowerCase() === key) {
            const link = document.querySelector('.channel-location-link');
            if (link) this._fillLocationParts(link, place);
        }
    },
    // Concurrent lookups via our proxy, which edge-caches and is itself Nominatim's client.
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
                    // Drop negatives written by earlier builds so "Unknown location" rows can resolve.
                    if (obj[k] === 'Unknown location') continue;
                    this._geohashPlaceCache.set(k, obj[k]);
                }
            }
        } catch (_) { }
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
            } catch (_) { }
        }, 1000);
    },

    // Nominatim `zoom` granularity (3 country, 5 state, 8 county, 10 city), matched to the cell size.
    _geoPlaceZoomFor(geohash) {
        const n = (geohash || '').length;
        if (n <= 2) return 5;   // ~1250km — state/country
        if (n <= 4) return 8;   // ~40km — county
        return 10;              // ~5km and finer — city
    },

    // The center first, then the four quarter-points, since a short cell's center often falls in water.
    _geoPlaceProbePoints(geohash) {
        const zoom = this._geoPlaceZoomFor(geohash);
        let b;
        try { b = this.decodeGeohashBounds(geohash); } catch (_) { return []; }
        const [latLo, latHi] = b.lat;
        const [lngLo, lngHi] = b.lng;
        const at = (fx, fy) => ({
            lat: latLo + (latHi - latLo) * fy,
            lng: lngLo + (lngHi - lngLo) * fx,
            zoom
        });
        return [
            at(0.5, 0.5),
            at(0.25, 0.25), at(0.75, 0.25),
            at(0.25, 0.75), at(0.75, 0.75)
        ];
    },

    // "City, Country" from a reverse-geocode response, falling back to state/region, or ''.
    _geoPlaceFromAddress(data) {
        const addr = (data && data.address) || {};
        const city = addr.city || addr.town || addr.village || addr.county
            || addr.state || addr.region || addr.territory || '';
        const country = addr.country || '';
        return [city, country].filter(x => x).join(', ');
    },

    // Fetched lazily, only after a lookup fails; independent of the globe's worker copy.
    _loadWorldPlaceFeatures() {
        if (!this._worldPlaceFeatures) {
            this._worldPlaceFeatures = fetch('/data/countries-110m.json', { cache: 'force-cache' })
                .then(r => r.ok ? r.json() : null)
                .then(j => (j && window.NymGeoDecode) ? window.NymGeoDecode.decodeWorld(j) : [])
                .catch(() => []);
        }
        return this._worldPlaceFeatures;
    },

    // Label for cells the geocoder can't name, from the bundled map data instead of raw coordinates.
    async _geoPlaceDescribeRegion(geohash) {
        try {
            const feats = await this._loadWorldPlaceFeatures();
            if (!feats || !feats.length || !window.NymGeoDecode) return '';
            const c = this.decodeGeohash(geohash);
            return window.NymGeoDecode.describeRegion(feats, c.lat, c.lng) || '';
        } catch (_) { return ''; }
    },

    async _geoPlaceFallbackLabel(geohash) {
        const described = await this._geoPlaceDescribeRegion(geohash);
        return described || this.getGeohashLocation(geohash) || '';
    },

    async _resolveGeohashPlaceName(geohash) {
        const key = String(geohash || '').toLowerCase();
        if (!key) return 'Unknown location';
        const cache = this._loadGeohashPlaceCache();
        if (cache.has(key)) return cache.get(key);
        // A recorded miss short-circuits only while its backoff is unexpired.
        if (Date.now() < this._geoPlaceRetryAt(key)) {
            return this._geoPlaceFallbackLabel(geohash);
        }

        // Collapse concurrent callers for the same geohash.
        if (!this._geoPlaceInflight) this._geoPlaceInflight = new Map();
        const existing = this._geoPlaceInflight.get(key);
        if (existing) return existing;

        const p = this._geoPlaceRun(async () => {
            // Probes are sequential and, on the direct Nominatim path, spaced to respect its 1/s limit.
            const viaProxy = typeof this._getProxyBaseUrl === 'function' && !!this._getProxyBaseUrl();
            let first = true;
            for (const pt of this._geoPlaceProbePoints(geohash)) {
                if (!first && !viaProxy) {
                    const gap = (this._geoPlaceLastAt || 0) + this._GEO_PLACE_MIN_INTERVAL_MS - Date.now();
                    if (gap > 0) await new Promise(r => setTimeout(r, gap));
                }
                first = false;
                this._geoPlaceLastAt = Date.now();
                const data = await this.fetchGeocode(pt.lat, pt.lng, pt.zoom);
                const place = this._geoPlaceFromAddress(data);
                if (place) return place;
            }
            return '';
        })
            .then(place => {
                this._geoPlaceInflight.delete(key);
                // A geocode with no city/country is a non-answer; don't cache it permanently.
                if (!place) {
                    this._geoPlaceNoteMiss(key);
                    return this._geoPlaceFallbackLabel(geohash);
                }
                cache.set(key, place);
                this._saveGeohashPlaceCache();
                if (this._geoPlaceMisses) this._geoPlaceMisses.delete(key);
                if (this._geoPlacePending) this._geoPlacePending.delete(key);
                return place;
            })
            .catch(err => {
                this._geoPlaceInflight.delete(key);
                // A hard failure is a miss too, so it earns a retry.
                this._geoPlaceNoteMiss(key);
                throw err;
            });
        this._geoPlaceInflight.set(key, p);
        return p;
    },

    // Via the proxy several lookups may run at once; direct to Nominatim they are paced one per second.
    async _geoPlaceRun(fn) {
        const viaProxy = typeof this._getProxyBaseUrl === 'function' && !!this._getProxyBaseUrl();

        if (!viaProxy) {
            const mine = (this._geoPlaceQueue || Promise.resolve()).then(async () => {
                const gap = (this._geoPlaceLastAt || 0) + this._GEO_PLACE_MIN_INTERVAL_MS - Date.now();
                if (gap > 0) await new Promise(r => setTimeout(r, gap));
                this._geoPlaceLastAt = Date.now();
                return fn();
            });
            // Keep the chain alive after a rejection so one failure doesn't wedge every queued lookup.
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

    _getInputContextKey() {
        if (this.inPMMode && this.currentGroup) return 'g:' + this.currentGroup;
        if (this.inPMMode && this.currentPM) return 'p:' + this.currentPM;
        return 'c:' + (this.currentGeohash || this.currentChannel || '');
    },

    _saveCurrentDraft() {
        const input = document.getElementById('messageInput');
        if (!input || !input._richInit || !this._activeDraftKey) return;
        if (!this._inputDrafts) this._inputDrafts = new Map();
        const v = input.value || '';
        if (v.trim()) this._inputDrafts.set(this._activeDraftKey, v);
        else this._inputDrafts.delete(this._activeDraftKey);
    },

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

    // Oldest-first through handleEvent so edits and reaction add/remove net correctly; throttled per channel.
    async channelRestoreFromD1(channelName, opts = {}) {
        if (!channelName) return;
        return this.channelRestoreManyFromD1([channelName], opts);
    },

    async channelRestoreManyFromD1(channelNames, opts = {}) {
        if (!Array.isArray(channelNames) || channelNames.length === 0) return true;
        if (!this._getApiHost || !this._getApiHost()) return false;
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
        if (names.length === 0) return true;
        let resp;
        try {
            const since = Number(opts.since) > 0 ? Math.floor(Number(opts.since)) : 0;
            resp = await this._storageApiStream('channel-get', since ? { channels: names, since } : { channels: names }, false);
        } catch (_) {
            for (const name of names) this._channelD1FetchedAt.delete(name);
            return false;
        }

        let applied = false;
        const applyBatch = async (batch) => {
            if (!batch.length) return;
            if (typeof this._preformatBatch === 'function') {
                for (const ev of batch) {
                    if (typeof this.ingestEmojiTags === 'function') this.ingestEmojiTags(ev.tags);
                    if (typeof this.ingestImetaTags === 'function') this.ingestImetaTags(ev.tags);
                }
                try { await this._preformatBatch(batch.map(ev => ev && ev.content)); } catch (_) { }
            }
            for (const ev of batch) {
                if (await this._verifyRelayEventAsync(ev)) {
                    if (typeof this.recordEventProvenanceSource === 'function') {
                        this.recordEventProvenanceSource(ev, 'NYMCHAT ARCHIVE');
                    }
                    try { await this.handleEvent(ev); applied = true; } catch (_) { }
                }
            }
            if (typeof this._yieldToIdle === 'function') await this._yieldToIdle();
        };

        const FLUSH = 30;
        let batch = [];
        let completed = true;
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
        } catch (_) {
            completed = false;
        }

        // Paint the active channel if its view settled empty before the archive arrived.
        if (applied) this._repaintActiveChannelIfEmpty(names);
        return completed;
    },

    _repaintActiveChannelIfEmpty(names) {
        // Column view: repaint each channel column whose DOM has fallen behind its store.
        if (this._cvActive) {
            this._cvReconcileColumns();
            return;
        }
        if (this.inPMMode) return;
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
        if (typeof this._closeThreadViewOnSwitch === 'function') this._closeThreadViewOnSwitch();
        this._saveCurrentDraft();
        const previousChannel = this.currentChannel;
        const previousGeohash = this.currentGeohash;

        const isSameChannel = !this.inPMMode &&
            channel === previousChannel &&
            geohash === previousGeohash;

        if (isSameChannel) {
            const container = document.getElementById('messagesContainer');
            const storageKey = geohash ? `#${geohash}` : channel;
            const storedCount = (this.messages.get(storageKey) || []).length;
            const domCount = container ? container.querySelectorAll('.message[data-message-id]').length : 0;

            if (storedCount > 0 && domCount === 0) {
                if (container) container.dataset.lastChannel = '';
            } else {
                document.querySelectorAll('.channel-item').forEach(item => {
                    const isActive = item.dataset.channel === channel &&
                        item.dataset.geohash === geohash;
                    item.classList.toggle('active', isActive);
                });
                return;
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

        // Feeds the same handler as the relays, which merge by created_at plus the millisecond 'ms' tag.
        if (typeof this.channelRestoreFromD1 === 'function') {
            this.channelRestoreFromD1(geohash || channel, { force: true });
        }
        this.clearQuoteReply();
        if (this.pendingEdit) this.cancelEditMessage();

        // Close the mobile sidebar first so later throws can't leave it stuck open.
        if (window.innerWidth <= 1024) {
            this.closeSidebar();
        }

        this._pushNavigation({ type: 'channel', channel, geohash });

        this.renderTypingIndicator();

        if (previousGeohash && previousGeohash !== geohash) {
            this.cleanupGeoRelays(previousGeohash);
        }

        // Keep joined/common channels' REQs alive so background unread counts keep updating.
        const previousKey = previousGeohash || previousChannel;
        const newKey = geohash || channel;
        if (previousKey && previousKey !== newKey && typeof this.closeChannelSubscription === 'function') {
            this.closeChannelSubscription(previousKey);
        }

        // Non-blocking: the proxy buffers GEO_EVENTs for relays still connecting.
        if (geohash) {
            this.connectToGeoRelays(geohash);
            this.startGeoRelayKeepAlive(geohash);
        } else {
            this.stopGeoRelayKeepAlive();
        }

        this.ensureDefaultRelaysConnected();

        const channelType = (geohash && this.isValidGeohash(geohash)) ? 'geohash' : 'non-geohash';
        const channelKey = geohash || channel;
        this.loadChannelFromRelays(channelKey, channelType);

        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) {
            shareBtn.style.display = 'block';
        }
        this._refreshFavoriteChannelBtn();

        const displayName = geohash ? `#${geohash}` : `#${channel}`;

        this._renderChannelTitle(channel, geohash);

        if (!document.querySelector(`[data-channel="${channel}"][data-geohash="${geohash}"]`)) {
            this.addChannel(channel, geohash);
        }

        document.querySelectorAll('.channel-item').forEach(item => {
            const isActive = item.dataset.channel === channel &&
                item.dataset.geohash === geohash;
            item.classList.toggle('active', isActive);
        });

        document.querySelectorAll('.pm-item').forEach(item => {
            item.classList.remove('active');
        });

        const unreadKey = geohash ? `#${geohash}` : channel;
        this.clearUnreadCount(unreadKey);

        this.sortChannelsByActivity();

        // loadChannelMessages dedups via container.dataset.lastChannel, so always call it.
        this.loadChannelMessages(displayName);

        if (typeof this.markVisibleChannelMessagesRead === 'function') {
            this.markVisibleChannelMessagesRead();
        }

        this.updateUserList();

        if (localStorage.getItem('nym_auto_ephemeral') === 'true') {
            localStorage.setItem('nym_auto_ephemeral_channel', JSON.stringify({
                channel: channel,
                geohash: geohash
            }));
        }

        this._restoreDraftForContext();

        this.hideAutocomplete();
        this.hideChannelAutocomplete();
        this.hideEmojiAutocomplete();
        this._focusMessageInput();
    },

    _focusMessageInput() {
        if (window.innerWidth <= 768) return;
        // Only refocus the message input when focus isn't already on another control.
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

        if (key && !/^[\p{L}\p{N}]+$/u.test(key)) {
            return;
        }

        if (this.isChannelBlocked(channel, geohash)) {
            return;
        }

        // Duplicate guard keyed on the logical channel identity (geohash || channel).
        const alreadyPresent = list &&
            Array.from(list.querySelectorAll('.channel-item'))
                .some(el => (el.dataset.geohash || el.dataset.channel) === key);

        if (!alreadyPresent) {
            this._clearSidebarSkel('channelList');
            const item = document.createElement('div');
            item.className = 'channel-item list-item';
            item.dataset.channel = channel;
            // The routing key as registered (`geohash || channel` keys the store); not an "is geohash" flag.
            item.dataset.geohash = geohash;

            const isCurrentChannel = !this.inPMMode &&
                this.currentChannel === channel &&
                (this.currentGeohash || '') === geohash;
            if (isCurrentChannel) {
                item.classList.add('active');
            }

            // Display only: whether this channel has a location to show, derived via channelGeohashKey.
            const geoKey = this.channelGeohashKey(channel, geohash);
            const isGeo = !!geoKey;
            const displayName = geoKey ? `#${this.escapeHtml(geoKey)}` : `#${this.escapeHtml(channel)}`;

            let locationHint = '';
            if (isGeo) {
                const location = this.getGeohashLocation(geoKey);
                if (location) {
                    locationHint = ` title="${this.escapeHtml(location)}"`;
                }
            }

            const isPinned = this.pinnedChannels.has(key);
            if (isPinned) {
                item.classList.add('pinned');
            }

            const subText = isGeo
                ? (this._loadGeohashPlaceCache().get(geoKey) || this.getGeohashLocation(geoKey) || '')
                : 'Not a geohash';

            item.innerHTML = `
    <span class="channel-name"${locationHint}>${displayName}<span class="channel-sub"></span></span>
    <div class="channel-badges">
        <span class="unread-badge nm-hidden">0</span>
        <button class="row-menu-btn" data-action="sidebarRowMenu" aria-label="Channel menu" title="More" type="button"><svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="12" cy="5" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="12" cy="19" r="1.8"/></svg></button>
    </div>
`;

            const cachedPlace = isGeo ? this._loadGeohashPlaceCache().get(geoKey) : null;
            const subEl = item.querySelector('.channel-sub');
            if (subEl) {
                if (cachedPlace) {
                    this._fillLocationParts(subEl, cachedPlace);
                } else {
                    // Wrapped rather than bare text: an anonymous flex item can't ellipsize.
                    const only = document.createElement('span');
                    only.className = 'loc-city';
                    only.textContent = subText;
                    subEl.appendChild(only);
                }
            }
            if (isGeo && !this._loadGeohashPlaceCache().has(geoKey)) {
                this._resolveGeohashPlaceName(geoKey).then(place => {
                    if (place && subEl && subEl.isConnected) this._fillLocationParts(subEl, place);
                }).catch(() => { });
            }

            const viewMoreBtn = list.querySelector('.view-more-btn');
            if (viewMoreBtn) {
                list.insertBefore(item, viewMoreBtn);
            } else {
                list.appendChild(item);
            }

            this.channels.set(key, { channel, geohash });
            // Seed the badge from the live count, since rows are often built after counts are painted.
            const unreadKey = geohash ? `#${geohash}` : channel;
            const standingUnread = (this.unreadCounts && this.unreadCounts.get(unreadKey)) || 0;
            if (standingUnread > 0) this._renderUnreadBadge(unreadKey, standingUnread);
            // During a bulk add these per-list sweeps run once at the end (_flushBulkChannelAdd) to avoid O(n^2).
            if (!this._bulkChannelAdd) {
                this.updateChannelPins();
                this.applyHiddenChannels();
                if (typeof this.refreshChannelAutocompleteIfOpen === 'function') {
                    this.refreshChannelAutocompleteIfOpen();
                }
            }

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

            // Also suppressed during bulk add; _markListOverflow forces a style recalc per row.
            if (!this._bulkChannelAdd) this.updateViewMoreButton('channelList');
        }
    },

    updateViewMoreButton(listId) {
        const list = document.getElementById(listId);
        if (!list) return;

        const searchWrapper = list.parentElement?.querySelector('.search-input-wrapper');
        const searchInput = searchWrapper?.querySelector('.search-input');
        if (searchInput && searchInput.value.trim().length > 0) {
            const existingBtn = list.querySelector('.view-more-btn');
            if (existingBtn) {
                existingBtn.style.display = 'none';
            }
            return;
        }

        // Only visible rows count toward the collapsed budget.
        const items = this._markListOverflow(listId);
        let existingBtn = list.querySelector('.view-more-btn');

        const isExpanded = this.listExpansionStates.get(listId) || false;

        if (items.length > this.COLLAPSED_LIST_VISIBLE) {
            if (!existingBtn) {
                const btn = document.createElement('div');
                btn.className = 'view-more-btn';
                btn.onclick = () => this.toggleListExpansion(listId);
                list.appendChild(btn);
                existingBtn = btn;
            }

            if (isExpanded) {
                existingBtn.textContent = 'Show less';
                list.classList.remove('list-collapsed');
                list.classList.add('list-expanded');
            } else {
                existingBtn.textContent = `View ${this.abbreviateNumber(items.length - this.COLLAPSED_LIST_VISIBLE)} more...`;
                list.classList.add('list-collapsed');
                list.classList.remove('list-expanded');
            }

            existingBtn.style.display = 'block';
        } else {
            if (existingBtn) {
                existingBtn.remove();
            }
            list.classList.remove('list-collapsed', 'list-expanded');
            this.listExpansionStates.delete(listId);
        }
    },

    toggleListExpansion(listId) {
        const list = document.getElementById(listId);
        if (!list) return;

        let btn = list.querySelector('.view-more-btn');
        const items = list.querySelectorAll('.list-item');

        const currentState = this.listExpansionStates.get(listId) || false;
        const newState = !currentState;
        this.listExpansionStates.set(listId, newState);
        // Rows revealed by expanding have no badge yet, so re-run the D1 seed.
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
        this._markListOverflow(listId);

        if (newState) {
            list.classList.remove('list-collapsed');
            list.classList.add('list-expanded');

            if (btn) {
                btn.remove();
                btn = document.createElement('div');
                btn.className = 'view-more-btn';
                btn.textContent = 'Show less';
                btn.onclick = () => this.toggleListExpansion(listId);
                list.appendChild(btn);
            }
        } else {
            list.classList.add('list-collapsed');
            list.classList.remove('list-expanded');

            if (btn) {
                btn.remove();
                btn = document.createElement('div');
                btn.className = 'view-more-btn';
                const cap = this.COLLAPSED_LIST_VISIBLE;
                const visible = Array.from(list.querySelectorAll('.list-item:not(.search-hidden)'))
                    .filter(el => el.style.display !== 'none');
                btn.textContent = `View ${this.abbreviateNumber(visible.length - cap)} more...`;
                btn.onclick = () => this.toggleListExpansion(listId);

                // Insert after the last visible row of the collapsed window, not the raw item count.
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

        if (key === 'nymchat') {
            this.displaySystemMessage('Cannot remove the default #nymchat channel');
            return;
        }

        this.channels.delete(key);

        this.userJoinedChannels.delete(key);

        const selector = geohash ?
            `[data-geohash="${geohash}"]` :
            `[data-channel="${channel}"][data-geohash=""]`;
        const element = document.querySelector(selector);
        if (element) {
            element.remove();
        }

        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('nymchat', 'nymchat');
        }

        this.saveUserChannels();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();

        this.displaySystemMessage(`Left channel ${geohash ? '#' + geohash : '#' + channel}`);
    },

    // Cap on the joined-channel set.
    MAX_JOINED_CHANNELS: 300,

    saveUserJoinedChannels() {
        // No union with the stored copy: the in-memory set is authoritative, and merging would undo removals.
        this._capUserJoinedChannels();
        localStorage.setItem('nym_user_joined_channels',
            JSON.stringify(Array.from(this.userJoinedChannels)));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    // Drops least-recently-active first; pinned channels and the current one are never dropped.
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
                // Drop invalid legacy names and migrate the legacy default channel key.
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

        localStorage.setItem('nym_user_channels', JSON.stringify(userChannels));

        this.saveUserJoinedChannels();
    },

    addChannelToList(channel, geohash) {
        // For geohash channels, always use the geohash as the key.
        const key = geohash ? geohash : channel;

        const wasUserJoined = this.userJoinedChannels.has(key);

        if (geohash) {
            if (!this.channels.has(geohash)) {
                this.addChannel(geohash, geohash);
                if (wasUserJoined) {
                    this.userJoinedChannels.add(geohash);
                }
                this.addGeohashChannelToGlobe(geohash);
            }
        } else {
            if (!this.channels.has(channel)) {
                this.addChannel(channel, '');
                if (wasUserJoined) {
                    this.userJoinedChannels.add(channel);
                }
            }
        }
    },

    // Every caller gates this on `!message.isHistorical`, so it means one more live unread arrived.
    updateUnreadCount(channel, createdAt) {
        let count = this._recomputeUnreadCount(channel);
        // Don't let a partial local cache drop the badge below the D1 archive.
        count = Math.max(count, this._d1UnreadFloor(channel));
        // Bump the standing count only for messages newer than the read watermark, since relays replay old events.
        if (this._unreadCountStillValid(channel)) {
            const standing = this.unreadCounts.get(channel) || 0;
            const lastRead = (this.channelLastRead && this.channelLastRead.get(channel)) || 0;
            const isNew = !(createdAt > 0) || createdAt > lastRead;
            count = Math.max(count, standing + (isNew ? 1 : 0));
        }
        this._setUnreadCount(channel, count);
        this._persistUnreadCounts();
        this._renderUnreadBadge(channel, count);
        this._scheduleChannelSort();
    },

    // Re-derive without the live-arrival bump, for callers that only changed which stored messages are visible.
    refreshUnreadCount(channel) {
        let count = this._recomputeUnreadCount(channel);
        count = Math.max(count, this._d1UnreadFloor(channel));
        if (this._unreadCountStillValid(channel)) {
            count = Math.max(count, this.unreadCounts.get(channel) || 0);
        }
        this._setUnreadCount(channel, count);
        this._persistUnreadCounts();
        this._renderUnreadBadge(channel, count);
        this._scheduleChannelSort();
    },

    _d1UnreadFloor(channel) {
        if (!this._d1Unread) return 0;
        const floor = this._d1Unread.get(channel) || 0;
        if (!floor) return 0;
        const basis = this._d1UnreadBasis && this._d1UnreadBasis.get(channel);
        const lastRead = (this.channelLastRead && this.channelLastRead.get(channel)) || 0;
        if (basis !== undefined && lastRead > basis) return 0;
        return floor;
    },

    _markReadStateKnown() {
        if (this._readStateKnown !== false) return;
        this._readStateKnown = true;
        if (this._readStateKnownTimer) {
            clearTimeout(this._readStateKnownTimer);
            this._readStateKnownTimer = null;
        }
        this._seedUnreadFromD1Activity();
        this.recomputeAllUnreadCounts();
        if (typeof this._scheduleAppBadge === 'function') this._scheduleAppBadge();
    },

    _awaitReadState(ms) {
        if (this._readStateKnown === true) return;
        this._readStateKnown = false;
        if (this._readStateKnownTimer) clearTimeout(this._readStateKnownTimer);
        this._readStateKnownTimer = setTimeout(() => {
            this._readStateKnownTimer = null;
            this._markReadStateKnown();
        }, ms || 15000);
    },

    // Derived from cached messages newer than lastRead so it can't drift from the cache.
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
        const shown = this._readStateKnown === false ? 0 : count;
        const badge = item.querySelector('.unread-badge');
        if (badge) {
            badge.textContent = shown > 99 ? '99+' : shown;
            badge.style.display = shown > 0 ? 'block' : 'none';
        }
        item.classList.toggle('has-unread', shown > 0);
    },

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

        const viewMoreBtn = channelList.querySelector('.view-more-btn');

        const scrollTop = channelList.scrollTop;

        channels.sort((a, b) => {
            const aIsDefault = (a.dataset.geohash || a.dataset.channel) === 'nymchat';
            const bIsDefault = (b.dataset.geohash || b.dataset.channel) === 'nymchat';

            if (aIsDefault) return -1;
            if (bIsDefault) return 1;

            const pinAt = (el) => (typeof this._pinChannelIndex === 'function'
                ? this._pinChannelIndex(el) : (el.classList.contains('pinned') ? 0 : -1));
            const aPin = pinAt(a);
            const bPin = pinAt(b);
            if (aPin >= 0 && bPin >= 0 && aPin !== bPin) return aPin - bPin;
            if (aPin >= 0 && bPin < 0) return -1;
            if (aPin < 0 && bPin >= 0) return 1;

            const aIsActive = a.classList.contains('active');
            const bIsActive = b.classList.contains('active');

            if (aIsActive && !bIsActive) return -1;
            if (!aIsActive && bIsActive) return 1;

            const aIsGeo = !!a.dataset.geohash && a.dataset.geohash !== '' && this.isValidGeohash(a.dataset.geohash);
            const bIsGeo = !!b.dataset.geohash && b.dataset.geohash !== '' && this.isValidGeohash(b.dataset.geohash);

            if (this.settings.sortByProximity && this.userLocation) {
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

                        return distA - distB;
                    } catch (e) {
                    }
                }
            }

            // Sort by most recent activity so live channels rise regardless of stale cached unread counts.
            const aChannel = a.dataset.geohash ? `#${a.dataset.geohash}` : a.dataset.channel;
            const bChannel = b.dataset.geohash ? `#${b.dataset.geohash}` : b.dataset.channel;

            const aActivity = this.channelLastActivity.get(aChannel) || 0;
            const bActivity = this.channelLastActivity.get(bChannel) || 0;

            if (aActivity !== bActivity) return bActivity - aActivity;

            const aUnread = this.unreadCounts.get(aChannel) || 0;
            const bUnread = this.unreadCounts.get(bChannel) || 0;
            return bUnread - aUnread;
        });

        channelList.innerHTML = '';
        channels.forEach(channel => channelList.appendChild(channel));

        // Hidden/blocked state must be settled before updateViewMoreButton counts visible rows.
        this.applyHiddenChannels();

        this.updateViewMoreButton('channelList');

        const searchInput = document.getElementById('channelSearch');
        if (searchInput && searchInput.value.trim().length > 0) {
            this.filterChannels(searchInput.value);
        }

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
        // Drop the D1 floor; it was relative to the old lastRead.
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
            // The lastRead each stored count was computed against, to tell a thin cache from a stale count.
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

    // Store an unread count and stamp the lastRead it was derived from.
    _setUnreadCount(channel, count) {
        if (typeof this._scheduleAppBadge === 'function') this._scheduleAppBadge();
        if (!this._unreadBasisRead) this._unreadBasisRead = new Map();
        if (count > 0) {
            this.unreadCounts.set(channel, count);
            this._unreadBasisRead.set(channel, (this.channelLastRead && this.channelLastRead.get(channel)) || 0);
        } else {
            this.unreadCounts.delete(channel);
            this._unreadBasisRead.delete(channel);
        }
    },

    // In seconds; channelLastActivity is in ms. Returns 0 when nothing is known.
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
        if (!isConv && channel.startsWith('#') && this._d1ChannelLast) {
            const d1 = this._d1ChannelLast.get(channel.slice(1)) || 0;
            if (d1 > ts) ts = d1;
        }
        return ts;
    },

    // Unstamped counts from older builds are treated as valid so an upgrade doesn't wipe badges.
    _unreadCountStillValid(channel) {
        const lastRead = (this.channelLastRead && this.channelLastRead.get(channel)) || 0;
        const basis = this._unreadBasisRead && this._unreadBasisRead.get(channel);
        if (basis === undefined) return true;
        if (lastRead <= basis) return true;
        // Only stale once the read mark reaches the newest known activity, not merely past the stamp.
        const activity = this._channelActivityTime(channel);
        if (activity <= 0) return true;
        return activity > lastRead;
    },

    recomputeAllUnreadCounts() {
        const keys = new Set();
        if (this.messages) for (const k of this.messages.keys()) keys.add(k);
        if (this.pmMessages) for (const k of this.pmMessages.keys()) keys.add(k);
        if (this.unreadCounts) for (const k of this.unreadCounts.keys()) keys.add(k);
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
                // No cached messages to derive from; keep the persisted count.
                count = this._unreadCountStillValid(k) ? persisted : 0;
            }
            const floor = this._d1UnreadFloor(k);
            if (isConv) {
                // PM/group history is restored in full, so the cache count is authoritative.
                count = Math.max(count, floor || 0);
            } else {
                // A public channel's cache is partial, so keep the stored count as a floor until a read lowers it.
                count = Math.max(count, floor || 0);
                if (this._unreadCountStillValid(k)) count = Math.max(count, persisted);
            }
            this._setUnreadCount(k, count);
            this._renderUnreadBadge(k, count);
        }
        this._persistUnreadCounts(true);
    },

});
