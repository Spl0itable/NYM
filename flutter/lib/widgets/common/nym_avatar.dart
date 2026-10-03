import 'package:flutter/material.dart';

import '../../features/messages/inline_network_image.dart';
import '../../models/user.dart';
import '../../services/api/api_client.dart';
import '../../services/mesh/mesh_avatar_registry.dart';

final _avatarApi = ApiClient();

/// Routes a remote avatar/banner URL through the media proxy to hide the user's IP; other URLs pass through.
String? proxiedAvatarUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final lower = url.toLowerCase();
  if (lower.startsWith('data:') || lower.startsWith('blob:')) return url;
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) return url;
  if (isOwnMediaUrl(url)) return url;
  return _avatarApi.mediaProxyUrl(url);
}

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

/// Round avatar via the media proxy, falling back to the raw URL, then a generated identicon.
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

  final String? label;

  final String? imageUrl;

  @override
  State<NymAvatar> createState() => _NymAvatarState();
}

class _NymAvatarState extends State<NymAvatar> {
  @override
  void didUpdateWidget(NymAvatar old) {
    super.didUpdateWidget(old);
    // Evict the old URL from every cache so a reused URL or stale disk entry can't keep serving the old photo.
    final oldUrl = old.imageUrl;
    if (oldUrl != null && oldUrl.isNotEmpty && oldUrl != widget.imageUrl) {
      final oldProxied = proxiedAvatarUrl(oldUrl);
      if (oldProxied != null) InlineNetworkImage.evict(oldProxied);
      if (oldProxied != oldUrl) InlineNetworkImage.evict(oldUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A mesh-transferred avatar wins so Bluetooth-only peers still show their real picture.
    return ValueListenableBuilder<int>(
      valueListenable: MeshAvatarRegistry.instance.revision,
      builder: (context, _, _) {
        final meshBytes = MeshAvatarRegistry.instance.bytesFor(widget.seed);
        if (meshBytes != null) {
          return ClipOval(
            child: Image.memory(
              meshBytes,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // Decode at the avatar size, not the transferred photo's intrinsic size.
              cacheWidth: (widget.size *
                      MediaQuery.devicePixelRatioOf(context) *
                      1.5)
                  .ceil(),
              errorBuilder: (_, _, _) => _identicon(context),
            ),
          );
        }
        return _buildNetwork(context);
      },
    );
  }

  Widget _buildNetwork(BuildContext context) {
    final proxied = proxiedAvatarUrl(widget.imageUrl);
    final fallback = _identicon(context);
    if (proxied == null) return fallback;
    return ClipOval(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: InlineNetworkImage(
          url: proxied,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          // Identicon while loading and after every source (proxy and raw) fails.
          placeholder: fallback,
          errorChild: fallback,
        ),
      ),
    );
  }

  /// Identicon ported from the PWA `generateAvatarSvg` so it matches byte-for-byte per seed.
  Widget _identicon(BuildContext context) {
    return ClipOval(
      child: CustomPaint(
        size: Size(widget.size, widget.size),
        painter: _IdenticonPainter(widget.seed),
      ),
    );
  }
}

class _IdenticonPainter extends CustomPainter {
  _IdenticonPainter(this.seed);

  final String seed;

  /// JS `Math.imul`: the low 32 bits survive Dart's 64-bit wrap.
  static int _imul(int a, int b) => (a * b) & 0xFFFFFFFF;

  @override
  void paint(Canvas canvas, Size size) {
    final key = seed;
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
    final fg =
        HSLColor.fromAHSL(1, hue.toDouble(), sat / 100, light / 100).toColor();
    final bgHue = (hue + 180) % 360;
    final bg = HSLColor.fromAHSL(1, bgHue.toDouble(), 0.25, 0.18).toColor();

    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    const cols = 5;
    const rows = 5;
    const half = 3;
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
