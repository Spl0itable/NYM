/// The mesh peer row's ping button has to actually fire a ping.
///
/// Its glyph changed (a share icon read as "send this somewhere", which is not
/// what it does), and a glyph swap is exactly the kind of edit that can quietly
/// take a control's behaviour with it — a wrong icon size, a lost onPressed, a
/// tap target that no longer covers the drawn shape. This drives the shipped
/// screen: it finds the button by its tooltip, taps it, and checks the
/// controller was asked to ping that peer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/mesh/mesh_controller.dart';
import 'package:nym_bar/features/mesh/mesh_screen.dart';
import 'package:nym_bar/services/mesh/mesh_peer.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

/// A controller that records pings instead of touching a radio. The real one
/// is a StateNotifier, so a subclass carrying a seeded state is enough for the
/// screen to render against.
class _FakeMeshController extends MeshController {
  _FakeMeshController(Ref ref, MeshUiState seed)
      : super(ref: ref, nickname: () => 'me') {
    state = seed;
  }

  final List<String> pinged = [];

  @override
  Future<void> ping(String peerID) async => pinged.add(peerID);
}

/// A bare Ref, so a MeshController can be built outside the real provider.
final _refProvider = Provider<Ref>((ref) => ref);

MeshPeer _peer() => MeshPeer(
      peerID: 'abcdef0123456789',
      nickname: 'alice',
      lastSeen: DateTime.now(),
    );

void main() {
  testWidgets('tapping the ping button pings that peer', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();
    tester.view.physicalSize = const Size(430 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    late _FakeMeshController fake;
    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      meshControllerProvider.overrideWith((ref) {
        fake = _FakeMeshController(
          ref,
          MeshUiState(running: true, enabled: true, peers: [_peer()]),
        );
        return fake;
      }),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildNymThemeData(resolveNymColors(
            theme: NymThemeKey.bitchat,
            brightness: Brightness.dark,
            solidUi: true,
          )),
          home: const MeshScreen(),
        ),
      ),
    );
    await tester.pump();

    final tip = find.byTooltip('Ping');
    expect(tip, findsOneWidget, reason: 'the ping button must be on screen');
    final button =
        find.ancestor(of: tip, matching: find.byType(IconButton)).first;

    final iconButton = tester.widget<IconButton>(button);
    expect(iconButton.onPressed, isNotNull,
        reason: 'an idle peer\'s ping button must be enabled');

    await tester.tap(button);
    await tester.pump();

    expect(fake.pinged, ['abcdef0123456789']);
  });

  test('a ping with the radio stopped reports, rather than doing nothing', () {
    // The tap lands and the handler runs; without a radio there is nothing to
    // measure. Returning in silence made the button look dead.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = MeshController(ref: container.read(_refProvider), nickname: () => 'me');
    addTearDown(c.dispose);
    expect(c.state.running, isFalse);
    c.ping('abcdef0123456789');
    expect(c.state.pings['abcdef0123456789']?.lost, isTrue);
    expect(c.state.pings['abcdef0123456789']?.isWaiting, isFalse);
  });

  testWidgets('a ping already in flight disables the button', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();
    tester.view.physicalSize = const Size(430 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      meshControllerProvider.overrideWith((ref) => _FakeMeshController(
            ref,
            MeshUiState(
              running: true,
              enabled: true,
              peers: [_peer()],
              pings: const {'abcdef0123456789': MeshPingState.waiting()},
            ),
          )),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildNymThemeData(resolveNymColors(
            theme: NymThemeKey.bitchat,
            brightness: Brightness.dark,
            solidUi: true,
          )),
          home: const MeshScreen(),
        ),
      ),
    );
    await tester.pump();

    final button = find
        .ancestor(
            of: find.byTooltip('Ping'), matching: find.byType(IconButton))
        .first;
    expect(tester.widget<IconButton>(button).onPressed, isNull);
    // And the row says why, rather than looking inert.
    expect(find.textContaining('pinging'), findsOneWidget);
  });
}
