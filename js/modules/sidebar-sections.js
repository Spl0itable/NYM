// sidebar-sections.js - Long-press reordering of the sidebar sections

Object.assign(NYM.prototype, {

    _sidebarSectionIds: ['channels', 'pms', 'nyms'],

    _getSidebarSectionEls() {
        const sidebar = document.getElementById('sidebar');
        if (!sidebar) return [];
        return Array.from(sidebar.querySelectorAll(':scope > [data-section]'));
    },

    _getSidebarSectionOrder() {
        const els = this._getSidebarSectionEls();
        if (els.length) return els.map(el => el.dataset.section);
        try {
            const stored = JSON.parse(localStorage.getItem('nym_sidebar_section_order') || 'null');
            if (Array.isArray(stored)) return stored;
        } catch (_) { }
        return this._sidebarSectionIds.slice();
    },

    _applySidebarSectionOrder(order) {
        const sidebar = document.getElementById('sidebar');
        if (!sidebar || !Array.isArray(order)) return;
        const byId = new Map(this._getSidebarSectionEls().map(el => [el.dataset.section, el]));
        // Keep any sections missing from the saved order at their tail position.
        const finalOrder = order.filter(id => byId.has(id));
        for (const id of this._sidebarSectionIds) {
            if (!finalOrder.includes(id) && byId.has(id)) finalOrder.push(id);
        }
        for (const id of finalOrder) sidebar.appendChild(byId.get(id));
        this._refreshSidebarReorderButtons();
    },

    _saveSidebarSectionOrder() {
        const order = this._getSidebarSectionOrder();
        localStorage.setItem('nym_sidebar_section_order', JSON.stringify(order));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    _moveSidebarSection(sectionEl, direction) {
        const sidebar = document.getElementById('sidebar');
        if (!sidebar || !sectionEl) return;
        if (direction === 'up') {
            const prev = sectionEl.previousElementSibling;
            if (prev && prev.dataset.section) sidebar.insertBefore(sectionEl, prev);
        } else {
            const next = sectionEl.nextElementSibling;
            if (next && next.dataset.section) sidebar.insertBefore(next, sectionEl);
        }
        this._refreshSidebarReorderButtons();
        this._saveSidebarSectionOrder();
    },

    // Disable the up arrow on the first section and the down arrow on the last.
    _refreshSidebarReorderButtons() {
        const els = this._getSidebarSectionEls();
        els.forEach((el, idx) => {
            const up = el.querySelector('.section-reorder-btn[data-section-move="up"]');
            const down = el.querySelector('.section-reorder-btn[data-section-move="down"]');
            if (up) up.disabled = idx === 0;
            if (down) down.disabled = idx === els.length - 1;
        });
    },

    _setSidebarReorderMode(on) {
        document.body.classList.toggle('sidebar-reorder-mode', !!on);
        if (on) this._refreshSidebarReorderButtons();
    },

    _getCollapsedSidebarSections() {
        try {
            const stored = JSON.parse(localStorage.getItem('nym_sidebar_section_collapsed') || '[]');
            return Array.isArray(stored) ? stored : [];
        } catch (_) { return []; }
    },

    _saveCollapsedSidebarSections(list) {
        localStorage.setItem('nym_sidebar_section_collapsed', JSON.stringify(list));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    _applySidebarSectionCollapse() {
        const collapsed = new Set(this._getCollapsedSidebarSections());
        for (const el of this._getSidebarSectionEls()) {
            el.classList.toggle('section-collapsed', collapsed.has(el.dataset.section));
            const btn = el.querySelector('.collapse-icon');
            if (btn) {
                const isCollapsed = collapsed.has(el.dataset.section);
                btn.title = isCollapsed ? 'Expand section' : 'Collapse section';
                btn.setAttribute('aria-label', btn.title);
            }
        }
    },

    toggleSidebarSectionCollapse(sectionId) {
        if (!sectionId) return;
        const list = this._getCollapsedSidebarSections();
        const idx = list.indexOf(sectionId);
        if (idx >= 0) list.splice(idx, 1); else list.push(sectionId);
        this._saveCollapsedSidebarSections(list);
        this._applySidebarSectionCollapse();
    },

    setupSidebarSectionCollapse() {
        this._applySidebarSectionCollapse();
    },

    setupSidebarSectionReorder() {
        const els = this._getSidebarSectionEls();
        if (!els.length) return;

        // Restore a previously saved order
        try {
            const stored = JSON.parse(localStorage.getItem('nym_sidebar_section_order') || 'null');
            if (Array.isArray(stored)) this._applySidebarSectionOrder(stored);
        } catch (_) { }
        this._refreshSidebarReorderButtons();

        let pressTimer = null;
        let startX = 0, startY = 0;
        const MOVE_THRESHOLD = 10;

        const cancelPress = () => {
            if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; }
        };

        for (const sectionEl of els) {
            const title = sectionEl.querySelector('.nav-title');
            if (!title) continue;

            const startPress = (x, y) => {
                startX = x; startY = y;
                cancelPress();
                pressTimer = setTimeout(() => {
                    pressTimer = null;
                    this._setSidebarReorderMode(!document.body.classList.contains('sidebar-reorder-mode'));
                }, 500);
            };

            title.addEventListener('mousedown', (e) => {
                if (e.button !== 0 || e.target.closest('.section-reorder-arrows')) return;
                startPress(e.clientX, e.clientY);
            });
            title.addEventListener('touchstart', (e) => {
                if (e.target.closest('.section-reorder-arrows')) return;
                const t = e.touches && e.touches[0];
                if (t) startPress(t.clientX, t.clientY);
            }, { passive: true });

            title.addEventListener('mousemove', (e) => {
                if (!pressTimer) return;
                if (Math.abs(e.clientX - startX) > MOVE_THRESHOLD ||
                    Math.abs(e.clientY - startY) > MOVE_THRESHOLD) cancelPress();
            });
            title.addEventListener('touchmove', (e) => {
                if (!pressTimer) return;
                const t = e.touches && e.touches[0];
                if (t && (Math.abs(t.clientX - startX) > MOVE_THRESHOLD ||
                    Math.abs(t.clientY - startY) > MOVE_THRESHOLD)) cancelPress();
            }, { passive: true });

            title.addEventListener('mouseup', cancelPress);
            title.addEventListener('mouseleave', cancelPress);
            title.addEventListener('touchend', cancelPress);
            title.addEventListener('touchcancel', cancelPress);

            const arrows = title.querySelector('.section-reorder-arrows');
            if (arrows) {
                arrows.addEventListener('click', (e) => {
                    const moveBtn = e.target.closest('.section-reorder-btn');
                    if (!moveBtn || moveBtn.disabled) return;
                    e.stopPropagation();
                    this._moveSidebarSection(sectionEl, moveBtn.dataset.sectionMove);
                });
            }
        }
    },

});
