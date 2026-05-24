// autocomplete.js - Emoji, channel, mention, and command autocomplete UI

Object.assign(NYM.prototype, {

    // No longer needed - geohash links navigate directly
    insertMention(nym) {
        const input = document.getElementById('messageInput');
        const currentValue = input.value;
        const mention = `@${nym} `;

        // Insert at cursor position or append
        const start = input.selectionStart;
        const end = input.selectionEnd;

        if (start !== undefined) {
            input.value = currentValue.substring(0, start) + mention + currentValue.substring(end);
            input.selectionStart = input.selectionEnd = start + mention.length;
        } else {
            input.value = currentValue + mention;
        }

        input.focus();
    },

    _buildEmojiAutocompleteIndex() {
        const entries = [];
        const seenEmoji = new Set();
        for (const name in this.emojiMap) {
            const emoji = this.emojiMap[name];
            entries.push({ name, nameLower: name.toLowerCase(), emoji, priority: 1 });
            seenEmoji.add(emoji);
        }
        for (const category in this.allEmojis) {
            const list = this.allEmojis[category];
            for (let i = 0; i < list.length; i++) {
                const emoji = list[i];
                if (seenEmoji.has(emoji)) continue;
                seenEmoji.add(emoji);
                entries.push({ name: emoji, nameLower: emoji, emoji, priority: 2 });
            }
        }
        // Custom emoji entries are appended at search time so they stay live
        // without rebuilding the cached unicode/shortcode index.
        this._emojiAcEntries = entries;
        this._emojiAcEntriesCustomSize = 0;
        this._emojiAcShortcodeIndex = null;
    },

    invalidateEmojiAutocompleteCache() {
        this._emojiAcEntries = null;
        this._emojiAcShortcodeIndex = null;
    },

    _emojiShortcodeForEmoji(emoji) {
        if (!this._emojiAcShortcodeIndex) {
            const idx = new Map();
            for (const name in this.emojiMap) idx.set(this.emojiMap[name], name);
            this._emojiAcShortcodeIndex = idx;
        }
        return this._emojiAcShortcodeIndex.get(emoji) || emoji;
    },

    _getEmojiAutocompleteEntries() {
        if (!this._emojiAcEntries) this._buildEmojiAutocompleteIndex();
        const customSize = this.customEmojis ? this.customEmojis.size : 0;
        if (customSize !== this._emojiAcEntriesCustomSize) {
            // Drop previously-appended custom entries and re-append the current set.
            const base = this._emojiAcEntries;
            const baseLen = base.length - this._emojiAcEntriesCustomSize;
            base.length = baseLen;
            if (this.customEmojis) {
                this.customEmojis.forEach((url, shortcode) => {
                    base.push({
                        name: shortcode,
                        nameLower: shortcode.toLowerCase(),
                        emoji: `:${shortcode}:`,
                        priority: 1,
                        customUrl: url
                    });
                });
            }
            this._emojiAcEntriesCustomSize = customSize;
        }
        return this._emojiAcEntries;
    },

    showEmojiAutocomplete(search) {
        const dropdown = document.getElementById('emojiAutocomplete');
        const allEmojiEntries = this._getEmojiAutocompleteEntries();

        let matches;
        if (search === '') {
            const recentSet = new Set(this.recentEmojis);
            const recent = this.recentEmojis.map(emoji => ({
                name: this._emojiShortcodeForEmoji(emoji),
                emoji
            }));
            const fill = [];
            for (let i = 0; i < allEmojiEntries.length && fill.length < 10; i++) {
                if (!recentSet.has(allEmojiEntries[i].emoji)) fill.push(allEmojiEntries[i]);
            }
            matches = recent.concat(fill).slice(0, 8);
        } else {
            const searchLower = search.toLowerCase();
            const filtered = [];
            for (let i = 0; i < allEmojiEntries.length; i++) {
                const entry = allEmojiEntries[i];
                if (entry.nameLower.indexOf(searchLower) !== -1 ||
                    entry.emoji.indexOf(search) !== -1) {
                    filtered.push(entry);
                }
            }
            filtered.sort((a, b) => {
                const aExact = a.nameLower === searchLower ? 0 : 1;
                const bExact = b.nameLower === searchLower ? 0 : 1;
                if (aExact !== bExact) return aExact - bExact;
                const aPrefix = a.nameLower.startsWith(searchLower) ? 0 : 1;
                const bPrefix = b.nameLower.startsWith(searchLower) ? 0 : 1;
                if (aPrefix !== bPrefix) return aPrefix - bPrefix;
                if (a.priority !== b.priority) return a.priority - b.priority;
                return a.nameLower.length - b.nameLower.length;
            });
            matches = filtered.slice(0, 8);
        }

        if (matches.length > 0) {
            this._renderEmojiAutocompleteItems(dropdown, matches);
            dropdown.classList.add('active');
            this.emojiAutocompleteIndex = 0;
        } else {
            this.hideEmojiAutocomplete();
        }
    },

    _renderEmojiAutocompleteItems(dropdown, matches) {
        const frag = document.createDocumentFragment();
        matches.forEach(({ name, emoji }, index) => {
            const item = document.createElement('div');
            item.className = index === 0 ? 'emoji-item selected' : 'emoji-item';
            item.dataset.name = name;
            item.dataset.emoji = emoji;
            item.dataset.action = 'selectSpecificEmojiAutocomplete';
            const emojiSpan = document.createElement('span');
            emojiSpan.className = 'emoji-item-emoji';
            const cm = typeof emoji === 'string' && emoji.match(/^:([a-zA-Z0-9_]+):$/);
            if (cm && this.customEmojis && this.customEmojis.has(cm[1])) {
                const img = document.createElement('img');
                img.className = 'custom-emoji';
                img.src = this.getProxiedEmojiUrl(this.customEmojis.get(cm[1]));
                img.alt = emoji;
                img.loading = 'lazy';
                emojiSpan.appendChild(img);
            } else {
                emojiSpan.textContent = emoji;
            }
            const nameSpan = document.createElement('span');
            nameSpan.className = 'emoji-item-name';
            // `name` may already be a :shortcode: token (custom emoji recents) —
            // strip wrapping colons so the label isn't shown as ::shortcode::.
            nameSpan.textContent = `:${String(name).replace(/^:+|:+$/g, '')}:`;
            item.appendChild(emojiSpan);
            item.appendChild(nameSpan);
            frag.appendChild(item);
        });
        dropdown.replaceChildren(frag);
    },

    hideEmojiAutocomplete() {
        const el = document.getElementById('emojiAutocomplete');
        if (el && el.classList.contains('active')) {
            el.classList.remove('active');
            el.replaceChildren();
        }
        this.emojiAutocompleteIndex = -1;
    },

    navigateEmojiAutocomplete(direction) {
        const items = document.querySelectorAll('.emoji-item');
        if (items.length === 0) return;

        items.forEach(el => el.classList.remove('selected'));

        if (this.emojiAutocompleteIndex < 0 || this.emojiAutocompleteIndex >= items.length) {
            this.emojiAutocompleteIndex = direction > 0 ? 0 : items.length - 1;
        } else {
            this.emojiAutocompleteIndex += direction;
            if (this.emojiAutocompleteIndex < 0) this.emojiAutocompleteIndex = items.length - 1;
            if (this.emojiAutocompleteIndex >= items.length) this.emojiAutocompleteIndex = 0;
        }

        items[this.emojiAutocompleteIndex].classList.add('selected');
        items[this.emojiAutocompleteIndex].scrollIntoView({ block: 'nearest' });
    },

    selectEmojiAutocomplete() {
        const selected = document.querySelector('.emoji-item.selected');
        if (selected) this.selectSpecificEmojiAutocomplete(selected.dataset.emoji);
    },

    selectSpecificEmojiAutocomplete(emoji) {
        if (!emoji) return;
        const input = document.getElementById('messageInput');
        const value = input.value;
        const cursor = (typeof input.selectionStart === 'number')
            ? input.selectionStart
            : value.length;
        const before = value.substring(0, cursor);
        const after = value.substring(cursor);
        // Find the start of the :shortcode token at end of `before`
        const m = before.match(/:([a-z0-9_+-]*)$/i);
        const colonIndex = m ? before.length - m[0].length : before.lastIndexOf(':');
        const replaced = before.substring(0, colonIndex) + emoji + ' ';
        input.value = replaced + after;
        input.selectionStart = input.selectionEnd = replaced.length;
        input.focus();
        this.hideEmojiAutocomplete();
        this.addToRecentEmojis(emoji);
    },

    showAutocomplete(search) {
        const dropdown = document.getElementById('autocompleteDropdown');
        const currentChannelKey = this.currentGeohash || this.currentChannel;

        // Get current time for activity check
        const now = Date.now();
        const activeThreshold = 300000; // 5 minutes

        // Collect users with effective status (matching sidebar logic)
        const channelActiveUsers = [];
        const channelAwayUsers = [];
        const channelOfflineUsers = [];
        const otherActiveUsers = [];
        const otherAwayUsers = [];
        const otherOfflineUsers = [];

        this.users.forEach((user, pubkey) => {
            // Create formatted nym for matching
            const baseNym = this.stripPubkeySuffix(user.nym);
            const suffix = this.getPubkeySuffix(pubkey);
            const searchableNym = `${baseNym}#${suffix}`;

            if (!this.blockedUsers.has(pubkey) &&
                searchableNym.toLowerCase().includes(search.toLowerCase())) {

                // Compute effective status matching sidebar logic
                let effectiveStatus = user.status;
                if (this.isVerifiedBot(pubkey)) {
                    effectiveStatus = 'online';
                } else if (now - user.lastSeen >= activeThreshold && effectiveStatus !== 'away') {
                    effectiveStatus = 'offline';
                }

                const userEntry = {
                    nym: user.nym,
                    pubkey: pubkey,
                    baseNym: baseNym,
                    suffix: suffix,
                    searchableNym: searchableNym,
                    lastSeen: user.lastSeen,
                    effectiveStatus: effectiveStatus
                };

                const inCurrentChannel = user.channels && user.channels.has(currentChannelKey);

                if (inCurrentChannel) {
                    if (effectiveStatus === 'online') channelActiveUsers.push(userEntry);
                    else if (effectiveStatus === 'away') channelAwayUsers.push(userEntry);
                    else channelOfflineUsers.push(userEntry);
                } else {
                    if (effectiveStatus === 'online') otherActiveUsers.push(userEntry);
                    else if (effectiveStatus === 'away') otherAwayUsers.push(userEntry);
                    else otherOfflineUsers.push(userEntry);
                }
            }
        });

        // Sort each group alphabetically
        const sortAlpha = (a, b) => a.searchableNym.localeCompare(b.searchableNym);
        channelActiveUsers.sort(sortAlpha);
        channelAwayUsers.sort(sortAlpha);
        channelOfflineUsers.sort(sortAlpha);
        otherActiveUsers.sort(sortAlpha);
        otherAwayUsers.sort(sortAlpha);
        otherOfflineUsers.sort(sortAlpha);

        // Channel members first (active > away > offline), then others (active > away > offline)
        const allUsers = [
            ...channelActiveUsers, ...channelAwayUsers, ...channelOfflineUsers,
            ...otherActiveUsers, ...otherAwayUsers, ...otherOfflineUsers
        ].slice(0, 8);

        if (allUsers.length > 0) {
            const localStatusOff = this.settings && this.settings.showStatus === false;
            this._reconcileAutocompleteItems(dropdown, allUsers, localStatusOff);
            dropdown.classList.add('active');
            this.autocompleteIndex = 0;
        } else {
            this.hideAutocomplete();
        }
    },

    _createAutocompleteItem(safePk) {
        const item = document.createElement('div');
        item.className = 'autocomplete-item';
        item.dataset.action = 'selectSpecificAutocomplete';
        const wrap = document.createElement('span');
        wrap.className = 'user-avatar-wrap';
        const img = document.createElement('img');
        img.className = 'avatar-message';
        img.alt = '';
        img.loading = 'lazy';
        // Avatar fallback is handled by the delegated error listener in inline-bindings.js
        if (safePk) img.dataset.avatarPubkey = safePk;
        wrap.appendChild(img);
        const dot = document.createElement('span');
        dot.className = 'user-status-dot';
        wrap.appendChild(dot);
        const strong = document.createElement('strong');
        item.appendChild(wrap);
        item.appendChild(strong);
        return item;
    },

    // Reconcile dropdown rows in place so avatars don't reload (flicker) on refresh
    _reconcileAutocompleteItems(dropdown, allUsers, localStatusOff) {
        const existing = new Map();
        for (const el of dropdown.querySelectorAll('.autocomplete-item')) {
            if (el.dataset.acPubkey) existing.set(el.dataset.acPubkey, el);
        }
        let prev = null;
        allUsers.forEach((user, index) => {
            const safePk = this._safePubkey(user.pubkey);
            const statusHidden = localStatusOff ||
                !!(this.statusHiddenUsers && this.statusHiddenUsers.has(user.pubkey));
            const avatarSrc = this.getAvatarUrl(user.pubkey);

            let item = existing.get(safePk);
            if (item) {
                existing.delete(safePk);
            } else {
                item = this._createAutocompleteItem(safePk);
            }

            item.dataset.nym = user.nym;
            item.dataset.pubkey = safePk;
            item.dataset.acNym = user.nym;
            item.dataset.acPubkey = safePk;
            item.classList.toggle('selected', index === 0);

            const wrap = item.querySelector('.user-avatar-wrap');
            wrap.classList.toggle('no-status', statusHidden);
            const img = wrap.querySelector('img');
            if (img.getAttribute('src') !== avatarSrc) img.src = avatarSrc;
            const dot = wrap.querySelector('.user-status-dot');
            dot.className = `user-status-dot status-${user.effectiveStatus}`;

            const strong = item.querySelector('strong');
            const flairHtml = this.getFlairForUser(user.pubkey) || '';
            const isDev = this.isVerifiedDeveloper(user.pubkey);
            const isBot = this.isVerifiedBot(user.pubkey);
            const friendHtml = this.getFriendBadgeHtml(user.pubkey) || '';
            const label = `@${user.baseNym}#${user.suffix}|${flairHtml}|${isDev ? 'd' : ''}${isBot ? 'b' : ''}|${friendHtml ? 'f' : ''}`;
            if (strong.dataset.label !== label) {
                strong.dataset.label = label;
                strong.textContent = '';
                strong.appendChild(document.createTextNode(`@${user.baseNym}`));
                const sfx = document.createElement('span');
                sfx.className = 'nym-suffix';
                sfx.textContent = `#${user.suffix}`;
                strong.appendChild(sfx);
                if (flairHtml) {
                    const tmpl = document.createElement('template');
                    tmpl.innerHTML = flairHtml;
                    strong.appendChild(tmpl.content);
                }
                if (isDev || isBot) {
                    strong.appendChild(document.createTextNode(' '));
                    const badge = document.createElement('span');
                    badge.className = 'verified-badge';
                    badge.title = isDev ? this.verifiedDeveloper.title : 'Nymchat Bot';
                    badge.textContent = '✓';
                    strong.appendChild(badge);
                }
                if (friendHtml) {
                    const tmpl = document.createElement('template');
                    tmpl.innerHTML = friendHtml;
                    strong.appendChild(tmpl.content);
                }
            }

            const ref = prev ? prev.nextSibling : dropdown.firstChild;
            if (ref !== item) dropdown.insertBefore(item, ref);
            prev = item;
        });
        for (const el of existing.values()) el.remove();
    },

    selectSpecificAutocomplete(nym, pubkey) {
        const input = document.getElementById('messageInput');
        const value = input.value;
        const lastAtIndex = value.lastIndexOf('@');

        // Insert "@base#suffix" so the mention resolves to one specific pubkey,
        // matching keyboard selection — identically-named users aren't cross-notified.
        const baseNym = this.stripPubkeySuffix(nym);
        const suffix = this.getPubkeySuffix(pubkey);
        input.value = value.substring(0, lastAtIndex) + '@' + baseNym + '#' + suffix + ' ';
        input.focus();
        this.hideAutocomplete();
    },

    refreshAutocompleteIfOpen() {
        const dropdown = document.getElementById('autocompleteDropdown');
        if (!dropdown || !dropdown.classList.contains('active')) return;
        const input = document.getElementById('messageInput');
        if (!input) return;
        const value = input.value;
        const lastAtIndex = value.lastIndexOf('@');
        if (lastAtIndex !== -1 && (lastAtIndex === value.length - 1 ||
            value.substring(lastAtIndex).match(/^@[^\s]*$/))) {
            const search = value.substring(lastAtIndex + 1);
            this.showAutocomplete(search);
        }
    },

    hideAutocomplete() {
        const dropdown = document.getElementById('autocompleteDropdown');
        if (dropdown && dropdown.classList.contains('active')) {
            dropdown.classList.remove('active');
            dropdown.replaceChildren();
        }
        this.autocompleteIndex = -1;
    },

    navigateAutocomplete(direction) {
        const items = document.querySelectorAll('.autocomplete-item');
        if (items.length === 0) return;

        items.forEach(el => el.classList.remove('selected'));

        if (this.autocompleteIndex < 0 || this.autocompleteIndex >= items.length) {
            this.autocompleteIndex = direction > 0 ? 0 : items.length - 1;
        } else {
            this.autocompleteIndex += direction;
            if (this.autocompleteIndex < 0) this.autocompleteIndex = items.length - 1;
            if (this.autocompleteIndex >= items.length) this.autocompleteIndex = 0;
        }

        items[this.autocompleteIndex].classList.add('selected');
        items[this.autocompleteIndex].scrollIntoView({ block: 'nearest' });
    },

    selectAutocomplete() {
        const selected = document.querySelector('.autocomplete-item.selected');
        if (selected) {
            const nym = selected.dataset.nym;
            const pubkey = selected.dataset.pubkey;
            const input = document.getElementById('messageInput');
            const value = input.value;
            const lastAtIndex = value.lastIndexOf('@');

            // Use base nym with suffix
            const baseNym = this.stripPubkeySuffix(nym);
            const suffix = this.getPubkeySuffix(pubkey);
            input.value = value.substring(0, lastAtIndex) + '@' + baseNym + '#' + suffix + ' ';
            input.focus();
            this.hideAutocomplete();
        }
    },

    showChannelAutocomplete(search) {
        const dropdown = document.getElementById('channelAutocomplete');

        // Collect all known channels from multiple sources
        const channelMap = new Map(); // geohash -> { name, messageCount, isJoined, isCurrent }
        const currentKey = this.currentGeohash || this.currentChannel;

        // From messages Map (channels we have messages for)
        this.messages.forEach((msgs, key) => {
            if (key.startsWith('#')) {
                const name = key.substring(1);
                channelMap.set(name, {
                    name,
                    messageCount: msgs.length,
                    isJoined: this.userJoinedChannels.has(name) || this.channels.has(name),
                    isCurrent: name === currentKey
                });
            }
        });

        // From channels Map (sidebar channels)
        this.channels.forEach((value, key) => {
            if (!channelMap.has(key)) {
                const msgCount = (this.messages.get(`#${key}`) || []).length;
                channelMap.set(key, {
                    name: key,
                    messageCount: msgCount,
                    isJoined: true,
                    isCurrent: key === currentKey
                });
            }
        });

        // From commonGeohashes
        this.commonGeohashes.forEach(g => {
            if (!channelMap.has(g)) {
                const msgCount = (this.messages.get(`#${g}`) || []).length;
                channelMap.set(g, {
                    name: g,
                    messageCount: msgCount,
                    isJoined: this.userJoinedChannels.has(g) || this.channels.has(g),
                    isCurrent: g === currentKey
                });
            }
        });

        // Filter by search, excluding invalid channel names
        const validChannelPattern = /^[\p{L}\p{N}]+$/u;
        const searchLower = search.toLowerCase();
        let matches = Array.from(channelMap.values())
            .filter(ch => validChannelPattern.test(ch.name) && ch.name.toLowerCase().includes(searchLower));

        // Sort: current first, then joined with messages, then joined, then by name
        matches.sort((a, b) => {
            if (a.isCurrent !== b.isCurrent) return a.isCurrent ? -1 : 1;
            if (a.isJoined !== b.isJoined) return a.isJoined ? -1 : 1;
            if (a.messageCount !== b.messageCount) return b.messageCount - a.messageCount;
            return a.name.localeCompare(b.name);
        });

        matches = matches.slice(0, 8);

        if (matches.length > 0) {
            this._renderChannelAutocompleteItems(dropdown, matches);
            dropdown.classList.add('active');
            this.channelAutocompleteIndex = 0;
        } else {
            this.hideChannelAutocomplete();
        }
    },

    _renderChannelAutocompleteItems(dropdown, matches) {
        const frag = document.createDocumentFragment();
        matches.forEach((ch, index) => {
            const item = document.createElement('div');
            item.className = 'autocomplete-item channel-ac-item' +
                (ch.isJoined ? ' joined' : '') + (index === 0 ? ' selected' : '');
            item.dataset.channel = ch.name;
            item.dataset.channelName = ch.name;
            item.dataset.action = 'selectChannelAutocompleteItem';

            const strong = document.createElement('strong');
            strong.textContent = `#${ch.name}`;
            item.appendChild(strong);

            if (ch.isCurrent) {
                const badge = document.createElement('span');
                badge.className = 'channel-ac-badge';
                badge.textContent = 'current';
                item.appendChild(badge);
            }

            const locationName = this.isValidGeohash(ch.name) ? this.getGeohashLocation(ch.name) : '';
            if (locationName) {
                const loc = document.createElement('span');
                loc.className = 'channel-ac-location';
                loc.textContent = locationName;
                item.appendChild(loc);
            }

            if (ch.messageCount > 0) {
                const count = document.createElement('span');
                count.className = 'channel-ac-count';
                count.textContent = `${ch.messageCount} msg${ch.messageCount !== 1 ? 's' : ''}`;
                item.appendChild(count);
            }

            frag.appendChild(item);
        });
        dropdown.replaceChildren(frag);
    },

    hideChannelAutocomplete() {
        const el = document.getElementById('channelAutocomplete');
        if (el && el.classList.contains('active')) {
            el.classList.remove('active');
            el.replaceChildren();
        }
        this.channelAutocompleteIndex = -1;
    },

    refreshChannelAutocompleteIfOpen() {
        const dropdown = document.getElementById('channelAutocomplete');
        if (!dropdown || !dropdown.classList.contains('active')) return;
        const input = document.getElementById('messageInput');
        if (!input) return;
        const value = input.value;
        const lastHash = value.lastIndexOf('#');
        if (lastHash !== -1 && value.substring(lastHash).match(/^#[^\s]*$/)) {
            this.showChannelAutocomplete(value.substring(lastHash + 1));
        }
    },

    navigateChannelAutocomplete(direction) {
        const items = document.querySelectorAll('#channelAutocomplete .autocomplete-item');
        if (items.length === 0) return;

        items.forEach(el => el.classList.remove('selected'));

        if (this.channelAutocompleteIndex < 0 || this.channelAutocompleteIndex >= items.length) {
            this.channelAutocompleteIndex = direction > 0 ? 0 : items.length - 1;
        } else {
            this.channelAutocompleteIndex += direction;
            if (this.channelAutocompleteIndex < 0) this.channelAutocompleteIndex = items.length - 1;
            if (this.channelAutocompleteIndex >= items.length) this.channelAutocompleteIndex = 0;
        }

        items[this.channelAutocompleteIndex].classList.add('selected');
        items[this.channelAutocompleteIndex].scrollIntoView({ block: 'nearest' });
    },

    selectChannelAutocomplete() {
        const selected = document.querySelector('#channelAutocomplete .autocomplete-item.selected');
        if (selected) {
            const channel = selected.dataset.channel;
            this.insertChannelReference(channel);
        }
    },

    selectChannelAutocompleteItem(channel) {
        this.insertChannelReference(channel);
    },

    insertChannelReference(channel) {
        const input = document.getElementById('messageInput');
        const value = input.value;
        // Find the last # that triggered the autocomplete
        const lastHash = value.lastIndexOf('#');
        if (lastHash !== -1) {
            input.value = value.substring(0, lastHash) + '#' + channel + ' ';
        }
        input.focus();
        this.hideChannelAutocomplete();
        // Trigger input change to update other autocompletes
        this.handleInputChange(input.value);
    },

});
