import 'dart:convert';
import 'dart:typed_data';

import 'mesh_message_type.dart';

/// The decrypted plaintext carried inside a [MeshMessageType.noiseEncrypted]
/// packet — a `[type:1][data]` envelope, byte-for-byte compatible with bitchat's
/// `NoisePayload`. [type] is a [NoisePayloadType] value.
class NoisePayload {
  NoisePayload(this.type, this.data);

  final int type;
  final Uint8List data;

  Uint8List encode() {
    final out = Uint8List(1 + data.length);
    out[0] = type & 0xFF;
    out.setRange(1, out.length, data);
    return out;
  }

  static NoisePayload? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final type = bytes[0];
    final data = bytes.length > 1
        ? Uint8List.fromList(Uint8List.sublistView(bytes, 1, bytes.length))
        : Uint8List(0);
    return NoisePayload(type, data);
  }

  /// A delivery acknowledgement for [messageID] — over the mesh the payload is
  /// simply the UTF-8 message id (bitchat `.delivered`).
  static NoisePayload delivered(String messageID) =>
      NoisePayload(NoisePayloadType.delivered,
          Uint8List.fromList(utf8.encode(messageID)));

  /// A read receipt for [messageID] — payload is the UTF-8 message id
  /// (bitchat `.readReceipt`).
  static NoisePayload readReceipt(String messageID) =>
      NoisePayload(NoisePayloadType.readReceipt,
          Uint8List.fromList(utf8.encode(messageID)));

  /// The UTF-8 message id from a receipt payload ([delivered]/[readReceipt]).
  String receiptMessageId() => utf8.decode(data, allowMalformed: true);
}

/// A private text message — the TLV body of a [NoisePayloadType.privateMessage]
/// payload. Byte-for-byte compatible with bitchat's `PrivateMessagePacket`.
///
/// TLV: `MESSAGE_ID(0x00)` then `CONTENT(0x01)`, each `type:1 | length:1 | value`
/// with UTF-8 values. The single-byte length caps each field at 255 bytes; the
/// mesh send path chunks longer text into multiple packets (see
/// [maxContentBytes]).
class PrivateMessagePacket {
  PrivateMessagePacket({required this.messageID, required this.content});

  final String messageID;
  final String content;

  static const int _tlvMessageId = 0x00;
  static const int _tlvContent = 0x01;

  /// Max UTF-8 content bytes that fit a single packet (1-byte TLV length).
  static const int maxContentBytes = 255;

  /// Encodes the TLV. Returns null if either field exceeds 255 UTF-8 bytes,
  /// matching bitchat — callers must pre-chunk long content.
  Uint8List? encode() {
    final idBytes = utf8.encode(messageID);
    final contentBytes = utf8.encode(content);
    if (idBytes.length > 255 || contentBytes.length > 255) return null;
    final out = BytesBuilder();
    out.addByte(_tlvMessageId);
    out.addByte(idBytes.length);
    out.add(idBytes);
    out.addByte(_tlvContent);
    out.addByte(contentBytes.length);
    out.add(contentBytes);
    return out.toBytes();
  }

  static PrivateMessagePacket? decode(Uint8List data) {
    var offset = 0;
    String? messageID;
    String? content;
    while (offset + 2 <= data.length) {
      final type = data[offset];
      final length = data[offset + 1];
      offset += 2;
      if (offset + length > data.length) return null;
      final value =
          Uint8List.sublistView(data, offset, offset + length);
      offset += length;
      switch (type) {
        case _tlvMessageId:
          messageID = utf8.decode(value, allowMalformed: true);
          break;
        case _tlvContent:
          content = utf8.decode(value, allowMalformed: true);
          break;
        default:
          // Unknown TLV type — bitchat rejects the packet.
          return null;
      }
    }
    if (messageID == null || content == null) return null;
    return PrivateMessagePacket(messageID: messageID, content: content);
  }
}
