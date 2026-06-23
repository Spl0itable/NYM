import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/features/zaps/lnurl.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/widgets/chat/message_row.dart';
import 'package:nym_bar/widgets/context_menu/context_menu_actions.dart';
import 'package:nym_bar/widgets/context_menu/interaction_hooks.dart';

/// Minimal channel message used across tests.
Message _channelMsg({
  String id = 'm1',
  String pubkey = 'pkOther',
  bool isOwn = false,
  int eventKind = 20000,
  String? geohash = 'u4pruyd',
  String? channel,
  bool isPM = false,
  bool isGroup = false,
  String? groupId,
}) {
  return Message(
    id: id,
    author: 'alice#abcd',
    pubkey: pubkey,
    content: 'hello world',
    createdAt: 1000,
    isOwn: isOwn,
    eventKind: eventKind,
    geohash: geohash,
    channel: channel,
    isPM: isPM,
    isGroup: isGroup,
    groupId: groupId,
  );
}

/// A fake controller that records toggleReaction calls instead of touching the
/// network. It extends the real controller so the provider type matches.
class _FakeController extends NostrController {
  _FakeController(super.ref);

  final List<({String messageId, String emoji, String target, String kind})>
      calls = [];

  @override
  Future<bool> toggleReaction(
    String messageId,
    String emoji, {
    required String target,
    required String kind,
  }) async {
    calls.add((messageId: messageId, emoji: emoji, target: target, kind: kind));
    return true;
  }
}

void main() {
  group('inferOriginalKind', () {
    test('geohash channel → 20000', () {
      final m = _channelMsg(eventKind: 20000, geohash: 'u4pruyd');
      expect(
        inferOriginalKind(m, view: const ChatView.channel('u4pruyd')),
        '20000',
      );
    });

    test('named (non-geohash) channel → 23333', () {
      final m = _channelMsg(eventKind: 23333, geohash: null, channel: 'nymchat');
      expect(
        inferOriginalKind(m, view: const ChatView.channel('nymchat')),
        '23333',
      );
    });

    test('PM message → 1059', () {
      final m = _channelMsg(eventKind: 1059, isPM: true, geohash: null);
      expect(inferOriginalKind(m, view: const ChatView.pm('peer')), '1059');
    });

    test('group message → 1059', () {
      final m = _channelMsg(
        eventKind: 14,
        isGroup: true,
        groupId: 'g1',
        geohash: null,
      );
      expect(inferOriginalKind(m, view: const ChatView.group('g1')), '1059');
    });

    test('falls back to view when message kind is unset (geohash id)', () {
      final m = _channelMsg(eventKind: 0, geohash: null, channel: null);
      expect(
        inferOriginalKind(m, view: const ChatView.channel('u4pruyd')),
        '20000',
      );
    });

    test('falls back to view when message kind is unset (named id)', () {
      final m = _channelMsg(eventKind: 0, geohash: null, channel: null);
      expect(
        inferOriginalKind(m, view: const ChatView.channel('general!')),
        '23333',
      );
    });
  });

  group('buildContextMenuActions', () {
    CtxTarget target({required bool isSelf}) => CtxTarget(
          pubkey: 'pk',
          nym: 'alice',
          isSelf: isSelf,
          content: 'hello world',
          messageId: 'm1',
        );

    test('own message includes Edit + EditProfile + Mention, excludes PM/Zap/'
        'Report/Block/Slap/Hug', () {
      final actions = buildContextMenuActions(target(isSelf: true));
      expect(actions, contains(CtxAction.edit));
      // Edit Profile only appears on own messages (ui-context.js:587-589).
      expect(actions, contains(CtxAction.editProfile));
      // Mention is NOT self-gated in the PWA — it shows on your own messages
      // (only hidden in profileOnly mode, ui-context.js:640-642).
      expect(actions, contains(CtxAction.mention));
      expect(actions, isNot(contains(CtxAction.privateMessage)));
      expect(actions, isNot(contains(CtxAction.zap)));
      expect(actions, isNot(contains(CtxAction.report)));
      expect(actions, isNot(contains(CtxAction.block)));
      expect(actions, isNot(contains(CtxAction.slap)));
      expect(actions, isNot(contains(CtxAction.hug)));
    });

    test(
        'other message excludes Edit, includes Mention/PM/Slap/Hug/Zap/Report/'
        'Block', () {
      final actions = buildContextMenuActions(target(isSelf: false));
      expect(actions, isNot(contains(CtxAction.edit)));
      expect(actions, contains(CtxAction.mention));
      expect(actions, contains(CtxAction.privateMessage));
      expect(actions, contains(CtxAction.slap));
      expect(actions, contains(CtxAction.hug));
      expect(actions, contains(CtxAction.zap));
      expect(actions, contains(CtxAction.report));
      expect(actions, contains(CtxAction.block));
      // Content-bearing actions present.
      expect(actions, contains(CtxAction.quote));
      expect(actions, contains(CtxAction.copyMessage));
      expect(actions, contains(CtxAction.translate));
    });

    test('runtime action order matches the PWA DOM (Slap/Hug after PM)', () {
      final actions = buildContextMenuActions(target(isSelf: false));
      // The non-group, content-bearing, other-user menu, in DOM order.
      expect(actions, [
        CtxAction.react,
        CtxAction.mention,
        CtxAction.privateMessage,
        CtxAction.slap,
        CtxAction.hug,
        CtxAction.addToGroup,
        CtxAction.zap,
        CtxAction.giftCredits,
        CtxAction.quote,
        CtxAction.copyMessage,
        CtxAction.translate,
        CtxAction.friend,
        CtxAction.report,
        CtxAction.block,
      ]);
    });

    test('profile-only mode shows PM / AddToGroup / GiftCredits / Friend / '
        'Report / Block', () {
      // ui-context.js:640-654 hides Mention/Translate/Slap/Hug/mod/Edit; with no
      // messageId/content the message-scoped items fall away, leaving these.
      final actions = buildContextMenuActions(const CtxTarget(
        pubkey: 'pk',
        nym: 'alice',
        isSelf: false,
        profileOnly: true,
      ));
      expect(actions, [
        CtxAction.privateMessage,
        CtxAction.addToGroup,
        CtxAction.giftCredits,
        CtxAction.friend,
        CtxAction.report,
        CtxAction.block,
      ]);
    });

    test('friend / block labels toggle', () {
      final t = const CtxTarget(
        pubkey: 'pk',
        nym: 'alice',
        isSelf: false,
        isFriend: true,
        isBlocked: true,
      );
      expect(ctxActionLabel(CtxAction.friend, t), 'Remove Friend');
      expect(ctxActionLabel(CtxAction.block, t), 'Unblock User');
    });
  });

  group('LNURL callback URL builder', () {
    const params = LnurlPayParams(
      callback: 'https://pay.example.com/lnurl/cb?id=42',
      minSendable: 1000,
      maxSendable: 100000000,
      commentAllowed: 120,
      allowsNostr: true,
      nostrPubkey: 'providerPubkeyHex',
    );

    test('amount is in millisats; comment + nostr params attached', () {
      final zapReq = NostrEvent(
        id: 'zr1',
        pubkey: 'me',
        createdAt: 1,
        kind: 9734,
        tags: const [
          ['p', 'recipient'],
          ['amount', '21000'],
        ],
        content: 'gm',
        sig: 'sig',
      );
      final url = Lnurl.buildCallbackUrl(
        params: params,
        amountSats: 21,
        comment: 'gm',
        zapRequest: zapReq,
      );
      // 21 sats → 21000 millisats.
      expect(url.queryParameters['amount'], '21000');
      expect(url.queryParameters['comment'], 'gm');
      // The existing callback query param is preserved.
      expect(url.queryParameters['id'], '42');
      // nostr param round-trips to the zap request JSON.
      expect(url.queryParameters['nostr'], contains('"kind":9734'));
      expect(url.queryParameters['nostr'], contains('"content":"gm"'));
    });

    test('comment clamped to commentAllowed length', () {
      const shortParams = LnurlPayParams(
        callback: 'https://pay.example.com/cb',
        minSendable: 1000,
        maxSendable: 100000000,
        commentAllowed: 5,
      );
      final url = Lnurl.buildCallbackUrl(
        params: shortParams,
        amountSats: 100,
        comment: 'abcdefghij',
      );
      expect(url.queryParameters['comment'], 'abcde');
      // No nostr param when the provider does not allow it.
      expect(url.queryParameters.containsKey('nostr'), isFalse);
      expect(url.queryParameters['amount'], '100000');
    });

    test('lnurlpUrl splits a lightning address', () {
      final u = Lnurl.lnurlpUrl('sats@walletofsatoshi.com');
      expect(u.toString(),
          'https://walletofsatoshi.com/.well-known/lnurlp/sats');
      expect(Lnurl.lnurlpUrl('invalid'), isNull);
    });
  });

  testWidgets('tapping a reaction badge invokes toggleReaction', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();

    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

    final message = _channelMsg();
    const reactions = [
      MessageReaction(emoji: '🔥', count: 2, userReacted: false),
    ];

    final container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        nostrControllerProvider.overrideWith((ref) => _FakeController(ref)),
      ],
    );
    addTearDown(container.dispose);
    final fake = container.read(nostrControllerProvider) as _FakeController;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          home: Scaffold(
            // IRC layout avoids the bubble overflow on the small test surface.
            body: MessageRow(
              message: message,
              settings: const Settings(chatLayout: 'irc'),
              reactions: reactions,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Tap the badge ("🔥 2").
    expect(find.text('🔥 2'), findsOneWidget);
    await tester.tap(find.text('🔥 2'), warnIfMissed: false);
    await tester.pump();
    // Flush the reaction-burst overlay timer (Future.delayed ~900ms).
    await tester.pump(const Duration(milliseconds: 1000));

    expect(fake.calls, hasLength(1));
    expect(fake.calls.single.messageId, message.id);
    expect(fake.calls.single.emoji, '🔥');
    expect(fake.calls.single.target, message.pubkey);
    // geohash channel → originalKind 20000.
    expect(fake.calls.single.kind, '20000');
  });

  test('mention/quote hook mailbox round-trips', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final hooks = container.read(pendingComposerActionProvider.notifier);

    hooks.requestMention('alice#abcd');
    final a = container.read(pendingComposerActionProvider);
    expect(a, isA<MentionAction>());
    expect((a as MentionAction).fullNym, 'alice#abcd');

    hooks.requestQuote(fullNym: 'bob#1234', content: 'hi');
    final q = container.read(pendingComposerActionProvider);
    expect(q, isA<QuoteAction>());
    expect((q as QuoteAction).content, 'hi');

    hooks.consume();
    expect(container.read(pendingComposerActionProvider), isNull);
  });
}
