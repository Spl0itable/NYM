import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import 'panic_wipe.dart';

/// Full-screen "Encrypting" scramble overlay shown during a panic wipe
/// (`_panicShowOverlay`, docs/specs/04 §10.2 step 1):
///
/// * "ENCRYPTING" title (uppercase, letter-spacing, primary colour)
/// * a 40×8 hex/symbol grid re-randomised every ~60 ms (mono, primary, dim)
/// * a status line that updates through the wipe stages
/// * an indeterminate progress bar (`nm-panic-fill`)
///
/// Opaque background so nothing sensitive shows while the data is destroyed.
class PanicOverlay extends StatefulWidget {
  const PanicOverlay({super.key, required this.wipe, this.onComplete});

  /// The wipe to run while the animation plays.
  final PanicWipe wipe;

  /// Called once the wipe + minimum hold completes (caller restarts to
  /// first-run). Tests may omit this.
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
        pageBuilder: (_, __, ___) =>
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
  String _status = 'Initializing…';

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
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
    if (mounted) setState(() => _status = 'Encrypting local store…');
    await widget.wipe.wipe();
    if (mounted) setState(() => _status = 'Shredding local databases…');
    if (mounted) setState(() => _status = 'Keys destroyed.');
    // Hold the animation a minimum so the effect reads as deliberate (PWA: 1.5s).
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    final wait = max(250, 1500 - elapsed);
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
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'ENCRYPTING',
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 13,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
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
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 16,
                  child: Text(
                    _status,
                    style: TextStyle(
                      color: c.textBright,
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
    );
  }
}

/// The indeterminate sliding fill bar (`nm-panic-bar` / `nm-panic-fill`).
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
              // Slide a 30%-wide fill from -100% to 333% (PWA keyframes).
              final t = controller.value;
              final fillW = width * 0.30;
              final travel = width - (-fillW); // from off-left to off-right
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
