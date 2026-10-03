import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../models/channel.dart' show kDefaultChannel;
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../chat_tools/chat_tools_providers.dart';
import '../i18n/i18n.dart';
import '../identity/vault_settings_modal.dart' show identityVaultProvider;
import '../toasts/toast_center.dart';
import 'chat_lock.dart';
import 'chat_lock_service.dart';
import 'screen_privacy.dart';

class LocalAuthChatLockAuthenticator implements ChatLockAuthenticator {
  LocalAuthChatLockAuthenticator([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> deviceAvailable() async {
    final p = chatLockPlatform();
    if (p != 'android' && p != 'ios') return false;
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool?> deviceAuth(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException catch (e) {
      if (e.code == LocalAuthExceptionCode.userCanceled ||
          e.code == LocalAuthExceptionCode.systemCanceled) {
        return null;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}

final chatLockRevisionProvider = StateProvider<int>((ref) => 0);

final chatLockAuthenticatorProvider = Provider<ChatLockAuthenticator>(
    (ref) => LocalAuthChatLockAuthenticator());

final chatLockProvider = Provider<ChatLockService>((ref) {
  final kv = ref.watch(keyValueStoreProvider);
  var bump = false;
  late final ChatLockService service;
  void redactHistory() {
    try {
      final r = service.redact('', '', true);
      ref.read(notificationHistoryProvider.notifier).redactWhere(
          (e) => service.notificationIsLocked(e.type, e.route, e.senderPubkey),
          r.title,
          r.body);
    } catch (_) {}
    try {
      ref.read(notificationHistoryProvider.notifier).recountUnread();
    } catch (_) {}
  }

  service = ChatLockService(
    KeyValueChatToolsPrefs(kv),
    ChatLockHooks(
      selfPubkey: () => ref.read(appStateProvider).selfPubkey,
      online: () => ref.read(appStateProvider).connectedRelays > 0,
      hydrated: () => ref.read(nostrControllerProvider).savesHydrated,
      syncAllowed: () => ref.read(nostrControllerProvider).savedSyncAllowed,
      publishLocked: (p) =>
          ref.read(nostrControllerProvider).publishLockedChats(p),
      vaultMethod: () {
        try {
          final v = ref.read(identityVaultProvider);
          return v.isEnabled ? v.method : '';
        } catch (_) {
          return '';
        }
      },
      verifyVaultPassword: (pw) =>
          ref.read(identityVaultProvider).verifyPassword(pw),
      currentKey: () => ref.read(appStateProvider).view.storageKey,
      onRelock: () {
        try {
          final cur = ref.read(appStateProvider).view.storageKey;
          if (service.blocks(cur)) {
            ref
                .read(appStateProvider.notifier)
                .switchView(const ChatView.channel(kDefaultChannel));
          }
        } catch (_) {}
      },
      notice: (text) {
        try {
          showToast(text);
        } catch (_) {}
      },
      onChanged: () {
        if (bump) return;
        bump = true;
        Future.microtask(() {
          bump = false;
          try {
            ref.read(chatLockRevisionProvider.notifier).state++;
          } catch (_) {}
          redactHistory();
          unawaited(ScreenPrivacy.setEnabled(service.screenSecurity));
        });
      },
    ),
    authenticator: ref.watch(chatLockAuthenticatorProvider),
    tr: (s) => tr(s),
  );
  NotificationHistoryNotifier.lockedEntry =
      (e) => service.notificationIsLocked(e.type, e.route, e.senderPubkey);
  ref.onDispose(() => NotificationHistoryNotifier.lockedEntry = null);
  return service;
});

void installChatLockGate(AppStateNotifier notifier, ChatLockService service) {
  notifier.viewGate = (from, to) => service.beforeOpen(
      from.storageKey, to.storageKey, () => notifier.switchView(to));
  unawaited(ScreenPrivacy.setEnabled(service.screenSecurity));
}

final incognitoKeyboardProvider = Provider<bool>((ref) {
  ref.watch(chatLockRevisionProvider);
  return ref.read(chatLockProvider).incognitoKeyboard;
});

final incognitoFieldFlagsProvider =
    Provider<({bool imeLearning, bool autocorrect, bool suggestions})>((ref) {
  return textFieldFlags(ref.watch(incognitoKeyboardProvider), chatLockPlatform());
});

final lockedConversationOpenProvider = Provider<bool>((ref) {
  ref.watch(chatLockRevisionProvider);
  final view = ref.watch(currentViewProvider);
  final service = ref.read(chatLockProvider);
  return service.isConversationLocked(view.storageKey) || service.revealed;
});

List<({String key, Object? n})> chatLockUnreadEntries(Map<String, int> unread) {
  final best = <String, int>{};
  unread.forEach((k, v) {
    final key = _unreadChatKey(k);
    final cur = best[key] ?? 0;
    if (v > cur) best[key] = v;
  });
  return [for (final e in best.entries) (key: e.key, n: e.value)];
}

String _unreadChatKey(String k) {
  if (k.startsWith('pm-') || k.startsWith('group-')) return k;
  if (k.startsWith('#')) return k.toLowerCase();
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(k)) return 'pm-${k.toLowerCase()}';
  return '#${k.toLowerCase()}';
}

final chatLockBadgesProvider = Provider<ChatLockBadges>((ref) {
  ref.watch(chatLockRevisionProvider);
  final unread = ref.watch(unreadCountsProvider);
  return ref.read(chatLockProvider).badgesFor(chatLockUnreadEntries(unread));
});
