import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../calls/call_providers.dart';
import '../calls/call_signaling.dart' show CallPhase;
import '../notifications/notification_route_target.dart';
import '../notifications/notification_routing.dart';
import '../notifications/notifications_panel.dart';
import 'event_toast_center.dart';
import 'event_toast_settings_store.dart';
import 'event_toasts.dart';
import 'toast_center.dart';

PointerRoute? _pointerHook;
KeyEventCallback? _keyHook;

void installEventToasts(
  ProviderContainer c,
  BuildContext? Function() context, {
  EventToastCenter? center,
}) {
  final et = center ?? EventToastCenter.instance;
  ToastCenter.holdGate = et.holdOtherToasts;
  final prevPointer = _pointerHook;
  if (prevPointer != null) {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(prevPointer);
  }
  void onPointer(PointerEvent e) {
    if (e is PointerDownEvent) EventToastCenter.instance.noteUserAction();
  }

  _pointerHook = onPointer;
  GestureBinding.instance.pointerRouter.addGlobalRoute(onPointer);
  final prevKey = _keyHook;
  if (prevKey != null) HardwareKeyboard.instance.removeHandler(prevKey);
  bool onKey(KeyEvent e) {
    if (e is KeyDownEvent) EventToastCenter.instance.noteUserAction();
    return false;
  }

  _keyHook = onKey;
  HardwareKeyboard.instance.addHandler(onKey);
  et.viewOf = () {
    final ctl = c.read(nostrControllerProvider);
    var call = false;
    try {
      call = c.read(callServiceProvider).state.value.phase != CallPhase.idle;
    } catch (_) {}
    return EventToastView(
      foreground: ctl.appInForeground,
      call: call,
      identity: ctl.eventToastIdentity,
    );
  };
  et.seesOf = (t) {
    final ctl = c.read(nostrControllerProvider);
    ctl.toastColumnKeys = et.columnKeys;
    return ctl.toastSees(t.type, t.route, t.threadRoot);
  };
  et.settingsOf = () => readEventToastSettings(c.read(keyValueStoreProvider));
  et.prefsOf = () =>
      EventToastPrefs(hidePreviews: c.read(settingsProvider).hidePreviews);
  et.stillUnread = (token) {
    final id = et.targetOf(token)?.eventId ?? '';
    if (id.isEmpty) return true;
    for (final e in c.read(notificationHistoryProvider).entries) {
      if (e.eventId == id) return !e.viewed;
    }
    return true;
  };
  et.onOpen = (target, all) {
    final ids = {
      for (final t in all)
        if (t.eventId.isNotEmpty) t.eventId,
    };
    final entries = [
      for (final e in c.read(notificationHistoryProvider).entries)
        if (ids.contains(e.eventId) && !e.viewed) e,
    ];
    if (entries.isNotEmpty) {
      c.read(notificationHistoryProvider.notifier).markEntriesViewed(entries);
    }
    openNotificationRoute(
      NotificationRoute(
        type: target.type,
        route: target.route,
        senderPubkey: target.senderPubkey,
        threadRoot: target.threadRoot,
      ),
      AppNotificationRouteTarget(
        controller: c.read(nostrControllerProvider),
        appState: c.read(appStateProvider.notifier),
        container: c,
      ),
    );
  };
  et.onOpenPanel = () {
    final ctx = context();
    if (ctx != null && ctx.mounted) showNotificationsPanel(ctx);
  };
}
