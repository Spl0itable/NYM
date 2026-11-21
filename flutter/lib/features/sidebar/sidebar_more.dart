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

Set<int> _keepSet(Iterable<num>? keep, int total) {
  final out = <int>{};
  if (keep == null) return out;
  for (final raw in keep) {
    if (!raw.isFinite || raw != raw.truncateToDouble()) continue;
    final i = raw.toInt();
    if (i >= 0 && i < total) out.add(i);
  }
  return out;
}

int _keptPast(Set<int> ks, int from) {
  var n = 0;
  for (final i in ks) {
    if (i >= from) n++;
  }
  return n;
}

SbWindow sbWindow(num? total, num? shown, Iterable<num>? keep,
    {bool searching = false}) {
  final n = _count(total, 0);
  final want = math.max(kSbFirst, _count(shown, kSbFirst));
  if (n <= kSbFirst) {
    return SbWindow(shown: kSbFirst, visible: n, hidden: 0, buttons: const []);
  }
  if (searching) {
    return SbWindow(shown: want, visible: n, hidden: 0, buttons: const []);
  }
  final ks = _keepSet(keep, n);
  final visible = math.min(want, n) + _keptPast(ks, want);
  final hidden = n - visible;
  final buttons = <PsButton>[];
  if (hidden > 0) {
    final step = math.min(kSbStep, hidden);
    var seen = 0;
    var i = want;
    while (seen < step) {
      if (!ks.contains(i)) seen++;
      i++;
    }
    buttons.add(PsButton(
        want <= kSbFirst ? 'view' : 'show', step, math.max(i, want + kSbStep)));
  }
  if (want > kSbFirst && n - (kSbFirst + _keptPast(ks, kSbFirst)) > 0) {
    buttons.add(const PsButton('less', 0, kSbFirst));
  }
  return SbWindow(shown: want, visible: visible, hidden: hidden, buttons: buttons);
}

List<int> sbHiddenRows(num? total, num? shown, Iterable<num>? keep,
    {bool searching = false}) {
  final n = _count(total, 0);
  final want = math.max(kSbFirst, _count(shown, kSbFirst));
  if (n <= kSbFirst || searching) return const [];
  final ks = _keepSet(keep, n);
  return [
    for (var i = want; i < n; i++)
      if (!ks.contains(i)) i,
  ];
}

List<T> sbVisibleRows<T>(List<T> rows, SbWindow win, Iterable<num>? keep) {
  final n = rows.length;
  if (win.hidden <= 0) return rows;
  final cut = math.min(win.shown, n);
  final ks = _keepSet(keep, n);
  return [
    ...rows.sublist(0, cut),
    for (var i = cut; i < n; i++)
      if (ks.contains(i)) rows[i],
  ];
}

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
