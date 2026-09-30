// NOSTR_CARRIER (0x28), a port of bitchat's gateway mode; carried events are verified by signature at both ends.

import 'dart:convert';
import 'dart:typed_data';

enum NostrCarrierDirection {
  /// Mesh-only peer to gateway: publish this for me. Directed.
  toGateway(0x01),

  /// Gateway to mesh: what the relays are saying. Broadcast.
  fromGateway(0x02),

  /// Mesh-only peer to bridge gateway, for a rendezvous event. Directed.
  toBridge(0x03),

  /// Bridge gateway to mesh; older clients fail to decode this direction and drop it quietly.
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

class NostrCarrierPacket {
  const NostrCarrierPacket._({
    required this.direction,
    required this.geohash,
    required this.eventJson,
  });

  final NostrCarrierDirection direction;

  final String geohash;

  /// The complete signed event JSON.
  final Uint8List eventJson;

  /// BLE airtime cap for a carried event.
  static const int maxEventJsonBytes = 16 * 1024;
  static const int maxGeohashLength = 12;

  /// Null when the geohash or event is empty or over its cap.
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

  /// Parses only: the caller must still verify the signature before publishing or displaying.
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

  /// Null for anything malformed, including trailing bytes, since it is published on someone's behalf.
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
