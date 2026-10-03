import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/secret_screen.dart';
import '../../features/i18n/i18n.dart';
import '../../features/toasts/toast_center.dart';
import '../../state/settings_provider.dart';
import 'keyboard_inset_dialog.dart';

/// Shared confirm, alert and prompt dialogs, the native port of the PWA's `dialog.js`.

Color _barrierColor(BuildContext context) {
  final solidUi =
      ProviderScope.containerOf(context).read(settingsProvider).solidUi;
  if (!solidUi) return Colors.black.withValues(alpha: 0.7);
  return context.nym.isLight
      ? const Color(0x73000000)
      : const Color(0xBF000000);
}

/// Resolves `true` on OK, `false` on Cancel/Esc; use [showAppConfirmWithCheckbox] for the checkbox variant.
Future<bool> showAppConfirm(
  BuildContext context,
  String message, {
  String? title,
  String? okLabel,
  String? cancelLabel,
  bool danger = false,
}) async {
  final res = await showDialog<AppDialogResult>(
    context: context,
    barrierColor: _barrierColor(context),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? tr('Confirm'),
      okLabel: okLabel ?? tr('OK'),
      cancelLabel: cancelLabel ?? tr('Cancel'),
      danger: danger,
    ),
  );
  return res?.confirmed ?? false;
}

Future<AppConfirmResult> showAppConfirmWithCheckbox(
  BuildContext context,
  String message, {
  required String checkboxLabel,
  String? title,
  String? okLabel,
  String? cancelLabel,
  bool danger = false,
}) async {
  final res = await showDialog<AppDialogResult>(
    context: context,
    barrierColor: _barrierColor(context),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? tr('Confirm'),
      okLabel: okLabel ?? tr('OK'),
      cancelLabel: cancelLabel ?? tr('Cancel'),
      danger: danger,
      checkboxLabel: checkboxLabel,
    ),
  );
  return AppConfirmResult(
    confirmed: res?.confirmed ?? false,
    checked: res?.checked ?? false,
  );
}

/// [copyValue] adds a selectable monospace row with a Copy button for the value the alert is about.
Future<void> showAppAlert(
  BuildContext context,
  String message, {
  String? title,
  String? okLabel,
  String? copyValue,
  String? copyLabel,
  String? copiedMessage,
  bool secret = false,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: _barrierColor(context),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? tr('Notice'),
      okLabel: okLabel ?? tr('OK'),
      alertOnly: true,
      copyValue: copyValue,
      copyLabel: copyLabel,
      copiedMessage: copiedMessage,
      secret: secret,
    ),
  );
}

/// Resolves the entered string on OK or `null` on Cancel/Esc; [maxLength] adds a live char counter.
Future<String?> showAppPrompt(
  BuildContext context,
  String message, {
  String? title,
  String? okLabel,
  String? cancelLabel,
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
      title: title ?? tr('Confirm'),
      okLabel: okLabel ?? tr('OK'),
      cancelLabel: cancelLabel ?? tr('Cancel'),
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

class AppConfirmResult {
  const AppConfirmResult({required this.confirmed, required this.checked});
  final bool confirmed;
  final bool checked;
}

class AppDialogResult {
  const AppDialogResult(
      {required this.confirmed, this.checked = false, this.value});
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
    this.copyValue,
    this.copyLabel,
    this.copiedMessage,
    this.secret = false,
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
  final String? copyValue;
  final String? copyLabel;
  final String? copiedMessage;
  final bool secret;

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
    _inputFocus.addListener(() => setState(() {}));
    // Select the whole default value on open so typing replaces it, as the PWA does.
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
    // Keeps prompt fields above the soft keyboard on mobile.
    return KeyboardInsetDialog(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
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
                    boxShadow: c.isLight
                        ? const [
                            BoxShadow(
                              color: Color(0x1F000000),
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
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(32, 0, 32, 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.message,
                                style: TextStyle(
                                  color: c.text,
                                  fontSize: 14,
                                  height: 1.45,
                                ),
                              ),
                              if (widget.copyValue != null) _copyRow(c),
                              if (widget.checkboxLabel != null) _checkboxRow(c),
                              if (widget.isPrompt) _promptField(c),
                            ],
                          ),
                        ),
                      ),
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

  Widget _copyRow(NymColors c) {
    final value = widget.copyValue ?? '';
    final row = Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: c.glassBorder),
              ),
              child: widget.secret
                  ? Text(
                      value,
                      key: const Key('appDialogSecretValue'),
                      style: TextStyle(
                        color: c.primary,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    )
                  : SelectableText(
                      value,
                      style: TextStyle(
                        color: c.primary,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
              if (widget.secret) {
                SecretScreen.copy(value);
              } else {
                Clipboard.setData(ClipboardData(text: value));
              }
              final msg = widget.copiedMessage;
              if (msg != null) {
                showToast(msg);
              }
            },
            style: TextButton.styleFrom(
              foregroundColor: c.secondary,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(widget.copyLabel ?? tr('Copy'),
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
    return widget.secret ? SecretGuard(child: row) : row;
  }

  Widget _checkboxRow(NymColors c) {
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
    final Color counterColor;
    if (max != null && len >= max) {
      counterColor = c.danger;
    } else if (max != null && len >= max * 0.8) {
      counterColor = const Color(0xFFF59E0B);
    } else {
      counterColor = c.textDim.withValues(alpha: 0.6);
    }
    // Light mode forces the input fill with `!important`, so there is no focus fill lift.
    final baseBorder = c.isLight ? const Color(0x1A000000) : c.glassBorder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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

  /// Cancel `.icon-btn`; flex's default stretch sizes it to the 42px OK button beside it.
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
                ? const Color(0x1A000000)
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
