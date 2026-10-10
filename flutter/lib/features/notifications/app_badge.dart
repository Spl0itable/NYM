import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/notification_service.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';

int appBadgeCount({required bool notificationsEnabled, required int bellUnread}) =>
    notificationsEnabled && bellUnread > 0 ? bellUnread : 0;

final appBadgeCountProvider = Provider<int>((ref) => appBadgeCount(
      notificationsEnabled:
          ref.watch(settingsProvider.select((s) => s.notificationsEnabled)),
      bellUnread:
          ref.watch(notificationHistoryProvider.select((s) => s.unread)),
    ));

abstract class AppBadgePlatform {
  Future<void> setCount(int count);

  Future<void> clearRead(Set<String> keys);
}

class SystemAppBadge implements AppBadgePlatform {
  const SystemAppBadge();

  static const MethodChannel _channel = MethodChannel('app.nymchat/badge');

  @override
  Future<void> setCount(int count) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<bool>('set', {'count': count});
    } catch (_) {}
  }

  @override
  Future<void> clearRead(Set<String> keys) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await NotificationService().cancelReadConversations(keys);
    } catch (_) {}
  }
}

ProviderSubscription<int> installAppBadge(
  ProviderContainer c, {
  AppBadgePlatform platform = const SystemAppBadge(),
}) {
  int? shown;
  void push(int count) {
    if (count == shown) return;
    final before = shown;
    shown = count;
    unawaited(platform.setCount(count));
    if (before == null || count < before) {
      Set<String> keys = const {};
      try {
        keys = c.read(notificationHistoryProvider.notifier).unreadConversationKeys();
      } catch (_) {}
      unawaited(platform.clearRead(count > 0 ? keys : const {}));
    }
  }

  return c.listen<int>(appBadgeCountProvider, (_, next) => push(next),
      fireImmediately: true);
}
