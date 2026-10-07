import 'package:flutter/material.dart';
import '../../widgets/common/keyboard_inset_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../services/storage/secure_store.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/nym_sheet.dart';
import '../accounts/account_host.dart';
import '../i18n/i18n.dart';
import 'biometric_secret_store.dart';
import 'identity_vault.dart';
import 'modal_chrome.dart';

final identityVaultProvider = Provider<IdentityVault>((ref) {
  return IdentityVault(
    ref.watch(keyValueStoreProvider),
    SecureStoreAdapter(SecureStore()),
  );
});

/// Identity encryption-at-rest settings: enable or disable, with a Password, PIN or Biometric factor.
class VaultSettingsModal extends ConsumerStatefulWidget {
  const VaultSettingsModal({super.key});

  static Future<void> open(BuildContext context) {
    return showNymSheet<void>(
      context,
      (_) => const VaultSettingsModal(),
      barrierColor: Colors.black.withValues(alpha: 0.7),
    );
  }

  @override
  ConsumerState<VaultSettingsModal> createState() => _VaultSettingsModalState();
}

class _VaultSettingsModalState extends ConsumerState<VaultSettingsModal> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  final _cur = TextEditingController();
  final _next = TextEditingController();
  final _next2 = TextEditingController();
  final _off = TextEditingController();
  String _view = 'main';
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
    final supported =
        await ref.read(identityVaultProvider).biometricAvailable();
    final taken = ref.read(accountsProvider)?.biometricHeldByOther() ?? false;
    if (mounted) setState(() => _bioAvailable = supported && !taken);
  }

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    _cur.dispose();
    _next.dispose();
    _next2.dispose();
    _off.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final vault = ref.watch(identityVaultProvider);
    final view = vault.isEnabled ? _enabledView(c, vault) : _setupView(c, vault);
    return NymDiscardGuard(
      isDirty: () =>
          !_busy &&
          [_pw, _pw2, _cur, _next, _next2, _off].any((t) => t.text.isNotEmpty),
      child: nymSheetOr(
        context,
        SingleChildScrollView(
          padding: ModalChrome.sheetPadding,
          child: view,
        ),
        (_) => KeyboardInsetDialog(
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
                    child: view,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _methodName(IdentityVault vault) => vault.method == 'biometric'
      ? tr('Biometric (Face/Touch ID)')
      : tr('Password or PIN');

  Widget _status(NymColors c) => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        );

  Widget _field(NymColors c, TextEditingController t, String hint,
          {bool last = false, VoidCallback? onDone}) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: ModalChrome.focusRing(
          c,
          child: TextField(
            controller: t,
            obscureText: true,
            enabled: !_busy,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: last ? TextInputAction.done : TextInputAction.next,
            onSubmitted: last && onDone != null ? (_) => onDone() : null,
            style: TextStyle(color: c.inputText, fontSize: 15),
            decoration: _decoration(c, hint),
          ),
        ),
      );

  void _go(String view) {
    for (final t in [_cur, _next, _next2, _off]) {
      t.clear();
    }
    setState(() {
      _view = view;
      _error = null;
    });
  }

  Widget _spinner(NymColors c) => SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: c.primary));

  Widget _enabledView(NymColors c, IdentityVault vault) {
    if (_view == 'change') return _changeView(c, vault);
    if (_view == 'off') return _offView(c, vault);
    final isBio = vault.method == 'biometric';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _modalHeader(c, tr('Identity encryption')),
        Text(
          tr('Your identity key is encrypted at rest ({method}).',
              {'method': _methodName(vault)}),
          style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
        ),
        if (isBio && !vault.biometricProtected) ...[
          const SizedBox(height: 12),
          Text(
            tr("This device can't keep the biometric key in its secure "
                'hardware, so the biometric check here only guards the app '
                'screen. Turn encryption off and on again with a password or '
                'PIN for stronger protection.'),
            style: TextStyle(color: c.textDim, fontSize: 11),
          ),
        ],
        _status(c),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            ModalChrome.iconButton(
                c, tr('Close'), () => Navigator.of(context).pop(),
                height: 42),
            if (!isBio)
              ModalChrome.iconButton(c, tr('Change password or PIN'),
                  _busy ? null : () => _go('change'),
                  height: 42),
            ModalChrome.sendButton(
                c, tr('Turn off'), _busy ? null : () => _go('off'),
                danger: true),
          ],
        ),
      ],
    );
  }

  Widget _changeView(NymColors c, IdentityVault vault) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _modalHeader(c, tr('Change password or PIN')),
        Text(
          tr('Enter your current password or PIN, then choose a new one.'),
          style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 6),
        _field(c, _cur, tr('Current password or PIN')),
        _field(c, _next, tr('New password or PIN')),
        _field(c, _next2, tr('Confirm'),
            last: true, onDone: () => _change(vault)),
        _status(c),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ModalChrome.iconButton(
                c, tr('Cancel'), () => Navigator.of(context).pop()),
            const SizedBox(width: 10),
            ModalChrome.sendButton(
              c,
              tr('Change'),
              _busy ? null : () => _change(vault),
              child: _busy ? _spinner(c) : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _offView(NymColors c, IdentityVault vault) {
    final isBio = vault.method == 'biometric';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _modalHeader(c, tr('Turn off identity encryption')),
        Text(
          isBio
              ? tr('Confirm with your passkey or biometric to turn off identity '
                  'encryption.')
              : tr('Enter your password or PIN to turn off identity encryption.'),
          style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
        ),
        if (!isBio) ...[
          const SizedBox(height: 6),
          _field(c, _off, tr('Password or PIN'),
              last: true, onDone: () => _disable(vault)),
        ],
        _status(c),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ModalChrome.iconButton(
                c, tr('Cancel'), () => Navigator.of(context).pop()),
            const SizedBox(width: 10),
            ModalChrome.sendButton(
              c,
              tr('Turn off'),
              _busy ? null : () => _disable(vault),
              danger: true,
              child: _busy ? _spinner(c) : null,
            ),
          ],
        ),
      ],
    );
  }

  /// Header rendered inline because the vault box has no separate header row.
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
        Text(
          tr("Protect your saved identity so it can't be read from this device "
              'without unlocking.'),
          style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 16),
        ModalChrome.formLabel(c, tr('Method')),
        const SizedBox(height: 8),
        ModalChrome.focusRing(
          c,
          child: DropdownButtonFormField<String>(
            initialValue: _method,
            dropdownColor: c.bgTertiary,
            style: TextStyle(color: c.text, fontSize: 14),
            decoration: _decoration(c, ''),
            items: [
              DropdownMenuItem(value: 'password', child: Text(tr('Password'))),
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
              // PIN: strip non-digits on every keystroke.
              inputFormatters:
                  isPin ? [FilteringTextInputFormatter.digitsOnly] : null,
              style: TextStyle(color: c.inputText, fontSize: 15),
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
              style: TextStyle(color: c.inputText, fontSize: 15),
              decoration: _decoration(c, tr('Confirm')),
            ),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr("You'll be asked for your biometric to unlock the app on "
                      'next launch.'),
                  style: TextStyle(color: c.textDim, fontSize: 11),
                ),
                const SizedBox(height: 6),
                Text(
                  tr('The key is tied to the fingerprints or face enrolled '
                      'now. If they change, this device erases it and you will '
                      'need your saved nsec to get back in.'),
                  style: TextStyle(color: c.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        const SizedBox(height: 24),
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

  InputDecoration _decoration(NymColors c, String hint) =>
      ModalChrome.inputDecoration(c, hint);

  Future<void> _enable(IdentityVault vault) async {
    setState(() => _error = null);
    String password = '';
    if (_method != 'biometric') {
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
      // A PIN persists as method `'password'`, never `'pin'`; only WebAuthn factors keep their own name.
      if (_method == 'biometric') {
        await vault.enableBiometric();
      } else {
        await vault.enable(method: 'password', password: password);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      await showAppAlert(
        context,
        tr("Identity encryption enabled and verified. You'll be asked to unlock "
            'on next launch.'),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _change(IdentityVault vault) async {
    if (_busy) return;
    String? problem;
    if (_cur.text.isEmpty) {
      problem = tr('Enter your password or PIN.');
    } else if (_next.text.length < 4) {
      problem = tr('Use at least 4 characters.');
    } else if (_next.text != _next2.text) {
      problem = tr('The two entries do not match.');
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    bool ok;
    try {
      ok = await vault.changePassword(_cur.text, _next.text);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (!ok) {
      _cur.clear();
      setState(() {
        _busy = false;
        _error = tr('Your current password or PIN is incorrect.');
      });
      return;
    }
    Navigator.of(context).pop();
    await showAppAlert(context, tr('Password or PIN changed.'));
  }

  Future<void> _disable(IdentityVault vault) async {
    if (_busy) return;
    final isBio = vault.method == 'biometric';
    if (!isBio && _off.text.isEmpty) {
      setState(() => _error = tr('Enter your password or PIN.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (isBio) {
        await vault.disableBiometric();
      } else {
        await vault.disable(_off.text);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      await showAppAlert(context, tr('Encryption turned off.'));
    } catch (e) {
      if (!mounted) return;
      _off.clear();
      setState(() {
        _busy = false;
        _error = e is BiometricVaultException
            ? e.message
            : isBio
                ? tr('Re-authentication failed. Encryption was not turned off.')
                : tr('Your current password or PIN is incorrect.');
      });
    }
  }
}

/// Once after settings sync, offers to encrypt here too if enabled on another device; shows at most once, true if shown.
Future<bool> maybePromptEncryptAtRest(
  BuildContext context,
  WidgetRef ref,
) async {
  final kv = ref.read(keyValueStoreProvider);
  final vault = ref.read(identityVaultProvider);
  if (vault.isEnabled) return false;
  if (!kv.getBool(StorageKeys.encryptAtRestPref)) return false;
  if (kv.getBool(StorageKeys.encryptAtRestPromptDismissed)) return false;

  // Only nudge when there is a persisted identity secret to protect.
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

  // Persist dismissed up front; either choice dismisses.
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
