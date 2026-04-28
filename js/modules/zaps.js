// zaps.js - Lightning zaps: invoices, modals, receipts, message/profile zaps, wallets
// Methods are attached to NYM.prototype.

Object.assign(NYM.prototype, {

    // Build a zap receipt filter scoped to visible message event IDs.
    // Returns null if no event IDs are available (caller should skip zap filter).
    _buildZapReceiptFilter() {
        this._collectVisibleEventIds();
        if (this._zapReceiptEventIds.size === 0) return null;
        // Limit to 500 event IDs to stay within relay filter size limits
        const ids = [...this._zapReceiptEventIds].slice(0, 500);
        return { kinds: [9735], "#e": ids, limit: 100 };
    },

    // Debounced update of the zap receipt subscription (called when messages change)
    _scheduleZapResubscribe() {
        if (this._zapResubscribeTimer) return; // already scheduled
        this._zapResubscribeTimer = setTimeout(() => {
            this._zapResubscribeTimer = null;
            this._updateZapReceiptSubscription();
        }, 10000); // 10-second debounce
    },

    // Send an updated zap receipt subscription to critical relays only
    _updateZapReceiptSubscription() {
        const zapFilter = this._buildZapReceiptFilter();
        if (!zapFilter) return;

        const newSubId = Math.random().toString(36).substring(2);

        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            // Close previous zap subscription
            if (this._zapReceiptSubId) {
                this._poolSendToRole('critical', ["CLOSE", this._zapReceiptSubId]);
            }
            this._zapReceiptSubId = newSubId;
            this._poolSendToRole('critical', ["REQ", newSubId, zapFilter]);
        } else {
            // Direct mode: send to default + DM relays only
            const msg = JSON.stringify(["REQ", newSubId, zapFilter]);
            const closeMsg = this._zapReceiptSubId ? JSON.stringify(["CLOSE", this._zapReceiptSubId]) : null;
            this._zapReceiptSubId = newSubId;

            this.relayPool.forEach((relay, url) => {
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN &&
                    relay.type !== 'write' && !this._isGeoOrDiscoveredRelay(url)) {
                    if (closeMsg) try { relay.ws.send(closeMsg); } catch (_) { }
                    if (!relay.subscriptions) relay.subscriptions = new Set();
                    relay.subscriptions.add(newSubId);
                    try { relay.ws.send(msg); } catch (_) { }
                }
            });
        }
    },

    // Fetch invoice from LNURL
    async fetchLightningInvoice(lnAddress, amountSats, comment) {
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

            // Add nostr params for zap
            if (lnurlData.allowsNostr && lnurlData.nostrPubkey) {
                // Create zap request event
                const zapRequest = await this.createZapRequest(amountSats, comment);
                if (zapRequest) {
                    callbackUrl.searchParams.set('nostr', JSON.stringify(zapRequest));
                }
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

    // Resolve any pending waiters for a user's lightning address
    notifyLightningAddress(pubkey, address) {
        const waiters = this.pendingLightningWaiters.get(pubkey);
        if (!waiters) return;
        for (const resolve of Array.from(waiters)) {
            try { resolve(address); } catch (_) { }
        }
        this.pendingLightningWaiters.delete(pubkey);
    },

    // Wait for a user's lightning address to be discovered
    waitForLightningAddress(pubkey, timeoutMs = 8000) {
        // If already cached, resolve immediately
        if (this.userLightningAddresses.has(pubkey)) {
            return Promise.resolve(this.userLightningAddresses.get(pubkey));
        }

        return new Promise((resolve) => {
            const resolver = (addr) => resolve(addr || null);

            // Register waiter
            if (!this.pendingLightningWaiters.has(pubkey)) {
                this.pendingLightningWaiters.set(pubkey, new Set());
            }
            const set = this.pendingLightningWaiters.get(pubkey);
            set.add(resolver);

            // Timeout fallback
            const timer = setTimeout(() => {
                // Clean up this resolver to prevent leaks
                const s = this.pendingLightningWaiters.get(pubkey);
                if (s) {
                    s.delete(resolver);
                    if (s.size === 0) this.pendingLightningWaiters.delete(pubkey);
                }
                resolve(null);
            }, timeoutMs);

            // Wrap resolver to clear timeout when it fires
            const wrapped = (addr) => {
                clearTimeout(timer);
                resolve(addr || null);
            };

            // Replace the bare resolver with a wrapped one that clears the timeout
            set.delete(resolver);
            set.add(wrapped);
        });
    },

    async fetchLightningAddressForUser(pubkey) {
        // Serve from cache if available
        if (this.userLightningAddresses.has(pubkey)) {
            return this.userLightningAddresses.get(pubkey);
        }

        try { this.requestUserProfile(pubkey); } catch (_) { }

        // Fire a direct, one-shot profile request to a few relays
        const subId = 'ln-addr-' + Math.random().toString(36).slice(2);
        const req = ["REQ", subId, { kinds: [0], authors: [pubkey], limit: 1 }];
        try { this.sendRequestToFewRelays(req); } catch (_) { }

        // Wait for handleEvent(kind 0) to notice LUD16/LUD06 (or timeout)
        const addr = await this.waitForLightningAddress(pubkey, 8000);

        try { this.sendToRelay(["CLOSE", subId]); } catch (_) { }

        return addr;
    },

    async loadLightningAddress() {
        // Only load if we have a pubkey
        if (!this.pubkey) return;

        // First, try to load from pubkey-specific localStorage
        const saved = localStorage.getItem(`nym_lightning_address_${this.pubkey}`);
        if (saved) {
            this.lightningAddress = saved;
            this.updateLightningAddressDisplay();
            return;
        }

        // If not in localStorage, try to fetch from Nostr profile
        const profileAddress = await this.fetchLightningAddressForUser(this.pubkey);
        if (profileAddress) {
            this.lightningAddress = profileAddress;
            // Cache it in localStorage for this pubkey
            localStorage.setItem(`nym_lightning_address_${this.pubkey}`, profileAddress);
            this.updateLightningAddressDisplay();
        }
    },

    updateLightningAddressDisplay() {
        const display = document.getElementById('lightningAddressDisplay');
        const value = document.getElementById('lightningAddressValue');

        if (this.lightningAddress && display && value) {
            display.style.display = 'flex';
            value.textContent = this.lightningAddress;
        } else if (display) {
            display.style.display = 'none';
        }
    },

    // Show zap modal
    showZapModal(messageId, recipientPubkey, recipientNym) {
        // Check if recipient has lightning address
        const lnAddress = this.userLightningAddresses.get(recipientPubkey);

        if (!lnAddress) {
            this.displaySystemMessage(`${recipientNym} doesn't have a lightning address set`);
            return;
        }

        // Store target info
        this.currentZapTarget = {
            messageId,
            recipientPubkey,
            recipientNym,
            lnAddress
        };

        // Reset modal state
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = `Zapping @${recipientNym}`;
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        document.getElementById('zapSendBtn').textContent = 'Generate Invoice';
        document.getElementById('zapSendBtn').onclick = () => this.generateZapInvoice();

        // Clear selected amounts
        document.querySelectorAll('.zap-amount-btn').forEach(btn => {
            btn.classList.remove('selected');
            btn.onclick = (e) => {
                document.querySelectorAll('.zap-amount-btn').forEach(b => b.classList.remove('selected'));
                e.target.closest('.zap-amount-btn').classList.add('selected');
                document.getElementById('zapCustomAmount').value = '';
            };
        });

        // Show modal
        document.getElementById('zapModal').classList.add('active');
    },

    showProfileZapModal(recipientPubkey, recipientNym, lnAddress) {
        // Store target info for profile zap (no messageId)
        this.currentZapTarget = {
            messageId: null, // No message ID for profile zaps
            recipientPubkey,
            recipientNym,
            lnAddress,
            isProfileZap: true
        };

        // Reset modal state
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = `Zapping @${recipientNym}'s profile`;
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        document.getElementById('zapSendBtn').textContent = 'Generate Invoice';
        document.getElementById('zapSendBtn').onclick = () => this.generateZapInvoice();

        // Clear selected amounts
        document.querySelectorAll('.zap-amount-btn').forEach(btn => {
            btn.classList.remove('selected');
            btn.onclick = (e) => {
                document.querySelectorAll('.zap-amount-btn').forEach(b => b.classList.remove('selected'));
                e.target.closest('.zap-amount-btn').classList.add('selected');
                document.getElementById('zapCustomAmount').value = '';
            };
        });

        // Show modal
        document.getElementById('zapModal').classList.add('active');
    },

    cleanupOldLightningAddress() {
        // Remove old non-pubkey-specific entry if it exists
        const oldAddress = localStorage.getItem('nym_lightning_address');
        if (oldAddress) {
            localStorage.removeItem('nym_lightning_address');
        }
    },

    // Create zap request event (NIP-57)
    async createZapRequest(amountSats, comment) {
        try {
            if (!this.currentZapTarget) {
                return null;
            }

            const zapRequest = {
                kind: 9734,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['p', this.currentZapTarget.recipientPubkey], // Recipient of zap
                    ['amount', (parseInt(amountSats) * 1000).toString()], // Amount in millisats
                    ['relays', ...this.defaultRelays.slice(0, 5)] // Limit to 5 relays
                ],
                content: comment || '',
                pubkey: this.pubkey
            };

            // Add event tag only if this is a message zap (not profile zap)
            if (this.currentZapTarget.messageId) {
                zapRequest.tags.unshift(['e', this.currentZapTarget.messageId]); // Event being zapped

                let originalKind = '20000'; // Default geohash
                if (this.inPMMode) {
                    originalKind = '1059'; // PMs via NIP-17
                } else if (this.currentGeohash) {
                    originalKind = '20000';
                }
                zapRequest.tags.push(['k', originalKind]);
            }

            // Sign the request
            const signedEvent = await this.signEvent(zapRequest);

            return signedEvent;
        } catch (error) {
            return null;
        }
    },

    // Generate and display invoice
    async generateZapInvoice() {
        if (!this.currentZapTarget) return;

        // Clear any stale payment state from a previous invoice
        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }
        if (this.zapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.zapReceiptSubId]);
            this.zapReceiptSubId = null;
        }
        this.currentZapInvoice = null;

        // Get amount
        const selectedBtn = document.querySelector('.zap-amount-btn.selected');
        const customAmount = document.getElementById('zapCustomAmount').value;
        const amount = customAmount || (selectedBtn ? selectedBtn.dataset.amount : null);

        if (!amount || amount <= 0) {
            this.displaySystemMessage('Please select or enter an amount');
            return;
        }

        const comment = document.getElementById('zapComment').value || '';

        // Show loading state
        document.getElementById('zapAmountSection').style.display = 'none';
        document.getElementById('zapInvoiceSection').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status checking';
        document.getElementById('zapStatus').innerHTML = '<span class="loader"></span> Generating invoice...';

        try {
            // Fetch the invoice
            const invoice = await this.fetchLightningInvoice(
                this.currentZapTarget.lnAddress,
                amount,
                comment
            );

            if (invoice) {
                this.currentZapInvoice = invoice;
                this.zapInvoiceData = {
                    ...invoice,
                    messageId: this.currentZapTarget.messageId,
                    recipientPubkey: this.currentZapTarget.recipientPubkey
                };

                // Display invoice
                this.displayZapInvoice(invoice);

                // Start checking for payment
                this.checkZapPayment(invoice);
            }
        } catch (error) {
            document.getElementById('zapStatus').className = 'zap-status';
            document.getElementById('zapStatus').textContent = `Failed: ${error.message}`;
        }
    },

    // Display the invoice with QR code
    displayZapInvoice(invoice) {
        document.getElementById('zapStatus').style.display = 'none';
        document.getElementById('zapInvoiceDisplay').style.display = 'block';

        // Display invoice text
        const invoiceEl = document.getElementById('zapInvoice');
        invoiceEl.textContent = invoice.pr;

        // Generate QR code
        const qrContainer = document.getElementById('zapQRCode');
        qrContainer.innerHTML = ''; // Clear existing QR

        // Set container to center content
        qrContainer.style.cssText = 'text-align: center; display: flex; justify-content: center; align-items: center;';

        // Create QR code element with white border styling
        const qrDiv = document.createElement('div');
        qrDiv.id = 'zapQRCodeCanvas';
        qrDiv.style.cssText = 'display: inline-block; padding: 15px; background: white; border: 5px solid white; border-radius: 10px;';
        qrContainer.appendChild(qrDiv);

        // Generate QR using the invoice
        try {
            new QRCode(qrDiv, {
                text: invoice.pr,  // Just the raw invoice, no lightning: prefix
                width: 200,
                height: 200,
                colorDark: "#000000",
                colorLight: "#ffffff",
                correctLevel: QRCode.CorrectLevel.L
            });

        } catch (err) {
            // Fallback if QRCode library not loaded
            qrContainer.innerHTML = `
    <div style="display: inline-block; padding: 20px; border: 5px solid white; background: white; color: black; text-align: center; border-radius: 10px;">
        <div style="font-size: 14px; margin-bottom: 10px;">Lightning Invoice</div>
        <div style="font-size: 10px; word-break: break-all;">${this.escapeHtml(invoice.pr.substring(0, 60))}...</div>
        <div style="margin-top: 10px; font-size: 12px; color: red;">QR generation failed - copy invoice manually</div>
    </div>
`;
        }

        // Update button
        document.getElementById('zapSendBtn').textContent = 'Close';
        document.getElementById('zapSendBtn').onclick = () => this.closeZapModal();
    },

    // Check if payment was made
    async checkZapPayment(invoice) {
        if (!invoice.verify) {
            // No verify URL, just wait for zap receipt event
            this.listenForZapReceipt();
            return;
        }

        // Clear any existing payment check interval to prevent stale invoice polling
        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }

        let checkCount = 0;
        const maxChecks = 60; // Check for up to 60 seconds

        this.zapCheckInterval = setInterval(async () => {
            checkCount++;

            try {
                const response = await fetch(invoice.verify);
                const data = await response.json();

                if (data.settled || data.paid) {
                    // Payment confirmed!
                    clearInterval(this.zapCheckInterval);
                    this.handleZapPaymentSuccess(invoice.amount);
                } else if (checkCount >= maxChecks) {
                    // Timeout
                    clearInterval(this.zapCheckInterval);
                    const zapStatusEl = document.getElementById('zapStatus');
                    if (zapStatusEl) {
                        zapStatusEl.style.display = 'block';
                        zapStatusEl.className = 'zap-status';
                        zapStatusEl.innerHTML = 'Payment timeout - please check your wallet';
                    }
                }
            } catch (error) {
            }
        }, 1000); // Check every second
    },

    // Listen for zap receipt events
    listenForZapReceipt() {
        // Close any existing zap receipt subscription to prevent stale matching
        if (this.zapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.zapReceiptSubId]);
            this.zapReceiptSubId = null;
        }

        // Subscribe to zap receipt events (kind 9735) for this specific event
        const subId = "zap-receipt-" + Math.random().toString(36).substring(7);
        this.zapReceiptSubId = subId;
        const subscription = [
            "REQ",
            subId,
            {
                kinds: [9735],
                "#e": [this.currentZapTarget.messageId],
                since: Math.floor(Date.now() / 1000) - 300, // Last 5 minutes
                limit: 10
            }
        ];

        this.sendToRelay(subscription);

        // Also close the subscription after 60 seconds
        setTimeout(() => {
            if (this.zapReceiptSubId === subId) {
                this.sendToRelay(["CLOSE", subId]);
                this.zapReceiptSubId = null;
            }
        }, 60000);
    },

    // Handle successful payment
    handleZapPaymentSuccess(amount) {
        if (!this.currentZapTarget) return;

        // Clear check interval
        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }

        // Update UI
        document.getElementById('zapInvoiceDisplay').style.display = 'none';
        document.getElementById('zapStatus').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status paid';
        document.getElementById('zapStatus').innerHTML = `
<div style="font-size: 24px; margin-bottom: 10px;">⚡</div>
<div>Zap sent successfully!</div>
<div style="font-size: 20px; margin-top: 10px;">${amount} sats</div>
`;

        // Close modal after 2 seconds
        setTimeout(() => {
            this.closeZapModal();
        }, 2000);
    },

    // Handle zap receipt events (NIP-57)
    handleZapReceipt(event) {
        if (event.kind !== 9735) return;

        // Parse zap receipt
        const eTag = event.tags.find(t => t[0] === 'e');
        const pTag = event.tags.find(t => t[0] === 'p');
        const boltTag = event.tags.find(t => t[0] === 'bolt11');
        const descriptionTag = event.tags.find(t => t[0] === 'description');

        if (!eTag || !boltTag) return;

        const messageId = eTag[1];
        const bolt11 = boltTag[1];

        // Parse amount from bolt11
        const amount = this.parseAmountFromBolt11(bolt11);

        if (amount) {
            // Get zapper pubkey from description if available
            let zapperPubkey = event.pubkey;

            if (descriptionTag) {
                try {
                    const zapRequest = JSON.parse(descriptionTag[1]);
                    if (zapRequest.pubkey) {
                        zapperPubkey = zapRequest.pubkey;
                    }

                    // Optional: Verify the k tag to ensure it's for supported kinds
                    const kTag = zapRequest.tags?.find(t => t[0] === 'k');
                    if (kTag && !['20000', '1059'].includes(kTag[1])) {
                        return;
                    }
                } catch (e) {
                    // Ignore parse errors
                }
            }

            // Initialize zaps tracking for this message if needed
            if (!this.zaps.has(messageId)) {
                this.zaps.set(messageId, {
                    receipts: new Set(), // Track receipt IDs to prevent duplicates
                    amounts: new Map()   // Map of pubkey -> total amount
                });
            }

            const messageZaps = this.zaps.get(messageId);

            // Check if we've already processed this receipt (deduplication)
            if (messageZaps.receipts.has(event.id)) {
                return; // Already processed this zap receipt
            }

            // Mark this receipt as processed
            messageZaps.receipts.add(event.id);

            // Update the amount for this zapper
            const currentAmount = messageZaps.amounts.get(zapperPubkey) || 0;
            messageZaps.amounts.set(zapperPubkey, currentAmount + amount);

            // Update display for this message
            this.updateMessageZaps(messageId);

            // Check if this is for our current pending zap
            if (this.currentZapTarget &&
                this.currentZapTarget.messageId === messageId &&
                zapperPubkey === this.pubkey) {
                this.handleZapPaymentSuccess(amount);
            }
        }
    },

    // Parse amount from bolt11 invoice
    parseAmountFromBolt11(bolt11) {
        const match = bolt11.match(/lnbc(\d+)([munp])/i);
        if (match) {
            const amount = parseInt(match[1]);
            const multiplier = match[2];

            switch (multiplier) {
                case 'm': return amount * 100000; // millisats to sats
                case 'u': return amount * 100; // microsats to sats
                case 'n': return Math.round(amount / 10); // nanosats to sats
                case 'p': return Math.round(amount / 10000); // picosats to sats
                default: return amount;
            }
        }
        return null;
    },

    // Update message with zap display
    updateMessageZaps(messageId) {
        const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
        if (!messageEl) return;

        // Capture scroll state before modifying DOM so we can auto-scroll if needed
        const container = document.getElementById('messagesContainer');
        const wasAtBottom = container && (container.scrollHeight - container.scrollTop <= container.clientHeight + 150);

        const messageZaps = this.zaps.get(messageId);

        // Find or create reactions row
        let reactionsRow = messageEl.querySelector('.reactions-row');
        if (!reactionsRow) {
            reactionsRow = document.createElement('div');
            reactionsRow.className = 'reactions-row';
            messageEl.appendChild(reactionsRow);
        }

        // Remove existing zap badges
        const existingZap = reactionsRow.querySelector('.zap-badge');
        if (existingZap) {
            existingZap.remove();
        }
        const existingZapBtn = reactionsRow.querySelector('.add-zap-btn');
        if (existingZapBtn) {
            existingZapBtn.remove();
        }

        // Only add badges if there are zaps
        if (messageZaps && messageZaps.amounts.size > 0) {
            // Calculate total zaps from the amounts map
            let totalZaps = 0;
            messageZaps.amounts.forEach(amount => {
                totalZaps += amount;
            });

            const zapBadge = document.createElement('span');
            zapBadge.className = 'zap-badge';
            zapBadge.innerHTML = `
    <svg class="zap-icon" viewBox="0 0 24 24">
        <path d="M13 2L3 14h8l-1 8 10-12h-8l1-8z"/>
    </svg>
    ${this.abbreviateNumber(totalZaps)}
`;

            const zapperCount = messageZaps.amounts.size;
            zapBadge.title = `${this.abbreviateNumber(zapperCount)} zapper${zapperCount > 1 ? 's' : ''} • ${this.abbreviateNumber(totalZaps)} sats total`;

            // Insert at beginning of reactions row
            reactionsRow.insertBefore(zapBadge, reactionsRow.firstChild);

            // Add quick zap button ONLY if zaps exist and not own message
            const pubkey = messageEl.dataset.pubkey;
            if (pubkey && pubkey !== this.pubkey) {
                const addZapBtn = document.createElement('span');
                addZapBtn.className = 'add-zap-btn';
                addZapBtn.innerHTML = `
        <svg viewBox="0 0 24 24">
            <path d="M11 2L1 14h8l-1 8 10-12h-8l1-8z" stroke="var(--text)" fill="var(--text)"/>
            <circle cx="19" cy="6" r="5" fill="var(--text)" stroke="none"></circle>
            <line x1="19" y1="4" x2="19" y2="8" stroke="var(--bg)" stroke-width="1.5" stroke-linecap="round"></line>
            <line x1="17" y1="6" x2="21" y2="6" stroke="var(--bg)" stroke-width="1.5" stroke-linecap="round"></line>
        </svg>
    `;
                addZapBtn.title = 'Quick zap';
                addZapBtn.onclick = async (e) => {
                    e.stopPropagation();
                    await this.handleQuickZap(messageId, pubkey, messageEl);
                };

                // Insert after zap badge
                reactionsRow.insertBefore(addZapBtn, zapBadge.nextSibling);
            }
        }

        // Auto-scroll to keep zaps visible if user was already at the bottom
        if (wasAtBottom) {
            this._scheduleScrollToBottom();
        }
    },

    async handleQuickZap(messageId, pubkey, messageEl) {
        // Get the author's nym
        const author = messageEl.dataset.author;

        // Show loading message
        this.displaySystemMessage(`Checking if @${author} can receive zaps...`);

        try {
            // Always fetch fresh to ensure we have the latest
            const lnAddress = await this.fetchLightningAddressForUser(pubkey);

            if (lnAddress) {
                // User has lightning address, show zap modal
                this.showZapModal(messageId, pubkey, author);
            } else {
                // No lightning address found
                this.displaySystemMessage(`@${author} cannot receive zaps (no lightning address set)`);
            }
        } catch (error) {
            this.displaySystemMessage(`Failed to check if @${author} can receive zaps`);
        }
    },

    // Close zap modal
    closeZapModal() {
        const modal = document.getElementById('zapModal');
        if (modal) modal.classList.remove('active');

        // Clear any payment check intervals
        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }
        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }

        // Close any zap receipt subscriptions
        if (this.shopZapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
            this.shopZapReceiptSubId = null;
        }
        if (this.zapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.zapReceiptSubId]);
            this.zapReceiptSubId = null;
        }

        // Reset modal state for regular zaps
        const zapAmountsContainer = document.querySelector('.zap-amounts');
        if (zapAmountsContainer) {
            zapAmountsContainer.style.display = 'grid';
        }

        const customAmountInput = document.getElementById('zapCustomAmount');
        if (customAmountInput) {
            customAmountInput.value = '';
            customAmountInput.readOnly = false;
            customAmountInput.style.background = '';
            customAmountInput.style.cursor = '';
        }

        const commentSection = document.querySelector('.zap-comment');
        if (commentSection) {
            commentSection.style.display = 'block';
        }

        const amountSection = document.getElementById('zapAmountSection');
        const invoiceSection = document.getElementById('zapInvoiceSection');

        if (amountSection) amountSection.style.display = 'block';
        if (invoiceSection) invoiceSection.style.display = 'none';

        // Restore modal actions (may have been replaced by shop success screen)
        const modalActions = document.querySelector('#zapModal .modal-actions');
        if (modalActions) {
            modalActions.innerHTML = `
                <button class="icon-btn" onclick="nym.closeZapModal()">Cancel</button>
                <button class="send-btn" id="zapSendBtn" onclick="nym.generateZapInvoice()">Generate Invoice</button>
            `;
        }

        // Clear contexts
        this.currentZapTarget = null;
        this.currentZapInvoice = null;
        this.currentPurchaseContext = null;
        this.currentShopInvoice = null;

        // Clear selected amounts
        document.querySelectorAll('.zap-amount-btn').forEach(btn => {
            btn.classList.remove('selected');
        });
    },

    // Copy invoice to clipboard
    copyZapInvoice() {
        if (!this.currentZapInvoice) return;

        navigator.clipboard.writeText(this.currentZapInvoice.pr).then(() => {
            // Show feedback
            const btn = event.target;
            const originalText = btn.textContent;
            btn.textContent = 'Copied!';
            setTimeout(() => {
                btn.textContent = originalText;
            }, 2000);
        }).catch(err => {
            this.displaySystemMessage('Failed to copy invoice');
        });
    },

    // Open invoice in wallet
    openInWallet() {
        // heck both currentZapInvoice and currentShopInvoice
        const invoice = this.currentZapInvoice || this.currentShopInvoice;
        if (!invoice) return;

        // Try multiple methods to open wallet
        const invoiceStr = invoice.pr;

        // Check if invoice already has lightning: prefix
        const invoiceToOpen = invoiceStr.toLowerCase().startsWith('lightning:') ?
            invoiceStr : `lightning:${invoiceStr}`;

        // Try Flutter bridge first (for Nymchat native app)
        if (window.nymOpenExternal) {
            window.nymOpenExternal(invoiceToOpen);
        } else {
            // Fallback to standard window.open (for regular browsers)
            window.open(invoiceToOpen, '_blank');
        }

        // Also copy to clipboard as fallback (just the raw invoice)
        navigator.clipboard.writeText(invoiceStr).then(() => {
            this.displaySystemMessage('Invoice copied - paste in your wallet');
        }).catch(err => {
            this.displaySystemMessage('Failed to copy invoice');
        });
    },

    async cmdZap(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /zap nym, /zap nym#xxxx, or /zap [pubkey]');
            return;
        }

        const targetInput = args.trim().replace(/^@/, '');

        // Check if input is a pubkey (64 hex characters)
        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            const targetPubkey = targetInput.toLowerCase();

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't zap yourself");
                return;
            }

            const targetNym = this.getNymFromPubkey(targetPubkey);
            const displayNym = this.formatNymWithPubkey(targetNym, targetPubkey);
            this.displaySystemMessage(`Checking if @${displayNym} can receive zaps...`, 'system', { html: true });

            const lnAddress = await this.fetchLightningAddressForUser(targetPubkey);

            if (lnAddress) {
                this.showProfileZapModal(targetPubkey, targetNym, lnAddress);
            } else {
                this.displaySystemMessage(`@${displayNym} cannot receive zaps (no lightning address set)`, 'system', { html: true });
            }
            return;
        }

        const hashIndex = targetInput.indexOf('#');
        let searchNym = targetInput;
        let searchSuffix = null;

        if (hashIndex !== -1) {
            searchNym = targetInput.substring(0, hashIndex);
            searchSuffix = targetInput.substring(hashIndex + 1);
        }

        // Find matching users
        const matches = [];
        this.users.forEach((user, pubkey) => {
            const baseNym = this.stripPubkeySuffix(user.nym);
            if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                if (searchSuffix) {
                    if (pubkey.endsWith(searchSuffix)) {
                        matches.push({ nym: user.nym, pubkey: pubkey });
                    }
                } else {
                    matches.push({ nym: user.nym, pubkey: pubkey });
                }
            }
        });

        if (matches.length === 0) {
            this.displaySystemMessage(`User ${targetInput} not found`);
            return;
        }

        if (matches.length > 1 && !searchSuffix) {
            const matchList = matches.map(m =>
                `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
            ).join(', ');
            this.displaySystemMessage(`Multiple users found with nym "${this.escapeHtml(searchNym)}": ${matchList}`, 'system', { html: true });
            this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
            return;
        }

        const targetPubkey = matches[0].pubkey;
        const targetNym = matches[0].nym;

        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You can't zap yourself");
            return;
        }

        // Check for lightning address
        const displayNym = this.formatNymWithPubkey(targetNym, targetPubkey);
        this.displaySystemMessage(`Checking if @${displayNym} can receive zaps...`, 'system', { html: true });

        const lnAddress = await this.fetchLightningAddressForUser(targetPubkey);

        if (lnAddress) {
            // Show zap modal for profile zap (no messageId)
            this.showProfileZapModal(targetPubkey, targetNym, lnAddress);
        } else {
            this.displaySystemMessage(`@${displayNym} cannot receive zaps (no lightning address set)`, 'system', { html: true });
        }
    },

});
