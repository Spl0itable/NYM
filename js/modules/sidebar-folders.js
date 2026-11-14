(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const LIMITS = Object.freeze({
        folders: 20,
        perFolder: 50,
        total: 100,
        nameMax: 32,
        removedMax: 100,
        deletedMax: 20,
        layoutMax: 23,
        ttlMs: 180 * 24 * 60 * 60 * 1000,
        rumorOverhead: 256,
        wrapLimitPq2: 16384,
        wrapLimitClassic: 28672,
        reserve: 1024,
        oldRefMax: 64,
    });

    const KEYS = Object.freeze({
        dTag: 'nymchat-folders',
        payload: 'sidebarFolders',
        section: 'folders',
        state: 'nym_sidebar_folders:',
        pending: 'nym_sidebar_folders_pending:',
        collapsed: 'nym_sidebar_folder_collapsed:',
    });

    const STRINGS = Object.freeze({
        newFolder: 'New folder',
        folderName: 'Folder name',
        create: 'Create',
        addChats: 'Add chats',
        searchChats: 'Search chats',
        done: 'Done',
        cancel: 'Cancel',
        renameFolder: 'Rename folder',
        rename: 'Rename',
        deleteFolder: 'Delete folder',
        deleteConfirm: 'Delete this folder? Its chats go back to their sections.',
        del: 'Delete',
        deleted: 'Folder deleted',
        addTo: 'Add to folder…',
        moveTo: 'Move to folder…',
        removeFrom: 'Remove from folder',
        added: 'Added to {folder}',
        moved: 'Moved to {folder}',
        removedFrom: 'Removed from {folder}',
        inFolder: 'In {folder}',
        options: 'Folder options',
        moveUp: 'Move folder up',
        moveDown: 'Move folder down',
        expand: 'Expand folder',
        collapse: 'Collapse folder',
        empty: 'No chats to show',
        unread: '{n} unread',
        headLabel: '{name}, folder',
        headLabelUnread: '{name}, folder, {n} unread',
        capFolders: 'You can have up to {n} folders.',
        capItems: 'A folder can hold up to {n} chats.',
        capTotal: 'Folders can hold up to {n} chats in all.',
        nameLong: 'Folder names can be up to {n} characters.',
        nameEmpty: 'Enter a folder name.',
        capSize: 'Folders are full. Remove some chats to make room.',
    });

    const BUILTIN = Object.freeze(['channels', 'pms', 'nyms']);
    const RX_FID = /^[a-z0-9]{12}$/;
    const RX_HEX64 = /^[0-9a-f]{64}$/;
    const RX_GROUP = /^[0-9a-f]{16,64}$/;
    const isChannelName = (s) => G.NymChannelName.isChannelName(s);
    const ID_CHARS = 'abcdefghijklmnopqrstuvwxyz0123456789';
    const REMOVED = '';

    function stamp(v) {
        return typeof v === 'number' && isFinite(v) && v > 0 ? Math.floor(v) : 0;
    }

    function cmpStr(a, b) {
        return a < b ? -1 : a > b ? 1 : 0;
    }

    function fill(s, vars) {
        let out = String(s);
        if (vars) for (const k of Object.keys(vars)) out = out.split('{' + k + '}').join(String(vars[k]));
        return out;
    }

    function isObj(v) {
        return !!v && typeof v === 'object' && !Array.isArray(v);
    }

    function validRef(k) {
        const s = typeof k === 'string' ? k : '';
        if (s.indexOf('d:') === 0) return RX_HEX64.test(s.slice(2));
        if (s.indexOf('g:') === 0) return RX_GROUP.test(s.slice(2));
        if (s.indexOf('c:') === 0) return isChannelName(s.slice(2));
        return false;
    }

    function validFid(id) {
        return typeof id === 'string' && RX_FID.test(id);
    }

    function validToken(t) {
        if (BUILTIN.indexOf(t) >= 0) return true;
        return typeof t === 'string' && t.indexOf('f:') === 0 && validFid(t.slice(2));
    }

    function codePoints(s) {
        const out = [];
        for (let i = 0; i < s.length; i++) {
            const c = s.charCodeAt(i);
            if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
                const d = s.charCodeAt(i + 1);
                if (d >= 0xDC00 && d <= 0xDFFF) { out.push(((c - 0xD800) << 10) + (d - 0xDC00) + 0x10000); i++; continue; }
            }
            out.push(c);
        }
        return out;
    }

    function isSpace(cp) {
        return cp === 0x20 || (cp >= 0x09 && cp <= 0x0D) || cp === 0x85 || cp === 0xA0 || cp === 0x1680
            || (cp >= 0x2000 && cp <= 0x200A) || cp === 0x2028 || cp === 0x2029 || cp === 0x202F
            || cp === 0x205F || cp === 0x3000 || cp === 0xFEFF;
    }

    function isDropped(cp) {
        return cp <= 0x1F || (cp >= 0x7F && cp <= 0x9F) || cp === 0x200E || cp === 0x200F
            || (cp >= 0x202A && cp <= 0x202E) || (cp >= 0x2066 && cp <= 0x2069) || (cp >= 0xD800 && cp <= 0xDFFF);
    }

    function cleanCodePoints(raw) {
        const out = [];
        let gap = false;
        for (const cp of codePoints(typeof raw === 'string' ? raw : '')) {
            if (isSpace(cp)) { gap = true; continue; }
            if (isDropped(cp)) continue;
            if (gap && out.length) out.push(0x20);
            gap = false;
            out.push(cp);
        }
        return out;
    }

    function cleanFolderName(raw) {
        const cps = cleanCodePoints(raw);
        if (!cps.length) return { name: '', error: 'name' };
        if (cps.length > LIMITS.nameMax) return { name: '', error: 'long' };
        return { name: String.fromCodePoint(...cps), error: null };
    }

    function storedName(raw) {
        const cps = cleanCodePoints(raw).slice(0, LIMITS.nameMax);
        while (cps.length && cps[cps.length - 1] === 0x20) cps.pop();
        return cps.length ? String.fromCodePoint(...cps) : '';
    }

    function folderIdFrom(bytes) {
        let id = '';
        const b = bytes || [];
        for (let i = 0; i < b.length && id.length < 12; i++) {
            const v = b[i] & 255;
            if (v < 252) id += ID_CHARS[v % 36];
        }
        return id.length === 12 ? id : '';
    }

    function emptyFolders() {
        return { v: 1, folders: {}, removed: {}, deleted: {}, layout: [], lt: 0 };
    }

    function sortedKeys(o) {
        return Object.keys(o).sort(cmpStr);
    }

    function finish(s, nowMs) {
        const now = stamp(nowMs);
        const cutoff = now > 0 ? now - LIMITS.ttlMs : 0;
        const deleted = {};
        for (const id of sortedKeys(s.deleted)) {
            const at = s.deleted[id];
            if (cutoff > 0 && at < cutoff) continue;
            deleted[id] = at;
        }
        const best = new Map();
        const claim = (ref, who, at) => {
            const cur = best.get(ref);
            if (!cur || at > cur.at) best.set(ref, { at, who: [who] });
            else if (at === cur.at && cur.who.indexOf(who) < 0) cur.who.push(who);
        };
        for (const id of sortedKeys(s.folders)) {
            const items = s.folders[id].items;
            for (const ref of Object.keys(items)) claim(ref, id, items[ref]);
        }
        for (const ref of Object.keys(s.removed)) claim(ref, REMOVED, s.removed[ref]);
        const folders = {};
        for (const id of sortedKeys(s.folders)) {
            if (deleted[id] !== undefined) continue;
            const f = s.folders[id];
            folders[id] = { name: f.name, nt: f.nt, at: f.at, items: {} };
        }
        const removed = {};
        for (const ref of [...best.keys()].sort(cmpStr)) {
            const c = best.get(ref);
            const who = c.who.length === 1 ? c.who[0] : REMOVED;
            if (who !== REMOVED && folders[who]) folders[who].items[ref] = c.at;
            else if (!(cutoff > 0 && c.at < cutoff)) removed[ref] = c.at;
        }
        const layout = [];
        for (const t of s.layout) {
            if (layout.length >= LIMITS.layoutMax) break;
            if (!validToken(t) || layout.indexOf(t) >= 0) continue;
            if (t.indexOf('f:') === 0 && deleted[t.slice(2)] !== undefined) continue;
            layout.push(t);
        }
        return fitBudget({ v: 1, folders, removed: keepNewest(removed, LIMITS.removedMax), deleted: keepNewest(deleted, LIMITS.deletedMax), layout, lt: stamp(s.lt) });
    }

    function keepNewest(o, max) {
        const keys = Object.keys(o);
        if (keys.length <= max) return o;
        const out = {};
        for (const k of keys.sort((a, b) => (o[b] - o[a]) || cmpStr(a, b)).slice(0, max).sort(cmpStr)) out[k] = o[k];
        return out;
    }

    function stateBytes(s) {
        return rumorBytes({ [KEYS.payload]: s });
    }

    function fitBudget(s) {
        let bytes = stateBytes(s);
        if (bytes <= LIMITS.wrapLimitPq2) return s;
        const seen = liveBytes(oldBuildView(s));
        const budget = LIMITS.wrapLimitPq2 + liveBytes(s) - seen;
        if (bytes <= budget || seen > LIMITS.wrapLimitPq2) return s;
        const tombs = [];
        for (const k of Object.keys(s.removed)) tombs.push({ m: s.removed, k, at: s.removed[k], o: 0 });
        for (const k of Object.keys(s.deleted)) tombs.push({ m: s.deleted, k, at: s.deleted[k], o: 1 });
        tombs.sort((a, b) => (a.at - b.at) || (a.o - b.o) || cmpStr(a.k, b.k));
        for (const t of tombs) {
            if (bytes <= budget) break;
            delete t.m[t.k];
            bytes = stateBytes(s);
        }
        return s;
    }

    function liveBytes(s) {
        return stateBytes({ v: 1, folders: s.folders, removed: {}, deleted: {}, layout: s.layout, lt: s.lt });
    }

    function hasRoom(s) {
        return liveBytes(s) <= LIMITS.wrapLimitPq2 - LIMITS.reserve;
    }

    function rawState(raw) {
        const s = emptyFolders();
        if (!isObj(raw)) return s;
        if (isObj(raw.folders)) {
            for (const id of Object.keys(raw.folders)) {
                const f = raw.folders[id];
                if (!validFid(id) || !isObj(f)) continue;
                const name = storedName(f.name);
                if (!name) continue;
                const items = {};
                if (isObj(f.items)) {
                    for (const ref of Object.keys(f.items)) {
                        const at = stamp(f.items[ref]);
                        if (validRef(ref) && at) items[ref] = at;
                    }
                }
                s.folders[id] = { name, nt: stamp(f.nt), at: stamp(f.at), items };
            }
        }
        if (isObj(raw.removed)) {
            for (const ref of Object.keys(raw.removed)) {
                const at = stamp(raw.removed[ref]);
                if (validRef(ref) && at) s.removed[ref] = at;
            }
        }
        if (isObj(raw.deleted)) {
            for (const id of Object.keys(raw.deleted)) {
                const at = stamp(raw.deleted[id]);
                if (validFid(id) && at) s.deleted[id] = at;
            }
        }
        if (Array.isArray(raw.layout)) s.layout = raw.layout.filter((t) => typeof t === 'string');
        s.lt = stamp(raw.lt);
        return s;
    }

    function normalizeFolders(raw, nowMs) {
        return finish(rawState(raw), nowMs);
    }

    function clone(s) {
        const out = { v: 1, folders: {}, removed: Object.assign({}, s.removed), deleted: Object.assign({}, s.deleted), layout: s.layout.slice(), lt: s.lt };
        for (const id of Object.keys(s.folders)) {
            const f = s.folders[id];
            out.folders[id] = { name: f.name, nt: f.nt, at: f.at, items: Object.assign({}, f.items) };
        }
        return out;
    }

    function folderOf(state, ref) {
        const s = normalizeFolders(state);
        for (const id of Object.keys(s.folders)) if (s.folders[id].items[ref] !== undefined) return id;
        return '';
    }

    function folderList(state) {
        const s = normalizeFolders(state);
        return layoutOf(s).filter((t) => t.indexOf('f:') === 0).map((t) => {
            const id = t.slice(2);
            const f = s.folders[id];
            return { id, name: f.name, refs: Object.keys(f.items).sort(cmpStr) };
        });
    }

    function itemCount(s) {
        let n = 0;
        for (const id of Object.keys(s.folders)) n += Object.keys(s.folders[id].items).length;
        return n;
    }

    function prevStamp(s, ref) {
        let at = s.removed[ref] || 0;
        for (const id of Object.keys(s.folders)) {
            const v = s.folders[id].items[ref];
            if (v > at) at = v;
        }
        return at;
    }

    function layoutOf(state) {
        const s = state && state.v === 1 && isObj(state.folders) && Array.isArray(state.layout) ? state : normalizeFolders(state);
        const out = [];
        for (const t of s.layout) {
            if (out.indexOf(t) >= 0) continue;
            if (BUILTIN.indexOf(t) >= 0 || (t.indexOf('f:') === 0 && s.folders[t.slice(2)])) out.push(t);
        }
        for (const b of BUILTIN) if (out.indexOf(b) < 0) out.push(b);
        const missing = Object.keys(s.folders).filter((id) => out.indexOf('f:' + id) < 0)
            .sort((a, b) => ((s.folders[a].at || 0) - (s.folders[b].at || 0)) || cmpStr(a, b));
        const at = out.indexOf('channels');
        out.splice(at, 0, ...missing.map((id) => 'f:' + id));
        return out;
    }

    function builtinOrder(applied) {
        const out = [];
        for (const t of (Array.isArray(applied) ? applied : [])) if (BUILTIN.indexOf(t) >= 0 && out.indexOf(t) < 0) out.push(t);
        for (const b of BUILTIN) if (out.indexOf(b) < 0) out.push(b);
        return out;
    }

    function effectiveLayout(state, applied) {
        const order = builtinOrder(applied);
        let i = 0;
        return layoutOf(state).map((t) => (BUILTIN.indexOf(t) >= 0 ? order[i++] : t));
    }

    function bump(prev, nowMs) {
        return Math.max(stamp(nowMs), stamp(prev) + 1);
    }

    function cleanRefs(refs) {
        const out = [];
        for (const r of (Array.isArray(refs) ? refs : [])) {
            if (!validRef(r)) return null;
            if (out.indexOf(r) < 0) out.push(r);
        }
        return out;
    }

    function folderCreate(state, id, name, nowMs, refs, applied) {
        const s = normalizeFolders(state, nowMs);
        if (!validFid(id) || s.folders[id] || s.deleted[id] !== undefined) return { state: s, error: 'invalid' };
        const n = cleanFolderName(name);
        if (n.error) return { state: s, error: n.error };
        if (Object.keys(s.folders).length >= LIMITS.folders) return { state: s, error: 'folders' };
        const list = refs === undefined ? [] : cleanRefs(refs);
        if (!list) return { state: s, error: 'invalid' };
        const t = clone(s);
        const at = Math.max(stamp(nowMs), 1);
        const layout = Array.isArray(applied) ? effectiveLayout(s, applied) : layoutOf(s);
        t.folders[id] = { name: n.name, nt: at, at, items: {} };
        layout.splice(layout.indexOf('channels'), 0, 'f:' + id);
        t.layout = layout;
        t.lt = bump(s.lt, nowMs);
        const created = finish(t, nowMs);
        if (!hasRoom(created)) return { state: s, error: 'size' };
        if (!list.length) return { state: created, error: null };
        const r = folderAdd(created, id, list, nowMs);
        return r.error ? { state: s, error: r.error } : r;
    }

    function folderRename(state, id, name, nowMs) {
        const s = normalizeFolders(state, nowMs);
        if (!s.folders[id]) return { state: s, error: 'invalid' };
        const n = cleanFolderName(name);
        if (n.error) return { state: s, error: n.error };
        if (n.name === s.folders[id].name) return { state: s, error: null };
        const t = clone(s);
        t.folders[id].name = n.name;
        t.folders[id].nt = bump(s.folders[id].nt, nowMs);
        const next = finish(t, nowMs);
        if (!hasRoom(next) && liveBytes(next) > liveBytes(s)) return { state: s, error: 'size' };
        return { state: next, error: null };
    }

    function folderAdd(state, id, refs, nowMs) {
        const s = normalizeFolders(state, nowMs);
        if (!s.folders[id]) return { state: s, error: 'invalid' };
        const list = cleanRefs(refs);
        if (!list) return { state: s, error: 'invalid' };
        const fresh = list.filter((r) => s.folders[id].items[r] === undefined);
        if (!fresh.length) return { state: s, error: null };
        if (Object.keys(s.folders[id].items).length + fresh.length > LIMITS.perFolder) return { state: s, error: 'cap' };
        const outside = fresh.filter((r) => !folderOfState(s, r)).length;
        if (itemCount(s) + outside > LIMITS.total) return { state: s, error: 'total' };
        const t = clone(s);
        for (const r of fresh) {
            const at = bump(prevStamp(s, r), nowMs);
            for (const other of Object.keys(t.folders)) delete t.folders[other].items[r];
            delete t.removed[r];
            t.folders[id].items[r] = at;
        }
        const next = finish(t, nowMs);
        if (!hasRoom(next)) return { state: s, error: 'size' };
        return { state: next, error: null };
    }

    function folderOfState(s, ref) {
        for (const id of Object.keys(s.folders)) if (s.folders[id].items[ref] !== undefined) return id;
        return '';
    }

    function folderRemove(state, id, refs, nowMs) {
        const s = normalizeFolders(state, nowMs);
        if (!s.folders[id]) return { state: s, error: 'invalid' };
        const list = cleanRefs(refs);
        if (!list) return { state: s, error: 'invalid' };
        const t = clone(s);
        let changed = false;
        for (const r of list) {
            const at = s.folders[id].items[r];
            if (at === undefined) continue;
            delete t.folders[id].items[r];
            t.removed[r] = bump(at, nowMs);
            changed = true;
        }
        return { state: changed ? finish(t, nowMs) : s, error: null };
    }

    function folderDelete(state, id, nowMs) {
        const s = normalizeFolders(state, nowMs);
        if (!s.folders[id]) return { state: s, error: 'invalid' };
        const t = clone(s);
        for (const r of Object.keys(s.folders[id].items)) t.removed[r] = bump(s.folders[id].items[r], nowMs);
        delete t.folders[id];
        t.deleted[id] = Math.max(stamp(nowMs), 1);
        t.layout = layoutOf(s).filter((x) => x !== 'f:' + id);
        t.lt = bump(s.lt, nowMs);
        return { state: finish(t, nowMs), error: null };
    }

    function folderRestore(state, id, name, refs, index, nowMs) {
        const r = folderCreate(state, id, name, nowMs);
        if (r.error) return r;
        let s = r.state;
        const list = cleanRefs(refs) || [];
        if (list.length) {
            const a = folderAdd(s, id, list, nowMs);
            if (a.error) return { state: normalizeFolders(state, nowMs), error: a.error };
            s = a.state;
        }
        const layout = layoutOf(s).filter((x) => x !== 'f:' + id);
        const at = Math.max(0, Math.min(layout.length, Math.floor(typeof index === 'number' && isFinite(index) ? index : layout.indexOf('channels'))));
        layout.splice(at, 0, 'f:' + id);
        const t = clone(s);
        t.layout = layout;
        t.lt = bump(s.lt, nowMs);
        return { state: finish(t, nowMs), error: null };
    }

    function layoutMove(state, token, delta, nowMs, applied) {
        const s = normalizeFolders(state, nowMs);
        const layout = effectiveLayout(s, applied);
        const i = layout.indexOf(token);
        const j = i + Math.trunc(typeof delta === 'number' && isFinite(delta) ? delta : 0);
        if (i < 0 || j < 0 || j >= layout.length || i === j) return { state: s, error: 'edge', layout };
        layout.splice(i, 1);
        layout.splice(j, 0, token);
        const t = clone(s);
        t.layout = layout;
        t.lt = bump(s.lt, nowMs);
        return { state: finish(t, nowMs), error: null, layout };
    }

    function layoutSet(state, layout, nowMs) {
        const s = normalizeFolders(state, nowMs);
        const next = (Array.isArray(layout) ? layout : []).filter(validToken);
        if (JSON.stringify(layoutOf(Object.assign({}, s, { layout: next }))) === JSON.stringify(layoutOf(s))) return s;
        const t = clone(s);
        t.layout = next;
        t.lt = bump(s.lt, nowMs);
        return finish(t, nowMs);
    }

    function mergeFolders(a, b, nowMs) {
        const x = normalizeFolders(a, nowMs);
        const y = normalizeFolders(b, nowMs);
        const t = clone(x);
        for (const id of Object.keys(y.folders)) {
            const f = y.folders[id];
            const g = t.folders[id];
            if (!g) { t.folders[id] = { name: f.name, nt: f.nt, at: f.at, items: Object.assign({}, f.items) }; continue; }
            if (f.nt > g.nt || (f.nt === g.nt && cmpStr(f.name, g.name) > 0)) g.name = f.name;
            g.nt = Math.max(g.nt, f.nt);
            g.at = g.at && f.at ? Math.min(g.at, f.at) : (g.at || f.at);
            for (const r of Object.keys(f.items)) if (!(g.items[r] >= f.items[r])) g.items[r] = f.items[r];
        }
        for (const r of Object.keys(y.removed)) if (!(t.removed[r] >= y.removed[r])) t.removed[r] = y.removed[r];
        for (const id of Object.keys(y.deleted)) if (!(t.deleted[id] >= y.deleted[id])) t.deleted[id] = y.deleted[id];
        if (y.lt > x.lt || (y.lt === x.lt && JSON.stringify(y.layout) > JSON.stringify(x.layout))) t.layout = y.layout.slice();
        t.lt = Math.max(x.lt, y.lt);
        return finish(t, nowMs);
    }

    function oldBuildsSee(ref) {
        return ref.indexOf('c:') !== 0 || codePoints(ref.slice(2)).length <= LIMITS.oldRefMax;
    }

    function oldBuildView(s) {
        const folders = {};
        for (const id of Object.keys(s.folders)) {
            const f = s.folders[id];
            const items = {};
            for (const ref of Object.keys(f.items)) if (oldBuildsSee(ref)) items[ref] = f.items[ref];
            folders[id] = { name: f.name, nt: f.nt, at: f.at, items };
        }
        return { v: 1, folders, removed: {}, deleted: {}, layout: s.layout, lt: s.lt };
    }

    function capRepair(state, nowMs) {
        let s = normalizeFolders(state, nowMs);
        let changed = false;
        const ids = Object.keys(s.folders).sort((a, b) => (s.folders[a].at - s.folders[b].at) || cmpStr(a, b));
        for (const id of ids.slice(LIMITS.folders)) { s = folderDelete(s, id, nowMs).state; changed = true; }
        const newest = (list) => list.sort((p, q) => (q.at - p.at) || cmpStr(q.ref, p.ref));
        for (const id of Object.keys(s.folders)) {
            const items = s.folders[id].items;
            const list = newest(Object.keys(items).filter(oldBuildsSee).map((ref) => ({ ref, at: items[ref] })));
            const extra = list.length - LIMITS.perFolder;
            if (extra > 0) { s = folderRemove(s, id, list.slice(0, extra).map((e) => e.ref), nowMs).state; changed = true; }
        }
        const all = [];
        for (const id of Object.keys(s.folders)) for (const ref of Object.keys(s.folders[id].items).filter(oldBuildsSee)) all.push({ id, ref, at: s.folders[id].items[ref] });
        const over = all.length - LIMITS.total;
        if (over > 0) {
            for (const e of newest(all).slice(0, over)) s = folderRemove(s, e.id, [e.ref], nowMs).state;
            changed = true;
        }
        for (let guard = 0; liveBytes(oldBuildView(s)) > LIMITS.wrapLimitPq2 && guard < LIMITS.total; guard++) {
            const live = [];
            for (const id of Object.keys(s.folders)) for (const ref of Object.keys(s.folders[id].items).filter(oldBuildsSee)) live.push({ id, ref, at: s.folders[id].items[ref] });
            if (!live.length) break;
            const e = newest(live)[0];
            s = folderRemove(s, e.id, [e.ref], nowMs).state;
            changed = true;
        }
        return { state: s, changed };
    }

    function folderSort(refs, ctx) {
        const pins = (ctx && Array.isArray(ctx.pins)) ? ctx.pins : [];
        const act = (ctx && isObj(ctx.activity)) ? ctx.activity : {};
        const pos = new Map();
        pins.forEach((k, i) => { if (!pos.has(k)) pos.set(k, i); });
        const val = (r) => (typeof act[r] === 'number' && isFinite(act[r]) ? act[r] : 0);
        return (Array.isArray(refs) ? refs.slice() : []).sort((a, b) => {
            const pa = pos.has(a) ? pos.get(a) : -1;
            const pb = pos.has(b) ? pos.get(b) : -1;
            if (pa >= 0 && pb >= 0 && pa !== pb) return pa - pb;
            if (pa >= 0 && pb < 0) return -1;
            if (pb >= 0 && pa < 0) return 1;
            return (val(b) - val(a)) || cmpStr(a, b);
        });
    }

    function folderUnread(counts) {
        let n = 0;
        for (const c of (Array.isArray(counts) ? counts : [])) {
            if (typeof c === 'number' && isFinite(c) && c > 0) n += Math.floor(c);
            if (n > 99) { n = 100; break; }
        }
        return { n, label: n <= 0 ? '' : n > 99 ? '99+' : String(n) };
    }

    function visibleRefs(refs, ctx) {
        const c = ctx || {};
        const set = (k) => new Set(Array.isArray(c[k]) ? c[k] : []);
        const exists = set('exists'), hidden = set('hidden'), blocked = set('blocked'), locked = set('locked'), filtered = set('filtered');
        return (Array.isArray(refs) ? refs : []).filter((r) => {
            if (!validRef(r) || !exists.has(r) || locked.has(r) || filtered.has(r) || blocked.has(r)) return false;
            if (r.indexOf('c:') === 0) {
                if (c.pmOnly) return false;
                if (hidden.has(r) && c.active !== r) return false;
            }
            return true;
        });
    }

    function navRefs(state, collapsed, visibleOf) {
        const s = normalizeFolders(state);
        const closed = new Set(Array.isArray(collapsed) ? collapsed : []);
        const out = [];
        for (const f of folderList(s)) {
            if (closed.has(f.id)) continue;
            const refs = typeof visibleOf === 'function' ? visibleOf(f.refs) : f.refs;
            for (const r of refs) out.push(f.id + ' ' + r);
        }
        return out;
    }

    function publishable(state) {
        return normalizeFolders(state);
    }

    function trimFoldersPayload(p) {
        const s = p && p[KEYS.payload];
        if (!isObj(s)) return false;
        for (const k of ['removed', 'deleted']) {
            const o = s[k];
            if (!isObj(o)) continue;
            const keys = Object.keys(o);
            if (!keys.length) continue;
            keys.sort((a, b) => (o[a] - o[b]) || cmpStr(a, b));
            for (const x of keys.slice(0, Math.ceil(keys.length / 4))) delete o[x];
            return true;
        }
        return false;
    }

    function utf8Len(str) {
        let n = 0;
        for (const cp of codePoints(str)) n += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
        return n;
    }

    function rumorBytes(payload) {
        return utf8Len(JSON.stringify(JSON.stringify(payload))) + LIMITS.rumorOverhead;
    }

    function hasFolders(state) {
        return Object.keys(normalizeFolders(state).folders).length > 0;
    }

    G.NymFolders = {
        LIMITS, KEYS, STRINGS, BUILTIN,
        fill, validRef, validFid, cleanFolderName, folderIdFrom, emptyFolders, normalizeFolders,
        folderOf, folderList, layoutOf, effectiveLayout, builtinOrder,
        folderCreate, folderRename, folderAdd, folderRemove, folderDelete, folderRestore, layoutMove, layoutSet,
        mergeFolders, capRepair, folderSort, folderUnread, visibleRefs, navRefs,
        publishable, trimFoldersPayload, rumorBytes, liveBytes, hasFolders,
    };
})();
