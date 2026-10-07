(function () {

    // Vendored map data (world-atlas@2.0.2, natural-earth-geojson@0b9a6ce)
    const WORLD_TOPO_URL = '/data/countries-110m.json';
    const ADMIN1_GEOJSON_URL = '/data/ne_50m_admin_1_states_provinces_lakes.json';
    const CITIES_GEOJSON_URL = '/data/ne_50m_populated_places_simple.json';

    const TIER50_URL = '/data/geo-detail-50m.json';
    const TIER10_URL = '/data/geo-detail-10m.json';
    const TIER_URLS = [null, TIER50_URL, TIER10_URL];
    const MIN_PART_PX = 0.6;

    const ADMIN1_ZOOM_THRESHOLD = 2.5;
    const CITY_ZOOM_THRESHOLD = 2.5;
    const ACTIVE_WINDOW_REFRESH_MS = 30000;
    const DAYNIGHT_REFRESH_MS = 60000;

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

    let geoWorker = null, geoWorkerFailed = false, geoSeq = 0;
    const geoPending = new Map();

    function getGeoWorker() {
        if (geoWorkerFailed) return null;
        if (geoWorker) return geoWorker;
        if (typeof Worker !== 'function') { geoWorkerFailed = true; return null; }
        try {
            const w = new Worker('/js/geo-decode-worker.js');
            w.onmessage = (e) => {
                const d = e.data || {};
                const p = geoPending.get(d.seq);
                if (!p) return;
                geoPending.delete(d.seq);
                if (d.error) p.reject(new Error(d.error));
                else p.resolve(d.features || []);
            };
            w.onerror = () => {
                geoWorkerFailed = true;
                geoWorker = null;
                const pend = Array.from(geoPending.values());
                geoPending.clear();
                try { w.terminate(); } catch (_) { }
                for (const p of pend) p.reject(new Error('geo worker error'));
            };
            geoWorker = w;
            return w;
        } catch (_) { geoWorkerFailed = true; return null; }
    }

    function decodeViaWorker(kind, url) {
        return new Promise((resolve, reject) => {
            const w = getGeoWorker();
            if (!w) { reject(new Error('no geo worker')); return; }
            const seq = ++geoSeq;
            geoPending.set(seq, { resolve, reject });
            try { w.postMessage({ seq, kind, url }); }
            catch (_) { geoPending.delete(seq); reject(new Error('geo post failed')); }
        });
    }

    function decodeOnMain(kind, url) {
        return fetch(url, { cache: 'force-cache' })
            .then(r => r.ok ? r.json() : null)
            .then(json => (json && window.NymGeoDecode)
                ? window.NymGeoDecode.decodeByKind(kind, json)
                : []);
    }

    function loadFeatures(kind, url) {
        return decodeViaWorker(kind, url)
            .catch(() => decodeOnMain(kind, url))
            .catch(() => []);
    }

    let worldFeaturesPromise = null;
    function loadWorldFeatures() {
        if (!worldFeaturesPromise) worldFeaturesPromise = loadFeatures('world', WORLD_TOPO_URL);
        return worldFeaturesPromise;
    }

    let admin1FeaturesPromise = null;
    function loadAdmin1Features() {
        if (!admin1FeaturesPromise) admin1FeaturesPromise = loadFeatures('admin1', ADMIN1_GEOJSON_URL);
        return admin1FeaturesPromise;
    }

    let cityFeaturesPromise = null;
    function loadCityFeatures() {
        if (!cityFeaturesPromise) cityFeaturesPromise = loadFeatures('cities', CITIES_GEOJSON_URL);
        return cityFeaturesPromise;
    }

    const tierPromises = [null, null, null];
    function loadTier(t) {
        if (!tierPromises[t]) {
            tierPromises[t] = loadFeatures('tier', TIER_URLS[t])
                .then((g) => (g && g.countries) ? buildTierPaths(g) : null)
                .then((d) => { if (!d) tierPromises[t] = null; return d; }, () => { tierPromises[t] = null; return null; });
        }
        return tierPromises[t];
    }

    function partPath(layer, p) {
        const path = new Path2D();
        const c = layer.coords;
        for (let r = layer.partRing[p]; r < layer.partRing[p + 1]; r++) {
            const a = layer.ringOff[r], b = layer.ringOff[r + 1];
            if (b - a < 2) continue;
            let prev = c[a * 2];
            path.moveTo(prev, -c[a * 2 + 1]);
            for (let i = a + 1; i < b; i++) {
                const x = c[i * 2], y = -c[i * 2 + 1];
                if (Math.abs(x - prev) > 180) {
                    if (layer.closed) path.closePath();
                    path.moveTo(x, y);
                } else {
                    path.lineTo(x, y);
                }
                prev = x;
            }
            if (layer.closed) path.closePath();
        }
        return path;
    }

    function partCount(layer) { return layer.partRing.length - 1; }
    function partPoints(layer, p) { return layer.ringOff[layer.partRing[p + 1]] - layer.ringOff[layer.partRing[p]]; }

    function buildLayerPathsSync(layer) {
        const paths = [];
        for (let p = 0; p < partCount(layer); p++) paths.push(partPath(layer, p));
        return { layer, paths };
    }

    function buildLayerPaths(layer) {
        return new Promise((resolve) => {
            const paths = [];
            let p = 0;
            const n = partCount(layer);
            const slice = () => {
                const until = performance.now() + 6;
                while (p < n && performance.now() < until) { paths.push(partPath(layer, p)); p++; }
                if (p < n) setTimeout(slice, 0);
                else resolve({ layer, paths });
            };
            slice();
        });
    }

    async function buildTierPaths(g) {
        return {
            countries: await buildLayerPaths(g.countries),
            lakes: await buildLayerPaths(g.lakes),
            rivers: await buildLayerPaths(g.rivers),
            countryLabels: g.countryLabels || [],
        };
    }

    const featurePaths = new WeakMap();
    const openFeaturePaths = new WeakMap();
    function pathsForFeatures(features, closed) {
        if (!features || !features.length || !window.NymGeoDecode) return null;
        const cache = closed === false ? openFeaturePaths : featurePaths;
        let lp = cache.get(features);
        if (!lp) {
            lp = buildLayerPathsSync(window.NymGeoDecode.layerFromFeatures(features, closed !== false));
            cache.set(features, lp);
        }
        return lp;
    }

    const textWidths = new Map();
    function measureLabel(ctx, font, text) {
        const k = font + '|' + text;
        let w = textWidths.get(k);
        if (w === undefined) {
            if (textWidths.size > 3000) textWidths.clear();
            ctx.font = font;
            w = ctx.measureText(text).width;
            textWidths.set(k, w);
        }
        return w;
    }

    const cityOrder = new WeakMap();
    function citiesByPriority(cities) {
        let out = cityOrder.get(cities);
        if (!out) {
            out = cities.slice().sort((a, b) => (a.rank - b.rank) || ((b.pop || 0) - (a.pop || 0)));
            cityOrder.set(cities, out);
        }
        return out;
    }

    const GEOHASH_BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';

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

    function decodeGeohashBoundsRaw(geohash) {
        const bounds = { lat: [-90, 90], lng: [-180, 180] };
        let isEven = true;
        for (let i = 0; i < geohash.length; i++) {
            const cd = GEOHASH_BASE32.indexOf(geohash[i].toLowerCase());
            if (cd === -1) return null;
            for (let j = 4; j >= 0; j--) {
                const mask = 1 << j;
                if (isEven) {
                    if (cd & mask) bounds.lng[0] = (bounds.lng[0] + bounds.lng[1]) / 2;
                    else bounds.lng[1] = (bounds.lng[0] + bounds.lng[1]) / 2;
                } else {
                    if (cd & mask) bounds.lat[0] = (bounds.lat[0] + bounds.lat[1]) / 2;
                    else bounds.lat[1] = (bounds.lat[0] + bounds.lat[1]) / 2;
                }
                isEven = !isEven;
            }
        }
        return bounds;
    }

    const SVG = (body) => `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${body}</svg>`;
    const GX_ICONS = {
        search: SVG('<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>'),
        close: SVG('<path d="M6 6l12 12M18 6L6 18"/>'),
        plus: SVG('<path d="M12 5v14M5 12h14"/>'),
        minus: SVG('<path d="M5 12h14"/>'),
        locate: SVG('<circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/>'),
        layers: SVG('<path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/>'),
        globe: SVG('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>'),
        list: SVG('<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>'),
        star: SVG('<path d="M12 3l2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.3 6.4 20.2l1.1-6.2L3 9.6l6.2-.9L12 3z"/>'),
        share: SVG('<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="M8.6 13.5l6.8 4M15.4 6.5l-6.8 4"/>'),
    };

    const GX_FLY_MS = 650;
    const GX_SELECT_PULSE_MS = 900;
    const GX_AMBIENT_MS = 1600;
    const GX_RING_R = 9;
    const GX_SAVED_COLOR = '#f5c518';

    function gxReducedMotion() {
        try { return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches); }
        catch (_) { return false; }
    }

    function gxEase(t) {
        return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
    }

    let heatPalette = null;
    function getHeatPalette() {
        if (heatPalette) return heatPalette;
        const c = document.createElement('canvas');
        c.width = 256; c.height = 1;
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

    function getMapStyles() {
        const cs = getComputedStyle(document.body);
        const primary = (cs.getPropertyValue('--primary') || '#00ffff').trim() || '#00ffff';
        const warning = (cs.getPropertyValue('--warning') || '#ffcc00').trim() || '#ffcc00';
        const isLight = document.body.classList.contains('light-mode');
        return {
            primary,
            warning,
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
            lake: isLight ? '#d6e8f1' : '#0a131e',
            river: isLight ? 'rgba(90,150,190,0.7)' : 'rgba(70,120,160,0.55)',
            haloAlpha: isLight ? 0.18 : 0.32
        };
    }

Object.assign(NYM.prototype, {

    // Opens the explorer; with focusGeohash, zooms to that cell and opens its info panel.
    showGeohashExplorer(focusGeohash) {
        const modal = document.getElementById('geohashExplorerModal');
        if (!modal) return;
        modal.style.display = 'flex';
        const gh = (typeof focusGeohash === 'string' && this.isValidGeohash(focusGeohash))
            ? focusGeohash.toLowerCase() : null;
        setTimeout(() => {
            // initializeGeohashMap is async; the focus must wait for this.geohashMap.
            Promise.resolve(this.initializeGeohashMap()).then(() => {
                if (gh && typeof this._selectGeohashCell === 'function') {
                    this._selectGeohashCell(gh, { fly: false, pulse: true });
                }
            }).catch(() => { });
        }, 30);
        // Pull D1 activity counts so the globe reflects real activity without loading messages.
        if (typeof this.fetchGeohashActivityFromD1 === 'function') {
            this.fetchGeohashActivityFromD1();
        }
    },

    closeGeohashExplorer() {
        const modal = document.getElementById('geohashExplorerModal');
        if (modal) modal.style.display = 'none';

        if (this._geomapCleanup) {
            try { this._geomapCleanup(); } catch (_) {}
            this._geomapCleanup = null;
        }
        this.geohashMap = null;
    },

    async initializeGeohashMap() {
        const container = document.getElementById('geohashGlobeCanvas');
        if (!container) return;

        if (this._geomapCleanup) {
            try { this._geomapCleanup(); } catch (_) {}
            this._geomapCleanup = null;
        }
        container.innerHTML = '';

        const GX = window.NymGeoExplore;
        const L = (t) => (typeof this.uiText === 'function' ? this.uiText(t) : t);
        const esc = (t) => this.escapeHtml(String(t));
        const showYourLocation = this.settings && this.settings.sortByProximity && this.userLocation;

        this._geohashActiveWindowHours = GX.normalizeWindowHours(this._geohashActiveWindowHours);
        const activeHours = this._geohashActiveWindowHours;
        const windowGroup = this._gxWindowGroupHtml(activeHours, true);
        const icon = (name) => GX_ICONS[name] || '';
        const ctl = (id, action, label, ic, extra = '') =>
            `<button type="button" class="gx-ctl" id="${id}"${action ? ` data-action="${action}"` : ''} aria-label="${esc(L(label))}" title="${esc(L(label))}"${extra}>${icon(ic)}</button>`;

        container.insertAdjacentHTML('beforeend', `
<canvas id="geohashMapCanvas" class="geohash-map-canvas" aria-hidden="true"></canvas>

<div class="gx-search" id="gxSearch">
    <div class="gx-search-box nm-field">
        <span class="gx-search-icon" aria-hidden="true">${icon('search')}</span>
        <input id="gxSearchInput" class="gx-search-input" type="text" inputmode="search" enterkeyhint="search"
               autocomplete="off" spellcheck="false" placeholder="${esc(L('Search a place or geohash'))}"
               aria-label="${esc(L('Search a place or geohash'))}" role="combobox" aria-autocomplete="list"
               aria-expanded="false" aria-controls="gxSearchResults">
        <button type="button" class="gx-search-clear nm-hidden" id="gxSearchClear" aria-label="${esc(L('Clear search'))}" title="${esc(L('Clear search'))}">${icon('close')}</button>
    </div>
    <div class="gx-search-results nm-hidden" id="gxSearchResults" role="listbox" aria-label="${esc(L('Search results'))}"></div>
</div>

<div class="gx-controls" role="toolbar" aria-orientation="vertical" aria-label="${esc(L('Map controls'))}">
    ${ctl('gxZoomIn', 'zoomMapIn', 'Zoom in', 'plus')}
    ${ctl('gxZoomOut', 'zoomMapOut', 'Zoom out', 'minus')}
    ${ctl('gxLocationBtn', '', 'Your Location', 'locate', showYourLocation ? ' data-on="1"' : '')}
    <button type="button" class="gx-ctl gx-layers-btn" id="gxLayersBtn" aria-label="${esc(L('Layers'))}" title="${esc(L('Layers'))}" aria-haspopup="menu" aria-expanded="false" aria-controls="gxLayersMenu">${icon('layers')}<span class="gx-badge nm-hidden" aria-hidden="true"></span></button>
    ${ctl('gxResetBtn', 'resetGlobeView', 'Reset View', 'globe')}
    ${ctl('gxListsBtn', '', 'Rooms list', 'list', ' aria-expanded="false" aria-controls="gxLists"')}
</div>

<div class="gx-layers nm-hidden" id="gxLayers">
    <div id="gxLayersMenu" role="menu" aria-orientation="vertical" aria-label="${esc(L('Layers'))}">
    <button type="button" class="gx-layer-toggle" id="geohashHeatmapBtn" data-action="toggleHeatmap" role="menuitemcheckbox" aria-checked="false" tabindex="-1"><span class="gx-check" aria-hidden="true"></span>${esc(L('Heat'))}</button>
    <button type="button" class="gx-layer-toggle" id="geohashDaynightBtn" data-action="toggleDaynight" role="menuitemcheckbox" aria-checked="false" tabindex="-1"><span class="gx-check" aria-hidden="true"></span>${esc(L('Day / Night'))}</button>
    <button type="button" class="gx-layer-toggle" id="geohashGridBtn" data-action="toggleGeohashGrid" role="menuitemcheckbox" aria-checked="false" tabindex="-1"><span class="gx-check" aria-hidden="true"></span>${esc(L('Geohash grid'))}</button>
    <div class="gx-layers-row" role="none"><span aria-hidden="true">${esc(L('Activity'))}</span>${windowGroup}</div>
    </div>
    <div class="gx-legend" role="list" aria-label="${esc(L('Legend'))}">
        <div class="geohash-legend-item" role="listitem"><div class="geohash-legend-dot nm-geo-1" aria-hidden="true"></div><span>${esc(L('Active'))}</span></div>
        <div class="geohash-legend-item" role="listitem"><div class="geohash-legend-dot gx-dot-joined" aria-hidden="true"></div><span>${esc(L('Joined'))}</span></div>
        <div class="geohash-legend-item" role="listitem"><div class="geohash-legend-dot gx-dot-saved" aria-hidden="true"></div><span>${esc(L('Saved'))}</span></div>
        ${showYourLocation ? `<div class="geohash-legend-item" role="listitem"><div class="geohash-legend-dot nm-geo-2" aria-hidden="true"></div><span>${esc(L('Your Location'))}</span></div>` : ''}
        <div class="geohash-legend-item gx-legend-cluster" role="listitem"><span class="gx-swatch gx-swatch-cluster" aria-hidden="true">3</span><span>${esc(L('Number = rooms grouped together'))}</span></div>
        <div class="geohash-legend-item gx-legend-pulse" role="listitem"><span class="gx-swatch gx-swatch-pulse" aria-hidden="true"></span><span>${esc(L('Pulsing = active in the last {n} minutes').replace('{n}', String(Math.round(GX.PULSE_WINDOW_MS / 60000))))}</span></div>
    </div>
</div>

<div class="gx-lists nm-hidden" id="gxLists">
    <div class="gx-tabs" role="tablist" aria-label="${esc(L('Rooms'))}">
        <button type="button" class="gx-tab" role="tab" id="gxTabActive" data-tab="active" aria-selected="true">${esc(L('Active now'))}</button>
        <button type="button" class="gx-tab" role="tab" id="gxTabNearby" data-tab="nearby" aria-selected="false">${esc(L('Nearby'))}</button>
        <button type="button" class="gx-tab" role="tab" id="gxTabSaved" data-tab="saved" aria-selected="false">${esc(L('Saved'))}</button>
    </div>
    <div class="gx-lists-body" id="gxListsBody" role="tabpanel"></div>
</div>

<div class="geohash-info-panel nm-hidden" id="geohashInfoPanel" role="region" aria-labelledby="geohashInfoTitle">
    <div class="gx-info-head">
        <div class="geohash-info-title" id="geohashInfoTitle">Channel Info</div>
        <button type="button" class="gx-icon-btn" id="gxSaveBtn" aria-pressed="false" aria-label="${esc(L('Save place'))}" title="${esc(L('Save place'))}">${icon('star')}</button>
        <button type="button" class="gx-icon-btn" id="gxShareBtn" aria-label="${esc(L('Share place'))}" title="${esc(L('Share place'))}">${icon('share')}</button>
        <button type="button" class="gx-icon-btn geohash-info-close" id="geohashInfoClose" data-action="closeGeohashInfo" aria-label="${esc(L('Close'))}" title="${esc(L('Close'))}">${icon('close')}</button>
    </div>
    <div class="gx-info-scroll">
        <div id="geohashInfoContent"></div>
        <div class="gx-precision" id="gxPrecision"></div>
        <div class="gx-peek" id="gxPeek" aria-live="polite"></div>
    </div>
    <button type="button" class="geohash-join-btn" id="geohashJoinBtn">Join Channel</button>
</div>
`);

        this.updateGeohashChannels();

        const canvas = container.querySelector('#geohashMapCanvas');
        const ctx = canvas.getContext('2d');

        let dpr = GX.capDpr(window.devicePixelRatio || 1);

        const view = { cx: 0, cy: 0, zoom: 1, minZoom: 1, maxZoom: 16 };

        let cssWidth = container.clientWidth || 1;
        let cssHeight = container.clientHeight || 1;

        const resizeCanvas = () => {
            dpr = GX.capDpr(window.devicePixelRatio || 1);
            cssWidth = Math.max(1, container.clientWidth);
            cssHeight = Math.max(1, container.clientHeight);
            canvas.width = Math.floor(cssWidth * dpr);
            canvas.height = Math.floor(cssHeight * dpr);
            canvas.style.width = cssWidth + 'px';
            canvas.style.height = cssHeight + 'px';
            ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        };
        resizeCanvas();

        const baseScale = () => Math.max(cssWidth / 360, cssHeight / 180);

        const project = (lng, lat) => {
            const s = baseScale() * view.zoom;
            return {
                x: (lng - view.cx) * s + cssWidth / 2,
                y: (view.cy - lat) * s + cssHeight / 2
            };
        };
        const unproject = (x, y) => {
            const s = baseScale() * view.zoom;
            return {
                lng: (x - cssWidth / 2) / s + view.cx,
                lat: view.cy - (y - cssHeight / 2) / s
            };
        };

        const clampView = () => {
            if (view.zoom < view.minZoom) view.zoom = view.minZoom;
            if (view.zoom > view.maxZoom) view.zoom = view.maxZoom;
            const s = baseScale() * view.zoom;
            const halfLng = (cssWidth / 2) / s;
            const halfLat = (cssHeight / 2) / s;
            if (halfLng >= 180) view.cx = 0;
            else view.cx = Math.max(-180 + halfLng, Math.min(180 - halfLng, view.cx));
            if (halfLat >= 90) view.cy = 0;
            else view.cy = Math.max(-90 + halfLat, Math.min(90 - halfLat, view.cy));
        };

        let features = [];
        let admin1Features = [];
        let cityFeatures = [];
        let admin1Loaded = false;
        let citiesLoaded = false;
        let drawScheduled = false;
        let heatmapMode = !!this._heatmapPreference;
        let daynightMode = !!this._daynightPreference;
        let geohashGridMode = !!this._geohashGridPreference;
        let styles = getMapStyles();

        const tierData = [null, null, null];
        const wantTier = () => GX.tierFor(baseScale() * view.zoom);
        const activeTier = () => {
            let t = wantTier();
            while (t > 0 && !tierData[t]) t--;
            return t;
        };
        const ensureTier = () => {
            const t = wantTier();
            if (t < 1 || tierData[t] || tierRequested.has(t)) return;
            tierRequested.add(t);
            loadTier(t).then((d) => {
                if (!d) { tierRequested.delete(t); return; }
                tierData[t] = d;
                requestDraw();
            });
        };
        const tierRequested = new Set();

        const ensureSubregions = () => {
            ensureTier();
            if (view.zoom >= ADMIN1_ZOOM_THRESHOLD && !admin1Loaded) {
                admin1Loaded = true;
                loadAdmin1Features().then(feats => {
                    admin1Features = feats;
                    requestDraw();
                });
            }
            if (view.zoom >= CITY_ZOOM_THRESHOLD && !citiesLoaded) {
                citiesLoaded = true;
                loadCityFeatures().then(feats => {
                    cityFeatures = feats;
                    requestDraw();
                });
            }
        };

        const HEAT_SCALE = 0.5;
        let heatCanvas = null, heatCtx = null;
        const ensureHeatCanvas = () => {
            const w = Math.max(1, Math.floor(cssWidth * HEAT_SCALE * dpr));
            const h = Math.max(1, Math.floor(cssHeight * HEAT_SCALE * dpr));
            if (!heatCanvas) {
                heatCanvas = document.createElement('canvas');
                heatCtx = heatCanvas.getContext('2d');
            }
            if (heatCanvas.width !== w || heatCanvas.height !== h) {
                heatCanvas.width = w;
                heatCanvas.height = h;
            }
        };

        const updateLayersBtn = () => this._gxSyncLayersBtn();

        const updateHeatmapButton = () => {
            const btn = document.getElementById('geohashHeatmapBtn');
            if (btn) { btn.classList.toggle('active', heatmapMode); btn.setAttribute('aria-checked', heatmapMode ? 'true' : 'false'); }
            updateLayersBtn();
        };
        updateHeatmapButton();

        const updateDaynightButton = () => {
            const btn = document.getElementById('geohashDaynightBtn');
            if (btn) { btn.classList.toggle('active', daynightMode); btn.setAttribute('aria-checked', daynightMode ? 'true' : 'false'); }
            updateLayersBtn();
        };
        updateDaynightButton();

        const updateGeohashGridButton = () => {
            const btn = document.getElementById('geohashGridBtn');
            if (btn) { btn.classList.toggle('active', geohashGridMode); btn.setAttribute('aria-checked', geohashGridMode ? 'true' : 'false'); }
            updateLayersBtn();
        };
        updateGeohashGridButton();

        const computeGridPrecision = () => {
            const s = baseScale() * view.zoom;
            let p = 1;
            while (p < 9) {
                const next = geohashCellSize(p + 1);
                if (next.lngStep * s < 50) break;
                p++;
            }
            return p;
        };

        const drawGeohashGrid = () => {
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

            const isLight = document.body.classList.contains('light-mode');
            const lineColor = isLight ? 'rgba(0, 100, 140, 0.45)' : 'rgba(0, 220, 255, 0.35)';
            const fillColor = isLight ? 'rgba(0, 140, 180, 0.04)' : 'rgba(0, 220, 255, 0.04)';
            const labelColor = isLight ? 'rgba(20, 30, 45, 0.85)' : 'rgba(220, 240, 255, 0.92)';
            const labelStroke = isLight ? 'rgba(255,255,255,0.85)' : 'rgba(0,0,0,0.7)';

            ctx.save();
            ctx.lineWidth = 1;
            ctx.strokeStyle = lineColor;
            ctx.fillStyle = fillColor;
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
                ctx.font = `600 ${fontSize}px var(--font-sans, system-ui, sans-serif)`;
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
                        ctx.strokeStyle = labelStroke;
                        ctx.strokeText(gh, p.x, p.y);
                        ctx.fillStyle = labelColor;
                        ctx.fillText(gh, p.x, p.y);
                    }
                }
            }
            ctx.restore();
        };

        const findGeohashAt = (x, y) => {
            const precision = computeGridPrecision();
            const u = unproject(x, y);
            if (u.lat < -90 || u.lat > 90 || u.lng < -180 || u.lng > 180) return null;
            return encodeGeohashRaw(u.lat, u.lng, precision);
        };

        const viewBox = (padPx) => {
            const sc = baseScale() * view.zoom;
            const hw = (cssWidth / 2 + padPx) / sc, hh = (cssHeight / 2 + padPx) / sc;
            return { lngLo: view.cx - hw, lngHi: view.cx + hw, latLo: view.cy - hh, latHi: view.cy + hh, s: sc };
        };
        const partVisible = (layer, p, vb) => {
            const o = p * 4, bb = layer.bbox;
            if (bb[o + 2] < vb.lngLo || bb[o] > vb.lngHi || bb[o + 3] < vb.latLo || bb[o + 1] > vb.latHi) return false;
            return (bb[o + 2] - bb[o]) * vb.s >= MIN_PART_PX || (bb[o + 3] - bb[o + 1]) * vb.s >= MIN_PART_PX;
        };
        const layerStats = (layer) => {
            if (!layer) return { verts: 0, len: 0, segs: 0 };
            const vb = viewBox(0);
            let verts = 0, len = 0, segs = 0;
            for (let p = 0; p < partCount(layer); p++) {
                if (!partVisible(layer, p, vb)) continue;
                const n = partPoints(layer, p);
                verts += n;
                len += layer.partLen[p];
                segs += n - (layer.partRing[p + 1] - layer.partRing[p]);
            }
            return { verts, len, segs };
        };
        const withWorld = (body) => {
            const sc = baseScale() * view.zoom;
            ctx.save();
            ctx.setTransform(dpr * sc, 0, 0, dpr * sc, dpr * (cssWidth / 2 - view.cx * sc), dpr * (cssHeight / 2 + view.cy * sc));
            ctx.lineJoin = 'round';
            body(sc);
            ctx.restore();
        };
        const drawLayer = (lp, opts) => {
            const vb = viewBox(2);
            const layer = lp.layer;
            let lw = -1;
            for (let p = 0; p < partCount(layer); p++) {
                if (!partVisible(layer, p, vb)) continue;
                const path = lp.paths[p];
                if (opts.fill) ctx.fill(path, 'evenodd');
                if (opts.width) {
                    const w = typeof opts.width === 'function' ? opts.width(layer.partRank[p]) : opts.width;
                    if (w !== lw) { ctx.lineWidth = w; lw = w; }
                    ctx.stroke(path);
                }
            }
        };
        const tierLayers = () => {
            const t = activeTier();
            return t > 0 ? tierData[t] : (features.length ? { countries: pathsForFeatures(features, true) } : null);
        };

        const drawWorld = () => {
            const td = tierLayers();
            if (!td || !td.countries) return;
            withWorld((sc) => {
                ctx.fillStyle = styles.land;
                ctx.strokeStyle = styles.border;
                drawLayer(td.countries, { fill: true, width: 0.5 / sc });
                if (!td.lakes) return;
                ctx.fillStyle = styles.lake;
                ctx.globalAlpha = 1;
                ctx.strokeStyle = styles.border;
                drawLayer(td.lakes, { fill: true, width: 0.4 / sc });
                ctx.strokeStyle = styles.river;
                ctx.lineCap = 'round';
                drawLayer(td.rivers, { width: (rank) => (rank <= 2 ? 0.9 : 0.6) / sc });
            });
        };

        const drawGraticule = () => {
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
        };

        const inView = (p, pad) => p.x >= -pad && p.x <= cssWidth + pad && p.y >= -pad && p.y <= cssHeight + pad;

        const drawAdmin1 = () => {
            if (view.zoom < ADMIN1_ZOOM_THRESHOLD || !admin1Features.length) return;
            const fadeStart = ADMIN1_ZOOM_THRESHOLD;
            const fadeEnd = fadeStart + 1.5;
            const t = Math.min(1, Math.max(0, (view.zoom - fadeStart) / (fadeEnd - fadeStart)));
            if (t <= 0) return;
            const lp = pathsForFeatures(admin1Features, false);
            if (!lp) return;
            withWorld((sc) => {
                ctx.strokeStyle = styles.adminBorder;
                ctx.globalAlpha = t;
                drawLayer(lp, { width: 0.4 / sc });
            });
        };

        let lastLabels = [];
        let lastOccupied = [];
        const occupiedRects = () => {
            const c = canvas.getBoundingClientRect();
            const out = [];
            for (const el of [container.querySelector('#gxSearch'), container.querySelector('.gx-controls')]) {
                if (!el || el.offsetParent === null) continue;
                const r = el.getBoundingClientRect();
                if (r.width <= 0 || r.height <= 0) continue;
                out.push({ x0: r.left - c.left, y0: r.top - c.top, x1: r.right - c.left, y1: r.bottom - c.top });
            }
            lastOccupied = out;
            return out;
        };
        const FONT = (w, px) => `${w} ${px}px var(--font-sans, system-ui, sans-serif)`;
        const layoutLabels = () => {
            const cands = [];
            const add = (text, kind, p, px, weight, color, halo, center) => {
                const font = FONT(weight, px);
                const w = measureLabel(ctx, font, text);
                const h = px * 1.2;
                const box = center
                    ? { x0: p.x - w / 2 - 1, y0: p.y - h / 2, x1: p.x + w / 2 + 1, y1: p.y + h / 2 }
                    : { x0: p.x - 2.5, y0: p.y - h / 2, x1: p.x + 4 + w + 1, y1: p.y + h / 2 };
                const fit = GX.fitLabelBox(box, { anchorX: p.x, side: !center, width: cssWidth, height: cssHeight });
                if (!fit) return;
                cands.push({ text, kind, x: p.x, y: p.y, font, color, halo, center, box: fit, flipped: fit.flipped });
            };
            const t = activeTier();
            const countryFeats = (t > 0 && tierData[t] && tierData[t].countryLabels) || features;
            for (const f of countryFeats) {
                if (!f.name) continue;
                const bb = f.bounds;
                const a = project(bb[0], bb[3]);
                const b = project(bb[2], bb[1]);
                const span = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y));
                if (span < Math.max(28, f.name.length * 5)) continue;
                const p = project(f.centroid[0], f.centroid[1]);
                if (!inView(p, 0)) continue;
                add(f.name, 'country', p, 11, 600, styles.label, 3, true);
            }
            if (!heatmapMode && view.zoom >= 3 && cityFeatures.length) {
                const cutoff = GX.cityRankCutoff(view.zoom);
                for (const c of citiesByPriority(cityFeatures)) {
                    if (c.rank > cutoff) break;
                    if (!c.name) continue;
                    const p = project(c.lng, c.lat);
                    if (!inView(p, 0)) continue;
                    const big = c.rank <= 2;
                    add(c.name, 'city', p, big ? 10 : 9, big ? 600 : 500, styles.cityLabel, 2.5, false);
                }
            }
            if (view.zoom >= 4) {
                for (const f of admin1Features) {
                    if (!f.name) continue;
                    const bb = f.bounds;
                    const a = project(bb[0], bb[3]);
                    const b = project(bb[2], bb[1]);
                    const span = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y));
                    if (span < Math.max(40, f.name.length * 5.5)) continue;
                    const p = project(f.centroid[0], f.centroid[1]);
                    if (!inView(p, 0)) continue;
                    add(f.name, 'admin1', p, 9, 500, styles.adminLabel, 2.5, true);
                }
            }
            return GX.placeLabels(cands.map((c) => c.box), GX.LABEL_PAD, occupiedRects()).map((i) => cands[i]);
        };

        const drawPlaceLabels = () => {
            if (!heatmapMode && view.zoom >= CITY_ZOOM_THRESHOLD && view.zoom < 3 && cityFeatures.length) {
                const cutoff = GX.cityRankCutoff(view.zoom);
                ctx.fillStyle = styles.cityDot;
                for (const city of cityFeatures) {
                    if (city.rank > cutoff) break;
                    const p = project(city.lng, city.lat);
                    if (!inView(p, 4)) continue;
                    ctx.beginPath();
                    ctx.arc(p.x, p.y, 1.5, 0, Math.PI * 2);
                    ctx.fill();
                }
            }
            const labels = layoutLabels();
            lastLabels = labels;
            ctx.textBaseline = 'middle';
            ctx.lineJoin = 'round';
            for (const l of labels) {
                ctx.font = l.font;
                ctx.lineWidth = l.halo;
                ctx.strokeStyle = styles.labelStroke;
                const ty = (l.box.y0 + l.box.y1) / 2;
                if (l.center) {
                    const tx = (l.box.x0 + l.box.x1) / 2;
                    ctx.textAlign = 'center';
                    ctx.strokeText(l.text, tx, ty);
                    ctx.fillStyle = l.color;
                    ctx.fillText(l.text, tx, ty);
                } else {
                    ctx.beginPath();
                    ctx.arc(l.x, l.y, 1.5, 0, Math.PI * 2);
                    ctx.fillStyle = styles.cityDot;
                    ctx.fill();
                    const tx = l.flipped ? l.x - 4 : l.x + 4;
                    ctx.textAlign = l.flipped ? 'right' : 'left';
                    ctx.strokeText(l.text, tx, ty);
                    ctx.fillStyle = l.color;
                    ctx.fillText(l.text, tx, ty);
                }
            }
        };

        const drawDaynight = () => {
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
            ctx.fillStyle = document.body.classList.contains('light-mode')
                ? 'rgba(20, 30, 55, 0.28)'
                : 'rgba(2, 6, 16, 0.5)';
            ctx.beginPath();
            ctx.moveTo(points[0].x, points[0].y);
            for (let i = 1; i < points.length; i++) {
                ctx.lineTo(points[i].x, points[i].y);
            }
            const last = points[points.length - 1];
            ctx.lineTo(last.x, yEdge);
            ctx.lineTo(points[0].x, yEdge);
            ctx.closePath();
            ctx.fill();

            ctx.beginPath();
            ctx.moveTo(points[0].x, points[0].y);
            for (let i = 1; i < points.length; i++) {
                ctx.lineTo(points[i].x, points[i].y);
            }
            ctx.strokeStyle = document.body.classList.contains('light-mode')
                ? 'rgba(40, 60, 100, 0.45)'
                : 'rgba(180, 200, 230, 0.35)';
            ctx.lineWidth = 1;
            ctx.stroke();
            ctx.restore();
        };

        const drawHeatmap = () => {
            const channels = this.geohashChannels || [];
            if (!channels.length) return;

            ensureHeatCanvas();
            const palette = getHeatPalette();
            const w = heatCanvas.width, h = heatCanvas.height;

            heatCtx.globalCompositeOperation = 'source-over';
            heatCtx.clearRect(0, 0, w, h);
            heatCtx.globalCompositeOperation = 'lighter';

            const baseRadius = Math.max(22, Math.min(70, 24 + view.zoom * 3.5));
            const hs = HEAT_SCALE * dpr;
            const radius = baseRadius * hs;

            let maxMsg = 1;
            for (const ch of channels) if (ch.messages > maxMsg) maxMsg = ch.messages;
            const denom = Math.log(maxMsg + 1) || 1;

            for (const ch of channels) {
                const p = project(ch.lng, ch.lat);
                const sx = p.x * hs, sy = p.y * hs;
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
            ctx.imageSmoothingQuality = 'low';
            ctx.drawImage(heatCanvas, 0, 0, cssWidth, cssHeight);
            ctx.imageSmoothingEnabled = false;

            if (hoveredChannel) {
                const p = project(hoveredChannel.lng, hoveredChannel.lat);
                if (inView(p, 12)) {
                    ctx.beginPath();
                    ctx.arc(p.x, p.y, 6, 0, Math.PI * 2);
                    ctx.strokeStyle = '#ffffff';
                    ctx.lineWidth = 2;
                    ctx.stroke();
                }
            }
        };

        let selectPulseStart = 0;
        let ambientOn = false;
        let rafAnim = 0;
        let fly = null;

        const currentClusters = () => {
            if (heatmapMode || view.zoom >= GX.CLUSTER_MAX_ZOOM) return [];
            const pts = (this.geohashChannels || []).map((c) => {
                const p = project(c.lng, c.lat);
                return { id: c.geohash, x: p.x, y: p.y, messages: c.messages };
            });
            return GX.clusterPoints(pts, GX.CLUSTER_CELL_PX);
        };

        const savedSet = () => {
            const out = new Set();
            for (const k of (this.pinnedChannels || [])) {
                const g = String(k).toLowerCase();
                if (g !== 'nymchat' && GX.isValidGeohash(g)) out.add(g);
            }
            return out;
        };

        const recentSet = () => {
            const now = Date.now();
            const out = new Set();
            for (const c of (this.geohashChannels || [])) if (GX.isRecent(c.lastActivityMs || 0, now)) out.add(c.geohash);
            return out;
        };

        const drawSaved = () => {
            const saved = savedSet();
            if (!saved.size) return;
            for (const gh of saved) {
                const b = GX.cellBounds(gh);
                if (!b) continue;
                const p = project((b.lngLo + b.lngHi) / 2, (b.latLo + b.latHi) / 2);
                if (!inView(p, 12)) continue;
                ctx.beginPath();
                ctx.arc(p.x, p.y, 7, 0, Math.PI * 2);
                ctx.lineWidth = 4;
                ctx.strokeStyle = 'rgba(0,0,0,0.55)';
                ctx.stroke();
                ctx.lineWidth = 2;
                ctx.strokeStyle = GX_SAVED_COLOR;
                ctx.stroke();
            }
        };

        const drawRecent = (t) => {
            if (t === null) return;
            const recent = recentSet();
            if (!recent.size) return;
            ctx.save();
            ctx.lineWidth = 2;
            ctx.strokeStyle = styles.primary;
            ctx.globalAlpha = (1 - t) * 0.6;
            for (const ch of (this.geohashChannels || [])) {
                if (!recent.has(ch.geohash)) continue;
                const p = project(ch.lng, ch.lat);
                if (!inView(p, 24)) continue;
                ctx.beginPath();
                ctx.arc(p.x, p.y, 5 + 13 * t, 0, Math.PI * 2);
                ctx.stroke();
            }
            ctx.restore();
        };

        const drawSelected = (pulseT) => {
            const sel = this._gxSelected;
            if (!sel) return;
            const b = GX.cellBounds(sel);
            if (!b) return;
            const tl = project(b.lngLo, b.latHi);
            const br = project(b.lngHi, b.latLo);
            const w = br.x - tl.x, h = br.y - tl.y;
            ctx.save();
            if (w >= 16 && h >= 12) {
                ctx.globalAlpha = 0.08;
                ctx.fillStyle = styles.primary;
                ctx.fillRect(tl.x, tl.y, w, h);
                ctx.globalAlpha = 0.7;
                ctx.lineWidth = 1.5;
                ctx.strokeStyle = styles.primary;
                ctx.strokeRect(tl.x, tl.y, w, h);
                ctx.globalAlpha = 1;
            }
            const p = project((b.lngLo + b.lngHi) / 2, (b.latLo + b.latHi) / 2);
            if (inView(p, 40)) {
                if (pulseT !== null) {
                    ctx.globalAlpha = (1 - pulseT) * 0.8;
                    ctx.lineWidth = 2;
                    ctx.strokeStyle = styles.primary;
                    ctx.beginPath();
                    ctx.arc(p.x, p.y, GX_RING_R + 22 * pulseT, 0, Math.PI * 2);
                    ctx.stroke();
                    ctx.globalAlpha = 1;
                }
                const ring = (color, width) => {
                    ctx.beginPath();
                    ctx.arc(p.x, p.y, GX_RING_R, 0, Math.PI * 2);
                    ctx.lineWidth = width;
                    ctx.strokeStyle = color;
                    ctx.stroke();
                };
                ring('rgba(0,0,0,0.6)', 5.5);
                ring('rgba(255,255,255,0.9)', 3.5);
                ring(styles.primary, 2);
            }
            ctx.restore();
        };

        const drawClusterMarker = (k) => {
            const r = 12 + Math.min(6, Math.log2(k.count) * 2);
            ctx.beginPath();
            ctx.arc(k.x, k.y, r + 2, 0, Math.PI * 2);
            ctx.fillStyle = 'rgba(0,0,0,0.55)';
            ctx.fill();
            ctx.beginPath();
            ctx.arc(k.x, k.y, r, 0, Math.PI * 2);
            ctx.globalAlpha = 0.9;
            ctx.fillStyle = styles.primary;
            ctx.fill();
            ctx.globalAlpha = 1;
            ctx.font = '700 11px var(--font-sans, system-ui, sans-serif)';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillStyle = '#000000';
            ctx.fillText(String(k.count), k.x, k.y);
        };

        const drawChannels = () => {
            const baseR = 4;
            const channels = this.geohashChannels || [];
            const hidden = new Set();
            for (const k of currentClusters()) {
                if (k.count < 2) continue;
                for (const id of k.ids) hidden.add(id);
                if (inView({ x: k.x, y: k.y }, 24)) drawClusterMarker(k);
            }

            for (const ch of channels) {
                if (hidden.has(ch.geohash)) continue;
                const p = project(ch.lng, ch.lat);
                if (!inView(p, 12)) continue;
                const isHover = hoveredChannel && hoveredChannel.geohash === ch.geohash;
                const r = isHover ? baseR + 2 : baseR;
                const color = ch.isJoined ? styles.joined : styles.primary;

                ctx.beginPath();
                ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
                ctx.fillStyle = color;
                ctx.fill();
                ctx.strokeStyle = 'rgba(0,0,0,0.55)';
                ctx.lineWidth = 1;
                ctx.stroke();
            }
        };

        const drawUserLocation = () => {
            if (this.userLocation) {
                const p = project(this.userLocation.lng, this.userLocation.lat);
                if (inView(p, 10)) {
                    ctx.beginPath();
                    ctx.arc(p.x, p.y, 5.5, 0, Math.PI * 2);
                    ctx.fillStyle = styles.warning;
                    ctx.fill();
                    ctx.strokeStyle = 'rgba(0,0,0,0.6)';
                    ctx.lineWidth = 1.2;
                    ctx.stroke();
                }
            }
        };

        const animState = () => {
            const reduced = gxReducedMotion();
            const now = performance.now();
            let pulseT = null;
            if (!reduced && selectPulseStart) {
                const e = now - selectPulseStart;
                if (e < GX_SELECT_PULSE_MS * 2) pulseT = (e % GX_SELECT_PULSE_MS) / GX_SELECT_PULSE_MS;
                else selectPulseStart = 0;
            }
            ambientOn = !reduced && !heatmapMode && recentSet().size > 0;
            const ambientT = ambientOn ? (now % GX_AMBIENT_MS) / GX_AMBIENT_MS : null;
            return { pulseT, ambientT };
        };

        let legendKey = '';
        const syncLegend = () => {
            const clusters = !heatmapMode && view.zoom < GX.CLUSTER_MAX_ZOOM;
            const pulses = !heatmapMode && !gxReducedMotion();
            const key = `${clusters}|${pulses}`;
            if (key === legendKey) return;
            legendKey = key;
            const c = document.querySelector('#gxLayers .gx-legend-cluster');
            const p = document.querySelector('#gxLayers .gx-legend-pulse');
            if (c) c.classList.toggle('nm-hidden', !clusters);
            if (p) p.classList.toggle('nm-hidden', !pulses);
        };

        const draw = () => {
            drawScheduled = false;
            stepFly();
            const anim = animState();
            this._gxAnim = anim;
            syncLegend();

            ctx.fillStyle = styles.ocean;
            ctx.fillRect(0, 0, cssWidth, cssHeight);

            drawGraticule();
            drawWorld();
            drawAdmin1();
            drawPlaceLabels();
            if (heatmapMode) {
                drawHeatmap();
            } else {
                drawSaved();
                drawRecent(anim.ambientT);
                drawChannels();
            }
            if (daynightMode) drawDaynight();
            if (geohashGridMode) drawGeohashGrid();
            drawSelected(anim.pulseT);
            drawUserLocation();
            if ((anim.pulseT !== null || anim.ambientT !== null || fly) && !rafAnim) {
                drawScheduled = true;
                rafAnim = requestAnimationFrame(() => { rafAnim = 0; draw(); });
            }
        };

        const stepFly = () => {
            if (!fly) return;
            const t = Math.min(1, (performance.now() - fly.start) / GX_FLY_MS);
            const e = gxEase(t);
            view.cx = fly.from.cx + (fly.to.cx - fly.from.cx) * e;
            view.cy = fly.from.cy + (fly.to.cy - fly.from.cy) * e;
            view.zoom = Math.exp(Math.log(fly.from.zoom) + (Math.log(fly.to.zoom) - Math.log(fly.from.zoom)) * e);
            clampView();
            if (t >= 1) { fly = null; ensureSubregions(); }
        };

        const targetForBounds = (bounds, padding = 0.7) => {
            const lngSpan = Math.max(1e-6, bounds.lng[1] - bounds.lng[0]);
            const latSpan = Math.max(1e-6, bounds.lat[1] - bounds.lat[0]);
            const s = baseScale();
            const z = Math.min((cssWidth * padding) / (lngSpan * s), (cssHeight * padding) / (latSpan * s));
            return {
                cx: (bounds.lng[0] + bounds.lng[1]) / 2,
                cy: (bounds.lat[0] + bounds.lat[1]) / 2,
                zoom: Math.max(view.minZoom, Math.min(view.maxZoom, z)),
            };
        };

        const flyTo = (target, animate) => {
            if (!animate || gxReducedMotion()) {
                fly = null;
                view.cx = target.cx; view.cy = target.cy; view.zoom = target.zoom;
                clampView();
                ensureSubregions();
                requestDraw();
                return;
            }
            fly = { from: { cx: view.cx, cy: view.cy, zoom: view.zoom }, to: target, start: performance.now() };
            requestDraw();
        };

        const requestDraw = () => {
            if (drawScheduled) return;
            drawScheduled = true;
            requestAnimationFrame(draw);
        };
        const offThemeChange = this.onThemeChange(() => {
            styles = getMapStyles();
            requestDraw();
        });

        let hoveredChannel = null;
        let dragging = false;
        let dragStart = null;
        let dragOriginCenter = null;
        let movedDistance = 0;
        const CLICK_THRESHOLD = 5;

        const findChannelAt = (x, y) => {
            const hitR = 10;
            let nearest = null;
            let best = Infinity;
            const channels = this.geohashChannels || [];
            for (const ch of channels) {
                const p = project(ch.lng, ch.lat);
                const d = Math.hypot(p.x - x, p.y - y);
                if (d < hitR && d < best) { best = d; nearest = ch; }
            }
            return nearest;
        };

        const onPointerDown = (e) => {
            if (e.pointerType === 'touch' && e.isPrimary === false) return;
            try { canvas.setPointerCapture(e.pointerId); } catch (_) {}
            fly = null;
            dragging = true;
            movedDistance = 0;
            dragStart = { x: e.clientX, y: e.clientY };
            dragOriginCenter = { cx: view.cx, cy: view.cy };
            canvas.style.cursor = 'grabbing';
        };

        const onPointerMove = (e) => {
            const rect = canvas.getBoundingClientRect();
            const localX = e.clientX - rect.left;
            const localY = e.clientY - rect.top;

            if (!dragging) {
                const ch = findChannelAt(localX, localY);
                if (ch !== hoveredChannel) {
                    hoveredChannel = ch;
                    canvas.style.cursor = ch ? 'pointer' : 'grab';
                    requestDraw();
                }
                return;
            }

            const dx = e.clientX - dragStart.x;
            const dy = e.clientY - dragStart.y;
            movedDistance += Math.abs(dx) + Math.abs(dy);

            const s = baseScale() * view.zoom;
            view.cx = dragOriginCenter.cx - dx / s;
            view.cy = dragOriginCenter.cy + dy / s;
            clampView();
            requestDraw();
        };

        const onPointerUp = (e) => {
            const wasDrag = movedDistance > CLICK_THRESHOLD;
            const wasDown = dragging;
            dragging = false;
            try { canvas.releasePointerCapture(e.pointerId); } catch (_) {}
            canvas.style.cursor = hoveredChannel ? 'pointer' : 'grab';

            if (!wasDown || wasDrag) return;

            const rect = canvas.getBoundingClientRect();
            const localX = e.clientX - rect.left;
            const localY = e.clientY - rect.top;
            if (this._gxLayersOpen) { this._gxToggleLayers(false); return; }
            const cluster = currentClusters().find((k) => k.count > 1 && Math.hypot(k.x - localX, k.y - localY) <= 22);
            if (cluster) {
                const bs = cluster.ids.map((id) => GX.cellBounds(id)).filter(Boolean);
                const bounds = {
                    lat: [Math.min(...bs.map((b) => b.latLo)), Math.max(...bs.map((b) => b.latHi))],
                    lng: [Math.min(...bs.map((b) => b.lngLo)), Math.max(...bs.map((b) => b.lngHi))],
                };
                const t = targetForBounds(bounds, 0.5);
                if (t.zoom <= view.zoom) t.zoom = Math.min(view.maxZoom, GX.CLUSTER_MAX_ZOOM + 0.5);
                flyTo(t, true);
                return;
            }
            const ch = findChannelAt(localX, localY);
            if (ch && typeof this.selectGeohashChannel === 'function') {
                this.selectGeohashChannel(ch);
                return;
            }
            if (geohashGridMode) {
                const gh = findGeohashAt(localX, localY);
                if (gh) this._selectGeohashCell(gh, { fly: false, pulse: false });
            }
        };

        const onWheel = (e) => {
            e.preventDefault();
            const rect = canvas.getBoundingClientRect();
            const px = e.clientX - rect.left;
            const py = e.clientY - rect.top;
            const before = unproject(px, py);
            const factor = Math.exp(-e.deltaY * 0.0015);
            view.zoom = Math.max(view.minZoom, Math.min(view.maxZoom, view.zoom * factor));
            const after = unproject(px, py);
            view.cx += (before.lng - after.lng);
            view.cy += (before.lat - after.lat);
            clampView();
            ensureSubregions();
            requestDraw();
        };

        let pinch = null;
        const onTouchStart = (e) => {
            if (e.touches.length === 2) {
                const t0 = e.touches[0], t1 = e.touches[1];
                const dx = t0.clientX - t1.clientX;
                const dy = t0.clientY - t1.clientY;
                pinch = {
                    dist: Math.hypot(dx, dy) || 1,
                    zoom: view.zoom,
                    midX: (t0.clientX + t1.clientX) / 2,
                    midY: (t0.clientY + t1.clientY) / 2
                };
                dragging = false;
            }
        };
        const onTouchMove = (e) => {
            if (e.touches.length === 2 && pinch) {
                e.preventDefault();
                const t0 = e.touches[0], t1 = e.touches[1];
                const dx = t0.clientX - t1.clientX;
                const dy = t0.clientY - t1.clientY;
                const newDist = Math.hypot(dx, dy) || 1;
                const rect = canvas.getBoundingClientRect();
                const px = pinch.midX - rect.left, py = pinch.midY - rect.top;
                const before = unproject(px, py);
                view.zoom = Math.max(view.minZoom, Math.min(view.maxZoom, pinch.zoom * (newDist / pinch.dist)));
                const after = unproject(px, py);
                view.cx += (before.lng - after.lng);
                view.cy += (before.lat - after.lat);
                clampView();
                ensureSubregions();
                requestDraw();
            }
        };
        const onTouchEnd = (e) => {
            if (e.touches.length < 2) pinch = null;
        };

        canvas.addEventListener('pointerdown', onPointerDown);
        canvas.addEventListener('pointermove', onPointerMove);
        canvas.addEventListener('pointerup', onPointerUp);
        canvas.addEventListener('pointercancel', onPointerUp);
        canvas.addEventListener('wheel', onWheel, { passive: false });
        canvas.addEventListener('touchstart', onTouchStart, { passive: true });
        canvas.addEventListener('touchmove', onTouchMove, { passive: false });
        canvas.addEventListener('touchend', onTouchEnd, { passive: true });
        canvas.addEventListener('touchcancel', onTouchEnd, { passive: true });

        canvas.style.cursor = 'grab';
        canvas.style.touchAction = 'none';

        let resizeTimer = null;
        const onResize = () => {
            if (resizeTimer) clearTimeout(resizeTimer);
            resizeTimer = setTimeout(() => {
                resizeCanvas();
                clampView();
                requestDraw();
                this._gxSyncListsVisibility();
            }, 100);
        };
        window.addEventListener('resize', onResize, { passive: true });

        let dprMql = null;
        const onDprChange = () => {
            watchDpr();
            resizeCanvas();
            clampView();
            requestDraw();
        };
        const watchDpr = () => {
            if (dprMql) { try { dprMql.removeEventListener('change', onDprChange); } catch (_) { } }
            dprMql = null;
            if (!window.matchMedia) return;
            try {
                dprMql = window.matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
                dprMql.addEventListener('change', onDprChange);
            } catch (_) { dprMql = null; }
        };
        watchDpr();

        const activeWindowTimer = setInterval(() => {
            if (!this.geohashMap) return;
            if (typeof this.fetchGeohashActivityFromD1 === 'function') {
                this.fetchGeohashActivityFromD1();
            }
            this.updateGeohashChannels();
            requestDraw();
            if (this._gxListsOpen) this._gxRenderLists();
        }, ACTIVE_WINDOW_REFRESH_MS);

        const daynightTimer = setInterval(() => {
            if (!this.geohashMap || !daynightMode) return;
            requestDraw();
        }, DAYNIGHT_REFRESH_MS);

        this._geomapCleanup = () => {
            offThemeChange();
            canvas.removeEventListener('pointerdown', onPointerDown);
            canvas.removeEventListener('pointermove', onPointerMove);
            canvas.removeEventListener('pointerup', onPointerUp);
            canvas.removeEventListener('pointercancel', onPointerUp);
            canvas.removeEventListener('wheel', onWheel);
            canvas.removeEventListener('touchstart', onTouchStart);
            canvas.removeEventListener('touchmove', onTouchMove);
            canvas.removeEventListener('touchend', onTouchEnd);
            canvas.removeEventListener('touchcancel', onTouchEnd);
            window.removeEventListener('resize', onResize);
            if (dprMql) { try { dprMql.removeEventListener('change', onDprChange); } catch (_) { } }
            dprMql = null;
            if (resizeTimer) clearTimeout(resizeTimer);
            clearInterval(activeWindowTimer);
            clearInterval(daynightTimer);
            if (rafAnim) cancelAnimationFrame(rafAnim);
            rafAnim = 0;
            fly = null;
            if (typeof this._gxTeardownUi === 'function') this._gxTeardownUi();
        };

        this.geohashMap = {
            updatePoints: () => {
                this.updateGeohashChannels();
                requestDraw();
                if (this._gxListsOpen) this._gxRenderLists();
            },
            resetView: () => {
                fly = null;
                selectPulseStart = 0;
                view.cx = 0; view.cy = 0; view.zoom = 1;
                hoveredChannel = null;
                if (heatmapMode) {
                    heatmapMode = false;
                    this._heatmapPreference = false;
                    updateHeatmapButton();
                }
                if (daynightMode) {
                    daynightMode = false;
                    this._daynightPreference = false;
                    updateDaynightButton();
                }
                if (geohashGridMode) {
                    geohashGridMode = false;
                    this._geohashGridPreference = false;
                    updateGeohashGridButton();
                }
                clampView();
                requestDraw();
            },
            zoomBy: (factor) => {
                const before = unproject(cssWidth / 2, cssHeight / 2);
                view.zoom = Math.max(view.minZoom, Math.min(view.maxZoom, view.zoom * factor));
                const after = unproject(cssWidth / 2, cssHeight / 2);
                view.cx += (before.lng - after.lng);
                view.cy += (before.lat - after.lat);
                clampView();
                ensureSubregions();
                requestDraw();
            },
            toggleHeatmap: () => {
                heatmapMode = !heatmapMode;
                this._heatmapPreference = heatmapMode;
                updateHeatmapButton();
                requestDraw();
            },
            toggleDaynight: () => {
                daynightMode = !daynightMode;
                this._daynightPreference = daynightMode;
                updateDaynightButton();
                requestDraw();
            },
            toggleGeohashGrid: () => {
                geohashGridMode = !geohashGridMode;
                this._geohashGridPreference = geohashGridMode;
                updateGeohashGridButton();
                requestDraw();
            },
            flyToBounds: (bounds, animate, opts) => {
                const o = opts || {};
                const t = targetForBounds(bounds, o.padding || 0.7);
                if (typeof o.anchorY === 'number') t.cy -= (0.5 - o.anchorY) * cssHeight / (baseScale() * t.zoom);
                flyTo(t, animate);
            },
            flyToPoint: (lat, lng, zoom) => flyTo({ cx: lng, cy: lat, zoom: Math.max(view.minZoom, Math.min(view.maxZoom, zoom)) }, true),
            pulseSelected: () => { if (!gxReducedMotion()) { selectPulseStart = performance.now(); requestDraw(); } },
            redraw: () => requestDraw(),
            ensureLayers: () => {
                if (!admin1Loaded) { admin1Loaded = true; loadAdmin1Features().then((f) => { admin1Features = f; requestDraw(); }); }
                if (!citiesLoaded) { citiesLoaded = true; loadCityFeatures().then((f) => { cityFeatures = f; requestDraw(); }); }
            },
            debugState: () => ({ view: { cx: view.cx, cy: view.cy, zoom: view.zoom }, width: cssWidth, height: cssHeight,
                clusters: currentClusters(), recent: [...recentSet()], saved: [...savedSet()], selected: this._gxSelected || null,
                pulse: this._gxAnim ? this._gxAnim.pulseT : null, ambient: this._gxAnim ? this._gxAnim.ambientT : null,
                flying: !!fly, project: (lat, lng) => project(lng, lat),
                dpr, heat: heatCanvas ? { w: heatCanvas.width, h: heatCanvas.height } : null,
                geo: (() => {
                    const t0 = features.length ? pathsForFeatures(features, true).layer : null;
                    const st = [t0, tierData[1] && tierData[1].countries.layer, tierData[2] && tierData[2].countries.layer].map(layerStats);
                    const td = tierLayers();
                    const cur = td && td.countries ? layerStats(td.countries.layer) : { len: 0, segs: 0 };
                    return {
                        tier: activeTier(), want: wantTier(), loaded: [features.length > 0, !!tierData[1], !!tierData[2]],
                        vertsByTier: st.map((x) => x.verts),
                        segPx: cur.segs ? cur.len * baseScale() * view.zoom / cur.segs : 0,
                    };
                })(),
                occupied: lastOccupied,
                labels: lastLabels.map((l) => ({ text: l.text, kind: l.kind, x0: l.box.x0, y0: l.box.y0, x1: l.box.x1, y1: l.box.y1 })) }),
            zoomToBounds: (bounds, padding = 0.7) => {
                const lngSpan = Math.max(1e-6, bounds.lng[1] - bounds.lng[0]);
                const latSpan = Math.max(1e-6, bounds.lat[1] - bounds.lat[0]);
                const s = baseScale();
                const zLng = (cssWidth * padding) / (lngSpan * s);
                const zLat = (cssHeight * padding) / (latSpan * s);
                const target = Math.min(zLng, zLat);
                view.zoom = Math.max(view.minZoom, Math.min(view.maxZoom, target));
                view.cx = (bounds.lng[0] + bounds.lng[1]) / 2;
                view.cy = (bounds.lat[0] + bounds.lat[1]) / 2;
                clampView();
                ensureSubregions();
                requestDraw();
            }
        };

        clampView();
        requestDraw();
        this._gxInitUi();

        loadWorldFeatures().then(feats => {
            features = feats;
            requestDraw();
        });
    },

    zoomMapIn() {
        if (this.geohashMap) this.geohashMap.zoomBy(1.6);
    },

    zoomMapOut() {
        if (this.geohashMap) this.geohashMap.zoomBy(1 / 1.6);
    },

    toggleHeatmap() {
        if (this.geohashMap) this.geohashMap.toggleHeatmap();
    },

    toggleDaynight() {
        if (this.geohashMap) this.geohashMap.toggleDaynight();
    },

    toggleGeohashGrid() {
        if (this.geohashMap) this.geohashMap.toggleGeohashGrid();
    },

    _selectGeohashCell(geohash, opts = {}) {
        const gh = geohash.toLowerCase();
        const bounds = decodeGeohashBoundsRaw(gh);
        if (!bounds) return;
        const lat = (bounds.lat[0] + bounds.lat[1]) / 2;
        const lng = (bounds.lng[0] + bounds.lng[1]) / 2;
        const animate = opts.fly !== false;
        if (this.geohashMap && this.geohashMap.flyToBounds) {
            this.geohashMap.flyToBounds(bounds, animate, this._gxNarrow() ? { padding: 0.45, anchorY: 0.27 } : null);
        }
        if (opts.pulse !== false && this.geohashMap && this.geohashMap.pulseSelected) {
            this.geohashMap.pulseSelected();
        }
        const existing = (this.geohashChannels || []).find(c => c.geohash && c.geohash.toLowerCase() === gh);
        const channelInfo = existing || {
            geohash: gh,
            lat,
            lng,
            messages: 0,
            isJoined: !!(this.userJoinedChannels && this.userJoinedChannels.has(gh))
        };
        if (typeof this.selectGeohashChannel === 'function') {
            this.selectGeohashChannel(channelInfo);
        }
    },

    _scheduleGeohashMapUpdate() {
        if (!this.geohashMap) return;
        if (this._geomapUpdateTimer) return;
        this._geomapUpdateTimer = setTimeout(() => {
            this._geomapUpdateTimer = null;
            if (this.geohashMap) this.geohashMap.updatePoints();
        }, 250);
    },

    closeGeohashInfo() {
        const infoPanel = document.getElementById('geohashInfoPanel');
        if (infoPanel) infoPanel.style.display = 'none';
        this.selectedGeohash = null;
        this._gxSelected = null;
        this._gxCancelPeek();
        this._gxSyncListsVisibility();
        if (this.geohashMap && this.geohashMap.redraw) this.geohashMap.redraw();
    },

    _gxL(text) {
        return typeof this.uiText === 'function' ? this.uiText(text) : text;
    },

    _gxWindowGroupHtml(active, inMenu) {
        const label = { 1: 'Last hour', 24: 'Last 24 hours', 168: 'Last 7 days' };
        const short = { 1: '1h', 24: '24h', 168: '7d' };
        const state = (h) => inMenu
            ? `role="menuitemradio" tabindex="-1" aria-checked="${h === active ? 'true' : 'false'}"`
            : `aria-pressed="${h === active ? 'true' : 'false'}"`;
        const btns = window.NymGeoExplore.WINDOW_OPTIONS.map((h) => `<button type="button" class="geohash-window-btn${h === active ? ' active' : ''}" data-action="setActiveWindow" data-hours="${h}" ${state(h)} aria-label="${this.escapeHtml(this._gxL(label[h]))}" title="${this.escapeHtml(this._gxL(label[h]))}">${this.escapeHtml(this._gxL(short[h]))}</button>`).join('');
        return `<div class="geohash-window-group" role="group" aria-label="${this.escapeHtml(this._gxL('Activity window'))}">${btns}</div>`;
    },

    _gxInitUi() {
        const root = document.getElementById('geohashGlobeCanvas');
        if (!root) return;
        this._gxTab = this._gxTab || 'active';
        this._gxListsOpen = false;
        this._gxLayersOpen = false;
        this._gxSelected = null;
        const on = (id, ev, fn) => {
            const el = document.getElementById(id);
            if (!el) return;
            el.addEventListener(ev, fn);
            (this._gxUnbind = this._gxUnbind || []).push(() => el.removeEventListener(ev, fn));
        };
        on('gxLayersBtn', 'click', () => this._gxToggleLayers(undefined, true));
        on('gxLayersBtn', 'keydown', (e) => {
            if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
            e.preventDefault();
            this._gxToggleLayers(true, true);
        });
        on('gxLayers', 'keydown', (e) => this._gxLayersKey(e));
        on('geohashGlobeCanvas', 'keydown', (e) => {
            if (e.key !== 'Escape' || !this._gxLayersOpen || e.defaultPrevented) return;
            e.preventDefault();
            e.stopPropagation();
            this._gxToggleLayers(false, true);
        });
        on('geohashExplorerModal', 'nym-sheet-escape', (e) => {
            if (!this._gxLayersOpen) return;
            e.preventDefault();
            this._gxToggleLayers(false, true);
        });
        on('gxListsBtn', 'click', () => this._gxToggleLists());
        on('gxLocationBtn', 'click', () => this._gxGoToLocation());
        on('gxSaveBtn', 'click', () => {
            if (!this.selectedGeohash) return;
            this.togglePin(this.selectedGeohash, this.selectedGeohash);
            this._gxSyncSave();
            this._gxRenderLists();
            if (this.geohashMap && this.geohashMap.redraw) this.geohashMap.redraw();
        });
        on('gxShareBtn', 'click', () => {
            if (!this.selectedGeohash) return;
            const m = document.getElementById('shareModal');
            if (m) m.classList.add('gx-over');
            this.shareChannel(this.selectedGeohash);
        });
        on('gxLists', 'click', (e) => {
            const tab = e.target.closest('.gx-tab');
            if (tab) { this._gxTab = tab.dataset.tab; this._gxRenderLists(); return; }
            const row = e.target.closest('.gx-row');
            if (row && row.dataset.gh) this._selectGeohashCell(row.dataset.gh);
        });
        on('gxPrecision', 'click', (e) => {
            const b = e.target.closest('.gx-step');
            if (b && b.dataset.gh) this._selectGeohashCell(b.dataset.gh);
        });
        on('gxSearchInput', 'input', () => this._gxSearchInput());
        on('gxSearchInput', 'keydown', (e) => this._gxSearchKey(e));
        on('gxSearchClear', 'click', () => this._gxSearchClear(true));
        on('gxSearchResults', 'mousedown', (e) => e.preventDefault());
        on('gxSearchResults', 'click', (e) => {
            const opt = e.target.closest('.gx-result');
            if (opt && opt.dataset.gh) this._gxPick(opt.dataset.gh);
        });
        if (typeof this.i18nApplyNow === 'function') this.i18nApplyNow(root);
    },

    _gxTeardownUi() {
        for (const f of (this._gxUnbind || [])) { try { f(); } catch (_) { } }
        this._gxUnbind = [];
        this._gxCancelPeek();
        this._gxSelected = null;
    },

    _gxToggleLayers(force, moveFocus) {
        const was = !!this._gxLayersOpen;
        const open = typeof force === 'boolean' ? force : !was;
        this._gxLayersOpen = open;
        const menu = document.getElementById('gxLayers');
        const btn = document.getElementById('gxLayersBtn');
        if (menu) menu.classList.toggle('nm-hidden', !open);
        if (btn) btn.setAttribute('aria-expanded', open ? 'true' : 'false');
        this._gxSyncLayersBtn();
        if (!moveFocus) {
            if (!open && was && menu && btn && menu.contains(document.activeElement)) btn.focus({ preventScroll: true });
            return;
        }
        if (open) {
            const first = this._gxLayerItems()[0];
            if (first) first.focus({ preventScroll: true });
        } else if (btn) {
            btn.focus({ preventScroll: true });
        }
    },

    _gxLayerItems() {
        const menu = document.getElementById('gxLayers');
        return menu ? [...menu.querySelectorAll('[role="menuitemcheckbox"], [role="menuitemradio"]')] : [];
    },

    _gxLayersKey(e) {
        const items = this._gxLayerItems();
        const at = items.indexOf(document.activeElement);
        let next = -1;
        if (e.key === 'ArrowDown') next = at < 0 ? 0 : (at + 1) % items.length;
        else if (e.key === 'ArrowUp') next = at <= 0 ? items.length - 1 : at - 1;
        else if (e.key === 'Home') next = 0;
        else if (e.key === 'End') next = items.length - 1;
        else if (e.key === 'Escape') {
            e.preventDefault();
            e.stopPropagation();
            this._gxToggleLayers(false, true);
            return;
        } else if (e.key === 'Tab') {
            this._gxToggleLayers(false);
            return;
        }
        if (next < 0 || !items[next]) return;
        e.preventDefault();
        items[next].focus({ preventScroll: true });
    },

    _gxSyncLayersBtn() {
        const btn = document.getElementById('gxLayersBtn');
        if (!btn) return;
        const count = [this._heatmapPreference, this._daynightPreference, this._geohashGridPreference].filter(Boolean).length;
        const label = count ? this._gxL('Layers, {n} on').replace('{n}', String(count)) : this._gxL('Layers');
        btn.setAttribute('aria-label', label);
        btn.setAttribute('title', label);
        btn.classList.toggle('active', !!this._gxLayersOpen || count > 0);
        const badge = btn.querySelector('.gx-badge');
        if (badge) {
            badge.textContent = count ? String(count) : '';
            badge.classList.toggle('nm-hidden', !count);
        }
    },

    _gxNarrow() {
        const root = document.getElementById('geohashGlobeCanvas');
        return !!root && root.clientWidth < 768;
    },

    _gxToggleLists(force) {
        const open = typeof force === 'boolean' ? force : !this._gxListsOpen;
        this._gxListsOpen = open;
        this._gxToggleLayers(false);
        const btn = document.getElementById('gxListsBtn');
        if (btn) { btn.setAttribute('aria-expanded', open ? 'true' : 'false'); btn.classList.toggle('active', open); }
        if (open) {
            this._gxLoadPlaces().then(() => this._gxRenderLists()).catch(() => { });
            if (this._gxNarrow() && this.selectedGeohash) this.closeGeohashInfo();
        }
        this._gxSyncListsVisibility();
        this._gxRenderLists();
    },

    _gxSyncListsVisibility() {
        const lists = document.getElementById('gxLists');
        if (!lists) return;
        const hide = !this._gxListsOpen || (this._gxNarrow() && !!this.selectedGeohash);
        lists.classList.toggle('nm-hidden', hide);
    },

    _gxUserLoc() {
        return (this.settings && this.settings.sortByProximity && this.userLocation) ? this.userLocation : null;
    },

    _gxGoToLocation() {
        const loc = this._gxUserLoc();
        if (!loc) {
            const msg = this._gxL('Location is off. Turn on "Sort by proximity" in Settings to use your location.');
            if (typeof this.showToast === 'function') this.showToast(msg);
            return;
        }
        const GX = window.NymGeoExplore;
        const b = GX.cellBounds(GX.encodeGeohash(loc.lat, loc.lng, 4));
        if (b && this.geohashMap && this.geohashMap.flyToBounds) {
            this.geohashMap.flyToBounds({ lat: [b.latLo, b.latHi], lng: [b.lngLo, b.lngHi] }, true);
        }
    },

    _gxLoadPlaces() {
        if (this._gxPlacesPromise) return this._gxPlacesPromise;
        if (this.geohashMap && this.geohashMap.ensureLayers) this.geohashMap.ensureLayers();
        const get = (u) => fetch(u, { cache: 'force-cache' }).then((r) => r.ok ? r.json() : null).catch(() => null);
        const p = Promise.all([get(CITIES_GEOJSON_URL), get(ADMIN1_GEOJSON_URL), loadWorldFeatures()])
            .then(([cities, admin1, world]) => {
                this._gxPlaces = window.NymGeoExplore.buildPlaceIndex({ cities, admin1, countries: world || [] });
                this._gxWorld = world || [];
                this._gxLabelCache = new Map();
                return this._gxPlaces;
            });
        this._gxPlacesPromise = p;
        p.catch(() => { this._gxPlacesPromise = null; });
        return p;
    },

    _gxPlaceLabel(gh) {
        if (!this._gxLabelCache) this._gxLabelCache = new Map();
        if (this._gxLabelCache.has(gh)) return this._gxLabelCache.get(gh);
        const GX = window.NymGeoExplore;
        let label = GX.roomPlaceLabel(this._gxPlaces || [], gh);
        if (!label && this._gxWorld && this._gxWorld.length && window.NymGeoDecode) {
            const b = GX.cellBounds(gh);
            if (b) label = window.NymGeoDecode.countryAt(this._gxWorld, (b.latLo + b.latHi) / 2, (b.lngLo + b.lngHi) / 2) || '';
        }
        if (this._gxPlaces) this._gxLabelCache.set(gh, label);
        return label;
    },

    _gxRow(c, km) {
        const GX = window.NymGeoExplore;
        const place = this._gxPlaceLabel(c.geohash);
        const activity = c.messages === 1 ? this._gxL('1 message') : this._gxL(`${c.messages} messages`);
        const loc = this._gxUserLoc();
        const d = typeof km === 'number' ? km : (loc ? GX.haversineKm(loc.lat, loc.lng, c.lat, c.lng) : null);
        const dist = d === null ? '' : this._gxL(`${GX.formatDistanceKm(d)} away`);
        const label = [`#${c.geohash}`, place, dist, activity].filter(Boolean).join(', ');
        const e = (t) => this.escapeHtml(t);
        return `<button type="button" class="gx-row" data-gh="${e(c.geohash)}" aria-label="${e(label)}">
<span class="gx-row-main"><span class="gx-row-gh">#${e(c.geohash)}</span>${place ? `<span class="gx-row-place">${e(place)}</span>` : ''}</span>
<span class="gx-row-meta"><span>${e(activity)}</span>${dist ? `<span class="gx-row-dist">${e(dist)}</span>` : ''}</span></button>`;
    },

    _gxEmpty(title, body) {
        return `<div class="gx-empty"><div class="gx-empty-title">${this.escapeHtml(this._gxL(title))}</div><div>${this.escapeHtml(this._gxL(body))}</div></div>`;
    },

    _gxSavedRows() {
        const GX = window.NymGeoExplore;
        const by = new Map((this.geohashChannels || []).map((c) => [c.geohash, c]));
        const out = [];
        for (const k of [...(this.pinnedChannels || [])].map((x) => String(x).toLowerCase()).sort()) {
            if (k === 'nymchat' || !GX.isValidGeohash(k)) continue;
            const b = GX.cellBounds(k);
            out.push(by.get(k) || { geohash: k, lat: (b.latLo + b.latHi) / 2, lng: (b.lngLo + b.lngHi) / 2, messages: 0 });
        }
        return out;
    },

    _gxRenderLists() {
        const body = document.getElementById('gxListsBody');
        if (!body || !this._gxListsOpen) return;
        const GX = window.NymGeoExplore;
        const tab = this._gxTab || 'active';
        document.querySelectorAll('#gxLists .gx-tab').forEach((t) => {
            const on = t.dataset.tab === tab;
            t.setAttribute('aria-selected', on ? 'true' : 'false');
            t.classList.toggle('active', on);
        });
        const active = this.geohashChannels || [];
        let html = '';
        if (tab === 'active') {
            const rows = GX.rankActive(active);
            const wl = { 1: 'Last hour', 24: 'Last 24 hours', 168: 'Last 7 days' }[this._geohashActiveWindowHours] || 'Last 24 hours';
            html = `<div class="gx-lists-head"><span>${this.escapeHtml(this._gxL(wl))}</span>${this._gxWindowGroupHtml(this._geohashActiveWindowHours)}</div>`
                + (rows.length ? `<div class="gx-rows">${rows.map((c) => this._gxRow(c)).join('')}</div>`
                    : this._gxEmpty('No active rooms', 'Nothing was posted in this window.'));
        } else if (tab === 'nearby') {
            const loc = this._gxUserLoc();
            if (!loc) {
                html = this._gxEmpty('Location is off', 'Turn on "Sort by proximity" in Settings to list rooms near you. Distances are worked out on this device and your location is never sent.');
            } else {
                const seen = new Set(active.map((c) => c.geohash));
                const pool = active.concat(this._gxSavedRows().filter((c) => !seen.has(c.geohash)));
                const rows = GX.rankNearby(pool, loc);
                html = rows.length ? `<div class="gx-rows">${rows.map((r) => this._gxRow(r, r.distanceKm)).join('')}</div>`
                    : this._gxEmpty('No rooms yet', 'No active or saved rooms to measure.');
            }
        } else {
            const rows = this._gxSavedRows();
            html = rows.length ? `<div class="gx-rows">${rows.map((c) => this._gxRow(c)).join('')}</div>`
                : this._gxEmpty('No saved places', 'Star a cell to save it here.');
        }
        body.innerHTML = html;
    },

    _gxSyncSave() {
        const btn = document.getElementById('gxSaveBtn');
        if (!btn || !this.selectedGeohash) return;
        const saved = !!(this.pinnedChannels && this.pinnedChannels.has(this.selectedGeohash));
        const label = this._gxL(saved ? 'Remove from saved places' : 'Save place');
        btn.setAttribute('aria-pressed', saved ? 'true' : 'false');
        btn.setAttribute('aria-label', label);
        btn.title = label;
        btn.classList.toggle('saved', saved);
    },

    _gxAfterSelect(channel) {
        const gh = String(channel.geohash).toLowerCase();
        this._gxSelected = gh;
        this._gxToggleLayers(false);
        this._gxSyncSave();
        this._gxRenderPrecision(gh);
        this._gxStartPeek(gh);
        this._gxSyncListsVisibility();
        if (this.geohashMap && this.geohashMap.redraw) this.geohashMap.redraw();
    },

    _gxRenderPrecision(gh) {
        const el = document.getElementById('gxPrecision');
        if (!el) return;
        const steps = window.NymGeoExplore.precisionSteps(gh);
        const e = (t) => this.escapeHtml(t);
        el.innerHTML = `<div class="gx-section-title">${e(this._gxL('Precision'))}</div><div class="gx-steps">`
            + steps.map((s, i) => {
                const label = this._gxL(s.label);
                const sel = s.geohash === gh;
                const aria = `#${s.geohash}, ${label}, ${this._gxL('about')} ${s.size}`;
                return `${i ? '<span class="gx-step-sep" aria-hidden="true">›</span>' : ''}<button type="button" class="gx-step${sel ? ' active' : ''}" data-gh="${e(s.geohash)}" aria-label="${e(aria)}" aria-current="${sel ? 'true' : 'false'}" title="${e(label)} · ~${e(s.size)}"><span class="gx-step-gh">${e(s.geohash)}</span><span class="gx-step-label">${e(label)}</span></button>`;
            }).join('')
            + `</div><div class="gx-hint">${e(this._gxL('A shorter geohash shares less about where you are.'))}</div>`;
    },

    _gxCancelPeek() {
        const p = this._gxPeekRun;
        this._gxPeekRun = null;
        if (p) {
            p.cancelled = true;
            if (p.reader) { try { p.reader.cancel(); } catch (_) { } }
        }
    },

    _gxPeekReach(gh) {
        if (typeof this.meshShouldCarry === 'function' && this.meshShouldCarry(gh)) return 'mesh';
        if (!this.connected || (typeof navigator !== 'undefined' && navigator.onLine === false)) return 'offline';
        return 'online';
    },

    async _gxStartPeek(gh) {
        this._gxCancelPeek();
        const el = document.getElementById('gxPeek');
        if (!el) return;
        const e = (t) => this.escapeHtml(t);
        const head = (online) => `<div class="gx-peek-head"><span class="gx-section-title">${e(this._gxL('Recent messages'))}</span>${typeof online === 'number' ? `<span class="gx-peek-online" id="gxPeekOnline">${e(this._gxL(online === 1 ? '1 nym online' : `${online} nyms online`))}</span>` : ''}</div>`;
        const note = (cls, text) => `${head()}<div class="gx-peek-note ${cls}">${e(this._gxL(text))}</div>`;
        const reach = this._gxPeekReach(gh);
        if (reach !== 'online') {
            el.innerHTML = note('gx-peek-offline', reach === 'mesh'
                ? 'Peek needs the internet. Over the Bluetooth mesh, join the room to see its messages.'
                : "You're offline. Peek shows recent messages once you're back online.");
            return;
        }
        const run = { gh, cancelled: false, reader: null };
        this._gxPeekRun = run;
        el.innerHTML = note('gx-peek-loading', 'Loading recent messages...');
        let summary = null;
        try {
            const events = await this._gxPeekFetch(gh, run);
            if (run.cancelled) return;
            const ok = [];
            for (const ev of events) {
                if (run.cancelled) return;
                if (typeof this._quietHit === 'function' && this._quietHit(ev)) continue;
                if (await this._verifyRelayEventAsync(ev)) ok.push(ev);
            }
            if (run.cancelled) return;
            const now = Date.now();
            const local = [];
            const set = this.channelUsers && this.channelUsers.get(gh);
            if (set) for (const pk of set) {
                const u = this.users && this.users.get(pk);
                if (u && now - u.lastSeen < 300000) local.push(pk);
            }
            summary = window.NymGeoExplore.summarizePeek(ok, {
                geohash: gh, nowSec: Math.floor(now / 1000), blocked: [...(this.blockedUsers || [])], localOnline: local,
                capped: window.NymGeoExplore.peekCapped(events),
            });
        } catch (_) {
            summary = null;
        }
        if (run.cancelled || this._gxPeekRun !== run) return;
        this._gxPeekRun = null;
        if (!summary) { el.innerHTML = note('gx-peek-error', "Couldn't load recent messages."); return; }
        const countEl = document.getElementById('geohashInfoMessages');
        if (countEl && this.selectedGeohash === gh) countEl.textContent = window.NymGeoExplore.peekCountLabel(summary);
        if (!summary.messages.length) {
            el.innerHTML = `${head(summary.online)}<div class="gx-peek-note">${e(this._gxL('No recent messages in this room.'))}</div>`;
            return;
        }
        const rows = summary.messages.map((m) => {
            const who = this.formatNymWithPubkey(m.nym || this._gxL('anon'), m.pubkey);
            return `<div class="gx-peek-msg"><span class="gx-peek-who">${who}</span> <span class="gx-peek-text">${e(m.content)}</span></div>`;
        }).join('');
        el.innerHTML = `${head(summary.online)}<div class="gx-peek-list" aria-label="${e(this._gxL('Recent messages, read only'))}">${rows}</div>`;
    },

    async _gxPeekFetch(gh, run) {
        const resp = await this._storageApiStream('channel-get', { channel: gh }, false);
        if (run.cancelled) return [];
        if (resp && resp._wsItems) return resp._wsItems.slice();
        const out = [];
        if (!resp || !resp.body) return out;
        const reader = resp.body.getReader();
        run.reader = reader;
        const dec = new TextDecoder();
        let buf = '';
        while (true) {
            const { value, done } = await reader.read();
            if (done || run.cancelled) break;
            buf += dec.decode(value, { stream: true });
            let nl;
            while ((nl = buf.indexOf('\n')) >= 0) {
                const line = buf.slice(0, nl);
                buf = buf.slice(nl + 1);
                if (line) { try { out.push(JSON.parse(line)); } catch (_) { } }
            }
        }
        if (!run.cancelled) {
            buf += dec.decode();
            if (buf) { try { out.push(JSON.parse(buf)); } catch (_) { } }
        }
        return out;
    },

    _gxSearchInput() {
        const input = document.getElementById('gxSearchInput');
        if (!input) return;
        const q = input.value;
        const clear = document.getElementById('gxSearchClear');
        if (clear) clear.classList.toggle('nm-hidden', !q);
        if (q.trim()) {
            this._gxLoadPlaces().then(() => {
                const cur = document.getElementById('gxSearchInput');
                if (cur && cur.value === q) this._gxRenderResults(q);
            }).catch(() => { });
        }
        this._gxRenderResults(q);
    },

    _gxRenderResults(q) {
        const box = document.getElementById('gxSearchResults');
        const input = document.getElementById('gxSearchInput');
        if (!box || !input) return;
        const results = window.NymGeoExplore.buildSearchResults(this._gxPlaces || [], q, window.NymGeoExplore.SEARCH_LIMIT);
        this._gxResults = results;
        const first = results.findIndex((r) => r.type !== 'invalid');
        this._gxHi = first < 0 ? -1 : first;
        const e = (t) => this.escapeHtml(t);
        box.innerHTML = results.map((r, i) => {
            if (r.type === 'invalid') {
                const msg = r.reason === 'length' ? 'A geohash has at most 12 characters.' : 'Geohashes use 0–9 and the letters b–z except i, l and o.';
                return `<div class="gx-result-invalid" role="alert">${e(this._gxL(msg))}</div>`;
            }
            let title, sub;
            if (r.type === 'geohash') {
                title = this._gxL(`Go to #${r.geohash}`);
                const steps = window.NymGeoExplore.precisionSteps(r.geohash);
                const step = steps[steps.length - 1];
                sub = [
                    this._gxL('Precision {n}').replace('{n}', String(r.precision || r.geohash.length)),
                    step ? this._gxL(step.label) : '',
                    this._gxPlaceLabel(r.geohash),
                ].filter(Boolean).join(' · ');
            }
            else {
                title = r.name;
                const where = [r.region && r.region !== r.name ? r.region : '', r.country].filter(Boolean).join(', ');
                sub = where ? `${where} · #${r.geohash}` : `#${r.geohash}`;
            }
            return `<div class="gx-result" role="option" id="gxOpt${i}" data-gh="${e(r.geohash)}" aria-selected="${i === this._gxHi ? 'true' : 'false'}"><span class="gx-result-title">${e(title)}</span><span class="gx-result-sub">${e(sub)}</span></div>`;
        }).join('');
        const open = results.length > 0;
        box.classList.toggle('nm-hidden', !open);
        input.setAttribute('aria-expanded', open ? 'true' : 'false');
        if (this._gxHi >= 0) input.setAttribute('aria-activedescendant', `gxOpt${this._gxHi}`);
        else input.removeAttribute('aria-activedescendant');
    },

    _gxSearchKey(ev) {
        const results = this._gxResults || [];
        const sel = results.map((r, i) => (r.type !== 'invalid' ? i : -1)).filter((i) => i >= 0);
        if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
            ev.preventDefault();
            if (!sel.length) return;
            const at = sel.indexOf(this._gxHi);
            const next = ev.key === 'ArrowDown' ? (at + 1) % sel.length : (at <= 0 ? sel.length - 1 : at - 1);
            this._gxHi = sel[next];
            document.querySelectorAll('#gxSearchResults .gx-result').forEach((n) => {
                n.setAttribute('aria-selected', n.id === `gxOpt${this._gxHi}` ? 'true' : 'false');
            });
            const input = document.getElementById('gxSearchInput');
            if (input) input.setAttribute('aria-activedescendant', `gxOpt${this._gxHi}`);
            const opt = document.getElementById(`gxOpt${this._gxHi}`);
            if (opt && opt.scrollIntoView) opt.scrollIntoView({ block: 'nearest' });
        } else if (ev.key === 'Enter') {
            ev.preventDefault();
            const r = results[this._gxHi];
            if (r && r.geohash) this._gxPick(r.geohash);
        } else if (ev.key === 'Escape') {
            if (ev.target.value) { ev.preventDefault(); ev.stopPropagation(); this._gxSearchClear(false); }
        }
    },

    _gxSearchClear(focus) {
        const input = document.getElementById('gxSearchInput');
        if (input) input.value = '';
        this._gxResults = [];
        this._gxRenderResults('');
        const clear = document.getElementById('gxSearchClear');
        if (clear) clear.classList.add('nm-hidden');
        if (focus && input) input.focus();
    },

    _gxPick(gh) {
        this._gxSearchClear(false);
        const input = document.getElementById('gxSearchInput');
        if (input) input.blur();
        this._selectGeohashCell(gh);
    },

    joinSelectedGeohash() {
        if (this.selectedGeohash) {
            const geohash = this.selectedGeohash.toLowerCase();

            this.closeGeohashExplorer();

            setTimeout(() => {
                if (!this.channels.has(geohash)) {
                    this.addChannel(geohash, geohash);
                }

                if (this._cvActive) {
                    this._cvOpenConversation({ type: 'channel', channel: geohash, geohash }, { forceNew: true });
                } else {
                    this.switchChannel(geohash, geohash);
                }

                this.userJoinedChannels.add(geohash);
                this.saveUserChannels();
                this._debouncedNostrSettingsSave();

                this.displaySystemMessage(`Joined geohash channel #${geohash}`);
            }, 100);
        }
    },

    resetGlobeView() {
        if (this.geohashMap) this.geohashMap.resetView();
        const infoPanel = document.getElementById('geohashInfoPanel');
        if (infoPanel) infoPanel.style.display = 'none';
        this.selectedGeohash = null;
        this._gxSelected = null;
        this._gxCancelPeek();
        this._gxToggleLayers(false);
        this._gxSyncListsVisibility();
        if (this._geohashActiveWindowHours !== 24) {
            this.setGeohashActiveWindow(24);
        }
    },

    // Returns the geohash cell's bounds; decodeGeohash takes its center.
    decodeGeohashBounds(geohash) {
        const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
        const bounds = {
            lat: [-90, 90],
            lng: [-180, 180]
        };

        let isEven = true;
        for (let i = 0; i < geohash.length; i++) {
            const cd = BASE32.indexOf(geohash[i].toLowerCase());
            if (cd === -1) throw new Error('Invalid geohash character');

            for (let j = 4; j >= 0; j--) {
                const mask = 1 << j;
                if (isEven) {
                    bounds.lng = (cd & mask) ?
                        [(bounds.lng[0] + bounds.lng[1]) / 2, bounds.lng[1]] :
                        [bounds.lng[0], (bounds.lng[0] + bounds.lng[1]) / 2];
                } else {
                    bounds.lat = (cd & mask) ?
                        [(bounds.lat[0] + bounds.lat[1]) / 2, bounds.lat[1]] :
                        [bounds.lat[0], (bounds.lat[0] + bounds.lat[1]) / 2];
                }
                isEven = !isEven;
            }
        }

        return bounds;
    },

    decodeGeohash(geohash) {
        const bounds = this.decodeGeohashBounds(geohash);
        return {
            lat: (bounds.lat[0] + bounds.lat[1]) / 2,
            lng: (bounds.lng[0] + bounds.lng[1]) / 2
        };
    },

    getGeohashLocation(geohash) {
        try {
            const coords = this.decodeGeohash(geohash);
            const lat = coords.lat;
            const lng = coords.lng;

            const latStr = Math.abs(lat).toFixed(2) + '°' + (lat >= 0 ? 'N' : 'S');
            const lngStr = Math.abs(lng).toFixed(2) + '°' + (lng >= 0 ? 'E' : 'W');

            return `${latStr}, ${lngStr}`;
        } catch (e) {
            return '';
        }
    },

    calculateDistance(lat1, lon1, lat2, lon2) {
        const R = 6371;
        const dLat = (lat2 - lat1) * Math.PI / 180;
        const dLon = (lon2 - lon1) * Math.PI / 180;
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return R * c;
    },

});

})();
