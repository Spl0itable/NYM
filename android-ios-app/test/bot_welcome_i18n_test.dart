// Nymbot's greeting is the first thing a new user reads, and it has to be in
// the language they just picked at signup.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/nymbot/nymbot_providers.dart';
import 'package:nym_bar/features/translate/auto_translate.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';

Message _msg(String id, {bool isPM = true}) => Message(
      id: id,
      author: 'Nymbot',
      pubkey: 'b' * 64,
      content: 'hello',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      isPM: isPM,
      isBot: true,
    );

void main() {
  group('localizeBotWelcome', () {
    test('routes both welcome messages through the UI-string cache', () {
      // English (no active language) is a pass-through, so the assertion here
      // is that the welcome ids are the ones recognised — the transient
      // in-chat welcome and the persisted first-contact PM.
      expect(localizeBotWelcome('nymbot-welcome', botWelcomeText),
          botWelcomeText);
      expect(
        localizeBotWelcome('nymbot-welcome-1750000000', botFirstContactText),
        botFirstContactText,
      );
    });

    test('leaves every other message untouched', () {
      const peerText = 'a message from another person';
      expect(localizeBotWelcome('some-event-id', peerText), peerText);
      expect(localizeBotWelcome('nymbot-info-123-4', peerText), peerText);
    });
  });

  group('auto-translate no longer competes for the welcome', () {
    test('welcome messages are excluded from the message translator', () {
      // They localize through the UI-string cache instead; translating them
      // here too would race two differently-worded results into one bubble.
      const settings = Settings(autoTranslate: true, translateLanguage: 'es');
      expect(autoTranslateAppliesTo(_msg('nymbot-welcome'), settings), false);
      expect(
        autoTranslateAppliesTo(_msg('nymbot-welcome-1750000000'), settings),
        false,
      );
      // An ordinary PM still auto-translates when the user asked for it.
      expect(autoTranslateAppliesTo(_msg('event-id'), settings), true);
    });
  });

  test('the primeable copy is exactly the two welcome strings', () {
    // What gets pre-translated when the language is chosen at signup.
    expect(botWelcomeSourceStrings(),
        containsAll(<String>[botWelcomeText, botFirstContactText]));
    expect(botWelcomeSourceStrings(), hasLength(2));
  });
}
