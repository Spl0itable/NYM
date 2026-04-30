// shop.js - Shop UI: cosmetics, flair, special items, purchases, transfers, recovery codes

Object.assign(NYM.prototype, {

    // Cache "active items"
    loadShopActiveCache() {
        try {
            const raw = localStorage.getItem('nym_shop_active_cache');
            if (!raw) return;
            const cache = JSON.parse(raw);
            const now = Date.now();
            const maxAge = 24 * 60 * 60 * 1000; // 24 hours

            for (const [pubkey, entry] of Object.entries(cache)) {
                if (entry && entry.items && (now - entry.ts < maxAge)) {
                    this.otherUsersShopItems.set(pubkey, entry.items);
                    // Also store in memory cache with timestamp
                    this.shopItemsCache.set(pubkey, {
                        items: entry.items,
                        timestamp: entry.ts,
                        eventCreatedAt: entry.eventCreatedAt || 0
                    });
                }
            }
        } catch (e) { /* ignore */ }
    },

    cacheShopActiveItems(pubkey, items, eventCreatedAt = 0) {
        try {
            const raw = localStorage.getItem('nym_shop_active_cache');
            const cache = raw ? JSON.parse(raw) : {};
            cache[pubkey] = {
                items,
                ts: Date.now(),
                eventCreatedAt: eventCreatedAt
            };
            localStorage.setItem('nym_shop_active_cache', JSON.stringify(cache));

            // Also update memory cache
            this.shopItemsCache.set(pubkey, {
                items: items,
                timestamp: Date.now(),
                eventCreatedAt: eventCreatedAt
            });
        } catch (e) { /* ignore */ }
    },

    // Build current user's active items object used for broadcast
    _buildActiveItemsPayload() {
        return {
            style: this.activeMessageStyle || null,
            flair: this.activeFlair || null,
            supporter: this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false,
            cosmetics: Array.from(this.activeCosmetics || [])
        };
    },

    // Publish current user's active shop items
    async publishActiveShopItems() {
        if (!this.pubkey) return;

        const payload = this._buildActiveItemsPayload();

        // Cache locally for immediate access
        this.localActiveStyle = this.activeMessageStyle;
        this.localActiveFlair = this.activeFlair;
        localStorage.setItem('nym_active_style', this.activeMessageStyle || '');
        localStorage.setItem('nym_active_flair', this.activeFlair || '');

        const evt = {
            kind: 30078,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['d', 'nym-shop-active'],
                ['title', 'Nymchat Shop Active Items']
            ],
            content: JSON.stringify(payload),
            pubkey: this.pubkey
        };

        try {
            const signed = await this.signEvent(evt);
            if (signed) this.sendToRelay(['EVENT', signed]);
        } catch (_) { }
    },

    loadCachedShopItems() {

        if (!this.pubkey) {
            return;
        }

        // Try to load from localStorage cache first
        const cachedStyle = localStorage.getItem('nym_active_style');
        const cachedFlair = localStorage.getItem('nym_active_flair');


        if (cachedStyle && cachedStyle !== '') {
            this.activeMessageStyle = cachedStyle;
            this.localActiveStyle = cachedStyle;
        }

        if (cachedFlair && cachedFlair !== '') {
            this.activeFlair = cachedFlair;
            this.localActiveFlair = cachedFlair;
        }

        // Restore cached purchases so items show as "purchased" in the shop
        this._restorePurchasesFromCache();

        // Apply to any existing messages immediately
        this.applyShopStylesToOwnMessages();
    },

    _cachePurchases() {
        try {
            const data = Array.from(this.userPurchases.entries());
            const cosmeticsArr = Array.from(this.activeCosmetics || []);
            localStorage.setItem('nym_purchases_cache', JSON.stringify({
                purchases: data,
                activeCosmetics: cosmeticsArr,
                activeStyle: this.activeMessageStyle || null,
                activeFlair: this.activeFlair || null,
                ts: Date.now()
            }));
        } catch (e) { /* ignore */ }
    },

    _restorePurchasesFromCache() {
        try {
            const raw = localStorage.getItem('nym_purchases_cache');
            if (!raw) return;
            const cache = JSON.parse(raw);
            if (!cache || !cache.purchases) return;

            // Only restore if userPurchases is currently empty (avoid overwriting Nostr data)
            if (this.userPurchases.size === 0) {
                cache.purchases.forEach(([id, purchase]) => {
                    this.userPurchases.set(id, purchase);
                });
                if (cache.activeCosmetics) {
                    this.activeCosmetics = new Set(cache.activeCosmetics);
                }
                // Restore flair and style from cache if not already set
                if (cache.activeFlair && !this.activeFlair) {
                    this.activeFlair = cache.activeFlair;
                    this.localActiveFlair = cache.activeFlair;
                    localStorage.setItem('nym_active_flair', cache.activeFlair);
                }
                if (cache.activeStyle && !this.activeMessageStyle) {
                    this.activeMessageStyle = cache.activeStyle;
                    this.localActiveStyle = cache.activeStyle;
                    localStorage.setItem('nym_active_style', cache.activeStyle);
                }
            }
        } catch (e) { /* ignore */ }
    },

    applyCachedShopItemsToNewIdentity() {
        if (!this.pubkey) return;

        // Restore cached purchases so items show as "purchased" in the shop
        this._restorePurchasesFromCache();

        // Load cached active style/flair from localStorage
        const cachedStyle = localStorage.getItem('nym_active_style');
        const cachedFlair = localStorage.getItem('nym_active_flair');

        if (cachedStyle && cachedStyle !== '') {
            this.activeMessageStyle = cachedStyle;
            this.localActiveStyle = cachedStyle;
        }
        if (cachedFlair && cachedFlair !== '') {
            this.activeFlair = cachedFlair;
            this.localActiveFlair = cachedFlair;
        }

        // If there are any active items or purchases, publish them for the new pubkey
        if (this.activeMessageStyle || this.activeFlair || (this.activeCosmetics && this.activeCosmetics.size > 0) || this.userPurchases.size > 0) {
            // Also cache for the new pubkey so others see it immediately
            this.cacheShopActiveItems(this.pubkey, {
                style: this.activeMessageStyle,
                flair: this.activeFlair,
                supporter: this.userPurchases.has('supporter-badge'),
                cosmetics: Array.from(this.activeCosmetics || [])
            }, Math.floor(Date.now() / 1000));

            // Save purchases to Nostr for the new keypair
            this.savePurchaseToNostr();

            // Broadcast active items for the new pubkey so other users see the styling
            this.publishActiveShopItems();

            // Apply to any messages already displayed
            this.applyShopStylesToOwnMessages();
        }
    },

    applyShopStylesToOwnMessages() {
        if (!this.pubkey) return;

        const ownMessages = document.querySelectorAll(`.message[data-pubkey="${this.pubkey}"]`);

        ownMessages.forEach(msg => {
            // Remove previous styling classes
            [...msg.classList].forEach(cls => {
                if (cls.startsWith('style-') || cls.startsWith('cosmetic-') || cls === 'supporter-style') {
                    msg.classList.remove(cls);
                }
            });

            // Add active message style
            if (this.activeMessageStyle) {
                msg.classList.add(this.activeMessageStyle);
            }

            // Add supporter badge if owned and active
            const supporterActive = this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false;
            if (supporterActive) {
                msg.classList.add('supporter-style');
            }

            // Add active cosmetics
            if (this.activeCosmetics && this.activeCosmetics.size > 0) {
                this.activeCosmetics.forEach(c => {
                    if (c === 'cosmetic-aura-gold') {
                        msg.classList.add('cosmetic-aura-gold');
                    }
                    if (c === 'cosmetic-redacted') {
                        const auth = msg.querySelector('.message-author');
                        if (auth) auth.classList.add('cosmetic-redacted');

                        // Apply redacted effect to message content after 10 seconds
                        const contentEl = msg.querySelector('.message-content');
                        if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                            setTimeout(() => {
                                contentEl.classList.add('cosmetic-redacted-message');
                                contentEl.textContent = '';
                            }, 10000);
                        }
                    }
                });
            }

            // Update flair badge in author element
            const authorEl = msg.querySelector('.message-author');
            if (authorEl) {
                const existingFlair = authorEl.querySelector('.flair-badge');
                if (existingFlair) existingFlair.remove();
                if (this.activeFlair) {
                    const flairItem = this.getShopItemById(this.activeFlair);
                    if (flairItem) {
                        const flairSpan = document.createElement('span');
                        flairSpan.className = `flair-badge ${this.activeFlair}`;
                        flairSpan.innerHTML = flairItem.icon;
                        const suffix = authorEl.querySelector('.nym-suffix');
                        if (suffix) {
                            suffix.after(flairSpan);
                        }
                    }
                }

                // Update supporter badge
                const existingSupporter = authorEl.querySelector('.supporter-badge');
                if (existingSupporter) existingSupporter.remove();
                if (supporterActive) {
                    const badge = document.createElement('span');
                    badge.className = 'supporter-badge';
                    badge.innerHTML = '<span class="supporter-badge-icon">\u{1F3C6}</span><span class="supporter-badge-text">Supporter</span>';
                    authorEl.insertBefore(badge, authorEl.lastChild);
                }
            }
        });

    },

    activateCosmetic(itemId) {
        // ensure item exists and is cosmetic
        const item = this.getShopItemById(itemId);
        if (!item || item.type !== 'cosmetic') return;

        if (this.activeCosmetics.has(itemId)) {
            this.activeCosmetics.delete(itemId);
            this.displaySystemMessage(`❎ Deactivated ${item.name}`);
        } else {
            this.activeCosmetics.add(itemId);
            this.displaySystemMessage(`🟡 Activated ${item.name}`);
        }
        // Save & broadcast
        this.savePurchaseToNostr();
        this.publishActiveShopItems();

        // Apply to own messages immediately
        this.applyShopStylesToOwnMessages();

        // Refresh inventory tab if open
        if (document.getElementById('shopModal').classList.contains('active') &&
            this.activeShopTab === 'inventory') {
            this.renderInventoryTab(document.getElementById('shopBody'));
        }
    },

    async openShop() {
        const modal = document.getElementById('shopModal');
        modal.classList.add('active');

        // Show loading state
        const shopBody = document.getElementById('shopBody');
        shopBody.innerHTML = `
<div class="shop-loading">
    <div class="shop-loading-spinner"></div>
    <div class="shop-loading-text">Loading shop items...</div>
</div>
`;

        // Display default tab
        this.switchShopTab('styles');
    },

    closeShop() {
        const modal = document.getElementById('shopModal');
        modal.classList.remove('active');
    },

    switchShopTab(tab, event) {
        this.activeShopTab = tab;

        // Update tab buttons
        document.querySelectorAll('.shop-tab').forEach(btn => {
            btn.classList.remove('active');
        });
        if (event && event.target) {
            event.target.classList.add('active');
        } else {
            // Fallback if event not provided
            document.querySelector(`.shop-tab:nth-child(${['styles', 'flair', 'special', 'inventory'].indexOf(tab) + 1})`).classList.add('active');
        }

        // Update content
        const shopBody = document.getElementById('shopBody');

        switch (tab) {
            case 'styles':
                this.renderStylesTab(shopBody);
                break;
            case 'flair':
                this.renderFlairTab(shopBody);
                break;
            case 'special':
                this.renderSpecialTab(shopBody);
                break;
            case 'inventory':
                this.renderInventoryTab(shopBody);
                break;
        }
    },

    renderStylesTab(container) {
        let html = '<div class="shop-category-title">Message Styles</div>';
        html += '<div class="shop-items">';

        this.shopItems.styles.forEach(item => {
            const isPurchased = this.userPurchases.has(item.id);
            html += `
    <div class="shop-item ${isPurchased ? 'purchased' : ''}" onclick="${!isPurchased ? `nym.purchaseItem('${item.id}')` : ''}">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        <div class="shop-item-preview">
            <span class="${item.preview}">Preview Message</span>
        </div>
        <div class="shop-item-price">
            <span class="shop-price-amount">⚡ ${item.price} sats</span>
            ${!isPurchased ? '<button class="shop-buy-btn">GET</button>' : ''}
        </div>
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
    <div class="shop-item ${isPurchased ? 'purchased' : ''}" onclick="${!isPurchased ? `nym.purchaseItem('${item.id}')` : ''}">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        <div class="shop-item-preview">
            <span>Your_Nick <span class="flair-badge ${item.id.replace('flair-', 'flair-')}">${item.icon}</span></span>
        </div>
        <div class="shop-item-price">
            <span class="shop-price-amount">⚡ ${item.price} sats</span>
            ${!isPurchased ? '<button class="shop-buy-btn">GET</button>' : ''}
        </div>
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
    <div class="shop-item ${isPurchased ? 'purchased' : ''}" onclick="${!isPurchased ? `nym.purchaseItem('${item.id}')` : ''}">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        ${item.benefits ? `
            <div class="shop-item-preview" style="font-size: 11px; text-align: left;">
                ${item.benefits.map(b => `• ${b}`).join('<br>')}
            </div>
        ` : ''}
        <div class="shop-item-price">
            <span class="shop-price-amount">⚡ ${item.price} sats</span>
            ${!isPurchased ? '<button class="shop-buy-btn">GET</button>' : ''}
        </div>
    </div>
`;
        });

        html += '</div>';
        container.innerHTML = html;
    },

    renderInventoryTab(container) {
        let html = '<div class="shop-category-title">My Items</div>';

        if (this.userPurchases.size === 0) {
            html += '<div style="text-align: center; padding: 40px; color: var(--text-dim);">No items purchased yet</div>';
        } else {
            // Active message style
            const activeStyle = this.getActiveMessageStyle();
            if (activeStyle) {
                html += '<div class="shop-active-items">';
                html += '<div class="shop-active-items-title">Active Message Style</div>';
                html += `<div class="shop-active-item">${activeStyle.name}</div>`;
                html += '</div>';
            }

            // Active flair
            const activeFlair = this.getActiveFlair();
            if (activeFlair) {
                html += '<div class="shop-active-items">';
                html += '<div class="shop-active-items-title">Active Nickname Flair</div>';
                html += `<div class="shop-active-item">${activeFlair.name} ${activeFlair.icon}</div>`;
                html += '</div>';
            }

            // Active special items
            if (this.activeCosmetics.size > 0) {
                html += '<div class="shop-active-items">';
                html += '<div class="shop-active-items-title">Active Special Items</div>';
                this.activeCosmetics.forEach(id => {
                    const it = this.getShopItemById(id);
                    if (it) html += `<div class="shop-active-item">${it.icon} ${it.name}</div>`;
                });
                html += '</div>';
            }

            // All purchased items with activate buttons
            html += '<div class="shop-category-title" style="margin-top: 20px;">All Purchased Items</div>';
            html += '<div class="shop-items">';

            this.userPurchases.forEach((purchase, itemId) => {
                const item = this.getShopItemById(itemId);
                if (!item) return;

                html += `
    <div class="shop-item purchased">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        <div style="font-size: 10px; color: var(--text-dim); margin-top: 10px;">
            Purchased: ${new Date(purchase.timestamp * 1000).toLocaleDateString()}
        </div>
    `;

                if (item.type === 'message-style') {
                    const isActive = this.activeMessageStyle === itemId;
                    html += `
<button class="shop-buy-btn" onclick="nym.activateMessageStyle('${itemId}')" style="margin-top: 10px; width: 100%;">
${isActive ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
                } else if (item.type === 'nickname-flair') {
                    const isActive = this.activeFlair === itemId;
                    html += `
<button class="shop-buy-btn" onclick="nym.activateFlair('${itemId}')" style="margin-top: 10px; width: 100%;">
${isActive ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
                } else if (item.type === 'cosmetic') {
                    const isOn = this.activeCosmetics.has(itemId);
                    html += `
<button class="shop-buy-btn" onclick="nym.activateCosmetic('${itemId}')" style="margin-top: 10px; width: 100%;">
${isOn ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
                } else if (item.type === 'supporter') {
                    const isActive = this.supporterBadgeActive !== false;
                    html += `<div class="shop-item-preview"><span class="supporter-badge"><span class="supporter-badge-icon">🏆</span><span class="supporter-badge-text">Supporter</span></span></div>`;
                    html += `
<button class="shop-buy-btn" onclick="nym.activateSupporter()" style="margin-top: 10px; width: 100%;">
${isActive ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
                }

                // Transfer button for all purchased items
                html += `
<button class="shop-buy-btn shop-transfer-btn" onclick="nym.promptTransferShopItem('${itemId}')" style="margin-top: 8px; width: 100%; background: linear-gradient(135deg, rgba(0, 255, 170, 0.12), rgba(0, 255, 170, 0.05)); border-color: rgba(0, 255, 170, 0.3); color: var(--text-bright);">
TRANSFER TO PUBKEY
</button>`;

                html += `</div>`;
            });

            html += '</div>';
        }

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

    async purchaseItem(itemId) {
        const item = this.getShopItemById(itemId);
        if (!item) return;

        // Generate Lightning invoice
        await this.generateShopInvoice(itemId, item.price);
    },

    async generateShopInvoice(itemId, amount) {
        const item = this.getShopItemById(itemId);

        // Store the purchase context
        this.currentPurchaseContext = {
            type: 'shop',
            itemId: itemId,
            item: item,
            amount: amount
        };

        // Create a zap modal for payment
        const zapModal = document.getElementById('zapModal');

        // Update zap modal for shop purchase
        const recipientInfo = document.getElementById('zapRecipientInfo');
        if (recipientInfo) {
            recipientInfo.innerHTML = `
<div>Purchasing: <strong>${item.name}</strong></div>
<div style="font-size: 12px; margin-top: 5px; color: var(--warning);">Price: ${amount} sats</div>
`;
        }

        // Hide preset amounts for shop purchases
        const zapAmountsContainer = document.querySelector('.zap-amounts');
        if (zapAmountsContainer) {
            zapAmountsContainer.style.display = 'none';
        }

        const customFormlabel = document.getElementById('zapAmountSection');
        if (customFormlabel) {
            customFormlabel.style.display = 'none';
        }

        // Set and lock the custom amount
        const customAmountInput = document.getElementById('zapCustomAmount');
        if (customAmountInput) {
            customAmountInput.style.display = 'none';
        }

        // Hide the comment field for shop purchases
        const commentSection = document.querySelector('.zap-comment');
        if (commentSection) {
            commentSection.style.display = 'none';
        }

        // Update send button to use existing invoice generation
        const sendBtn = document.getElementById('zapSendBtn');
        if (sendBtn) {
            sendBtn.textContent = 'Generate Invoice';
            sendBtn.onclick = () => {
                this.generateShopPaymentInvoice();
            };
        }

        // Open zap modal (will be above shop modal due to z-index fix)
        zapModal.classList.add('active');
    },

    async generateShopPaymentInvoice() {
        if (!this.currentPurchaseContext || this.currentPurchaseContext.type !== 'shop') {
            return;
        }

        // Clear any stale payment state from a previous invoice
        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }
        if (this.shopZapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
            this.shopZapReceiptSubId = null;
        }
        this.currentShopInvoice = null;
        this.currentZapInvoice = null;

        const { itemId, item, amount } = this.currentPurchaseContext;

        // Show loading state
        document.getElementById('zapAmountSection').style.display = 'none';
        document.getElementById('zapInvoiceSection').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status checking';
        document.getElementById('zapStatus').innerHTML = '<span class="loader"></span> Generating invoice...';

        try {
            // Set up a temporary zap target for the shop
            const originalZapTarget = this.currentZapTarget;
            this.currentZapTarget = {
                recipientPubkey: 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df',
                lnAddress: '69420@wallet.yakihonne.com',
                messageId: null
            };

            // Create zap request event for shop purchase
            const zapRequest = await this.createShopZapRequest(amount, `Nymchat Shop Purchase: ${item.name}`);

            // Build the LNURL callback with the zap request
            const invoice = await this.fetchShopLightningInvoice(
                '69420@wallet.yakihonne.com',
                amount,
                `Nymchat Shop Purchase: ${item.name}`,
                zapRequest
            );

            if (invoice) {
                // Store invoice data for verification
                this.currentShopInvoice = {
                    ...invoice,
                    itemId: itemId,
                    item: item,
                    zapRequestId: zapRequest ? zapRequest.id : null
                };

                // Also set currentZapInvoice so openInWallet() works
                this.currentZapInvoice = invoice;

                // Display invoice using existing function
                this.displayZapInvoice(invoice);

                // Start listening for zap receipt
                this.listenForShopZapReceipt(zapRequest);

                // Also check with verify URL if available
                if (invoice.verify) {
                    this.checkShopPayment(invoice);
                }
            }

            // Restore original zap target
            this.currentZapTarget = originalZapTarget;

        } catch (error) {
            document.getElementById('zapStatus').className = 'zap-status error';
            document.getElementById('zapStatus').textContent = `❌ Failed: ${error.message}`;

            // Show retry button
            setTimeout(() => {
                document.getElementById('zapAmountSection').style.display = 'block';
                document.getElementById('zapInvoiceSection').style.display = 'none';
                document.getElementById('zapSendBtn').style.display = 'block';
            }, 3000);
        }
    },

    async createShopZapRequest(amountSats, description) {
        try {
            const zapRequest = {
                kind: 9734,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['p', 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df'], // Shop is the recipient
                    ['amount', (parseInt(amountSats) * 1000).toString()], // Amount in millisats
                    ['relays', ...this.defaultRelays.slice(0, 5)], // Limit to 5 relays
                    ['shop-item', this.currentPurchaseContext.itemId], // Custom tag for shop item
                    ['shop-purchase', 'true'] // Flag this as a shop purchase
                ],
                content: description || '',
                pubkey: this.pubkey
            };

            // Sign the request
            const signedEvent = await this.signEvent(zapRequest);

            // Broadcast the zap request to relays
            if (signedEvent) {
                this.sendToRelay(['EVENT', signedEvent]);
            }

            return signedEvent;
        } catch (error) {
            return null;
        }
    },

    async fetchShopLightningInvoice(lnAddress, amountSats, comment, zapRequest) {
        try {
            const [username, domain] = lnAddress.split('@');
            if (!username || !domain) {
                throw new Error('Invalid lightning address format');
            }

            // Fetch LNURL endpoint
            const lnurlResponse = await fetch(`https://${domain}/.well-known/lnurlp/${username}`);
            if (!lnurlResponse.ok) {
                throw new Error('Failed to fetch LNURL endpoint');
            }

            const lnurlData = await lnurlResponse.json();

            // Convert sats to millisats
            const amountMillisats = parseInt(amountSats) * 1000;

            // Check bounds
            if (amountMillisats < lnurlData.minSendable || amountMillisats > lnurlData.maxSendable) {
                throw new Error(`Amount must be between ${lnurlData.minSendable / 1000} and ${lnurlData.maxSendable / 1000} sats`);
            }

            // Build callback URL
            const callbackUrl = new URL(lnurlData.callback);
            callbackUrl.searchParams.set('amount', amountMillisats);

            // Add comment if allowed
            if (comment && lnurlData.commentAllowed) {
                callbackUrl.searchParams.set('comment', comment.substring(0, lnurlData.commentAllowed));
            }

            // Add nostr zap request params
            if (zapRequest && lnurlData.allowsNostr && lnurlData.nostrPubkey) {
                callbackUrl.searchParams.set('nostr', JSON.stringify(zapRequest));
            }

            // Fetch invoice
            const invoiceResponse = await fetch(callbackUrl.toString());
            if (!invoiceResponse.ok) {
                throw new Error('Failed to fetch invoice');
            }

            const invoiceData = await invoiceResponse.json();

            if (invoiceData.pr) {
                return {
                    pr: invoiceData.pr,
                    successAction: invoiceData.successAction,
                    verify: invoiceData.verify,
                    amount: amountSats
                };
            } else {
                throw new Error('No payment request in response');
            }
        } catch (error) {
            throw error;
        }
    },

    listenForShopZapReceipt(zapRequest) {
        if (!zapRequest) return;

        // Close any existing shop zap receipt subscription to prevent stale matching
        if (this.shopZapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
        }

        // Store the subscription ID for later cleanup
        this.shopZapReceiptSubId = "shop-zap-" + Math.random().toString(36).substring(7);

        // Subscribe to zap receipts for the shop
        const subscription = [
            "REQ",
            this.shopZapReceiptSubId,
            {
                kinds: [9735],
                "#p": ['d49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df'], // Zaps to the shop
                since: Math.floor(Date.now() / 1000) - 60, // Last minute
                limit: 50
            }
        ];

        this.sendToRelay(subscription);

        // Set timeout to close subscription after 2 minutes
        setTimeout(() => {
            if (this.shopZapReceiptSubId) {
                this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
                this.shopZapReceiptSubId = null;
            }
        }, 120000);
    },

    async checkShopPayment(invoice) {
        if (!invoice.verify) {
            // No verify URL, just wait for zap receipt event
            this.listenForZapReceipt();
            return;
        }

        // Clear any existing payment check interval to prevent stale invoice polling
        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }

        let checkCount = 0;
        const maxChecks = 120; // Check for up to 2 minutes for shop purchases

        this.shopPaymentCheckInterval = setInterval(async () => {
            checkCount++;

            try {
                const response = await fetch(invoice.verify);
                const data = await response.json();

                if (data.settled || data.paid) {
                    // Payment confirmed!
                    clearInterval(this.shopPaymentCheckInterval);
                    this.shopPaymentCheckInterval = null;
                    await this.handleShopPaymentSuccess();
                } else if (checkCount >= maxChecks) {
                    // Timeout
                    clearInterval(this.shopPaymentCheckInterval);
                    this.shopPaymentCheckInterval = null;
                    const zapStatusEl = document.getElementById('zapStatus');
                    if (zapStatusEl) {
                        zapStatusEl.style.display = 'block';
                        zapStatusEl.className = 'zap-status';
                        zapStatusEl.innerHTML = '⏱️ Payment timeout - please check your wallet';
                    }
                }
            } catch (error) {
            }
        }, 1000); // Check every second
    },

    async handleShopPaymentSuccess() {
        if (!this.currentPurchaseContext || !this.currentShopInvoice) return;

        // Capture context and nullify immediately to prevent duplicate handling
        // (both invoice polling and zap receipt events can trigger this)
        const { itemId, item, amount } = this.currentPurchaseContext;
        const shopInvoice = this.currentShopInvoice;
        this.currentPurchaseContext = null;
        this.currentShopInvoice = null;

        // Clear check intervals and subscriptions
        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }

        if (this.shopZapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
            this.shopZapReceiptSubId = null;
        }

        // Show success message
        const zapInvoiceDisplay = document.getElementById('zapInvoiceDisplay');
        const zapStatus = document.getElementById('zapStatus');
        if (zapInvoiceDisplay) zapInvoiceDisplay.style.display = 'none';
        if (zapStatus) {
            zapStatus.style.display = 'block';
            zapStatus.className = 'zap-status paid';
        }
        if (zapStatus) zapStatus.innerHTML = `
<div style="font-size: 24px; margin-bottom: 10px;">✅</div>
<div>Purchase successful!</div>
<div style="font-size: 16px; margin-top: 10px;">${item.name}</div>
<div style="font-size: 14px; color: var(--text-dim);">${amount} sats</div>
`;

        // Create purchase record with zap event ID if available
        const purchase = {
            itemId: itemId,
            amount: amount,
            timestamp: Math.floor(Date.now() / 1000),
            txid: shopInvoice.zapRequestId || 'shop_' + Date.now()
        };

        // Store purchase locally
        this.userPurchases.set(itemId, purchase);

        // Auto-activate cosmetics on purchase
        if (item?.type === 'cosmetic') {
            this.activeCosmetics.add(itemId);
        }

        // Save to Nostr
        await this.savePurchaseToNostr(purchase);

        // Publish active items so others see the update
        this.publishActiveShopItems();

        // **NEW: Generate recovery code for ephemeral users**
        const recoveryCode = this.handlePurchaseStrategy();

        // **NEW: If ephemeral, show the recovery code in the success message**
        if (this.connectionMode === 'ephemeral' && recoveryCode && zapStatus) {
            zapStatus.innerHTML = `
    <div style="font-size: 24px; margin-bottom: 10px;">✅</div>
    <div>Purchase successful!</div>
    <div style="font-size: 16px; margin-top: 10px;">${item.name}</div>
    <div style="font-size: 14px; color: var(--text-dim);">${amount} sats</div>
    <div style="margin-top: 20px; padding: 15px; background: var(--bg-tertiary); border: 1px solid var(--warning); border-radius: 5px;">
        <div style="color: var(--warning); font-weight: bold; margin-bottom: 10px;">⚠️ SAVE YOUR RECOVERY CODE</div>
        <div style="font-size: 12px; color: var(--text-dim); margin-bottom: 10px;">Copy this code to restore your purchase in a new session:</div>
        <div style="font-family: monospace; color: var(--text-bright); font-size: 14px; word-break: break-all; cursor: pointer;" onclick="navigator.clipboard.writeText('${recoveryCode}'); this.textContent = 'Copied!';" title="Click to copy">${recoveryCode}</div>
    </div>
`;
        }

        // If there's a recovery code, don't auto-close — let the user dismiss manually
        const hasRecovery = this.connectionMode === 'ephemeral' && recoveryCode;

        // Replace modal action buttons with a Close button
        const modalActions = document.querySelector('#zapModal .modal-actions');
        if (modalActions) {
            if (hasRecovery) {
                modalActions.innerHTML = `<button class="send-btn" onclick="nym.dismissShopSuccess()">Close</button>`;
            } else {
                modalActions.innerHTML = `<button class="send-btn" onclick="nym.dismissShopSuccess()">Close</button>`;
                // Auto-close after 5 seconds for non-recovery purchases
                this._shopSuccessAutoClose = setTimeout(() => {
                    this.dismissShopSuccess();
                }, 5000);
            }
        }
    },

    dismissShopSuccess() {
        if (this._shopSuccessAutoClose) {
            clearTimeout(this._shopSuccessAutoClose);
            this._shopSuccessAutoClose = null;
        }
        this.closeZapModal();

        // Re-render the current shop tab so purchased item shows as owned
        if (this.activeShopTab) {
            this.switchShopTab(this.activeShopTab);
        }
    },

    async savePurchaseToNostr(purchaseJustMade = null) {
        if (!this.pubkey) return;

        try {
            // Merge purchase just made into map before saving
            if (purchaseJustMade) {
                this.userPurchases.set(purchaseJustMade.itemId, purchaseJustMade);
            }

            // Build full state
            const allPurchases = Array.from(this.userPurchases.entries()).map(([id, data]) => ({
                id, ...data
            }));

            // Collect recovery codes from localStorage so they are persisted to relays
            const recoveryCodes = {};
            for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                if (key && key.startsWith('nym_shop_recovery_')) {
                    try {
                        recoveryCodes[key.replace('nym_shop_recovery_', '')] = JSON.parse(localStorage.getItem(key));
                    } catch (_) { }
                }
            }

            const purchaseData = {
                purchases: allPurchases,
                activeStyle: this.activeMessageStyle || null,
                activeFlair: this.activeFlair || null,
                activeCosmetics: Array.from(this.activeCosmetics || []),
                supporterActive: this.supporterBadgeActive !== false,
                recoveryCodes: Object.keys(recoveryCodes).length > 0 ? recoveryCodes : undefined
            };

            // Cache to localStorage (CRITICAL)
            localStorage.setItem('nym_active_style', this.activeMessageStyle || '');
            localStorage.setItem('nym_active_flair', this.activeFlair || '');
            this._cachePurchases();

            const purchaseEvent = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ["d", "nym-shop-purchases"],
                    ["title", "Nymchat Shop Purchases"]
                ],
                content: JSON.stringify(purchaseData),
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(purchaseEvent);
            if (signedEvent) {
                this.sendToRelay(["EVENT", signedEvent]);
            }
        } catch (error) {
        }
    },

    getUserShopItems(pubkey) {
        if (pubkey === this.pubkey) {
            return {
                style: this.activeMessageStyle,
                flair: this.activeFlair,
                supporter: this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false,
                cosmetics: Array.from(this.activeCosmetics || [])
            };
        }
        return this.otherUsersShopItems?.get(pubkey) || null;
    },

    getFlairForUser(pubkey) {
        const userItems = this.getUserShopItems(pubkey);
        if (userItems && userItems.flair) {
            const flairItem = this.getShopItemById(userItems.flair);
            if (flairItem) {
                return `<span class="flair-badge ${userItems.flair.replace('flair-', 'flair-')}">${flairItem.icon}</span>`;
            }
        }
        return '';
    },

    activateMessageStyle(styleId) {
        // Toggle: if already active, deactivate it
        if (this.activeMessageStyle === styleId) {
            this.activeMessageStyle = null;
            this.localActiveStyle = null;
            localStorage.setItem('nym_active_style', '');
            this.savePurchaseToNostr();
            this.publishActiveShopItems();
            this.displaySystemMessage(`Deactivated ${this.getShopItemById(styleId).name}`);
            this.renderInventoryTab(document.getElementById('shopBody'));
            this.applyShopStylesToOwnMessages();
            return;
        }

        // Otherwise activate it
        this.activeMessageStyle = styleId;

        // Cache immediately
        this.localActiveStyle = this.activeMessageStyle;
        localStorage.setItem('nym_active_style', this.activeMessageStyle || '');

        this.savePurchaseToNostr();
        this.publishActiveShopItems();
        this.displaySystemMessage(`Activated ${this.getShopItemById(styleId).name}`);
        this.renderInventoryTab(document.getElementById('shopBody'));
        this.applyShopStylesToOwnMessages();
    },

    activateFlair(flairId) {
        // Toggle: if already active, deactivate it
        if (this.activeFlair === flairId) {
            this.activeFlair = null;
            this.localActiveFlair = null;
            localStorage.setItem('nym_active_flair', '');
            this.savePurchaseToNostr();
            this.publishActiveShopItems();
            this.displaySystemMessage(`Deactivated ${this.getShopItemById(flairId).name}`);
            this.renderInventoryTab(document.getElementById('shopBody'));
            this.applyShopStylesToOwnMessages();
            return;
        }

        // Otherwise activate it
        this.activeFlair = flairId;

        // Cache immediately
        this.localActiveFlair = this.activeFlair;
        localStorage.setItem('nym_active_flair', this.activeFlair || '');

        this.savePurchaseToNostr();
        this.publishActiveShopItems();
        this.displaySystemMessage(`Activated ${this.getShopItemById(flairId).name}`);
        this.renderInventoryTab(document.getElementById('shopBody'));
        this.applyShopStylesToOwnMessages();
    },

    activateSupporter() {
        if (!this.userPurchases.has('supporter-badge')) return;

        // Toggle supporter badge
        if (this.supporterBadgeActive !== false) {
            this.supporterBadgeActive = false;
            localStorage.setItem('nym_supporter_active', 'false');
            this.displaySystemMessage('Deactivated Nymchat Supporter badge');
        } else {
            this.supporterBadgeActive = true;
            localStorage.setItem('nym_supporter_active', 'true');
            this.displaySystemMessage('Activated Nymchat Supporter badge');
        }

        this.savePurchaseToNostr();
        this.publishActiveShopItems();
        this.renderInventoryTab(document.getElementById('shopBody'));
        this.applyShopStylesToOwnMessages();
    },

    getActiveMessageStyle() {
        if (this.activeMessageStyle) {
            return this.getShopItemById(this.activeMessageStyle);
        }
        return null;
    },

    getActiveFlair() {
        if (this.activeFlair) {
            return this.getShopItemById(this.activeFlair);
        }
        return null;
    },

    handlePurchaseStrategy() {
        if (this.connectionMode === 'ephemeral') {
            // Build a self-contained Base64 code so it works across sessions/devices
            const payload = {
                purchases: Array.from(this.userPurchases.entries()),
                activeStyle: this.activeMessageStyle || null,
                activeFlair: this.activeFlair || null,
                activeCosmetics: Array.from(this.activeCosmetics || []),
                ts: Date.now()
            };
            const code = this.generatePurchaseRecoveryCode(payload);

            // Also keep a local copy as a fallback
            localStorage.setItem('nym_shop_recovery_' + code, JSON.stringify(payload));

            this.displaySystemMessage(`
⚠️ PURCHASE RECOVERY CODE ⚠️
Save this code to restore this purchase in a new session across device:
${code}
`);
            return code;
        } else {
            this.savePurchaseToNostr();
            return null;
        }
    },

    generatePurchaseRecoveryCode(payloadObj) {
        // Generate 16 random bytes → 32 uppercase hex chars
        const id = (() => {
            if (window.crypto?.getRandomValues) {
                const u8 = new Uint8Array(16);
                window.crypto.getRandomValues(u8);
                return Array.from(u8, b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
            }
            // Minimal non-crypto fallback (still produces 32 chars)
            let s = '';
            while (s.length < 32) s += Math.random().toString(16).slice(2);
            return s.slice(0, 32).toUpperCase();
        })();

        const code = `NYM-${id}`;
        const json = JSON.stringify(payloadObj);
        localStorage.setItem('nym_shop_recovery_' + code, json);
        return code;
    },

    async restorePurchases(recoveryCode) {
        if (recoveryCode && recoveryCode.startsWith('NYM-')) {
            try {
                const stored = localStorage.getItem('nym_shop_recovery_' + recoveryCode);
                if (!stored) {
                    throw new Error('No stored data for code');
                }

                const data = JSON.parse(stored);

                this.userPurchases.clear();
                (data.purchases || []).forEach(([id, purchase]) => this.userPurchases.set(id, purchase));
                this.activeMessageStyle = data.activeStyle || null;
                this.activeFlair = data.activeFlair || null;
                this.activeCosmetics = new Set(Array.isArray(data.activeCosmetics) ? data.activeCosmetics : []);

                // Cache purchases locally
                this._cachePurchases();

                // Save & broadcast so others see it
                await this.savePurchaseToNostr();
                this.publishActiveShopItems();

                this.displaySystemMessage('✅ Shop item restored successfully!');
                if (document.getElementById('shopModal').classList.contains('active')) {
                    this.switchShopTab(this.activeShopTab);
                }
                return true;
            } catch (e) {
            }
        }

        this.displaySystemMessage('❌ Invalid recovery code');
        return false;
    },

    promptTransferShopItem(itemId) {
        const item = this.getShopItemById(itemId);
        if (!item) return;

        if (!this.userPurchases.has(itemId)) {
            this.displaySystemMessage('❌ You do not own this item');
            return;
        }

        // Create a modal prompt for entering the recipient pubkey
        const modal = document.createElement('div');
        modal.className = 'modal active';
        modal.id = 'transferModal';
        modal.innerHTML = `
<div class="modal-content" style="max-width: 420px;">
    <button class="modal-close" onclick="document.getElementById('transferModal').remove()">✕</button>
    <h3 style="color: var(--text-bright); margin-bottom: 15px;">Transfer Item</h3>
    <div style="margin-bottom: 15px;">
        <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 10px;">
            <span>${item.icon}</span>
            <strong>${item.name}</strong>
        </div>
        <p style="font-size: 12px; color: var(--text-dim); margin-bottom: 15px;">
            Enter the recipient's hex pubkey (64 characters). This will send a Nostr event granting them access to this item on their devices.
        </p>
        <input type="text" id="transferPubkeyInput" placeholder="Recipient hex pubkey (64 chars)"
            style="width: 100%; padding: 10px; background: var(--bg); border: 1px solid var(--glass-border); border-radius: 8px; color: var(--text); font-family: var(--font-mono); font-size: 12px;" />
        <p id="transferError" style="color: var(--danger); font-size: 11px; margin-top: 5px; display: none;"></p>
    </div>
    <div style="display: flex; gap: 10px;">
        <button class="send-btn" onclick="nym.executeTransferShopItem('${itemId}')" style="flex: 1;">Confirm</button>
        <button class="send-btn" onclick="document.getElementById('transferModal').remove()" style="flex: 1; background: var(--bg-tertiary);">Cancel</button>
    </div>
</div>`;
        document.body.appendChild(modal);

        // Focus the input
        setTimeout(() => document.getElementById('transferPubkeyInput')?.focus(), 100);
    },

    async executeTransferShopItem(itemId) {
        const input = document.getElementById('transferPubkeyInput');
        const errorEl = document.getElementById('transferError');
        if (!input || !errorEl) return;

        const recipientPubkey = input.value.trim().toLowerCase();

        // Validate hex pubkey (64 hex chars)
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

        const purchase = this.userPurchases.get(itemId);

        try {
            // Publish a transfer event (kind 30078 with d tag "nym-shop-transfer")
            const transferPayload = {
                itemId: itemId,
                itemName: item.name,
                itemType: item.type,
                fromPubkey: this.pubkey,
                toPubkey: recipientPubkey,
                originalPurchase: purchase,
                transferredAt: Math.floor(Date.now() / 1000)
            };

            const transferEvent = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['d', `nym-shop-transfer-${itemId}-${recipientPubkey}`],
                    ['title', 'Nymchat Shop Item Transfer'],
                    ['p', recipientPubkey],
                    ['transfer-item', itemId],
                    ['transfer-to', recipientPubkey]
                ],
                content: JSON.stringify(transferPayload),
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(transferEvent);
            if (signedEvent) {
                this.sendToRelay(['EVENT', signedEvent]);
            }

            // Close the transfer modal
            const modal = document.getElementById('transferModal');
            if (modal) modal.remove();

            this.displaySystemMessage(`Transfer event sent! ${item.name} has been shared with ${recipientPubkey.substring(0, 8)}...`);

            // Refresh the inventory tab if open
            if (this.activeShopTab === 'inventory') {
                this.renderInventoryTab(document.getElementById('shopBody'));
            }
        } catch (error) {
            errorEl.textContent = 'Failed to send transfer event. Please try again.';
            errorEl.style.display = 'block';
        }
    },

    handleShopTransferEvent(event) {
        try {
            // Verify event signature
            if (!window.NostrTools.verifyEvent(event)) return;

            const transferTo = event.tags.find(t => t[0] === 'transfer-to');
            if (!transferTo || transferTo[1] !== this.pubkey) return;

            const data = JSON.parse(event.content);
            if (!data.itemId || !data.fromPubkey) return;

            // Verify the event was actually signed by the claimed sender
            if (event.pubkey !== data.fromPubkey) return;

            // Skip if already handled
            if (this.dismissedTransferEvents.has(event.id)) return;

            // Verify this item exists in the shop
            const item = this.getShopItemById(data.itemId);
            if (!item) return;

            // Skip if we already own this item
            if (this.userPurchases.has(data.itemId)) return;

            // Mark as handled so relays don't re-trigger it
            this.dismissTransferEvent(event.id);

            // Add the item to our purchases
            const purchase = {
                itemId: data.itemId,
                amount: data.originalPurchase?.amount || 0,
                timestamp: data.transferredAt || Math.floor(Date.now() / 1000),
                txid: `transfer_from_${data.fromPubkey.substring(0, 8)}_${Date.now()}`,
                transferredFrom: data.fromPubkey
            };

            this.userPurchases.set(data.itemId, purchase);

            // Cache purchases locally
            this._cachePurchases();

            // Save to Nostr so it persists
            this.savePurchaseToNostr();
            this.publishActiveShopItems();

            this.displaySystemMessage(`You received "${data.itemName}" from ${data.fromPubkey.substring(0, 8)}...! Check your Flair Shop inventory.`);
        } catch (e) {
            // Silently ignore malformed transfer events
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

        try {
            const avatarUrl = this.userAvatars.get(this.pubkey) || localStorage.getItem('nym_avatar_url') || '';

            const settingsPayload = {
                fromPubkey: this.pubkey,
                fromNym: this.nym,
                toPubkey: recipientPubkey,
                transferredAt: Math.floor(Date.now() / 1000),
                nickname: this.nym,
                avatarUrl: avatarUrl,
                settings: {
                    theme: this.settings.theme,
                    sound: this.settings.sound,
                    autoscroll: this.settings.autoscroll,
                    showTimestamps: this.settings.showTimestamps,
                    timeFormat: this.settings.timeFormat,
                    sortByProximity: this.settings.sortByProximity,
                    blurOthersImages: this.blurOthersImages,
                    lightningAddress: this.lightningAddress,
                    dmForwardSecrecyEnabled: !!this.settings.dmForwardSecrecyEnabled,
                    dmTTLSeconds: this.settings.dmTTLSeconds || 86400,
                    readReceiptsEnabled: this.settings.readReceiptsEnabled !== false,
                    typingIndicatorsEnabled: this.settings.typingIndicatorsEnabled !== false,
                    pinnedLandingChannel: this.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' },
                    wallpaperType: localStorage.getItem('nym_wallpaper_type') || 'geometric',
                    wallpaperCustomUrl: localStorage.getItem('nym_wallpaper_custom_url') || '',
                    chatLayout: this.settings.chatLayout || 'irc',
                    colorMode: this.getColorMode(),
                    nickStyle: this.settings.nickStyle || 'fancy',
                    groupChatPMOnlyMode: this.settings.groupChatPMOnlyMode || false
                }
            };

            const transferEvent = {
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

            const signedEvent = await this.signEvent(transferEvent);
            if (signedEvent) {
                this.sendToRelay(['EVENT', signedEvent]);
            }

            input.value = '';
            this.displaySystemMessage(`Settings transfer sent to ${recipientPubkey.substring(0, 8)}...!`);
        } catch (error) {
            errorEl.textContent = 'Failed to send settings transfer. Please try again.';
            errorEl.style.display = 'block';
        }
    },

    handleSettingsTransferEvent(event) {
        try {
            // Verify event signature
            if (!window.NostrTools.verifyEvent(event)) return;

            const transferTo = event.tags.find(t => t[0] === 'settings-transfer-to');
            if (!transferTo || transferTo[1] !== this.pubkey) return;

            const data = JSON.parse(event.content);
            if (!data.fromPubkey || !data.settings) return;

            // Verify the event was actually signed by the claimed sender
            if (event.pubkey !== data.fromPubkey) return;

            // Check if we already handled or have this pending transfer
            if (this.dismissedTransferEvents.has(event.id)) return;
            if (this.pendingSettingsTransfers.some(t => t.eventId === event.id)) return;

            // Add to pending list
            this.pendingSettingsTransfers.push({
                eventId: event.id,
                fromPubkey: data.fromPubkey,
                fromNym: data.fromNym || data.fromPubkey.substring(0, 8) + '...',
                nickname: data.nickname,
                avatarUrl: data.avatarUrl,
                settings: data.settings,
                transferredAt: data.transferredAt || event.created_at
            });

            // Notify user via system message
            this.displaySystemMessage(`Settings received from ${data.fromPubkey.substring(0, 8)}...! Approve from settings modal.`);

            // Update the pending transfers UI if the settings modal is open
            this.renderPendingSettingsTransfers();
        } catch (e) {
            // Silently ignore malformed transfer events
        }
    },

    acceptSettingsTransfer(eventId) {
        const transfer = this.pendingSettingsTransfers.find(t => t.eventId === eventId);
        if (!transfer) return;

        // Apply nickname
        if (transfer.nickname) {
            this.nym = transfer.nickname;
            localStorage.setItem(`nym_nickname_${this.pubkey}`, transfer.nickname);
            document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
            this.saveToNostrProfile();
        }

        // Apply avatar
        if (transfer.avatarUrl) {
            this.userAvatars.set(this.pubkey, transfer.avatarUrl);
            localStorage.setItem('nym_avatar_url', transfer.avatarUrl);
            this.cacheAvatarImage(this.pubkey, transfer.avatarUrl);
        }

        // Apply settings
        const s = transfer.settings;
        if (s) {
            if (s.theme) {
                this.settings.theme = s.theme;
                this.applyTheme(s.theme);
                localStorage.setItem('nym_theme', s.theme);
            }
            if (s.sound !== undefined) {
                this.settings.sound = s.sound;
                localStorage.setItem('nym_sound', s.sound);
            }
            if (s.autoscroll !== undefined) {
                this.settings.autoscroll = s.autoscroll;
                localStorage.setItem('nym_autoscroll', s.autoscroll);
            }
            if (s.showTimestamps !== undefined) {
                this.settings.showTimestamps = s.showTimestamps;
                localStorage.setItem('nym_timestamps', s.showTimestamps);
            }
            if (s.timeFormat !== undefined) {
                this.settings.timeFormat = s.timeFormat;
                localStorage.setItem('nym_time_format', s.timeFormat);
            }
            if (s.sortByProximity !== undefined) {
                this.settings.sortByProximity = s.sortByProximity;
                localStorage.setItem('nym_sort_proximity', s.sortByProximity);
            }
            if (s.blurOthersImages !== undefined) {
                this.blurOthersImages = s.blurOthersImages;
                localStorage.setItem('nym_image_blur', s.blurOthersImages.toString());
                if (this.pubkey) {
                    localStorage.setItem(`nym_image_blur_${this.pubkey}`, s.blurOthersImages.toString());
                }
            }
            if (s.lightningAddress) {
                this.lightningAddress = s.lightningAddress;
                localStorage.setItem(`nym_lightning_address_${this.pubkey}`, s.lightningAddress);
            }
            if (s.dmForwardSecrecyEnabled !== undefined) {
                this.settings.dmForwardSecrecyEnabled = s.dmForwardSecrecyEnabled;
                localStorage.setItem('nym_dm_fwdsec_enabled', String(s.dmForwardSecrecyEnabled));
            }
            if (s.dmTTLSeconds !== undefined) {
                this.settings.dmTTLSeconds = s.dmTTLSeconds;
                localStorage.setItem('nym_dm_ttl_seconds', String(s.dmTTLSeconds));
            }
            if (s.readReceiptsEnabled !== undefined) {
                this.settings.readReceiptsEnabled = s.readReceiptsEnabled;
                localStorage.setItem('nym_read_receipts_enabled', String(s.readReceiptsEnabled));
            }
            if (s.typingIndicatorsEnabled !== undefined) {
                this.settings.typingIndicatorsEnabled = s.typingIndicatorsEnabled;
                localStorage.setItem('nym_typing_indicators_enabled', String(s.typingIndicatorsEnabled));
            }
            if (s.pinnedLandingChannel) {
                this.pinnedLandingChannel = s.pinnedLandingChannel;
                this.settings.pinnedLandingChannel = s.pinnedLandingChannel;
                localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(s.pinnedLandingChannel));
            }
            if (s.wallpaperType !== undefined) {
                this.saveWallpaper(s.wallpaperType, s.wallpaperCustomUrl || '');
                this.applyWallpaper(s.wallpaperType, s.wallpaperCustomUrl || '');
            }
            if (s.chatLayout) {
                this.settings.chatLayout = s.chatLayout;
                localStorage.setItem('nym_chat_layout', s.chatLayout);
                applyMessageLayout(s.chatLayout);
            }
            if (s.colorMode) {
                localStorage.setItem('nym_color_mode', s.colorMode);
                this.applyColorMode();
            }
            if (s.nickStyle) {
                this.settings.nickStyle = s.nickStyle;
                localStorage.setItem('nym_nick_style', s.nickStyle);
            }
            if (s.groupChatPMOnlyMode !== undefined) {
                this.settings.groupChatPMOnlyMode = s.groupChatPMOnlyMode;
                localStorage.setItem('nym_groupchat_pm_only_mode', String(s.groupChatPMOnlyMode));
                this.applyGroupChatPMOnlyMode(s.groupChatPMOnlyMode);
            }

            // Save synced settings to Nostr
            this.saveSyncedSettings();
        }

        // Remove from pending and mark as dismissed so relays don't re-trigger it
        this.pendingSettingsTransfers = this.pendingSettingsTransfers.filter(t => t.eventId !== eventId);
        this.dismissTransferEvent(eventId);
        this.renderPendingSettingsTransfers();

        // Update sidebar avatar
        this.updateSidebarAvatar();

        // Update settings modal UI if open
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
            container.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No pending transfers</div>';
            return;
        }

        container.innerHTML = this.pendingSettingsTransfers.map(t => {
            const date = new Date(t.transferredAt * 1000).toLocaleString();
            return `
                <div style="display: flex; align-items: center; justify-content: space-between; padding: 8px; margin-bottom: 6px; background: rgba(255,255,255,0.03); border: 1px solid var(--glass-border); border-radius: 8px;">
                    <div style="flex: 1; min-width: 0;">
                        <div style="font-size: 13px; color: var(--text); font-weight: 500;">${this.escapeHtml(t.fromNym)}</div>
                        <div style="font-size: 11px; color: var(--text-dim); margin-top: 2px;">${date}</div>
                        <div style="font-size: 11px; color: var(--text-dim);">Includes: ${t.nickname ? 'nickname' : ''}${t.avatarUrl ? ', avatar' : ''}${t.settings ? ', preferences' : ''}</div>
                    </div>
                    <div style="display: flex; gap: 6px; margin-left: 8px;">
                        <button class="icon-btn" onclick="nym.acceptSettingsTransfer('${t.eventId}')" style="padding: 4px 10px; font-size: 12px;">Accept</button>
                        <button class="icon-btn" onclick="nym.rejectSettingsTransfer('${t.eventId}')" style="padding: 4px 10px; font-size: 12px; color: var(--danger); border-color: var(--danger);">Reject</button>
                    </div>
                </div>`;
        }).join('');
    },

});
