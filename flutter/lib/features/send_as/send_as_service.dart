import 'dart:async';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/event_kinds.dart';
import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../core/crypto/keys.dart' as keys;
import '../../core/utils/nym_utils.dart';
import '../../models/nostr_event.dart';
import '../../services/api/api_client.dart';
import '../../services/api/storage_sync.dart';
import '../../services/attest/attest_service.dart';
import '../../services/nostr/event_signer.dart';
import '../../services/nostr/nostr_service.dart';
import '../../services/storage/key_value_store.dart';
import '../accounts/account_host.dart';
import '../accounts/account_logic.dart';
import '../composer/send_as_model.dart';
import '../identity/remote_panic.dart';
import '../identity/remote_panic_logic.dart';
import 'send_as_stash.dart';
import 'send_as_transport.dart';

class SendAsResult {
  const SendAsResult.refused([this.reason = '', this.label = ''])
      : status = 'refused',
        placeholder = '',
        eventId = '',
        message = '';

  const SendAsResult.sent(this.label, this.eventId)
      : status = 'sent',
        reason = '',
        placeholder = '',
        message = '';

  const SendAsResult.failed(this.label, this.placeholder, this.message)
      : status = 'failed',
        reason = SendAsStrings.failed,
        eventId = '';

  final String status;
  final String reason;
  final String label;
  final String placeholder;
  final String eventId;
  final String message;

  bool get ok => status == 'sent';
}

class SendAsSender {
  SendAsSender({
    required this.entry,
    required this.stash,
    required this.signer,
  });

  final AccountEntry entry;
  final SendAsStash stash;
  final LocalSigner signer;

  String get id => entry.id;

  String get pubkey => entry.pubkey;

  String get nym => stash.nym;

  String get label =>
      '${stripPubkeySuffix(nym).isEmpty ? 'nym' : stripPubkeySuffix(nym)}'
      '#${getPubkeySuffix(pubkey)}';

  int get powDifficulty => stash.powDifficulty;

  void wipe() {
    try {
      signer.privkey.fillRange(0, signer.privkey.length, 0);
    } catch (_) {}
  }
}

class _Lane {
  _Lane(this.transport, this.pubkey);

  SendAsTransport transport;
  final String pubkey;
  Timer? idle;
  Future<void> tail = Future<void>.value();
}

class SendAsService {
  SendAsService({
    required this.accounts,
    required this.prefs,
    required this.direct,
    SendAsTransportFactory? transport,
    AttestService Function(KeyValueStore kv)? attest,
    ApiClient Function()? api,
    this.idle = const Duration(seconds: 60),
    this.badgeWait = const Duration(seconds: 8),
    this.budget = const Duration(seconds: 20),
    this.panicEvery = const Duration(minutes: 5),
    this.presenceEvery = const Duration(seconds: 60),
    int Function()? nowMs,
  })  : _transport = transport ?? _defaultTransport,
        _attest = attest ?? ((kv) => AttestService(kv: kv)),
        _api = api ?? ApiClient.new,
        _nowMs = nowMs ?? _wallMs;

  static SendAsTransport _defaultTransport(
          bool direct, List<String> blocked) =>
      PoolSendAsTransport(direct: direct, blocked: blocked);

  static int _wallMs() => DateTime.now().millisecondsSinceEpoch;

  final AccountsController? Function() accounts;
  final Future<SharedPreferences?> Function() prefs;
  final bool Function() direct;
  final SendAsTransportFactory _transport;
  final AttestService Function(KeyValueStore kv) _attest;
  final ApiClient Function() _api;
  final Duration idle;
  final Duration badgeWait;
  final Duration budget;
  final Duration panicEvery;
  final Duration presenceEvery;
  final int Function() _nowMs;

  final Map<String, _Lane> _lanes = {};
  final Map<String, int> _panicCheckedAt = {};
  final Map<String, int> _presenceAt = {};
  bool _closed = false;
  int inFlight = 0;

  Future<SharedPreferences?> _prefs() async {
    try {
      return await prefs();
    } catch (_) {
      return null;
    }
  }

  Future<List<SendAsAccount>> probe() async {
    final api = accounts();
    final p = await _prefs();
    if (api == null || p == null) return const [];
    final index = api.changes.value;
    final out = <SendAsAccount>[];
    for (final a in index.accounts) {
      final stash = SendAsStash(a, StashKeyValueStore(p, a.id).getString);
      if (a.id == index.active) {
        out.add(SendAsAccount(id: a.id, pubkey: a.pubkey, method: a.method));
        continue;
      }
      String? secret;
      if (a.pubkey.length == 64 &&
          (a.method == 'nsec' || a.method == 'ephemeral')) {
        try {
          secret = await api.storedSecret(a.id, sendAsSecretKey(a.method));
        } catch (_) {
          secret = null;
        }
      }
      out.add(stash.account(secret));
    }
    return out;
  }

  Future<SendAsSender?> resolve(String accountId) async {
    final api = accounts();
    final p = await _prefs();
    if (api == null || p == null) return null;
    final index = api.changes.value;
    final entry = index.byId(accountId);
    if (entry == null || entry.id == index.active) return null;
    if (entry.method != 'nsec' && entry.method != 'ephemeral') return null;
    final stash = SendAsStash(entry, StashKeyValueStore(p, entry.id).getString);
    if (entry.method == 'ephemeral' &&
        isThrowawayKeypairMode(stash.keypairMode)) {
      return null;
    }
    if (stash.vaultOn) return null;
    String? secret;
    try {
      secret = await api.storedSecret(entry.id, sendAsSecretKey(entry.method));
    } catch (_) {
      return null;
    }
    if (secret == null || !secret.startsWith('nsec1')) return null;
    Uint8List sk;
    try {
      sk = bech32.decodeNsec(secret);
    } catch (_) {
      return null;
    }
    if (keys.getPublicKeyHex(sk) != entry.pubkey) {
      sk.fillRange(0, sk.length, 0);
      return null;
    }
    return SendAsSender(entry: entry, stash: stash, signer: LocalSigner(sk));
  }

  bool stillListed(SendAsSender s) {
    final index = accounts()?.changes.value;
    if (index == null || index.active == s.id) return false;
    final e = index.byId(s.id);
    return e != null && e.pubkey == s.pubkey;
  }

  Future<String?> badgeFor(SendAsSender s) async {
    final p = await _prefs();
    if (p == null) return null;
    final attest = _attest(StashKeyValueStore(p, s.id));
    try {
      attest.restore(s.pubkey);
      await attest.ensureBadge(s.signer).timeout(badgeWait, onTimeout: () {});
    } catch (_) {}
    return attest.restore(s.pubkey) ? attest.badge : null;
  }

  Future<String?> panicVerdict(SendAsSender s) async {
    final now = _nowMs();
    final last = _panicCheckedAt[s.id];
    if (last != null && now - last < panicEvery.inMilliseconds) return null;
    Map<String, dynamic>? row;
    final api = _api();
    try {
      final auth = await Nip98Auth.buildSigned(
        action: 'panic-check',
        url: StorageSync.storageUrl(),
        signer: s.signer,
      );
      final res = await api.storageAction({
        'action': 'panic-check',
        'pubkey': s.pubkey,
        'auth': auth,
      }, socket: false);
      final mark = res['mark'];
      row = mark is Map ? Map<String, dynamic>.from(mark) : null;
    } catch (_) {
      return null;
    } finally {
      try {
        api.dispose();
      } catch (_) {}
    }
    _panicCheckedAt[s.id] = now;
    final verdict = RemotePanic.decide(
      enabled: s.stash.remotePanicOn,
      loginAt: s.stash.panicLoginAt,
      now: now ~/ 1000,
      pubkey: s.pubkey,
      marker: RemotePanic.fromRow(s.pubkey, row),
      verify: RemotePanicSignals.verify,
    );
    if (!verdict.wipe) return null;
    _panicCheckedAt.remove(s.id);
    return verdict.reason;
  }

  _Lane _lane(SendAsSender s) {
    final existing = _lanes[s.id];
    if (existing != null && existing.pubkey == s.pubkey) {
      existing.idle?.cancel();
      return existing;
    }
    if (existing != null) {
      _lanes.remove(s.id);
      unawaited(existing.transport.close());
    }
    final lane = _Lane(_transport(direct(), s.stash.blockedRelays), s.pubkey);
    _lanes[s.id] = lane;
    return lane;
  }

  void _armIdle(String id, _Lane lane) {
    lane.idle?.cancel();
    lane.idle = Timer(idle, () {
      if (_lanes[id] != lane) return;
      _lanes.remove(id);
      unawaited(lane.transport.close());
    });
  }

  Future<T> _serial<T>(SendAsSender s, Future<T> Function(_Lane lane) job) {
    final lane = _lane(s);
    final done = Completer<T>();
    final prev = lane.tail;
    lane.tail = done.future.then((_) {}, onError: (_) {});
    unawaited(prev.then((_) async {
      try {
        done.complete(await job(lane));
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        if (_lanes[s.id] == lane) _armIdle(s.id, lane);
      }
    }));
    return done.future;
  }

  Future<SendAsOk> publish(SendAsSender s, NostrEvent event,
      {List<String> geoRelays = const []}) {
    if (_closed) return Future.value(const SendAsOk(false, retryable: true));
    inFlight++;
    return _serial<SendAsOk>(s, (lane) async {
      final started = _nowMs();
      var attempt = 0;
      var result = const SendAsOk(false, retryable: true);
      while (attempt < 3 && !_closed) {
        attempt++;
        result = await lane.transport.publish(event, geoRelays: geoRelays);
        if (result.accepted || !result.retryable || _closed) break;
        if (_nowMs() - started >= budget.inMilliseconds) break;
        final old = lane.transport;
        lane.transport = _transport(direct(), s.stash.blockedRelays);
        unawaited(old.close());
      }
      return result;
    }).whenComplete(() => inFlight--);
  }

  Future<void> publishPlain(SendAsSender s, NostrEvent event) {
    if (_closed) return Future.value();
    return _serial<void>(s, (lane) => lane.transport.publishPlain(event));
  }

  Future<void> presence(SendAsSender s) async {
    final stash = s.stash;
    final mode = stash.statusMode;
    if (mode == PresenceStatusMode.disabled || stash.away) return;
    final now = _nowMs();
    final last = _presenceAt[s.id];
    if (last != null && now - last < presenceEvery.inMilliseconds) return;
    _presenceAt[s.id] = now;
    final signed = await s.signer.sign(UnsignedEvent(
      pubkey: s.pubkey,
      createdAt: now ~/ 1000,
      kind: EventKind.appData,
      tags: PresencePayload(
        nym: s.nym,
        status: 'online',
        mode: mode,
        avatarUrl: stash.avatar,
      ).tags(),
      content: '',
    ));
    await publishPlain(s, signed);
  }

  Future<Map<String, dynamic>> botAction(Map<String, dynamic> body) async {
    final api = _api();
    try {
      return await api.botAction(body);
    } finally {
      try {
        api.dispose();
      } catch (_) {}
    }
  }

  Future<void> settle(Duration within) async {
    final deadline = _nowMs() + within.inMilliseconds;
    while (inFlight > 0 && _nowMs() < deadline) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> closeAll() async {
    _closed = true;
    final lanes = _lanes.values.toList();
    _lanes.clear();
    for (final l in lanes) {
      l.idle?.cancel();
      try {
        await l.transport.close();
      } catch (_) {}
    }
    _presenceAt.clear();
    _panicCheckedAt.clear();
  }
}

({List<Map<String, dynamic>> messages, List<Map<String, dynamic>> users})
    sendAsScrubContext({
  required List<Map<String, dynamic>> messages,
  required List<Map<String, dynamic>> users,
  required String activePubkey,
}) {
  final active = activePubkey.toLowerCase();
  final kept = <Map<String, dynamic>>[];
  var activePosted = false;
  for (final m in messages) {
    if (m['pending'] == true) continue;
    final copy = Map<String, dynamic>.of(m)..remove('pending');
    if ('${copy['pubkey'] ?? ''}'.toLowerCase() == active) activePosted = true;
    kept.add(copy);
  }
  final outUsers = <Map<String, dynamic>>[
    for (final u in users)
      if (activePosted || '${u['pubkey'] ?? ''}'.toLowerCase() != active)
        Map<String, dynamic>.of(u),
  ];
  return (messages: kept, users: outUsers);
}
