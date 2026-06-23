import 'dart:math';

import '../../core/constants/event_kinds.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/nostr_event.dart';
import '../../models/poll.dart';

/// Pure, socket-free logic for Nymchat polls (kind 30078, `nym-poll` /
/// `nym-poll-vote`). Mirrors `js/modules/polls.js` verbatim: tag shapes, vote
/// dedup (one per pubkey, latest-by-arrival), buffered votes that arrive before
/// the poll, and `expiration` honoring. (docs/specs/03 §6)
class PollLogic {
  PollLogic._();

  static final Random _rng = Random.secure();

  /// 8-char poll id fragment (`Math.random().toString(36).substring(2,10)`).
  /// Used for the `['d','nym-poll-'+id8]` replaceable identifier.
  static String generatePollId8() {
    const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(alphabet[_rng.nextInt(alphabet.length)]);
    }
    return sb.toString();
  }

  /// Builds the kind-30078 poll-create rumor tags (polls.js `publishPoll`):
  /// `['d','nym-poll-'+id8], ['t','nym-poll'], ['n',nym], ['g',geohash],
  ///  ['poll_question',q], ['poll_option','0',o0], ['poll_option','1',o1] …`.
  /// content = question.
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

  /// Builds the kind-30078 poll-vote rumor tags (polls.js `votePoll`):
  /// `['d','nym-poll-vote-'+pollId], ['t','nym-poll-vote'], ['e',pollId],
  ///  ['n',nym], ['g',geohash], ['response', String(idx)]`. content = ''.
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

  // ---------------------------------------------------------------------------
  // Inbound classification / parsing
  // ---------------------------------------------------------------------------

  /// True when a kind-30078 event is a poll-create (`['t','nym-poll']`).
  static bool isPollEvent(NostrEvent e) =>
      e.kind == EventKind.pollKind &&
      e.tagsNamed('t').any((t) => t.length > 1 && t[1] == AppDataTopic.poll);

  /// True when a kind-30078 event is a poll-vote (`['t','nym-poll-vote']`).
  static bool isPollVoteEvent(NostrEvent e) =>
      e.kind == EventKind.pollVoteKind &&
      e.tagsNamed('t').any((t) => t.length > 1 && t[1] == AppDataTopic.pollVote);

  /// True if an `['expiration', ts]` tag is present and already in the past
  /// (polls.js skips expired polls and votes on receive). [nowSec] injectable.
  static bool isExpired(NostrEvent e, {int? nowSec}) {
    final exp = e.tagValue('expiration');
    if (exp == null) return false;
    final ts = int.tryParse(exp);
    if (ts == null || ts == 0) return false;
    final now = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    return ts < now;
  }

  /// Parses a poll-create event into a [Poll] (no votes attached), or null when
  /// it lacks a question or has < 2 options (polls.js `handlePollEvent` guard).
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
    final geohash = e.tagValue('g') ?? '';
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

  /// Parses a poll-vote event into (pollId, optionIndex), or null if it lacks
  /// the `['e', …]` or `['response', …]` tags (polls.js `handlePollVoteEvent`).
  static PollVote? parseVote(NostrEvent e) {
    final pollId = e.tagValue('e');
    final response = e.tagValue('response');
    if (pollId == null || response == null) return null;
    final idx = int.tryParse(response);
    if (idx == null) return null;
    return PollVote(pollId: pollId, voter: e.pubkey, optionIndex: idx);
  }
}

/// A parsed poll vote (kind 30078 `nym-poll-vote`).
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
