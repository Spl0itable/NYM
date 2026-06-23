import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/storage/secure_store.dart';
import 'identity_vault.dart' show SecureStoreLike;
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
  String? _error;
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
    setState(() {
      _busy = true;
      _error = null;
    });
    final vault = ref.read(identityVaultProvider);
    try {
      String password;
      if (_isBiometric) {
        // TODO(verify): the PWA biometric factor derives the key from a WebAuthn
        // PRF output; native has no PRF, so (matching VaultSettingsModal's enable
        // path) we gate on local_auth and derive from a per-device secret. This
        // is a platform-equivalence choice, not a 1:1 port of the PRF scheme.
        final ok = await _biometricAuth();
        if (!ok) {
          if (mounted) {
            setState(() {
              _busy = false;
              _error = 'Biometric unlock was cancelled.';
            });
          }
          return;
        }
        password = await _deviceBiometricSecret();
      } else {
        password = _pw.text;
        if (password.isEmpty) {
          setState(() {
            _busy = false;
            _error = 'Enter your password or PIN.';
          });
          return;
        }
      }
      // `unlockVault` derives the key, verifies the check token (throws on a
      // wrong factor) and returns the decrypted secrets. We hand them to the
      // caller IN MEMORY (the native analogue of the PWA's `_vaultMem`) — the
      // encrypted `enc:v1:` blobs stay in secure storage and are never
      // re-plaintexted, so unlock is required on every launch.
      final secrets = await vault.unlock(password);
      if (mounted) widget.onUnlocked(secrets);
    } catch (e) {
      // `_vaultErrorModal`: "Wrong password/PIN or unrecognised passkey."
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Wrong password/PIN or unrecognised passkey.';
        });
      }
    }
  }

  /// "Forget identity" — confirm, then reset the vault (`resetVault`) and hand
  /// control back so the caller starts a clean first-run.
  Future<void> _forget() async {
    final confirmed = await _confirmForget();
    if (!confirmed) return;
    await ref.read(identityVaultProvider).reset();
    if (mounted) widget.onForget();
  }

  Future<bool> _confirmForget() async {
    final c = context.nym;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (ctx) => AlertDialog(
        backgroundColor: c.bgSecondary,
        title: Text('Forget identity', style: TextStyle(color: c.text)),
        content: Text(
          'This permanently deletes the encrypted identity on this device and '
          'starts a fresh one. Continue?',
          style: TextStyle(color: c.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel', style: TextStyle(color: c.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Forget',
                style: TextStyle(color: Color(0xFFE5484D))),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<bool> _biometricAuth() async {
    try {
      final auth = LocalAuthentication();
      return await auth.authenticate(
        localizedReason: 'Unlock your Nymchat identity',
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
    return Scaffold(
      backgroundColor: c.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.lock_outline, size: 48, color: c.primary),
                const SizedBox(height: 16),
                Text(
                  'Unlock your identity',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your Nymchat identity key is encrypted on this device.'
                  '${isBio ? ' Use your biometric to unlock.' : ''}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textDim, fontSize: 13),
                ),
                const SizedBox(height: 20),
                if (!isBio)
                  TextField(
                    controller: _pw,
                    autofocus: true,
                    obscureText: true,
                    enabled: !_busy,
                    keyboardType: TextInputType.visiblePassword,
                    onSubmitted: (_) => _unlock(),
                    decoration: InputDecoration(
                      hintText: 'Password or PIN',
                      hintStyle: TextStyle(color: c.textDim),
                      filled: true,
                      fillColor: c.bgSecondary,
                      border: OutlineInputBorder(
                        borderRadius: NymRadius.rmd,
                        borderSide: BorderSide(color: c.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: NymRadius.rmd,
                        borderSide: BorderSide(color: c.border),
                      ),
                    ),
                    style: TextStyle(color: c.text),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Color(0xFFE5484D), fontSize: 13),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _unlock,
                  style: FilledButton.styleFrom(
                    backgroundColor: c.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Unlock'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : _forget,
                  child: Text('Forget identity',
                      style: TextStyle(color: c.textDim)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
