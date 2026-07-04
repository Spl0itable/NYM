/// Web-of-trust ("nym-vouch") logic, ported 1:1 from the PWA.
///
/// The PWA gates channel spam behind a transitive trust graph rooted in the
/// verified developer + Nymbot pubkeys (app.js:1100-1101). Two sets drive it,
/// both held on [AppState] (the native analogue of the PWA app object):
///
///  * `nymchatPubkeys` — the trust GRAPH: every pubkey we believe is running a
///    Nymchat client. Seeded with the dev + bot roots, then grown by observing
///    PoW-valid channel messages / read receipts (`_markNymchatPubkey`,
///    messages.js:353) and by ingesting the kind-30078 `nym-vouches` lists of
///    peers already in the graph (`handleVouchEvent`, nostr-core.js:2663). A
///    sender in this set is never spam-gated.
///
///  * `nymchatVouches` — OUR OWN observation set: the pubkeys we've personally
///    seen running Nymchat. This is the list we publish as our kind-30078
///    `nym-vouches` event (`_observeNymchatPubkey` → `publishNymchatVouches`,
///    nostr-core.js:2623/2645) so other clients can expand their graph through
///    us.
///
/// Both sets are capped at [maxEntries]; on overflow the oldest entries are
/// dropped down to [trimEntries] (messages.js:356-358, nostr-core.js:2628-2630).
///
/// This file is intentionally socket-free and UI-free so the ingest + gating
/// rules are unit-testable in isolation (mirrors `poll_logic.dart`).
library;

/// Pure helpers for the Nymchat web-of-trust. All methods operate on the caller's
/// mutable [Set]s so [AppState] can own the storage (like `blockedUsers`).
class TrustGraph {
  TrustGraph._();

  /// Cap on `nymchatPubkeys` / `nymchatVouches` before trimming
  /// (messages.js:356 / nostr-core.js:2628: `size > 5000`).
  static const int maxEntries = 5000;

  /// Size each set is trimmed back to on overflow (`slice(-4000)`).
  static const int trimEntries = 4000;

  /// A lowercase 64-char hex pubkey (nostr-core.js:2674 `/^[0-9a-f]{64}$/i`).
  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

  /// True when [pubkey] is a well-formed 64-hex nostr key.
  static bool isHex64(String pubkey) => _hex64.hasMatch(pubkey);

  /// Adds [pubkey] to [set], trimming oldest-first when it exceeds [maxEntries]
  /// (mirrors `_markNymchatPubkey` / `_observeNymchatPubkey`). Returns true when
  /// [pubkey] was newly added. [selfPubkey] is never added (the PWA's
  /// `pubkey === this.pubkey` guards). Insertion order is preserved by [Set]
  /// (Dart's `LinkedHashSet`), so the trim drops the earliest-seen keys.
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

  /// Parses a kind-30078 `nym-vouches` event's `content` (a JSON array of hex
  /// pubkey strings) into the valid, non-self pubkeys it vouches for. Invalid
  /// JSON / non-array content yields an empty list (nostr-core.js:2668-2674).
  static List<String> parseVouchList(dynamic decodedContent, {String? selfPubkey}) {
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
