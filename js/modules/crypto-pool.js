// crypto-pool.js - Routes heavy crypto across a pool of Web Workers

(function () {
    const MAX_WORKERS = 4;

    // Worker dispatcher source (runs inside the blob worker).
    const WORKER_SRC = "let ready=false;self.onmessage=function(e){var d=e.data||{},id=d.id,op=d.op,args=d.args;" +
        "if(op==='__init'){try{self.importScripts.apply(self,args[0].scripts);ready=!!self.NymCrypto;self.postMessage({id:id,ok:ready});}" +
        "catch(err){self.postMessage({id:id,ok:false,error:String(err&&err.message||err)});}return;}" +
        "if(!ready||typeof self.NymCrypto[op]!=='function'){self.postMessage({id:id,ok:false,error:'unavailable: '+op});return;}" +
        "try{self.postMessage({id:id,ok:true,result:self.NymCrypto[op].apply(null,args)});}" +
        "catch(e2){self.postMessage({id:id,ok:false,error:String(e2&&e2.message||e2)});}};";

    const scriptUrl = (match) => {
        const el = document.querySelector('script[src*="' + match + '"]');
        return el ? el.src : null;
    };

    Object.assign(NYM.prototype, {

        _ensureCryptoPool() {
            if (this._cryptoPoolReady) return this._cryptoPoolReady;
            this._cryptoPending = new Map();
            this._cryptoSeq = 0;
            this._cryptoPool = null;
            this._cryptoPoolReady = new Promise((resolve) => {
                const ntUrl = scriptUrl('nostr-tools'), ncUrl = scriptUrl('nym-crypto');
                if (typeof Worker === 'undefined' || typeof Blob === 'undefined' ||
                    typeof window.NymCrypto === 'undefined' || !ntUrl || !ncUrl ||
                    !window.URL || !URL.createObjectURL) { resolve(null); return; }
                let blobUrl;
                try { blobUrl = URL.createObjectURL(new Blob([WORKER_SRC], { type: 'text/javascript' })); }
                catch (_) { resolve(null); return; }
                const scripts = [ntUrl, ncUrl];
                const n = Math.max(1, Math.min(navigator.hardwareConcurrency || 2, MAX_WORKERS));
                const pool = [];
                let pendingInit = 0, settled = false;
                const finish = () => {
                    if (settled) return;
                    settled = true;
                    try { URL.revokeObjectURL(blobUrl); } catch (_) { }
                    this._cryptoPool = pool.length ? pool : null;
                    resolve(this._cryptoPool);
                };
                const failInflight = (rec) => {
                    for (const [id, p] of this._cryptoPending) {
                        if (p.rec !== rec) continue;
                        this._cryptoPending.delete(id);
                        if (p.timer) clearTimeout(p.timer);
                        p.resolve(p.fallback());
                    }
                };
                for (let k = 0; k < n; k++) {
                    let w;
                    try { w = new Worker(blobUrl); } catch (_) { continue; }
                    const rec = { w, busy: 0 };
                    pendingInit++;
                    const drop = () => { const i = pool.indexOf(rec); if (i >= 0) pool.splice(i, 1); failInflight(rec); this._cryptoPool = pool.length ? pool : null; };
                    w.onerror = drop;
                    w.onmessageerror = drop;
                    w.onmessage = (ev) => {
                        const { id, ok, result } = ev.data || {};
                        if (id === 0) { if (ok) pool.push(rec); else { try { w.terminate(); } catch (_) { } } if (--pendingInit === 0) finish(); return; }
                        const p = this._cryptoPending.get(id);
                        if (!p) return;
                        this._cryptoPending.delete(id);
                        if (p.timer) clearTimeout(p.timer);
                        rec.busy--;
                        p.resolve(ok ? result : p.fallback());
                    };
                    try { w.postMessage({ id: 0, op: '__init', args: [{ scripts }] }); }
                    catch (_) { pendingInit--; }
                }
                if (pendingInit === 0) finish();
            });
            return this._cryptoPoolReady;
        },

        async _cryptoCall(op, args, fallback) {
            const run = fallback || (() => window.NymCrypto[op](...args));
            let pool;
            try { pool = await this._ensureCryptoPool(); } catch (_) { pool = null; }
            if (!pool || !pool.length) return run();
            let rec = pool[0];
            for (const r of pool) if (r.busy < rec.busy) rec = r;
            return new Promise((resolve) => {
                const id = ++this._cryptoSeq;
                const entry = { resolve, fallback: run, rec, timer: null };
                if (op !== 'minePow') entry.timer = setTimeout(() => { if (this._cryptoPending.delete(id)) { rec.busy--; resolve(run()); } }, 20000);
                this._cryptoPending.set(id, entry);
                rec.busy++;
                try { rec.w.postMessage({ id, op, args }); }
                catch (_) { this._cryptoPending.delete(id); rec.busy--; if (entry.timer) clearTimeout(entry.timer); resolve(run()); }
            });
        },
    });
})();
