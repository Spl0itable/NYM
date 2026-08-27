// PausableAnimatedImage: playback (frame delivery) must follow visibility —
// listening while on screen, detached (codec frozen) while scrolled away, and
// re-attached when scrolled back. Also covers the animated-format detection
// helpers in inline_network_image.dart.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:nym_bar/features/messages/inline_network_image.dart';
import 'package:nym_bar/features/messages/pausable_animated_image.dart';

/// A completer we control: exposes listener count and lets the test push
/// frames.
class _FakeCompleter extends ImageStreamCompleter {
  int listeners = 0;

  @override
  void addListener(ImageStreamListener listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    listeners--;
    super.removeListener(listener);
  }

  void pushFrame(ui.Image image) => setImage(ImageInfo(image: image.clone()));
}

class _FakeProvider extends ImageProvider<_FakeProvider> {
  _FakeProvider(this.completer);
  final _FakeCompleter completer;

  @override
  Future<_FakeProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FakeProvider>(this);

  @override
  ImageStreamCompleter loadImage(
          _FakeProvider key, ImageDecoderCallback decode) =>
      completer;
}

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('pauses frame delivery off screen and resumes when visible',
      (tester) async {
    final completer = _FakeCompleter();
    final provider = _FakeProvider(completer);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    final image = await tester.runAsync(() => createTestImage(width: 4));

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 400,
          child: ListView(
            controller: scroll,
            cacheExtent: 2000, // keep the item MOUNTED while scrolled away
            children: [
              PausableAnimatedImage(
                image: provider,
                visibilityKey: const ValueKey('gif-under-test'),
                width: 100,
                height: 100,
              ),
              const SizedBox(height: 3000),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // A delivered frame renders. (Counting only after the first frame: the
    // framework ImageCache holds its own tracking listener until then.)
    completer.pushFrame(image!);
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    expect(completer.listeners, 1,
        reason: 'visible → listening (codec driven)');

    // Scroll the image far off screen (still mounted via cacheExtent).
    scroll.jumpTo(1500);
    await tester.pump();
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump();
    expect(completer.listeners, 0,
        reason: 'off screen → detached, codec frozen');

    // Scroll back: playback resumes.
    scroll.jumpTo(0);
    await tester.pump();
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump();
    expect(completer.listeners, 1, reason: 'back on screen → re-attached');

    // Teardown must detach cleanly.
    await tester.pumpWidget(const SizedBox.shrink());
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump();
    expect(completer.listeners, 0);
  });

  testWidgets(
      'stays attached until the first frame when it materializes OFFSCREEN '
      '(the pause-before-load deadlock that broke GIF loading)',
      (tester) async {
    final completer = _FakeCompleter();
    final provider = _FakeProvider(completer);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    final image = await tester.runAsync(() => createTestImage(width: 4));

    // The image starts VISIBLE with its fetch still "in flight" (no frame
    // yet), then scrolls away before the first frame lands — exactly the
    // fast-scroll / route-change window that broke GIF loading.
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 400,
          child: ListView(
            controller: scroll,
            cacheExtent: 2000, // keep the item MOUNTED while scrolled away
            children: [
              PausableAnimatedImage(
                image: provider,
                visibilityKey: const ValueKey('offscreen-gif'),
                width: 100,
                height: 100,
              ),
              const SizedBox(height: 3000),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump();

    // Scrolled away BEFORE any frame was delivered.
    scroll.jumpTo(1500);
    await tester.pump();
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump();
    // The pause must be deferred: detaching now (nothing decoded, nothing to
    // pin) lets the framework dispose the completer and the image could
    // never load.
    expect(completer.listeners, greaterThan(0),
        reason: 'hidden but unloaded → must stay listening so the fetch '
            'and first decode can complete');

    // First frame arrives while still hidden → NOW it freezes (detaches).
    completer.pushFrame(image!);
    await tester.pump();
    expect(completer.listeners, 0,
        reason: 'first frame landed while hidden → frozen on it');

    // Scrolling it into view resumes playback and shows the frame.
    scroll.jumpTo(0);
    await tester.pump();
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump();
    expect(completer.listeners, 1, reason: 'back on screen → re-attached');
    expect(find.byType(RawImage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump();
    expect(completer.listeners, 0);
  });

  test('isAnimatedImageUrl matches gif/apng incl. the proxied url= form', () {
    expect(isAnimatedImageUrl('https://x.test/a.gif'), isTrue);
    expect(isAnimatedImageUrl('https://x.test/a.GIF?x=1'), isTrue);
    expect(isAnimatedImageUrl('https://x.test/a.apng'), isTrue);
    expect(
        isAnimatedImageUrl(
            'https://p.test/api/proxy?url=${Uri.encodeComponent('https://x.test/b.gif')}'),
        isTrue);
    expect(isAnimatedImageUrl('https://x.test/a.png'), isFalse);
    expect(isAnimatedImageUrl('https://x.test/a.webp'), isFalse);
    expect(isAnimatedImageUrl(''), isFalse);
  });

  test('looksAnimatedImageBytes sniffs GIF and animated WebP only', () {
    Uint8List gif() => Uint8List.fromList('GIF89a'.codeUnits);
    Uint8List webp({required bool animated}) {
      final b = Uint8List(30);
      b.setAll(0, 'RIFF'.codeUnits);
      b.setAll(8, 'WEBPVP8X'.codeUnits);
      b[20] = animated ? 0x02 : 0x00;
      return b;
    }

    expect(looksAnimatedImageBytes(gif()), isTrue);
    expect(looksAnimatedImageBytes(webp(animated: true)), isTrue);
    expect(looksAnimatedImageBytes(webp(animated: false)), isFalse);
    expect(
        looksAnimatedImageBytes(
            Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), // PNG
        isFalse);
  });
}
