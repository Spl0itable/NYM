
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import '../mesh/mesh_bridge.dart';
import '../mesh/mesh_controller.dart';
import 'media_notes.dart';
import 'once_crypto.dart';

typedef MediaUpload = Future<String?> Function(Uint8List bytes, String contentType);
typedef MediaContentSend = Future<void> Function(ChatView view, String content);
typedef MediaMeshSend = Future<String?> Function(
    ChatView view, String fileName, String mime, Uint8List bytes);

const String kMeshNotRunning = "The Bluetooth mesh isn't running.";
const String kSendingVoice = 'Sending voice message…';
const String kSendingVideoNote = 'Sending video note…';
typedef MediaNotice = void Function(String text, {bool retry});

class PendingMediaNote {
  const PendingMediaNote({
    required this.desc,
    required this.bytes,
    required this.target,
    required this.once,
  });

  final MediaNote desc;
  final Uint8List bytes;
  final ChatView target;
  final bool once;
}

String mediaSurface(ChatView v) => switch (v.kind) {
      ViewKind.pm => 'dm',
      ViewKind.group => 'group',
      _ => 'channel',
    };

String mediaRouteFor(MeshBridge? bridge, bool online, ChatView v) {
  if (bridge != null && bridge.shouldSendOverMesh(v)) return 'mesh';
  return online ? 'online' : 'offline';
}

MediaFeatureState mediaFeatureWith(String feature, ChatView v, String route) =>
    featureState(
      feature,
      MediaFeatureContext(
        surface: mediaSurface(v),
        route: route,
        meshDm: true,
      ),
    );

class MediaNoteSender {
  MediaNoteSender({
    required this.upload,
    required this.sendContent,
    required this.sendMesh,
    required this.notice,
  });

  factory MediaNoteSender.live(Ref ref) => MediaNoteSender(
        upload: (bytes, type) =>
            ref.read(nostrControllerProvider).uploadImage(bytes, contentType: type),
        sendContent: (view, content) =>
            ref.read(nostrControllerProvider).sendMediaNoteContent(view, content),
        sendMesh: (view, name, mime, bytes) async {
          final bridge = ref.read(meshControllerProvider.notifier).bridge;
          if (bridge == null) return kMeshNotRunning;
          final ok = await bridge.sendFileFromComposer(view, name, mime, bytes);
          return ok ? null : MediaNoteReasons.meshTooLarge;
        },
        notice: (text, {retry = false}) {
          final app = ref.read(appStateProvider.notifier);
          if (retry) {
            app.addSystemMessageWithAction(
                text,
                SystemAction(
                    kind: SystemActionKind.retryMediaNote, label: tr('Retry')));
          } else {
            app.addSystemMessage(text);
          }
        },
      );

  final MediaUpload upload;
  final MediaContentSend sendContent;
  final MediaMeshSend sendMesh;
  final MediaNotice notice;

  PendingMediaNote? failed;
  final ValueNotifier<String?> sending = ValueNotifier<String?>(null);

  Future<bool> send(MediaNote desc, Uint8List bytes, ChatView target,
      {required String route, bool once = false}) {
    if (route == 'mesh') return sendOverMesh(desc, bytes, target, once: once);
    return uploadAndSend(desc, bytes, target, once: once);
  }

  Future<bool> uploadAndSend(MediaNote desc, Uint8List bytes, ChatView target,
      {bool once = false}) async {
    failed = null;
    try {
      var body = bytes;
      OnceSecret? secret;
      if (once) {
        secret = newOnceSecret();
        body = await encryptOnce(bytes, secret.key, secret.nonce);
      }
      sending.value =
          tr(desc.kind == 'round' ? kSendingVideoNote : kSendingVoice);
      final String? url;
      try {
        url = await upload(body, once ? 'application/octet-stream' : desc.mime);
      } finally {
        sending.value = null;
      }
      if (url == null || url.isEmpty) throw StateError('upload failed');
      final note = MediaNote(
        kind: desc.kind,
        mime: desc.mime,
        duration: desc.duration,
        size: desc.size,
        waveform: desc.waveform,
        once: once,
        onceId: secret?.onceId ?? '',
        key: secret?.key ?? '',
        nonce: secret?.nonce ?? '',
      );
      final full = attachDescriptor(url, note);
      if (full.isEmpty) throw StateError('descriptor');
      await sendContent(target, once ? onceContent(desc.kind, full) : full);
      return true;
    } catch (e) {
      failed = PendingMediaNote(desc: desc, bytes: bytes, target: target, once: once);
      notice(tr("Couldn't send: {error}", {'error': _short(e)}), retry: true);
      return false;
    }
  }

  Future<bool> retry() async {
    final f = failed;
    if (f == null) return false;
    return uploadAndSend(f.desc, f.bytes, f.target, once: f.once);
  }

  Future<bool> sendOverMesh(MediaNote desc, Uint8List bytes, ChatView target,
      {bool once = false}) async {
    final size = meshSizeCheck(bytes.length);
    final tooLarge = tr(MediaNoteReasons.meshTooLarge,
        {'size': formatBytes(bytes.length)});
    if (!size.ok) {
      notice(tooLarge);
      return false;
    }
    var note = desc;
    if (once) {
      note = MediaNote(
        kind: desc.kind,
        mime: desc.mime,
        duration: desc.duration,
        waveform: desc.waveform,
        once: true,
        onceId: newOnceSecret().onceId,
      );
    }
    final name = meshFileName(note);
    final err = await sendMesh(
        target, name.isEmpty ? 'file.${extForMime(desc.mime)}' : name, desc.mime, bytes);
    if (err != null) {
      notice(err == MediaNoteReasons.meshTooLarge ? tooLarge : tr(err));
    }
    return err == null;
  }

  static String _short(Object e) {
    final s = e is StateError ? e.message : e.toString();
    return s.length > 120 ? s.substring(0, 120) : s;
  }
}

final mediaNoteSenderProvider =
    Provider<MediaNoteSender>((ref) => MediaNoteSender.live(ref));
