// key-vault.js — Optional encryption-at-rest for the identity secret keys

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

  _VAULT_KEYS: ['nym_session_nsec', 'nym_dev_nsec', 'nym_nostr_login_nsec', 'nym_nip46_client_secret'],

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
        return null; // locked or not present
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
    } catch (e) { /* storage may be full/blocked */ }
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

  // True when a WebAuthn authenticator of any kind is usable (platform
  // biometric, roaming security key, or a synced passkey). Used to offer the
  // "Passkey" method.
  webauthnAvailable() {
    return !!(window.PublicKeyCredential && navigator.credentials &&
      navigator.credentials.create && navigator.credentials.get);
  },

  // True when a built-in platform authenticator (Face/Touch ID, Windows Hello,
  // Android biometric) is present. Used to offer the "Biometric" quick method.
  async biometricAvailable() {
    try {
      if (!this.webauthnAvailable()) return false;
      if (!PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable) return false;
      return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
    } catch (e) { return false; }
  },

  _vaultIsWebAuthn(method) { return method === 'biometric' || method === 'passkey'; },

  // On Apple platforms (iOS/iPadOS/macOS Safari) the built-in platform
  // authenticator IS the passkey provider, so "Biometric" and "Passkey" trigger
  // the same Face/Touch ID flow and create the same synced passkey. Offering
  // both there is redundant, so the separate Biometric option is hidden.
  _biometricRedundantWithPasskey() {
    try {
      const ua = navigator.userAgent || '';
      const iOS = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
      const macSafari = /Macintosh/.test(ua) && /Safari/.test(ua) && !/Chrome|Chromium|Edg|OPR/.test(ua);
      return iOS || macSafari;
    } catch (e) { return false; }
  },

  // Enroll a WebAuthn credential and derive the vault key from its PRF output.
  // platformOnly=true pins it to the built-in biometric authenticator;
  // platformOnly=false ("passkey") lets the OS picker offer synced passkeys and
  // external security keys too.
  async _webauthnEnroll(salt, platformOnly) {
    const userId = crypto.getRandomValues(new Uint8Array(16));
    const authenticatorSelection = { userVerification: 'required', residentKey: 'required' };
    if (platformOnly) authenticatorSelection.authenticatorAttachment = 'platform';
    const cred = await navigator.credentials.create({ publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      rp: { name: 'Nymchat', id: location.hostname },
      user: { id: userId, name: 'nym-vault', displayName: 'Nymchat Vault' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
      authenticatorSelection,
      timeout: 60000,
      extensions: { prf: {} }
    }});
    if (!cred) throw new Error('Passkey enrollment was cancelled.');
    // Derive the actual key via a follow-up get() (PRF results are reliably
    // returned on get, not always on create). This also fails fast here if the
    // chosen authenticator doesn't support PRF, before we commit any state.
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

  // Enable the vault: derive a key from the chosen factor, encrypt the existing
  // plaintext secrets, and persist the encrypted blobs + metadata.
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
    // Snapshot current plaintext secrets and re-store them encrypted.
    this._vaultMem = new Map();
    for (const name of this._VAULT_KEYS) {
      let cur = null;
      try { cur = localStorage.getItem(name); } catch (e) {}
      if (cur == null || String(cur).startsWith('enc:v1:')) continue;
      this._vaultMem.set(name, cur);
      try { localStorage.setItem(name, await this._vaultEncrypt(cur)); } catch (e) {}
    }
    try {
      localStorage.setItem('nym_vault_salt', this._vb64(salt));
      localStorage.setItem('nym_vault_method', this._vaultIsWebAuthn(method) ? method : 'password');
      if (credId) localStorage.setItem('nym_vault_cred', credId);
      // A known token encrypted under the vault key — lets unlock verify the
      // derived key even when no identity secret is stored yet.
      localStorage.setItem('nym_vault_check', await this._vaultEncrypt('nymchat-vault-ok'));
      localStorage.setItem('nym_vault_enabled', '1');
      // Remember the (non-sensitive) preference and sync it so other devices
      // can offer to set up encryption too. Clear any prior "don't ask" so the
      // user's renewed intent re-enables prompting on new devices.
      localStorage.setItem('nym_encrypt_at_rest_pref', '1');
      localStorage.removeItem('nym_encrypt_at_rest_prompt_dismissed');
    } catch (e) {
      throw new Error('Could not persist encryption settings.');
    }
    try { if (typeof nostrSettingsSave === 'function') nostrSettingsSave(); } catch (e) {}
  },

  // Disable the vault: decrypt the secrets back to plaintext (requires the
  // vault to be unlocked) and clear the metadata.
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

  // Prove the chosen factor can actually unlock BEFORE the user relies on it at
  // next launch. For passkey/biometric this triggers a fresh authenticator
  // interaction and re-derives the key independently, then decrypts the check
  // token. Returns true on success. (Password/PIN derive deterministically from
  // the just-confirmed input, so they need no round-trip.)
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

  // Derive the session key from the supplied factor and decrypt all secrets
  // into memory. Returns true on success.
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
    // Verify the derived key against the check token first — this rejects a
    // wrong password/PIN (or a mismatched passkey) even when no identity secret
    // is stored yet. _vaultDecrypt throws on the AES-GCM tag if the key is wrong.
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
      throw new Error('Wrong password/PIN or unrecognised passkey.');
    }
    for (const name of this._VAULT_KEYS) {
      let blob = null;
      try { blob = localStorage.getItem(name); } catch (e) {}
      if (!blob) continue;
      if (String(blob).startsWith('enc:v1:')) {
        mem.set(name, await this._vaultDecrypt(blob)); // throws if key wrong
        verifiedOne = true;
      } else {
        mem.set(name, blob); // legacy plaintext alongside (shouldn't normally happen)
      }
    }
    if (!verifiedOne) {
      // Nothing encrypted to verify against — accept the key (will be used on
      // the next secretSet). This is the freshly-enabled empty-identity case.
    }
    this._vaultMem = mem;
    return true;
  },

  // Clear the vault and its secrets entirely (escape hatch for a forgotten
  // password — the encrypted identity is unrecoverable and is discarded).
  resetVault() {
    for (const name of this._VAULT_KEYS) { try { localStorage.removeItem(name); } catch (e) {} }
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

  // Called early in startup. If the vault is enabled, blocks until the user
  // unlocks (or resets) so the encrypted identity can be read by the loader.
  async unlockVaultAtBoot() {
    if (!this.vaultEnabled() || this._vaultKey) return;
    // Apply the saved theme/color mode first so the unlock modal matches the
    // app's appearance instead of boot defaults (this runs before initialize()).
    try { this.applyColorMode(); } catch (e) {}
    while (true) {
      // The prompt adapts to the method (password/PIN field, or a passkey/
      // biometric "Unlock" button). null means the user chose to reset.
      const password = await this._vaultPromptModal();
      if (password === null) {
        this.resetVault();
        return;
      }
      try {
        await this.unlockVault(password);
        return;
      } catch (e) {
        const retry = await this._vaultErrorModal(e && e.message ? e.message : 'Unlock failed.');
        if (retry === 'reset') { this.resetVault(); return; }
        // otherwise loop and prompt again
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
      // For passkey/biometric there is no field — the user taps "Unlock" to
      // bring up the authenticator (we don't auto-fire the system sheet).
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

  // True only when there is an identity secret actually persisted on this device
  // that would benefit from at-rest encryption (skip for pure per-session keys).
  _hasPersistedSecret() {
    for (const name of this._VAULT_KEYS) {
      try { if (localStorage.getItem(name)) return true; } catch (e) {}
    }
    return false;
  },

  // Called once after settings sync. If the user prefers identity encryption
  // (set on another device) but this device hasn't enabled it, offer to set it
  // up. Only the boolean preference crossed devices — no key material — so each
  // device still creates its own factor here.
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

  // Verify a password/PIN against the stored check token without unlocking.
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

  // Challenge the user for their current factor before a sensitive change (e.g.
  // turning encryption off). Resolves true on success, false on failure, and
  // null when the user cancels. WebAuthn triggers a fresh authenticator check;
  // password/PIN shows a themed re-entry prompt.
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

  // Opened from Settings. Lets the user enable/disable encryption and pick a
  // factor. Biometric is offered when a platform authenticator exists; Passkey
  // is offered whenever WebAuthn is available (covers synced passkeys and
  // external security keys as well as platform authenticators).
  async openVaultSettings() {
    const enabled = this.vaultEnabled();
    const bio = (await this.biometricAvailable()) && !this._biometricRedundantWithPasskey();
    const passkey = this.webauthnAvailable();
    const o = this._vaultOverlay();
    if (enabled) {
      o.box.innerHTML =
        '<div class="modal-header">Identity encryption</div>' +
        '<div class="modal-body"><p class="form-hint nm-vault-text">Your identity key is encrypted at rest (' + this.vaultMethod() + ').</p></div>' +
        '<div class="modal-actions">' +
        '<button id="nymVClose" class="icon-btn">Close</button>' +
        '<button id="nymVDisable" class="send-btn danger">Turn off</button>' +
        '</div>';
      o.box.querySelector('#nymVClose').onclick = o.close;
      o.box.querySelector('#nymVDisable').onclick = async () => {
        try {
          if (!this._vaultKey) { o.close(); this._vaultAlert('Unlock the app first, then turn off encryption.'); return; }
          const auth = await this._vaultReauth();
          if (auth === null) return; // cancelled
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
        // For passkey/biometric, immediately prove a real unlock works (a fresh
        // authenticator interaction + PRF) before the user relies on it next
        // launch. If it can't, roll back so they're never locked out.
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
