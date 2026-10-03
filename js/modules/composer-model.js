(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const STRINGS = Object.freeze({
        meshOff: 'Not available over mesh',
        meshPhoto: 'Up to 100 KB over mesh',
        pollMesh: "Polls need the internet. They can't be created over the Bluetooth mesh.",
        sendLater: 'Send later',
        sendAnon: 'Send anonymously',
    });

    const ATTACH_ORDER = Object.freeze(['photo', 'file', 'location', 'videoNote', 'poll', 'event']);

    const SHEET_MAX_WIDTH = 768;

    const MAIN_MENU = Object.freeze({
        primary: Object.freeze(['notifications', 'saved', 'calls']),
        secondary: Object.freeze(['flair', 'settings', 'about']),
    });

    function item(id, extra) {
        return Object.assign({ id, enabled: true, reason: '', detail: '', warn: '' }, extra || {});
    }

    function off(reason, detail) {
        return { enabled: false, reason, detail: detail || reason };
    }

    function attachItems(ctx) {
        const c = ctx || {};
        const surface = c.surface || 'channel';
        const mesh = c.route === 'mesh';
        const round = c.round || { state: 'ok', reason: '' };
        const out = [];
        out.push(item('photo', mesh ? { warn: STRINGS.meshPhoto } : null));
        out.push(item('file', mesh ? { warn: STRINGS.meshPhoto } : null));
        if (surface !== 'channel') out.push(item('location'));
        if (round.state === 'off') out.push(item('videoNote', off(mesh ? STRINGS.meshOff : round.reason, round.reason)));
        else out.push(item('videoNote', round.state === 'warn' ? { warn: round.reason } : null));
        if (!(surface === 'dm' && c.bot)) out.push(item('poll', mesh ? off(STRINGS.meshOff, STRINGS.pollMesh) : null));
        if (surface === 'group') out.push(item('event'));
        return out;
    }

    function primaryAction(state) {
        const s = state || {};
        if (s.recording) return 'mic';
        if (s.editing || s.busy) return 'send';
        if ((s.attachments || 0) > 0) return 'send';
        return String(s.text || '').trim() ? 'send' : 'mic';
    }

    function sendMenuItems(ctx) {
        const c = ctx || {};
        const out = [{ id: 'later', label: STRINGS.sendLater }];
        if (c.canAnon) out.push({ id: 'anon', label: STRINGS.sendAnon });
        return out;
    }

    function presentation(width) {
        return width <= SHEET_MAX_WIDTH ? 'sheet' : 'popover';
    }

    function menuStep(count, index, key) {
        if (!count) return -1;
        switch (key) {
            case 'ArrowDown': return index < 0 ? 0 : (index + 1) % count;
            case 'ArrowUp': return index < 0 ? count - 1 : (index - 1 + count) % count;
            case 'Home': return 0;
            case 'End': return count - 1;
            default: return -1;
        }
    }

    function isMenuKey(e) {
        if (!e) return false;
        return e.key === 'ContextMenu' || (e.key === 'F10' && !!e.shiftKey);
    }

    function mainMenuRows() {
        return { grid: [MAIN_MENU.primary.slice(), MAIN_MENU.secondary.slice()] };
    }

    G.NymComposer = {
        STRINGS, ATTACH_ORDER, SHEET_MAX_WIDTH, MAIN_MENU,
        attachItems, primaryAction, sendMenuItems, presentation, menuStep, isMenuKey, mainMenuRows,
    };
})();
