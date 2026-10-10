// Network Stats modal: live relay counters re-read every second; missing metrics show placeholders.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/relays.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/relay/relay_stats.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../services/platform/background_connectivity.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/nym_switch.dart';
import '../i18n/i18n.dart';
import '../settings/settings_widgets.dart';
import '../../widgets/common/nym_focusable.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_tooltip.dart';
import 'blocked_relays.dart';
import 'relay_block.dart';

/// At or below this width: 3-column cards, no latency column, tighter padding.
const double _kMobileMaxWidth = 480;

class RelayStatsModal extends ConsumerStatefulWidget {
  const RelayStatsModal({super.key});

  static Future<void> open(BuildContext context) {
    final isLight = context.nym.isLight;
    return showNymSheet<void>(
      context,
      (_) => const RelayStatsModal(),
      barrierColor: isLight
          ? const Color(0x73000000)
          : const Color(0xBF000000),
    );
  }

  @override
  ConsumerState<RelayStatsModal> createState() => _RelayStatsModalState();
}

class _RelayStatsModalState extends ConsumerState<RelayStatsModal> {
  // Re-read live counters every second while open.
  Timer? _ticker;

  /// Expanded row key (`__api__` for App data), or null.
  String? _expandedRow;

  void _toggleRow(String key) {
    setState(() => _expandedRow = _expandedRow == key ? null : key);
  }

  bool _switching = false;

  Future<void> _useDirect() async {
    if (_switching) return;
    final nostr = ref.read(nostrControllerProvider);
    if (!nostr.relayDirectAcknowledged) {
      final ok = await showAppConfirm(
        context,
        tr('Nymchat will disconnect from the relay pool proxy and connect to '
            'each relay directly. Images, videos, voice messages, avatars, '
            'custom emoji, GIFs and link previews will also load straight from '
            'the sites that host them, and uploads will go straight to them. '
            'Relays and those sites will see your IP address, and the '
            "proxy's spam filtering won't apply. You can switch back anytime "
            'from Network Stats.'),
        title: tr('Use direct connections?'),
        okLabel: tr('Use direct'),
      );
      if (!ok) return;
      nostr.acknowledgeRelayDirect();
    }
    await _runSwitch(() => nostr.setUserDirectMode(true));
  }

  Future<void> _useProxy() async {
    if (_switching) return;
    final nostr = ref.read(nostrControllerProvider);
    if (nostr.isUserDirectMode) {
      await _runSwitch(() => nostr.setUserDirectMode(false));
    } else {
      nostr.retryProxyNow();
      if (mounted) setState(() {});
    }
  }

  Future<void> _runSwitch(Future<void> Function() action) async {
    setState(() => _switching = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  String get _query => _search.text.trim();

  void _clearSearch() {
    _search.clear();
    setState(() {});
    _searchFocus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_search.text.isEmpty) return KeyEventResult.ignored;
    _clearSearch();
    return KeyEventResult.handled;
  }

  Future<void> _confirmBlock(String url) async {
    final nostr = ref.read(nostrControllerProvider);
    final why = nostr.relayBlockGuard(url);
    if (why != 'ok' && why != 'signer') return;
    final shown = RelayBlock.shown(url);
    final parts = <String>[
      if (why == 'signer')
        tr('{relay} is the relay your remote signer uses. Your signer keeps '
            'its own connection, so signing still works.', {'relay': shown}),
      tr('Block {relay}? The app stops connecting to it for this account, '
          'here and on your other devices.', {'relay': shown}),
    ];
    final bare = nostr.relayBlockLeavesGeoBare(url);
    if (bare.isNotEmpty) {
      parts.add(tr('Live messages in #{geohash} need one of its nearest '
          'relays, and this is the last one you have not blocked.',
          {'geohash': bare}));
    }
    parts.add(tr("History the app backend already stored can't be filtered "
        "by relay, and blocking doesn't reduce app backend traffic."));
    final ok = await showAppConfirm(
      context,
      parts.join('\n\n'),
      title: tr('Block relay?'),
      okLabel: tr('Block'),
      danger: true,
    );
    if (!ok || !mounted) return;
    final res = nostr.blockRelay(url, confirmed: why == 'signer');
    setState(() {
      if (res == 'blocked' && _expandedRow == url) _expandedRow = null;
    });
  }

  void _unblock(String url) {
    ref.read(nostrControllerProvider).unblockRelay(url);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final connected =
        ref.watch(appStateProvider.select((s) => s.connectedRelays));
    final lowData = ref.watch(settingsProvider.select((s) => s.lowDataMode));
    final backgroundConnectivity =
        ref.watch(settingsProvider.select((s) => s.backgroundConnectivity));

    // Fresh merged snapshot each tick, null before boot, so a mid-second mutation can't tear a frame.
    final stats = ref.read(nostrControllerProvider).relayStats;

    // url -> connected; empty before boot, showing the "No relays connected" state.
    final relayStatus = ref.read(nostrControllerProvider).relayConnectionStatus;
    final proxyMode = ref.watch(appStateProvider.select((s) => s.proxyMode));
    final nostr = ref.read(nostrControllerProvider);
    final blocked = ref.watch(blockedRelaysProvider);
    final fallbackActive = nostr.isProxyFallbackActive;
    final userDirect = nostr.isUserDirectMode;

    final body = Stack(
      children: [
        Padding(
          padding: MediaQuery.sizeOf(context).width <= _kMobileMaxWidth
              ? const EdgeInsets.symmetric(vertical: 18, horizontal: 14)
              : const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 24),
                padding: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: c.glassBorder)),
                ),
                child: Text(
                  tr('NETWORK STATS'),
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ConnectionModeLine(
                        connected: connected,
                        proxyMode: proxyMode,
                        fallbackActive: fallbackActive,
                        userDirect: userDirect,
                        canSwitch: nostr.canSwitchRelayTransport,
                        switching: _switching ||
                            (fallbackActive &&
                                nostr.isProxyRetryInFlight),
                        onUseDirect: _useDirect,
                        onUseProxy: _useProxy,
                      ),
                      const SizedBox(height: 12),
                      _Cards(connected: connected, stats: stats),
                      const SizedBox(height: 14),
                      _ThroughputSection(
                        history: stats?.throughputHistory ?? const [],
                      ),
                      const SizedBox(height: 14),
                      _RelayListSection(
                        relayStatus: relayStatus,
                        stats: stats,
                        expandedRow: _expandedRow,
                        onToggleRow: _toggleRow,
                        query: _query,
                        search: Semantics(
                          label: tr('Search relays'),
                          textField: true,
                          child: FormInput(
                            key: const ValueKey('relay-search'),
                            controller: _search,
                            focusNode: _searchFocus,
                            hint: tr('Search relays'),
                            prefix: Icon(Icons.search,
                                size: 16, color: c.textDim),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        onClearSearch: _clearSearch,
                        guardFor: nostr.relayBlockGuard,
                        onBlock: _confirmBlock,
                        blocked: blocked.toSet(),
                      ),
                      const SizedBox(height: 12),
                      _BlockedSection(
                        blocked: blocked,
                        query: _query,
                        geoNoteFor: nostr.relayBlockGeoNote,
                        onUnblock: _unblock,
                      ),
                      if (BackgroundConnectivityService.isSupported) ...[
                        const SizedBox(height: 14),
                        _TogglePanel(
                          title: tr('Stay connected in background'),
                          hint: tr('Keep relay connections and the '
                              'Bluetooth mesh running while Nymchat is in '
                              'the background, so messages and '
                              'notifications arrive without opening it. '
                              'Uses more battery and data. On iOS the system '
                              'decides when a suspended app may catch up, '
                              'so notifications can lag; with identity '
                              'encryption on, catch-up works only once '
                              'the device has been unlocked at least once '
                              'since it was powered on.'),
                          enabled: backgroundConnectivity,
                          onToggle: (v) => ref
                              .read(settingsProvider.notifier)
                              .setBackgroundConnectivity(v),
                        ),
                      ],
                      const SizedBox(height: 14),
                      _TogglePanel(
                        title: tr('Using too much data?'),
                        semanticLabel: tr('Low Data Mode'),
                        hint: tr('Enable Low Data Mode to connect only to '
                            'the 18 default relays and load geo relays only '
                            'for the channels you open.'),
                        enabled: lowData,
                        onToggle: (v) => ref
                            .read(settingsProvider.notifier)
                            .setLowDataMode(v),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 14,
          right: 14,
          child: _CloseChip(
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
    final keyed = FocusScope(
      autofocus: true,
      onKeyEvent: _onKey,
      child: body,
    );
    return nymSheetOr(
      context,
      keyed,
      (body) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: MediaQuery.of(context).size.width * 0.94,
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
            decoration: BoxDecoration(
              color: c.bgSecondary,
              borderRadius: NymRadius.rxl,
              border: Border.all(color: c.glassBorder),
              boxShadow: c.isLight
                  ? const [
                      BoxShadow(
                        color: Color(0x1F000000),
                        blurRadius: 40,
                        offset: Offset(0, 8),
                      ),
                    ]
                  : [
                      const BoxShadow(
                        color: Color(0x80000000),
                        blurRadius: 32,
                        offset: Offset(0, 8),
                      ),
                      BoxShadow(
                        color: c.primary.withValues(alpha: 0.1),
                        blurRadius: 20,
                      ),
                      BoxShadow(
                        color: Colors.white
                            .withValues(alpha: 0.05),
                        spreadRadius: 1,
                      ),
                    ],
            ),
            child: body,
          ),
        ),
      ),
    );
  }
}

class _ConnectionModeLine extends StatelessWidget {
  const _ConnectionModeLine({
    required this.connected,
    required this.proxyMode,
    required this.fallbackActive,
    this.userDirect = false,
    this.canSwitch = false,
    this.switching = false,
    this.onUseDirect,
    this.onUseProxy,
  });

  final int connected;
  final bool proxyMode;
  final bool fallbackActive;
  final bool userDirect;
  final bool canSwitch;
  final bool switching;
  final VoidCallback? onUseDirect;
  final VoidCallback? onUseProxy;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final String value;
    final String hint;
    if (proxyMode) {
      value = tr('Proxy');
      hint = tr('Relay pool proxy: one multiplexed connection, relays only '
          'see the proxy, spam filtering applies.');
    } else if (userDirect) {
      value = tr('Direct');
      hint = tr('Direct relay connections, chosen by you: relays and media '
          "hosts see your IP address and the proxy's spam filtering doesn't "
          'apply.');
    } else if (connected > 0 || fallbackActive) {
      value = tr('Direct');
      hint = fallbackActive
          ? tr('Direct relay connections: the proxy was unreachable, so the '
              'app talks to relays itself and will switch back when it '
              'recovers.')
          : tr('Direct relay connections: the app talks to each relay '
              'itself.');
    } else {
      value = tr('Connecting...');
      hint = '';
    }
    final Widget? action;
    if (!canSwitch) {
      action = null;
    } else if (userDirect && !proxyMode) {
      action = _ModeButton(
        key: const ValueKey('relay-mode-use-proxy'),
        label: tr('Use proxy'),
        tooltip: tr('Reconnect through the relay pool proxy'),
        onTap: switching ? null : onUseProxy,
      );
    } else if (fallbackActive && !proxyMode) {
      action = _ModeButton(
        key: const ValueKey('relay-mode-use-proxy'),
        label: tr('Use proxy'),
        tooltip: tr('Try reconnecting to the proxy now'),
        onTap: switching ? null : onUseProxy,
      );
    } else {
      action = _ModeButton(
        key: const ValueKey('relay-mode-use-direct'),
        label: tr('Use direct'),
        tooltip:
            tr('Disconnect from the proxy and connect to relays directly'),
        onTap: switching ? null : onUseDirect,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                tr('Connection').toUpperCase(),
                style: TextStyle(
                  color: c.textDim,
                  fontSize: 9,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                value,
                style: TextStyle(
                  color: c.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
              if (action != null) ...[
                const Spacer(),
                action,
              ],
            ],
          ),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              hint,
              style: TextStyle(color: c.textDim, fontSize: 11, height: 1.35),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeButton extends StatefulWidget {
  const _ModeButton({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  State<_ModeButton> createState() => _ModeButtonState();
}

class _ModeButtonState extends State<_ModeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final enabled = widget.onTap != null;
    final hovered = _hover && enabled;
    return NymTooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.tooltip,
        excludeSemantics: true,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: widget.onTap,
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: NymRadius.rsm,
                  color: hovered
                      ? c.primary.withValues(alpha: 0.12)
                      : Colors.white.withValues(alpha: 0.05),
                  border: Border.all(
                    color: hovered
                        ? c.primary.withValues(alpha: 0.4)
                        : c.glassBorder,
                  ),
                ),
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: hovered ? c.primary : c.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Cards extends StatelessWidget {
  const _Cards({required this.connected, required this.stats});
  final int connected;

  /// Null before boot; untracked metrics then show `--`, `0` or `0 B`.
  final RelayStats? stats;

  @override
  Widget build(BuildContext context) {
    // `<avg>ms`, or `--` without data.
    final latency =
        stats?.averageLatencyMs != null ? '${stats!.averageLatencyMs}ms' : '--';
    // k-abbreviated total.
    final events = stats != null ? _abbreviateCount(stats!.totalEvents) : '0';
    final dataIn = stats != null ? formatBytes(stats!.bytesReceived) : '0 B';
    final dataOut = stats != null ? formatBytes(stats!.bytesSent) : '0 B';

    // 5 columns, 3 at ≤480px.
    final columns =
        MediaQuery.sizeOf(context).width <= _kMobileMaxWidth ? 3 : 5;
    return LayoutBuilder(builder: (context, cons) {
      const gap = 6.0;
      final cardW = (cons.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          _StatCard(width: cardW, value: '$connected', label: tr('Connected')),
          _StatCard(width: cardW, value: latency, label: tr('Avg Latency')),
          _StatCard(width: cardW, value: events, label: tr('Events')),
          _StatCard(width: cardW, value: dataIn, label: tr('Data In')),
          _StatCard(width: cardW, value: dataOut, label: tr('Data Out')),
        ],
      );
    });
  }
}

/// Switches to `X.Xk` only past 9999.
String _abbreviateCount(int n) =>
    n > 9999 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

/// `N B`, `X.X KB`, `X.X MB`, else `X.XX GB` (binary units).
String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
  return '${(b / 1073741824).toStringAsFixed(2)} GB';
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.width,
    required this.value,
    required this.label,
  });
  final double width;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 3),
      decoration: BoxDecoration(
        color: c.isLight
            ? const Color(0x08000000)
            : Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: c.primary,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label.toUpperCase(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9,
              color: c.textDim,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: c.textDim,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ThroughputSection extends StatelessWidget {
  const _ThroughputSection({required this.history});

  /// Last ≤60 per-second counts, oldest first; empty shows a flat baseline.
  final List<int> history;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(tr('Throughput (events/sec)')),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.isLight
                ? const Color(0x05000000)
                : Colors.white.withValues(alpha: 0.02),
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
          ),
          child: SizedBox(
            height: 100,
            width: double.infinity,
            // Empty data renders the flat baseline with `0/s` and `0` labels.
            child: CustomPaint(
              painter: _ThroughputPainter(
                history: history,
                line: c.primary,
                label: c.textDim,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Last ≤60 per-second counts as a filled polyline, newest at right, scaled to max(1, …history).
class _ThroughputPainter extends CustomPainter {
  _ThroughputPainter({
    required this.history,
    required this.line,
    required this.label,
  });

  final List<int> history;
  final Color line;
  final Color label;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final data = history.isNotEmpty ? history : const [0];
    final maxVal = math.max(1, data.reduce(math.max));
    const points = 60;
    final stepX = w / (points - 1);
    // Right-align so the freshest sample sits at the last index.
    final startIdx = math.max(0, points - data.length);

    double xAt(int i) => (startIdx + i) * stepX;
    double yAt(int i) => h - (data[i] / maxVal) * (h - 4) - 2;

    // Fill gradient under the line (primary 0.25 to 0.02).
    final fillPath = Path()..moveTo(xAt(0), h);
    for (var i = 0; i < data.length; i++) {
      fillPath.lineTo(xAt(i), yAt(i));
    }
    fillPath.lineTo(xAt(data.length - 1), h);
    fillPath.close();
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          line.withValues(alpha: 0.25),
          line.withValues(alpha: 0.02),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawPath(fillPath, fillPaint);

    final linePath = Path()..moveTo(xAt(0), yAt(0));
    for (var i = 1; i < data.length; i++) {
      linePath.lineTo(xAt(i), yAt(i));
    }
    final strokePaint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, strokePaint);

    // Right-aligned mono 9px scale labels.
    void drawLabel(String text, double anchorRight, double baselineY) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: label,
            fontSize: 9,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(anchorRight - tp.width, baselineY));
    }

    drawLabel('$maxVal/s', w - 2, 2);
    drawLabel('0', w - 2, h - 12);
  }

  @override
  bool shouldRepaint(covariant _ThroughputPainter old) =>
      old.line != line ||
      old.label != label ||
      !_sameHistory(old.history, history);

  static bool _sameHistory(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// "App data" (per-action breakdown) and "Relay data" (per-kind breakdown) sub-sections; the shard line is omitted.

class _RelayListSection extends StatelessWidget {
  const _RelayListSection({
    required this.relayStatus,
    required this.stats,
    required this.expandedRow,
    required this.onToggleRow,
    this.query = '',
    this.search,
    this.onClearSearch,
    this.guardFor,
    this.onBlock,
    this.blocked = const {},
  });

  final Set<String> blocked;
  final String query;
  final Widget? search;
  final VoidCallback? onClearSearch;
  final String Function(String url)? guardFor;
  final ValueChanged<String>? onBlock;

  /// url -> open; empty before boot.
  final Map<String, bool> relayStatus;

  /// Live counters for per-relay events and latency; null before boot.
  final RelayStats? stats;

  /// Expanded row key (`__api__` or a relay url), or null.
  final String? expandedRow;

  final ValueChanged<String> onToggleRow;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    // Rows from real per-relay status; absent counters show 0 events and `--` latency.
    final entries = <_RelayRowData>[];
    for (final e in relayStatus.entries) {
      if (RelayConfig.writeOnlyRelays.contains(e.key)) continue;
      if (RelayBlock.isBlocked(blocked, e.key)) continue;
      entries.add(_RelayRowData(
        url: e.key,
        open: e.value,
        events: stats?.eventsPerRelay[e.key] ?? 0,
        latency: stats?.latencyPerRelay[e.key],
      ));
    }
    // Connected first, then events descending.
    entries.sort((a, b) {
      if (a.open != b.open) return a.open ? -1 : 1;
      return b.events - a.events;
    });

    final searching = query.isNotEmpty;
    final total = entries.length;
    final shown = searching
        ? [
            for (final e in entries)
              if (RelayBlock.searchMatch(e.url, query)) e
          ]
        : entries;

    final hasApiData = !searching && (stats?.hasApiData ?? false);

    final rows = <Widget>[];
    final contentEmpty = !searching && entries.isEmpty && !hasApiData;
    if (searching && shown.isEmpty) {
      rows.add(Padding(
        key: const ValueKey('relay-search-empty'),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Text(
              tr("No relays match '{query}'", {'query': query}),
              style: TextStyle(color: c.textDim, fontSize: 12),
            ),
            _SmallButton(
              key: const ValueKey('relay-search-clear'),
              label: tr('Clear'),
              onTap: onClearSearch,
            ),
          ],
        ),
      ));
    } else if (contentEmpty) {
      // Empty state inside the list box.
      rows.add(Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          tr('No relays connected'),
          style: TextStyle(color: c.textDim, fontSize: 12),
        ),
      ));
    } else {
      if (hasApiData) {
        rows.add(_ListSubHeader(tr('App data')));
        rows.add(_ApiRow(
          stats: stats!,
          expanded: expandedRow == _kApiRowKey,
          onTap: () => onToggleRow(_kApiRowKey),
        ));
      }
      if (shown.isNotEmpty) {
        rows.add(_ListSubHeader(tr('Relay data')));
        for (final e in shown) {
          rows.add(_RelayRow(
            key: ValueKey('relay-row-${e.url}'),
            data: e,
            stats: stats,
            expanded: expandedRow == e.url,
            onTap: () => onToggleRow(e.url),
            guard: guardFor?.call(e.url) ?? 'invalid',
            onBlock: onBlock == null ? null : () => onBlock!(e.url),
          ));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(tr('Data transferred')),
        if (search != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(child: search!),
                if (searching) ...[
                  const SizedBox(width: 8),
                  Text(
                    tr('{n} of {m}', {'n': shown.length, 'm': total}),
                    key: const ValueKey('relay-search-count'),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: c.textDim,
                    ),
                  ),
                ],
              ],
            ),
          ),
        Container(
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: c.isLight
                ? const Color(0x05000000)
                : Colors.white.withValues(alpha: 0.02),
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
      ],
    );
  }
}

/// Expansion key for the App-data row.
const String _kApiRowKey = '__api__';

/// Section title rendered inside the list.
class _ListSubHeader extends StatelessWidget {
  const _ListSubHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: c.textDim,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _RelayRowData {
  const _RelayRowData({
    required this.url,
    required this.open,
    required this.events,
    required this.latency,
  });
  final String url;
  final bool open;

  /// Unique inbound events from this relay.
  final int events;

  /// Last latency in ms, or null for `--`.
  final int? latency;
}

/// Shared row chrome: dot, url, latency and a right-aligned metric, optionally expanded.
class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.open,
    required this.label,
    required this.tooltip,
    required this.latency,
    required this.metric,
    required this.metricColor,
    required this.expanded,
    required this.onTap,
    this.detail,
  });

  final bool open;
  final String label;
  final String tooltip;
  final int? latency;
  final String metric;
  final Color metricColor;
  final bool expanded;
  final VoidCallback onTap;
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: c.isLight
                  ? const Color(0x0F000000)
                  : Colors.white.withValues(alpha: 0.04),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: open ? c.primary : c.danger,
                    boxShadow: [
                      BoxShadow(
                        color: (open ? c.primary : c.danger)
                            .withValues(alpha: open ? 0.5 : 0.4),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: NymTooltip(
                    message: tooltip,
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: c.textDim,
                      ),
                    ),
                  ),
                ),
                // Latency column hidden at ≤480px, along with its gap.
                if (MediaQuery.sizeOf(context).width > _kMobileMaxWidth) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 45,
                    child: Text(
                      latency != null ? '${latency}ms' : '--',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: c.textDim,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                SizedBox(
                  width: 60,
                  child: Text(
                    metric,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: metricColor,
                    ),
                  ),
                ),
              ],
            ),
            if (expanded && detail != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 16),
                child: detail!,
              ),
          ],
        ),
      ),
    );
  }
}

/// Relay row, expandable to its per-kind breakdown.
class _RelayRow extends StatelessWidget {
  const _RelayRow({
    super.key,
    required this.data,
    required this.stats,
    required this.expanded,
    required this.onTap,
    this.guard = 'invalid',
    this.onBlock,
  });
  final _RelayRowData data;
  final RelayStats? stats;
  final bool expanded;
  final VoidCallback onTap;
  final String guard;
  final VoidCallback? onBlock;

  @override
  Widget build(BuildContext context) {
    final shortUrl =
        data.url.replaceFirst('wss://', '').replaceFirst('ws://', '');
    return _StatsRow(
      open: data.open,
      label: shortUrl,
      tooltip: data.url,
      latency: data.latency,
      metric: tr('{n} evt', {'n': data.events}),
      metricColor: context.nym.textBright,
      expanded: expanded,
      onTap: onTap,
      detail: expanded
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _KindDetail(perKind: stats?.kindStatsPerRelay[data.url]),
                _RelayActions(guard: guard, onBlock: onBlock),
              ],
            )
          : null,
    );
  }
}

class _RelayActions extends StatelessWidget {
  const _RelayActions({required this.guard, this.onBlock});
  final String guard;
  final VoidCallback? onBlock;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final noteStyle = TextStyle(color: c.textDim, fontSize: 11, height: 1.35);
    Widget? body;
    if (guard == 'required') {
      body = Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 6,
        children: [
          Container(
            key: const ValueKey('relay-required'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.glassBorder),
            ),
            child: Text(
              tr('Required'),
              style: TextStyle(
                color: c.text,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            tr("The app relay carries Nymchat's own channels and can't be "
                'blocked.'),
            style: noteStyle,
          ),
        ],
      );
    } else if (guard == 'ok' || guard == 'signer' || guard == 'last-default') {
      final last = guard == 'last-default';
      body = Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 6,
        children: [
          _SmallButton(
            key: const ValueKey('relay-block'),
            label: tr('Block'),
            danger: true,
            onTap: last ? null : onBlock,
          ),
          if (last)
            Text(
              tr('Keep at least one default relay unblocked: direct '
                  'connections read from these.'),
              style: noteStyle,
            ),
        ],
      );
    }
    if (body == null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: 8), child: body);
  }
}

class _SmallButton extends StatefulWidget {
  const _SmallButton({
    super.key,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final String? semanticsLabel;

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final enabled = widget.onTap != null;
    final hovered = _hover && enabled;
    final accent = widget.danger ? c.danger : c.primary;
    final fg = widget.danger ? c.danger : (hovered ? c.primary : c.text);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticsLabel ?? widget.label,
      excludeSemantics: true,
      child: NymFocusable(
        onActivate: widget.onTap,
        radius: NymRadius.rsm,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          cursor:
              enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Container(
                constraints: const BoxConstraints(minHeight: 28),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: NymRadius.rsm,
                  color: widget.danger
                      ? c.danger.withValues(alpha: hovered ? 0.18 : 0.08)
                      : (c.isLight ? Colors.black : Colors.white)
                          .withValues(alpha: hovered ? 0.08 : 0.05),
                  border: Border.all(
                    color: widget.danger
                        ? c.danger.withValues(alpha: 0.4)
                        : (hovered ? accent : c.glassBorder),
                  ),
                ),
                child: Align(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BlockedSection extends StatelessWidget {
  const _BlockedSection({
    required this.blocked,
    required this.query,
    required this.geoNoteFor,
    required this.onUnblock,
  });

  final List<String> blocked;
  final String query;
  final String Function(String url) geoNoteFor;
  final ValueChanged<String> onUnblock;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final list = query.isEmpty
        ? blocked
        : [
            for (final u in blocked)
              if (RelayBlock.searchMatch(u, query)) u
          ];
    final rows = <Widget>[];
    if (blocked.isEmpty || list.isEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Text(
          blocked.isEmpty
              ? tr('No blocked relays. Open a relay above to block it.')
              : tr("No blocked relays match '{query}'", {'query': query}),
          style: TextStyle(color: c.textDim, fontSize: 12),
        ),
      ));
    }
    for (var i = 0; i < list.length; i++) {
      final url = list[i];
      final note = geoNoteFor(url);
      final shown = RelayBlock.shown(url);
      rows.add(Container(
        key: ValueKey('blocked-relay-$url'),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        decoration: BoxDecoration(
          border: i == list.length - 1
              ? null
              : Border(
                  bottom: BorderSide(
                    color: c.isLight
                        ? const Color(0x0F000000)
                        : Colors.white.withValues(alpha: 0.04),
                  ),
                ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: NymTooltip(
                    message: url,
                    child: Text(
                      shown,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: c.textDim,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _SmallButton(
                  key: ValueKey('relay-unblock-$url'),
                  label: tr('Unblock'),
                  semanticsLabel: tr('Unblock {relay}', {'relay': shown}),
                  onTap: () => onUnblock(url),
                ),
              ],
            ),
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  tr('Live messages in #{geohash} need one of its nearest '
                      'relays. Unblock one of them to receive them.',
                      {'geohash': note}),
                  style:
                      TextStyle(color: c.textDim, fontSize: 11, height: 1.35),
                ),
              ),
          ],
        ),
      ));
    }
    return Column(
      key: const ValueKey('relay-blocked-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(tr('Blocked ({n})', {'n': blocked.length})),
        Container(
          decoration: BoxDecoration(
            color: c.isLight
                ? const Color(0x05000000)
                : Colors.white.withValues(alpha: 0.02),
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          tr("Blocking stops live traffic with a relay for this account on "
              "every device. History the app backend already stored can't be "
              "filtered by relay, because the backend doesn't record which "
              "relay a message came from, and blocking doesn't reduce app "
              'backend traffic.'),
          style: TextStyle(color: c.textDim, fontSize: 11, height: 1.35),
        ),
        if (RelayConfig.writeOnlyRelays.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            tr("Messages you send are also published to {relay}, a "
                "publish-only relay. It isn't listed here and can't be "
                'blocked.', {
              'relay':
                  RelayConfig.writeOnlyRelays.map(RelayBlock.shown).join(', '),
            }),
            key: const ValueKey('relay-blocked-publish-only'),
            style: TextStyle(color: c.textDim, fontSize: 11, height: 1.35),
          ),
        ],
      ],
    );
  }
}

/// App-data row, expandable to its per-action breakdown.
class _ApiRow extends StatelessWidget {
  const _ApiRow({
    required this.stats,
    required this.expanded,
    required this.onTap,
  });
  final RelayStats stats;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Native has no persistent api socket, so any recorded api data reads as open.
    return _StatsRow(
      open: stats.hasApiData,
      label: tr('app backend'),
      tooltip: tr('App backend (D1 storage, profiles, messages)'),
      latency: null,
      metric: '${formatBytes(stats.apiBytesReceived)} ↓',
      metricColor: c.textBright,
      expanded: expanded,
      onTap: onTap,
      detail: expanded ? _ApiActionDetail(actions: stats.apiActionStats) : null,
    );
  }
}

/// Per-kind rows sorted by bytes descending.
class _KindDetail extends StatelessWidget {
  const _KindDetail({required this.perKind});
  final Map<int, KindStat>? perKind;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final pk = perKind;
    if (pk == null || pk.isEmpty) {
      return Text(
        tr('No events recorded from this relay yet.'),
        style: TextStyle(color: c.textDim, fontSize: 10),
      );
    }
    final rows = pk.entries.toList()
      ..sort((a, b) => b.value.bytes - a.value.bytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in rows)
          _KindRow(
            left: tr('kind {k}', {'k': e.key}),
            mid: tr('{n} evt', {'n': e.value.count}),
            right: formatBytes(e.value.bytes),
          ),
      ],
    );
  }
}

/// Per-action rows sorted by bytes descending, with friendly labels.
class _ApiActionDetail extends StatelessWidget {
  const _ApiActionDetail({required this.actions});
  final Map<String, ApiActionStat> actions;

  static const Map<String, String> _labels = {
    'channel-get': 'Channel history',
    'channel-activity': 'Channel activity',
    'channel-active': 'Active channels',
    'channel-delete': 'Channel cleanup',
    'pm-get': 'Private messages',
    'pm-get:inbox': 'Group messages',
    'pm-put': 'Message backup',
    'pm-deposit': 'Message delivery',
    'pm-delete': 'Message cleanup',
    'profile-get': 'Profiles',
    'profile-set': 'Profile updates',
    'emoji-get': 'Emoji',
    'settings-get': 'Settings',
    'settings-set': 'Settings sync',
    'settings-delete': 'Settings cleanup',
    'shop-status': 'Shop status',
    'filter-get': 'Filters',
    'auth': 'Sign-in',
    'other': 'Other',
  };

  /// Title-case fallback so no raw hyphenated action shows.
  static String _labelFor(String action) {
    final known = _labels[action];
    if (known != null) return tr(known);
    final words = action.split(RegExp(r'[-_:]+')).where((w) => w.isNotEmpty);
    return words.map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    if (actions.isEmpty) {
      return Text(
        tr('No app data recorded yet.'),
        style: TextStyle(color: c.textDim, fontSize: 10),
      );
    }
    final rows = actions.entries.toList()
      ..sort((a, b) => b.value.bytes - a.value.bytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in rows)
          _KindRow(
            left: _labelFor(e.key),
            mid: '${e.value.count}×',
            right: formatBytes(e.value.bytes),
          ),
      ],
    );
  }
}

/// 3-column mono row (label, count, bytes), the last two right-aligned.
class _KindRow extends StatelessWidget {
  const _KindRow({required this.left, required this.mid, required this.right});
  final String left;
  final String mid;
  final String right;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 10,
      color: c.textDim,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(left,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(mid, textAlign: TextAlign.right, style: style)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(right, textAlign: TextAlign.right, style: style)),
        ],
      ),
    );
  }
}

/// Titled toggle row in the footer, for connectivity switches beside the traffic they affect.
class _TogglePanel extends StatelessWidget {
  const _TogglePanel({
    required this.title,
    required this.hint,
    required this.enabled,
    required this.onToggle,
    this.semanticLabel,
  });
  final String title;
  final String hint;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final panel = Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: c.isLight
            ? const Color(0x08000000)
            : Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.textBright,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: TextStyle(
                    fontSize: 11,
                    color: c.textDim,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          NymSwitch(value: enabled, onChanged: onToggle),
        ],
      ),
    );
    return MergeSemantics(
      child: Semantics(
        toggled: enabled,
        label: semanticLabel ?? title,
        hint: hint,
        onTap: () => onToggle(!enabled),
        child: ExcludeSemantics(child: panel),
      ),
    );
  }
}

/// 32x32 circular glass close chip with a danger hover.
class _CloseChip extends StatefulWidget {
  const _CloseChip({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseChip> createState() => _CloseChipState();
}

class _CloseChipState extends State<_CloseChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hovered = _hover;
    return NymFocusable(
      onActivate: widget.onTap,
      tooltip: tr('Close'),
      excludeChildSemantics: true,
      radius: const BorderRadius.all(Radius.circular(16)),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hovered
                  ? c.danger.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.05),
              border: Border.all(
                color: hovered ? c.danger.withValues(alpha: 0.3) : c.glassBorder,
              ),
            ),
            child: Icon(
              Icons.close,
              size: 16,
              color: hovered ? c.danger : c.textDim,
            ),
          ),
        ),
      ),
    );
  }
}
