import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/settings_provider.dart';
import '../i18n/i18n.dart';
import '../toasts/toast_center.dart';
import 'translate_target.dart';
import 'translate_languages.dart';
import 'translate_service.dart';
import 'translation_cache.dart';

/// Inline translation block shown below a message after "Translate".
class MessageTranslation extends ConsumerStatefulWidget {
  const MessageTranslation({
    super.key,
    required this.content,
    this.targetLang,
    this.service,
  });

  /// The quote-stripped text to translate.
  final String content;

  /// Override target language; defaults to `settings.translateLanguage`.
  final String? targetLang;

  /// Injectable for tests.
  final TranslateService? service;

  @override
  ConsumerState<MessageTranslation> createState() => _MessageTranslationState();
}

class _MessageTranslationState extends ConsumerState<MessageTranslation> {
  /// Null until a target language is resolved.
  Future<TranslationResult>? _future;

  /// Finished cached translation, so a rebuilt row paints it without a "Translating..." frame.
  TranslationResult? _seed;

  late final TranslateService _service = widget.service ?? TranslateService();

  String get _target =>
      widget.targetLang ?? manualTranslateTargetFor(ref.read(settingsProvider));

  @override
  void initState() {
    super.initState();
    _start(_target);
  }

  void _start(String target) {
    final plain = TranslateService.stripQuotes(widget.content);
    _seed = ref.read(translationCacheProvider).settled(plain, target);
    // Through the cache, so a rebuilt row reuses its request instead of re-calling the API.
    _future = ref.read(translationCacheProvider).resolve(
      plain,
      target,
      () => _service.translate(plain, target),
      onStarted: (future) {
        future.then<void>((_) {}, onError: (Object err) {
          final msg = err is TranslateException ? err.message : err.toString();
          showToast(tr('Translation failed: {error}',
              {'error': msg.isEmpty ? tr('Unknown error') : msg}));
        });
      },
    );
  }


  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // 0.9em of the user text size, so the block scales with that setting.
    final baseSize =
        ref.watch(settingsProvider.select((s) => s.textSize)).toDouble() * 0.9;
    final future = _future;
    if (future == null) return const SizedBox.shrink();
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
        initialData: _seed,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done && !snap.hasData) {
            // Static italic; the inline translation has no pulse.
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
                    style:
                        TextStyle(color: c.danger, fontSize: baseSize * 0.85),
                  ),
                ],
              ),
            );
          }
          final showLang =
              res.detectedLanguage != 'auto' && res.detectedLanguage != _target;
          return Text.rich(
            TextSpan(
              style:
                  TextStyle(color: c.textDim, fontSize: baseSize, height: 1.4),
              children: [
                const TextSpan(text: '🌐 '),
                TextSpan(text: res.translatedText),
                if (showLang)
                  TextSpan(
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
