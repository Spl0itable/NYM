import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'chat_lock.dart';

String chatLockPlatform() {
  if (kIsWeb) return 'web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    default:
      return 'desktop';
  }
}

class ScreenPrivacy {
  ScreenPrivacy._();

  static const channel = MethodChannel('app.nymchat/privacy');

  static bool _setting = false;
  static int _holds = 0;
  static bool? _sent;
  static bool _bound = false;

  static final ValueNotifier<bool> wanted = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> captured = ValueNotifier<bool>(false);

  static bool get setting => _setting;
  static int get holds => _holds;

  static bool get _native {
    final p = chatLockPlatform();
    return p == 'android' || p == 'ios';
  }

  static Future<void> setEnabled(bool on) async {
    _setting = on;
    await _sync();
  }

  static Future<void> hold() async {
    _holds++;
    await _sync();
  }

  static Future<void> release() async {
    if (_holds == 0) return;
    _holds--;
    await _sync();
  }

  static Future<void> _sync() async {
    final want = obscureWanted(setting: _setting, lockedOpen: _holds > 0);
    wanted.value = want;
    if (!_native || _sent == want) return;
    _sent = want;
    try {
      await channel.invokeMethod<void>('configure', {'secure': want});
    } catch (_) {}
  }

  static void bindNative() {
    if (_bound || !_native) return;
    _bound = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'captured') captured.value = call.arguments == true;
      return null;
    });
    unawaited(() async {
      try {
        final v = await channel.invokeMethod<bool>('isCaptured');
        captured.value = v == true;
      } catch (_) {}
    }());
  }

  @visibleForTesting
  static void resetForTest() {
    _setting = false;
    _holds = 0;
    _sent = null;
    _bound = false;
    wanted.value = false;
    captured.value = false;
  }
}

class ScreenPrivacyHold extends StatefulWidget {
  const ScreenPrivacyHold({super.key, this.child = const SizedBox.shrink()});

  final Widget child;

  @override
  State<ScreenPrivacyHold> createState() => _ScreenPrivacyHoldState();
}

class _ScreenPrivacyHoldState extends State<ScreenPrivacyHold> {
  @override
  void initState() {
    super.initState();
    unawaited(ScreenPrivacy.hold());
  }

  @override
  void dispose() {
    unawaited(ScreenPrivacy.release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
