/* eslint-env worker */

try {
    importScripts('../nostr-tools.js');
} catch (e) {
    self.postMessage({ jobId: 'init', error: 'nip13-miner: nostr-tools load failed: ' + (e && e.message || e) });
}

self.onmessage = (e) => {
    const { event, difficulty, jobId } = e.data || {};
    if (!jobId) return;
    try {
        const NT = self.NostrTools || NostrTools;
        const mined = NT.nip13.minePow(event, difficulty);
        self.postMessage({ jobId, event: mined });
    } catch (err) {
        self.postMessage({ jobId, error: String(err && err.message || err) });
    }
};
