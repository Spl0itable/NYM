(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const COORD = /^30030:[0-9a-f]{64}:[^\u0000-\u001f\u007f]{0,1024}$/;
    const CODE = /^[a-zA-Z0-9_]{1,64}$/;
    const URL_RX = /^https?:\/\//i;
    const TOKEN = /:([a-zA-Z0-9_]+):/g;
    const CONTROL = /[\u0000-\u001f\u007f]/g;
    const SETTINGS_KEY = 'nym_blocked_emoji_packs';
    const SYNC_FIELD = 'blockedEmojiPacks';
    const MAX_PACKS = 200;
    const MAX_SAMPLE = 4;
    const MAX_NAME = 64;
    const MAX_URL = 1024;
    const MAX_LEARNED = 4000;
    const GLOBAL_KEY = 'nym_global_emoji_blocks';
    const GLOBAL_FIELD = 'ep';
    const MAX_GLOBAL = 5000;
    const GLOBAL_URL_KEY = 'nym_global_emoji_block_urls';
    const GLOBAL_URL_FIELD = 'epu';
    const MAX_GLOBAL_URLS = 3000;

    function str(v) {
        return typeof v === 'string' ? v : '';
    }

    function validCoord(c) {
        return typeof c === 'string' && COORD.test(c);
    }

    function coordOf(pubkey, d) {
        const c = '30030:' + str(pubkey) + ':' + str(d);
        return validCoord(c) ? c : '';
    }

    function authorOf(c) {
        return validCoord(c) ? c.slice(6, 70) : '';
    }

    function dOf(c) {
        return validCoord(c) ? c.slice(71) : '';
    }

    function cleanName(v) {
        let s = str(v).replace(CONTROL, '').trim();
        if (s.length > MAX_NAME) {
            s = s.slice(0, MAX_NAME);
            const last = s.charCodeAt(s.length - 1);
            if (last >= 0xD800 && last <= 0xDBFF) s = s.slice(0, -1);
            s = s.trim();
        }
        return s;
    }

    function cleanSample(list) {
        const out = [];
        if (!Array.isArray(list)) return out;
        const seen = new Set();
        for (const e of list) {
            if (out.length >= MAX_SAMPLE) break;
            if (!e || typeof e !== 'object') continue;
            const code = str(e.shortcode);
            const url = str(e.url);
            if (!CODE.test(code) || !URL_RX.test(url) || url.length > MAX_URL || seen.has(code)) continue;
            seen.add(code);
            out.push({ shortcode: code, url });
        }
        return out;
    }

    function cleanAt(v) {
        return typeof v === 'number' && Number.isInteger(v) && v >= 0 ? v : 0;
    }

    function normalize(list) {
        if (!Array.isArray(list)) return [];
        const out = [];
        const seen = new Set();
        for (const item of list) {
            if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
            const coord = str(item.coord);
            if (!validCoord(coord) || seen.has(coord)) continue;
            seen.add(coord);
            out.push({ coord, name: cleanName(item.name), sample: cleanSample(item.sample), at: cleanAt(item.at) });
        }
        return out.length > MAX_PACKS ? out.slice(out.length - MAX_PACKS) : out;
    }

    function packCoord(pack) {
        if (!pack || typeof pack !== 'object') return '';
        return coordOf(pack.pubkey, pack.identifier);
    }

    function entryFor(pack, at) {
        const coord = packCoord(pack);
        if (!coord) return null;
        return {
            coord,
            name: cleanName(str(pack.title) || str(pack.identifier)),
            sample: cleanSample(pack.emojis),
            at: cleanAt(at)
        };
    }

    function add(list, entry) {
        const cur = normalize(list);
        const e = normalize([entry])[0];
        if (!e) return cur;
        return normalize(cur.filter((x) => x.coord !== e.coord).concat([e]));
    }

    function remove(list, coord) {
        return normalize(list).filter((x) => x.coord !== coord);
    }

    function globalList(v) {
        if (!Array.isArray(v)) return null;
        const seen = new Set();
        for (const c of v) if (validCoord(c)) seen.add(c);
        const out = Array.from(seen).sort((a, b) => (a < b ? -1 : (a > b ? 1 : 0)));
        return out.length > MAX_GLOBAL ? out.slice(0, MAX_GLOBAL) : out;
    }

    function globalUrls(v) {
        if (!Array.isArray(v)) return null;
        const seen = new Set();
        for (const u of v) if (typeof u === 'string' && URL_RX.test(u) && u.length <= MAX_URL) seen.add(u);
        const out = Array.from(seen).sort((a, b) => (a < b ? -1 : (a > b ? 1 : 0)));
        return out.length > MAX_GLOBAL_URLS ? out.slice(0, MAX_GLOBAL_URLS) : out;
    }

    function state(list, packs, global, gurls) {
        const entries = normalize(list);
        const coords = new Set(entries.map((e) => e.coord));
        if (global && typeof global[Symbol.iterator] === 'function' && typeof global !== 'string') {
            for (const c of global) if (validCoord(c)) coords.add(c);
        }
        const urls = new Set();
        for (const e of entries) for (const s of e.sample) urls.add(s.url);
        if (gurls && typeof gurls[Symbol.iterator] === 'function' && typeof gurls !== 'string') {
            for (const u of gurls) if (typeof u === 'string' && u) urls.add(u);
        }
        if (packs && typeof packs[Symbol.iterator] === 'function') {
            for (const p of packs) {
                if (!p || !Array.isArray(p.emojis) || !coords.has(packCoord(p))) continue;
                for (const em of p.emojis) if (em && typeof em.url === 'string' && em.url) urls.add(em.url);
            }
        }
        return { coords, urls, base: new Set(urls), learned: new Set() };
    }

    function learnTags(tags, st) {
        let added = 0;
        if (!Array.isArray(tags) || !st || !st.coords || st.coords.size === 0) return added;
        if (!st.base) st.base = new Set(st.urls);
        if (!st.learned) st.learned = new Set();
        for (const t of tags) {
            if (!Array.isArray(t) || t[0] !== 'emoji' || typeof t[2] !== 'string' || !t[2]) continue;
            if (typeof t[3] !== 'string' || !st.coords.has(t[3])) continue;
            const url = t[2];
            if (st.base.has(url)) continue;
            if (st.learned.has(url)) {
                st.learned.delete(url);
                st.learned.add(url);
                continue;
            }
            st.learned.add(url);
            st.urls.add(url);
            added++;
            if (st.learned.size > MAX_LEARNED) {
                const old = st.learned.values().next().value;
                st.learned.delete(old);
                if (!st.base.has(old)) st.urls.delete(old);
            }
        }
        return added;
    }

    function hidden(emoji, st) {
        if (!emoji || !st) return false;
        const coord = str(emoji.coord);
        if (coord && st.coords && st.coords.has(coord)) return true;
        const url = str(emoji.url);
        return !!url && !!st.urls && st.urls.has(url);
    }

    function strip(text, isHidden) {
        if (typeof text !== 'string' || text.indexOf(':') === -1 || typeof isHidden !== 'function') return str(text);
        return text.replace(TOKEN, (m, code) => (isHidden(code) ? '' : m));
    }

    function reportTags(coord, type) {
        if (!validCoord(coord)) return [];
        const t = str(type) || 'other';
        return [['p', authorOf(coord), t], ['a', coord, t]];
    }

    G.NymEmojiBlock = Object.freeze({
        SETTINGS_KEY, SYNC_FIELD, MAX_PACKS, MAX_SAMPLE, MAX_NAME, MAX_LEARNED, GLOBAL_KEY, GLOBAL_FIELD, MAX_GLOBAL,
        GLOBAL_URL_KEY, GLOBAL_URL_FIELD, MAX_GLOBAL_URLS,
        validCoord, coordOf, globalList, globalUrls, authorOf, dOf, packCoord, normalize, entryFor, add, remove, state, learnTags, hidden, strip, reportTags
    });
})();
