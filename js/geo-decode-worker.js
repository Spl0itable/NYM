// geo-decode-worker.js - Fetches and decodes the geohash globe's map data

importScripts('/js/geo-decode.js');

self.onmessage = (e) => {
    const d = e.data || {};
    const seq = d.seq;
    (async () => {
        try {
            const resp = await fetch(d.url, { cache: 'force-cache' });
            if (!resp || !resp.ok) { self.postMessage({ seq, features: [] }); return; }
            const json = await resp.json();
            const features = self.NymGeoDecode.decodeByKind(d.kind, json);
            self.postMessage({ seq, features });
        } catch (err) {
            self.postMessage({ seq, error: String(err && err.message || err) });
        }
    })();
};
