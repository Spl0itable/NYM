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

import 'pausable_animated_image.dart';

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

/// True when [url] names a format that ANIMATES (by extension, like
/// [isSvgUrl] — including the proxied `url=` form). Only clearly-animated
/// extensions are matched: `.gif` / `.apng`. Animated WebP can't be told from
/// static WebP by URL; the in-memory path sniffs its bytes instead
/// ([looksAnimatedImageBytes]).
bool isAnimatedImageUrl(String url) {
  if (url.isEmpty) return false;
  final rx = RegExp(r'\.(gif|apng)(\?|#|$)');
  if (rx.hasMatch(url.toLowerCase())) return true;
  final q = Uri.tryParse(url)?.queryParameters['url'];
  return q != null && rx.hasMatch(q.toLowerCase());
}

/// True when [bytes] begin like an animated image: any GIF (`GIF8…` — GIFs in
/// chat are effectively always animated, and a static GIF through the
/// pausable path renders identically), or a WebP whose VP8X header carries
/// the animation flag.
bool looksAnimatedImageBytes(Uint8List bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x47 && // G
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x38) {
    return true;
  }
  // RIFF....WEBP + VP8X chunk with the animation bit (0x02) set.
  if (bytes.length >= 21 &&
      bytes[0] == 0x52 && // R
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x46 && // F
      bytes[8] == 0x57 && // W
      bytes[9] == 0x45 && // E
      bytes[10] == 0x42 && // B
      bytes[11] == 0x50 && // P
      bytes[12] == 0x56 && // V
      bytes[13] == 0x50 && // P
      bytes[14] == 0x38 && // 8
      bytes[15] == 0x58) {
    // X
    return (bytes[20] & 0x02) != 0;
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

  /// Returns decoded RASTER bytes for an already-proxied [url] when available:
  /// from the in-memory decode cache (so it works offline for any emoji/GIF the
  /// app has already rendered or prefetched) or, when [fetchIfMissing] is set,
  /// by fetching now and caching the result. Returns null on a cache miss (when
  /// not fetching), for an SVG/vector source (which has no raster bytes), or for
  /// an undecodable/unreachable URL.
  ///
  /// The Bluetooth-mesh composer uses this to ship a locally-cached custom emoji
  /// or favourite GIF as a file (there is no shared server for peers to fetch it
  /// from), reusing the exact cache the display path already populated.
  static Future<Uint8List?> resolveBytes(String url,
      {bool fetchIfMissing = true}) async {
    if (url.isEmpty) return null;
    if (_cache[url] == null && !fetchIfMissing) return null;
    _Decoded? decoded;
    try {
      decoded = await _decode(url);
    } catch (_) {
      return null;
    }
    return decoded?.raster;
  }

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

  /// Browser-like headers for every image fetch. Many image hosts (Cloudflare
  /// bot protection, hotlink guards) 403 a bare `Dart/x` User-Agent, so a
  /// proxy-blocked avatar's RAW-URL fallback failed natively while the PWA — a
  /// real browser — loaded it fine. Presenting a browser UA + image `Accept`
  /// makes the direct-host fetch behave like the PWA's. Harmless on the media
  /// proxy itself (it has no UA gate). Applied to both the `http.get` path here
  /// and the [CachedNetworkImage] path (via `httpHeaders`).
  static const Map<String, String> imageFetchHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept':
        'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
  };

  /// Drops [url] from every cache tier — the in-memory decode cache, the
  /// framework [ImageCache], and the on-disk `flutter_cache_manager` store — so
  /// the next request re-fetches it. Called when a user changes their avatar so
  /// a re-used URL (or a stale disk entry) can't keep serving the old image,
  /// mirroring the PWA revoking the old blob on an avatar URL change
  /// (`cacheAvatarImage`). Best-effort; failures are swallowed.
  static void evict(String url) {
    if (url.isEmpty) return;
    _cache.remove(url);
    unawaited(CachedNetworkImage.evictFromCache(url).catchError((_) => false));
    unawaited(CachedNetworkImageProvider(url).evict().catchError((_) => false));
  }

  static Future<_Decoded?> _fetchAndDecode(String url) async {
    Uint8List bytes;
    try {
      final resp = await http
          .get(Uri.parse(url), headers: imageFetchHeaders)
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
        assert(() {
          debugPrint('[img-fetch] status=${resp.statusCode} '
              'len=${resp.bodyBytes.length} '
              'ct=${resp.headers['content-type']} url=$url');
          return true;
        }());
        return null;
      }
      bytes = resp.bodyBytes;
    } catch (e) {
      assert(() {
        debugPrint('[img-fetch] ERROR $e url=$url');
        return true;
      }());
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
    final stream = CachedNetworkImageProvider(url, headers: imageFetchHeaders)
        .resolve(ImageConfiguration.empty);
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
    final head = String.fromCharCodes(bytes.take(512).where((b) => b != 0))
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
  String get _baseUrl =>
      _srcIndex == 0 ? widget.url : widget.fallbackUrls[_srcIndex - 1];

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

  /// The decode-width cap (physical px) for the current display box, or null
  /// when the caller gave no finite width/height (full-size surfaces like the
  /// fullscreen viewer, which want the native resolution).
  ///
  /// Without a cap every raster decodes at its INTRINSIC size — a 12MP photo
  /// shown in a 300px tile, a 2MP avatar in a 40px circle — costing tens of MB
  /// of decode + GPU texture upload EACH, evicting the whole ImageCache (so
  /// scrolled-away rows re-decode on every pass) and hammering both CPU and
  /// GPU exactly while messages stream in. Capping the decode to the on-screen
  /// physical size is the single biggest lever on that. Only ONE dimension is
  /// ever passed to the codec so the aspect ratio is always preserved
  /// (width preferred, else height); [BoxFit.cover] gets a 1.5× margin so the
  /// crop of a non-matching aspect ratio can't render soft.
  int? _decodeCacheWidth(BuildContext context) {
    final logical = (widget.width ?? widget.height);
    if (logical == null || !logical.isFinite || logical <= 0) return null;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final cover = widget.fit == BoxFit.cover ? 1.5 : 1.0;
    return (logical * dpr * cover).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final url = _effectiveUrl;
    final cacheWidth = _decodeCacheWidth(context);
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
            // Animated GIF / animated-WebP: visibility-gated playback so a
            // pile of animated emoji only burns frame decodes while actually
            // on screen (see [PausableAnimatedImage]).
            if (looksAnimatedImageBytes(d.raster!)) {
              ImageProvider provider = MemoryImage(d.raster!);
              if (cacheWidth != null) {
                provider = ResizeImage(provider,
                    width: cacheWidth, allowUpscaling: false);
              }
              return PausableAnimatedImage(
                image: provider,
                visibilityKey: ValueKey('anim-mem:$url'),
                width: widget.width,
                height: widget.height,
                fit: widget.fit,
                placeholder: widget.placeholder,
                errorBuilder: _fallback,
              );
            }
            return Image.memory(
              d.raster!,
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              // Decode at the display size, not the intrinsic size (see
              // [_decodeCacheWidth]). Applies per-frame for animated GIF/WebP
              // emoji, which otherwise decode every frame at full resolution.
              cacheWidth: cacheWidth,
              gaplessPlayback: true,
              errorBuilder: (ctx, _, __) => _fallback(ctx),
            );
          }
          return _fallback(ctx);
        },
      );
    }
    // Animated media (`.gif`/`.apng` — Giphy picks, GIF spam): same
    // disk-cached provider, but rendered through the visibility-gated player
    // so offscreen GIFs stop decoding frames instead of animating forever.
    if (isAnimatedImageUrl(url)) {
      return PausableAnimatedImage(
        image: CachedNetworkImageProvider(
          url,
          headers: InlineNetworkImage.imageFetchHeaders,
          maxWidth: cacheWidth,
        ),
        visibilityKey: ValueKey('anim-net:$url'),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        placeholder: widget.placeholder,
        errorBuilder: _fallback,
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: InlineNetworkImage.imageFetchHeaders,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      // Decode at the display size (see [_decodeCacheWidth]); the disk cache
      // still stores the original bytes, so nothing is lost across surfaces.
      memCacheWidth: cacheWidth,
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

  /// Height recorded during [performLayout], because the baseline getter below
  /// MUST NOT read [size]: the paragraph queries a placeholder's baseline
  /// during ITS OWN performLayout, and on Flutter < 3.41 (before upstream
  /// fix flutter#176906) a RenderBox that isn't the paragraph's direct child
  /// (this one sits under a Padding) may not read its size in that scope —
  /// the debug assert threw MID-LAYOUT of every emoji-bearing paragraph,
  /// aborting it before placeholder dimensions were set and corrupting the
  /// whole message-list subtree into a per-frame exception storm
  /// ("RenderBox.size accessed beyond the scope…", "dimensions != null",
  /// "RenderBox was not laid out…") — the app-wide lag while messages load.
  double _layoutHeight = 0.0;

  @override
  void performLayout() {
    super.performLayout();
    _layoutHeight = size.height; // own size during own layout: always legal
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      _layoutHeight - _drop;

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) =>
      getDryLayout(constraints).height - _drop;
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
