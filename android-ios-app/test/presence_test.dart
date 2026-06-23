import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/notifications/notifications_service.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/services/nostr/nostr_service.dart';
import 'package:nym_bar/state/app_state.dart';

void main() {
  const other =
      '11111111111111111111111111111111111111111111111111111111deadbeef';

  // Helper: pull a single-valued presence tag out of the built tag list.
  String? tagOf(List<List<String>> tags, String name) {
    for (final t in tags) {
      if (t.isNotEmpty && t[0] == name) return t.length > 1 ? t[1] : '';
    }
    return null;
  }

  group('PresencePayload.tags (presence tag builder)', () {
    test('online (enabled) emits d/t/n/status, no away', () {
      final tags = const PresencePayload(
        nym: 'satoshi',
        status: 'online',
        mode: PresenceStatusMode.enabled,
      ).tags();
      expect(tagOf(tags, 'd'), 'nym-presence');
      expect(tagOf(tags, 't'), 'nym-presence');
      expect(tagOf(tags, 'n'), 'satoshi');
      expect(tagOf(tags, 'status'), 'online');
      expect(tagOf(tags, 'away'), isNull);
    });

    test('away (enabled) emits status=away + away message', () {
      final tags = const PresencePayload(
        nym: 'satoshi',
        status: 'away',
        awayMessage: 'brb lunch',
        mode: PresenceStatusMode.enabled,
      ).tags();
      expect(tagOf(tags, 'status'), 'away');
      expect(tagOf(tags, 'away'), 'brb lunch');
    });

    test('hidden mode broadcasts status=hidden and drops away', () {
      // Disabled/friends mode → public status is forced to hidden, no away tag.
      final disabled = const PresencePayload(
        nym: 'satoshi',
        status: 'away',
        awayMessage: 'brb',
        mode: PresenceStatusMode.disabled,
      ).tags();
      expect(tagOf(disabled, 'status'), 'hidden');
      expect(tagOf(disabled, 'away'), isNull);

      final friends = const PresencePayload(
        nym: 'satoshi',
        status: 'online',
        mode: PresenceStatusMode.friends,
      ).tags();
      expect(tagOf(friends, 'status'), 'hidden');
    });

    test('avatar-update + shop-update tags appended with cosmetics', () {
      final tags = const PresencePayload(
        nym: 'satoshi',
        status: 'online',
        mode: PresenceStatusMode.enabled,
        avatarUrl: 'https://x/y.png',
        shopUpdate: true,
        cosmetics: PresenceCosmetics(
          style: 'style-satoshi',
          flair: 'flair-crown',
          supporter: true,
        ),
      ).tags();
      expect(tagOf(tags, 'avatar-update'), 'https://x/y.png');
      expect(tagOf(tags, 'shop-update'), '1');
      expect(tagOf(tags, 'shop-style'), 'style-satoshi');
      expect(tagOf(tags, 'shop-flair'), 'flair-crown');
      expect(tagOf(tags, 'shop-supporter'), '1');
    });

    test('presenceStatusModeFrom maps showStatus strings', () {
      expect(presenceStatusModeFrom('true'), PresenceStatusMode.enabled);
      expect(presenceStatusModeFrom('friends'), PresenceStatusMode.friends);
      expect(presenceStatusModeFrom('false'), PresenceStatusMode.disabled);
    });
  });

  group('setUserPresence (presence ingest)', () {
    test('sets status/away/avatar/shopStyle/shopFlair/isSupporter', () {
      final notifier = AppStateNotifier();
      const ts = 1700000000;
      notifier.setUserPresence(
        pubkey: other,
        status: UserStatus.away,
        nym: 'satoshi',
        awayMessage: 'brb lunch',
        lastSeenMs: ts * 1000,
        avatarUrl: 'https://x/y.png',
        hasAvatarTag: true,
        shopUpdate: true,
        shopStyle: 'style-satoshi',
        shopFlair: 'flair-crown',
        isSupporter: true,
      );
      final u = notifier.state.users[other]!;
      expect(u.status, UserStatus.away);
      expect(u.awayMessage, 'brb lunch');
      expect(u.profile?.picture, 'https://x/y.png');
      expect(u.shopStyle, 'style-satoshi');
      expect(u.shopFlair, 'flair-crown');
      expect(u.isSupporter, isTrue);
      expect(u.nym, 'satoshi#beef'); // suffix appended from pubkey
    });

    test('avatar tag with empty url clears the avatar', () {
      final notifier = AppStateNotifier();
      notifier.setUserPresence(
        pubkey: other,
        status: UserStatus.online,
        avatarUrl: 'https://x/y.png',
        hasAvatarTag: true,
      );
      expect(notifier.state.users[other]!.profile?.picture, 'https://x/y.png');
      notifier.setUserPresence(
        pubkey: other,
        status: UserStatus.online,
        avatarUrl: '',
        hasAvatarTag: true,
      );
      expect(notifier.state.users[other]!.profile?.picture, isNull);
    });

    test('shop-update without inlined tags clears cosmetics', () {
      final notifier = AppStateNotifier();
      notifier.setUserPresence(
        pubkey: other,
        status: UserStatus.online,
        shopUpdate: true,
        shopStyle: 'style-satoshi',
        shopFlair: 'flair-crown',
        isSupporter: true,
      );
      expect(notifier.state.users[other]!.shopStyle, 'style-satoshi');
      notifier.setUserPresence(
        pubkey: other,
        status: UserStatus.online,
        shopUpdate: true,
      );
      final u = notifier.state.users[other]!;
      expect(u.shopStyle, isNull);
      expect(u.shopFlair, isNull);
      expect(u.isSupporter, isFalse);
    });

    test('effectiveStatus honors getEffectiveUserStatus semantics', () {
      final notifier = AppStateNotifier();
      final now = DateTime.now().millisecondsSinceEpoch;
      // hidden → hidden regardless of recency.
      notifier.setUserPresence(
          pubkey: other, status: UserStatus.hidden, lastSeenMs: now);
      expect(notifier.state.users[other]!.effectiveStatus(nowMs: now),
          UserStatus.hidden);
      // away message → away.
      notifier.setUserPresence(
          pubkey: other,
          status: UserStatus.away,
          awayMessage: 'brb',
          lastSeenMs: now);
      expect(notifier.state.users[other]!.effectiveStatus(nowMs: now),
          UserStatus.away);
      // recent online → online; stale → offline.
      notifier.setUserPresence(
          pubkey: other, status: UserStatus.online, lastSeenMs: now);
      expect(notifier.state.users[other]!.effectiveStatus(nowMs: now),
          UserStatus.online);
      expect(
          notifier.state.users[other]!
              .effectiveStatus(nowMs: now + kActiveThresholdMs + 1),
          UserStatus.offline);
    });
  });

  group('shouldNotify (notification gate)', () {
    test('own message → false', () {
      expect(
        shouldNotify(
          kind: NotifyKind.pm,
          isOwn: true,
          isHistorical: false,
          notificationsEnabled: true,
        ),
        isFalse,
      );
    });

    test('historical message → false', () {
      expect(
        shouldNotify(
          kind: NotifyKind.pm,
          isOwn: false,
          isHistorical: true,
          notificationsEnabled: true,
        ),
        isFalse,
      );
    });

    test('PM from other (enabled) → true', () {
      expect(
        shouldNotify(
          kind: NotifyKind.pm,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
        ),
        isTrue,
      );
    });

    test('group non-mention with mentions-only → false', () {
      expect(
        shouldNotify(
          kind: NotifyKind.group,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
          isMention: false,
          groupMentionsOnly: true,
        ),
        isFalse,
      );
    });

    test('group mention with mentions-only → true', () {
      expect(
        shouldNotify(
          kind: NotifyKind.group,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
          isMention: true,
          groupMentionsOnly: true,
        ),
        isTrue,
      );
    });

    test('channel mention → true; channel non-mention → false', () {
      expect(
        shouldNotify(
          kind: NotifyKind.channel,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
          isMention: true,
        ),
        isTrue,
      );
      expect(
        shouldNotify(
          kind: NotifyKind.channel,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
          isMention: false,
        ),
        isFalse,
      );
    });

    test('friends-only + non-friend → false', () {
      expect(
        shouldNotify(
          kind: NotifyKind.pm,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
          friendsOnly: true,
          isFriend: false,
        ),
        isFalse,
      );
      // friends-only + friend → true.
      expect(
        shouldNotify(
          kind: NotifyKind.pm,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
          friendsOnly: true,
          isFriend: true,
        ),
        isTrue,
      );
    });

    test('notifications disabled → false', () {
      expect(
        shouldNotify(
          kind: NotifyKind.pm,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: false,
        ),
        isFalse,
      );
    });

    test('actively-viewed conversation → false', () {
      expect(
        shouldNotify(
          kind: NotifyKind.pm,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
          isActiveView: true,
        ),
        isFalse,
      );
    });

    test('blocked sender / bot → false', () {
      expect(
        shouldNotify(
          kind: NotifyKind.channel,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
          isMention: true,
          isBlocked: true,
        ),
        isFalse,
      );
      expect(
        shouldNotify(
          kind: NotifyKind.pm,
          isOwn: false,
          isHistorical: false,
          notificationsEnabled: true,
          isBot: true,
        ),
        isFalse,
      );
    });
  });
}
