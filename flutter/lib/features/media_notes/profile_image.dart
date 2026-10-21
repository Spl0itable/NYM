import 'dart:typed_data';

const int kProfileAvatarMaxBytes = 5 * 1024 * 1024;
const int kProfileBannerMaxBytes = 10 * 1024 * 1024;

int profileImageMaxBytes({required bool avatar}) =>
    avatar ? kProfileAvatarMaxBytes : kProfileBannerMaxBytes;

bool _has(Uint8List b, List<int> sig, [int at = 0]) {
  if (b.length < at + sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[at + i] != sig[i]) return false;
  }
  return true;
}

String profileImageContentType(Uint8List bytes,
    {String path = '', String declared = ''}) {
  if (_has(bytes, const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (_has(bytes, const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (_has(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
      _has(bytes, const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  if (_has(bytes, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  final d = declared.split(';').first.trim().toLowerCase();
  if (d.startsWith('image/')) return d;
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}
