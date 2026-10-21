(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const QUIET = 4;
    const PLATE = 0.22;
    const MARK = 0.82;
    const MIN_CSS = 240;
    const MIN_DEVICE_MODULE = 4;
    const EXPORT_MODULE = 10;
    const MAX_BYTES = 382;
    const MARK_URL = '/images/nym-qr-mark.png';

    const CAP_H = [7, 14, 24, 34, 44, 58, 64, 84, 98, 119, 137, 155, 177, 194, 220, 250, 280, 310, 338, 382];
    let Model = null;

    function modelProto() {
        if (Model) return Model;
        const Q = G.QRCode;
        if (typeof Q !== 'function' || typeof G.document === 'undefined') return null;
        try {
            const seed = new Q(G.document.createElement('div'), { text: 'n', width: 1, height: 1, correctLevel: Q.CorrectLevel.H });
            Model = seed && seed._oQRCode ? Object.getPrototypeOf(seed._oQRCode) : null;
        } catch (_) { Model = null; }
        return Model;
    }

    function newModel(version, level) {
        const proto = modelProto();
        if (!proto) return null;
        const m = Object.create(proto);
        m.typeNumber = version;
        m.errorCorrectLevel = level;
        m.modules = null;
        m.moduleCount = 0;
        m.dataCache = null;
        m.dataList = [];
        return m;
    }

    function versionFor(bytes) {
        for (let i = 0; i < CAP_H.length; i++) if (CAP_H[i] >= bytes) return i + 1;
        return 0;
    }

    function matrix(text) {
        if (typeof text !== 'string' || !/^[\x20-\x7e]+$/.test(text) || text.length > MAX_BYTES) return null;
        const version = versionFor(text.length);
        const m = version ? newModel(version, G.QRCode && G.QRCode.CorrectLevel.H) : null;
        if (!m) return null;
        try {
            m.addData(text);
            m.make();
        } catch (_) { return null; }
        const count = m.getModuleCount();
        const cells = [];
        for (let r = 0; r < count; r++) {
            const row = [];
            for (let c = 0; c < count; c++) row.push(!!m.isDark(r, c));
            cells.push(row);
        }
        return { count, version: (count - 17) / 4, isDark: (r, c) => cells[r][c] };
    }

    function layout(count, cssWidth, dpr) {
        const ratio = dpr > 0 ? dpr : 1;
        const total = count + QUIET * 2;
        const target = Math.max(MIN_CSS, cssWidth || 0) * ratio;
        const module = Math.max(MIN_DEVICE_MODULE, Math.ceil(target / total));
        const plate = Math.floor(PLATE * count * module);
        return { total, module, size: total * module, css: (total * module) / ratio, plate, mark: plate * MARK, quiet: QUIET };
    }

    function exportSize(count) {
        return (count + QUIET * 2) * EXPORT_MODULE;
    }

    let markPromise = null;
    function loadMark() {
        if (markPromise) return markPromise;
        markPromise = new Promise((resolve) => {
            if (typeof G.Image !== 'function') { resolve(null); return; }
            const img = new G.Image();
            img.decoding = 'async';
            img.onload = () => resolve(img);
            img.onerror = () => { markPromise = null; resolve(null); };
            img.src = MARK_URL;
        });
        return markPromise;
    }

    function paint(ctx, m, module, mark) {
        const total = m.count + QUIET * 2;
        const size = total * module;
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(0, 0, size, size);
        ctx.fillStyle = '#000000';
        for (let r = 0; r < m.count; r++) {
            for (let c = 0; c < m.count; c++) {
                if (m.isDark(r, c)) ctx.fillRect((c + QUIET) * module, (r + QUIET) * module, module, module);
            }
        }
        const plate = Math.floor(PLATE * m.count * module);
        const cx = size / 2;
        ctx.fillStyle = '#FFFFFF';
        ctx.beginPath();
        ctx.arc(cx, cx, plate / 2, 0, Math.PI * 2);
        ctx.fill();
        if (mark) {
            const d = plate * MARK;
            ctx.imageSmoothingEnabled = true;
            ctx.imageSmoothingQuality = 'high';
            ctx.drawImage(mark, cx - d / 2, cx - d / 2, d, d);
        }
    }

    async function draw(canvas, text, opts) {
        const m = matrix(text);
        if (!m || !canvas) return null;
        const o = opts || {};
        const lay = layout(m.count, o.cssWidth || MIN_CSS, o.dpr || G.devicePixelRatio || 1);
        canvas.width = lay.size;
        canvas.height = lay.size;
        canvas.style.width = lay.css + 'px';
        canvas.style.height = lay.css + 'px';
        const ctx = canvas.getContext('2d');
        paint(ctx, m, lay.module, null);
        const mark = await loadMark();
        if (mark && (!o.isCurrent || o.isCurrent())) paint(ctx, m, lay.module, mark);
        return { count: m.count, version: m.version, layout: lay };
    }

    async function exportCanvas(text) {
        const m = matrix(text);
        if (!m) return null;
        const size = exportSize(m.count);
        const canvas = G.document.createElement('canvas');
        canvas.width = size;
        canvas.height = size;
        paint(canvas.getContext('2d'), m, EXPORT_MODULE, await loadMark());
        return canvas;
    }

    async function exportDataUrl(text) {
        const c = await exportCanvas(text);
        return c ? c.toDataURL('image/png') : null;
    }

    async function exportBlob(text) {
        const c = await exportCanvas(text);
        if (!c) return null;
        return new Promise((resolve) => c.toBlob((b) => resolve(b), 'image/png'));
    }

    G.NymShareQr = { matrix, versionFor, layout, exportSize, draw, exportDataUrl, exportBlob, loadMark, MARK_URL };
})();
