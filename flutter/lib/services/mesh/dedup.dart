import 'dart:collection';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'mesh_constants.dart';

/// Bounded, expiring seen-set (bitchat: 1000 entries, 5 minutes) that stops the flood mesh from looping.
class SeenPackets {
  SeenPackets({
    int capacity = MeshConstants.seenPacketCapacity,
    Duration ttl = MeshConstants.seenPacketTtl,
  })  : _capacity = capacity,
        _ttl = ttl;

  final int _capacity;
  final Duration _ttl;

  // Insertion-ordered, so iteration runs oldest first; value is the insertion time.
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  /// Content key over every field except the mutable TTL, so relayed copies dedupe against the original.
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

  /// Records [key]; returns true when it is new, false for a duplicate within the window.
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
        break; // Insertion-ordered: the rest are newer.
      }
    }
    for (final k in expired) {
      _seen.remove(k);
    }
  }

  void clear() => _seen.clear();
}
