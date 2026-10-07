(function () {
    const SPECS = Object.freeze({
        pmList: Object.freeze({ rows: '.pm-item', empty: 'No private messages yet', action: 'Start one', run: 'openNewPMModal' }),
        userListContent: Object.freeze({ rows: '.user-item', empty: 'No one else is here right now', term: 'userSearchTerm' }),
    });

    Object.assign(NYM.prototype, {
        _leText(s) {
            return typeof this.uiText === 'function' ? this.uiText(s) : s;
        },

        _leBindAll() {
            for (const id of Object.keys(SPECS)) this._leBind(id);
        },

        _leBind(id) {
            const list = document.getElementById(id);
            if (!list || list._leBound) return;
            list._leBound = true;
            let pending = false;
            const schedule = () => {
                if (pending) return;
                pending = true;
                requestAnimationFrame(() => {
                    pending = false;
                    this._leSync(id);
                });
            };
            if (typeof MutationObserver !== 'undefined') {
                new MutationObserver((records) => {
                    for (const r of records) {
                        if (r.type === 'childList' && r.target === list) { schedule(); return; }
                        if (r.type === 'attributes' && r.target.parentElement === list) { schedule(); return; }
                    }
                }).observe(list, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style'] });
            }
            this._leSync(id);
        },

        _leState(id) {
            const list = document.getElementById(id);
            const spec = SPECS[id];
            if (!list || !spec) return null;
            if (list.querySelector(':scope > .sidebar-skeleton')) return null;
            const rows = Array.from(list.querySelectorAll(spec.rows));
            if (!rows.length) return spec.term && String(this[spec.term] || '').trim() ? 'nomatch' : 'empty';
            const shown = rows.filter((r) => !r.classList.contains('search-hidden') && r.style.display !== 'none');
            return shown.length ? null : 'nomatch';
        },

        _leSync(id) {
            const list = document.getElementById(id);
            const spec = SPECS[id];
            if (!list || !spec) return;
            const want = this._leState(id);
            let note = list.querySelector(':scope > .list-empty');
            if (!want) {
                if (note) note.remove();
                return;
            }
            if (note && note.dataset.state === want) return;
            if (note) note.remove();
            note = document.createElement('div');
            note.className = 'list-empty';
            note.dataset.state = want;
            const text = document.createElement('span');
            text.className = 'list-empty-text';
            text.textContent = this._leText(want === 'empty' ? spec.empty : 'No matches');
            note.appendChild(text);
            if (want === 'empty' && spec.action && typeof this[spec.run] === 'function') {
                const btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'list-empty-action';
                btn.textContent = this._leText(spec.action);
                btn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    this[spec.run]();
                });
                note.appendChild(btn);
            }
            list.appendChild(note);
        },
    });
})();
