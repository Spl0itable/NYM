(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const LIMITS = Object.freeze({
        titleMax: 80,
        placeMax: 80,
        noteMax: 280,
        joinRequestsMax: 50,
        joinRequestTtlSec: 604800,
        adminNymsMax: 5,
        adminNymMax: 48,
        summaryDescMax: 150,
        summaryUrlMax: 500,
        summaryContentMax: 2000,
        linkNameMax: 40,
        callLinksMax: 50,
        liveUpdateSec: 60,
    });

    const SLOWMODE_SECONDS = Object.freeze([0, 10, 30, 60, 300, 900, 3600]);
    const SLOWMODE_GRACE_SEC = 2;
    const LIVE_DURATIONS_SEC = Object.freeze([900, 3600, 28800]);
    const REMINDER_OFFSETS_MIN = Object.freeze([0, 10, 60, 1440]);
    const CALL_LINK_EXPIRY_SEC = Object.freeze([3600, 86400, 604800, 0]);
    const RSVP_STATUSES = Object.freeze(['going', 'maybe', 'no']);
    const SUMMARY_KIND = 27312;
    const TYPES = Object.freeze({
        rsvp: 'group-rsvp',
        joinPending: 'group-join-pending',
        joinWaiting: 'group-join-waiting',
        joinDeclined: 'group-join-declined',
        joinResolved: 'group-join-resolved',
    });
    const CALL_SIGNALS = Object.freeze({
        join: 'link-join',
        refused: 'link-refused',
        memberAdd: 'member-add',
    });

    const STRINGS = Object.freeze({
        broadcastDenied: 'Only the group owner, admins and moderators can use @here and @everyone.',
        slowmodeWait: 'Slowmode is on. You can send again in {time}.',
        groupsNeedNet: "Encrypted groups don't travel over the Bluetooth mesh. Connect to the internet to use this.",
        callNeedsNet: "Call links need an internet connection. Calls don't run over the Bluetooth mesh.",
        noPublicLocation: "Location can't be shared in public channels.",
        locationNeedsNet: "You're offline. Location needs the internet or this person in Bluetooth range.",
        refusedRevoked: 'This call link was revoked.',
        refusedExpired: 'This call link has expired.',
        refusedInvalid: "This call link isn't valid.",
        refusedDeclined: 'The host declined your request to join.',
        refusedBusy: 'The host is busy right now. Try again later.',
        off: 'Off',
        never: 'Never',
        atStart: 'At start',
        min10: '10 minutes before',
        hour1: '1 hour before',
        day1: '1 day before',
        live15: '15 minutes',
        live60: '1 hour',
        live480: '8 hours',
        exp1h: '1 hour',
        exp24h: '24 hours',
        exp7d: '7 days',
    });

    const RX_HEX16 = /^[0-9a-f]{16}$/;
    const RX_HEX8 = /^[0-9a-f]{8}$/;
    const RX_HEX32 = /^[0-9a-f]{32}$/;
    const RX_HEX64 = /^[0-9a-f]{64}$/;
    const RX_HEX128 = /^[0-9a-f]{128}$/;
    const RX_GROUP_ID = /^([0-9a-f]{64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i;

    function roleRank(role) {
        if (role === 'owner') return 0;
        if (role === 'admin') return 1;
        if (role === 'mod') return 2;
        return 3;
    }

    function stripQuotesAndCode(content) {
        const lines = String(content).split('\n').filter((l) => !l.replace(/^\s+/, '').startsWith('>')).join('\n');
        return lines.replace(/```[\s\S]*?```/g, ' ').replace(/`[^`\n]*`/g, ' ');
    }

    function broadcastMention(content) {
        if (typeof content !== 'string' || content.indexOf('@') < 0) return null;
        const m = /(^|[^A-Za-z0-9_@#\/.-])@(everyone|here)(?![A-Za-z0-9_#@-])/i.exec(stripQuotesAndCode(content));
        return m ? m[2].toLowerCase() : null;
    }

    function mayBroadcast(role) {
        return roleRank(role) <= 2;
    }

    function sendCheck(surface, role, content) {
        if (surface !== 'group') return { ok: true, mention: null, reason: null };
        const mention = broadcastMention(content);
        if (mention && !mayBroadcast(role)) return { ok: false, mention, reason: STRINGS.broadcastDenied };
        return { ok: true, mention, reason: null };
    }

    function notifiesAll(surface, senderRole, content) {
        return surface === 'group' && mayBroadcast(senderRole) && !!broadcastMention(content);
    }

    function broadcastSuggestions(surface, role, query) {
        if (surface !== 'group' || !mayBroadcast(role)) return [];
        const q = String(query || '').toLowerCase();
        return ['here', 'everyone'].filter((w) => w.startsWith(q));
    }

    function normalizeSlowmode(v) {
        const n = parseInt(v, 10);
        return SLOWMODE_SECONDS.indexOf(n) >= 0 ? n : 0;
    }

    function slowmodeExempt(role) {
        return roleRank(role) <= 2;
    }

    function slowmodeLabel(sec) {
        const s = normalizeSlowmode(sec);
        if (!s) return STRINGS.off;
        if (s < 60) return s + 's';
        if (s < 3600) return (s / 60) + 'm';
        return (s / 3600) + 'h';
    }

    function pad2(n) {
        return (n < 10 ? '0' : '') + n;
    }

    function formatWait(sec) {
        const s = Math.max(0, Math.ceil(Number(sec) || 0));
        if (s < 60) return s + 's';
        if (s < 3600) return Math.floor(s / 60) + ':' + pad2(s % 60);
        return Math.floor(s / 3600) + ':' + pad2(Math.floor((s % 3600) / 60)) + ':' + pad2(s % 60);
    }

    function slowmodeWait(interval, lastSentSec, nowSec) {
        const i = normalizeSlowmode(interval);
        const last = Number(lastSentSec) || 0;
        if (!i || last <= 0) return 0;
        return Math.max(0, last + i - (Number(nowSec) || 0));
    }

    function sortedForSlowmode(messages) {
        return (messages || []).filter((m) => m && typeof m.id === 'string' && Number.isFinite(Number(m.ts)))
            .map((m) => ({ id: m.id, ts: Math.floor(Number(m.ts)) }))
            .sort((a, b) => (a.ts - b.ts) || (a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)));
    }

    function slowmodeScan(messages, interval, sinceSec) {
        const i = normalizeSlowmode(interval);
        const since = Number(sinceSec) || 0;
        const held = [];
        let last = null;
        if (!i) return { held, last: 0 };
        for (const m of sortedForSlowmode(messages)) {
            if (m.ts < since) continue;
            if (last !== null && m.ts < last + i - SLOWMODE_GRACE_SEC) held.push(m.id);
            else last = m.ts;
        }
        return { held, last: last || 0 };
    }

    function slowmodeHeld(messages, interval, sinceSec) {
        return slowmodeScan(messages, interval, sinceSec).held;
    }

    function slowmodeLastAccepted(messages, interval, sinceSec) {
        return slowmodeScan(messages, interval, sinceSec).last;
    }

    function descriptionLine(desc) {
        return String(desc || '').replace(/\s+/g, ' ').trim();
    }

    function mayApproveJoins(role) {
        return roleRank(role) <= 1;
    }

    function joinRequestAction(g, req, selfCanAdd) {
        const group = g || {};
        const r = req || {};
        if (!group.inviteEnabled) return 'ignore';
        if ((parseInt(r.epoch, 10) || 0) !== (parseInt(group.epoch, 10) || 0)) return 'ignore';
        if ((group.members || []).indexOf(r.pubkey) >= 0) return 'ignore';
        if ((group.banned || []).indexOf(r.pubkey) >= 0) return 'ignore';
        if (group.approval) return 'queue';
        return selfCanAdd ? 'admit' : 'ignore';
    }

    function pruneJoinRequests(list, nowSec) {
        const cutoff = (Number(nowSec) || 0) - LIMITS.joinRequestTtlSec;
        return (Array.isArray(list) ? list : [])
            .filter((r) => r && RX_HEX64.test(String(r.pubkey || '')) && Number(r.ts) > cutoff)
            .map((r) => ({ pubkey: r.pubkey, ts: Math.floor(Number(r.ts)), via: RX_HEX64.test(String(r.via || '')) ? r.via : '' }));
    }

    function addJoinRequest(list, req, nowSec) {
        let out = pruneJoinRequests(list, nowSec);
        const r = pruneJoinRequests([req], nowSec)[0];
        if (!r) return out;
        const cur = out.find((x) => x.pubkey === r.pubkey);
        if (cur && cur.ts >= r.ts) return out;
        out = out.filter((x) => x.pubkey !== r.pubkey);
        out.push(r);
        out.sort((a, b) => (a.ts - b.ts) || (a.pubkey < b.pubkey ? -1 : 1));
        while (out.length > LIMITS.joinRequestsMax) out.shift();
        return out;
    }

    function removeJoinRequest(list, pubkey) {
        return (Array.isArray(list) ? list : []).filter((r) => r && r.pubkey !== pubkey);
    }

    function utf8Bytes(str) {
        const out = [];
        const s = String(str);
        for (let i = 0; i < s.length; i++) {
            let c = s.charCodeAt(i);
            if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
                const d = s.charCodeAt(i + 1);
                if (d >= 0xdc00 && d <= 0xdfff) {
                    c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
                    i++;
                }
            }
            if (c < 0x80) out.push(c);
            else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
            else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
            else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
        return out;
    }

    function utf8String(bytes) {
        let out = '';
        for (let i = 0; i < bytes.length;) {
            const b = bytes[i];
            let c;
            let n;
            if (b < 0x80) { c = b; n = 1; }
            else if ((b & 0xe0) === 0xc0) { c = b & 31; n = 2; }
            else if ((b & 0xf0) === 0xe0) { c = b & 15; n = 3; }
            else if ((b & 0xf8) === 0xf0) { c = b & 7; n = 4; }
            else throw new Error('utf8');
            if (i + n > bytes.length) throw new Error('utf8');
            for (let k = 1; k < n; k++) {
                const x = bytes[i + k];
                if ((x & 0xc0) !== 0x80) throw new Error('utf8');
                c = (c << 6) | (x & 63);
            }
            i += n;
            if (c >= 0x10000) {
                c -= 0x10000;
                out += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 1023));
            } else out += String.fromCharCode(c);
        }
        return out;
    }

    const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

    function b64uEncode(str) {
        const b = utf8Bytes(str);
        let out = '';
        for (let i = 0; i < b.length; i += 3) {
            const n = (b[i] << 16) | ((b[i + 1] || 0) << 8) | (b[i + 2] || 0);
            out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63];
            if (i + 1 < b.length) out += B64[(n >> 6) & 63];
            if (i + 2 < b.length) out += B64[n & 63];
        }
        return out;
    }

    function b64uDecode(token) {
        const s = String(token || '');
        if (!/^[A-Za-z0-9_-]*$/.test(s) || s.length % 4 === 1) throw new Error('b64');
        const bytes = [];
        let acc = 0;
        let bits = 0;
        for (const ch of s) {
            acc = (acc << 6) | B64.indexOf(ch);
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                bytes.push((acc >> bits) & 255);
            }
        }
        return utf8String(bytes);
    }

    function sanitizeName(name, max) {
        return String(name || '').replace(/[\x00-\x1F\x7F]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max || LIMITS.linkNameMax);
    }

    function sanitizeLine(s, max) {
        return String(s || '').replace(/[\x00-\x1F\x7F]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max);
    }

    function httpsUrl(u) {
        const s = String(u || '');
        return (/^https:\/\/[^\s"'<>]+$/.test(s) && s.length <= LIMITS.summaryUrlMax) ? s : '';
    }

    function summaryFields(src) {
        const s = src || {};
        const ad = (Array.isArray(s.adminNyms) ? s.adminNyms : [])
            .map((n) => sanitizeLine(n, LIMITS.adminNymMax)).filter(Boolean).slice(0, LIMITS.adminNymsMax);
        return {
            d: sanitizeLine(s.description, LIMITS.summaryDescMax),
            av: httpsUrl(s.avatar),
            bn: httpsUrl(s.banner),
            mc: (typeof s.memberCount === 'number' && Number.isFinite(s.memberCount)) ? Math.max(0, Math.floor(s.memberCount)) : 0,
            ad,
            ap: s.approval ? 1 : 0,
        };
    }

    function summaryContent(src) {
        return JSON.stringify(summaryFields(src));
    }

    function summaryTemplate(groupId, inviter, createdAt, content) {
        return { kind: SUMMARY_KIND, pubkey: inviter, created_at: Math.floor(Number(createdAt) || 0), tags: [['g', groupId]], content };
    }

    function parseSummaryContent(content) {
        if (typeof content !== 'string' || content.length > LIMITS.summaryContentMax) return null;
        let o;
        try { o = JSON.parse(content); } catch (_) { return null; }
        if (!o || typeof o !== 'object' || Array.isArray(o)) return null;
        return summaryFields({ description: o.d, avatar: o.av, banner: o.bn, memberCount: o.mc, adminNyms: o.ad, approval: o.ap === 1 });
    }

    function encodeInvite(p) {
        const o = { v: 1, g: p.g, n: String(p.n || 'Group').slice(0, 80), a: p.a, e: parseInt(p.e, 10) || 0 };
        if (p.s && typeof p.s === 'object') o.s = { t: Math.floor(Number(p.s.t) || 0), c: String(p.s.c || ''), sig: String(p.s.sig || '') };
        return b64uEncode(JSON.stringify(o));
    }

    function parseInviteInput(str) {
        if (!str) return null;
        let token = String(str).trim();
        const m = token.match(/[#&?]gjoin=([A-Za-z0-9_-]+)/);
        if (m) token = m[1];
        else if (/^gjoin=/.test(token)) token = token.slice(6);
        if (!/^[A-Za-z0-9_-]+$/.test(token)) return null;
        let obj;
        try { obj = JSON.parse(b64uDecode(token)); } catch (_) { return null; }
        if (!obj || typeof obj !== 'object' || obj.v !== 1) return null;
        if (!RX_GROUP_ID.test(String(obj.g || ''))) return null;
        if (!/^[0-9a-f]{64}$/i.test(String(obj.a || ''))) return null;
        const out = { v: 1, g: String(obj.g), n: typeof obj.n === 'string' ? obj.n : '', a: String(obj.a), e: parseInt(obj.e, 10) || 0 };
        const s = obj.s;
        if (s && typeof s === 'object' && Number.isInteger(s.t) && s.t > 0
            && typeof s.c === 'string' && s.c.length <= LIMITS.summaryContentMax
            && typeof s.sig === 'string' && RX_HEX128.test(s.sig)) {
            out.s = { t: s.t, c: s.c, sig: s.sig };
        }
        return out;
    }

    function invitePreview(payload, verifiedFields) {
        const p = payload || {};
        const f = verifiedFields || null;
        return {
            name: sanitizeName(p.n, 40) || 'Group',
            description: f ? descriptionLine(f.d) : '',
            avatar: f ? f.av : '',
            banner: f ? f.bn : '',
            memberCount: f ? f.mc : null,
            admins: f ? f.ad.slice() : [],
            approval: !!(f && f.ap === 1),
            verified: !!f,
        };
    }

    function pctEncode(s) {
        let out = '';
        for (const b of utf8Bytes(s)) {
            const ch = String.fromCharCode(b);
            if (b < 0x80 && /[A-Za-z0-9_.~-]/.test(ch)) out += ch;
            else out += '%' + (b < 16 ? '0' : '') + b.toString(16).toUpperCase();
        }
        return out;
    }

    function pctDecode(s) {
        const str = String(s || '');
        if (!/^(?:[A-Za-z0-9_.~-]|%[0-9A-Fa-f]{2})*$/.test(str)) throw new Error('pct');
        const bytes = [];
        for (let i = 0; i < str.length;) {
            if (str[i] === '%') { bytes.push(parseInt(str.slice(i + 1, i + 3), 16)); i += 3; }
            else { bytes.push(str.charCodeAt(i)); i++; }
        }
        return utf8String(bytes);
    }

    function tzLabel(offsetMin) {
        const o = Math.trunc(Number(offsetMin) || 0);
        if (!o) return 'UTC';
        const a = Math.abs(o);
        return 'UTC' + (o < 0 ? '-' : '+') + pad2(Math.floor(a / 60)) + ':' + pad2(a % 60);
    }

    function wallToUtc(y, mo, d, h, mi, offsetMin) {
        return Math.floor(Date.UTC(y, mo - 1, d, h, mi, 0) / 1000) - Math.trunc(Number(offsetMin) || 0) * 60;
    }

    function cleanEventFields(ev) {
        const e = ev || {};
        return {
            id: String(e.id || ''),
            title: sanitizeLine(e.title, LIMITS.titleMax),
            start: Math.floor(Number(e.start) || 0),
            offset: Math.trunc(Number(e.offset) || 0),
            place: sanitizeLine(e.place, LIMITS.placeMax),
            note: sanitizeLine(e.note, LIMITS.noteMax),
        };
    }

    function validEventFields(e) {
        return RX_HEX16.test(e.id) && !!e.title && e.start > 0 && e.start < 1e11 && e.offset >= -720 && e.offset <= 840;
    }

    function buildEventContent(ev) {
        const e = cleanEventFields(ev);
        if (!validEventFields(e)) return null;
        const lines = ['Event: ' + e.title, 'When: <t:' + e.start + ':F> (' + tzLabel(e.offset) + ')'];
        if (e.place) lines.push('Where: ' + e.place);
        if (e.note) lines.push(e.note);
        let machine = 'nymevent:v=1;id=' + e.id + ';s=' + e.start + ';o=' + e.offset + ';t=' + pctEncode(e.title);
        if (e.place) machine += ';p=' + pctEncode(e.place);
        if (e.note) machine += ';n=' + pctEncode(e.note);
        lines.push(machine);
        return lines.join('\n');
    }

    function parseEvent(content) {
        if (typeof content !== 'string' || content.indexOf('nymevent:') < 0) return null;
        const m = /(?:^|\n)nymevent:([A-Za-z0-9_.~%=;-]+)[ \t]*$/.exec(content);
        if (!m) return null;
        const params = {};
        for (const part of m[1].split(';')) {
            const i = part.indexOf('=');
            if (i <= 0) return null;
            params[part.slice(0, i)] = part.slice(i + 1);
        }
        if (params.v !== '1') return null;
        if (!/^-?\d{1,12}$/.test(params.s || '') || !/^-?\d{1,4}$/.test(params.o || '')) return null;
        let title;
        let place = '';
        let note = '';
        try {
            title = pctDecode(params.t || '');
            if (params.p) place = pctDecode(params.p);
            if (params.n) note = pctDecode(params.n);
        } catch (_) { return null; }
        const e = cleanEventFields({ id: params.id, title, start: Number(params.s), offset: Number(params.o), place, note });
        return validEventFields(e) ? e : null;
    }

    function eventFallbackText(content) {
        if (typeof content !== 'string') return '';
        return content.replace(/\n?nymevent:[^\n]*$/, '');
    }

    function previewText(content) {
        const loc = parseLocation(content);
        if (loc) return loc.kind === 'pin' ? 'Location' : 'Live location';
        return eventFallbackText(content);
    }

    function normalizeRsvp(s) {
        return RSVP_STATUSES.indexOf(s) >= 0 ? s : null;
    }

    function applyRsvp(entries, pubkey, status, ts) {
        const out = Object.assign({}, entries || {});
        const st = normalizeRsvp(status);
        const t = Math.floor(Number(ts) || 0);
        if (!st || !RX_HEX64.test(String(pubkey || '')) || t <= 0) return { entries: out, changed: false };
        const cur = out[pubkey];
        if (cur && (t < cur.ts || (t === cur.ts && st <= cur.s))) return { entries: out, changed: false };
        out[pubkey] = { s: st, ts: t };
        return { entries: out, changed: true };
    }

    function rsvpTally(entries, allowed) {
        const res = { going: [], maybe: [], no: [] };
        const list = Object.keys(entries || {})
            .filter((pk) => !allowed || allowed.indexOf(pk) >= 0)
            .map((pk) => ({ pk, s: entries[pk].s, ts: entries[pk].ts }))
            .filter((x) => normalizeRsvp(x.s))
            .sort((a, b) => (a.ts - b.ts) || (a.pk < b.pk ? -1 : 1));
        for (const x of list) res[x.s].push(x.pk);
        return res;
    }

    function rsvpTags(eventId, status) {
        return [['type', TYPES.rsvp], ['e', eventId], ['rsvp', status]];
    }

    function rsvpContent(status, title) {
        return 'RSVP ' + status + ': ' + sanitizeLine(title, LIMITS.titleMax);
    }

    function reminderAt(start, offsetMin) {
        return Math.floor(Number(start) || 0) - Math.floor(Number(offsetMin) || 0) * 60;
    }

    function reminderLabel(offsetMin) {
        if (offsetMin === 0) return STRINGS.atStart;
        if (offsetMin === 10) return STRINGS.min10;
        if (offsetMin === 60) return STRINGS.hour1;
        if (offsetMin === 1440) return STRINGS.day1;
        return '';
    }

    function encodeCallLink(link) {
        const o = { v: 1, i: link.id, h: link.host, k: link.kind === 'video' ? 'video' : 'audio', x: Math.max(0, Math.floor(Number(link.exp) || 0)), s: link.secret, n: sanitizeName(link.name, LIMITS.linkNameMax) };
        if (link.groupId) o.g = link.groupId;
        return b64uEncode(JSON.stringify(o));
    }

    function parseCallLinkInput(str) {
        if (!str) return null;
        let token = String(str).trim();
        const m = token.match(/[#&?]call=([A-Za-z0-9_-]+)/);
        if (m) token = m[1];
        else if (/^call=/.test(token)) token = token.slice(5);
        if (!/^[A-Za-z0-9_-]+$/.test(token)) return null;
        let o;
        try { o = JSON.parse(b64uDecode(token)); } catch (_) { return null; }
        if (!o || typeof o !== 'object' || o.v !== 1) return null;
        if (!RX_HEX16.test(String(o.i || '')) || !RX_HEX64.test(String(o.h || '')) || !RX_HEX32.test(String(o.s || ''))) return null;
        if (o.k !== 'audio' && o.k !== 'video') return null;
        if (!Number.isInteger(o.x) || o.x < 0) return null;
        if (o.g !== undefined && !RX_GROUP_ID.test(String(o.g))) return null;
        const out = { id: o.i, host: o.h, kind: o.k, exp: o.x, secret: o.s, name: sanitizeName(o.n, LIMITS.linkNameMax) };
        if (o.g) out.groupId = String(o.g);
        return out;
    }

    function callLinkState(link, nowSec) {
        if (!link) return 'unknown';
        if (link.revoked) return 'revoked';
        if (link.exp > 0 && (Number(nowSec) || 0) >= link.exp) return 'expired';
        return 'active';
    }

    function checkCallLinkJoin(links, linkId, secret, nowSec) {
        const link = (Array.isArray(links) ? links : []).find((l) => l && l.id === linkId);
        if (!link) return { ok: false, reason: 'unknown' };
        const st = callLinkState(link, nowSec);
        if (st !== 'active') return { ok: false, reason: st };
        if (link.secret !== secret) return { ok: false, reason: 'secret' };
        return { ok: true, reason: null };
    }

    function callLinkRefusal(reason) {
        if (reason === 'revoked') return STRINGS.refusedRevoked;
        if (reason === 'expired') return STRINGS.refusedExpired;
        if (reason === 'declined') return STRINGS.refusedDeclined;
        if (reason === 'busy') return STRINGS.refusedBusy;
        return STRINGS.refusedInvalid;
    }

    function expiryLabel(sec) {
        if (sec === 3600) return STRINGS.exp1h;
        if (sec === 86400) return STRINGS.exp24h;
        if (sec === 604800) return STRINGS.exp7d;
        return STRINGS.never;
    }

    function addCallLink(list, link) {
        const out = [link].concat((Array.isArray(list) ? list : []).filter((l) => l && l.id !== link.id));
        return out.slice(0, LIMITS.callLinksMax);
    }

    function revokeCallLink(list, id) {
        return (Array.isArray(list) ? list : []).map((l) => (l && l.id === id ? Object.assign({}, l, { revoked: true }) : l));
    }

    function coordDecimals(acc) {
        const a = Number(acc) || 0;
        if (a <= 10) return 5;
        if (a <= 100) return 4;
        if (a <= 1000) return 3;
        if (a <= 10000) return 2;
        return 1;
    }

    function wrapLon(lon) {
        let x = Number(lon) || 0;
        while (x > 180) x -= 360;
        while (x < -180) x += 360;
        return x;
    }

    function fixed(x, d) {
        const s = x.toFixed(d);
        return /^-0\.?0*$/.test(s) ? s.slice(1) : s;
    }

    function buildLocation(loc) {
        const l = loc || {};
        const lat = Math.max(-90, Math.min(90, Number(l.lat) || 0));
        const lon = wrapLon(l.lon);
        const acc = Math.max(1, Math.round(Number(l.acc) || 0));
        const d = coordDecimals(acc);
        let out = 'geo:' + fixed(lat, d) + ',' + fixed(lon, d) + ';u=' + acc;
        if (l.kind === 'live') {
            if (!RX_HEX8.test(String(l.id || ''))) return null;
            out += ';nymk=live;nymid=' + l.id + ';nymuntil=' + Math.floor(Number(l.until) || 0) + ';nymq=' + Math.max(0, Math.floor(Number(l.seq) || 0));
        } else if (l.kind === 'end') {
            if (!RX_HEX8.test(String(l.id || ''))) return null;
            out += ';nymk=end;nymid=' + l.id + ';nymq=' + Math.max(0, Math.floor(Number(l.seq) || 0));
        } else {
            out += ';nymk=pin';
        }
        return out;
    }

    function parseLocation(content) {
        if (typeof content !== 'string') return null;
        const m = /^geo:(-?\d{1,2}(?:\.\d{1,7})?),(-?\d{1,3}(?:\.\d{1,7})?)((?:;[a-z]{1,10}=[A-Za-z0-9._-]{1,20}){0,6})$/.exec(content.trim());
        if (!m) return null;
        const lat = Number(m[1]);
        const lon = Number(m[2]);
        if (!(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180)) return null;
        const p = {};
        for (const part of m[3].split(';').filter(Boolean)) {
            const i = part.indexOf('=');
            p[part.slice(0, i)] = part.slice(i + 1);
        }
        const acc = /^\d{1,8}$/.test(p.u || '') ? Number(p.u) : 0;
        const kind = p.nymk || 'pin';
        if (kind === 'pin') return { lat, lon, acc, kind: 'pin', id: '', until: 0, seq: 0 };
        if (kind !== 'live' && kind !== 'end') return null;
        if (!RX_HEX8.test(p.nymid || '') || !/^\d{1,9}$/.test(p.nymq || '')) return null;
        if (kind === 'live' && !/^\d{1,12}$/.test(p.nymuntil || '')) return null;
        return { lat, lon, acc, kind, id: p.nymid, until: kind === 'live' ? Number(p.nymuntil) : 0, seq: Number(p.nymq) };
    }

    function precisionText(acc) {
        const a = Math.max(1, Math.round(Number(acc) || 0));
        if (a < 1000) return a + ' m';
        const km = Math.round(a / 100) / 10;
        return (km % 1 === 0 ? String(km) : km.toFixed(1)) + ' km';
    }

    const GEOHASH_ACC = [2500000, 630000, 78000, 20000, 2400, 610, 76, 19, 3];

    function geohashAccuracy(len) {
        const n = Math.max(1, Math.min(GEOHASH_ACC.length, Math.floor(Number(len) || 1)));
        return GEOHASH_ACC[n - 1];
    }

    function liveState(loc, nowSec) {
        if (!loc) return 'none';
        if (loc.kind === 'pin') return 'pin';
        if (loc.kind === 'end') return 'ended';
        return (Number(nowSec) || 0) >= loc.until ? 'expired' : 'live';
    }

    function liveSupersedes(cur, next) {
        if (!cur || !next) return false;
        if (cur.kind === 'pin' || next.kind === 'pin' || cur.id !== next.id) return false;
        return next.seq > cur.seq;
    }

    function mapFrame(lat, lon, acc) {
        const a = Number(acc) || 0;
        const span = a <= 1000 ? 4 : (a <= 20000 ? 8 : (a <= 200000 ? 16 : 40));
        let minLat = lat - span / 2;
        let maxLat = lat + span / 2;
        if (minLat < -90) { maxLat += -90 - minLat; minLat = -90; }
        if (maxLat > 90) { minLat -= maxLat - 90; maxLat = 90; }
        const minLon = lon - span;
        const maxLon = lon + span;
        return { minLon, maxLon, minLat, maxLat, x: (lon - minLon) / (maxLon - minLon), y: (maxLat - lat) / (maxLat - minLat) };
    }

    const PICK_START_SPAN = 180;

    function pickAccuracy(span) {
        return Math.max(5, Math.round((Number(span) || 0) * 111320 / 20));
    }

    function pickZoomIn(span) {
        return Math.max(0.005, (Number(span) || 0) / 4);
    }

    function pickZoomOut(span) {
        return Math.min(PICK_START_SPAN, (Number(span) || 0) * 4);
    }

    function pickTap(lat, lon, span, fx, fy) {
        const x = Math.max(0, Math.min(1, Number(fx) || 0));
        const y = Math.max(0, Math.min(1, Number(fy) || 0));
        const nlat = Math.max(-89.9, Math.min(89.9, lat + span / 2 - y * span));
        const nlon = wrapLon(lon - span + x * 2 * span);
        return { lat: nlat, lon: nlon, span: pickZoomIn(span) };
    }

    function liveDurationLabel(sec) {
        if (sec === 900) return STRINGS.live15;
        if (sec === 3600) return STRINGS.live60;
        if (sec === 28800) return STRINGS.live480;
        return '';
    }

    const GROUP_FEATURES = ['mentionAll', 'slowmode', 'description', 'approval', 'preview', 'event', 'rsvp'];

    function availability(feature, ctx) {
        const c = ctx || {};
        const ok = { ok: true, reason: null, mesh: false };
        if (feature === 'location' || feature === 'liveLocation') {
            if (c.surface === 'channel') return { ok: false, reason: STRINGS.noPublicLocation, mesh: false };
            if (c.surface === 'group') return c.online ? ok : { ok: false, reason: STRINGS.groupsNeedNet, mesh: false };
            if (c.online) return ok;
            if (c.meshPeer) return { ok: true, reason: null, mesh: true };
            return { ok: false, reason: STRINGS.locationNeedsNet, mesh: false };
        }
        if (feature === 'callLink') return c.online ? ok : { ok: false, reason: STRINGS.callNeedsNet, mesh: false };
        if (GROUP_FEATURES.indexOf(feature) >= 0) return c.online ? ok : { ok: false, reason: STRINGS.groupsNeedNet, mesh: false };
        return { ok: false, reason: null, mesh: false };
    }

    function groupCapRoster(input) {
        const o = input || {};
        const max = Math.max(0, Math.floor(Number(o.max) || 0));
        const banned = new Set(Array.isArray(o.banned) ? o.banned : []);
        const best = new Map();
        for (const e of (Array.isArray(o.entries) ? o.entries : [])) {
            if (!e || typeof e.pk !== 'string' || !e.pk || banned.has(e.pk)) continue;
            let at = Number(e.at);
            if (!Number.isFinite(at) || at < 0) at = 0;
            const cur = best.get(e.pk);
            if (cur === undefined || at < cur) best.set(e.pk, at);
        }
        const sorted = [...best].sort((a, b) => (a[1] - b[1]) || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
        return { members: sorted.slice(0, max).map((e) => e[0]), dropped: sorted.slice(max).map((e) => e[0]) };
    }

    G.NymGroupTools = {
        LIMITS, STRINGS, TYPES, CALL_SIGNALS, SLOWMODE_SECONDS, SLOWMODE_GRACE_SEC, LIVE_DURATIONS_SEC,
        REMINDER_OFFSETS_MIN, CALL_LINK_EXPIRY_SEC, RSVP_STATUSES, SUMMARY_KIND,
        roleRank, broadcastMention, mayBroadcast, sendCheck, notifiesAll, broadcastSuggestions,
        normalizeSlowmode, slowmodeExempt, slowmodeLabel, formatWait, slowmodeWait, slowmodeHeld, slowmodeLastAccepted,
        descriptionLine, mayApproveJoins, joinRequestAction, pruneJoinRequests, addJoinRequest, removeJoinRequest,
        b64uEncode, b64uDecode, sanitizeName, summaryFields, summaryContent, summaryTemplate, parseSummaryContent,
        encodeInvite, parseInviteInput, invitePreview,
        pctEncode, pctDecode, tzLabel, wallToUtc, buildEventContent, parseEvent, eventFallbackText, previewText,
        normalizeRsvp, applyRsvp, rsvpTally, rsvpTags, rsvpContent, reminderAt, reminderLabel,
        encodeCallLink, parseCallLinkInput, callLinkState, checkCallLinkJoin, callLinkRefusal, expiryLabel,
        addCallLink, revokeCallLink,
        coordDecimals, buildLocation, parseLocation, precisionText, geohashAccuracy, liveState, liveSupersedes,
        mapFrame, liveDurationLabel, availability, PICK_START_SPAN, pickAccuracy, pickZoomIn, pickZoomOut, pickTap,
        groupCapRoster,
    };
})();
