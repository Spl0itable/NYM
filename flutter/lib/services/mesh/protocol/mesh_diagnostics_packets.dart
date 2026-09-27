// mesh_diagnostics_packets.dart - PING (0x26) and PONG (0x27).
//
// A directed echo probe: "are you there, and how far away are you?". The reply
// echoes the nonce so it can only answer a probe this device actually sent, and
// both carry the TTL the packet was LAUNCHED with — so the receiver can work
// out how many links it crossed by comparing that against the TTL it arrived
// with. That hop count is the one thing a mesh cannot otherwise show you: a
// peer three relays away and a peer in the same room look identical in a peer
// list.
//
// A port of bitchat's `MeshPingPayload`. Both directions are unencrypted and
// unsigned, which is safe here because the payload carries nothing private and
// the unguessable nonce already binds a pong to a probe we sent.

import 'dart:typed_data';

/// The 9-byte payload shared by PING and PONG: an 8-byte nonce plus the origin
/// TTL.
class MeshPingPayload {
  const MeshPingPayload({required this.nonce, required this.originTtl});

  static const int nonceLength = 8;
  static const int _encodedLength = nonceLength + 1;

  /// Random, and echoed verbatim by the pong. Unguessable so a reply cannot be
  /// forged for a probe we never sent.
  final Uint8List nonce;

  /// The TTL the packet was launched with, so the far end can derive the hop
  /// count from the TTL it actually received.
  final int originTtl;

  /// Null when [nonce] is not exactly [nonceLength] bytes.
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

  /// Accepts trailing bytes, so a future revision can extend the format
  /// without older clients refusing to answer.
  static MeshPingPayload? decode(Uint8List data) {
    if (data.length < _encodedLength) return null;
    return MeshPingPayload(
      nonce: Uint8List.fromList(Uint8List.sublistView(data, 0, nonceLength)),
      originTtl: data[nonceLength],
    );
  }

  /// How many links the packet crossed: the TTL decrements plus the final
  /// delivery link, so a directly connected peer is 1 hop away.
  ///
  /// Null when the TTLs are inconsistent (received above origin), which means
  /// somebody rewrote the packet rather than relayed it.
  static int? hopCount({required int originTtl, required int receivedTtl}) {
    if (originTtl < receivedTtl) return null;
    return (originTtl - receivedTtl) + 1;
  }
}

/// One completed probe, for the mesh diagnostics panel.
class MeshPingResult {
  const MeshPingResult({
    required this.peerID,
    required this.roundTripMs,
    this.hops,
  });

  final String peerID;
  final int roundTripMs;

  /// Null when the reply's TTLs did not make sense.
  final int? hops;
}
