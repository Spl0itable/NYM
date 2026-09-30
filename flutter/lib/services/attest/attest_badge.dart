import 'dart:convert';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart' as crypto;

import '../../core/crypto/native_schnorr.dart';

/// Clamps a stored verified-app filter onto the options the UI offers.
String normalizeAppVerifiedFilter(String? raw) =>
    (raw == 'on' || raw == 'verified' || raw == 'any') ? 'on' : 'off';

/// What a badge proves, strongest first: hardware attestation, browser challenge, origin only.
enum AttestTier { attested, challenged, origin }

/// Authority BIP340 signature over (pubkey, expiry-day, tier); must match nym-staging's `verifyBadge` rules.
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

  /// Returns the badge when it verifies for [pubkey], else null.
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

  static String? badgeFromTags(List<List<String>> tags) {
    for (final t in tags) {
      if (t.length >= 2 && t[0] == tagName) return t[1];
    }
    return null;
  }
}
