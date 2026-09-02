import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/translate/message_translation.dart';
import 'package:nym_bar/features/translate/translate_service.dart';
import 'package:nym_bar/features/translate/translation_cache.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

/// The message list re-keys its children by index, so an ARRIVING MESSAGE tears
/// down and rebuilds the rows below it. [MessageTranslation] started its request
/// in `initState` and held the Future in its State, so a rebuilt row started
/// over: an already-translated message flashed "Translating..." and spent
/// another API call on text it had already translated.

/// Counts calls and lets the test decide when each one settles.
class _CountingTranslate extends TranslateService {
  _CountingTranslate() : super();
  int calls = 0;
  final List<Completer<TranslationResult>> pending = [];

  @override
  Future<TranslationResult> translate(String text, String target) {
    calls++;
    final c = Completer<TranslationResult>();
    pending.add(c);
    return c.future;
  }

  void completeAll(String text) {
    for (final c in pending) {
      if (!c.isCompleted) {
        c.complete(
            TranslationResult(translatedText: text, detectedLanguage: 'es'));
      }
    }
    pending.clear();
  }

  void failAll() {
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(const TranslateException('boom'));
    }
    pending.clear();
  }
}

late ProviderContainer _container;

Future<void> _newContainer() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  _container = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(kv)]);
  addTearDown(_container.dispose);
}

Widget _host(Widget child) {
  final colors = resolveNymColors(
      theme: NymThemeKey.bitchat, brightness: Brightness.dark, solidUi: true);
  return UncontrolledProviderScope(
    container: _container,
    child: MaterialApp(
      theme: buildNymThemeData(colors),
      home: Scaffold(body: child),
    ),
  );
}

/// The row at its original slot, then the same row after a message landed above
/// it — a different position in the list, so a different element and a fresh
/// State.
Widget _atSlot(int slot, TranslateService service,
        {String content = 'hola', String lang = 'en'}) =>
    Column(children: [
      for (var i = 0; i < slot; i++) SizedBox(key: ValueKey('pad$i'), height: 1),
      MessageTranslation(
          key: ValueKey('slot-$slot'),
          content: content,
          targetLang: lang,
          service: service),
    ]);

void main() {
  testWidgets('a rebuilt row reuses the finished translation', (tester) async {
    await _newContainer();
    final service = _CountingTranslate();

    await tester.pumpWidget(_host(_atSlot(0, service)));
    expect(service.calls, 1);
    expect(find.text('Translating...'), findsOneWidget);

    service.completeAll('hello');
    await tester.pump();
    expect(find.textContaining('hello'), findsOneWidget);

    await tester.pumpWidget(_host(_atSlot(1, service)));
    await tester.pump();

    expect(service.calls, 1,
        reason: 'the same text and language must not be translated twice');
    expect(find.text('Translating...'), findsNothing,
        reason: 'an already-translated message must not flash Translating...');
    expect(find.textContaining('hello'), findsOneWidget);
  });

  testWidgets('re-entering the channel repaints the translation without a flash',
      (tester) async {
    await _newContainer();
    final service = _CountingTranslate();

    await tester.pumpWidget(_host(_atSlot(0, service)));
    service.completeAll('hello');
    await tester.pump();
    expect(find.textContaining('hello'), findsOneWidget);

    // Leave the channel: the whole message list goes away, so nothing of the
    // row's State survives.
    await tester.pumpWidget(_host(const Text('another channel')));
    await tester.pump();

    // Come back. The FIRST frame must already carry the translation — a
    // FutureBuilder handed an even already-complete future renders one waiting
    // frame, so without the settled result seeding it every translated row in
    // the channel flashed "Translating..." on the way back in, which reads as
    // the app re-translating the whole conversation.
    await tester.pumpWidget(_host(_atSlot(0, service)));

    expect(find.text('Translating...'), findsNothing,
        reason: 'no waiting frame for a translation that is already done');
    expect(find.textContaining('hello'), findsOneWidget);
    expect(service.calls, 1, reason: 'and no second API call');
  });

  testWidgets('a rebuild MID-FLIGHT joins the request rather than starting one',
      (tester) async {
    await _newContainer();
    final service = _CountingTranslate();

    await tester.pumpWidget(_host(_atSlot(0, service)));
    expect(service.calls, 1);

    // The message arrives while the translation is still in flight.
    await tester.pumpWidget(_host(_atSlot(1, service)));
    await tester.pump();
    expect(service.calls, 1);
    expect(find.text('Translating...'), findsOneWidget);

    service.completeAll('hello');
    await tester.pump();
    expect(find.textContaining('hello'), findsOneWidget,
        reason: 'the rebuilt row still receives the result');
  });

  testWidgets('a different target language is its own translation',
      (tester) async {
    await _newContainer();
    final service = _CountingTranslate();

    await tester.pumpWidget(_host(_atSlot(0, service, lang: 'en')));
    service.completeAll('hello');
    await tester.pump();

    await tester.pumpWidget(_host(_atSlot(1, service, lang: 'fr')));
    await tester.pump();
    expect(service.calls, 2);
    expect(find.text('Translating...'), findsOneWidget);
    service.completeAll('bonjour');
    await tester.pump();
    expect(find.textContaining('bonjour'), findsOneWidget);
  });

  testWidgets('different text is its own translation', (tester) async {
    await _newContainer();
    final service = _CountingTranslate();

    await tester.pumpWidget(_host(_atSlot(0, service, content: 'hola')));
    service.completeAll('hello');
    await tester.pump();

    await tester.pumpWidget(_host(_atSlot(1, service, content: 'adios')));
    await tester.pump();
    expect(service.calls, 2);
  });

  testWidgets('a FAILURE is not cached, so a rebuild retries', (tester) async {
    await _newContainer();
    final service = _CountingTranslate();

    await tester.pumpWidget(_host(_atSlot(0, service)));
    service.failAll();
    await tester.pump();
    expect(find.text('Translation failed'), findsOneWidget);

    await tester.pumpWidget(_host(_atSlot(1, service)));
    await tester.pump();
    expect(service.calls, 2,
        reason: 'a stale error must not be replayed for the whole session');

    service.completeAll('hello');
    await tester.pump();
    expect(find.textContaining('hello'), findsOneWidget);
  });

  testWidgets('the failure system message is posted once, not once per rebuild',
      (tester) async {
    await _newContainer();
    final service = _CountingTranslate();
    final notifier = _container.read(appStateProvider.notifier)
      ..goLive('selfpk', 'me#0001');

    await tester.pumpWidget(_host(_atSlot(0, service)));
    // Rebuild several times while the one request is still in flight.
    for (var slot = 1; slot <= 3; slot++) {
      await tester.pumpWidget(_host(_atSlot(slot, service)));
      await tester.pump();
    }
    expect(service.calls, 1);

    service.failAll();
    await tester.pump();

    final systemRows = notifier.state.messages.values
        .expand((l) => l)
        .where((m) => m.content.contains('Translation failed'))
        .length;
    expect(systemRows, 1);
  });

  group('the cache itself', () {
    test('is bounded and evicts least-recently-used', () async {
      final cache = TranslationCache();
      Future<TranslationResult> ok() async =>
          const TranslationResult(translatedText: 'x', detectedLanguage: 'es');

      for (var i = 0; i < TranslationCache.max; i++) {
        cache.resolve('t$i', 'en', ok);
      }
      expect(cache.has('t0', 'en'), isTrue);
      // Touch the oldest so it is no longer the eviction candidate.
      cache.resolve('t0', 'en', ok);
      cache.resolve('overflow', 'en', ok);

      expect(cache.has('t0', 'en'), isTrue, reason: 're-used, so kept');
      expect(cache.has('t1', 'en'), isFalse, reason: 'least recently used');
      expect(cache.has('overflow', 'en'), isTrue);
    });

    test('text and language both take part in the key', () {
      final cache = TranslationCache();
      expect(TranslationCache.keyFor('a', 'en'),
          isNot(TranslationCache.keyFor('a', 'fr')));
      expect(TranslationCache.keyFor('a', 'en'),
          isNot(TranslationCache.keyFor('b', 'en')));
      cache.clear();
    });
  });
}
