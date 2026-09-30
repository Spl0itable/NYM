import 'dart:math';

import '../../core/constants/event_kinds.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/channel.dart';
import '../../models/nostr_event.dart';
import '../../models/poll.dart';

/// Socket-free poll logic (kind 30078): tag shapes, one vote per pubkey (latest wins), buffered early votes, expiration.
class PollLogic {
  PollLogic._();

  static final Random _rng = Random.secure();

  /// 8-char base-36 poll id fragment used in the `nym-poll-<id8>` d-tag.
  static String generatePollId8() {
    const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(alphabet[_rng.nextInt(alphabet.length)]);
    }
    return sb.toString();
  }

  /// Poll-create rumor: d/t/n/g tags, `poll_question`, then one `poll_option` per option; content is the question.
  static UnsignedEvent buildPollEvent({
    required String pubkey,
    required String nym,
    required String geohash,
    required String question,
    required List<String> options,
    String? pollId8,
    int? nowSec,
  }) {
    final id8 = pollId8 ?? generatePollId8();
    final now = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final tags = <List<String>>[
      ['d', 'nym-poll-$id8'],
      ['t', AppDataTopic.poll],
      ['n', nym],
      ['g', geohash],
      ['poll_question', question],
    ];
    for (var i = 0; i < options.length; i++) {
      tags.add(['poll_option', '$i', options[i]]);
    }
    return UnsignedEvent(
      pubkey: pubkey,
      createdAt: now,
      kind: EventKind.pollKind,
      tags: tags,
      content: question,
    );
  }

  /// Poll-vote rumor: d/t/e/n/g tags plus `['response', idx]`; content is empty.
  static UnsignedEvent buildVoteEvent({
    required String pubkey,
    required String nym,
    required String geohash,
    required String pollId,
    required int optionIndex,
    int? nowSec,
  }) {
    final now = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    return UnsignedEvent(
      pubkey: pubkey,
      createdAt: now,
      kind: EventKind.pollVoteKind,
      tags: [
        ['d', 'nym-poll-vote-$pollId'],
        ['t', AppDataTopic.pollVote],
        ['e', pollId],
        ['n', nym],
        ['g', geohash],
        ['response', '$optionIndex'],
      ],
      content: '',
    );
  }

  static bool isPollEvent(NostrEvent e) =>
      e.kind == EventKind.pollKind &&
      e.tagsNamed('t').any((t) => t.length > 1 && t[1] == AppDataTopic.poll);

  static bool isPollVoteEvent(NostrEvent e) =>
      e.kind == EventKind.pollVoteKind &&
      e
          .tagsNamed('t')
          .any((t) => t.length > 1 && t[1] == AppDataTopic.pollVote);

  /// True if an `['expiration', ts]` tag is already in the past; expired polls and votes are dropped.
  static bool isExpired(NostrEvent e, {int? nowSec}) {
    final exp = e.tagValue('expiration');
    if (exp == null) return false;
    final ts = int.tryParse(exp);
    if (ts == null || ts == 0) return false;
    final now = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    return ts < now;
  }

  /// Parses a poll-create event, or null without a question or with fewer than 2 options.
  static Poll? parsePoll(NostrEvent e) {
    final question = e.tagValue('poll_question');
    final optionTags =
        e.tagsNamed('poll_option').where((t) => t.length > 2).toList();
    if (question == null || optionTags.length < 2) return null;
    final options = optionTags
        .map((t) => PollOption(index: int.tryParse(t[1]) ?? 0, text: t[2]))
        .toList();
    final nymTag = e.tagValue('n');
    final nym = nymTag != null ? stripPubkeySuffix(nymTag) : 'nym';
    final gTag = e.tagValue('g');
    if (gTag != null && !isValidChannelTag(gTag)) return null;
    final geohash = gTag ?? '';
    return Poll(
      id: e.id,
      question: question,
      options: options,
      pubkey: e.pubkey,
      nym: nym,
      geohash: geohash,
      createdAt: e.createdAt,
    );
  }

  /// Parses a vote, or null without the `e` or `response` tag.
  static PollVote? parseVote(NostrEvent e) {
    final pollId = e.tagValue('e');
    final response = e.tagValue('response');
    if (pollId == null || response == null) return null;
    final idx = int.tryParse(response);
    if (idx == null) return null;
    return PollVote(pollId: pollId, voter: e.pubkey, optionIndex: idx);
  }
}

class PollVote {
  PollVote({
    required this.pollId,
    required this.voter,
    required this.optionIndex,
  });
  final String pollId;
  final String voter;
  final int optionIndex;
}
