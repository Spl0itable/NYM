import 'package:flutter/widgets.dart';

Rect shareOriginOf(BuildContext? context) {
  final screen = _screenRect();
  if (context != null && context.mounted) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize && !box.size.isEmpty) {
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final visible = screen == null ? rect : rect.intersect(screen);
      if (!visible.isEmpty) return visible;
    }
  }
  if (screen == null) return const Rect.fromLTWH(0, 0, 1, 1);
  return Rect.fromCenter(center: screen.center, width: 1, height: 1);
}

Rect? _screenRect() {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return null;
  final view = views.first;
  if (view.devicePixelRatio <= 0) return null;
  final size = view.physicalSize / view.devicePixelRatio;
  if (size.isEmpty) return null;
  return Offset.zero & size;
}
