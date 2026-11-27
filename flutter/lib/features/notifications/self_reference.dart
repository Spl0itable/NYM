library;

import '../../core/utils/nick_parse.dart';

bool mentionsSelf({
  required String content,
  required String nym,
  required String suffix,
}) =>
    selfMentionOf(content, nym, suffix).mentioned;

bool quotesSelf({
  required String content,
  required String nym,
  required String suffix,
}) =>
    selfMentionOf(content, nym, suffix).quoted;

bool contentMentionsSelf({
  required String content,
  required String nym,
  String? pubkey,
  NickKnown? known,
}) {
  var pk = pubkey ?? '';
  var base = nickBase(nym, pk);
  if (nickTail(pk).isEmpty) {
    final m = _ownTag.firstMatch(nym);
    if (m != null) {
      base = nym.substring(0, m.start);
      pk = m[1]!;
    }
  }
  final r = selfMentionOf(content, base, pk, known: known);
  return r.mentioned || r.quoted;
}

final RegExp _ownTag = RegExp(r'#([0-9a-f]{4})$', caseSensitive: false);
