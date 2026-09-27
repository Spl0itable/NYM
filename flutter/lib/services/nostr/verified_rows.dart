import '../../models/nostr_event.dart';

Future<List<NostrEvent>> verifiedRows(
  Iterable<Map<String, dynamic>> rows,
  Future<bool> Function(NostrEvent event) verify,
) async {
  final parsed = <NostrEvent>[];
  for (final raw in rows) {
    try {
      parsed.add(NostrEvent.fromJson(raw));
    } catch (_) {}
  }
  if (parsed.isEmpty) return parsed;
  final oks = await Future.wait([for (final e in parsed) verify(e)]);
  return [
    for (var i = 0; i < parsed.length; i++)
      if (oks[i]) parsed[i],
  ];
}
