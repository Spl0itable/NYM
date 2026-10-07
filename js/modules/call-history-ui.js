(function () {
    const H = () => window.NymCallHistory;
    const KEY = 'nym_call_history';
    const KEEP_KEY = 'nym_keep_call_history';
    const CLEARED_KEY = 'nym_call_history_cleared:';
    const MODAL = 'gtCallLinksModal';
    const PHONE = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"></path></svg>';
    const VIDEO = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polygon points="23 7 16 12 23 17 23 7"></polygon><rect x="1" y="5" width="15" height="14" rx="2" ry="2"></rect></svg>';
    const LABELS = { missed: 'Missed', incoming: 'Incoming', outgoing: 'Outgoing' };

    function lsGet(k) { try { return localStorage.getItem(k); } catch (_) { return null; } }
    function lsSet(k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (_) { } }

    Object.assign(NYM.prototype, {

        _chText(s) { return typeof this.uiText === 'function' ? this.uiText(s) : s; },

        _chKeep() { return lsGet(KEEP_KEY) !== 'off'; },

        _chKeepTs() {
            const m = typeof this._prefStamps === 'function' ? this._prefStamps() : {};
            return m.keepCallHistory > 0 ? m.keepCallHistory : 0;
        },

        async _chReconcileRow(row) {
            const M = window.NymSyncMerge;
            if (!this.pubkey || !H() || !M || typeof M.callsRowAction !== 'function') return;
            const act = M.callsRowAction(this._chKeep(), this._chKeepTs(), row);
            if (act !== 'clear' && act !== 'delete') return;
            const s = this._chLoad();
            if (s.items.length || s.seen) this._chClear(true);
            if (act === 'delete' && typeof this._deleteSettingsCategory === 'function') {
                this._chDeletePending = true;
                if (await this._deleteSettingsCategory('nymchat-calls')) this._chDeletePending = false;
            }
        },

        _chLoad() {
            const owner = this.pubkey || '';
            if (!this._chStore || this._chStore.owner !== owner) this._chStore = H().decode(lsGet(KEY), owner);
            return this._chStore;
        },

        _chSave(store, fromSync) {
            this._chStore = store;
            if (!store.items.length && !store.seen) lsSet(KEY, null);
            else lsSet(KEY, H().encode(store));
            this._chRenderBadges();
            this._chRefreshIfOpen();
            if (!fromSync) this._chChanged();
        },

        _chChanged() {
            if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(3000);
        },

        _chClearedAt() {
            const v = parseInt(lsGet(CLEARED_KEY + (this.pubkey || '')) || '0', 10);
            return v > 0 ? v : 0;
        },

        _chSetClearedAt(ms) {
            if (!this.pubkey || !(ms > this._chClearedAt())) return;
            lsSet(CLEARED_KEY + this.pubkey, String(Math.floor(ms)));
        },

        _chSyncPayload() {
            if (!this.pubkey || !H()) return null;
            if (!this._chKeep()) return { on: false, clearedAt: this._chClearedAt() };
            const s = this._chLoad();
            return { on: true, clearedAt: this._chClearedAt(), seen: s.seen || 0, items: s.items.slice(), keepTs: this._chKeepTs() };
        },

        _chApplySynced(raw) {
            const M = window.NymSyncMerge;
            if (!this.pubkey || !H() || !M || !raw || typeof raw !== 'object') return;
            const remote = M.callsNorm(raw);
            this._chSetClearedAt(remote.clearedAt);
            if (!this._chKeep()) return;
            const s = this._chLoad();
            const merged = M.callsMerge({ clearedAt: this._chClearedAt(), seen: s.seen, items: s.items }, remote);
            const next = { v: 1, owner: s.owner, seen: merged.seen, items: merged.items };
            if (H().encode(next) !== H().encode(s)) this._chSave(next, true);
        },

        _chRecord(rec) {
            if (!this.pubkey || !this._chKeep() || !H()) return;
            this._chSave(H().upsert(this._chLoad(), rec));
        },

        _chBegin(ac, dir, peer, at) {
            if (!ac) return;
            ac._ch = { id: ac.callId, peer: peer || '', group: (ac.isGroup && ac.groupId) || '', kind: ac.kind, dir, at: at || Date.now(), dur: 0, missed: false };
            this._chRecord(ac._ch);
        },

        _chFinish(ac) {
            if (!ac || !ac._ch) return;
            const dur = ac.startedAt ? Math.floor((Date.now() - ac.startedAt) / 1000) : 0;
            this._chRecord(Object.assign({}, ac._ch, { dur }));
            ac._ch = null;
        },

        _chMissed(callId, from, kind, isGroup, groupId, whenMs) {
            this._chRecord({ id: callId, peer: from || '', group: (isGroup && groupId) || '', kind, dir: 'in', at: whenMs || Date.now(), dur: 0, missed: true });
        },

        _chDeclined(inc) {
            if (!inc) return;
            this._chRecord({ id: inc.callId, peer: inc.from || '', group: (inc.isGroup && inc.groupId) || '', kind: inc.kind, dir: 'in', at: inc.chAt || Date.now(), dur: 0, missed: false });
        },

        _chAnsweredElsewhere(callId) {
            if (!this.pubkey || !H()) return;
            const r = this._chLoad().items.find((x) => x.id === callId && x.missed);
            if (r) this._chSave(H().upsert(this._chLoad(), Object.assign({}, r, { missed: false })));
        },

        _chClear(fromSync) {
            this._chSetClearedAt(Date.now());
            this._chStore = H().empty(this.pubkey || '');
            lsSet(KEY, null);
            this._chRenderBadges();
            this._chRefreshIfOpen();
            if (!fromSync) this._chChanged();
        },

        setKeepCallHistory(on, opts) {
            const fromSync = !!(opts && opts.fromSync);
            const was = this._chKeep();
            lsSet(KEEP_KEY, on ? null : 'off');
            if (!on && (was || (this._chStore && this._chStore.items.length))) this._chClear(true);
            if (on && !was) {
                const ts = opts && typeof opts.ts === 'number' && opts.ts > 0 ? opts.ts : Date.now();
                this._chSetClearedAt(ts);
            }
            if (!on && !fromSync) this._chDeletePending = true;
            const sel = document.getElementById('keepCallHistorySelect');
            if (sel) sel.value = on ? 'on' : 'off';
            if (!fromSync && typeof this.notePrefChanged === 'function') this.notePrefChanged('keepCallHistory');
        },

        _chHidden() {
            return (r) => this._chLocked(r);
        },

        _chRenderBadges() {
            const n = this.pubkey && H() ? H().missedCount(this._chLoad(), this._chHidden()) : 0;
            for (const id of ['callsBadgeSidebar', 'callsBadgeMore']) {
                const b = document.getElementById(id);
                if (!b) continue;
                b.textContent = n > 99 ? '99+' : String(n);
                b.classList.toggle('nm-hidden', !n);
            }
        },

        openCalls(tab) {
            const { modal, body } = this._ctModal(MODAL, this._chText('Calls'));
            modal.classList.add('ch-modal');
            const esc = (s) => this.escapeHtml(String(s));
            body.innerHTML = `<div class="ch-tabs" role="tablist" aria-label="${esc(this._chText('Calls'))}">
                <button type="button" class="ch-tab" role="tab" id="chTabRecent" aria-controls="chRecentPanel" data-action="chTab" data-tab="recent">${esc(this._chText('Recent'))}</button>
                <button type="button" class="ch-tab" role="tab" id="chTabLinks" aria-controls="chLinksPanel" data-action="chTab" data-tab="links">${esc(this._chText('Call links'))}</button>
            </div>
            <div class="ch-panel" id="chRecentPanel" role="tabpanel" aria-labelledby="chTabRecent"></div>
            <div class="ch-panel" id="chLinksPanel" role="tabpanel" aria-labelledby="chTabLinks"></div>`;
            this._chShowTab(tab === 'links' ? 'links' : 'recent');
        },

        _chShowTab(tab) {
            const modal = document.getElementById(MODAL);
            if (!modal) return;
            for (const t of modal.querySelectorAll('.ch-tab')) {
                const on = t.dataset.tab === tab;
                t.setAttribute('aria-selected', on ? 'true' : 'false');
                t.tabIndex = on ? 0 : -1;
                t.classList.toggle('active', on);
            }
            const recent = document.getElementById('chRecentPanel');
            const links = document.getElementById('chLinksPanel');
            recent.classList.toggle('nm-hidden', tab !== 'recent');
            links.classList.toggle('nm-hidden', tab !== 'links');
            this._chTab = tab;
            if (tab === 'links') {
                this._gtRenderCallLinks(links);
            } else {
                this._chRenderRecent(recent);
                if (this.pubkey && H() && H().missedCount(this._chLoad(), this._chHidden())) this._chSave(H().markSeen(this._chLoad(), Date.now()));
            }
        },

        _chRefreshIfOpen() {
            const modal = document.getElementById(MODAL);
            if (!modal || !modal.classList.contains('active') || this._chTab !== 'recent') return;
            const panel = document.getElementById('chRecentPanel');
            if (panel) this._chRenderRecent(panel);
        },

        _chLocked(r) {
            if (typeof this._clNotifLocked !== 'function') return false;
            try { return !!this._clNotifLocked({ type: 'call', isGroup: !!r.group, groupId: r.group, pubkey: r.peer }); } catch (_) { return false; }
        },

        _chWho(r) {
            const esc = (s) => this.escapeHtml(String(s));
            const g = r.group && this.groupConversations && this.groupConversations.get(r.group);
            if (r.group) {
                const members = g && Array.isArray(g.members) ? g.members : (r.peer ? [this.pubkey, r.peer] : [this.pubkey]);
                return { avatar: this._groupAvatarHtml(r.group, members), name: esc(g && g.name ? g.name : this._chText('Group call')) };
            }
            const sk = this._safePubkey(r.peer);
            return {
                avatar: `<img src="${esc(this.getAvatarUrl(r.peer))}" class="avatar-message" data-avatar-pubkey="${sk}" alt="" decoding="async" loading="lazy">`,
                name: this._callNymHtml(r.peer, { name: this._callPeerName(r.peer) }),
            };
        },

        _chRenderRecent(panel) {
            const esc = (s) => this.escapeHtml(String(s));
            const items = this.pubkey && H() ? H().visible(this._chLoad(), this._chHidden()) : [];
            if (!items.length) {
                panel.innerHTML = `<div class="ct-empty ch-empty">${esc(this._chText('No calls yet.'))}<div class="ch-empty-hint">${esc(this._chText('Calls you make and get show up here, on every device signed in with this identity.'))}</div></div>`;
                return;
            }
            const peers = items.filter((r) => r.peer && !r.group).map((r) => r.peer);
            if (peers.length && typeof this.ensureListProfiles === 'function') {
                try { this.ensureListProfiles(null, [...new Set(peers)].slice(0, 30), () => this._chRefreshIfOpen()); } catch (_) { }
            }
            const h12 = this.settings && this.settings.timeFormat === '12hr';
            const rows = items.map((r) => {
                const who = this._chWho(r);
                const lbl = H().label(r);
                const dur = r.missed ? '' : H().duration(r.dur);
                const time = new Date(r.at).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: h12 });
                const kindLabel = this._chText(r.kind === 'video' ? 'Video call' : 'Voice call');
                return `<div class="ch-row${r.missed ? ' ch-missed' : ''}" data-call-id="${esc(r.id)}" data-kind="${r.kind}">
                    <button type="button" class="ch-open" data-action="chOpenChat" data-call-id="${esc(r.id)}">
                        <span class="ch-avatar">${who.avatar}</span>
                        <span class="ch-main"><span class="ch-name">${who.name}</span>
                        <span class="ch-meta"><span class="ch-kind" role="img" aria-label="${esc(kindLabel)}">${r.kind === 'video' ? VIDEO : PHONE}</span><span class="ch-dir">${esc(this._chText(LABELS[lbl]))}</span><span class="ch-sep" aria-hidden="true">·</span><span class="ch-time">${esc(time)}</span>${dur ? `<span class="ch-sep" aria-hidden="true">·</span><span class="ch-dur">${esc(dur)}</span>` : ''}</span></span>
                    </button>
                    <button type="button" class="icon-btn ch-callback" data-action="chCallBack" data-call-id="${esc(r.id)}" aria-label="${esc(this._chText('Call back'))}" data-tip="">${r.kind === 'video' ? VIDEO : PHONE}</button>
                </div>`;
            }).join('');
            panel.innerHTML = `<div class="ch-head"><button type="button" class="icon-btn danger ch-clear" id="chClearBtn" data-action="chClearHistory">${esc(this._chText('Clear history'))}</button></div><div class="ch-list">${rows}</div>`;
        },

        _chFind(id) {
            return this.pubkey && H() ? this._chLoad().items.find((r) => r.id === id) || null : null;
        },

        _chOpenChatFor(r) {
            if (!r) return false;
            if (r.group && this.groupConversations && this.groupConversations.has(r.group)) {
                this.openGroup(r.group);
                return true;
            }
            if (r.peer && !r.group) {
                this.openUserPM(this._nymForPubkey(r.peer), r.peer);
                return true;
            }
            return false;
        },

        chOpenChat(id) {
            const r = this._chFind(id);
            this._ctCloseModal(MODAL);
            this._chOpenChatFor(r);
        },

        async chCallBack(id) {
            const r = this._chFind(id);
            this._ctCloseModal(MODAL);
            if (!this._chOpenChatFor(r)) return;
            await new Promise((done) => setTimeout(done, 50));
            await this.startCall(r.kind === 'video' ? 'video' : 'audio');
        },

        async chClearHistory() {
            const ok = await window.showAppConfirm(this._chText("Remove every call from this list on all your devices? This can't be undone."), { title: this._chText('Clear call history'), okLabel: this._chText('Clear'), danger: true });
            if (ok) this._chClear();
        },
    });

    if (typeof window !== 'undefined' && window.NYM_ACTIONS) {
        const nym = () => window.nym;
        Object.assign(window.NYM_ACTIONS, {
            chTab: function (_e, t) { nym()._chShowTab(t.dataset.tab); },
            chOpenChat: function (_e, t) { nym().chOpenChat(t.dataset.callId); },
            chCallBack: function (_e, t) { nym().chCallBack(t.dataset.callId); },
            chClearHistory: function () { nym().chClearHistory(); },
            onKeepCallHistoryChange: function (_e, t) { nym().setKeepCallHistory(!(t && t.value === 'off')); },
        });
    }

    if (typeof document !== 'undefined') {
        const sync = () => {
            const sel = document.getElementById('keepCallHistorySelect');
            if (sel) sel.value = lsGet(KEEP_KEY) === 'off' ? 'off' : 'on';
        };
        const boot = () => {
            sync();
            const n = window.nym;
            if (n && n.pubkey && typeof n._chRenderBadges === 'function') n._chRenderBadges();
            else setTimeout(boot, 1000);
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => setTimeout(boot, 500));
        else setTimeout(boot, 500);
    }
})();
