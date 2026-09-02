/// A channel message's KIND and its channel's SHAPE have to agree.
///
/// `channelWire` pairs them on the way out: a geohash channel is kind 20000
/// with a `g` tag, a named one is kind 23333 with a `d` tag. The ingest picked
/// WHICH tag to read from the kind but never checked the value it found, so a
/// kind 20000 carrying `['g','nymchat']` filed itself under `#nymchat` and
/// rendered among the real 23333 traffic — a message in a kind this app would
/// never send there, indistinguishable from the rest. The reverse smuggled a
/// 23333 into a geohash channel. Nothing upstream stops it: the subscription is
/// kind-only, with no tag filter.
///
/// One gate covers every way an event arrives — the live pool, the D1 backfill
/// and the mesh carrier all map through [EventMapper] — so these drive the real
/// mapper. A radio frame carries no kind at all, so the pairing rule cannot
/// apply to it; what it needs is that the name it gives itself is one the app
/// could have created.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/features/mesh/mesh_bridge.dart' show kMeshNearbyChannel;
import 'package:nym_bar/models/channel.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_mapper.dart';
import 'package:nym_bar/services/platform/deep_links.dart'
    show sanitizeChannelName;

const _self =
    '0000000000000000000000000000000000000000000000000000000000001a2b';
const _other =
    '11111111111111111111111111111111111111111111111111111111deadbeef';

NostrEvent _event(int kind, String tag, String value) => NostrEvent(
      id: 'evt-$kind-$value',
      pubkey: _other,
      createdAt: 1700000000,
      kind: kind,
      tags: [
        ['n', 'satoshi'],
        [tag, value],
      ],
      content: 'hello',
    );

void main() {
  group('the kind and the channel shape must agree', () {
    test('a geohash channel on kind 20000 is a channel message', () {
      final m = EventMapper.channelMessage(_event(EventKind.geoChannel, 'g', '9q8y'),
          selfPubkey: _self);
      expect(m, isNotNull);
      expect(m!.geohash, '9q8y');
      expect(EventMapper.channelKeyOf(_event(EventKind.geoChannel, 'g', '9q8y')),
          '#9q8y');
    });

    test('a named channel on kind 23333 is a channel message', () {
      final e = _event(EventKind.namedChannel, 'd', 'nymchat');
      final m = EventMapper.channelMessage(e, selfPubkey: _self);
      expect(m, isNotNull);
      expect(m!.channel, 'nymchat');
      expect(EventMapper.channelKeyOf(e), '#nymchat');
    });

    test('a named channel smuggled in on kind 20000 is dropped', () {
      final e = _event(EventKind.geoChannel, 'g', 'nymchat');
      expect(EventMapper.channelMessage(e, selfPubkey: _self), isNull);
      expect(EventMapper.channelKeyOf(e), isNull,
          reason: 'nothing may key, notify or receipt on it either');
    });

    test('a geohash smuggled in on kind 23333 is dropped', () {
      final e = _event(EventKind.namedChannel, 'd', 'u4pruy');
      expect(EventMapper.channelMessage(e, selfPubkey: _self), isNull);
      expect(EventMapper.channelKeyOf(e), isNull);
    });

    test('the tag has to be the one the kind names', () {
      // A 20000 carrying only a `d` tag has no channel at all.
      expect(
          EventMapper.channelMessage(_event(EventKind.geoChannel, 'd', 'u4pruy'),
              selfPubkey: _self),
          isNull);
      expect(
          EventMapper.channelMessage(
              _event(EventKind.namedChannel, 'g', 'nymchat'),
              selfPubkey: _self),
          isNull);
    });

    test('an empty channel tag is dropped', () {
      expect(
          EventMapper.channelMessage(_event(EventKind.geoChannel, 'g', ''),
              selfPubkey: _self),
          isNull);
    });

    test('a non-channel kind is still not a channel message', () {
      expect(
          EventMapper.channelMessage(_event(EventKind.reaction, 'g', '9q8y'),
              selfPubkey: _self),
          isNull);
    });
  });

  group('the gate accepts exactly what channelWire sends', () {
    // Short words that ARE valid geohashes (mesh, dev) travel as geohash
    // channels; the gate has to agree with that rather than with intuition.
    for (final name in const [
      'u4pruy',
      '9q8yy',
      'mesh',
      'dev',
      'nymchat',
      'bitcoin',
      'crew',
    ]) {
      test('#$name round-trips through its own wire', () {
        final wire = channelWire(name);
        final ok = _event(wire.kind, wire.tag, name);
        expect(EventMapper.channelMessage(ok, selfPubkey: _self), isNotNull,
            reason: '#$name is sent as ${wire.kind}/${wire.tag}');
        expect(EventMapper.channelKeyOf(ok), '#$name');

        final other = wire.isGeohash
            ? (EventKind.namedChannel, 'd')
            : (EventKind.geoChannel, 'g');
        final wrong = _event(other.$1, other.$2, name);
        expect(EventMapper.channelMessage(wrong, selfPubkey: _self), isNull,
            reason: '#$name must be refused as ${other.$1}/${other.$2}');
        expect(EventMapper.channelKeyOf(wrong), isNull);
      });
    }
  });

  group('a radio frame names its own channel', () {
    // A mesh frame carries no event kind, so the pairing rule cannot apply —
    // but the name still has to be one the app could have created. This is the
    // derivation MeshBridge._onPublic runs on an inbound frame.
    String meshKey(String? raw) {
      final base = (raw == null || raw.isEmpty)
          ? kMeshNearbyChannel
          : (raw.startsWith('#') ? raw.substring(1) : raw);
      final sanitized = sanitizeChannelName(base);
      return sanitized.isEmpty ? kMeshNearbyChannel : sanitized;
    }

    test('a legal channel name is kept', () => expect(meshKey('crew'), 'crew'));
    test('a leading # is stripped', () => expect(meshKey('#crew'), 'crew'));
    test('a malformed name falls back to Nearby rather than creating a junk '
        'channel', () => expect(meshKey('has space'), 'mesh'));
    test('an unnamed frame is a Nearby message',
        () => expect(meshKey(null), 'mesh'));
    test('the name is normalised the way every other channel key is',
        () => expect(meshKey('NYMCHAT'), 'nymchat'));

    test('a mesh message carries the kind its channel would travel under', () {
      // The row hardcoded 20000 for every mesh channel. A named one is 23333,
      // so a reaction to a mesh message now carries the same `k` the relay copy
      // would. ('radio' has an a/i/o, so it is a named channel; 'mesh' and
      // 'crew' are legal geohashes and really do travel as 20000.)
      expect(channelWire(meshKey('radio')).kind, EventKind.namedChannel);
      expect(channelWire(meshKey('crew')).kind, EventKind.geoChannel);
      expect(channelWire(meshKey(null)).kind, EventKind.geoChannel);
    });
  });
}
