import '../../core/constants/event_kinds.dart';
import '../../models/nostr_event.dart';
import 'server_quiet.dart';
import 'spam_filter.dart';

bool archivedSpam(
  NostrEvent ev,
  String? selfPubkey, {
  bool enabled = true,
  bool aggressive = true,
}) {
  if (selfPubkey != null && ev.pubkey == selfPubkey) return false;
  if (ServerQuiet.hides(ev.pubkey, ev.id)) return true;
  if (ev.kind != EventKind.geoChannel && ev.kind != EventKind.namedChannel) {
    return false;
  }
  return SpamFilter.isSpamMessage(ev.content,
      enabled: enabled, aggressive: aggressive);
}
