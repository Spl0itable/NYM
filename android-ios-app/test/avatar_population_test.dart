// Verifies the avatar POPULATION half of the pipeline: a kind-0 profile event
// (the shape D1 `profile-get` and live relays deliver) lands its `picture` into
// `users[pubkey].profile.picture`, newest-wins, and a presence avatar-update tag
// seeds/updates it too. If names resolve for a user but the avatar doesn't, this
// proves the URL IS populated — so the failure is purely the image LOADER, which
// is why NymAvatar now fetches bytes via the blob (memoryOnly) path.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

const _self = '0000000000000000000000000000000000000000000000000000000000001a2b';
const _other = '11111111111111111111111111111111111111111111111111111111deadbeef';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final container = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv)],
  );
  container.read(appStateProvider.notifier).goLive(_self, 'you#1a2b');
  return container;
}

NostrEvent _kind0(String pubkey, String json, {required int ts, String? id}) {
  final e = NostrEvent(
    pubkey: pubkey,
    createdAt: ts,
    kind: EventKind.profile,
    content: json,
    sig: 's',
  );
  e.id = id ?? e.computeId();
  return e;
}

void main() {
  test('a kind-0 with a picture populates users[pk].profile.picture', () async {
    final c = await _container();
    final n = c.read(appStateProvider.notifier);

    n.ingestEvent(_kind0(
      _other,
      '{"name":"alice","picture":"https://cdn.example/alice.png"}',
      ts: 100,
    ));

    final user = c.read(appStateProvider).users[_other];
    expect(user, isNotNull);
    expect(user!.profile?.picture, 'https://cdn.example/alice.png');
    // And usersProvider (what NymAvatar reads) sees the same picture.
    expect(c.read(usersProvider)[_other]?.profile?.picture,
        'https://cdn.example/alice.png');
    addTearDown(c.dispose);
  });

  test('a newer kind-0 replaces the picture; an older one does not', () async {
    final c = await _container();
    final n = c.read(appStateProvider.notifier);

    n.ingestEvent(_kind0(
      _other,
      '{"name":"alice","picture":"https://cdn.example/old.png"}',
      ts: 100,
      id: 'old',
    ));
    n.ingestEvent(_kind0(
      _other,
      '{"name":"alice","picture":"https://cdn.example/new.png"}',
      ts: 500,
      id: 'new',
    ));
    expect(c.read(appStateProvider).users[_other]?.profile?.picture,
        'https://cdn.example/new.png');

    // A stale kind-0 must not regress the avatar.
    n.ingestEvent(_kind0(
      _other,
      '{"name":"alice","picture":"https://cdn.example/stale.png"}',
      ts: 50,
      id: 'stale',
    ));
    expect(c.read(appStateProvider).users[_other]?.profile?.picture,
        'https://cdn.example/new.png');
    addTearDown(c.dispose);
  });

  test('a picture-less kind-0 is superseded by a later one that has a picture',
      () async {
    final c = await _container();
    final n = c.read(appStateProvider.notifier);

    // Nym-only profile first (the stub that must NOT permanently block avatars).
    n.ingestEvent(_kind0(_other, '{"name":"alice"}', ts: 100, id: 'nym-only'));
    expect(c.read(appStateProvider).users[_other]?.profile?.picture, isNull);

    n.ingestEvent(_kind0(
      _other,
      '{"name":"alice","picture":"https://cdn.example/late.png"}',
      ts: 200,
      id: 'with-pic',
    ));
    expect(c.read(appStateProvider).users[_other]?.profile?.picture,
        'https://cdn.example/late.png');
    addTearDown(c.dispose);
  });

  test('usersProvider.select notifies when a picture lands (reactivity)',
      () async {
    final c = await _container();
    final n = c.read(appStateProvider.notifier);
    final seen = <String?>[];
    final sub = c.listen(
      usersProvider.select((m) => m[_other]?.profile?.picture),
      (prev, next) => seen.add(next),
    );
    addTearDown(sub.close);

    // A profile picture landing in the (in-place-mutated, reused) users map must
    // still propagate — usersProvider now returns a fresh view each emit so the
    // selector re-runs and observes null → url.
    n.ingestEvent(_kind0(
      _other,
      '{"name":"alice","picture":"https://cdn.example/live.png"}',
      ts: 100,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(seen, contains('https://cdn.example/live.png'),
        reason: 'a landed avatar must notify usersProvider.select subscribers');
    addTearDown(c.dispose);
  });
}
