import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/channels/channel_manager.dart';
import '../../features/chat_lock/chat_lock_providers.dart';
import '../../core/utils/nym_utils.dart';
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
  final users = only == null
      ? nymsList.values
      : nymsList.values.where((u) => only!.contains(u.pubkey));
  final controller = ref.read(nostrControllerProvider);
  final order = ref.read(_nymOrderProvider)
    ..update(users, now, controller.isVerifiedBot);
  return SidebarRows(order.rows,
      count: nymsListOnlineCount(order.users, now));
});

final _nymOrderProvider = Provider<NymListOrder>((ref) => NymListOrder());

class _NymSlot {
  _NymSlot(this.user, this.rank, this.nym)
      : name = stripPubkeySuffix(nym).toLowerCase();

  User user;
  int rank;
  String nym;
  String name;
  int seen = 0;
  int seq = 0;
  SidebarRow<User>? row;
}

int _nymRank(User u, int now) => switch (nymStatus(u, now)) {
      UserStatus.online => 0,
      UserStatus.away => 1,
      _ => 2,
    };

int _slotOrder(_NymSlot a, _NymSlot b) {
  final r = a.rank - b.rank;
  if (r != 0) return r;
  final n = a.name.compareTo(b.name);
  if (n != 0) return n;
  return a.seq - b.seq;
}

class NymListOrder {
  final Map<String, _NymSlot> _slots = {};
  List<_NymSlot> _order = [];
  int _gen = 0;
  int _seq = 0;

  @visibleForTesting
  int fullSorts = 0;

  @visibleForTesting
  int moves = 0;

  List<User> users = const [];
  List<SidebarRow<User>> rows = const [];

  int _find(_NymSlot slot) {
    var lo = 0;
    var hi = _order.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_slotOrder(_order[mid], slot) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void update(Iterable<User> next, int now, bool Function(String) isBot) {
    final gen = ++_gen;
    final moved = <(_NymSlot, int, String)>[];
    final added = <_NymSlot>[];
    var kept = 0;
    var last = 0;
    var resequence = false;
    for (final u in next) {
      final nym = u.nym;
      final rank = _nymRank(u, now);
      final slot = _slots[u.pubkey];
      if (slot == null) {
        added.add(_slots[u.pubkey] = _NymSlot(u, rank, nym)
          ..seen = gen
          ..seq = last = ++_seq);
        continue;
      }
      kept++;
      if (slot.seq < last) resequence = true;
      last = slot.seq;
      slot
        ..seen = gen
        ..user = u;
      if (slot.rank != rank || slot.nym != nym) {
        moved.add((slot, rank, nym));
      }
    }
    final gone = kept == _order.length
        ? const <_NymSlot>[]
        : [for (final s in _order) if (s.seen != gen) s];
    final churn = moved.length + added.length + gone.length;
    if (resequence) {
      for (final u in next) {
        _slots[u.pubkey]!.seq = ++_seq;
      }
    }
    if (churn > 0 || resequence) {
      if (resequence ||
          _order.isEmpty ||
          churn * 8 > _order.length + added.length) {
        for (final (slot, rank, nym) in moved) {
          slot
            ..rank = rank
            ..nym = nym
            ..name = stripPubkeySuffix(nym).toLowerCase();
        }
        for (final s in gone) {
          _slots.remove(s.user.pubkey);
        }
        _order = _slots.values.toList()..sort(_slotOrder);
        fullSorts++;
      } else {
        for (final s in [...gone, for (final m in moved) m.$1]) {
          final i = _find(s);
          if (i < _order.length && identical(_order[i], s)) {
            _order.removeAt(i);
          } else {
            _order.remove(s);
          }
        }
        for (final s in gone) {
          _slots.remove(s.user.pubkey);
        }
        for (final (slot, rank, nym) in moved) {
          slot
            ..rank = rank
            ..nym = nym
            ..name = stripPubkeySuffix(nym).toLowerCase();
        }
        for (final s in [for (final m in moved) m.$1, ...added]) {
          _order.insert(_find(s), s);
          moves++;
        }
      }
    }
    users = [for (final s in _order) s.user];
    rows = [
      for (final s in _order) _rowFor(s, isBot),
    ];
  }

  SidebarRow<User> _rowFor(_NymSlot s, bool Function(String) isBot) {
    final u = s.user;
    final sig = (
      u,
      s.nym,
      u.effectiveStatus(isVerifiedBot: isBot(u.pubkey)),
      u.profile?.picture,
    );
    final row = s.row;
    if (row != null && row.sig == sig) return row;
    return s.row = SidebarRow(u, sig);
  }
}
