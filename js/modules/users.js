// users.js - User identities, blocked users/keywords, friends, avatars, banners, wallpaper, uploads

Object.assign(NYM.prototype, {

    getUserColorClass(pubkey) {
        if (this.settings.theme !== 'bitchat') return '';
        if (!pubkey) return '';

        // Your own messages are always orange
        if (pubkey === this.pubkey) {
            return 'bitchat-theme';
        }

        // Return cached color if exists
        if (this.userColors.has(pubkey)) {
            return this.userColors.get(pubkey);
        }

        // Generate unique color based on pubkey hash
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
        const isLight = document.body.classList.contains('light-mode');
        this._ensureBitchatColorSheet(isLight);
        return `bitchat-user-${isLight ? 'l' : 'd'}${bucket}`;
    },

    _ensureBitchatColorSheet(isLight) {
        const id = isLight ? 'bitchat-colors-l' : 'bitchat-colors-d';
        if (document.getElementById(id)) return;
        const style = document.createElement('style');
        style.id = id;
        const parts = new Array(1000);
        const tag = isLight ? 'l' : 'd';
        for (let i = 0; i < 1000; i++) {
            const hue = (i * 360 / 1000) | 0;
            const sat = isLight ? 55 + (i % 35) : 65 + (i % 35);
            const light = isLight ? 25 + (i % 20) : 60 + (i % 25);
            const cls = `bitchat-user-${tag}${i}`;
            parts[i] = `.${cls},.${cls} .nym-suffix{color:hsl(${hue},${sat}%,${light}%)!important}`;
        }
        style.textContent = parts.join('');
        document.head.appendChild(style);
    },

    isVerifiedDeveloper(pubkey) {
        return pubkey === this.verifiedDeveloper.pubkey;
    },

    isReservedNick(nick) {
        const reserved = ['luxas', 'nymbot'];
        return reserved.includes(nick.toLowerCase().replace(/#.*$/, '').trim());
    },

    isVerifiedBot(pubkey) {
        return pubkey === this.verifiedBot.pubkey;
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
        this.privkey = secretKey;
        this.pubkey = pubkey;
        this.nym = 'Luxas';
        document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
        this.updateSidebarAvatar();
    },

    // NSEC decode method
    decodeNsec(nsec) {
        try {
            // Use nostr-tools nip19 decode
            if (window.NostrTools && window.NostrTools.nip19) {
                const decoded = window.NostrTools.nip19.decode(nsec);
                if (decoded.type === 'nsec') {
                    return decoded.data;
                }
            }
            throw new Error('Invalid nsec format');
        } catch (error) {
            throw new Error('Failed to decode nsec: ' + error.message);
        }
    },

    loadBlockedKeywords() {
        const saved = localStorage.getItem('nym_blocked_keywords');
        if (saved) {
            try {
                this.blockedKeywords = new Set(JSON.parse(saved));
            } catch (_) {
                // Corrupted localStorage — fall back to empty set rather than crashing init.
                this.blockedKeywords = new Set();
            }
        }
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

            // Hide messages containing this keyword (check both content and nickname)
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

        // Re-check all messages (check both content and nickname against remaining keywords)
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

        // Use the last 4 chars of pubkey
        const suffix = this.getPubkeySuffix(this.pubkey);

        if (style === 'simple') {
            const randomNum = Math.floor(1000 + Math.random() * 9000);
            return `nym${randomNum}#${suffix}`;
        }

        // Fancy style: adjective_noun
        const adjectives = [
            'quantum', 'neon', 'cyber', 'shadow', 'plasma',
            'echo', 'nexus', 'void', 'flux', 'ghost',
            'phantom', 'stealth', 'cryptic', 'dark', 'neural',
            'binary', 'matrix', 'digital', 'virtual', 'zero',
            'null', 'anon', 'masked', 'hidden', 'cipher',
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
        // Only strip a trailing #xxxx where xxxx is exactly 4 hex chars (pubkey suffix)
        return nym.replace(/#[0-9a-f]{4}$/i, '');
    },

    formatNymWithPubkey(nym, pubkey) {
        // If nym already has a pubkey suffix (#xxxx where xxxx is 4 hex chars), wrap it
        const suffixMatch = nym.match(/#([0-9a-f]{4})$/i);
        if (suffixMatch) {
            const baseName = nym.substring(0, nym.length - 5);
            return `${this.escapeHtml(baseName)}<span class="nym-suffix">#${suffixMatch[1]}</span>`;
        }

        // Get last 4 characters of pubkey
        const suffix = pubkey ? pubkey.slice(-4) : '????';
        return `${this.escapeHtml(nym)}<span class="nym-suffix">#${suffix}</span>`;
    },

    updateSidebarAvatar() {
        const el = document.getElementById('sidebarAvatar');
        if (el && this.pubkey) {
            const pubkey = this.pubkey;
            el.setAttribute('data-avatar-pubkey', pubkey);
            el.src = this.getAvatarUrl(pubkey);
            const fallback = this.generateAvatarSvg(pubkey);
            el.onerror = function () { this.onerror = null; this.src = fallback; };
        }
    },

    getPubkeySuffix(pubkey) {
        if (typeof pubkey !== 'string' || pubkey.length < 4) return '????';
        const tail = pubkey.slice(-4);
        return /^[0-9a-f]{4}$/i.test(tail) ? tail : '????';
    },

    parseNymFromDisplay(displayNym) {
        if (!displayNym) return 'anon';

        // Strip flair and everything after the nym-suffix span first
        // Use [\s\S]* instead of .* to match across newlines (SVG flair icons contain newlines)
        let cleaned = displayNym.replace(/<span class="nym-suffix">[\s\S]*$/, '').trim();

        // Strip all remaining HTML tags (avatar img, formatting, etc.)
        cleaned = cleaned.replace(/<[^>]*>/g, '').trim();

        // Decode HTML entities (e.g., &lt; &gt; from display formatting)
        cleaned = cleaned.replace(/&lt;/g, '').replace(/&gt;/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').trim();

        // Strip pubkey suffix if still present (#xxxx where xxxx is 4 hex chars)
        return cleaned.replace(/#[0-9a-f]{4}$/i, '') || cleaned || 'anon';
    },

    // Generate a deterministic identicon SVG from a seed (pubkey or any string).
    // Returned as a data URI so it can be used directly as an <img> src without
    // any external network requests. Cached per-seed for performance.
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
        const blob = this.avatarBlobCache.get(pubkey);
        if (blob) {
            this.avatarBlobCache.delete(pubkey);
            this.avatarBlobCache.set(pubkey, blob);
            return blob;
        }
        const custom = this.userAvatars.get(pubkey);
        if (custom) return custom;
        return this.generateAvatarSvg(pubkey);
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

    // Fetch an avatar image and cache it as a blob object URL.
    // Deduplicates concurrent requests for the same pubkey.
    cacheAvatarImage(pubkey, url) {
        if (this.avatarBlobCache.has(pubkey)) return Promise.resolve();
        if (this.avatarBlobInflight.has(pubkey)) return this.avatarBlobInflight.get(pubkey);
        const fetchUrl = this.getProxiedMediaUrl(url);
        const p = this._throttledProxyFetch(fetchUrl, { mode: 'cors' })
            .then(r => { if (!r.ok) throw new Error(r.status); return r.blob(); })
            .then(blob => {
                // Revoke old blob URL if avatar changed
                const old = this.avatarBlobCache.get(pubkey);
                if (old) URL.revokeObjectURL(old);
                const objectUrl = URL.createObjectURL(blob);
                this.avatarBlobCache.set(pubkey, objectUrl);
                this._evictAvatarBlobIfFull();
                this.updateRenderedAvatars(pubkey, objectUrl);
                // Persist to IndexedDB so we can render it immediately on next load
                if (typeof this.persistAvatarBlob === 'function') {
                    const ts = (this._kind0Ts && this._kind0Ts.get(pubkey)) || null;
                    this.persistAvatarBlob(pubkey, blob, url, ts);
                }
            })
            .catch(() => {
                // Blob fetch failed (CORS, network, etc.) — fall back to raw URL
                this.updateRenderedAvatars(pubkey, url);
            })
            .finally(() => { this.avatarBlobInflight.delete(pubkey); });
        this.avatarBlobInflight.set(pubkey, p);
        return p;
    },

    // Fetch a banner image and cache it as a blob object URL.
    cacheBannerImage(pubkey, url) {
        if (this.bannerBlobCache.has(pubkey)) return Promise.resolve();
        if (this.bannerBlobInflight.has(pubkey)) return this.bannerBlobInflight.get(pubkey);
        const fetchUrl = this.getProxiedMediaUrl(url);
        const p = this._throttledProxyFetch(fetchUrl, { mode: 'cors' })
            .then(r => { if (!r.ok) throw new Error(r.status); return r.blob(); })
            .then(blob => {
                const old = this.bannerBlobCache.get(pubkey);
                if (old) URL.revokeObjectURL(old);
                const objectUrl = URL.createObjectURL(blob);
                this.bannerBlobCache.set(pubkey, objectUrl);
                // Update context menu banner if open for this user
                const ctxBanner = document.getElementById('ctxBannerImg');
                if (ctxBanner && this.contextMenuData?.pubkey === pubkey) {
                    ctxBanner.src = objectUrl;
                }
                if (typeof this.persistBannerBlob === 'function') {
                    const ts = (this._kind0Ts && this._kind0Ts.get(pubkey)) || null;
                    this.persistBannerBlob(pubkey, blob, url, ts);
                }
            })
            .catch(() => { })
            .finally(() => { this.bannerBlobInflight.delete(pubkey); });
        this.bannerBlobInflight.set(pubkey, p);
        return p;
    },

    getBannerUrl(pubkey) {
        const blob = this.bannerBlobCache.get(pubkey);
        if (blob) return blob;
        return this.userBanners.get(pubkey) || null;
    },

    getBio(pubkey) {
        return this.userBios.get(pubkey) || '';
    },

    // Returns a proxied URL for media (images/videos) to hide the user's IP
    getProxiedMediaUrl(originalUrl) {
        const base = this._getProxyBaseUrl();
        if (!base) return originalUrl;
        return `${base}?url=${encodeURIComponent(originalUrl)}`;
    },

    // Proxied URL for a custom emoji image. The emoji flag tells the proxy to
    // apply a long edge-cache TTL so emoji render instantly on repeat views.
    getProxiedEmojiUrl(originalUrl) {
        const base = this._getProxyBaseUrl();
        if (!base) return originalUrl;
        return `${base}?emoji=1&url=${encodeURIComponent(originalUrl)}`;
    },

    // Blob upload endpoint. Routes through the Cloudflare proxy when available
    // (hides the user's IP); falls back to a direct blossom.band PUT when
    // running locally / in direct mode so uploads still work.
    _getBlossomUploadUrl() {
        const base = this._getProxyBaseUrl();
        return base ? `${base}?action=upload` : 'https://blossom.band/upload';
    },

    // Update already-rendered message avatars when a kind 0 profile picture arrives
    updateRenderedAvatars(pubkey, avatarUrl) {
        const safePk = this._safePubkey(pubkey);
        if (!safePk) return;
        const fallback = this.generateAvatarSvg(safePk);
        document.querySelectorAll(`img[data-avatar-pubkey="${safePk}"]`).forEach(img => {
            // Skip if already showing the desired URL — avoids cancelling
            // an in-flight load and triggering a spurious error → SVG swap.
            if (img.getAttribute('src') === avatarUrl) return;
            img.onerror = function () { this.onerror = null; this.src = fallback; };
            img.src = avatarUrl;
        });
        // Update context menu avatar if open for this user
        const ctxImg = document.getElementById('ctxAvatarImg');
        if (ctxImg && this.contextMenuData?.pubkey === pubkey && ctxImg.getAttribute('src') !== avatarUrl) {
            ctxImg.onerror = function () { this.onerror = null; this.src = fallback; };
            ctxImg.src = avatarUrl;
        }
    },

    async uploadAvatar(file) {
        try {
            // Compute SHA-256 hash
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

            // Create and sign Nostr event for blossom upload auth
            const now = Math.floor(Date.now() / 1000);
            const uploadEvent = {
                kind: 24242,
                created_at: now,
                tags: [
                    ['t', 'upload'],
                    ['x', hashHex],
                    ['expiration', String(now + 600)]
                ],
                content: 'Uploading blob with SHA-256 hash',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(uploadEvent);
            const eventBase64 = btoa(JSON.stringify(signedEvent));

            const response = await fetch(this._getBlossomUploadUrl(), {
                method: 'PUT',
                headers: {
                    'Authorization': `Nostr ${eventBase64}`,
                    'Content-Type': file.type || 'image/png'
                },
                body: file
            });

            if (response.ok) {
                const data = await response.json();
                if (data.url) {
                    // Clear old cached blob so cacheAvatarImage will fetch the new one
                    const oldBlob = this.avatarBlobCache.get(this.pubkey);
                    if (oldBlob) URL.revokeObjectURL(oldBlob);
                    this.avatarBlobCache.delete(this.pubkey);

                    // Store locally
                    this.userAvatars.set(this.pubkey, data.url);
                    this.cacheAvatarImage(this.pubkey, data.url);

                    // Persist for auto-ephemeral reuse
                    localStorage.setItem('nym_avatar_url', data.url);

                    // Update sidebar avatar
                    this.updateSidebarAvatar();

                    // Update rendered avatars immediately
                    this.updateRenderedAvatars(this.pubkey, data.url);

                    // Update nostr profile with picture
                    await this.saveToNostrProfile();

                    // Broadcast avatar update so other users clear their cache
                    this.publishAvatarUpdate(data.url);

                    return data.url;
                }
            }
            throw new Error(`Upload failed: ${response.status}`);
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
        // Broadcast avatar removal so other users clear their cache
        this.publishAvatarUpdate('');
    },

    async uploadBanner(file) {
        try {
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

            const now = Math.floor(Date.now() / 1000);
            const uploadEvent = {
                kind: 24242,
                created_at: now,
                tags: [
                    ['t', 'upload'],
                    ['x', hashHex],
                    ['expiration', String(now + 600)]
                ],
                content: 'Uploading blob with SHA-256 hash',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(uploadEvent);
            const eventBase64 = btoa(JSON.stringify(signedEvent));

            const response = await fetch(this._getBlossomUploadUrl(), {
                method: 'PUT',
                headers: {
                    'Authorization': `Nostr ${eventBase64}`,
                    'Content-Type': file.type || 'image/png'
                },
                body: file
            });

            if (response.ok) {
                const data = await response.json();
                if (data.url) {
                    const oldBlob = this.bannerBlobCache.get(this.pubkey);
                    if (oldBlob) URL.revokeObjectURL(oldBlob);
                    this.bannerBlobCache.delete(this.pubkey);
                    this.userBanners.set(this.pubkey, data.url);
                    this.cacheBannerImage(this.pubkey, data.url);
                    localStorage.setItem('nym_banner_url', data.url);
                    await this.saveToNostrProfile();
                    return data.url;
                }
            }
            throw new Error(`Upload failed: ${response.status}`);
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

    // Wallpaper Methods
    async uploadWallpaper(file) {
        // Validate minimum image size
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
            // Compute SHA-256 hash
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

            // Create and sign Nostr event for blossom upload auth
            const now = Math.floor(Date.now() / 1000);
            const uploadEvent = {
                kind: 24242,
                created_at: now,
                tags: [
                    ['t', 'upload'],
                    ['x', hashHex],
                    ['expiration', String(now + 600)]
                ],
                content: 'Uploading blob with SHA-256 hash',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(uploadEvent);
            const eventBase64 = btoa(JSON.stringify(signedEvent));

            const response = await fetch(this._getBlossomUploadUrl(), {
                method: 'PUT',
                headers: {
                    'Authorization': `Nostr ${eventBase64}`,
                    'Content-Type': file.type || 'image/png'
                },
                body: file
            });

            if (response.ok) {
                const data = await response.json();
                if (data.url) {
                    return data.url;
                }
            }
            throw new Error(`Upload failed: ${response.status}`);
        } catch (error) {
            this.displaySystemMessage('Failed to upload wallpaper: ' + error.message);
            return null;
        }
    },

    applyWallpaper(type, customUrl) {
        const layer = document.getElementById('wallpaperLayer');
        if (!layer) return;

        const presets = ['geometric', 'circuit', 'dots', 'waves', 'topography', 'hexagons', 'diamonds'];

        // Remove any existing wallpaper classes and inline background-image
        presets.forEach(p => layer.classList.remove(`wallpaper-pattern-${p}`));
        layer.classList.remove('has-custom-wallpaper');
        layer.style.backgroundImage = '';

        if (type === 'none' || !type) return;

        if (presets.includes(type)) {
            layer.classList.add(`wallpaper-pattern-${type}`);
        } else if (type === 'custom' && customUrl) {
            layer.classList.add('has-custom-wallpaper');
            // Layer a semi-transparent overlay on top of the image for readability
            const isLight = document.body.classList.contains('light-mode');
            const overlay = isLight
                ? 'rgba(245, 245, 242, 0.85)'
                : 'rgba(10, 10, 15, 0.82)';
            layer.style.backgroundImage = `linear-gradient(${overlay}, ${overlay}), url('${customUrl}')`;
        }
    },

    saveWallpaper(type, customUrl) {
        localStorage.setItem('nym_wallpaper_type', type);
        if (type === 'custom' && customUrl) {
            localStorage.setItem('nym_wallpaper_custom_url', customUrl);
        } else {
            localStorage.removeItem('nym_wallpaper_custom_url');
        }
    },

    loadWallpaper() {
        const type = localStorage.getItem('nym_wallpaper_type') || 'geometric';
        const customUrl = localStorage.getItem('nym_wallpaper_custom_url') || '';
        this.applyWallpaper(type, customUrl);
        return { type, customUrl };
    },

    async uploadImage(file) {
        const isVideo = file.type.startsWith('video/');
        const MAX_UPLOAD_SIZE = 50 * 1024 * 1024; // 50MB

        if (file.size > MAX_UPLOAD_SIZE) {
            this.displaySystemMessage((isVideo ? 'Video' : 'Image') + ' files must be under 50MB. Your file is ' + (file.size / (1024 * 1024)).toFixed(1) + 'MB.');
            return;
        }

        const progress = document.getElementById('uploadProgress');
        const progressFill = document.getElementById('progressFill');
        const progressLabel = document.getElementById('uploadProgressLabel');

        try {
            progress.classList.add('active');
            progressLabel.textContent = isVideo ? 'Uploading video...' : 'Uploading image...';
            progressFill.style.width = '20%';

            // Compute SHA-256 hash
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

            progressFill.style.width = '40%';

            // Create and sign Nostr event
            const now = Math.floor(Date.now() / 1000);
            const uploadEvent = {
                kind: 24242,
                created_at: now,
                tags: [
                    ['t', 'upload'],
                    ['x', hashHex],
                    ['expiration', String(now + 600)] // 10 minutes from now
                ],
                content: 'Uploading blob with SHA-256 hash',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(uploadEvent);

            progressFill.style.width = '60%';

            // Convert signed event to base64
            const eventString = JSON.stringify(signedEvent);
            const eventBase64 = btoa(eventString);

            progressFill.style.width = '80%';

            // Upload to blossom.band
            const response = await fetch(this._getBlossomUploadUrl(), {
                method: 'PUT',
                headers: {
                    'Authorization': `Nostr ${eventBase64}`,
                    'Content-Type': file.type || 'application/octet-stream'
                },
                body: file
            });

            progressFill.style.width = '100%';

            if (response.ok) {
                const data = await response.json();
                if (data.url) {
                    const mediaUrl = data.url;
                    const input = document.getElementById('messageInput');
                    input.value += mediaUrl + ' ';
                    input.focus();
                } else {
                    throw new Error('No URL in response');
                }
            } else {
                throw new Error(`Upload failed: ${response.status}`);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to upload ' + (isVideo ? 'video' : 'image') + ': ' + error.message);
        } finally {
            setTimeout(() => {
                progress.classList.remove('active');
            }, 500);
        }
    },

    getNymFromPubkey(pubkey) {
        const user = this.users.get(pubkey);
        if (user) {
            // Get clean nym without existing HTML
            const cleanNym = this.parseNymFromDisplay(user.nym);
            return `${cleanNym}#${this.getPubkeySuffix(pubkey)}`;
        }

        // Check if we've seen this user in PM conversations
        const pmConvo = Array.from(this.pmConversations.values())
            .find(conv => conv.pubkey === pubkey);
        if (pmConvo && pmConvo.nym) {
            const cleanNym = this.parseNymFromDisplay(pmConvo.nym);
            return `${cleanNym}#${this.getPubkeySuffix(pubkey)}`;
        }

        // Return shortened pubkey as fallback with anon prefix
        return `anon#${pubkey.slice(-4)}`;
    },

    // Compute the effective status (online / away / offline / hidden) for a user.
    // Returns 'hidden' when the user has opted out of broadcasting their status
    // — callers should suppress the status indicator entirely in that case.
    getEffectiveUserStatus(pubkey) {
        if (!pubkey) return 'offline';
        if (this.statusHiddenUsers && this.statusHiddenUsers.has(pubkey)) return 'hidden';
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

        // Ignore our own presence events
        if (pubkey === this.pubkey) return;

        // Skip stale presence events - only process if newer than last seen
        if (!this.presenceTimestamps) this.presenceTimestamps = new Map();
        const lastTimestamp = this.presenceTimestamps.get(pubkey) || 0;
        if (eventTime < lastTimestamp) return;
        this.presenceTimestamps.set(pubkey, eventTime);

        // Handle avatar update: clear cached avatar and re-fetch
        if (avatarUpdateTag) {
            const newAvatarUrl = avatarUpdateTag[1];
            const oldBlob = this.avatarBlobCache.get(pubkey);
            if (oldBlob) URL.revokeObjectURL(oldBlob);
            this.avatarBlobCache.delete(pubkey);
            if (typeof this.deleteCachedAvatar === 'function') this.deleteCachedAvatar(pubkey);

            if (newAvatarUrl) {
                this.userAvatars.set(pubkey, newAvatarUrl);
                this.cacheAvatarImage(pubkey, newAvatarUrl);
                this.updateRenderedAvatars(pubkey, newAvatarUrl);
            } else {
                // Avatar removed - fall back to generated identicon
                this.userAvatars.delete(pubkey);
                this.updateRenderedAvatars(pubkey, this.getAvatarUrl(pubkey));
            }
        }

        // Handle shop update: drop cached active items and re-fetch so the
        // user's new flair/style shows up immediately for everyone.
        const shopUpdateTag = event.tags.find(t => t[0] === 'shop-update');
        if (shopUpdateTag && typeof this.invalidateShopCache === 'function') {
            this.invalidateShopCache(pubkey);
        }

        // Track users who have opted to hide their status indicator
        if (!this.statusHiddenUsers) this.statusHiddenUsers = new Set();
        if (status === 'hidden') {
            this.statusHiddenUsers.add(pubkey);
            this.awayMessages.delete(pubkey);
        } else {
            this.statusHiddenUsers.delete(pubkey);
        }

        // Update away messages map for this user
        if (status === 'away' && awayTag) {
            this.awayMessages.set(pubkey, awayTag[1]);
        } else if (status === 'online') {
            this.awayMessages.delete(pubkey);
        }

        // Update user status if we know this user
        if (this.users.has(pubkey)) {
            const user = this.users.get(pubkey);
            // Don't overwrite the activity-derived status with 'hidden' —
            // visibility is tracked separately via statusHiddenUsers so the
            // user still appears in the list, just without a status dot.
            if (status !== 'hidden') user.status = status;
            if (nym) user.nym = nym;
            this.updateUserList();
        }
    },

    updateUserPresence(nym, pubkey, channel, geohash, createdAt) {
        const channelKey = geohash || channel;

        // Use the event's created_at timestamp (seconds) converted to ms,
        // so historical messages don't falsely mark users as online
        const eventTime = createdAt ? createdAt * 1000 : Date.now();

        // Determine base status from away messages or event age
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

        // Update or create user with deduplication by pubkey
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
            // Only update lastSeen if this event is more recent
            if (eventTime > user.lastSeen) {
                user.lastSeen = eventTime;
                user.status = baseStatus;
            }
            user.nym = nym; // Update nym in case it changed
            if (!user.channels) user.channels = new Set();
            user.channels.add(channelKey);
        }

        // Track users per channel
        if (!this.channelUsers.has(channelKey)) {
            this.channelUsers.set(channelKey, new Set());
        }
        this.channelUsers.get(channelKey).add(pubkey);

        if (this.users.size > 10000) this._evictStaleUsers();

        this.updateUserList();
    },

    // Mark a remote user as recently active without an explicit message —
    // e.g. after receiving a "read" receipt, so lurkers who only view
    // messages still appear online.
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
                this.isGibberishNym(user.nym)) return;

            const isRecent = (now - user.lastSeen) < ACTIVE_THRESHOLD;
            let effectiveStatus = user.status;
            if (verifiedBotSet.has(pubkey)) {
                effectiveStatus = 'online';
            } else if (!isRecent && effectiveStatus !== 'away') {
                effectiveStatus = 'offline';
            }
            // Only count users who have sent a recent channel message (or verified bots).
            // Away users without recent activity don't count as active.
            if (effectiveStatus !== 'offline' && (isRecent || verifiedBotSet.has(pubkey))) {
                activeCount++;
            }

            if (isRecent && user.channels && user.channels.has(currentChannelKey)) {
                channelUserCount++;
            }

            const sortKey = this.parseNymFromDisplay(user.nym).toLowerCase();
            const localStatusOff = this.settings && this.settings.showStatus === false;
            const statusHidden = localStatusOff || (this.statusHiddenUsers && this.statusHiddenUsers.has(pubkey));
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
    },

    _renderUserListItems(container, displayUsers, themeBitchat) {
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

        const nym = this.getNymFromPubkey(pubkey);
        this.displaySystemMessage(`Unblocked ${nym}`);
        this.updateUserList();
        this.updateBlockedList();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    loadBlockedUsers() {
        const blocked = localStorage.getItem('nym_blocked');
        if (blocked) {
            try {
                this.blockedUsers = new Set(JSON.parse(blocked));
            } catch (_) {
                this.blockedUsers = new Set();
            }
        }
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
        // Initialize nymCache if it doesn't exist
        if (!this.nymCache) {
            this.nymCache = {};
        }

        // Fetch metadata for blocked users who aren't in cache
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
            const nym = this.getNymFromPubkey(pubkey);
            const row = document.createElement('div');
            row.className = 'blocked-item';
            const span = document.createElement('span');
            span.textContent = nym;
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

    // Fetch metadata for blocked users
    async fetchMetadataForBlockedUsers(pubkeys) {
        if (pubkeys.length === 0) return;

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
                try { this.sendToRelay(["CLOSE", subId]); } catch (_) { }
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
                        // Temporarily process metadata ONLY for caching the nym
                        try {
                            const metadata = JSON.parse(event.content);
                            const name = metadata.name || metadata.display_name || metadata.displayName;
                            if (name) {
                                // Store in nym cache (without adding to profile cache)
                                this.nymCache[event.pubkey] = name;
                            }
                            receivedCount++;

                            // If we got all metadata, resolve early
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

            // Request metadata for blocked users
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
        const saved = localStorage.getItem('nym_friends');
        if (saved) {
            try {
                this.friends = new Set(JSON.parse(saved));
            } catch (_) {
                this.friends = new Set();
            }
        }
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
        return '<span class="friend-badge" title="Friend"><svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" style="vertical-align: middle; margin-left: 3px; opacity: 0.7;"><circle cx="6" cy="5" r="2.5" /><path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" /><line x1="13" y1="6" x2="13" y2="10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /><line x1="11" y1="8" x2="15" y2="8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg></span>';
    },

    async toggleFriend(target) {
        let targetPubkey;
        if (/^[0-9a-f]{64}$/i.test(target)) {
            targetPubkey = target.toLowerCase();
        } else {
            targetPubkey = await this.findUserPubkey(target);
            if (!targetPubkey) return;
        }

        const targetNym = this.getNymFromPubkey(targetPubkey);
        const cleanNym = this.getCleanNym ? this.getCleanNym(targetNym) : targetNym.replace(/<[^>]*>/g, '');

        if (this.friends.has(targetPubkey)) {
            this.friends.delete(targetPubkey);
            this.saveFriends();
            this.displaySystemMessage(`Removed ${cleanNym} from friends`);
        } else {
            this.friends.add(targetPubkey);
            this.saveFriends();
            this.displaySystemMessage(`Added ${cleanNym} as a friend`);
        }

        this.updateFriendsList();
        this._refreshFriendBadgesFor(targetPubkey);
        if (typeof this.reapplyImageBlur === 'function') this.reapplyImageBlur();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    removeFriendByPubkey(pubkey) {
        this.friends.delete(pubkey);
        this.saveFriends();

        const nym = this.getNymFromPubkey(pubkey);
        this.displaySystemMessage(`Removed ${nym} from friends`);
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
            if (profileName) this.updatePMNicknameFromProfile(pubkey, profileName);
        }

        if (this.inPMMode && this.currentPM === pubkey) {
            const channelEl = document.getElementById('currentChannel');
            if (channelEl) {
                const known = this.users.get(pubkey);
                const baseNym = known ? this.parseNymFromDisplay(known.nym) : this.getNymFromPubkey(pubkey);
                const suffix = this.getPubkeySuffix(pubkey);
                const safePk = this._safePubkey(pubkey);
                const pmAvatarSrc = this.getAvatarUrl(pubkey);
                const flairHtml = this.getFlairForUser(pubkey);
                const friendBadge = this.getFriendBadgeHtml(pubkey);
                const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml}${friendBadge}`;
                channelEl.innerHTML = `<img src="${this.escapeHtml(pmAvatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" loading="lazy">@${displayNym} <span style="font-size: 12px; color: var(--text-dim);">(PM)</span>`;
            }
        }
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
            const nym = this.getNymFromPubkey(pubkey);
            const row = document.createElement('div');
            row.className = 'blocked-item';
            const span = document.createElement('span');
            span.textContent = nym;
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
        const cleanInput = input.replace(/^@/, '');
        const hashIndex = cleanInput.indexOf('#');
        let searchNym = cleanInput;
        let searchSuffix = null;

        if (hashIndex !== -1) {
            searchNym = cleanInput.substring(0, hashIndex);
            searchSuffix = cleanInput.substring(hashIndex + 1);
        }

        const matches = [];

        // First, search in active users
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

        // If no matches in active users, search in stored messages
        if (matches.length === 0) {
            // Search through all stored messages
            this.messages.forEach((channelMessages, channel) => {
                channelMessages.forEach(msg => {
                    if (msg.pubkey && msg.author) {
                        const baseNym = this.stripPubkeySuffix(msg.author);
                        if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                            if (searchSuffix) {
                                if (msg.pubkey.endsWith(searchSuffix)) {
                                    // Check if not already in matches
                                    if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                        matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                    }
                                }
                            } else {
                                // Check if not already in matches
                                if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                    matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                }
                            }
                        }
                    }
                });
            });

            // Also search in PM messages
            this.pmMessages.forEach((conversationMessages, conversationKey) => {
                conversationMessages.forEach(msg => {
                    if (msg.pubkey && msg.author) {
                        const baseNym = this.stripPubkeySuffix(msg.author);
                        if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                            if (searchSuffix) {
                                if (msg.pubkey.endsWith(searchSuffix)) {
                                    // Check if not already in matches
                                    if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                        matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                    }
                                }
                            } else {
                                // Check if not already in matches
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
            this.displaySystemMessage(`Multiple users found: ${matchList}`, 'system', { html: true });
            this.displaySystemMessage('Please specify using the #xxxx suffix');
            return null;
        }

        return matches[0].pubkey;
    },

});
