// nostr-cards.js - NIP-19 reference chips: decode a pasted nevent/note/naddr/
// npub/nprofile (or a bare 64-hex event id) and unfurl it into a display card
// under the message, the way a pasted URL unfurls into a link preview.

(function () {

    Object.assign(NYM.prototype, {

        NOSTR_REF_TTL_MS: 7 * 24 * 60 * 60 * 1000,
        NOSTR_REF_MISS_TTL_MS: 10 * 60 * 1000,
        NOSTR_REF_CACHE_MAX: 200,

        // Decodes a reference token, or null when it is not a NIP-19 entity
        // this app renders a card for.
        _decodeNostrRef(token) {
            const raw = String(token || '').trim().replace(/^nostr:/i, '');
            if (!raw) return null;
            if (/^[0-9a-f]{64}$/i.test(raw)) {
                return { type: 'event', id: raw.toLowerCase(), relays: [] };
            }
            const NT = window.NostrTools;
            if (!NT || !NT.nip19 || typeof NT.nip19.decode !== 'function') return null;
            let dec;
            try { dec = NT.nip19.decode(raw); } catch (_) { return null; }
            if (!dec || !dec.data) return null;
            const hex = (v) => (typeof v === 'string' ? v.toLowerCase() : '');
            const relays = (v) => (Array.isArray(v) ? v.slice(0, 4) : []);
            switch (dec.type) {
                case 'note':
                    return { type: 'event', id: hex(dec.data), relays: [] };
                case 'nevent':
                    return {
                        type: 'event',
                        id: hex(dec.data.id),
                        author: hex(dec.data.author),
                        eventKind: Number.isFinite(dec.data.kind) ? dec.data.kind : null,
                        relays: relays(dec.data.relays)
                    };
                case 'npub':
                    return { type: 'profile', pubkey: hex(dec.data), relays: [] };
                case 'nprofile':
                    return { type: 'profile', pubkey: hex(dec.data.pubkey), relays: relays(dec.data.relays) };
                case 'naddr':
                    return {
                        type: 'addr',
                        pubkey: hex(dec.data.pubkey),
                        eventKind: Number.isFinite(dec.data.kind) ? dec.data.kind : null,
                        identifier: typeof dec.data.identifier === 'string' ? dec.data.identifier : '',
                        relays: relays(dec.data.relays)
                    };
                default:
                    return null;
            }
        },

        // The clipboard form for a message: an nevent, falling back to the raw
        // id when nostr-tools isn't loaded or the encode fails.
        neventForMessage(id, pubkey, relays) {
            if (!id || !/^[0-9a-f]{64}$/i.test(id)) return '';
            const NT = window.NostrTools;
            if (NT && NT.nip19 && typeof NT.nip19.neventEncode === 'function') {
                try {
                    const hints = Array.isArray(relays) ? relays.slice(0, 3) : [];
                    return NT.nip19.neventEncode({
                        id: id.toLowerCase(),
                        author: (pubkey && /^[0-9a-f]{64}$/i.test(pubkey)) ? pubkey.toLowerCase() : undefined,
                        relays: hints.length ? hints : undefined
                    });
                } catch (_) { }
            }
            return id.toLowerCase();
        },

        // Relay hints good enough for someone else to fetch a channel message.
        _nostrRefRelayHints() {
            const out = [];
            const list = Array.isArray(this.relayList) ? this.relayList : [];
            for (const r of list) {
                const url = typeof r === 'string' ? r : (r && r.url);
                if (typeof url !== 'string' || !/^wss?:\/\//i.test(url)) continue;
                out.push(url);
                if (out.length >= 3) break;
            }
            return out;
        },

        _nostrRefCacheKey(ref) {
            if (!ref) return '';
            if (ref.type === 'event') return 'e:' + ref.id;
            if (ref.type === 'profile') return 'p:' + ref.pubkey;
            if (ref.type === 'addr') return `a:${ref.eventKind}:${ref.pubkey}:${ref.identifier}`;
            return '';
        },

        _loadNostrRefCache() {
            if (this._nostrRefCacheLoaded) return;
            this._nostrRefCacheLoaded = true;
            if (!this._nostrRefCache) this._nostrRefCache = new Map();
            try {
                const raw = localStorage.getItem('nym_nostr_ref_cache');
                if (!raw) return;
                const now = Date.now();
                for (const [key, entry] of Object.entries(JSON.parse(raw) || {})) {
                    if (!entry || typeof entry.at !== 'number' || !entry.data) continue;
                    if (now - entry.at > this.NOSTR_REF_TTL_MS) continue;
                    this._nostrRefCache.set(key, entry);
                }
            } catch (_) { }
        },

        _saveNostrRefCache() {
            if (this._nostrRefSaveTimer) return;
            this._nostrRefSaveTimer = setTimeout(() => {
                this._nostrRefSaveTimer = null;
                try {
                    const out = {};
                    for (const [key, entry] of this._nostrRefCache) {
                        if (entry && entry.data) out[key] = entry;
                    }
                    localStorage.setItem('nym_nostr_ref_cache', JSON.stringify(out));
                } catch (_) { }
            }, 2000);
        },

        _cacheNostrRef(key, data) {
            if (!key) return data || null;
            if (!this._nostrRefCache) this._nostrRefCache = new Map();
            this._nostrRefCache.set(key, { at: Date.now(), data: data || null });
            while (this._nostrRefCache.size > this.NOSTR_REF_CACHE_MAX) {
                this._nostrRefCache.delete(this._nostrRefCache.keys().next().value);
            }
            this._saveNostrRefCache();
            return data || null;
        },

        // Resolves a reference to its card payload: local stores first, then a
        // one-shot relay REQ. Hits and misses are cached; concurrent callers
        // for the same reference share one lookup.
        resolveNostrRef(token) {
            const ref = this._decodeNostrRef(token);
            if (!ref) return Promise.resolve(null);
            const key = this._nostrRefCacheKey(ref);
            if (!key) return Promise.resolve(null);

            const local = this._localNostrRefCard(ref);
            if (local) return Promise.resolve(local);

            this._loadNostrRefCache();
            const hit = this._nostrRefCache.get(key);
            if (hit) {
                const ttl = hit.data ? this.NOSTR_REF_TTL_MS : this.NOSTR_REF_MISS_TTL_MS;
                if (Date.now() - hit.at <= ttl) return Promise.resolve(hit.data);
                this._nostrRefCache.delete(key);
            }

            if (!this._nostrRefInflight) this._nostrRefInflight = new Map();
            const pending = this._nostrRefInflight.get(key);
            if (pending) return pending;

            const p = this._fetchNostrRef(ref)
                .then(data => this._cacheNostrRef(key, data))
                .catch(() => this._cacheNostrRef(key, null))
                .finally(() => this._nostrRefInflight.delete(key));
            this._nostrRefInflight.set(key, p);
            return p;
        },

        // A card built from what this client already holds — no network.
        _localNostrRefCard(ref) {
            if (!ref) return null;
            if (ref.type === 'profile') {
                const card = this._profileNostrRefCard(ref.pubkey);
                if (card) return card;
                if (typeof this.queueProfileFetch === 'function') {
                    try { this.queueProfileFetch(ref.pubkey); } catch (_) { }
                }
                return null;
            }
            if (ref.type !== 'event') return null;
            const msg = this._findStoredMessage(ref.id);
            if (!msg) return null;
            return {
                type: 'event',
                id: msg.id,
                pubkey: msg.pubkey || '',
                author: msg.author || '',
                content: msg.content || '',
                created_at: msg.created_at || 0,
                eventKind: msg.eventKind || (msg.geohash ? 20000 : 0),
                channel: msg.geohash ? `#${msg.geohash}` : (msg.channel || ''),
                local: true
            };
        },

        // The storage key of the conversation holding `id`, or '' when this
        // client has no copy. Channels key `#<name>`, PMs `pm-<pubkey>`,
        // groups `group-<id>`.
        _conversationHolding(id) {
            if (!id) return '';
            for (const store of [this.messages, this.pmMessages]) {
                if (!store || typeof store.forEach !== 'function') continue;
                for (const [key, list] of store) {
                    if (!Array.isArray(list)) continue;
                    for (const m of list) {
                        if (m && (m.id === id || m.nymMessageId === id)) return key;
                    }
                }
            }
            return '';
        },

        _findStoredMessage(id) {
            if (!id) return null;
            const stores = [this.messages, this.pmMessages];
            for (const store of stores) {
                if (!store || typeof store.forEach !== 'function') continue;
                for (const list of store.values()) {
                    if (!Array.isArray(list)) continue;
                    for (const m of list) {
                        if (m && (m.id === id || m.nymMessageId === id)) return m;
                    }
                }
            }
            return null;
        },

        _profileNostrRefCard(pubkey) {
            if (!pubkey) return null;
            const user = this.users && this.users.get(pubkey);
            const profile = user && user.profile;
            const nym = (user && user.nym) || '';
            const about = (profile && profile.about) || '';
            if (!nym && !about) return null;
            return {
                type: 'profile',
                pubkey,
                author: nym,
                about,
                nip05: (profile && profile.nip05) || '',
                local: true
            };
        },

        async _fetchNostrRef(ref) {
            if (ref.type === 'profile') {
                if (typeof this.fetchProfileDirect === 'function') {
                    try { await this.fetchProfileDirect(ref.pubkey); } catch (_) { }
                }
                return this._profileNostrRefCard(ref.pubkey);
            }

            let filter;
            if (ref.type === 'event') {
                filter = { ids: [ref.id], limit: 1 };
            } else if (ref.type === 'addr') {
                if (!ref.pubkey || !Number.isFinite(ref.eventKind)) return null;
                filter = {
                    kinds: [ref.eventKind],
                    authors: [ref.pubkey],
                    '#d': [ref.identifier],
                    limit: 1
                };
            } else {
                return null;
            }

            const event = await this._fetchNostrEventOnce(filter);
            if (!event) return null;
            const nymTag = Array.isArray(event.tags)
                ? event.tags.find(t => Array.isArray(t) && t[0] === 'n')
                : null;
            const rawNym = nymTag && typeof nymTag[1] === 'string'
                ? (typeof this.stripPubkeySuffix === 'function'
                    ? this.stripPubkeySuffix(nymTag[1]) : nymTag[1])
                : '';
            const author = typeof this.resolveDisplayNym === 'function'
                ? this.resolveDisplayNym(event.pubkey, rawNym)
                : rawNym;
            const channelTag = Array.isArray(event.tags)
                ? event.tags.find(t => Array.isArray(t) && (t[0] === 'g' || t[0] === 'd'))
                : null;
            return {
                type: 'event',
                id: event.id,
                pubkey: event.pubkey,
                author,
                content: typeof event.content === 'string' ? event.content : '',
                created_at: event.created_at || 0,
                eventKind: event.kind,
                channel: channelTag && channelTag[1] ? `#${channelTag[1]}` : ''
            };
        },

        // One REQ across a few relays for a single event, resolving with the
        // newest match or null on timeout. EOSE only ends the wait once
        // something has arrived: the first relay to answer often lacks it.
        _fetchNostrEventOnce(filter, timeoutMs) {
            return new Promise(resolve => {
                if (!this.connected || typeof this.sendRequestToFewRelays !== 'function') {
                    resolve(null);
                    return;
                }
                if (!this._subscriptionHandlers) this._subscriptionHandlers = new Map();
                const subId = 'nref-' + Math.random().toString(36).slice(2);
                let best = null;
                let settled = false;
                let timer = null;
                const cleanup = () => {
                    if (settled) return;
                    settled = true;
                    if (timer) clearTimeout(timer);
                    this._subscriptionHandlers.delete(subId);
                    try { this.closeFewRelaysSub(subId); } catch (_) { }
                    if (typeof this._oneShotReqDone === 'function') this._oneShotReqDone();
                    resolve(best);
                };
                this._subscriptionHandlers.set(subId, (type, data) => {
                    if (type === 'EVENT' && data[0] === subId) {
                        const ev = data[1];
                        if (ev && ev.id && (!best || (ev.created_at || 0) > (best.created_at || 0))) {
                            best = ev;
                        }
                    } else if (type === 'EOSE' && data[0] === subId && best) {
                        cleanup();
                    }
                });
                const run = () => {
                    timer = setTimeout(cleanup, timeoutMs || 4000);
                    try { this.sendRequestToFewRelays(['REQ', subId, filter]); }
                    catch (_) { cleanup(); }
                };
                if (typeof this._oneShotReqAcquire === 'function') this._oneShotReqAcquire(run);
                else run();
            });
        },

        _nostrRefKindLabel(kind) {
            switch (kind) {
                case 0: return 'Profile';
                case 1: return 'Note';
                case 7: return 'Reaction';
                case 20000:
                case 23333: return 'Channel message';
                case 30023: return 'Article';
                case 1059:
                case 1060: return 'Private message';
                default: return Number.isFinite(kind) ? `Kind ${kind}` : 'Event';
            }
        },

        _cardAuthorHtml(data) {
            const esc = (s) => this.escapeHtml(s || '');
            const raw = (data && data.author) || '';
            const base = typeof this.stripPubkeySuffix === 'function'
                ? this.stripPubkeySuffix(raw) : raw;
            if (!base) return '';
            const pubkey = (data && data.pubkey) || '';
            const suffix = (pubkey && typeof this.getPubkeySuffix === 'function')
                ? this.getPubkeySuffix(pubkey) : '';
            const attrs = pubkey
                ? ` data-action="openNostrProfileCard" data-nostr-pubkey="${esc(pubkey)}" role="button" tabindex="0"`
                : '';
            return `<span class="nostr-card-author"${attrs}>${esc(base)}` +
                `${suffix ? `<span class="nym-suffix">#${esc(suffix)}</span>` : ''}</span>`;
        },

        _hydrateCardAuthor(cardEl, data) {
            const pubkey = data && data.pubkey;
            if (!cardEl || !pubkey) return;
            if (typeof this.hasResolvedNym === 'function' && this.hasResolvedNym(pubkey)) return;
            if (typeof this.fetchProfileDirect !== 'function') return;
            Promise.resolve(this.fetchProfileDirect(pubkey)).then(() => {
                const span = cardEl.querySelector('.nostr-card-author');
                const nym = this.resolveDisplayNym(pubkey, '');
                if (!span || !nym || nym.toLowerCase() === 'nym') return;
                const fresh = this._cardAuthorHtml(Object.assign({}, data, { author: nym }));
                if (fresh) span.outerHTML = fresh;
            }).catch(() => { });
        },

        _renderNostrRefCard(data) {
            if (!data) return '';
            const esc = (s) => this.escapeHtml(s || '');
            const avatarSrc = (data.pubkey && typeof this.getAvatarUrl === 'function')
                ? this.getAvatarUrl(data.pubkey) : '';
            // Carries `data-avatar-pubkey` so a picture that lands after the
            // card was painted rides the global _flushAvatarUpdates sweep, the
            // way every other avatar in the app does.
            const avatarHtml = avatarSrc
                ? `<img src="${esc(avatarSrc)}" class="nostr-card-avatar" alt="" decoding="async" loading="lazy" data-avatar-pubkey="${esc(this._safePubkey(data.pubkey))}" data-error-action="errorHideElement">`
                : '';
            const authorHtml = this._cardAuthorHtml(data);

            if (data.type === 'profile') {
                const nip05Html = data.nip05
                    ? `<span class="nostr-card-nip05">${esc(data.nip05)}</span>` : '';
                const aboutHtml = data.about
                    ? `<div class="nostr-card-body">${this.formatMessage(data.about)}</div>` : '';
                // A shared npub is a person, so the card offers what tapping
                // that person anywhere else in the app offers: their menu. The
                // HEAD carries it, not the whole card: the body below is real
                // content, and a tap target around all of it would compete
                // with every link in it.
                const profileAttr = data.pubkey
                    ? ' data-action="openNostrProfileCard" role="button" tabindex="0"' : '';
                return `<div class="nostr-card nostr-card-profile" data-nostr-pubkey="${esc(data.pubkey)}">
                    <div class="nostr-card-head"${profileAttr}>${avatarHtml}<div class="nostr-card-ident">${authorHtml}${nip05Html}</div><span class="nostr-card-kind">Profile</span></div>
                    ${aboutHtml}
                </div>`;
            }

            const kindLabel = this._nostrRefKindLabel(data.eventKind);
            const timeHtml = data.created_at
                ? `<span class="nostr-card-time">${esc(this._formatRelativeTime(data.created_at * 1000))}</span>`
                : '';
            const channelHtml = data.channel
                ? `<span class="nostr-card-channel">${esc(data.channel)}</span>` : '';
            // The referenced event's body renders as a message body — media,
            // code, mentions, emoji — not an escaped excerpt. A referenced
            // event is very often exactly the media it carries, which a
            // character-count truncation could never show. `_attachCardBody`
            // then adds the same height-based Read more clamp and the link
            // previews once this is in the DOM.
            const body = (data.content || '').trim();
            const bodyHtml = body
                ? `<div class="nostr-card-body">${this.formatMessage(body)}</div>`
                : '<div class="nostr-card-body nostr-card-empty">No text content</div>';
            // The HEAD is the jump affordance, not the whole card — see the
            // profile branch above.
            const jumpAttr = this._findStoredMessage(data.id)
                ? ' data-action="jumpToNostrRef" role="button" tabindex="0"' : '';
            return `<div class="nostr-card" data-nostr-event-id="${esc(data.id)}">
                <div class="nostr-card-head"${jumpAttr}>${avatarHtml}<div class="nostr-card-ident">${authorHtml}${channelHtml}</div><span class="nostr-card-kind">${esc(kindLabel)}</span>${timeHtml}</div>
                ${bodyHtml}
            </div>`;
        },

        // Unfurls every distinct reference chip in a rendered message.
        // Idempotent, and paints straight from the cache when warm.
        _attachNostrCards(messageEl) {
            if (!messageEl || messageEl.dataset.nostrCardsAttached === '1') return;
            const chips = messageEl.querySelectorAll('.nostr-ref[data-nostr-ref]');
            if (chips.length === 0) return;
            const container = messageEl.querySelector('.message-content');
            if (!container) return;
            messageEl.dataset.nostrCardsAttached = '1';

            const seen = new Set();
            const tokens = [];
            for (const chip of chips) {
                const token = chip.dataset.nostrRef;
                if (!token || seen.has(token)) continue;
                seen.add(token);
                tokens.push(token);
                if (tokens.length >= 4) break;
            }
            if (tokens.length === 0) return;

            const paint = (data) => {
                if (!data || !container.isConnected) return;
                const html = this._renderNostrRefCard(data);
                if (!html) return;
                const el = document.createElement('div');
                el.className = 'nostr-card-container';
                el.innerHTML = html;
                container.appendChild(el);
                this._attachCardBody(el, data);
                this._hydrateCardAuthor(el, data);
            };

            const run = () => {
                for (const token of tokens) {
                    this.resolveNostrRef(token).then(paint).catch(() => { });
                }
            };

            // Same deferral as link previews: a 50-message window must not fire
            // a REQ per reference for rows the user may never scroll to.
            if (typeof IntersectionObserver !== 'function') { run(); return; }
            if (!this._nostrCardObserver) {
                this._nostrCardObserver = new IntersectionObserver((entries) => {
                    for (const en of entries) {
                        if (!en.isIntersecting) continue;
                        this._nostrCardObserver.unobserve(en.target);
                        const cb = en.target._nostrCardRun;
                        if (cb) { en.target._nostrCardRun = null; cb(); }
                    }
                }, { rootMargin: '200px' });
            }
            messageEl._nostrCardRun = run;
            this._nostrCardObserver.observe(messageEl);
        },

        // Chip click: a profile reference opens that user's card, an event
        // reference scrolls to the message when this client holds it.
        openNostrRef(token, e) {
            const ref = this._decodeNostrRef(token);
            if (!ref) return;
            if (ref.type === 'profile') {
                if (typeof this.showContextMenu !== 'function') return;
                const nym = this.resolveDisplayNym(ref.pubkey, '');
                const suffix = typeof this.getPubkeySuffix === 'function'
                    ? this.getPubkeySuffix(ref.pubkey) : '';
                this.showContextMenu(e, suffix ? `${nym}#${suffix}` : nym, ref.pubkey, null, null, true);
                return;
            }
            if (ref.type !== 'event') return;
            this.jumpToNostrRef(ref.id);
        },

        // The referenced event is very often in ANOTHER conversation — that is
        // rather the point of pasting a reference — so a miss in the open view
        // is not the answer. Switch to whichever conversation holds it, then
        // scroll, the way a tapped blockquote jumps to its quoted source.
        // Opens the context menu for the person a profile card points at — the
        // same menu a tapped nym or avatar opens.
        openNostrProfileCard(pubkey, e) {
            if (!pubkey || typeof this.showContextMenu !== 'function') return;
            const raw = this.resolveDisplayNym(pubkey, '');
            // Both sources can already carry `#xxxx` (getNymFromPubkey always
            // does), so strip before re-adding or the menu title reads
            // `name#abcd#abcd`.
            const nym = typeof this.stripPubkeySuffix === 'function'
                ? this.stripPubkeySuffix(raw) : raw;
            const suffix = typeof this.getPubkeySuffix === 'function'
                ? this.getPubkeySuffix(pubkey) : '';
            this.showContextMenu(e, suffix ? `${nym}#${suffix}` : nym, pubkey, null, null, false);
        },

        jumpToNostrRef(id) {
            if (!id) return;
            if (this._scrollToLoadedMessage(id)) return;

            const key = this._conversationHolding(id);
            if (!key) {
                if (typeof this.displaySystemMessage === 'function') {
                    this.displaySystemMessage('Referenced event is not available');
                }
                return;
            }
            if (!this._switchToConversation(key)) return;
            // Switching re-renders the conversation; the row exists only once
            // that paint lands, so retry across a few frames.
            this._scrollWhenRendered(id);
        },

        _scrollToLoadedMessage(id) {
            const el = (typeof this.findMessageElementAnywhere === 'function')
                ? this.findMessageElementAnywhere(id) : null;
            if (!el || !el.isConnected) return false;
            if (typeof el.scrollIntoView === 'function') {
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }
            el.classList.add('message-scroll-flash');
            setTimeout(() => el.classList.remove('message-scroll-flash'), 1600);
            return true;
        },

        // Opens the conversation a storage key names. Returns false when the
        // key's shape isn't one we can route to.
        _switchToConversation(key) {
            if (key.startsWith('pm-')) {
                const pubkey = key.slice(3);
                if (!/^[0-9a-f]{64}$/i.test(pubkey)) return false;
                if (typeof this.openPM !== 'function') return false;
                this.openPM(this.resolveDisplayNym(pubkey, ''), pubkey);
                return true;
            }
            if (key.startsWith('group-')) {
                const groupId = key.slice(6);
                if (!groupId || typeof this.openGroup !== 'function') return false;
                this.openGroup(groupId);
                return true;
            }
            const name = key.startsWith('#') ? key.slice(1) : key;
            if (!name || typeof this.switchChannel !== 'function') return false;
            this.switchChannel(name, this.isValidGeohash(name) ? name : '');
            return true;
        },

        _scrollWhenRendered(id, attempts = 12) {
            requestAnimationFrame(() => {
                if (this._scrollToLoadedMessage(id)) return;
                if (attempts > 1) { this._scrollWhenRendered(id, attempts - 1); return; }
                if (typeof this.displaySystemMessage === 'function') {
                    this.displaySystemMessage('Referenced event is not available');
                }
            });
        },

        // The passes a card body needs once it is in the DOM, the same ones a
        // message body gets: the height-based Read more clamp, link previews,
        // media fallbacks, and the others'-images blur. Reference chips inside
        // it are deliberately NOT unfurled — a card inside a card, and again
        // inside that one, is not a thread of context.
        _attachCardBody(cardEl, data) {
            const bodyEl = cardEl.querySelector('.nostr-card-body');
            if (!bodyEl || bodyEl.classList.contains('nostr-card-empty')) return;

            const text = (data.type === 'profile' ? data.about : data.content) || '';
            if (text.length > this._readMoreThreshold()) {
                const target = this._collapseWithReadMore(bodyEl);
                if (target) this._settleReadMore([target]);
            }

            if (typeof this._attachLinkPreviews === 'function') {
                this._attachLinkPreviews(cardEl, {
                    scope: bodyEl,
                    container: bodyEl,
                    flag: 'cardPreviewsAttached',
                });
            }
            if (typeof this._attachMediaFallbacks === 'function') {
                this._attachMediaFallbacks(cardEl);
            }

            const pubkey = data.pubkey || '';
            const isOwn = pubkey && pubkey === this.pubkey;
            const shouldBlur = !isOwn && (this.blurOthersImages === true ||
                (this.blurOthersImages === 'friends' && !this.isFriend(pubkey)));
            if (shouldBlur) {
                bodyEl.querySelectorAll('img:not(.avatar-message)')
                    .forEach(img => img.classList.add('blurred'));
            }
        },

        // Copies an event reference, confirming in place on the button.
        copyNostrEventRef(text, btnEl) {
            if (!text) return;
            const done = (ok) => {
                if (!btnEl) return;
                const prev = btnEl.dataset.label || btnEl.textContent;
                btnEl.dataset.label = prev;
                btnEl.textContent = ok ? 'Copied' : 'Copy failed';
                setTimeout(() => { btnEl.textContent = btnEl.dataset.label || prev; }, 1500);
            };
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(() => done(true)).catch(() => done(false));
                return;
            }
            done(false);
        }

    });

})();
