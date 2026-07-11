import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/settings_provider.dart';
import '../translate/translate_languages.dart';
import 'app_strings_catalog.dart';
import 'i18n.dart';
import 'localization_service.dart';

/// A selectable UI-language option: its stored code (empty ⇒ English source)
/// and its English display name.
class UiLanguageOption {
  const UiLanguageOption(this.code, this.name);
  final String code;
  final String name;
}

/// The full UI-language menu: English pinned first (stored as `''` so it maps
/// to the no-translate source path), then every language the message
/// translator supports, alphabetically. Reuses [sortedTranslateLanguages] so
/// the app-language list stays in lockstep with the message-translation list.
final List<UiLanguageOption> kUiLanguageOptions = [
  const UiLanguageOption('', 'English'),
  ...sortedTranslateLanguages()
      .where((e) => e.key != 'en')
      .map((e) => UiLanguageOption(e.key, e.value)),
];

/// The display name for a stored UI-language [code] (empty/`en` ⇒ English).
String uiLanguageName(String code) {
  if (code.isEmpty || code == 'en') return 'English';
  return languageName(code);
}

/// Applies [code] as the app UI language and kicks translation. NON-BLOCKING:
/// the caller can proceed immediately (no progress dialog, no render block), so
/// the user starts using the app right away.
///
/// Prioritization is handled by [LocalizationService]'s two-lane queue: the
/// screens shown next — the welcome/signup modal, then the tutorial — translate
/// FIRST via the high-priority lane (their on-demand `tr()` renders + the
/// tutorial's [LocalizationService.prime]), while the full-app catalog [sweep]
/// kicked here runs in the LOW-priority background behind them. A brief English
/// flash before each screen's strings land is fine.
void applyUiLanguage(WidgetRef ref, String code) {
  ref.read(settingsProvider.notifier).setUiLanguage(code);
  // Apply immediately rather than waiting on the root's settings listener (its
  // callback fires asynchronously); setLanguage is idempotent, so the listener
  // re-invoking it with the same code is a harmless no-op.
  final svc = LocalizationService.instance;
  svc.setLanguage(code);
  if (!svc.isActive) return; // English: nothing to translate.
  svc.sweep(kAppStringsCatalog);
}

/// First-run, full-screen language chooser shown at the very start of
/// onboarding (before the guided tutorial). Picking a language localizes the
/// app going forward and persists the choice; [onComplete] then advances to the
/// tutorial. English is offered first so the default path is one tap.
class LanguageSelectScreen extends ConsumerWidget {
  const LanguageSelectScreen({super.key, required this.onComplete});

  /// Called once a language has been chosen and applied.
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Text(
                    // English by design — the user hasn't chosen a language yet,
                    // so this welcome greeting stays in the source language.
                    'Choose your language',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'You can change this anytime in Settings.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.textDim, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: LanguagePickerList(
                      selectedCode: ref.watch(
                          settingsProvider.select((s) => s.uiLanguage)),
                      onSelected: (code) {
                        applyUiLanguage(ref, code);
                        onComplete();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A searchable, scrollable list of [kUiLanguageOptions] with the active one
/// checked. Reused by the onboarding screen and the Settings language dialog.
class LanguagePickerList extends StatefulWidget {
  const LanguagePickerList({
    super.key,
    required this.selectedCode,
    required this.onSelected,
  });

  final String selectedCode;
  final ValueChanged<String> onSelected;

  @override
  State<LanguagePickerList> createState() => _LanguagePickerListState();
}

class _LanguagePickerListState extends State<LanguagePickerList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final q = _query.trim().toLowerCase();
    final items = q.isEmpty
        ? kUiLanguageOptions
        : kUiLanguageOptions
            .where((o) => o.name.toLowerCase().contains(q))
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search box.
        Container(
          decoration: BoxDecoration(
            color: c.bgTertiary,
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: c.textDim),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  style: TextStyle(color: c.text, fontSize: 14),
                  cursorColor: c.primary,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: tr('Search languages'),
                    hintStyle: TextStyle(color: c.textDim, fontSize: 14),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (_, i) {
              final o = items[i];
              final selected = o.code == widget.selectedCode ||
                  (o.code.isEmpty && widget.selectedCode == 'en');
              return _LanguageRow(
                name: o.name,
                selected: selected,
                onTap: () => widget.onSelected(o.code),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? c.primary.withValues(alpha: 0.12) : null,
          borderRadius: NymRadius.rsm,
          border: Border.all(
            color: selected ? c.primary : c.glassBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: c.text,
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (selected) Icon(Icons.check, size: 18, color: c.primary),
          ],
        ),
      ),
    );
  }
}

/// Opens the shared, searchable language chooser — the same ~130-language list
/// [kUiLanguageOptions] the onboarding picker uses. [selectedCode] is checked in
/// the list; [onSelected] receives the picked code once the dialog closes. Used
/// for BOTH the app language (Appearance) and the message-translation target
/// (Messaging & Display) so the two offer the exact same list.
Future<void> showLanguageListDialog(
  BuildContext context, {
  required String selectedCode,
  required ValueChanged<String> onSelected,
  String? title,
}) {
  final c = context.nym;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: c.bgSecondary,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: NymRadius.rlg,
        side: BorderSide(color: c.glassBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title ?? tr('Language'),
                      style: TextStyle(
                        color: c.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: c.textDim),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: LanguagePickerList(
                  selectedCode: selectedCode,
                  onSelected: (code) {
                    Navigator.of(dialogContext).pop();
                    onSelected(code);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The Appearance → Language chooser: opens the shared dialog and applies the
/// pick as the app UI language (translation runs non-blocking in the
/// background).
Future<void> showLanguagePickerDialog(BuildContext context, WidgetRef ref) {
  return showLanguageListDialog(
    context,
    selectedCode: ref.read(settingsProvider).uiLanguage,
    title: tr('Language'),
    onSelected: (code) => applyUiLanguage(ref, code),
  );
}
