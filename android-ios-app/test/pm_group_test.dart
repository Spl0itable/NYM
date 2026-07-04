import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/crypto/gift_wrap.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/features/groups/group_logic.dart';
import 'package:nym_bar/features/pms/pm_logic.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
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

    test('inbound group-leave removes the departing sender (F04-H1)', () {
      final g = makeGroup('owner', ['leaver', 'other'], mods: ['leaver']);
      final r = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.leave,
        tags: const [
          ['p', 'owner'],
          ['p', 'other'],
        ],
        senderPubkey: 'leaver',
        ts: 100,
        eventId: 'eLeave',
      );
      expect(r, GroupControlResult.applied);
      expect(g.members, isNot(contains('leaver')));
      expect(g.mods, isNot(contains('leaver'))); // departed mod also dropped
      expect(g.members, contains('other'));
      expect(g.modLog.last.type, 'leave');
      // A leave from a non-member is a no-op.
      final r2 = GroupLogic.applyControlEvent(
        group: g,
        type: GroupControlType.leave,
        tags: const [],
        senderPubkey: 'stranger',
        ts: 101,
        eventId: 'eLeave2',
      );
      expect(r2, GroupControlResult.noop);
    });

    test('delete-message authorizes owner/mod, blocks others (F04-B4)', () {
      Group g() => makeGroup('owner', ['mod1', 'member'], mods: ['mod1']);

      // Owner can delete anyone's message.
      final byOwner = GroupLogic.applyControlEvent(
        group: g(),
        type: GroupControlType.deleteMessage,
        tags: const [
          ['e', 'msg1'],
          ['target_pubkey', 'member'],
        ],
        senderPubkey: 'owner',
        ts: 10,
        eventId: 'd1',
      );
      expect(byOwner, GroupControlResult.applied);

      // Mod can delete a plain member's message.
      final gm = g();
      final byMod = GroupLogic.applyControlEvent(
        group: gm,
        type: GroupControlType.deleteMessage,
        tags: const [
          ['e', 'msg2'],
          ['target_pubkey', 'member'],
        ],
        senderPubkey: 'mod1',
        ts: 11,
        eventId: 'd2',
      );
      expect(byMod, GroupControlResult.applied);
      expect(gm.modLog.last.type, 'delete-message');
      expect(gm.modLog.last.messageId, 'msg2');

      // Mod CANNOT delete the owner's message.
      final modVsOwner = GroupLogic.applyControlEvent(
        group: g(),
        type: GroupControlType.deleteMessage,
        tags: const [
          ['e', 'msg3'],
          ['target_pubkey', 'owner'],
        ],
        senderPubkey: 'mod1',
        ts: 12,
        eventId: 'd3',
      );
      expect(modVsOwner, GroupControlResult.unauthorized);

      // A plain member can't delete anything.
      final byMember = GroupLogic.applyControlEvent(
        group: g(),
        type: GroupControlType.deleteMessage,
        tags: const [
          ['e', 'msg4'],
          ['target_pubkey', 'mod1'],
        ],
        senderPubkey: 'member',
        ts: 13,
        eventId: 'd4',
      );
      expect(byMember, GroupControlResult.unauthorized);

      // Missing `e` tag → invalid.
      final noTarget = GroupLogic.applyControlEvent(
        group: g(),
        type: GroupControlType.deleteMessage,
        tags: const [
          ['target_pubkey', 'member'],
        ],
        senderPubkey: 'owner',
        ts: 14,
        eventId: 'd5',
      );
      expect(noTarget, GroupControlResult.invalid);
    });
  });

  group('applyGroupControl message-store side effects (F04-B4)', () {
    Message groupMsg(String gid, String id, String author) => Message(
          id: id,
          nymMessageId: id,
          pubkey: author,
          author: 'm#$author',
          content: 'hi',
          createdAt: 1000,
          isGroup: true,
          groupId: gid,
          conversationKey: GroupLogic.groupStorageKey(gid),
        );

    test('inbound delete-message removes the target from the store', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      final g = Group(
        id: GroupLogic.generateGroupId(),
        name: 'g',
        members: ['owner', 'mod1', 'member', 'selfpk'],
        createdBy: 'owner',
        mods: ['mod1'],
      );
      n.upsertGroup(g);
      n.ingestGroupMessage(groupMsg(g.id, 'msgX', 'member'));
      final key = GroupLogic.groupStorageKey(g.id);
      expect(n.state.messages[key]!.map((m) => m.id), contains('msgX'));

      // A mod deletes the member's message → it's removed locally for everyone.
      final r = n.applyGroupControl(
        groupId: g.id,
        type: GroupControlType.deleteMessage,
        tags: const [
          ['e', 'msgX'],
          ['target_pubkey', 'member'],
        ],
        senderPubkey: 'mod1',
        ts: 10,
        eventId: 'del1',
      );
      expect(r, GroupControlResult.applied);
      expect(n.state.messages[key]!.map((m) => m.id), isNot(contains('msgX')));
    });

    test('unauthorized delete (plain member) leaves the message intact', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      final g = Group(
        id: GroupLogic.generateGroupId(),
        name: 'g',
        members: ['owner', 'member', 'selfpk'],
        createdBy: 'owner',
      );
      n.upsertGroup(g);
      n.ingestGroupMessage(groupMsg(g.id, 'msgY', 'owner'));
      final key = GroupLogic.groupStorageKey(g.id);

      final r = n.applyGroupControl(
        groupId: g.id,
        type: GroupControlType.deleteMessage,
        tags: const [
          ['e', 'msgY'],
          ['target_pubkey', 'owner'],
        ],
        senderPubkey: 'member', // not owner/mod
        ts: 11,
        eventId: 'del2',
      );
      expect(r, GroupControlResult.unauthorized);
      expect(n.state.messages[key]!.map((m) => m.id), contains('msgY'));
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

    test('onClosedPmsChanged fires on close/re-open; hydrate restores (F02)', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      var fired = 0;
      n.onClosedPmsChanged = () => fired++;
      const peer = 'peerpk';

      n.closePM(peer, nowSec: 1000);
      expect(fired, 1, reason: 'close must notify for persistence');
      expect(n.closedPMs.contains(peer), isTrue);
      expect(n.closedPmTimes[peer], 1000);

      // A strictly-newer inbound re-opens AND notifies again (so the re-open is
      // persisted, not undone on relaunch).
      n.ingestPMMessage(pmFrom(peer, 'newer', 1100));
      expect(fired, 2);
      expect(n.closedPMs.contains(peer), isFalse);

      // Hydration restores a persisted closed set on a fresh store.
      final n2 = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n2.hydrateClosedPMs({peer}, {peer: 2000});
      expect(n2.closedPMs.contains(peer), isTrue);
      // Backlog at/under the close time stays suppressed after hydration.
      n2.ingestPMMessage(pmFrom(peer, 'old backlog', 1500));
      expect(n2.state.messages.containsKey('pm-$peer'), isFalse);
    });
  });

  group('Group message rumor', () {
    test('carries p-per-member, g, x, ephemeral_pk, ms tags but NO type tag',
        () {
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
      // F04-M4: a plain group message carries no `type` tag (matches
      // groups.js sendGroupMessage, which never pushes one).
      expect(GroupLogic.tagValue(rumor.tags, 'type'), isNull);
      expect(GroupLogic.tagValue(rumor.tags, 'x'), 'nmid');
      expect(GroupLogic.tagValue(rumor.tags, 'ephemeral_pk'), 'ephpk');
      expect(GroupLogic.tagValue(rumor.tags, 'ms'), '1700000000999');
    });

    test('threads extraTags (emoji/imeta/offer) after ms in PWA push order',
        () {
      final g = Group(
        id: GroupLogic.generateGroupId(),
        name: 'grp',
        members: ['self', 'a'],
        createdBy: 'self',
      );
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: g,
        selfPubkey: 'self',
        content: 'hi :smile:',
        nymMessageId: 'nmid',
        ephemeralPk: 'ephpk',
        nowMs: 1700000000999,
        extraTags: const [
          ['emoji', 'smile', 'https://example/smile.png'],
          ['offer', '{"hash":"abc"}'],
        ],
      );
      expect(GroupLogic.tagValue(rumor.tags, 'emoji'), 'smile');
      expect(GroupLogic.tagValue(rumor.tags, 'offer'), '{"hash":"abc"}');
      // extraTags are appended after the `ms` tag (PWA push order).
      final msIdx = rumor.tags.indexWhere((t) => t[0] == 'ms');
      final emojiIdx = rumor.tags.indexWhere((t) => t[0] == 'emoji');
      expect(emojiIdx, greaterThan(msIdx));
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

  group('Channel read receipts (kind 24421)', () {
    const selfPk =
        '1111111111111111111111111111111111111111111111111111111111111111';
    const readerPk =
        '2222222222222222222222222222222222222222222222222222222222222222';
    const msgId =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const geohash = '9q8y';

    // Ingests one OWN channel message (kind 20000) so it carries reader avatars.
    void ingestOwnChannelMessage(AppStateNotifier n, {String id = msgId}) {
      n.ingestEvent(NostrEvent(
        id: id,
        pubkey: selfPk,
        createdAt: 1700000000,
        kind: EventKind.geoChannel,
        tags: [
          ['g', geohash],
          ['n', 'me'],
        ],
        content: 'hello channel',
      ));
    }

    test('applyChannelReader populates an own message readers map', () {
      final n = AppStateNotifier()..goLive(selfPk, 'me#1111');
      ingestOwnChannelMessage(n);
      n.applyChannelReader(
        messageId: msgId,
        readerPubkey: readerPk,
        readerNym: 'neo#2222',
      );
      final msg = n.state.messages['#$geohash']!
          .firstWhere((m) => m.id == msgId);
      expect(msg.readers[readerPk], 'neo#2222');
      expect(msg.readers.length, 1);
    });

    test('a receipt that arrives before its message is replayed on landing', () {
      final n = AppStateNotifier()..goLive(selfPk, 'me#1111');
      // Receipt first — no message yet, so nothing to mirror onto.
      n.applyChannelReader(
        messageId: msgId,
        readerPubkey: readerPk,
        readerNym: 'neo#2222',
      );
      // Message lands afterwards → readers get attached.
      ingestOwnChannelMessage(n);
      final msg = n.state.messages['#$geohash']!
          .firstWhere((m) => m.id == msgId);
      expect(msg.readers[readerPk], 'neo#2222');
    });

    test('self and blocked readers are ignored', () {
      final n = AppStateNotifier()..goLive(selfPk, 'me#1111');
      ingestOwnChannelMessage(n);
      // Our own receipt is dropped.
      n.applyChannelReader(
        messageId: msgId,
        readerPubkey: selfPk,
        readerNym: 'me#1111',
      );
      // A blocked reader is dropped.
      n.hydrateSocialState(
        friends: const {},
        blockedUsers: const {readerPk},
        blockedKeywords: const {},
      );
      n.applyChannelReader(
        messageId: msgId,
        readerPubkey: readerPk,
        readerNym: 'neo#2222',
      );
      final msg = n.state.messages['#$geohash']!
          .firstWhere((m) => m.id == msgId);
      expect(msg.readers, isEmpty);
    });

    test('multiple readers accumulate; newest nym wins per reader', () {
      final n = AppStateNotifier()..goLive(selfPk, 'me#1111');
      ingestOwnChannelMessage(n);
      const readerPk2 =
          '3333333333333333333333333333333333333333333333333333333333333333';
      n.applyChannelReader(
          messageId: msgId, readerPubkey: readerPk, readerNym: 'neo#2222');
      n.applyChannelReader(
          messageId: msgId, readerPubkey: readerPk2, readerNym: 'trin#3333');
      // Same reader sends an updated display name.
      n.applyChannelReader(
          messageId: msgId, readerPubkey: readerPk, readerNym: 'neo2#2222');
      final msg = n.state.messages['#$geohash']!
          .firstWhere((m) => m.id == msgId);
      expect(msg.readers.length, 2);
      expect(msg.readers[readerPk], 'neo2#2222');
      expect(msg.readers[readerPk2], 'trin#3333');
    });
  });
}
