/* eslint-env worker */

let canvas = null;
let ctx = null;
let cssWidth = 1;
let cssHeight = 1;
let dpr = 1;
let isPerf = false;

const view = { cx: 0, cy: 0, zoom: 1, minZoom: 1, maxZoom: 16 };

let features = [];
let admin1Features = [];
let cityFeatures = [];

let channels = [];
let userLocation = null;
let hoveredGeohash = null;

let heatmapMode = false;
let daynightMode = false;
let geohashGridMode = false;

let styles = computeStyles(false);

let drawScheduled = false;
let heatPalette = null;
let heatCanvas = null;
let heatCtx = null;
const HEAT_SCALE = 0.5;

const ADMIN1_ZOOM_THRESHOLD = 2.5;
const CITY_ZOOM_THRESHOLD = 2.5;
const GEOHASH_BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';

function computeStyles(isLight) {
    return {
        primary: '#00ffff',
        warning: '#ffcc00',
        joined: '#28e07a',
        ocean: isLight ? '#d6e8f1' : '#0a131e',
        land: isLight ? '#eef2f4' : '#1c2a39',
        border: isLight ? '#9aaeba' : '#2c4357',
        adminBorder: isLight ? 'rgba(120,140,160,0.55)' : 'rgba(180,200,220,0.22)',
        graticule: isLight ? 'rgba(0,0,0,0.05)' : 'rgba(255,255,255,0.04)',
        label: isLight ? 'rgba(30,40,55,0.85)' : 'rgba(220,232,245,0.85)',
        adminLabel: isLight ? 'rgba(70,80,95,0.75)' : 'rgba(190,205,220,0.65)',
        cityDot: isLight ? 'rgba(60,70,85,0.85)' : 'rgba(220,232,245,0.9)',
        cityLabel: isLight ? 'rgba(50,60,75,0.85)' : 'rgba(220,232,245,0.85)',
        labelStroke: isLight ? 'rgba(255,255,255,0.85)' : 'rgba(0,0,0,0.65)',
        haloAlpha: isLight ? 0.18 : 0.32,
        gridLine: isLight ? 'rgba(0, 100, 140, 0.45)' : 'rgba(0, 220, 255, 0.35)',
        gridLabel: isLight ? 'rgba(20, 30, 45, 0.85)' : 'rgba(220, 240, 255, 0.92)',
        daynightFill: isLight ? 'rgba(20, 30, 55, 0.28)' : 'rgba(2, 6, 16, 0.5)',
        daynightStroke: isLight ? 'rgba(40, 60, 100, 0.45)' : 'rgba(180, 200, 230, 0.35)',
        isLight
    };
}

function solarPosition(date) {
    const rad = Math.PI / 180;
    const n = (date.getTime() / 86400000) - 10957.5;
    const L = ((280.46 + 0.9856474 * n) % 360 + 360) % 360;
    const g = (((357.528 + 0.9856003 * n) % 360 + 360) % 360) * rad;
    const lambda = (L + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * rad;
    const epsilon = 23.4397 * rad;
    const RA = Math.atan2(Math.cos(epsilon) * Math.sin(lambda), Math.cos(lambda));
    const decl = Math.asin(Math.sin(epsilon) * Math.sin(lambda));
    const gmst = (((18.697374558 + 24.06570982441908 * n) % 24) + 24) % 24;
    let lng = (RA / rad) - gmst * 15;
    lng = ((lng % 360) + 540) % 360 - 180;
    return { lat: decl / rad, lng };
}

function geohashCellSize(precision) {
    const totalBits = 5 * precision;
    const lngBits = Math.ceil(totalBits / 2);
    const latBits = Math.floor(totalBits / 2);
    return {
        lngStep: 360 / Math.pow(2, lngBits),
        latStep: 180 / Math.pow(2, latBits)
    };
}

function encodeGeohashRaw(lat, lng, precision) {
    const bounds = { lat: [-90, 90], lng: [-180, 180] };
    let isEven = true, bit = 0, ch = 0, geohash = '';
    while (geohash.length < precision) {
        if (isEven) {
            const mid = (bounds.lng[0] + bounds.lng[1]) / 2;
            if (lng >= mid) { ch = (ch << 1) + 1; bounds.lng[0] = mid; }
            else { ch = ch << 1; bounds.lng[1] = mid; }
        } else {
            const mid = (bounds.lat[0] + bounds.lat[1]) / 2;
            if (lat >= mid) { ch = (ch << 1) + 1; bounds.lat[0] = mid; }
            else { ch = ch << 1; bounds.lat[1] = mid; }
        }
        isEven = !isEven;
        if (++bit === 5) {
            geohash += GEOHASH_BASE32[ch];
            bit = 0; ch = 0;
        }
    }
    return geohash;
}

function baseScale() {
    return Math.max(cssWidth / 360, cssHeight / 180);
}

function project(lng, lat) {
    const s = baseScale() * view.zoom;
    return {
        x: (lng - view.cx) * s + cssWidth / 2,
        y: (view.cy - lat) * s + cssHeight / 2
    };
}

function unproject(x, y) {
    const s = baseScale() * view.zoom;
    return {
        lng: (x - cssWidth / 2) / s + view.cx,
        lat: view.cy - (y - cssHeight / 2) / s
    };
}

function clampView() {
    if (view.zoom < view.minZoom) view.zoom = view.minZoom;
    if (view.zoom > view.maxZoom) view.zoom = view.maxZoom;
    const s = baseScale() * view.zoom;
    const halfLng = (cssWidth / 2) / s;
    const halfLat = (cssHeight / 2) / s;
    if (halfLng >= 180) view.cx = 0;
    else view.cx = Math.max(-180 + halfLng, Math.min(180 - halfLng, view.cx));
    if (halfLat >= 90) view.cy = 0;
    else view.cy = Math.max(-90 + halfLat, Math.min(90 - halfLat, view.cy));
}

function inView(p, pad) {
    return p.x >= -pad && p.x <= cssWidth + pad && p.y >= -pad && p.y <= cssHeight + pad;
}

function computeGridPrecision() {
    const s = baseScale() * view.zoom;
    let p = 1;
    while (p < 9) {
        const next = geohashCellSize(p + 1);
        if (next.lngStep * s < 50) break;
        p++;
    }
    return p;
}

function ensureHeatCanvas() {
    const w = Math.max(1, Math.floor(cssWidth * HEAT_SCALE));
    const h = Math.max(1, Math.floor(cssHeight * HEAT_SCALE));
    if (!heatCanvas) {
        heatCanvas = new OffscreenCanvas(w, h);
        heatCtx = heatCanvas.getContext('2d');
    }
    if (heatCanvas.width !== w || heatCanvas.height !== h) {
        heatCanvas.width = w;
        heatCanvas.height = h;
    }
}

function getHeatPalette() {
    if (heatPalette) return heatPalette;
    const c = new OffscreenCanvas(256, 1);
    const x = c.getContext('2d');
    const grad = x.createLinearGradient(0, 0, 256, 0);
    grad.addColorStop(0.00, 'rgba(0,0,128,0)');
    grad.addColorStop(0.20, 'rgba(0,160,255,0.75)');
    grad.addColorStop(0.45, 'rgba(0,255,120,0.9)');
    grad.addColorStop(0.70, 'rgba(255,220,0,0.95)');
    grad.addColorStop(1.00, 'rgba(255,40,0,1)');
    x.fillStyle = grad;
    x.fillRect(0, 0, 256, 1);
    heatPalette = x.getImageData(0, 0, 256, 1).data;
    return heatPalette;
}

function drawAdmin0() {
    ctx.fillStyle = styles.land;
    ctx.strokeStyle = styles.border;
    ctx.lineWidth = isPerf ? 0.5 : 0.7;
    ctx.lineJoin = 'round';

    for (const feat of features) {
        const polys = feat.type === 'Polygon' ? [feat.coordinates] : feat.coordinates;
        ctx.beginPath();
        for (const poly of polys) {
            for (const ring of poly) {
                if (ring.length < 2) continue;
                let prevLng = ring[0][0];
                const first = project(prevLng, ring[0][1]);
                ctx.moveTo(first.x, first.y);
                for (let i = 1; i < ring.length; i++) {
                    const lng = ring[i][0];
                    const p = project(lng, ring[i][1]);
                    if (Math.abs(lng - prevLng) > 180) {
                        ctx.closePath();
                        ctx.moveTo(p.x, p.y);
                    } else {
                        ctx.lineTo(p.x, p.y);
                    }
                    prevLng = lng;
                }
                ctx.closePath();
            }
        }
        ctx.fill('evenodd');
        ctx.stroke();
    }
}

function drawGraticule() {
    ctx.strokeStyle = styles.graticule;
    ctx.lineWidth = 1;
    ctx.beginPath();
    const step = view.zoom > 4 ? 10 : 30;
    for (let lng = -180; lng <= 180; lng += step) {
        const a = project(lng, 85);
        const b = project(lng, -85);
        ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y);
    }
    for (let lat = -60; lat <= 60; lat += step) {
        const a = project(-180, lat);
        const b = project(180, lat);
        ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y);
    }
    ctx.stroke();
}

function drawLabels() {
    if (!features.length) return;
    const fontSize = isPerf ? 10 : 11;
    ctx.font = `600 ${fontSize}px system-ui, sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.lineJoin = 'round';

    for (const feat of features) {
        if (!feat.name) continue;
        const bb = feat.bounds;
        const a = project(bb[0], bb[3]);
        const b = project(bb[2], bb[1]);
        const widthPx = Math.abs(b.x - a.x);
        const heightPx = Math.abs(b.y - a.y);
        const span = Math.max(widthPx, heightPx);
        const text = feat.name;
        const minSpan = Math.max(28, text.length * 5);
        if (span < minSpan) continue;

        const c = feat.centroid;
        const p = project(c[0], c[1]);
        if (!inView(p, 40)) continue;

        ctx.lineWidth = 3;
        ctx.strokeStyle = styles.labelStroke;
        ctx.strokeText(text, p.x, p.y);
        ctx.fillStyle = styles.label;
        ctx.fillText(text, p.x, p.y);
    }
}

function drawAdmin1() {
    if (view.zoom < ADMIN1_ZOOM_THRESHOLD || !admin1Features.length) return;
    const fadeStart = ADMIN1_ZOOM_THRESHOLD;
    const fadeEnd = fadeStart + 1.5;
    const t = Math.min(1, Math.max(0, (view.zoom - fadeStart) / (fadeEnd - fadeStart)));
    if (t <= 0) return;

    ctx.strokeStyle = styles.adminBorder;
    ctx.lineWidth = isPerf ? 0.4 : 0.5;
    ctx.globalAlpha = t;
    ctx.lineJoin = 'round';
    ctx.beginPath();
    for (const feat of admin1Features) {
        const bb = feat.bounds;
        if (bb) {
            const a = project(bb[0], bb[3]);
            const b = project(bb[2], bb[1]);
            if (b.x < -10 || a.x > cssWidth + 10 || b.y < -10 || a.y > cssHeight + 10) continue;
        }
        const polys = feat.type === 'Polygon' ? [feat.coordinates] : feat.coordinates;
        for (const poly of polys) {
            for (const ring of poly) {
                if (ring.length < 2) continue;
                let prevLng = ring[0][0];
                const first = project(prevLng, ring[0][1]);
                ctx.moveTo(first.x, first.y);
                for (let i = 1; i < ring.length; i++) {
                    const lng = ring[i][0];
                    const p = project(lng, ring[i][1]);
                    if (Math.abs(lng - prevLng) > 180) {
                        ctx.moveTo(p.x, p.y);
                    } else {
                        ctx.lineTo(p.x, p.y);
                    }
                    prevLng = lng;
                }
            }
        }
    }
    ctx.stroke();
    ctx.globalAlpha = 1;
}

function drawAdmin1Labels() {
    if (view.zoom < 4 || !admin1Features.length) return;
    const fontSize = isPerf ? 9 : 10;
    ctx.font = `500 ${fontSize}px system-ui, sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.lineJoin = 'round';

    for (const feat of admin1Features) {
        if (!feat.name) continue;
        const bb = feat.bounds;
        const a = project(bb[0], bb[3]);
        const b = project(bb[2], bb[1]);
        const span = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y));
        const text = feat.name;
        const minSpan = Math.max(40, text.length * 5.5);
        if (span < minSpan) continue;

        const c = feat.centroid;
        const p = project(c[0], c[1]);
        if (!inView(p, 30)) continue;

        ctx.lineWidth = 2.5;
        ctx.strokeStyle = styles.labelStroke;
        ctx.strokeText(text, p.x, p.y);
        ctx.fillStyle = styles.adminLabel;
        ctx.fillText(text, p.x, p.y);
    }
}

function drawCities() {
    if (view.zoom < CITY_ZOOM_THRESHOLD || !cityFeatures.length) return;

    const rankCutoff = view.zoom < 3 ? 2
        : view.zoom < 4 ? 4
        : view.zoom < 6 ? 6
        : view.zoom < 8 ? 8 : 10;

    const fontSize = isPerf ? 9 : 10;
    ctx.font = `500 ${fontSize}px system-ui, sans-serif`;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.lineJoin = 'round';

    const dotR = isPerf ? 1.5 : 2;
    const showLabels = view.zoom >= 3;

    for (const city of cityFeatures) {
        if (city.rank > rankCutoff) continue;
        const p = project(city.lng, city.lat);
        if (!inView(p, 80)) continue;

        ctx.beginPath();
        ctx.arc(p.x, p.y, dotR, 0, Math.PI * 2);
        ctx.fillStyle = styles.cityDot;
        ctx.fill();

        if (showLabels && city.name) {
            ctx.lineWidth = 2.5;
            ctx.strokeStyle = styles.labelStroke;
            ctx.strokeText(city.name, p.x + 4, p.y);
            ctx.fillStyle = styles.cityLabel;
            ctx.fillText(city.name, p.x + 4, p.y);
        }
    }
}

function drawDaynight() {
    const sun = solarPosition(new Date());
    const declRad = sun.lat * Math.PI / 180;
    let tanDecl = Math.tan(declRad);
    if (Math.abs(tanDecl) < 1e-4) tanDecl = (declRad >= 0 ? 1 : -1) * 1e-4;

    const step = 2;
    const points = [];
    for (let lng = -180; lng <= 180; lng += step) {
        const dLng = (lng - sun.lng) * Math.PI / 180;
        const lat = Math.atan(-Math.cos(dLng) / tanDecl) * 180 / Math.PI;
        points.push(project(lng, lat));
    }

    const closeBottom = sun.lat >= 0;
    const yEdge = closeBottom ? cssHeight + 4 : -4;

    ctx.save();
    ctx.fillStyle = styles.daynightFill;
    ctx.beginPath();
    ctx.moveTo(points[0].x, points[0].y);
    for (let i = 1; i < points.length; i++) ctx.lineTo(points[i].x, points[i].y);
    const last = points[points.length - 1];
    ctx.lineTo(last.x, yEdge);
    ctx.lineTo(points[0].x, yEdge);
    ctx.closePath();
    ctx.fill();

    ctx.beginPath();
    ctx.moveTo(points[0].x, points[0].y);
    for (let i = 1; i < points.length; i++) ctx.lineTo(points[i].x, points[i].y);
    ctx.strokeStyle = styles.daynightStroke;
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.restore();
}

function drawHeatmap() {
    if (!channels.length) return;

    ensureHeatCanvas();
    const palette = getHeatPalette();
    const w = heatCanvas.width, h = heatCanvas.height;

    heatCtx.globalCompositeOperation = 'source-over';
    heatCtx.clearRect(0, 0, w, h);
    heatCtx.globalCompositeOperation = 'lighter';

    const baseRadius = Math.max(22, Math.min(70, 24 + view.zoom * 3.5));
    const radius = baseRadius * HEAT_SCALE;

    let maxMsg = 1;
    for (const ch of channels) if (ch.messages > maxMsg) maxMsg = ch.messages;
    const denom = Math.log(maxMsg + 1) || 1;

    for (const ch of channels) {
        const p = project(ch.lng, ch.lat);
        const sx = p.x * HEAT_SCALE, sy = p.y * HEAT_SCALE;
        if (sx < -radius || sx > w + radius || sy < -radius || sy > h + radius) continue;
        const weight = Math.log(ch.messages + 1) / denom;
        const intensity = Math.min(1, 0.18 + 0.82 * weight);
        const grad = heatCtx.createRadialGradient(sx, sy, 0, sx, sy, radius);
        grad.addColorStop(0, `rgba(0,0,0,${intensity})`);
        grad.addColorStop(1, 'rgba(0,0,0,0)');
        heatCtx.fillStyle = grad;
        heatCtx.fillRect(sx - radius, sy - radius, radius * 2, radius * 2);
    }

    const img = heatCtx.getImageData(0, 0, w, h);
    const d = img.data;
    for (let i = 0; i < d.length; i += 4) {
        const a = d[i + 3];
        if (a === 0) continue;
        const j = a * 4;
        d[i]     = palette[j];
        d[i + 1] = palette[j + 1];
        d[i + 2] = palette[j + 2];
        d[i + 3] = palette[j + 3];
    }
    heatCtx.globalCompositeOperation = 'source-over';
    heatCtx.putImageData(img, 0, 0);

    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = isPerf ? 'low' : 'medium';
    ctx.drawImage(heatCanvas, 0, 0, cssWidth, cssHeight);
    ctx.imageSmoothingEnabled = false;
}

function drawGeohashGrid() {
    const precision = computeGridPrecision();
    const { lngStep, latStep } = geohashCellSize(precision);
    const s = baseScale() * view.zoom;
    const halfLng = (cssWidth / 2) / s;
    const halfLat = (cssHeight / 2) / s;
    const lngMin = Math.max(-180, view.cx - halfLng);
    const lngMax = Math.min(180, view.cx + halfLng);
    const latMin = Math.max(-90, view.cy - halfLat);
    const latMax = Math.min(90, view.cy + halfLat);

    const startGi = Math.floor((lngMin + 180) / lngStep);
    const endGi = Math.ceil((lngMax + 180) / lngStep);
    const startLi = Math.floor((latMin + 90) / latStep);
    const endLi = Math.ceil((latMax + 90) / latStep);

    ctx.save();
    ctx.lineWidth = 1;
    ctx.strokeStyle = styles.gridLine;
    ctx.beginPath();
    for (let gi = startGi; gi < endGi; gi++) {
        const lng0 = -180 + gi * lngStep;
        const a = project(lng0, latMax);
        const b = project(lng0, latMin);
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(b.x, b.y);
    }
    for (let li = startLi; li < endLi; li++) {
        const lat0 = -90 + li * latStep;
        const a = project(lngMin, lat0);
        const b = project(lngMax, lat0);
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(b.x, b.y);
    }
    ctx.stroke();

    const cellPxW = lngStep * s;
    const cellPxH = latStep * s;
    const showLabels = cellPxW >= 38 && cellPxH >= 22;
    if (showLabels) {
        const fontSize = Math.max(9, Math.min(14, Math.floor(Math.min(cellPxW, cellPxH) / 5)));
        ctx.font = `600 ${fontSize}px system-ui, sans-serif`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.lineJoin = 'round';
        ctx.lineWidth = 3;
        for (let li = startLi; li < endLi; li++) {
            const cellLat = -90 + li * latStep + latStep / 2;
            if (cellLat < -90 || cellLat > 90) continue;
            for (let gi = startGi; gi < endGi; gi++) {
                const cellLng = -180 + gi * lngStep + lngStep / 2;
                if (cellLng < -180 || cellLng > 180) continue;
                const gh = encodeGeohashRaw(cellLat, cellLng, precision);
                const p = project(cellLng, cellLat);
                if (!inView(p, 0)) continue;
                ctx.strokeStyle = styles.labelStroke;
                ctx.strokeText(gh, p.x, p.y);
                ctx.fillStyle = styles.gridLabel;
                ctx.fillText(gh, p.x, p.y);
            }
        }
    }
    ctx.restore();
}

function drawChannels() {
    const baseR = isPerf ? 4 : 5;
    for (const ch of channels) {
        const p = project(ch.lng, ch.lat);
        if (!inView(p, 12)) continue;
        const isHover = hoveredGeohash && hoveredGeohash === ch.geohash;
        const r = isHover ? baseR + 2 : baseR;
        const color = ch.isJoined ? styles.joined : styles.primary;

        if (!isPerf) {
            ctx.beginPath();
            ctx.arc(p.x, p.y, r + 5, 0, Math.PI * 2);
            ctx.fillStyle = color;
            ctx.globalAlpha = styles.haloAlpha;
            ctx.fill();
            ctx.globalAlpha = 1;
        }

        ctx.beginPath();
        ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
        ctx.fillStyle = color;
        ctx.fill();
        ctx.strokeStyle = 'rgba(0,0,0,0.55)';
        ctx.lineWidth = 1;
        ctx.stroke();
    }
}

function drawUserLocation() {
    if (!userLocation) return;
    const p = project(userLocation.lng, userLocation.lat);
    if (!inView(p, 10)) return;
    if (!isPerf) {
        ctx.beginPath();
        ctx.arc(p.x, p.y, 11, 0, Math.PI * 2);
        ctx.fillStyle = styles.warning;
        ctx.globalAlpha = styles.haloAlpha;
        ctx.fill();
        ctx.globalAlpha = 1;
    }
    ctx.beginPath();
    ctx.arc(p.x, p.y, 5.5, 0, Math.PI * 2);
    ctx.fillStyle = styles.warning;
    ctx.fill();
    ctx.strokeStyle = 'rgba(0,0,0,0.6)';
    ctx.lineWidth = 1.2;
    ctx.stroke();
}

function draw() {
    drawScheduled = false;
    if (!ctx) return;

    ctx.fillStyle = styles.ocean;
    ctx.fillRect(0, 0, cssWidth, cssHeight);

    drawGraticule();
    drawAdmin0();
    drawAdmin1();
    drawLabels();
    drawAdmin1Labels();
    if (heatmapMode) {
        drawHeatmap();
    } else {
        drawCities();
        drawChannels();
    }
    if (daynightMode) drawDaynight();
    if (geohashGridMode) drawGeohashGrid();
    drawUserLocation();
}

function requestDraw() {
    if (drawScheduled) return;
    drawScheduled = true;
    (self.requestAnimationFrame || ((cb) => setTimeout(cb, 16)))(draw);
}

function applySize() {
    if (!canvas) return;
    canvas.width = Math.floor(cssWidth * dpr);
    canvas.height = Math.floor(cssHeight * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}

function findChannelAt(x, y) {
    const hitR = 10;
    let nearest = null;
    let best = Infinity;
    for (const ch of channels) {
        const p = project(ch.lng, ch.lat);
        const d = Math.hypot(p.x - x, p.y - y);
        if (d < hitR && d < best) { best = d; nearest = ch; }
    }
    return nearest;
}

function findGeohashAt(x, y) {
    const precision = computeGridPrecision();
    const u = unproject(x, y);
    if (u.lat < -90 || u.lat > 90 || u.lng < -180 || u.lng > 180) return null;
    return encodeGeohashRaw(u.lat, u.lng, precision);
}

self.onmessage = (e) => {
    const m = e.data || {};
    switch (m.op) {
        case 'init': {
            canvas = m.canvas;
            cssWidth = m.cssWidth || 1;
            cssHeight = m.cssHeight || 1;
            dpr = m.dpr || 1;
            isPerf = !!m.isPerf;
            styles = computeStyles(!!m.isLight);
            ctx = canvas.getContext('2d');
            applySize();
            clampView();
            requestDraw();
            break;
        }
        case 'resize': {
            cssWidth = m.cssWidth || 1;
            cssHeight = m.cssHeight || 1;
            if (m.dpr) dpr = m.dpr;
            applySize();
            clampView();
            requestDraw();
            break;
        }
        case 'setView': {
            if (typeof m.cx === 'number') view.cx = m.cx;
            if (typeof m.cy === 'number') view.cy = m.cy;
            if (typeof m.zoom === 'number') view.zoom = m.zoom;
            clampView();
            requestDraw();
            break;
        }
        case 'panBy': {
            const s = baseScale() * view.zoom;
            view.cx -= (m.dx || 0) / s;
            view.cy += (m.dy || 0) / s;
            clampView();
            requestDraw();
            break;
        }
        case 'zoomAt': {
            const before = unproject(m.focusX, m.focusY);
            view.zoom = Math.max(view.minZoom, Math.min(view.maxZoom, view.zoom * (m.factor || 1)));
            const after = unproject(m.focusX, m.focusY);
            view.cx += (before.lng - after.lng);
            view.cy += (before.lat - after.lat);
            clampView();
            self.postMessage({ type: 'viewChanged', cx: view.cx, cy: view.cy, zoom: view.zoom });
            requestDraw();
            break;
        }
        case 'zoomToBounds': {
            const b = m.bounds;
            const padding = m.padding || 0.7;
            const lngSpan = Math.max(1e-6, b.lng[1] - b.lng[0]);
            const latSpan = Math.max(1e-6, b.lat[1] - b.lat[0]);
            const s = baseScale();
            const zLng = (cssWidth * padding) / (lngSpan * s);
            const zLat = (cssHeight * padding) / (latSpan * s);
            const target = Math.min(zLng, zLat);
            view.zoom = Math.max(view.minZoom, Math.min(view.maxZoom, target));
            view.cx = (b.lng[0] + b.lng[1]) / 2;
            view.cy = (b.lat[0] + b.lat[1]) / 2;
            clampView();
            self.postMessage({ type: 'viewChanged', cx: view.cx, cy: view.cy, zoom: view.zoom });
            requestDraw();
            break;
        }
        case 'resetView': {
            view.cx = 0; view.cy = 0; view.zoom = 1;
            hoveredGeohash = null;
            heatmapMode = false;
            daynightMode = false;
            geohashGridMode = false;
            clampView();
            requestDraw();
            break;
        }
        case 'setChannels': {
            channels = m.channels || [];
            requestDraw();
            break;
        }
        case 'setUserLocation': {
            userLocation = m.userLocation || null;
            requestDraw();
            break;
        }
        case 'setHovered': {
            hoveredGeohash = m.geohash || null;
            requestDraw();
            break;
        }
        case 'setFeatures': {
            if (m.admin0) features = m.admin0;
            if (m.admin1) admin1Features = m.admin1;
            if (m.cities) cityFeatures = m.cities;
            requestDraw();
            break;
        }
        case 'setMode': {
            if (typeof m.heatmap === 'boolean') heatmapMode = m.heatmap;
            if (typeof m.daynight === 'boolean') daynightMode = m.daynight;
            if (typeof m.grid === 'boolean') geohashGridMode = m.grid;
            requestDraw();
            break;
        }
        case 'setStyle': {
            styles = computeStyles(!!m.isLight);
            requestDraw();
            break;
        }
        case 'hitTest': {
            const ch = findChannelAt(m.x, m.y);
            const gh = (!ch && geohashGridMode) ? findGeohashAt(m.x, m.y) : null;
            self.postMessage({ type: 'hitResult', replyId: m.replyId, channel: ch, geohash: gh });
            break;
        }
        case 'hoverTest': {
            const ch = findChannelAt(m.x, m.y);
            const next = ch ? ch.geohash : null;
            if (next !== hoveredGeohash) {
                hoveredGeohash = next;
                requestDraw();
            }
            self.postMessage({ type: 'hoverResult', replyId: m.replyId, hasChannel: !!ch });
            break;
        }
        case 'requestDraw': {
            requestDraw();
            break;
        }
    }
};
