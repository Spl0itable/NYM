import '../../models/nostr_event.dart';
import 'bitchat_verify.dart';

const List<int> kEncryptedBlobChannelKinds = [20000, 23333];

const List<int> _ivBytes = [12, 16];

const int _minPayloadBytes = 16;

const int _maxSegments = 8;

final RegExp _hex = RegExp(r'^[0-9a-fA-F]+$');

final RegExp _prefix = RegExp(r'^v\d{1,2}:');

final RegExp _standard = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

final RegExp _urlSafe = RegExp(r'^[A-Za-z0-9_-]+={0,2}$');

final RegExp _padding = RegExp(r'=+$');

const String _ws =
    '\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff';

final RegExp _edgeSpace = RegExp('^[$_ws]+|[$_ws]+\$');

int _segmentBytes(String seg) {
  if (seg.isEmpty || !(_standard.hasMatch(seg) || _urlSafe.hasMatch(seg))) {
    return -1;
  }
  final body = seg.replaceFirst(_padding, '').length;
  if (body != seg.length && seg.length % 4 != 0) return -1;
  if (body % 4 == 1) return -1;
  return body * 3 ~/ 4;
}

bool isEncryptedBlobContent(String content) {
  if (content.isEmpty) return false;
  final segs = content
      .replaceAll(_edgeSpace, '')
      .replaceFirst(_prefix, '')
      .split(':');
  if (segs.length < 2 || segs.length > _maxSegments) return false;
  if (_hex.hasMatch(segs.last)) return false;
  final sizes = segs.map(_segmentBytes).toList();
  if (sizes.any((n) => n < 0)) return false;
  if (sizes.last < _minPayloadBytes) return false;
  return sizes.sublist(0, sizes.length - 1).any(_ivBytes.contains);
}

bool isEncryptedBlobChannelKind(int kind) =>
    kEncryptedBlobChannelKinds.contains(kind);

bool isDroppedChannelContent(String content) =>
    isEncryptedBlobContent(content) || isBitchatVerifyContent(content);

bool isEncryptedBlobChannelEvent(NostrEvent e) =>
    isEncryptedBlobChannelKind(e.kind) && isDroppedChannelContent(e.content);

const List<int> _pointerKinds = [7, 9735, 20000, 23333];

bool pointsAtDroppedBlob(NostrEvent e, Set<String> dropped) {
  if (dropped.isEmpty || !_pointerKinds.contains(e.kind)) return false;
  return e.tags.any(
    (t) => t.length > 1 && t[0] == 'e' && dropped.contains(t[1]),
  );
}
