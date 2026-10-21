import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/channels/channel_manager.dart';
import '../../features/chat_lock/chat_lock_providers.dart';
import '../../features/chat_nav/chat_nav.dart' show pinSort;
import '../../features/chat_nav/chat_nav_providers.dart';
import '../../features/groups/group_logic.dart';
import '../../features/mesh/mesh_controller.dart';
import '../../features/presence/nyms_online.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/pm_conversation.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';

@immutable
class SidebarRow<T> {
  const SidebarRow(this.item, this.sig);

  final T item;
  final Object sig;

  @override
  bool operator ==(Object other) => other is SidebarRow<T> && other.sig == sig;

  @override
  int get hashCode => sig.hashCode;
}

@immutable
class SidebarRows<T> {
  const SidebarRows(this.rows, {this.count = 0, this.flag = false});

  final List<SidebarRow<T>> rows;
  final int count;
  final bool flag;

  @override
  bool operator ==(Object other) =>
      other is SidebarRows<T> &&
      other.count == count &&
      other.flag == flag &&
      listEquals(other.rows, rows);

  @override
  int get hashCode => Object.hash(count, flag, Object.hashAll(rows));
}

@immutable
class _Inputs {
  const _Inputs(this.head, this.rows);

  final List<Object?> head;
  final List<Object?> rows;

  @override
  bool operator ==(Object other) =>
      other is _Inputs &&
      listEquals(other.head, head) &&
      listEquals(other.rows, rows);

  @override
  int get hashCode => Object.hash(Object.hashAll(head), Object.hashAll(rows));
}

final _channelInputsProvider = Provider<_Inputs>((ref) {
  final s = ref.watch(appStateProvider);
  final rows = <Object?>[];
  for (final ch in s.channels) {
    final key = ch.key;
    final storageKey = ch.storageKey;
    rows
      ..add(ch)
      ..add(s.blockedChannels.contains(key))
      ..add(s.hiddenChannels.contains(key))
      ..add(s.channelLastActivity[storageKey])
      ..add(s.unreadCounts[storageKey]);
  }
  return _Inputs([...s.pinnedChannels], rows);
});

String _shownMembers(AppState s, Group g, Map<String, User> users) => [
      for (final pk in g.members.where((pk) => pk != s.selfPubkey).take(3))
        '$pk|${users[pk]?.nym}|${users[pk]?.profile?.picture}',
    ].join('\n');

final _pmInputsProvider = Provider<_Inputs>((ref) {
  final s = ref.watch(appStateProvider);
  final users = ref.watch(usersProvider);
  return _Inputs([s.selfPubkey], [
    for (final c in s.pmConversations) ...[
      c,
      c.pubkey,
      c.nym,
      c.lastMessageTime,
      c.pubkey != s.selfPubkey && s.isPersonHidden(c.pubkey),
      s.unreadCounts[c.pubkey],
    ],
    for (final g in s.groups) ...[
      g,
      g.id,
      g.lastMessageTime,
      s.groupLabel(g),
      g.members.length,
      g.avatar,
      _shownMembers(s, g, users),
      s.unreadCounts[GroupLogic.groupStorageKey(g.id)],
    ],
  ]);
});

typedef SidebarChannelSig = ({
  ChannelEntry entry,
  bool active,
  bool pinned,
  int unread
});

class SidebarPmEntry {
  SidebarPmEntry.pm(PMConversation this.pm)
      : group = null,
        lastMessageTime = pm.lastMessageTime;
  SidebarPmEntry.group(Group g)
      : pm = null,
        group = g,
        lastMessageTime = g.lastMessageTime;

  final PMConversation? pm;
  final Group? group;
  final int lastMessageTime;
  bool active = false;
  int unread = 0;
  bool mesh = false;

  String get key => group != null
      ? 'group-${group!.id}'
      : 'pm-${pm!.pubkey.toLowerCase()}';
}

final sidebarChannelRowsProvider =
    Provider<SidebarRows<ChannelEntry>>((ref) {
  ref.watch(_channelInputsProvider);
  final app = ref.read(appStateProvider);
  final view = ref.watch(currentViewProvider);
  final meshOpen = ref.watch(meshScreenOpenProvider);
  final sortByProximity =
      ref.watch(settingsProvider.select((s) => s.sortByProximity));
  final hideNonPinned =
      ref.watch(settingsProvider.select((s) => s.hideNonPinned));
  final location = ref.watch(userLocationProvider);
  ref.watch(chatLockRevisionProvider);
  final chatLock = ref.read(chatLockProvider);
  final activeChannelKey = (!meshOpen && view.kind == ViewKind.channel)
      ? view.id.toLowerCase()
      : '';
  final visibleChannels = app.channels
      .where((ch) => !app.blockedChannels.contains(ch.key))
      .where((ch) =>
          ch.key == kDefaultChannel ||
          ch.key == activeChannelKey ||
          (!app.hiddenChannels.contains(ch.key) &&
              !(hideNonPinned && !app.pinnedChannels.contains(ch.key))))
      .toList();
  final sorted = ChannelManager.sortChannels(
    visibleChannels,
    ChannelSortContext(
      activeKey: activeChannelKey,
      pinned: app.pinnedChannels,
      lastActivity: app.channelLastActivity,
      unreadCounts: app.unreadCounts,
      sortByProximity: sortByProximity,
      userLocation: location,
    ),
  );
  final bands = [for (var i = 0; i < 5; i++) <SidebarRow<ChannelEntry>>[]];
  for (final ch in sorted) {
    final key = ch.key;
    final storageKey = ch.storageKey;
    if (chatLock.isConversationLocked(storageKey)) continue;
    final pinned = app.pinnedChannels.contains(key);
    final unread = app.unreadCounts[storageKey] ?? 0;
    final band = key == kDefaultChannel
        ? 0
        : pinned
            ? 1
            : key == activeChannelKey
                ? 2
                : unread > 0
                    ? 3
                    : 4;
    bands[band].add(SidebarRow(
      ch,
      (
        entry: ch,
        active: !meshOpen && view.kind == ViewKind.channel && view.id == key,
        pinned: pinned,
        unread: unread,
      ),
    ));
  }
  return SidebarRows([
    for (final b in bands) ...b,
  ], flag: app.channels.any((ch) => ch.key != kDefaultChannel));
});

final sidebarPmRowsProvider = Provider<SidebarRows<SidebarPmEntry>>((ref) {
  ref.watch(_pmInputsProvider);
  final app = ref.read(appStateProvider);
  final view = ref.watch(currentViewProvider);
  final meshOpen = ref.watch(meshScreenOpenProvider);
  final pms = ref.read(pmListProvider);
  final groups = ref.read(groupsProvider);
  final users = ref.read(usersProvider);
  final meshPmPubkeys =
      ref.watch(meshControllerProvider.select((s) => s.meshPmPubkeys));
  ref.watch(chatLockRevisionProvider);
  final chatLock = ref.read(chatLockProvider);
  ref.watch(chatNavRevisionProvider);
  final byTime = <SidebarPmEntry>[
    for (final pm in pms) SidebarPmEntry.pm(pm),
    for (final g in groups) SidebarPmEntry.group(g),
  ]..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
  final entryByKey = <String, SidebarPmEntry>{
    for (final e in byTime) e.key: e,
  };
  final ordered = pinSort(
      entryByKey.keys.toList(), ref.read(chatNavProvider).pinState());
  final unread = app.unreadCounts;
  final rows = <SidebarRow<SidebarPmEntry>>[];
  for (final k in ordered) {
    if (chatLock.isConversationLocked(k)) continue;
    final e = entryByKey[k]!;
    final g = e.group;
    if (g != null) {
      e
        ..active = !meshOpen && view.kind == ViewKind.group && view.id == g.id
        ..unread = unread[GroupLogic.groupStorageKey(g.id)] ?? 0;
      final shown = _shownMembers(app, g, users);
      rows.add(SidebarRow(e, (
        g,
        app.groupLabel(g),
        g.members.length,
        g.avatar,
        shown,
        e.active,
        e.unread,
        app.selfPubkey,
      )));
    } else {
      final pm = e.pm!;
      e
        ..active = !meshOpen && view.kind == ViewKind.pm && view.id == pm.pubkey
        ..unread = unread[pm.pubkey] ?? 0
        ..mesh = meshPmPubkeys.contains(pm.pubkey.toLowerCase());
      rows.add(SidebarRow(e, (pm.pubkey, pm.nym, e.active, e.unread, e.mesh)));
    }
  }
  return SidebarRows(rows);
});

final sidebarNymRowsProvider = Provider<SidebarRows<User>>((ref) {
  final pmOnly =
      ref.watch(settingsProvider.select((s) => s.groupChatPMOnlyMode));
  final nymsList = ref.watch(nymsListUsersProvider);
  Set<String>? only;
  if (pmOnly) {
    only = {
      for (final pm in ref.watch(pmListProvider)) pm.pubkey,
      for (final g in ref.watch(groupsProvider)) ...g.members,
    };
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  final users = nymsList.values
      .where((u) => only == null || only.contains(u.pubkey))
      .toList()
    ..sort((a, b) => compareNymsListRows(a, b, now));
  final controller = ref.read(nostrControllerProvider);
  return SidebarRows([
    for (final u in users)
      SidebarRow(u, (
        u,
        u.nym,
        u.effectiveStatus(isVerifiedBot: controller.isVerifiedBot(u.pubkey)),
        u.profile?.picture,
      )),
  ], count: nymsListOnlineCount(users, now));
});
