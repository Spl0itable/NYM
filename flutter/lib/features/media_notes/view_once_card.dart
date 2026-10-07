import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/secret_screen.dart';
import '../chat_lock/screen_privacy.dart';
import '../../widgets/common/app_dialog.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import '../mesh/mesh_controller.dart';
import 'media_note_files.dart';
import 'media_note_host.dart';
import 'media_note_stores.dart';
import 'media_notes.dart';
import 'once_crypto.dart';
import 'voice_note_format.dart';
import 'voice_note_player.dart';

abstract class OnceReceiptSender {
  Future<void> opened({
    required String onceId,
    required String senderPubkey,
    String? groupId,
    String? meshPeerPubkey,
  });
}

class NoopOnceReceiptSender implements OnceReceiptSender {
  @override
  Future<void> opened({
    required String onceId,
    required String senderPubkey,
    String? groupId,
    String? meshPeerPubkey,
  }) async {}
}

class ControllerOnceReceiptSender implements OnceReceiptSender {
  ControllerOnceReceiptSender(this._ref);

  final Ref _ref;

  @override
  Future<void> opened({
    required String onceId,
    required String senderPubkey,
    String? groupId,
    String? meshPeerPubkey,
  }) async {
    if (meshPeerPubkey != null) {
      final bridge = _ref.read(meshControllerProvider.notifier).bridge;
      if (bridge != null) await bridge.sendOnceOpened(meshPeerPubkey, onceId);
      return;
    }
    await _ref.read(nostrControllerProvider).sendViewOnceOpened(
        onceId: onceId, senderPubkey: senderPubkey, groupId: groupId);
  }
}

final onceReceiptSenderProvider =
    Provider<OnceReceiptSender>((ref) => ControllerOnceReceiptSender(ref));

typedef OnceBytesLoader = Future<Uint8List> Function(MediaNote note, String? localPath);

Future<Uint8List> defaultOnceBytes(MediaNote note, String? localPath) async {
  if (localPath != null) return MediaNoteFiles.readLocal(localPath);
  final ct = await MediaNoteFiles.fetch(note.url);
  return decryptOnce(ct, note.key, note.nonce);
}

final onceBytesLoaderProvider =
    Provider<OnceBytesLoader>((ref) => defaultOnceBytes);

const String kOnceOpenWarning =
    "View once: after you close it, Nymchat won't show it again. A modified app or another device could still keep a copy.";
const String kOnceViewerNote =
    'View once. Closing this removes it from Nymchat. A modified app or another device could still keep a copy.';
const String kOnceComposerNote =
    'Opens once, then disappears in Nymchat. A modified app or another device could still keep a copy.';

String onceViewKind(MediaNote note) => note.kind == 'round' ? 'video' : note.kind;

class ViewOnceCard extends ConsumerWidget {
  const ViewOnceCard({super.key, required this.note});

  final MediaNote note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(onceRevisionProvider);
    final c = context.nym;
    final host = MediaNoteHost.maybeOf(context);
    final own = host?.isOwn ?? false;
    final store = ref.read(onceStoreProvider);
    final kind = onceViewKind(note);
    String state;
    var done = false;
    if (own) {
      final by = store.remoteOpenedBy(note.onceId);
      final inGroup = host?.groupId != null;
      state = by.isEmpty
          ? tr('Sent')
          : (inGroup && by.length > 1
              ? tr('Opened by {n}', {'n': by.length})
              : tr('Opened'));
      done = true;
    } else if (store.isOpened(note.onceId)) {
      state = tr('Opened');
      done = true;
    } else {
      state = tr('Tap to view once');
    }
    final icon = switch (kind) {
      'video' => Icons.videocam_outlined,
      'voice' => Icons.mic_none,
      _ => Icons.image_outlined,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Opacity(
        opacity: done ? 0.7 : 1,
        child: InkWell(
          key: ValueKey('once-${note.onceId}'),
          borderRadius: BorderRadius.circular(12),
          onTap: done && !own ? null : () => _open(context, ref, own),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: c.primaryA(0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: done ? c.glassBorder : c.primaryA(0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: c.primary, size: 20),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tr(onceLabel(kind)),
                        style: TextStyle(
                            color: c.text,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                    Text(state,
                        key: ValueKey('onceState-${note.onceId}'),
                        style: TextStyle(color: c.textDim, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref, bool own) async {
    if (own) {
      await showAppAlert(context,
          tr("You sent this as view once, so it can't be opened from here."));
      return;
    }
    final store = ref.read(onceStoreProvider);
    if (store.isOpened(note.onceId)) return;
    final host = MediaNoteHost.maybeOf(context);
    final kind = onceViewKind(note);
    final ok = await showAppConfirm(context, tr(kOnceOpenWarning),
        okLabel: tr('View'), title: tr(onceLabel(kind)));
    if (!ok || !context.mounted) return;
    Uint8List bytes;
    try {
      bytes = await ref.read(onceBytesLoaderProvider)(note, host?.localPath);
    } catch (_) {
      if (context.mounted) {
        await showAppAlert(context,
            tr("This view-once media couldn't be loaded. Try again later."));
      }
      return;
    }
    store.markOpened(note.onceId);
    ref.read(onceRevisionProvider.notifier).state++;
    unawaited(ref.read(onceReceiptSenderProvider).opened(
          onceId: note.onceId,
          senderPubkey: host?.senderPubkey ?? '',
          groupId: host?.groupId,
          meshPeerPubkey: host?.meshPeerPubkey,
        ));
    final local = host?.localPath;
    if (local != null) {
      unawaited(MediaNoteFiles.deleteQuietly(local));
    }
    if (!context.mounted) return;
    await Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      pageBuilder: (_, _, _) =>
          ViewOnceViewer(
              bytes: bytes,
              kind: kind,
              mime: note.mime,
              prepareSession: ref.read(voiceSessionPrepProvider)),
    ));
  }
}

class ViewOnceViewer extends StatefulWidget {
  const ViewOnceViewer({
    super.key,
    required this.bytes,
    required this.kind,
    required this.mime,
    this.prepareSession,
  });

  final Uint8List bytes;
  final String kind;
  final String mime;
  final VoiceSessionPrep? prepareSession;

  @override
  State<ViewOnceViewer> createState() => _ViewOnceViewerState();
}

class _ViewOnceViewerState extends State<ViewOnceViewer> {
  String? _temp;
  VideoPlayerController? _video;
  AudioPlayer? _audio;
  bool _unplayable = false;

  @override
  void initState() {
    super.initState();
    SecretScreen.hold();
    ScreenPrivacy.hold();
    if (widget.kind != 'photo') _prepare();
  }

  Future<void> _prepare() async {
    final voice = widget.kind == 'video'
        ? null
        : voiceFileFor(widget.bytes, widget.mime, defaultTargetPlatform);
    if (widget.kind != 'video' && voice == null) {
      if (mounted) setState(() => _unplayable = true);
      return;
    }
    _temp = voice == null
        ? await MediaNoteFiles.writeTemp(widget.bytes, widget.mime)
        : await MediaNoteFiles.writeTempExt(voice.bytes, voice.ext);
    if (!mounted) return;
    if (widget.kind == 'video') {
      final c = VideoPlayerController.file(File(_temp!));
      try {
        await c.initialize();
        await c.play();
      } catch (_) {}
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _video = c);
    } else {
      final p = AudioPlayer();
      _audio = p;
      try {
        await widget.prepareSession?.call();
        await p.play(DeviceFileSource(_temp!, mimeType: voice!.mime));
      } catch (_) {}
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    SecretScreen.release();
    ScreenPrivacy.release();
    _video?.dispose();
    _audio?.dispose();
    MediaNoteFiles.deleteQuietly(_temp);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget media;
    if (widget.kind == 'photo') {
      media = Image.memory(widget.bytes, fit: BoxFit.contain, gaplessPlayback: true);
    } else if (widget.kind == 'video') {
      final v = _video;
      media = v != null && v.value.isInitialized
          ? AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v))
          : const CircularProgressIndicator();
    } else {
      media = _unplayable
          ? Text(tr(kVoiceAppleUnplayable),
              key: const ValueKey('onceUnplayable'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white))
          : const Icon(Icons.graphic_eq, color: Colors.white, size: 64);
    }
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            key: const ValueKey('onceViewer'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(child: Center(child: media)),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(tr(kOnceViewerNote),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFDDDDDD), fontSize: 13)),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                key: const ValueKey('onceClose'),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(tr('Close'),
                    style: const TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
