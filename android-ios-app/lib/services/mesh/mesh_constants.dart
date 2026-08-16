/// Wire-level constants for the Bluetooth mesh, mirrored from bitchat's
/// `AppConstants`. These MUST match the reference clients for interop.
class MeshConstants {
  const MeshConstants._();

  /// GATT service advertised/scanned for. Shared with bitchat.
  static const String serviceUuid = 'F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C';

  /// The single characteristic used for all mesh traffic (notify + write).
  static const String characteristicUuid =
      'A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D';

  /// Client Characteristic Configuration descriptor (standard 0x2902).
  static const String cccdUuid = '00002902-0000-1000-8000-00805f9b34fb';

  /// Default packet TTL (hops).
  static const int messageTtl = 7;

  /// Packets whose serialized size exceeds this are fragmented.
  static const int fragmentSizeThreshold = 512;

  /// Max bytes of packet data carried per fragment.
  static const int maxFragmentSize = 469;

  /// MTU we request on connect to fit a full padded packet in one write.
  static const int desiredMtu = 517;

  // ---- Dedup / peer lifecycle ----------------------------------------------

  /// LRU size for the seen-packet set (drop duplicates during flooding).
  static const int seenPacketCapacity = 1000;

  /// A seen-packet entry expires after this long.
  static const Duration seenPacketTtl = Duration(minutes: 5);

  /// A peer with no traffic for this long is considered stale/offline.
  static const Duration stalePeerTimeout = Duration(minutes: 3);

  /// How often we re-broadcast our identity announcement.
  static const Duration announceInterval = Duration(seconds: 30);

  /// Fragment reassembly is abandoned after this long.
  static const Duration fragmentTimeout = Duration(seconds: 30);

  /// Random relay jitter bounds (avoids synchronized flooding storms).
  static const int relayJitterMinMs = 10;
  static const int relayJitterMaxMs = 220;

  /// Gap inserted between consecutive fragments of a multi-fragment transfer
  /// (images/files). Paces GATT writes/notifications so iOS Core Bluetooth's
  /// bounded send queue doesn't overflow and silently drop fragments, which
  /// would leave the payload unreassemblable on the receiver.
  static const Duration interFragmentDelay = Duration(milliseconds: 20);
}
