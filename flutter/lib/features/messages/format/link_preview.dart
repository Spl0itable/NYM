// Lazy OpenGraph link-preview card via the unfurl proxy; media URLs are skipped and any failure renders nothing.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_metrics.dart';
import '../../../services/api/api_client.dart';
import '../../../core/utils/safe_url.dart';

class LinkPreviewData {
  const LinkPreviewData({
    required this.url,
    required this.title,
    required this.description,
    required this.image,
    required this.siteName,
    required this.favicon,
  });

  final String url;
  final String title;
  final String description;
  final String? image;
  final String siteName;
  final String? favicon;

  /// Header label: `siteName` when present, else the URL host.
  String get host {
    if (siteName.isNotEmpty) return siteName;
    final u = Uri.tryParse(url);
    return u?.host ?? '';
  }

  /// A card renders only when there is a title or description.
  bool get hasContent => title.isNotEmpty || description.isNotEmpty;

  factory LinkPreviewData.fromUnfurl(UnfurlResult r) => LinkPreviewData(
        url: r.url,
        title: r.title ?? '',
        description: r.description ?? '',
        image: (r.image != null && r.image!.isNotEmpty) ? r.image : null,
        siteName: r.siteName ?? '',
        favicon:
            (r.favicon != null && r.favicon!.isNotEmpty) ? r.favicon : null,
      );
}

/// True for URLs already rendered as inline media, which get no preview.
bool isInlineMediaUrl(String url) =>
    RegExp(r'\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(\?.*)?$',
            caseSensitive: false)
        .hasMatch(url);

/// Unfurls [url] on mount; renders nothing while loading, on error, or without a title or description.
class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({super.key, required this.url, this.api});

  final String url;

  /// Injectable for tests.
  final ApiClient? api;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  late final ApiClient _api = widget.api ?? ApiClient();
  LinkPreviewData? _data;
  bool _failed = false;
  Timer? _dwell;

  @override
  void initState() {
    super.initState();
    final cached = _api.unfurlCached(widget.url);
    if (cached != null) {
      final data = LinkPreviewData.fromUnfurl(cached);
      if (data.hasContent) {
        _data = data;
        return;
      }
    }
    // Dwell before fetching so rows flung past mid-scroll never fire unfurl requests.
    _dwell = Timer(const Duration(milliseconds: 300), () {
      _dwell = null;
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _dwell?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await _api.unfurl(widget.url);
      final data = LinkPreviewData.fromUnfurl(res);
      if (!mounted) return;
      if (!data.hasContent) {
        setState(() => _failed = true);
        return;
      }
      setState(() => _data = data);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (_failed || data == null) return const SizedBox.shrink();
    return _Card(data: data, api: _api);
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.data, required this.api});
  final LinkPreviewData data;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final size = _baseTextSize(context);
    final narrow = MediaQuery.of(context).size.width <= 768;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: () => launchSafeUrl(data.url),
        borderRadius: NymRadius.rsm,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: narrow ? double.infinity : 400),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: c.glassBorder),
              borderRadius: NymRadius.rsm,
            ),
            clipBehavior: Clip.antiAlias,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (data.image != null)
                    SizedBox(
                      width: narrow ? 80 : 120,
                      child: CachedNetworkImage(
                        imageUrl: api.mediaProxyUrl(data.image!),
                        fit: BoxFit.cover,
                        // og:image is often full-size; decode at the card slot size.
                        memCacheWidth: ((narrow ? 80 : 120) *
                                MediaQuery.devicePixelRatioOf(context) *
                                1.5)
                            .ceil(),
                        errorWidget: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 80),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _siteRow(context, c, size),
                            if (data.title.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                data.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.text,
                                  fontSize: size * 0.9,
                                  fontWeight: FontWeight.w600,
                                  height: 1.3,
                                ),
                              ),
                            ],
                            if (data.description.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                // Description is sliced to 200 chars.
                                data.description.length > 200
                                    ? data.description.substring(0, 200)
                                    : data.description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.textDim,
                                  fontSize: size * 0.8,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Base body text size from settings; the preview's ems are relative to it.
  double _baseTextSize(BuildContext context) =>
      DefaultTextStyle.of(context).style.fontSize ?? 15;

  Widget _siteRow(BuildContext context, NymColors c, double size) {
    final favicon = data.favicon;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (favicon != null) ...[
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(2)),
            child: CachedNetworkImage(
              imageUrl: api.mediaProxyUrl(favicon),
              width: 14,
              height: 14,
              fit: BoxFit.cover,
              memCacheWidth:
                  (14 * MediaQuery.devicePixelRatioOf(context) * 1.5).ceil(),
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            data.host.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c.textDim,
              fontSize: size * 0.75,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }
}
