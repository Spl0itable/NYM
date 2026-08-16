import 'dart:convert';
import 'dart:typed_data';

/// The payload of a public [MeshMessageType.message] packet — a byte-for-byte
/// port of bitchat's `BitchatMessage.toBinaryPayload` / `fromBinaryPayload`.
/// These are unencrypted broadcast messages (nearby public chat / geohash-style
/// channels); authenticity comes from the enclosing packet's Ed25519 signature.
///
/// Layout (big-endian):
/// ```
/// flags:1 | timestamp:8 (u64 ms) | idLen:1 + id | senderLen:1 + sender |
/// contentLen:2 + content | [originalSender:1+utf8] | [recipientNick:1+utf8] |
/// [senderPeerID:1+utf8] | [mentionCount:1, (len:1+utf8)*n] | [channel:1+utf8]
/// ```
/// Flag bits: 0x01 relay, 0x02 private, 0x04 hasOriginalSender,
/// 0x08 hasRecipientNickname, 0x10 hasSenderPeerID, 0x20 hasMentions,
/// 0x40 hasChannel, 0x80 isEncrypted.
class BitchatMessage {
  BitchatMessage({
    required this.id,
    required this.sender,
    required this.content,
    required this.timestampMs,
    this.isRelay = false,
    this.isPrivate = false,
    this.originalSender,
    this.recipientNickname,
    this.senderPeerID,
    this.mentions,
    this.channel,
    this.isEncrypted = false,
    this.encryptedContent,
  });

  final String id;
  final String sender;
  final String content;
  final int timestampMs;
  final bool isRelay;
  final bool isPrivate;
  final String? originalSender;
  final String? recipientNickname;
  final String? senderPeerID;
  final List<String>? mentions;
  final String? channel;
  final bool isEncrypted;
  final Uint8List? encryptedContent;

  static const int _flagRelay = 0x01;
  static const int _flagPrivate = 0x02;
  static const int _flagHasOriginalSender = 0x04;
  static const int _flagHasRecipientNickname = 0x08;
  static const int _flagHasSenderPeerID = 0x10;
  static const int _flagHasMentions = 0x20;
  static const int _flagHasChannel = 0x40;
  static const int _flagEncrypted = 0x80;

  Uint8List toBinaryPayload() {
    final out = BytesBuilder();

    var flags = 0;
    if (isRelay) flags |= _flagRelay;
    if (isPrivate) flags |= _flagPrivate;
    if (originalSender != null) flags |= _flagHasOriginalSender;
    if (recipientNickname != null) flags |= _flagHasRecipientNickname;
    if (senderPeerID != null) flags |= _flagHasSenderPeerID;
    if (mentions != null && mentions!.isNotEmpty) flags |= _flagHasMentions;
    if (channel != null) flags |= _flagHasChannel;
    if (isEncrypted) flags |= _flagEncrypted;
    out.addByte(flags);

    _u64(out, timestampMs);
    _lenPrefixed8(out, utf8.encode(id));
    _lenPrefixed8(out, utf8.encode(sender));

    if (isEncrypted && encryptedContent != null) {
      _lenPrefixed16(out, encryptedContent!);
    } else {
      _lenPrefixed16(out, utf8.encode(content));
    }

    if (originalSender != null) _lenPrefixed8(out, utf8.encode(originalSender!));
    if (recipientNickname != null) {
      _lenPrefixed8(out, utf8.encode(recipientNickname!));
    }
    if (senderPeerID != null) _lenPrefixed8(out, utf8.encode(senderPeerID!));

    if (mentions != null && mentions!.isNotEmpty) {
      final list = mentions!.take(255).toList();
      out.addByte(list.length);
      for (final m in list) {
        _lenPrefixed8(out, utf8.encode(m));
      }
    }

    if (channel != null) _lenPrefixed8(out, utf8.encode(channel!));

    return out.toBytes();
  }

  static BitchatMessage? fromBinaryPayload(Uint8List data) {
    try {
      if (data.length < 13) return null;
      final r = _Reader(data);

      final flags = r.u8();
      final isRelay = (flags & _flagRelay) != 0;
      final isPrivate = (flags & _flagPrivate) != 0;
      final hasOriginalSender = (flags & _flagHasOriginalSender) != 0;
      final hasRecipientNickname = (flags & _flagHasRecipientNickname) != 0;
      final hasSenderPeerID = (flags & _flagHasSenderPeerID) != 0;
      final hasMentions = (flags & _flagHasMentions) != 0;
      final hasChannel = (flags & _flagHasChannel) != 0;
      final isEncrypted = (flags & _flagEncrypted) != 0;

      final timestampMs = r.u64();
      final id = r.str8();
      if (id == null) return null;
      final sender = r.str8();
      if (sender == null) return null;

      final contentLength = r.u16();
      if (r.remaining < contentLength) return null;
      String content = '';
      Uint8List? encryptedContent;
      if (isEncrypted) {
        encryptedContent = r.take(contentLength);
      } else {
        content = utf8.decode(r.take(contentLength), allowMalformed: true);
      }

      final originalSender = hasOriginalSender ? r.str8() : null;
      final recipientNickname = hasRecipientNickname ? r.str8() : null;
      final senderPeerID = hasSenderPeerID ? r.str8() : null;

      List<String>? mentions;
      if (hasMentions && r.hasRemaining) {
        final count = r.u8();
        final list = <String>[];
        for (var i = 0; i < count && r.hasRemaining; i++) {
          final m = r.str8();
          if (m != null) list.add(m);
        }
        if (list.isNotEmpty) mentions = list;
      }

      final channel = hasChannel && r.hasRemaining ? r.str8() : null;

      return BitchatMessage(
        id: id,
        sender: sender,
        content: content,
        timestampMs: timestampMs,
        isRelay: isRelay,
        isPrivate: isPrivate,
        originalSender: originalSender,
        recipientNickname: recipientNickname,
        senderPeerID: senderPeerID,
        mentions: mentions,
        channel: channel,
        isEncrypted: isEncrypted,
        encryptedContent: encryptedContent,
      );
    } catch (_) {
      return null;
    }
  }

  static void _u64(BytesBuilder out, int v) {
    final b = BigInt.from(v);
    for (var i = 7; i >= 0; i--) {
      out.addByte(((b >> (i * 8)) & BigInt.from(0xFF)).toInt());
    }
  }

  static void _lenPrefixed8(BytesBuilder out, List<int> bytes) {
    final n = bytes.length > 255 ? 255 : bytes.length;
    out.addByte(n);
    out.add(bytes.sublist(0, n));
  }

  static void _lenPrefixed16(BytesBuilder out, List<int> bytes) {
    final n = bytes.length > 0xFFFF ? 0xFFFF : bytes.length;
    out.addByte((n >> 8) & 0xFF);
    out.addByte(n & 0xFF);
    out.add(bytes.sublist(0, n));
  }
}

class _Reader {
  _Reader(this._buf);
  final Uint8List _buf;
  int _pos = 0;

  int get remaining => _buf.length - _pos;
  bool get hasRemaining => _pos < _buf.length;

  int u8() => _buf[_pos++];

  int u16() {
    final v = (_buf[_pos] << 8) | _buf[_pos + 1];
    _pos += 2;
    return v;
  }

  int u64() {
    var v = BigInt.zero;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | BigInt.from(_buf[_pos + i]);
    }
    _pos += 8;
    return v.toInt();
  }

  Uint8List take(int n) {
    final out = Uint8List.fromList(Uint8List.sublistView(_buf, _pos, _pos + n));
    _pos += n;
    return out;
  }

  /// Reads a 1-byte-length-prefixed UTF-8 string, or null if truncated.
  String? str8() {
    if (!hasRemaining) return null;
    final len = u8();
    if (remaining < len) return null;
    return utf8.decode(take(len), allowMalformed: true);
  }
}
