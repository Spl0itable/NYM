(function () {
    const G = () => window.NymGroupInvites;
    const nowSec = () => Math.floor(Date.now() / 1000);
    const MODAL = 'gtGroupInvitesModal';
    const SYNC_DEBOUNCE_MS = 1200;
    const ICON = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="6" cy="5.5" r="2.5"/><path d="M2 14c0-3 2-4.5 4-4.5s4 1.5 4 4.5"/><path d="M12 4v4M10 6h4"/></svg>';
    const tagOf = (rumor, k) => {
        const t = ((rumor && rumor.tags) || []).find((x) => Array.isArray(x) && x[0] === k && typeof x[1] === 'string' && x[1]);
        return t ? t[1] : null;
    };

    Object.assign(NYM.prototype, {

        _gi(text, vars) {
            const s = typeof this.uiText === 'function' ? this.uiText(text) : text;
            return G().fill(s, vars);
        },

        _gnView(groupId) {
            const M = window.NymGroupInvited;
            const g = this.groupConversations && this.groupConversations.get(groupId);
            if (!M || !g) return null;
            const ek = this.groupEphemeralKeys && typeof this.groupEphemeralKeys.get === 'function' ? this.groupEphemeralKeys.get(groupId) : null;
            return M.view({ self: this.pubkey, members: g.members, invited: g.invited, keyTs: (ek && ek._memberKeyTs) || {}, removedAt: g.memberRemovedAt || {}, now: nowSec() });
        },

        _gnStatus(groupId, pk) {
            const v = this._gnView(groupId);
            return v ? window.NymGroupInvited.statusOf(v, pk) : 'member';
        },

        _gnAccepted(groupId, list) {
            const v = this._gnView(groupId);
            const src = Array.isArray(list) ? list : [];
            return v ? src.filter((pk) => window.NymGroupInvited.statusOf(v, pk) === 'member') : src.slice();
        },

        _gnSet(g, map) {
            if (Object.keys(map).length) g.invited = map;
            else delete g.invited;
        },

        _gnMark(groupId, pks, it) {
            const M = window.NymGroupInvited;
            const g = this.groupConversations && this.groupConversations.get(groupId);
            if (!M || !g) return false;
            this._gnSet(g, M.mark(g.invited, pks, it, this.pubkey));
            return true;
        },

        _gnAdopt(g, incoming) {
            const M = window.NymGroupInvited;
            const src = incoming && incoming.invited;
            if (!M || !g || !src || typeof src !== 'object') return false;
            const merged = M.merge(g.invited, src);
            if (M.same(merged, g.invited || {})) return false;
            this._gnSet(g, merged);
            return true;
        },

        _gnSeen(groupId) {
            const M = window.NymGroupInvited;
            const g = this.groupConversations && this.groupConversations.get(groupId);
            if (!M || !g || !g.invited) return false;
            const v = this._gnView(groupId);
            if (!v || M.same(v.keep, g.invited)) return false;
            this._gnSet(g, v.keep);
            if (typeof this._saveGroupConversations === 'function') this._saveGroupConversations();
            if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave();
            if (typeof this.updateGroupConversationUI === 'function') this.updateGroupConversationUI(groupId);
            return true;
        },

        _gnBadge(groupId, pk, nym) {
            const M = window.NymGroupInvited;
            const st = this._gnStatus(groupId, pk);
            if (!M || st === 'member') return '';
            const esc = (x) => (typeof this.escapeHtml === 'function' ? this.escapeHtml(x) : String(x));
            const text = st === 'expired' ? this._gi(M.STRINGS.expired) : this._gi(M.STRINGS.invited);
            const label = this._gi(st === 'expired' ? M.STRINGS.expiredLabel : M.STRINGS.invitedLabel, { nym: nym || '' });
            return `<span class="group-ctx-role group-ctx-invited ${st}" role="img" aria-label="${esc(label)}" title="${esc(label)}" data-no-i18n translate="no">${esc(text)}</span>`;
        },

        _gnCountLine(groupId) {
            const M = window.NymGroupInvited;
            const v = this._gnView(groupId);
            return M && v && v.waiting > 0 ? this._gi(M.STRINGS.count, { n: v.waiting }) : '';
        },

        _giLocal() {
            if (typeof this.savedMode === 'function' && this.savedMode() === 'local') return true;
            if (this.connectionMode !== 'ephemeral') return false;
            let mode = 'persistent';
            try { mode = localStorage.getItem('nym_keypair_mode') || (localStorage.getItem('nym_random_keypair_per_session') === 'true' ? 'random' : 'persistent'); } catch (_) { }
            return mode === 'random' || mode === 'hardcore';
        },

        _giVaultOn() {
            return typeof this.vaultEnabled === 'function' && this.vaultEnabled();
        },

        _giEmpty() {
            return { v: 1, items: [], dec: {}, ns: { last: {}, recent: [] }, as: { last: {}, recent: [] }, us: { last: {} }, lr: {} };
        },

        _giState() {
            if (this._giCache && this._giCache.pk === this.pubkey) return this._giCache.state;
            return this._giEmpty();
        },

        async _giReady() {
            const pk = this.pubkey;
            if (!pk) return false;
            if (this._giCache && this._giCache.pk === pk) return true;
            let raw = null;
            try { raw = localStorage.getItem(G().KEYS.local + pk); } catch (_) { raw = null; }
            if (raw && String(raw).startsWith('enc:v1:')) {
                if (!(this._giVaultOn() && this._vaultKey)) return false;
                try { raw = await this._vaultDecrypt(raw); } catch (_) { raw = null; }
            }
            if (this._giCache && this._giCache.pk === pk) return true;
            if (this.pubkey !== pk) return false;
            const st = this._giEmpty();
            try {
                const p = raw ? JSON.parse(raw) : null;
                if (p && typeof p === 'object') {
                    const now = nowSec();
                    st.items = G().normalizeItems(p.items, now);
                    st.dec = G().normalizeDecisions(p.dec, now);
                    st.ns = G().notifyState(p.ns, now);
                    st.as = G().notifyState(p.as, now);
                    st.us = G().unbanState(p.us, now);
                    st.lr = G().leftRoles(p.lr, null);
                }
            } catch (_) { }
            this._giCache = { pk, state: st };
            this._giRender();
            return true;
        },

        _giPersist(state) {
            const pk = this.pubkey;
            if (!pk) return;
            this._giCache = { pk, state };
            const name = G().KEYS.local + pk;
            const json = JSON.stringify(state);
            if (this._giVaultOn()) {
                if (!this._vaultKey || typeof this._vaultEncrypt !== 'function') return;
                const seq = (this._giSaveSeq = (this._giSaveSeq || 0) + 1);
                this._vaultEncrypt(json).then((blob) => {
                    if (seq !== this._giSaveSeq || this.pubkey !== pk) return;
                    try { localStorage.setItem(name, blob); } catch (_) { }
                }).catch(() => { });
                return;
            }
            try { localStorage.setItem(name, json); } catch (_) { }
        },

        _giList() {
            return this._giState().items.slice();
        },

        _giHold() {
            if (!this._giHoldState || this._giHoldState.pk !== this.pubkey) this._giHoldState = { pk: this.pubkey, h: G().holdNew(), data: new Map() };
            return this._giHoldState;
        },

        _giHoldPut(groupId, entry) {
            const hs = this._giHold();
            let b = 0;
            try { b = new TextEncoder().encode(JSON.stringify(entry.rumor)).length + String((entry.event && entry.event.content) || '').length; } catch (_) { b = 0; }
            const id = (entry.event && entry.event.id) || entry.rumor.id || '';
            const r = G().holdAdd(hs.h, { gid: groupId, id, ts: Math.floor(entry.rumor.created_at || 0), b });
            hs.h = r.state;
            for (const d of r.dropped) hs.data.delete(d.id);
            if (r.accepted) hs.data.set(id, entry);
        },

        _giHoldClear(groupId) {
            const hs = this._giHold();
            const r = G().holdTake(hs.h, groupId);
            hs.h = r.state;
            const out = [];
            for (const id of r.ids) {
                const e = hs.data.get(id);
                hs.data.delete(id);
                if (e) out.push(e);
            }
            return out;
        },

        _giBellRemove(groupId) {
            if (!Array.isArray(this.notificationHistory)) return;
            const id = G().notifyId(groupId);
            const before = this.notificationHistory.length;
            this.notificationHistory = this.notificationHistory.filter((n) => !(n && n.channelInfo && n.channelInfo.eventId === id));
            if (this.notificationHistory.length === before) return;
            if (typeof this._saveNotificationHistory === 'function') this._saveNotificationHistory();
            if (typeof this._updateNotificationBadge === 'function') this._updateNotificationBadge();
            if (typeof this._refreshNotificationsModalIfOpen === 'function') this._refreshNotificationsModalIfOpen();
        },

        _giHoldMedia(pk) {
            if (!pk || pk === this.pubkey) return;
            if (!this._giNoMedia) this._giNoMedia = new Set();
            this._giNoMedia.add(pk);
        },

        _giReleaseMedia(pk) {
            if (!pk || !this._giNoMedia || !this._giNoMedia.delete(pk)) return;
            const pic = this.userAvatars && this.userAvatars.get(pk);
            if (pic && typeof this.cacheAvatarImage === 'function') this.cacheAvatarImage(pk, pic);
            if (pic && typeof this.updateRenderedAvatars === 'function') this.updateRenderedAvatars(pk, pic);
            const banner = this.userBanners && this.userBanners.get(pk);
            if (banner && typeof this.cacheBannerImage === 'function') this.cacheBannerImage(pk, banner);
        },

        _giForget(groupId) {
            this._giHoldClear(groupId);
            this._giBellRemove(groupId);
        },

        _giChanged() {
            this._giRender();
            const modal = document.getElementById(MODAL);
            if (modal && modal.classList.contains('active')) this._giRenderModal();
        },

        _giWho(pk) {
            const mask = typeof this._actorMask === 'function' ? this._actorMask(pk) : '';
            return mask || (typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(pk) : '');
        },

        _giName(item) {
            const masked = (typeof this._actorMask === 'function' && !!this._actorMask(item.by))
                || (item.n && typeof this.hasBlockedKeyword === 'function' && this.hasBlockedKeyword(item.n, '', ''));
            const label = typeof this._groupLabel === 'function' ? this._groupLabel({ name: masked ? '' : item.n }) : (masked ? '' : item.n);
            return label && label !== 'Group' ? label : this._gi(G().STRINGS.group);
        },

        async _giGate(rumor, event, senderPubkey, isOwn, ctx) {
            const c = ctx || {};
            const groupId = tagOf(rumor, 'g');
            if (!groupId) return false;
            const type = tagOf(rumor, 'type');
            const blockedSender = !isOwn && !!this.blockedUsers && this.blockedUsers.has(senderPubkey);
            const archive = () => { if (!c.fromD1 && !blockedSender && event && typeof this._archivePMEvent === 'function') this._archivePMEvent(event); };
            if (typeof this._gtPendingJoins === 'function') this._gtPendingJoins();
            const left = !!this.leftGroups && this.leftGroups.has(groupId);
            const joined = !!this.groupConversations && this.groupConversations.has(groupId) && !left;
            const started = (!!this._pendingInviteJoins && this._pendingInviteJoins.has(groupId))
                || (!!this._giAccepting && this._giAccepting.has(groupId));
            if (this._giAccepting && this._giAccepting.has(groupId)) return true;
            if (isOwn || joined || started) this._giReleaseMedia(senderPubkey);
            if (isOwn || joined || started) { archive(); return true; }
            if (c.unbansSelf) return this._giUnban(rumor, senderPubkey, blockedSender, archive, c);
            if (!(await this._giReady())) return false;
            const inviteLike = type === 'group-invite' || type === 'group-add-member';
            if (inviteLike && !blockedSender && typeof this._fetchShownProfile === 'function') {
                if (!(this.users && this.users.has(senderPubkey))) this._giHoldMedia(senderPubkey);
                try { await this._fetchShownProfile(senderPubkey); } catch (_) { }
            }
            const st = this._giState();
            const now = nowSec();
            const pending = st.items.find((i) => i.gid === groupId) || null;
            const genesis = typeof this._verifyGroupGenesis === 'function'
                ? this._verifyGroupGenesis(groupId, tagOf(rumor, 'gowner'), tagOf(rumor, 'gnonce')) : null;
            const it = G().inviteTime(rumor.created_at, now);
            const input = {
                anon: false, own: false, joined: false, started: false,
                blocked: blockedSender,
                hidden: typeof this.isPersonHidden === 'function' && this.isPersonHidden(senderPubkey),
                accept: this.settings && this.settings.acceptPMs ? this.settings.acceptPMs : 'enabled',
                friend: typeof this.isFriend === 'function' && this.isFriend(senderPubkey),
                type, genesis, sender: senderPubkey, gowner: tagOf(rumor, 'gowner'), owner: tagOf(rumor, 'owner'),
                pending, it, now,
                decision: st.dec[groupId] || null,
                left, leftAt: left ? Math.floor((this.leftGroupTimes && this.leftGroupTimes.get(groupId)) || 0) : 0,
                bytes: G().rumorBytes(rumor),
            };
            const verdict = G().gate(input);
            if (verdict.v === 'hold') {
                this._giHoldPut(groupId, { rumor, event, senderPubkey, senderVerified: c.senderVerified, isPqWrap: !!c.isPqWrap, live: !c.fromD1 });
                return false;
            }
            if (verdict.v !== 'pending-new' && verdict.v !== 'pending-update') return false;
            const item = Object.assign(G().itemFrom({ gid: groupId, it, sender: senderPubkey, type, rumor, now, left: verdict.left, wrapId: event && event.id }), { pq: !!c.isPqWrap });
            const friends = st.items.filter((i) => typeof this.isFriend === 'function' && this.isFriend(i.by)).map((i) => i.by);
            const applied = G().pendingApply(st.items, verdict, item, friends);
            if (!applied.changed) return false;
            if (verdict.v === 'pending-update' && !verdict.boot) {
                const kept = applied.list.find((i) => i.gid === groupId);
                if (kept && pending) kept.pq = !!pending.pq;
            }
            const next = Object.assign({}, st, { items: applied.list });
            for (const gid of applied.evicted) this._giForget(gid);
            if (!c.fromD1) {
                const ad = G().archiveDecision(st.as, { verdict: verdict.v, boot: !!verdict.boot, kept: applied.list.some((i) => i.gid === groupId), by: senderPubkey, now });
                next.as = ad.state;
                if (ad.archive) archive();
            }
            const backlog = !!c.fromD1 || !!(c.gap && c.gap.stale) || (typeof this._isGiftWrapBacklog === 'function' && this._isGiftWrapBacklog(it));
            const nd = G().notifyDecision(st.ns, { verdict: verdict.v, now, live: G().isLive(it, now, backlog), toast: true, by: senderPubkey });
            next.ns = nd.state;
            this._giPersist(next);
            if (nd.bell && applied.list.some((i) => i.gid === groupId)) this._giNotify(applied.list.find((i) => i.gid === groupId), nd.banner);
            this._giChanged();
            return false;
        },

        async _giUnban(rumor, senderPubkey, blockedSender, archive, c) {
            const groupId = tagOf(rumor, 'g');
            c.unbanNotice = false;
            if (!(await this._giReady())) return false;
            if (!blockedSender) {
                if (!(this.users && this.users.has(senderPubkey))) this._giHoldMedia(senderPubkey);
                if (typeof this._fetchShownProfile === 'function') { try { await this._fetchShownProfile(senderPubkey); } catch (_) { } }
            }
            const st = this._giState();
            const now = nowSec();
            const grp = this.groupConversations ? this.groupConversations.get(groupId) : null;
            const d = G().unbanNotice(st.us, {
                gid: groupId,
                blocked: blockedSender,
                hidden: typeof this.isPersonHidden === 'function' && this.isPersonHidden(senderPubkey),
                accept: this.settings && this.settings.acceptPMs ? this.settings.acceptPMs : 'enabled',
                friend: typeof this.isFriend === 'function' && this.isFriend(senderPubkey),
                known: !!grp,
                role: grp ? (grp.createdBy === senderPubkey || (Array.isArray(grp.mods) && grp.mods.includes(senderPubkey))) : G().leftRole(st.lr, groupId, senderPubkey),
                it: G().inviteTime(rumor.created_at, now),
                leftAt: Math.floor((this.leftGroupTimes && this.leftGroupTimes.get(groupId)) || 0),
                now,
            });
            if (JSON.stringify(d.state) !== JSON.stringify(st.us)) this._giPersist(Object.assign({}, st, { us: d.state }));
            c.unbanNotice = d.notice;
            c.unbanGeneric = d.generic === true;
            if (d.archive) archive();
            return d.notice || d.archive;
        },

        async _giNoteLeft(groupId, roles) {
            const pk = this.pubkey;
            if (!pk || !roles || !(await this._giReady()) || this.pubkey !== pk) return;
            const st = this._giState();
            const lr = G().leftRolesNote(st.lr, groupId, roles.createdBy, roles.mods, [...(this.leftGroups || [])]);
            if (JSON.stringify(lr) === JSON.stringify(st.lr || {})) return;
            const next = Object.assign({}, st, { lr });
            if (this._giLocal()) this._giCache = { pk, state: next };
            else this._giPersist(next);
        },

        _giLeftRolesForSync() {
            const pk = this.pubkey;
            if (!pk || !this._giCache || this._giCache.pk !== pk) return {};
            const times = this.leftGroupTimes instanceof Map ? Object.fromEntries(this.leftGroupTimes) : {};
            return G().leftRolesSync(this._giCache.state && this._giCache.state.lr, [...(this.leftGroups || [])], times);
        },

        async _giMergeLeftRoles(incoming) {
            const pk = this.pubkey;
            if (!pk || !incoming || typeof incoming !== 'object' || !(await this._giReady()) || this.pubkey !== pk) return;
            const st = this._giState();
            const lr = G().leftRolesMerge(st.lr, incoming, [...(this.leftGroups || [])]);
            if (JSON.stringify(lr) === JSON.stringify(st.lr || {})) return;
            const next = Object.assign({}, st, { lr });
            if (this._giLocal()) this._giCache = { pk, state: next };
            else this._giPersist(next);
        },

        _giNotify(item, banner) {
            const name = this._giName(item);
            const nym = this._giWho(item.by);
            const title = this._gi(G().STRINGS.notifyTitle, { name });
            const body = this._gi(item.via === 'add' ? G().STRINGS.notifyAdd : G().STRINGS.notifyInvite, { nym });
            const info = { type: 'group-invite', groupId: item.gid, pubkey: item.by, eventId: G().notifyId(item.gid), stableId: true };
            const ts = item.it * 1000;
            this._giBellRemove(item.gid);
            if (banner && typeof this.showNotification === 'function') this.showNotification(title, body, info, ts);
            else if (typeof this._addNotificationToHistory === 'function') this._addNotificationToHistory(title, body, info, ts);
        },

        _giDecide(groupId, s, it) {
            const st = this._giState();
            const next = Object.assign({}, st, {
                items: G().pendingRemove(st.items, groupId),
                dec: G().decide(st.dec, groupId, s, it, nowSec()),
            });
            this._giPersist(next);
            this._giSyncSoon(0);
        },

        async giAccept(groupId, opts) {
            const o = opts || {};
            await this._giReady();
            const item = this._giState().items.find((i) => i.gid === groupId);
            if (!item) { if (o.notice !== false) this._giNoticeText(this._gi(G().STRINGS.stale)); this._giChanged(); return false; }
            if (this.leftGroups && this.leftGroups.has(groupId)) {
                this.leftGroups.delete(groupId);
                if (this.leftGroupTimes) this.leftGroupTimes.delete(groupId);
                if (typeof this._saveLeftGroups === 'function') this._saveLeftGroups();
                try { localStorage.setItem('nym_left_group_times', JSON.stringify(Object.fromEntries(this.leftGroupTimes || new Map()))); } catch (_) { }
            }
            this._giDecide(groupId, 'a', item.it);
            this._giBellRemove(groupId);
            this._giReleaseMedia(item.by);
            if (item.owner && item.owner !== item.by) this._giReleaseMedia(item.owner);
            const held = this._giHoldClear(groupId);
            if (!this._giAccepting) this._giAccepting = new Set();
            this._giAccepting.add(groupId);
            const ev = { id: item.wrapId || item.rumor.id || '', kind: 1059, created_at: item.it, tags: [], content: '' };
            try {
                await this.handleGroupMessage(item.rumor, ev, item.owner || item.by, false, true, !!item.pq, null, false);
                const joined = this.groupConversations && this.groupConversations.has(groupId);
                if (joined && item.via === 'add' && typeof this._announceGroupEphemeralKey === 'function') {
                    this._announceGroupEphemeralKey(groupId, { replay: false, ts: nowSec(), x: tagOf(item.rumor, 'x') }).catch(() => { });
                }
                if (joined) {
                    const stale = { stale: false, floorSec: Number.MAX_SAFE_INTEGER };
                    for (const h of held) {
                        if (h.live && h.event && h.event.kind === 1059 && typeof this._archivePMEvent === 'function') this._archivePMEvent(h.event);
                        try { await this.handleGroupMessage(h.rumor, h.event, h.senderPubkey, false, h.senderVerified, h.isPqWrap, stale, true); } catch (_) { }
                    }
                }
            } finally {
                this._giAccepting.delete(groupId);
            }
            const ok = !!(this.groupConversations && this.groupConversations.has(groupId));
            if (ok) {
                if (typeof this._saveGroupConversations === 'function') this._saveGroupConversations();
                if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(0);
                if (o.open !== false && typeof this.openGroup === 'function') this.openGroup(groupId);
                const g = this.groupConversations.get(groupId);
                const shown = typeof this._groupLabel === 'function' ? this._groupLabel(g) : (g && g.name) || '';
                if (o.notice !== false) this._giNoticeText(this._gi(G().STRINGS.joined, { name: shown }));
            } else if (o.notice !== false) {
                this._giNoticeText(this._gi(G().STRINGS.stale));
            }
            this._giChanged();
            return ok;
        },

        async giDecline(groupId, opts) {
            await this._giReady();
            const item = this._giState().items.find((i) => i.gid === groupId);
            if (!item) { this._giNoticeText(this._gi(G().STRINGS.stale)); this._giChanged(); return false; }
            this._giDecide(groupId, 'd', item.it);
            this._giForget(groupId);
            let text = this._gi(G().STRINGS.declined);
            if (opts && opts.block && item.by && !(this.blockedUsers && this.blockedUsers.has(item.by))) {
                const nym = this._giWho(item.by);
                if (typeof this.toggleBlockUserByPubkey === 'function') this.toggleBlockUserByPubkey(item.by);
                text = this._gi(G().STRINGS.declinedBlocked, { nym });
            }
            this._giNoticeText(text);
            this._giChanged();
            return true;
        },

        _giNoticeText(text) {
            this._giLastNotice = text;
            const live = document.getElementById('groupInvitesLive');
            if (live) { live.textContent = ''; live.textContent = text; }
            if (typeof this.displaySystemMessage === 'function') this.displaySystemMessage(text);
        },

        applySyncedGroupInvites(remote) {
            if (!remote || typeof remote !== 'object' || this._giLocal() || !this.pubkey) return;
            const go = () => {
                const now = nowSec();
                const st = this._giState();
                const theirs = G().normalizeDecisions(G().fromPayload(remote), now);
                const merged = G().mergeDecisions(st.dec, theirs, now);
                let items = st.items;
                for (const gid of Object.keys(merged)) {
                    const i = items.find((x) => x.gid === gid);
                    if (i && i.it <= merged[gid].dt) {
                        items = G().pendingRemove(items, gid);
                        this._giForget(gid);
                    }
                }
                const changed = JSON.stringify(merged) !== JSON.stringify(st.dec) || items !== st.items;
                if (changed) {
                    this._giPersist(Object.assign({}, st, { items, dec: merged }));
                    this._giChanged();
                }
                if (JSON.stringify(merged) !== JSON.stringify(theirs)) this._giSyncSoon(0);
            };
            if (this._giCache && this._giCache.pk === this.pubkey) go();
            else this._giReady().then((ok) => { if (ok) go(); }, () => { });
        },

        _giSyncSoon(ms) {
            if (this._giLocal()) return;
            if (this._giSyncTimer) clearTimeout(this._giSyncTimer);
            this._giSyncTimer = setTimeout(() => { this._giSyncTimer = null; this._giSync(); }, ms === undefined ? SYNC_DEBOUNCE_MS : ms);
        },

        async _giSync() {
            if (this._giLocal() || !this.pubkey || typeof this._publishCategoryWrap !== 'function') return false;
            const online = typeof this._ctOnline === 'function' ? this._ctOnline() : !!this.connected;
            if (!online || this._acctGoing) { this._giSyncSoon(5000); return false; }
            const now = nowSec();
            const dec = G().normalizeDecisions(this._giState().dec, now);
            const payload = { [G().KEYS.payload]: JSON.parse(JSON.stringify(G().publishable(dec))) };
            try {
                const changed = await this._publishCategoryWrap(payload, G().KEYS.dTag, now, [G().trimPayload]);
                if (changed && typeof this._publishSettingsChangedPing === 'function') await this._publishSettingsChangedPing([G().KEYS.section], now);
                return true;
            } catch (_) {
                this._giSyncSoon(5000);
                return false;
            }
        },

        _giRender() {
            const row = document.getElementById('groupInvitesRow');
            if (!row) return;
            if (!row._giBound) {
                row._giBound = true;
                row.addEventListener('click', () => this.openGroupInvites());
            }
            const n = this._giCache && this._giCache.pk === this.pubkey ? this._giCache.state.items.length : 0;
            row.hidden = n < 1;
            row.setAttribute('aria-label', this._gi(G().STRINGS.rowLabel, { n }));
            const label = row.querySelector('.gi-row-label');
            if (label) label.textContent = this._gi(G().STRINGS.title);
            const badge = row.querySelector('.gi-row-count');
            if (badge) badge.textContent = String(n);
        },

        async openGroupInvites(groupId) {
            await this._giReady();
            if (typeof this._ctModal !== 'function') return;
            const { modal } = this._ctModal(MODAL, this._gi(G().STRINGS.title));
            const header = modal.querySelector('.ct-modal-header');
            if (header) { header.id = MODAL + 'Title'; modal.setAttribute('aria-labelledby', header.id); }
            if (!modal._giBound) {
                modal._giBound = true;
                modal.addEventListener('click', (e) => this._giModalClick(e));
            }
            this._giRenderModal();
            const card = groupId ? modal.querySelector(`[data-gi-card="${CSS.escape(groupId)}"]`) : null;
            const target = card || modal.querySelector('.gi-card');
            if (target && target.scrollIntoView) target.scrollIntoView({ block: 'nearest' });
            const focus = (card || modal).querySelector('[data-gi="accept"]') || modal.querySelector('.modal-close');
            if (focus) focus.focus();
        },

        _giRenderModal() {
            const modal = document.getElementById(MODAL);
            if (!modal) return;
            const body = modal.querySelector('.ct-modal-body');
            const esc = (s) => this.escapeHtml(String(s));
            const S = G().STRINGS;
            const items = this._giList();
            const now = nowSec();
            const capMax = this.MAX_GROUP_MEMBERS || 100;
            const ago = (t) => (typeof this._formatRelativeTime === 'function' ? this._formatRelativeTime(t * 1000) : new Date(t * 1000).toLocaleString());
            const cards = items.map((i) => {
                const name = this._giName(i);
                const nym = this._giWho(i.by);
                const lineT = this._gi(i.via === 'add' ? S.addedBy : S.invitedBy, { nym: '\u0000' }).split('\u0000');
                const line = `${esc(lineT[0])}<span data-no-i18n translate="no">${esc(nym)}</span>${esc(lineT.slice(1).join(''))}`;
                const left = i.left ? `<div class="gt-inv-note">${esc(this._gi(S.leftBefore))}</div>` : '';
                const gid = esc(i.gid);
                return `<li class="gt-inv-card gi-card" data-gi-card="${gid}">
                    <div class="gt-inv-head"><span class="gt-inv-avatar gt-inv-avatar-empty">${ICON}</span><div class="gt-inv-name" data-no-i18n translate="no">${esc(name)}</div></div>
                    <div class="gt-inv-desc gi-by">${line}</div>
                    <div class="gt-inv-members">${esc(this._gi(S.members, { n: i.m, max: capMax }))} · <span>${esc(ago(Math.min(i.it, now)))}</span></div>${left}
                    <div class="gt-inv-actions">
                        <button type="button" class="icon-btn gi-more" data-gi="more" data-gid="${gid}" aria-haspopup="true" aria-expanded="false" aria-label="${esc(this._gi(S.more))}">⋯</button>
                        <button type="button" class="icon-btn" data-gi="decline" data-gid="${gid}" aria-label="${esc(this._gi(S.declineLabel, { group: name }))}">${esc(this._gi(S.decline))}</button>
                        <button type="button" class="send-btn" data-gi="accept" data-gid="${gid}" aria-label="${esc(this._gi(S.acceptLabel, { group: name }))}">${esc(this._gi(S.accept))}</button>
                    </div>
                    <div class="gi-menu" hidden><button type="button" class="icon-btn" data-gi="block" data-gid="${gid}"><span>${esc(this._gi(S.declineBlock, { nym: '\u0000' }).split('\u0000')[0])}</span><span data-no-i18n translate="no">${esc(nym)}</span><span>${esc(this._gi(S.declineBlock, { nym: '\u0000' }).split('\u0000').slice(1).join(''))}</span></button></div>
                </li>`;
            }).join('');
            body.innerHTML = (items.length ? `<ul class="gi-list" aria-labelledby="${MODAL}Title">${cards}</ul>` : `<div class="gt-inv-note gi-empty">${esc(this._gi(S.empty))}</div>`)
                + '<div class="gi-live visually-hidden" id="groupInvitesLive" role="status" aria-live="polite"></div>';
        },

        async _giModalClick(e) {
            const b = e.target.closest('[data-gi]');
            if (!b) return;
            e.preventDefault();
            const gid = b.dataset.gid;
            const act = b.dataset.gi;
            if (act === 'more') {
                const menu = b.closest('.gi-card').querySelector('.gi-menu');
                menu.hidden = !menu.hidden;
                b.setAttribute('aria-expanded', menu.hidden ? 'false' : 'true');
                if (!menu.hidden) menu.querySelector('button').focus();
                return;
            }
            const list = this._giList().map((i) => i.gid);
            const at = list.indexOf(gid);
            const nextGid = at >= 0 ? (list[at + 1] || list[at - 1] || null) : null;
            let text = '';
            if (act === 'accept') {
                const ok = await this.giAccept(gid);
                if (ok) { this._ctCloseModal(MODAL); return; }
            } else if (act === 'decline' || act === 'block') {
                this._giLastNotice = '';
                await this.giDecline(gid, { block: act === 'block' });
                text = this._giLastNotice || '';
            }
            this._giRenderModal();
            const live = document.getElementById('groupInvitesLive');
            if (live && text) live.textContent = text;
            const modal = document.getElementById(MODAL);
            const card = nextGid && modal ? modal.querySelector(`[data-gi-card="${CSS.escape(nextGid)}"] [data-gi="accept"]`) : null;
            const focus = card || (modal && modal.querySelector('.modal-close'));
            if (focus) focus.focus();
        },
    });

    const wrap = (name, fn) => {
        const orig = NYM.prototype[name];
        if (typeof orig !== 'function') return;
        NYM.prototype[name] = function (...args) { return fn.call(this, orig, ...args); };
    };

    wrap('_openNotificationTarget', function (orig, n) {
        const info = n && n.channelInfo;
        if (info && info.type === 'group-invite') { this.openGroupInvites(info.groupId); return; }
        return orig.call(this, n);
    });
})();
