(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const CONFIG = Object.freeze({ weekdayDays: 7, floatIdleMs: 1500, floatTopPx: 8, floatPx: 26 });

    const STRINGS = Object.freeze({ today: 'Today', yesterday: 'Yesterday' });

    const DAY_SEC = 86400;

    function num(v) {
        const n = Number(v);
        return Number.isFinite(n) ? n : 0;
    }

    function effectiveAt(createdAt, seenAt) {
        const c = Math.floor(num(createdAt));
        const s = Math.floor(num(seenAt));
        return s > 0 && s < c ? s : c;
    }

    function offsetAt(tz, sec) {
        if (typeof tz === 'function') return Math.round(num(tz(sec)));
        if (Array.isArray(tz)) {
            let out = 0;
            for (const pair of tz) {
                if (!Array.isArray(pair)) continue;
                if (num(pair[0]) <= sec) out = num(pair[1]);
                else break;
            }
            return Math.round(out);
        }
        if (tz === undefined || tz === null) return -new Date(sec * 1000).getTimezoneOffset();
        return Math.round(num(tz));
    }

    function pad(n, w) {
        return String(n).padStart(w, '0');
    }

    function localDay(sec, tz) {
        const s = Math.floor(num(sec));
        const shifted = s + offsetAt(tz, s) * 60;
        const ordinal = Math.floor(shifted / DAY_SEC);
        const d = new Date(ordinal * DAY_SEC * 1000);
        const y = d.getUTCFullYear();
        const m = d.getUTCMonth() + 1;
        const day = d.getUTCDate();
        return { ordinal, y, m, d: day, wd: d.getUTCDay(), key: pad(y, 4) + '-' + pad(m, 2) + '-' + pad(day, 2) };
    }

    function dayKey(createdAt, now, tz) {
        return localDay(effectiveAt(createdAt, now), tz).key;
    }

    function dayInfo(createdAt, now, tz) {
        const at = localDay(effectiveAt(createdAt, now), tz);
        const today = localDay(Math.floor(num(now)), tz);
        const diff = today.ordinal - at.ordinal;
        let kind;
        if (diff <= 0) kind = 'today';
        else if (diff === 1) kind = 'yesterday';
        else if (diff < CONFIG.weekdayDays) kind = 'weekday';
        else kind = 'date';
        return { key: at.key, kind, diff, y: at.y, m: at.m, d: at.d, wd: at.wd, showYear: kind === 'date' && at.y !== today.y };
    }

    function intlLocale(locale) {
        if (!locale) return 'en';
        const tag = String(locale).replace(/_/g, '-');
        try { return Intl.DateTimeFormat.supportedLocalesOf([tag]).length ? tag : 'en'; } catch (_) { return 'en'; }
    }

    function clean(s) {
        return String(s).replace(/[  ]/g, ' ');
    }

    function format(info, locale, t) {
        const tr = (s) => (typeof t === 'function' ? t(s) : s);
        if (!info) return '';
        if (info.kind === 'today') return tr(STRINGS.today);
        if (info.kind === 'yesterday') return tr(STRINGS.yesterday);
        const date = new Date(Date.UTC(info.y, info.m - 1, info.d, 12));
        const loc = intlLocale(locale);
        const opts = info.kind === 'weekday'
            ? { timeZone: 'UTC', weekday: 'long' }
            : (info.showYear
                ? { timeZone: 'UTC', year: 'numeric', month: 'long', day: 'numeric' }
                : { timeZone: 'UTC', month: 'long', day: 'numeric' });
        try { return clean(new Intl.DateTimeFormat(loc, opts).format(date)); } catch (_) {
            return clean(new Intl.DateTimeFormat('en', opts).format(date));
        }
    }

    function label(createdAt, now, tz, locale, t) {
        return format(dayInfo(createdAt, now, tz), locale, t);
    }

    function boundaries(stamps, now, tz) {
        const out = [];
        let prev = null;
        for (const s of Array.isArray(stamps) ? stamps : []) {
            const k = dayKey(s, now, tz);
            out.push(k !== prev);
            prev = k;
        }
        return out;
    }

    function sameDay(a, b, now, tz) {
        return dayKey(a, now, tz) === dayKey(b, now, tz);
    }

    function nextMidnightMs(nowMs, tz) {
        const sec = Math.floor(num(nowMs) / 1000);
        const today = localDay(sec, tz);
        let guess = (today.ordinal + 1) * DAY_SEC - offsetAt(tz, sec) * 60;
        for (let i = 0; i < 3 && localDay(guess, tz).ordinal === today.ordinal; i++) guess += 3600;
        return guess * 1000;
    }

    function floatVisible(o) {
        const r = o && typeof o === 'object' ? o : {};
        if (!r.key) return false;
        if (r.inlineKey === r.key && r.inlineTop !== null && r.inlineTop !== undefined && num(r.inlineTop) >= num(r.viewTop) - 1) return false;
        if (r.coverTop !== null && r.coverTop !== undefined && r.coverBottom !== null && r.coverBottom !== undefined) {
            const top = num(r.viewTop) + CONFIG.floatTopPx;
            if (num(r.coverBottom) > top && num(r.coverTop) < top + CONFIG.floatPx) return false;
        }
        if (r.atBottom && !r.scrolling) return false;
        return !!(r.scrolling || num(r.idleMs) < CONFIG.floatIdleMs);
    }

    G.NymDayLabels = Object.freeze({
        CONFIG, STRINGS, effectiveAt, offsetAt, localDay, dayKey, dayInfo, format, label, boundaries, sameDay, nextMidnightMs, floatVisible,
    });
})();
