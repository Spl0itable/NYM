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

/// NIP-46 remote-signer (bunker / nostrconnect) transport.
///
/// 1:1 port of the PWA NIP-46 section (`js/app.js` ~5077-5481). The client
/// generates an ephemeral keypair, connects a WebSocket to the signer relay,
/// subscribes to kind-24133 events `#p=<clientPubkey>`, and exchanges
/// NIP-44-encrypted `{id, method, params}` RPC frames with the remote signer.
///
/// Supported RPC methods (PWA parity): `connect`, `get_public_key`,
/// `sign_event`, `nip44_encrypt`, `nip44_decrypt`. Responses are matched to
/// outstanding requests by `id` via [_pendingRequests] (with a timeout).
///
/// On a successful connect the session is persisted so it survives a restart:
///   - `nym_nostr_login_method` = `'nip46'`               (KV)
///   - `nym_nip46_remote_pubkey`                           (KV)
///   - `nym_nip46_relay`                                   (KV)
///   - `nym_nip46_client_secret` (hex client secret key)   (SecureStore)
/// [restoreSession] reads them back and reconnects on boot.
///
/// The signing path in the controller/service is owned by another agent. This
/// service exposes a [Nip46Signer] the publish path can later delegate to —
/// see the README/return notes for the integration point.

/// The kind used for NIP-46 transport events.
const int kNip46Kind = 24133;

/// Default RPC timeout. Matches the PWA's 60s (remote signer may prompt user).
const Duration kNip46RequestTimeout = Duration(seconds: 60);

/// Minimal subset of [SecureStore] this service needs, declared as an interface
/// so tests can inject an in-memory fake (mirrors `SecureStoreLike` elsewhere).
abstract class Nip46SecureStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

/// Minimal subset of [KeyValueStore] this service needs. [KeyValueStore]
/// satisfies this shape structurally, so it can be passed directly in
/// production while tests inject an in-memory fake.
abstract class Nip46KeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
}

/// A bidirectional text transport to the signer relay. Abstracted so tests can
/// supply an in-memory fake instead of a live WebSocket.
abstract class Nip46Socket {
  /// Inbound text frames from the relay.
  Stream<String> get messages;

  /// Sends a text frame to the relay.
  void send(String data);

  /// Closes the transport.
  Future<void> close();
}

/// Factory that opens a [Nip46Socket] for a relay URL.
typedef Nip46SocketFactory = Nip46Socket Function(String relayUrl);

/// Default [Nip46Socket] backed by a real [WebSocketChannel].
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

/// A socket that failed to open. It keeps the service alive (no crash) while
/// surfacing failure through logs.
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

/// Parsed `nostrconnect://` or `bunker://` connection string.
class Nip46ConnectionUri {
  Nip46ConnectionUri({
    required this.scheme,
    required this.pubkey,
    required this.relay,
    this.secret,
    this.metadataName,
  });

  /// `'nostrconnect'` (pubkey is the client's) or `'bunker'` (pubkey is the
  /// remote signer's).
  final String scheme;

  /// For `nostrconnect://` this is the *client* pubkey; for `bunker://` it is
  /// the *remote signer* pubkey. 64-char hex.
  final String pubkey;
  final String relay;
  final String? secret;
  final String? metadataName;

  bool get isBunker => scheme == 'bunker';
  bool get isNostrConnect => scheme == 'nostrconnect';
}

/// A handle to a connected remote signer that can sign events.
///
/// The publish path delegates to this: when the active login method is
/// `'nip46'`, instead of signing locally with a secret key it calls
/// [signEvent] (which round-trips a `sign_event` RPC to the remote signer) and
/// uses [pubkey] as the event author.
abstract class Nip46Signer {
  /// The remote signer's *user* pubkey (from `get_public_key`). 64-char hex.
  String get pubkey;

  /// Asks the remote signer to sign [unsigned] and returns the signed event.
  Future<NostrEvent> signEvent(UnsignedEvent unsigned);

  /// NIP-44 encrypt [plaintext] to [thirdPartyPubkey] via the remote signer.
  Future<String> nip44Encrypt(String thirdPartyPubkey, String plaintext);

  /// NIP-44 decrypt [ciphertext] from [thirdPartyPubkey] via the remote signer.
  Future<String> nip44Decrypt(String thirdPartyPubkey, String ciphertext);
}

class _Pending {
  _Pending(this.completer, this.timer);
  final Completer<dynamic> completer;
  final Timer timer;
}

/// Result of a successful connect: the user pubkey plus the live signer.
class Nip46ConnectResult {
  Nip46ConnectResult(this.userPubkey, this.signer);
  final String userPubkey;
  final Nip46Signer signer;
}

class Nip46Service implements Nip46Signer {
  Nip46Service({
    required Nip46KeyValueStore kv,
    required Nip46SecureStore secure,
    Nip46SocketFactory socketFactory = _defaultSocketFactory,
    Duration requestTimeout = kNip46RequestTimeout,
  })  : _kv = kv,
        _secure = secure,
        _socketFactory = socketFactory,
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

  /// Outstanding RPC requests keyed by request id. Mirrors the PWA
  /// `pendingRequests` Map.
  final Map<String, _Pending> _pendingRequests = {};

  /// Completes once the signer acknowledges `connect` (used by the login flow).
  Completer<String>? _connectCompleter;

  // --- public getters -------------------------------------------------------

  @override
  String get pubkey => _userPubkey ?? '';

  String? get clientPubkey => _clientPubkey;
  String? get remotePubkey => _remotePubkey;
  bool get isConnected => _connected;

  // --- URI building / parsing ----------------------------------------------

  /// Builds a `nostrconnect://<clientPubkey>?relay=..&metadata=..&secret=..`
  /// URI for QR display. Matches the PWA param ordering: relay, metadata,
  /// secret (URLSearchParams form-encoded).
  static String buildNostrConnectUri({
    required String clientPubkey,
    required String relay,
    required String secret,
    String appName = 'Nymchat',
  }) {
    // Mirror URLSearchParams: '+'-encode spaces, set in relay/metadata/secret
    // order. metadata is a JSON object `{"name":"<appName>"}`.
    final metadata = jsonEncode({'name': appName});
    final params = <String>[
      'relay=${_formEncode(relay)}',
      'metadata=${_formEncode(metadata)}',
      'secret=${_formEncode(secret)}',
    ].join('&');
    return 'nostrconnect://$clientPubkey?$params';
  }

  /// Parses a `nostrconnect://` or `bunker://` connection string.
  ///
  /// `bunker://<remotePubkey>?relay=wss://..&secret=..` (NIP-46) — the host is
  /// the remote signer pubkey. `nostrconnect://<clientPubkey>?relay=..` — the
  /// host is the client pubkey.
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
      // Pubkey must be 64-char hex; bail clearly rather than later.
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
          // First relay wins (PWA uses a single relay).
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
      relay: relay ?? RelayConfig.nip46Relay,
      secret: secret,
      metadataName: metadataName,
    );
  }

  // --- connect flows --------------------------------------------------------

  /// Starts a `nostrconnect://` login: generates a client keypair + 16-hex
  /// secret, opens the relay, subscribes for the signer's connect response, and
  /// returns the `nostrconnect://` URI for QR display.
  ///
  /// Await [awaitConnect] (or pass [onConnected]) to learn when the signer
  /// acknowledges and the session is established.
  String startNostrConnect({String relay = RelayConfig.nip46Relay}) {
    _clientSecretKey = generatePrivateKey();
    _clientPubkey = getPublicKeyHex(_clientSecretKey!);
    _relayUrl = relay;
    // 16 hex chars == 8 random bytes. Matches the PWA (.slice(0, 16)).
    _secret = bytesToHex(randomBytes(8));
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

  /// Connects via a pasted `bunker://` (or `nostrconnect://`) URI.
  ///
  /// For `bunker://` the remote pubkey + relay (+ optional secret) come from the
  /// URI; the client keypair is generated locally. We send an explicit
  /// `connect` RPC to the remote signer and resolve once it responds. Returns
  /// the connect result (user pubkey + signer).
  Future<Nip46ConnectResult> connectViaUri(String bunkerOrNostrconnect) async {
    final parsed = parseConnectionUri(bunkerOrNostrconnect);

    _clientSecretKey = generatePrivateKey();
    _clientPubkey = getPublicKeyHex(_clientSecretKey!);
    _relayUrl = parsed.relay;
    _secret = parsed.secret;
    _connected = false;
    _userPubkey = null;

    if (parsed.isBunker) {
      // bunker:// gives us the remote signer pubkey up front.
      _remotePubkey = parsed.pubkey;
      _connectCompleter = Completer<String>();
      _openRelay();
      // Per NIP-46: client → signer `connect` with [remote_pubkey, secret].
      final params = <String>[parsed.pubkey];
      if (parsed.secret != null) params.add(parsed.secret!);
      // The connect response itself is matched by id in _handleEvent.
      await sendRequest('connect', params);
      _connected = true;
    } else {
      // nostrconnect:// from a paste: behave like startNostrConnect, but the
      // signer initiates. Wait for the signer's connect ack.
      _remotePubkey = null;
      _connectCompleter = Completer<String>();
      _openRelay();
      await _connectCompleter!.future;
    }

    final userPubkey = await _completeLogin();
    return Nip46ConnectResult(userPubkey, this);
  }

  /// Completes once the signer acknowledges connect (nostrconnect flow). Yields
  /// the remote signer pubkey.
  Future<String> awaitConnect() {
    final c = _connectCompleter;
    if (c == null) {
      throw StateError('No NIP-46 connect in progress');
    }
    return c.future;
  }

  /// For the [startNostrConnect] flow: after the signer acknowledges connect
  /// (await [awaitConnect]), fetch the user pubkey, persist the session, and
  /// return the [Nip46ConnectResult]. The relay is already open and
  /// `_remotePubkey` is set by the connect ack — do NOT re-open.
  Future<Nip46ConnectResult> finishNostrConnect() async {
    final userPubkey = await _completeLogin();
    return Nip46ConnectResult(userPubkey, this);
  }

  /// After connect: fetch the user pubkey, persist the session, and switch the
  /// subscription to a persistent one. Returns the 64-hex user pubkey.
  Future<String> _completeLogin() async {
    final result = await sendRequest('get_public_key', const []);
    final userPubkey = result is String ? result : '';
    if (userPubkey.length != 64) {
      throw StateError('Remote signer returned an invalid public key.');
    }
    _userPubkey = userPubkey;
    _connected = true;

    await _persistSession(userPubkey);

    // Close the auth sub; re-subscribe persistently for ongoing signing.
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

  // --- session restore ------------------------------------------------------

  /// Restores a persisted NIP-46 session on boot and reconnects the relay.
  /// Returns true if a session was found and reconnected.
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

  // --- relay transport ------------------------------------------------------

  void _openRelay({bool persistent = false}) {
    final relay = _relayUrl!;
    final socket = _socketFactory(relay);
    if (socket is _FailingNip46Socket) {
      debugPrint('[NIP46] Socket open failed; skipping subscribe. error=${socket.error}');
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
    );

    // Subscribe to kind-24133 addressed to our client pubkey.
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

  /// Handles a decrypted kind-24133 event from the signer. Exposed for tests.
  void handleEvent(NostrEvent event) {
    try {
      final ck = nip44.getConversationKey(_clientSecretKey!, event.pubkey);
      final decrypted = nip44.decrypt(event.content, ck);
      final response = jsonDecode(decrypted);
      if (response is! Map) return;

      final result = response['result'];
      final error = response['error'];
      final id = response['id'];

      // Auth-url challenge: surface to UI, don't resolve the request.
      if (result == 'auth_url') {
        _authUrl = (error is String) ? error : null;
        _authUrlController?.add(_authUrl ?? '');
        return;
      }

      // Connect ack for the nostrconnect flow (signer initiates, no prior id).
      if (_remotePubkey == null) {
        _remotePubkey = event.pubkey;
        // Verify secret if the signer echoed it (PWA parity).
        if (_secret != null &&
            result is String &&
            result != 'ack' &&
            result != _secret) {
          // Secret mismatch — treat as failure.
          _connectCompleter?.completeError(
            StateError('NIP-46 connection secret mismatch'),
          );
          return;
        }
        _connected = true;
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.complete(event.pubkey);
        }
        // Fall through so an id-bearing connect response still resolves.
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
      // Ignore frames we can't decrypt/parse (PWA logs and continues).
    }
  }

  String? _authUrl;
  StreamController<String>? _authUrlController;

  /// Emits the signer's auth-url when authorization is required.
  Stream<String> get authUrls {
    _authUrlController ??= StreamController<String>.broadcast();
    return _authUrlController!.stream;
  }

  // --- RPC ------------------------------------------------------------------

  /// Sends an `{id, method, params}` RPC: NIP-44-encrypts it to the remote
  /// signer, wraps it in a signed kind-24133 event, and returns a future that
  /// resolves with the response `result` (matched by id), or times out.
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
    // PWA: Math.random().toString(36) + Date.now().toString(36). Uniqueness is
    // all that matters; use random bytes + a counter for determinism in tests.
    _reqCounter++;
    return '${bytesToHex(randomBytes(8))}$_reqCounter';
  }

  // --- Nip46Signer ----------------------------------------------------------

  @override
  Future<NostrEvent> signEvent(UnsignedEvent unsigned) async {
    // PWA sends sign_event with the unsigned event JSON as a single param. The
    // pubkey defaults to the logged-in user pubkey.
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
  Future<String> nip44Decrypt(String thirdPartyPubkey, String ciphertext)
      async {
    final r = await sendRequest('nip44_decrypt', [thirdPartyPubkey, ciphertext]);
    return r as String;
  }

  // --- teardown -------------------------------------------------------------

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

  // --- form-encoding helpers (URLSearchParams parity) -----------------------

  static String _formEncode(String s) =>
      Uri.encodeQueryComponent(s); // encodes space as '+', like URLSearchParams

  static String _formDecode(String s) =>
      Uri.decodeQueryComponent(s); // decodes '+' to space
}
