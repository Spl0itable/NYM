import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/crypto/gift_wrap.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/features/groups/group_logic.dart';
import 'package:nym_bar/features/pms/pm_logic.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

void main() {
  group('PM round-trip (NIP-17)', () {
    test('wrap to recipient, unwrap, map to a PM Message', () async {
      final senderSk = generatePrivateKey();
      final senderPk = getPublicKeyHex(senderSk);
      final recipientSk = generatePrivateKey();
      final recipientPk = getPublicKeyHex(recipientSk);

      final nymMessageId = PmLogic.generateSharedEventId();
      final rumor = PmLogic.buildPmRumor(
        selfPubkey: senderPk,
        recipientPubkey: recipientPk,
        content: 'hello over nip-17',
        nymMessageId: nymMessageId,
        nowSec: 1700000000,
        nowMs: 1700000000123,
      );

      // Rumor shape checks.
      expect(rumor.kind, EventKind.dmRumor);
      expect(GroupLogic.tagValue(rumor.tags, 'p'), recipientPk);
      expect(GroupLogic.tagValue(rumor.tags, 'x'), nymMessageId);
      expect(GroupLogic.tagValue(rumor.tags, 'ms'), '1700000000123');

      final wrap =
          nip59Wrap(rumor: rumor, senderPrivkey: senderSk, recipientPubkey: recipientPk);
      expect(wrap.kind, EventKind.giftWrap);

      final res = await unwrapGiftWrap(wrap, [(sk: recipientSk, bitchat: false)]);
      expect(res, isNotNull);
      expect(res!.rumor['content'], 'hello over nip-17');
      expect(res.rumor['pubkey'], senderPk);

      // seal.pubkey must equal rumor.pubkey for native verification.
      expect(res.seal.pubkey, senderPk);

      final m = PmLogic.mapPmRumor(
        rumor: res.rumor,
        wrapId: wrap.id,
        selfPubkey: recipientPk,
        senderVerified: true,
      );
      expect(m, isNotNull);
      expect(m!.isPM, isTrue);
      expect(m.isOwn, isFalse);
      expect(m.pubkey, senderPk);
      expect(m.content, 'hello over nip-17');
      expect(m.nymMessageId, nymMessageId);
      expect(m.conversationPubkey, senderPk);
      expect(m.conversationKey, 'pm-$senderPk');
      expect(m.senderVerified, isTrue);
    });

    test('self-copy maps with isOwn and peer from the p tag', () async {
      final selfSk = generatePrivateKey();
      final selfPk = getPublicKeyHex(selfSk);
      final peerPk = getPublicKeyHex(generatePrivateKey());

      final rumor = PmLogic.buildPmRumor(
        selfPubkey: selfPk,
        recipientPubkey: peerPk,
        content: 'self copy',
        nymMessageId: PmLogic.generateSharedEventId(),
      );
      final selfWrap =
          nip59Wrap(rumor: rumor, senderPrivkey: selfSk, recipientPubkey: selfPk);
      final res = await unwrapGiftWrap(selfWrap, [(sk: selfSk, bitchat: false)]);
      final m = PmLogic.mapPmRumor(
        rumor: res!.rumor,
        wrapId: selfWrap.id,
        selfPubkey: selfPk,
        senderVerified: true,
      );
      expect(m!.isOwn, isTrue);
      expect(m.conversationPubkey, peerPk); // peer from p tag, not self
      expect(m.conversationKey, 'pm-$peerPk');
    });
  });

  group('Group control events', () {
    Group makeGroup(String owner, List<String> members, {List<String>? mods}) =>
        Group(
          id: GroupLogic.generateGroupId(),
          name: 'test',
          members: [owner, ...members],
          createdBy: owner,
          mods: mods,
        );

    test('owner remove-member removes the member', () {
      final owner = 'owner';
      final victim = 'victim';
      final g = makeGroup(owner, [victim, 'other']);
      final r = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.removeMember,
        tags: [
          ['kick', victim],
        ],
        senderPubkey: owner,
        ts: 100,
        eventId: 'e1',
      );
      expect(r, GroupControlResult.applied);
      expect(g.members, isNot(contains(victim)));
      expect(g.modLog.last.type, 'kick');
    });

    test('ban removes and adds to banned', () {
      final g = makeGroup('owner', ['victim']);
      final r = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.removeMember,
        tags: [
          ['kick', 'victim'],
          ['ban', '1'],
        ],
        senderPubkey: 'owner',
        ts: 10,
        eventId: 'e1',
      );
      expect(r, GroupControlResult.applied);
      expect(g.banned, contains('victim'));
    });

    test('non-owner / non-mod remove is rejected', () {
      final g = makeGroup('owner', ['member', 'victim']);
      final r = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.removeMember,
        tags: [
          ['kick', 'victim'],
        ],
        senderPubkey: 'member', // not owner/mod
        ts: 100,
        eventId: 'e1',
      );
      expect(r, GroupControlResult.unauthorized);
      expect(g.members, contains('victim'));
    });

    test('mod cannot kick the owner or another mod', () {
      final g = makeGroup('owner', ['mod1', 'mod2', 'victim'],
          mods: ['mod1', 'mod2']);
      final kickOwner = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.removeMember,
        tags: [
          ['kick', 'owner'],
        ],
        senderPubkey: 'mod1',
        ts: 5,
        eventId: 'eOwner',
      );
      expect(kickOwner, GroupControlResult.unauthorized);
      final kickMod = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.removeMember,
        tags: [
          ['kick', 'mod2'],
        ],
        senderPubkey: 'mod1',
        ts: 6,
        eventId: 'eMod',
      );
      expect(kickMod, GroupControlResult.unauthorized);
      // A mod can kick a plain member.
      final kickMember = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.removeMember,
        tags: [
          ['kick', 'victim'],
        ],
        senderPubkey: 'mod1',
        ts: 7,
        eventId: 'eVic',
      );
      expect(kickMember, GroupControlResult.applied);
      expect(g.members, isNot(contains('victim')));
    });

    test('stale (older ts) mod event is ignored', () {
      final g = makeGroup('owner', ['a', 'b']);
      // First event at ts 100 succeeds.
      final first = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.promoteMod,
        tags: [
          ['mod', 'a'],
        ],
        senderPubkey: 'owner',
        ts: 100,
        eventId: 'e1',
      );
      expect(first, GroupControlResult.applied);
      expect(g.mods, contains('a'));
      // A later event with an EARLIER ts is stale.
      final stale = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.removeMember,
        tags: [
          ['kick', 'b'],
        ],
        senderPubkey: 'owner',
        ts: 50, // < lastModTs (100)
        eventId: 'e2',
      );
      expect(stale, GroupControlResult.stale);
      expect(g.members, contains('b')); // unchanged
    });

    test('promote / revoke / transfer are owner-only', () {
      final g = makeGroup('owner', ['a', 'b'], mods: ['a']);
      expect(
        GroupLogic.applyControlEvent(
          group: g,
          type: GroupControlType.promoteMod,
          tags: [
            ['mod', 'b'],
          ],
          senderPubkey: 'a', // mod, not owner
          ts: 10,
          eventId: 'e',
        ),
        GroupControlResult.unauthorized,
      );
      expect(
        GroupLogic.applyControlEvent(
          group: g,
          type: GroupControlType.transferOwner,
          tags: [
            ['owner', 'a'],
          ],
          senderPubkey: 'owner',
          ts: 20,
          eventId: 'e2',
        ),
        GroupControlResult.applied,
      );
      expect(g.createdBy, 'a');
      expect(g.mods, isNot(contains('a'))); // new owner dropped from mods
    });
  });

  group('Ephemeral key rotation', () {
    test('sending twice advances current → prev and advertises new pk', () {
      final ek = GroupEphemeralKeys();
      final first = ek.rotateSelf();
      final firstPk = first.pk;
      expect(ek.selfCurrent!.pk, firstPk);
      expect(ek.selfPrev, isEmpty);

      final second = ek.rotateSelf();
      expect(second.pk, isNot(firstPk)); // new advertised key
      expect(ek.selfCurrent!.pk, second.pk);
      expect(ek.selfPrev.first.pk, firstPk); // previous retained
    });

    test('prev keys are capped at 30', () {
      final ek = GroupEphemeralKeys();
      for (var i = 0; i < 40; i++) {
        ek.rotateSelf();
      }
      expect(ek.selfPrev.length, kEphemeralPrevKeysMax);
    });

    test('member key updates respect timestamp ordering', () {
      final ek = GroupEphemeralKeys();
      ek.updateMemberKey('peer', 'pkNew', 200);
      ek.updateMemberKey('peer', 'pkOld', 100); // stale, ignored
      expect(ek.members['peer'], 'pkNew');
      ek.updateMemberKey('peer', 'pkNewer', 300);
      expect(ek.members['peer'], 'pkNewer');
    });

    test('encryptionPubkeyFor uses ephemeral when known, real otherwise', () {
      final ek = GroupEphemeralKeys();
      ek.ensureSelf();
      ek.updateMemberKey('peer', 'peerEph', 50);
      expect(ek.encryptionPubkeyFor('peer', 'self'), 'peerEph');
      expect(ek.encryptionPubkeyFor('stranger', 'self'), 'stranger');
      // Self-copy uses our own current ephemeral key.
      expect(ek.encryptionPubkeyFor('self', 'self'), ek.selfCurrent!.pk);
    });
  });

  group('Receipt / typing parse (kind 69420)', () {
    Map<String, dynamic> rumorWith(List<List<String>> tags) => {
          'kind': EventKind.nymReceiptRumor,
          'pubkey': 'peerpk',
          'created_at': 1700000000,
          'tags': tags,
          'content': '',
        };

    test('read receipt advances delivery status', () {
      final rumor = rumorWith([
        ['p', 'me'],
        ['x', 'MSGID123'],
        ['receipt', 'read'],
      ]);
      expect(PmLogic.isReceipt(rumor), isTrue);
      final info = PmLogic.parseReceipt(rumor)!;
      expect(info.messageId, 'MSGID123');
      expect(info.receiptType, 'read');
      expect(PmLogic.deliveryFromReceipt(info.receiptType), DeliveryStatus.read);
      // status ordering only advances.
      expect(
        PmLogic.statusOrder(DeliveryStatus.read) >
            PmLogic.statusOrder(DeliveryStatus.delivered),
        isTrue,
      );
    });

    test('typing start/stop parse with group id', () {
      final start = rumorWith([
        ['typing', 'start'],
        ['g', 'group123'],
      ]);
      expect(PmLogic.isTyping(start), isTrue);
      final info = PmLogic.parseTyping(start)!;
      expect(info.isStart, isTrue);
      expect(info.groupId, 'group123');
      expect(info.pubkey, 'peerpk');

      final stop = rumorWith([
        ['typing', 'stop'],
        ['p', 'me'],
      ]);
      expect(PmLogic.parseTyping(stop)!.isStart, isFalse);
    });

    test('a receipt is not mistaken for a message rumor', () {
      final rumor = rumorWith([
        ['x', 'mid'],
        ['receipt', 'delivered'],
      ]);
      // kind is 69420 not 14, so mapPmRumor rejects it.
      expect(
        PmLogic.mapPmRumor(
          rumor: rumor,
          wrapId: 'w',
          selfPubkey: 'me',
          senderVerified: true,
        ),
        isNull,
      );
    });
  });

  group('Closed PM re-open semantics', () {
    Message pmFrom(String peer, String content, int createdAtSec) => Message(
          id: 'pm_${peer}_$createdAtSec',
          author: 'peer#0001',
          pubkey: peer,
          content: content,
          createdAt: createdAtSec,
          isPM: true,
          conversationKey: 'pm-$peer',
          conversationPubkey: peer,
        );

    test('stale backlog stays suppressed but a newer message re-opens', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      const peer = 'peerpk';

      // Seed a conversation, then close it at t=1000.
      n.ingestPMMessage(pmFrom(peer, 'first', 900));
      expect(n.state.messages.containsKey('pm-$peer'), isTrue);
      n.closePM(peer, nowSec: 1000);
      expect(n.state.messages.containsKey('pm-$peer'), isFalse);
      expect(n.closedPMs.contains(peer), isTrue);

      // Older relay backlog (t=950 < 1000) must NOT resurrect the thread.
      n.ingestPMMessage(pmFrom(peer, 'stale backlog', 950));
      expect(n.state.messages.containsKey('pm-$peer'), isFalse);
      expect(n.closedPMs.contains(peer), isTrue);

      // A genuinely newer message (t=1100 > 1000) re-opens the conversation.
      n.ingestPMMessage(pmFrom(peer, 'new ping', 1100));
      expect(n.state.messages['pm-$peer']!.single.content, 'new ping');
      expect(n.closedPMs.contains(peer), isFalse);
    });
  });

  group('Group message rumor', () {
    test('carries p-per-member, g, type, x, ephemeral_pk, ms tags', () {
      final g = Group(
        id: GroupLogic.generateGroupId(),
        name: 'grp',
        members: ['self', 'a', 'b'],
        createdBy: 'self',
      );
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: g,
        selfPubkey: 'self',
        content: 'hi group',
        nymMessageId: 'nmid',
        ephemeralPk: 'ephpk',
        nowSec: 1700000000,
        nowMs: 1700000000999,
      );
      expect(rumor.kind, EventKind.dmRumor);
      expect(rumor.tags.where((t) => t[0] == 'p').length, 3);
      expect(GroupLogic.tagValue(rumor.tags, 'g'), g.id);
      expect(GroupLogic.tagValue(rumor.tags, 'type'), GroupControlType.message);
      expect(GroupLogic.tagValue(rumor.tags, 'x'), 'nmid');
      expect(GroupLogic.tagValue(rumor.tags, 'ephemeral_pk'), 'ephpk');
      expect(GroupLogic.tagValue(rumor.tags, 'ms'), '1700000000999');
    });

    test('round-trips through a gift wrap to a member', () async {
      final selfSk = generatePrivateKey();
      final selfPk = getPublicKeyHex(selfSk);
      final memberSk = generatePrivateKey();
      final memberPk = getPublicKeyHex(memberSk);
      final g = Group(
        id: GroupLogic.generateGroupId(),
        name: 'grp',
        members: [selfPk, memberPk],
        createdBy: selfPk,
      );
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: g,
        selfPubkey: selfPk,
        content: 'group payload',
        nymMessageId: 'nmid2',
        ephemeralPk: 'ephpk',
      );
      final wrap =
          nip59Wrap(rumor: rumor, senderPrivkey: selfSk, recipientPubkey: memberPk);
      final res = await unwrapGiftWrap(wrap, [(sk: memberSk, bitchat: false)]);
      expect(res, isNotNull);
      expect(res!.rumor['content'], 'group payload');
      final tags = (res.rumor['tags'] as List)
          .map((t) => (t as List).map((e) => e.toString()).toList())
          .toList();
      expect(GroupLogic.tagValue(tags, 'g'), g.id);
      expect(GroupLogic.tagValue(tags, 'x'), 'nmid2');
      // Confirm the seal JSON serialized cleanly.
      expect(jsonEncode(res.seal.toJson()), isA<String>());
    });
  });
}
