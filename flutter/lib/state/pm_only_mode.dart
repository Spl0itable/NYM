import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_state.dart';
import 'settings_provider.dart';

class PmOnlyEmptyNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<ChatView>(currentViewProvider, (prev, next) {
      if (prev != next) state = false;
    });
    ref.listen<bool>(
        settingsProvider.select((s) => s.groupChatPMOnlyMode), (_, on) {
      if (!on) state = false;
    });
    return false;
  }

  void show() => state = true;

  void hide() => state = false;
}

final pmOnlyEmptyProvider =
    NotifierProvider<PmOnlyEmptyNotifier, bool>(PmOnlyEmptyNotifier.new);

final pmOnlyEmptyShownProvider = Provider<bool>((ref) =>
    ref.watch(pmOnlyEmptyProvider) &&
    ref.watch(settingsProvider.select((s) => s.groupChatPMOnlyMode)) &&
    ref.watch(currentViewProvider).kind == ViewKind.channel);
