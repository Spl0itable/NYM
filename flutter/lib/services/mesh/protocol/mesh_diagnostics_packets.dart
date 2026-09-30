// PING (0x26) / PONG (0x27), a port of bitchat's `MeshPingPayload`; unsigned since the nonce binds the pong.

import 'dart:typed_data';

/// The 9-byte PING/PONG payload: an 8-byte nonce plus the origin TTL.
class MeshPingPayload {
  const MeshPingPayload({required this.nonce, required this.originTtl});

  static const int nonceLength = 8;
  static const int _encodedLength = nonceLength + 1;

  /// Random and echoed by the pong, so a reply can't be forged.
  final Uint8List nonce;

  /// Launch TTL, so the far end can derive the hop count.
  final int originTtl;

  static MeshPingPayload? create({
    required Uint8List nonce,
    required int originTtl,
  }) {
    if (nonce.length != nonceLength) return null;
    return MeshPingPayload(nonce: nonce, originTtl: originTtl & 0xFF);
  }

  Uint8List encode() {
    final out = Uint8List(_encodedLength);
    out.setRange(0, nonceLength, nonce);
    out[nonceLength] = originTtl & 0xFF;
    return out;
  }

  /// Accepts trailing bytes so future revisions can extend the format.
  static MeshPingPayload? decode(Uint8List data) {
    if (data.length < _encodedLength) return null;
    return MeshPingPayload(
      nonce: Uint8List.fromList(Uint8List.sublistView(data, 0, nonceLength)),
      originTtl: data[nonceLength],
    );
  }

  /// Links crossed (a direct peer is 1 hop); null when received TTL exceeds origin.
  static int? hopCount({required int originTtl, required int receivedTtl}) {
    if (originTtl < receivedTtl) return null;
    return (originTtl - receivedTtl) + 1;
  }
}

class MeshPingResult {
  const MeshPingResult({
    required this.peerID,
    required this.roundTripMs,
    this.hops,
  });

  final String peerID;
  final int roundTripMs;

  final int? hops;
}
