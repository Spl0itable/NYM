import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

abstract class HeldMedia {
  HeldMedia(this.key);

  final String? key;
  final Set<Object> _holders = <Object>{};
  Timer? _grace;
  bool _resume = false;
  bool _released = false;

  int get holders => _holders.length;

  bool get released => _released;

  bool get isPlaying;

  void pausePlayback();

  void resumePlayback();

  void releasePlayback();

  void holderLeft(Object holder) {}

  void _release() {
    if (_released) return;
    _released = true;
    _grace?.cancel();
    _grace = null;
    releasePlayback();
  }
}

class MediaKeeper<T extends HeldMedia> {
  MediaKeeper({this.grace = const Duration(seconds: 1)});

  final Duration grace;
  final Map<String, T> _live = <String, T>{};
  final Map<String, Set<VoidCallback>> _watchers =
      <String, Set<VoidCallback>>{};

  T? join(String? key, Object holder) {
    final s = key == null ? null : _live[key];
    if (s == null || s._released) return null;
    s._grace?.cancel();
    s._grace = null;
    s._holders.add(holder);
    if (s._resume) {
      s._resume = false;
      s.resumePlayback();
    }
    return s;
  }

  T start(String? key, Object holder, T Function() create,
      {void Function(T live)? discard}) {
    final current = key == null ? null : _live[key];
    if (current != null && !current._released) {
      discard?.call(current);
      return join(key, holder)!;
    }
    final s = create().._holders.add(holder);
    if (key != null) {
      _live[key] = s;
      for (final w in [...?_watchers[key]]) {
        w();
      }
    }
    return s;
  }

  void leave(T s, Object holder) {
    s._holders.remove(holder);
    if (s._released) return;
    s.holderLeft(holder);
    if (s._holders.isNotEmpty || s._grace != null) return;
    final key = s.key;
    if (key == null) {
      s._release();
      return;
    }
    if (s.isPlaying) {
      s._resume = true;
      s.pausePlayback();
    }
    s._grace = Timer(grace, () {
      s._grace = null;
      if (s._holders.isNotEmpty) return;
      if (identical(_live[key], s)) _live.remove(key);
      s._release();
    });
  }

  void watch(String? key, VoidCallback onStart) {
    if (key == null) return;
    (_watchers[key] ??= <VoidCallback>{}).add(onStart);
  }

  void unwatch(String? key, VoidCallback onStart) {
    if (key == null) return;
    final set = _watchers[key];
    if (set == null) return;
    set.remove(onStart);
    if (set.isEmpty) _watchers.remove(key);
  }
}

class SharedPlayback extends HeldMedia {
  SharedPlayback._(super.key, this.controller, this._onRelease);

  final VideoPlayerController controller;
  final VoidCallback? _onRelease;
  final Set<Object> _visible = <Object>{};
  final Set<Object> _covered = <Object>{};
  final Set<Object> _still = <Object>{};
  Timer? _unseen;
  bool _tracked = false;

  bool sound = false;

  bool get seen => _visible.isNotEmpty;

  bool get shown =>
      _visible.any((h) => !_covered.contains(h) && !_still.contains(h));

  @override
  bool get isPlaying => controller.value.isPlaying;

  @override
  void pausePlayback() => unawaited(controller.pause());

  @override
  void resumePlayback() => unawaited(controller.play());

  @override
  void releasePlayback() {
    _unseen?.cancel();
    _unseen = null;
    unawaited(controller.dispose());
    _onRelease?.call();
  }

  @override
  void holderLeft(Object holder) {
    _visible.remove(holder);
    _covered.remove(holder);
    _still.remove(holder);
    if (_holders.isEmpty) {
      _unseen?.cancel();
      _unseen = null;
    } else {
      _watchUnseen();
    }
  }

  void markVisible(Object holder, bool visible) {
    if (!_holders.contains(holder)) return;
    _tracked = true;
    if (visible) {
      _visible.add(holder);
      _unseen?.cancel();
      _unseen = null;
    } else {
      _visible.remove(holder);
      _watchUnseen();
    }
  }

  void markCovered(Object holder, bool covered) {
    if (!_holders.contains(holder)) return;
    if (covered) {
      _covered.add(holder);
    } else {
      _covered.remove(holder);
      _watchUnseen();
    }
  }

  void markTicking(Object holder, bool ticking) {
    if (!_holders.contains(holder)) return;
    if (ticking) {
      _still.remove(holder);
    } else {
      _still.add(holder);
    }
  }

  void _watchUnseen() {
    if (!_tracked || seen || _holders.isEmpty || _released || _unseen != null) {
      return;
    }
    _unseen = Timer(PlaybackKeeper.grace, () {
      _unseen = null;
      if (seen ||
          _released ||
          _holders.isEmpty ||
          !isPlaying ||
          _covered.isNotEmpty) {
        return;
      }
      final loud = sound;
      sound = false;
      unawaited(controller.pause());
      if (loud) {
        unawaited(controller.setVolume(0));
        unawaited(controller.setLooping(true));
      }
    });
  }
}

class PlaybackKeeper {
  PlaybackKeeper._();

  static const Duration grace = Duration(seconds: 1);

  static final MediaKeeper<SharedPlayback> _keeper =
      MediaKeeper<SharedPlayback>(grace: grace);

  static String keyFor(String scope, String source) => '$scope\n$source';

  static SharedPlayback? join(String? key, Object holder) =>
      _keeper.join(key, holder);

  static SharedPlayback start(
    String? key,
    Object holder,
    VideoPlayerController controller, {
    VoidCallback? onRelease,
  }) =>
      _keeper.start(
        key,
        holder,
        () => SharedPlayback._(key, controller, onRelease),
        discard: (live) {
          if (identical(live.controller, controller)) return;
          unawaited(controller.dispose());
          onRelease?.call();
        },
      );

  static void leave(SharedPlayback s, Object holder) =>
      _keeper.leave(s, holder);

  static void watch(String? key, VoidCallback onStart) =>
      _keeper.watch(key, onStart);

  static void unwatch(String? key, VoidCallback onStart) =>
      _keeper.unwatch(key, onStart);
}
