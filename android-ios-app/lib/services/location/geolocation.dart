import 'package:geolocator/geolocator.dart';

import '../../features/channels/channel_manager.dart' show UserLocation;

/// Fetches the device's current GPS coordinates for proximity channel sorting —
/// the native equivalent of the PWA's `navigator.geolocation.getCurrentPosition`
/// (app.js:3920 on Save, app.js:6857 on boot when `sortByProximity` is already
/// on). The OS permission grant is handled by the caller (permission_handler);
/// this only reads the fix.
///
/// Returns null when location services are disabled, permission isn't granted,
/// or the fix times out — so the caller leaves proximity sorting off, mirroring
/// the PWA's geolocation error branch. Never throws (a 15s cap stops a missing
/// GPS from hanging the Save/boot flow).
Future<UserLocation?> fetchCurrentUserLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    // Don't re-prompt here: the grant is the caller's job (permission_handler).
    // A denied/forever-denied state simply yields no fix.
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
    // Services off, timeout, or platform without GPS → leave proximity off.
    return null;
  }
}
