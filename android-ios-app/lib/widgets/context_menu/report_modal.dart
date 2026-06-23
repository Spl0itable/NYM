import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// `#reportModal` (index.html lines 361-405; ui-context.js `openReportModal` /
/// `submitReport`). Report a user/content: a type select + optional details +
/// a "report specific message" checkbox.
///
/// UI only — submitting builds the NIP-56 kind-1984 report the PWA does, but the
/// signing/relay path is owned by another slice, so [onSubmit] is invoked with
/// the form values and the actual publish is a labelled TODO for the caller.
class ReportModal extends StatefulWidget {
  const ReportModal({
    super.key,
    required this.targetNym,
    this.hasMessage = false,
    this.onSubmit,
  });

  /// The full `base#suffix` nym being reported (shown in the body).
  final String targetNym;

  /// Whether a specific message can be reported (enables the checkbox).
  final bool hasMessage;

  /// Called with (type, details, reportMessage) on Submit.
  final void Function(String type, String details, bool reportMessage)? onSubmit;

  /// Report types, in the PWA's `#reportType` option order.
  static const types = <(String, String)>[
    ('nudity', 'Nudity - depictions of nudity, porn, etc.'),
    ('malware', 'Malware - virus, trojan, spyware, etc.'),
    ('profanity', 'Profanity - hateful speech, etc.'),
    ('illegal', 'Illegal - content that may be illegal'),
    ('spam', 'Spam'),
    ('impersonation', 'Impersonation - pretending to be someone else'),
    ('other', 'Other'),
  ];

  static Future<void> show(
    BuildContext context, {
    required String targetNym,
    bool hasMessage = false,
    void Function(String type, String details, bool reportMessage)? onSubmit,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: const Color(0xB3000000),
      builder: (_) => ReportModal(
        targetNym: targetNym,
        hasMessage: hasMessage,
        onSubmit: onSubmit,
      ),
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
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        width: MediaQuery.of(context).size.width * 0.9,
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxl,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('REPORT USER/CONTENT',
                  style: TextStyle(
                      color: c.primary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5)),
              const SizedBox(height: 16),
              Text.rich(TextSpan(children: [
                TextSpan(
                    text: 'Reporting: ',
                    style: TextStyle(color: c.text, fontSize: 13)),
                TextSpan(
                    text: widget.targetNym,
                    style: TextStyle(color: c.primary, fontSize: 13)),
              ])),
              const SizedBox(height: 16),
              Text('Report Type:',
                  style: TextStyle(color: c.textDim, fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  border: Border.all(color: c.glassBorder),
                  borderRadius: NymRadius.rsm,
                ),
                child: DropdownButton<String>(
                  value: _type,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  dropdownColor: c.bgSecondary,
                  style: TextStyle(color: c.textBright, fontSize: 13),
                  items: [
                    for (final t in ReportModal.types)
                      DropdownMenuItem(value: t.$1, child: Text(t.$2)),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? _type),
                ),
              ),
              const SizedBox(height: 16),
              Text('Additional Details (optional):',
                  style: TextStyle(color: c.textDim, fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: _details,
                maxLines: 4,
                style: TextStyle(color: c.textBright, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Provide any additional context for this report...',
                  hintStyle: TextStyle(color: c.textDim),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                    borderRadius: NymRadius.rsm,
                    borderSide: BorderSide(color: c.glassBorder),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Checkbox(
                    value: _reportMessage,
                    onChanged: widget.hasMessage
                        ? (v) => setState(() => _reportMessage = v ?? false)
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      'Report specific message (if unchecked, reports the user profile)',
                      style: TextStyle(color: c.textDim, fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _btn(c, 'Cancel', primary: false,
                      onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 10),
                  _btn(c, 'Submit Report', primary: true, onTap: () {
                    // TODO(verify): publish NIP-56 kind-1984 report. The PWA's
                    // submitReport signs `{kind:1984, tags:[['p',pubkey,type],
                    // ['e',messageId,type]?], content:details}` and sends it to
                    // relays; signing/relay is owned by another slice, so we
                    // surface the form values via onSubmit instead.
                    widget.onSubmit
                        ?.call(_type, _details.text, _reportMessage);
                    Navigator.of(context).maybePop();
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _btn(NymColors c, String label,
      {required bool primary, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary
              ? c.primary.withValues(alpha: 0.1)
              : Colors.white.withValues(alpha: 0.04),
          border: Border.all(
              color: primary ? c.primary.withValues(alpha: 0.3) : c.glassBorder),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: primary ? c.primary : c.textDim,
            fontSize: 12,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
