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
    capNymBase(nym.replaceAll(_suffixRe, ''));

const int kNymMax = 20;

final RegExp _trailingSpaceRe = RegExp(r'\s+$');

final RegExp _loneSurrogateRe = RegExp(
    r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]');

String nymWellFormed(String s) => s.replaceAll(_loneSurrogateRe, '');

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

String? nymInitial(String name) {
  final s = nymWellFormed(name);
  return s.isEmpty ? null : s.characters.first;
}

String capNymBase(String base) {
  final s = nymWellFormed(base);
  if (s.length <= kNymMax) return s;
  return s.substring(0, nymCutAt(s, kNymMax)).replaceAll(_trailingSpaceRe, '');
}

class NymLengthFormatter extends TextInputFormatter {
  const NymLengthFormatter([this.max = kNymMax]);

  final int max;

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final text = newValue.text;
    final clean = nymWellFormed(text);
    if (clean.length == text.length && text.length <= max) return newValue;
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
      final room = max - pre.length - post.length;
      if (room >= 0 &&
          text.length >= pre.length + post.length &&
          text.startsWith(pre) &&
          text.endsWith(post)) {
        final ins =
            nymWellFormed(text.substring(pre.length, text.length - post.length));
        final put = ins.substring(0, nymCutAt(ins, room));
        return TextEditingValue(
          text: '$pre$put$post',
          selection: TextSelection.collapsed(offset: pre.length + put.length),
        );
      }
    }
    final cut = clean.substring(0, nymCutAt(clean, max));
    return TextEditingValue(
      text: cut,
      selection: TextSelection.collapsed(offset: cut.length),
    );
  }
}

String capNym(String nym) {
  final parts = splitNymSuffix(nym);
  return '${capNymBase(parts.base)}${parts.suffix}';
}

String capMentionBase(String base) =>
    base.startsWith('@') ? '@${capNymBase(base.substring(1))}' : capNymBase(base);

String capNymMentions(String text) => text.replaceAllMapped(
    _mentionRe, (m) => '@${capNymBase(m.group(1)!)}#${m.group(2)!}');

final RegExp _mentionRe = RegExp(r'@([^@#\n]*?(?<!\s))#([0-9a-f]{4})\b',
    caseSensitive: false);

String withOwnNymSuffix(String nym, String pubkey) {
  if (!_pubkeyHexRe.hasMatch(pubkey)) return nym;
  return nym.replaceFirst(_suffixRe, '#${pubkey.substring(60).toLowerCase()}');
}

String getNymFromPubkey(String baseNym, String pubkey) {
  final base = stripPubkeySuffix(baseNym);
  return '$base#${getPubkeySuffix(pubkey)}';
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
