import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../state/settings_provider.dart';

final streetDetailProvider =
    StateNotifierProvider<StreetDetailNotifier, bool>(
        (ref) => StreetDetailNotifier(ref));

class StreetDetailNotifier extends StateNotifier<bool> {
  StreetDetailNotifier(this._ref) : super(readStreetDetail(_ref));

  final Ref _ref;

  static bool readStreetDetail(Ref ref) {
    try {
      return ref.read(keyValueStoreProvider).getString(StorageKeys.streetDetail) !=
          '0';
    } catch (_) {
      return true;
    }
  }

  @override
  bool updateShouldNotify(bool old, bool current) => true;

  void set(bool on, {bool fromSync = false}) {
    try {
      unawaited(_ref
          .read(keyValueStoreProvider)
          .setString(StorageKeys.streetDetail, on ? '1' : '0'));
    } catch (_) {}
    if (mounted) state = on;
    if (fromSync) return;
    try {
      _ref.read(settingsProvider.notifier).notePrefChanged('streetDetail');
    } catch (_) {}
  }
}
