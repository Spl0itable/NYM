// Gossip-synced public history: the memory the controlled flood does not have.
//
// A public message reaches whoever is in radio range at that instant and
// nobody else. Walk in a minute late, or be in a mesh partition that never
// touched the sender's, and it is simply gone. These cover the reconciliation
// that fixes that — and, just as importantly, that its wire format is bitchat's
// rather than a lookalike, since a filter neither client can decode syncs
// nothing at all.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/protocol/bitchat_packet.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_message_type.dart';
import 'package:nym_bar/services/mesh/sync/gcs_filter.dart';
import 'package:nym_bar/services/mesh/sync/gossip_sync.dart';
import 'package:nym_bar/services/mesh/sync/request_sync_packet.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

Uint8List _sender(int n) => _bytes([0, 0, 0, 0, 0, 0, 0, n]);

BitchatPacket _pkt({
  int type = MeshMessageType.message,
  int sender = 1,
  required int tsMs,
  String content = 'hello',
  Uint8List? recipient,
}) =>
    BitchatPacket(
      type: type,
      senderID: _sender(sender),
      recipientID: recipient ?? kBroadcastRecipient,
      timestamp: tsMs,
      payload: _bytes(content.codeUnits),
      ttl: 7,
    );

void main() {
  const now = 1700000000000;
  int clock() => now;

  group('GCS filter', () {
    test('every id it encoded is found again', () {
      final ids = [
        for (var i = 0; i < 50; i++)
          packetIdFor(
            type: MeshMessageType.message,
            senderID: _sender(1),
            timestampMs: now + i,
            payload: _bytes('m$i'.codeUnits),
          ),
      ];
      final params =
          GcsFilter.buildFilter(ids: ids, maxBytes: 400, targetFpr: 0.01);
      expect(params.includedCount, ids.length);
      final decoded = GcsFilter.decodeToSortedSet(
          p: params.p, m: params.m, data: params.data);
      for (final id in ids) {
        expect(
          GcsFilter.contains(decoded, GcsFilter.bucket(id, params.m)),
          isTrue,
          reason: 'a filter that loses an id re-sends a message forever',
        );
      }
    });

    test('an id it never saw is almost always absent', () {
      // The whole design trades a small false-positive rate for size. What must
      // hold is that the rate is small — not that it is zero.
      final ids = [
        for (var i = 0; i < 40; i++)
          packetIdFor(
            type: MeshMessageType.message,
            senderID: _sender(1),
            timestampMs: now + i,
            payload: _bytes('in$i'.codeUnits),
          ),
      ];
      final params =
          GcsFilter.buildFilter(ids: ids, maxBytes: 400, targetFpr: 0.01);
      final decoded = GcsFilter.decodeToSortedSet(
          p: params.p, m: params.m, data: params.data);
      var falsePositives = 0;
      for (var i = 0; i < 400; i++) {
        final absent = packetIdFor(
          type: MeshMessageType.message,
          senderID: _sender(2),
          timestampMs: now + i,
          payload: _bytes('out$i'.codeUnits),
        );
        if (GcsFilter.contains(decoded, GcsFilter.bucket(absent, params.m))) {
          falsePositives++;
        }
      }
      expect(falsePositives, lessThan(40)); // ~1% expected, 10% is generous
    });

    test('an empty set encodes to an empty filter', () {
      final params =
          GcsFilter.buildFilter(ids: [], maxBytes: 400, targetFpr: 0.01);
      expect(params.data, isEmpty);
      expect(params.includedCount, 0);
      expect(
        GcsFilter.decodeToSortedSet(
            p: params.p, m: params.m, data: params.data),
        isEmpty,
      );
    });

    test('the byte budget trims the tail, and says how far it reached', () {
      final ids = [
        for (var i = 0; i < 2000; i++)
          packetIdFor(
            type: MeshMessageType.message,
            senderID: _sender(1),
            timestampMs: now + i,
            payload: _bytes('m$i'.codeUnits),
          ),
      ];
      final params =
          GcsFilter.buildFilter(ids: ids, maxBytes: 64, targetFpr: 0.01);
      expect(params.data.length, lessThanOrEqualTo(64));
      expect(params.includedCount, lessThan(ids.length));
      expect(params.includedCount, greaterThan(0));
    });

    test('garbage parameters decode to nothing rather than noise', () {
      // Callers read an empty result as "the peer holds nothing" and send
      // everything — wasted airtime, never a silently dropped message.
      expect(
        GcsFilter.decodeToSortedSet(p: 0, m: 100, data: _bytes([1, 2, 3])),
        isEmpty,
      );
      expect(
        GcsFilter.decodeToSortedSet(
            p: GcsFilter.maxP + 1, m: 100, data: _bytes([1, 2, 3])),
        isEmpty,
      );
      expect(
        GcsFilter.decodeToSortedSet(p: 7, m: 1, data: _bytes([1, 2, 3])),
        isEmpty,
      );
    });

    test('P follows the target false-positive rate', () {
      expect(GcsFilter.deriveP(0.01), 7); // ceil(log2(100))
      expect(GcsFilter.deriveP(0.5), greaterThanOrEqualTo(1));
      expect(GcsFilter.deriveP(0.0), greaterThanOrEqualTo(1));
    });

    test('the packet id ignores TTL, which mutates as a packet is relayed', () {
      // Including TTL would make every hop a different "packet" and the whole
      // reconciliation meaningless.
      final a = _pkt(tsMs: now)..ttl = 7;
      final b = _pkt(tsMs: now)..ttl = 3;
      Uint8List idOf(BitchatPacket p) => packetIdFor(
            type: p.type,
            senderID: p.senderID,
            timestampMs: p.timestamp,
            payload: p.payload,
          );
      expect(idOf(a), idOf(b));
      expect(idOf(a), hasLength(16));
    });
  });

  group('REQUEST_SYNC wire format', () {
    test('round-trips every field', () {
      final packet = RequestSyncPacket(
        p: 7,
        m: 1280,
        data: _bytes([0xAB, 0xCD, 0xEF]),
        types: SyncTypeFlags.publicMessages,
        sinceTimestampMs: now,
      );
      final decoded = RequestSyncPacket.decode(packet.encode())!;
      expect(decoded.p, 7);
      expect(decoded.m, 1280);
      expect(decoded.data, _bytes([0xAB, 0xCD, 0xEF]));
      expect(decoded.types!.contains(MeshMessageType.message), isTrue);
      expect(decoded.types!.contains(MeshMessageType.announce), isTrue);
      expect(decoded.sinceTimestampMs, now);
    });

    test('the optional halves stay optional', () {
      final decoded = RequestSyncPacket.decode(
        RequestSyncPacket(p: 7, m: 2, data: Uint8List(0)).encode(),
      )!;
      expect(decoded.types, isNull);
      expect(decoded.sinceTimestampMs, isNull);
    });

    test('an unknown TLV is skipped, not fatal', () {
      // Forward compatibility is the point of the TLV: a newer bitchat adding
      // a field must not stop this client syncing with it.
      final base = RequestSyncPacket(p: 7, m: 2, data: _bytes([1])).encode();
      final withUnknown = Uint8List.fromList([...base, 0x7F, 0x00, 0x02, 9, 9]);
      final decoded = RequestSyncPacket.decode(withUnknown);
      expect(decoded, isNotNull);
      expect(decoded!.p, 7);
    });

    test('a truncated or nonsense payload decodes to null', () {
      expect(RequestSyncPacket.decode(_bytes([0x01])), isNull);
      expect(RequestSyncPacket.decode(_bytes([0x01, 0x00, 0x09, 1])), isNull);
      expect(RequestSyncPacket.decode(Uint8List(0)), isNull);
    });

    test('an oversized filter is refused rather than held', () {
      final big = RequestSyncPacket(p: 7, m: 2, data: Uint8List(2000)).encode();
      expect(RequestSyncPacket.decode(big, maxAcceptBytes: 1024), isNull);
    });

    test('type flags are little-endian with trailing zeros trimmed', () {
      expect(SyncTypeFlags.masked(3).toBytes(), _bytes([0x03])); // bits 0, 1
      expect(SyncTypeFlags.decode(_bytes([0x03]))!.rawValue, 3);
      expect(SyncTypeFlags.decode(Uint8List(0)), isNull);
      expect(SyncTypeFlags.decode(Uint8List(9)), isNull);
    });

    test('the public set asks for prekey bundles too', () {
      // Announce + public message + prekey bundle (bit 9), so the set spills
      // into a second byte — and the low byte still comes first.
      final flags = SyncTypeFlags.publicMessages;
      expect(flags.toBytes(), _bytes([0x03, 0x02]));
      expect(SyncTypeFlags.decode(flags.toBytes())!.rawValue, flags.rawValue);
      expect(flags.contains(MeshMessageType.prekeyBundle), isTrue);
    });

    test('an unknown type bit is dropped, never held as phantom membership',
        () {
      final flags = SyncTypeFlags.masked(1 << 40);
      expect(flags.isEmpty, isTrue);
    });
  });

  group('the store', () {
    test('remembers public broadcasts', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(_pkt(tsMs: now - 1000));
      expect(g.messageCount, 1);
    });

    test('refuses a DIRECTED packet — that is somebody\'s private mail', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(_pkt(tsMs: now, recipient: _sender(9)));
      expect(g.messageCount, 0);
    });

    test('refuses a type that must never be replayed', () {
      final g = GossipSync(nowMs: clock);
      for (final type in [
        MeshMessageType.noiseEncrypted,
        MeshMessageType.noiseHandshake,
        MeshMessageType.requestSync,
        MeshMessageType.nymTyping,
        MeshMessageType.voiceFrame,
      ]) {
        g.onPublicPacketSeen(_pkt(type: type, tsMs: now));
      }
      expect(g.messageCount, 0);
    });

    test('keeps one announce per peer, replacing not accumulating', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(
          _pkt(type: MeshMessageType.announce, sender: 1, tsMs: now - 2000));
      g.onPublicPacketSeen(
          _pkt(type: MeshMessageType.announce, sender: 1, tsMs: now - 1000));
      g.onPublicPacketSeen(
          _pkt(type: MeshMessageType.announce, sender: 2, tsMs: now - 1000));
      expect(g.announceCount, 2);
    });

    test('a message older than the 6h window is not carried', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(_pkt(tsMs: now - 7 * 60 * 60 * 1000));
      expect(g.messageCount, 0);
    });

    test('a message inside the window is', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(_pkt(tsMs: now - 5 * 60 * 60 * 1000));
      expect(g.messageCount, 1);
    });

    test('a stale announce ages out faster than a message', () {
      // Announces are presence; a stale one advertises a peer who left.
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(
          _pkt(type: MeshMessageType.announce, tsMs: now - 20 * 60 * 1000));
      expect(g.announceCount, 0);
    });

    test('a future timestamp is clock skew, not a reason to discard', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(_pkt(tsMs: now + 60 * 1000));
      expect(g.messageCount, 1);
    });

    test('the cap evicts oldest-first', () {
      final g = GossipSync(
        config: const GossipSyncConfig(capacity: 3),
        nowMs: clock,
      );
      for (var i = 0; i < 5; i++) {
        g.onPublicPacketSeen(_pkt(tsMs: now - 5000 + i, content: 'm$i'));
      }
      expect(g.messageCount, 3);
      expect(String.fromCharCodes(g.messages.last.payload), 'm2');
    });

    test('the same packet twice is stored once', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(_pkt(tsMs: now - 1000));
      g.onPublicPacketSeen(_pkt(tsMs: now - 1000));
      expect(g.messageCount, 1);
    });

    test('prune drops what has aged out', () {
      var t = now;
      final g = GossipSync(nowMs: () => t);
      g.onPublicPacketSeen(_pkt(tsMs: now));
      t = now + 7 * 60 * 60 * 1000;
      expect(g.prune(), isTrue);
      expect(g.messageCount, 0);
    });
  });

  group('the diff', () {
    test('a peer holding nothing is sent everything', () {
      final g = GossipSync(nowMs: clock);
      for (var i = 0; i < 5; i++) {
        g.onPublicPacketSeen(_pkt(tsMs: now - 1000 + i, content: 'm$i'));
      }
      final empty = RequestSyncPacket.decode(
        GossipSync(nowMs: clock).buildRequest(),
      )!;
      expect(g.packetsMissingFrom(empty), hasLength(5));
    });

    test('a peer holding everything is sent nothing', () {
      // The convergence property: two synced devices stop talking.
      final a = GossipSync(nowMs: clock);
      final b = GossipSync(nowMs: clock);
      for (var i = 0; i < 20; i++) {
        final p = _pkt(tsMs: now - 1000 + i, content: 'm$i');
        a.onPublicPacketSeen(p);
        b.onPublicPacketSeen(p);
      }
      final req = RequestSyncPacket.decode(b.buildRequest())!;
      expect(a.packetsMissingFrom(req), isEmpty);
    });

    test('only the difference crosses the air', () {
      final a = GossipSync(nowMs: clock);
      final b = GossipSync(nowMs: clock);
      for (var i = 0; i < 10; i++) {
        final p = _pkt(tsMs: now - 5000 + i, content: 'shared$i');
        a.onPublicPacketSeen(p);
        b.onPublicPacketSeen(p);
      }
      a.onPublicPacketSeen(_pkt(tsMs: now - 100, content: 'only-a'));
      final req = RequestSyncPacket.decode(b.buildRequest())!;
      final missing = a.packetsMissingFrom(req);
      expect(missing, hasLength(1));
      expect(String.fromCharCodes(missing.single.payload), 'only-a');
    });

    test('a response carries TTL 0 — a reply must not re-flood the mesh', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(_pkt(tsMs: now - 1000)..ttl = 7);
      final req =
          RequestSyncPacket.decode(GossipSync(nowMs: clock).buildRequest())!;
      expect(g.packetsMissingFrom(req).single.ttl, 0);
    });

    test('the since-cursor stops the uncovered tail re-sending every round',
        () {
      // A store bigger than one filter can cover: without the cursor the
      // responder would re-send that tail forever.
      final g = GossipSync(nowMs: clock);
      final peer = GossipSync(
        config: const GossipSyncConfig(gcsMaxBytes: 24),
        nowMs: clock,
      );
      for (var i = 0; i < 200; i++) {
        final p = _pkt(tsMs: now - 100000 + i * 10, content: 'm$i');
        g.onPublicPacketSeen(p);
        peer.onPublicPacketSeen(p);
      }
      final req = RequestSyncPacket.decode(peer.buildRequest())!;
      expect(req.sinceTimestampMs, isNotNull);
      // Everything the peer already holds is at or after the cursor and inside
      // its filter, so nothing older is offered back to it.
      final missing = g.packetsMissingFrom(req);
      for (final pkt in missing) {
        expect(pkt.timestamp, greaterThanOrEqualTo(req.sinceTimestampMs!));
      }
    });

    test('announces ignore the cursor — they carry the verifying keys', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(
          _pkt(type: MeshMessageType.announce, tsMs: now - 60 * 1000));
      final req = RequestSyncPacket(
        p: 7,
        m: 2,
        data: Uint8List(0),
        types: SyncTypeFlags.publicMessages,
        sinceTimestampMs: now, // newer than the announce
      );
      expect(g.packetsMissingFrom(req), hasLength(1));
    });

    test('a type the requester did not ask for is not sent', () {
      final g = GossipSync(nowMs: clock);
      g.onPublicPacketSeen(_pkt(tsMs: now - 1000));
      g.onPublicPacketSeen(
          _pkt(type: MeshMessageType.announce, tsMs: now - 1000));
      final onlyAnnounce = RequestSyncPacket(
        p: 7,
        m: 2,
        data: Uint8List(0),
        types: SyncTypeFlags.masked(1 << 0),
      );
      final out = g.packetsMissingFrom(onlyAnnounce);
      expect(out, hasLength(1));
      expect(out.single.type, MeshMessageType.announce);
    });
  });

  group('schedule and rate limit', () {
    test('a peer is asked once per interval', () {
      var t = now;
      final g = GossipSync(nowMs: () => t);
      expect(g.shouldAsk('peer'), isTrue);
      g.markAsked('peer');
      expect(g.shouldAsk('peer'), isFalse);
      t += 15 * 1000;
      expect(g.shouldAsk('peer'), isTrue);
    });

    test('a peer that asks too fast is answered once', () {
      // A response can replay the whole store, so this bounds what one peer
      // can make us spend however fast it asks.
      var t = now;
      final g = GossipSync(nowMs: () => t);
      expect(g.shouldAnswer('peer'), isTrue);
      g.markAnswered('peer');
      expect(g.shouldAnswer('peer'), isFalse);
      t += 30 * 1000;
      expect(g.shouldAnswer('peer'), isTrue);
    });

    test('a departed peer is forgotten rather than tracked forever', () {
      final g = GossipSync(nowMs: clock);
      g.markAnswered('peer');
      g.forgetPeer('peer');
      expect(g.shouldAnswer('peer'), isTrue);
    });
  });

  group('the archive', () {
    test('the carried history survives a restart', () {
      final g = GossipSync(nowMs: clock);
      for (var i = 0; i < 3; i++) {
        g.onPublicPacketSeen(_pkt(tsMs: now - 1000 + i, content: 'm$i'));
      }
      final restored = GossipSync(nowMs: clock)
        ..decodeArchive(g.encodeArchive());
      expect(restored.messageCount, 3);
      expect(
        restored.messages.map((m) => String.fromCharCodes(m.payload)).toSet(),
        {'m0', 'm1', 'm2'},
      );
    });

    test('restoring re-applies the freshness window', () {
      var t = now;
      final g = GossipSync(nowMs: () => t);
      g.onPublicPacketSeen(_pkt(tsMs: now));
      final archive = g.encodeArchive();
      t = now + 7 * 60 * 60 * 1000;
      final restored = GossipSync(nowMs: () => t)..decodeArchive(archive);
      expect(restored.messageCount, 0);
    });

    test('a corrupt archive costs the history, never the launch', () {
      final g = GossipSync(nowMs: clock);
      expect(() => g.decodeArchive('not json'), returnsNormally);
      expect(() => g.decodeArchive('{"not":"a list"}'), returnsNormally);
      expect(() => g.decodeArchive('["!!!not base64!!!"]'), returnsNormally);
      expect(() => g.decodeArchive(null), returnsNormally);
      expect(g.messageCount, 0);
    });
  });
}
