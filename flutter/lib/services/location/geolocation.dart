import 'package:geolocator/geolocator.dart';

import '../../features/channels/channel_manager.dart' show UserLocation;

/// Current GPS fix for proximity sorting, or null when unavailable; never throws and caps at 15s.
Future<UserLocation?> fetchCurrentUserLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    // Never prompt here: the caller owns the permission grant.
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return UserLocation(lat: pos.latitude, lng: pos.longitude);
  } catch (_) {
    return null;
  }
}
