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

        // Chromium exposes Web Bluetooth; Safari and Firefox do not.
        async initMeshUI() {
            const row = document.getElementById('meshStatusRow');
            if (!row) return;
            if (!(await this.meshUsable())) { row.classList.add('nm-hidden'); return; }
            row.classList.remove('nm-hidden');
            this._meshLog = [];
            this._renderMeshStatusRow();
        },

        // Mirrors the Flutter mesh status row.
        _renderMeshStatusRow() {
            const row = document.getElementById('meshStatusRow');
            const label = document.getElementById('meshStatusLabel');
            const links = document.getElementById('meshStatusLinks');
            if (!row || !label) return;
            const mesh = this._mesh;
            const running = !!(mesh && mesh.running);
            const peers = running ? mesh.peerList.length : 0;
            label.textContent = !running
                ? 'Mesh off'
                : (peers === 0 ? 'Mesh · no peers' : `Mesh · ${peers} peer${peers === 1 ? '' : 's'}`);
            row.classList.toggle('active', running);
            if (links) {
                const n = running ? mesh.linkCount : 0;
                links.textContent = n > 0 ? `${n} link${n === 1 ? '' : 's'}` : '';
            }
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
                const sig = window.NostrTools._secp256k1.schnorr.sign(
                    window.NymMeshProtocol.fromHex(msgHex), sk);
                this._meshNostrLink = C.NostrLink.build(this.pubkey, window.NymMeshProtocol.toHex(sig));
            } catch (_) {
                this._meshNostrLink = null;
            }
        },

        async addMeshPeer() {
            try {
                const name = await this._meshService().addPeer();
                this.displaySystemMessage('Mesh peer added: ' + name);
            } catch (err) {
                if (err && err.name === 'NotFoundError') return; // chooser dismissed
                this.displaySystemMessage('Could not add mesh peer: ' + (err && err.message));
            }
            this._renderMeshPanel();
        },

        async setMeshGhostMode(on) {
            const mesh = this._meshService();
            if (on) {
                const okToGo = await window.showAppConfirm(
                    'Ghost Mode hides who you are on the Bluetooth mesh.\n\n' +
                    'Your device stops advertising your nym and your Nostr identity. It presents a ' +
                    'throwaway name and key instead, and replaces them every few minutes, so nearby ' +
                    'devices cannot recognize you or follow you between places.\n\n' +
                    'You can still send and receive messages. Anyone you talk to while it is on sees ' +
                    'an anonymous identity, not your usual one. Turning it off restores your normal identity.',
                    { okLabel: 'Enable' });
                if (!okToGo) { this._renderMeshPanel(); return; }
            }
            await mesh.setGhostMode(on);
            this._renderMeshPanel();
        },

        // inbound 
        _onMeshPublicMessage(m) {
            const channel = this.sanitizeChannelName(m.channel || '') || MESH_CHANNEL;
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

            this.addPMConversation(this.getNymFromPubkey(pubkey), pubkey, ms);
            this.movePMToTop(pubkey, ms);
            this.displayMessage(msg);
            if (typeof this.updateUnreadCount === 'function') this.updateUnreadCount(conversationKey, msg.created_at);
        },

        // #mesh always rides the mesh; other channels only when the internet route is unavailable.
        meshShouldCarry(channel) {
            if (!this._mesh || !this._mesh.running) return false;
            if (channel === MESH_CHANNEL) return true;
            return !this.connected;
        },

        // Nothing comes back from the mesh for our own packet, so echo locally.
        async _sendChannelOverMesh(content, channel) {
            const mesh = this._meshService();
            let meshId = null;
            try {
                meshId = await mesh.sendPublicMessage(content, channel === MESH_CHANNEL ? null : channel);
            } catch (err) {
                this.displaySystemMessage('Mesh send failed: ' + (err && err.message));
                return;
            }
            if (mesh.linkCount === 0) {
                this.displaySystemMessage('No mesh device in range — waiting for Bluetooth range.');
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

        //  panel 
        openMeshPanel() {
            const modal = document.getElementById('meshModal');
            if (!modal) return;
            modal.classList.add('active');
            this._renderMeshPanel();
            this._renderMeshLog();
        },

        _renderMeshPanel() {
            const body = document.getElementById('meshPanelBody');
            if (!body) return;
            const mesh = this._mesh;
            const running = !!(mesh && mesh.running);
            const links = running ? mesh.linkList : [];
            const peers = running ? mesh.peerList : [];
            const ghost = running && mesh.ghostEnabled;

            const esc = (s) => this.escapeHtml(s);
            const peerRows = peers.length
                ? peers.map(p => `<div class="mesh-peer">
                        <span class="mesh-peer-name">${esc(p.nickname || p.peerID)}</span>
                        <span class="mesh-peer-meta">${esc(p.peerID)}${p.isVerified ? ' &middot; verified' : ''}${p.nostrLinkVerified ? ' &middot; linked' : ''}${this._meshPingLabel(p.peerID)}</span>
                        <button class="mesh-ping" data-action="meshPingPeer" data-peer-id="${esc(p.peerID)}" type="button"
                            title="Measure the round trip and how many hops away this peer is">Ping</button>
                    </div>`).join('')
                : '<div class="mesh-empty">No peers heard yet.</div>';

            const linkRows = links.length
                ? links.map(l => `<div class="mesh-link">
                        <span class="mesh-link-dot ${l.connected ? 'up' : 'down'}"></span>
                        <span class="mesh-link-name">${esc(l.name)}</span>
                        <button class="mesh-forget" data-action="meshForgetPeer" data-peer-id="${esc(l.id)}" type="button">Forget</button>
                    </div>`).join('')
                : '<div class="mesh-empty">No devices paired. Add one to join the mesh.</div>';

            body.innerHTML = `
                <div class="mesh-status">
                    <span class="mesh-status-dot ${running ? 'on' : 'off'}"></span>
                    <span class="mesh-status-text">${running ? 'Mesh on' : 'Mesh off'}</span>
                    ${running && mesh.peerID ? `<span class="mesh-self">${esc(mesh.peerID)}</span>` : ''}
                    <button class="mesh-toggle" data-action="meshToggle" type="button">${running ? 'Turn off' : 'Turn on'}</button>
                    <button class="mesh-ghost ${ghost ? 'on' : 'off'}" data-action="meshToggleGhost" type="button"
                        title="${ghost ? 'Ghost Mode on' : 'Ghost Mode off'}" aria-label="Ghost Mode"
                        ${running ? '' : 'disabled'}>${this._meshGhostIcon(ghost)}</button>
                </div>
                <p class="mesh-note">A browser can join the mesh but cannot advertise itself, so it
                    connects out to nearby phones and relays through them. Pick each device once —
                    it reconnects on its own after that.</p>
                <div class="mesh-section-title">Paired devices
                    <button class="mesh-add" data-action="meshAddPeer" type="button">Add device</button>
                </div>
                ${linkRows}
                <div class="mesh-section-title">Peers on the mesh</div>
                ${peerRows}
            `;
        },

        _meshGhostIcon(on) {
            const body = on
                ? '<path d="M4 22V10a8 8 0 0 1 16 0v12l-2.7-2.6L14.6 22l-2.6-2.6L9.4 22 6.7 19.4Z" fill="currentColor"/>' +
                  '<circle cx="9.5" cy="10.5" r="1.4" fill="var(--bg)"/><circle cx="14.5" cy="10.5" r="1.4" fill="var(--bg)"/>'
                : '<path d="M4 22V10a8 8 0 0 1 16 0v12l-2.7-2.6L14.6 22l-2.6-2.6L9.4 22 6.7 19.4Z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>' +
                  '<circle cx="9.5" cy="10.5" r="1.2" fill="currentColor"/><circle cx="14.5" cy="10.5" r="1.2" fill="currentColor"/>';
            const badge = on
                ? '<circle cx="18.5" cy="18.5" r="5" fill="#22C55E"/><path d="m16.2 18.6 1.6 1.6 3-3.2" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>'
                : '<circle cx="18.5" cy="18.5" r="5" fill="#EF4444"/><path d="m16.6 16.6 3.8 3.8m0-3.8-3.8 3.8" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/>';
            return `<svg viewBox="0 0 26 26" width="22" height="22" aria-hidden="true">${body}
                <circle cx="18.5" cy="18.5" r="6.4" fill="var(--bg-secondary)"/>${badge}</svg>`;
        },

        _renderMeshLog() {
            const el = document.getElementById('meshLogBody');
            if (!el) return;
            const lines = this._meshLog || [];
            el.textContent = lines.length ? lines.slice(-60).join('\n') : 'No radio activity yet.';
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

        _meshPingLabel(peerID) {
            const held = this._meshPings && this._meshPings.get(peerID);
            if (!held) return '';
            if (held.state === 'waiting') return ' &middot; pinging&hellip;';
            if (held.state === 'lost') return ' &middot; no reply';
            const hops = held.hops === null
                ? '' : `, ${held.hops} hop${held.hops === 1 ? '' : 's'}`;
            return ` &middot; ${held.roundTripMs}ms${hops}`;
        },
    });
})();
