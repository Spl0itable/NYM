import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../share_links.dart';

const String kAppShareChannel = 'app.nymchat/app_share';
const String kApkMime = 'application/vnd.android.package-archive';
const String kPlayInstaller = 'com.android.vending';
const List<String> kUniversalAbis = ['arm64-v8a', 'armeabi-v7a'];

enum AppShareMode { apk, qr }

AppShareMode appShareModeFor({
  required String platform,
  int? splitCount,
  String? installer,
  List<String>? abis,
}) {
  if (platform != 'android') return AppShareMode.qr;
  if (splitCount != 0) return AppShareMode.qr;
  if (installer == kPlayInstaller) return AppShareMode.qr;
  final have = abis ?? const <String>[];
  if (!kUniversalAbis.every(have.contains)) return AppShareMode.qr;
  return AppShareMode.apk;
}

final RegExp _sha256Hex = RegExp(r'^[0-9a-fA-F]{64}$');

String? formatFingerprint(String? hex) {
  if (hex == null || !_sha256Hex.hasMatch(hex)) return null;
  final up = hex.toUpperCase();
  return [for (var i = 0; i < up.length; i += 2) up.substring(i, i + 2)]
      .join(':');
}

class AppLinkChoice {
  const AppLinkChoice(this.label, this.url);
  final String label;
  final String url;
}

List<AppLinkChoice> appLinkChoices(String platform) => [
      const AppLinkChoice('Get Nymchat', ShareAppLinks.downloadPage),
      const AppLinkChoice('Web app', ShareAppLinks.webApp),
      if (platform == 'android') ...const [
        AppLinkChoice('Google Play', ShareAppLinks.googlePlay),
        AppLinkChoice('Zapstore', ShareAppLinks.zapstore),
      ] else
        const AppLinkChoice('App Store (TestFlight)', ShareAppLinks.iosTestFlight),
    ];

final RegExp _unsafeName = RegExp(r'[^A-Za-z0-9._+-]');

class ApkInfo {
  const ApkInfo({
    required this.path,
    required this.sizeBytes,
    required this.splitCount,
    required this.installer,
    required this.versionName,
    required this.versionCode,
    required this.signerSha256,
    required this.abis,
  });

  static ApkInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final size = raw['sizeBytes'];
    final splits = raw['splitCount'];
    final installer = raw['installer'];
    final name = raw['versionName'];
    final code = raw['versionCode'];
    final signer = raw['signerSha256'];
    final abis = raw['abis'];
    if (path is! String || path.isEmpty) return null;
    if (size is! int || size < 0) return null;
    if (splits is! int || splits < 0) return null;
    if (name is! String || code is! int) return null;
    return ApkInfo(
      path: path,
      sizeBytes: size,
      splitCount: splits,
      installer: installer is String ? installer : null,
      versionName: name,
      versionCode: code,
      signerSha256: signer is String ? signer : null,
      abis: abis is List ? List.unmodifiable(abis.whereType<String>()) : const [],
    );
  }

  final String path;
  final int sizeBytes;
  final int splitCount;
  final String? installer;
  final String versionName;
  final int versionCode;
  final String? signerSha256;
  final List<String> abis;

  String get fileName =>
      'Nymchat-${versionName.replaceAll(_unsafeName, '_')}-$versionCode.apk';

  String? get fingerprint => formatFingerprint(signerSha256);

  AppShareMode get mode => appShareModeFor(
        platform: 'android',
        splitCount: splitCount,
        installer: installer,
        abis: abis,
      );
}

abstract class AppShareChannel {
  Future<ApkInfo?> apkInfo();
  Future<String?> prepareCopy();
  Future<void> clearCopies();
}

class MethodChannelAppShare implements AppShareChannel {
  MethodChannelAppShare([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(kAppShareChannel);
  final MethodChannel _channel;

  Future<Object?> _call(String method) async {
    try {
      return await _channel.invokeMethod<Object?>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<ApkInfo?> apkInfo() async => ApkInfo.fromMap(await _call('apkInfo'));

  @override
  Future<String?> prepareCopy() async {
    final p = await _call('prepareCopy');
    return p is String && p.isNotEmpty ? p : null;
  }

  @override
  Future<void> clearCopies() => _call('clearCopies');
}

String appSharePlatform() {
  if (kIsWeb) return 'web';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  return 'web';
}

final appSharePlatformProvider = Provider<String>((ref) => appSharePlatform());

final appShareChannelProvider =
    Provider<AppShareChannel>((ref) => MethodChannelAppShare());
