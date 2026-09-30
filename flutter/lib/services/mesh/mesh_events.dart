import 'dart:typed_data';

import 'protocol/mesh_profile.dart';

class MeshPublicMessage {
  MeshPublicMessage({
    required this.senderPeerID,
    required this.senderNickname,
    required this.content,
    required this.messageId,
    required this.timestampMs,
    this.channel,
    this.mentions = const [],
    this.isRelay = false,
    this.filePath,
    this.fileMime,
    this.fileName,
  });

  final String senderPeerID;
  final String senderNickname;
  final String content;
  final String messageId;
  final int timestampMs;
  final String? channel;
  final List<String> mentions;
  final bool isRelay;

  final String? filePath;
  final String? fileMime;
  final String? fileName;

  bool get hasFile => filePath != null;
  bool get isImage => fileMime?.startsWith('image/') ?? false;
}

class MeshPrivateMessage {
  MeshPrivateMessage({
    required this.senderPeerID,
    required this.messageId,
    required this.content,
    required this.timestampMs,
  });

  final String senderPeerID;
  final String messageId;
  final String content;
  final int timestampMs;
}

class MeshProfileReceived {
  MeshProfileReceived({required this.peerID, required this.profile});
  final String peerID;
  final MeshProfile profile;
}

class MeshFileReceived {
  MeshFileReceived({
    required this.fromPeerID,
    required this.fileName,
    required this.mimeType,
    required this.bytes,
    this.isDirect = true,
    this.channel,
    this.senderNickname = '',
  });

  final String fromPeerID;
  final String fileName;
  final String mimeType;
  final Uint8List bytes;

  /// True for an encrypted 1:1 DM file; false for a public/channel file.
  final bool isDirect;

  /// Null for a 1:1 DM file.
  final String? channel;
  final String senderNickname;

  bool get isImage => mimeType.startsWith('image/');
}

/// Ephemeral mesh typing indicator (Nymchat-only).
class MeshTypingEvent {
  MeshTypingEvent({
    required this.senderPeerID,
    required this.nickname,
    required this.isStart,
    required this.isDirect,
    this.channel,
  });

  final String senderPeerID;
  final String nickname;
  final bool isStart;

  final bool isDirect;

  /// Null for nearby and DM indicators.
  final String? channel;
}

class MeshReactionEvent {
  MeshReactionEvent({
    required this.senderPeerID,
    required this.targetId,
    required this.emoji,
    required this.isRemove,
    required this.reactorNick,
    required this.isDirect,
  });

  final String senderPeerID;

  /// Channel message id, or a DM's shared id.
  final String targetId;
  final String emoji;
  final bool isRemove;
  final String reactorNick;

  final bool isDirect;
}

class MeshReceipt {
  MeshReceipt({
    required this.fromPeerID,
    required this.messageId,
    required this.isRead,
  });

  final String fromPeerID;
  final String messageId;

  /// True for a read receipt, false for a delivery ack.
  final bool isRead;
}
