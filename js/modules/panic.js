// panic.js — Emergency wipe

Object.assign(NYM.prototype, {

  _PANIC_HOLD_MS: 2000,   // press-and-hold the "Your Nym" section this long to wipe

  // Click opens the nick editor; press-and-hold triggers the emergency wipe.
  bindNymPanicGesture() {
    const el = document.querySelector('.nym-display');
    if (!el || el._panicBound) return;
    el._panicBound = true;
    let timer = null;
    const cancel = () => { if (timer) { clearTimeout(timer); timer = null; } };
    const start = (e) => {
      if (e.type === 'mousedown' && e.button !== 0) return;
      cancel();
      this._panicFired = false;
      timer = setTimeout(() => {
        timer = null;
        this._panicFired = true;
        if (window.nymHapticTap) window.nymHapticTap();
        this.panicWipe();
      }, this._PANIC_HOLD_MS);
    };
    el.addEventListener('mousedown', start);
    el.addEventListener('touchstart', start, { passive: true });
    el.addEventListener('mouseup', cancel);
    el.addEventListener('mouseleave', cancel);
    el.addEventListener('touchend', cancel);
    el.addEventListener('touchmove', cancel, { passive: true });
    el.addEventListener('touchcancel', cancel);
    el.addEventListener('contextmenu', (e) => { e.preventDefault(); });
    // Capture phase: swallow the post-hold click before the delegated editNick handler opens the editor.
    el.addEventListener('click', (e) => {
      if (this._panicFired) { this._panicFired = false; e.stopPropagation(); e.preventDefault(); }
    }, true);
  },

  _panicJunk() {
    try {
      const a = new Uint8Array(2048);
      crypto.getRandomValues(a);
      let s = '';
      for (let i = 0; i < a.length; i++) s += String.fromCharCode(a[i]);
      return btoa(s);
    } catch (e) {
      return String(Math.random()).repeat(128);
    }
  },

  // Signed while the key is still here, sent keepalive so the reload can't cancel it; skipped for signer logins.
  async purgeServerRecords(app) {
    try {
      if (!this.pubkey || !this.privkey) return false;
      const apiHost = this._getApiHost && this._getApiHost();
      if (!apiHost) return false;
      const body = JSON.stringify({
        action: 'account-purge',
        app: app || 'nymchat',
        pubkey: this.pubkey,
        auth: await this._signBotAuth('account-purge', 'storage')
      });
      await this._edgeFetch(`https://${apiHost}/api/storage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body,
        keepalive: true
      });
      return true;
    } catch (e) { return false; }
  },

  async panicWipe() {
    if (this._panicking) return;
    this._panicking = true;
    const startedAt = Date.now();

    const ui = this._panicShowOverlay();

    // Bounded: a wipe that waits on the network is a wipe that did not happen.
    const purged = Promise.race([
      this.purgeServerRecords('nymchat'),
      new Promise((done) => setTimeout(done, 2500))
    ]);
    try { await purged; } catch (e) { }

    try { this._cacheDisabled = true; } catch (e) {}
    for (const t of ['_trimTimer', '_dedupPersistTimer', '_poolStatePersistTimer', '_pendingPersistTimer']) {
      try { if (this[t]) { clearTimeout(this[t]); this[t] = null; } } catch (e) {}
    }
    try {
      if (this.relayPool && typeof this.relayPool.forEach === 'function') {
        this.relayPool.forEach((relay) => { try { relay && relay.ws && relay.ws.close(); } catch (e) {} });
      }
    } catch (e) {}
    try { if (this.proxyWs && this.proxyWs.close) this.proxyWs.close(); } catch (e) {}

    try {
      this.privkey = null; this.pubkey = null;
      this._vaultKey = null; this._vaultMem = null; this._botAuthCache = null;
    } catch (e) {}
    // The sweep below takes the stored PQ root; this drops the decoded copy that rebuilds every ML-KEM key.
    try { if (typeof this.pqRootWipe === 'function') this.pqRootWipe(); } catch (e) {}

    // Encrypt storage under a discarded key so surviving bytes are unrecoverable, then overwrite and clear.
    try { ui.setStatus('Encrypting local store with a random key…'); } catch (e) {}
    try { await this._panicEncryptStorage(); } catch (e) {}
    for (const store of [window.localStorage, window.sessionStorage]) {
      try {
        const keys = [];
        for (let i = 0; i < store.length; i++) keys.push(store.key(i));
        for (const k of keys) { try { store.setItem(k, this._panicJunk()); } catch (e) {} }
        store.clear();
      } catch (e) {}
    }

    try { ui.setStatus('Shredding local databases…'); } catch (e) {}
    try {
      const names = new Set(['nym-cache']);
      try {
        if (indexedDB.databases) {
          const dbs = (await indexedDB.databases()) || [];
          dbs.forEach((d) => { if (d && d.name) names.add(d.name); });
        }
      } catch (e) {}
      await Promise.all([...names].map((name) => this._panicWipeDb(name)));
    } catch (e) {}

    try { ui.setStatus('Purging caches…'); } catch (e) {}
    try {
      if (window.caches && caches.keys) {
        const ks = await caches.keys();
        await Promise.all(ks.map((k) => caches.delete(k)));
      }
    } catch (e) {}
    try {
      if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
        const regs = await navigator.serviceWorker.getRegistrations();
        await Promise.all(regs.map((r) => r.unregister()));
      }
    } catch (e) {}

    try {
      document.cookie.split(';').forEach((c) => {
        const name = c.split('=')[0].trim();
        if (name) {
          document.cookie = name + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/';
          document.cookie = name + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=' + location.hostname;
        }
      });
    } catch (e) {}

    try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}
    try { ui.setStatus('Keys destroyed.'); } catch (e) {}
    const minMs = 1500;
    const wait = Math.max(250, minMs - (Date.now() - startedAt));
    setTimeout(() => {
      try { location.replace(location.origin + location.pathname); }
      catch (e) { try { location.reload(); } catch (e2) {} }
    }, wait);
  },

  // Best-effort, time-boxed; the junk overwrite + clear that follow are what guarantee removal.
  async _panicEncryptStorage() {
    let key;
    try { key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt']); }
    catch (e) { return; }
    const enc = new TextEncoder();
    const budgetUntil = Date.now() + 600; // don't let this delay destruction
    for (const store of [window.localStorage, window.sessionStorage]) {
      let keys = [];
      try { for (let i = 0; i < store.length; i++) keys.push(store.key(i)); } catch (e) {}
      for (const k of keys) {
        if (Date.now() > budgetUntil) return;
        try {
          const v = store.getItem(k);
          if (v == null) continue;
          const iv = crypto.getRandomValues(new Uint8Array(12));
          const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, enc.encode(v));
          const out = new Uint8Array(12 + ct.byteLength);
          out.set(iv, 0); out.set(new Uint8Array(ct), 12);
          let s = ''; for (let i = 0; i < out.length; i++) s += String.fromCharCode(out[i]);
          store.setItem(k, 'panic:' + btoa(s));
        } catch (e) {}
      }
    }
  },

  // Backdrop stays opaque so sensitive content is hidden while destruction runs.
  _panicShowOverlay() {
    let interval = null;
    let statusEl = null;
    try {
      const ov = document.createElement('div');
      ov.className = 'nm-panic-overlay';

      const title = document.createElement('div');
      title.className = 'nm-panic-title';
      title.textContent = 'Encrypting';

      const grid = document.createElement('div');
      grid.className = 'nm-panic-grid';

      statusEl = document.createElement('div');
      statusEl.className = 'nm-panic-status';
      statusEl.textContent = 'Initializing…';

      const bar = document.createElement('div');
      bar.className = 'nm-panic-bar';
      const fill = document.createElement('div');
      fill.className = 'nm-panic-fill';
      bar.appendChild(fill);

      const charset = '0123456789ABCDEF·×÷=+/\\<>{}[]#@$%&';
      const cols = 40, rows = 8;
      const rnd = () => {
        let buf;
        try { buf = crypto.getRandomValues(new Uint8Array(cols * rows)); } catch (e) { buf = null; }
        let out = '';
        for (let r = 0; r < rows; r++) {
          for (let c = 0; c < cols; c++) {
            const n = buf ? buf[r * cols + c] : Math.floor(Math.random() * 256);
            out += charset[n % charset.length];
          }
          out += '\n';
        }
        return out;
      };

      grid.textContent = rnd();
      ov.appendChild(title);
      ov.appendChild(grid);
      ov.appendChild(statusEl);
      ov.appendChild(bar);
      (document.body || document.documentElement).appendChild(ov);

      interval = setInterval(() => { try { grid.textContent = rnd(); } catch (e) {} }, 60);
    } catch (e) {}

    return {
      setStatus: (text) => { try { if (statusEl) statusEl.textContent = text; } catch (e) {} },
      stop: () => { try { if (interval) clearInterval(interval); } catch (e) {} }
    };
  },

  // Resolves (never rejects) and self-times-out so a blocked DB can't hang the wipe.
  _panicWipeDb(name) {
    return new Promise((resolve) => {
      let settled = false;
      const finish = (db) => {
        if (settled) return;
        settled = true;
        try { if (db) db.close(); } catch (e) {}
        try { indexedDB.deleteDatabase(name); } catch (e) {}
        resolve();
      };
      let req;
      try { req = indexedDB.open(name); } catch (e) { return finish(null); }
      req.onerror = () => finish(null);
      req.onblocked = () => finish(null);
      req.onsuccess = () => {
        const db = req.result;
        let stores = [];
        try { stores = Array.from(db.objectStoreNames || []); } catch (e) { stores = []; }
        if (!stores.length) return finish(db);
        try {
          const tx = db.transaction(stores, 'readwrite');
          for (const s of stores) {
            try {
              const os = tx.objectStore(s);
              for (let i = 0; i < 3; i++) {
                try { os.put({ _panic: this._panicJunk() }, '__panic_' + i); } catch (e) {}
              }
              os.clear();
            } catch (e) {}
          }
          tx.oncomplete = () => finish(db);
          tx.onerror = () => finish(db);
          tx.onabort = () => finish(db);
        } catch (e) {
          finish(db);
        }
      };
      setTimeout(() => finish(null), 1500);
    });
  }

});
