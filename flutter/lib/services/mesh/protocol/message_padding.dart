import 'dart:typed_data';

/// PKCS#7-style padding to fixed block sizes against traffic analysis, a port of bitchat's `MessagePadding`.
class MessagePadding {
  const MessagePadding._();

  /// Standard block sizes, identical to bitchat.
  static const List<int> blockSizes = [256, 512, 1024, 2048];

  /// Smallest block fitting [dataSize] plus a 16-byte tag; oversized frames keep their size.
  static int optimalBlockSize(int dataSize) {
    final totalSize = dataSize + 16;
    for (final blockSize in blockSizes) {
      if (totalSize <= blockSize) return blockSize;
    }
    return dataSize;
  }

  /// Strict PKCS#7 pad, since bitchat validates the whole trailing run; unchanged if over 255 bytes of padding.
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

  /// Removes PKCS#7 padding, returning [data] unchanged when the trailing run is not valid.
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
