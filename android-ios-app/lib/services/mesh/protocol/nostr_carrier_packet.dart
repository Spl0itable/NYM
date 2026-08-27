// nostr_carrier_packet.dart - NOSTR_CARRIER (0x28), gateway mode.
//
// The sender outbox holds a message sent with no internet until OUR internet
// comes back. Gateway mode does not wait for ours: a mesh-only peer hands a
// complete, signed Nostr event to a peer that HAS internet, who publishes it to
// the relays. One phone with a signal is enough for the whole room.
//
// It runs both ways:
//  * `toGateway` rides a DIRECTED packet — "please publish this for me".
//  * `fromGateway` rides a BROADCAST — the gateway rebroadcasting what it heard
//    from the relays, so mesh-only peers can read the channel as well as write
//    to it.
//
// The carried event is public geohash chat, already plaintext on Nostr, so the
// carrier adds no encryption of its own. What matters is that it is SIGNED by
// the originator: neither the gateway nor any relay in between can alter or
// forge it undetected, and both ends verify the Schnorr signature before acting
// on it. A gateway is a postbox, not an author.
//
// A port of bitchat's `NostrCarrierPacket`. TLV with 2-byte big-endian lengths,
// because a signed event's JSON does not fit the 1-byte range the smaller
// packets use.

import 'dart:convert';
import 'dart:typed_data';

/// Which way a carried event is travelling.
enum NostrCarrierDirection {
  /// Mesh-only peer → gateway: publish this for me. Directed.
  toGateway(0x01),

  /// Gateway → mesh: here is what the relays are saying. Broadcast.
  fromGateway(0x02),

  /// Mesh-only peer → bridge gateway, for a rendezvous event. Directed.
  toBridge(0x03),

  /// Bridge gateway → mesh, rebroadcasting a remote island's rendezvous.
  /// A client that does not know 0x03/0x04 fails the direction decode and
  /// drops the carrier quietly — bridge traffic degrades to invisible, not to
  /// junk in the timeline.
  fromBridge(0x04);

  const NostrCarrierDirection(this.wire);
  final int wire;

  static NostrCarrierDirection? fromWire(int v) {
    for (final d in NostrCarrierDirection.values) {
      if (d.wire == v) return d;
    }
    return null;
  }
}

/// A complete signed Nostr event ferried over the mesh.
class NostrCarrierPacket {
  const NostrCarrierPacket._({
    required this.direction,
    required this.geohash,
    required this.eventJson,
  });

  final NostrCarrierDirection direction;

  /// The geohash channel the event belongs to.
  final String geohash;

  /// The complete signed event JSON (id, pubkey, created_at, kind, tags,
  /// content, sig).
  final Uint8List eventJson;

  /// BLE airtime cap for a carried event.
  static const int maxEventJsonBytes = 16 * 1024;
  static const int maxGeohashLength = 12;

  /// Null when the geohash or event is empty or over its cap — a carrier that
  /// cannot fit the air is worse than none.
  static NostrCarrierPacket? create({
    required NostrCarrierDirection direction,
    required String geohash,
    required Uint8List eventJson,
  }) {
    final geoBytes = utf8.encode(geohash);
    if (geoBytes.isEmpty || geoBytes.length > maxGeohashLength) return null;
    if (eventJson.isEmpty || eventJson.length > maxEventJsonBytes) return null;
    return NostrCarrierPacket._(
      direction: direction,
      geohash: geohash,
      eventJson: eventJson,
    );
  }

  /// Builds one from a decoded event map.
  static NostrCarrierPacket? fromEvent({
    required NostrCarrierDirection direction,
    required String geohash,
    required Map<String, dynamic> event,
  }) {
    try {
      final json = Uint8List.fromList(utf8.encode(jsonEncode(event)));
      return create(
          direction: direction, geohash: geohash, eventJson: json);
    } catch (_) {
      return null;
    }
  }

  /// The carried event as a map.
  ///
  /// The caller MUST still verify the signature before publishing or
  /// displaying it: this only parses, it does not vouch.
  Map<String, dynamic>? event() {
    try {
      final decoded = jsonDecode(utf8.decode(eventJson));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Uint8List encode() {
    final out = BytesBuilder();
    void tlv(int t, List<int> v) {
      out.addByte(t);
      out.addByte((v.length >> 8) & 0xFF);
      out.addByte(v.length & 0xFF);
      out.add(v);
    }

    tlv(0x01, [direction.wire]);
    tlv(0x02, utf8.encode(geohash));
    tlv(0x03, eventJson);
    return out.toBytes();
  }

  /// Null for anything malformed, including trailing bytes: a carrier is
  /// published on somebody's behalf, so a payload that does not parse exactly
  /// is refused rather than guessed at.
  static NostrCarrierPacket? decode(Uint8List data) {
    var off = 0;
    NostrCarrierDirection? direction;
    String? geohash;
    Uint8List? eventJson;
    while (off + 3 <= data.length) {
      final t = data[off];
      final len = (data[off + 1] << 8) | data[off + 2];
      off += 3;
      if (off + len > data.length) return null;
      final v = Uint8List.sublistView(data, off, off + len);
      off += len;
      switch (t) {
        case 0x01:
          if (len != 1) return null;
          direction = NostrCarrierDirection.fromWire(v[0]);
          if (direction == null) return null;
        case 0x02:
          try {
            geohash = utf8.decode(v);
          } catch (_) {
            return null;
          }
        case 0x03:
          eventJson = Uint8List.fromList(v);
        default:
        // Unknown TLV: skipped for forward compatibility.
      }
    }
    if (off != data.length) return null;
    if (direction == null || geohash == null || eventJson == null) return null;
    return create(
      direction: direction,
      geohash: geohash,
      eventJson: eventJson,
    );
  }
}
