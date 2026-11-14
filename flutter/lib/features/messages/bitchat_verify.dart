import '../../models/nostr_event.dart';

const List<int> kBitchatVerifyChannelKinds = [20000, 23333];

const String kBitchatVerifyLabel = 'bitchat verification link';

const String _ws =
    '\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff';

final RegExp _rxTrim = RegExp('^[$_ws]+|[$_ws]+\$');

final RegExp _rxToken = RegExp('[^$_ws]+');

final RegExp _rxPrefix =
    RegExp(r'^bitchat:(?://verify/?|///verify|verify)\?', caseSensitive: false);

final RegExp _rxScheme = RegExp('bitchat:', caseSensitive: false);

final RegExp _rxQueryBad = RegExp('[$_ws#]');

final RegExp _rxLead = RegExp('^[(\\["\'<*_~|]+');

final RegExp _rxTrail = RegExp('[.,;:!?)\\]"\'*_~|>\u2026\u3002]+\$');

final RegExp _rxRunStart = RegExp(r'^bitchat:', caseSensitive: false);

const int _maxLength = 2048;

const List<String> _required = [
  'v',
  'noise',
  'sign',
  'nick',
  'ts',
  'nonce',
  'sig',
];

final Map<String, RegExp> _fields = {
  'v': RegExp(r'^[1-9][0-9]?$'),
  'noise': RegExp(r'^[0-9A-Fa-f]{64}$'),
  'sign': RegExp(r'^[0-9A-Fa-f]{64}$'),
  'nick': RegExp(r'^(?:[^\x00-\x1f\x7f&#%<>"`]|%[0-9A-Fa-f]{2}){0,1024}$'),
  'ts': RegExp(r'^[0-9]{1,19}$'),
  'nonce': RegExp(r'^[A-Za-z0-9_-]{22}$'),
  'sig': RegExp(r'^[0-9A-Fa-f]{128}$'),
  'npub': RegExp(r'^npub1[02-9ac-hj-np-z]{58}$'),
};

bool _isLink(String s) {
  if (s.isEmpty || s.length > _maxLength) return false;
  final m = _rxPrefix.firstMatch(s);
  if (m == null) return false;
  final query = s.substring(m.end);
  if (query.isEmpty || _rxQueryBad.hasMatch(query)) return false;
  final seen = <String>{};
  for (final part in query.split('&')) {
    final eq = part.indexOf('=');
    if (eq < 0) return false;
    final name = part.substring(0, eq);
    final rule = _fields[name];
    if (rule == null || seen.contains(name)) return false;
    if (!rule.hasMatch(part.substring(eq + 1))) return false;
    seen.add(name);
  }
  return _required.every(seen.contains);
}

bool isBitchatVerifyContent(String content) =>
    _isLink(content.replaceAll(_rxTrim, ''));

bool isBitchatVerifyChannelEvent(NostrEvent e) =>
    kBitchatVerifyChannelKinds.contains(e.kind) &&
    isBitchatVerifyContent(e.content);

List<({int start, int end})> findBitchatVerifyLinks(String text) {
  if (!_rxScheme.hasMatch(text)) return const [];
  final out = <({int start, int end})>[];
  for (final m in _rxToken.allMatches(text)) {
    final token = m[0]!;
    final lead = _rxLead.firstMatch(token)?.end ?? 0;
    final run = token.substring(lead);
    if (!_rxRunStart.hasMatch(run)) continue;
    final last = run.length < _maxLength ? run.length : _maxLength;
    for (var end = _rxTrail.firstMatch(run)?.start ?? run.length; end <= last; end++) {
      if (_isLink(run.substring(0, end))) {
        out.add((start: m.start + lead, end: m.start + lead + end));
        break;
      }
    }
  }
  return out;
}

String labelBitchatVerifyLinks(String text, String label) {
  final spans = findBitchatVerifyLinks(text);
  if (spans.isEmpty) return text;
  final out = StringBuffer();
  var last = 0;
  for (final s in spans) {
    out
      ..write(text.substring(last, s.start))
      ..write(label);
    last = s.end;
  }
  out.write(text.substring(last));
  return out.toString();
}
