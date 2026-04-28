// groups.js - NIP-17 group chats: create, send, ephemeral keys, members, readers, history
// Methods are attached to NYM.prototype.

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

    // Rotate own ephemeral key for a group (called after sending a message).
    // Generates a fresh random keypair. Previous keys are retained for
    // in-flight message tolerance and multi-device sync.
    _rotateSelfEphemeralKey(groupId) {
        const NT = window.NostrTools;
        const ek = this._getGroupEphemeralKeys(groupId);
        if (!ek.self) {
            this._ensureSelfEphemeralKey(groupId);
        }
        // Move current to prev
        if (ek.self.current) {
            ek.self.prev.unshift(ek.self.current);
            if (ek.self.prev.length > 10) ek.self.prev = ek.self.prev.slice(0, 10);
        }
        // Generate fresh random keypair
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

    // Collect ephemeral pubkeys to subscribe to on relays.
    // Includes current + all prev keys (prev is already capped at 10 by rotation).
    // We subscribe to all stored keys so messages to any known key get delivered.
    _getAllSelfEphemeralPubkeys() {
        // Reuse the full set — prev is already bounded by _rotateSelfEphemeralKey
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

                // Add any synced prev keys we don't have
                for (const k of synced.self.prev) {
                    if (!knownPks.has(k.pk)) {
                        local.self.prev.push(k);
                        knownPks.add(k.pk);
                    }
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
            for (const [groupId, entry] of Object.entries(data)) {
                this.groupEphemeralKeys.set(groupId, this._deserializeEphemeralEntry(entry));
            }
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
                };
            }
            localStorage.setItem(`nym_groups_${this.pubkey}`, JSON.stringify(data));
        } catch (_) { }
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

    // Reload leftGroups for the current pubkey (called after pubkey is known)
    _loadLeftGroups() {
        if (!this.pubkey) return;
        try {
            const perUser = localStorage.getItem(`nym_left_groups_${this.pubkey}`);
            if (perUser) {
                const arr = JSON.parse(perUser);
                for (const gid of arr) this.leftGroups.add(gid);
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
                // instead of showing "anon" while waiting for relay profile fetches.
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
                    this.addGroupConversation(groupId, group.name, group.members || [], group.lastMessageTime || Date.now());
                    // Restore createdBy which addGroupConversation doesn't accept
                    const g = this.groupConversations.get(groupId);
                    if (g) {
                        if (group.createdBy) g.createdBy = group.createdBy;
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
    },

    // Handle incoming group message (rumor with 'g' tag)
    async handleGroupMessage(rumor, event, senderPubkey, isOwn) {
        const groupTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'g' && t[1]);
        if (!groupTag) return;
        const groupId = groupTag[1];
        const groupConvKey = this.getGroupConversationKey(groupId);

        // Extract sender's next ephemeral pubkey from the rumor (timing-attack mitigation).
        // When present, future messages to this sender will be encrypted to this key.
        if (!isOwn) {
            const ephTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'ephemeral_pk' && t[1]);
            if (ephTag) {
                this._updateMemberEphemeralKey(groupId, senderPubkey, ephTag[1], rumor.created_at || 0);
                this._saveEphemeralKeys();
            }
        }

        // Filter group invites based on acceptPMs setting
        if (!isOwn && this.settings.acceptPMs !== 'enabled' && !this.groupConversations.has(groupId)) {
            if (this.settings.acceptPMs === 'disabled') return;
            if (this.settings.acceptPMs === 'friends' && !this.isFriend(senderPubkey)) return;
        }

        // Drop all messages from blocked senders, including group invites.
        if (!isOwn && (this.blockedUsers.has(senderPubkey) || this.isNymBlocked(this.getNymFromPubkey(senderPubkey)))) {
            return;
        }

        // Determine message type early so we can decide whether to drop it
        const typeTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'type' && t[1]);
        const msgType = typeTag ? typeTag[1] : null;

        // Drop messages for groups the user has left, unless it's a reinvite
        if (this.leftGroups.has(groupId) && msgType !== 'group-invite' && msgType !== 'group-add-member') {
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
            // Re-invited to a group we previously left — clear the left state
            if (this.leftGroups.has(groupId)) {
                this.leftGroups.delete(groupId);
                this._saveLeftGroups();
                this._debouncedNostrSettingsSave();
            }
            const grp = this.groupConversations.get(groupId);
            if (grp && !grp.createdBy) {
                grp.createdBy = senderPubkey;
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
                const isHistorical = (Math.floor(Date.now() / 1000) - inviteTsSec) > 10;
                const groupConvKeyForNotif = this.getGroupConversationKey(groupId);
                if (!isHistorical) {
                    this.showNotification(`Group invite: ${groupName}`, inviteBody, {
                        type: 'group',
                        groupId,
                        id: groupConvKeyForNotif,
                        pubkey: senderPubkey
                    });
                } else {
                    this._addNotificationToHistory(`Group invite: ${groupName}`, inviteBody, {
                        type: 'group',
                        groupId,
                        id: groupConvKeyForNotif,
                        pubkey: senderPubkey
                    }, inviteTsSec * 1000);
                }
            }

            // Fall through to display the invite message inline
        }

        // group-add-member: show as system message, not a chat bubble.
        if (typeTag && typeTag[1] === 'group-add-member') {
            // Re-added to a group we previously left — clear the left state
            if (this.leftGroups.has(groupId)) {
                this.leftGroups.delete(groupId);
                this._saveLeftGroups();
            }
            const memberPubkeys = (rumor.tags || [])
                .filter(t => Array.isArray(t) && t[0] === 'p' && t[1])
                .map(t => t[1]);
            // Determine who was added by comparing new member list with existing group
            const existingGroup = this.groupConversations.get(groupId);
            const existingMembers = existingGroup ? new Set(existingGroup.members) : new Set();
            const newMembers = memberPubkeys.filter(pk => !existingMembers.has(pk));
            this.addGroupConversation(groupId, groupName, memberPubkeys, (rumor.created_at || Math.floor(Date.now() / 1000)) * 1000);
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
            // Fetch profiles so nicknames display correctly instead of anon#xxxx
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
                document.getElementById('pmList')?.querySelector(`[data-group-id="${groupId}"]`)?.remove();
                this.updateViewMoreButton('pmList');
                if (this.currentGroup === groupId) {
                    this.currentGroup = null;
                    this.inPMMode = false;
                    this.switchChannel(this.currentChannel || 'nym', this.currentChannel || 'nym');
                    this.displaySystemMessage(`You were removed from "${groupName}" by ${removerName}.`);
                }
            } else {
                // Another member was kicked — update local state and show system notice
                const grp = this.groupConversations.get(groupId);
                if (grp) {
                    grp.members = grp.members.filter(pk => pk !== removedPubkey);
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
            _seq: ++this._msgSeq,
            timestamp: new Date(tsSec * 1000),
            isOwn,
            isPM: true,
            isGroup: true,
            groupId,
            conversationKey: groupConvKey,
            conversationPubkey: null,
            eventKind: 1059,
            isHistorical: (Math.floor(Date.now() / 1000) - tsSec) > 10,
            nymMessageId: nymMsgId,
            deliveryStatus: isOwn ? 'sent' : undefined
        };

        list.push(msg);
        list.sort((a, b) => {
            const dt = (a.created_at || 0) - (b.created_at || 0);
            if (dt !== 0) return dt;
            return (a._seq || 0) - (b._seq || 0);
        });
        if (list.length > this.pmStorageLimit) list = list.slice(-this.pmStorageLimit);
        this.pmMessages.set(groupConvKey, list);

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

        const senderBlocked = this.blockedUsers.has(senderPubkey) || this.isNymBlocked(msg.author) || this.hasBlockedKeyword(msg.content, msg.author);
        if (this.inPMMode && this.currentGroup === groupId) {
            // displayMessage already filters blocked senders; no extra check needed here
            this.displayMessage(msg);
            // Force auto-scroll to bottom for group messages
            this._scheduleScrollToBottom();
        } else {
            // Not viewing this group — invalidate DOM cache so it
            // re-renders fresh when the user opens this group.
            this.channelDOMCache.delete(groupConvKey);
            if (!isOwn && !senderBlocked) {
                if (!msg.isHistorical) {
                    // Always update sidebar unread count for all group messages
                    this.updateUnreadCount(groupConvKey);
                }
                // Notify for all group messages unless mentions-only is enabled
                const shouldNotifyGroup = !this.groupNotifyMentionsOnly || this.isMentioned(messageContent);
                if (shouldNotifyGroup) {
                    if (!msg.isHistorical) {
                        this.showNotification(`${groupName}: ${msg.author}`, messageContent, {
                            type: 'group',
                            groupId,
                            id: groupConvKey,
                            pubkey: senderPubkey
                        });
                    } else {
                        this._addNotificationToHistory(`${groupName}: ${msg.author}`, messageContent, {
                            type: 'group',
                            groupId,
                            id: groupConvKey,
                            pubkey: senderPubkey
                        }, msg.timestamp.getTime());
                    }
                }
            }
        }

        // Send read receipt back to sender so they can show our avatar as "read"
        if (!isOwn && !msg.isHistorical && this._canSendGiftWraps() && nymMsgId) {
            this.sendNymReceipt(nymMsgId, 'read', senderPubkey);
        }
    },

    // Create a new private group and send invites to all members via NIP-17 gift wraps.
    async createGroup(name, memberPubkeys) {
        if (!this._canSendGiftWraps()) {
            this.displaySystemMessage('Creating groups requires a logged-in account (not anonymous mode)');
            return null;
        }

        // Always include self as a member
        const allMembers = [...new Set([...memberPubkeys, this.pubkey])];

        const groupId = this.generateUUID();
        const now = Math.floor(Date.now() / 1000);
        const nymMessageId = this.generateUUID();
        const inviteContent = `You've been added to group "${name}" (${allMembers.length} members).`;

        const tags = allMembers.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', name]);
        tags.push(['type', 'group-invite']);
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

        // addGroupConversation creates the sidebar item (existing is null at this point)
        this.addGroupConversation(groupId, name, allMembers, Date.now());
        // Mark this user as the group owner
        const grp = this.groupConversations.get(groupId);
        if (grp) grp.createdBy = this.pubkey;
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

        group.members = [...group.members, newMemberPubkey];
        this.groupConversations.set(groupId, group);

        // Fetch profile for the new member if we don't have it yet so nicknames display correctly
        if (!this.users.has(newMemberPubkey)) {
            await this.fetchProfileDirect(newMemberPubkey);
        }

        const now = Math.floor(Date.now() / 1000);
        const nymMessageId = this.generateUUID();
        const newMemberName = this.getNymFromPubkey(newMemberPubkey);
        const inviterName = this.getNymFromPubkey(this.pubkey);
        const addContent = `${newMemberName} was added by ${inviterName}.`;

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['type', 'group-add-member']);
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
        for (const pubkey of members) {
            // Use ephemeral recipient key when available (timing-attack mitigation)
            const encryptTo = groupId ? this._getEncryptionPubkey(groupId, pubkey) : pubkey;
            const wrapped = this.nip59WrapEvent(rumor, this.privkey, encryptTo, expirationTs);
            this.sendDMToRelays(['EVENT', wrapped]);

            if (this.activeCosmetics?.has('cosmetic-redacted')) {
                setTimeout(() => { this.publishDeletionEvent(wrapped.id, 1059); }, 600000);
            }
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

        for (const pubkey of members) {
            try {
                // Use ephemeral recipient key when available (timing-attack mitigation)
                const encryptTo = groupId ? this._getEncryptionPubkey(groupId, pubkey) : pubkey;

                // Seal: encrypt rumor to recipient via extension or remote signer
                const sealContent = useExtension
                    ? await window.nostr.nip44.encrypt(encryptTo, JSON.stringify(rumorWithId))
                    : await _nip46Encrypt(encryptTo, JSON.stringify(rumorWithId));
                const sealUnsigned = {
                    kind: 13, content: sealContent, created_at: this.randomNow(), tags: []
                };
                const seal = useExtension
                    ? await window.nostr.signEvent(sealUnsigned)
                    : await _nip46SignEvent(sealUnsigned);

                // Wrap with local ephemeral keypair
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

                if (this.activeCosmetics?.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(wrapped.id, 1059); }, 600000);
                }
            } catch (e) {
                console.warn('[GiftWrap] Remote wrap failed for', pubkey, e);
            }
        }
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
        const now = Math.floor(Date.now() / 1000);

        const nymMessageId = this.generateUUID();

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['x', nymMessageId]);

        // Ephemeral key rotation: generate next key and advertise it inside the rumor.
        // Recipients will encrypt future messages to this key instead of our real pubkey.
        const nextEph = this._rotateSelfEphemeralKey(groupId);
        tags.push(['ephemeral_pk', nextEph.pk]);

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
            const dt = (a.created_at || 0) - (b.created_at || 0);
            if (dt !== 0) return dt;
            return (a._seq || 0) - (b._seq || 0);
        });
        if (groupList.length > this.pmStorageLimit) this.pmMessages.set(groupConvKey, groupList.slice(-this.pmStorageLimit));
        this.channelDOMCache.delete(groupConvKey);
        this.moveGroupToTop(groupId);

        if (this.inPMMode && this.currentGroup === groupId) {
            this.displayMessage(msg);
        }

        // Send gift wraps using ephemeral recipient keys when available
        await this._sendGiftWrapsAsync(group.members, rumor, expirationTs, groupId);
        this._saveEphemeralKeys();

        // Refresh relay subscriptions so we receive messages to our new ephemeral key
        this._refreshEphemeralSubscriptions();

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
                tags.push(['x', this.generateUUID()]);
                const rumor = { kind: 14, created_at: now, tags, content: leaveContent, pubkey: this.pubkey };
                // Send to remaining members only (not self), using ephemeral keys
                await this._sendGiftWrapsAsync(otherMembers, rumor, null, groupId);
            }
        }
        // Track the left group so it doesn't reappear from stale relay data
        this.leftGroups.add(groupId);
        this._saveLeftGroups();

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
        const pmList = document.getElementById('pmList');
        const item = pmList?.querySelector(`[data-group-id="${groupId}"]`);
        if (item) item.remove();
        if (this.currentGroup === groupId) {
            this.currentGroup = null;
            this.inPMMode = false;
            const fallback = this.currentChannel || 'nym';
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

    // Remove a member from the current group (owner only) via NIP-17 gift-wrapped rumor.
    async kickFromGroup(pubkey) {
        this.closeContextMenu();
        const groupId = this.currentGroup;
        if (!groupId || !this._canSendGiftWraps()) return;
        const group = this.groupConversations.get(groupId);
        if (!group || group.createdBy !== this.pubkey) return;
        if (!group.members.includes(pubkey)) return;

        // Fetch profile if we don't have it yet so the nickname displays correctly
        if (!this.users.has(pubkey)) {
            await this.fetchProfileDirect(pubkey);
        }

        const kickedName = this.getNymFromPubkey(pubkey);
        const kickerName = this.getNymFromPubkey(this.pubkey);
        const content = `${kickedName} was removed by ${kickerName}.`;
        const now = Math.floor(Date.now() / 1000);
        const nymMessageId = this.generateUUID();

        const tags = group.members.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['type', 'group-remove-member']);
        tags.push(['kick', pubkey]);
        tags.push(['x', nymMessageId]);
        const rumor = { kind: 14, created_at: now, tags, content, pubkey: this.pubkey };

        // Send to everyone including the kicked member so they can remove themselves
        await this._sendGiftWrapsAsync(group.members, rumor, null, groupId);

        // Update local state immediately — also clean up kicked member's ephemeral key
        const ek = this.groupEphemeralKeys.get(groupId);
        if (ek) { delete ek.members[pubkey]; this._saveEphemeralKeys(); }
        group.members = group.members.filter(pk => pk !== pubkey);
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        this.updateGroupConversationUI(groupId);
        this.openGroup(groupId); // refresh header member count
        this.displaySystemMessage(content);
    },

    // Add or update a group entry in the PM sidebar list
    addGroupConversation(groupId, name, members, timestamp = Date.now()) {
        const existing = this.groupConversations.get(groupId);
        const allMembers = [...new Set(members)];

        if (!existing) {
            // Don't re-show groups the user previously left
            if (this.leftGroups.has(groupId)) return;
            this.groupConversations.set(groupId, {
                name, members: allMembers, lastMessageTime: timestamp, createdBy: null
            });
            const pmList = document.getElementById('pmList');
            const item = document.createElement('div');
            item.className = 'pm-item group-item list-item';
            item.dataset.groupId = groupId;
            item.dataset.lastMessageTime = timestamp;
            item.innerHTML = this._buildGroupItemHTML(groupId, name, allMembers);
            item.onclick = () => this.openGroup(groupId);
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
            this.groupConversations.set(groupId, {
                ...existing,
                name: name || existing.name,
                members: merged,
                lastMessageTime: Math.max(existing.lastMessageTime || 0, timestamp)
            });
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
            ? `<div class="group-avatar-stack">${displayMembers.map((pk, i) =>
                `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="group-avatar-stack-img" data-avatar-pubkey="${pk}" style="z-index:${3 - i}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pk}.png?set=set1&size=80x80'">`
            ).join('')}<span class="group-icon-badge">${groupSvg}</span></div>`
            : `<div class="group-icon-wrap">${groupSvg}</div>`;

        return `${avatarStackHtml}<span class="pm-name">${this.escapeHtml(name)}<span class="group-member-count"> · ${this.abbreviateNumber(memberCount)}</span></span><div class="channel-badges"><span class="delete-pm" data-group-id="${this.escapeHtml(groupId)}" onclick="event.stopPropagation(); nym.deleteGroup(this.dataset.groupId)">✕</span><span class="unread-badge" style="display:none">0</span></div>`;
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
            const html = waterfallReaders && waterfallReaders.size > 0
                ? this._buildGroupReadersHtmlFromMap(waterfallReaders)
                : '';
            el.innerHTML = html;
            if (html && !el._readerLongPressBound) {
                this._bindReaderLongPress(el, msg.nymMessageId);
                el._readerLongPressBound = true;
            }
        }
    },

    // Fallback: update a single message's reader avatars without waterfall
    _updateSingleGroupReaders(nymMessageId) {
        const el = document.querySelector(`.group-readers[data-nym-msg-id="${nymMessageId}"]`);
        if (!el) return;
        const html = this._buildGroupReadersHtml(nymMessageId);
        if (!html) return;
        el.innerHTML = html;
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
        const avatarHtml = visible.map(([pk, name]) =>
            `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="group-reader-avatar" title="Read by ${this.escapeHtml(name)}" data-avatar-pubkey="${pk}" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pk}.png?set=set1&size=80x80'">`
        ).join('');
        const overflowHtml = overflow > 0
            ? `<span class="group-reader-overflow">+${this.abbreviateNumber(overflow)}</span>`
            : '';
        return avatarHtml + overflowHtml;
    },

    // Returns the inner HTML for a .group-readers span: up to 3 avatars + overflow badge
    _buildGroupReadersHtml(nymMessageId) {
        const MAX_VISIBLE = 3;
        const readers = this.groupMessageReaders.get(nymMessageId);
        if (!readers || readers.size === 0) return '';
        const entries = Array.from(readers.entries());
        const visible = entries.slice(0, MAX_VISIBLE);
        const overflow = readers.size - MAX_VISIBLE;
        const avatarHtml = visible.map(([pk, name]) =>
            `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="group-reader-avatar" title="Read by ${this.escapeHtml(name)}" data-avatar-pubkey="${pk}" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pk}.png?set=set1&size=80x80'">`
        ).join('');
        const overflowHtml = overflow > 0
            ? `<span class="group-reader-overflow">+${this.abbreviateNumber(overflow)}</span>`
            : '';
        return avatarHtml + overflowHtml;
    },

    // Attach a 500ms long-press to a .group-readers element to open the readers modal
    _bindReaderLongPress(el, nymMessageId) {
        let timer = null;
        const start = (e) => {
            e.stopPropagation();
            timer = setTimeout(() => {
                timer = null;
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
        el.style.cursor = 'pointer';
    },

    showReadersModal(nymMessageId, anchorEl) {
        this.closeReadersModal();
        const readers = this.groupMessageReaders.get(nymMessageId);
        if (!readers || readers.size === 0) return;

        const userItems = Array.from(readers.entries()).map(([pubkey, nym]) => {
            const isYou = pubkey === this.pubkey;
            const baseNym = this.stripPubkeySuffix(nym);
            const suffix = this.getPubkeySuffix(pubkey);
            const avatarSrc = this.escapeHtml(this.getAvatarUrl(pubkey));
            return `<div class="reactors-modal-user readers-modal-user" data-pubkey="${pubkey}">
                <img src="${avatarSrc}" class="readers-modal-avatar" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">
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

        // Position above/below the anchor
        const rect = anchorEl.getBoundingClientRect();
        modal.style.right = Math.max(4, window.innerWidth - rect.right) + 'px';
        const approxHeight = Math.min(readers.size * 44 + 50, 300);
        if (rect.top > approxHeight + 20) {
            modal.style.bottom = (window.innerHeight - rect.top + 4) + 'px';
        } else {
            modal.style.top = (rect.bottom + 6) + 'px';
        }
    },

    closeReadersModal() {
        if (this.readersModal) {
            this.readersModal.remove();
            this.readersModal = null;
        }
    },

    // Re-render a group item's inner HTML (e.g., after member list changes)
    updateGroupConversationUI(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        const pmList = document.getElementById('pmList');
        const item = pmList?.querySelector(`[data-group-id="${groupId}"]`);
        if (item) {
            item.innerHTML = this._buildGroupItemHTML(groupId, group.name, group.members);
            item.onclick = () => this.openGroup(groupId);
        }
    },

    // Open a group conversation in the main chat area
    openGroup(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;

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
        const headerAvatars = otherMembers.slice(0, 4).map(pk => {
            const src = this.getAvatarUrl(pk);
            return `<img src="${this.escapeHtml(src)}" class="avatar-message group-header-avatar" data-avatar-pubkey="${pk}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pk}.png?set=set1&size=80x80'">`;
        }).join('');

        const groupSvg = `<svg class="group-chat-icon group-header-svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;
        const memberLabel = `<span style="font-size:12px;color:var(--text-dim);margin-left:4px">(${this.abbreviateNumber(group.members.length)} members)</span>`;
        const headerHtml = `<span class="group-header-icon">${groupSvg}</span>${headerAvatars}<span style="margin-left:${otherMembers.length > 0 ? '8' : '0'}px">${this.escapeHtml(group.name)}</span>${memberLabel}`;

        document.getElementById('currentChannel').innerHTML = headerHtml;
        const lockSvg = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px;margin-right:4px"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>';
        const metaText = `${lockSvg}End-to-end encrypted group chat`;
        document.getElementById('channelMeta').innerHTML = metaText;

        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) shareBtn.style.display = 'none';

        // Mark only the matching group item as active
        document.querySelectorAll('.channel-item').forEach(i => i.classList.remove('active'));
        document.querySelectorAll('.pm-item').forEach(i => {
            i.classList.toggle('active', i.dataset.groupId === groupId);
        });

        const groupConvKey = this.getGroupConversationKey(groupId);
        this.clearUnreadCount(groupConvKey);
        this.loadPMMessages(groupConvKey);

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
            const nymMessageId = this.generateUUID();

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
            this.channelDOMCache.delete(groupConvKey);

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
            this.displaySystemMessage('Creating groups requires a logged-in account (not anonymous mode)');
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

    // /groupinfo — list members of the current group
    cmdGroupInfo() {
        if (!this.inPMMode || !this.currentGroup) {
            this.displaySystemMessage('You must be in a group conversation to use /groupinfo');
            return;
        }
        const group = this.groupConversations.get(this.currentGroup);
        if (!group) return;
        const memberList = group.members.map(pk => {
            const name = this.getNymFromPubkey(pk);
            const suffix = this.getPubkeySuffix(pk);
            const isYou = pk === this.pubkey ? ' (you)' : '';
            return `  @${name}#${suffix}${isYou}`;
        }).join('\n');
        this.displaySystemMessage(`Group: "${group.name}"\nMembers (${group.members.length}):\n${memberList}`);
    },

    toggleGroupMentionsOnly(enabled) {
        this.groupNotifyMentionsOnly = enabled;
        localStorage.setItem('nym_group_notify_mentions_only', String(enabled));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

});
