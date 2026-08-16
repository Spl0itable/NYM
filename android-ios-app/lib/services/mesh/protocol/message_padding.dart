import 'dart:typed_data';

/// Privacy-preserving PKCS#7-style padding — a byte-for-byte port of bitchat's
/// `MessagePadding` (iOS/Android). Normalising every frame to one of a small set
/// of block sizes resists traffic analysis: an eavesdropper cannot infer message
/// length from the BLE packet size.
///
/// Interop note: bitchat's decoder tries the raw bytes first and only strips
/// padding if the raw decode fails, so padding is optional on the wire but every
/// reference client emits it. We emit it too.
class MessagePadding {
  const MessagePadding._();

  /// Standard block sizes — identical to bitchat.
  static const List<int> blockSizes = [256, 512, 1024, 2048];

  /// Smallest block that fits [dataSize] plus a 16-byte AEAD-tag allowance.
  /// Falls back to the raw size for very large frames (they get fragmented).
  static int optimalBlockSize(int dataSize) {
    final totalSize = dataSize + 16;
    for (final blockSize in blockSizes) {
      if (totalSize <= blockSize) return blockSize;
    }
    return dataSize;
  }

  /// Pads [data] up to [targetSize] using strict PKCS#7 — every pad byte equals
  /// the pad length. Returns [data] unchanged when it already meets/exceeds the
  /// target or when the required padding would not fit a single-byte length
  /// marker (> 255), exactly matching bitchat's guard.
  ///
  /// Strictness matters for interop: bitchat's [unpad] validates the *entire*
  /// trailing run against the length marker, so a non-uniform pad region would
  /// make a bitchat peer fail to strip our padding and reject the packet.
  static Uint8List pad(Uint8List data, int targetSize) {
    if (data.length >= targetSize) return data;
    final paddingNeeded = targetSize - data.length;
    if (paddingNeeded <= 0 || paddingNeeded > 255) return data;

    final result = Uint8List(targetSize)..setRange(0, data.length, data);
    for (var i = data.length; i < targetSize; i++) {
      result[i] = paddingNeeded;
    }
    return result;
  }

  /// Removes PKCS#7 padding. Returns [data] unchanged if the trailing bytes are
  /// not a valid pad run — matching bitchat's lenient unpad (a false strip would
  /// corrupt an unpadded frame, so validation is strict).
  static Uint8List unpad(Uint8List data) {
    if (data.isEmpty) return data;
    final paddingLength = data[data.length - 1];
    if (paddingLength <= 0 || paddingLength > data.length) return data;
    final start = data.length - paddingLength;
    for (var i = start; i < data.length; i++) {
      if (data[i] != paddingLength) return data;
    }
    return Uint8List.sublistView(data, 0, start);
  }
}
