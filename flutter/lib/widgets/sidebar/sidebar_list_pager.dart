import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/sidebar/sidebar_more.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart' show bootEpochProvider;

class SidebarListPager {
  final Map<String, int> _shown = {};

  int shown(String section) => _shown[section] ?? kSbFirst;

  void set(String section, num? shown) {
    final s = sbStore(shown);
    if (s == 0) {
      _shown.remove(section);
    } else {
      _shown[section] = s;
    }
  }

  Map<String, int> get stored => Map.unmodifiable(_shown);
}

final sidebarListPagerProvider = Provider<SidebarListPager>((ref) {
  ref.watch(bootEpochProvider);
  ref.watch(appStateProvider.select((s) => s.selfPubkey));
  return SidebarListPager();
});

final sidebarListTickProvider = StateProvider<int>((ref) => 0);
