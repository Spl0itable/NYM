import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/storage_keys.dart';
import '../../models/nostr_event.dart';
import '../../services/storage/key_value_store.dart';
import '../api/api_client.dart';
import '../api/api_config.dart';
import '../nostr/event_signer.dart';
import 'attest_badge.dart';

/// Enrolls this identity with `/api/attest` and keeps the badge it gets back.
///
/// The platform proof is the whole point. Apple App Attest and Google Play
/// Integrity each return something their own root signs, covering the app's
/// identity and the device's state, over a challenge the server chose — which
/// a repackaged build, an emulator harness or a script cannot produce. The
/// badge the server returns in exchange is what other clients verify.
///
/// This mirrors `ensureAttestBadge` in nym-staging's `js/modules/attest.js`,
/// minus the web tier: a native install always has a real proof to offer, so
/// it never enrolls at `origin`.
class AttestService {
  AttestService({
    required KeyValueStore kv,
    http.Client? client,
    MethodChannel? channel,
    String? host,
    String? platform,
  })  : _kv = kv,
        _client = client ?? http.Client(),
        _channel = channel ?? const MethodChannel(channelName),
        _host = host ?? ApiConfig.apiHost,
        _platform = platform ?? Platform.operatingSystem;

  /// The tier the server named, defaulting to the weakest reading. An
  /// unknown name is a server newer than this build, and treating it as
  /// `attested` on a guess is the one wrong answer.
  static AttestTier _tierFromName(String? name) {
    switch (name) {
      case 'attested':
        return AttestTier.attested;
      case 'challenged':
        return AttestTier.challenged;
      default:
        return AttestTier.origin;
    }
  }

  /// Native side: `ios/Runner/AppAttestPlugin.swift` and
  /// `android/app/src/main/kotlin/.../PlayIntegrityPlugin.kt`.
  static const String channelName = 'app.nymchat/attest';

  /// Public key of the server's `ATTEST_AUTHORITY_SECRET`, as
  /// npub1rfymj0vm6dtjvuujj27556phcj2va0qxuarmhphnx29pgy8ugq8s3l03yh.
  /// Pinning it here is what stops a badge signed by anyone else from being
  /// accepted; when it is empty the service falls back to the key the API
  /// reports on first enrollment and remembers that, which is weaker (trust on
  /// first use).
  static const String pinnedAuthority =
      '1a49b93d9bd35726739292bd4a6837c494cebc06e747bb86f3328a1410fc400f';

  /// Renew with this much of the term left, so a device that spends a while
  /// offline still renews before peers stop trusting it.
  static const Duration renewBefore = Duration(days: 7);
  static const Duration retryAfter = Duration(hours: 6);

  final KeyValueStore _kv;
  final http.Client _client;
  final MethodChannel _channel;
  final String _host;
  final String _platform;

  Future<void>? _inFlight;
  DateTime? _nextTry;

  String? _badge;
  AttestTier? _tier;

  String? lastError;
  String? lastPlatformRefusal;
  DateTime? lastAttemptAt;

  Future<void>? get inFlight => _inFlight;

  /// The badge to attach to outgoing channel messages, or null when this
  /// install has not enrolled (or its enrollment lapsed).
  String? get badge => _badge;
  AttestTier? get tier => _tier;

  String get authorityPubkey {
    if (pinnedAuthority.length == 64) return pinnedAuthority;
    return _kv.getString(StorageKeys.attestAuthority) ?? '';
  }

  /// Tag list for [NostrService.publishChannelMessage].
  List<List<String>> tagsForEvent() => _badge == null
      ? const []
      : [
          [AttestBadge.tagName, _badge!]
        ];

  /// Loads a stored badge for [pubkey] into memory. Returns true when one is
  /// live; the caller still runs [ensureBadge] to renew a near-expired one.
  bool restore(String pubkey) {
    final raw = _kv.getString(StorageKeys.attestBadge);
    if (raw == null || raw.isEmpty) return false;
    try {
      final rec = jsonDecode(raw) as Map<String, dynamic>;
      if (rec['pubkey'] != pubkey) return false;
      final expiresAt = (rec['expiresAt'] as num?)?.toInt() ?? 0;
      if (expiresAt <= DateTime.now().millisecondsSinceEpoch) return false;
      _badge = rec['badge'] as String?;
      _tier = _tierFromName(rec['tier'] as String?);
      return _badge != null;
    } catch (_) {
      return false;
    }
  }

  DateTime? _storedExpiry(String pubkey) {
    final raw = _kv.getString(StorageKeys.attestBadge);
    if (raw == null || raw.isEmpty) return null;
    try {
      final rec = jsonDecode(raw) as Map<String, dynamic>;
      if (rec['pubkey'] != pubkey) return null;
      final ms = (rec['expiresAt'] as num?)?.toInt() ?? 0;
      return ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    } catch (_) {
      return null;
    }
  }

  /// Enrolls, or renews a badge nearing its end. Never throws: a failure just
  /// leaves this install unbadged, which costs it visibility to peers running
  /// the filter but does not stop it sending.
  Future<void> ensureBadge(EventSigner signer, {bool force = false}) {
    final existing = _inFlight;
    if (existing != null) return existing;

    final pubkey = signer.pubkey;
    restore(pubkey);
    final expiry = _storedExpiry(pubkey);
    if (!force &&
        expiry != null &&
        expiry.difference(DateTime.now()) > renewBefore) {
      return Future<void>.value();
    }
    final next = _nextTry;
    if (!force && next != null && DateTime.now().isBefore(next)) {
      return Future<void>.value();
    }

    final run = _enroll(signer).whenComplete(() => _inFlight = null);
    _inFlight = run;
    return run;
  }

  Future<void> _enroll(EventSigner signer) async {
    try {
      final pubkey = signer.pubkey;
      var issued = await _challenge(pubkey);
      if (issued == null) throw StateError('no challenge');

      final platformProof = await _platformProof(issued['challenge'] as String);
      Map<String, dynamic>? res;
      if (platformProof != null) {
        try {
          res = await _enrollWith(signer, issued, platformProof,
              mine: platformProof['platform'] == 'android');
          lastPlatformRefusal = null;
        } on EnrollRefused catch (e) {
          if (!e.platformRefusal) rethrow;
          lastPlatformRefusal = e.describe();
          issued = await _challenge(pubkey);
          if (issued == null) throw StateError('no challenge');
        }
      }
      if (res == null) {
        final web = await _webProof(issued);
        if (web == null) throw StateError('no proof');
        res = await _enrollWith(signer, issued, web, mine: true);
      }

      final badge = res['badge'] as String?;
      if (badge == null || badge.isEmpty) throw StateError('no badge');

      final authority = res['authority'] as String?;
      if (pinnedAuthority.length != 64 &&
          authority != null &&
          authority.length == 64) {
        _kv.setString(StorageKeys.attestAuthority, authority);
      }

      _badge = badge;
      _tier = _tierFromName(res['tier'] as String?);
      _kv.setString(
        StorageKeys.attestBadge,
        jsonEncode({
          'pubkey': pubkey,
          'badge': badge,
          'tier': res['tier'] ?? 'origin',
          'expiresAt': (res['expiresAt'] as num?)?.toInt() ?? 0,
        }),
      );
      _nextTry = null;
      lastError = null;
    } on EnrollRefused catch (e) {
      lastError = e.describe();
      _nextTry = DateTime.now().add(retryAfter);
    } catch (e) {
      lastError = e is StateError ? e.message : e.toString();
      _nextTry = DateTime.now().add(retryAfter);
    } finally {
      lastAttemptAt = DateTime.now();
    }
  }

  Future<Map<String, dynamic>> _enrollWith(
    EventSigner signer,
    Map<String, dynamic> issued,
    Map<String, dynamic> proof, {
    required bool mine,
  }) async {
    final challenge = issued['challenge'] as String;
    final powBits = mine ? ((issued['powBits'] as num?)?.toInt() ?? 0) : 0;
    final auth = await Nip98Auth.buildSigned(
      action: 'attest-enroll',
      url: _url(),
      signer: signer,
      sensitive: true,
      powBits: powBits,
      extraTags: [
        ['challenge', challenge]
      ],
    );
    if (auth == null) throw StateError('auth signing failed');
    final reply = await _post(<String, dynamic>{
      'action': 'enroll',
      'pubkey': signer.pubkey,
      'challenge': challenge,
      'auth': auth,
      ...proof,
    });
    final body = reply.body;
    if (reply.ok && body != null && body['error'] == null) return body;
    throw EnrollRefused(
      reply.status,
      (body?['error'] as String?) ?? 'HTTP ${reply.status}',
      body?['reason'] as String?,
    );
  }

  Future<Map<String, dynamic>?> _challenge(String pubkey) async {
    final reply = await _post(<String, dynamic>{
      'action': 'challenge',
      'pubkey': pubkey,
    });
    final body = reply.body;
    if (!reply.ok || body == null || body['error'] != null) return null;
    return body['challenge'] is String ? body : null;
  }

  /// Asks the native side for a platform proof over [challenge]. Returns the
  /// enrollment fields for this platform, or null when the device cannot
  /// attest — an older OS, a device without the hardware, a Play Services gap.
  /// Null enrolls nothing rather than falling back to a weaker claim.
  Future<Map<String, dynamic>?> _platformProof(String challenge) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'attest',
        <String, dynamic>{'challenge': challenge},
      );
      if (result == null) return null;
      final reason = result['reason'];
      if (reason is String && reason.isNotEmpty) {
        lastPlatformRefusal =
            _platform == 'android' ? 'play-integrity: $reason' : reason;
        return null;
      }
      if (_platform == 'ios') {
        final keyId = result['keyId'] as String?;
        final attestation = result['attestation'] as String?;
        if (keyId == null || attestation == null) return null;
        return {'platform': 'ios', 'keyId': keyId, 'attestation': attestation};
      }
      if (_platform == 'android') {
        final token = result['token'] as String?;
        if (token == null) return null;
        return {'platform': 'android', 'token': token};
      }
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// The build-proof enrollment: the web app's only path, and the fallback
  /// for a native install that could not produce a platform proof. It still
  /// names the platform it runs on — a phone that failed Play Integrity is
  /// an Android install, not a browser — and says why the platform proof
  /// was not accepted, so the server can record the reason.
  Future<Map<String, dynamic>?> _webProof(Map<String, dynamic> issued) async {
    final probe = issued['buildProbe'];
    if (probe is! List || probe.isEmpty) return null;
    final files = await _buildManifestFiles();
    if (files == null) return null;
    final build = <String, String>{};
    for (final path in probe) {
      final hash = path is String ? files[path] : null;
      if (hash is! String) return null;
      build[path as String] = hash;
    }
    final native = _platform == 'ios' || _platform == 'android';
    return {
      'platform': native ? _platform : 'web',
      'build': build,
      if (native) 'refusal': lastPlatformRefusal ?? 'no-platform-proof',
    };
  }

  Future<Map<String, dynamic>?> _buildManifestFiles() async {
    try {
      final resp = await _client.get(
        Uri.parse('https://$_host/build-manifest.json'),
        headers: ApiConfig.defaultHeaders,
      );
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      final files = decoded is Map ? decoded['files'] : null;
      return files is Map ? Map<String, dynamic>.from(files) : null;
    } catch (_) {
      return null;
    }
  }

  String _url() => 'https://$_host/api/attest';

  Future<_ApiReply> _post(Map<String, dynamic> body) async {
    final resp = await _client.post(
      Uri.parse(_url()),
      headers: {
        'Content-Type': 'application/json',
        ...ApiConfig.defaultHeaders,
      },
      body: jsonEncode(body),
    );
    Map<String, dynamic>? map;
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map) map = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return _ApiReply(resp.statusCode, map);
  }
}

class _ApiReply {
  const _ApiReply(this.status, this.body);
  final int status;
  final Map<String, dynamic>? body;
  bool get ok => status >= 200 && status < 300;
}

class EnrollRefused implements Exception {
  EnrollRefused(this.status, this.error, this.reason);
  final int status;
  final String error;
  final String? reason;

  bool get platformRefusal => status == 403 && error == 'Attestation failed';

  String describe() => reason == null ? error : '$error ($reason)';

  @override
  String toString() => describe();
}

/// Everyone whose badge this session has verified, and what it proved.
///
/// Remembered per pubkey rather than per message so a sender stays verified
/// across messages that arrive without the tag — an older build of theirs, a
/// mesh replay, an edit. `attested` never decays to `origin`: the same person
/// on a phone and on the web is still that person.
class AttestRegistry {
  final Map<String, AttestTier> _tiers = <String, AttestTier>{};
  final Map<String, AttestTier?> _badgeCache = <String, AttestTier?>{};

  static const int _maxTiers = 20000;
  static const int _maxBadgeCache = 4000;

  AttestTier? tierOf(String pubkey) => _tiers[pubkey];

  /// Verifies the badge on [event] (if any) and records what it proves.
  /// [now] is injectable so expiry is testable against a fixed badge.
  AttestTier? ingest(NostrEvent event, String authorityPubkey,
      {DateTime? now}) {
    if (authorityPubkey.length != 64) return null;
    final badge = AttestBadge.badgeFromTags(event.tags);
    if (badge == null) return null;

    // Keyed by the authority too: before enrollment there is no key to verify
    // against, and those misses must not outlive the moment one arrives.
    final cacheKey = '$authorityPubkey|${event.pubkey}|$badge';
    final AttestTier? tier;
    if (_badgeCache.containsKey(cacheKey)) {
      tier = _badgeCache[cacheKey];
    } else {
      tier = AttestBadge.verify(
        badge: badge,
        pubkey: event.pubkey,
        authorityPubkey: authorityPubkey,
        now: now,
      )?.tier;
      if (_badgeCache.length > _maxBadgeCache) _badgeCache.clear();
      _badgeCache[cacheKey] = tier;
    }
    if (tier == null) return null;

    // Keep the strongest tier ever seen for a key rather than the most recent.
    // AttestTier is declared strongest first, so a lower index wins: the same
    // person on a phone and on the web is still that person, and a challenged
    // sender must not decay to origin either.
    final prev = _tiers[event.pubkey];
    if (prev == null || tier.index < prev.index) {
      _tiers[event.pubkey] = tier;
    }
    if (_tiers.length > _maxTiers) {
      final keep =
          _tiers.entries.skip(_tiers.length - (_maxTiers ~/ 2)).toList();
      _tiers
        ..clear()
        ..addEntries(keep);
    }
    return tier;
  }

  void clear() {
    _tiers.clear();
    _badgeCache.clear();
  }
}
