(function () {
    const L = () => window.NymShareLinks;
    const SEND_GUARD_MS = 3000;
    const KIND_TEXT = {
        profile: '{nick} wants to share a profile',
        groupInvite: '{nick} wants to share a group',
        channel: '{nick} wants to share a channel',
    };

    Object.assign(NYM.prototype, {
        _nearbyMesh() {
            const m = this._mesh;
            return m && m.running ? m : null;
        },

        shareNearbyAvailable() {
            return !!this._nearbyMesh();
        },

        _nearbyPeers() {
            const m = this._nearbyMesh();
            if (!m || !m.peers) return [];
            return [...m.peers.values()]
                .filter((p) => p && typeof p.nostrPubkey === 'string' && /^[0-9a-f]{64}$/.test(p.nostrPubkey) && p.nostrLinkVerified === true)
                .filter((p) => !(this.blockedUsers && this.blockedUsers.has(p.nostrPubkey)))
                .sort((a, b) => ((b.isDirect ? 1 : 0) - (a.isDirect ? 1 : 0)) || ((b.rssi ?? -999) - (a.rssi ?? -999)));
        },

        openNearbyShare(tg) {
            if (!tg || !tg.codeLink || tg.refusal) return;
            window.closeModal('shareModal');
            const { modal, body } = this._shareModal('shareNearbyModal', 'Share nearby');
            body.textContent = '';
            const status = document.createElement('div');
            status.className = 'share-scan-status';
            status.setAttribute('role', 'status');
            const m = this._nearbyMesh();
            if (!m) {
                status.textContent = this._shT('Nearby sharing needs the Bluetooth mesh to be on.');
                const go = this._shareButton('Bluetooth mesh');
                go.addEventListener('click', () => { window.closeModal('shareNearbyModal'); if (typeof this.openMeshPanel === 'function') this.openMeshPanel(); });
                body.append(status, go);
                modal.classList.add('active');
                return;
            }
            const peers = this._nearbyPeers();
            if (!peers.length) {
                status.textContent = this._shT('No Nymchat users nearby');
                body.appendChild(status);
                modal.classList.add('active');
                return;
            }
            const list = document.createElement('div');
            list.className = 'share-nearby-list';
            list.setAttribute('role', 'listbox');
            let chosen = null;
            peers.forEach((p) => {
                const b = document.createElement('button');
                b.type = 'button';
                b.className = 'share-nearby-peer';
                b.setAttribute('role', 'option');
                b.setAttribute('aria-selected', 'false');
                b.dataset.peerId = p.peerID;
                b.textContent = p.nickname || p.peerID;
                b.addEventListener('click', () => {
                    chosen = p;
                    list.querySelectorAll('button').forEach((x) => x.setAttribute('aria-selected', x === b ? 'true' : 'false'));
                    send.disabled = false;
                });
                list.appendChild(b);
            });
            const send = this._shareButton('Send', 'icon-btn primary');
            send.dataset.nearbyAction = 'send';
            send.disabled = true;
            if (!this._nearbySendGuard) this._nearbySendGuard = L().createSendGuard(SEND_GUARD_MS);
            send.addEventListener('click', async () => {
                if (!chosen || !this._nearbySendGuard.allow(chosen.peerID, Date.now())) return;
                const peer = chosen;
                try {
                    await m.sendNymShare(peer.peerID, tg.codeLink);
                    status.textContent = this._shT('Sent to {nick}. They need to accept it.').replace('{nick}', peer.nickname || peer.peerID);
                } catch (_) { }
            });
            body.append(list, send, status);
            modal.classList.add('active');
        },

        _nearbyReceive(msg) {
            const link = msg && msg.payload ? L().decodeNearby(msg.payload) : null;
            if (!link) return;
            const r = L().parseShareInput(link);
            if (r.kind === 'invalid' || r.kind === 'appLink') return;
            const mesh = this._mesh;
            const peer = mesh && mesh.peers ? mesh.peers.get(msg.senderPeerID) : null;
            if (peer && peer.nostrPubkey && this.blockedUsers && this.blockedUsers.has(peer.nostrPubkey)) return;
            const rl = L();
            if (!this._nearbyLimiter) this._nearbyLimiter = rl.createNearbyLimiter();
            const now = Date.now();
            this._nearbyCards = (this._nearbyCards || []).filter((c) => now - c.at < 300000);
            if (this._nearbyCards.length >= 3) return;
            if (!this._nearbyLimiter.accept(msg.senderPeerID, link, now)) return;
            const card = { id: Math.random().toString(36).slice(2), at: now, nick: (peer && peer.nickname) || msg.senderPeerID, link, kind: r.kind };
            this._nearbyCards.push(card);
            setTimeout(() => this._nearbyDrop(card.id), 300000);
            this._nearbyRenderCards();
        },

        _nearbyDrop(id) {
            this._nearbyCards = (this._nearbyCards || []).filter((c) => c.id !== id);
            this._nearbyRenderCards();
        },

        _nearbyClear() {
            this._nearbyCards = [];
            if (this._nearbyLimiter) this._nearbyLimiter.clear();
            this._nearbyRenderCards();
        },

        _nearbyRenderCards() {
            let box = document.getElementById('nearbyInbox');
            const cards = this._nearbyCards || [];
            if (!box) {
                if (!cards.length) return;
                box = document.createElement('div');
                box.id = 'nearbyInbox';
                box.className = 'nearby-inbox';
                box.setAttribute('role', 'region');
                box.setAttribute('aria-live', 'polite');
                document.body.appendChild(box);
            }
            box.textContent = '';
            cards.forEach((c) => {
                const el = document.createElement('div');
                el.className = 'nearby-card';
                el.dataset.cardId = c.id;
                const t = document.createElement('div');
                t.className = 'nearby-card-title';
                t.textContent = this._shT(KIND_TEXT[c.kind]).replace('{nick}', c.nick);
                const row = document.createElement('div');
                row.className = 'share-preview-actions';
                const open = this._shareButton(c.kind === 'groupInvite' ? 'Ask to join' : 'Open', 'icon-btn primary');
                open.dataset.nearbyCard = 'open';
                open.addEventListener('click', () => {
                    const link = c.link;
                    this._nearbyDrop(c.id);
                    this.shareInbound(link, 'nearby', this._shT(KIND_TEXT[c.kind]).replace('{nick}', c.nick));
                });
                const dismiss = this._shareButton('Dismiss', 'icon-btn');
                dismiss.dataset.nearbyCard = 'dismiss';
                dismiss.addEventListener('click', () => this._nearbyDrop(c.id));
                row.append(open, dismiss);
                el.append(t, row);
                box.appendChild(el);
            });
            box.classList.toggle('nm-hidden', !cards.length);
        },
    });
})();
