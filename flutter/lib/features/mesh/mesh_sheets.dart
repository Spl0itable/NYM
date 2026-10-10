import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../widgets/common/keyboard_inset_dialog.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/dialog_button.dart';
import '../identity/modal_chrome.dart';

Future<T?> showMeshSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showNymSheet<T>(
    context,
    builder,
    barrierColor: Colors.black.withValues(alpha: 0.7),
  );
}

class MeshSheetFrame extends StatelessWidget {
  const MeshSheetFrame({
    super.key,
    required this.title,
    required this.children,
    required this.actions,
  });

  final String title;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            color: c.primary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 16),
        ...children,
        const SizedBox(height: 20),
        DialogActions(alignment: WrapAlignment.end, children: actions),
      ],
    );
    return nymSheetOr(
      context,
      SingleChildScrollView(
        padding: ModalChrome.sheetPadding,
        child: column,
      ),
      (_) => KeyboardInsetDialog(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Material(
              color: Colors.transparent,
              child: ModalChrome.box(
                c,
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: column,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
