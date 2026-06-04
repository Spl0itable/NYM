// shop.js - Shop UI: styles, flair, cosmetics

Object.assign(NYM.prototype, {

    // POST an action to the storage worker. Signs a NIP-27235 auth event.
    async _storageApiRequest(action, extra, withAuth = true) {
        const apiHost = this._getApiHost();
        if (!apiHost) throw new Error('Storage is unavailable on this host.');
        const body = Object.assign({ action }, extra || {});
        if (withAuth) {
            if (!this.pubkey) throw new Error('Login required.');
            body.pubkey = this.pubkey;
            body.auth = await this._signBotAuth();
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

    async _storageApiStream(action, extra, withAuth = true) {
        const apiHost = this._getApiHost();
        if (!apiHost) throw new Error('Storage is unavailable on this host.');
        const body = Object.assign({ action }, extra || {});
        if (withAuth) {
            if (!this.pubkey) throw new Error('Login required.');
            body.pubkey = this.pubkey;
            body.auth = await this._signBotAuth();
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
                    gift: !!p.gift
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

    loadCachedShopItems() {
        this._restoreShopRecordFromCache();
        this.applyShopStylesToOwnMessages();
    },

    // Pull the authoritative record from R2 for the current pubkey
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

    // Apply a {owned, active} record (from R2 or cache) to local state
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
                    gift: !!info.gift
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

    // Push the current user's active items to R2 so other clients can read them
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
        try {
            const data = await this._shopApiRequest('shop-status', { pubkeys }, false);
            const statuses = (data && data.statuses) || {};
            Object.entries(statuses).forEach(([pk, st]) => {
                const active = (st && st.active) || {};
                const items = {
                    style: active.style || null,
                    flair: Array.isArray(active.flair) ? active.flair : [],
                    cosmetics: Array.isArray(active.cosmetics) ? active.cosmetics : [],
                    supporter: !!active.supporter
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
            if (c === 'cosmetic-aura-gold') {
                msg.classList.add('cosmetic-aura-gold');
            }
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
            }
        });
    },

    _applyFlairBadgesToMessage(msg, flairIds, supporter) {
        const authorEl = msg.querySelector('.message-author');
        if (!authorEl) return;
        authorEl.querySelectorAll('.flair-badge').forEach(el => el.remove());
        const suffix = authorEl.querySelector('.nym-suffix');
        let anchor = suffix;
        (flairIds || []).forEach(id => {
            const flairItem = this.getShopItemById(id);
            if (!flairItem) return;
            const span = document.createElement('span');
            span.className = `flair-badge ${id}`;
            span.innerHTML = flairItem.icon;
            if (anchor) { anchor.after(span); anchor = span; }
        });
        const existingSupporter = authorEl.querySelector('.supporter-badge');
        if (existingSupporter) existingSupporter.remove();
        if (supporter) {
            const badge = document.createElement('span');
            badge.className = 'supporter-badge';
            badge.innerHTML = '<span class="supporter-badge-icon">\u{1F3C6}</span><span class="supporter-badge-text">Supporter</span>';
            authorEl.insertBefore(badge, authorEl.lastChild);
        }
    },

    applyShopStylesToUserMessages(pubkey, items) {
        if (!pubkey || !items) return;
        const messages = document.querySelectorAll(`.message[data-pubkey="${pubkey}"]`);
        messages.forEach(msg => {
            this._applyShopClassesToMessage(msg, items.style, items.cosmetics, items.supporter);
            this._applyFlairBadgesToMessage(msg, items.flair, items.supporter);
        });
    },

    applyShopStylesToOwnMessages() {
        if (!this.pubkey) return;
        const supporterActive = this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false;
        const cosmetics = Array.from(this.activeCosmetics || []);
        const flairs = Array.from(this.activeFlairs || []);
        document.querySelectorAll(`.message[data-pubkey="${this.pubkey}"]`).forEach(msg => {
            this._applyShopClassesToMessage(msg, this.activeMessageStyle, cosmetics, supporterActive);
            this._applyFlairBadgesToMessage(msg, flairs, supporterActive);
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
            const idx = ['styles', 'flair', 'special', 'inventory'].indexOf(tab) + 1;
            const btn = document.querySelector(`.shop-tab:nth-child(${idx})`);
            if (btn) btn.classList.add('active');
        }

        const shopBody = document.getElementById('shopBody');
        switch (tab) {
            case 'styles': this.renderStylesTab(shopBody); break;
            case 'flair': this.renderFlairTab(shopBody); break;
            case 'special': this.renderSpecialTab(shopBody); break;
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
            <span class="shop-price-amount">Owned</span>
            ${allowGift ? `<button class="shop-buy-btn shop-gift-btn" data-action="promptGiftShopItem" data-item-id="${item.id}">GIFT</button>` : ''}
        </div>`;
    },

    renderStylesTab(container) {
        let html = '<div class="shop-category-title">Message Styles</div>';
        html += '<div class="shop-items">';
        this.shopItems.styles.forEach(item => {
            const isPurchased = this.userPurchases.has(item.id);
            html += `
    <div class="shop-item ${isPurchased ? 'purchased' : ''}">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        <div class="shop-item-preview">
            <span class="${item.preview}">Preview Message</span>
        </div>
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
    <div class="shop-item ${isPurchased ? 'purchased' : ''}">
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

    renderSpecialTab(container) {
        let html = '<div class="shop-category-title">Special Items</div>';
        html += '<div class="shop-items">';
        this.shopItems.special.forEach(item => {
            const isPurchased = this.userPurchases.has(item.id);
            html += `
    <div class="shop-item ${isPurchased ? 'purchased' : ''}">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        ${item.benefits ? `
            <div class="shop-item-preview nm-shop-1">
                ${item.benefits.map(b => `• ${b}`).join('<br>')}
            </div>
        ` : ''}
        ${isPurchased ? this._shopItemOwnedHtml(item, true) : this._shopItemActionsHtml(item, false)}
    </div>
`;
        });
        html += '</div>';
        container.innerHTML = html;
    },

    renderInventoryTab(container) {
        let html = '<div class="shop-category-title">My Items</div>';

        if (this.userPurchases.size === 0) {
            html += '<div class="nm-shop-2">No items purchased yet</div>';
            container.innerHTML = html;
            return;
        }

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

            html += `
    <div class="shop-item purchased">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
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
                html += `<div class="shop-item-preview"><span class="supporter-badge"><span class="supporter-badge-icon">🏆</span><span class="supporter-badge-text">Supporter</span></span></div>`;
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
            ...this.shopItems.special
        ];
        return allItems.find(item => item.id === itemId);
    },

    getUserShopItems(pubkey) {
        if (pubkey === this.pubkey) {
            return {
                style: this.activeMessageStyle,
                flair: Array.from(this.activeFlairs || []),
                supporter: this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false,
                cosmetics: Array.from(this.activeCosmetics || [])
            };
        }
        this._queueShopStatusFetch(pubkey);
        const items = this.otherUsersShopItems && this.otherUsersShopItems.get(pubkey);
        if (!items) return null;
        return {
            style: items.style || null,
            flair: Array.isArray(items.flair) ? items.flair : [],
            supporter: !!items.supporter,
            cosmetics: Array.isArray(items.cosmetics) ? items.cosmetics : []
        };
    },

    getFlairForUser(pubkey) {
        const userItems = this.getUserShopItems(pubkey);
        if (!userItems || !userItems.flair || !userItems.flair.length) return '';
        return userItems.flair.map(id => {
            const flairItem = this.getShopItemById(id);
            return flairItem ? `<span class="flair-badge ${id}">${flairItem.icon}</span>` : '';
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
        if (data.gift) this.displaySystemMessage(`Gift purchase completed: ${name}.`);
        else this.displaySystemMessage(`Purchase completed: ${name}.` + (data.code ? ` Recovery code: ${data.code}` : ''));
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
        if (zapStatus) {
            zapStatus.style.display = 'block';
            zapStatus.className = 'zap-status checking';
            zapStatus.innerHTML = '<span class="loader"></span> Confirming purchase...';
        }

        try {
            const data = await this._claimShopPurchase(inv.invoiceId, inv.receipt);
            this._applyShopClaim(data, item);
            this._removePendingPurchase(inv.invoiceId);
            this._renderShopSuccess(item, data.gift, data.gift ? null : data.code);
        } catch (e) {
            if (zapStatus) {
                zapStatus.className = 'zap-status error';
                zapStatus.textContent = 'Purchase confirmation failed: ' + e.message;
            }
        }
    },

    _renderShopSuccess(item, isGift, code) {
        const zapStatus = document.getElementById('zapStatus');
        if (zapStatus) {
            zapStatus.style.display = 'block';
            zapStatus.className = 'zap-status paid';
            zapStatus.innerHTML = `
<div class="nm-shop-10">✅</div>
<div>${isGift ? 'Gift sent!' : 'Purchase successful!'}</div>
<div class="nm-shop-11">${item ? item.name : ''}</div>
${code ? `
<div class="nm-shop-12">
    <div class="nm-shop-13">⚠️ SAVE YOUR RECOVERY CODE</div>
    <div class="nm-shop-14">Use this code to restore this item on another pubkey:</div>
    <div class="nm-shop-15" data-action="copyTextFromData" data-copy-text="${code}" title="Click to copy">${code}</div>
</div>` : ''}
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
                if (s.sound !== undefined) document.getElementById('soundSelect').value = s.sound;
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

        this.displaySystemMessage(`Settings from ${transfer.fromNym} applied successfully!`);
    },

    rejectSettingsTransfer(eventId) {
        const transfer = this.pendingSettingsTransfers.find(t => t.eventId === eventId);
        this.pendingSettingsTransfers = this.pendingSettingsTransfers.filter(t => t.eventId !== eventId);
        this.renderPendingSettingsTransfers();
        this.dismissTransferEvent(eventId);
        if (transfer) {
            this.displaySystemMessage(`Settings transfer from ${transfer.fromNym} rejected.`);
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
