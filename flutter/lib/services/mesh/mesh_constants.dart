/// Bluetooth mesh wire constants that must match bitchat's `AppConstants` for interop.
class MeshConstants {
  const MeshConstants._();

  /// GATT service UUID shared with bitchat.
  static const String serviceUuid = 'F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C';

  /// The single characteristic for all mesh traffic (notify + write).
  static const String characteristicUuid =
      'A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D';

  /// Client Characteristic Configuration descriptor (standard 0x2902).
  static const String cccdUuid = '00002902-0000-1000-8000-00805f9b34fb';

  /// Default packet TTL in hops.
  static const int messageTtl = 7;

  static const int fragmentSizeThreshold = 512;

  static const int maxFragmentSize = 469;

  /// MTU requested on connect so a full padded packet fits one write.
  static const int desiredMtu = 517;

  static const int seenPacketCapacity = 1000;

  static const Duration seenPacketTtl = Duration(minutes: 5);

  /// A peer silent this long is considered offline.
  static const Duration stalePeerTimeout = Duration(minutes: 3);

  static const Duration announceInterval = Duration(seconds: 30);

  /// Jitter so beacon rhythm can't fingerprint a device; stays far under [stalePeerTimeout].
  static const Duration announceJitter = Duration(seconds: 8);

  /// Slower announce while no peer is known, saving battery and exposure.
  static const Duration announceIntervalIdle = Duration(seconds: 90);

  static const Duration fragmentTimeout = Duration(seconds: 30);

  /// Random relay jitter bounds, avoiding synchronized flooding.
  static const int relayJitterMinMs = 10;
  static const int relayJitterMaxMs = 220;

  /// Paces fragments so iOS Core Bluetooth's send queue doesn't silently drop them.
  static const Duration interFragmentDelay = Duration(milliseconds: 20);
}
