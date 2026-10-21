(function () {
    const L = () => window.NymShareLinks;
    const Q = () => window.NymShareQr;

    const REFUSALS = {
        disabled: 'Invite links are disabled for this group.',
        not_allowed: 'Only members who can add people can share this group.',
        full: 'This group is full (100 members).',
    };
    const RESET_HINT = 'Reset the invite link in group settings to stop old codes and stickers.';
    const PROFILE_NOTE = 'Anyone who scans this code can open this profile.';
    const ACTIONS = [
        { id: 'share', order: 10, label: 'Share...' },
        { id: 'nearby', order: 20, label: 'Share nearby' },
        { id: 'nfc', order: 40, label: 'Write to NFC sticker' },
        { id: 'save', order: 50, label: 'Save QR image' },
        { id: 'scan', order: 60, label: 'Scan a code' },
        { id: 'app', order: 70, label: 'Share Nymchat app' },
    ];
    const ICONS = {
        share: '<path d="M8 2v8M5 5l3-3 3 3"/><path d="M3 9v4h10V9"/>',
        nearby: '<circle cx="8" cy="8" r="1.5"/><path d="M5 5a4.2 4.2 0 0 0 0 6M11 5a4.2 4.2 0 0 1 0 6M3 3a7 7 0 0 0 0 10M13 3a7 7 0 0 1 0 10"/>',
        nfc: '<rect x="3" y="2" width="10" height="12" rx="2"/><path d="M6 6c1 1.2 1 2.8 0 4M8.5 5c1.6 1.8 1.6 4.2 0 6"/>',
        save: '<path d="M8 2v8M5 7l3 3 3-3"/><path d="M3 13h10"/>',
        scan: '<path d="M2 5V2h3M11 2h3v3M14 11v3h-3M5 14H2v-3"/><path d="M4 8h8"/>',
        app: '<rect x="4" y="1.5" width="8" height="13" rx="1.5"/><path d="M7 12.5h2"/>',
    };
    const svg = (p) => `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${p}</svg>`;
    const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

    Object.assign(NYM.prototype, {
        _shT(s) {
            return typeof this.uiText === 'function' ? (this.uiText(s) || s) : s;
        },

        _shareUnverifiedMeshKey(pubkey) {
            const m = this._mesh;
            if (!m || !m.peers || (this.users && this.users.has(pubkey))) return false;
            for (const p of m.peers.values()) {
                if (p && p.nostrPubkey === pubkey && !p.nostrLinkVerified) return true;
            }
            return false;
        },

        _shareProfileAllowed(pubkey) {
            if (typeof pubkey !== 'string' || !/^[0-9a-f]{64}$/.test(pubkey)) return false;
            if (pubkey === this.pubkey) return true;
            if (typeof this.isVerifiedBot === 'function' && this.isVerifiedBot(pubkey)) return false;
            if (typeof this._ownOtherKey === 'function' && this._ownOtherKey(pubkey)) return false;
            if (typeof this._botAnonKeySet === 'function' && this._botAnonKeySet().has(pubkey)) return false;
            if (typeof this._getAllSelfEphemeralPubkeys === 'function' && (this._getAllSelfEphemeralPubkeys() || []).includes(pubkey)) return false;
            if (this._shareUnverifiedMeshKey(pubkey)) return false;
            return true;
        },

        _shareTargetChannel(channel) {
            const ch = String(channel || this.currentChannel || 'nymchat');
            const geo = typeof this.isValidGeohash === 'function' && this.isValidGeohash(ch);
            return {
                kind: 'channel', title: 'Share channel', subtitle: '#' + ch, detail: geo ? 'Location channel' : '',
                link: window.location.origin + window.location.pathname + '#' + ch,
                codeLink: L().channelCodeLink(ch), channel: ch,
            };
        },

        _shareTargetProfile(pubkey) {
            if (!this._shareProfileAllowed(pubkey)) return null;
            const own = pubkey === this.pubkey;
            const suffix = typeof this.getPubkeySuffix === 'function' ? this.getPubkeySuffix(pubkey) : '';
            let name = own ? `${String(this.nym || '').replace(/#[0-9a-f]{4}$/i, '')}#${suffix}` : '';
            if (!own) {
                const known = this.users && this.users.has(pubkey) && typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(pubkey) : '';
                name = known || L().shortNpub(pubkey);
            }
            const link = L().profileLink(pubkey);
            return { kind: 'profile', title: 'Share profile', subtitle: name, link, codeLink: link, note: PROFILE_NOTE, pubkey, isOwnProfile: own };
        },

        _shareTargetGroup(groupId) {
            const g = this.groupConversations && this.groupConversations.get(groupId);
            if (!g) return null;
            const base = { kind: 'group', title: 'Share group', subtitle: g.name || 'Group', groupId };
            const offer = L().groupCodeOffer({
                inviteEnabled: !!g.inviteEnabled,
                canAddMembers: this._canAddMembers(groupId, this.pubkey),
                memberCount: (g.members || []).length,
                maxMembers: this.MAX_GROUP_MEMBERS || 100,
            });
            if (!offer.offered) return Object.assign(base, { refusal: REFUSALS[offer.reason] || REFUSALS.disabled });
            const payload = this._groupInvitePayload(groupId);
            const link = this.buildGroupInviteLink(groupId);
            const code = payload ? L().groupCodeLink(payload) : null;
            if (!link || !code) return Object.assign(base, { refusal: REFUSALS.disabled });
            return Object.assign(base, { link, codeLink: code, note: L().STRINGS.groupWarning, hint: RESET_HINT });
        },

        shareProfile(pubkey) {
            const tg = this._shareTargetProfile(pubkey);
            if (tg) this.openShareSheet(tg);
        },

        async shareGroup(groupId) {
            if (!groupId || !this.groupConversations || !this.groupConversations.has(groupId)) return;
            if (typeof this._gtEnsureSummary === 'function' && this.connected) {
                try { await this._gtEnsureSummary(groupId); } catch (_) { }
            }
            this.openShareSheet(this._shareTargetGroup(groupId));
        },

        groupCtxShareGroup() {
            const groupId = this._groupCtxGroupId;
            if (!groupId) return;
            if (typeof this.closeGroupContextMenu === 'function') this.closeGroupContextMenu();
            this.shareGroup(groupId);
        },

        openShareSheet(target) {
            if (!target) return;
            this._shareTarget = target;
            this._shareRender();
            document.getElementById('shareModal').classList.add('active');
            setTimeout(() => {
                const cl = document.querySelector('#shareModal .modal-close');
                if (cl && document.getElementById('shareModal').classList.contains('active')) cl.focus({ preventScroll: true });
            }, 50);
        },

        _shareSheetOpen() {
            const m = document.getElementById('shareModal');
            return !!(m && m.classList.contains('active') && this._shareTarget);
        },

        _shareSheetGroupChanged() {
            const tg = this._shareTarget;
            if (!tg || tg.kind !== 'group' || !this._shareSheetOpen()) return;
            const next = this._shareTargetGroup(tg.groupId);
            if (!next) { window.closeModal('shareModal'); return; }
            if (next.codeLink === tg.codeLink && next.link === tg.link && next.refusal === tg.refusal && next.subtitle === tg.subtitle) return;
            this._shareTarget = next;
            this._shareRender();
        },

        _shareRender() {
            const tg = this._shareTarget;
            if (!tg) return;
            const q = (id) => document.getElementById(id);
            const refused = !!tg.refusal;
            q('shareTitle').textContent = this._shT(tg.title);
            q('shareRefusal').textContent = refused ? this._shT(tg.refusal) : '';
            q('shareRefusal').classList.toggle('nm-hidden', !refused);
            q('shareQrCard').classList.toggle('nm-hidden', refused);
            q('shareSubtitle').textContent = refused ? '' : (tg.subtitle || '');
            q('shareDetail').textContent = refused || !tg.detail ? '' : this._shT(tg.detail);
            q('shareNote').textContent = refused || !tg.note ? '' : this._shT(tg.note);
            q('shareHint').textContent = refused || !tg.hint ? '' : this._shT(tg.hint);
            q('shareNote').classList.toggle('share-warning', tg.kind === 'group' && !refused);
            q('shareLinkRow').classList.toggle('nm-hidden', refused);
            q('shareUrlInput').value = refused ? '' : (tg.link || '');
            this._shareRenderActions();
            if (!refused) this._shareDrawQr(tg);
        },

        _shareActionAvailable(id, tg) {
            if (!tg || tg.refusal) return false;
            switch (id) {
                case 'share': return typeof navigator.share === 'function';
                case 'nearby': return typeof this.shareNearbyAvailable === 'function' && this.shareNearbyAvailable();
                case 'nfc': return typeof this.shareNfcAvailable === 'function' && this.shareNfcAvailable();
                case 'save': return !!tg.codeLink;
                case 'scan': return typeof this.openShareScanner === 'function';
                case 'app': return tg.kind === 'profile' && !!tg.isOwnProfile && typeof this.openShareApp === 'function';
                default: return false;
            }
        },

        _shareRenderActions() {
            const tg = this._shareTarget;
            const box = document.getElementById('shareActions');
            const list = ACTIONS.filter((a) => this._shareActionAvailable(a.id, tg)).sort((a, b) => a.order - b.order);
            box.innerHTML = list.map((a) => `<button type="button" class="share-action" data-action="shareRunAction" data-share-action="${a.id}">${svg(ICONS[a.id])}<span>${esc(this._shT(a.label))}</span></button>`).join('');
            box.classList.toggle('nm-hidden', !list.length);
        },

        async _shareDrawQr(tg) {
            const canvas = document.getElementById('shareQrCanvas');
            const card = document.getElementById('shareQrCard');
            canvas.dataset.qrText = '';
            canvas.setAttribute('role', 'img');
            canvas.setAttribute('aria-label', this._shT('QR code for {title}').replace('{title}', tg.subtitle || ''));
            const text = tg.codeLink;
            const fail = () => { if (this._shareTarget === tg) card.classList.add('nm-hidden'); };
            if (!text || !L().isCodeSafe(text)) { fail(); return; }
            try { await window.loadScriptOnce(window.NYM_CDN.qrcode); } catch (_) { fail(); return; }
            if (this._shareTarget !== tg) return;
            const r = await Q().draw(canvas, text, { cssWidth: 240, dpr: window.devicePixelRatio || 1, isCurrent: () => this._shareTarget === tg });
            if (this._shareTarget !== tg) return;
            if (!r) { fail(); return; }
            canvas.dataset.qrText = text;
        },

        shareRunAction(id) {
            const tg = this._shareTarget;
            if (!this._shareActionAvailable(id, tg)) return;
            if (id === 'share') {
                navigator.share({ title: 'Nymchat', url: tg.link }).catch(() => { });
            } else if (id === 'nearby') {
                this.openNearbyShare(tg);
            } else if (id === 'nfc') {
                this.openNfcWrite(tg);
            } else if (id === 'save') {
                this._shareSaveQr(tg);
            } else if (id === 'scan') {
                window.closeModal('shareModal');
                this.openShareScanner();
            } else if (id === 'app') {
                window.closeModal('shareModal');
                this.openShareApp();
            }
        },

        _shareModal(id, title) {
            let m = document.getElementById(id);
            if (!m) {
                m = document.createElement('div');
                m.className = 'modal share-aux-modal';
                m.id = id;
                m.setAttribute('role', 'dialog');
                m.setAttribute('aria-modal', 'true');
                m.setAttribute('aria-labelledby', id + 'Title');
                m.innerHTML = `<div class="modal-content share-modal"><button class="modal-close" data-action="closeModal" data-modal-id="${id}" aria-label="Close">✕</button><div class="modal-header" id="${id}Title"></div><div class="modal-body share-body"></div></div>`;
                document.body.appendChild(m);
            }
            m.querySelector('.modal-header').textContent = this._shT(title);
            return { modal: m, body: m.querySelector('.modal-body') };
        },

        _shareButton(label, cls) {
            const b = document.createElement('button');
            b.type = 'button';
            b.className = cls || 'share-action';
            b.textContent = this._shT(label);
            return b;
        },

        shareInbound(raw, source, fromLabel) {
            const r = L().parseShareInput(raw, { extraHosts: L().extraHostsFor(window.location) });
            raw = null;
            const quiet = source === 'nearby' || source === 'deepLink';
            if (r.kind === 'invalid') {
                if (!quiet) this._sharePreview({ kind: 'invalid' });
                return false;
            }
            if (r.kind === 'groupInvite') {
                if (typeof this.handleGroupInviteFromUrl === 'function') this.handleGroupInviteFromUrl(r.token);
                return true;
            }
            this._sharePreview(r, fromLabel);
            return true;
        },

        _sharePreview(r, fromLabel) {
            const { modal, body } = this._shareModal('sharePreviewModal', r.kind === 'profile' ? 'Share profile' : (r.kind === 'channel' ? 'Share channel' : 'Nymchat'));
            body.textContent = '';
            const card = document.createElement('div');
            card.className = 'share-preview-card';
            const line = (text, cls) => { const d = document.createElement('div'); d.className = cls; d.textContent = text; card.appendChild(d); };
            if (fromLabel) line(fromLabel, 'share-preview-from');
            const actions = document.createElement('div');
            actions.className = 'share-preview-actions';
            const close = () => window.closeModal('sharePreviewModal');
            const cancel = this._shareButton(r.kind === 'invalid' || r.kind === 'appLink' ? 'Close' : 'Cancel', 'icon-btn');
            cancel.addEventListener('click', close);
            if (r.kind === 'invalid') {
                line(this._shT(L().STRINGS.notNymchat), 'share-preview-title');
                modal.querySelector('.modal-header').textContent = this._shT(L().STRINGS.notNymchat);
            } else if (r.kind === 'appLink') {
                line(this._shT('This code links to Nymchat downloads.'), 'share-preview-title');
            } else if (r.kind === 'profile') {
                const known = this.users && this.users.has(r.pubkey) && typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(r.pubkey) : '';
                line(known || L().shortNpub(r.pubkey), 'share-preview-title');
                if (known) line(L().shortNpub(r.pubkey), 'share-preview-sub');
                const open = this._shareButton('Open profile', 'icon-btn primary');
                open.dataset.sharePreviewOpen = '1';
                open.addEventListener('click', () => {
                    close();
                    const nymName = known || L().shortNpub(r.pubkey);
                    const ev = { preventDefault() { }, stopPropagation() { }, stopImmediatePropagation() { }, clientX: window.innerWidth / 2, clientY: window.innerHeight / 3, target: document.body, currentTarget: document.body };
                    this.showContextMenu(ev, nymName, r.pubkey, null, null, true);
                });
                actions.appendChild(open);
            } else if (r.kind === 'channel') {
                line('#' + r.channel, 'share-preview-title');
                if (r.geohash) line(this._shT('Location channel'), 'share-preview-sub');
                const open = this._shareButton('Open channel', 'icon-btn primary');
                open.dataset.sharePreviewOpen = '1';
                open.addEventListener('click', () => { close(); this.handleChannelLink(r.channel); });
                actions.appendChild(open);
            }
            actions.appendChild(cancel);
            body.appendChild(card);
            body.appendChild(actions);
            modal.classList.add('active');
            setTimeout(() => { const b = actions.querySelector('button'); if (b) b.focus({ preventScroll: true }); }, 30);
        },

        async _shareSaveQr(tg) {
            try { await window.loadScriptOnce(window.NYM_CDN.qrcode); } catch (_) { return; }
            const blob = await Q().exportBlob(tg.codeLink);
            if (!blob) return;
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `nymchat-${tg.kind}-qr.png`;
            document.body.appendChild(a);
            a.click();
            a.remove();
            setTimeout(() => URL.revokeObjectURL(url), 2000);
        },
    });
    const ESC_ORDER = ['sharePreviewModal', 'shareNfcModal', 'shareNearbyModal', 'shareScanModal', 'shareAppModal', 'shareModal'];
    window.addEventListener('keydown', (e) => {
        if (e.key !== 'Escape' || e.isComposing) return;
        for (const id of ESC_ORDER) {
            const m = document.getElementById(id);
            if (m && m.classList.contains('active')) {
                window.closeModal(id);
                e.preventDefault();
                e.stopPropagation();
                return;
            }
        }
    }, true);
})();
