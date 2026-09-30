import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../state/settings_provider.dart';
import '../../core/crypto/keys.dart';
import '../../services/mesh/noise/noise_identity.dart';
import '../../state/nostr_controller.dart';
import 'mesh_controller.dart';

/// One Ghost Mode epoch; all announce identifiers rotate together so none can be followed.
class GhostEpoch {
  GhostEpoch({
    required this.meshIdentity,
    required this.privkey,
    required this.pubkey,
    required this.nickname,
    required this.startedAt,
  });

  final NoiseIdentity meshIdentity;
  final Uint8List privkey;
  final String pubkey;
  final String nickname;
  final DateTime startedAt;
}

class GhostState {
  const GhostState({this.enabled = false, this.epochs = const []});

  final bool enabled;

  /// Newest first; older epochs are kept so gift wraps to rotated-away pubkeys still decrypt.
  final List<GhostEpoch> epochs;

  GhostEpoch? get current => epochs.isEmpty ? null : epochs.first;

  /// Every pubkey this session presented, for the gift-wrap `#p` filter.
  List<String> get pubkeys => [for (final e in epochs) e.pubkey];

  /// Every secret key this session held, for unwrap candidates.
  List<Uint8List> get secretKeys => [for (final e in epochs) e.privkey];

  GhostState copyWith({bool? enabled, List<GhostEpoch>? epochs}) => GhostState(
        enabled: enabled ?? this.enabled,
        epochs: epochs ?? this.epochs,
      );
}

/// Advertises a throwaway, unpersisted mesh identity rotated every [rotateEvery], unlinked to the npub.
class GhostModeController extends StateNotifier<GhostState> {
  GhostModeController({this.onRotate, this.persist})
      : super(const GhostState());

  /// Persists only the on/off flag, never the keys, so a restart comes back ghosted with a new identity.
  final void Function(bool enabled)? persist;

  static const Duration rotateEvery = Duration(minutes: 15);

  /// Retired epochs that stay decryptable (~2h of replies).
  static const int maxEpochs = 8;

  /// Called after rotation so the mesh restarts and Nostr subscriptions re-point.
  final Future<void> Function()? onRotate;

  Timer? _timer;
  final Random _random = Random.secure();

  Future<void> enable() async {
    if (state.enabled) return;
    persist?.call(true);
    state = state.copyWith(enabled: true);
    await _newEpoch();
    _arm();
  }

  Future<void>? _restoreFuture;

  /// Re-arms a persisted session with a fresh identity; doesn't fire [onRotate], which would re-enter the mesh start in progress.
  Future<void> restore({required bool wasEnabled}) {
    if (!wasEnabled || state.enabled) return Future.value();
    return _restoreFuture ??= () async {
      final epoch = await _mintEpoch();
      state = GhostState(enabled: true, epochs: [epoch]);
      _arm();
    }();
  }

  /// The mesh awaits this before reading state, so a restart never announces the real identity first.
  Future<void> ensureRestored() => _restoreFuture ?? Future.value();

  Future<void> disable() async {
    persist?.call(false);
    _timer?.cancel();
    _timer = null;
    // Drop every key with the mode so it leaves no trail.
    state = const GhostState();
    await onRotate?.call();
  }

  /// Forces a rotation now.
  Future<void> rotateNow() async {
    if (!state.enabled) return;
    await _newEpoch();
    _arm();
  }

  Future<GhostEpoch> _mintEpoch() async {
    final priv = generatePrivateKey();
    return GhostEpoch(
      meshIdentity: await NoiseIdentity.ephemeral(),
      privkey: priv,
      pubkey: getPublicKeyHex(priv),
      nickname: _pseudonym(),
      startedAt: DateTime.now(),
    );
  }

  Future<void> _newEpoch() async {
    final next = [await _mintEpoch(), ...state.epochs];
    if (next.length > maxEpochs) next.removeRange(maxEpochs, next.length);
    state = state.copyWith(epochs: next);
    await onRotate?.call();
  }

  /// `ghost#` plus four random hex, not derived from the pubkey so the two can't be linked.
  String _pseudonym() {
    const hex = '0123456789abcdef';
    final b = StringBuffer('ghost#');
    for (var i = 0; i < 4; i++) {
      b.write(hex[_random.nextInt(16)]);
    }
    return b.toString();
  }

  /// Jittered so rotations can't be recognized by their period.
  void _arm() {
    _timer?.cancel();
    final jitterMs = _random.nextInt(rotateEvery.inMilliseconds ~/ 4);
    _timer = Timer(rotateEvery + Duration(milliseconds: jitterMs), () async {
      if (!state.enabled) return;
      await _newEpoch();
      _arm();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// Explicitly typed because this and meshControllerProvider reference each other.
final StateNotifierProvider<GhostModeController, GhostState> ghostModeProvider =
    StateNotifierProvider<GhostModeController, GhostState>((ref) {
  final kv = ref.read(keyValueStoreProvider);
  final controller = GhostModeController(
    persist: (on) => kv.setBool(StorageKeys.ghostMode, on),
    onRotate: () async {
      // Re-point gift-wrap subscriptions before the mesh returns, so peers reading the new announce can be answered.
      ref.read(nostrControllerProvider).refreshEphemeralSubscriptions();
      await ref.read(meshControllerProvider.notifier).restart();
    },
  );
  unawaited(controller.restore(
    wasEnabled: kv.getBool(StorageKeys.ghostMode),
  ));
  return controller;
});
