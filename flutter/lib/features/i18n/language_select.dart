import 'dart:async';
import '../nymbot/nymbot_providers.dart' show primeBotWelcomeCopy;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/settings_provider.dart';
import '../translate/translate_languages.dart';
import '../commands/command_i18n.dart';
import 'app_strings_catalog.dart';
import 'i18n.dart';
import 'localization_service.dart';

/// A UI-language option: stored code (empty for English source) and English display name.
class UiLanguageOption {
  const UiLanguageOption(this.code, this.name);
  final String code;
  final String name;
}

/// English first (stored as `''`), then every translator language alphabetically.
final List<UiLanguageOption> kUiLanguageOptions = [
  const UiLanguageOption('', 'English'),
  ...sortedTranslateLanguages()
      .where((e) => e.key != 'en')
      .map((e) => UiLanguageOption(e.key, e.value)),
];

/// Endonym first, with the English name appended when it differs.
String uiLanguageName(String code) {
  if (code.isEmpty || code == 'en') return 'English';
  final subtitle = languageSubtitle(code);
  final native = languageNative(code);
  return subtitle.isEmpty ? native : '$native — $subtitle';
}

/// Applies [code] without blocking; next screens translate on the high-priority lane ahead of the background sweep.
void applyUiLanguage(WidgetRef ref, String code) {
  ref.read(settingsProvider.notifier).setUiLanguage(code);
  // Apply now rather than waiting for the async settings listener; setLanguage is idempotent.
  final svc = LocalizationService.instance;
  svc.setLanguage(code);
  if (!svc.isActive) return; // English: nothing to translate.
  // Command names are typed, so they translate ahead of the bulk catalog.
  svc.prime(commandSourcePhrases());
  // Nymbot greets a new user seconds later, so prime its welcome copy now.
  primeBotWelcomeCopy();
  svc.sweep(kAppStringsCatalog);
}

/// First-run language chooser shown before the tutorial; [onComplete] advances.
class LanguageSelectScreen extends ConsumerWidget {
  const LanguageSelectScreen({super.key, required this.onComplete});

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
                    // English by design: no language has been chosen yet.
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
                      selectedCode: ref
                          .watch(settingsProvider.select((s) => s.uiLanguage)),
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

/// Searchable language list, reused by onboarding and the Settings dialog.
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
            .where((o) => languageSearchKey(o.code, o.name).contains(q))
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                  style: TextStyle(color: c.inputText, fontSize: 14),
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
                name: o.code.isEmpty ? o.name : languageNative(o.code),
                subtitle: o.code.isEmpty ? '' : languageSubtitle(o.code),
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
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String name;

  /// The English name, shown under the endonym when it adds something.
  final String subtitle;
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: c.text,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: TextStyle(color: c.textDim, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            if (selected) Icon(Icons.check, size: 18, color: c.primary),
          ],
        ),
      ),
    );
  }
}

/// Shared searchable language dialog, used for both the app language and the translation target.
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

/// Appearance language chooser; applies the pick as the UI language.
Future<void> showLanguagePickerDialog(BuildContext context, WidgetRef ref) {
  return showLanguageListDialog(
    context,
    selectedCode: ref.read(settingsProvider).uiLanguage,
    title: tr('Language'),
    onSelected: (code) => applyUiLanguage(ref, code),
  );
}
