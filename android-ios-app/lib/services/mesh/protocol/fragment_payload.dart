import 'dart:typed_data';

import '../../../core/crypto/keys.dart' show randomBytes;

/// A single fragment of a larger mesh packet — a byte-for-byte port of bitchat's
/// `FragmentPayload`. Packets whose serialized size exceeds the fragment
/// threshold (512 bytes) are split; each fragment is carried as the payload of a
/// [MeshMessageType.fragment] packet and reassembled by the receiver.
///
/// Layout (13-byte header + data):
/// ```
/// fragmentID:8 (random) | index:2 (u16 BE) | total:2 (u16 BE) |
/// originalType:1 | data:variable
/// ```
class FragmentPayload {
  FragmentPayload({
    required this.fragmentID,
    required this.index,
    required this.total,
    required this.originalType,
    required this.data,
  });

  static const int headerSize = 13;
  static const int fragmentIdSize = 8;

  final Uint8List fragmentID; // 8 bytes
  final int index; // 0-based
  final int total; // >= 1
  final int originalType; // pre-fragmentation packet type
  final Uint8List data;

  /// A random 8-byte fragment set identifier.
  static Uint8List generateFragmentID() => randomBytes(fragmentIdSize);

  Uint8List encode() {
    assert(index >= 0 && index <= 0xFFFF);
    assert(total >= 1 && total <= 0xFFFF);
    assert(index < total);
    final out = Uint8List(headerSize + data.length);
    out.setRange(0, fragmentIdSize, fragmentID);
    out[8] = (index >> 8) & 0xFF;
    out[9] = index & 0xFF;
    out[10] = (total >> 8) & 0xFF;
    out[11] = total & 0xFF;
    out[12] = originalType & 0xFF;
    out.setRange(headerSize, out.length, data);
    return out;
  }

  static FragmentPayload? decode(Uint8List payload) {
    if (payload.length < headerSize) return null;
    try {
      final fragmentID = Uint8List.fromList(
          Uint8List.sublistView(payload, 0, fragmentIdSize));
      final index = (payload[8] << 8) | payload[9];
      final total = (payload[10] << 8) | payload[11];
      final originalType = payload[12];
      final data = payload.length > headerSize
          ? Uint8List.fromList(
              Uint8List.sublistView(payload, headerSize, payload.length))
          : Uint8List(0);
      return FragmentPayload(
        fragmentID: fragmentID,
        index: index,
        total: total,
        originalType: originalType,
        data: data,
      );
    } catch (_) {
      return null;
    }
  }

  String get fragmentIdHex =>
      fragmentID.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
