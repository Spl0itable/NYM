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
import '../../state/app_state.dart';
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
    this.eventId,
    this.timestampMs,
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

  /// The source event id (notifications.js `channelInfo.eventId`). Keys the
  /// alert dedup against the bell history and the persisted seen-key
  /// (`e:<id>`), so a replayed/resynced copy of an event can't re-alert.
  final String? eventId;

  /// The event's `created_at` in milliseconds (notifications.js `timestamp`).
  /// Drives the backlog age gate plus the no-eventId dedup/seen fallbacks.
  /// Null/zero falls back to "now", exactly like the PWA (notifications.js:22).
  final int? timestampMs;
}

/// The conversation surface an inbound message belongs to, for notification
/// gating (channel = public geohash/named; pm; group).
enum NotifyKind { channel, pm, group }

/// Pure decision: should an inbound message be RECORDED into the in-app
/// notification history? Mirrors the PWA, where every qualifying message is
/// pushed to history regardless of age — a live one loudly (`showNotification`)
/// and a backlog/replayed one silently (`_addNotificationToHistory`, pms.js
/// 1383 / groups.js 1347 / nostr-core.js 548). So this is the [shouldNotify]
/// gate MINUS the historical condition: an old gift-wrapped PM/group backlog
/// still belongs in the bell history, it just doesn't alert.
///
/// Gates, in order (any failing → false):
/// * [notificationsEnabled] off → false (notifications.js line 6).
/// * [isOwn] → false (don't surface our own messages).
/// * [isBlocked] → false; [isBot] → false (notifications.js lines 11/14).
/// * [isActiveView] → false (PWA records only in the not-viewing `else` branch).
/// * [friendsOnly] + not [isFriend] → false (notifications.js line 12).
/// * channel: only an @-mention is recorded (PWA channel gate).
/// * group + [groupMentionsOnly]: only a mention is recorded.
/// * pm: always recorded (subject to the gates above).
bool shouldRecordNotification({
  required NotifyKind kind,
  required bool isOwn,
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
  if (isBlocked) return false;
  if (isBot) return false;
  if (isActiveView) return false;
  if (friendsOnly && !isFriend) return false;

  switch (kind) {
    case NotifyKind.channel:
      // Public channels only notify/record on an @-mention (PWA channel gate).
      return isMention;
    case NotifyKind.group:
      // Mentions-only mode suppresses non-mention group messages.
      if (groupMentionsOnly && !isMention) return false;
      return true;
    case NotifyKind.pm:
      // Any PM from another user qualifies.
      return true;
  }
}

/// Pure notification-gate decision for an inbound message, mirroring the PWA's
/// `showNotification` gate (notifications.js) plus the inbound `handleEvent`
/// pre-checks (nostr-core.js: own/historical/mention/active-view).
///
/// Returns true when this message should raise a LOUD notification (sound +
/// local popup). This is exactly [shouldRecordNotification] AND `!isHistorical`
/// — a historical message is still recorded to history (silently) but never
/// alerts. All inputs are explicit so this is unit-testable without any
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
  if (isHistorical) return false;
  return shouldRecordNotification(
    kind: kind,
    isOwn: isOwn,
    notificationsEnabled: notificationsEnabled,
    isMention: isMention,
    isFriend: isFriend,
    isBlocked: isBlocked,
    isBot: isBot,
    isActiveView: isActiveView,
    friendsOnly: friendsOnly,
    groupMentionsOnly: groupMentionsOnly,
  );
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

  /// Resets the 2s replay-dedup window so the next [playSound] always sounds.
  /// The PWA zeroes `_lastSoundPlayedAt` before a settings sound preview
  /// (`soundSelect.onchange`, app.js:3481-3483) so rapid consecutive previews
  /// always play instead of being swallowed by the guard.
  void resetSoundDedupe() => _lastSoundPlayedAt = 0;

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

  /// 24h backlog cutoff shared with the bell history (notifications.js:59/135):
  /// an event older than this must never raise a loud alert, no matter how it
  /// reached us (relay rehydration, reconnect replay, cross-device resync).
  static const int _maxAlertAgeMs = 24 * 60 * 60 * 1000;

  /// Shows a local notification for a new message/mention/PM, applying the
  /// notifications.js `showNotification` gate against the current settings.
  /// Also plays the configured sound (unless silenced) like the PWA.
  ///
  /// Beyond the settings gates, this enforces the PWA's replay guards
  /// (notifications.js:22-69) so old or already-seen events can never re-alert:
  /// the 24h backlog age cutoff, the dedup against the bell history (live +
  /// replay paths can both fire for the same underlying event), and the
  /// persisted 48h seen-key map (read on this device in a previous session, or
  /// on another device via the synced read-state). A gated event is still
  /// recorded into the bell history by the caller; only the sound/popup is
  /// suppressed — exactly the PWA's `previouslySeen`/dupe behavior.
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
    // Digest bodies ("10 recent messages:") never alert (notifications.js:13).
    if (body.contains('10 recent messages:')) return;
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
    if (_isReplayedOrSeen(title: title, body: body, context: context)) return;

    if (soundIsAudible(settings.sound)) {
      await playSound(settings.sound);
    }
    await _local.showNotification(
      title: title,
      body: body,
      payload: context.payload,
    );
  }

  /// The PWA `showNotification` replay guards (notifications.js:22-69), in the
  /// same order. True → the event must NOT alert (it's backlog, a duplicate, or
  /// already read):
  /// * Age: older than the 24h bell window (`_addNotificationToHistory`'s
  ///   cutoff, notifications.js:135) — relay rehydration of hours-old messages
  ///   never re-alerts. A missing timestamp is treated as "now" (a live event),
  ///   matching notifications.js:22.
  /// * Dupe: already in the bell history — same event id, or same
  ///   title+body+sender within 60s (notifications.js:27-37). The history store
  ///   dedups its own entries the same way, but that runs AFTER the alert, so
  ///   the loud path must check independently or a multi-relay duplicate /
  ///   reconnect replay re-fires the popup for an event the bell already holds.
  /// * Seen: the event's stable key is in the persisted 48h seen-map
  ///   (`_isNotificationSeen`, notifications.js:53) — viewed here in a previous
  ///   session or on another device (synced read-state). The PWA records such
  ///   an entry silently and returns before the sound/popup (line 69); here the
  ///   caller's `record()` still lands it pre-viewed, so skipping the alert
  ///   yields the identical outcome.
  bool _isReplayedOrSeen({
    required String title,
    required String body,
    required NotifyContext context,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rawTs = context.timestampMs ?? 0;
    final ts = rawTs > 0 ? rawTs : now;
    if (now - ts > _maxAlertAgeMs) return true;

    final eventId = context.eventId ?? '';
    final sender = context.senderPubkey ?? '';
    // `entriesForAlertDedup` covers the store's async hydration window too:
    // while the persisted history loads, `record()` calls are buffered (not in
    // `state.entries` yet), so scanning only the live entries let multi-relay
    // duplicates of one boot-time event double-popup.
    final history = _ref
        .read(notificationHistoryProvider.notifier)
        .entriesForAlertDedup;
    final isDupe = history.any((e) {
      if (eventId.isNotEmpty && e.eventId == eventId) return true;
      return e.title == title &&
          e.body == body &&
          (e.senderPubkey ?? '') == sender &&
          (e.ts - ts).abs() < 60000;
    });
    if (isDupe) return true;

    // Stable seen-key, byte-matching the history store's `_seenKey` (and the
    // PWA's `_notificationSeenKey`, notifications.js:238-248): event id when
    // known, else sender+minute+body-prefix (body clipped to 40 chars so the
    // key matches the 240-char-truncated synced copy).
    final prefix = body.length > 40 ? body.substring(0, 40) : body;
    final seenKey =
        eventId.isNotEmpty ? 'e:$eventId' : 'f:$sender:${ts ~/ 60000}:$prefix';
    final seen = _ref
        .read(notificationHistoryProvider.notifier)
        .seenNotificationsForSync();
    return seen.containsKey(seenKey);
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
