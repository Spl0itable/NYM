import 'dart:async';
import 'dart:math' as math;
import '../nymbot/nymbot_providers.dart' show primeBotWelcomeCopy;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';
import '../notifications/background_catch_up.dart' show hasChosenIdentity;
import '../translate/translate_languages.dart';
import '../commands/command_i18n.dart';
import 'app_strings_catalog.dart';
import 'i18n.dart';
import 'localization_service.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_field.dart';

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

String deviceUiLanguage(List<Locale> locales) {
  final known = kTranslateLanguageNames.keys.toSet();
  for (final locale in locales) {
    final base = locale.languageCode.toLowerCase();
    if (base.isEmpty) continue;
    if (base == 'en') return '';
    final country = (locale.countryCode ?? '').toLowerCase();
    final full = country.isEmpty ? base : '$base-$country';
    if (known.contains(full)) return full;
    if (known.contains(base)) return base;
  }
  return '';
}

bool needsFirstRunLanguage(KeyValueStore kv) {
  if (kv.getBool(StorageKeys.uiLanguageChosen, defaultValue: false)) {
    return false;
  }
  if ((kv.getString(StorageKeys.uiLanguage) ?? '').isNotEmpty) return false;
  return !hasChosenIdentity(kv);
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
                      selectedCode: _preselected(ref),
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

String _preselected(WidgetRef ref) {
  final saved = ref.watch(settingsProvider.select((s) => s.uiLanguage));
  if (saved.isNotEmpty) return saved;
  return deviceUiLanguage(WidgetsBinding.instance.platformDispatcher.locales);
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
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _initialOffset(),
  );

  final FocusNode _selectedFocus = FocusNode(debugLabel: 'selectedLanguage');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected(6));
  }

  int get _selectedIndex {
    final code = widget.selectedCode == 'en' ? '' : widget.selectedCode;
    return kUiLanguageOptions.indexWhere((o) => o.code == code);
  }

  void _revealSelected(int tries) {
    if (!mounted) return;
    final row = _selectedFocus.context;
    if (row != null) {
      unawaited(Scrollable.ensureVisible(row, alignment: 0.3));
      _selectedFocus.requestFocus();
      return;
    }
    final i = _selectedIndex;
    if (tries <= 0 || i < 0 || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final extent = (pos.maxScrollExtent + pos.viewportDimension) /
        kUiLanguageOptions.length;
    _scroll.jumpTo((i * extent - pos.viewportDimension * 0.3)
        .clamp(0.0, pos.maxScrollExtent));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _revealSelected(tries - 1));
  }

  double _initialOffset() {
    final i = _selectedIndex;
    return i <= 3 ? 0 : (i - 3) * 64.0;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _selectedFocus.dispose();
    super.dispose();
  }

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
        NymFieldBox(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: NymField.icon(c)),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  style: TextStyle(color: c.inputText, fontSize: 14),
                  cursorColor: c.primary,
                  decoration: NymField.bare(c,
                      hint: tr('Search languages'), fontSize: 14),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            itemCount: items.length,
            itemBuilder: (_, i) {
              final o = items[i];
              final selected = o.code == widget.selectedCode ||
                  (o.code.isEmpty && widget.selectedCode == 'en');
              return _LanguageRow(
                key: ValueKey('langRow-${o.code}'),
                name: o.code.isEmpty ? o.name : languageNative(o.code),
                subtitle: o.code.isEmpty ? '' : languageSubtitle(o.code),
                selected: selected,
                focusNode: selected ? _selectedFocus : null,
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
    super.key,
    required this.name,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.focusNode,
  });

  final String name;
  final FocusNode? focusNode;

  /// The English name, shown under the endonym when it adds something.
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: onTap,
      focusNode: focusNode,
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
  return showNymSheet<void>(
    context,
    (dialogContext) {
      final list = Column(
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
    );
      return nymSheetOr(
        dialogContext,
        SizedBox(
          height: math.min(560, MediaQuery.sizeOf(dialogContext).height * 0.75),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: list,
          ),
        ),
        (list) => Dialog(
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
              child: list,
            ),
          ),
        ),
      );
    },
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
