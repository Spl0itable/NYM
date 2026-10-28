(function () {
    const L = () => window.NymShareLinks;
    const Q = () => window.NymShareQr;

    Object.assign(NYM.prototype, {
        _shareAppChoices() {
            return window.NymShareUi.appLinkChoices('web', L().APP_LINKS);
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
                const label = document.createElement('span');
                label.textContent = sh.textContent;
                sh.textContent = '';
                sh.insertAdjacentHTML('afterbegin', window.NymShareUi.svg('shareNodes', 20));
                sh.appendChild(label);
                sh.dataset.appAction = 'share';
                sh.addEventListener('click', () => { navigator.share({ title: 'Nymchat', url: current.url }).catch(() => { }); });
                actions.appendChild(sh);
            }
            body.append(card, linkText, chips, actions);
            modal.classList.add('active');
            show(current);
        },
    });
})();
