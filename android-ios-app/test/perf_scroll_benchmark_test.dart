@Tags(['perf'])
library;

// Scroll-cost harness for the message list: builds REAL MessageGroup rows
// (bubble layout, varied realistic content) inside a reversed list and
// measures the UI-thread cost of (a) the initial render and (b) each frame
// of a fast scroll that continuously mounts new rows — the exact work that
// makes scrolling feel heavy on-device. A plain-Text list scrolls alongside
// as the baseline so the row widgets' own cost is isolated from list
// mechanics. Not a pass/fail test: prints timings.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/features/messages/format/nym_format.dart';
import 'package:nym_bar/widgets/chat/message_row.dart';
import 'package:nym_bar/widgets/common/nym_avatar.dart';

const _contents = [
  'hey, how is it going?',
  'That is a much longer message that wraps over multiple lines because it '
      'keeps going on and on about something fairly detailed, the way real '
      'chat messages sometimes do when someone gets excited about a topic.',
  'check this out: https://example.com/some/path?with=query',
  'short',
  '**bold move** and _italics_ with `some code` inline',
  'multi\nline\nmessage\nwith\nbreaks',
  'plain text with an @alice#abcd mention in the middle of it',
  'another normal length message, nothing special about it at all',
];

Message _msg(int i) => Message(
      id: 'm$i',
      author: 'user${i % 7}#ab${i % 10}${i % 10}',
      pubkey: 'pk${i % 7}',
      content: _contents[i % _contents.length],
      createdAt: 1700000000 + i * 40,
      isOwn: i % 7 == 3,
      isHistorical: true,
      eventKind: 20000,
      geohash: 'u4pruyd',
    );

List<Widget> _groupRows(int count, Settings settings) {
  // Fold consecutive same-author runs like the live list does.
  final rows = <Widget>[];
  var i = 0;
  while (i < count) {
    final entries = <MessageGroupEntry>[];
    final pk = 'pk${i % 7}';
    while (i < count && 'pk${i % 7}' == pk && entries.length < 3) {
      entries.add(MessageGroupEntry(
          message: _msg(i), reactions: const [], mentioned: false));
      i++;
    }
    rows.add(RepaintBoundary(
      child: MessageGroup(entries: entries, settings: settings),
    ));
  }
  return rows.reversed.toList();
}

Future<void> _run(
  WidgetTester tester,
  String label,
  List<Widget> rows,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final colors = resolveNymColors(
    theme: NymThemeKey.bitchat,
    brightness: Brightness.dark,
    solidUi: true,
  );
  final scroll = ScrollController();
  addTearDown(scroll.dispose);

  final sw = Stopwatch()..start();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(
          body: ListView(
            controller: scroll,
            reverse: true,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            children: rows,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  sw.stop();
  final initialMs = sw.elapsedMilliseconds;

  // Fast scroll: 400px per 16ms frame for 60 frames — every frame mounts new
  // rows, the worst case the user hits flinging through history.
  final frames = <int>[];
  for (var f = 0; f < 60; f++) {
    final target = (f + 1) * 400.0;
    if (target > scroll.position.maxScrollExtent) break;
    scroll.jumpTo(target);
    final fsw = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 16));
    fsw.stop();
    frames.add(fsw.elapsedMicroseconds);
  }
  frames.sort();
  final avg = frames.isEmpty
      ? 0
      : frames.reduce((a, b) => a + b) / frames.length / 1000.0;
  final p95 = frames.isEmpty ? 0 : frames[(frames.length * 95) ~/ 100] / 1000.0;
  final worst = frames.isEmpty ? 0 : frames.last / 1000.0;
  // ignore: avoid_print
  print('$label: initial=${initialMs}ms  scroll avg=${avg.toStringAsFixed(1)}ms '
      'p95=${p95.toStringAsFixed(1)}ms worst=${worst.toStringAsFixed(1)}ms '
      '(${frames.length} frames)');
}

void main() {
  testWidgets('micro: MessageContent / avatar / bare group costs',
      (tester) async {
    const settings = Settings();
    Future<void> timed(String label, List<Widget> children) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final colors = resolveNymColors(
          theme: NymThemeKey.bitchat,
          brightness: Brightness.dark,
          solidUi: true);
      // Warm-up pump so theme/font setup isn't billed to the first probe.
      final sw = Stopwatch()..start();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [keyValueStoreProvider.overrideWithValue(kv)],
          child: MaterialApp(
            theme: buildNymThemeData(colors),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(children: children),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      sw.stop();
      // ignore: avoid_print
      print('MICRO $label: ${sw.elapsedMilliseconds}ms for ${children.length}'
          ' => ${(sw.elapsedMicroseconds / children.length / 1000).toStringAsFixed(2)}ms each');
      await tester.pumpWidget(const SizedBox.shrink());
    }

    // Warm-up (theme/font/engine setup) so the first probe isn't inflated.
    await timed('warm-up (ignore)', [const Text('warm')]);

    // Raw parse cost (pure Dart, no widgets).
    {
      final sw = Stopwatch()..start();
      for (var r = 0; r < 5; r++) {
        for (final c in _contents) {
          NymFormat.format(c);
        }
      }
      sw.stop();
      // ignore: avoid_print
      print('MICRO NymFormat.format: ${sw.elapsedMicroseconds / 40} us avg '
          '(8 distinct x5, cache active)');
    }

    await timed('MessageContent distinct', [
      for (var i = 0; i < 40; i++)
        MessageContent(content: _msg(i).content, fontSize: 15),
    ]);
    await timed('MessageContent same x40', [
      for (var i = 0; i < 40; i++)
        const MessageContent(content: 'hey, how is it going?', fontSize: 15),
    ]);
    for (var t = 0; t < _contents.length; t++) {
      await timed('type[$t] ${_contents[t].substring(0, _contents[t].length.clamp(0, 24))}', [
        for (var i = 0; i < 20; i++)
          MessageContent(content: '${_contents[t]} v$i', fontSize: 15),
      ]);
    }
    await timed('Text.rich baseline', [
      for (var i = 0; i < 40; i++)
        Text(_contents[i % _contents.length],
            style: const TextStyle(fontSize: 15)),
    ]);
    await timed('NymAvatar identicon', [
      for (var i = 0; i < 40; i++) NymAvatar(seed: 'pk$i', size: 32),
    ]);
    await timed('MessageGroup 1-entry', [
      for (var i = 0; i < 40; i++)
        MessageGroup(entries: [
          MessageGroupEntry(
              message: _msg(i), reactions: const [], mentioned: false)
        ], settings: settings),
    ]);
  });

  testWidgets('scroll cost: real bubble rows vs plain-text baseline',
      (tester) async {
    const settings = Settings(); // bubbles default
    await _run(tester, 'BUBBLE ROWS', _groupRows(400, settings));

    await _run(tester, 'IRC ROWS',
        _groupRows(400, const Settings(chatLayout: 'irc')));

    await _run(tester, 'BASELINE (plain Text)', [
      for (var i = 0; i < 400; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(_contents[i % _contents.length]),
        ),
    ]);
  });
}


