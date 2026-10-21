import 'dart:convert';
import 'dart:typed_data';

const String kNdefAid = 'D2760000850101';
const int kNdefFileSize = 0x0800;
const int kNdefMaxRecords = 16;
const int kNdefMaxUriBytes = 4096;
const int kNdefMaxMessageBytes = 65536;

const List<String> kNdefUriPrefixes = [
  '',
  'http://www.',
  'https://www.',
  'http://',
  'https://',
  'tel:',
  'mailto:',
  'ftp://anonymous:anonymous@',
  'ftp://ftp.',
  'ftps://',
  'sftp://',
  'smb://',
  'nfs://',
  'ftp://',
  'dav://',
  'news:',
  'telnet://',
  'imap:',
  'rtsp://',
  'urn:',
  'pop:',
  'sip:',
  'sips:',
  'tftp:',
  'btspp://',
  'btl2cap://',
  'btgoep://',
  'tcpobex://',
  'irdaobex://',
  'file://',
  'urn:epc:id:',
  'urn:epc:tag:',
  'urn:epc:pat:',
  'urn:epc:raw:',
  'urn:epc:',
  'urn:nfc:',
];

class NdefRecord {
  NdefRecord({
    required this.tnf,
    required this.type,
    Uint8List? id,
    required this.payload,
  }) : id = id ?? Uint8List(0);

  final int tnf;
  final Uint8List type;
  final Uint8List id;
  final Uint8List payload;
}

Uint8List ndefUriRecordPayload(String uri) {
  var code = 0;
  var best = 0;
  for (var i = 1; i < kNdefUriPrefixes.length; i++) {
    final p = kNdefUriPrefixes[i];
    if (p.length > best && uri.startsWith(p)) {
      code = i;
      best = p.length;
    }
  }
  return Uint8List.fromList([code, ...utf8.encode(uri.substring(best))]);
}

Uint8List ndefUriMessage(String uri) {
  final payload = ndefUriRecordPayload(uri);
  final n = payload.length;
  final b = BytesBuilder(copy: false);
  if (n <= 255) {
    b.add([0xD1, 0x01, n]);
  } else {
    b.add([0xC1, 0x01, (n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF]);
  }
  b.addByte(0x55);
  b.add(payload);
  return b.toBytes();
}

Uint8List ndefType4Cc() => Uint8List.fromList([
      0x00, 0x0F,
      0x20,
      0x00, 0xFA,
      0x00, 0x34,
      0x04, 0x06,
      0xE1, 0x04,
      (kNdefFileSize >> 8) & 0xFF, kNdefFileSize & 0xFF,
      0x00,
      0xFF,
    ]);

Uint8List? ndefType4File(Uint8List message) {
  final n = message.length;
  if (n + 2 > kNdefFileSize) return null;
  return Uint8List.fromList([(n >> 8) & 0xFF, n & 0xFF, ...message]);
}

List<NdefRecord>? parseNdefMessage(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > kNdefMaxMessageBytes) return null;
  final out = <NdefRecord>[];
  var i = 0;
  var first = true;
  while (true) {
    if (i >= bytes.length) return null;
    final h = bytes[i++];
    final mb = h & 0x80 != 0;
    final me = h & 0x40 != 0;
    final cf = h & 0x20 != 0;
    final sr = h & 0x10 != 0;
    final il = h & 0x08 != 0;
    final tnf = h & 0x07;
    if (mb != first || cf || tnf == 6 || tnf == 7) return null;
    if (i >= bytes.length) return null;
    final typeLen = bytes[i++];
    int payloadLen;
    if (sr) {
      if (i >= bytes.length) return null;
      payloadLen = bytes[i++];
    } else {
      if (i + 4 > bytes.length) return null;
      payloadLen = (bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3];
      i += 4;
    }
    var idLen = 0;
    if (il) {
      if (i >= bytes.length) return null;
      idLen = bytes[i++];
    }
    if (payloadLen > bytes.length - i) return null;
    final end = i + typeLen + idLen + payloadLen;
    if (end > bytes.length) return null;
    final type = Uint8List.sublistView(bytes, i, i + typeLen);
    i += typeLen;
    final id = Uint8List.sublistView(bytes, i, i + idLen);
    i += idLen;
    final payload = Uint8List.sublistView(bytes, i, i + payloadLen);
    i += payloadLen;
    if (tnf == 0 && (typeLen != 0 || idLen != 0 || payloadLen != 0)) return null;
    if (out.length < kNdefMaxRecords) {
      out.add(NdefRecord(tnf: tnf, type: type, id: id, payload: payload));
    }
    first = false;
    if (me) {
      return i == bytes.length ? out : null;
    }
  }
}

String? _utf8(List<int> b) {
  try {
    return utf8.decode(b);
  } on FormatException {
    return null;
  }
}

bool _isUriRecord(NdefRecord r) =>
    (r.tnf == 1 && r.type.length == 1 && r.type[0] == 0x55) || r.tnf == 3;

String? ndefRecordUri(NdefRecord r) {
  if (!_isUriRecord(r)) return null;
  if (r.tnf == 3) {
    if (r.type.isEmpty || r.type.length > kNdefMaxUriBytes) return null;
    final s = _utf8(r.type);
    return s == null || s.isEmpty ? null : s;
  }
  final p = r.payload;
  if (p.isEmpty || p.length > kNdefMaxUriBytes + 1) return null;
  final code = p[0];
  if (code >= kNdefUriPrefixes.length) return null;
  final rest = _utf8(Uint8List.sublistView(p, 1));
  if (rest == null) return null;
  final uri = '${kNdefUriPrefixes[code]}$rest';
  return uri.isEmpty ? null : uri;
}

String? firstNdefUri(List<NdefRecord> records) {
  for (final r in records) {
    if (_isUriRecord(r)) return ndefRecordUri(r);
  }
  return null;
}

List<NdefRecord> ndefRecordsFromChannel(Object? raw) {
  if (raw is! List) return const [];
  final out = <NdefRecord>[];
  for (final e in raw) {
    if (out.length >= kNdefMaxRecords) break;
    if (e is! List || e.length != 4) continue;
    final tnf = e[0];
    final type = e[1];
    final id = e[2];
    final payload = e[3];
    if (tnf is! int || tnf < 0 || tnf > 7) continue;
    if (type is! Uint8List || id is! Uint8List || payload is! Uint8List) continue;
    out.add(NdefRecord(tnf: tnf, type: type, id: id, payload: payload));
  }
  return out;
}
