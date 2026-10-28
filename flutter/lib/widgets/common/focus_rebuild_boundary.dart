import 'package:flutter/widgets.dart';

class FocusRebuildBoundary extends StatelessWidget {
  const FocusRebuildBoundary({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: child,
    );
  }
}
