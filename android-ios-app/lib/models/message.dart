/// Delivery state for a PM/group message.
enum DeliveryStatus { sending, sent, delivered, read, failed }

/// What kind of row a [Message] renders as.
///
/// * [normal] — an ordinary chat message (bubble / IRC row).
/// * [system] — a centered muted `.system-message` pill injected into the
///   conversation flow (command feedback, P2P/call status, flood notices).
/// * [action] — the purple-italic `.action-message` variant of a system message.
/// * [me] — a `/me …` emote rendered as an italic `* author action *` line.
///
/// Mirrors the PWA's `displaySystemMessage(content, type)` (`messages.js:1511`)
/// and the `/me` branch (`messages.js:662`).
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

/// An optional inline action button carried by a [MessageKind.system] row.
///
/// The PWA renders some system lines with an embedded `<button>` — e.g. the
/// spam false-positive notice has `data-action="reportSpamFalsePositive"` with
/// the flagged message stashed in a `data-spam-content` attribute
/// (messages.js:645). Native rows can't embed HTML, so the button is modelled
/// here: a [label] plus a [kind] discriminator and the [payload] the handler
/// needs (the flagged content for [SystemActionKind.reportSpamFalsePositive]).
enum SystemActionKind { reportSpamFalsePositive }

class SystemAction {
  const SystemAction({
    required this.kind,
    required this.label,
    this.payload = '',
  });

  final SystemActionKind kind;

  /// Button text (`Report false positive`).
  final String label;

  /// Action data — the flagged message body for the spam false-positive report.
  final String payload;
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
    this.senderVerified,
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
    this.kind = MessageKind.normal,
    this.systemAction,
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

  /// Tri-state cryptographic verification of a sealed (NIP-17/NIP-59) sender,
  /// mirroring the PWA's `senderVerified` (`messages.js:736`): `true` when the
  /// seal's signer matches the claimed author, `false` for a throwaway-key
  /// (Bitchat) seal, `null` when the seal isn't available to verify (restored
  /// history, or a public channel message that carries no seal). Drives the
  /// `.crypto-verified-badge` lock shown on PM/group messages.
  bool? senderVerified;
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

  /// What kind of row this renders as (normal / system / action / `/me`).
  /// Defaults to [MessageKind.normal]; a system/action message is one injected
  /// by [Message.system] (`displaySystemMessage`).
  MessageKind kind;

  /// Optional inline action button for a [MessageKind.system] row (e.g. the
  /// spam false-positive "Report false positive" affordance). Null for ordinary
  /// system lines. Not serialised — these notices are session-local.
  SystemAction? systemAction;

  /// Read-receipt readers for own channel/group messages: `pubkey → nym`. Drives
  /// the stacked reader-avatar delivery indicator (`group-readers`/
  /// `channel-readers`, `groups.js:2624`). Empty for everyone else.
  final Map<String, String> readers;

  /// True for the centered system/action pill rows (not an ordinary message).
  bool get isSystemRow =>
      kind == MessageKind.system || kind == MessageKind.action;

  /// True when this is a `/me` emote (rendered as an italic action line). The
  /// PWA keys this off the raw content prefix (`messages.js:662`), so we accept
  /// either an explicit [MessageKind.me] or the `/me ` content prefix.
  bool get isMeAction =>
      kind == MessageKind.me || content.startsWith('/me ');

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
        'kind': kind.name,
      };

  /// Builds a centered system/action pill row for the conversation flow,
  /// mirroring `displaySystemMessage(content, type)` (`messages.js:1511`). Pass
  /// [action] for the purple-italic `.action-message` variant. The id is
  /// synthetic (`sys-…`) and the row is flagged so the list renders the pill.
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

  /// A [MessageKind.system] pill that carries an inline action [SystemAction]
  /// button (e.g. the spam false-positive notice with its "Report false
  /// positive" affordance, messages.js:645).
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
      kind: messageKindFromString(j['kind'] as String?),
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
