import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import 'translate_languages.dart';

/// "Select Your Language" picker (translate.js `_promptTranslateLanguage`),
/// shown when the user translates without a `translateLanguage` set. Returns the
/// chosen language code, or null if cancelled. A searchable grid of languages.
///
/// The caller is responsible for persisting the choice to settings (settings is
/// owned by another slice).
Future<String?> promptTranslateLanguage(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierColor: const Color(0xB3000000),
    builder: (_) => const _LanguagePromptDialog(),
  );
}

class _LanguagePromptDialog extends StatefulWidget {
  const _LanguagePromptDialog();
  @override
  State<_LanguagePromptDialog> createState() => _LanguagePromptDialogState();
}

class _LanguagePromptDialogState extends State<_LanguagePromptDialog> {
  String _query = '';
  late final List<MapEntry<String, String>> _all = sortedTranslateLanguages();

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final filtered = _query.isEmpty
        ? _all
        : _all
            .where((e) => e.value.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 560),
        width: MediaQuery.of(context).size.width * 0.9,
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Select Your Language',
                style: TextStyle(
                    color: c.primary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              "Choose the language you'd like messages translated into. "
              'This will be saved to your settings.',
              style: TextStyle(color: c.textDim, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(color: c.textBright),
              decoration: InputDecoration(
                hintText: 'Search languages...',
                hintStyle: TextStyle(color: c.textDim),
                isDense: true,
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: NymRadius.rsm,
                  borderSide: BorderSide(color: c.glassBorder),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 3.4,
                children: [
                  for (final e in filtered)
                    InkWell(
                      onTap: () => Navigator.of(context).pop(e.key),
                      borderRadius: NymRadius.rxs,
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          border: Border.all(color: c.glassBorder),
                          borderRadius: NymRadius.rxs,
                        ),
                        child: Text(e.value,
                            style: TextStyle(color: c.text, fontSize: 12),
                            textAlign: TextAlign.center),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
