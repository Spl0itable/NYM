import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../screens/home_shell.dart';
import '../../state/settings_provider.dart';
import '../identity/setup_modal.dart';
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
  }

  Future<void> _dismissTutorial() async {
    final kv = ref.read(keyValueStoreProvider);
    await kv.setString(StorageKeys.tutorialSeen, 'true');
    if (mounted) setState(() => _showTutorial = false);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const HomeShell(),
        if (_showTutorial)
          Positioned.fill(
            child: TutorialOverlay(onDismiss: _dismissTutorial),
          ),
      ],
    );
  }
}
