import 'dart:typed_data';

/// A frame received from a mesh link (one GATT notification or write).
class MeshInboundFrame {
  MeshInboundFrame({required this.data, required this.linkId, this.rssi = 0});

  /// The raw [BitchatPacket] bytes as they arrived on the air.
  final Uint8List data;

  /// Opaque identifier of the BLE link the frame arrived on (remote peer UUID).
  final String linkId;

  /// Signal strength when known (0 if unavailable, e.g. a peripheral write).
  final int rssi;
}

enum MeshLinkChange { connected, disconnected }

/// A change in the set of directly-connected BLE links.
class MeshLinkEvent {
  MeshLinkEvent(this.linkId, this.change, {this.rssi = 0});
  final String linkId;
  final MeshLinkChange change;
  final int rssi;
}

/// Availability of the underlying radio / permissions.
enum MeshTransportAvailability {
  unknown,
  unsupported,
  unauthorized,
  poweredOff,
  ready,
}

/// The radio transport a [MeshService] runs over. Abstracted so the mesh logic
/// (routing, dedup, Noise, fragmentation) can be unit-tested against a fake
/// transport with no Bluetooth hardware.
///
/// The contract is a controlled flood: [broadcast] pushes a frame to every
/// directly-connected link; higher layers add TTL, deduplication and recipient
/// filtering. There is no directed-send primitive — directed packets carry a
/// recipient id in their header and are flooded like everything else.
abstract class MeshTransport {
  /// Powers up both BLE roles (advertise + scan) and begins forming links.
  /// Returns the resulting availability; only [MeshTransportAvailability.ready]
  /// means links can form.
  Future<MeshTransportAvailability> start();

  /// Tears down advertising, scanning and all links.
  Future<void> stop();

  /// Floods [frame] to every connected link (best-effort; failures per link are
  /// swallowed so one dead link cannot block the rest).
  Future<void> broadcast(Uint8List frame);

  /// Frames received from any link.
  Stream<MeshInboundFrame> get inbound;

  /// Connect/disconnect events for directly-connected links.
  Stream<MeshLinkEvent> get links;

  /// Current availability of the radio/permissions.
  MeshTransportAvailability get availability;

  /// The number of currently-connected direct links.
  int get connectedLinkCount;

  /// Opens the OS app-settings page so the user can grant Bluetooth permission
  /// after a denial. No-op where unsupported.
  Future<void> openSystemSettings();
}
