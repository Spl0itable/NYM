// Inline @mention chips in the composer reuse the emoji SENTINEL technique: a
// mention picked from autocomplete / the context menu is kept as ONE Private-
// Use-Area char in [EmojiSentinelController.text] and painted as an inline
// avatar + nym + flair chip. The load-bearing invariant is WIRE-SAFETY — a
// sentinel PUA char must NEVER leave the composer: every wire-bound read routes
// through `expand`, which maps a mention sentinel back to `@base#suffix`.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/widgets/chat/composer.dart';

/// True when [s] contains any Unicode Private-Use-Area code point — the sentinel
/// range. Wire-safety requires this to be FALSE for anything sent.
bool _hasPua(String s) => s.runes.any((r) => r >= 0xE000 && r <= 0xF8FF);

String _pk(String seed) => (seed * 64).substring(0, 64);

void main() {
  test('a mention sentinel expands to @base#suffix on the wire', () {
    final c = EmojiSentinelController();
    final ch = c.mentionSentinel(fullNym: 'alice#abcd', pubkey: _pk('a'));
    expect(ch, isNotNull);
    c.value = TextEditingValue(
      text: 'hi ${ch}there',
      selection: const TextSelection.collapsed(offset: 4),
    );
    // The stored text carries the PUA sentinel…
    expect(_hasPua(c.text), isTrue);
    // …but the wire form never does.
    final wire = c.expand(c.text);
    expect(wire, 'hi @alice#abcdthere');
    expect(_hasPua(wire), isFalse);
  });

  test('the same mention reuses one sentinel; distinct mentions differ', () {
    final c = EmojiSentinelController();
    final a1 = c.mentionSentinel(fullNym: 'alice#abcd', pubkey: _pk('a'));
    final a2 = c.mentionSentinel(fullNym: 'alice#abcd', pubkey: _pk('a'));
    final b = c.mentionSentinel(fullNym: 'bob#ef01', pubkey: _pk('b'));
    expect(a1, isNotNull);
    expect(a1, a2, reason: 'repeat mention of one user shares a char');
    expect(a1, isNot(b));
  });

  test('emptying the draft drops mention sentinel allocations', () {
    final c = EmojiSentinelController();
    final ch = c.mentionSentinel(fullNym: 'alice#abcd', pubkey: _pk('a'));
    c.value = TextEditingValue(
      text: ch!,
      selection: const TextSelection.collapsed(offset: 1),
    );
    // Empty the field → sentinels reset, so the next allocation restarts at
    // U+E000 (the same char the first allocation used).
    c.value = const TextEditingValue(text: '');
    final again = c.mentionSentinel(fullNym: 'bob#ef01', pubkey: _pk('b'));
    expect(again, ch);
    // The stale 'alice' mapping is gone — expanding a leftover char no longer
    // yields the old nym.
    expect(c.expand(again!), '@bob#ef01');
  });

  test('mention and emoji sentinels coexist and both expand', () {
    final c = EmojiSentinelController();
    c.codeToUrl = {'smile': 'https://cdn.example/smile.png'};
    final emoji = c.resolveValue(TextEditingValue(
      text: ':smile:',
      selection: const TextSelection.collapsed(offset: 7),
    ));
    expect(emoji, isNotNull);
    final emojiChar = emoji!.text; // the single sentinel for :smile:
    final mentionChar =
        c.mentionSentinel(fullNym: 'alice#abcd', pubkey: _pk('a'))!;
    final draft = '$emojiChar $mentionChar';
    c.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    final wire = c.expand(c.text);
    expect(wire, ':smile: @alice#abcd');
    expect(_hasPua(wire), isFalse);
  });

  test('no mention/emoji sentinels → expand is a no-op', () {
    final c = EmojiSentinelController();
    expect(c.expand('plain @alice#abcd text'), 'plain @alice#abcd text');
  });
}
