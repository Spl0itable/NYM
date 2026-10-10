// Synthesized notification tones and local notifications with the PWA's gating; wiring into the pipeline is the caller's job.

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/notification_service.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../chat_lock/chat_lock_providers.dart';
import '../dm_polls/dm_polls.dart' show DmPolls, dmPollPreview;
import '../group_tools/group_tools.dart' show GroupTools;
import '../i18n/i18n.dart';
import '../messages/format/nym_format.dart' show NymFormat;
import '../toasts/event_toasts.dart';
import 'notification_sounds.dart';
import 'notify_view.dart';

/// Plays a rendered WAV tone; tests inject a no-op so no plugin is touched.
abstract class TonePlayer {
  /// Plays the WAV bytes for tone [name]; must never throw.
  Future<void> play(String name, Uint8List wav);
}

/// Default [TonePlayer] feeding synthesized WAV bytes to `audioplayers`, created lazily.
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
      // Restart each time so rapid notifications retrigger the tone.
      await player.stop();
      await player.play(BytesSource(wav, mimeType: 'audio/wav'));
    } catch (_) {
      // Best-effort; never throw from a sound.
    }
  }
}

/// Per-notification context for the friends-only and mentions-only gates.
class NotifyContext {
  const NotifyContext({
    this.senderPubkey,
    this.isGroup = false,
    this.isMention = false,
    this.isFriend = false,
    this.isBot = false,
    this.isBlocked = false,
    this.isThreadReply = false,
    this.payload,
    this.eventId,
    this.timestampMs,
    this.conversationKey,
    this.kind = NotificationKind.message,
    this.presentWhileOpen = true,
    this.preview,
  });

  final String? senderPubkey;
  final bool isGroup;

  /// True when the inbound group message @-mentions us.
  final bool isMention;
  final bool isFriend;
  final bool isBot;
  final bool isBlocked;

  /// Thread replies are judged by `threadNotifyMentionsOnly`; see [shouldRecordNotification].
  final bool isThreadReply;

  /// Opaque payload forwarded to [NotificationService].
  final String? payload;

  /// Source event id, keying alert dedup against history and the persisted `e:<id>` seen key.
  final String? eventId;

  /// Event `created_at` in ms, for the backlog age gate and fallback dedup; null or zero means now.
  final int? timestampMs;

  /// Conversation key, so notifications replace rather than stack and clear when read.
  final String? conversationKey;

  /// Which Android channel and alert weight to post under.
  final NotificationKind kind;

  final bool presentWhileOpen;

  final EventToastEvent? preview;
}

String systemNotificationBody({
  required String body,
  required bool locked,
  required bool hidePreviews,
  NotifyContext context = const NotifyContext(),
}) {
  final base = context.preview ??
      EventToastEvent(
        kind: context.isGroup ? 'group' : 'pm',
        mention: context.isMention,
        thread: context.isThreadReply,
      );
  return EventToasts.systemBody(
    base.copyWith(body: locked ? '' : body, locked: locked || base.locked),
    EventToastPrefs(hidePreviews: hidePreviews),
    (s, [p]) => EventToasts.fill(tr(s), p),
  );
}

String systemNotificationTitle({
  required String title,
  required bool locked,
  required bool hidePreviews,
  NotifyContext context = const NotifyContext(),
}) =>
    EventToasts.systemTitle(
      title,
      EventToastPrefs(hidePreviews: hidePreviews),
      topic: EventToasts.topicOf(context.eventId),
      locked: locked,
      tr: (s, [p]) => EventToasts.fill(tr(s), p),
    );

/// Notification text with quoted lines dropped, so the reply is shown; a quote-only message keeps its content.
String notificationBodyFor(String content) {
  final text =
      content.contains(DmPolls.prefix) ? dmPollPreview(content, tr) : content;
  final pv = GroupTools.previewText(text);
  if (pv == 'Location' || pv == 'Live location') return tr(pv);
  final body = pv
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('>'))
      .join('\n')
      .trim();
  return body.isEmpty ? content.trim() : body;
}

/// Conversation surface of an inbound message, for gating.
enum NotifyKind { channel, pm, group }

/// Whether to record into bell history: [shouldNotify] without the historical gate.
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
  bool isThreadReply = false,
  bool isOwnThreadRoot = false,
  bool isOwnThreadReply = false,
  bool threadMentionsOnly = false,
}) {
  if (!notificationsEnabled) return false;
  if (isOwn) return false;
  if (isBlocked) return false;
  if (isBot) return false;
  if (isActiveView) return false;
  if (friendsOnly && !isFriend) return false;

  return NotifyView.addressed(
    kind: switch (kind) {
      NotifyKind.channel => 'channel',
      NotifyKind.group => 'group',
      NotifyKind.pm => 'pm',
    },
    thread: isThreadReply,
    mention: isMention,
    ownRoot: isOwnThreadRoot,
    ownReply: isOwnThreadReply,
    threadMentionsOnly: threadMentionsOnly,
    groupMentionsOnly: groupMentionsOnly,
  );
}

/// Whether to raise a loud alert: [shouldRecordNotification] and not [isHistorical]; pure and IO-free.
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
  bool isThreadReply = false,
  bool isOwnThreadRoot = false,
  bool isOwnThreadReply = false,
  bool threadMentionsOnly = false,
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
    isThreadReply: isThreadReply,
    isOwnThreadRoot: isOwnThreadRoot,
    isOwnThreadReply: isOwnThreadReply,
    threadMentionsOnly: threadMentionsOnly,
  );
}

class NotificationsService {
  NotificationsService(
    this._ref, {
    NotificationService? local,
    this._player,
  })  : _local = local ?? NotificationService();

  final Ref _ref;
  final NotificationService _local;

  /// Created on the first audible sound; tests inject a no-op.
  TonePlayer? _player;

  /// Rendered WAV bytes per sound key; synthesis is deterministic.
  final Map<String, Uint8List> _wavCache = {};

  /// Don't replay the same tone within 2s.
  int _lastSoundPlayedAt = 0;

  /// Resets the 2s replay guard so rapid settings previews always sound.
  void resetSoundDedupe() => _lastSoundPlayedAt = 0;

  /// Plays the tone for a `settings.sound` value; silent for `'none'` or unknown; 2s replay guard.
  Future<void> playSound(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastSoundPlayedAt != 0 && now - _lastSoundPlayedAt < 2000) return;

    final descriptor = resolveSound(name);
    if (descriptor == null) return; // Silent / unknown.
    _lastSoundPlayedAt = now;

    final wav = _wavCache.putIfAbsent(name, () => renderSoundWav(descriptor));
    await _playWav(name, wav);
  }

  /// WAV bytes for [name] without playing, or null if silent.
  Uint8List? renderTone(String name) {
    final descriptor = resolveSound(name);
    if (descriptor == null) return null;
    return _wavCache.putIfAbsent(name, () => renderSoundWav(descriptor));
  }

  /// Events older than 24h never raise a loud alert, however they arrived.
  static const int _maxAlertAgeMs = 24 * 60 * 60 * 1000;

  /// Shows a local notification and plays the sound, after the settings gates and replay guards (age, history dupes, seen-map).
  Future<void> notify({
    required String title,
    required String body,
    NotifyContext context = const NotifyContext(),
    bool notifyFriendsOnly = false,
    bool groupNotifyMentionsOnly = false,
    bool threadNotifyMentionsOnly = false,
  }) async {
    final settings = _ref.read(settingsProvider);
    if (!settings.notificationsEnabled) return;
    if (context.isBlocked) return;
    // Digest bodies never alert.
    if (body.contains('10 recent messages:')) return;
    if (context.isBot) return;
    // Friends-only: skip non-friends.
    if (notifyFriendsOnly &&
        context.senderPubkey != null &&
        !context.isFriend) {
      return;
    }
    // Threads use `threadNotifyMentionsOnly` instead of the flat mentions-only setting.
    if (context.isThreadReply) {
      if (threadNotifyMentionsOnly && !context.isMention) return;
    } else if (context.isGroup &&
        groupNotifyMentionsOnly &&
        !context.isMention) {
      // Group mentions-only: only mentions notify.
      return;
    }
    var shownTitle = title;
    var shownBody = body;
    var redacted = false;
    final ck = context.conversationKey ?? '';
    final sep = ck.indexOf(':');
    if (sep > 0) {
      try {
        final lock = _ref.read(chatLockProvider);
        if (lock.notificationIsLocked(
            ck.substring(0, sep), ck.substring(sep + 1), context.senderPubkey)) {
          final r = lock.redact(title, body, true);
          shownTitle = r.title;
          shownBody = r.body;
          redacted = true;
        }
      } catch (_) {}
    }
    if (_isReplayedOrSeen(
        title: shownTitle,
        body: shownBody,
        context: context,
        exactOnly: redacted)) {
      return;
    }

    // Post the OS notification first and don't await the tone, which may never start in the background.
    await _local.showNotification(
      title: systemNotificationTitle(
        title: shownTitle,
        locked: redacted,
        hidePreviews: settings.hidePreviews,
        context: context,
      ),
      body: systemNotificationBody(
        body: NymFormat.stripForPreview(shownBody),
        locked: redacted,
        hidePreviews: settings.hidePreviews,
        context: context,
      ),
      payload: context.payload,
      conversationKey: context.conversationKey,
      kind: context.kind,
      presentWhileOpen: context.presentWhileOpen,
    );
    if (soundIsAudible(settings.sound)) {
      unawaited(playSound(settings.sound));
    }
  }

  bool alreadyAlerted({
    required String title,
    required String body,
    required NotifyContext context,
    bool exactOnly = false,
  }) =>
      _isReplayedOrSeen(
          title: title, body: body, context: context, exactOnly: exactOnly);

  /// True when the event must not alert: older than 24h, already in bell history, or in the seen-map.
  bool _isReplayedOrSeen({
    required String title,
    required String body,
    required NotifyContext context,
    bool exactOnly = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rawTs = context.timestampMs ?? 0;
    final ts = rawTs > 0 ? rawTs : now;
    if (now - ts > _maxAlertAgeMs) return true;

    final eventId = context.eventId ?? '';
    final sender = context.senderPubkey ?? '';
    // Also covers records buffered during history hydration, avoiding double popups at boot.
    final history =
        _ref.read(notificationHistoryProvider.notifier).entriesForAlertDedup;
    final probe = NotifyAlertKey(
      eventId: eventId,
      title: title,
      body: body,
      sender: sender,
      ts: ts,
      exact: exactOnly,
    );
    final isDupe = history.any((e) => NotifyView.sameAlert(
        probe,
        NotifyAlertKey(
          eventId: e.eventId ?? '',
          title: e.title,
          body: e.body,
          sender: e.senderPubkey ?? '',
          ts: e.ts,
        )));
    if (isDupe) return true;

    // Seen key matching the history store: event id, else sender+minute+40-char body prefix.
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
    // Create the real player on the first audible tone.
    final player = _player ??= AudioPlayersTonePlayer();
    await player.play(name, wav);
  }
}

final notificationsServiceProvider = Provider<NotificationsService>((ref) {
  return NotificationsService(ref);
});
