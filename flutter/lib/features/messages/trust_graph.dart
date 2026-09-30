/// Web-of-trust logic: `nymchatPubkeys` is the trust graph (never spam-gated), `nymchatVouches` our published observations.
library;

/// Pure helpers over caller-owned mutable sets.
class TrustGraph {
  TrustGraph._();

  /// Cap before trimming.
  static const int maxEntries = 5000;

  /// Size each set is trimmed back to on overflow.
  static const int trimEntries = 4000;

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

  static bool isHex64(String pubkey) => _hex64.hasMatch(pubkey);

  /// Adds [pubkey] (never [selfPubkey]), trimming earliest-seen first past [maxEntries]; true when newly added.
  static bool add(Set<String> set, String pubkey, {String? selfPubkey}) {
    if (pubkey.isEmpty || pubkey == selfPubkey) return false;
    if (set.contains(pubkey)) return false;
    set.add(pubkey);
    if (set.length > maxEntries) {
      final kept = set.toList().sublist(set.length - trimEntries);
      set
        ..clear()
        ..addAll(kept);
    }
    return true;
  }

  /// Valid, non-self pubkeys from a `nym-vouches` JSON array; anything else yields an empty list.
  static List<String> parseVouchList(dynamic decodedContent,
      {String? selfPubkey}) {
    if (decodedContent is! List) return const [];
    final out = <String>[];
    for (final pk in decodedContent) {
      if (pk is! String) continue;
      if (!isHex64(pk)) continue;
      if (pk == selfPubkey) continue;
      out.add(pk);
    }
    return out;
  }
}
