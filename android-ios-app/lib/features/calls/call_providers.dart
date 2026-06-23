// call_providers.dart - Riverpod wiring for the calling feature.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_service.dart';
import 'call_state.dart';

/// The singleton [CallService] for the app. Registers the inbound call-signal
/// handler on construction (see [CallService]). Boot it once early (e.g. read
/// it in the root widget) so inbound invites are caught even before the overlay
/// is mounted.
final callServiceProvider = Provider<CallService>((ref) {
  final service = CallService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// The live [CallState] snapshot (idle/ringing/incoming/connecting/active +
/// participant streams). Rebuilds whenever the service publishes a new state.
final callStateProvider = StreamProvider<CallState>((ref) {
  final service = ref.watch(callServiceProvider);
  final controller = StreamController<CallState>();
  controller.add(service.state.value);
  void listener() => controller.add(service.state.value);
  service.state.addListener(listener);
  ref.onDispose(() {
    service.state.removeListener(listener);
    controller.close();
  });
  return controller.stream;
});

/// Convenience: the current call state, defaulting to idle while the stream
/// is connecting (so widgets never juggle AsyncValue for a value that always
/// has a sensible default).
final currentCallStateProvider = Provider<CallState>((ref) {
  return ref.watch(callStateProvider).valueOrNull ?? CallState.idle;
});
