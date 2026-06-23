/// A poll option.
class PollOption {
  PollOption({required this.index, required this.text});
  final int index;
  final String text;
}

/// A poll (kind 30078, `nym-poll`), channel-only (docs/specs/03 §6).
class Poll {
  Poll({
    required this.id,
    required this.question,
    required this.options,
    Map<String, int>? votes,
    required this.pubkey,
    this.nym = '',
    this.geohash = '',
    this.createdAt = 0,
  }) : votes = votes ?? <String, int>{};

  final String id;
  final String question;
  final List<PollOption> options;

  /// voter pubkey → option index (one vote each).
  final Map<String, int> votes;

  final String pubkey;
  final String nym;
  final String geohash;
  final int createdAt;

  int votesFor(int optionIndex) =>
      votes.values.where((v) => v == optionIndex).length;

  int get totalVotes => votes.length;

  double fractionFor(int optionIndex) =>
      totalVotes == 0 ? 0 : votesFor(optionIndex) / totalVotes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'question': question,
        'options':
            options.map((o) => {'index': o.index, 'text': o.text}).toList(),
        'votes': votes,
        'pubkey': pubkey,
        'nym': nym,
        'geohash': geohash,
        'created_at': createdAt,
      };

  factory Poll.fromJson(Map<String, dynamic> j) => Poll(
        id: j['id'] as String,
        question: (j['question'] ?? '') as String,
        options: ((j['options'] as List?) ?? const [])
            .map((o) => PollOption(
                  index: (o['index'] as num).toInt(),
                  text: o['text'] as String,
                ))
            .toList(),
        votes: ((j['votes'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, (v as num).toInt())),
        pubkey: (j['pubkey'] ?? '') as String,
        nym: (j['nym'] ?? '') as String,
        geohash: (j['geohash'] ?? '') as String,
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
      );
}
