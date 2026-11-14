(function () {
    'use strict';
    const G = typeof window !== 'undefined' ? window : globalThis;

    const MIN = 4.5;
    const BLACK = [0, 0, 0, 1];
    const WHITE = [1, 1, 1, 1];

    function parse(s) {
        if (typeof s !== 'string') return null;
        let h = s.trim().replace(/^#/, '');
        if (h.length === 3) h = h.split('').map((c) => c + c).join('');
        if (!/^[0-9a-f]{6}([0-9a-f]{2})?$/i.test(h)) return null;
        const n = (i) => parseInt(h.slice(i, i + 2), 16) / 255;
        return [n(0), n(2), n(4), h.length === 8 ? n(6) : 1];
    }

    const byte = (x) => Math.min(255, Math.max(0, Math.round(x * 255)));
    const two = (x) => byte(x).toString(16).padStart(2, '0');

    function hex(c) {
        const a = byte(c[3]);
        return '#' + two(c[0]) + two(c[1]) + two(c[2]) + (a === 255 ? '' : two(c[3]));
    }

    const lin = (v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
    const lum = (c) => 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2]);
    const opaque = (c) => [c[0], c[1], c[2], 1];
    const clamp = (x) => Math.min(1, Math.max(0, x));

    function blend(fg, bg) {
        const a = fg[3];
        if (a === 0) return bg;
        const ia = 1 - a;
        let ba = bg[3];
        if (ba === 1) return [a * fg[0] + ia * bg[0], a * fg[1] + ia * bg[1], a * fg[2] + ia * bg[2], 1];
        ba = ba * ia;
        const oa = a + ba;
        return [(fg[0] * a + bg[0] * ba) / oa, (fg[1] * a + bg[1] * ba) / oa, (fg[2] * a + bg[2] * ba) / oa, oa];
    }

    const flatten = (fg, bg) => blend(fg, opaque(bg));

    function ratio(fg, bg) {
        const b = opaque(bg);
        const x = lum(flatten(fg, b));
        const l = lum(b);
        return (Math.max(x, l) + 0.05) / (Math.min(x, l) + 0.05);
    }

    const lerp = (x, y, t) => [0, 1, 2, 3].map((i) => clamp(x[i] * (1 - t) + y[i] * t));

    function legibleOn(fg, bg) {
        const base = opaque(bg);
        const c = flatten(fg, base);
        if (ratio(c, base) >= MIN) return c;
        const toward = lum(base) > 0.18 ? BLACK : WHITE;
        for (let i = 1; i <= 20; i++) {
            const m = lerp(c, toward, i / 20);
            if (ratio(m, base) >= MIN) return m;
        }
        return toward;
    }

    function legibleOnAll(fg, bgs) {
        let c = fg;
        for (let i = 0; i < 3; i++) {
            for (const bg of bgs) c = legibleOn(c, bg);
        }
        return c;
    }

    function surfaces(isLight, solid, ghost) {
        const bg = parse(isLight ? '#f5f5f2' : (ghost ? '#080808' : '#0a0a0f'));
        let bubble;
        if (solid) bubble = parse(ghost ? (isLight ? '#dddddd' : '#2a2a2a') : (isLight ? '#e6e6e0' : '#2a2a3a'));
        else bubble = isLight ? [0, 0, 0, 0x1a / 255] : [1, 1, 1, 0x24 / 255];
        return [flatten(bubble, bg), bg];
    }

    const redactedBase = (isLight) => (isLight ? '#1a1a1abf' : '#ffffffcc');

    const memo = new Map();

    function legible(color, o) {
        const key = color + '|' + (o.isLight ? 'l' : 'd') + (o.solid ? 's' : 'g') + (o.ghost ? 'h' : '');
        if (memo.has(key)) return memo.get(key);
        const fg = parse(color);
        const out = fg ? hex(legibleOnAll(fg, surfaces(!!o.isLight, !!o.solid, !!o.ghost))) : null;
        memo.set(key, out);
        return out;
    }

    const sets = new Map();

    function names(o) {
        const key = [o.primary, o.secondary, o.isLight ? 'l' : 'd', o.ghost ? 'h' : ''].join('|');
        if (sets.has(key)) return sets.get(key);
        const red = redactedBase(!!o.isLight);
        const at = (color, solid) => legible(color, { isLight: o.isLight, solid, ghost: o.ghost });
        const out = {
            ownSolid: at(o.primary, true), ownGlass: at(o.primary, false),
            otherSolid: at(o.secondary, true), otherGlass: at(o.secondary, false),
            redactedSolid: at(red, true), redactedGlass: at(red, false)
        };
        sets.set(key, out);
        return out;
    }

    const PROPS = [
        ['--nym-hc-own-s', 'ownSolid'], ['--nym-hc-own-g', 'ownGlass'],
        ['--nym-hc-other-s', 'otherSolid'], ['--nym-hc-other-g', 'otherGlass'],
        ['--nym-hc-red-s', 'redactedSolid'], ['--nym-hc-red-g', 'redactedGlass']
    ];

    function apply(el, o) {
        if (!el || !el.style) return;
        const n = names(o);
        for (const [prop, k] of PROPS) {
            if (n[k]) el.style.setProperty(prop, n[k]);
            else el.style.removeProperty(prop);
        }
    }

    G.NymNameContrast = { MIN, parse, hex, legibleOn, legibleOnAll, surfaces, redactedBase, legible, names, apply, PROPS };
})();
