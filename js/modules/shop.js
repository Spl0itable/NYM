// shop.js - Shop UI: styles, flair, cosmetics

Object.assign(NYM.prototype, {

    _apiWsUrl() {
        const host = this._getApiHost();
        return host ? `wss://${host}/api` : null;
    },

    // One persistent, authenticated WebSocket carries every D1 storage op so the
    // client doesn't open an HTTP request (and sign an auth event) per fetch/put.
    _ensureApiSocket() {
        const s = this._apiSock;
        if (s && s.ws && s.ws.readyState === WebSocket.OPEN && s.authed) return Promise.resolve(s);
        if (this._apiSockPromise) return this._apiSockPromise;

        // After a failure, skip the socket (straight to HTTP) for a cooldown so a
        // broken endpoint doesn't add a connect-timeout delay to every call.
        if (this._apiSockFailedUntil && Date.now() < this._apiSockFailedUntil) {
            return Promise.reject(new Error('api socket cooling down'));
        }

        const url = this._apiWsUrl();
        if (!url || !this.pubkey) return Promise.reject(new Error('api socket unavailable'));

        this._apiSockPromise = (async () => {
            const auth = await this._signBotAuth('api-ws', 'WS');
            return await new Promise((resolve, reject) => {
                let ws;
                try { ws = new WebSocket(url); } catch (e) { this._apiSockPromise = null; return reject(e); }
                const sock = { ws, authed: false, pending: new Map(), nextId: 1 };
                let settled = false;
                const fail = (err) => {
                    for (const [, p] of sock.pending) { try { p.reject(err); } catch (_) { } }
                    sock.pending.clear();
                    if (this._apiSock === sock) this._apiSock = null;
                    // Cool down only on connect/auth failures, not a clean post-auth drop.
                    if (!sock.authed) this._apiSockFailedUntil = Date.now() + 30000;
                    if (!settled) { settled = true; this._apiSockPromise = null; reject(err); }
                };
                const timer = setTimeout(() => { try { ws.close(); } catch (_) { } fail(new Error('api socket timeout')); }, 12000);

                ws.onopen = () => {
                    try { ws.send(JSON.stringify(['AUTH', auth])); }
                    catch (e) { clearTimeout(timer); fail(e); }
                };
                ws.onmessage = (event) => {
                    let msg;
                    try { msg = JSON.parse(event.data); } catch (_) { return; }
                    if (!Array.isArray(msg)) return;
                    const t = msg[0];
                    if (t === 'AUTH_OK') {
                        clearTimeout(timer);
                        sock.authed = true;
                        this._apiSock = sock;
                        this._apiSockPromise = null;
                        this._apiSockFailedUntil = 0;
                        settled = true;
                        resolve(sock);
                        return;
                    }
                    if (t === 'AUTH_ERR') {
                        clearTimeout(timer);
                        try { ws.close(); } catch (_) { }
                        fail(new Error(msg[1] || 'Authentication failed'));
                        return;
                    }
                    const p = sock.pending.get(msg[1]);
                    if (!p) return;
                    if (t === 'RES') {
                        sock.pending.delete(msg[1]);
                        const status = msg[2], data = msg[3] || {};
                        if (p.raw) {
                            p.resolve({ status, data });
                        } else if (status >= 400 || (data && data.error)) {
                            try { p.reject(new Error((data && data.error) || `Request failed (${status})`)); } catch (_) { }
                        } else {
                            p.resolve(data);
                        }
                    } else if (t === 'ITEM') {
                        if (p.items) p.items.push(msg[2]);
                    } else if (t === 'END') {
                        sock.pending.delete(msg[1]);
                        const hdrs = msg[3] || {};
                        p.resolve({
                            _wsItems: p.items || [],
                            headers: { get: (n) => { const v = hdrs[String(n).toLowerCase()]; return v === undefined ? null : v; } }
                        });
                    }
                };
                ws.onclose = () => { clearTimeout(timer); fail(new Error('api socket closed')); };
                ws.onerror = () => { clearTimeout(timer); fail(new Error('api socket error')); };
            });
        })();
        return this._apiSockPromise;
    },

    // opts.stream collects ndjson items; opts.raw resolves { status, data }
    // instead of rejecting on an error status (callers that branch on status).
    _apiSocketSend(action, extra, opts) {
        opts = opts || {};
        const sock = this._apiSock;
        if (!sock || !sock.ws || sock.ws.readyState !== WebSocket.OPEN || !sock.authed) {
            return Promise.reject(new Error('api socket not ready'));
        }
        const id = sock.nextId++;
        return new Promise((resolve, reject) => {
            const p = { resolve, reject };
            if (opts.stream) p.items = [];
            if (opts.raw) p.raw = true;
            const timer = setTimeout(() => {
                if (sock.pending.delete(id)) reject(new Error('api request timeout'));
            }, opts.timeout || 45000);
            p.resolve = (v) => { clearTimeout(timer); resolve(v); };
            p.reject = (e) => { clearTimeout(timer); reject(e); };
            sock.pending.set(id, p);
            try { sock.ws.send(JSON.stringify(['REQ', id, action, extra || {}])); }
            catch (e) { sock.pending.delete(id); p.reject(e); }
        });
    },

    // Bot/Ledger money op over the socket (WS-first), falling back to a signed
    // HTTP POST to /api/bot. Returns { status, data } so callers can branch.
    async _botMoneyRequest(action, extra, opts) {
        const apiHost = this._getApiHost();
        if (!apiHost) return { status: 0, data: {} };
        if (this.pubkey) {
            try {
                await this._ensureApiSocket();
                return await this._apiSocketSend(action, extra, { raw: true, timeout: opts && opts.timeout });
            } catch (_) { /* fall back to HTTP */ }
        }
        const auth = await this._signBotAuth(action);
        const body = Object.assign({ action, pubkey: this.pubkey, auth }, extra || {});
        const resp = await fetch(`https://${apiHost}/api/bot`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        const data = await resp.json().catch(() => ({}));
        return { status: resp.status, data: data || {} };
    },

    // Run a storage action over the socket when logged in, falling back to a
    // one-off HTTP POST (signed per request) if the socket is unavailable.
    async _storageApiRequest(action, extra, withAuth = true) {
        const apiHost = this._getApiHost();
        if (!apiHost) throw new Error('Storage is unavailable on this host.');
        if (this.pubkey) {
            try {
                await this._ensureApiSocket();
                return await this._apiSocketSend(action, extra);
            } catch (_) { /* fall back to HTTP */ }
        }
        const body = Object.assign({ action }, extra || {});
        if (withAuth) {
            if (!this.pubkey) throw new Error('Login required.');
            body.pubkey = this.pubkey;
            body.auth = await this._signBotAuth(action, 'storage');
        }
        const resp = await fetch(`https://${apiHost}/api/storage`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        const data = await resp.json().catch(() => ({}));
        if (!resp.ok || (data && data.error)) {
            throw new Error((data && data.error) || `Request failed (${resp.status})`);
        }
        return data || {};
    },

    _shopApiRequest(action, extra, withAuth = true) {
        return this._storageApiRequest(action, extra, withAuth);
    },

    // Returns either a fetch Response (HTTP fallback) or a { _wsItems } object;
    // both are consumed by _readNdjsonStream.
    async _storageApiStream(action, extra, withAuth = true) {
        const apiHost = this._getApiHost();
        if (!apiHost) throw new Error('Storage is unavailable on this host.');
        if (this.pubkey) {
            try {
                await this._ensureApiSocket();
                return await this._apiSocketSend(action, extra, { stream: true });
            } catch (_) { /* fall back to HTTP */ }
        }
        const body = Object.assign({ action }, extra || {});
        if (withAuth) {
            if (!this.pubkey) throw new Error('Login required.');
            body.pubkey = this.pubkey;
            body.auth = await this._signBotAuth(action, 'storage');
        }
        const resp = await fetch(`https://${apiHost}/api/storage`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        const ct = resp.headers.get('Content-Type') || '';
        if (!resp.ok || ct.indexOf('application/x-ndjson') < 0) {
            let msg = `Request failed (${resp.status})`;
            try { const j = await resp.json(); if (j && j.error) msg = j.error; } catch (_) { }
            throw new Error(msg);
        }
        return resp;
    },

    async _readNdjsonStream(resp, onItem) {
        if (resp && resp._wsItems) {
            for (const it of resp._wsItems) { try { onItem(it); } catch (_) { } }
            return;
        }
        if (!resp || !resp.body) return;
        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buf = '';
        const handle = (line) => {
            if (!line) return;
            try { onItem(JSON.parse(line)); } catch (_) { }
        };
        while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            buf += decoder.decode(value, { stream: true });
            let nl;
            while ((nl = buf.indexOf('\n')) >= 0) {
                handle(buf.slice(0, nl));
                buf = buf.slice(nl + 1);
            }
        }
        buf += decoder.decode();
        if (buf) handle(buf);
    },

    // Cache of other users' active items, persisted across sessions
    loadShopActiveCache() {
        try {
            const raw = localStorage.getItem('nym_shop_active_cache');
            if (!raw) return;
            const cache = JSON.parse(raw);
            const now = Date.now();
            const maxAge = 24 * 60 * 60 * 1000;

            for (const [pubkey, entry] of Object.entries(cache)) {
                if (entry && entry.items && (now - entry.ts < maxAge)) {
                    this.otherUsersShopItems.set(pubkey, entry.items);
                    this.shopItemsCache.set(pubkey, {
                        items: entry.items,
                        timestamp: entry.ts,
                        updatedAt: entry.updatedAt || 0
                    });
                }
            }
        } catch (e) { /* ignore */ }
    },

    cacheShopActiveItems(pubkey, items, updatedAt = 0) {
        try {
            const raw = localStorage.getItem('nym_shop_active_cache');
            const cache = raw ? JSON.parse(raw) : {};
            cache[pubkey] = { items, ts: Date.now(), updatedAt };
            localStorage.setItem('nym_shop_active_cache', JSON.stringify(cache));
            this.shopItemsCache.set(pubkey, { items, timestamp: Date.now(), updatedAt });
        } catch (e) { /* ignore */ }
    },

    // Drop the cached active-items record for a user and re-fetch, so a flair
    // or style change shows up before the 10-minute cache would expire.
    invalidateShopCache(pubkey) {
        if (!pubkey || pubkey === this.pubkey || !/^[0-9a-f]{64}$/.test(pubkey)) return;
        if (this.shopItemsCache) this.shopItemsCache.delete(pubkey);
        if (this._shopStatusInFlight) this._shopStatusInFlight.delete(pubkey);
        if (!this._shopStatusForceFresh) this._shopStatusForceFresh = new Set();
        this._shopStatusForceFresh.add(pubkey);
        try {
            const raw = localStorage.getItem('nym_shop_active_cache');
            if (raw) {
                const cache = JSON.parse(raw);
                if (cache[pubkey]) {
                    delete cache[pubkey];
                    localStorage.setItem('nym_shop_active_cache', JSON.stringify(cache));
                }
            }
        } catch (e) { /* ignore */ }
        this._queueShopStatusFetch(pubkey);
    },

    // Persist the current user's own record so the shop renders instantly
    _cacheShopRecord() {
        try {
            const owned = {};
            this.userPurchases.forEach((p, id) => {
                owned[id] = {
                    at: (p.timestamp || 0) * 1000,
                    amountSats: p.amount || 0,
                    code: p.code || null,
                    gift: !!p.gift,
                    edition: p.edition || null,
                    editionMax: p.editionMax || 0
                };
            });
            localStorage.setItem('nym_shop_record', JSON.stringify({
                owned,
                active: {
                    style: this.activeMessageStyle || null,
                    flair: Array.from(this.activeFlairs || []),
                    cosmetics: Array.from(this.activeCosmetics || []),
                    supporter: this.supporterBadgeActive !== false
                },
                ts: Date.now()
            }));
        } catch (e) { /* ignore */ }
    },

    _restoreShopRecordFromCache() {
        try {
            const raw = localStorage.getItem('nym_shop_record');
            if (!raw) return;
            const cache = JSON.parse(raw);
            if (cache && typeof cache === 'object') this._applyOwnShopRecord(cache);
        } catch (e) { /* ignore */ }
    },

    // Pull the authoritative record from D1 for the current pubkey
    async loadShopFromServer() {
        if (!this.pubkey) return;
        try {
            const data = await this._shopApiRequest('shop-get', {});
            this._applyOwnShopRecord(data);
        } catch (e) { /* keep cached state */ }
    },

    applyCachedShopItemsToNewIdentity() {
        if (!this.pubkey) return;
        // Purchases are bound to a pubkey server-side; a new identity owns
        // nothing until its own record loads.
        this.userPurchases.clear();
        this.activeMessageStyle = null;
        this.localActiveStyle = null;
        this.activeFlairs = new Set();
        this.activeCosmetics = new Set();
        this.supporterBadgeActive = true;
        this.loadShopFromServer();
    },

    // Apply a {owned, active} record (from D1 or cache) to local state
    _applyOwnShopRecord(data) {
        if (!data || typeof data !== 'object') return;
        if (data.owned && typeof data.owned === 'object') {
            this.userPurchases.clear();
            Object.entries(data.owned).forEach(([id, info]) => {
                info = info || {};
                this.userPurchases.set(id, {
                    itemId: id,
                    timestamp: Math.floor((info.at || Date.now()) / 1000),
                    amount: info.amountSats || 0,
                    code: info.code || null,
                    gift: !!info.gift,
                    edition: info.edition || null,
                    editionMax: info.editionMax || 0
                });
            });
        }
        if (data.active && typeof data.active === 'object') {
            this.activeMessageStyle = data.active.style || null;
            this.localActiveStyle = this.activeMessageStyle;
            const flairArr = Array.isArray(data.active.flair) ? data.active.flair : [];
            this.activeFlairs = new Set(flairArr.length ? [flairArr[flairArr.length - 1]] : []);
            this.activeCosmetics = new Set(Array.isArray(data.active.cosmetics) ? data.active.cosmetics : []);
            this.supporterBadgeActive = !!data.active.supporter;
        }
        this._cacheShopRecord();
        this.applyShopStylesToOwnMessages();
        const modal = document.getElementById('shopModal');
        if (modal && modal.classList.contains('active') && this.activeShopTab) {
            this.switchShopTab(this.activeShopTab);
        }
    },

    _buildActiveItemsPayload() {
        return {
            style: this.activeMessageStyle || null,
            flair: Array.from(this.activeFlairs || []),
            cosmetics: Array.from(this.activeCosmetics || []),
            supporter: this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false
        };
    },

    // Push the current user's active items to D1 so other clients can read them
    async publishActiveShopItems() {
        this._cacheShopRecord();
        if (!this.pubkey) return;
        try {
            await this._shopApiRequest('shop-set-active', { active: this._buildActiveItemsPayload() });
            this.publishShopUpdate();
        } catch (e) { /* ignore */ }
    },

    // Queue a pubkey for an active-items lookup. Skips anyone with a fresh
    // cache entry so we don't repeatedly hit the worker.
    _queueShopStatusFetch(pubkey) {
        if (!pubkey || pubkey === this.pubkey || !/^[0-9a-f]{64}$/.test(pubkey)) return;
        const cached = this.shopItemsCache.get(pubkey);
        if (cached && (Date.now() - cached.timestamp) < 600000) return;
        if (this._shopStatusInFlight && this._shopStatusInFlight.has(pubkey)) return;
        if (!this._shopStatusQueue) this._shopStatusQueue = new Set();
        this._shopStatusQueue.add(pubkey);
        if (this._shopStatusTimer) return;
        this._shopStatusTimer = setTimeout(() => this._flushShopStatusQueue(), 600);
    },

    async _flushShopStatusQueue() {
        this._shopStatusTimer = null;
        const pubkeys = Array.from(this._shopStatusQueue || []);
        this._shopStatusQueue = new Set();
        if (!pubkeys.length) return;
        if (!this._shopStatusInFlight) this._shopStatusInFlight = new Set();
        pubkeys.forEach(pk => this._shopStatusInFlight.add(pk));
        let fresh = [];
        if (this._shopStatusForceFresh && this._shopStatusForceFresh.size) {
            fresh = pubkeys.filter(pk => this._shopStatusForceFresh.delete(pk));
        }
        try {
            const data = await this._shopApiRequest('shop-status', fresh.length ? { pubkeys, fresh } : { pubkeys }, false);
            const statuses = (data && data.statuses) || {};
            Object.entries(statuses).forEach(([pk, st]) => {
                const active = (st && st.active) || {};
                const items = {
                    style: active.style || null,
                    flair: Array.isArray(active.flair) ? active.flair : [],
                    cosmetics: Array.isArray(active.cosmetics) ? active.cosmetics : [],
                    supporter: !!active.supporter,
                    editions: (active.editions && typeof active.editions === 'object') ? active.editions : {}
                };
                const prev = this.shopItemsCache.get(pk);
                const updatedAt = (st && st.updatedAt) || 0;
                // Only re-render when the user actually changed their items
                if (prev && prev.updatedAt === updatedAt) {
                    this.shopItemsCache.set(pk, { items: prev.items, timestamp: Date.now(), updatedAt });
                    return;
                }
                this.otherUsersShopItems.set(pk, items);
                this.cacheShopActiveItems(pk, items, updatedAt);
                this.applyShopStylesToUserMessages(pk, items);
            });
        } catch (e) { /* ignore */ }
        finally {
            pubkeys.forEach(pk => this._shopStatusInFlight.delete(pk));
        }
    },

    _applyShopClassesToMessage(msg, style, cosmetics, supporter) {
        [...msg.classList].forEach(cls => {
            if (cls.startsWith('style-') || cls.startsWith('cosmetic-') || cls === 'supporter-style') {
                msg.classList.remove(cls);
            }
        });
        if (style) msg.classList.add(style);
        if (supporter) msg.classList.add('supporter-style');
        (cosmetics || []).forEach(c => {
            if (c === 'cosmetic-redacted') {
                const auth = msg.querySelector('.message-author');
                if (auth) auth.classList.add('cosmetic-redacted');
                const contentEl = msg.querySelector('.message-content');
                if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                    setTimeout(() => {
                        contentEl.classList.add('cosmetic-redacted-message');
                        contentEl.textContent = '';
                    }, 10000);
                }
            } else if (c) {
                // Purely visual cosmetics map directly to a message CSS class
                // (cosmetic-aura-gold, cosmetic-aura-neon, cosmetic-aura-rainbow, cosmetic-frost)
                msg.classList.add(c);
            }
        });
    },

    _applyFlairBadgesToMessage(msg, flairIds, supporter, editions) {
        const authorEl = msg.querySelector('.message-author');
        if (!authorEl) return;
        authorEl.querySelectorAll('.flair-badge').forEach(el => el.remove());
        authorEl.classList.remove('has-genesis-flair');
        const suffix = authorEl.querySelector('.nym-suffix');
        let anchor = suffix;
        editions = editions || {};
        (flairIds || []).forEach(id => {
            const flairItem = this.getShopItemById(id);
            if (!flairItem) return;
            const span = document.createElement('span');
            span.className = `flair-badge ${id}`;
            span.innerHTML = this._flairIconHtml(id, editions[id]);
            if (anchor) { anchor.after(span); anchor = span; }
            if (id === 'flair-genesis') authorEl.classList.add('has-genesis-flair');
        });
        const existingSupporter = authorEl.querySelector('.supporter-badge');
        if (existingSupporter) existingSupporter.remove();
        if (supporter) {
            const badge = document.createElement('span');
            badge.className = 'supporter-badge';
            badge.innerHTML = `<span class="supporter-badge-icon">${this.getSupporterTrophyIcon()}</span><span class="supporter-badge-text">Supporter</span>`;
            // Keep the badge inside .author-clickable (before the friend badge)
            // so author rewrites and renders all agree on its placement.
            const clickable = authorEl.querySelector('.author-clickable');
            if (clickable) {
                const friendBadge = clickable.querySelector('.friend-badge');
                if (friendBadge) clickable.insertBefore(badge, friendBadge);
                else clickable.appendChild(badge);
            } else {
                authorEl.insertBefore(badge, authorEl.lastChild);
            }
        }
        // Safeguard: never leave more than one verified/supporter badge behind
        // (a re-render race could otherwise stack two checkmarks).
        this._dedupeAuthorBadges(authorEl);
    },

    // Keep at most one of each singleton badge inside an author element.
    _dedupeAuthorBadges(authorEl) {
        if (!authorEl) return;
        ['.verified-badge', '.supporter-badge', '.friend-badge'].forEach(sel => {
            const found = authorEl.querySelectorAll(sel);
            for (let i = 1; i < found.length; i++) found[i].remove();
        });
    },

    applyShopStylesToUserMessages(pubkey, items) {
        if (!pubkey || !items) return;
        const messages = document.querySelectorAll(`.message[data-pubkey="${pubkey}"]`);
        messages.forEach(msg => {
            this._applyShopClassesToMessage(msg, items.style, items.cosmetics, items.supporter);
            this._applyFlairBadgesToMessage(msg, items.flair, items.supporter, items.editions);
        });
    },

    applyShopStylesToOwnMessages() {
        if (!this.pubkey) return;
        const supporterActive = this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false;
        const cosmetics = Array.from(this.activeCosmetics || []);
        const flairs = Array.from(this.activeFlairs || []);
        const editions = this._ownEditions();
        document.querySelectorAll(`.message[data-pubkey="${this.pubkey}"]`).forEach(msg => {
            this._applyShopClassesToMessage(msg, this.activeMessageStyle, cosmetics, supporterActive);
            this._applyFlairBadgesToMessage(msg, flairs, supporterActive, editions);
        });
    },

    activateCosmetic(itemId) {
        const item = this.getShopItemById(itemId);
        if (!item || item.type !== 'cosmetic') return;
        if (!this.userPurchases.has(itemId)) return;

        if (this.activeCosmetics.has(itemId)) {
            this.activeCosmetics.delete(itemId);
            this.displaySystemMessage(`Deactivated ${item.name}`);
        } else {
            this.activeCosmetics.add(itemId);
            this.displaySystemMessage(`Activated ${item.name}`);
        }
        this.publishActiveShopItems();
        this.applyShopStylesToOwnMessages();

        if (document.getElementById('shopModal').classList.contains('active') &&
            this.activeShopTab === 'inventory') {
            this.renderInventoryTab(document.getElementById('shopBody'));
        }
    },

    activateMessageStyle(styleId) {
        if (!this.userPurchases.has(styleId)) return;
        if (this.activeMessageStyle === styleId) {
            this.activeMessageStyle = null;
            this.localActiveStyle = null;
            this.displaySystemMessage(`Deactivated ${this.getShopItemById(styleId).name}`);
        } else {
            this.activeMessageStyle = styleId;
            this.localActiveStyle = styleId;
            this.displaySystemMessage(`Activated ${this.getShopItemById(styleId).name}`);
        }
        this.publishActiveShopItems();
        this.renderInventoryTab(document.getElementById('shopBody'));
        this.applyShopStylesToOwnMessages();
    },

    activateFlair(flairId) {
        if (!this.userPurchases.has(flairId)) return;
        const item = this.getShopItemById(flairId);
        if (!this.activeFlairs) this.activeFlairs = new Set();
        if (this.activeFlairs.has(flairId)) {
            this.activeFlairs.delete(flairId);
            this.displaySystemMessage(`Deactivated ${item.name}`);
        } else {
            this.activeFlairs.clear();
            this.activeFlairs.add(flairId);
            this.displaySystemMessage(`Activated ${item.name}`);
        }
        this.publishActiveShopItems();
        this.renderInventoryTab(document.getElementById('shopBody'));
        this.applyShopStylesToOwnMessages();
    },

    activateSupporter() {
        if (!this.userPurchases.has('supporter-badge')) return;
        if (this.supporterBadgeActive !== false) {
            this.supporterBadgeActive = false;
            this.displaySystemMessage('Deactivated Nymchat Supporter badge');
        } else {
            this.supporterBadgeActive = true;
            this.displaySystemMessage('Activated Nymchat Supporter badge');
        }
        this.publishActiveShopItems();
        this.renderInventoryTab(document.getElementById('shopBody'));
        this.applyShopStylesToOwnMessages();
    },

    getActiveMessageStyle() {
        return this.activeMessageStyle ? this.getShopItemById(this.activeMessageStyle) : null;
    },

    getActiveFlairs() {
        return Array.from(this.activeFlairs || [])
            .map(id => this.getShopItemById(id))
            .filter(Boolean);
    },

    async openShop() {
        const modal = document.getElementById('shopModal');
        modal.classList.add('active');

        const shopBody = document.getElementById('shopBody');
        shopBody.innerHTML = `
<div class="shop-loading">
    <div class="shop-loading-spinner"></div>
    <div class="shop-loading-text">Loading shop items...</div>
</div>
`;

        // Refresh the authoritative record so transferred/gifted items appear
        this.loadShopFromServer();
        this.switchShopTab('styles');
    },

    closeShop() {
        document.getElementById('shopModal').classList.remove('active');
    },

    switchShopTab(tab, event) {
        this.activeShopTab = tab;

        document.querySelectorAll('.shop-tab').forEach(btn => btn.classList.remove('active'));
        if (event && event.target) {
            event.target.classList.add('active');
        } else {
            const idx = ['styles', 'flair', 'special', 'limited', 'inventory'].indexOf(tab) + 1;
            const btn = document.querySelector(`.shop-tab:nth-child(${idx})`);
            if (btn) btn.classList.add('active');
        }

        const shopBody = document.getElementById('shopBody');
        switch (tab) {
            case 'styles': this.renderStylesTab(shopBody); break;
            case 'flair': this.renderFlairTab(shopBody); break;
            case 'special': this.renderSpecialTab(shopBody); break;
            case 'limited': this.renderLimitedTab(shopBody); break;
            case 'inventory': this.renderInventoryTab(shopBody); break;
        }
    },

    _shopItemActionsHtml(item, isPurchased) {
        if (isPurchased) return '';
        return `
        <div class="shop-item-price">
            <span class="shop-price-amount">⚡ ${item.price} sats</span>
            <button class="shop-buy-btn" data-action="purchaseItem" data-item-id="${item.id}">GET</button>
            <button class="shop-buy-btn shop-gift-btn" data-action="promptGiftShopItem" data-item-id="${item.id}">GIFT</button>
        </div>`;
    },

    // Owned-item footer; keeps GIFT available when allowGift so an owned
    // item can still be purchased as a gift for another user.
    _shopItemOwnedHtml(item, allowGift) {
        return `
        <div class="shop-item-price">
            <span class="shop-price-amount">⚡ ${item.price} sats</span>
            ${allowGift ? `<button class="shop-buy-btn shop-gift-btn" data-action="promptGiftShopItem" data-item-id="${item.id}">GIFT</button>` : ''}
        </div>`;
    },

    // A live sample bubble for a message style
    _shopStyleDemo(item) {
        return `<div class="shop-msg-demo"><div class="message ${item.id}"><div class="message-content"><span>Preview message</span></div></div></div>`;
    },

    renderStylesTab(container) {
        let html = '<div class="shop-category-title">Message Styles</div>';
        html += '<div class="shop-items">';
        this.shopItems.styles.forEach(item => {
            const isPurchased = this.userPurchases.has(item.id);
            html += `
    <div class="shop-item ${isPurchased ? 'purchased' : ''} ${item.tier === 'legendary' ? 'shop-item-legendary' : ''}">
        ${this._legendaryRibbon(item)}
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        ${this._shopStyleDemo(item)}
        ${isPurchased ? this._shopItemOwnedHtml(item, true) : this._shopItemActionsHtml(item, false)}
    </div>
`;
        });
        html += '</div>';
        container.innerHTML = html;
    },

    renderFlairTab(container) {
        let html = '<div class="shop-category-title">Nickname Flair</div>';
        html += '<div class="shop-items">';
        this.shopItems.flair.forEach(item => {
            const isPurchased = this.userPurchases.has(item.id);
            html += `
    <div class="shop-item ${isPurchased ? 'purchased' : ''} ${item.tier === 'legendary' ? 'shop-item-legendary' : ''}">
        ${this._legendaryRibbon(item)}
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        <div class="shop-item-preview">
            <span>Your_Nick <span class="flair-badge ${item.id}">${item.icon}</span></span>
        </div>
        ${isPurchased ? this._shopItemOwnedHtml(item, true) : this._shopItemActionsHtml(item, false)}
    </div>
`;
        });
        html += '</div>';
        container.innerHTML = html;
    },

    // Small "LEGENDARY" ribbon for tier:'legendary' items.
    _legendaryRibbon(item) {
        return item && item.tier === 'legendary' ? '<div class="shop-legendary-ribbon">LEGENDARY</div>' : '';
    },

    // A live sample message bubble showing how a special item looks. It reuses
    // the real cosmetic classes, so it reflects the user's current bubble mode.
    _shopCosmeticDemo(item) {
        const text = 'Preview message';
        if (item.id === 'cosmetic-redacted') {
            return `<div class="shop-msg-demo"><div class="message"><div class="message-content cosmetic-redacted-message">${text}</div></div></div>`;
        }
        if (item.type === 'supporter') {
            const badge = `<span class="supporter-badge"><span class="supporter-badge-icon">${this.getSupporterTrophyIcon()}</span><span class="supporter-badge-text">Supporter</span></span>`;
            return `<div class="shop-item-preview"><span><strong>Your_Nick</strong> ${badge}</span></div><div class="shop-msg-demo"><div class="message supporter-style"><div class="message-content">${text}</div></div></div>`;
        }
        const cls = item.cssClass || '';
        return `<div class="shop-msg-demo"><div class="message ${cls}"><div class="message-content">${text}</div></div></div>`;
    },

    renderSpecialTab(container) {
        let html = '<div class="shop-category-title">Special Items</div>';
        html += '<div class="shop-items">';
        this.shopItems.special.forEach(item => {
            const isPurchased = this.userPurchases.has(item.id);
            const legend = item.tier === 'legendary';
            html += `
    <div class="shop-item ${isPurchased ? 'purchased' : ''} ${legend ? 'shop-item-legendary' : ''}">
        ${this._legendaryRibbon(item)}
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        ${this._shopCosmeticDemo(item)}
        ${isPurchased ? this._shopItemOwnedHtml(item, true) : this._shopItemActionsHtml(item, false)}
    </div>
`;
        });
        html += '</div>';
        container.innerHTML = html;
    },

    // Availability for a limited/dropped item given cached supply.
    // Returns { state, label } where state is one of:
    // available | soon | ended | soldout.
    _shopItemAvailability(item, supply) {
        const now = Date.now();
        if (typeof item.startsAt === 'number' && now < item.startsAt) {
            return { state: 'soon', label: 'Starts ' + new Date(item.startsAt).toLocaleDateString() };
        }
        if (typeof item.endsAt === 'number' && now > item.endsAt) {
            return { state: 'ended', label: 'Drop ended' };
        }
        if (item.maxSupply) {
            const s = supply && supply[item.id];
            if (s && typeof s.remaining === 'number') {
                if (s.remaining <= 0) return { state: 'soldout', label: 'Sold out' };
                return { state: 'available', label: `${s.remaining} / ${item.maxSupply} left` };
            }
            return { state: 'available', label: `Limited · ${item.maxSupply}` };
        }
        return { state: 'available', label: '' };
    },

    // Fetch remaining supply for limited items (public, no auth).
    async fetchShopSupply(itemIds) {
        try {
            const data = await this._shopApiRequest('shop-supply', { itemIds }, false);
            this._shopSupply = Object.assign(this._shopSupply || {}, data.supply || {});
        } catch (e) { /* keep last known */ }
        return this._shopSupply || {};
    },

    _maybeFetchSupply() {
        const ids = (this.shopItems.limited || []).filter(i => i.maxSupply).map(i => i.id);
        if (!ids.length || this._shopSupplyFetching) return;
        if (this._shopSupplyTs && Date.now() - this._shopSupplyTs < 30000) return;
        this._shopSupplyFetching = true;
        this.fetchShopSupply(ids).then(() => {
            this._shopSupplyTs = Date.now();
            this._shopSupplyFetching = false;
            if (this.activeShopTab === 'limited') {
                const body = document.getElementById('shopBody');
                if (body) this.renderLimitedTab(body);
            }
        }).catch(() => { this._shopSupplyFetching = false; });
    },

    _renderLimitedCard(item, supply) {
        const isPurchased = this.userPurchases.has(item.id);
        const avail = this._shopItemAvailability(item, supply);
        const supplyBadge = avail.label
            ? `<div class="shop-supply-badge shop-supply-${avail.state}">${avail.label}</div>` : '';
        let preview = '';
        if (item.type === 'nickname-flair') {
            const sampleEdition = item.id === 'flair-genesis' ? 69 : null;
            preview = `<div class="shop-item-preview"><span><strong>Your_Nick</strong> <span class="flair-badge ${item.id}">${this._flairIconHtml(item.id, sampleEdition)}</span></span></div>`;
        } else if (item.type === 'message-style') {
            preview = this._shopStyleDemo(item);
        }
        let footer;
        if (isPurchased) footer = this._shopItemOwnedHtml(item, false);
        else if (avail.state === 'available') footer = this._shopItemActionsHtml(item, false);
        else footer = `<div class="shop-item-price"><span class="shop-price-amount">${avail.label}</span></div>`;
        return `
    <div class="shop-item ${isPurchased ? 'purchased' : ''} ${item.tier === 'legendary' ? 'shop-item-legendary' : ''}">
        ${this._legendaryRibbon(item)}
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        ${supplyBadge}
        ${preview}
        ${footer}
    </div>
`;
    },

    _renderBundleCard(item) {
        const all = item.bundle || [];
        const CHIP_CAP = 10;
        const shown = all.slice(0, CHIP_CAP);
        let contents = shown.map(id => {
            const ci = this.getShopItemById(id);
            return ci ? `<span class="shop-bundle-chip">${ci.icon}<span>${ci.name}</span></span>` : '';
        }).join('');
        if (all.length > CHIP_CAP) {
            contents += `<span class="shop-bundle-chip shop-bundle-more">+${all.length - CHIP_CAP} more</span>`;
        }
        const sum = (item.bundle || []).reduce((t, id) => {
            const ci = this.getShopItemById(id);
            return t + (ci ? ci.price : 0);
        }, 0);
        const savePct = sum > item.price ? Math.round((1 - item.price / sum) * 100) : 0;
        const save = savePct > 0
            ? `<div class="shop-supply-badge shop-supply-available">Save ${savePct}% · ${sum} sats value</div>` : '';
        return `
    <div class="shop-item ${item.tier === 'legendary' ? 'shop-item-legendary' : ''}">
        ${this._legendaryRibbon(item)}
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        ${save}
        <div class="shop-bundle-contents">${contents}</div>
        ${this._shopItemActionsHtml(item, false)}
    </div>
`;
    },

    renderLimitedTab(container) {
        const supply = this._shopSupply || {};
        let html = '';
        const limited = this.shopItems.limited || [];
        if (limited.length) {
            html += '<div class="shop-category-title">Limited Editions</div>';
            html += '<div class="shop-items">';
            limited.forEach(item => { html += this._renderLimitedCard(item, supply); });
            html += '</div>';
        }
        const bundles = this.shopItems.bundles || [];
        if (bundles.length) {
            html += '<div class="shop-category-title nm-shop-3">Bundles</div>';
            html += '<div class="shop-items">';
            bundles.forEach(item => { html += this._renderBundleCard(item); });
            html += '</div>';
        }
        container.innerHTML = html;
        this._maybeFetchSupply();
    },

    _renderActiveItemsPreview() {
        const supporterActive = this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false;
        const cosmetics = this.activeCosmetics ? Array.from(this.activeCosmetics) : [];
        const flairs = this.getActiveFlairs();
        const hasActive = !!this.activeMessageStyle || supporterActive || cosmetics.length || flairs.length;
        if (!hasActive) return '';

        const classes = ['message', 'self', 'shop-preview-message'];
        if (this.activeMessageStyle) classes.push(this.activeMessageStyle);
        if (supporterActive) classes.push('supporter-style');
        cosmetics.forEach(c => { if (c && c !== 'cosmetic-redacted') classes.push(c); });

        const colorClass = this.getUserColorClass(this.pubkey);
        const authorExtra = cosmetics.includes('cosmetic-redacted') ? ' cosmetic-redacted' : '';
        const nym = this.escapeHtml(this.nym || 'You');
        const suffix = this.escapeHtml(this.getPubkeySuffix(this.pubkey));
        const editions = this._ownEditions();
        const flairHtml = flairs.map(f => `<span class="flair-badge ${f.id}">${this._flairIconHtml(f.id, editions[f.id])}</span>`).join('');
        const supporterBadge = supporterActive
            ? `<span class="supporter-badge"><span class="supporter-badge-icon">${this.getSupporterTrophyIcon()}</span><span class="supporter-badge-text">Supporter</span></span>`
            : '';

        return `
<div class="shop-active-items shop-preview-block">
    <div class="shop-active-items-title">Preview</div>
    <div class="${classes.join(' ')}">
        <span class="message-author self ${colorClass}${authorExtra}"><span class="nym-bracket">&lt;</span>${nym}<span class="nym-suffix">#${suffix}</span>${flairHtml}${supporterBadge}<span class="nym-bracket">&gt;</span></span>
        <span class="message-content ${colorClass}">This is how your messages look.</span>
    </div>
</div>`;
    },

    renderInventoryTab(container) {
        let html = '<div class="shop-category-title">My Items</div>';

        if (this.userPurchases.size === 0) {
            html += '<div class="nm-shop-2">No items purchased yet</div>';
            container.innerHTML = html;
            return;
        }

        html += this._renderActiveItemsPreview();

        const activeStyle = this.getActiveMessageStyle();
        if (activeStyle) {
            html += '<div class="shop-active-items">';
            html += '<div class="shop-active-items-title">Active Message Style</div>';
            html += `<div class="shop-active-item">${activeStyle.name}</div>`;
            html += '</div>';
        }

        const activeFlairs = this.getActiveFlairs();
        if (activeFlairs.length) {
            html += '<div class="shop-active-items">';
            html += '<div class="shop-active-items-title">Active Nickname Flair</div>';
            activeFlairs.forEach(f => {
                html += `<div class="shop-active-item">${f.name} ${f.icon}</div>`;
            });
            html += '</div>';
        }

        if (this.activeCosmetics.size > 0) {
            html += '<div class="shop-active-items">';
            html += '<div class="shop-active-items-title">Active Special Items</div>';
            this.activeCosmetics.forEach(id => {
                const it = this.getShopItemById(id);
                if (it) html += `<div class="shop-active-item">${it.icon} ${it.name}</div>`;
            });
            html += '</div>';
        }

        html += '<div class="shop-category-title nm-shop-3">All Purchased Items</div>';
        html += '<div class="shop-items">';

        this.userPurchases.forEach((purchase, itemId) => {
            const item = this.getShopItemById(itemId);
            if (!item) return;

            const editionNo = purchase.edition
                ? ` <span class="shop-edition-no">#${purchase.edition}${purchase.editionMax ? '/' + purchase.editionMax : ''}</span>` : '';
            html += `
    <div class="shop-item purchased ${item.tier === 'legendary' ? 'shop-item-legendary' : ''}">
        ${this._legendaryRibbon(item)}
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}${editionNo}</div>
        <div class="shop-item-description">${item.description}</div>
        <div class="nm-shop-4">
            Acquired: ${new Date((purchase.timestamp || 0) * 1000).toLocaleDateString()}
        </div>
    `;

            if (item.type === 'message-style') {
                const isActive = this.activeMessageStyle === itemId;
                html += `
<button class="shop-buy-btn nm-shop-5" data-action="activateMessageStyle" data-item-id="${itemId}">
${isActive ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
            } else if (item.type === 'nickname-flair') {
                const isActive = this.activeFlairs && this.activeFlairs.has(itemId);
                html += `
<button class="shop-buy-btn nm-shop-5" data-action="activateFlair" data-item-id="${itemId}">
${isActive ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
            } else if (item.type === 'cosmetic') {
                const isOn = this.activeCosmetics.has(itemId);
                html += `
<button class="shop-buy-btn nm-shop-5" data-action="activateCosmetic" data-item-id="${itemId}">
${isOn ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
            } else if (item.type === 'supporter') {
                const isActive = this.supporterBadgeActive !== false;
                html += `<div class="shop-item-preview"><span class="supporter-badge"><span class="supporter-badge-icon">${this.getSupporterTrophyIcon()}</span><span class="supporter-badge-text">Supporter</span></span></div>`;
                html += `
<button class="shop-buy-btn nm-shop-5" data-action="activateSupporter">
${isActive ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
            }

            if (purchase.code) {
                html += `
<div class="nm-shop-6">Recovery code</div>
<div class="nm-shop-7" data-action="copyTextFromData" data-copy-text="${purchase.code}" title="Click to copy">${purchase.code}</div>`;
            }

            html += `
<button class="shop-buy-btn shop-transfer-btn nm-shop-8" data-action="promptTransferShopItem" data-item-id="${itemId}">
TRANSFER TO PUBKEY
</button>`;

            html += `</div>`;
        });

        html += '</div>';
        container.innerHTML = html;
    },

    getShopItemById(itemId) {
        const allItems = [
            ...this.shopItems.styles,
            ...this.shopItems.flair,
            ...this.shopItems.special,
            ...(this.shopItems.limited || []),
            ...(this.shopItems.bundles || [])
        ];
        return allItems.find(item => item.id === itemId);
    },

    // Inline SVG trophy used for the supporter badge so the rendered flair
    // matches the SVG icon shown in the shop preview (instead of an emoji).
    getSupporterTrophyIcon() {
        const item = this.getShopItemById('supporter-badge');
        if (item && item.icon) return item.icon;
        return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" role="img" aria-label="Trophy"><title>Trophy</title><path d="M7 4h10v6a5 5 0 0 1-10 0V4z"/><path d="M7 6H4.5a2.5 2.5 0 0 0 2.5 2.5"/><path d="M17 6h2.5a2.5 2.5 0 0 1-2.5 2.5"/><path d="M12 15v3"/><path d="M9 21h6"/><path d="M10 18h4l.5 3h-5z"/></svg>';
    },

    // Canonical supporter-badge markup used by every render/rewrite path so
    // the badge never changes shape (or vanishes) when an author is re-rendered.
    _supporterBadgeMarkup() {
        return `<span class="supporter-badge"><span class="supporter-badge-icon">${this.getSupporterTrophyIcon()}</span><span class="supporter-badge-text">Supporter</span></span>`;
    },

    getSupporterBadgeHtml(pubkey) {
        const items = this.getUserShopItems(pubkey);
        return items && items.supporter ? this._supporterBadgeMarkup() : '';
    },

    // Edition numbers for the current user's owned items (id -> number),
    // used to stamp numbered editions (e.g. Genesis) onto their flair.
    _ownEditions() {
        const out = {};
        this.userPurchases.forEach((p, id) => { if (p && p.edition) out[id] = p.edition; });
        return out;
    },

    getUserShopItems(pubkey) {
        if (pubkey === this.pubkey) {
            return {
                style: this.activeMessageStyle,
                flair: Array.from(this.activeFlairs || []),
                supporter: this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false,
                cosmetics: Array.from(this.activeCosmetics || []),
                editions: this._ownEditions()
            };
        }
        this._queueShopStatusFetch(pubkey);
        const items = this.otherUsersShopItems && this.otherUsersShopItems.get(pubkey);
        if (!items) return null;
        return {
            style: items.style || null,
            flair: Array.isArray(items.flair) ? items.flair : [],
            supporter: !!items.supporter,
            cosmetics: Array.isArray(items.cosmetics) ? items.cosmetics : [],
            editions: (items.editions && typeof items.editions === 'object') ? items.editions : {}
        };
    },

    // Flair SVG for a badge, stamping the edition number inside numbered
    // editions (Genesis shows the owner's number at the base of the pyramid).
    _flairIconHtml(id, edition) {
        const item = this.getShopItemById(id);
        if (!item) return '';
        if (id === 'flair-genesis' && edition) {
            const n = parseInt(edition, 10);
            if (!Number.isInteger(n) || n < 0 || n > 1e7) return item.icon;
            const txt = `<text x="12" y="19.4" text-anchor="middle" font-size="7.5" font-weight="700" fill="currentColor" stroke="none">${n}</text>`;
            return item.icon.replace('</svg>', txt + '</svg>');
        }
        return item.icon;
    },

    getFlairForUser(pubkey) {
        const userItems = this.getUserShopItems(pubkey);
        if (!userItems || !userItems.flair || !userItems.flair.length) return '';
        const editions = userItems.editions || {};
        return userItems.flair.map(id => {
            const flairItem = this.getShopItemById(id);
            return flairItem ? `<span class="flair-badge ${id}">${this._flairIconHtml(id, editions[id])}</span>` : '';
        }).join('');
    },

    async purchaseItem(itemId, recipientPubkey = null) {
        const item = this.getShopItemById(itemId);
        if (!item) return;
        await this.generateShopInvoice(itemId, item.price, recipientPubkey);
    },

    async generateShopInvoice(itemId, amount, recipientPubkey = null) {
        const item = this.getShopItemById(itemId);
        if (!item) return;

        this.currentPurchaseContext = { type: 'shop', itemId, item, amount, recipientPubkey };

        const zapModal = document.getElementById('zapModal');
        const recipientInfo = document.getElementById('zapRecipientInfo');
        if (recipientInfo) {
            recipientInfo.innerHTML = `
<div>${recipientPubkey ? 'Gifting' : 'Purchasing'}: <strong>${item.name}</strong></div>
<div class="nm-shop-9">Price: ${amount} sats${recipientPubkey ? ' — gift to ' + recipientPubkey.substring(0, 8) + '...' : ''}</div>
`;
        }

        ['zap-amounts', 'zap-comment'].forEach(cls => {
            const el = document.querySelector('.' + cls);
            if (el) el.style.display = 'none';
        });
        const amountSection = document.getElementById('zapAmountSection');
        if (amountSection) amountSection.style.display = 'none';
        const customAmountInput = document.getElementById('zapCustomAmount');
        if (customAmountInput) customAmountInput.style.display = 'none';

        const sendBtn = document.getElementById('zapSendBtn');
        if (sendBtn) sendBtn.style.display = 'none';

        zapModal.classList.add('active');
        this.generateShopPaymentInvoice();
    },

    async generateShopPaymentInvoice() {
        const ctx = this.currentPurchaseContext;
        if (!ctx || ctx.type !== 'shop') return;

        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }
        this.currentShopInvoice = null;
        this.currentZapInvoice = null;

        document.getElementById('zapAmountSection').style.display = 'none';
        document.getElementById('zapInvoiceSection').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status checking';
        document.getElementById('zapStatus').innerHTML = '<span class="loader"></span> Generating invoice...';

        try {
            const extra = { itemId: ctx.itemId, comment: this._shopPurchaseComment(ctx) };
            if (ctx.recipientPubkey && ctx.recipientPubkey !== this.pubkey) {
                extra.recipientPubkey = ctx.recipientPubkey;
            }
            const zapRequest = await this._buildShopZapRequest(ctx.amount);
            if (zapRequest) extra.zapRequest = zapRequest;
            const data = await this._shopApiRequest('shop-buy-invoice', extra);
            if (!data.pr) throw new Error('Invoice unavailable');

            this.currentShopInvoice = {
                pr: data.pr,
                verify: data.verify || null,
                serverVerify: !!data.serverVerify,
                invoiceId: data.invoiceId,
                itemId: ctx.itemId,
                item: ctx.item,
                isGift: !!extra.recipientPubkey,
                receipt: null
            };
            this.currentZapInvoice = { pr: data.pr };
            this._addPendingPurchase({ kind: 'shop', invoiceId: data.invoiceId, itemId: ctx.itemId, isGift: !!extra.recipientPubkey });
            this.displayZapInvoice({ pr: data.pr });
            // LUD-21: poll the verify URL. Else let the worker confirm via the
            // bot wallet (NWC). Else wait for the NIP-57 receipt.
            if (data.verify) {
                this.checkShopPayment(data.verify);
            } else if (data.serverVerify) {
                this.checkShopPaymentViaServer();
            } else {
                this._listenForShopReceipt();
            }
        } catch (error) {
            document.getElementById('zapStatus').className = 'zap-status error';
            document.getElementById('zapStatus').textContent = `Failed: ${error.message}`;
            setTimeout(() => {
                const inv = document.getElementById('zapInvoiceSection');
                const amt = document.getElementById('zapAmountSection');
                if (inv) inv.style.display = 'none';
                if (amt) amt.style.display = 'block';
            }, 3000);
        }
    },

    checkShopPayment(verifyUrl) {
        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }
        let checkCount = 0;
        const maxChecks = 180;
        this.shopPaymentCheckInterval = setInterval(async () => {
            checkCount++;
            try {
                const response = await this.proxiedJsonFetch(verifyUrl);
                const data = await response.json();
                if (data.settled || data.paid) {
                    clearInterval(this.shopPaymentCheckInterval);
                    this.shopPaymentCheckInterval = null;
                    await this.handleShopPaymentSuccess();
                } else if (checkCount >= maxChecks) {
                    clearInterval(this.shopPaymentCheckInterval);
                    this.shopPaymentCheckInterval = null;
                    const el = document.getElementById('zapStatus');
                    if (el) {
                        el.style.display = 'block';
                        el.className = 'zap-status';
                        el.innerHTML = '⏱️ Payment timeout - please check your wallet';
                    }
                }
            } catch (e) { /* keep polling */ }
        }, 1000);
    },

    // Poll the worker, which confirms the shop payment via the bot wallet (NWC)
    // even when no LUD-21 verify URL or NIP-57 receipt is available.
    checkShopPaymentViaServer() {
        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }
        const invoiceId = this.currentShopInvoice && this.currentShopInvoice.invoiceId;
        if (!invoiceId) return;
        let checkCount = 0;
        const maxChecks = 180;
        this.shopPaymentCheckInterval = setInterval(async () => {
            checkCount++;
            if (!this.currentShopInvoice || this.currentShopInvoice.invoiceId !== invoiceId) {
                clearInterval(this.shopPaymentCheckInterval);
                this.shopPaymentCheckInterval = null;
                return;
            }
            let paid = false;
            try { paid = await this._checkShopInvoicePaid(invoiceId); } catch (e) { }
            if (paid) {
                clearInterval(this.shopPaymentCheckInterval);
                this.shopPaymentCheckInterval = null;
                await this.handleShopPaymentSuccess();
            } else if (checkCount >= maxChecks) {
                clearInterval(this.shopPaymentCheckInterval);
                this.shopPaymentCheckInterval = null;
                const el = document.getElementById('zapStatus');
                if (el) {
                    el.style.display = 'block';
                    el.className = 'zap-status';
                    el.innerHTML = 'Payment not detected yet — if you paid, tap "I\'ve paid" or reopen the shop shortly.';
                }
            }
        }, 2000);
    },

    async _checkShopInvoicePaid(invoiceId) {
        const data = await this._shopApiRequest('shop-check', { invoiceId });
        return !!(data && data.paid);
    },

    async _claimShopPurchase(invoiceId, receipt) {
        const extra = { invoiceId };
        if (receipt) extra.receipt = receipt;
        if (this.nym) extra.gifterNym = this.nym + '#' + this.getPubkeySuffix(this.pubkey);
        let data = null;
        for (let attempt = 0; attempt < 6; attempt++) {
            try {
                data = await this._shopApiRequest('shop-claim', extra);
                break;
            } catch (e) {
                if (/not confirmed/i.test(e.message) && attempt < 5) {
                    await new Promise(r => setTimeout(r, 2000));
                    continue;
                }
                throw e;
            }
        }
        if (!data) throw new Error('Could not confirm purchase');
        return data;
    },

    _applyShopClaim(data, item) {
        if (data.gift) {
            if (data.giftEvent) {
                try { this.sendDMToRelays(['EVENT', data.giftEvent]); } catch (e) { }
            }
        } else {
            if (data.owned && data.active) {
                this._applyOwnShopRecord({ owned: data.owned, active: data.active });
            }
            if (item && item.type === 'cosmetic' && data.itemId) {
                this.activeCosmetics.add(data.itemId);
                this.publishActiveShopItems();
                this.applyShopStylesToOwnMessages();
            }
        }
    },

    // Persisted pending purchases survive a backgrounded/killed PWA so a payment
    // settled while the app was closed is reconciled and finalized on return.
    _loadPendingPurchases() {
        try {
            const raw = localStorage.getItem('nym_pending_purchases');
            const arr = raw ? JSON.parse(raw) : [];
            return Array.isArray(arr) ? arr : [];
        } catch (e) { return []; }
    },

    _savePendingPurchases(arr) {
        try { localStorage.setItem('nym_pending_purchases', JSON.stringify((arr || []).slice(-20))); } catch (e) { }
    },

    _addPendingPurchase(entry) {
        if (!entry || !entry.invoiceId) return;
        const arr = this._loadPendingPurchases().filter(e => e && e.invoiceId !== entry.invoiceId);
        entry.createdAt = Date.now();
        arr.push(entry);
        this._savePendingPurchases(arr);
    },

    _removePendingPurchase(invoiceId) {
        if (!invoiceId) return;
        this._savePendingPurchases(this._loadPendingPurchases().filter(e => e && e.invoiceId !== invoiceId));
    },

    async reconcilePendingPurchases() {
        if (this._reconcilingPurchases) return;
        const pending = this._loadPendingPurchases();
        if (!pending.length) return;
        if (!this.pubkey || !this._getApiHost()) {
            if (!this._reconcileRetryScheduled) {
                this._reconcileRetryScheduled = true;
                setTimeout(() => { this._reconcileRetryScheduled = false; this.reconcilePendingPurchases(); }, 5000);
            }
            return;
        }
        this._reconcilingPurchases = true;
        const ttl = 2 * 60 * 60 * 1000;
        const now = Date.now();
        try {
            for (const entry of pending) {
                if (!entry || !entry.invoiceId) { this._removePendingPurchase(entry && entry.invoiceId); continue; }
                if (now - (entry.createdAt || 0) > ttl) { this._removePendingPurchase(entry.invoiceId); continue; }
                try {
                    if (entry.kind === 'shop') await this._reconcileShopEntry(entry);
                    else if (entry.kind === 'credit') await this._reconcileCreditEntry(entry);
                } catch (e) { /* leave for next foreground */ }
            }
        } finally {
            this._reconcilingPurchases = false;
        }
    },

    async _reconcileShopEntry(entry) {
        if (this.currentShopInvoice && this.currentShopInvoice.invoiceId === entry.invoiceId) return;
        if (!await this._checkShopInvoicePaid(entry.invoiceId)) return;
        const item = this.getShopItemById(entry.itemId);
        const data = await this._claimShopPurchase(entry.invoiceId, null);
        this._removePendingPurchase(entry.invoiceId);
        if (data.alreadyClaimed) return;
        this._applyShopClaim(data, item);
        const name = item ? item.name : 'item';
        if (data.gift) {
            this.displaySystemMessage(`Gift purchase completed: ${name}.`);
        } else {
            let msg = `Purchase completed: ${name}`;
            if (data.edition && data.edition.n) msg += ` #${data.edition.n}/${data.edition.max}`;
            msg += '.';
            if (Array.isArray(data.bundle) && data.bundle.length) msg += ` Unlocked ${data.bundle.length} items.`;
            else if (data.code) msg += ` Recovery code: ${data.code}`;
            this.displaySystemMessage(msg);
        }
    },

    async _reconcileCreditEntry(entry) {
        if (this.currentZapInvoice && this.currentZapInvoice.invoiceId === entry.invoiceId) return;
        if (!await this._checkBotInvoicePaid(entry.invoiceId)) return;
        if (await this._claimBotCredits(entry.invoiceId, entry.recipientNym, null)) {
            this._removePendingPurchase(entry.invoiceId);
        }
    },

    // Human-readable description of a shop purchase, used as the invoice/zap comment
    _shopPurchaseComment(ctx) {
        if (!ctx || !ctx.item) return 'Nymchat shop purchase';
        const item = ctx.item;
        const kind = item.type === 'message-style' ? 'Message style'
            : item.type === 'nickname-flair' ? 'Nickname flair'
            : item.type === 'supporter' ? 'Supporter badge'
            : item.type === 'cosmetic' ? 'Cosmetic'
            : 'Shop item';
        let label = `${kind}: ${item.name}`;
        if (ctx.recipientPubkey && ctx.recipientPubkey !== this.pubkey) label += ' (gift)';
        return label;
    },

    async _buildShopZapRequest(amountSats) {
        try {
            const evt = {
                kind: 9734,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['p', this.verifiedBot.pubkey],
                    ['amount', String(parseInt(amountSats, 10) * 1000)],
                    ['relays', ...this.defaultRelays.slice(0, 5)]
                ],
                content: this._shopPurchaseComment(this.currentPurchaseContext),
                pubkey: this.pubkey
            };
            return await this.signEvent(evt);
        } catch (e) {
            return null;
        }
    },

    // Fallback payment detection when the bot wallet has no LUD-21 verify URL:
    // wait for the NIP-57 zap receipt and match it by bolt11 (handleZapReceipt).
    _listenForShopReceipt() {
        const inv = this.currentShopInvoice;
        if (!inv) return;
        if (this._shopReceiptWait && this._shopReceiptWait.subId) {
            this.sendToRelay(['CLOSE', this._shopReceiptWait.subId]);
            if (this._shopReceiptWait.timer) clearTimeout(this._shopReceiptWait.timer);
        }
        const subId = 'shopreceipt-' + Math.random().toString(36).slice(2, 9);
        const wait = { subId, pr: inv.pr, timer: null };
        this._shopReceiptWait = wait;
        this.sendToRelay(['REQ', subId, {
            kinds: [9735],
            '#p': [this.verifiedBot.pubkey],
            since: Math.floor(Date.now() / 1000) - 60,
            limit: 25
        }]);
        wait.timer = setTimeout(() => {
            if (this._shopReceiptWait === wait) {
                this.sendToRelay(['CLOSE', subId]);
                this._shopReceiptWait = null;
                const el = document.getElementById('zapStatus');
                if (el) {
                    el.style.display = 'block';
                    el.className = 'zap-status';
                    el.innerHTML = 'Payment not detected yet — if you paid, reopen the shop shortly.';
                }
            }
        }, 180000);
    },

    _clearShopReceiptWait() {
        if (this._shopReceiptWait) {
            if (this._shopReceiptWait.subId) this.sendToRelay(['CLOSE', this._shopReceiptWait.subId]);
            if (this._shopReceiptWait.timer) clearTimeout(this._shopReceiptWait.timer);
            this._shopReceiptWait = null;
        }
    },

    async handleShopPaymentSuccess() {
        const inv = this.currentShopInvoice;
        if (!inv) return;
        this.currentShopInvoice = null;
        this.currentPurchaseContext = null;
        this._clearShopReceiptWait();
        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }

        const item = inv.item;
        const zapStatus = document.getElementById('zapStatus');
        const zapInvoiceDisplay = document.getElementById('zapInvoiceDisplay');
        if (zapInvoiceDisplay) zapInvoiceDisplay.style.display = 'none';
        const zapPaidBtn = document.getElementById('zapPaidBtn');
        if (zapPaidBtn) zapPaidBtn.classList.add('nm-hidden');
        if (zapStatus) {
            zapStatus.style.display = 'block';
            zapStatus.className = 'zap-status checking';
            zapStatus.innerHTML = '<span class="loader"></span> Confirming purchase...';
        }

        try {
            const data = await this._claimShopPurchase(inv.invoiceId, inv.receipt);
            this._applyShopClaim(data, item);
            this._removePendingPurchase(inv.invoiceId);
            // A limited purchase changes remaining supply; force a refresh.
            this._shopSupplyTs = 0;
            this._renderShopSuccess(item, data.gift, data.gift ? null : data.code, data);
        } catch (e) {
            if (zapStatus) {
                zapStatus.className = 'zap-status error';
                zapStatus.textContent = 'Purchase confirmation failed: ' + e.message;
            }
        }
    },

    _renderShopSuccess(item, isGift, code, data) {
        const zapStatus = document.getElementById('zapStatus');
        data = data || {};
        const edition = data.edition && data.edition.n
            ? `<div class="nm-shop-11">Edition #${data.edition.n} of ${data.edition.max}</div>` : '';
        // Bundle component recovery codes (only for the buyer, not when gifting).
        const bundleCodes = (!isGift && Array.isArray(data.bundle) && data.bundle.length)
            ? `<div class="nm-shop-12">
    <div class="nm-shop-13">⚠️ SAVE YOUR RECOVERY CODES</div>
    ${data.bundle.map(b => {
                const ci = this.getShopItemById(b.itemId);
                return `<div class="nm-shop-14">${ci ? ci.name : b.itemId}</div>
    <div class="nm-shop-15" data-action="copyTextFromData" data-copy-text="${b.code}" title="Click to copy">${b.code}</div>`;
            }).join('')}
</div>` : '';
        if (zapStatus) {
            zapStatus.style.display = 'block';
            zapStatus.className = 'zap-status paid';
            zapStatus.innerHTML = `
<div class="nm-shop-10">✅</div>
<div>${isGift ? 'Gift sent!' : 'Purchase successful!'}</div>
<div class="nm-shop-11">${item ? item.name : ''}</div>
${edition}
${bundleCodes || (code ? `
<div class="nm-shop-12">
    <div class="nm-shop-13">⚠️ SAVE YOUR RECOVERY CODE</div>
    <div class="nm-shop-14">Use this code to restore this item on another pubkey:</div>
    <div class="nm-shop-15" data-action="copyTextFromData" data-copy-text="${code}" title="Click to copy">${code}</div>
</div>` : '')}
`;
        }
        const modalActions = document.querySelector('#zapModal .modal-actions');
        if (modalActions) {
            modalActions.innerHTML = `<button class="send-btn" data-action="dismissShopSuccess">Close</button>`;
        }
    },

    dismissShopSuccess() {
        if (this._shopSuccessAutoClose) {
            clearTimeout(this._shopSuccessAutoClose);
            this._shopSuccessAutoClose = null;
        }
        this.closeZapModal();
        if (this.activeShopTab) this.switchShopTab(this.activeShopTab);
    },

    promptGiftShopItem(itemId) {
        const item = this.getShopItemById(itemId);
        if (!item) return;

        const modal = document.createElement('div');
        modal.className = 'modal active';
        modal.id = 'giftShopModal';
        modal.innerHTML = `
<div class="modal-content nm-shop-16">
    <button class="modal-close" data-action="removeElementById" data-remove-id="giftShopModal">✕</button>
    <h3 class="nm-shop-17">Gift Item</h3>
    <div class="nm-shop-18">
        <div class="nm-shop-19">
            <span>${item.icon}</span>
            <strong>${item.name}</strong>
            <span class="nm-shop-20">${item.price} sats</span>
        </div>
        <p class="nm-shop-21">
            Enter the recipient's hex pubkey (64 characters). You pay for the item and it lands directly in their inventory.
        </p>
        <input type="text" id="giftPubkeyInput" placeholder="Recipient hex pubkey (64 chars)"
            class="nm-shop-22" />
        <p id="giftError" class="nm-shop-23 nm-hidden"></p>
    </div>
    <div class="nm-shop-24">
        <button class="send-btn nm-flex1" data-action="executeGiftShopItem" data-item-id="${itemId}">Continue</button>
        <button class="send-btn nm-shop-25" data-action="removeElementById" data-remove-id="giftShopModal">Cancel</button>
    </div>
</div>`;
        document.body.appendChild(modal);
        setTimeout(() => document.getElementById('giftPubkeyInput')?.focus(), 100);
    },

    async executeGiftShopItem(itemId) {
        const input = document.getElementById('giftPubkeyInput');
        const errorEl = document.getElementById('giftError');
        if (!input || !errorEl) return;

        const recipientPubkey = input.value.trim().toLowerCase();
        if (!/^[0-9a-f]{64}$/.test(recipientPubkey)) {
            errorEl.textContent = 'Invalid pubkey. Must be 64 hex characters.';
            errorEl.style.display = 'block';
            return;
        }
        if (recipientPubkey === this.pubkey) {
            errorEl.textContent = 'Use GET to buy an item for yourself.';
            errorEl.style.display = 'block';
            return;
        }

        const modal = document.getElementById('giftShopModal');
        if (modal) modal.remove();
        await this.purchaseItem(itemId, recipientPubkey);
    },

    // Redeem a recovery code: claims the item for this pubkey and revokes it
    // from whoever held it before.
    async restorePurchases(recoveryCode) {
        const code = (recoveryCode || '').trim();
        if (!code) {
            this.displaySystemMessage('Enter a recovery code');
            return false;
        }
        try {
            const data = await this._shopApiRequest('shop-redeem', { code });
            this._applyOwnShopRecord(data);
            this.displaySystemMessage('✅ Shop item restored successfully!');
            if (document.getElementById('shopModal').classList.contains('active')) {
                this.switchShopTab(this.activeShopTab || 'inventory');
            }
            return true;
        } catch (e) {
            this.displaySystemMessage('❌ Restore failed: ' + e.message);
            return false;
        }
    },

    promptTransferShopItem(itemId) {
        const item = this.getShopItemById(itemId);
        if (!item) return;

        if (!this.userPurchases.has(itemId)) {
            this.displaySystemMessage('❌ You do not own this item');
            return;
        }

        const modal = document.createElement('div');
        modal.className = 'modal active';
        modal.id = 'transferModal';
        modal.innerHTML = `
<div class="modal-content nm-shop-16">
    <button class="modal-close" data-action="removeElementById" data-remove-id="transferModal">✕</button>
    <h3 class="nm-shop-17">Transfer Item</h3>
    <div class="nm-shop-18">
        <div class="nm-shop-19">
            <span>${item.icon}</span>
            <strong>${item.name}</strong>
        </div>
        <p class="nm-shop-21">
            Enter the recipient's hex pubkey (64 characters). The item will be revoked from your inventory and assigned to theirs.
        </p>
        <input type="text" id="transferPubkeyInput" placeholder="Recipient hex pubkey (64 chars)"
            class="nm-shop-22" />
        <p id="transferError" class="nm-shop-23 nm-hidden"></p>
    </div>
    <div class="nm-shop-24">
        <button class="send-btn nm-flex1" data-action="executeTransferShopItem" data-item-id="${itemId}">Confirm</button>
        <button class="send-btn nm-shop-25" data-action="removeElementById" data-remove-id="transferModal">Cancel</button>
    </div>
</div>`;
        document.body.appendChild(modal);
        setTimeout(() => document.getElementById('transferPubkeyInput')?.focus(), 100);
    },

    async executeTransferShopItem(itemId) {
        const input = document.getElementById('transferPubkeyInput');
        const errorEl = document.getElementById('transferError');
        if (!input || !errorEl) return;

        const recipientPubkey = input.value.trim().toLowerCase();
        if (!/^[0-9a-f]{64}$/.test(recipientPubkey)) {
            errorEl.textContent = 'Invalid pubkey. Must be 64 hex characters.';
            errorEl.style.display = 'block';
            return;
        }
        if (recipientPubkey === this.pubkey) {
            errorEl.textContent = 'Cannot transfer to yourself.';
            errorEl.style.display = 'block';
            return;
        }

        const item = this.getShopItemById(itemId);
        if (!item || !this.userPurchases.has(itemId)) {
            errorEl.textContent = 'Item not found in your inventory.';
            errorEl.style.display = 'block';
            return;
        }

        try {
            const extra = { itemId, toPubkey: recipientPubkey };
            if (this.nym) extra.gifterNym = this.nym + '#' + this.getPubkeySuffix(this.pubkey);
            const data = await this._shopApiRequest('shop-transfer', extra);

            if (data.giftEvent) {
                try { this.sendDMToRelays(['EVENT', data.giftEvent]); } catch (e) { }
            }
            this._applyOwnShopRecord({ owned: data.owned, active: data.active });
            this.publishActiveShopItems();

            const modal = document.getElementById('transferModal');
            if (modal) modal.remove();

            this.displaySystemMessage(`${item.name} transferred to ${recipientPubkey.substring(0, 8)}...`);
            if (this.activeShopTab === 'inventory') {
                this.renderInventoryTab(document.getElementById('shopBody'));
            }
        } catch (error) {
            errorEl.textContent = 'Transfer failed: ' + error.message;
            errorEl.style.display = 'block';
        }
    },

    async executeSettingsTransfer() {
        const input = document.getElementById('settingsTransferPubkeyInput');
        const errorEl = document.getElementById('settingsTransferError');
        if (!input || !errorEl) return;

        const recipientPubkey = input.value.trim().toLowerCase();
        errorEl.style.display = 'none';

        if (!/^[0-9a-f]{64}$/.test(recipientPubkey)) {
            errorEl.textContent = 'Invalid pubkey. Must be 64 hex characters.';
            errorEl.style.display = 'block';
            return;
        }

        if (recipientPubkey === this.pubkey) {
            errorEl.textContent = 'Cannot transfer settings to yourself.';
            errorEl.style.display = 'block';
            return;
        }

        if (!this._canSendGiftWraps()) {
            errorEl.textContent = 'Settings transfer requires a logged-in account.';
            errorEl.style.display = 'block';
            return;
        }

        try {
            const avatarUrl = this.userAvatars.get(this.pubkey) || localStorage.getItem('nym_avatar_url') || '';

            const transferSettings = this._buildSettingsPayload();
            delete transferSettings.closedPMs;
            delete transferSettings.leftGroups;
            delete transferSettings.notificationLastReadTime;
            delete transferSettings.userJoinedChannels;
            delete transferSettings.pinnedChannels;
            delete transferSettings.keypairMode;

            const settingsPayload = {
                fromPubkey: this.pubkey,
                fromNym: this.nym,
                toPubkey: recipientPubkey,
                transferredAt: Math.floor(Date.now() / 1000),
                nickname: this.nym,
                avatarUrl: avatarUrl,
                settings: transferSettings
            };

            const rumor = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['d', `nym-settings-transfer-${this.pubkey}-${recipientPubkey}`],
                    ['title', 'Nymchat Settings Transfer'],
                    ['p', recipientPubkey],
                    ['settings-transfer-to', recipientPubkey]
                ],
                content: JSON.stringify(settingsPayload),
                pubkey: this.pubkey
            };

            await this._sendGiftWrapsAsync([recipientPubkey], rumor, null);

            input.value = '';
            this.displaySystemMessage(`Settings transfer sent to ${recipientPubkey.substring(0, 8)}...!`);
        } catch (error) {
            errorEl.textContent = 'Failed to send settings transfer. Please try again.';
            errorEl.style.display = 'block';
        }
    },

    handleSettingsTransferEvent(event) {
        try {
            if (!event._giftWrapped && !window.NostrTools.verifyEvent(event)) return;

            const transferTo = event.tags.find(t => t[0] === 'settings-transfer-to');
            if (!transferTo || transferTo[1] !== this.pubkey) return;

            const data = JSON.parse(event.content);
            if (!data.fromPubkey || !data.settings) return;

            if (event.pubkey !== data.fromPubkey) return;

            if (this.dismissedTransferEvents.has(event.id)) return;
            if (this.pendingSettingsTransfers.some(t => t.eventId === event.id)) return;

            this.pendingSettingsTransfers.push({
                eventId: event.id,
                fromPubkey: data.fromPubkey,
                fromNym: data.fromNym || data.fromPubkey.substring(0, 8) + '...',
                nickname: data.nickname,
                avatarUrl: data.avatarUrl,
                settings: data.settings,
                transferredAt: data.transferredAt || event.created_at
            });

            this.displaySystemMessage(`Settings received from ${data.fromPubkey.substring(0, 8)}...! Approve from settings modal.`);

            this.renderPendingSettingsTransfers();
        } catch (e) {
            // Silently ignore malformed transfer events
        }
    },

    async acceptSettingsTransfer(eventId) {
        const transfer = this.pendingSettingsTransfers.find(t => t.eventId === eventId);
        if (!transfer) return;

        if (transfer.nickname) {
            this.nym = transfer.nickname;
            localStorage.setItem(`nym_nickname_${this.pubkey}`, transfer.nickname);
            document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
            this.saveToNostrProfile();
        }

        if (transfer.avatarUrl) {
            this.userAvatars.set(this.pubkey, transfer.avatarUrl);
            localStorage.setItem('nym_avatar_url', transfer.avatarUrl);
            this.cacheAvatarImage(this.pubkey, transfer.avatarUrl);
        }

        const s = transfer.settings;
        if (s) {
            if (typeof applyNostrSettings === 'function') {
                try { await applyNostrSettings(s); } catch (_) { }
            }

            if (s.lightningAddress && this.pubkey) {
                this.lightningAddress = s.lightningAddress;
                localStorage.setItem(`nym_lightning_address_${this.pubkey}`, s.lightningAddress);
            }

            this.saveSyncedSettings();
        }

        this.pendingSettingsTransfers = this.pendingSettingsTransfers.filter(t => t.eventId !== eventId);
        this.dismissTransferEvent(eventId);
        this.renderPendingSettingsTransfers();

        this.updateSidebarAvatar();

        if (document.getElementById('settingsModal').classList.contains('active')) {
            const s = transfer.settings;
            if (s) {
                if (s.theme) document.getElementById('themeSelect').value = s.theme;
                if (s.sound !== undefined) document.getElementById('soundSelect').value = ({ icq: 'uhoh', msn: 'msnding' })[s.sound] || s.sound;
                if (s.autoscroll !== undefined) document.getElementById('autoscrollSelect').value = String(s.autoscroll);
                if (s.showTimestamps !== undefined) {
                    document.getElementById('timestampSelect').value = String(s.showTimestamps);
                    const timeFormatGroup = document.getElementById('timeFormatGroup');
                    if (timeFormatGroup) timeFormatGroup.style.display = s.showTimestamps ? 'block' : 'none';
                }
                if (s.timeFormat !== undefined) document.getElementById('timeFormatSelect').value = s.timeFormat;
                if (s.dateFormat !== undefined) {
                    const dfEl = document.getElementById('dateFormatSelect');
                    if (dfEl) dfEl.value = s.dateFormat;
                }
                if (s.sortByProximity !== undefined) {
                    const el = document.getElementById('proximitySelect');
                    if (el) el.value = String(s.sortByProximity);
                }
                if (s.blurOthersImages !== undefined) {
                    const el = document.getElementById('blurImagesSelect');
                    if (el) el.value = String(s.blurOthersImages);
                }
                if (s.lightningAddress) {
                    const el = document.getElementById('nickEditLightningInput');
                    if (el) el.value = s.lightningAddress;
                }
                if (s.dmForwardSecrecyEnabled !== undefined) {
                    const el = document.getElementById('dmForwardSecrecySelect');
                    if (el) el.value = String(s.dmForwardSecrecyEnabled);
                    const ttlGroup = document.getElementById('dmTTLGroup');
                    if (ttlGroup) ttlGroup.style.display = s.dmForwardSecrecyEnabled ? 'block' : 'none';
                }
                if (s.dmTTLSeconds !== undefined) {
                    const el = document.getElementById('dmTTLSelect');
                    if (el) el.value = String(s.dmTTLSeconds);
                }
                if (s.readReceiptsEnabled !== undefined) {
                    const el = document.getElementById('readReceiptsSelect');
                    if (el) el.value = String(s.readReceiptsEnabled);
                }
                if (s.typingIndicatorsEnabled !== undefined) {
                    const el = document.getElementById('typingIndicatorsSelect');
                    if (el) el.value = String(s.typingIndicatorsEnabled);
                }
                if (s.nickStyle) {
                    const el = document.getElementById('nickStyleSelect');
                    if (el) el.value = s.nickStyle;
                }
                if (s.colorMode) {
                    const colorModeGroup = document.getElementById('colorModeGroup');
                    if (colorModeGroup) {
                        colorModeGroup.querySelectorAll('.color-mode-btn').forEach(btn => {
                            btn.classList.toggle('active', btn.dataset.mode === s.colorMode);
                        });
                    }
                }
                if (s.wallpaperType !== undefined) {
                    document.querySelectorAll('.wallpaper-option').forEach(opt => {
                        opt.classList.toggle('selected', opt.dataset.wallpaper === s.wallpaperType);
                    });
                }
                if (s.chatLayout) {
                    document.querySelectorAll('.layout-option').forEach(opt => {
                        opt.classList.toggle('selected', opt.dataset.layout === s.chatLayout);
                    });
                }
            }
        }

        this.displaySystemMessage(`Settings from ${this.dimNymSuffix(transfer.fromNym)} applied successfully!`, 'system', { html: true });
    },

    rejectSettingsTransfer(eventId) {
        const transfer = this.pendingSettingsTransfers.find(t => t.eventId === eventId);
        this.pendingSettingsTransfers = this.pendingSettingsTransfers.filter(t => t.eventId !== eventId);
        this.renderPendingSettingsTransfers();
        this.dismissTransferEvent(eventId);
        if (transfer) {
            this.displaySystemMessage(`Settings transfer from ${this.dimNymSuffix(transfer.fromNym)} rejected.`, 'system', { html: true });
        }
    },

    dismissTransferEvent(eventId) {
        this.dismissedTransferEvents.add(eventId);
        localStorage.setItem('nym_dismissed_transfers', JSON.stringify([...this.dismissedTransferEvents]));
    },

    renderPendingSettingsTransfers() {
        const container = document.getElementById('pendingSettingsTransfers');
        if (!container) return;

        if (this.pendingSettingsTransfers.length === 0) {
            container.innerHTML = '<div class="nm-shop-26">No pending transfers</div>';
            return;
        }

        container.innerHTML = this.pendingSettingsTransfers.map(t => {
            const date = new Date(t.transferredAt * 1000).toLocaleString();
            return `
                <div class="nm-shop-27">
                    <div class="nm-shop-28">
                        <div class="nm-shop-29">${this.escapeHtml(t.fromNym)}</div>
                        <div class="nm-shop-30" title="${this.escapeHtml(t.fromPubkey)}">Verified sender key: ${this.escapeHtml(String(t.fromPubkey).slice(0, 16))}…${this.escapeHtml(String(t.fromPubkey).slice(-8))}</div>
                        <div class="nm-shop-30">${date}</div>
                        <div class="nm-shop-31">Includes: ${t.nickname ? 'nickname' : ''}${t.avatarUrl ? ', avatar' : ''}${t.settings ? ', preferences' : ''}</div>
                    </div>
                    <div class="nm-shop-32">
                        <button class="icon-btn nm-shop-33" data-action="acceptSettingsTransfer" data-event-id="${t.eventId}">Accept</button>
                        <button class="icon-btn nm-shop-34" data-action="rejectSettingsTransfer" data-event-id="${t.eventId}">Reject</button>
                    </div>
                </div>`;
        }).join('');
    },

});
