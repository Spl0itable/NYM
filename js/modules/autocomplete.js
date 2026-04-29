// autocomplete.js - Emoji, channel, mention, and command autocomplete UI
// Methods are attached to NYM.prototype.

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

    showEmojiAutocomplete(search) {
        const dropdown = document.getElementById('emojiAutocomplete');

        // Build complete emoji list from all categories
        const allEmojiEntries = [];

        // Add emoji shortcodes
        Object.entries(this.emojiMap).forEach(([name, emoji]) => {
            allEmojiEntries.push({ name, emoji, priority: 1 });
        });

        // Add all categorized emojis with searchable names
        Object.entries(this.allEmojis).forEach(([category, emojis]) => {
            emojis.forEach(emoji => {
                // Try to find a name for this emoji in emojiMap
                const existingEntry = allEmojiEntries.find(e => e.emoji === emoji);
                if (!existingEntry) {
                    // Generate a searchable name from the emoji itself
                    allEmojiEntries.push({
                        name: emoji,
                        emoji,
                        priority: 2
                    });
                }
            });
        });

        // Filter based on search
        let matches = [];
        if (search === '') {
            // Show recent emojis first, then common ones
            const recentSet = new Set(this.recentEmojis);
            matches = [
                ...this.recentEmojis.map(emoji => ({
                    name: Object.entries(this.emojiMap).find(([n, e]) => e === emoji)?.[0] || emoji,
                    emoji
                })),
                ...allEmojiEntries.filter(e => !recentSet.has(e.emoji)).slice(0, 10)
            ].slice(0, 8);
        } else {
            const searchLower = search.toLowerCase();
            matches = allEmojiEntries
                .filter(entry =>
                    entry.name.toLowerCase().includes(searchLower) ||
                    entry.emoji.includes(search)
                )
                .sort((a, b) => {
                    const aName = a.name.toLowerCase();
                    const bName = b.name.toLowerCase();
                    // Exact match first
                    const aExact = aName === searchLower ? 0 : 1;
                    const bExact = bName === searchLower ? 0 : 1;
                    if (aExact !== bExact) return aExact - bExact;
                    // Prefix match before substring match
                    const aPrefix = aName.startsWith(searchLower) ? 0 : 1;
                    const bPrefix = bName.startsWith(searchLower) ? 0 : 1;
                    if (aPrefix !== bPrefix) return aPrefix - bPrefix;
                    // Then by priority (emojiMap entries before category-only)
                    if (a.priority !== b.priority) return a.priority - b.priority;
                    // Shorter names first (more likely what user wants)
                    return aName.length - bName.length;
                })
                .slice(0, 8);
        }

        if (matches.length > 0) {
            dropdown.innerHTML = matches.map(({ name, emoji }, index) => `
                <div class="emoji-item ${index === 0 ? 'selected' : ''}" data-name="${name}" data-emoji="${emoji}">
                    <span class="emoji-item-emoji">${emoji}</span>
                    <span class="emoji-item-name">:${name}:</span>
                </div>
            `).join('');
            dropdown.classList.add('active');
            this.emojiAutocompleteIndex = 0;

            // Add click handlers for each emoji item
            dropdown.querySelectorAll('.emoji-item').forEach((item, index) => {
                item.onclick = (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this.emojiAutocompleteIndex = index;
                    // Remove selected from all, add to clicked
                    dropdown.querySelectorAll('.emoji-item').forEach(i => i.classList.remove('selected'));
                    item.classList.add('selected');
                    this.selectEmojiAutocomplete();
                };
            });
        } else {
            this.hideEmojiAutocomplete();
        }
    },

    hideEmojiAutocomplete() {
        document.getElementById('emojiAutocomplete').classList.remove('active');
        this.emojiAutocompleteIndex = -1;
    },

    navigateEmojiAutocomplete(direction) {
        const items = document.querySelectorAll('.emoji-item');
        if (items.length === 0) return;

        items[this.emojiAutocompleteIndex]?.classList.remove('selected');

        this.emojiAutocompleteIndex += direction;
        if (this.emojiAutocompleteIndex < 0) this.emojiAutocompleteIndex = items.length - 1;
        if (this.emojiAutocompleteIndex >= items.length) this.emojiAutocompleteIndex = 0;

        items[this.emojiAutocompleteIndex].classList.add('selected');
        items[this.emojiAutocompleteIndex].scrollIntoView({ block: 'nearest' });
    },

    selectEmojiAutocomplete() {
        const selected = document.querySelector('.emoji-item.selected');
        if (selected) {
            const emoji = selected.dataset.emoji;
            const input = document.getElementById('messageInput');
            const value = input.value;
            const colonIndex = value.lastIndexOf(':');

            input.value = value.substring(0, colonIndex) + emoji + ' ';
            input.focus();
            this.hideEmojiAutocomplete();
            this.addToRecentEmojis(emoji);
        }
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

            if (!this.blockedUsers.has(user.nym) &&
                searchableNym.toLowerCase().includes(search.toLowerCase())) {

                // Compute effective status matching sidebar logic
                let effectiveStatus = user.status;
                if (this.isVerifiedBot(pubkey)) {
                    effectiveStatus = 'online';
                } else if (now - user.lastSeen >= activeThreshold && effectiveStatus !== 'away') {
                    effectiveStatus = 'offline';
                }

                // Create HTML version for display
                const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;

                const userEntry = {
                    nym: user.nym,
                    pubkey: pubkey,
                    displayNym: displayNym,
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
            dropdown.innerHTML = allUsers.map((user, index) => {
                const statusClass = user.effectiveStatus === 'online' ? '' :
                    user.effectiveStatus === 'away' ? ' away' : ' offline';
                const statusIndicator = `<span class="user-status${statusClass}" style="display: inline-block; margin-right: 6px; vertical-align: middle;"></span>`;

                const acAvatarSrc = this.getAvatarUrl(user.pubkey);
                const safePk = this._safePubkey(user.pubkey);
                return `
        <div class="autocomplete-item ${index === 0 ? 'selected' : ''}"
                data-nym="${this.escapeHtml(user.nym)}"
                data-pubkey="${safePk}"
                onclick="nym.selectSpecificAutocomplete('${this.escapeHtml(user.nym)}', '${safePk}')">
            <img src="${this.escapeHtml(acAvatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${safePk}.png?set=set1&size=80x80'">${statusIndicator}<strong>@${user.displayNym}</strong>
        </div>
    `;
            }).join('');
            dropdown.classList.add('active');
            this.autocompleteIndex = 0;

            // Add click handlers
            dropdown.querySelectorAll('.autocomplete-item').forEach((item, index) => {
                item.onclick = (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this.autocompleteIndex = index;
                    dropdown.querySelectorAll('.autocomplete-item').forEach(i => i.classList.remove('selected'));
                    item.classList.add('selected');
                    this.selectAutocomplete();
                };
            });
        } else {
            this.hideAutocomplete();
        }
    },

    selectSpecificAutocomplete(nym, pubkey) {
        const input = document.getElementById('messageInput');
        const value = input.value;
        const lastAtIndex = value.lastIndexOf('@');

        // Use just the base nym without suffix in the message
        input.value = value.substring(0, lastAtIndex) + '@' + nym + ' ';
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
        document.getElementById('autocompleteDropdown').classList.remove('active');
        this.autocompleteIndex = -1;
    },

    navigateAutocomplete(direction) {
        const items = document.querySelectorAll('.autocomplete-item');
        if (items.length === 0) return;

        items[this.autocompleteIndex]?.classList.remove('selected');

        this.autocompleteIndex += direction;
        if (this.autocompleteIndex < 0) this.autocompleteIndex = items.length - 1;
        if (this.autocompleteIndex >= items.length) this.autocompleteIndex = 0;

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
            dropdown.innerHTML = matches.map((ch, index) => {
                const locationName = this.isValidGeohash(ch.name) ? this.getGeohashLocation(ch.name) : '';
                const locationHtml = locationName ? `<span class="channel-ac-location">${this.escapeHtml(locationName)}</span>` : '';
                const msgCountHtml = ch.messageCount > 0 ? `<span class="channel-ac-count">${ch.messageCount} msg${ch.messageCount !== 1 ? 's' : ''}</span>` : '';
                const currentBadge = ch.isCurrent ? '<span class="channel-ac-badge">current</span>' : '';
                const joinedClass = ch.isJoined ? ' joined' : '';
                return `
        <div class="autocomplete-item channel-ac-item${joinedClass} ${index === 0 ? 'selected' : ''}"
                data-channel="${this.escapeHtml(ch.name)}"
                onclick="nym.selectChannelAutocompleteItem('${this.escapeHtml(ch.name)}')">
            <strong>#${this.escapeHtml(ch.name)}</strong>${currentBadge}${locationHtml}${msgCountHtml}
        </div>
    `;
            }).join('');
            dropdown.classList.add('active');
            this.channelAutocompleteIndex = 0;

            // Add click handlers
            dropdown.querySelectorAll('.autocomplete-item').forEach((item, index) => {
                item.onclick = (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this.channelAutocompleteIndex = index;
                    dropdown.querySelectorAll('.autocomplete-item').forEach(i => i.classList.remove('selected'));
                    item.classList.add('selected');
                    this.selectChannelAutocomplete();
                };
            });
        } else {
            this.hideChannelAutocomplete();
        }
    },

    hideChannelAutocomplete() {
        const el = document.getElementById('channelAutocomplete');
        if (el) el.classList.remove('active');
        this.channelAutocompleteIndex = -1;
    },

    navigateChannelAutocomplete(direction) {
        const items = document.querySelectorAll('#channelAutocomplete .autocomplete-item');
        if (items.length === 0) return;

        items[this.channelAutocompleteIndex]?.classList.remove('selected');

        this.channelAutocompleteIndex += direction;
        if (this.channelAutocompleteIndex < 0) this.channelAutocompleteIndex = items.length - 1;
        if (this.channelAutocompleteIndex >= items.length) this.channelAutocompleteIndex = 0;

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
