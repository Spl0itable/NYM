import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import '../messages/format/audio_message.dart';
import '../messages/format/nym_format.dart';
import 'media_note_files.dart';
import 'media_note_host.dart';
import 'media_notes.dart';
import 'round_video_note.dart';
import 'view_once_card.dart';
import 'voice_note_player.dart';

MediaNote? localMediaNote(String? name, String? mime) {
  final parsed = parseMeshFileName(name ?? '', mime);
  if (parsed != null) return parsed.copyWith(local: true);
  final m = baseMime(mime);
  if (m.startsWith('audio/')) {
    return MediaNote(kind: 'voice', mime: m, local: true);
  }
  return null;
}

Widget audioOrMediaNote(AudioBlock block) {
  final note = block.note;
  if (note == null) return AudioMessage(url: block.url, fileName: block.fileName);
  return MediaNoteView(note: note);
}

class MediaNoteView extends StatelessWidget {
  const MediaNoteView({super.key, required this.note, this.localPath});

  final MediaNote note;
  final String? localPath;

  @override
  Widget build(BuildContext context) {
    final host = MediaNoteHost.maybeOf(context);
    final path = localPath ?? host?.localPath;
    if (note.local && path == null) {
      return Text(
        tr('This mesh file is no longer on this device.'),
        style: TextStyle(
            color: context.nym.textDim,
            fontStyle: FontStyle.italic,
            fontSize: 12),
      );
    }
    if (note.once) return ViewOnceCard(note: note);
    switch (note.kind) {
      case 'voice':
        return VoiceNotePlayer(note: note, localPath: path);
      case 'round':
        return RoundVideoNote(note: note, localPath: path);
      case 'photo':
        if (path != null) return _LocalPhoto(path: path);
    }
    return const SizedBox.shrink();
  }
}

class _LocalPhoto extends StatelessWidget {
  const _LocalPhoto({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: MediaNoteFiles.readLocal(path),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) return const SizedBox(width: 160, height: 120);
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260, maxHeight: 320),
            child: Image.memory(bytes, fit: BoxFit.cover),
          ),
        );
      },
    );
  }
}
