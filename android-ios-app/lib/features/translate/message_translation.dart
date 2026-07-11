import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../i18n/i18n.dart';
import 'translate_language_prompt.dart';
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
  /// Null until a target language is resolved (either it was already set, or
  /// the user picked one via the prompt). Stays null — with [_cancelled] set —
  /// when the user dismisses the "Select Your Language" picker.
  Future<TranslationResult>? _future;

  /// True once the user cancels the language prompt; the block renders nothing,
  /// mirroring translate.js:200 (`if (!targetLang) return;`).
  bool _cancelled = false;

  late final TranslateService _service = widget.service ?? TranslateService();

  String get _target =>
      widget.targetLang ??
      ref.read(settingsProvider).translateLanguage;

  @override
  void initState() {
    super.initState();
    final target = _target;
    if (target.isEmpty) {
      // No translateLanguage set: open the picker first, persist the choice,
      // then translate into it — mirrors translate.js:197-201 + :165-171.
      _promptThenTranslate();
    } else {
      _start(target);
    }
  }

  void _start(String target) {
    final plain = TranslateService.stripQuotes(widget.content);
    final future = _service.translate(plain, target);
    // On failure the PWA shows the inline `.translation-error` AND posts a
    // system chat message with the error detail
    // (translate.js:269 `displaySystemMessage('Translation failed: ' + ...)`).
    // Capture the notifier now so the message still lands even if this widget
    // is disposed before the request settles, like the PWA's detached async.
    final notifier = ref.read(appStateProvider.notifier);
    future.then<void>((_) {}, onError: (Object err) {
      final msg = err is TranslateException ? err.message : err.toString();
      notifier.addSystemMessage(tr('Translation failed: {error}',
          {'error': msg.isEmpty ? tr('Unknown error') : msg}));
    });
    _future = future;
  }

  Future<void> _promptThenTranslate() async {
    final code = await promptTranslateLanguage(context);
    if (!mounted) return;
    if (code == null || code.isEmpty) {
      // User cancelled — render nothing (translate.js:200 `return`).
      setState(() => _cancelled = true);
      return;
    }
    // Persist the choice (the picker widget leaves persistence to the caller).
    ref.read(settingsProvider.notifier).setTranslateLanguage(code);
    setState(() => _start(code));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.message-translation { font-size: 0.9em }` — em of the `.message` font,
    // which is `var(--user-text-size)` (styles-chat.css:54), so the block
    // scales with the text-size setting (styles-features.css:4316).
    final baseSize =
        ref.watch(settingsProvider.select((s) => s.textSize)).toDouble() * 0.9;
    // Nothing to show until a target language is resolved: while the picker is
    // open (_future still null) or if the user cancelled it (translate.js:200).
    final future = _future;
    if (future == null || _cancelled) return const SizedBox.shrink();
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
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            // `.translation-loading`: STATIC italic dim@0.6 — the PWA has NO
            // pulse on the inline message translation (styles-features.css:4333).
            return Text(
              tr('Translating...'),
              style: TextStyle(
                color: c.textDim.withValues(alpha: 0.6),
                fontStyle: FontStyle.italic,
                fontSize: baseSize,
                height: 1.4,
              ),
            );
          }
          if (snap.hasError) {
            // `.translation-error { font-size: 0.85em }` of the block base.
            return Text(
              tr('Translation failed'),
              style: TextStyle(
                  color: c.danger, fontSize: baseSize * 0.85, height: 1.4),
            );
          }
          final res = snap.data!;
          final plain = TranslateService.stripQuotes(widget.content);
          final isNoop = res.translatedText.trim().isEmpty ||
              res.translatedText.trim() == plain.trim();
          if (isNoop) {
            return Text.rich(
              TextSpan(
                style: TextStyle(
                    color: c.textDim, fontSize: baseSize, height: 1.4),
                children: [
                  const TextSpan(text: '🌐 '),
                  TextSpan(
                    text: tr('Already in {lang} (nothing to translate)',
                        {'lang': languageName(_target)}),
                    // `.translation-error`: 0.85em of the block base.
                    style: TextStyle(
                        color: c.danger, fontSize: baseSize * 0.85),
                  ),
                ],
              ),
            );
          }
          final showLang = res.detectedLanguage != 'auto' &&
              res.detectedLanguage != _target;
          return Text.rich(
            TextSpan(
              style:
                  TextStyle(color: c.textDim, fontSize: baseSize, height: 1.4),
              children: [
                const TextSpan(text: '🌐 '),
                TextSpan(text: res.translatedText),
                if (showLang)
                  TextSpan(
                    // `.translation-lang`: 0.8em of the block base.
                    text:
                        '  ${languageName(res.detectedLanguage)} → ${languageName(_target)}',
                    style: TextStyle(
                      color: c.textDim.withValues(alpha: 0.7),
                      fontSize: baseSize * 0.8,
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

