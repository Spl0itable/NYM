// relay_stats_modal.dart - `#relayStatsModal` port: the "Network Stats" modal
// (`openRelayStats` / `renderRelayStats`, app.js:7242-7680).
//
// Markup (index.html:1090-1146):
//   .modal > .modal-content.relay-stats-content
//     .modal-close (32px glass chip) · .modal-header "Network Stats"
//     .modal-body
//       .relay-stats-cards  → 5 cards: Connected / Avg Latency / Events /
//                              Data In / Data Out
//       .relay-stats-section "Throughput (events/sec)" → canvas graph
//       .relay-stats-section "Data transferred" → per-relay list
//       .relay-stats-low-data → Low-Data-Mode panel + nym-switch toggle
//
// Live data: the connected-relay COUNT (`appState.connectedRelays`, fed by
// `NostrService.onConnectionChanged`), the per-relay connection status
// (`NostrController.relayConnectionStatus`), and the real relay-traffic
// counters (`NostrController.relayStats` → `RelayStats`: avg latency, total
// events, bytes in/out, the throughput-history graph, and per-relay
// events/latency rows). A 1s `Timer.periodic` re-reads a `RelayStats.snapshot`
// each tick so every metric refreshes live (mirrors the PWA `_rsRenderInterval`
// 1s poll). When `relayStats` is null (pre-boot) OR a specific metric is absent,
// the PWA's real placeholder renders (`--` / `0` / `0 B` / flat graph) — NEVER a
// fabricated number. The Low-Data-Mode toggle is wired live to
// `settingsProvider.setLowDataMode` (mirrors `toggleLowDataModeFromStats`).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/relays.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/relay/relay_stats.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/nym_switch.dart';
import '../i18n/i18n.dart';

/// Width breakpoint at or below which the modal applies its phone layout:
/// 3-column stat cards, hidden per-relay latency column, and 18/14 content
/// padding (styles-themes-responsive.css:1496-1507 `@media max-width: 480px`).
const double _kMobileMaxWidth = 480;

class RelayStatsModal extends ConsumerStatefulWidget {
  const RelayStatsModal({super.key});

  /// Opens the Network Stats modal as a centered dialog (the PWA renders it as a
  /// `.modal` overlay, not a sheet). Wire this to the sidebar status-indicator
  /// (see CROSS_FILE_NEEDS).
  static Future<void> open(BuildContext context) {
    // `.modal` barrier: solid-ui (default) dark `rgba(0,0,0,0.75)` →
    // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
    // (styles-themes-responsive.css:1630-1635).
    final isLight = context.nym.isLight;
    return showDialog<void>(
      context: context,
      barrierColor: isLight
          ? const Color(0x73000000) // black @ 0.45
          : const Color(0xBF000000), // black @ 0.75
      builder: (_) => const RelayStatsModal(),
    );
  }

  @override
  ConsumerState<RelayStatsModal> createState() => _RelayStatsModalState();
}

class _RelayStatsModalState extends ConsumerState<RelayStatsModal> {
  // Mirrors the PWA `_rsRenderInterval` 1s poll (app.js:7339): re-read the live
  // counters every second so the cards/graph/rows refresh while the modal is up.
  Timer? _ticker;

  /// The url/key of the currently-expanded relay row (or `__api__` for the App
  /// data row), or null when none is expanded. Mirrors the PWA's
  /// `_rsExpandedRelay` (app.js:7506) — clicking a row toggles its kind/action
  /// breakdown.
  String? _expandedRow;

  void _toggleRow(String key) {
    setState(() => _expandedRow = _expandedRow == key ? null : key);
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Real connected-relay count (NostrService.onConnectionChanged → appState).
    final connected =
        ref.watch(appStateProvider.select((s) => s.connectedRelays));
    final lowData =
        ref.watch(settingsProvider.select((s) => s.lowDataMode));

    // Live relay traffic counters — typed getter on the controller, null before
    // boot. Already a fresh snapshot (the controller getter merges the pool's
    // live relay stats with the persistent /api "App data" counters), so a
    // per-second source mutation can't tear a frame (mirrors the PWA reading
    // `nym.relayStats` each tick).
    final stats = ref.read(nostrControllerProvider).relayStats;

    // Per-relay connection status (url → connected), typed getter; empty before
    // boot → the relay list shows the real "No relays connected" empty state.
    final relayStatus = ref.read(nostrControllerProvider).relayConnectionStatus;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          // .modal-content (radius 24, glass border, shadow + glow + 1px ring) +
          // .relay-stats-content (max-width 560, width 94%, padding 24).
          width: MediaQuery.of(context).size.width * 0.94,
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            borderRadius: NymRadius.rxl,
            border: Border.all(color: c.glassBorder),
            // `body.light-mode .modal-content { box-shadow: 0 8px 40px
            // rgba(0,0,0,0.12) }` — a single soft shadow, no glow/white ring
            // (styles-themes-responsive.css:1050-1052).
            boxShadow: c.isLight
                ? const [
                    BoxShadow(
                      color: Color(0x1F000000), // black @ 0.12
                      blurRadius: 40,
                      offset: Offset(0, 8),
                    ),
                  ]
                : [
                    const BoxShadow(
                      color: Color(0x80000000), // shadow-lg 0 8 32 black/0.5
                      blurRadius: 32,
                      offset: Offset(0, 8),
                    ),
                    BoxShadow(
                      color: c.primary.withValues(alpha: 0.1), // shadow-glow
                      blurRadius: 20,
                    ),
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.05), // 1px white ring
                      spreadRadius: 1,
                    ),
                  ],
          ),
          child: Stack(
            children: [
              Padding(
                // .relay-stats-content padding 24 → 18px 14px at ≤480px
                // (styles-themes-responsive.css:1501-1503).
                padding: MediaQuery.sizeOf(context).width <= _kMobileMaxWidth
                    ? const EdgeInsets.symmetric(vertical: 18, horizontal: 14)
                    : const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // .modal-header: 22px UPPERCASE primary + ls1.5 + bottom rule.
                    Container(
                      margin: const EdgeInsets.only(bottom: 24),
                      padding: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        border: Border(
                            bottom: BorderSide(color: c.glassBorder)),
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
                            ),
                            const SizedBox(height: 14),
                            _LowDataPanel(
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
              // .modal-close — 32px circular glass chip, top-right (14,14).
              Positioned(
                top: 14,
                right: 14,
                child: _CloseChip(
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Summary cards (.relay-stats-cards / .relay-stat-card)
// =============================================================================

class _Cards extends StatelessWidget {
  const _Cards({required this.connected, required this.stats});
  final int connected;

  /// Live relay counters, or null before boot. When null every untracked metric
  /// renders the PWA's literal placeholder (NEVER a fabricated value): latency
  /// `--`, events `0`, data in/out `0 B`.
  final RelayStats? stats;

  @override
  Widget build(BuildContext context) {
    // Real values when [stats] is available; PWA placeholders otherwise.
    // Avg Latency: `avgLat !== null ? avgLat + 'ms' : '--'` (app.js:7391).
    final latency = stats?.averageLatencyMs != null
        ? '${stats!.averageLatencyMs}ms'
        : '--';
    // Events: k-abbreviated total (app.js:7392).
    final events =
        stats != null ? _abbreviateCount(stats!.totalEvents) : '0';
    // Data In / Out: formatBytes (app.js:7393-7394).
    final dataIn = stats != null ? formatBytes(stats!.bytesReceived) : '0 B';
    final dataOut = stats != null ? formatBytes(stats!.bytesSent) : '0 B';

    // 5-up grid (.relay-stats-cards: grid 5, gap 6); 3 columns at ≤480px
    // (styles-themes-responsive.css:1497-1499).
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

/// k-abbreviated event count, mirroring the PWA Events card
/// (`s.totalEvents > 9999 ? (s.totalEvents / 1000).toFixed(1) + 'k' :
/// s.totalEvents`, app.js:7392): only past 9999 does it switch to `X.Xk`.
String _abbreviateCount(int n) =>
    n > 9999 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

/// Human-readable byte size, a 1:1 port of the PWA `formatBytes` (app.js:7347):
/// `< 1024` → `N B`; `< 1MiB` → `X.X KB`; `< 1GiB` → `X.X MB`; else `X.XX GB`.
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
        // .relay-stat-card: white/0.03 fill, glass border, radius 12.
        // `body.light-mode .relay-stat-card { rgba(0,0,0,0.03) }`
        // (styles-themes-responsive.css:1479-1481).
        color: c.isLight
            ? const Color(0x08000000) // black @ 0.03
            : Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        children: [
          // .relay-stat-value: mono 14, w700, primary.
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
          // .relay-stat-label: 9px UPPERCASE textDim, ls0.4.
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

// =============================================================================
// Section title (.relay-stats-section-title)
// =============================================================================

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

// =============================================================================
// Throughput graph (.relay-stats-graph-wrap > canvas)
// =============================================================================

class _ThroughputSection extends StatelessWidget {
  const _ThroughputSection({required this.history});

  /// Last ≤60 per-second event counts (oldest→newest). Empty before any sample
  /// → the flat-baseline placeholder.
  final List<int> history;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(tr('Throughput (events/sec)')),
        Container(
          // .relay-stats-graph-wrap: white/0.02 fill, glass border, radius 12,
          // padding 10. Canvas is 100px tall.
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            // `body.light-mode .relay-stats-graph-wrap { rgba(0,0,0,0.02) }`
            // (styles-themes-responsive.css:1483-1486).
            color: c.isLight
                ? const Color(0x05000000) // black @ 0.02
                : Colors.white.withValues(alpha: 0.02),
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
          ),
          child: SizedBox(
            height: 100,
            width: double.infinity,
            // Real polyline once samples exist; the empty list renders the flat
            // baseline + `0/s`/`0` labels the PWA draws for `data=[0]`, max=1.
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

/// Port of the PWA `drawThroughputGraph` (app.js:7424): plots the last ≤60
/// per-second event counts as a fill + 1.5px polyline (newest at the right),
/// scaled to `max(1, …history)`, with `<max>/s` (top-right) and `0`
/// (bottom-right) mono-9px labels. An empty list collapses to `data=[0]`,
/// max=1 → the flat baseline the PWA draws before any sample exists.
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

    // data = history.length > 0 ? history : [0] (app.js:7442).
    final data = history.isNotEmpty ? history : const [0];
    final maxVal = math.max(1, data.reduce(math.max));
    const points = 60;
    final stepX = w / (points - 1);
    // Right-align: the freshest sample sits at index `points - 1` (app.js:7456).
    final startIdx = math.max(0, points - data.length);

    double xAt(int i) => (startIdx + i) * stepX;
    double yAt(int i) => h - (data[i] / maxVal) * (h - 4) - 2;

    // Fill gradient under the line (primary 0.25 → 0.02 top→bottom).
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

    // Polyline (primary stroke 1.5, round join).
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

    // Scale labels (mono 9px, right-aligned), matching the canvas text.
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

// =============================================================================
// Relay list (.relay-stats-relay-list / .relay-stats-row)
//
// Mirrors the PWA `renderRelayList` (app.js 7554-7680): up to two
// sub-sections inside the list — "App data" (the /api backend, clickable for a
// per-action breakdown) and "Relay data" (clickable per relay for a per-kind
// breakdown). The PWA's shard fan-in line above the list (`rsShardLine`,
// app.js 7399-7420) is intentionally omitted in the native app.
// =============================================================================

class _RelayListSection extends StatelessWidget {
  const _RelayListSection({
    required this.relayStatus,
    required this.stats,
    required this.expandedRow,
    required this.onToggleRow,
  });

  /// Per-relay url → open (empty before boot → real empty state).
  final Map<String, bool> relayStatus;

  /// Live counters for the per-relay events/latency columns; null before boot.
  final RelayStats? stats;

  /// Currently-expanded row key (`__api__` or a relay url), or null.
  final String? expandedRow;

  /// Toggle a row's expansion by key.
  final ValueChanged<String> onToggleRow;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    // Build the relay rows from REAL per-relay status; the empty status map
    // leaves the list showing the PWA's real empty state ("No relays
    // connected"). Each row carries its real `eventsPerRelay`/`latencyPerRelay`
    // value (absent → 0 events / `--` latency — never a fabricated number).
    final entries = <_RelayRowData>[];
    for (final e in relayStatus.entries) {
      if (RelayConfig.writeOnlyRelays.contains(e.key)) continue;
      entries.add(_RelayRowData(
        url: e.key,
        open: e.value,
        events: stats?.eventsPerRelay[e.key] ?? 0,
        latency: stats?.latencyPerRelay[e.key],
      ));
    }
    // PWA sort: connected first, then by events DESC (app.js:7592-7595).
    entries.sort((a, b) {
      if (a.open != b.open) return a.open ? -1 : 1;
      return b.events - a.events;
    });

    final hasApiData = stats?.hasApiData ?? false;

    // Compose the list rows: "App data" + its api row, then "Relay data" + its
    // relay rows (`renderRelayList`'s `ordered` assembly, app.js:7606).
    final rows = <Widget>[];
    final contentEmpty = entries.isEmpty && !hasApiData;
    if (contentEmpty) {
      // .nm-app-5 empty state ("No relays connected", app.js:7601) — shown
      // inside the list box, below the shard line if one exists.
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
      if (entries.isNotEmpty) {
        rows.add(_ListSubHeader(tr('Relay data')));
        for (final e in entries) {
          rows.add(_RelayRow(
            data: e,
            stats: stats,
            expanded: expandedRow == e.url,
            onTap: () => onToggleRow(e.url),
          ));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(tr('Data transferred')),
        Container(
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            // .relay-stats-relay-list: white/0.02 fill, glass border, radius 12.
            // `body.light-mode .relay-stats-relay-list { rgba(0,0,0,0.02) }`
            // (styles-themes-responsive.css:1483-1486).
            color: c.isLight
                ? const Color(0x05000000) // black @ 0.02
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
/// Key for the App-data row's expansion state (the PWA uses the literal
/// `'__api__'` url, app.js:7611).
const String _kApiRowKey = '__api__';

/// A `.relay-stats-section-title` rendered INSIDE the list (the "App data" /
/// "Relay data" sub-headers, app.js:7609/7617).
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

  /// Unique inbound events from this relay (`eventsPerRelay[url] ?? 0`).
  final int events;

  /// Last measured latency in ms, or null → render `--` (`latencyPerRelay[url]`).
  final int? latency;
}

/// Shared row chrome: a dot + url + latency + a right-aligned metric, optionally
/// expanded to a kind/action breakdown. Mirrors `.relay-stats-row`.
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
        // .relay-stats-row: padding 8/12, gap 10, bottom border white/0.04.
        // `body.light-mode .relay-stats-row { border-bottom-color: rgba(0,0,0,0.06) }`
        // (styles-themes-responsive.css:1492-1494).
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: c.isLight
                  ? const Color(0x0F000000) // black @ 0.06
                  : Colors.white.withValues(alpha: 0.04),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                // .relay-stats-dot: 6px, open=primary (glow) / closed=danger.
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
                // .relay-stats-url: mono 11, textDim, ellipsized.
                Expanded(
                  child: Tooltip(
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
                // .relay-stats-latency: mono 11, textDim, right. `<ms>ms`/`--`.
                // Hidden at ≤480px (`display: none`,
                // styles-themes-responsive.css:1505-1507) — the gap before it
                // collapses too (CSS flex gap).
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
                // .relay-stats-events: mono 11, right. `<n> evt` or `<bytes> ↓`.
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
                // .relay-stats-detail: margin-top 6, padding-left 16.
                padding: const EdgeInsets.only(top: 6, left: 16),
                child: detail!,
              ),
          ],
        ),
      ),
    );
  }
}

/// A single relay row, expandable to its per-kind breakdown
/// (`rsRenderRelayDetail`'s kind branch, app.js:7541).
class _RelayRow extends StatelessWidget {
  const _RelayRow({
    required this.data,
    required this.stats,
    required this.expanded,
    required this.onTap,
  });
  final _RelayRowData data;
  final RelayStats? stats;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shortUrl =
        data.url.replaceFirst('wss://', '').replaceFirst('ws://', '');
    return _StatsRow(
      open: data.open,
      label: shortUrl,
      tooltip: data.url,
      latency: data.latency,
      // `<n> evt` per-relay event count (app.js:7652).
      metric: tr('{n} evt', {'n': data.events}),
      metricColor: context.nym.textBright,
      expanded: expanded,
      onTap: onTap,
      detail:
          expanded ? _KindDetail(perKind: stats?.kindStatsPerRelay[data.url]) : null,
    );
  }
}

/// The App-data ("app backend") row, expandable to its per-action breakdown
/// (`rsRenderRelayDetail`'s `__api__` branch, app.js:7516).
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
    // The PWA row shows `${formatBytes(bytesReceived)} ↓` as the metric and the
    // `app backend` label; the dot is open when the api socket is open. Native
    // has no persistent api socket, so treat any recorded api data as "open".
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

/// Per-kind breakdown rows (`kind <k>` · `<n> evt` · `<bytes>`), sorted by bytes
/// DESC. Mirrors `rsRenderRelayDetail` (app.js:7546-7551).
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

/// Per-action /api breakdown rows (`<label>` · `<n>×` · `<bytes>`), sorted by
/// bytes DESC, with the PWA's friendly action labels (app.js:7522).
class _ApiActionDetail extends StatelessWidget {
  const _ApiActionDetail({required this.actions});
  final Map<String, ApiActionStat> actions;

  /// PWA action → friendly label (app.js:7522-7530).
  static const Map<String, String> _labels = {
    'channel-get': 'Channel history',
    'channel-activity': 'Channel activity',
    'channel-active': 'Active channels',
    'channel-delete': 'Channel cleanup',
    'pm-get': 'Direct messages',
    'pm-put': 'Message backup',
    'pm-deposit': 'Message delivery',
    'pm-delete': 'Message cleanup',
    'profile-get': 'Profiles',
    'profile-set': 'Profile updates',
    'emoji-get': 'Emoji',
    'settings-get': 'Settings',
    'settings-set': 'Settings sync',
    'auth': 'Sign-in',
    'other': 'Other',
  };

  /// Title-case fallback so no raw hyphenated action ever shows (app.js:7532).
  static String _labelFor(String action) {
    final known = _labels[action];
    if (known != null) return known;
    final words = action.split(RegExp(r'[-_]+')).where((w) => w.isNotEmpty);
    return words
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
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

/// One `.rs-kind-row`: a 3-column mono-10 grid (label · count · bytes), the
/// last two right-aligned (app.js CSS .rs-kind-row).
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
            child: Text(left, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(mid, textAlign: TextAlign.right, style: style)),
          const SizedBox(width: 10),
          Expanded(child: Text(right, textAlign: TextAlign.right, style: style)),
        ],
      ),
    );
  }
}

// =============================================================================
// Low-Data-Mode panel (.relay-stats-low-data) + nym-switch toggle
// =============================================================================

class _LowDataPanel extends StatelessWidget {
  const _LowDataPanel({required this.enabled, required this.onToggle});
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      // .relay-stats-low-data: flex, gap 12, padding 12/14, white/0.03 fill,
      // glass border, radius 12.
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        // `body.light-mode .relay-stats-low-data { rgba(0,0,0,0.03) }`
        // (styles-themes-responsive.css:1467-1469 / :596-598).
        color: c.isLight
            ? const Color(0x08000000) // black @ 0.03
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
                // .relay-stats-low-data-title: 13, w600, textBright.
                Text(
                  tr('Using too much data?'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.textBright,
                  ),
                ),
                const SizedBox(height: 2),
                // .relay-stats-low-data-hint: 11, textDim, line-height 1.4.
                Text(
                  tr('Enable Low Data Mode to limit relay connections to a small '
                      'core set and load geo relays only when entering channels.'),
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
  }
}

// =============================================================================
// Close chip (.modal-close)
// =============================================================================

/// 32×32 circular glass close chip with a danger hover (`.modal-close`).
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
    return MouseRegion(
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
              color: hovered
                  ? c.danger.withValues(alpha: 0.3)
                  : c.glassBorder,
            ),
          ),
          child: Text(
            '✕',
            style: TextStyle(
              color: hovered ? c.danger : c.textDim,
              fontSize: 16,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
