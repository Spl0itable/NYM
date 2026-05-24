// persistence.js - IndexedDB-backed cache for channel messages, PMs, group chats, user profiles, and reactions.

(function () {
    const DB_NAME = 'nym-cache';
    const DB_VERSION = 3;
    const STORES = ['meta', 'profiles', 'channels', 'pms', 'reactions', 'avatars', 'banners'];
    const MESSAGE_STORES = new Set(['channels', 'pms']);

    const PERSIST_DEBOUNCE_MS = 1500;

    const STORE_LIMITS = {
        profiles: 2000,
        reactions: 5000,
        avatars: 500,
        banners: 200
    };

    // Debounce for the dedup-set persistence
    const DEDUP_PERSIST_DEBOUNCE_MS = 5000;

    // Meta store keys.
    const META_PROCESSED_PM_EVENT_IDS = 'processedPMEventIds';
    const META_DELETED_EVENT_IDS = 'deletedEventIds';
    const META_NYMCHAT_PUBKEYS = 'nymchatPubkeys';
    const META_NYMCHAT_VOUCHES = 'nymchatVouches';

    Object.assign(NYM.prototype, {

        _cacheOpen() {
            if (this._cacheDbPromise) return this._cacheDbPromise;
            this._cacheDbPromise = new Promise((resolve, reject) => {
                if (!('indexedDB' in window)) {
                    reject(new Error('IndexedDB not available'));
                    return;
                }
                let req;
                try {
                    req = indexedDB.open(DB_NAME, DB_VERSION);
                } catch (e) {
                    reject(e);
                    return;
                }
                req.onupgradeneeded = (e) => {
                    const db = e.target.result;
                    const tx = e.target.transaction;
                    if (!db.objectStoreNames.contains('meta')) db.createObjectStore('meta', { keyPath: 'key' });
                    if (!db.objectStoreNames.contains('profiles')) db.createObjectStore('profiles', { keyPath: 'pubkey' });
                    if (!db.objectStoreNames.contains('reactions')) db.createObjectStore('reactions', { keyPath: 'messageId' });
                    if (!db.objectStoreNames.contains('avatars')) db.createObjectStore('avatars', { keyPath: 'pubkey' });
                    if (!db.objectStoreNames.contains('banners')) db.createObjectStore('banners', { keyPath: 'pubkey' });

                    const upgradeMessageStore = (storeName) => {
                        const hadOld = db.objectStoreNames.contains(storeName);
                        if (!hadOld) {
                            const newStore = db.createObjectStore(storeName, { keyPath: 'id' });
                            newStore.createIndex('conv', 'conv', { unique: false });
                            return;
                        }
                        const oldStore = tx.objectStore(storeName);
                        // Only migrate if the existing store is the legacy per-conversation shape (keyPath 'key').
                        if (oldStore.keyPath === 'id') return;
                        const getReq = oldStore.getAll();
                        getReq.onsuccess = () => {
                            const oldRecords = getReq.result || [];
                            db.deleteObjectStore(storeName);
                            const newStore = db.createObjectStore(storeName, { keyPath: 'id' });
                            newStore.createIndex('conv', 'conv', { unique: false });
                            for (const r of oldRecords) {
                                if (!r || !r.key || !Array.isArray(r.messages)) continue;
                                for (const m of r.messages) {
                                    if (!m || !m.id) continue;
                                    try { newStore.put({ ...m, conv: r.key, lastTouched: r.lastTouched || Date.now() }); } catch (_) { }
                                }
                            }
                        };
                    };
                    upgradeMessageStore('channels');
                    upgradeMessageStore('pms');
                };
                req.onsuccess = () => resolve(req.result);
                req.onerror = () => reject(req.error);
                req.onblocked = () => reject(new Error('IndexedDB blocked'));
            }).catch(err => {
                // Once a load fails (private mode, quota, etc.), stop trying.
                this._cacheDbPromise = null;
                this._cacheDisabled = true;
                throw err;
            });
            return this._cacheDbPromise;
        },

        // IndexedDB transactions go inactive at the end of the task
        async _cacheGetAll(storeName) {
            if (this._cacheDisabled) return [];
            if (!STORES.includes(storeName)) return [];
            try {
                const db = await this._cacheOpen();
                return await new Promise((resolve) => {
                    let result = [];
                    try {
                        const tx = db.transaction(storeName, 'readonly');
                        const store = tx.objectStore(storeName);
                        const req = store.getAll();
                        req.onsuccess = () => { result = req.result || []; };
                        req.onerror = () => { result = []; };
                        tx.oncomplete = () => resolve(result);
                        tx.onabort = () => resolve(result);
                        tx.onerror = () => resolve(result);
                    } catch (_) {
                        resolve([]);
                    }
                });
            } catch (_) {
                return [];
            }
        },

        async _cachePut(storeName, value) {
            if (this._cacheDisabled) return;
            if (!STORES.includes(storeName)) return;
            try {
                const db = await this._cacheOpen();
                return await new Promise((resolve) => {
                    try {
                        const tx = db.transaction(storeName, 'readwrite');
                        const store = tx.objectStore(storeName);
                        store.put({ ...value, lastTouched: Date.now() });
                        tx.oncomplete = () => resolve();
                        tx.onabort = () => resolve();
                        tx.onerror = () => resolve();
                    } catch (_) {
                        resolve();
                    }
                });
            } catch (_) { }
        },

        async _cacheDelete(storeName, key) {
            if (this._cacheDisabled) return;
            if (!STORES.includes(storeName)) return;
            try {
                const db = await this._cacheOpen();
                return await new Promise((resolve) => {
                    try {
                        const tx = db.transaction(storeName, 'readwrite');
                        tx.objectStore(storeName).delete(key);
                        tx.oncomplete = () => resolve();
                        tx.onabort = () => resolve();
                        tx.onerror = () => resolve();
                    } catch (_) {
                        resolve();
                    }
                });
            } catch (_) { }
        },

        async _cacheSyncMessages(storeName, putRecords, deleteIds) {
            if (this._cacheDisabled) return;
            if (!MESSAGE_STORES.has(storeName)) return;
            if ((!putRecords || putRecords.length === 0) && (!deleteIds || deleteIds.length === 0)) return;
            try {
                const db = await this._cacheOpen();
                return await new Promise((resolve) => {
                    try {
                        const tx = db.transaction(storeName, 'readwrite');
                        const store = tx.objectStore(storeName);
                        const stamp = Date.now();
                        if (putRecords) {
                            for (const r of putRecords) {
                                if (!r || !r.id) continue;
                                store.put({ ...r, lastTouched: stamp });
                            }
                        }
                        if (deleteIds) {
                            for (const id of deleteIds) {
                                if (!id) continue;
                                store.delete(id);
                            }
                        }
                        tx.oncomplete = () => resolve();
                        tx.onabort = () => resolve();
                        tx.onerror = () => resolve();
                    } catch (_) {
                        resolve();
                    }
                });
            } catch (_) { }
        },

        async _cacheGetMessagesByConv(storeName) {
            const result = new Map();
            if (this._cacheDisabled || !MESSAGE_STORES.has(storeName)) return result;
            try {
                const db = await this._cacheOpen();
                return await new Promise((resolve) => {
                    try {
                        const tx = db.transaction(storeName, 'readonly');
                        const store = tx.objectStore(storeName);
                        const req = store.openCursor();
                        req.onsuccess = (e) => {
                            const cursor = e.target.result;
                            if (!cursor) return;
                            const v = cursor.value;
                            const conv = v && v.conv;
                            if (conv) {
                                let arr = result.get(conv);
                                if (!arr) { arr = []; result.set(conv, arr); }
                                arr.push(v);
                            }
                            cursor.continue();
                        };
                        tx.oncomplete = () => resolve(result);
                        tx.onabort = () => resolve(result);
                        tx.onerror = () => resolve(result);
                    } catch (_) {
                        resolve(result);
                    }
                });
            } catch (_) {
                return result;
            }
        },

        async _cacheDeleteConv(storeName, conv) {
            if (this._cacheDisabled || !MESSAGE_STORES.has(storeName) || !conv) return;
            try {
                const db = await this._cacheOpen();
                return await new Promise((resolve) => {
                    try {
                        const tx = db.transaction(storeName, 'readwrite');
                        const store = tx.objectStore(storeName);
                        const idx = store.index('conv');
                        const req = idx.openCursor(IDBKeyRange.only(conv));
                        req.onsuccess = (e) => {
                            const cursor = e.target.result;
                            if (!cursor) return;
                            cursor.delete();
                            cursor.continue();
                        };
                        tx.oncomplete = () => resolve();
                        tx.onabort = () => resolve();
                        tx.onerror = () => resolve();
                    } catch (_) {
                        resolve();
                    }
                });
            } catch (_) { }
        },

        async _cacheClearStore(storeName) {
            if (this._cacheDisabled) return;
            if (!STORES.includes(storeName)) return;
            try {
                const db = await this._cacheOpen();
                return await new Promise((resolve) => {
                    try {
                        const tx = db.transaction(storeName, 'readwrite');
                        tx.objectStore(storeName).clear();
                        tx.oncomplete = () => resolve();
                        tx.onabort = () => resolve();
                        tx.onerror = () => resolve();
                    } catch (_) {
                        resolve();
                    }
                });
            } catch (_) { }
        },

        // Strip non-serialisable / volatile fields before writing
        _serialiseMessage(m) {
            return {
                id: m.id,
                author: m.author,
                pubkey: m.pubkey,
                content: m.content,
                created_at: m.created_at,
                _originalCreatedAt: m._originalCreatedAt,
                _ms: m._ms,
                _seq: m._seq,
                timestamp: m.timestamp,
                isOwn: m.isOwn,
                isPM: m.isPM,
                isGroup: m.isGroup,
                groupId: m.groupId,
                conversationKey: m.conversationKey,
                conversationPubkey: m.conversationPubkey,
                eventKind: m.eventKind,
                isHistorical: m.isHistorical,
                bitchatMessageId: m.bitchatMessageId,
                nymMessageId: m.nymMessageId,
                deliveryStatus: m.deliveryStatus,
                isEdited: m.isEdited,
                channel: m.channel,
                geohash: m.geohash,
                isFileOffer: m.isFileOffer,
                fileOffer: m.fileOffer,
                isBot: m.isBot
            };
        },

        _hydrateMessage(m) {
            // Convert serialised timestamp back to Date if needed
            if (m.timestamp && !(m.timestamp instanceof Date)) {
                try { m.timestamp = new Date(m.timestamp); } catch (_) { }
            }
            return m;
        },

        async clearPMCache() {
            await this._cacheClearStore('pms');
            if (this._persistedPMIds) this._persistedPMIds.clear();
        },

        // Public: wipe the entire cache. Useful on logout / nuke.
        async resetCache() {
            for (const s of STORES) {
                await this._cacheClearStore(s);
            }
            if (this._persistedChannelIds) this._persistedChannelIds.clear();
            if (this._persistedPMIds) this._persistedPMIds.clear();
        },

        async _trimStore(storeName) {
            const limit = STORE_LIMITS[storeName];
            if (!limit) return;
            const all = await this._cacheGetAll(storeName);
            if (all.length <= limit) return;

            const target = Math.floor(limit * 0.9);
            const evictCount = all.length - target;
            all.sort((a, b) => (a.lastTouched || 0) - (b.lastTouched || 0));
            const toEvict = all.slice(0, evictCount);

            const keyForRecord = (r) => {
                if (storeName === 'profiles') return r.pubkey;
                if (storeName === 'avatars') return r.pubkey;
                if (storeName === 'banners') return r.pubkey;
                if (storeName === 'reactions') return r.messageId;
                return null;
            };

            for (const r of toEvict) {
                const k = keyForRecord(r);
                if (k != null) await this._cacheDelete(storeName, k);
            }
        },

        async _trimAllStores() {
            for (const s of Object.keys(STORE_LIMITS)) {
                try { await this._trimStore(s); } catch (_) { }
            }
        },

        // Schedule a trim run with a long debounce
        _scheduleTrim() {
            if (this._cacheDisabled) return;
            if (this._trimTimer) return;
            this._trimTimer = setTimeout(() => {
                this._trimTimer = null;
                this._trimAllStores().catch(() => { });
            }, 30000);
        },

        _persistDedupSets() {
            if (this._cacheDisabled) return;
            if (this._dedupPersistTimer) clearTimeout(this._dedupPersistTimer);
            this._dedupPersistTimer = setTimeout(() => {
                this._dedupPersistTimer = null;
                if (this.processedPMEventIds && this.processedPMEventIds.size > 0) {
                    this._cachePut('meta', {
                        key: META_PROCESSED_PM_EVENT_IDS,
                        ids: Array.from(this.processedPMEventIds)
                    });
                }
                if (this.deletedEventIds && this.deletedEventIds.size > 0) {
                    this._cachePut('meta', {
                        key: META_DELETED_EVENT_IDS,
                        ids: Array.from(this.deletedEventIds)
                    });
                }
                if (this.nymchatPubkeys && this.nymchatPubkeys.size > 0) {
                    this._cachePut('meta', {
                        key: META_NYMCHAT_PUBKEYS,
                        ids: Array.from(this.nymchatPubkeys)
                    });
                }
                if (this.nymchatVouches && this.nymchatVouches.size > 0) {
                    this._cachePut('meta', {
                        key: META_NYMCHAT_VOUCHES,
                        ids: Array.from(this.nymchatVouches)
                    });
                }
            }, DEDUP_PERSIST_DEBOUNCE_MS);
        },

        async _hydrateDedupSets() {
            try {
                const meta = await this._cacheGetAll('meta');
                for (const m of meta) {
                    if (!m || !m.key || !Array.isArray(m.ids)) continue;
                    if (m.key === META_PROCESSED_PM_EVENT_IDS && this.processedPMEventIds) {
                        for (const id of m.ids) this.processedPMEventIds.add(id);
                    } else if (m.key === META_DELETED_EVENT_IDS && this.deletedEventIds) {
                        for (const id of m.ids) this.deletedEventIds.add(id);
                    } else if (m.key === META_NYMCHAT_PUBKEYS && this.nymchatPubkeys) {
                        for (const id of m.ids) this.nymchatPubkeys.add(id);
                    } else if (m.key === META_NYMCHAT_VOUCHES && this.nymchatVouches) {
                        for (const id of m.ids) this.nymchatVouches.add(id);
                    }
                }
            } catch (_) { }
        },

        // Hydrate in-memory Maps from IndexedDB
        async hydrateFromCache() {
            if (this._cacheDisabled) return;
            const cachePMsAllowed = this.settings && this.settings.cachePMs !== false;
            try {
                const [profiles, channelMsgs, pmMsgs, reactions, avatars, banners] = await Promise.all([
                    this._cacheGetAll('profiles'),
                    this._cacheGetMessagesByConv('channels'),
                    cachePMsAllowed ? this._cacheGetMessagesByConv('pms') : Promise.resolve(new Map()),
                    this._cacheGetAll('reactions'),
                    this._cacheGetAll('avatars'),
                    this._cacheGetAll('banners')
                ]);

                // Profiles
                let profileCount = 0;
                for (const p of profiles) {
                    if (!p || !p.pubkey) continue;
                    if (profileCount++ >= STORE_LIMITS.profiles) break;
                    if (!this.users.has(p.pubkey)) {
                        this.users.set(p.pubkey, p.profile || p);
                    }
                    // Restore the kind 0 source URL into the userAvatars/banners maps
                    // so getAvatarUrl can return it before the blob hydrates.
                    if (p.profile) {
                        if (typeof p.profile.kind0Ts === 'number') {
                            if (!this._kind0Ts) this._kind0Ts = new Map();
                            this._kind0Ts.set(p.pubkey, p.profile.kind0Ts);
                        }
                        if (p.profile.pictureUrl && !this.userAvatars.has(p.pubkey)) {
                            this.userAvatars.set(p.pubkey, p.profile.pictureUrl);
                        }
                        if (p.profile.bannerUrl && !this.userBanners.has(p.pubkey)) {
                            this.userBanners.set(p.pubkey, p.profile.bannerUrl);
                        }
                        if (p.profile.bio && !this.userBios.has(p.pubkey)) {
                            this.userBios.set(p.pubkey, p.profile.bio);
                        }
                        if (p.profile.lnAddress && !this.userLightningAddresses.has(p.pubkey)) {
                            this.userLightningAddresses.set(p.pubkey, p.profile.lnAddress);
                        }
                    }
                }

                // Avatars: rehydrate blobs as object URLs
                for (const a of avatars) {
                    if (!a || !a.pubkey || !a.blob) continue;
                    try {
                        // Skip if the cached blob doesn't match the current source URL
                        const currentSource = this.userAvatars.get(a.pubkey);
                        if (currentSource && a.sourceUrl && currentSource !== a.sourceUrl) {
                            this._cacheDelete('avatars', a.pubkey);
                            continue;
                        }
                        const objectUrl = URL.createObjectURL(a.blob);
                        this.avatarBlobCache.set(a.pubkey, objectUrl);
                    } catch (_) { }
                }

                // Banners: rehydrate blobs as object URLs
                for (const b of banners) {
                    if (!b || !b.pubkey || !b.blob) continue;
                    try {
                        const currentSource = this.userBanners.get(b.pubkey);
                        if (currentSource && b.sourceUrl && currentSource !== b.sourceUrl) {
                            this._cacheDelete('banners', b.pubkey);
                            continue;
                        }
                        const objectUrl = URL.createObjectURL(b.blob);
                        this.bannerBlobCache.set(b.pubkey, objectUrl);
                    } catch (_) { }
                }

                const loadedChannelKeys = [];
                const channelLimit = this.channelMessageLimit || 100;
                const channelPersistedMap = this._persistedSetFor('channels');
                for (const [convKey, records] of channelMsgs.entries()) {
                    if (!convKey || !Array.isArray(records) || records.length === 0) continue;
                    if (!this.messages.has(convKey)) this.messages.set(convKey, []);
                    if (!this.channelMessageIds.has(convKey)) this.channelMessageIds.set(convKey, new Set());
                    const arr = this.messages.get(convKey);
                    const idSet = this.channelMessageIds.get(convKey);
                    let persistedSet = channelPersistedMap.get(convKey);
                    if (!persistedSet) { persistedSet = new Set(); channelPersistedMap.set(convKey, persistedSet); }
                    let added = 0;
                    for (const raw of records) {
                        if (raw && raw.id) persistedSet.add(raw.id);
                        const m = this._hydrateMessage(raw);
                        if (!m || !m.id || idSet.has(m.id)) continue;
                        if (typeof this._insertMessageSorted === 'function') {
                            this._insertMessageSorted(arr, m);
                        } else {
                            arr.push(m);
                        }
                        idSet.add(m.id);
                        if (typeof this._indexMessage === 'function') this._indexMessage(convKey, m);
                        if (typeof this._trackPubkeyMessage === 'function' && m.pubkey) {
                            this._trackPubkeyMessage(m.pubkey, m.id, true);
                        }
                        added++;
                    }
                    if (arr.length > channelLimit) {
                        const drop = arr.length - channelLimit;
                        for (let i = 0; i < drop; i++) {
                            const removed = arr[i];
                            if (removed && removed.id) {
                                idSet.delete(removed.id);
                                if (typeof this._unindexMessage === 'function') this._unindexMessage(removed);
                            }
                        }
                        arr.splice(0, drop);
                    }
                    if (added > 0) loadedChannelKeys.push(convKey);
                }

                for (const key of loadedChannelKeys) {
                    const msgs = this.messages.get(key);
                    if (!msgs || !msgs.length) continue;
                    let lastTs = 0;
                    for (const m of msgs) {
                        if (!m) continue;
                        const gated = !m.isOwn && !this.isFriend(m.pubkey) &&
                            !this.nymchatPubkeys.has(m.pubkey) &&
                            this._isPubkeyGated(m.pubkey);
                        m._spamGated = gated;
                        if (gated) continue;
                        const ts = (m.created_at || 0) * 1000;
                        if (ts > lastTs) lastTs = ts;
                    }
                    if (lastTs > 0) this.channelLastActivity.set(key, lastTs);
                }

                if (cachePMsAllowed) {
                    const pmLimit = this.pmStorageLimit || 1000;
                    const pmPersistedMap = this._persistedSetFor('pms');
                    for (const [convKey, records] of pmMsgs.entries()) {
                        if (!convKey || !Array.isArray(records) || records.length === 0) continue;
                        if (!this.pmMessages.has(convKey)) this.pmMessages.set(convKey, []);
                        const arr = this.pmMessages.get(convKey);
                        const seen = new Set(arr.map(m => m && m.id).filter(Boolean));
                        let persistedSet = pmPersistedMap.get(convKey);
                        if (!persistedSet) { persistedSet = new Set(); pmPersistedMap.set(convKey, persistedSet); }
                        for (const raw of records) {
                            if (raw && raw.id) persistedSet.add(raw.id);
                            const m = this._hydrateMessage(raw);
                            if (!m || !m.id || seen.has(m.id)) continue;
                            if (typeof this._insertMessageSorted === 'function') {
                                this._insertMessageSorted(arr, m);
                            } else {
                                arr.push(m);
                            }
                            seen.add(m.id);
                            if (typeof this._indexMessage === 'function') this._indexMessage(convKey, m);
                        }
                        if (arr.length > pmLimit) {
                            const drop = arr.length - pmLimit;
                            for (let i = 0; i < drop; i++) {
                                const removed = arr[i];
                                if (removed && typeof this._unindexMessage === 'function') {
                                    this._unindexMessage(removed);
                                }
                            }
                            arr.splice(0, drop);
                        }
                    }
                } else {
                    this.clearPMCache().catch(() => { });
                }

                for (const r of reactions) {
                    if (!r || !r.messageId || !Array.isArray(r.entries)) continue;
                    if (this.reactions.has(r.messageId)) continue;
                    const emojiMap = new Map();
                    for (const [emoji, reactors] of r.entries) {
                        if (!Array.isArray(reactors)) continue;
                        emojiMap.set(emoji, new Map(reactors));
                    }
                    if (emojiMap.size > 0) this.reactions.set(r.messageId, emojiMap);
                }

                // PM/group bubbles render keyed by nymMessageId. Migrate any
                // reactions still cached under the event ID so they reappear.
                if (typeof this._migrateReactionKey === 'function') {
                    for (const msgs of this.pmMessages.values()) {
                        if (!Array.isArray(msgs)) continue;
                        for (const m of msgs) {
                            if (m && m.id && m.nymMessageId && m.id !== m.nymMessageId) {
                                this._migrateReactionKey(m.id, m.nymMessageId);
                            }
                        }
                    }
                }

                await this._hydrateDedupSets();

                this._populateSidebarFromHydration();
            } catch (_) {
                // Cache failure is non-fatal — we'll just refetch from relays.
            }

            this._trimAllStores().catch(() => { });
        },

        _onHydrationComplete() {
            try {
                const container = document.getElementById('messagesContainer');
                if (!container) return;
                if (this.inPMMode && this.currentPM) {
                    if (typeof this.loadPMMessages === 'function') {
                        const peer = this.currentPM;
                        container.dataset.lastChannel = '';
                        this.loadPMMessages(peer);
                    }
                    return;
                }
                const storageKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
                if (!storageKey) return;
                const arr = this.messages.get(storageKey);
                if (!arr || arr.length === 0) return;
                if (typeof this.loadChannelMessages === 'function') {
                    container.dataset.lastChannel = '';
                    if (this.channelDOMCache) this.channelDOMCache.delete(storageKey);
                    this.loadChannelMessages(this.currentGeohash ? this.currentGeohash : this.currentChannel);
                }
            } catch (_) { }
        },

        _populateSidebarFromHydration() {
            try {
                if (typeof this.addChannel === 'function') {
                    for (const storageKey of [...this.messages.keys()]) {
                        if (!storageKey) continue;
                        if (storageKey.startsWith('#')) {
                            const geohash = storageKey.slice(1);
                            this.addChannel(geohash, geohash);
                        } else if (storageKey === 'unknown') {
                            this.messages.delete(storageKey);
                        } else {
                            this.addChannel(storageKey, storageKey);
                        }
                    }
                }

                if (typeof this.addPMConversation === 'function') {
                    for (const [convKey, msgs] of this.pmMessages.entries()) {
                        if (!Array.isArray(msgs) || msgs.length === 0) continue;
                        if (msgs.some(m => m && m.isGroup)) continue;
                        const sample = msgs.find(m => m && m.conversationPubkey);
                        if (!sample || !sample.conversationPubkey) continue;
                        const peer = sample.conversationPubkey;
                        if (this.closedPMs && this.closedPMs.has(peer)) continue;
                        const last = msgs[msgs.length - 1];
                        const ts = ((last && last.created_at) || (sample.created_at || 0)) * 1000;
                        const nym = this.users.has(peer)
                            ? this.users.get(peer).nym
                            : `nym#${(peer || '').slice(0, 4)}`;
                        this.addPMConversation(nym, peer, ts || Date.now());
                    }
                }

                if (typeof this.recomputeAllUnreadCounts === 'function') {
                    this.recomputeAllUnreadCounts();
                }

                if (typeof this.sortChannelsByActivity === 'function') {
                    this.sortChannelsByActivity();
                }
            } catch (_) { }
        },

        _ensurePersistState() {
            if (!this._pendingPersists) {
                this._pendingPersists = new Map();
                this._pendingPersistTimer = null;

                if (typeof window !== 'undefined' && !this._persistUnloadHooked) {
                    this._persistUnloadHooked = true;
                    const flush = () => this.flushPendingPersists();
                    // pagehide / beforeunload — desktop + most mobile.
                    window.addEventListener('pagehide', flush);
                    window.addEventListener('beforeunload', flush);
                    // visibilitychange — backgrounded PWAs.
                    document.addEventListener('visibilitychange', () => {
                        if (document.hidden) flush();
                    });
                    window.addEventListener('freeze', flush);
                    window.addEventListener('blur', flush);
                }
            }
        },

        _schedulePersist(category, key, fn) {
            this._ensurePersistState();
            const tkey = `${category}:${key}`;
            this._pendingPersists.set(tkey, fn);
            if (!this._pendingPersistTimer) {
                this._pendingPersistTimer = setTimeout(
                    () => this.flushPendingPersists(),
                    PERSIST_DEBOUNCE_MS
                );
            }
        },

        flushPendingPersists() {
            if (this._pendingPersistTimer) {
                clearTimeout(this._pendingPersistTimer);
                this._pendingPersistTimer = null;
            }
            if (!this._pendingPersists || this._pendingPersists.size === 0) return;
            const fns = Array.from(this._pendingPersists.values());
            this._pendingPersists.clear();
            for (const fn of fns) {
                try { fn(); } catch (_) { }
            }
        },

        _persistedSetFor(storeName) {
            if (storeName === 'channels') {
                if (!this._persistedChannelIds) this._persistedChannelIds = new Map();
                return this._persistedChannelIds;
            }
            if (storeName === 'pms') {
                if (!this._persistedPMIds) this._persistedPMIds = new Map();
                return this._persistedPMIds;
            }
            return null;
        },

        async _syncMessagesToCache(storeName, key, sourceMap, limit) {
            const persistedMap = this._persistedSetFor(storeName);
            if (!persistedMap) return;
            const messages = sourceMap.get(key);
            if (!messages || messages.length === 0) {
                if (persistedMap.has(key)) {
                    await this._cacheDeleteConv(storeName, key);
                    persistedMap.delete(key);
                }
                return;
            }
            const startIdx = Math.max(0, messages.length - limit);
            const liveIds = new Set();
            const toPut = [];
            let persistedSet = persistedMap.get(key);
            if (!persistedSet) {
                persistedSet = new Set();
                persistedMap.set(key, persistedSet);
            }
            for (let i = startIdx; i < messages.length; i++) {
                const m = messages[i];
                if (!m || !m.id) continue;
                liveIds.add(m.id);
                if (!persistedSet.has(m.id) || m._dirty) toPut.push(m);
            }
            const toDelete = [];
            for (const id of persistedSet) {
                if (!liveIds.has(id)) toDelete.push(id);
            }
            if (toPut.length === 0 && toDelete.length === 0) return;
            const records = toPut.map(m => ({ ...this._serialiseMessage(m), conv: key }));
            await this._cacheSyncMessages(storeName, records, toDelete);
            for (const m of toPut) { persistedSet.add(m.id); delete m._dirty; }
            for (const id of toDelete) persistedSet.delete(id);
        },

        persistChannelMessages(key) {
            if (!key || this._cacheDisabled) return;
            this._schedulePersist('ch', key, () => {
                const limit = this.channelMessageLimit || 100;
                this._syncMessagesToCache('channels', key, this.messages, limit).catch(() => { });
            });
        },

        persistPMMessages(key) {
            if (!key || this._cacheDisabled) return;
            if (this.settings && this.settings.cachePMs === false) return;
            this._schedulePersist('pm', key, () => {
                const limit = this.pmStorageLimit || 500;
                this._syncMessagesToCache('pms', key, this.pmMessages, limit).catch(() => { });
            });
        },

        persistProfile(pubkey) {
            if (!pubkey || this._cacheDisabled) return;
            this._schedulePersist('pr', pubkey, () => {
                const profile = this.users.get(pubkey);
                if (!profile) return;
                // Snapshot enriched profile fields alongside the user record so
                // we can rehydrate them without a kind 0 round-trip.
                const enriched = {
                    ...profile,
                    pictureUrl: this.userAvatars && this.userAvatars.get(pubkey) || null,
                    bannerUrl: this.userBanners && this.userBanners.get(pubkey) || null,
                    bio: this.userBios && this.userBios.get(pubkey) || null,
                    lnAddress: this.userLightningAddresses && this.userLightningAddresses.get(pubkey) || null,
                    kind0Ts: this._kind0Ts && this._kind0Ts.get(pubkey) || profile.kind0Ts || null
                };
                this._cachePut('profiles', { pubkey, profile: enriched });
                this._scheduleTrim();
            });
        },

        // Persist an avatar blob keyed by pubkey
        persistAvatarBlob(pubkey, blob, sourceUrl, kind0Ts) {
            if (!pubkey || !blob || this._cacheDisabled) return;
            this._schedulePersist('av', pubkey, () => {
                this._cachePut('avatars', { pubkey, blob, sourceUrl: sourceUrl || null, kind0Ts: kind0Ts || null });
                this._scheduleTrim();
            });
        },

        persistBannerBlob(pubkey, blob, sourceUrl, kind0Ts) {
            if (!pubkey || !blob || this._cacheDisabled) return;
            this._schedulePersist('bn', pubkey, () => {
                this._cachePut('banners', { pubkey, blob, sourceUrl: sourceUrl || null, kind0Ts: kind0Ts || null });
                this._scheduleTrim();
            });
        },

        deleteCachedAvatar(pubkey) {
            if (!pubkey || this._cacheDisabled) return;
            this._cacheDelete('avatars', pubkey);
        },

        deleteCachedBanner(pubkey) {
            if (!pubkey || this._cacheDisabled) return;
            this._cacheDelete('banners', pubkey);
        },

        persistReactions(messageId) {
            if (!messageId || this._cacheDisabled) return;
            this._schedulePersist('rx', messageId, () => {
                const r = this.reactions.get(messageId);
                if (!r || r.size === 0) {
                    this._cacheDelete('reactions', messageId);
                    return;
                }
                const entries = [];
                for (const [emoji, reactorMap] of r.entries()) {
                    entries.push([emoji, Array.from(reactorMap.entries())]);
                }
                this._cachePut('reactions', { messageId, entries });
                this._scheduleTrim();
            });
        },

        persistDedupSets() {
            this._persistDedupSets();
        }
    });
})();
