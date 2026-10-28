import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

abstract final class EscapeRank {
  static const int translate = 30;
  static const int picker = 40;
  static const int quickReact = 50;
}

class EscapeLayer {
  EscapeLayer._(this.rank, this.isOpen, this.close);
  final int rank;
  final bool Function() isOpen;
  final VoidCallback close;
}

abstract final class EscapeLayers {
  static final List<EscapeLayer> _layers = [];

  static EscapeLayer add(int rank, bool Function() isOpen, VoidCallback close) {
    final layer = EscapeLayer._(rank, isOpen, close);
    _layers.add(layer);
    return layer;
  }

  static void remove(EscapeLayer? layer) {
    if (layer != null) _layers.remove(layer);
  }

  static final Map<FocusNode, bool Function()> _textBusy = {};

  static void watchText(FocusNode node, bool Function() busy) =>
      _textBusy[node] = busy;

  static void unwatchText(FocusNode node) => _textBusy.remove(node);

  static bool textBusy(FocusNode? node) =>
      node != null && (_textBusy[node]?.call() ?? false);

  static bool closeTop({int minRank = 0}) {
    EscapeLayer? top;
    for (final l in _layers.toList()) {
      if (l.rank < minRank || !l.isOpen()) continue;
      if (top == null || l.rank >= top.rank) top = l;
    }
    if (top == null) return false;
    top.close();
    return true;
  }
}

class EscapeToClose extends StatelessWidget {
  const EscapeToClose({super.key, required this.onEscape, required this.child});

  final VoidCallback onEscape;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        onEscape();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}
