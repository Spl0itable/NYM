import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';

const int kConnNoticeGraceMs = 2000;

class ComposerConnStrings {
  const ComposerConnStrings._();

  static const String connecting =
      'Connecting… messages will send when connected';
  static const String offline =
      'Offline – messages will send when you reconnect';
  static const String mesh = 'Offline – sending over the Bluetooth mesh';
  static const String queued = 'Waiting to send';

  static Map<String, String> toJson() => {
        'connecting': connecting,
        'offline': offline,
        'mesh': mesh,
      };

  static String forState(String state) => toJson()[state] ?? '';
}

String composerConnState({
  required bool relayOpen,
  required bool meshCarries,
  required bool deviceOffline,
  required bool connectFailed,
}) {
  if (relayOpen) return '';
  if (meshCarries) return 'mesh';
  if (deviceOffline || connectFailed) return 'offline';
  return 'connecting';
}

bool composerConnectFailedFor({
  required bool everConnected,
  required bool statusFailed,
}) =>
    everConnected || statusFailed;

class ConnNoticeGrace {
  ConnNoticeGrace({this.graceMs = kConnNoticeGraceMs});

  final int graceMs;
  int? _since;
  bool _armed = false;

  bool get armed => _armed;

  int? get due => _since == null || _armed ? null : _since! + graceMs;

  void restart() {
    _since = null;
    _armed = false;
  }

  void arm() {
    if (_since != null) _armed = true;
  }

  String step(int t, String state, {bool restart = false}) {
    if (restart) this.restart();
    if (state.isEmpty) {
      this.restart();
      return '';
    }
    final since = _since ??= t;
    if (t - since >= graceMs) _armed = true;
    return _armed ? state : '';
  }
}

class ConnNoticeGate extends StateNotifier<int> with WidgetsBindingObserver {
  ConnNoticeGate(this._now) : super(0) {
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {}
  }

  final int Function() _now;
  final ConnNoticeGrace grace = ConnNoticeGrace();
  bool _observing = false;
  bool _away = false;
  bool _open = true;
  bool _everConnected = false;

  bool get everConnected => _everConnected;

  void noteRelays(bool open) {
    if (open) _everConnected = true;
  }

  int now() => _now();

  String show(String state) => grace.step(_now(), state);

  void track(bool open) {
    _open = open;
    grace.step(_now(), open ? '' : ComposerConnStrings.connecting);
  }

  void elapse(int due) {
    if (grace.due != due) return;
    grace.arm();
    state = state + 1;
  }

  void restart() {
    grace.step(_now(), _open ? '' : ComposerConnStrings.connecting,
        restart: true);
    state = state + 1;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _away = true;
    } else if ((state == AppLifecycleState.inactive ||
            state == AppLifecycleState.resumed) &&
        _away) {
      _away = false;
      restart();
    }
  }

  @override
  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final Provider<int Function()> connNoticeClockProvider =
    Provider<int Function()>((ref) {
  final watch = Stopwatch()..start();
  return () => watch.elapsedMilliseconds;
});

final StateNotifierProvider<ConnNoticeGate, int> connNoticeGateProvider =
    StateNotifierProvider<ConnNoticeGate, int>((ref) {
  final gate = ConnNoticeGate(ref.watch(connNoticeClockProvider));
  ref.listen<bool>(
      appStateProvider
          .select((s) => s.selfPubkey.isEmpty || s.relayLinked),
      (_, open) => gate.track(open),
      fireImmediately: true);
  ref.listen<bool>(appStateProvider.select((s) => s.relayLinked),
      (_, open) => gate.noteRelays(open),
      fireImmediately: true);
  return gate;
});

class ConnNoticeTimer {
  Timer? _timer;
  int? _due;

  void wait(ConnNoticeGate gate, bool Function() alive) {
    final due = gate.grace.due;
    if (due == _due && (_timer?.isActive ?? false)) return;
    cancel();
    _due = due;
    if (due == null) return;
    final left = due - gate.now();
    _timer = Timer(Duration(milliseconds: left < 0 ? 0 : left), () {
      _timer = null;
      if (alive()) gate.elapse(due);
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _due = null;
  }
}
