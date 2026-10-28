import 'dart:async';

import 'package:flutter/widgets.dart';

import '../shortcuts/shortcuts.dart';

const Duration kComposerQuietFor = Duration(seconds: 4);

bool composerHoldsDraft() {
  final focus = ComposerShortcutHooks.focus;
  final text = ComposerShortcutHooks.text;
  return focus != null &&
      focus.hasFocus &&
      text != null &&
      text.text.trim().isNotEmpty;
}

String? composerDraft() => ComposerShortcutHooks.text?.text;

Future<void> composerQuiet({Duration quiet = kComposerQuietFor}) {
  if (!composerHoldsDraft()) return Future<void>.value();
  final focus = ComposerShortcutHooks.focus!;
  final text = ComposerShortcutHooks.text!;
  final done = Completer<void>();
  Timer? timer;
  late final VoidCallback onChange;
  void finish() {
    if (done.isCompleted) return;
    timer?.cancel();
    focus.removeListener(onChange);
    text.removeListener(onChange);
    done.complete();
  }

  onChange = () {
    timer?.cancel();
    if (!composerHoldsDraft() || !identical(ComposerShortcutHooks.text, text)) {
      finish();
      return;
    }
    timer = Timer(quiet, finish);
  };
  focus.addListener(onChange);
  text.addListener(onChange);
  timer = Timer(quiet, finish);
  return done.future;
}
