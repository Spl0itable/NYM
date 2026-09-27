import '../i18n/i18n.dart';

import '../../models/settings.dart';

/// The language a MANUAL translate should target.
///
/// This never returns empty: a manual translate is an explicit request, so it
/// has to produce something. There is no "pick a language" prompt any more — every user chooses one at first run and that
/// pick is adopted as the translation target, so asking again on the first
/// translation was asking a question already answered, and it interrupted the
/// very action the user had just taken.
String manualTranslateTargetFor(Settings settings) {
  if (settings.translateLanguage.isNotEmpty) return settings.translateLanguage;
  final ui = settings.uiLanguage;
  return ui.isNotEmpty ? ui : 'en';
}

/// Message-id prefix of Nymbot's welcome messages: the transient premium
/// welcome `nymbot-welcome` and the persisted first-contact PM
/// `nymbot-welcome-<ts>`.
const String kNymbotWelcomeIdPrefix = 'nymbot-welcome';

/// Renders Nymbot's welcome copy in the language chosen at signup.
///
/// The greeting is the first thing a new user reads, and it was shown in
/// English however carefully they had just picked their language. It is app
/// copy rather than user content, so [tr] localizes it from the same cache the
/// rest of the UI uses: no per-message network round trip, correct offline once
/// cached, and it follows a later language change instead of being frozen into
/// the stored message. Anything else is returned untouched.
///
/// Until the translation lands, `tr` returns the English source and the
/// repaint that follows swaps it — which is why the copy is primed the moment
/// the language is chosen (`primeBotWelcomeCopy`).
String localizeBotWelcome(String messageId, String content) =>
    messageId.startsWith(kNymbotWelcomeIdPrefix) ? tr(content) : content;
