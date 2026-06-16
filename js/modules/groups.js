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

    // Ordered ephemeral secret keys to try when unwrapping (p-tag match first).
    _ephemeralCandidateSks(event) {
        const out = [], seen = new Set();
        const pTag = (event.tags || []).find(t => Array.isArray(t) && t[0] === 'p' && t[1]);
        if (pTag) { const sk = this._lookupEphemeralSk(pTag[1]); if (sk) { out.push(sk); seen.add(pTag[1]); } }
        for (const [, ek] of this.groupEphemeralKeys) {
            if (!ek.self) continue;
            for (const key of [ek.self.current, ...ek.self.prev]) {
                if (seen.has(key.pk)) continue;
                seen.add(key.pk);
                out.push(key.sk);
            }
        }
        return out;
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
                    banner: group.banner || null,
                    avatar: group.avatar || null,
                    description: group.description || null,
                    allowMemberInvites: group.allowMemberInvites !== false,
                    inviteEnabled: group.inviteEnabled === true,
                    inviteEpoch: group.inviteEpoch || 0,
                    metaUpdatedAt: group.metaUpdatedAt || 0,
                    lastModTs: group.lastModTs || 0,
                    lastModEventId: group.lastModEventId || null,
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
    // Whether a user may add new members. The owner always can; everyone else
    // only when the group's "allow member invites" setting is enabled (the
    // default for groups created before this setting existed).
    _canAddMembers(groupId, pubkey) {
        const g = this.groupConversations.get(groupId);
        if (!g) return false;
        if (this._isGroupOwner(groupId, pubkey)) return true;
        return g.allowMemberInvites !== false;
    },

    _b64uEncode(str) {
        const bytes = new TextEncoder().encode(str);
        let bin = '';
        for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    },
    _b64uDecode(token) {
        let b64 = token.replace(/-/g, '+').replace(/_/g, '/');
        while (b64.length % 4) b64 += '=';
        const bin = atob(b64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return new TextDecoder().decode(bytes);
    },

    // Self-contained invite link
    buildGroupInviteLink(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return null;
        if (!group.inviteEnabled) return null;
        if (!this._canAddMembers(groupId, this.pubkey)) return null;
        const payload = { v: 1, g: groupId, n: (group.name || 'Group').slice(0, 80), a: this.pubkey, e: group.inviteEpoch || 0 };
        const token = this._b64uEncode(JSON.stringify(payload));
        const base = window.location.origin + window.location.pathname;
        return `${base}#gjoin=${token}`;
    },

    parseGroupInviteInput(str) {
        if (!str) return null;
        let token = String(str).trim();
        const m = token.match(/[#&?]gjoin=([A-Za-z0-9_-]+)/);
        if (m) token = m[1];
        else if (/^gjoin=/.test(token)) token = token.slice(6);
        if (!/^[A-Za-z0-9_-]+$/.test(token)) return null;
        try {
            const obj = JSON.parse(this._b64uDecode(token));
            if (!obj || obj.v !== 1) return null;
            // Group ids are 64-hex for new groups, uppercase UUIDs for legacy ones.
            if (!/^([0-9a-f]{64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i.test(obj.g || '')) return null;
            if (!/^[0-9a-f]{64}$/i.test(obj.a || '')) return null;
            obj.e = parseInt(obj.e, 10) || 0;
            return obj;
        } catch { return null; }
    },

    async groupCtxCopyInviteLink() {
        const groupId = this._groupCtxGroupId;
        if (!groupId) return;
        const link = this.buildGroupInviteLink(groupId);
        if (!link) {
            this.displaySystemMessage('Invite links are disabled for this group.');
            return;
        }
        try {
            await navigator.clipboard.writeText(link);
            this.displaySystemMessage('Copied group invite link to clipboard');
        } catch {
            this.displaySystemMessage('Failed to copy invite link');
        }
    },

    _clearPendingInvite() {
        try { localStorage.removeItem('nym_pending_group_invite'); } catch (e) { }
    },

    // Joiner side: confirm, then gift-wrap a single join-request to the sharer.
    async requestJoinGroupViaInvite(payload) {
        if (!payload) return;
        const groupId = payload.g;
        const approver = payload.a;
        if (this.groupConversations.has(groupId)) {
            this._clearPendingInvite();
            this.openGroup(groupId);
            return;
        }
        if (approver === this.pubkey) {
            this._clearPendingInvite();
            this.displaySystemMessage('That is your own invite link.');
            return;
        }
        const name = this.sanitizeGroupName(payload.n || '') || 'this group';
        // Brand-new user with no identity yet: keep the invite pending, prompt
        // them to set up, and resume the join after they enter chat.
        if (!this._canSendGiftWraps()) {
            this.displaySystemMessage(`Pick a nym or log in to join "${name}", then you'll be added.`);
            const setupModal = document.getElementById('setupModal');
            if (setupModal && !setupModal.classList.contains('active')) setupModal.classList.add('active');
            if (typeof window.updateSetupInviteBanner === 'function') window.updateSetupInviteBanner();
            return;
        }
        const ok = await window.showAppConfirm(`Join "${name}"? A join request will be sent to a group member.`, { title: 'Join Group', okLabel: 'Join' });
        if (!ok) { this._clearPendingInvite(); return; }
        this._clearPendingInvite();

        if (!this._pendingInviteJoins) this._pendingInviteJoins = new Set();
        this._pendingInviteJoins.add(groupId);

        const now = Math.floor(Date.now() / 1000);
        const tags = [
            ['p', approver],
            ['g', groupId],
            ['subject', (payload.n || 'Group').slice(0, 80)],
            ['type', 'group-join-request'],
            ['invite_epoch', String(payload.e || 0)],
            ['x', this._generateSharedEventId()]
        ];
        const rumor = { kind: 14, created_at: now, tags, content: 'requested to join via invite link', pubkey: this.pubkey };
        await this._sendGiftWrapsAsync([approver], rumor, null);
        this.displaySystemMessage(`Join request sent for "${name}". You'll be added once a member is online.`);
    },

    async handleGroupInviteFromUrl(token) {
        const payload = this.parseGroupInviteInput(token);
        if (!payload) {
            this._clearPendingInvite();
            this.displaySystemMessage('Invalid or expired invite link.');
            return;
        }
        await this.requestJoinGroupViaInvite(payload);
    },

    // Approver side: auto-admit only when invite links are enabled, the request's
    // epoch matches the current one, and the joiner is eligible.
    async _handleGroupJoinRequest(rumor, groupId, joinerPubkey) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!group.inviteEnabled) return;
        if (!this._canSendGiftWraps()) return;
        if (!this._canAddMembers(groupId, this.pubkey)) return;
        const epochTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'invite_epoch');
        const reqEpoch = epochTag ? (parseInt(epochTag[1], 10) || 0) : 0;
        if (reqEpoch !== (group.inviteEpoch || 0)) return;
        if (group.members.includes(joinerPubkey)) return;
        if (Array.isArray(group.banned) && group.banned.includes(joinerPubkey)) return;
        await this.addMemberToGroup(groupId, joinerPubkey);
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
                        if (group.banner) g.banner = group.banner;
                        if (group.avatar) g.avatar = group.avatar;
                        if (group.description) g.description = group.description;
                        if (group.allowMemberInvites === false) g.allowMemberInvites = false;
                        if (group.inviteEnabled === true) g.inviteEnabled = true;
                        if (group.inviteEpoch) g.inviteEpoch = group.inviteEpoch;
                        if (group.metaUpdatedAt) g.metaUpdatedAt = group.metaUpdatedAt;
                        if (group.lastModTs) g.lastModTs = group.lastModTs;
                        if (group.lastModEventId) g.lastModEventId = group.lastModEventId;
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

    handleGroupZap(rumor, senderPubkey) {
        const eTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'e' && t[1]);
        const boltTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'bolt11' && t[1]);
        if (!eTag || !boltTag) return;
        const messageId = eTag[1];
        const amount = this.parseAmountFromBolt11(boltTag[1]);
        if (!amount) return;

        const dedupKey = 'b:' + boltTag[1].toLowerCase();
        const existing = this.zaps.get(messageId);
        if (existing && existing.receipts.has(dedupKey)) return;

        const isLive = (Date.now() - ((rumor.created_at || 0) * 1000)) <= 10000;
        this._recordMessageZap(messageId, senderPubkey, amount, dedupKey, isLive, true);

        const pTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'p' && t[1]);
        if (senderPubkey !== this.pubkey && pTag && pTag[1] === this.pubkey) {
            this._notifyZapToOurMessage(messageId, amount, senderPubkey, { id: '', created_at: rumor.created_at });
        }
    },

    // Handle incoming group message (rumor with 'g' tag)
    async handleGroupMessage(rumor, event, senderPubkey, isOwn, senderVerified) {
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

        // Filter group invites based on acceptPMs setting. A group the user is
        // actively joining via an invite link bypasses the filter so the
        // resulting add-member wrap is accepted.
        if (!isOwn && this.settings.acceptPMs !== 'enabled' && !this.groupConversations.has(groupId)
            && !(this._pendingInviteJoins && this._pendingInviteJoins.has(groupId))) {
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

        // Extract group name from 'subject' tag
        const subjectTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'subject' && t[1]);
        const groupName = subjectTag ? subjectTag[1] : 'Group';

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

        // Route group zaps (kind 9735) before regular message processing
        if (rumor.kind === 9735) {
            this.handleGroupZap(rumor, senderPubkey);
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
                    this.displaySystemMessage(`${this.getNymHtmlFromPubkey(senderPubkey)} left the group.`, 'system', { html: true });
                }
            }
            return;
        }

        // group-metadata: owner changed the group name, banner, and/or avatar.
        if (typeTag && typeTag[1] === 'group-metadata') {
            this._applyGroupMetadataTags(rumor, groupId, senderPubkey, rumor.created_at || 0);
            return;
        }

        // group-join-request: someone used an invite link; admit them if eligible.
        if (typeTag && typeTag[1] === 'group-join-request') {
            if (!isOwn) await this._handleGroupJoinRequest(rumor, groupId, senderPubkey);
            return;
        }

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
            const inviteAvatar = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'avatar' && t[1])?.[1] || null;
            const inviteBanner = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'banner' && t[1])?.[1] || null;
            const inviteDesc = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'description' && t[1])?.[1] || null;
            const inviteAllowInvTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'allow_invites');
            const inviteAllowInvites = inviteAllowInvTag ? inviteAllowInvTag[1] !== '0' : undefined;
            const inviteEnabledTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'invite_enabled');
            const inviteEnabled = inviteEnabledTag ? inviteEnabledTag[1] === '1' : undefined;
            const inviteEpochTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'invite_epoch');
            const inviteEpoch = inviteEpochTag ? (parseInt(inviteEpochTag[1], 10) || 0) : undefined;
            if (!this.groupConversations.has(groupId)) {
                this.addGroupConversation(
                    groupId,
                    groupName,
                    inviteMembers,
                    (rumor.created_at || Math.floor(Date.now() / 1000)) * 1000,
                    { createdBy: senderPubkey, mods: inviteMods, avatar: inviteAvatar, banner: inviteBanner, description: inviteDesc, allowMemberInvites: inviteAllowInvites, inviteEnabled, inviteEpoch }
                );
            }
            const grp = this.groupConversations.get(groupId);
            if (grp && !grp.createdBy) {
                grp.createdBy = senderPubkey;
            }
            if (grp && inviteMods.length > 0 && (!Array.isArray(grp.mods) || grp.mods.length === 0)) {
                grp.mods = [...inviteMods];
            }
            if (grp && inviteAvatar && !grp.avatar) grp.avatar = inviteAvatar;
            if (grp && inviteBanner && !grp.banner) grp.banner = inviteBanner;
            if (grp && inviteDesc && !grp.description) grp.description = inviteDesc;
            if (grp && inviteAllowInvites !== undefined) grp.allowMemberInvites = inviteAllowInvites;
            if (grp && inviteEnabled !== undefined) grp.inviteEnabled = inviteEnabled;
            if (grp && inviteEpoch !== undefined) grp.inviteEpoch = inviteEpoch;
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
            const claimedOwner = ownerTag ? ownerTag[1] : null;
            const addAvatar = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'avatar' && t[1])?.[1] || null;
            const addBanner = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'banner' && t[1])?.[1] || null;
            const addDesc = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'description' && t[1])?.[1] || null;
            const addAllowInvTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'allow_invites');
            const addInviteEnabledTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'invite_enabled');
            const addInviteEpochTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'invite_epoch');
            const existingGroup = this.groupConversations.get(groupId);
            const senderIsClaimedOwner = !!claimedOwner && claimedOwner === senderPubkey;
            // Refuse to bootstrap a brand-new group entry from a non-owner, unless
            // the user is actively joining via an invite link they chose to accept.
            const joiningViaInvite = !!(this._pendingInviteJoins && this._pendingInviteJoins.has(groupId));
            if (!existingGroup && !senderIsClaimedOwner && !joiningViaInvite) return;
            if (existingGroup && existingGroup.createdBy) {
                const isOwnerSender = existingGroup.createdBy === senderPubkey;
                const isModSender = Array.isArray(existingGroup.mods) && existingGroup.mods.includes(senderPubkey);
                const isMemberSender = Array.isArray(existingGroup.members) && existingGroup.members.includes(senderPubkey);
                const memberInvitesAllowed = existingGroup.allowMemberInvites !== false;
                if (!isOwnerSender && !isModSender && !(isMemberSender && memberInvitesAllowed)) return;
            }
            const trustBootstrap = senderIsClaimedOwner || (joiningViaInvite && !existingGroup);
            const bannedSet = existingGroup && Array.isArray(existingGroup.banned)
                ? new Set(existingGroup.banned) : new Set();
            const addMemberPubkeys = bannedSet.size > 0
                ? memberPubkeys.filter(pk => !bannedSet.has(pk)) : memberPubkeys;
            const existingMembers = existingGroup ? new Set(existingGroup.members) : new Set();
            const newMembers = addMemberPubkeys.filter(pk => !existingMembers.has(pk));
            this.addGroupConversation(
                groupId,
                groupName,
                addMemberPubkeys,
                (rumor.created_at || Math.floor(Date.now() / 1000)) * 1000,
                {
                    createdBy: trustBootstrap ? claimedOwner : undefined,
                    mods: trustBootstrap ? addMods : [],
                    avatar: trustBootstrap ? addAvatar : undefined,
                    banner: trustBootstrap ? addBanner : undefined,
                    description: trustBootstrap ? addDesc : undefined,
                    allowMemberInvites: trustBootstrap && addAllowInvTag ? addAllowInvTag[1] !== '0' : undefined,
                    inviteEnabled: trustBootstrap && addInviteEnabledTag ? addInviteEnabledTag[1] === '1' : undefined,
                    inviteEpoch: trustBootstrap && addInviteEpochTag ? (parseInt(addInviteEpochTag[1], 10) || 0) : undefined
                }
            );
            const grpAdd = this.groupConversations.get(groupId);
            if (trustBootstrap && grpAdd && addAvatar && !grpAdd.avatar) grpAdd.avatar = addAvatar;
            if (trustBootstrap && grpAdd && addBanner && !grpAdd.banner) grpAdd.banner = addBanner;
            if (trustBootstrap && grpAdd && addDesc && !grpAdd.description) grpAdd.description = addDesc;
            if (trustBootstrap && grpAdd && addAllowInvTag) grpAdd.allowMemberInvites = addAllowInvTag[1] !== '0';
            if (trustBootstrap && grpAdd && addInviteEnabledTag) grpAdd.inviteEnabled = addInviteEnabledTag[1] === '1';
            if (trustBootstrap && grpAdd && addInviteEpochTag) grpAdd.inviteEpoch = parseInt(addInviteEpochTag[1], 10) || 0;
            if (trustBootstrap && grpAdd && addMods.length > 0 && (!Array.isArray(grpAdd.mods) || grpAdd.mods.length === 0)) {
                grpAdd.mods = [...addMods];
            }
            if (joiningViaInvite) this._pendingInviteJoins.delete(groupId);
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
                if (this._isStaleModEvent(grpForCheck, rumor, event)) return;
                const isOwnerKick = grpForCheck.createdBy === senderPubkey;
                const isModKick = Array.isArray(grpForCheck.mods) && grpForCheck.mods.includes(senderPubkey);
                if (!isOwnerKick && !isModKick) return;
                // Mods can't kick the owner or other mods
                if (!isOwnerKick) {
                    if (grpForCheck.createdBy === removedPubkey) return;
                    if (Array.isArray(grpForCheck.mods) && grpForCheck.mods.includes(removedPubkey)) return;
                }
                this._recordModEvent(grpForCheck, rumor, event);
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
            if (this._isStaleModEvent(grp, rumor, event)) return;
            this._recordModEvent(grp, rumor, event);
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
            if (this._isStaleModEvent(grp, rumor, event)) return;
            this._recordModEvent(grp, rumor, event);
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
            if (this._isStaleModEvent(grp, rumor, event)) return;
            this._recordModEvent(grp, rumor, event);
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

        const nymMsgId = this.getNymMessageId(rumor);

        // Content dedup for dual-wrap scenarios
        let dupGroupMsg = null;
        if (nymMsgId) {
            dupGroupMsg = list.find(m => m.pubkey === senderPubkey && m.nymMessageId === nymMsgId);
        }
        if (!dupGroupMsg) {
            dupGroupMsg = list.find(m => m.pubkey === senderPubkey && m.content === messageContent && Math.abs((m.timestamp?.getTime() / 1000 || 0) - tsSec) < 5);
        }
        if (dupGroupMsg) {
            if (senderVerified === true && dupGroupMsg.senderVerified !== true) {
                dupGroupMsg.senderVerified = true;
                this._setMessageVerifiedDOM(dupGroupMsg.nymMessageId || dupGroupMsg.id, true);
                this._recordMsgVerification(dupGroupMsg.nymMessageId, true);
                this.channelDOMCache.delete(groupConvKey);
                this.persistPMMessages(groupConvKey);
            }
            return;
        }

        const senderName = this.getNymFromPubkey(senderPubkey);

        // Fetch profile for unknown senders
        if (!isOwn && !this.users.has(senderPubkey)) {
            await this.fetchProfileDirect(senderPubkey);
        }

        const groupFileOffer = this.parseFileOfferTag(rumor.tags, senderPubkey);

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
            senderVerified,
            nymMessageId: nymMsgId,
            isFileOffer: !!groupFileOffer,
            fileOffer: groupFileOffer,
            deliveryStatus: isOwn ? 'sent' : undefined
        };
        this._recordMsgVerification(nymMsgId, senderVerified);

        list.push(msg);
        list.sort((a, b) => {
            return this._compareMessages(a, b);
        });
        if (list.length > this.pmStorageLimit) list = list.slice(-this.pmStorageLimit);
        this.pmMessages.set(groupConvKey, list);
        this.persistPMMessages(groupConvKey);
        if (isOwn) this._applyEarlyReceipt(msg, groupConvKey);

        // Update or create group conversation entry
        this.addGroupConversation(groupId, groupName, memberPubkeys, tsSec * 1000);
        const metaTsTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'meta_ts' && t[1]);
        if (metaTsTag) {
            this._applyGroupMetadataTags(rumor, groupId, senderPubkey, parseInt(metaTsTag[1], 10) || 0);
        }
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
            if (!isOwn && !msg.isHistorical && !document.hidden && !this.userScrolledUp &&
                this._canSendGiftWraps() && nymMsgId) {
                this.sendNymReceipt(nymMsgId, 'read', senderPubkey, 'group', groupId);
                msg.readReceiptSent = true;
                this.recordOwnActivity();
            }
        } else {
            // Column view: render into the group's open column even when it
            // isn't the focused one.
            const cvShown = this._cvActive && this._cvListForKey(groupConvKey);
            if (cvShown) this.displayMessage(msg);
            if (!isOwn && !senderBlocked) {
                const ageMs = Date.now() - (tsSec * 1000);
                const treatAsHistorical = msg.isHistorical || ageMs > 30000;
                if (!(cvShown && this._cvMarkColumnRead(groupConvKey))) this.updateUnreadCount(groupConvKey);
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
    },

    // Create a new private group and send invites to all members via NIP-17 gift wraps.
    async createGroup(name, memberPubkeys, opts = {}) {
        if (!this._canSendGiftWraps()) {
            this.displaySystemMessage('Creating groups requires a logged-in account (not pseudonymous mode)');
            return null;
        }
        name = this.sanitizeGroupName(name);

        // Always include self as a member
        const allMembers = [...new Set([...memberPubkeys, this.pubkey])];

        // CSPRNG (32-byte hex)
        const groupId = this._generateSharedEventId();
        const now = Math.floor(Date.now() / 1000);
        const nymMessageId = this._generateSharedEventId();
        const inviteContent = `You've been added to group "${name}" (${allMembers.length} members).`;
        const groupAvatar = opts.avatar || null;
        const groupBanner = opts.banner || null;
        const groupDescription = opts.description || null;
        const allowMemberInvites = opts.allowMemberInvites !== false;
        const inviteEnabled = opts.inviteEnabled === true;
        const inviteEpoch = opts.inviteEpoch || 0;

        const tags = allMembers.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', name]);
        tags.push(['type', 'group-invite']);
        tags.push(['owner', this.pubkey]);
        if (groupAvatar) tags.push(['avatar', groupAvatar]);
        if (groupBanner) tags.push(['banner', groupBanner]);
        if (groupDescription) tags.push(['description', groupDescription]);
        tags.push(['allow_invites', allowMemberInvites ? '1' : '0']);
        tags.push(['invite_enabled', inviteEnabled ? '1' : '0']);
        tags.push(['invite_epoch', String(inviteEpoch)]);
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
        this.addGroupConversation(groupId, name, allMembers, Date.now(), { createdBy: this.pubkey, avatar: groupAvatar, banner: groupBanner, description: groupDescription, allowMemberInvites, inviteEnabled, inviteEpoch });
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
        if (!this._canAddMembers(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can add new members to this group.');
            return false;
        }
        if (group.members.includes(newMemberPubkey)) {
            this.displaySystemMessage('User is already in this group');
            return false;
        }
        // Banlist: only the owner or a moderator can re-admit a banned user; regular members cannot.
        if (Array.isArray(group.banned) && group.banned.includes(newMemberPubkey)) {
            if (!this._canModerate(groupId, this.pubkey)) {
                this.displaySystemMessage('That user was removed from this group and can only be re-invited by the group owner or a moderator.');
                return false;
            }
            // Owner/mod is re-admitting: clear the ban
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
        if (group.avatar) tags.push(['avatar', group.avatar]);
        if (group.banner) tags.push(['banner', group.banner]);
        if (group.description) tags.push(['description', group.description]);
        tags.push(['allow_invites', group.allowMemberInvites === false ? '0' : '1']);
        tags.push(['invite_enabled', group.inviteEnabled ? '1' : '0']);
        tags.push(['invite_epoch', String(group.inviteEpoch || 0)]);
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
    // Archive every group rumor — messages, edits, reactions, deletions AND
    // control events (membership, mods, bans, ownership, key rotation) — so a
    // new device can fully reconstruct group state. Replaying them in order
    // mirrors the existing relay reconnect catch-up.
    _isArchivableGroupRumor(rumor) {
        if (!rumor || (rumor.kind !== 14 && rumor.kind !== 7)) return false;
        // group-metadata is an empty-content control event; never archive it as
        // a message so it can't reappear as a blank bubble on restore.
        const typeTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'type');
        if (typeTag && typeTag[1] === 'group-metadata') return false;
        return true;
    },

    // Mirror a group rumor to D1 as a self-addressed gift wrap (to our real
    // pubkey) so group chats restore on other devices like 1:1 PMs. Local-key
    // path only, matching how 1:1 PM archival works.
    async _archiveGroupRumorSelf(rumor, expirationTs) {
        try {
            if (!this._isArchivableGroupRumor(rumor)) return;
            if (typeof this._pmArchiveAllowed !== 'function' || !this._pmArchiveAllowed()) return;
            let wrap = null;
            if (this.privkey) {
                wrap = this.nip59WrapEvent(rumor, this.privkey, this.pubkey, expirationTs);
            } else {
                // Extension / NIP-46: seal via the signer, wrap with a local ephemeral.
                const useExt = !!(window.nostr?.nip44?.encrypt && window.nostr?.signEvent);
                const useN46 = this.nostrLoginMethod === 'nip46' && _nip46State && _nip46State.connected;
                if (!useExt && !useN46) return;
                const NT = window.NostrTools;
                const r = { ...rumor };
                r.id = NT.getEventHash(r);
                const rumorJson = JSON.stringify(r);
                const sealContent = useExt
                    ? await window.nostr.nip44.encrypt(this.pubkey, rumorJson)
                    : await _nip46Encrypt(this.pubkey, rumorJson);
                const sealUnsigned = { kind: 13, content: sealContent, created_at: this.randomNow(), tags: [] };
                const seal = useExt
                    ? await window.nostr.signEvent(sealUnsigned)
                    : await _nip46SignEvent(sealUnsigned);
                const ephSk = NT.generateSecretKey();
                const ckWrap = NT.nip44.getConversationKey(ephSk, this.pubkey);
                const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
                const wrapUnsigned = { kind: 1059, content: wrapContent, created_at: this.randomNow(), tags: [['p', this.pubkey]] };
                if (expirationTs) wrapUnsigned.tags.push(['expiration', String(expirationTs)]);
                wrap = NT.finalizeEvent(wrapUnsigned, ephSk);
            }
            if (wrap) this._archivePMEvent(wrap);
        } catch (_) { }
    },

    async _sendGiftWrapsAsync(members, rumor, expirationTs, groupId = null) {
        // Archive-only self copy so group messages also hydrate from D1.
        if (groupId) this._archiveGroupRumorSelf(rumor, expirationTs);

        // Fast path — local key available. Offload each wrap to the crypto
        // worker pool so large groups don't block the UI thread.
        if (this.privkey) {
            const sharedId = this.getNymMessageId(rumor);
            const wrapLocal = async (pubkey) => {
                const encryptTo = groupId ? this._getEncryptionPubkey(groupId, pubkey) : pubkey;
                const wrapped = await this.nip59WrapEventAsync(rumor, this.privkey, encryptTo, expirationTs);
                this.sendDMToRelays(['EVENT', wrapped]);
                this._recordGiftWrapId(sharedId, wrapped.id);
                if (this.activeCosmetics?.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(wrapped.id, 1059); }, 600000);
                }
            };
            const queue = members.slice();
            const workers = new Array(Math.min(8, queue.length)).fill(0).map(async () => {
                while (queue.length) await wrapLocal(queue.shift());
            });
            await Promise.all(workers);
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
    async sendGroupMessage(content, groupId, options = {}) {
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
        this._attachGroupMetaTags(tags, group, groupId);

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

        const fileOffer = options.fileOffer || null;
        if (fileOffer) tags.push(['offer', JSON.stringify(fileOffer)]);

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
            senderVerified: true,
            isFileOffer: !!fileOffer,
            fileOffer,
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
        if (typeof this._clearGroupSyncData === 'function') this._clearGroupSyncData(groupId);

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
    async deleteGroup(groupId) {
        if (!(await window.showAppConfirm('Leave and delete this group conversation?', { danger: true, okLabel: 'Leave' }))) return;
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

    // Owner-only: broadcast a name/banner/avatar/description change to members.
    async _broadcastGroupMetadata(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group || !this._canSendGiftWraps()) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can change group settings.');
            return;
        }
        // Send only to other members. We already applied the change locally and
        // it syncs to our own devices via nymchat-groups, so echoing it back to
        // ourselves would surface an empty control event as a blank message.
        const others = group.members.filter(pk => pk !== this.pubkey);
        if (!others.length) return;
        const now = group.metaUpdatedAt || Math.floor(Date.now() / 1000);
        const tags = others.map(pk => ['p', pk]);
        tags.push(['g', groupId]);
        tags.push(['subject', group.name]);
        tags.push(['type', 'group-metadata']);
        tags.push(['banner', group.banner || '']);
        tags.push(['avatar', group.avatar || '']);
        tags.push(['description', group.description || '']);
        tags.push(['allow_invites', group.allowMemberInvites === false ? '0' : '1']);
        tags.push(['invite_enabled', group.inviteEnabled ? '1' : '0']);
        tags.push(['invite_epoch', String(group.inviteEpoch || 0)]);
        tags.push(['x', this._generateSharedEventId()]);
        const rumor = { kind: 14, created_at: now, tags, content: '', pubkey: this.pubkey };
        await this._sendGiftWrapsAsync(others, rumor, null, groupId);
    },

    _attachGroupMetaTags(tags, group, groupId) {
        if (!group || !this._isGroupOwner(groupId, this.pubkey)) return;
        const metaTs = group.metaUpdatedAt || 0;
        if (!metaTs) return;
        if (Math.floor(Date.now() / 1000) - metaTs > this.GROUP_META_PIGGYBACK_WINDOW) return;
        tags.push(['meta_ts', String(metaTs)]);
        tags.push(['banner', group.banner || '']);
        tags.push(['avatar', group.avatar || '']);
        tags.push(['description', group.description || '']);
        tags.push(['allow_invites', group.allowMemberInvites === false ? '0' : '1']);
        tags.push(['invite_enabled', group.inviteEnabled ? '1' : '0']);
        tags.push(['invite_epoch', String(group.inviteEpoch || 0)]);
    },

    _isStaleModEvent(grp, rumor, event) {
        if (!grp) return false;
        const ts = Math.floor(rumor.created_at || 0);
        const last = grp.lastModTs || 0;
        if (ts < last) return true;
        const evId = rumor && rumor.id;
        if (ts === last && evId && grp.lastModEventId && evId === grp.lastModEventId) return true;
        return false;
    },

    _recordModEvent(grp, rumor, event) {
        if (!grp) return;
        const nowSec = Math.floor(Date.now() / 1000);
        const ts = Math.min(Math.floor(rumor.created_at || 0), nowSec + 300);
        if (ts >= (grp.lastModTs || 0)) {
            grp.lastModTs = ts;
            const evId = rumor && rumor.id;
            if (evId) grp.lastModEventId = evId;
        }
    },

    _applyGroupMetadataTags(rumor, groupId, senderPubkey, metaTs) {
        const grp = this.groupConversations.get(groupId);
        if (!grp) return false;
        if (grp.createdBy !== senderPubkey) return false; // owner-issued only
        if (!metaTs || metaTs < (grp.metaUpdatedAt || 0)) return false;
        const tag = (k) => (rumor.tags || []).find(t => Array.isArray(t) && t[0] === k);
        const subjectTag = tag('subject');
        const bannerTag = tag('banner');
        const avatarTag = tag('avatar');
        const descTag = tag('description');
        const allowInvTag = tag('allow_invites');
        const inviteEnabledTag = tag('invite_enabled');
        const inviteEpochTag = tag('invite_epoch');
        let changed = false;
        if (subjectTag && subjectTag[1] && subjectTag[1] !== grp.name) { grp.name = subjectTag[1]; changed = true; }
        if (bannerTag) {
            const newBanner = bannerTag[1] || null;
            if (newBanner !== (grp.banner || null)) { grp.banner = newBanner; changed = true; }
        }
        if (avatarTag) {
            const newAvatar = avatarTag[1] || null;
            if (newAvatar !== (grp.avatar || null)) { grp.avatar = newAvatar; changed = true; }
        }
        if (descTag) {
            const newDesc = descTag[1] || null;
            if (newDesc !== (grp.description || null)) { grp.description = newDesc; changed = true; }
        }
        if (allowInvTag) {
            const newAllow = allowInvTag[1] !== '0';
            if (newAllow !== (grp.allowMemberInvites !== false)) { grp.allowMemberInvites = newAllow; changed = true; }
        }
        if (inviteEnabledTag) {
            const newEnabled = inviteEnabledTag[1] === '1';
            if (newEnabled !== !!grp.inviteEnabled) { grp.inviteEnabled = newEnabled; changed = true; }
        }
        if (inviteEpochTag) {
            const newEpoch = parseInt(inviteEpochTag[1], 10) || 0;
            if (newEpoch !== (grp.inviteEpoch || 0)) { grp.inviteEpoch = newEpoch; changed = true; }
        }
        if (changed) {
            grp.metaUpdatedAt = metaTs;
            this.groupConversations.set(groupId, grp);
            this.updateGroupConversationUI(groupId);
            this._saveGroupConversations();
            this._debouncedNostrSettingsSave();
            if (this.inPMMode && this.currentGroup === groupId) this.openGroup(groupId);
        }
        return changed;
    },

    // Single-line: strip control chars, collapse whitespace, cap at 2x nickname length.
    sanitizeGroupName(name) {
        return (name || '').replace(/[\x00-\x1F\x7F]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 40);
    },

    // Multi-line: keep newlines, strip other control chars, cap at user-bio length.
    sanitizeGroupDescription(description) {
        return (description || '').replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '').replace(/\n{3,}/g, '\n\n').trim().slice(0, 150);
    },

    // Owner-only: rename the group and propagate to members.
    async setGroupName(groupId, name) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can rename the group.');
            return;
        }
        const trimmed = this.sanitizeGroupName(name);
        if (!trimmed || trimmed === group.name) return;
        group.name = trimmed;
        group.metaUpdatedAt = Math.floor(Date.now() / 1000);
        this.groupConversations.set(groupId, group);
        this.updateGroupConversationUI(groupId);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        if (this.inPMMode && this.currentGroup === groupId) this.openGroup(groupId);
        await this._broadcastGroupMetadata(groupId);
        this.displaySystemMessage(`Group renamed to "${trimmed}".`);
    },

    // Owner-only: set the group description and propagate to members.
    async setGroupDescription(groupId, description) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can change the description.');
            return;
        }
        const trimmed = this.sanitizeGroupDescription(description) || null;
        if (trimmed === (group.description || null)) return;
        group.description = trimmed;
        group.metaUpdatedAt = Math.floor(Date.now() / 1000);
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        await this._broadcastGroupMetadata(groupId);
        this.displaySystemMessage('Group description updated.');
    },

    // Owner-only: toggle whether regular members may add new members, then
    // propagate to the rest of the group.
    async setGroupAllowMemberInvites(groupId, allow) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can change this setting.');
            return;
        }
        const next = !!allow;
        if (next === (group.allowMemberInvites !== false)) return;
        group.allowMemberInvites = next;
        group.metaUpdatedAt = Math.floor(Date.now() / 1000);
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        await this._broadcastGroupMetadata(groupId);
        this.displaySystemMessage(next
            ? 'Group members can now add new users.'
            : 'Only the group owner can add new users now.');
    },

    // Owner-only: turn joining via invite link on or off, then propagate.
    async setGroupInviteEnabled(groupId, enabled) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can change this setting.');
            return;
        }
        const next = !!enabled;
        if (next === !!group.inviteEnabled) return;
        group.inviteEnabled = next;
        group.metaUpdatedAt = Math.floor(Date.now() / 1000);
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        await this._broadcastGroupMetadata(groupId);
        this.displaySystemMessage(next
            ? 'Joining via invite link is now enabled.'
            : 'Joining via invite link is now disabled.');
    },

    // Owner-only: rotate the invite epoch to revoke every outstanding link.
    async rotateGroupInviteEpoch(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage('Only the group owner can reset the invite link.');
            return;
        }
        group.inviteEpoch = (group.inviteEpoch || 0) + 1;
        group.metaUpdatedAt = Math.floor(Date.now() / 1000);
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        await this._broadcastGroupMetadata(groupId);
        this.displaySystemMessage('Previous invite links revoked. A new link is now active.');
    },

    // Owner-only: persist a group image (kind = 'avatar' | 'banner') and
    // propagate to members. Re-renders the sidebar item too for avatar changes.
    async _applyGroupImage(groupId, kind, url) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        group[kind] = url;
        group.metaUpdatedAt = Math.floor(Date.now() / 1000);
        this.groupConversations.set(groupId, group);
        this._saveGroupConversations();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        if (kind === 'avatar') this.updateGroupConversationUI(groupId);
        if (this.inPMMode && this.currentGroup === groupId) this.openGroup(groupId);
        await this._broadcastGroupMetadata(groupId);
    },

    // Owner-only: upload and set a group avatar/banner, then propagate.
    async _setGroupImage(groupId, kind, file) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        if (!this._isGroupOwner(groupId, this.pubkey)) {
            this.displaySystemMessage(`Only the group owner can change the ${kind}.`);
            return;
        }
        try {
            const { url } = await this._uploadFileWithProgress(file, `Uploading group ${kind}…`);
            await this._applyGroupImage(groupId, kind, url);
            this.displaySystemMessage(`Group ${kind} updated.`);
        } catch (error) {
            if (!(error && error.name === 'AbortError')) this.displaySystemMessage(`Failed to upload ${kind}: ` + (error?.message || error));
        }
    },

    // Owner-only: clear a group avatar/banner.
    async _clearGroupImage(groupId, kind) {
        const group = this.groupConversations.get(groupId);
        if (!group || !this._isGroupOwner(groupId, this.pubkey)) return;
        await this._applyGroupImage(groupId, kind, null);
        this.displaySystemMessage(`Group ${kind} removed.`);
    },

    uploadGroupBanner(groupId, file) { return this._setGroupImage(groupId, 'banner', file); },
    removeGroupBanner(groupId) { return this._clearGroupImage(groupId, 'banner'); },
    uploadGroupAvatar(groupId, file) { return this._setGroupImage(groupId, 'avatar', file); },
    removeGroupAvatar(groupId) { return this._clearGroupImage(groupId, 'avatar'); },

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
                if (typeof this.updateUnreadCount === 'function') this.updateUnreadCount(groupConvKey);
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
                banner: opts.banner || null,
                avatar: opts.avatar || null,
                description: opts.description || null,
                allowMemberInvites: opts.allowMemberInvites !== false,
                inviteEnabled: opts.inviteEnabled === true,
                inviteEpoch: opts.inviteEpoch || 0,
                modLog: []
            });
            const pmList = document.getElementById('pmList');
            const item = document.createElement('div');
            item.className = 'pm-item group-item list-item';
            item.dataset.groupId = groupId;
            item.dataset.lastMessageTime = timestamp;
            item.innerHTML = this._buildGroupItemHTML(groupId, name, allMembers);
            item.dataset.groupSig = this._groupItemSignature(this.groupConversations.get(groupId));
            item.dataset.action = 'openGroupItem';
            this.insertPMInOrder(item, pmList);

            // Show any unread count persisted from a previous session
            const convKey = this.getGroupConversationKey(groupId);
            const unread = this.unreadCounts.get(convKey) || 0;
            if (unread > 0) this._renderUnreadBadge(convKey, unread);

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
            if (opts.banner !== undefined && opts.banner !== null) next.banner = opts.banner;
            if (opts.avatar !== undefined && opts.avatar !== null) next.avatar = opts.avatar;
            if (opts.description !== undefined && opts.description !== null) next.description = opts.description;
            if (opts.allowMemberInvites !== undefined) next.allowMemberInvites = opts.allowMemberInvites;
            if (opts.inviteEnabled !== undefined) next.inviteEnabled = opts.inviteEnabled;
            if (opts.inviteEpoch !== undefined) next.inviteEpoch = opts.inviteEpoch;
            this.groupConversations.set(groupId, next);
            this.updateGroupConversationUI(groupId);
        }
    },

    // Proxied URL of a group's custom avatar, or null when none is set.
    getGroupAvatarUrl(groupId) {
        const g = this.groupConversations.get(groupId);
        if (!g || !g.avatar) return null;
        return this.getProxiedMediaUrl(g.avatar);
    },

    // Rebuild the inner HTML of a group PM list item
    _buildGroupItemHTML(groupId, name, members) {
        const otherMembers = members.filter(pk => pk !== this.pubkey);
        const displayMembers = otherMembers.slice(0, 3);
        const memberCount = members.length;

        const groupSvg = `<svg class="group-chat-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;

        const customAvatar = this.getGroupAvatarUrl(groupId);
        const avatarStackHtml = customAvatar
            ? `<div class="group-avatar-wrap"><img src="${this.escapeHtml(customAvatar)}" class="group-custom-avatar" alt="" decoding="async" loading="lazy" data-error-action="groupImgError"></div>`
            : displayMembers.length > 0
                ? `<div class="group-avatar-stack">${displayMembers.map((pk) => {
                    const sk = this._safePubkey(pk);
                    return `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="group-avatar-stack-img" data-avatar-pubkey="${sk}" alt="" decoding="async" loading="lazy">`;
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

        const displayReaders = this._computeWaterfallReaders(
            messages, this.groupMessageReaders, m => m.nymMessageId, m => m.timestamp.getTime());

        for (const msg of messages) {
            if (!msg.isOwn || !msg.nymMessageId || !this.groupMessageReaders.has(msg.nymMessageId)) continue;
            const el = document.querySelector(`.group-readers[data-nym-msg-id="${msg.nymMessageId}"]`);
            if (!el) continue;
            const hasReaders = this._syncReaderAvatars(el, displayReaders.get(msg.nymMessageId));
            if (hasReaders && !el._readerLongPressBound) {
                this._bindReaderLongPress(el, msg.nymMessageId);
                el._readerLongPressBound = true;
            }
        }
    },

    _computeWaterfallReaders(messages, readersStore, idOf, tsOf) {
        const latestReadByReader = new Map(); // pubkey -> messageId
        const ownMessages = (messages || [])
            .filter(m => m.isOwn && idOf(m) && readersStore.has(idOf(m)))
            .sort((a, b) => tsOf(b) - tsOf(a)); // newest first

        for (const msg of ownMessages) {
            const readers = readersStore.get(idOf(msg));
            if (!readers) continue;
            for (const [pk] of readers) {
                if (!latestReadByReader.has(pk)) latestReadByReader.set(pk, idOf(msg));
            }
        }

        const displayReaders = new Map(); // messageId -> Map(pk -> nym)
        for (const [pk, msgId] of latestReadByReader) {
            if (!displayReaders.has(msgId)) displayReaders.set(msgId, new Map());
            const readers = readersStore.get(msgId);
            const name = readers ? readers.get(pk) : this.getNymFromPubkey(pk);
            displayReaders.get(msgId).set(pk, name);
        }
        return displayReaders;
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
            return `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="group-reader-avatar" title="Read by ${this.escapeHtml(name)}" data-avatar-pubkey="${sk}" decoding="async" loading="lazy">`;
        }).join('');
        const overflowHtml = overflow > 0
            ? `<span class="group-reader-overflow">+${this.abbreviateNumber(overflow)}</span>`
            : '';
        if (typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(null, visible.map(([pk]) => pk));
        }
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

        if (typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(null, visible.map(([pk]) => pk));
        }

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

        const displayReaders = this._computeWaterfallReaders(
            messages, this.channelMessageReaders, m => m.id, m => (m.created_at || 0));

        for (const msg of messages) {
            if (!msg.isOwn || !msg.id || !this.channelMessageReaders.has(msg.id)) continue;
            const el = document.querySelector(`.channel-readers[data-msg-id="${msg.id}"]`);
            if (!el) continue;
            const hasReaders = this._syncReaderAvatars(el, displayReaders.get(msg.id));
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
        const readers = this._waterfallReadersForChannel(messageId);
        if (!readers || readers.size === 0) return '';
        return this._buildGroupReadersHtmlFromMap(readers);
    },

    // Resolve the waterfalled reader set for a single channel message so the
    // initial render only shows avatars on each reader's latest seen message.
    _waterfallReadersForChannel(messageId) {
        if (this.inPMMode || !this.currentGeohash) return this.channelMessageReaders.get(messageId) || null;
        const messages = this.messages.get(`#${this.currentGeohash}`);
        if (!messages) return this.channelMessageReaders.get(messageId) || null;
        const displayReaders = this._computeWaterfallReaders(
            messages, this.channelMessageReaders, m => m.id, m => (m.created_at || 0));
        return displayReaders.get(messageId) || null;
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
        const readers = this._waterfallReadersForGroup(nymMessageId);
        if (!readers || readers.size === 0) return '';
        return this._buildGroupReadersHtmlFromMap(readers);
    },

    // Resolve the waterfalled reader set for a single group message so the
    // initial render only shows avatars on each reader's latest seen message.
    _waterfallReadersForGroup(nymMessageId) {
        if (!this.inPMMode || !this.currentGroup) return this.groupMessageReaders.get(nymMessageId) || null;
        const messages = this.pmMessages.get(this.getGroupConversationKey(this.currentGroup));
        if (!messages) return this.groupMessageReaders.get(nymMessageId) || null;
        const displayReaders = this._computeWaterfallReaders(
            messages, this.groupMessageReaders, m => m.nymMessageId, m => m.timestamp.getTime());
        return displayReaders.get(nymMessageId) || null;
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

        const entries = Array.from(readers.entries());
        const userItems = entries.map(([pubkey, nym]) => {
            const isYou = pubkey === this.pubkey;
            const baseNym = this.stripPubkeySuffix(nym);
            const suffix = this.getPubkeySuffix(pubkey);
            const safePk = this._safePubkey(pubkey);
            const avatarSrc = this.escapeHtml(this.getAvatarUrl(pubkey));
            return `<div class="reactors-modal-user readers-modal-user" data-pubkey="${safePk}">
                <img src="${avatarSrc}" class="readers-modal-avatar" data-avatar-pubkey="${safePk}" decoding="async" loading="lazy">
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

        if (typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(modal, Array.from(readers.keys()));
        }

        // Click user row to open their context menu
        modal.querySelectorAll('.readers-modal-user').forEach((el, i) => {
            el.addEventListener('click', (e) => {
                const [pubkey, nym] = entries[i];
                this.closeReadersModal();
                const baseNym = this.stripPubkeySuffix(nym);
                const suffix = this.getPubkeySuffix(pubkey);
                this.showContextMenu(e, `${baseNym}#${suffix}`, pubkey, null, null, false);
            });
        });

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
        return `${displayPks}|${group.members ? group.members.length : 0}|${group.name || ''}|${group.avatar || ''}`;
    },

    // Signature for the in-chat group header; changes force a header re-render.
    _groupHeaderSig(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return '';
        const displayPks = group.members.filter(pk => pk !== this.pubkey)
            .slice(0, 4).map(pk => this._safePubkey(pk));
        return `${displayPks.join(',')}|${group.members.length}|${group.name || ''}|${group.avatar || ''}`;
    },

    // Build the in-chat group header: custom avatar when set, else the stacked
    // member avatars + group glyph.
    _buildGroupHeaderHtml(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return '';
        const otherMembers = group.members.filter(pk => pk !== this.pubkey);
        const groupSvg = `<svg class="group-chat-icon group-header-svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;
        const customAvatar = this.getGroupAvatarUrl(groupId);
        let iconPart;
        if (customAvatar) {
            iconPart = `<span class="group-header-custom-wrap"><img src="${this.escapeHtml(customAvatar)}" class="group-header-custom-avatar" alt="" decoding="async" loading="lazy" data-error-action="groupImgError"></span>`;
        } else {
            const displayPks = otherMembers.slice(0, 4).map(pk => this._safePubkey(pk));
            const headerAvatars = displayPks.map((sk, i) => {
                const pk = otherMembers[i];
                return `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="avatar-message group-header-avatar" data-avatar-pubkey="${sk}" alt="" decoding="async" loading="lazy">`;
            }).join('');
            iconPart = `<span class="group-header-icon">${groupSvg}</span>${headerAvatars}`;
            if (typeof this.ensureListProfiles === 'function') {
                this.ensureListProfiles(null, otherMembers.slice(0, 4));
            }
        }
        const nameCls = (!customAvatar && otherMembers.length > 0) ? 'nm-grp-ml8' : '';
        const memberLabel = `<div class="channel-location"><span class="loc-country">${this.abbreviateNumber(group.members.length)} members</span></div>`;
        return `<span class="group-header-row">${iconPart}<span class="group-name-text ${nameCls}">${this.escapeHtml(group.name)}</span></span>${memberLabel}`;
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
                // Rebuilding innerHTML resets the unread badge — restore it
                const convKey = this.getGroupConversationKey(groupId);
                this._renderUnreadBadge(convKey, this.unreadCounts.get(convKey) || 0);
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
                    const sig = this._groupHeaderSig(groupId);
                    if (channelEl.dataset.groupHeaderSig !== sig) {
                        channelEl.innerHTML = this._buildGroupHeaderHtml(groupId);
                        channelEl.dataset.groupHeaderSig = sig;
                        this._wireGroupHeaderClick(channelEl, groupId);
                    }
                }
            }
        }
    },

    // Make the group chat header open the group context menu on click.
    _wireGroupHeaderClick(channelEl, groupId) {
        const row = channelEl.querySelector('.group-header-row');
        if (!row) return;
        row.classList.add('header-clickable');
        row.onclick = (e) => { e.preventDefault(); e.stopPropagation(); this.showGroupContextMenu(groupId); };
    },

    // Build and open the group info / management context menu.
    showGroupContextMenu(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        this._groupCtxGroupId = groupId;
        this._groupCtxTransferMode = false;
        const iAmOwner = this._isGroupOwner(groupId, this.pubkey);

        const menu = document.getElementById('groupContextMenu');
        const overlay = document.getElementById('groupContextMenuOverlay');
        if (!menu || !overlay) return;

        // Banner: custom image when set, otherwise a default gradient background.
        const bannerImg = document.getElementById('grpCtxBannerImg');
        const defaultBanner = document.getElementById('grpCtxDefaultBanner');
        menu.classList.add('has-banner');
        if (group.banner) {
            bannerImg.src = this.getProxiedMediaUrl(group.banner);
            bannerImg.classList.remove('nm-hidden');
            if (defaultBanner) defaultBanner.classList.add('nm-hidden');
            bannerImg.onerror = () => {
                bannerImg.classList.add('nm-hidden');
                if (defaultBanner) defaultBanner.classList.remove('nm-hidden');
            };
        } else {
            bannerImg.classList.add('nm-hidden');
            if (defaultBanner) defaultBanner.classList.remove('nm-hidden');
        }

        // Icon: custom group avatar, else stacked member avatars over a glyph.
        const groupSvg = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;
        const grpCtxIcon = document.getElementById('grpCtxIcon');
        const customAvatar = this.getGroupAvatarUrl(groupId);
        if (customAvatar) {
            grpCtxIcon.classList.add('has-image');
            grpCtxIcon.innerHTML = `<img src="${this.escapeHtml(customAvatar)}" class="group-ctx-custom-avatar nm-pointer" alt="" decoding="async" data-error-action="groupImgError" data-action="expandImageFromSrcStop">`;
        } else {
            grpCtxIcon.classList.remove('has-image');
            grpCtxIcon.innerHTML = groupSvg;
        }

        document.getElementById('grpCtxName').textContent = group.name || 'Group';
        document.getElementById('grpCtxMemberCount').textContent = `${group.members.length} member${group.members.length === 1 ? '' : 's'}`;
        document.getElementById('grpCtxBio').textContent = group.description || '';

        // Invite link row, shown in the header like the pubkey row of a user menu.
        const inviteLink = this._canAddMembers(groupId, this.pubkey) ? this.buildGroupInviteLink(groupId) : null;
        const grpCtxInviteLink = document.getElementById('grpCtxInviteLink');
        const grpCtxCopyInvite = document.getElementById('grpCtxCopyInvite');
        if (inviteLink) {
            if (grpCtxInviteLink) { grpCtxInviteLink.textContent = inviteLink; grpCtxInviteLink.classList.remove('nm-hidden'); }
            if (grpCtxCopyInvite) grpCtxCopyInvite.classList.remove('nm-hidden');
        } else {
            if (grpCtxInviteLink) { grpCtxInviteLink.textContent = ''; grpCtxInviteLink.classList.add('nm-hidden'); }
            if (grpCtxCopyInvite) grpCtxCopyInvite.classList.add('nm-hidden');
        }

        // Role-based action buttons
        const icon = (p) => `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" class="nm-ico8">${p}</svg>`;
        const actions = [];
        if (iAmOwner) {
            actions.push(`<div class="context-menu-item" data-action="groupCtxEditName">${icon('<path d="M 11.5 2.5 L 13.5 4.5 L 5 13 L 2 14 L 3 11 Z" stroke-linejoin="round"/><path d="M 10 4 L 12 6" stroke-linecap="round"/>')}Edit Group Name</div>`);
            actions.push(`<div class="context-menu-item" data-action="groupCtxEditDescription">${icon('<line x1="3" y1="4" x2="13" y2="4" stroke-linecap="round"/><line x1="3" y1="8" x2="13" y2="8" stroke-linecap="round"/><line x1="3" y1="12" x2="9" y2="12" stroke-linecap="round"/>')}Edit Description</div>`);
            actions.push(`<div class="context-menu-item" data-action="groupCtxChangeAvatar">${icon('<circle cx="8" cy="6" r="3"/><path d="M 2.5 14 C 2.5 10.5 5 9 8 9 C 11 9 13.5 10.5 13.5 14" stroke-linecap="round"/>')}Change Avatar</div>`);
            if (group.avatar) actions.push(`<div class="context-menu-item" data-action="groupCtxRemoveAvatar">${icon('<circle cx="8" cy="6" r="3"/><path d="M 2.5 14 C 2.5 10.5 5 9 8 9 C 11 9 13.5 10.5 13.5 14" stroke-linecap="round"/><line x1="3" y1="3" x2="13" y2="13" stroke-linecap="round"/>')}Remove Avatar</div>`);
            actions.push(`<div class="context-menu-item" data-action="groupCtxChangeBanner">${icon('<rect x="2" y="3" width="12" height="10" rx="1"/><circle cx="5.5" cy="6.5" r="1"/><path d="M 2 11 L 6 8 L 9 10 L 12 7 L 14 9" stroke-linejoin="round"/>')}Change Banner</div>`);
            if (group.banner) actions.push(`<div class="context-menu-item" data-action="groupCtxRemoveBanner">${icon('<rect x="2" y="3" width="12" height="10" rx="1"/><line x1="3" y1="3" x2="13" y2="13" stroke-linecap="round"/>')}Remove Banner</div>`);
        }
        if (iAmOwner && group.members.length > 1) {
            actions.push(`<div class="context-menu-item" data-action="groupCtxTransferOwner">${icon('<circle cx="8" cy="5" r="2.5"/><path d="M 2 14 C 2 10 4 9 8 9 C 12 9 14 10 14 14" stroke-linecap="round"/><path d="M 12 4 L 15 4 L 13.5 2 M 15 4 L 13.5 6" stroke-linecap="round" stroke-linejoin="round"/>')}Transfer Ownership</div>`);
        }
        const checkbox = (on) => on
            ? '<rect x="2.5" y="2.5" width="11" height="11" rx="2.5"/><path d="M 5 8 L 7 10 L 11 5.5" stroke-linecap="round" stroke-linejoin="round"/>'
            : '<rect x="2.5" y="2.5" width="11" height="11" rx="2.5"/>';
        if (iAmOwner) {
            actions.push(`<div class="context-menu-item" data-action="groupCtxToggleInviteJoin">${icon(checkbox(!!group.inviteEnabled))}Allow joining via invite link</div>`);
            if (group.inviteEnabled) {
                actions.push(`<div class="context-menu-item" data-action="groupCtxResetInviteLink">${icon('<path d="M 13 8 A 5 5 0 1 1 11.5 4.5" stroke-linecap="round"/><path d="M 11.5 2 L 11.5 5 L 8.5 5" stroke-linecap="round" stroke-linejoin="round"/>')}Reset Invite Link</div>`);
            }
        }
        if (iAmOwner) {
            actions.push(`<div class="context-menu-item" data-action="groupCtxToggleInvites">${icon(checkbox(group.allowMemberInvites !== false))}Allow members to add others</div>`);
        }
        if (this._canAddMembers(groupId, this.pubkey)) {
            actions.push(`<div class="context-menu-item" data-action="groupCtxAddMembers">${icon('<circle cx="6" cy="5.5" r="2.5"/><path d="M 2 14 C 2 11 4 9.5 6 9.5 C 7 9.5 8 9.8 8.7 10.4" stroke-linecap="round"/><line x1="12" y1="6" x2="12" y2="12" stroke-linecap="round"/><line x1="9" y1="9" x2="15" y2="9" stroke-linecap="round"/>')}Add Members</div>`);
        }
        actions.push(`<div class="context-menu-item danger" data-action="groupCtxLeave">${icon('<path d="M 6 2 L 3 2 C 2.5 2 2 2.5 2 3 L 2 13 C 2 13.5 2.5 14 3 14 L 6 14" stroke-linecap="round" stroke-linejoin="round"/><path d="M 10 11 L 13 8 L 10 5" stroke-linecap="round" stroke-linejoin="round"/><line x1="13" y1="8" x2="6" y2="8" stroke-linecap="round"/>')}Leave Group</div>`);
        document.getElementById('grpCtxActions').innerHTML = actions.join('');

        // Members list (owner first, then mods, then members)
        document.getElementById('grpCtxMembersTitle').textContent = `Members · ${group.members.length}`;
        const sorted = [...group.members].sort((a, b) => this._memberRoleRank(groupId, a) - this._memberRoleRank(groupId, b));
        document.getElementById('grpCtxMembers').innerHTML = sorted.map(pk => this._groupCtxMemberRowHtml(groupId, pk)).join('');
        if (typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(document.getElementById('grpCtxMembers'), sorted);
        }

        menu.scrollTop = 0;
        overlay.classList.add('active');
        menu.classList.add('active');
    },

    _memberRoleRank(groupId, pubkey) {
        if (this._isGroupOwner(groupId, pubkey)) return 0;
        if (this._isGroupMod(groupId, pubkey)) return 1;
        return 2;
    },

    _groupCtxMemberRowHtml(groupId, pubkey) {
        const safePk = this._safePubkey(pubkey);
        const baseNym = this.escapeHtml(this.stripPubkeySuffix(this.getNymFromPubkey(pubkey)));
        const suffix = this.getPubkeySuffix(pubkey);
        const isSelf = pubkey === this.pubkey;
        const roleBadge = this._isGroupOwner(groupId, pubkey)
            ? '<span class="group-ctx-role owner">Owner</span>'
            : this._isGroupMod(groupId, pubkey)
                ? '<span class="group-ctx-role mod">Mod</span>'
                : '';
        const avatar = `<img src="${this.escapeHtml(this.getAvatarUrl(pubkey))}" class="group-ctx-member-avatar" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy">`;
        const youTag = isSelf ? '<span class="group-ctx-you">you</span>' : '';
        return `<div class="group-ctx-member" data-action="groupCtxMemberClick" data-pubkey="${safePk}" data-nym="${baseNym}">${avatar}<span class="group-ctx-member-name">${baseNym}<span class="nym-suffix">#${suffix}</span>${youTag}</span>${roleBadge}</div>`;
    },

    closeGroupContextMenu() {
        const menu = document.getElementById('groupContextMenu');
        const overlay = document.getElementById('groupContextMenuOverlay');
        if (menu) menu.classList.remove('active');
        if (overlay) overlay.classList.remove('active');
        this._groupCtxTransferMode = false;
    },

    // Owner action: pick a new owner by selecting a member from the list.
    groupCtxTransferOwner() {
        const groupId = this._groupCtxGroupId;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        this._groupCtxTransferMode = true;
        document.getElementById('grpCtxMembersTitle').textContent = 'Select a member to make owner';
        const others = group.members.filter(pk => pk !== this.pubkey)
            .sort((a, b) => this._memberRoleRank(groupId, a) - this._memberRoleRank(groupId, b));
        document.getElementById('grpCtxMembers').innerHTML = others.map(pk => this._groupCtxMemberRowHtml(groupId, pk)).join('');
    },

    // A member row was clicked. In transfer mode this picks the new owner;
    // otherwise it opens the user's profile/moderation context menu
    // (profileOnly=false so the group kick/ban/mod actions remain visible).
    _openMemberFromGroupCtx(pubkey, nym) {
        if (this._groupCtxTransferMode) {
            this._groupCtxTransferMode = false;
            this.closeGroupContextMenu();
            window.showAppConfirm(`Transfer group ownership to ${nym}? You will lose owner privileges.`, { danger: true, okLabel: 'Transfer' })
                .then(ok => { if (ok) this.transferOwner(pubkey); });
            return;
        }
        const backGroupId = this._groupCtxGroupId;
        this.closeGroupContextMenu();
        const suffix = this.getPubkeySuffix(pubkey);
        const fakeEvent = { preventDefault() {}, stopPropagation() {}, stopImmediatePropagation() {} };
        // Pass the originating group so the user menu shows a "back" button.
        this.showContextMenu(fakeEvent, `${nym}#${suffix}`, pubkey, null, null, false, null, backGroupId);
    },

    // Back button in the user context menu returns to the group context menu.
    ctxBackToGroup() {
        const groupId = this._ctxBackToGroup;
        this.closeContextMenu();
        if (groupId) this.showGroupContextMenu(groupId);
    },

    // Owner action: prompt for a new group name.
    async groupCtxEditName() {
        const groupId = this._groupCtxGroupId;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        this.closeGroupContextMenu();
        const name = await window.showAppPrompt('Enter a new group name:', {
            title: 'Rename Group', okLabel: 'Save', defaultValue: group.name || '', maxLength: 40
        });
        if (name === null) return;
        await this.setGroupName(groupId, name);
    },

    // Owner action: prompt for a group description.
    async groupCtxEditDescription() {
        const groupId = this._groupCtxGroupId;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        this.closeGroupContextMenu();
        const desc = await window.showAppPrompt('Enter a group description:', {
            title: 'Group Description', okLabel: 'Save', defaultValue: group.description || '', maxLength: 150, multiline: true
        });
        if (desc === null) return;
        await this.setGroupDescription(groupId, desc);
    },

    // Owner action: pick an image file for the banner or avatar. The group
    // context menu is closed once a file is chosen so the upload progress bar
    // (anchored to the message input) is visible.
    _pickGroupImage(groupId, kind) {
        const input = document.getElementById('grpBannerFileInput');
        if (!input) return;
        input.onchange = async () => {
            const file = input.files && input.files[0];
            input.value = '';
            if (!file) return;
            this.closeGroupContextMenu();
            if (kind === 'avatar') await this.uploadGroupAvatar(groupId, file);
            else await this.uploadGroupBanner(groupId, file);
        };
        input.click();
    },

    groupCtxChangeBanner() { this._pickGroupImage(this._groupCtxGroupId, 'banner'); },
    groupCtxChangeAvatar() { this._pickGroupImage(this._groupCtxGroupId, 'avatar'); },

    async groupCtxRemoveBanner() {
        const groupId = this._groupCtxGroupId;
        this.closeGroupContextMenu();
        await this.removeGroupBanner(groupId);
    },

    async groupCtxRemoveAvatar() {
        const groupId = this._groupCtxGroupId;
        this.closeGroupContextMenu();
        await this.removeGroupAvatar(groupId);
    },

    groupCtxAddMembers() {
        const groupId = this._groupCtxGroupId;
        this.closeGroupContextMenu();
        this.openAddMembersModal(groupId);
    },

    // Owner action: flip the "members can add others" permission.
    groupCtxToggleInvites() {
        const groupId = this._groupCtxGroupId;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        this.closeGroupContextMenu();
        this.setGroupAllowMemberInvites(groupId, group.allowMemberInvites === false);
    },

    groupCtxToggleInviteJoin() {
        const groupId = this._groupCtxGroupId;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        this.closeGroupContextMenu();
        this.setGroupInviteEnabled(groupId, !group.inviteEnabled);
    },

    async groupCtxResetInviteLink() {
        const groupId = this._groupCtxGroupId;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        this.closeGroupContextMenu();
        const ok = await window.showAppConfirm('Reset the invite link? Every link shared so far will stop working.', { title: 'Reset Invite Link', okLabel: 'Reset', danger: true });
        if (ok) this.rotateGroupInviteEpoch(groupId);
    },

    async groupCtxLeave() {
        const groupId = this._groupCtxGroupId;
        const group = this.groupConversations.get(groupId);
        if (!group) return;
        this.closeGroupContextMenu();
        const ok = await window.showAppConfirm(`Leave "${group.name}"? You'll stop receiving messages from this group.`, { danger: true, okLabel: 'Leave' });
        if (ok) this.leaveGroup(groupId);
    },

    // Open a group conversation in the main chat area
    // Render the group conversation header into the shared chat header. Split
    // out of openGroup so column-view focus can show the same header.
    _renderGroupHeader(groupId) {
        const channelEl = document.getElementById('currentChannel');
        channelEl.innerHTML = this._buildGroupHeaderHtml(groupId);
        channelEl.dataset.groupHeaderSig = this._groupHeaderSig(groupId);
        delete channelEl.dataset.pmHeaderSig;
        this._wireGroupHeaderClick(channelEl, groupId);
        const lockSvg = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="nm-grp-2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>';
        document.getElementById('channelMeta').innerHTML = `${lockSvg}End-to-end encrypted group chat`;
        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) shareBtn.style.display = 'none';
        const favBtn = document.getElementById('favoriteChannelBtn');
        if (favBtn) favBtn.style.display = 'none';
        if (typeof this._refreshCallButtons === 'function') this._refreshCallButtons();
    },

    openGroup(groupId) {
        const group = this.groupConversations.get(groupId);
        if (!group) return;

        if (this._cvActive) { this._cvOpenConversation({ type: 'group', groupId }); return; }
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

        // Close the mobile sidebar as soon as the switch is committed.
        if (window.innerWidth <= 1024) {
            this.closeSidebar();
        }

        // Track navigation history
        this._pushNavigation({ type: 'group', groupId });

        // Re-render typing indicator for the new conversation
        this.renderTypingIndicator();

        // Build the group header (custom avatar or stacked member avatars).
        this._renderGroupHeader(groupId);

        // Mark only the matching group item as active
        document.querySelectorAll('.channel-item').forEach(i => i.classList.remove('active'));
        document.querySelectorAll('.pm-item').forEach(i => {
            i.classList.toggle('active', i.dataset.groupId === groupId);
        });

        const groupConvKey = this.getGroupConversationKey(groupId);
        this.clearUnreadCount(groupConvKey);
        this.loadPMMessages(groupConvKey);

        this._markVisibleGroupMessagesRead();

        // Restore any unsent input previously typed for this conversation
        this._restoreDraftForContext();

        this.hideAutocomplete();
        this.hideChannelAutocomplete();
        this.hideEmojiAutocomplete();
        this._focusMessageInput();
    },

    _markVisibleGroupMessagesRead() {
        if (!this.inPMMode || !this.currentGroup) return;
        if (document.hidden || this.userScrolledUp) return;
        if (!this._canSendGiftWraps()) return;
        const groupId = this.currentGroup;
        const messages = this.pmMessages.get(this.getGroupConversationKey(groupId));
        if (!messages || !messages.length) return;
        let sentAny = false;
        for (const m of messages) {
            if (m.isOwn || m.readReceiptSent || m.isHistorical || !m.nymMessageId) continue;
            this.sendNymReceipt(m.nymMessageId, 'read', m.pubkey, 'group', groupId);
            m.readReceiptSent = true;
            sentAny = true;
        }
        if (sentAny) this.recordOwnActivity();
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
        const memberRow = (pk) => {
            const baseNym = this.parseNymFromDisplay(this.getNymFromPubkey(pk) || '');
            const suffix = this.getPubkeySuffix(pk);
            const safePk = this._safePubkey(pk);
            const avatarSrc = this.getAvatarUrl(pk);
            const flairHtml = this.getFlairForUser(pk) || '';
            const labels = [];
            if (pk === ownerPk) labels.push('owner');
            else if (mods.includes(pk)) labels.push('mod');
            if (pk === this.pubkey) labels.push('you');
            const labelHtml = labels.length
                ? `<span class="group-info-label">${labels.join(', ')}</span>`
                : '';
            return `<div class="group-info-member" data-pubkey="${safePk}"><img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy"><span class="group-info-nym">${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml}</span>${labelHtml}</div>`;
        };
        const membersHtml = sorted.map(memberRow).join('');
        const infoId = `group-info-${Date.now().toString(36)}`;
        const html = `<div class="group-info" id="${infoId}"><div class="group-info-title">Group: "${this.escapeHtml(group.name)}"</div><div class="group-info-count">Members (${group.members.length})</div><div class="group-info-members">${membersHtml}</div></div>`;
        this.displaySystemMessage(html, 'system', { html: true });
        if (typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(document.getElementById(infoId), sorted);
        }
    },

    toggleGroupMentionsOnly(enabled) {
        this.groupNotifyMentionsOnly = enabled;
        localStorage.setItem('nym_group_notify_mentions_only', String(enabled));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

});
