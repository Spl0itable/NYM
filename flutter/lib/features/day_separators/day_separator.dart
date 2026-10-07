import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import '../i18n/localization_service.dart';
import '../messages/format/discord_timestamp.dart';
import 'day_labels.dart';

class DayClock extends ChangeNotifier {
  DayClock._();

  static final DayClock instance = DayClock._();

  int Function() _nowMs = () => DateTime.now().millisecondsSinceEpoch;
  DayZone _zone = DayZone.local;
  Timer? _timer;
  int _listeners = 0;

  int get nowSec => _nowMs() ~/ 1000;

  DayZone get zone => _zone;

  String keyOf(int createdAt) => dayKeyOf(createdAt, nowSec, _zone);

  bool sameDay(int a, int b) {
    final now = nowSec;
    return dayKeyOf(a, now, _zone) == dayKeyOf(b, now, _zone);
  }

  String labelOf(int createdAt) {
    String? language;
    try {
      language = LocalizationService.instance.language;
    } catch (_) {
      language = null;
    }
    return formatDayLabel(
      dayInfo(createdAt, nowSec, _zone),
      resolveTimestampLocale(language),
      (s) => tr(s),
    );
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listeners++;
    _arm();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listeners--;
    if (_listeners <= 0) {
      _listeners = 0;
      _timer?.cancel();
      _timer = null;
    }
  }

  void _arm() {
    if (_timer != null || _listeners <= 0) return;
    final now = _nowMs();
    final wait = nextMidnightMs(now, _zone) - now + 1000;
    _timer = Timer(Duration(milliseconds: wait < 1000 ? 1000 : wait), () {
      _timer = null;
      notifyListeners();
      _arm();
    });
  }

  @visibleForTesting
  void debugOverride({int Function()? nowMs, DayZone? zone}) {
    _nowMs = nowMs ?? () => DateTime.now().millisecondsSinceEpoch;
    _zone = zone ?? DayZone.local;
    _timer?.cancel();
    _timer = null;
    _arm();
    notifyListeners();
  }

  @visibleForTesting
  bool get isRunning => _timer != null;
}

class DaySeparator extends StatelessWidget {
  const DaySeparator({
    super.key,
    required this.createdAt,
    required this.useBubbles,
  });

  final int createdAt;
  final bool useBubbles;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DayClock.instance,
      builder: (context, _) {
        final clock = DayClock.instance;
        final label = clock.labelOf(createdAt);
        final c = context.nym;
        final child = useBubbles
            ? Center(child: DayPill(label: label))
            : Row(
                children: [
                  Expanded(child: Container(height: 1, color: c.glassBorder)),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: TextStyle(
                      color: c.textDim,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.44,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Container(height: 1, color: c.glassBorder)),
                ],
              );
        return Padding(
          key: ValueKey('day-separator-${clock.keyOf(createdAt)}'),
          padding: useBubbles
              ? const EdgeInsets.only(top: 10, bottom: 6)
              : const EdgeInsets.symmetric(vertical: 8),
          child: Semantics(
            container: true,
            header: true,
            label: label,
            excludeSemantics: true,
            child: child,
          ),
        );
      },
    );
  }
}

class DayPill extends StatelessWidget {
  const DayPill({super.key, required this.label, this.floating = false});

  final String label;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: floating ? c.bgSecondary : c.glassBg,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        border: Border.all(color: c.glassBorder),
        boxShadow: floating
            ? const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 10,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          color: c.textDim,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
    );
  }
}

class DayFloatState {
  const DayFloatState({this.createdAt, this.visible = false});

  final int? createdAt;
  final bool visible;
}

class DayFloatCover {
  final Set<Element> _at = {};

  void track(BuildContext context) => _at.add(context as Element);

  (double, double)? measure(GlobalKey host, {double inset = 0}) {
    _at.removeWhere((e) => !e.mounted);
    final h = host.currentContext?.findRenderObject();
    if (h is! RenderBox || !h.attached) return null;
    for (final e in _at) {
      final c = e.findRenderObject();
      if (c is! RenderBox || !c.attached || !c.hasSize) continue;
      final top = c.localToGlobal(Offset.zero, ancestor: h).dy;
      return (top + inset, top + c.size.height - inset);
    }
    return null;
  }
}

class DayFloatController extends ValueNotifier<DayFloatState> {
  DayFloatController() : super(const DayFloatState());

  bool _scrolling = false;
  bool _recent = false;
  Timer? _idle;
  String? _key;
  int? _at;
  bool _inline = false;
  bool _atBottom = true;
  (double, double)? _cover;

  void observe(ScrollNotification n) {
    final user =
        (n is ScrollStartNotification && n.dragDetails != null) ||
        (n is ScrollUpdateNotification && n.dragDetails != null) ||
        (n is UserScrollNotification && n.direction != ScrollDirection.idle);
    if (user) {
      _scrolling ? scrolled() : scrollStarted();
    } else if (_scrolling &&
        (n is ScrollEndNotification ||
            (n is UserScrollNotification &&
                n.direction == ScrollDirection.idle))) {
      scrollEnded();
    }
  }

  void scrollStarted() {
    _scrolling = true;
    _idle?.cancel();
    _idle = null;
    _recent = true;
    _apply();
  }

  void scrolled() {
    _scrolling = true;
    _recent = true;
    _apply();
  }

  void scrollEnded() {
    _scrolling = false;
    _recent = true;
    _apply();
    _idle?.cancel();
    _idle = Timer(const Duration(milliseconds: DayLabels.floatIdleMs), () {
      _idle = null;
      _recent = false;
      _apply();
    });
  }

  void update({
    required int? topCreatedAt,
    required bool inlineVisible,
    required bool atBottom,
    (double, double)? cover,
  }) {
    _cover = cover;
    _at = topCreatedAt;
    _key = topCreatedAt == null ? null : DayClock.instance.keyOf(topCreatedAt);
    _inline = inlineVisible;
    _atBottom = atBottom;
    _apply();
  }

  void _apply() {
    final idle = _recent ? 0 : DayLabels.floatIdleMs;
    final show = dayFloatVisible(
      key: _key,
      inlineKey: _inline ? _key : null,
      inlineTop: _inline ? 0 : null,
      viewTop: 0,
      atBottom: _atBottom,
      scrolling: _scrolling,
      idleMs: idle,
      coverTop: _cover?.$1,
      coverBottom: _cover?.$2,
    );
    final next = DayFloatState(createdAt: _at, visible: show);
    if (next.visible != value.visible || next.createdAt != value.createdAt) {
      value = next;
    }
  }

  @override
  void dispose() {
    _idle?.cancel();
    super.dispose();
  }
}

class DayFloatLabel extends StatelessWidget {
  const DayFloatLabel({super.key, required this.controller});

  final DayFloatController controller;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      child: ValueListenableBuilder<DayFloatState>(
        valueListenable: controller,
        builder: (context, s, _) {
          final at = s.createdAt;
          return ExcludeSemantics(
            child: AnimatedOpacity(
              key: const ValueKey('day-float'),
              opacity: s.visible && at != null ? 1 : 0,
              duration: still
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              child: at == null
                  ? const SizedBox.shrink()
                  : ListenableBuilder(
                      listenable: DayClock.instance,
                      builder: (context, _) => DayPill(
                        key: ValueKey(
                          'day-float-${DayClock.instance.keyOf(at)}-${s.visible}',
                        ),
                        label: DayClock.instance.labelOf(at),
                        floating: true,
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }
}

List<List<T>> splitGroupsByDay<T>(
  List<List<T>> groups,
  int Function(T item) createdAt,
) {
  final clock = DayClock.instance;
  final out = <List<T>>[];
  for (final g in groups) {
    var run = <T>[];
    String? day;
    for (final item in g) {
      final k = clock.keyOf(createdAt(item));
      if (run.isNotEmpty && k != day) {
        out.add(run);
        run = <T>[];
      }
      run.add(item);
      day = k;
    }
    if (run.isNotEmpty) out.add(run);
  }
  return out;
}

Set<int> dayStartIndexes<T>(
  List<List<T>> groups,
  int Function(T item) createdAt,
) {
  final clock = DayClock.instance;
  final out = <int>{};
  String? last;
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i];
    if (g.isEmpty) continue;
    if (clock.keyOf(createdAt(g.first)) != last) out.add(i);
    last = clock.keyOf(createdAt(g.last));
  }
  return out;
}
