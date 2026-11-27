import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

final RegExp _suffixRe = RegExp(r'#[0-9a-f]{4}$', caseSensitive: false);
final RegExp _hex4Re = RegExp(r'^[0-9a-f]{4}$', caseSensitive: false);
final RegExp _pubkeyHexRe = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

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

String stripPubkeySuffix(String nym) =>
    normalizeNym(nym.replaceAll(_suffixRe, ''));

const int kNymMax = 20;

const int kNymUnits = 80;

const Map<String, String> kNymNameOwners = {
  'nymbot': 'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2',
  'luxas': 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df',
};

final RegExp _loneSurrogateRe = RegExp(
    r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]');

final RegExp _toSpaceRe = RegExp(
    r'[\t\n\v\f\r\u0085\u2028\u2029\u00A0\u1680\u2000-\u200A\u202F\u205F]');
final RegExp _controlRe = RegExp(r'[\u0000-\u001F\u007F-\u009F]');
final RegExp _invisibleRe = RegExp(
    r'[\u200B\u200E\u200F\u061C\u202A-\u202E\u2066-\u2069\u2060-\u2064\uFEFF\u00AD\u034F\u180E\u115F\u1160\u3164\uFFA0\u17B4\u17B5\u2800\uFFF9-\uFFFB\u{1BCA0}-\u{1BCA3}\u{E0001}]',
    unicode: true);
final RegExp _formatRe =
    RegExp(r'[^\P{Cf}\u200C\u200D\u{E0020}-\u{E007F}]', unicode: true);
final RegExp _selectorRe = RegExp(
    r'[\uFE00-\uFE0F\u180B-\u180D\u180F\uFF9E\uFF9F\u{1F3FB}-\u{1F3FF}\u{E0100}-\u{E01EF}]',
    unicode: true);
const String _emojiPattern = r'\p{Emoji}';
const String _modBasePattern = r'\p{Emoji_Modifier_Base}';
final RegExp _emojiCpRe = RegExp('^$_emojiPattern\$', unicode: true);
final RegExp _modBaseCpRe = RegExp('^$_modBasePattern\$', unicode: true);
final RegExp _hanCpRe = RegExp(r'^\p{Script=Han}$', unicode: true);
final RegExp _mongolCpRe = RegExp(r'^[\u1820-\u18AA]$');
final RegExp _kanaCpRe = RegExp(r'^[\u3040-\u30FF\u31F0-\u31FF\uFF66-\uFF9D]$');
final RegExp _tagRunRe = RegExp(r'[\u{E0020}-\u{E007F}]+', unicode: true);
final RegExp _tagSeqRe =
    RegExp(r'^[\u{E0020}-\u{E007E}]+\u{E007F}$', unicode: true);
const String _pictPattern = r'\p{Extended_Pictographic}';
final RegExp _tagBaseRe =
    RegExp('$_pictPattern[\uFE0F\u{1F3FB}-\u{1F3FF}]?\$', unicode: true);
final RegExp _joinSkipRe =
    RegExp(r'^[\p{M}\u{1F3FB}-\u{1F3FF}]$', unicode: true);
final RegExp _pictRe = RegExp('^$_pictPattern\$', unicode: true);
final RegExp _joinLetterRe = RegExp(
    r'^(?=\p{L})[\u0600-\u06FF\u0700-\u074F\u0750-\u077F\u07C0-\u07FF\u0860-\u086F\u0870-\u089F\u08A0-\u08FF\u0900-\u0DFF\uA8E0-\uA8FF\uFB50-\uFDFF\uFE70-\uFEFE]$',
    unicode: true);
final RegExp _markRunRe = RegExp(r'\p{M}{5,}', unicode: true);
final RegExp _tag4Re = RegExp(
    r'[#\uFF03\uFE5F\u266F]+(?=[0-9a-f\uFF10-\uFF19\uFF21-\uFF26\uFF41-\uFF46]{4}(?![0-9a-z_\uFF10-\uFF19\uFF21-\uFF3A\uFF3F\uFF41-\uFF5A]))',
    caseSensitive: false);
final RegExp _edgeRe = RegExp(r'^[ \u3000]+|[ \u3000]+$');
final RegExp _atSpaceRe = RegExp(r'(?<=[ \u3000])@+');
final RegExp _plainRe =
    RegExp(r'^(?![\s\S]* @)[!"$-~](?:[ !"$-~]{0,18}[!"$-~])?$');
final RegExp _keepRe = RegExp(r'^[\p{L}\p{N}]$', unicode: true);

const Map<String, String> _lookUpper = {
  'I': 'l', '\u0391': 'a', '\u0392': 'b', '\u0399': 'l', '\u039C': 'm',
  '\u039D': 'n', '\u039F': 'o', '\u03A4': 't', '\u03A5': 'y', '\u03A7': 'x',
  '\u0405': 's', '\u0406': 'l', '\u0410': 'a', '\u0412': 'b', '\u041C': 'm',
  '\u041E': 'o', '\u0422': 't', '\u0423': 'y', '\u0425': 'x', '\u04AE': 'y',
  '\u04C0': 'l',
};

const Map<String, String> _foldSrc = {
  'n': '\u00F1\u0144\u0146\u0148\u01F9\u1E45\u1E47\u1E49\u1E4B\u019E\u0272\u0273\u0235\u014B',
  'y': '\u00FD\u00FF\u0177\u0233\u1E8F\u1E99\u1EF3\u1EF5\u1EF7\u1EF9\u01B4\u024F\u03B3',
  'm': '\u1E3F\u1E41\u1E43\u0271\u217F\u216F',
  'b': '\u1E03\u1E05\u1E07\u0180\u0253\u0183',
  'o': '\u00F2\u00F3\u00F4\u00F5\u00F6\u014D\u014F\u0151\u01A1\u01D2\u01EB\u01ED\u020D\u020F\u022B\u022D\u022F\u0231\u1E4D\u1E4F\u1E51\u1E53\u1ECD\u1ECF\u1ED1\u1ED3\u1ED5\u1ED7\u1ED9\u1EDB\u1EDD\u1EDF\u1EE1\u1EE3\u00F8\u0275',
  't': '\u0163\u0165\u021B\u1E6B\u1E6D\u1E6F\u1E71\u1E97\u0167\u01AD\u0288\u0236\u01AB',
  'l': '\u013A\u013C\u013E\u1E37\u1E39\u1E3B\u1E3D\u0142\u019A\u0140\u026B\u026C\u026D\u0234|\u01C0\u05C0\u2113\u2223\u0269\u0196\u217C\u216C\uA7AD',
  'u': '\u00F9\u00FA\u00FB\u00FC\u0169\u016B\u016D\u016F\u0171\u0173\u01B0\u01D4\u01D6\u01D8\u01DA\u01DC\u0215\u0217\u1E73\u1E75\u1E77\u1E79\u1E7B\u1EE5\u1EE7\u1EE9\u1EEB\u1EED\u1EEF\u1EF1\u0289',
  'x': '\u1E8B\u1E8D\u2179\u2169',
  'a': '\u00E0\u00E1\u00E2\u00E3\u00E4\u00E5\u0101\u0103\u0105\u01CE\u01DF\u01E1\u01FB\u0201\u0203\u0227\u1E01\u1EA1\u1EA3\u1EA5\u1EA7\u1EA9\u1EAB\u1EAD\u1EAF\u1EB1\u1EB3\u1EB5\u1EB7\u2C65\u0251',
  's': '\u015B\u015D\u015F\u0161\u0219\u1E61\u1E63\u1E65\u1E67\u1E69\u0282\u023F\uA7C5\u2C7E',
};

final Map<String, String> _fold = {
  for (final e in _foldSrc.entries)
    for (final r in e.value.runes) String.fromCharCode(r): e.key,
};

const Map<String, String> _lookLower = {
  '0': 'o', '1': 'l', '\u03B1': 'a', '\u03B7': 'n', '\u03BF': 'o',
  '\u03C4': 't', '\u03C5': 'u', '\u03C7': 'x', '\u0430': 'a', '\u0432': 'b',
  '\u043C': 'm', '\u043E': 'o', '\u043F': 'n', '\u0442': 't', '\u0443': 'y',
  '\u0445': 'x', '\u044C': 'b', '\u0455': 's', '\u04AF': 'y', '\u04CF': 'l',
  '\u0274': 'n', '\u028F': 'y', '\u0299': 'b', '\u029F': 'l', '\u1D00': 'a',
  '\u1D0D': 'm', '\u1D0F': 'o', '\u1D1B': 't', '\u1D1C': 'u', '\uA731': 's',
};

String nymWellFormed(String s) => s.replaceAll(_loneSurrogateRe, '');

int nymGraphemes(String s) => s.length <= 1 ? s.length : s.characters.length;

int nymCutAt(String s, int max) {
  final room = max < 0 ? 0 : max;
  if (s.length <= room) return s.length;
  var end = 0;
  for (final g in s.characters) {
    if (end + g.length > room) break;
    end += g.length;
  }
  return end;
}

String _nymClip(String s) {
  if (s.length <= kNymMax) return s;
  final out = StringBuffer();
  var n = 0;
  var units = 0;
  for (final g in s.characters) {
    if (n >= kNymMax || units + g.length > kNymUnits) break;
    out.write(g);
    units += g.length;
    n++;
  }
  return out.toString();
}

List<String> _codePoints(String s) =>
    s.runes.map(String.fromCharCode).toList(growable: false);

String _keepTags(String s) => s.replaceAllMapped(_tagRunRe, (m) {
      final run = m.group(0)!;
      final at = m.start;
      final before = m.input.substring(at - 4 < 0 ? 0 : at - 4, at);
      return _tagSeqRe.hasMatch(run) && _tagBaseRe.hasMatch(before) ? run : '';
    });

String _keepSelectors(String s) {
  if (!_selectorRe.hasMatch(s)) return s;
  final out = StringBuffer();
  var prev = '';
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    var keep = true;
    if (r == 0xFE0E || r == 0xFE0F) {
      keep = _emojiCpRe.hasMatch(prev);
    } else if ((r >= 0xFE00 && r <= 0xFE0D) || (r >= 0xE0100 && r <= 0xE01EF)) {
      keep = _hanCpRe.hasMatch(prev);
    } else if ((r >= 0x180B && r <= 0x180D) || r == 0x180F) {
      keep = _mongolCpRe.hasMatch(prev);
    } else if (r == 0xFF9E || r == 0xFF9F) {
      keep = _kanaCpRe.hasMatch(prev);
    } else if (r >= 0x1F3FB && r <= 0x1F3FF) {
      keep = _modBaseCpRe.hasMatch(prev);
    }
    if (!keep) continue;
    out.write(c);
    prev = c;
  }
  return out.toString();
}

String _keepJoiners(String s) {
  if (!s.contains('\u200C') && !s.contains('\u200D')) return s;
  final cps = _codePoints(s);
  final out = StringBuffer();
  for (var i = 0; i < cps.length; i++) {
    final c = cps[i];
    if (c != '\u200C' && c != '\u200D') {
      out.write(c);
      continue;
    }
    var p = i - 1;
    while (p >= 0 && _joinSkipRe.hasMatch(cps[p])) {
      p--;
    }
    final prev = p >= 0 ? cps[p] : '';
    final next = i + 1 < cps.length ? cps[i + 1] : '';
    final emoji =
        c == '\u200D' && _pictRe.hasMatch(prev) && _pictRe.hasMatch(next);
    if (emoji ||
        (_joinLetterRe.hasMatch(prev) && _joinLetterRe.hasMatch(next))) {
      out.write(c);
    }
  }
  return out.toString();
}

String _normalizeOnce(String s, String tail) {
  var v = s
      .replaceAll(_loneSurrogateRe, '')
      .replaceAll(_toSpaceRe, ' ')
      .replaceAll(_controlRe, '')
      .replaceAll(_invisibleRe, '')
      .replaceAll(_formatRe, '');
  v = _keepJoiners(_keepTags(_keepSelectors(v)))
      .replaceAllMapped(_markRunRe, (m) => m.group(0)!.runes.take(4).map(String.fromCharCode).join())
      .replaceAll(_edgeRe, '')
      .replaceAll(_atSpaceRe, '');
  if (tail.isNotEmpty) {
    final own = RegExp('#$tail\$', caseSensitive: false);
    while (own.hasMatch(v)) {
      v = v.replaceAll(own, '').replaceAll(_edgeRe, '');
    }
  }
  v = v.replaceAll(_tag4Re, '').replaceAll(_edgeRe, '');
  return _nymClip(v).replaceAll(_edgeRe, '');
}

String _tailOf(String? pubkey) {
  final p = pubkey ?? '';
  if (_pubkeyHexRe.hasMatch(p)) return p.substring(60).toLowerCase();
  return _hex4Re.hasMatch(p) ? p.toLowerCase() : '';
}

final Map<String, String> _normMemo = <String, String>{};

String normalizeNym(String raw, {String? pubkey}) {
  var s = raw;
  if (_plainRe.hasMatch(s)) return s;
  final tail = _tailOf(pubkey);
  final key = '$tail|$raw';
  final hit = _normMemo[key];
  if (hit != null) return hit;
  for (var i = 0; i < 8; i++) {
    final next = _normalizeOnce(s, tail);
    if (next == s) break;
    s = next;
  }
  if (_normMemo.length >= 4000) _normMemo.clear();
  _normMemo[key] = s;
  return s;
}

String nymSkeleton(String name) {
  final out = StringBuffer();
  for (final ch in _codePoints(normalizeNym(name))) {
    var c = _lookUpper[ch] ?? ch;
    final cp = c.runes.first;
    if (cp >= 0xFF01 && cp <= 0xFF5E) {
      c = String.fromCharCode(cp - 0xFEE0);
    } else if (cp >= 0x1D400 && cp <= 0x1D6A3) {
      final k = (cp - 0x1D400) % 52;
      c = String.fromCharCode(k < 26 ? 97 + k : 71 + k);
    } else if (cp >= 0x1D7CE && cp <= 0x1D7FF) {
      c = '${(cp - 0x1D7CE) % 10}';
    }
    c = _lookUpper[c] ?? c.toLowerCase();
    for (final d in _codePoints(c)) {
      final e = _fold[d] ?? _lookLower[d] ?? d;
      if (_keepRe.hasMatch(e)) out.write(e);
    }
  }
  return out.toString().replaceAll('rn', 'm');
}

final RegExp _suffixSpanRe = RegExp(r'<span class="nym-suffix">[\s\S]*$');
final RegExp _markupTagRe = RegExp(r'<[^>]*>');
final RegExp _ltGtRe = RegExp(r'&lt;|&gt;');

String nymMarkupView(String name) => name
    .replaceAll(_suffixSpanRe, '')
    .replaceAll(_markupTagRe, '')
    .replaceAll(_ltGtRe, '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll(_edgeRe, '')
    .replaceAll(_suffixRe, '');

final Map<String, String> _reservedMemo = <String, String>{};

String nymReservedOf(String name) {
  if (name.length < 5) return '';
  final hit = _reservedMemo[name];
  if (hit != null) return hit;
  var k = nymSkeleton(name);
  if (!kNymNameOwners.containsKey(k)) {
    final n = normalizeNym(name);
    final v = nymMarkupView(n);
    k = v == n ? '' : nymSkeleton(v);
  }
  final out = kNymNameOwners.containsKey(k) ? k : '';
  if (_reservedMemo.length >= 4000) _reservedMemo.clear();
  _reservedMemo[name] = out;
  return out;
}

bool _isNymbotName(String name) {
  if (name.toLowerCase() == 'nymbot') return true;
  final v = nymMarkupView(name);
  return v != name && normalizeNym(v).toLowerCase() == 'nymbot';
}

String receivedNymBase(String? raw, String pubkey,
    {Map<String, String> owners = kNymNameOwners}) {
  final name = normalizeNym(raw ?? '', pubkey: pubkey);
  final k = nymReservedOf(name);
  if (name.isEmpty ||
      (k.isNotEmpty && pubkey.toLowerCase() != (owners[k] ?? ''))) {
    return 'nym';
  }
  return name;
}

bool isNymbotImpostor(String? raw, String pubkey,
    {Map<String, String> owners = kNymNameOwners}) {
  if (raw == null) return false;
  final name = normalizeNym(raw, pubkey: pubkey);
  return name.isNotEmpty &&
      _isNymbotName(name) &&
      pubkey.toLowerCase() != (owners['nymbot'] ?? '');
}

String meshNym(String raw, String? linkedPubkey) {
  final pk = linkedPubkey != null && _pubkeyHexRe.hasMatch(linkedPubkey)
      ? linkedPubkey.toLowerCase()
      : '';
  if (normalizeNym(raw, pubkey: pk).isEmpty) return '';
  return receivedNymBase(raw, pk);
}

String? nymInitial(String name) {
  final s = nymWellFormed(name);
  return s.isEmpty ? null : s.characters.first;
}

String capNymBase(String base) => normalizeNym(base);

class NymLengthFormatter extends TextInputFormatter {
  const NymLengthFormatter([this.max = kNymMax]);

  final int max;

  bool _fits(String s) => s.length <= kNymUnits && nymGraphemes(s) <= max;

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final text = newValue.text;
    final clean = nymWellFormed(text.replaceAll('\r', ''));
    if (clean.length == text.length && _fits(text)) return newValue;
    if (newValue.composing.isValid &&
        !newValue.composing.isCollapsed &&
        clean.length == text.length) {
      return newValue;
    }
    final old = oldValue.text;
    final sel = oldValue.selection;
    if (sel.isValid && sel.start >= 0 && sel.end <= old.length) {
      final pre = old.substring(0, sel.start);
      final post = old.substring(sel.end);
      if (text.length >= pre.length + post.length &&
          text.startsWith(pre) &&
          text.endsWith(post)) {
        final ins = nymWellFormed(text
            .substring(pre.length, text.length - post.length)
            .replaceAll('\r', ''));
        final put = StringBuffer();
        for (final g in ins.characters) {
          if (!_fits('$pre$put$g$post')) break;
          put.write(g);
        }
        return TextEditingValue(
          text: '$pre$put$post',
          selection: TextSelection.collapsed(offset: pre.length + put.length),
        );
      }
    }
    final cut = StringBuffer();
    for (final g in clean.characters) {
      if (!_fits('$cut$g')) break;
      cut.write(g);
    }
    final value = cut.toString();
    return TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }
}

String capNym(String nym) {
  final parts = splitNymSuffix(nym);
  return '${normalizeNym(parts.base)}${parts.suffix}';
}

String capMentionBase(String base) =>
    base.startsWith('@') ? '@${capNymBase(base.substring(1))}' : capNymBase(base);

String withOwnNymSuffix(String nym, String pubkey) {
  if (!_pubkeyHexRe.hasMatch(pubkey)) return nym;
  return nym.replaceFirst(_suffixRe, '#${pubkey.substring(60).toLowerCase()}');
}

String getNymFromPubkey(String baseNym, String pubkey) {
  return '${receivedNymBase(baseNym, pubkey)}#${getPubkeySuffix(pubkey)}';
}

List<List<String>> nymTags(String nym) => nym.isEmpty
    ? const <List<String>>[]
    : <List<String>>[
        ['n', nym]
      ];

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
