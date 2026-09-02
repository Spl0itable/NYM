import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/features/polls/poll_logic.dart';
import 'package:nym_bar/models/channel.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_mapper.dart';

const _self =
    '0000000000000000000000000000000000000000000000000000000000001a2b';
const _other =
    '11111111111111111111111111111111111111111111111111111111deadbeef';

NostrEvent _channel(int kind, String tag, String value) => NostrEvent(
      id: 'evt-$kind-$value',
      pubkey: _other,
      createdAt: 1700000000,
      kind: kind,
      tags: [
        ['n', 'satoshi'],
        [tag, value],
      ],
      content: 'hello',
    );

NostrEvent _poll(String? geohash) => NostrEvent(
      id: 'poll-$geohash',
      pubkey: _other,
      createdAt: 1700000000,
      kind: EventKind.pollKind,
      tags: [
        ['t', AppDataTopic.poll],
        ['n', 'satoshi'],
        ['poll_question', 'tabs or spaces?'],
        ['poll_option', '0', 'tabs'],
        ['poll_option', '1', 'spaces'],
        if (geohash != null) ['g', geohash],
      ],
      content: '',
    );

void main() {
  group('isValidChannelTag', () {
    test('accepts a named channel', () {
      expect(isValidChannelTag('nymchat'), isTrue);
    });

    test('accepts a geohash', () {
      expect(isValidChannelTag('9q8yyk'), isTrue);
    });

    test('rejects an inner space', () {
      expect(isValidChannelTag('nym chat'), isFalse);
    });

    test('rejects a leading or trailing space', () {
      expect(isValidChannelTag(' nymchat'), isFalse);
      expect(isValidChannelTag('nymchat '), isFalse);
    });

    test('rejects a tab or a newline', () {
      expect(isValidChannelTag('nym\tchat'), isFalse);
      expect(isValidChannelTag('nym\nchat'), isFalse);
    });

    test('rejects empty and null', () {
      expect(isValidChannelTag(''), isFalse);
      expect(isValidChannelTag(null), isFalse);
    });
  });

  group('a channel tag with a space is not a channel', () {
    test('a clean named channel still maps', () {
      final e = _channel(EventKind.namedChannel, 'd', 'nymchat');
      expect(EventMapper.channelNameOf(e), 'nymchat');
      expect(EventMapper.channelKeyOf(e), '#nymchat');
      expect(EventMapper.channelMessage(e, selfPubkey: _self), isNotNull);
    });

    test('a clean geohash channel still maps', () {
      final e = _channel(EventKind.geoChannel, 'g', '9q8yyk');
      expect(EventMapper.channelNameOf(e), '9q8yyk');
      expect(EventMapper.channelKeyOf(e), '#9q8yyk');
      expect(EventMapper.channelMessage(e, selfPubkey: _self), isNotNull);
    });

    test('a kind 23333 with a spaced d tag is refused', () {
      final e = _channel(EventKind.namedChannel, 'd', 'nym chat');
      expect(EventMapper.channelNameOf(e), isNull);
      expect(EventMapper.channelKeyOf(e), isNull);
      expect(EventMapper.channelMessage(e, selfPubkey: _self), isNull);
    });

    test('a padded d tag is refused rather than trimmed', () {
      final e = _channel(EventKind.namedChannel, 'd', ' nymchat ');
      expect(EventMapper.channelNameOf(e), isNull);
      expect(EventMapper.channelMessage(e, selfPubkey: _self), isNull);
    });

    test('a tab in a d tag is refused', () {
      final e = _channel(EventKind.namedChannel, 'd', 'nym\tchat');
      expect(EventMapper.channelNameOf(e), isNull);
    });

    test('a kind 20000 with a spaced g tag is refused', () {
      final e = _channel(EventKind.geoChannel, 'g', '9q8 yyk');
      expect(EventMapper.channelNameOf(e), isNull);
      expect(EventMapper.channelKeyOf(e), isNull);
      expect(EventMapper.channelMessage(e, selfPubkey: _self), isNull);
    });

    test('the kind and shape rule still holds', () {
      expect(
          EventMapper.channelNameOf(
              _channel(EventKind.geoChannel, 'g', 'nymchat')),
          isNull);
      expect(
          EventMapper.channelNameOf(
              _channel(EventKind.namedChannel, 'd', '9q8yyk')),
          isNull);
    });
  });

  group('a poll carrying a spaced g tag is refused', () {
    test('a clean geohash poll parses', () {
      final p = PollLogic.parsePoll(_poll('9q8yyk'));
      expect(p, isNotNull);
      expect(p!.geohash, '9q8yyk');
    });

    test('a poll with no g tag still parses', () {
      final p = PollLogic.parsePoll(_poll(null));
      expect(p, isNotNull);
      expect(p!.geohash, '');
    });

    test('a spaced g tag drops the poll instead of globalizing it', () {
      expect(PollLogic.parsePoll(_poll('nym chat')), isNull);
    });
  });
}
