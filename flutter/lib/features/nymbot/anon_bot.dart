import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../core/crypto/keys.dart';
import '../../core/crypto/schnorr.dart';
import '../../core/crypto/ml_kem.dart';
import '../../core/crypto/pq.dart' as pq;
import '../../core/crypto/voucher.dart';
import '../../models/nostr_event.dart';
import '../../services/api/api_client.dart';
import 'nymbot_models.dart';
import 'nymbot_service.dart';

const int kAnonPrevMax = 4;
const int kAnonRunLanesMax = 64;
const int kAnonAnnounceTtlSec = 7 * 24 * 3600;
const int kAnonTokenMax = 200;
const int kAnonQuietMs = 10 * 60 * 1000;
const int kAnonSyncMinMs = 15 * 60 * 1000;
const int kAnonSyncSpanMs = 30 * 60 * 1000;

Map<String, Object?> settleAnonKeys(
    Map<String, dynamic> local, Map<String, dynamic> incoming, int max) {
  final cap = max > 0 ? max : 4;
  ({String? current, List<String> prev, num at}) norm(Map<String, dynamic> side) {
    final cur = side['current'];
    final rawAt = side['createdAt'];
    final rawPrev = side['prev'];
    final prev = <String>[
      if (rawPrev is List)
        for (final p in rawPrev)
          if (p is String && p.isNotEmpty) p.toLowerCase(),
    ];
    return (
      current: cur is String && cur.isNotEmpty ? cur.toLowerCase() : null,
      prev: prev,
      at: rawAt is num && rawAt > 0 ? rawAt : 0,
    );
  }

  List<String> uniq(List<String?> list, String? skip) {
    final out = <String>[];
    for (final pk in list) {
      if (pk != null && pk != skip && !out.contains(pk)) out.add(pk);
    }
    return out.take(cap).toList();
  }

  final l = norm(local);
  final i = norm(incoming);
  if (i.current == null) {
    return {'current': l.current, 'prev': uniq(l.prev, l.current), 'loser': null, 'rule': 'keep'};
  }
  if (l.current == null) {
    return {'current': i.current, 'prev': uniq(i.prev, i.current), 'loser': null, 'rule': 'adopt'};
  }
  if (l.current == i.current) {
    return {
      'current': l.current,
      'prev': uniq([...l.prev, ...i.prev], l.current),
      'loser': null,
      'rule': 'same',
    };
  }
  final iNext = i.prev.contains(l.current);
  final lNext = l.prev.contains(i.current);
  final aged = iNext && lNext && i.at > 0 && l.at > 0 && i.at != l.at;
  final takeIncoming = iNext != lNext
      ? iNext
      : (aged ? i.at > l.at : i.current!.compareTo(l.current!) < 0);
  final w = takeIncoming ? i : l;
  final x = takeIncoming ? l : i;
  return {
    'current': w.current,
    'prev': uniq([x.current, ...w.prev, ...x.prev], w.current),
    'loser': x.current,
    'rule': iNext != lNext ? 'next' : (iNext ? 'newer' : 'lower'),
  };
}

class AnonBotIdentity {
  const AnonBotIdentity({
    required this.sk,
    required this.pk,
    required this.root,
    required this.createdAt,
  });

  final Uint8List sk;
  final String pk;
  final Uint8List root;
  final int createdAt;

  factory AnonBotIdentity.generate() {
    final sk = generatePrivateKey();
    return AnonBotIdentity(
      sk: sk,
      pk: getPublicKeyHex(sk),
      root: pq.pqGenerateRoot(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

  static AnonBotIdentity? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final sk = raw['sk'];
    final pk = raw['pk'];
    final root = raw['root'];
    if (sk is! String || pk is! String || root is! String) return null;
    if (!_hex64.hasMatch(sk) || !_hex64.hasMatch(pk) || !_hex64.hasMatch(root)) {
      return null;
    }
    return AnonBotIdentity(
      sk: hexToBytes(sk),
      pk: pk.toLowerCase(),
      root: hexToBytes(root),
      createdAt: (raw['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'sk': bytesToHex(sk),
        'pk': pk,
        'root': bytesToHex(root),
        'createdAt': createdAt,
      };
}

class AnonVoucherOutput {
  const AnonVoucherOutput({
    required this.d,
    required this.x,
    required this.r,
    required this.b,
  });

  final int d;
  final String x;
  final String r;
  final String b;

  static AnonVoucherOutput? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final d = (raw['d'] as num?)?.toInt();
    final x = raw['x'], r = raw['r'], b = raw['b'];
    if (d == null || x is! String || r is! String || b is! String) return null;
    return AnonVoucherOutput(d: d, x: x, r: r, b: b);
  }

  Map<String, dynamic> toJson() => {'d': d, 'x': x, 'r': r, 'b': b};

  Map<String, dynamic> toWire() => {'d': d, 'B': b};
}

class AnonVoucherRequest {
  const AnonVoucherRequest({
    required this.tier,
    required this.reqId,
    required this.outputs,
    this.from,
  });

  final String tier;
  final String reqId;
  final List<AnonVoucherOutput> outputs;
  final String? from;

  static AnonVoucherRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final tier = raw['tier'], reqId = raw['reqId'];
    if (tier is! String || reqId is! String) return null;
    final list = raw['outputs'];
    if (list is! List || list.isEmpty) return null;
    final outputs = <AnonVoucherOutput>[];
    for (final o in list) {
      final parsed = AnonVoucherOutput.fromJson(o);
      if (parsed == null) return null;
      outputs.add(parsed);
    }
    final from = raw['from'];
    return AnonVoucherRequest(
      tier: tier,
      reqId: reqId,
      outputs: outputs,
      from: from is String ? from : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'tier': tier,
        'reqId': reqId,
        'outputs': outputs.map((o) => o.toJson()).toList(),
        if (from != null) 'from': from,
      };
}

class AnonVoucherToken {
  AnonVoucherToken({
    required this.d,
    required this.x,
    required this.c,
    required this.tier,
    this.redeemId,
  });

  final int d;
  final String x;
  final String c;
  final String tier;
  String? redeemId;

  static AnonVoucherToken? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final d = (raw['d'] as num?)?.toInt();
    final x = raw['x'], c = raw['C'] ?? raw['c'], tier = raw['tier'];
    if (d == null || x is! String || c is! String) return null;
    return AnonVoucherToken(
      d: d,
      x: x,
      c: c,
      tier: tier is String ? tier : 'standard',
      redeemId: raw['redeemId'] is String ? raw['redeemId'] as String : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'd': d,
        'x': x,
        'C': c,
        'tier': tier,
        if (redeemId != null) 'redeemId': redeemId,
      };

  Map<String, dynamic> toWire() => {'d': d, 'x': x, 'C': c};
}

class AnonBotState {
  AnonBotState({
    this.current,
    List<AnonBotIdentity>? prev,
    List<AnonVoucherToken>? tokens,
    this.pending,
    this.unsent = false,
    this.sent = false,
    this.quietAt = 0,
    this.sweepDue = false,
    List<String>? runs,
  })  : prev = prev ?? <AnonBotIdentity>[],
        tokens = tokens ?? <AnonVoucherToken>[],
        runs = runs ?? <String>[];

  AnonBotIdentity? current;
  List<AnonBotIdentity> prev;
  List<AnonVoucherToken> tokens;
  AnonVoucherRequest? pending;
  bool unsent;
  bool sent;
  int quietAt;
  bool sweepDue;
  List<String> runs;

  static AnonBotState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final current = AnonBotIdentity.fromJson(raw['current']);
    if (current == null) return null;
    final prev = <AnonBotIdentity>[];
    final rawPrev = raw['prev'];
    if (rawPrev is List) {
      for (final p in rawPrev) {
        final id = AnonBotIdentity.fromJson(p);
        if (id != null && prev.length < kAnonPrevMax) prev.add(id);
      }
    }
    final tokens = <AnonVoucherToken>[];
    final rawTokens = raw['tokens'];
    if (rawTokens is List) {
      for (final t in rawTokens) {
        final token = AnonVoucherToken.fromJson(t);
        if (token != null && tokens.length < kAnonTokenMax) tokens.add(token);
      }
    }
    return AnonBotState(
      current: current,
      prev: prev,
      tokens: tokens,
      pending: AnonVoucherRequest.fromJson(raw['pending']),
      unsent: raw['unsent'] == true,
      sent: raw['sent'] == true,
      quietAt: (raw['quietAt'] as num?)?.toInt() ?? 0,
      sweepDue: raw['sweepDue'] == true,
      runs: [
        if (raw['runs'] is List)
          for (final r in raw['runs'] as List)
            if (r is String && r.isNotEmpty) r,
      ].take(kAnonRunLanesMax).toList(),
    );
  }

  Map<String, dynamic> toLocalJson() => {
        ...toJson(),
        'unsent': unsent,
        'sent': sent,
        'quietAt': quietAt,
        'sweepDue': sweepDue,
        if (runs.isNotEmpty) 'runs': runs.take(kAnonRunLanesMax).toList(),
      };

  Map<String, dynamic> toJson() => {
        'current': current?.toJson(),
        'prev': prev.take(kAnonPrevMax).map((p) => p.toJson()).toList(),
        'tokens': tokens.take(kAnonTokenMax).map((t) => t.toJson()).toList(),
        'pending': pending?.toJson(),
      };

  List<String> pubkeys() => [
        if (current != null) current!.pk,
        ...prev.map((p) => p.pk),
      ];
}

class AnonBotException implements Exception {
  AnonBotException(this.message, {this.insufficient = false});
  final String message;
  final bool insufficient;
  @override
  String toString() => message;
}

class AnonBotManager {
  AnonBotManager(this._service);

  final NymbotService _service;

  bool _enabled = false;
  bool _loaded = false;
  String? _owner;
  AnonBotState? _state;
  Map<String, dynamic>? _keyset;
  final Map<String, MlKemKeyPair> _kemCache = {};
  Map<String, dynamic>? _announcement;
  int _announcementExp = 0;

  /// Identity [_announcement] belongs to, so a stale cache never seals replies to a dropped KEM key.
  String? _announcementPk;
  bool _flushing = false;

  Future<void> Function(String json)? persist;
  void Function()? onKeysChanged;
  void Function()? requestSync;
  Future<void> Function(String message)? onNotice;
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;
  Future<int> Function()? settleSweep;
  Timer? _syncTimer;
  int? _syncDue;
  Timer? _sweepTimer;
  static final Random _rng = Random.secure();

  int? get scheduledSyncAt => _syncDue;
  bool get unsent => _state?.unsent ?? false;
  bool get syncHeld {
    final st = _state;
    return st != null && st.unsent && nowMs() - st.quietAt < kAnonQuietMs;
  }

  int _syncDelayMs() => kAnonSyncMinMs + _rng.nextInt(kAnonSyncSpanMs);

  void _armSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _syncDue = null;
    final st = _state;
    if (st == null || st.current == null || !st.unsent) return;
    final delay = _syncDelayMs();
    _syncDue = nowMs() + delay;
    _syncTimer = Timer(Duration(milliseconds: delay), () {
      _syncTimer = null;
      _syncDue = null;
      if (!identical(_state, st) || !st.unsent) return;
      if (syncHeld) {
        _armSync();
        return;
      }
      requestSync?.call();
      _armSync();
    });
  }

  void _armSweep() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    final st = _state;
    if (st == null || !st.sweepDue) return;
    _sweepTimer = Timer(Duration(milliseconds: _syncDelayMs()), () async {
      _sweepTimer = null;
      if (!identical(_state, st) || !st.sweepDue) return;
      var ok = true;
      try {
        final run = settleSweep;
        if (run != null) {
          await run();
        } else {
          await sweepPrevious(quiet: true);
        }
      } catch (_) {
        ok = false;
      }
      if (!identical(_state, st)) return;
      if (ok && st.pending == null) {
        st.sweepDue = false;
        _save();
      } else {
        _armSweep();
      }
    });
  }

  void markSynced(String pk) {
    final st = _state;
    if (st == null || !st.unsent || st.current?.pk != pk) return;
    st.unsent = false;
    _save();
    _armSync();
  }

  void dispose() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _syncDue = null;
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  bool get enabled => _enabled;
  bool get loaded => _loaded;
  bool get ready => _enabled && _state?.current != null;
  AnonBotIdentity? get identity => _state?.current;
  String? get pubkey => _state?.current?.pk;
  List<String> get pubkeys => _state?.pubkeys() ?? const <String>[];
  AnonBotState? get state => _state;

  bool isAnonPubkey(String pk) => pubkeys.contains(pk);

  final Set<String> _lane = <String>{};

  Set<String> get laneIds => Set.unmodifiable(_lane);

  bool isLane(String id) => _lane.contains(id);

  bool runLane(String eventId) =>
      eventId.isNotEmpty && (_state?.runs.contains(eventId) ?? false);

  void keepRunLanes(Iterable<String> eventIds) {
    final st = _state;
    if (st == null) return;
    final next = eventIds.where((e) => e.isNotEmpty).take(kAnonRunLanesMax).toList();
    if (next.join(',') == st.runs.join(',')) return;
    st.runs = next;
    _save();
  }

  void markLane(String id) {
    if (id.isEmpty) return;
    _lane.remove(id);
    _lane.add(id);
    while (_lane.length > 4000) {
      _lane.remove(_lane.first);
    }
  }

  bool suppressSendTo(String pubkey, {required bool isBot}) =>
      _enabled && isBot;

  void setEnabled(bool on) {
    _enabled = on;
    onKeysChanged?.call();
  }

  void reset(String? owner) {
    if (_owner != owner) {
      dispose();
      _state = null;
      _kemCache.clear();
      _announcement = null;
      _announcementExp = 0;
      _announcementPk = null;
    }
    _owner = owner;
    _loaded = false;
  }

  void hydrate(String json) {
    try {
      final parsed = AnonBotState.fromJson(jsonDecode(json));
      if (parsed != null) {
        if (_state?.current == null) {
          _state = parsed;
          _kemCache.clear();
          _announcement = null;
          _announcementExp = 0;
          _announcementPk = null;
          onKeysChanged?.call();
        } else {
          applySynced(parsed.toJson());
          if (_state!.runs.isEmpty) _state!.runs = parsed.runs;
        }
      }
    } catch (_) {
    }
    _loaded = true;
    _armSync();
    _armSweep();
  }

  void markLoaded() {
    _loaded = true;
  }

  AnonBotIdentity? ensureIdentity({bool send = false}) {
    if (!_loaded) return null;
    final st = _state ??= AnonBotState();
    if (st.current == null) {
      st.current = AnonBotIdentity.generate();
      st.unsent = true;
      st.sent = send;
      st.quietAt = nowMs();
      _save();
      onKeysChanged?.call();
      _armSync();
    } else if (send && st.unsent && !st.sent) {
      st.sent = true;
      st.quietAt = nowMs();
      _save();
      _armSync();
    }
    return st.current;
  }

  void applySynced(Object? raw) {
    final parsed = AnonBotState.fromJson(raw);
    if (parsed == null || parsed.current == null) return;
    final st = _state ??= AnonBotState();
    final cur = st.current;
    Map<String, dynamic> pks(AnonBotState s) => {
          'current': s.current?.pk,
          'prev': s.prev.map((p) => p.pk).toList(),
          'createdAt': s.current?.createdAt ?? 0,
        };
    final out = settleAnonKeys(pks(st), pks(parsed), kAnonPrevMax);
    final byPk = <String, AnonBotIdentity>{
      for (final e in [parsed.current!, ...parsed.prev, ?cur, ...st.prev]) e.pk: e,
    };
    final prevBefore = st.prev.map((p) => p.pk).join(',');
    st.current = byPk[out['current']] ?? cur;
    st.prev = [
      for (final pk in (out['prev'] as List).cast<String>())
        if (byPk[pk] != null) byPk[pk]!,
    ];
    final same = cur != null && cur.pk == st.current!.pk;
    if (cur != null && cur.pk == parsed.current!.pk) {
      if (st.tokens.isEmpty) st.tokens = parsed.tokens;
    } else {
      _mergeTokens(parsed.tokens);
    }
    if ((out['rule'] == 'lower' || out['rule'] == 'newer') && !st.sweepDue) {
      st.sweepDue = true;
      _armSweep();
    }
    if (same) {
      if (st.prev.map((p) => p.pk).join(',') != prevBefore ||
          out['loser'] != null) {
        _save();
        onKeysChanged?.call();
      }
      return;
    }
    _kemCache.clear();
    _announcement = null;
    _announcementExp = 0;
    _announcementPk = null;
    _save();
    onKeysChanged?.call();
  }

  void _adoptPrev(AnonBotIdentity id) {
    final st = _state;
    if (st == null) return;
    if (st.prev.any((p) => p.pk == id.pk)) return;
    st.prev = [id, ...st.prev].take(kAnonPrevMax).toList();
  }

  void _mergeTokens(List<AnonVoucherToken> tokens) {
    final st = _state;
    if (st == null || tokens.isEmpty) return;
    final have = st.tokens.map((t) => t.x).toSet();
    for (final t in tokens) {
      if (have.add(t.x)) st.tokens.add(t);
    }
  }

  Future<int> rotate({bool sweep = false}) async {
    final st = _state ??= AnonBotState();
    final old = st.current;
    if (old != null) _adoptPrev(old);
    st.current = AnonBotIdentity.generate();
    _kemCache.clear();
    _announcement = null;
    _announcementExp = 0;
    _announcementPk = null;
    _save();
    onKeysChanged?.call();
    var moved = 0;
    if (sweep) moved = await sweepPrevious();
    return moved;
  }

  Future<int> sweepPrevious({bool quiet = false}) async {
    final st = _state;
    if (st == null || st.current == null || st.prev.isEmpty) return 0;
    final waiting = st.pending;
    if (waiting != null) {
      try {
        await _finishIssue(waiting);
      } catch (_) {}
      if (_state?.pending != null) return 0;
    }
    try {
      await keyset();
    } catch (_) {
      return 0;
    }
    var issued = 0;
    for (final old in List<AnonBotIdentity>.of(st.prev)) {
      BotBalance balance;
      try {
        balance = await _service.balance(
          pubkey: old.pk,
          auth: () async => _authFor('balance', old),
          anon: true,
        );
      } catch (_) {
        continue;
      }
      for (final tier in voucherTiers) {
        final whole =
            (tier == 'pro' ? balance.proBalance : balance.balance).floor();
        if (whole <= 0) continue;
        for (final denoms in voucherBatches(whole)) {
          final now = _state;
          if (now == null ||
              now.tokens.length + denoms.length > kAnonTokenMax) {
            break;
          }
          final request = AnonVoucherRequest(
            tier: tier,
            reqId: bytesToHex(randomBytes(32)),
            outputs: _blindOutputs(denoms),
            from: old.pk,
          );
          now.pending = request;
          _save();
          try {
            final minted = await _finishIssue(request);
            issued += minted.fold<int>(0, (sum, t) => sum + t.d);
          } catch (_) {
            if (_state?.pending != null) return issued;
            break;
          }
        }
      }
    }
    final after = _state;
    if (quiet && issued > 0 && after != null) {
      after.unsent = true;
      after.quietAt = nowMs();
      _save();
      _armSync();
    }
    return issued;
  }

  List<AnonVoucherOutput> _blindOutputs(List<int> denoms) {
    final outputs = <AnonVoucherOutput>[];
    for (final d in denoms) {
      final x = randomBytes(32);
      final r = voucherRandomScalar();
      final b = voucherBlind(x, r);
      outputs.add(AnonVoucherOutput(
        d: d,
        x: bytesToHex(x),
        r: voucherScalarHex(r),
        b: voucherPointHex(b),
      ));
    }
    return outputs;
  }

  MlKemKeyPair? kemFor(AnonBotIdentity id) {
    final hit = _kemCache[id.pk];
    if (hit != null) return hit;
    try {
      final keys = pq.pqKeypairFromRoot(id.root, 0);
      _kemCache[id.pk] = keys;
      return keys;
    } catch (_) {
      return null;
    }
  }

  AnonBotIdentity? identityForWrap(String pTag) {
    final st = _state;
    if (st == null) return null;
    for (final id in [if (st.current != null) st.current!, ...st.prev]) {
      if (id.pk == pTag) return id;
    }
    return null;
  }

  Map<String, dynamic>? announcement() {
    final id = identity;
    if (id == null) return null;
    final kem = kemFor(id);
    if (kem == null) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cached = _announcement;
    if (cached != null &&
        _announcementPk == id.pk &&
        _announcementExp > nowSec + 3600) {
      return cached;
    }
    final b64 = pq.b64uEncode(kem.publicKey);
    final exp = nowSec + kAnonAnnounceTtlSec;
    final payload = <String, dynamic>{
      'v': 2,
      'src': 'root',
      'alg': 'mlkem768',
      'nym': 1,
      'epoch': 0,
      'pk': b64,
      'pk2': b64,
      'exp': exp,
      'devices': <dynamic>[],
    };
    final event = finalizeEvent(
      UnsignedEvent(
        pubkey: id.pk,
        createdAt: nowSec,
        kind: 30078,
        tags: [
          ['d', 'nym-pq'],
          ['t', 'nym-pq'],
          ['expiration', '$exp'],
        ],
        content: jsonEncode(payload),
      ),
      id.sk,
    ).toJson();
    _announcement = event;
    _announcementExp = exp;
    _announcementPk = id.pk;
    return event;
  }

  Map<String, dynamic> _authFor(String action, AnonBotIdentity id,
          [String? payload]) =>
      Nip98Auth.build(
        action: action,
        url: _service.baseUrl,
        privkey: id.sk,
        pubkey: id.pk,
        payload: payload,
      );

  Future<Map<String, dynamic>?> authFor(String action,
      [String? payload]) async {
    final id = identity;
    if (id == null) return null;
    return _authFor(action, id, payload);
  }

  Map<String, dynamic> zapRequest({
    required int amountSats,
    required String comment,
    required String recipientPubkey,
    required List<String> relays,
  }) {
    final id = identity;
    if (id == null) throw AnonBotException('No anonymous key.');
    return finalizeEvent(
      UnsignedEvent(
        pubkey: id.pk,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 9734,
        tags: [
          ['p', recipientPubkey],
          ['amount', '${amountSats * 1000}'],
          ['relays', ...relays.take(5)],
          ['k', '0'],
        ],
        content: comment,
      ),
      id.sk,
    ).toJson();
  }

  Future<Map<String, dynamic>> keyset({bool force = false}) async {
    final cached = _keyset;
    if (cached != null && !force) return cached;
    final data = await _service.voucherKeys();
    final pinned = verifiedVoucherKeyset(data);
    if (pinned == null) {
      throw AnonBotException('Voucher keys unavailable.');
    }
    _keyset = pinned;
    return pinned;
  }

  static Map<String, dynamic>? verifiedVoucherKeyset(
      Map<String, dynamic> data) {
    final keys = data['keys'];
    final id = data['keysetId'];
    final rawDenoms = data['denoms'];
    if (keys is! Map || id is! String || id.isEmpty) return null;
    final denoms = rawDenoms == null
        ? voucherDenoms
        : rawDenoms is List && rawDenoms.every((d) => d is int && d > 0)
            ? rawDenoms.cast<int>().toList()
            : null;
    if (denoms == null || denoms.isEmpty) return null;
    final computed = voucherKeysetId(keys, denoms);
    if (computed == null || computed != id.toLowerCase()) return null;
    return <String, dynamic>{
      'keysetId': computed,
      'denoms': denoms,
      'keys': <String, Map<String, String>>{
        for (final tier in voucherTiers)
          tier: <String, String>{
            for (final d in denoms) '$d': (keys[tier] as Map)['$d'] as String,
          },
      },
    };
  }

  String? keysetId() => _keyset?['keysetId'] as String?;

  List<AnonVoucherToken> tokensFor(String tier) =>
      (_state?.tokens ?? const <AnonVoucherToken>[])
          .where((t) => t.tier == tier)
          .toList();

  Future<int> moveCredits(int amount, String tier) async {
    if (amount <= 0) throw AnonBotException('Enter how many credits to move.');
    final denoms = voucherSplitAmount(amount);
    if (denoms == null) {
      throw AnonBotException(
          'That amount needs too many vouchers — move a smaller amount.');
    }
    final id = ensureIdentity();
    if (id == null) {
      throw AnonBotException('Anonymous Nymbot chat is unavailable right now.');
    }
    await keyset();
    final st = _state!;
    if (st.pending != null) await _wrapIssue(st.pending!);
    st.pending = AnonVoucherRequest(
      tier: tier,
      reqId: bytesToHex(randomBytes(32)),
      outputs: _blindOutputs(denoms),
    );
    _save();
    await _wrapIssue(st.pending!);
    var credited = 0;
    while (tokensFor(tier).isNotEmpty) {
      credited += await _wrapRedeem(tier);
    }
    requestSync?.call();
    return credited;
  }

  Future<void> flush() async {
    if (_flushing || !ready || _accountPubkey == null) return;
    final st = _state;
    if (st == null) return;
    if (st.pending == null && st.tokens.isEmpty) return;
    _flushing = true;
    try {
      if (st.pending != null) await _finishIssue(st.pending!);
      for (final tier in const ['standard', 'pro']) {
        while (tokensFor(tier).isNotEmpty) {
          await _redeem(tier);
        }
      }
    } catch (_) {
    } finally {
      _flushing = false;
    }
  }

  Future<void> _wrapIssue(AnonVoucherRequest pending) async {
    try {
      await _finishIssue(pending);
    } on NymbotException catch (e) {
      throw AnonBotException(e.message);
    }
  }

  Future<int> _wrapRedeem(String tier) async {
    try {
      return await _redeem(tier);
    } on NymbotException catch (e) {
      throw AnonBotException(e.message);
    }
  }

  String? _accountPubkey;
  Future<Map<String, dynamic>?> Function(String action, [String? payload])?
      _accountAuth;

  void bindAccount(
      String pubkey,
      Future<Map<String, dynamic>?> Function(String action, [String? payload])?
          auth) {
    _accountPubkey = pubkey;
    _accountAuth = auth;
  }

  Future<List<AnonVoucherToken>> _finishIssue(AnonVoucherRequest pending) async {
    final from = pending.from;
    final signer = from == null ? null : identityForWrap(from);
    if (from != null && signer == null) {
      _state?.pending = null;
      _save();
      throw AnonBotException(
          'The anonymous key that owned these credits is gone.');
    }
    final account = _accountPubkey;
    if (signer == null && account == null) {
      throw AnonBotException('Not signed in.');
    }
    final ks = await keyset();
    Map<String, dynamic> data;
    try {
      data = await _service.voucherIssue(
        pubkey: signer?.pk ?? account!,
        tier: pending.tier,
        reqId: pending.reqId,
        outputs: pending.outputs.map((o) => o.toWire()).toList(),
        signedFor: (payload) async => signer != null
            ? _authFor('voucher-issue', signer, payload)
            : _accountAuth?.call('voucher-issue', payload),
        anon: signer != null,
      );
    } on NymbotException catch (e) {
      final code = e.statusCode ?? 0;
      if (code >= 400 && code < 500) {
        _state?.pending = null;
        _save();
      }
      rethrow;
    }
    if (data['insufficient'] == true) {
      _state?.pending = null;
      _save();
      final balance = (data['balance'] as num?)?.toInt() ?? 0;
      final required = (data['required'] as num?)?.toInt() ?? 0;
      throw AnonBotException(
        'Not enough ${pending.tier == 'pro' ? 'Pro ' : ''}credits on '
        '${signer != null ? 'your old anonymous key' : 'your nym'} — '
        '$balance left, $required needed.',
        insufficient: true,
      );
    }
    final sigs = data['signatures'];
    if (sigs is! List || sigs.length != pending.outputs.length) {
      throw AnonBotException('Voucher response did not match the request.');
    }
    final tierKeys = (ks['keys'] as Map)[pending.tier];
    final minted = <AnonVoucherToken>[];
    for (var i = 0; i < sigs.length; i++) {
      final out = pending.outputs[i];
      final sig = sigs[i];
      if (sig is! Map) throw AnonBotException('Malformed voucher signature.');
      if ((sig['d'] as num?)?.toInt() != out.d) {
        throw AnonBotException('Voucher denomination mismatch.');
      }
      final keyHex = tierKeys is Map ? tierKeys['${out.d}'] : null;
      if (keyHex is! String) {
        throw AnonBotException('Unknown voucher denomination.');
      }
      final c = sig['C'], e = sig['e'], s = sig['s'];
      if (c is! String || e is! String || s is! String) {
        throw AnonBotException('Malformed voucher signature.');
      }
      if (!voucherVerifyDleq(
          keyHex: keyHex, blindedHex: out.b, signatureHex: c, e: e, s: s)) {
        throw AnonBotException(
            'Nymbot returned a voucher signature it could not prove — refusing '
            'it, since an unprovable signature can be used to tag you. Nothing '
            'was spent anonymously.');
      }
      final unblinded = voucherUnblind(
        voucherPointFromHex(c),
        voucherPointFromHex(keyHex),
        BigInt.parse(out.r, radix: 16),
      );
      minted.add(AnonVoucherToken(
        d: out.d,
        x: out.x,
        c: voucherPointHex(unblinded),
        tier: pending.tier,
      ));
    }
    final st = _state!;
    st.tokens.addAll(minted);
    st.pending = null;
    _save();
    return minted;
  }

  Future<int> _redeem(String tier) async {
    final id = identity;
    final st = _state;
    if (id == null || st == null) return 0;
    final tokens = tokensFor(tier);
    if (tokens.isEmpty) return 0;
    final claimed = tokens.where((t) => t.redeemId != null).toList();
    late String redeemId;
    late List<AnonVoucherToken> batch;
    if (claimed.isNotEmpty) {
      redeemId = claimed.first.redeemId!;
      batch = tokens
          .where((t) => t.redeemId == redeemId)
          .take(voucherMaxOutputs)
          .toList();
    } else {
      redeemId = bytesToHex(randomBytes(32));
      batch = tokens.take(voucherMaxOutputs).toList();
      for (final t in batch) {
        t.redeemId = redeemId;
      }
      _save();
    }
    Map<String, dynamic> data;
    try {
      data = await _service.voucherRedeem(
        pubkey: id.pk,
        tier: tier,
        redeemId: redeemId,
        tokens: batch.map((t) => t.toWire()).toList(),
        auth: () async => _authFor('voucher-redeem', id),
      );
    } on NymbotException catch (e) {
      if (e.message.toLowerCase().contains('already redeemed')) {
        _dropTokens(batch);
      }
      rethrow;
    }
    _dropTokens(batch);
    return (data['credited'] as num?)?.toInt() ?? 0;
  }

  void _dropTokens(List<AnonVoucherToken> batch) {
    final st = _state;
    if (st == null) return;
    final gone = batch.map((t) => t.x).toSet();
    st.tokens = st.tokens.where((t) => !gone.contains(t.x)).toList();
    _save();
  }

  Map<String, dynamic>? syncPayload() {
    final st = _state;
    if (st == null || st.current == null || syncHeld) return null;
    return st.toJson();
  }

  void _save() {
    final st = _state;
    final write = persist;
    if (st == null || write == null) return;
    try {
      write(jsonEncode(st.toLocalJson()));
    } catch (_) {
    }
  }
}
