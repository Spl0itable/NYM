import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nym_bar/features/translate/auto_translate.dart';
import 'package:nym_bar/features/translate/translate_service.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/services/api/api_client.dart';

/// A [TranslateService] that returns a canned result without touching the
/// network, so the notifier's caching / no-op logic can be exercised offline.
class _FakeTranslate extends TranslateService {
  _FakeTranslate(this.result, {this.calls}) : super();
  final TranslationResult result;
  final List<String>? calls;
  @override
  Future<TranslationResult> translate(String text, String target) async {
    calls?.add(text);
    return result;
  }
}

/// A [TranslateService] that throws [failTimes] times, then returns [result] —
/// exercises the notifier's retry/backoff path.
class _FlakyTranslate extends TranslateService {
  _FlakyTranslate({required this.failTimes, required this.result}) : super();
  int failTimes;
  final TranslationResult result;
  @override
  Future<TranslationResult> translate(String text, String target) async {
    if (failTimes > 0) {
      failTimes--;
      throw const TranslateException('boom');
    }
    return result;
  }
}

/// A real [TranslateService] whose proxy "translates" by upper-casing the text
/// it actually receives — so what it never receives (an `@mention`) is provably
/// left untouched.
TranslateService _uppercasingService() {
  final mock = MockClient((req) async {
    final text = (jsonDecode(req.body)['text'] ?? '').toString();
    return http.Response(
      jsonEncode({'translatedText': text.toUpperCase(), 'detectedLanguage': 'es'}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return TranslateService(
    api: ApiClient(client: mock, baseUrl: 'https://h/api/proxy'),
  );
}

Message _msg({
  String id = 'm1',
  String content = 'hola',
  bool isOwn = false,
  bool isPM = false,
  bool isGroup = false,
  MessageKind kind = MessageKind.normal,
}) =>
    Message(
      id: id,
      author: 'a',
      pubkey: 'pk',
      content: content,
      createdAt: 1,
      isOwn: isOwn,
      isPM: isPM,
      isGroup: isGroup,
      kind: kind,
    );

void main() {
  group('autoTranslateAppliesTo', () {
    const off = Settings(autoTranslate: false);
    const on = Settings(autoTranslate: true);

    test('never applies when the master switch is off', () {
      expect(autoTranslateAppliesTo(_msg(), off), isFalse);
    });

    test('never applies to your own messages or system rows', () {
      expect(autoTranslateAppliesTo(_msg(isOwn: true), on), isFalse);
      expect(
        autoTranslateAppliesTo(_msg(kind: MessageKind.system), on),
        isFalse,
      );
    });

    test('public channel messages honour the channels gate', () {
      final ch = _msg(); // not PM, not group ⇒ public channel
      expect(autoTranslateAppliesTo(ch, on), isTrue);
      expect(
        autoTranslateAppliesTo(
            ch, const Settings(autoTranslate: true, autoTranslateChannels: false)),
        isFalse,
      );
    });

    test('PMs honour the PMs gate', () {
      final pm = _msg(isPM: true);
      expect(autoTranslateAppliesTo(pm, on), isTrue);
      expect(
        autoTranslateAppliesTo(
            pm, const Settings(autoTranslate: true, autoTranslatePMs: false)),
        isFalse,
      );
    });

    test('group chats honour the groups gate', () {
      final g = _msg(isGroup: true);
      expect(autoTranslateAppliesTo(g, on), isTrue);
      expect(
        autoTranslateAppliesTo(
            g, const Settings(autoTranslate: true, autoTranslateGroups: false)),
        isFalse,
      );
    });

    test('always applies to the Nymbot welcome, even with the toggle off', () {
      const off = Settings(autoTranslate: false);
      expect(autoTranslateAppliesTo(_msg(id: 'nymbot-welcome'), off), isTrue);
      expect(
        autoTranslateAppliesTo(_msg(id: 'nymbot-welcome-1700000000'), off),
        isTrue,
      );
      // …but never your own message or a system row.
      expect(
        autoTranslateAppliesTo(_msg(id: 'nymbot-welcome', isOwn: true), off),
        isFalse,
      );
      expect(
        autoTranslateAppliesTo(
            _msg(id: 'nymbot-welcome', kind: MessageKind.system), off),
        isFalse,
      );
    });
  });

  group('autoTranslateTargetFor', () {
    test('prefers translateLanguage, falls back to the app UI language', () {
      expect(
        autoTranslateTargetFor(
            const Settings(translateLanguage: 'es', uiLanguage: 'fr')),
        'es',
      );
      expect(
        autoTranslateTargetFor(
            const Settings(translateLanguage: '', uiLanguage: 'fr')),
        'fr',
      );
    });

    test('is empty when neither a translation nor a non-English UI lang is set',
        () {
      expect(autoTranslateTargetFor(const Settings()), '');
      expect(
        autoTranslateTargetFor(const Settings(uiLanguage: 'en')),
        '',
      );
    });
  });

  group('AutoTranslateNotifier.ensureForView', () {
    test('queues only eligible messages (skips own + system rows)', () async {
      final n = AutoTranslateNotifier(
        service: _FakeTranslate(const TranslationResult(
            translatedText: 'X', detectedLanguage: 'es')),
      );
      final msgs = [
        _msg(id: 'own', content: 'a', isOwn: true),
        _msg(id: 'sys', content: 'b', kind: MessageKind.system),
        _msg(id: 'c1', content: 'hello'),
        _msg(id: 'c2', content: 'world'),
      ];
      n.ensureForView(msgs, 'en', const Settings(autoTranslate: true));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(n.state.containsKey('own'), isFalse);
      expect(n.state.containsKey('sys'), isFalse);
      expect(n.state['c1']?.isReady, isTrue);
      expect(n.state['c2']?.isReady, isTrue);
    });

    test('no-ops without a target or when auto-translate is disabled', () {
      final n = AutoTranslateNotifier(
        service: _FakeTranslate(const TranslationResult(
            translatedText: 'X', detectedLanguage: 'es')),
      );
      n.ensureForView(
          [_msg(content: 'hi')], '', const Settings(autoTranslate: true));
      expect(n.state, isEmpty);
      n.ensureForView(
          [_msg(content: 'hi')], 'en', const Settings(autoTranslate: false));
      expect(n.state, isEmpty);
    });
  });

  group('AutoTranslateNotifier', () {
    test('does nothing without a target language', () {
      final n = AutoTranslateNotifier(
        service: _FakeTranslate(const TranslationResult(
            translatedText: 'hello', detectedLanguage: 'es')),
      );
      n.ensure(_msg(), '');
      expect(n.state, isEmpty);
    });

    test('translates and marks ready when the text differs', () async {
      final n = AutoTranslateNotifier(
        service: _FakeTranslate(const TranslationResult(
            translatedText: 'hello', detectedLanguage: 'es')),
      );
      n.ensure(_msg(content: 'hola'), 'en');
      // loading first
      expect(n.state['m1']!.status, AutoTranslateStatus.loading);
      await Future<void>.delayed(Duration.zero);
      final e = n.state['m1']!;
      expect(e.status, AutoTranslateStatus.ready);
      expect(e.translated, 'hello');
      expect(e.detected, 'es');
    });

    test('marks no-op when the message is already in the target language',
        () async {
      final n = AutoTranslateNotifier(
        // detected == target ⇒ nothing to translate.
        service: _FakeTranslate(const TranslationResult(
            translatedText: 'hello', detectedLanguage: 'en')),
      );
      n.ensure(_msg(content: 'hello'), 'en');
      await Future<void>.delayed(Duration.zero);
      expect(n.state['m1']!.status, AutoTranslateStatus.noop);
    });

    test('preserves @mention nicknames — never translates them', () async {
      final n = AutoTranslateNotifier(service: _uppercasingService());
      n.ensure(_msg(content: '@alice#1a2b hello there'), 'en');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final e = n.state['m1']!;
      expect(e.status, AutoTranslateStatus.ready);
      // The prose is translated (upper-cased) but the mention is byte-identical.
      expect(e.translated, contains('@alice#1a2b'));
      expect(e.translated, contains('HELLO THERE'));
      // The nickname itself was not sent upstream, so it wasn't upper-cased.
      expect(e.translated.contains('@ALICE'), isFalse);
    });

    test('preserves URLs and :shortcode: emoji so media/links survive',
        () async {
      final n = AutoTranslateNotifier(service: _uppercasingService());
      n.ensure(
          _msg(content: 'look https://ex.com/a.png :party: hello'), 'en');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final e = n.state['m1']!;
      expect(e.status, AutoTranslateStatus.ready);
      // URL + custom-emoji shortcode kept byte-identical (never sent upstream),
      // so MessageContent re-renders the image, link preview, and emoji.
      expect(e.translated, contains('https://ex.com/a.png'));
      expect(e.translated, contains(':party:'));
      // The URL was NOT translated/upper-cased…
      expect(e.translated.contains('HTTPS://'), isFalse);
      expect(e.translated.contains(':PARTY:'), isFalse);
      // …but the surrounding prose was.
      expect(e.translated, contains('HELLO'));
    });

    test('preserves inline code spans so commands survive (e.g. `?help`)',
        () async {
      final n = AutoTranslateNotifier(service: _uppercasingService());
      n.ensure(_msg(content: 'type `?help` for the guide'), 'en');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final e = n.state['m1']!;
      expect(e.status, AutoTranslateStatus.ready);
      // The code span is byte-identical; the surrounding prose is translated.
      expect(e.translated, contains('`?help`'));
      expect(e.translated.contains('`?HELP`'), isFalse);
      expect(e.translated, contains('TYPE'));
    });

    test('keeps a quote-reply line verbatim (renders as a quote, not a mention)',
        () async {
      final n = AutoTranslateNotifier(service: _uppercasingService());
      // A quote reply: `> @author: quoted` header + the reply below.
      n.ensure(_msg(content: '> @alice#1a2b: hola amigo\nyes i agree'), 'en');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final e = n.state['m1']!;
      expect(e.status, AutoTranslateStatus.ready);
      final out = e.translated.split('\n');
      // The quote line is byte-identical (still starts with '>' at col 0), so
      // the parser still renders it as a blockquote with the author mention.
      expect(out.first, '> @alice#1a2b: hola amigo');
      // Only the reply text was translated (upper-cased).
      expect(out.last, 'YES I AGREE');
    });

    test('retries a failing translation before succeeding', () async {
      final n = AutoTranslateNotifier(
        service: _FlakyTranslate(
          failTimes: 2, // fail twice, succeed on the 3rd attempt
          result: const TranslationResult(
              translatedText: 'hello', detectedLanguage: 'es'),
        ),
      );
      n.ensure(_msg(content: 'hola'), 'en');
      // Backoff is 400ms + 800ms before the successful 3rd attempt.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(n.state['m1']!.status, AutoTranslateStatus.ready);
      expect(n.state['m1']!.translated, 'hello');
    });

    test('caches per (message, target): no duplicate proxy calls', () async {
      final calls = <String>[];
      final n = AutoTranslateNotifier(
        service: _FakeTranslate(
          const TranslationResult(
              translatedText: 'hello', detectedLanguage: 'es'),
          calls: calls,
        ),
      );
      final m = _msg(content: 'hola');
      n.ensure(m, 'en');
      await Future<void>.delayed(Duration.zero);
      n.ensure(m, 'en'); // same input again
      await Future<void>.delayed(Duration.zero);
      expect(calls.length, 1);
      expect(n.entryFor('m1', 'en', 'hola')?.isReady, isTrue);
      // Stale on a different target language.
      expect(n.entryFor('m1', 'fr', 'hola'), isNull);
    });
  });
}
