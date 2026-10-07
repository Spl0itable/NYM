import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../chat_tools/chat_tools_providers.dart';
import '../group_tools/group_tools_providers.dart';
import '../i18n/i18n.dart';
import '../notifications/self_reference.dart';
import '../toasts/toast_center.dart';
import 'chat_nav_service.dart';

String chatNavAlias(String key) {
  if (key.startsWith('pm-')) return key.substring(3);
  if (key.startsWith('group-')) return key.substring(6);
  if (key.startsWith('#')) return key.substring(1);
  return key;
}

final Expando<(String, String, String?, bool)> _selfMentionMemo =
    Expando<(String, String, String?, bool)>();

bool chatNavMentions(Ref ref, Message m) {
  if (m.isOwn) return false;
  if (m.isGroup && ref.read(groupToolsProvider).mentionsAll(m)) return true;
  final nym = ref.read(appStateProvider).selfNym;
  final pubkey = ref.read(nostrControllerProvider).identity?.pubkey;
  final hit = _selfMentionMemo[m];
  if (hit != null && hit.$1 == m.content && hit.$2 == nym && hit.$3 == pubkey) {
    return hit.$4;
  }
  final r = contentMentionsSelf(content: m.content, nym: nym, pubkey: pubkey);
  _selfMentionMemo[m] = (m.content, nym, pubkey, r);
  return r;
}

final chatNavRevisionProvider = StateProvider<int>((ref) => 0);

final composerHintTopProvider = StateProvider<double?>((ref) => null);

double floatLiftOver(double? hintTop, double listBottom) =>
    hintTop == null || hintTop >= listBottom ? 0 : listBottom - hintTop;

final chatNavProvider = Provider<ChatNavService>((ref) {
  final kv = ref.watch(keyValueStoreProvider);
  var bump = false;
  var disposed = false;
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
      storeRaw: (key) =>
          ref.read(appStateProvider).messages[key] ?? const <Message>[],
      plainlyVisible: (m) => plainlyVisible(ref.read(appStateProvider), m),
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
      notice: (text) => showToast(text),
      undoNotice: (text, undo) => showUndoToast(text, undo),
      chatName: (kind, id) {
        final app = ref.read(appStateProvider);
        if (kind == 'dm') {
          final nym = app.users[id]?.nym;
          final base = nym == null || nym.isEmpty
              ? id.substring(0, 8)
              : stripPubkeySuffix(nym);
          return '$base#${getPubkeySuffix(id)}';
        }
        for (final g in app.groups) {
          if (g.id == id) return g.name;
        }
        return id.substring(0, 8);
      },
      onChanged: () {
        if (bump) return;
        bump = true;
        Future.microtask(() {
          bump = false;
          if (disposed) return;
          ref.read(chatNavRevisionProvider.notifier).state++;
        });
      },
    ),
    tr: (s) => tr(s),
  );
  ref.onDispose(() {
    disposed = true;
    service.dispose();
  });
  return service;
});
