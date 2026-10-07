
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import '../mesh/mesh_bridge.dart';
import '../mesh/mesh_controller.dart';
import '../pms/upload_activity.dart';
import '../toasts/toast_center.dart';
import '../toasts/toast_model.dart';
import 'media_notes.dart';
import 'once_crypto.dart';
import 'voice_recorder.dart';

typedef MediaUpload = Future<String?> Function(Uint8List bytes, String contentType);
typedef MediaContentSend = Future<void> Function(ChatView view, String content);
typedef MediaMeshSend = Future<String?> Function(
    ChatView view, String fileName, String mime, Uint8List bytes);

const String kMeshNotRunning = "The Bluetooth mesh isn't running.";
const String kSendingVoice = 'Sending voice message…';
const String kSendingVideoNote = 'Sending video note…';
const String kVoiceSendFailed = "Couldn't send the voice message: {error}";
const String kVideoNoteSendFailed = "Couldn't send the video note: {error}";
const String kRecordingEmpty = 'the recording is empty';
const String kVoiceRecordingFailed = 'The recording failed: {error}';
const String kNoRecordingToSend = "There's no recording to send.";

String voiceStopFailureText({bool noRecording = false, Object? error}) {
  if (noRecording) return tr(kNoRecordingToSend);
  if (error is VoiceRecordingFailure) {
    return tr(kVoiceRecordingFailed, {'error': tr(error.reason)});
  }
  return tr(kVoiceSendFailed,
      {'error': error == null ? tr(kVoiceNoData) : '$error'});
}
typedef MediaFileRead = Future<Uint8List> Function(String path);
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
    MediaFileRead? readFile,
    this.beginActivity,
    this.endActivity,
  }) : readFile = readFile ?? ((path) => File(path).readAsBytes());

  factory MediaNoteSender.live(Ref ref) => MediaNoteSender(
        upload: (bytes, type) async {
          final c = ref.read(nostrControllerProvider);
          final url = await c.uploadImage(bytes, contentType: type);
          if (url == null || url.isEmpty) {
            final why = c.lastUploadFailure;
            throw StateError(why.isEmpty ? 'upload failed' : why);
          }
          return url;
        },
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
            showToast(text, kind: ToastKind.error);
            app.addSystemMessageWithAction(
                text,
                SystemAction(
                    kind: SystemActionKind.retryMediaNote, label: tr('Retry')));
          } else {
            showToast(text);
          }
        },
        beginActivity: (kind, view) =>
            ref.read(nostrControllerProvider).beginChatActivity(kind, view),
        endActivity: (token) =>
            ref.read(nostrControllerProvider).endChatActivity(token),
      );

  final MediaUpload upload;
  final MediaContentSend sendContent;
  final MediaMeshSend sendMesh;
  final MediaNotice notice;
  final MediaFileRead readFile;
  final int? Function(String kind, ChatView view)? beginActivity;
  final void Function(int? token)? endActivity;

  PendingMediaNote? failed;
  final ValueNotifier<String?> sending = ValueNotifier<String?>(null);

  Future<bool> send(MediaNote desc, Uint8List bytes, ChatView target,
      {required String route, bool once = false}) {
    if (route == 'mesh') return sendOverMesh(desc, bytes, target, once: once);
    return uploadAndSend(desc, bytes, target, once: once);
  }

  Future<bool> sendRecording({
    required String path,
    required String kind,
    required String mime,
    required ChatView target,
    required String route,
    double? duration,
    List<double> samples = const [],
    bool once = false,
  }) async {
    final failText = kind == 'round' ? kVideoNoteSendFailed : kVoiceSendFailed;
    Uint8List bytes;
    try {
      bytes = await readFile(path);
      if (bytes.isEmpty) {
        throw kind == 'voice'
            ? const VoiceRecordingFailure(kVoiceNoData)
            : StateError(tr(kRecordingEmpty));
      }
    } catch (e) {
      debugPrint('[media-note] $kind recording unreadable: $e');
      notice(e is VoiceRecordingFailure
          ? voiceStopFailureText(error: e)
          : tr(failText, {'error': _short(e)}));
      return false;
    } finally {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    List<int> waveform = const [];
    if (kind == 'voice') {
      try {
        waveform = computeWaveform(
            [for (final v in samples) v.isFinite ? v : 0.0]);
      } catch (_) {
        waveform = List<int>.filled(MediaNoteLimits.waveformBars, 0);
      }
    }
    final desc = MediaNote(
      kind: kind,
      mime: mime,
      duration: duration,
      size: bytes.length,
      waveform: waveform,
    );
    try {
      return await send(desc, bytes, target, route: route, once: once);
    } catch (e) {
      debugPrint('[media-note] $kind send failed: $e');
      notice(tr(failText, {'error': _short(e)}));
      return false;
    }
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
      final types = once
          ? const ['application/octet-stream']
          : noteUploadTypes(desc.kind, desc.mime);
      String? url;
      final errors = <String>[];
      final activity =
          beginActivity?.call(UploadActivity.kindForNote(desc.kind), target);
      try {
        for (final type in types.isEmpty ? [desc.mime] : types) {
          try {
            url = await upload(body, type);
          } catch (e) {
            errors.add(_short(e, 400));
            continue;
          }
          if (url != null && url.isNotEmpty) break;
          errors.add('upload failed');
        }
      } finally {
        sending.value = null;
        endActivity?.call(activity);
      }
      if (url == null || url.isEmpty) {
        throw StateError(errors.isEmpty ? 'upload failed' : errors.join('; '));
      }
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
      debugPrint('[media-note] upload or publish failed: $e');
      failed = PendingMediaNote(desc: desc, bytes: bytes, target: target, once: once);
      notice(tr("Couldn't send: {error}", {'error': _short(e, 600)}), retry: true);
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

  static String _short(Object e, [int max = 120]) {
    final s = e is StateError ? e.message : e.toString();
    return s.length > max ? s.substring(0, max) : s;
  }
}

final mediaNoteSenderProvider =
    Provider<MediaNoteSender>((ref) => MediaNoteSender.live(ref));
