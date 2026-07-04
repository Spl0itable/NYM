// Lazy OpenGraph link-preview card, a 1:1 port of the PWA's `.link-preview`
// surface (ui-context.js `unfurlUrl` + `_renderLinkPreview` + `_attachLinkPreviews`,
// lines 682-831; markup index.html; styles styles-features.css `.link-preview`).
//
// For a bare http(s) link in a message the PWA lazily unfurls it through the
// backend proxy (`/api/proxy?action=unfurl`) and renders a card with the
// site/title/description and (proxied) preview image + favicon. Media URLs
// (image/video extensions) are skipped — they already render inline. The card
// is collapsed/lazy (fetched only when mounted), and dismiss/error tolerant:
// any failure or an empty `{title, description}` renders nothing.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_metrics.dart';
import '../../../services/api/api_client.dart';

/// Parsed link-preview content (mirrors `proxy.js` `extractOpenGraph` /
/// ui-context.js `_renderLinkPreview`). Built from an [UnfurlResult].
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

  /// The site label shown in the card header: `siteName` when present, else the
  /// URL hostname (ui-context.js:792-798).
  String get host {
    if (siteName.isNotEmpty) return siteName;
    final u = Uri.tryParse(url);
    return u?.host ?? '';
  }

  /// The PWA only renders a card when there is a title or description
  /// (ui-context.js:778). Mirror that gate.
  bool get hasContent => title.isNotEmpty || description.isNotEmpty;

  /// Builds from the proxy's `?action=unfurl` JSON shape.
  factory LinkPreviewData.fromUnfurl(UnfurlResult r) => LinkPreviewData(
        url: r.url,
        title: r.title ?? '',
        description: r.description ?? '',
        image: (r.image != null && r.image!.isNotEmpty) ? r.image : null,
        siteName: r.siteName ?? '',
        favicon: (r.favicon != null && r.favicon!.isNotEmpty) ? r.favicon : null,
      );
}

/// Returns true for URLs that should NOT get a link preview because they are
/// already rendered as inline media (ui-context.js:815). Mirrors the PWA regex
/// `\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(\?.*)?$`.
bool isInlineMediaUrl(String url) =>
    RegExp(r'\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(\?.*)?$',
            caseSensitive: false)
        .hasMatch(url);

/// A lazily-unfurled link-preview card. Fetches [UnfurlResult] for [url] via
/// [ApiClient.unfurl] on mount; renders nothing while loading, on error, or
/// when the result has no title/description. The preview image + favicon are
/// loaded through the media proxy (mirrors `_renderLinkPreview`).
class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({super.key, required this.url, this.api});

  final String url;

  /// Injectable for tests; defaults to a live [ApiClient].
  final ApiClient? api;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  late final ApiClient _api = widget.api ?? ApiClient();
  LinkPreviewData? _data;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
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
    // Collapsed until ready; dismiss/error tolerant (renders nothing).
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
    // `.link-preview` is a horizontal flex card (`styles-features.css:4348`):
    // a 120px left thumbnail + a right text column, max-width 400, radius 8.
    // At ≤768px the card spans the full message width and the thumbnail
    // shrinks to 80px (`styles-themes-responsive.css:1531-1539`).
    final narrow = MediaQuery.of(context).size.width <= 768;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: () {
          final uri = Uri.tryParse(data.url);
          if (uri != null) {
            launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        borderRadius: NymRadius.rsm,
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: narrow ? double.infinity : 400),
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
                      // `.link-preview-image { width: 120px }`, 80px at ≤768px.
                      width: narrow ? 80 : 120,
                      child: CachedNetworkImage(
                        imageUrl: api.mediaProxyUrl(data.image!),
                        fit: BoxFit.cover,
                        // The PWA hides a broken preview image; collapse it.
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
                            _siteRow(c, size),
                            if (data.title.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                data.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  // `.link-preview-title { color: var(--text) }`
                                  // (styles-features.css:4397-4405).
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
                                // PWA slices description to 200 chars.
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

  /// The base body text size from settings (the link-preview ems are relative).
  double _baseTextSize(BuildContext context) =>
      DefaultTextStyle.of(context).style.fontSize ?? 15;

  /// `.link-preview-site`: an UPPERCASE text-dim label with a 14×14 favicon and
  /// `letter-spacing:0.3` (`styles-features.css:4390`).
  Widget _siteRow(NymColors c, double size) {
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
