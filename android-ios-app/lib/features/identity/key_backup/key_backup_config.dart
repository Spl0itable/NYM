import 'package:flutter/foundation.dart';

const String kDefaultPasskeyRpId = 'web.nymchat.app';
const String kGoogleIosClientId =
    '435441872913-8lb1h9498kapbl00am68t046it4dv0iu.apps.googleusercontent.com';
const String kGoogleWebClientId =
    '435441872913-ccmsrqp8nsi3vqm27cptpsld3kqb5i2g.apps.googleusercontent.com';
const String kAppleKeychainGroup = 'KJ6U2Y9B2M.com.nym.shared';

class KeyBackupConfig {
  const KeyBackupConfig({
    this.googleIosClientId = '',
    this.googleServerClientId = '',
    this.appleBackup = false,
    this.appleKeychainGroup = '',
    this.passkeyBackup = false,
    this.passkeyRpId = kDefaultPasskeyRpId,
  });

  static const KeyBackupConfig environment = KeyBackupConfig(
    googleIosClientId: String.fromEnvironment('GOOGLE_IOS_CLIENT_ID',
        defaultValue: kGoogleIosClientId),
    googleServerClientId: String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID',
        defaultValue: kGoogleWebClientId),
    appleBackup:
        String.fromEnvironment('APPLE_BACKUP', defaultValue: 'true') == 'true',
    appleKeychainGroup: String.fromEnvironment('APPLE_KEYCHAIN_GROUP',
        defaultValue: kAppleKeychainGroup),
    passkeyBackup:
        String.fromEnvironment('PASSKEY_BACKUP', defaultValue: 'true') == 'true',
    passkeyRpId: String.fromEnvironment('PASSKEY_RP_ID',
        defaultValue: kDefaultPasskeyRpId),
  );

  final String googleIosClientId;
  final String googleServerClientId;
  final bool appleBackup;
  final String appleKeychainGroup;
  final bool passkeyBackup;
  final String passkeyRpId;

  bool googleEnabledOn(TargetPlatform platform, {bool web = kIsWeb}) {
    if (web) return false;
    switch (platform) {
      case TargetPlatform.android:
        return googleServerClientId.isNotEmpty;
      case TargetPlatform.iOS:
        return googleIosClientId.isNotEmpty;
      default:
        return false;
    }
  }

  bool passkeyEnabledOn(TargetPlatform platform, {bool web = kIsWeb}) =>
      !web &&
      passkeyBackup &&
      passkeyRpId.isNotEmpty &&
      (platform == TargetPlatform.iOS || platform == TargetPlatform.android);

  bool appleEnabledOn(TargetPlatform platform, {bool web = kIsWeb}) =>
      !web && appleBackup && platform == TargetPlatform.iOS;

  String? get googleClientIdForIos =>
      googleIosClientId.isEmpty ? null : googleIosClientId;

  String? get googleServerClientIdOrNull =>
      googleServerClientId.isEmpty ? null : googleServerClientId;

  String? get appleKeychainGroupOrNull =>
      appleKeychainGroup.isEmpty ? null : appleKeychainGroup;
}
