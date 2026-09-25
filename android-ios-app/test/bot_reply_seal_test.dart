import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/features/nymbot/nymbot_providers.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

NostrEvent _seal() {
  final sk = generatePrivateKey();
  return schnorr.finalizeEvent(
    UnsignedEvent(pubkey: getPublicKeyHex(sk), createdAt: 1700000000, kind: 13),
    sk,
  );
}

NostrEvent _claimingBot(NostrEvent seal) => NostrEvent(
      id: seal.id,
      pubkey: kNymbotPubkey,
      createdAt: seal.createdAt,
      kind: seal.kind,
      tags: seal.tags,
      content: seal.content,
      sig: seal.sig,
    );

void main() {
  test('a reply sealed by anyone but Nymbot is not shown as the bot', () {
    final seal = _seal();
    expect(BotChatController.fromBot(seal, {'pubkey': seal.pubkey}), isFalse);
  });

  test('a seal that only claims to be Nymbot is refused', () {
    final forged = _claimingBot(_seal());
    expect(
        BotChatController.fromBot(forged, {'pubkey': kNymbotPubkey}), isFalse);
  });

  test('the message inside must name the same author as the seal', () {
    final seal = _seal();
    expect(BotChatController.fromBot(seal, {'pubkey': kNymbotPubkey}), isFalse);
  });
}
