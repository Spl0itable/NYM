import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_a11y.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/chat_lock/chat_lock_providers.dart';
import '../../features/emoji/emoji_block.dart' show hiddenEmojiProvider;
import '../../features/i18n/i18n.dart';
import '../../features/identity/deleted_notice.dart' show dimRangeSpans;
import '../../features/layout/layout_model.dart';
import '../../features/messages/format/message_content.dart' show proxiedMedia;
import '../../features/messages/format/nym_format.dart' show kBuiltinEmoji;
import '../../features/messages/inline_network_image.dart';
import '../../features/messages/media_fallbacks.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/search/unified_search_panel.dart' show nymSuffixStyle;
import '../../features/sidebar/public_stream.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart' show bootEpochProvider;
import '../../state/settings_provider.dart';
import '../chat/bitchat_user_color.dart';
import '../chat/message_row.dart' show channelBodyTextColor, channelNymColor, redactedNymColor;
import 'row_preview.dart';
import 'sidebar_chrome.dart' show kSidebarSubLine;
import 'sidebar_row_gestures.dart';

@immutable
class _Sig {
  const _Sig(this.parts);

  final List<Object?> parts;

  @override
  bool operator ==(Object other) =>
      other is _Sig && listEquals(other.parts, parts);

  @override
  int get hashCode => Object.hashAll(parts);
}

final publicStreamKeysProvider = Provider<List<String>>((ref) {
  final pmOnly =
      ref.watch(settingsProvider.select((s) => s.groupChatPMOnlyMode));
  final hideNonPinned =
      ref.watch(settingsProvider.select((s) => s.hideNonPinned));
  ref.watch(chatLockRevisionProvider);
  final lock = ref.read(chatLockProvider);
  ref.watch(appStateProvider.select((s) => _Sig([
        for (final ch in s.channels) ch.key,
        null,
        ...s.blockedChannels,
        null,
        ...s.hiddenChannels,
        null,
        ...s.pinnedChannels,
      ])));
  final s = ref.read(appStateProvider);
  return List.unmodifiable(psStreamKeys(
    channels: [for (final ch in s.channels) ch.key],
    blocked: s.blockedChannels,
    hidden: s.hiddenChannels,
    pinned: s.pinnedChannels,
    locked: {
      for (final ch in s.channels)
        if (lock.isConversationLocked(ch.storageKey)) ch.key,
    },
    hideNonPinned: hideNonPinned,
    pmOnly: pmOnly,
  ));
});

final publicStreamRevProvider = Provider<Object>((ref) {
  final keys = ref.watch(publicStreamKeysProvider);
  return ref.watch(appStateProvider.select((s) => _Sig([
        s.globalRev,
        for (final k in keys) s.keyRevs['#$k'],
      ])));
});

class PublicStreamPager {
  int shown = kPsFirst;
  PsHold? hold;
  bool release = false;
  bool scrolled = false;
  bool pointer = false;
  List<PsStamp> last = const [];

  void reset() {
    shown = kPsFirst;
    hold = null;
    release = false;
    last = const [];
  }
}

final publicStreamPagerProvider = Provider<PublicStreamPager>((ref) {
  ref.watch(bootEpochProvider);
  ref.watch(appStateProvider.select((s) => s.selfPubkey));
  return PublicStreamPager();
});

final publicStreamTickProvider = StateProvider<int>((ref) => 0);

@immutable
class PublicStreamView {
  const PublicStreamView(this.page, this.texts, this.sig);

  final PsPage<Message> page;
  final List<PsParts> texts;
  final Object sig;
}

final publicStreamViewProvider = Provider<PublicStreamView>((ref) {
  final keys = ref.watch(publicStreamKeysProvider);
  ref.watch(publicStreamRevProvider);
  ref.watch(publicStreamTickProvider);
  final hide = ref.watch(settingsProvider.select((s) => s.hidePreviews));
  final pager = ref.watch(publicStreamPagerProvider);
  final codes =
      ref.watch(liveCustomEmojiProvider.select((s) => s.codeToUrl));
  final hidden = ref.watch(hiddenEmojiProvider);
  final app = ref.read(appStateProvider);
  final page = computePublicStream(app, keys, pager,
      held: pager.scrolled || pager.pointer);
  final emoji = codes.keys.toSet();
  final texts = <PsParts>[
    for (final r in page.rows)
      hide
          ? PsParts.empty
          : psParts(
              previewBody(hidden
                  .strip(app.stripBlockedQuotes(r.m.content, r.m.quoted))),
              emoji: emoji,
              builtin: kBuiltinEmoji),
  ];
  return PublicStreamView(
    page,
    texts,
    _Sig([
      hide,
      for (var i = 0; i < page.rows.length; i++) ...[
        page.rows[i].id,
        texts[i],
        page.rows[i].m.author,
        page.rows[i].m.pubkey,
      ],
      codes,
      null,
      ...page.pendingIds,
      page.pendingMore,
      null,
      page.remaining,
      ...page.buttons,
    ]),
  );
});

int _orderAt(Message m) => m.anchorAt ?? m.createdAt;

int _orderMs(Message m) => m.anchorMs ?? m.ms;

PsPage<Message> computePublicStream(
    AppState s, List<String> keys, PublicStreamPager pager,
    {required bool held, int? nowSec}) {
  final now = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final release = pager.release;
  pager.release = false;
  final hold = !release && held;
  if (hold && pager.hold == null) pager.hold = psHold(pager.last, null);
  if (!hold) pager.hold = null;
  final lists = <PsList<Message>>[];
  final roots = <String, Set<String>?>{};
  final canFilter = channelFilterActive(s);
  for (final k in keys) {
    final sk = '#$k';
    if (s.isChannelBlockedKey(sk)) continue;
    final list = s.messages[sk];
    if (list == null || list.isEmpty) continue;
    lists.add(PsList(sk, list));
  }
  final page = psPage<Message>(
    lists,
    PsState(shown: pager.shown, hold: pager.hold),
    nowSec: now,
    at: _orderAt,
    ms: _orderMs,
    id: (m) => m.id,
    visible: (m, key) {
      final list = s.messages[key] ?? const <Message>[];
      final r = m.threadRoot == null
          ? null
          : roots.putIfAbsent(
              key,
              () => appThreadsEnabled && list.any((x) => x.threadRoot != null)
                  ? channelThreadRootIds(list)
                  : null);
      return channelMessageShown(s, m, list,
          canFilter: canFilter, nowSec: now, rootIds: r);
    },
  );
  final stamps = [for (final r in page.rows) r.stamp];
  if (pager.hold != null) pager.hold = psHold(stamps, pager.hold);
  pager.last = stamps;
  return page;
}

String _ui(String s, [Map<String, Object?>? vars]) => tr(s);

final Map<double, double> _timeWidths = {};

double _timeWidth(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(11);
  return _timeWidths.putIfAbsent(scale, () {
    final p = TextPainter(
      text: TextSpan(
          text: '88h',
          style: TextStyle(
              fontSize: scale,
              fontFeatures: const [FontFeature.tabularFigures()])),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = p.width.ceilToDouble();
    p.dispose();
    return w;
  });
}

class PublicStreamRow extends StatefulWidget {
  const PublicStreamRow({
    super.key,
    required this.id,
    required this.storageKey,
    required this.tag,
    required this.author,
    required this.pubkey,
    required this.parts,
    required this.ts,
    required this.hide,
    required this.onTap,
    this.own = false,
    this.onPointer,
  });

  final String id;
  final String storageKey;
  final String tag;
  final String author;
  final String pubkey;
  final PsParts parts;
  final int ts;
  final bool hide;
  final bool own;
  final VoidCallback onTap;
  final void Function(bool down)? onPointer;

  String get text => parts.text;

  @override
  State<PublicStreamRow> createState() => _PublicStreamRowState();
}

class _PublicStreamRowState extends State<PublicStreamRow> {
  List<InlineSpan> _body(BuildContext context, WidgetRef ref, TextStyle style,
      TextStyle suffix) {
    final codes =
        ref.watch(liveCustomEmojiProvider.select((s) => s.codeToUrl));
    final side = MediaQuery.textScalerOf(context).scale(NymType.sm) * 1.25;
    return [
      for (final p in widget.parts.parts)
        if (p.kind == 'e' && codes[p.value] != null)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: InlineNetworkImage(
              key: ValueKey('ps-emoji-${p.value}'),
              url: proxiedMedia(codes[p.value]!, emoji: true),
              width: side,
              height: side,
              fit: BoxFit.contain,
              retryOnError: true,
              errorChild: Text(':${p.value}:', style: style),
            ),
          )
        else if (p.kind == 'e')
          TextSpan(text: ':${p.value}:', style: style)
        else
          TextSpan(
              style: style,
              children: dimRangeSpans(
                  p.value, mentionSuffixRanges(p.value), suffix)),
    ];
  }

  Widget _thumbs(BuildContext context, WidgetRef ref, bool blur) {
    final c = context.nym;
    final reg = ref.watch(mediaFallbacksProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var i = 0; i < widget.parts.media.length; i++)
            if (widget.parts.media[i].kind == 'v')
              Container(
                key: ValueKey('ps-video-$i'),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    borderRadius: NymRadius.rxs,
                    color: c.text.withValues(alpha: 0.06)),
                alignment: Alignment.center,
                child: Icon(Icons.play_arrow_rounded, size: 18, color: c.textDim),
              )
            else
              ClipRRect(
                key: ValueKey('ps-thumb-$i'),
                borderRadius: NymRadius.rxs,
                child: InlineNetworkImage(
                  url: proxiedMedia(widget.parts.media[i].value),
                  fallbackUrls: [
                    for (final u in reg.fallbacksFor(widget.parts.media[i].value))
                      proxiedMedia(u)
                  ],
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  blurSigma: blur ? 20 : null,
                  placeholder: Container(
                      width: 48,
                      height: 48,
                      color: c.text.withValues(alpha: 0.06)),
                  errorChild: Container(
                    width: 48,
                    height: 48,
                    color: c.text.withValues(alpha: 0.06),
                    alignment: Alignment.center,
                    child: Icon(Icons.broken_image, size: 16, color: c.textDim),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final contrast = context.highContrast;
    final base = stripPubkeySuffix(widget.author.isEmpty ? tr('anon') : widget.author);
    final suffix = '#${getPubkeySuffix(widget.pubkey)}';
    final size = NymType.sm;
    final text = widget.text;
    return Consumer(builder: (context, ref, _) {
      final when = ref.watch(rowClockProvider.select((_) => relativeTime(
          DateTime.now().millisecondsSinceEpoch, widget.ts, _ui)));
      final (theme, colorful, bubbles) = ref.watch(settingsProvider
          .select((s) => (s.theme, s.colorfulMessages, s.useBubbles)));
      final blurSetting = ref.read(settingsProvider.notifier).blurImages;
      final cos = ref.watch(userCosmeticsProvider(widget.pubkey));
      final bitchat = theme == NymThemeKey.bitchat && !widget.own
          ? bitchatUserColor(widget.pubkey, isLight: c.isLight, contrast: contrast)
          : null;
      final line = TextStyle(
          fontSize: size, height: 1.4, color: c.text, fontWeight: FontWeight.w400);
      final who = line.copyWith(
          color: widget.own ? channelNymColor(c, cos.isRedacted ? redactedNymColor(c) : c.primary, contrast: contrast) : (bitchat ?? channelNymColor(c, c.secondary, contrast: contrast)),
          fontWeight: FontWeight.w600);
      final body = TextStyle(
        fontSize: size,
        height: kSidebarSubLine / size,
        fontWeight: FontWeight.w400,
        fontStyle: FontStyle.normal,
        color: channelBodyTextColor(c,
            cosmetics: cos,
            own: widget.own,
            pubkey: widget.pubkey,
            bitchatTheme: theme == NymThemeKey.bitchat,
            colorful: colorful,
            contrast: contrast,
            bubbles: bubbles),
      );
      final blur = !widget.own &&
          (blurSetting == 'true' ||
              (blurSetting == 'friends' &&
                  !ref.read(appStateProvider).isFriend(widget.pubkey)));
      final label = psRowLabel(
          time: when,
          channel: widget.tag,
          nym: '$base$suffix',
          text: text,
          hide: widget.hide);
      final showBody = widget.parts.parts.isNotEmpty;
      final showMedia = widget.parts.media.isNotEmpty;
      return Semantics(
        button: true,
        label: tr(label.template, label.vars),
        onTap: widget.onTap,
        excludeSemantics: true,
        child: Listener(
          onPointerDown: (_) => widget.onPointer?.call(true),
          onPointerUp: (_) => widget.onPointer?.call(false),
          onPointerCancel: (_) => widget.onPointer?.call(false),
          child: SidebarRowGestures(
            onTap: widget.onTap,
            onShowMenu: (_) => false,
            builder: (context, hovered) => Container(
                constraints: BoxConstraints(
                    minHeight: context.largeTouchTargets ? 44 : 32),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: NymRadius.rxs,
                  color: hovered ? sidebarRowHoverFill(c) : null,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    SizedBox(
                      width: _timeWidth(context),
                      child: Text(
                        when,
                        key: const ValueKey('ps-time'),
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.4,
                          color: c.textDim,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text.rich(
                            TextSpan(style: line, children: [
                              TextSpan(
                                  text: widget.tag,
                                  style: line.copyWith(color: c.primary)),
                              const TextSpan(text: ' '),
                              TextSpan(text: base, style: who),
                              TextSpan(
                                  text: suffix,
                                  style: nymSuffixStyle(who, contrast: contrast)),
                              if (showBody) ...[
                                const TextSpan(text: ' '),
                                TextSpan(
                                  style: body,
                                  children: _body(context, ref, body,
                                      nymSuffixStyle(body, contrast: contrast)),
                                ),
                              ],
                            ]),
                          ),
                          if (showMedia) _thumbs(context, ref, blur),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ),
        ),
      );
    });
  }
}

class PublicStreamPill extends StatelessWidget {
  const PublicStreamPill({super.key, required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Semantics(
      button: true,
      label: text,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: c.bgSecondary,
        shape: StadiumBorder(side: BorderSide(color: c.primaryA(0.5))),
        child: InkWell(
          key: const ValueKey('ps-pill'),
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Text(text,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(fontSize: 11, color: c.primary)),
          ),
        ),
      ),
    );
  }
}

class PublicStreamProbe extends SingleChildRenderObjectWidget {
  const PublicStreamProbe({super.key, required this.onLayout, required Widget sliver})
      : super(child: sliver);

  final void Function(double scrollOffset, double paintExtent) onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderPublicStreamProbe(onLayout);

  @override
  void updateRenderObject(
      BuildContext context, RenderPublicStreamProbe renderObject) {
    renderObject.onLayout = onLayout;
  }
}

class RenderPublicStreamProbe extends RenderProxySliver {
  RenderPublicStreamProbe(this.onLayout);

  void Function(double scrollOffset, double paintExtent) onLayout;

  @override
  void performLayout() {
    super.performLayout();
    onLayout(constraints.scrollOffset, geometry?.paintExtent ?? 0);
  }
}
