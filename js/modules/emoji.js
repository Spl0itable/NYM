const _RX_EMOJI_SHORTCODE = /^[a-zA-Z0-9_]+$/;
const _RX_EMOJI_URL = /^https?:\/\//i;
const _RX_REACTION_SHORTCODE = /^:[a-zA-Z0-9_]{1,64}:$/;
const _RX_REACTION_EMOJI = new RegExp('^(?:(?:[\\u{1F1E0}-\\u{1F1FF}]{2})|(?:[#*0-9]\\u{FE0F}?\\u{20E3})|(?:(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?(?:\\u{200D}(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?)*)(?:[\\u{E0020}-\\u{E007E}]+\\u{E007F})?)$', 'u');
const _REACTION_MAX_LENGTH = 64;
const _REACTION_EXTRA_SYMBOLS = new Set(['\u20BF', '+', '-']);
const EMOJI_D1_REFRESH_MS = 6 * 60 * 60 * 1000;
const EMOJI_PACK_CACHE_MAX = 200;
const EMOJI_PINNED_MAX = 120;
const EMOJI_USED_MAX = 40;
const EMOJI_PAGE_WALK = 5;
const EMOJI_COORDS_CHUNK = 12;
const _RX_EMOJI_COORD = /^30030:[0-9a-f]{64}:[^\u0000-\u001f\u007f]{0,1024}$/;
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
                        if (!Array.isArray(entry)) continue;
                        this.registerCustomEmoji(entry[0], entry[1]);
                        if (entry[2] === 1 && this.customEmojis.get(entry[0]) === entry[1]) this._taggedEmojiSet().add(entry[0]);
                    }
                }
            } catch (_) { }
            try {
                const pinned = JSON.parse(localStorage.getItem('nym_custom_emoji_pinned') || '[]');
                if (Array.isArray(pinned)) for (const pack of pinned) this._storeEmojiPack(pack, false);
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
                const pinned = [];
                const kept = new Set();
                for (const key of this._emojiPinnedKeys()) {
                    if (pinned.length >= EMOJI_PINNED_MAX) break;
                    const pack = this.customEmojiPacks.get(key);
                    if (pack) { pinned.push(pack); kept.add(key); }
                }
                const rest = [];
                for (const [key, pack] of this.customEmojiPacks.entries()) if (!kept.has(key)) rest.push(pack);
                rest.sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
                try { localStorage.setItem('nym_custom_emoji_pinned', JSON.stringify(pinned)); } catch (_) { }
                try {
                    localStorage.setItem('nym_custom_emoji_packs', JSON.stringify(rest.slice(0, EMOJI_PACK_CACHE_MAX)));
                } catch (err) {
                    if (err && err.name === 'QuotaExceededError') {
                        try {
                            localStorage.setItem('nym_custom_emoji_packs', JSON.stringify(rest.slice(0, 80)));
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
                const entries = this._customEmojiSaveEntries().slice(-5000);
                localStorage.setItem('nym_custom_emojis', JSON.stringify(entries));
            } catch (err) {
                if (err && err.name === 'QuotaExceededError') {
                    try {
                        const trimmed = this._customEmojiSaveEntries().slice(-800);
                        localStorage.setItem('nym_custom_emojis', JSON.stringify(trimmed));
                    } catch (_) { }
                }
            }
        }, 2000);
    },

    _taggedEmojiSet() {
        if (!this._taggedEmoji) this._taggedEmoji = new Set();
        return this._taggedEmoji;
    },

    _customEmojiSaveEntries() {
        const tagged = this._taggedEmoji || new Set();
        const plain = [];
        const kept = [];
        for (const [code, url] of this.customEmojis.entries()) {
            if (tagged.has(code)) kept.push([code, url, 1]);
            else plain.push([code, url]);
        }
        return plain.concat(kept);
    },

    _markTaggedEmoji(code, url) {
        if (!this.customEmojis || this.customEmojis.get(code) !== url) return;
        const set = this._taggedEmojiSet();
        if (set.has(code)) return;
        set.add(code);
        if (set.size > 4000) set.delete(set.values().next().value);
        this._saveCustomEmojiMap();
    },

    noteMissingCustomEmoji(code) {
        if (typeof code !== 'string' || !_RX_EMOJI_SHORTCODE.test(code) || !/[a-zA-Z_]/.test(code)) return;
        if (this.emojiMap && this.emojiMap[code.toLowerCase()]) return;
        if (!this.customEmojis || this.customEmojis.has(code)) return;
        if (!this._emojiAsked) this._emojiAsked = new Set();
        if (this._emojiAsked.has(code) || this._emojiAsked.size >= 2000) return;
        this._emojiAsked.add(code);
        this._emojiAskPending = true;
        if (this._emojiAskTimer) return;
        const wait = Math.max(400, (this._emojiAskAt || 0) + 60000 - Date.now());
        this._emojiAskTimer = setTimeout(() => {
            this._emojiAskTimer = null;
            if (!this._emojiAskPending) return;
            this._emojiAskPending = false;
            this._emojiAskAt = Date.now();
            Promise.resolve(this._emojiRestoreFromD1({ force: true })).catch(() => { }).then(() => this._emojiAskAgain());
        }, wait);
    },

    _emojiAskAgain() {
        if (!this._emojiPageCursor || !this._emojiAsked || !this.customEmojis) return;
        for (const code of this._emojiAsked) {
            if (this.customEmojis.has(code)) continue;
            this._emojiAsked.delete(code);
            this.noteMissingCustomEmoji(code);
            return;
        }
    },

    noteMissingCustomEmojiIn(content) {
        if (typeof content !== 'string' || content.indexOf(':') === -1) return;
        for (const m of content.matchAll(/:([a-zA-Z0-9_]+):/g)) this.noteMissingCustomEmoji(m[1]);
    },

    registerCustomEmoji(shortcode, url) {
        if (!shortcode || !url || !this.customEmojis) return;
        if (!_RX_EMOJI_SHORTCODE.test(shortcode) || !_RX_EMOJI_URL.test(url)) return;
        if (this.emojiMap && this.emojiMap[shortcode.toLowerCase()]) return;
        if (this.customEmojis.get(shortcode) === url) return;
        this.customEmojis.set(shortcode, url);
        this._emojiBlockCodes = null;
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
        const roots = document.querySelectorAll('.message-content, .notification-item-body, .reaction-badge');
        if (roots.length === 0) return;
        const blockedCodes = this._blockedEmojiCodes();
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
            const extra = root.classList && root.classList.contains('reaction-badge') ? 'custom-emoji-reaction' : '';
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
                    if (blockedCodes.has(mm[1])) {
                        last = mm.index + mm[0].length;
                        continue;
                    }
                    const tmp = document.createElement('span');
                    tmp.innerHTML = this.renderCustomEmojiImg(mm[1], extra, !extra) || '';
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

    async _emojiApplyEvents(events) {
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

    async _emojiStorageRead(action, payload, opts) {
        const events = [];
        const resp = await this._storageApiStream(action, payload, false, opts);
        await this._readNdjsonStream(resp, (ev) => events.push(ev));
        return { events, etag: resp.headers.get('X-Etag'), same: resp.headers.get('X-Same') === '1', next: resp.headers.get('X-Next') || '' };
    },

    _emojiCoordOfKey(key) {
        const i = typeof key === 'string' ? key.indexOf(':') : -1;
        return i === 64 ? `30030:${key}` : '';
    },

    _emojiUsedKeys() {
        if (!this._emojiUsed) {
            let stored = [];
            try { stored = JSON.parse(localStorage.getItem('nym_emoji_packs_used') || '[]'); } catch (_) { }
            this._emojiUsed = Array.isArray(stored) ? stored.filter((k) => typeof k === 'string').slice(-EMOJI_USED_MAX) : [];
        }
        return this._emojiUsed;
    },

    _noteEmojiPackUsed(key) {
        if (!key) return;
        const used = this._emojiUsedKeys();
        const at = used.indexOf(key);
        if (at === used.length - 1 && at !== -1) return;
        if (at !== -1) used.splice(at, 1);
        used.push(key);
        while (used.length > EMOJI_USED_MAX) used.shift();
        try { localStorage.setItem('nym_emoji_packs_used', JSON.stringify(used)); } catch (_) { }
        this._emojiPickerDirty = true;
        this._saveCustomEmojiCache();
    },

    isEmojiPackUsed(pack) {
        const key = this._emojiPackKey(pack);
        return !!key && this._emojiUsedKeys().includes(key);
    },

    _emojiPinnedKeys() {
        const keys = new Set();
        for (const k of this._getEmojiPackFavorites()) if (typeof k === 'string') keys.add(k);
        if (this.pubkey && this.customEmojiPacks) {
            for (const [k, p] of this.customEmojiPacks.entries()) if (p && p.pubkey === this.pubkey) keys.add(k);
        }
        if (this.userEmojiPackRefs) for (const ref of this.userEmojiPackRefs) keys.add(String(ref).slice(6));
        for (const k of this._emojiUsedKeys().slice().reverse()) keys.add(k);
        return keys;
    },

    _emojiOwnPubkeys() {
        const out = new Set();
        if (this.pubkey) out.add(this.pubkey);
        try {
            const api = typeof window !== 'undefined' ? window.NymAccounts : null;
            const idx = api && typeof api.read === 'function' ? api.read() : null;
            if (idx && Array.isArray(idx.accounts)) for (const a of idx.accounts) if (a && typeof a.pubkey === 'string' && a.pubkey) out.add(a.pubkey);
        } catch (_) { }
        return out;
    },

    _emojiWantedCoords() {
        const out = [];
        const seen = new Set();
        const blocked = this._globalEmojiPackSet();
        const add = (coord) => {
            if (!_RX_EMOJI_COORD.test(coord) || seen.has(coord) || blocked.has(coord)) return;
            seen.add(coord);
            if (this.customEmojiPacks && this.customEmojiPacks.has(coord.slice(6))) return;
            if (this._emojiCoordsTried && this._emojiCoordsTried.has(coord)) return;
            out.push(coord);
        };
        for (const k of this._emojiPinnedKeys()) add(this._emojiCoordOfKey(k));
        if (this._emojiWanted) for (const c of this._emojiWanted) add(c);
        return out;
    },

    requestEmojiPack(coord) {
        if (!_RX_EMOJI_COORD.test(coord || '')) return;
        if (this._globalEmojiPackSet().has(coord)) return;
        if (this.customEmojiPacks && this.customEmojiPacks.has(coord.slice(6))) return;
        if (!this._emojiWanted) this._emojiWanted = new Set();
        if (this._emojiWanted.size >= 500) return;
        this._emojiWanted.add(coord);
        this._scheduleEmojiCoordFetch();
    },

    _scheduleEmojiCoordFetch() {
        if (this._emojiCoordTimer) return;
        this._emojiCoordTimer = setTimeout(() => {
            this._emojiCoordTimer = null;
            Promise.resolve(this._emojiFetchCoords()).catch(() => { });
        }, 300);
    },

    async _emojiFetchCoords() {
        if (!this._getApiHost || !this._getApiHost()) return;
        if (typeof this._storageApiStream !== 'function') return;
        if (this._emojiCoordsBusy) { this._emojiCoordsAgain = true; return; }
        this._emojiCoordsBusy = true;
        try {
            if (!this._emojiCoordsTried) this._emojiCoordsTried = new Set();
            const wanted = this._emojiWantedCoords();
            for (let i = 0; i < wanted.length; i += EMOJI_COORDS_CHUNK) {
                const chunk = wanted.slice(i, i + EMOJI_COORDS_CHUNK);
                let got;
                try { got = await this._emojiStorageRead('emoji-coords', { coords: chunk }); } catch (_) { break; }
                for (const c of chunk) {
                    this._emojiCoordsTried.add(c);
                    if (this._emojiWanted) this._emojiWanted.delete(c);
                }
                await this._emojiApplyEvents(got.events);
            }
        } finally {
            this._emojiCoordsBusy = false;
        }
        if (this._emojiCoordsAgain) {
            this._emojiCoordsAgain = false;
            this._scheduleEmojiCoordFetch();
        }
    },

    async _emojiRestoreFromD1(opts) {
        if (!this._getApiHost || !this._getApiHost()) return;
        if (typeof this._storageApiStream !== 'function') return;
        const force = !!(opts && opts.force);
        const now = Date.now();
        const via = force ? { noIdentity: true } : undefined;
        if (!force) {
            try { await this._emojiFetchCoords(); } catch (_) { }
        }
        if (force && this._emojiPageCursor) {
            const cursor = this._emojiPageCursor;
            this._emojiPageCursor = '';
            try {
                const more = await this._emojiStorageRead('emoji-page', { cursor }, via);
                this._emojiPageCursor = more.next;
                this._emojiCursorFails = 0;
                await this._emojiApplyEvents(more.events);
            } catch (_) {
                this._emojiCursorFails = (this._emojiCursorFails || 0) + 1;
                this._emojiPageCursor = this._emojiCursorFails < 3 ? cursor : '';
                if (!this._emojiPageCursor) this._emojiCursorFails = 0;
            }
            return;
        }
        if (!force && this._emojiD1FetchedAt && now - this._emojiD1FetchedAt < 600000) return;
        const pinned = this._emojiPinnedKeys();
        const held = !force && !!this.customEmojiPacks && Array.from(this.customEmojiPacks.keys()).some((k) => !pinned.has(k));
        const meta = held ? this._emojiD1Meta() : null;
        if (meta && Number.isFinite(meta.at) && now >= meta.at && now - meta.at < EMOJI_D1_REFRESH_MS) return;
        this._emojiD1FetchedAt = now;
        const etag = meta && typeof meta.etag === 'string' && /^[0-9a-f]{32}$/.test(meta.etag) ? meta.etag : null;
        let head;
        try {
            head = await this._emojiStorageRead('emoji-page', etag ? { etag } : {}, via);
        } catch (_) {
            this._emojiD1FetchedAt = 0;
            return;
        }
        const same = !!etag && head.same;
        const tag = typeof head.etag === 'string' && /^[0-9a-f]{32}$/.test(head.etag) ? head.etag : null;
        let packs = head.events.filter((ev) => ev && ev.kind === 30030).length;
        await this._emojiApplyEvents(head.events);
        this._emojiPageCursor = head.next;
        for (let page = 1; !same && !force && page < EMOJI_PAGE_WALK && this._emojiPageCursor; page++) {
            const cursor = this._emojiPageCursor;
            let more;
            try { more = await this._emojiStorageRead('emoji-page', { cursor }); } catch (_) { break; }
            this._emojiPageCursor = more.next;
            packs += more.events.filter((ev) => ev && ev.kind === 30030).length;
            await this._emojiApplyEvents(more.events);
        }
        const keep = tag && (same || packs <= EMOJI_PACK_CACHE_MAX) ? tag : null;
        try { localStorage.setItem('nym_custom_emoji_d1', JSON.stringify({ at: now, etag: keep })); } catch (_) { }
    },

    ingestEmojiTags(tags, opts) {
        if (!Array.isArray(tags)) return;
        const anon = !!(opts && opts.anon);
        for (const t of tags) {
            if (!Array.isArray(t) || t[0] !== 'emoji' || !t[1]) continue;
            if (t[2]) {
                this.registerCustomEmoji(t[1], t[2]);
                this._markTaggedEmoji(t[1], t[2]);
            }
            if (typeof t[3] === 'string' && t[2]) this._learnBlockedEmojiTag(t);
            if (!anon && typeof t[3] === 'string' && (!this.customEmojis || !this.customEmojis.has(t[1]))) this.requestEmojiPack(t[3]);
        }
    },

    _emojiPackBlocked(pack) {
        const pk = String((pack && pack.pubkey) || '');
        return !!pk && pk !== this.pubkey && !!this.blockedUsers && this.blockedUsers.has(pk);
    },

    _emojiPackHidden(pack) {
        if (!pack) return true;
        if (this.isEmojiPackBlocked(pack)) return true;
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
            if (!pack || !Array.isArray(pack.emojis) || this._emojiPackBlocked(pack) || this.isEmojiPackBlocked(pack)) continue;
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
        this._emojiCodePack = null;
        const packBlocked = this.isEmojiPackBlocked(pack);
        if (packBlocked) {
            this._emojiBlockChanged();
            this._repointBlockedEmojiCodes();
            this._scheduleEmojiBlockSweep();
        }
        this._emojiPickerDirty = true;
        if (!blocked && !packBlocked) for (const e of pack.emojis) this.registerCustomEmoji(e.shortcode, e.url);
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
        this._saveCustomEmojiCache();
        this._scheduleEmojiCoordFetch();
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

    renderCustomEmojiImg(shortcode, extraClass = '', tip = true) {
        const url = this.customEmojiUrl(shortcode);
        if (!url) return null;
        if (this.isCustomEmojiBlocked(shortcode)) return '';
        const safeUrl = this.escapeHtml(this.getProxiedEmojiUrl(url));
        const safeCode = this.escapeHtml(shortcode);
        const cls = 'custom-emoji' + (extraClass ? ' ' + extraClass : '');
        const tipAttrs = tip ? ` data-tip="" data-tip-raw=":${safeCode}:"` : '';
        return `<img class="${cls}" src="${safeUrl}" alt=":${safeCode}:"${tipAttrs} data-emoji-code="${safeCode}" width="30" height="30" decoding="async" loading="lazy" draggable="false">`;
    },

    customEmojiTagsForContent(content, map, opts) {
        const tags = [];
        const anon = !!(opts && opts.anon);
        const emojis = map || this.customEmojis;
        if (!content || !emojis || emojis.size === 0) return tags;
        const seen = new Set();
        const re = /:([a-zA-Z0-9_]+):/g;
        let m;
        while ((m = re.exec(content)) !== null) {
            const code = m[1];
            if (seen.has(code)) continue;
            const url = emojis.get(code);
            if (url && this._emojiUrlBlocked(url)) {
                seen.add(code);
                continue;
            }
            if (url) {
                seen.add(code);
                const packKey = map || anon ? '' : this._emojiPackKeyFor(code, url);
                if (packKey) {
                    tags.push(['emoji', code, url, `30030:${packKey}`]);
                    this._noteEmojiPackUsed(packKey);
                } else {
                    tags.push(['emoji', code, url]);
                }
            }
        }
        return tags;
    },

    _emojiPackKeyFor(code, url) {
        if (!this.customEmojiPacks) return '';
        if (!this._emojiCodePack) {
            const idx = new Map();
            const pinned = this._emojiPinnedKeys();
            const own = this._emojiOwnPubkeys();
            for (const [key, pack] of this.customEmojiPacks.entries()) {
                if (!pack || !Array.isArray(pack.emojis) || own.has(pack.pubkey)) continue;
                for (const e of pack.emojis) {
                    const k = `${e.shortcode}\n${e.url}`;
                    if (!idx.has(k) || pinned.has(key)) idx.set(k, key);
                }
            }
            this._emojiCodePack = idx;
        }
        return this._emojiCodePack.get(`${code}\n${url}`) || '';
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
            const packs = JSON.parse(get('nym_custom_emoji_packs') || '[]').concat(JSON.parse(get('nym_custom_emoji_pinned') || '[]'));
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
            return m && this.customEmojis.has(m[1]) && !this.isCustomEmojiBlocked(m[1]);
        });
    },

    renderReactionEmoji(emoji, tip = true) {
        if (typeof emoji === 'string') {
            const m = emoji.match(/^:([a-zA-Z0-9_]+):$/);
            if (m) {
                if (this.isCustomEmojiBlocked(m[1])) return '';
                const img = this.renderCustomEmojiImg(m[1], 'custom-emoji-reaction', tip);
                if (img) return img;
                this.noteMissingCustomEmoji(m[1]);
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
            if (m && this.isCustomEmojiBlocked(m[1])) return '';
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
        this._saveCustomEmojiCache();
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
            : this.isEmojiPackSubscribed(p) ? 2
            : (this.isEmojiPackUsed(p) ? 3 : 4);
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
                .filter(e => this.customEmojis.has(e.shortcode) && !this._emojiUrlBlocked(e.url) && !this.isCustomEmojiBlocked(e.shortcode))
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
            const blockBtn = key && !this.isEmojiPackOwn(pack) ? this._emojiPackBlockButtonHtml(key) : '';
            const actions = blockBtn ? `<span class="emoji-pack-actions">${favBtn}${blockBtn}</span>` : favBtn;
            html += `<div class="${sectionClass}" data-category="custom" data-pack-key="${this.escapeHtml(key)}">` +
                `<div class="${titleClass} emoji-pack-title">${title}${actions}</div><div class="${gridClass}">` +
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
            if (this.isCustomEmojiBlocked(code)) return '';
            if (this.customEmojis.has(code)) {
                return this.renderCustomEmojiImg(code) || match;
            }
            return match;
        });
    },

    _eb() {
        const g = typeof window !== 'undefined' ? window : (typeof self !== 'undefined' ? self : null);
        return g && g.NymEmojiBlock ? g.NymEmojiBlock : null;
    },

    _ebText(text, args) {
        if (typeof this.uiText === 'function') return this.uiText(text, args);
        return String(text).replace(/\{(\w+)\}/g, (m, k) => (args && args[k] != null ? String(args[k]) : m));
    },

    _blockedEmojiPackList() {
        if (!this._emojiBlockList) {
            const B = this._eb();
            let stored = [];
            try { stored = JSON.parse(localStorage.getItem('nym_blocked_emoji_packs') || '[]'); } catch (_) { }
            this._emojiBlockList = B ? B.normalize(stored) : [];
        }
        return this._emojiBlockList;
    },

    _globalEmojiPackList() {
        if (!this._emojiGlobalList) {
            const B = this._eb();
            let stored = null;
            try { stored = JSON.parse(localStorage.getItem(B ? B.GLOBAL_KEY : 'nym_global_emoji_blocks') || 'null'); } catch (_) { }
            this._emojiGlobalList = (B && B.globalList(stored)) || [];
        }
        return this._emojiGlobalList;
    },

    _globalEmojiUrlList() {
        if (!this._emojiGlobalUrls) {
            const B = this._eb();
            let stored = null;
            try { stored = JSON.parse(localStorage.getItem(B ? B.GLOBAL_URL_KEY : 'nym_global_emoji_block_urls') || 'null'); } catch (_) { }
            this._emojiGlobalUrls = (B && B.globalUrls(stored)) || [];
        }
        return this._emojiGlobalUrls;
    },

    _globalEmojiPackSet() {
        const list = this._globalEmojiPackList();
        if (this._emojiGlobalSetOf !== list) {
            this._emojiGlobalSet = new Set(list);
            this._emojiGlobalSetOf = list;
        }
        return this._emojiGlobalSet;
    },

    _setGlobalEmojiBlocks(ep, epu) {
        const B = this._eb();
        const next = B ? B.globalList(ep) : null;
        if (!next) return false;
        const prev = this._globalEmojiPackList();
        const prevUrls = this._globalEmojiUrlList();
        const nextUrls = next.length ? (B.globalUrls(epu) || prevUrls) : [];
        if (JSON.stringify(prev) === JSON.stringify(next) && JSON.stringify(prevUrls) === JSON.stringify(nextUrls)) return false;
        this._emojiGlobalList = next;
        this._emojiGlobalUrls = nextUrls;
        try { localStorage.setItem(B.GLOBAL_KEY, JSON.stringify(next)); } catch (_) { }
        try { localStorage.setItem(B.GLOBAL_URL_KEY, JSON.stringify(nextUrls)); } catch (_) { }
        this._emojiBlockChanged();
        this._repointBlockedEmojiCodes();
        const kept = new Set(next);
        for (const coord of prev) {
            if (kept.has(coord)) continue;
            const pack = this.customEmojiPacks && this.customEmojiPacks.get(coord.slice(6));
            if (!pack || !Array.isArray(pack.emojis) || this.isEmojiPackBlocked(pack) || this._emojiPackBlocked(pack)) continue;
            for (const e of pack.emojis) if (e && !this.customEmojis.has(e.shortcode)) this.registerCustomEmoji(e.shortcode, e.url);
        }
        this._applyEmojiBlocksToDom();
        return true;
    },

    _emojiBlockState() {
        if (!this._emojiBlockSt) {
            const B = this._eb();
            const list = this._blockedEmojiPackList();
            const global = this._globalEmojiPackList();
            const gurls = this._globalEmojiUrlList();
            const st = B && (list.length || global.length || gurls.length)
                ? B.state(list, this.customEmojiPacks ? this.customEmojiPacks.values() : [], global, gurls)
                : { coords: new Set(), urls: new Set() };
            if (B && st.coords.size && this._emojiTagCoords) {
                const tags = [];
                for (const k of this._emojiTagCoords) {
                    const i = k.indexOf('\n');
                    tags.push(['emoji', '', k.slice(0, i), k.slice(i + 1)]);
                }
                B.learnTags(tags, st);
            }
            this._emojiBlockSt = st;
        }
        return this._emojiBlockSt;
    },

    _emojiBlockChanged() {
        this._emojiBlockSt = null;
        this._emojiBlockCodes = null;
        this._emojiPickerDirty = true;
        this._emojiCodePack = null;
        if (typeof this._invalidateFormatCtx === 'function') this._invalidateFormatCtx();
    },

    _learnBlockedEmojiTag(t) {
        const B = this._eb();
        if (!B || !B.validCoord(t[3]) || typeof t[2] !== 'string') return;
        if (!this._emojiTagCoords) this._emojiTagCoords = new Set();
        const set = this._emojiTagCoords;
        const k = `${t[2]}\n${t[3]}`;
        if (set.has(k)) return;
        if (set.size >= B.MAX_LEARNED) set.delete(set.values().next().value);
        set.add(k);
        const st = this._emojiBlockState();
        if (st.coords.has(t[3]) && B.learnTags([t], st) > 0) {
            this._emojiBlockCodes = null;
            this._emojiPickerDirty = true;
            if (typeof this._invalidateFormatCtx === 'function') this._invalidateFormatCtx();
            this._scheduleEmojiBlockSweep();
        }
    },

    _scheduleEmojiBlockSweep() {
        if (this._emojiBlockSweepT) return;
        this._emojiBlockSweepT = setTimeout(() => {
            this._emojiBlockSweepT = null;
            this._applyEmojiBlocksToDom();
        }, 100);
    },

    _repointBlockedEmojiCodes() {
        if (!this.customEmojiPacks || !this.customEmojis) return;
        const st = this._emojiBlockState();
        if (!st.urls.size) return;
        for (const pack of this.customEmojiPacks.values()) {
            if (!pack || !Array.isArray(pack.emojis) || this._emojiPackBlocked(pack) || this.isEmojiPackBlocked(pack)) continue;
            for (const e of pack.emojis) {
                if (!e || !e.shortcode || !e.url || st.urls.has(e.url)) continue;
                const cur = this.customEmojis.get(e.shortcode);
                if (cur && st.urls.has(cur)) this.registerCustomEmoji(e.shortcode, e.url);
            }
        }
    },

    isEmojiPackBlocked(pack) {
        const key = this._emojiPackKey(pack);
        return !!key && this._emojiBlockState().coords.has(`30030:${key}`);
    },

    _emojiUrlBlocked(url) {
        return !!url && this._emojiBlockState().urls.has(url);
    },

    isCustomEmojiBlocked(code) {
        if (!code || !this.customEmojis) return false;
        const st = this._emojiBlockState();
        if (st.urls.size === 0) return false;
        const url = this.customEmojis.get(code);
        return !!url && st.urls.has(url);
    },

    _blockedEmojiCodes() {
        if (!this._emojiBlockCodes) {
            const out = new Set();
            const st = this._emojiBlockState();
            if (st.urls.size && this.customEmojis) {
                for (const [code, url] of this.customEmojis) if (st.urls.has(url)) out.add(code);
            }
            this._emojiBlockCodes = out;
        }
        return this._emojiBlockCodes;
    },

    _emojiStringBlocked(emoji) {
        if (typeof emoji !== 'string') return false;
        const m = emoji.match(/^:([a-zA-Z0-9_]+):$/);
        return !!m && this.isCustomEmojiBlocked(m[1]);
    },

    stripBlockedEmoji(text) {
        const B = this._eb();
        if (!B || typeof text !== 'string' || this._emojiBlockState().urls.size === 0) return text;
        return B.strip(text, (code) => this.isCustomEmojiBlocked(code));
    },

    _emojiPackBlockButtonHtml(key) {
        const label = this.escapeHtml(this._ebText('Block this pack'));
        return `<button type="button" class="emoji-pack-block-btn" data-action="blockEmojiPack" data-pack-key="${this.escapeHtml(key)}" title="${label}" aria-label="${label}"><svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><circle cx="12" cy="12" r="9"/><line x1="5.6" y1="5.6" x2="18.4" y2="18.4"/></svg></button>`;
    },

    async blockEmojiPack(key) {
        const pack = this.customEmojiPacks && this.customEmojiPacks.get(key);
        const B = this._eb();
        if (!pack || !B || this.isEmojiPackOwn(pack) || !B.packCoord(pack)) return false;
        const ask = typeof window !== 'undefined' && typeof window.showAppConfirm === 'function' ? window.showAppConfirm : null;
        if (!ask) return false;
        const res = await ask(this._ebText('Emoji from this pack will be hidden everywhere: the emoji picker, autocomplete, reactions and messages. You can unblock it in Settings.'), {
            title: this._ebText('Block emoji pack?'),
            okLabel: this._ebText('Block'),
            danger: true,
            checkboxLabel: this._ebText('Also report this pack')
        });
        if (!res || !res.confirmed) return false;
        this._blockEmojiPackNow(pack);
        if (res.checked) this.openEmojiPackReport(pack);
        return true;
    },

    _blockEmojiPackNow(pack) {
        const B = this._eb();
        const entry = B && B.entryFor(pack, Math.floor(Date.now() / 1000));
        if (!entry) return false;
        const key = this._emojiPackKey(pack);
        const favs = this._getEmojiPackFavorites();
        const fi = favs.indexOf(key);
        if (fi !== -1) {
            favs.splice(fi, 1);
            try { localStorage.setItem('nym_emoji_pack_favorites', JSON.stringify(favs)); } catch (_) { }
        }
        this._setBlockedEmojiPacks(B.add(this._blockedEmojiPackList(), entry));
        return true;
    },

    openEmojiPackReport(pack) {
        const B = this._eb();
        const coord = B ? B.packCoord(pack) : '';
        if (!coord || typeof this.openReportModal !== 'function') return;
        this.openReportModal({ kind: 'emojiPack', coord, name: String(pack.title || pack.identifier || ''), author: B.authorOf(coord) });
    },

    unblockEmojiPack(coord) {
        const B = this._eb();
        if (!B) return;
        this._setBlockedEmojiPacks(B.remove(this._blockedEmojiPackList(), coord));
        const pack = this.customEmojiPacks && this.customEmojiPacks.get(String(coord || '').slice(6));
        if (pack && Array.isArray(pack.emojis)) {
            for (const e of pack.emojis) if (e && !this.customEmojis.has(e.shortcode)) this.registerCustomEmoji(e.shortcode, e.url);
        }
    },

    unblockEmojiPackFromSettings(coord) {
        this.unblockEmojiPack(coord);
    },

    _setBlockedEmojiPacks(list, opts) {
        const B = this._eb();
        const norm = B ? B.normalize(list) : [];
        this._emojiBlockList = norm;
        try { localStorage.setItem('nym_blocked_emoji_packs', JSON.stringify(norm)); } catch (_) { }
        this._emojiBlockChanged();
        this._repointBlockedEmojiCodes();
        if (!(opts && opts.anon)) {
            for (const e of norm) if (this.customEmojiPacks && !this.customEmojiPacks.has(e.coord.slice(6))) this.requestEmojiPack(e.coord);
        }
        this._applyEmojiBlocksToDom();
        this.updateBlockedEmojiPacksList();
        if (!(opts && opts.remote)) {
            this._saveCustomEmojiCache();
            if (typeof nostrSettingsSave === 'function') {
                try { nostrSettingsSave(); } catch (_) { }
            }
        }
    },

    _applySyncedEmojiBlocks(list) {
        if (!Array.isArray(list)) return;
        const B = this._eb();
        const next = B ? B.normalize(list) : [];
        if (JSON.stringify(next) === JSON.stringify(this._blockedEmojiPackList())) return;
        this._setBlockedEmojiPacks(next, { remote: true });
    },

    _emojiBlockSyncPayload() {
        return this._blockedEmojiPackList().map((e) => ({ coord: e.coord, name: e.name, sample: e.sample.map((s) => ({ shortcode: s.shortcode, url: s.url })), at: e.at }));
    },

    _applyEmojiBlocksToDom() {
        if (typeof document === 'undefined' || typeof document.querySelectorAll !== 'function') return;
        document.querySelectorAll('[data-category="custom"][data-pack-key]').forEach((el) => {
            const key = el.getAttribute('data-pack-key') || '';
            if (key && this._emojiBlockState().coords.has(`30030:${key}`)) el.remove();
        });
        const codes = this._blockedEmojiCodes();
        if (codes.size) {
            document.querySelectorAll('.custom-emoji-option, .quick-react-emoji, .msg-sheet-emoji').forEach((el) => {
                const m = String(el.getAttribute('data-emoji') || '').match(/^:([a-zA-Z0-9_]+):$/);
                if (m && codes.has(m[1])) el.remove();
            });
            document.querySelectorAll('img.custom-emoji').forEach((img) => {
                const code = img.getAttribute('data-emoji-code');
                if (code && codes.has(code)) img.remove();
            });
        }
        if (typeof this._refreshVisibleReactions === 'function') this._refreshVisibleReactions();
    },

    _emojiPackAuthorLabel(pk) {
        const name = typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(pk) : '';
        return name || `${String(pk).slice(0, 8)}…`;
    },

    updateBlockedEmojiPacksList() {
        const el = typeof document !== 'undefined' && typeof document.getElementById === 'function' ? document.getElementById('blockedEmojiPacksList') : null;
        if (!el) return;
        const list = this._blockedEmojiPackList();
        if (!list.length) {
            el.innerHTML = `<div class="nm-dim12">${this.escapeHtml(this._ebText('No blocked emoji packs'))}</div>`;
            return;
        }
        const proxied = (u) => (typeof this.getProxiedEmojiUrl === 'function' ? this.getProxiedEmojiUrl(u) : u);
        const unblock = this.escapeHtml(this._ebText('Unblock'));
        el.innerHTML = list.slice().reverse().map((e) => {
            const author = e.coord.slice(6, 70);
            const pack = this.customEmojiPacks && this.customEmojiPacks.get(e.coord.slice(6));
            const name = e.name || (pack && String(pack.title || pack.identifier || '')) || e.coord.slice(71);
            const sample = e.sample.length ? e.sample : (pack && Array.isArray(pack.emojis) ? pack.emojis.slice(0, 4) : []);
            const imgs = sample.map((s) => `<img class="blocked-pack-sample" src="${this.escapeHtml(proxied(s.url))}" alt="" width="20" height="20" loading="lazy" decoding="async" draggable="false">`).join('');
            const by = this._ebText('by {author}', { author: this._emojiPackAuthorLabel(author) });
            return `<div class="blocked-item blocked-emoji-pack" data-coord="${this.escapeHtml(e.coord)}">` +
                `<span class="blocked-pack-info"><span class="blocked-pack-samples" aria-hidden="true">${imgs}</span>` +
                `<span class="blocked-pack-text"><span class="blocked-pack-name" data-no-i18n>${this.escapeHtml(name)}</span>` +
                `<span class="blocked-pack-author" data-no-i18n>${this.escapeHtml(by)}</span></span></span>` +
                `<button class="unblock-btn" data-action="unblockEmojiPackFromSettings" data-coord="${this.escapeHtml(e.coord)}">${unblock}</button></div>`;
        }).join('');
    },

});
