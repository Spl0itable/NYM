import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/site_links.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/utils/safe_url.dart';
import '../../widgets/common/nym_switch.dart';
import '../i18n/i18n.dart';

const String kAiConsentKey = 'nym_ai_consent';
const String kAiTranslateConsentKey = 'nym_ai_translate_consent';

enum AiConsentDecision { unset, allowed, declined }

class AiConsentBlocked implements Exception {
  const AiConsentBlocked();

  @override
  String toString() => AiConsentStrings.offNotice;
}

const Set<String> kAiConsentBotActions = {
  'pm',
  'pm-steer',
  'pm-answer',
  'pm-bgleg',
  'pm-schedfire',
  'transcribe',
};

class AiConsentCopy {
  const AiConsentCopy({
    required this.title,
    required this.paragraphs,
    required this.settingLabel,
    required this.settingSwitch,
    required this.switchKey,
    required this.groupKey,
  });

  final String Function() title;
  final List<String> Function() paragraphs;
  final String Function() settingLabel;
  final String Function() settingSwitch;
  final Key switchKey;
  final Key groupKey;
}

class AiConsentStrings {
  AiConsentStrings._();

  static String get title => tr('Allow Nymbot to use AI services?');

  static String get what => tr(
      'What is sent: to answer you, Nymbot sends what you ask it to AI '
      'services. That is your question or message, earlier messages in that '
      'Nymbot conversation, images and links you include and your nym. For a '
      'question in a channel it also sends the channel\'s recent messages '
      'from other people and the channel\'s approximate location. Allowing '
      'this also turns on AI translation, which sends text you choose to '
      'translate to our servers.');

  static String get who => tr(
      'Who receives it: the Nymbot service run by 21 Million LLC, which '
      'processes it on our servers. If you pick a Pro model or an image or '
      'video generator, it also goes to that model\'s maker, such as OpenAI, '
      'Anthropic, Google, xAI, Moonshot AI, Alibaba or MiniMax.');

  static String get later => tr(
      'Nothing is sent unless you allow it. You can change this at any time '
      'in Settings → Privacy & Security.');

  static String get privacyLink => tr('Privacy Policy');

  static String get allow => tr('Allow');

  static String get deny => tr('Don\'t Allow');

  static String get offNotice => tr(
      'Nothing was sent. This message goes to Nymbot, so it needs Nymbot AI '
      'processing. Send it again and choose Allow, or turn it on in Settings '
      '→ Privacy & Security.');

  static String get settingLabel => tr('Nymbot AI Processing');

  static String get settingSwitch => tr('Allow Nymbot AI processing');

  static String get settingSearch => tr(
      'Nymbot AI Processing Allow Nymbot AI processing for Nymbot, ?ask '
      'and @Nymbot');

  static List<String> get all => [
        title,
        what,
        who,
        later,
        privacyLink,
        allow,
        deny,
        offNotice,
        settingLabel,
        settingSwitch,
        settingSearch,
      ];
}

class TranslateConsentStrings {
  TranslateConsentStrings._();

  static String get title => tr('Allow AI translation?');

  static String get what => tr(
      'What is sent: only the text you choose to translate, such as a '
      'message, a poll or your draft, and the language to translate it into.');

  static String get who => tr(
      'Who receives it: the Nymchat service run by 21 Million LLC, which '
      'translates it with AI models on our servers and sends the translation '
      'back. A translation may be cached for up to a day so repeats are '
      'faster, and it is not used for anything else.');

  static String get offNotice => tr(
      'Nothing was translated. AI translation is off. Translate again and '
      'choose Allow, or turn it on in Settings → Privacy & Security.');

  static String get settingLabel => tr('AI Translation');

  static String get settingSwitch => tr('Allow AI translation');

  static String get settingSearch =>
      tr('AI Translation Allow AI translation for messages, polls and drafts');

  static List<String> get all => [
        title,
        what,
        who,
        offNotice,
        settingLabel,
        settingSwitch,
        settingSearch,
      ];
}

final AiConsentCopy kNymbotConsentCopy = AiConsentCopy(
  title: () => AiConsentStrings.title,
  paragraphs: () => [
    AiConsentStrings.what,
    AiConsentStrings.who,
    AiConsentStrings.later,
  ],
  settingLabel: () => AiConsentStrings.settingLabel,
  settingSwitch: () => AiConsentStrings.settingSwitch,
  switchKey: const Key('aiConsentSwitch'),
  groupKey: const Key('aiConsentGroup'),
);

final AiConsentCopy kTranslateConsentCopy = AiConsentCopy(
  title: () => TranslateConsentStrings.title,
  paragraphs: () => [
    TranslateConsentStrings.what,
    TranslateConsentStrings.who,
    AiConsentStrings.later,
  ],
  settingLabel: () => TranslateConsentStrings.settingLabel,
  settingSwitch: () => TranslateConsentStrings.settingSwitch,
  switchKey: const Key('aiTranslateSwitch'),
  groupKey: const Key('aiTranslateGroup'),
);

class AiConsent extends ChangeNotifier {
  AiConsent._(this.storageKey, this.copy);

  static final AiConsent instance = AiConsent._(kAiConsentKey, kNymbotConsentCopy);

  static final AiConsent translation =
      AiConsent._(kAiTranslateConsentKey, kTranslateConsentCopy);

  final String storageKey;
  final AiConsentCopy copy;

  Future<bool?> Function()? prompter;

  Future<bool?>? _asking;

  bool assumeAllowed = false;

  Future<AiConsentDecision> decision() async {
    if (assumeAllowed) return AiConsentDecision.allowed;
    try {
      final prefs = await SharedPreferences.getInstance();
      switch (prefs.getString(storageKey)) {
        case 'allowed':
          return AiConsentDecision.allowed;
        case 'declined':
          return AiConsentDecision.declined;
      }
    } catch (_) {}
    return AiConsentDecision.unset;
  }

  Future<bool> allowed() async {
    return await decision() == AiConsentDecision.allowed;
  }

  Future<void> set(bool allow) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, allow ? 'allowed' : 'declined');
    if (allow &&
        identical(this, instance) &&
        prefs.getString(translation.storageKey) == null) {
      await prefs.setString(translation.storageKey, 'allowed');
      translation.notifyListeners();
    }
    notifyListeners();
  }

  Future<bool> ensure() async {
    final d = await decision();
    if (d == AiConsentDecision.allowed) return true;
    final ask = prompter;
    if (ask == null) return false;
    final pending = _asking ??= ask();
    bool? answer;
    try {
      answer = await pending;
    } finally {
      if (identical(_asking, pending)) _asking = null;
    }
    if (answer == null) return false;
    if (await decision() != AiConsentDecision.allowed) await set(answer);
    return answer;
  }

  Future<void> guard() async {
    if (!await allowed()) throw const AiConsentBlocked();
  }
}

void registerAiConsentPrompter(GlobalKey<NavigatorState> navKey) {
  for (final consent in [AiConsent.instance, AiConsent.translation]) {
    consent.prompter = () async {
      final ctx = navKey.currentContext;
      if (ctx == null || !ctx.mounted) return null;
      return showAiConsentDialog(ctx, consent.copy);
    };
  }
}

Future<bool?> showAiConsentDialog(BuildContext context, AiConsentCopy copy) {
  return showAdaptiveDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AiConsentDialog(copy: copy),
  );
}

bool _cupertinoStyle(BuildContext context) {
  final p = Theme.of(context).platform;
  return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
}

class _PolicyLink extends StatelessWidget {
  const _PolicyLink({required this.style});

  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final color = style.color;
    return Align(
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          text: AiConsentStrings.privacyLink,
          style: style.copyWith(
            decoration: TextDecoration.underline,
            decorationColor: color,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () => launchSafeUrl(kPrivacyUrl),
        ),
      ),
    );
  }
}

class AiConsentDialog extends StatelessWidget {
  const AiConsentDialog({super.key, required this.copy});

  final AiConsentCopy copy;

  @override
  Widget build(BuildContext context) {
    final cupertino = _cupertinoStyle(context);
    final link = cupertino
        ? CupertinoTheme.of(context).primaryColor
        : Theme.of(context).colorScheme.primary;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in copy.paragraphs()) ...[
          Text(p, textAlign: TextAlign.left),
          const SizedBox(height: 8),
        ],
        _PolicyLink(style: TextStyle(color: link)),
      ],
    );
    void answer(bool v) => Navigator.of(context).pop(v);
    if (cupertino) {
      return CupertinoAlertDialog(
        key: const Key('aiConsentDialog'),
        title: Text(copy.title()),
        content: Padding(padding: const EdgeInsets.only(top: 8), child: body),
        actions: [
          CupertinoDialogAction(
            key: const Key('aiConsentDeny'),
            onPressed: () => answer(false),
            child: Text(AiConsentStrings.deny),
          ),
          CupertinoDialogAction(
            key: const Key('aiConsentAllow'),
            isDefaultAction: true,
            onPressed: () => answer(true),
            child: Text(AiConsentStrings.allow),
          ),
        ],
      );
    }
    return AlertDialog(
      key: const Key('aiConsentDialog'),
      title: Text(copy.title()),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(child: body),
      ),
      actions: [
        TextButton(
          key: const Key('aiConsentDeny'),
          onPressed: () => answer(false),
          child: Text(AiConsentStrings.deny),
        ),
        FilledButton(
          key: const Key('aiConsentAllow'),
          onPressed: () => answer(true),
          child: Text(AiConsentStrings.allow),
        ),
      ],
    );
  }
}

class AiConsentSettingRow extends StatefulWidget {
  const AiConsentSettingRow({super.key, required this.consent});

  final AiConsent consent;

  @override
  State<AiConsentSettingRow> createState() => _AiConsentSettingRowState();
}

class _AiConsentSettingRowState extends State<AiConsentSettingRow> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    widget.consent.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.consent.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final d = await widget.consent.decision();
    if (!mounted) return;
    setState(() => _on = d == AiConsentDecision.allowed);
  }

  Future<void> _set(bool v) async {
    setState(() => _on = v);
    await widget.consent.set(v);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label = widget.consent.copy.settingSwitch();
    return Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: c.text, fontSize: 14)),
        ),
        const SizedBox(width: 12),
        Semantics(
          toggled: _on,
          label: label,
          child: NymSwitch(
            key: widget.consent.copy.switchKey,
            value: _on,
            onChanged: _set,
          ),
        ),
      ],
    );
  }
}

class AiConsentSettingFooter extends StatelessWidget {
  const AiConsentSettingFooter({super.key, required this.consent});

  final AiConsent consent;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final style = TextStyle(color: c.textDim, fontSize: 11, height: 1.4);
    final paragraphs = consent.copy.paragraphs();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in paragraphs.take(paragraphs.length - 1)) ...[
          Text(p, style: style),
          const SizedBox(height: 6),
        ],
        _PolicyLink(style: style.copyWith(color: c.primary)),
      ],
    );
  }
}
