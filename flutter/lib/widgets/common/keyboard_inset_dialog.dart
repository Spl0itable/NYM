import 'package:flutter/material.dart';

/// Centers a custom (non-[Dialog]) modal, shifted up by the keyboard inset and capped to the visible height.
class KeyboardInsetDialog extends StatelessWidget {
  const KeyboardInsetDialog({
    super.key,
    required this.child,
    this.bottomInsetMargin = 40,
  });

  final Widget child;

  /// Gap in logical pixels between the modal and the keyboard or screen edges when the cap binds.
  final double bottomInsetMargin;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final visibleHeight = mq.size.height - mq.viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight:
                (visibleHeight - bottomInsetMargin).clamp(200.0, visibleHeight),
          ),
          child: child,
        ),
      ),
    );
  }
}
