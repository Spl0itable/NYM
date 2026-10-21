(function () {
    const L = () => window.NymShareLinks;
    const READ_MS = 30000;
    const LOCK_TEXT = 'Lock this sticker so it can never be changed? This cannot be undone.';

    Object.assign(NYM.prototype, {
        shareNfcAvailable() {
            return typeof window !== 'undefined' && 'NDEFReader' in window;
        },

        shareNfcStop() {
            const c = this._nfcAbort;
            this._nfcAbort = null;
            if (c) { try { c.abort(); } catch (_) { } }
        },

        _nfcSignal(ms) {
            this.shareNfcStop();
            const c = new AbortController();
            this._nfcAbort = c;
            setTimeout(() => { if (this._nfcAbort === c) this.shareNfcStop(); }, ms);
            return c.signal;
        },

        shareNfcRead(status) {
            if (!this.shareNfcAvailable()) return;
            const signal = this._nfcSignal(READ_MS);
            let reader;
            try { reader = new window.NDEFReader(); } catch (_) { return; }
            reader.onreading = (ev) => {
                const recs = (ev && ev.message && ev.message.records) || [];
                const rec = recs.find((r) => r && (r.recordType === 'url' || r.recordType === 'absolute-url'));
                let text = '';
                if (rec && rec.data) {
                    try { text = new TextDecoder('utf-8', { fatal: true }).decode(rec.data); } catch (_) { text = ''; }
                }
                this.shareNfcStop();
                window.closeModal('shareScanModal');
                this.shareInbound(text, 'nfc');
            };
            reader.onreadingerror = () => { if (status) status.textContent = this._shT(L().STRINGS.notNymchat); };
            reader.scan({ signal }).then(() => {
                if (status) status.textContent = this._shT('Hold an NFC sticker to the back of this phone');
            }).catch(() => { });
        },

        openNfcWrite(tg) {
            if (!this.shareNfcAvailable() || !tg || !tg.codeLink || tg.refusal) return;
            window.closeModal('shareModal');
            const { modal, body } = this._shareModal('shareNfcModal', 'Write to NFC sticker');
            body.textContent = '';
            const note = (text, cls) => { const d = document.createElement('div'); d.className = cls || 'share-note'; d.textContent = this._shT(text); body.appendChild(d); return d; };
            note(L().STRINGS.stickerWarning, 'share-note share-warning');
            if (tg.kind === 'group') note(L().STRINGS.groupWarning, 'share-note share-warning');
            const status = note('', 'share-scan-status');
            status.setAttribute('role', 'status');
            const row = document.createElement('div');
            row.className = 'share-actions';
            const write = this._shareButton('Write to NFC sticker');
            write.dataset.nfcAction = 'write';
            row.appendChild(write);
            body.appendChild(row);
            const link = tg.codeLink;
            write.addEventListener('click', async () => {
                const signal = this._nfcSignal(READ_MS);
                status.textContent = this._shT('Hold an NFC sticker to the back of this phone');
                try {
                    const w = new window.NDEFReader();
                    await w.write({ records: [L().webNfcRecord(link)] }, { overwrite: true, signal });
                    status.textContent = this._shT('Sticker written');
                    this.shareNfcStop();
                    this._nfcOfferLock(row, status);
                } catch (_) {
                    status.textContent = '';
                }
            });
            this._nfcWatch(modal);
            modal.classList.add('active');
        },

        _nfcOfferLock(row, status) {
            row.textContent = '';
            const proto = window.NDEFReader && window.NDEFReader.prototype;
            if (!proto || typeof proto.makeReadOnly !== 'function') return;
            const ask = this._shareButton('Lock sticker');
            ask.dataset.nfcAction = 'lock';
            ask.addEventListener('click', () => {
                row.textContent = '';
                status.textContent = this._shT(LOCK_TEXT);
                const confirm = this._shareButton('Lock sticker');
                confirm.dataset.nfcAction = 'lockConfirm';
                confirm.addEventListener('click', async () => {
                    confirm.disabled = true;
                    const signal = this._nfcSignal(READ_MS);
                    try {
                        await new window.NDEFReader().makeReadOnly({ signal });
                        status.textContent = this._shT('Sticker locked');
                    } catch (_) { }
                    this.shareNfcStop();
                });
                row.appendChild(confirm);
            });
            row.appendChild(ask);
        },

        _nfcWatch(modal) {
            if (modal._nfcObs) return;
            modal._nfcObs = new MutationObserver(() => { if (!modal.classList.contains('active')) this.shareNfcStop(); });
            modal._nfcObs.observe(modal, { attributes: true, attributeFilter: ['class'] });
        },
    });
})();
