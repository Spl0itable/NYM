import 'dart:async';

import 'package:flutter/widgets.dart';

import '../i18n/i18n.dart';
import 'event_toasts.dart';
import 'toast_center.dart';

class EventToastTarget {
  const EventToastTarget({
    required this.type,
    this.route = '',
    this.senderPubkey = '',
    this.threadRoot = '',
    this.eventId = '',
  });

  final String type;
  final String route;
  final String senderPubkey;
  final String threadRoot;
  final String eventId;
}

class EventToastRouteObserver extends NavigatorObserver {
  EventToastRouteObserver(this._changed, this._clock);

  final VoidCallback _changed;
  final int Function() _clock;
  final List<Route<dynamic>> _popups = [];
  int openedAt = 0;

  bool get anyOpen => _popups.isNotEmpty;

  Route<dynamic>? get top => _popups.isEmpty ? null : _popups.last;

  void _add(Route<dynamic>? r) {
    if (r is PopupRoute && !_popups.contains(r)) {
      _popups.add(r);
      openedAt = _clock();
      _changed();
    }
  }

  void _drop(Route<dynamic>? r) {
    if (r != null && _popups.remove(r)) _changed();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _drop(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _drop(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _drop(oldRoute);
    _add(newRoute);
  }
}

String eventToastTr(String s, [Map<String, Object?>? p]) =>
    EventToasts.fill(tr(s), p);

class EventToastCenter extends ChangeNotifier {
  EventToastCenter({int Function()? now})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    observer = EventToastRouteObserver(_onRoutes, _now);
  }

  static EventToastCenter instance = EventToastCenter();

  final int Function() _now;
  late final EventToastRouteObserver observer;

  EventToastState _state = const EventToastState();
  List<EventToastEvent> _held = [];
  final Map<String, EventToastTarget> _targets = {};
  int _seq = 0;
  int _backlogAt = 0;
  int _backlogFirst = 0;
  Timer? _timer;
  Timer? _flushTimer;
  int _hosts = 0;

  EventToastView Function()? viewOf;
  EventToastSettings Function()? settingsOf;
  EventToastPrefs Function()? prefsOf;
  bool Function(String token)? stillUnread;
  bool Function(EventToastTarget target)? seesOf;
  List<String> Function()? columnKeys;
  void Function(EventToastTarget target, List<EventToastTarget> all)? onOpen;
  VoidCallback? onOpenPanel;

  List<EventToast> get visible => _state.toasts;
  bool get hasHeld => _held.isNotEmpty;

  EventToastText textFor(EventToast t) => EventToasts.present(
      t, prefsOf?.call() ?? const EventToastPrefs(), eventToastTr);

  EventToastView currentView() {
    final v = viewOf?.call() ?? const EventToastView();
    return EventToastView(
      foreground: v.foreground,
      call: v.call,
      sheet: v.sheet || observer.anyOpen,
      identity: v.identity,
    );
  }

  EventToastSettings get settings =>
      settingsOf?.call() ?? EventToasts.defaults;

  String register(EventToastTarget target) {
    _seq++;
    final token = 'et$_seq';
    _targets[token] = target;
    return token;
  }

  EventToastDecision consider(EventToastEvent ev) {
    final d = EventToasts.decide(ev, currentView(), settings);
    if (d.toast == 'show') {
      _apply(EventToasts.add(_state, ev, _now()));
    } else if (d.toast == 'hold') {
      _hold(ev);
    } else {
      _targets.remove(ev.eventId);
    }
    return d;
  }

  final Map<String, int> _heldAt = {};

  void _hold(EventToastEvent ev) {
    _held = [..._held, ev];
    _heldAt[ev.eventId] = _now();
    if (ev.backlog) {
      if (_backlogFirst == 0) _backlogFirst = _now();
      _backlogAt = _now();
    }
    _flushTimer ??= Timer.periodic(
        const Duration(milliseconds: 500), (_) => tryFlush());
  }

  int lastActAt = 0;

  void noteUserAction() => lastActAt = _now();

  bool holdOtherToasts() {
    if (!observer.anyOpen) return false;
    final act = lastActAt;
    return !(act >= observer.openedAt && _now() - act < 1500);
  }

  Rect? dialogRect() {
    final route = observer.top;
    if (route is! ModalRoute) return null;
    final ro = route.subtreeContext?.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    final full = ro.size;
    RenderBox? found;
    var level = <RenderObject>[ro];
    for (var depth = 0; depth < 40 && found == null && level.isNotEmpty; depth++) {
      final next = <RenderObject>[];
      for (final o in level) {
        if (found != null) break;
        if (o is RenderBox &&
            o.hasSize &&
            o.size.width > 40 &&
            o.size.height > 40 &&
            (o.size.width < full.width - 1 || o.size.height < full.height - 1)) {
          found = o;
          break;
        }
        o.visitChildren(next.add);
      }
      level = next;
    }
    final box = found;
    if (box == null || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _onRoutes() {
    scheduleMicrotask(() {
      ToastCenter.instance.releaseHeld();
      if (_held.isNotEmpty) tryFlush();
      notifyListeners();
    });
  }

  void tryFlush() {
    if (_held.isEmpty) {
      _flushTimer?.cancel();
      _flushTimer = null;
      return;
    }
    final view = currentView();
    if (!view.foreground || view.call || view.sheet) return;
    if (_held.any((e) => e.backlog) &&
        _now() - _backlogAt < EventToastConfig.backlogQuietMs &&
        _now() - _backlogFirst < EventToastConfig.backlogMaxMs) {
      return;
    }
    final held = _held;
    _held = [];
    _backlogFirst = 0;
    _flushTimer?.cancel();
    _flushTimer = null;
    final s = settings;
    final calm =
        EventToastView(foreground: true, identity: view.identity);
    final now = _now();
    final fresh = [
      for (final e in held)
        if (_targets.containsKey(e.eventId) &&
            (e.backlog ||
                now - (_heldAt[e.eventId] ?? now) <=
                    EventToastConfig.durationMs) &&
            (stillUnread?.call(e.eventId) ?? true) &&
            EventToasts.decide(e.asLive(seen: sees(_targets[e.eventId]!)),
                        calm, s)
                    .toast ==
                'show')
          e,
    ];
    for (final e in held) {
      _heldAt.remove(e.eventId);
      if (!fresh.contains(e)) _targets.remove(e.eventId);
    }
    if (fresh.isNotEmpty) _apply(EventToasts.addMany(_state, fresh, _now()));
  }

  EventToastTarget? targetOf(String token) => _targets[token];

  bool sees(EventToastTarget target) => seesOf?.call(target) ?? false;

  void _apply(EventToastResult r) {
    _state = r.state;
    _prune();
    _arm();
    notifyListeners();
  }

  void dismiss(int id) {
    _state = EventToasts.dismiss(_state, id);
    _arm();
    notifyListeners();
  }

  void pause(int id) {
    _state = EventToasts.pause(_state, id, _now());
    _arm();
    notifyListeners();
  }

  void resume(int id) {
    _state = EventToasts.resume(_state, id, _now());
    _arm();
    notifyListeners();
  }

  void open(int id) {
    EventToast? t;
    for (final x in _state.toasts) {
      if (x.id == id) t = x;
    }
    if (t == null) return;
    dismiss(id);
    if (t.isSummary) {
      onOpenPanel?.call();
      return;
    }
    final all = [
      for (final tok in t.events)
        if (_targets[tok] != null) _targets[tok]!,
    ];
    if (all.isEmpty) return;
    onOpen?.call(all.last, all);
  }

  void attach() {
    _hosts++;
    _arm();
  }

  void detach() {
    if (_hosts > 0) _hosts--;
    _arm();
  }

  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _state = const EventToastState();
    _held = [];
    _backlogFirst = 0;
    _heldAt.clear();
    lastActAt = 0;
    _targets.clear();
    notifyListeners();
  }

  void _prune() {
    if (_targets.length < 200) return;
    final keep = <String>{
      for (final t in _state.toasts) ...t.events,
      for (final e in _held) e.eventId,
    };
    _targets.removeWhere((k, _) => !keep.contains(k));
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (_hosts == 0) return;
    final next = EventToasts.nextExpiry(_state);
    if (next == null) return;
    final wait = next - _now();
    _timer = Timer(Duration(milliseconds: (wait > 0 ? wait : 0) + 5), _tick);
  }

  void _tick() {
    _timer = null;
    final r = EventToasts.expire(_state, _now());
    _state = r.state;
    _arm();
    if (r.removed.isNotEmpty) notifyListeners();
  }
}
