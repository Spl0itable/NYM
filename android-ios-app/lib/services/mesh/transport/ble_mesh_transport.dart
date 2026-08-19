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
  BleMeshTransport(String advertisedName)
      : _advertisedNameString = advertisedName;

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
  final _availabilityChanges =
      StreamController<MeshTransportAvailability>.broadcast();

  /// Fires whenever [availability] changes. On iOS the radio reports `unknown`
  /// synchronously at start() and only flips to `ready` a beat later when the
  /// CBManager powers on, so a one-shot read at start would leave the UI stuck
  /// on "Starting…". The controller listens here to keep the status live.
  Stream<MeshTransportAvailability> get availabilityChanged =>
      _availabilityChanges.stream;

  void _setAvailability(MeshTransportAvailability next) {
    if (next == _availability) return;
    _availability = next;
    if (!_availabilityChanges.isClosed) _availabilityChanges.add(next);
  }

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

  /// Reentrancy guards for the role bring-ups. The state listener and start()'s
  /// direct check can BOTH invoke _beginPeripheral before either finishes; the
  /// second call's removeAllServices() then runs AFTER the first call's
  /// addService(), leaving the device ADVERTISING the mesh service with an
  /// empty GATT — remote centrals connect and find "no mesh characteristic".
  /// This race is intermittent, which is exactly why linking worked on some
  /// runs and not others. The busy flag makes each bring-up single-flight.
  bool _centralStarting = false;
  bool _peripheralStarting = false;

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
    _log(
        'start(): bringing up central+peripheral (peerID=$_advertisedNameString)');

    // Wire the event handlers and BOTH managers' state listeners BEFORE the
    // authorize() awaits below. On iOS each CBManager is created in .unknown
    // and flips to .poweredOn asynchronously moments after construction; if we
    // awaited first, that transition could fire on the broadcast state stream
    // before we subscribed and be lost — leaving the radio powered on but the
    // roles never started (the classic "mesh never starts, no logs" symptom).
    _wireCentral();
    _wirePeripheral();

    _subs.add(_central.stateChanged.listen((e) {
      _setAvailability(_mapState(e.state));
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

    _setAvailability(_mapState(_central.state));
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
    _centralStarting = false;
    _peripheralStarting = false;
    _cooldownUntil.clear();
    _failStreak.clear();
    _connecting.clear();
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
    _subs
        .add(_central.connectionStateChanged.listen(_onCentralConnectionState));
    _subs.add(_central.characteristicNotified.listen((e) {
      if (e.characteristic.uuid != _characteristicUuid) return;
      _inbound.add(MeshInboundFrame(
        data: Uint8List.fromList(e.value),
        linkId: e.peripheral.uuid.toString(),
      ));
    }));
  }

  Future<void> _beginCentral() async {
    if (_scanning || _centralStarting) return;
    _centralStarting = true;
    try {
      await _central.startDiscovery(serviceUUIDs: [_serviceUuid]);
      _scanning = true;
      _log('scanning for mesh service');
    } catch (e) {
      _log('startDiscovery failed: $e');
    } finally {
      _centralStarting = false;
    }
  }

  final Set<String> _connecting = {};

  /// Per-peer link-failure backoff. A peer that advertises the service but can't
  /// be linked — an iOS GATT cache returning the service with no characteristics,
  /// a peripheral whose GATT isn't ready yet, or a distant peer that keeps timing
  /// out — is otherwise re-discovered and re-connected every few seconds in a
  /// tight loop that churns the radio and can starve a good link. We skip a peer
  /// while it's cooling down and grow the cooldown exponentially per consecutive
  /// failure, but still retry periodically so a transiently-unready peer links
  /// once it recovers. Cleared the moment a link succeeds.
  final Map<String, DateTime> _cooldownUntil = {};
  final Map<String, int> _failStreak = {};

  static const Duration _cooldownBase = Duration(seconds: 15);
  // Capped at 1 minute (was 5): a peer that failed because its app was mid-
  // restart or its GATT briefly unready shouldn't look dead for minutes.
  static const Duration _cooldownMax = Duration(minutes: 1);

  /// Upper bounds on a single connect / GATT-discovery step (iOS provides none).
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _discoverTimeout = Duration(seconds: 8);

  void _noteLinkFailure(String id) {
    // Prune expired entries so rotating iOS peer UUIDs can't grow these maps
    // without bound over a long session.
    final now = DateTime.now();
    if (_cooldownUntil.length > 128) {
      _cooldownUntil.removeWhere((_, until) => now.isAfter(until));
      _failStreak.removeWhere((k, _) => !_cooldownUntil.containsKey(k));
    }
    final n = (_failStreak[id] ?? 0) + 1;
    _failStreak[id] = n;
    var shift = n - 1;
    if (shift > 10) shift = 10;
    final ms = (_cooldownBase.inMilliseconds << shift)
        .clamp(0, _cooldownMax.inMilliseconds)
        .toInt();
    _cooldownUntil[id] = now.add(Duration(milliseconds: ms));
  }

  void _noteLinkSuccess(String id) {
    _failStreak.remove(id);
    _cooldownUntil.remove(id);
  }

  Future<void> _onDiscovered(DiscoveredEventArgs e) async {
    final id = e.peripheral.uuid.toString();
    if (_centralLinks.containsKey(id) || _connecting.contains(id)) return;
    final until = _cooldownUntil[id];
    if (until != null && DateTime.now().isBefore(until)) return;
    _connecting.add(id);
    _log('discovered peer $id (rssi ${e.rssi}) — connecting');
    try {
      // iOS CBCentralManager.connect() has NO built-in timeout — a peer that
      // never completes the connection leaves the attempt pending forever,
      // pinning the peer in `_connecting` so it's never retried (and, if it's
      // the peer we actually want, never linked). Bound every step so a stuck
      // attempt aborts, backs off, and frees the slot for the next scan hit.
      await _central.connect(e.peripheral).timeout(_connectTimeout);
      // Best-effort MTU bump. iOS/Darwin THROWS UnsupportedError here (Core
      // Bluetooth negotiates the MTU itself and exposes no manual request) —
      // if that threw out of the connect flow it aborted every central link on
      // iOS, which is exactly why the mesh never formed there. Swallow it: the
      // OS-negotiated MTU is fine and oversized packets fragment anyway.
      try {
        await _central.requestMTU(e.peripheral, mtu: MeshConstants.desiredMtu);
      } catch (err) {
        _log(
            'requestMTU unsupported (${err.runtimeType}); using negotiated MTU');
      }
      var services =
          await _central.discoverGATT(e.peripheral).timeout(_discoverTimeout);
      var characteristic = _findCharacteristic(services);
      if (characteristic == null) {
        // Retry once: iOS sometimes surfaces the service before its
        // characteristics have populated on a freshly-opened connection.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        services =
            await _central.discoverGATT(e.peripheral).timeout(_discoverTimeout);
        characteristic = _findCharacteristic(services);
      }
      if (characteristic == null) {
        // Log what the peer's GATT actually contains: distinguishes an empty
        // GATT (peer's service add failed/was stripped) from a stale cache or
        // a UUID mismatch.
        final dump = services
            .map((s) => '${_shortUuid(s.uuid)}'
                '[${s.characteristics.map((ch) => _shortUuid(ch.uuid)).join(' ')}]')
            .join(' ');
        _log('peer $id has no mesh characteristic — dropping (backing off); '
            'gatt: ${dump.isEmpty ? '(no services)' : dump}');
        _noteLinkFailure(id);
        await _central.disconnect(e.peripheral);
        return;
      }
      await _central.setCharacteristicNotifyState(
        e.peripheral,
        characteristic,
        state: true,
      );
      _centralLinks[id] = _CentralLink(e.peripheral, characteristic);
      _noteLinkSuccess(id);
      _log('linked to peer $id (central role) — $connectedLinkCount link(s)');
      _links.add(MeshLinkEvent(id, MeshLinkChange.connected, rssi: e.rssi));
    } catch (err) {
      _log('connect to $id failed: $err');
      _noteLinkFailure(id);
      try {
        await _central.disconnect(e.peripheral);
      } catch (_) {}
    } finally {
      _connecting.remove(id);
    }
  }

  void _onCentralConnectionState(PeripheralConnectionStateChangedEventArgs e) {
    if (e.state == ConnectionState.disconnected) {
      final id = e.peripheral.uuid.toString();
      if (_centralLinks.remove(id) != null) {
        _log('peer $id disconnected (central role)');
        _links.add(MeshLinkEvent(id, MeshLinkChange.disconnected));
      }
    }
  }

  /// First 8 hex chars of a UUID — enough to identify it in the tiny log pane.
  static String _shortUuid(UUID uuid) {
    final s = uuid.toString().replaceAll('-', '');
    return s.length > 8 ? s.substring(0, 8) : s;
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
    if (_advertising || _peripheralStarting) return;
    _peripheralStarting = true;
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
    } finally {
      _peripheralStarting = false;
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
