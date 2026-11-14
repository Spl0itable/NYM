final RegExp _rxChannelName = RegExp(r'^[\p{L}\p{N}]+$', unicode: true);
final RegExp _rxCased = RegExp(r'[\p{Lu}\p{Lt}]', unicode: true);
final RegExp _rxNonAscii = RegExp(r'[^\x00-\x7f]');

const List<int> _kLowerRanges = [
  0x37F, 0x37F, 1, 116, 0x524, 0x52E, 2, 1, 0x10C7, 0x10C7, 1, 7264,
  0x10CD, 0x10CD, 1, 7264, 0x13A0, 0x13EF, 1, 38864,
  0x13F0, 0x13F5, 1, 8, 0x1C89, 0x1C89, 1, 1, 0x1C90, 0x1CBA, 1, -3008,
  0x1CBD, 0x1CBF, 1, -3008, 0x2C2F, 0x2C2F, 1, 48,
  0x2C70, 0x2C70, 1, -10782, 0x2C7E, 0x2C7F, 1, -10815,
  0x2CEB, 0x2CED, 2, 1, 0x2CF2, 0x2CF2, 1, 1, 0xA660, 0xA660, 1, 1,
  0xA698, 0xA69A, 2, 1, 0xA78D, 0xA78D, 1, -42280, 0xA790, 0xA792, 2, 1,
  0xA796, 0xA7A8, 2, 1, 0xA7AA, 0xA7AA, 1, -42308,
  0xA7AB, 0xA7AB, 1, -42319, 0xA7AC, 0xA7AC, 1, -42315,
  0xA7AD, 0xA7AD, 1, -42305, 0xA7AE, 0xA7AE, 1, -42308,
  0xA7B0, 0xA7B0, 1, -42258, 0xA7B1, 0xA7B1, 1, -42282,
  0xA7B2, 0xA7B2, 1, -42261, 0xA7B3, 0xA7B3, 1, 928,
  0xA7B4, 0xA7C2, 2, 1, 0xA7C4, 0xA7C4, 1, -48,
  0xA7C5, 0xA7C5, 1, -42307, 0xA7C6, 0xA7C6, 1, -35384,
  0xA7C7, 0xA7C9, 2, 1, 0xA7CB, 0xA7CB, 1, -42343, 0xA7CC, 0xA7CC, 1, 1,
  0xA7D0, 0xA7D0, 1, 1, 0xA7D6, 0xA7DA, 2, 1, 0xA7DC, 0xA7DC, 1, -42561,
  0xA7F5, 0xA7F5, 1, 1, 0x104B0, 0x104D3, 1, 40, 0x10570, 0x1057A, 1, 39,
  0x1057C, 0x1058A, 1, 39, 0x1058C, 0x10592, 1, 39,
  0x10594, 0x10595, 1, 39, 0x10C80, 0x10CB2, 1, 64,
  0x10D50, 0x10D65, 1, 32, 0x118A0, 0x118BF, 1, 32,
  0x16E40, 0x16E5F, 1, 32, 0x1E900, 0x1E921, 1, 34,
];

bool isChannelName(String name) => _rxChannelName.hasMatch(name);

String _lowerRune(int r) {
  for (var i = 0; i < _kLowerRanges.length; i += 4) {
    final start = _kLowerRanges[i];
    if (r < start || r > _kLowerRanges[i + 1]) continue;
    if ((r - start) % _kLowerRanges[i + 2] != 0) continue;
    return String.fromCharCode(r + _kLowerRanges[i + 3]);
  }
  return String.fromCharCode(r).toLowerCase();
}

String lowerChannelName(String name) {
  if (!_rxNonAscii.hasMatch(name)) return name.toLowerCase();
  final out = StringBuffer();
  for (final r in name.runes) {
    out.write(r < 0x80 ? String.fromCharCode(r).toLowerCase() : _lowerRune(r));
  }
  return out.toString();
}

String sanitizeChannelName(String name) {
  if (name.isEmpty) return '';
  final lower = lowerChannelName(name);
  return isChannelName(lower) && !_rxCased.hasMatch(lower) ? lower : '';
}
