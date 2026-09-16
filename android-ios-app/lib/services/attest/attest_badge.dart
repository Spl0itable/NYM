import 'dart:convert';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart' as crypto;

import '../../core/crypto/native_schnorr.dart';

/// Clamps a stored verified-app filter onto the options the UI offers.
/// The older three-way values both map onto the single enabled state.
String normalizeAppVerifiedFilter(String? raw) =>
    (raw == 'on' || raw == 'verified' || raw == 'any') ? 'on' : 'off';

/// Tier a badge asserts about the client that holds it.
///
/// [attested] is backed by Apple App Attest or Google Play Integrity — a blob
/// the platform's own root signs, covering the app's identity and the device's
/// state. [origin] is the web app, which cannot attest itself and is verified
/// only by request origin. The distinction is kept all the way to the UI
/// because calling both "verified" would overstate the second.
/// What a badge proves, strongest first.
///
/// [attested] is hardware-backed — Apple App Attest or Play Integrity — and no
/// third party can mint one. [challenged] is a browser that solved a
/// domain-bound challenge for its own enrollment: a real cost, but a
/// transferable one, so it is named apart rather than folded into [attested].
/// [origin] is a browser and nothing more.
enum AttestTier { attested, challenged, origin }

/// A badge issued by the attestation authority: a BIP340 signature over
/// (pubkey, expiry-day, tier), carried in a `nymattest` tag on channel
/// messages.
///
/// Verification is local and costs one schnorr verify, which is what makes
/// this usable as a per-message filter. The pubkey is inside the signed
/// digest, so a badge lifted from someone else's message verifies for them and
/// not for whoever copied it.
///
/// The wire format, and every rule below, mirrors `verifyBadge` in
/// nym-staging's `functions/api/_attest.js` and `verifyAttestBadge` in its
/// `js/modules/attest.js`. All three must agree or a badge minted for one
/// client reads as forged by another.
class AttestBadge {
  const AttestBadge({required this.tier, required this.expiryDay});

  static const String tagName = 'nymattest';
  static const String version = '1';
  static const int _msPerDay = 86400000;

  final AttestTier tier;
  final int expiryDay;

  static String _digest(String pubkey, int expiryDay, String tier) {
    final input = 'nymattest:$version:$pubkey:$expiryDay:$tier';
    return crypto.sha256.convert(utf8.encode(input)).toString();
  }

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

  static Uint8List? _base64Url(String s) {
    var t = s.replaceAll('-', '+').replaceAll('_', '/');
    while (t.length % 4 != 0) {
      t += '=';
    }
    try {
      return base64.decode(t);
    } catch (_) {
      return null;
    }
  }

  static String _hex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Verifies [badge] for [pubkey] against [authorityPubkey], returning null
  /// when it does not hold. [now] is injectable so expiry is testable.
  static AttestBadge? verify({
    required String badge,
    required String pubkey,
    required String authorityPubkey,
    DateTime? now,
  }) {
    if (!_hex64.hasMatch(pubkey) || !_hex64.hasMatch(authorityPubkey)) {
      return null;
    }
    final parts = badge.split('.');
    if (parts.length != 4 || parts[0] != version) return null;

    final AttestTier tier;
    switch (parts[1]) {
      case 'attested':
        tier = AttestTier.attested;
      case 'challenged':
        tier = AttestTier.challenged;
      case 'origin':
        tier = AttestTier.origin;
      default:
        return null;
    }

    final expiryDay = int.tryParse(parts[2], radix: 36);
    if (expiryDay == null || expiryDay <= 0) return null;
    final today = ((now ?? DateTime.now()).millisecondsSinceEpoch) ~/ _msPerDay;
    if (today > expiryDay) return null;

    final sig = _base64Url(parts[3]);
    if (sig == null || sig.length != 64) return null;

    final digest = _digest(pubkey, expiryDay, parts[1]);
    final sigHex = _hex(sig);
    final ok = NativeSchnorr.isAvailable
        ? NativeSchnorr.verify(
            pubkeyHex: authorityPubkey, idHex: digest, sigHex: sigHex)
        : _verifyPure(authorityPubkey, digest, sigHex);
    if (!ok) return null;

    return AttestBadge(tier: tier, expiryDay: expiryDay);
  }

  static bool _verifyPure(String pubkey, String digest, String sigHex) {
    try {
      return bip340.verify(pubkey, digest, sigHex);
    } catch (_) {
      return false;
    }
  }

  /// Reads the `nymattest` tag off an event's [tags], returning its raw value.
  static String? badgeFromTags(List<List<String>> tags) {
    for (final t in tags) {
      if (t.length >= 2 && t[0] == tagName) return t[1];
    }
    return null;
  }
}
