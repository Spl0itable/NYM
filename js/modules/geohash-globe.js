// geohash-globe.js - Flat 2D world map for geohash channel explorer

(function () {

    const WORLD_TOPO_URL = 'https://cdn.jsdelivr.net/npm/world-atlas@2/countries-110m.json';

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
            graticule: isLight ? 'rgba(0,0,0,0.05)' : 'rgba(255,255,255,0.04)',
            label: isLight ? 'rgba(30,40,55,0.85)' : 'rgba(220,232,245,0.85)',
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

        container.insertAdjacentHTML('beforeend', `
<canvas id="geohashMapCanvas" class="geohash-map-canvas"></canvas>

<div class="geohash-info-panel" id="geohashInfoPanel" style="display: none;">
    <button class="geohash-info-close" id="geohashInfoClose" data-action="closeGeohashInfo" aria-label="Close">&#x2715;</button>
    <div class="geohash-info-title" id="geohashInfoTitle">Channel Info</div>
    <div id="geohashInfoContent"></div>
    <button class="geohash-join-btn" id="geohashJoinBtn">Join Channel</button>
</div>

<div class="geohash-controls">
    <button class="geohash-control-btn" data-action="resetGlobeView">Reset View</button>
    <button class="geohash-control-btn geohash-heatmap-btn" id="geohashHeatmapBtn" data-action="toggleHeatmap">Heatmap</button>
    <button class="geohash-control-btn geohash-zoom-btn" data-action="zoomMapIn" aria-label="Zoom in">+</button>
    <button class="geohash-control-btn geohash-zoom-btn" data-action="zoomMapOut" aria-label="Zoom out">&minus;</button>
</div>

<div class="geohash-legend">
    <div class="geohash-legend-item">
        <div class="geohash-legend-dot" style="background: var(--primary); box-shadow: 0 0 5px var(--primary);"></div>
        <span>Active Channels</span>
    </div>
    ${showYourLocation ? `
    <div class="geohash-legend-item">
        <div class="geohash-legend-dot" style="background: var(--warning);"></div>
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
        let drawScheduled = false;
        let heatmapMode = !!this._heatmapPreference;
        const styles = getMapStyles();

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
                        const first = project(ring[0][0], ring[0][1]);
                        ctx.moveTo(first.x, first.y);
                        for (let i = 1; i < ring.length; i++) {
                            const p = project(ring[i][0], ring[i][1]);
                            ctx.lineTo(p.x, p.y);
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
            drawLabels();
            if (heatmapMode) drawHeatmap();
            else drawChannels();
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
            const ch = findChannelAt(e.clientX - rect.left, e.clientY - rect.top);
            if (ch && typeof this.selectGeohashChannel === 'function') {
                this.selectGeohashChannel(ch);
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
                requestDraw();
            },
            toggleHeatmap: () => {
                heatmapMode = !heatmapMode;
                this._heatmapPreference = heatmapMode;
                updateHeatmapButton();
                requestDraw();
            },
            isHeatmap: () => heatmapMode
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
