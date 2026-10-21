import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/mesh/mesh_peer.dart';
import '../../../services/mesh/protocol/nym_share_payload.dart';
import 'nearby_link.dart';
import 'nearby_pointing.dart';

const String kNiChannel = 'app.nymchat/nearby_interaction';
const String kNiEventsChannel = 'app.nymchat/nearby_interaction/events';
const int kNiMaxPeers = 8;

class NiReading {
  const NiReading({required this.peerId, this.sample, this.event});

  final String peerId;
  final NiSample? sample;
  final String? event;

  static NiReading? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final peerId = raw['peerId'];
    if (peerId is! String || peerId.isEmpty) return null;
    final event = raw['event'];
    if (event is String) return NiReading(peerId: peerId, event: event);
    double? num_(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    return NiReading(
      peerId: peerId,
      sample: NiSample(
        distance: num_(raw['distance']),
        x: num_(raw['x']),
        y: num_(raw['y']),
        z: num_(raw['z']),
      ),
    );
  }
}

abstract class NiPlatform {
  Future<bool> isSupported();
  Future<bool> supportsDirection();
  Future<Uint8List?> prepare(String peerId);
  Future<bool> run(String peerId, Uint8List token);
  Future<void> stop(String peerId);
  Future<void> stopAll();
  Stream<NiReading> get readings;
}

class MethodChannelNiPlatform implements NiPlatform {
  MethodChannelNiPlatform();

  final MethodChannel _channel = const MethodChannel(kNiChannel);
  final EventChannel _events = const EventChannel(kNiEventsChannel);
  Stream<NiReading>? _readings;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> isSupported() async => await _call<bool>('isSupported') ?? false;

  @override
  Future<bool> supportsDirection() async =>
      await _call<bool>('supportsDirection') ?? false;

  @override
  Future<Uint8List?> prepare(String peerId) =>
      _call<Uint8List>('prepare', {'peerId': peerId});

  @override
  Future<bool> run(String peerId, Uint8List token) async =>
      await _call<bool>('run', {'peerId': peerId, 'token': token}) ?? false;

  @override
  Future<void> stop(String peerId) => _call<void>('stop', {'peerId': peerId});

  @override
  Future<void> stopAll() => _call<void>('stopAll');

  @override
  Stream<NiReading> get readings => _readings ??= _events
      .receiveBroadcastStream()
      .handleError((Object _) {})
      .map(NiReading.fromMap)
      .where((r) => r != null)
      .cast<NiReading>();
}

class NearbyNiSession extends ChangeNotifier {
  NearbyNiSession({
    required this.platform,
    required this.link,
    required this.isEligible,
    required this.now,
  });

  final NiPlatform platform;
  final NearbyLink link;
  final bool Function(String peerID) isEligible;
  final int Function() now;

  final NearbyPointer _pointer = NearbyPointer();
  final Map<String, Uint8List> _own = {};
  final Set<String> _sent = {};
  final Set<String> _exchanged = {};
  StreamSubscription<NiReading>? _sub;
  bool _active = false;
  bool _closed = false;
  bool _direction = false;
  String? _highlighted;

  bool get active => _active;
  bool get supportsDirection => _direction;
  String? get highlighted => _highlighted;

  Future<bool> start(List<MeshPeer> peers) async {
    if (_active || _closed) return _active;
    bool supported;
    try {
      supported = await platform.isSupported();
    } catch (_) {
      supported = false;
    }
    if (!supported || _closed) return false;
    try {
      _direction = await platform.supportsDirection();
    } catch (_) {
      _direction = false;
    }
    if (_closed) return false;
    _active = true;
    _sub = platform.readings.listen(_onReading, onError: (Object _) {});
    _notify();
    final targets = peers
        .where((p) => p.isDirectLink && isEligible(p.peerID))
        .take(kNiMaxPeers)
        .map((p) => p.peerID)
        .toList();
    for (final peer in targets) {
      if (!_active) break;
      final token = await _prepare(peer);
      if (token == null || !_active) continue;
      _sent.add(peer);
      _exchanged.add(peer);
      await _send(peer, token, replyRequested: true);
    }
    return _active;
  }

  Future<void> onToken(MeshNiToken t) async {
    if (!_active) return;
    final peer = t.senderPeerID;
    if (!isEligible(peer)) return;
    if (t.isStop) {
      _own.remove(peer);
      _sent.remove(peer);
      _exchanged.remove(peer);
      _pointer.remove(peer);
      try {
        await platform.stop(peer);
      } catch (_) {}
      _refresh();
      return;
    }
    final own = _own[peer] ?? await _prepare(peer);
    if (own == null || !_active) return;
    bool ran;
    try {
      ran = await platform.run(peer, t.token);
    } catch (_) {
      ran = false;
    }
    if (!ran || !_active) return;
    _exchanged.add(peer);
    if (t.replyRequested && !_sent.contains(peer)) {
      _sent.add(peer);
      await _send(peer, own, replyRequested: false);
    }
  }

  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    final wasActive = _active;
    _active = false;
    final sub = _sub;
    _sub = null;
    _pointer.clear();
    _highlighted = null;
    _own.clear();
    _sent.clear();
    final peers = _exchanged.toList();
    _exchanged.clear();
    if (sub != null) unawaited(sub.cancel());
    if (!wasActive) return;
    for (final peer in peers) {
      await _send(peer, Uint8List(0), replyRequested: false);
    }
    try {
      await platform.stopAll();
    } catch (_) {}
  }

  Future<Uint8List?> _prepare(String peer) async {
    Uint8List? token;
    try {
      token = await platform.prepare(peer);
    } catch (_) {
      token = null;
    }
    if (token == null || token.isEmpty || token.length > kNiTokenMaxBytes) {
      return null;
    }
    if (!_active) return null;
    _own[peer] = token;
    return token;
  }

  Future<void> _send(String peer, Uint8List token,
      {required bool replyRequested}) async {
    try {
      await link.sendNiToken(peer, token, replyRequested: replyRequested);
    } catch (_) {}
  }

  void _onReading(NiReading r) {
    if (!_active) return;
    final event = r.event;
    final sample = r.sample;
    if (event != null) {
      _pointer.remove(r.peerId);
    } else if (sample != null && isEligible(r.peerId)) {
      _pointer.update(r.peerId, sample, now());
    }
    _refresh();
  }

  void _refresh() {
    final next = _active ? _pointer.pick(now()) : null;
    if (next == _highlighted) return;
    _highlighted = next;
    _notify();
  }

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class NearbyNiHub {
  NearbyNiSession? session;

  Future<void> deliver(MeshNiToken token) async {
    final s = session;
    if (s == null) return;
    await s.onToken(token);
  }
}

final niPlatformProvider = Provider<NiPlatform?>((ref) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? MethodChannelNiPlatform()
        : null);

final nearbyNiHubProvider = Provider<NearbyNiHub>((ref) => NearbyNiHub());
