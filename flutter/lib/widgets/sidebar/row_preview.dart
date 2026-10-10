import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show Bidi;

import '../../core/theme/nym_a11y.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/chat_lock/chat_lock_providers.dart';
import '../../features/i18n/i18n.dart';
import '../../features/layout/layout_model.dart';
import '../../features/messages/format/nym_format.dart';
import '../../features/notifications/notifications_service.dart';
import '../../features/search/unified_search_panel.dart' show nymSuffixStyle;
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import 'sidebar_chrome.dart';

final rowClockProvider = StateProvider<int>((ref) => 0);

typedef RowLast = ({
  String id,
  String author,
  String pubkey,
  String content,
  bool own,
  int ts
});

typedef RowPreview = ({
  String text,
  List<List<int>> dim,
  List<int>? sender,
  int bodyAt,
  String time,
  int ts
});

const RowPreview kNoRowPreview =
    (text: '', dim: <List<int>>[], sender: null, bodyAt: 0, time: '', ts: 0);

RowLast? lastPreviewable(AppState s, List<Message>? list) {
  final m = s.lastVisibleMessage(list);
  if (m == null) return null;
  final ts = m.ms > 0 ? m.ms : m.createdAt * 1000;
  return (
    id: m.id,
    author: m.author,
    pubkey: m.pubkey,
    content: m.content,
    own: m.isOwn,
    ts: ts,
  );
}

String _ui(String s, [Map<String, Object?>? vars]) => tr(s);

String previewBody(String content) =>
    NymFormat.stripForPreview(notificationBodyFor(content));

RowPreview sidebarRowPreview(WidgetRef ref, String storageKey, String kind) {
  final last = ref.watch(
      appStateProvider.select((s) => lastPreviewable(s, s.messages[storageKey])));
  final hide = ref.watch(settingsProvider.select((s) => s.hidePreviews));
  ref.watch(chatLockRevisionProvider);
  ref.watch(rowClockProvider);
  if (last == null) return kNoRowPreview;
  final live = ref.watch(usersProvider.select((u) => u[last.pubkey]?.nym));
  final lock = ref.read(chatLockProvider);
  final locked = lock.isConversationLocked(storageKey);
  final parts = rowPreviewParts(
    kind: kind,
    author: pickDisplayNym(live, last.author),
    pubkey: last.pubkey,
    self: last.own,
    text: previewBody(last.content),
    hide: hide,
    locked: locked,
    redacted: locked ? lock.redact('', '', true).body : '',
    t: _ui,
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  return (
    text: parts.text,
    dim: parts.dim,
    sender: parts.sender,
    bodyAt: parts.bodyAt,
    time: relativeTime(now, last.ts, _ui),
    ts: last.ts,
  );
}

List<TextSpan> _dimSpans(String text, List<List<int>> dim, int from, int to,
    TextStyle suffix) {
  final spans = <TextSpan>[];
  var at = from;
  for (final r in dim) {
    final a = math.max(r[0], from);
    final b = math.min(r[1], to);
    if (b <= a) continue;
    if (a > at) spans.add(TextSpan(text: text.substring(at, a)));
    spans.add(TextSpan(text: text.substring(a, b), style: suffix));
    at = b;
  }
  if (at < to) spans.add(TextSpan(text: text.substring(at, to)));
  return spans;
}

TextDirection isolatedDirection(String text, TextDirection ambient) {
  if (Bidi.startsWithRtl(text)) return TextDirection.rtl;
  if (Bidi.startsWithLtr(text)) return TextDirection.ltr;
  return ambient;
}

Widget rowPreviewLine(BuildContext context, String text, String kind,
    [List<List<int>> dim = const [], List<int>? sender, int? bodyAt]) {
  final c = context.nym;
  final style = TextStyle(
      color: c.textDim,
      fontSize: NymType.sm,
      height: kSidebarSubLine / NymType.sm);
  final suffix = nymSuffixStyle(style, contrast: context.highContrast);
  final key = ValueKey('rowPreview-$kind');
  final lead = bodyAt ??
      (sender != null && sender.length == 2 ? sender[1] + 2 : 0);
  final at = lead > 1 && lead <= text.length ? lead : 0;
  final nameEnd = sender != null &&
          sender.length == 2 &&
          sender[0] > 0 &&
          sender[1] + 2 == at
      ? sender[0]
      : at - 2;
  final body = _PreviewBody(
    key: at > 0 ? null : key,
    text: text,
    dim: dim,
    from: at,
    style: style,
    suffix: suffix,
  );
  return Padding(
    padding: const EdgeInsets.only(top: 1),
    child: at > 0
        ? _SenderPreview(
            key: key,
            name: text.substring(0, nameEnd),
            tag: TextSpan(
                style: style,
                children: _dimSpans(text, dim, nameEnd, at, suffix)),
            body: body,
            bodySpan: TextSpan(
                style: style,
                children: _dimSpans(text, dim, at, text.length, suffix)),
            style: style,
          )
        : body,
  );
}

class _PreviewMeasure {
  _PreviewMeasure(BuildContext context, TextStyle style)
      : scaler = MediaQuery.textScalerOf(context),
        _inherited = DefaultTextStyle.of(context),
        _root = _rootStyle(context, style),
        _locale = Localizations.maybeLocaleOf(context),
        _heightBehavior = DefaultTextStyle.of(context).textHeightBehavior ??
            DefaultTextHeightBehavior.maybeOf(context);

  final TextScaler scaler;
  final DefaultTextStyle _inherited;
  final TextStyle _root;
  final Locale? _locale;
  final TextHeightBehavior? _heightBehavior;

  static TextStyle _rootStyle(BuildContext context, TextStyle style) {
    var root = DefaultTextStyle.of(context).style.merge(style);
    if (MediaQuery.boldTextOf(context)) {
      root = root.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    return root;
  }

  double width(InlineSpan span, TextDirection dir) {
    final painter = TextPainter(
      text: TextSpan(style: _root, children: [span]),
      textDirection: dir,
      textScaler: scaler,
      maxLines: 1,
      textWidthBasis: _inherited.textWidthBasis,
      textHeightBehavior: _heightBehavior,
      locale: _locale,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    super.key,
    required this.text,
    required this.dim,
    required this.from,
    required this.style,
    required this.suffix,
  });

  final String text;
  final List<List<int>> dim;
  final int from;
  final TextStyle style;
  final TextStyle suffix;

  TextSpan _span(int to, {bool ellipsis = false}) => TextSpan(
        style: style,
        children: [
          ..._dimSpans(text, dim, from, to, suffix),
          if (ellipsis) const TextSpan(text: '…'),
        ],
      );

  int _fit(_PreviewMeasure m, TextDirection dir, double max) {
    final ends = <int>[from];
    var at = from;
    for (final g in text.substring(from).characters) {
      at += g.length;
      ends.add(at);
    }
    bool fits(int to) =>
        m.width(_span(to, ellipsis: true), dir) <= max + 0.01;
    var lo = 0;
    var hi = ends.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (fits(ends[mid])) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    var cut = ends[lo];
    for (final r in dim) {
      if (r[0] < cut && cut < r[1]) cut = math.max(r[0], from);
    }
    return cut;
  }

  @override
  Widget build(BuildContext context) {
    final ambient = Directionality.of(context);
    final dir = isolatedDirection(text.substring(from), ambient);
    final rest =
        ambient == TextDirection.ltr ? TextAlign.left : TextAlign.right;
    return LayoutBuilder(builder: (context, box) {
      var span = _span(text.length);
      String? label;
      if (box.hasBoundedWidth) {
        final m = _PreviewMeasure(context, style);
        if (m.width(span, dir) > box.maxWidth + 0.01) {
          span = _span(_fit(m, dir, box.maxWidth), ellipsis: true);
          label = text.substring(from);
        }
      }
      return Text.rich(
        span,
        key: const ValueKey('rowPreviewBody'),
        style: style,
        textDirection: dir,
        textAlign: label == null ? rest : TextAlign.start,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        semanticsLabel: label,
      );
    });
  }
}

class _SenderPreview extends StatelessWidget {
  const _SenderPreview({
    super.key,
    required this.name,
    required this.tag,
    required this.body,
    required this.bodySpan,
    required this.style,
  });

  final String name;
  final TextSpan tag;
  final Widget body;
  final TextSpan bodySpan;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final m = _PreviewMeasure(context, style);
    final dir = Directionality.of(context);
    return LayoutBuilder(builder: (context, box) {
      if (!box.hasBoundedWidth) {
        return Text.rich(
            TextSpan(children: [TextSpan(text: name), tag, bodySpan]),
            style: style,
            maxLines: 1,
            softWrap: false);
      }
      final tagWidth = m.width(tag, dir);
      final keep =
          m.scaler.scale(style.fontSize ?? NymType.sm) * kPreviewBodyMinEm;
      final need = tagWidth + keep;
      final nameMax = math.max(box.maxWidth, need) - need;
      final row = Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: nameMax),
            child: Text(
              name,
              key: const ValueKey('rowPreviewName'),
              style: style,
              textDirection: isolatedDirection(name, dir),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
          Text.rich(
            tag,
            key: const ValueKey('rowPreviewTag'),
            style: style,
            maxLines: 1,
            softWrap: false,
          ),
          Expanded(child: body),
        ],
      );
      if (need <= box.maxWidth) return row;
      return UnconstrainedBox(
        constrainedAxis: Axis.vertical,
        alignment: AlignmentDirectional.centerStart,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(width: need, child: row),
      );
    });
  }
}

Widget rowTimeLabel(BuildContext context, String time) {
  if (time.isEmpty) return const SizedBox.shrink();
  final c = context.nym;
  return Padding(
    padding: const EdgeInsets.only(left: NymSpace.s1),
    child: Text(
      time,
      key: const ValueKey('rowTime'),
      style: TextStyle(
        color: c.textDim,
        fontSize: NymType.xs,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}
