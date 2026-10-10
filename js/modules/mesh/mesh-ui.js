// mesh-ui.js - wires the Bluetooth mesh into the app

// `NYM` is read as the lexical global from app.js (loaded first), never `window.NYM`, which is always undefined.
(function () {
    const MESH_CHANNEL = 'mesh';
    const MESH_GOSSIP_KEY = 'nym_mesh_gossip_archive';
    // A private half lost on reload is mail nobody can open, so it outlives the session.
    const MESH_PREKEYS_KEY = 'nym_mesh_prekeys_v1';
    // The peer's announce may be minutes old; silence is an answer, not a hang.
    const MESH_PING_TIMEOUT_MS = 10 * 1000;

    Object.assign(NYM.prototype, {

        meshSupported() {
            return !!(window.NymMeshTransport && window.NymMeshTransport.isSupported());
        },

        async meshUsable() {
            if (!this.meshSupported()) return false;
            try { return await window.NymMeshCrypto.cryptoSupported(); } catch (_) { return false; }
        },

        async initMeshUI() {
            const row = document.getElementById('meshStatusRow');
            if (!row) return;
            this._wrapMeshNav();
            this._meshAvailable = await this.meshUsable();
            if (!this._meshAvailable) { row.classList.add('nm-hidden'); return; }
            row.classList.remove('nm-hidden');
            this._meshLog = [];
            this._renderMeshStatusRow();
        },

        _wrapMeshNav() {
            const proto = Object.getPrototypeOf(this);
            if (proto._meshNavWrapped) return;
            proto._meshNavWrapped = true;
            ['switchChannel', 'openPM', 'openUserPM', 'openGroup', 'navigateToLatestPMOrGroup'].forEach((name) => {
                const orig = proto[name];
                if (typeof orig !== 'function') return;
                proto[name] = function () {
                    if (this._meshPageOpen) this.closeMeshPage();
                    return orig.apply(this, arguments);
                };
            });
        },

        _meshPlural(n, one, many) {
            return this.uiText(n === 1 ? one : many.replace('{count}', String(n)));
        },

        _renderMeshStatusRow() {
            const row = document.getElementById('meshStatusRow');
            const label = document.getElementById('meshStatusLabel');
            const links = document.getElementById('meshStatusLinks');
            if (!row || !label) return;
            const mesh = this._mesh;
            const running = !!(mesh && mesh.running);
            const peers = running ? mesh.peerList.length : 0;
            label.textContent = !running
                ? this.uiText('Mesh off')
                : (peers === 0 ? this.uiText('Mesh · no peers') : this._meshPlural(peers, 'Mesh · 1 peer', 'Mesh · {count} peers'));
            row.classList.toggle('active', running);
            const open = !!this._meshPageOpen;
            row.classList.toggle('selected', open);
            if (open) row.setAttribute('aria-current', 'page');
            else row.removeAttribute('aria-current');
            if (links) {
                const n = running ? mesh.linkCount : 0;
                links.textContent = n > 0 ? this._meshPlural(n, '1 link', '{count} links') : '';
            }
            this._renderMeshHeader();
        },

        _meshService() {
            if (this._mesh) return this._mesh;
            this._mesh = new window.NymMeshService.MeshService({
                nickname: () => this.nym || 'nym',
                nostrLink: () => this._meshNostrLink || null,
                log: (line) => {
                    if (!this._meshLog) this._meshLog = [];
                    this._meshLog.push(new Date().toLocaleTimeString() + '  ' + line);
                    if (this._meshLog.length > 200) this._meshLog.shift();
                    this._renderMeshLog();
                },
                onPublicMessage: (m) => this._onMeshPublicMessage(m),
                onPrivateMessage: (m) => this._onMeshPrivateMessage(m),
                onReceipt: (r) => { if (typeof this.onMeshReceipt === 'function') this.onMeshReceipt(r); },
                onFile: (f) => { if (typeof this.onMeshFile === 'function') this.onMeshFile(f); },
                onPeersChanged: () => { this._renderMeshPanel(); this._renderMeshStatusRow(); },
                onGhostChanged: () => { this._renderMeshPanel(); this._renderMeshStatusRow(); },
            });
            // Persisted so the backlog survives reloads and partition hops.
            this._mesh.onGossipArchiveChanged = (archive) => {
                try { localStorage.setItem(MESH_GOSSIP_KEY, archive); } catch (_) { }
            };
            this._mesh.onPrekeysChanged = (blob) => {
                try { localStorage.setItem(MESH_PREKEYS_KEY, blob); } catch (_) { }
            };
            this._mesh.onNostrCarrier = (carrier, fromPeerID) =>
                this._onMeshNostrCarrier(carrier, fromPeerID);
            this._mesh.onPingResult = (result) => this._onMeshPingResult(result);
            return this._mesh;
        },

        async startMesh() {
            const mesh = this._meshService();
            await this._prepareMeshNostrLink(mesh);
            try {
                await mesh.restoreGossipArchive(localStorage.getItem(MESH_GOSSIP_KEY));
            } catch (_) { }
            try {
                await mesh.restorePrekeys(localStorage.getItem(MESH_PREKEYS_KEY));
            } catch (_) { }
            await mesh.start();
            this.addChannel(MESH_CHANNEL, MESH_CHANNEL);
            this._renderMeshPanel();
            this._renderMeshStatusRow();
        },

        async stopMesh() {
            if (!this._mesh) return;
            await this._mesh.stop();
            // A round trip to an unreachable peer is stale.
            if (this._meshPings) {
                for (const held of this._meshPings.values()) {
                    if (held.timeout) clearTimeout(held.timeout);
                }
                this._meshPings.clear();
            }
            this._renderMeshPanel();
            this._renderMeshStatusRow();
        },

        async toggleMesh() {
            if (this._mesh && this._mesh.running) await this.stopMesh();
            else await this.startMesh();
        },

        // Both directions verify first: the originator signs, so a gateway is a postbox, not an author.
        async _onMeshNostrCarrier(carrier, fromPeerID) {
            const D = window.NymMeshExtras.CARRIER_DIRECTION;
            const event = window.NymMeshExtras.carrierEvent(carrier);
            if (!event || typeof event.id !== 'string' || typeof event.sig !== 'string') return;
            let ok = false;
            try { ok = await this._verifyRelayEventAsync(event); } catch (_) { ok = false; }
            if (!ok) {
                this._meshLogLine(`carried event from ${fromPeerID} FAILED verification — dropped`);
                return;
            }
            const outbound = carrier.direction === D.toGateway || carrier.direction === D.toBridge;
            if (outbound) {
                // Refused without our own connection.
                if (!this.connected) return;
                this.broadcastEvent(['EVENT', event]);
                this.ensureGeoRelayDelivery(event, carrier.geohash);
                this._meshLogLine(`published carried event for ${fromPeerID}`);
                return;
            }
            // Through the ordinary relay ingest so it renders, notifies and dedups like any event.
            this.handleRelayMessage(['EVENT', 'mesh-carrier', event], 'mesh');
        },

        // Returns peers asked, not published (the outbox keeps the message); never while ghosted (real-key signature).
        async meshCarryToGateway(geohash, event) {
            const mesh = this._mesh;
            if (!mesh || !mesh.running || mesh.ghostEnabled) return 0;
            let asked = 0;
            for (const peer of mesh.peerList) {
                // Verified only: handing traffic to an unverified radio tells a stranger we're here.
                if (!peer.isVerified) continue;
                if (await mesh.carryToGateway(peer.peerID, geohash, event)) asked++;
            }
            if (asked) this._meshLogLine(`asked ${asked} peer(s) to publish for us`);
            return asked;
        },

        _meshLogLine(line) {
            if (!this._meshLog) this._meshLog = [];
            this._meshLog.push(new Date().toLocaleTimeString() + '  ' + line);
            if (this._meshLog.length > 200) this._meshLog.shift();
            this._renderMeshLog();
        },

        // Only for the durable identity; Ghost Mode signs its own link.
        async _prepareMeshNostrLink(mesh) {
            try {
                const sk = this.privkey;
                if (!sk || !mesh.realIdentity) {
                    mesh.realIdentity = mesh.realIdentity || await window.NymMeshCrypto.MeshIdentity.loadOrCreate();
                }
                if (!sk) { this._meshNostrLink = null; return; }
                const C = window.NymMeshCrypto;
                const msgHex = await C.NostrLink.messageHex(mesh.realIdentity.staticPublic);
                const sig = window.NostrTools._schnorr.sign(
                    window.NymMeshProtocol.fromHex(msgHex), sk);
                this._meshNostrLink = C.NostrLink.build(this.pubkey, window.NymMeshProtocol.toHex(sig));
            } catch (_) {
                this._meshNostrLink = null;
            }
        },

        async addMeshPeer() {
            if (!this._mesh || !this._mesh.running) return;
            try {
                const name = await this._meshService().addPeer();
                this.displaySystemMessage(this.uiText('Mesh peer added: ') + name);
            } catch (err) {
                if (err && err.name === 'NotFoundError') return;
                this.displaySystemMessage(this.uiText('Could not add mesh peer: ') + (err && err.message));
            }
            this._renderMeshPanel();
        },

        async setMeshGhostMode(on) {
            const mesh = this._mesh;
            if (!mesh || !mesh.running) return;
            if (on) {
                const modal = document.getElementById('meshGhostModal');
                if (modal) modal.classList.add('active');
                return;
            }
            await mesh.setGhostMode(false);
            this._renderMeshPanel();
        },

        async meshGhostConfirm() {
            if (typeof window.closeModal === 'function') window.closeModal('meshGhostModal');
            const mesh = this._mesh;
            if (!mesh || !mesh.running) return;
            await mesh.setGhostMode(true);
            this._renderMeshPanel();
        },

        _sanitizeMeshGroupName(raw) {
            const lower = String(raw || '').trim().toLowerCase().replace(/^#+/, '');
            const cleaned = lower.replace(/[^\p{L}\p{N}]/gu, '');
            return cleaned.length > 40 ? cleaned.slice(0, 40) : cleaned;
        },

        openMeshJoin() {
            const modal = document.getElementById('meshJoinModal');
            if (!modal) return;
            const name = document.getElementById('meshJoinName');
            const pass = document.getElementById('meshJoinPassword');
            if (name) name.value = '';
            if (pass) pass.value = '';
            modal.classList.add('active');
            if (name) setTimeout(() => { try { name.focus(); } catch (_) { } }, 50);
        },

        async meshJoinSubmit() {
            const name = this._sanitizeMeshGroupName((document.getElementById('meshJoinName') || {}).value);
            const password = (document.getElementById('meshJoinPassword') || {}).value || '';
            if (typeof window.closeModal === 'function') window.closeModal('meshJoinModal');
            if (!name) return;
            await this.joinMeshGroup(name, password);
        },

        async joinMeshGroup(name, password) {
            if (!this._meshGroups) this._meshGroups = new Set();
            this._meshGroups.add(name);
            const mesh = this._mesh;
            if (password && mesh && typeof mesh.setChannelPassword === 'function') {
                try { await mesh.setChannelPassword('#' + name, password); } catch (_) { }
            }
            if (typeof this.addChannel === 'function') this.addChannel(name, name);
            this.closeMeshPage();
            this.switchChannel(name, name);
        },

        // inbound 
        _onMeshPublicMessage(m) {
            const channel = this.sanitizeChannelName(m.channel || '') || MESH_CHANNEL;
            if (typeof this.isChannelBlocked === 'function' && this.isChannelBlocked(channel, channel)) return;
            const seconds = Math.floor((m.timestampMs || Date.now()) / 1000);
            const pubkey = m.senderNostrPubkey || ('mesh:' + m.senderPeerID);
            // The sender's outbox later republishes with a `['nymmesh', id]` tag; remembering the id drops that copy.
            if (m.id) {
                if (!this._meshReplayIds) this._meshReplayIds = new Set();
                this._meshReplayIds.add(m.id);
            }
            this.displayMessage({
                id: 'mesh-' + m.senderPeerID + '-' + (m.timestampMs || Date.now()) + '-' + (this._msgSeq || 0),
                author: m.senderNickname,
                pubkey,
                content: m.content,
                created_at: seconds,
                _ms: m.timestampMs || Date.now(),
                _seq: ++this._msgSeq,
                timestamp: new Date(seconds * 1000),
                channel,
                geohash: channel,
                isOwn: false,
                isMesh: true,
                isPM: false,
                meshFile: m.meshFile || null,
            });
        },

        _onMeshPrivateMessage(m) {
            const seconds = Math.floor((m.timestampMs || Date.now()) / 1000);
            const ms = m.timestampMs || Date.now();

            // Only a verified nostrLink files it under the real conversation; otherwise it surfaces in #mesh.
            const pubkey = m.senderNostrPubkey;
            if (!pubkey) {
                this._onMeshPublicMessage({
                    senderPeerID: m.senderPeerID,
                    senderNickname: m.senderNickname,
                    meshFile: m.meshFile || null,
                    content: '(direct over mesh) ' + m.content,
                    timestampMs: ms,
                    channel: MESH_CHANNEL,
                });
                return;
            }

            if (this.blockedUsers && this.blockedUsers.has(pubkey)) return;
            const accept = this.settings && this.settings.acceptPMs;
            if (accept && accept !== 'enabled') {
                if (accept === 'disabled') return;
                if (accept === 'friends' && !(typeof this.isFriend === 'function' && this.isFriend(pubkey))) return;
            }

            const conversationKey = this.getPMConversationKey(pubkey);
            const msg = {
                id: 'mesh-pm-' + m.messageId,
                nymMessageId: m.messageId,
                author: m.senderNickname,
                pubkey,
                content: m.content,
                created_at: seconds,
                _ms: ms,
                _seq: ++this._msgSeq,
                timestamp: new Date(seconds * 1000),
                isOwn: false,
                isMesh: true,
                isPM: true,
                conversationKey,
                conversationPubkey: pubkey,
                senderVerified: true,
                meshFile: m.meshFile || null,
            };

            let list = this.pmMessages.get(conversationKey) || [];
            if (list.some(x => x.id === msg.id)) return;
            if (typeof this._gtAbsorbLive === 'function' && this._gtAbsorbLive(msg, list)) return;
            list.push(msg);
            list.sort((a, b) => this._compareMessages(a, b));
            if (list.length > this.pmStorageLimit) list = list.slice(-this.pmStorageLimit);
            this.pmMessages.set(conversationKey, list);
            if (typeof this.persistPMMessages === 'function') this.persistPMMessages(conversationKey);
            if (typeof this.isContentHidden === 'function' && this.isContentHidden(msg)) return;

            this.addPMConversation(this.getNymFromPubkey(pubkey), pubkey, ms);
            this.movePMToTop(pubkey, ms);
            this.displayMessage(msg);
            if (typeof this.updateUnreadCount === 'function') this.updateUnreadCount(conversationKey, msg.created_at);
        },

        // #mesh always rides the mesh; other channels only when the internet route is unavailable.
        meshShouldCarry(channel) {
            if (!this._mesh || !this._mesh.running) return false;
            if (channel === MESH_CHANNEL) return true;
            if (this._meshGroups && this._meshGroups.has(channel)) return true;
            return !this.connected;
        },

        // Nothing comes back from the mesh for our own packet, so echo locally.
        async _sendChannelOverMesh(content, channel) {
            const mesh = this._meshService();
            let meshId = null;
            try {
                meshId = await mesh.sendPublicMessage(content, channel === MESH_CHANNEL ? null : channel);
            } catch (err) {
                this.displaySystemMessage(this.uiText('Mesh send failed: ') + (err && err.message));
                return;
            }
            if (mesh.linkCount === 0) {
                this.displaySystemMessage(this.uiText('No mesh device in range — waiting for Bluetooth range.'));
            }
            const now = Date.now();
            // `_optim_` so the Nostr replay reconciles onto this bubble (`_replaceOptimisticMessage`).
            const localId = '_optim_mesh' + now.toString(36) + (this._msgSeq || 0);
            this.displayMessage({
                id: localId,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                created_at: Math.floor(now / 1000),
                _ms: now,
                _seq: ++this._msgSeq,
                timestamp: new Date(now),
                channel,
                geohash: channel,
                isOwn: true,
                isMesh: true,
                isPM: false,
                _optimistic: true,
                _storageKey: `#${channel}`,
            });
            // Only offline sends are queued; `#mesh` is a real kind-20000 channel, so it queues too.
            if (this.connected) return;
            const entry = {
                kind: 'channel',
                target: channel,
                content,
                createdAt: Math.floor(now / 1000),
                localId,
                meshMessageId: meshId || null,
            };
            // Sign once so gateway and outbox publish identical bytes and relays dedup the second.
            let signed = null;
            try { signed = await this._meshBuildOutboxEvent(entry); } catch (_) { }
            if (signed) entry.signedEvent = signed;
            if (typeof this.meshOutboxQueue === 'function') this.meshOutboxQueue(entry);
            // A gateway shortcut; the entry stays queued since nothing confirms gateway success.
            if (signed) this.meshCarryToGateway(channel, signed).catch(() => { });
        },

        // Signed by us, so a carrying gateway can't alter or forge it.
        async _meshBuildOutboxEvent(entry) {
            if (!entry || entry.kind !== 'channel') return null;
            if (typeof this.publishMessage !== 'function') return null;
            const event = await this.publishMessage(
                entry.content, entry.target, entry.target, null, entry.threadRoot || null,
                {
                    buildOnly: true,
                    createdAt: entry.createdAt,
                    localId: entry.localId,
                    extraTags: entry.meshMessageId ? [['nymmesh', entry.meshMessageId]] : [],
                });
            return event && event.sig ? event : null;
        },

        meshPageAvailable() {
            return !!this._meshAvailable;
        },

        openMeshPanel() {
            if (!this.meshPageAvailable()) return;
            const page = document.getElementById('meshPage');
            const main = document.querySelector('.main-content');
            if (!page || !main) return;
            if (!this._meshPageOpen) {
                this._meshSavedActive = Array.from(document.querySelectorAll('#sidebar .channel-item.active, #sidebar .pm-item.active'));
                this._meshSavedActive.forEach((el) => el.classList.remove('active'));
            }
            this._meshPageOpen = true;
            main.classList.add('mesh-mode');
            document.body.classList.add('mesh-page-open');
            page.hidden = false;
            if (typeof this._pushNavigation === 'function') this._pushNavigation({ type: 'mesh' });
            this._renderMeshPanel();
            this._renderMeshLog();
            this._renderMeshStatusRow();
        },

        closeMeshPage() {
            if (!this._meshPageOpen) return;
            this._meshPageOpen = false;
            const page = document.getElementById('meshPage');
            const main = document.querySelector('.main-content');
            if (page) page.hidden = true;
            if (main) main.classList.remove('mesh-mode');
            document.body.classList.remove('mesh-page-open');
            (this._meshSavedActive || []).forEach((el) => { if (el.isConnected) el.classList.add('active'); });
            this._meshSavedActive = null;
            this._renderMeshStatusRow();
            if (!this._navigating) setTimeout(() => this._meshRecordLeave(), 0);
        },

        _meshRecordLeave() {
            if (this._meshPageOpen || this._navigating || !Array.isArray(this.navigationHistory)) return;
            const current = this.navigationHistory[this.navigationIndex];
            if (!current || current.type !== 'mesh') return;
            let entry = null;
            if (this.inPMMode && this.currentGroup) entry = { type: 'group', groupId: this.currentGroup };
            else if (this.inPMMode && this.currentPM) entry = { type: 'pm', nym: this.getNymFromPubkey(this.currentPM), pubkey: this.currentPM };
            else if (!this.inPMMode && this.currentChannel) entry = { type: 'channel', channel: this.currentChannel, geohash: this.currentGeohash || '' };
            if (entry) this._pushNavigation(entry);
        },

        meshBackToList() {
            this.closeMeshPage();
            const s = document.getElementById('sidebar');
            if (s && !s.classList.contains('open') && typeof this.toggleSidebar === 'function') this.toggleSidebar();
        },

        meshOpenChannel() {
            this.closeMeshPage();
            this.addChannel(MESH_CHANNEL, MESH_CHANNEL);
            this.switchChannel(MESH_CHANNEL, MESH_CHANNEL);
        },

        _meshLinkedKey(peer) {
            return peer && peer.nostrLinkVerified && typeof peer.nostrPubkey === 'string' && /^[0-9a-f]{64}$/i.test(peer.nostrPubkey)
                ? peer.nostrPubkey.toLowerCase() : null;
        },

        meshOpenPeer(peerID) {
            const mesh = this._mesh;
            const peer = mesh && mesh.peerList ? mesh.peerList.find((p) => p.peerID === peerID) : null;
            const pk = this._meshLinkedKey(peer);
            if (!pk) return;
            this.closeMeshPage();
            this.openPM(peer.nickname || this.getNymFromPubkey(pk), pk);
        },

        _meshHeaderSub() {
            const mesh = this._mesh;
            if (!mesh || !mesh.running) return this.uiText('Off');
            const peers = mesh.peerList.length;
            let base;
            if (!peers) base = this.uiText('Searching · no peers yet');
            else {
                const parts = [this._meshPlural(peers, '1 peer', '{count} peers')];
                if (mesh.linkCount > 0) parts.push(this._meshPlural(mesh.linkCount, '1 link', '{count} links'));
                base = parts.join(' · ');
            }
            return mesh.ghostEnabled ? base + ' · ' + this.uiText('Ghost Mode') : base;
        },

        _renderMeshHeader() {
            const sub = document.getElementById('meshHeaderSub');
            if (!sub) return;
            const mesh = this._mesh;
            const running = !!(mesh && mesh.running);
            const ghost = running && !!mesh.ghostEnabled;
            sub.textContent = this._meshHeaderSub();
            const g = document.getElementById('meshGhostBtn');
            if (g) {
                g.disabled = !running;
                g.setAttribute('aria-pressed', ghost ? 'true' : 'false');
                g.classList.toggle('on', ghost);
                g.setAttribute('aria-label', this.uiText(ghost ? 'Ghost Mode on' : 'Ghost Mode off'));
            }
            const add = document.getElementById('meshAddBtn');
            if (add) add.disabled = !running;
        },

        _meshPeerLine(peer) {
            const held = this._meshPings && this._meshPings.get(peer.peerID);
            if (held) {
                if (held.state === 'waiting') return this.uiText('Pinging…');
                if (held.state === 'lost') return this.uiText('No reply to ping');
                if (held.hops === null || held.hops === undefined) return this.uiText(`${held.roundTripMs} ms`);
                if (held.hops === 1) return this.uiText(`1 hop · ${held.roundTripMs} ms`);
                return this.uiText(`${held.hops} hops · ${held.roundTripMs} ms`);
            }
            return this.uiText(peer.isVerified ? 'Verified' : 'Not verified yet');
        },

        _meshRefreshForFilters() {
            if (this._meshPageOpen) this._renderMeshPanel();
        },

        _renderMeshPanel() {
            this._renderMeshHeader();
            const body = document.getElementById('meshPanelBody');
            if (!body || !this._meshPageOpen) return;
            const mesh = this._mesh;
            const running = !!(mesh && mesh.running);
            const links = running ? (mesh.linkList || []) : [];
            const peers = (running ? (mesh.peerList || []) : []).filter((p) =>
                !(typeof this.isPersonHidden === 'function' && this.isPersonHidden(this._meshLinkedKey(p) || '', p.nickname || '')));
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            const u = (s) => esc(this.uiText(s));
            const icon = (inner) => `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${inner}</svg>`;
            const RADAR = icon('<circle cx="12" cy="12" r="9"></circle><circle cx="12" cy="12" r="4.75"></circle><path d="M12 12 L18.36 5.64"></path>');
            const CLOSE = icon('<path d="M18 6 6 18M6 6l12 12"></path>');
            const PLUS = '<svg class="channel-glyph" viewBox="0 0 24 24" width="10" height="10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 5v14M5 12h14"></path></svg>';
            const short = running && mesh.peerID ? String(mesh.peerID).slice(0, 8) : '';
            const powerSub = !running
                ? u('Chat with people nearby, no internet needed')
                : (short ? u(`On · your mesh ID ${short}`).replace(esc(short), `<code>${esc(short)}</code>`) : u('Starting…'));
            const empty = (text) => `<div class="list-empty mesh-empty"><span class="list-empty-text">${u(text)}</span></div>`;
            const section = (title) => `<div class="nav-title mesh-sec"><span class="nav-title-text">${esc(title)}</span></div>`;
            const row = (cls, attrs, lead, name, sub, trail) => `<div class="mesh-row${cls}" ${attrs}>${lead}<span class="mesh-row-text"><span class="mesh-row-name">${name}</span><span class="mesh-row-sub">${sub}</span></span>${trail || ''}</div>`;

            const peerRows = peers.map((p) => {
                const pk = this._meshLinkedKey(p);
                const display = p.nickname ? p.nickname : String(p.peerID).slice(0, 8);
                const suffix = pk ? '#' + pk.slice(-4) : '';
                const avatar = `<img class="mesh-row-avatar" src="${esc(this.getAvatarUrl(pk || p.peerID))}" alt="" aria-hidden="true">`;
                const name = `${esc(display)}${suffix ? `<span class="nym-suffix">${esc(suffix)}</span>` : ''}`;
                const attrs = `data-peer-id="${esc(p.peerID)}" title="${esc((p.nickname || display) + ' · ' + p.peerID)}"` +
                    (pk ? ` role="button" tabindex="0" data-action="meshOpenPeer"` : '');
                const held = this._meshPings && this._meshPings.get(p.peerID);
                const waiting = !!(held && held.state === 'waiting');
                const ping = `<button type="button" class="mesh-icon-btn" data-action="meshPingPeer" data-peer-id="${esc(p.peerID)}" aria-label="${u('Ping')}" data-tip=""${waiting ? ' disabled' : ''}>${RADAR}</button>`;
                return row(' mesh-peer' + (pk ? ' mesh-tappable' : ''), attrs, avatar, name, esc(this._meshPeerLine(p)), ping);
            }).join('');

            const linkRows = links.map((l) => row(
                '',
                'data-link-id="' + esc(l.id) + '"',
                `<span class="mesh-link-dot ${l.connected ? 'up' : 'down'}" aria-hidden="true"></span>`,
                esc(l.name),
                u(l.connected ? 'Connected' : 'Out of range'),
                `<button type="button" class="mesh-icon-btn" data-action="meshForgetPeer" data-peer-id="${esc(l.id)}" aria-label="${u('Forget')}" data-tip="">${CLOSE}</button>`,
            )).join('');

            let peersBlock;
            if (!running) peersBlock = empty('Turn the mesh on to find people nearby.');
            else if (!peers.length) peersBlock = empty('No one in range yet. Peers show up when another Nymchat device is nearby.');
            else peersBlock = peerRows;

            body.innerHTML = `
                <div class="mesh-power">
                    <div class="mesh-power-text">
                        <div class="mesh-power-title">${u('Mesh')}</div>
                        <div class="mesh-power-sub">${powerSub}</div>
                    </div>
                    <label class="nym-switch" title="${u('Bluetooth mesh')}">
                        <input type="checkbox" id="meshPowerSwitch" data-on-change="meshToggle" aria-label="${u('Bluetooth mesh')}"${running ? ' checked' : ''}>
                        <span class="nym-switch-track"><span class="nym-switch-thumb"></span></span>
                    </label>
                </div>
                ${section(this.uiText('Channels'))}
                ${row(' mesh-tappable', 'id="meshChannelRow" role="button" tabindex="0" data-action="meshOpenChannel"', `<span class="channel-tile" aria-hidden="true">${this._channelGlyphSvg(true, 10)}</span>`, '#mesh', u('Public · everyone in range'))}
                ${row(' mesh-tappable', 'id="meshJoinRow" role="button" tabindex="0" data-action="meshOpenJoin"', `<span class="channel-tile" aria-hidden="true">${PLUS}</span>`, u('Join or create a mesh group'), u('Named room · optional password'))}
                ${section(running && peers.length ? this.uiText(`Peers nearby (${peers.length})`) : this.uiText('Peers nearby'))}
                ${peersBlock}
                ${section(this.uiText('Paired devices'))}
                ${running && links.length ? linkRows : empty('No devices paired yet.')}
                <p class="mesh-hint">${u("Browsers can't advertise, so this tab connects out to nearby phones and relays through them. Pick each device once; it reconnects by itself.")}</p>
            `;
        },

        meshToggleDiag() {
            const log = document.getElementById('meshLogBody');
            const btn = document.querySelector('.mesh-diag-toggle');
            const diag = document.getElementById('meshDiag');
            if (!log || !btn) return;
            const open = log.hidden;
            log.hidden = !open;
            btn.setAttribute('aria-expanded', open ? 'true' : 'false');
            if (diag) diag.classList.toggle('open', open);
            this._renderMeshLog();
        },

        _meshDiagLines() {
            const mesh = this._mesh;
            const ids = [];
            if (mesh && mesh.running && mesh.peerID) ids.push(this.uiText('Your mesh ID') + '  ' + mesh.peerID);
            if (mesh && mesh.running) for (const p of (mesh.peerList || [])) ids.push((p.nickname || p.peerID) + '  ' + p.peerID);
            return ids.concat((this._meshLog || []).slice(-60));
        },

        meshCopyDiag() {
            const text = this._meshDiagLines().join('\n');
            try { navigator.clipboard.writeText(text); } catch (_) { }
        },

        meshClearDiag() {
            this._meshLog = [];
            this._renderMeshLog();
        },

        _renderMeshLog() {
            const el = document.getElementById('meshLogBody');
            if (!el) return;
            const lines = this._meshDiagLines();
            el.textContent = lines.length ? lines.join('\n') : this.uiText('No mesh activity yet');
        },

        meshForgetPeer(id) {
            if (!this._mesh) return;
            this._mesh.forgetPeer(id).then(() => this._renderMeshPanel());
        },

        // The echo shows whether a peer is in the same room or several relays away.
        meshPingPeer(peerID) {
            const mesh = this._mesh;
            if (!mesh || !mesh.running || !peerID) return;
            if (!this._meshPings) this._meshPings = new Map();
            this._meshPings.set(peerID, { state: 'waiting' });
            this._renderMeshPanel();
            // Time it out: the announce may be minutes old.
            const timeout = setTimeout(() => {
                const held = this._meshPings.get(peerID);
                if (!held || held.state !== 'waiting') return;
                this._meshPings.set(peerID, { state: 'lost' });
                this._renderMeshPanel();
            }, MESH_PING_TIMEOUT_MS);
            this._meshPings.get(peerID).timeout = timeout;
            mesh.ping(peerID).then((sent) => {
                if (sent) return;
                clearTimeout(timeout);
                this._meshPings.set(peerID, { state: 'lost' });
                this._renderMeshPanel();
            });
        },

        _onMeshPingResult(result) {
            if (!this._meshPings) this._meshPings = new Map();
            const held = this._meshPings.get(result.peerID);
            if (held && held.timeout) clearTimeout(held.timeout);
            this._meshPings.set(result.peerID, {
                state: 'ok', roundTripMs: result.roundTripMs, hops: result.hops,
            });
            this._meshLogLine(`pong from ${result.peerID} ${result.roundTripMs}ms`
                + (result.hops === null ? '' : ` (${result.hops} hop${result.hops === 1 ? '' : 's'})`));
            this._renderMeshPanel();
        },
    });
})();
