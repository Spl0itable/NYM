// Through the relay-pool proxy the pool and the spam engine already filter
// every channel message, so the app's own automatic heuristics (web-of-trust
// gate, content heuristics, campaign auto-mute, gibberish nyms) apply only in
// direct mode. User choices still apply in both.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/features/messages/cross_content_flood.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

const _self = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _stranger = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final c = ProviderContainer(overrides: [keyValueStoreProvider.overrideWithValue(kv)]);
  c.read(appStateProvider.notifier).goLive(_self, 'you#1a2b');
  return c;
}

NostrEvent _msg(String id, String content) => NostrEvent(
      id: id,
      pubkey: _stranger,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: 23333,
      tags: [
        ['n', 'Stranger#dddd'],
        ['d', 'nymchat'],
      ],
      content: content,
      sig: '0' * 128,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    nymVouchSpamGateEnabled = false;
    appSpamFilterEnabled = true;
    appSpamFilterAggressive = true;
  });
  tearDown(() {
    nymVouchSpamGateEnabled = false;
  });

  test('an untrusted sender without proof of work shows through the proxy', () async {
    final c = await _container();
    final n = c.read(appStateProvider.notifier);
    n.setProxyMode(true);
    n.ingestEvent(_msg('1' * 64, 'hello from a phone that never mined'));
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 1);
    expect(c.read(appStateProvider).clientGatesActive, isFalse);

    n.setProxyMode(false);
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 1,
        reason: 'the first-message hide is off in direct mode too');
    nymVouchSpamGateEnabled = true;
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 0,
        reason: 'only the flag nothing sets would bring it back, and only off the proxy');
    n.setProxyMode(true);
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 1);
    c.dispose();
  });

  test('the content heuristic and blocks behave the same way', () async {
    final c = await _container();
    final n = c.read(appStateProvider.notifier);
    n.setProxyMode(true);
    n.ingestEvent(_msg('2' * 64, 'look ["client","chorus"] tagged'));
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 1,
        reason: 'the pool already applies the shared content heuristics');
    n.setProxyMode(false);
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 0);

    n.setProxyMode(true);
    n.blockUser(_stranger);
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 0,
        reason: 'an explicit block applies in both modes');
    c.dispose();
  });

  test('the campaign detector stands down through the proxy', () async {
    crossContentFlood = CrossContentFlood();
    final c = await _container();
    final n = c.read(appStateProvider.notifier);
    n.setProxyMode(true);
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 4; i++) {
      n.ingestEvent(NostrEvent(
        id: '${i + 3}' * 64,
        pubkey: _stranger,
        createdAt: t - 120 + i * 30,
        kind: 23333,
        tags: [
          ['n', 'Stranger#dddd'],
          ['d', 'nymchat'],
        ],
        content: 'yep the same long paragraph that keeps coming round the '
            'channel every minute with a fresh nonce on the end ghdr5c${i}n15',
        sig: '0' * 128,
      ));
    }
    expect(c.read(appStateProvider).isAutoMuted(_stranger), isFalse);
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 4);
    c.dispose();
  });

  test('a gibberish nym is listed through the proxy', () async {
    final c = await _container();
    final n = c.read(appStateProvider.notifier);
    n.setProxyMode(true);
    n.setUserPresence(
        pubkey: _stranger,
        status: UserStatus.online,
        nym: 'aAbBcCdDeE',
        lastSeenMs: 1);
    expect(c.read(usersProvider).containsKey(_stranger), isTrue);
    n.setProxyMode(false);
    expect(c.read(usersProvider).containsKey(_stranger), isFalse);
    c.dispose();
  });
}
