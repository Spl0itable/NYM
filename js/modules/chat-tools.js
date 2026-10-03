(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const LIMITS = Object.freeze({
        savedMax: 500,
        savedTextMax: 4000,
        removedMax: 1000,
        removedTtlMs: 180 * 24 * 60 * 60 * 1000,
        editVersionsMax: 20,
        editMessagesMax: 1000,
        keepMax: 2000,
    });

    const SAVED_DTAG = 'nymchat-saved';
    const SAVED_KEY = 'nym_saved_messages';
    const SAVED_PENDING_KEY = 'nym_saved_pending';
    const EDITS_KEY = 'nym_edit_history';
    const KEEP_KEY = 'nym_kept_messages';
    const RECEIPT_KEEP = 'keep';
    const RECEIPT_UNKEEP = 'unkeep';
    const MESH_KEEP_PREFIX = 'nymkeep:';
    const MESH_UNKEEP_PREFIX = 'nymunkeep:';

    const STRINGS = Object.freeze({
        onceNotSaved: "View-once media can't be saved.",
        onceExported: '[view-once media, not exported]',
        localMedia: '[mesh media, not saved]',
        exportTitle: 'Chat export: {title}',
        exportedAt: 'Exported {time}',
        edited: '(edited)',
        voice: 'Voice message',
        round: 'Video note',
    });

    const IMAGE_EXT = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'heic', 'bmp', 'svg'];
    const VIDEO_EXT = ['mp4', 'webm', 'mov', 'm4v', 'ogv', 'mkv'];
    const AUDIO_EXT = ['mp3', 'm4a', 'ogg', 'oga', 'wav', 'flac', 'aac', 'opus', 'weba'];
    const FILE_EXT = ['pdf', 'zip', 'txt', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'csv', 'json', 'md',
        'rar', '7z', 'tar', 'gz', 'apk', 'dmg', 'epub', 'rtf', 'odt', 'ods'];

    const RX_TOKEN = /(https?:\/\/[^\s<>"'`|]+|nymlocal:[A-Za-z0-9]{1,40}(?:#nym:[A-Za-z0-9=;:.\/_+-]+)?)/g;
    const RX_ONCE_ID = /^[0-9a-f]{16}$/;
    const RX_KEEP_ID = /^[A-Za-z0-9:_-]{1,128}$/;

    function fill(s, vars) {
        let out = String(s);
        if (vars) for (const k of Object.keys(vars)) out = out.split('{' + k + '}').join(String(vars[k]));
        return out;
    }

    function tr(t, s, vars) {
        const base = typeof t === 'function' ? t(s) : s;
        return fill(base, vars);
    }

    function trimUrl(url) {
        let u = url;
        for (;;) {
            if (!u.length) break;
            const ch = u[u.length - 1];
            if ('.,;:!?\'"*~'.indexOf(ch) >= 0) { u = u.slice(0, -1); continue; }
            if (ch === ')' && count(u, '(') < count(u, ')')) { u = u.slice(0, -1); continue; }
            if (ch === ']' && count(u, '[') < count(u, ']')) { u = u.slice(0, -1); continue; }
            break;
        }
        return u;
    }

    function count(s, ch) {
        let n = 0;
        for (const c of s) if (c === ch) n++;
        return n;
    }

    function parseDescriptorParams(frag) {
        const out = {};
        if (!frag) return out;
        for (const part of frag.split(';')) {
            const i = part.indexOf('=');
            if (i > 0) out[part.slice(0, i)] = part.slice(i + 1);
        }
        return out;
    }

    function spoilerRanges(text) {
        const out = [];
        const rx = /\|\|([\s\S]+?)\|\|/g;
        let m;
        while ((m = rx.exec(text))) out.push([m.index, m.index + m[0].length]);
        return out;
    }

    function inRanges(ranges, i) {
        for (const r of ranges) if (i >= r[0] && i < r[1]) return true;
        return false;
    }

    function extOf(path) {
        const clean = path.split('?')[0].split('#')[0];
        const seg = clean.split('/').pop() || '';
        const dot = seg.lastIndexOf('.');
        if (dot <= 0 || dot === seg.length - 1) return '';
        return seg.slice(dot + 1).toLowerCase();
    }

    function lastSegment(url) {
        const clean = url.split('?')[0].split('#')[0];
        const noScheme = clean.replace(/^https?:\/\/[^/]+/, '');
        let seg = noScheme.split('/').filter(Boolean).pop() || '';
        try { seg = decodeURIComponent(seg); } catch (_) { }
        return seg;
    }

    function tokens(text) {
        const out = [];
        const src = String(text || '');
        RX_TOKEN.lastIndex = 0;
        let m;
        while ((m = RX_TOKEN.exec(src))) {
            const raw = m[0];
            const isLocal = raw.indexOf('nymlocal:') === 0;
            const token = isLocal ? raw : trimUrl(raw);
            if (!token) continue;
            const hash = token.indexOf('#nym:');
            const base = hash >= 0 ? token.slice(0, hash) : token;
            const params = hash >= 0 ? parseDescriptorParams(token.slice(hash + 5)) : null;
            out.push({ index: m.index, length: token.length, token, base, params, local: isLocal });
            RX_TOKEN.lastIndex = m.index + Math.max(1, token.length);
        }
        return out;
    }

    function isOnceParams(p) {
        return !!(p && typeof p.o === 'string' && RX_ONCE_ID.test(p.o));
    }

    function hasOnce(content) {
        return tokens(content).some((t) => isOnceParams(t.params));
    }

    function classify(tok) {
        const p = tok.params;
        if (p && p.k) {
            if (p.k === 'photo') return { tab: 'media', kind: 'image' };
            if (p.k === 'video' || p.k === 'round') return { tab: 'media', kind: 'video', note: p.k === 'round' };
            if (p.k === 'voice') return { tab: 'files', kind: 'audio', note: true };
        }
        if (tok.local) {
            const m = p && p.m ? String(p.m) : '';
            if (/^image\//.test(m)) return { tab: 'media', kind: 'image' };
            if (/^video\//.test(m)) return { tab: 'media', kind: 'video' };
            return { tab: 'files', kind: 'file' };
        }
        const ext = extOf(tok.base);
        if (IMAGE_EXT.indexOf(ext) >= 0) return { tab: 'media', kind: 'image' };
        if (VIDEO_EXT.indexOf(ext) >= 0) return { tab: 'media', kind: 'video' };
        if (AUDIO_EXT.indexOf(ext) >= 0) return { tab: 'files', kind: 'audio' };
        if (FILE_EXT.indexOf(ext) >= 0) return { tab: 'files', kind: 'file' };
        return { tab: 'links', kind: 'link' };
    }

    function quoteMask(text) {
        const mask = [];
        let offset = 0;
        for (const line of String(text || '').split('\n')) {
            mask.push([offset, offset + line.length, line.startsWith('>')]);
            offset += line.length + 1;
        }
        return mask;
    }

    function inQuote(mask, i) {
        for (const [s, e, q] of mask) if (i >= s && i <= e) return q;
        return false;
    }

    function normMessage(m, i) {
        return {
            id: String(m.id || ''),
            nid: m.nid ? String(m.nid) : '',
            pubkey: String(m.pubkey || ''),
            author: String(m.author || ''),
            content: String(m.content || ''),
            at: Number(m.at) || 0,
            edited: !!m.edited,
            system: !!m.system,
            fileOffer: m.fileOffer && typeof m.fileOffer === 'object' ? m.fileOffer : null,
            order: i,
        };
    }

    function galleryItems(messages) {
        const media = [];
        const files = [];
        const links = [];
        (messages || []).forEach((raw, i) => {
            const m = normMessage(raw, i);
            if (m.system) return;
            const spoilers = spoilerRanges(m.content);
            const quote = quoteMask(m.content);
            const seen = new Set();
            let pos = 0;
            for (const tok of tokens(m.content)) {
                if (inQuote(quote, tok.index)) continue;
                if (isOnceParams(tok.params)) continue;
                if (seen.has(tok.base)) continue;
                seen.add(tok.base);
                const c = classify(tok);
                const item = {
                    mid: m.id,
                    nid: m.nid,
                    url: tok.base,
                    kind: c.kind,
                    name: c.note ? (c.kind === 'audio' ? 'voice' : 'round') : lastSegment(tok.base),
                    at: m.at,
                    author: m.author,
                    pubkey: m.pubkey,
                    spoiler: inRanges(spoilers, tok.index),
                    local: tok.local,
                    order: m.order,
                    pos: pos++,
                };
                if (c.tab === 'media') media.push(item);
                else if (c.tab === 'files') files.push(item);
                else links.push(item);
            }
            if (m.fileOffer && m.fileOffer.name) {
                files.push({
                    mid: m.id, nid: m.nid, url: '', kind: 'offer', name: String(m.fileOffer.name),
                    at: m.at, author: m.author, pubkey: m.pubkey, spoiler: false, local: false,
                    order: m.order, pos: pos++,
                });
            }
        });
        const sort = (a, b) => (b.at - a.at) || (b.order - a.order) || (a.pos - b.pos);
        const strip = (list) => list.sort(sort).map((x) => {
            const o = Object.assign({}, x);
            delete o.order;
            delete o.pos;
            return o;
        });
        return { media: strip(media), files: strip(files), links: strip(links) };
    }

    function pad(n, w) {
        return String(n).padStart(w || 2, '0');
    }

    function formatStamp(sec, offsetMin) {
        const d = new Date((Number(sec) || 0) * 1000 + (Number(offsetMin) || 0) * 60000);
        return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
    }

    function exportLineText(m, opts) {
        const t = opts.t;
        const names = opts.mediaNames || {};
        let text = m.content;
        const toks = tokens(text);
        for (let i = toks.length - 1; i >= 0; i--) {
            const tok = toks[i];
            let rep;
            if (isOnceParams(tok.params)) rep = tr(t, STRINGS.onceExported);
            else if (tok.local) rep = names[tok.base] ? 'media/' + names[tok.base] : tr(t, STRINGS.localMedia);
            else if (tok.params) rep = names[tok.base] ? `${tok.base} (media/${names[tok.base]})` : tok.base;
            else rep = names[tok.base] ? `${tok.base} (media/${names[tok.base]})` : tok.token;
            text = text.slice(0, tok.index) + rep + text.slice(tok.index + tok.length);
        }
        if (m.fileOffer && m.fileOffer.name && !text.trim()) text = String(m.fileOffer.name);
        if (m.edited) text = text + ' ' + tr(t, STRINGS.edited);
        return text;
    }

    function exportTranscript(opts) {
        const o = opts || {};
        const msgs = (o.messages || []).map(normMessage).filter((m) => !m.system);
        msgs.sort((a, b) => (a.at - b.at) || (a.order - b.order));
        const lines = [];
        lines.push(tr(o.t, STRINGS.exportTitle, { title: o.title || '' }));
        lines.push(tr(o.t, STRINGS.exportedAt, { time: formatStamp(Math.floor((o.exportedAtMs || 0) / 1000), o.offsetMin) }));
        lines.push('');
        for (const m of msgs) {
            const body = exportLineText(m, o).split('\n');
            lines.push(`[${formatStamp(m.at, o.offsetMin)}] ${m.author}: ${body[0]}`);
            for (const rest of body.slice(1)) lines.push('    ' + rest);
        }
        return lines.join('\n') + '\n';
    }

    function safeName(s) {
        const cleaned = String(s || '').replace(/[^A-Za-z0-9._-]+/g, '_').replace(/^[._]+/, '').slice(0, 60);
        return cleaned || 'file';
    }

    function exportMediaPlan(messages) {
        const out = [];
        const taken = new Set();
        const seen = new Set();
        const msgs = (messages || []).map(normMessage).filter((m) => !m.system);
        msgs.sort((a, b) => (a.at - b.at) || (a.order - b.order));
        for (const m of msgs) {
            for (const tok of tokens(m.content)) {
                if (isOnceParams(tok.params)) continue;
                if (seen.has(tok.base)) continue;
                const c = classify(tok);
                if (c.tab === 'links') continue;
                seen.add(tok.base);
                let stem;
                if (tok.local) stem = tok.base.slice('nymlocal:'.length);
                else stem = lastSegment(tok.base);
                let ext = extOf(stem);
                if (!ext && tok.params && tok.params.m) ext = extForMime(tok.params.m);
                let name = safeName(ext && extOf(stem) ? stem : (stem + (ext ? '.' + ext : '')));
                let n = out.length + 1;
                let candidate = pad(n, 3) + '-' + name;
                while (taken.has(candidate)) { n++; candidate = pad(n, 3) + '-' + name; }
                taken.add(candidate);
                out.push({ mid: m.id, url: tok.base, name: candidate, local: tok.local });
            }
        }
        return out;
    }

    function extForMime(mime) {
        const m = String(mime || '').toLowerCase().split(';')[0];
        const map = {
            'audio/mp4': 'm4a', 'audio/webm': 'weba', 'audio/ogg': 'ogg', 'audio/mpeg': 'mp3',
            'video/mp4': 'mp4', 'video/webm': 'webm', 'video/quicktime': 'mov',
            'image/jpeg': 'jpg', 'image/png': 'png', 'image/gif': 'gif', 'image/webp': 'webp',
        };
        return map[m] || '';
    }

    function exportFileName(title, nowMs, offsetMin, ext) {
        const slug = String(title || 'chat').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'chat';
        const stamp = formatStamp(Math.floor((nowMs || 0) / 1000), offsetMin).replace(/[-: ]/g, '');
        return `nymchat-${slug}-${stamp.slice(0, 8)}-${stamp.slice(8)}.${ext || 'txt'}`;
    }

    let CRC_TABLE = null;
    function crc32(bytes) {
        if (!CRC_TABLE) {
            CRC_TABLE = new Uint32Array(256);
            for (let n = 0; n < 256; n++) {
                let c = n;
                for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
                CRC_TABLE[n] = c >>> 0;
            }
        }
        let crc = 0xFFFFFFFF;
        for (let i = 0; i < bytes.length; i++) crc = CRC_TABLE[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
        return (crc ^ 0xFFFFFFFF) >>> 0;
    }

    function utf8(s) {
        return new TextEncoder().encode(String(s));
    }

    function dosTime(ms, offsetMin) {
        const d = new Date((Number(ms) || 0) + (Number(offsetMin) || 0) * 60000);
        const year = Math.max(1980, d.getUTCFullYear());
        const time = (d.getUTCHours() << 11) | (d.getUTCMinutes() << 5) | Math.floor(d.getUTCSeconds() / 2);
        const date = ((year - 1980) << 9) | ((d.getUTCMonth() + 1) << 5) | d.getUTCDate();
        return { time, date };
    }

    function zipStore(entries, atMs, offsetMin) {
        const { time, date } = dosTime(atMs, offsetMin);
        const parts = [];
        const central = [];
        let offset = 0;
        for (const e of entries) {
            const name = utf8(e.name);
            const data = (e.bytes && typeof e.bytes !== 'string' && ArrayBuffer.isView(e.bytes)) ? new Uint8Array(e.bytes.buffer, e.bytes.byteOffset, e.bytes.byteLength) : utf8(e.bytes || '');
            const crc = crc32(data);
            const local = new Uint8Array(30 + name.length);
            const lv = new DataView(local.buffer);
            lv.setUint32(0, 0x04034b50, true);
            lv.setUint16(4, 20, true);
            lv.setUint16(6, 0x0800, true);
            lv.setUint16(8, 0, true);
            lv.setUint16(10, time, true);
            lv.setUint16(12, date, true);
            lv.setUint32(14, crc, true);
            lv.setUint32(18, data.length, true);
            lv.setUint32(22, data.length, true);
            lv.setUint16(26, name.length, true);
            lv.setUint16(28, 0, true);
            local.set(name, 30);
            parts.push(local, data);
            const cen = new Uint8Array(46 + name.length);
            const cv = new DataView(cen.buffer);
            cv.setUint32(0, 0x02014b50, true);
            cv.setUint16(4, 20, true);
            cv.setUint16(6, 20, true);
            cv.setUint16(8, 0x0800, true);
            cv.setUint16(10, 0, true);
            cv.setUint16(12, time, true);
            cv.setUint16(14, date, true);
            cv.setUint32(16, crc, true);
            cv.setUint32(20, data.length, true);
            cv.setUint32(24, data.length, true);
            cv.setUint16(28, name.length, true);
            cv.setUint16(30, 0, true);
            cv.setUint16(32, 0, true);
            cv.setUint16(34, 0, true);
            cv.setUint16(36, 0, true);
            cv.setUint32(38, 0, true);
            cv.setUint32(42, offset, true);
            cen.set(name, 46);
            central.push(cen);
            offset += local.length + data.length;
        }
        let cenSize = 0;
        for (const c of central) cenSize += c.length;
        const end = new Uint8Array(22);
        const ev = new DataView(end.buffer);
        ev.setUint32(0, 0x06054b50, true);
        ev.setUint16(8, entries.length, true);
        ev.setUint16(10, entries.length, true);
        ev.setUint32(12, cenSize, true);
        ev.setUint32(16, offset, true);
        const all = parts.concat(central, [end]);
        let total = 0;
        for (const p of all) total += p.length;
        const out = new Uint8Array(total);
        let at = 0;
        for (const p of all) { out.set(p, at); at += p.length; }
        return out;
    }

    function savedEntry(msg, chat, nowMs) {
        const m = msg || {};
        if (hasOnce(m.content)) return { error: 'once' };
        const mid = String(m.id || '');
        const nid = m.nid ? String(m.nid) : '';
        const id = nid || mid;
        if (!id) return { error: 'missing' };
        let text = String(m.content || '');
        if (text.length > LIMITS.savedTextMax) text = text.slice(0, LIMITS.savedTextMax);
        const c = chat || {};
        return {
            entry: {
                id,
                mid,
                nid,
                chat: { t: c.t === 'dm' || c.t === 'group' ? c.t : 'channel', k: String(c.k || ''), n: String(c.n || '') },
                a: { pk: String(m.pubkey || ''), n: String(m.author || '') },
                text,
                at: Number(m.at) || 0,
                sv: Number(nowMs) || 0,
            },
        };
    }

    function validEntry(e) {
        return !!(e && typeof e === 'object' && typeof e.id === 'string' && e.id
            && e.chat && typeof e.chat === 'object' && typeof e.chat.k === 'string'
            && e.a && typeof e.a === 'object' && typeof e.text === 'string'
            && typeof e.sv === 'number' && isFinite(e.sv));
    }

    function emptySaved() {
        return { v: 1, items: [], removed: {} };
    }

    function normalizeSaved(raw) {
        const out = emptySaved();
        if (!raw || typeof raw !== 'object') return out;
        const items = Array.isArray(raw.items) ? raw.items : [];
        const byId = {};
        for (const e of items) {
            if (!validEntry(e)) continue;
            if (hasOnce(e.text)) continue;
            const prev = byId[e.id];
            if (!prev || e.sv > prev.sv) byId[e.id] = e;
        }
        const removed = {};
        if (raw.removed && typeof raw.removed === 'object' && !Array.isArray(raw.removed)) {
            for (const [k, v] of Object.entries(raw.removed)) {
                const n = Number(v);
                if (k && isFinite(n) && n > 0) removed[k] = n;
            }
        }
        out.items = Object.values(byId);
        out.removed = removed;
        return out;
    }

    function finishSaved(s, nowMs) {
        const removed = {};
        const cutoff = (Number(nowMs) || 0) - LIMITS.removedTtlMs;
        for (const [k, v] of Object.entries(s.removed)) if (v >= cutoff) removed[k] = v;
        let items = s.items.filter((e) => !(removed[e.id] >= e.sv));
        items.sort((a, b) => (b.sv - a.sv) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
        if (items.length > LIMITS.savedMax) items = items.slice(0, LIMITS.savedMax);
        let rk = Object.keys(removed);
        if (rk.length > LIMITS.removedMax) {
            rk.sort((a, b) => (removed[b] - removed[a]) || (a < b ? -1 : 1));
            const keep = {};
            for (const k of rk.slice(0, LIMITS.removedMax)) keep[k] = removed[k];
            return { v: 1, items, removed: keep };
        }
        return { v: 1, items, removed };
    }

    function mergeSaved(a, b, nowMs) {
        const x = normalizeSaved(a);
        const y = normalizeSaved(b);
        const byId = {};
        for (const e of x.items.concat(y.items)) {
            const prev = byId[e.id];
            if (!prev || e.sv > prev.sv) byId[e.id] = e;
        }
        const removed = Object.assign({}, x.removed);
        for (const [k, v] of Object.entries(y.removed)) if (!(removed[k] >= v)) removed[k] = v;
        return finishSaved({ v: 1, items: Object.values(byId), removed }, nowMs);
    }

    function addSaved(state, entry, nowMs) {
        const s = normalizeSaved(state);
        if (!validEntry(entry) || hasOnce(entry.text)) return finishSaved(s, nowMs);
        s.items = s.items.filter((e) => e.id !== entry.id);
        s.items.push(entry);
        if (s.removed[entry.id] != null && s.removed[entry.id] < entry.sv) delete s.removed[entry.id];
        return finishSaved(s, nowMs);
    }

    function removeSaved(state, id, nowMs) {
        const s = normalizeSaved(state);
        s.items = s.items.filter((e) => e.id !== id);
        s.removed[id] = Math.max(Number(nowMs) || 0, s.removed[id] || 0);
        return finishSaved(s, nowMs);
    }

    function isSaved(state, id) {
        const s = normalizeSaved(state);
        return s.items.some((e) => e.id === id);
    }

    function trimSavedPayload(p) {
        const s = p && p.savedMessages;
        if (!s || !Array.isArray(s.items)) return false;
        const rk = s.removed ? Object.keys(s.removed) : [];
        if (rk.length > 50) {
            rk.sort((a, b) => s.removed[a] - s.removed[b]);
            for (const k of rk.slice(0, Math.ceil(rk.length / 4))) delete s.removed[k];
            return true;
        }
        if (s.items.length <= 1) return false;
        s.items = s.items.slice(0, s.items.length - Math.max(1, Math.ceil(s.items.length * 0.1)));
        return true;
    }

    function recordEdit(rec, prevText, newText, createdAt, editAt) {
        const prev = String(prevText == null ? '' : prevText);
        const next = String(newText == null ? '' : newText);
        const base = rec && Array.isArray(rec.versions) ? rec : { versions: [], editedAt: 0 };
        if (prev === next) return base;
        const versions = base.versions.slice();
        const prevAt = base.editedAt || Number(createdAt) || 0;
        const last = versions[versions.length - 1];
        if (!last || last.text !== prev) versions.push({ text: prev, at: prevAt });
        while (versions.length > LIMITS.editVersionsMax) versions.shift();
        return { versions, editedAt: Math.max(Number(editAt) || 0, prevAt) };
    }

    function editTimeline(rec, currentText) {
        const r = rec && Array.isArray(rec.versions) ? rec : { versions: [], editedAt: 0 };
        const out = r.versions.map((v) => ({ text: v.text, at: v.at, current: false }));
        out.push({ text: String(currentText || ''), at: r.editedAt || 0, current: true });
        return out.reverse();
    }

    function pruneEditStore(store) {
        const keys = Object.keys(store || {});
        if (keys.length <= LIMITS.editMessagesMax) return store;
        keys.sort((a, b) => ((store[a] && store[a].editedAt) || 0) - ((store[b] && store[b].editedAt) || 0));
        const out = {};
        for (const k of keys.slice(keys.length - LIMITS.editMessagesMax)) out[k] = store[k];
        return out;
    }

    function keepTags(ids, kept, recipient, groupId) {
        const tags = [];
        if (recipient) tags.push(['p', recipient]);
        for (const id of ids || []) if (RX_KEEP_ID.test(String(id))) tags.push(['target', String(id)]);
        tags.push(['receipt', kept ? RECEIPT_KEEP : RECEIPT_UNKEEP]);
        if (groupId) tags.push(['g', String(groupId)]);
        return tags;
    }

    function parseKeep(rumor) {
        const tags = (rumor && Array.isArray(rumor.tags)) ? rumor.tags : [];
        let type = null;
        let groupId = null;
        const ids = [];
        for (const t of tags) {
            if (!Array.isArray(t) || typeof t[1] !== 'string') continue;
            if (t[0] === 'receipt') type = t[1];
            else if (t[0] === 'target' && RX_KEEP_ID.test(t[1])) ids.push(t[1]);
            else if (t[0] === 'g') groupId = t[1];
        }
        if (type !== RECEIPT_KEEP && type !== RECEIPT_UNKEEP) return null;
        if (!ids.length) return null;
        return { ids, kept: type === RECEIPT_KEEP, groupId };
    }

    function applyKeep(state, id, kept, at, by) {
        const s = state || {};
        const cur = s[id];
        const ts = Number(at) || 0;
        if (cur) {
            if (ts < cur.at) return false;
            if (ts === cur.at) {
                if (cur.k === !!kept) return false;
                if (!kept) return false;
            }
        }
        s[id] = { k: !!kept, at: ts, by: String(by || '') };
        return true;
    }

    function isKept(state, id) {
        const v = state && id ? state[id] : null;
        return !!(v && v.k);
    }

    function pruneKeep(state) {
        const keys = Object.keys(state || {});
        if (keys.length <= LIMITS.keepMax) return state;
        keys.sort((a, b) => (state[a].at || 0) - (state[b].at || 0));
        const out = {};
        for (const k of keys.slice(keys.length - LIMITS.keepMax)) out[k] = state[k];
        return out;
    }

    function isExpired(expiresAt, kept, nowSec) {
        const e = Number(expiresAt) || 0;
        if (!e || kept) return false;
        return e <= (Number(nowSec) || 0);
    }

    function keepAvailable(msg) {
        const m = msg || {};
        if (!m.nid || !RX_KEEP_ID.test(String(m.nid))) return false;
        if (m.surface !== 'dm' && m.surface !== 'group') return false;
        return !!(Number(m.expiresAt) > 0 || m.kept);
    }

    function meshKeepId(id, kept) {
        return (kept ? MESH_KEEP_PREFIX : MESH_UNKEEP_PREFIX) + id;
    }

    function parseMeshKeepId(s) {
        if (typeof s !== 'string') return null;
        let kept;
        let rest;
        if (s.indexOf(MESH_KEEP_PREFIX) === 0) { kept = true; rest = s.slice(MESH_KEEP_PREFIX.length); }
        else if (s.indexOf(MESH_UNKEEP_PREFIX) === 0) { kept = false; rest = s.slice(MESH_UNKEEP_PREFIX.length); }
        else return null;
        return RX_KEEP_ID.test(rest) ? { id: rest, kept } : null;
    }

    function replyPrivatelyAllowed(msg) {
        const m = msg || {};
        if (m.surface !== 'group' && m.surface !== 'channel') return false;
        if (!m.pubkey || m.system) return false;
        if (m.self && m.pubkey === m.self) return false;
        return true;
    }

    function wrapExpiration(tags) {
        for (const t of (tags || [])) {
            if (Array.isArray(t) && t[0] === 'expiration' && /^\d{1,12}$/.test(String(t[1] || ''))) return Number(t[1]);
        }
        return 0;
    }

    G.NymChatTools = {
        LIMITS, STRINGS, SAVED_DTAG, SAVED_KEY, SAVED_PENDING_KEY, EDITS_KEY, KEEP_KEY,
        RECEIPT_KEEP, RECEIPT_UNKEEP, MESH_KEEP_PREFIX, MESH_UNKEEP_PREFIX,
        hasOnce, tokens, galleryItems, spoilerRanges,
        formatStamp, exportTranscript, exportMediaPlan, exportFileName, extForMime,
        crc32, zipStore,
        savedEntry, emptySaved, normalizeSaved, mergeSaved, addSaved, removeSaved, isSaved, trimSavedPayload,
        recordEdit, editTimeline, pruneEditStore,
        keepTags, parseKeep, applyKeep, isKept, pruneKeep, isExpired, keepAvailable, meshKeepId, parseMeshKeepId,
        replyPrivatelyAllowed, wrapExpiration,
    };
})();
