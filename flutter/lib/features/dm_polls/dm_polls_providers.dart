import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../chat_tools/chat_tools_providers.dart' show KeyValueChatToolsPrefs;
import '../i18n/i18n.dart';
import '../pms/pm_logic.dart';
import 'dm_polls_service.dart';

final dmPollsRevisionProvider = StateProvider<int>((ref) => 0);

Message? findDmPollMessage(AppState s, String pollId) {
  if (pollId.isEmpty) return null;
  for (final list in s.messages.values) {
    for (final m in list) {
      if (m.nymMessageId == pollId && (m.isPM || m.isGroup)) return m;
    }
  }
  return null;
}

DmPollsHooks dmPollsAppHooks(Ref ref) {
  NostrController ctl() => ref.read(nostrControllerProvider);
  return DmPollsHooks(
    selfPubkey: () => ref.read(appStateProvider).selfPubkey,
    group: (id) => ref.read(appStateProvider.notifier).groupById(id),
    findMessage: (id) => findDmPollMessage(ref.read(appStateProvider), id),
    isBot: (pk) => ctl().isVerifiedBot(pk),
    sendPm: (pk, content) => ctl().gtSendPmContent(pk, content),
    sendGroup: (gid, content) => ctl().gtSendGroupContent(gid, content),
    sendControl: (rumor, recipients, gid) =>
        ctl().dpSendControl(rumor, recipients, gid),
    newId: PmLogic.generateSharedEventId,
    notice: (text) =>
        ref.read(appStateProvider.notifier).addSystemMessage(text),
    onChanged: () {
      ref.read(dmPollsRevisionProvider.notifier).state++;
      ref.read(appStateProvider.notifier).touch();
    },
    translate: (text, [vars]) => tr(text, vars),
  );
}

final dmPollsProvider = Provider<DmPollsService>((ref) {
  final kv = ref.watch(keyValueStoreProvider);
  return DmPollsService(KeyValueChatToolsPrefs(kv), dmPollsAppHooks(ref));
});
