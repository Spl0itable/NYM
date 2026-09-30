window.nymSecretGet = function (name) {
  try { return (window.nym && window.nym.secretGet) ? window.nym.secretGet(name) : localStorage.getItem(name); }
  catch (e) { return null; }
};
window.nymSecretSet = function (name, val) {
  if (window.nym && window.nym.secretSet) return window.nym.secretSet(name, val);
  try { localStorage.setItem(name, val); } catch (e) {}
};
window.nymSecretRemove = function (name) {
  if (window.nym && window.nym.secretRemove) return window.nym.secretRemove(name);
  try { localStorage.removeItem(name); } catch (e) {}
};

Object.assign(NYM.prototype, {

  // `nym_pq_root` seeds the ML-KEM identity key, so it is protected and reset exactly like the nsec (spec §5.3).
  _VAULT_KEYS: ['nym_session_nsec', 'nym_dev_nsec', 'nym_nostr_login_nsec', 'nym_nip46_client_secret',
    'nym_pq_root', 'nym_botpm_git'],

  // Prefixes of extra secrets encrypted alongside the identity keys (per-pubkey group ephemeral keys).
  _VAULT_EXTRA_PREFIXES: ['nym_ephemeral_keys_'],

  _vaultExtraKeyNames() {
    const names = [];
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const name = localStorage.key(i);
        if (name && (this._VAULT_EXTRA_PREFIXES.some(p => name.startsWith(p)) || /^nym_botanon_[0-9a-f]{64}$/.test(name))) names.push(name);
      }
    } catch (e) {}
    return names;
  },

  // Vault must be unlocked.
  async _vaultProtectExtras() {
    if (!this._vaultKey) return;
    for (const name of this._vaultExtraKeyNames()) {
      try {
        const cur = localStorage.getItem(name);
        if (cur == null || String(cur).startsWith('enc:v1:')) continue;
        localStorage.setItem(name, await this._vaultEncrypt(cur));
      } catch (e) {}
    }
  },

  // Vault must be unlocked.
  async _vaultUnprotectExtras() {
    if (!this._vaultKey) return;
    for (const name of this._vaultExtraKeyNames()) {
      try {
        const cur = localStorage.getItem(name);
        if (!cur || !String(cur).startsWith('enc:v1:')) continue;
        localStorage.setItem(name, await this._vaultDecrypt(cur));
      } catch (e) {}
    }
  },

  _vaultDiscardExtras() {
    for (const name of this._vaultExtraKeyNames()) {
      try {
        const cur = localStorage.getItem(name);
        if (cur && String(cur).startsWith('enc:v1:')) localStorage.removeItem(name);
      } catch (e) {}
    }
  },

  // The PM/group cache mirrors E2E conversations, so it must not stay readable on disk with the vault on.
  async _vaultProtectPmCache() {
    if (!this._vaultKey || typeof this._cacheGetAll !== 'function') return;
    try {
      const all = await this._cacheGetAll('pms');
      for (const rec of all) {
        if (!rec || !rec.key || !Array.isArray(rec.messages)) continue;
        try {
          const payload = await this._vaultEncrypt(JSON.stringify(rec.messages));
          await this._cachePut('pms', { key: rec.key, enc: 'v1', payload });
        } catch (e) {}
      }
    } catch (e) {}
  },

  // Runs while the vault key is still in memory so records don't become unreadable.
  async _vaultUnprotectPmCache() {
    if (!this._vaultKey || typeof this._cacheGetAll !== 'function') return;
    try {
      const all = await this._cacheGetAll('pms');
      for (const rec of all) {
        if (!rec || !rec.key || rec.enc !== 'v1' || typeof rec.payload !== 'string') continue;
        try {
          const messages = JSON.parse(await this._vaultDecrypt(rec.payload));
          await this._cachePut('pms', { key: rec.key, messages });
        } catch (e) {}
      }
    } catch (e) {}
  },

  vaultEnabled() {
    try { return localStorage.getItem('nym_vault_enabled') === '1'; } catch (e) { return false; }
  },
  vaultMethod() {
    try { return localStorage.getItem('nym_vault_method') || 'password'; } catch (e) { return 'password'; }
  },
  vaultUnlocked() { return !!this._vaultKey; },

  secretGet(name) {
    try {
      if (this.vaultEnabled()) {
        if (this._vaultMem && this._vaultMem.has(name)) return this._vaultMem.get(name);
        return null;
      }
      return localStorage.getItem(name);
    } catch (e) { return null; }
  },

  async secretSet(name, val) {
    try {
      if (this.vaultEnabled() && this._vaultKey) {
        if (!this._vaultMem) this._vaultMem = new Map();
        this._vaultMem.set(name, val);
        localStorage.setItem(name, await this._vaultEncrypt(val));
      } else {
        localStorage.setItem(name, val);
      }
    } catch (e) { }
  },

  secretRemove(name) {
    try { if (this._vaultMem) this._vaultMem.delete(name); } catch (e) {}
    try { localStorage.removeItem(name); } catch (e) {}
  },

  _vb64(bytes) { let s = ''; const b = new Uint8Array(bytes); for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s); },
  _vb64d(str) { const s = atob(str); const b = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i); return b; },

  async _vaultEncrypt(plaintext) {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, this._vaultKey, new TextEncoder().encode(plaintext));
    return 'enc:v1:' + this._vb64(iv) + ':' + this._vb64(new Uint8Array(ct));
  },
  async _vaultDecrypt(blob) {
    const p = String(blob).split(':');
    if (p.length !== 4 || p[0] !== 'enc' || p[1] !== 'v1') throw new Error('bad blob');
    const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: this._vb64d(p[2]) }, this._vaultKey, this._vb64d(p[3]));
    return new TextDecoder().decode(pt);
  },

  async _deriveKeyFromPassword(password, salt) {
    const base = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveKey']);
    return crypto.subtle.deriveKey(
      { name: 'PBKDF2', salt, iterations: 310000, hash: 'SHA-256' },
      base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  },

  webauthnAvailable() {
    return !!(window.PublicKeyCredential && navigator.credentials &&
      navigator.credentials.create && navigator.credentials.get);
  },

  async biometricAvailable() {
    try {
      if (!this.webauthnAvailable()) return false;
      if (!PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable) return false;
      return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
    } catch (e) { return false; }
  },

  _vaultIsWebAuthn(method) { return method === 'biometric' || method === 'passkey'; },

  // On Apple platforms Biometric and Passkey are the same Face/Touch ID flow, so Biometric is hidden.
  _biometricRedundantWithPasskey() {
    try {
      const ua = navigator.userAgent || '';
      const iOS = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
      const macSafari = /Macintosh/.test(ua) && /Safari/.test(ua) && !/Chrome|Chromium|Edg|OPR/.test(ua);
      return iOS || macSafari;
    } catch (e) { return false; }
  },

  // platformOnly pins the built-in authenticator; otherwise the OS picker may offer synced passkeys and security keys.
  _webauthnRpId() { return location.hostname; },

  async _webauthnEnroll(salt, platformOnly) {
    const userId = crypto.getRandomValues(new Uint8Array(16));
    const authenticatorSelection = { userVerification: 'required', residentKey: 'required' };
    if (platformOnly) authenticatorSelection.authenticatorAttachment = 'platform';
    const cred = await navigator.credentials.create({ publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      rp: { name: 'Nymchat', id: this._webauthnRpId() },
      user: { id: userId, name: 'nym-vault', displayName: 'Nymchat Vault' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
      authenticatorSelection,
      timeout: 60000,
      extensions: { prf: {} }
    }});
    if (!cred) throw new Error('Passkey enrollment was canceled.');
    // Derive via a follow-up get(), since PRF results are only reliable on get; also fails fast without PRF.
    const credId = this._vb64(new Uint8Array(cred.rawId));
    const key = await this._webauthnDeriveKey(credId, salt);
    return { credId, key };
  },

  async _webauthnDeriveKey(credId, salt) {
    const assertion = await navigator.credentials.get({ publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      allowCredentials: [{ id: this._vb64d(credId), type: 'public-key' }],
      userVerification: 'required',
      timeout: 60000,
      extensions: { prf: { eval: { first: salt } } }
    }});
    const ext = assertion && assertion.getClientExtensionResults ? assertion.getClientExtensionResults() : {};
    if (!ext.prf || !ext.prf.results || !ext.prf.results.first) {
      throw new Error('This passkey/authenticator does not support key derivation (WebAuthn PRF). Try a different passkey, or use a password or PIN instead.');
    }
    const prfOut = new Uint8Array(ext.prf.results.first);
    const base = await crypto.subtle.importKey('raw', prfOut, 'HKDF', false, ['deriveKey']);
    return crypto.subtle.deriveKey(
      { name: 'HKDF', salt: new Uint8Array(0), info: new TextEncoder().encode('nym-vault'), hash: 'SHA-256' },
      base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  },

  async enableVault(method, password) {
    if (this.vaultEnabled()) throw new Error('Encryption is already enabled.');
    const salt = crypto.getRandomValues(new Uint8Array(16));
    let credId = null;
    if (this._vaultIsWebAuthn(method)) {
      const r = await this._webauthnEnroll(salt, method === 'biometric');
      this._vaultKey = r.key;
      credId = r.credId;
    } else {
      if (!password || String(password).length < 4) throw new Error('Choose a password or PIN of at least 4 characters.');
      this._vaultKey = await this._deriveKeyFromPassword(String(password), salt);
    }
    this._vaultMem = new Map();
    for (const name of this._VAULT_KEYS) {
      let cur = null;
      try { cur = localStorage.getItem(name); } catch (e) {}
      if (cur == null || String(cur).startsWith('enc:v1:')) continue;
      this._vaultMem.set(name, cur);
      try { localStorage.setItem(name, await this._vaultEncrypt(cur)); } catch (e) {}
    }
    await this._vaultProtectExtras();
    await this._vaultProtectPmCache();
    try {
      localStorage.setItem('nym_vault_salt', this._vb64(salt));
      localStorage.setItem('nym_vault_method', this._vaultIsWebAuthn(method) ? method : 'password');
      if (credId) localStorage.setItem('nym_vault_cred', credId);
      // A known token under the vault key lets unlock verify the key even with no identity secret stored.
      localStorage.setItem('nym_vault_check', await this._vaultEncrypt('nymchat-vault-ok'));
      localStorage.setItem('nym_vault_enabled', '1');
      // Only the non-sensitive preference syncs; clearing "don't ask" re-enables prompting on new devices.
      localStorage.setItem('nym_encrypt_at_rest_pref', '1');
      localStorage.removeItem('nym_encrypt_at_rest_prompt_dismissed');
    } catch (e) {
      throw new Error('Could not persist encryption settings.');
    }
    try { if (typeof nostrSettingsSave === 'function') nostrSettingsSave(); } catch (e) {}
  },

  // Requires the vault to be unlocked.
  async disableVault() {
    if (!this.vaultEnabled()) return;
    if (!this._vaultKey) throw new Error('Unlock first to disable encryption.');
    for (const name of this._VAULT_KEYS) {
      let plain = this._vaultMem && this._vaultMem.has(name) ? this._vaultMem.get(name) : null;
      if (plain == null) {
        try {
          const blob = localStorage.getItem(name);
          if (blob && String(blob).startsWith('enc:v1:')) plain = await this._vaultDecrypt(blob);
        } catch (e) {}
      }
      try {
        if (plain != null) localStorage.setItem(name, plain);
      } catch (e) {}
    }
    await this._vaultUnprotectExtras();
    await this._vaultUnprotectPmCache();
    try {
      localStorage.removeItem('nym_vault_enabled');
      localStorage.removeItem('nym_vault_salt');
      localStorage.removeItem('nym_vault_method');
      localStorage.removeItem('nym_vault_cred');
      localStorage.removeItem('nym_vault_check');
    } catch (e) {}
    this._vaultKey = null;
    this._vaultMem = null;
  },

  // Proves passkey/biometric unlock with a fresh authenticator round-trip; password/PIN needs none.
  async testVaultUnlock() {
    if (!this.vaultEnabled() || !this._vaultIsWebAuthn(this.vaultMethod())) return true;
    try {
      const salt = this._vb64d(localStorage.getItem('nym_vault_salt') || '');
      const credId = localStorage.getItem('nym_vault_cred');
      if (!credId) return false;
      const freshKey = await this._webauthnDeriveKey(credId, salt);
      const blob = localStorage.getItem('nym_vault_check');
      if (!blob) return false;
      const p = String(blob).split(':');
      if (p.length !== 4 || p[0] !== 'enc' || p[1] !== 'v1') return false;
      const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: this._vb64d(p[2]) }, freshKey, this._vb64d(p[3]));
      return new TextDecoder().decode(pt) === 'nymchat-vault-ok';
    } catch (e) { return false; }
  },

  async unlockVault(password) {
    if (!this.vaultEnabled()) return true;
    let salt;
    try { salt = this._vb64d(localStorage.getItem('nym_vault_salt') || ''); } catch (e) { throw new Error('Vault metadata is corrupt.'); }
    if (this._vaultIsWebAuthn(this.vaultMethod())) {
      const credId = localStorage.getItem('nym_vault_cred');
      if (!credId) throw new Error('Passkey credential is missing.');
      this._vaultKey = await this._webauthnDeriveKey(credId, salt);
    } else {
      if (!password) throw new Error('Enter your password or PIN.');
      this._vaultKey = await this._deriveKeyFromPassword(String(password), salt);
    }
    // Verify against the check token first; _vaultDecrypt throws on the AES-GCM tag if the key is wrong.
    const mem = new Map();
    let verifiedOne = false;
    try {
      const check = localStorage.getItem('nym_vault_check');
      if (check && String(check).startsWith('enc:v1:')) {
        const v = await this._vaultDecrypt(check);
        if (v !== 'nymchat-vault-ok') throw new Error('Vault verification failed.');
        verifiedOne = true;
      }
    } catch (e) {
      throw new Error('Wrong password/PIN or unrecognized passkey.');
    }
    for (const name of this._VAULT_KEYS) {
      let blob = null;
      try { blob = localStorage.getItem(name); } catch (e) {}
      if (!blob) continue;
      if (String(blob).startsWith('enc:v1:')) {
        mem.set(name, await this._vaultDecrypt(blob));
        verifiedOne = true;
      } else {
        mem.set(name, blob);
      }
    }
    if (!verifiedOne) {
      // Nothing encrypted to verify against: the freshly-enabled empty-identity case.
    }
    this._vaultMem = mem;
    return true;
  },

  // Escape hatch for a forgotten password; the encrypted identity is unrecoverable and discarded.
  resetVault() {
    for (const name of this._VAULT_KEYS) { try { localStorage.removeItem(name); } catch (e) {} }
    try { if (typeof this.pqRootWipe === 'function') this.pqRootWipe(); } catch (e) {}
    // Extras and PM cache records under the discarded key are unrecoverable, so drop them.
    this._vaultDiscardExtras();
    try { if (typeof this.clearPMCache === 'function') this.clearPMCache(); } catch (e) {}
    try {
      localStorage.removeItem('nym_vault_enabled');
      localStorage.removeItem('nym_vault_salt');
      localStorage.removeItem('nym_vault_method');
      localStorage.removeItem('nym_vault_cred');
      localStorage.removeItem('nym_vault_check');
    } catch (e) {}
    this._vaultKey = null;
    this._vaultMem = null;
  },

  // Reloads to a bare URL so no half-logged-in or stale route state survives.
  _forgetIdentityAndReload() {
    // Bounded, and before resetVault takes the key that signs it.
    try {
      Promise.race([
        this.purgeServerRecords('nymchat'),
        new Promise((done) => setTimeout(done, 2500))
      ]).catch(() => { }).then(() => this._forgetIdentityNow());
      return;
    } catch (e) { }
    this._forgetIdentityNow();
  },

  _forgetIdentityNow() {
    this.resetVault();
    for (const name of [
      'nym_nostr_login_method', 'nym_nostr_login_pubkey', 'nym_nostr_login_npub',
      'nym_random_keypair_per_session', 'nym_auto_ephemeral', 'nym_auto_ephemeral_nick',
      'nym_auto_ephemeral_channel', 'nym_purchases_cache', 'nym_active_style', 'nym_active_flair',
      'nym_bio', 'nym_lightning_address_global', 'nym_avatar_url', 'nym_banner_url'
    ]) { try { localStorage.removeItem(name); } catch (e) {} }
    try { location.replace(location.origin + location.pathname); }
    catch (e) { try { location.reload(); } catch (e2) {} }
  },

  // Called early in startup; blocks until the user unlocks or resets.
  async unlockVaultAtBoot() {
    if (!this.vaultEnabled() || this._vaultKey) return;
    // Apply the saved theme first; this runs before initialize().
    try { this.applyColorMode(); } catch (e) {}
    while (true) {
      // null means the user chose to reset.
      const password = await this._vaultPromptModal();
      if (password === null) {
        this._forgetIdentityAndReload();
        return;
      }
      try {
        await this.unlockVault(password);
        return;
      } catch (e) {
        const retry = await this._vaultErrorModal(e && e.message ? e.message : 'Unlock failed.');
        if (retry === 'reset') { this._forgetIdentityAndReload(); return; }
      }
    }
  },

  _vaultPromptModal() {
    return new Promise((resolve) => {
      const webauthn = this._vaultIsWebAuthn(this.vaultMethod());
      const isPasskey = this.vaultMethod() === 'passkey';
      const o = this._vaultOverlay();
      o.box.innerHTML =
        '<div class="modal-header">Unlock your identity</div>' +
        '<div class="modal-body">' +
        '<p class="form-hint nm-vault-text">Your Nymchat identity key is encrypted on this device.' +
        (webauthn ? (isPasskey ? ' Use your passkey to unlock.' : ' Use your biometric to unlock.') : '') + '</p>' +
        (webauthn ? '' : '<div class="form-group"><input id="nymVaultPw" type="password" inputmode="numeric" autocomplete="off" placeholder="Password or PIN" class="form-input"></div>') +
        '</div>' +
        '<div class="modal-actions">' +
        '<button id="nymVaultReset" class="icon-btn">Forget identity</button>' +
        '<button id="nymVaultGo" class="send-btn">Unlock</button>' +
        '</div>';
      const go = async () => {
        const pw = webauthn ? '' : (o.box.querySelector('#nymVaultPw').value || '');
        o.close();
        resolve(pw);
      };
      o.box.querySelector('#nymVaultGo').onclick = go;
      o.box.querySelector('#nymVaultReset').onclick = async () => {
        o.close();
        const ok = await this._vaultConfirm('This permanently deletes the encrypted identity on this device and starts a fresh one. Continue?', { title: 'Forget identity', danger: true, okLabel: 'Forget' });
        if (ok) resolve(null);
        else this._vaultPromptModal().then(resolve);
      };
      const inp = o.box.querySelector('#nymVaultPw');
      if (inp) { inp.focus(); inp.onkeydown = (e) => { if (e.key === 'Enter') go(); }; }
      // We don't auto-fire the system authenticator sheet.
    });
  },

  _vaultErrorModal(msg) {
    return new Promise((resolve) => {
      const o = this._vaultOverlay();
      o.box.innerHTML =
        '<div class="modal-header">Unlock failed</div>' +
        '<div class="modal-body"><p class="form-hint nm-vault-text"></p></div>' +
        '<div class="modal-actions">' +
        '<button id="nymVErReset" class="icon-btn">Forget identity</button>' +
        '<button id="nymVErRetry" class="send-btn">Try again</button>' +
        '</div>';
      o.box.querySelector('p').textContent = msg;
      o.box.querySelector('#nymVErRetry').onclick = () => { o.close(); resolve('retry'); };
      o.box.querySelector('#nymVErReset').onclick = () => { o.close(); resolve('reset'); };
    });
  },

  _hasPersistedSecret() {
    for (const name of this._VAULT_KEYS) {
      try { if (localStorage.getItem(name)) return true; } catch (e) {}
    }
    return false;
  },

  // Only the boolean preference crosses devices, so each device creates its own factor here.
  maybePromptEncryptAtRest() {
    if (this._atRestPromptShown) return;
    try {
      if (this.vaultEnabled()) return;
      if (localStorage.getItem('nym_encrypt_at_rest_pref') !== '1') return;
      if (localStorage.getItem('nym_encrypt_at_rest_prompt_dismissed') === '1') return;
      if (!this._hasPersistedSecret()) return;
    } catch (e) { return; }
    this._atRestPromptShown = true;
    const dismiss = () => { try { localStorage.setItem('nym_encrypt_at_rest_prompt_dismissed', '1'); } catch (e) {} };
    const o = this._vaultOverlay();
    o.box.innerHTML =
      '<div class="modal-header">Protect your identity here too?</div>' +
      '<div class="modal-body"><p class="form-hint nm-vault-text">You protect your identity key with encryption on another device. ' +
      'Set it up on this device as well so your saved key can\'t be read without unlocking. ' +
      'You\'ll choose a password, PIN, or passkey for this device.</p></div>' +
      '<div class="modal-actions">' +
      '<button id="nymAREskip" class="icon-btn">Not now</button>' +
      '<button id="nymAREgo" class="send-btn">Set up</button>' +
      '</div>';
    o.box.querySelector('#nymAREskip').onclick = () => { dismiss(); o.close(); };
    o.box.querySelector('#nymAREgo').onclick = () => { dismiss(); o.close(); try { this.openVaultSettings(); } catch (e) {} };
  },

  _vaultConfirm(msg, opts) {
    return (typeof window.showAppConfirm === 'function') ? window.showAppConfirm(msg, opts) : Promise.resolve(confirm(msg));
  },
  _vaultAlert(msg, opts) {
    return (typeof window.showAppAlert === 'function') ? window.showAppAlert(msg, opts) : Promise.resolve(alert(msg));
  },

  _vaultOverlay() {
    const ov = document.createElement('div');
    ov.className = 'modal active nm-vault-overlay';
    const box = document.createElement('div');
    box.className = 'modal-content nm-vault-box';
    ov.appendChild(box);
    document.body.appendChild(ov);
    return { box, close: () => { try { document.body.removeChild(ov); } catch (e) {} } };
  },

  async _verifyPassword(password) {
    try {
      if (!password) return false;
      const salt = this._vb64d(localStorage.getItem('nym_vault_salt') || '');
      const key = await this._deriveKeyFromPassword(String(password), salt);
      const blob = localStorage.getItem('nym_vault_check');
      if (!blob) return false;
      const p = String(blob).split(':');
      if (p.length !== 4 || p[0] !== 'enc' || p[1] !== 'v1') return false;
      const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: this._vb64d(p[2]) }, key, this._vb64d(p[3]));
      return new TextDecoder().decode(pt) === 'nymchat-vault-ok';
    } catch (e) { return false; }
  },

  // Resolves true on success, false on failure, and null when the user cancels.
  async _vaultReauth() {
    if (this._vaultIsWebAuthn(this.vaultMethod())) {
      return await this.testVaultUnlock();
    }
    return await new Promise((resolve) => {
      const o = this._vaultOverlay();
      o.box.innerHTML =
        '<div class="modal-header">Confirm it\'s you</div>' +
        '<div class="modal-body">' +
        '<p class="form-hint nm-vault-text">Enter your password or PIN to turn off identity encryption.</p>' +
        '<div class="form-group"><input id="nymReauthPw" type="password" inputmode="text" autocomplete="off" placeholder="Password or PIN" class="form-input"></div>' +
        '</div>' +
        '<div class="modal-actions">' +
        '<button id="nymReauthCancel" class="icon-btn">Cancel</button>' +
        '<button id="nymReauthGo" class="send-btn">Confirm</button>' +
        '</div>';
      const inp = o.box.querySelector('#nymReauthPw');
      const go = async () => { const ok = await this._verifyPassword(inp.value || ''); o.close(); resolve(ok); };
      o.box.querySelector('#nymReauthGo').onclick = go;
      o.box.querySelector('#nymReauthCancel').onclick = () => { o.close(); resolve(null); };
      inp.focus();
      inp.onkeydown = (e) => { if (e.key === 'Enter') go(); };
    });
  },

  async openVaultSettings() {
    const enabled = this.vaultEnabled();
    const bio = (await this.biometricAvailable()) && !this._biometricRedundantWithPasskey();
    const passkey = this.webauthnAvailable();
    const o = this._vaultOverlay();
    if (enabled) {
      o.box.innerHTML =
        '<div class="modal-header">Identity encryption</div>' +
        '<div class="modal-body"><p class="form-hint nm-vault-text">Your identity key is encrypted at rest (<span id="nymVMethodLabel"></span>).</p></div>' +
        '<div class="modal-actions">' +
        '<button id="nymVClose" class="icon-btn">Close</button>' +
        '<button id="nymVDisable" class="send-btn danger">Turn off</button>' +
        '</div>';
      o.box.querySelector('#nymVMethodLabel').textContent = this.vaultMethod();
      o.box.querySelector('#nymVClose').onclick = o.close;
      o.box.querySelector('#nymVDisable').onclick = async () => {
        try {
          if (!this._vaultKey) { o.close(); this._vaultAlert('Unlock the app first, then turn off encryption.'); return; }
          const auth = await this._vaultReauth();
          if (auth === null) return;
          if (auth !== true) { this._vaultAlert('Re-authentication failed. Encryption was not turned off.'); return; }
          await this.disableVault();
          o.close();
          this._vaultAlert('Encryption turned off.');
        } catch (e) { this._vaultAlert(e.message || 'Failed.'); }
      };
      return;
    }
    o.box.innerHTML =
      '<div class="modal-header">Encrypt identity key</div>' +
      '<div class="modal-body">' +
      '<p class="form-hint nm-vault-text">Protect your saved identity so it can\'t be read from this device without unlocking.</p>' +
      '<div class="form-group">' +
      '<label class="form-label">Method</label>' +
      '<select id="nymVMethod" class="form-select">' +
      '<option value="password">Password</option>' +
      '<option value="pin">PIN</option>' +
      (passkey ? '<option value="passkey">Passkey (device, security key, or synced)</option>' : '') +
      (bio ? '<option value="biometric">Biometric (Face/Touch ID)</option>' : '') +
      '</select>' +
      '</div>' +
      '<div class="form-group"><input id="nymVPw" type="password" inputmode="text" autocomplete="new-password" placeholder="Choose a password" class="form-input"></div>' +
      '<div class="form-group"><input id="nymVPw2" type="password" autocomplete="new-password" placeholder="Confirm" class="form-input"></div>' +
      '<p id="nymVWaHint" class="form-hint nm-hidden">You\'ll be prompted to create/select a passkey. It must support the WebAuthn PRF extension; if it doesn\'t, pick a password or PIN instead.</p>' +
      (passkey ? '' : '<p class="form-hint">Passkey/biometric unlock isn\'t available in this browser/app, so password or PIN is used.</p>') +
      '</div>' +
      '<div class="modal-actions">' +
      '<button id="nymVCancel" class="icon-btn">Cancel</button>' +
      '<button id="nymVEnable" class="send-btn">Enable</button>' +
      '</div>';
    const methodSel = o.box.querySelector('#nymVMethod');
    const pw = o.box.querySelector('#nymVPw');
    const pw2 = o.box.querySelector('#nymVPw2');
    const waHint = o.box.querySelector('#nymVWaHint');
    const stripNonDigits = (el) => { if (methodSel.value === 'pin') el.value = el.value.replace(/[^0-9]/g, ''); };
    pw.addEventListener('input', () => stripNonDigits(pw));
    pw2.addEventListener('input', () => stripNonDigits(pw2));
    const syncPwVisibility = () => {
      const isWa = this._vaultIsWebAuthn(methodSel.value);
      const isPin = methodSel.value === 'pin';
      pw.parentNode.classList.toggle('nm-hidden', isWa);
      pw2.parentNode.classList.toggle('nm-hidden', isWa);
      if (waHint) waHint.classList.toggle('nm-hidden', !isWa);
      pw.setAttribute('inputmode', isPin ? 'numeric' : 'text');
      pw2.setAttribute('inputmode', isPin ? 'numeric' : 'text');
      pw.placeholder = isPin ? 'Choose a PIN code' : 'Choose a password';
      if (isPin) { stripNonDigits(pw); stripNonDigits(pw2); }
    };
    methodSel.onchange = syncPwVisibility; syncPwVisibility();
    o.box.querySelector('#nymVCancel').onclick = o.close;
    o.box.querySelector('#nymVEnable').onclick = async () => {
      const method = this._vaultIsWebAuthn(methodSel.value) ? methodSel.value : 'password';
      try {
        if (!this._vaultIsWebAuthn(method)) {
          if ((pw.value || '').length < 4) { this._vaultAlert('Use at least 4 characters.'); return; }
          if (pw.value !== pw2.value) { this._vaultAlert('The two entries do not match.'); return; }
        }
        const btn = o.box.querySelector('#nymVEnable');
        await this.enableVault(method, pw.value);
        // Prove a real unlock works before relying on it; roll back if it can't so the user is never locked out.
        if (this._vaultIsWebAuthn(method)) {
          if (btn) { btn.textContent = 'Confirm unlock…'; btn.disabled = true; }
          const ok = await this.testVaultUnlock();
          if (!ok) {
            try { await this.disableVault(); } catch (e) { this.resetVault(); }
            o.close();
            this._vaultAlert('Could not verify your ' + (method === 'passkey' ? 'passkey' : 'biometric') +
              ' unlock, so encryption was NOT enabled and your identity is unchanged. ' +
              'Your authenticator may not support WebAuthn PRF — try a different passkey, or use a password/PIN.');
            return;
          }
        }
        o.close();
        this._vaultAlert('Identity encryption enabled and verified. You\'ll be asked to unlock on next launch.');
      } catch (e) { this._vaultAlert(e.message || 'Could not enable encryption.'); }
    };
  }

});
