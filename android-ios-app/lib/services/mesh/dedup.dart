import 'dart:collection';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'mesh_constants.dart';

/// A bounded, time-expiring "seen" set used to drop duplicate packets during
/// the controlled flood. Mirrors bitchat's LRU seen-set (1000 entries, 5-minute
/// expiry): a packet already seen within the window is not processed or relayed
/// again, which is what keeps a flood mesh from looping forever.
class SeenPackets {
  SeenPackets({
    int capacity = MeshConstants.seenPacketCapacity,
    Duration ttl = MeshConstants.seenPacketTtl,
  })  : _capacity = capacity,
        _ttl = ttl;

  final int _capacity;
  final Duration _ttl;

  // Insertion-ordered map = LRU by age; value is the insertion time.
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  /// A stable content key for a packet: hash of the identity-bearing fields
  /// (everything except the mutable TTL), so relays with a decremented TTL still
  /// dedupe against the original.
  static String keyFor({
    required int type,
    required Uint8List senderID,
    required int timestamp,
    required Uint8List payload,
  }) {
    final digest = sha256.convert([
      type,
      ...senderID,
      (timestamp >> 24) & 0xFF,
      (timestamp >> 16) & 0xFF,
      (timestamp >> 8) & 0xFF,
      timestamp & 0xFF,
      ...payload,
    ]);
    return digest.toString();
  }

  /// Records [key] as seen. Returns true if it was NEW (i.e. should be
  /// processed), false if it is a duplicate still within the window.
  bool checkAndAdd(String key) {
    _evictExpired();
    final existing = _seen[key];
    if (existing != null && DateTime.now().difference(existing) < _ttl) {
      return false;
    }
    _seen.remove(key);
    _seen[key] = DateTime.now();
    while (_seen.length > _capacity) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }

  void _evictExpired() {
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in _seen.entries) {
      if (now.difference(entry.value) >= _ttl) {
        expired.add(entry.key);
      } else {
        break; // insertion-ordered: the rest are newer
      }
    }
    for (final k in expired) {
      _seen.remove(k);
    }
  }

  void clear() => _seen.clear();
}
