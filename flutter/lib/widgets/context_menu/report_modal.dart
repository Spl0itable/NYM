import 'package:flutter/material.dart';
import '../common/keyboard_inset_dialog.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/i18n/i18n.dart';
import '../common/nym_sheet.dart';
import '../common/nym_field.dart';

/// Report modal; [onSubmit] is wired to the NIP-56 kind-1984 report publish.
class ReportModal extends StatefulWidget {
  const ReportModal({
    super.key,
    required this.targetNym,
    this.hasMessage = false,
    this.onSubmit,
  });

  final String targetNym;

  final bool hasMessage;

  final void Function(String type, String details, bool reportMessage)?
      onSubmit;

  static const types = <(String, String)>[
    ('nudity', 'Nudity - depictions of nudity, porn, etc.'),
    ('malware', 'Malware - virus, trojan, spyware, etc.'),
    ('profanity', 'Profanity - hateful speech, etc.'),
    ('illegal', 'Illegal - content that may be illegal'),
    ('spam', 'Spam'),
    ('impersonation', 'Impersonation - pretending to be someone else'),
    ('other', 'Other'),
  ];

  static Future<bool?> show(
    BuildContext context, {
    required String targetNym,
    bool hasMessage = false,
    void Function(String type, String details, bool reportMessage)? onSubmit,
  }) {
    return showNymSheet<bool>(
      context,
      (_) => ReportModal(
        targetNym: targetNym,
        hasMessage: hasMessage,
        onSubmit: onSubmit,
      ),
      barrierColor: const Color(0xB3000000),
    );
  }

  @override
  State<ReportModal> createState() => _ReportModalState();
}

class _ReportModalState extends State<ReportModal> {
  String _type = ReportModal.types.first.$1;
  final _details = TextEditingController();
  late bool _reportMessage = widget.hasMessage;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final body = Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 24),
                  padding: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: c.glassBorder)),
                  ),
                  child: Text(tr('REPORT USER/CONTENT'),
                      style: TextStyle(
                          color: c.primary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5)),
                ),
                Text.rich(TextSpan(children: [
                  TextSpan(
                      text: tr('Reporting: '),
                      style: TextStyle(color: c.textDim, fontSize: 15)),
                  TextSpan(
                      text: widget.targetNym,
                      style: TextStyle(color: c.primary, fontSize: 15)),
                ])),
                const SizedBox(height: 15),
                Text(tr('Report Type:'),
                    style: TextStyle(color: c.textDim, fontSize: 15)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: c.insetFill,
                    border: Border.all(color: c.insetBorder),
                    borderRadius: NymRadius.rsm,
                  ),
                  child: DropdownButton<String>(
                    value: _type,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    dropdownColor: c.bgSecondary,
                    style: TextStyle(color: c.text, fontSize: 15),
                    items: [
                      for (final t in ReportModal.types)
                        DropdownMenuItem(
                            value: t.$1, child: Text(tr(t.$2))),
                    ],
                    onChanged: (v) => setState(() => _type = v ?? _type),
                  ),
                ),
                const SizedBox(height: 20),
                Text.rich(TextSpan(
                  text: tr('Additional Details'),
                  style: TextStyle(color: c.textDim, fontSize: 15),
                  children: [
                    TextSpan(
                      text: tr(' (optional)'),
                      style: const TextStyle(
                          fontWeight: FontWeight.w400, letterSpacing: 0),
                    ),
                    const TextSpan(text: ':'),
                  ],
                )),
                const SizedBox(height: 10),
                TextField(
                  controller: _details,
                  maxLines: 4,
                  style: TextStyle(color: c.inputText, fontSize: 15),
                  decoration: NymField.decoration(c,
                        hint: tr(
                            'Provide any additional context for this report...'),
                        contentPadding: const EdgeInsets.all(10)),
                ),
                const SizedBox(
                    height: 15),
                InkWell(
                  onTap: widget.hasMessage
                      ? () =>
                          setState(() => _reportMessage = !_reportMessage)
                      : null,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          value: _reportMessage,
                          onChanged: widget.hasMessage
                              ? (v) => setState(
                                  () => _reportMessage = v ?? false)
                              : null,
                          activeColor: c.primary,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tr('Report specific message (if unchecked, reports the user profile)'),
                          style: TextStyle(color: c.textDim, fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _cancelBtn(c),
                    const SizedBox(width: 10),
                    _submitBtn(c),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            top: -18,
            right: -18,
            child: _closeButton(c),
          ),
        ],
      ),
    );
    return NymDiscardGuard(
      isDirty: () => _details.text.trim().isNotEmpty,
      child: nymSheetOr(
        context,
        Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 20), child: body),
        (body) => KeyboardInsetDialog(
          child: Container(
            constraints: BoxConstraints(
              maxWidth: 500,
              maxHeight: MediaQuery.of(context).size.height * 0.9,
            ),
            width: MediaQuery.of(context).size.width * 0.9,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: c.bgSecondary,
              border: Border.all(color: c.glassBorder),
              borderRadius: NymRadius.rxl,
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
                      BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
                      BoxShadow(
                          color: Colors.white.withValues(alpha: 0.05),
                          spreadRadius: 1),
                    ],
            ),
            child: body,
          ),
        ),
      ),
    );
  }

  void _submit() {
    widget.onSubmit?.call(_type, _details.text, _reportMessage);
    Navigator.of(context).pop(true);
  }

  Widget _closeButton(NymColors c) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(),
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.subtleFill,
          border: Border.all(color: c.glassBorder),
        ),
        child: Icon(Icons.close, size: 16, color: c.textDim),
      ),
    );
  }

  Widget _cancelBtn(NymColors c) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(),
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: c.subtleFill,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxs,
        ),
        child: Text(
          tr('CANCEL'),
          style: TextStyle(
            color: c.isLight ? c.primary : c.text,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  Widget _submitBtn(NymColors c) {
    return InkWell(
      onTap: _submit,
      borderRadius: NymRadius.rsm,
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.primaryA(0.1),
          border: Border.all(color: c.primaryA(0.3)),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          tr('SUBMIT REPORT'),
          style: TextStyle(
            color: c.primary,
            fontSize: 12,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
