import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/settings_provider.dart';
import 'translate_languages.dart';
import 'translate_service.dart';

/// Inline `.message-translation` block shown below a message after the user
/// taps "Translate" (translate.js `translateMessage`). A left-accented panel
/// with a 🌐 icon, the translated text, and a dim `source → target` label.
/// While loading it shows an italic "Translating…" with a translate pulse.
class MessageTranslation extends ConsumerStatefulWidget {
  const MessageTranslation({
    super.key,
    required this.content,
    this.targetLang,
    this.service,
  });

  /// The (quote-stripped) text to translate.
  final String content;

  /// Override target language; defaults to `settings.translateLanguage`.
  final String? targetLang;

  /// Injectable for tests; defaults to a live [TranslateService].
  final TranslateService? service;

  @override
  ConsumerState<MessageTranslation> createState() => _MessageTranslationState();
}

class _MessageTranslationState extends ConsumerState<MessageTranslation> {
  late Future<TranslationResult> _future;
  late final TranslateService _service = widget.service ?? TranslateService();

  String get _target =>
      widget.targetLang ??
      ref.read(settingsProvider).translateLanguage;

  @override
  void initState() {
    super.initState();
    final plain = TranslateService.stripQuotes(widget.content);
    _future = _service.translate(plain, _target.isEmpty ? 'en' : _target);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        border: Border(left: BorderSide(color: c.primary, width: 3)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(NymRadius.xs),
          bottomRight: Radius.circular(NymRadius.xs),
        ),
      ),
      child: FutureBuilder<TranslationResult>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _TranslatePulse(
              child: Text(
                'Translating...',
                style: TextStyle(
                  color: c.textDim.withValues(alpha: 0.6),
                  fontStyle: FontStyle.italic,
                  fontSize: 13,
                ),
              ),
            );
          }
          if (snap.hasError) {
            return Text(
              'Translation failed',
              style: TextStyle(color: c.danger, fontSize: 12),
            );
          }
          final res = snap.data!;
          final plain = TranslateService.stripQuotes(widget.content);
          final isNoop = res.translatedText.trim().isEmpty ||
              res.translatedText.trim() == plain.trim();
          if (isNoop) {
            return Text.rich(
              TextSpan(children: [
                const TextSpan(text: '🌐 '),
                TextSpan(
                  text:
                      'Already in ${languageName(_target)} (nothing to translate)',
                  style: TextStyle(color: c.danger, fontSize: 12),
                ),
              ]),
            );
          }
          final showLang = res.detectedLanguage != 'auto' &&
              res.detectedLanguage != _target;
          return Text.rich(
            TextSpan(
              style: TextStyle(color: c.textDim, fontSize: 13, height: 1.4),
              children: [
                const TextSpan(text: '🌐 '),
                TextSpan(text: res.translatedText),
                if (showLang)
                  TextSpan(
                    text:
                        '  ${languageName(res.detectedLanguage)} → ${languageName(_target)}',
                    style: TextStyle(
                      color: c.textDim.withValues(alpha: 0.7),
                      fontSize: 13 * 0.8,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A subtle pulse used while a translation is in flight (the PWA's
/// `.translating` / translate-pulse affordance).
class _TranslatePulse extends StatefulWidget {
  const _TranslatePulse({required this.child});
  final Widget child;
  @override
  State<_TranslatePulse> createState() => _TranslatePulseState();
}

class _TranslatePulseState extends State<_TranslatePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1.0).animate(_c),
      child: widget.child,
    );
  }
}
