// notifications_service.dart - Synthesized notification tones + local
// notifications, ported from `../js/modules/notifications.js`.
//
// Two responsibilities, mirroring the PWA:
//  1. playSound(name) — synthesize and play one of the chiptune tones selected
//     by `settings.sound` (notifications.js `playSound`). `'none'` is silent.
//  2. notify(...) — surface a system notification for a new message/mention/PM,
//     honoring `settings.notificationsEnabled`, `groupNotifyMentionsOnly` and
//     `notifyFriendsOnly` (notifications.js `showNotification` gate).
//
// Wiring into the message pipeline is intentionally left to the caller; this
// only exposes the API + a Riverpod provider.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/notification_service.dart';
import '../../state/settings_provider.dart';
import 'notification_sounds.dart';

/// Plays a rendered WAV tone buffer. Abstracted so the real `audioplayers`
/// implementation is used in the app while tests inject a no-op (so no audio
/// fires and no platform plugin is touched in the test harness).
abstract class TonePlayer {
  /// Play the given WAV bytes for the tone keyed [name]. Must never throw.
  Future<void> play(String name, Uint8List wav);
}

/// Default [TonePlayer] backed by `audioplayers`, feeding it the synthesized
/// WAV bytes directly (the native equivalent of notifications.js's Web Audio
/// playback). The player is created lazily on first use.
class AudioPlayersTonePlayer implements TonePlayer {
  AudioPlayer? _player;

  AudioPlayer _ensure() {
    final existing = _player;
    if (existing != null) return existing;
    final p = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _player = p;
    return p;
  }

  @override
  Future<void> play(String name, Uint8List wav) async {
    if (kIsWeb) return;
    try {
      final player = _ensure();
      // Restart from the top each time so rapid notifications retrigger the
      // tone instead of being ignored mid-playback.
      await player.stop();
      await player.play(BytesSource(wav, mimeType: 'audio/wav'));
    } catch (_) {
      // Best-effort; never throw from a sound (matches the PWA's try/catch).
    }
  }
}

/// Context for a single notification, mirroring notifications.js `channelInfo`
/// enough to drive the friends-only / mentions-only gates.
class NotifyContext {
  const NotifyContext({
    this.senderPubkey,
    this.isGroup = false,
    this.isMention = false,
    this.isFriend = false,
    this.isBot = false,
    this.isBlocked = false,
    this.payload,
  });

  final String? senderPubkey;
  final bool isGroup;

  /// True when the inbound group message @-mentions us.
  final bool isMention;
  final bool isFriend;
  final bool isBot;
  final bool isBlocked;

  /// Opaque payload forwarded to [NotificationService] (e.g. a deep link).
  final String? payload;
}

/// The conversation surface an inbound message belongs to, for notification
/// gating (channel = public geohash/named; pm; group).
enum NotifyKind { channel, pm, group }

/// Pure notification-gate decision for an inbound message, mirroring the PWA's
/// `showNotification` gate (notifications.js) plus the inbound `handleEvent`
/// pre-checks (nostr-core.js: own/historical/mention/active-view).
///
/// Returns true when this message should raise a notification (sound + local
/// notification). All inputs are explicit so this is unit-testable without any
/// providers or IO.
///
/// Gates, in order (any failing → false):
/// * [notificationsEnabled] off → false (notifications.js line 6).
/// * [isOwn] → false (don't notify for our own messages).
/// * [isHistorical] → false (replayed backlog never notifies live).
/// * [isBlocked] → false; [isBot] → false (notifications.js lines 11/14).
/// * [isActiveView] → false (PWA: skip when actively viewing the conversation).
/// * [friendsOnly] + not [isFriend] → false (notifications.js line 12).
/// * channel: only an @-mention notifies (PWA channel `shouldNotify`).
/// * group + [groupMentionsOnly]: only a mention notifies.
/// * pm: always notifies (subject to the gates above).
bool shouldNotify({
  required NotifyKind kind,
  required bool isOwn,
  required bool isHistorical,
  required bool notificationsEnabled,
  bool isMention = false,
  bool isFriend = false,
  bool isBlocked = false,
  bool isBot = false,
  bool isActiveView = false,
  bool friendsOnly = false,
  bool groupMentionsOnly = false,
}) {
  if (!notificationsEnabled) return false;
  if (isOwn) return false;
  if (isHistorical) return false;
  if (isBlocked) return false;
  if (isBot) return false;
  if (isActiveView) return false;
  if (friendsOnly && !isFriend) return false;

  switch (kind) {
    case NotifyKind.channel:
      // Public channels only notify on an @-mention (PWA channel gate).
      return isMention;
    case NotifyKind.group:
      // Mentions-only mode suppresses non-mention group messages.
      if (groupMentionsOnly && !isMention) return false;
      return true;
    case NotifyKind.pm:
      // Any PM from another user notifies.
      return true;
  }
}

class NotificationsService {
  NotificationsService(
    this._ref, {
    NotificationService? local,
    TonePlayer? player,
  })  : _local = local ?? NotificationService(),
        _player = player;

  final Ref _ref;
  final NotificationService _local;

  /// Lazily-created tone player. Null until the first audible sound plays (so
  /// no audio plugin is touched at construction). Tests inject a no-op.
  TonePlayer? _player;

  /// Cached rendered WAV bytes per sound key (synthesis is deterministic).
  final Map<String, Uint8List> _wavCache = {};

  /// Dedup: don't replay the same tone within 2s (notifications.js `playSound`).
  int _lastSoundPlayedAt = 0;

  /// Plays the tone for [name] (a `settings.sound` value). Silent for `'none'`
  /// or an unknown key. The 2-second replay guard mirrors the PWA.
  Future<void> playSound(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastSoundPlayedAt != 0 && now - _lastSoundPlayedAt < 2000) return;

    final descriptor = resolveSound(name);
    if (descriptor == null) return; // Silent / unknown.
    _lastSoundPlayedAt = now;

    final wav = _wavCache.putIfAbsent(name, () => renderSoundWav(descriptor));
    await _playWav(name, wav);
  }

  /// Renders (without playing) the WAV bytes for [name], or null if silent.
  /// Exposed so a custom-sound notification path can reuse the buffer.
  Uint8List? renderTone(String name) {
    final descriptor = resolveSound(name);
    if (descriptor == null) return null;
    return _wavCache.putIfAbsent(name, () => renderSoundWav(descriptor));
  }

  /// Shows a local notification for a new message/mention/PM, applying the
  /// notifications.js `showNotification` gate against the current settings.
  /// Also plays the configured sound (unless silenced) like the PWA.
  ///
  /// [notifyFriendsOnly] and [groupNotifyMentionsOnly] map to the PWA prefs of
  /// the same name. They aren't on the native `Settings` model yet, so the
  /// integrating caller passes them (defaults match the PWA's "off").
  /// TODO(verify): once `notifyFriendsOnly` / `groupNotifyMentionsOnly` land on
  /// the shared `Settings` model, read them here instead of via parameters.
  Future<void> notify({
    required String title,
    required String body,
    NotifyContext context = const NotifyContext(),
    bool notifyFriendsOnly = false,
    bool groupNotifyMentionsOnly = false,
  }) async {
    final settings = _ref.read(settingsProvider);
    if (!settings.notificationsEnabled) return;
    if (context.isBlocked) return;
    if (context.isBot) return;
    // notifyFriendsOnly: skip non-friends (notifications.js line 12).
    if (notifyFriendsOnly &&
        context.senderPubkey != null &&
        !context.isFriend) {
      return;
    }
    // groupNotifyMentionsOnly: in a group, only mentions notify.
    if (context.isGroup && groupNotifyMentionsOnly && !context.isMention) {
      return;
    }

    if (soundIsAudible(settings.sound)) {
      await playSound(settings.sound);
    }
    await _local.showNotification(
      title: title,
      body: body,
      payload: context.payload,
    );
  }

  Future<void> _playWav(String name, Uint8List wav) async {
    if (kIsWeb) return;
    // Lazy-init the real player on first audible tone (matches notifications.js
    // creating the AudioContext on demand).
    final player = _player ??= AudioPlayersTonePlayer();
    await player.play(name, wav);
  }
}

/// Riverpod provider for the notifications service.
final notificationsServiceProvider = Provider<NotificationsService>((ref) {
  return NotificationsService(ref);
});
