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
    };
})();
