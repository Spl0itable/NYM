/// A reference card shows the referenced event as a MESSAGE body — media, link
/// previews, and the same height-based "Read more" clamp — not a hard-truncated
/// plain-text excerpt. Tapping the toggle must expand the body, not fire the
/// card's own jump.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/messages/nostr_ref_card.dart';
import 'package:nym_bar/features/messages/format/nym_format.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

const _id = 'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4';
const _pub = 'f00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabe';

String _longBody() =>
    List.generate(80, (i) => 'paragraph $i of the referenced event').join('\n');

/// A container whose message store already holds the referenced event, so the
/// card resolves locally and never touches the network.
Future<ProviderContainer> _container(String body) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final c = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv)],
  );
  final app = c.read(appStateProvider.notifier)..goLive('selfpk', 'me#0001');
  app.state.messages['#geo'] = [
    Message(
      id: _id,
      author: 'alice',
      pubkey: _pub,
      content: body,
      createdAt: 1700000000,
    )..geohash = 'geo',
  ];
  return c;
}

Future<void> _pump(WidgetTester tester, ProviderContainer c,
    {void Function(String)? onJump}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildNymThemeData(resolveNymColors(
          theme: NymThemeKey.bitchat,
          brightness: Brightness.dark,
          solidUi: true,
        )),
        home: Scaffold(
          body: SingleChildScrollView(
            child: NostrRefCard(token: _id, onJump: onJump),
          ),
        ),
      ),
    ),
  );
  // The card dwells 300ms before resolving (so flinging past a row does not
  // fire a query); a pending Timer schedules no frame, so pumpAndSettle alone
  // never reaches it.
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a long referenced body gets a Read more toggle', (tester) async {
    final c = await _container(_longBody());
    addTearDown(c.dispose);
    await _pump(tester, c);

    expect(find.text('Read more'), findsOneWidget,
        reason: 'the body is clamped, not cut off at a character count');
    expect(find.textContaining('paragraph 0'), findsOneWidget);
  });

  testWidgets('the toggle expands the body rather than firing the jump',
      (tester) async {
    final c = await _container(_longBody());
    addTearDown(c.dispose);
    final jumped = <String>[];
    await _pump(tester, c, onJump: jumped.add);

    await tester.tap(find.text('Read more'));
    await tester.pumpAndSettle();

    expect(find.text('Show less'), findsOneWidget, reason: 'it expanded');
    expect(jumped, isEmpty,
        reason: "the card's own tap target must not swallow the toggle");
  });

  testWidgets('the header is the jump affordance', (tester) async {
    final c = await _container(_longBody());
    addTearDown(c.dispose);
    final jumped = <String>[];
    await _pump(tester, c, onJump: jumped.add);

    // The body is real content now, so the tap target lives on the head rather
    // than wrapped around links, media and the toggle. Not the nym inside it:
    // that opens the author's menu (nostr_card_author_test.dart).
    await tester.tap(find.text('#geo'));
    await tester.pumpAndSettle();
    expect(jumped, [_id]);
  });

  testWidgets('tapping the body does not jump', (tester) async {
    final c = await _container(_longBody());
    addTearDown(c.dispose);
    final jumped = <String>[];
    await _pump(tester, c, onJump: jumped.add);

    await tester.tap(find.textContaining('paragraph 0'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(jumped, isEmpty);
  });

  testWidgets('a short body carries no toggle', (tester) async {
    final c = await _container('just a line');
    addTearDown(c.dispose);
    await _pump(tester, c);

    expect(find.text('Read more'), findsNothing);
    expect(find.textContaining('just a line'), findsOneWidget);
  });

  testWidgets('an empty body says so', (tester) async {
    final c = await _container('');
    addTearDown(c.dispose);
    await _pump(tester, c);

    expect(find.text('No text content'), findsOneWidget);
  });

  test('a card body does not unfurl further cards', () {
    // Otherwise a referenced event that itself references one nests forever.
    final blocks = NymFormat.format(
        'see note1qqsxyz023456789acdefghjklmnpqrstuvwxyzacdefgh',
        const FormatContext());
    final refs = <NostrRefNode>[];
    for (final b in blocks) {
      if (b is ParagraphBlock) refs.addAll(b.inlines.whereType<NostrRefNode>());
    }
    expect(refs, hasLength(1),
        reason: 'the chip still renders — only the CARD is suppressed');
  });
}
