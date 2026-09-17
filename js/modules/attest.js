// attest.js — the client half of app attestation.

(function () {
    const BADGE_TAG = 'nymattest';
    /// Strongest first. `attested` is hardware-backed and unmintable by a
    /// third party; `challenged` is a browser that solved a domain-bound
    /// challenge for its own enrollment; `origin` is a browser and no more.
    const TIER_RANK = { attested: 3, challenged: 2, origin: 1 };
    /// The public key of ATTEST_AUTHORITY_SECRET, as
    /// npub1rfymj0vm6dtjvuujj27556phcj2va0qxuarmhphnx29pgy8ugq8s3l03yh.
    /// Pinned here rather than learned, because the fallback below trusts the
    /// first answer the API gives this device — fine as a bootstrap, but a
    /// device that first reached a hostile endpoint would trust it forever.
    const PINNED_AUTHORITY = '1a49b93d9bd35726739292bd4a6837c494cebc06e747bb86f3328a1410fc400f';
    const AUTHORITY_LS_KEY = 'nym_attest_authority';
    const BADGE_LS_KEY = 'nym_attest_badge';
    /// Re-enroll with this much of the badge's term left, so a device that is
    /// offline for a while still renews before anyone stops trusting it.
    const RENEW_BEFORE_MS = 7 * 24 * 3600 * 1000;
    const ENROLL_RETRY_MS = 10 * 60 * 1000;
    /// Verified badges are cached per (pubkey, badge) — a busy channel re-reads
    /// the same sender's badge on every message they post.
    const VERIFY_CACHE_MAX = 4000;

    const NT = () => window.NostrTools;

    function b64urlToBytes(s) {
        let t = String(s || '').replace(/-/g, '+').replace(/_/g, '/');
        while (t.length % 4) t += '=';
        const bin = atob(t);
        const out = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
    }

    function toHex(bytes) {
        let hex = '';
        for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, '0');
        return hex;
    }

    Object.assign(NYM.prototype, {

        ATTEST_BADGE_TAG: BADGE_TAG,

        attestAuthorityPubkey() {
            if (/^[0-9a-f]{64}$/.test(PINNED_AUTHORITY)) return PINNED_AUTHORITY;
            try {
                const stored = localStorage.getItem(AUTHORITY_LS_KEY) || '';
                if (/^[0-9a-f]{64}$/.test(stored)) return stored;
            } catch (_) { }
            return '';
        },

        // Digest the authority signs. Mirrors badgeDigest in _attest.js; the two
        // must stay identical or every badge this client sees reads as forged.
        _attestDigest(pubkey, expDay, tier) {
            const sha = NT() && NT()._sha256;
            if (!sha) return '';
            return toHex(sha(new TextEncoder().encode(
                `nymattest:1:${pubkey}:${expDay}:${tier}`
            )));
        },

        // Returns the badge's tier, or '' when it does not verify for this
        // pubkey. A badge lifted from someone else's event fails here: the
        // pubkey it was issued for is inside the signed digest.
        verifyAttestBadge(badge, pubkey) {
            if (typeof badge !== 'string' || !/^[0-9a-f]{64}$/.test(pubkey || '')) return '';
            const authority = this.attestAuthorityPubkey();
            if (!authority) return '';
            const schnorr = NT() && NT()._schnorr;
            if (!schnorr) return '';

            if (!(this._attestVerifyCache instanceof Map)) this._attestVerifyCache = new Map();
            // Keyed by the authority too: before enrollment there is no pinned
            // key and every badge verifies as '', and those entries must not
            // outlive the moment the key arrives.
            const cacheKey = authority + '|' + pubkey + '|' + badge;
            const cached = this._attestVerifyCache.get(cacheKey);
            if (cached !== undefined) return cached;

            let tier = '';
            try {
                const parts = badge.split('.');
                if (parts.length === 4 && parts[0] === '1'
                    && TIER_RANK[parts[1]] !== undefined) {
                    const expDay = parseInt(parts[2], 36);
                    const today = Math.floor(Date.now() / 86400000);
                    if (Number.isFinite(expDay) && expDay >= today) {
                        const sig = b64urlToBytes(parts[3]);
                        if (sig.length === 64) {
                            const digest = this._attestDigest(pubkey, expDay, parts[1]);
                            if (digest && schnorr.verify(toHex(sig), digest, authority)) tier = parts[1];
                        }
                    }
                }
            } catch (_) { tier = ''; }

            if (this._attestVerifyCache.size > VERIFY_CACHE_MAX) this._attestVerifyCache.clear();
            this._attestVerifyCache.set(cacheKey, tier);
            return tier;
        },

        // The tier a sender has most recently proved. Remembered per pubkey so
        // a message that arrives without a badge (an older client, a mesh
        // replay) still shows as verified once one of their messages carried it.
        attestedTier(pubkey) {
            if (!(this._attestTiers instanceof Map)) return '';
            return this._attestTiers.get(pubkey) || '';
        },

        // Reads the badge off an inbound channel event and records what it
        // proves. Also feeds nymchatPubkeys, which the PoW-era heuristics
        // already use, so an attested peer is trusted everywhere that set is.
        ingestAttestBadge(event) {
            if (!event || !Array.isArray(event.tags)) return '';
            const tag = event.tags.find(t => Array.isArray(t) && t[0] === BADGE_TAG);
            if (!tag || typeof tag[1] !== 'string') return '';
            const tier = this.verifyAttestBadge(tag[1], event.pubkey);
            if (!tier) return '';
            if (!(this._attestTiers instanceof Map)) this._attestTiers = new Map();
            // Keep the strongest tier ever seen for a key rather than the most
            // recent. The same person on a phone and on the web is still that
            // person, and with three tiers "anything but attested is
            // replaceable" would also let a challenged sender decay to origin.
            const prev = this._attestTiers.get(event.pubkey);
            if (!prev || (TIER_RANK[tier] || 0) > (TIER_RANK[prev] || 0)) {
                this._attestTiers.set(event.pubkey, tier);
            }
            if (this._attestTiers.size > 20000) {
                this._attestTiers = new Map(Array.from(this._attestTiers).slice(-15000));
            }
            if (typeof this._markNymchatPubkey === 'function') this._markNymchatPubkey(event.pubkey);
            return tier;
        },

        passesAppVerifiedFilter(pubkey) {
            const mode = this.appVerifiedFilter || 'off';
            if (mode === 'off') return true;
            if (pubkey === this.pubkey) return true;
            if (typeof this.isVerifiedBot === 'function' && this.isVerifiedBot(pubkey)) return true;
            if (typeof this.isFriend === 'function' && this.isFriend(pubkey)) return true;
            return TIER_RANK[this.attestedTier(pubkey)] !== undefined;
        },

        // ---- enrollment ----------------------------------------------------

        _loadAttestBadge() {
            try {
                const raw = localStorage.getItem(BADGE_LS_KEY);
                if (!raw) return null;
                const rec = JSON.parse(raw);
                if (!rec || rec.pubkey !== this.pubkey) return null;
                if (!rec.badge || !(rec.expiresAt > Date.now())) return null;
                return rec;
            } catch (_) { return null; }
        },

        _saveAttestBadge(rec) {
            try { localStorage.setItem(BADGE_LS_KEY, JSON.stringify(rec)); } catch (_) { }
        },

        async _attestApi(body) {
            const apiHost = this._getApiHost && this._getApiHost();
            if (!apiHost) throw new Error('no api host');
            const resp = await fetch(`https://${apiHost}/api/attest`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            const data = await resp.json().catch(() => ({}));
            if (!resp.ok || (data && data.error)) {
                throw new Error((data && data.error) || `attest failed (${resp.status})`);
            }
            return data || {};
        },

        // The platform proof for this build. The PWA has none to give — a page
        // cannot attest itself, and pretending otherwise would put a tier on
        // web users that the name would not honestly describe. A native shell
        // installs window.NymNativeAttest to supply a real one.
        async _platformAttestation(challenge) {
            const native = window.NymNativeAttest;
            if (native && typeof native.attest === 'function') {
                try {
                    const proof = await native.attest(challenge);
                    if (proof && proof.platform) return proof;
                } catch (_) { }
            }
            return { platform: 'web' };
        },

        /// Hashes the asset paths the server named for this enrollment.
        /// build-verify.js already does this for the About dialog; enrollment
        /// borrows the same hashing so the two can never disagree about what
        /// an asset's hash is.
        async _buildProof(paths) {
            if (typeof window.hashRunningAssets !== 'function') return null;
            try {
                return await window.hashRunningAssets(paths);
            } catch (_) {
                return null;
            }
        },

        /// The auth event, optionally mined first.
        ///
        /// The work rides on this event rather than a field of its own: it is
        /// already signed by the enrolling key and already carries the
        /// server's challenge, so mining it binds the work to both. Mining
        /// happens before signing because every signing path recomputes the id
        /// from these same fields, and the nonce tag is one of them.
        ///
        /// _minePow runs in the crypto worker where there is one and falls
        /// back to a main-thread miner that yields every 4ms, so a slow device
        /// grinding for a few seconds does not drop frames. Nothing is waiting
        /// on it — the app sends unbadged until enrollment lands.
        async _signAttestAuth(challenge, powBits) {
            const apiHost = this._getApiHost && this._getApiHost();
            const event = {
                kind: 27235,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['domain', 'nymbot-pm'],
                    ['method', 'POST'],
                    ['action', 'attest-enroll'],
                    ['challenge', challenge]
                ],
                content: '',
                pubkey: this.pubkey
            };
            if (apiHost) event.tags.push(['u', `https://${apiHost}/api/attest`]);
            const bits = Number(powBits) || 0;
            let mined = event;
            if (bits > 0 && typeof this._minePow === 'function') {
                mined = (await this._minePow(event, bits)) || event;
            }
            return this.signEvent(mined);
        },

        // Enrolls if there is no live badge, or renews one nearing its end.
        async ensureAttestBadge(opts) {
            const force = !!(opts && opts.force);
            if (!this.pubkey) return null;
            if (this._attestEnrolling) return this._attestEnrolling;

            const existing = this._loadAttestBadge();
            if (existing && !force && existing.expiresAt - Date.now() > RENEW_BEFORE_MS) {
                this.attestBadge = existing.badge;
                this.attestTier = existing.tier;
                return existing;
            }
            if (!force && this._attestNextTry && Date.now() < this._attestNextTry) {
                return existing || null;
            }

            this._attestEnrolling = (async () => {
                try {
                    if (typeof this._syncComposerVerifying === 'function') this._syncComposerVerifying();
                    const issued = await this._attestApi({ action: 'challenge', pubkey: this.pubkey });
                    const challenge = issued && issued.challenge;
                    if (!challenge) throw new Error('no challenge');
                    const proof = await this._platformAttestation(challenge);
                    // Only the web tier is probed. A native build already
                    // carries a proof the server trusts more than this one.
                    const build = (proof.platform === 'web' && Array.isArray(issued.buildProbe))
                        ? await this._buildProof(issued.buildProbe)
                        : null;
                    // Only the web tier pays. A native build already carries a
                    // proof the server trusts more than any amount of hashing.
                    const auth = await this._signAttestAuth(
                        challenge, proof.platform === 'web' ? issued.powBits : 0);
                    const res = await this._attestApi(Object.assign({
                        action: 'enroll',
                        pubkey: this.pubkey,
                        challenge,
                        auth,
                        build
                    }, proof));
                    if (!res.badge) throw new Error('no badge');
                    if (res.authority && /^[0-9a-f]{64}$/.test(res.authority)
                        && !/^[0-9a-f]{64}$/.test(PINNED_AUTHORITY)) {
                        try { localStorage.setItem(AUTHORITY_LS_KEY, res.authority); } catch (_) { }
                    }
                    const rec = {
                        pubkey: this.pubkey,
                        badge: res.badge,
                        tier: res.tier || 'origin',
                        expiresAt: Number(res.expiresAt) || 0
                    };
                    this._saveAttestBadge(rec);
                    this.attestBadge = rec.badge;
                    this.attestTier = rec.tier;
                    this._attestNextTry = 0;
                    return rec;
                } catch (_) {
                    // A failed enrollment is not an error the user needs to see:
                    // they keep sending, they just go unbadged until it works.
                    this._attestNextTry = Date.now() + ENROLL_RETRY_MS;
                    return this._loadAttestBadge();
                } finally {
                    this._attestEnrolling = null;
                    if (typeof this._syncComposerVerifying === 'function') this._syncComposerVerifying();
                }
            })();
            return this._attestEnrolling;
        },

        composerVerifying() {
            return !!this._attestEnrolling && !this.attestBadge && !this.inPMMode;
        },

        _syncComposerVerifying() {
            if (typeof document === 'undefined') return;
            const btn = document.getElementById('sendBtn');
            const input = document.getElementById('messageInput');
            if (!btn || !input) return;
            const on = this.composerVerifying();
            if (on === !!this._composerVerifying) return;
            this._composerVerifying = on;
            if (on) {
                btn.dataset.attestPrevLabel = btn.textContent;
                btn.textContent = 'VERIFYING...';
                btn.classList.add('send-btn-verifying');
                btn.setAttribute('aria-busy', 'true');
                input.dataset.attestPrevPlaceholder = input.getAttribute('data-placeholder') || '';
                input.setAttribute('data-placeholder', 'Verifying your session...');
            } else {
                if (btn.dataset.attestPrevLabel) btn.textContent = btn.dataset.attestPrevLabel;
                btn.classList.remove('send-btn-verifying');
                btn.removeAttribute('aria-busy');
                if (this.connected) btn.disabled = false;
                if (input.dataset.attestPrevPlaceholder) {
                    input.setAttribute('data-placeholder', input.dataset.attestPrevPlaceholder);
                }
            }
            if (typeof this.i18nApplyNow === 'function') {
                try { this.i18nApplyNow(btn); } catch (_) { }
            }
            this._i18nComposerPlaceholder(input);
            if (!on) this._flushQueuedSend();
        },

        _i18nComposerPlaceholder(input) {
            const lang = typeof this.getUiLanguage === 'function' ? this.getUiLanguage() : '';
            if (!lang || lang === 'en' || !input) return;
            if (typeof this._i18nApplyAttr !== 'function' || typeof this._i18nAttrKey !== 'function') return;
            try {
                if (input.__i18nAttrOrig) delete input.__i18nAttrOrig['data-placeholder'];
                if (typeof this._i18nLoadCache === 'function') this._i18nLoadCache(lang);
                this._i18nApplyAttr({ el: input, attr: 'data-placeholder' }, lang);
                const key = this._i18nAttrKey(input, 'data-placeholder');
                const cache = typeof this._i18nLoadCache === 'function' ? this._i18nLoadCache(lang) : null;
                if (key && cache && cache[key] == null && typeof this._i18nEnqueue === 'function') {
                    this._i18nEnqueue([key], 'hi', lang);
                }
            } catch (_) { }
        },

        queueSendAfterVerify() {
            this._composerSendQueued = {
                channel: this.currentChannel,
                geohash: this.currentGeohash,
                pm: !!this.inPMMode
            };
            const btn = typeof document !== 'undefined' ? document.getElementById('sendBtn') : null;
            if (btn) {
                btn.textContent = 'SENDING...';
                if (typeof this.i18nApplyNow === 'function') {
                    try { this.i18nApplyNow(btn); } catch (_) { }
                }
            }
        },

        _flushQueuedSend() {
            const queued = this._composerSendQueued;
            if (!queued) return;
            this._composerSendQueued = null;
            const sameView = queued.pm === !!this.inPMMode
                && queued.channel === this.currentChannel
                && queued.geohash === this.currentGeohash;
            if (!sameView || !this.connected || typeof this.sendMessage !== 'function') return;
            const send = () => { try { this.sendMessage(); } catch (_) { } };
            if (typeof setTimeout === 'function') setTimeout(send, 0); else send();
        },

        async awaitAttestBadge(maxMs) {
            if (this.attestBadge) return this.attestBadge;
            if (!this.pubkey) return null;
            let pending = this._attestEnrolling;
            if (!pending) {
                try { pending = this.ensureAttestBadge(); } catch (_) { pending = null; }
            }
            if (!pending || typeof pending.then !== 'function') return this.attestBadge || null;
            const limit = Number(maxMs) > 0 ? Number(maxMs) : 8000;
            await Promise.race([
                pending.catch(() => null),
                new Promise(resolve => setTimeout(resolve, limit))
            ]);
            return this.attestBadge || null;
        },

        attachAttestTag(event) {
            if (!event || !Array.isArray(event.tags) || !this.attestBadge) return event;
            const tag = this.ATTEST_BADGE_TAG;
            if (event.tags.some(t => Array.isArray(t) && t[0] === tag)) return event;
            event.tags.push([tag, this.attestBadge]);
            return event;
        },

        // Tags to attach to an outgoing channel message.
        attestTagsForEvent() {
            return this.attestBadge ? [[BADGE_TAG, this.attestBadge]] : [];
        }
    });
})();
