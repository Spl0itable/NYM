import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/features/emoji/emoji_prefetch.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/widgets/context_menu/context_menu_panel.dart';
import 'package:nym_bar/screens/home_shell.dart';
import 'package:nym_bar/widgets/sidebar/sidebar.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

/// The production initial state is now the EMPTY logged-out shell (the demo seed
/// was removed — it leaked into login/first-run). This smoke test wants demo
/// content to render, so it injects `AppState.seed()` (kept for tests) via an
/// override, exactly as a real session would once data arrives.
class _SeededAppState extends AppStateNotifier {
  _SeededAppState() {
    state = AppState.seed();
  }
}

void main() {
  // Custom-emoji ingest arms a module-global deferred prefetch Timer; cancel
  // it so widget tests don't fail on a pending timer at teardown.
  tearDown(resetCustomEmojiPrefetchForTest);
  testWidgets('HomeShell renders a sample channel and a message',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();

    // A roomy surface so the desktop layout (sidebar + chat pane) is exercised.
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(kv),
          appStateProvider.overrideWith((ref) => _SeededAppState()),
        ],
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          home: const HomeShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Sidebar channel list shows the default channel.
    expect(find.text('#nymchat'), findsWidgets);

    // The chat pane shows seeded messages from the active (#nymchat) view.
    expect(
      find.text('wake up… the messenger has you 🐇'),
      findsOneWidget,
    );

    // Sidebar identity header (also appears as the author of self messages).
    expect(find.text('you#1a2b'), findsWidgets);

    // ChatPane kicks the module-global 3s custom-emoji prefetch; cancel it
    // INSIDE the body — the binding's pending-timer invariant runs before
    // group tearDown callbacks.
    resetCustomEmojiPrefetchForTest();
  });

  testWidgets('the left edge backs out of a thread, the right edge returns',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();
    // A phone-width surface: the edge swipe is narrow-layout only.
    tester.view.physicalSize = const Size(390, 840);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat, brightness: Brightness.dark, solidUi: true);
    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      appStateProvider.overrideWith((ref) => _SeededAppState()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: buildNymThemeData(colors), home: const HomeShell()),
    ));
    await tester.pumpAndSettle();

    // A thread needs a root with a real event id, which the seed has none of.
    final app = container.read(appStateProvider);
    final rootMsg = Message(
      id: 'a' * 64,
      author: 'someone',
      pubkey: 'b' * 64,
      content: 'the root of a thread',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    app.messages.putIfAbsent(app.view.storageKey, () => <Message>[]).add(rootMsg);
    container.read(activeThreadProvider.notifier).state =
        ActiveThread(view: app.view, rootId: threadKeyForMessage(rootMsg));
    await tester.pumpAndSettle();
    expect(container.read(activeThreadProvider), isNotNull);

    Future<void> swipe(Offset from, Offset to) async {
      final g = await tester.startGesture(from);
      await g.moveTo(to);
      await g.up();
      await tester.pumpAndSettle();
    }

    // Left edge, travelling right: out of the thread, and NOT into the drawer.
    await swipe(const Offset(10, 400), const Offset(140, 400));
    expect(container.read(activeThreadProvider), isNull,
        reason: 'the left-edge swipe should back out of the thread');
    expect(tester.getTopLeft(find.byType(Sidebar)).dx, lessThan(0),
        reason: 'and must leave the sidebar off-screen while a thread was open');

    // Right edge, travelling left: back into the same thread.
    await swipe(const Offset(380, 400), const Offset(250, 400));
    expect(container.read(activeThreadProvider)?.rootId,
        threadKeyForMessage(rootMsg),
        reason: 'the right-edge swipe should step back into the thread');

    // Left edge again with no thread open: the drawer, as before.
    container.read(activeThreadProvider.notifier).state = null;
    await tester.pumpAndSettle();
    await swipe(const Offset(10, 400), const Offset(140, 400));
    expect(tester.getTopLeft(find.byType(Sidebar)).dx, 0,
        reason: 'with no thread open the left edge still opens the sidebar');

    // In a PM with no thread to return to, the same swipe opens the menu the
    // header opens on tap.
    _lastThreadClear(container);
    container.read(appStateProvider.notifier).switchView(
        ChatView.pm('c' * 64));
    await tester.pumpAndSettle();
    await swipe(const Offset(380, 400), const Offset(250, 400));
    expect(find.byType(ContextMenuPanel), findsOneWidget,
        reason: 'a right-edge swipe in a PM opens the contact menu');

    resetCustomEmojiPrefetchForTest();
  });
}

/// Leaving the conversation the thread belonged to is what clears it; the shell
/// only reopens a thread whose view is the one on screen.
void _lastThreadClear(ProviderContainer container) {
  container.read(activeThreadProvider.notifier).state = null;
}
