import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/state/app_state.dart';

void main() {
  group('bare group shell enrichment (sidebar avatar backfill)', () {
    test('a message-born shell has no avatar/owner until enriched', () {
      final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
      // Learned via an inbound group MESSAGE before the invite → bare shell.
      n.mergeGroupFromMessage(
        groupId: 'g1',
        name: 'Squad',
        memberPubkeys: const ['self_pk', 'owner_pk'],
        timestampMs: 1000,
      );
      final shell = n.groupById('g1')!;
      expect(shell.avatar, isNull);
      expect(shell.createdBy, anyOf(isNull, isEmpty));

      // The invite / add-member bootstrap backfills owner + appearance.
      final changed = n.enrichGroupIdentity(
        'g1',
        createdBy: 'owner_pk',
        avatar: 'https://cdn.example/pic.png',
        members: const ['self_pk', 'owner_pk', 'friend_pk'],
      );
      expect(changed, isTrue);
      final g = n.groupById('g1')!;
      expect(g.avatar, 'https://cdn.example/pic.png');
      expect(g.createdBy, 'owner_pk');
      expect(g.members, contains('friend_pk'));
    });

    test('enrich never clobbers an avatar the group already has', () {
      final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
      n.mergeGroupFromMessage(
        groupId: 'g2',
        name: 'Squad',
        memberPubkeys: const ['self_pk'],
        timestampMs: 1000,
      );
      n.enrichGroupIdentity('g2', avatar: 'https://cdn.example/first.png');
      // A later (e.g. spoofed) backfill must not overwrite the real avatar.
      final changed =
          n.enrichGroupIdentity('g2', avatar: 'https://evil.example/x.png');
      expect(changed, isFalse);
      expect(n.groupById('g2')!.avatar, 'https://cdn.example/first.png');
    });
  });
}
