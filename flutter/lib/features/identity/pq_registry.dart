/// Post-quantum key announcement, discovery and policy, negotiated by signed kind-30078 `nym-pq` events.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/crypto/ml_kem.dart';
import '../../core/crypto/pq.dart' as pq;

/// The `d`/`t` tag identifying a post-quantum key announcement.
const String pqDTag = 'nym-pq';

/// The only algorithm this version understands.
const String pqAlgorithm = 'mlkem768';

/// Announcements expire so abandoned devices stop attracting messages they can't read.
const Duration pqTtl = Duration(days: 7);

/// Republish cadence, well inside [pqTtl].
const Duration pqRepublishInterval = Duration(hours: 24);

/// Devices unseen this long drop off the settings roster.
const Duration pqDeviceStale = Duration(days: 30);

/// Previous key epochs that stay decryptable after a rotation.
const int pqPreviousEpochs = 3;

/// Undocumented escape hatch (`nym_pq_mode`) to defuse a field bug without a release; nothing in the app writes it.
enum PqMode { on, off }

/// A device in our own announcement; its capability gates hybrid sealing to the account, never decryption.
class PqDevice {
  const PqDevice({
    required this.id,
    required this.version,
    required this.seenAt,
    this.postQuantumCapable = false,
    this.layeredCapable = false,
  });

  final String id;
  final String version;
  final int seenAt;

  /// Can decapsulate (holds a local nsec); defaults false since unknown must not read as capable.
  final bool postQuantumCapable;

  /// Can open the layered format; older devices open only the combined one.
  final bool layeredCapable;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ver': version,
        'ts': seenAt,
        'pq': postQuantumCapable ? 1 : 0,
        'pq2': layeredCapable ? 1 : 0,
      };

  static PqDevice? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return PqDevice(
      id: id,
      version: raw['ver'] is String ? raw['ver'] as String : '',
      seenAt: raw['ts'] is int ? raw['ts'] as int : 0,
      postQuantumCapable: raw['pq'] == 1,
      // Absent on older builds, which open only the combined format.
      layeredCapable: raw['pq2'] == 1,
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
    this.version = 1,
    this.src,
    // Defaults describe a pre-split announcement: combined format only.
    this.acceptsLegacy = true,
    this.acceptsLayered = false,
  });

  /// Null when [retracted] or for a Nymchat client without post-quantum; still a valid Nymchat claim.
  final Uint8List? publicKey;
  final int expiresAt;
  final int epoch;
  final List<PqDevice> devices;

  /// Replaceable events can't be unpublished, so a retraction supersedes with an expired one.
  final bool retracted;

  /// Payload version: 1 is nsec-derived, 2 carries [src].
  final int version;

  /// Key seed origin; only `"root"` means the identity root. Null for v1 or unrecognized values.
  final String? src;

  /// Payload formats this peer can open; layered-only means a signer login that can't open combined.
  final bool acceptsLegacy;
  final bool acceptsLayered;

  /// Root-seeded needs both `v:2` and `src == "root"`; unknown `src` reads as legacy (spec §3).
  bool get rootSeeded => version >= 2 && src == 'root';

  /// Null for malformed, wrong-algorithm or wrong-length payloads so the peer stays classical; signature is checked upstream.
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

    // An explicit retraction withdraws the whole claim and must be honored.
    if (decoded['retracted'] == true) {
      return PqAnnouncement(
          publicKey: null, expiresAt: exp, epoch: 0, retracted: true);
    }

    // No `pk` is a keyless Nymchat client, not a retraction; recording it avoids a pointless Bitchat wrap.
    Uint8List? readKey(dynamic raw) {
      if (raw is! String) return null;
      Uint8List k;
      try {
        k = pq.b64uDecode(raw);
      } catch (_) {
        return null;
      }
      return k.length == mlKemPublicKeyLength ? k : null;
    }

    final hasPk1 = decoded['pk'] != null;
    final hasPk2 = decoded['pk2'] != null;
    final pk1 = hasPk1 ? readKey(decoded['pk']) : null;
    final pk2 = hasPk2 ? readKey(decoded['pk2']) : null;
    // A malformed key makes the announcement malformed: stay classical.
    if ((hasPk1 && pk1 == null) || (hasPk2 && pk2 == null)) return null;
    final pk = pk2 ?? pk1;

    final devices = <PqDevice>[];
    final rawDevices = decoded['devices'];
    if (rawDevices is List) {
      for (final d in rawDevices) {
        final parsed = PqDevice.fromJson(d);
        if (parsed != null) devices.add(parsed);
      }
    }

    final rawSrc = decoded['src'];
    return PqAnnouncement(
      publicKey: pk,
      expiresAt: exp,
      epoch: decoded['epoch'] is int ? decoded['epoch'] as int : 0,
      devices: devices,
      version: decoded['v'] is int ? decoded['v'] as int : 1,
      src: rawSrc is String ? rawSrc : null,
      acceptsLegacy: hasPk1,
      acceptsLayered: hasPk2,
    );
  }

  /// Our announcement payload; null [publicKey] still announces Nymchat, and [rootSeeded] promotes to `v:2`.
  static String encode({
    required Uint8List? publicKey,
    required int expiresAt,
    required int epoch,
    required List<PqDevice> devices,
    bool rootSeeded = false,
    // Whether we can open the combined format (holds an nsec), which decides `pk`.
    bool legacyCapable = true,
  }) =>
      jsonEncode({
        'v': rootSeeded ? 2 : 1,
        'alg': pqAlgorithm,
        // Marks a Nymchat client with or without a KEM key, distinct from a retraction.
        'nym': 1,
        'epoch': epoch,
        // `pk` means either format (nsec logins only); `pk2` layered only, so older peers send plain NIP-44 to signer logins.
        if (publicKey != null && legacyCapable) 'pk': pq.b64uEncode(publicKey),
        if (publicKey != null) 'pk2': pq.b64uEncode(publicKey),
        'exp': expiresAt,
        if (rootSeeded) 'src': 'root',
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

/// pubkey -> announced ML-KEM key with expiry; a null [keyFor] means send classical NIP-17.
class PqRegistry {
  PqRegistry({this.maxEntries = 5000});

  final int maxEntries;
  final Map<String,
      ({Uint8List? pk, int exp, int epoch, bool root, bool pq1, bool pq2})>
      _keys = {};

  /// Ingests a verified author's announcement; keyless ones are recorded to mark Nymchat clients.
  void ingest(String pubkey, String content,
      {required int nowSec, int createdAt = 0}) {
    final ann = PqAnnouncement.parse(content);
    if (ann == null) return;
    if (ann.retracted || ann.expiresAt <= nowSec) {
      _keys.remove(pubkey);
      return;
    }
    // Kind 30078 is addressable, so the newest (by expiry) wins; replays and keyless boot publishes must not undo a live key.
    final held = _entry(pubkey, nowSec);
    if (held != null && createdAt > 0) {
      final heldAt = held.exp - pqTtl.inSeconds;
      if (createdAt < heldAt) return;
    }
    record(pubkey, ann.publicKey, ann.expiresAt, ann.epoch,
        rootSeeded: ann.rootSeeded,
        acceptsLegacy: ann.acceptsLegacy,
        acceptsLayered: ann.acceptsLayered);
  }

  /// Records a key (our own too), enforcing the cap here; the earliest-recorded entry is evicted.
  void record(String pubkey, Uint8List? pk, int exp, int epoch,
      {bool rootSeeded = false,
      bool acceptsLegacy = true,
      bool acceptsLayered = false}) {
    _keys[pubkey] = (
      pk: pk,
      exp: exp,
      epoch: epoch,
      root: rootSeeded,
      pq1: acceptsLegacy,
      pq2: acceptsLayered
    );
    while (_keys.length > maxEntries) {
      _keys.remove(_keys.keys.first);
    }
  }

  void forget(String pubkey) => _keys.remove(pubkey);

  void clear() => _keys.clear();

  /// Live entry for a peer, or null; the single place expiry is enforced.
  ({Uint8List? pk, int exp, int epoch, bool root, bool pq1, bool pq2})? _entry(
      String pubkey, int nowSec) {
    final rec = _keys[pubkey];
    if (rec == null) return null;
    if (rec.exp <= nowSec) {
      _keys.remove(pubkey);
      return null;
    }
    return rec;
  }

  /// Usable ML-KEM key, or null when absent, expired, keyless, or post-quantum is off for us.
  Uint8List? keyFor(String pubkey, {required int nowSec, required bool enabled}) {
    if (!enabled) return null;
    return _entry(pubkey, nowSec)?.pk;
  }

  /// Epoch of a peer's live announcement, needed when checking a pasted root.
  int? epochFor(String pubkey) => _keys[pubkey]?.epoch;

  /// When a peer's live announcement was signed (exp - pqTtl), or 0 if expired or unknown.
  int announcedAtFor(String pubkey, {required int nowSec}) {
    final e = _entry(pubkey, nowSec);
    if (e == null || e.exp <= 0) return 0;
    return e.exp - pqTtl.inSeconds;
  }

  /// Root-seeded live announcement, for the badge; keyless entries never are.
  bool isRootSeeded(String pubkey,
      {required int nowSec, required bool enabled}) {
    if (!enabled) return false;
    final e = _entry(pubkey, nowSec);
    return e != null && e.pk != null && e.root;
  }

  /// Accepts the layered format, the only one a signer login on either end can open.
  bool acceptsLayered(String pubkey,
      {required int nowSec, required bool enabled}) {
    if (!enabled) return false;
    final e = _entry(pubkey, nowSec);
    return e != null && e.pk != null && e.pq2;
  }

  /// Whether a peer provably runs Nymchat, regardless of either side's post-quantum setting.
  bool isKnownNymchatClient(String pubkey, {required int nowSec}) =>
      _entry(pubkey, nowSec) != null;

  /// Pubkeys with live ML-KEM keys; keyless entries don't count.
  List<String> knownPeers({required int nowSec}) => [
        for (final e in _keys.entries)
          if (e.value.exp > nowSec && e.value.pk != null) e.key
      ];

  /// Persistable map pubkey -> `[pk|null, exp, epoch]` without expired entries, matching the PWA's `pqKeys` record.
  Map<String, dynamic> toJson({required int nowSec}) => {
        for (final e in _keys.entries)
          if (e.value.exp > nowSec)
            e.key: [
              e.value.pk == null ? null : pq.b64uEncode(e.value.pk!),
              e.value.exp,
              e.value.epoch,
              e.value.root ? 1 : 0,
              e.value.pq1 ? 1 : 0,
              e.value.pq2 ? 1 : 0,
            ],
      };

  /// Restores keys as hints only; expired entries and corrupt rows are skipped.
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
      // Rows from before formats were recorded come back keyless, since the send path must not seal to them.
      final preSplit = v.length <= 5;
      // Absent on rows from before the root existed; those peers were legacy.
      record(entry.key, preSplit ? null : pk, exp, epoch,
          rootSeeded: v.length > 3 && v[3] == 1,
          acceptsLegacy: v.length > 4 ? v[4] == 1 : true,
          acceptsLayered: v.length > 5 && v[5] == 1);
    }
  }
}

const Duration pqLookupRefetch = Duration(minutes: 10);

const Duration pqLookupRetrySoon = Duration(seconds: 15);

const Duration pqFreshKeyless = Duration(minutes: 10);

class PqLookupLimiter {
  final Map<String, ({int atMs, bool answered})> _misses = {};

  void record(String pubkey,
      {required bool found, required bool answered, required int nowMs}) {
    if (found) {
      _misses.remove(pubkey);
    } else {
      _misses[pubkey] = (atMs: nowMs, answered: answered);
    }
  }

  int? missedAt(String pubkey) => _misses[pubkey]?.atMs;

  bool unanswered(String pubkey) => _misses[pubkey]?.answered == false;

  bool due(String pubkey,
      {required int nowMs, required int announcedAtSec, required bool keyless}) {
    final miss = _misses[pubkey];
    if (miss == null) return true;
    final nowSec = nowMs ~/ 1000;
    final keylessFresh = keyless &&
        announcedAtSec > 0 &&
        nowSec - announcedAtSec < pqFreshKeyless.inSeconds;
    final wait = (!miss.answered || keylessFresh)
        ? pqLookupRetrySoon
        : pqLookupRefetch;
    return nowMs - miss.atMs >= wait.inMilliseconds;
  }
}

/// One-line reason a conversation is classical: the first failing term of [PqPmPlan.decide].
String pqPeerDiagnosis({
  required bool supported,
  required bool modeOff,
  required bool haveEntry,
  required bool haveKey,
  required bool acceptsLayered,
  int? lookupAgeSec,
}) {
  if (!supported) return 'ML-KEM did not load on this device';
  if (modeOff) return 'post-quantum mode is off';
  if (!haveEntry) {
    if (lookupAgeSec != null) {
      return 'no announcement found (looked ${lookupAgeSec}s ago)';
    }
    return 'no announcement held, and none has been looked up yet';
  }
  if (!haveKey) return 'their announcement carries no ML-KEM key';
  if (!acceptsLayered) {
    return 'their announcement offers only the legacy format (pk without pk2), '
        'which is never sent';
  }
  // A live layered key settles it; the Bitchat app can't publish an announcement.
  return 'post-quantum';
}

/// Whether this identity can do, and is set for, post-quantum messaging.
class PqPolicy {
  const PqPolicy._();

  /// Can receive post-quantum (root or nsec suffices), so we announce a key.
  static bool capable({required Uint8List? privkey, Uint8List? root}) =>
      privkey != null || root != null;

  /// The combined format mixes raw ECDH output, which no signer returns, so it needs the nsec.
  static bool legacyCapable({required Uint8List? privkey}) => privkey != null;

  /// Sending only hybridizes the wrap, which signers can do; deliberately not symmetric with [capable].
  static bool sendCapable() => true;

  static bool enabled({required Uint8List? privkey, required PqMode mode}) =>
      sendCapable() && mode == PqMode.on;

  /// Self-addressed copies need a key we can decapsulate, or this device loses its own history.
  static bool selfEnabled(
          {required Uint8List? privkey,
          Uint8List? root,
          required PqMode mode}) =>
      capable(privkey: privkey, root: root) && mode == PqMode.on;

  /// On for anyone who can; a function so the escape hatch has a home.
  static PqMode initialMode({required bool seenBefore}) => PqMode.on;

  /// Upgrade (not fresh install) warrants the one-time notice; [seenBefore] is the `nym_last_online_ts` check.
  static bool upgradeNoticeNeeded({required bool seenBefore}) => seenBefore;

  /// Merges [deviceId], dropping stale entries and capping the list; newest first.
  static List<PqDevice> mergeDeviceRoster(
    List<PqDevice> previous,
    String deviceId,
    String version, {
    required int nowSec,
    bool capable = false,
    bool layered = false,
    int max = 16,
  }) {
    final out = [
      for (final d in previous)
        if (d.id != deviceId && (nowSec - d.seenAt) < pqDeviceStale.inSeconds) d,
      PqDevice(
          id: deviceId,
          version: version,
          seenAt: nowSec,
          postQuantumCapable: capable,
          layeredCapable: layered),
    ];
    out.sort((a, b) => b.seenAt.compareTo(a.seenAt));
    return out.length > max ? out.sublist(0, max) : out;
  }

  /// Every live device can open a hybrid copy; an empty roster means no second device.
  static bool allDevicesCapable(
    List<PqDevice> devices,
    String selfDeviceId, {
    required int nowSec,
  }) {
    for (final d in devices) {
      if (d.id == selfDeviceId) continue;
      if ((nowSec - d.seenAt) >= pqDeviceStale.inSeconds) continue;
      if (!d.postQuantumCapable) return false;
    }
    return true;
  }

  /// Self-copies may be layered only if every live device can open that format.
  static bool allDevicesLayered(
    List<PqDevice> devices,
    String selfDeviceId, {
    required int nowSec,
  }) {
    for (final d in devices) {
      if (d.id == selfDeviceId) continue;
      if ((nowSec - d.seenAt) >= pqDeviceStale.inSeconds) continue;
      if (!d.layeredCapable) return false;
    }
    return true;
  }
}

/// Transports for a 1:1 PM; must match the PWA's `pqPmPlan` or peers get unopenable or duplicate wraps.
class PqPmPlan {
  const PqPmPlan({
    required this.kemPublicKey,
    required this.bitchat,
    required this.nym,
    this.provenNym = false,
    this.layered = false,
  });

  /// Non-null when the recipient has a live ML-KEM key.
  final Uint8List? kemPublicKey;

  /// Also send a Bitchat-format wrap.
  final bool bitchat;

  /// Send the Nymchat wrap (post-quantum when [pq], else classical).
  final bool nym;

  /// The recipient provably runs Nymchat; for tests and diagnostics.
  final bool provenNym;

  /// Layered wrap per the recipient's announcement, never guessed.
  final bool layered;

  bool get pq => kemPublicKey != null;

  /// Decided by a signed announcement alone; [knownBitchat] (a decrypted `v2:` payload) is the only overriding signal.
  static PqPmPlan decide({
    required Uint8List? recipientKemKey,
    required bool knownBitchat,
    required bool knownNym,
    bool provenNymchat = false,
    bool recipientAcceptsLayered = false,
    int bitchatSeenAtSec = 0,
    int announcedAtSec = 0,
  }) {
    // A KEM key implies a proven Nymchat client.
    final proven = provenNymchat || recipientKemKey != null;
    // Never the combined format; a `pk`-only peer gets ordinary NIP-44.
    final announced = recipientAcceptsLayered ? recipientKemKey : null;

    // Newer evidence decides between announcement and Bitchat traffic; untimed Bitchat evidence reads as older.
    final bitchatIsCurrent = knownBitchat &&
        bitchatSeenAtSec > 0 &&
        !(announcedAtSec > 0 && announcedAtSec >= bitchatSeenAtSec);

    // A live sealable key settles it: their `v2:` wrap was their Nymchat client dual-sending, not Bitchat.
    final bitchat =
        announced != null ? false : (bitchatIsCurrent || !proven);

    // Never pair a post-quantum wrap with a Bitchat copy of the same plaintext.
    final usableKem = bitchat ? null : announced;
    return PqPmPlan(
      kemPublicKey: usableKem,
      bitchat: bitchat,
      // Always send the Nymchat wrap; a Bitchat client just ignores it.
      nym: true,
      provenNym: proven,
      layered: usableKem != null,
    );
  }
}

/// Our ML-KEM keys for this epoch plus a bounded window, newest first, root-derived before nsec-derived.
List<({Uint8List kemSk, Uint8List kemPk})> pqRootCandidates(
  Uint8List root,
  int epoch,
) {
  final out = <({Uint8List kemSk, Uint8List kemPk})>[];
  for (var e = epoch; e >= 0 && e > epoch - 1 - pqPreviousEpochs; e--) {
    final kp = pq.pqKeypairFromRoot(root, e);
    out.add((kemSk: kp.secretKey, kemPk: kp.publicKey));
  }
  return out;
}

List<({Uint8List kemSk, Uint8List kemPk})> pqSelfCandidates(
  Uint8List privkey,
  int epoch, {
  Uint8List? root,
}) {
  final out = <({Uint8List kemSk, Uint8List kemPk})>[];
  if (root != null) {
    for (var e = epoch; e >= 0 && e > epoch - 1 - pqPreviousEpochs; e--) {
      final kp = pq.pqKeypairFromRoot(root, e);
      out.add((kemSk: kp.secretKey, kemPk: kp.publicKey));
    }
  }
  for (var e = epoch; e >= 0 && e > epoch - 1 - pqPreviousEpochs; e--) {
    final kp = pq.pqKeypairFromPrivkey(privkey, e);
    out.add((kemSk: kp.secretKey, kemPk: kp.publicKey));
  }
  return out;
}
