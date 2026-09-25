import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/widgets/common/nym_avatar.dart';

void main() {
  const self = '0000000000000000000000000000000000000000000000000000000000000001';
  const other =
      'abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabca0';

  NostrEvent kind0(String pubkey, Map<String, dynamic> profile) => NostrEvent(
        id: 'k0-$pubkey',
        pubkey: pubkey,
        createdAt: 1700000000,
        kind: 0,
        content: jsonEncode(profile),
      );

  test('the seeded Nymbot carries the bundled avatar and banner', () {
    final n = AppStateNotifier()..goLive(self, 'me#0001');
    final bot = n.state.users[kNymbotPubkey]!;
    expect(bot.profile?.picture, kNymbotAvatarAsset);
    expect(bot.profile?.banner, kNymbotBannerAsset);
  });

  test('a Nymbot kind-0 keeps the bundled media, other users keep theirs', () {
    final n = AppStateNotifier()..goLive(self, 'me#0001');
    n.ingestEvent(kind0(kNymbotPubkey, {
      'name': 'Nymbot',
      'about': 'the bot',
      'picture': 'https://nymchat.app/images/nymbot-icon.png',
      'banner': 'https://nymchat.app/images/NYM-banner.png',
    }));
    final bot = n.state.users[kNymbotPubkey]!;
    expect(bot.profile?.about, 'the bot');
    expect(bot.profile?.picture, kNymbotAvatarAsset);
    expect(bot.profile?.banner, kNymbotBannerAsset);

    n.ingestEvent(kind0(other, {
      'name': 'bob',
      'picture': 'https://cdn.example/bob.png',
      'banner': 'https://cdn.example/bob-banner.png',
    }));
    final bob = n.state.users[other]!;
    expect(bob.profile?.picture, 'https://cdn.example/bob.png');
    expect(bob.profile?.banner, 'https://cdn.example/bob-banner.png');
  });

  test('a hydrated cache profile and a presence avatar cannot replace it', () {
    final n = AppStateNotifier()..goLive(self, 'me#0001');
    n.hydrateProfiles({
      kNymbotPubkey: UserProfile(
        name: 'Nymbot',
        picture: 'https://nymchat.app/images/nymbot-icon.png',
        kind0Ts: 1700000001,
      ),
    });
    expect(n.state.users[kNymbotPubkey]!.profile?.picture, kNymbotAvatarAsset);
    expect(n.state.users[kNymbotPubkey]!.profile?.banner, kNymbotBannerAsset);

    n.setUserPresence(
      pubkey: kNymbotPubkey,
      status: UserStatus.online,
      avatarUrl: 'https://cdn.example/spoof.png',
      hasAvatarTag: true,
      stampLastSeen: false,
    );
    expect(n.state.users[kNymbotPubkey]!.profile?.picture, kNymbotAvatarAsset);
  });

  testWidgets('the Nymbot avatar renders from the asset bundle',
      (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: NymAvatar(
          seed: kNymbotPubkey, size: 32, imageUrl: kNymbotAvatarAsset),
    ));
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    expect((provider as ResizeImage).imageProvider, isA<AssetImage>());
    expect(((provider).imageProvider as AssetImage).assetName,
        kNymbotAvatarAsset);
  });
}
