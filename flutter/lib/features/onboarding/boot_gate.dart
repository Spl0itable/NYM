import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../core/theme/nym_colors.dart';
import '../../screens/home_shell.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../i18n/i18n.dart';
import '../i18n/language_select.dart';
import '../i18n/localization_service.dart';
import '../identity/setup_modal.dart';
import '../identity/vault_settings_modal.dart';
import '../notifications/background_catch_up.dart';
import 'tutorial_overlay.dart';

/// Launch gate: language chooser, then setup if there is no saved login, else the shell and tutorial.
class BootGate extends ConsumerStatefulWidget {
  const BootGate({super.key});

  @override
  ConsumerState<BootGate> createState() => _BootGateState();
}

class _BootGateState extends ConsumerState<BootGate> {
  /// True shows the setup modal.
  late bool _needsSetup;

  /// First-run language chooser, shown at most once and before setup so everything after renders in that language.
  late bool _languageChosen;

  @override
  void initState() {
    super.initState();
    _needsSetup = _computeNeedsSetup();
    final kv = ref.read(keyValueStoreProvider);
    _languageChosen =
        kv.getBool(StorageKeys.uiLanguageChosen, defaultValue: false);
  }

  /// Needs setup when there is no saved login method and auto-ephemeral isn't opted into.
  bool _computeNeedsSetup() =>
      !hasChosenIdentity(ref.read(keyValueStoreProvider));

  void _onSetupComplete() {
    if (!mounted) return;
    setState(() => _needsSetup = false);
  }

  void _onLanguageChosen() {
    if (!mounted) return;
    // Start translating the tutorial now at middle priority, so it's ready by the time the user reaches it.
    LocalizationService.instance.prime(tutorialStringsForPretranslate());
    setState(() => _languageChosen = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_languageChosen) {
      return LanguageSelectScreen(onComplete: _onLanguageChosen);
    }
    // The static setup modal watches the i18n version so it re-renders as its translations land.
    if (_needsSetup) {
      return Scaffold(
        backgroundColor: context.nym.bg,
        body: Consumer(
          builder: (context, ref, _) {
            ref.watch(i18nVersionProvider);
            return SetupModal(onComplete: _onSetupComplete);
          },
        ),
      );
    }
    return const _ShellWithTutorial();
  }
}

class _ShellWithTutorial extends ConsumerStatefulWidget {
  const _ShellWithTutorial();

  @override
  ConsumerState<_ShellWithTutorial> createState() => _ShellWithTutorialState();
}

class _ShellWithTutorialState extends ConsumerState<_ShellWithTutorial> {
  bool _showTutorial = false;

  @override
  void initState() {
    super.initState();
    // Wait for synced settings so a tutorial already seen on another device isn't shown again; the controller falls back after 10s.
    unawaited(_startOnboardingWhenHydrated());
  }

  /// Canceled on dispose so a torn-down shell never leaves timers pending.
  Timer? _tutorialDelay;
  Timer? _pqNoticeDelay;
  Timer? _pqNoticeRetry;
  bool _pqNoticeShown = false;
  Timer? _encryptPromptDelay;

  @override
  void dispose() {
    _tutorialDelay?.cancel();
    _pqNoticeDelay?.cancel();
    _pqNoticeRetry?.cancel();
    _encryptPromptDelay?.cancel();
    super.dispose();
  }

  Future<void> _startOnboardingWhenHydrated() async {
    try {
      await ref.read(nostrControllerProvider).settingsHydrated;
    } catch (_) {}
    if (!mounted) return;
    _startTutorialAndPrompts();
  }

  /// Runs after settings hydrate: the tutorial-seen gate and the deferred encrypt-at-rest prompt.
  void _startTutorialAndPrompts() {
    if (!mounted) return;
    // Skip if seen, including a flag just restored from remote settings.
    final kv = ref.read(keyValueStoreProvider);
    final seen = kv.getString(StorageKeys.tutorialSeen) == 'true' ||
        kv.getBool(StorageKeys.tutorialSeen, defaultValue: false);
    if (!seen) {
      // Pre-translate the whole tutorial; the static overlay only re-renders via the i18n watch.
      LocalizationService.instance.prime(tutorialStringsForPretranslate());
      // 300ms settle delay before starting.
      _tutorialDelay = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _showTutorial = true);
      });
    }
    // Encrypt-at-rest offer, 2.5s after hydration so the synced flag has landed; never over the tutorial.
    _encryptPromptDelay = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) unawaited(_maybePromptEncryptAtRest());
    });

    // Skip the post-quantum notice when the tutorial covers the same ground; dismissed, not deferred.
    if (!seen) {
      unawaited(ref.read(nostrControllerProvider).dismissPqUpgradeNotice());
    } else {
      // Twice: the lock that makes a fresh device need the code is known only after §6 settles.
      _pqNoticeDelay = Timer(const Duration(milliseconds: 3500), () {
        if (mounted) unawaited(_maybeShowPqNotice());
        _pqNoticeRetry = Timer(const Duration(seconds: 12), () {
          if (!mounted) return;
          unawaited(_maybeShowPqNotice());
          // Retry the encrypt-at-rest offer; a locked second device can't read the synced flag at 2.5s.
          unawaited(_maybePromptEncryptAtRest());
        });
      });
    }
  }

  /// One-time post-quantum notice: a device holding the root is told to save the code, one without it to link.
  Future<void> _maybeShowPqNotice() async {
    if (_pqNoticeShown) return;
    final ctrl = ref.read(nostrControllerProvider);
    // Opens for an upgrade that should save its code or a device that must paste one.
    final linkPending = ctrl.pqRootLinkPromptPending;
    final backupPending = ctrl.pqRootBackupPending && ctrl.pqRootHeld;
    if (!ctrl.pqUpgradeNoticePending && !linkPending && !backupPending) return;
    _pqNoticeShown = true;
    await ctrl.dismissPqUpgradeNotice();
    if (linkPending) await ctrl.dismissPqRootLinkPrompt();
    if (backupPending && !ctrl.pqRootLinkNeeded) {
      await ctrl.dismissPqRootBackupNotice();
    }
    if (!mounted) return;
    final linkNeeded = ctrl.pqRootLinkNeeded;
    if (linkNeeded) {
      // A device that needs the code can paste it right here.
      final pasted = await showAppPrompt(
        context,
        tr('This account already has a post-quantum recovery code, and this '
            'device does not have it yet.\n\nUntil you add it, this device '
            'keeps working normally but cannot read the quantum-resistant '
            'messages your other devices can.\n\nPaste the nympq1… code from '
            'a device that has it — you will find it there under View or Edit '
            'Nym\u2019s Details. You can also do this later, in that same '
            'panel.'),
        title: tr('Add your post-quantum recovery code'),
        okLabel: tr('Link this device'),
        cancelLabel: tr('Later'),
        placeholder: 'nympq1…',
      );
      final code = (pasted ?? '').trim();
      if (code.isEmpty || !mounted) return;
      final ok = await ctrl.linkPqRootFromCode(code);
      if (!mounted) return;
      await showAppAlert(
        context,
        ok
            ? tr('Linked. This device can now read your quantum-resistant '
                'messages.')
            : tr('That code does not match this account. Check it and try '
                'again — you can also paste it in View or Edit Nym\u2019s '
                'Details.'),
        title: ok ? tr('Linked') : tr('That code did not match'),
        okLabel: tr('Got it'),
      );
      return;
    }
    await showAppAlert(
      context,
      tr('Your private messages and group chats with other Nymchat '
          'users are now encrypted with an added post-quantum key '
          'exchange (ML-KEM-768), so traffic recorded today can\u2019t be '
          'decrypted later by a quantum computer.\n\nThis uses a recovery '
          'code, not your nsec. Save the code below alongside your '
          'nsec — you will need it to read these messages on another '
          'device, and if every device holding it is lost, they cannot be '
          'recovered. It is always available in your Nym\u2019s details.'),
      title: tr('Quantum-resistant encryption is on'),
      okLabel: tr('Got it'),
      // Let the user copy the code at the moment it is explained.
      copyValue: ctrl.pqRootCode,
      copyLabel: tr('Copy code'),
      copiedMessage: tr('Post-quantum recovery code copied'),
      secret: true,
    );
  }

  /// Offers identity encryption once when [IdentityVault.shouldPromptEncryptAtRest]; declining persists.
  Future<void> _maybePromptEncryptAtRest() async {
    if (_encryptPromptShown) return;
    final vault = ref.read(identityVaultProvider);
    final shouldPrompt = await vault.shouldPromptEncryptAtRest();
    if (!shouldPrompt || !mounted) return;
    // Don't stack over the tutorial; its dismiss handler re-checks.
    if (_showTutorial) return;
    _encryptPromptShown = true;
    final ok = await showAppConfirm(
      context,
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

  bool _encryptPromptShown = false;

  Future<void> _dismissTutorial() async {
    final kv = ref.read(keyValueStoreProvider);
    await kv.setString(StorageKeys.tutorialSeen, 'true');
    // Publish the seen flag to synced settings so other devices don't re-prompt; every dismissal path lands here.
    try {
      ref.read(nostrControllerProvider).syncSettings();
    } catch (_) {}
    if (mounted) setState(() => _showTutorial = false);
    // Suppressed while the tutorial was up; offer it now.
    unawaited(_maybePromptEncryptAtRest());
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        HomeShell(key: HomeShell.tutorialKey),
        if (_showTutorial)
          Positioned.fill(
            // Watch the i18n version here, scoped to the static overlay, so late translations re-render it without rebuilding the shell.
            child: Consumer(
              builder: (context, ref, _) {
                ref.watch(i18nVersionProvider);
                // On narrow layouts the overlay drives the drawer per step; on wide layouts that's a no-op.
                return TutorialOverlay(
                  onDismiss: _dismissTutorial,
                  sidebar: HomeShell.tutorialKey.currentState,
                  nsec: () {
                    final privkey =
                        ref.read(nostrControllerProvider).identity?.privkey;
                    if (privkey == null) return null;
                    try {
                      return bech32.encodeNsecBytes(privkey);
                    } catch (_) {
                      return null;
                    }
                  },
                  recoveryCode: () =>
                      ref.read(nostrControllerProvider).pqRootCode,
                );
              },
            ),
          ),
      ],
    );
  }
}
