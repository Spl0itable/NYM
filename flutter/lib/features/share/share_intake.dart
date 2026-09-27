import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'share_destination_sheet.dart';

/// Bridges the OS share sheet into the app: when another app shares text, a
/// URL, or media into Nymchat, this collects the payload and opens the
/// destination picker so the user chooses a channel / PM / group.
///
/// Wired from the root widget alongside deep links and push. Self-guards so a
/// missing platform channel (tests, web, de-Googled builds) no-ops.
class ShareIntake {
  ShareIntake({required this.ref, required this.navKey});

  final WidgetRef ref;
  final GlobalKey<NavigatorState> navKey;

  StreamSubscription<List<SharedMediaFile>>? _sub;

  /// Starts listening. Handles the cold-start payload (app launched by a share)
  /// and the warm stream (shared while already running).
  Future<void> start() async {
    try {
      // Cold start: the app was launched by a share intent.
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      if (initial.isNotEmpty) {
        _present(initial);
        // Tell the plugin we consumed it so a later getInitialMedia won't
        // replay the same share.
        await ReceiveSharingIntent.instance.reset();
      }
    } catch (_) {
      // Plugin unavailable on this platform/build — nothing to do.
    }
    try {
      _sub = ReceiveSharingIntent.instance
          .getMediaStream()
          .listen(_present, onError: (_) {});
    } catch (_) {
      // Stream unavailable — cold-start-only is still fine.
    }
  }

  void _present(List<SharedMediaFile> media) {
    final payload = _toPayload(media);
    if (payload.isEmpty) return;
    // Defer to the next frame so the navigator/providers are settled even when
    // this fires during cold start.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = navKey.currentContext;
      if (ctx == null) return;
      showShareDestinationSheet(ctx, ref, payload);
    });
  }

  /// Collapses the plugin's media list into a single [SharedPayload]: text/URL
  /// entries join into one caption; image/video/file entries become local
  /// paths for the composer's upload pipeline.
  SharedPayload _toPayload(List<SharedMediaFile> media) {
    final texts = <String>[];
    final paths = <String>[];
    for (final m in media) {
      switch (m.type) {
        case SharedMediaType.text:
        case SharedMediaType.url:
          // For text/url the `path` field carries the string itself.
          if (m.path.trim().isNotEmpty) texts.add(m.path.trim());
        case SharedMediaType.image:
        case SharedMediaType.video:
        case SharedMediaType.file:
          if (m.path.isNotEmpty) paths.add(m.path);
      }
      // iOS may attach a caption alongside media.
      final msg = m.message;
      if (msg != null && msg.trim().isNotEmpty) texts.add(msg.trim());
    }
    return SharedPayload(
      text: texts.isEmpty ? null : texts.join('\n'),
      filePaths: paths,
    );
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
