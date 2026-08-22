import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'bech32_codec.dart';
import 'keys.dart';

/// npub / hex public keys, and nsec / hex private keys.
///
/// Identities are hex on the wire and hex in every index the app keeps, but
/// npub (NIP-19) is the form the docs and the wider Nostr ecosystem use, so it
/// is what we show by default. The two are NOT interchangeable character for
/// character: npub is bech32, whose last six characters are a checksum and
/// whose payload is 5-bit groups that never line up with hex nibbles. So the
/// `#xxxx` suffix in `nym#a1b2` stays derived from the HEX key — that suffix is
/// how mentions, autocomplete, the bot API and bitchat (which speaks hex only
/// over the mesh) resolve a person, and re-deriving it from the npub would
/// break every one of them plus every mention already in history.
///
/// Everything that ACCEPTS a public key accepts either form; everything that
/// SHOWS one honours [pubkeyDisplayFormat].

final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// Which form full public keys are rendered in.
enum PubkeyFormat { npub, hex }

/// Persisted under the same key the PWA uses (`nym_pubkey_format`).
const String kPubkeyFormatKey = 'nym_pubkey_format';

PubkeyFormat readPubkeyFormat(SharedPreferences? prefs) =>
    prefs?.getString(kPubkeyFormatKey) == 'hex'
        ? PubkeyFormat.hex
        : PubkeyFormat.npub;

Future<void> writePubkeyFormat(
        SharedPreferences prefs, PubkeyFormat format) =>
    prefs.setString(
        kPubkeyFormatKey, format == PubkeyFormat.hex ? 'hex' : 'npub');

/// Either a 64-char hex pubkey or an `npub` / `nprofile`, normalised to
/// lowercase hex. Returns null when [value] is neither.
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

/// True when [value] is a public key in either accepted form.
bool isPubkeyInput(String? value) => normalizePubkeyInput(value) != null;

/// The `npub` form of a hex pubkey, or the input unchanged when it can't be
/// encoded (so a caller can always render the result).
String npubOrHex(String hexPubkey) {
  if (!_hex64.hasMatch(hexPubkey)) return hexPubkey;
  try {
    return encodeNpub(hexPubkey.toLowerCase());
  } catch (_) {
    return hexPubkey;
  }
}

/// A full public key rendered in [format].
String formatPubkeyForDisplay(String hexPubkey, PubkeyFormat format) =>
    format == PubkeyFormat.npub ? npubOrHex(hexPubkey) : hexPubkey;

/// Either an `nsec` or a 64-char hex private key, normalised to the raw 32
/// bytes the signer wants. Returns null when [value] is neither.
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

/// True when [value] is a private key in either accepted form.
bool isPrivkeyInput(String? value) => normalizePrivkeyInput(value) != null;
