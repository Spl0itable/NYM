// users.js - User identities, blocked users/keywords, friends, avatars, banners, wallpaper, uploads

const UPLOAD_HOST_TIMEOUT_MS = 45000;
const UPLOAD_MIN_BYTES_PER_MS = 50;

const BLOSSOM_SERVERS = [
    'https://blossom.band',
    'https://blossom.primal.net',
    'https://nostr.download'
];

Object.assign(NYM.prototype, {

    getUserColorClass(pubkey) {
        if (this.settings.theme !== 'bitchat') return '';
        if (!pubkey) return '';

        if (pubkey === this.pubkey) {
            return 'bitchat-theme';
        }

        if (this.userColors.has(pubkey)) {
            return this.userColors.get(pubkey);
        }

        const colorClass = this.generateUniqueColor(pubkey);
        this.userColors.set(pubkey, colorClass);
        return colorClass;
    },

    generateUniqueColor(pubkey) {
        if (!pubkey) return '';
        let hash = 0;
        for (let i = 0; i < pubkey.length; i++) {
            hash = pubkey.charCodeAt(i) + ((hash << 5) - hash);
        }
        const bucket = Math.abs(hash) % 1000;
        this._ensureBitchatColorSheet();
        return `bitchat-user-h${bucket}`;
    },

    _ensureBitchatColorSheet() {
        if (this._bitchatColorSheet) return;
        const hsl = (i, isLight) => {
            const hue = (i * 360 / 1000) | 0;
            const sat = isLight ? 55 + (i % 35) : 65 + (i % 35);
            const light = isLight ? 25 + (i % 20) : 60 + (i % 25);
            return `hsl(${hue},${sat}%,${light}%)`;
        };
        const parts = new Array(2000);
        for (let i = 0; i < 1000; i++) {
            const cls = `bitchat-user-h${i}`;
            parts[i] = `.${cls},.${cls} .nym-suffix{color:${hsl(i, false)}!important}`;
            parts[1000 + i] = `body.light-mode .${cls},body.light-mode .${cls} .nym-suffix{color:${hsl(i, true)}!important}`;
        }
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(parts.join(''));
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        this._bitchatColorSheet = sheet;
    },

    isVerifiedDeveloper(pubkey) {
        return pubkey === this.verifiedDeveloper.pubkey;
    },

    isReservedNick(nick) {
        const reserved = ['luxas', 'nymbot'];
        return reserved.includes(nick.toLowerCase().replace(/#.*$/, '').trim());
    },

    isVerifiedBot(pubkey) {
        return !!this.verifiedBot && pubkey === this.verifiedBot.pubkey;
    },

    verifyDeveloperNsec(nsec) {
        try {
            const secretKey = this.decodeNsec(nsec);
            const derivedPubkey = window.NostrTools.getPublicKey(secretKey);
            if (derivedPubkey === this.verifiedDeveloper.pubkey) {
                return { valid: true, secretKey, pubkey: derivedPubkey };
            }
            return { valid: false };
        } catch (e) {
            return { valid: false };
        }
    },

    applyDeveloperIdentity(secretKey, pubkey) {
        const switched = this.pubkey !== pubkey;
        this.privkey = secretKey;
        this.pubkey = pubkey;
        if (switched && typeof this.pqResetIdentityState === 'function') this.pqResetIdentityState();
        this.nym = 'Luxas';
        document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
        this.updateSidebarAvatar();
    },

    // Accepts an `nsec1…` or a bare 64-char hex key; returns the raw 32 bytes the signer wants.
    decodeNsec(nsec) {
        const hex = this.normalizePrivkeyInput(nsec);
        if (!hex) throw new Error('Failed to decode nsec: expected an nsec1… or a 64-character hex private key');
        const bytes = new Uint8Array(32);
        for (let i = 0; i < 32; i++) bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
        return bytes;
    },

    loadBlockedKeywords() {
        // blockedKeywords parses lazily on first access (see the NYM constructor).
        this._scheduleIdle(() => this.updateKeywordList());
    },

    saveBlockedKeywords() {
        localStorage.setItem('nym_blocked_keywords', JSON.stringify(Array.from(this.blockedKeywords)));
    },

    addBlockedKeyword() {
        const input = document.getElementById('newKeywordInput');
        const keyword = input.value.trim().toLowerCase();

        if (keyword) {
            this.blockedKeywords.add(keyword);
            this.saveBlockedKeywords();
            this.updateKeywordList();
            input.value = '';

            document.querySelectorAll('.message').forEach(msg => {
                const content = msg.querySelector('.message-content');
                const author = msg.dataset.author || '';
                const contentMatch = content && content.textContent.toLowerCase().includes(keyword);
                const nickMatch = this.parseNymFromDisplay(author).toLowerCase().includes(keyword);
                if (contentMatch || nickMatch) {
                    msg.classList.add('blocked');
                }
            });

            this._userListSig = '';
            this.updateUserList();

            this.displaySystemMessage(`Blocked keyword: "${keyword}"`);
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        }
    },

    removeBlockedKeyword(keyword) {
        this.blockedKeywords.delete(keyword);
        this.saveBlockedKeywords();
        this.updateKeywordList();

        document.querySelectorAll('.message').forEach(msg => {
            const author = msg.dataset.author || '';
            const content = msg.querySelector('.message-content');

            if (content && !this.blockedUsers.has(msg.dataset.pubkey)) {
                const contentText = content.textContent.toLowerCase();
                const cleanNick = this.parseNymFromDisplay(author).toLowerCase();
                const hasBlockedKeyword = Array.from(this.blockedKeywords).some(kw =>
                    contentText.includes(kw) || (cleanNick && cleanNick.includes(kw))
                );

                if (!hasBlockedKeyword) {
                    msg.classList.remove('blocked');
                }
            }
        });

        this._userListSig = '';
        this.updateUserList();

        this.displaySystemMessage(`Unblocked keyword: "${keyword}"`);
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    updateKeywordList() {
        const list = document.getElementById('keywordList');
        if (!list) return;
        list.textContent = '';
        if (this.blockedKeywords.size === 0) {
            const empty = document.createElement('div');
            empty.className = 'list-empty-msg';
            empty.textContent = 'No blocked keywords';
            list.appendChild(empty);
            return;
        }
        const frag = document.createDocumentFragment();
        this.blockedKeywords.forEach(keyword => {
            const row = document.createElement('div');
            row.className = 'keyword-item';
            const span = document.createElement('span');
            span.textContent = keyword;
            const btn = document.createElement('button');
            btn.className = 'remove-keyword-btn';
            btn.textContent = 'Remove';
            btn.addEventListener('click', () => this.removeBlockedKeyword(keyword));
            row.appendChild(span);
            row.appendChild(btn);
            frag.appendChild(row);
        });
        list.appendChild(frag);
    },

    generateRandomNym() {
        const style = localStorage.getItem('nym_nick_style') || 'fancy';

        const suffix = this.getPubkeySuffix(this.pubkey);

        if (style === 'simple') {
            const randomNum = Math.floor(1000 + Math.random() * 9000);
            return `nym${randomNum}#${suffix}`;
        }

        const adjectives = [
            'quantum', 'neon', 'cyber', 'shadow', 'plasma',
            'echo', 'nexus', 'void', 'flux', 'ghost',
            'phantom', 'stealth', 'cryptic', 'dark', 'neural',
            'binary', 'matrix', 'digital', 'virtual', 'zero',
            'null', 'nym', 'masked', 'hidden', 'cipher',
            'enigma', 'spectral', 'rogue', 'omega', 'alpha',
            'delta', 'sigma', 'vortex', 'turbo', 'razor',
            'blade', 'frost', 'storm', 'glitch', 'pixel',
            'hyper', 'proto', 'nano', 'micro', 'ultra',
            'silent', 'feral', 'lucid', 'primal', 'astral',
            'cobalt', 'onyx', 'crimson', 'obsidian', 'iron',
            'solar', 'lunar', 'stellar', 'cosmic', 'atomic',
            'toxic', 'rogue', 'rapid', 'swift', 'fierce'
        ];

        const nouns = [
            'ghost', 'nomad', 'drift', 'pulse', 'wave',
            'spark', 'node', 'byte', 'mesh', 'link',
            'runner', 'hacker', 'coder', 'agent', 'proxy',
            'daemon', 'virus', 'worm', 'bot', 'droid',
            'reaper', 'shadow', 'wraith', 'specter', 'shade',
            'entity', 'unit', 'core', 'nexus', 'cypher',
            'breach', 'exploit', 'overflow', 'inject', 'root',
            'kernel', 'shell', 'terminal', 'console', 'script',
            'raven', 'wolf', 'viper', 'hawk', 'lynx',
            'phantom', 'signal', 'cipher', 'vector', 'forge',
            'circuit', 'photon', 'glider', 'shard', 'vault',
            'beacon', 'torrent', 'crypt', 'grid', 'orbit'
        ];

        const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
        const noun = nouns[Math.floor(Math.random() * nouns.length)];

        return `${adj}_${noun}#${suffix}`;
    },

    stripPubkeySuffix(nym) {
        if (!nym) return nym;
        // Only strip a trailing #xxxx where xxxx is exactly 4 hex chars (pubkey suffix).
        return nym.replace(/#[0-9a-f]{4}$/i, '');
    },

    formatNymWithPubkey(nym, pubkey) {
        if (pubkey && /^[0-9a-f]{64}$/i.test(pubkey)) {
            const baseName = nym.replace(/#[0-9a-f]{4}$/i, '');
            return `${this.escapeHtml(baseName)}<span class="nym-suffix">#${this.getPubkeySuffix(pubkey)}</span>`;
        }

        const suffixMatch = nym.match(/#([0-9a-f]{4})$/i);
        if (suffixMatch) {
            const baseName = nym.substring(0, nym.length - 5);
            return `${this.escapeHtml(baseName)}<span class="nym-suffix">#${suffixMatch[1]}</span>`;
        }

        const suffix = pubkey ? pubkey.slice(-4) : '????';
        return `${this.escapeHtml(nym)}<span class="nym-suffix">#${suffix}</span>`;
    },

    updateSidebarAvatar() {
        const el = document.getElementById('sidebarAvatar');
        if (el && this.pubkey) {
            if (typeof this._clearNymIdentitySkel === 'function') this._clearNymIdentitySkel();
            const pubkey = this.pubkey;
            el.setAttribute('data-avatar-pubkey', pubkey);
            const src = this.getAvatarUrl(pubkey);
            const fallback = this.generateAvatarSvg(pubkey);
            el.onerror = function () { this.onerror = null; this.src = fallback; };
            if (el.getAttribute('src') !== src) el.src = src;
        }
    },

    getPubkeySuffix(pubkey) {
        if (typeof pubkey !== 'string' || pubkey.length < 4) return '????';
        const tail = pubkey.slice(-4);
        return /^[0-9a-f]{4}$/i.test(tail) ? tail : '????';
    },

    // 64-char hex pubkey or npub/nprofile, normalized to lowercase hex; null otherwise.
    normalizePubkeyInput(value) {
        const raw = String(value == null ? '' : value)
            .trim()
            .replace(/^nostr:/i, '')
            .replace(/^@/, '');
        if (/^[0-9a-f]{64}$/i.test(raw)) return raw.toLowerCase();
        if (!/^(npub|nprofile)1/i.test(raw)) return null;
        const nip19 = window.NostrTools && window.NostrTools.nip19;
        if (!nip19) return null;
        try {
            const decoded = nip19.decode(raw);
            if (decoded.type === 'npub') return String(decoded.data).toLowerCase();
            if (decoded.type === 'nprofile' && decoded.data && decoded.data.pubkey) {
                return String(decoded.data.pubkey).toLowerCase();
            }
        } catch (_) { }
        return null;
    },

    isPubkeyInput(value) {
        return this.normalizePubkeyInput(value) !== null;
    },

    npubFromPubkey(pubkey) {
        if (!/^[0-9a-f]{64}$/i.test(pubkey || '')) return '';
        const nip19 = window.NostrTools && window.NostrTools.nip19;
        if (!nip19) return '';
        try { return nip19.npubEncode(String(pubkey).toLowerCase()); } catch (_) { return ''; }
    },

    // 'npub' (default) or 'hex'; persisted and toggled from the user context menu.
    getPubkeyDisplayFormat() {
        try {
            return localStorage.getItem('nym_pubkey_format') === 'hex' ? 'hex' : 'npub';
        } catch (_) { return 'npub'; }
    },

    setPubkeyDisplayFormat(format) {
        const value = format === 'hex' ? 'hex' : 'npub';
        try { localStorage.setItem('nym_pubkey_format', value); } catch (_) { }
        return value;
    },

    togglePubkeyDisplayFormat() {
        const next = this.setPubkeyDisplayFormat(
            this.getPubkeyDisplayFormat() === 'npub' ? 'hex' : 'npub');
        if (typeof this.notePrefChanged === 'function') this.notePrefChanged('pubkeyFormat');
        return next;
    },

    // Falls back to hex when nostr-tools hasn't loaded or the key isn't encodable.
    formatPubkeyForDisplay(pubkey, format) {
        const hex = String(pubkey == null ? '' : pubkey);
        const want = format || this.getPubkeyDisplayFormat();
        if (want !== 'npub') return hex;
        return this.npubFromPubkey(hex) || hex;
    },

    // Canonical `nsec1…` from either form, so a stored login always reveals the nsec.
    nsecFromPrivkeyInput(value) {
        const hex = this.normalizePrivkeyInput(value);
        if (!hex) return '';
        const nip19 = window.NostrTools && window.NostrTools.nip19;
        if (!nip19) return '';
        const bytes = new Uint8Array(32);
        for (let i = 0; i < 32; i++) bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
        try { return nip19.nsecEncode(bytes); } catch (_) { return ''; }
    },

    // nsec or 64-char hex private key, normalized to lowercase hex; null otherwise.
    normalizePrivkeyInput(value) {
        const raw = String(value == null ? '' : value).trim().replace(/^nostr:/i, '');
        if (/^[0-9a-f]{64}$/i.test(raw)) return raw.toLowerCase();
        if (!/^nsec1/i.test(raw)) return null;
        const nip19 = window.NostrTools && window.NostrTools.nip19;
        if (!nip19) return null;
        try {
            const decoded = nip19.decode(raw);
            if (decoded.type === 'nsec') {
                const data = decoded.data;
                if (typeof data === 'string') return data.toLowerCase();
                return Array.from(data).map(b => b.toString(16).padStart(2, '0')).join('');
            }
        } catch (_) { }
        return null;
    },

    parseNymFromDisplay(displayNym) {
        if (!displayNym) return 'nym';

        // [\s\S]* because SVG flair icons contain newlines.
        let cleaned = displayNym.replace(/<span class="nym-suffix">[\s\S]*$/, '').trim();

        cleaned = cleaned.replace(/<[^>]*>/g, '').trim();

        cleaned = cleaned.replace(/&lt;/g, '').replace(/&gt;/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').trim();

        return cleaned.replace(/#[0-9a-f]{4}$/i, '') || cleaned || 'nym';
    },

    // Deterministic identicon as a data URI, so no external network requests; cached per seed.
    generateAvatarSvg(seed) {
        const key = String(seed == null ? '' : seed);
        const cache = this._avatarSvgCache;
        const cached = cache.get(key);
        if (cached) {
            cache.delete(key);
            cache.set(key, cached);
            return cached;
        }

        // FNV-1a-ish 32-bit hash, then Mulberry32 PRNG for stable randomness.
        let h = 2166136261 >>> 0;
        for (let i = 0; i < key.length; i++) {
            h ^= key.charCodeAt(i);
            h = Math.imul(h, 16777619) >>> 0;
        }
        let s = h || 1;
        const rand = () => {
            s = (s + 0x6D2B79F5) >>> 0;
            let t = Math.imul(s ^ (s >>> 15), 1 | s);
            t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };

        const hue = Math.floor(rand() * 360);
        const sat = 60 + Math.floor(rand() * 25);
        const light = 50 + Math.floor(rand() * 15);
        const fg = `hsl(${hue},${sat}%,${light}%)`;
        const bgHue = (hue + 180) % 360;
        const bg = `hsl(${bgHue},25%,18%)`;

        // 5x5 grid, mirrored horizontally; cells are 16px so the image is 80x80.
        const cell = 16;
        const cols = 5;
        const rows = 5;
        const half = Math.ceil(cols / 2);
        let rects = '';
        for (let y = 0; y < rows; y++) {
            for (let x = 0; x < half; x++) {
                if (rand() < 0.5) {
                    rects += `<rect x="${x * cell}" y="${y * cell}" width="${cell}" height="${cell}"/>`;
                    const mirror = cols - 1 - x;
                    if (mirror !== x) {
                        rects += `<rect x="${mirror * cell}" y="${y * cell}" width="${cell}" height="${cell}"/>`;
                    }
                }
            }
        }

        const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 80" width="80" height="80" shape-rendering="crispEdges"><rect width="80" height="80" fill="${bg}"/><g fill="${fg}">${rects}</g></svg>`;
        const dataUri = 'data:image/svg+xml;base64,' + btoa(svg);
        cache.set(key, dataUri);
        const MAX_AVATAR_CACHE = 5000;
        if (cache.size > MAX_AVATAR_CACHE) {
            const firstKey = cache.keys().next().value;
            if (firstKey !== undefined) cache.delete(firstKey);
        }
        return dataUri;
    },

    getAvatarUrl(pubkey) {
        if (this.isVerifiedBot(pubkey)) return this.verifiedBot.picture;
        const blob = this.avatarBlobCache.get(pubkey);
        if (blob) {
            this.avatarBlobCache.delete(pubkey);
            this.avatarBlobCache.set(pubkey, blob);
            return blob;
        }
        const custom = this.userAvatars.get(pubkey);
        if (custom) return this._profileMediaUrl(custom);
        return this.generateAvatarSvg(pubkey);
    },

    _profileMediaUrl(url) {
        if (typeof url !== 'string' || !/^https?:/i.test(url)) return url;
        return this._mediaProxyDown() ? url : this.getProxiedMediaUrl(url);
    },

    _mediaProxyDown() {
        return !!this._mediaProxyDownAt && Date.now() - this._mediaProxyDownAt < 5 * 60 * 1000;
    },

    _fetchProfileMedia(url) {
        const fetchUrl = this.getProxiedMediaUrl(url);
        const viaProxy = fetchUrl !== url;
        const noteDown = (errOrResponse) => {
            if (viaProxy && this._proxyUnreachable(errOrResponse)) this._mediaProxyDownAt = Date.now();
        };
        return this._throttledProxyFetch(fetchUrl, { mode: 'cors' })
            .then(r => {
                if (!r.ok) { noteDown(r); throw new Error(r.status); }
                if (viaProxy) this._mediaProxyDownAt = 0;
                return r.blob();
            }, (err) => { noteDown(err); throw err; });
    },

    _evictAvatarBlobIfFull() {
        const MAX = 200;
        if (this.avatarBlobCache.size <= MAX) return;
        const it = this.avatarBlobCache.keys();
        while (this.avatarBlobCache.size > MAX) {
            const k = it.next().value;
            if (k === undefined) break;
            if (k === this.pubkey) continue;
            const url = this.avatarBlobCache.get(k);
            this.avatarBlobCache.delete(k);
            if (url && url.startsWith('blob:')) URL.revokeObjectURL(url);
        }
    },

    cacheAvatarImage(pubkey, url) {
        if (this.isVerifiedBot(pubkey)) return Promise.resolve();
        if (this.avatarBlobCache.has(pubkey)) return Promise.resolve();
        if (this.avatarBlobInflight.has(pubkey)) return this.avatarBlobInflight.get(pubkey);
        // Negative cache: don't re-fetch a failed URL on every redelivery (causes identicon flicker).
        if (!this._avatarFetchFailed) this._avatarFetchFailed = new Map();
        const failed = this._avatarFetchFailed.get(pubkey);
        const recentlyFailed = failed && failed.url === url && (Date.now() - failed.at) < 10 * 60 * 1000;
        if (recentlyFailed) return Promise.resolve();
        const p = this._fetchProfileMedia(url)
            .then(blob => {
                this._avatarFetchFailed.delete(pubkey);
                const old = this.avatarBlobCache.get(pubkey);
                if (old) URL.revokeObjectURL(old);
                const objectUrl = URL.createObjectURL(blob);
                this.avatarBlobCache.set(pubkey, objectUrl);
                this._evictAvatarBlobIfFull();
                this.updateRenderedAvatars(pubkey, objectUrl);
                if (typeof this.persistAvatarBlob === 'function') {
                    const ts = (this._kind0Ts && this._kind0Ts.get(pubkey)) || null;
                    this.persistAvatarBlob(pubkey, blob, url, ts);
                }
            })
            .catch(() => {
                const repeatFailure = failed && failed.url === url;
                this._avatarFetchFailed.set(pubkey, { url, at: Date.now() });
                if (!repeatFailure) this.updateRenderedAvatars(pubkey, url);
            })
            .finally(() => { this.avatarBlobInflight.delete(pubkey); });
        this.avatarBlobInflight.set(pubkey, p);
        return p;
    },

    cacheBannerImage(pubkey, url) {
        if (this.isVerifiedBot(pubkey)) return Promise.resolve();
        if (this.bannerBlobCache.has(pubkey)) return Promise.resolve();
        if (this.bannerBlobInflight.has(pubkey)) return this.bannerBlobInflight.get(pubkey);
        const p = this._fetchProfileMedia(url)
            .then(blob => {
                const old = this.bannerBlobCache.get(pubkey);
                if (old) URL.revokeObjectURL(old);
                const objectUrl = URL.createObjectURL(blob);
                this.bannerBlobCache.set(pubkey, objectUrl);
                // Go through _applyCtxBanner; setting src alone leaves the <img> hidden if the card opened first.
                if (typeof this.updateRenderedBanner === 'function') {
                    this.updateRenderedBanner(pubkey);
                }
                if (typeof this.persistBannerBlob === 'function') {
                    const ts = (this._kind0Ts && this._kind0Ts.get(pubkey)) || null;
                    this.persistBannerBlob(pubkey, blob, url, ts);
                }
            })
            .catch(() => {
                if (this._mediaProxyDown() && typeof this.updateRenderedBanner === 'function') this.updateRenderedBanner(pubkey);
            })
            .finally(() => { this.bannerBlobInflight.delete(pubkey); });
        this.bannerBlobInflight.set(pubkey, p);
        return p;
    },

    getBannerUrl(pubkey) {
        if (this.isVerifiedBot(pubkey)) return this.verifiedBot.banner;
        const blob = this.bannerBlobCache.get(pubkey);
        if (blob) return blob;
        const banner = this.userBanners.get(pubkey) || null;
        return this._profileMediaUrl(banner);
    },

    getBio(pubkey) {
        return this.userBios.get(pubkey) || '';
    },

    isOwnMediaUrl(url) {
        if (typeof url !== 'string' || !url) return false;
        if (url.startsWith('/')) return !url.startsWith('//');
        if (!/^https?:\/\//i.test(url)) return false;
        try {
            const host = new URL(url).hostname.toLowerCase();
            return host === location.hostname.toLowerCase() || host === 'nymchat.app' || host.endsWith('.nymchat.app');
        } catch (_) {
            return false;
        }
    },

    // Returns a proxied URL for media to hide the user's IP.
    getProxiedMediaUrl(originalUrl) {
        if (this.isOwnMediaUrl(originalUrl)) return originalUrl;
        const base = this._mediaProxyBase();
        if (!base) return originalUrl;
        return `${base}?url=${encodeURIComponent(originalUrl)}`;
    },

    // The emoji flag tells the proxy to apply a long edge-cache TTL.
    getProxiedEmojiUrl(originalUrl) {
        if (this.isOwnMediaUrl(originalUrl)) return originalUrl;
        const base = this._mediaProxyBase();
        if (!base) return originalUrl;
        return `${base}?emoji=1&url=${encodeURIComponent(originalUrl)}`;
    },

    _getBlossomUploadUrl(server) {
        const host = server || BLOSSOM_SERVERS[0];
        const base = this._mediaProxyBase();
        if (base) {
            return `${base}?action=upload&server=${encodeURIComponent(host)}`;
        }
        return `${host.replace(/\/$/, '')}/upload`;
    },

    _getBlossomMirrorUrl(server) {
        const base = this._mediaProxyBase();
        if (base) {
            return `${base}?action=mirror&server=${encodeURIComponent(server)}`;
        }
        return `${server.replace(/\/$/, '')}/mirror`;
    },

    _blossomFetch(url, opts) {
        const base = this._mediaProxyBase();
        if (base && url.startsWith(base)) return this._edgeFetch(url, opts);
        return fetch(url, opts);
    },

    _blossomTypeAllowed(type) {
        return type === 'application/octet-stream' || ['image/', 'video/', 'audio/'].some(p => type.startsWith(p));
    },

    async _signBlossomEvent(hashHex, tType = 'upload') {
        const now = Math.floor(Date.now() / 1000);
        const event = {
            kind: 24242,
            created_at: now,
            tags: [
                ['t', tType],
                ['x', hashHex],
                ['expiration', String(now + 600)]
            ],
            content: tType === 'mirror' ? 'Mirror blob' : 'Uploading blob with SHA-256 hash'
        };
        const NT = window.NostrTools;
        const signed = NT.finalizeEvent(event, NT.generateSecretKey());
        return btoa(JSON.stringify(signed));
    },

    _blossomType(file) {
        return String((file && file.type) || '').split(';')[0].trim().toLowerCase() || 'application/octet-stream';
    },

    async _putToBlossom(file, hashHex, server, signal) {
        const type = this._blossomType(file);
        if (!this._blossomTypeAllowed(type)) {
            const err = new Error('Content type not allowed: ' + type);
            err.status = 415;
            throw err;
        }
        const auth = await this._signBlossomEvent(hashHex, 'upload');
        const resp = await this._blossomFetch(this._getBlossomUploadUrl(server), {
            method: 'PUT',
            headers: {
                'Authorization': `Nostr ${auth}`,
                'Content-Type': type
            },
            body: file,
            signal
        });
        if (!resp.ok) {
            const MN = window.NymMediaNotes;
            const reason = (resp.headers && resp.headers.get('X-Reason')) || '';
            let body = '';
            try { body = await resp.text(); } catch (_) { }
            const err = new Error(MN ? MN.blossomFailureText(resp.status, reason, body) : `HTTP ${resp.status}`);
            err.status = resp.status;
            throw err;
        }
        const data = await resp.json();
        if (!data.url) throw new Error('No URL in response');
        return data.url;
    },

    async _uploadWithFallback(file, hashHex, signal) {
        const MN = window.NymMediaNotes;
        const failures = [];
        if (!this._blossomRejects) this._blossomRejects = new Set();
        const type = this._blossomType(file);
        const candidates = BLOSSOM_SERVERS.filter(s => !this._blossomRejects.has(s + ' ' + type));
        const limitMs = this._uploadHostTimeoutMs || Math.max(UPLOAD_HOST_TIMEOUT_MS, Math.ceil((file && file.size || 0) / UPLOAD_MIN_BYTES_PER_MS));
        const outerReason = () => (signal && signal.reason && signal.reason.name === 'AbortError' ? signal.reason : new DOMException('Aborted', 'AbortError'));
        for (const server of (candidates.length ? candidates : BLOSSOM_SERVERS)) {
            if (signal && signal.aborted) throw outerReason();
            const ctl = new AbortController();
            const onAbort = () => ctl.abort(outerReason());
            if (signal) signal.addEventListener('abort', onAbort, { once: true });
            let timedOut = false;
            const timer = setTimeout(() => { timedOut = true; ctl.abort(new DOMException('timeout', 'TimeoutError')); }, limitMs);
            try {
                const url = await this._putToBlossom(file, hashHex, server, ctl.signal);
                return { url, server };
            } catch (e) {
                if (signal && signal.aborted) throw outerReason();
                if (timedOut) {
                    const secs = Math.round(limitMs / 1000);
                    const why = typeof this.uiText === 'function' ? this.uiText('timed out after {s} s') : 'timed out after {s} s';
                    console.warn('[upload] ' + server + ' timed out after ' + secs + ' s');
                    failures.push(server.replace(/^https?:\/\//, '') + ' (' + type + '): ' + why.split('{s}').join(String(secs)));
                    continue;
                }
                if (e && e.name === 'AbortError') throw e;
                const text = (e && e.message) || 'failed';
                const rejects = MN ? MN.blossomRejectsType(e && e.status, text) : (e && e.status === 415);
                if (rejects) this._blossomRejects.add(server + ' ' + type);
                failures.push(server.replace(/^https?:\/\//, '') + ' (' + type + '): ' + text);
            } finally {
                clearTimeout(timer);
                if (signal) signal.removeEventListener('abort', onAbort);
            }
        }
        const err = new Error(failures.length ? failures.join('; ') : 'All Blossom servers failed');
        err.failures = failures;
        throw err;
    },

    async _uploadFileWithProgress(file, labelText, opts = {}) {
        const usingGlobalBar = !opts.container;
        const container = opts.container || document.getElementById('uploadProgress');
        const fill = opts.fill || document.getElementById('progressFill');
        const labelEl = opts.labelEl || document.getElementById('uploadProgressLabel');
        const abort = new AbortController();
        if (usingGlobalBar) this._uploadAbort = abort;
        try {
            if (container) container.classList.add('active');
            if (labelEl) labelEl.textContent = labelText || 'Uploading…';
            if (fill) fill.style.width = '15%';
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashHex = Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, '0')).join('');
            if (fill) fill.style.width = '55%';
            const { url, server } = await this._uploadWithFallback(file, hashHex, abort.signal);
            if (fill) fill.style.width = '100%';
            if (opts.registerFallbacks) this._registerMediaFallbacks(url, hashHex, server);
            else this._mirrorBlobBackground(hashHex, url, server).catch(() => { });
            return { url, server, hashHex };
        } finally {
            if (this._uploadAbort === abort) this._uploadAbort = null;
            setTimeout(() => { if (container) container.classList.remove('active'); }, 500);
        }
    },

    imetaTagsForContent(content) {
        if (!content) return [];
        const MN = window.NymMediaNotes;
        const noteTags = MN ? MN.imetaTagsForContent(content, (u) => (this.mediaFallbacks && this.mediaFallbacks.get(u)) || []) : [];
        if (noteTags.length) content = MN.stripMediaNotes(content);
        if (!this.mediaFallbacks || !this.mediaFallbacks.size) return noteTags;
        const tags = noteTags.slice();
        const re = /(https?:\/\/[^\s]+\.(?:jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov|m4a|mp3|aac|opus|wav|oga|flac)(?:\?[^\s]*)?)/gi;
        const seen = new Set();
        let m;
        while ((m = re.exec(content)) !== null) {
            const url = m[1];
            if (seen.has(url)) continue;
            seen.add(url);
            const mirrors = this.mediaFallbacks.get(url);
            if (mirrors && mirrors.length) {
                const tag = ['imeta', `url ${url}`];
                mirrors.forEach(mu => tag.push(`fallback ${mu}`));
                tags.push(tag);
            }
        }
        return tags;
    },

    ingestImetaTags(tags) {
        if (!tags || !tags.length) return;
        if (!this.mediaFallbacks) this.mediaFallbacks = new Map();
        for (const tag of tags) {
            if (!Array.isArray(tag) || tag[0] !== 'imeta') continue;
            let primary = null;
            const fallbacks = [];
            for (let i = 1; i < tag.length; i++) {
                const part = tag[i];
                if (typeof part !== 'string') continue;
                if (part.startsWith('url ')) primary = part.slice(4).trim().split('#nym:')[0];
                else if (part.startsWith('fallback ')) fallbacks.push(part.slice(9).trim());
            }
            if (primary && fallbacks.length) {
                const existing = this.mediaFallbacks.get(primary) || [];
                const merged = Array.from(new Set([...existing, ...fallbacks]));
                this.mediaFallbacks.set(primary, merged);
                if (typeof this._invalidateFormatCtx === 'function') this._invalidateFormatCtx();
            }
        }
    },

    _predictMirrorUrl(server, hashHex, primaryUrl) {
        const base = server.replace(/\/$/, '');
        const m = primaryUrl.match(/\.([a-z0-9]{2,5})(?:\?|$)/i);
        const ext = m ? `.${m[1].toLowerCase()}` : '';
        return `${base}/${hashHex}${ext}`;
    },

    async _mirrorBlobBackground(hashHex, primaryUrl, excludeServer) {
        const remaining = BLOSSOM_SERVERS.filter(s => s !== excludeServer);
        if (!remaining.length) return [];
        const auth = await this._signBlossomEvent(hashHex, 'upload');
        const mirrors = [];
        await Promise.all(remaining.map(async (server) => {
            try {
                const resp = await this._blossomFetch(this._getBlossomMirrorUrl(server), {
                    method: 'PUT',
                    headers: {
                        'Authorization': `Nostr ${auth}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ url: primaryUrl })
                });
                if (!resp.ok) return;
                const data = await resp.json().catch(() => null);
                const url = (data && data.url) ? data.url : this._predictMirrorUrl(server, hashHex, primaryUrl);
                mirrors.push(url);
            } catch (_) { }
        }));
        return mirrors;
    },

    // Fetch missing kind 0 profiles for list UIs so default nyms/avatars get replaced.
    ensureListProfiles(rootEl, pubkeys, onResolved) {
        const list = Array.isArray(pubkeys) ? pubkeys : Array.from(pubkeys || []);
        const wanted = new Set();
        const missing = [];
        for (const pk of list) {
            if (!pk || pk === this.pubkey || wanted.has(pk)) continue;
            wanted.add(pk);
            if (this.users.has(pk) && this.userAvatars && this.userAvatars.has(pk)) continue;
            missing.push(pk);
        }
        if (!missing.length) return;
        if (typeof this.fetchProfileDirect !== 'function') {
            for (const pk of missing) { try { this.queueProfileFetch(pk); } catch (_) { } }
            return;
        }
        const look = (pk) => {
            const u = this.users.get(pk);
            return (u ? 'u' + (u.nym || '') : '-') + '|' + ((this.userAvatars && this.userAvatars.get(pk)) || '');
        };
        const before = new Map(missing.map(pk => [pk, look(pk)]));
        Promise.all(missing.map(pk => this.fetchProfileDirect(pk).catch(() => { }))).then(() => {
            const changed = missing.filter(pk => look(pk) !== before.get(pk));
            if (!changed.length) return;
            if (typeof onResolved === 'function') { try { onResolved(changed); } catch (_) { } return; }
            if (!rootEl || !rootEl.isConnected) return;
            const wantedLower = new Set(Array.from(wanted).map(pk => pk.toLowerCase()));
            rootEl.querySelectorAll('[data-pubkey]').forEach(row => {
                const pk = (row.dataset.pubkey || '').toLowerCase();
                if (pk && wantedLower.has(pk)) this._refreshListRowNym(row, pk);
            });
        });
    },

    _refreshListRowNym(row, pubkey) {
        const user = this.users.get(pubkey);
        const baseNym = this.parseNymFromDisplay(user ? user.nym : this.getNymFromPubkey(pubkey));
        // Never clobber an authoritative nym the row already shows.
        if (baseNym === 'nym') return;
        const suffix = this.getPubkeySuffix(pubkey);
        const nameHtml = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
        const reactorEl = row.querySelector('.reactors-modal-nym');
        if (reactorEl) { reactorEl.innerHTML = nameHtml; return; }
        const ctxEl = row.querySelector('.group-ctx-member-name');
        if (ctxEl) { ctxEl.innerHTML = nameHtml; return; }
        const infoEl = row.querySelector('.group-info-nym');
        if (infoEl) {
            const flair = (typeof this.getFlairForUser === 'function' && this.getFlairForUser(pubkey)) || '';
            infoEl.innerHTML = `${nameHtml}${flair}`;
        }
    },

    hasResolvedNym(pubkey) {
        const user = this.users.get(pubkey);
        if (!user || !user.nym) return false;
        const base = this.parseNymFromDisplay(user.nym);
        return !!base && base.toLowerCase() !== 'nym';
    },

    resolveDisplayNym(pubkey, storedAuthor) {
        const user = pubkey && this.users.get(pubkey);
        if (user && user.nym) {
            const known = this.parseNymFromDisplay(user.nym);
            if (known && known.toLowerCase() !== 'nym') return known;
        }
        const convo = pubkey && this.pmConversations && this.pmConversations.get(pubkey);
        if (convo && convo.nym) {
            const known = this.parseNymFromDisplay(convo.nym);
            if (known && known.toLowerCase() !== 'nym') return known;
        }
        const stored = this.parseNymFromDisplay(storedAuthor);
        return stored || 'nym';
    },

    _propagateNymChange(pubkey, nym, prevBase) {
        const nextBase = this.parseNymFromDisplay(nym);
        if (!nextBase || nextBase === prevBase || nextBase.toLowerCase() === 'nym') return;
        this.updateStoredNymsForPubkey(pubkey, nextBase);
        if (typeof this.updatePMNicknameFromProfile === 'function') {
            this.updatePMNicknameFromProfile(pubkey, nextBase);
        }
    },

    updateStoredNymsForPubkey(pubkey, baseNym) {
        if (!pubkey || !baseNym) return;
        const clean = this.parseNymFromDisplay(baseNym).substring(0, 20);
        if (!clean || clean.toLowerCase() === 'nym') return;
        const display = `${clean}#${this.getPubkeySuffix(pubkey)}`;
        const sweep = (store, persist) => {
            if (!store || typeof store.forEach !== 'function') return;
            store.forEach((list, key) => {
                if (!Array.isArray(list)) return;
                let touched = false;
                for (const m of list) {
                    if (!m || m.pubkey !== pubkey || m.author === display) continue;
                    m.author = display;
                    touched = true;
                }
                if (!touched) return;
                if (this.channelDOMCache) this.channelDOMCache.delete(key);
                if (typeof persist === 'function') {
                    try { persist.call(this, key); } catch (_) { }
                }
            });
        };
        sweep(this.messages, this.persistChannelMessages);
        sweep(this.pmMessages, this.persistPMMessages);
        const safePk = this._safePubkey(pubkey);
        if (!safePk) return;
        document.querySelectorAll(`.message[data-pubkey="${safePk}"]`).forEach(el => {
            el.dataset.author = display;
        });
    },

    updateRenderedAvatars(pubkey, avatarUrl) {
        const safePk = this._safePubkey(pubkey);
        if (!safePk) return;
        if (this.isVerifiedBot(pubkey)) avatarUrl = this.verifiedBot.picture;
        else avatarUrl = this._profileMediaUrl(avatarUrl);
        if (!this._avatarUpdateQueue) this._avatarUpdateQueue = new Map();
        this._avatarUpdateQueue.set(safePk, { url: avatarUrl, pubkey });
        if (this._avatarUpdateRaf) return;
        this._avatarUpdateRaf = requestAnimationFrame(() => this._flushAvatarUpdates());
    },

    _flushAvatarUpdates() {
        this._avatarUpdateRaf = null;
        const queue = this._avatarUpdateQueue;
        if (!queue || queue.size === 0) return;
        this._avatarUpdateQueue = new Map();
        const fallbackCache = new Map();
        const fallbackFor = (pk) => {
            let f = fallbackCache.get(pk);
            if (f === undefined) { f = this.generateAvatarSvg(pk); fallbackCache.set(pk, f); }
            return f;
        };
        document.querySelectorAll('img[data-avatar-pubkey]').forEach(img => {
            const pk = img.getAttribute('data-avatar-pubkey');
            const entry = queue.get(pk);
            if (!entry) return;
            // Skip rows already showing this URL to avoid canceling an in-flight load (spurious error swap).
            if (img.getAttribute('src') === entry.url) return;
            const fallback = fallbackFor(pk);
            img.onerror = function () { this.onerror = null; this.src = fallback; };
            img.src = entry.url;
        });
        const ctxImg = document.getElementById('ctxAvatarImg');
        const ctxPk = this.contextMenuData ? this._safePubkey(this.contextMenuData.pubkey) : null;
        if (ctxImg && ctxPk && queue.has(ctxPk)) {
            const entry = queue.get(ctxPk);
            if (ctxImg.getAttribute('src') !== entry.url) {
                const fallback = fallbackFor(ctxPk);
                ctxImg.onerror = function () { this.onerror = null; this.src = fallback; };
                ctxImg.src = entry.url;
            }
        }
    },

    async uploadAvatar(file) {
        try {
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashHex = Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, '0')).join('');

            const { url, server } = await this._uploadWithFallback(file, hashHex);

            const oldBlob = this.avatarBlobCache.get(this.pubkey);
            if (oldBlob) URL.revokeObjectURL(oldBlob);
            this.avatarBlobCache.delete(this.pubkey);

            this.userAvatars.set(this.pubkey, url);
            this.cacheAvatarImage(this.pubkey, url);
            localStorage.setItem('nym_avatar_url', url);
            this.updateSidebarAvatar();
            this.updateRenderedAvatars(this.pubkey, url);
            await this.saveToNostrProfile();
            this.publishAvatarUpdate(url);

            this._mirrorBlobBackground(hashHex, url, server).catch(() => { });
            return url;
        } catch (error) {
            this.displaySystemMessage('Failed to upload avatar: ' + error.message);
            return null;
        }
    },

    removeAvatar() {
        const oldBlob = this.avatarBlobCache.get(this.pubkey);
        if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(this.pubkey); }
        this.userAvatars.delete(this.pubkey);
        if (typeof this.deleteCachedAvatar === 'function') this.deleteCachedAvatar(this.pubkey);
        localStorage.removeItem('nym_avatar_url');
        this.updateSidebarAvatar();
        this.updateRenderedAvatars(this.pubkey, this.getAvatarUrl(this.pubkey));
        this.saveToNostrProfile();
        this.publishAvatarUpdate('');
    },

    async uploadBanner(file) {
        try {
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashHex = Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, '0')).join('');

            const { url, server } = await this._uploadWithFallback(file, hashHex);

            const oldBlob = this.bannerBlobCache.get(this.pubkey);
            if (oldBlob) URL.revokeObjectURL(oldBlob);
            this.bannerBlobCache.delete(this.pubkey);
            this.userBanners.set(this.pubkey, url);
            this.cacheBannerImage(this.pubkey, url);
            localStorage.setItem('nym_banner_url', url);
            await this.saveToNostrProfile();

            this._mirrorBlobBackground(hashHex, url, server).catch(() => { });
            return url;
        } catch (error) {
            this.displaySystemMessage('Failed to upload banner: ' + error.message);
            return null;
        }
    },

    removeBanner() {
        const oldBlob = this.bannerBlobCache.get(this.pubkey);
        if (oldBlob) { URL.revokeObjectURL(oldBlob); this.bannerBlobCache.delete(this.pubkey); }
        this.userBanners.delete(this.pubkey);
        localStorage.removeItem('nym_banner_url');
        this.saveToNostrProfile();
    },

    async uploadWallpaper(file) {
        const minWidth = 1920;
        const minHeight = 1080;

        const validSize = await new Promise((resolve) => {
            const img = new Image();
            img.onload = () => {
                URL.revokeObjectURL(img.src);
                resolve(img.width >= minWidth && img.height >= minHeight);
            };
            img.onerror = () => {
                URL.revokeObjectURL(img.src);
                resolve(false);
            };
            img.src = URL.createObjectURL(file);
        });

        if (!validSize) {
            this.displaySystemMessage(`Wallpaper image must be at least ${minWidth}x${minHeight} pixels.`);
            return null;
        }

        try {
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashHex = Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, '0')).join('');

            const { url, server } = await this._uploadWithFallback(file, hashHex);
            await this._persistWallpaperBlob(file, url);
            this._setWallpaperBlobUrl(file);
            this._wallpaperCachedUrl = url;
            this._mirrorBlobBackground(hashHex, url, server).catch(() => { });
            return url;
        } catch (error) {
            this.displaySystemMessage('Failed to upload wallpaper: ' + error.message);
            return null;
        }
    },

    applyWallpaper(type, customUrl) {
        const layer = document.getElementById('wallpaperLayer');
        if (!layer) return;

        const presets = ['geometric', 'circuit', 'dots', 'waves', 'topography', 'hexagons', 'diamonds'];

        let targetClass = '';
        let targetImage = '';
        if (presets.includes(type)) {
            targetClass = `wallpaper-pattern-${type}`;
        } else if (type === 'custom' && (this.wallpaperBlobUrl || customUrl)) {
            targetClass = 'has-custom-wallpaper';
            const isLight = document.body.classList.contains('light-mode');
            const overlay = isLight
                ? 'rgba(245, 245, 242, 0.85)'
                : 'rgba(10, 10, 15, 0.82)';
            const src = this.wallpaperBlobUrl || customUrl;
            targetImage = `linear-gradient(${overlay}, ${overlay}), url('${src}')`;
        }

        const currentClass = [...layer.classList].find(c => c.startsWith('wallpaper-pattern-') || c === 'has-custom-wallpaper') || '';
        if (currentClass === targetClass && layer.style.backgroundImage === targetImage) return;

        presets.forEach(p => layer.classList.remove(`wallpaper-pattern-${p}`));
        layer.classList.remove('has-custom-wallpaper');
        layer.style.backgroundImage = targetImage;
        if (targetClass) layer.classList.add(targetClass);
    },

    saveWallpaper(type, customUrl) {
        localStorage.setItem('nym_wallpaper_type', type);
        if (type === 'custom' && customUrl) {
            localStorage.setItem('nym_wallpaper_custom_url', customUrl);
        } else {
            localStorage.removeItem('nym_wallpaper_custom_url');
            this._clearWallpaperCache();
        }
    },

    loadWallpaper() {
        const type = localStorage.getItem('nym_wallpaper_type') || 'geometric';
        const customUrl = localStorage.getItem('nym_wallpaper_custom_url') || '';
        this.applyWallpaper(type, customUrl);
        if (type === 'custom' && customUrl) {
            this._ensureWallpaperCached(customUrl);
        }
        return { type, customUrl };
    },

    async _persistWallpaperBlob(blob, url) {
        try {
            await this._cachePut('meta', { key: 'customWallpaper', blob, url });
        } catch (_) { }
    },

    _setWallpaperBlobUrl(blob) {
        if (this.wallpaperBlobUrl) URL.revokeObjectURL(this.wallpaperBlobUrl);
        this.wallpaperBlobUrl = URL.createObjectURL(blob);
    },

    _clearWallpaperCache() {
        try { this._cacheDelete('meta', 'customWallpaper'); } catch (_) { }
        if (this.wallpaperBlobUrl) {
            URL.revokeObjectURL(this.wallpaperBlobUrl);
            this.wallpaperBlobUrl = null;
        }
        this._wallpaperCachedUrl = null;
    },

    async _ensureWallpaperCached(customUrl) {
        if (this.wallpaperBlobUrl && this._wallpaperCachedUrl === customUrl) return;
        if (this._wallpaperCacheLoading === customUrl) return;
        this._wallpaperCacheLoading = customUrl;
        try {
            const meta = await this._cacheGetAll('meta');
            const entry = meta.find(m => m.key === 'customWallpaper');
            if (entry && entry.blob && entry.url === customUrl) {
                if (this._wallpaperCachedUrl !== customUrl) {
                    this._setWallpaperBlobUrl(entry.blob);
                }
            } else {
                const res = await fetch(customUrl);
                if (!res.ok) return;
                const blob = await res.blob();
                await this._persistWallpaperBlob(blob, customUrl);
                this._setWallpaperBlobUrl(blob);
            }
            this._wallpaperCachedUrl = customUrl;
            if ((localStorage.getItem('nym_wallpaper_type') || '') === 'custom') {
                this.applyWallpaper('custom', customUrl);
            }
        } catch (_) {
        } finally {
            if (this._wallpaperCacheLoading === customUrl) {
                this._wallpaperCacheLoading = null;
            }
        }
    },

    async uploadImage(fileOrFiles) {
        const files = Array.isArray(fileOrFiles) || fileOrFiles instanceof FileList
            ? Array.from(fileOrFiles)
            : [fileOrFiles];
        if (!files.length) return;

        const MAX_UPLOAD_SIZE = 50 * 1024 * 1024;
        for (const f of files) {
            if (f.size > MAX_UPLOAD_SIZE) {
                const isVid = f.type.startsWith('video/');
                this.displaySystemMessage((isVid ? 'Video' : 'Image') + ' files must be under 50MB. "' + (f.name || 'file') + '" is ' + (f.size / (1024 * 1024)).toFixed(1) + 'MB.');
                return;
            }
        }

        if (!this.mediaFallbacks) this.mediaFallbacks = new Map();

        if (!this.inPMMode && typeof this.sendImagesOverMesh === 'function' && typeof this.meshShouldCarry === 'function'
            && this.meshShouldCarry(this.currentGeohash || this.currentChannel)) {
            await this.sendImagesOverMesh(files);
            return;
        }

        const records = typeof this.addComposerAttachments === 'function'
            ? this.addComposerAttachments(files) : [];
        if (typeof this._refreshComposerOffsets === 'function') this._refreshComposerOffsets();

        const abortCtrl = new AbortController();
        this._uploadAbort = abortCtrl;
        const signal = abortCtrl.signal;

        try {
            for (const rec of records) {
                if (signal.aborted) break;
                await this._uploadOneAttachment(rec, signal);
            }
        } finally {
            if (this._uploadAbort === abortCtrl) this._uploadAbort = null;
        }
    },

    // Never throws: a failure marks only this tile retryable.
    async _uploadOneAttachment(rec, signal) {
        if (!rec || !rec.file) return;
        this.updateComposerAttachment(rec.id, { status: 'uploading', error: '' });
        const UA = window.NymUploadActivity;
        this._endAttachmentActivity(rec);
        rec.activity = UA && typeof this.beginChatActivity === 'function'
            ? this.beginChatActivity(UA.kindForMime(rec.file.type)) : null;
        try {
            const upload = typeof this.prepareAttachmentUpload === 'function'
                ? await this.prepareAttachmentUpload(rec) : rec.file;
            const arrayBuffer = await upload.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashHex = Array.from(new Uint8Array(hashBuffer))
                .map(b => b.toString(16).padStart(2, '0')).join('');
            const { url, server } = await this._uploadWithFallback(upload, hashHex, signal);
            this.updateComposerAttachment(rec.id, {
                status: 'done', url, hashHex, server, error: '',
                uploadedAs: { hd: !!rec.wantHd, once: !!rec.wantOnce, secret: rec.secret || null, mime: rec.onceMime || '', size: rec.onceSize || 0 },
            });
            if (!rec.wantOnce) this._registerMediaFallbacks(url, hashHex, server);
            if (typeof this.attachmentStale === 'function' && this.attachmentStale(rec)) {
                this.retryComposerAttachment(rec.id);
            }
        } catch (error) {
            if (error && error.name === 'AbortError') {
                if (typeof this.removeComposerAttachment === 'function') {
                    this.removeComposerAttachment(rec.id);
                }
                return;
            }
            this.updateComposerAttachment(rec.id, {
                status: 'failed',
                error: (error && error.message) ? String(error.message).slice(0, 120) : 'Upload failed',
            });
        } finally {
            this._endAttachmentActivity(rec);
        }
    },

    _endAttachmentActivity(rec) {
        if (!rec || rec.activity == null) return;
        const token = rec.activity;
        rec.activity = null;
        if (typeof this.endChatActivity === 'function') this.endChatActivity(token);
    },

    async retryComposerAttachment(id) {
        const rec = typeof this.composerAttachmentById === 'function'
            ? this.composerAttachmentById(id) : null;
        if (!rec || rec.status === 'uploading') return;
        const abortCtrl = new AbortController();
        const prev = this._uploadAbort;
        this._uploadAbort = abortCtrl;
        try {
            await this._uploadOneAttachment(rec, abortCtrl.signal);
        } finally {
            if (this._uploadAbort === abortCtrl) this._uploadAbort = prev || null;
        }
    },

    // Predicted + real mirrors, so a dead primary host doesn't take the message's media down.
    _registerMediaFallbacks(url, hashHex, server) {
        if (!this.mediaFallbacks) this.mediaFallbacks = new Map();
        const predicted = BLOSSOM_SERVERS
            .filter(s => s !== server)
            .map(s => this._predictMirrorUrl(s, hashHex, url));
        if (predicted.length) {
            this.mediaFallbacks.set(url, predicted);
            if (typeof this._invalidateFormatCtx === 'function') this._invalidateFormatCtx();
        }
        this._mirrorBlobBackground(hashHex, url, server)
            .then(mirrors => {
                if (mirrors && mirrors.length) {
                    const existing = this.mediaFallbacks.get(url) || [];
                    this.mediaFallbacks.set(url, Array.from(new Set([...mirrors, ...existing])));
                    if (typeof this._invalidateFormatCtx === 'function') this._invalidateFormatCtx();
                }
            })
            .catch(() => { });
    },

    cancelUpload() {
        if (this._uploadAbort) {
            const reason = new DOMException('Upload cancelled', 'AbortError');
            reason.userCancelled = true;
            try { this._uploadAbort.abort(reason); } catch (_) { }
        }
        if (typeof this.clearComposerAttachments === 'function') {
            this.clearComposerAttachments();
        }
        if (typeof this._refreshComposerOffsets === 'function') this._refreshComposerOffsets();
    },

    getNymFromPubkey(pubkey) {
        const user = this.users.get(pubkey);
        if (user) {
            const cleanNym = this.parseNymFromDisplay(user.nym);
            return `${cleanNym}#${this.getPubkeySuffix(pubkey)}`;
        }

        const pmConvo = Array.from(this.pmConversations.values())
            .find(conv => conv.pubkey === pubkey);
        if (pmConvo && pmConvo.nym) {
            const cleanNym = this.parseNymFromDisplay(pmConvo.nym);
            return `${cleanNym}#${this.getPubkeySuffix(pubkey)}`;
        }

        return `nym#${pubkey.slice(-4)}`;
    },

    getNymHtmlFromPubkey(pubkey) {
        return this.dimNymSuffix(this.getNymFromPubkey(pubkey));
    },

    dimNymSuffix(text) {
        const s = String(text == null ? '' : text);
        const m = s.match(/^([\s\S]*?)#([0-9a-f]{4})$/i);
        if (!m) return this.escapeHtml(s);
        return `${this.escapeHtml(m[1])}<span class="nym-suffix">#${m[2]}</span>`;
    },

    // Returns 'hidden' when the user opted out of broadcasting status; callers suppress the indicator.
    getEffectiveUserStatus(pubkey) {
        if (!pubkey) return 'offline';
        // Reflect our own hidden broadcast back to us so disabling clearly works.
        if (pubkey === this.pubkey && typeof this._awayEnsureRestored === 'function') this._awayEnsureRestored();
        if (pubkey === this.pubkey && this.settings && this.settings.showStatus === false) return 'hidden';
        // A friend sharing their real status privately ("Friends only") overrides the public 'hidden'.
        const sharesWithUs = this.friendsSharingStatus && this.friendsSharingStatus.has(pubkey);
        if (!sharesWithUs && this.statusHiddenUsers && this.statusHiddenUsers.has(pubkey)) return 'hidden';
        if (this.verifiedBotPubkeys && this.verifiedBotPubkeys.has(pubkey)) return 'online';
        const user = this.users.get(pubkey);
        const now = Date.now();
        const ACTIVE_THRESHOLD = 300000;
        const lastSeen = user ? (user.lastSeen || 0) : 0;
        const isRecent = (now - lastSeen) < ACTIVE_THRESHOLD;
        if (this.awayMessages && this.awayMessages.has(pubkey)) return 'away';
        if (user && user.status === 'away') return 'away';
        return isRecent ? 'online' : 'offline';
    },

    handleFriendPresenceRumor(rumor, pubkey) {
        if (!pubkey || pubkey === this.pubkey) return;
        // Only honor presence from known users or friends so strangers can't inject themselves as online.
        if (!this.isFriend?.(pubkey) && !this.users.has(pubkey)) return;
        const statusTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'status');
        const status = statusTag ? statusTag[1] : null;
        if (!status || status === 'hidden') return;

        if (!this.friendsSharingStatus) this.friendsSharingStatus = new Set();
        this.friendsSharingStatus.add(pubkey);
        if (this.statusHiddenUsers) this.statusHiddenUsers.delete(pubkey);

        const awayTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'away');
        if (status === 'away' && awayTag) {
            this.awayMessages.set(pubkey, awayTag[1]);
        } else if (status === 'online') {
            this.awayMessages.delete(pubkey);
        }

        const now = Date.now();
        if (this.users.has(pubkey)) {
            const user = this.users.get(pubkey);
            user.status = status;
            user.lastSeen = now;
        } else {
            const nymTag = (rumor.tags || []).find(t => Array.isArray(t) && t[0] === 'n');
            this.users.set(pubkey, {
                nym: nymTag ? this.stripPubkeySuffix(nymTag[1]) : this.getNymFromPubkey(pubkey),
                pubkey,
                lastSeen: now,
                status,
                channels: new Set()
            });
        }
        this.updateUserList();
        if (this.inPMMode && this.currentPM === pubkey && typeof this.refreshPMHeaderStatus === 'function') {
            this.refreshPMHeaderStatus();
        }
    },

    handlePresenceEvent(event) {
        const nymTag = event.tags.find(t => t[0] === 'n');
        const statusTag = event.tags.find(t => t[0] === 'status');
        const awayTag = event.tags.find(t => t[0] === 'away');
        const avatarUpdateTag = event.tags.find(t => t[0] === 'avatar-update');

        if (!statusTag) return;

        const pubkey = event.pubkey;
        const status = statusTag[1];
        const nym = nymTag ? this.stripPubkeySuffix(nymTag[1]) : null;
        const eventTime = event.created_at || 0;

        if (pubkey === this.pubkey) return;

        if (!this.presenceTimestamps) this.presenceTimestamps = new Map();
        const lastTimestamp = this.presenceTimestamps.get(pubkey) || 0;
        if (eventTime < lastTimestamp) return;
        this.presenceTimestamps.set(pubkey, eventTime);

        // Kind 30078 is redelivered on every resubscribe; only a real URL change may bust the cache (avoids flicker).
        if (avatarUpdateTag) {
            const newAvatarUrl = avatarUpdateTag[1];
            const prevUrl = this.userAvatars.get(pubkey);
            const clearCachedAvatar = () => {
                const oldBlob = this.avatarBlobCache.get(pubkey);
                if (oldBlob) URL.revokeObjectURL(oldBlob);
                this.avatarBlobCache.delete(pubkey);
                if (typeof this.deleteCachedAvatar === 'function') this.deleteCachedAvatar(pubkey);
            };

            if (newAvatarUrl) {
                if (newAvatarUrl !== prevUrl) {
                    clearCachedAvatar();
                    this.userAvatars.set(pubkey, newAvatarUrl);
                    this.cacheAvatarImage(pubkey, newAvatarUrl);
                    this.updateRenderedAvatars(pubkey, newAvatarUrl);
                } else if (!this.avatarBlobCache.has(pubkey)) {
                    this.cacheAvatarImage(pubkey, newAvatarUrl);
                }
            } else if (prevUrl || this.avatarBlobCache.has(pubkey)) {
                clearCachedAvatar();
                this.userAvatars.delete(pubkey);
                this.updateRenderedAvatars(pubkey, this.getAvatarUrl(pubkey));
            }
        }

        const shopUpdateTag = event.tags.find(t => t[0] === 'shop-update');
        if (shopUpdateTag && typeof this.invalidateShopCache === 'function') {
            this.invalidateShopCache(pubkey);
        }

        if (!this.statusHiddenUsers) this.statusHiddenUsers = new Set();
        if (status === 'hidden') {
            // "Friends only" friends broadcast 'hidden' but share real status privately; don't hide those.
            if (!(this.friendsSharingStatus && this.friendsSharingStatus.has(pubkey))) {
                this.statusHiddenUsers.add(pubkey);
            }
            this.awayMessages.delete(pubkey);
        } else {
            this.statusHiddenUsers.delete(pubkey);
        }

        if (status === 'away' && awayTag) {
            this.awayMessages.set(pubkey, awayTag[1]);
        } else if (status === 'online') {
            this.awayMessages.delete(pubkey);
        }

        if (this.users.has(pubkey)) {
            const user = this.users.get(pubkey);
            // Visibility is tracked in statusHiddenUsers so the user stays listed, just without a status dot.
            if (status !== 'hidden') user.status = status;
            if (nym) {
                const prevBase = this.parseNymFromDisplay(user.nym);
                user.nym = nym;
                this._propagateNymChange(pubkey, nym, prevBase);
            }
            this.updateUserList();
        }
        if (this.inPMMode && this.currentPM === pubkey && typeof this.refreshPMHeaderStatus === 'function') {
            this.refreshPMHeaderStatus();
        }
    },

    updateUserPresence(nym, pubkey, channel, geohash, createdAt) {
        const channelKey = geohash || channel;

        // Use created_at so historical messages don't falsely mark users as online.
        const eventTime = createdAt ? createdAt * 1000 : Date.now();

        const activeThreshold = 300000; // 5 minutes
        const isRecent = (Date.now() - eventTime) < activeThreshold;
        let baseStatus;
        if (this.awayMessages.has(pubkey)) {
            baseStatus = 'away';
        } else if (isRecent) {
            baseStatus = 'online';
        } else {
            baseStatus = 'offline';
        }

        if (!this.users.has(pubkey)) {
            this.users.set(pubkey, {
                nym: nym,
                pubkey: pubkey,
                lastSeen: eventTime,
                status: baseStatus,
                channels: new Set([channelKey])
            });
        } else {
            const user = this.users.get(pubkey);
            if (eventTime > user.lastSeen) {
                user.lastSeen = eventTime;
                user.status = baseStatus;
            }
            const prevBase = this.parseNymFromDisplay(user.nym);
            user.nym = nym;
            this._propagateNymChange(pubkey, nym, prevBase);
            if (!user.channels) user.channels = new Set();
            user.channels.add(channelKey);
        }

        if (!this.channelUsers.has(channelKey)) {
            this.channelUsers.set(channelKey, new Set());
        }
        this.channelUsers.get(channelKey).add(pubkey);

        if (this.users.size > 10000) this._evictStaleUsers();

        this.updateUserList();
    },

    // E.g. after a read receipt, so lurkers who only view messages still appear online.
    recordUserActivity(pubkey) {
        if (!pubkey || pubkey === this.pubkey) return;
        if (this.awayMessages && this.awayMessages.has(pubkey)) return;
        const now = Date.now();
        const user = this.users.get(pubkey);
        if (user) {
            user.lastSeen = now;
            if (user.status !== 'away') user.status = 'online';
        } else {
            this.users.set(pubkey, {
                nym: this.getNymFromPubkey(pubkey),
                pubkey: pubkey,
                lastSeen: now,
                status: 'online',
                channels: new Set()
            });
        }
        this.updateUserList();
    },

    updateUserList() {
        if (this._userListRafPending) return;
        this._userListRafPending = true;
        const raf = window.requestAnimationFrame || (cb => setTimeout(cb, 16));
        raf(() => {
            this._userListRafPending = false;
            this._doUpdateUserList();
        });
    },

    _doUpdateUserList() {
        const userListContent = document.getElementById('userListContent');
        if (!userListContent) return;

        const currentChannelKey = this.currentGeohash || this.currentChannel;
        const now = Date.now();
        const ACTIVE_THRESHOLD = 300000;

        let pmOnlyPubkeys = null;
        if (this.settings.groupChatPMOnlyMode) {
            pmOnlyPubkeys = new Set();
            this.pmConversations.forEach((_c, pk) => pmOnlyPubkeys.add(pk));
            this.groupConversations.forEach(g => {
                if (g.members) g.members.forEach(pk => pmOnlyPubkeys.add(pk));
            });
        }

        const themeBitchat = this.settings.theme === 'bitchat';
        const verifiedBotSet = this.verifiedBotPubkeys;
        const blockedUsers = this.blockedUsers;

        const candidates = [];
        let activeCount = 0;
        let channelUserCount = 0;

        this.users.forEach((user, pubkey) => {
            if (!user || !user.nym) return;
            if (blockedUsers.has(pubkey)) return;
            if (this.blockedKeywords.size && this.hasBlockedKeyword('', user.nym)) return;
            if (pmOnlyPubkeys && !pmOnlyPubkeys.has(pubkey)) return;
            if (pubkey !== this.pubkey && !this.isFriend?.(pubkey) &&
                typeof this.isGibberishNym === 'function' &&
                this._clientGatesActive() &&
                this.isGibberishNym(user.nym)) return;

            const isRecent = (now - user.lastSeen) < ACTIVE_THRESHOLD;
            const effectiveStatus = this.getEffectiveUserStatus(pubkey);
            const statusHidden = effectiveStatus === 'hidden';
            if (!statusHidden && effectiveStatus !== 'offline' && (isRecent || verifiedBotSet.has(pubkey))) {
                activeCount++;
            }

            if (!statusHidden && isRecent && user.channels && user.channels.has(currentChannelKey)) {
                channelUserCount++;
            }

            const sortKey = this.parseNymFromDisplay(user.nym).toLowerCase();
            candidates.push({ user, pubkey, effectiveStatus, sortKey, statusHidden });
        });

        const statusRank = s => s === 'online' ? 0 : (s === 'away' ? 1 : 2);
        candidates.sort((a, b) => {
            const r = statusRank(a.effectiveStatus) - statusRank(b.effectiveStatus);
            if (r !== 0) return r;
            return a.sortKey < b.sortKey ? -1 : (a.sortKey > b.sortKey ? 1 : 0);
        });

        let displayUsers = candidates;
        const term = this.userSearchTerm ? this.userSearchTerm.toLowerCase() : '';
        if (term) {
            displayUsers = [];
            for (let i = 0; i < candidates.length; i++) {
                if (candidates[i].sortKey.includes(term)) displayUsers.push(candidates[i]);
            }
        }

        const COLLAPSED_CAP = 20;
        const EXPANDED_STEP = 500;
        const isExpanded = this.listExpansionStates && this.listExpansionStates.get('userListContent');
        if (this._userListExpandedCap == null) this._userListExpandedCap = EXPANDED_STEP;
        const totalCount = displayUsers.length;
        let renderCap;
        if (term) {
            renderCap = totalCount;
        } else if (isExpanded) {
            renderCap = Math.min(totalCount, this._userListExpandedCap);
        } else {
            renderCap = Math.min(totalCount, COLLAPSED_CAP);
        }
        const renderUsers = renderCap < totalCount ? displayUsers.slice(0, renderCap) : displayUsers;

        const isLight = themeBitchat && document.body.classList.contains('light-mode');
        const sigParts = [
            themeBitchat ? (isLight ? 'bl' : 'bd') : 'n',
            term, totalCount, renderCap, isExpanded ? '1' : '0',
        ];
        for (let i = 0; i < renderUsers.length; i++) {
            const c = renderUsers[i];
            sigParts.push(c.pubkey, c.effectiveStatus[0], c.sortKey, c.statusHidden ? 'h' : 'v');
        }
        const sig = sigParts.join('|');

        if (sig !== this._userListSig) {
            this._userListSig = sig;
            this._renderUserListItems(userListContent, renderUsers, themeBitchat);
        }

        this._updateUserListViewMoreButton(userListContent, totalCount, renderCap, isExpanded, EXPANDED_STEP);

        const userListTitle = document.querySelector('#userList .nav-title-text');
        if (userListTitle) {
            userListTitle.textContent = `Nyms (${this.abbreviateNumber(activeCount)} online)`;
        }

        if (!this.inPMMode) {
            const meta = document.getElementById('channelMeta');
            if (meta) meta.textContent = `${this.abbreviateNumber(channelUserCount)} online nyms`;
        }

        this.refreshAutocompleteIfOpen();
        if (typeof this.refreshPMHeaderStatus === 'function') this.refreshPMHeaderStatus();
    },

    _renderUserListItems(container, displayUsers, themeBitchat) {
        // Hold the boot shimmer until real nyms arrive.
        if (displayUsers.length === 0 && container.querySelector('.sidebar-skeleton')) return;

        const existing = new Map();
        const itemEls = container.querySelectorAll('.user-item[data-pubkey]');
        for (let i = 0; i < itemEls.length; i++) {
            existing.set(itemEls[i].dataset.pubkey, itemEls[i]);
        }

        const fragment = document.createDocumentFragment();
        for (let i = 0; i < displayUsers.length; i++) {
            const { user, pubkey, effectiveStatus, statusHidden } = displayUsers[i];
            const safePk = this._safePubkey(pubkey);
            if (!safePk) continue;

            const baseNym = this.parseNymFromDisplay(user.nym);
            const userColorClass = themeBitchat ? this.getUserColorClass(pubkey) : '';
            const avatarSrc = this.getAvatarUrl(pubkey);
            const isDev = this.isVerifiedDeveloper(pubkey);
            const isBot = !isDev && this.verifiedBotPubkeys.has(pubkey);
            const flairKey = this._userFlairKey ? this._userFlairKey(pubkey) : '';
            const isFriend = this.isFriend(pubkey) ? 1 : 0;
            const fp = `${effectiveStatus}|${baseNym}|${userColorClass}|${avatarSrc}|${isDev?1:0}${isBot?1:0}|${flairKey}|${statusHidden?'h':'v'}|f${isFriend}`;

            let el = existing.get(safePk);
            if (el) {
                existing.delete(safePk);
                if (el._fp !== fp) {
                    this._updateUserItem(el, { baseNym, effectiveStatus, userColorClass, avatarSrc, pubkey: safePk, isDev, isBot, statusHidden });
                    el._fp = fp;
                }
            } else {
                el = this._createUserItem({ baseNym, effectiveStatus, userColorClass, avatarSrc, pubkey: safePk, isDev, isBot, statusHidden });
                el._fp = fp;
            }
            fragment.appendChild(el);
        }

        existing.forEach(el => el.remove());
        container.textContent = '';
        container.appendChild(fragment);

        if (!container._delegated) {
            container._delegated = true;
            const handler = (e) => {
                const item = e.target.closest && e.target.closest('.user-item[data-pubkey]');
                if (!item || !container.contains(item)) return;
                const pk = item.dataset.pubkey;
                if (!pk) return;
                const baseNym = item.dataset.nym || '';
                const suffix = this.getPubkeySuffix(pk);
                const flairHtml = this.getFlairForUser(pk);
                const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml}`;
                this.showContextMenu(e, displayNym, pk, null, null, true);
            };
            container.addEventListener('click', handler);
            container.addEventListener('contextmenu', handler);
        }
    },

    _createUserItem({ baseNym, effectiveStatus, userColorClass, avatarSrc, pubkey, isDev, isBot, statusHidden }) {
        const item = document.createElement('div');
        item.className = userColorClass ? `user-item list-item ${userColorClass}` : 'user-item list-item';
        item.dataset.pubkey = pubkey;
        item.dataset.nym = baseNym;

        const wrap = document.createElement('span');
        wrap.className = statusHidden ? 'user-avatar-wrap no-status' : 'user-avatar-wrap';

        const img = document.createElement('img');
        img.className = 'avatar-user-list';
        img.alt = '';
        img.loading = 'lazy';
        img.dataset.avatarPubkey = pubkey;
        img.src = avatarSrc;
        const fallback = this.generateAvatarSvg(pubkey);
        img.onerror = () => { img.onerror = null; img.src = fallback; };
        wrap.appendChild(img);

        const dot = document.createElement('span');
        dot.className = `user-status-dot status-${effectiveStatus}`;
        wrap.appendChild(dot);

        item.appendChild(wrap);

        const label = document.createElement('span');
        if (userColorClass) label.className = userColorClass;
        this._fillUserLabel(label, baseNym, pubkey, isDev, isBot);
        item.appendChild(label);
        return item;
    },

    _updateUserItem(el, { baseNym, effectiveStatus, userColorClass, avatarSrc, pubkey, isDev, isBot, statusHidden }) {
        el.className = userColorClass ? `user-item list-item ${userColorClass}` : 'user-item list-item';
        el.dataset.nym = baseNym;

        let wrap = el.querySelector('.user-avatar-wrap');
        if (!wrap) {
            const oldImg = el.querySelector('img.avatar-user-list');
            if (oldImg) oldImg.remove();
            wrap = document.createElement('span');
            wrap.className = 'user-avatar-wrap';
            const img = document.createElement('img');
            img.className = 'avatar-user-list';
            img.alt = '';
            img.loading = 'lazy';
            img.dataset.avatarPubkey = pubkey;
            img.src = avatarSrc;
            const fallback = this.generateAvatarSvg(pubkey);
            img.onerror = () => { img.onerror = null; img.src = fallback; };
            wrap.appendChild(img);
            const dot = document.createElement('span');
            dot.className = `user-status-dot status-${effectiveStatus}`;
            wrap.appendChild(dot);
            el.insertBefore(wrap, el.firstChild);
        }

        wrap.classList.toggle('no-status', !!statusHidden);
        const img = wrap.querySelector('img.avatar-user-list');
        if (img) {
            if (img.getAttribute('src') !== avatarSrc) img.src = avatarSrc;
            img.classList.remove('status-online', 'status-away', 'status-offline');
        }
        let dot = wrap.querySelector('.user-status-dot');
        if (!dot) {
            for (const child of Array.from(wrap.children)) {
                if (child !== img) child.remove();
            }
            dot = document.createElement('span');
            wrap.appendChild(dot);
        }
        dot.className = `user-status-dot status-${effectiveStatus}`;
        const oldStatusSpan = el.querySelector('.user-status');
        if (oldStatusSpan) oldStatusSpan.remove();
        let label = el.lastElementChild;
        if (label && label.classList && label.classList.contains('user-avatar-wrap')) {
            label = null;
        }
        if (label) {
            label.className = userColorClass || '';
            label.textContent = '';
            this._fillUserLabel(label, baseNym, pubkey, isDev, isBot);
        }
    },

    _fillUserLabel(label, baseNym, pubkey, isDev, isBot) {
        const displayNym = baseNym && baseNym.length > 20 ? baseNym.slice(0, 20) + '...' : baseNym;
        label.appendChild(document.createTextNode(displayNym));
        const suffix = this.getPubkeySuffix(pubkey);
        const suffixSpan = document.createElement('span');
        suffixSpan.className = 'nym-suffix';
        suffixSpan.textContent = `#${suffix}`;
        label.appendChild(suffixSpan);

        const flairHtml = this.getFlairForUser(pubkey);
        if (flairHtml) {
            const tmpl = document.createElement('template');
            tmpl.innerHTML = flairHtml;
            label.appendChild(tmpl.content);
        }

        if (isDev || isBot) {
            label.appendChild(document.createTextNode(' '));
            const badge = document.createElement('span');
            badge.className = 'verified-badge';
            badge.title = isDev ? this.verifiedDeveloper.title : 'Nymchat Bot';
            badge.textContent = '✓';
            label.appendChild(badge);
        }

        const friendHtml = this.getFriendBadgeHtml(pubkey);
        if (friendHtml) {
            const tmpl = document.createElement('template');
            tmpl.innerHTML = friendHtml;
            label.appendChild(tmpl.content);
        }
    },

    _userFlairKey(pubkey) {
        const items = this.getUserShopItems && this.getUserShopItems(pubkey);
        if (!items || !items.flair) return '';
        return Array.isArray(items.flair) ? items.flair.join(',') : items.flair;
    },

    _evictStaleUsers() {
        const TARGET = 8000;
        const STALE_AGE = 24 * 60 * 60 * 1000;
        const now = Date.now();
        if (this.users.size <= TARGET) return;

        const candidates = [];
        this.users.forEach((u, pk) => {
            if (pk === this.pubkey) return;
            if (this.friends && this.friends.has(pk)) return;
            const age = now - (u.lastSeen || 0);
            if (age > STALE_AGE) candidates.push({ pk, age });
        });
        candidates.sort((a, b) => b.age - a.age);

        let removed = 0;
        const target = this.users.size - TARGET;
        for (let i = 0; i < candidates.length && removed < target; i++) {
            const pk = candidates[i].pk;
            this.users.delete(pk);
            this.userColors && this.userColors.delete(pk);
            const blobUrl = this.avatarBlobCache && this.avatarBlobCache.get(pk);
            if (blobUrl && blobUrl.startsWith('blob:')) URL.revokeObjectURL(blobUrl);
            this.avatarBlobCache && this.avatarBlobCache.delete(pk);
            this.channelUsers && this.channelUsers.forEach(set => set.delete(pk));
            removed++;
        }
        if (removed > 0) this._userListSig = '';
    },

    _updateUserListViewMoreButton(container, totalCount, renderCap, isExpanded, expandedStep) {
        const list = container.parentElement;
        if (!list) return;

        const searchInput = list.querySelector('.search-input');
        const searchActive = !!(searchInput && searchInput.value.trim().length > 0);

        let btn = container.querySelector('.view-more-btn');

        if (searchActive || totalCount <= 20) {
            if (btn) btn.remove();
            list.classList.remove('list-collapsed', 'list-expanded');
            return;
        }

        if (isExpanded) {
            list.classList.remove('list-collapsed');
            list.classList.add('list-expanded');
        } else {
            list.classList.add('list-collapsed');
            list.classList.remove('list-expanded');
        }

        if (!btn) {
            btn = document.createElement('div');
            btn.className = 'view-more-btn';
            container.appendChild(btn);
        } else if (btn.parentElement !== container || btn !== container.lastElementChild) {
            container.appendChild(btn);
        }

        const remaining = totalCount - renderCap;
        if (!isExpanded) {
            btn.textContent = `View ${this.abbreviateNumber(totalCount - 20)} more...`;
            btn.onclick = () => {
                this.listExpansionStates.set('userListContent', true);
                this._userListExpandedCap = expandedStep;
                this._userListSig = '';
                this.updateUserList();
            };
        } else if (remaining > 0) {
            btn.textContent = `Show ${this.abbreviateNumber(Math.min(remaining, expandedStep))} more...`;
            btn.onclick = () => {
                this._userListExpandedCap = (this._userListExpandedCap || expandedStep) + expandedStep;
                this._userListSig = '';
                this.updateUserList();
            };
        } else {
            btn.textContent = 'Show less';
            btn.onclick = () => {
                this.listExpansionStates.set('userListContent', false);
                this._userListExpandedCap = expandedStep;
                this._userListSig = '';
                this.updateUserList();
            };
        }
    },

    unblockByPubkey(pubkey) {
        this.blockedUsers.delete(pubkey);
        this.saveBlockedUsers();
        this.showMessagesFromUnblockedUser(pubkey);

        this.displaySystemMessage(`Unblocked ${this.getNymHtmlFromPubkey(pubkey)}`, 'system', { html: true });
        this.updateUserList();
        this.updateBlockedList();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    toggleBlockUserByPubkey(pubkey) {
        if (!pubkey) return;
        if (this.blockedUsers.has(pubkey)) {
            this.unblockByPubkey(pubkey);
            return;
        }
        this.blockedUsers.add(pubkey);
        this.saveBlockedUsers();
        this.hideMessagesFromBlockedUser(pubkey);

        this.displaySystemMessage(`Blocked ${this.getNymHtmlFromPubkey(pubkey)}`, 'system', { html: true });
        this.updateUserList();
        this.updateBlockedList();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    loadBlockedUsers() {
        this._scheduleIdle(() => this.updateBlockedList());
    },

    saveBlockedUsers() {
        localStorage.setItem('nym_blocked', JSON.stringify(Array.from(this.blockedUsers)));
    },

    updateBlockedList() {
        const list = document.getElementById('blockedList');
        if (!list) return;
        list.textContent = '';
        const msg = document.createElement('div');
        msg.className = 'list-empty-msg';
        if (this.blockedUsers.size === 0) {
            msg.textContent = 'No blocked users';
            list.appendChild(msg);
        } else {
            msg.textContent = 'Loading...';
            list.appendChild(msg);
            this.loadBlockedUsersAsync(list);
        }
    },

    async loadBlockedUsersAsync(listElement) {
        if (!this.nymCache) {
            this.nymCache = {};
        }

        const blockedArray = Array.from(this.blockedUsers);
        const uncachedPubkeys = blockedArray.filter(pk => !this.nymCache[pk]);

        if (uncachedPubkeys.length > 0) {
            await this.fetchMetadataForBlockedUsers(uncachedPubkeys);
        }

        listElement.textContent = '';
        const frag = document.createDocumentFragment();
        blockedArray.forEach(pubkey => {
            const safePk = this._safePubkey(pubkey);
            if (!safePk) return;
            const row = document.createElement('div');
            row.className = 'blocked-item';
            const span = document.createElement('span');
            span.innerHTML = this.getNymHtmlFromPubkey(pubkey);
            const btn = document.createElement('button');
            btn.className = 'unblock-btn';
            btn.textContent = 'Unblock';
            btn.addEventListener('click', () => this.unblockByPubkey(safePk));
            row.appendChild(span);
            row.appendChild(btn);
            frag.appendChild(row);
        });
        listElement.appendChild(frag);
    },

    async fetchMetadataForBlockedUsers(pubkeys) {
        if (pubkeys.length === 0) return;

        if (this._getApiHost && this._getApiHost()) {
            try { if (typeof this._fetchProfilesFromD1 === 'function') await this._fetchProfilesFromD1(pubkeys); } catch (_) { }
            return;
        }

        return new Promise((resolve) => {
            const subId = "blocked-meta-" + Math.random().toString(36).substring(7);
            let receivedCount = 0;
            let messageHandlers = [];

            let releasedSlot = false;
            const cleanup = () => {
                messageHandlers.forEach(handler => {
                    const index = this.relayMessageHandlers?.indexOf(handler);
                    if (index > -1) {
                        this.relayMessageHandlers.splice(index, 1);
                    }
                });
                try { this.closeFewRelaysSub(subId); } catch (_) { }
                if (!releasedSlot && typeof this._oneShotReqDone === 'function') {
                    releasedSlot = true;
                    this._oneShotReqDone();
                }
            };

            const timeout = setTimeout(() => {
                cleanup();
                resolve();
            }, 2500);

            const handleMessage = (msg, relayUrl) => {
                if (!Array.isArray(msg)) return false;

                const [type, ...data] = msg;

                if (type === 'EVENT' && data[0] === subId) {
                    const event = data[1];
                    if (event && event.kind === 0) {
                        try {
                            const metadata = JSON.parse(event.content);
                            const name = metadata.name || metadata.display_name || metadata.displayName;
                            if (name) {
                                this.nymCache[event.pubkey] = name;
                            }
                            receivedCount++;

                            if (receivedCount >= pubkeys.length) {
                                clearTimeout(timeout);
                                cleanup();
                                resolve();
                            }
                        } catch (e) {
                        }
                    }
                } else if (type === 'EOSE' && data[0] === subId) {
                    clearTimeout(timeout);
                    cleanup();
                    resolve();
                }

                return false;
            };

            if (!this.relayMessageHandlers) {
                this.relayMessageHandlers = [];
            }
            this.relayMessageHandlers.push(handleMessage);
            messageHandlers.push(handleMessage);

            const subscription = [
                "REQ",
                subId,
                {
                    kinds: [0],
                    authors: pubkeys
                }
            ];

            const fire = () => this.sendRequestToFewRelays(subscription);
            if (typeof this._oneShotReqAcquire === 'function') this._oneShotReqAcquire(fire);
            else fire();
        });
    },

    loadFriends() {
        this._scheduleIdle(() => this.updateFriendsList());
    },

    saveFriends() {
        localStorage.setItem('nym_friends', JSON.stringify(Array.from(this.friends)));
    },

    isFriend(pubkey) {
        return this.friends.has(pubkey);
    },

    getFriendBadgeHtml(pubkey) {
        if (!pubkey || pubkey === this.pubkey || !this.isFriend(pubkey)) return '';
        return '<span class="friend-badge" title="Friend"><svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" class="nm-usr-1"><circle cx="6" cy="5" r="2.5" /><path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" /><line x1="13" y1="6" x2="13" y2="10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /><line x1="11" y1="8" x2="15" y2="8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg></span>';
    },

    async toggleFriend(target) {
        // A public key in either form (npub or hex), otherwise a nym.
        let targetPubkey = this.normalizePubkeyInput(target);
        if (!targetPubkey) {
            targetPubkey = await this.findUserPubkey(target);
            if (!targetPubkey) return;
        }

        const nymHtml = this.getNymHtmlFromPubkey(targetPubkey);

        if (this.friends.has(targetPubkey)) {
            this.friends.delete(targetPubkey);
            this.saveFriends();
            this.displaySystemMessage(`Removed ${nymHtml} from friends`, 'system', { html: true });
        } else {
            this.friends.add(targetPubkey);
            this.saveFriends();
            this.displaySystemMessage(`Added ${nymHtml} as a friend`, 'system', { html: true });
        }

        this.updateFriendsList();
        this._refreshFriendBadgesFor(targetPubkey);
        if (typeof this.reapplyImageBlur === 'function') this.reapplyImageBlur();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    removeFriendByPubkey(pubkey) {
        this.friends.delete(pubkey);
        this.saveFriends();

        this.displaySystemMessage(`Removed ${this.getNymHtmlFromPubkey(pubkey)} from friends`, 'system', { html: true });
        this.updateFriendsList();
        this._refreshFriendBadgesFor(pubkey);
        if (typeof this.reapplyImageBlur === 'function') this.reapplyImageBlur();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    _refreshFriendBadgesFor(pubkey) {
        if (!pubkey) return;

        this._userListSig = '';
        if (typeof this.updateUserList === 'function') this.updateUserList();

        if (typeof this.updatePMNicknameFromProfile === 'function') {
            const known = this.users.get(pubkey);
            const profileName = known && known.nym ? this.parseNymFromDisplay(known.nym) : null;
            if (profileName) {
                this.updatePMNicknameFromProfile(pubkey, profileName);
            } else {
                this._toggleFriendBadgeInMessages(pubkey);
            }
        } else {
            this._toggleFriendBadgeInMessages(pubkey);
        }

        if (typeof this._renderPMHeaderForPubkey === 'function') {
            this._renderPMHeaderForPubkey(pubkey);
        }
    },

    _toggleFriendBadgeInMessages(pubkey) {
        const safePk = this._safePubkey(pubkey);
        if (!safePk) return;
        const isFriend = this.isFriend(pubkey);
        document.querySelectorAll(`.message[data-pubkey="${safePk}"] .author-clickable`).forEach(clickable => {
            const existing = clickable.querySelector('.friend-badge');
            if (isFriend && !existing) {
                clickable.insertAdjacentHTML('beforeend', this.getFriendBadgeHtml(pubkey));
            } else if (!isFriend && existing) {
                existing.remove();
            }
            // Drop the cached signature so a later profile rewrite isn't skipped.
            if (clickable.dataset.authorSig) delete clickable.dataset.authorSig;
        });
    },

    updateFriendsList() {
        const list = document.getElementById('friendsList');
        if (!list) return;
        list.textContent = '';
        const msg = document.createElement('div');
        msg.className = 'list-empty-msg';
        if (this.friends.size === 0) {
            msg.textContent = 'No friends added';
            list.appendChild(msg);
        } else {
            msg.textContent = 'Loading...';
            list.appendChild(msg);
            this.loadFriendsListAsync(list);
        }
    },

    async loadFriendsListAsync(listElement) {
        if (!this.nymCache) {
            this.nymCache = {};
        }

        const friendsArray = Array.from(this.friends);
        const uncachedPubkeys = friendsArray.filter(pk => !this.nymCache[pk]);

        if (uncachedPubkeys.length > 0) {
            await this.fetchMetadataForBlockedUsers(uncachedPubkeys);
        }

        listElement.textContent = '';
        const frag = document.createDocumentFragment();
        friendsArray.forEach(pubkey => {
            const safePk = this._safePubkey(pubkey);
            if (!safePk) return;
            const row = document.createElement('div');
            row.className = 'blocked-item';
            const span = document.createElement('span');
            span.innerHTML = this.getNymHtmlFromPubkey(pubkey);
            const btn = document.createElement('button');
            btn.className = 'unblock-btn';
            btn.textContent = 'Remove';
            btn.addEventListener('click', () => this.removeFriendByPubkey(safePk));
            row.appendChild(span);
            row.appendChild(btn);
            frag.appendChild(row);
        });
        listElement.appendChild(frag);
    },

    escapeHtml(text) {
        const map = {
            '&': '&amp;',
            '<': '&lt;',
            '>': '&gt;',
            '"': '&quot;',
            "'": '&#x27;',
        };
        return String(text).replace(/[&<>"']/g, m => map[m]);
    },

    // Scheme guard for anything that becomes an href or an external open.
    safeUrl(url) {
        const F = window.NymFormat;
        if (F && typeof F.safeUrl === 'function') return F.safeUrl(url);
        if (typeof url !== 'string') return '';
        return /^https?:\/\//i.test(url.replace(/[\u0000-\u0020]/g, '')) ? url : '';
    },

    _safePubkey(pk) {
        if (typeof pk !== 'string') return '';
        return /^[0-9a-f]{64}$/i.test(pk) ? pk.toLowerCase() : '';
    },

    abbreviateNumber(n) {
        if (n < 1000) return String(n);
        if (n < 1000000) return (n / 1000).toFixed(n < 10000 ? 1 : 0) + 'k';
        return (n / 1000000).toFixed(1) + 'M';
    },

    async findUserPubkey(input) {
        // A public key in either form resolves as itself.
        const asPubkey = this.normalizePubkeyInput(input);
        if (asPubkey) return asPubkey;

        const cleanInput = input.replace(/^@/, '');
        const hashIndex = cleanInput.indexOf('#');
        let searchNym = cleanInput;
        let searchSuffix = null;

        if (hashIndex !== -1) {
            searchNym = cleanInput.substring(0, hashIndex);
            searchSuffix = cleanInput.substring(hashIndex + 1);
        }

        const matches = [];

        this.users.forEach((user, pubkey) => {
            const baseNym = this.stripPubkeySuffix(user.nym);
            if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                if (searchSuffix) {
                    if (pubkey.endsWith(searchSuffix)) {
                        matches.push({ nym: user.nym, pubkey: pubkey });
                    }
                } else {
                    matches.push({ nym: user.nym, pubkey: pubkey });
                }
            }
        });

        if (matches.length === 0) {
            this.messages.forEach((channelMessages, channel) => {
                channelMessages.forEach(msg => {
                    if (msg.pubkey && msg.author) {
                        const baseNym = this.stripPubkeySuffix(msg.author);
                        if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                            if (searchSuffix) {
                                if (msg.pubkey.endsWith(searchSuffix)) {
                                    if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                        matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                    }
                                }
                            } else {
                                if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                    matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                }
                            }
                        }
                    }
                });
            });

            this.pmMessages.forEach((conversationMessages, conversationKey) => {
                conversationMessages.forEach(msg => {
                    if (msg.pubkey && msg.author) {
                        const baseNym = this.stripPubkeySuffix(msg.author);
                        if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                            if (searchSuffix) {
                                if (msg.pubkey.endsWith(searchSuffix)) {
                                    if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                        matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                    }
                                }
                            } else {
                                if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                    matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                }
                            }
                        }
                    }
                });
            });

        }

        if (matches.length === 0) {
            this.displaySystemMessage(`User ${cleanInput} not found. Try using the full nym#xxxx format if you know their pubkey suffix.`);
            return null;
        }

        if (matches.length > 1 && !searchSuffix) {
            const matchList = matches.map(m =>
                `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
            ).join(', ');
            this.displaySystemMessage(`Multiple users found: ${matchList}`, 'system', { html: true, feed: true });
            this.displaySystemMessage('Please specify using the #xxxx suffix', 'system', { feed: true });
            return null;
        }

        return matches[0].pubkey;
    },

});
