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

    // Generate a unique color based on pubkey
    generateUniqueColor(pubkey) {
        let hash = 0;
        for (let i = 0; i < pubkey.length; i++) {
            hash = pubkey.charCodeAt(i) + ((hash << 5) - hash);
        }

        const isLight = document.body.classList.contains('light-mode');

        // Generate HSL color (adjusted for light/dark backgrounds)
        const hue = Math.abs(hash) % 360;
        const saturation = isLight ? (55 + (Math.abs(hash) % 35)) : (65 + (Math.abs(hash) % 35));
        const lightness = isLight ? (25 + (Math.abs(hash) % 20)) : (60 + (Math.abs(hash) % 25));

        // Create unique class name (include mode so it regenerates on switch)
        const modeTag = isLight ? 'l' : 'd';
        const uniqueClass = `bitchat-user-${modeTag}${Math.abs(hash) % 1000}`;

        // Add dynamic style if not exists
        if (!document.getElementById(uniqueClass)) {
            const style = document.createElement('style');
            style.id = uniqueClass;
            style.textContent = `
    .${uniqueClass} {
        color: hsl(${hue}, ${saturation}%, ${lightness}%) !important;
    }
    .${uniqueClass} .nym-suffix {
        color: hsl(${hue}, ${saturation}%, ${lightness}%) !important;
    }
`;
            document.head.appendChild(style);
        }

        return uniqueClass;
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

            if (content && !this.blockedUsers.has(author)) {
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

        this.displaySystemMessage(`Unblocked keyword: "${keyword}"`);
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    updateKeywordList() {
        const list = document.getElementById('keywordList');
        if (this.blockedKeywords.size === 0) {
            list.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No blocked keywords</div>';
        } else {
            list.innerHTML = Array.from(this.blockedKeywords).map(keyword => {
                const safeAttr = this.escapeHtml(keyword);
                return `
                <div class="keyword-item">
                    <span>${safeAttr}</span>
                    <button class="remove-keyword-btn" data-keyword="${safeAttr}">Remove</button>
                </div>`;
            }).join('');
            list.querySelectorAll('.remove-keyword-btn').forEach(btn => {
                btn.addEventListener('click', () => this.removeBlockedKeyword(btn.dataset.keyword));
            });
        }
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
            el.onerror = function () { this.onerror = null; this.src = `https://robohash.org/${pubkey}.png?set=set1&size=80x80`; };
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

    getAvatarUrl(pubkey) {
        // Prefer cached blob URL (instant, no network)
        const blob = this.avatarBlobCache.get(pubkey);
        if (blob) return blob;
        // Check custom avatar URL
        const custom = this.userAvatars.get(pubkey);
        if (custom) return custom;
        // Fall back to robohash
        return `https://robohash.org/${pubkey}.png?set=set1&size=80x80`;
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
                this.updateRenderedAvatars(pubkey, objectUrl);
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

    // Update already-rendered message avatars when a kind 0 profile picture arrives
    updateRenderedAvatars(pubkey, avatarUrl) {
        const safePk = this._safePubkey(pubkey);
        if (!safePk) return;
        const fallback = `https://robohash.org/${safePk}.png?set=set1&size=80x80`;
        document.querySelectorAll(`img[data-avatar-pubkey="${safePk}"]`).forEach(img => {
            img.onerror = function () { this.onerror = null; this.src = fallback; };
            img.src = avatarUrl;
        });
        // Update context menu avatar if open for this user
        const ctxImg = document.getElementById('ctxAvatarImg');
        if (ctxImg && this.contextMenuData?.pubkey === pubkey) {
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

            const response = await fetch('https://blossom.band/upload', {
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

            const response = await fetch('https://blossom.band/upload', {
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

            const response = await fetch('https://blossom.band/upload', {
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
        const MAX_VIDEO_SIZE = 50 * 1024 * 1024; // 50MB

        if (isVideo && file.size > MAX_VIDEO_SIZE) {
            this.displaySystemMessage('Video files must be under 50MB. Your file is ' + (file.size / (1024 * 1024)).toFixed(1) + 'MB.');
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
            const response = await fetch('https://blossom.band/upload', {
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

            if (newAvatarUrl) {
                this.userAvatars.set(pubkey, newAvatarUrl);
                this.cacheAvatarImage(pubkey, newAvatarUrl);
                this.updateRenderedAvatars(pubkey, newAvatarUrl);
            } else {
                // Avatar removed - fall back to robohash
                this.userAvatars.delete(pubkey);
                this.updateRenderedAvatars(pubkey, this.getAvatarUrl(pubkey));
            }
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
            user.status = status;
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
        const currentChannelKey = this.currentGeohash || this.currentChannel;

        // Build set of pubkeys from PM conversations and group chats for PM-only mode filtering
        let pmOnlyPubkeys = null;
        if (this.settings.groupChatPMOnlyMode) {
            pmOnlyPubkeys = new Set();
            // Add all PM conversation peers
            this.pmConversations.forEach((conv, pubkey) => {
                pmOnlyPubkeys.add(pubkey);
            });
            // Add all group chat members
            this.groupConversations.forEach((group) => {
                if (group.members) {
                    group.members.forEach(pk => pmOnlyPubkeys.add(pk));
                }
            });
        }

        // Get deduplicated users (one entry per pubkey), including inactive
        // Compute effective status without mutating the source user objects
        const uniqueUsers = new Map();
        const now = Date.now();
        const activeThreshold = 300000; // 5 minutes
        this.users.forEach((user, pubkey) => {
            if (!this.blockedUsers.has(user.nym)) {
                // In PM-only mode, only show users from PMs and group chats
                if (pmOnlyPubkeys && !pmOnlyPubkeys.has(pubkey)) return;

                if (!uniqueUsers.has(pubkey)) {
                    let effectiveStatus = user.status;
                    if (this.isVerifiedBot(pubkey)) {
                        effectiveStatus = 'online';
                    } else if (now - user.lastSeen >= activeThreshold && effectiveStatus !== 'away') {
                        effectiveStatus = 'offline';
                    }
                    uniqueUsers.set(pubkey, { ...user, effectiveStatus });
                }
            }
        });

        // Sort into three explicit groups: active first, then away, then inactive
        // Each group is alphabetically sorted by nym
        const alphabetical = (a, b) => {
            const nymA = this.parseNymFromDisplay(a.nym || '').toLowerCase();
            const nymB = this.parseNymFromDisplay(b.nym || '').toLowerCase();
            return nymA.localeCompare(nymB);
        };
        const validUsers = Array.from(uniqueUsers.values()).filter(user => user && user.nym);
        const activeUsers = validUsers.filter(u => u.effectiveStatus === 'online').sort(alphabetical);
        const awayUsers = validUsers.filter(u => u.effectiveStatus === 'away').sort(alphabetical);
        const inactiveUsers = validUsers.filter(u => u.effectiveStatus === 'offline').sort(alphabetical);
        const allUsers = [...activeUsers, ...awayUsers, ...inactiveUsers];

        // Filter users based on search term
        let displayUsers = allUsers;
        if (this.userSearchTerm) {
            const term = this.userSearchTerm.toLowerCase();
            displayUsers = allUsers.filter(user =>
                this.parseNymFromDisplay(user.nym).toLowerCase().includes(term)
            );
        }

        // Get users in current channel for the count
        let channelUserCount = 0;
        this.users.forEach((user, pubkey) => {
            if (Date.now() - user.lastSeen < 300000 &&
                !this.blockedUsers.has(user.nym) &&
                user.channels && user.channels.has(currentChannelKey)) {
                channelUserCount++;
            }
        });

        // Build updated DOM by reusing existing nodes where possible
        // so that unchanged avatar <img> elements are never removed/re-added
        // (which would cause visible flickering).
        const existingItems = new Map();
        userListContent.querySelectorAll('.user-item[data-pubkey]').forEach(el => {
            existingItems.set(el.dataset.pubkey, el);
        });

        const fragment = document.createDocumentFragment();

        displayUsers.forEach((user) => {
            const baseNym = this.parseNymFromDisplay(user.nym);
            const suffix = this.getPubkeySuffix(user.pubkey);
            const flairHtml = this.getFlairForUser(user.pubkey);
            const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml}`;
            const verifiedBadge = this.isVerifiedDeveloper(user.pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}" style="margin-left: 3px;">✓</span>`
                : this.verifiedBotPubkeys.has(user.pubkey)
                    ? '<span class="verified-badge" title="Nymchat Bot" style="margin-left: 3px;">✓</span>'
                    : '';
            const userColorClass = this.settings.theme === 'bitchat' ? this.getUserColorClass(user.pubkey) : '';
            const avatarSrc = this.getAvatarUrl(user.pubkey);

            let el = existingItems.get(user.pubkey);
            if (el) {
                // Reuse existing DOM node — only update mutable parts
                existingItems.delete(user.pubkey);
                const statusSpan = el.querySelector('.user-status');
                if (statusSpan) statusSpan.className = `user-status ${user.effectiveStatus}`;
                const img = el.querySelector('img.avatar-user-list');
                if (img && img.getAttribute('src') !== avatarSrc) img.src = avatarSrc;
                el.className = `user-item list-item ${userColorClass}`;
                fragment.appendChild(el);
            } else {
                // Create new element for a user not previously in the list
                const wrapper = document.createElement('div');
                const safePk = this._safePubkey(user.pubkey);
                wrapper.innerHTML = `<div class="user-item list-item ${userColorClass}"
                        data-pubkey="${safePk}"
                        data-nym="${this.escapeHtml(baseNym)}">
                    <img src="${this.escapeHtml(avatarSrc)}" class="avatar-user-list" alt="" loading="lazy" data-avatar-pubkey="${safePk}" onerror="this.onerror=null;this.src='https://robohash.org/${safePk}.png?set=set1&size=80x80'">
                    <span class="user-status ${user.effectiveStatus}"></span>
                    <span class="${userColorClass}">${displayNym} ${verifiedBadge}</span>
                </div>`;
                const itemEl = wrapper.firstElementChild;
                const ctxHandler = (e) => this.showContextMenu(e, displayNym, user.pubkey, null, null, true);
                itemEl.addEventListener('click', ctxHandler);
                itemEl.addEventListener('contextmenu', ctxHandler);
                fragment.appendChild(itemEl);
            }
        });

        // Remove users no longer in the list
        existingItems.forEach(el => el.remove());

        // Replace content — moves existing nodes (preserving loaded images)
        userListContent.textContent = '';
        userListContent.appendChild(fragment);

        this.updateViewMoreButton('userListContent');

        const activeCount = allUsers.filter(u => u.effectiveStatus !== 'offline').length;
        const userListTitle = document.querySelector('#userList .nav-title-text');
        if (userListTitle) {
            userListTitle.textContent = `Nyms (${this.abbreviateNumber(activeCount)} active)`;
        }

        if (!this.inPMMode) {
            const meta = document.getElementById('channelMeta');
            if (meta) meta.textContent = `${this.abbreviateNumber(channelUserCount)} active nyms`;
        }

        // Refresh mention menu if it's currently open so it reflects latest presence
        this.refreshAutocompleteIfOpen();
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

    isNymBlocked(nym) {
        const cleanNym = this.parseNymFromDisplay(nym);
        return Array.from(this.blockedUsers).some(blockedNym =>
            this.parseNymFromDisplay(blockedNym) === cleanNym
        );
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
        if (this.blockedUsers.size === 0) {
            list.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No blocked users</div>';
        } else {
            // Show loading state
            list.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">Loading...</div>';

            // Load async without blocking
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

        // Now render with proper nyms
        listElement.innerHTML = blockedArray.map(pubkey => {
            const nym = this.escapeHtml(this.getNymFromPubkey(pubkey));
            return `
    <div class="blocked-item">
        <span>${nym}</span>
        <button class="unblock-btn" onclick="nym.unblockByPubkey('${pubkey}')">Unblock</button>
    </div>
`;
        }).join('');
    },

    // Fetch metadata for blocked users
    async fetchMetadataForBlockedUsers(pubkeys) {
        if (pubkeys.length === 0) return;

        return new Promise((resolve) => {
            const subId = "blocked-meta-" + Math.random().toString(36).substring(7);
            let receivedCount = 0;
            let messageHandlers = [];

            const cleanup = () => {
                messageHandlers.forEach(handler => {
                    const index = this.relayMessageHandlers?.indexOf(handler);
                    if (index > -1) {
                        this.relayMessageHandlers.splice(index, 1);
                    }
                });
                this.sendToRelay(["CLOSE", subId]);
            };

            const timeout = setTimeout(() => {
                cleanup();
                resolve();
            }, 3000);

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

            this.sendRequestToFewRelays(subscription);
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
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    removeFriendByPubkey(pubkey) {
        this.friends.delete(pubkey);
        this.saveFriends();

        const nym = this.getNymFromPubkey(pubkey);
        this.displaySystemMessage(`Removed ${nym} from friends`);
        this.updateFriendsList();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    updateFriendsList() {
        const list = document.getElementById('friendsList');
        if (!list) return;
        if (this.friends.size === 0) {
            list.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No friends added</div>';
        } else {
            list.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">Loading...</div>';
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

        listElement.innerHTML = friendsArray.map(pubkey => {
            const nym = this.escapeHtml(this.getNymFromPubkey(pubkey));
            return `
    <div class="blocked-item">
        <span>${nym}</span>
        <button class="unblock-btn" onclick="nym.removeFriendByPubkey('${pubkey}')">Remove</button>
    </div>
`;
        }).join('');
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
