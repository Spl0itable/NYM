(function () {
    const C = () => window.NymChatTools;
    const ico = (p) => `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" class="nm-ico8">${p}</svg>`;
    const ICONS = {
        save: ico('<path d="M4 2.5h8v11l-4-3-4 3z"/>'),
        unsave: ico('<path d="M4 2.5h8v11l-4-3-4 3z"/><line x1="2.5" y1="2.5" x2="13.5" y2="13.5"/>'),
        replyPrivately: ico('<path d="M6 4 2 8l4 4"/><path d="M2 8h6.5a5 5 0 0 1 5 5"/><rect x="10" y="2" width="4" height="3.5" rx="0.6"/><path d="M10.8 2V1.4a1.2 1.2 0 0 1 2.4 0V2"/>'),
        keep: ico('<path d="M6 2h4l-.8 4 2.8 3H4l2.8-3z"/><line x1="8" y1="9" x2="8" y2="14"/>'),
        unkeep: ico('<path d="M6 2h4l-.8 4 2.8 3H4l2.8-3z"/><line x1="8" y1="9" x2="8" y2="14"/><line x1="2.5" y1="2.5" x2="13.5" y2="13.5"/>'),
        media: ico('<rect x="2" y="3" width="12" height="10" rx="1"/><circle cx="6" cy="6.8" r="1.2"/><path d="M2 11.5l3.5-3 3 2.5 2-1.8 3.5 3"/>'),
        exportChat: ico('<path d="M8 2v8"/><path d="M5 7l3 3 3-3"/><path d="M3 11.5V14h10v-2.5"/>'),
    };
    const KEEP_OUTBOX_KEY = 'nym_keep_outbox';
    const SWEEP_MS = 30000;
    const SAVED_FLUSH_MS = 10000;

    Object.assign(NYM.prototype, {

        _ct(text, vars) {
            let s = typeof this.uiText === 'function' ? this.uiText(text) : text;
            if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
            return s;
        },

        _ctNotice(text) {
            if (typeof this.displaySystemMessage === 'function') this.displaySystemMessage(text);
        },

        _ctStores() {
            return [this.messages, this.pmMessages].filter((s) => s && typeof s.forEach === 'function');
        },

        _ctFindMessage(id) {
            if (!id) return null;
            for (const store of this._ctStores()) {
                for (const [key, list] of store) {
                    if (!Array.isArray(list)) continue;
                    for (const m of list) {
                        if (m && (m.id === id || m.nymMessageId === id)) return { msg: m, key };
                    }
                }
            }
            return null;
        },

        _ctSurfaceForKey(key) {
            const k = String(key || '');
            if (k.startsWith('pm-')) return 'dm';
            if (k.startsWith('group-')) return 'group';
            return 'channel';
        },

        _ctPeerFromKey(key) {
            const k = String(key || '');
            if (!k.startsWith('pm-')) return '';
            const parts = k.slice(3).split('-');
            const other = parts.find((p) => p && p !== this.pubkey);
            return other || parts[0] || '';
        },

        _ctDisplayNym(pubkey, fallback) {
            if (!pubkey) return fallback || '';
            const raw = typeof this.resolveDisplayNym === 'function' ? this.resolveDisplayNym(pubkey, fallback || '') : (fallback || '');
            const base = typeof this.stripPubkeySuffix === 'function' ? this.stripPubkeySuffix(raw || 'nym') : (raw || 'nym');
            if (!/^[0-9a-f]{64}$/i.test(pubkey)) return base;
            const suffix = typeof this.getPubkeySuffix === 'function' ? this.getPubkeySuffix(pubkey) : pubkey.slice(-4);
            return `${base}#${suffix}`;
        },

        _ctChatInfo(key, from) {
            const t = this._ctSurfaceForKey(key);
            if (t === 'dm') {
                const peer = this._ctPeerFromKey(key);
                const fallback = from && from.pubkey === peer ? from.author : '';
                return { t, k: 'pm-' + peer, n: this._ctDisplayNym(peer, fallback) };
            }
            if (t === 'group') {
                const gid = String(key).slice(6);
                const g = this.groupConversations && this.groupConversations.get(gid);
                return { t, k: key, n: (g && g.name) || this._ct('Group') };
            }
            const name = String(key || '').replace(/^#/, '');
            return { t, k: key.startsWith('#') ? key : '#' + name, n: '#' + name };
        },

        _ctNorm(m) {
            return {
                id: m.id,
                nid: m.nymMessageId || '',
                pubkey: m.pubkey || '',
                author: m.pubkey ? this._ctDisplayNym(m.pubkey, m.author) : (m.author || ''),
                content: m.content || '',
                at: Number(m.created_at) || Math.floor(((m.timestamp && m.timestamp.getTime && m.timestamp.getTime()) || 0) / 1000),
                edited: !!m.isEdited,
                system: !m.pubkey || m.isSystem === true,
                fileOffer: m.isFileOffer && m.fileOffer ? { name: m.fileOffer.name, size: m.fileOffer.size } : null,
            };
        },

        _ctChatMessages(key) {
            const k = String(key || '');
            const isPm = k.startsWith('pm-') || k.startsWith('group-');
            const store = isPm ? this.pmMessages : this.messages;
            const list = (store && (store.get(k) || (!isPm && store.get(k.replace(/^#/, ''))))) || [];
            return list.filter((m) => m && !m.blocked
                && !(this.blockedUsers && this.blockedUsers.has(m.pubkey))
                && !(this.deletedEventIds && (this.deletedEventIds.has(m.id) || (m.nymMessageId && this.deletedEventIds.has(m.nymMessageId))))
                && !this._ctHidden(m));
        },

        _ctDomId(m) {
            return (m && m.isPM && m.nymMessageId) ? m.nymMessageId : (m && m.id);
        },

        _ctOnline() {
            const nav = typeof navigator !== 'undefined' ? navigator : null;
            return !!this.connected && !(nav && nav.onLine === false);
        },

        _savedStorageKey() {
            return C().SAVED_KEY + ':' + (this.pubkey || 'anon');
        },

        _savedPendingKey() {
            return C().SAVED_PENDING_KEY + ':' + (this.pubkey || 'anon');
        },

        _savedLoad() {
            if (this._savedCache && this._savedCache.pk === this.pubkey) return this._savedCache.state;
            let state = C().emptySaved();
            try {
                const raw = localStorage.getItem(this._savedStorageKey());
                if (raw) state = C().normalizeSaved(JSON.parse(raw));
            } catch (_) { state = C().emptySaved(); }
            this._savedCache = { pk: this.pubkey, state };
            return state;
        },

        _savedPersist(state) {
            this._savedCache = { pk: this.pubkey, state };
            try { localStorage.setItem(this._savedStorageKey(), JSON.stringify(state)); } catch (_) { }
        },

        _savedPending() {
            try { return localStorage.getItem(this._savedPendingKey()) === '1'; } catch (_) { return false; }
        },

        _savedSetPending(on) {
            try {
                if (on) localStorage.setItem(this._savedPendingKey(), '1');
                else localStorage.removeItem(this._savedPendingKey());
            } catch (_) { }
        },

        savedMode() {
            if (this.connectionMode === 'ephemeral') {
                let mode = 'persistent';
                try {
                    mode = localStorage.getItem('nym_keypair_mode') || (localStorage.getItem('nym_random_keypair_per_session') === 'true' ? 'random' : 'persistent');
                } catch (_) { }
                if (mode === 'random' || mode === 'hardcore') return 'local';
            }
            return 'sync';
        },

        savedStatus() {
            if (this.savedMode() === 'local') return 'local';
            return this._savedPending() ? 'pending' : 'synced';
        },

        isMessageSaved(m) {
            if (!m) return false;
            const id = m.nymMessageId || m.id;
            return C().isSaved(this._savedLoad(), id);
        },

        saveMessage(id) {
            const found = this._ctFindMessage(id);
            if (!found) {
                this._ctNotice(this._ct('This message is no longer available.'));
                return false;
            }
            const m = found.msg;
            const res = C().savedEntry(this._ctNorm(m), this._ctChatInfo(found.key, m), Date.now());
            if (res.error === 'once') {
                this._ctNotice(this._ct(C().STRINGS.onceNotSaved));
                return false;
            }
            if (!res.entry) return false;
            this._savedPersist(C().addSaved(this._savedLoad(), res.entry, Date.now()));
            this._savedRev = (this._savedRev || 0) + 1;
            this._savedSetPending(this.savedMode() === 'sync');
            this._ctNotice(this.savedStatus() === 'pending' && !this._ctOnline()
                ? this._ct('Saved. It will sync to your other devices when you are back online.')
                : this._ct('Saved to Saved messages.'));
            this._renderSavedPanel();
            this._savedSync();
            return true;
        },

        removeSavedMessage(id) {
            this._savedPersist(C().removeSaved(this._savedLoad(), id, Date.now()));
            this._savedRev = (this._savedRev || 0) + 1;
            this._savedSetPending(this.savedMode() === 'sync');
            this._renderSavedPanel();
            this._savedSync();
        },

        async _savedSync() {
            if (this.savedMode() !== 'sync') return 'local';
            if (!this._savedPending()) return 'synced';
            if (!this.pubkey || !this._ctOnline() || !this._settingsHydrated) return 'pending';
            if (this._savedSyncing) {
                this._savedResync = true;
                return 'pending';
            }
            this._savedSyncing = true;
            this._savedResync = false;
            const rev = this._savedRev || 0;
            let ok = false;
            try {
                const dTag = C().SAVED_DTAG;
                const payload = { savedMessages: JSON.parse(JSON.stringify(this._savedLoad())) };
                const json = JSON.stringify(payload);
                if (!this._publishedSectionJson) this._publishedSectionJson = {};
                ok = this._publishedSectionJson[dTag] === json;
                if (!ok && typeof this._publishCategoryWrap === 'function') {
                    const now = Math.floor(Date.now() / 1000);
                    const changed = await this._publishCategoryWrap(payload, dTag, now, [C().trimSavedPayload]);
                    ok = !!changed || this._publishedSectionJson[dTag] === JSON.stringify(payload);
                    if (changed && typeof this._publishSettingsChangedPing === 'function') {
                        await this._publishSettingsChangedPing(['saved'], now);
                    }
                }
            } catch (_) {
                ok = false;
            } finally {
                this._savedSyncing = false;
            }
            if (ok && rev === (this._savedRev || 0)) this._savedSetPending(false);
            this._renderSavedStatus();
            if (this._savedResync || (ok && rev !== (this._savedRev || 0))) {
                this._savedResync = false;
                return this._savedSync();
            }
            return this._savedPending() ? 'pending' : 'synced';
        },

        applySyncedSaved(remote) {
            if (!remote || typeof remote !== 'object') return;
            const local = this._savedLoad();
            const merged = C().mergeSaved(local, remote, Date.now());
            const remoteNorm = C().mergeSaved(remote, null, Date.now());
            this._savedPersist(merged);
            this._savedRev = (this._savedRev || 0) + 1;
            if (JSON.stringify(merged) !== JSON.stringify(remoteNorm) && this.savedMode() === 'sync') {
                this._savedSetPending(true);
                setTimeout(() => { this._savedSync(); }, 0);
            }
            this._renderSavedPanel();
        },

        openSavedPanel() {
            const { body } = this._ctModal('savedMessagesModal', this._ct('Saved messages'));
            body.classList.add('ct-saved-body');
            this._renderSavedPanel();
            this._savedSync();
        },

        _renderSavedStatus() {
            const el = typeof document !== 'undefined' ? document.getElementById('ctSavedStatus') : null;
            if (!el) return;
            const status = this.savedStatus();
            el.className = 'ct-status ct-status-' + status;
            el.textContent = status === 'local'
                ? this._ct('Saved on this device only')
                : status === 'pending'
                    ? this._ct('Will sync when online')
                    : this._ct('Synced across your devices');
        },

        _renderSavedPanel() {
            const modal = typeof document !== 'undefined' ? document.getElementById('savedMessagesModal') : null;
            if (!modal || !modal.classList.contains('active')) return;
            const body = modal.querySelector('.ct-modal-body');
            const items = this._savedLoad().items;
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            const rows = items.map((e) => {
                const when = this._formatFullTimestamp((e.at || 0) * 1000);
                const chat = e.chat.t === 'channel' ? e.chat.n : e.chat.t === 'group' ? this._ct('Group: {name}', { name: e.chat.n }) : this._ct('DM with {name}', { name: e.chat.n });
                return `<div class="ct-saved-item" data-saved-id="${esc(e.id)}">
                    <div class="ct-saved-meta"><span class="ct-saved-author">${esc(e.a.n)}</span><span class="ct-saved-chat">${esc(chat)}</span><span class="ct-saved-time">${esc(when)}</span></div>
                    <div class="ct-saved-text message-content">${this.formatMessageWithQuotes(e.text, 0)}</div>
                    <div class="ct-saved-actions">
                        <button type="button" class="ct-btn" data-action="ctSavedJump" data-saved-id="${esc(e.id)}">${esc(this._ct('Jump to original'))}</button>
                        <button type="button" class="ct-btn danger" data-action="ctSavedRemove" data-saved-id="${esc(e.id)}">${esc(this._ct('Remove'))}</button>
                    </div>
                </div>`;
            }).join('');
            body.innerHTML = `<div id="ctSavedStatus"></div>${rows || `<div class="ct-empty">${esc(this._ct('No saved messages yet. Use Save message on any message to keep a private copy here.'))}</div>`}`;
            this._renderSavedStatus();
        },

        savedJump(id) {
            const e = this._savedLoad().items.find((x) => x.id === id);
            if (!e) return;
            this._ctCloseModal('savedMessagesModal');
            const target = e.nid || e.mid;
            const found = this._ctFindMessage(e.nid) || this._ctFindMessage(e.mid);
            if (!found) {
                this._ctNotice(this._ct("The original message isn't loaded on this device anymore."));
                return;
            }
            if (typeof this.jumpToNostrRef === 'function') this.jumpToNostrRef(this._ctDomId(found.msg) || target);
        },

        _editStore() {
            if (this._ctEdits) return this._ctEdits;
            let store = {};
            try {
                const raw = localStorage.getItem(C().EDITS_KEY);
                const parsed = raw ? JSON.parse(raw) : null;
                if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) store = parsed;
            } catch (_) { store = {}; }
            this._ctEdits = store;
            return store;
        },

        _noteEdit(msg, nextContent, editAtSec) {
            if (!msg || typeof nextContent !== 'string') return;
            const key = this._ctDomId(msg);
            if (!key) return;
            const store = this._editStore();
            const at = Number(editAtSec) || Math.floor(Date.now() / 1000);
            const rec = C().recordEdit(store[key], msg.content, nextContent, msg.created_at, at);
            if (rec === store[key]) return;
            store[key] = rec;
            this._ctEdits = C().pruneEditStore(store);
            try { localStorage.setItem(C().EDITS_KEY, JSON.stringify(this._ctEdits)); } catch (_) { }
        },

        _noteStaleEdit(msg, text, editAtSec) {
            if (!msg || typeof text !== 'string') return;
            const key = this._ctDomId(msg);
            if (!key) return;
            const store = this._editStore();
            const rec = C().recordStaleEdit(store[key], text, editAtSec, msg.content);
            if (rec === store[key] || (!store[key] && !rec.versions.length)) return;
            store[key] = rec;
            this._ctEdits = C().pruneEditStore(store);
            try { localStorage.setItem(C().EDITS_KEY, JSON.stringify(this._ctEdits)); } catch (_) { }
        },

        editHistoryFor(domId) {
            return this._editStore()[domId] || null;
        },

        openEditHistory(domId) {
            const found = this._ctFindMessage(domId);
            const plan = C().editHistoryPlan(this.editHistoryFor(domId), {
                online: !!(found && found.msg.pubkey) && this._ehRemoteOk(),
                mesh: !!(found && found.msg.isMesh),
            });
            const { modal, body } = this._ctModal('editHistoryModal', this._ct('Edit history'));
            const token = (this._ehToken || 0) + 1;
            this._ehToken = token;
            this._renderEditHistory(body, domId, plan.view);
            if (!plan.fetch) return;
            this.fetchEditHistory(domId).then((view) => {
                if (this._ehToken !== token || !modal.classList.contains('active')) return;
                this._renderEditHistory(body, domId, view);
            });
        },

        _renderEditHistory(body, domId, view) {
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            const empty = (text) => `<div class="ct-empty">${esc(this._ct(text))}</div>`;
            if (view === 'loading') { body.innerHTML = empty('Loading...'); return; }
            if (view === 'notFound') { body.innerHTML = empty("Earlier versions couldn't be found."); return; }
            if (view !== 'versions') { body.innerHTML = empty("Earlier versions aren't available on this device."); return; }
            const found = this._ctFindMessage(domId);
            const current = found ? found.msg.content : '';
            body.innerHTML = C().editTimeline(this.editHistoryFor(domId), current).map((v) => `<div class="ct-version${v.current ? ' current' : ''}">
                <div class="ct-version-time">${esc(v.current ? this._ct('Current, edited {time}', { time: this._formatFullTimestamp(v.at * 1000) }) : this._formatFullTimestamp(v.at * 1000))}</div>
                <div class="ct-version-text message-content">${this.formatMessageWithQuotes(v.text, 0)}</div>
            </div>`).join('');
        },

        _ehRemoteOk() {
            return this._ctOnline() && !!(this._getApiHost && this._getApiHost());
        },

        async fetchEditHistory(domId) {
            const found = this._ctFindMessage(domId);
            if (!found || !found.msg.pubkey) return C().editHistoryPlan(this.editHistoryFor(domId), { done: true }).view;
            const L = C().LIMITS;
            const target = { id: domId, pubkey: found.msg.pubkey, at: Number(found.msg.created_at) || 0 };
            const surface = this._ctSurfaceForKey(found.key);
            const bag = [];
            let timer = null;
            const work = (surface === 'channel' ? this._ehChannelEvents(target, bag) : this._ehWrapEvents(surface, target, bag))
                .then(() => true, () => false);
            const ok = await Promise.race([work, new Promise((r) => { timer = setTimeout(() => r(false), L.editFetchTimeoutMs); })]);
            clearTimeout(timer);
            const live = this._ctFindMessage(domId);
            const store = this._editStore();
            const merged = C().mergeEditHistory(store[domId], C().editSources(target, bag), (live || found).msg.content);
            if (ok || merged.versions.length) {
                if (!ok) delete merged.fetched;
                store[domId] = merged;
                this._ctEdits = C().pruneEditStore(store);
                try { localStorage.setItem(C().EDITS_KEY, JSON.stringify(this._ctEdits)); } catch (_) { }
            }
            return C().editHistoryPlan(this.editHistoryFor(domId), { done: true }).view;
        },

        async _ehChannelEvents(target, bag) {
            const res = await this._storageApiRequest('channel-edits', { id: target.id }, false);
            const NT = window.NostrTools;
            for (const ev of (res && Array.isArray(res.events) ? res.events : [])) {
                if (!ev || (ev.kind !== 20000 && ev.kind !== 23333)) continue;
                let good = false;
                try { good = !!(NT && typeof NT.verifyEvent === 'function' && NT.verifyEvent(ev) === true); } catch (_) { good = false; }
                if (good) bag.push(ev);
            }
        },

        async _ehWrapEvents(surface, target, bag) {
            const L = C().LIMITS;
            const since = Math.max(0, target.at - L.editFetchSlackSec);
            const seen = new Set();
            const probe = (rumor, verified) => { if (verified === true && rumor) bag.push(rumor); };
            const page = async (extra, withAuth) => {
                let from = since;
                for (let i = 0; i < L.editFetchPages; i++) {
                    const wraps = [];
                    const resp = await this._storageApiStream('pm-get', Object.assign({ since: from, asc: true, limit: L.editFetchPageSize }, extra), withAuth);
                    await this._readNdjsonStream(resp, (ev) => { wraps.push(ev); });
                    for (const w of wraps) {
                        if (!w || typeof w.id !== 'string' || seen.has(w.id)) continue;
                        seen.add(w.id);
                        try { await this.handleGiftWrapDM(w, { fromD1: true, probe }); } catch (_) { }
                    }
                    const last = wraps.length ? Number(wraps[wraps.length - 1].created_at) || 0 : 0;
                    if (wraps.length < L.editFetchPageSize || last <= from) return;
                    from = last;
                }
            };
            const jobs = [];
            if (typeof this._pmArchiveAllowed === 'function' && this._pmArchiveAllowed()) jobs.push(page({}, true));
            if (surface === 'group' && typeof this._getAllSelfEphemeralPubkeys === 'function') {
                const pks = (this._getAllSelfEphemeralPubkeys() || []).slice(0, 200);
                if (pks.length) jobs.push(page({ pubkeys: pks }, false));
            }
            if (!jobs.length) throw new Error('no archive');
            const done = await Promise.allSettled(jobs);
            if (!done.some((d) => d.status === 'fulfilled')) throw new Error('archive unavailable');
        },

        _keepStore() {
            if (this._ctKeep) return this._ctKeep;
            let store = {};
            try {
                const raw = localStorage.getItem(C().KEEP_KEY);
                const parsed = raw ? JSON.parse(raw) : null;
                if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) store = parsed;
            } catch (_) { store = {}; }
            this._ctKeep = store;
            return store;
        },

        isMessageKept(m) {
            const nid = m && m.nymMessageId;
            return !!nid && C().isKept(this._keepStore(), nid);
        },

        _ctHidden(m) {
            if (!m || !m.expiresAt) return false;
            return C().isExpired(m.expiresAt, this.isMessageKept(m), Math.floor(Date.now() / 1000));
        },

        _keptBadgeHtml(m, irc) {
            if (!this.isMessageKept(m)) return '';
            const label = this.escapeHtml(this._ct('Kept'));
            const title = this.escapeHtml(this._ct('Kept in chat: this message will not disappear'));
            return `<span class="kept-indicator${irc ? ' kept-indicator-irc' : ''}" title="${title}">${label}</span>${irc ? '' : ' '}`;
        },

        _refreshKeptDom(nid) {
            if (typeof document === 'undefined' || typeof this.findMessageElementAnywhere !== 'function') return;
            const found = this._ctFindMessage(nid);
            const el = this.findMessageElementAnywhere(found ? this._ctDomId(found.msg) : nid);
            if (!el) return;
            el.querySelectorAll('.kept-indicator').forEach((x) => x.remove());
            if (!found || !this.isMessageKept(found.msg)) return;
            const holder = document.createElement('span');
            holder.innerHTML = this._keptBadgeHtml(found.msg, false);
            const inner = el.querySelector('.bubble-time-inner');
            if (inner && holder.firstChild) inner.insertBefore(holder.firstChild, inner.firstChild);
            const ircHolder = document.createElement('span');
            ircHolder.innerHTML = this._keptBadgeHtml(found.msg, true);
            const content = el.querySelector('.message-content');
            if (content && ircHolder.firstChild) content.after(ircHolder.firstChild);
        },

        _keepApply(nid, kept, at, by) {
            const store = this._keepStore();
            if (!C().applyKeep(store, nid, kept, at, by)) return false;
            this._ctKeep = C().pruneKeep(store);
            try { localStorage.setItem(C().KEEP_KEY, JSON.stringify(this._ctKeep)); } catch (_) { }
            this._refreshKeptDom(nid);
            if (!kept) this._expirySweep();
            return true;
        },

        keepAvailableFor(m, key) {
            if (!m) return false;
            return C().keepAvailable({
                nid: m.nymMessageId || '',
                surface: this._ctSurfaceForKey(key || m.conversationKey || ''),
                expiresAt: m.expiresAt || 0,
                kept: this.isMessageKept(m),
            });
        },

        async toggleKeepMessage(id) {
            const found = this._ctFindMessage(id);
            if (!found || !this.keepAvailableFor(found.msg, found.key)) return false;
            const m = found.msg;
            const kept = !this.isMessageKept(m);
            const at = this._keepNextAt(m.nymMessageId);
            this._keepApply(m.nymMessageId, kept, at, this.pubkey);
            const sent = await this._sendKeepControl(found.key, m.nymMessageId, kept, at);
            if (sent === 'queued') {
                this._ctNotice(this._ct(kept
                    ? "Kept here. Others will see it once you're back online."
                    : "Unkept here. Others will see it once you're back online."));
            } else if (sent === 'mesh') {
                this._ctNotice(this._ct(kept ? 'Kept. Sent over the Bluetooth mesh.' : 'Unkept. Sent over the Bluetooth mesh.'));
            }
            return true;
        },

        meshPmPeerId(pubkey) {
            const mesh = this._mesh;
            if (!mesh || !mesh.running || !pubkey) return null;
            const list = Array.isArray(mesh.peerList) ? mesh.peerList : [];
            const peer = list.find((p) => p && p.nostrPubkey === pubkey);
            return peer ? peer.peerID : null;
        },

        async _sendKeepControl(key, nid, kept, at) {
            const surface = this._ctSurfaceForKey(key);
            let route = null;
            if (surface === 'dm') {
                const peer = this._ctPeerFromKey(key);
                const peerID = this.meshPmPeerId(peer);
                if (peerID) {
                    try {
                        await this._mesh.sendReadReceipt(peerID, C().meshKeepId(nid, kept));
                        route = 'mesh';
                    } catch (_) { }
                }
            }
            if (!this._ctOnline() || !this._canSendKeepWraps()) {
                this._keepOutboxPush({ key, nid, kept, at });
                return route || 'queued';
            }
            const ok = await this._publishKeep(key, nid, kept, at);
            if (!ok) {
                this._keepOutboxPush({ key, nid, kept, at });
                return route || 'queued';
            }
            return route || 'sent';
        },

        _canSendKeepWraps() {
            return typeof this._canSendGiftWraps !== 'function' || this._canSendGiftWraps();
        },

        async _publishKeep(key, nid, kept, at) {
            const surface = this._ctSurfaceForKey(key);
            try {
                if (surface === 'group') {
                    const gid = String(key).slice(6);
                    const g = this.groupConversations && this.groupConversations.get(gid);
                    if (!g || !Array.isArray(g.members)) return false;
                    const rumor = { kind: 69420, created_at: at, tags: C().keepTags([nid], kept, null, gid), content: '', pubkey: this.pubkey };
                    await this._sendGiftWrapsAsync(g.members, rumor, null, gid);
                    return true;
                }
                if (surface === 'dm') {
                    const peer = this._ctPeerFromKey(key);
                    if (!peer || !/^[0-9a-f]{64}$/i.test(peer)) return false;
                    for (const to of [peer, this.pubkey]) {
                        const rumor = { kind: 69420, created_at: at, tags: C().keepTags([nid], kept, to, null), content: '', pubkey: this.pubkey };
                        if (this.privkey && typeof this._pmSignalWrapAsync === 'function') {
                            const wrapped = await this._pmSignalWrapAsync(rumor, to);
                            this.sendDMToRelays(['EVENT', wrapped]);
                        } else {
                            await this._sendGiftWrapsAsync([to], rumor, null);
                        }
                    }
                    return true;
                }
            } catch (_) { }
            return false;
        },

        _keepOutboxLoad() {
            try {
                const v = JSON.parse(localStorage.getItem(KEEP_OUTBOX_KEY) || '[]');
                return Array.isArray(v) ? v.filter((e) => e && typeof e.key === 'string' && typeof e.nid === 'string') : [];
            } catch (_) { return []; }
        },

        _keepOutboxPush(entry) {
            const list = this._keepOutboxLoad().filter((e) => !(e.key === entry.key && e.nid === entry.nid));
            list.push(entry);
            while (list.length > 200) list.shift();
            try { localStorage.setItem(KEEP_OUTBOX_KEY, JSON.stringify(list)); } catch (_) { }
        },

        async flushKeepOutbox() {
            if (this._keepFlushing || !this._ctOnline() || !this._canSendKeepWraps()) return;
            const list = this._keepOutboxLoad();
            if (!list.length) return;
            this._keepFlushing = true;
            const left = [];
            try {
                for (const e of list) {
                    if (!(await this._publishKeep(e.key, e.nid, !!e.kept, e.at))) left.push(e);
                }
            } finally {
                this._keepFlushing = false;
                try { localStorage.setItem(KEEP_OUTBOX_KEY, JSON.stringify(left)); } catch (_) { }
            }
        },

        handleKeepControl(rumor, senderPubkey, senderVerified) {
            if (!rumor || rumor.kind !== 69420) return false;
            const p = C().parseKeep(rumor);
            if (!p) return false;
            if (senderVerified !== true || !senderPubkey) return true;
            if (p.groupId) {
                const g = this.groupConversations && this.groupConversations.get(p.groupId);
                if (!g || !Array.isArray(g.members) || !g.members.includes(senderPubkey)) return true;
            }
            for (const id of p.ids) {
                const found = this._ctFindMessage(id);
                if (found) {
                    const surface = this._ctSurfaceForKey(found.key);
                    if (p.groupId && found.key !== 'group-' + p.groupId) continue;
                    if (!p.groupId && surface !== 'dm') continue;
                    if (!p.groupId && senderPubkey !== this.pubkey && senderPubkey !== this._ctPeerFromKey(found.key)) continue;
                }
                this._keepApply(id, p.kept, Number(rumor.created_at) || Math.floor(Date.now() / 1000), senderPubkey);
            }
            return true;
        },

        handleMeshKeep(r) {
            const parsed = C().parseMeshKeepId(r && r.messageId);
            if (!parsed) return false;
            const peer = this._mesh && this._mesh.peers && typeof this._mesh.peers.get === 'function'
                ? this._mesh.peers.get(r.fromPeerID) : null;
            const by = peer && peer.nostrPubkey ? peer.nostrPubkey : 'mesh:' + (r && r.fromPeerID);
            const found = this._ctFindMessage(parsed.id);
            if (found && this._ctSurfaceForKey(found.key) === 'dm' && peer && peer.nostrPubkey
                && peer.nostrPubkey !== this._ctPeerFromKey(found.key)) return true;
            this._keepApply(parsed.id, parsed.kept, this._keepNextAt(parsed.id), by);
            return true;
        },

        _keepNextAt(nid) {
            const cur = this._keepStore()[nid];
            return Math.max(Math.floor(Date.now() / 1000), cur ? (Number(cur.at) || 0) + 1 : 0);
        },

        _expirySweep() {
            if (!this.pmMessages || typeof this.pmMessages.forEach !== 'function') return 0;
            let removed = 0;
            for (const [key, list] of this.pmMessages) {
                if (!Array.isArray(list) || !list.some((m) => m && m.expiresAt)) continue;
                const gone = list.filter((m) => this._ctHidden(m));
                if (!gone.length) continue;
                this.pmMessages.set(key, list.filter((m) => !this._ctHidden(m)));
                removed += gone.length;
                if (this.channelDOMCache && typeof this.channelDOMCache.delete === 'function') this.channelDOMCache.delete(key);
                if (typeof this.persistPMMessages === 'function') this.persistPMMessages(key);
                if (typeof this.findMessageElementAnywhere === 'function') {
                    for (const m of gone) {
                        const el = this.findMessageElementAnywhere(this._ctDomId(m));
                        if (el) el.remove();
                    }
                }
            }
            return removed;
        },

        replyPrivately(id) {
            const found = this._ctFindMessage(id);
            if (!found) return false;
            const m = found.msg;
            const ok = C().replyPrivatelyAllowed({
                surface: this._ctSurfaceForKey(found.key), pubkey: m.pubkey, self: this.pubkey, system: !m.pubkey,
            });
            if (!ok) return false;
            if (/^mesh:/.test(m.pubkey)) {
                this._ctNotice(this._ct("This person is only on the Bluetooth mesh without a linked Nostr identity, and this app can't start a private chat with them. Use the Nymchat mobile app to reply privately over the mesh."));
                return false;
            }
            const nym = this._ctDisplayNym(m.pubkey, m.author);
            if (typeof this.openUserPM === 'function') this.openUserPM(nym, m.pubkey);
            if (typeof this.setQuoteReply === 'function') this.setQuoteReply(nym, m.content || '');
            if (!this.connected && !this.meshPmPeerId(m.pubkey)) {
                this._ctNotice(this._ct("You're offline. Your reply will need the internet or this person in Bluetooth range."));
            }
            return true;
        },

        async sendPMOverMesh(content, pubkey, peerID) {
            const mesh = this._mesh;
            if (!mesh || !mesh.running) {
                this._ctNotice(this._ct("The Bluetooth mesh isn't running."));
                return false;
            }
            let mid;
            try { mid = await mesh.sendPrivateMessage(peerID, content); } catch (err) {
                this._ctNotice(this._ct("Couldn't send over the Bluetooth mesh: {error}", { error: (err && err.message) || 'error' }));
                return false;
            }
            if (!mid) mid = Date.now().toString(16);
            if (mesh.linkCount === 0) this._ctNotice(this._ct('No mesh device in range — waiting for Bluetooth range.'));
            const nowMs = Date.now();
            const conversationKey = this.getPMConversationKey(pubkey);
            const msg = {
                id: 'mesh-pm-' + mid,
                nymMessageId: mid,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                created_at: Math.floor(nowMs / 1000),
                _ms: nowMs,
                _seq: ++this._msgSeq,
                timestamp: new Date(nowMs),
                isOwn: true,
                isMesh: true,
                isPM: true,
                conversationKey,
                conversationPubkey: pubkey,
                senderVerified: true,
                deliveryStatus: 'sent',
            };
            let list = this.pmMessages.get(conversationKey) || [];
            list.push(msg);
            if (typeof this._compareMessages === 'function') list.sort((a, b) => this._compareMessages(a, b));
            if (list.length > this.pmStorageLimit) list = list.slice(-this.pmStorageLimit);
            this.pmMessages.set(conversationKey, list);
            if (typeof this.persistPMMessages === 'function') this.persistPMMessages(conversationKey);
            if (typeof this.displayMessage === 'function') this.displayMessage(msg);
            return true;
        },

        openExportChat(key) {
            const msgs = this._ctChatMessages(key);
            const info = this._ctChatInfo(key);
            const { body } = this._ctModal('exportChatModal', this._ct('Export chat'));
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            this._ctExportKey = key;
            body.innerHTML = `<p class="ct-note">${esc(this._ct('Export {count} messages from {chat} that are on this device.', { count: msgs.length, chat: info.n }))}</p>
                <p class="ct-note">${esc(this._ct('The .zip adds media already downloaded to this device. View-once media is never exported.'))}</p>
                <div class="ct-export-actions">
                    <button type="button" class="ct-btn" data-action="ctExportTxt">${esc(this._ct('Text transcript (.txt)'))}</button>
                    <button type="button" class="ct-btn" data-action="ctExportZip">${esc(this._ct('Transcript and media (.zip)'))}</button>
                </div>`;
        },

        _ctOffsetMin() {
            return -new Date().getTimezoneOffset();
        },

        buildChatTranscript(key, mediaNames) {
            const info = this._ctChatInfo(key);
            return C().exportTranscript({
                title: info.n,
                messages: this._ctChatMessages(key).map((m) => this._ctNorm(m)),
                exportedAtMs: Date.now(),
                offsetMin: this._ctOffsetMin(),
                mediaNames: mediaNames || null,
                t: (s) => this._ct(s),
            });
        },

        _ctDownload(blob, name) {
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = name;
            a.rel = 'noopener';
            document.body.appendChild(a);
            a.click();
            a.remove();
            setTimeout(() => { try { URL.revokeObjectURL(url); } catch (_) { } }, 30000);
        },

        exportChatText(key) {
            const info = this._ctChatInfo(key);
            const text = this.buildChatTranscript(key);
            const name = C().exportFileName(info.n, Date.now(), this._ctOffsetMin(), 'txt');
            this._ctDownload(new Blob([text], { type: 'text/plain;charset=utf-8' }), name);
            this._ctCloseModal('exportChatModal');
            return { name, text };
        },

        async _ctCachedBytes(url) {
            if (url.startsWith('nymlocal:')) {
                const local = this._meshLocalMedia && this._meshLocalMedia.get(url.slice('nymlocal:'.length));
                return local && local.blob ? new Uint8Array(await local.blob.arrayBuffer()) : null;
            }
            if (typeof caches === 'undefined') return null;
            const candidates = [url];
            if (typeof this.getProxiedMediaUrl === 'function') {
                try { candidates.unshift(new URL(this.getProxiedMediaUrl(url), location.href).href); } catch (_) { }
            }
            for (const c of candidates) {
                try {
                    const hit = await caches.match(c);
                    if (hit && hit.ok) return new Uint8Array(await hit.arrayBuffer());
                } catch (_) { }
            }
            return null;
        },

        async exportChatZip(key) {
            const info = this._ctChatInfo(key);
            const norm = this._ctChatMessages(key).map((m) => this._ctNorm(m));
            const plan = C().exportMediaPlan(norm);
            const entries = [];
            const names = {};
            for (const p of plan) {
                const bytes = await this._ctCachedBytes(p.url);
                if (!bytes) continue;
                names[p.url] = p.name;
                entries.push({ name: 'media/' + p.name, bytes });
            }
            const text = this.buildChatTranscript(key, names);
            entries.unshift({ name: 'transcript.txt', bytes: new TextEncoder().encode(text) });
            const zip = C().zipStore(entries, Date.now(), this._ctOffsetMin());
            const name = C().exportFileName(info.n, Date.now(), this._ctOffsetMin(), 'zip');
            this._ctDownload(new Blob([zip], { type: 'application/zip' }), name);
            this._ctCloseModal('exportChatModal');
            this._ctNotice(this._ct('Exported {count} messages and {media} media files.', { count: norm.filter((m) => !m.system).length, media: entries.length - 1 }));
            return { name, entries: entries.map((e) => e.name), text };
        },

        openChatMedia(key) {
            this._ctGallery = { key, tab: (this._ctGallery && this._ctGallery.key === key) ? this._ctGallery.tab : 'media', revealed: new Set() };
            this._ctModal('chatMediaModal', this._ct('Media, files & links'));
            this._renderGallery();
        },

        _galleryData() {
            const g = this._ctGallery;
            if (!g) return { media: [], files: [], links: [] };
            return C().galleryItems(this._ctChatMessages(g.key).map((m) => this._ctNorm(m)));
        },

        _ctGalleryCanLoadOlder() {
            const g = this._ctGallery;
            if (!g || this._ctSurfaceForKey(g.key) === 'channel') return false;
            return typeof this.pmLoadOlderFromD1 === 'function' && !this._pmD1NoMore
                && typeof this._pmArchiveAllowed === 'function' && this._pmArchiveAllowed();
        },

        _renderGallery() {
            const modal = typeof document !== 'undefined' ? document.getElementById('chatMediaModal') : null;
            if (!modal || !modal.classList.contains('active') || !this._ctGallery) return;
            const body = modal.querySelector('.ct-modal-body');
            const g = this._ctGallery;
            const data = this._galleryData();
            this._ctGalleryItems = data[g.tab] || [];
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            const tabs = [['media', this._ct('Media')], ['files', this._ct('Files')], ['links', this._ct('Links')]]
                .map(([id, label]) => `<button type="button" class="ct-tab${g.tab === id ? ' active' : ''}" role="tab" aria-selected="${g.tab === id}" data-action="ctGalleryTab" data-tab="${id}">${esc(label)} <span class="ct-tab-count">${data[id].length}</span></button>`).join('');
            const items = this._ctGalleryItems.map((it, i) => {
                const hidden = it.spoiler && !g.revealed.has(i);
                const when = this._formatFullTimestamp(it.at * 1000);
                const label = it.name === 'voice' && it.kind === 'audio' ? this._ct(C().STRINGS.voice) : it.name === 'round' ? this._ct(C().STRINGS.round) : it.name;
                if (g.tab === 'media') {
                    let thumb = '';
                    if (it.kind === 'image') {
                        const src = this._ctMediaSrc(it);
                        thumb = src ? `<img src="${esc(src)}" alt="" loading="lazy" decoding="async">` : '';
                    } else {
                        thumb = `<span class="ct-media-video">${esc(this._ct(it.name === 'round' ? C().STRINGS.round : 'Video'))}</span>`;
                    }
                    return `<button type="button" class="ct-media-tile${hidden ? ' ct-spoiler' : ''}" data-action="ctGalleryOpen" data-idx="${i}" title="${esc(it.author + ' · ' + when)}" aria-label="${esc(hidden ? this._ct('Spoiler, tap to reveal') : label)}">${thumb}${hidden ? `<span class="ct-spoiler-label">${esc(this._ct('Spoiler'))}</span>` : ''}</button>`;
                }
                const main = hidden ? this._ct('Spoiler, tap to reveal') : (g.tab === 'links' ? it.url : label);
                return `<button type="button" class="ct-row${hidden ? ' ct-spoiler' : ''}" data-action="ctGalleryOpen" data-idx="${i}">
                    <span class="ct-row-main">${esc(main)}</span>
                    <span class="ct-row-meta">${esc(it.author)} · ${esc(when)}</span>
                </button>`;
            }).join('');
            const empty = g.tab === 'media' ? this._ct('No media in this chat yet.') : g.tab === 'files' ? this._ct('No files in this chat yet.') : this._ct('No links in this chat yet.');
            const older = this._ctGalleryCanLoadOlder()
                ? `<button type="button" class="ct-btn ct-load-older" data-action="ctGalleryOlder">${esc(this._ct('Load older from archive'))}</button>` : '';
            body.innerHTML = `<div class="ct-tabs" role="tablist">${tabs}</div>
                <div class="ct-gallery ct-gallery-${g.tab}">${items || `<div class="ct-empty">${esc(empty)}</div>`}</div>${older}`;
        },

        _ctMediaSrc(it) {
            if (it.local) return ((this._meshLocalMedia && this._meshLocalMedia.get(it.url.slice(9))) || {}).url || '';
            return this.getProxiedMediaUrl(it.url);
        },

        galleryTab(tab) {
            if (!this._ctGallery || ['media', 'files', 'links'].indexOf(tab) < 0) return;
            this._ctGallery.tab = tab;
            this._ctGallery.revealed = new Set();
            this._renderGallery();
        },

        galleryOpen(idx) {
            const g = this._ctGallery;
            const it = this._ctGalleryItems && this._ctGalleryItems[idx];
            if (!g || !it) return;
            if (it.spoiler && !g.revealed.has(idx)) {
                g.revealed.add(idx);
                this._renderGallery();
                return;
            }
            if (g.tab === 'media' && typeof this.openMediaViewer === 'function') {
                const items = this._ctGalleryItems.map((x, i) => ({
                    src: this._ctMediaSrc(x),
                    kind: x.kind === 'video' ? 'video' : 'image',
                    spoiler: !!x.spoiler,
                    revealed: g.revealed.has(i),
                    idx: i,
                })).filter((x) => x.src);
                const at = items.findIndex((x) => x.idx === idx);
                if (at >= 0) {
                    this.openMediaViewer(items, at, {
                        returnFocus: () => document.querySelector('#chatMediaModal .ct-media-tile[data-idx="' + idx + '"]'),
                        onReveal: (x) => {
                            if (this._ctGallery !== g) return;
                            g.revealed.add(x.idx);
                            this._renderGallery();
                        },
                    });
                    return;
                }
            }
            this._ctCloseModal('chatMediaModal');
            const found = this._ctFindMessage(it.nid) || this._ctFindMessage(it.mid);
            if (typeof this.jumpToNostrRef === 'function') this.jumpToNostrRef(found ? this._ctDomId(found.msg) : (it.nid || it.mid));
        },

        async galleryLoadOlder() {
            if (!this._ctGalleryCanLoadOlder()) return;
            try { await this.pmLoadOlderFromD1(); } catch (_) { }
            this._renderGallery();
        },

        _ctModal(id, title) {
            let modal = document.getElementById(id);
            if (!modal) {
                modal = document.createElement('div');
                modal.className = 'modal ct-modal';
                modal.id = id;
                modal.setAttribute('role', 'dialog');
                modal.setAttribute('aria-modal', 'true');
                modal.innerHTML = `<div class="modal-content ct-modal-content">
                    <button class="modal-close" type="button" data-action="ctCloseModal" data-modal-id="${id}" aria-label="${this.escapeHtml(this._ct('Close'))}">&#x2715;</button>
                    <div class="modal-header ct-modal-header"></div>
                    <div class="ct-modal-body"></div>
                </div>`;
                modal.addEventListener('click', (e) => { if (e.target === modal) this._ctCloseModal(id); });
                document.body.appendChild(modal);
            }
            modal.querySelector('.ct-modal-header').textContent = title;
            modal.classList.add('active');
            this._ctModalStack = (this._ctModalStack || []).filter((x) => x !== id).concat(id);
            if (!this._ctEscBound) {
                this._ctEscBound = true;
                document.addEventListener('keydown', (e) => {
                    if (e.key !== 'Escape' || e.defaultPrevented) return;
                    const stack = (this._ctModalStack || []).filter((x) => { const m = document.getElementById(x); return m && m.classList.contains('active'); });
                    if (!stack.length) return;
                    e.preventDefault();
                    this._ctCloseModal(stack[stack.length - 1]);
                });
            }
            return { modal, body: modal.querySelector('.ct-modal-body') };
        },

        _ctCloseModal(id) {
            const modal = document.getElementById(id);
            if (modal) modal.classList.remove('active');
        },

        _ctMenuItem(id, action, svg, label, cls) {
            const el = document.createElement('div');
            el.className = 'context-menu-item' + (cls ? ' ' + cls : '');
            el.id = id;
            el.dataset.action = action;
            el.innerHTML = svg;
            el.appendChild(document.createTextNode(label));
            return el;
        },

        _ctDecorateContextMenu() {
            ['ctxSaveMessage', 'ctxReplyPrivately', 'ctxKeepMessage', 'ctxChatMedia', 'ctxExportChat']
                .forEach((id) => { const el = document.getElementById(id); if (el) el.remove(); });
            const data = this.contextMenuData;
            const anchor = document.getElementById('ctxCopyMessage') || document.getElementById('ctxQuote');
            if (!data || !anchor) return;
            const items = [];
            const found = (data.messageId && this._ctFindMessage(data.messageId)) || (data.reactionId && this._ctFindMessage(data.reactionId));
            if (found && data.content) {
                const m = found.msg;
                const saved = this.isMessageSaved(m);
                items.push(this._ctMenuItem('ctxSaveMessage', 'ctxSaveMessage', saved ? ICONS.unsave : ICONS.save,
                    saved ? this._ct('Remove from Saved') : this._ct('Save message')));
                if (C().replyPrivatelyAllowed({ surface: this._ctSurfaceForKey(found.key), pubkey: m.pubkey, self: this.pubkey, system: !m.pubkey })) {
                    items.push(this._ctMenuItem('ctxReplyPrivately', 'ctxReplyPrivately', ICONS.replyPrivately, this._ct('Reply privately')));
                }
                if (this.keepAvailableFor(m, found.key)) {
                    const kept = this.isMessageKept(m);
                    items.push(this._ctMenuItem('ctxKeepMessage', 'ctxKeepMessage', kept ? ICONS.unkeep : ICONS.keep,
                        kept ? this._ct('Unkeep') : this._ct('Keep in chat')));
                }
                this._ctCtxMessage = { id: m.nymMessageId || m.id, key: found.key };
            } else {
                this._ctCtxMessage = null;
            }
            if (!data.messageId && this.inPMMode && !this.currentGroup && this.currentPM && data.pubkey === this.currentPM) {
                this._ctCtxChatKey = this.getPMConversationKey(this.currentPM);
                items.push(this._ctMenuItem('ctxChatMedia', 'ctxChatMedia', ICONS.media, this._ct('Media, files & links')));
                items.push(this._ctMenuItem('ctxExportChat', 'ctxExportChat', ICONS.exportChat, this._ct('Export chat')));
            }
            let after = anchor;
            for (const el of items) {
                after.parentNode.insertBefore(el, after.nextSibling);
                after = el;
            }
        },

        _ctChatMenuItems(key) {
            return [
                { label: this._ct('Media, files & links'), svg: ICONS.media.replace('class="nm-ico8"', ''), action: () => this.openChatMedia(key) },
                { label: this._ct('Export chat'), svg: ICONS.exportChat.replace('class="nm-ico8"', ''), action: () => this.openExportChat(key) },
            ];
        },

        _ctGroupMenuHtml(groupId) {
            const key = this.getGroupConversationKey(groupId);
            const esc = (s) => this.escapeHtml(String(s));
            return `<div class="context-menu-item" data-action="groupCtxMedia" data-chat-key="${esc(key)}">${ICONS.media}${esc(this._ct('Media, files & links'))}</div>`
                + `<div class="context-menu-item" data-action="groupCtxExport" data-chat-key="${esc(key)}">${ICONS.exportChat}${esc(this._ct('Export chat'))}</div>`;
        },

        _ctStartTimers() {
            if (this._ctTimers) return;
            this._ctTimers = true;
            setInterval(() => { try { this._expirySweep(); } catch (_) { } }, SWEEP_MS);
            setInterval(() => {
                try {
                    if (this._savedPending()) this._savedSync();
                    this.flushKeepOutbox();
                } catch (_) { }
            }, SAVED_FLUSH_MS);
            if (typeof window !== 'undefined' && window.addEventListener) {
                window.addEventListener('online', () => {
                    setTimeout(() => { this._savedSync(); this.flushKeepOutbox(); }, 1500);
                });
            }
        },
    });

    const origShowContextMenu = NYM.prototype.showContextMenu;
    if (typeof origShowContextMenu === 'function') {
        NYM.prototype.showContextMenu = function () {
            const r = origShowContextMenu.apply(this, arguments);
            try { this._ctDecorateContextMenu(); } catch (_) { }
            return r;
        };
    }

    const origMeshReceipt = NYM.prototype.onMeshReceipt;
    NYM.prototype.onMeshReceipt = function (r) {
        if (this.handleMeshKeep(r)) return;
        if (typeof origMeshReceipt === 'function') origMeshReceipt.call(this, r);
    };

    if (typeof window !== 'undefined' && window.NYM_ACTIONS) {
        const nym = () => window.nym;
        Object.assign(window.NYM_ACTIONS, {
            openSavedMessages: function () { nym().openSavedPanel(); },
            openSavedAndCloseSidebar: function () { nym().openSavedPanel(); nym().closeSidebar(); },
            ctCloseModal: function (_e, t) { nym()._ctCloseModal(t.dataset.modalId); },
            ctSavedJump: function (_e, t) { nym().savedJump(t.dataset.savedId); },
            ctSavedRemove: function (_e, t) { nym().removeSavedMessage(t.dataset.savedId); },
            showEditHistory: function (e, t) {
                if (e && e.stopPropagation) e.stopPropagation();
                const msg = t.closest('.message');
                if (msg && msg.dataset.messageId) nym().openEditHistory(msg.dataset.messageId);
            },
            ctxSaveMessage: function () {
                const n = nym();
                const c = n._ctCtxMessage;
                n.closeContextMenu();
                if (!c) return;
                const found = n._ctFindMessage(c.id);
                if (found && n.isMessageSaved(found.msg)) n.removeSavedMessage(found.msg.nymMessageId || found.msg.id);
                else n.saveMessage(c.id);
            },
            ctxReplyPrivately: function () {
                const n = nym();
                const c = n._ctCtxMessage;
                n.closeContextMenu();
                if (c) n.replyPrivately(c.id);
            },
            ctxKeepMessage: function () {
                const n = nym();
                const c = n._ctCtxMessage;
                n.closeContextMenu();
                if (c) n.toggleKeepMessage(c.id);
            },
            ctxChatMedia: function () {
                const n = nym();
                const key = n._ctCtxChatKey;
                n.closeContextMenu();
                if (key) n.openChatMedia(key);
            },
            ctxExportChat: function () {
                const n = nym();
                const key = n._ctCtxChatKey;
                n.closeContextMenu();
                if (key) n.openExportChat(key);
            },
            groupCtxMedia: function (_e, t) { const n = nym(); n.closeGroupContextMenu(); n.openChatMedia(t.dataset.chatKey); },
            groupCtxExport: function (_e, t) { const n = nym(); n.closeGroupContextMenu(); n.openExportChat(t.dataset.chatKey); },
            ctExportTxt: function () { const n = nym(); if (n._ctExportKey) n.exportChatText(n._ctExportKey); },
            ctExportZip: function () { const n = nym(); if (n._ctExportKey) n.exportChatZip(n._ctExportKey); },
            ctGalleryTab: function (_e, t) { nym().galleryTab(t.dataset.tab); },
            ctGalleryOpen: function (_e, t) { nym().galleryOpen(parseInt(t.dataset.idx, 10)); },
            ctGalleryOlder: function () { nym().galleryLoadOlder(); },
        });
        let tries = 0;
        const boot = () => {
            const n = window.nym;
            if (n && typeof n._ctStartTimers === 'function') n._ctStartTimers();
            else if (++tries < 120) setTimeout(boot, 1000);
        };
        setTimeout(boot, 1000);
    }
})();
