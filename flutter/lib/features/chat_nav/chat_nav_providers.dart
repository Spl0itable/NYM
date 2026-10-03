import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../chat_tools/chat_tools_providers.dart';
import '../group_tools/group_tools_providers.dart';
import '../i18n/i18n.dart';
import '../notifications/self_reference.dart';
import 'chat_nav_service.dart';

String chatNavAlias(String key) {
  if (key.startsWith('pm-')) return key.substring(3);
  if (key.startsWith('group-')) return key.substring(6);
  if (key.startsWith('#')) return key.substring(1);
  return key;
}

bool chatNavMentions(Ref ref, Message m) {
  if (m.isOwn) return false;
  if (m.isGroup && ref.read(groupToolsProvider).mentionsAll(m)) return true;
  return contentMentionsSelf(
    content: m.content,
    nym: ref.read(appStateProvider).selfNym,
    pubkey: ref.read(nostrControllerProvider).identity?.pubkey,
  );
}

final chatNavRevisionProvider = StateProvider<int>((ref) => 0);

final chatNavProvider = Provider<ChatNavService>((ref) {
  final kv = ref.watch(keyValueStoreProvider);
  var bump = false;
  final service = ChatNavService(
    KeyValueChatToolsPrefs(kv),
    ChatNavHooks(
      selfPubkey: () => ref.read(appStateProvider).selfPubkey,
      online: () => ref.read(appStateProvider).connectedRelays > 0,
      hydrated: () => ref.read(nostrControllerProvider).savesHydrated,
      syncAllowed: () => ref.read(nostrControllerProvider).savedSyncAllowed,
      publishPinned: (p) =>
          ref.read(nostrControllerProvider).publishPinnedChats(p),
      legacyPinnedChannels: () =>
          ref.read(appStateProvider).pinnedChannels.toList(),
      applyPinnedChannels: (channels, persist) => ref
          .read(nostrControllerProvider)
          .applyPinnedChannels(channels, persist),
      storeList: (key) => visibleMessagesFor(ref.read(appStateProvider), key),
      lastRead: (key) =>
          ref.read(appStateProvider.notifier).channelLastRead[key] ?? 0,
      badge: (key) {
        final u = ref.read(appStateProvider).unreadCounts;
        final a = u[key] ?? 0;
        final b = u[chatNavAlias(key)] ?? 0;
        return a > b ? a : b;
      },
      isMention: (m) => chatNavMentions(ref, m),
      isOpen: (key) => ref.read(appStateProvider).view.storageKey == key,
      scheduleApi: (action, body) =>
          ref.read(nostrControllerProvider).scheduleApi(action, body),
      buildScheduled: (key, text, at, threadRoot) => ref
          .read(nostrControllerProvider)
          .buildScheduledEvents(key, text, at, threadRoot),
      encryptNote: (json) =>
          ref.read(nostrControllerProvider).encryptScheduleNote(json),
      decryptNote: (blob) =>
          ref.read(nostrControllerProvider).decryptScheduleNote(blob),
      blockContext: (key) =>
          ref.read(nostrControllerProvider).scheduleBlockContext(key),
      sendText: (key, text) =>
          ref.read(nostrControllerProvider).sendScheduledText(key, text),
      groupSendBlocked: (key, text) => ref
          .read(groupToolsProvider)
          .sendBlockedReason(chatNavAlias(key), text),
      notice: (text) =>
          ref.read(appStateProvider.notifier).addSystemMessage(text),
      onChanged: () {
        if (bump) return;
        bump = true;
        Future.microtask(() {
          bump = false;
          ref.read(chatNavRevisionProvider.notifier).state++;
        });
      },
    ),
    tr: (s) => tr(s),
  );
  ref.onDispose(service.dispose);
  return service;
});
