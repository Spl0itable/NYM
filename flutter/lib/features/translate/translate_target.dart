import '../i18n/i18n.dart';

import '../../models/settings.dart';

/// Target language for a manual translate; never empty, defaulting to the language picked at first run.
String manualTranslateTargetFor(Settings settings) {
  if (settings.translateLanguage.isNotEmpty) return settings.translateLanguage;
  final ui = settings.uiLanguage;
  return ui.isNotEmpty ? ui : 'en';
}

/// Message-id prefix of Nymbot's welcome messages (`nymbot-welcome` and `nymbot-welcome-<ts>`).
const String kNymbotWelcomeIdPrefix = 'nymbot-welcome';

/// Localizes Nymbot's welcome copy via [tr] so it follows the UI language; other messages pass through.
String localizeBotWelcome(String messageId, String content) =>
    messageId.startsWith(kNymbotWelcomeIdPrefix) ? tr(content) : content;
