// The "Nymbot is thinking" strip in a PUBLIC channel is a typing entry set under
// the bot's pubkey with a 45s auto-expiry (`_setBotChannelThinking`). On the
// SUCCESS path the command handler does NOT clear it — it relies on the bot's
// reply arriving to clear it (PWA nostr-core.js:508-510,
// `if (message.isBot) _setBotChannelThinking(false)`). The controller now clears
// it when a verified-bot channel message lands, using
// `EventMapper.channelKeyOf(event)` as the storage key.
//
// These tests lock the two things that fix relies on:
//   1) `channelKeyOf(botEvent)` == the channel view's `storageKey` (so the clear
//      targets the SAME typing entry the set created), and
//   2) `setTyping(typing: false)` on that key removes the entry, so
//      `typingForCurrentViewProvider` stops showing the bot.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_mapper.dart';
import 'package:nym_bar/state/app_state.dart';

const _botPk = 'b0771234';

NostrEvent _botGeoMsg(String geohash) => NostrEvent(
      id: 'evt_bot_1',
      pubkey: _botPk,
      createdAt: 1000,
      kind: EventKind.geoChannel,
      tags: [
        ['g', geohash],
        ['n', 'Nymbot'],
      ],
      content: 'the answer is 42',
    );

void main() {
  test('channelKeyOf(botEvent) matches the channel view storageKey', () {
    const geohash = 'u4pruyd';
    final event = _botGeoMsg(geohash);
    final viewKey = const ChatView.channel(geohash).storageKey;
    expect(EventMapper.channelKeyOf(event), viewKey,
        reason: 'the clear must target the SAME key the thinking-set used');
  });

  test('bot thinking strip clears when cleared via the message channel key', () {
    const geohash = 'u4pruyd';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(appStateProvider.notifier)
      ..goLive('self', 'me#0001');
    // Open the channel where the ?command was issued.
    n.switchView(const ChatView.channel(geohash));

    final storageKey = const ChatView.channel(geohash).storageKey;
    final now = DateTime.now().millisecondsSinceEpoch;

    // `_setBotChannelThinking(storageKey, true)` — 45s auto-expiry.
    n.setTyping(
      storageKey: storageKey,
      pubkey: _botPk,
      typing: true,
      expiresAtMs: now + 45000,
    );
    expect(container.read(typingForCurrentViewProvider), contains(_botPk),
        reason: 'the thinking strip should be showing the bot');

    // The reply lands: the controller clears via channelKeyOf(event).
    final clearKey = EventMapper.channelKeyOf(_botGeoMsg(geohash))!;
    n.setTyping(storageKey: clearKey, pubkey: _botPk, typing: false);

    expect(container.read(typingForCurrentViewProvider), isNot(contains(_botPk)),
        reason: 'the thinking strip must clear the moment the reply lands, '
            'not hang until the 45s expiry');
  });
}
