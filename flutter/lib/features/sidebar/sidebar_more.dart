import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'public_stream.dart' show PsButton, kPsFirst, kPsStep;

const int kSbFirst = kPsFirst;
const int kSbStep = kPsStep;

@immutable
class SbWindow {
  const SbWindow({
    required this.shown,
    required this.visible,
    required this.hidden,
    required this.buttons,
  });

  final int shown;
  final int visible;
  final int hidden;
  final List<PsButton> buttons;

  PsButton? get more {
    for (final b in buttons) {
      if (b.kind != 'less') return b;
    }
    return null;
  }

  PsButton? get less {
    for (final b in buttons) {
      if (b.kind == 'less') return b;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SbWindow &&
      other.shown == shown &&
      other.visible == visible &&
      other.hidden == hidden &&
      listEquals(other.buttons, buttons);

  @override
  int get hashCode => Object.hash(shown, visible, hidden, Object.hashAll(buttons));
}

int _count(num? v, int fallback) {
  if (v == null || !v.isFinite) return fallback;
  final n = v.floor();
  return n < 0 ? 0 : n;
}

SbWindow sbWindow(num? total, num? shown, {bool searching = false}) {
  final n = _count(total, 0);
  final want = math.max(kSbFirst, _count(shown, kSbFirst));
  if (n <= kSbFirst) {
    return SbWindow(shown: kSbFirst, visible: n, hidden: 0, buttons: const []);
  }
  if (searching) {
    return SbWindow(shown: want, visible: n, hidden: 0, buttons: const []);
  }
  final visible = math.min(want, n);
  final hidden = n - visible;
  return SbWindow(shown: want, visible: visible, hidden: hidden, buttons: [
    if (hidden > 0)
      PsButton(want <= kSbFirst ? 'view' : 'show', math.min(kSbStep, hidden),
          want + kSbStep),
    if (want > kSbFirst) const PsButton('less', 0, kSbFirst),
  ]);
}

List<T> sbVisibleRows<T>(List<T> rows, SbWindow win) =>
    win.visible < rows.length ? rows.sublist(0, win.visible) : rows;

int? sbPress(SbWindow? win, String kind) {
  if (win == null) return null;
  final less = kind == 'less';
  for (final b in win.buttons) {
    if ((b.kind == 'less') == less) return b.next;
  }
  return null;
}

int sbStore(num? shown) {
  final s = _count(shown, kSbFirst);
  return s > kSbFirst ? s : 0;
}
