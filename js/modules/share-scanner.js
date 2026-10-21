(function () {
    const FRAME_MS = 200;
    const CAMERA_MAX = 720;
    const PHOTO_MAX = 1600;

    async function makeDecoder() {
        if (typeof window.BarcodeDetector === 'function') {
            try {
                const formats = typeof window.BarcodeDetector.getSupportedFormats === 'function' ? await window.BarcodeDetector.getSupportedFormats() : [];
                if (formats.includes('qr_code')) {
                    const det = new window.BarcodeDetector({ formats: ['qr_code'] });
                    return async (canvas) => {
                        const out = await det.detect(canvas);
                        return out && out[0] && typeof out[0].rawValue === 'string' ? out[0].rawValue : null;
                    };
                }
            } catch (_) { }
        }
        await window.loadScriptOnce(window.NYM_CDN.jsqr);
        return async (canvas) => {
            const ctx = canvas.getContext('2d', { willReadFrequently: true });
            const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
            const r = window.jsQR(img.data, img.width, img.height, { inversionAttempts: 'attemptBoth' });
            return r && typeof r.data === 'string' ? r.data : null;
        };
    }

    function fit(w, h, max) {
        const s = Math.min(1, max / Math.max(w, h));
        return [Math.max(1, Math.round(w * s)), Math.max(1, Math.round(h * s))];
    }

    Object.assign(NYM.prototype, {
        openShareScanner() {
            const { modal, body } = this._shareModal('shareScanModal', 'Scan a code');
            body.textContent = '';
            const video = document.createElement('video');
            video.className = 'share-scan-video nm-hidden';
            video.setAttribute('playsinline', '');
            video.muted = true;
            const status = document.createElement('div');
            status.className = 'share-scan-status';
            status.id = 'shareScanStatus';
            status.setAttribute('role', 'status');
            const file = document.createElement('input');
            file.type = 'file';
            file.accept = 'image/*';
            file.className = 'nm-hidden';
            file.id = 'shareScanFile';
            const row = document.createElement('div');
            row.className = 'share-actions';
            const photo = this._shareButton('Scan from photo');
            photo.dataset.scanAction = 'photo';
            photo.addEventListener('click', () => file.click());
            row.appendChild(photo);
            if (typeof this.shareNfcAvailable === 'function' && this.shareNfcAvailable()) {
                const nfc = this._shareButton('Read NFC');
                nfc.dataset.scanAction = 'nfc';
                nfc.addEventListener('click', () => this.shareNfcRead(status));
                row.appendChild(nfc);
            }
            file.addEventListener('change', () => {
                const f = file.files && file.files[0];
                file.value = '';
                if (f) this._scanPhoto(f, status);
            });
            body.append(video, status, row, file);
            this._scanWatch(modal);
            modal.classList.add('active');
            this._scanStartCamera(video, status);
        },

        _scanWatch(modal) {
            if (this._scanObserver) return;
            this._scanObserver = new MutationObserver(() => {
                if (!modal.classList.contains('active')) {
                    this._scanStop();
                    if (typeof this.shareNfcStop === 'function') this.shareNfcStop();
                }
            });
            this._scanObserver.observe(modal, { attributes: true, attributeFilter: ['class'] });
            document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') this._scanStop(); });
            window.addEventListener('pagehide', () => this._scanStop());
        },

        _scanStop() {
            if (this._scanTimer) { clearTimeout(this._scanTimer); this._scanTimer = null; }
            const st = this._scanStream;
            this._scanStream = null;
            if (st) st.getTracks().forEach((t) => { try { t.stop(); } catch (_) { } });
            const v = document.querySelector('#shareScanModal video');
            if (v) { try { v.pause(); } catch (_) { } v.srcObject = null; v.classList.add('nm-hidden'); }
        },

        async _scanStartCamera(video, status) {
            const off = () => { status.textContent = this._shT('Camera access is off. Scan from a photo instead.'); };
            if (!navigator.mediaDevices || typeof navigator.mediaDevices.getUserMedia !== 'function') { off(); return; }
            let decode;
            try { decode = await makeDecoder(); } catch (_) { off(); return; }
            let stream;
            try {
                stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
            } catch (_) { off(); return; }
            const modal = document.getElementById('shareScanModal');
            if (!modal || !modal.classList.contains('active') || document.visibilityState === 'hidden') {
                stream.getTracks().forEach((t) => t.stop());
                return;
            }
            this._scanStream = stream;
            video.srcObject = stream;
            video.classList.remove('nm-hidden');
            try { await video.play(); } catch (_) { }
            const canvas = document.createElement('canvas');
            const tick = async () => {
                if (this._scanStream !== stream) return;
                const vw = video.videoWidth, vh = video.videoHeight;
                if (vw && vh) {
                    const [w, h] = fit(vw, vh, CAMERA_MAX);
                    canvas.width = w;
                    canvas.height = h;
                    canvas.getContext('2d', { willReadFrequently: true }).drawImage(video, 0, 0, w, h);
                    let text = null;
                    try { text = await decode(canvas); } catch (_) { text = null; }
                    if (this._scanStream !== stream) return;
                    if (text) {
                        this._scanStop();
                        window.closeModal('shareScanModal');
                        this.shareInbound(text, 'scan');
                        return;
                    }
                }
                this._scanTimer = setTimeout(tick, FRAME_MS);
            };
            this._scanTimer = setTimeout(tick, FRAME_MS);
        },

        async _scanPhoto(fileObj, status) {
            let text = null;
            try {
                const decode = await makeDecoder();
                const bmp = await createImageBitmap(fileObj);
                const [w, h] = fit(bmp.width, bmp.height, PHOTO_MAX);
                const canvas = document.createElement('canvas');
                canvas.width = w;
                canvas.height = h;
                canvas.getContext('2d', { willReadFrequently: true }).drawImage(bmp, 0, 0, w, h);
                if (typeof bmp.close === 'function') bmp.close();
                text = await decode(canvas);
            } catch (_) { text = null; }
            if (!text) {
                status.textContent = this._shT('No code found in this photo.');
                return;
            }
            this._scanStop();
            window.closeModal('shareScanModal');
            this.shareInbound(text, 'photo');
        },
    });
})();
