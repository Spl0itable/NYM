// local_prekeys.dart - The one-time keys this device publishes and consumes.
//
// The half of the prekey story that lives on the recipient's side. We mint a
// small batch of X25519 keypairs, publish the public halves in a signed
// [PrekeyBundle], and delete each private half once mail sealed to it has been
// opened. That deletion is the whole point: after it, an envelope captured in
// transit cannot be opened by anyone, including us.
//
// Deletion is not immediate, and the delay is deliberate. Spray-and-wait means
// several couriers may be carrying copies of the SAME envelope, and they arrive
// whenever their carriers happen to meet us. Deleting the key on first open
// would make every later copy undecryptable — the message would look lost even
// though it arrived. So a consumed key survives a grace window, long enough for
// the redeliveries, and is then gone for good.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../noise/noise_crypto.dart';
import 'prekey_bundle.dart';

/// One minted keypair and its lifecycle.
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

  /// When mail sealed to this key was first opened, or null while unused.
  /// After [LocalPrekeys.graceMs] past this, the private half is deleted.
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

/// The device's own prekeys.
class LocalPrekeys {
  LocalPrekeys({int Function()? nowMs, Random? random})
      : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? Random.secure();

  final int Function() _now;
  final Random _random;

  /// How long a consumed key's private half survives, so spray-and-wait
  /// redeliveries of the same envelope still open. 48h, matching bitchat.
  static const int graceMs = 48 * 60 * 60 * 1000;

  /// How many unused keys to keep published. Small: each is another key an
  /// attacker could try to obtain, and the batch is cheap to refresh.
  static const int batchSize = PrekeyBundle.maxPrekeys;

  final List<LocalPrekey> _keys = <LocalPrekey>[];
  int _nextId = 1;

  List<LocalPrekey> get keys => List.unmodifiable(_keys);

  /// The unused keys, which are what a bundle publishes.
  List<LocalPrekey> get available =>
      _keys.where((k) => !k.isConsumed).toList(growable: false);

  /// Mints keys until [batchSize] unused ones exist. Returns whether anything
  /// was minted, so the caller only re-gossips a bundle that actually changed.
  Future<bool> replenish() async {
    var minted = false;
    while (available.length < batchSize) {
      final (priv, pub) = await NoiseCrypto.x25519Generate();
      _keys.add(LocalPrekey(id: _nextId++, publicKey: pub, privateKey: priv));
      minted = true;
    }
    return minted;
  }

  /// The private half for [id], or null when it was never ours or its grace
  /// window has lapsed.
  Uint8List? privateKeyFor(int id) {
    for (final k in _keys) {
      if (k.id != id) continue;
      final used = k.consumedAtMs;
      if (used != null && _now() - used > graceMs) return null;
      return k.privateKey;
    }
    return null;
  }

  /// The public half for [id] — needed as the "responder static" when opening.
  Uint8List? publicKeyFor(int id) {
    for (final k in _keys) {
      if (k.id == id) return k.publicKey;
    }
    return null;
  }

  /// Marks [id] used. Returns true only when this was the FIRST open, so the
  /// caller re-gossips the shrunken bundle once rather than on every
  /// redelivery of the same message.
  bool markConsumed(int id) {
    for (final k in _keys) {
      if (k.id != id) continue;
      if (k.isConsumed) return false;
      k.consumedAtMs = _now();
      return true;
    }
    return false;
  }

  /// Deletes consumed keys whose grace window has lapsed. This is where
  /// forward secrecy actually happens — everything before it is bookkeeping.
  bool prune() {
    final now = _now();
    final before = _keys.length;
    _keys.removeWhere((k) {
      final used = k.consumedAtMs;
      return used != null && now - used > graceMs;
    });
    return _keys.length != before;
  }

  /// A prekey to seal to, chosen at random from a peer's published batch.
  ///
  /// Random rather than first: two senders picking the same key would burn it
  /// twice, and the second envelope would then depend on the grace window to
  /// open at all.
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
      // A corrupt blob costs the batch, which is replenished on next use —
      // never the launch.
      _keys.clear();
    }
    // Never re-issue an id: a repeated id would let a new key be sealed to
    // under an id whose private half we already deleted.
    for (final k in _keys) {
      if (k.id >= _nextId) _nextId = k.id + 1;
    }
  }

  void clear() {
    _keys.clear();
    _nextId = 1;
  }
}
