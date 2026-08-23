/// Hybrid post-quantum key announcement, discovery, and policy, ported 1:1 from
/// the PWA's `js/modules/pq.js`.
///
/// The crypto lives in `lib/core/crypto/pq.dart`; this file decides WHO gets it.
///
/// ## Discovery
/// Each client publishes its ML-KEM-768 public key as a signed, replaceable
/// kind-30078 bundle (`['d','nym-pq'],['t','nym-pq']`), the same machinery the
/// `nym-vouches` web of trust already uses. Holding a peer's valid announcement
/// IS the negotiation: there is no in-band capability exchange, so there is no
/// downgrade surface. Peers without one — Bitchat users, other Nostr clients,
/// older Nymchat builds — keep receiving classical NIP-17 unchanged.
///
/// ## Why the key derives from the nsec
/// ML-KEM keygen is a pure function of a 64-byte seed, so deriving that seed
/// from the identity key means every device sharing an nsec derives the SAME
/// ML-KEM key. That is what makes one replaceable announcement per identity
/// correct — two devices can never fight over it — and there is no new secret
/// to back up.
///
/// ## Why it is opt-in
/// A post-quantum wrap is readable only by a build that has ML-KEM. Sending a
/// classical copy alongside would defeat the point entirely (an attacker just
/// breaks the classical copy), so enabling is necessarily all-or-nothing per
/// identity. An older device on the same nsec cannot be detected — it publishes
/// no announcement — so the switch is an explicit, informed choice. Fresh
/// installs default on; upgrades default off.
///
/// Socket-free and UI-free so the ingest, expiry and policy rules are
/// unit-testable in isolation (mirrors `trust_graph.dart`).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/crypto/ml_kem.dart';
import '../../core/crypto/pq.dart' as pq;

/// The `d`/`t` tag identifying a post-quantum key announcement.
const String pqDTag = 'nym-pq';

/// The only algorithm this version understands.
const String pqAlgorithm = 'mlkem768';

/// Announcements expire so a downgraded or abandoned device stops attracting
/// post-quantum messages it cannot read.
const Duration pqTtl = Duration(days: 7);

/// Republish cadence, comfortably inside [pqTtl].
const Duration pqRepublishInterval = Duration(hours: 24);

/// Devices unseen this long drop off the roster shown in settings.
const Duration pqDeviceStale = Duration(days: 30);

/// How many previous key epochs stay decryptable after a rotation.
const int pqPreviousEpochs = 3;

/// Whether this identity sends post-quantum and advertises itself as able to
/// receive it.
///
/// There is no user setting: post-quantum is simply how Nymchat talks to
/// Nymchat. This exists only as an undocumented escape hatch (the PWA's
/// `nym_pq_mode`), so a field bug can be defused for affected users without an
/// emergency release. Nothing in the app writes it.
enum PqMode { on, off }

/// One device listed in our own announcement. Informational only — it never
/// gates decryption; it exists so the settings screen can say which devices
/// have actually been seen running a post-quantum-capable build.
class PqDevice {
  const PqDevice({required this.id, required this.version, required this.seenAt});

  final String id;
  final String version;
  final int seenAt;

  Map<String, dynamic> toJson() => {'id': id, 'ver': version, 'ts': seenAt};

  static PqDevice? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return PqDevice(
      id: id,
      version: raw['ver'] is String ? raw['ver'] as String : '',
      seenAt: raw['ts'] is int ? raw['ts'] as int : 0,
    );
  }
}

/// A parsed kind-30078 `nym-pq` announcement.
class PqAnnouncement {
  const PqAnnouncement({
    required this.publicKey,
    required this.expiresAt,
    required this.epoch,
    this.devices = const [],
    this.retracted = false,
  });

  /// Null when [retracted], and also null for a Nymchat client that cannot or
  /// will not do post-quantum — post-quantum switched off, or an extension /
  /// NIP-46 login that cannot seal a hybrid message at all. A KEM-less
  /// announcement is still a valid Nymchat claim.
  final Uint8List? publicKey;
  final int expiresAt;
  final int epoch;
  final List<PqDevice> devices;

  /// A replaceable event cannot be unpublished, so turning post-quantum off
  /// supersedes the announcement with a retracted, already-expired one.
  final bool retracted;

  /// Parses an announcement's `content`. Returns null for anything malformed,
  /// wrong-algorithm, or carrying a wrong-length key — a bad announcement must
  /// leave the peer classical rather than half-configured.
  ///
  /// Note this does NOT check the event signature: that happens upstream, and
  /// it is what binds the ML-KEM key to the Nostr identity. An attacker cannot
  /// substitute their own KEM key without also forging a secp256k1 signature.
  static PqAnnouncement? parse(String content) {
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['alg'] != pqAlgorithm) return null;

    final exp = decoded['exp'];
    if (exp is! int) return null;

    // An explicit retraction withdraws the whole claim, Nymchat and all.
    // Nothing emits one today — turning post-quantum off republishes without a
    // key instead — but a peer that does must be honoured.
    if (decoded['retracted'] == true) {
      return PqAnnouncement(
          publicKey: null, expiresAt: exp, epoch: 0, retracted: true);
    }

    // No `pk` is a valid announcement, not a retraction: a Nymchat client
    // without post-quantum. Recording it is what stops us sending a pointless
    // Bitchat wrap.
    Uint8List? pk;
    if (decoded['pk'] != null) {
      final pkRaw = decoded['pk'];
      if (pkRaw is! String) return null;
      try {
        pk = pq.b64uDecode(pkRaw);
      } catch (_) {
        return null;
      }
      if (pk.length != mlKemPublicKeyLength) return null;
    }

    final devices = <PqDevice>[];
    final rawDevices = decoded['devices'];
    if (rawDevices is List) {
      for (final d in rawDevices) {
        final parsed = PqDevice.fromJson(d);
        if (parsed != null) devices.add(parsed);
      }
    }

    return PqAnnouncement(
      publicKey: pk,
      expiresAt: exp,
      epoch: decoded['epoch'] is int ? decoded['epoch'] as int : 0,
      devices: devices,
    );
  }

  /// Builds the `content` payload for our own announcement.
  /// Builds the `content` payload for our own announcement. [publicKey] is
  /// null when we cannot or will not do post-quantum — the announcement still
  /// goes out, because its presence is what tells peers we run Nymchat.
  static String encode({
    required Uint8List? publicKey,
    required int expiresAt,
    required int epoch,
    required List<PqDevice> devices,
  }) =>
      jsonEncode({
        'v': 1,
        'alg': pqAlgorithm,
        // Marks this as a Nymchat client regardless of whether a KEM key is
        // present, so "Nymchat without post-quantum" stays distinguishable
        // from a retraction.
        'nym': 1,
        'epoch': epoch,
        if (publicKey != null) 'pk': pq.b64uEncode(publicKey),
        'exp': expiresAt,
        'devices': [for (final d in devices) d.toJson()],
      });

  /// The payload that retracts our announcement.
  static String encodeRetraction(int nowSec) => jsonEncode({
        'v': 1,
        'alg': pqAlgorithm,
        'retracted': true,
        'exp': nowSec,
      });
}

/// The pubkey -> announced ML-KEM key map, with expiry.
///
/// Holding an entry for a peer is exactly what makes them post-quantum capable,
/// so [keyFor] returning null is the signal to send classical NIP-17. Every
/// caller treats it that way, which is what makes a missing or expired
/// announcement degrade cleanly instead of failing a send.
class PqRegistry {
  PqRegistry({this.maxEntries = 5000});

  final int maxEntries;
  final Map<String, ({Uint8List? pk, int exp, int epoch})> _keys = {};

  /// Ingests a peer's announcement. [content] is the event content; [pubkey]
  /// its (already signature-verified) author.
  ///
  /// A KEM-less announcement is recorded, not dropped: it still proves the peer
  /// runs Nymchat, which is what [isKnownNymchatClient] reports and what stops
  /// the send path wasting a Bitchat wrap on them.
  void ingest(String pubkey, String content, {required int nowSec}) {
    final ann = PqAnnouncement.parse(content);
    if (ann == null) return;
    if (ann.retracted || ann.expiresAt <= nowSec) {
      _keys.remove(pubkey);
      return;
    }
    record(pubkey, ann.publicKey, ann.expiresAt, ann.epoch);
  }

  /// Records a key. Also the path our own key takes, so self-addressed wraps
  /// resolve through the same lookup as everyone else's.
  ///
  /// The cap is enforced here rather than in [ingest] so every write goes
  /// through one bound (Dart's Map preserves insertion order, so the evicted
  /// entry is the earliest-recorded one).
  void record(String pubkey, Uint8List? pk, int exp, int epoch) {
    _keys[pubkey] = (pk: pk, exp: exp, epoch: epoch);
    while (_keys.length > maxEntries) {
      _keys.remove(_keys.keys.first);
    }
  }

  void forget(String pubkey) => _keys.remove(pubkey);

  void clear() => _keys.clear();

  /// The live entry for a peer, or null. Shared by both lookups so expiry is
  /// enforced in exactly one place.
  ({Uint8List? pk, int exp, int epoch})? _entry(String pubkey, int nowSec) {
    final rec = _keys[pubkey];
    if (rec == null) return null;
    if (rec.exp <= nowSec) {
      _keys.remove(pubkey);
      return null;
    }
    return rec;
  }

  /// A peer's usable ML-KEM public key, or null when we have none, it expired,
  /// their announcement carries no key, or post-quantum is off for us.
  Uint8List? keyFor(String pubkey, {required int nowSec, required bool enabled}) {
    if (!enabled) return null;
    return _entry(pubkey, nowSec)?.pk;
  }

  /// Whether a peer has published a live capability announcement, i.e. whether
  /// they are provably running Nymchat.
  ///
  /// Deliberately NOT gated on our own post-quantum setting: it answers "which
  /// client is this?", not "should we use post-quantum?". A peer stays a known
  /// Nymchat client whether or not either side has post-quantum on.
  bool isKnownNymchatClient(String pubkey, {required int nowSec}) =>
      _entry(pubkey, nowSec) != null;

  /// Pubkeys we hold live ML-KEM keys for — used to size the group coverage
  /// readout and to decide whether a self-archive can be post-quantum. A
  /// KEM-less entry is just a Nymchat client and does not count.
  List<String> knownPeers({required int nowSec}) => [
        for (final e in _keys.entries)
          if (e.value.exp > nowSec && e.value.pk != null) e.key
      ];

  /// The registry as a persistable map: pubkey -> `[pk|null, exp, epoch]`.
  /// Already-expired entries are left out rather than written and dropped
  /// again on the way back in. Matches the PWA's `pqKeys` meta record
  /// (js/modules/persistence.js), field for field.
  Map<String, dynamic> toJson({required int nowSec}) => {
        for (final e in _keys.entries)
          if (e.value.exp > nowSec)
            e.key: [
              e.value.pk == null ? null : pq.b64uEncode(e.value.pk!),
              e.value.exp,
              e.value.epoch,
            ],
      };

  /// Restores peers' announced keys from the last session.
  ///
  /// A restored entry is a HINT, never the final word, and the difference
  /// matters more here than for the other caches this app persists: this is a
  /// key we ENCRYPT TO. A wrong one does not quietly degrade the message to
  /// classical, it makes it unreadable — the recipient holds no secret half to
  /// decapsulate with and the text never opens for them.
  ///
  /// Two bounds keep that from happening. Entries past the announcement's own
  /// expiry are dropped rather than restored, and any fresher announcement —
  /// pushed by the standing subscription, or fetched from the archive —
  /// replaces what is here, because [ingest] overwrites unconditionally. Key
  /// ROTATION is survivable even so: a recipient derives the current epoch and
  /// [pqPreviousEpochs] before it, so a slightly stale key still opens. What is
  /// not survivable is a peer who moved from an nsec to a remote signer,
  /// because they then hold no ML-KEM secret at all — that is what the expiry
  /// bound is really protecting against.
  ///
  /// Anything malformed or wrong-length is skipped entry by entry: a single
  /// corrupt row must not cost the whole cache.
  void hydrate(Map<String, dynamic> raw, {required int nowSec}) {
    for (final entry in raw.entries) {
      final v = entry.value;
      if (v is! List || v.length < 3) continue;
      final exp = v[1];
      if (exp is! int || exp <= nowSec) continue;
      final epoch = v[2] is int ? v[2] as int : 0;
      Uint8List? pk;
      final pkRaw = v[0];
      if (pkRaw != null) {
        if (pkRaw is! String) continue;
        try {
          pk = pq.b64uDecode(pkRaw);
        } catch (_) {
          continue;
        }
        if (pk.length != mlKemPublicKeyLength) continue;
      }
      record(entry.key, pk, exp, epoch);
    }
  }
}

/// Policy: whether this identity is capable of, and configured for,
/// post-quantum messaging.
class PqPolicy {
  const PqPolicy._();

  /// Whether we can RECEIVE post-quantum messages, and therefore whether we
  /// announce an ML-KEM key for peers to encapsulate to.
  ///
  /// Needs the nsec: the ML-KEM keypair derives from it, and opening a message
  /// means decapsulating with its secret half. An extension or NIP-46 signer
  /// holds the nsec and will not do ML-KEM, so those logins cannot receive.
  static bool capable({required Uint8List? privkey}) => privkey != null;

  /// Whether we can SEND post-quantum, which is a weaker requirement.
  ///
  /// A NIP-17 message is a SEAL under our identity key inside a WRAP under a
  /// throwaway key we generate ourselves on every send. Only the seal needs the
  /// signer, so a remote one can still hybridize the wrap — and the wrap is
  /// what a recorder stores, so that already defeats harvest-now-decrypt-later.
  /// The seal's classical encryption is only reachable by someone who has
  /// ALREADY broken the post-quantum layer.
  ///
  /// Deliberately not symmetric with [capable]: such a login sends
  /// post-quantum but still receives classical. Half a conversation, and worth
  /// having — a recorded outbound message is still a recorded message.
  static bool sendCapable() => true;

  static bool enabled({required Uint8List? privkey, required PqMode mode}) =>
      sendCapable() && mode == PqMode.on;

  /// Whether copies addressed to OURSELVES — self-wraps, the archive, synced
  /// settings — can be post-quantum. They are addressed to us, so this is the
  /// receive-side question: encapsulating to a key we cannot decapsulate with
  /// would lock this device out of its own history.
  static bool selfEnabled({required Uint8List? privkey, required PqMode mode}) =>
      capable(privkey: privkey) && mode == PqMode.on;

  /// Post-quantum is on for anyone who can do it. Kept as a function so the
  /// escape hatch has somewhere to live.
  static PqMode initialMode({required bool seenBefore}) => PqMode.on;

  /// Whether this boot was an upgrade into post-quantum rather than a fresh
  /// install, and so warrants the one-time notice. [seenBefore] is the
  /// `nym_last_online_ts` check — any prior version wrote it.
  static bool upgradeNoticeNeeded({required bool seenBefore}) => seenBefore;

  /// Merges [deviceId] into [previous], dropping entries not seen for
  /// [pqDeviceStale] and capping the list. Newest first.
  static List<PqDevice> mergeDeviceRoster(
    List<PqDevice> previous,
    String deviceId,
    String version, {
    required int nowSec,
    int max = 16,
  }) {
    final out = [
      for (final d in previous)
        if (d.id != deviceId && (nowSec - d.seenAt) < pqDeviceStale.inSeconds) d,
      PqDevice(id: deviceId, version: version, seenAt: nowSec),
    ];
    out.sort((a, b) => b.seenAt.compareTo(a.seenAt));
    return out.length > max ? out.sublist(0, max) : out;
  }
}

/// Which transports a 1:1 PM should use. Mirrors the PWA's `pqPmPlan`
/// (js/modules/pq.js) — both apps must make the same call or a peer receives a
/// wrap it cannot open, or worse, two copies of the same plaintext.
class PqPmPlan {
  const PqPmPlan({
    required this.kemPublicKey,
    required this.bitchat,
    required this.nym,
    this.provenNym = false,
  });

  /// Non-null when the recipient has a live announced ML-KEM key, which is
  /// proof they can decrypt a hybrid wrap.
  final Uint8List? kemPublicKey;

  /// Also send a Bitchat-format wrap.
  final bool bitchat;

  /// Send the Nymchat-format wrap (post-quantum when [pq], classical
  /// otherwise).
  final bool nym;

  /// The recipient published a live capability announcement, so they are
  /// provably running Nymchat. Surfaced for tests and diagnostics.
  final bool provenNym;

  bool get pq => kemPublicKey != null;

  /// Decides the transports for a recipient.
  ///
  /// There is no setting. Nymchat-to-Nymchat is post-quantum; anyone we cannot
  /// prove is on Nymchat gets exactly what they got before post-quantum
  /// existed. The whole rule is one question — has this peer published a
  /// capability announcement ([provenNymchat])? — because that announcement is
  /// signed and cannot be faked, whereas inferring the client from public
  /// activity would occasionally be wrong, and being wrong here means sending
  /// someone a message their app cannot open, with no error and no retry.
  ///
  /// A post-quantum wrap is never accompanied by a Bitchat copy of the same
  /// plaintext: it would hand a future quantum attacker the easier target and
  /// make the shield badge a lie, and it buys no reach, because a peer with an
  /// ML-KEM key is demonstrably not on Bitchat. That falls out of the rule
  /// rather than being a special case — holding a key implies holding the
  /// announcement.
  static PqPmPlan decide({
    required Uint8List? recipientKemKey,
    required bool knownBitchat,
    required bool knownNym,
    bool provenNymchat = false,
  }) {
    final unknown = !knownBitchat && !knownNym;
    // Holding a KEM key means we hold their announcement, so it always implies
    // a proven Nymchat client. Deriving it here rather than trusting the caller
    // keeps the two arguments from ever disagreeing.
    final proven = provenNymchat || recipientKemKey != null;
    // The Bitchat wrap exists to reach someone who MIGHT be running Bitchat. A
    // live announcement proves they are not, so it is dropped; without one we
    // cannot tell, so it is sent.
    final bitchat = (knownBitchat || unknown) && !proven;
    return PqPmPlan(
      kemPublicKey: recipientKemKey,
      bitchat: bitchat,
      // Invariant: a message must always leave in SOME format. The other terms
      // happen to cover every case today, but a silent no-send is such a bad
      // failure — no error, no retry, the message simply never exists — that
      // the guard stays.
      nym: !bitchat || knownNym || unknown || proven,
      provenNym: proven,
    );
  }
}

/// Our own ML-KEM keys for the current epoch plus a bounded window of previous
/// ones, so a wrap sent just before a rotation still opens. Ordered
/// newest-first, matching the PWA's `pqSelfCandidates`.
List<({Uint8List kemSk, Uint8List kemPk})> pqSelfCandidates(
    Uint8List privkey, int epoch) {
  final out = <({Uint8List kemSk, Uint8List kemPk})>[];
  for (var e = epoch; e >= 0 && e > epoch - 1 - pqPreviousEpochs; e--) {
    final kp = pq.pqKeypairFromPrivkey(privkey, e);
    out.add((kemSk: kp.secretKey, kemPk: kp.publicKey));
  }
  return out;
}
