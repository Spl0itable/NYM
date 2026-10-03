import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../i18n/i18n.dart';
import '../mesh/mesh_controller.dart';
import '../toasts/toast_center.dart';
import 'chat_tools_service.dart';

class KeyValueChatToolsPrefs implements ChatToolsPrefs {
  KeyValueChatToolsPrefs(this._kv);

  final KeyValueStore _kv;

  @override
  String? read(String key) => _kv.getString(key);

  @override
  void write(String key, String value) {
    _kv.setString(key, value).ignore();
  }

  @override
  void remove(String key) {
    _kv.remove(key).ignore();
  }
}

({Message msg, String key})? findMessageAnywhere(AppState s, String id) {
  if (id.isEmpty) return null;
  for (final e in s.messages.entries) {
    for (final m in e.value) {
      if (m.id == id || m.nymMessageId == id) return (msg: m, key: e.key);
    }
  }
  return null;
}

final chatToolsRevisionProvider = StateProvider<int>((ref) => 0);

final chatToolsProvider = Provider<ChatToolsService>((ref) {
  final kv = ref.watch(keyValueStoreProvider);
  return ChatToolsService(
    KeyValueChatToolsPrefs(kv),
    ChatToolsHooks(
      selfPubkey: () => ref.read(appStateProvider).selfPubkey,
      online: () => ref.read(appStateProvider).connectedRelays > 0,
      hydrated: () => ref.read(nostrControllerProvider).savesHydrated,
      syncAllowed: () => ref.read(nostrControllerProvider).savedSyncAllowed,
      publishSaved: (saved) =>
          ref.read(nostrControllerProvider).publishSavedMessages(saved),
      publishKeep: (key, nid, kept, at) => ref
          .read(nostrControllerProvider)
          .publishKeepControl(key, nid, kept, at),
      meshPeerFor: (pubkey) => ref
          .read(meshControllerProvider.notifier)
          .bridge
          ?.peerIdForPubkey(pubkey),
      sendMeshKeep: (pubkey, nid, kept) async =>
          await ref
              .read(meshControllerProvider.notifier)
              .bridge
              ?.sendKeep(pubkey, nid, kept) ??
          false,
      groupMembers: (gid) =>
          ref.read(appStateProvider.notifier).groupById(gid)?.members,
      findMessage: (id) => findMessageAnywhere(ref.read(appStateProvider), id),
      fetchEditEvents: (surface, id, at) => ref
          .read(nostrControllerProvider)
          .editHistoryEvents(surface, id, at),
      notice: (text) => showToast(tr(text)),
      onChanged: () {
        ref.read(chatToolsRevisionProvider.notifier).state++;
        ref.read(appStateProvider.notifier).touch();
      },
    ),
  );
});
