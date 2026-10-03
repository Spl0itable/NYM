// zaps.js - Lightning zaps: invoices, modals, receipts, message/profile zaps, wallets

Object.assign(NYM.prototype, {

    _backfillZapReceipts(messageIds) {
        if (!Array.isArray(messageIds)) return;
        const seen = new Set();
        const ids = [];
        for (const id of messageIds) {
            if (this._isNostrHex64(id) && !seen.has(id)) {
                seen.add(id);
                ids.push(id);
                if (ids.length >= 500) break;
            }
        }
        if (ids.length === 0) return;
        // Zaps are archived to D1; only backfill from relays when D1 is unavailable.
        if (!this._getApiHost || !this._getApiHost()) {
            const subId = 'zap-bf-' + Math.random().toString(36).slice(2, 9);
            try {
                this.sendToRelay(["REQ", subId, { kinds: [9735], "#e": ids, limit: 500 }]);
                setTimeout(() => { try { this.sendToRelay(["CLOSE", subId]); } catch (_) { } }, 10000);
            } catch (_) { }
        }
        this._backfillZapReceiptsFromD1(ids, this.inPMMode ? 'pm' : 'channel');
    },

    async _backfillZapReceiptsFromD1(ids, scope) {
        if (!Array.isArray(ids) || ids.length === 0) return;
        if (!this._getApiHost || !this._getApiHost()) return;
        if (typeof this._storageApiStream !== 'function') return;
        try {
            const resp = await this._storageApiStream('zap-get', { scope, ids }, false);
            const evs = [];
            await this._readNdjsonStream(resp, (ev) => { if (ev) evs.push(ev); });
            for (const ev of evs) {
                if (!(await this._verifyRelayEventAsync(ev))) continue;
                try { this.handleZapReceipt(ev); } catch (_) { }
            }
        } catch (_) { }
    },

    _archiveZapReceipt(event, eTag, descriptionTag) {
        if (!event || event.kind !== 9735 || typeof event.id !== 'string') return;
        if (!this.pubkey || !this._getApiHost || !this._getApiHost()) return;
        let scope = null;
        if (descriptionTag && descriptionTag[1]) {
            try {
                const req = JSON.parse(descriptionTag[1]);
                const kTag = req && Array.isArray(req.tags) && req.tags.find(t => t[0] === 'k');
                if (kTag) {
                    if (kTag[1] === '20000' || kTag[1] === '23333') scope = 'channel';
                    else if (kTag[1] === '1059') scope = 'pm';
                    else if (kTag[1] === '0') scope = 'profile';
                }
            } catch (_) { }
        }
        if (!scope) return;
        // Profile zaps have no e tag; the server keys them on the recipient pubkey.
        if (scope !== 'profile') {
            const targetId = eTag && eTag[1];
            if (!targetId || !this._isNostrHex64(targetId)) return;
        }
        if (!this._zapArchivedIds) this._zapArchivedIds = new Set();
        if (this._zapArchivedIds.has(event.id)) return;
        this._zapArchivedIds.add(event.id);
        if (this._zapArchivedIds.size > 6000) {
            this._zapArchivedIds = new Set(Array.from(this._zapArchivedIds).slice(-4000));
        }
        if (!this._zapArchiveQueue) this._zapArchiveQueue = [];
        this._zapArchiveQueue.push(event);
        if (this._zapArchiveQueue.length > 300) this._zapArchiveQueue.shift();
        if (this._zapArchiveFlushTimer) return;
        this._zapArchiveFlushTimer = setTimeout(() => {
            this._zapArchiveFlushTimer = null;
            this._flushZapArchive();
        }, 4000);
    },

    async _flushZapArchive() {
        if (!this._zapArchiveQueue || this._zapArchiveQueue.length === 0) return;
        const batch = this._zapArchiveQueue.splice(0, 100);
        try {
            await this._storageApiRequest('zap-put', { events: batch });
        } catch (_) { }
        if (this._zapArchiveQueue.length > 0 && !this._zapArchiveFlushTimer) {
            this._zapArchiveFlushTimer = setTimeout(() => {
                this._zapArchiveFlushTimer = null;
                this._flushZapArchive();
            }, 4000);
        }
    },

    PROJECT_LIGHTNING_ADDRESSES: ['69420@wallet.yakihonne.com', '69420@cake.cash'],

    lightningAddressesForPubkey(pubkey) {
        if (!pubkey) return [];
        const own = [
            this.verifiedBot && this.verifiedBot.pubkey,
            this.verifiedDeveloper && this.verifiedDeveloper.pubkey
        ];
        return own.indexOf(pubkey) === -1 ? [] : this.PROJECT_LIGHTNING_ADDRESSES.slice();
    },

    // One bad wallet (host down, bad LNURL, amount out of range) should not fail the zap.
    async fetchLightningInvoiceWithFallback(addresses, amountSats, comment) {
        const list = (addresses || []).filter((a, i, arr) => a && arr.indexOf(a) === i);
        let lastError = new Error('No lightning address available');
        for (const address of list) {
            try {
                const invoice = await this.fetchLightningInvoice(address, amountSats, comment);
                if (invoice && invoice.pr) return invoice;
            } catch (err) {
                lastError = err;
            }
        }
        throw lastError;
    },

    async fetchLightningInvoice(lnAddress, amountSats, comment) {
        try {
            if (!lnAddress || typeof lnAddress !== 'string') {
                throw new Error('No lightning address available');
            }
            const [username, domain] = lnAddress.split('@');
            if (!username || !domain) {
                throw new Error('Invalid lightning address format');
            }

            const lnurlResponse = await this.proxiedJsonFetch(`https://${domain}/.well-known/lnurlp/${username}`);
            if (!lnurlResponse.ok) {
                throw new Error('Failed to fetch LNURL endpoint');
            }

            const lnurlData = await lnurlResponse.json();

            const amountMillisats = parseInt(amountSats) * 1000;

            if (amountMillisats < lnurlData.minSendable || amountMillisats > lnurlData.maxSendable) {
                throw new Error(`Amount must be between ${lnurlData.minSendable / 1000} and ${lnurlData.maxSendable / 1000} sats`);
            }

            const callbackUrl = new URL(lnurlData.callback);
            callbackUrl.searchParams.set('amount', amountMillisats);

            if (comment && lnurlData.commentAllowed) {
                callbackUrl.searchParams.set('comment', comment.substring(0, lnurlData.commentAllowed));
            }

            if (lnurlData.allowsNostr && lnurlData.nostrPubkey) {
                const zapRequest = await this.createZapRequest(amountSats, comment);
                if (zapRequest) {
                    callbackUrl.searchParams.set('nostr', JSON.stringify(zapRequest));
                }
            }

            const invoiceResponse = await this.proxiedJsonFetch(callbackUrl.toString());
            if (!invoiceResponse.ok) {
                throw new Error('Failed to fetch invoice');
            }

            const invoiceData = await invoiceResponse.json();

            if (invoiceData.pr) {
                if (this.parseAmountFromBolt11(invoiceData.pr) !== parseInt(amountSats)) {
                    throw new Error('Invoice amount does not match the zap');
                }
                return {
                    pr: invoiceData.pr,
                    successAction: invoiceData.successAction,
                    verify: invoiceData.verify,
                    // Provider's Nostr pubkey lets the worker validate the NIP-57 receipt.
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

    notifyLightningAddress(pubkey, address) {
        const waiters = this.pendingLightningWaiters.get(pubkey);
        if (!waiters) return;
        for (const resolve of Array.from(waiters)) {
            try { resolve(address); } catch (_) { }
        }
        this.pendingLightningWaiters.delete(pubkey);
    },

    waitForLightningAddress(pubkey, timeoutMs = 8000) {
        if (this.userLightningAddresses.has(pubkey)) {
            return Promise.resolve(this.userLightningAddresses.get(pubkey));
        }

        return new Promise((resolve) => {
            const resolver = (addr) => resolve(addr || null);

            if (!this.pendingLightningWaiters.has(pubkey)) {
                this.pendingLightningWaiters.set(pubkey, new Set());
            }
            const set = this.pendingLightningWaiters.get(pubkey);
            set.add(resolver);

            const timer = setTimeout(() => {
                const s = this.pendingLightningWaiters.get(pubkey);
                if (s) {
                    s.delete(resolver);
                    if (s.size === 0) this.pendingLightningWaiters.delete(pubkey);
                }
                resolve(null);
            }, timeoutMs);

            const wrapped = (addr) => {
                clearTimeout(timer);
                resolve(addr || null);
            };

            set.delete(resolver);
            set.add(wrapped);
        });
    },

    async fetchLightningAddressForUser(pubkey) {
        if (this.userLightningAddresses.has(pubkey)) {
            return this.userLightningAddresses.get(pubkey);
        }

        // Our own identities are known; never make the user wait on a relay.
        const known = this.lightningAddressesForPubkey(pubkey);
        if (known.length) {
            this.userLightningAddresses.set(pubkey, known[0]);
            return known[0];
        }

        try { this.requestUserProfile(pubkey); } catch (_) { }

        // Kind 0 carries LUD16/LUD06.
        try { this.queueProfileFetch(pubkey); } catch (_) { }

        return await this.waitForLightningAddress(pubkey, 4000);
    },

    async loadLightningAddress() {
        if (!this.pubkey) return;

        const saved = localStorage.getItem(`nym_lightning_address_${this.pubkey}`);
        if (saved) {
            this.lightningAddress = saved;
            this.updateLightningAddressDisplay();
            return;
        }

        const profileAddress = await this.fetchLightningAddressForUser(this.pubkey);
        if (profileAddress) {
            this.lightningAddress = profileAddress;
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

    showZapModal(messageId, recipientPubkey, recipientNym) {
        const lnAddress = this.userLightningAddresses.get(recipientPubkey);

        if (!lnAddress) {
            const recipHtml = recipientPubkey ? this.getNymHtmlFromPubkey(recipientPubkey) : this.dimNymSuffix(recipientNym);
            this.displaySystemMessage(`${recipHtml} doesn't have a lightning address set`, 'system', { html: true });
            return;
        }

        this.currentZapTarget = {
            messageId,
            recipientPubkey,
            recipientNym,
            lnAddress
        };

        this._resetZapModalToDefault();
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = `Zapping @${recipientNym}`;
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        this._wireZapAutoGenerate(() => this.generateZapInvoice());

        document.getElementById('zapModal').classList.add('active');
    },

    showProfileZapModal(recipientPubkey, recipientNym, lnAddress) {
        // Zapping Nymbot's profile means buying private-message credits.
        if (this.isVerifiedBot(recipientPubkey)) {
            this.showBotCreditsModal();
            return;
        }
        this.currentZapTarget = {
            messageId: null,
            recipientPubkey,
            recipientNym,
            lnAddress,
            isProfileZap: true
        };

        this._resetZapModalToDefault();
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = `Zapping @${recipientNym}'s profile`;
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        this._wireZapAutoGenerate(() => this.generateZapInvoice());

        document.getElementById('zapModal').classList.add('active');
    },

    _botBulkBonusFallback: [
        { bonus: 0.10, standardSats: 500, proSats: 5000 },
        { bonus: 0.15, standardSats: 1000, proSats: 10000 },
        { bonus: 0.20, standardSats: 5000, proSats: 50000 }
    ],

    _botBulkRows() {
        const served = this._botProCatalog && this._botProCatalog.bulkBonus;
        return (Array.isArray(served) && served.length) ? served : this._botBulkBonusFallback;
    },

    _botBulkMultiplier(sats, tier) {
        const key = tier === 'pro' ? 'proSats' : 'standardSats';
        let best = 0;
        for (const row of this._botBulkRows()) {
            const at = Number(row && row[key]) || 0;
            if (at > 0 && sats >= at) best = Math.max(best, Number(row.bonus) || 0);
        }
        return 1 + best;
    },

    _botBulkBonusLine(tier) {
        const key = tier === 'pro' ? 'proSats' : 'standardSats';
        const parts = this._botBulkRows()
            .slice()
            .sort((a, b) => (Number(a[key]) || 0) - (Number(b[key]) || 0))
            .map(row => {
                const at = Number(row[key]) || 0;
                return '+' + Math.round((Number(row.bonus) || 0) * 100) + '% at '
                    + (at >= 1000 ? (at / 1000) + 'K' : String(at));
            });
        return parts.length ? 'Bulk bonus: ' + parts.join(', ') + ' sats.' : '';
    },

    _botCreditsForSats(sats) {
        sats = Math.max(0, Math.floor(Number(sats) || 0));
        return Math.floor((sats / 10) * this._botBulkMultiplier(sats, 'standard'));
    },

    // Pro credits: 100 sats each, bulk bonuses at 10x thresholds (mirrors botProCreditsForSats in bot.js).
    _botProCreditsForSats(sats) {
        sats = Math.max(0, Math.floor(Number(sats) || 0));
        return Math.floor((sats / 100) * this._botBulkMultiplier(sats, 'pro'));
    },

    _botCreditsForSatsTier(sats) {
        return this._botCreditTier === 'pro' ? this._botProCreditsForSats(sats) : this._botCreditsForSats(sats);
    },

    _botCreditTiers: [100, 500, 1000, 2500, 5000, 10000],
    // Smallest Pro preset (2K sats = 20 credits) clears the largest per-message reserve (Claude Fable 5 at 16).
    _botProCreditPresets: [2000, 5000, 10000, 20000, 50000, 100000],

    _captureDefaultZapAmounts() {
        if (this._defaultZapAmountsHtml != null) return;
        const c = document.querySelector('.zap-amounts');
        if (c && !c.querySelector('.bot-credit-btn')) this._defaultZapAmountsHtml = c.innerHTML;
    },

    _resetZapModalToDefault() {
        const c = document.querySelector('.zap-amounts');
        if (c && this._defaultZapAmountsHtml != null && c.querySelector('.bot-credit-btn')) {
            c.innerHTML = this._defaultZapAmountsHtml;
        }
        const est = document.getElementById('botCreditEstimate');
        if (est) est.style.display = 'none';
        const note = document.querySelector('.bot-credit-pricing-note');
        if (note) note.remove();
        const toggle = document.getElementById('botCreditTierToggle');
        if (toggle) toggle.remove();
        const input = document.getElementById('zapCustomAmount');
        if (input) input.oninput = null;
    },

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
        const triggerCustom = () => {
            const val = parseInt(custom && custom.value, 10);
            if (!val || val <= 0) { if (custom) custom.focus(); return; }
            document.querySelectorAll('.zap-amount-btn').forEach(b => b.classList.remove('selected'));
            generate();
        };
        if (custom) {
            custom.onkeydown = (e) => {
                if (e.key !== 'Enter') return;
                e.preventDefault();
                triggerCustom();
            };
        }
        const customBtn = document.getElementById('zapCustomGenerateBtn');
        if (customBtn) {
            customBtn.onclick = (e) => {
                e.preventDefault();
                triggerCustom();
            };
        }
    },

    _renderBotCreditTierToggle(onTierChange) {
        const container = document.querySelector('.zap-amounts');
        if (!container || !container.parentElement) return;
        let toggle = document.getElementById('botCreditTierToggle');
        if (!toggle) {
            toggle = document.createElement('div');
            toggle.id = 'botCreditTierToggle';
            toggle.className = 'bot-credit-tier-toggle';
            container.insertAdjacentElement('beforebegin', toggle);
        }
        const isPro = this._botCreditTier === 'pro';
        toggle.innerHTML = `
            <button type="button" class="bot-credit-tier-btn${!isPro ? ' active' : ''}" data-tier="standard">Standard</button>
            <button type="button" class="bot-credit-tier-btn${isPro ? ' active' : ''}" data-tier="pro">Pro</button>`;
        toggle.querySelectorAll('.bot-credit-tier-btn').forEach(btn => {
            btn.onclick = () => {
                const tier = btn.dataset.tier === 'pro' ? 'pro' : 'standard';
                if (this._botCreditTier === tier) return;
                this._botCreditTier = tier;
                this._renderBotCreditTierToggle(onTierChange);
                if (onTierChange) onTierChange();
            };
        });
    },

    _renderBotCreditAmounts() {
        const container = document.querySelector('.zap-amounts');
        if (!container) return;
        const isPro = this._botCreditTier === 'pro';
        const presets = isPro ? this._botProCreditPresets : this._botCreditTiers;
        const word = isPro ? 'Pro' : 'credits';
        container.innerHTML = presets.map(sats => {
            const credits = this._botCreditsForSatsTier(sats);
            const satLabel = sats >= 1000 ? (sats / 1000) + 'K' : String(sats);
            return `<button class="zap-amount-btn bot-credit-btn" data-amount="${sats}">
                <span class="sats">${satLabel} sats</span>
                <span class="credits">${credits} ${word}</span>
            </button>`;
        }).join('');
        const note = isPro ? this._botProCreditPricingNote() : this._botCreditPricingNote();
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
            'Replies are metered on the tokens they use, charged in thousandths of a credit — a short question costs a fraction of one.',
            'Coding and reasoning/math cost more per token than general chat, creative writing or translation, because those routes use larger models.',
            'Repeated context is billed at a cached rate, so a long conversation does not re-pay for its own history.',
            this._botBulkBonusLine('standard')
        ].filter(Boolean).join('<br>');
    },

    _botProCreditPricingNote() {
        const metered = (this._botProModels || []).filter(m => Number(m.outUsdPerMTok) > 0);
        const models = (metered.length ? metered : (this._botProModels || [])).slice(0, 6).map(m =>
            Number(m.outUsdPerMTok) > 0
                ? `${this.escapeHtml(m.label)} (<strong>$${m.inUsdPerMTok}/M in, $${m.outUsdPerMTok}/M out</strong>)`
                : `${this.escapeHtml(m.label)} (<strong>${m.max > m.credits ? 'from ' : ''}${m.credits} credit${m.credits === 1 ? '' : 's'}</strong>)`
        ).join(' · ');
        return [
            '<strong>Pro credits</strong> unlock replies from a frontier model you pick with <code>?model</code> in the Nymbot chat.',
            'Metered on the tokens each reply uses: ' + models + '.',
            'Repeated context is billed at the cached rate, a tenth of the fresh one.',
            this._botBulkBonusLine('pro')
        ].filter(Boolean).join('<br>');
    },

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
        const isPro = this._botCreditTier === 'pro';
        const input = document.getElementById('zapCustomAmount');
        const selected = document.querySelector('.zap-amount-btn.selected');
        const sats = parseInt((input && input.value) || (selected ? selected.dataset.amount : ''), 10);
        if (!sats || sats <= 0) {
            est.textContent = isPro
                ? 'Enter a custom amount to see how many Pro credits you\'ll get.'
                : 'Enter a custom amount to see how many messages you\'ll get.';
            return;
        }
        const credits = this._botCreditsForSatsTier(sats);
        if (credits <= 0) {
            est.textContent = `Amount too small to buy any ${isPro ? 'Pro ' : ''}credits.`;
            return;
        }
        if (isPro) {
            est.textContent = `${sats.toLocaleString()} sats = ${credits} Pro credit${credits === 1 ? '' : 's'}`
                + ' — charged on the tokens each reply uses, so an ordinary question costs a fraction of one';
            return;
        }
        est.textContent = `${sats.toLocaleString()} sats = ${credits} credit${credits === 1 ? '' : 's'}`
            + ' — charged on the tokens each reply uses, so a short question costs a fraction of one';
    },

    showBotCreditsModal(giftRecipient, tier) {
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
        this._botCreditTier = tier === 'pro' ? 'pro' : 'standard';
        this._captureDefaultZapAmounts();
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = isGift
            ? `Gift Nymbot credits to @${giftRecipient.nym}`
            : 'Buy Nymbot private message credits';
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        const refreshTier = () => {
            this._renderBotCreditAmounts();
            this._updateBotCreditEstimate();
            this._wireZapAutoGenerate(
                () => this.generateBotCreditInvoice(),
                () => this._updateBotCreditEstimate()
            );
        };
        this._renderBotCreditTierToggle(refreshTier);
        this._renderBotCreditAmounts();
        this._setupBotCreditEstimate();
        this._wireZapAutoGenerate(
            () => this.generateBotCreditInvoice(),
            () => this._updateBotCreditEstimate()
        );
        document.getElementById('zapModal').classList.add('active');
    },

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
            const isPro = this._botCreditTier === 'pro';
            const credits = this._botCreditsForSatsTier(amount);
            const giftNym = this.currentZapTarget.giftRecipientNym;
            const creditWord = isPro
                ? `${credits} Pro credit${credits === 1 ? '' : 's'}`
                : `${credits} message${credits === 1 ? '' : 's'}`;
            const purchaseComment = giftNym
                ? `Nymbot ${isPro ? 'Pro ' : ''}credits gift for @${giftNym} — ${creditWord}`
                : `Nymbot ${isPro ? 'Pro ' : ''}credits — ${creditWord}`;
            const giftPk = this.currentZapTarget.giftRecipientPubkey;
            const anonBuy = !!(typeof this.botAnonReady === 'function' && this.botAnonReady() &&
                !(giftPk && giftPk !== this.pubkey));
            let zapRequest = null;
            try {
                zapRequest = anonBuy
                    ? this._botAnonZapRequest(amount, purchaseComment, this.verifiedBot.pubkey)
                    : await this.createZapRequest(amount, purchaseComment);
            } catch (e) { }
            const reqExtra = { amountSats: amount, zapRequest, comment: purchaseComment };
            if (isPro) reqExtra.tier = 'pro';
            if (giftPk && giftPk !== this.pubkey) reqExtra.recipientPubkey = giftPk;
            const { data } = await this._botMoneyRequest('create-invoice', reqExtra, { anon: anonBuy });
            if (!data || data.error || !data.pr) {
                throw new Error((data && data.error) || 'Failed to generate invoice');
            }
            const invoice = { pr: data.pr, verify: data.verify, serverVerify: !!data.serverVerify, amount, invoiceId: data.invoiceId, anon: anonBuy };
            this.currentZapInvoice = invoice;
            this._addPendingPurchase({ kind: 'credit', invoiceId: invoice.invoiceId, amount, recipientNym: giftNym || null, anon: anonBuy });
            this.displayZapInvoice(invoice);
            if (invoice.verify) {
                // LUD-21: poll the verify URL.
                this.checkZapPayment(invoice);
            } else if (invoice.serverVerify) {
                // No LUD-21 verify URL: the worker confirms payment via the bot wallet (NWC).
                this.checkBotCreditPaymentViaServer(invoice);
            } else {
                // Last resort: wait for the NIP-57 zap receipt.
                this._listenForBotCreditReceipt(invoice);
            }
        } catch (error) {
            document.getElementById('zapStatus').className = 'zap-status';
            document.getElementById('zapStatus').textContent = `Failed: ${error.message}`;
        }
    },

    // No LUD-21 verify URL: match the kind 9735 receipt by bolt11 (handleZapReceipt).
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

    // Confirms via the bot wallet (NWC) even without a LUD-21 verify URL or NIP-57 receipt.
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
            try { paid = await this._checkBotInvoicePaid(invoice.invoiceId, invoice.anon); } catch (e) { }
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

    async _checkBotInvoicePaid(invoiceId, anon) {
        const apiHost = this._getApiHost();
        if (!apiHost) return false;
        const { data } = await this._botMoneyRequest('check-invoice', { invoiceId }, { anon: !!anon });
        return !!(data && data.paid);
    },

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
                const paid = await this._checkBotInvoicePaid(this.currentZapInvoice.invoiceId, this.currentZapInvoice.anon);
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

    // Server-side verification against the issued invoice; receipt is used when there's no LUD-21 verify URL.
    async _claimBotCredits(invoiceId, recipientNym, receipt, anon) {
        if (!invoiceId) {
            this.displaySystemMessage('Nymbot credit purchase: payment received but the invoice reference was lost. Run ?balance shortly — if credits are missing, contact support.');
            return false;
        }
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) return false;
            const reqExtra = { invoiceId };
            if (receipt) reqExtra.receipt = receipt;
            if (this.nym && !anon) reqExtra.gifterNym = this.nym + '#' + this.getPubkeySuffix(this.pubkey);
            let data = null, status = 0;
            for (let attempt = 0; attempt < 5; attempt++) {
                const res = await this._botMoneyRequest('claim-credits', reqExtra, { anon: !!anon });
                status = res.status;
                data = res.data || {};
                if (status >= 200 && status < 300 && data && !data.error) break;
                if (status === 402) { await new Promise(r => setTimeout(r, 2000)); continue; }
                break;
            }
            if (data && typeof data.credited === 'number') {
                const isPro = data.tier === 'pro';
                if (data.gift) {
                    if (data.giftEvent) {
                        try { this.sendDMToRelays(['EVENT', data.giftEvent]); } catch (e) { }
                    }
                    this.displaySystemMessage(`Gifted +${data.credited} Nymbot ${isPro ? 'Pro ' : ''}credits to @${recipientNym || 'user'}.`);
                } else if (isPro) {
                    this._setBotProCreditDisplay(data.balance);
                    this.displaySystemMessage(`Nymbot Pro credits added: +${data.credited}. Pro balance: ${data.balance}. Pick a model with ?model in the Nymbot chat.`);
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
        const oldAddress = localStorage.getItem('nym_lightning_address');
        if (oldAddress) {
            localStorage.removeItem('nym_lightning_address');
        }
    },

    async createZapRequest(amountSats, comment) {
        try {
            if (!this.currentZapTarget) {
                return null;
            }

            const zapRequest = {
                kind: 9734,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['p', this.currentZapTarget.recipientPubkey],
                    ['amount', (parseInt(amountSats) * 1000).toString()], // Amount in millisats
                    ['relays', ...this.defaultRelays.slice(0, 5)] // Limit to 5 relays
                ],
                content: comment || '',
                pubkey: this.pubkey
            };

            if (this.currentZapTarget.messageId) {
                zapRequest.tags.unshift(['e', this.currentZapTarget.messageId]); // Event being zapped

                let originalKind = '20000'; // Default geohash
                if (this.inPMMode) {
                    originalKind = '1059'; // PMs via NIP-17
                } else if (this.currentGeohash) {
                    originalKind = String(this.channelWire(this.currentGeohash).kind);
                }
                zapRequest.tags.push(['k', originalKind]);
                this.currentZapTarget._messageKind = originalKind;
                this.currentZapTarget._geohash = this.currentGeohash || null;
                this.currentZapTarget._channelId = this.currentChannel || null;
                this.currentZapTarget._groupId = (this.inPMMode && this.currentGroup) ? this.currentGroup : null;
                this.currentZapTarget._pmPeer = (this.inPMMode && !this.currentGroup) ? this.currentPM : null;
            } else {
                // k=0 so the receipt matches the recipient's broad #k subscription alongside message zaps.
                zapRequest.tags.push(['k', '0']);
            }

            const signedEvent = await this.signEvent(zapRequest);
            this._lastSignedZapRequest = signedEvent;

            return signedEvent;
        } catch (error) {
            return null;
        }
    },

    async generateZapInvoice() {
        if (!this.currentZapTarget) return;

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

        const selectedBtn = document.querySelector('.zap-amount-btn.selected');
        const customAmount = document.getElementById('zapCustomAmount').value;
        const amount = customAmount || (selectedBtn ? selectedBtn.dataset.amount : null);

        if (!amount || amount <= 0) {
            this.displaySystemMessage('Please select or enter an amount');
            return;
        }

        let comment = (document.getElementById('zapComment').value || '').trim();
        if (!comment) {
            comment = this.currentZapTarget.messageId ? 'Zap for your message' : 'Profile zap';
        }

        document.getElementById('zapAmountSection').style.display = 'none';
        document.getElementById('zapInvoiceSection').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status checking';
        document.getElementById('zapStatus').innerHTML = '<span class="loader"></span> Generating invoice...';

        try {
            // Resolved address first, then the project chain for our own targets, so a failing wallet falls through.
            const invoice = await this.fetchLightningInvoiceWithFallback(
                [
                    this.currentZapTarget.lnAddress,
                    ...this.lightningAddressesForPubkey(this.currentZapTarget.recipientPubkey)
                ],
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
                this._addPendingZap(invoice, this.currentZapTarget);

                this.displayZapInvoice(invoice);

                this.checkZapPayment(invoice);
            }
        } catch (error) {
            document.getElementById('zapStatus').className = 'zap-status';
            document.getElementById('zapStatus').textContent = `Failed: ${error.message}`;
        }
    },

    displayZapInvoice(invoice) {
        document.getElementById('zapStatus').style.display = 'none';
        document.getElementById('zapInvoiceDisplay').style.display = 'block';

        const invoiceEl = document.getElementById('zapInvoice');
        invoiceEl.textContent = invoice.pr;

        const qrContainer = document.getElementById('zapQRCode');
        qrContainer.innerHTML = '';

        // Class instead of inline styles for CSP compliance.
        qrContainer.classList.add('nm-zap-7');

        const qrDiv = document.createElement('div');
        qrDiv.id = 'zapQRCodeCanvas';
        qrDiv.className = 'nm-zap-8';
        qrContainer.appendChild(qrDiv);

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

        // Cancel already dismisses the modal, so the generic close button stays hidden.
        const paidBtn = document.getElementById('zapPaidBtn');
        if (paidBtn) paidBtn.classList.remove('nm-hidden');
        const sendBtn = document.getElementById('zapSendBtn');
        if (sendBtn) { sendBtn.style.display = 'none'; sendBtn.onclick = null; }
    },

    async _serverVerifyZapPaid(invoice, receipt) {
        if (!invoice) return false;
        const base = this._getProxyBaseUrl();
        if (!base) return false;
        try {
            const resp = await this._edgeFetch(`${base}?action=zap-verify`, {
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

    // LUD-21 verify URL is authoritative; otherwise the NIP-57 receipt leads, backed by a slower NWC server poll.
    async checkZapPayment(invoice) {
        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }

        const lud21 = !!invoice.verify;
        if (!lud21) this.listenForZapReceipt();

        let checkCount = 0;
        const stepMs = lud21 ? 1000 : 3000;
        const maxChecks = lud21 ? 180 : 60; // Poll for up to 3 minutes

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
                if (!lud21) return;
                const zapStatusEl = document.getElementById('zapStatus');
                if (zapStatusEl) {
                    zapStatusEl.style.display = 'block';
                    zapStatusEl.className = 'zap-status';
                    zapStatusEl.innerHTML = 'Payment timeout - please check your wallet';
                }
            }
        }, stepMs);
    },

    // Matches by bolt11, so it works for profile zaps too (no event id).
    listenForZapReceipt() {
        const target = this.currentZapTarget;
        const invoice = this.currentZapInvoice;
        if (!target || !invoice) return;

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

        // Filter by recipient (always p-tagged) so profile zaps resolve too; bolt11 disambiguates.
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

    handleZapPaymentSuccess(amount) {
        if (!this.currentZapTarget) return;

        // Capture before closeZapModal clears state.
        const isBotCreditPurchase = !!this.currentZapTarget.isBotCreditPurchase;
        const botCreditInvoiceId = this.currentZapInvoice && this.currentZapInvoice.invoiceId;
        const botCreditReceipt = (this.currentZapInvoice && this.currentZapInvoice.receipt) || null;
        const botCreditGiftNym = this.currentZapTarget.giftRecipientNym || null;
        const botCreditAnon = !!(this.currentZapInvoice && this.currentZapInvoice.anon);

        if (!isBotCreditPurchase && this.currentZapTarget.messageId) {
            const bolt11 = this.currentZapInvoice && this.currentZapInvoice.pr;
            const t = this.currentZapTarget;
            this._recordOwnMessageZap(t.messageId, amount, bolt11, true);
            if (t._groupId || t._pmPeer) {
                // PM/group zap: announce privately via gift wrap so the zap doesn't leak to public relays.
                this._publishOwnPrivateZapEvent(t.messageId, t.recipientPubkey, bolt11, t._groupId, t._pmPeer);
            } else {
                this._publishOwnMessageZapEvent(t.messageId, t.recipientPubkey, bolt11, t._messageKind, t._geohash, t._channelId);
            }
        }

        window.nymHapticTap && window.nymHapticTap();

        if (this.currentZapInvoice && this.currentZapInvoice.pr) {
            this._removePendingPurchase(this._pendingZapId(this.currentZapInvoice.pr));
        }

        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }
        if (this._botCreditServerPoll) {
            clearInterval(this._botCreditServerPoll);
            this._botCreditServerPoll = null;
        }

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
            this._claimBotCredits(botCreditInvoiceId, botCreditGiftNym, botCreditReceipt, botCreditAnon);
        }

        setTimeout(() => {
            this.closeZapModal();
        }, 2000);
    },

    handleZapReceipt(event) {
        if (event.kind !== 9735) return;

        // Ignore echoes of our own zap events; our zap is recorded locally at payment time.
        if (this._ownPublishedZapIds && this._ownPublishedZapIds.has(event.id)) return;

        if (this.blockedUsers && this.blockedUsers.has(event.pubkey)) return;

        const eTag = event.tags.find(t => t[0] === 'e');
        const pTag = event.tags.find(t => t[0] === 'p');
        const boltTag = event.tags.find(t => t[0] === 'bolt11');
        const descriptionTag = event.tags.find(t => t[0] === 'description');

        // Archive message zaps (e tag) and profile zaps (recipient pubkey) for D1 backfill.
        if (boltTag) this._archiveZapReceipt(event, eTag, descriptionTag);

        // Bot credit purchase without LUD-21: match by bolt11 (profile zap, no e tag).
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

        // Shop purchase without LUD-21: match by bolt11, then confirm server-side.
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

        // Direct zap without LUD-21: bolt11 is the only reliable match for profile zaps.
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
            // Kept so the worker can validate it; handleZapPaymentSuccess dedupes by bolt11.
            if (this.currentZapInvoice) this.currentZapInvoice.receipt = event;
            this._rebroadcastZapReceipt(event);
            this.handleZapPaymentSuccess(amount);
            return;
        }

        if (!boltTag) return;

        if (!eTag) {
            if (pTag && pTag[1] === this.pubkey) {
                this._handleIncomingProfileZap(event, descriptionTag, boltTag);
            }
            return;
        }

        const messageId = eTag[1];
        const bolt11 = boltTag[1];

        const amount = this.parseAmountFromBolt11(bolt11);
        if (!amount) return;

        const zapRequest = this._parseZapRequestFromDescription(descriptionTag, amount);
        if (descriptionTag && !zapRequest) return;

        let zapperPubkey = event.pubkey;
        if (zapRequest) {
            if (zapRequest.pubkey) {
                zapperPubkey = zapRequest.pubkey;
            }

            const kTag = zapRequest.tags?.find(t => t[0] === 'k');
            if (kTag && !['20000', '23333', '1059'].includes(kTag[1])) {
                return;
            }
            if (!kTag && !this._messageIdKnown(messageId)) {
                return;
            }
        }

        if (this.blockedUsers && this.blockedUsers.has(zapperPubkey)) return;

        const dedupKey = bolt11 ? 'b:' + bolt11.toLowerCase() : event.id;
        const existing = this.zaps.get(messageId);
        if (existing && existing.receipts.has(dedupKey) &&
            !(existing.unverified && existing.unverified.has(dedupKey))) return;

        const isLive = (Date.now() - (event.created_at * 1000)) <= 10000;

        const recipientPubkey = (pTag && pTag[1]) || null;
        this._getZapProviderPubkey(recipientPubkey).then((providerPubkey) => {
            const verified = !!providerPubkey && typeof event.pubkey === 'string' &&
                event.pubkey.toLowerCase() === providerPubkey;

            const zapper = (verified || zapperPubkey === event.pubkey) ? zapperPubkey : event.pubkey;
            if (this.blockedUsers && this.blockedUsers.has(zapper)) return;

            if (zapper === this.pubkey) {
                if (!verified && event.pubkey !== this.pubkey) return;
                this._rebroadcastZapReceipt(event);
                if (verified && this.currentZapTarget && this.currentZapTarget.messageId === messageId) {
                    this.handleZapPaymentSuccess(amount);
                } else {
                    this._recordOwnMessageZap(messageId, amount, bolt11, isLive);
                }
                return;
            }

            const counted = this._recordMessageZap(messageId, zapper, amount, dedupKey, isLive, verified);
            if (!counted) return;

            if (pTag && pTag[1] === this.pubkey && zapper !== this.pubkey) {
                if (verified || !providerPubkey) {
                    this._notifyZapToOurMessage(messageId, amount, zapper, event);
                }
            }
        }).catch(() => { });
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

        if (this.blockedUsers && this.blockedUsers.has(event.pubkey)) return;

        const amount = this.parseAmountFromBolt11(boltTag[1]);
        if (!amount) return;

        const zapRequest = this._parseZapRequestFromDescription(descriptionTag, amount);
        if (descriptionTag && !zapRequest) return;

        let zapperPubkey = event.pubkey;
        if (zapRequest) {
            if (zapRequest.pubkey) zapperPubkey = zapRequest.pubkey;
            const kTag = zapRequest.tags?.find(t => t[0] === 'k');
            if (kTag && kTag[1] !== '0') return;
        }
        if (zapperPubkey === this.pubkey) return;
        if (this.blockedUsers && this.blockedUsers.has(zapperPubkey)) return;

        this._getZapProviderPubkey(this.pubkey).then((providerPubkey) => {
            const verified = !!providerPubkey && typeof event.pubkey === 'string' &&
                event.pubkey.toLowerCase() === providerPubkey;
            if (providerPubkey && !verified) return;
            if (!verified && zapperPubkey !== event.pubkey) zapperPubkey = event.pubkey;
            if (zapperPubkey === this.pubkey) return;

            const zapperNym = this.getNymFromPubkey(zapperPubkey);
            const ts = (event && event.created_at ? event.created_at * 1000 : Date.now());
            const sats = this.abbreviateNumber ? this.abbreviateNumber(amount) : String(amount);
            const body = `⚡ zapped ${sats} sats to your profile${verified ? '' : ' (unverified)'}`;
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
        }).catch(() => { });
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

        if (msgPreview && window.NymFormat && typeof window.NymFormat.stripForPreview === 'function') msgPreview = window.NymFormat.stripForPreview(msgPreview);
        if (msgPreview && msgPreview.length > 80) msgPreview = msgPreview.slice(0, 80) + '…';
        const sats = this.abbreviateNumber ? this.abbreviateNumber(amount) : String(amount);
        const body = msgPreview
            ? `⚡ zapped ${sats} sats to: "${msgPreview}"`
            : `⚡ zapped ${sats} sats to your message`;

        // Lets the modal re-render the body once the zapped message arrives.
        channelInfo.zapMessageId = messageId;
        channelInfo.zapSats = sats;

        if (!msgPreview) this._fetchZappedMessage(messageId);

        const isHistorical = (Date.now() - ts) > 10000;
        if (isHistorical) this._addNotificationToHistory(zapperNym, body, channelInfo, ts);
        else this.showNotification(zapperNym, body, channelInfo, ts);
    },

    // Fetched events flow into this.messages, and the notifications modal re-reads text at render time.
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

    parseAmountFromBolt11(bolt11) {
        if (typeof bolt11 !== 'string' || bolt11.length < 6 || bolt11.length > 4096) return null;
        const match = bolt11.match(/^lnbc(\d{1,15})([munp])/i);
        if (!match) return null;
        const amount = parseInt(match[1], 10);
        if (!Number.isSafeInteger(amount) || amount <= 0) return null;
        let sats;
        switch (match[2].toLowerCase()) {
            case 'm': sats = amount * 100000; break;
            case 'u': sats = amount * 100; break;
            case 'n': sats = Math.round(amount / 10); break;
            case 'p': sats = Math.round(amount / 10000); break;
            default: return null;
        }
        if (!Number.isSafeInteger(sats) || sats <= 0 || sats > 1000000000) return null;
        return sats;
    },

    async _getZapProviderPubkey(recipientPubkey) {
        if (!recipientPubkey) return null;
        if (!this._zapProviderPubkeys) this._zapProviderPubkeys = new Map();
        const cached = this._zapProviderPubkeys.get(recipientPubkey);
        if (cached && (cached.pk || (Date.now() - cached.ts) < 300000)) return cached.pk;
        if (!this._zapProviderLookups) this._zapProviderLookups = new Map();
        if (this._zapProviderLookups.has(recipientPubkey)) {
            return this._zapProviderLookups.get(recipientPubkey);
        }
        const lookup = (async () => {
            try {
                let lnAddress = this.userLightningAddresses && this.userLightningAddresses.get(recipientPubkey);
                if (!lnAddress && recipientPubkey === this.pubkey) lnAddress = this.lightningAddress;
                if (!lnAddress || typeof lnAddress !== 'string') return null;
                const [username, domain] = lnAddress.split('@');
                if (!username || !domain) return null;
                const resp = await this.proxiedJsonFetch(`https://${domain}/.well-known/lnurlp/${username}`);
                if (!resp.ok) return null;
                const data = await resp.json();
                if (data && data.allowsNostr && typeof data.nostrPubkey === 'string' &&
                    /^[0-9a-f]{64}$/i.test(data.nostrPubkey)) {
                    return data.nostrPubkey.toLowerCase();
                }
                return null;
            } catch (_) {
                return null;
            }
        })();
        this._zapProviderLookups.set(recipientPubkey, lookup);
        const pk = await lookup;
        this._zapProviderLookups.delete(recipientPubkey);
        this._zapProviderPubkeys.set(recipientPubkey, { pk, ts: Date.now() });
        return pk;
    },

    _parseZapRequestFromDescription(descriptionTag, amountSats) {
        if (!descriptionTag || typeof descriptionTag[1] !== 'string') return null;
        let req = null;
        try { req = JSON.parse(descriptionTag[1]); } catch (_) { return null; }
        if (!req || typeof req !== 'object' || req.kind !== 9734) return null;
        if (!Array.isArray(req.tags)) return null;
        const amountTag = req.tags.find(t => Array.isArray(t) && t[0] === 'amount');
        if (amountTag && amountTag[1] != null) {
            const msats = parseInt(amountTag[1], 10);
            if (!Number.isSafeInteger(msats) || msats <= 0) return null;
            if (amountSats != null && Math.round(msats / 1000) !== amountSats) return null;
        }
        return req;
    },

    // Deduped by receipt id so we only republish once.
    _rebroadcastZapReceipt(event) {
        if (!event || event.kind !== 9735 || !event.id) return;
        if (!this._rebroadcastedZapReceipts) this._rebroadcastedZapReceipts = new Set();
        if (this._rebroadcastedZapReceipts.has(event.id)) return;
        this._rebroadcastedZapReceipts.add(event.id);
        try { this.sendToRelay(["EVENT", event]); } catch (_) { }
    },

    // The LNURL receipt has no top-level k tag, so it misses live #k subscriptions; this event matches them.
    async _publishOwnMessageZapEvent(messageId, recipientPubkey, bolt11, kind, geohash, channelId) {
        if (!messageId || !recipientPubkey || !bolt11) return;
        if (kind !== '20000' && kind !== '23333') return;
        const tags = [
            ['e', messageId],
            ['p', recipientPubkey],
            ['k', kind],
            ['bolt11', bolt11]
        ];
        if (this._lastSignedZapRequest) {
            tags.push(['description', JSON.stringify(this._lastSignedZapRequest)]);
        }
        if (geohash) tags.push(['g', geohash]);
        else if (kind === '23333' && channelId) tags.push(['d', channelId]);

        const event = {
            kind: 9735,
            created_at: Math.floor(Date.now() / 1000),
            tags,
            content: '',
            pubkey: this.pubkey
        };
        const signed = await this.signEvent(event);
        if (!signed) return;

        if (!this._ownPublishedZapIds) this._ownPublishedZapIds = new Set();
        this._ownPublishedZapIds.add(signed.id);
        if (this._ownPublishedZapIds.size > 500) {
            this._ownPublishedZapIds = new Set(Array.from(this._ownPublishedZapIds).slice(-400));
        }

        try { this.sendToRelay(["EVENT", signed]); } catch (_) { }
        if (geohash) this.ensureGeoRelayDelivery(signed, geohash);

        const descTag = signed.tags.find(t => t[0] === 'description');
        this._archiveZapReceipt(signed, signed.tags.find(t => t[0] === 'e'), descTag);
    },

    // Gift-wrapped kind-9735 rumor so members see the zap without leaking it to public relays.
    async _publishOwnPrivateZapEvent(messageId, recipientPubkey, bolt11, groupId, pmPeer) {
        if (!messageId || !recipientPubkey || !bolt11) return;
        if (!this._canSendGiftWraps()) return;
        const now = Math.floor(Date.now() / 1000);
        if (groupId) {
            const group = this.groupConversations.get(groupId);
            if (!group) return;
            const rumor = {
                kind: 9735,
                created_at: now,
                tags: [['g', groupId], ['e', messageId], ['k', '14'], ['p', recipientPubkey], ['bolt11', bolt11]],
                content: '',
                pubkey: this.pubkey
            };
            await this._sendGiftWrapsAsync(group.members, rumor, null, groupId);
        } else if (pmPeer) {
            if (this.botAnonSuppressSendTo && this.botAnonSuppressSendTo(pmPeer)) return;
            const rumor = {
                kind: 9735,
                created_at: now,
                tags: [['e', messageId], ['p', recipientPubkey], ['k', '1059'], ['bolt11', bolt11]],
                content: '',
                pubkey: this.pubkey
            };
            await this._sendGiftWrapsAsync([this.pubkey, pmPeer], rumor, null);
        }
    },

    _pendingZapId(pr) {
        return 'zap:' + String(pr || '').toLowerCase();
    },

    _addPendingZap(invoice, target) {
        if (!invoice || !invoice.pr || !target) return;
        if (!target.messageId) return;
        this._addPendingPurchase({
            kind: 'zap',
            invoiceId: this._pendingZapId(invoice.pr),
            pr: invoice.pr,
            verify: invoice.verify || null,
            providerPubkey: invoice.providerPubkey || null,
            amount: Number(invoice.amount) || 0,
            messageId: target.messageId || null,
            recipientPubkey: target.recipientPubkey || null,
            messageKind: target._messageKind || null,
            geohash: target._geohash || null,
            channelId: target._channelId || null,
            groupId: target._groupId || null,
            pmPeer: target._pmPeer || null
        });
    },

    async _reconcileZapEntry(entry) {
        if (!entry || !entry.pr) return;
        if (this.currentZapInvoice && this.currentZapInvoice.pr === entry.pr) return;
        const paid = await this._serverVerifyZapPaid({
            pr: entry.pr,
            verify: entry.verify,
            providerPubkey: entry.providerPubkey
        });
        if (!paid) return;
        this._removePendingPurchase(entry.invoiceId);
        if (!entry.messageId) return;
        const amount = Number(entry.amount) || this.parseAmountFromBolt11(entry.pr);
        this._recordOwnMessageZap(entry.messageId, amount, entry.pr, false);
        if (entry.groupId || entry.pmPeer) {
            this._publishOwnPrivateZapEvent(entry.messageId, entry.recipientPubkey, entry.pr, entry.groupId, entry.pmPeer);
        } else {
            this._publishOwnMessageZapEvent(entry.messageId, entry.recipientPubkey, entry.pr, entry.messageKind, entry.geohash, entry.channelId);
        }
    },

    // Deduped by bolt11 so the verify-URL confirmation and a later NIP-57 receipt don't double count.
    _recordOwnMessageZap(messageId, amount, bolt11, isLive) {
        if (!messageId || !amount) return;
        if (!this._selfCountedZapInvoices) this._selfCountedZapInvoices = new Set();
        const key = bolt11 ? String(bolt11).toLowerCase() : ('amt:' + messageId + ':' + amount);
        if (this._selfCountedZapInvoices.has(key)) return;
        this._selfCountedZapInvoices.add(key);
        // Keyed on the invoice so our zap and its echo dedup against each other.
        this._recordMessageZap(messageId, this.pubkey, amount, 'b:' + key, isLive, true);
    },

    _recordMessageZap(messageId, zapperPubkey, amount, receiptId, isLive, verified) {
        const sats = Number(amount) || 0;
        if (!messageId || !sats) return false;
        if (!this.zaps.has(messageId)) {
            this.zaps.set(messageId, { receipts: new Set(), amounts: new Map(), unverified: new Map() });
        }
        const messageZaps = this.zaps.get(messageId);
        if (!messageZaps.unverified) messageZaps.unverified = new Map();
        if (receiptId && messageZaps.receipts.has(receiptId)) {
            if (verified && messageZaps.unverified.has(receiptId)) {
                messageZaps.unverified.delete(receiptId);
                this.updateMessageZaps(messageId);
                return true;
            }
            return false;
        }
        if (receiptId) {
            messageZaps.receipts.add(receiptId);
            if (!verified) messageZaps.unverified.set(receiptId, sats);
        }
        const currentAmount = messageZaps.amounts.get(zapperPubkey) || 0;
        messageZaps.amounts.set(zapperPubkey, currentAmount + sats);
        const applied = this.updateMessageZaps(messageId);
        if (applied) {
            if (isLive) this._playZapBurst(messageId);
        } else {
            // Not in the DOM: drop the channel's cached render so the badge appears on next navigation.
            this._invalidateZapDOMCache(messageId);
        }
        return true;
    },

    _invalidateZapDOMCache(messageId) {
        for (const [key, msgs] of this.messages.entries()) {
            if (msgs.some(m => m.id === messageId)) { this.channelDOMCache.delete(key); return; }
        }
        for (const [key, msgs] of this.pmMessages.entries()) {
            if (msgs.some(m => m.id === messageId || m.nymMessageId === messageId)) {
                this.channelDOMCache.delete(key);
                return;
            }
        }
    },

    _playZapBurst(messageId) {
        const messageEl = document.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
        if (!messageEl) return;
        const badge = messageEl.querySelector('.zap-badge');
        if (!badge) return;
        const rect = badge.getBoundingClientRect();
        if (!rect.width && !rect.height) return;
        const cx = rect.left + rect.width / 2;
        const cy = rect.top + rect.height / 2;

        const flash = document.createElement('div');
        flash.className = 'zap-burst';
        flash.style.left = cx + 'px';
        flash.style.top = cy + 'px';
        flash.innerHTML = `<svg viewBox="0 0 24 24"><path d="M13 2L3 14h8l-1 8 10-12h-8l1-8z"/></svg>`;

        const bolts = document.createElement('div');
        bolts.className = 'zap-burst-bolts';
        bolts.style.left = cx + 'px';
        bolts.style.top = cy + 'px';
        const boltCount = 9;
        for (let i = 0; i < boltCount; i++) {
            const b = document.createElement('span');
            b.className = 'zap-bolt';
            const angle = (i / boltCount) * Math.PI * 2 + (Math.random() - 0.5) * 0.5;
            const dist = 20 + Math.random() * 20;
            b.style.setProperty('--dx', (Math.cos(angle) * dist).toFixed(1) + 'px');
            b.style.setProperty('--dy', (Math.sin(angle) * dist).toFixed(1) + 'px');
            b.style.setProperty('--rot', (angle * 180 / Math.PI + 90).toFixed(1) + 'deg');
            b.style.animationDelay = (Math.random() * 60) + 'ms';
            bolts.appendChild(b);
        }

        document.body.appendChild(flash);
        document.body.appendChild(bolts);
        setTimeout(() => {
            if (flash.parentNode) flash.remove();
            if (bolts.parentNode) bolts.remove();
        }, 800);

        badge.classList.remove('zap-badge-shock');
        void badge.offsetWidth;
        badge.classList.add('zap-badge-shock');
        setTimeout(() => badge.classList.remove('zap-badge-shock'), 600);
    },

    updateMessageZaps(messageId) {
        // A message can render more than once; `.message` excludes the hover `.reaction-btn`.
        const els = document.querySelectorAll(`.message[data-message-id="${messageId}"]`);
        if (!els.length) return false;
        let updated = false;
        els.forEach(el => { updated = this._updateMessageZapsEl(messageId, el) || updated; });
        return updated;
    },

    _updateMessageZapsEl(messageId, messageEl) {
        if (!messageEl) return false;

        const container = document.getElementById('messagesScroller');
        const wasAtBottom = container && (container.scrollHeight - container.scrollTop <= container.clientHeight + 150);

        const messageZaps = this.zaps.get(messageId);

        // Always a direct child of the row.
        let reactionsRow = messageEl.querySelector(':scope > .reactions-row');
        if (!reactionsRow) {
            reactionsRow = document.createElement('div');
            reactionsRow.className = 'reactions-row';
            const threadIndicator = messageEl.querySelector(':scope > .thread-indicator-row');
            if (threadIndicator) messageEl.insertBefore(reactionsRow, threadIndicator);
            else messageEl.appendChild(reactionsRow);
        }

        const existingZap = reactionsRow.querySelector('.zap-badge');
        if (existingZap) {
            existingZap.remove();
        }
        const existingZapBtn = reactionsRow.querySelector('.add-zap-btn');
        if (existingZapBtn) {
            existingZapBtn.remove();
        }

        if (messageZaps && messageZaps.amounts.size > 0) {
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
            let zapTitle = `${this.abbreviateNumber(zapperCount)} zapper${zapperCount > 1 ? 's' : ''} • ${this.abbreviateNumber(totalZaps)} sats total`;
            let unverifiedSats = 0;
            if (messageZaps.unverified) messageZaps.unverified.forEach(s => { unverifiedSats += s; });
            if (unverifiedSats > 0) zapTitle += ` (${this.abbreviateNumber(unverifiedSats)} unverified)`;
            zapBadge.title = zapTitle;

            reactionsRow.insertBefore(zapBadge, reactionsRow.firstChild);

            const pubkey = messageEl.dataset.pubkey;
            if (pubkey) {
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

                reactionsRow.insertBefore(addZapBtn, zapBadge.nextSibling);
            }
        }

        if (wasAtBottom) {
            this._scheduleScrollToBottom();
        }
        return true;
    },

    async handleQuickZap(messageId, pubkey, messageEl) {
        const author = messageEl.dataset.author;

        this.displaySystemMessage(`Checking if @${author} can receive zaps...`);

        try {
            const lnAddress = await this.fetchLightningAddressForUser(pubkey);

            if (lnAddress) {
                this.showZapModal(messageId, pubkey, author);
            } else {
                this.displaySystemMessage(`@${author} cannot receive zaps (no lightning address set)`);
            }
        } catch (error) {
            this.displaySystemMessage(`Failed to check if @${author} can receive zaps`);
        }
    },

    closeZapModal() {
        const modal = document.getElementById('zapModal');
        if (modal) modal.classList.remove('active');

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

        if (this.zapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.zapReceiptSubId]);
            this.zapReceiptSubId = null;
        }
        if (this._zapReceiptWait) {
            if (this._zapReceiptWait.timer) clearTimeout(this._zapReceiptWait.timer);
            this._zapReceiptWait = null;
        }

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

        const modalActions = document.querySelector('#zapModal .modal-actions');
        if (modalActions) {
            modalActions.innerHTML = `
                <button class="icon-btn" data-action="closeZapModal">Cancel</button>
                <button class="send-btn nm-hidden" id="zapPaidBtn" data-action="manualCheckPayment">I've paid</button>
                <button class="send-btn nm-hidden" id="zapSendBtn"></button>
            `;
        }

        this.currentZapTarget = null;
        this.currentZapInvoice = null;
        this.currentPurchaseContext = null;
        this.currentShopInvoice = null;

        document.querySelectorAll('.zap-amount-btn').forEach(btn => {
            btn.classList.remove('selected');
        });
    },

    copyZapInvoice() {
        if (!this.currentZapInvoice) return;

        navigator.clipboard.writeText(this.currentZapInvoice.pr).then(() => {
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

    openInWallet() {
        const invoice = this.currentZapInvoice || this.currentShopInvoice;
        if (!invoice) return;

        const invoiceStr = invoice.pr;

        // Don't double-prefix lightning:.
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

        const displayNym = this.formatNymWithPubkey(targetNym, targetPubkey);
        this.displaySystemMessage(`Checking if @${displayNym} can receive zaps...`, 'system', { html: true });

        const lnAddress = await this.fetchLightningAddressForUser(targetPubkey);

        if (lnAddress) {
            this.showProfileZapModal(targetPubkey, targetNym, lnAddress);
        } else {
            this.displaySystemMessage(`@${displayNym} cannot receive zaps (no lightning address set)`, 'system', { html: true });
        }
    },

});
