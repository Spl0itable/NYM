// zaps.js - Lightning zaps: invoices, modals, receipts, message/profile zaps, wallets

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
            if (!lnAddress || typeof lnAddress !== 'string') {
                throw new Error('No lightning address available');
            }
            const [username, domain] = lnAddress.split('@');
            if (!username || !domain) {
                throw new Error('Invalid lightning address format');
            }

            // Fetch LNURL endpoint via Cloudflare proxy
            const lnurlResponse = await this.proxiedJsonFetch(`https://${domain}/.well-known/lnurlp/${username}`);
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

            // Fetch invoice via Cloudflare proxy
            const invoiceResponse = await this.proxiedJsonFetch(callbackUrl.toString());
            if (!invoiceResponse.ok) {
                throw new Error('Failed to fetch invoice');
            }

            const invoiceData = await invoiceResponse.json();

            if (invoiceData.pr) {
                return {
                    pr: invoiceData.pr,
                    successAction: invoiceData.successAction,
                    verify: invoiceData.verify,
                    // Provider's Nostr pubkey lets the worker validate the NIP-57 receipt
                    providerPubkey: lnurlData.nostrPubkey || null,
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

        // Trigger a batched profile fetch (kind 0 has LUD16/LUD06)
        try { this.queueProfileFetch(pubkey); } catch (_) { }

        // Wait for handleEvent(kind 0) to notice LUD16/LUD06 (or timeout)
        return await this.waitForLightningAddress(pubkey, 4000);
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
            const recipHtml = recipientPubkey ? this.getNymHtmlFromPubkey(recipientPubkey) : this.dimNymSuffix(recipientNym);
            this.displaySystemMessage(`${recipHtml} doesn't have a lightning address set`, 'system', { html: true });
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
        this._resetZapModalToDefault();
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = `Zapping @${recipientNym}`;
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        this._wireZapAutoGenerate(() => this.generateZapInvoice());

        // Show modal
        document.getElementById('zapModal').classList.add('active');
    },

    showProfileZapModal(recipientPubkey, recipientNym, lnAddress) {
        // Zapping Nymbot's profile means buying private-message credits
        if (this.isVerifiedBot(recipientPubkey)) {
            this.showBotCreditsModal();
            return;
        }
        // Store target info for profile zap (no messageId)
        this.currentZapTarget = {
            messageId: null, // No message ID for profile zaps
            recipientPubkey,
            recipientNym,
            lnAddress,
            isProfileZap: true
        };

        // Reset modal state
        this._resetZapModalToDefault();
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = `Zapping @${recipientNym}'s profile`;
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        this._wireZapAutoGenerate(() => this.generateZapInvoice());

        // Show modal
        document.getElementById('zapModal').classList.add('active');
    },

    // Convert a sats amount to Nymbot message credits
    _botCreditsForSats(sats) {
        sats = Math.max(0, Math.floor(Number(sats) || 0));
        let mult = 1;
        if (sats >= 5000) mult = 1.20;
        else if (sats >= 1000) mult = 1.15;
        else if (sats >= 500) mult = 1.10;
        return Math.floor((sats / 10) * mult);
    },

    // Preset purchase tiers for the Nymbot credit modal
    _botCreditTiers: [100, 500, 1000, 2500, 5000, 10000],

    // Capture the default sats buttons once so regular zaps can restore them
    _captureDefaultZapAmounts() {
        if (this._defaultZapAmountsHtml != null) return;
        const c = document.querySelector('.zap-amounts');
        if (c && !c.querySelector('.bot-credit-btn')) this._defaultZapAmountsHtml = c.innerHTML;
    },

    // Restore the regular sats buttons and hide the credit estimate line
    _resetZapModalToDefault() {
        const c = document.querySelector('.zap-amounts');
        if (c && this._defaultZapAmountsHtml != null && c.querySelector('.bot-credit-btn')) {
            c.innerHTML = this._defaultZapAmountsHtml;
        }
        const est = document.getElementById('botCreditEstimate');
        if (est) est.style.display = 'none';
        const note = document.querySelector('.bot-credit-pricing-note');
        if (note) note.remove();
        const input = document.getElementById('zapCustomAmount');
        if (input) input.oninput = null;
    },

    // Picking an amount (a preset button or the custom field + Enter) generates the invoice
    _wireZapAutoGenerate(generate, onAmountSelected) {
        const sendBtn = document.getElementById('zapSendBtn');
        if (sendBtn) sendBtn.style.display = 'none';
        const paidBtn = document.getElementById('zapPaidBtn');
        if (paidBtn) paidBtn.classList.add('nm-hidden');
        document.querySelectorAll('.zap-amount-btn').forEach(btn => {
            btn.classList.remove('selected');
            btn.onclick = (e) => {
                document.querySelectorAll('.zap-amount-btn').forEach(b => b.classList.remove('selected'));
                e.target.closest('.zap-amount-btn').classList.add('selected');
                document.getElementById('zapCustomAmount').value = '';
                if (onAmountSelected) onAmountSelected();
                generate();
            };
        });
        const custom = document.getElementById('zapCustomAmount');
        if (custom) {
            custom.onkeydown = (e) => {
                if (e.key !== 'Enter') return;
                e.preventDefault();
                document.querySelectorAll('.zap-amount-btn').forEach(b => b.classList.remove('selected'));
                generate();
            };
        }
    },

    _renderBotCreditAmounts() {
        const container = document.querySelector('.zap-amounts');
        if (!container) return;
        container.innerHTML = this._botCreditTiers.map(sats => {
            const credits = this._botCreditsForSats(sats);
            const satLabel = sats >= 1000 ? (sats / 1000) + 'K' : String(sats);
            return `<button class="zap-amount-btn bot-credit-btn" data-amount="${sats}">
                <span class="sats">${satLabel} sats</span>
                <span class="credits">${credits} credits</span>
            </button>`;
        }).join('');
        const note = this._botCreditPricingNote();
        let info = container.parentElement && container.parentElement.querySelector('.bot-credit-pricing-note');
        if (!info && container.parentElement) {
            info = document.createElement('div');
            info.className = 'bot-credit-pricing-note';
            container.insertAdjacentElement('afterend', info);
        }
        if (info) info.innerHTML = note;
    },

    _botCreditPricingNote() {
        return [
            '<strong>1 credit</strong> per general chat, creative writing, or translation reply.',
            '<strong>2 credits</strong> per coding or reasoning/math reply (uses larger, more capable models).',
            'Bulk bonus: +10% at 500 sats, +15% at 1K, +20% at 5K.'
        ].join('<br>');
    },

    // Show/refresh a live "X sats = Y messages" estimate for the custom amount
    _setupBotCreditEstimate() {
        const input = document.getElementById('zapCustomAmount');
        if (!input) return;
        let est = document.getElementById('botCreditEstimate');
        if (!est) {
            est = document.createElement('div');
            est.id = 'botCreditEstimate';
            est.className = 'zap-credit-estimate';
            const group = input.closest('.zap-custom-amount');
            if (group) group.insertAdjacentElement('afterend', est);
        }
        est.style.display = 'block';
        input.oninput = () => this._updateBotCreditEstimate();
        this._updateBotCreditEstimate();
    },

    _updateBotCreditEstimate() {
        const est = document.getElementById('botCreditEstimate');
        if (!est) return;
        const input = document.getElementById('zapCustomAmount');
        const selected = document.querySelector('.zap-amount-btn.selected');
        const sats = parseInt((input && input.value) || (selected ? selected.dataset.amount : ''), 10);
        if (!sats || sats <= 0) {
            est.textContent = 'Enter a custom amount to see how many messages you\'ll get.';
            return;
        }
        const credits = this._botCreditsForSats(sats);
        est.textContent = credits > 0
            ? `${sats.toLocaleString()} sats = ${credits} credit${credits === 1 ? '' : 's'} (1/msg, 2 for coding & reasoning)`
            : 'Amount too small to buy any credits.';
    },

    // Open the zap modal in "buy Nymbot credits" mode
    showBotCreditsModal(giftRecipient) {
        const botPubkey = this.verifiedBot.pubkey;
        const isGift = !!(giftRecipient && giftRecipient.pubkey);
        this.currentZapTarget = {
            messageId: null,
            recipientPubkey: botPubkey,
            recipientNym: 'Nymbot',
            isProfileZap: true,
            isBotCreditPurchase: true,
            giftRecipientPubkey: isGift ? giftRecipient.pubkey : null,
            giftRecipientNym: isGift ? giftRecipient.nym : null
        };
        this._captureDefaultZapAmounts();
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = isGift
            ? `Gift Nymbot credits to @${giftRecipient.nym}`
            : 'Buy Nymbot private message credits';
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        this._renderBotCreditAmounts();
        this._setupBotCreditEstimate();
        this._wireZapAutoGenerate(
            () => this.generateBotCreditInvoice(),
            () => this._updateBotCreditEstimate()
        );
        document.getElementById('zapModal').classList.add('active');
    },

    // Ask the bot worker to generate a credit-purchase invoice from Nymbot's
    // own Lightning address, then display and poll it via the normal zap UI.
    async generateBotCreditInvoice() {
        if (!this.currentZapTarget || !this.currentZapTarget.isBotCreditPurchase) return;
        if (this.zapCheckInterval) { clearInterval(this.zapCheckInterval); this.zapCheckInterval = null; }
        this.currentZapInvoice = null;

        const selectedBtn = document.querySelector('.zap-amount-btn.selected');
        const customAmount = document.getElementById('zapCustomAmount').value;
        const amount = parseInt(customAmount || (selectedBtn ? selectedBtn.dataset.amount : ''), 10);
        if (!amount || amount <= 0) {
            this.displaySystemMessage('Please select or enter an amount');
            return;
        }

        document.getElementById('zapAmountSection').style.display = 'none';
        document.getElementById('zapInvoiceSection').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status checking';
        document.getElementById('zapStatus').innerHTML = '<span class="loader"></span> Generating invoice...';

        try {
            const apiHost = this._getApiHost();
            if (!apiHost) throw new Error('Bot API unavailable');
            const auth = await this._signBotAuth('create-invoice');
            const credits = this._botCreditsForSats(amount);
            const giftNym = this.currentZapTarget.giftRecipientNym;
            const purchaseComment = giftNym
                ? `Nymbot credits gift for @${giftNym} — ${credits} message${credits === 1 ? '' : 's'}`
                : `Nymbot credits — ${credits} message${credits === 1 ? '' : 's'}`;
            let zapRequest = null;
            try { zapRequest = await this.createZapRequest(amount, purchaseComment); } catch (e) { }
            const reqBody = { action: 'create-invoice', pubkey: this.pubkey, auth, amountSats: amount, zapRequest, comment: purchaseComment };
            const giftPk = this.currentZapTarget.giftRecipientPubkey;
            if (giftPk && giftPk !== this.pubkey) reqBody.recipientPubkey = giftPk;
            const resp = await fetch(`https://${apiHost}/api/bot`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(reqBody)
            });
            const data = await resp.json().catch(() => ({}));
            if (!resp.ok || !data || data.error || !data.pr) {
                throw new Error((data && data.error) || 'Failed to generate invoice');
            }
            const invoice = { pr: data.pr, verify: data.verify, serverVerify: !!data.serverVerify, amount, invoiceId: data.invoiceId };
            this.currentZapInvoice = invoice;
            this._addPendingPurchase({ kind: 'credit', invoiceId: invoice.invoiceId, amount, recipientNym: giftNym || null });
            this.displayZapInvoice(invoice);
            if (invoice.verify) {
                // LUD-21: poll the verify URL
                this.checkZapPayment(invoice);
            } else if (invoice.serverVerify) {
                // No LUD-21 verify URL — the worker confirms payment via the bot wallet (NWC)
                this.checkBotCreditPaymentViaServer(invoice);
            } else {
                // Last resort: wait for the NIP-57 zap receipt
                this._listenForBotCreditReceipt(invoice);
            }
        } catch (error) {
            document.getElementById('zapStatus').className = 'zap-status';
            document.getElementById('zapStatus').textContent = `Failed: ${error.message}`;
        }
    },

    // Fallback payment detection when the bot wallet has no LUD-21 verify URL:
    // subscribe for the NIP-57 zap receipt (kind 9735) and match it to this
    // invoice by its bolt11 tag. handleZapReceipt picks up the match.
    _listenForBotCreditReceipt(invoice) {
        if (this._botCreditReceiptWait && this._botCreditReceiptWait.subId) {
            this.sendToRelay(["CLOSE", this._botCreditReceiptWait.subId]);
            if (this._botCreditReceiptWait.timer) clearTimeout(this._botCreditReceiptWait.timer);
        }
        const subId = 'botcredit-' + Math.random().toString(36).slice(2, 9);
        const wait = { subId, pr: invoice.pr, amount: invoice.amount, timer: null };
        this._botCreditReceiptWait = wait;
        this.sendToRelay(["REQ", subId, {
            kinds: [9735],
            "#p": [this.verifiedBot.pubkey],
            since: Math.floor(Date.now() / 1000) - 60,
            limit: 25
        }]);
        wait.timer = setTimeout(() => {
            if (this._botCreditReceiptWait === wait) {
                this.sendToRelay(["CLOSE", subId]);
                this._botCreditReceiptWait = null;
                const el = document.getElementById('zapStatus');
                if (el) {
                    el.style.display = 'block';
                    el.className = 'zap-status';
                    el.innerHTML = 'Payment not detected yet — if you paid, run ?balance shortly.';
                }
            }
        }, 180000);
    },

    // Poll the worker, which confirms the credit payment via the bot wallet (NWC)
    // even when no LUD-21 verify URL or NIP-57 receipt is available.
    checkBotCreditPaymentViaServer(invoice) {
        if (this._botCreditServerPoll) {
            clearInterval(this._botCreditServerPoll);
            this._botCreditServerPoll = null;
        }
        let checkCount = 0;
        const maxChecks = 180;
        this._botCreditServerPoll = setInterval(async () => {
            checkCount++;
            if (!this.currentZapInvoice || this.currentZapInvoice.invoiceId !== invoice.invoiceId) {
                clearInterval(this._botCreditServerPoll);
                this._botCreditServerPoll = null;
                return;
            }
            let paid = false;
            try { paid = await this._checkBotInvoicePaid(invoice.invoiceId); } catch (e) { }
            if (paid) {
                clearInterval(this._botCreditServerPoll);
                this._botCreditServerPoll = null;
                this.handleZapPaymentSuccess(invoice.amount);
            } else if (checkCount >= maxChecks) {
                clearInterval(this._botCreditServerPoll);
                this._botCreditServerPoll = null;
                const el = document.getElementById('zapStatus');
                if (el) {
                    el.style.display = 'block';
                    el.className = 'zap-status';
                    el.innerHTML = 'Payment not detected yet — if you paid, tap "I\'ve paid" or run ?balance shortly.';
                }
            }
        }, 2000);
    },

    async _checkBotInvoicePaid(invoiceId) {
        const apiHost = this._getApiHost();
        if (!apiHost) return false;
        const auth = await this._signBotAuth('check-invoice');
        const resp = await fetch(`https://${apiHost}/api/bot`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'check-invoice', pubkey: this.pubkey, auth, invoiceId })
        });
        const data = await resp.json().catch(() => ({}));
        return !!(data && data.paid);
    },

    // "I've paid" button: immediately re-check the current invoice and, if the
    // bot wallet confirms payment, finalize the purchase. Works for shop items,
    // Nymbot credits, and LUD-21 zaps.
    async manualCheckPayment() {
        const el = document.getElementById('zapStatus');
        if (el) {
            el.style.display = 'block';
            el.className = 'zap-status checking';
            el.innerHTML = '<span class="loader"></span> Checking payment...';
        }
        try {
            if (this.currentShopInvoice && this.currentShopInvoice.invoiceId) {
                const paid = await this._checkShopInvoicePaid(this.currentShopInvoice.invoiceId);
                if (paid) { await this.handleShopPaymentSuccess(); return; }
            } else if (this.currentZapInvoice && this.currentZapInvoice.invoiceId &&
                this.currentZapTarget && this.currentZapTarget.isBotCreditPurchase) {
                const paid = await this._checkBotInvoicePaid(this.currentZapInvoice.invoiceId);
                if (paid) { this.handleZapPaymentSuccess(this.currentZapInvoice.amount); return; }
            } else if (this.currentZapInvoice && (this.currentZapInvoice.verify || this.currentZapInvoice.providerPubkey || this.currentZapInvoice.receipt)) {
                const paid = await this._serverVerifyZapPaid(this.currentZapInvoice);
                if (paid) { this.handleZapPaymentSuccess(this.currentZapInvoice.amount); return; }
            }
            if (el) {
                el.className = 'zap-status';
                el.innerHTML = 'Not paid yet — complete the payment in your wallet, then tap again.';
            }
        } catch (e) {
            if (el) {
                el.className = 'zap-status';
                el.innerHTML = 'Could not check yet — try again in a moment.';
            }
        }
    },

    // After a Nymbot credit invoice is paid, ask the worker to verify the
    // payment (server-side, against the invoice it issued) and add credits.
    // receipt is the NIP-57 zap receipt, used when the wallet has no LUD-21
    // verify URL.
    async _claimBotCredits(invoiceId, recipientNym, receipt) {
        if (!invoiceId) {
            this.displaySystemMessage('Nymbot credit purchase: payment received but the invoice reference was lost. Run ?balance shortly — if credits are missing, contact support.');
            return false;
        }
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) return false;
            const auth = await this._signBotAuth('claim-credits');
            const reqBody = { action: 'claim-credits', pubkey: this.pubkey, auth, invoiceId };
            if (receipt) reqBody.receipt = receipt;
            if (this.nym) reqBody.gifterNym = this.nym + '#' + this.getPubkeySuffix(this.pubkey);
            let data = null, status = 0;
            for (let attempt = 0; attempt < 5; attempt++) {
                const resp = await fetch(`https://${apiHost}/api/bot`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(reqBody)
                });
                status = resp.status;
                data = await resp.json().catch(() => ({}));
                if (resp.ok && data && !data.error) break;
                if (resp.status === 402) { await new Promise(r => setTimeout(r, 2000)); continue; }
                break;
            }
            if (data && typeof data.credited === 'number') {
                if (data.gift) {
                    if (data.giftEvent) {
                        try { this.sendDMToRelays(['EVENT', data.giftEvent]); } catch (e) { }
                    }
                    this.displaySystemMessage(`Gifted +${data.credited} Nymbot credits to @${recipientNym || 'user'}.`);
                } else {
                    this._setBotCreditDisplay(data.balance);
                    this.displaySystemMessage(`Nymbot credits added: +${data.credited}. New balance: ${data.balance} private message${data.balance === 1 ? '' : 's'}.`);
                }
                this._removePendingPurchase(invoiceId);
                return true;
            }
            if (status === 409) { this._removePendingPurchase(invoiceId); return true; }
            this.displaySystemMessage('Nymbot credit purchase: ' + ((data && data.error) || 'could not confirm credit'));
            return false;
        } catch (e) {
            this.displaySystemMessage('Nymbot credit purchase failed to confirm. Your payment went through — run ?balance shortly.');
            return false;
        }
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
                    originalKind = String(this.channelWire(this.currentGeohash).kind);
                }
                zapRequest.tags.push(['k', originalKind]);
            } else {
                // Profile zap: tag k=0 so the receipt can be filtered by the
                // recipient's broad #k subscription alongside message zaps.
                zapRequest.tags.push(['k', '0']);
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
        if (this._zapReceiptWait) {
            if (this._zapReceiptWait.timer) clearTimeout(this._zapReceiptWait.timer);
            this._zapReceiptWait = null;
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

        let comment = (document.getElementById('zapComment').value || '').trim();
        if (!comment) {
            // Label the payment so the recipient knows what it was for
            comment = this.currentZapTarget.messageId ? 'Zap for your message' : 'Profile zap';
        }

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

        // Center the QR via a class (no inline styles — keeps us CSP-compliant)
        qrContainer.classList.add('nm-zap-7');

        // Create QR code element with white border styling
        const qrDiv = document.createElement('div');
        qrDiv.id = 'zapQRCodeCanvas';
        qrDiv.className = 'nm-zap-8';
        qrContainer.appendChild(qrDiv);

        // Generate QR using the invoice (QRCode lib loaded on demand)
        (async () => {
            try {
                if (typeof QRCode === 'undefined') await window.loadScriptOnce(window.NYM_CDN.qrcode);
                new QRCode(qrDiv, {
                    text: invoice.pr,  // Just the raw invoice, no lightning: prefix
                    width: 200,
                    height: 200,
                    colorDark: "#000000",
                    colorLight: "#ffffff",
                    correctLevel: QRCode.CorrectLevel.L
                });
            } catch (err) {
                qrContainer.innerHTML = `
    <div class="nm-zap-1">
        <div class="nm-zap-2">Lightning Invoice</div>
        <div class="nm-zap-3">${this.escapeHtml(invoice.pr.substring(0, 60))}...</div>
        <div class="nm-zap-4">QR generation failed - copy invoice manually</div>
    </div>
`;
            }
        })();

        // Reveal the "I've paid" action in the footer, next to Cancel. The
        // generic send/close button stays hidden — Cancel already dismisses the
        // modal, so we don't need a separate Close.
        const paidBtn = document.getElementById('zapPaidBtn');
        if (paidBtn) paidBtn.classList.remove('nm-hidden');
        const sendBtn = document.getElementById('zapSendBtn');
        if (sendBtn) { sendBtn.style.display = 'none'; sendBtn.onclick = null; }
    },

    // Ask the worker whether a zap invoice was paid
    async _serverVerifyZapPaid(invoice, receipt) {
        if (!invoice) return false;
        const base = this._getProxyBaseUrl();
        if (!base) return false;
        try {
            const resp = await fetch(`${base}?action=zap-verify`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    pr: invoice.pr,
                    verifyUrl: invoice.verify || null,
                    providerPubkey: invoice.providerPubkey || null,
                    receipt: receipt || invoice.receipt || null
                })
            });
            const data = await resp.json().catch(() => ({}));
            return !!(data && data.paid);
        } catch (_) {
            return false;
        }
    },

    // Check if payment was made. The LUD-21 verify URL is the authoritative,
    // invoice-scoped signal, confirmed server-side. Only when the provider
    // returns no verify URL do we fall back to the NIP-57 receipt
    async checkZapPayment(invoice) {
        if (!invoice.verify) {
            // No verify URL, fall back to the (best-effort) zap receipt
            this.listenForZapReceipt();
            return;
        }

        // Clear any existing payment check interval to prevent stale invoice polling
        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }

        let checkCount = 0;
        const maxChecks = 180; // Poll for up to 3 minutes

        this.zapCheckInterval = setInterval(async () => {
            checkCount++;

            const paid = await this._serverVerifyZapPaid(invoice);
            if (paid) {
                clearInterval(this.zapCheckInterval);
                this.zapCheckInterval = null;
                this.handleZapPaymentSuccess(invoice.amount);
            } else if (checkCount >= maxChecks) {
                clearInterval(this.zapCheckInterval);
                this.zapCheckInterval = null;
                const zapStatusEl = document.getElementById('zapStatus');
                if (zapStatusEl) {
                    zapStatusEl.style.display = 'block';
                    zapStatusEl.className = 'zap-status';
                    zapStatusEl.innerHTML = 'Payment timeout - please check your wallet';
                }
            }
        }, 1000); // Check every second
    },

    // Listen for the NIP-57 zap receipt and confirm payment by matching the
    // receipt's bolt11 to our invoice. Works for both message zaps and direct
    // profile zaps (which carry no event id)
    listenForZapReceipt() {
        const target = this.currentZapTarget;
        const invoice = this.currentZapInvoice;
        if (!target || !invoice) return;

        // Close any existing zap receipt subscription to prevent stale matching
        if (this.zapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.zapReceiptSubId]);
            this.zapReceiptSubId = null;
        }
        if (this._zapReceiptWait && this._zapReceiptWait.timer) {
            clearTimeout(this._zapReceiptWait.timer);
        }

        const subId = "zap-receipt-" + Math.random().toString(36).substring(7);
        this.zapReceiptSubId = subId;
        this._zapReceiptWait = {
            subId,
            pr: invoice.pr,
            amount: invoice.amount,
            messageId: target.messageId || null,
            timer: null
        };

        // Filter by recipient pubkey (always p-tagged on the receipt) rather
        // than event id, so profile zaps resolve too. bolt11 disambiguates.
        this.sendToRelay(["REQ", subId, {
            kinds: [9735],
            "#p": [target.recipientPubkey],
            since: Math.floor(Date.now() / 1000) - 60,
            limit: 25
        }]);

        this._zapReceiptWait.timer = setTimeout(() => {
            if (this.zapReceiptSubId === subId) {
                this.sendToRelay(["CLOSE", subId]);
                this.zapReceiptSubId = null;
            }
            if (this._zapReceiptWait && this._zapReceiptWait.subId === subId) {
                this._zapReceiptWait = null;
                const el = document.getElementById('zapStatus');
                if (el) {
                    el.style.display = 'block';
                    el.className = 'zap-status';
                    el.innerHTML = 'Payment not detected yet — if you paid, it may take a moment to confirm.';
                }
            }
        }, 180000);
    },

    // Handle successful payment
    handleZapPaymentSuccess(amount) {
        if (!this.currentZapTarget) return;

        // Capture credit-purchase details before closeZapModal clears state
        const isBotCreditPurchase = !!this.currentZapTarget.isBotCreditPurchase;
        const botCreditInvoiceId = this.currentZapInvoice && this.currentZapInvoice.invoiceId;
        const botCreditReceipt = (this.currentZapInvoice && this.currentZapInvoice.receipt) || null;
        const botCreditGiftNym = this.currentZapTarget.giftRecipientNym || null;

        window.nymHapticTap && window.nymHapticTap();

        // Clear check interval
        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }
        if (this._botCreditServerPoll) {
            clearInterval(this._botCreditServerPoll);
            this._botCreditServerPoll = null;
        }

        // Update UI
        document.getElementById('zapInvoiceDisplay').style.display = 'none';
        const paidBtn = document.getElementById('zapPaidBtn');
        if (paidBtn) paidBtn.classList.add('nm-hidden');
        document.getElementById('zapStatus').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status paid';
        document.getElementById('zapStatus').innerHTML = `
<div class="nm-zap-5">⚡</div>
<div>Zap sent successfully!</div>
<div class="nm-zap-6">${amount} sats</div>
`;

        if (isBotCreditPurchase) {
            this._claimBotCredits(botCreditInvoiceId, botCreditGiftNym, botCreditReceipt);
        }

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

        // Nymbot credit purchase (no LUD-21 verify): match the receipt to the
        // pending invoice by bolt11. This is a profile zap, so it has no e tag.
        if (this._botCreditReceiptWait && boltTag && boltTag[1] &&
            String(boltTag[1]).toLowerCase() === String(this._botCreditReceiptWait.pr).toLowerCase()) {
            const wait = this._botCreditReceiptWait;
            this._botCreditReceiptWait = null;
            if (wait.timer) clearTimeout(wait.timer);
            if (wait.subId) this.sendToRelay(["CLOSE", wait.subId]);
            if (this.currentZapInvoice) this.currentZapInvoice.receipt = event;
            this.handleZapPaymentSuccess(wait.amount);
            return;
        }

        // Shop purchase (no LUD-21 verify): match the receipt to the pending
        // shop invoice by bolt11, then confirm the purchase server-side.
        if (this._shopReceiptWait && boltTag && boltTag[1] &&
            String(boltTag[1]).toLowerCase() === String(this._shopReceiptWait.pr).toLowerCase()) {
            const wait = this._shopReceiptWait;
            this._shopReceiptWait = null;
            if (wait.timer) clearTimeout(wait.timer);
            if (wait.subId) this.sendToRelay(["CLOSE", wait.subId]);
            if (this.currentShopInvoice) this.currentShopInvoice.receipt = event;
            this.handleShopPaymentSuccess();
            return;
        }

        // Direct message/profile zap (no LUD-21 verify): match the receipt to
        // the pending invoice by bolt11, then finalize the modal. Profile zaps
        // have no e tag, so bolt11 is the only reliable match.
        if (this._zapReceiptWait && boltTag && boltTag[1] &&
            String(boltTag[1]).toLowerCase() === String(this._zapReceiptWait.pr).toLowerCase()) {
            const wait = this._zapReceiptWait;
            this._zapReceiptWait = null;
            if (wait.timer) clearTimeout(wait.timer);
            if (wait.subId) {
                this.sendToRelay(["CLOSE", wait.subId]);
                if (this.zapReceiptSubId === wait.subId) this.zapReceiptSubId = null;
            }
            const amount = wait.amount || this.parseAmountFromBolt11(boltTag[1]);
            // Keep the receipt so the worker can validate it (e.g. on "I've paid")
            if (this.currentZapInvoice) this.currentZapInvoice.receipt = event;
            // Show the zap badge on our own message for message zaps
            if (wait.messageId) this._recordMessageZap(wait.messageId, this.pubkey, amount, event.id);
            this.handleZapPaymentSuccess(amount);
            return;
        }

        if (!boltTag) return;

        // Profile zap (no e tag): if it's tagged to us, notify and exit.
        if (!eTag) {
            if (pTag && pTag[1] === this.pubkey) {
                this._handleIncomingProfileZap(event, descriptionTag, boltTag);
            }
            return;
        }

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

                    // Verify the k tag is for one of our supported kinds. If
                    // missing, fall through (legacy compat) but only display
                    // if we actually have the message in storage.
                    const kTag = zapRequest.tags?.find(t => t[0] === 'k');
                    if (kTag && !['20000', '23333', '1059'].includes(kTag[1])) {
                        return;
                    }
                    if (!kTag && !this._messageIdKnown(messageId)) {
                        return;
                    }
                } catch (e) {
                    // Ignore parse errors
                }
            }

            // Track the zap and refresh the message badge (deduped by receipt id)
            const existing = this.zaps.get(messageId);
            if (existing && existing.receipts.has(event.id)) return;
            this._recordMessageZap(messageId, zapperPubkey, amount, event.id);

            // Check if this is for our current pending zap
            if (this.currentZapTarget &&
                this.currentZapTarget.messageId === messageId &&
                zapperPubkey === this.pubkey) {
                this.handleZapPaymentSuccess(amount);
            }

            if (pTag && pTag[1] === this.pubkey && zapperPubkey !== this.pubkey) {
                this._notifyZapToOurMessage(messageId, amount, zapperPubkey, event);
            }
        }
    },

    _messageIdKnown(messageId) {
        if (!messageId) return false;
        for (const msgs of this.messages.values()) {
            if (msgs.some(m => m.id === messageId)) return true;
        }
        if (this.pmMessages) {
            for (const msgs of this.pmMessages.values()) {
                if (msgs.some(m => m.id === messageId || m.nymMessageId === messageId)) return true;
            }
        }
        return false;
    },

    _handleIncomingProfileZap(event, descriptionTag, boltTag) {
        if (!this._profileZapReceipts) this._profileZapReceipts = new Set();
        if (this._profileZapReceipts.has(event.id)) return;
        this._profileZapReceipts.add(event.id);

        const amount = this.parseAmountFromBolt11(boltTag[1]);
        if (!amount) return;

        let zapperPubkey = event.pubkey;
        if (descriptionTag) {
            try {
                const zapRequest = JSON.parse(descriptionTag[1]);
                if (zapRequest.pubkey) zapperPubkey = zapRequest.pubkey;
                // If the zap request explicitly tagged a non-profile kind,
                // ignore — this isn't actually a profile zap.
                const kTag = zapRequest.tags?.find(t => t[0] === 'k');
                if (kTag && kTag[1] !== '0') return;
            } catch (_) { }
        }
        if (zapperPubkey === this.pubkey) return;

        const zapperNym = this.getNymFromPubkey(zapperPubkey);
        const ts = (event && event.created_at ? event.created_at * 1000 : Date.now());
        const sats = this.abbreviateNumber ? this.abbreviateNumber(amount) : String(amount);
        const body = `⚡ zapped ${sats} sats to your profile`;
        const channelInfo = {
            type: 'reaction',
            id: event.id,
            eventId: event.id,
            pubkey: zapperPubkey,
            sourceType: 'pm',
            sourcePubkey: zapperPubkey
        };
        const isHistorical = (Date.now() - ts) > 10000;
        if (isHistorical) this._addNotificationToHistory(zapperNym, body, channelInfo, ts);
        else this.showNotification(zapperNym, body, channelInfo, ts);
    },

    _notifyZapToOurMessage(messageId, amount, zapperPubkey, event) {
        const zapperNym = this.getNymFromPubkey(zapperPubkey);
        const ts = (event && event.created_at ? event.created_at * 1000 : Date.now());
        const eventId = (event && event.id) || '';

        let msgPreview = '';
        let channelInfo = {
            type: 'reaction',
            id: eventId,
            eventId,
            pubkey: zapperPubkey,
            messageId
        };

        const msgEl = document.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
        if (msgEl) {
            const raw = msgEl.dataset.rawContent || '';
            msgPreview = raw.split('\n').filter(l => !l.startsWith('>')).join(' ').trim();
        }
        if (!msgPreview) {
            for (const msgs of this.messages.values()) {
                const found = msgs.find(m => m.id === messageId);
                if (found) { msgPreview = (found.content || '').split('\n').filter(l => !l.startsWith('>')).join(' ').trim(); break; }
            }
        }
        if (!msgPreview) {
            for (const msgs of this.pmMessages.values()) {
                const found = msgs.find(m => m.id === messageId || m.nymMessageId === messageId);
                if (found) { msgPreview = (found.content || '').split('\n').filter(l => !l.startsWith('>')).join(' ').trim(); break; }
            }
        }

        for (const [key, msgs] of this.messages.entries()) {
            if (msgs.some(m => m.id === messageId)) {
                channelInfo.sourceType = 'geohash';
                const gh = key.startsWith('#') ? key.slice(1) : key;
                channelInfo.sourceChannel = gh;
                channelInfo.sourceGeohash = gh;
                break;
            }
        }
        if (!channelInfo.sourceType) {
            for (const [key, msgs] of this.pmMessages.entries()) {
                if (msgs.some(m => m.id === messageId || m.nymMessageId === messageId)) {
                    if (key.startsWith('group-')) {
                        channelInfo.sourceType = 'group';
                        channelInfo.sourceGroupId = key.slice(6);
                    } else if (key.startsWith('pm-')) {
                        channelInfo.sourceType = 'pm';
                        const parts = key.slice(3).split('-');
                        channelInfo.sourcePubkey = parts.find(p => p && p !== this.pubkey) || parts[0];
                    }
                    break;
                }
            }
        }

        if (msgPreview && msgPreview.length > 80) msgPreview = msgPreview.slice(0, 80) + '…';
        const sats = this.abbreviateNumber ? this.abbreviateNumber(amount) : String(amount);
        const body = msgPreview
            ? `⚡ zapped ${sats} sats to: "${msgPreview}"`
            : `⚡ zapped ${sats} sats to your message`;

        // Tag the notification so the modal can re-render the body with the
        // actual message text once it arrives (e.g. if the zapped message
        // isn't in local storage yet).
        channelInfo.zapMessageId = messageId;
        channelInfo.zapSats = sats;

        if (!msgPreview) this._fetchZappedMessage(messageId);

        const isHistorical = (Date.now() - ts) > 10000;
        if (isHistorical) this._addNotificationToHistory(zapperNym, body, channelInfo, ts);
        else this.showNotification(zapperNym, body, channelInfo, ts);
    },

    // Best-effort fetch of a zapped message we don't have yet. Stored events
    // flow back through handleRelayMessage → displayMessage → this.messages,
    // and the notifications modal re-reads message text at render time.
    _fetchZappedMessage(messageId) {
        if (!messageId || !/^[0-9a-f]{64}$/i.test(messageId)) return;
        if (!this._zapFetchInflight) this._zapFetchInflight = new Set();
        if (this._zapFetchInflight.has(messageId)) return;
        this._zapFetchInflight.add(messageId);
        try {
            const subId = 'zap-msg-' + Math.random().toString(36).slice(2, 9);
            this.sendToRelay(["REQ", subId, { ids: [messageId], limit: 1 }]);
            setTimeout(() => {
                try { this.sendToRelay(["CLOSE", subId]); } catch (_) { }
                this._zapFetchInflight.delete(messageId);
            }, 10000);
        } catch (_) {
            this._zapFetchInflight.delete(messageId);
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

    // Record a zap against a message and refresh its badge (deduped by receipt)
    _recordMessageZap(messageId, zapperPubkey, amount, receiptId) {
        if (!messageId || !amount) return;
        if (!this.zaps.has(messageId)) {
            this.zaps.set(messageId, { receipts: new Set(), amounts: new Map() });
        }
        const messageZaps = this.zaps.get(messageId);
        if (receiptId && messageZaps.receipts.has(receiptId)) return;
        if (receiptId) messageZaps.receipts.add(receiptId);
        const currentAmount = messageZaps.amounts.get(zapperPubkey) || 0;
        messageZaps.amounts.set(zapperPubkey, currentAmount + amount);
        this.updateMessageZaps(messageId);
    },

    // Update message with zap display
    updateMessageZaps(messageId) {
        const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
        if (!messageEl) return;

        // Capture scroll state before modifying DOM so we can auto-scroll if needed
        const container = document.getElementById('messagesScroller');
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
            <path fill-rule="evenodd" clip-rule="evenodd" d="M19 1a.75.75 0 0 1 .75.75v2h2a.75.75 0 0 1 0 1.5h-2v2a.75.75 0 0 1-1.5 0v-2h-2a.75.75 0 0 1 0-1.5h2v-2A.75.75 0 0 1 19 1" fill="var(--text)"/>
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
        if (this._botCreditServerPoll) {
            clearInterval(this._botCreditServerPoll);
            this._botCreditServerPoll = null;
        }

        // Close any zap receipt subscriptions
        if (this.zapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.zapReceiptSubId]);
            this.zapReceiptSubId = null;
        }
        if (this._zapReceiptWait) {
            if (this._zapReceiptWait.timer) clearTimeout(this._zapReceiptWait.timer);
            this._zapReceiptWait = null;
        }

        // Reset modal state for regular zaps
        this._resetZapModalToDefault();
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
                <button class="icon-btn" data-action="closeZapModal">Cancel</button>
                <button class="send-btn nm-hidden" id="zapPaidBtn" data-action="manualCheckPayment">I've paid</button>
                <button class="send-btn nm-hidden" id="zapSendBtn"></button>
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
        // Check both currentZapInvoice and currentShopInvoice
        const invoice = this.currentZapInvoice || this.currentShopInvoice;
        if (!invoice) return;

        const invoiceStr = invoice.pr;

        // Build a lightning: URI (don't double-prefix)
        const invoiceToOpen = invoiceStr.toLowerCase().startsWith('lightning:') ?
            invoiceStr : `lightning:${invoiceStr}`;

        let launched = true;
        if (window.nymOpenExternal) {
            launched = window.nymOpenExternal(invoiceToOpen) !== false;
        } else {
            launched = !!window.open(invoiceToOpen, '_blank');
        }

        // Always copy the raw invoice as a fallback so the user can paste it.
        navigator.clipboard.writeText(invoiceStr).then(() => {
            this.displaySystemMessage(launched
                ? 'Invoice copied - paste in your wallet'
                : 'No Lightning wallet found to open the invoice. It has been copied - paste it into your wallet.');
        }).catch(() => {
            this.displaySystemMessage(launched
                ? 'Opening your wallet…'
                : 'No Lightning wallet found to open the invoice. Copy it manually to pay.');
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
