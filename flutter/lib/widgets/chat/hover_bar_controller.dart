import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

class HoverBarController extends ChangeNotifier {
  HoverBarController._();

  static final HoverBarController instance = HoverBarController._();

  static const Duration hideDelay = Duration(milliseconds: 150);

  Object? _active;
  Object? _pending;
  Timer? _timer;

  Object? get active => _active;

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

List<String> hoverBarButtons(
  List<String> sheetActions, {
  required bool hasId,
  required double availablePx,
}) {
  final full = [
    if (hasId) 'react',
    if (sheetActions.contains('reply')) 'reply',
    if (sheetActions.contains('thread')) 'thread',
    'more',
  ];
  if (hoverBarWidth(full.length) <= availablePx) return full;
  return [if (hasId) 'react', 'more'];
}
