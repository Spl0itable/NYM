const _RX_EMOJI_SHORTCODE = /^[a-zA-Z0-9_]+$/;
const _RX_EMOJI_URL = /^https?:\/\//i;
const _RX_REACTION_SHORTCODE = /^:[a-zA-Z0-9_]{1,64}:$/;
const _RX_REACTION_EMOJI = new RegExp('^(?:(?:[\\u{1F1E0}-\\u{1F1FF}]{2})|(?:[#*0-9]\\u{FE0F}?\\u{20E3})|(?:(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?(?:\\u{200D}(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?)*)(?:[\\u{E0020}-\\u{E007E}]+\\u{E007F})?)$', 'u');
const _REACTION_MAX_LENGTH = 64;
const _REACTION_EXTRA_SYMBOLS = new Set(['\u20BF', '+', '-']);
const EMOJI_D1_REFRESH_MS = 6 * 60 * 60 * 1000;
const EMOJI_PACK_CACHE_MAX = 200;
const _EMOJI_EXTRA_NAMES = {
    '🫢': ['face_with_open_eyes_and_hand_over_mouth'], '😦': ['frowning_face_with_open_mouth'],
    '👨‍👩‍👦': ['family_man_woman_boy'], '👨‍👩‍👧': ['family_man_woman_girl'],
    '👨‍👩‍👧‍👦': ['family_man_woman_girl_boy'], '👨‍👩‍👦‍👦': ['family_man_woman_boy_boy'],
    '👨‍👩‍👧‍👧': ['family_man_woman_girl_girl'], '🤟': ['love_you_gesture'], '🔈': ['speaker_low_volume'],
    '🔉': ['speaker_medium_volume'], '📢': ['loudspeaker'], '📣': ['megaphone'], '📯': ['postal_horn'],
    '🔯': ['dotted_six_pointed_star'], '🕎': ['menorah'], '☦️': ['orthodox_cross'], '🛐': ['place_of_worship'],
    '⛎': ['ophiuchus'], '♈': ['aries'], '♉': ['taurus'], '♊': ['gemini'], '♋': ['cancer'], '♌': ['leo'],
    '♍': ['virgo'], '♎': ['libra'], '♏': ['scorpio'], '♐': ['sagittarius'], '♑': ['capricorn'],
    '♒': ['aquarius'], '♓': ['pisces'], '🆔': ['id_button'], '🉑': ['japanese_acceptable_button'],
    '📴': ['mobile_phone_off'], '📳': ['vibration_mode'], '🈶': ['japanese_not_free_of_charge_button'],
    '🈚': ['japanese_free_of_charge_button'], '🈸': ['japanese_application_button'],
    '🈺': ['japanese_open_for_business_button'], '🈷️': ['japanese_monthly_amount_button'],
    '✴️': ['eight_pointed_star'], '🆚': ['vs_button'], '🉐': ['japanese_bargain_button'],
    '㊙️': ['japanese_secret_button'], '㊗️': ['japanese_congratulations_button'],
    '🈴': ['japanese_passing_grade_button'], '🈵': ['japanese_no_vacancy_button'],
    '🈹': ['japanese_discount_button'], '🈲': ['japanese_prohibited_button'], '🅰️': ['a_button_blood_type'],
    '🅱️': ['b_button_blood_type'], '🆎': ['ab_button_blood_type'], '🆑': ['cl_button'],
    '🅾️': ['o_button_blood_type'], '🆘': ['sos_button'], '⭕': ['hollow_red_circle'], '🛑': ['stop_sign'],
    '⛔': ['no_entry'], '📛': ['name_badge'], '🚫': ['prohibited'], '♨️': ['hot_springs'],
    '🚷': ['no_pedestrians'], '🚯': ['no_littering'], '🚳': ['no_bicycles'], '🚱': ['non_potable_water'],
    '🔞': ['no_one_under_eighteen'], '📵': ['no_mobile_phones'], '🚭': ['no_smoking'],
    '❕': ['white_exclamation_mark'], '❔': ['white_question_mark'], '🔅': ['dim_button'],
    '🔆': ['bright_button'], '〽️': ['part_alternation_mark'], '🚸': ['children_crossing'],
    '🔱': ['trident_emblem'], '⚜️': ['fleur_de_lis'], '🔰': ['japanese_symbol_for_beginner'],
    '🈯': ['japanese_reserved_button'], '💹': ['chart_increasing_with_yen'], '❇️': ['sparkle'],
    '✳️': ['eight_spoked_asterisk'], '❎': ['cross_mark_button'], '🌐': ['globe_with_meridians'],
    '💠': ['diamond_with_a_dot'], 'Ⓜ️': ['circled_m'], '🌀': ['cyclone'], '🏧': ['atm_sign'],
    '🚾': ['water_closet'], '♿': ['wheelchair_symbol'], '🅿️': ['p_button'], '🛗': ['elevator'],
    '🈳': ['japanese_vacancy_button'], '🈂️': ['japanese_service_charge_button'], '🛂': ['passport_control'],
    '🛃': ['customs'], '🛄': ['baggage_claim'], '🛅': ['left_luggage'], '🚹': ['mens_room'],
    '🚺': ['womens_room'], '🚼': ['baby_symbol'], '⚧️': ['transgender_symbol'], '🚻': ['restroom'],
    '🚮': ['litter_in_bin_sign'], '🎦': ['cinema'], '📶': ['antenna_bars'], '🈁': ['japanese_here_button'],
    '🔣': ['input_symbols'], 'ℹ️': ['information'], '🔤': ['input_latin_letters'],
    '🔡': ['input_latin_lowercase'], '🔠': ['input_latin_uppercase'], '🆖': ['ng_button'], '🆗': ['ok_button'],
    '🆙': ['up_button'], '🆒': ['cool_button'], '🆕': ['new_button'], '🆓': ['free_button'],
    '0️⃣': ['zero', 'keycap_0'], '1️⃣': ['one', 'keycap_1'], '2️⃣': ['two', 'keycap_2'],
    '3️⃣': ['three', 'keycap_3'], '4️⃣': ['four', 'keycap_4'], '5️⃣': ['five', 'keycap_5'],
    '6️⃣': ['six', 'keycap_6'], '7️⃣': ['seven', 'keycap_7'], '8️⃣': ['eight', 'keycap_8'],
    '9️⃣': ['nine', 'keycap_9'], '🔟': ['keycap_10'], '🔢': ['input_numbers'], '#️⃣': ['hash', 'keycap_hash'],
    '*️⃣': ['asterisk', 'keycap_asterisk'], '⏏️': ['eject_button'], '▶️': ['play_button'],
    '⏸️': ['pause_button'], '⏯️': ['play_or_pause_button'], '⏹️': ['stop_button'], '⏺️': ['record_button'],
    '⏭️': ['next_track_button'], '⏮️': ['last_track_button'], '⏩': ['fast_forward_button'],
    '⏪': ['fast_reverse_button'], '⏫': ['fast_up_button'], '⏬': ['fast_down_button'],
    '◀️': ['reverse_button'], '🔼': ['upwards_button'], '🔽': ['downwards_button'], '➡️': ['right_arrow'],
    '⬅️': ['left_arrow'], '⬆️': ['up_arrow'], '⬇️': ['down_arrow'], '↗️': ['up_right_arrow'],
    '↘️': ['down_right_arrow'], '↙️': ['down_left_arrow'], '↖️': ['up_left_arrow'], '↕️': ['up_down_arrow'],
    '↔️': ['left_right_arrow'], '↩️': ['right_arrow_curving_left'], '↪️': ['left_arrow_curving_right'],
    '⤴️': ['right_arrow_curving_up'], '⤵️': ['right_arrow_curving_down'], '🔀': ['shuffle_tracks_button'],
    '🔁': ['repeat_button'], '🔂': ['repeat_single_button'], '🔄': ['counterclockwise_arrows_button'],
    '🔃': ['clockwise_vertical_arrows'], '➕': ['plus'], '➖': ['minus'], '➗': ['divide'], '✖️': ['multiply'],
    '🟰': ['heavy_equals_sign'], '💲': ['heavy_dollar_sign'], '💱': ['currency_exchange'], '〰️': ['wavy_dash'],
    '➰': ['curly_loop'], '➿': ['double_curly_loop'], '🔚': ['end_arrow'], '🔙': ['back_arrow'],
    '🔛': ['on_arrow'], '🔝': ['top_arrow'], '🔜': ['soon_arrow'], '✔️': ['check_mark'],
    '☑️': ['check_box_with_check'], '🔘': ['radio_button'], '🔴': ['red_circle'], '🟠': ['orange_circle'],
    '🟡': ['yellow_circle'], '🟢': ['green_circle'], '🔵': ['blue_circle'], '🟣': ['purple_circle'],
    '⚫': ['black_circle'], '⚪': ['white_circle'], '🟤': ['brown_circle'], '🔺': ['red_triangle_pointed_up'],
    '🔻': ['red_triangle_pointed_down'], '🔸': ['small_orange_diamond'], '🔹': ['small_blue_diamond'],
    '🔶': ['large_orange_diamond'], '🔷': ['large_blue_diamond'], '🔳': ['white_square_button'],
    '🔲': ['black_square_button'], '▪️': ['black_small_square'], '▫️': ['white_small_square'],
    '◾': ['black_medium_small_square'], '◽': ['white_medium_small_square'], '◼️': ['black_medium_square'],
    '◻️': ['white_medium_square'], '🟥': ['red_square'], '🟧': ['orange_square'], '🟨': ['yellow_square'],
    '🟩': ['green_square'], '🟦': ['blue_square'], '🟪': ['purple_square'], '⬛': ['black_large_square'],
    '⬜': ['white_large_square'], '🟫': ['brown_square'], '🎴': ['flower_playing_cards'], '🗜️': ['clamp'],
    '💽': ['computer_disk'], '💾': ['floppy_disk'], '📞': ['telephone_receiver'], '💸': ['money_with_wings'],
    '⚒️': ['hammer_and_pick'], '🚬': ['cigarette'], '📿': ['prayer_beads'], '🪭': ['folding_hand_fan'],
    '🪮': ['hair_pick'], '🍰': ['shortcake'], '🪂': ['parachute'], '🏄': ['person_surfing'],
    '🏊': ['person_swimming'], '🚣': ['person_rowing_boat'], '🚴': ['person_biking'],
    '🚵': ['person_mountain_biking'], '🦯': ['white_cane'], '🦽': ['manual_wheelchair'],
    '🦼': ['motorized_wheelchair'], '🚍': ['oncoming_bus'], '🚘': ['oncoming_automobile'],
    '🚖': ['oncoming_taxi'], '🚡': ['aerial_tramway'], '🚠': ['mountain_cableway'], '🚟': ['suspension_railway'],
    '🚃': ['railway_car'], '🚋': ['tram_car'], '🚈': ['light_rail'], '🚂': ['locomotive'], '🏘️': ['houses'],
    '🏤': ['post_office'], '🗾': ['map_of_japan'], '🏞️': ['national_park'], '🌇': ['sunset_over_buildings'],
    '🏙️': ['cityscape'], '🌁': ['foggy'], '🇧🇪': ['belgium'], '🇦🇹': ['austria'], '🇰🇪': ['kenya'],
    '🇨🇱': ['chile'], '🇨🇴': ['colombia'], '🇵🇪': ['peru'], '🇻🇪': ['venezuela'], '🇲🇾': ['malaysia'],
    '🇵🇰': ['pakistan'], '🇧🇩': ['bangladesh'], '🇨🇿': ['czechia'], '🇭🇺': ['hungary'], '🇷🇴': ['romania'],
    '🇭🇷': ['croatia'], '🇷🇸': ['serbia'], '🇧🇬': ['bulgaria'], '🇸🇰': ['slovakia'], '🇸🇮': ['slovenia'],
    '🇱🇹': ['lithuania'], '🇱🇻': ['latvia'], '🇪🇪': ['estonia'], '🇮🇸': ['iceland'], '🇱🇺': ['luxembourg'],
    '🇲🇹': ['malta'], '🇨🇾': ['cyprus'], '🇹🇹': ['trinidad_and_tobago'], '🇧🇸': ['bahamas'], '🇧🇧': ['barbados'],
    '🇩🇴': ['dominican_republic'], '🇭🇹': ['haiti'], '🇵🇦': ['panama'], '🇨🇷': ['costa_rica'],
    '🇬🇹': ['guatemala'], '🇭🇳': ['honduras'], '🇸🇻': ['el_salvador'], '🇳🇮': ['nicaragua'], '🇧🇴': ['bolivia'],
    '🇪🇨': ['ecuador'], '🇺🇾': ['uruguay'], '🇵🇾': ['paraguay'], '🇬🇾': ['guyana']
};

Object.assign(NYM.prototype, {

    _loadCustomEmojiCache() {
        // Loose shortcode→url map for emoji seen in message tags outside any saved pack.
        this._hydratingEmojiCache = true;
        // finally, so a stuck flag can't disable emoji persistence for the session.
        try {
            try {
                const map = JSON.parse(localStorage.getItem('nym_custom_emojis') || '[]');
                if (Array.isArray(map)) {
                    for (const entry of map) {
                        if (Array.isArray(entry)) this.registerCustomEmoji(entry[0], entry[1]);
                    }
                }
            } catch (_) { }
            try {
                const cached = JSON.parse(localStorage.getItem('nym_custom_emoji_packs') || '[]');
                for (const pack of cached) this._storeEmojiPack(pack, false);
            } catch (_) { }
        } finally {
            this._hydratingEmojiCache = false;
        }
    },

    // Throttled, not debounced, for the same reason as _saveCustomEmojiMap.
    _saveCustomEmojiCache() {
        if (this._hydratingEmojiCache) return;
        if (this._emojiCacheSaveTimer) return;
        this._emojiCacheSaveTimer = setTimeout(() => {
            this._emojiCacheSaveTimer = null;
            const write = () => {
                try {
                    const packs = Array.from(this.customEmojiPacks.values())
                        .sort((a, b) => (b.created_at || 0) - (a.created_at || 0))
                        .slice(0, EMOJI_PACK_CACHE_MAX);
                    localStorage.setItem('nym_custom_emoji_packs', JSON.stringify(packs));
                } catch (err) {
                    if (err && err.name === 'QuotaExceededError') {
                        try {
                            const trimmed = Array.from(this.customEmojiPacks.values())
                                .sort((a, b) => (b.created_at || 0) - (a.created_at || 0))
                                .slice(0, 80);
                            localStorage.setItem('nym_custom_emoji_packs', JSON.stringify(trimmed));
                        } catch (_) { }
                    }
                }
            };
            if (typeof requestIdleCallback === 'function') requestIdleCallback(write, { timeout: 10000 });
            else write();
        }, 2000);
    },

    _prefetchCustomEmojiImages() {
        if (this._emojiPrefetchTimer) return;
        if (this.settings && this.settings.lowDataMode) return;
        this._emojiPrefetchTimer = setTimeout(() => {
            this._emojiPrefetchTimer = null;
            const run = () => this._runEmojiPrefetch();
            if (typeof requestIdleCallback === 'function') requestIdleCallback(run, { timeout: 5000 });
            else run();
        }, 3000);
    },

    // Warm only images likely seen first; everything else loads lazily on open.
    _runEmojiPrefetch() {
        if (!this.customEmojis || this.customEmojis.size === 0) return;
        if (!this._prefetchedEmojiUrls) this._prefetchedEmojiUrls = new Set();
        const urls = [];
        for (const e of (this.recentEmojis || [])) {
            const m = typeof e === 'string' && e.match(/^:([a-zA-Z0-9_]+):$/);
            if (m && this.customEmojis.has(m[1])) urls.push(this.customEmojis.get(m[1]));
        }
        if (this.customEmojiPacks) {
            for (const pack of this.customEmojiPacks.values()) {
                if (!this.isEmojiPackFavorite(pack) && !this.isEmojiPackOwn(pack) &&
                    !this.isEmojiPackSubscribed(pack)) continue;
                for (const e of pack.emojis) {
                    const url = this.customEmojis.get(e.shortcode);
                    if (url) urls.push(url);
                }
            }
        }
        let budget = 60;
        for (const url of urls) {
            if (budget <= 0) break;
            if (this._prefetchedEmojiUrls.has(url)) continue;
            this._prefetchedEmojiUrls.add(url);
            budget--;
            try {
                const img = new Image();
                img.decoding = 'async';
                img.loading = 'eager';
                img.referrerPolicy = 'no-referrer';
                img.src = this.getProxiedEmojiUrl(url);
            } catch (_) { }
        }
    },

    _saveCustomEmojiMap() {
        if (this._hydratingEmojiCache) return;
        if (this._emojiMapSaveTimer) return;
        this._emojiMapSaveTimer = setTimeout(() => {
            this._emojiMapSaveTimer = null;
            try {
                const entries = Array.from(this.customEmojis.entries()).slice(-5000);
                localStorage.setItem('nym_custom_emojis', JSON.stringify(entries));
            } catch (err) {
                if (err && err.name === 'QuotaExceededError') {
                    try {
                        const trimmed = Array.from(this.customEmojis.entries()).slice(-800);
                        localStorage.setItem('nym_custom_emojis', JSON.stringify(trimmed));
                    } catch (_) { }
                }
            }
        }, 2000);
    },

    registerCustomEmoji(shortcode, url) {
        if (!shortcode || !url || !this.customEmojis) return;
        if (!_RX_EMOJI_SHORTCODE.test(shortcode) || !_RX_EMOJI_URL.test(url)) return;
        if (this.emojiMap && this.emojiMap[shortcode.toLowerCase()]) return;
        if (this.customEmojis.get(shortcode) === url) return;
        this.customEmojis.set(shortcode, url);
        // The formatting context snapshots this map; tell it the snapshot moved.
        if (typeof this._invalidateFormatCtx === 'function') this._invalidateFormatCtx();
        if (!this._pendingEmojiRefreshCodes) this._pendingEmojiRefreshCodes = new Set();
        this._pendingEmojiRefreshCodes.add(shortcode);
        this._emojiPickerDirty = true;
        this._saveCustomEmojiMap();
        this._scheduleEmojiDomRefresh();
        this._prefetchCustomEmojiImages();
    },

    // Emoji can register after messages render, so rescan rendered text for newly known shortcodes.
    _scheduleEmojiDomRefresh() {
        if (this._emojiDomRefreshTimer) return;
        this._emojiDomRefreshTimer = setTimeout(() => {
            this._emojiDomRefreshTimer = null;
            this._refreshCustomEmojiInDom();
        }, 300);
    },

    _refreshCustomEmojiInDom() {
        if (!this.customEmojis || this.customEmojis.size === 0) return;
        // Only shortcodes learned since the last refresh need rescanning.
        const pending = this._pendingEmojiRefreshCodes;
        if (!pending || pending.size === 0) return;
        this._pendingEmojiRefreshCodes = new Set();
        const roots = document.querySelectorAll('.message-content, .notification-item-body');
        if (roots.length === 0) return;
        const skip = (node, root) => {
            let p = node.parentNode;
            while (p && p !== root) {
                const tag = p.tagName;
                if (tag === 'A' || tag === 'CODE' || tag === 'PRE') return true;
                if (p.classList && (p.classList.contains('bubble-time') ||
                    p.classList.contains('bubble-time-inner') ||
                    p.classList.contains('message-time'))) return true;
                p = p.parentNode;
            }
            return false;
        };
        for (const root of roots) {
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            const textNodes = [];
            let tn;
            while ((tn = walker.nextNode())) {
                if (tn.nodeValue && tn.nodeValue.indexOf(':') !== -1 && !skip(tn, root)) {
                    textNodes.push(tn);
                }
            }
            for (const node of textNodes) {
                const text = node.nodeValue;
                const matches = [...text.matchAll(/:([a-zA-Z0-9_]+):/g)]
                    .filter(mm => pending.has(mm[1]) && this.customEmojis.has(mm[1]));
                if (matches.length === 0) continue;
                const frag = document.createDocumentFragment();
                let last = 0;
                for (const mm of matches) {
                    if (mm.index > last) {
                        frag.appendChild(document.createTextNode(text.slice(last, mm.index)));
                    }
                    const tmp = document.createElement('span');
                    tmp.innerHTML = this.renderCustomEmojiImg(mm[1]) || '';
                    frag.appendChild(tmp.firstChild || document.createTextNode(mm[0]));
                    last = mm.index + mm[0].length;
                }
                if (last < text.length) {
                    frag.appendChild(document.createTextNode(text.slice(last)));
                }
                if (node.parentNode) node.parentNode.replaceChild(frag, node);
            }
        }
    },

    _emojiD1Meta() {
        try {
            const m = JSON.parse(localStorage.getItem('nym_custom_emoji_d1') || 'null');
            return m && typeof m === 'object' ? m : null;
        } catch (_) { return null; }
    },

    async _emojiRestoreFromD1() {
        if (!this._getApiHost || !this._getApiHost()) return;
        if (typeof this._storageApiStream !== 'function') return;
        const now = Date.now();
        if (this._emojiD1FetchedAt && now - this._emojiD1FetchedAt < 600000) return;
        const held = this.customEmojiPacks && this.customEmojiPacks.size > 0;
        const meta = held ? this._emojiD1Meta() : null;
        if (meta && Number.isFinite(meta.at) && now >= meta.at && now - meta.at < EMOJI_D1_REFRESH_MS) return;
        this._emojiD1FetchedAt = now;
        const etag = meta && typeof meta.etag === 'string' && /^[0-9a-f]{32}$/.test(meta.etag) ? meta.etag : null;
        const events = [];
        let tag = null;
        let same = false;
        try {
            const resp = await this._storageApiStream('emoji-get', etag ? { etag } : {}, false);
            tag = resp.headers.get('X-Etag');
            same = !!etag && resp.headers.get('X-Same') === '1';
            await this._readNdjsonStream(resp, (ev) => events.push(ev));
        } catch (_) {
            this._emojiD1FetchedAt = 0;
            return;
        }
        const packs = events.filter((ev) => ev && ev.kind === 30030).length;
        const keep = typeof tag === 'string' && /^[0-9a-f]{32}$/.test(tag) && (same || packs <= EMOJI_PACK_CACHE_MAX) ? tag : null;
        try { localStorage.setItem('nym_custom_emoji_d1', JSON.stringify({ at: now, etag: keep })); } catch (_) { }
        let sliceStart = Date.now();
        for (let i = 0; i < events.length; i++) {
            if (await this._verifyRelayEventAsync(events[i])) {
                try { await this.handleEvent(events[i]); } catch (_) { }
            }
            if (Date.now() - sliceStart > 10 && i + 1 < events.length && typeof this._yieldToIdle === 'function') {
                await this._yieldToIdle();
                sliceStart = Date.now();
            }
        }
    },

    ingestEmojiTags(tags) {
        if (!Array.isArray(tags)) return;
        for (const t of tags) {
            if (Array.isArray(t) && t[0] === 'emoji' && t[1] && t[2]) {
                this.registerCustomEmoji(t[1], t[2]);
            }
        }
    },

    _emojiPackBlocked(pack) {
        const pk = String((pack && pack.pubkey) || '');
        return !!pk && pk !== this.pubkey && !!this.blockedUsers && this.blockedUsers.has(pk);
    },

    _emojiPackHidden(pack) {
        if (!pack) return true;
        const pk = String(pack.pubkey || '');
        if (pk && pk === this.pubkey) return false;
        if (this._emojiPackBlocked(pack)) return true;
        if ((typeof this.isEmojiPackSubscribed === 'function' && this.isEmojiPackSubscribed(pack))
            || (typeof this.isEmojiPackFavorite === 'function' && this.isEmojiPackFavorite(pack))) return false;
        const title = String(pack.title || pack.identifier || '');
        return !!title && typeof this.hasBlockedKeyword === 'function' && this.hasBlockedKeyword(title, '', pk);
    },

    _emojiRefreshForFilters() {
        this._emojiPickerDirty = true;
        if (!this.customEmojiPacks || !this.customEmojis) return;
        for (const pack of this.customEmojiPacks.values()) {
            if (!pack || !Array.isArray(pack.emojis) || this._emojiPackBlocked(pack)) continue;
            for (const e of pack.emojis) {
                if (e && e.shortcode && !this.customEmojis.has(e.shortcode)) this.registerCustomEmoji(e.shortcode, e.url);
            }
        }
    },

    _storeEmojiPack(pack, persist = true) {
        if (!pack || !pack.pubkey || !Array.isArray(pack.emojis) || pack.emojis.length === 0) return;
        const blocked = this._emojiPackBlocked(pack);
        if (blocked && !this._hydratingEmojiCache) return;
        const key = `${pack.pubkey}:${pack.identifier || ''}`;
        const existing = this.customEmojiPacks.get(key);
        if (existing && (existing.created_at || 0) >= (pack.created_at || 0)) return;
        this.customEmojiPacks.set(key, pack);
        this._emojiPickerDirty = true;
        if (!blocked) for (const e of pack.emojis) this.registerCustomEmoji(e.shortcode, e.url);
        if (persist) this._saveCustomEmojiCache();
        this._prefetchCustomEmojiImages();
    },

    handleEmojiPackEvent(event) {
        if (!event || !Array.isArray(event.tags)) return;
        const dTag = event.tags.find(t => t[0] === 'd');
        const titleTag = event.tags.find(t => t[0] === 'title');
        const emojis = [];
        const seen = new Set();
        for (const t of event.tags) {
            if (t[0] === 'emoji' && t[1] && t[2] &&
                _RX_EMOJI_SHORTCODE.test(t[1]) && _RX_EMOJI_URL.test(t[2]) && !seen.has(t[1])) {
                seen.add(t[1]);
                emojis.push({ shortcode: t[1], url: t[2] });
                if (emojis.length >= 120) break;
            }
        }
        if (emojis.length === 0) return;
        const identifier = dTag ? dTag[1] : '';
        this._storeEmojiPack({
            pubkey: event.pubkey,
            identifier,
            title: (titleTag && titleTag[1]) || identifier || 'Emoji pack',
            created_at: event.created_at || 0,
            emojis
        }, true);
    },

    handleUserEmojiListEvent(event) {
        if (!event || event.pubkey !== this.pubkey || !Array.isArray(event.tags)) return;
        if (this._userEmojiListTs && (event.created_at || 0) < this._userEmojiListTs) return;
        this._userEmojiListTs = event.created_at || 0;
        this.userEmojiPackRefs = new Set();
        this._emojiPickerDirty = true;
        for (const t of event.tags) {
            if (t[0] === 'a' && typeof t[1] === 'string' && t[1].startsWith('30030:')) {
                this.userEmojiPackRefs.add(t[1]);
            } else if (t[0] === 'emoji' && t[1] && t[2]) {
                this.registerCustomEmoji(t[1], t[2]);
            }
        }
    },

    isEmojiPackSubscribed(pack) {
        return !!(this.userEmojiPackRefs &&
            this.userEmojiPackRefs.has(`30030:${pack.pubkey}:${pack.identifier || ''}`));
    },

    isEmojiPackOwn(pack) {
        return !!(pack && this.pubkey && pack.pubkey === this.pubkey);
    },

    customEmojiUrl(shortcode) {
        return this.customEmojis ? this.customEmojis.get(shortcode) : null;
    },

    renderCustomEmojiImg(shortcode, extraClass = '') {
        const url = this.customEmojiUrl(shortcode);
        if (!url) return null;
        const safeUrl = this.escapeHtml(this.getProxiedEmojiUrl(url));
        const safeCode = this.escapeHtml(shortcode);
        const cls = 'custom-emoji' + (extraClass ? ' ' + extraClass : '');
        return `<img class="${cls}" src="${safeUrl}" alt=":${safeCode}:" title=":${safeCode}:" data-emoji-code="${safeCode}" width="30" height="30" decoding="async" loading="lazy" draggable="false">`;
    },

    customEmojiTagsForContent(content, map) {
        const tags = [];
        const emojis = map || this.customEmojis;
        if (!content || !emojis || emojis.size === 0) return tags;
        const seen = new Set();
        const re = /:([a-zA-Z0-9_]+):/g;
        let m;
        while ((m = re.exec(content)) !== null) {
            const code = m[1];
            if (seen.has(code)) continue;
            const url = emojis.get(code);
            if (url) {
                seen.add(code);
                tags.push(['emoji', code, url]);
            }
        }
        return tags;
    },

    customEmojiMapFrom(get) {
        const map = new Map();
        const add = (code, url) => {
            if (!code || !url || typeof code !== 'string' || typeof url !== 'string') return;
            if (!_RX_EMOJI_SHORTCODE.test(code) || !_RX_EMOJI_URL.test(url)) return;
            if (this.emojiMap && this.emojiMap[code.toLowerCase()]) return;
            map.set(code, url);
        };
        try {
            const list = JSON.parse(get('nym_custom_emojis') || '[]');
            if (Array.isArray(list)) for (const e of list) if (Array.isArray(e)) add(e[0], e[1]);
        } catch (_) { }
        try {
            const packs = JSON.parse(get('nym_custom_emoji_packs') || '[]');
            const seen = new Map();
            if (Array.isArray(packs)) {
                for (const p of packs) {
                    if (!p || !p.pubkey || !Array.isArray(p.emojis) || p.emojis.length === 0) continue;
                    const key = `${p.pubkey}:${p.identifier || ''}`;
                    if (seen.has(key) && seen.get(key) >= (p.created_at || 0)) continue;
                    seen.set(key, p.created_at || 0);
                    for (const e of p.emojis) if (e) add(e.shortcode, e.url);
                }
            }
        } catch (_) { }
        return map;
    },

    isCustomEmojiOnly(content) {
        if (!content || !this.customEmojis) return false;
        const tokens = content.trim().split(/\s+/);
        if (tokens.length === 0 || tokens.length > 6) return false;
        return tokens.every(tok => {
            const m = tok.match(/^:([a-zA-Z0-9_]+):$/);
            return m && this.customEmojis.has(m[1]);
        });
    },

    renderReactionEmoji(emoji) {
        if (typeof emoji === 'string') {
            const m = emoji.match(/^:([a-zA-Z0-9_]+):$/);
            if (m) {
                const img = this.renderCustomEmojiImg(m[1], 'custom-emoji-reaction');
                if (img) return img;
            }
        }
        return this.escapeHtml(emoji);
    },

    isValidReactionEmoji(emoji) {
        if (typeof emoji !== 'string' || !emoji || emoji.length > _REACTION_MAX_LENGTH + 2) return false;
        if (_RX_REACTION_SHORTCODE.test(emoji)) return true;
        if (emoji.length > _REACTION_MAX_LENGTH) return false;
        return _REACTION_EXTRA_SYMBOLS.has(emoji) || _RX_REACTION_EMOJI.test(emoji);
    },

    sanitizeRecentEmojis(list) {
        if (!Array.isArray(list)) return [];
        const seen = new Set();
        const out = [];
        for (const e of list) {
            if (!this.isValidReactionEmoji(e) || seen.has(e)) continue;
            seen.add(e);
            out.push(e);
            if (out.length >= 24) break;
        }
        return out;
    },

    emojiOptionHtml(emoji, emojiToNames, btnClass = 'emoji-option') {
        if (typeof emoji === 'string') {
            const m = emoji.match(/^:([a-zA-Z0-9_]+):$/);
            if (m && this.customEmojis && this.customEmojis.has(m[1])) {
                const img = this.renderCustomEmojiImg(m[1]);
                const code = this.escapeHtml(m[1]);
                return `<button class="${btnClass} custom-emoji-option" data-emoji=":${code}:" data-names="${code}" aria-label=":${code}:" data-tip="">${img}</button>`;
            }
        }
        const names = (emojiToNames && Object.prototype.hasOwnProperty.call(emojiToNames, emoji) && Array.isArray(emojiToNames[emoji])) ? emojiToNames[emoji] : [];
        const safe = this.escapeHtml(emoji);
        const label = names.join(', ');
        const named = label ? ` aria-label="${this.escapeHtml(label)}" data-tip=""` : '';
        return `<button class="${btnClass}" data-emoji="${safe}" data-names="${this.escapeHtml(names.join(' '))}"${named}>${safe}</button>`;
    },

    _emojiPackKey(pack) {
        if (!pack || !pack.pubkey) return '';
        return `${pack.pubkey}:${pack.identifier || ''}`;
    },

    _getEmojiPackFavorites() {
        if (!this._emojiPackFavorites) {
            let stored = [];
            try { stored = JSON.parse(localStorage.getItem('nym_emoji_pack_favorites') || '[]'); } catch (_) { }
            this._emojiPackFavorites = Array.isArray(stored) ? stored : [];
        }
        return this._emojiPackFavorites;
    },

    _getDefaultCategoryFavorites() {
        if (!this._defaultCategoryFavorites) {
            let stored = [];
            try { stored = JSON.parse(localStorage.getItem('nym_emoji_category_favorites') || '[]'); } catch (_) { }
            this._defaultCategoryFavorites = Array.isArray(stored) ? stored : [];
        }
        return this._defaultCategoryFavorites;
    },

    isEmojiCategoryFavorite(category) {
        return !!category && this._getDefaultCategoryFavorites().includes(category);
    },

    toggleEmojiCategoryFavorite(category) {
        if (!category) return;
        const favs = this._getDefaultCategoryFavorites();
        const idx = favs.indexOf(category);
        const nowFav = idx === -1;
        if (nowFav) favs.push(category);
        else favs.splice(idx, 1);
        localStorage.setItem('nym_emoji_category_favorites', JSON.stringify(favs));
        this._emojiPickerDirty = true;
        if (typeof nostrSettingsSave === 'function') {
            try { nostrSettingsSave(); } catch (_) { }
        }
        const desiredOrder = this._getOrderedDefaultEmojiEntries().map(([c]) => c);
        const reorderIn = (root) => {
            if (!root) return;
            const sections = Array.from(root.querySelectorAll('.emoji-section, .emoji-picker-section'))
                .filter(el => desiredOrder.includes(el.getAttribute('data-category')));
            if (sections.length < 2) return;
            const parent = sections[0].parentNode;
            const anchor = sections[sections.length - 1].nextSibling;
            desiredOrder.forEach(cat => {
                const el = sections.find(s => s.getAttribute('data-category') === cat);
                if (el) parent.insertBefore(el, anchor);
            });
            root.querySelectorAll('.emoji-category-fav-btn').forEach(btn => {
                const cat = btn.dataset.category;
                const isFav = this.isEmojiCategoryFavorite(cat);
                btn.classList.toggle('active', isFav);
                btn.title = isFav ? 'Unfavorite category' : 'Favorite category';
                btn.setAttribute('aria-label', btn.title);
            });
        };
        reorderIn(this.enhancedEmojiModal);
        reorderIn(document.getElementById('emojiPicker'));
    },

    _getOrderedDefaultEmojiEntries() {
        const favs = this._getDefaultCategoryFavorites();
        const entries = Object.entries(this.allEmojis);
        const favSet = new Set(favs);
        const favored = favs
            .map(cat => entries.find(([c]) => c === cat))
            .filter(Boolean);
        const rest = entries.filter(([c]) => !favSet.has(c));
        return favored.concat(rest);
    },

    _emojiCategoryFavButtonHtml(category) {
        const isFav = this.isEmojiCategoryFavorite(category);
        const label = isFav ? 'Unfavorite category' : 'Favorite category';
        return `<button type="button" class="emoji-category-fav-btn${isFav ? ' active' : ''}" data-action="toggleEmojiCategoryFavorite" data-category="${this.escapeHtml(category)}" title="${label}" aria-label="${label}"><svg viewBox="0 0 24 24" width="14" height="14"><path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg></button>`;
    },

    isEmojiPackFavorite(pack) {
        const key = this._emojiPackKey(pack);
        return !!key && this._getEmojiPackFavorites().includes(key);
    },

    toggleEmojiPackFavorite(key) {
        if (!key) return;
        const favs = this._getEmojiPackFavorites();
        const idx = favs.indexOf(key);
        const nowFav = idx === -1;
        if (nowFav) favs.push(key);
        else favs.splice(idx, 1);
        localStorage.setItem('nym_emoji_pack_favorites', JSON.stringify(favs));
        this._emojiPickerDirty = true;
        if (typeof nostrSettingsSave === 'function') {
            try { nostrSettingsSave(); } catch (_) { }
        }
        if (this.enhancedEmojiModal) {
            this.enhancedEmojiModal.querySelectorAll('.emoji-pack-fav-btn').forEach(btn => {
                if (btn.dataset && btn.dataset.packKey === key) {
                    btn.classList.toggle('active', nowFav);
                    btn.title = nowFav ? 'Unfavorite this pack' : 'Favorite this pack';
                    btn.setAttribute('aria-label', btn.title);
                }
            });
        }
    },

    buildCustomEmojiSectionsHtml(opts = {}) {
        if (!this.customEmojiPacks || this.customEmojiPacks.size === 0) return '';
        const sectionClass = opts.sectionClass || 'emoji-section';
        const titleClass = opts.titleClass || 'emoji-section-title';
        const gridClass = opts.gridClass || 'emoji-grid';
        const btnClass = opts.btnClass || 'emoji-option';

        const rank = (p) => this.isEmojiPackFavorite(p) ? 0
            : this.isEmojiPackOwn(p) ? 1
            : (this.isEmojiPackSubscribed(p) ? 2 : 3);
        const packs = Array.from(this.customEmojiPacks.values()).sort((a, b) => {
            const ra = rank(a);
            const rb = rank(b);
            if (ra !== rb) return ra - rb;
            return (b.created_at || 0) - (a.created_at || 0);
        });

        let html = '';
        let shown = 0;
        for (const pack of packs) {
            if (shown >= 50) break;
            if (this._emojiPackHidden(pack)) continue;
            const emojis = pack.emojis
                .filter(e => this.customEmojis.has(e.shortcode))
                .slice(0, 120);
            if (emojis.length === 0) continue;
            shown++;
            const labelSuffix = (this.isEmojiPackOwn(pack) || this.isEmojiPackSubscribed(pack)) ? ' ★' : '';
            const title = this.escapeHtml(pack.title || 'Emoji pack') + labelSuffix;
            const key = this._emojiPackKey(pack);
            const isFav = this.isEmojiPackFavorite(pack);
            const favBtn = key
                ? `<button type="button" class="emoji-pack-fav-btn${isFav ? ' active' : ''}" data-action="toggleEmojiPackFavorite" data-pack-key="${this.escapeHtml(key)}" title="${isFav ? 'Unfavorite' : 'Favorite'} this pack" aria-label="${isFav ? 'Unfavorite' : 'Favorite'} this pack"><svg viewBox="0 0 24 24" width="14" height="14"><path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg></button>`
                : '';
            html += `<div class="${sectionClass}" data-category="custom">` +
                `<div class="${titleClass} emoji-pack-title">${title}${favBtn}</div><div class="${gridClass}">` +
                emojis.map(e => this.emojiOptionHtml(`:${e.shortcode}:`, null, btnClass)).join('') +
                `</div></div>`;
        }
        return html;
    },

    _getEmojiToNames() {
        if (!this._emojiToNames) {
            const map = {};
            for (const [name, emoji] of Object.entries(this.emojiMap)) {
                (map[emoji] || (map[emoji] = [])).push(name);
            }
            for (const [emoji, names] of Object.entries(_EMOJI_EXTRA_NAMES)) {
                if (!map[emoji]) map[emoji] = names.slice();
            }
            this._emojiToNames = map;
        }
        return this._emojiToNames;
    },

    _emojiSectionsHtml(opts = {}) {
        const sectionClass = opts.sectionClass || 'emoji-section';
        const titleClass = opts.titleClass || 'emoji-section-title';
        const gridClass = opts.gridClass || 'emoji-grid';
        const btnClass = opts.btnClass || 'emoji-option';
        const emojiToNames = this._getEmojiToNames();
        let html = '';
        const recents = this._recentEmojisForPicker();
        if (recents.length > 0) {
            html += `<div class="${sectionClass}" data-category="recent">` +
                `<div class="${titleClass}">Recently Used</div><div class="${gridClass}">` +
                recents.map(e => this.emojiOptionHtml(e, emojiToNames, btnClass)).join('') +
                `</div></div>`;
        }
        html += this.buildCustomEmojiSectionsHtml(opts);
        for (const [category, emojis] of this._getOrderedDefaultEmojiEntries()) {
            html += `<div class="${sectionClass}" data-category="${category}">` +
                `<div class="${titleClass} emoji-default-cat-title">${category.charAt(0).toUpperCase() + category.slice(1)}${this._emojiCategoryFavButtonHtml(category)}</div>` +
                `<div class="${gridClass}">` +
                emojis.map(e => this.emojiOptionHtml(e, emojiToNames, btnClass)).join('') +
                `</div></div>`;
        }
        return html;
    },

    renderCustomEmojiInEscapedText(escapedText) {
        if (!escapedText || !this.customEmojis || this.customEmojis.size === 0) return escapedText;
        return escapedText.replace(/:([a-zA-Z0-9_]+):/g, (match, code) => {
            if (this.customEmojis.has(code)) {
                return this.renderCustomEmojiImg(code) || match;
            }
            return match;
        });
    },

});
