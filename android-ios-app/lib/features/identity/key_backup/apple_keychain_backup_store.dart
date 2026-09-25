import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

const String kAppleBackupService = 'com.nym.apple-backup';

final RegExp kAppleBackupAccountPattern = RegExp(r'^nym_bk_[0-9a-f-]{36}$');

class AppleKeychainBackupStore {
  AppleKeychainBackupStore({
    FlutterSecureStorage? storage,
    String? accessGroup,
    String Function()? newId,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _accessGroup = accessGroup,
        _newId = newId ?? (() => const Uuid().v4());

  final FlutterSecureStorage _storage;
  final String? _accessGroup;
  final String Function() _newId;

  IOSOptions get options => IOSOptions(
        accountName: kAppleBackupService,
        groupId: _accessGroup,
        accessibility: KeychainAccessibility.first_unlock,
        synchronizable: true,
      );

  Future<Map<String, String>> readAll() async {
    final all = await _storage.readAll(iOptions: options);
    return {
      for (final e in all.entries)
        if (kAppleBackupAccountPattern.hasMatch(e.key)) e.key: e.value,
    };
  }

  Future<String> write(String payload) async {
    final account = 'nym_bk_${_newId().toLowerCase()}';
    await _storage.write(key: account, value: payload, iOptions: options);
    return account;
  }

  Future<void> delete(String account) =>
      _storage.delete(key: account, iOptions: options);
}
