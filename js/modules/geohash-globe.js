// geohash-globe.js - Flat 2D world map for geohash channel explorer

(function () {

    const WORLD_TOPO_URL = 'https://cdn.jsdelivr.net/npm/world-atlas@2/countries-110m.json';
    const ADMIN1_GEOJSON_URL = 'https://cdn.jsdelivr.net/gh/martynafford/natural-earth-geojson@master/50m/cultural/ne_50m_admin_1_states_provinces_lakes.json';
    const CITIES_GEOJSON_URL = 'https://cdn.jsdelivr.net/gh/martynafford/natural-earth-geojson@master/50m/cultural/ne_50m_populated_places_simple.json';

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

    function decodeTopoJson(topo, objectName) {
        const tx = topo.transform || { scale: [1, 1], translate: [0, 0] };
        const sx = tx.scale[0], sy = tx.scale[1];
        const dx = tx.translate[0], dy = tx.translate[1];

        const rawArcs = topo.arcs.map(arc => {
            let x = 0, y = 0;
            return arc.map(([adx, ady]) => {
                x += adx; y += ady;
                return [x * sx + dx, y * sy + dy];
            });
        });

        const arcAt = (i) => i >= 0 ? rawArcs[i] : rawArcs[~i].slice().reverse();

        const stitchRing = (arcIdxs) => {
            const out = [];
            for (let i = 0; i < arcIdxs.length; i++) {
                const a = arcAt(arcIdxs[i]);
                if (i > 0) for (let j = 1; j < a.length; j++) out.push(a[j]);
                else for (let j = 0; j < a.length; j++) out.push(a[j]);
            }
            return out;
        };

        const buildPolygon = (rings) => rings.map(stitchRing);

        const obj = topo.objects[objectName] || topo.objects[Object.keys(topo.objects)[0]];
        if (!obj) return [];
        const geoms = obj.type === 'GeometryCollection' ? obj.geometries : [obj];

        const features = [];
        for (const g of geoms) {
            const name = (g.properties && g.properties.name) || '';
            if (g.type === 'Polygon') {
                features.push({ type: 'Polygon', name, coordinates: buildPolygon(g.arcs) });
            } else if (g.type === 'MultiPolygon') {
                features.push({ type: 'MultiPolygon', name, coordinates: g.arcs.map(buildPolygon) });
            }
        }
        return features;
    }

    function ringSignedArea(ring) {
        let a = 0;
        for (let i = 0, n = ring.length - 1; i < n; i++) {
            a += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1];
        }
        return a / 2;
    }

    function annotateFeature(feat) {
        let minLng = Infinity, maxLng = -Infinity, minLat = Infinity, maxLat = -Infinity;
        let largestRing = null, largestArea = -Infinity;

        const polys = feat.type === 'Polygon' ? [feat.coordinates] : feat.coordinates;
        for (const poly of polys) {
            if (!poly.length) continue;
            const outer = poly[0];
            const area = Math.abs(ringSignedArea(outer));
            if (area > largestArea) { largestArea = area; largestRing = outer; }
            for (const ring of poly) {
                for (let i = 0, n = ring.length; i < n; i++) {
                    const lng = ring[i][0], lat = ring[i][1];
                    if (lng < minLng) minLng = lng;
                    if (lng > maxLng) maxLng = lng;
                    if (lat < minLat) minLat = lat;
                    if (lat > maxLat) maxLat = lat;
                }
            }
        }

        let cx = 0, cy = 0;
        if (largestRing && largestRing.length) {
            for (let i = 0, n = largestRing.length; i < n; i++) {
                cx += largestRing[i][0];
                cy += largestRing[i][1];
            }
            cx /= largestRing.length;
            cy /= largestRing.length;
        }

        feat.bounds = [minLng, minLat, maxLng, maxLat];
        feat.centroid = [cx, cy];
        feat.area = largestArea;
    }

    let worldFeaturesPromise = null;
    function loadWorldFeatures() {
        if (worldFeaturesPromise) return worldFeaturesPromise;
        worldFeaturesPromise = fetch(WORLD_TOPO_URL, { cache: 'force-cache' })
            .then(r => r.ok ? r.json() : null)
            .then(topo => {
                if (!topo) return [];
                const feats = decodeTopoJson(topo, 'countries');
                feats.forEach(annotateFeature);
                feats.sort((a, b) => b.area - a.area);
                return feats;
            })
            .catch(() => []);
        return worldFeaturesPromise;
    }

    let admin1FeaturesPromise = null;
    function loadAdmin1Features() {
        if (admin1FeaturesPromise) return admin1FeaturesPromise;
        admin1FeaturesPromise = fetch(ADMIN1_GEOJSON_URL, { cache: 'force-cache' })
            .then(r => r.ok ? r.json() : null)
            .then(geo => {
                if (!geo || !Array.isArray(geo.features)) return [];
                const feats = [];
                for (const f of geo.features) {
                    if (!f || !f.geometry) continue;
                    const props = f.properties || {};
                    const name = props.name || props.name_en || '';
                    const type = f.geometry.type;
                    if (type !== 'Polygon' && type !== 'MultiPolygon') continue;
                    const feat = { type, name, coordinates: f.geometry.coordinates };
                    annotateFeature(feat);
                    feats.push(feat);
                }
                feats.sort((a, b) => b.area - a.area);
                return feats;
            })
            .catch(() => []);
        return admin1FeaturesPromise;
    }

    let cityFeaturesPromise = null;
    function loadCityFeatures() {
        if (cityFeaturesPromise) return cityFeaturesPromise;
        cityFeaturesPromise = fetch(CITIES_GEOJSON_URL, { cache: 'force-cache' })
            .then(r => r.ok ? r.json() : null)
            .then(geo => {
                if (!geo || !Array.isArray(geo.features)) return [];
                const out = [];
                for (const f of geo.features) {
                    const coords = f && f.geometry && f.geometry.coordinates;
                    if (!coords || coords.length < 2) continue;
                    const props = f.properties || {};
                    const rank = typeof props.scalerank === 'number' ? props.scalerank
                        : (typeof props.SCALERANK === 'number' ? props.SCALERANK : 10);
                    out.push({
                        name: props.name || props.NAME || '',
                        lng: coords[0],
                        lat: coords[1],
                        rank,
                        pop: props.pop_max || props.POP_MAX || props.pop_min || 0
                    });
                }
                out.sort((a, b) => a.rank - b.rank);
                return out;
            })
            .catch(() => []);
        return cityFeaturesPromise;
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
        const cs = getComputedStyle(document.documentElement);
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
            haloAlpha: isLight ? 0.18 : 0.32
        };
    }

Object.assign(NYM.prototype, {

    showGeohashExplorer() {
        const modal = document.getElementById('geohashExplorerModal');
        if (!modal) return;
        modal.style.display = 'flex';
        setTimeout(() => this.initializeGeohashMap(), 30);
        // Quietly pull recent-activity counts from R2 so the globe reflects real
        // activity (especially the default 24h view) without loading messages.
        if (typeof this.fetchGeohashActivityFromR2 === 'function') {
            this.fetchGeohashActivityFromR2();
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

        const showYourLocation = this.settings && this.settings.sortByProximity && this.userLocation;

        if (typeof this._geohashActiveWindowHours !== 'number'
            || this._geohashActiveWindowHours < 1
            || this._geohashActiveWindowHours > 24) {
            this._geohashActiveWindowHours = 24;
        }
        const activeHours = this._geohashActiveWindowHours;
        const windowOptions = [1, 3, 6, 12, 24];
        const windowButtons = windowOptions.map(h => `
        <button class="geohash-window-btn${h === activeHours ? ' active' : ''}"
                data-action="setActiveWindow" data-hours="${h}" type="button">${h}h</button>`).join('');
        const windowOptionTags = windowOptions.map(h =>
            `<option value="${h}"${h === activeHours ? ' selected' : ''}>${h}h</option>`).join('');

        container.insertAdjacentHTML('beforeend', `
<canvas id="geohashMapCanvas" class="geohash-map-canvas"></canvas>

<div class="geohash-info-panel nm-hidden" id="geohashInfoPanel">
    <button class="geohash-info-close" id="geohashInfoClose" data-action="closeGeohashInfo" aria-label="Close">&#x2715;</button>
    <div class="geohash-info-title" id="geohashInfoTitle">Channel Info</div>
    <div id="geohashInfoContent"></div>
    <button class="geohash-join-btn" id="geohashJoinBtn">Join Channel</button>
</div>

<div class="geohash-controls geohash-controls-tl">
    <button class="geohash-control-btn geohash-zoom-btn" data-action="zoomMapIn" aria-label="Zoom in">+</button>
    <button class="geohash-control-btn geohash-zoom-btn" data-action="zoomMapOut" aria-label="Zoom out">&minus;</button>
    <button class="geohash-control-btn" data-action="resetGlobeView">Reset View</button>
</div>

<div class="geohash-controls">
    <div class="geohash-controls-row">
        <button class="geohash-control-btn geohash-heatmap-btn" id="geohashHeatmapBtn" data-action="toggleHeatmap">Heat</button>
        <button class="geohash-control-btn geohash-daynight-btn" id="geohashDaynightBtn" data-action="toggleDaynight">Day / Night</button>
        <button class="geohash-control-btn geohash-grid-btn" id="geohashGridBtn" data-action="toggleGeohashGrid">Geohash</button>
    </div>
</div>

<div class="geohash-legend">
    <div class="geohash-legend-item">
        <div class="geohash-legend-dot nm-geo-1"></div>
        <span>Active</span>
        <div class="geohash-window-group" role="group" aria-label="Active window">${windowButtons}</div>
        <select class="geohash-window-select" aria-label="Active window"
                data-on-change="setActiveWindowFromSelect">${windowOptionTags}</select>
    </div>
    ${showYourLocation ? `
    <div class="geohash-legend-item">
        <div class="geohash-legend-dot nm-geo-2"></div>
        <span>Your Location</span>
    </div>` : ''}
</div>
`);

        this.updateGeohashChannels();

        const canvas = container.querySelector('#geohashMapCanvas');
        const ctx = canvas.getContext('2d');

        const isPerf = !!this.performanceMode;
        const dpr = isPerf ? 1 : Math.min(window.devicePixelRatio || 1, 2);

        const view = { cx: 0, cy: 0, zoom: 1, minZoom: 1, maxZoom: 16 };

        let cssWidth = container.clientWidth || 1;
        let cssHeight = container.clientHeight || 1;

        const resizeCanvas = () => {
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
        const styles = getMapStyles();

        const ensureSubregions = () => {
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
            const w = Math.max(1, Math.floor(cssWidth * HEAT_SCALE));
            const h = Math.max(1, Math.floor(cssHeight * HEAT_SCALE));
            if (!heatCanvas) {
                heatCanvas = document.createElement('canvas');
                heatCtx = heatCanvas.getContext('2d');
            }
            if (heatCanvas.width !== w || heatCanvas.height !== h) {
                heatCanvas.width = w;
                heatCanvas.height = h;
            }
        };

        const updateHeatmapButton = () => {
            const btn = document.getElementById('geohashHeatmapBtn');
            if (btn) btn.classList.toggle('active', heatmapMode);
        };
        updateHeatmapButton();

        const updateDaynightButton = () => {
            const btn = document.getElementById('geohashDaynightBtn');
            if (btn) btn.classList.toggle('active', daynightMode);
        };
        updateDaynightButton();

        const updateGeohashGridButton = () => {
            const btn = document.getElementById('geohashGridBtn');
            if (btn) btn.classList.toggle('active', geohashGridMode);
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

        const drawWorld = () => {
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

        const drawLabels = () => {
            if (!features.length) return;
            const fontSize = isPerf ? 10 : 11;
            ctx.font = `600 ${fontSize}px var(--font-sans, system-ui, sans-serif)`;
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
        };

        const drawAdmin1 = () => {
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
        };

        const drawAdmin1Labels = () => {
            if (view.zoom < 4 || !admin1Features.length) return;
            const fontSize = isPerf ? 9 : 10;
            ctx.font = `500 ${fontSize}px var(--font-sans, system-ui, sans-serif)`;
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
        };

        const drawCities = () => {
            if (view.zoom < CITY_ZOOM_THRESHOLD || !cityFeatures.length) return;

            // scalerank: 0 = world's largest. Higher zoom -> show smaller cities.
            const rankCutoff = view.zoom < 3 ? 2
                : view.zoom < 4 ? 4
                : view.zoom < 6 ? 6
                : view.zoom < 8 ? 8 : 10;

            const fontSize = isPerf ? 9 : 10;
            ctx.font = `500 ${fontSize}px var(--font-sans, system-ui, sans-serif)`;
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

        const drawChannels = () => {
            const baseR = isPerf ? 4 : 5;
            const channels = this.geohashChannels || [];

            for (const ch of channels) {
                const p = project(ch.lng, ch.lat);
                if (!inView(p, 12)) continue;
                const isHover = hoveredChannel && hoveredChannel.geohash === ch.geohash;
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
        };

        const drawUserLocation = () => {
            if (this.userLocation) {
                const p = project(this.userLocation.lng, this.userLocation.lat);
                if (inView(p, 10)) {
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
            }
        };

        const draw = () => {
            drawScheduled = false;

            ctx.fillStyle = styles.ocean;
            ctx.fillRect(0, 0, cssWidth, cssHeight);

            drawGraticule();
            drawWorld();
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
        };

        const requestDraw = () => {
            if (drawScheduled) return;
            drawScheduled = true;
            requestAnimationFrame(draw);
        };

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
            const ch = findChannelAt(localX, localY);
            if (ch && typeof this.selectGeohashChannel === 'function') {
                this.selectGeohashChannel(ch);
                return;
            }
            if (geohashGridMode) {
                const gh = findGeohashAt(localX, localY);
                if (gh) this._selectGeohashCell(gh);
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
            }, 100);
        };
        window.addEventListener('resize', onResize, { passive: true });

        const activeWindowTimer = setInterval(() => {
            if (!this.geohashMap) return;
            // Refresh R2 activity counts too (throttled internally) so the globe
            // stays current for channels we aren't actively loading.
            if (typeof this.fetchGeohashActivityFromR2 === 'function') {
                this.fetchGeohashActivityFromR2();
            }
            this.updateGeohashChannels();
            requestDraw();
        }, ACTIVE_WINDOW_REFRESH_MS);

        const daynightTimer = setInterval(() => {
            if (!this.geohashMap || !daynightMode) return;
            requestDraw();
        }, DAYNIGHT_REFRESH_MS);

        this._geomapCleanup = () => {
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
            if (resizeTimer) clearTimeout(resizeTimer);
            clearInterval(activeWindowTimer);
            clearInterval(daynightTimer);
        };

        this.geohashMap = {
            updatePoints: () => {
                this.updateGeohashChannels();
                requestDraw();
            },
            resetView: () => {
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

    _selectGeohashCell(geohash) {
        const gh = geohash.toLowerCase();
        const bounds = decodeGeohashBoundsRaw(gh);
        if (!bounds) return;
        const lat = (bounds.lat[0] + bounds.lat[1]) / 2;
        const lng = (bounds.lng[0] + bounds.lng[1]) / 2;
        if (this.geohashMap && this.geohashMap.zoomToBounds) {
            this.geohashMap.zoomToBounds(bounds);
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
    },

    joinSelectedGeohash() {
        if (this.selectedGeohash) {
            const geohash = this.selectedGeohash.toLowerCase();

            this.closeGeohashExplorer();

            setTimeout(() => {
                if (!this.channels.has(geohash)) {
                    this.addChannel(geohash, geohash);
                }

                this.switchChannel(geohash, geohash);

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
        if (this._geohashActiveWindowHours !== 24) {
            this.setGeohashActiveWindow(24);
        }
    },

    decodeGeohash(geohash) {
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
