import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import 'translate_languages.dart';

/// "Select Your Language" picker (translate.js `_promptTranslateLanguage`,
/// lines 126-192), shown when the user translates without a `translateLanguage`
/// set. Returns the chosen language code, or null if cancelled. A searchable
/// 2-col grid of languages.
///
/// The classes here have NO base CSS — all styling comes from the `nm-tr-*`
/// utilities (no-inline.css:167-172) over the shared `.modal-content`, plus the
/// inline hover (translate.js:174-181). Verified against those tokens.
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
        // `.nm-tr-1` over `.modal-content`: max-width 360, padding 24, radius-xl,
        // bg-secondary, glass border.
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 560),
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
            // `.nm-tr-2`: 1.1em (~16.5 of 15) text-bright, margin-bottom 6 — a
            // bespoke <h3>, NOT a `.modal-header` (no uppercase/primary/rule).
            Text('Select Your Language',
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            // `.nm-tr-3`: 0.85em (~13) text-dim, margin-bottom 12.
            Text(
              "Choose the language you'd like messages translated into. "
              'This will be saved to your settings.',
              style: TextStyle(color: c.textDim, fontSize: 13),
            ),
            const SizedBox(height: 12),
            // `.nm-tr-4`: padding 9/12, radius-sm, glass border, bg white@0.05,
            // text (`--text`), 0.9em (~13.5), focus → primary border.
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(color: c.text, fontSize: 13.5),
              cursorColor: c.isLight ? Colors.black : Colors.white,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search languages...',
                hintStyle: TextStyle(color: c.textDim, fontSize: 13.5),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                border: OutlineInputBorder(
                  borderRadius: NymRadius.rsm,
                  borderSide: BorderSide(color: c.glassBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: NymRadius.rsm,
                  borderSide: BorderSide(color: c.glassBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: NymRadius.rsm,
                  borderSide: BorderSide(color: c.primary),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // `.nm-tr-5`: 2-col grid, gap 6, max-height 320, padding-right 4.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                    // `.nm-tr-6`: padding 10/12 + ~13.5 line ≈ 38px tall; at the
                    // ~166px 2-col width that's ≈ 4.3:1.
                    childAspectRatio: 4.3,
                    children: [
                      for (final e in filtered)
                        _LangOption(
                          name: e.value,
                          onTap: () => Navigator.of(context).pop(e.key),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.translate-lang-option` / `.nm-tr-6`: a left-aligned translucent pill,
/// padding 10/12, radius-sm, glass border, bg white@0.04, text (`--text`) 0.9em.
/// Hover (translate.js:174-181) → bg white@0.1 + primary border (~120ms).
class _LangOption extends StatefulWidget {
  const _LangOption({required this.name, required this.onTap});
  final String name;
  final VoidCallback onTap;

  @override
  State<_LangOption> createState() => _LangOptionState();
}

class _LangOptionState extends State<_LangOption> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _hover
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.white.withValues(alpha: 0.04),
            border: Border.all(color: _hover ? c.primary : c.glassBorder),
            borderRadius: NymRadius.rsm,
          ),
          child: Text(
            widget.name,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.left,
            style: TextStyle(color: c.text, fontSize: 13.5),
          ),
        ),
      ),
    );
  }
}
