import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class SecretScreen {
  SecretScreen._();

  static const channel = MethodChannel('app.nymchat/secure');
  static const clipboardLife = Duration(seconds: 60);

  static int _holds = 0;
  static Timer? _wipe;

  static bool get held => _holds > 0;

  static Future<void> hold() async {
    if (_holds++ == 0) await _set(true);
  }

  static Future<void> release() async {
    if (_holds == 0) return;
    if (--_holds == 0) await _set(false);
  }

  static Future<void> _set(bool on) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await channel.invokeMethod<void>('secure', on);
    } catch (_) {}
  }

  static Future<void> copy(String value,
      {Duration life = clipboardLife}) async {
    await Clipboard.setData(ClipboardData(text: value));
    _wipe?.cancel();
    _wipe = Timer(life, () => unawaited(forget(value)));
  }

  static Future<void> forget(String value) async {
    try {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == value) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {}
  }
}

class SecretGuard extends StatefulWidget {
  const SecretGuard({super.key, this.child = const SizedBox.shrink()});

  final Widget child;

  @override
  State<SecretGuard> createState() => _SecretGuardState();
}

class _SecretGuardState extends State<SecretGuard> {
  @override
  void initState() {
    super.initState();
    unawaited(SecretScreen.hold());
  }

  @override
  void dispose() {
    unawaited(SecretScreen.release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
