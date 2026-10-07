import 'package:flutter/services.dart';

enum NymHaptic { selection, light, medium }

class Haptics {
  const Haptics._();

  static Future<void> selection() => play(NymHaptic.selection);

  static Future<void> light() => play(NymHaptic.light);

  static Future<void> medium() => play(NymHaptic.medium);

  static Future<void> play(NymHaptic kind) async {
    try {
      switch (kind) {
        case NymHaptic.selection:
          await HapticFeedback.selectionClick();
        case NymHaptic.light:
          await HapticFeedback.lightImpact();
        case NymHaptic.medium:
          await HapticFeedback.mediumImpact();
      }
    } catch (_) {}
  }
}
