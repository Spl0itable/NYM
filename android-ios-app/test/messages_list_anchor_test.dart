import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/threads/thread_view.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/widgets/chat/messages_list.dart';
import 'package:nym_bar/widgets/columns/columns_deck.dart';

class _FakeController extends NostrController {
  _FakeController(super.ref);
  @override
  bool get isLive => true;
}

const _base = 1700000000;
const _room = ChatView.channel('room');

Message msg(int i, {int? ts}) => Message(
      id: 'msg_${i}_'.padRight(64, '0'),
      author: i.isEven ? 'alice' : 'bob',
      pubkey: (i.isEven ? 'a' : 'b') * 64,
      content: 'message $i ${'word ' * ((i * 7) % 23)}',
      createdAt: ts ?? _base + i * 600,
      eventKind: 20000,
      channel: 'room',
    );

Future<ProviderContainer> pumpHarness(WidgetTester tester,
    {int count = 60, bool columns = false}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (columns)
      StorageKeys.columnsLayout:
          '[{"type":"channel","channel":"room","geohash":""}]',
  });
  final kv = await KeyValueStore.open();
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final colors = resolveNymColors(
    theme: NymThemeKey.bitchat,
    brightness: Brightness.dark,
    solidUi: true,
  );
  final container = ProviderContainer(overrides: [
    keyValueStoreProvider.overrideWithValue(kv),
    nostrControllerProvider.overrideWith((ref) => _FakeController(ref)),
  ]);
  addTearDown(container.dispose);
  final n = container.read(appStateProvider.notifier)
    ..goLive('self' * 16, 'me#0001')
    ..switchView(_room);
  n.hydrateMessages('#room', [for (var i = 0; i < count; i++) msg(i)]);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildNymThemeData(colors),
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) {
          final at = ref.watch(activeThreadProvider);
          if (columns) return const ColumnsDeck();
          if (at != null) return ThreadView(key: ValueKey(at), thread: at);
          return const MessagesList();
        }),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return container;
}

Future<void> settleTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Finder row(int i) => find.byKey(ValueKey(msg(i).id));

Finder list() => find.descendant(
    of: find.byType(ScrollablePositionedList),
    matching: find.byType(Scrollable));

Map<int, Rect> visibleRows(WidgetTester tester, int count) {
  final out = <int, Rect>{};
  for (var i = 0; i < count; i++) {
    final f = row(i);
    if (f.evaluate().isEmpty) continue;
    final r = tester.getRect(f);
    if (r.bottom > 0 && r.top < 800) out[i] = r;
  }
  return out;
}

void main() {
  testWidgets('rows stay put while scrolled up as messages arrive',
      (tester) async {
    final c = await pumpHarness(tester);
    await tester.drag(find.byType(Scrollable), const Offset(0, 900));
    await tester.pumpAndSettle();
    final before = visibleRows(tester, 60);
    expect(before, isNotEmpty);
    expect(before.containsKey(59), isFalse, reason: 'scrolled away from the newest');

    final n = c.read(appStateProvider.notifier);
    for (var k = 0; k < 5; k++) {
      n.hydrateMessages('#room', [msg(60 + k)]);
      await tester.pump();
      await tester.pump();
      for (final e in before.entries) {
        expect(tester.getRect(row(e.key)), e.value,
            reason: 'row ${e.key} moved after arrival ${60 + k}');
      }
    }
    await settleTimers(tester);
  });

  testWidgets('the list keeps following at the bottom', (tester) async {
    final c = await pumpHarness(tester);
    final newestBefore = tester.getRect(row(59));
    c.read(appStateProvider.notifier).hydrateMessages('#room', [msg(60)]);
    await tester.pump();
    await tester.pump();
    final arrived = tester.getRect(row(60));
    expect(arrived.bottom, newestBefore.bottom);
    expect(tester.getRect(row(59)).bottom, lessThan(newestBefore.bottom));
    await settleTimers(tester);
  });

  testWidgets('leaving a thread lands where the feed was', (tester) async {
    final c = await pumpHarness(tester);
    await tester.drag(find.byType(Scrollable), const Offset(0, 900));
    await tester.pumpAndSettle();
    final before = visibleRows(tester, 60);
    expect(before.containsKey(59), isFalse);

    final rootId = msg(before.keys.first).id;
    c.read(activeThreadProvider.notifier).state =
        ActiveThread(view: _room, rootId: rootId);
    await tester.pumpAndSettle();
    expect(find.byType(ThreadView), findsOneWidget);

    c.read(activeThreadProvider.notifier).state = null;
    await tester.pumpAndSettle();
    expect(find.byType(MessagesList), findsOneWidget);
    final after = visibleRows(tester, 60);
    expect(after.keys.toSet(), before.keys.toSet());
    for (final e in before.entries) {
      expect(after[e.key], e.value, reason: 'row ${e.key}');
    }
    await settleTimers(tester);
  });

  testWidgets('a fling keeps going across an arrival', (tester) async {
    final c = await pumpHarness(tester, count: 200);
    await tester.fling(list(), const Offset(0, 600), 2500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final scrollable = tester.state<ScrollableState>(list());
    final pixelsBefore = scrollable.position.pixels;
    expect(scrollable.position.isScrollingNotifier.value, isTrue);
    final visible = visibleRows(tester, 200);
    final probe = visible.keys.reduce((a, b) => a > b ? a : b);
    final rectBefore = visible[probe]!;

    c.read(appStateProvider.notifier).hydrateMessages('#room', [msg(200)]);
    await tester.pump();
    expect(tester.getRect(row(probe)), rectBefore);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scrollable.position.isScrollingNotifier.value, isTrue,
        reason: 'the fling resumed');
    expect(tester.getRect(row(probe)).top, greaterThan(rectBefore.top));
    expect(scrollable.position.pixels, isNot(pixelsBefore));
    await tester.pumpAndSettle();
    await settleTimers(tester);
  });

  testWidgets('a finger still on the list keeps dragging it after an arrival',
      (tester) async {
    final c = await pumpHarness(tester, count: 200);
    final gesture = await tester.startGesture(tester.getCenter(list()));
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    final visible = visibleRows(tester, 200);
    final probe = visible.keys.reduce((a, b) => a > b ? a : b);
    final rectBefore = tester.getRect(row(probe));

    c.read(appStateProvider.notifier).hydrateMessages('#room', [msg(200)]);
    await tester.pump();
    await tester.pump();
    final rectAfter = tester.getRect(row(probe));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(tester.getRect(row(probe)).top, rectAfter.top + 100,
        reason: 'the drag still moves the list');
    expect(rectBefore, isNot(rectAfter));
    await gesture.up();
    await tester.pumpAndSettle();
    await settleTimers(tester);
  });

  testWidgets('a column keeps its rows put and comes back from a thread',
      (tester) async {
    final c = await pumpHarness(tester, columns: true);
    expect(find.byType(ColumnsDeck), findsOneWidget);
    await tester.drag(list(), const Offset(0, 900));
    await tester.pumpAndSettle();
    final before = visibleRows(tester, 60);
    expect(before, isNotEmpty);
    expect(before.containsKey(59), isFalse);

    final n = c.read(appStateProvider.notifier);
    n.hydrateMessages('#room', [msg(60)]);
    await tester.pump();
    await tester.pump();
    for (final e in before.entries) {
      expect(tester.getRect(row(e.key)), e.value, reason: 'row ${e.key}');
    }

    c.read(activeThreadProvider.notifier).state =
        ActiveThread(view: _room, rootId: msg(before.keys.first).id);
    await tester.pumpAndSettle();
    expect(find.byType(ThreadView), findsOneWidget);
    c.read(activeThreadProvider.notifier).state = null;
    await tester.pumpAndSettle();
    final after = visibleRows(tester, 60);
    expect(after.keys.toSet(), before.keys.toSet());
    for (final e in before.entries) {
      expect(after[e.key], e.value, reason: 'row ${e.key}');
    }
    await settleTimers(tester);
  });
}
