enum DeliveryStatus { sending, sent, delivered, read, failed }

/// Row type: ordinary message, system pill, action pill, or `/me` emote.
enum MessageKind { normal, system, action, me }

MessageKind messageKindFromString(String? s) {
  switch (s) {
    case 'system':
      return MessageKind.system;
    case 'action':
      return MessageKind.action;
    case 'me':
      return MessageKind.me;
    default:
      return MessageKind.normal;
  }
}

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

/// Discriminator for an inline action button on a system row.
enum SystemActionKind { reportSpamFalsePositive, retryMediaNote }

class SystemAction {
  const SystemAction({
    required this.kind,
    required this.label,
    this.payload = '',
  });

  final SystemActionKind kind;

  final String label;

  /// Action data, e.g. the flagged body for a spam false-positive report.
  final String payload;
}

/// Unified channel, PM and group message model, mirroring the PWA's IndexedDB record.
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
    this.senderVerified,
    this.pqEncrypted = false,
    this.pqRoot = false,
    this.pqCoverage,
    this.bitchatMessageId,
    this.nymMessageId,
    this.threadRoot,
    this.replyTo,
    this.anchorAt,
    this.anchorMs,
    this.deliveryStatus = DeliveryStatus.sending,
    this.isEdited = false,
    this.channel,
    this.geohash,
    this.isFileOffer = false,
    this.fileOffer,
    this.localMediaPath,
    this.localMediaMime,
    this.localMediaName,
    this.viaMesh = false,
    this.isBot = false,
    this.powTarget,
    this.thinking,
    this.optimistic = false,
    this.spamGated = false,
    this.blocked = false,
    this.kind = MessageKind.normal,
    this.systemAction,
    this.expiresAt,
    this.slowHeld = false,
    Map<String, String>? readers,
  })  : timestamp = timestamp ?? createdAt * 1000,
        readers = readers ?? <String, String>{};

  String id;
  String author;
  String pubkey;
  String content;

  /// Nostr timestamp, seconds.
  int createdAt;
  int? originalCreatedAt;

  /// Absolute ms from the `ms` tag, the sub-second tiebreak; values <= created_at*1000 are ignored.
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

  /// Seal verification: true when signer matches author, false for a throwaway-key seal, null if unavailable.
  bool? senderVerified;

  /// Post-quantum transport; confidentiality, orthogonal to [senderVerified].
  bool pqEncrypted;

  /// Whether every ML-KEM key was root-seeded; defaults false, as history used nsec-derived keys.
  bool pqRoot;

  /// PQ wraps out of total members for a group message we sent; overrides [pqEncrypted].
  ({int pq, int total})? pqCoverage;
  String? bitchatMessageId;
  String? nymMessageId;

  /// Thread root, via NIP-10 `e` root tag for channels or `nymthread` for PMs/groups; null at top level.
  String? threadRoot;

  String? replyTo;

  int? anchorAt;

  int? anchorMs;
  DeliveryStatus deliveryStatus;
  bool isEdited;

  String? channel;
  String? geohash;

  bool isFileOffer;
  Map<String, dynamic>? fileOffer;

  /// Session-local path of a mesh attachment; [localMediaMime] selects image or file card.
  String? localMediaPath;
  String? localMediaMime;
  String? localMediaName;

  bool get hasLocalMedia =>
      localMediaPath != null && localMediaPath!.isNotEmpty;
  bool get isLocalImage => localMediaMime?.startsWith('image/') ?? false;

  /// Delivered over the Bluetooth mesh; session-local.
  bool viaMesh;

  bool isBot;

  /// NIP-13 committed difficulty, or null without a nonce tag; session-local.
  int? powTarget;

  /// Nymbot reasoning block.
  String? thinking;

  /// Pre-sign placeholder; cleared when the signed event arrives.
  bool optimistic;

  /// Held until the sender becomes trusted.
  bool spamGated;

  /// Flagged from a blocked user.
  bool blocked;

  MessageKind kind;

  /// Optional session-local action button for a system row.
  SystemAction? systemAction;

  int? expiresAt;

  bool slowHeld;

  bool heldShown = false;

  bool foreignKey = false;

  bool get localOnlyRow => optimistic && foreignKey;

  /// Read-receipt readers of own channel/group messages: pubkey to nym.
  final Map<String, String> readers;

  bool get isSystemRow =>
      kind == MessageKind.system || kind == MessageKind.action;

  /// True for `/me` emotes, by kind or by the `/me ` content prefix as the PWA does.
  bool get isMeAction => kind == MessageKind.me || content.startsWith('/me ');

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
        'pqEncrypted': pqEncrypted,
        'pqRoot': pqRoot,
        if (pqCoverage != null) 'pqCoverPq': pqCoverage!.pq,
        if (pqCoverage != null) 'pqCoverTotal': pqCoverage!.total,
        'bitchatMessageId': bitchatMessageId,
        'nymMessageId': nymMessageId,
        'threadRoot': threadRoot,
        if (replyTo != null) 'replyTo': replyTo,
        if (anchorAt != null) '_anchorAt': anchorAt,
        if (anchorMs != null) '_anchorMs': anchorMs,
        'deliveryStatus': deliveryStatus.name,
        'isEdited': isEdited,
        'channel': channel,
        'geohash': geohash,
        'isFileOffer': isFileOffer,
        'fileOffer': fileOffer,
        'isBot': isBot,
        'thinking': thinking,
        'kind': kind.name,
        if (powTarget != null) 'powTarget': powTarget,
        if (expiresAt != null) 'expiresAt': expiresAt,
        if (slowHeld) 'slowHeld': true,
      };

  /// Centered system pill like `displaySystemMessage`; [action] selects the italic action variant.
  factory Message.system(
    String content, {
    bool action = false,
    int? createdAtMs,
  }) {
    final ms = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;
    return Message(
      id: 'sys-${ms.toRadixString(36)}-${content.hashCode.toUnsigned(20)}',
      author: '',
      pubkey: '',
      content: content,
      createdAt: ms ~/ 1000,
      timestamp: ms,
      kind: action ? MessageKind.action : MessageKind.system,
    );
  }

  /// A system pill carrying an inline [SystemAction] button.
  factory Message.systemWithAction(
    String content,
    SystemAction action, {
    int? createdAtMs,
  }) {
    final ms = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;
    return Message(
      id: 'sys-${ms.toRadixString(36)}-${content.hashCode.toUnsigned(20)}',
      author: '',
      pubkey: '',
      content: content,
      createdAt: ms ~/ 1000,
      timestamp: ms,
      kind: MessageKind.system,
      systemAction: action,
    );
  }

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
      senderVerified:
          j['senderVerified'] is bool ? j['senderVerified'] as bool : null,
      // Absent in messages persisted before post-quantum shipped.
      pqEncrypted: j['pqEncrypted'] is bool ? j['pqEncrypted'] as bool : false,
      pqRoot: j['pqRoot'] is bool ? j['pqRoot'] as bool : false,
      pqCoverage: (j['pqCoverPq'] is int && j['pqCoverTotal'] is int)
          ? (pq: j['pqCoverPq'] as int, total: j['pqCoverTotal'] as int)
          : null,
      bitchatMessageId: j['bitchatMessageId'] as String?,
      nymMessageId: j['nymMessageId'] as String?,
      threadRoot: j['threadRoot'] as String?,
      replyTo: j['replyTo'] as String?,
      anchorAt: (j['_anchorAt'] as num?)?.toInt(),
      anchorMs: (j['_anchorMs'] as num?)?.toInt(),
      deliveryStatus: deliveryStatusFromString(j['deliveryStatus'] as String?),
      isEdited: j['isEdited'] == true,
      channel: j['channel'] as String?,
      geohash: j['geohash'] as String?,
      isFileOffer: j['isFileOffer'] == true,
      fileOffer: (j['fileOffer'] as Map?)?.cast<String, dynamic>(),
      isBot: j['isBot'] == true,
      thinking: j['thinking'] as String?,
      kind: messageKindFromString(j['kind'] as String?),
      powTarget: (j['powTarget'] as num?)?.toInt(),
      expiresAt: (j['expiresAt'] as num?)?.toInt(),
      slowHeld: j['slowHeld'] == true,
    );
  }
}

/// Leading zero bits of a 64-hex event id (NIP-13 proven work); 0 for anything else.
int powBitsForId(String? id) {
  if (id == null || id.length != 64) return 0;
  var bits = 0;
  for (var i = 0; i < id.length; i++) {
    final nibble = int.tryParse(id[i], radix: 16);
    if (nibble == null) return 0; // Not hex, so not an event id.
    if (nibble == 0) {
      bits += 4;
      continue;
    }
    // Leading zeros within this nibble: 8->0, 4->1, 2->2, 1->3.
    if (nibble >= 8) return bits;
    if (nibble >= 4) return bits + 1;
    if (nibble >= 2) return bits + 2;
    return bits + 3;
  }
  return bits;
}

int _orderAt(Message m) => m.anchorAt ?? m.createdAt;

int _orderMs(Message m) => m.anchorMs ?? m.ms;

bool _hasRealOrderMs(Message m) {
  final ms = _orderMs(m);
  return ms > 0 && ms > _orderAt(m) * 1000;
}

int compareMessages(Message a, Message b) {
  final sa = _orderAt(a);
  final sb = _orderAt(b);
  if (sa != sb) return sa - sb;
  if (_hasRealOrderMs(a) && _hasRealOrderMs(b)) {
    final dm = _orderMs(a) - _orderMs(b);
    if (dm != 0) return dm;
  }
  return a.seq - b.seq;
}
