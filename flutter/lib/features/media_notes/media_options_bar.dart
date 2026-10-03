import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../widgets/chat/composer_format.dart';
import '../i18n/i18n.dart';
import 'media_notes.dart';
import 'view_once_card.dart' show kOnceComposerNote;

String mediaOptionsSizeLine(List<ComposerAttachment> list, bool hd) {
  var orig = 0;
  var comp = 0;
  var known = true;
  var anyImage = false;
  for (final a in list) {
    final o = a.originalSize;
    if (o == null) {
      known = false;
      continue;
    }
    orig += o;
    comp += a.compressedSize ?? o;
    if (!a.isVideo) anyImage = true;
  }
  final size = known ? formatBytes(hd ? orig : comp) : '…';
  final other =
      known && anyImage && orig != comp ? formatBytes(hd ? comp : orig) : '';
  if (other.isNotEmpty) {
    return tr('{size} (the other option: {other})', {'size': size, 'other': other});
  }
  if (anyImage || !known) return size;
  return tr('{size} · videos are sent as they are', {'size': size});
}

class MediaOptionsBar extends StatelessWidget {
  const MediaOptionsBar({
    super.key,
    required this.attachments,
    required this.hd,
    required this.once,
    required this.hdState,
    required this.onceState,
    required this.onToggleHd,
    required this.onToggleOnce,
  });

  final List<ComposerAttachment> attachments;
  final bool hd;
  final bool once;
  final MediaFeatureState hdState;
  final MediaFeatureState onceState;
  final VoidCallback onToggleHd;
  final VoidCallback onToggleOnce;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    Widget chip({
      required Key key,
      required bool on,
      required Widget leading,
      required String label,
      required VoidCallback onTap,
    }) =>
        Semantics(
          button: true,
          toggled: on,
          child: InkWell(
            key: key,
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: on ? c.primaryA(0.12) : null,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: on ? c.primary : c.glassBorder),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                leading,
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(color: on ? c.primary : c.text, fontSize: 12)),
              ]),
            ),
          ),
        );
    return Padding(
      key: const ValueKey('mediaOptionsBar'),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          chip(
            key: const ValueKey('mediaOptHd'),
            on: hd,
            leading: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                border: Border.all(color: hd ? c.primary : c.text),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('HD',
                  style: TextStyle(
                      color: hd ? c.primary : c.text,
                      fontSize: 10,
                      fontWeight: FontWeight.w800)),
            ),
            label: hd ? tr('HD · original quality') : tr('Standard quality'),
            onTap: onToggleHd,
          ),
          Text(mediaOptionsSizeLine(attachments, hd),
              key: const ValueKey('mediaOptSize'),
              style: TextStyle(
                  color: c.textDim,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          if (onceState.level != MediaFeatureLevel.off)
            chip(
              key: const ValueKey('mediaOptOnce'),
              on: once,
              leading: Icon(Icons.looks_one_outlined,
                  size: 16, color: once ? c.primary : c.text),
              label: tr('View once'),
              onTap: onToggleOnce,
            ),
          if (hd && hdState.level == MediaFeatureLevel.warn)
            SizedBox(
              width: double.infinity,
              child: Text(tr(hdState.reason),
                  style: TextStyle(color: c.textDim, fontSize: 11)),
            ),
          if (once)
            SizedBox(
              width: double.infinity,
              child: Text(tr(kOnceComposerNote),
                  key: const ValueKey('mediaOptOnceNote'),
                  style: TextStyle(color: c.textDim, fontSize: 11)),
            ),
        ],
      ),
    );
  }
}
