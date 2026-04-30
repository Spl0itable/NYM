// persistence.js - IndexedDB-backed cache for channel messages, PMs, group chats, user profiles, and reactions.

(function () {
    const DB_NAME = 'nym-cache';
    const DB_VERSION = 1;
    const STORES = ['meta', 'profiles', 'channels', 'pms', 'reactions'];

    const PERSIST_DEBOUNCE_MS = 1500;

    const STORE_LIMITS = {
        profiles: 2000,
        channels: 50,
        pms: 100,
        reactions: 5000
    };

    // Debounce for the dedup-set persistence
    const DEDUP_PERSIST_DEBOUNCE_MS = 5000;

    // Meta store keys.
    const META_PROCESSED_PM_EVENT_IDS = 'processedPMEventIds';
    const META_DELETED_EVENT_IDS = 'deletedEventIds';

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
                    if (!db.objectStoreNames.contains('meta')) db.createObjectStore('meta', { keyPath: 'key' });
                    if (!db.objectStoreNames.contains('profiles')) db.createObjectStore('profiles', { keyPath: 'pubkey' });
                    if (!db.objectStoreNames.contains('channels')) db.createObjectStore('channels', { keyPath: 'key' });
                    if (!db.objectStoreNames.contains('pms')) db.createObjectStore('pms', { keyPath: 'key' });
                    if (!db.objectStoreNames.contains('reactions')) db.createObjectStore('reactions', { keyPath: 'messageId' });
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
        },

        // Public: wipe the entire cache. Useful on logout / nuke.
        async resetCache() {
            for (const s of STORES) {
                await this._cacheClearStore(s);
            }
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
                if (storeName === 'reactions') return r.messageId;
                return r.key; // channels, pms, meta
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
                    }
                }
            } catch (_) { }
        },

        // Hydrate in-memory Maps from IndexedDB
        async hydrateFromCache() {
            if (this._cacheDisabled) return;
            const cachePMsAllowed = this.settings && this.settings.cachePMs !== false;
            try {
                const [profiles, channels, pms, reactions] = await Promise.all([
                    this._cacheGetAll('profiles'),
                    this._cacheGetAll('channels'),
                    cachePMsAllowed ? this._cacheGetAll('pms') : Promise.resolve([]),
                    this._cacheGetAll('reactions')
                ]);

                // Profiles
                let profileCount = 0;
                for (const p of profiles) {
                    if (!p || !p.pubkey) continue;
                    if (profileCount++ >= STORE_LIMITS.profiles) break;
                    if (!this.users.has(p.pubkey)) {
                        this.users.set(p.pubkey, p.profile || p);
                    }
                }

                // Channel messages
                for (const c of channels) {
                    if (!c || !c.key || !Array.isArray(c.messages)) continue;
                    if (this.messages.has(c.key) && this.messages.get(c.key).length > 0) continue;
                    const msgs = c.messages.map(m => this._hydrateMessage(m));
                    this.messages.set(c.key, msgs);
                    if (msgs.length > 0) {
                        const last = msgs[msgs.length - 1];
                        const lastTs = (last.created_at || 0) * 1000;
                        if (lastTs > 0) this.channelLastActivity.set(c.key, lastTs);
                    }
                }

                // PM/group messages
                if (cachePMsAllowed) {
                    for (const p of pms) {
                        if (!p || !p.key || !Array.isArray(p.messages)) continue;
                        if (this.pmMessages.has(p.key) && this.pmMessages.get(p.key).length > 0) continue;
                        const msgs = p.messages.map(m => this._hydrateMessage(m));
                        this.pmMessages.set(p.key, msgs);
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

                await this._hydrateDedupSets();

                this._populateSidebarFromHydration();
            } catch (_) {
                // Cache failure is non-fatal — we'll just refetch from relays.
            }

            this._trimAllStores().catch(() => { });
        },

        _populateSidebarFromHydration() {
            try {
                if (typeof this.addChannel === 'function') {
                    for (const storageKey of this.messages.keys()) {
                        if (!storageKey) continue;
                        if (storageKey.startsWith('#')) {
                            const geohash = storageKey.slice(1);
                            this.addChannel(geohash, geohash);
                        } else {
                            this.addChannel(storageKey, '');
                        }
                    }
                }

                if (typeof this.addPMConversation === 'function') {
                    for (const [convKey, msgs] of this.pmMessages.entries()) {
                        if (!Array.isArray(msgs) || msgs.length === 0) continue;
                        // Skip groups — _loadGroupConversations handles those
                        // via its own metadata store.
                        if (msgs.some(m => m && m.isGroup)) continue;
                        // Find any message that exposes the peer pubkey.
                        const sample = msgs.find(m => m && m.conversationPubkey);
                        if (!sample || !sample.conversationPubkey) continue;
                        const peer = sample.conversationPubkey;
                        const last = msgs[msgs.length - 1];
                        const ts = ((last && last.created_at) || (sample.created_at || 0)) * 1000;
                        const nym = this.users.has(peer)
                            ? this.users.get(peer).nym
                            : `anon#${(peer || '').slice(0, 4)}`;
                        this.addPMConversation(nym, peer, ts || Date.now());
                    }
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
                    window.addEventListener('pagehide', flush);
                    window.addEventListener('beforeunload', flush);
                    document.addEventListener('visibilitychange', () => {
                        if (document.hidden) flush();
                    });
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

        persistChannelMessages(key) {
            if (!key || this._cacheDisabled) return;
            this._schedulePersist('ch', key, () => {
                const messages = this.messages.get(key);
                if (!messages || messages.length === 0) {
                    this._cacheDelete('channels', key);
                    return;
                }
                const limit = this.channelMessageLimit || 100;
                const trimmed = messages.length > limit ? messages.slice(-limit) : messages;
                this._cachePut('channels', {
                    key,
                    messages: trimmed.map(m => this._serialiseMessage(m))
                });
                this._scheduleTrim();
            });
        },

        persistPMMessages(key) {
            if (!key || this._cacheDisabled) return;
            // Honour the opt-out setting: don't write decrypted PM/group
            // content to disk if the user disabled it.
            if (this.settings && this.settings.cachePMs === false) return;
            this._schedulePersist('pm', key, () => {
                const messages = this.pmMessages.get(key);
                if (!messages || messages.length === 0) {
                    this._cacheDelete('pms', key);
                    return;
                }
                const limit = this.pmStorageLimit || 500;
                const trimmed = messages.length > limit ? messages.slice(-limit) : messages;
                this._cachePut('pms', {
                    key,
                    messages: trimmed.map(m => this._serialiseMessage(m))
                });
                this._scheduleTrim();
            });
        },

        persistProfile(pubkey) {
            if (!pubkey || this._cacheDisabled) return;
            this._schedulePersist('pr', pubkey, () => {
                const profile = this.users.get(pubkey);
                if (!profile) return;
                this._cachePut('profiles', { pubkey, profile });
                this._scheduleTrim();
            });
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
