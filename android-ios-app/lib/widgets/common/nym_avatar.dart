import 'package:flutter/material.dart';

import '../../features/messages/inline_network_image.dart';
import '../../models/user.dart';
import '../../services/api/api_client.dart';

/// Stateless [ApiClient] for avatar/banner proxy URL construction (pure, no
/// network). Mirrors the PWA's `getProxiedMediaUrl` (users.js:485).
final _avatarApi = ApiClient();

/// Routes a remote `http(s)://` avatar/banner [url] through the media proxy so
/// the user's IP is hidden from the image host (PWA `getProxiedMediaUrl`).
/// `data:`/`blob:`/relative/already-proxied URLs pass through unchanged; the
/// caller treats a null/empty result as "no remote image" (identicon fallback).
String? proxiedAvatarUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final lower = url.toLowerCase();
  if (lower.startsWith('data:') || lower.startsWith('blob:')) return url;
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) return url;
  if (url.contains('/api/proxy?')) return url;
  return _avatarApi.mediaProxyUrl(url);
}

/// Maps a user status to the spec dot color (docs/specs/02 §5.3):
/// online `#22c55e`, away `#eab308`, offline `#6b7280`.
Color statusColor(UserStatus status) {
  switch (status) {
    case UserStatus.online:
      return const Color(0xFF22C55E);
    case UserStatus.away:
      return const Color(0xFFEAB308);
    case UserStatus.offline:
    case UserStatus.hidden:
      return const Color(0xFF6B7280);
  }
}

/// A round avatar. When [imageUrl] points at a remote `http(s)://` image it is
/// loaded through the media proxy (PWA `getProxiedMediaUrl`); on error or when
/// absent it falls back to a generated identicon that derives a stable tint
/// from the seed (mirroring the bitchat multicolor feel).
///
/// PROXY→RAW FALLBACK — the fix for avatars that render in the PWA but not
/// natively. The PWA's `cacheAvatarImage` (users.js:945) fetches the PROXIED
/// URL as a blob and, when that fetch fails (CORS, network, a non-200 from the
/// proxy), FALLS BACK to the RAW direct URL — `updateRenderedAvatars(pubkey,
/// url)` re-renders with the un-proxied `url`. Lots of avatar hosts block the
/// proxy's egress IP, hotlink-protect, or rate-limit it, so their pictures only
/// load via that raw fallback. The old native path only ever tried the proxied
/// URL and then gave up to the identicon, so every one of those users showed a
/// generated avatar natively while the PWA showed their real one.
///
/// We reproduce it by handing [InlineNetworkImage] the proxied URL as the
/// primary source and the RAW original as a [InlineNetworkImage.fallbackUrls]
/// mirror: a failed proxied load swaps to the direct host before degrading to
/// the identicon. [InlineNetworkImage] also renders any image type the way the
/// PWA's `<img>`/blob does (raster AND SVG), so the fetched picture replaces the
/// identicon regardless of format.
///
/// BROWSER USER-AGENT — the actual reason the picture stayed an identicon: many
/// avatar hosts (Cloudflare bot protection, hotlink guards) 403 a bare `Dart/x`
/// User-Agent, so when the media proxy can't fetch the image upstream and BOTH
/// clients fall back to the RAW direct host, the PWA (a real browser) loads it
/// but native's fetch was rejected. [InlineNetworkImage] now presents a
/// browser-like UA (`imageFetchHeaders`) on every image request, so the
/// direct-host fallback behaves like the PWA's `<img>`.
///
/// Rendered through the DISK-cached [CachedNetworkImage] path (not `memoryOnly`)
/// so a fetched avatar persists across launches instead of re-fetching every
/// time — the native counterpart of the PWA's IndexedDB blob cache
/// (`persistAvatarBlob`). SVG avatars still route through the SVG-aware in-memory
/// path automatically.
class NymAvatar extends StatefulWidget {
  const NymAvatar({
    super.key,
    required this.seed,
    this.size = 20,
    this.label,
    this.imageUrl,
  });

  final String seed;
  final double size;

  /// Optional single-glyph override; defaults to the first non-`#` char.
  final String? label;

  /// Optional remote avatar URL. Proxied via [proxiedAvatarUrl]; falls back to
  /// the identicon when null/empty or on load error.
  final String? imageUrl;

  @override
  State<NymAvatar> createState() => _NymAvatarState();
}

class _NymAvatarState extends State<NymAvatar> {
  @override
  void didUpdateWidget(NymAvatar old) {
    super.didUpdateWidget(old);
    // The user changed their avatar (the profile's `picture` URL changed): drop
    // the OLD image from every cache so a re-used URL / stale disk entry can't
    // keep serving the previous photo — the PWA revokes the old blob on an
    // avatar URL change (`cacheAvatarImage`). The NEW URL is a fresh cache key,
    // so it re-fetches automatically; this only cleans up the superseded one.
    final oldUrl = old.imageUrl;
    if (oldUrl != null &&
        oldUrl.isNotEmpty &&
        oldUrl != widget.imageUrl) {
      final oldProxied = proxiedAvatarUrl(oldUrl);
      if (oldProxied != null) InlineNetworkImage.evict(oldProxied);
      if (oldProxied != oldUrl) InlineNetworkImage.evict(oldUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final proxied = proxiedAvatarUrl(widget.imageUrl);
    final fallback = _identicon(context);
    if (proxied == null) return fallback;
    // The RAW original URL, tried directly when the proxied load fails — the
    // PWA's proxied-blob→raw-URL fallback (`cacheAvatarImage`, users.js:983).
    // Only meaningful when we actually proxied something (an http(s) URL that
    // isn't already a proxy link); for a pass-through data:/blob:/relative URL
    // `proxied == imageUrl`, so there's no distinct raw mirror to add.
    final raw = widget.imageUrl;
    final fallbackUrls = <String>[
      if (raw != null && raw.isNotEmpty && raw != proxied) raw,
    ];
    return ClipOval(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: InlineNetworkImage(
          url: proxied,
          fallbackUrls: fallbackUrls,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          // Identicon while loading AND after every source (proxy + raw) fails
          // — the swap to the real avatar happens once a source resolves.
          placeholder: fallback,
          errorChild: fallback,
        ),
      ),
    );
  }

  /// The generated identicon fallback — a 1:1 port of the PWA's
  /// `generateAvatarSvg` (users.js:318): an FNV-1a hash of the seed seeds a
  /// Mulberry32 PRNG that picks an HSL foreground + complementary dark
  /// background and fills a 5×5 horizontally-mirrored cell grid. Deterministic
  /// per seed, so it matches the PWA byte-for-byte and is clearly visible in
  /// both light and dark themes (it carries its own opaque background).
  Widget _identicon(BuildContext context) {
    return ClipOval(
      child: CustomPaint(
        size: Size(widget.size, widget.size),
        painter: _IdenticonPainter(widget.seed),
      ),
    );
  }
}

/// Paints the deterministic identicon described by [NymAvatar._identicon].
class _IdenticonPainter extends CustomPainter {
  _IdenticonPainter(this.seed);

  final String seed;

  /// 32-bit truncated multiply (JS `Math.imul`). The low 32 bits survive Dart's
  /// 64-bit wrap, so `& 0xFFFFFFFF` reproduces it exactly on native.
  static int _imul(int a, int b) => (a * b) & 0xFFFFFFFF;

  @override
  void paint(Canvas canvas, Size size) {
    final key = seed;
    // FNV-1a-ish 32-bit hash.
    var h = 2166136261;
    for (var i = 0; i < key.length; i++) {
      h ^= key.codeUnitAt(i);
      h = _imul(h, 16777619);
    }
    var s = h == 0 ? 1 : h;
    double rand() {
      s = (s + 0x6D2B79F5) & 0xFFFFFFFF;
      var t = _imul(s ^ (s >>> 15), 1 | s);
      t = ((t + _imul(t ^ (t >>> 7), 61 | t)) ^ t) & 0xFFFFFFFF;
      return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296.0;
    }

    final hue = (rand() * 360).floor();
    final sat = 60 + (rand() * 25).floor();
    final light = 50 + (rand() * 15).floor();
    final fg = HSLColor.fromAHSL(1, hue.toDouble(), sat / 100, light / 100)
        .toColor();
    final bgHue = (hue + 180) % 360;
    final bg =
        HSLColor.fromAHSL(1, bgHue.toDouble(), 0.25, 0.18).toColor();

    // Background fill.
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    // 5×5 grid, mirrored horizontally; the 80px SVG viewBox scales to [size].
    const cols = 5;
    const rows = 5;
    const half = 3; // ceil(cols / 2)
    final cell = size.width / cols;
    final fgPaint = Paint()..color = fg;
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < half; x++) {
        if (rand() < 0.5) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5),
            fgPaint,
          );
          final mirror = cols - 1 - x;
          if (mirror != x) {
            canvas.drawRect(
              Rect.fromLTWH(mirror * cell, y * cell, cell + 0.5, cell + 0.5),
              fgPaint,
            );
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _IdenticonPainter old) => old.seed != seed;
}

/// 6×6 round status dot (docs/specs/02 §5.3 user-item dot).
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.status, this.size = 6});
  final UserStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: statusColor(status),
        shape: BoxShape.circle,
      ),
    );
  }
}
