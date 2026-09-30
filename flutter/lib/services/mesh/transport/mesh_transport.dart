import 'dart:typed_data';

class MeshInboundFrame {
  MeshInboundFrame({required this.data, required this.linkId, this.rssi = 0});

  final Uint8List data;

  /// Opaque id of the BLE link (remote peer UUID).
  final String linkId;

  /// Signal strength, or 0 when unknown (e.g. a peripheral write).
  final int rssi;
}

enum MeshLinkChange { connected, disconnected }

class MeshLinkEvent {
  MeshLinkEvent(this.linkId, this.change, {this.rssi = 0});
  final String linkId;
  final MeshLinkChange change;
  final int rssi;
}

enum MeshTransportAvailability {
  unknown,
  unsupported,
  unauthorized,
  poweredOff,
  ready,
}

/// The radio under [MeshService]: a controlled flood with no directed send; faked in tests.
abstract class MeshTransport {
  /// Starts advertising and scanning; only [MeshTransportAvailability.ready] means links can form.
  Future<MeshTransportAvailability> start();

  Future<void> stop();

  /// Floods [frame] to every link; per-link failures are swallowed.
  Future<void> broadcast(Uint8List frame);

  Stream<MeshInboundFrame> get inbound;

  Stream<MeshLinkEvent> get links;

  MeshTransportAvailability get availability;

  int get connectedLinkCount;

  /// Opens the OS app settings to grant Bluetooth after a denial; no-op where unsupported.
  Future<void> openSystemSettings();
}
