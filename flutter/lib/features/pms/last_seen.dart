import '../../models/message.dart';

const int kLastSeenActiveMs = 300000;

int mergeLastSeen(int prevMs, int eventMs, int nowMs) {
  final p = prevMs > 0 ? prevMs : 0;
  final e = eventMs > 0 ? eventMs : 0;
  final best = p > e ? p : e;
  return best > nowMs ? nowMs : best;
}

bool lastSeenIsActive(int lastSeenMs, int nowMs) =>
    lastSeenMs > 0 && nowMs - lastSeenMs < kLastSeenActiveMs;

const List<String> kPresenceActivityStatuses = ['online', 'active'];

int presenceActivityMs(String? status, int eventMs) =>
    kPresenceActivityStatuses.contains(status) && eventMs > 0 ? eventMs : 0;

int mergePresenceLastSeen(
        int prevMs, String? status, int eventMs, int nowMs) =>
    mergeLastSeen(prevMs, presenceActivityMs(status, eventMs), nowMs);

enum PmSeenState { bot, hidden, away, active, seen, unknown }

class PmSeenView {
  const PmSeenView(this.state, this.atMs);
  final PmSeenState state;
  final int atMs;
}

PmSeenView pmSeenView({
  required int nowMs,
  bool bot = false,
  bool hidden = false,
  bool away = false,
  Iterable<int> seenMs = const [],
}) {
  if (bot) return const PmSeenView(PmSeenState.bot, 0);
  if (hidden) return const PmSeenView(PmSeenState.hidden, 0);
  var at = 0;
  for (final v in seenMs) {
    at = mergeLastSeen(at, v, nowMs);
  }
  if (away) return PmSeenView(PmSeenState.away, at);
  if (lastSeenIsActive(at, nowMs)) {
    return PmSeenView(PmSeenState.active, at);
  }
  if (at > 0) return PmSeenView(PmSeenState.seen, at);
  return const PmSeenView(PmSeenState.unknown, 0);
}

int pmPeerActivityMs(Iterable<Message>? msgs, String peer) {
  var newest = 0;
  if (msgs == null) return newest;
  for (final m in msgs) {
    if (m.isOwn || m.pubkey != peer) continue;
    final ms = m.createdAt * 1000;
    if (ms > newest) newest = ms;
  }
  return newest;
}
