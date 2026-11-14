import '../../features/messages/encrypted_blob.dart';
import '../../models/nostr_event.dart';

Future<List<NostrEvent>> verifiedRows(
  Iterable<Map<String, dynamic>> rows,
  Future<bool> Function(NostrEvent event) verify, {
  void Function(String id)? onBlob,
}) async {
  final parsed = <NostrEvent>[];
  for (final raw in rows) {
    try {
      final e = NostrEvent.fromJson(raw);
      if (isEncryptedBlobChannelEvent(e)) {
        if (onBlob != null && e.id.isNotEmpty && e.computeId() == e.id) {
          onBlob(e.id);
        }
        continue;
      }
      parsed.add(e);
    } catch (_) {}
  }
  if (parsed.isEmpty) return parsed;
  final oks = await Future.wait([for (final e in parsed) verify(e)]);
  return [
    for (var i = 0; i < parsed.length; i++)
      if (oks[i]) parsed[i],
  ];
}
