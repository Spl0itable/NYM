import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../toasts/toast_center.dart';
import 'call_service.dart';
import 'call_state.dart';

/// Singleton [CallService]; read it early so inbound invites are caught before the overlay mounts.
final callServiceProvider = Provider<CallService>((ref) {
  final service = CallService(ref);
  service.onSystemMessage = (message) {
    try {
      showToast(message);
    } catch (_) {
      // Best-effort; never throw from a status toast.
    }
  };
  ref.onDispose(service.dispose);
  return service;
});

/// The live [CallState] snapshot.
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

/// Current call state, defaulting to idle while the stream connects.
final currentCallStateProvider = Provider<CallState>((ref) {
  return ref.watch(callStateProvider).valueOrNull ?? CallState.idle;
});
