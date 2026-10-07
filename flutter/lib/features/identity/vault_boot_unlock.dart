import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/theme/nym_theme.dart' show kMonoFont;
import '../../services/storage/at_rest_wipe.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/panic_hold_detector.dart';
import '../accounts/account_host.dart';
import '../accounts/account_logic.dart';
import '../accounts/account_switcher.dart' show accountDisplayName;
import '../i18n/i18n.dart';
import 'biometric_secret_store.dart';
import 'identity_vault.dart' show SecureStoreLike;
import 'modal_chrome.dart';
import 'panic_overlay.dart';
import 'vault_settings_modal.dart' show identityVaultProvider;

const String nymchatWordmark = r'''                                            ##\                  ##\
                                            ## |                 ## |
#######\  ##\   ##\ ######\####\   #######\ #######\   ######\ ######\
##  __##\ ## |  ## |##  _##  _##\ ##  _____|##  __##\  \____##\\_##  _|
## |  ## |## |  ## |## / ## / ## |## /      ## |  ## | ####### | ## |
## |  ## |## |  ## |## | ## | ## |## |      ## |  ## |##  __## | ## |##\
## |  ## |\####### |## | ## | ## |\#######\ ## |  ## |\####### | \####  |
\__|  \__| \____## |\__| \__| \__| \_______|\__|  \__| \_______|  \____/
          ##\   ## |
          \######  |
           \______/''';

/// Blocks launch until the identity vault unlocks, so secrets are decrypted before identity restore reads them.
class VaultBootUnlock extends ConsumerStatefulWidget {
  const VaultBootUnlock({
    super.key,
    required this.onUnlocked,
    required this.onForget,
    this.secureStore,
  });

  /// Called with the decrypted secrets, which the caller keeps in memory.
  final void Function(Map<String, String> secrets) onUnlocked;

  /// Called on vault reset; the caller drops login pointers and proceeds to a clean first run.
  final VoidCallback onForget;

  /// Defaults to the platform keystore; tests inject an in-memory fake.
  final SecureStoreLike? secureStore;

  @override
  ConsumerState<VaultBootUnlock> createState() => _VaultBootUnlockState();
}

class VaultLockedApp extends StatelessWidget {
  const VaultLockedApp({super.key, required this.app, required this.lock});

  final Widget app;
  final Widget lock;

  @override
  Widget build(BuildContext context) => Stack(
        textDirection: TextDirection.ltr,
        children: [
          Offstage(child: TickerMode(enabled: false, child: app)),
          lock,
        ],
      );
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

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final vault = ref.read(identityVaultProvider);
    try {
      final Map<String, String> secrets;
      if (_isBiometric) {
        secrets = await vault.unlockBiometric();
      } else {
        final password = _pw.text;
        if (password.isEmpty) {
          throw StateError(tr('Enter your password or PIN.'));
        }
        secrets = await vault.unlock(password);
      }
      if (mounted) widget.onUnlocked(secrets);
    } catch (e) {
      if (mounted) {
        _pw.clear();
        setState(() {
          _busy = false;
          _error = _messageOf(e);
        });
      }
    }
  }

  static String _messageOf(Object e) {
    final m = e is BiometricVaultException
        ? e.message
        : e is StateError
            ? e.message
            : e is FormatException
                ? e.message
                : e is ArgumentError
                    ? e.message?.toString()
                    : null;
    if (m == null || m.isEmpty) return tr('Unlock failed.');
    if (m == 'Wrong password/PIN or unrecognized passkey.') {
      return tr('Wrong password/PIN or unrecognized passkey.');
    }
    return m;
  }

  Future<void> _forgetIdentity() async {
    final accounts = ref.read(accountsProvider);
    if (accounts != null &&
        accounts.changes.value.activeAccount != null &&
        await accounts.logout()) {
      return;
    }
    if (!mounted) return;
    await _resetIdentity();
    if (mounted) widget.onForget();
  }

  Future<void> _resetIdentity() async {
    final kv = ref.read(keyValueStoreProvider);
    await ref.read(identityVaultProvider).reset();
    unawaited(forgetAtRestData(kv));
  }

  /// Confirms, then resets the vault and hands control back for a clean first run.
  Future<void> _forget() async {
    final confirmed = await _confirmForget();
    if (!confirmed) return;
    await _forgetIdentity();
  }

  String? _nextAccountName() {
    final accounts = ref.read(accountsProvider);
    if (accounts == null) return null;
    final plan = AccountLogic.plan(accounts.changes.value, const LogoutOp());
    final next = plan.ok ? plan.index.activeAccount : null;
    return next == null ? null : accountDisplayName(next);
  }

  Future<bool> _confirmForget() {
    final next = _nextAccountName();
    final current = ref.read(accountsProvider)?.changes.value.activeAccount;
    return showAppConfirm(
      context,
      next != null && current != null
          ? tr('This permanently deletes {nym} and its data on this device, '
              'and you will switch to {next}. Continue?',
              {'nym': accountDisplayName(current), 'next': next})
          : tr('This permanently deletes the encrypted identity on this device and '
              'starts a fresh one. Continue?'),
      title: tr('Forget identity'),
      okLabel: tr('Forget'),
      danger: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isBio = _isBiometric;
    return Material(
      color: c.bg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _promptChildren(c, isBio),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _panicking = false;

  void _panic() {
    if (_panicking) return;
    _panicking = true;
    FocusManager.instance.primaryFocus?.unfocus();
    startLockScreenPanic(context, ref, onComplete: widget.onForget);
  }

  Widget _wordmark(NymColors c) {
    return PanicHoldDetector(
      key: const Key('vaultWordmarkPanic'),
      onHold: _panic,
      child: _wordmarkText(c),
    );
  }

  Widget _wordmarkText(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Center(
        child: Semantics(
          label: 'Nymchat',
          excludeSemantics: true,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              nymchatWordmark,
              style: TextStyle(
                fontFamily: kMonoFont,
                fontFamilyFallback: const [
                  'Menlo',
                  'SF Mono',
                  'Roboto Mono',
                  'Droid Sans Mono',
                  'DejaVu Sans Mono',
                  'Liberation Mono',
                  'Courier New',
                ],
                fontSize: 10,
                height: 1.08,
                letterSpacing: 0,
                color: c.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(NymColors c, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          color: c.text,
          fontSize: NymType.xl,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
    );
  }

  Widget _lede(NymColors c, String text, {bool error = false}) {
    return Text(
      text,
      style: TextStyle(
        color: error ? c.danger : c.textDim,
        fontSize: 14,
        height: 1.5,
      ),
    );
  }

  Widget _primary(NymColors c, String label, VoidCallback? onTap,
      {Widget? child}) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: Material(
        color: c.primaryA(0.1),
        shape: RoundedRectangleBorder(
          borderRadius: NymRadius.rxs,
          side: BorderSide(color: c.primary),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Center(
              child: child ??
                  Text(
                    label,
                    style: TextStyle(
                      color: c.primary,
                      fontSize: NymType.lg,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ghost(NymColors c, String label, VoidCallback? onTap) {
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: NymRadius.rxs,
        side: BorderSide(color: c.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: c.textDim,
                fontSize: NymType.lg,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _promptChildren(NymColors c, bool isBio) {
    return [
      _wordmark(c),
      _title(c, tr('Unlock your identity')),
      _lede(
          c,
          isBio
              ? tr('Your Nymchat identity key is encrypted on this device. '
                  'Use your biometric to unlock.')
              : tr('Your Nymchat identity key is encrypted on this device.')),
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
            style: TextStyle(color: c.inputText, fontSize: 15),
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            _error!,
            style: TextStyle(color: c.danger, fontSize: NymType.md, height: 1.4),
          ),
        ),
      SizedBox(height: isBio ? 4 : 16),
      _primary(
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
      const SizedBox(height: 8),
      _ghost(c, tr('Forget identity'), _busy ? null : _forget),
      if (_busy)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            tr('Unlocking…'),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: NymType.md),
          ),
        ),
    ];
  }
}
