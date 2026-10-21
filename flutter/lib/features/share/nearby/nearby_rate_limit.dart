import 'dart:collection';
import 'dart:math' as math;

const int kNearbyPerPeerMinIntervalMs = 10000;
const int kNearbyPerPeerWindowMs = 600000;
const int kNearbyPerPeerWindowMax = 5;
const int kNearbyDuplicateWindowMs = 600000;
const int kNearbyMaxPendingCards = 3;
const int kNearbyCardTtlMs = 300000;
const int kNearbyMaxTrackedPeers = 64;

class NearbyRateLimit {
  final LinkedHashMap<String, List<(int, String)>> _peers =
      LinkedHashMap<String, List<(int, String)>>();

  int get trackedPeers => _peers.length;

  bool accept(String peer, String link, int now) {
    final log = _peers.remove(peer) ?? <(int, String)>[];
    _peers[peer] = log;
    final keep = math.max(kNearbyPerPeerWindowMs, kNearbyDuplicateWindowMs);
    log.removeWhere((e) => now - e.$1 >= keep);
    if (log.isNotEmpty && now - log.last.$1 < kNearbyPerPeerMinIntervalMs) {
      return false;
    }
    final inWindow =
        log.where((e) => now - e.$1 < kNearbyPerPeerWindowMs).length;
    if (inWindow >= kNearbyPerPeerWindowMax) return false;
    if (log.any((e) => e.$2 == link && now - e.$1 < kNearbyDuplicateWindowMs)) {
      return false;
    }
    log.add((now, link));
    while (_peers.length > kNearbyMaxTrackedPeers) {
      _peers.remove(_peers.keys.first);
    }
    return true;
  }

  void clear() => _peers.clear();
}
