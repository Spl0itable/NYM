import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'bech32_codec.dart';
import 'keys.dart';

/// The `#xxxx` nym suffix always derives from hex: npub characters don't align with hex nibbles.

final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

enum PubkeyFormat { npub, hex }

/// Persisted under the same key the PWA uses.
const String kPubkeyFormatKey = 'nym_pubkey_format';

PubkeyFormat readPubkeyFormat(SharedPreferences? prefs) =>
    prefs?.getString(kPubkeyFormatKey) == 'hex'
        ? PubkeyFormat.hex
        : PubkeyFormat.npub;

Future<void> writePubkeyFormat(
        SharedPreferences prefs, PubkeyFormat format) =>
    prefs.setString(
        kPubkeyFormatKey, format == PubkeyFormat.hex ? 'hex' : 'npub');

/// Hex, `npub` or `nprofile` normalized to lowercase hex; null otherwise.
String? normalizePubkeyInput(String? value) {
  var raw = (value ?? '').trim();
  if (raw.toLowerCase().startsWith('nostr:')) raw = raw.substring(6);
  if (raw.startsWith('@')) raw = raw.substring(1);
  if (raw.isEmpty) return null;
  if (_hex64.hasMatch(raw)) return raw.toLowerCase();
  final lower = raw.toLowerCase();
  if (!lower.startsWith('npub1') && !lower.startsWith('nprofile1')) return null;
  try {
    if (lower.startsWith('npub1')) return decodeNpub(lower).toLowerCase();
    return decodeNprofilePubkey(lower);
  } catch (_) {
    return null;
  }
}

bool isPubkeyInput(String? value) => normalizePubkeyInput(value) != null;

/// The `npub` of a hex pubkey, or the input unchanged when it can't be encoded.
String npubOrHex(String hexPubkey) {
  if (!_hex64.hasMatch(hexPubkey)) return hexPubkey;
  try {
    return encodeNpub(hexPubkey.toLowerCase());
  } catch (_) {
    return hexPubkey;
  }
}

String formatPubkeyForDisplay(String hexPubkey, PubkeyFormat format) =>
    format == PubkeyFormat.npub ? npubOrHex(hexPubkey) : hexPubkey;

/// `nsec` or hex private key normalized to 32 raw bytes; null otherwise.
Uint8List? normalizePrivkeyInput(String? value) {
  var raw = (value ?? '').trim();
  if (raw.toLowerCase().startsWith('nostr:')) raw = raw.substring(6);
  if (raw.isEmpty) return null;
  if (_hex64.hasMatch(raw)) return hexToBytes(raw.toLowerCase());
  if (!raw.toLowerCase().startsWith('nsec1')) return null;
  try {
    final bytes = decodeNsec(raw.toLowerCase());
    return bytes.length == 32 ? bytes : null;
  } catch (_) {
    return null;
  }
}

bool isPrivkeyInput(String? value) => normalizePrivkeyInput(value) != null;
