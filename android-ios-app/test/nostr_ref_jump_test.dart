/// A reference card points wherever the referenced event actually is, which is
/// usually NOT the conversation the card is rendered in — so a miss in the open
/// list must resolve to the conversation that holds it rather than reporting
/// the event unavailable.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

const _id = 'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4';
const _peer =
    'f00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabe';

Message _msg(String id, {String? nymMessageId}) => Message(
      id: id,
      author: 'a',
      pubkey: 'p' * 64,
      content: 'x',
      createdAt: 1,
    )..nymMessageId = nymMessageId;

AppStateNotifier _store(Map<String, List<Message>> byKey) {
  final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
  byKey.forEach((k, v) => n.state.messages[k] = v);
  return n;
}

void main() {
  test('an event in another channel resolves to that channel', () {
    final n = _store({
      '#here': [_msg('b' * 64)],
      '#there': [_msg(_id)],
    });
    final view = conversationHoldingEvent(n.state, _id)!;
    expect(view.kind, ViewKind.channel);
    expect(view.id, 'there');
    expect(view.storageKey, '#there');
  });

  test('an event in a PM resolves to that conversation', () {
    final n = _store({
      'pm-$_peer': [_msg(_id)],
    });
    final view = conversationHoldingEvent(n.state, _id)!;
    expect(view.kind, ViewKind.pm);
    expect(view.id, _peer);
  });

  test('an event in a group resolves to that group', () {
    final n = _store({
      'group-abc': [_msg(_id)],
    });
    final view = conversationHoldingEvent(n.state, _id)!;
    expect(view.kind, ViewKind.group);
    expect(view.id, 'abc');
  });

  test('a message is also found by its nym message id', () {
    final n = _store({
      '#there': [_msg('c' * 64, nymMessageId: _id)],
    });
    expect(conversationHoldingEvent(n.state, _id)?.id, 'there');
  });

  test('an id this client does not hold resolves to nothing', () {
    final n = _store({
      '#here': [_msg('b' * 64)],
    });
    expect(conversationHoldingEvent(n.state, _id), isNull);
  });

  test('an empty id resolves to nothing', () {
    final n = _store({
      '#here': [_msg(_id)],
    });
    expect(conversationHoldingEvent(n.state, ''), isNull);
  });

  test('an empty store resolves to nothing', () {
    expect(conversationHoldingEvent(_store({}).state, _id), isNull);
  });
}
