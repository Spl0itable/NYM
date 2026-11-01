(function () {
    const BADGE_TAG = 'nymattest';
    // Strongest first: `attested` is hardware-backed, `challenged` solved a domain-bound challenge, `origin` is a browser.
    const TIER_RANK = { attested: 3, challenged: 2, origin: 1 };
    // Pinned rather than learned, so a device whose first contact was hostile doesn't trust it forever.
    const PINNED_AUTHORITY = '1a49b93d9bd35726739292bd4a6837c494cebc06e747bb86f3328a1410fc400f';
    const AUTHORITY_LS_KEY = 'nym_attest_authority';
    const BADGE_LS_KEY = 'nym_attest_badge';
    // Re-enroll with this much of the badge's term left so briefly-offline devices still renew in time.
    const RENEW_BEFORE_MS = 7 * 24 * 3600 * 1000;
    const ENROLL_RETRY_MS = 10 * 60 * 1000;
    const ENROLL_SOON_MS = [1000, 3000, 8000, 20000, 45000];
    const ATTEST_FETCH_TIMEOUT_MS = 20000;
    // Verified badges are cached per (pubkey, badge).
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

        // Must stay identical to badgeDigest in _attest.js or every badge reads as forged.
        _attestDigest(pubkey, expDay, tier) {
            const sha = NT() && NT()._sha256;
            if (!sha) return '';
            return toHex(sha(new TextEncoder().encode(
                `nymattest:1:${pubkey}:${expDay}:${tier}`
            )));
        },

        // Returns the badge's tier, or '' when it does not verify for this pubkey.
        verifyAttestBadge(badge, pubkey) {
            if (typeof badge !== 'string' || !/^[0-9a-f]{64}$/.test(pubkey || '')) return '';
            const authority = this.attestAuthorityPubkey();
            if (!authority) return '';
            const schnorr = NT() && NT()._schnorr;
            if (!schnorr) return '';

            if (!(this._attestVerifyCache instanceof Map)) this._attestVerifyCache = new Map();
            // Keyed by the authority too, so pre-enrollment '' results don't outlive the key's arrival.
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

        // Remembered per pubkey so later badge-less messages still show as verified.
        attestedTier(pubkey) {
            if (!(this._attestTiers instanceof Map)) return '';
            return this._attestTiers.get(pubkey) || '';
        },

        // Also feeds nymchatPubkeys so an attested peer is trusted everywhere that set is.
        ingestAttestBadge(event) {
            if (!event || !Array.isArray(event.tags)) return '';
            const tag = event.tags.find(t => Array.isArray(t) && t[0] === BADGE_TAG);
            if (!tag || typeof tag[1] !== 'string') return '';
            const tier = this.verifyAttestBadge(tag[1], event.pubkey);
            if (!tier) return '';
            if (!(this._attestTiers instanceof Map)) this._attestTiers = new Map();
            // Keep the strongest tier ever seen for a key, not the most recent.
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
            const opts = {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            };
            if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
                opts.signal = AbortSignal.timeout(ATTEST_FETCH_TIMEOUT_MS);
            }
            const resp = await this._edgeFetch(`https://${apiHost}/api/attest`, opts);
            const data = await resp.json().catch(() => ({}));
            if (!resp.ok || (data && data.error)) {
                const err = new Error((data && data.error) || `attest failed (${resp.status})`);
                err.attestStatus = resp.status || 0;
                throw err;
            }
            return data || {};
        },

        _attestTransient(err) {
            const status = err && err.attestStatus;
            if (!status) return true;
            return status >= 500 || status === 408;
        },

        _attestSyncIdentity() {
            const pk = this.pubkey || '';
            if (this._attestFor === pk) return;
            this._attestFor = pk;
            this.attestBadge = null;
            this.attestTier = null;
            this._attestNextTry = 0;
            const rec = pk ? this._loadAttestBadge() : null;
            if (rec) {
                this.attestBadge = rec.badge;
                this.attestTier = rec.tier;
            }
        },

        _attestRotatingKey() {
            if (this.connectionMode !== 'ephemeral') return false;
            try {
                return localStorage.getItem('nym_keypair_mode') === 'hardcore';
            } catch (_) {
                return false;
            }
        },

        _attestPending() {
            this._attestSyncIdentity();
            if (this._attestRotatingKey()) return false;
            return !!this.pubkey && !this.attestBadge && !!this._attestEnrolling
                && this._attestEnrollingFor === this.pubkey;
        },

        _attestWaitSoon(ms) {
            return new Promise((resolve) => {
                let timer = null;
                const done = () => {
                    if (timer) clearTimeout(timer);
                    if (typeof window !== 'undefined' && window.removeEventListener) window.removeEventListener('online', done);
                    resolve();
                };
                timer = setTimeout(done, ms);
                if (typeof window !== 'undefined' && window.addEventListener) window.addEventListener('online', done);
            });
        },

        // The PWA cannot attest itself; a native shell supplies window.NymNativeAttest.
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

        // Reuses build-verify.js hashing so enrollment and the About dialog never disagree.
        async _buildProof(paths) {
            if (typeof window.hashRunningAssets !== 'function') return null;
            try {
                return await window.hashRunningAssets(paths);
            } catch (_) {
                return null;
            }
        },

        // Mining happens before signing because the nonce tag is part of the id.
        async _signAttestAuth(challenge, powBits) {
            const pk = this.pubkey;
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
                pubkey: pk
            };
            if (apiHost) event.tags.push(['u', `https://${apiHost}/api/attest`]);
            const bits = Number(powBits) || 0;
            let mined = event;
            const mine = typeof this._minePowParallel === 'function' ? this._minePowParallel : this._minePow;
            if (bits > 0 && typeof mine === 'function') {
                mined = (await mine.call(this, event, bits, () => this.pubkey !== pk)) || event;
            }
            if (this.pubkey !== pk) throw new Error('identity changed');
            return this.signEvent(mined);
        },

        // Enrolls if there is no live badge, or renews one nearing its end.
        async ensureAttestBadge(opts) {
            const force = !!(opts && opts.force);
            this._attestSyncIdentity();
            const pk = this.pubkey;
            if (!pk || this._attestRotatingKey()) return null;
            if (this._attestEnrolling && this._attestEnrollingFor === pk) return this._attestEnrolling;

            const existing = this._loadAttestBadge();
            if (existing && !force && existing.expiresAt - Date.now() > RENEW_BEFORE_MS) {
                this.attestBadge = existing.badge;
                this.attestTier = existing.tier;
                return existing;
            }
            if (!force && this._attestNextTry && Date.now() < this._attestNextTry) {
                return existing || null;
            }

            const run = this._attestEnrollLoop(pk);
            this._attestEnrolling = run;
            this._attestEnrollingFor = pk;
            run.then(() => {
                if (this._attestEnrolling !== run) return;
                this._attestEnrolling = null;
                this._attestEnrollingFor = '';
            });
            return run;
        },

        async _attestEnrollLoop(pk) {
            for (let step = 0; ; step++) {
                try {
                    const rec = await this._attestEnrollOnce(pk);
                    if (this.pubkey === pk) this._attestNextTry = 0;
                    return rec;
                } catch (err) {
                    if (this.pubkey !== pk) return null;
                    if (!this._attestTransient(err) || step >= ENROLL_SOON_MS.length) {
                        this._attestNextTry = Date.now() + ENROLL_RETRY_MS;
                        return this._loadAttestBadge();
                    }
                    await this._attestWaitSoon(ENROLL_SOON_MS[step]);
                    if (this.pubkey !== pk) return null;
                }
            }
        },

        async _attestEnrollOnce(pk) {
            const still = () => {
                if (this.pubkey !== pk) throw new Error('identity changed');
            };
            const issued = await this._attestApi({ action: 'challenge', pubkey: pk });
            const challenge = issued && issued.challenge;
            if (!challenge) throw new Error('no challenge');
            still();
            const proof = await this._platformAttestation(challenge);
            const probe = proof.platform === 'web' && Array.isArray(issued.buildProbe) ? issued.buildProbe : null;
            const build = probe ? await this._buildProof(probe) : null;
            if (probe && !build) throw new Error('build proof not ready');
            still();
            const auth = await this._signAttestAuth(
                challenge, proof.platform === 'web' ? issued.powBits : 0);
            still();
            const res = await this._attestApi(Object.assign({
                action: 'enroll',
                pubkey: pk,
                challenge,
                auth,
                build
            }, proof));
            if (!res.badge) {
                const err = new Error('no badge');
                err.attestStatus = 422;
                throw err;
            }
            still();
            if (res.authority && /^[0-9a-f]{64}$/.test(res.authority)
                && !/^[0-9a-f]{64}$/.test(PINNED_AUTHORITY)) {
                try { localStorage.setItem(AUTHORITY_LS_KEY, res.authority); } catch (_) { }
            }
            const rec = {
                pubkey: pk,
                badge: res.badge,
                tier: res.tier || 'origin',
                expiresAt: Number(res.expiresAt) || 0
            };
            this._saveAttestBadge(rec);
            this.attestBadge = rec.badge;
            this.attestTier = rec.tier;
            return rec;
        },

        _i18nComposerPlaceholder(input) {
            if (!input || typeof this.i18nBindAttr !== 'function') return;
            const value = input.getAttribute('data-placeholder');
            if (!value) return;
            try { this.i18nBindAttr(input, 'data-placeholder', value); } catch (_) { }
        },

        async awaitAttestBadge(maxMs) {
            this._attestSyncIdentity();
            if (this._attestRotatingKey()) return null;
            if (this.attestBadge) return this.attestBadge;
            const pk = this.pubkey;
            if (!pk) return null;
            let pending = this._attestEnrolling && this._attestEnrollingFor === pk ? this._attestEnrolling : null;
            if (!pending) {
                try { pending = this.ensureAttestBadge(); } catch (_) { pending = null; }
            }
            if (!pending || typeof pending.then !== 'function') return this.attestBadge || null;
            const waits = [pending.catch(() => null)];
            if (Number(maxMs) > 0) waits.push(new Promise(resolve => setTimeout(resolve, Number(maxMs))));
            await Promise.race(waits);
            if (this.pubkey !== pk) return null;
            return this.attestBadge || null;
        },

        attachAttestTag(event) {
            this._attestSyncIdentity();
            if (!event || !Array.isArray(event.tags) || !this.attestBadge || this._attestRotatingKey()) return event;
            if (event.pubkey && event.pubkey !== this.pubkey) return event;
            const tag = this.ATTEST_BADGE_TAG;
            if (event.tags.some(t => Array.isArray(t) && t[0] === tag)) return event;
            event.tags.push([tag, this.attestBadge]);
            return event;
        },

        // Tags to attach to an outgoing channel message.
        attestTagsForEvent() {
            this._attestSyncIdentity();
            return this.attestBadge && !this._attestRotatingKey() ? [[BADGE_TAG, this.attestBadge]] : [];
        }
    });
})();
