// High-level events emitted by MeshService for the app layer to consume.

import 'dart:typed_data';

import 'protocol/mesh_profile.dart';

/// A public broadcast message received over the mesh (nearby / channel chat).
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

  /// On-disk path of an attached file/media, when this message carries one.
  final String? filePath;
  final String? fileMime;
  final String? fileName;

  bool get hasFile => filePath != null;
  bool get isImage => fileMime?.startsWith('image/') ?? false;
}

/// A private (Noise-encrypted) message received over the mesh.
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

/// A rich profile transferred to us over the mesh (avatar/banner bytes).
class MeshProfileReceived {
  MeshProfileReceived({required this.peerID, required this.profile});
  final String peerID;
  final MeshProfile profile;
}

/// A file/media received over the mesh (from a DM or a public/channel send).
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

  /// True for an encrypted 1:1 DM file; false for a public/broadcast file.
  final bool isDirect;

  /// Null for a 1:1 DM file; set for a public/channel file.
  final String? channel;
  final String senderNickname;

  bool get isImage => mimeType.startsWith('image/');
}

/// An ephemeral typing indicator received over the mesh (Nymchat-only).
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

  /// True for a 1:1 DM typing indicator; false for a channel/nearby one.
  final bool isDirect;

  /// Channel name for a channel typing indicator (null for nearby/DM).
  final String? channel;
}

/// An emoji reaction received over the mesh (add or remove).
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

  /// The reacted message's id (channel message id, or a DM's shared id).
  final String targetId;
  final String emoji;
  final bool isRemove;
  final String reactorNick;

  /// True for a 1:1 (encrypted) reaction; false for a channel/nearby one.
  final bool isDirect;
}

/// A delivery/read acknowledgement received for one of our sent messages.
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
