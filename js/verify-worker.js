importScripts('/js/nostr-tools.js');

self.onmessage = (e) => {
    const d = e.data || {};
    let ok = false;
    try {
        ok = NostrTools.verifyEvent(d.event) === true;
    } catch (_) { }
    self.postMessage({ seq: d.seq, ok });
};
