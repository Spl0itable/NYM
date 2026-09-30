import 'dart:convert';
import 'dart:typed_data';

/// bitchat v2 `BitchatFilePacket` TLV; CONTENT uses a 4-byte length so a chunk can exceed 64 KiB.
class BitchatFilePacket {
  BitchatFilePacket({
    required this.fileName,
    required this.mimeType,
    required this.content,
  }) : fileSize = content.length;

  final String fileName;
  final String mimeType;
  final Uint8List content;
  final int fileSize;

  static const int _tName = 0x01;
  static const int _tSize = 0x02;
  static const int _tMime = 0x03;
  static const int _tContent = 0x04;
  static const int _maxU16 = 0xFFFF;

  Uint8List? encode() {
    final nameBytes = utf8.encode(fileName);
    final mimeBytes = utf8.encode(mimeType);
    if (nameBytes.length > _maxU16 || mimeBytes.length > _maxU16) return null;

    final out = BytesBuilder();
    void u16(int v) {
      out.addByte((v >> 8) & 0xFF);
      out.addByte(v & 0xFF);
    }

    void u32(int v) {
      out.addByte((v >> 24) & 0xFF);
      out.addByte((v >> 16) & 0xFF);
      out.addByte((v >> 8) & 0xFF);
      out.addByte(v & 0xFF);
    }

    out.addByte(_tName);
    u16(nameBytes.length);
    out.add(nameBytes);

    // fileSize: 2-byte length (=4), then a 4-byte big-endian value.
    out.addByte(_tSize);
    u16(4);
    u32(content.length);

    out.addByte(_tMime);
    u16(mimeBytes.length);
    out.add(mimeBytes);

    // content: 4-byte length, single chunk.
    out.addByte(_tContent);
    u32(content.length);
    out.add(content);

    return out.toBytes();
  }

  static BitchatFilePacket? decode(Uint8List data) {
    var offset = 0;
    String? fileName;
    String? mimeType;
    final content = BytesBuilder();
    var sawContent = false;

    int? u(int bytes) {
      if (offset + bytes > data.length) return null;
      var v = 0;
      for (var i = 0; i < bytes; i++) {
        v = (v << 8) | data[offset++];
      }
      return v;
    }

    while (offset < data.length) {
      final type = data[offset++];
      int? len;
      if (type == _tContent) {
        // Fall back to a legacy 2-byte length when the 4-byte read would overrun.
        final snapshot = offset;
        final canonical = u(4);
        if (canonical != null && offset + canonical <= data.length) {
          len = canonical;
        } else {
          offset = snapshot;
          len = u(2);
        }
      } else {
        len = u(2);
      }
      if (len == null || offset + len > data.length) return null;
      final value = Uint8List.sublistView(data, offset, offset + len);
      offset += len;
      switch (type) {
        case _tName:
          fileName = utf8.decode(value, allowMalformed: true);
          break;
        case _tMime:
          mimeType = utf8.decode(value, allowMalformed: true);
          break;
        case _tContent:
          content.add(value);
          sawContent = true;
          break;
        case _tSize:
          break; // Informational; recomputed from content.
        default:
          break; // Unknown TLV: skip.
      }
    }
    if (!sawContent) return null;
    return BitchatFilePacket(
      fileName: fileName ?? 'file',
      mimeType: mimeType ?? 'application/octet-stream',
      content: content.toBytes(),
    );
  }
}
