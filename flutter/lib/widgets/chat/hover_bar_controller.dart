import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../features/reactions/hover_actions.dart';

class HoverBarController extends ChangeNotifier {
  HoverBarController._();

  static final HoverBarController instance = HoverBarController._();

  static const Duration hideDelay = Duration(milliseconds: 150);

  Object? _active;
  Object? _pending;
  Timer? _timer;

  Object? get active => _active;

  String? get activeId => _active is MessageHoverOwner
      ? (_active as MessageHoverOwner).hoverMessageId
      : null;

  void request(Object? owner) {
    if (identical(owner, _active)) {
      _cancel();
      return;
    }
    if (_active == null) {
      _activate(owner);
      return;
    }
    if (_timer != null && identical(_pending, owner)) return;
    _cancel();
    _pending = owner;
    _timer = Timer(hideDelay, () => _activate(_pending));
  }

  void release(Object owner) {
    if (identical(_pending, owner)) {
      _cancel();
    }
    if (identical(_active, owner)) {
      _cancel();
      _active = null;
      notifyListeners();
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  void _activate(Object? owner) {
    _cancel();
    if (identical(owner, _active)) return;
    _active = owner;
    notifyListeners();
  }
}

const double kHoverBarButtonWidth = 34;
const double kHoverBarButtonHeight = 26;
const double kHoverBarGap = 4;
const double kColumnsBubbleGutter = 16;
const double kHoverBarAbove = 14;
const double kHoverBarOverlap = 8;
const double kHoverBarEdge = 4;

Offset hoverBarSpot(Rect bubble, Rect clip, double bw, double bh,
    {required bool self, required bool columns}) {
  var x = self
      ? bubble.left + kHoverBarOverlap - bw
      : columns
          ? clip.right - kHoverBarEdge - bw
          : bubble.right - kHoverBarOverlap;
  x = math.max(clip.left + kHoverBarEdge,
      math.min(x, clip.right - kHoverBarEdge - bw));
  final y = math.max(bubble.top - kHoverBarAbove, clip.top + kHoverBarEdge);
  return Offset(x.roundToDouble(), y.roundToDouble());
}

double hoverBarWidth(int count) =>
    count <= 0 ? 0 : count * kHoverBarButtonWidth + (count - 1) * kHoverBarGap;

List<String> fitHoverBar(List<String> full, double availablePx) {
  final ids = full.isEmpty ? const ['more'] : full;
  if (hoverBarWidth(ids.length) <= availablePx) return [...ids];
  return ids.length > 1 ? [ids.first, 'more'] : const ['more'];
}

List<String> hoverBarButtons(
  List<String> sheetActions, {
  required bool hasId,
  required double availablePx,
  Object? slots,
}) =>
    fitHoverBar([
      ...resolveHoverActions(
          slots, [if (hasId) 'react', ...sheetActions]),
      'more',
    ], availablePx);

abstract interface class MessageHoverOwner {
  String get hoverMessageId;
}

class MessageHover extends InheritedWidget {
  const MessageHover({
    super.key,
    required this.messageId,
    required this.hovered,
    required super.child,
  });

  final String messageId;
  final bool hovered;

  static MessageHover? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MessageHover>();

  static bool hoveredOf(BuildContext context) =>
      maybeOf(context)?.hovered ?? false;

  @override
  bool updateShouldNotify(MessageHover oldWidget) =>
      oldWidget.hovered != hovered || oldWidget.messageId != messageId;
}
