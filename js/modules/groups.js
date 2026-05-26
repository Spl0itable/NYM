// groups.js - NIP-17 group chats: create, send, ephemeral keys, members, readers, history

Object.assign(NYM.prototype, {

    // Convert Uint8Array to hex string
    _skToHex(sk) {
        return Array.from(sk).map(b => b.toString(16).padStart(2, '0')).join('');
    },

    // Convert hex string to Uint8Array
    _hexToSk(hex) {
        const bytes = new Uint8Array(hex.length / 2);
        for (let i = 0; i < hex.length; i += 2) {
            bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
        }
        return bytes;
    },

    // Get or create the ephemeral key entry for a group.
    _getGroupEphemeralKeys(groupId) {
        if (!this.groupEphemeralKeys.has(groupId)) {
            this.groupEphemeralKeys.set(groupId, { self: null, members: {} });
        }
        return this.groupEphemeralKeys.get(groupId);
    },

    // Ensure we have a current ephemeral keypair for ourselves in this group.
    _ensureSelfEphemeralKey(groupId) {
        const NT = window.NostrTools;
        const ek = this._getGroupEphemeralKeys(groupId);
        if (!ek.self) {
            const sk = NT.generateSecretKey();
            const pk = NT.getPublicKey(sk);
            ek.self = { current: { sk, pk }, prev: [] };
        }
        return ek.self.current;
    },

    _rotateSelfEphemeralKey(groupId) {
        const NT = window.NostrTools;
        const ek = this._getGroupEphemeralKeys(groupId);
        if (!ek.self) {
            this._ensureSelfEphemeralKey(groupId);
        }
        if (ek.self.current) {
            ek.self.prev.unshift(ek.self.current);
        }
        if (ek.self.prev.length > this.EPHEMERAL_PREV_KEYS_MAX) {
            ek.self.prev = ek.self.prev.slice(0, this.EPHEMERAL_PREV_KEYS_MAX);
        }
        const nextSk = NT.generateSecretKey();
        const nextPk = NT.getPublicKey(nextSk);
        ek.self.current = { sk: nextSk, pk: nextPk };
        this._invalidateEphPkCache();
        return ek.self.current;
    },

    // Update a member's ephemeral pubkey (called when we receive a message with ephemeral_pk tag).
    // Uses timestamp ordering so out-of-order relay delivery doesn't overwrite a newer key.
    _updateMemberEphemeralKey(groupId, realPubkey, ephemeralPk, messageTs) {
        const ek = this._getGroupEphemeralKeys(groupId);
        if (!ek._memberKeyTs) ek._memberKeyTs = {};
        const prevTs = ek._memberKeyTs[realPubkey] || 0;
        if ((messageTs || 0) >= prevTs) {
            ek.members[realPubkey] = ephemeralPk;
            ek._memberKeyTs[realPubkey] = messageTs || 0;
        }
    },

    // Get the pubkey to encrypt TO for a given group member.
    // Returns their ephemeral pk if known, otherwise their real pk.
    _getEncryptionPubkey(groupId, realPubkey) {
        const ek = this.groupEphemeralKeys.get(groupId);
        if (!ek) return realPubkey;

        // Self-copy: use our own current ephemeral key so even the
        // self-addressed gift wrap doesn't reveal our real pubkey.
        if (realPubkey === this.pubkey && ek.self && ek.self.current) {
            return ek.self.current.pk;
        }

        if (ek.members[realPubkey]) {
            return ek.members[realPubkey];
        }
        return realPubkey; // fallback to real pubkey
    },

    // Collect ALL ephemeral pubkeys we own (for isForMe checks and decryption).
    // Includes current + all prev keys across all groups.
    _getAllKnownEphemeralPubkeys() {
        const pks = new Set();
        for (const [, ek] of this.groupEphemeralKeys) {
            if (ek.self) {
                pks.add(ek.self.current.pk);
                for (const prev of ek.self.prev) {
                    pks.add(prev.pk);
                }
            }
        }
        return [...pks];
    },

    // Collect ephemeral pubkeys to subscribe to on relays
    _getAllSelfEphemeralPubkeys() {
        return this._getAllKnownEphemeralPubkeys();
    },

    // Try to decrypt a gift wrap using ephemeral keys. Returns {seal, rumor} or null.
    _tryDecryptWithEphemeralKeys(event) {
        const NT = window.NostrTools;

        // Fast path: look up the ephemeral sk directly from the p tag.
        const pTag = (event.tags || []).find(t => Array.isArray(t) && t[0] === 'p' && t[1]);
        if (pTag) {
            const sk = this._lookupEphemeralSk(pTag[1]);
            if (sk) {
                try {
                    const ckWrap = NT.nip44.getConversationKey(sk, event.pubkey);
                    const sealJson = NT.nip44.decrypt(event.content, ckWrap);
                    const seal = JSON.parse(sealJson);
                    const ckSeal = NT.nip44.getConversationKey(sk, seal.pubkey);
                    const rumorJson = NT.nip44.decrypt(seal.content, ckSeal);
                    const rumor = JSON.parse(rumorJson);
                    return { seal, rumor };
                } catch (_) { }
            }
        }

        // Slow fallback: try all stored keys (current + prev window) across all groups.
        for (const [, ek] of this.groupEphemeralKeys) {
            if (!ek.self) continue;
            const keysToTry = [ek.self.current, ...ek.self.prev];
            for (const key of keysToTry) {
                try {
                    const ckWrap = NT.nip44.getConversationKey(key.sk, event.pubkey);
                    const sealJson = NT.nip44.decrypt(event.content, ckWrap);
                    const seal = JSON.parse(sealJson);
                    const ckSeal = NT.nip44.getConversationKey(key.sk, seal.pubkey);
                    const rumorJson = NT.nip44.decrypt(seal.content, ckSeal);
                    const rumor = JSON.parse(rumorJson);
                    return { seal, rumor };
                } catch (_) { }
            }
        }
        return null;
    },

    // O(1) lookup: find the ephemeral secret key for a given ephemeral pubkey.
    _lookupEphemeralSk(ephemeralPk) {
        if (!this._ephPkCache) this._rebuildEphPkCache();
        const key = this._ephPkCache.get(ephemeralPk);
        return key || null;
    },

    // Build reverse map: ephemeralPk -> sk for fast lookup.
    _rebuildEphPkCache() {
        this._ephPkCache = new Map();
        for (const [, ek] of this.groupEphemeralKeys) {
            if (!ek.self) continue;
            this._ephPkCache.set(ek.self.current.pk, ek.self.current.sk);
            for (const prev of ek.self.prev) {
                this._ephPkCache.set(prev.pk, prev.sk);
            }
        }
    },

    // Invalidate the cache (called after key rotation).
    _invalidateEphPkCache() {
        this._ephPkCache = null;
    },

    // Save ephemeral keys to localStorage.
    // Only stores counters + member pubkeys — secret keys are derived on demand.
    // Serialize an ephemeral key entry for JSON storage.
    _serializeEphemeralKeys(ek) {
        const entry = { members: ek.members };
        if (ek._memberKeyTs) entry.memberKeyTs = ek._memberKeyTs;
        if (ek.self) {
            entry.self = {
                current: { sk: this._skToHex(ek.self.current.sk), pk: ek.self.current.pk },
                prev: ek.self.prev.map(k => ({ sk: this._skToHex(k.sk), pk: k.pk }))
            };
        }
        return entry;
    },

    // Deserialize an ephemeral key entry from JSON storage.
    _deserializeEphemeralEntry(entry) {
        const ek = { members: entry.members || {} };
        if (entry.memberKeyTs) ek._memberKeyTs = entry.memberKeyTs;
        if (entry.self) {
            ek.self = {
                current: { sk: this._hexToSk(entry.self.current.sk), pk: entry.self.current.pk },
                prev: (entry.self.prev || []).map(k => ({ sk: this._hexToSk(k.sk), pk: k.pk }))
            };
        } else {
            ek.self = null;
        }
        return ek;
    },

    // Merge synced ephemeral keys into the local set for a group.
    // Handles multi-device: both devices accumulate all keys so either
    // can decrypt messages addressed to any device's ephemeral key.
    _mergeEphemeralKeys(groupId, syncedEntry) {
        const synced = this._deserializeEphemeralEntry(syncedEntry);
        const local = this.groupEphemeralKeys.get(groupId);

        if (!local) {
            // No local keys — just use synced
            this.groupEphemeralKeys.set(groupId, synced);
            this._invalidateEphPkCache();
            return;
        }

        // Merge member keys using timestamps: keep whichever device saw
        // the more recent message from each member.
        if (!local._memberKeyTs) local._memberKeyTs = {};
        const syncedTs = synced._memberKeyTs || {};
        if (synced.members) {
            for (const [realPk, ephPk] of Object.entries(synced.members)) {
                const localTs = local._memberKeyTs[realPk] || 0;
                const remoteTs = syncedTs[realPk] || 0;
                if (!local.members[realPk] || remoteTs > localTs) {
                    local.members[realPk] = ephPk;
                    local._memberKeyTs[realPk] = remoteTs;
                }
            }
        }

        // Merge self keys: collect all secret keys from both devices so
        // we can decrypt messages sent to any of our ephemeral pubkeys.
        if (synced.self) {
            if (!local.self) {
                local.self = synced.self;
            } else {
                // Collect all known pks to deduplicate
                const knownPks = new Set();
                knownPks.add(local.self.current.pk);
                for (const k of local.self.prev) knownPks.add(k.pk);

                // Add synced current if we don't have it
                if (!knownPks.has(synced.self.current.pk)) {
                    local.self.prev.push(synced.self.current);
                    knownPks.add(synced.self.current.pk);
                }

                for (const k of synced.self.prev) {
                    if (!knownPks.has(k.pk)) {
                        local.self.prev.push(k);
                        knownPks.add(k.pk);
                    }
                }
                if (local.self.prev.length > this.EPHEMERAL_PREV_KEYS_MAX) {
                    local.self.prev = local.self.prev.slice(0, this.EPHEMERAL_PREV_KEYS_MAX);
                }
            }
        }

        this._invalidateEphPkCache();
    },

    // Save ephemeral keys to localStorage.
    _saveEphemeralKeys() {
        if (!this.pubkey) return;
        try {
            const data = {};
            for (const [groupId, ek] of this.groupEphemeralKeys) {
                data[groupId] = this._serializeEphemeralKeys(ek);
            }
            localStorage.setItem(`nym_ephemeral_keys_${this.pubkey}`, JSON.stringify(data));
        } catch (_) { }
    },

    // Load ephemeral keys from localStorage
    _loadEphemeralKeys() {
        if (!this.pubkey) return;
        try {
            const raw = localStorage.getItem(`nym_ephemeral_keys_${this.pubkey}`);
            if (!raw) return;
            const data = JSON.parse(raw);
            const cap = this.EPHEMERAL_PREV_KEYS_MAX || 30;
            let trimmed = false;
            for (const [groupId, entry] of Object.entries(data)) {
                const ek = this._deserializeEphemeralEntry(entry);
                if (ek.self && Array.isArray(ek.self.prev) && ek.self.prev.length > cap) {
                    ek.self.prev = ek.self.prev.slice(0, cap);
                    trimmed = true;
                }
                this.groupEphemeralKeys.set(groupId, ek);
            }
            this._invalidateEphPkCache();
            if (trimmed) this._saveEphemeralKeys();
        } catch (_) { }
    },

    getGroupConversationKey(groupId) {
        return `group-${groupId}`;
    },

    // Persist all known groups to localStorage so Nostr users see them after refresh
    _saveGroupConversations() {
        if (!this.pubkey) return;
        try {
            const data = {};
            for (const [groupId, group] of this.groupConversations) {
                // Snapshot kind 0 profile data for each member so nicknames and
                // avatars can be restored immediately without waiting for relays.
                const memberProfiles = {};
                if (group.members) {
                    for (const pk of group.members) {
                        const user = this.users.get(pk);
                        const avatar = this.userAvatars?.get(pk);
                        if (user || avatar) {
                            memberProfiles[pk] = {};
                            if (user?.nym) memberProfiles[pk].name = user.nym;
                            if (avatar) memberProfiles[pk].picture = avatar;
                        }
                    }
                }
                data[groupId] = {
                    name: group.name,
                    members: group.members,
                    memberProfiles,
                    lastMessageTime: group.lastMessageTime,
                    createdBy: group.createdBy,
                    mods: Array.isArray(group.mods) ? group.mods : [],
                    banned: Array.isArray(group.banned) ? group.banned : [],
                    modLog: Array.isArray(group.modLog) ? group.modLog.slice(-50) : [],
                };
            }
            localStorage.setItem(`nym_groups_${this.pubkey}`, JSON.stringify(data));
        } catch (_) { }
    },

    // Role helpers
    _isGroupOwner(groupId, pubkey) {
        const g = this.groupConversations.get(groupId);
        return !!(g && g.createdBy && g.createdBy === pubkey);
    },
    _isGroupMod(groupId, pubkey) {
        const g = this.groupConversations.get(groupId);
        return !!(g && Array.isArray(g.mods) && g.mods.includes(pubkey));
    },
    _canModerate(groupId, pubkey) {
        return this._isGroupOwner(groupId, pubkey) || this._isGroupMod(groupId, pubkey);
    },
    _appendModLog(group, entry) {
        if (!group) return;
        if (!Array.isArray(group.modLog)) group.modLog = [];
        group.modLog.push({ ...entry, ts: Math.floor(Date.now() / 1000) });
        if (group.modLog.length > 50) group.modLog = group.modLog.slice(-50);
    },

    // Persist left-group IDs so they survive reload. Uses a per-pubkey key when
    // pubkey is available, plus a global fallback for early init.
    _saveLeftGroups() {
        const json = JSON.stringify([...this.leftGroups]);
        try { localStorage.setItem('nym_left_groups', json); } catch { }
        if (this.pubkey) {
            try { localStorage.setItem(`nym_left_groups_${this.pubkey}`, json); } catch { }
        }
    },

    _loadLeftGroups() {
        if (!this.pubkey) return;
        try {
            const perUser = localStorage.getItem(`nym_left_groups_${this.pubkey}`);
            if (perUser) {
                const arr = JSON.parse(perUser);
                for (const gid of arr) this.leftGroups.add(gid);
            }
            if (!this.leftGroupTimes) this.leftGroupTimes = new Map();
            const times = localStorage.getItem('nym_left_group_times');
            if (times) {
                const obj = JSON.parse(times);
                for (const [k, v] of Object.entries(obj || {})) {
                    if (typeof v === 'number' && v > 0) this.leftGroupTimes.set(k, v);
                }
            }
        } catch (_) { }
    },

    // Restore groups saved by _saveGroupConversations (called after pubkey is known)
    _loadGroupConversations() {
        if (!this.pubkey) return;
        try {
            const raw = localStorage.getItem(`nym_groups_${this.pubkey}`);
            if (!raw) return;
            const data = JSON.parse(raw);
            for (const [groupId, group] of Object.entries(data)) {
                // Pre-populate users Map and avatar cache from saved kind 0 profile
                // snapshots so nicknames/avatars display immediately on restore
                // instead of showing "nym" while waiting for relay profile fetches.
                if (group.memberProfiles) {
                    for (const [pk, profile] of Object.entries(group.memberProfiles)) {
                        if (profile.name && !this.users.has(pk)) {
                            this.users.set(pk, {
                                nym: profile.name,
                                pubkey: pk,
                                lastSeen: 0,
                                status: 'offline',
                                channels: new Set()
                            });
                        }
                        if (profile.picture && this.userAvatars && !this.userAvatars.has(pk)) {
                            this.userAvatars.set(pk, profile.picture);
                        }
                    }
                }
                if (!this.groupConversations.has(groupId)) {
                    this.addGroupConversation(groupId, group.name, group.members || [], group.lastMessageTime || Date.now(), { createdBy: group.createdBy });
                    // Restore role data which addGroupConversation doesn't merge
                    const g = this.groupConversations.get(groupId);
                    if (g) {
                        if (group.createdBy) g.createdBy = group.createdBy;
                        g.mods = Array.isArray(group.mods) ? [...group.mods] : [];
                        g.banned = Array.isArray(group.banned) ? [...group.banned] : [];
                        g.modLog = Array.isArray(group.modLog) ? [...group.modLog] : [];
                    }
                }
            }
        } catch (_) { }
    },

    // Handle a group reaction (kind 7 gift-wrapped to the group)
    handleGroupReaction(rumor, senderPubkey) {
        const eTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'e' && t[1]);
        if (!eTag) return;
        const messageId = eTag[1]; // nymMessageId of the target message
        const emoji = rumor.content;
        if (!emoji) return;

        const actionTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'action');
        const isRemoval = actionTag && actionTag[1] === 'remove';

        // Timestamp-based dedup for out-of-order delivery
        const actionKey = `${messageId}:${emoji}:${senderPubkey}`;
        const lastAction = this.reactionLastAction.get(actionKey);
        const eventTs = rumor.created_at || 0;
        if (lastAction && lastAction.ts > eventTs) return;
        this.reactionLastAction.set(actionKey, { action: isRemoval ? 'remove' : 'add', ts: eventTs });

        if (isRemoval) {
            const messageReactions = this.reactions.get(messageId);
            if (messageReactions && messageReactions.has(emoji)) {
                messageReactions.get(emoji).delete(senderPubkey);
                if (messageReactions.get(emoji).size === 0) messageReactions.delete(emoji);
                if (messageReactions.size === 0) this.reactions.delete(messageId);
            }
            this.updateMessageReactions(messageId);
            return;
        }

        const reactorNym = this.getNymFromPubkey(senderPubkey);
        if (!this.reactions.has(messageId)) this.reactions.set(messageId, new Map());
        const messageReactions = this.reactions.get(messageId);
        if (!messageReactions.has(emoji)) messageReactions.set(emoji, new Map());
        messageReactions.get(emoji).set(senderPubkey, reactorNym);
        this.updateMessageReactions(messageId);

        if (senderPubkey !== this.pubkey) {
            const groupTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'g' && t[1]);
            const groupId = groupTag ? groupTag[1] : null;
            if (groupId && typeof this._notifyGroupReactionToOurMessage === 'function') {
                this._notifyGroupReactionToOurMessage(messageId, emoji, senderPubkey, groupId, rumor);
            }
        }
    },

    // Handle incoming group message (rumor with 'g' tag)
    async handleGroupMessage(rumor, event, senderPubkey, isOwn) {
        const groupTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'g' && t[1]);
        if (!groupTag) return;
        const groupId = groupTag[1];
        const groupConvKey = this.getGroupConversationKey(groupId);

        if (typeof this.ingestImetaTags === 'function') {
            this.ingestImetaTags(rumor.tags);
        }

        // Extract sender's next ephemeral pubkey from the rumor (timing-attack mitigation).
        // When present, future messages to this sender will be encrypted to this key.
        if (!isOwn) {
            const ephTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'ephemeral_pk' && t[1]);
            if (ephTag) {
                this._updateMemberEphemeralKey(groupId, senderPubkey, ephTag[1], rumor.created_at || 0);
                this._saveEphemeralKeys();
                this._debouncedNostrSettingsSave(15000);
            }
        }

        // Filter group invites based on acceptPMs setting
        if (!isOwn && this.settings.acceptPMs !== 'enabled' && !this.groupConversations.has(groupId)) {
            if (this.settings.acceptPMs === 'disabled') return;
            if (this.settings.acceptPMs === 'friends' && !this.isFriend(senderPubkey)) return;
        }

        // Drop all messages from blocked senders, including group invites.
        if (!isOwn && this.blockedUsers.has(senderPubkey)) {
            return;
        }

        // Determine message type early so we can decide whether to drop it
        const typeTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'type' && t[1]);
        const msgType = typeTag ? typeTag[1] : null;

        // Drop messages for groups the user has left, unless it's a reinvite or unban
        // newer than when we left. Stale backlog never resurrects a deleted group.
        if (this.leftGroups.has(groupId)) {
            const leftAt = this.leftGroupTimes?.get(groupId) || 0;
            const msgTs = Math.floor(rumor.created_at || 0);
            const isReinviteType = (msgType === 'group-invite' || msgType === 'group-add-member' || msgType === 'group-unban');
            if (!isReinviteType || msgTs <= leftAt) {
                return;
            }
        }

        // group-unban: owner notified us that we were unbanned. Show a notification.
        if (typeTag && typeTag[1] === 'group-unban') {
            if (isOwn) return;
            if (this.blockedUsers.has(senderPubkey)) return;
            if (!this.users.has(senderPubkey)) await this.fetchProfileDirect(senderPubkey);
            const actorName = this.getNymFromPubkey(senderPubkey);
            const unbanTsSec = Math.floor(rumor.created_at) || Math.floor(Date.now() / 1000);
            const unbanIsHistorical = (Math.floor(Date.now() / 1000) - unbanTsSec) > 10;
            const unbanTitle = `Unbanned from ${groupName}`;
            const unbanBody = `${actorName} unbanned you from "${groupName}". You may be re-invited.`;
            const unbanChannelInfo = { type: 'group', groupId, id: groupConvKey, pubkey: senderPubkey, eventId: event.id };
            if (!unbanIsHistorical) {
                this.showNotification(unbanTitle, unbanBody, unbanChannelInfo, unbanTsSec * 1000);
            } else {
                this._addNotificationToHistory(unbanTitle, unbanBody, unbanChannelInfo, unbanTsSec * 1000);
            }
            return;
        }

        // Route group reactions (kind 7) before regular message processing
        if (rumor.kind === 7) {
            this.handleGroupReaction(rumor, senderPubkey);
            return;
        }

        // Handle key-resync from older clients. The ephemeral_pk was already
        // extracted above; just silently consume so it doesn't display as a message.
        if (typeTag && typeTag[1] === 'key-resync') {
            return;
        }

        // Handle group-leave: remove the member from local state and show system message
        if (typeTag && typeTag[1] === 'group-leave' && !isOwn) {
            const group = this.groupConversations.get(groupId);
            if (group) {
                group.members = group.members.filter(pk => pk !== senderPubkey);
                this.groupConversations.set(groupId, group);
                this.updateGroupConversationUI(groupId);
                this._saveGroupConversations();
                this._debouncedNostrSettingsSave();
                if (this.inPMMode && this.currentGroup === groupId) {
                    this.openGroup(groupId); // refresh header member count
                    // Fetch profile so nickname displays correctly
                    if (!this.users.has(senderPubkey)) await this.fetchProfileDirect(senderPubkey);
                    this.displaySystemMessage(`${this.getNymFromPubkey(senderPubkey)} left the group.`);
                }
            }
            return;
        }

        // Extract group name from 'subject' tag
        const subjectTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'subject' && t[1]);
        const groupName = subjectTag ? subjectTag[1] : 'Group';

        // group-invite: the rumor author is always the group creator — persist this so
        // non-creating members know who owns the group without relying on local state.
        if (typeTag && typeTag[1] === 'group-invite') {
            if (this.leftGroups.has(groupId)) {
                this.leftGroups.delete(groupId);
                if (this.leftGroupTimes) this.leftGroupTimes.delete(groupId);
                this._saveLeftGroups();
                try { localStorage.setItem('nym_left_group_times', JSON.stringify(Object.fromEntries(this.leftGroupTimes || new Map()))); } catch { }
                this._debouncedNostrSettingsSave();
            }
            // Pre-create the group entry with createdBy set BEFORE _addGroupMessage
            // runs later in this handler. Otherwise the merge-branch in
            // addGroupConversation creates the entry with createdBy: null first.
            const inviteMembers = (rumor.tags || [])
                .filter(t => Array.isArray(t) && t[0] === 'p' && t[1])
                .map(t => t[1]);
            const inviteMods = (rumor.tags || [])
                .filter(t => Array.isArray(t) && t[0] === 'mod' && t[1])
                .map(t => t[1]);
            if (!this.groupConversations.has(groupId)) {
                this.addGroupConversation(
                    groupId,
                    groupName,
                    inviteMembers,
                    (rumor.created_at || Math.floor(Date.now() / 1000)) * 1000,
                    { createdBy: senderPubkey, mods: inviteMods }
                );
            }
            const grp = this.groupConversations.get(groupId);
            if (grp && !grp.createdBy) {
                grp.createdBy = senderPubkey;
            }
            if (grp && inviteMods.length > 0 && (!Array.isArray(grp.mods) || grp.mods.length === 0)) {
                grp.mods = [...inviteMods];
            }
            if (grp) {
                this._saveGroupConversations();
                this._debouncedNostrSettingsSave();
            }

            // Send notification for group invites
            if (!isOwn && !this.blockedUsers.has(senderPubkey)) {
                // Fetch profile so the inviter's nickname displays correctly
                if (!this.users.has(senderPubkey)) await this.fetchProfileDirect(senderPubkey);
                const inviterName = this.getNymFromPubkey(senderPubkey);
                const inviteBody = rumor.content || `You've been added to group "${groupName}"`;
                const inviteTsSec = Math.floor(rumor.created_at) || Math.floor(Date.now() / 1000);
                const inviteAgeMs = Date.now() - (inviteTsSec * 1000);
                const isHistorical = this._isGiftWrapBacklog() || inviteAgeMs > 30000;
                const groupConvKeyForNotif = this.getGroupConversationKey(groupId);
                const inviteChannelInfo = {
                    type: 'group',
                    groupId,
                    id: groupConvKeyForNotif,
                    pubkey: senderPubkey,
                    eventId: event.id
                };
                if (!isHistorical) {
                    this.showNotification(`Group invite: ${groupName}`, inviteBody, inviteChannelInfo, inviteTsSec * 1000);
                } else {
                    this._addNotificationToHistory(`Group invite: ${groupName}`, inviteBody, inviteChannelInfo, inviteTsSec * 1000);
                }
            }

            // Fall through to display the invite message inline
        }

        // group-add-member: show as system message, not a chat bubble.
        if (typeTag && typeTag[1] === 'group-add-member') {
            if (this.leftGroups.has(groupId)) {
                this.leftGroups.delete(groupId);
                if (this.leftGroupTimes) this.leftGroupTimes.delete(groupId);
                this._saveLeftGroups();
                try { localStorage.setItem('nym_left_group_times', JSON.stringify(Object.fromEntries(this.leftGroupTimes || new Map()))); } catch { }
            }
            const memberPubkeys = (rumor.tags || [])
                .filter(t => Array.isArray(t) && t[0] === 'p' && t[1])
                .map(t => t[1]);
            const ownerTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'owner' && t[1]);
            const addMods = (rumor.tags || [])
                .filter(t => Array.isArray(t) && t[0] === 'mod' && t[1])
                .map(t => t[1]);
            // Determine who was added by comparing new member list with existing group
            const existingGroup = this.groupConversations.get(groupId);
            const existingMembers = existingGroup ? new Set(existingGroup.members) : new Set();
            const newMembers = memberPubkeys.filter(pk => !existingMembers.has(pk));
            this.addGroupConversation(
                groupId,
                groupName,
                memberPubkeys,
                (rumor.created_at || Math.floor(Date.now() / 1000)) * 1000,
                { createdBy: ownerTag ? ownerTag[1] : undefined, mods: addMods }
            );
            const grpAdd = this.groupConversations.get(groupId);
            if (grpAdd && addMods.length > 0 && (!Array.isArray(grpAdd.mods) || grpAdd.mods.length === 0)) {
                grpAdd.mods = [...addMods];
            }
            this._saveGroupConversations();
            this._debouncedNostrSettingsSave();
            if (!isOwn && this.inPMMode && this.currentGroup === groupId) {
                this.openGroup(groupId);
                // Reconstruct the system message locally with fresh nicknames
                // instead of using rumor.content which may have stale names
                const fetchPromises = [];
                for (const pk of newMembers) {
                    if (!this.users.has(pk)) fetchPromises.push(this.fetchProfileDirect(pk));
                }
                if (!this.users.has(senderPubkey)) fetchPromises.push(this.fetchProfileDirect(senderPubkey));
                if (fetchPromises.length > 0) await Promise.all(fetchPromises);
                const inviterName = this.getNymFromPubkey(senderPubkey);
                if (newMembers.length > 0) {
                    const addedNames = newMembers.map(pk => this.getNymFromPubkey(pk)).join(', ');
                    this.displaySystemMessage(`${addedNames} was added by ${inviterName}.`);
                } else {
                    this.displaySystemMessage(rumor.content);
                }
            }
            return;
        }

        // group-remove-member: update membership, notify if we were kicked.
        if (typeTag && typeTag[1] === 'group-remove-member') {
            const kickTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'kick' && t[1]);
            if (!kickTag) return;
            const removedPubkey = kickTag[1];
            const banTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'ban' && t[1] === '1');
            // Verify the kick was actually issued by the owner or a moderator
            const grpForCheck = this.groupConversations.get(groupId);
            if (grpForCheck) {
                const isOwnerKick = grpForCheck.createdBy === senderPubkey;
                const isModKick = Array.isArray(grpForCheck.mods) && grpForCheck.mods.includes(senderPubkey);
                if (!isOwnerKick && !isModKick) return;
                // Mods can't kick the owner or other mods
                if (!isOwnerKick) {
                    if (grpForCheck.createdBy === removedPubkey) return;
                    if (Array.isArray(grpForCheck.mods) && grpForCheck.mods.includes(removedPubkey)) return;
                }
            }
            // Fetch profiles so nicknames display correctly instead of nym#xxxx
            const profileFetches = [];
            if (!this.users.has(removedPubkey)) profileFetches.push(this.fetchProfileDirect(removedPubkey));
            if (!this.users.has(senderPubkey)) profileFetches.push(this.fetchProfileDirect(senderPubkey));
            if (profileFetches.length > 0) await Promise.all(profileFetches);
            const removedName = this.getNymFromPubkey(removedPubkey);
            const removerName = this.getNymFromPubkey(senderPubkey);
            if (removedPubkey === this.pubkey) {
                // We were removed — track as left so it doesn't reappear
                this.leftGroups.add(groupId);
                this._saveLeftGroups();
                this.groupConversations.delete(groupId);
                this._saveGroupConversations();
                this._debouncedNostrSettingsSave();
                const gck = this.getGroupConversationKey(groupId);
                this.pmMessages.delete(gck);
                this.channelDOMCache.delete(gck);
                if (typeof this._cacheDelete === 'function') this._cacheDelete('pms', gck);
                document.getElementById('pmList')?.querySelector(`[data-group-id="${groupId}"]`)?.remove();
                this.updateViewMoreButton('pmList');
                if (this.currentGroup === groupId) {
                    this.currentGroup = null;
                    this.inPMMode = false;
                    this.switchChannel(this.currentChannel || 'nymchat', this.currentChannel || 'nymchat');
                    this.displaySystemMessage(`You were removed from "${groupName}" by ${removerName}.`);
                }
                // Notify — the user might not have the group open.
                const titleSelf = banTag ? `Banned from ${groupName}` : `Removed from ${groupName}`;
                const bodySelf = banTag
                    ? `${removerName} banned you. You can be re-invited only by the group owner.`
                    : `${removerName} removed you from the group.`;
                const removeSelfChannelInfo = { type: 'group', groupId, id: gck, pubkey: senderPubkey, eventId: event.id };
                const removeSelfTsSec = Math.floor(rumor.created_at) || Math.floor(Date.now() / 1000);
                const removeSelfIsHistorical = (Math.floor(Date.now() / 1000) - removeSelfTsSec) > 10;
                if (!removeSelfIsHistorical) {
                    this.showNotification(titleSelf, bodySelf, removeSelfChannelInfo, removeSelfTsSec * 1000);
                } else {
                    this._addNotificationToHistory(titleSelf, bodySelf, removeSelfChannelInfo, removeSelfTsSec * 1000);
                }
            } else {
                // Another member was kicked — update local state and show system notice
                const grp = this.groupConversations.get(groupId);
                if (grp) {
                    grp.members = grp.members.filter(pk => pk !== removedPubkey);
                    if (Array.isArray(grp.mods)) grp.mods = grp.mods.filter(pk => pk !== removedPubkey);
                    if (banTag) {
                        if (!Array.isArray(grp.banned)) grp.banned = [];
                        if (!grp.banned.includes(removedPubkey)) grp.banned.push(removedPubkey);
                    }
                    this._appendModLog(grp, { type: 'kick', actor: senderPubkey, target: removedPubkey });
                    this.groupConversations.set(groupId, grp);
                    this._saveGroupConversations();
                    this._debouncedNostrSettingsSave();
                    this.updateGroupConversationUI(groupId);
                    if (!isOwn && this.inPMMode && this.currentGroup === groupId) {
                        this.openGroup(groupId);
                        this.displaySystemMessage(`${removedName} was removed by ${removerName}.`);
                    }
                }
            }
            return;
        }

        // group-promote-mod: promote a member to moderator (owner-issued only).
        if (typeTag && typeTag[1] === 'group-promote-mod') {
            const modTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'mod' && t[1]);
            if (!modTag) return;
            const targetPubkey = modTag[1];
            const grp = this.groupConversations.get(groupId);
            if (!grp) return;
            if (grp.createdBy !== senderPubkey) return; // only owner can promote
            if (!Array.isArray(grp.mods)) grp.mods = [];
            if (!grp.mods.includes(targetPubkey)) grp.mods.push(targetPubkey);
            this._appendModLog(grp, { type: 'promote', actor: senderPubkey, target: targetPubkey });
            this.groupConversations.set(groupId, grp);
            this._saveGroupConversations();
            this._debouncedNostrSettingsSave();
            if (!isOwn) {
                if (!this.users.has(targetPubkey)) await this.fetchProfileDirect(targetPubkey);
                if (!this.users.has(senderPubkey)) await this.fetchProfileDirect(senderPubkey);
                const targetName = this.getNymFromPubkey(targetPubkey);
                const actorName = this.getNymFromPubkey(senderPubkey);
                if (this.inPMMode && this.currentGroup === groupId) {
                    this.displaySystemMessage(`${targetName} was promoted to moderator by ${actorName}.`);
                    this.openGroup(groupId);
                }
                if (targetPubkey === this.pubkey) {
                    const promoteTitle = `Promoted in ${grp.name || groupName}`;
                    const promoteBody = `${actorName} made you a moderator.`;
                    const promoteChannelInfo = { type: 'group', groupId, id: groupConvKey, pubkey: senderPubkey, eventId: event.id };
                    const promoteTsSec = Math.floor(rumor.created_at) || Math.floor(Date.now() / 1000);
                    if ((Math.floor(Date.now() / 1000) - promoteTsSec) > 10) {
                        this._addNotificationToHistory(promoteTitle, promoteBody, promoteChannelInfo, promoteTsSec * 1000);
                    } else {
                        this.showNotification(promoteTitle, promoteBody, promoteChannelInfo, promoteTsSec * 1000);
                    }
                }
            }
            return;
        }

        // group-revoke-mod: revoke a member's moderator role (owner-issued only).
        if (typeTag && typeTag[1] === 'group-revoke-mod') {
            const modTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'mod' && t[1]);
            if (!modTag) return;
            const targetPubkey = modTag[1];
            const grp = this.groupConversations.get(groupId);
            if (!grp) return;
            if (grp.createdBy !== senderPubkey) return;
            if (Array.isArray(grp.mods)) grp.mods = grp.mods.filter(pk => pk !== targetPubkey);
            this._appendModLog(grp, { type: 'revoke', actor: senderPubkey, target: targetPubkey });
            this.groupConversations.set(groupId, grp);
            this._saveGroupConversations();
            this._debouncedNostrSettingsSave();
            if (!isOwn) {
                if (!this.users.has(targetPubkey)) await this.fetchProfileDirect(targetPubkey);
                if (!this.users.has(senderPubkey)) await this.fetchProfileDirect(senderPubkey);
                const targetName = this.getNymFromPubkey(targetPubkey);
                const actorName = this.getNymFromPubkey(senderPubkey);
                if (this.inPMMode && this.currentGroup === groupId) {
                    this.displaySystemMessage(`${targetName}'s moderator role was revoked by ${actorName}.`);
                    this.openGroup(groupId);
                }
                if (targetPubkey === this.pubkey) {
                    const revokeTitle = `Moderator removed in ${grp.name || groupName}`;
                    const revokeBody = `${actorName} revoked your moderator role.`;
                    const revokeChannelInfo = { type: 'group', groupId, id: groupConvKey, pubkey: senderPubkey, eventId: event.id };
                    const revokeTsSec = Math.floor(rumor.created_at) || Math.floor(Date.now() / 1000);
                    if ((Math.floor(Date.now() / 1000) - revokeTsSec) > 10) {
                        this._addNotificationToHistory(revokeTitle, revokeBody, revokeChannelInfo, revokeTsSec * 1000);
                    } else {
                        this.showNotification(revokeTitle, revokeBody, revokeChannelInfo, revokeTsSec * 1000);
                    }
                }
            }
            return;
        }

        // group-transfer-owner: change owner (current-owner-issued only).
        if (typeTag && typeTag[1] === 'group-transfer-owner') {
            const ownerTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'owner' && t[1]);
            if (!ownerTag) return;
            const newOwner = ownerTag[1];
            const grp = this.groupConversations.get(groupId);
            if (!grp) return;
            if (grp.createdBy !== senderPubkey) return;
            grp.createdBy = newOwner;
            if (Array.isArray(grp.mods)) grp.mods = grp.mods.filter(pk => pk !== newOwner);
            this._appendModLog(grp, { type: 'transfer', actor: senderPubkey, target: newOwner });
            this.groupConversations.set(groupId, grp);
            this._saveGroupConversations();
            this._debouncedNostrSettingsSave();
            if (!isOwn) {
                if (!this.users.has(newOwner)) await this.fetchProfileDirect(newOwner);
                if (!this.users.has(senderPubkey)) await this.fetchProfileDirect(senderPubkey);
                const targetName = this.getNymFromPubkey(newOwner);
                const actorName = this.getNymFromPubkey(senderPubkey);
                if (this.inPMMode && this.currentGroup === groupId) {
                    this.displaySystemMessage(`${actorName} transferred group ownership to ${targetName}.`);
                    this.openGroup(groupId);
                }
                if (newOwner === this.pubkey) {
                    const transferTitle = `Owner of ${grp.name || groupName}`;
                    const transferBody = `${actorName} transferred group ownership to you.`;
                    const transferChannelInfo = { type: 'group', groupId, id: groupConvKey, pubkey: senderPubkey, eventId: event.id };
                    const transferTsSec = Math.floor(rumor.created_at) || Math.floor(Date.now() / 1000);
                    if ((Math.floor(Date.now() / 1000) - transferTsSec) > 10) {
                        this._addNotificationToHistory(transferTitle, transferBody, transferChannelInfo, transferTsSec * 1000);
                    } else {
                        this.showNotification(transferTitle, transferBody, transferChannelInfo, transferTsSec * 1000);
                    }
                }
            }
            return;
        }

        // group-delete-message: owner or moderator deletes another member's message.
        if (typeTag && typeTag[1] === 'group-delete-message') {
            const eTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'e' && t[1]);
            if (!eTag) return;
            const targetMessageId = eTag[1];
            const targetAuthorTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'target_pubkey' && t[1]);
            const targetAuthor = targetAuthorTag ? targetAuthorTag[1] : null;
            const grp = this.groupConversations.get(groupId);
            if (!grp) return;
            const isOwnerSender = grp.createdBy === senderPubkey;
            const isModSender = Array.isArray(grp.mods) && grp.mods.includes(senderPubkey);
            if (!isOwnerSender && !isModSender) return;
            // Mods can't delete the owner's messages
            if (!isOwnerSender && targetAuthor && grp.createdBy === targetAuthor) return;
            this._applyGroupMessageDeletion(groupId, targetMessageId);
            this._appendModLog(grp, { type: 'delete-message', actor: senderPubkey, target: targetAuthor, messageId: targetMessageId });
            this._saveGroupConversations();
            this._debouncedNostrSettingsSave();
            if (!isOwn && this.inPMMode && this.currentGroup === groupId) {
                if (!this.users.has(senderPubkey)) await this.fetchProfileDirect(senderPubkey);
                const actorName = this.getNymFromPubkey(senderPubkey);
                if (targetAuthor && !this.users.has(targetAuthor)) await this.fetchProfileDirect(targetAuthor);
                const authorName = targetAuthor ? this.getNymFromPubkey(targetAuthor) : 'a member';
                this.displaySystemMessage(`${actorName} deleted a message from ${authorName}.`);
            }
            return;
        }

        // Extract all member pubkeys from 'p' tags
        const memberPubkeys = (rumor.tags || [])
            .filter(t => Array.isArray(t) && t[0] === 'p' && t[1])
            .map(t => t[1]);

        if (!this.pmMessages.has(groupConvKey)) this.pmMessages.set(groupConvKey, []);
        let list = this.pmMessages.get(groupConvKey);

        // Deduplicate by event ID
        if (list.some(m => m.id === event.id)) return;

        const messageContent = rumor.content;
        const nowSec = Math.floor(Date.now() / 1000);
        const originalGroupTsSec = Math.floor(rumor.created_at) || nowSec;
        let tsSec = originalGroupTsSec;

        // Guard against clock skew: cap at current time (no future messages)
        tsSec = Math.min(tsSec, nowSec);

        // Check if this is an edit of a previous group message (has 'edit' tag in rumor)
        const groupEditTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'edit' && t[1]);
        if (groupEditTag) {
            const originalId = groupEditTag[1];
            this.handleIncomingPMEdit(originalId, messageContent, senderPubkey, groupConvKey);
            return;
        }

        // Content dedup for dual-wrap scenarios
        if (list.some(m => m.pubkey === senderPubkey && m.content === messageContent && Math.abs((m.timestamp?.getTime() / 1000 || 0) - tsSec) < 5)) return;

        const nymMsgId = this.getNymMessageId(rumor);
        const senderName = this.getNymFromPubkey(senderPubkey);

        // Fetch profile for unknown senders
        if (!isOwn && !this.users.has(senderPubkey)) {
            await this.fetchProfileDirect(senderPubkey);
        }

        const msg = {
            id: event.id,
            author: isOwn ? this.nym : senderName,
            pubkey: senderPubkey,
            content: messageContent,
            created_at: tsSec,
            _originalCreatedAt: originalGroupTsSec,
            _ms: this._extractEventMs(rumor, tsSec),
            _seq: ++this._msgSeq,
            timestamp: new Date(tsSec * 1000),
            isOwn,
            isPM: true,
            isGroup: true,
            groupId,
            conversationKey: groupConvKey,
            conversationPubkey: null,
            eventKind: 1059,
            isHistorical: this._isGiftWrapBacklog(),
            nymMessageId: nymMsgId,
            deliveryStatus: isOwn ? 'sent' : undefined
        };

        list.push(msg);
        list.sort((a, b) => {
            return this._compareMessages(a, b);
        });
        if (list.length > this.pmStorageLimit) list = list.slice(-this.pmStorageLimit);
        this.pmMessages.set(groupConvKey, list);
        this.persistPMMessages(groupConvKey);

        // Update or create group conversation entry
        this.addGroupConversation(groupId, groupName, memberPubkeys, tsSec * 1000);
        this._saveGroupConversations();
        this._debouncedNostrSettingsSave(15000); // longer delay for routine messages
        this.moveGroupToTop(groupId, tsSec * 1000);

        // Clear typing indicator for sender (they sent a message, so they stopped typing)
        if (!isOwn) {
            const convTypers = this.typingUsers.get(groupConvKey);
            if (convTypers && convTypers.has(senderPubkey)) {
                const entry = convTypers.get(senderPubkey);
                if (entry.timeout) clearTimeout(entry.timeout);
                convTypers.delete(senderPubkey);
                this.renderTypingIndicator();
            }
        }

        const senderBlocked = this.blockedUsers.has(senderPubkey) || this.hasBlockedKeyword(msg.content, msg.author);
        if (this.inPMMode && this.currentGroup === groupId) {
            this.displayMessage(msg);
            this._scheduleScrollToBottom();
            if (typeof this._markChannelRead === 'function') {
                this._markChannelRead(groupConvKey, msg.created_at);
            }
        } else {
            if (!isOwn && !senderBlocked) {
                const ageMs = Date.now() - (tsSec * 1000);
                const treatAsHistorical = msg.isHistorical || ageMs > 30000;
                if (!treatAsHistorical) {
                    this.updateUnreadCount(groupConvKey);
                }
                const isInviteRumor = msgType === 'group-invite';
                const shouldNotifyGroup = !isInviteRumor && (!this.groupNotifyMentionsOnly || this.isMentioned(messageContent));
                if (shouldNotifyGroup) {
                    const groupMsgChannelInfo = {
                        type: 'group',
                        groupId,
                        id: groupConvKey,
                        pubkey: senderPubkey,
                        eventId: event.id
                    };
                    if (!treatAsHistorical) {
                        this.showNotification(`${groupName}: ${msg.author}`, messageContent, groupMsgChannelInfo, tsSec * 1000);
                    } else {
                        this._addNotificationToHistory(`${groupName}: ${msg.author}`, messageContent, groupMsgChannelInfo, tsSec * 1000);
                    }
                }
            }
        }

        // Send read receipt back to sender so they can show our avatar as "read"
        if (!isOwn && !msg.isHistorical && this._canSendGiftWraps() && nymMsgId) {
            this.sendNymReceipt(nymMsgId, 'read', senderPubkey, 'group');
            this.recordOwnActivity();
        }
    },

    // Create a new private group and send invites to all members via NIP-17 gift wraps.
    async createGroup(name, memberPubkeys) {
        if (!this._canSendGiftWraps()) {
            this.displaySystemMessage('Creating groups requires a logged-in account (not pseudonymous mode)');
            return null;
        }

        // Always include self as a member
        const allMembers = [...new Set([...memberPubkeys, this.pubkey])];

        const groupId = this.generateUUID();
        const now = Math.floor(Date.now() / 1000);
        const nymMessageId = this._generateSharedEventId();
        const inviteContent = `You've been added to group "${name}" (${allMembers.length} members).`;

        const tags = allMembers.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', name]);
        tags.push(['type', 'group-invite']);
        tags.push(['owner', this.pubkey]);
        tags.push(['x', nymMessageId]);

        // Bootstrap ephemeral keys: include our first ephemeral pk so members
        // can start encrypting to it instead of our real pubkey.
        const initialEph = this._ensureSelfEphemeralKey(groupId);
        tags.push(['ephemeral_pk', initialEph.pk]);

        const rumor = { kind: 14, created_at: now, tags, content: inviteContent, pubkey: this.pubkey };
        const expirationTs = (this.settings?.dmForwardSecrecyEnabled && this.settings?.dmTTLSeconds > 0)
            ? now + this.settings.dmTTLSeconds : null;

        // First invite always uses real pubkeys (no ephemeral keys established yet)
        await this._sendGiftWrapsAsync(allMembers, rumor, expirationTs);
        this._saveEphemeralKeys();

        // addGroupConversation creates the sidebar item with us marked as owner
        this.addGroupConversation(groupId, name, allMembers, Date.now(), { createdBy: this.pubkey });
        // Defensive: ensure createdBy is set even if a relay echo created the entry first
        const grp = this.groupConversations.get(groupId);
        if (grp && grp.createdBy !== this.pubkey) grp.createdBy = this.pubkey;
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.openGroup(groupId);
        return groupId;
    },

    // Add a new member to an existing group via NIP-17
    async addMemberToGroup(groupId, newMemberPubkey) {
        if (!this._canSendGiftWraps()) {
            this.displaySystemMessage('Adding members requires a logged-in account');
            return false;
        }
        const group = this.groupConversations.get(groupId);
        if (!group) {
            this.displaySystemMessage('Group not found');
            return false;
        }
        if (group.members.includes(newMemberPubkey)) {
            this.displaySystemMessage('User is already in this group');
            return false;
        }
        // Banlist: only the owner can re-admit a banned user; mods/members cannot.
        if (Array.isArray(group.banned) && group.banned.includes(newMemberPubkey)) {
            if (!this._isGroupOwner(groupId, this.pubkey)) {
                this.displaySystemMessage('That user was removed from this group and can only be re-invited by the group owner.');
                return false;
            }
            // Owner is re-admitting: clear the ban
            group.banned = group.banned.filter(pk => pk !== newMemberPubkey);
        }

        group.members = [...group.members, newMemberPubkey];
        this.groupConversations.set(groupId, group);

        // Fetch profile for the new member if we don't have it yet so nicknames display correctly
        if (!this.users.has(newMemberPubkey)) {
            await this.fetchProfileDirect(newMemberPubkey);
        }

        const now = Math.floor(Date.now() / 1000);
        const nymMessageId = this._generateSharedEventId();
        const newMemberName = this.getNymFromPubkey(newMemberPubkey);
        const inviterName = this.getNymFromPubkey(this.pubkey);
        const addContent = `${newMemberName} was added by ${inviterName}.`;

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['type', 'group-add-member']);
        if (group.createdBy) tags.push(['owner', group.createdBy]);
        if (Array.isArray(group.mods)) {
            for (const modPk of group.mods) tags.push(['mod', modPk]);
        }
        tags.push(['x', nymMessageId]);

        // Include our ephemeral pk so the new member (and existing members) learn it
        const eph = this._ensureSelfEphemeralKey(groupId);
        tags.push(['ephemeral_pk', eph.pk]);

        const rumor = { kind: 14, created_at: now, tags, content: addContent, pubkey: this.pubkey };
        const expirationTs = (this.settings?.dmForwardSecrecyEnabled && this.settings?.dmTTLSeconds > 0)
            ? now + this.settings.dmTTLSeconds : null;

        // New member doesn't have an ephemeral key yet, so their wrap uses real pubkey.
        // Existing members with ephemeral keys will get theirs used automatically.
        await this._sendGiftWrapsAsync(group.members, rumor, expirationTs, groupId);
        this._saveEphemeralKeys();

        this.updateGroupConversationUI(groupId);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        // Refresh header if currently viewing this group
        if (this.inPMMode && this.currentGroup === groupId) {
            this.openGroup(groupId);
            this.displaySystemMessage(addContent);
        }

        return true;
    },

    // Wrap and send one NIP-59 gift wrap per group member.
    // Check whether the user can send gift-wrapped messages.
    // True when a local privkey is available OR a NIP-07 extension exposes
    // the required nip44 encrypt + signEvent methods.
    _canSendGiftWraps() {
        return !!this.privkey
            || !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent)
            || (this.nostrLoginMethod === 'nip46' && !!(_nip46State && _nip46State.connected));
    },

    _sendGiftWraps(members, rumor, expirationTs, groupId = null) {
        const sharedId = this.getNymMessageId(rumor);
        for (const pubkey of members) {
            const encryptTo = groupId ? this._getEncryptionPubkey(groupId, pubkey) : pubkey;
            const wrapped = this.nip59WrapEvent(rumor, this.privkey, encryptTo, expirationTs);
            this.sendDMToRelays(['EVENT', wrapped]);
            this._recordGiftWrapId(sharedId, wrapped.id);

            if (this.activeCosmetics?.has('cosmetic-redacted')) {
                setTimeout(() => { this.publishDeletionEvent(wrapped.id, 1059); }, 600000);
            }
        }
    },

    _recordGiftWrapId(sharedId, wrappedId) {
        if (!sharedId || !wrappedId) return;
        if (!this._giftWrapsForSharedId) this._giftWrapsForSharedId = new Map();
        let set = this._giftWrapsForSharedId.get(sharedId);
        if (!set) {
            set = new Set();
            this._giftWrapsForSharedId.set(sharedId, set);
        }
        set.add(wrappedId);
        if (this._giftWrapsForSharedId.size > 5000) {
            const firstKey = this._giftWrapsForSharedId.keys().next().value;
            this._giftWrapsForSharedId.delete(firstKey);
        }
    },

    // Uses the local privkey when available, otherwise falls back to the
    // NIP-07 extension for sealing (nip44.encrypt + signEvent) while still
    // wrapping with a local ephemeral keypair.
    async _sendGiftWrapsAsync(members, rumor, expirationTs, groupId = null) {
        // Fast path — local key available
        if (this.privkey) {
            this._sendGiftWraps(members, rumor, expirationTs, groupId);
            return;
        }

        // Extension or NIP-46 remote signer path
        const useExtension = !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent);
        const useNip46 = this.nostrLoginMethod === 'nip46' && _nip46State && _nip46State.connected;
        if (!useExtension && !useNip46) return;

        const NT = window.NostrTools;
        // Compute rumor id once
        const rumorWithId = { ...rumor };
        rumorWithId.id = NT.getEventHash(rumorWithId);
        const rumorJson = JSON.stringify(rumorWithId);
        const sharedId = this.getNymMessageId(rumor);

        const wrapOne = async (pubkey) => {
            try {
                const encryptTo = groupId ? this._getEncryptionPubkey(groupId, pubkey) : pubkey;

                const sealContent = useExtension
                    ? await window.nostr.nip44.encrypt(encryptTo, rumorJson)
                    : await _nip46Encrypt(encryptTo, rumorJson);
                const sealUnsigned = {
                    kind: 13, content: sealContent, created_at: this.randomNow(), tags: []
                };
                const seal = useExtension
                    ? await window.nostr.signEvent(sealUnsigned)
                    : await _nip46SignEvent(sealUnsigned);

                const ephSk = NT.generateSecretKey();
                const ckWrap = NT.nip44.getConversationKey(ephSk, encryptTo);
                const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
                const wrapUnsigned = {
                    kind: 1059,
                    content: wrapContent,
                    created_at: this.randomNow(),
                    tags: [['p', encryptTo]]
                };
                if (expirationTs) wrapUnsigned.tags.push(['expiration', String(expirationTs)]);

                const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);
                this.sendDMToRelays(['EVENT', wrapped]);
                this._recordGiftWrapId(sharedId, wrapped.id);

                if (this.activeCosmetics?.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(wrapped.id, 1059); }, 600000);
                }
            } catch (e) {
                console.warn('[GiftWrap] Remote wrap failed for', pubkey, e);
            }
        };

        // Controlled-concurrency pool
        const limit = useNip46 ? 4 : 8;
        const queue = members.slice();
        const workers = new Array(Math.min(limit, queue.length)).fill(0).map(async () => {
            while (queue.length) {
                const pk = queue.shift();
                await wrapOne(pk);
            }
        });
        await Promise.all(workers);
    },

    // Send a message to a group via NIP-17 gift wraps (one per member).
    async sendGroupMessage(content, groupId) {
        if (!content || !content.trim()) return false;
        if (!this._canSendGiftWraps()) {
            this.displaySystemMessage('Group messages require a logged-in account');
            return false;
        }

        // Wait for reconnect catch-up to finish so we have the latest
        // ephemeral keys from missed messages before encrypting.
        await this._dmCatchupReady;

        const group = this.groupConversations.get(groupId);
        if (!group) return false;
        const nowMs = Date.now();
        const now = Math.floor(nowMs / 1000);

        const nymMessageId = this._generateSharedEventId();

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['x', nymMessageId]);

        // Ephemeral key rotation: generate next key and advertise it inside the rumor.
        // Recipients will encrypt future messages to this key instead of our real pubkey.
        const nextEph = this._rotateSelfEphemeralKey(groupId);
        tags.push(['ephemeral_pk', nextEph.pk]);
        tags.push(['ms', String(nowMs)]);

        // NIP-30: declare any custom emoji shortcodes used in the message
        tags.push(...this.customEmojiTagsForContent(content));

        // NIP-92: imeta tags listing Blossom mirror URLs for any media in the message
        if (typeof this.imetaTagsForContent === 'function') {
            tags.push(...this.imetaTagsForContent(content));
        }

        const rumor = { kind: 14, created_at: now, tags, content, pubkey: this.pubkey };
        const expirationTs = (this.settings?.dmForwardSecrecyEnabled && this.settings?.dmTTLSeconds > 0)
            ? now + this.settings.dmTTLSeconds : null;

        const groupConvKey = this.getGroupConversationKey(groupId);
        if (!this.pmMessages.has(groupConvKey)) this.pmMessages.set(groupConvKey, []);
        const msg = {
            id: nymMessageId,
            author: this.nym,
            pubkey: this.pubkey,
            content,
            created_at: now,
            _ms: nowMs,
            _seq: ++this._msgSeq,
            timestamp: new Date(now * 1000),
            isOwn: true,
            isPM: true,
            isGroup: true,
            groupId,
            conversationKey: groupConvKey,
            conversationPubkey: null,
            eventKind: 1059,
            nymMessageId,
            deliveryStatus: 'sent'
        };

        const groupList = this.pmMessages.get(groupConvKey);
        groupList.push(msg);
        groupList.sort((a, b) => {
            return this._compareMessages(a, b);
        });
        if (groupList.length > this.pmStorageLimit) this.pmMessages.set(groupConvKey, groupList.slice(-this.pmStorageLimit));
        this.channelDOMCache.delete(groupConvKey);
        this.persistPMMessages(groupConvKey);
        this.moveGroupToTop(groupId);

        if (this.inPMMode && this.currentGroup === groupId) {
            this.displayMessage(msg);
        }

        // Send gift wraps using ephemeral recipient keys when available
        await this._sendGiftWrapsAsync(group.members, rumor, expirationTs, groupId);
        this._saveEphemeralKeys();
        this._debouncedNostrSettingsSave(2000);

        // Refresh relay subscriptions so we receive messages to our new ephemeral key
        this._refreshEphemeralSubscriptions();

        // Bump our own presence so status stays "online".
        this.recordOwnActivity();

        return true;
    },

    // Resolve a nym or nym#suffix or pubkey string to a pubkey
    resolvePubkeyFromNym(nymInput) {
        if (/^[0-9a-f]{64}$/i.test(nymInput)) return nymInput.toLowerCase();
        const hashIndex = nymInput.indexOf('#');
        let searchNym = nymInput;
        let searchSuffix = null;
        if (hashIndex !== -1) {
            searchNym = nymInput.substring(0, hashIndex);
            searchSuffix = nymInput.substring(hashIndex + 1);
        }
        const matches = [];
        this.users.forEach((user, pubkey) => {
            const baseNym = this.stripPubkeySuffix(user.nym);
            if (baseNym.toLowerCase() === searchNym.toLowerCase()) {
                if (!searchSuffix || pubkey.endsWith(searchSuffix)) matches.push(pubkey);
            }
        });
        if (matches.length === 1) return matches[0];
        if (matches.length > 1) {
            this.displaySystemMessage(`Multiple users named @${searchNym} — use @name#xxxx to disambiguate`);
            return null;
        }
        return null;
    },

    // Send a leave notification to remaining group members, then clean up locally
    async leaveGroup(groupId) {
        const group = this.groupConversations.get(groupId);

        // NIP-17 leave notification
        if (group && this._canSendGiftWraps()) {
            const otherMembers = group.members.filter(pk => pk !== this.pubkey);
            if (otherMembers.length > 0) {
                const now = Math.floor(Date.now() / 1000);
                const suffix = this.getPubkeySuffix(this.pubkey);
                const leaveContent = `${this.nym}#${suffix} left the group.`;
                const tags = group.members.map(pk => ['p', pk]);
                tags.push(['g', groupId]);
                tags.push(['subject', group.name]);
                tags.push(['type', 'group-leave']);
                tags.push(['x', this._generateSharedEventId()]);
                const rumor = { kind: 14, created_at: now, tags, content: leaveContent, pubkey: this.pubkey };
                // Send to remaining members only (not self), using ephemeral keys
                await this._sendGiftWrapsAsync(otherMembers, rumor, null, groupId);
            }
        }
        // Track the left group so it doesn't reappear from stale relay data
        this.leftGroups.add(groupId);
        if (!this.leftGroupTimes) this.leftGroupTimes = new Map();
        this.leftGroupTimes.set(groupId, Math.floor(Date.now() / 1000));
        this._saveLeftGroups();
        try { localStorage.setItem('nym_left_group_times', JSON.stringify(Object.fromEntries(this.leftGroupTimes))); } catch { }
        const groupConvKeyForRead = this.getGroupConversationKey(groupId);
        if (this.channelLastRead) this.channelLastRead.set(groupConvKeyForRead, Math.floor(Date.now() / 1000));
        if (this.unreadCounts) this.unreadCounts.delete(groupConvKeyForRead);
        if (typeof this._persistUnreadCounts === 'function') this._persistUnreadCounts(true);

        // Clean up ephemeral keys for this group
        this.groupEphemeralKeys.delete(groupId);
        this._saveEphemeralKeys();

        // Remove persisted entry
        try { localStorage.removeItem(`nym_groups_${this.pubkey}`); } catch (_) { }
        this.groupConversations.delete(groupId);
        this._saveGroupConversations();

        const groupConvKey = this.getGroupConversationKey(groupId);
        this.pmMessages.delete(groupConvKey);
        this.channelDOMCache.delete(groupConvKey);
        if (typeof this._cacheDelete === 'function') this._cacheDelete('pms', groupConvKey);
        const pmList = document.getElementById('pmList');
        const item = pmList?.querySelector(`[data-group-id="${groupId}"]`);
        if (item) item.remove();
        if (this.currentGroup === groupId) {
            this.currentGroup = null;
            this.inPMMode = false;
            const fallback = this.currentChannel || 'nymchat';
            this.switchChannel(fallback, fallback);
        }
        this.updateViewMoreButton('pmList');
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    // Delete a group conversation locally
    deleteGroup(groupId) {
        if (!confirm('Leave and delete this group conversation?')) return;
        this.leaveGroup(groupId);
    },

    // Remove a member from the current group (owner or moderator) via NIP-17 gift-wrapped rumor.
    // /kick: removes membership; the user can be re-invited by anyone.
    async kickFromGroup(pubkey) {
        return this._removeFromGroup(pubkey, { ban: false });
    },

    // Remove and banlist a member. Only the owner can re-admit them.
    async banFromGroup(pubkey) {
        return this._removeFromGroup(pubkey, { ban: true });
    },

    async _removeFromGroup(pubkey, { ban }) {
        this.closeContextMenu();
        const groupId = this.currentGroup;
        if (!groupId || !this._canSendGiftWraps()) return;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._canModerate(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner or a moderator can remove members.');
            return;
        }
        if (!group.members.includes(pubkey)) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            if (this._isGroupOwner(groupId, pubkey) || this._isGroupMod(groupId, pubkey)) {
                this.displaySystemMessage("You can't remove the group owner or another moderator.");
                return;
            }
        }

        if (!this.users.has(pubkey)) {
            await this.fetchProfileDirect(pubkey);
        }

        const kickedName = this.getNymFromPubkey(pubkey);
        const kickerName = this.getNymFromPubkey(this.pubkey);
        const content = ban
            ? `${kickedName} was banned by ${kickerName}.`
            : `${kickedName} was removed by ${kickerName}.`;
        const now = Math.floor(Date.now() / 1000);
        const nymMessageId = this._generateSharedEventId();

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['type', 'group-remove-member']);
        tags.push(['kick', pubkey]);
        if (ban) tags.push(['ban', '1']);
        tags.push(['x', nymMessageId]);
        const rumor = { kind: 14, created_at: now, tags, content, pubkey: this.pubkey };

        await this._sendGiftWrapsAsync(group.members, rumor, null, groupId);

        const ek = this.groupEphemeralKeys.get(groupId);
        if (ek) { delete ek.members[pubkey]; this._saveEphemeralKeys(); }
        group.members = group.members.filter(pk => pk !== pubkey);
        if (Array.isArray(group.mods)) group.mods = group.mods.filter(pk => pk !== pubkey);
        if (ban) {
            if (!Array.isArray(group.banned)) group.banned = [];
            if (!group.banned.includes(pubkey)) group.banned.push(pubkey);
        }
        this._appendModLog(group, { type: ban ? 'ban' : 'kick', actor: this.pubkey, target: pubkey });
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.updateGroupConversationUI(groupId);
        this.openGroup(groupId);
        this.displaySystemMessage(content);
    },

    // Owner-only: lift a ban (does not re-invite the user).
    async unbanFromGroup(pubkey) {
        const groupId = this.currentGroup;
        if (!groupId) return;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can unban users.');
            return;
        }
        if (!Array.isArray(group.banned) || !group.banned.includes(pubkey)) {
            this.displaySystemMessage('That user is not banned.');
            return;
        }
        group.banned = group.banned.filter(pk => pk !== pubkey);
        this._appendModLog(group, { type: 'unban', actor: this.pubkey, target: pubkey });
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        if (!this.users.has(pubkey)) await this.fetchProfileDirect(pubkey);
        const targetName = this.getNymFromPubkey(pubkey);
        const actorName = this.getNymFromPubkey(this.pubkey);
        // Notify the unbanned user via a gift-wrapped rumor so they see a notification.
        if (this._canSendGiftWraps()) {
            const now = Math.floor(Date.now() / 1000);
            const tags = [
                ['p', pubkey],
                ['g', groupId],
                ['subject', group.name],
                ['type', 'group-unban'],
                ['unban', pubkey],
                ['x', this._generateSharedEventId()]
            ];
            const rumor = {
                kind: 14,
                created_at: now,
                tags,
                content: `${actorName} unbanned you from "${group.name}". You may be re-invited.`,
                pubkey: this.pubkey
            };
            await this._sendGiftWrapsAsync([pubkey], rumor, null);
        }
        this.displaySystemMessage(`@${targetName} was unbanned. They can be re-invited.`);
    },

    // Owner-only: promote a member to moderator
    async promoteModerator(pubkey) {
        this.closeContextMenu();
        const groupId = this.currentGroup;
        if (!groupId || !this._canSendGiftWraps()) return;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can assign moderators.');
            return;
        }
        if (!group.members.includes(pubkey)) {
            this.displaySystemMessage('That user is not a member of this group.');
            return;
        }
        if (pubkey === this.pubkey) {
            this.displaySystemMessage("You're already the group owner.");
            return;
        }
        if (this._isGroupMod(groupId, pubkey)) {
            this.displaySystemMessage('That user is already a moderator.');
            return;
        }

        if (!this.users.has(pubkey)) await this.fetchProfileDirect(pubkey);
        const targetName = this.getNymFromPubkey(pubkey);
        const actorName = this.getNymFromPubkey(this.pubkey);
        const content = `${targetName} was promoted to moderator by ${actorName}.`;
        const now = Math.floor(Date.now() / 1000);

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['type', 'group-promote-mod']);
        tags.push(['mod', pubkey]);
        tags.push(['x', this._generateSharedEventId()]);
        const rumor = { kind: 14, created_at: now, tags, content, pubkey: this.pubkey };

        await this._sendGiftWrapsAsync(group.members, rumor, null, groupId);

        if (!Array.isArray(group.mods)) group.mods = [];
        if (!group.mods.includes(pubkey)) group.mods.push(pubkey);
        this._appendModLog(group, { type: 'promote', actor: this.pubkey, target: pubkey });
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.displaySystemMessage(content);
    },

    // Owner-only: revoke a member's moderator role
    async revokeModerator(pubkey) {
        this.closeContextMenu();
        const groupId = this.currentGroup;
        if (!groupId || !this._canSendGiftWraps()) return;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can revoke moderators.');
            return;
        }
        if (!this._isGroupMod(groupId, pubkey)) {
            this.displaySystemMessage('That user is not a moderator.');
            return;
        }

        if (!this.users.has(pubkey)) await this.fetchProfileDirect(pubkey);
        const targetName = this.getNymFromPubkey(pubkey);
        const actorName = this.getNymFromPubkey(this.pubkey);
        const content = `${targetName}'s moderator role was revoked by ${actorName}.`;
        const now = Math.floor(Date.now() / 1000);

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['type', 'group-revoke-mod']);
        tags.push(['mod', pubkey]);
        tags.push(['x', this._generateSharedEventId()]);
        const rumor = { kind: 14, created_at: now, tags, content, pubkey: this.pubkey };

        await this._sendGiftWrapsAsync(group.members, rumor, null, groupId);

        if (Array.isArray(group.mods)) group.mods = group.mods.filter(pk => pk !== pubkey);
        this._appendModLog(group, { type: 'revoke', actor: this.pubkey, target: pubkey });
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.displaySystemMessage(content);
    },

    // Owner-only: transfer ownership of the group to another member
    async transferOwner(pubkey) {
        this.closeContextMenu();
        const groupId = this.currentGroup;
        if (!groupId || !this._canSendGiftWraps()) return;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the current owner can transfer ownership.');
            return;
        }
        if (!group.members.includes(pubkey)) {
            this.displaySystemMessage('That user is not a member of this group.');
            return;
        }
        if (pubkey === this.pubkey) return;

        if (!this.users.has(pubkey)) await this.fetchProfileDirect(pubkey);
        const targetName = this.getNymFromPubkey(pubkey);
        const actorName = this.getNymFromPubkey(this.pubkey);
        const content = `${actorName} transferred group ownership to ${targetName}.`;
        const now = Math.floor(Date.now() / 1000);

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['type', 'group-transfer-owner']);
        tags.push(['owner', pubkey]);
        tags.push(['x', this._generateSharedEventId()]);
        const rumor = { kind: 14, created_at: now, tags, content, pubkey: this.pubkey };

        await this._sendGiftWrapsAsync(group.members, rumor, null, groupId);

        group.createdBy = pubkey;
        if (Array.isArray(group.mods)) group.mods = group.mods.filter(pk => pk !== pubkey);
        this._appendModLog(group, { type: 'transfer', actor: this.pubkey, target: pubkey });
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.displaySystemMessage(content);
    },

    // Owner or moderator: delete a message in the current group for everyone.
    async modDeleteGroupMessage(messageId, authorPubkey) {
        this.closeContextMenu();
        const groupId = this.currentGroup;
        if (!groupId || !this._canSendGiftWraps()) return;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._canModerate(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner or a moderator can delete messages.');
            return;
        }
        // Mods can't delete the owner's messages; only the owner can.
        if (!this._isGroupOwner(groupId, this.pubkey) && this._isGroupOwner(groupId, authorPubkey)) {
            this.displaySystemMessage("Moderators can't delete the group owner's messages.");
            return;
        }
        if (!messageId) return;

        // Resolve to the nymMessageId — that's the only id that's stable across
        // recipients, since each one has a different gift-wrap event id.
        const groupConvKey = this.getGroupConversationKey(groupId);
        const list = this.pmMessages.get(groupConvKey) || [];
        const msg = list.find(m => m.id === messageId || m.nymMessageId === messageId);
        const sharedId = (msg && msg.nymMessageId) || messageId;

        const actorName = this.getNymFromPubkey(this.pubkey);
        const authorName = authorPubkey ? this.getNymFromPubkey(authorPubkey) : 'a member';
        const content = `${actorName} deleted a message from ${authorName}.`;
        const now = Math.floor(Date.now() / 1000);

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['type', 'group-delete-message']);
        tags.push(['e', sharedId]);
        if (authorPubkey) tags.push(['target_pubkey', authorPubkey]);
        tags.push(['x', this._generateSharedEventId()]);
        const rumor = { kind: 14, created_at: now, tags, content, pubkey: this.pubkey };

        await this._sendGiftWrapsAsync(group.members, rumor, null, groupId);

        // Apply locally
        this._applyGroupMessageDeletion(groupId, sharedId);
        this._appendModLog(group, { type: 'delete-message', actor: this.pubkey, target: authorPubkey || null, messageId: sharedId });
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.displaySystemMessage(content);
    },

    // Local-only: drop a message from group state and remove from DOM.
    // The DOM bubble's data-message-id is the message's nymMessageId for group
    // messages (see messages.js), but moderation rumors may carry the gift-wrap
    // event id. Look up by either, then derive the actual DOM id from the
    // stored message so the right node is removed.
    _applyGroupMessageDeletion(groupId, messageId) {
        if (!messageId) return;
        const groupConvKey = this.getGroupConversationKey(groupId);
        const list = this.pmMessages.get(groupConvKey);
        let domId = messageId;
        if (list) {
            const idx = list.findIndex(m => m.id === messageId || m.nymMessageId === messageId);
            if (idx !== -1) {
                const msg = list[idx];
                domId = msg.nymMessageId || msg.id;
                if (this.deletedEventIds && this.deletedEventIds.add) {
                    if (msg.id) this.deletedEventIds.add(msg.id);
                    if (msg.nymMessageId) this.deletedEventIds.add(msg.nymMessageId);
                    if (typeof this.persistDedupSets === 'function') this.persistDedupSets();
                }
                list.splice(idx, 1);
                this.channelDOMCache.delete(groupConvKey);
                if (typeof this.persistPMMessages === 'function') this.persistPMMessages(groupConvKey);
            } else if (this.deletedEventIds && this.deletedEventIds.add) {
                // Not in our local list yet — remember so a late-arriving copy stays gone.
                this.deletedEventIds.add(messageId);
                if (typeof this.persistDedupSets === 'function') this.persistDedupSets();
            }
        }
        const el = document.querySelector(`[data-message-id="${domId}"]`);
        if (el) el.remove();
    },

    // Add or update a group entry in the PM sidebar list
    addGroupConversation(groupId, name, members, timestamp = Date.now(), opts = {}) {
        const existing = this.groupConversations.get(groupId);
        const allMembers = [...new Set(members)];

        if (!existing) {
            // Don't re-show groups the user previously left
            if (this.leftGroups.has(groupId)) return;
            this.groupConversations.set(groupId, {
                name,
                members: allMembers,
                lastMessageTime: timestamp,
                createdBy: opts.createdBy || null,
                mods: Array.isArray(opts.mods) ? [...opts.mods] : [],
                banned: Array.isArray(opts.banned) ? [...opts.banned] : [],
                modLog: []
            });
            const pmList = document.getElementById('pmList');
            const item = document.createElement('div');
            item.className = 'pm-item group-item list-item';
            item.dataset.groupId = groupId;
            item.dataset.lastMessageTime = timestamp;
            item.innerHTML = this._buildGroupItemHTML(groupId, name, allMembers);
            item.dataset.action = 'openGroupItem';
            this.insertPMInOrder(item, pmList);

            // Apply active search filter
            const searchInput = document.getElementById('pmSearch');
            if (searchInput?.value.trim().length > 0) {
                const term = searchInput.value.toLowerCase();
                if (!name.toLowerCase().includes(term)) {
                    item.style.display = 'none';
                    item.classList.add('search-hidden');
                }
            }
            this.updateViewMoreButton('pmList');
        } else {
            // Merge members (new invitees may arrive with updated member list)
            const merged = [...new Set([...existing.members, ...allMembers])];
            const next = {
                ...existing,
                name: name || existing.name,
                members: merged,
                lastMessageTime: Math.max(existing.lastMessageTime || 0, timestamp),
                mods: Array.isArray(existing.mods) ? existing.mods : [],
                banned: Array.isArray(existing.banned) ? existing.banned : [],
                modLog: Array.isArray(existing.modLog) ? existing.modLog : []
            };
            // Adopt createdBy if missing and provided
            if (!next.createdBy && opts.createdBy) next.createdBy = opts.createdBy;
            this.groupConversations.set(groupId, next);
            this.updateGroupConversationUI(groupId);
        }
    },

    // Rebuild the inner HTML of a group PM list item
    _buildGroupItemHTML(groupId, name, members) {
        const otherMembers = members.filter(pk => pk !== this.pubkey);
        const displayMembers = otherMembers.slice(0, 3);
        const memberCount = members.length;

        const groupSvg = `<svg class="group-chat-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;

        const avatarStackHtml = displayMembers.length > 0
            ? `<div class="group-avatar-stack">${displayMembers.map((pk) => {
                const sk = this._safePubkey(pk);
                return `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="group-avatar-stack-img" data-avatar-pubkey="${sk}" alt="" loading="lazy">`;
            }).join('')}<span class="group-icon-badge">${groupSvg}</span></div>`
            : `<div class="group-icon-wrap">${groupSvg}</div>`;

        return `${avatarStackHtml}<span class="pm-name">${this.escapeHtml(name)}<span class="group-member-count"> · ${this.abbreviateNumber(memberCount)}</span></span><div class="channel-badges"><span class="unread-badge nm-hidden">0</span></div>`;
    },

    // Update the stacked reader avatars for group messages using waterfall logic:
    // Each reader's avatar only appears on the LATEST message they've read, since
    // reading message N implies having read all prior messages.
    updateGroupReaderAvatars(nymMessageId) {
        // Find the current group conversation
        if (!this.inPMMode || !this.currentGroup) {
            // Fallback: just update the single message
            this._updateSingleGroupReaders(nymMessageId);
            return;
        }
        const groupConvKey = this.getGroupConversationKey(this.currentGroup);
        const messages = this.pmMessages.get(groupConvKey);
        if (!messages) {
            this._updateSingleGroupReaders(nymMessageId);
            return;
        }

        // Build a map: readerPubkey -> latest nymMessageId they've read
        // by iterating own messages from newest to oldest
        const latestReadByReader = new Map(); // pubkey -> nymMessageId
        const ownMessages = messages
            .filter(m => m.isOwn && m.nymMessageId && this.groupMessageReaders.has(m.nymMessageId))
            .sort((a, b) => b.timestamp.getTime() - a.timestamp.getTime()); // newest first

        for (const msg of ownMessages) {
            const readers = this.groupMessageReaders.get(msg.nymMessageId);
            if (!readers) continue;
            for (const [pk] of readers) {
                if (!latestReadByReader.has(pk)) {
                    latestReadByReader.set(pk, msg.nymMessageId);
                }
            }
        }

        // Now for each own message, compute which readers to DISPLAY on it
        // (only those whose latest-read message is THIS message)
        const displayReaders = new Map(); // nymMessageId -> Map(pk -> nym)
        for (const [pk, msgId] of latestReadByReader) {
            if (!displayReaders.has(msgId)) displayReaders.set(msgId, new Map());
            const readers = this.groupMessageReaders.get(msgId);
            const name = readers ? readers.get(pk) : this.getNymFromPubkey(pk);
            displayReaders.get(msgId).set(pk, name);
        }

        // Update each visible own message's reader avatars
        for (const msg of ownMessages) {
            const el = document.querySelector(`.group-readers[data-nym-msg-id="${msg.nymMessageId}"]`);
            if (!el) continue;
            const waterfallReaders = displayReaders.get(msg.nymMessageId);
            const hasReaders = this._syncReaderAvatars(el, waterfallReaders);
            if (hasReaders && !el._readerLongPressBound) {
                this._bindReaderLongPress(el, msg.nymMessageId);
                el._readerLongPressBound = true;
            }
        }
    },

    // Fallback: update a single message's reader avatars without waterfall
    _updateSingleGroupReaders(nymMessageId) {
        const el = document.querySelector(`.group-readers[data-nym-msg-id="${nymMessageId}"]`);
        if (!el) return;
        const readers = this.groupMessageReaders.get(nymMessageId);
        if (!readers || readers.size === 0) return;
        this._syncReaderAvatars(el, readers);
        if (!el._readerLongPressBound) {
            this._bindReaderLongPress(el, nymMessageId);
            el._readerLongPressBound = true;
        }
    },

    // Build reader avatars HTML from a provided Map (used by waterfall)
    _buildGroupReadersHtmlFromMap(readersMap) {
        const MAX_VISIBLE = 3;
        if (!readersMap || readersMap.size === 0) return '';
        const entries = Array.from(readersMap.entries());
        const visible = entries.slice(0, MAX_VISIBLE);
        const overflow = readersMap.size - MAX_VISIBLE;
        const avatarHtml = visible.map(([pk, name]) => {
            const sk = this._safePubkey(pk);
            return `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="group-reader-avatar" title="Read by ${this.escapeHtml(name)}" data-avatar-pubkey="${sk}" loading="lazy">`;
        }).join('');
        const overflowHtml = overflow > 0
            ? `<span class="group-reader-overflow">+${this.abbreviateNumber(overflow)}</span>`
            : '';
        return avatarHtml + overflowHtml;
    },

    // Reconcile a .group-readers / .channel-readers element in place
    _syncReaderAvatars(el, readersMap) {
        const MAX_VISIBLE = 3;
        const entries = readersMap ? Array.from(readersMap.entries()) : [];
        const visible = entries.slice(0, MAX_VISIBLE);
        const overflow = entries.length - MAX_VISIBLE;

        const existing = new Map();
        for (const img of el.querySelectorAll('img.group-reader-avatar')) {
            if (img.dataset.avatarPubkey) existing.set(img.dataset.avatarPubkey, img);
        }

        let prev = null;
        for (const [pk, name] of visible) {
            const sk = this._safePubkey(pk);
            let img = existing.get(sk);
            if (img) {
                existing.delete(sk);
            } else {
                img = document.createElement('img');
                img.className = 'group-reader-avatar';
                img.loading = 'lazy';
                img.dataset.avatarPubkey = sk;
            }
            const src = this.getAvatarUrl(pk);
            if (img.getAttribute('src') !== src) img.src = src;
            const title = `Read by ${name}`;
            if (img.title !== title) img.title = title;
            const ref = prev ? prev.nextSibling : el.firstChild;
            if (ref !== img) el.insertBefore(img, ref);
            prev = img;
        }
        for (const img of existing.values()) img.remove();

        let badge = el.querySelector('.group-reader-overflow');
        if (overflow > 0) {
            const text = `+${this.abbreviateNumber(overflow)}`;
            if (!badge) {
                badge = document.createElement('span');
                badge.className = 'group-reader-overflow';
            }
            if (badge.textContent !== text) badge.textContent = text;
            const ref = prev ? prev.nextSibling : el.firstChild;
            if (ref !== badge) el.insertBefore(badge, ref);
        } else if (badge) {
            badge.remove();
        }
        return visible.length > 0;
    },

    // Channel-message reader avatars (kind 20000 message IDs keyed in channelMessageReaders)
    updateChannelReaderAvatars(messageId) {
        if (this.inPMMode || !this.currentGeohash) {
            this._updateSingleChannelReaders(messageId);
            return;
        }
        const storageKey = `#${this.currentGeohash}`;
        const messages = this.messages.get(storageKey);
        if (!messages) {
            this._updateSingleChannelReaders(messageId);
            return;
        }

        const latestReadByReader = new Map();
        const ownMessages = messages
            .filter(m => m.isOwn && m.id && this.channelMessageReaders.has(m.id))
            .sort((a, b) => (b.created_at || 0) - (a.created_at || 0));

        for (const msg of ownMessages) {
            const readers = this.channelMessageReaders.get(msg.id);
            if (!readers) continue;
            for (const [pk] of readers) {
                if (!latestReadByReader.has(pk)) latestReadByReader.set(pk, msg.id);
            }
        }

        const displayReaders = new Map();
        for (const [pk, msgId] of latestReadByReader) {
            if (!displayReaders.has(msgId)) displayReaders.set(msgId, new Map());
            const readers = this.channelMessageReaders.get(msgId);
            const name = readers ? readers.get(pk) : this.getNymFromPubkey(pk);
            displayReaders.get(msgId).set(pk, name);
        }

        for (const msg of ownMessages) {
            const el = document.querySelector(`.channel-readers[data-msg-id="${msg.id}"]`);
            if (!el) continue;
            const waterfallReaders = displayReaders.get(msg.id);
            const hasReaders = this._syncReaderAvatars(el, waterfallReaders);
            if (hasReaders && !el._readerLongPressBound) {
                this._bindChannelReaderLongPress(el, msg.id);
                el._readerLongPressBound = true;
            }
        }
    },

    _updateSingleChannelReaders(messageId) {
        const el = document.querySelector(`.channel-readers[data-msg-id="${messageId}"]`);
        if (!el) return;
        const readers = this.channelMessageReaders.get(messageId);
        if (!readers || readers.size === 0) return;
        this._syncReaderAvatars(el, readers);
        if (!el._readerLongPressBound) {
            this._bindChannelReaderLongPress(el, messageId);
            el._readerLongPressBound = true;
        }
    },

    _buildChannelReadersHtml(messageId) {
        const readers = this.channelMessageReaders.get(messageId);
        if (!readers || readers.size === 0) return '';
        return this._buildGroupReadersHtmlFromMap(readers);
    },

    _bindChannelReaderLongPress(el, messageId) {
        let timer = null;
        const start = (e) => {
            if (e.type === 'mousedown' && e.button !== 0) return;
            e.stopPropagation();
            timer = setTimeout(() => {
                timer = null;
                window.nymHapticTap && window.nymHapticTap();
                this.showChannelReadersModal(messageId, el);
            }, 500);
        };
        const cancel = (e) => { if (e) e.stopPropagation(); if (timer) { clearTimeout(timer); timer = null; } };
        el.addEventListener('mousedown', start);
        el.addEventListener('touchstart', start, { passive: false });
        el.addEventListener('mouseup', cancel);
        el.addEventListener('mouseleave', cancel);
        el.addEventListener('touchend', cancel);
        el.addEventListener('touchcancel', cancel);
        el.addEventListener('contextmenu', (e) => { e.preventDefault(); e.stopPropagation(); cancel(e); });
        el.style.cursor = 'pointer';
    },

    showChannelReadersModal(messageId, anchorEl) {
        const readers = this.channelMessageReaders.get(messageId);
        if (!readers || readers.size === 0) return;
        this._showReadersModalFromMap(readers, anchorEl);
    },

    // Returns the inner HTML for a .group-readers span: up to 3 avatars + overflow badge
    _buildGroupReadersHtml(nymMessageId) {
        const MAX_VISIBLE = 3;
        const readers = this.groupMessageReaders.get(nymMessageId);
        if (!readers || readers.size === 0) return '';
        const entries = Array.from(readers.entries());
        const visible = entries.slice(0, MAX_VISIBLE);
        const overflow = readers.size - MAX_VISIBLE;
        const avatarHtml = visible.map(([pk, name]) => {
            const sk = this._safePubkey(pk);
            return `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="group-reader-avatar" title="Read by ${this.escapeHtml(name)}" data-avatar-pubkey="${sk}" loading="lazy">`;
        }).join('');
        const overflowHtml = overflow > 0
            ? `<span class="group-reader-overflow">+${this.abbreviateNumber(overflow)}</span>`
            : '';
        return avatarHtml + overflowHtml;
    },

    // Attach a 500ms long-press to a .group-readers element to open the readers modal
    _bindReaderLongPress(el, nymMessageId) {
        let timer = null;
        const start = (e) => {
            if (e.type === 'mousedown' && e.button !== 0) return;
            e.stopPropagation();
            timer = setTimeout(() => {
                timer = null;
                window.nymHapticTap && window.nymHapticTap();
                this.showReadersModal(nymMessageId, el);
            }, 500);
        };
        const cancel = (e) => { if (e) e.stopPropagation(); if (timer) { clearTimeout(timer); timer = null; } };
        el.addEventListener('mousedown', start);
        el.addEventListener('touchstart', start, { passive: false });
        el.addEventListener('mouseup', cancel);
        el.addEventListener('mouseleave', cancel);
        el.addEventListener('touchend', cancel);
        el.addEventListener('touchcancel', cancel);
        el.addEventListener('contextmenu', (e) => { e.preventDefault(); e.stopPropagation(); cancel(e); });
        el.style.cursor = 'pointer';
    },

    showReadersModal(nymMessageId, anchorEl) {
        const readers = this.groupMessageReaders.get(nymMessageId);
        if (!readers || readers.size === 0) return;
        this._showReadersModalFromMap(readers, anchorEl);
    },

    _showReadersModalFromMap(readers, anchorEl) {
        this.closeReadersModal();
        if (!readers || readers.size === 0) return;

        const userItems = Array.from(readers.entries()).map(([pubkey, nym]) => {
            const isYou = pubkey === this.pubkey;
            const baseNym = this.stripPubkeySuffix(nym);
            const suffix = this.getPubkeySuffix(pubkey);
            const safePk = this._safePubkey(pubkey);
            const avatarSrc = this.escapeHtml(this.getAvatarUrl(pubkey));
            return `<div class="reactors-modal-user readers-modal-user" data-pubkey="${safePk}">
                <img src="${avatarSrc}" class="readers-modal-avatar" data-avatar-pubkey="${safePk}" loading="lazy">
                <span class="reactors-modal-nym">${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span></span>
                ${isYou ? '<span class="reactors-modal-you">you</span>' : ''}
            </div>`;
        }).join('');

        const modal = document.createElement('div');
        modal.className = 'reactors-modal readers-modal';
        modal.innerHTML = `
            <div class="reactors-modal-header">Seen by <span class="reactors-modal-count">${this.abbreviateNumber(readers.size)}</span></div>
            <div class="reactors-modal-list">${userItems}</div>
        `;
        document.body.appendChild(modal);
        this.readersModal = modal;

        // Position above/below the anchor — batch style writes
        const rect = anchorEl.getBoundingClientRect();
        const right = Math.max(4, window.innerWidth - rect.right);
        const approxHeight = Math.min(readers.size * 44 + 50, 300);
        const verticalDecl = (rect.top > approxHeight + 20)
            ? `bottom:${window.innerHeight - rect.top + 4}px;`
            : `top:${rect.bottom + 6}px;`;
        modal.style.cssText += `right:${right}px;${verticalDecl}`;
    },

    closeReadersModal() {
        if (this.readersModal) {
            this.readersModal.remove();
            this.readersModal = null;
        }
    },

    _groupItemSignature(group) {
        if (!group) return '';
        const otherMembers = (group.members || []).filter(pk => pk !== this.pubkey);
        const displayPks = otherMembers.slice(0, 3).map(pk => this._safePubkey(pk)).join(',');
        return `${displayPks}|${group.members ? group.members.length : 0}|${group.name || ''}`;
    },

    // Re-render a group item's inner HTML (e.g., after member list changes)
    updateGroupConversationUI(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        const pmList = document.getElementById('pmList');
        const item = pmList?.querySelector(`[data-group-id="${groupId}"]`);
        if (item) {
            const sig = this._groupItemSignature(group);
            if (item.dataset.groupSig !== sig) {
                item.innerHTML = this._buildGroupItemHTML(groupId, group.name, group.members);
                item.dataset.groupSig = sig;
            }
            item.dataset.action = 'openGroupItem';
        }
    },

    // Refresh group sidebar avatar tooltips and in-chat header when a member's
    // profile (nickname) changes. The group sidebar item's name reflects the
    // group's subject, not member nicknames, but the avatar stack and the
    // current group's header reference per-member nyms via the users map.
    updateGroupMembershipDisplay(memberPubkey) {
        if (!memberPubkey || !this.groupConversations) return;
        for (const [groupId, group] of this.groupConversations.entries()) {
            if (!group || !Array.isArray(group.members)) continue;
            if (!group.members.includes(memberPubkey)) continue;
            // Re-render the sidebar item so any per-member metadata (e.g. avatar
            // alt/title attributes) reflects the latest profile data.
            this.updateGroupConversationUI(groupId);
            // If we're currently viewing this group, refresh its header so the
            // (re)rendered nickname appears in the title bar.
            if (this.inPMMode && this.currentGroup === groupId) {
                const channelEl = document.getElementById('currentChannel');
                if (channelEl) {
                    const otherMembers = group.members.filter(pk => pk !== this.pubkey);
                    const displayPks = otherMembers.slice(0, 4).map(pk => this._safePubkey(pk));
                    const sig = `${displayPks.join(',')}|${group.members.length}|${group.name || ''}`;
                    if (channelEl.dataset.groupHeaderSig !== sig) {
                        const headerAvatars = displayPks.map((sk, i) => {
                            const pk = otherMembers[i];
                            const src = this.getAvatarUrl(pk);
                            return `<img src="${this.escapeHtml(src)}" class="avatar-message group-header-avatar" data-avatar-pubkey="${sk}" alt="" loading="lazy">`;
                        }).join('');
                        const groupSvg = `<svg class="group-chat-icon group-header-svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;
                        const memberLabel = `<span class="nm-grp-1">(${this.abbreviateNumber(group.members.length)} members)</span>`;
                        const headerHtml = `<span class="group-header-icon">${groupSvg}</span>${headerAvatars}<span class="${otherMembers.length > 0 ? 'nm-grp-ml8' : ''}">${this.escapeHtml(group.name)}</span>${memberLabel}`;
                        channelEl.innerHTML = headerHtml;
                        channelEl.dataset.groupHeaderSig = sig;
                    }
                }
            }
        }
    },

    // Open a group conversation in the main chat area
    openGroup(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;

        this._saveCurrentDraft();
        const prevChannelKey = this.currentGeohash || this.currentChannel;
        if (prevChannelKey && typeof this.closeChannelSubscription === 'function') {
            this.closeChannelSubscription(prevChannelKey);
        }
        this.inPMMode = true;
        this.currentPM = null;
        this.currentGroup = groupId;
        this.currentChannel = null;
        this.currentGeohash = null;
        this.userScrolledUp = false;
        if (this.pendingEdit) this.cancelEditMessage();

        // Track navigation history
        this._pushNavigation({ type: 'group', groupId });

        // Re-render typing indicator for the new conversation
        this.renderTypingIndicator();

        // Build stacked avatar header
        const otherMembers = group.members.filter(pk => pk !== this.pubkey);
        const displayPks = otherMembers.slice(0, 4).map(pk => this._safePubkey(pk));
        const headerAvatars = displayPks.map((sk, i) => {
            const pk = otherMembers[i];
            const src = this.getAvatarUrl(pk);
            return `<img src="${this.escapeHtml(src)}" class="avatar-message group-header-avatar" data-avatar-pubkey="${sk}" alt="" loading="lazy">`;
        }).join('');

        const groupSvg = `<svg class="group-chat-icon group-header-svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;
        const memberLabel = `<span class="nm-grp-1">(${this.abbreviateNumber(group.members.length)} members)</span>`;
        const headerHtml = `<span class="group-header-icon">${groupSvg}</span>${headerAvatars}<span class="${otherMembers.length > 0 ? 'nm-grp-ml8' : ''}">${this.escapeHtml(group.name)}</span>${memberLabel}`;

        const channelEl = document.getElementById('currentChannel');
        channelEl.innerHTML = headerHtml;
        channelEl.dataset.groupHeaderSig = `${displayPks.join(',')}|${group.members.length}|${group.name || ''}`;
        delete channelEl.dataset.pmHeaderSig;
        const lockSvg = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="nm-grp-2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>';
        const metaText = `${lockSvg}End-to-end encrypted group chat`;
        document.getElementById('channelMeta').innerHTML = metaText;

        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) shareBtn.style.display = 'none';
        const favBtn = document.getElementById('favoriteChannelBtn');
        if (favBtn) favBtn.style.display = 'none';

        // Mark only the matching group item as active
        document.querySelectorAll('.channel-item').forEach(i => i.classList.remove('active'));
        document.querySelectorAll('.pm-item').forEach(i => {
            i.classList.toggle('active', i.dataset.groupId === groupId);
        });

        const groupConvKey = this.getGroupConversationKey(groupId);
        this.clearUnreadCount(groupConvKey);
        this.loadPMMessages(groupConvKey);

        // Restore any unsent input previously typed for this conversation
        this._restoreDraftForContext();

        this.hideAutocomplete();
        this.hideChannelAutocomplete();
        this.hideEmojiAutocomplete();
        this._focusMessageInput();

        if (window.innerWidth <= 768) this.closeSidebar();
    },

    // Bubble a group item to the top of the PM list
    moveGroupToTop(groupId, messageTimestamp) {
        const pmList = document.getElementById('pmList');
        const groupItem = pmList?.querySelector(`[data-group-id="${groupId}"]`);
        if (!groupItem) return;

        const ts = messageTimestamp || Date.now();
        const currentTs = parseInt(groupItem.dataset.lastMessageTime || '0');
        const newTs = Math.max(ts, currentTs);
        groupItem.dataset.lastMessageTime = newTs;
        const group = this.groupConversations.get(groupId);
        if (group) group.lastMessageTime = newTs;

        groupItem.remove();
        this.insertPMInOrder(groupItem, pmList);

        const searchInput = document.getElementById('pmSearch');
        if (searchInput?.value.trim().length > 0) {
            const term = searchInput.value.toLowerCase();
            const nameEl = groupItem.querySelector('.pm-name');
            if (nameEl && !nameEl.textContent.toLowerCase().includes(term)) {
                groupItem.style.display = 'none';
                groupItem.classList.add('search-hidden');
            }
        }
    },

    async sendEditedGroupMessage(newContent, originalMessageId, groupId, originalNymMessageId) {
        try {
            if (!this._canSendGiftWraps()) {
                this.displaySystemMessage('Group messages require a logged-in account');
                return false;
            }

            const group = this.groupConversations.get(groupId);
            if (!group) return false;

            const now = Math.floor(Date.now() / 1000);
            const nymMessageId = this._generateSharedEventId();

            const tags = group.members.map(pk => ['p', pk]);
            tags.push(['g', groupId]);
            tags.push(['subject', group.name]);
            tags.push(['x', nymMessageId]);
            tags.push(['edit', originalNymMessageId || originalMessageId]); // Reference the original message

            const rumor = { kind: 14, created_at: now, tags, content: newContent, pubkey: this.pubkey };
            const expirationTs = (this.settings?.dmForwardSecrecyEnabled && this.settings?.dmTTLSeconds > 0)
                ? now + this.settings.dmTTLSeconds : null;

            // Track edit locally
            const lookupId = originalNymMessageId || originalMessageId;
            this.editedMessages.set(lookupId, {
                newContent,
                editEventId: nymMessageId,
                timestamp: new Date(now * 1000)
            });

            // Update stored messages
            const groupConvKey = this.getGroupConversationKey(groupId);
            const msgs = this.pmMessages.get(groupConvKey);
            if (msgs) {
                const msg = msgs.find(m => m.nymMessageId === lookupId || m.id === lookupId);
                if (msg) {
                    msg.content = newContent;
                    msg.isEdited = true;
                }
            }

            // Update DOM in-place
            this.updateMessageInDOM(lookupId, newContent);

            // Send gift wraps to all group members
            await this._sendGiftWrapsAsync(group.members, rumor, expirationTs, groupId);
            return true;
        } catch (error) {
            this.displaySystemMessage('Failed to edit message: ' + error.message);
            return false;
        }
    },

    // /group @alice @bob [GroupName] — create a new private group
    async cmdGroup(args) {
        if (!this._canSendGiftWraps()) {
            this.displaySystemMessage('Creating groups requires a logged-in account (not pseudonymous mode)');
            return;
        }
        if (!args) {
            this.displaySystemMessage('Usage: /group @user1 @user2 [GroupName]  — creates a private encrypted group');
            return;
        }

        const parts = args.trim().split(/\s+/);
        const memberNyms = [];
        const nameWords = [];
        for (const part of parts) {
            if (part.startsWith('@')) {
                // @nym or @nym#suffix
                memberNyms.push(part.slice(1));
            } else if (/^[0-9a-f]{64}$/i.test(part)) {
                // raw pubkey
                memberNyms.push(part);
            } else if (part.includes('#') && !part.startsWith('#')) {
                // nym#suffix disambiguation without @ (e.g. anon_pulse#35b5)
                memberNyms.push(part);
            } else {
                nameWords.push(part);
            }
        }

        if (memberNyms.length === 0) {
            this.displaySystemMessage('Usage: /group @user1 @user2 [GroupName]  — at least one user required (@user, user#xxxx, or pubkey)');
            return;
        }

        const resolvedMembers = [];
        for (const memberNym of memberNyms) {
            const pubkey = this.resolvePubkeyFromNym(memberNym);
            if (!pubkey) {
                this.displaySystemMessage(`User @${memberNym} not found. They need to be visible in the current channel first.`);
                return;
            }
            if (pubkey === this.pubkey) continue; // self is always included
            if (this.isVerifiedBot(pubkey)) {
                this.displaySystemMessage("Nymbot can't be added to group chats. Use ?ask or @Nymbot in a channel instead.");
                return;
            }
            if (!resolvedMembers.includes(pubkey)) resolvedMembers.push(pubkey);
        }

        if (resolvedMembers.length === 0) {
            this.displaySystemMessage('No valid users found to create a group with.');
            return;
        }

        const groupName = nameWords.join(' ').trim() ||
            [this.getNymFromPubkey(this.pubkey), ...resolvedMembers.slice(0, 2).map(pk => this.getNymFromPubkey(pk))].join(', ');

        this.displaySystemMessage(`Creating group "${groupName}"...`);
        const groupId = await this.createGroup(groupName, resolvedMembers);
        if (groupId) {
            this.displaySystemMessage(`Group "${groupName}" created with ${resolvedMembers.length + 1} members`);
        }
    },

    // /groupinfo — list members of the current group, including owner and moderators
    cmdGroupInfo() {
        if (!this.inPMMode || !this.currentGroup) {
            this.displaySystemMessage('You must be in a group conversation to use /groupinfo');
            return;
        }
        const group = this.groupConversations.get(this.currentGroup);
        if (!group) return;
        const mods = Array.isArray(group.mods) ? group.mods : [];
        // Sort: owner first, then mods, then everyone else (each group alphabetized by nym)
        const ownerPk = group.createdBy;
        const sorted = [...group.members].sort((a, b) => {
            const rank = (pk) => (pk === ownerPk ? 0 : mods.includes(pk) ? 1 : 2);
            const ra = rank(a), rb = rank(b);
            if (ra !== rb) return ra - rb;
            const na = (this.getNymFromPubkey(a) || '').toLowerCase();
            const nb = (this.getNymFromPubkey(b) || '').toLowerCase();
            return na.localeCompare(nb);
        });
        const memberList = sorted.map(pk => {
            const name = this.getNymFromPubkey(pk);
            const labels = [];
            if (pk === ownerPk) labels.push('owner');
            else if (mods.includes(pk)) labels.push('mod');
            if (pk === this.pubkey) labels.push('you');
            const suffix = labels.length ? ` (${labels.join(', ')})` : '';
            return `  @${name}${suffix}`;
        }).join('\n');
        const ownerLine = ownerPk
            ? `Owner: @${this.getNymFromPubkey(ownerPk)}`
            : 'Owner: unknown';
        const modLine = mods.length > 0
            ? `Moderators: ${mods.map(pk => '@' + this.getNymFromPubkey(pk)).join(', ')}`
            : 'Moderators: none';
        this.displaySystemMessage(`Group: "${group.name}"\n${ownerLine}\n${modLine}\nMembers (${group.members.length}):\n${memberList}`);
    },

    toggleGroupMentionsOnly(enabled) {
        this.groupNotifyMentionsOnly = enabled;
        localStorage.setItem('nym_group_notify_mentions_only', String(enabled));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

});
