import 'dart:async';

import 'package:flutter/foundation.dart';

import '../i18n/i18n.dart';
import '../i18n/localization_service.dart';
import 'toast_model.dart';

class ToastCenter extends ChangeNotifier {
  ToastCenter({int Function()? now})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  static ToastCenter instance = ToastCenter();

  final int Function() _now;
  ToastQueue _queue = const ToastQueue();
  Timer? _timer;
  int _hosts = 0;

  List<ToastItem> get visible => _queue.toasts;

  final Map<int, VoidCallback> _actions = {};

  static bool Function()? holdGate;

  final List<({String text, ToastKind? kind, String? action, VoidCallback? onAction, int at})> _held = [];

  bool get hasHeld => _held.isNotEmpty;

  void releaseHeld() {
    if (_held.isEmpty) return;
    if (holdGate?.call() ?? false) return;
    final held = List.of(_held);
    _held.clear();
    final now = _now();
    for (final h in held) {
      final undo = h.action != null && h.onAction != null;
      if (!undo) {
        final k = h.kind ??
            classifyToast(LocalizationService.instance.sourceOf(h.text));
        if (now - h.at > toastDurationMs(h.text, k)) continue;
      }
      _show(h.text, kind: h.kind, action: h.action, onAction: h.onAction);
    }
  }

  int? show(String text,
      {ToastKind? kind, String? action, VoidCallback? onAction}) {
    if (text.trim().isEmpty) return null;
    if (holdGate?.call() ?? false) {
      _held.add((
        text: text,
        kind: kind,
        action: action,
        onAction: onAction,
        at: _now(),
      ));
      return null;
    }
    return _show(text, kind: kind, action: action, onAction: onAction);
  }

  int? _show(String text,
      {ToastKind? kind, String? action, VoidCallback? onAction}) {
    final source = LocalizationService.instance.sourceOf(text);
    final label = onAction == null ? null : action;
    final r = pushToast(_queue, text, kind ?? classifyToast(source), _now(),
        action: label);
    _queue = r.queue;
    for (final id in r.evicted) {
      _actions.remove(id);
    }
    final id = r.id;
    if (!r.deduped && id != null && label != null && onAction != null) {
      _actions[id] = onAction;
    }
    _arm();
    notifyListeners();
    return r.id;
  }

  void runAction(int id) {
    final fn = _actions.remove(id);
    dismiss(id);
    fn?.call();
  }

  void dismiss(int id) {
    _actions.remove(id);
    _queue = dismissToastIn(_queue, id);
    _arm();
    notifyListeners();
  }

  void pause(int id) {
    _queue = pauseToastIn(_queue, id, _now());
    _arm();
    notifyListeners();
  }

  void resume(int id) {
    _queue = resumeToastIn(_queue, id, _now());
    _arm();
    notifyListeners();
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
    _queue = const ToastQueue();
    _actions.clear();
    _held.clear();
    notifyListeners();
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (_hosts == 0) return;
    final next = _queue.nextExpiry;
    if (next == null) return;
    final wait = next - _now();
    _timer = Timer(Duration(milliseconds: (wait > 0 ? wait : 0) + 5), _tick);
  }

  void _tick() {
    _timer = null;
    final r = expireToasts(_queue, _now());
    _queue = r.queue;
    for (final id in r.expired) {
      _actions.remove(id);
    }
    _arm();
    if (r.expired.isNotEmpty) notifyListeners();
  }
}

int? showToast(String text, {ToastKind? kind}) =>
    ToastCenter.instance.show(text, kind: kind);

int? showUndoToast(String text, VoidCallback onUndo) => ToastCenter.instance
    .show(text, kind: ToastKind.info, action: tr('Undo'), onAction: onUndo);
