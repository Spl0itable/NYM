(function () {
    const L = () => window.NymShareLinks;
    const Q = () => window.NymShareQr;

    Object.assign(NYM.prototype, {
        _shareAppChoices() {
            const A = L().APP_LINKS;
            return [
                { id: 'download', label: 'Get Nymchat', url: A.downloadPage },
                { id: 'web', label: 'Web app', url: A.webApp },
                { id: 'ios', label: 'App Store (TestFlight)', url: A.iosTestFlight },
                { id: 'play', label: 'Google Play', url: A.googlePlay },
                { id: 'zapstore', label: 'Zapstore', url: A.zapstore },
            ];
        },

        openShareApp() {
            const { modal, body } = this._shareModal('shareAppModal', 'Share Nymchat app');
            body.textContent = '';
            const choices = this._shareAppChoices();
            const card = document.createElement('div');
            card.className = 'share-qr-card';
            const canvas = document.createElement('canvas');
            canvas.id = 'shareAppQr';
            canvas.setAttribute('role', 'img');
            card.appendChild(canvas);
            const title = document.createElement('div');
            title.className = 'share-subtitle';
            const linkText = document.createElement('div');
            linkText.className = 'share-detail share-app-link';
            linkText.id = 'shareAppLink';
            const chips = document.createElement('div');
            chips.className = 'share-chips';
            chips.setAttribute('role', 'group');
            const actions = document.createElement('div');
            actions.className = 'share-actions';
            let current = choices[0];
            const show = async (c) => {
                current = c;
                title.textContent = this._shT(c.label);
                linkText.textContent = c.url;
                chips.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', b.dataset.appChoice === c.id ? 'true' : 'false'));
                canvas.dataset.qrText = '';
                canvas.setAttribute('aria-label', this._shT('QR code for {title}').replace('{title}', this._shT(c.label)));
                try { await window.loadScriptOnce(window.NYM_CDN.qrcode); } catch (_) { return; }
                if (current !== c) return;
                const r = await Q().draw(canvas, c.url, { cssWidth: 240, dpr: window.devicePixelRatio || 1, isCurrent: () => current === c });
                if (r && current === c) canvas.dataset.qrText = c.url;
            };
            choices.forEach((c) => {
                const b = this._shareButton(c.label, 'share-chip');
                b.dataset.appChoice = c.id;
                b.addEventListener('click', () => show(c));
                chips.appendChild(b);
            });
            if (typeof navigator.share === 'function') {
                const sh = this._shareButton('Share...');
                sh.dataset.appAction = 'share';
                sh.addEventListener('click', () => { navigator.share({ title: 'Nymchat', url: current.url }).catch(() => { }); });
                actions.appendChild(sh);
            }
            body.append(card, title, linkText, chips, actions);
            modal.classList.add('active');
            show(current);
        },
    });
})();
