import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/relays.dart';
import '../../core/crypto/bech32_codec.dart' show encodeNevent;
import '../../core/crypto/pow.dart' show getPow;
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/i18n/i18n.dart';
import '../../models/nostr_event.dart';
import '../../services/nostr/event_provenance.dart';
import '../../state/nostr_controller.dart';

/// Everything known about the event behind a message: the signed JSON, and
/// which relays delivered it.
///
/// Mirrors the PWA's event details modal. What it can show depends on where
/// the message came from, so it shows what it has rather than nothing: the
/// session's own record first, then the D1 archive for a message rendered from
/// local storage on a later launch, and failing both the fields the rendered
/// message itself carries.
Future<void> showEventDetails(
  BuildContext context, {
  required String eventId,
  String? pubkey,
  String? nym,
  String? channel,
  DateTime? createdAt,
  int? powTarget,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (_) => _EventDetailsDialog(
      eventId: eventId,
      pubkey: pubkey,
      nym: nym,
      channel: channel,
      createdAt: createdAt,
      powTarget: powTarget,
    ),
  );
}

class _EventDetailsDialog extends ConsumerStatefulWidget {
  const _EventDetailsDialog({
    required this.eventId,
    this.pubkey,
    this.nym,
    this.channel,
    this.createdAt,
    this.powTarget,
  });

  final String eventId;
  final String? pubkey;
  final String? nym;
  final String? channel;
  final DateTime? createdAt;
  final int? powTarget;

  @override
  ConsumerState<_EventDetailsDialog> createState() => _EventDetailsDialogState();
}

class _EventDetailsDialogState extends ConsumerState<_EventDetailsDialog> {
  NostrEvent? _event;
  List<String> _relays = const [];
  DateTime? _firstSeen;
  bool _looking = false;

  @override
  void initState() {
    super.initState();
    final rec = eventProvenance.of(widget.eventId);
    if (rec != null) {
      _event = rec.event;
      _relays = List<String>.from(rec.relays);
      _firstSeen = rec.firstSeen;
    } else {
      _looking = true;
      _fetchArchived();
    }
  }

  Future<void> _fetchArchived() async {
    final controller = ref.read(nostrControllerProvider);
    var ev = await controller.archivedEvent(widget.eventId);
    var source = 'NYMCHAT ARCHIVE';
    if (ev == null) {
      ev = await controller.relayEvent(widget.eventId);
      source = 'RELAY LOOKUP';
    }
    if (!mounted) return;
    setState(() {
      _looking = false;
      if (ev != null) {
        _event = ev;
        final rec = eventProvenance.of(ev.id);
        _relays = rec != null && rec.relays.isNotEmpty
            ? List<String>.from(rec.relays)
            : [source];
        _firstSeen ??= rec?.firstSeen;
      }
    });
  }

  String get _json =>
      _event == null ? '' : const JsonEncoder.withIndent('  ').convert(_event!.toJson());

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final media = MediaQuery.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: media.size.height * 0.86,
        ),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          borderRadius: NymRadius.rxl,
          border: Border.all(color: c.glassBorder),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Event Details').toUpperCase(),
                    style: TextStyle(
                      color: c.primary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: c.textDim),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: tr('Close'),
                ),
              ],
            ),
            Divider(color: c.glassBorder, height: 20),
            Flexible(child: SingleChildScrollView(child: _body(c))),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_event != null) ...[
                  _Btn(
                    label: tr('Copy Raw JSON'),
                    onTap: () => Clipboard.setData(ClipboardData(text: _json)),
                  ),
                  const SizedBox(width: 8),
                ],
                _Btn(
                  label: tr('Close'),
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(NymColors c) {
    final ev = _event;
    final rows = <Widget>[_section(c, tr('Event')), _row(c, tr('ID'), widget.eventId, mono: true)];

    final pk = ev?.pubkey ?? widget.pubkey;
    if (pk != null && pk.isNotEmpty) {
      rows.add(_row(c, tr('Public key'), pk, mono: true));
      final nevent = encodeNevent(widget.eventId,
          author: pk, relays: RelayConfig.defaultRelays.take(3).toList());
      if (nevent.isNotEmpty) rows.add(_row(c, tr('nevent'), nevent, mono: true));
    }
    if (widget.nym != null && widget.nym!.isNotEmpty) {
      rows.add(_row(c, tr('Nym'), widget.nym!));
    }
    if (ev != null) rows.add(_row(c, tr('Kind'), '${ev.kind}'));
    final ch = widget.channel;
    if (ch != null && ch.isNotEmpty) rows.add(_row(c, tr('Channel'), ch));

    final created = ev != null
        ? DateTime.fromMillisecondsSinceEpoch(ev.createdAt * 1000, isUtc: true)
        : widget.createdAt?.toUtc();
    if (created != null) {
      final secs = created.millisecondsSinceEpoch ~/ 1000;
      rows.add(_row(c, tr('Created at'), '$secs (${created.toIso8601String()})'));
    }
    if (_firstSeen != null) {
      rows.add(_row(c, tr('First seen'), _firstSeen!.toUtc().toIso8601String()));
    }
    if (ev != null && ev.sig.isNotEmpty) {
      rows.add(_row(c, tr('Signature'), ev.sig, mono: true));
    }
    if (ev != null) {
      rows.add(_row(c, tr('Size'), '${_json.length} bytes, ${ev.tags.length} tags'));
    }

    // Reported the way the filter counts it, not by leading zeros alone: the
    // two disagree exactly when a sender got lucky under a cheap commitment.
    final actual = getPow(widget.eventId);
    final target = _committedTarget(ev) ?? widget.powTarget;
    rows.add(_row(
      c,
      tr('Proof of work'),
      target != null && target > 0
          ? '$actual bits, committed $target, counts as ${actual >= target ? target : 0}'
          : '$actual bits, no commitment, counts as 0',
    ));

    rows.add(_section(
        c, '${tr('Received from')} ${_relays.length} ${_relays.length == 1 ? tr('source') : tr('sources')}'));
    if (_relays.isEmpty) {
      rows.add(_dim(c, tr('No source recorded.')));
    } else {
      for (final r in _relays) {
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(r,
              style: TextStyle(
                  color: c.text, fontSize: 11, fontFamily: 'monospace')),
        ));
      }
    }

    rows.add(_section(c, tr('Raw event')));
    if (ev != null) {
      rows.add(Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.18),
          borderRadius: NymRadius.rsm,
          border: Border.all(color: c.glassBorder),
        ),
        child: SelectableText(
          _json,
          style: TextStyle(
              color: c.text, fontSize: 11, height: 1.45, fontFamily: 'monospace'),
        ),
      ));
    } else {
      rows.add(_dim(
          c,
          _looking
              ? tr('Looking for the signed event in the archive…')
              : tr('Nothing is archived for this event, so only what this '
                  'client stored for display is shown above. Messages carried '
                  'over the mesh are never archived.')));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  int? _committedTarget(NostrEvent? ev) {
    if (ev == null) return null;
    for (final t in ev.tags) {
      if (t.isNotEmpty && t[0] == 'nonce' && t.length > 2) {
        return int.tryParse(t[2]);
      }
    }
    return null;
  }

  Widget _section(NymColors c, String label) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(),
                style: TextStyle(
                    color: c.textDim,
                    fontSize: 11,
                    letterSpacing: 0.66,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Divider(color: c.glassBorder, height: 1),
          ],
        ),
      );

  Widget _row(NymColors c, String label, String value, {bool mono = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 116,
              child: Text(label,
                  style: TextStyle(color: c.textDim, fontSize: 12)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SelectableText(
                value,
                style: TextStyle(
                  color: c.text,
                  fontSize: mono ? 11 : 12,
                  fontFamily: mono ? 'monospace' : null,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _dim(NymColors c, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text,
            style: TextStyle(color: c.textDim, fontSize: 12, height: 1.5)),
      );
}

class _Btn extends StatelessWidget {
  const _Btn({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      color: Colors.white.withValues(alpha: 0.05),
      borderRadius: NymRadius.rxs,
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rxs,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: NymRadius.rxs,
            border: Border.all(color: c.glassBorder),
          ),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
                color: c.text,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.8),
          ),
        ),
      ),
    );
  }
}
