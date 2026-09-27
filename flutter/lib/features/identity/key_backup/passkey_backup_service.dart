import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/constants/relays.dart';
import '../../../core/crypto/bech32_codec.dart' as bech32;
import '../../../core/crypto/keys.dart';
import '../../../models/nostr_event.dart';
import 'key_backup_config.dart';
import 'key_backup_crypto.dart' show BackupSecret;
import 'key_backup_service.dart' show shortNpub;
import 'passkey_backup_crypto.dart';

enum PasskeyBackupError {
  canceled,
  noCredential,
  unsupported,
  publishFailed,
  blobFailed,
  notFound,
  rp,
  exists,
  other,
}

class PasskeyBackupException implements Exception {
  const PasskeyBackupException(this.error);

  final PasskeyBackupError error;

  @override
  String toString() => 'PasskeyBackupException(${error.name})';
}

class PasskeyCreateResult {
  const PasskeyCreateResult({
    required this.credentialId,
    this.prfFirst,
    this.prfEnabled = false,
    this.largeBlobSupported = false,
  });

  final Uint8List credentialId;
  final Uint8List? prfFirst;
  final bool prfEnabled;
  final bool largeBlobSupported;
}

class PasskeyGetResult {
  const PasskeyGetResult({
    required this.credentialId,
    this.prfFirst,
    this.largeBlob,
    this.largeBlobWritten,
  });

  final Uint8List credentialId;
  final Uint8List? prfFirst;
  final Uint8List? largeBlob;
  final bool? largeBlobWritten;
}

abstract class PasskeyPlatform {
  Future<bool> isAvailable();

  Future<PasskeyCreateResult> create({
    required String rpId,
    required String rpName,
    required Uint8List userId,
    required String userName,
    required Uint8List challenge,
    required Uint8List prfSalt,
  });

  Future<PasskeyGetResult> get({
    required String rpId,
    required Uint8List challenge,
    Uint8List? prfSalt,
    List<Uint8List> allowCredentials = const [],
    bool largeBlobRead = false,
    Uint8List? largeBlobWrite,
  });
}

String _b64url(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List? _unb64url(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    return Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
  } catch (_) {
    return null;
  }
}

String passkeyCreateRequestJson({
  required String rpId,
  required String rpName,
  required Uint8List userId,
  required String userName,
  required Uint8List challenge,
  required Uint8List prfSalt,
}) =>
    jsonEncode({
      'challenge': _b64url(challenge),
      'rp': {'id': rpId, 'name': rpName},
      'user': {
        'id': _b64url(userId),
        'name': userName,
        'displayName': userName,
      },
      'pubKeyCredParams': [
        {'type': 'public-key', 'alg': -7},
        {'type': 'public-key', 'alg': -257},
      ],
      'timeout': 60000,
      'authenticatorSelection': {
        'residentKey': 'required',
        'requireResidentKey': true,
        'userVerification': 'required',
      },
      'extensions': {
        'prf': {
          'eval': {'first': _b64url(prfSalt)},
        },
        'largeBlob': {'support': 'preferred'},
      },
    });

String passkeyGetRequestJson({
  required String rpId,
  required Uint8List challenge,
  Uint8List? prfSalt,
  List<Uint8List> allowCredentials = const [],
  bool largeBlobRead = false,
  Uint8List? largeBlobWrite,
}) =>
    jsonEncode({
      'challenge': _b64url(challenge),
      'rpId': rpId,
      'timeout': 60000,
      'userVerification': 'required',
      'allowCredentials': [
        for (final id in allowCredentials)
          {'type': 'public-key', 'id': _b64url(id)},
      ],
      'extensions': {
        if (prfSalt != null)
          'prf': {
            'eval': {'first': _b64url(prfSalt)},
          },
        if (largeBlobWrite != null)
          'largeBlob': {'write': _b64url(largeBlobWrite)}
        else if (largeBlobRead)
          'largeBlob': {'read': true},
      },
    });

Map<String, dynamic> _extensionResults(String json) {
  final decoded = jsonDecode(json);
  if (decoded is! Map) return const {};
  final ext = decoded['clientExtensionResults'];
  return ext is Map ? Map<String, dynamic>.from(ext) : const {};
}

Uint8List _rawId(String json) {
  final decoded = jsonDecode(json);
  if (decoded is! Map) return Uint8List(0);
  return _unb64url(decoded['rawId']) ?? _unb64url(decoded['id']) ?? Uint8List(0);
}

Uint8List? _prfFirst(Map<String, dynamic> ext) {
  final prf = ext['prf'];
  if (prf is! Map) return null;
  final results = prf['results'];
  if (results is! Map) return null;
  return _unb64url(results['first']);
}

PasskeyCreateResult parsePasskeyCreateResponse(String json) {
  final ext = _extensionResults(json);
  final prf = ext['prf'];
  final blob = ext['largeBlob'];
  return PasskeyCreateResult(
    credentialId: _rawId(json),
    prfFirst: _prfFirst(ext),
    prfEnabled: prf is Map && prf['enabled'] == true,
    largeBlobSupported: blob is Map && blob['supported'] == true,
  );
}

PasskeyGetResult parsePasskeyGetResponse(String json) {
  final ext = _extensionResults(json);
  final blob = ext['largeBlob'];
  final written = blob is Map ? blob['written'] : null;
  return PasskeyGetResult(
    credentialId: _rawId(json),
    prfFirst: _prfFirst(ext),
    largeBlob: blob is Map ? _unb64url(blob['blob']) : null,
    largeBlobWritten: written is bool ? written : null,
  );
}

class MethodChannelPasskeyPlatform implements PasskeyPlatform {
  const MethodChannelPasskeyPlatform();

  static const MethodChannel channel =
      MethodChannel('app.nymchat/passkey_backup');

  bool get _json => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> isAvailable() async {
    try {
      return await channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PasskeyCreateResult> create({
    required String rpId,
    required String rpName,
    required Uint8List userId,
    required String userName,
    required Uint8List challenge,
    required Uint8List prfSalt,
  }) async {
    if (_json) {
      final res = await _invoke<String>('create', {
        'requestJson': passkeyCreateRequestJson(
          rpId: rpId,
          rpName: rpName,
          userId: userId,
          userName: userName,
          challenge: challenge,
          prfSalt: prfSalt,
        ),
      });
      return parsePasskeyCreateResponse(res ?? '{}');
    }
    final res = await _invoke<Map<Object?, Object?>>('create', {
      'rpId': rpId,
      'rpName': rpName,
      'userId': userId,
      'userName': userName,
      'challenge': challenge,
      'prfSalt': prfSalt,
    });
    final map = res ?? const {};
    return PasskeyCreateResult(
      credentialId: _bytes(map['credentialId']) ?? Uint8List(0),
      prfFirst: _bytes(map['prfFirst']),
      prfEnabled: map['prfEnabled'] == true,
      largeBlobSupported: map['largeBlobSupported'] == true,
    );
  }

  @override
  Future<PasskeyGetResult> get({
    required String rpId,
    required Uint8List challenge,
    Uint8List? prfSalt,
    List<Uint8List> allowCredentials = const [],
    bool largeBlobRead = false,
    Uint8List? largeBlobWrite,
  }) async {
    if (_json) {
      final res = await _invoke<String>('get', {
        'requestJson': passkeyGetRequestJson(
          rpId: rpId,
          challenge: challenge,
          prfSalt: prfSalt,
          allowCredentials: allowCredentials,
          largeBlobRead: largeBlobRead,
          largeBlobWrite: largeBlobWrite,
        ),
      });
      return parsePasskeyGetResponse(res ?? '{}');
    }
    final res = await _invoke<Map<Object?, Object?>>('get', {
      'rpId': rpId,
      'challenge': challenge,
      'prfSalt': prfSalt,
      'allowCredentials': allowCredentials,
      'largeBlobRead': largeBlobRead,
      'largeBlobWrite': largeBlobWrite,
    });
    final map = res ?? const {};
    final written = map['largeBlobWritten'];
    return PasskeyGetResult(
      credentialId: _bytes(map['credentialId']) ?? Uint8List(0),
      prfFirst: _bytes(map['prfFirst']),
      largeBlob: _bytes(map['largeBlob']),
      largeBlobWritten: written is bool ? written : null,
    );
  }

  Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw PasskeyBackupException(passkeyErrorFromCode(e.code));
    } on MissingPluginException {
      throw const PasskeyBackupException(PasskeyBackupError.unsupported);
    }
  }

  static Uint8List? _bytes(Object? v) {
    if (v is Uint8List) return v.isEmpty ? null : v;
    if (v is List) return v.isEmpty ? null : Uint8List.fromList(v.cast<int>());
    return null;
  }
}

PasskeyBackupError passkeyErrorFromCode(String code) => switch (code) {
      'canceled' => PasskeyBackupError.canceled,
      'none' => PasskeyBackupError.noCredential,
      'unsupported' => PasskeyBackupError.unsupported,
      'exists' => PasskeyBackupError.exists,
      'rp' => PasskeyBackupError.rp,
      _ => PasskeyBackupError.other,
    };

abstract class PasskeyRelayClient {
  Future<int> publish(NostrEvent event, List<String> relays);

  Future<List<NostrEvent>> query(Map<String, Object> filter, List<String> relays);
}

class WebSocketPasskeyRelayClient implements PasskeyRelayClient {
  const WebSocketPasskeyRelayClient({
    this.timeout = const Duration(seconds: 8),
  });

  final Duration timeout;

  @override
  Future<int> publish(NostrEvent event, List<String> relays) async {
    final results = await Future.wait(relays.map((url) => _publishOne(url, event)));
    return results.where((ok) => ok).length;
  }

  @override
  Future<List<NostrEvent>> query(
      Map<String, Object> filter, List<String> relays) async {
    final results = await Future.wait(relays.map((url) => _queryOne(url, filter)));
    return [for (final r in results) ...r];
  }

  Future<bool> _publishOne(String url, NostrEvent event) async {
    WebSocketChannel? ws;
    try {
      ws = WebSocketChannel.connect(Uri.parse(url));
      await ws.ready.timeout(timeout);
      ws.sink.add(jsonEncode(['EVENT', event.toJson()]));
      final ok = await ws.stream
          .map((m) => m is String ? jsonDecode(m) : null)
          .firstWhere((m) => m is List && m.length >= 3 && m[0] == 'OK' && m[1] == event.id)
          .timeout(timeout);
      return (ok as List)[2] == true;
    } catch (_) {
      return false;
    } finally {
      unawaited(ws?.sink.close().catchError((_) {}));
    }
  }

  Future<List<NostrEvent>> _queryOne(
      String url, Map<String, Object> filter) async {
    WebSocketChannel? ws;
    final events = <NostrEvent>[];
    try {
      ws = WebSocketChannel.connect(Uri.parse(url));
      await ws.ready.timeout(timeout);
      const sub = 'nymbk';
      ws.sink.add(jsonEncode(['REQ', sub, filter]));
      await for (final raw in ws.stream.timeout(timeout)) {
        if (raw is! String) continue;
        final m = jsonDecode(raw);
        if (m is! List || m.length < 2 || m[1] != sub) continue;
        if (m[0] == 'EOSE' || m[0] == 'CLOSED') break;
        if (m[0] == 'EVENT' && m.length >= 3 && m[2] is Map) {
          try {
            events.add(NostrEvent.fromJson(Map<String, dynamic>.from(m[2] as Map)));
          } catch (_) {}
        }
      }
    } catch (_) {
    } finally {
      unawaited(ws?.sink.close().catchError((_) {}));
    }
    return events;
  }
}

List<String> passkeyPublishRelays() => {
      ...RelayConfig.defaultRelays,
      ...kPasskeyFixedRelays,
    }.toList();

List<String> passkeyQueryRelays() => passkeyPublishRelays()
    .where((r) => !RelayConfig.writeOnlyRelays.contains(r))
    .toList();

class PasskeyBackupService {
  PasskeyBackupService({
    required this.rpId,
    this.rpName = 'Nymchat',
    PasskeyPlatform? platform,
    PasskeyRelayClient? relays,
    List<String>? publishRelays,
    List<String>? queryRelays,
    int Function()? now,
    Uint8List? Function()? nonce,
  })  : _platform = platform ?? const MethodChannelPasskeyPlatform(),
        _relays = relays ?? const WebSocketPasskeyRelayClient(),
        _publishRelays = publishRelays ?? passkeyPublishRelays(),
        _queryRelays = queryRelays ?? passkeyQueryRelays(),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000),
        _nonce = nonce;

  final String rpId;
  final String rpName;
  final PasskeyPlatform _platform;
  final PasskeyRelayClient _relays;
  final List<String> _publishRelays;
  final List<String> _queryRelays;
  final int Function() _now;
  final Uint8List? Function()? _nonce;

  Future<bool> isAvailable() => _platform.isAvailable();

  Future<void> backUp({
    required String secretHex,
    required String pubkeyHex,
    String? pqCode,
  }) async {
    final salt = passkeyPrfSalt();
    final label = '$rpName key backup · ${shortNpub(bech32.encodeNpub(pubkeyHex))}';
    final created = await _platform.create(
      rpId: rpId,
      rpName: rpName,
      userId: randomBytes(16),
      userName: label,
      challenge: randomBytes(32),
      prfSalt: salt,
    );
    var prf = created.prfFirst;
    if (prf == null && created.prfEnabled) {
      final got = await _platform.get(
        rpId: rpId,
        challenge: randomBytes(32),
        prfSalt: salt,
        allowCredentials: [created.credentialId],
      );
      prf = got.prfFirst;
    }
    if (prf != null) {
      final keys = PasskeyBackupKeys.fromPrf(prf);
      prf.fillRange(0, prf.length, 0);
      try {
        final event = keys.buildEvent(secretHex,
            createdAt: _now(), pqCode: pqCode, nonce: _nonce?.call());
        final ok = await _relays.publish(event, _publishRelays);
        if (ok < 1) {
          throw const PasskeyBackupException(PasskeyBackupError.publishFailed);
        }
      } finally {
        keys.wipe();
      }
      return;
    }
    if (created.largeBlobSupported) {
      final blob = encodeLargeBlob(secretHex, pqCode: pqCode);
      try {
        final got = await _platform.get(
          rpId: rpId,
          challenge: randomBytes(32),
          allowCredentials: [created.credentialId],
          largeBlobWrite: blob,
        );
        if (got.largeBlobWritten != true) {
          throw const PasskeyBackupException(PasskeyBackupError.blobFailed);
        }
      } finally {
        blob.fillRange(0, blob.length, 0);
      }
      return;
    }
    throw const PasskeyBackupException(PasskeyBackupError.unsupported);
  }

  Future<BackupSecret> restore() async {
    final got = await _platform.get(
      rpId: rpId,
      challenge: randomBytes(32),
      prfSalt: passkeyPrfSalt(),
      largeBlobRead: true,
    );
    final prf = got.prfFirst;
    if (prf != null) {
      final keys = PasskeyBackupKeys.fromPrf(prf);
      prf.fillRange(0, prf.length, 0);
      try {
        final events = await _relays.query(keys.filter, _queryRelays);
        final secret = keys.secretFromEvents(events);
        if (secret != null) return secret;
      } finally {
        keys.wipe();
      }
    }
    final blob = got.largeBlob;
    final secret = decodeLargeBlob(blob);
    blob?.fillRange(0, blob.length, 0);
    if (secret != null) return secret;
    throw const PasskeyBackupException(PasskeyBackupError.notFound);
  }
}

PasskeyBackupService? defaultPasskeyBackupService({
  KeyBackupConfig config = KeyBackupConfig.environment,
  TargetPlatform? platform,
}) {
  final p = platform ?? defaultTargetPlatform;
  if (!config.passkeyEnabledOn(p)) return null;
  return PasskeyBackupService(rpId: config.passkeyRpId);
}

final passkeyBackupServiceProvider =
    Provider<PasskeyBackupService?>((ref) => defaultPasskeyBackupService());

final passkeyBackupAvailableProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(passkeyBackupServiceProvider);
  if (service == null) return false;
  return service.isAvailable();
});
