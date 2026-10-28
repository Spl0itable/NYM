import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/event_kinds.dart';
import '../../core/constants/relays.dart';
import '../../core/constants/storage_keys.dart';
import '../../core/crypto/bech32_codec.dart';
import '../../core/crypto/gift_wrap.dart' as giftwrap;
import '../../core/crypto/pq.dart' as pq;
import '../../models/message.dart' show Message;
import '../../models/nostr_event.dart';
import '../../services/api/api_config.dart';
import '../../services/api/d1_cursor.dart';
import '../../services/filter/content_filter.dart';
import '../../services/filter/filter_packs.dart';
import '../../services/relay/relay_message.dart';
import '../../services/relay/relay_pool.dart';
import '../../services/relay/relay_pool_proxy.dart';
import '../../services/storage/at_rest_cipher.dart';
import '../../services/storage/secure_store.dart';
import '../group_tools/group_tools_service.dart' show GroupToolsKeys;
import '../messages/spam_filter.dart';
import '../identity/pq_registry.dart';
import '../identity/pq_root.dart';
import '../relays/relay_block.dart';
import 'account_logic.dart';
import '../nymbot/standalone_nymbot.dart';
import '../../state/app_state.dart' show kNymbotPubkey;

typedef ProbeTransportFactory = PoolTransport Function(
    bool direct, List<String> relays);

typedef ProbeHttpFactory = http.Client Function();

typedef ProbeInbox = ({List<NostrEvent> wraps, List<String> known, String? cursor});

class InactiveProbe {
  InactiveProbe({
    required this.prefs,
    ProbeTransportFactory? transport,
    this.window = const Duration(seconds: 8),
    int Function()? nowSec,
    Duration Function()? stagger,
    ProbeHttpFactory? http,
    this.secretOf,
    this.rootOf,
    this.unseal,
    this.secure,
  })  : _transport = transport ?? _defaultTransport,
        _nowSec = nowSec ?? _wallSec,
        _stagger = stagger ?? defaultStagger,
        _http = http ?? _defaultHttp;

  static final Random _rng = Random();

  static Duration defaultStagger() =>
      Duration(milliseconds: 1000 + _rng.nextInt(11000));

  static const String seenKey = 'nym_probe_seen';
  static const String sinceKey = 'nym_probe_since';
  static const String cursorKey = 'nym_probe_d1';
  static const String legacyCursorKey = 'nym_probe_cursor';
  static const int wrapSkewSec = 2 * 24 * 60 * 60;
  static const int seenCap = 500;

  final SharedPreferences prefs;
  final Future<String?> Function(String id)? secretOf;
  final Future<String?> Function(String id)? rootOf;
  final Future<String?> Function(String raw)? unseal;
  final SecureStore? secure;
  bool Function(String pubkey)? muted;
  Future<void> Function(AccountEntry a, int n)? onLocked;
  final ProbeTransportFactory _transport;
  final Duration window;
  final int Function() _nowSec;
  final Duration Function() _stagger;
  final ProbeHttpFactory _http;

  static http.Client _defaultHttp() => http.Client();

  static String storageUrl() => 'https://${ApiConfig.apiHost}/api/storage';

  static int _wallSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static PoolTransport _defaultTransport(bool direct, List<String> relays) =>
      direct
          ? RelayPool(
              relays: relays,
              writeOnlyRelays: RelayConfig.writeOnlyRelays,
            )
          : RelayPoolProxy(
              relays: relays,
              dmRelays: relays,
            );

  List<String> relaysFor(String id) {
    Object? raw;
    try {
      final s =
          prefs.getString(AccountLogic.nsKey(id, StorageKeys.blockedRelays));
      if (s != null && s.isNotEmpty) raw = jsonDecode(s);
    } catch (_) {
      raw = null;
    }
    final blocked = RelayBlock.list(
        RelayBlock.norm(raw, DateTime.now().millisecondsSinceEpoch));
    return RelayBlock.usable(RelayConfig.defaultRelays, blocked);
  }

  bool get directMode => prefs.getString('nym_relay_direct_mode') == 'true';

  List<String> _seenOf(String id) {
    try {
      final raw = prefs.getString(AccountLogic.nsKey(id, seenKey));
      if (raw == null) return <String>[];
      return [for (final e in jsonDecode(raw) as List) '$e'];
    } catch (_) {
      return <String>[];
    }
  }

  Future<bool> noteSeen(String id, String wrapId) async {
    final seen = _seenOf(id);
    if (seen.contains(wrapId)) return false;
    seen.add(wrapId);
    final kept =
        seen.length > seenCap ? seen.sublist(seen.length - seenCap) : seen;
    await prefs.setString(AccountLogic.nsKey(id, seenKey), jsonEncode(kept));
    return true;
  }

  Future<void> baseline(String id, List<String> seen) async {
    final kept =
        seen.length > seenCap ? seen.sublist(seen.length - seenCap) : seen;
    await prefs.setString(AccountLogic.nsKey(id, seenKey), jsonEncode(kept));
    await prefs.setString(AccountLogic.nsKey(id, sinceKey), '${_nowSec()}');
    await prefs.remove(AccountLogic.nsKey(id, cursorKey));
    await prefs.remove(AccountLogic.nsKey(id, legacyCursorKey));
  }

  Future<int> probe(AccountEntry a) async {
    if (a.pubkey.length != 64 || a.method == 'anonymous') return 0;
    final sinceRaw = prefs.getString(AccountLogic.nsKey(a.id, sinceKey));
    final since = int.tryParse(sinceRaw ?? '');
    final seen = <String>[];
    try {
      final raw = prefs.getString(AccountLogic.nsKey(a.id, seenKey));
      if (raw != null) {
        for (final id in jsonDecode(raw) as List) {
          seen.add('$id');
        }
      }
    } catch (_) {}
    await Future<void>.delayed(_stagger());
    final now = _nowSec();
    final direct = directMode;
    final found = <NostrEvent>[];
    final already = <String>[];
    String? cursor;
    if (!direct && ApiConfig.apiHost.isNotEmpty) {
      final prev = prefs.getString(AccountLogic.nsKey(a.id, cursorKey));
      final legacy = prefs.getString(AccountLogic.nsKey(a.id, legacyCursorKey));
      final got = await _inbox(a.pubkey, prev, legacy, since, now);
      if (got == null) return 0;
      found.addAll(got.wraps);
      already.addAll(got.known);
      cursor = D1Cursor.newer(prev, got.cursor);
    } else {
      await _relays(a, direct, since ?? now, found);
    }
    final latest = _seenOf(a.id);
    final known = {...seen, ...latest};
    final freshWraps = <NostrEvent>[];
    final freshIds = <String>{};
    for (final e in found) {
      if (known.contains(e.id) || !freshIds.add(e.id)) continue;
      freshWraps.add(e);
    }
    final fresh = freshIds.toList();
    var shown = 0;
    var locked = 0;
    if (since != null && freshWraps.isNotEmpty) {
      final judge = await _judge(a);
      try {
        if (judge != null && judge.locked) {
          locked = freshWraps.length;
        } else {
          for (final w in freshWraps) {
            if (judge == null || !await judge.hidden(w)) shown++;
          }
        }
      } finally {
        judge?.dispose();
      }
    }
    final counted = {...known, ...fresh};
    final merged = [
      ...known,
      ...fresh,
      ...{
        for (final id in already)
          if (!counted.contains(id)) id,
      },
    ];
    final kept = merged.length > seenCap
        ? merged.sublist(merged.length - seenCap)
        : merged;
    await prefs.setString(AccountLogic.nsKey(a.id, seenKey), jsonEncode(kept));
    await prefs.setString(AccountLogic.nsKey(a.id, sinceKey), '$now');
    if (cursor != null) {
      await prefs.setString(AccountLogic.nsKey(a.id, cursorKey), cursor);
      await prefs.remove(AccountLogic.nsKey(a.id, legacyCursorKey));
    }
    if (since != null && locked > 0) await onLocked?.call(a, locked);
    return since == null ? 0 : shown;
  }

  List<String> _storedList(String id, String key) {
    try {
      final raw = prefs.getString(AccountLogic.nsKey(id, key));
      if (raw == null || raw.isEmpty) return const [];
      final v = jsonDecode(raw);
      return v is List ? [for (final e in v) '$e'] : const [];
    } catch (_) {
      return const [];
    }
  }

  String? _storedPref(String id, String key) =>
      prefs.getString(AccountLogic.nsKey(id, key));

  Future<bool> wrapHidden(AccountEntry a, NostrEvent wrap) async {
    final judge = await _judge(a);
    if (judge == null) return false;
    try {
      if (judge.locked) {
        await onLocked?.call(a, 1);
        return true;
      }
      return await judge.hidden(wrap);
    } finally {
      judge.dispose();
    }
  }

  bool? _storedFlag(String id, String key) {
    final v = prefs.get(AccountLogic.nsKey(id, key));
    if (v is bool) return v;
    if (v is String) {
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    return null;
  }

  Future<String?> _unsealFor(AccountEntry a, String raw) {
    final hook = unseal;
    if (hook != null) return hook(raw);
    return AtRestCipher(_OwnAtRestKey(secure ?? SecureStore(),
            AccountLogic.nsKey(a.id, SecureAtRestKeyStore.keyName)))
        .decryptString(raw);
  }

  Future<Set<String>> _groupsOf(AccountEntry a) async {
    final out = <String>{};
    Future<void> add(String key) async {
      String? raw = _storedPref(a.id, key);
      if (raw == null || raw.isEmpty) return;
      if (AtRestCipher.isEncryptedString(raw)) {
        try {
          raw = await _unsealFor(a, raw);
        } catch (_) {
          raw = null;
        }
        if (raw == null || raw.isEmpty) return;
      }
      try {
        final v = jsonDecode(raw);
        if (v is Map) out.addAll(v.keys.map((k) => '$k'));
      } catch (_) {}
    }

    await add(StorageKeys.groupStoreFor(a.pubkey));
    await add('${GroupToolsKeys.pendingJoins}:${a.pubkey}');
    return out;
  }

  Future<_WrapJudge?> _judge(AccountEntry a) async {
    final blocked = _storedList(a.id, StorageKeys.blocked);
    final keywords = _storedList(a.id, StorageKeys.blockedKeywords);
    final friends = _storedList(a.id, StorageKeys.friends).toSet();
    final blockedChannels = _storedList(a.id, StorageKeys.blockedChannels);
    final packs = [
      for (final id in _storedList(a.id, StorageKeys.filterPacks))
        if (kFilterPackIds.contains(id)) id,
    ];
    final friendsOnly =
        _storedPref(a.id, StorageKeys.notifyFriendsOnly) == 'true';
    final accept = _storedPref(a.id, StorageKeys.acceptPms) ?? 'enabled';
    final spamOn = _storedFlag(a.id, StorageKeys.spamFilterEnabled) != false;
    final spamAggressive =
        _storedFlag(a.id, StorageKeys.spamFilterAggressive) != false;
    final mutedOf = muted;
    final userFilters = blocked.isNotEmpty ||
        keywords.any((k) => k.trim().isNotEmpty) ||
        friendsOnly ||
        accept != 'enabled' ||
        packs.isNotEmpty ||
        blockedChannels.isNotEmpty;
    final filtering = userFilters || spamOn || mutedOf != null;
    Uint8List? sk;
    final read = secretOf;
    final nsec = read == null ? null : await read(a.id);
    if (nsec != null && nsec.isNotEmpty) {
      try {
        sk = decodeNsec(nsec);
      } catch (_) {
        sk = null;
      }
    }
    if (sk != null && packs.isNotEmpty) await FilterPacks.ensureLoaded(packs);
    final ctx = ContentFilterCtx(
      self: a.pubkey,
      blockedUsers: blocked.toSet(),
      keywords: keywords,
      blockedChannels: blockedChannels,
      friendsOnly: friendsOnly,
      packs: packs.isNotEmpty,
      friend: friends.contains,
      pack: packs.isEmpty
          ? null
          : (text, nym) => FilterPacks.matchIn(packs, text, nym: nym) != null,
      muted: mutedOf,
      spam: (r) =>
          r is CfEntry &&
          SpamFilter.isSpamMessage(r.body,
              enabled: spamOn, aggressive: spamAggressive),
    );
    final key = sk;
    return _WrapJudge(
      account: a,
      sk: key,
      ctx: ctx,
      accept: accept,
      unopened: userFilters,
      filtering: filtering,
      kemKeys: key == null ? null : () => _kemKeys(a, key),
      groups: () => _groupsOf(a),
    );
  }

  Future<List<({Uint8List kemSk, Uint8List kemPk})>> _kemKeys(
      AccountEntry a, Uint8List sk) async {
    final epoch = int.tryParse(_storedPref(a.id, StorageKeys.pqEpoch) ?? '') ?? 0;
    Uint8List? root;
    final readRoot = rootOf;
    if (readRoot != null) {
      try {
        final code = PqRootStore.parse(await readRoot(a.id)).codeFor(a.pubkey);
        if (code != null) root = pqRootFromCode(code);
      } catch (_) {
        root = null;
      }
    }
    try {
      return pqSelfCandidates(sk, epoch < 0 ? 0 : epoch, root: root);
    } catch (_) {
      return const [];
    } finally {
      if (root != null) root.fillRange(0, root.length, 0);
    }
  }

  Future<void> _relays(
      AccountEntry a, bool direct, int sinceSec, List<NostrEvent> found) async {
    final pool = _transport(direct, relaysFor(a.id));
    try {
      pool.connectAll();
      final sub = pool.subscribe([
        NostrFilter(
          kinds: const [EventKind.giftWrap],
          since: sinceSec - wrapSkewSec,
          limit: 200,
          tags: {
            'p': [a.pubkey],
          },
        ),
      ]);
      final listen = sub.events.listen(found.add);
      try {
        await sub.eose.timeout(window);
      } catch (_) {}
      await listen.cancel();
      await sub.close();
    } catch (_) {
    } finally {
      try {
        await pool.disconnectAll();
      } catch (_) {}
    }
  }

  Future<ProbeInbox?> _inbox(String pubkey, String? prev, String? legacy,
      int? since, int now) async {
    final client = _http();
    try {
      if (D1Cursor.valid(prev)) {
        final got = await _after(client, pubkey, D1Cursor.startAfter(prev)!);
        if (got == null) return null;
        return (wraps: got.wraps, known: const <String>[], cursor: got.cursor);
      }
      final List<NostrEvent> wraps;
      final String? edgeFrom;
      if (D1Cursor.valid(legacy)) {
        final got = await _after(client, pubkey, legacy!);
        if (got == null) return null;
        wraps = got.wraps;
        edgeFrom = D1Cursor.newer(legacy, got.cursor);
      } else {
        final r = await _read(client, pubkey, {
          'since': since == null ? now : since - wrapSkewSec,
          'limit': since == null ? 1 : D1Cursor.pageLimit,
        });
        if (r == null) return null;
        wraps = r.wraps;
        edgeFrom = D1Cursor.fromHead(r.headers['x-cursor-head']);
      }
      final edge = edgeFrom == null
          ? null
          : await _after(client, pubkey, D1Cursor.startAfter(edgeFrom)!);
      if (edge == null) {
        return (wraps: wraps, known: const <String>[], cursor: null);
      }
      return (
        wraps: wraps,
        known: [for (final w in edge.wraps) w.id],
        cursor: D1Cursor.newer(edgeFrom, edge.cursor),
      );
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<({List<NostrEvent> wraps, String? cursor})?> _after(
      http.Client client, String pubkey, String from) async {
    final wraps = <NostrEvent>[];
    var after = from;
    String? best;
    for (var page = 0; page < D1Cursor.maxPages; page++) {
      final r = await _read(
          client, pubkey, {'after': after, 'limit': D1Cursor.pageLimit});
      if (r == null) return null;
      final step = D1Cursor.step(
          page, after, r.headers['x-cursor'], r.headers['x-has-more']);
      if (!step.serverOk) break;
      wraps.addAll(r.wraps);
      best = D1Cursor.newer(best, step.cursor);
      final next = step.next;
      if (next == null) break;
      after = next;
    }
    return (wraps: wraps, cursor: best);
  }

  Future<({List<NostrEvent> wraps, Map<String, String> headers})?> _read(
      http.Client client, String pubkey, Map<String, Object> extra) async {
    final res = await client.post(
      Uri.parse(storageUrl()),
      headers: {
        ...ApiConfig.defaultHeaders,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'action': 'pm-get',
        'pubkeys': [pubkey],
        ...extra,
      }),
    );
    final type = res.headers['content-type'] ?? '';
    if (res.statusCode < 200 ||
        res.statusCode >= 300 ||
        !type.contains('application/x-ndjson')) {
      return null;
    }
    final wraps = <NostrEvent>[];
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      try {
        final ev = jsonDecode(line);
        if (ev is Map &&
            ev['kind'] == EventKind.giftWrap &&
            ev['id'] is String &&
            _hex64.hasMatch(ev['id'] as String)) {
          wraps.add(NostrEvent.fromJson(Map<String, dynamic>.from(ev)));
        }
      } catch (_) {}
    }
    return (
      wraps: wraps,
      headers: {
        for (final e in res.headers.entries) e.key.toLowerCase(): e.value,
      },
    );
  }

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
}

class _OwnAtRestKey implements AtRestKeyStore {
  _OwnAtRestKey(this._store, this._name);

  final SecureStore _store;
  final String _name;

  @override
  Future<String?> read() => _store.get(_name);

  @override
  Future<void> write(String value) async => throw const AtRestKeyUnavailable();

  @override
  Future<void> delete() async {}
}

class _WrapJudge {
  _WrapJudge({
    required this.account,
    required this.sk,
    required this.ctx,
    required this.accept,
    required this.unopened,
    required this.kemKeys,
    required this.groups,
    this.filtering = true,
  });

  final bool filtering;

  final AccountEntry account;
  final Uint8List? sk;
  final ContentFilterCtx ctx;
  final String accept;
  final bool unopened;
  final Future<List<({Uint8List kemSk, Uint8List kemPk})>> Function()? kemKeys;
  final Future<Set<String>> Function() groups;
  List<({Uint8List kemSk, Uint8List kemPk})>? _kem;
  Set<String>? _groups;

  bool get locked => sk == null && unopened;

  Future<bool> hidden(NostrEvent wrap) async {
    final key = sk;
    if (key == null) return unopened;
    try {
      final cands = <giftwrap.UnwrapCandidate>[];
      final kemOf = kemKeys;
      if (kemOf != null &&
          (pq.isPq2Payload(wrap.content) || pq.isPqPayload(wrap.content))) {
        final kem = _kem ??= await kemOf();
        for (final k in kem) {
          cands.add((sk: key, bitchat: false, kemSk: k.kemSk, kemPk: k.kemPk));
        }
      }
      cands.add(giftwrap.classicalCandidate(key, bitchat: true));
      final u = await giftwrap.unwrapGiftWrap(wrap, cands);
      if (u == null) return unopened;
      if (isStandaloneNymbotRunWrap(
        sealPubkey: u.seal.pubkey,
        sealKind: u.seal.kind,
        rumor: u.rumor,
        me: account.pubkey,
        botPubkey: kNymbotPubkey,
      )) {
        return true;
      }
      if (!filtering) return false;
      final sender = u.seal.pubkey;
      if (sender.isEmpty || sender == account.pubkey) return false;
      final raw = u.rumor['content'];
      final content = raw is String ? raw : '';
      final tags = u.rumor['tags'];
      String tag(String k) {
        if (tags is! List) return '';
        for (final t in tags) {
          if (t is List && t.length > 1 && t[0] == k && t[1] is String) {
            return t[1] as String;
          }
        }
        return '';
      }

      final gid = tag('g');
      var known = false;
      if (gid.isNotEmpty && accept != 'enabled') {
        known = (_groups ??= await groups()).contains(gid);
      }
      return ContentFilter.inboxHidden(
        ctx,
        CfEntry(
          sender: sender,
          body: content,
          channel: gid.isEmpty ? ContentFilter.inviteChannel(content) : '',
          subject: tag('type') == 'group-invite' ? tag('subject') : '',
          knownGroup: known,
          quoted: Message.quotedFromTags([
            if (tags is List)
              for (final t in tags)
                if (t is List && t.length > 1 && t[0] == 'quote_pk' && t[1] is String)
                  ['quote_pk', t[1] as String],
          ]),
        ),
        accept,
      );
    } catch (_) {
      return unopened;
    }
  }

  void dispose() {
    for (final k in _kem ?? const <({Uint8List kemSk, Uint8List kemPk})>[]) {
      k.kemSk.fillRange(0, k.kemSk.length, 0);
    }
    _kem = null;
    final key = sk;
    if (key != null) key.fillRange(0, key.length, 0);
  }
}
