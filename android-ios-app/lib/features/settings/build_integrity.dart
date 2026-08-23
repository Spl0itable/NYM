// build_integrity.dart — whether this install is the build the developer
// published.
//
// The web app re-hashes every file it is running and looks the result up in the
// repository's signed build attestations, so its About panel reports a real
// verdict. A native build cannot do the same thing with its own source: what
// runs on the device is AOT machine code, not the Dart in `android-ios-app/`,
// and no computation available on the device relates one to the other.
//
// What Android does offer is the installed APK, readable by the app at
// `ApplicationInfo.sourceDir`. That makes the same SHAPE of proof available:
// hash the artifact here, compare against a hash the developer published and
// signed, and let neither half vouch for the other.
//
// The published half is Zapstore's own release event — the one the listing at
// zapstore.dev/apps/com.nym.bar already shows. `zsp publish` emits a NIP-82
// kind-3063 Software Asset event for every release, signed with the
// publisher's Nostr key, carrying the APK's SHA-256 in its `x` tag and the
// signing certificate's SHA-256 in `apk_certificate_hash`. Reading that rather
// than a manifest of our own means there is no second publishing step to
// remember, no second thing to keep in step with the release, and the value
// being checked is the same one Zapstore serves the download against.
//
// It does NOT make the app self-certifying. Whoever modifies an app can delete
// the check along with everything else, so a green verdict proves nothing to
// someone holding a tampered build. What it proves is the ordinary case: that
// the copy you installed is bit-for-bit the copy that was published — and
// anyone else can repeat both halves, because the event is public and the APK
// is downloadable.
//
// iOS is out of reach entirely. App Store binaries are FairPlay-encrypted per
// download and re-signed per install, so a hash computed on the device is
// device-specific and matches nothing publishable.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';

/// The relay `zsp publish` writes to by default, and the one Zapstore's own
/// client reads. Queried directly rather than through the app's relay pool:
/// this is a one-shot lookup against someone else's relay, not part of the
/// user's own relay set.
const String kZapstoreRelay = 'wss://relay.zapstore.dev';

/// NIP-82 Software Asset — binary metadata for one published artifact.
const int kZapstoreAssetKind = 3063;

/// The Android application id, matching the asset event's `i` tag.
const String kAndroidAppId = 'com.nym.bar';

/// Play's own package name — an install it made is not the published artifact.
const String kPlayInstaller = 'com.android.vending';

/// What the app could establish about the copy of itself that is running.
enum BuildIntegrityState {
  /// The installed APK matches a hash in the signed manifest.
  verified,

  /// The APK hashes cleanly but matches nothing the manifest publishes for
  /// this version. Either it was modified, or it was built by someone else.
  mismatch,

  /// Installed from Google Play, which re-signs the upload and delivers
  /// per-device splits — the bytes on the device are not the published file,
  /// so there is nothing to compare. Not a failure.
  storeRepackaged,

  /// The manifest could not be fetched, or its signature did not check out.
  provenanceUnreachable,

  /// The manifest publishes nothing for this version yet.
  notPublished,

  /// This platform cannot measure itself (iOS, web, desktop).
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

  /// Split APKs alongside the base one. A universal sideloaded APK has none.
  final int splitCount;

  /// Hex SHA-256 of the signing certificate.
  final String? signerSha256;

  /// Package that performed the install, e.g. `com.android.vending` for Play.
  final String? installer;

  final String? versionName;
  final int? versionCode;

  /// True when the bytes on this device cannot be the published artifact:
  /// Play re-signs the App Bundle and generates splits per device.
  bool get isStoreRepackaged =>
      installer == kPlayInstaller || splitCount > 0;
}

/// One published artifact, from a Zapstore kind-3063 Software Asset event.
@immutable
class PublishedBuild {
  const PublishedBuild({
    required this.version,
    this.versionCode,
    this.apkSha256 = '',
    this.certSha256,
    this.platform,
  });

  /// Reads one asset event's tags. Returns null when the event is not an
  /// asset for [appId], or carries no hash to compare against.
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

  /// The `f` tag, e.g. `android-arm64-v8a`. Several assets can share a version
  /// when a release ships one APK per ABI.
  final String? platform;
}

/// The verdict, plus the values a reader needs to check it off-device.
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

/// The verdict for one measurement, as a pure function so every branch is
/// testable without a device or a relay.
///
/// [provenanceOk] is false when the release events could not be fetched OR
/// none of them verified — the two are deliberately one state, because an
/// unverifiable claim is worth exactly as much as a missing one.
BuildIntegrityResult describeBuildIntegrity({
  required NativeBuildInfo? info,
  required bool provenanceOk,
  required List<PublishedBuild> builds,
}) {
  if (info == null || info.apkSha256 == null) {
    return const BuildIntegrityResult(state: BuildIntegrityState.unsupported);
  }
  // Checked FIRST: on a Play install the answer is the same whether or not the
  // lookup succeeded, and reporting a network problem would imply a check that
  // was never going to run.
  if (info.isStoreRepackaged) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.storeRepackaged, info: info);
  }
  if (!provenanceOk) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.provenanceUnreachable, info: info);
  }

  // The hash is the check. A matching APK hash is conclusive on its own, and
  // it is matched across EVERY published asset rather than only those tagged
  // with this version: an asset's `version` tag is what the publisher typed,
  // while the hash is what the bytes are.
  for (final build in builds) {
    if (build.apkSha256 == info.apkSha256) {
      return BuildIntegrityResult(
        state: BuildIntegrityState.verified,
        info: info,
        published: build,
      );
    }
  }

  // No hash matched. Distinguish "this version was never published" — the
  // ordinary case for a build newer than the listing, and not a fault — from
  // "this version was published and the bytes are different", which is.
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

/// The published assets carried by [events], keeping only those signed by
/// [publisherPubkey] and describing [appId].
///
/// An event that does not verify is dropped rather than read: the relay is
/// someone else's, and anyone can publish a kind-3063 event claiming any hash.
/// Pinning the publisher key is what makes the answer mean anything.
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

/// Opens one short-lived socket to a relay, asks for the app's release assets,
/// and returns what arrives before EOSE or the deadline.
///
/// Deliberately not routed through the app's relay pool: this is a one-shot
/// lookup against Zapstore's relay, not part of the user's own relay set, and
/// it should not disturb (or be disturbed by) their connections.
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
          // A frame we can't read is not a reason to abandon the ones we can.
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

  /// The pinned key the release events must be signed with. Without it the
  /// check would accept a hash from anyone who can write to the relay.
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

  /// True once a publisher key is configured. Without one there is nothing to
  /// check against, and the panel says so rather than reporting a failure.
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
    // Skip the network entirely on a Play install: nothing it returned could
    // change the answer.
    if (info != null && info.isStoreRepackaged) {
      return BuildIntegrityResult(
          state: BuildIntegrityState.storeRepackaged, info: info);
    }
    if (!isConfigured) {
      return BuildIntegrityResult(
          state: BuildIntegrityState.provenanceUnreachable, info: info);
    }
    final builds = await fetchPublished();
    // An empty result is ambiguous — nothing published, or the relay never
    // answered — so it reads as unreachable rather than claiming the build is
    // unpublished. `notPublished` is reserved for a lookup that DID return
    // assets, none of them for this version.
    return describeBuildIntegrity(
      info: info,
      provenanceOk: builds.isNotEmpty,
      builds: builds,
    );
  }
}
