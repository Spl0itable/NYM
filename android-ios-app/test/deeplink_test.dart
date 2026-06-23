import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/services/firebase_messaging_service.dart';
import 'package:nym_bar/services/platform/deep_links.dart';

/// A valid base64url invite token: {v:1, g:<64 hex>, a:<64 hex>, e:7, n:"My Group"}.
const String kValidInviteToken =
    'eyJ2IjoxLCJnIjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsImEiOiJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiIiwiZSI6NywibiI6Ik15IEdyb3VwIn0';

/// Captures controller calls so the dispatch decision can be asserted without a
/// real `NostrController` (no networking, no Firebase, no permissions).
class _FakeTarget implements DeepLinkTarget {
  final List<({String channel, String geohash})> channelSwitches = [];
  final List<({String pubkey, String? nym})> pmStarts = [];
  final List<GroupInviteToken> invites = [];

  @override
  void switchChannel(String channel, {String geohash = ''}) =>
      channelSwitches.add((channel: channel, geohash: geohash));

  @override
  void startPM(String peerPubkey, {String? nym}) =>
      pmStarts.add((pubkey: peerPubkey, nym: nym));

  @override
  Future<void> joinGroupViaInvite(GroupInviteToken token) async =>
      invites.add(token);
}

void main() {
  group('parseNymLink', () {
    test('plain named channel → channel', () {
      final link = parseNymLink('https://app.nymchat.app/#bitcoin');
      expect(link, isNotNull);
      expect(link!.kind, NymLinkKind.channel);
      expect(link.channel, 'bitcoin');
    });

    test('lowercases a named channel', () {
      final link = parseNymLink('https://app.nymchat.app/#Bitcoin');
      expect(link!.kind, NymLinkKind.channel);
      expect(link.channel, 'bitcoin');
    });

    test('geohash fragment → geohash', () {
      final link = parseNymLink('https://app.nymchat.app/#9q8y');
      expect(link, isNotNull);
      expect(link!.kind, NymLinkKind.geohash);
      expect(link.channel, '9q8y');
    });

    test('#g:<id> → channelRef (g)', () {
      final link = parseNymLink('https://app.nymchat.app/#g:9q8y');
      expect(link, isNotNull);
      expect(link!.kind, NymLinkKind.channelRef);
      expect(link.refPrefix, 'g');
      expect(link.channel, '9q8y');
    });

    test('#c:<id> → channelRef (c)', () {
      final link = parseNymLink('https://app.nymchat.app/#c:foo');
      expect(link, isNotNull);
      expect(link!.kind, NymLinkKind.channelRef);
      expect(link.refPrefix, 'c');
      expect(link.channel, 'foo');
    });

    test('#e:<id> → channelRef (e)', () {
      // The PWA emits `e:<hex event id>`; the id is sanitized like a channel
      // name (letters + digits only), so a hex id survives.
      final link =
          parseNymLink('https://app.nym.bar/#e:deadbeef0123456789abcdef');
      expect(link, isNotNull);
      expect(link!.kind, NymLinkKind.channelRef);
      expect(link.refPrefix, 'e');
      expect(link.channel, 'deadbeef0123456789abcdef');
    });

    test('#gjoin=<token> → groupInvite with parsed payload', () {
      final link = parseNymLink('https://app.nymchat.app/#gjoin=$kValidInviteToken');
      expect(link, isNotNull);
      expect(link!.kind, NymLinkKind.groupInvite);
      expect(link.inviteToken, kValidInviteToken);
      expect(link.invite, isNotNull);
      expect(link.invite!.groupId, 'a' * 64);
      expect(link.invite!.approver, 'b' * 64);
      expect(link.invite!.epoch, 7);
      expect(link.invite!.name, 'My Group');
    });

    test('invite token is not lowercased (case-sensitive base64url)', () {
      final link = parseNymLink('https://app.nymchat.app/#gjoin=$kValidInviteToken');
      expect(link!.inviteToken, kValidInviteToken); // preserves mixed case
    });

    test('non-nym URL → null', () {
      expect(parseNymLink('https://example.com/#bitcoin'), isNull);
      expect(parseNymLink('https://google.com/'), isNull);
    });

    test('nym URL without a fragment → null', () {
      expect(parseNymLink('https://app.nymchat.app/'), isNull);
    });

    test('garbage / empty input → null', () {
      expect(parseNymLink(''), isNull);
      expect(parseNymLink('not a url'), isNull);
    });

    test('a fragment with invalid channel chars → null', () {
      // sanitizeChannelName REJECTS (not strips) non letter/digit chars.
      expect(parseNymLink('https://app.nymchat.app/#a b'), isNull);
    });
  });

  group('parseGroupInvite', () {
    test('accepts a bare valid token', () {
      final t = parseGroupInvite(kValidInviteToken);
      expect(t, isNotNull);
      expect(t!.groupId, 'a' * 64);
    });

    test('accepts a full #gjoin= input', () {
      final t = parseGroupInvite('https://app.nymchat.app/#gjoin=$kValidInviteToken');
      expect(t, isNotNull);
      expect(t!.epoch, 7);
    });

    test('rejects malformed token', () {
      expect(parseGroupInvite('not-base64-json'), isNull);
      expect(parseGroupInvite(''), isNull);
    });
  });

  group('dispatchNymLink', () {
    test('geohash → switchChannel(channel, geohash)', () {
      final t = _FakeTarget();
      final ok = dispatchNymLink(NymLink.geohash('9q8y'), t);
      expect(ok, isTrue);
      expect(t.channelSwitches.single.channel, '9q8y');
      expect(t.channelSwitches.single.geohash, '9q8y');
    });

    test('named channel → switchChannel(channel, geohash:"")', () {
      final t = _FakeTarget();
      final ok = dispatchNymLink(NymLink.channel('bitcoin'), t);
      expect(ok, isTrue);
      expect(t.channelSwitches.single.channel, 'bitcoin');
      expect(t.channelSwitches.single.geohash, '');
    });

    test('channelRef → switchChannel', () {
      final t = _FakeTarget();
      final ok = dispatchNymLink(NymLink.channelRef('c', 'foo'), t);
      expect(ok, isTrue);
      expect(t.channelSwitches.single.channel, 'foo');
    });

    test('group invite → joinGroupViaInvite', () {
      final t = _FakeTarget();
      final link =
          parseNymLink('https://app.nymchat.app/#gjoin=$kValidInviteToken')!;
      final ok = dispatchNymLink(link, t);
      expect(ok, isTrue);
      expect(t.invites.single.groupId, 'a' * 64);
      expect(t.channelSwitches, isEmpty);
      expect(t.pmStarts, isEmpty);
    });

    test('group invite with unparseable token does not dispatch', () {
      final t = _FakeTarget();
      final link = NymLink.groupInvite('garbage', null);
      final ok = dispatchNymLink(link, t);
      expect(ok, isFalse);
      expect(t.invites, isEmpty);
    });

    test('end-to-end: each parsed type maps to the right call', () {
      final cases = <String, void Function(_FakeTarget)>{
        'https://app.nymchat.app/#bitcoin': (t) {
          expect(t.channelSwitches.single.channel, 'bitcoin');
        },
        'https://app.nymchat.app/#9q8y': (t) {
          expect(t.channelSwitches.single.geohash, '9q8y');
        },
        'https://app.nymchat.app/#c:foo': (t) {
          expect(t.channelSwitches.single.channel, 'foo');
        },
        'https://app.nymchat.app/#gjoin=$kValidInviteToken': (t) {
          expect(t.invites, hasLength(1));
        },
      };
      cases.forEach((url, assertFn) {
        final t = _FakeTarget();
        final link = parseNymLink(url);
        expect(link, isNotNull, reason: url);
        dispatchNymLink(link!, t);
        assertFn(t);
      });
    });
  });

  group('FirebaseMessagingService guard', () {
    test('initialize no-ops without Firebase and getToken returns null',
        () async {
      final svc = FirebaseMessagingService();
      // Must not throw even though no Firebase/config is present.
      await svc.initialize();
      expect(await svc.getToken(), isNull);
    });

    test('routeMessage(opened) routes a link payload to the deep-link handler',
        () async {
      final svc = FirebaseMessagingService();
      String? routed;
      await svc.initialize(onDeepLink: (url) {
        routed = url;
        return true;
      });
      await svc.routeMessage(
        {'link': 'https://app.nymchat.app/#bitcoin'},
        opened: true,
      );
      expect(routed, 'https://app.nymchat.app/#bitcoin');
    });

    test('routeMessage (foreground) surfaces a local notification with payload',
        () async {
      final svc = FirebaseMessagingService();
      String? seenPayload;
      String? seenTitle;
      await svc.initialize(
        showLocalNotification: ({
          required String title,
          required String body,
          String? payload,
        }) async {
          seenTitle = title;
          seenPayload = payload;
        },
      );
      await svc.routeMessage({
        'title': 'New message',
        'body': 'hi',
        'link': 'https://app.nymchat.app/#bitcoin',
      });
      expect(seenTitle, 'New message');
      expect(seenPayload, 'https://app.nymchat.app/#bitcoin');
    });
  });
}
