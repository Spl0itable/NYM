import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../screens/home_shell.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../identity/setup_modal.dart';
import '../identity/vault_settings_modal.dart';
import 'tutorial_overlay.dart';

/// First-run boot gate (`setup-modal-init.js` + `checkSavedConnection`).
///
/// Decides what to show on launch:
///  * **needs setup** — no saved Nostr login AND auto-ephemeral is not enabled
///    (`nym_nostr_login_method===null && nym_auto_ephemeral!=='true'`): show the
///    [SetupModal] until the user enters a nym or logs in.
///  * otherwise proceed to the [HomeShell] (auto-ephemeral / saved identity).
///
/// The shell is rendered as soon as the gate decides setup isn't needed; it
/// does not block on `isLive` (the controller boots its ephemeral identity in
/// the background). Once the shell is reached, the first-run [TutorialOverlay]
/// is shown if it hasn't been seen yet.
class BootGate extends ConsumerStatefulWidget {
  const BootGate({super.key});

  @override
  ConsumerState<BootGate> createState() => _BootGateState();
}

class _BootGateState extends ConsumerState<BootGate> {
  /// Null until decided; true => show the setup modal.
  late bool _needsSetup;

  @override
  void initState() {
    super.initState();
    _needsSetup = _computeNeedsSetup();
  }

  /// Mirrors setup-modal-init.js: needs setup when there is no saved login
  /// method and auto-ephemeral hasn't been opted into.
  bool _computeNeedsSetup() {
    final kv = ref.read(keyValueStoreProvider);
    final hasLogin = kv.getString(StorageKeys.nostrLoginMethod) != null;
    final autoEphemeral =
        kv.getString(StorageKeys.autoEphemeral) == 'true' ||
            kv.getBool(StorageKeys.autoEphemeral, defaultValue: false);
    return !hasLogin && !autoEphemeral;
  }

  void _onSetupComplete() {
    if (!mounted) return;
    setState(() => _needsSetup = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_needsSetup) {
      return Scaffold(
        backgroundColor: context.nym.bg,
        body: SetupModal(onComplete: _onSetupComplete),
      );
    }
    // Reached the shell: overlay the first-run tutorial above it.
    return const _ShellWithTutorial();
  }
}

/// The shell plus the first-run guided tutorial overlay (`#tutorialOverlay`).
class _ShellWithTutorial extends ConsumerStatefulWidget {
  const _ShellWithTutorial();

  @override
  ConsumerState<_ShellWithTutorial> createState() =>
      _ShellWithTutorialState();
}

class _ShellWithTutorialState extends ConsumerState<_ShellWithTutorial> {
  bool _showTutorial = false;

  @override
  void initState() {
    super.initState();
    // maybeStartTutorial(false): skip if already seen.
    final kv = ref.read(keyValueStoreProvider);
    final seen = kv.getString(StorageKeys.tutorialSeen) == 'true' ||
        kv.getBool(StorageKeys.tutorialSeen, defaultValue: false);
    if (!seen) {
      // setTimeout(300) in the PWA — defer one frame so the shell paints first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _showTutorial = true);
      });
    }
    // Encrypt-at-rest prompt (key-vault.js `maybePromptEncryptAtRest`): once the
    // shell is reached, offer to set up identity encryption if a plaintext
    // identity secret is sitting in storage and the user hasn't declined. Deferred
    // post-frame so it doesn't fight the tutorial (the PWA delays it ~2.5s); only
    // shown when the first-run tutorial isn't up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybePromptEncryptAtRest());
    });
  }

  /// Shows the "Protect your identity here too?" prompt when
  /// [IdentityVault.shouldPromptEncryptAtRest] is true. "Set up" opens the vault
  /// setup modal; "Not now" persists the decline so we don't nag again. Fires at
  /// most once; never over the tutorial (re-checked after the tutorial closes).
  Future<void> _maybePromptEncryptAtRest() async {
    if (_encryptPromptShown) return;
    final vault = ref.read(identityVaultProvider);
    final shouldPrompt = await vault.shouldPromptEncryptAtRest();
    if (!shouldPrompt || !mounted) return;
    // Don't stack over the first-run tutorial; the dismiss handler re-checks.
    if (_showTutorial) return;
    _encryptPromptShown = true;
    final ok = await showAppConfirm(
      context,
      // key-vault.js `maybePromptEncryptAtRest` body copy.
      'You protect your identity key with encryption on another device. Set it '
      "up on this device as well so your saved key can't be read without "
      "unlocking. You'll choose a password, PIN, or passkey for this device.",
      title: 'Protect your identity here too?',
      okLabel: 'Set up',
      cancelLabel: 'Not now',
    );
    if (!mounted) return;
    if (ok) {
      await VaultSettingsModal.open(context);
    } else {
      await vault.declineEncryptAtRest();
    }
  }

  /// Whether the encrypt-at-rest prompt has been shown this session
  /// (key-vault.js `_atRestPromptShown`).
  bool _encryptPromptShown = false;

  Future<void> _dismissTutorial() async {
    final kv = ref.read(keyValueStoreProvider);
    await kv.setString(StorageKeys.tutorialSeen, 'true');
    if (mounted) setState(() => _showTutorial = false);
    // The encrypt-at-rest prompt is suppressed while the tutorial is up; now
    // that it's closed, offer it (still gated by shouldPromptEncryptAtRest).
    unawaited(_maybePromptEncryptAtRest());
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        HomeShell(key: HomeShell.tutorialKey),
        if (_showTutorial)
          Positioned.fill(
            // The tutorial renders one frame after the shell mounts (post-frame
            // setState below), so `tutorialKey.currentState` is populated here.
            // On narrow layouts the overlay drives the drawer per step; on wide
            // layouts the driver's open/close are no-ops and targets spotlight
            // in place.
            child: TutorialOverlay(
              onDismiss: _dismissTutorial,
              sidebar: HomeShell.tutorialKey.currentState,
            ),
          ),
      ],
    );
  }
}
