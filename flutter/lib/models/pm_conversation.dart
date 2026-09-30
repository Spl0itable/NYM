/// A 1:1 PM conversation meta entry (`pmConversations`).
class PMConversation {
  PMConversation({
    required this.pubkey,
    this.nym = '',
    this.lastMessageTime = 0,
  });

  final String pubkey;
  String nym;

  /// Last message time in ms.
  int lastMessageTime;

  Map<String, dynamic> toJson() =>
      {'pubkey': pubkey, 'nym': nym, 'lastMessageTime': lastMessageTime};

  factory PMConversation.fromJson(Map<String, dynamic> j) => PMConversation(
        pubkey: j['pubkey'] as String,
        nym: (j['nym'] ?? '') as String,
        lastMessageTime: (j['lastMessageTime'] as num?)?.toInt() ?? 0,
      );
}
