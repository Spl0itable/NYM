// Spray-and-wait mail carried for others, bounded by capacity, copy budget and expiry; pure state for tests.

import 'dart:typed_data';

import 'courier_envelope.dart';

class CarriedEnvelope {
  CarriedEnvelope({
    required this.envelope,
    required this.receivedAtMs,
    Set<String>? handedTo,
  }) : handedTo = handedTo ?? <String>{};

  final CourierEnvelope envelope;
  final int receivedAtMs;

  /// Peers already given a share, so re-sprays reach new carriers.
  final Set<String> handedTo;
}

class CourierStore {
  CourierStore({
    this.capacity = 100,
    this.maxCouriersPerDeposit = 3,
    int Function()? nowMs,
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Kept small: this is other people's mail using our storage and airtime.
  final int capacity;

  /// Each extra copy improves delivery odds but tells one more peer a message exists.
  final int maxCouriersPerDeposit;

  final int Function() _now;

  /// Keyed by a hex digest of the ciphertext, so duplicates from two couriers are carried once.
  final Map<String, CarriedEnvelope> _carried = <String, CarriedEnvelope>{};

  int get length => _carried.length;
  List<CarriedEnvelope> get carried => List.unmodifiable(_carried.values);

  /// Privacy gate: never courier while ghosted or to a ghost-pinned peer, and only to a real static key.
  static bool mayDeposit({
    required bool isGhostPinned,
    required bool isGhostMode,
    required bool hasRecipientStaticKey,
  }) {
    if (isGhostPinned) return false;
    if (isGhostMode) return false;
    if (!hasRecipientStaticKey) return false;
    return true;
  }

  /// Only announce-verified peers, excluding our own ghost epochs.
  static bool mayCourier({
    required bool isVerified,
    required bool isSelf,
    required bool isRecipient,
  }) {
    if (isSelf) return false;
    if (isRecipient) return false;
    return isVerified;
  }

  /// Binary split of the copy budget; at 1 nothing is handed on, which keeps the spray bounded.
  static int sprayShare(int copies) => copies <= 1 ? 0 : copies ~/ 2;

  static int keepShare(int copies) => copies - sprayShare(copies);

  /// Files an envelope; false when already held, expired, or the store is full of fresher mail.
  bool accept(CourierEnvelope envelope, String ciphertextKey) {
    final now = _now();
    if (envelope.isExpiredAt(now)) return false;
    if (_carried.containsKey(ciphertextKey)) return false;
    _carried[ciphertextKey] =
        CarriedEnvelope(envelope: envelope, receivedAtMs: now);
    while (_carried.length > capacity) {
      // Evict oldest-received first.
      _carried.remove(_carried.keys.first);
    }
    return true;
  }

  void setCopies(String ciphertextKey, int copies) {
    final held = _carried[ciphertextKey];
    if (held == null) return;
    _carried[ciphertextKey] = CarriedEnvelope(
      envelope: held.envelope.withCopies(copies),
      receivedAtMs: held.receivedAtMs,
      handedTo: held.handedTo,
    );
  }

  void markHandedTo(String ciphertextKey, String peerID) {
    _carried[ciphertextKey]?.handedTo.add(peerID);
  }

  bool drop(String ciphertextKey) => _carried.remove(ciphertextKey) != null;

  /// Drops expired envelopes; returns whether anything went.
  bool prune() {
    final now = _now();
    final before = _carried.length;
    _carried.removeWhere((_, c) => c.envelope.isExpiredAt(now));
    return _carried.length != before;
  }

  /// Carried envelopes for a peer we have just met.
  List<MapEntry<String, CarriedEnvelope>> forTags(List<Uint8List> tags) {
    final wanted = {for (final t in tags) _hex(t)};
    return [
      for (final e in _carried.entries)
        if (wanted.contains(_hex(e.value.envelope.recipientTag))) e,
    ];
  }

  /// Envelopes with budget left that [peerID] has not been given.
  List<MapEntry<String, CarriedEnvelope>> sprayableTo(String peerID) => [
        for (final e in _carried.entries)
          if (e.value.envelope.copies > 1 && !e.value.handedTo.contains(peerID))
            e,
      ];

  void clear() => _carried.clear();

  static String _hex(Uint8List b) {
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
