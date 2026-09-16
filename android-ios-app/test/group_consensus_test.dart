// Regression tests for group membership state converging across members.
//
//   1. a ban is not undone by a member who missed it advertising a stale
//      roster on its next ordinary message;
//   2. only the group owner's `subject` tag renames the group;
//   3. an unban is authorized for owners AND moderators, and a moderator may
//      add members even when "allow members to add others" is off.
//
// Mirrors scripts/test-group-consensus.mjs in the PWA.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/groups/group_logic.dart';
import 'package:nym_bar/features/pms/pm_logic.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/state/app_state.dart';

String _pk(int i) => i.toString().padLeft(2, '0') * 32;

Group _seed(
  AppStateNotifier n, {
  required String gid,
  required String owner,
  required List<String> members,
  String name = 'Room',
  List<String> mods = const [],
  List<String> banned = const [],
  bool allowMemberInvites = true,
}) {
  final g = Group(
    id: gid,
    name: name,
    members: [...members],
    createdBy: owner,
    mods: [...mods],
    banned: [...banned],
    allowMemberInvites: allowMemberInvites,
  );
  n.upsertGroup(g);
  return g;
}

void main() {
  group('a ban survives a stale roster on an ordinary message', () {
    test('a banned member is not merged back in from a p-tag roster', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g1';
      final owner = _pk(0), bob = _pk(2), carol = _pk(3);
      final members = [for (var i = 0; i < 6; i++) _pk(i)];
      final g = _seed(n, gid: gid, owner: owner, members: members);

      // Owner bans carol on this client.
      g.members.remove(carol);
      g.banned.add(carol);

      // Bob, who missed the ban, sends a message carrying the pre-ban roster.
      n.mergeGroupFromMessage(
        groupId: gid,
        name: 'Room',
        memberPubkeys: members,
        timestampMs: 110000,
        senderPubkey: bob,
      );

      expect(n.groupById(gid)!.members, isNot(contains(carol)));
      expect(n.groupById(gid)!.banned, contains(carol));
    });

    test('a non-banned newcomer in the same roster is still learned', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g1b';
      final owner = _pk(0), bob = _pk(2), carol = _pk(3), dave = _pk(9);
      final members = [for (var i = 0; i < 6; i++) _pk(i)];
      final g = _seed(n, gid: gid, owner: owner, members: members);
      g.members.remove(carol);
      g.banned.add(carol);

      n.mergeGroupFromMessage(
        groupId: gid,
        name: 'Room',
        memberPubkeys: [...members, dave],
        timestampMs: 120000,
        senderPubkey: bob,
      );

      expect(n.groupById(gid)!.members, contains(dave));
      expect(n.groupById(gid)!.members, isNot(contains(carol)));
    });
  });

  group('the group name is owner-controlled', () {
    test('a non-owner subject tag does not rename the group', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g2';
      final owner = _pk(0);
      final members = [for (var i = 0; i < 4; i++) _pk(i)];
      _seed(n, gid: gid, owner: owner, members: members, name: 'Book Club');

      n.mergeGroupFromMessage(
        groupId: gid,
        name: 'Not Book Club',
        memberPubkeys: members,
        timestampMs: 500000,
        senderPubkey: _pk(3),
      );

      expect(n.groupById(gid)!.name, 'Book Club');
    });

    test("the owner's subject tag still renames it", () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g2b';
      final owner = _pk(0);
      final members = [for (var i = 0; i < 4; i++) _pk(i)];
      _seed(n, gid: gid, owner: owner, members: members, name: 'Book Club');

      n.mergeGroupFromMessage(
        groupId: gid,
        name: 'Reading Group',
        memberPubkeys: members,
        timestampMs: 510000,
        senderPubkey: owner,
      );

      expect(n.groupById(gid)!.name, 'Reading Group');
    });
  });

  group('moderator privileges', () {
    test('a moderator may lift a ban', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g3';
      final owner = _pk(0), mod = _pk(1), carol = _pk(3);
      final members = [owner, mod, _pk(2)];
      _seed(n,
          gid: gid,
          owner: owner,
          members: members,
          mods: [mod],
          banned: [carol]);

      final res = n.applyGroupControl(
        groupId: gid,
        type: GroupControlType.unban,
        tags: [
          ['unban', carol]
        ],
        senderPubkey: mod,
        ts: 400,
        eventId: 'u1',
      );

      expect(res, GroupControlResult.applied);
      expect(n.groupById(gid)!.banned, isNot(contains(carol)));
    });

    test('a plain member may not lift a ban', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g3b';
      final owner = _pk(0), mod = _pk(1), plain = _pk(2), carol = _pk(3);
      final members = [owner, mod, plain];
      _seed(n,
          gid: gid,
          owner: owner,
          members: members,
          mods: [mod],
          banned: [carol]);

      final res = n.applyGroupControl(
        groupId: gid,
        type: GroupControlType.unban,
        tags: [
          ['unban', carol]
        ],
        senderPubkey: plain,
        ts: 401,
        eventId: 'u2',
      );

      expect(res, GroupControlResult.unauthorized);
      expect(n.groupById(gid)!.banned, contains(carol));
    });

    test('an admin may lift a ban but may not demote a peer admin', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g3c';
      final owner = _pk(0), a1 = _pk(1), a2 = _pk(2), carol = _pk(3);
      _seed(n,
          gid: gid,
          owner: owner,
          members: [owner, a1, a2],
          mods: const [],
          banned: [carol]);
      n.groupById(gid)!.admins.addAll([a1, a2]);

      expect(
        n.applyGroupControl(
          groupId: gid,
          type: GroupControlType.unban,
          tags: [
            ['unban', carol]
          ],
          senderPubkey: a1,
          ts: 500,
          eventId: 'u3',
        ),
        GroupControlResult.applied,
      );
      expect(n.groupById(gid)!.banned, isNot(contains(carol)));

      expect(
        n.applyGroupControl(
          groupId: gid,
          type: GroupControlType.revokeAdmin,
          tags: [
            ['admin', a2]
          ],
          senderPubkey: a1,
          ts: 510,
          eventId: 'r1',
        ),
        GroupControlResult.unauthorized,
      );
      expect(n.groupById(gid)!.admins, contains(a2));
    });

    test('only the owner promotes an admin, and it clears the mod role', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g3d';
      final owner = _pk(0), admin = _pk(1), target = _pk(2);
      _seed(n,
          gid: gid,
          owner: owner,
          members: [owner, admin, target],
          mods: [target]);
      n.groupById(gid)!.admins.add(admin);

      expect(
        n.applyGroupControl(
          groupId: gid,
          type: GroupControlType.promoteAdmin,
          tags: [
            ['admin', target]
          ],
          senderPubkey: admin,
          ts: 600,
          eventId: 'p1',
        ),
        GroupControlResult.unauthorized,
      );

      expect(
        n.applyGroupControl(
          groupId: gid,
          type: GroupControlType.promoteAdmin,
          tags: [
            ['admin', target]
          ],
          senderPubkey: owner,
          ts: 610,
          eventId: 'p2',
        ),
        GroupControlResult.applied,
      );
      expect(n.groupById(gid)!.admins, contains(target));
      expect(n.groupById(gid)!.mods, isNot(contains(target)));
    });

    test('rank orders owner < admin < mod < member', () {
      final owner = _pk(0), admin = _pk(1), mod = _pk(2), plain = _pk(3);
      final g = Group(
        id: 'g3e',
        members: [owner, admin, mod, plain],
        createdBy: owner,
        admins: [admin],
        mods: [mod],
      );
      expect(GroupLogic.roleRank(g, owner), 0);
      expect(GroupLogic.roleRank(g, admin), 1);
      expect(GroupLogic.roleRank(g, mod), 2);
      expect(GroupLogic.roleRank(g, plain), 3);
      expect(GroupLogic.outranks(g, admin, mod), isTrue);
      expect(GroupLogic.outranks(g, mod, admin), isFalse);
      expect(GroupLogic.canAdminister(g, admin), isTrue);
      expect(GroupLogic.canAdminister(g, mod), isFalse);
      expect(GroupLogic.canModerate(g, mod), isTrue);
    });

    test('a moderator can add members when member invites are off', () {
      final owner = _pk(0), mod = _pk(1), plain = _pk(2);
      final off = Group(
        id: 'g4',
        members: [owner, mod, plain],
        createdBy: owner,
        mods: [mod],
        allowMemberInvites: false,
      );
      expect(GroupLogic.canAddMembers(off, owner), isTrue);
      expect(GroupLogic.canAddMembers(off, mod), isTrue);
      expect(GroupLogic.canAddMembers(off, plain), isFalse);

      final on = Group(
        id: 'g5',
        members: [owner, mod, plain],
        createdBy: owner,
        mods: [mod],
      );
      expect(GroupLogic.canAddMembers(on, plain), isTrue);
    });
  });

  group('group ids commit to their creator', () {
    test('genesis vectors match the PWA byte for byte', () {
      expect(GroupLogic.genesisId('00' * 32, 'ab' * 32),
          '1b81ee5931be5bf82b294c2d72c554a4afce6271d9e74f3527e76e64df80a298');
      expect(GroupLogic.genesisId('11' * 32, 'cd' * 32),
          'eeb83ebd3245da063e596238a1d350a300dc362a70dda39d3fbe2b38daa10c06');
      expect(GroupLogic.genesisId('deadbeef' * 8, '0123456789abcdef' * 4),
          'a6261ffe2671fa66ca3c5f10acf00d2bca513be8f58ec6287f05bc2544d67971');
    });

    test('a real creator verifies and an impostor does not', () {
      final owner = _pk(0), impostor = _pk(7);
      final nonce = 'ab' * 32;
      final gid = GroupLogic.genesisId(owner, nonce);
      expect(GroupLogic.verifyGenesis(gid, owner, nonce), isTrue);
      expect(GroupLogic.verifyGenesis(gid, impostor, nonce), isFalse);
      expect(GroupLogic.verifyGenesis(gid, owner, 'cd' * 32), isFalse);
      expect(GroupLogic.verifyGenesis(gid, null, null), isNull);
      expect(GroupLogic.verifyGenesis(gid, 'nothex', nonce), isNull);
    });
  });

  group('join requests elect a single admitter', () {
    test('ranks are a permutation all clients agree on', () {
      final owner = _pk(0);
      final members = [owner, _pk(1), _pk(2), _pk(3), _pk(4)];
      final g = Group(
        id: 'g8',
        members: members,
        createdBy: owner,
        admins: [_pk(1)],
        mods: [_pk(2)],
      );
      final joiner = _pk(9);
      final ranks = [
        for (final pk in members) GroupLogic.joinAdmitRank(g, pk, joiner)
      ];
      expect(ranks.every((r) => r >= 0), isTrue);
      expect((ranks.toList()..sort()), List.generate(members.length, (i) => i));
      expect(ranks.where((r) => r == 0).length, 1);
    });

    test('a plain member is excluded when invites are off', () {
      final owner = _pk(0), plain = _pk(3);
      final g = Group(
        id: 'g9',
        members: [owner, plain],
        createdBy: owner,
        allowMemberInvites: false,
      );
      expect(GroupLogic.joinAdmitRank(g, plain, _pk(9)), -1);
      expect(GroupLogic.joinAdmitRank(g, owner, _pk(9)), 0);
    });
  });

  group('the roster digest', () {
    test('vectors match the PWA byte for byte', () {
      expect(GroupLogic.rosterHash('ab' * 16, ['11' * 32, '22' * 32]),
          '93184dc64e871a48');
      expect(GroupLogic.rosterHash('cd' * 16, const <String>[]),
          '02cfadbb08532833');
    });

    test('order and duplicates do not change it', () {
      final gid = 'ab' * 16;
      final m = [_pk(1), _pk(2), _pk(3)];
      final h = GroupLogic.rosterHash(gid, m);
      expect(GroupLogic.rosterHash(gid, m.reversed), h);
      expect(GroupLogic.rosterHash(gid, [...m, _pk(1)]), h);
      expect(GroupLogic.rosterHash(gid, [...m, _pk(4)]), isNot(h));
      expect(GroupLogic.rosterHash('cd' * 16, m), isNot(h));
    });

    test('an ordinary message carries the digest, not the roster', () {
      final owner = _pk(0);
      final g = Group(
        id: 'ab' * 16,
        name: 'Room',
        members: [owner, _pk(1), _pk(2)],
        createdBy: owner,
      );
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: g,
        selfPubkey: owner,
        content: 'hi',
        nymMessageId: 'x' * 64,
        ephemeralPk: _pk(5),
      );
      expect(rumor.tags.where((t) => t[0] == 'p'), isEmpty);
      final rh = rumor.tags.firstWhere((t) => t[0] == 'rh');
      expect(rh[1], GroupLogic.rosterHash(g.id, g.members));
    });

    test('a served roster converges the asker and respects authority', () {
      final owner = _pk(0), mod = _pk(1), plain = _pk(2), asker = _pk(3);
      final source = Group(
        id: 'g13',
        members: [owner, mod, plain, asker, _pk(4)],
        createdBy: owner,
        admins: [_pk(4)],
        mods: [mod],
        banned: [_pk(9)],
      );
      final tags = GroupLogic.buildRosterReplyTags(source, asker);

      final target = Group(
          id: 'g13', members: [owner, asker], createdBy: owner, mods: [mod]);
      expect(GroupLogic.applyRoster(target, tags, mod, asker), isTrue);
      expect(target.members.length, 5);
      expect(GroupLogic.rosterHash('g13', target.members),
          GroupLogic.rosterHash('g13', source.members));
      expect(target.admins, contains(_pk(4)));
      expect(target.mods, contains(mod));
      expect(target.members, isNot(contains(_pk(9))));

      final unauthorized =
          Group(id: 'g13', members: [owner, asker], createdBy: owner);
      expect(GroupLogic.applyRoster(unauthorized, tags, plain, asker), isFalse);
      expect(unauthorized.members.length, 2);

      final evicted =
          Group(id: 'g13', members: [owner, _pk(7)], createdBy: owner, mods: [mod]);
      expect(GroupLogic.applyRoster(evicted, tags, mod, _pk(7)), isFalse);
      expect(evicted.members, contains(_pk(7)));

      final shell = Group(id: 'g13', members: [asker]);
      expect(GroupLogic.applyRoster(shell, tags, mod, asker), isTrue);
      expect(shell.members.length, 5);
      expect(shell.createdBy, owner);
      expect(GroupLogic.applyRoster(shell, tags, plain, asker), isFalse);
    });
  });

  group('batched signals', () {
    test('a receipt carrying several ids parses them all', () {
      final rumor = {
        'pubkey': _pk(1),
        'created_at': 1700000000,
        'tags': [
          ['p', _pk(0)],
          ['x', 'aa'],
          ['x', 'bb'],
          ['x', 'cc'],
          ['receipt', 'read'],
        ],
        'content': '',
      };
      final info = PmLogic.parseReceipt(rumor);
      expect(info, isNotNull);
      expect(info!.messageIds, ['aa', 'bb', 'cc']);
      expect(info.receiptType, 'read');
      expect(info.messageId, 'aa');
    });

    test('a single-id receipt still parses as one', () {
      final rumor = {
        'pubkey': _pk(1),
        'created_at': 1700000000,
        'tags': [
          ['p', _pk(0)],
          ['x', 'aa'],
          ['receipt', 'delivered'],
        ],
        'content': '',
      };
      final info = PmLogic.parseReceipt(rumor);
      expect(info!.messageIds, ['aa']);
      expect(info.messageId, 'aa');
    });

    test('a receipt with no ids is not a receipt', () {
      final rumor = {
        'pubkey': _pk(1),
        'created_at': 1700000000,
        'tags': [
          ['p', _pk(0)],
          ['receipt', 'read'],
        ],
        'content': '',
      };
      expect(PmLogic.parseReceipt(rumor), isNull);
    });
  });

  group('typing carries a ttl so it need not re-broadcast every 3s', () {
    test('a start with a ttl parses it', () {
      final info = PmLogic.parseTyping({
        'pubkey': _pk(1),
        'created_at': 1700000000,
        'tags': [
          ['typing', 'start'],
          ['ttl', '15'],
          ['g', 'g1'],
        ],
        'content': '',
      });
      expect(info, isNotNull);
      expect(info!.isStart, isTrue);
      expect(info.ttlSec, 15);
      expect(info.groupId, 'g1');
    });

    test('a start without one reports no ttl, so the receiver keeps its default',
        () {
      final info = PmLogic.parseTyping({
        'pubkey': _pk(1),
        'created_at': 1700000000,
        'tags': [
          ['typing', 'start'],
        ],
        'content': '',
      });
      expect(info!.ttlSec, 0);
    });

    test('a stop still parses', () {
      final info = PmLogic.parseTyping({
        'pubkey': _pk(1),
        'created_at': 1700000000,
        'tags': [
          ['typing', 'stop'],
          ['g', 'g1'],
        ],
        'content': '',
      });
      expect(info!.isStart, isFalse);
    });
  });
}
