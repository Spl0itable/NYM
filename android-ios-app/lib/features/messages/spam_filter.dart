/// Heuristic content spam filter, ported 1:1 from the PWA
/// (`js/modules/nostr-core.js:806-940`). Pure, Flutter-free, and unit-testable
/// in isolation (mirrors `trust_graph.dart` / `flood_tracker.dart`).
///
/// This is the CONTENT heuristic — distinct from the web-of-trust spam GATE
/// (`AppState.isSpamGated`), which hides un-vouched strangers regardless of what
/// they say. Both feed [AppState.isMessageFiltered].
///
/// The PWA holds two booleans on the `nym` app object (`app.js:559-560`):
/// `spamFilterEnabled` and `spamFilterAggressive`, BOTH defaulting to `true`.
/// `isSpamMessage` short-circuits on `spamFilterEnabled === false` and, after
/// the two known-spam strings, on `spamFilterAggressive === false`. The Dart
/// port threads those as named params with the same `true` defaults.
///
/// Every Unicode-sensitive pattern is written with explicit `\u` escapes so the
/// source stays ASCII and the codepoints match the JS literals exactly.
library;

/// Pure heuristic spam detector. All methods are static; the gate booleans are
/// passed in (defaulting to the PWA's `true`).
class SpamFilter {
  SpamFilter._();

  /// Zero-width / bidi-control characters stripped before scoring
  /// (`_RX_ZERO_WIDTH`, nostr-core.js:806:
  /// `/[zero-width + bidi-control ranges]/g`. The `g`
  /// flag is irrelevant in Dart; [String.replaceAll] removes every occurrence.
  static final RegExp _rxZeroWidth = RegExp(
      '[\u200B\u200C\u200E\u200F\u202A-\u202E\u2060-\u206F\uFEFF]');

  /// Bigrams that are vanishingly rare in real English words; their presence in
  /// a long alphanumeric token is a tell of randomized/spam strings
  /// (`_RARE_BIGRAMS`, nostr-core.js:807). Kept verbatim and in order.
  static const List<String> _rareBigrams = [
    'xw', 'xz', 'xj', 'xk', 'wx', 'wz', 'wj', 'wq', 'jq', 'jx', 'jz',
    'kq', 'kx', 'kz', 'vq', 'vx', 'vz', 'zx', 'zk', 'zp', 'pq', 'pz',
    'fq', 'fz', 'gq', 'gz', 'hq', 'hz',
  ];

  // --- Reusable patterns (compiled once; the PWA inlines these as literals) ---
  static final RegExp _rxAlphaNum = RegExp(r'^[A-Za-z0-9]+$');
  static final RegExp _rxUpper = RegExp(r'[A-Z]');
  static final RegExp _rxLower = RegExp(r'[a-z]');
  static final RegExp _rxDigit = RegExp(r'[0-9]');
  static final RegExp _rxLatin = RegExp(r'[A-Za-z]');
  static final RegExp _rxAlphaNum8 = RegExp(r'^[A-Za-z0-9]{8,}$');
  static final RegExp _rxQNotU = RegExp('q(?!u)', caseSensitive: false);
  static final RegExp _rxWhitespace = RegExp(r'\s+');
  static final RegExp _rxOnlyAlphaNum = RegExp(r'^[a-zA-Z0-9]+$');
  static final RegExp _rxAlphaNumChar = RegExp(r'[A-Za-z0-9]');
  // `\p{Extended_Pictographic}` (JS: `/\p{Extended_Pictographic}/gu`). Built via
  // interpolation so the `valid_regexps` lint (which can't parse a standalone
  // Unicode-property literal) doesn't flag it — the same pattern
  // `message_content.dart` uses for its emoji units.
  static const String _emojiPattern = r'\p{Extended_Pictographic}';
  static final RegExp _rxEmoji = RegExp(_emojiPattern, unicode: true);

  // Word splitter for the long-word detector (nostr-core.js:909):
  // pattern: /[\s\u3000\u2000-\u200B\u0020\u00A0.,;!?\u3002\u3001\uFF0C\uFF1B\uFF01\uFF1F\n]/
  // — whitespace (incl. ideographic / unicode spaces), ASCII + CJK punctuation,
  // and newlines. `\\s` keeps the regex whitespace metachar; the rest are
  // explicit codepoints.
  static final RegExp _rxWordSplit = RegExp(
      '[\\s\u3000\u2000-\u200B\u0020\u00A0.,;!?\u3002\u3001\uFF0C\uFF1B\uFF01\uFF1F\n]');

  // Scrub patterns (nostr-core.js:932-936).
  static final RegExp _rxMention = RegExp(r'@\S+');
  static final RegExp _rxNostrId = RegExp(
      r'(nostr:)?(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+',
      caseSensitive: false);
  static final RegExp _rxHex64Word = RegExp(r'\b[0-9a-fA-F]{64}\b');

  // Early-return guard patterns (nostr-core.js:901-904).
  static final RegExp _rxLnInvoice =
      RegExp(r'^ln(bc|tb|ts)', caseSensitive: false);
  static final RegExp _rxCashu = RegExp(r'^cashu', caseSensitive: false);
  static final RegExp _rxNostrBech = RegExp(
      r'^(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+$',
      caseSensitive: false);
  static final RegExp _rxHex64Full = RegExp(r'^[0-9a-fA-F]{64}$');

  // Script ranges for mixed-script detection (nostr-core.js:834-838):
  // Cyrillic \u0400-\u04FF, Greek \u0370-\u03FF.
  static final RegExp _rxCyrillic = RegExp('[\u0400-\u04FF]');
  static final RegExp _rxGreek = RegExp('[\u0370-\u03FF]');
  static final RegExp _rxLetterAnyScript =
      RegExp('[A-Za-z\u0400-\u04FF\u0370-\u03FF]');

  // Vowels / interior-upper for the single-word alphanumeric score
  // (nostr-core.js:815-818).
  static final RegExp _rxVowel = RegExp('[aeiou]');
  static final RegExp _rxUpperRun = RegExp(r'[A-Z]');

  /// True when [content] looks like spam under the heuristic. 1:1 port of
  /// `isSpamMessage(content)` (nostr-core.js:887-940). [enabled] / [aggressive]
  /// mirror `spamFilterEnabled` / `spamFilterAggressive` (both default `true`,
  /// the PWA defaults).
  static bool isSpamMessage(
    Object? content, {
    bool enabled = true,
    bool aggressive = true,
  }) {
    if (enabled == false) return false;
    if (content is! String) return false;

    final trimmed = content.trim();

    if (trimmed.contains('joined the channel via bitchat.land')) return true;
    if (trimmed.contains('["client","chorus"]')) return true;

    if (aggressive == false) return false;

    if (trimmed.length < 6) return false;

    if (trimmed.contains('://') || trimmed.startsWith('www.')) return false;
    if (_rxLnInvoice.hasMatch(trimmed)) return false;
    if (_rxCashu.hasMatch(trimmed)) return false;
    if (_rxNostrBech.hasMatch(trimmed)) return false;
    if (_rxHex64Full.hasMatch(trimmed)) return false;
    if (trimmed.contains('```') || trimmed.contains('`')) return false;
    if (trimmed.startsWith('data:image')) return false;

    final filteredWords =
        trimmed.split(_rxWordSplit).where((w) => w.isNotEmpty).toList();
    var longestWord = 0;
    for (final w in filteredWords) {
      if (w.length > longestWord) longestWord = w.length;
    }

    if (longestWord > 100) {
      final hasOnlyAlphaNumeric = _rxOnlyAlphaNum.hasMatch(trimmed);
      if (hasOnlyAlphaNumeric && trimmed.length > 100) return true;

      String? longWord;
      for (final w in filteredWords) {
        if (w.length > 100) {
          longWord = w;
          break;
        }
      }
      if (longWord != null && _rxOnlyAlphaNum.hasMatch(longWord)) {
        final charFreq = <String, int>{};
        for (final char in longWord.split('')) {
          charFreq[char] = (charFreq[char] ?? 0) + 1;
        }
        final frequencies = charFreq.values.toList();
        final avgFreq = longWord.length / charFreq.keys.length;
        var sumSq = 0.0;
        for (final freq in frequencies) {
          final d = freq - avgFreq;
          sumSq += d * d;
        }
        final variance = sumSq / frequencies.length;
        if (variance < 2 && longWord.length > 100) return true;
      }
    }

    // Score against the user's own text only: @mentions (whose digit-heavy
    // #suffix would otherwise trip the heuristics) and quoted lines don't count.
    final scrubbed = trimmed
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('>'))
        .join('\n')
        .replaceAll(_rxMention, ' ')
        .replaceAll(_rxNostrId, ' ')
        .replaceAll(_rxHex64Word, ' ')
        .trim();

    return spamScore(scrubbed) >= 3;
  }

  /// Heuristic score for already-scrubbed text. 1:1 port of `_spamScore`
  /// (nostr-core.js:845-879). Exposed (non-private) so unit tests can probe the
  /// scorer directly, the way the PWA does internally.
  static int spamScore(String input) {
    var score = 0;

    final trimmed = input.replaceAll(_rxZeroWidth, '');
    if (_hasRepeatedTokenSpam(trimmed)) score += 3;
    if (_hasMixedScriptToken(trimmed)) score += 2;

    final tokens =
        trimmed.split(_rxWhitespace).where((t) => t.isNotEmpty).toList();
    if (tokens.length == 1) {
      if (_looksLikeRandomToken(tokens[0])) score += 3;
      score += _scoreSingleAlphanumWord(tokens[0]);
      if (tokens[0].length >= 12) {
        final alnum = _countMatches(tokens[0], _rxAlphaNumChar);
        if (alnum / tokens[0].length >= 0.5) score += 1;
      }
    } else {
      var gibberish = 0, analyzable = 0;
      for (final tok in tokens) {
        if (tok.length < 6) continue;
        analyzable++;
        if (_looksLikeRandomToken(tok)) gibberish++;
      }
      if (analyzable > 0 && gibberish / analyzable >= 0.5) score += 3;
    }

    final digitCount = _countMatches(trimmed, _rxDigit);
    final letterCount = _countMatches(trimmed, _rxLatin);
    if (trimmed.length >= 8 &&
        letterCount > 0 &&
        digitCount / trimmed.length > 0.5) {
      score += 1;
    }

    // Heavy emoji + text floods (a lone emoji is normal chat and never trips
    // this). `\p{Extended_Pictographic}` → Dart unicode property class.
    final emojiMatches = _countMatches(trimmed, _rxEmoji);
    if (emojiMatches >= 4 && letterCount > 0) score += 1;

    return score;
  }

  /// True when [nym] looks like a randomized spam-bot nickname. 1:1 port of
  /// `isGibberishNym(nym)` (nostr-core.js:943-950): off unless BOTH the spam
  /// filter and its aggressive mode are on, requires a string of length >= 8
  /// (after trim), then defers to the same [_looksLikeRandomToken] detector the
  /// content scorer uses. [enabled] / [aggressive] mirror `spamFilterEnabled` /
  /// `spamFilterAggressive` (both default `true`, the PWA defaults).
  ///
  /// Callers (channel ingest drop, sidebar Nyms list/count) feed the BARE
  /// stripped nym and gate it on `!isOwn && !isFriend`, matching nostr-core.js:
  /// 363-367 and users.js:1375-1377.
  static bool isGibberishNym(
    Object? nym, {
    bool enabled = true,
    bool aggressive = true,
  }) {
    if (enabled == false) return false;
    if (aggressive == false) return false;
    if (nym is! String) return false;
    final n = nym.trim();
    if (n.isEmpty || n.length < 8) return false;
    return _looksLikeRandomToken(n);
  }

  /// 1:1 port of `_looksLikeRandomToken(token)` (nostr-core.js:746-772).
  static bool _looksLikeRandomToken(String token) {
    if (token.isEmpty || token.length < 8) return false;
    if (!_rxAlphaNum.hasMatch(token)) return false;

    final hasUpper = _rxUpper.hasMatch(token);
    final hasLower = _rxLower.hasMatch(token);

    final half = token.length ~/ 2;
    for (var unit = 3; unit <= half; unit++) {
      final head = token.substring(0, unit);
      if (token.substring(unit, unit * 2) == head) {
        if (head.split('').toSet().length >= 3) return true;
      }
    }

    if (hasUpper && hasLower) {
      var interiorUpper = 0;
      for (var i = 1; i < token.length; i++) {
        final c = token.codeUnitAt(i);
        if (c >= 65 && c <= 90) interiorUpper++;
      }
      final interiorUpperRatio = interiorUpper / (token.length - 1);
      if (interiorUpper >= 3 && interiorUpperRatio >= 0.3) return true;
    }

    return false;
  }

  /// 1:1 port of `_hasRepeatedTokenSpam(trimmed)` (nostr-core.js:774-804).
  static bool _hasRepeatedTokenSpam(String trimmed) {
    final tokens =
        trimmed.split(_rxWhitespace).where((t) => t.isNotEmpty).toList();
    if (tokens.length >= 2) {
      final first = tokens[0];
      if (first.length >= 6 &&
          _rxAlphaNum.hasMatch(first) &&
          tokens.every((t) => t == first)) {
        return true;
      }
      var baseLen = tokens[0].length;
      for (final t in tokens) {
        if (t.length < baseLen) baseLen = t.length;
      }
      if (baseLen >= 6) {
        String? base;
        for (final t in tokens) {
          if (t.length == baseLen) {
            base = t;
            break;
          }
        }
        if (base != null &&
            _rxAlphaNum.hasMatch(base) &&
            tokens.every((t) {
              if (t.length % baseLen != 0) return false;
              for (var i = 0; i < t.length; i += baseLen) {
                if (t.substring(i, i + baseLen) != base) return false;
              }
              return true;
            })) {
          return true;
        }
      }
    }
    if (tokens.length == 1 &&
        tokens[0].length >= 12 &&
        _rxAlphaNum.hasMatch(tokens[0])) {
      final t = tokens[0];
      for (var unit = 4; unit <= t.length ~/ 2; unit++) {
        final head = t.substring(0, unit);
        if (t.substring(unit, unit * 2) == head &&
            head.split('').toSet().length >= 3) {
          return true;
        }
      }
    }
    return false;
  }

  /// 1:1 port of `_hasMixedScriptToken(text)` (nostr-core.js:830-843).
  static bool _hasMixedScriptToken(String text) {
    for (final tok in text.split(_rxWhitespace)) {
      if (tok.length < 4) continue;
      final hasLatin = _rxLatin.hasMatch(tok);
      final hasCyrillic = _rxCyrillic.hasMatch(tok);
      final hasGreek = _rxGreek.hasMatch(tok);
      final scripts =
          (hasLatin ? 1 : 0) + (hasCyrillic ? 1 : 0) + (hasGreek ? 1 : 0);
      if (scripts < 2) continue;
      final letterCount = _countMatches(tok, _rxLetterAnyScript);
      if (letterCount / tok.length < 0.6) continue;
      return true;
    }
    return false;
  }

  /// 1:1 port of `_scoreSingleAlphanumWord(token)` (nostr-core.js:809-828).
  static int _scoreSingleAlphanumWord(String token) {
    if (!_rxAlphaNum8.hasMatch(token)) return 0;
    var score = 1;
    final lower = token.toLowerCase();
    final hasDigit = _rxDigit.hasMatch(token);
    if (hasDigit && _rxLatin.hasMatch(token)) score += 1;
    final interiorUpper = _countMatches(token.substring(1), _rxUpperRun);
    if (interiorUpper >= 3) score += 1;
    final vowelCount = _countMatches(lower, _rxVowel);
    final vowelRatio = vowelCount / token.length;
    if (vowelRatio <= 0.2) score += 1;
    // 'q' in English is almost always followed by 'u'; violating that is a
    // strong tell.
    if (_rxQNotU.hasMatch(token)) score += 2;
    var rare = 0;
    for (final bg in _rareBigrams) {
      if (lower.contains(bg)) rare++;
    }
    if (rare > 0) score += rare < 2 ? rare : 2;
    return score;
  }

  /// Counts non-overlapping matches of [re] in [s] — the Dart analogue of
  /// `(s.match(/re/g) || []).length`.
  static int _countMatches(String s, RegExp re) => re.allMatches(s).length;
}
