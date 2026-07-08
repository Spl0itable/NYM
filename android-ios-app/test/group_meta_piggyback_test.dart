import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/groups/group_logic.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/state/app_state.dart';

List<String>? _tag(List<List<String>> tags, String k) {
  for (final t in tags) {
    if (t.isNotEmpty && t[0] == k) return t;
  }
  return null;
}

Group _g({
  String? createdBy,
  int metaUpdatedAt = 0,
  String? avatar,
  String? banner,
}) =>
    Group(
      id: 'g1',
      name: 'Squad',
      members: const ['owner_pk', 'self_pk'],
      createdBy: createdBy,
      metaUpdatedAt: metaUpdatedAt,
      avatar: avatar,
      banner: banner,
    );

void main() {
  group('group metadata piggyback tags', () {
    test('owner with metadata → carries meta_ts + avatar + banner', () {
      final tags = GroupLogic.groupMetaPiggybackTags(
        _g(
          createdBy: 'owner_pk',
          metaUpdatedAt: 1700,
          avatar: 'https://cdn/a.png',
          banner: 'https://cdn/b.png',
        ),
        'owner_pk',
      );
      expect(_tag(tags, 'meta_ts'), ['meta_ts', '1700']);
      expect(_tag(tags, 'avatar'), ['avatar', 'https://cdn/a.png']);
      expect(_tag(tags, 'banner'), ['banner', 'https://cdn/b.png']);
    });

    test('a NON-owner attaches nothing (anti-spoof)', () {
      expect(
        GroupLogic.groupMetaPiggybackTags(
            _g(createdBy: 'owner_pk', metaUpdatedAt: 1700, avatar: 'x'),
            'self_pk'),
        isEmpty,
      );
    });

    test('owner who never set metadata (metaUpdatedAt 0) attaches nothing', () {
      expect(
        GroupLogic.groupMetaPiggybackTags(
            _g(createdBy: 'self_pk', metaUpdatedAt: 0, avatar: 'x'), 'self_pk'),
        isEmpty,
      );
    });

    test('round-trip: a member who knows the owner heals the avatar from the '
        'piggyback tags on a regular message', () {
      final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
      // The member already knows the group + its owner, but has no avatar yet
      // (missed the ephemeral group-metadata control event).
      n.upsertGroup(Group(
        id: 'g1',
        name: 'Squad',
        members: const ['owner_pk', 'self_pk'],
        createdBy: 'owner_pk',
      ));
      expect(n.groupById('g1')!.avatar, isNull);

      // The owner's regular message carries the piggyback; the inbound meta_ts
      // handler applies it via a metadata control apply.
      final piggyback = GroupLogic.groupMetaPiggybackTags(
        _g(createdBy: 'owner_pk', metaUpdatedAt: 1700, avatar: 'https://cdn/a.png'),
        'owner_pk',
      );
      n.applyGroupControl(
        groupId: 'g1',
        type: GroupControlType.metadata,
        tags: piggyback,
        senderPubkey: 'owner_pk',
        ts: 1700,
      );
      expect(n.groupById('g1')!.avatar, 'https://cdn/a.png');
    });
  });
}
