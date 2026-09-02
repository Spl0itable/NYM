/// The nym on a reference card: it names the author once, it names them by
/// whatever the store knows now (a kind 0 that lands after the card painted
/// included), and tapping it opens that person's menu rather than jumping to
/// the event.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/messages/nostr_ref_card.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

const _id = 'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4';
const _pub = 'f00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabe';
const _sfx = 'babe'; // the last four of _pub

/// A container holding the referenced event, so the card resolves locally and
/// never touches the network. [author] is what the stored message carries;
/// [known] optionally seeds the users store as if their kind 0 were already in.
Future<ProviderContainer> _container({
  String author = 'alice',
  String? known,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final c = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv)],
  );
  final app = c.read(appStateProvider.notifier)..goLive('selfpk', 'me#0001');
  if (known != null) app.state.users[_pub] = User(pubkey: _pub, nym: known);
  app.state.messages['#geo'] = [
    Message(
      id: _id,
      author: author,
      pubkey: _pub,
      content: 'a referenced message',
      createdAt: 1700000000,
      eventKind: 20000,
    )..geohash = 'geo',
  ];
  return c;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer c, {
  void Function(String)? onJump,
  void Function(String, String)? onOpenProfile,
}) async {
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
            child: NostrRefCard(
              token: _id,
              onJump: onJump,
              onOpenProfile: onOpenProfile,
            ),
          ),
        ),
      ),
    ),
  );
  // The card dwells 300ms before resolving; a pending Timer schedules no
  // frame, so pumpAndSettle alone never reaches it.
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the nym carries the pubkey suffix once', (tester) async {
    final c = await _container(author: 'alice');
    addTearDown(c.dispose);
    await _pump(tester, c);
    expect(find.text('alice#$_sfx'), findsOneWidget);
  });

  testWidgets('an author that already carries the suffix is not given a second',
      (tester) async {
    // Every source of the author does this: a stored user's nym, a
    // getNymFromPubkey fallback, and a stored message's own author field.
    final c = await _container(author: 'alice#$_sfx');
    addTearDown(c.dispose);
    await _pump(tester, c);
    expect(find.text('alice#$_sfx'), findsOneWidget);
    expect(find.text('alice#$_sfx#$_sfx'), findsNothing);
  });

  testWidgets('a stored nym carrying its own suffix is not doubled either',
      (tester) async {
    final c = await _container(author: 'alice', known: 'bob#$_sfx');
    addTearDown(c.dispose);
    await _pump(tester, c);
    expect(find.text('bob#$_sfx'), findsOneWidget);
  });

  testWidgets('the store wins over the author the card resolved with',
      (tester) async {
    final c = await _container(author: 'nym', known: 'realname');
    addTearDown(c.dispose);
    await _pump(tester, c);
    expect(find.text('realname#$_sfx'), findsOneWidget);
    expect(find.textContaining('nym#'), findsNothing);
  });

  testWidgets('a kind 0 landing after the card painted repaints the nym',
      (tester) async {
    // The whole point of a shared nevent is that it came from elsewhere, so
    // its author is often somebody this client has never seen. The card names
    // them by the fallback until their profile arrives.
    final c = await _container(author: 'nym#$_sfx');
    addTearDown(c.dispose);
    await _pump(tester, c);
    expect(find.text('nym#$_sfx'), findsOneWidget);

    c.read(appStateProvider.notifier).setUserPresence(
          pubkey: _pub,
          status: UserStatus.online,
          nym: 'satoshi',
        );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('satoshi#$_sfx'), findsOneWidget);
    expect(find.text('nym#$_sfx'), findsNothing);
  });

  testWidgets('tapping the nym opens that person, not the event',
      (tester) async {
    final c = await _container(author: 'alice');
    addTearDown(c.dispose);
    final jumped = <String>[];
    final opened = <(String, String)>[];
    await _pump(tester, c,
        onJump: jumped.add,
        onOpenProfile: (pk, nym) => opened.add((pk, nym)));

    await tester.tap(find.text('alice#$_sfx'));
    await tester.pumpAndSettle();

    expect(opened, [(_pub, 'alice')]);
    expect(jumped, isEmpty,
        reason: "the head's jump must not swallow the nym's own tap");
  });

  testWidgets('the nym passes the base name, with no suffix on it',
      (tester) async {
    final c = await _container(author: 'alice#$_sfx');
    addTearDown(c.dispose);
    final opened = <(String, String)>[];
    await _pump(tester, c, onOpenProfile: (pk, nym) => opened.add((pk, nym)));
    await tester.tap(find.text('alice#$_sfx'));
    await tester.pumpAndSettle();
    expect(opened, [(_pub, 'alice')]);
  });

  testWidgets('the rest of the head still jumps', (tester) async {
    final c = await _container(author: 'alice');
    addTearDown(c.dispose);
    final jumped = <String>[];
    final opened = <(String, String)>[];
    await _pump(tester, c,
        onJump: jumped.add,
        onOpenProfile: (pk, nym) => opened.add((pk, nym)));

    await tester.tap(find.text('Channel message'));
    await tester.pumpAndSettle();

    expect(jumped, [_id]);
    expect(opened, isEmpty);
  });

  testWidgets('with no profile handler the nym is inert, and the head jumps',
      (tester) async {
    final c = await _container(author: 'alice');
    addTearDown(c.dispose);
    final jumped = <String>[];
    await _pump(tester, c, onJump: jumped.add);
    await tester.tap(find.text('alice#$_sfx'));
    await tester.pumpAndSettle();
    expect(jumped, [_id]);
  });
}
