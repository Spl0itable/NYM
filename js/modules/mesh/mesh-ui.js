// mesh-ui.js - wires the Bluetooth mesh into the app: the #mesh channel, mesh
// private messages, and the mesh panel with its Ghost Mode toggle.
//
// The whole feature is hidden unless the browser can actually do it, so an
// unsupported browser sees no dead controls.

(function () {
    const NYM = window.NYM;
    if (!NYM) return;

    const MESH_CHANNEL = 'mesh';

    Object.assign(NYM.prototype, {

        meshSupported() {
            return !!(window.NymMeshTransport && window.NymMeshTransport.isSupported());
        },

        async meshUsable() {
            if (!this.meshSupported()) return false;
            try { return await window.NymMeshCrypto.cryptoSupported(); } catch (_) { return false; }
        },

        // Shows the entry point only where the feature can run. Chromium exposes
        // Web Bluetooth; Safari and Firefox do not.
        async initMeshUI() {
            const btn = document.getElementById('meshSidebarBtn');
            if (!btn) return;
            if (!(await this.meshUsable())) { btn.classList.add('nm-hidden'); return; }
            btn.classList.remove('nm-hidden');
            this._meshLog = [];
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
                onReceipt: () => { },
                onPeersChanged: () => this._renderMeshPanel(),
                onGhostChanged: () => this._renderMeshPanel(),
            });
            return this._mesh;
        },

        async startMesh() {
            const mesh = this._meshService();
            await this._prepareMeshNostrLink(mesh);
            await mesh.start();
            this.addChannel(MESH_CHANNEL, MESH_CHANNEL);
            this._renderMeshPanel();
        },

        async stopMesh() {
            if (!this._mesh) return;
            await this._mesh.stop();
            this._renderMeshPanel();
        },

        async toggleMesh() {
            if (this._mesh && this._mesh.running) await this.stopMesh();
            else await this.startMesh();
        },

        // Binds this device's mesh key to its Nostr identity so peers can match
        // it to the real profile. Ghost Mode signs its own link instead, so this
        // is only built for the durable identity.
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
                    'devices cannot recognise you or follow you between places.\n\n' +
                    'You can still send and receive messages. Anyone you talk to while it is on sees ' +
                    'an anonymous identity, not your usual one. Turning it off restores your normal identity.',
                    { okLabel: 'Enable' });
                if (!okToGo) { this._renderMeshPanel(); return; }
            }
            await mesh.setGhostMode(on);
            this._renderMeshPanel();
        },

        // ---- inbound ---------------------------------------------------------

        _onMeshPublicMessage(m) {
            const channel = m.channel || MESH_CHANNEL;
            const seconds = Math.floor((m.timestampMs || Date.now()) / 1000);
            const pubkey = m.senderNostrPubkey || ('mesh:' + m.senderPeerID);
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
            });
        },

        _onMeshPrivateMessage(m) {
            const seconds = Math.floor((m.timestampMs || Date.now()) / 1000);
            const ms = m.timestampMs || Date.now();

            // Only a VERIFIED nostrLink identifies the sender well enough to file
            // the message under their real conversation. Without one there is no
            // Nostr pubkey to key a thread on, so it surfaces in #mesh rather
            // than being dropped or filed under a fake identity.
            const pubkey = m.senderNostrPubkey;
            if (!pubkey) {
                this._onMeshPublicMessage({
                    senderPeerID: m.senderPeerID,
                    senderNickname: m.senderNickname,
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
            };

            let list = this.pmMessages.get(conversationKey) || [];
            if (list.some(x => x.id === msg.id)) return;
            list.push(msg);
            list.sort((a, b) => this._compareMessages(a, b));
            if (list.length > this.pmStorageLimit) list = list.slice(-this.pmStorageLimit);
            this.pmMessages.set(conversationKey, list);
            if (typeof this.persistPMMessages === 'function') this.persistPMMessages(conversationKey);

            this.addPMConversation(this.getNymFromPubkey(pubkey), pubkey, ms);
            this.movePMToTop(pubkey, ms);
            this.displayMessage(msg);
            if (typeof this.updateUnreadCount === 'function') this.updateUnreadCount(conversationKey);
        },

        // True when the message the user is sending should ride the mesh: the
        // #mesh channel always does, and anything else falls back to it only
        // when the internet route is unavailable.
        meshShouldCarry(channel) {
            if (!this._mesh || !this._mesh.running) return false;
            if (channel === MESH_CHANNEL) return true;
            return !this.connected;
        },

        // Sends over the radio and echoes locally: nothing comes back from the
        // mesh for our own packet, so the sender would otherwise see nothing.
        async _sendChannelOverMesh(content, channel) {
            const mesh = this._meshService();
            try {
                await mesh.sendPublicMessage(content, channel === MESH_CHANNEL ? null : channel);
            } catch (err) {
                this.displaySystemMessage('Mesh send failed: ' + (err && err.message));
                return;
            }
            if (mesh.linkCount === 0) {
                this.displaySystemMessage('No mesh device in range — waiting for Bluetooth range.');
            }
            const now = Date.now();
            this.displayMessage({
                id: 'mesh-own-' + now + '-' + (this._msgSeq || 0),
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
            });
        },

        // ---- panel -----------------------------------------------------------

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
                        <span class="mesh-peer-meta">${esc(p.peerID)}${p.isVerified ? ' &middot; verified' : ''}${p.nostrLinkVerified ? ' &middot; linked' : ''}</span>
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
    });
})();
