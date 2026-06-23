// Nym display-name helpers ported from the PWA (docs/specs/03 §2.3).

final RegExp _suffixRe = RegExp(r'#[0-9a-f]{4}$', caseSensitive: false);
final RegExp _hex4Re = RegExp(r'^[0-9a-f]{4}$', caseSensitive: false);

/// Last 4 hex chars of the pubkey, or '????' if not hex.
String getPubkeySuffix(String pubkey) {
  if (pubkey.length < 4) return '????';
  final last4 = pubkey.substring(pubkey.length - 4);
  return _hex4Re.hasMatch(last4) ? last4 : '????';
}

/// Removes a trailing `#xxxx` hex suffix from a nym.
String stripPubkeySuffix(String nym) => nym.replaceAll(_suffixRe, '');

/// `base#suffix` display form for a pubkey + base nym.
String getNymFromPubkey(String baseNym, String pubkey) {
  final base = stripPubkeySuffix(baseNym);
  return '$base#${getPubkeySuffix(pubkey)}';
}

/// PM conversation key: `pm-<sorted pubkeys>` (docs/specs/03 §3.4).
String getPMConversationKey(String self, String other) {
  final pair = [self, other]..sort();
  return 'pm-${pair.join('-')}';
}
