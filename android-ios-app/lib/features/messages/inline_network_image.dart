// Robust inline network-image rendering for message bodies + emoji.
//
// `cached_network_image` (and the underlying `ImageDecoder`) can only decode the
// raster formats Skia/Impeller support (PNG/JPEG/GIF/WebP/BMP). NIP-30 custom
// emoji and inline media URLs in the wild are frequently **SVG** (and
// occasionally AVIF / animated-WebP), which surface as `ImageDecoder
// unimplemented` when fed to `Image.network`/`CachedNetworkImage`.
//
// CRITICAL: flutter_svg's network/memory widgets do NOT route a *parse/compile*
// failure to `placeholderBuilder` — a non-SVG response (a proxy 403/404 HTML
// page) OR an SVG whose features its strict compiler rejects (browsers render
// the same file leniently) throws an UNHANDLED async `Bad state: Invalid SVG
// data`. Multiplied across a gridful of emoji (the picker) those repeated
// failures exhaust the heap and CRASH the app. So for SVG-looking URLs we fetch
// the bytes, then PRE-COMPILE them through `vg.loadPicture` inside a try/catch
// (caching the result): only a successfully-compiled picture is ever drawn, a
// misadvertised raster falls back to `Image.memory`, and anything else degrades
// to [errorChild]. No bad data ever reaches the parser at paint time.
//
// URLs are expected to be ALREADY proxied by the caller.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

/// True when [url] looks like an SVG (by extension, ignoring any query string),
/// including the proxied form `…/api/proxy?url=<encoded …/foo.svg>`.
bool isSvgUrl(String url) {
  if (url.isEmpty) return false;
  final lower = url.toLowerCase();
  if (RegExp(r'\.svg(\?|#|$)').hasMatch(lower)) return true;
  final q = Uri.tryParse(url)?.queryParameters['url'];
  if (q != null && RegExp(r'\.svg(\?|#|$)').hasMatch(q.toLowerCase())) {
    return true;
  }
  return false;
}

/// The decoded result for an SVG-looking URL: a compiled vector [picture] (+ its
/// intrinsic [size]) when it parsed, or raw [raster] bytes when the response was
/// actually a raster image. Null overall ⇒ fetch failed / undecodable.
class _Decoded {
  const _Decoded.svg(this.picture, this.size) : raster = null;
  const _Decoded.raster(this.raster)
      : picture = null,
        size = ui.Size.zero;
  final ui.Picture? picture;
  final ui.Size size;
  final Uint8List? raster;
}

/// A network image that transparently handles SVG and degrades to [errorChild]
/// (or a sensible default) when the bytes can't be fetched or decoded — without
/// ever throwing to the framework.
class InlineNetworkImage extends StatefulWidget {
  const InlineNetworkImage({
    super.key,
    required this.url,
    this.fallbackUrls = const [],
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorChild,
    this.memoryOnly = false,
    this.retryOnError = false,
  });

  /// Already-proxied image URL.
  final String url;

  /// NIP-92 imeta Blossom mirror URLs (already proxied, like [url]). When the
  /// current source fails to load, the next mirror is swapped in before any
  /// [errorChild]/retry — the PWA's `data-media-fallbacks` img handler
  /// (`_attachMediaFallbacks`, messages.js:1154-1163), which sets `img.src`
  /// to the next mirror on each `error` event.
  final List<String> fallbackUrls;

  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorChild;

  /// Skip the `cached_network_image` / `flutter_cache_manager` disk cache and
  /// render through the in-memory `http` + `Image.memory` path instead. Set this
  /// for EMOJI: a gridful of custom-emoji cells (the picker) or an emoji-heavy
  /// conversation would otherwise fire dozens of concurrent writes at
  /// flutter_cache_manager's sqflite DB, which serialises them behind a
  /// transaction and floods the log with "database has been locked for
  /// 0:00:10.000000" warnings (and can wedge the app). Emoji are small and
  /// repeat heavily, so the in-memory [_cache] + framework image cache covers
  /// them with zero disk I/O. Leave false for large one-off media, which benefit
  /// from the on-disk cache.
  final bool memoryOnly;

  /// Retry a failed load up to 2 more times with a cache-busting `_r=N` query
  /// param at an 800ms·n backoff — the PWA's custom-emoji `error` handler
  /// (inline-bindings.js:166-183), which re-fetches so a transient CDN miss
  /// gets a chance to populate the long-lived edge cache. The PWA only does
  /// this for `img.custom-emoji`, so set it for EMOJI call sites and leave it
  /// false for general inline media.
  final bool retryOnError;

  /// URL → decoded SVG/raster (cached so a grid of repeats + rebuilds share one
  /// fetch+compile and bad URLs aren't retried into a crash loop).
  static final Map<String, Future<_Decoded?>> _cache = {};

  static Future<_Decoded?> _decode(String url) {
    // Return the SAME cached Future every call. The old code wrapped the cached
    // future in a fresh `.then(...)` per call, so each rebuild handed the
    // FutureBuilder a NEW Future → it reset to the placeholder and re-ran → a
    // visible placeholder↔image flicker ("constantly reloading") whenever the
    // surrounding widget rebuilt. A stable Future keeps the FutureBuilder settled.
    final cached = _cache[url];
    if (cached != null) return cached;
    // Bound the cache at INSERT time (drop the oldest), not in a per-call `.then`.
    if (_cache.length > 1024) _cache.remove(_cache.keys.first);
    final fut = _fetchAndDecode(url);
    _cache[url] = fut;
    return fut;
  }

  static Future<_Decoded?> _fetchAndDecode(String url) async {
    Uint8List bytes;
    try {
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
      bytes = resp.bodyBytes;
    } catch (_) {
      return null;
    }
    if (_looksLikeSvg(bytes)) {
      try {
        final info = await vg.loadPicture(SvgBytesLoader(bytes), null);
        return _Decoded.svg(info.picture, info.size);
      } catch (_) {
        return null; // strict compiler rejected it — never paint it
      }
    }
    return _Decoded.raster(bytes);
  }

  /// Warms the caches for an already-proxied [url] — the Flutter counterpart of
  /// the PWA's custom-emoji prefetch (`img.src = getProxiedEmojiUrl(url)`,
  /// emoji.js `_runEmojiPrefetch`:83-95), which warms the shared browser HTTP
  /// cache. Flutter has no shared HTTP cache, so this warms BOTH loaders an
  /// emoji can render through: the in-memory [_decode] cache (SVGs + every
  /// [memoryOnly] surface, i.e. the picker grid) and — for rasters — the
  /// `cached_network_image` disk/framework cache the other emoji surfaces use.
  /// The returned future settles when the warm-up does, so a prefetch batch can
  /// run SEQUENTIALLY (an all-at-once batch is exactly the
  /// flutter_cache_manager sqflite lock storm described on [memoryOnly]).
  /// Never throws.
  static Future<void> prefetch(String url) async {
    if (url.isEmpty) return;
    _Decoded? decoded;
    try {
      decoded = await _decode(url);
    } catch (_) {
      return;
    }
    // SVGs (and anything undecodable) only ever render through [_decode]; the
    // compiled picture cached above IS the warm state.
    if (decoded == null || decoded.raster == null) return;
    final completer = Completer<void>();
    final stream =
        CachedNetworkImageProvider(url).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    void done() {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    }

    listener = ImageStreamListener(
      (_, __) => done(),
      onError: (_, __) => done(),
    );
    stream.addListener(listener);
    await completer.future;
  }

  /// True when [bytes] begin with an SVG/XML document head (guards the parser
  /// against an HTML error page or a raster blob).
  static bool _looksLikeSvg(Uint8List bytes) {
    final head =
        String.fromCharCodes(bytes.take(512).where((b) => b != 0))
            .trimLeft()
            .toLowerCase();
    return head.startsWith('<svg') ||
        head.startsWith('<?xml') ||
        head.startsWith('<!doctype svg') ||
        (head.startsWith('<!--') && head.contains('<svg'));
  }

  @override
  State<InlineNetworkImage> createState() => _InlineNetworkImageState();
}

class _InlineNetworkImageState extends State<InlineNetworkImage> {
  /// 0 = the caller's URL; 1..2 = cache-busted retries (`_r=N`).
  int _attempt = 0;
  Timer? _retryTimer;

  /// 0 = [InlineNetworkImage.url]; k = `fallbackUrls[k-1]` — the NIP-92 imeta
  /// mirror the load has fallen through to (messages.js:1154-1163).
  int _srcIndex = 0;
  bool _advancePending = false;

  @override
  void didUpdateWidget(InlineNetworkImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _attempt = 0;
      _srcIndex = 0;
      _advancePending = false;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  /// The source for the current mirror step: the caller's URL, or the imeta
  /// fallback mirror the failed loads have advanced to.
  String get _baseUrl => _srcIndex == 0
      ? widget.url
      : widget.fallbackUrls[_srcIndex - 1];

  /// The URL for the current attempt: the base URL, or (on retry) the base URL
  /// with a cache-busting `_r=N` param appended (inline-bindings.js:176-180).
  String get _effectiveUrl {
    final base = _baseUrl;
    if (_attempt == 0) return base;
    final sep = base.contains('?') ? '&' : '?';
    return '$base$sep' '_r=$_attempt';
  }

  /// Swap in the next imeta mirror after a failed load — the PWA's img `error`
  /// handler does `img.src = list[idx++]` (messages.js:1158-1162). Deferred a
  /// frame because the failure surfaces inside build.
  void _advanceFallback() {
    if (_advancePending) return;
    _advancePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _advancePending = false;
        _srcIndex++;
        _attempt = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
      });
    });
  }

  /// After a failed load, schedule the next attempt at `800ms * (tries + 1)`
  /// (inline-bindings.js:177-180: `setTimeout(..., 800 * (tries + 1))`), up to
  /// 2 retries.
  void _scheduleRetry() {
    if (!widget.retryOnError || _attempt >= 2 || _retryTimer != null) return;
    _retryTimer = Timer(Duration(milliseconds: 800 * (_attempt + 1)), () {
      if (!mounted) return;
      setState(() {
        _retryTimer = null;
        _attempt++;
      });
    });
  }

  Widget _fallback(BuildContext context) {
    // Un-exhausted imeta mirrors take priority over the broken-image state:
    // the PWA never shows the broken img while `data-media-fallbacks` URLs
    // remain — it swaps the src and lets the mirror load.
    if (_srcIndex < widget.fallbackUrls.length) {
      _advanceFallback();
      return widget.placeholder ??
          SizedBox(width: widget.width, height: widget.height);
    }
    _scheduleRetry();
    if (widget.errorChild != null) return widget.errorChild!;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Icon(
        Icons.broken_image_outlined,
        size: (widget.width ?? widget.height ?? 16) * 0.8,
        color: Theme.of(context).disabledColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _effectiveUrl;
    // The in-memory http path handles BOTH svg and raster (and never touches the
    // sqflite-backed disk cache). Use it for SVG-looking URLs and whenever the
    // caller opts out of the disk cache ([memoryOnly], i.e. emoji).
    if (widget.memoryOnly || isSvgUrl(url)) {
      return FutureBuilder<_Decoded?>(
        future: InlineNetworkImage._decode(url),
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return widget.placeholder ??
                SizedBox(width: widget.width, height: widget.height);
          }
          final d = snap.data;
          if (d == null) return _fallback(ctx);
          if (d.picture != null && d.size.width > 0 && d.size.height > 0) {
            return SizedBox(
              width: widget.width,
              height: widget.height,
              child: FittedBox(
                fit: widget.fit,
                child: SizedBox(
                  width: d.size.width,
                  height: d.size.height,
                  child: CustomPaint(painter: _PicturePainter(d.picture!)),
                ),
              ),
            );
          }
          if (d.raster != null) {
            return Image.memory(
              d.raster!,
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              gaplessPlayback: true,
              errorBuilder: (ctx, _, __) => _fallback(ctx),
            );
          }
          return _fallback(ctx);
        },
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      placeholder:
          widget.placeholder == null ? null : (_, __) => widget.placeholder!,
      errorWidget: (ctx, _, __) => _fallback(ctx),
    );
  }
}

/// Gives a baseline-less child (a custom-emoji image) an alphabetic baseline
/// [drop] logical px above its bottom edge. Inside a
/// `PlaceholderAlignment.baseline` [WidgetSpan] this reproduces the PWA's
/// `vertical-align: -Nem` on inline `img.custom-emoji` (styles-chat.css:843
/// `-0.375em`, :857 `-0.25em`, :1707 `-0.3em`): the image bottom sits [drop]
/// below the text baseline, contributing `height - drop` of ascent and [drop]
/// of descent to the line box — exactly the CSS inline-block behaviour.
class EmojiBaselineDrop extends SingleChildRenderObjectWidget {
  const EmojiBaselineDrop({super.key, required this.drop, super.child});

  /// Distance (px) the child's bottom edge sits below the reported baseline.
  final double drop;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEmojiBaselineDrop(drop);

  @override
  void updateRenderObject(
      BuildContext context,
      // ignore: library_private_types_in_public_api
      covariant _RenderEmojiBaselineDrop renderObject) {
    renderObject.drop = drop;
  }
}

class _RenderEmojiBaselineDrop extends RenderProxyBox {
  _RenderEmojiBaselineDrop(this._drop);

  double _drop;
  set drop(double value) {
    if (value == _drop) return;
    _drop = value;
    markNeedsLayout();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      size.height - _drop;
}

/// Paints a pre-compiled SVG [ui.Picture] (sized to its intrinsic viewport; the
/// caller scales it with a [FittedBox]).
class _PicturePainter extends CustomPainter {
  _PicturePainter(this.picture);
  final ui.Picture picture;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPicture(picture);
  @override
  bool shouldRepaint(_PicturePainter old) => old.picture != picture;
}
