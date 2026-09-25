import 'dart:typed_data';

import 'package:nym_bar/features/identity/key_backup/passkey_backup_crypto.dart';
import 'package:nym_bar/features/identity/key_backup/passkey_backup_service.dart';
import 'package:nym_bar/models/nostr_event.dart';

class FakePasskeyPlatform implements PasskeyPlatform {
  FakePasskeyPlatform({this.prf});

  Uint8List? prf;
  bool prfEnabled = true;
  bool prfAtCreate = true;
  bool largeBlob = false;
  bool blobWriteWorks = true;
  bool available = true;
  PasskeyBackupError? createError;
  PasskeyBackupError? getError;
  Uint8List? storedBlob;
  bool hasCredential = false;
  final Uint8List credentialId = Uint8List.fromList([9, 9, 9]);
  final List<String> calls = [];
  Map<String, Object?>? lastCreate;
  Map<String, Object?>? lastGet;

  Uint8List? _prfCopy() => prf == null ? null : Uint8List.fromList(prf!);

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<PasskeyCreateResult> create({
    required String rpId,
    required String rpName,
    required Uint8List userId,
    required String userName,
    required Uint8List challenge,
    required Uint8List prfSalt,
  }) async {
    calls.add('create');
    lastCreate = {
      'rpId': rpId,
      'rpName': rpName,
      'userId': userId,
      'userName': userName,
      'prfSalt': prfSalt,
    };
    final error = createError;
    if (error != null) throw PasskeyBackupException(error);
    hasCredential = true;
    return PasskeyCreateResult(
      credentialId: credentialId,
      prfFirst: prfAtCreate ? _prfCopy() : null,
      prfEnabled: prf != null && prfEnabled,
      largeBlobSupported: largeBlob,
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
    calls.add('get');
    lastGet = {
      'rpId': rpId,
      'prfSalt': prfSalt,
      'allowCredentials': allowCredentials,
      'largeBlobRead': largeBlobRead,
      'largeBlobWrite': largeBlobWrite,
    };
    final error = getError;
    if (error != null) throw PasskeyBackupException(error);
    if (!hasCredential && allowCredentials.isEmpty) {
      throw const PasskeyBackupException(PasskeyBackupError.noCredential);
    }
    bool? written;
    if (largeBlobWrite != null) {
      written = largeBlob && blobWriteWorks;
      if (written) storedBlob = Uint8List.fromList(largeBlobWrite);
    }
    return PasskeyGetResult(
      credentialId: credentialId,
      prfFirst: prfSalt != null && prfEnabled ? _prfCopy() : null,
      largeBlob: largeBlobRead && storedBlob != null
          ? Uint8List.fromList(storedBlob!)
          : null,
      largeBlobWritten: written,
    );
  }
}

class FakeRelays implements PasskeyRelayClient {
  bool accept = true;
  final List<NostrEvent> published = [];
  List<String> publishedTo = [];
  List<String> queriedFrom = [];
  Map<String, Object>? lastFilter;

  @override
  Future<int> publish(NostrEvent event, List<String> relays) async {
    publishedTo = relays;
    if (!accept) return 0;
    published.add(event);
    return relays.length;
  }

  @override
  Future<List<NostrEvent>> query(
      Map<String, Object> filter, List<String> relays) async {
    queriedFrom = relays;
    lastFilter = filter;
    final authors = filter['authors'] as List;
    return published
        .where((e) =>
            authors.contains(e.pubkey) && e.tagValue('d') == kPasskeyBackupDTag)
        .toList();
  }
}

PasskeyBackupService fakePasskeyService(
        FakePasskeyPlatform platform, FakeRelays relays) =>
    PasskeyBackupService(
      rpId: 'web.nymchat.app',
      platform: platform,
      relays: relays,
      publishRelays: const ['wss://a', 'wss://b'],
      queryRelays: const ['wss://a'],
    );
