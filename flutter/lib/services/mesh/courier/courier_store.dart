// courier_store.dart - The mail this device is carrying for other people.
//
// Spray-and-wait, bounded on every axis. A message sealed to an unreachable
// peer is handed to a few nearby peers, each of whom carries it and delivers
// it if they meet the recipient — and may hand a share of their remaining
// budget on to peers THEY meet. The budget halves at each hand-off (binary
// split), so a message reaches a bounded number of carriers instead of
// flooding the mesh with copies of itself.
//
// Everything here is policy and pure state, so the parts that decide who gets
// told what — and, more importantly, who does NOT — are testable without a
// radio: what may be deposited, who may be a courier, how far a copy spreads,
// and when a carried envelope is dropped.

import 'dart:typed_data';

import 'courier_envelope.dart';

/// One envelope being carried, plus what this device knows about carrying it.
class CarriedEnvelope {
  CarriedEnvelope({
    required this.envelope,
    required this.receivedAtMs,
    Set<String>? handedTo,
  }) : handedTo = handedTo ?? <String>{};

  final CourierEnvelope envelope;
  final int receivedAtMs;

  /// Peers already given a share of this envelope, so a re-spray adds NEW
  /// carriers instead of burning budget on the same ones over and over.
  final Set<String> handedTo;
}

/// The carried mail, with the rules that bound it.
class CourierStore {
  CourierStore({
    this.capacity = 100,
    this.maxCouriersPerDeposit = 3,
    int Function()? nowMs,
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Most envelopes carried for other people at once. This is somebody else's
  /// mail taking up our storage and our airtime, so it is a small number.
  final int capacity;

  /// How many nearby peers one deposit is sprayed to. Redundancy buys delivery
  /// odds; each extra copy also tells one more person that a message exists.
  final int maxCouriersPerDeposit;

  final int Function() _now;

  /// Keyed by a hex digest of the ciphertext, so the same envelope arriving
  /// from two different couriers is carried once.
  final Map<String, CarriedEnvelope> _carried = <String, CarriedEnvelope>{};

  int get length => _carried.length;
  List<CarriedEnvelope> get carried => List.unmodifiable(_carried.values);

  /// Whether a message to [recipientStaticKeyHex] may be couriered at all.
  ///
  /// This is the privacy gate, and it is deliberately conservative. Handing an
  /// envelope to a courier tells that courier a message exists and that we
  /// sent it — never the content, never the recipient, but the fact. So:
  ///
  ///  * [isGhostPinned] — NEVER. The peer met us as a ghost and knows us only
  ///    as that; asking a stranger to carry mail on that conversation's behalf
  ///    is exactly the link the ghost identity exists to prevent. This mirrors
  ///    the sender outbox's refusal to republish a ghost-pinned PM to Nostr.
  ///  * [isGhostMode] — NEVER, for the same reason from the other direction:
  ///    while WE are ghosted, a deposit associates our throwaway identity with
  ///    a message someone else will still be carrying after we rotate.
  ///  * a recipient with no real static key — nothing to seal to.
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

  /// Whether [peer] may be handed mail to carry.
  ///
  /// Only a peer whose announce we have verified: an unverified peer is just a
  /// radio claiming a name, and handing it an envelope tells an unknown party
  /// that we are sending mail. Our own ghost epochs are excluded too — a
  /// courier that is us is no redundancy at all.
  static bool mayCourier({
    required bool isVerified,
    required bool isSelf,
    required bool isRecipient,
  }) {
    if (isSelf) return false;
    if (isRecipient) return false; // Delivered directly, not couriered.
    return isVerified;
  }

  /// The copy budget a holder passes on when handing an envelope to another
  /// courier — a binary split, keeping the larger half.
  ///
  /// At 1 the holder keeps carrying and hands nothing on: the message still
  /// gets delivered if this device meets the recipient, but it stops spreading.
  /// That is what makes "spray and wait" bounded rather than a flood.
  static int sprayShare(int copies) => copies <= 1 ? 0 : copies ~/ 2;

  /// What the holder keeps after spraying [sprayShare] away.
  static int keepShare(int copies) => copies - sprayShare(copies);

  /// Files an envelope to carry. Returns false when it was already held, has
  /// expired, or the store is full of fresher mail.
  bool accept(CourierEnvelope envelope, String ciphertextKey) {
    final now = _now();
    if (envelope.isExpiredAt(now)) return false;
    if (_carried.containsKey(ciphertextKey)) return false;
    _carried[ciphertextKey] =
        CarriedEnvelope(envelope: envelope, receivedAtMs: now);
    while (_carried.length > capacity) {
      // Oldest-received first: the newest mail has the best chance of still
      // mattering to somebody.
      _carried.remove(_carried.keys.first);
    }
    return true;
  }

  /// Replaces a carried envelope's remaining budget (after a spray).
  void setCopies(String ciphertextKey, int copies) {
    final held = _carried[ciphertextKey];
    if (held == null) return;
    _carried[ciphertextKey] = CarriedEnvelope(
      envelope: held.envelope.withCopies(copies),
      receivedAtMs: held.receivedAtMs,
      handedTo: held.handedTo,
    );
  }

  /// Notes that [peerID] has been given a share of this envelope.
  void markHandedTo(String ciphertextKey, String peerID) {
    _carried[ciphertextKey]?.handedTo.add(peerID);
  }

  /// Drops [ciphertextKey] — delivered, or given up on.
  bool drop(String ciphertextKey) => _carried.remove(ciphertextKey) != null;

  /// Drops everything that has expired. Returns whether anything went.
  bool prune() {
    final now = _now();
    final before = _carried.length;
    _carried.removeWhere((_, c) => c.envelope.isExpiredAt(now));
    return _carried.length != before;
  }

  /// The carried envelopes whose recipient tag is one of [tags] — i.e. the mail
  /// for a peer we have just met.
  List<MapEntry<String, CarriedEnvelope>> forTags(List<Uint8List> tags) {
    final wanted = {for (final t in tags) _hex(t)};
    return [
      for (final e in _carried.entries)
        if (wanted.contains(_hex(e.value.envelope.recipientTag))) e,
    ];
  }

  /// The carried envelopes that still have budget to hand on, excluding any
  /// [peerID] has already been given.
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
