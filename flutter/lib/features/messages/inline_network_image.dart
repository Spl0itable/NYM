// Inline images; SVG bytes are pre-compiled in a try/catch because flutter_svg parse errors crash grids.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import '../../services/api/api_config.dart';

import 'pausable_animated_image.dart';

bool isAssetImageUrl(String url) => url.startsWith('assets/');

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

/// Clearly animated extensions only (`.gif`, `.apng`), including the proxied form; animated WebP is sniffed from bytes.
bool isAnimatedImageUrl(String url) {
  if (url.isEmpty) return false;
  final rx = RegExp(r'\.(gif|apng)(\?|#|$)');
  if (rx.hasMatch(url.toLowerCase())) return true;
  final q = Uri.tryParse(url)?.queryParameters['url'];
  return q != null && rx.hasMatch(q.toLowerCase());
}

/// Any GIF, or a WebP whose VP8X header has the animation flag.
bool looksAnimatedImageBytes(Uint8List bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true;
  }
  // RIFF....WEBP + VP8X chunk with the animation bit (0x02) set.
  if (bytes.length >= 21 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50 &&
      bytes[12] == 0x56 &&
      bytes[13] == 0x50 &&
      bytes[14] == 0x38 &&
      bytes[15] == 0x58) {
    return (bytes[20] & 0x02) != 0;
  }
  return false;
}

/// A compiled SVG [picture] with its [size], or [raster] bytes for a misadvertised raster; null if undecodable.
class _Decoded {
  const _Decoded.svg(this.picture, this.size) : raster = null;
  const _Decoded.raster(this.raster)
      : picture = null,
        size = ui.Size.zero;
  final ui.Picture? picture;
  final ui.Size size;
  final Uint8List? raster;
}

/// Network image that handles SVG and degrades to [errorChild] without ever throwing.
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

  /// Already-proxied NIP-92 mirror URLs, tried in order before [errorChild] or retries.
  final List<String> fallbackUrls;

  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorChild;

  /// Skip the disk cache for emoji, whose many concurrent writes lock the cache manager's sqflite DB.
  final bool memoryOnly;

  /// Up to 2 cache-busting `_r=N` retries at 800ms·n; for emoji call sites only.
  final bool retryOnError;

  /// URL -> decoded result, so repeats share one fetch and bad URLs don't crash-loop.
  static final Map<String, Future<_Decoded?>> _cache = {};

  /// Raster bytes from the decode cache (fetching if [fetchIfMissing]); null for SVGs or misses.
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
    // Return the same cached Future every call so FutureBuilders stay settled instead of flickering.
    final cached = _cache[url];
    if (cached != null) return cached;
    // Bound the cache on insert by dropping the oldest.
    if (_cache.length > 1024) _cache.remove(_cache.keys.first);
    final fut = _fetchAndDecode(url);
    _cache[url] = fut;
    return fut;
  }

  /// Browser-like headers, since many hosts 403 a bare `Dart/x` User-Agent on direct fetches.
  static const Map<String, String> imageFetchHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept':
        'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
  };

  static final Map<String, String> apiImageFetchHeaders = {
    'User-Agent': ApiConfig.userAgent,
    'Accept':
        'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
  };

  static Map<String, String> imageHeadersFor(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    return host == ApiConfig.apiHost ? apiImageFetchHeaders : imageFetchHeaders;
  }

  /// Drops [url] from memory, framework and disk caches, e.g. after an avatar change; best-effort.
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
          .get(Uri.parse(url), headers: imageHeadersFor(url))
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
        return null; // The strict compiler rejected it; never paint it.
      }
    }
    return _Decoded.raster(bytes);
  }

  /// Warms both the in-memory decode cache and, for rasters, the disk cache; await it to run a batch sequentially.
  static Future<void> prefetch(String url) async {
    if (url.isEmpty) return;
    _Decoded? decoded;
    try {
      decoded = await _decode(url);
    } catch (_) {
      return;
    }
    // SVGs only render through [_decode], so the compiled picture is the warm state.
    if (decoded == null || decoded.raster == null) return;
    final completer = Completer<void>();
    final stream = CachedNetworkImageProvider(url, headers: imageHeadersFor(url))
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

  /// Guards the parser against HTML error pages or raster blobs.
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
  /// 0 = the caller's URL; 1..2 = cache-busted retries.
  int _attempt = 0;
  Timer? _retryTimer;

  /// 0 = [InlineNetworkImage.url]; k = `fallbackUrls[k-1]`.
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

  /// The current mirror step's source URL.
  String get _baseUrl =>
      _srcIndex == 0 ? widget.url : widget.fallbackUrls[_srcIndex - 1];

  /// The source URL, with a cache-busting `_r=N` param on retries.
  String get _effectiveUrl {
    final base = _baseUrl;
    if (_attempt == 0) return base;
    final sep = base.contains('?') ? '&' : '?';
    return '$base$sep' '_r=$_attempt';
  }

  /// Swaps in the next mirror, deferred a frame because the failure surfaces during build.
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

  /// Next attempt after `800ms * (tries + 1)`, up to 2 retries.
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
    // Remaining mirrors take priority over the broken-image state.
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

  /// Decode width capped to the physical display size (1.5x for cover), or null for full-size surfaces; one dimension only.
  int? _decodeCacheWidth(BuildContext context) {
    final logical = (widget.width ?? widget.height);
    if (logical == null || !logical.isFinite || logical <= 0) return null;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final cover = widget.fit == BoxFit.cover ? 1.5 : 1.0;
    return (logical * dpr * cover).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final cacheWidth = _decodeCacheWidth(context);
    if (isAssetImageUrl(_baseUrl)) {
      return Image.asset(
        _baseUrl,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (ctx, _, __) => _fallback(ctx),
      );
    }
    final url = _effectiveUrl;
    // The in-memory path handles SVG and raster without the disk cache.
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
            // Visibility-gated playback so animated emoji only decode while on screen.
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
              // Decode at display size; applies per frame for animated images.
              cacheWidth: cacheWidth,
              gaplessPlayback: true,
              errorBuilder: (ctx, _, __) => _fallback(ctx),
            );
          }
          return _fallback(ctx);
        },
      );
    }
    // Animated media through the visibility-gated player so offscreen GIFs stop decoding.
    if (isAnimatedImageUrl(url)) {
      return PausableAnimatedImage(
        image: CachedNetworkImageProvider(
          url,
          headers: InlineNetworkImage.imageHeadersFor(url),
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
      httpHeaders: InlineNetworkImage.imageHeadersFor(url),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      // The disk cache still stores the original bytes.
      memCacheWidth: cacheWidth,
      placeholder:
          widget.placeholder == null ? null : (_, __) => widget.placeholder!,
      errorWidget: (ctx, _, __) => _fallback(ctx),
    );
  }
}

/// Gives a baseline-less child a baseline [drop] px above its bottom, like CSS `vertical-align: -Nem` on inline emoji.
class EmojiBaselineDrop extends SingleChildRenderObjectWidget {
  const EmojiBaselineDrop({super.key, required this.drop, super.child});

  /// Distance (px) the child's bottom sits below the reported baseline.
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

  /// Recorded in [performLayout] because the baseline getter must not read [size] on Flutter < 3.41 (flutter#176906).
  double _layoutHeight = 0.0;

  @override
  void performLayout() {
    super.performLayout();
    _layoutHeight = size.height; // Own size during own layout is always legal.
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      _layoutHeight - _drop;

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) =>
      getDryLayout(constraints).height - _drop;
}

/// Paints a pre-compiled SVG picture; the caller scales it with a [FittedBox].
class _PicturePainter extends CustomPainter {
  _PicturePainter(this.picture);
  final ui.Picture picture;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPicture(picture);
  @override
  bool shouldRepaint(_PicturePainter old) => old.picture != picture;
}
