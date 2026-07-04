import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../screens/home_shell.dart';
import '../../state/nostr_controller.dart';
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
    // Onboarding waits for the SYNCED settings to hydrate before deciding —
    // `tutorialSeen` is a device-spanning synced flag, so a user who already
    // completed (or skipped) the tutorial on another device must not see it
    // again when setting up here. The PWA defers the same way:
    // `startOnboardingWhenHydrated` → `_onSettingsHydrated(maybeStartTutorial)`
    // (app.js:5652-5661), with the controller's built-in 10s fallback so an
    // offline boot still onboards.
    unawaited(_startOnboardingWhenHydrated());
  }

  /// Delay timers (PWA's `setTimeout`s), cancelled on dispose so a torn-down
  /// shell never leaves them pending.
  Timer? _tutorialDelay;
  Timer? _encryptPromptDelay;

  @override
  void dispose() {
    _tutorialDelay?.cancel();
    _encryptPromptDelay?.cancel();
    super.dispose();
  }

  Future<void> _startOnboardingWhenHydrated() async {
    try {
      await ref.read(nostrControllerProvider).settingsHydrated;
    } catch (_) {}
    if (!mounted) return;
    // maybeStartTutorial(false): skip if already seen (now including a flag
    // that just arrived from the remote settings restore).
    final kv = ref.read(keyValueStoreProvider);
    final seen = kv.getString(StorageKeys.tutorialSeen) == 'true' ||
        kv.getBool(StorageKeys.tutorialSeen, defaultValue: false);
    if (!seen) {
      // The PWA's 300ms settle delay before starting (app.js:446).
      _tutorialDelay = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _showTutorial = true);
      });
    }
    // Encrypt-at-rest prompt (key-vault.js `maybePromptEncryptAtRest`): offer
    // to set up identity encryption if a plaintext identity secret sits in
    // storage and the user hasn't declined. The PWA fires it 2.5s AFTER
    // settings hydration (settings.js:253-256) — the synced
    // `encryptAtRestPreferred` flag must land first; never over the tutorial
    // (re-offered on its dismiss).
    _encryptPromptDelay = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) unawaited(_maybePromptEncryptAtRest());
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
    // Publish the seen flag into the SYNCED settings so other devices never
    // re-prompt this user (the PWA's `endTutorial` → `nostrSettingsSave()`,
    // app.js:424-428; the flag rides the `data` section, settings.js:24).
    // Covers Skip, Done, and Escape — every dismissal path lands here.
    try {
      ref.read(nostrControllerProvider).syncSettings();
    } catch (_) {}
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
