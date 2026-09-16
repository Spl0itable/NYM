import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/state/app_state.dart';

const _peer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabeef';

NostrEvent _msg(String id, int ts, String content, {String? nym}) => NostrEvent(
      id: id,
      pubkey: _peer,
      createdAt: ts,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'room'],
        if (nym != null) ['n', nym],
      ],
      content: content,
    );

NostrEvent _profile(String name, int ts) => NostrEvent(
      id: 'k0_$ts',
      pubkey: _peer,
      createdAt: ts,
      kind: EventKind.profile,
      tags: const [],
      content: '{"name":"$name"}',
    );

void main() {
  AppStateNotifier fresh() =>
      AppStateNotifier()..goLive('self_pk_0001', 'me#0001');

  test('a sender with no n tag starts on the placeholder', () {
    final n = fresh();
    n.ingestEvent(_msg('m1', 1000, 'hi'));
    expect(n.state.messages['#room']!.single.author, 'nym#beef');
    expect(n.state.users[_peer]!.nym, 'nym#beef');
  });

  test('a kind 0 rewrites the author already stored on their messages', () {
    final n = fresh();
    n.ingestEvent(_msg('m1', 1000, 'hi'));
    n.ingestEvent(_profile('Alice', 1001));
    expect(n.state.users[_peer]!.nym, 'Alice#beef');
    expect(n.state.messages['#room']!.single.author, 'Alice#beef');
  });

  test('a later n-tag-less message does not put the placeholder back', () {
    final n = fresh();
    n.ingestEvent(_msg('m1', 1000, 'hi'));
    n.ingestEvent(_profile('Alice', 1001));
    n.ingestEvent(_msg('m2', 1002, 'again'));
    expect(n.state.users[_peer]!.nym, 'Alice#beef');
    final authors =
        n.state.messages['#room']!.map((m) => m.author).toSet();
    expect(authors, {'Alice#beef'});
  });

  test('a real n tag still wins over a stale stored nym', () {
    final n = fresh();
    n.ingestEvent(_msg('m1', 1000, 'hi'));
    n.ingestEvent(_profile('Alice', 1001));
    n.ingestEvent(_msg('m2', 1002, 'renamed', nym: 'Bob'));
    expect(n.state.users[_peer]!.nym, 'Bob#beef');
    expect(n.state.messages['#room']!.last.author, 'Bob#beef');
  });

  test('presence carrying a nym also repairs stored placeholders', () {
    final n = fresh();
    n.ingestEvent(_msg('m1', 1000, 'hi'));
    n.setUserPresence(
      pubkey: _peer,
      status: UserStatus.online,
      nym: 'Carol',
      stampLastSeen: false,
    );
    expect(n.state.users[_peer]!.nym, 'Carol#beef');
    expect(n.state.messages['#room']!.single.author, 'Carol#beef');
  });
}
