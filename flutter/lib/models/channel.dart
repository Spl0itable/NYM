import 'dart:math' as math;

import '../core/constants/event_kinds.dart';

/// Geohash base32 alphabet (no a/i/l/o).
const String _geohashAlphabet = '0123456789bcdefghjkmnpqrstuvwxyz';
final RegExp _geohashRe = RegExp(r'^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$');

bool isValidGeohash(String s) => _geohashRe.hasMatch(s.toLowerCase());

final RegExp _channelTagWhitespaceRe = RegExp(r'\s');

bool isValidChannelTag(String? s) =>
    s != null && s.isNotEmpty && !_channelTagWhitespaceRe.hasMatch(s);

/// The default channel, which cannot be left or blocked.
const String kDefaultChannel = 'nymchat';

/// Wire parameters for a channel key: geohash flag, event kind and identifier tag.
class ChannelWire {
  const ChannelWire(this.isGeohash, this.kind, this.tag);
  final bool isGeohash;
  final int kind;
  final String tag;
}

ChannelWire channelWire(String channelKey) {
  // Valid geohash keys use kind 20000 + `g`; all else is kind 23333 + `d` ('nymchat' is never a geohash).
  if (channelKey.isNotEmpty && isValidGeohash(channelKey)) {
    return const ChannelWire(true, EventKind.geoChannel, 'g');
  }
  return const ChannelWire(false, EventKind.namedChannel, 'd');
}

class ChannelEntry {
  ChannelEntry({required this.channel, this.geohash = ''});

  final String channel;

  /// Geohash as supplied, or ''; prefer [geohashKey].
  final String geohash;

  /// The validated geohash this channel is, or ''; uses the same test as [channelWire].
  String get geohashKey {
    if (geohash.isNotEmpty && isValidGeohash(geohash)) return geohash;
    return isValidGeohash(channel) ? channel : '';
  }

  bool get isGeohash => geohashKey.isNotEmpty;

  /// Message storage key, always `#`-prefixed.
  String get storageKey => '#${isGeohash ? geohashKey : channel}';

  /// Lookup key in the `channels` map (geohash or name, lowercase).
  String get key => (isGeohash ? geohashKey : channel).toLowerCase();

  Map<String, dynamic> toJson() =>
      {'key': key, 'channel': channel, 'geohash': geohash};

  factory ChannelEntry.fromJson(Map<String, dynamic> j) => ChannelEntry(
        channel: j['channel'] as String,
        geohash: (j['geohash'] ?? '') as String,
      );
}

/// Decodes a geohash to its center lat/lng.
({double lat, double lng}) decodeGeohash(String geohash) {
  double latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  bool isLng = true;
  for (final ch in geohash.toLowerCase().split('')) {
    final idx = _geohashAlphabet.indexOf(ch);
    if (idx < 0) continue;
    for (int bit = 4; bit >= 0; bit--) {
      final bitVal = (idx >> bit) & 1;
      if (isLng) {
        final mid = (lngMin + lngMax) / 2;
        if (bitVal == 1) {
          lngMin = mid;
        } else {
          lngMax = mid;
        }
      } else {
        final mid = (latMin + latMax) / 2;
        if (bitVal == 1) {
          latMin = mid;
        } else {
          latMax = mid;
        }
      }
      isLng = !isLng;
    }
  }
  return (lat: (latMin + latMax) / 2, lng: (lngMin + lngMax) / 2);
}

String encodeGeohash(double lat, double lng, {int precision = 9}) {
  double latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  bool isLng = true;
  int bit = 0, idx = 0;
  final out = StringBuffer();
  while (out.length < precision) {
    if (isLng) {
      final mid = (lngMin + lngMax) / 2;
      if (lng >= mid) {
        idx = (idx << 1) | 1;
        lngMin = mid;
      } else {
        idx = idx << 1;
        lngMax = mid;
      }
    } else {
      final mid = (latMin + latMax) / 2;
      if (lat >= mid) {
        idx = (idx << 1) | 1;
        latMin = mid;
      } else {
        idx = idx << 1;
        latMax = mid;
      }
    }
    isLng = !isLng;
    if (++bit == 5) {
      out.write(_geohashAlphabet[idx]);
      bit = 0;
      idx = 0;
    }
  }
  return out.toString();
}

/// Haversine distance in km (R=6371).
double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  double toRad(double d) => d * math.pi / 180.0;
  final dLat = toRad(lat2 - lat1);
  final dLon = toRad(lon2 - lon1);
  final a = (1 - math.cos(dLat)) / 2 +
      math.cos(toRad(lat1)) * math.cos(toRad(lat2)) * (1 - math.cos(dLon)) / 2;
  return 2 * r * math.asin(math.sqrt(a));
}
