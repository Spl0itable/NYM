import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/settings_provider.dart';

/// Shared confirm / alert / prompt dialog — the native port of the PWA's
/// `dialog.js` (`showAppConfirm` / `showAppAlert` / `showAppPrompt`), styled to
/// the `.app-dialog` component (`styles-components.css:2349-2388`):
///
///  * `max-width: 440px` content
///  * message `font-size: 14px; line-height: 1.45; white-space: pre-line`
///  * optional checkbox row, optional single-line input OR `min-height: 110px`
///    textarea, optional char counter (warning at 80%, limit at 100%)
///  * `danger` OK button (`bg rgb(danger/.1)`, `border rgb(danger/.35)`,
///    text `--danger`)
///  * Esc = cancel, Enter = confirm (single-line only)
///
/// Other modal slices can reuse these helpers for a consistent danger-confirm /
/// prompt-with-char-count / checkbox-confirm surface.

/// `.modal` overlay: glass default `rgba(0,0,0,0.7)` (styles-chat.css:1974);
/// `body.solid-ui .modal { rgba(0,0,0,0.75) }` and
/// `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
/// (styles-themes-responsive.css:1630-1636).
Color _barrierColor(BuildContext context) {
  final solidUi =
      ProviderScope.containerOf(context).read(settingsProvider).solidUi;
  if (!solidUi) return Colors.black.withValues(alpha: 0.7);
  return context.nym.isLight
      ? const Color(0x73000000) // black @ 0.45
      : const Color(0xBF000000); // black @ 0.75
}

/// Shows a confirmation dialog. Resolves `true` on OK, `false` on Cancel/Esc.
///
/// When [checkboxLabel] is provided the result instead resolves to an
/// [AppConfirmResult] carrying `{confirmed, checked}` (mirrors the PWA's
/// checkbox-confirm shape). Use [showAppConfirmWithCheckbox] for that case so
/// the return type is precise.
Future<bool> showAppConfirm(
  BuildContext context,
  String message, {
  String? title,
  String okLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final res = await showDialog<AppDialogResult>(
    context: context,
    barrierColor: _barrierColor(context),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? 'Confirm',
      okLabel: okLabel,
      cancelLabel: cancelLabel,
      danger: danger,
    ),
  );
  return res?.confirmed ?? false;
}

/// Confirmation dialog with a checkbox row, resolving `{confirmed, checked}`
/// (the PWA's `showAppConfirm(msg, {checkboxLabel})`).
Future<AppConfirmResult> showAppConfirmWithCheckbox(
  BuildContext context,
  String message, {
  required String checkboxLabel,
  String? title,
  String okLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final res = await showDialog<AppDialogResult>(
    context: context,
    barrierColor: _barrierColor(context),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? 'Confirm',
      okLabel: okLabel,
      cancelLabel: cancelLabel,
      danger: danger,
      checkboxLabel: checkboxLabel,
    ),
  );
  return AppConfirmResult(
    confirmed: res?.confirmed ?? false,
    checked: res?.checked ?? false,
  );
}

/// Shows an alert with a single OK button (the PWA's `showAppAlert`).
Future<void> showAppAlert(
  BuildContext context,
  String message, {
  String? title,
  String okLabel = 'OK',
}) {
  return showDialog<void>(
    context: context,
    barrierColor: _barrierColor(context),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? 'Notice',
      okLabel: okLabel,
      alertOnly: true,
    ),
  );
}

/// Shows a prompt with a text field. Resolves the entered string on OK, or
/// `null` on Cancel/Esc (the PWA's `showAppPrompt`). [multiline] swaps the
/// single-line input for a 110px-min textarea; [maxLength] adds a live char
/// counter.
Future<String?> showAppPrompt(
  BuildContext context,
  String message, {
  String? title,
  String okLabel = 'OK',
  String cancelLabel = 'Cancel',
  String defaultValue = '',
  String placeholder = '',
  int? maxLength,
  bool multiline = false,
}) async {
  final res = await showDialog<AppDialogResult>(
    context: context,
    barrierColor: _barrierColor(context),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? 'Confirm',
      okLabel: okLabel,
      cancelLabel: cancelLabel,
      isPrompt: true,
      defaultValue: defaultValue,
      placeholder: placeholder,
      maxLength: maxLength,
      multiline: multiline,
    ),
  );
  if (res == null || !res.confirmed) return null;
  return res.value ?? '';
}

/// The resolved shape of [showAppConfirmWithCheckbox].
class AppConfirmResult {
  const AppConfirmResult({required this.confirmed, required this.checked});
  final bool confirmed;
  final bool checked;
}

/// Internal pop payload (so a single dialog can resolve confirm/checkbox/prompt).
class AppDialogResult {
  const AppDialogResult({required this.confirmed, this.checked = false, this.value});
  final bool confirmed;
  final bool checked;
  final String? value;
}

class _AppDialog extends StatefulWidget {
  const _AppDialog({
    required this.message,
    required this.title,
    required this.okLabel,
    this.cancelLabel = 'Cancel',
    this.danger = false,
    this.alertOnly = false,
    this.isPrompt = false,
    this.checkboxLabel,
    this.defaultValue = '',
    this.placeholder = '',
    this.maxLength,
    this.multiline = false,
  });

  final String message;
  final String title;
  final String okLabel;
  final String cancelLabel;
  final bool danger;
  final bool alertOnly;
  final bool isPrompt;
  final String? checkboxLabel;
  final String defaultValue;
  final String placeholder;
  final int? maxLength;
  final bool multiline;

  @override
  State<_AppDialog> createState() => _AppDialogState();
}

class _AppDialogState extends State<_AppDialog> {
  late final TextEditingController _input =
      TextEditingController(text: widget.defaultValue);
  final FocusNode _inputFocus = FocusNode();
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    // Repaint the `.form-input:focus` glow/fill when focus changes.
    _inputFocus.addListener(() => setState(() {}));
    // The PWA selects the whole default value on open so typing replaces it
    // (`field.focus(); field.select()` — dialog.js:127).
    if (widget.isPrompt) {
      _input.selection =
          TextSelection(baseOffset: 0, extentOffset: _input.text.length);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _ok() {
    Navigator.of(context).pop(AppDialogResult(
      confirmed: true,
      checked: _checked,
      value: widget.isPrompt ? _input.text : null,
    ));
  }

  void _cancel() {
    Navigator.of(context).pop(AppDialogResult(
      confirmed: false,
      checked: _checked,
      value: null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          // `.app-dialog-content { max-width: 440px }`.
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            color: Colors.transparent,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _cancel,
                if (!widget.multiline)
                  const SingleActivator(LogicalKeyboardKey.enter): _ok,
                if (!widget.multiline)
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): _ok,
              },
              child: Focus(
                autofocus: true,
                child: Container(
                  decoration: BoxDecoration(
                    color: c.bgSecondary,
                    borderRadius: NymRadius.rxl,
                    border: Border.all(color: c.glassBorder),
                    // `.modal-content` shadow stack: shadow-lg + shadow-glow +
                    // a 1px white/0.05 ring. Light mode replaces it with a
                    // single soft `0 8px 40px rgba(0,0,0,0.12)` — no glow, no
                    // ring (styles-themes-responsive.css:1050-1052).
                    boxShadow: c.isLight
                        ? const [
                            BoxShadow(
                              color: Color(0x1F000000), // black @ 0.12
                              blurRadius: 40,
                              offset: Offset(0, 8),
                            ),
                          ]
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.5),
                              blurRadius: 32,
                              offset: const Offset(0, 8),
                            ),
                            BoxShadow(
                              color: c.primaryA(0.1),
                              blurRadius: 20,
                            ),
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.05),
                              spreadRadius: 1,
                            ),
                          ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // `.modal-header` — 22px primary UPPERCASE ls1.5 w700,
                      // 1px glass bottom rule, padding-bottom 14, margin-bottom 24.
                      Container(
                        margin: const EdgeInsets.fromLTRB(32, 32, 32, 24),
                        padding: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: c.glassBorder),
                          ),
                        ),
                        child: Text(
                          widget.title.toUpperCase(),
                          style: TextStyle(
                            color: c.primary,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                      // `.modal-body { margin-bottom: 20px }`.
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(32, 0, 32, 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // `.app-dialog-message` — 14px / 1.45, pre-line.
                              Text(
                                widget.message,
                                style: TextStyle(
                                  color: c.text,
                                  fontSize: 14,
                                  height: 1.45,
                                ),
                              ),
                              if (widget.checkboxLabel != null)
                                _checkboxRow(c),
                              if (widget.isPrompt) _promptField(c),
                            ],
                          ),
                        ),
                      ),
                      // `.modal-actions` — display:flex; gap:10px;
                      // justify:center; `.app-dialog-content .modal-actions
                      // { margin-top: 8px }` on top of the body's 20px.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!widget.alertOnly) ...[
                              _cancelButton(c),
                              const SizedBox(width: 10),
                            ],
                            _okButton(c),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _checkboxRow(NymColors c) {
    // `.app-dialog-checkbox` — 12px top margin, 13px dim text, 8px gap.
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: InkWell(
        onTap: () => setState(() => _checked = !_checked),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: _checked,
                onChanged: (v) => setState(() => _checked = v ?? false),
                activeColor: c.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(widget.checkboxLabel!,
                  style: TextStyle(color: c.textDim, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _promptField(NymColors c) {
    final max = widget.maxLength;
    final focused = _inputFocus.hasFocus;
    final len = _input.text.length;
    // `.input-char-count` colors: limit (#ff4444) at 100%, warning (#f59e0b)
    // at 80%, else text-dim @0.6 base opacity.
    final Color counterColor;
    if (max != null && len >= max) {
      counterColor = c.danger;
    } else if (max != null && len >= max * 0.8) {
      counterColor = const Color(0xFFF59E0B);
    } else {
      counterColor = c.textDim.withValues(alpha: 0.6);
    }
    // Light mode forces `input { background: rgba(0,0,0,0.04); border-color:
    // rgba(0,0,0,0.1); color: #000000 } !important` (no focus fill lift),
    // while dark's global `input { color: #ffffff !important }` beats
    // `.form-input`'s `--text-bright`
    // (styles-themes-responsive.css:561-592, styles-components.css:229-255).
    final baseBorder = c.isLight ? const Color(0x1A000000) : c.glassBorder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // `.app-dialog-input` / `.app-dialog-textarea` — 12px top margin, with
        // the `.form-input:focus` glow ring (`0 0 0 3px primary/0.06`; light
        // mode `primary/0.1` — styles-themes-responsive.css:1087-1092).
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: NymRadius.rsm,
              boxShadow: focused
                  ? [
                      BoxShadow(
                        color: c.primaryA(c.isLight ? 0.1 : 0.06),
                        spreadRadius: 3,
                      ),
                    ]
                  : null,
            ),
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(minHeight: widget.multiline ? 110 : 0),
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                autofocus: true,
                maxLength: max,
                maxLines: widget.multiline ? null : 1,
                minLines: widget.multiline ? 4 : 1,
                expands: false,
                onChanged: (_) {
                  if (max != null) setState(() {});
                },
                onSubmitted: widget.multiline ? null : (_) => _ok(),
                buildCounter: (_,
                        {required currentLength,
                        required isFocused,
                        maxLength}) =>
                    null,
                style: TextStyle(
                  color: c.isLight
                      ? const Color(0xFF000000)
                      : const Color(0xFFFFFFFF),
                  fontSize: 15,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText:
                      widget.placeholder.isEmpty ? null : widget.placeholder,
                  hintStyle: TextStyle(color: c.textDim),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  filled: true,
                  // Dark: focus lifts the fill white/0.05 → white/0.07; light:
                  // black/0.04 `!important`, so the focus bump never applies.
                  fillColor: c.isLight
                      ? const Color(0x0A000000)
                      : Colors.white.withValues(alpha: focused ? 0.07 : 0.05),
                  border: OutlineInputBorder(
                    borderRadius: NymRadius.rsm,
                    borderSide: BorderSide(color: baseBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: NymRadius.rsm,
                    borderSide: BorderSide(color: baseBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: NymRadius.rsm,
                    borderSide: BorderSide(color: c.primaryA(0.3)),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (max != null)
          // `.input-char-count` — warning at 80%, limit at 100%.
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$len/$max',
                style: TextStyle(fontSize: 11, color: counterColor),
              ),
            ),
          ),
      ],
    );
  }

  /// `.icon-btn` Cancel — dark: bg white/0.05, glass border, `--text` label;
  /// light mode overrides to bg black/0.03, border black/0.1, `--primary`
  /// label (styles-themes-responsive.css:595-599). Radius 8 (`rxs`),
  /// UPPERCASE 12px w500 ls0.8, padding 7/14. `.modal-actions` has no
  /// `align-items`, so flex's default stretch sizes it to the 42px `.send-btn`
  /// beside it, label centered (`.icon-btn` is `inline-flex; align-items:
  /// center`).
  Widget _cancelButton(NymColors c) {
    return InkWell(
      onTap: _cancel,
      borderRadius: NymRadius.rxs,
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: c.subtleFill,
          border: Border.all(
            color: c.isLight
                ? const Color(0x1A000000) // black @ 0.1
                : c.glassBorder,
          ),
          borderRadius: NymRadius.rxs,
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            widget.cancelLabel.toUpperCase(),
            style: TextStyle(
              color: c.isLight ? c.primary : c.text,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ),
    );
  }

  /// `.send-btn` (translucent outline pill) — non-danger: bg primary/0.1,
  /// border primary/0.3, text `--primary`; danger: danger/0.1 + danger/0.35 +
  /// `--danger`. radius 12 (`rsm`), height 42, padding 22/10, UPPERCASE 12px
  /// w600 ls1.5.
  Widget _okButton(NymColors c) {
    final accent = widget.danger ? c.danger : c.primary;
    return InkWell(
      onTap: _ok,
      borderRadius: NymRadius.rsm,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.1),
          border: Border.all(
            color: accent.withValues(alpha: widget.danger ? 0.35 : 0.3),
          ),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          widget.okLabel.toUpperCase(),
          style: TextStyle(
            color: accent,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }
}
