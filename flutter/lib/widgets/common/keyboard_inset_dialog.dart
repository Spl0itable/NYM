import 'package:flutter/material.dart';

/// Centers a custom (non-[Dialog]) modal and keeps it clear of the soft
/// keyboard.
///
/// `showDialog` bodies that build their own `Center(child: Container(...))`
/// layout — rather than using [AlertDialog]/[Dialog], which inset themselves —
/// otherwise stay centered against the full screen height, so any field below
/// the vertical midpoint hides behind the keyboard. Wrapping the modal body in
/// this widget (in place of the bare `Center`) shifts it up by the keyboard
/// inset and caps its height to the visible area, so a scrollable body can
/// bring the focused field above the keyboard.
///
/// For short, non-scrolling modals the height cap never binds (the content is
/// shorter than the visible area) and only the upward shift applies — which is
/// exactly what reveals a covered field.
class KeyboardInsetDialog extends StatelessWidget {
  const KeyboardInsetDialog({
    super.key,
    required this.child,
    this.bottomInsetMargin = 40,
  });

  /// The modal body (typically the `Container`/`Material` the dialog used to
  /// return directly inside a `Center`).
  final Widget child;

  /// Breathing room, in logical pixels, left between the modal and the top of
  /// the keyboard (and the screen edges) when the cap binds.
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
