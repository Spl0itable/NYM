// panic.js — Emergency wipe

Object.assign(NYM.prototype, {

  _PANIC_PURGE_MS: 3000,

  _PANIC_HOLD_MS: 2000,   // press-and-hold the "Your Nym" section this long to wipe

  // Click opens the nick editor; press-and-hold triggers the emergency wipe.
  bindNymPanicGesture() {
    const el = document.querySelector('.nym-display');
    if (!el || el._panicBound) return;
    this.bindPanicHold(el, () => this.panicWipe());
  },

  bindPanicHold(el, fire) {
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
        fire();
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
      if (!this.pubkey) return false;
      if (!this.privkey && this.nostrLoginMethod !== 'extension' && this.nostrLoginMethod !== 'nip46') return false;
      const apiHost = this._getApiHost && this._getApiHost();
      if (!apiHost) return false;
      await this._panicSignalActive();
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

  async _panicSignalActive() {
    try {
      if (typeof this.remotePanicSignal !== 'function' || !this.remotePanicEnabled()) return;
      const pubkey = this.pubkey;
      const secret = this.privkey;
      const sign = secret
        ? (ev) => Promise.resolve(window.NostrTools.finalizeEvent(ev, secret))
        : (ev) => this.signEvent(ev);
      await this.remotePanicSignal(sign, pubkey, { enabled: true, secret: secret || null });
    } catch (e) {}
  },

  async _panicSignalOther(a, sign) {
    try {
      if (typeof this.remotePanicSignal !== 'function') return;
      const A = window.NymAccounts;
      let on = null;
      try { on = await A.stashKey(a.id, 'nym_remote_panic'); } catch (e) { on = null; }
      if (on !== '1') return;
      await this.remotePanicSignal(sign, a.pubkey, { enabled: true });
    } catch (e) {}
  },

  _panicText(text, vars) {
    let out = typeof this.uiText === 'function' ? this.uiText(text) : text;
    if (vars) for (const k of Object.keys(vars)) out = out.split('{' + k + '}').join(String(vars[k]));
    return out;
  },

  _panicPurgeBody(app, pubkey, auth) {
    return JSON.stringify({ action: 'account-purge', app: app || 'nymchat', pubkey, auth });
  },

  _panicPurgeSend(body) {
    const apiHost = this._getApiHost && this._getApiHost();
    if (!apiHost) return Promise.resolve(false);
    return this._edgeFetch(`https://${apiHost}/api/storage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      keepalive: true
    }).then(() => true, () => false);
  },

  _panicAuthTemplate(pubkey) {
    const apiHost = this._getApiHost && this._getApiHost();
    const tags = [['domain', 'nymbot-pm'], ['method', 'POST']];
    if (apiHost) tags.push(['u', `https://${apiHost}/api/storage`]);
    tags.push(['action', 'account-purge']);
    return { kind: 27235, created_at: Math.floor(Date.now() / 1000), tags, content: 'nymbot-pm-auth', pubkey };
  },

  async _panicOtherSigner(a) {
    const A = window.NymAccounts;
    const names = a.method === 'nsec' ? ['nym_nostr_login_nsec'] : (a.method === 'ephemeral' ? ['nym_session_nsec', 'nym_dev_nsec'] : []);
    for (const n of names) {
      let v = null;
      try { v = await A.stashKey(a.id, n); } catch (e) { v = null; }
      if (!v || String(v).startsWith('enc:v1:')) continue;
      try {
        const sk = this.decodeNsec(v);
        if (window.NostrTools.getPublicKey(sk) !== a.pubkey) continue;
        return (ev) => Promise.resolve(window.NostrTools.finalizeEvent(ev, sk));
      } catch (e) {}
    }
    if (a.method === 'extension' && window.nostr && window.nostr.getPublicKey && window.nostr.signEvent) {
      try {
        const live = await Promise.race([window.nostr.getPublicKey(), new Promise((r) => setTimeout(() => r(null), 800))]);
        if (live === a.pubkey) return (ev) => window.nostr.signEvent(ev);
      } catch (e) {}
    }
    return null;
  },

  async _panicPurgeAll(app, out) {
    const jobs = [];
    let skipped = 0;
    const A = window.NymAccounts;
    let others = [];
    try { if (A && typeof A.read === 'function') others = A.read().accounts.filter((a) => a.pubkey && a.pubkey !== this.pubkey); } catch (e) { others = []; }
    if (this.pubkey) {
      const live = !!this.privkey || this.nostrLoginMethod === 'extension' || this.nostrLoginMethod === 'nip46';
      if (live) jobs.push(this.purgeServerRecords(app).then((ok) => { if (!ok) skipped++; }));
      else skipped++;
    }
    const signers = await Promise.all(others.map((a) => this._panicOtherSigner(a).catch(() => null)));
    others.forEach((a, i) => {
      const sign = signers[i];
      if (!sign) { skipped++; return; }
      jobs.push(Promise.resolve().then(async () => {
        await this._panicSignalOther(a, sign);
        const auth = await sign(this._panicAuthTemplate(a.pubkey));
        if (!auth || auth.pubkey !== a.pubkey) throw new Error('signer');
        return this._panicPurgeSend(this._panicPurgeBody(app, a.pubkey, auth));
      }).then((ok) => { if (!ok) skipped++; }, () => { skipped++; }));
    });
    out.skipped = skipped;
    await Promise.all(jobs);
    out.skipped = skipped;
  },

  async panicWipe(opts) {
    if (this._panicking) return;
    this._panicking = true;
    const localOnly = !!(opts && opts.localOnly);
    const startedAt = Date.now();
    const accountDbs = [];
    try {
      const A = window.NymAccounts;
      if (A && typeof A.read === 'function') A.read().accounts.forEach((a) => accountDbs.push(A.dbName('nym-cache', a)));
      if (A && typeof A.pageDb === 'function') accountDbs.push(A.pageDb('nym-cache'));
    } catch (e) {}

    const ui = this._panicShowOverlay();

    // Bounded: a wipe that waits on the network is a wipe that did not happen.
    const purge = { skipped: null };
    const purged = localOnly ? Promise.resolve() : Promise.race([
      this._panicPurgeAll('nymchat', purge),
      new Promise((done) => setTimeout(done, this._PANIC_PURGE_MS))
    ]);
    try { await purged; } catch (e) { }
    if (purge.skipped) {
      try {
        ui.setStatus(purge.skipped === 1
          ? this._panicText("Server records for 1 identity couldn't be removed")
          : this._panicText("Server records for {n} identities couldn't be removed", { n: purge.skipped }));
      } catch (e) {}
    }

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
      const open = this._cacheDbPromise;
      this._cacheOpen = () => Promise.reject(new Error('wiped'));
      this._cacheDbPromise = null;
      if (open) {
        const db = await Promise.race([open, new Promise((r) => setTimeout(() => r(null), 500))]);
        if (db && db.close) db.close();
      }
    } catch (e) {}
    try {
      const names = new Set(['nym-cache', 'nym-accounts'].concat(accountDbs));
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
