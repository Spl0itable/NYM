import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/storage_keys.dart';
import '../features/i18n/i18n.dart';
import '../features/toasts/toast_center.dart';
import '../features/toasts/toast_model.dart';
import '../services/storage/key_value_store.dart';
import 'settings_provider.dart';

const String kFallbackNoticeText =
    'Direct relay connections: the proxy was unreachable, so relays can see your IP address. The app will switch back when it recovers.';
const String kFallbackNoticeLabel = 'Direct Connection Notice';
const String kFallbackNoticeHint =
    'Tell me when Nymchat falls back to direct relay connections because the proxy is unreachable. Relays can see your IP address in direct mode.';

class FallbackNoticeController extends StateNotifier<bool> {
  FallbackNoticeController(this._kv)
      : super(!_kv.getBool(StorageKeys.relayFallbackNoticeOff));

  final KeyValueStore _kv;

  Future<void> setEnabled(bool on) async {
    state = on;
    if (on) {
      await _kv.remove(StorageKeys.relayFallbackNoticeOff);
    } else {
      await _kv.setBool(StorageKeys.relayFallbackNoticeOff, true);
    }
  }

  void show() {
    if (!state) return;
    ToastCenter.instance.show(
      tr(kFallbackNoticeText),
      kind: ToastKind.info,
      action: tr("Don't show again"),
      onAction: () => unawaited(setEnabled(false)),
    );
  }
}

final StateNotifierProvider<FallbackNoticeController, bool>
    fallbackNoticeProvider =
    StateNotifierProvider<FallbackNoticeController, bool>(
        (ref) => FallbackNoticeController(ref.read(keyValueStoreProvider)));
