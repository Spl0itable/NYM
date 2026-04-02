/**
 * MLS (Marmot Protocol) integration layer for Nymchat group chats.
 *
 * Wraps @internet-privacy/marmot-ts to provide:
 * - MLS-based group creation, messaging, member management
 * - KeyPackage lifecycle (publish, rotate)
 * - NIP-59 gift-wrapped Welcome events (kind 444)
 * - Encrypted group messages (kind 445) with ephemeral keys
 * - localStorage-backed state persistence
 *
 * Depends on window.MarmotMLS (from marmot-bundle.js) and window.NostrTools.
 */

class NymMLS {
    constructor(nymInstance) {
        this.nym = nymInstance;
        this.client = null;
        this._initialized = false;
        // Map of nostrGroupId (hex) -> { marmotGroup, nymGroupId (UUID) }
        this._groupMap = new Map();
        // Map of nymGroupId (UUID) -> nostrGroupId (hex) for reverse lookup
        this._nymToMls = new Map();
        // Track processed kind 445 event IDs to avoid re-processing on reload
        this._processedEventIds = new Set();
        // Timestamp of init — skip kind 445 events older than this on reload
        this._initTimestamp = 0;
        // Persisted set of event IDs (kind 444 + 445) that already triggered notifications.
        // Prevents re-firing desktop/sound notifications on app reload.
        this._notifiedEventIds = new Set();
    }

    // ──────────────────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────────────────

    async init() {
        if (this._initialized) return;
        const M = window.MarmotMLS;
        if (!M) {
            console.warn('[MLS] MarmotMLS bundle not loaded');
            return;
        }

        const signer = this._buildSigner();
        if (!signer) {
            console.warn('[MLS] No signer available, MLS disabled');
            return;
        }

        // localStorage-backed GroupStateStore
        const groupStateBackend = this._createGroupStateBackend();
        // localStorage-backed KeyPackageStore
        const keyPackageBackend = this._createKeyValueBackend('nym_mls_kp_');

        this.client = new M.MarmotClient({
            signer,
            network: this._buildNetworkInterface(),
            groupStateBackend,
            keyPackageStore: new M.KeyPackageStore(keyPackageBackend),
        });

        // Load all existing groups from storage
        try {
            const storedIds = await groupStateBackend.list();
            if (storedIds.length > 0) {
                const groups = await this.client.loadAllGroups();
                for (const group of groups) {
                    this._registerGroup(group);
                }
            }
        } catch (e) {
            console.warn('[MLS] Failed to load groups:', e);
        }

        // If groups were loaded from storage, set init timestamp so we skip
        // old kind 445 events from relays (they can't be re-decrypted and would
        // corrupt the MLS generation counter state).
        if (this._groupMap.size > 0) {
            this._initTimestamp = Math.floor(Date.now() / 1000) - 5; // 5s grace for in-flight events
        }

        // Load persisted notification tracking from localStorage
        this._loadNotifiedEventIds();

        this._initialized = true;
        // Initialization complete
        console.log('[MLS] Ready:', this._groupMap.size, 'groups',
            this._initTimestamp ? '(reload, skipping events before ' + this._initTimestamp + ')' : '(fresh)');
    }

    // ──────────────────────────────────────────────────────────
    //  Signer adapter (bridges NIP-07/privkey/NIP-46 → EventSigner)
    // ──────────────────────────────────────────────────────────

    _buildSigner() {
        const nym = this.nym;
        const NT = window.NostrTools;

        if (nym.privkey) {
            // Local private key path
            return {
                getPublicKey: () => nym.pubkey,
                signEvent: (draft) => {
                    return NT.finalizeEvent(draft, nym.privkey);
                },
                nip44: {
                    encrypt: (pubkey, plaintext) => {
                        const ck = NT.nip44.getConversationKey(nym.privkey, pubkey);
                        return NT.nip44.encrypt(plaintext, ck);
                    },
                    decrypt: (pubkey, ciphertext) => {
                        const ck = NT.nip44.getConversationKey(nym.privkey, pubkey);
                        return NT.nip44.decrypt(ciphertext, ck);
                    },
                },
            };
        }

        if (window.nostr?.signEvent && window.nostr?.nip44) {
            // NIP-07 extension path
            return {
                getPublicKey: () => Promise.resolve(nym.pubkey),
                signEvent: (draft) => window.nostr.signEvent(draft),
                nip44: {
                    encrypt: (pubkey, plaintext) => window.nostr.nip44.encrypt(pubkey, plaintext),
                    decrypt: (pubkey, ciphertext) => window.nostr.nip44.decrypt(pubkey, ciphertext),
                },
            };
        }

        return null;
    }

    // ──────────────────────────────────────────────────────────
    //  Network adapter (bridges Nymchat relay pool → NostrNetworkInterface)
    // ──────────────────────────────────────────────────────────

    _buildNetworkInterface() {
        const nym = this.nym;
        const self = this;

        // Get the pool socket for sending/receiving in pool proxy mode
        const getPoolSocket = () => {
            if (nym.useRelayProxy) {
                // Pool mode: use _poolSend for sending, listen on pool sockets
                const open = nym.poolSockets?.find(p => p.ws && p.ws.readyState === WebSocket.OPEN);
                return open?.ws || null;
            }
            return null;
        };

        return {
            publish: async (relays, event) => {
                // Use the app's sendDMToRelays which handles pool proxy mode correctly
                const sent = nym.sendDMToRelays(['EVENT', event]);
                const responses = {};
                for (const url of (relays.length > 0 ? relays : nym.bitchatDMRelays)) {
                    responses[url] = { from: url, ok: sent > 0 };
                }
                return responses;
            },

            request: async (relays, filters) => {
                const filtersArr = Array.isArray(filters) ? filters : [filters];
                const events = [];
                const seen = new Set();
                const subId = 'mls_' + Math.random().toString(36).slice(2, 8);

                return new Promise((resolve) => {
                    let resolved = false;
                    const timeout = setTimeout(() => {
                        if (!resolved) { resolved = true; cleanup(); resolve(events); }
                    }, 5000);

                    const poolWs = getPoolSocket();
                    const handlers = [];

                    const cleanup = () => {
                        for (const { ws, handler } of handlers) {
                            ws.removeEventListener('message', handler);
                        }
                        // Send CLOSE
                        try {
                            if (poolWs) {
                                nym._poolSend(['CLOSE', subId]);
                            } else {
                                nym.relayPool.forEach((relay) => {
                                    if (relay.ws?.readyState === WebSocket.OPEN) {
                                        relay.ws.send(JSON.stringify(['CLOSE', subId]));
                                    }
                                });
                            }
                        } catch (e) {}
                    };

                    const handler = (msgEvt) => {
                        try {
                            const data = JSON.parse(msgEvt.data);
                            if (data[0] === 'EVENT' && data[1] === subId && data[2]) {
                                if (!seen.has(data[2].id)) {
                                    seen.add(data[2].id);
                                    events.push(data[2]);
                                }
                            } else if (data[0] === 'EOSE' && data[1] === subId) {
                                if (!resolved) {
                                    resolved = true;
                                    clearTimeout(timeout);
                                    cleanup();
                                    resolve(events);
                                }
                            }
                        } catch (e) {}
                    };

                    if (poolWs) {
                        // Pool mode: single listener on pool socket, send via _poolSend
                        poolWs.addEventListener('message', handler);
                        handlers.push({ ws: poolWs, handler });
                        nym._poolSend(['REQ', subId, ...filtersArr]);
                    } else {
                        // Direct mode: attach to each connected relay
                        let connected = 0;
                        nym.relayPool.forEach((relay, url) => {
                            if (relay.ws?.readyState === WebSocket.OPEN) {
                                relay.ws.addEventListener('message', handler);
                                handlers.push({ ws: relay.ws, handler });
                                relay.ws.send(JSON.stringify(['REQ', subId, ...filtersArr]));
                                connected++;
                            }
                        });
                        if (connected === 0 && !resolved) {
                            resolved = true;
                            clearTimeout(timeout);
                            resolve(events);
                        }
                    }
                });
            },

            subscription: (relays, filters) => {
                const filtersArr = Array.isArray(filters) ? filters : [filters];
                return {
                    subscribe: (observer) => {
                        const subId = 'mls_sub_' + Math.random().toString(36).slice(2, 8);
                        const handlers = [];

                        const poolWs = getPoolSocket();

                        const handler = (msgEvt) => {
                            try {
                                const data = JSON.parse(msgEvt.data);
                                if (data[0] === 'EVENT' && data[1] === subId && data[2]) {
                                    if (observer.next) observer.next(data[2]);
                                }
                            } catch (e) {}
                        };

                        if (poolWs) {
                            poolWs.addEventListener('message', handler);
                            handlers.push({ ws: poolWs, handler });
                            nym._poolSend(['REQ', subId, ...filtersArr]);
                        } else {
                            nym.relayPool.forEach((relay, url) => {
                                if (relay.ws?.readyState === WebSocket.OPEN) {
                                    relay.ws.addEventListener('message', handler);
                                    handlers.push({ ws: relay.ws, handler });
                                    relay.ws.send(JSON.stringify(['REQ', subId, ...filtersArr]));
                                }
                            });
                        }

                        return {
                            unsubscribe: () => {
                                for (const { ws, handler: h } of handlers) {
                                    ws.removeEventListener('message', h);
                                }
                                try {
                                    if (poolWs) {
                                        nym._poolSend(['CLOSE', subId]);
                                    } else {
                                        nym.relayPool.forEach((relay) => {
                                            if (relay.ws?.readyState === WebSocket.OPEN) {
                                                relay.ws.send(JSON.stringify(['CLOSE', subId]));
                                            }
                                        });
                                    }
                                } catch (e) {}
                                handlers.length = 0;
                            }
                        };
                    }
                };
            },

            getUserInboxRelays: async (pubkey) => {
                const events = await self.client.network.request(
                    nym.bitchatDMRelays,
                    { kinds: [10050], authors: [pubkey], limit: 1 }
                );
                if (events.length > 0) {
                    const relayTags = events[0].tags.filter(t => t[0] === 'relay' && t[1]);
                    if (relayTags.length > 0) return relayTags.map(t => t[1]);
                }
                return [...nym.bitchatDMRelays];
            },
        };
    }

    // ──────────────────────────────────────────────────────────
    //  Storage backends (localStorage)
    // ──────────────────────────────────────────────────────────

    _createGroupStateBackend() {
        const prefix = `nym_mls_gs_${this.nym.pubkey}_`;
        const self = this;
        return {
            get: async (groupId) => {
                const hex = self._bytesToHex(groupId);
                const data = localStorage.getItem(prefix + hex);
                if (!data) return null;
                return this._base64ToBytes(data);
            },
            set: async (groupId, stateBytes) => {
                const hex = this._bytesToHex(groupId);
                const key = prefix + hex;
                try {
                    const b64 = this._bytesToBase64(stateBytes);
                    localStorage.setItem(key, b64);
                } catch (e) {
                    console.error('[MLS] Failed to save group state to localStorage:', e);
                }
            },
            remove: async (groupId) => {
                const hex = this._bytesToHex(groupId);
                localStorage.removeItem(prefix + hex);
            },
            list: async () => {
                const ids = [];
                for (let i = 0; i < localStorage.length; i++) {
                    const key = localStorage.key(i);
                    if (key && key.startsWith(prefix)) {
                        const hex = key.slice(prefix.length);
                        ids.push(this._hexToBytes(hex));
                    }
                }
                return ids;
            },
        };
    }

    _createKeyValueBackend(prefix) {
        const fullPrefix = prefix + (this.nym.pubkey || '') + '_';

        // Custom JSON replacer/reviver to handle Uint8Array and BigInt,
        // which MLS key packages contain but JSON cannot natively represent.
        const replacer = (_, v) => {
            if (v instanceof Uint8Array) {
                return { __type: 'Uint8Array', data: Array.from(v) };
            }
            if (typeof v === 'bigint') {
                return { __type: 'BigInt', data: v.toString() };
            }
            return v;
        };
        const reviver = (_, v) => {
            if (v && typeof v === 'object' && v.__type === 'Uint8Array' && Array.isArray(v.data)) {
                return new Uint8Array(v.data);
            }
            if (v && typeof v === 'object' && v.__type === 'BigInt' && typeof v.data === 'string') {
                return BigInt(v.data);
            }
            return v;
        };

        return {
            getItem: async (key) => {
                const data = localStorage.getItem(fullPrefix + key);
                if (!data) return null;
                try { return JSON.parse(data, reviver); } catch { return null; }
            },
            setItem: async (key, value) => {
                localStorage.setItem(fullPrefix + key, JSON.stringify(value, replacer));
                return value;
            },
            removeItem: async (key) => {
                localStorage.removeItem(fullPrefix + key);
            },
            clear: async () => {
                const toRemove = [];
                for (let i = 0; i < localStorage.length; i++) {
                    const k = localStorage.key(i);
                    if (k && k.startsWith(fullPrefix)) toRemove.push(k);
                }
                toRemove.forEach(k => localStorage.removeItem(k));
            },
            keys: async () => {
                const result = [];
                for (let i = 0; i < localStorage.length; i++) {
                    const k = localStorage.key(i);
                    if (k && k.startsWith(fullPrefix)) {
                        result.push(k.slice(fullPrefix.length));
                    }
                }
                return result;
            },
        };
    }

    // ──────────────────────────────────────────────────────────
    //  KeyPackage lifecycle
    // ──────────────────────────────────────────────────────────

    async publishKeyPackages() {
        if (!this.client) return;
        try {
            // Check if we already have a usable key package with valid private key
            const existing = await this.client.keyPackages.list();
            const validUnused = [];
            for (const kp of existing) {
                if (kp.used || !kp.published || kp.published.length === 0) continue;
                // Verify private key is retrievable
                try {
                    const pk = await this.client.keyPackages.getPrivateKey(kp.keyPackageRef);
                    if (pk) { validUnused.push(kp); continue; }
                } catch (e) { /* corrupted entry, skip */ }
            }
            if (validUnused.length > 0) {
                // Already have valid published KeyPackage(s)
                return;
            }

            // Delete old KP events from relays so stale ones aren't fetched by others
            await this._deleteOldKeyPackageEvents();

            // KeyPackageManager.create() handles the full lifecycle:
            // generate keypair, store private material, sign kind 443 event, publish to relays
            const relays = [...this.nym.bitchatDMRelays];
            const kp = await this.client.keyPackages.create({ relays });
            // KeyPackage published successfully
        } catch (e) {
            console.warn('[MLS] KeyPackage publish failed:', e);
        }
    }

    // Publish a kind 5 (NIP-09) deletion event for old KP events on relays
    async _deleteOldKeyPackageEvents() {
        try {
            const oldEvents = await this.client.network.request(
                this.nym.bitchatDMRelays,
                { kinds: [443], authors: [this.nym.pubkey], limit: 20 }
            );
            if (oldEvents.length === 0) return;

            const eventIds = oldEvents.map(e => e.id).filter(Boolean);
            if (eventIds.length === 0) return;

            const NT = window.NostrTools;
            const tags = eventIds.map(id => ['e', id]);
            tags.push(['k', '443']);
            const deleteEvent = { kind: 5, created_at: Math.floor(Date.now() / 1000), content: 'Superseded KeyPackage', tags };

            if (this.nym.privkey) {
                const signed = NT.finalizeEvent(deleteEvent, this.nym.privkey);
                this.nym.sendDMToRelays(['EVENT', signed]);
            } else if (window.nostr?.signEvent) {
                const signed = await window.nostr.signEvent(deleteEvent);
                this.nym.sendDMToRelays(['EVENT', signed]);
            }
            // Old KP events deleted
        } catch (e) {
            console.warn('[MLS] Failed to delete old KP events:', e);
        }
    }

    // Re-broadcast the most recent KeyPackage event to all connected relays
    async republishKeyPackage() {
        if (!this.client) return;
        try {
            const existing = await this.client.keyPackages.list();
            const withPublished = existing.filter(kp => kp.published && kp.published.length > 0);
            if (withPublished.length === 0) return;
            // Get the most recent published event
            const latest = withPublished[withPublished.length - 1];
            const event = latest.published[latest.published.length - 1];
            if (!event) return;
            // Re-publishing KeyPackage to more relays
            this.nym.sendDMToRelays(['EVENT', event]);
        } catch (e) {
            console.warn('[MLS] KeyPackage re-publish failed:', e);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Group creation
    // ──────────────────────────────────────────────────────────

    /**
     * Creates an MLS group and invites members.
     * Returns { mlsGroupId, nymGroupId } or null on failure.
     */
    async createGroup(name, memberPubkeys) {
        if (!this.client) return null;
        try {
            const allMembers = [...new Set([...memberPubkeys, this.nym.pubkey])];
            const relays = [...this.nym.bitchatDMRelays];

            // Create the MLS group
            const group = await this.client.createGroup(name, {
                adminPubkeys: [this.nym.pubkey],
                relays,
                description: '',
            });

            const mlsGroupIdHex = group.idStr;
            const rawNgid = group.groupData?.nostrGroupId;
            const nostrGroupId = rawNgid instanceof Uint8Array ? this._bytesToHex(rawNgid) : (rawNgid || mlsGroupIdHex);

            // Generate a nymchat UUID for sidebar/UI compatibility
            const nymGroupId = this.nym.generateUUID();

            // Store the mapping
            this._groupMap.set(nostrGroupId, { marmotGroup: group, nymGroupId });
            this._nymToMls.set(nymGroupId, nostrGroupId);
            this._saveMappings();

            // Persist MLS group state so it survives page reload
            await group.save();

            // Invite each member by fetching their KeyPackage
            const otherMembers = allMembers.filter(pk => pk !== this.nym.pubkey);
            const failedInvites = [];
            for (const memberPk of otherMembers) {
                try {
                    await this._inviteMember(group, memberPk);
                } catch (e) {
                    console.warn('[MLS] Failed to invite', memberPk.slice(0, 8), '- member needs MLS KeyPackage:', e.message);
                    failedInvites.push(memberPk);
                }
            }

            // Save updated state after invites (epoch may have advanced)
            await group.save();

            return { mlsGroupIdHex, nymGroupId, nostrGroupId, failedInvites };
        } catch (e) {
            console.error('[MLS] createGroup failed:', e);
            return null;
        }
    }

    async _inviteMember(group, pubkey) {
        // Fetch the member's KeyPackage (kind 443) from relays
        const kpEvents = await this.client.network.request(
            this.nym.bitchatDMRelays,
            { kinds: [443], authors: [pubkey], limit: 5 }
        );

        if (kpEvents.length === 0) {
            throw new Error('No KeyPackage found for ' + pubkey.slice(0, 8));
        }

        // Identify real MLS KeyPackage events (have mls_protocol_version or ciphersuite tags)
        const mlsEvents = kpEvents.filter(ev =>
            ev.tags && ev.tags.some(t =>
                t[0] === 'mls_protocol_version' || t[0] === 'ciphersuite' || t[0] === 'encoding'
            )
        );

        if (mlsEvents.length === 0) {
            console.warn('[MLS] Found', kpEvents.length, 'kind 443 events for', pubkey.slice(0, 8),
                'but none are MLS KeyPackages');
            throw new Error('No MLS KeyPackage found for ' + pubkey.slice(0, 8));
        }

        // Normalize: some clients (e.g. 0xchat) omit the encoding tag — assume base64
        for (const ev of mlsEvents) {
            if (!ev.tags.some(t => t[0] === 'encoding')) {
                ev.tags.push(['encoding', 'base64']);
            }
        }

        // Sort: prefer marmot-ts/nymchat KPs (have encoding tag natively) over other clients,
        // then by most recent. This ensures our KPs are tried before 0xchat etc.
        const sorted = mlsEvents.sort((a, b) => {
            const aHasEncoding = a.tags.some(t => t[0] === 'encoding' && !a._addedEncoding);
            const bHasEncoding = b.tags.some(t => t[0] === 'encoding' && !b._addedEncoding);
            const aClient = a.tags.find(t => t[0] === 'client')?.[1];
            const bClient = b.tags.find(t => t[0] === 'client')?.[1];
            // Prefer KPs without a 'client' tag (ours) or with native encoding tag
            if (!aClient && bClient) return -1;
            if (aClient && !bClient) return 1;
            return b.created_at - a.created_at;
        });

        // Try each KP until one decodes successfully
        for (const kpEvent of sorted) {
            const client = kpEvent.tags.find(t => t[0] === 'client')?.[1] || 'marmot-ts';
            try {
                // Try KeyPackage from this client
                await group.inviteByKeyPackageEvent(kpEvent);
                return; // success
            } catch (e) {
                console.warn('[MLS] KeyPackage from', client, 'failed to decode, trying next...', e.message);
            }
        }
        throw new Error('All KeyPackages for ' + pubkey.slice(0, 8) + ' failed to decode');
    }

    /**
     * Send a NIP-17 gift-wrapped fallback invite for members without MLS support.
     */
    async _sendLegacyInvite(nymGroupId, groupName, allMembers, recipientPubkey, nostrGroupId) {
        const now = Math.floor(Date.now() / 1000);
        const tags = allMembers.map(pk => ['p', pk]);
        tags.push(['g', nymGroupId]);
        tags.push(['subject', groupName]);
        tags.push(['type', 'group-invite']);
        tags.push(['x', this.nym.generateUUID()]);
        // Use 'h' tag so the receiver can resolve it to their local MLS group
        tags.push(['h', nostrGroupId]);

        const rumor = { kind: 14, created_at: now, tags, content: `You've been added to group "${groupName}".`, pubkey: this.nym.pubkey };
        await this.nym._sendGiftWrapsAsync([recipientPubkey], rumor, null);
    }

    // ──────────────────────────────────────────────────────────
    //  Group messaging (kind 445)
    // ──────────────────────────────────────────────────────────

    /**
     * Sends a message to an MLS group.
     * Returns true on success, false if MLS unavailable (caller should fall back to NIP-17).
     */
    async sendMessage(nymGroupId, content, nymMessageId) {
        const nostrGroupId = this._nymToMls.get(nymGroupId);
        if (!nostrGroupId || !this.client) return false;

        const entry = this._groupMap.get(nostrGroupId);
        if (!entry || !entry.marmotGroup) return false;

        try {
            // Pass nymMessageId as a tag so all members get the same message ID
            // (needed for reactions, read receipts, etc. to match across devices)
            const tags = nymMessageId ? [['x', nymMessageId]] : [];
            await entry.marmotGroup.sendChatMessage(content, tags);
            return true;
        } catch (e) {
            console.warn('[MLS] sendMessage failed:', e);
            return false;
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Member management
    // ──────────────────────────────────────────────────────────

    async addMember(nymGroupId, newMemberPubkey) {
        const nostrGroupId = this._nymToMls.get(nymGroupId);
        if (!nostrGroupId || !this.client) return false;

        const entry = this._groupMap.get(nostrGroupId);
        if (!entry || !entry.marmotGroup) return false;

        try {
            await this._inviteMember(entry.marmotGroup, newMemberPubkey);
            // Save state after invite (epoch advances with the commit)
            await entry.marmotGroup.save();
            return true;
        } catch (e) {
            console.warn('[MLS] addMember failed:', e);
            return false;
        }
    }

    async removeMember(nymGroupId, memberPubkey) {
        const nostrGroupId = this._nymToMls.get(nymGroupId);
        if (!nostrGroupId || !this.client) return false;

        const entry = this._groupMap.get(nostrGroupId);
        if (!entry || !entry.marmotGroup) return false;

        try {
            const M = window.MarmotMLS;
            await entry.marmotGroup.commit({
                extraProposals: [M.Proposals.proposeRemoveUser(memberPubkey)],
            });
            await entry.marmotGroup.save();
            return true;
        } catch (e) {
            console.warn('[MLS] removeMember failed:', e);
            return false;
        }
    }

    async leaveGroup(nymGroupId) {
        const nostrGroupId = this._nymToMls.get(nymGroupId);
        if (!nostrGroupId || !this.client) return false;

        try {
            await this.client.leaveGroup(nostrGroupId);
            this._groupMap.delete(nostrGroupId);
            this._nymToMls.delete(nymGroupId);
            this._saveMappings();
            return true;
        } catch (e) {
            console.warn('[MLS] leaveGroup failed:', e);
            return false;
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Incoming event handling
    // ──────────────────────────────────────────────────────────

    /**
     * Process a kind 444 Welcome event (received as unwrapped rumor from gift wrap).
     * Returns { nymGroupId, groupName } if successfully joined, or null.
     */
    async handleWelcome(welcomeRumor) {
        if (!this.client) return null;
        try {
            const result = await this.client.joinGroupFromWelcome({ welcomeRumor });
            const group = result.group;
            const rawNgid = group.groupData?.nostrGroupId;
            const nostrGroupId = rawNgid instanceof Uint8Array ? this._bytesToHex(rawNgid) : (rawNgid || group.idStr);
            const groupName = group.groupData?.name || 'MLS Group';

            // Check if we already have a nymGroupId for this MLS group
            let nymGroupId = null;
            for (const [nid, mid] of this._nymToMls) {
                if (mid === nostrGroupId) { nymGroupId = nid; break; }
            }
            if (!nymGroupId) {
                nymGroupId = this.nym.generateUUID();
            }

            this._groupMap.set(nostrGroupId, { marmotGroup: group, nymGroupId });
            this._nymToMls.set(nymGroupId, nostrGroupId);
            this._saveMappings();

            // Persist MLS group state so it survives page reload
            await group.save();

            // Joined group via Welcome
            return { nymGroupId, groupName, nostrGroupId, members: this._getGroupMembers(group) };
        } catch (e) {
            console.warn('[MLS] handleWelcome failed:', e);
            // If the KeyPackage is stale (private key lost from local store),
            // rotate it so future invites use a fresh one
            if (e.message && e.message.includes('KeyPackage')) {
                console.warn('[MLS] Stale KeyPackage detected — rotating...');
                try {
                    await this._deleteOldKeyPackageEvents();
                    // Force Marmot to create a fresh KeyPackage
                    const relays = [...this.nym.bitchatDMRelays];
                    await this.client.keyPackages.create({ relays });
                    console.log('[MLS] Fresh KeyPackage published after stale KP error');
                } catch (kpErr) {
                    console.warn('[MLS] KeyPackage rotation failed:', kpErr);
                }
            }
            return null;
        }
    }

    /**
     * Process kind 445 group message events.
     * Returns array of { pubkey, content, created_at, nymGroupId, kind } or empty array.
     */
    async handleGroupEvents(nymGroupId, events) {
        const nostrGroupId = this._nymToMls.get(nymGroupId);
        if (!nostrGroupId || !this.client) return { messages: [], membersChanged: false };

        const entry = this._groupMap.get(nostrGroupId);
        if (!entry || !entry.marmotGroup) return { messages: [], membersChanged: false };

        const messages = [];
        let membersChanged = false;
        try {
            for await (const result of entry.marmotGroup.ingest(events)) {
                if (result.kind === 'processed' && result.result?.kind === 'applicationMessage') {
                    // The decoded rumor is in result.result.message
                    const rumor = result.result.message;
                    if (rumor) {
                        // Deserialize if needed (marmot may return raw bytes or parsed object)
                        let parsed = rumor;
                        if (rumor instanceof Uint8Array) {
                            try { parsed = JSON.parse(new TextDecoder().decode(rumor)); } catch (e) {
                                console.warn('[MLS] Failed to parse application message bytes:', e);
                                continue;
                            }
                        }
                        const msg = {
                            pubkey: parsed.pubkey,
                            content: parsed.content,
                            created_at: parsed.created_at,
                            kind: parsed.kind,
                            tags: parsed.tags || [],
                            nymGroupId,
                            id: parsed.id,
                        };
                        messages.push(msg);
                        // Persist the message locally
                        this._persistMessage(nostrGroupId, msg);
                    }
                } else if (result.kind === 'processed' && result.result?.kind === 'newState') {
                    // Epoch advanced (commit processed — likely member add/remove)
                    // Commit processed, saving state
                    await entry.marmotGroup.save();
                    membersChanged = true;
                } else if (result.kind === 'unreadable') {
                    console.warn('[MLS] Unreadable event:', result.event?.id?.slice(0, 16), result.errors);
                } else if (result.kind === 'skipped') {
                    // Self-echo or wrong wireformat — silently skip
                }
            }
        } catch (e) {
            console.warn('[MLS] ingest failed:', e);
        }

        return { messages, membersChanged };
    }

    /**
     * Subscribe to kind 445 events for all known MLS groups.
     * Called after init to start listening for group messages.
     */
    startGroupSubscriptions() {
        if (!this.client || this._groupMap.size === 0) return;

        const groupIds = [];
        for (const [nostrGroupId, entry] of this._groupMap) {
            const relays = entry.marmotGroup.groupData?.relays || this.nym.bitchatDMRelays;
            groupIds.push(nostrGroupId);
        }

        if (groupIds.length === 0) return;

        // Subscribe to kind 445 events with h tags matching our groups
        const allRelays = [...new Set([
            ...this.nym.bitchatDMRelays,
            ...Array.from(this._groupMap.values())
                .flatMap(e => e.marmotGroup.groupData?.relays || [])
        ])];

        const filter = {
            kinds: [445],
            '#h': groupIds,
            since: Math.floor(Date.now() / 1000) - 86400, // Last 24 hours
        };

        const sub = this.client.network.subscription(allRelays, filter);
        this._groupSub = sub.subscribe({
            next: (event) => {
                this._handleIncomingGroupEvent(event);
            },
        });
    }

    async _handleIncomingGroupEvent(event) {
        if (event.kind !== 445) return;

        // Skip already-processed events
        if (this._processedEventIds.has(event.id)) return;

        // On reload, skip old events that pre-date our init — they can't be
        // re-decrypted (MLS generation counters have advanced) and attempting
        // to ingest them corrupts the state.
        if (this._initTimestamp && event.created_at && event.created_at < this._initTimestamp) {
            return;
        }

        const hTag = (event.tags || []).find(t => t[0] === 'h' && t[1]);
        if (!hTag) return;

        const nostrGroupId = hTag[1];
        const entry = this._groupMap.get(nostrGroupId);
        if (!entry) return;

        this._processedEventIds.add(event.id);
        // Cap set size to prevent memory leak
        if (this._processedEventIds.size > 2000) {
            const iter = this._processedEventIds.values();
            for (let i = 0; i < 500; i++) iter.next();
            // Restart by keeping only recent entries
            const keep = new Set();
            for (const id of this._processedEventIds) keep.add(id);
            // Actually just delete oldest 500
            const arr = [...this._processedEventIds];
            this._processedEventIds = new Set(arr.slice(500));
        }

        // Check if this event already triggered a notification in a prior session
        const alreadyNotified = this.wasNotified(event.id);

        const { messages, membersChanged } = await this.handleGroupEvents(entry.nymGroupId, [event]);
        for (const msg of messages) {
            msg._alreadyNotified = alreadyNotified;
            this.nym._handleMLSMessage(msg);
        }

        // Mark this event as notified (persists to localStorage)
        if (!alreadyNotified) this.markNotified(event.id);
        // After processing a commit (member add/remove), refresh the member list
        if (membersChanged) {
            const updatedMembers = this._getGroupMembers(entry.marmotGroup);
            const grp = this.nym.groupConversations.get(entry.nymGroupId);
            if (grp) {
                const oldCount = grp.members.length;
                grp.members = [...new Set([...grp.members, ...updatedMembers])];
                if (grp.members.length !== oldCount) {
                    // Group members updated
                    this.nym.updateGroupConversationUI(entry.nymGroupId);
                    this.nym._saveGroupConversations();
                }
            }
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────

    _registerGroup(group) {
        const rawNgid = group.groupData?.nostrGroupId;
        const nostrGroupId = rawNgid instanceof Uint8Array ? this._bytesToHex(rawNgid) : (rawNgid || group.idStr);
        const mappings = this._loadMappings();
        let nymGroupId = null;
        for (const [nid, mid] of Object.entries(mappings)) {
            if (mid === nostrGroupId) { nymGroupId = nid; break; }
        }
        if (!nymGroupId) nymGroupId = this.nym.generateUUID();

        this._groupMap.set(nostrGroupId, { marmotGroup: group, nymGroupId });
        this._nymToMls.set(nymGroupId, nostrGroupId);
    }

    _getGroupMembers(group) {
        const members = new Set();
        try {
            const M = window.MarmotMLS;
            // Extract member pubkeys from ratchet tree leaf nodes
            // Marmot tree nodes have: { nodeType: leaf|parent, leaf: { credential, ... } }
            const state = group.state;
            if (state?.ratchetTree) {
                for (const node of state.ratchetTree) {
                    if (!node) continue;
                    // Marmot uses node.leaf.credential for leaf nodes
                    const cred = node.leaf?.credential
                        || node.leafNode?.credential
                        || node.credential
                        || null;
                    if (cred) {
                        try {
                            const pk = M.getCredentialPubkey(cred);
                            if (pk) members.add(pk);
                        } catch (e) { /* skip invalid credential */ }
                    }
                }
            }
            // Include admin pubkeys from group metadata (includes creator)
            if (group.groupData?.adminPubkeys) {
                for (const pk of group.groupData.adminPubkeys) {
                    if (pk) members.add(pk);
                }
            }
            // Always include self
            if (this.nym.pubkey) members.add(this.nym.pubkey);
            // Members extracted from ratchet tree
        } catch (e) {
            console.warn('[MLS] _getGroupMembers error:', e);
            if (this.nym.pubkey) members.add(this.nym.pubkey);
        }
        return [...members];
    }

    isMlsGroup(nymGroupId) {
        return this._nymToMls.has(nymGroupId);
    }

    getMlsGroupId(nymGroupId) {
        return this._nymToMls.get(nymGroupId) || null;
    }

    // ──────────────────────────────────────────────────────────
    //  Mapping persistence (nymGroupId <-> nostrGroupId)
    // ──────────────────────────────────────────────────────────

    _saveMappings() {
        const data = {};
        for (const [nymId, mlsId] of this._nymToMls) {
            data[nymId] = mlsId;
        }
        try {
            localStorage.setItem(`nym_mls_mappings_${this.nym.pubkey}`, JSON.stringify(data));
        } catch (e) {}
    }

    _loadMappings() {
        try {
            const raw = localStorage.getItem(`nym_mls_mappings_${this.nym.pubkey}`);
            return raw ? JSON.parse(raw) : {};
        } catch (e) {
            return {};
        }
    }

    _restoreMappings() {
        const data = this._loadMappings();
        for (const [nymId, mlsId] of Object.entries(data)) {
            this._nymToMls.set(nymId, mlsId);
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Notification dedup persistence (survives reload)
    // ──────────────────────────────────────────────────────────

    _notifiedStorageKey() {
        return `nym_mls_notified_${this.nym.pubkey}`;
    }

    _loadNotifiedEventIds() {
        try {
            const raw = localStorage.getItem(this._notifiedStorageKey());
            if (raw) {
                const arr = JSON.parse(raw);
                this._notifiedEventIds = new Set(arr);
            }
        } catch (e) {
            this._notifiedEventIds = new Set();
        }
    }

    _saveNotifiedEventIds() {
        try {
            // Keep last 500 to prevent unbounded growth
            let arr = [...this._notifiedEventIds];
            if (arr.length > 500) arr = arr.slice(-500);
            localStorage.setItem(this._notifiedStorageKey(), JSON.stringify(arr));
        } catch (e) {}
    }

    /**
     * Check whether an event has already triggered a notification.
     * If not, mark it as notified and persist.
     * Returns true if this is the FIRST time (should notify), false if already seen.
     */
    markNotified(eventId) {
        if (this._notifiedEventIds.has(eventId)) return false;
        this._notifiedEventIds.add(eventId);
        this._saveNotifiedEventIds();
        return true;
    }

    wasNotified(eventId) {
        return this._notifiedEventIds.has(eventId);
    }

    // ──────────────────────────────────────────────────────────
    //  Message persistence (MLS messages can't be re-decrypted from relays)
    // ──────────────────────────────────────────────────────────

    _persistMessage(nostrGroupId, msg) {
        const key = `nym_mls_msgs_${this.nym.pubkey}_${nostrGroupId}`;
        try {
            const raw = localStorage.getItem(key);
            const msgs = raw ? JSON.parse(raw) : [];
            // Deduplicate by id
            if (msg.id && msgs.some(m => m.id === msg.id)) return;
            msgs.push(msg);
            // Keep last 200 messages per group
            if (msgs.length > 200) msgs.splice(0, msgs.length - 200);
            localStorage.setItem(key, JSON.stringify(msgs));
            // Debounced sync to Nostr so history is available cross-device
            if (this.nym.settings.syncMLSHistory && typeof this.nym._debouncedNostrSettingsSave === 'function') {
                this.nym._debouncedNostrSettingsSave(30000); // 30s debounce
            }
        } catch (e) {
            console.warn('[MLS] Failed to persist message:', e);
        }
    }

    // Store a sent message (called by app after sendMessage succeeds)
    persistSentMessage(nymGroupId, msg) {
        const nostrGroupId = this._nymToMls.get(nymGroupId);
        if (!nostrGroupId) return;
        this._persistMessage(nostrGroupId, msg);
    }

    // Load persisted messages for a group (called on reload)
    loadPersistedMessages(nymGroupId) {
        const nostrGroupId = this._nymToMls.get(nymGroupId);
        if (!nostrGroupId) return [];
        const key = `nym_mls_msgs_${this.nym.pubkey}_${nostrGroupId}`;
        try {
            const raw = localStorage.getItem(key);
            return raw ? JSON.parse(raw) : [];
        } catch (e) {
            return [];
        }
    }

    // ──────────────────────────────────────────────────────────
    //  Byte/hex/base64 utilities
    // ──────────────────────────────────────────────────────────

    _bytesToHex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    _hexToBytes(hex) {
        const bytes = new Uint8Array(hex.length / 2);
        for (let i = 0; i < hex.length; i += 2) {
            bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
        }
        return bytes;
    }

    _bytesToBase64(bytes) {
        let binary = '';
        for (let i = 0; i < bytes.length; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    }

    _base64ToBytes(base64) {
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes;
    }

    // Cleanup
    destroy() {
        if (this._groupSub) {
            this._groupSub.unsubscribe();
            this._groupSub = null;
        }
        this._groupMap.clear();
        this._nymToMls.clear();
        this.client = null;
        this._initialized = false;
    }
}

// Export globally
window.NymMLS = NymMLS;