import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../services/storage/secure_store.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../i18n/i18n.dart';
import 'identity_vault.dart';
import 'modal_chrome.dart';

/// Provides the [IdentityVault] wired to the app key/value + secure stores.
final identityVaultProvider = Provider<IdentityVault>((ref) {
  return IdentityVault(
    ref.watch(keyValueStoreProvider),
    SecureStoreAdapter(SecureStore()),
  );
});

/// Settings modal for identity encryption-at-rest (`openVaultSettings`,
/// `js/modules/key-vault.js`). Lets the user enable/disable per-device
/// encryption and pick a factor: Password, PIN, or Biometric (`local_auth`).
class VaultSettingsModal extends ConsumerStatefulWidget {
  const VaultSettingsModal({super.key});

  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const VaultSettingsModal(),
    );
  }

  @override
  ConsumerState<VaultSettingsModal> createState() => _VaultSettingsModalState();
}

class _VaultSettingsModalState extends ConsumerState<VaultSettingsModal> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  String _method = 'password';
  String? _error;
  bool _busy = false;
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    try {
      final auth = LocalAuthentication();
      final supported =
          await auth.isDeviceSupported() && await auth.canCheckBiometrics;
      if (mounted) setState(() => _bioAvailable = supported);
    } catch (_) {
      // Biometric probing unavailable (tests / desktop) — leave disabled.
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final vault = ref.watch(identityVaultProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          // `.nm-vault-box`: max-width 420, padding 32.
          constraints: const BoxConstraints(maxWidth: 420),
          child: Material(
            color: Colors.transparent,
            child: ModalChrome.box(
              c,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: vault.isEnabled
                    ? _enabledView(c, vault)
                    : _setupView(c, vault),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _enabledView(NymColors c, IdentityVault vault) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _modalHeader(c, tr('Identity encryption')),
        // `.nm-vault-text`: 13px, line-height 1.5.
        Text(
          tr('Your identity key is encrypted at rest ({method}).',
              {'method': vault.method}),
          style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        const SizedBox(height: 24),
        // `.modal-actions`: center, gap 10.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ModalChrome.iconButton(
                c, tr('Close'), () => Navigator.of(context).pop()),
            const SizedBox(width: 10),
            // `.send-btn.danger` (NOT a solid fill).
            ModalChrome.sendButton(c, tr('Turn off'),
                _busy ? null : () => _disable(vault),
                danger: true),
          ],
        ),
      ],
    );
  }

  /// The `.modal-header` (22px primary UPPERCASE ls1.5 w700 + bottom rule),
  /// rendered inline because the vault box has no separate header row.
  Widget _modalHeader(NymColors c, String title) => Container(
        padding: const EdgeInsets.only(bottom: 14),
        margin: const EdgeInsets.only(bottom: 24),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.glassBorder)),
        ),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            color: c.primary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      );

  Widget _setupView(NymColors c, IdentityVault vault) {
    final isBio = _method == 'biometric';
    final isPin = _method == 'pin';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _modalHeader(c, tr('Encrypt identity key')),
        // `.nm-vault-text`: 13px, line-height 1.5.
        Text(
          tr("Protect your saved identity so it can't be read from this device "
              'without unlocking.'),
          style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 16),
        // `.form-label`.
        ModalChrome.formLabel(c, tr('Method')),
        const SizedBox(height: 8),
        ModalChrome.focusRing(
          c,
          child: DropdownButtonFormField<String>(
            // `value` over `initialValue`: the latter doesn't exist on the
            // build toolchain's Flutter; `value` works on both (deprecated-only
            // on newer SDKs).
            // ignore: deprecated_member_use
            value: _method,
            dropdownColor: c.bgTertiary,
            style: TextStyle(color: c.text, fontSize: 14),
            decoration: _decoration(c, ''),
            items: [
              DropdownMenuItem(
                  value: 'password', child: Text(tr('Password'))),
              DropdownMenuItem(value: 'pin', child: Text(tr('PIN'))),
              if (_bioAvailable)
                DropdownMenuItem(
                    value: 'biometric',
                    child: Text(tr('Biometric (Face/Touch ID)'))),
            ],
            onChanged: (v) => setState(() => _method = v ?? 'password'),
          ),
        ),
        if (!isBio) ...[
          const SizedBox(height: 12),
          ModalChrome.focusRing(
            c,
            child: TextField(
              controller: _pw,
              obscureText: true,
              keyboardType: isPin ? TextInputType.number : TextInputType.text,
              // PIN: hard-strip non-digits on every keystroke
              // (key-vault.js:558).
              inputFormatters:
                  isPin ? [FilteringTextInputFormatter.digitsOnly] : null,
              style: TextStyle(color: c.textBright, fontSize: 15),
              decoration: _decoration(
                  c, isPin ? tr('Choose a PIN code') : tr('Choose a password')),
            ),
          ),
          const SizedBox(height: 10),
          ModalChrome.focusRing(
            c,
            child: TextField(
              controller: _pw2,
              obscureText: true,
              keyboardType: isPin ? TextInputType.number : TextInputType.text,
              inputFormatters:
                  isPin ? [FilteringTextInputFormatter.digitsOnly] : null,
              style: TextStyle(color: c.textBright, fontSize: 15),
              decoration: _decoration(c, tr('Confirm')),
            ),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              tr("You'll be asked for your biometric to unlock the app on next "
                  'launch.'),
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        const SizedBox(height: 24),
        // `.modal-actions`: center, gap 10.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ModalChrome.iconButton(
                c, tr('Cancel'), () => Navigator.of(context).pop()),
            const SizedBox(width: 10),
            ModalChrome.sendButton(
              c,
              tr('Enable'),
              _busy ? null : () => _enable(vault),
              child: _busy
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: c.primary))
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  // `.form-input`/`.form-select`: radius 12, padding 11/14, font 15.
  InputDecoration _decoration(NymColors c, String hint) =>
      ModalChrome.inputDecoration(c, hint);

  Future<void> _enable(IdentityVault vault) async {
    setState(() => _error = null);
    String password;
    if (_method == 'biometric') {
      // Authenticate once; derive the vault key from a stable device secret.
      // TODO(verify): the PWA derives the key from a WebAuthn PRF output. On
      // native there is no PRF; here we gate enabling behind a biometric prompt
      // and derive from a generated device secret stored in secure storage.
      final ok = await _biometricAuth();
      if (!ok) {
        setState(() => _error = tr('Biometric authentication failed.'));
        return;
      }
      password = await _deviceBiometricSecret();
    } else {
      if (_pw.text.length < 4) {
        setState(() => _error = tr('Use at least 4 characters.'));
        return;
      }
      if (_pw.text != _pw2.text) {
        setState(() => _error = tr('The two entries do not match.'));
        return;
      }
      password = _pw.text;
    }
    setState(() => _busy = true);
    try {
      // The PWA collapses password + PIN to method `'password'`; only WebAuthn
      // factors keep their own name (`_vaultIsWebAuthn(method) ? method :
      // 'password'`, key-vault.js:180). So a PIN persists as `'password'`, never
      // the literal `'pin'`. (Mirrored at the call site since identity_vault is
      // shared core — see CROSS_FILE_NEEDS for the in-engine fix.)
      final storedMethod = _method == 'biometric' ? 'biometric' : 'password';
      await vault.enable(method: storedMethod, password: password);
      if (!mounted) return;
      Navigator.of(context).pop();
      // PWA uses a modal `_vaultAlert`, not a transient toast (key-vault.js:599).
      await showAppAlert(
        context,
        tr("Identity encryption enabled and verified. You'll be asked to unlock "
            'on next launch.'),
      );
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _disable(IdentityVault vault) async {
    setState(() => _error = null);
    String password;
    if (vault.method == 'biometric') {
      // Passkey/biometric: fresh authenticator challenge (`_vaultReauth`).
      final ok = await _biometricAuth();
      if (!ok) {
        setState(() => _error = tr('Biometric authentication failed.'));
        return;
      }
      password = await _deviceBiometricSecret();
    } else {
      // Password/PIN: a separate "Confirm it's you" prompt before turning off,
      // matching the PWA's `_vaultReauth` (key-vault.js:479-498) instead of an
      // inline field. Verify the factor, then disable only on success.
      final entered = await showAppPrompt(
        context,
        tr('Enter your password or PIN to turn off identity encryption.'),
        title: tr("Confirm it's you"),
        okLabel: tr('Confirm'),
        placeholder: tr('Password or PIN'),
      );
      if (entered == null) return; // cancelled
      final ok = await vault.verifyPassword(entered);
      if (!mounted) return;
      if (!ok) {
        setState(() =>
            _error = tr('Re-authentication failed. Encryption was not turned off.'));
        return;
      }
      password = entered;
    }
    setState(() => _busy = true);
    try {
      await vault.disable(password);
      if (!mounted) return;
      Navigator.of(context).pop();
      // PWA modal `_vaultAlert` "Encryption turned off." (key-vault.js:527).
      await showAppAlert(context, tr('Encryption turned off.'));
    } catch (e) {
      setState(() {
        _busy = false;
        _error = tr('Re-authentication failed. Encryption was not turned off.');
      });
    }
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

  /// A stable per-device secret used as the PBKDF2 password for the biometric
  /// factor, stored in secure storage (behind the biometric gate).
  Future<String> _deviceBiometricSecret() async {
    final secure = SecureStore();
    const key = 'nym_vault_bio_secret';
    var s = await secure.get(key);
    if (s == null) {
      // 32 bytes from a CSPRNG — never time-derived, so the biometric factor
      // has full entropy (the WebAuthn-PRF equivalent on native).
      final rng = Random.secure();
      final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
      s = base64.encode(bytes);
      await secure.set(key, s);
    }
    return s;
  }
}

/// Cross-device "Protect your identity here too?" nudge — the native port of
/// `maybePromptEncryptAtRest` (key-vault.js:415-437). Call once AFTER settings
/// sync completes. If the user enabled identity encryption on another device
/// (`encryptAtRestPref`), this device isn't encrypted yet, a secret is
/// persisted, and the prompt wasn't dismissed, it offers to set encryption up
/// here. "Set up" opens [VaultSettingsModal]; both choices persist the
/// dismissed flag so it shows at most once.
///
/// Returns true when the prompt was shown. Safe to call when conditions aren't
/// met (returns false without UI). The trigger (calling this after sync) lives
/// in the controller — see this slice's CROSS-FILE NEEDS.
Future<bool> maybePromptEncryptAtRest(
  BuildContext context,
  WidgetRef ref,
) async {
  final kv = ref.read(keyValueStoreProvider);
  final vault = ref.read(identityVaultProvider);
  if (vault.isEnabled) return false;
  if (!kv.getBool(StorageKeys.encryptAtRestPref)) return false;
  if (kv.getBool(StorageKeys.encryptAtRestPromptDismissed)) return false;

  // Only nudge if there's actually a persisted identity secret to protect
  // (`_hasPersistedSecret`). Mirrors the PWA's guard.
  final secure = SecureStore();
  var hasSecret = false;
  for (final name in SecretKeys.all) {
    if ((await secure.get(name))?.isNotEmpty ?? false) {
      hasSecret = true;
      break;
    }
  }
  if (!hasSecret) return false;
  if (!context.mounted) return false;

  // Persist dismissed up-front (the PWA dismisses on either choice).
  await kv.setBool(StorageKeys.encryptAtRestPromptDismissed, true);
  if (!context.mounted) return true;

  final setUp = await showAppConfirm(
    context,
    tr('You protect your identity key with encryption on another device. Set it '
        "up on this device as well so your saved key can't be read without "
        "unlocking. You'll choose a password, PIN, or passkey for this device."),
    title: tr('Protect your identity here too?'),
    okLabel: tr('Set up'),
    cancelLabel: tr('Not now'),
  );
  if (setUp && context.mounted) {
    await VaultSettingsModal.open(context);
  }
  return true;
}
