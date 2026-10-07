(function () {
    const S = () => window.NymUnifiedSearch;
    const MODAL_ID = 'unifiedSearchModal';
    const SEARCH_SVG = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="8"></circle><path d="m21 21-4.35-4.35"></path></svg>';

    Object.assign(NYM.prototype, {
        _us(key, vars) {
            let s = S().STRINGS[key] || key;
            s = typeof this.uiText === 'function' ? this.uiText(s) : s;
            if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
            return s;
        },

        _usLocked(key) {
            try { return typeof this.isConversationLocked === 'function' && !!this.isConversationLocked(key); } catch (_) { return false; }
        },

        _usCurrentKey() {
            if (this.inPMMode && this.currentGroup) return this.getGroupConversationKey(this.currentGroup);
            if (this.inPMMode && this.currentPM) return this.getPMConversationKey(this.currentPM);
            return this.currentGeohash ? '#' + this.currentGeohash : (this.currentChannel || '');
        },

        _usItem(key, m) {
            if (!this._usItems) this._usItems = new WeakMap();
            let it = this._usItems.get(m);
            const at = (m.created_at || 0) * 1000;
            if (it && it.text === m.content && it.key === key && it.at === at) return it;
            it = { id: m.id, key, at, text: m.content || '', msg: m, folded: null };
            this._usItems.set(m, it);
            return it;
        },

        _usVisibilitySig() {
            const size = (x) => (x && typeof x.size === 'number' ? x.size : 0);
            const packs = typeof this.activeFilterPacks === 'function' ? this.activeFilterPacks().join(',') : '';
            const gates = typeof this._clientGatesActive === 'function' && this._clientGatesActive() ? 1 : 0;
            const minute = Math.floor(Date.now() / 60000);
            return [size(this.deletedEventIds), size(this.blockedUsers), size(this.blockedKeywords), [...(this.blockedKeywords || [])].join('\u0001'), size(this._quiet), packs, gates, minute].join('|');
        },

        _usVisible(it) {
            const m = it.msg;
            if (!m) return true;
            if (this.deletedEventIds && (this.deletedEventIds.has(m.id) || (m.nymMessageId && this.deletedEventIds.has(m.nymMessageId)))) return false;
            if (typeof this._isMessageDeleted === 'function' && this._isMessageDeleted(m)) return false;
            if (!m.isOwn && ((this.blockedUsers && this.blockedUsers.has(m.pubkey)) || m.blocked)) return false;
            if (typeof this._quietMessage === 'function' && this._quietMessage(m)) return false;
            if (!m.isOwn && typeof this.hasBlockedKeyword === 'function' && this.hasBlockedKeyword(m.content, m.author, m.pubkey)) return false;
            const gates = typeof this._clientGatesActive === 'function' && this._clientGatesActive();
            if (gates && !m.isOwn && typeof this.isSpamMessage === 'function' && this.isSpamMessage(m.content)) return false;
            if (typeof this._ctHidden === 'function' && this._ctHidden(m)) return false;
            return true;
        },

        _usCorpus() {
            const channels = [];
            const seen = new Set();
            const blocked = this.blockedChannels || new Set();
            const activity = this.channelLastActivity || new Map();
            for (const [key, ch] of (this.channels || new Map())) {
                const k = String(key || '').toLowerCase();
                if (!k || blocked.has(k) || seen.has(k)) continue;
                const storage = ch && ch.geohash ? '#' + ch.geohash : k;
                if (this._usLocked(storage)) continue;
                seen.add(k);
                const geo = typeof this.isValidGeohash === 'function' && this.isValidGeohash(k) && !!(ch && ch.geohash);
                channels.push({ key: k, name: k, kind: geo ? 'geohash' : 'channel', joined: true, at: activity.get(geo ? '#' + k : k) || activity.get('#' + k) || 0 });
            }
            for (const [gh, buckets] of (this._geohashD1Activity || new Map())) {
                const k = String(gh || '').toLowerCase();
                if (!k || seen.has(k) || blocked.has(k) || !S().isGeohash(k)) continue;
                seen.add(k);
                let sum = 0;
                for (const n of (Array.isArray(buckets) ? buckets : [])) sum += Number(n) || 0;
                channels.push({ key: k, name: k, kind: 'geohash', joined: false, at: sum });
            }
            for (const [gid, g] of (this.groupConversations || new Map())) {
                if (!gid || this._usLocked(this.getGroupConversationKey(gid))) continue;
                channels.push({ key: gid, name: (g && g.name) || this._ct('Group'), kind: 'group', joined: true, at: (g && g.lastMessageTime) || 0 });
            }
            const nyms = [];
            const people = new Set();
            if (!this._usNpubs) this._usNpubs = new Map();
            const npub = (pk) => {
                let v = this._usNpubs.get(pk);
                if (v === undefined) { v = typeof this.npubFromPubkey === 'function' ? this.npubFromPubkey(pk) : ''; this._usNpubs.set(pk, v); }
                return v;
            };
            const blockedUsers = this.blockedUsers || new Set();
            const friends = this.friends || new Set();
            for (const [pk, u] of (this.users || new Map())) {
                if (!pk || blockedUsers.has(pk) || people.has(pk)) continue;
                people.add(pk);
                nyms.push({ pubkey: pk, nym: this.stripPubkeySuffix((u && u.nym) || ''), npub: npub(pk), friend: friends.has(pk), at: (u && u.lastSeen) || 0 });
            }
            for (const [pk, p] of (this.pmConversations || new Map())) {
                if (!pk || blockedUsers.has(pk) || people.has(pk)) continue;
                if (this._usLocked(this.getPMConversationKey(pk))) continue;
                people.add(pk);
                nyms.push({ pubkey: pk, nym: this.stripPubkeySuffix((p && p.nym) || ''), npub: npub(pk), friend: friends.has(pk), at: 0 });
            }
            const blockedRooms = new Set([...blocked].map((k) => '#' + k).concat([...blocked]));
            const messages = (each) => {
                for (const store of [this.messages, this.pmMessages]) {
                    if (!store || typeof store.forEach !== 'function') continue;
                    for (const [key, list] of store) {
                        if (!Array.isArray(list) || !list.length) continue;
                        if (blockedRooms.has(key) || this._usLocked(key)) continue;
                        for (const m of list) {
                            if (!m || !m.content) continue;
                            each(this._usItem(key, m));
                        }
                    }
                }
            };
            return { channels, nyms, messages };
        },

        _usRun() {
            const st = this._usState;
            if (!st) return null;
            const scope = st.scoped ? st.scope : '';
            const lower = (it) => {
                if (it.folded === null) it.folded = S().fold(it.text);
                return it.folded;
            };
            const sig = this._usVisibilitySig();
            const visible = (it) => {
                if (it.visSig !== sig || it.visText !== it.text) {
                    it.vis = this._usVisible(it);
                    it.visSig = sig;
                    it.visText = it.text;
                }
                return it.vis;
            };
            return S().search(st.query, this._usCorpus(), { limits: st.limits, scope, lower, visible });
        },

        _usHighlight(text, ranges) {
            const esc = (s) => this.escapeHtml(s);
            let out = '';
            let at = 0;
            for (const r of ranges || []) {
                if (r[0] > at) out += esc(text.slice(at, r[0]));
                out += '<mark class="us-hit">' + esc(text.slice(r[0], r[1])) + '</mark>';
                at = r[1];
            }
            return out + esc(text.slice(at));
        },

        _usAvatarImg(pubkey, cls) {
            const safe = this._safePubkey(pubkey);
            return `<img src="${this.escapeHtml(this.getAvatarUrl(pubkey))}" class="${cls}" data-avatar-pubkey="${safe}" alt="" decoding="async" loading="lazy">`;
        },

        _usConvHtml(key) {
            const k = String(key || '');
            let inner = '';
            if (k.startsWith('pm-')) {
                const peer = this._ctPeerFromKey(k);
                if (peer) inner = this._usAvatarImg(peer, 'avatar-pm');
            } else if (k.startsWith('group-')) {
                const gid = k.slice(6);
                const g = this.groupConversations && this.groupConversations.get(gid);
                if (g && typeof this._groupAvatarHtml === 'function') inner = this._groupAvatarHtml(gid, Array.isArray(g.members) ? g.members : []);
            }
            if (!inner && !k.startsWith('pm-')) inner = k.startsWith('group-') && typeof this._groupGlyphSvg === 'function' ? this._groupGlyphSvg() : this._channelGlyphSvg(this._channelKeyIsGeohash(k), 18);
            return `<span class="us-conv" aria-hidden="true">${inner}</span>`;
        },

        _usGlyphHtml(key) {
            const k = String(key || '');
            let inner = this._channelGlyphSvg(this._channelKeyIsGeohash(k), 18);
            if (k.startsWith('pm-')) inner = '<svg class="us-glyph-pm" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2" y="4" width="12" height="9" rx="1"/><path d="M 2 5 L 8 9 L 14 5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
            else if (k.startsWith('group-') && typeof this._groupGlyphSvg === 'function') inner = this._groupGlyphSvg('us-glyph-group');
            return `<span class="us-conv us-glyph" aria-hidden="true">${inner}</span>`;
        },

        _usNymHtml(base, pubkey, tokens) {
            const suffix = '#' + this.getPubkeySuffix(pubkey);
            const label = base + suffix;
            const ranges = S().highlight(label, tokens || []);
            const slice = (from, to) => {
                const rs = [];
                for (const r of ranges) {
                    const a = Math.max(r[0], from);
                    const b = Math.min(r[1], to);
                    if (b > a) rs.push([a - from, b - from]);
                }
                return this._usHighlight(label.slice(from, to), rs);
            };
            return `${slice(0, base.length)}<span class="nym-suffix">${slice(base.length, label.length)}</span>`;
        },

        _usEnsureModal() {
            let modal = document.getElementById(MODAL_ID);
            if (modal) return modal;
            modal = document.createElement('div');
            modal.className = 'modal us-modal';
            modal.id = MODAL_ID;
            modal.setAttribute('data-sheet', '');
            modal.setAttribute('role', 'dialog');
            modal.setAttribute('aria-modal', 'true');
            modal.setAttribute('aria-labelledby', 'usTitle');
            modal.innerHTML = `<div class="modal-content us-content">
                <button class="modal-close" type="button" data-action="closeUnifiedSearch" aria-label=""></button>
                <div class="modal-header us-header" id="usTitle"></div>
                <div class="us-field">
                    <span class="us-field-icon">${SEARCH_SVG}</span>
                    <input type="search" id="usInput" class="us-input" autocomplete="off" spellcheck="false" role="combobox" aria-expanded="true" aria-controls="usResults" aria-autocomplete="list">
                </div>
                <div class="us-scope nm-hidden" id="usScope" role="radiogroup"></div>
                <div class="us-count" id="usCount" aria-live="polite"></div>
                <div class="us-results" id="usResults" role="listbox"></div>
            </div>`;
            modal.addEventListener('click', (e) => { if (e.target === modal) this.closeUnifiedSearch(); });
            document.body.appendChild(modal);
            const input = modal.querySelector('#usInput');
            input.addEventListener('input', () => this._usOnInput(input.value));
            input.addEventListener('keydown', (e) => this._usKey(e));
            modal.querySelector('#usResults').addEventListener('click', (e) => {
                const row = e.target.closest && e.target.closest('[data-us-idx]');
                if (row) this._usActivate(parseInt(row.dataset.usIdx, 10));
            });
            modal.querySelector('#usScope').addEventListener('click', (e) => {
                const b = e.target.closest && e.target.closest('[data-us-scope]');
                if (!b || !this._usState) return;
                this._usState.scoped = b.dataset.usScope === 'chat';
                this._usState.limits = Object.assign({}, S().CONFIG.pages);
                this._usState.active = -1;
                this._usRender();
            });
            return modal;
        },

        openUnifiedSearch(opts) {
            const o = opts || {};
            const modal = this._usEnsureModal();
            const scope = o.scope || '';
            this._usReturnFocus = document.activeElement;
            this._usState = { query: o.query || '', scope, scoped: !!scope, limits: Object.assign({}, S().CONFIG.pages), active: -1, rows: [] };
            modal.querySelector('.modal-close').setAttribute('aria-label', this._us('close'));
            modal.querySelector('.modal-close').innerHTML = '&#x2715;';
            modal.querySelector('#usTitle').textContent = this._us('title');
            const input = modal.querySelector('#usInput');
            input.placeholder = this._us('placeholder');
            input.setAttribute('aria-label', this._us('placeholder'));
            input.value = o.query || '';
            modal.classList.add('active');
            if (!this._usEscBound) {
                this._usEscBound = true;
                document.addEventListener('keydown', (e) => {
                    if (e.key !== 'Escape') return;
                    const m = document.getElementById(MODAL_ID);
                    if (!m || !m.classList.contains('active')) return;
                    const dlg = document.getElementById('appDialogModal');
                    if (dlg && dlg.classList.contains('active')) return;
                    if (m.classList.contains('is-sheet') && window.nymSheets) return;
                    e.preventDefault();
                    this.closeUnifiedSearch();
                }, true);
            }
            this._usRender();
            setTimeout(() => { try { input.focus(); } catch (_) { } }, 30);
        },

        closeUnifiedSearch() {
            clearTimeout(this._usTimer);
            const modal = document.getElementById(MODAL_ID);
            if (modal) modal.classList.remove('active');
            const back = this._usReturnFocus;
            this._usReturnFocus = null;
            if (back && back.isConnected && typeof back.focus === 'function') { try { back.focus(); } catch (_) { } }
        },

        _usOnInput(value) {
            clearTimeout(this._usTimer);
            this._usTimer = setTimeout(() => {
                if (!this._usState) return;
                this._usState.query = value;
                this._usState.limits = Object.assign({}, S().CONFIG.pages);
                this._usState.active = -1;
                this._usRender();
            }, S().CONFIG.debounceMs);
        },

        _usKey(e) {
            const st = this._usState;
            if (!st) return;
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                e.preventDefault();
                if (!st.rows.length) return;
                const d = e.key === 'ArrowDown' ? 1 : -1;
                st.active = st.active < 0 ? (d > 0 ? 0 : st.rows.length - 1) : Math.max(0, Math.min(st.rows.length - 1, st.active + d));
                this._usPaintActive();
                return;
            }
            if (e.key === 'Enter') {
                e.preventDefault();
                const input = document.getElementById('usInput');
                if (input && input.value !== st.query) {
                    clearTimeout(this._usTimer);
                    st.query = input.value;
                    st.limits = Object.assign({}, S().CONFIG.pages);
                    st.active = -1;
                    this._usRender();
                }
                if (st.rows.length) this._usActivate(st.active < 0 ? 0 : st.active);
            }
        },

        _usPaintActive() {
            const st = this._usState;
            const input = document.getElementById('usInput');
            document.querySelectorAll('#usResults [data-us-idx]').forEach((el) => {
                const on = parseInt(el.dataset.usIdx, 10) === st.active;
                el.classList.toggle('active', on);
                el.setAttribute('aria-selected', on ? 'true' : 'false');
                if (on && typeof el.scrollIntoView === 'function') el.scrollIntoView({ block: 'nearest' });
            });
            if (input) {
                if (st.active >= 0) input.setAttribute('aria-activedescendant', 'usOpt' + st.active);
                else input.removeAttribute('aria-activedescendant');
            }
        },

        _usRender() {
            const st = this._usState;
            const box = document.getElementById('usResults');
            const countEl = document.getElementById('usCount');
            const scopeEl = document.getElementById('usScope');
            if (!st || !box) return;
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            if (st.scope) {
                const info = this._ctChatInfo(st.scope);
                scopeEl.classList.remove('nm-hidden');
                scopeEl.innerHTML = `<button type="button" role="radio" class="us-chip${st.scoped ? '' : ' on'}" data-us-scope="all" aria-checked="${st.scoped ? 'false' : 'true'}">${esc(this._us('scopeAll'))}</button>`
                    + `<button type="button" role="radio" class="us-chip${st.scoped ? ' on' : ''}" data-us-scope="chat" aria-checked="${st.scoped ? 'true' : 'false'}">${esc(this._us('scopeChat', { chat: info.n }))}</button>`;
            } else {
                scopeEl.classList.add('nm-hidden');
                scopeEl.innerHTML = '';
            }
            const r = this._usRun();
            this._usLast = r;
            const q = r.query;
            st.rows = [];
            if (!q.text) {
                countEl.textContent = '';
                box.innerHTML = `<div class="us-state" id="usEmpty">${SEARCH_SVG}<div class="us-state-title">${esc(this._us('empty'))}</div><div class="us-state-hint">${esc(this._us('emptyHint'))}</div></div>`;
                this._usPaintActive();
                return;
            }
            const empty = !r.channels.total && !r.join && !r.nyms.total && !r.messages.total;
            if (empty) {
                countEl.textContent = '';
                const hint = q.text.length < S().CONFIG.minMessageChars ? `<div class="us-state-hint">${esc(this._us('shortMessages'))}</div>` : '';
                box.innerHTML = `<div class="us-state" id="usNoResults">${SEARCH_SVG}<div class="us-state-title">${esc(this._us('noResults', { q: st.query.trim() }))}</div>${hint}</div>`;
                this._usPaintActive();
                return;
            }
            countEl.textContent = this._us('resultCount', { n: r.channels.total + r.nyms.total + r.messages.total });
            const row = (kind, data, label, inner) => {
                const i = st.rows.length;
                st.rows.push(Object.assign({ kind }, data));
                return `<div class="us-row us-${kind}" role="option" id="usOpt${i}" data-us-idx="${i}" data-us-id="${esc(data.rid || '')}" aria-selected="false" aria-label="${esc(label)}">${inner}</div>`;
            };
            const more = (group, shown, total) => row('more', { group, rid: 'more-' + group }, this._us('showMore'), `<span class="us-more">${esc(this._us('showMore'))} (${total - shown})</span>`);
            const groupHtml = (id, title, total, body) => `<div class="us-group" role="group" aria-labelledby="usG${id}"><div class="us-group-title" id="usG${id}" role="presentation">${esc(title)} · ${total}</div>${body}</div>`;
            let html = '';
            if (r.channels.total || r.join) {
                let body = '';
                for (const it of r.channels.items) {
                    const label = it.kind === 'group' ? it.name : '#' + it.name;
                    const sub = it.kind === 'group' ? this._us('group') : (it.joined ? this._us('joined') : this._us('notJoined'));
                    body += row('channel', { item: it, rid: 'channel-' + it.kind + '-' + it.key }, label + ', ' + sub,
                        `${this._usConvHtml(it.kind === 'group' ? 'group-' + it.key : (it.kind === 'geohash' ? '#' + it.key : it.key))}<span class="us-name">${this._usHighlight(label, S().highlight(label, q.nameTokens))}</span><span class="us-sub">${esc(sub)}</span>`);
                }
                if (r.channels.total > r.channels.items.length) body += more('channels', r.channels.items.length, r.channels.total);
                if (r.join) {
                    const label = r.join.geohash ? this._us('joinGeohash', { name: r.join.key }) : this._us('joinChannel', { name: r.join.key });
                    body += row('join', { join: r.join, rid: 'join-' + r.join.key }, label, `<span class="us-icon">+</span><span class="us-name us-join">${esc(label)}</span>`);
                }
                html += groupHtml('c', this._us('channels'), r.channels.total, body);
            }
            if (r.nyms.total) {
                let body = '';
                for (const it of r.nyms.items) {
                    const label = it.nym + '#' + this.getPubkeySuffix(it.pubkey);
                    body += row('nym', { item: it, rid: 'nym-' + it.pubkey }, it.friend ? label + ', ' + this._us('friend') : label,
                        `<span class="us-conv">${this._usAvatarImg(it.pubkey, 'avatar-user-list')}</span><span class="us-name">${this._usNymHtml(it.nym, it.pubkey, q.nameTokens)}</span>${it.friend ? `<span class="us-sub">${esc(this._us('friend'))}</span>` : ''}`);
                }
                if (r.nyms.total > r.nyms.items.length) body += more('nyms', r.nyms.items.length, r.nyms.total);
                html += groupHtml('n', this._us('nyms'), r.nyms.total, body);
            }
            if (r.messages.total) {
                let body = '';
                for (const it of r.messages.items) {
                    const m = it.msg;
                    const sender = this._ctDisplayNym(m.pubkey, m.author);
                    const senderBase = this.stripPubkeySuffix(sender);
                    const info = this._ctChatInfo(it.key, m);
                    const chat = info.t === 'dm' ? this._us('dm', { name: info.n }) : info.n;
                    const when = this._formatFullTimestamp(it.at);
                    const snip = S().snippet(it.text, q.tokens);
                    body += row('message', { item: it, rid: 'message-' + it.key + '-' + it.id }, `${sender}, ${chat}, ${when}: ${snip.text}`,
                        `${this._usGlyphHtml(it.key)}<div class="us-body"><div class="us-meta"><span class="us-sender">${m.pubkey ? this._usNymHtml(senderBase, m.pubkey, []) : esc(sender)}</span><span class="us-dot">·</span><span class="us-chat">${esc(chat)}</span><span class="us-when">${esc(when)}</span></div><div class="us-snippet">${this._usHighlight(snip.text, snip.ranges)}</div></div>`);
                }
                if (r.messages.total > r.messages.items.length) body += more('messages', r.messages.items.length, r.messages.total);
                html += groupHtml('m', this._us('messages'), r.messages.total, body);
            }
            box.innerHTML = html;
            if (st.active >= st.rows.length) st.active = st.rows.length - 1;
            this._usPaintActive();
        },

        _usActivate(i) {
            const st = this._usState;
            const row = st && st.rows[i];
            if (!row) return;
            if (row.kind === 'more') {
                const step = S().CONFIG.steps[row.group];
                st.limits = Object.assign({}, st.limits, { [row.group]: st.limits[row.group] + step });
                st.active = i;
                this._usRender();
                return;
            }
            this.closeUnifiedSearch();
            if (row.kind === 'channel') {
                const it = row.item;
                if (it.kind === 'group') { this.openGroup(it.key); return; }
                const geo = it.kind === 'geohash' ? it.key : '';
                if (!it.joined) {
                    this.addChannel(it.key, geo);
                    if (this.userJoinedChannels) this.userJoinedChannels.add(it.key);
                    if (typeof this.saveUserChannels === 'function') this.saveUserChannels();
                }
                this.switchChannel(it.key, geo);
                return;
            }
            if (row.kind === 'join') {
                const j = row.join;
                const geo = j.geohash ? j.key : '';
                this.addChannel(j.key, geo);
                this.switchChannel(j.key, geo);
                if (this.userJoinedChannels) this.userJoinedChannels.add(j.key);
                if (typeof this.saveUserChannels === 'function') this.saveUserChannels();
                return;
            }
            if (row.kind === 'nym') {
                const it = row.item;
                const fake = { preventDefault() { }, stopPropagation() { }, clientX: 0, clientY: 0, target: document.body };
                const suffix = this.getPubkeySuffix(it.pubkey);
                this.showContextMenu(fake, `${this.escapeHtml(it.nym)}<span class="nym-suffix">#${suffix}</span>`, it.pubkey, null, null, true);
                return;
            }
            if (row.kind === 'message') this.unifiedSearchJump(row.item.key, row.item.msg);
        },

        _usSwitchTo(key) {
            if (key.startsWith('pm-')) {
                const peer = this._ctPeerFromKey(key);
                if (!peer) return false;
                this.openPM(this.resolveDisplayNym(peer, ''), peer);
                return true;
            }
            if (key.startsWith('group-')) {
                this.openGroup(key.slice(6));
                return true;
            }
            const name = key.replace(/^#/, '');
            if (!name) return false;
            this.switchChannel(name, this.isValidGeohash(name) && key.startsWith('#') ? name : '');
            return true;
        },

        _usThreadCtx(key) {
            if (key.startsWith('group-')) return { type: 'group', groupId: key.slice(6), storageKey: key, isPM: true };
            if (key.startsWith('pm-')) {
                const peer = this._ctPeerFromKey(key);
                return { type: 'pm', pubkey: peer, nym: this.getNymFromPubkey(peer), storageKey: key, isPM: true };
            }
            const name = key.replace(/^#/, '');
            const geo = key.startsWith('#') ? name : '';
            return { type: 'channel', channel: name, geohash: geo, storageKey: key, isPM: false };
        },

        unifiedSearchJump(key, msg) {
            if (!key || !msg) return;
            const isPM = key.startsWith('pm-') || key.startsWith('group-');
            const domId = (msg.isPM && msg.nymMessageId) ? msg.nymMessageId : msg.id;
            if (this._usCurrentKey() !== key) this._usSwitchTo(key);
            const store = isPM ? this.pmMessages : this.messages;
            const list = (store && store.get(key)) || [];
            const rootKey = msg.threadRoot;
            const rootHere = !!rootKey && list.some((x) => x && !x.threadRoot && this.threadKeyForMessage(x) === rootKey);
            if (rootHere && typeof this.threadsEnabled === 'function' && this.threadsEnabled() && typeof this.openThreadView === 'function') {
                requestAnimationFrame(() => {
                    this.openThreadView(rootKey, this._usThreadCtx(key));
                    this._scrollWhenRendered(domId);
                });
                return;
            }
            if (this.activeThread && typeof this.closeThreadView === 'function') this.closeThreadView();
            requestAnimationFrame(() => {
                const shown = isPM ? this.getFilteredPMMessages(key) : this.getFilteredMessages(key);
                const idx = shown.findIndex((x) => x === msg || x.id === msg.id);
                const startMap = isPM ? this.pmRenderedStart : this.channelRenderedStart;
                if (idx >= 0 && startMap) {
                    let safety = 200;
                    while (safety-- > 0) {
                        const start = startMap.get(key) || 0;
                        if (start <= idx) break;
                        const advanced = isPM ? this.loadOlderPMMessages(key) : this.loadOlderChannelMessages(key);
                        if (!advanced) break;
                    }
                }
                this._scrollWhenRendered(domId);
            });
        },

        cmdSearch(args) {
            this.openUnifiedSearch({ scope: this._usCurrentKey(), query: String(args || '').trim() });
        },
    });

    if (typeof window !== 'undefined' && window.NYM_ACTIONS) {
        const nym = () => window.nym;
        Object.assign(window.NYM_ACTIONS, {
            openUnifiedSearch: function () { nym().openUnifiedSearch(); },
            openUnifiedSearchAndCloseSidebar: function () { const n = nym(); if (typeof n.closeSidebar === 'function') n.closeSidebar(); n.openUnifiedSearch(); },
            closeUnifiedSearch: function () { nym().closeUnifiedSearch(); },
        });
    }

    if (typeof document !== 'undefined') {
        document.addEventListener('keydown', (e) => {
            const K = window.NymShortcuts;
            if (K) {
                if (K.match({ key: e.key, ctrl: e.ctrlKey, meta: e.metaKey, alt: e.altKey, shift: e.shiftKey, mac: K.isMac() }) !== 'search') return;
            } else {
                if (!(e.ctrlKey || e.metaKey) || e.altKey || e.shiftKey) return;
                if (String(e.key || '').toLowerCase() !== 'k') return;
            }
            const n = window.nym;
            if (!n || typeof n.openUnifiedSearch !== 'function') return;
            e.preventDefault();
            const m = document.getElementById(MODAL_ID);
            if (m && m.classList.contains('active')) {
                const input = document.getElementById('usInput');
                if (input) { input.focus(); input.select(); }
                return;
            }
            n.openUnifiedSearch();
        }, true);
    }
})();
