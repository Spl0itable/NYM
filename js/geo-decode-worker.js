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
            const transfer = d.kind === 'tier' ? self.NymGeoDecode.tierTransfer(features) : [];
            self.postMessage({ seq, features }, transfer);
        } catch (err) {
            self.postMessage({ seq, error: String(err && err.message || err) });
        }
    })();
};
