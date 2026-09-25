import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'apple_keychain_backup_store.dart';
import 'drive_backup_client.dart';
import 'key_backup_config.dart';
import 'key_backup_crypto.dart';

class BackupEntry {
  const BackupEntry({required this.id, this.payload});

  final String id;
  final String? payload;
}

class KeyBackupCanceled implements Exception {
  const KeyBackupCanceled();
}

class KeyBackupAuthExpired implements Exception {
  const KeyBackupAuthExpired();
}

abstract class KeyBackupStore {
  BackupCloud get cloud;

  Future<String> signIn();

  Future<List<BackupEntry>> list();

  Future<String> read(BackupEntry entry);

  Future<void> write(String payload);

  Future<void> delete(BackupEntry entry);
}

const List<String> kGoogleBackupScopes = <String>[
  'openid',
  'https://www.googleapis.com/auth/drive.appdata',
];

String? subFromIdToken(String? idToken) {
  if (idToken == null) return null;
  final parts = idToken.split('.');
  if (parts.length < 2) return null;
  try {
    final json = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final claims = jsonDecode(json);
    final sub = claims is Map ? claims['sub'] : null;
    return sub is String && sub.isNotEmpty ? sub : null;
  } catch (_) {
    return null;
  }
}

class GoogleKeyBackupStore implements KeyBackupStore {
  GoogleKeyBackupStore(this._config, {http.Client? client}) : _http = client;

  final KeyBackupConfig _config;
  final http.Client? _http;

  static Future<void>? _initialized;

  GoogleSignInAccount? _account;
  String? _accessToken;
  DriveBackupClient? _drive;

  @override
  BackupCloud get cloud => BackupCloud.google;

  Future<void> _ensureInitialized() {
    return _initialized ??= GoogleSignIn.instance
        .initialize(
          clientId: defaultTargetPlatform == TargetPlatform.iOS
              ? _config.googleClientIdForIos
              : null,
          serverClientId: _config.googleServerClientIdOrNull,
        )
        .catchError((Object e) {
      _initialized = null;
      throw e;
    });
  }

  @override
  Future<String> signIn() async {
    await _ensureInitialized();
    final GoogleSignInAccount account;
    try {
      account =
          await GoogleSignIn.instance.authenticate(scopeHint: kGoogleBackupScopes);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const KeyBackupCanceled();
      }
      rethrow;
    }
    _account = account;
    _accessToken = null;
    await _token();
    _drive = DriveBackupClient(accessToken: _token, client: _http);
    return subFromIdToken(account.authentication.idToken) ?? account.id;
  }

  Future<String> _token({bool forceRefresh = false}) async {
    final account = _account;
    if (account == null) throw const KeyBackupAuthExpired();
    final client = account.authorizationClient;
    final current = _accessToken;
    if (!forceRefresh && current != null) return current;
    if (forceRefresh && current != null) {
      try {
        await client.clearAuthorizationToken(accessToken: current);
      } catch (_) {}
    }
    try {
      final authz = await client.authorizationForScopes(kGoogleBackupScopes) ??
          await client.authorizeScopes(kGoogleBackupScopes);
      _accessToken = authz.accessToken;
      return authz.accessToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const KeyBackupCanceled();
      }
      rethrow;
    }
  }

  DriveBackupClient get _driveClient {
    final d = _drive;
    if (d == null) throw const KeyBackupAuthExpired();
    return d;
  }

  @override
  Future<List<BackupEntry>> list() => _guard(() async {
        final files = await _driveClient.list();
        return [for (final f in files) BackupEntry(id: f.id)];
      });

  @override
  Future<String> read(BackupEntry entry) =>
      _guard(() => _driveClient.download(entry.id));

  @override
  Future<void> write(String payload) => _guard(() => _driveClient.upload(payload));

  @override
  Future<void> delete(BackupEntry entry) =>
      _guard(() => _driveClient.delete(entry.id));

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DriveAuthException {
      throw const KeyBackupAuthExpired();
    }
  }
}

class AppleKeyBackupStore implements KeyBackupStore {
  AppleKeyBackupStore(KeyBackupConfig config, {AppleKeychainBackupStore? keychain})
      : _keychain = keychain ??
            AppleKeychainBackupStore(
                accessGroup: config.appleKeychainGroupOrNull);

  final AppleKeychainBackupStore _keychain;

  @override
  BackupCloud get cloud => BackupCloud.apple;

  @override
  Future<String> signIn() async {
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
          scopes: const <AppleIDAuthorizationScopes>[]);
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const KeyBackupCanceled();
      }
      rethrow;
    }
    final user = credential.userIdentifier;
    if (user == null || user.isEmpty) {
      throw PlatformException(code: 'no_user_identifier');
    }
    return user;
  }

  @override
  Future<List<BackupEntry>> list() async {
    final all = await _keychain.readAll();
    return [
      for (final e in all.entries) BackupEntry(id: e.key, payload: e.value),
    ];
  }

  @override
  Future<String> read(BackupEntry entry) async {
    final cached = entry.payload;
    if (cached != null) return cached;
    final all = await _keychain.readAll();
    final value = all[entry.id];
    if (value == null) throw StateError('backup not found');
    return value;
  }

  @override
  Future<void> write(String payload) async {
    await _keychain.write(payload);
  }

  @override
  Future<void> delete(BackupEntry entry) => _keychain.delete(entry.id);
}

List<KeyBackupStore> defaultKeyBackupStores({
  KeyBackupConfig config = KeyBackupConfig.environment,
  TargetPlatform? platform,
}) {
  final p = platform ?? defaultTargetPlatform;
  return [
    if (config.appleEnabledOn(p)) AppleKeyBackupStore(config),
    if (config.googleEnabledOn(p)) GoogleKeyBackupStore(config),
  ];
}

final keyBackupStoresProvider =
    Provider<List<KeyBackupStore>>((ref) => defaultKeyBackupStores());

final keyBackupDeriverProvider =
    Provider<BackupKeyDeriver>((ref) => deriveBackupKey);
