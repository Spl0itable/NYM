(function () {
    const G = (typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : globalThis));

    const HOST = 'https://web.nymchat.app';
    const HOSTS = ['web.nymchat.app'];
    const CODE_MAX_BYTES = 382;
    const MAX_INPUT_BYTES = 4096;
    const MAX_TOKEN_CHARS = 4000;
    const MAX_CHANNEL_CHARS = 64;
    const MAX_NPROFILE_CHARS = 1000;
    const NEARBY_TYPE = 0x71;
    const NEARBY_VERSION = 0x01;
    const NEARBY_MAX_BYTES = 1024;
    const MAX_GROUP_MEMBERS = 100;

    const STRINGS = Object.freeze({
        notNymchat: 'Not a Nymchat code',
        groupWarning: 'Anyone who sees or scans this code can ask to join and will see the group’s name.',
        stickerWarning: 'Anyone who taps or scans this sticker can read the link.',
    });

    const APP_LINKS = Object.freeze({
        downloadPage: 'https://nymchat.app/',
        webApp: 'https://web.nymchat.app/',
        iosTestFlight: 'https://testflight.apple.com/join/k8FS8Mm3',
        googlePlay: 'https://play.google.com/store/apps/details?id=com.nym.bar',
        zapstore: 'https://zapstore.dev/apps/com.nym.bar',
        exact: Object.freeze([
            'https://nymchat.app/',
            'https://web.nymchat.app/',
            'https://web.nymchat.app',
            'https://testflight.apple.com/join/k8FS8Mm3',
            'https://play.google.com/store/apps/details?id=com.nym.bar',
            'https://zapstore.dev/apps/com.nym.bar',
        ]),
    });

    const enc = new TextEncoder();
    const utf8Len = (s) => enc.encode(s).length;

    const CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
    function polymod(values) {
        const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
        let chk = 1;
        for (const v of values) {
            const top = chk >>> 25;
            chk = ((chk & 0x1ffffff) << 5) ^ v;
            for (let i = 0; i < 5; i++) if ((top >>> i) & 1) chk ^= GEN[i];
        }
        return chk >>> 0;
    }
    function hrpExpand(hrp) {
        const out = [];
        for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) >> 5);
        out.push(0);
        for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) & 31);
        return out;
    }
    function convertBits(data, from, to, pad) {
        let acc = 0, bits = 0;
        const out = [];
        const maxv = (1 << to) - 1;
        for (const v of data) {
            if (v < 0 || (v >> from) !== 0) return null;
            acc = (acc << from) | v;
            bits += from;
            while (bits >= to) { bits -= to; out.push((acc >> bits) & maxv); }
        }
        if (pad) { if (bits > 0) out.push((acc << (to - bits)) & maxv); }
        else if (bits >= from || ((acc << (to - bits)) & maxv)) return null;
        return out;
    }
    function bech32Decode(str) {
        if (typeof str !== 'string') return null;
        const lower = str.toLowerCase();
        if (str !== lower && str !== str.toUpperCase()) return null;
        const pos = lower.lastIndexOf('1');
        if (pos < 1 || pos + 7 > lower.length) return null;
        const hrp = lower.slice(0, pos);
        const data = [];
        for (let i = pos + 1; i < lower.length; i++) {
            const d = CHARSET.indexOf(lower[i]);
            if (d === -1) return null;
            data.push(d);
        }
        if (polymod(hrpExpand(hrp).concat(data)) !== 1) return null;
        const bytes = convertBits(data.slice(0, -6), 5, 8, false);
        if (!bytes) return null;
        return { hrp, bytes };
    }
    function bech32Encode(hrp, bytes) {
        const data = convertBits(Array.from(bytes), 8, 5, true);
        const values = hrpExpand(hrp).concat(data).concat([0, 0, 0, 0, 0, 0]);
        const mod = polymod(values) ^ 1;
        let out = hrp + '1';
        for (const d of data) out += CHARSET[d];
        for (let i = 0; i < 6; i++) out += CHARSET[(mod >> (5 * (5 - i))) & 31];
        return out;
    }
    const toHex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    function hexToBytes(h) {
        if (typeof h !== 'string' || !/^[0-9a-fA-F]*$/.test(h) || h.length % 2) return null;
        const out = new Uint8Array(h.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
        return out;
    }

    function npubToHex(s) {
        const d = bech32Decode(s);
        if (!d || d.hrp !== 'npub' || d.bytes.length !== 32) return null;
        return toHex(d.bytes);
    }
    function nprofileToHex(s) {
        if (s.length > MAX_NPROFILE_CHARS) return null;
        const d = bech32Decode(s);
        if (!d || d.hrp !== 'nprofile') return null;
        const b = d.bytes;
        let i = 0, pk = null;
        while (i < b.length) {
            if (i + 2 > b.length) return null;
            const t = b[i], l = b[i + 1];
            if (i + 2 + l > b.length) return null;
            if (t === 0 && pk === null) {
                if (l !== 32) return null;
                pk = toHex(b.slice(i + 2, i + 2 + l));
            }
            i += 2 + l;
        }
        return pk;
    }
    function hexToNpub(hexKey) {
        if (typeof hexKey !== 'string' || !/^[0-9a-f]{64}$/i.test(hexKey)) return null;
        return bech32Encode('npub', hexToBytes(hexKey.toLowerCase()));
    }

    const invalid = (reason) => ({ kind: 'invalid', reason });
    const RX_CONTROL = /[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u2028-\u202E\u2060-\u2069\uFEFF]/;
    const RX_NPUB_FRAGMENT = /^npub1[02-9ac-hj-np-z]{58}$/;
    const RX_GEOHASH = /^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/;
    const RX_CHANNEL = /^[\p{L}\p{N}]+$/u;
    const RX_UPPER_OR_TITLE = /[\p{Lu}\p{Lt}]/u;
    const asciiLower = (v) => v.replace(/[A-Z]/g, (c) => c.toLowerCase());

    function trimAscii(s) {
        return s.replace(/^[ \t\n\r\f\v]+/, '').replace(/[ \t\n\r\f\v]+$/, '');
    }

    function strictPercentDecode(s) {
        const bytes = [];
        for (let i = 0; i < s.length; i++) {
            const c = s[i];
            if (c === '%') {
                const h = s.substr(i + 1, 2);
                if (!/^[0-9A-Fa-f]{2}$/.test(h)) return null;
                bytes.push(parseInt(h, 16));
                i += 2;
            } else {
                for (const b of enc.encode(c)) bytes.push(b);
            }
        }
        try { return new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array(bytes)); } catch (_) { return null; }
    }

    function parseChannel(name, refPrefix) {
        let n = name;
        if (n.indexOf('%') !== -1) {
            n = strictPercentDecode(n);
            if (n === null) return invalid('bad_fragment');
        }
        n = asciiLower(n);
        if (RX_UPPER_OR_TITLE.test(n) || !RX_CHANNEL.test(n) || Array.from(n).length > MAX_CHANNEL_CHARS) return invalid('bad_fragment');
        return { kind: 'channel', channel: n, geohash: RX_GEOHASH.test(n), refPrefix };
    }

    function parseInviteToken(token) {
        if (!/^[A-Za-z0-9_-]+$/.test(token) || token.length > MAX_TOKEN_CHARS) return invalid('bad_invite');
        const GT = G.NymGroupTools;
        const p = GT && typeof GT.parseInviteInput === 'function' ? GT.parseInviteInput(token) : null;
        if (!p) return invalid('bad_invite');
        return { kind: 'groupInvite', groupId: p.g, approver: p.a, epoch: p.e, name: p.n, hasSummary: !!p.s, token };
    }

    function parseShareInput(raw, opts) {
        if (typeof raw !== 'string') return invalid('empty');
        let s = raw;
        if (s.charCodeAt(0) === 0xFEFF) s = s.slice(1);
        s = trimAscii(s);
        if (!s) return invalid('empty');
        if (utf8Len(s) > MAX_INPUT_BYTES) return invalid('too_long');
        if (RX_CONTROL.test(s)) return invalid('control_chars');
        if (APP_LINKS.exact.indexOf(s) !== -1) return { kind: 'appLink', url: s };

        let rest = s;
        const hadNostr = /^nostr:/i.test(rest);
        if (hadNostr) rest = rest.slice(6);
        const lowerRest = asciiLower(rest);
        if (lowerRest.startsWith('nsec1') || lowerRest.startsWith('ncryptsec1')) return invalid('secret');
        if (lowerRest.startsWith('npub1')) {
            const pk = npubToHex(rest);
            return pk ? { kind: 'profile', pubkey: pk } : invalid('bad_profile');
        }
        if (lowerRest.startsWith('nprofile1')) {
            const pk = nprofileToHex(rest);
            return pk ? { kind: 'profile', pubkey: pk } : invalid('bad_profile');
        }
        if (hadNostr) return invalid('not_nymchat');

        const scheme = s.match(/^([A-Za-z][A-Za-z0-9+.-]*):/);
        if (!scheme) return invalid('not_nymchat');
        const hosts = HOSTS.concat(((opts && opts.extraHosts) || []).filter((h) => typeof h === 'string' && h).map((h) => h.toLowerCase()));
        const authorityOf = (afterSlashes) => {
            const m = afterSlashes.match(/^[^/?#]*/);
            return m ? m[0] : '';
        };
        if (!/^https:\/\//i.test(s)) {
            if (/^http:\/\//i.test(s) && authorityOf(s.slice(7)).toLowerCase() === 'web.nymchat.app') return invalid('not_https');
            return invalid('not_nymchat');
        }
        const afterScheme = s.slice(8);
        const authority = authorityOf(afterScheme);
        if (hosts.indexOf(authority.toLowerCase()) === -1) return invalid('other_host');
        const tail = afterScheme.slice(authority.length);
        const hashAt = tail.indexOf('#');
        const qAt = tail.indexOf('?');
        if (qAt !== -1 && (hashAt === -1 || qAt < hashAt)) return invalid('bad_path');
        const p = hashAt === -1 ? tail : tail.slice(0, hashAt);
        if (p !== '' && p !== '/' && p !== '/index.html') return invalid('bad_path');
        if (hashAt === -1) return invalid('bad_fragment');
        const frag = tail.slice(hashAt + 1);
        if (!frag) return invalid('bad_fragment');

        if (frag.startsWith('gjoin=')) return parseInviteToken(frag.slice(6));
        if (frag.startsWith('p=')) {
            const v = frag.slice(2);
            const pk = RX_NPUB_FRAGMENT.test(v) ? npubToHex(v) : null;
            return pk ? { kind: 'profile', pubkey: pk } : invalid('bad_profile');
        }
        if (frag.startsWith('call=')) return invalid('unsupported_link');
        const ref = frag.match(/^([egcEGC]):(.*)$/);
        if (ref) return parseChannel(ref[2], ref[1].toLowerCase());
        return parseChannel(frag, '');
    }

    function profileLink(pubkeyHex) {
        const npub = hexToNpub(pubkeyHex);
        return npub ? `${HOST}/#p=${npub}` : null;
    }

    function channelCodeLink(channel) {
        const c = String(channel || '');
        if (!c) return null;
        return `${HOST}/#${encodeURIComponent(c)}`;
    }

    function encodeInvite(payload) {
        const GT = G.NymGroupTools;
        return GT.encodeInvite(payload);
    }

    function groupInviteLink(payload) {
        return `${HOST}/#gjoin=${encodeInvite(payload)}`;
    }

    function groupCodeLink(payload) {
        if (!payload || !payload.g || !payload.a) return null;
        const full = groupInviteLink(payload);
        if (utf8Len(full) <= CODE_MAX_BYTES) return full;
        const cps = Array.from(String(payload.n || 'Group')).slice(0, 80);
        for (;;) {
            const code = groupInviteLink({ v: 1, g: payload.g, n: cps.join(''), a: payload.a, e: payload.e });
            if (utf8Len(code) <= CODE_MAX_BYTES) return code;
            if (cps.length <= 1) return null;
            cps.pop();
        }
    }

    function groupCodeOffer(state) {
        const st = state || {};
        if (!st.inviteEnabled) return { offered: false, reason: 'disabled' };
        if (!st.canAddMembers) return { offered: false, reason: 'not_allowed' };
        const cap = st.maxMembers || MAX_GROUP_MEMBERS;
        if ((Number(st.memberCount) || 0) >= cap) return { offered: false, reason: 'full' };
        return { offered: true };
    }

    function isCodeSafe(link) {
        return typeof link === 'string' && /^[\x21-\x7e]+$/.test(link) && link.length <= CODE_MAX_BYTES;
    }

    function ndefMessage(link) {
        if (typeof link !== 'string' || !link.startsWith('https://')) return null;
        const body = enc.encode(link.slice(8));
        const plLen = body.length + 1;
        const short = plLen <= 255;
        const head = short ? [0xD1, 0x01, plLen] : [0xC1, 0x01, (plLen >>> 24) & 255, (plLen >>> 16) & 255, (plLen >>> 8) & 255, plLen & 255];
        const out = new Uint8Array(head.length + 2 + body.length);
        out.set(head, 0);
        out[head.length] = 0x55;
        out[head.length + 1] = 0x04;
        out.set(body, head.length + 2);
        return out;
    }

    function ndefFile(link) {
        const m = ndefMessage(link);
        if (!m) return null;
        const out = new Uint8Array(m.length + 2);
        out[0] = (m.length >>> 8) & 255;
        out[1] = m.length & 255;
        out.set(m, 2);
        return out;
    }

    function webNfcRecord(link) {
        return { recordType: 'url', data: link };
    }

    function encodeNearby(link) {
        if (typeof link !== 'string') return null;
        const body = enc.encode(link);
        if (body.length < 1 || body.length > NEARBY_MAX_BYTES) return null;
        const out = new Uint8Array(4 + body.length);
        out[0] = NEARBY_TYPE;
        out[1] = NEARBY_VERSION;
        out[2] = (body.length >>> 8) & 255;
        out[3] = body.length & 255;
        out.set(body, 4);
        return out;
    }

    function decodeNearby(bytes) {
        if (!bytes || bytes.length < 5) return null;
        if (bytes[0] !== NEARBY_TYPE || bytes[1] !== NEARBY_VERSION) return null;
        const len = (bytes[2] << 8) | bytes[3];
        if (len < 1 || len > NEARBY_MAX_BYTES || bytes.length !== 4 + len) return null;
        try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes.slice(4)); } catch (_) { return null; }
    }

    function createNearbyLimiter(cfg) {
        const c = Object.assign({ perPeerMinIntervalMs: 10000, perPeerWindowMs: 600000, perPeerWindowMax: 5, duplicateWindowMs: 600000 }, cfg || {});
        const peers = new Map();
        return {
            accept(peer, link, now) {
                const list = (peers.get(peer) || []).filter((e) => now - e.t < Math.max(c.perPeerWindowMs, c.duplicateWindowMs));
                peers.set(peer, list);
                const last = list.length ? list[list.length - 1].t : null;
                if (last !== null && now - last < c.perPeerMinIntervalMs) return false;
                if (list.some((e) => e.link === link && now - e.t < c.duplicateWindowMs)) return false;
                if (list.filter((e) => now - e.t < c.perPeerWindowMs).length >= c.perPeerWindowMax) return false;
                list.push({ t: now, link });
                return true;
            },
            clear() { peers.clear(); },
        };
    }

    function createSendGuard(ms) {
        const last = new Map();
        return {
            allow(peer, now) {
                const t = last.get(peer);
                if (t !== undefined && now - t < ms) return false;
                last.set(peer, now);
                return true;
            },
        };
    }

    function appShareMode(info) {
        const i = info || {};
        if (i.platform !== 'android') return 'qr';
        if (i.splitCount !== 0) return 'qr';
        if (i.installer === 'com.android.vending') return 'qr';
        const abis = Array.isArray(i.abis) ? i.abis : [];
        return abis.indexOf('arm64-v8a') !== -1 && abis.indexOf('armeabi-v7a') !== -1 ? 'apk' : 'qr';
    }

    function formatFingerprint(hexStr) {
        if (typeof hexStr !== 'string' || !/^[0-9a-fA-F]{64}$/.test(hexStr)) return '';
        return hexStr.toUpperCase().match(/../g).join(':');
    }

    function shortNpub(pubkeyHex) {
        const n = hexToNpub(pubkeyHex);
        return n ? `${n.slice(0, 9)}...${n.slice(-4)}` : '';
    }

    function extraHostsFor(loc) {
        const host = loc && typeof loc.host === 'string' ? loc.host.toLowerCase() : '';
        return host && HOSTS.indexOf(host) === -1 ? [host] : [];
    }

    const api = {
        HOST, HOSTS, CODE_MAX_BYTES, NEARBY_TYPE, NEARBY_MAX_BYTES, STRINGS, APP_LINKS,
        parseShareInput, profileLink, channelCodeLink, groupInviteLink, groupCodeLink, groupCodeOffer, isCodeSafe,
        ndefMessage, ndefFile, webNfcRecord, encodeNearby, decodeNearby, createNearbyLimiter, createSendGuard,
        appShareMode, formatFingerprint, shortNpub, hexToNpub, npubToHex, extraHostsFor,
    };
    G.NymShareLinks = api;
    if (typeof module !== 'undefined' && module && typeof module === 'object') module.exports = api;
})();
