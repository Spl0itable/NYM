import 'dart:typed_data';

import 'mesh_constants.dart';
import 'protocol/bitchat_packet.dart';
import 'protocol/fragment_payload.dart';
import 'protocol/mesh_message_type.dart';

/// Splits oversized packets into MTU-safe fragments and reassembles them —
/// byte-compatible with bitchat's `FragmentManager`.
///
/// The *unpadded* serialized packet is chunked; each chunk rides as the payload
/// of a [MeshMessageType.fragment] packet that inherits the original's
/// sender/recipient (so directed packets stay routable). The receiver
/// concatenates chunks in index order and decodes the original packet.
class PacketFragmenter {
  const PacketFragmenter._();

  /// Returns [packet] unchanged when it fits, otherwise its fragment packets.
  /// Returns an empty list if the packet cannot be serialized or would need more
  /// than [MeshMessageType.fragment]-safe fragments.
  static List<BitchatPacket> fragment(BitchatPacket packet) {
    if (packet.type == MeshMessageType.fragment) return [packet];

    final fullData = packet.toBytes(padding: false);
    if (fullData == null) return const [];
    if (fullData.length <= MeshConstants.fragmentSizeThreshold) {
      return [packet];
    }

    final hasRoute = packet.route != null && packet.route!.isNotEmpty;
    final headerSize = hasRoute ? 15 : 13;
    final recipientSize = packet.recipientID != null ? 8 : 0;
    final routeSize = hasRoute ? (1 + packet.route!.length * 8) : 0;
    const fragmentHeaderSize = FragmentPayload.headerSize;
    const paddingBuffer = 16;
    final overhead =
        headerSize + 8 + recipientSize + routeSize + fragmentHeaderSize + paddingBuffer;
    var maxDataSize = MeshConstants.fragmentSizeThreshold - overhead;
    if (maxDataSize > MeshConstants.maxFragmentSize) {
      maxDataSize = MeshConstants.maxFragmentSize;
    }
    if (maxDataSize <= 0) return const [];

    final fragmentID = FragmentPayload.generateFragmentID();
    final chunks = <Uint8List>[];
    for (var offset = 0; offset < fullData.length; offset += maxDataSize) {
      final end = (offset + maxDataSize < fullData.length)
          ? offset + maxDataSize
          : fullData.length;
      chunks.add(Uint8List.sublistView(fullData, offset, end));
    }
    // bitchat caps reassembly at 256 fragments per id; never emit more.
    if (chunks.length > 256) return const [];

    final out = <BitchatPacket>[];
    for (var i = 0; i < chunks.length; i++) {
      final payload = FragmentPayload(
        fragmentID: fragmentID,
        index: i,
        total: chunks.length,
        originalType: packet.type,
        data: Uint8List.fromList(chunks[i]),
      ).encode();
      out.add(BitchatPacket(
        version: hasRoute ? 2 : 1,
        type: MeshMessageType.fragment,
        senderID: packet.senderID,
        recipientID: packet.recipientID,
        timestamp: packet.timestamp,
        payload: payload,
        ttl: packet.ttl,
        route: packet.route,
      ));
    }
    return out;
  }
}

/// Reassembles incoming fragments into the original packet bytes.
class FragmentReassembler {
  final Map<String, _Assembly> _assemblies = {};

  /// Accepts a fragment payload. Returns the reassembled original packet bytes
  /// when the final missing fragment arrives, otherwise null.
  Uint8List? accept(FragmentPayload fragment) {
    _evictExpired();
    if (fragment.total < 1 ||
        fragment.index < 0 ||
        fragment.index >= fragment.total ||
        fragment.total > 256) {
      return null;
    }
    final key = fragment.fragmentIdHex;
    final assembly = _assemblies.putIfAbsent(
        key, () => _Assembly(fragment.total, fragment.originalType));
    if (assembly.total != fragment.total) return null;
    assembly.chunks[fragment.index] = fragment.data;

    if (assembly.chunks.length != assembly.total) return null;
    final builder = BytesBuilder();
    for (var i = 0; i < assembly.total; i++) {
      final chunk = assembly.chunks[i];
      if (chunk == null) return null; // gap remains
      builder.add(chunk);
    }
    _assemblies.remove(key);
    return builder.toBytes();
  }

  void _evictExpired() {
    final now = DateTime.now();
    _assemblies.removeWhere((_, a) =>
        now.difference(a.startedAt) > MeshConstants.fragmentTimeout);
  }

  void clear() => _assemblies.clear();
}

class _Assembly {
  _Assembly(this.total, this.originalType) : startedAt = DateTime.now();
  final int total;
  final int originalType;
  final DateTime startedAt;
  final Map<int, Uint8List> chunks = {};
}
