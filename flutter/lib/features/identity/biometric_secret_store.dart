import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../i18n/i18n.dart';

abstract class BiometricSecretStore {
  Future<bool> isAvailable();
  Future<String?> read();
  Future<void> write(String secret);
  Future<void> delete();
  Future<bool> confirmPresence();
}

class BiometricCanceled implements Exception {
  const BiometricCanceled();
}

class BiometricStoreError implements Exception {
  const BiometricStoreError(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail ?? code;
}

enum BiometricVaultFailure {
  unavailable,
  canceled,
  verifyFailed,
  invalidated,
  failed,
}

class BiometricVaultException implements Exception {
  const BiometricVaultException(this.failure);

  final BiometricVaultFailure failure;

  String get message => switch (failure) {
        BiometricVaultFailure.unavailable =>
          tr("This device can't keep a key behind its biometric lock. Choose a "
              'password or PIN instead.'),
        BiometricVaultFailure.canceled => tr('Biometric unlock was canceled.'),
        BiometricVaultFailure.verifyFailed =>
          tr('Biometric setup could not be verified. Encryption was not turned '
              'on.'),
        BiometricVaultFailure.invalidated => tr(
            'The fingerprints or face enrolled on this device have changed, so '
            'it no longer releases your identity key. Forget this identity and '
            'restore it with your saved nsec.'),
        BiometricVaultFailure.failed => tr('Biometric authentication failed.'),
      };

  @override
  String toString() => message;
}

class PlatformBiometricSecretStore implements BiometricSecretStore {
  PlatformBiometricSecretStore([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  static const MethodChannel channel = MethodChannel('app.nymchat/vault_key');

  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      if (!await _auth.isDeviceSupported() || !await _auth.canCheckBiometrics) {
        return false;
      }
      final types = await _auth.getAvailableBiometrics();
      return types.any((type) => type != BiometricType.weak);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> read() => _call<String>('load', {
        'title': tr('Unlock your Nymchat identity'),
        'cancel': tr('Cancel'),
      });

  @override
  Future<void> write(String secret) => _call<void>('store', {
        'secret': secret,
        'title': tr('Unlock your Nymchat identity'),
        'cancel': tr('Cancel'),
      });

  @override
  Future<void> delete() async {
    try {
      await channel.invokeMethod<void>('erase');
    } catch (_) {}
  }

  @override
  Future<bool> confirmPresence() async {
    try {
      return await _auth.authenticate(
        localizedReason: tr('Unlock your Nymchat identity'),
        options: const AuthenticationOptions(biometricOnly: true),
      );
    } catch (_) {
      return false;
    }
  }

  static Future<T?> _call<T>(String method, Map<String, String> args) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'cancelled':
          throw const BiometricCanceled();
        case 'invalidated':
          return null;
        default:
          throw BiometricStoreError(e.code, e.message);
      }
    } on MissingPluginException catch (e) {
      throw BiometricStoreError('missing', e.message);
    }
  }
}
