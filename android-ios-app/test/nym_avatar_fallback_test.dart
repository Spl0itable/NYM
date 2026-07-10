// A remote kind-0 `picture` avatar must load with the PWA's proxied→raw
// fallback: NymAvatar renders it through [InlineNetworkImage] with the PROXIED
// URL as the primary source and the RAW original as a fallback mirror, so an
// avatar whose host blocks/rate-limits the media proxy still loads directly —
// the reason many users' avatars render in the PWA but not natively
// (AVATAR-LOADING). Absent/empty pictures paint the identicon with no fetch.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/messages/inline_network_image.dart';
import 'package:nym_bar/widgets/common/nym_avatar.dart';

/// [HttpOverrides] whose client fails every request immediately, so the
/// InlineNetworkImage http path resolves to its fallback without real network
/// and without leaving a pending timeout timer. (These tests use `.svg` URLs,
/// which take the in-memory http path — never flutter_cache_manager/sqflite —
/// keeping the widget test hermetic.) The assertions below inspect the stable
/// InlineNetworkImage widget configuration, independent of the fetch outcome.
class _FailingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FailingHttpClient();
}

class _FailingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      Future<HttpClientRequest>.error(const SocketException('blocked in test'));
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('remote avatar routes through InlineNetworkImage with a raw '
      'fallback mirror', (tester) async {
    const rawUrl = 'https://cdn.example/alice.svg';
    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(_wrap(const NymAvatar(
        seed: 'pk_alice',
        size: 32,
        imageUrl: rawUrl,
      )));
      await tester.pump();

      final finder = find.byType(InlineNetworkImage);
      expect(finder, findsOneWidget,
          reason: 'remote avatars must render through InlineNetworkImage');
      final img = tester.widget<InlineNetworkImage>(finder);

      // Primary source is the PROXIED URL (privacy-preserving, like the PWA).
      expect(img.url.contains('/api/proxy?'), isTrue,
          reason: 'primary source should be the media-proxy URL');
      expect(img.url.contains(Uri.encodeComponent(rawUrl)), isTrue);

      // …with the RAW original as the fallback mirror tried on proxy failure —
      // the fix for hosts that block/rate-limit the proxy.
      expect(img.fallbackUrls, <String>[rawUrl],
          reason: 'raw direct URL must be the proxied load\'s fallback');

      // Drain the (failing) fetch so no work is left pending.
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }, createHttpClient: (c) => _FailingHttpOverrides().createHttpClient(c));
  });

  testWidgets('no picture → identicon fallback, never a network image',
      (tester) async {
    await tester.pumpWidget(_wrap(const NymAvatar(seed: 'pk_none', size: 32)));
    await tester.pump();
    expect(find.byType(InlineNetworkImage), findsNothing,
        reason: 'a pictureless user paints the identicon with no network fetch');
    expect(find.byType(NymAvatar), findsOneWidget);
  });

  testWidgets('empty picture string is treated as no picture', (tester) async {
    await tester.pumpWidget(
        _wrap(const NymAvatar(seed: 'pk_empty', size: 32, imageUrl: '')));
    await tester.pump();
    expect(find.byType(InlineNetworkImage), findsNothing);
  });
}
