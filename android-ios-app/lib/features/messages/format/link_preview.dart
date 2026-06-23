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
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        onTap: () {
          final uri = Uri.tryParse(data.url);
          if (uri != null) {
            launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        borderRadius: NymRadius.rsm,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              border: Border.all(color: c.glassBorder),
              borderRadius: NymRadius.rsm,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (data.image != null)
                  CachedNetworkImage(
                    imageUrl: api.mediaProxyUrl(data.image!),
                    width: double.infinity,
                    height: 150,
                    fit: BoxFit.cover,
                    // The PWA hides a broken preview image (data-error-action
                    // errorHideElement); mirror by collapsing it.
                    errorWidget: (_, __, ___) => const SizedBox.shrink(),
                  ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _siteRow(c),
                      if (data.title.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          data.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textBright,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                      ],
                      if (data.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          // PWA slices description to 200 chars (ui-context.js:800).
                          data.description.length > 200
                              ? data.description.substring(0, 200)
                              : data.description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textDim,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _siteRow(NymColors c) {
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
            data.host,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c.secondary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
