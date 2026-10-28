import '../../core/utils/nym_utils.dart';
import '../../models/user.dart';
import '../../state/app_state.dart' show kVerifiedBotPubkeys;
import '../pms/last_seen.dart';

UserStatus nymStatus(User u, int nowMs) => u.effectiveStatus(
    nowMs: nowMs, isVerifiedBot: kVerifiedBotPubkeys.contains(u.pubkey));

int compareNymsListRows(User a, User b, int nowMs) {
  int rank(User u) => switch (nymStatus(u, nowMs)) {
        UserStatus.online => 0,
        UserStatus.away => 1,
        _ => 2,
      };
  final r = rank(a) - rank(b);
  if (r != 0) return r;
  return stripPubkeySuffix(a.nym)
      .toLowerCase()
      .compareTo(stripPubkeySuffix(b.nym).toLowerCase());
}

int nymsListOnlineCount(Iterable<User> users, int nowMs) => users.where((u) {
      final st = nymStatus(u, nowMs);
      if (st == UserStatus.hidden || st == UserStatus.offline) return false;
      return kVerifiedBotPubkeys.contains(u.pubkey) ||
          lastSeenIsActive(u.lastSeen, nowMs);
    }).length;

int channelOnlineNymsCount(
  Iterable<User> users,
  String channelKey, {
  required int nowMs,
  required String? selfPubkey,
  required bool Function(User u) isPersonHidden,
}) =>
    users.where((u) {
      if (u.pubkey == selfPubkey) return false;
      if (isPersonHidden(u)) return false;
      if (nymStatus(u, nowMs) == UserStatus.hidden) return false;
      return u.onlineIn(channelKey, nowMs);
    }).length;
