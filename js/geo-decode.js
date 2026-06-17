// geo-decode.js - Portable TopoJSON/GeoJSON decoding for the geohash globe

(function () {

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

    // High-level decoders matching each data file's shape. Each takes parsed
    // JSON and returns the render-ready feature array.
    function decodeWorld(topo) {
        if (!topo) return [];
        const feats = decodeTopoJson(topo, 'countries');
        feats.forEach(annotateFeature);
        feats.sort((a, b) => b.area - a.area);
        return feats;
    }

    function decodeAdmin1(geo) {
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
    }

    function decodeCities(geo) {
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
    }

    // 'world' | 'admin1' | 'cities' -> decoder over parsed JSON.
    function decodeByKind(kind, json) {
        if (kind === 'world') return decodeWorld(json);
        if (kind === 'admin1') return decodeAdmin1(json);
        if (kind === 'cities') return decodeCities(json);
        return [];
    }

    (typeof self !== 'undefined' ? self : window).NymGeoDecode = {
        decodeTopoJson, annotateFeature, decodeWorld, decodeAdmin1, decodeCities, decodeByKind
    };
})();
