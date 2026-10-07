import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/bech32_codec.dart' show encodeNpub;
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../chat_tools/chat_tools_service.dart' show chatToolsHidden;
import 'unified_search.dart';

class SearchCorpus {
  const SearchCorpus({
    required this.channels,
    required this.nyms,
    required this.messages,
    required this.visible,
  });

  final List<SearchChannelItem> channels;
  final List<SearchNymItem> nyms;
  final List<SearchMessageItem> messages;
  final bool Function(SearchMessageItem) visible;
}

class UnifiedSearchIndex {
  final Expando<SearchMessageItem> _items = Expando<SearchMessageItem>();
  final Map<String, String> _npubs = <String, String>{};
  Map<String, List<Message>>? _map;
  final Map<String, (List<Message>, int)> _lists = <String, (List<Message>, int)>{};
  String _lockSig = '';
  int _rev = -1;
  List<SearchMessageItem> _flat = const [];
  int builds = 0;

  String npubOf(String pubkey) {
    final hit = _npubs[pubkey];
    if (hit != null) return hit;
    String out = '';
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(pubkey)) {
      try {
        out = encodeNpub(pubkey);
      } catch (_) {}
    }
    _npubs[pubkey] = out;
    return out;
  }

  bool _fresh(Map<String, List<Message>> map, String lockSig, int rev) {
    if (!identical(map, _map) || lockSig != _lockSig || rev != _rev) {
      return false;
    }
    if (map.length != _lists.length) return false;
    for (final e in map.entries) {
      final seen = _lists[e.key];
      if (seen == null ||
          !identical(seen.$1, e.value) ||
          seen.$2 != e.value.length) {
        return false;
      }
    }
    return true;
  }

  SearchMessageItem _itemFor(String key, Message m) {
    final hit = _items[m];
    if (hit != null &&
        identical(hit.text, m.content) &&
        hit.key == key &&
        hit.at == m.timestamp) {
      return hit;
    }
    final it = SearchMessageItem(
      id: m.id,
      key: key,
      at: m.timestamp,
      text: m.content,
      ref: m,
    );
    _items[m] = it;
    return it;
  }

  List<SearchMessageItem> messages(
      Map<String, List<Message>> map, bool Function(String key) locked,
      {int rev = 0}) {
    final lockedKeys = [
      for (final k in map.keys)
        if (locked(k)) k
    ]..sort();
    final lockSig = lockedKeys.join('\n');
    if (_fresh(map, lockSig, rev)) return _flat;
    builds++;
    final out = <SearchMessageItem>[];
    _lists.clear();
    for (final e in map.entries) {
      _lists[e.key] = (e.value, e.value.length);
      if (locked(e.key)) continue;
      for (final m in e.value) {
        if (m.isSystemRow || m.content.isEmpty) continue;
        out.add(_itemFor(e.key, m));
      }
    }
    _map = map;
    _lockSig = lockSig;
    _rev = rev;
    _flat = out;
    return out;
  }
}

final unifiedSearchIndexProvider =
    Provider<UnifiedSearchIndex>((ref) => UnifiedSearchIndex());

SearchCorpus buildSearchCorpus(
  AppState s,
  UnifiedSearchIndex index, {
  required bool Function(String storageKey) locked,
  int? nowSec,
}) {
  final now = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final channels = <SearchChannelItem>[];
  final seen = <String>{};
  for (final ch in s.channels) {
    if (s.blockedChannels.contains(ch.key)) continue;
    if (locked(ch.storageKey)) continue;
    if (!seen.add(ch.key)) continue;
    channels.add(SearchChannelItem(
      key: ch.key,
      name: ch.isGeohash ? ch.geohashKey : ch.channel,
      kind: ch.isGeohash ? 'geohash' : 'channel',
      joined: true,
      at: s.channelLastActivity[ch.storageKey] ?? 0,
    ));
  }
  for (final e in s.geohashD1Activity.entries) {
    final gh = e.key.toLowerCase();
    if (seen.contains(gh) || s.blockedChannels.contains(gh)) continue;
    if (!isSearchGeohash(gh)) continue;
    seen.add(gh);
    var sum = 0;
    for (final n in e.value) {
      sum += n;
    }
    channels.add(SearchChannelItem(
        key: gh, name: gh, kind: 'geohash', joined: false, at: sum));
  }
  for (final g in s.groups) {
    if (locked('group-${g.id}')) continue;
    channels.add(SearchChannelItem(
      key: g.id,
      name: g.name,
      kind: 'group',
      joined: true,
      at: g.lastMessageTime,
    ));
  }
  final nyms = <SearchNymItem>[];
  final people = <String>{};
  for (final u in s.users.values) {
    if (u.pubkey.isEmpty || s.blockedUsers.contains(u.pubkey)) continue;
    if (!people.add(u.pubkey)) continue;
    nyms.add(SearchNymItem(
      pubkey: u.pubkey,
      nym: stripPubkeySuffix(u.nym),
      npub: index.npubOf(u.pubkey),
      friend: s.friends.contains(u.pubkey),
      at: u.lastSeen,
    ));
  }
  for (final p in s.pmConversations) {
    if (p.pubkey.isEmpty || s.blockedUsers.contains(p.pubkey)) continue;
    if (locked('pm-${p.pubkey}')) continue;
    if (!people.add(p.pubkey)) continue;
    nyms.add(SearchNymItem(
      pubkey: p.pubkey,
      nym: stripPubkeySuffix(p.nym),
      npub: index.npubOf(p.pubkey),
      friend: s.friends.contains(p.pubkey),
    ));
  }
  final blockedRooms = <String>{
    for (final k in s.blockedChannels) '#$k',
  };
  final messages = index.messages(
      s.messages, (k) => blockedRooms.contains(k) || locked(k),
      rev: s.displayRev);
  bool visible(SearchMessageItem it) {
    final m = it.ref;
    if (m is! Message) return true;
    if (m.blocked || m.spamGated) return false;
    if (s.isMessageFiltered(m)) return false;
    if (m.expiresAt != null && chatToolsHidden(m, now)) return false;
    return true;
  }

  return SearchCorpus(
    channels: channels,
    nyms: nyms,
    messages: messages,
    visible: visible,
  );
}
