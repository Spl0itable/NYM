(function () {
    'use strict';
    const G = typeof window !== 'undefined' ? window : globalThis;

    const MAX = 120;

    function fill(t, s, vars) {
        const out = typeof t === 'function' ? t(s, vars) : s;
        if (!vars) return out;
        return String(out).replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m));
    }

    function stripMarkdown(input) {
        if (typeof input !== 'string' || !input) return '';
        let s = input.replace(/\r\n?/g, '\n');
        s = s.replace(/```[^\n`]*\n?([\s\S]*?)```/g, (m, body) => body);
        const lines = s.split('\n');
        const kept = lines.filter((l) => !/^\s*>/.test(l));
        const use = kept.some((l) => l.trim()) ? kept : lines.map((l) => l.replace(/^\s*>+\s?/, ''));
        s = use.map((l) => l
            .replace(/^\s{0,3}#{1,6}\s+/, '')
            .replace(/^-#\s+/, '')
            .replace(/^\s*(?:[-*+]|\d{1,3}[.)])\s+/, '')).join('\n');
        s = s.replace(/!\[([^\]]*)\]\([^)\s]*\)/g, '$1');
        s = s.replace(/\[([^\]]+)\]\((?:[^)\s]+)\)/g, '$1');
        s = s.replace(/`([^`\n]+)`/g, '$1');
        s = s.replace(/(\*\*|__|~~)(?=\S)([\s\S]*?\S)\1/g, '$2');
        s = s.replace(/(^|[^\w*])\*(?=\S)([^*\n]*?\S)\*(?![\w*])/g, '$1$2');
        s = s.replace(/(^|[^\w_])_(?=\S)([^_\n]*?\S)_(?![\w_])/g, '$1$2');
        s = s.replace(/\s+/g, ' ').trim();
        if (s.length > MAX) s = s.slice(0, MAX - 1).trimEnd() + '…';
        return s;
    }

    function rowPreview(o, t) {
        const x = o || {};
        if (x.hide) return '';
        if (x.locked) return String(x.redacted || '');
        const body = stripMarkdown(x.text || '');
        if (!body) return '';
        const who = x.self ? fill(t, 'You') : String(x.author || '');
        if (x.kind === 'pm' && !x.self) return body;
        return who ? who + ': ' + body : body;
    }

    function relativeTime(nowMs, tsMs, t) {
        const now = Number(nowMs) || 0;
        const ts = Number(tsMs) || 0;
        if (!ts) return '';
        const sec = Math.max(0, Math.floor((now - ts) / 1000));
        if (sec < 60) return fill(t, 'now');
        const min = Math.floor(sec / 60);
        if (min < 60) return fill(t, '{n}m', { n: min });
        const h = Math.floor(min / 60);
        if (h < 24) return fill(t, '{n}h', { n: h });
        const d = Math.floor(h / 24);
        if (d < 7) return fill(t, '{n}d', { n: d });
        if (d < 365) return fill(t, '{n}w', { n: Math.floor(d / 7) });
        return fill(t, '{n}y', { n: Math.floor(d / 365) });
    }

    const DOCK_MIN = 1280;
    const SETTINGS_TWO_PANE_MIN = 1025;
    const DOCK_WIDTH = 320;
    const READ_CH = 85;
    const CH_EM = 0.55;

    function readWidthPx(fontSize) {
        return Math.round(READ_CH * CH_EM * (Number(fontSize) || 15));
    }

    const CHAT_HEADER_H_COMPACT = 60;
    const CHAT_HEADER_H_WIDE = 64;

    function chatHeaderHeight(width) {
        return (Number(width) || 0) <= 1024 ? CHAT_HEADER_H_COMPACT : CHAT_HEADER_H_WIDE;
    }

    function infoPanelMode(width) {
        return (Number(width) || 0) >= DOCK_MIN ? 'docked' : 'overlay';
    }

    function settingsMode(width) {
        const w = Number(width) || 0;
        return w >= SETTINGS_TWO_PANE_MIN ? 'two-pane' : 'page';
    }

    function isPubkey(v) { return typeof v === 'string' && /^[0-9a-fA-F]{64}$/.test(v); }

    function notifGroupKey(type, route, sender) {
        const t = String(type || '');
        const r = String(route || '');
        const s = String(sender || '');
        if (t === 'group') return r ? 'group:' + r : 'other';
        if (t === 'channel' || t === 'geohash') return r ? 'channel:' + r.toLowerCase() : 'other';
        if (t === 'call') {
            if (isPubkey(r)) return 'pm:' + r.toLowerCase();
            if (r) return 'group:' + r;
            return s ? 'pm:' + s.toLowerCase() : 'other';
        }
        const peer = s || (isPubkey(r) ? r : '');
        return peer ? 'pm:' + peer.toLowerCase() : 'other';
    }

    function groupNotifications(keys) {
        const order = [];
        const at = {};
        (keys || []).forEach((k, i) => {
            if (!(k in at)) { at[k] = order.length; order.push({ key: k, items: [] }); }
            order[at[k]].items.push(i);
        });
        return order;
    }

    function formatToolbarVisible(o) {
        const x = o || {};
        return !!x.draft && (!!x.focused || !!x.overlay);
    }

    const ROLE_SECTIONS = Object.freeze(['owner', 'admins', 'mods', 'members']);

    function memberSections(roles) {
        const out = ROLE_SECTIONS.map((key) => ({ key, items: [] }));
        (roles || []).forEach((r, i) => {
            const k = r === 'owner' ? 0 : r === 'admin' ? 1 : r === 'mod' ? 2 : 3;
            out[k].items.push(i);
        });
        return out.filter((s) => s.items.length);
    }

    function presenceClass(status) {
        return status === 'online' || status === 'away' ? status : (status === 'hidden' ? '' : 'offline');
    }

    const SIDEBAR_MIN = 240;
    const SIDEBAR_MAX = 400;
    const SIDEBAR_DEFAULT = 290;

    function clampSidebarWidth(w) {
        const n = Number(w);
        if (!isFinite(n) || (typeof w === 'string' && !w.trim())) return SIDEBAR_DEFAULT;
        return Math.round(Math.min(SIDEBAR_MAX, Math.max(SIDEBAR_MIN, n)));
    }

    const COLUMN_MIN = 280;
    const COLUMN_MAX = 560;
    const COLUMN_DEFAULT = 360;
    const ADD_RAIL = 56;

    function clampColumnWidth(w) {
        const n = Number(w);
        if (!isFinite(n) || (typeof w === 'string' && !w.trim())) return COLUMN_DEFAULT;
        return Math.round(Math.min(COLUMN_MAX, Math.max(COLUMN_MIN, n)));
    }

    G.NymLayoutModel = {
        MAX, DOCK_MIN, SETTINGS_TWO_PANE_MIN, DOCK_WIDTH, READ_CH, CH_EM,
        stripMarkdown, rowPreview, relativeTime, infoPanelMode, settingsMode, chatHeaderHeight, CHAT_HEADER_H_COMPACT, CHAT_HEADER_H_WIDE, readWidthPx, notifGroupKey, groupNotifications, formatToolbarVisible, ROLE_SECTIONS, memberSections, presenceClass, SIDEBAR_MIN, SIDEBAR_MAX, SIDEBAR_DEFAULT, clampSidebarWidth, COLUMN_MIN, COLUMN_MAX, COLUMN_DEFAULT, ADD_RAIL, clampColumnWidth
    };
})();
