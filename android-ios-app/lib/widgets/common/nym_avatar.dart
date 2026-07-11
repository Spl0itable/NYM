import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

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
class NymAvatar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final proxied = proxiedAvatarUrl(imageUrl);
    final fallback = _identicon(context);
    if (proxied == null) return fallback;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: CachedNetworkImage(
          imageUrl: proxied,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, __) => fallback,
          errorWidget: (_, __, ___) => fallback,
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
        size: Size(size, size),
        painter: _IdenticonPainter(seed),
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
