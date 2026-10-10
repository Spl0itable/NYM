final RegExp _suffixRe = RegExp(r'#[0-9a-f]{4}$', caseSensitive: false);
final RegExp _hex4Re = RegExp(r'^[0-9a-f]{4}$', caseSensitive: false);

final Set<String> _seenSuffixes = <String>{};

/// Last 4 hex chars of the pubkey, or '????' if not hex.
String getPubkeySuffix(String pubkey) {
  if (pubkey.length < 4) return '????';
  final last4 = pubkey.substring(pubkey.length - 4);
  if (!_hex4Re.hasMatch(last4)) return '????';
  if (pubkey.length == 64) _seenSuffixes.add(last4.toLowerCase());
  return last4;
}

bool isSeenNymSuffix(String hex) => _seenSuffixes.contains(hex.toLowerCase());

String stripPubkeySuffix(String nym) => nym.replaceAll(_suffixRe, '');

String getNymFromPubkey(String baseNym, String pubkey) {
  final base = stripPubkeySuffix(baseNym);
  return '$base#${getPubkeySuffix(pubkey)}';
}

bool isPlaceholderNym(String? nym) {
  if (nym == null) return true;
  final base = stripPubkeySuffix(nym).trim();
  return base.isEmpty || base.toLowerCase() == 'nym';
}

String pickDisplayNym(String? liveNym, String? storedNym) {
  if (!isPlaceholderNym(liveNym)) return stripPubkeySuffix(liveNym!);
  if (!isPlaceholderNym(storedNym)) return stripPubkeySuffix(storedNym!);
  return 'nym';
}

final RegExp _nymSplitRe =
    RegExp(r'^([\s\S]*)#([0-9a-f]{4})$', caseSensitive: false);

/// Splits off only a trailing 4-hex `#xxxx` suffix, so names like `player#1` keep their `#`.
({String base, String suffix}) splitNymSuffix(String nym) {
  final m = _nymSplitRe.firstMatch(nym);
  if (m == null) return (base: nym, suffix: '');
  return (base: m.group(1)!, suffix: '#${m.group(2)!}');
}

/// PM conversation key: `pm-<sorted pubkeys>`.
String getPMConversationKey(String self, String other) {
  final pair = [self, other]..sort();
  return 'pm-${pair.join('-')}';
}
