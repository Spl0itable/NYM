(function () {
    if (typeof NYM === 'undefined') return;

    const M = () => window.NymSendAs;
    const A = () => window.NymAccounts;
    const T = () => window.NostrTools;
    const HEX = /^[0-9a-f]{64}$/;
    const OK_MS = 20000;
    const OPEN_MS = 8000;
    const UPSTREAM_MS = 6000;
    const GEO_RESEND_MS = 2000;
    const REPLAY_MS = 10000;
    const IDLE_MS = 60000;
    const ATTEMPTS = 3;
    const REUSE_MS = 10 * 60 * 1000;
    const PRESENCE_MS = 60000;
    const PANIC_CHECK_MS = 5 * 60 * 1000;
    const BADGE_WAIT_MS = 8000;
    const RENEW_BEFORE_MS = 7 * 24 * 3600 * 1000;
    const ENROLL_RETRY_MS = 10 * 60 * 1000;
    const ECHO_MAX = 200;
    const REDACT_MS = 600000;
    const LEAVE_MS = 3000;
    const PANIC_WAIT_MS = 8000;
    const STATIC_BLOCKED = new Set(['wss://relay.nosflare.com', 'wss://relay.nostraddress.com', 'wss://nostr-server-production.up.railway.app']);
    const SEND_KEYS = [
        'nym_nostr_login_nsec', 'nym_session_nsec', 'nym_dev_nsec', 'nym_vault_enabled',
        'nym_keypair_mode', 'nym_random_keypair_per_session', 'nym_ai_consent',
        'nym_nostr_login_profile', 'nym_auto_ephemeral_nick', 'nym_pow_difficulty',
        'nym_attest_badge', 'nym_custom_emojis', 'nym_custom_emoji_packs', 'nym_show_status',
        'nym_shop_record', 'nym_remote_panic', 'nym_panic_login_at', 'nym_blocked_relays',
    ];

    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const parse = (raw, fallback) => {
        if (typeof raw !== 'string' || !raw) return fallback;
        try { return JSON.parse(raw); } catch (_) { return fallback; }
    };

    Object.assign(NYM.prototype, {

        _sa(key, nym) {
            const S = M();
            const raw = S && S.STRINGS[key] ? S.STRINGS[key] : key;
            const t = typeof this.uiText === 'function' ? this.uiText(raw) : raw;
            return S ? S.text(t, nym || '') : t;
        },

        _sendAsAnonActive() {
            let method = '';
            try { method = typeof this._acctLiveMethod === 'function' ? this._acctLiveMethod() : ''; } catch (_) { method = ''; }
            if (method === 'anonymous') return true;
            if (method !== 'ephemeral') return false;
            let mode = '';
            try {
                mode = localStorage.getItem('nym_keypair_mode')
                    || (localStorage.getItem('nym_random_keypair_per_session') === 'true' ? 'random' : '');
            } catch (_) { mode = ''; }
            return mode === 'random' || mode === 'hardcore';
        },

        _sendAsComposerText() {
            const input = typeof document !== 'undefined' ? document.getElementById('messageInput') : null;
            if (!input) return '';
            return String(typeof input.value === 'string' ? input.value : (input.textContent || '')).trim();
        },

        _sendAsCtx() {
            let surface = typeof this._composerSurface === 'function' ? this._composerSurface() : (this.inPMMode ? 'dm' : 'channel');
            if (surface === 'channel' && !this.currentGeohash) surface = 'none';
            const mesh = surface === 'channel' && typeof this.meshShouldCarry === 'function'
                && !!this.meshShouldCarry(this.currentGeohash || this.currentChannel);
            const enabled = typeof this.acctEnabled === 'function' && this.acctEnabled();
            return {
                loggedIn: !!this.pubkey && enabled,
                anonymousActive: this._sendAsAnonActive(),
                surface,
                editing: !!this.pendingEdit,
                mesh,
                command: this._sendAsComposerText().startsWith('/'),
            };
        },

        _sendAsOnline() {
            if (!this.connected) return false;
            try { if (typeof navigator !== 'undefined' && navigator.onLine === false) return false; } catch (_) { }
            return true;
        },

        _sendAsBotQuotes() {
            const savedQuote = this.pendingQuote
                ? { author: this.pendingQuote.author, text: this.pendingQuote.text, fullText: this.pendingQuote.fullText }
                : null;
            const threadRoot = typeof this._threadRootForSend === 'function' ? this._threadRootForSend() : null;
            const key = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
            const threadBotQuote = (!savedQuote && threadRoot && typeof this._threadBotQuoteContext === 'function')
                ? this._threadBotQuoteContext(threadRoot, key) : null;
            return { savedQuote, threadRoot, threadBotQuote, botQuote: savedQuote || threadBotQuote };
        },

        _sendAsNeedsBot(rawInput, quotes) {
            const text = String(rawInput || '');
            if (text.startsWith('/')) return false;
            const N = window.NymAnonNymbot;
            if (!N) return false;
            const q = quotes || this._sendAsBotQuotes();
            return !!N.triggers({ body: text, quoteAuthor: q.botQuote ? q.botQuote.author : '', threadBot: !!q.threadBotQuote });
        },

        _sendAsUnsent(m) {
            if (!m) return true;
            if (m._optimistic || !HEX.test(String(m.id || ''))) return true;
            return !!(this._queuedSends && this._queuedSends.has(m.id));
        },

        _sendAsQuotePending() {
            const q = this.pendingQuote;
            if (!q) return false;
            const id = String(q.sourceId || '');
            if (!HEX.test(id)) return true;
            return !!(this._queuedSends && this._queuedSends.has(id));
        },

        _sendAsRawInput() {
            let content = this._sendAsComposerText();
            const urls = typeof this.composerAttachmentUrls === 'function' ? this.composerAttachmentUrls() : [];
            if (urls.length) content = (content ? content + ' ' : '') + urls.join(' ');
            return content;
        },

        _sendAsKeyFor(a, get) {
            const S = M();
            for (const n of S.secretNames(a.method)) {
                const v = get(n);
                if (!v || String(v).startsWith('enc:v1:')) continue;
                let sk = null;
                try {
                    sk = this.decodeNsec(String(v));
                    if (T().getPublicKey(sk) === a.pubkey) return sk;
                } catch (_) { }
                if (sk && typeof sk.fill === 'function') sk.fill(0);
            }
            return null;
        },

        async _sendAsProbe() {
            const S = A();
            const Mo = M();
            if (!S || !Mo || typeof S.stashKeys !== 'function' || typeof S.read !== 'function') return null;
            const idx = S.read();
            const sig = JSON.stringify(idx.accounts.map((a) => [a.id, a.pubkey, a.method, a.nym]));
            if (this._sendAsProbing && this._sendAsProbing.sig === sig) return this._sendAsProbing.p;
            const p = (async () => {
                const rows = new Map();
                for (const a of idx.accounts) {
                    if (a.id === S.pageId || !HEX.test(a.pubkey || '') || !Mo.METHODS.includes(a.method)) continue;
                    const vals = (await S.stashKeys(a.id, Mo.PROBE_KEYS)) || {};
                    const get = (k) => (vals[k] == null ? null : String(vals[k]));
                    let signer = Mo.signerState(a.method, get);
                    if (signer === 'key') {
                        const sk = this._sendAsKeyFor(a, get);
                        if (sk) sk.fill(0);
                        else signer = 'none';
                    }
                    rows.set(a.id, { signer, keypairMode: Mo.keypairMode(get), aiConsent: get('nym_ai_consent') || '', nym: Mo.nymFrom(get, a.method, a.nym) });
                }
                this._sendAsCache = { sig, rows };
                return this._sendAsCache;
            })();
            this._sendAsProbing = { sig, p };
            try { return await p; } catch (_) { return null; } finally {
                if (this._sendAsProbing && this._sendAsProbing.p === p) this._sendAsProbing = null;
            }
        },

        _sendAsAccounts() {
            const S = A();
            if (!S || typeof S.read !== 'function') return [];
            const cache = this._sendAsCache;
            return S.read().accounts.map((a) => {
                const p = cache ? cache.rows.get(a.id) : null;
                return {
                    id: a.id, pubkey: a.pubkey, method: a.method, avatar: a.avatar,
                    nym: p ? p.nym : a.nym,
                    keypairMode: p ? p.keypairMode : '',
                    signer: p ? p.signer : 'none',
                    aiConsent: p ? p.aiConsent : '',
                };
            });
        },

        _sendAsInput(snap) {
            const S = A();
            const raw = snap ? snap.rawInput : this._sendAsRawInput();
            return {
                activeId: S ? S.pageId : null,
                activePubkey: this.pubkey || '',
                online: this._sendAsOnline(),
                needsNymbot: snap ? !!snap.needsBot : this._sendAsNeedsBot(raw),
                quotePending: snap ? !!snap.quotePending : this._sendAsQuotePending(),
                accounts: this._sendAsAccounts(),
            };
        },

        sendAsSection() {
            const Mo = M();
            if (!Mo || !A()) return { show: false, count: 0, rows: [] };
            return Mo.section(this._sendAsCtx(), this._sendAsInput());
        },

        _sendAsAvatar(id) {
            const S = A();
            const a = S && typeof S.read === 'function' ? S.read().accounts.find((x) => x.id === id) : null;
            if (a && typeof a.avatar === 'string' && /^data:image\/(png|jpeg|webp|gif);base64,[A-Za-z0-9+/=]+$/.test(a.avatar)) return a.avatar;
            if (a && typeof this.generateAvatarSvg === 'function' && this._avatarSvgCache) return this.generateAvatarSvg(a.pubkey);
            return '';
        },

        _sendAsSenderFrom(acct, get) {
            const Mo = M();
            if (!Mo || !acct || !HEX.test(acct.pubkey || '') || !Mo.METHODS.includes(acct.method)) return null;
            const mode = Mo.keypairMode(get);
            if (acct.method === 'ephemeral' && (mode === 'random' || mode === 'hardcore')) return null;
            if (Mo.signerState(acct.method, get) !== 'key') return null;
            let sk = this._sendAsKeyFor(acct, get);
            if (!sk) return null;
            const pubkey = acct.pubkey;
            const emojis = typeof this.customEmojiMapFrom === 'function' ? this.customEmojiMapFrom(get) : new Map();
            const now = Date.now();
            const rec = parse(get('nym_attest_badge'), null);
            const badge = rec && rec.pubkey === pubkey && typeof rec.badge === 'string' && rec.badge && Number(rec.expiresAt) > now
                ? { pubkey, badge: rec.badge, tier: rec.tier || 'origin', expiresAt: Number(rec.expiresAt) } : null;
            const shop = parse(get('nym_shop_record'), null);
            const cosmetics = shop && shop.active && Array.isArray(shop.active.cosmetics) ? shop.active.cosmetics.slice() : [];
            const show = get('nym_show_status');
            const statusMode = show === 'false' ? 'disabled' : (show === 'friends' ? 'friends' : 'enabled');
            const AW = window.NymAwaySync;
            const awayState = AW ? AW.decode(get(AW.storageKey(pubkey))) : null;
            const loginAt = parseInt(get('nym_panic_login_at') || '', 10);
            const RB = window.NymRelayBlock;
            const blocked = RB ? RB.toSet(RB.list(RB.norm(parse(get('nym_blocked_relays'), null), now))) : new Set();
            const sender = {
                id: acct.id,
                pubkey,
                method: acct.method,
                nym: Mo.nymFrom(get, acct.method, acct.nym),
                pow: Mo.difficulty(get('nym_pow_difficulty'), this.nymchatPowFloor || 0),
                badge,
                consent: get('nym_ai_consent') || '',
                statusMode,
                away: !!(awayState && awayState.enabled),
                cosmetics,
                blocked,
                panic: { enabled: get('nym_remote_panic') === '1', loginAt: Number.isInteger(loginAt) && loginAt > 0 ? loginAt : null },
                emojiTags: (text) => this.customEmojiTagsForContent(text, emojis),
                sign: (ev) => {
                    if (!sk) throw new Error('signer gone');
                    return T().finalizeEvent(ev, sk);
                },
                alive: () => !!sk,
                keep: () => (sk ? new Uint8Array(sk) : null),
                wipe: () => { if (sk) sk.fill(0); sk = null; },
            };
            return sender;
        },

        async _sendAsSender(acct) {
            const S = A();
            if (!S || typeof S.stashKeys !== 'function' || !acct) return null;
            const AW = window.NymAwaySync;
            const names = SEND_KEYS.concat(AW ? [AW.storageKey(acct.pubkey)] : []);
            const vals = await S.stashKeys(acct.id, names);
            if (!vals) return null;
            return this._sendAsSenderFrom(acct, (k) => (vals[k] == null ? null : String(vals[k])));
        },

        _sendAsSafe(id) {
            const S = A();
            if (!S || S.frozen || this._panicking || this._remotePanicWiping || this._acctGoing) return false;
            const idx = S.read();
            if (idx.journal || idx.active !== S.pageId) return false;
            return idx.accounts.some((a) => a.id === id);
        },

        _sendAsSnapshot() {
            const input = document.getElementById('messageInput');
            if (!input || !this.currentGeohash) return null;
            const typed = typeof input.value === 'string' ? input.value : '';
            const rawInput = this._sendAsRawInput();
            if (!rawInput && !this.pendingQuote) return null;
            const quotes = this._sendAsBotQuotes();
            let content = rawInput;
            if (quotes.savedQuote) {
                const lines = quotes.savedQuote.text.split('\n');
                const quoteLine = `> @${quotes.savedQuote.author}: ${lines[0]}` +
                    (lines.length > 1 ? '\n' + lines.slice(1).map((l) => `> ${l}`).join('\n') : '');
                content = rawInput ? `${quoteLine}\n\n${rawInput}` : quoteLine;
            }
            return {
                typed,
                rawInput,
                content,
                quote: quotes.savedQuote,
                quoteSource: this.pendingQuote ? String(this.pendingQuote.sourceId || '') : '',
                quotePending: this._sendAsQuotePending(),
                threadRoot: quotes.threadRoot,
                botQuote: quotes.botQuote,
                needsBot: this._sendAsNeedsBot(rawInput, quotes),
                geohash: this.currentGeohash,
                channel: this.currentChannel,
                draftKey: typeof this._getInputContextKey === 'function' ? this._getInputContextKey() : null,
            };
        },

        _sendAsEvent(sender, snap, createdAt) {
            const opts = createdAt ? { createdAt } : null;
            return this._buildChannelEvent(sender, snap.content, snap.geohash, snap.quote, snap.threadRoot, opts);
        },

        _sendAsRelays(channelKey, blocked) {
            const RB = window.NymRelayBlock;
            const set = blocked instanceof Set ? blocked : new Set();
            const ok = (u) => typeof u === 'string' && u.startsWith('wss://') && !STATIC_BLOCKED.has(u) && !(RB && RB.isBlocked(set, u));
            const relays = [];
            const add = (u) => {
                if (ok(u) && !relays.includes(u)) relays.push(u);
            };
            (this.defaultRelays || []).forEach(add);
            add(this.appRelay);
            const geo = (typeof this.isValidGeohash === 'function' && this.isValidGeohash(channelKey) && typeof this.getClosestRelaysForGeohash === 'function')
                ? this.getClosestRelaysForGeohash(channelKey).map((r) => r.url).filter(ok)
                : [];
            geo.forEach(add);
            return { relays, geo };
        },

        _sendAsPoolTransport(sender, cfg) {
            const t = {
                id: sender.id, pubkey: sender.pubkey, dead: false, queue: [], waiters: new Map(),
                relays: new Set(cfg.relays), holds: 0, idle: null, upstream: false, kind: 'pool',
            };
            let ws = null;
            const finish = (why) => {
                if (t.dead) return;
                t.dead = true;
                if (t.idle) clearTimeout(t.idle);
                for (const w of [...t.waiters.values()]) w.done({ ok: false, reason: why, transport: true });
                t.waiters.clear();
                try { if (ws) ws.close(); } catch (_) { }
                if (this._sendAsTransports && this._sendAsTransports.get(t.id) === t) this._sendAsTransports.delete(t.id);
            };
            const relaysFrame = () => JSON.stringify(['RELAYS', { relays: [...t.relays], dmRelays: [] }]);
            t.close = () => finish('closed');
            t.touch = () => {
                if (t.idle) clearTimeout(t.idle);
                t.idle = null;
                if (!t.dead && t.holds <= 0 && t.waiters.size === 0) t.idle = setTimeout(() => finish('idle'), IDLE_MS);
            };
            t.hold = () => { t.holds++; if (t.idle) { clearTimeout(t.idle); t.idle = null; } };
            t.release = () => { t.holds = Math.max(0, t.holds - 1); t.touch(); };
            t.send = (frame) => {
                if (t.dead || !ws) return false;
                if (ws.readyState === 1) {
                    try { ws.send(frame); } catch (_) { finish('error'); return false; }
                } else t.queue.push(frame);
                return true;
            };
            t.publish = (frame) => {
                if (!t.send(frame)) return false;
                const now = Date.now();
                t.replays = t.replays.filter((r) => r.until > now && r.frame !== frame);
                t.replays.push({ frame, until: now + REPLAY_MS });
                return true;
            };
            t.need = (urls) => {
                let changed = false;
                for (const u of urls || []) if (!t.relays.has(u)) { t.relays.add(u); changed = true; }
                if (changed && ws && ws.readyState === 1) t.send(relaysFrame());
            };
            t.connected = new Set();
            t.opened = false;
            t.ups = [];
            t.replays = [];
            const app = typeof this.appRelay === 'string' ? this.appRelay : '';
            t.check = () => {
                t.ups = t.ups.filter((u) => {
                    const want = u.urls && u.urls.length ? u.urls : null;
                    const appUp = !app || !t.relays.has(app) || t.connected.has(app);
                    const hit = t.opened && (Date.now() >= u.until || (appUp && (want ? want.some((x) => t.connected.has(x)) : t.connected.size > 0)));
                    if (hit) u.resolve();
                    return !hit;
                });
            };
            t.up = (urls) => new Promise((resolve) => {
                t.ups.push({ urls: urls || [], until: Date.now() + UPSTREAM_MS, resolve });
                t.check();
                setTimeout(t.check, UPSTREAM_MS + 50);
            });
            const url = typeof this._getRelayPoolUrl === 'function' ? this._getRelayPoolUrl() : null;
            if (!url) { finish('unavailable'); return t; }
            try { ws = new WebSocket(url); } catch (_) { finish('unavailable'); return t; }
            t.ws = ws;
            const openTimer = setTimeout(() => { if (ws.readyState !== 1) finish('timeout'); }, OPEN_MS);
            ws.onopen = () => {
                clearTimeout(openTimer);
                try { ws.send(relaysFrame()); } catch (_) { finish('error'); return; }
                const q = t.queue;
                t.queue = [];
                for (const f of q) { try { ws.send(f); } catch (_) { } }
                t.opened = true;
                for (const u of t.ups) u.until = Date.now() + UPSTREAM_MS;
                setTimeout(t.check, UPSTREAM_MS + 50);
            };
            ws.onmessage = (e) => {
                let m;
                try { m = JSON.parse(e.data); } catch (_) { return; }
                if (!Array.isArray(m)) return;
                if (m[0] === 'POOL:STATUS') {
                    const st = m[1];
                    if (st && Array.isArray(st.connected)) {
                        const next = new Set(st.connected.filter((u) => typeof u === 'string'));
                        const grew = [...next].some((u) => !t.connected.has(u));
                        t.connected = next;
                        if (grew && t.opened) {
                            const now = Date.now();
                            t.replays = t.replays.filter((r) => r.until > now);
                            for (const r of t.replays) t.send(r.frame);
                        }
                        t.check();
                    }
                    return;
                }
                if (m[0] !== 'OK' || typeof m[1] !== 'string') return;
                const w = t.waiters.get(m[1]);
                if (!w) return;
                if (m[2] === true) { w.done({ ok: true }); return; }
                const reason = typeof m[3] === 'string' && m[3] ? m[3] : 'refused';
                if (typeof m[4] === 'string' && m[4]) { w.rejects.push(reason); return; }
                w.done({ ok: false, reason });
            };
            ws.onclose = () => finish('closed');
            ws.onerror = () => finish('error');
            return t;
        },

        _sendAsDirectTransport(sender, cfg) {
            const t = {
                id: sender.id, pubkey: sender.pubkey, dead: false, waiters: new Map(), sockets: new Map(),
                relays: new Set(cfg.relays), holds: 0, idle: null, kind: 'direct',
            };
            const finish = (why) => {
                if (t.dead) return;
                t.dead = true;
                if (t.idle) clearTimeout(t.idle);
                for (const w of [...t.waiters.values()]) w.done({ ok: false, reason: why, transport: true });
                t.waiters.clear();
                for (const s of t.sockets.values()) { try { s.close(); } catch (_) { } }
                t.sockets.clear();
                if (this._sendAsTransports && this._sendAsTransports.get(t.id) === t) this._sendAsTransports.delete(t.id);
            };
            const sockets = () => [...t.sockets.values()];
            const open = (url) => {
                if (t.sockets.has(url)) return;
                let ws;
                try { ws = new WebSocket(url); } catch (_) { return; }
                ws._q = [];
                t.sockets.set(url, ws);
                ws.onopen = () => { const q = ws._q; ws._q = []; for (const f of q) { try { ws.send(f); } catch (_) { } } t.connected.add(url); t.check(); };
                ws.onmessage = (e) => {
                    let m;
                    try { m = JSON.parse(e.data); } catch (_) { return; }
                    if (!Array.isArray(m) || m[0] !== 'OK' || typeof m[1] !== 'string') return;
                    const w = t.waiters.get(m[1]);
                    if (!w) return;
                    if (m[2] === true) { w.done({ ok: true }); return; }
                    w.rejects.push(typeof m[3] === 'string' ? m[3] : 'refused');
                    if (w.rejects.length >= t.sockets.size) w.done({ ok: false, reason: w.rejects[0] || 'refused' });
                };
                ws.onclose = () => {
                    t.sockets.delete(url);
                    if (!t.dead && t.sockets.size === 0) finish('closed');
                };
                ws.onerror = () => { };
            };
            t.connected = new Set();
            t.ups = [];
            t.check = () => {
                t.ups = t.ups.filter((u) => {
                    const hit = Date.now() >= u.until || t.connected.size > 0;
                    if (hit) u.resolve();
                    return !hit;
                });
            };
            t.up = () => new Promise((resolve) => {
                t.ups.push({ until: Date.now() + UPSTREAM_MS, resolve });
                t.check();
                setTimeout(t.check, UPSTREAM_MS + 50);
            });
            t.close = () => finish('closed');
            t.touch = () => {
                if (t.idle) clearTimeout(t.idle);
                t.idle = null;
                if (!t.dead && t.holds <= 0 && t.waiters.size === 0) t.idle = setTimeout(() => finish('idle'), IDLE_MS);
            };
            t.hold = () => { t.holds++; if (t.idle) { clearTimeout(t.idle); t.idle = null; } };
            t.release = () => { t.holds = Math.max(0, t.holds - 1); t.touch(); };
            t.send = (frame) => {
                if (t.dead) return false;
                const list = sockets();
                if (!list.length) return false;
                for (const ws of list) {
                    if (ws.readyState === 1) { try { ws.send(frame); } catch (_) { } } else ws._q.push(frame);
                }
                return true;
            };
            t.need = (urls) => { for (const u of urls || []) { t.relays.add(u); open(u); } };
            for (const u of t.relays) open(u);
            if (!t.sockets.size) finish('unavailable');
            return t;
        },

        _sendAsTransport(sender, cfg) {
            if (!this._sendAsTransports) this._sendAsTransports = new Map();
            const cur = this._sendAsTransports.get(sender.id);
            if (cur && !cur.dead && cur.pubkey === sender.pubkey) {
                cur.need(cfg.relays);
                return cur;
            }
            if (cur) cur.close();
            const pool = !!this.useRelayProxy && typeof this._getRelayPoolUrl === 'function' && !!this._getRelayPoolUrl();
            const t = pool ? this._sendAsPoolTransport(sender, cfg) : this._sendAsDirectTransport(sender, cfg);
            if (!t.dead) this._sendAsTransports.set(sender.id, t);
            return t;
        },

        _sendAsPublishOnce(t, ev, geo, pre) {
            return new Promise((resolve) => {
                if (t.dead) { resolve({ ok: false, reason: 'closed', transport: true }); return; }
                const timer = setTimeout(() => w.done({ ok: false, reason: 'timeout' }), OK_MS);
                const resend = [];
                const w = {
                    rejects: [],
                    done: (r) => {
                        clearTimeout(timer);
                        for (const x of resend) clearTimeout(x);
                        if (t.waiters.get(ev.id) === w) t.waiters.delete(ev.id);
                        t.touch();
                        resolve(r);
                    },
                };
                t.waiters.set(ev.id, w);
                if (t.idle) { clearTimeout(t.idle); t.idle = null; }
                const geoFrame = t.kind === 'pool' && ev.kind === 20000 && geo && geo.length
                    ? JSON.stringify(['GEO_EVENT', ev, geo]) : null;
                const frame = geoFrame || JSON.stringify(['EVENT', ev]);
                t.up(geoFrame ? geo : null).then(() => {
                    if (!t.waiters.has(ev.id)) return;
                    if (this._panicking || this._remotePanicWiping) { w.done({ ok: false, reason: 'panic', abort: true }); return; }
                    const put = typeof t.publish === 'function' ? t.publish : t.send;
                    for (const f of pre || []) put(f);
                    if (!put(frame)) { w.done({ ok: false, reason: 'closed', transport: true }); return; }
                    if (geoFrame) resend.push(setTimeout(() => { if (t.waiters.has(ev.id)) t.send(geoFrame); }, GEO_RESEND_MS));
                });
            });
        },

        async _sendAsPublish(sender, ev, cfg, job) {
            let last = { ok: false, reason: 'closed' };
            for (let i = 0; i < ATTEMPTS; i++) {
                if (job && job.silent) return { ok: false, reason: 'closed', abort: true };
                if (!this._sendAsSafe(sender.id)) return { ok: false, reason: 'gone', abort: true };
                const t = this._sendAsTransport(sender, cfg);
                if (job) job.transport = t;
                const pre = job && job.presence ? [JSON.stringify(['EVENT', job.presence])] : null;
                last = await this._sendAsPublishOnce(t, ev, cfg.geo, pre);
                if (pre && last.ok) {
                    if (!this._sendAsPresenceAt) this._sendAsPresenceAt = new Map();
                    this._sendAsPresenceAt.set(sender.pubkey, Date.now());
                    job.presence = null;
                }
                if (last.ok || !last.transport) return last;
                if (job && job.echoed) return { ok: true };
                if (t && !t.dead) t.close();
            }
            return last;
        },

        async _sendAsEnroll(sender) {
            const issued = await this._attestApi({ action: 'challenge', pubkey: sender.pubkey });
            const challenge = issued && issued.challenge;
            if (!challenge) throw new Error('no challenge');
            const proof = await this._platformAttestation(challenge);
            const build = (proof.platform === 'web' && Array.isArray(issued.buildProbe))
                ? await this._buildProof(issued.buildProbe) : null;
            const bits = proof.platform === 'web' ? (Number(issued.powBits) || 0) : 0;
            const apiHost = this._getApiHost && this._getApiHost();
            let ev = {
                kind: 27235,
                created_at: Math.floor(Date.now() / 1000),
                tags: [['domain', 'nymbot-pm'], ['method', 'POST'], ['action', 'attest-enroll'], ['challenge', challenge]],
                content: '',
                pubkey: sender.pubkey,
            };
            if (apiHost) ev.tags.push(['u', `https://${apiHost}/api/attest`]);
            if (bits > 0 && typeof this._minePow === 'function') ev = (await this._minePow(ev, bits)) || ev;
            const auth = sender.sign(ev);
            const res = await this._attestApi(Object.assign({ action: 'enroll', pubkey: sender.pubkey, challenge, auth, build }, proof));
            if (!res || !res.badge) throw new Error('no badge');
            return { pubkey: sender.pubkey, badge: res.badge, tier: res.tier || 'origin', expiresAt: Number(res.expiresAt) || 0 };
        },

        async _sendAsBadge(sender) {
            const now = Date.now();
            const rec = sender.badge;
            if (rec && rec.expiresAt - now > RENEW_BEFORE_MS) return rec.badge;
            const usable = rec && rec.expiresAt > now ? rec.badge : null;
            if (!this._sendAsEnrollNext) this._sendAsEnrollNext = new Map();
            if (!this._sendAsEnrolling) this._sendAsEnrolling = new Map();
            if ((this._sendAsEnrollNext.get(sender.pubkey) || 0) > now) return usable;
            let job = this._sendAsEnrolling.get(sender.pubkey);
            if (!job) {
                job = this._sendAsEnroll(sender).then(async (fresh) => {
                    sender.badge = fresh;
                    try { await A().stashSet(sender.id, 'nym_attest_badge', JSON.stringify(fresh)); } catch (_) { }
                    return fresh.badge;
                }, () => {
                    this._sendAsEnrollNext.set(sender.pubkey, Date.now() + ENROLL_RETRY_MS);
                    return usable;
                }).finally(() => { this._sendAsEnrolling.delete(sender.pubkey); });
                this._sendAsEnrolling.set(sender.pubkey, job);
            }
            const got = await Promise.race([job, sleep(BADGE_WAIT_MS).then(() => undefined)]);
            return got === undefined ? usable : got;
        },

        async _sendAsPanicOk(sender) {
            if (!this._sendAsPanicAt) this._sendAsPanicAt = new Map();
            if (Date.now() - (this._sendAsPanicAt.get(sender.pubkey) || 0) < PANIC_CHECK_MS) return true;
            const R = window.NymRemotePanic;
            const apiHost = this._getApiHost && this._getApiHost();
            if (!R || !apiHost || typeof this._remotePanicAuth !== 'function') return true;
            const url = `https://${apiHost}/api/storage`;
            const body = { action: 'panic-check', pubkey: sender.pubkey };
            let data = null;
            try {
                body.auth = await this._remotePanicAuth((ev) => Promise.resolve(sender.sign(ev)), sender.pubkey, 'panic-check', body, url);
                const res = await this._edgeFetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
                if (!res || !res.ok) return true;
                data = await res.json().catch(() => null);
            } catch (_) { return true; }
            const marker = R.fromRow(sender.pubkey, data && data.mark);
            const verdict = marker ? R.decide({
                enabled: sender.panic.enabled, loginAt: sender.panic.loginAt,
                now: Math.floor(Date.now() / 1000), pubkey: sender.pubkey, marker,
            }, (ev) => T().verifyEvent(ev)) : null;
            if (verdict && verdict.action === 'wipe') return false;
            this._sendAsPanicAt.set(sender.pubkey, Date.now());
            return true;
        },

        async _sendAsPanicGate(sender) {
            let timer = null;
            const wait = new Promise((r) => { timer = setTimeout(() => r('timeout'), this._sendAsPanicWaitMs || PANIC_WAIT_MS); });
            try {
                return await Promise.race([this._sendAsPanicOk(sender).then((ok) => (ok ? 'ok' : 'wipe'), () => 'ok'), wait]);
            } finally {
                clearTimeout(timer);
            }
        },

        _sendAsPresence(sender) {
            if (sender.statusMode === 'disabled' || sender.away) return null;
            if (!this._sendAsPresenceAt) this._sendAsPresenceAt = new Map();
            if (Date.now() - (this._sendAsPresenceAt.get(sender.pubkey) || 0) < PRESENCE_MS) return null;
            try {
                return sender.sign({
                    kind: 30078,
                    created_at: Math.floor(Date.now() / 1000),
                    tags: [['d', 'nym-presence'], ['t', 'nym-presence'], ['n', sender.nym], ['status', sender.statusMode === 'enabled' ? 'online' : 'hidden']],
                    content: '',
                    pubkey: sender.pubkey,
                });
            } catch (_) { return null; }
        },

        _sendAsContainer(snap) {
            if (typeof document === 'undefined') return null;
            const storageKey = snap.geohash ? `#${snap.geohash}` : snap.channel;
            let container = this._cvActive && typeof this._cvListForKey === 'function'
                ? this._cvListForKey(storageKey)
                : (this.currentGeohash === snap.geohash ? document.getElementById('messagesContainer') : null);
            const at = this.activeThread;
            if (at && this._threadContainer) {
                if (snap.threadRoot && at.rootId === snap.threadRoot) container = this._threadContainer;
                else if (container === this._threadContainer) container = null;
            }
            return container || null;
        },

        _sendAsBubble(job) {
            const snap = job.snap;
            const nowMs = Date.now();
            const tempId = '_sendas_' + Math.random().toString(36).slice(2) + nowMs.toString(36);
            job.tempId = tempId;
            job.storageKey = snap.geohash ? `#${snap.geohash}` : snap.channel;
            const container = this._sendAsContainer(snap);
            if (!container) return;
            if (typeof this._clearMessageSkeleton === 'function' && (container._skelTimer || container._emptyNote)) this._clearMessageSkeleton(container);
            const suffix = job.acct.pubkey.slice(-4);
            const nym = job.sender ? job.sender.nym : String(job.label || '').replace(/#[0-9a-f]{4}$/i, '');
            const seq = ++this._msgSeq;
            const time = new Date(nowMs).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: !!(this.settings && this.settings.timeFormat === '12hr') });
            const el = document.createElement('div');
            el.className = 'message sendas-bubble';
            el.dataset.messageId = tempId;
            el.dataset.timestamp = String(nowMs);
            el.dataset.createdAt = String(Math.floor(nowMs / 1000));
            el.dataset.ms = String(nowMs);
            el.dataset.seq = String(seq);
            const body = esc(snap.content).replace(/\n/g, '<br>');
            el.innerHTML = `<span class="message-time">${esc(time)}</span>`
                + `<span class="message-author"><span class="bubble-time">${esc(time)}</span><span class="author-clickable"><bdi>${esc(nym)}<span class="nym-suffix">#${esc(suffix)}</span></bdi></span><span class="nym-bracket">&gt;</span></span>`
                + `<span class="message-content">${body}<span class="sendas-status"></span></span>`;
            let node = el;
            if (document.body && document.body.classList.contains('chat-bubbles')) {
                const wrap = document.createElement('div');
                wrap.className = 'message-group sendas-group';
                wrap.dataset.sendasFor = tempId;
                const box = document.createElement('div');
                box.className = 'message-group-avatar';
                const src = this._sendAsAvatar(job.acct.id);
                if (src) {
                    const img = document.createElement('img');
                    img.className = 'avatar-bubble';
                    img.alt = '';
                    img.src = src;
                    box.appendChild(img);
                }
                const stack = document.createElement('div');
                stack.className = 'message-group-stack';
                stack.appendChild(el);
                wrap.appendChild(box);
                wrap.appendChild(stack);
                node = wrap;
            }
            container.appendChild(node);
            this.userScrolledUp = false;
            if (typeof this._scheduleScrollToBottom === 'function') this._scheduleScrollToBottom(true);
            this._sendAsMark(job, 'pending');
        },

        _sendAsSay(key) {
            if (typeof this.displaySystemMessage === 'function') this.displaySystemMessage(this._sa(key));
        },

        _sendAsMark(job, state) {
            if (typeof document === 'undefined' || !job.tempId) return;
            const label = job.label;
            document.querySelectorAll(`.message[data-message-id="${job.tempId}"]`).forEach((el) => {
                el.classList.toggle('sendas-pending', state === 'pending');
                el.classList.toggle('sendas-failed', state === 'failed');
                el.classList.add('sendas-bubble');
                let note = el.querySelector(':scope .sendas-status');
                if (!note) {
                    note = document.createElement('div');
                    note.className = 'sendas-status';
                    note.setAttribute('aria-live', 'off');
                    const host = el.querySelector(':scope > .message-content') || el;
                    host.appendChild(note);
                }
                note.textContent = state === 'pending' ? this._sa('sending', label)
                    : (state === 'failed' ? this._sa('failedShort', label) : '');
                note.hidden = !note.textContent;
                if (state === 'failed') note.appendChild(this._sendAsActions(job));
            });
        },

        _sendAsActions(job) {
            const bar = document.createElement('span');
            bar.className = 'sendas-actions';
            const word = (t) => (typeof this.uiText === 'function' ? this.uiText(t) : t);
            const add = (label, run) => {
                const b = document.createElement('button');
                b.type = 'button';
                b.className = 'sendas-act';
                b.textContent = label;
                b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); run(); });
                bar.appendChild(b);
            };
            add(word('Retry'), () => { this._sendAsRetry(job); });
            add(word('Copy'), () => { this._sendAsCopy(job); });
            add(this._sa('putBack'), () => { this._sendAsPutBack(job); });
            return bar;
        },

        _sendAsClipboard(text) {
            if (typeof navigator !== 'undefined' && navigator.clipboard && typeof navigator.clipboard.writeText === 'function') return navigator.clipboard.writeText(text);
            return Promise.reject(new Error('no clipboard'));
        },

        async _sendAsCopy(job) {
            if (!job || !job.snap) return false;
            try {
                await this._sendAsClipboard(job.snap.rawInput);
                if (typeof this.showToast === 'function') this.showToast(typeof this.uiText === 'function' ? this.uiText('Copied!') : 'Copied!', { kind: 'success' });
                return true;
            } catch (_) {
                return false;
            }
        },

        _sendAsPutBack(job) {
            if (!job || !job.snap) return false;
            const input = typeof document !== 'undefined' ? document.getElementById('messageInput') : null;
            const raw = job.snap.rawInput;
            if (this._sendAsFailed) this._sendAsFailed.delete(job);
            job.state = 'dropped';
            this._sendAsDropBubble(job);
            if (!input || this.currentGeohash !== job.snap.geohash) {
                this._sendAsKeepDraft(job);
                return true;
            }
            const cur = String(input.value || '');
            if (!cur.includes(raw)) input.value = cur.trim() ? cur + '\n' + raw : raw;
            if (!cur.trim() && job.snap.quote && !this.pendingQuote && typeof this.setQuoteReply === 'function') this.setQuoteReply(job.snap.quote.author, job.snap.quote.fullText || job.snap.quote.text, job.snap.quoteSource);
            if (typeof this.autoResizeTextarea === 'function') this.autoResizeTextarea(input);
            if (typeof this.refreshComposerPrimary === 'function') this.refreshComposerPrimary();
            if (typeof input.focus === 'function') input.focus();
            return true;
        },

        _sendAsKeepDraft(job) {
            const snap = job && job.snap;
            const raw = snap && snap.rawInput;
            if (!raw || !snap.draftKey) return;
            const input = typeof document !== 'undefined' ? document.getElementById('messageInput') : null;
            const here = !!input && typeof this._getInputContextKey === 'function' && this._getInputContextKey() === snap.draftKey;
            if (here) {
                const cur = String(input.value || '');
                if (!cur.includes(raw)) input.value = cur.trim() ? cur + '\n' + raw : raw;
                return;
            }
            if (!this._inputDrafts) this._inputDrafts = new Map();
            const cur = String(this._inputDrafts.get(snap.draftKey) || '');
            if (!cur.includes(raw)) this._inputDrafts.set(snap.draftKey, cur.trim() ? cur + '\n' + raw : raw);
        },

        _sendAsDropBubble(job) {
            if (!job || !job.tempId) return;
            const id = job.tempId;
            if (typeof document !== 'undefined') {
                document.querySelectorAll(`[data-sendas-for="${id}"]`).forEach((el) => el.remove());
                document.querySelectorAll(`[data-message-id="${id}"]`).forEach((el) => el.remove());
            }
            job.tempId = null;
        },

        _sendAsSeen(event) {
            const job = this._sendAsEchoes && this._sendAsEchoes.get(event.id);
            if (!job) return;
            this._sendAsEchoes.delete(event.id);
            if (!this._sendAsQuiet) this._sendAsQuiet = new Set();
            this._sendAsQuiet.add(event.id);
            if (this._sendAsQuiet.size > 500) this._sendAsQuiet = new Set([...this._sendAsQuiet].slice(-300));
            job.echoed = true;
            this._sendAsDropBubble(job);
        },

        _sendAsClearComposer(snap) {
            const input = document.getElementById('messageInput');
            if (this.pendingQuote && typeof this.clearQuoteReply === 'function') this.clearQuoteReply();
            if (Array.isArray(this.commandHistory)) {
                this.commandHistory.push(snap.content);
                this.historyIndex = this.commandHistory.length;
            }
            if (input) input.value = '';
            if (typeof this.clearComposerAttachments === 'function') this.clearComposerAttachments();
            if (input && typeof this.autoResizeTextarea === 'function') this.autoResizeTextarea(input);
            if (typeof this.hideCommandPalette === 'function') this.hideCommandPalette();
            if (typeof this.hideAutocomplete === 'function') this.hideAutocomplete();
            if (typeof this.hideEmojiAutocomplete === 'function') this.hideEmojiAutocomplete();
            if (typeof this.refreshComposerPrimary === 'function') this.refreshComposerPrimary();
            if (input) input.focus();
        },

        _sendAsRestore(job) {
            const input = document.getElementById('messageInput');
            if (!input) return false;
            const empty = !String(input.value || '').trim() && !this.pendingQuote
                && !(typeof this.composerAttachmentUrls === 'function' && this.composerAttachmentUrls().length);
            if (!empty) return false;
            const sameChat = this.currentGeohash === job.snap.geohash;
            if (!sameChat) {
                if (!job.snap.draftKey) return false;
                if (!this._inputDrafts) this._inputDrafts = new Map();
                if (this._inputDrafts.get(job.snap.draftKey)) return false;
                this._inputDrafts.set(job.snap.draftKey, job.snap.rawInput);
                return true;
            }
            input.value = job.snap.rawInput;
            job.restored = job.snap.rawInput;
            if (job.snap.quote && typeof this.setQuoteReply === 'function') this.setQuoteReply(job.snap.quote.author, job.snap.quote.fullText || job.snap.quote.text, job.snap.quoteSource);
            if (typeof this.autoResizeTextarea === 'function') this.autoResizeTextarea(input);
            if (typeof this.refreshComposerPrimary === 'function') this.refreshComposerPrimary();
            return true;
        },

        async _sendAsSign(job) {
            const sender = job.sender;
            const badge = await this._sendAsBadge(sender);
            if (!this._sendAsSafe(sender.id) || !sender.alive()) throw Object.assign(new Error('gone'), { abort: true });
            const built = this._sendAsEvent(sender, job.snap);
            let event = built.event;
            if (badge) event.tags.push([this.ATTEST_BADGE_TAG || 'nymattest', badge]);
            if (sender.pow > 0) event = await this._minePow(event, sender.pow);
            if (!this._sendAsSafe(sender.id) || !sender.alive()) throw Object.assign(new Error('gone'), { abort: true });
            job.signed = sender.sign(event);
            job.signedAt = Date.now();
            job.presence = this._sendAsPresence(sender);
            if (job.sender.cosmetics.includes('cosmetic-redacted')) job.redactKey = sender.keep();
            if (!this._sendAsEchoes) this._sendAsEchoes = new Map();
            this._sendAsEchoes.set(job.signed.id, job);
            if (this._sendAsEchoes.size > ECHO_MAX) this._sendAsEchoes.delete(this._sendAsEchoes.keys().next().value);
            return job.signed;
        },

        async _sendAsDeliver(job) {
            const sender = job.sender;
            job.state = 'sending';
            let settle;
            job.settled = new Promise((r) => { settle = r; });
            let res = { ok: false, reason: 'failed' };
            try {
                if (!job.signed) {
                    if (this._sendAsSafe(sender.id)) {
                        const warm = this._sendAsTransport(sender, job.cfg);
                        if (warm && !warm.dead && typeof warm.touch === 'function') warm.touch();
                    }
                    await this._sendAsSign(job);
                }
                res = await this._sendAsPublish(sender, job.signed, job.cfg, job);
                if (!res.ok && job.echoed) res = { ok: true };
            } catch (e) {
                res = { ok: false, reason: (e && e.message) || 'failed', abort: !!(e && e.abort) };
            }
            sender.wipe();
            if (res.ok) this._sendAsDone(job);
            else this._sendAsFail(job, res);
            settle(res);
            return !!res.ok;
        },

        _sendAsTakeBack(job) {
            const input = typeof document !== 'undefined' ? document.getElementById('messageInput') : null;
            const restored = job.restored;
            job.restored = null;
            if (!input || typeof restored !== 'string' || input.value !== restored) return;
            if (this.currentGeohash !== job.snap.geohash) return;
            input.value = '';
            if (job.snap.quote && this.pendingQuote && typeof this.clearQuoteReply === 'function') this.clearQuoteReply();
            if (typeof this.autoResizeTextarea === 'function') this.autoResizeTextarea(input);
            if (typeof this.refreshComposerPrimary === 'function') this.refreshComposerPrimary();
        },

        _sendAsDone(job) {
            job.state = 'sent';
            this._sendAsTakeBack(job);
            this._sendAsJobs && this._sendAsJobs.delete(job);
            if (this._sendAsFailed) this._sendAsFailed.delete(job);
            job.presence = null;
            if (window.nymHaptic) window.nymHaptic('light');
            if (typeof this.showToast === 'function') this.showToast(this._sa('sentAs', job.label), { kind: 'success' });
            if (job.tempId) this._sendAsMark(job, 'sent');
            if (job.snap.needsBot) this._sendAsAskBot(job);
            if (job.redactKey) this._sendAsScheduleRedact(job);
        },

        _sendAsFail(job, res) {
            job.state = res && res.abort ? 'aborted' : 'failed';
            this._sendAsJobs && this._sendAsJobs.delete(job);
            if (job.signed && this._sendAsEchoes) this._sendAsEchoes.delete(job.signed.id);
            if (job.redactKey) { job.redactKey.fill(0); job.redactKey = null; }
            job.presence = null;
            if (job.silent || (res && res.abort && (this._panicking || this._remotePanicWiping || this._acctGoing))) return;
            if (res && res.abort) {
                this._sendAsDropBubble(job);
                if (!this._sendAsRestore(job)) this._sendAsKeepDraft(job);
                this._sendAsSay('removed');
                return;
            }
            if (!this._sendAsFailed) this._sendAsFailed = new Set();
            this._sendAsFailed.add(job);
            this._sendAsMark(job, 'failed');
            const back = this._sendAsRestore(job);
            if (typeof this.showToast === 'function') {
                const retry = typeof this.uiText === 'function' ? this.uiText('Retry') : 'Retry';
                this.showToast(this._sa(back ? 'failed' : 'failedShort', job.label), { kind: 'error', action: retry, onAction: () => { this._sendAsRetry(job); } });
            }
        },

        async _sendAsRetry(job) {
            if (!job || job.state !== 'failed') return false;
            if (!this._sendAsSafe(job.acct.id)) {
                if (this._sendAsFailed) this._sendAsFailed.delete(job);
                this._sendAsDropBubble(job);
                this._sendAsKeepDraft(job);
                this._sendAsSay('removed');
                return false;
            }
            job.state = 'retrying';
            const sender = await this._sendAsSender(job.acct);
            if (!sender) {
                job.state = 'failed';
                this._sendAsSay('removed');
                return false;
            }
            if (!job.panicOk) {
                this._sendAsMark(job, 'pending');
                const gate = await this._sendAsPanicGate(sender);
                if (gate === 'wipe' || !this._sendAsSafe(job.acct.id)) {
                    sender.wipe();
                    if (this._sendAsFailed) this._sendAsFailed.delete(job);
                    this._sendAsDropBubble(job);
                    this._sendAsKeepDraft(job);
                    this._sendAsSay('removed');
                    return false;
                }
                if (gate === 'timeout') {
                    sender.wipe();
                    this._sendAsFail(job, { ok: false, reason: 'timeout' });
                    return false;
                }
                job.panicOk = true;
            }
            if (this._sendAsFailed) this._sendAsFailed.delete(job);
            if (!job.signed || Date.now() - (job.signedAt || 0) > REUSE_MS) job.signed = null;
            job.sender = sender;
            if (!job.cfg) job.cfg = this._sendAsRelays(job.snap.geohash, sender.blocked);
            if (!this._sendAsJobs) this._sendAsJobs = new Set();
            this._sendAsJobs.add(job);
            if (job.signed) {
                if (!this._sendAsEchoes) this._sendAsEchoes = new Map();
                this._sendAsEchoes.set(job.signed.id, job);
                job.presence = this._sendAsPresence(sender);
                if (sender.cosmetics.includes('cosmetic-redacted')) job.redactKey = sender.keep();
            }
            if (!job.tempId) this._sendAsBubble(job);
            else this._sendAsMark(job, 'pending');
            return this._sendAsDeliver(job);
        },

        _sendAsAskBot(job) {
            const t = job.transport;
            if (t && !t.dead) t.hold();
            const publish = (ev) => {
                let tr = job.transport;
                if (!tr || tr.dead) {
                    const shadow = { id: job.acct.id, pubkey: job.acct.pubkey };
                    tr = this._sendAsTransport(shadow, job.cfg);
                }
                const frame = JSON.stringify(['EVENT', ev]);
                tr.up().then(() => { (typeof tr.publish === 'function' ? tr.publish : tr.send)(frame); tr.touch(); });
            };
            const as = { nym: job.sender.nym, pubkey: job.sender.pubkey, publish };
            Promise.resolve(this._handleBotCommand(job.snap.rawInput, job.snap.geohash, job.snap.botQuote, job.snap.content, job.snap.threadRoot, null, as))
                .catch(() => null)
                .then(() => { if (t && !t.dead) t.release(); });
        },

        _sendAsScheduleRedact(job) {
            const key = job.redactKey;
            job.redactKey = null;
            if (!key || !job.signed) return;
            const id = job.signed.id;
            const pubkey = job.sender.pubkey;
            const channel = job.snap.geohash;
            const cfg = job.cfg;
            const acct = job.acct;
            if (!this._sendAsTimers) this._sendAsTimers = new Set();
            const entry = { key, timer: null };
            entry.timer = setTimeout(() => {
                this._sendAsTimers.delete(entry);
                if (!this._sendAsSafe(acct.id) || !entry.key) { if (entry.key) entry.key.fill(0); return; }
                let del = null;
                try {
                    del = T().finalizeEvent({ kind: 5, created_at: Math.floor(Date.now() / 1000), tags: [['e', id]], content: '', pubkey }, entry.key);
                } catch (_) { del = null; }
                entry.key.fill(0);
                entry.key = null;
                if (!del || del.pubkey !== pubkey) return;
                const t = this._sendAsTransport({ id: acct.id, pubkey }, cfg);
                t.up().then(() => { (typeof t.publish === 'function' ? t.publish : t.send)(JSON.stringify(['EVENT', del])); t.touch(); });
                const apiHost = this._getApiHost && this._getApiHost();
                if (apiHost && channel && typeof this._edgeFetch === 'function') {
                    this._edgeFetch(`https://${apiHost}/api/storage`, {
                        method: 'POST', headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ action: 'channel-delete', channel, deletionEvent: del }),
                    }).catch(() => { });
                }
            }, REDACT_MS);
            this._sendAsTimers.add(entry);
        },

        async sendAs(acctId) {
            const Mo = M();
            const S = A();
            if (!Mo || !S || !acctId || typeof document === 'undefined') return false;
            const ctx = this._sendAsCtx();
            if (!Mo.canSendAs(ctx)) return false;
            if (typeof this.composerHasPendingUploads === 'function' && this.composerHasPendingUploads()) {
                this.displaySystemMessage('Still uploading — send again once the attachments finish.');
                return false;
            }
            const first = S.read().accounts.find((a) => a.id === acctId);
            if (!first || !this._sendAsSafe(acctId)) {
                this._sendAsSay('removed');
                return false;
            }
            const known = this._sendAsCache ? Mo.section(ctx, this._sendAsInput()).rows.find((r) => r.account === acctId) : null;
            if (known && !known.enabled) {
                this.displaySystemMessage(typeof this.uiText === 'function' ? this.uiText(known.reason) : known.reason);
                return false;
            }
            const snap = this._sendAsSnapshot();
            if (!snap) return false;
            const suffix = '#' + first.pubkey.slice(-4);
            const job = {
                acct: { id: first.id, pubkey: first.pubkey, method: first.method, nym: first.nym },
                sender: null,
                snap,
                label: (known ? known.nym : Mo.nymFrom(() => null, first.method, first.nym)) + suffix,
                cfg: null,
                state: 'new',
            };
            if (!this._sendAsJobs) this._sendAsJobs = new Set();
            this._sendAsJobs.add(job);
            this._sendAsBubble(job);
            this._sendAsClearComposer(snap);
            const refuse = (say) => {
                if (this._sendAsJobs) this._sendAsJobs.delete(job);
                if (job.sender) job.sender.wipe();
                job.state = 'refused';
                this._sendAsDropBubble(job);
                if (!this._sendAsRestore(job)) this._sendAsKeepDraft(job);
                if (say) say();
                return false;
            };
            const gone = () => { if (job.sender) job.sender.wipe(); return false; };
            await this._sendAsProbe();
            if (job.silent) return gone();
            const row = Mo.section(ctx, this._sendAsInput(snap)).rows.find((r) => r.account === acctId);
            const acct = S.read().accounts.find((a) => a.id === acctId);
            if (!row || !acct || acct.pubkey !== first.pubkey || !this._sendAsSafe(acctId)) return refuse(() => this._sendAsSay('removed'));
            if (!row.enabled) return refuse(() => this.displaySystemMessage(typeof this.uiText === 'function' ? this.uiText(row.reason) : row.reason));
            const sender = await this._sendAsSender(acct);
            if (job.silent) { if (sender) sender.wipe(); return false; }
            if (!sender) return refuse(() => this._sendAsSay('removed'));
            job.sender = sender;
            if (snap.needsBot && sender.consent !== 'allowed') return refuse(() => this.displaySystemMessage(this._sa('nymbot')));
            const label = sender.nym + suffix;
            if (label !== job.label) {
                job.label = label;
                this._sendAsRename(job, sender.nym);
            }
            job.cfg = this._sendAsRelays(snap.geohash, sender.blocked);
            const gate = await this._sendAsPanicGate(sender);
            if (job.silent) return gone();
            if (gate === 'wipe' || !this._sendAsSafe(acctId)) return refuse(() => this._sendAsSay('removed'));
            if (gate === 'timeout') {
                sender.wipe();
                this._sendAsFail(job, { ok: false, reason: 'timeout' });
                return false;
            }
            job.panicOk = true;
            return this._sendAsDeliver(job);
        },

        _sendAsRename(job, nym) {
            if (typeof document === 'undefined' || !job.tempId) return;
            document.querySelectorAll(`.message[data-message-id="${job.tempId}"] .message-author bdi`).forEach((el) => {
                const sfx = el.querySelector('.nym-suffix');
                el.textContent = nym;
                if (sfx) el.appendChild(sfx);
            });
            this._sendAsMark(job, 'pending');
        },

        async _sendAsLeave(targetId) {
            const jobs = [...(this._sendAsJobs || new Set())].filter((j) => j.state === 'sending' || j.state === 'new');
            if (jobs.length) await Promise.race([Promise.all(jobs.map((j) => j.settled || Promise.resolve())), sleep(LEAVE_MS)]);
            const S = A();
            for (const j of jobs) {
                if (j.state === 'sent') continue;
                if (j.signed && targetId && j.acct.id === targetId && S && typeof S.carryTake === 'function') {
                    let carry = null;
                    try { carry = await S.carryTake(targetId); } catch (_) { carry = null; }
                    if (!carry || carry.pubkey !== j.acct.pubkey) carry = { pubkey: j.acct.pubkey, at: Date.now(), drafts: [], events: [], pending: [] };
                    carry.events = (Array.isArray(carry.events) ? carry.events : []).concat([{ m: ['EVENT', j.signed], dm: false }]);
                    try { await S.carryPut(targetId, carry); } catch (_) { }
                } else {
                    this._sendAsKeepDraft(j);
                }
            }
            for (const j of [...(this._sendAsFailed || [])]) this._sendAsKeepDraft(j);
            this._sendAsShutdown();
        },

        _sendAsShutdown() {
            for (const t of [...((this._sendAsTransports && this._sendAsTransports.values()) || [])]) { try { t.close(); } catch (_) { } }
            if (this._sendAsTransports) this._sendAsTransports.clear();
            for (const e of [...(this._sendAsTimers || [])]) {
                clearTimeout(e.timer);
                if (e.key) e.key.fill(0);
                e.key = null;
            }
            if (this._sendAsTimers) this._sendAsTimers.clear();
            for (const j of [...(this._sendAsJobs || [])]) {
                j.silent = true;
                if (j.sender) j.sender.wipe();
                if (j.redactKey) { j.redactKey.fill(0); j.redactKey = null; }
            }
        },
    });

    if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
        window.addEventListener('pagehide', () => {
            try { if (window.nym && typeof window.nym._sendAsShutdown === 'function') window.nym._sendAsShutdown(); } catch (_) { }
        });
    }
})();
