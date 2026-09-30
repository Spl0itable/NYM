// This device's one-time prekeys; a consumed private half survives a grace window for spray-and-wait redeliveries.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../noise/noise_crypto.dart';
import 'prekey_bundle.dart';

class LocalPrekey {
  LocalPrekey({
    required this.id,
    required this.publicKey,
    required this.privateKey,
    this.consumedAtMs,
  });

  final int id;
  final Uint8List publicKey;
  final Uint8List privateKey;

  /// When mail sealed to this key was first opened; the private half is deleted [LocalPrekeys.graceMs] later.
  int? consumedAtMs;

  bool get isConsumed => consumedAtMs != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'pub': base64Encode(publicKey),
        'priv': base64Encode(privateKey),
        if (consumedAtMs != null) 'used': consumedAtMs,
      };

  static LocalPrekey? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final pub = raw['pub'];
    final priv = raw['priv'];
    if (id is! num || pub is! String || priv is! String) return null;
    try {
      return LocalPrekey(
        id: id.toInt(),
        publicKey: base64Decode(pub),
        privateKey: base64Decode(priv),
        consumedAtMs: raw['used'] is num ? (raw['used'] as num).toInt() : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class LocalPrekeys {
  LocalPrekeys({int Function()? nowMs, Random? random})
      : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? Random.secure();

  final int Function() _now;
  final Random _random;

  /// Consumed-key survival for redeliveries of the same envelope; 48h, matching bitchat.
  static const int graceMs = 48 * 60 * 60 * 1000;

  /// Kept small: each published key is another key an attacker could try to obtain.
  static const int batchSize = PrekeyBundle.maxPrekeys;

  final List<LocalPrekey> _keys = <LocalPrekey>[];
  int _nextId = 1;

  List<LocalPrekey> get keys => List.unmodifiable(_keys);

  List<LocalPrekey> get available =>
      _keys.where((k) => !k.isConsumed).toList(growable: false);

  /// Mints keys up to [batchSize]; returns whether any were minted, so only changed bundles re-gossip.
  Future<bool> replenish() async {
    var minted = false;
    while (available.length < batchSize) {
      final (priv, pub) = await NoiseCrypto.x25519Generate();
      _keys.add(LocalPrekey(id: _nextId++, publicKey: pub, privateKey: priv));
      minted = true;
    }
    return minted;
  }

  /// The private half for [id], or null when never ours or past its grace window.
  Uint8List? privateKeyFor(int id) {
    for (final k in _keys) {
      if (k.id != id) continue;
      final used = k.consumedAtMs;
      if (used != null && _now() - used > graceMs) return null;
      return k.privateKey;
    }
    return null;
  }

  /// The public half for [id], needed as the responder static when opening.
  Uint8List? publicKeyFor(int id) {
    for (final k in _keys) {
      if (k.id == id) return k.publicKey;
    }
    return null;
  }

  /// Marks [id] used; true only on the first open, so the bundle re-gossips once.
  bool markConsumed(int id) {
    for (final k in _keys) {
      if (k.id != id) continue;
      if (k.isConsumed) return false;
      k.consumedAtMs = _now();
      return true;
    }
    return false;
  }

  /// Deletes consumed keys past their grace window; this is where forward secrecy happens.
  bool prune() {
    final now = _now();
    final before = _keys.length;
    _keys.removeWhere((k) {
      final used = k.consumedAtMs;
      return used != null && now - used > graceMs;
    });
    return _keys.length != before;
  }

  /// Random rather than first, so two senders rarely burn the same key.
  Prekey? chooseFrom(List<Prekey> published) {
    if (published.isEmpty) return null;
    return published[_random.nextInt(published.length)];
  }

  String encode() => jsonEncode({
        'next': _nextId,
        'keys': [for (final k in _keys) k.toJson()],
      });

  void decode(String? raw) {
    _keys.clear();
    _nextId = 1;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final next = decoded['next'];
      if (next is num) _nextId = next.toInt();
      final rows = decoded['keys'];
      if (rows is! List) return;
      for (final row in rows) {
        final k = LocalPrekey.fromJson(row);
        if (k != null) _keys.add(k);
      }
    } catch (_) {
      // A corrupt blob costs the batch, which is replenished on next use.
      _keys.clear();
    }
    // Never re-issue an id whose private half may already be deleted.
    for (final k in _keys) {
      if (k.id >= _nextId) _nextId = k.id + 1;
    }
  }

  void clear() {
    _keys.clear();
    _nextId = 1;
  }
}
