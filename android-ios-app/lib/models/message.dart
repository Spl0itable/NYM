/// Delivery state for a PM/group message.
enum DeliveryStatus { sending, sent, delivered, read, failed }

DeliveryStatus deliveryStatusFromString(String? s) {
  switch (s) {
    case 'sent':
      return DeliveryStatus.sent;
    case 'delivered':
      return DeliveryStatus.delivered;
    case 'read':
      return DeliveryStatus.read;
    case 'failed':
      return DeliveryStatus.failed;
    default:
      return DeliveryStatus.sending;
  }
}

/// Unified message model covering channel, PM and group messages, mirroring the
/// IndexedDB-serialised record the PWA uses (docs/specs/01 §1.4, 03 §2.1/§3.4).
class Message {
  Message({
    required this.id,
    required this.author,
    required this.pubkey,
    required this.content,
    required this.createdAt,
    this.originalCreatedAt,
    this.ms = 0,
    this.seq = 0,
    int? timestamp,
    this.isOwn = false,
    this.isPM = false,
    this.isGroup = false,
    this.groupId,
    this.conversationKey,
    this.conversationPubkey,
    this.eventKind = 0,
    this.isHistorical = false,
    this.senderVerified = false,
    this.bitchatMessageId,
    this.nymMessageId,
    this.deliveryStatus = DeliveryStatus.sending,
    this.isEdited = false,
    this.channel,
    this.geohash,
    this.isFileOffer = false,
    this.fileOffer,
    this.isBot = false,
    this.thinking,
    this.optimistic = false,
    this.spamGated = false,
    this.blocked = false,
  }) : timestamp = timestamp ?? createdAt * 1000;

  String id;
  String author;
  String pubkey;
  String content;

  /// Nostr timestamp, seconds.
  int createdAt;
  int? originalCreatedAt;

  /// Full millisecond timestamp from the `['ms', …]` tag (`Date.now()` when the
  /// event was stamped), used as the sub-second ordering tiebreak. Mirrors the
  /// PWA `_ms`: it is an absolute ms value (`created_at * 1000 + sub-second`),
  /// NOT a 0-999 offset. A value `<= created_at * 1000` is treated as the
  /// floor-to-second fallback and ignored for ordering (see `_hasRealMsTag`).
  int ms;

  /// Local monotonic arrival sequence (final ordering tiebreak).
  int seq;

  /// Milliseconds since epoch (createdAt*1000, clamped to now if future).
  int timestamp;

  bool isOwn;
  bool isPM;
  bool isGroup;
  String? groupId;
  String? conversationKey;
  String? conversationPubkey;

  /// 20000 | 23333 | 14 | 1059 | …
  int eventKind;

  bool isHistorical;
  bool senderVerified;
  String? bitchatMessageId;
  String? nymMessageId;
  DeliveryStatus deliveryStatus;
  bool isEdited;

  String? channel;
  String? geohash;

  bool isFileOffer;
  Map<String, dynamic>? fileOffer;

  bool isBot;

  /// Nymbot reasoning block (collapsed "💭 Reasoning").
  String? thinking;

  /// Pre-sign placeholder; cleared when the signed event arrives.
  bool optimistic;

  /// Held until sender becomes trusted.
  bool spamGated;

  /// Flagged from a blocked user.
  bool blocked;

  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(timestamp);

  Map<String, dynamic> toJson() => {
        'id': id,
        'author': author,
        'pubkey': pubkey,
        'content': content,
        'created_at': createdAt,
        '_originalCreatedAt': originalCreatedAt,
        '_ms': ms,
        '_seq': seq,
        'timestamp': timestamp,
        'isOwn': isOwn,
        'isPM': isPM,
        'isGroup': isGroup,
        'groupId': groupId,
        'conversationKey': conversationKey,
        'conversationPubkey': conversationPubkey,
        'eventKind': eventKind,
        'isHistorical': isHistorical,
        'senderVerified': senderVerified,
        'bitchatMessageId': bitchatMessageId,
        'nymMessageId': nymMessageId,
        'deliveryStatus': deliveryStatus.name,
        'isEdited': isEdited,
        'channel': channel,
        'geohash': geohash,
        'isFileOffer': isFileOffer,
        'fileOffer': fileOffer,
        'isBot': isBot,
        'thinking': thinking,
      };

  factory Message.fromJson(Map<String, dynamic> j) {
    return Message(
      id: j['id'] as String,
      author: (j['author'] ?? '') as String,
      pubkey: (j['pubkey'] ?? '') as String,
      content: (j['content'] ?? '') as String,
      createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
      originalCreatedAt: (j['_originalCreatedAt'] as num?)?.toInt(),
      ms: (j['_ms'] as num?)?.toInt() ?? 0,
      seq: (j['_seq'] as num?)?.toInt() ?? 0,
      timestamp: (j['timestamp'] as num?)?.toInt(),
      isOwn: j['isOwn'] == true,
      isPM: j['isPM'] == true,
      isGroup: j['isGroup'] == true,
      groupId: j['groupId'] as String?,
      conversationKey: j['conversationKey'] as String?,
      conversationPubkey: j['conversationPubkey'] as String?,
      eventKind: (j['eventKind'] as num?)?.toInt() ?? 0,
      isHistorical: j['isHistorical'] == true,
      senderVerified: j['senderVerified'] == true,
      bitchatMessageId: j['bitchatMessageId'] as String?,
      nymMessageId: j['nymMessageId'] as String?,
      deliveryStatus: deliveryStatusFromString(j['deliveryStatus'] as String?),
      isEdited: j['isEdited'] == true,
      channel: j['channel'] as String?,
      geohash: j['geohash'] as String?,
      isFileOffer: j['isFileOffer'] == true,
      fileOffer: (j['fileOffer'] as Map?)?.cast<String, dynamic>(),
      isBot: j['isBot'] == true,
      thinking: j['thinking'] as String?,
    );
  }
}

/// True if [m] carries a genuine sub-second `ms` tag, mirroring the PWA's
/// `_hasRealMsTag`: the ms value must be finite, positive, and strictly greater
/// than the whole-second base (`created_at * 1000`) so it adds real sub-second
/// precision rather than echoing the second-granularity timestamp.
bool _hasRealMsTag(Message m) {
  if (m.ms <= 0) return false;
  final base = m.createdAt * 1000;
  return m.ms > base;
}

/// Ordering comparator mirroring `_compareMessages`: primary created_at (sec);
/// secondary `ms` only when both carry a real ms tag; tertiary seq.
int compareMessages(Message a, Message b) {
  if (a.createdAt != b.createdAt) return a.createdAt - b.createdAt;
  if (_hasRealMsTag(a) && _hasRealMsTag(b)) {
    final dm = a.ms - b.ms;
    if (dm != 0) return dm;
  }
  return a.seq - b.seq;
}
