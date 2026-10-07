import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/haptics.dart';
import '../../services/api/api_client.dart';
import '../../services/api/storage_sync.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../accounts/account_host.dart';
import '../i18n/i18n.dart';
import 'delete_account.dart';
import 'key_backup/cloudkit_backup_store.dart';
import 'key_backup/key_backup_config.dart';
import 'panic_purge.dart';
import 'panic_wipe.dart';
import 'remote_panic.dart';

/// Runs the emergency wipe; the server purge is signed while the key exists and time-bounded so it can't stall the wipe.
void startPanicWipe(BuildContext context, WidgetRef ref) {
  final ctrl = ref.read(nostrControllerProvider);
  final accounts = ref.read(accountsProvider);
  PanicOverlay.show(
    context,
    wipe: PanicWipe.production(purge: buildPanicPurge(ref)),
    onComplete: () {
      accounts?.forgetAll();
      unawaited(ctrl.resetAfterPanic());
    },
  );
}

void startDeleteAccount(BuildContext context, WidgetRef ref,
    {required PanicIdentityPurge purge, RemotePanicSender? signals}) {
  final ctrl = ref.read(nostrControllerProvider);
  final accounts = ref.read(accountsProvider);
  final iOS = defaultTargetPlatform == TargetPlatform.iOS;
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => DeleteAccountScreen(
        run: DeleteAccountRun(
          purge: purge,
          wipe: PanicWipe.production(),
          marked: signals == null ? null : () => signals.marked.toSet(),
          iCloud: iOS
              ? () async => deleteSavedICloudBackups(
                  await SharedPreferences.getInstance(),
                  CloudKitBackupChannel(
                      container: KeyBackupConfig
                          .environment.appleCloudKitContainer))
              : null,
        ),
        onDone: () {
          accounts?.forgetAll();
          unawaited(ctrl.resetAfterPanic());
        },
      ),
    ),
  );
}

void startLockScreenPanic(BuildContext context, WidgetRef ref,
    {required VoidCallback onComplete}) {
  final accounts = ref.read(accountsProvider);
  PanicOverlay.show(
    context,
    wipe: PanicWipe.production(purge: buildPanicPurge(ref)),
    onComplete: () {
      accounts?.forgetAll();
      onComplete();
    },
  );
}

@visibleForTesting
Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
    panicSendForTest;

PanicIdentityPurge buildPanicPurge(WidgetRef ref) =>
    _buildPurge(ref, deleting: false).purge;

({PanicIdentityPurge purge, RemotePanicSender signals}) buildDeletePurge(
        WidgetRef ref) =>
    _buildPurge(ref, deleting: true);

({PanicIdentityPurge purge, RemotePanicSender signals}) _buildPurge(
    WidgetRef ref,
    {required bool deleting}) {
  final ctrl = ref.read(nostrControllerProvider);
  final api = ApiClient();
  final send = panicSendForTest ??
      (Map<String, dynamic> body) => api.storageAction(body, socket: false);
  final signals = RemotePanicSender.fromStore(
    ref.read(keyValueStoreProvider),
    send: send,
    url: StorageSync.storageUrl,
    publish: ctrl.publishRemotePanicWrap,
    deleting: deleting,
  );
  final purge = PanicIdentityPurge.fromAccounts(
    ref.read(accountsProvider),
    send: send,
    purgeActive: (pubkey) =>
        ctrl.purgeServerRecords(pubkey: pubkey.isEmpty ? null : pubkey),
    beforePurge: signals.call,
    activeKey: ctrl.remotePanicActiveKey,
    activeSigner: ctrl.remotePanicActiveSigner,
    beforePurgeSigned: signals.viaSigner,
    activePubkey: ctrl.identity?.pubkey ?? '',
  );
  return (purge: purge, signals: signals);
}

/// Opaque full-screen "Encrypting" overlay shown during a panic wipe, so nothing sensitive shows.
class PanicOverlay extends StatefulWidget {
  const PanicOverlay({super.key, required this.wipe, this.onComplete});

  final PanicWipe wipe;

  /// Called once the wipe and minimum hold complete; the caller restarts to first run.
  final VoidCallback? onComplete;

  /// Pushes the overlay as an opaque, non-dismissible route and runs the wipe.
  static Future<void> show(
    BuildContext context, {
    required PanicWipe wipe,
    VoidCallback? onComplete,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: true,
        barrierDismissible: false,
        transitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            PanicOverlay(wipe: wipe, onComplete: onComplete),
      ),
    );
  }

  @override
  State<PanicOverlay> createState() => _PanicOverlayState();
}

class _PanicOverlayState extends State<PanicOverlay>
    with SingleTickerProviderStateMixin {
  static const int _cols = 40;
  static const int _rows = 8;
  static const String _charset = '0123456789ABCDEF·×÷=+/\\<>{}[]#@\$%&';

  final Random _rng = Random.secure();
  Timer? _scrambleTimer;
  late final AnimationController _barController;
  String _grid = '';
  String _status = tr('Initializing…');

  @override
  void initState() {
    super.initState();
    Haptics.medium();
    _grid = _randomGrid();
    _scrambleTimer = Timer.periodic(
      const Duration(milliseconds: 60),
      (_) => setState(() => _grid = _randomGrid()),
    );
    _barController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _runWipe();
  }

  Future<void> _runWipe() async {
    final startedAt = DateTime.now();
    // Stage strings track real wipe progress, ending on "Keys destroyed.".
    final report = await widget.wipe.wipe(onStatus: (status) {
      if (mounted) setState(() => _status = status);
    });
    final unremoved = panicPurgeStatus(report.unremoved);
    if (mounted) setState(() => _status = unremoved ?? tr('Keys destroyed.'));
    // Hold the animation at least 1.5s so the effect reads as deliberate.
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    final wait = max(unremoved == null ? 250 : 1500, 1500 - elapsed);
    await Future<void>.delayed(Duration(milliseconds: wait));
    widget.onComplete?.call();
  }

  String _randomGrid() {
    final buf = StringBuffer();
    for (var r = 0; r < _rows; r++) {
      for (var c = 0; c < _cols; c++) {
        buf.write(_charset[_rng.nextInt(_charset.length)]);
      }
      if (r < _rows - 1) buf.write('\n');
    }
    return buf.toString();
  }

  @override
  void dispose() {
    _scrambleTimer?.cancel();
    _barController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return PopScope(
      canPop: false,
      child: Material(
        color: c.bg,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.3),
              radius: 0.9,
              colors: [c.primary.withValues(alpha: 0.08), Colors.transparent],
              stops: const [0, 0.6],
            ),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    tr('ENCRYPTING'),
                    style: TextStyle(
                      color: c.primary.withValues(alpha: 0.9),
                      fontFamily: 'monospace',
                      fontSize: 13,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ClipRect(
                    child: Text(
                      _grid,
                      textAlign: TextAlign.center,
                      maxLines: _rows,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.35,
                        color: c.primary.withValues(alpha: 0.55),
                        shadows: [
                          Shadow(
                            color: c.primary.withValues(alpha: 0.4),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 16),
                    child: Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.textBright.withValues(alpha: 0.95),
                        fontFamily: 'monospace',
                        fontSize: 13,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _ProgressBar(controller: _barController, color: c.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.controller, required this.color});
  final AnimationController controller;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final width = min(320.0, MediaQuery.of(context).size.width * 0.8);
    return SizedBox(
      width: width,
      height: 3,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final t = controller.value;
              final fillW = width * 0.30;
              final travel = width - (-fillW);
              final x = -fillW + travel * t;
              return Stack(
                children: [
                  Positioned(
                    left: x,
                    top: 0,
                    bottom: 0,
                    width: fillW,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: [
                          BoxShadow(
                            color: color.withValues(alpha: 0.6),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
