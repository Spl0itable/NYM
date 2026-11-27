import '../../core/constants/event_kinds.dart';
import '../../core/constants/history_window.dart';
import '../../models/nostr_event.dart';

bool isChannelWireKind(String? kind) =>
    kind == '${EventKind.geoChannel}' || kind == '${EventKind.namedChannel}';

int channelExpiresAt(int createdAtSec) =>
    createdAtSec + kChannelHistoryMaxAge.inSeconds;

List<String> channelExpirationTag(int createdAtSec) =>
    ['expiration', '${channelExpiresAt(createdAtSec)}'];

final RegExp _expirationDigits = RegExp(r'^[0-9]+$');

bool eventExpired(NostrEvent e, {int? nowSec}) {
  String? raw;
  for (final t in e.tags) {
    if (t.isNotEmpty && t[0] == 'expiration') {
      raw = t.length > 1 ? t[1] : null;
      break;
    }
  }
  if (raw == null || !_expirationDigits.hasMatch(raw)) return false;
  final ts = int.tryParse(raw);
  if (ts == null || ts == 0) return false;
  final now = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  return ts < now;
}
