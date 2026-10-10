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

    function ringWrapsAntimeridian(ring) {
        let lo = Infinity, hi = -Infinity, slo = Infinity, shi = -Infinity;
        for (const p of ring) {
            const lng = p[0];
            const s = lng < 0 ? lng + 360 : lng;
            if (lng < lo) lo = lng;
            if (lng > hi) hi = lng;
            if (s < slo) slo = s;
            if (s > shi) shi = s;
        }
        return hi - lo > 180 && shi - slo < 180;
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
            const wrap = ringWrapsAntimeridian(largestRing);
            for (let i = 0, n = largestRing.length; i < n; i++) {
                const lng = largestRing[i][0];
                cx += wrap && lng < 0 ? lng + 360 : lng;
                cy += largestRing[i][1];
            }
            cx /= largestRing.length;
            cy /= largestRing.length;
            if (cx > 180) cx -= 360;
        }

        feat.bounds = [minLng, minLat, maxLng, maxLat];
        feat.centroid = [cx, cy];
        feat.area = largestArea;
    }

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

    // Walked smallest-first so an enclave wins over the country whose bbox contains it.
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

    // Nearest country at sea as { name, km }, measured to the nearest vertex rather than edge.
    function nearestCountry(features, lat, lng) {
        let best = '', bestKm = Infinity;
        for (const feat of features) {
            const b = feat.bounds;
            // Cheap reject: the nearest bbox corner in latitude is already farther than the best.
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

    // Never coordinates; ocean basins other than the polar ones are deliberately not named.
    function describeRegion(features, lat, lng) {
        if (!features || !features.length) return '';
        const land = countryAt(features, lat, lng);
        if (land) return land;
        // Natural Earth's Antarctica ring is clipped at ~-85.6, so name the polar cap directly.
        if (lat <= -85.5) return 'Antarctica';
        // Proximity before polar names, so points just off a coast name that coast.
        const near = nearestCountry(features, lat, lng);
        if (near.name && near.km <= 300) return `Off the coast of ${near.name}`;
        if (lat >= 66.5) return 'Arctic Ocean';
        if (lat <= -60) return 'Southern Ocean';
        if (near.name && near.km <= 1200) return `Ocean near ${near.name}`;
        return 'Open ocean';
    }

    function layerBuilder(closed) {
        const coords = [], ringOff = [0], partRing = [0], bbox = [], partLen = [], partRank = [];
        return {
            addPart(rings, rank) {
                let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity, len = 0, added = 0;
                for (const ring of rings) {
                    if (!ring || ring.length < 2) continue;
                    for (let i = 0; i < ring.length; i++) {
                        const x = ring[i][0], y = ring[i][1];
                        coords.push(x, y);
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                        if (i > 0) {
                            const dx = x - ring[i - 1][0];
                            if (Math.abs(dx) <= 180) len += Math.hypot(dx, y - ring[i - 1][1]);
                        }
                    }
                    ringOff.push(coords.length / 2);
                    added++;
                }
                if (!added) return;
                partRing.push(ringOff.length - 1);
                bbox.push(minX, minY, maxX, maxY);
                partLen.push(len);
                partRank.push(rank || 0);
            },
            build() {
                return {
                    coords: new Float32Array(coords), ringOff: new Int32Array(ringOff), partRing: new Int32Array(partRing),
                    bbox: new Float32Array(bbox), partLen: new Float32Array(partLen), partRank: new Int32Array(partRank), closed
                };
            }
        };
    }

    function layerFromFeatures(features, closed) {
        const b = layerBuilder(closed !== false);
        for (const f of (features || [])) {
            const polys = f.type === 'Polygon' ? [f.coordinates] : f.coordinates;
            for (const poly of polys) b.addPart(poly, 0);
        }
        return b.build();
    }

    function decodeTier(topo) {
        if (!topo || !topo.arcs) return null;
        const tx = topo.transform || { scale: [1, 1], translate: [0, 0] };
        const sx = tx.scale[0], sy = tx.scale[1], dx = tx.translate[0], dy = tx.translate[1];
        const arcs = topo.arcs.map((arc) => {
            let x = 0, y = 0;
            return arc.map(([ax, ay]) => { x += ax; y += ay; return [x * sx + dx, y * sy + dy]; });
        });
        const stitch = (idxs) => {
            const out = [];
            for (let i = 0; i < idxs.length; i++) {
                const k = idxs[i];
                const a = k >= 0 ? arcs[k] : arcs[~k].slice().reverse();
                for (let j = i === 0 ? 0 : 1; j < a.length; j++) out.push(a[j]);
            }
            return out;
        };
        const objects = topo.objects || {};
        const geoms = (name) => (objects[name] && objects[name].geometries) || [];
        const rankOf = (g) => (g.properties && typeof g.properties.rank === 'number') ? g.properties.rank : 0;
        const countries = layerBuilder(true), lakes = layerBuilder(true), rivers = layerBuilder(false);
        const labels = [];
        for (const [name, builder] of [['countries', countries], ['lakes', lakes]]) {
            for (const g of geoms(name)) {
                const polys = g.type === 'Polygon' ? [g.arcs] : (g.type === 'MultiPolygon' ? g.arcs : []);
                const built = [];
                for (const p of polys) {
                    const poly = p.map(stitch);
                    builder.addPart(poly, rankOf(g));
                    built.push(poly);
                }
                const label = name === 'countries' && g.properties && g.properties.name;
                if (label && built.length) {
                    const feat = { type: 'MultiPolygon', name: label, coordinates: built };
                    annotateFeature(feat);
                    labels.push({ name: label, bounds: feat.bounds, centroid: feat.centroid, area: feat.area });
                }
            }
        }
        for (const g of geoms('rivers')) {
            const lines = g.type === 'LineString' ? [g.arcs] : (g.type === 'MultiLineString' ? g.arcs : []);
            rivers.addPart(lines.map(stitch), rankOf(g));
        }
        labels.sort((a, b) => b.area - a.area);
        return { countries: countries.build(), lakes: lakes.build(), rivers: rivers.build(), countryLabels: labels };
    }

    function tierTransfer(t) {
        if (!t || !t.countries) return [];
        const out = [];
        for (const k of ['countries', 'lakes', 'rivers']) {
            const l = t[k];
            out.push(l.coords.buffer, l.ringOff.buffer, l.partRing.buffer, l.bbox.buffer, l.partLen.buffer, l.partRank.buffer);
        }
        return out;
    }

    function decodeByKind(kind, json) {
        if (kind === 'tier') return decodeTier(json);
        if (kind === 'world') return decodeWorld(json);
        if (kind === 'admin1') return decodeAdmin1(json);
        if (kind === 'cities') return decodeCities(json);
        return [];
    }

    (typeof self !== 'undefined' ? self : window).NymGeoDecode = {
        decodeTopoJson, annotateFeature, decodeWorld, decodeAdmin1, decodeCities, decodeByKind,
        decodeTier, layerFromFeatures, tierTransfer,
        pointInFeature, countryAt, nearestCountry, describeRegion
    };
})();
