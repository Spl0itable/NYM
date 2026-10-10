import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_a11y.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import '../identity/deleted_notice.dart' show dimRangeSpans;
import '../layout/layout_model.dart';
import '../mesh/mesh_controller.dart';
import '../search/unified_search_panel.dart' show nymSuffixStyle;
import 'geo_explore.dart';

enum GeoPeekReach { online, offline, meshOnly }

String _peekTr(String s, [Map<String, Object?>? vars]) => tr(s);

abstract class GeoPeekSource {
  GeoPeekReach reach(String geohash);
  Future<GeoPeekSummary?> peek(String geohash, bool Function() isCancelled);
}

class _ControllerPeekSource implements GeoPeekSource {
  _ControllerPeekSource(this._ref);
  final Ref _ref;

  @override
  GeoPeekReach reach(String geohash) {
    final bridge = _ref.read(meshControllerProvider.notifier).bridge;
    if (bridge != null &&
        bridge.shouldSendOverMesh(ChatView.channel(geohash.toLowerCase()))) {
      return GeoPeekReach.meshOnly;
    }
    if (_ref.read(appStateProvider).connectedRelays <= 0) {
      return GeoPeekReach.offline;
    }
    return GeoPeekReach.online;
  }

  @override
  Future<GeoPeekSummary?> peek(String geohash, bool Function() isCancelled) =>
      _ref
          .read(nostrControllerProvider)
          .peekGeohash(geohash, isCancelled: isCancelled);
}

final geoPeekSourceProvider =
    Provider<GeoPeekSource>((ref) => _ControllerPeekSource(ref));

class GeoPeekView extends ConsumerStatefulWidget {
  const GeoPeekView({super.key, required this.geohash, this.onSummary});

  final String geohash;
  final void Function(String geohash, GeoPeekSummary summary)? onSummary;

  @override
  ConsumerState<GeoPeekView> createState() => _GeoPeekViewState();
}

class _GeoPeekViewState extends ConsumerState<GeoPeekView> {
  GeoPeekReach _reach = GeoPeekReach.online;
  GeoPeekSummary? _summary;
  bool _loading = false;
  bool _failed = false;
  bool _cancelled = false;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(GeoPeekView old) {
    super.didUpdateWidget(old);
    if (old.geohash != widget.geohash) _start();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  void _start() {
    final token = ++_token;
    final source = ref.read(geoPeekSourceProvider);
    _summary = null;
    _failed = false;
    _reach = source.reach(widget.geohash);
    if (_reach != GeoPeekReach.online) {
      _loading = false;
      return;
    }
    _loading = true;
    bool stale() => _cancelled || token != _token;
    source.peek(widget.geohash, stale).then((s) {
      if (!mounted || stale()) return;
      setState(() {
        _loading = false;
        _summary = s;
        _failed = s == null;
      });
      if (s != null) widget.onSummary?.call(widget.geohash, s);
    }, onError: (_) {
      if (!mounted || stale()) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    final Widget body;
    if (_reach != GeoPeekReach.online) {
      body = _note(
        Icons.cloud_off,
        _reach == GeoPeekReach.meshOnly
            ? tr('Peek needs the internet. Over the Bluetooth mesh, join the channel to see its messages.')
            : tr("You're offline. Peek shows recent messages once you're back online."),
        nym,
        key: const ValueKey('geo-peek-offline'),
      );
    } else if (_loading) {
      body = _note(Icons.hourglass_empty, tr('Loading recent messages...'), nym,
          key: const ValueKey('geo-peek-loading'));
    } else if (_failed) {
      body = _note(Icons.error_outline,
          tr("Couldn't load recent messages."), nym);
    } else if (_summary == null || _summary!.messages.isEmpty) {
      body = _note(Icons.chat_bubble_outline,
          tr('No recent messages in this channel.'), nym);
    } else {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      body = Table(
        columnWidths: const {
          0: IntrinsicColumnWidth(),
          1: FlexColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          for (final m in _summary!.messages)
            _message(m, nym, nowMs, context.highContrast),
        ],
      );
    }
    final online = _summary?.online;
    return Semantics(
      container: true,
      label: tr('Recent messages, read only'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('Recent messages'),
                  style: TextStyle(
                      fontSize: 12,
                      color: nym.text,
                      fontWeight: FontWeight.w700),
                ),
              ),
              if (online != null)
                Text(
                  online == 1
                      ? tr('1 nym online')
                      : tr('{n} nyms online', {'n': online}),
                  key: const ValueKey('geo-peek-online'),
                  style: TextStyle(fontSize: 11, color: nym.textDim),
                ),
            ],
          ),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
  }

  Widget _note(IconData icon, String text, NymColors nym, {Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: nym.textDim),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 11, color: nym.textDim)),
          ),
        ],
      ),
    );
  }

  TableRow _message(
      GeoPeekMessage m, NymColors nym, int nowMs, bool contrast) {
    final base = stripPubkeySuffix(m.nym.isEmpty ? tr('anon') : m.nym);
    final whoStyle = TextStyle(
        fontSize: 11, color: nym.secondary, fontWeight: FontWeight.w600);
    final textStyle = TextStyle(fontSize: 11, color: nym.text);
    return TableRow(children: [
      Padding(
        padding: const EdgeInsets.only(top: 3, bottom: 3, right: 6),
        child: Text(
          relativeTime(nowMs, m.createdAt * 1000, _peekTr),
          key: const ValueKey('geo-peek-time'),
          textAlign: TextAlign.end,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            fontSize: 11,
            color: nym.textDim,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: base, style: whoStyle),
            TextSpan(
              text: '#${getPubkeySuffix(m.pubkey)}',
              style: nymSuffixStyle(whoStyle, contrast: contrast),
            ),
            TextSpan(text: ' ', style: whoStyle),
            TextSpan(
              style: textStyle,
              children: dimRangeSpans(m.content, mentionSuffixRanges(m.content),
                  nymSuffixStyle(textStyle, contrast: contrast)),
            ),
          ]),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]);
  }
}
