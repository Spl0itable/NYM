import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/theme/nym_colors.dart';
import '../../services/storage/secure_store.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../i18n/i18n.dart';
import 'identity_vault.dart' show SecureStoreLike;
import 'modal_chrome.dart';
import 'vault_settings_modal.dart' show identityVaultProvider;

/// Boot-time identity-vault unlock gate, mirroring `unlockVaultAtBoot` +
/// `_vaultPromptModal` / `_vaultErrorModal` in `js/modules/key-vault.js`.
///
/// When the vault is enabled this screen blocks the app at launch — exactly
/// like the PWA, where `await nym.unlockVaultAtBoot()` runs *before*
/// `initialize()` so the decrypted identity secret is available before any
/// identity-restore code reads it. On success the decrypted secrets are written
/// back to secure storage as plaintext (the native equivalent of the PWA's
/// in-memory `_vaultMem`, which `secretGet` returns post-unlock), then
/// [onUnlocked] fires so the caller can boot the controller / proceed to the
/// shell.
///
/// Adapts to `nym_vault_method`:
///  * `password` / `pin` — a password/PIN field + "Unlock" button.
///  * `biometric` — a "Unlock" button that triggers `local_auth`; the derived
///    PBKDF2 password is the per-device biometric secret (same scheme as
///    [VaultSettingsModal]).
///
/// On repeated failure the user can "Forget identity" — the PWA's reset path
/// (`resetVault` → discard the encrypted identity, start fresh).
class VaultBootUnlock extends ConsumerStatefulWidget {
  const VaultBootUnlock({
    super.key,
    required this.onUnlocked,
    required this.onForget,
    this.secureStore,
  });

  /// Called once the vault is unlocked, with the decrypted secrets (kept in
  /// memory by the caller — the native analogue of the PWA's `_vaultMem`).
  final void Function(Map<String, String> secrets) onUnlocked;

  /// Called when the user chooses to forget the identity (vault reset). The
  /// caller should drop login pointers and proceed to a clean first-run, the
  /// way `_forgetIdentityAndReload` reloads to a bare app.
  final VoidCallback onForget;

  /// Secure store the decrypted secrets are written back to. Defaults to the
  /// real platform keystore; tests inject an in-memory fake so no plugin is hit.
  final SecureStoreLike? secureStore;

  @override
  ConsumerState<VaultBootUnlock> createState() => _VaultBootUnlockState();
}

class _VaultBootUnlockState extends ConsumerState<VaultBootUnlock> {
  final _pw = TextEditingController();

  /// Non-null while the `_vaultErrorModal` state is showing — the card swaps
  /// from the unlock prompt to the "Unlock failed" chrome with this message.
  String? _failMessage;
  bool _busy = false;

  bool get _isBiometric =>
      ref.read(identityVaultProvider).method == 'biometric';

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  /// Mirrors `_vaultPromptModal` "Unlock" → `unlockVault` → on success return,
  /// on failure show `_vaultErrorModal` (Try again / Forget identity).
  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    final vault = ref.read(identityVaultProvider);
    try {
      String password;
      if (_isBiometric) {
        // TODO(verify): the PWA biometric factor derives the key from a WebAuthn
        // PRF output; native has no PRF, so (matching VaultSettingsModal's enable
        // path) we gate on local_auth and derive from a per-device secret. This
        // is a platform-equivalence choice, not a 1:1 port of the PRF scheme.
        final ok = await _biometricAuth();
        if (!ok) throw StateError(tr('Biometric unlock was cancelled.'));
        password = await _deviceBiometricSecret();
      } else {
        password = _pw.text;
        // `unlockVault`'s own guard (key-vault.js:257) — like every unlock
        // failure it surfaces through the "Unlock failed" card, not inline.
        if (password.isEmpty) throw StateError(tr('Enter your password or PIN.'));
      }
      // `unlockVault` derives the key, verifies the check token (throws on a
      // wrong factor) and returns the decrypted secrets. We hand them to the
      // caller IN MEMORY (the native analogue of the PWA's `_vaultMem`) — the
      // encrypted `enc:v1:` blobs stay in secure storage and are never
      // re-plaintexted, so unlock is required on every launch.
      final secrets = await vault.unlock(password);
      if (mounted) widget.onUnlocked(secrets);
    } catch (e) {
      // `unlockVaultAtBoot`'s retry loop: `_vaultErrorModal(e.message ||
      // 'Unlock failed.')` (key-vault.js:344) — swap the card to the separate
      // "Unlock failed" state carrying the thrown message.
      if (mounted) {
        setState(() {
          _busy = false;
          _failMessage = _messageOf(e);
        });
      }
    }
  }

  /// `e && e.message ? e.message : 'Unlock failed.'` (key-vault.js:344).
  static String _messageOf(Object e) {
    final m = e is StateError
        ? e.message
        : e is FormatException
            ? e.message
            : e is ArgumentError
                ? e.message?.toString()
                : null;
    return (m == null || m.isEmpty) ? tr('Unlock failed.') : m;
  }

  /// "Try again" on the error modal — the boot loop prompts again with a fresh
  /// (empty) field (`_vaultPromptModal` rebuilds the input each time).
  void _retry() {
    _pw.clear();
    setState(() => _failMessage = null);
  }

  /// "Forget identity" on the ERROR modal resolves `'reset'` straight into
  /// `_forgetIdentityAndReload` — no second confirmation (key-vault.js:345,398),
  /// unlike the prompt's Forget which confirms first.
  Future<void> _forgetFromError() async {
    await ref.read(identityVaultProvider).reset();
    if (mounted) widget.onForget();
  }

  /// "Forget identity" — confirm, then reset the vault (`resetVault`) and hand
  /// control back so the caller starts a clean first-run.
  Future<void> _forget() async {
    final confirmed = await _confirmForget();
    if (!confirmed) return;
    await ref.read(identityVaultProvider).reset();
    if (mounted) widget.onForget();
  }

  Future<bool> _confirmForget() {
    // Shared danger-confirm (`.app-dialog`, the F6 component).
    return showAppConfirm(
      context,
      tr('This permanently deletes the encrypted identity on this device and '
          'starts a fresh one. Continue?'),
      title: tr('Forget identity'),
      okLabel: tr('Forget'),
      danger: true,
    );
  }

  Future<bool> _biometricAuth() async {
    try {
      final auth = LocalAuthentication();
      return await auth.authenticate(
        localizedReason: tr('Unlock your Nymchat identity'),
        options: const AuthenticationOptions(biometricOnly: true),
      );
    } catch (_) {
      return false;
    }
  }

  /// The per-device biometric secret used as the PBKDF2 password (same key +
  /// scheme as [VaultSettingsModal], so a biometric-enabled vault unlocks).
  Future<String> _deviceBiometricSecret() async {
    final secure = SecureStore();
    const key = 'nym_vault_bio_secret';
    final s = await secure.get(key);
    // If it's missing the vault can't be unlocked biometrically (shouldn't
    // happen for a vault that was enabled with biometric) — return empty so
    // unlock fails cleanly into the error path rather than throwing.
    return s ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isBio = _isBiometric;
    // Boot unlock is a `.modal active nm-vault-overlay` — the `.modal` overlay
    // over the page `--bg`: glass default rgba(0,0,0,0.7) (styles-chat.css:
    // 1974); `body.solid-ui .modal { rgba(0,0,0,0.75) }` and
    // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
    // (styles-themes-responsive.css:1630-1636) — with a floating
    // `.modal-content nm-vault-box` card (420 max, padding 32).
    final solidUi = ref.watch(settingsProvider.select((s) => s.solidUi));
    final overlay = !solidUi
        ? Colors.black.withValues(alpha: 0.7)
        : c.isLight
            ? const Color(0x73000000) // black @ 0.45
            : const Color(0xBF000000); // black @ 0.75
    return Scaffold(
      backgroundColor: Color.alphaBlend(overlay, c.bg),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Material(
              color: Colors.transparent,
              child: ModalChrome.box(
                c,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _failMessage != null
                        ? _errorChildren(c)
                        : _promptChildren(c, isBio),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The `.modal-header` (no lock glyph in the PWA prompt).
  Widget _header(NymColors c, String text) {
    return Container(
      padding: const EdgeInsets.only(bottom: 14),
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: c.primary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  /// `_vaultPromptModal` — "Unlock your identity" with the factor field.
  List<Widget> _promptChildren(NymColors c, bool isBio) {
    return [
      _header(c, tr('Unlock your identity')),
      // `.form-hint.nm-vault-text`: 13px, line-height 1.5, left,
      // `margin: 0 0 16px`.
      Text(
        isBio
            ? tr('Your Nymchat identity key is encrypted on this device. '
                'Use your biometric to unlock.')
            : tr('Your Nymchat identity key is encrypted on this device.'),
        style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
      ),
      const SizedBox(height: 16),
      if (!isBio)
        ModalChrome.focusRing(
          c,
          child: TextField(
            controller: _pw,
            autofocus: true,
            obscureText: true,
            enabled: !_busy,
            keyboardType: TextInputType.visiblePassword,
            onSubmitted: (_) => _unlock(),
            decoration: ModalChrome.inputDecoration(c, tr('Password or PIN')),
            style: TextStyle(color: c.textBright, fontSize: 15),
          ),
        ),
      // Body → actions gap: the password `.form-group` carries
      // `margin-bottom: 20px` and `.modal-body` another 20px
      // (40 total); the biometric prompt has no field, so only
      // the text's 16px margin + the body's 20px apply.
      SizedBox(height: isBio ? 20 : 40),
      // `.modal-actions`: flex row, gap 10, justify center; no
      // `align-items`, so the default stretch sizes the
      // `.icon-btn` to the 42px `.send-btn` beside it. CSS flex items
      // SHRINK when the row is tight — mirror that with loose Flexibles so a
      // narrow viewport compresses the buttons instead of overflowing.
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
              child: ModalChrome.iconButton(
                  c, tr('Forget identity'), _busy ? null : _forget,
                  height: 42)),
          const SizedBox(width: 10),
          Flexible(
            child: ModalChrome.sendButton(
              c,
              tr('Unlock'),
              _busy ? null : _unlock,
              child: _busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: c.primary),
                    )
                  : null,
            ),
          ),
        ],
      ),
    ];
  }

  /// `_vaultErrorModal` — the separate "Unlock failed" card: the thrown
  /// message as the `.form-hint.nm-vault-text` body, "Forget identity"
  /// (`.icon-btn`, no re-confirm) / "Try again" (`.send-btn`).
  List<Widget> _errorChildren(NymColors c) {
    return [
      _header(c, tr('Unlock failed')),
      Text(
        _failMessage!,
        style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
      ),
      // The p's 16px bottom margin collapses into `.modal-body`'s 20px.
      const SizedBox(height: 20),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
              child: ModalChrome.iconButton(
                  c, tr('Forget identity'), _forgetFromError,
                  height: 42)),
          const SizedBox(width: 10),
          Flexible(child: ModalChrome.sendButton(c, tr('Try again'), _retry)),
        ],
      ),
    ];
  }
}
