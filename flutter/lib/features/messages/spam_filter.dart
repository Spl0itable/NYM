/// Heuristic content spam filter; unicode patterns use `\u` escapes to match the JS exactly.
library;

/// Pure static detector; gate booleans default to `true` like the PWA.
class SpamFilter {
  SpamFilter._();

  /// Zero-width and bidi-control characters stripped before scoring.
  static final RegExp _rxZeroWidth =
      RegExp('[\u200B\u200C\u200E\u200F\u202A-\u202E\u2060-\u206F\uFEFF]');

  /// Bigrams rare in English; kept verbatim and in order.
  static const List<String> _rareBigrams = [
    'xw',
    'xz',
    'xj',
    'xk',
    'wx',
    'wz',
    'wj',
    'wq',
    'jq',
    'jx',
    'jz',
    'kq',
    'kx',
    'kz',
    'vq',
    'vx',
    'vz',
    'zx',
    'zk',
    'zp',
    'pq',
    'pz',
    'fq',
    'fz',
    'gq',
    'gz',
    'hq',
    'hz',
  ];

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
  // Built via interpolation so the `valid_regexps` lint doesn't flag the Unicode property literal.
  static const String _emojiPattern = r'\p{Extended_Pictographic}';
  static final RegExp _rxEmoji = RegExp(_emojiPattern, unicode: true);

  // Splits on whitespace (including unicode spaces), ASCII and CJK punctuation, and newlines.
  static final RegExp _rxWordSplit = RegExp(
      '[\\s\u3000\u2000-\u200B\u0020\u00A0.,;!?\u3002\u3001\uFF0C\uFF1B\uFF01\uFF1F\n]');

  static final RegExp _rxMention = RegExp(r'@\S+');
  static final RegExp _rxNostrId = RegExp(
      r'(nostr:)?(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+',
      caseSensitive: false);
  static final RegExp _rxHex64Word = RegExp(r'\b[0-9a-fA-F]{64}\b');

  static final RegExp _rxLnInvoice =
      RegExp(r'^ln(bc|tb|ts)', caseSensitive: false);
  static final RegExp _rxCashu = RegExp(r'^cashu', caseSensitive: false);
  static final RegExp _rxNostrBech = RegExp(
      r'^(npub|nsec|note|nevent|naddr|nprofile)1[a-z0-9]+$',
      caseSensitive: false);
  static final RegExp _rxHex64Full = RegExp(r'^[0-9a-fA-F]{64}$');

  static final RegExp _rxCyrillic = RegExp('[\u0400-\u04FF]');
  static final RegExp _rxGreek = RegExp('[\u0370-\u03FF]');
  static final RegExp _rxLetterAnyScript =
      RegExp('[A-Za-z\u0400-\u04FF\u0370-\u03FF]');

  static final RegExp _rxVowel = RegExp('[aeiou]');
  static final RegExp _rxUpperRun = RegExp(r'[A-Z]');

  /// Domains stripped from text rather than dropping the message, which would hide the conversation around it.
  static const List<String> maliciousDomains = ['glub.chat'];

  /// Scheme, subdomains and trailing path optional, so full URLs and bare domains both go.
  static final RegExp _rxMaliciousDomain = RegExp(
    '(?:https?:\\/\\/)?(?:[\\w-]+\\.)*(?:'
    '${maliciousDomains.map((d) => d.replaceAll('.', '\\.')).join('|')}'
    ')\\b(?:\\/[^\\s]*)?',
    caseSensitive: false,
  );
  static final RegExp _rxMaliciousHint = RegExp(
    maliciousDomains.map((d) => d.replaceAll('.', '\\.')).join('|'),
    caseSensitive: false,
  );
  static final RegExp _rxDoubleSpace = RegExp(r'[ \t]{2,}');
  static final RegExp _rxSpaceBeforePunct = RegExp(r'[ \t]+([.,!?;:])');

  /// Removes known-malicious domains, leaving the rest of the message intact.
  static String stripMaliciousDomains(String content) {
    if (content.isEmpty ||
        !_rxMaliciousHint.hasMatch(content) ||
        !_rxMaliciousDomain.hasMatch(content)) {
      return content;
    }
    return content
        .replaceAll(_rxMaliciousDomain, '')
        // Collapse the gap the link leaves behind.
        .replaceAll(_rxDoubleSpace, ' ')
        .replaceAllMapped(_rxSpaceBeforePunct, (m) => m[1]!)
        .trim();
  }

  static bool isSpamMessage(
    Object? content, {
    bool enabled = true,
    bool aggressive = true,
  }) {
    if (enabled == false) return false;
    if (content is! String) return false;

    final trimmed = content.trim();

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

    // Score only the user's own text: @mentions and quoted lines don't count.
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

  /// Score for already-scrubbed text; public so tests can probe it.
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

    // A lone emoji never trips this.
    final emojiMatches = _countMatches(trimmed, _rxEmoji);
    if (emojiMatches >= 4 && letterCount > 0) score += 1;

    return score;
  }

  /// Randomized spam-bot nick check; needs both filter flags on and length >= 8.
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
    // 'q' not followed by 'u' is a strong tell.
    if (_rxQNotU.hasMatch(token)) score += 2;
    var rare = 0;
    for (final bg in _rareBigrams) {
      if (lower.contains(bg)) rare++;
    }
    if (rare > 0) score += rare < 2 ? rare : 2;
    return score;
  }

  static int _countMatches(String s, RegExp re) => re.allMatches(s).length;
}
