import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Opt-in keyword packs, and the matcher that makes them survive evasion
/// without inventing false positives.
///
/// A direct port of the PWA's `js/modules/filter-packs.js`, reading the same
/// `data/filter-packs/*.json` — bundled as assets here rather than fetched,
/// because a phone that is offline should still filter. The two must agree
/// term for term and rule for rule: the setting syncs across devices, so a
/// pack that behaves differently on mobile is a message that is hidden on the
/// laptop and visible on the phone, with nothing to explain the difference.
/// `test/filter_packs_test.dart` runs the same corpus as the PWA's
/// `scripts/test-filter-packs.mjs` and asserts the same verdicts.
///
/// The hard part is not the word list. "fuck", "f u c k", "f.u.c.k", "fuuuck",
/// "f\u200buck" and "fυck" are the same word to a reader and six different
/// strings to `contains()`, while "Scunthorpe", "classic", "assassin" and
/// "analysis" are NOT the words they contain. So the text is normalized once
/// and then matched as WHOLE WORDS — the word boundary being the single most
/// important defense against false positives.

/// Precomposed Latin letters folded to their base. Dart has no
/// `String.normalize()`, so this table is GENERATED from Node's Unicode data
/// (NFD, strip U+0300-U+036F, NFC) over U+00C0-U+024F and U+1E00-U+1EFF. It is
/// therefore the same fold the PWA performs, rather than an approximation of
/// it. Greek and Cyrillic accented forms are deliberately absent: those
/// scripts are handled by the homoglyph table, and stripping their marks would
/// merge letters that are genuinely distinct.
const Map<String, String> _latinFold = {
  'À': 'A', 'Á': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A', 'Ç': 'C', 'È': 'E',
  'É': 'E', 'Ê': 'E', 'Ë': 'E', 'Ì': 'I', 'Í': 'I', 'Î': 'I', 'Ï': 'I', 'Ñ': 'N',
  'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O', 'Ù': 'U', 'Ú': 'U', 'Û': 'U',
  'Ü': 'U', 'Ý': 'Y', 'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
  'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ì': 'i', 'í': 'i', 'î': 'i',
  'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ù': 'u',
  'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'Ā': 'A', 'ā': 'a', 'Ă': 'A',
  'ă': 'a', 'Ą': 'A', 'ą': 'a', 'Ć': 'C', 'ć': 'c', 'Ĉ': 'C', 'ĉ': 'c', 'Ċ': 'C',
  'ċ': 'c', 'Č': 'C', 'č': 'c', 'Ď': 'D', 'ď': 'd', 'Ē': 'E', 'ē': 'e', 'Ĕ': 'E',
  'ĕ': 'e', 'Ė': 'E', 'ė': 'e', 'Ę': 'E', 'ę': 'e', 'Ě': 'E', 'ě': 'e', 'Ĝ': 'G',
  'ĝ': 'g', 'Ğ': 'G', 'ğ': 'g', 'Ġ': 'G', 'ġ': 'g', 'Ģ': 'G', 'ģ': 'g', 'Ĥ': 'H',
  'ĥ': 'h', 'Ĩ': 'I', 'ĩ': 'i', 'Ī': 'I', 'ī': 'i', 'Ĭ': 'I', 'ĭ': 'i', 'Į': 'I',
  'į': 'i', 'İ': 'I', 'Ĵ': 'J', 'ĵ': 'j', 'Ķ': 'K', 'ķ': 'k', 'Ĺ': 'L', 'ĺ': 'l',
  'Ļ': 'L', 'ļ': 'l', 'Ľ': 'L', 'ľ': 'l', 'Ń': 'N', 'ń': 'n', 'Ņ': 'N', 'ņ': 'n',
  'Ň': 'N', 'ň': 'n', 'Ō': 'O', 'ō': 'o', 'Ŏ': 'O', 'ŏ': 'o', 'Ő': 'O', 'ő': 'o',
  'Ŕ': 'R', 'ŕ': 'r', 'Ŗ': 'R', 'ŗ': 'r', 'Ř': 'R', 'ř': 'r', 'Ś': 'S', 'ś': 's',
  'Ŝ': 'S', 'ŝ': 's', 'Ş': 'S', 'ş': 's', 'Š': 'S', 'š': 's', 'Ţ': 'T', 'ţ': 't',
  'Ť': 'T', 'ť': 't', 'Ũ': 'U', 'ũ': 'u', 'Ū': 'U', 'ū': 'u', 'Ŭ': 'U', 'ŭ': 'u',
  'Ů': 'U', 'ů': 'u', 'Ű': 'U', 'ű': 'u', 'Ų': 'U', 'ų': 'u', 'Ŵ': 'W', 'ŵ': 'w',
  'Ŷ': 'Y', 'ŷ': 'y', 'Ÿ': 'Y', 'Ź': 'Z', 'ź': 'z', 'Ż': 'Z', 'ż': 'z', 'Ž': 'Z',
  'ž': 'z', 'Ơ': 'O', 'ơ': 'o', 'Ư': 'U', 'ư': 'u', 'Ǎ': 'A', 'ǎ': 'a', 'Ǐ': 'I',
  'ǐ': 'i', 'Ǒ': 'O', 'ǒ': 'o', 'Ǔ': 'U', 'ǔ': 'u', 'Ǖ': 'U', 'ǖ': 'u', 'Ǘ': 'U',
  'ǘ': 'u', 'Ǚ': 'U', 'ǚ': 'u', 'Ǜ': 'U', 'ǜ': 'u', 'Ǟ': 'A', 'ǟ': 'a', 'Ǡ': 'A',
  'ǡ': 'a', 'Ǣ': 'Æ', 'ǣ': 'æ', 'Ǧ': 'G', 'ǧ': 'g', 'Ǩ': 'K', 'ǩ': 'k', 'Ǫ': 'O',
  'ǫ': 'o', 'Ǭ': 'O', 'ǭ': 'o', 'Ǯ': 'Ʒ', 'ǯ': 'ʒ', 'ǰ': 'j', 'Ǵ': 'G', 'ǵ': 'g',
  'Ǹ': 'N', 'ǹ': 'n', 'Ǻ': 'A', 'ǻ': 'a', 'Ǽ': 'Æ', 'ǽ': 'æ', 'Ǿ': 'Ø', 'ǿ': 'ø',
  'Ȁ': 'A', 'ȁ': 'a', 'Ȃ': 'A', 'ȃ': 'a', 'Ȅ': 'E', 'ȅ': 'e', 'Ȇ': 'E', 'ȇ': 'e',
  'Ȉ': 'I', 'ȉ': 'i', 'Ȋ': 'I', 'ȋ': 'i', 'Ȍ': 'O', 'ȍ': 'o', 'Ȏ': 'O', 'ȏ': 'o',
  'Ȑ': 'R', 'ȑ': 'r', 'Ȓ': 'R', 'ȓ': 'r', 'Ȕ': 'U', 'ȕ': 'u', 'Ȗ': 'U', 'ȗ': 'u',
  'Ș': 'S', 'ș': 's', 'Ț': 'T', 'ț': 't', 'Ȟ': 'H', 'ȟ': 'h', 'Ȧ': 'A', 'ȧ': 'a',
  'Ȩ': 'E', 'ȩ': 'e', 'Ȫ': 'O', 'ȫ': 'o', 'Ȭ': 'O', 'ȭ': 'o', 'Ȯ': 'O', 'ȯ': 'o',
  'Ȱ': 'O', 'ȱ': 'o', 'Ȳ': 'Y', 'ȳ': 'y', 'Ḁ': 'A', 'ḁ': 'a', 'Ḃ': 'B', 'ḃ': 'b',
  'Ḅ': 'B', 'ḅ': 'b', 'Ḇ': 'B', 'ḇ': 'b', 'Ḉ': 'C', 'ḉ': 'c', 'Ḋ': 'D', 'ḋ': 'd',
  'Ḍ': 'D', 'ḍ': 'd', 'Ḏ': 'D', 'ḏ': 'd', 'Ḑ': 'D', 'ḑ': 'd', 'Ḓ': 'D', 'ḓ': 'd',
  'Ḕ': 'E', 'ḕ': 'e', 'Ḗ': 'E', 'ḗ': 'e', 'Ḙ': 'E', 'ḙ': 'e', 'Ḛ': 'E', 'ḛ': 'e',
  'Ḝ': 'E', 'ḝ': 'e', 'Ḟ': 'F', 'ḟ': 'f', 'Ḡ': 'G', 'ḡ': 'g', 'Ḣ': 'H', 'ḣ': 'h',
  'Ḥ': 'H', 'ḥ': 'h', 'Ḧ': 'H', 'ḧ': 'h', 'Ḩ': 'H', 'ḩ': 'h', 'Ḫ': 'H', 'ḫ': 'h',
  'Ḭ': 'I', 'ḭ': 'i', 'Ḯ': 'I', 'ḯ': 'i', 'Ḱ': 'K', 'ḱ': 'k', 'Ḳ': 'K', 'ḳ': 'k',
  'Ḵ': 'K', 'ḵ': 'k', 'Ḷ': 'L', 'ḷ': 'l', 'Ḹ': 'L', 'ḹ': 'l', 'Ḻ': 'L', 'ḻ': 'l',
  'Ḽ': 'L', 'ḽ': 'l', 'Ḿ': 'M', 'ḿ': 'm', 'Ṁ': 'M', 'ṁ': 'm', 'Ṃ': 'M', 'ṃ': 'm',
  'Ṅ': 'N', 'ṅ': 'n', 'Ṇ': 'N', 'ṇ': 'n', 'Ṉ': 'N', 'ṉ': 'n', 'Ṋ': 'N', 'ṋ': 'n',
  'Ṍ': 'O', 'ṍ': 'o', 'Ṏ': 'O', 'ṏ': 'o', 'Ṑ': 'O', 'ṑ': 'o', 'Ṓ': 'O', 'ṓ': 'o',
  'Ṕ': 'P', 'ṕ': 'p', 'Ṗ': 'P', 'ṗ': 'p', 'Ṙ': 'R', 'ṙ': 'r', 'Ṛ': 'R', 'ṛ': 'r',
  'Ṝ': 'R', 'ṝ': 'r', 'Ṟ': 'R', 'ṟ': 'r', 'Ṡ': 'S', 'ṡ': 's', 'Ṣ': 'S', 'ṣ': 's',
  'Ṥ': 'S', 'ṥ': 's', 'Ṧ': 'S', 'ṧ': 's', 'Ṩ': 'S', 'ṩ': 's', 'Ṫ': 'T', 'ṫ': 't',
  'Ṭ': 'T', 'ṭ': 't', 'Ṯ': 'T', 'ṯ': 't', 'Ṱ': 'T', 'ṱ': 't', 'Ṳ': 'U', 'ṳ': 'u',
  'Ṵ': 'U', 'ṵ': 'u', 'Ṷ': 'U', 'ṷ': 'u', 'Ṹ': 'U', 'ṹ': 'u', 'Ṻ': 'U', 'ṻ': 'u',
  'Ṽ': 'V', 'ṽ': 'v', 'Ṿ': 'V', 'ṿ': 'v', 'Ẁ': 'W', 'ẁ': 'w', 'Ẃ': 'W', 'ẃ': 'w',
  'Ẅ': 'W', 'ẅ': 'w', 'Ẇ': 'W', 'ẇ': 'w', 'Ẉ': 'W', 'ẉ': 'w', 'Ẋ': 'X', 'ẋ': 'x',
  'Ẍ': 'X', 'ẍ': 'x', 'Ẏ': 'Y', 'ẏ': 'y', 'Ẑ': 'Z', 'ẑ': 'z', 'Ẓ': 'Z', 'ẓ': 'z',
  'Ẕ': 'Z', 'ẕ': 'z', 'ẖ': 'h', 'ẗ': 't', 'ẘ': 'w', 'ẙ': 'y', 'ẛ': 'ſ', 'Ạ': 'A',
  'ạ': 'a', 'Ả': 'A', 'ả': 'a', 'Ấ': 'A', 'ấ': 'a', 'Ầ': 'A', 'ầ': 'a', 'Ẩ': 'A',
  'ẩ': 'a', 'Ẫ': 'A', 'ẫ': 'a', 'Ậ': 'A', 'ậ': 'a', 'Ắ': 'A', 'ắ': 'a', 'Ằ': 'A',
  'ằ': 'a', 'Ẳ': 'A', 'ẳ': 'a', 'Ẵ': 'A', 'ẵ': 'a', 'Ặ': 'A', 'ặ': 'a', 'Ẹ': 'E',
  'ẹ': 'e', 'Ẻ': 'E', 'ẻ': 'e', 'Ẽ': 'E', 'ẽ': 'e', 'Ế': 'E', 'ế': 'e', 'Ề': 'E',
  'ề': 'e', 'Ể': 'E', 'ể': 'e', 'Ễ': 'E', 'ễ': 'e', 'Ệ': 'E', 'ệ': 'e', 'Ỉ': 'I',
  'ỉ': 'i', 'Ị': 'I', 'ị': 'i', 'Ọ': 'O', 'ọ': 'o', 'Ỏ': 'O', 'ỏ': 'o', 'Ố': 'O',
  'ố': 'o', 'Ồ': 'O', 'ồ': 'o', 'Ổ': 'O', 'ổ': 'o', 'Ỗ': 'O', 'ỗ': 'o', 'Ộ': 'O',
  'ộ': 'o', 'Ớ': 'O', 'ớ': 'o', 'Ờ': 'O', 'ờ': 'o', 'Ở': 'O', 'ở': 'o', 'Ỡ': 'O',
  'ỡ': 'o', 'Ợ': 'O', 'ợ': 'o', 'Ụ': 'U', 'ụ': 'u', 'Ủ': 'U', 'ủ': 'u', 'Ứ': 'U',
  'ứ': 'u', 'Ừ': 'U', 'ừ': 'u', 'Ử': 'U', 'ử': 'u', 'Ữ': 'U', 'ữ': 'u', 'Ự': 'U',
  'ự': 'u', 'Ỳ': 'Y', 'ỳ': 'y', 'Ỵ': 'Y', 'ỵ': 'y', 'Ỷ': 'Y', 'ỷ': 'y', 'Ỹ': 'Y',
  'ỹ': 'y',};

/// Characters that look like ASCII letters and are not. Cyrillic and Greek
/// lookalikes are the common evasion. Mirrors HOMOGLYPHS in filter-packs.js.
const Map<String, String> _homoglyphs = {
  'а': 'a', 'ӓ': 'a', 'ɑ': 'a', 'α': 'a',
  'ь': 'b', 'β': 'b',
  'с': 'c', 'ϲ': 'c', 'ⅽ': 'c',
  'ԁ': 'd', 'ⅾ': 'd',
  'е': 'e', 'ё': 'e', 'ε': 'e', 'ҽ': 'e',
  'ɡ': 'g',
  'һ': 'h',
  'і': 'i', 'ı': 'i', 'ι': 'i', 'ⅰ': 'i', 'ɩ': 'i',
  'ј': 'j', 'ϳ': 'j',
  'κ': 'k', 'ⲕ': 'k',
  'ⅼ': 'l', 'ӏ': 'l', 'ℓ': 'l',
  'м': 'm', 'ⅿ': 'm',
  'п': 'n', 'ή': 'n', 'ո': 'n',
  'о': 'o', 'ο': 'o', 'σ': 'o', 'ø': 'o', 'θ': 'o', 'ⲟ': 'o',
  'р': 'p', 'ρ': 'p',
  'ԛ': 'q',
  'г': 'r', 'ɾ': 'r',
  'ѕ': 's', 'ș': 's',
  'т': 't', 'τ': 't', 'ţ': 't',
  'υ': 'u', 'ս': 'u', 'μ': 'u',
  'ν': 'v', 'ѵ': 'v', 'ⅴ': 'v',
  'ԝ': 'w', 'ѡ': 'w', 'ω': 'w',
  'х': 'x', 'χ': 'x', 'ⅹ': 'x',
  'у': 'y', 'γ': 'y', 'ү': 'y',
  'ᴢ': 'z', 'ζ': 'z',
};

/// Digits that stand in for a letter, as ALTERNATIVES inside a compiled term
/// rather than a rewrite of the text: turning every '1' into an 'i' would
/// corrupt ordinary numbers.
const Map<String, String> _leet = {
  'a': 'a@4', 'b': 'b8', 'c': 'c', 'd': 'd', 'e': 'e3', 'f': 'f', 'g': 'g69',
  'h': 'h', 'i': 'i1!|', 'j': 'j', 'k': 'k', 'l': 'l1|', 'm': 'm', 'n': 'n',
  'o': 'o0', 'p': 'p', 'q': 'q', 'r': 'r', 's': 's5\$', 't': 't7', 'u': 'u',
  'v': 'v', 'w': 'w', 'x': 'x', 'y': 'y', 'z': 'z2',
};

final RegExp _invisible = RegExp(
    r'[\u00AD\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]');
/// Deleted between two alphanumerics: the shape of "f.u.c.k", and nothing a
/// reader writes by accident. Outside a word they stay separators.
final RegExp _midwordStrip =
    RegExp(r"(?<=[\p{L}\p{N}])[.\-_*'’`~^+]+(?=[\p{L}\p{N}])", unicode: true);
/// @ and $ convert beside a LETTER ("$hit", "a$$hole"); a digit neighbor is
/// left alone so "$20" stays a price.
final RegExp _atDollar = RegExp(r'(?<=\p{L})[@$]|[@$](?=\p{L})', unicode: true);
/// ! and | only BETWEEN two letters ("b!tch"). Converting a trailing one turns
/// "fuck!" into "fucki", which the term then misses.
final RegExp _bangPipe = RegExp(r'(?<=\p{L})[!|]+(?=\p{L})', unicode: true);
final RegExp _nonAlnum = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _spacedRun =
    RegExp(r'(?:^| )((?:[\p{L}\p{N}] ){2,}[\p{L}\p{N}])(?= |$)', unicode: true);
/// Scripts with no spaces between words, where a whole-word match can never
/// reach inside the text. Terms in these match as substrings instead.
final RegExp _unspaced = RegExp(
    r'[぀-ヿ㐀-䶿一-鿿豈-﫿'
    r'฀-๿຀-໿ក-៿က-႟]');
final RegExp _reSpecial = RegExp(r'[.*+?^${}()|[\]\\]');

/// Only the first this many characters are scanned.
const int _scanLimit = 8000;

const List<String> kFilterPackIds = ['profanity', 'scams', 'crypto', 'politics'];

class _CompiledPack {
  _CompiledPack(this.id, this.matchers, this.patterns, this.allow, this.nym);
  final String id;
  final List<RegExp> matchers;
  final List<RegExp> patterns;
  final RegExp? allow;
  final RegExp? nym;
}

/// The normalized forms of one message: [norm] with word boundaries as spaces,
/// and [joined] with runs of three or more single characters rejoined so
/// "f u c k" is reachable. [joined] is empty when nothing was joined.
class NormalizedText {
  const NormalizedText(this.norm, this.joined);
  final String norm;
  final String joined;
}

class FilterPacks {
  FilterPacks._();

  static final Map<String, _CompiledPack> _compiled = {};
  static Set<String> _active = <String>{};

  static Set<String> get active => _active;

  static String _escape(String s) =>
      s.replaceAllMapped(_reSpecial, (m) => '\\${m[0]}');

  /// Folds a message down to `[a-z0-9 ]`. Mirrors `normalizeForFilter`.
  static NormalizedText normalize(String? text) {
    if (text == null || text.isEmpty) return const NormalizedText('', '');
    var s = text.length > _scanLimit ? text.substring(0, _scanLimit) : text;
    s = s.toLowerCase().replaceAll(_invisible, '');
    // Fullwidth forms, which NFKC gives the PWA for free.
    final buf = StringBuffer();
    for (final ch in s.split('')) {
      final code = ch.codeUnitAt(0);
      if (code >= 0xFF01 && code <= 0xFF5E) {
        buf.writeCharCode(code - 0xFEE0);
      } else {
        buf.write(_latinFold[ch] ?? _homoglyphs[ch] ?? ch);
      }
    }
    s = buf.toString().toLowerCase();
    s = s.replaceAllMapped(_atDollar, (m) => m[0] == '@' ? 'a' : 's');
    s = s.replaceAll(_bangPipe, 'i');
    s = s.replaceAll(_midwordStrip, '');
    s = s.replaceAll(_nonAlnum, ' ').trim();
    final joined = s.replaceAllMapped(
        _spacedRun, (m) => ' ${m[1]!.replaceAll(' ', '')}');
    return NormalizedText(s, joined == s ? '' : joined);
  }

  /// A term is normalized by the SAME pipeline as the text before compiling,
  /// or the homoglyph fold breaks every non-Latin list: "хуй" becomes "xyй" in
  /// the message and stays "хуй" in the pack.
  ///
  /// [repeat] false compiles each letter exactly once. Allow entries use it
  /// because with repetition "niger" matches "nigger", and an allow list that
  /// swallows the slur is worse than no allow list.
  static String? _termBody(String term, {bool repeat = true}) {
    final norm = normalize(term).norm;
    if (norm.isEmpty) return null;
    final rep = repeat ? '+' : '{1}';
    final b = StringBuffer();
    for (final ch in norm.split('')) {
      if (ch == ' ') {
        b.write(' +');
        continue;
      }
      final cls = _leet[ch];
      b.write(cls != null ? '[${_escape(cls)}]$rep' : '${_escape(ch)}$rep');
    }
    final out = b.toString();
    return out.isEmpty ? null : out;
  }

  static _CompiledPack _compile(Map<String, dynamic> pack) {
    final seen = <String>{};
    final worded = <String>[];
    final loose = <String>[];
    final terms = pack['terms'];
    if (terms is Map) {
      for (final list in terms.values) {
        if (list is! List) continue;
        for (final raw in list) {
          final term = raw.toString().toLowerCase().trim();
          if (term.isEmpty || !seen.add(term)) continue;
          final body = _termBody(term);
          if (body == null) continue;
          (_unspaced.hasMatch(term) ? loose : worded).add(body);
        }
      }
    }
    const chunk = 120;
    final matchers = <RegExp>[];
    for (var i = 0; i < worded.length; i += chunk) {
      final slice = worded.sublist(i, (i + chunk).clamp(0, worded.length));
      matchers.add(RegExp('(?:^| )(?:${slice.join('|')})(?:\$| )', unicode: true));
    }
    for (var i = 0; i < loose.length; i += chunk) {
      final slice = loose.sublist(i, (i + chunk).clamp(0, loose.length));
      matchers.add(RegExp('(?:${slice.join('|')})', unicode: true));
    }
    final patterns = <RegExp>[];
    for (final p in (pack['patterns'] as List? ?? const [])) {
      if (p is! Map || p['re'] is! String) continue;
      try {
        patterns.add(RegExp(p['re'] as String,
            caseSensitive: !(p['flags'] as String? ?? 'i').contains('i')));
      } catch (_) {
        // A pattern the Dart engine will not take is skipped, not fatal.
      }
    }
    final allowBodies = <String>[];
    for (final a in (pack['allow'] as List? ?? const [])) {
      final body = _termBody(a.toString().toLowerCase().trim(), repeat: false);
      if (body != null) allowBodies.add(body);
    }
    final nymBodies = <String>[];
    for (final t in (pack['nymTerms'] as List? ?? const [])) {
      final body = _termBody(t.toString().toLowerCase().trim());
      if (body != null) nymBodies.add(body);
    }
    return _CompiledPack(
      pack['id'] as String? ?? '',
      matchers,
      patterns,
      allowBodies.isEmpty
          ? null
          : RegExp('(?:^| )(?:${allowBodies.join('|')})(?:\$| )', unicode: true),
      nymBodies.isEmpty ? null : RegExp(nymBodies.join('|'), unicode: true),
    );
  }

  /// Compiles a pack from already-decoded JSON. Public so tests can load the
  /// same file the app bundles without going through the asset system.
  static void loadFromJson(Map<String, dynamic> pack) {
    final id = pack['id'] as String?;
    if (id == null || !kFilterPackIds.contains(id)) return;
    _compiled[id] = _compile(pack);
  }

  /// Sets the enabled packs and loads any that are new. A pack that will not
  /// load simply does not filter — a missing asset must never swallow a
  /// channel.
  static Future<void> setActive(Iterable<String> ids) async {
    _active = ids.where(kFilterPackIds.contains).toSet();
    for (final id in _active) {
      if (_compiled.containsKey(id)) continue;
      try {
        final raw =
            await rootBundle.loadString('assets/data/filter-packs/$id.json');
        loadFromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        // Leave it uncompiled; match() skips packs it has no rules for.
      }
    }
  }

  /// The id of the pack that matched, or null. The id rather than a bool so a
  /// caller can say WHICH pack hid a message.
  static String? match(String? text, {String? nym}) {
    if (_active.isEmpty) return null;
    final body = text ?? '';
    final subject = (nym != null && nym.isNotEmpty) ? '$nym $body' : body;
    if (subject.isEmpty) return null;

    final n = normalize(subject);
    if (n.norm.isEmpty) return null;
    final nymNorm = (nym != null && nym.isNotEmpty) ? normalize(nym).norm : '';

    for (final id in _active) {
      final pack = _compiled[id];
      if (pack == null) continue;
      // The allow list is subtracted from the haystack BEFORE the terms run,
      // so "Scunthorpe" cannot be reached by the term inside it.
      var hay = n.norm;
      var hay2 = n.joined;
      if (pack.allow != null) {
        hay = hay.replaceAll(pack.allow!, ' ');
        if (hay2.isNotEmpty) hay2 = hay2.replaceAll(pack.allow!, ' ');
      }
      for (final re in pack.matchers) {
        if (re.hasMatch(hay) || (hay2.isNotEmpty && re.hasMatch(hay2))) return id;
      }
      if (pack.nym != null && nymNorm.isNotEmpty) {
        final nymHay = pack.allow != null
            ? nymNorm.replaceAll(pack.allow!, ' ')
            : nymNorm;
        if (pack.nym!.hasMatch(nymHay)) return id;
      }
      // Structural patterns run on the ORIGINAL text: a wallet address or an
      // invite link does not survive normalization.
      for (final re in pack.patterns) {
        if (re.hasMatch(body)) return id;
      }
    }
    return null;
  }

  static bool matches(String? text, {String? nym}) => match(text, nym: nym) != null;

  /// Test seam: forget every compiled pack.
  static void resetForTest() {
    _compiled.clear();
    _active = <String>{};
  }
}
