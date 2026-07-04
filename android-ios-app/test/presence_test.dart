import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/notifications/notifications_service.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
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

    test('avatar-update + bare shop-update flag appended (no inlined items)',
        () {
      // publishShopUpdate emits ONLY ['shop-update','1'] (nostr-core.js:
      // 2876-2885); item data never rides presence — receivers refetch the
      // D1 shop-status record instead.
      final tags = const PresencePayload(
        nym: 'satoshi',
        status: 'online',
        mode: PresenceStatusMode.enabled,
        avatarUrl: 'https://x/y.png',
        shopUpdate: true,
      ).tags();
      expect(tagOf(tags, 'avatar-update'), 'https://x/y.png');
      expect(tagOf(tags, 'shop-update'), '1');
      expect(tagOf(tags, 'shop-style'), isNull);
      expect(tagOf(tags, 'shop-flair'), isNull);
      expect(tagOf(tags, 'shop-supporter'), isNull);
    });

    test('presenceStatusModeFrom maps showStatus strings', () {
      expect(presenceStatusModeFrom('true'), PresenceStatusMode.enabled);
      expect(presenceStatusModeFrom('friends'), PresenceStatusMode.friends);
      expect(presenceStatusModeFrom('false'), PresenceStatusMode.disabled);
    });
  });

  group('setUserPresence (presence ingest)', () {
    test('sets status/away/avatar', () {
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
      );
      final u = notifier.state.users[other]!;
      expect(u.status, UserStatus.away);
      expect(u.awayMessage, 'brb lunch');
      expect(u.profile?.picture, 'https://x/y.png');
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

    test('presence ingest never touches shop cosmetic fields', () {
      // A shop-update presence is a cache-bust flag handled by the controller
      // (OtherUsersShopController.invalidate) — setUserPresence must neither
      // set nor clear the User cosmetic fields (users.js:1221-1223).
      final notifier = AppStateNotifier();
      notifier.state.users[other] =
          User(pubkey: other, nym: 'bob', shopStyle: 'style-satoshi');
      notifier.setUserPresence(
        pubkey: other,
        status: UserStatus.online,
      );
      expect(notifier.state.users[other]!.shopStyle, 'style-satoshi');
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

  // ---------------------------------------------------------------------------
  // W2-A: channel-membership root cause, presence-vs-activity, unread predicate,
  // notification-badge clear-on-read, and gibberish-nym filtering.
  // ---------------------------------------------------------------------------

  NostrEvent geoMsg(String sender, String geohash,
          {String content = 'gm', int createdAt = 2000}) =>
      NostrEvent(
        id: 'g_${sender}_${geohash}_$createdAt',
        pubkey: sender,
        createdAt: createdAt,
        kind: 20000,
        tags: [
          ['n', 'peer'],
          ['g', geohash],
        ],
        content: content,
      );

  NostrEvent namedMsg(String sender, String channel,
          {int createdAt = 2000}) =>
      NostrEvent(
        id: 'n_${sender}_${channel}_$createdAt',
        pubkey: sender,
        createdAt: createdAt,
        kind: 23333,
        tags: [
          ['n', 'peer'],
          ['d', channel],
        ],
        content: 'gm',
      );

  group('CC-1: user.channels membership (geohash root cause)', () {
    test('geohash channel records the BARE lowercase geohash (no #)', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.ingestEvent(geoMsg('peerpk', '9q8y'));
      final chans = n.state.users['peerpk']!.channels;
      // PWA channelKey = geohash || channel, lowercased (users.js:1262).
      expect(chans, contains('9q8y'));
      expect(chans, isNot(contains('#9q8y')));
    });

    test('uppercase geohash is lowercased to match view.id.toLowerCase()', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.ingestEvent(geoMsg('peerpk', '9Q8Y'));
      expect(n.state.users['peerpk']!.channels, contains('9q8y'));
    });

    test('named channel records the bare lowercased channel name', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.ingestEvent(namedMsg('peerpk', 'Bitcoin'));
      final chans = n.state.users['peerpk']!.channels;
      expect(chans, contains('bitcoin'));
      expect(chans, isNot(contains('#bitcoin')));
    });
  });

  group('C01-4: presence is not activity (lastSeen stamping)', () {
    test('stampLastSeen:false leaves lastSeen untouched (bare presence)', () {
      final n = AppStateNotifier();
      const ts = 1700000000000;
      n.setUserPresence(
        pubkey: other,
        status: UserStatus.online,
        lastSeenMs: ts,
        stampLastSeen: false,
      );
      final u = n.state.users[other]!;
      expect(u.status, UserStatus.online); // status still applied
      expect(u.lastSeen, 0); // never stamped → stale → resolves offline
      expect(u.effectiveStatus(nowMs: ts), UserStatus.offline);
    });

    test('default (stampLastSeen:true) stamps lastSeen (friend/own activity)',
        () {
      final n = AppStateNotifier();
      final now = DateTime.now().millisecondsSinceEpoch;
      n.setUserPresence(
          pubkey: other, status: UserStatus.online, lastSeenMs: now);
      expect(n.state.users[other]!.lastSeen, now);
      expect(n.state.users[other]!.effectiveStatus(nowMs: now),
          UserStatus.online);
    });
  });

  group('C02-5: unread predicate counts keyword/spam the PWA still counts', () {
    test('countsTowardUnread keeps a keyword-hidden message that '
        'isMessageFiltered drops', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.addBlockedKeyword('spamword');
      final m = Message(
        id: 'k1',
        author: 'peer#beef',
        pubkey: other,
        content: 'this has spamword in it',
        createdAt: 2000,
      );
      // List-visibility filter hides it (keyword on content)...
      expect(n.state.isMessageFiltered(m), isTrue);
      // ...but the unread badge still counts it (PWA _recomputeUnreadCount does
      // not exclude keyword/heuristic-spam — channels.js:1709-1728).
      expect(n.state.countsTowardUnread(m), isTrue);
    });

    test('countsTowardUnread excludes own / blocked / system rows', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.blockUser(other);
      final blocked = Message(
          id: 'b1',
          author: 'peer#beef',
          pubkey: other,
          content: 'hi',
          createdAt: 2000);
      final own = Message(
          id: 'o1',
          author: 'me#0001',
          pubkey: 'selfpk',
          content: 'hi',
          createdAt: 2000,
          isOwn: true);
      expect(n.state.countsTowardUnread(blocked), isFalse);
      expect(n.state.countsTowardUnread(own), isFalse);
    });
  });

  group('C02-4: notification badge clear-on-read + blocked filter', () {
    test('markConversationSeen flips matching-route entries and re-counts', () {
      final notifier = NotificationHistoryNotifier();
      notifier.record(
          type: 'pm', title: 'a', body: 'b', route: 'peerA', eventId: 'e1');
      notifier.record(
          type: 'pm', title: 'c', body: 'd', route: 'peerB', eventId: 'e2');
      expect(notifier.state.unread, 2);

      notifier.markConversationSeen('peerA');
      expect(notifier.state.unread, 1);
      expect(
          notifier.state.entries.firstWhere((e) => e.route == 'peerA').viewed,
          isTrue);
      expect(
          notifier.state.entries.firstWhere((e) => e.route == 'peerB').viewed,
          isFalse);
    });

    test('setBlocked drops a blocked sender from the badge count', () {
      final notifier = NotificationHistoryNotifier();
      notifier.record(
          type: 'pm',
          title: 'a',
          body: 'b',
          route: 'peerA',
          eventId: 'e1',
          senderPubkey: other);
      expect(notifier.state.unread, 1);
      notifier.setBlocked({other});
      expect(notifier.state.unread, 0);
    });
  });

  group('CC-13: gibberish nyms excluded from usersProvider (Nyms source)', () {
    test('a randomized spam-bot nym is filtered; a real nym is kept', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(appStateProvider.notifier)
        ..goLive('selfpk', 'me#0001');
      // Interior-caps gibberish handle. setUserPresence appends a #suffix
      // (getNymFromPubkey), so the stored nym is `aAbBcCdDeE#beef`; the provider
      // strips the suffix before the gibberish check (the PWA stores the bare
      // handle and checks it directly — nostr-core.js:943).
      notifier.setUserPresence(
          pubkey: other,
          status: UserStatus.online,
          nym: 'aAbBcCdDeE',
          lastSeenMs: 1);
      const human =
          '22222222222222222222222222222222222222222222222222222222cafebabe';
      notifier.setUserPresence(
          pubkey: human,
          status: UserStatus.online,
          nym: 'swift-fox',
          lastSeenMs: 1);

      final users = container.read(usersProvider);
      expect(users.containsKey(other), isFalse, reason: 'gibberish dropped');
      expect(users.containsKey(human), isTrue, reason: 'real nym kept');
    });

    test('self is never filtered even if its nym looks gibberish', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(appStateProvider.notifier)
        ..goLive(other, 'aAbBcCdDeE'); // self with a gibberish-looking nym
      notifier.setUserPresence(
          pubkey: other,
          status: UserStatus.online,
          nym: 'aAbBcCdDeE',
          lastSeenMs: 1);
      expect(container.read(usersProvider).containsKey(other), isTrue);
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

  // Regression for the bug where PMs/group messages never reached the bell:
  // the PWA RECORDS every qualifying message to history regardless of age (a
  // fresh one loudly, an old/gift-wrapped one silently) — so the record gate
  // must NOT include the historical condition that the alert gate has.
  group('shouldRecordNotification (history-record gate)', () {
    test('a historical PM is still recorded (unlike shouldNotify)', () {
      // The whole bug: gift-wrapped PM/group backlog always arrives "old", so
      // gating the record on historical dropped it from the bell entirely.
      expect(
        shouldRecordNotification(
          kind: NotifyKind.pm,
          isOwn: false,
          notificationsEnabled: true,
        ),
        isTrue,
      );
      // The alert gate, by contrast, suppresses a historical message.
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

    test('a historical group message is still recorded', () {
      expect(
        shouldRecordNotification(
          kind: NotifyKind.group,
          isOwn: false,
          notificationsEnabled: true,
        ),
        isTrue,
      );
    });

    test('record gate keeps the non-age gates (own/blocked/bot/active/friends)',
        () {
      expect(
        shouldRecordNotification(
            kind: NotifyKind.pm, isOwn: true, notificationsEnabled: true),
        isFalse,
      );
      expect(
        shouldRecordNotification(
            kind: NotifyKind.pm,
            isOwn: false,
            notificationsEnabled: true,
            isBlocked: true),
        isFalse,
      );
      expect(
        shouldRecordNotification(
            kind: NotifyKind.pm,
            isOwn: false,
            notificationsEnabled: true,
            isBot: true),
        isFalse,
      );
      expect(
        shouldRecordNotification(
            kind: NotifyKind.pm,
            isOwn: false,
            notificationsEnabled: true,
            isActiveView: true),
        isFalse,
      );
      expect(
        shouldRecordNotification(
            kind: NotifyKind.pm,
            isOwn: false,
            notificationsEnabled: true,
            friendsOnly: true,
            isFriend: false),
        isFalse,
      );
      expect(
        shouldRecordNotification(
            kind: NotifyKind.pm, isOwn: false, notificationsEnabled: false),
        isFalse,
      );
    });

    test('group mentions-only suppresses a non-mention; a mention records', () {
      expect(
        shouldRecordNotification(
            kind: NotifyKind.group,
            isOwn: false,
            notificationsEnabled: true,
            groupMentionsOnly: true,
            isMention: false),
        isFalse,
      );
      expect(
        shouldRecordNotification(
            kind: NotifyKind.group,
            isOwn: false,
            notificationsEnabled: true,
            groupMentionsOnly: true,
            isMention: true),
        isTrue,
      );
    });

    test('a channel source only records on an @-mention', () {
      expect(
        shouldRecordNotification(
            kind: NotifyKind.channel,
            isOwn: false,
            notificationsEnabled: true,
            isMention: false),
        isFalse,
      );
      expect(
        shouldRecordNotification(
            kind: NotifyKind.channel,
            isOwn: false,
            notificationsEnabled: true,
            isMention: true),
        isTrue,
      );
    });
  });

  // The notifications modal reads this store directly, so the PM/group entries
  // must land here with the right type/route/context to be rendered + routed.
  group('NotificationHistoryNotifier (the modal store)', () {
    test('records a PM and a group entry the modal can render + route', () {
      final n = NotificationHistoryNotifier();
      n.record(
        type: 'pm',
        title: 'alice',
        body: 'hi there',
        route: other,
        senderPubkey: other,
        eventId: 'pm-evt-1',
      );
      n.record(
        type: 'group',
        title: 'bob',
        body: 'gm all',
        route: 'group-123',
        senderPubkey: other,
        contextLabel: 'in My Group',
        eventId: 'grp-evt-1',
      );
      expect(n.state.entries.length, 2);
      expect(n.state.unread, 2);
      // Newest-first: the group message was recorded last.
      final group = n.state.entries.first;
      final pm = n.state.entries.last;
      expect(group.type, 'group');
      expect(group.route, 'group-123');
      expect(group.contextLabel, 'in My Group');
      expect(group.senderPubkey, other); // drives the avatar + decorated author
      expect(pm.type, 'pm');
      expect(pm.route, other);
    });

    test('dedupes a replayed copy by eventId', () {
      final n = NotificationHistoryNotifier();
      n.record(type: 'pm', title: 'a', body: 'x', eventId: 'evt-dup');
      n.record(type: 'pm', title: 'a', body: 'x', eventId: 'evt-dup');
      expect(n.state.entries.length, 1);
    });

    test('markAllViewed clears unread + flips every entry viewed', () {
      final n = NotificationHistoryNotifier();
      n.record(type: 'pm', title: 'a', body: 'x', eventId: 'e1');
      n.record(type: 'group', title: 'b', body: 'y', eventId: 'e2');
      expect(n.state.unread, 2);
      n.markAllViewed();
      expect(n.state.unread, 0);
      expect(n.state.entries.every((e) => e.viewed), isTrue);
    });

    test('trims entries older than 24h on record', () {
      final n = NotificationHistoryNotifier();
      final old = DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch;
      n.record(type: 'pm', title: 'old', body: 'stale', ts: old, eventId: 'o1');
      // The stale entry is outside the 24h window; recording a fresh one drops
      // it (matching the PWA's 24h cutoff).
      n.record(type: 'pm', title: 'new', body: 'fresh', eventId: 'n1');
      expect(n.state.entries.length, 1);
      expect(n.state.entries.first.title, 'new');
    });
  });

  // N26 — cross-device notification read-state (the seen-keys wrap). A
  // notification read/dismissed on one device must not re-alert on another.
  group('NotificationHistoryNotifier cross-device seen-keys (N26)', () {
    test('mergeSeenNotifications retro-marks a matching entry viewed', () {
      final n = NotificationHistoryNotifier();
      n.record(
          type: 'pm',
          title: 'a',
          body: 'x',
          eventId: 'evt-seen',
          senderPubkey: other);
      expect(n.state.unread, 1);
      // A sibling device reports it read: merging its seen-key clears the badge.
      final changed = n.mergeSeenNotifications(
          {'e:evt-seen': DateTime.now().millisecondsSinceEpoch});
      expect(changed, isTrue);
      expect(n.state.entries.single.viewed, isTrue);
      expect(n.state.unread, 0);
    });

    test('a notification already seen elsewhere lands pre-viewed (no badge bump)',
        () {
      final n = NotificationHistoryNotifier();
      // The seen-key syncs in BEFORE the event itself replays here.
      n.mergeSeenNotifications(
          {'e:evt-future': DateTime.now().millisecondsSinceEpoch});
      n.record(
          type: 'pm',
          title: 'a',
          body: 'x',
          eventId: 'evt-future',
          senderPubkey: other);
      expect(n.state.entries.single.viewed, isTrue);
      expect(n.state.unread, 0);
    });

    test('viewing here exports seen-keys that silence the same event elsewhere',
        () {
      final deviceA = NotificationHistoryNotifier();
      deviceA.record(
          type: 'pm',
          title: 'a',
          body: 'x',
          eventId: 'evt-rt',
          senderPubkey: other);
      deviceA.markAllViewed();
      final synced = deviceA.seenNotificationsForSync();
      expect(synced.containsKey('e:evt-rt'), isTrue);

      // Device B merges the synced keys, then the same event replays there.
      final deviceB = NotificationHistoryNotifier();
      deviceB.mergeSeenNotifications(synced);
      deviceB.record(
          type: 'pm',
          title: 'a',
          body: 'x',
          eventId: 'evt-rt',
          senderPubkey: other);
      expect(deviceB.state.entries.single.viewed, isTrue);
      expect(deviceB.state.unread, 0);
    });

    test('an expired incoming seen-key is ignored (48h TTL)', () {
      final n = NotificationHistoryNotifier();
      n.record(
          type: 'pm',
          title: 'a',
          body: 'x',
          eventId: 'evt-old',
          senderPubkey: other);
      final old = DateTime.now()
          .subtract(const Duration(hours: 49))
          .millisecondsSinceEpoch;
      final changed = n.mergeSeenNotifications({'e:evt-old': old});
      expect(changed, isFalse); // expired → not adopted
      expect(n.state.entries.single.viewed, isFalse);
      expect(n.state.unread, 1);
    });

    test('fallback seen-key (no eventId) uses sender+minute+body prefix', () {
      final n = NotificationHistoryNotifier();
      n.record(
          type: 'pm', title: 'a', body: 'hello world', senderPubkey: other);
      n.markAllViewed();
      final synced = n.seenNotificationsForSync();
      expect(synced.keys.any((k) => k.startsWith('f:$other:')), isTrue);
    });
  });
}
