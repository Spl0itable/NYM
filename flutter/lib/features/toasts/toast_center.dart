import 'dart:async';

import 'package:flutter/foundation.dart';

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

  int? show(String text, {ToastKind? kind}) {
    if (text.trim().isEmpty) return null;
    final source = LocalizationService.instance.sourceOf(text);
    final r = pushToast(_queue, text, kind ?? classifyToast(source), _now());
    _queue = r.queue;
    _arm();
    notifyListeners();
    return r.id;
  }

  void dismiss(int id) {
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
    _arm();
    if (r.expired.isNotEmpty) notifyListeners();
  }
}

int? showToast(String text, {ToastKind? kind}) =>
    ToastCenter.instance.show(text, kind: kind);
