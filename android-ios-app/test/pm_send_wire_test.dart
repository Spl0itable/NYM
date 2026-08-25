// What actually goes on the wire when a PM is sent.
//
// Every other test around this checks the send PLAN — an object describing
// what should happen. That is how "Bitchat users receive nothing" survived
// three rounds of fixes: a plan test asserted the broken behaviour, and the
// plan is not what users notice. This drives the REAL `publishPM` against a
// recording transport and looks at the events, then opens the Bitchat copy the
// way a Bitchat client would.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/bitchat.dart' as bitchat;
import 'package:nym_bar/core/crypto/gift_wrap.dart' as giftwrap;
import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/features/identity/pq_registry.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/nostr/nostr_service.dart';
import 'package:nym_bar/services/relay/relay_message.dart';
import 'package:nym_bar/services/relay/relay_pool.dart';
import 'package:nym_bar/services/relay/relay_stats.dart';

void main() {
  final skMe = keys.generatePrivateKey();
  final skPeer = keys.generatePrivateKey();
  final me = keys.getPublicKeyHex(skMe);
  final peer = keys.getPublicKeyHex(skPeer);
  final peerKem = pq.pqKeypairFromPrivkey(skPeer, 0);

  /// Everything `_publishDualPm` does between deciding and publishing, so the
  /// test exercises the same construction the app does.
  Future<_RecordingTransport> send({
    Uint8List? recipientKemKey,
    bool layered = true,
    bool proven = false,
    bool knownBitchat = false,
    bool knownNym = false,
    String content = 'hello from nymchat',
    int? expiration,
  }) async {
    final rec = _RecordingTransport();
    final svc = NostrService(
      identity: Identity(pubkey: me, privkey: skMe, nym: 'me#0001'),
      signer: LocalSigner(skMe),
      pool: rec,
    );
    const nymMessageId = 'shared-message-id';
    final rumor = UnsignedEvent(
      pubkey: me,
      createdAt: 1700000000,
      kind: 14,
      tags: const [
        ['x', nymMessageId],
      ],
      content: content,
    );
    final plan = PqPmPlan.decide(
      recipientKemKey: recipientKemKey,
      recipientAcceptsLayered: layered,
      provenNymchat: proven,
      knownBitchat: knownBitchat,
      knownNym: knownNym,
    );
    final bitchatRumors = <UnsignedEvent>[];
    if (plan.bitchat) {
      for (final chunk in bitchat.chunkBitchatContent(rumor.content)) {
        final encoded =
            bitchat.encodeBitchatMessage(chunk, me, recipientPubkey: peer);
        // No tags — mirrors `_publishDualPm`. Bitchat 1.7.1 rejects any inner
        // rumor whose tags are neither empty nor exactly [["p", recipient]].
        bitchatRumors.add(UnsignedEvent(
          pubkey: me,
          createdAt: rumor.createdAt,
          kind: 14,
          tags: const [],
          content: encoded.content,
        ));
      }
    }
    await svc.publishPM(
      rumor: rumor,
      settings: MessagingSettings(
        dmForwardSecrecyEnabled: expiration != null,
        dmTtlSeconds: expiration != null ? 3600 : 0,
      ),
      recipientPubkey: peer,
      bitchatRumors: bitchatRumors,
      sendNymWrap: plan.nym,
      recipientKemPublicKey: plan.kemPublicKey,
      recipientLayered: plan.layered,
    );
    return rec;
  }

  /// The transport each published wrap used, and who it was addressed to.
  List<String> transports(_RecordingTransport rec) => rec.dmCalls.map((ev) {
        final c = ev.content;
        final kind = c.startsWith('pq2.')
            ? 'pq2'
            : c.startsWith('pq1.')
                ? 'pq1'
                : c.startsWith('v2:')
                    ? 'bitchat'
                    : 'nip44';
        final to = ev.tags.firstWhere((t) => t.isNotEmpty && t[0] == 'p',
            orElse: () => const ['p', '?'])[1];
        return '$kind->${to == me ? 'self' : to == peer ? 'peer' : '?'}';
      }).toList();

  List<String> toPeer(_RecordingTransport rec) =>
      transports(rec).where((t) => t.endsWith('->peer')).toList();

  group('what a 1:1 PM actually puts on the wire', () {
    test('no announcement -> Bitchat + NIP-44', () async {
      expect(toPeer(await send()), ['bitchat->peer', 'nip44->peer']);
    });

    // Classification from traffic must not move the verdict in either
    // direction — it is inference, and the announcement is signed.
    test('...whatever the peer is classified as', () async {
      for (final flags in const [
        (b: true, n: false),
        (b: false, n: true),
        (b: true, n: true),
      ]) {
        expect(toPeer(await send(knownBitchat: flags.b, knownNym: flags.n)),
            ['bitchat->peer', 'nip44->peer'],
            reason: 'knownBitchat=${flags.b} knownNym=${flags.n}');
      }
    });

    test('live announcement with pk2 -> pq2 alone', () async {
      expect(toPeer(await send(recipientKemKey: peerKem.publicKey)),
          ['pq2->peer']);
    });

    test('live announcement, pq1 key only -> NIP-44 alone', () async {
      expect(
          toPeer(await send(recipientKemKey: peerKem.publicKey, layered: false)),
          ['nip44->peer']);
    });

    test('live announcement carrying no key -> NIP-44 alone', () async {
      expect(toPeer(await send(proven: true)), ['nip44->peer']);
    });

    // A peer who moved from Nymchat to Bitchat, or who runs both. Their
    // announcement is live and would otherwise silence us for its whole
    // seven-day TTL.
    test('heard bitchat + live pk2 announcement -> Bitchat + NIP-44', () async {
      expect(
          toPeer(await send(
              recipientKemKey: peerKem.publicKey, knownBitchat: true)),
          ['bitchat->peer', 'nip44->peer']);
    });

    test('heard bitchat + keyless announcement -> Bitchat + NIP-44', () async {
      expect(toPeer(await send(proven: true, knownBitchat: true)),
          ['bitchat->peer', 'nip44->peer']);
    });

    test('a self-copy is archived for our other devices either way', () async {
      expect(transports(await send()).where((t) => t.endsWith('->self')),
          isNotEmpty);
      expect(
          transports(await send(recipientKemKey: peerKem.publicKey))
              .where((t) => t.endsWith('->self')),
          isNotEmpty);
    });
  });

  group('the Bitchat copy, opened as a Bitchat client would', () {
    test('a Bitchat peer gets a wrap it can actually read', () async {
      final rec = await send();
      final wrap = rec.dmCalls.firstWhere((e) => e.content.startsWith('v2:'));

      expect(wrap.kind, 1059);
      expect(wrap.tags.firstWhere((t) => t[0] == 'p')[1], peer);
      expect(wrap.pubkey, isNot(me),
          reason: 'the wrap is signed by a throwaway key, not by us');

      final opened = await giftwrap.unwrapGiftWrap(wrap, [
        giftwrap.classicalCandidate(skPeer, bitchat: true),
      ]);
      expect(opened, isNotNull);
      expect(opened!.isBitchat, isTrue);

      final inner = opened.rumor['content'] as String;
      expect(inner, startsWith('bitchat1:'));

      // Decode the packet the way the Bitchat app does, so a change to the
      // header or TLV layout fails here rather than in someone's chat.
      final b = base64Url.decode(base64Url
          .normalize(inner.substring('bitchat1:'.length)));
      expect(b[0], 0x01, reason: 'version 1');
      expect(b[1], 0x11, reason: 'type NOISE_ENCRYPTED');
      expect(b[11] & 0x01, 1, reason: 'HAS_RECIPIENT flag');
      final payloadLen = (b[12] << 8) | b[13];
      expect(_hex(b.sublist(14, 22)), me.substring(0, 16),
          reason: 'sender id');
      expect(_hex(b.sublist(22, 30)), peer.substring(0, 16),
          reason: 'recipient id');

      final payload = b.sublist(30, 30 + payloadLen);
      expect(payload[0], 0x01, reason: 'PRIVATE_MESSAGE');
      final tlv = <int, String>{};
      var i = 1;
      while (i < payload.length) {
        final type = payload[i];
        final long = (type & 0x80) != 0;
        final len = long ? ((payload[i + 1] << 8) | payload[i + 2]) : payload[i + 1];
        final start = i + (long ? 3 : 2);
        tlv[type & 0x7f] = utf8.decode(payload.sublist(start, start + len));
        i = start + len;
      }
      expect(tlv[1], 'hello from nymchat',
          reason: 'the plaintext comes back out intact');
      expect(tlv[0], hasLength(36), reason: 'a bitchat message id');
    });

    test('an announced peer we have heard bitchat from still gets a readable wrap',
        () async {
      final rec = await send(
          recipientKemKey: peerKem.publicKey, knownBitchat: true);
      final wrap = rec.dmCalls.firstWhere((e) => e.content.startsWith('v2:'));
      final opened = await giftwrap.unwrapGiftWrap(wrap, [
        giftwrap.classicalCandidate(skPeer, bitchat: true),
      ]);
      expect(opened, isNotNull);
      expect((opened!.rumor['content'] as String), startsWith('bitchat1:'));
      // And not ALSO post-quantum: a readable copy beside it protects nothing.
      expect(rec.dmCalls.where((e) => e.content.startsWith('pq2.')
          && e.tags.firstWhere((t) => t[0] == 'p')[1] == peer), isEmpty);
    });

    // --- Bitchat's own envelope guards -------------------------------------
    // Transliterated from bitchat's `NostrProtocol.swift decryptPrivateMessage`
    // as of upstream e9275cb (v1.7.1, 2026-07-26), which hardened validation. A
    // wrap failing ANY of these is dropped as malformed on their side, silently
    // — which is what a user sees as "they never got it". Our own decoder
    // cannot catch it: it accepts whatever we produce.
    Future<String?> bitchatAccepts(NostrEvent wrap) async {
      String t(List<List<String>> x) => jsonEncode(x);
      // step 0: the gift wrap's tags must be EXACTLY [["p", recipient]].
      if (t(wrap.tags) != t([['p', peer]])) return 'wrap tags: ${t(wrap.tags)}';
      final opened = await giftwrap.unwrapGiftWrap(wrap, [
        giftwrap.classicalCandidate(skPeer, bitchat: true),
      ]);
      if (opened == null) return 'does not decrypt';
      // step 2: the seal carries no tags.
      if (t(opened.seal.tags) != '[]') return 'seal tags: ${t(opened.seal.tags)}';
      // step 4: validInnerMessageTags — empty, or exactly [["p", recipient]].
      final rt = (opened.rumor['tags'] as List)
          .map((e) => (e as List).map((x) => x as String).toList())
          .toList();
      if (t(rt) != '[]' && t(rt) != t([['p', peer]])) return 'rumor tags: ${t(rt)}';
      return null;
    }

    test('a MESSAGE passes every one of Bitchat 1.7.1 envelope checks',
        () async {
      final rec = await send();
      final wrap = rec.dmCalls.firstWhere((e) => e.content.startsWith('v2:'));
      expect(await bitchatAccepts(wrap), isNull);
    });

    // Named so a well-meaning re-add of the x tag fails right here.
    test('the bitchat rumor carries NO tags at all', () async {
      final rec = await send();
      final wrap = rec.dmCalls.firstWhere((e) => e.content.startsWith('v2:'));
      final opened = await giftwrap.unwrapGiftWrap(wrap, [
        giftwrap.classicalCandidate(skPeer, bitchat: true),
      ]);
      expect(opened!.rumor['tags'], isEmpty,
          reason: 'an x tag here is what stopped Bitchat 1.7.1 accepting us');
    });

    test('and the bitchat wrap carries nothing but its p tag', () async {
      // With disappearing messages ON, an expiration tag on the wrap fails
      // Bitchat's exact-shape check — this asserts we never add one.
      final rec = await send(expiration: 1787660000);
      final wrap = rec.dmCalls.firstWhere((e) => e.content.startsWith('v2:'));
      expect(jsonEncode(wrap.tags), jsonEncode([['p', peer]]));
      expect(await bitchatAccepts(wrap), isNull);
    });
  });

  group('a long message reaches Bitchat in pieces', () {
    // Bitchat writes a 1-byte TLV length and refuses to encode a field over 255
    // bytes; its decoder meets an unknown type and discards the WHOLE packet.
    // We used to set the high bit of the type byte with a 2-byte length — a
    // convention bitchat has never had — so every long message to a Bitchat
    // user was dropped on arrival, and had been for as long as this existed.
    final long = 'The quick brown fox jumps over the lazy dog. ' * 20;

    test('it goes out as several wraps, each decodable by bitchat', () async {
      final rec = await send(content: long);
      final wraps =
          rec.dmCalls.where((e) => e.content.startsWith('v2:')).toList();
      expect(wraps.length, greaterThan(1));

      final parts = <String>[];
      for (final w in wraps) {
        final opened = await giftwrap.unwrapGiftWrap(w, [
          giftwrap.classicalCandidate(skPeer, bitchat: true),
        ]);
        final inner = opened!.rumor['content'] as String;
        final b = base64Url
            .decode(base64Url.normalize(inner.substring('bitchat1:'.length)));
        final payload = b.sublist(30, 30 + ((b[12] << 8) | b[13]));
        // Decoded exactly as bitchat does: 1-byte lengths, unknown type => drop.
        var i = 1;
        String? id, text;
        while (i + 2 <= payload.length) {
          final type = payload[i], len = payload[i + 1];
          final st = i + 2;
          expect(st + len, lessThanOrEqualTo(payload.length));
          final v = utf8.decode(payload.sublist(st, st + len));
          if (type == 0x00) {
            id = v;
          } else if (type == 0x01) {
            text = v;
          } else {
            fail('bitchat would discard this packet: unknown TLV type $type');
          }
          i = st + len;
        }
        expect(id, isNotNull);
        expect(utf8.encode(text!).length, lessThanOrEqualTo(255));
        parts.add(text);
      }
      expect(parts.join(), long, reason: 'the pieces reassemble exactly');
    });
  });

  group('chunking', () {
    test('never splits a multi-byte character', () {
      final emoji = '🙂' * 200; // 4 bytes each; no 255 boundary is clean
      final parts = bitchat.chunkBitchatContent(emoji);
      expect(parts.join(), emoji);
      expect(parts.join(), isNot(contains('\uFFFD')));
      for (final p in parts) {
        expect(utf8.encode(p).length, lessThanOrEqualTo(255));
      }
    });

    test('leaves short text as one chunk', () {
      expect(bitchat.chunkBitchatContent('hello'), hasLength(1));
    });
  });

  _lookupCannotBlockASend();
}

/// The send path awaits a peer's announcement before deciding. A peer WITH a
/// key answers off the registry and never reaches the network; a peer WITHOUT
/// one pays for the lookup on EVERY message, which is to say a Bitchat user
/// does, always. Neither leg of that lookup is bounded on the send path's
/// terms, and the pending future is handed to every later caller — so one stuck
/// read stopped every subsequent message to that peer, silently, with nothing
/// published.
///
/// Driving a stalled D1 read needs the controller's private members, so this
/// pins the two guards at the source instead. The PWA has the executable
/// version of this in scripts/test-pm-send.mjs.
void _lookupCannotBlockASend() {
  group('a stalled key lookup cannot stop a message', () {
    final src = File('lib/state/nostr_controller.dart').readAsStringSync();

    test('the announcement lookup is bounded before the send awaits it', () {
      expect(
          src.contains('const Duration(milliseconds: _pqSendLookupBudgetMs)'),
          isTrue,
          reason: 'ensurePqAnnouncement must time out rather than hang a send');
    });

    test('later callers attach to the BOUNDED future, not the raw one', () {
      expect(src.contains('_pqLookups[pubkey] = bounded;'), isTrue,
          reason: 'or one stuck read holds up every later message to that peer');
    });

    test('and a failed lookup can never abort the send', () {
      expect(
          RegExp(r'try \{\s*await ensurePqAnnouncement\(recipientPubkey\);\s*\}\s*catch')
              .hasMatch(src),
          isTrue,
          reason: 'a peer with no announcement is the normal case, not an error');
    });
  });
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// A PoolTransport that records instead of publishing.
class _RecordingTransport implements PoolTransport {
  final List<NostrEvent> plainCalls = [];
  final List<NostrEvent> dmCalls = [];

  @override
  void connectAll() {}
  @override
  void updateGeoRelays(List<String> geoRelayUrls) {}
  @override
  Future<void> disconnectAll() async {}
  @override
  int get connectedCount => 0;
  @override
  Set<String> get connectedRelayUrls => const {};
  @override
  RelayStats get stats => RelayStats();
  @override
  Future<int> publish(NostrEvent event) async {
    plainCalls.add(event);
    return 1;
  }

  @override
  Future<int> publishDm(NostrEvent event) async {
    dmCalls.add(event);
    return 1;
  }

  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) async
      => 1;
  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) =>
      throw UnimplementedError();
  @override
  void closeSubscription(Subscription sub) {}
}
