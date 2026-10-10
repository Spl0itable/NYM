import 'package:flutter/widgets.dart';

import '../../core/utils/nym_utils.dart';
import '../i18n/i18n.dart';
import '../../widgets/common/nym_label.dart' show nymRangeSpans, nymSuffixRanges;

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

bool hasNymSuffix(String text) => nymSuffixRanges(text).isNotEmpty;

List<InlineSpan> dimRangeSpans(
    String text, List<List<int>> ranges, TextStyle dim) {
  final parts = <InlineSpan>[];
  var at = 0;
  for (final r in ranges) {
    if (r[0] < at || r[1] > text.length) continue;
    if (r[0] > at) parts.add(TextSpan(text: text.substring(at, r[0])));
    parts.add(TextSpan(text: text.substring(r[0], r[1]), style: dim));
    at = r[1];
  }
  if (at < text.length) parts.add(TextSpan(text: text.substring(at)));
  return parts;
}

TextSpan dimNymSuffixes(String text, TextStyle dim) {
  final ranges = nymSuffixRanges(text);
  if (ranges.isEmpty) return TextSpan(text: text);
  return TextSpan(children: nymRangeSpans(text, ranges, dim));
}
