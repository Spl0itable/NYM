(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const ORDER = Object.freeze(['reply', 'replyPrivately', 'thread', 'copy', 'translate', 'save', 'unsave',
        'keep', 'unkeep', 'zap', 'edit', 'delete', 'editHistory', 'eventDetails', 'report']);

    const FOLLOW_CAP = 100;

    const TONES = Object.freeze({ report: 'report', delete: 'danger' });

    function actionTone(id) {
        return TONES[id] || 'normal';
    }

    function buildMessageActions(f) {
        const x = f || {};
        const tools = !!(x.stored && x.content);
        const out = [];
        if (x.content) out.push('reply');
        if (tools && x.replyPrivately && !x.self) out.push('replyPrivately');
        if (x.threadable && x.id) out.push('thread');
        if (x.content) out.push('copy');
        if (x.content) out.push('translate');
        if (tools) out.push(x.saved ? 'unsave' : 'save');
        if (tools && x.keepOffered) out.push(x.kept ? 'unkeep' : 'keep');
        if (!x.self && x.id && x.author) out.push('zap');
        if (x.self && x.id && x.content) out.push('edit');
        if (x.id && (x.self || x.modDelete)) out.push('delete');
        if (x.edited && x.id) out.push('editHistory');
        if (x.hexId) out.push('eventDetails');
        if (!x.self && x.author) out.push('report');
        return out;
    }

    const HOVER_ACTIONS = Object.freeze(['react', 'reply', 'replyPrivately', 'thread', 'copy', 'translate', 'save', 'keep',
        'zap', 'edit', 'delete', 'editHistory', 'eventDetails', 'report']);
    const HOVER_DEFAULTS = Object.freeze(['react', 'reply', 'thread']);
    const HOVER_SLOTS = 3;
    const HOVER_VARIANTS = Object.freeze({ save: Object.freeze(['save', 'unsave']), keep: Object.freeze(['keep', 'unkeep']) });

    function normalizeHoverActions(v) {
        if (!Array.isArray(v) || v.length !== HOVER_SLOTS) return HOVER_DEFAULTS.slice();
        const out = [];
        for (const id of v) {
            if (typeof id !== 'string' || HOVER_ACTIONS.indexOf(id) < 0 || out.indexOf(id) >= 0) return HOVER_DEFAULTS.slice();
            out.push(id);
        }
        return out;
    }

    function pickHoverAction(slots, index, id) {
        const cur = normalizeHoverActions(slots);
        const i = Number(index);
        if (!Number.isInteger(i) || i < 0 || i >= HOVER_SLOTS || HOVER_ACTIONS.indexOf(id) < 0) return cur;
        const j = cur.indexOf(id);
        if (j >= 0) cur[j] = cur[i];
        cur[i] = id;
        return cur;
    }

    function resolveHoverActions(slots, available) {
        const have = Array.isArray(available) ? available : [];
        const offered = (id) => (HOVER_VARIANTS[id] || [id]).find((c) => have.indexOf(c) >= 0) || null;
        const chosen = normalizeHoverActions(slots);
        const spare = HOVER_DEFAULTS.concat(HOVER_ACTIONS)
            .filter((id, i, all) => all.indexOf(id) === i && chosen.indexOf(id) < 0 && offered(id));
        const out = [];
        for (const id of chosen) {
            const c = offered(id) || (spare.length ? offered(spare.shift()) : null);
            if (c) out.push(c);
        }
        return out;
    }

    function swipeThresholdPx(n) {
        const v = Number(n);
        const t = Number.isFinite(v) ? Math.round(v) : 60;
        return Math.max(30, Math.min(FOLLOW_CAP, t));
    }

    function swipeActionApplies(action, f) {
        const x = f || {};
        switch (action) {
            case 'quote':
            case 'copy':
            case 'translate':
                return !!x.content;
            case 'react':
                return !!x.id;
            case 'zap':
                return !!(x.id && x.author);
            case 'slap':
            case 'hug':
                return !!(x.author && !x.self);
            default:
                return false;
        }
    }

    const IMAGE_URL = /(https?:\/\/[^\s#]+\.(?:png|jpe?g|gif|webp|avif)(?:\?[^\s#]*)?)(?:#\S*)?(?=\s|$)/i;
    const IMAGE_URL_G = new RegExp(IMAGE_URL.source, 'gi');
    const VIDEO_URL_G = /(https?:\/\/[^\s#]+\.(?:mp4|webm|mov|m4v)(?:\?[^\s#]*)?)(?:#\S*)?(?=\s|$)/gi;

    function sheetPreview(content, tr) {
        const t = (s) => (typeof tr === 'function' ? tr(s) : s);
        let text = typeof content === 'string' ? content : '';
        if (G.NymDmPolls && typeof G.NymDmPolls.previewText === 'function') text = G.NymDmPolls.previewText(text);
        const loc = G.NymGroupTools && typeof G.NymGroupTools.previewText === 'function'
            ? G.NymGroupTools.previewText(text) : text;
        if (loc === 'Location' || loc === 'Live location') return { text: t(loc), thumb: null };
        text = loc;
        const unquoted = text.split('\n').filter((l) => !/^\s*>/.test(l)).join('\n').trim();
        if (unquoted) text = unquoted;
        if (G.NymMediaNotes && typeof G.NymMediaNotes.previewText === 'function') {
            text = G.NymMediaNotes.previewText(text, typeof tr === 'function' ? tr : undefined);
        }
        const m = IMAGE_URL.exec(text);
        const thumb = m ? m[1] : null;
        text = text.replace(IMAGE_URL_G, t('Photo'))
            .replace(VIDEO_URL_G, t('Video'))
            .replace(/[ \t]+/g, ' ')
            .replace(/ *\n */g, '\n')
            .trim();
        return { text, thumb };
    }

    G.NymMessageActions = {
        ORDER, FOLLOW_CAP, TONES, actionTone,
        buildMessageActions, swipeThresholdPx, swipeActionApplies, sheetPreview,
        HOVER_ACTIONS, HOVER_DEFAULTS, HOVER_SLOTS, HOVER_VARIANTS,
        normalizeHoverActions, pickHoverAction, resolveHoverActions,
    };
})();
