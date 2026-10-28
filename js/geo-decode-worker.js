importScripts('/js/geo-decode.js', '/js/modules/geo-places.js');

self.onmessage = (e) => {
    const d = e.data || {};
    const seq = d.seq;
    (async () => {
        try {
            if (d.kind === 'places') {
                const pack = await self.NymGeoPlaces.fetchPack(d.url);
                self.postMessage({ seq, features: pack }, self.NymGeoPlaces.transferList(pack));
                return;
            }
            const resp = await fetch(d.url, { cache: 'force-cache' });
            if (!resp || !resp.ok) { self.postMessage({ seq, features: [] }); return; }
            const json = await resp.json();
            const features = self.NymGeoDecode.decodeByKind(d.kind, json);
            const transfer = d.kind === 'tier' ? self.NymGeoDecode.tierTransfer(features) : [];
            self.postMessage({ seq, features }, transfer);
        } catch (err) {
            self.postMessage({ seq, error: String(err && err.message || err) });
        }
    })();
};
