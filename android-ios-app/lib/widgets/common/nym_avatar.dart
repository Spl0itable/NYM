import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
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

  /// The generated identicon fallback (unchanged behavior).
  Widget _identicon(BuildContext context) {
    final c = context.nym;
    final hue = (seed.hashCode % 360).toDouble().abs();
    final tint = HSLColor.fromAHSL(1, hue, 0.5, 0.5).toColor();
    final glyph = (label ?? _initial(seed)).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.25),
        shape: BoxShape.circle,
        border: Border.all(color: c.glassBorder, width: 1),
      ),
      child: Text(
        glyph,
        style: TextStyle(
          color: tint,
          fontSize: size * 0.5,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  String _initial(String s) {
    for (final ch in s.split('')) {
      if (ch != '#' && ch.trim().isNotEmpty) return ch;
    }
    return '?';
  }
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
