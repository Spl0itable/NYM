import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../media_notes/media_note_files.dart';
import 'playback_keeper.dart';

class AudioPlayback extends HeldMedia with ChangeNotifier {
  AudioPlayback(super.key, this.player) {
    _subs
      ..add(player.onDurationChanged.listen((d) {
        duration = d;
        notifyListeners();
      }))
      ..add(player.onPositionChanged.listen((d) {
        position = d;
        notifyListeners();
      }))
      ..add(player.onPlayerStateChanged.listen((s) {
        playing = s == PlayerState.playing;
        notifyListeners();
      }))
      ..add(player.onPlayerComplete.listen((_) {
        playing = false;
        position = Duration.zero;
        notifyListeners();
      }));
  }

  static final MediaKeeper<AudioPlayback> keeper =
      MediaKeeper<AudioPlayback>(grace: PlaybackKeeper.grace);

  final AudioPlayer player;
  final List<StreamSubscription<Object?>> _subs = [];

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool sourceSet = false;
  bool prepared = false;
  String? source;
  String? file;
  String? fileMime;

  @override
  bool get isPlaying => playing;

  @override
  void pausePlayback() => unawaited(player.pause().catchError((Object _) {}));

  @override
  void resumePlayback() =>
      unawaited(player.resume().catchError((Object _) {}));

  @override
  void releasePlayback() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    unawaited(player.dispose().catchError((Object _) {}));
    unawaited(MediaNoteFiles.deleteQuietly(file));
    dispose();
  }
}
