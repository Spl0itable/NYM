(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    function str(v) {
        return typeof v === 'string' ? v : '';
    }

    function normView(view) {
        const v = view && typeof view === 'object' ? view : {};
        const keys = Array.isArray(v.keys) ? v.keys.filter((k) => typeof k === 'string' && k) : [];
        const t = v.thread && typeof v.thread === 'object' ? v.thread : null;
        const thread = t && str(t.key) && str(t.root) ? { key: t.key, root: t.root } : null;
        return { focused: v.focused === true, keys, thread };
    }

    function normEvent(ev) {
        const e = ev && typeof ev === 'object' ? ev : {};
        return { key: str(e.key), root: str(e.root), notify: e.notify === true };
    }

    function threadOpen(view, ev) {
        const v = normView(view);
        const e = normEvent(ev);
        if (!e.key || !e.root || !v.thread) return false;
        return v.thread.key === e.key && v.thread.root === e.root;
    }

    function onScreen(view, ev) {
        const v = normView(view);
        const e = normEvent(ev);
        if (!e.key) return false;
        if (e.root) return threadOpen(v, e);
        return v.keys.includes(e.key);
    }

    function sees(view, ev) {
        return normView(view).focused && onScreen(view, ev);
    }

    function outcome(view, ev) {
        const v = normView(view);
        const e = normEvent(ev);
        const seen = sees(v, e);
        const alert = e.notify && !seen;
        return { badge: alert, sound: alert, read: seen, toast: alert && v.focused };
    }

    function addressed(input) {
        const i = input && typeof input === 'object' ? input : {};
        const kind = i.kind === 'pm' || i.kind === 'group' ? i.kind : 'channel';
        const mention = i.mention === true;
        if (i.thread === true) {
            if (i.threadMentionsOnly === true) return mention;
            if (mention || i.ownRoot === true || i.ownReply === true) return true;
            return kind === 'pm';
        }
        if (kind === 'channel') return mention;
        if (kind === 'group') return mention || i.groupMentionsOnly !== true;
        return true;
    }

    function num(v) {
        return typeof v === 'number' && isFinite(v) ? v : 0;
    }

    function readTs(ts, receivedAt, live) {
        const t = num(ts);
        const r = num(receivedAt);
        return live === true && r > t ? r : t;
    }

    function shownSeen(view, ev, tsMs, key, atSec) {
        const v = normView(view);
        const e = normEvent(ev);
        const k = str(key);
        const at = num(atSec);
        if (!v.focused || !k || e.key !== k || e.root || !(at > 0)) return false;
        return Math.floor(num(tsMs) / 1000) <= at;
    }
    const PUBKEY_RE = /^[0-9a-f]{64}$/i;
    const NEAR_MS = 1000;

    function alertId(input) {
        const i = input && typeof input === 'object' ? input : {};
        const x = str(i.x);
        if (x) return { eventId: x, stable: true };
        const id = str(i.id);
        return { eventId: id, stable: !!id && i.stable === true };
    }

    function reactionId(wrapId, messageId) {
        const w = str(wrapId);
        const m = str(messageId);
        if (!w) return { eventId: '', stable: false };
        return m ? { eventId: w + ':' + m, stable: true } : { eventId: w, stable: false };
    }

    function sec(v) {
        const n = Math.floor(num(v));
        return n > 0 ? n : 0;
    }

    function knockId(linkId, sender, createdAt) {
        return 'call-link-' + str(linkId) + '-' + str(sender) + '-' + sec(createdAt);
    }

    function joinRequestId(groupId, joiner, ts) {
        return 'join-req-' + str(groupId) + '-' + str(joiner) + '-' + sec(ts);
    }

    function joinDeclinedId(groupId, createdAt) {
        return 'join-declined-' + str(groupId) + '-' + sec(createdAt);
    }

    function collapseWs(s) {
        return s.replace(/\s+/g, ' ').trim();
    }

    function bodyKey(body) {
        const s = str(body);
        const kept = collapseWs(s.split('\n').filter((l) => !/^\s*>/.test(l)).join(' '));
        return (kept || collapseWs(s)).slice(0, 40);
    }

    function alertScope(type, route, sender) {
        const t = str(type);
        const r = str(route);
        if (t === 'pm') {
            const peer = r || str(sender);
            return peer ? 'pm:' + peer.toLowerCase() : '';
        }
        if (t === 'group') return r ? 'group:' + r : '';
        if (t === 'channel' || t === 'geohash') return r ? 'channel:' + r.toLowerCase() : '';
        if (t === 'mention') return r && !PUBKEY_RE.test(r) ? 'channel:' + r.toLowerCase() : '';
        return '';
    }

    function sameAlert(a, b) {
        const x = a && typeof a === 'object' ? a : {};
        const y = b && typeof b === 'object' ? b : {};
        const xi = str(x.eventId);
        const yi = str(y.eventId);
        if (xi && yi && xi === yi) return true;
        if ((x.exact === true && xi) || (y.exact === true && yi)) return false;
        const xs = str(x.scope);
        const ys = str(y.scope);
        if (xs && ys && xs !== ys) return false;
        const sender = str(x.sender);
        const dt = Math.abs(num(x.ts) - num(y.ts));
        const near = () => {
            if (!sender || sender !== str(y.sender) || dt >= NEAR_MS) return false;
            const k = bodyKey(x.body);
            return !!k && k === bodyKey(y.body);
        };
        if (xi && yi) return !(x.stable === true && y.stable === true) && near();
        return near() || (str(x.title) === str(y.title) && str(x.body) === str(y.body) &&
            sender === str(y.sender) && dt < 60000);
    }

    const PIECE_MAX_BYTES = 255;
    const PIECE_OPEN_BYTES = 252;
    const PIECE_HOLD_MS = 3000;

    function charBytes(ch) {
        const cp = ch.codePointAt(0);
        return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    }

    function utf8Length(text) {
        let n = 0;
        for (const ch of str(text)) n += charBytes(ch);
        return n;
    }

    function pmChunks(content) {
        const s = str(content);
        const out = [];
        let cur = '';
        let bytes = 0;
        for (const ch of s) {
            const b = charBytes(ch);
            if (cur && bytes + b > PIECE_MAX_BYTES) {
                out.push(cur);
                cur = '';
                bytes = 0;
            }
            cur += ch;
            bytes += b;
        }
        if (cur || !out.length) out.push(cur);
        return out;
    }

    function pmOpenPiece(content) {
        const n = utf8Length(content);
        return n >= PIECE_OPEN_BYTES && n <= PIECE_MAX_BYTES;
    }

    function pmPiece(a, b) {
        const x = a && typeof a === 'object' ? a : {};
        const y = b && typeof b === 'object' ? b : {};
        if (!str(x.pubkey) || str(x.pubkey) !== str(y.pubkey)) return false;
        if (str(x.nymId) || !str(y.nymId)) return false;
        const piece = str(x.content);
        const whole = str(y.content);
        if (!piece || piece.length >= whole.length) return false;
        if (Math.abs(num(x.createdAt) - num(y.createdAt)) >= 5) return false;
        if (str(x.replyTo) && str(x.replyTo) !== str(y.replyTo)) return false;
        return pmChunks(whole).indexOf(piece) >= 0;
    }

    function samePm(a, b) {
        const x = a && typeof a === 'object' ? a : {};
        const y = b && typeof b === 'object' ? b : {};
        if (str(x.pubkey) !== str(y.pubkey)) return false;
        const xi = str(x.nymId);
        const yi = str(y.nymId);
        if (xi && yi) return xi === yi;
        if (str(x.content) !== str(y.content)) return false;
        if (Math.abs(num(x.createdAt) - num(y.createdAt)) >= 5) return false;
        return !str(x.replyTo) || str(x.replyTo) === str(y.replyTo);
    }

    G.NymNotifyView = Object.freeze({ threadOpen, onScreen, sees, outcome, addressed, readTs, shownSeen, sameAlert, samePm, pmChunks, pmOpenPiece, pmPiece, PIECE_HOLD_MS, alertId, reactionId, knockId, joinRequestId, joinDeclinedId, bodyKey, alertScope });
})();
