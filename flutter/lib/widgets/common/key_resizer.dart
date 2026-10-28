import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';

class KeyResizer extends StatefulWidget {
  const KeyResizer({super.key, required this.onStep, required this.child});

  static const double step = 16;

  final ValueChanged<double> onStep;
  final Widget child;

  @override
  State<KeyResizer> createState() => _KeyResizerState();
}

class _KeyResizerState extends State<KeyResizer> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.onStep(-KeyResizer.step);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onStep(KeyResizer.step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ring = _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return Focus(
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          color: ring ? context.nym.primaryA(0.5) : null,
        ),
        child: widget.child,
      ),
    );
  }
}
