(function () {
    const A = () => window.NymAwaySync;

    Object.assign(NYM.prototype, {
        _awaySyncAllowed() {
            if (!this.pubkey) return false;
            if (this.connectionMode === 'ephemeral') {
                let mode = 'random';
                try {
                    mode = localStorage.getItem('nym_keypair_mode')
                        || (localStorage.getItem('nym_random_keypair_per_session') === 'true' ? 'random' : 'persistent');
                } catch (_) { mode = 'random'; }
                if (mode === 'random' || mode === 'hardcore') return false;
            }
            return true;
        },

        _awayEnsureRestored() {
            const pk = this.pubkey;
            if (!pk || this._awayRestoredFor === pk) return;
            if (!this.awayMessages) this.awayMessages = new Map();
            const prev = this._awayRestoredFor;
            this._awayRestoredFor = pk;
            if (prev) {
                this._awayCancelReplies(prev);
                this._awayReflect(prev, null);
            }
            let state = null;
            if (this._awaySyncAllowed()) {
                try { state = A().decode(localStorage.getItem(A().storageKey(pk))); } catch (_) { state = null; }
            }
            this._awayState = state;
            this._awayPending = false;
            this._awayReflect(pk, state);
        },

        _awayReflect(pk, state) {
            const p = A().presence(state);
            if (p.status === 'away') this.awayMessages.set(pk, p.message);
            else this.awayMessages.delete(pk);
            const u = this.users && this.users.get(pk);
            if (u) {
                if (p.status === 'away') u.status = 'away';
                else if (u.status === 'away') u.status = 'online';
            }
        },

        awayState() {
            this._awayEnsureRestored();
            return this._awayState || null;
        },

        _awayStore(next) {
            this._awayState = next;
            if (!this._awaySyncAllowed()) return;
            const encoded = A().encode(next);
            if (!encoded) return;
            try { localStorage.setItem(A().storageKey(this.pubkey), encoded); } catch (_) { }
        },

        _awayCancelReplies(pk) {
            if (this._awayTimers) for (const t of this._awayTimers) clearTimeout(t);
            this._awayTimers = new Set();
            this._awayReplied = new Set();
            const self = pk || this.pubkey;
            if (!self) return;
            const prefix = A().sessionKey(self, '');
            try {
                const drop = [];
                for (let i = 0; i < sessionStorage.length; i++) {
                    const key = sessionStorage.key(i);
                    if (key && key.startsWith(prefix)) drop.push(key);
                }
                drop.forEach((key) => sessionStorage.removeItem(key));
            } catch (_) { }
        },

        _awayShow(next) {
            this._awayReflect(this.pubkey, next);
            if (typeof this.updateUserList === 'function') this.updateUserList();
        },

        async _awayAnnounce(next) {
            this._awayShow(next);
            const p = A().presence(next);
            await this.publishPresence(p.status, p.message);
        },

        async setAwayState(message) {
            this._awayEnsureRestored();
            const next = A().enable(this._awayState, message, Date.now());
            this._awayStore(next);
            this._awayCancelReplies();
            this._awayShow(next);
            await this._awaySync();
            await this._awayAnnounce(next);
            return next;
        },

        async clearAwayState() {
            this._awayEnsureRestored();
            if (!(this._awayState && this._awayState.enabled)) return false;
            const next = A().disable(this._awayState, Date.now());
            this._awayStore(next);
            this._awayCancelReplies();
            this._awayShow(next);
            await this._awaySync();
            await this._awayAnnounce(next);
            return true;
        },

        async _awaySync() {
            if (!this._awaySyncAllowed()) return false;
            const payload = A().payload(this._awayState);
            if (!payload) return false;
            if (!this._settingsHydrated) {
                this._awayPending = true;
                if (!this._awayHydrateHooked && typeof this._onSettingsHydrated === 'function') {
                    this._awayHydrateHooked = true;
                    this._onSettingsHydrated(() => {
                        this._awayHydrateHooked = false;
                        this._awayFlushPending();
                    });
                }
                return false;
            }
            this._awayPending = false;
            let ok = false;
            try {
                if (typeof this._publishCategoryWrap === 'function') {
                    const dTag = A().DTAG;
                    const now = Math.floor(Date.now() / 1000);
                    const changed = await this._publishCategoryWrap(payload, dTag, now);
                    ok = !!changed || !!(this._publishedSectionJson && this._publishedSectionJson[dTag] === JSON.stringify(payload));
                    if (changed && typeof this._publishSettingsChangedPing === 'function') {
                        await this._publishSettingsChangedPing(['away'], now);
                    }
                }
            } catch (_) {
                ok = false;
            }
            if (!ok) this._awayPending = true;
            return ok;
        },

        async _awayFlushPending() {
            this._awayEnsureRestored();
            if (!this._awayPending) return;
            await this._awaySync();
        },

        async applySyncedAway(raw) {
            this._awayEnsureRestored();
            if (!this._awaySyncAllowed()) return;
            const remote = A().normalize(raw);
            if (!remote) return;
            const local = this._awayState;
            const merged = A().merge(local, remote);
            if (!merged) return;
            if (A().encode(merged) !== A().encode(remote)) {
                await this._awaySync();
                return;
            }
            if (A().encode(local) === A().encode(merged)) return;
            const before = A().presence(local);
            this._awayStore(merged);
            const after = A().presence(merged);
            if (before.status === after.status && before.message === after.message) return;
            this._awayCancelReplies();
            await this._awayAnnounce(merged);
        },

        _awayMaybeAutoReply(o) {
            this._awayEnsureRestored();
            const self = this.pubkey;
            if (!A().shouldAutoReply({
                state: this._awayState, selfPubkey: self, senderPubkey: o.senderPubkey,
                mentioned: o.mentioned, historical: o.historical
            })) return;
            const key = A().sessionKey(self, o.nym);
            if (!this._awayReplied) this._awayReplied = new Set();
            let seen = this._awayReplied.has(key);
            try { seen = seen || !!sessionStorage.getItem(key); sessionStorage.setItem(key, '1'); } catch (_) { }
            if (seen) return;
            this._awayReplied.add(key);
            const armed = this._awayState;
            if (!this._awayTimers) this._awayTimers = new Set();
            const timer = setTimeout(() => {
                this._awayTimers.delete(timer);
                const current = this._awayState;
                if (this.pubkey !== self || !current || !current.enabled || current.updatedAt !== armed.updatedAt) return;
                const list = (this.messages && this.messages.get('#' + o.geohash)) || [];
                const shown = list.map((m) => ({ pubkey: m.pubkey, content: m.content, createdAt: m.created_at }));
                if (A().hasOwnAutoReply(shown, self, o.nym, A().sinceSec(current))) return;
                Promise.resolve(this.publishMessage(A().autoReplyText(o.nym, current.message), o.geohash, o.geohash))
                    .catch(() => { });
            }, A().delayMs(Math.random()));
            this._awayTimers.add(timer);
        },
    });
})();
