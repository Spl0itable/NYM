import 'package:flutter/widgets.dart';

class MediaNoteHost extends InheritedWidget {
  const MediaNoteHost({
    super.key,
    required super.child,
    required this.isOwn,
    required this.senderPubkey,
    this.groupId,
    this.messageId,
    this.localPath,
    this.meshPeerPubkey,
  });

  final bool isOwn;
  final String senderPubkey;
  final String? groupId;
  final String? messageId;
  final String? localPath;
  final String? meshPeerPubkey;

  static MediaNoteHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaNoteHost>();

  @override
  bool updateShouldNotify(MediaNoteHost oldWidget) =>
      isOwn != oldWidget.isOwn ||
      senderPubkey != oldWidget.senderPubkey ||
      groupId != oldWidget.groupId ||
      messageId != oldWidget.messageId ||
      localPath != oldWidget.localPath ||
      meshPeerPubkey != oldWidget.meshPeerPubkey;
}
