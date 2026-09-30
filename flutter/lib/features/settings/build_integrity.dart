// Android-only build check: hashes the installed APK against Zapstore's signed NIP-82 release event.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';

/// Zapstore's relay, queried directly rather than through the user's relay pool.
const String kZapstoreRelay = 'wss://relay.zapstore.dev';

/// NIP-82 Software Asset: metadata for one published artifact.
const int kZapstoreAssetKind = 3063;

/// Android application id, matching the asset event's `i` tag.
const String kAndroidAppId = 'com.nym.bar';

/// Play's package name; a Play install isn't the published artifact.
const String kPlayInstaller = 'com.android.vending';

/// What the app could establish about the running copy.
enum BuildIntegrityState {
  /// The installed APK matches a published hash.
  verified,

  /// Hashes cleanly but matches nothing published for this version: modified or built elsewhere.
  mismatch,

  /// Play re-signs and splits the upload, so there is nothing to compare; not a failure.
  storeRepackaged,

  /// Release events unfetchable or failed signature checks.
  provenanceUnreachable,

  /// Nothing is published for this version yet.
  notPublished,

  /// This platform can't measure itself (iOS, web, desktop).
  unsupported,
}

/// What the native side measured about the install.
@immutable
class NativeBuildInfo {
  const NativeBuildInfo({
    this.packageName,
    this.apkSha256,
    this.splitCount = 0,
    this.signerSha256,
    this.installer,
    this.versionName,
    this.versionCode,
  });

  factory NativeBuildInfo.fromMap(Map<Object?, Object?> map) {
    String? str(String key) {
      final v = map[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final code = map['versionCode'];
    return NativeBuildInfo(
      packageName: str('packageName'),
      apkSha256: str('apkSha256')?.toLowerCase(),
      splitCount: map['splitCount'] is int ? map['splitCount'] as int : 0,
      signerSha256: str('signerSha256')?.toLowerCase(),
      installer: str('installer'),
      versionName: str('versionName'),
      versionCode: code is int ? code : (code is num ? code.toInt() : null),
    );
  }

  final String? packageName;

  /// Hex SHA-256 of the base APK on disk.
  final String? apkSha256;

  /// Split APKs alongside the base; a universal sideloaded APK has none.
  final int splitCount;

  /// Hex SHA-256 of the signing certificate.
  final String? signerSha256;

  /// Installing package, e.g. `com.android.vending` for Play.
  final String? installer;

  final String? versionName;
  final int? versionCode;

  /// True when Play re-signed and split the bytes, so they can't be the published artifact.
  bool get isStoreRepackaged =>
      installer == kPlayInstaller || splitCount > 0;
}

/// One published artifact from a Zapstore kind-3063 event.
@immutable
class PublishedBuild {
  const PublishedBuild({
    required this.version,
    this.versionCode,
    this.apkSha256 = '',
    this.certSha256,
    this.platform,
  });

  /// Null unless the event is an asset for [appId] with a hash to compare.
  static PublishedBuild? fromEvent(NostrEvent event, {required String appId}) {
    if (event.kind != kZapstoreAssetKind) return null;
    String? first(String name) {
      for (final t in event.tags) {
        if (t.length > 1 && t[0] == name) return t[1];
      }
      return null;
    }

    if (first('i') != appId) return null;
    final x = first('x')?.toLowerCase();
    if (x == null || x.isEmpty) return null;
    final code = int.tryParse(first('version_code') ?? '');
    return PublishedBuild(
      version: first('version') ?? '',
      versionCode: code,
      apkSha256: x,
      certSha256: first('apk_certificate_hash')?.toLowerCase(),
      platform: first('f'),
    );
  }

  final String version;
  final int? versionCode;

  /// The `x` tag: SHA-256 of the published APK.
  final String apkSha256;

  /// The `apk_certificate_hash` tag: SHA-256 of the signing certificate.
  final String? certSha256;

  /// The `f` tag, e.g. `android-arm64-v8a`; a release may ship one APK per ABI.
  final String? platform;
}

/// The verdict, plus the values needed to check it off-device.
@immutable
class BuildIntegrityResult {
  const BuildIntegrityResult({
    required this.state,
    this.info,
    this.published,
  });

  final BuildIntegrityState state;
  final NativeBuildInfo? info;
  final PublishedBuild? published;

  bool get isVerified => state == BuildIntegrityState.verified;
}

/// Pure verdict; [provenanceOk] is false when events are unfetchable or unverified, since both are worth the same.
BuildIntegrityResult describeBuildIntegrity({
  required NativeBuildInfo? info,
  required bool provenanceOk,
  required List<PublishedBuild> builds,
}) {
  if (info == null || info.apkSha256 == null) {
    return const BuildIntegrityResult(state: BuildIntegrityState.unsupported);
  }
  // Checked first: on a Play install the lookup can't change the answer.
  if (info.isStoreRepackaged) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.storeRepackaged, info: info);
  }
  if (!provenanceOk) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.provenanceUnreachable, info: info);
  }

  // Match the hash across every published asset; the version tag is typed by the publisher, the hash is the bytes.
  for (final build in builds) {
    if (build.apkSha256 == info.apkSha256) {
      return BuildIntegrityResult(
        state: BuildIntegrityState.verified,
        info: info,
        published: build,
      );
    }
  }

  // No hash matched: distinguish an unpublished version (not a fault) from different bytes (a fault).
  final sameVersion = builds
      .where((b) =>
          (b.version.isNotEmpty && b.version == info.versionName) ||
          (b.versionCode != null && b.versionCode == info.versionCode))
      .toList();
  if (sameVersion.isEmpty) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.notPublished, info: info);
  }
  return BuildIntegrityResult(
    state: BuildIntegrityState.mismatch,
    info: info,
    published: sameVersion.first,
  );
}

/// Assets signed by the pinned [publisherPubkey] for [appId]; unverified events are dropped since anyone can publish one.
List<PublishedBuild> zapstoreAssets(
  Iterable<NostrEvent> events, {
  required String publisherPubkey,
  String appId = kAndroidAppId,
}) {
  final out = <PublishedBuild>[];
  for (final event in events) {
    if (event.pubkey != publisherPubkey) continue;
    try {
      if (!schnorr.verifyEvent(event)) continue;
    } catch (_) {
      continue;
    }
    final build = PublishedBuild.fromEvent(event, appId: appId);
    if (build != null) out.add(build);
  }
  return out;
}

/// One short-lived socket per lookup, kept separate from the user's relay pool.
typedef ZapstoreSocketFactory = WebSocketChannel Function(Uri url);

Future<List<NostrEvent>> fetchZapstoreAssets({
  required String publisherPubkey,
  String appId = kAndroidAppId,
  String relay = kZapstoreRelay,
  ZapstoreSocketFactory? socketFactory,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final open = socketFactory ?? WebSocketChannel.connect;
  WebSocketChannel? channel;
  try {
    channel = open(Uri.parse(relay));
    final subId = 'nym-bi-${DateTime.now().microsecondsSinceEpoch}';
    final events = <NostrEvent>[];
    final done = Completer<void>();

    final sub = channel.stream.listen(
      (raw) {
        try {
          final msg = jsonDecode(raw as String);
          if (msg is! List || msg.isEmpty) return;
          if (msg[0] == 'EVENT' && msg.length > 2 && msg[1] == subId) {
            events.add(
                NostrEvent.fromJson(msg[2] as Map<String, dynamic>));
          } else if (msg[0] == 'EOSE' && msg.length > 1 && msg[1] == subId) {
            if (!done.isCompleted) done.complete();
          }
        } catch (_) {
          // An unreadable frame doesn't abandon the readable ones.
        }
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );

    channel.sink.add(jsonEncode([
      'REQ',
      subId,
      {
        'kinds': [kZapstoreAssetKind],
        'authors': [publisherPubkey],
        '#i': [appId],
        'limit': 50,
      }
    ]));

    await done.future.timeout(timeout, onTimeout: () {});
    await sub.cancel();
    return events;
  } catch (_) {
    return const [];
  } finally {
    try {
      await channel?.sink.close();
    } catch (_) { }
  }
}

/// Measures the install and checks it against Zapstore's published assets.
class BuildIntegrityService {
  BuildIntegrityService({
    MethodChannel? channel,
    this.relay = kZapstoreRelay,
    this.appId = kAndroidAppId,
    this.socketFactory,
    required this.publisherPubkey,
  }) : _channel = channel ?? const MethodChannel(channelName);

  /// Shared with `MainActivity.kt`.
  static const String channelName = 'app.nymchat/build_integrity';

  final MethodChannel _channel;
  final String relay;
  final String appId;
  final ZapstoreSocketFactory? socketFactory;

  /// Pinned key release events must be signed with.
  final String publisherPubkey;

  /// Only Android can read and hash its own installed artifact.
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Without a publisher key the panel says so rather than reporting a failure.
  bool get isConfigured => publisherPubkey.length == 64;

  Future<NativeBuildInfo?> measure() async {
    if (!isSupported) return null;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('inspect');
      return raw == null ? null : NativeBuildInfo.fromMap(raw);
    } catch (_) {
      return null;
    }
  }

  Future<List<PublishedBuild>> fetchPublished() async {
    final events = await fetchZapstoreAssets(
      publisherPubkey: publisherPubkey,
      appId: appId,
      relay: relay,
      socketFactory: socketFactory,
    );
    return zapstoreAssets(events,
        publisherPubkey: publisherPubkey, appId: appId);
  }

  Future<BuildIntegrityResult> run() async {
    if (!isSupported) {
      return const BuildIntegrityResult(state: BuildIntegrityState.unsupported);
    }
    final info = await measure();
    // Skip the network on a Play install.
    if (info != null && info.isStoreRepackaged) {
      return BuildIntegrityResult(
          state: BuildIntegrityState.storeRepackaged, info: info);
    }
    if (!isConfigured) {
      return BuildIntegrityResult(
          state: BuildIntegrityState.provenanceUnreachable, info: info);
    }
    final builds = await fetchPublished();
    // An empty result is ambiguous, so it reads as unreachable; `notPublished` needs returned assets.
    return describeBuildIntegrity(
      info: info,
      provenanceOk: builds.isNotEmpty,
      builds: builds,
    );
  }
}
