import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../mesh_constants.dart';
import 'mesh_transport.dart';

/// The production BLE mesh transport. Every device runs **both** GATT roles
/// simultaneously — a peripheral advertising the bitchat service and a central
/// scanning for and connecting to peers — so any two nearby devices form a link
/// regardless of who discovered whom. This dual-role controlled flood is exactly
/// how bitchat's mesh operates, which is what makes cross-app interop possible.
///
/// Frames are opaque here: this layer only moves bytes over GATT. TTL, dedup,
/// Noise sessions and fragmentation all live above it in [MeshService].
class BleMeshTransport implements MeshTransport {
  /// [advertisedName] is our mesh peerID — bitchat advertises the peerID as the
  /// BLE device name so peers can pre-seed identity before the announce packet.
  BleMeshTransport(String advertisedName) : _advertisedNameString = advertisedName;

  /// Diagnostic sink, wired by [MeshController] to the on-screen mesh log so a
  /// device with no adb/Console access can still see the radio lifecycle —
  /// power state, scanning, advertising, links. Null in tests / when unwired.
  static void Function(String line)? debugLog;

  void _log(String line) => debugLog?.call('ble: $line');

  final CentralManager _central = CentralManager();
  final PeripheralManager _peripheral = PeripheralManager();

  final UUID _serviceUuid = UUID.fromString(MeshConstants.serviceUuid);
  final UUID _characteristicUuid =
      UUID.fromString(MeshConstants.characteristicUuid);

  final _inbound = StreamController<MeshInboundFrame>.broadcast();
  final _links = StreamController<MeshLinkEvent>.broadcast();

  final List<StreamSubscription<dynamic>> _subs = [];

  /// Peripherals we (as central) are connected to, keyed by peer UUID, with the
  /// remote characteristic we write to and subscribe on.
  final Map<String, _CentralLink> _centralLinks = {};

  /// Centrals (as peripheral) currently subscribed to our characteristic.
  final Map<String, Central> _subscribedCentrals = {};

  /// Our local mutable characteristic (peripheral role).
  GATTCharacteristic? _localCharacteristic;

  MeshTransportAvailability _availability = MeshTransportAvailability.unknown;
  bool _started = false;

  /// Whether each role is currently active, so a repeated power-on event (or the
  /// initial sync check racing the state listener) can't double-start discovery
  /// or advertising. Reset when the radio leaves the powered-on state.
  bool _scanning = false;
  bool _advertising = false;

  final String _advertisedNameString;

  @override
  MeshTransportAvailability get availability => _availability;

  @override
  int get connectedLinkCount =>
      _centralLinks.length + _subscribedCentrals.length;

  @override
  Stream<MeshInboundFrame> get inbound => _inbound.stream;

  @override
  Stream<MeshLinkEvent> get links => _links.stream;

  @override
  Future<MeshTransportAvailability> start() async {
    if (_started) return _availability;
    _started = true;
    _log('start(): bringing up central+peripheral (peerID=$_advertisedNameString)');

    // Wire the event handlers and BOTH managers' state listeners BEFORE the
    // authorize() awaits below. On iOS each CBManager is created in .unknown
    // and flips to .poweredOn asynchronously moments after construction; if we
    // awaited first, that transition could fire on the broadcast state stream
    // before we subscribed and be lost — leaving the radio powered on but the
    // roles never started (the classic "mesh never starts, no logs" symptom).
    _wireCentral();
    _wirePeripheral();

    _subs.add(_central.stateChanged.listen((e) {
      _availability = _mapState(e.state);
      _log('central state → ${e.state.name}');
      if (e.state == BluetoothLowEnergyState.poweredOn) {
        unawaited(_beginCentral());
      } else {
        _scanning = false;
      }
    }));
    // The peripheral role has its OWN state on iOS. Advertising must (re)start
    // when the PERIPHERAL manager powers on — not when the central does, as the
    // old code assumed. Otherwise an iOS device could scan but never advertise,
    // so no peer (including real bitchat) can discover it and no packets flow.
    _subs.add(_peripheral.stateChanged.listen((e) {
      _log('peripheral state → ${e.state.name}');
      if (e.state == BluetoothLowEnergyState.poweredOn) {
        unawaited(_beginPeripheral());
      } else {
        _advertising = false;
      }
    }));

    // Request runtime authorization for both roles.
    try {
      await _central.authorize();
      await _peripheral.authorize();
    } catch (e) {
      // authorize() throws on platforms that grant implicitly; that's fine.
      _log('authorize() threw (implicit-grant platform?): $e');
    }

    _availability = _mapState(_central.state);
    _log('initial state: central=${_central.state.name} '
        'peripheral=${_peripheral.state.name} → ${_availability.name}');

    // Handle the case where a manager was ALREADY powered on by the time we got
    // here (the state listener above only covers future transitions).
    if (_central.state == BluetoothLowEnergyState.poweredOn) {
      await _beginCentral();
    }
    if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
      await _beginPeripheral();
    }
    return _availability;
  }

  @override
  Future<void> stop() async {
    _started = false;
    _scanning = false;
    _advertising = false;
    _log('stop(): tearing down radio');
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    for (final link in _centralLinks.values) {
      try {
        await _central.disconnect(link.peripheral);
      } catch (_) {}
    }
    _centralLinks.clear();
    try {
      await _peripheral.stopAdvertising();
      await _peripheral.removeAllServices();
    } catch (_) {}
    _subscribedCentrals.clear();
    _localCharacteristic = null;
  }

  @override
  Future<void> broadcast(Uint8List frame) async {
    // As central: write to every connected peripheral.
    for (final link in _centralLinks.values.toList()) {
      try {
        await _central.writeCharacteristic(
          link.peripheral,
          link.characteristic,
          value: frame,
          type: GATTCharacteristicWriteType.withoutResponse,
        );
      } catch (_) {
        // Dead link; the disconnect handler will prune it.
      }
    }
    // As peripheral: notify every subscribed central.
    final characteristic = _localCharacteristic;
    if (characteristic != null) {
      for (final central in _subscribedCentrals.values.toList()) {
        try {
          await _peripheral.notifyCharacteristic(
            central,
            characteristic,
            value: frame,
          );
        } catch (_) {}
      }
    }
  }

  // ---- Central role ---------------------------------------------------------

  void _wireCentral() {
    _subs.add(_central.discovered.listen((e) => _onDiscovered(e)));
    _subs.add(_central.connectionStateChanged.listen(_onCentralConnectionState));
    _subs.add(_central.characteristicNotified.listen((e) {
      if (e.characteristic.uuid != _characteristicUuid) return;
      _inbound.add(MeshInboundFrame(
        data: Uint8List.fromList(e.value),
        linkId: e.peripheral.uuid.toString(),
      ));
    }));
  }

  Future<void> _beginCentral() async {
    if (_scanning) return;
    try {
      await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
      _scanning = true;
      _log('scanning for mesh service');
    } catch (e) {
      _log('startDiscovery failed: $e');
    }
  }

  final Set<String> _connecting = {};

  Future<void> _onDiscovered(DiscoveredEventArgs e) async {
    final id = e.peripheral.uuid.toString();
    if (_centralLinks.containsKey(id) || _connecting.contains(id)) return;
    _connecting.add(id);
    _log('discovered peer $id (rssi ${e.rssi}) — connecting');
    try {
      await _central.connect(e.peripheral);
      // Best-effort MTU bump. iOS/Darwin THROWS UnsupportedError here (Core
      // Bluetooth negotiates the MTU itself and exposes no manual request) —
      // if that threw out of the connect flow it aborted every central link on
      // iOS, which is exactly why the mesh never formed there. Swallow it: the
      // OS-negotiated MTU is fine and oversized packets fragment anyway.
      try {
        await _central.requestMTU(e.peripheral, mtu: MeshConstants.desiredMtu);
      } catch (err) {
        _log('requestMTU unsupported (${err.runtimeType}); using negotiated MTU');
      }
      final services = await _central.discoverGATT(e.peripheral);
      final characteristic = _findCharacteristic(services);
      if (characteristic == null) {
        _log('peer $id has no mesh characteristic — dropping');
        await _central.disconnect(e.peripheral);
        return;
      }
      await _central.setCharacteristicNotifyState(
        e.peripheral,
        characteristic,
        state: true,
      );
      _centralLinks[id] = _CentralLink(e.peripheral, characteristic);
      _log('linked to peer $id (central role) — $connectedLinkCount link(s)');
      _links.add(MeshLinkEvent(id, MeshLinkChange.connected, rssi: e.rssi));
    } catch (err) {
      _log('connect to $id failed: $err');
      try {
        await _central.disconnect(e.peripheral);
      } catch (_) {}
    } finally {
      _connecting.remove(id);
    }
  }

  void _onCentralConnectionState(
      PeripheralConnectionStateChangedEventArgs e) {
    if (e.state == ConnectionState.disconnected) {
      final id = e.peripheral.uuid.toString();
      if (_centralLinks.remove(id) != null) {
        _log('peer $id disconnected (central role)');
        _links.add(MeshLinkEvent(id, MeshLinkChange.disconnected));
      }
    }
  }

  GATTCharacteristic? _findCharacteristic(List<GATTService> services) {
    for (final service in services) {
      if (service.uuid != _serviceUuid) continue;
      for (final c in service.characteristics) {
        if (c.uuid == _characteristicUuid) return c;
      }
    }
    return null;
  }

  // ---- Peripheral role ------------------------------------------------------

  void _wirePeripheral() {
    _subs.add(_peripheral.characteristicWriteRequested.listen((e) async {
      if (e.characteristic.uuid == _characteristicUuid) {
        _inbound.add(MeshInboundFrame(
          data: Uint8List.fromList(e.request.value),
          linkId: e.central.uuid.toString(),
        ));
      }
      try {
        await _peripheral.respondWriteRequest(e.request);
      } catch (_) {}
    }));
    _subs.add(_peripheral.characteristicNotifyStateChanged.listen((e) {
      if (e.characteristic.uuid != _characteristicUuid) return;
      final id = e.central.uuid.toString();
      if (e.state) {
        final wasNew = !_subscribedCentrals.containsKey(id);
        _subscribedCentrals[id] = e.central;
        if (wasNew) {
          _log('central $id subscribed (peripheral role) — '
              '$connectedLinkCount link(s)');
          _links.add(MeshLinkEvent(id, MeshLinkChange.connected));
        }
      } else {
        if (_subscribedCentrals.remove(id) != null) {
          _log('central $id unsubscribed (peripheral role)');
          _links.add(MeshLinkEvent(id, MeshLinkChange.disconnected));
        }
      }
    }));
    // Android surfaces central connect/disconnect; other platforms throw.
    try {
      _subs.add(_peripheral.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected) {
          final id = e.central.uuid.toString();
          if (_subscribedCentrals.remove(id) != null) {
            _links.add(MeshLinkEvent(id, MeshLinkChange.disconnected));
          }
        }
      }));
    } catch (_) {
      // connectionStateChanged unsupported on this platform.
    }
  }

  Future<void> _beginPeripheral() async {
    if (_advertising) return;
    try {
      await _peripheral.removeAllServices();
      final characteristic = GATTCharacteristic.mutable(
        uuid: _characteristicUuid,
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
          GATTCharacteristicPermission.write,
        ],
        descriptors: [],
      );
      _localCharacteristic = characteristic;
      await _peripheral.addService(GATTService(
        uuid: _serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [characteristic],
      ));
      await _peripheral.startAdvertising(Advertisement(
        name: _advertisedNameString,
        serviceUUIDs: [_serviceUuid],
      ));
      _advertising = true;
      _log('advertising mesh service as "$_advertisedNameString"');
    } catch (e) {
      _log('startAdvertising failed: $e');
    }
  }

  @override
  Future<void> openSystemSettings() async {
    try {
      await _central.showAppSettings();
    } catch (_) {
      try {
        await _peripheral.showAppSettings();
      } catch (_) {}
    }
  }

  MeshTransportAvailability _mapState(BluetoothLowEnergyState state) {
    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        return MeshTransportAvailability.ready;
      case BluetoothLowEnergyState.poweredOff:
        return MeshTransportAvailability.poweredOff;
      case BluetoothLowEnergyState.unauthorized:
        return MeshTransportAvailability.unauthorized;
      case BluetoothLowEnergyState.unsupported:
        return MeshTransportAvailability.unsupported;
      case BluetoothLowEnergyState.unknown:
        return MeshTransportAvailability.unknown;
    }
  }
}

class _CentralLink {
  _CentralLink(this.peripheral, this.characteristic);
  final Peripheral peripheral;
  final GATTCharacteristic characteristic;
}
