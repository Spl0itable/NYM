import 'package:flutter/widgets.dart';

import '../../core/utils/nym_utils.dart';
import '../i18n/i18n.dart';

class DeletedNotice {
  DeletedNotice({required String nym, required String pubkey})
      : nym = stripPubkeySuffix(nym).trim(),
        suffix = getPubkeySuffix(pubkey);

  static final ValueNotifier<DeletedNotice?> pending =
      ValueNotifier<DeletedNotice?>(null);

  final String nym;
  final String suffix;

  String get label => nym.isEmpty ? '' : '$nym#$suffix';

  String get text => nym.isEmpty
      ? tr('This identity was deleted from another device.')
      : tr('{nym} was deleted from another device.', {'nym': label});
}

final RegExp _nymSuffixRe =
    RegExp(r'(?<=[^\s#])#[0-9a-f]{4}(?![0-9A-Za-z])', caseSensitive: false);

bool hasNymSuffix(String text) => _nymSuffixRe.hasMatch(text);

TextSpan dimNymSuffixes(String text, TextStyle dim) {
  final parts = <InlineSpan>[];
  var at = 0;
  for (final m in _nymSuffixRe.allMatches(text)) {
    if (m.start > at) parts.add(TextSpan(text: text.substring(at, m.start)));
    parts.add(TextSpan(text: m.group(0), style: dim));
    at = m.end;
  }
  if (parts.isEmpty) return TextSpan(text: text);
  if (at < text.length) parts.add(TextSpan(text: text.substring(at)));
  return TextSpan(children: parts);
}
