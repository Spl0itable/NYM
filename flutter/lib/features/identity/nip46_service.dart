import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/constants/relays.dart';
import '../../core/constants/storage_keys.dart';
import '../../core/crypto/keys.dart';
import '../../core/crypto/nip44.dart' as nip44;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';
import '../../services/relay/relay_message.dart';
import '../../services/relay/relay_pool.dart';

/// NIP-46 remote signer transport: NIP-44 `{id, method, params}` RPC over kind 24133, with the session persisted for restore.

const int kNip46Kind = 24133;

/// RPC timeout; the remote signer may be prompting the user.
const Duration kNip46RequestTimeout = Duration(seconds: 60);

/// [SecureStore] subset, so tests can inject an in-memory fake.
abstract class Nip46SecureStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

/// [KeyValueStore] subset, so tests can inject an in-memory fake.
abstract class Nip46KeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
}

/// Text transport to the signer relay, fakeable in tests.
abstract class Nip46Socket {
  Stream<String> get messages;

  void send(String data);

  Future<void> close();
}

typedef Nip46SocketFactory = Nip46Socket Function(String relayUrl);

class _WebSocketNip46Socket implements Nip46Socket {
  _WebSocketNip46Socket(String relayUrl)
      : _channel = WebSocketChannel.connect(Uri.parse(relayUrl));

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages =>
      _channel.stream.where((e) => e is String).cast<String>();

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();
}

/// A socket that failed to open; keeps the service alive and logs the failure.
class _FailingNip46Socket implements Nip46Socket {
  _FailingNip46Socket(this.error);

  final Object error;

  @override
  Stream<String> get messages => const Stream.empty();

  @override
  void send(String data) {}

  @override
  Future<void> close() async {}
}

Nip46Socket _defaultSocketFactory(String relayUrl) {
  try {
    return _WebSocketNip46Socket(relayUrl);
  } catch (e) {
    debugPrint('[NIP46] Failed to open socket for $relayUrl: $e');
    return _FailingNip46Socket(e);
  }
}

/// Routes relays the pool already covers through it (proxy privacy, reconnect); other `bunker://` relays get a raw socket.
Nip46SocketFactory _makeDefaultFactory(
    PoolTransport? Function()? poolProvider) {
  return (relayUrl) {
    final pool = poolProvider?.call();
    if (pool != null &&
        RelayConfig.defaultRelays.contains(_canonicalRelayUrl(relayUrl))) {
      return _PoolNip46Socket(pool);
    }
    return _defaultSocketFactory(relayUrl);
  };
}

/// Trims and drops one trailing `/`, so Amber's `wss://relay.primal.net/` matches the pool instead of bypassing the proxy.
String _canonicalRelayUrl(String url) {
  final t = url.trim();
  return t.endsWith('/') ? t.substring(0, t.length - 1) : t;
}

/// Pool-backed socket translating REQ/EVENT/CLOSE frames to pool calls; the pool reconnects, so this closes only on [close].
class _PoolNip46Socket implements Nip46Socket {
  _PoolNip46Socket(this._pool);

  final PoolTransport _pool;
  final StreamController<String> _incoming =
      StreamController<String>.broadcast();
  final Map<String, Subscription> _subs = {};
  final Map<String, StreamSubscription<NostrEvent>> _streams = {};

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String data) {
    dynamic frame;
    try {
      frame = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (frame is! List || frame.isEmpty) return;
    switch (frame[0]) {
      case 'REQ':
        final subId = frame[1] as String;
        final filters = <NostrFilter>[
          for (var i = 2; i < frame.length; i++)
            NostrFilter.fromJson(Map<String, dynamic>.from(frame[i] as Map)),
        ];
        // Reuse the caller's subId so synthesized EVENT frames match `_subId`.
        final sub = _pool.subscribe(filters, subId: subId);
        _subs[subId] = sub;
        _streams[subId] = sub.events.listen((ev) {
          if (!_incoming.isClosed) {
            _incoming.add(jsonEncode(['EVENT', subId, ev.toJson()]));
          }
        });
        break;
      case 'CLOSE':
        final subId = frame[1] as String;
        unawaited(_streams.remove(subId)?.cancel());
        unawaited(_subs.remove(subId)?.close());
        break;
      case 'EVENT':
        final ev =
            NostrEvent.fromJson(Map<String, dynamic>.from(frame[1] as Map));
        // Broadcasting ephemeral 24133 to all relays is harmless; the signer reads its own, which is in the pool.
        unawaited(_pool.publish(ev));
        break;
    }
  }

  @override
  Future<void> close() async {
    for (final s in _streams.values) {
      await s.cancel();
    }
    for (final s in _subs.values) {
      await s.close();
    }
    _streams.clear();
    _subs.clear();
    if (!_incoming.isClosed) await _incoming.close();
  }
}

class Nip46ConnectionUri {
  Nip46ConnectionUri({
    required this.scheme,
    required this.pubkey,
    required this.relay,
    this.secret,
    this.metadataName,
  });

  /// `'nostrconnect'` (client pubkey) or `'bunker'` (remote signer pubkey).
  final String scheme;

  /// 64-hex client pubkey for `nostrconnect://`, remote signer pubkey for `bunker://`.
  final String pubkey;
  final String relay;
  final String? secret;
  final String? metadataName;

  bool get isBunker => scheme == 'bunker';
  bool get isNostrConnect => scheme == 'nostrconnect';
}

/// Connected remote signer; for `'nip46'` logins the publish path signs through [signEvent].
abstract class Nip46Signer {
  /// The user's pubkey from `get_public_key`, 64-char hex.
  String get pubkey;

  /// Asks the remote signer to sign [unsigned].
  Future<NostrEvent> signEvent(UnsignedEvent unsigned);

  Future<String> nip44Encrypt(String thirdPartyPubkey, String plaintext);

  Future<String> nip44Decrypt(String thirdPartyPubkey, String ciphertext);
}

class _Pending {
  _Pending(this.completer, this.timer);
  final Completer<dynamic> completer;
  final Timer timer;
}

/// A successful connect: user pubkey plus the live signer.
class Nip46ConnectResult {
  Nip46ConnectResult(this.userPubkey, this.signer);
  final String userPubkey;
  final Nip46Signer signer;
}

class Nip46Service implements Nip46Signer {
  Nip46Service({
    required Nip46KeyValueStore kv,
    required Nip46SecureStore secure,
    Nip46SocketFactory? socketFactory,
    PoolTransport? Function()? poolProvider,
    Duration requestTimeout = kNip46RequestTimeout,
  })  : _kv = kv,
        _secure = secure,
        // An injected factory wins; otherwise pool-backed when it covers the relay.
        _socketFactory = socketFactory ?? _makeDefaultFactory(poolProvider),
        _requestTimeout = requestTimeout;

  final Nip46KeyValueStore _kv;
  final Nip46SecureStore _secure;
  final Nip46SocketFactory _socketFactory;
  final Duration _requestTimeout;

  Uint8List? _clientSecretKey;
  String? _clientPubkey;
  String? _relayUrl;
  String? _secret;
  String? _remotePubkey;
  String? _userPubkey;
  bool _connected = false;

  Nip46Socket? _socket;
  StreamSubscription<String>? _socketSub;
  String _subId = '';

  /// Outstanding RPC requests by id.
  final Map<String, _Pending> _pendingRequests = {};

  /// Completes once the signer acknowledges `connect`.
  Completer<String>? _connectCompleter;

  final ValueNotifier<bool> bareAck = ValueNotifier<bool>(false);

  @override
  String get pubkey => _userPubkey ?? '';

  String? get clientPubkey => _clientPubkey;
  String? get remotePubkey => _remotePubkey;
  bool get isConnected => _connected;

  /// `nostrconnect://` URI for QR display, params in relay, metadata, secret order and form-encoded.
  static String buildNostrConnectUri({
    required String clientPubkey,
    required String relay,
    required String secret,
    String appName = 'Nymchat',
  }) {
    // '+'-encode spaces like URLSearchParams; metadata is `{"name":"<appName>"}`.
    final metadata = jsonEncode({'name': appName});
    final params = <String>[
      'relay=${_formEncode(relay)}',
      'metadata=${_formEncode(metadata)}',
      'secret=${_formEncode(secret)}',
    ].join('&');
    return 'nostrconnect://$clientPubkey?$params';
  }

  /// Parses a connection string; the host is the remote signer pubkey for `bunker://`, the client's for `nostrconnect://`.
  static Nip46ConnectionUri parseConnectionUri(String input) {
    final trimmed = input.trim();
    final schemeIdx = trimmed.indexOf('://');
    if (schemeIdx < 0) {
      throw FormatException('Not a NIP-46 URI: $input');
    }
    final scheme = trimmed.substring(0, schemeIdx);
    if (scheme != 'bunker' && scheme != 'nostrconnect') {
      throw FormatException('Unsupported scheme: $scheme');
    }
    final rest = trimmed.substring(schemeIdx + 3);
    final qIdx = rest.indexOf('?');
    final host = (qIdx < 0 ? rest : rest.substring(0, qIdx)).trim();
    final query = qIdx < 0 ? '' : rest.substring(qIdx + 1);

    if (host.length != 64) {
      // Pubkey must be 64-char hex; fail clearly now.
      throw FormatException('Invalid pubkey in NIP-46 URI: "$host"');
    }

    String? relay;
    String? secret;
    String? metadataName;
    for (final part in query.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final key = eq < 0 ? part : part.substring(0, eq);
      final rawVal = eq < 0 ? '' : part.substring(eq + 1);
      final value = _formDecode(rawVal);
      switch (key) {
        case 'relay':
          // First relay wins.
          relay ??= value;
          break;
        case 'secret':
          secret = value;
          break;
        case 'metadata':
          try {
            final m = jsonDecode(value);
            if (m is Map && m['name'] is String) {
              metadataName = m['name'] as String;
            }
          } catch (_) {/* ignore malformed metadata */}
          break;
      }
    }

    return Nip46ConnectionUri(
      scheme: scheme,
      pubkey: host.toLowerCase(),
      // Canonicalize so trailing-slash relays match the pool and persist consistently.
      relay: relay != null ? _canonicalRelayUrl(relay) : RelayConfig.nip46Relay,
      secret: secret,
      metadataName: metadataName,
    );
  }

  /// Generates a client keypair and secret, subscribes for the connect ack, and returns the URI; await [awaitConnect].
  String startNostrConnect({String relay = RelayConfig.nip46Relay}) {
    _clientSecretKey = generatePrivateKey();
    _clientPubkey = getPublicKeyHex(_clientSecretKey!);
    _relayUrl = relay;
    // 16 hex chars from 8 random bytes.
    _secret = bytesToHex(randomBytes(8));
    bareAck.value = false;
    _remotePubkey = null;
    _userPubkey = null;
    _connected = false;
    _connectCompleter = Completer<String>();

    _openRelay();

    return buildNostrConnectUri(
      clientPubkey: _clientPubkey!,
      relay: relay,
      secret: _secret!,
    );
  }

  /// `bunker://` sends an explicit `connect` RPC and resolves on the signer's reply.
  Future<Nip46ConnectResult> connectViaUri(String bunkerOrNostrconnect) async {
    final parsed = parseConnectionUri(bunkerOrNostrconnect);

    _clientSecretKey = generatePrivateKey();
    _clientPubkey = getPublicKeyHex(_clientSecretKey!);
    _relayUrl = parsed.relay;
    _secret = parsed.secret;
    bareAck.value = false;
    _connected = false;
    _userPubkey = null;

    if (parsed.isBunker) {
      _remotePubkey = parsed.pubkey;
      _connectCompleter = Completer<String>();
      _openRelay();
      // NIP-46: client sends `connect` with [remote_pubkey, secret].
      final params = <String>[parsed.pubkey];
      if (parsed.secret != null) params.add(parsed.secret!);
      // The connect response is matched by id in _handleEvent.
      await sendRequest('connect', params);
      _connected = true;
    } else {
      // Pasted `nostrconnect://`: the signer initiates, so wait for its ack.
      _remotePubkey = null;
      _connectCompleter = Completer<String>();
      _openRelay();
      await _connectCompleter!.future;
    }

    final userPubkey = await _completeLogin();
    return Nip46ConnectResult(userPubkey, this);
  }

  /// Completes with the remote signer pubkey once it acknowledges connect.
  Future<String> awaitConnect() {
    final c = _connectCompleter;
    if (c == null) {
      throw StateError('No NIP-46 connect in progress');
    }
    return c.future;
  }

  /// After [awaitConnect], fetch the user pubkey and persist; the relay is already open, so don't re-open.
  Future<Nip46ConnectResult> finishNostrConnect() async {
    final userPubkey = await _completeLogin();
    return Nip46ConnectResult(userPubkey, this);
  }

  /// Fetches the user pubkey, persists the session, and switches to a persistent subscription.
  Future<String> _completeLogin() async {
    final result = await sendRequest('get_public_key', const []);
    final userPubkey = result is String ? result : '';
    if (userPubkey.length != 64) {
      throw StateError('Remote signer returned an invalid public key.');
    }
    _userPubkey = userPubkey;
    _connected = true;

    await _persistSession(userPubkey);

    // Replace the auth sub with a persistent one for ongoing signing.
    _resubscribePersistent();
    return userPubkey;
  }

  Future<void> _persistSession(String userPubkey) async {
    await _kv.setString(StorageKeys.nostrLoginMethod, 'nip46');
    await _kv.setString(StorageKeys.nostrLoginPubkey, userPubkey);
    await _kv.setString(StorageKeys.nip46RemotePubkey, _remotePubkey ?? '');
    await _kv.setString(StorageKeys.nip46Relay, _relayUrl ?? '');
    await _secure.set(
      SecretKeys.nip46ClientSecret,
      bytesToHex(_clientSecretKey!),
    );
  }

  /// Restores and reconnects a persisted session; true if one was found.
  Future<bool> restoreSession() async {
    final clientSecretHex = await _secure.get(SecretKeys.nip46ClientSecret);
    final remotePubkey = _kv.getString(StorageKeys.nip46RemotePubkey);
    final relayUrl = _kv.getString(StorageKeys.nip46Relay);
    final userPubkey = _kv.getString(StorageKeys.nostrLoginPubkey);
    if (clientSecretHex == null ||
        clientSecretHex.isEmpty ||
        remotePubkey == null ||
        remotePubkey.isEmpty ||
        relayUrl == null ||
        relayUrl.isEmpty) {
      return false;
    }
    try {
      _clientSecretKey = hexToBytes(clientSecretHex);
      _clientPubkey = getPublicKeyHex(_clientSecretKey!);
      _relayUrl = relayUrl;
      _remotePubkey = remotePubkey;
      _userPubkey = userPubkey;
      _secret = null;
      _connected = true;
      _openRelay(persistent: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _openRelay({bool persistent = false}) {
    final relay = _relayUrl!;
    // Tear down any prior socket before opening a new one.
    _socketSub?.cancel();
    _socketSub = null;
    final socket = _socketFactory(relay);
    if (socket is _FailingNip46Socket) {
      debugPrint(
          '[NIP46] Socket open failed; skipping subscribe. error=${socket.error}');
      _connected = false;
      return;
    }
    _socket = socket;
    _subId = '${persistent ? 'nip46-session' : 'nip46-auth'}-'
        '${DateTime.now().millisecondsSinceEpoch}';

    _socketSub = socket.messages.listen(
      _onSocketMessage,
      onError: (_) {},
      cancelOnError: false,
      // Reconnect after 3s if a raw socket drops mid-wait; pool sockets only end on our own [close].
      onDone: () {
        if (!_connected && identical(_socket, socket)) {
          Timer(const Duration(seconds: 3), () {
            if (!_connected && identical(_socket, socket)) {
              _openRelay(persistent: persistent);
            }
          });
        }
      },
    );

    // Kind-24133 addressed to our client pubkey.
    final since = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 10;
    socket.send(jsonEncode([
      'REQ',
      _subId,
      {
        'kinds': [kNip46Kind],
        '#p': [_clientPubkey],
        'since': since,
      },
    ]));
  }

  void _resubscribePersistent() {
    final socket = _socket;
    if (socket == null) return;
    socket.send(jsonEncode(['CLOSE', _subId]));
    _subId = 'nip46-session-${DateTime.now().millisecondsSinceEpoch}';
    final since = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 5;
    socket.send(jsonEncode([
      'REQ',
      _subId,
      {
        'kinds': [kNip46Kind],
        '#p': [_clientPubkey],
        'since': since,
      },
    ]));
  }

  void _onSocketMessage(String data) {
    dynamic msg;
    try {
      msg = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (msg is! List || msg.isEmpty) return;
    if (msg[0] == 'EVENT' && msg.length >= 3 && msg[1] == _subId) {
      final event = msg[2];
      if (event is Map<String, dynamic>) {
        handleEvent(NostrEvent.fromJson(event));
      }
    }
  }

  /// Handles a decrypted kind-24133 event; exposed for tests.
  void handleEvent(NostrEvent event) {
    try {
      final ck = nip44.getConversationKey(_clientSecretKey!, event.pubkey);
      final decrypted = nip44.decrypt(event.content, ck);
      final response = jsonDecode(decrypted);
      if (response is! Map) return;

      final result = response['result'];
      final error = response['error'];
      final id = response['id'];

      // Auth-url challenge: surface to the UI without resolving the request.
      if (result == 'auth_url') {
        if (_remotePubkey == null || event.pubkey != _remotePubkey) return;
        _authUrl = (error is String) ? error : null;
        _authUrlController?.add(_authUrl ?? '');
        return;
      }

      if (_remotePubkey == null) {
        final secret = _secret;
        if (secret == null || result is! String || result != secret) {
          if (result == 'ack') bareAck.value = true;
          return;
        }
        _remotePubkey = event.pubkey;
        _connected = true;
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.complete(event.pubkey);
        }
      } else if (event.pubkey != _remotePubkey) {
        return;
      }

      if (id is String) {
        final pending = _pendingRequests.remove(id);
        if (pending != null) {
          pending.timer.cancel();
          if (!pending.completer.isCompleted) {
            if (error != null && (result == null)) {
              pending.completer.completeError(
                StateError(error is String ? error : 'remote signer error'),
              );
            } else {
              pending.completer.complete(result);
            }
          }
        }
      }
    } catch (_) {
      // Ignore frames we can't decrypt or parse.
    }
  }

  String? _authUrl;
  StreamController<String>? _authUrlController;

  /// Emits the signer's auth URL when authorization is required.
  Stream<String> get authUrls {
    _authUrlController ??= StreamController<String>.broadcast();
    return _authUrlController!.stream;
  }

  /// NIP-44-encrypts the RPC into a signed kind-24133 event; resolves with the id-matched result or times out.
  Future<dynamic> sendRequest(String method, List<dynamic> params) {
    final socket = _socket;
    final clientKey = _clientSecretKey;
    final remote = _remotePubkey;
    if (socket == null || clientKey == null || remote == null) {
      return Future.error(
        StateError('NIP-46 remote signer not connected'),
      );
    }

    final id = _newRequestId();
    final request = jsonEncode({'id': id, 'method': method, 'params': params});

    final ck = nip44.getConversationKey(clientKey, remote);
    final encrypted = nip44.encrypt(request, ck);

    final unsigned = UnsignedEvent(
      pubkey: _clientPubkey!,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: kNip46Kind,
      tags: [
        ['p', remote],
      ],
      content: encrypted,
    );
    final signed = schnorr.finalizeEvent(unsigned, clientKey);
    socket.send(jsonEncode(['EVENT', signed.toJson()]));

    final completer = Completer<dynamic>();
    final timer = Timer(_requestTimeout, () {
      final pending = _pendingRequests.remove(id);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          TimeoutException('Remote signer request timed out'),
        );
      }
    });
    _pendingRequests[id] = _Pending(completer, timer);
    return completer.future;
  }

  int _reqCounter = 0;
  String _newRequestId() {
    // Only uniqueness matters; random bytes plus a counter keep tests deterministic.
    _reqCounter++;
    return '${bytesToHex(randomBytes(8))}$_reqCounter';
  }

  @override
  Future<NostrEvent> signEvent(UnsignedEvent unsigned) async {
    // The unsigned event JSON is the single param; author defaults to the logged-in pubkey.
    final author = unsigned.pubkey.isNotEmpty ? unsigned.pubkey : pubkey;
    final payload = {
      'kind': unsigned.kind,
      'created_at': unsigned.createdAt,
      'tags': unsigned.tags,
      'content': unsigned.content,
      'pubkey': author,
    };
    final resultStr = await sendRequest('sign_event', [jsonEncode(payload)]);
    final map = resultStr is String ? jsonDecode(resultStr) : resultStr;
    return NostrEvent.fromJson(Map<String, dynamic>.from(map as Map));
  }

  @override
  Future<String> nip44Encrypt(String thirdPartyPubkey, String plaintext) async {
    final r = await sendRequest('nip44_encrypt', [thirdPartyPubkey, plaintext]);
    return r as String;
  }

  @override
  Future<String> nip44Decrypt(
      String thirdPartyPubkey, String ciphertext) async {
    final r =
        await sendRequest('nip44_decrypt', [thirdPartyPubkey, ciphertext]);
    return r as String;
  }

  Future<void> dispose() async {
    for (final p in _pendingRequests.values) {
      p.timer.cancel();
      if (!p.completer.isCompleted) {
        p.completer.completeError(StateError('NIP-46 service disposed'));
      }
    }
    _pendingRequests.clear();
    await _socketSub?.cancel();
    await _socket?.close();
    _socket = null;
    await _authUrlController?.close();
    _authUrlController = null;
  }

  /// Aborts a pending connection but stays reusable, so a live session is never killed by the modal closing.
  Future<void> cancelConnect() async {
    for (final p in _pendingRequests.values) {
      p.timer.cancel();
      if (!p.completer.isCompleted) {
        p.completer.completeError(StateError('NIP-46 connect canceled'));
      }
    }
    _pendingRequests.clear();
    await _socketSub?.cancel();
    _socketSub = null;
    await _socket?.close();
    _socket = null;
    _connected = false;
  }

  static String _formEncode(String s) =>
      Uri.encodeQueryComponent(s); // Space as '+', like URLSearchParams.

  static String _formDecode(String s) =>
      Uri.decodeQueryComponent(s);
}
