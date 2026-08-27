// Reproduction harness for the startup lag: the emulator logs show a per-frame
// exception storm rooted in the custom-emoji WidgetSpan machinery —
//   * iOS:  "RenderBox.size accessed beyond the scope of resize, layout, or
//           permitted parent access ... in _RenderEmojiBaselineDrop.performLayout"
//           and 167× "widget_span.dart ... 'dimensions != null'"
//   * Android: "'!_debugDoingThisLayout': is not true" + endless
//           "RenderBox was not laid out" cascades inside the message list.
// These tests pump the same widget structure the message rows / composer use
// (baseline-aligned WidgetSpan → Padding → EmojiBaselineDrop → child that
// SWAPS SIZE when the image future resolves) and fail on any framework
// exception.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/messages/inline_network_image.dart';

/// A stand-in for [InlineNetworkImage]: resolves like its FutureBuilder — a
/// placeholder [SizedBox] first, then swaps to the "loaded" child a frame
/// later, changing the subtree's render objects (and possibly size).
class _FakeAsyncImage extends StatefulWidget {
  const _FakeAsyncImage({required this.side});
  final double side;

  @override
  State<_FakeAsyncImage> createState() => _FakeAsyncImageState();
}

class _FakeAsyncImageState extends State<_FakeAsyncImage> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return SizedBox(width: widget.side, height: widget.side);
    return SizedBox(
      width: widget.side,
      height: widget.side,
      child: const ColoredBox(color: Colors.red),
    );
  }
}

InlineSpan _emojiSpan(double fontSize, {Widget? child}) {
  final side = fontSize * 1.75;
  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: EmojiBaselineDrop(
        drop: fontSize * 0.375,
        child: child ?? _FakeAsyncImage(side: side),
      ),
    ),
  );
}

/// The bubble wrapper from message_row.dart: LayoutBuilder → ConstrainedBox
/// (minWidth 180 / maxWidth 85%) → Padding → Stack+Column shrink-wrap.
Widget _bubble(Widget body) {
  return LayoutBuilder(builder: (context, box) {
    final capW = (box.maxWidth * 0.85).clamp(180.0, double.infinity);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: 180, maxWidth: capW),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [body],
            ),
          ],
        ),
      ),
    );
  });
}

void main() {
  testWidgets('baseline emoji span in a bubble list survives image load',
      (tester) async {
    const fontSize = 14.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            reverse: true,
            children: [
              for (var i = 0; i < 5; i++)
                RepaintBoundary(
                  child: _bubble(
                    Text.rich(
                      TextSpan(children: [
                        const TextSpan(
                            text: 'hello ',
                            style: TextStyle(fontSize: fontSize)),
                        _emojiSpan(fontSize),
                        const TextSpan(
                            text: ' world',
                            style: TextStyle(fontSize: fontSize)),
                      ]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // Let the fake image "load" (subtree swap) and settle several frames —
    // the log storm is per-frame, so any corruption shows up here.
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('baseline emoji span inside an EditableText (composer path)',
      (tester) async {
    final controller = TextEditingController(text: 'hi  there');
    addTearDown(controller.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _ComposerLike(controller: controller, focus: focus),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Type more text to force re-layout passes with the placeholder present.
    controller.text = 'hi  there and more text that wraps the line';
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('emoji span whose EmojiBaselineDrop drop value changes',
      (tester) async {
    // The drop setter calls markNeedsLayout() — make sure a text-size change
    // mid-flight doesn't corrupt the paragraph's placeholder layout.
    for (final fontSize in [14.0, 18.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _bubble(
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: 'resize ', style: TextStyle(fontSize: fontSize)),
                  _emojiSpan(fontSize,
                      child: SizedBox(
                          width: fontSize * 1.75, height: fontSize * 1.75)),
                ]),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });
}

/// Minimal analogue of the composer's WYSIWYG field: a [TextField] whose
/// controller replaces the  sentinel with the emoji WidgetSpan, exactly
/// like `_SentinelEditingController.buildTextSpan` (composer.dart).
class _ComposerLike extends StatelessWidget {
  const _ComposerLike({required this.controller, required this.focus});
  final TextEditingController controller;
  final FocusNode focus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _SentinelController(controller.text),
      focusNode: focus,
      maxLines: null,
      style: const TextStyle(fontSize: 16),
    );
  }
}

class _SentinelController extends TextEditingController {
  _SentinelController(String text) : super(text: text);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle(fontSize: 16);
    final fontSize = base.fontSize ?? 16;
    final side = fontSize * 1.4;
    final children = <InlineSpan>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isEmpty) return;
      children.add(TextSpan(text: buf.toString(), style: base));
      buf.clear();
    }

    for (final rune in text.runes) {
      if (rune == 0xE000) {
        flush();
        children.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: EmojiBaselineDrop(
              drop: fontSize * 0.3,
              child: _FakeAsyncImage(side: side),
            ),
          ),
        ));
      } else {
        buf.write(String.fromCharCode(rune));
      }
    }
    flush();
    return TextSpan(style: base, children: children);
  }
}
