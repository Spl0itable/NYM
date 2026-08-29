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

    // Point-in-polygon (ray casting) over one ring.
    function pointInRing(ring, lng, lat) {
        let inside = false;
        for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
            const xi = ring[i][0], yi = ring[i][1];
            const xj = ring[j][0], yj = ring[j][1];
            if ((yi > lat) !== (yj > lat)
                && lng < (xj - xi) * (lat - yi) / ((yj - yi) || 1e-12) + xi) {
                inside = !inside;
            }
        }
        return inside;
    }

    // Inside the feature's outer ring and outside every hole.
    function pointInFeature(feat, lng, lat) {
        const b = feat.bounds;
        if (b && (lng < b[0] || lng > b[2] || lat < b[1] || lat > b[3])) return false;
        const polys = feat.type === 'Polygon' ? [feat.coordinates] : feat.coordinates;
        for (const poly of polys) {
            if (!poly.length || !pointInRing(poly[0], lng, lat)) continue;
            let inHole = false;
            for (let h = 1; h < poly.length; h++) {
                if (pointInRing(poly[h], lng, lat)) { inHole = true; break; }
            }
            if (!inHole) return true;
        }
        return false;
    }

    /// The country containing this point, or ''. Walked smallest-first (the
    /// decoder sorts largest-area first) so an enclave wins over the country
    /// whose bounding box merely contains it.
    function countryAt(features, lat, lng) {
        for (let i = features.length - 1; i >= 0; i--) {
            if (pointInFeature(features[i], lng, lat)) return features[i].name || '';
        }
        return '';
    }

    function haversineKm(lat1, lng1, lat2, lng2) {
        const R = 6371, rad = Math.PI / 180;
        const dLat = (lat2 - lat1) * rad, dLng = (lng2 - lng1) * rad;
        const a = Math.sin(dLat / 2) ** 2
            + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLng / 2) ** 2;
        return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
    }

    /// Nearest country to a point at sea, as { name, km }. Measured to the
    /// nearest polygon VERTEX rather than the nearest edge — at 110m resolution
    /// the error is far below the thresholds this feeds, and it keeps the scan
    /// a flat loop over the coordinates we already hold.
    function nearestCountry(features, lat, lng) {
        let best = '', bestKm = Infinity;
        for (const feat of features) {
            const b = feat.bounds;
            // Cheap reject: if even the bbox corner nearest in latitude is
            // farther than the best so far, the polygon cannot beat it.
            if (b) {
                const dLat = lat < b[1] ? b[1] - lat : (lat > b[3] ? lat - b[3] : 0);
                if (dLat * 111 > bestKm) continue;
            }
            const polys = feat.type === 'Polygon' ? [feat.coordinates] : feat.coordinates;
            for (const poly of polys) {
                for (const ring of poly) {
                    for (let i = 0; i < ring.length; i++) {
                        const km = haversineKm(lat, lng, ring[i][1], ring[i][0]);
                        if (km < bestKm) { bestKm = km; best = feat.name || ''; }
                    }
                }
            }
        }
        return { name: best, km: bestKm };
    }

    /// A human description of somewhere the geocoder could not name, from the
    /// map data the app already ships. Never coordinates.
    ///
    /// Deliberately conservative about water. The two polar oceans are named
    /// because their extent is unambiguous; everywhere else at sea is described
    /// by what it is near, rather than by a basin name, because the
    /// Atlantic/Pacific/Indian boundaries are irregular enough (the Gulf of
    /// Mexico is Atlantic despite sitting west of Panama; the South China Sea
    /// is Pacific despite sitting east of the Indian Ocean's longitudes) that a
    /// hand-drawn table would state some of them confidently and wrongly.
    /// "Somewhere in the ocean" is honest; "Pacific Ocean" pointing at the
    /// Caribbean is not.
    function describeRegion(features, lat, lng) {
        if (!features || !features.length) return '';
        const land = countryAt(features, lat, lng);
        if (land) return land;
        // Natural Earth's Antarctica ring is CLIPPED at ~-85.6 and never closes
        // around the pole, so plate-carrée point-in-polygon reports "not land"
        // for the entire polar cap — every longitude at -85 and below. Below
        // that clip line there is nothing but continent, so name it directly
        // rather than letting the ocean branch call the South Pole a sea.
        if (lat <= -85.5) return 'Antarctica';
        // Proximity BEFORE the polar names, so a point just off the Antarctic
        // or Greenland coast says which coast rather than naming the whole
        // ocean it technically sits in.
        const near = nearestCountry(features, lat, lng);
        if (near.name && near.km <= 300) return `Off the coast of ${near.name}`;
        if (lat >= 66.5) return 'Arctic Ocean';
        if (lat <= -60) return 'Southern Ocean';
        if (near.name && near.km <= 1200) return `Ocean near ${near.name}`;
        return 'Open ocean';
    }

    // 'world' | 'admin1' | 'cities' -> decoder over parsed JSON.
    function decodeByKind(kind, json) {
        if (kind === 'world') return decodeWorld(json);
        if (kind === 'admin1') return decodeAdmin1(json);
        if (kind === 'cities') return decodeCities(json);
        return [];
    }

    (typeof self !== 'undefined' ? self : window).NymGeoDecode = {
        decodeTopoJson, annotateFeature, decodeWorld, decodeAdmin1, decodeCities, decodeByKind,
        pointInFeature, countryAt, nearestCountry, describeRegion
    };
})();
