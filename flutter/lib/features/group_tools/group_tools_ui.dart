import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../models/group.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/nym_icons.dart';
import '../calls/call_history_ui.dart' show showCallsScreen;
import '../calls/call_providers.dart';
import '../calls/call_signaling.dart' show CallPhase;
import '../channels/channel_share.dart' show kNymchatShareHost;
import '../globe/topojson.dart';
import '../groups/group_logic.dart' show kMaxGroupMembers;
import '../i18n/i18n.dart';
import '../messages/format/discord_timestamp.dart';
import '../messages/format/message_content.dart';
import '../search/unified_search_panel.dart' show nymSuffixStyle;
import '../toasts/toast_center.dart';
import 'group_tools.dart';
import 'group_tools_providers.dart';
import 'group_tools_service.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_field.dart';

class GroupToolIcons {
  const GroupToolIcons._();

  static const String _open =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">';
  static const String slowmode =
      '$_open<circle cx="8" cy="9" r="5.5"/><path d="M8 6v3l2 1.5"/><path d="M6 1.5h4"/></svg>';
  static const String requests =
      '$_open<circle cx="6" cy="5.5" r="2.5"/><path d="M2 14c0-3 2-4.5 4-4.5s4 1.5 4 4.5"/><path d="M12 4v4M10 6h4"/></svg>';
  static const String event =
      '$_open<rect x="2" y="3" width="12" height="11" rx="1.5"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/></svg>';
  static const String location =
      '$_open<path d="M8 14.5s4.5-4.2 4.5-8a4.5 4.5 0 0 0-9 0c0 3.8 4.5 8 4.5 8z"/><circle cx="8" cy="6.5" r="1.6"/></svg>';
  static const String checkboxOn =
      '$_open<rect x="2.5" y="2.5" width="11" height="11" rx="2.5"/><path d="M 5 8 L 7 10 L 11 5.5"/></svg>';
  static const String checkboxOff =
      '$_open<rect x="2.5" y="2.5" width="11" height="11" rx="2.5"/></svg>';
  static const String callLink =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/><path d="M16.6 7.4l2.8-2.8" stroke-width="1.75"/><path d="M17.3 3.5l.5-.5a2.05 2.05 0 0 1 2.9 2.9l-.5.5" stroke-width="1.75"/><path d="M18.7 8.5l-.5.5a2.05 2.05 0 0 1-2.9-2.9l.5-.5" stroke-width="1.75"/></svg>';
}

const List<String> kGroupToolsStrings = <String>[
  GroupToolsStrings.broadcastDenied,
  GroupToolsStrings.slowmodeWait,
  GroupToolsStrings.groupsNeedNet,
  GroupToolsStrings.callNeedsNet,
  GroupToolsStrings.noPublicLocation,
  GroupToolsStrings.locationNeedsNet,
  GroupToolsStrings.refusedRevoked,
  GroupToolsStrings.refusedExpired,
  GroupToolsStrings.refusedInvalid,
  GroupToolsStrings.refusedDeclined,
  GroupToolsStrings.refusedBusy,
  GroupToolsStrings.off,
  GroupToolsStrings.never,
  GroupToolsStrings.atStart,
  GroupToolsStrings.min10,
  GroupToolsStrings.hour1,
  GroupToolsStrings.day1,
  GroupToolsStrings.live15,
  GroupToolsStrings.live60,
  GroupToolsStrings.live480,
  GroupToolsStrings.exp1h,
  GroupToolsStrings.exp24h,
  GroupToolsStrings.exp7d,
  'Only the group owner or an admin can change this setting.',
  'Slowmode is on: members can send one message every {interval}.',
  'Slowmode is off.',
  'Admins now approve join requests from invite links.',
  'Invite links admit new members automatically again.',
  'Join request in {group}',
  '{nym} wants to join. Open the group menu to approve or decline.',
  'Only the group owner or an admin can approve join requests.',
  'Approved. {nym} was added to the group.',
  'Declined the join request from {nym}.',
  'Waiting for approval to join "{name}".',
  'Your request to join "{name}" was declined.',
  'Join request declined',
  'Join requests',
  'No pending join requests.',
  'Approve',
  'Decline',
  'Join group',
  '1 member',
  '{n} members',
  'Admins: {list}',
  'This link has no group details. Ask the sender for a fresh link to see them.',
  'An admin approves join requests for this group.',
  'Waiting for approval',
  'Join',
  'Cancel',
  'Join request sent for "{name}". Waiting for approval from an admin.',
  'Going',
  'Maybe',
  "Can't",
  'Remind me',
  'No reminder',
  "Organizer's time zone: {tz}",
  'That reminder time has already passed.',
  'Reminder set: {label}.',
  'Reminder: {title}',
  'Starts {when}',
  'Held by slowmode',
  'Show',
  'Location',
  'Live location',
  'Live until {time}',
  'Live location ended',
  'Accurate to about {d}',
  'Precision unknown',
  'Copy coordinates',
  'Coordinates copied.',
  'Stop sharing',
  'Share location',
  'Your location is end-to-end encrypted like a message. The card shows how precise it is.',
  'It will go over the Bluetooth mesh.',
  'Send current location',
  'Pick on map',
  'Share live location',
  'Stop sharing live location',
  'Send your current location? Accurate to about {d}.',
  'Send',
  "Couldn't get your location. Check the location permission or pick a spot on the map.",
  'Tap the map to zoom in on a spot. The pin goes in the middle.',
  'Zoom out',
  'Send this spot',
  'Share your live location for {d}? Accurate to about {acc}. You can stop at any time.',
  'Share',
  'Stopped sharing your live location.',
  'Your live location share ended.',
  'Still sharing your live location until {time}.',
  'Events can only be created in a group.',
  'New event',
  'Title',
  'Date',
  'Time',
  'Time zone',
  'this device',
  'Place (optional)',
  'Note (optional)',
  'Create event',
  'Add a title, date and time.',
  'Call links need a logged-in account.',
  'New call link',
  'Name',
  'Call',
  'Voice',
  'Video',
  'Expires',
  'Anyone with the link can ask to join. You admit each person, and you can revoke the link at any time.',
  'Create link',
  'Call link ready',
  'Copy link',
  'Send in this chat',
  'Call links',
  'Active until {time}',
  'Active, never expires',
  'Revoked',
  'Expired',
  'Copy',
  'Revoke',
  'No call links yet.',
  'Call link revoked. Anyone who tries it now is told it was revoked.',
  'Call link copied.',
  'Pick a nym or log in to join this call.',
  'Already in a call',
  'Join the video call "{name}" hosted by {host}? The host admits you. Your camera and microphone are used once you join.',
  'Join the voice call "{name}" hosted by {host}? The host admits you. Your microphone is used once you join.',
  'Join call',
  'Ask to join',
  'Asked {host} to let you in…',
  'The host did not answer. They may be offline.',
  'Call link: {name}',
  '{nym} wants to join',
  '{nym} wants to join your call link "{name}".',
  'Join request',
  'Admit',
  'Slowmode',
  'Members can send one message per interval. The owner, admins and moderators are not limited.',
  'Admins approve join requests',
  'Create call link',
  'Slowmode: one message every {interval}',
  "you're exempt",
  'send again in {time}',
  'Notify everyone in this group',
  'Notify all members',
  'Group',
  'Map',
  'Join voice call',
  'Join video call',
  'Calls',
];

bool gtHeld(Message m) => m.slowHeld && !m.heldShown;

bool gtHasCard(Message m) {
  if (gtHeld(m)) return true;
  if (m.isGroup && GroupTools.parseEvent(m.content) != null) return true;
  if ((m.isPM || m.isGroup) && GroupTools.parseLocation(m.content) != null) {
    return true;
  }
  return false;
}

class GtMessageCard extends ConsumerWidget {
  const GtMessageCard({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = message;
    if (gtHeld(m)) return GtHeldPlaceholder(message: m);
    if (m.isGroup && m.groupId != null) {
      final ev = GroupTools.parseEvent(m.content);
      if (ev != null) return GtEventCard(event: ev, groupId: m.groupId!);
    }
    final loc = GroupTools.parseLocation(m.content);
    if (loc != null) return GtLocationCard(location: loc, message: m);
    return const SizedBox.shrink();
  }
}

class GtHeldPlaceholder extends ConsumerWidget {
  const GtHeldPlaceholder({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          tr('Held by slowmode'),
          style: TextStyle(color: c.textDim, fontStyle: FontStyle.italic),
        ),
        TextButton(
          key: const ValueKey('gtShowHeld'),
          onPressed: () {
            message.heldShown = true;
            ref.read(appStateProvider.notifier).touch();
            ref.read(groupToolsRevisionProvider.notifier).state++;
          },
          child: Text(tr('Show'), style: TextStyle(color: c.primary)),
        ),
      ],
    );
  }
}

class _GtCardShell extends StatelessWidget {
  const _GtCardShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: NymRadius.rmd,
        border: Border.all(color: c.glassBorder),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: c.text, fontSize: 13),
        child: child,
      ),
    );
  }
}

class GtEventCard extends ConsumerWidget {
  const GtEventCard({super.key, required this.event, required this.groupId});

  final GroupEventInfo event;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(groupToolsRevisionProvider);
    final c = context.nym;
    final svc = ref.read(groupToolsProvider);
    final group = ref.read(appStateProvider.notifier).groupById(groupId);
    final entries = svc.rsvpEntries(event.id);
    final tally = GroupTools.rsvpTally(entries, group?.members);
    final self = ref.read(appStateProvider).selfPubkey;
    final mine = entries[self]?.s;
    final labels = {
      'going': tr('Going'),
      'maybe': tr('Maybe'),
      'no': tr("Can't"),
    };
    final lists = {'going': tally.going, 'maybe': tally.maybe, 'no': tally.no};
    final nym = ref.read(nostrControllerProvider);
    final rem = svc.reminderOffset(event.id);
    Widget rsvpButton(String s) {
      final active = mine == s;
      return OutlinedButton(
        key: ValueKey('gtRsvp-$s'),
        onPressed: () => svc.rsvp(groupId, event.id, s),
        style: OutlinedButton.styleFrom(
          foregroundColor: active ? c.primary : c.text,
          side: BorderSide(color: active ? c.primary : c.glassBorder),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: const Size(0, 30),
          textStyle: const TextStyle(fontSize: 13),
        ),
        child: Text('${labels[s]} ${lists[s]!.length}'),
      );
    }

    return _GtCardShell(
      child: Column(
        key: ValueKey('gtEvent-${event.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              NymSvgIcon(GroupToolIcons.event, size: 16, color: c.textBright),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  event.title,
                  style: TextStyle(
                    color: c.textBright,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          MessageContent(
            content: '<t:${event.start}:F> · <t:${event.start}:R>',
            fontSize: 13,
            nostrRefCards: false,
          ),
          const SizedBox(height: 4),
          Text(
            tr("Organizer's time zone: {tz}", {
              'tz': GroupTools.tzLabel(event.offset),
            }),
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
          if (event.place.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                NymSvgIcon(GroupToolIcons.location, size: 14, color: c.textDim),
                const SizedBox(width: 6),
                Flexible(child: Text(event.place)),
              ],
            ),
          ],
          if (event.note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(event.note),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              rsvpButton('going'),
              rsvpButton('maybe'),
              rsvpButton('no'),
            ],
          ),
          for (final s in const ['going', 'maybe', 'no'])
            if (lists[s]!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${labels[s]}: ${lists[s]!.map(nym.gtNym).join(', ')}',
                  key: ValueKey('gtWho-$s'),
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
              ),
          const SizedBox(height: 6),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            children: [
              Text(
                tr('Remind me'),
                style: TextStyle(color: c.textDim, fontSize: 12),
              ),
              DropdownButton<int>(
                key: ValueKey('gtReminder-${event.id}'),
                value: rem ?? -1,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: TextStyle(color: c.text, fontSize: 12),
                dropdownColor: c.bgSecondary,
                items: [
                  DropdownMenuItem(value: -1, child: Text(tr('No reminder'))),
                  for (final o in GroupTools.reminderOffsetsMin)
                    DropdownMenuItem(
                      value: o,
                      child: Text(tr(GroupTools.reminderLabel(o))),
                    ),
                ],
                onChanged: (v) => svc.setReminder(
                  groupId,
                  event.id,
                  v == null || v < 0 ? null : v,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<List<GeoFeature>>? _worldFuture;

Future<List<GeoFeature>> gtWorldFeatures() {
  return _worldFuture ??= () async {
    try {
      final raw = await rootBundle.loadString(kWorldTopoAsset);
      return await compute(decodeWorldTopoJson, raw);
    } catch (_) {
      return const <GeoFeature>[];
    }
  }();
}

class GtMapPainter extends CustomPainter {
  GtMapPainter({
    required this.minLon,
    required this.maxLon,
    required this.minLat,
    required this.maxLat,
    required this.features,
    required this.sea,
    required this.land,
    required this.edge,
    required this.pinColor,
    this.pin,
    this.accDeg = 0,
  });

  final double minLon;
  final double maxLon;
  final double minLat;
  final double maxLat;
  final List<GeoFeature> features;
  final Color sea;
  final Color land;
  final Color edge;
  final Color pinColor;
  final ({double lat, double lon})? pin;
  final double accDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = sea);
    double px(double lon) => (lon - minLon) / (maxLon - minLon) * w;
    double py(double lat) => (maxLat - lat) / (maxLat - minLat) * h;
    final fill = Paint()..color = land;
    final stroke = Paint()
      ..color = edge
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (final f in features) {
      final b = f.bounds;
      if (b[2] < minLon - 360 || b[0] > maxLon + 360) continue;
      for (final poly in f.polygons) {
        final path = Path()..fillType = PathFillType.evenOdd;
        for (final ring in poly) {
          for (var i = 0; i < ring.length; i++) {
            var lon = ring[i][0];
            if (maxLon > 180 && lon < minLon) lon += 360;
            if (minLon < -180 && lon > maxLon) lon -= 360;
            final x = px(lon);
            final y = py(ring[i][1]);
            if (i == 0) {
              path.moveTo(x, y);
            } else {
              path.lineTo(x, y);
            }
          }
          path.close();
        }
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      }
    }
    final p = pin;
    if (p != null) {
      final o = Offset(px(p.lon), py(p.lat));
      if (accDeg > 0) {
        final r = math.max(4.0, accDeg / (maxLon - minLon) * w);
        canvas.drawCircle(
          o,
          math.min(r, w),
          Paint()..color = pinColor.withValues(alpha: 0.18),
        );
      }
      canvas.drawCircle(o, 5, Paint()..color = pinColor);
      canvas.drawCircle(
        o,
        5,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(GtMapPainter old) =>
      old.minLon != minLon ||
      old.maxLon != maxLon ||
      old.minLat != minLat ||
      old.maxLat != maxLat ||
      old.features != features ||
      old.sea != sea ||
      old.land != land ||
      old.edge != edge ||
      old.pinColor != pinColor ||
      old.pin != pin ||
      old.accDeg != accDeg;
}

class GtMapView extends StatelessWidget {
  const GtMapView({
    super.key,
    required this.minLon,
    required this.maxLon,
    required this.minLat,
    required this.maxLat,
    this.pin,
    this.accDeg = 0,
  });

  final double minLon;
  final double maxLon;
  final double minLat;
  final double maxLat;
  final ({double lat, double lon})? pin;
  final double accDeg;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return AspectRatio(
      aspectRatio: 2,
      child: ClipRRect(
        borderRadius: NymRadius.rxs,
        child: FutureBuilder<List<GeoFeature>>(
          future: gtWorldFeatures(),
          builder: (context, snap) => CustomPaint(
            painter: GtMapPainter(
              minLon: minLon,
              maxLon: maxLon,
              minLat: minLat,
              maxLat: maxLat,
              features: snap.data ?? const [],
              sea: c.bgTertiary,
              land: c.bgSecondary,
              edge: c.border,
              pinColor: c.primary,
              pin: pin,
              accDeg: accDeg,
            ),
          ),
        ),
      ),
    );
  }
}

class GtLocationCard extends ConsumerStatefulWidget {
  const GtLocationCard({
    super.key,
    required this.location,
    required this.message,
  });

  final SharedLocation location;
  final Message message;

  @override
  ConsumerState<GtLocationCard> createState() => _GtLocationCardState();
}

class _GtLocationCardState extends ConsumerState<GtLocationCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.location.kind == 'live') {
      _tick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(groupToolsRevisionProvider);
    final c = context.nym;
    final loc =
        GroupTools.parseLocation(widget.message.content) ?? widget.location;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final state = GroupTools.liveState(loc, now);
    final frame = GroupTools.mapFrame(loc.lat, loc.lon, loc.acc);
    final coords = '${_num(loc.lat)}, ${_num(loc.lon)}';
    var title = tr('Location');
    String? sub;
    if (state == 'live') {
      title = tr('Live location');
      sub = tr('Live until {time}', {
        'time': formatDiscordTimestamp(loc.until, 't'),
      });
    } else if (state == 'ended' || state == 'expired') {
      title = tr('Live location');
      sub = tr('Live location ended');
    }
    final svc = ref.read(groupToolsProvider);
    final own =
        widget.message.isOwn && state == 'live' && svc.liveShare?.id == loc.id;
    return _GtCardShell(
      child: Column(
        key: ValueKey('gtLoc-${loc.id.isEmpty ? 'pin' : loc.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 320,
            child: GtMapView(
              minLon: frame.minLon,
              maxLon: frame.maxLon,
              minLat: frame.minLat,
              maxLat: frame.maxLat,
              pin: (lat: loc.lat, lon: loc.lon),
              accDeg: loc.acc / 111320,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              NymSvgIcon(
                GroupToolIcons.location,
                size: 16,
                color: c.textBright,
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  color: c.textBright,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              if (sub != null)
                Expanded(
                  child: Text(
                    sub,
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textDim, fontSize: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            coords,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            loc.acc > 0
                ? tr('Accurate to about {d}', {
                    'd': GroupTools.precisionText(loc.acc),
                  })
                : tr('Precision unknown'),
            key: const ValueKey('gtLocPrecision'),
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              GtButton(
                label: tr('Copy coordinates'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: coords));
                  showToast(tr('Coordinates copied.'));
                },
              ),
              if (own)
                GtButton(
                  key: const ValueKey('gtStopLive'),
                  label: tr('Stop sharing'),
                  danger: true,
                  onTap: () => svc.stopLive(),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _num(double v) {
    final s = v.toString();
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }
}

class GtButton extends StatelessWidget {
  const GtButton({
    super.key,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final fg = danger ? c.danger : (primary ? c.primary : c.text);
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        side: BorderSide(color: primary ? c.primary : c.glassBorder),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        textStyle: const TextStyle(fontSize: 13),
      ),
      child: Text(label),
    );
  }
}

class GtDescriptionLine extends ConsumerWidget {
  const GtDescriptionLine({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appStateProvider);
    Group? g;
    for (final cand in app.groups) {
      if (cand.id == groupId) g = cand;
    }
    final line = GroupTools.descriptionLine(g?.description);
    if (g == null || line.isEmpty) return const SizedBox.shrink();
    final c = context.nym;
    final group = g;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const ValueKey('gtDescLine'),
        behavior: HitTestBehavior.opaque,
        onTap: () => showAppAlert(
          context,
          group.description ?? '',
          title: group.name.isEmpty ? tr('Group') : group.name,
        ),
        child: Text(
          line,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: TextStyle(color: c.textDim, fontSize: 11, height: 1.3),
        ),
      ),
    );
  }
}

class GtSlowmodeBar extends ConsumerStatefulWidget {
  const GtSlowmodeBar({super.key});

  @override
  ConsumerState<GtSlowmodeBar> createState() => _GtSlowmodeBarState();
}

class _GtSlowmodeBarState extends ConsumerState<GtSlowmodeBar> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appStateProvider);
    ref.watch(groupToolsRevisionProvider);
    final view = app.view;
    if (view.kind != ViewKind.group) return const SizedBox.shrink();
    final svc = ref.read(groupToolsProvider);
    final g = ref.read(appStateProvider.notifier).groupById(view.id);
    final interval = g == null ? 0 : GroupTools.normalizeSlowmode(g.slowmode);
    if (interval == 0) return const SizedBox.shrink();
    final exempt = GroupTools.slowmodeExempt(svc.role(view.id, app.selfPubkey));
    final wait = exempt ? 0 : svc.slowmodeWait(view.id);
    final label = tr('Slowmode: one message every {interval}', {
      'interval': gtSlowmodeLabel(interval),
    });
    final text = exempt
        ? '$label · ${tr("you're exempt")}'
        : (wait > 0
              ? '$label · ${tr('send again in {time}', {'time': GroupTools.formatWait(wait)})}'
              : label);
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
      child: Text(
        text,
        key: const ValueKey('gtSlowBar'),
        style: TextStyle(fontSize: 12, color: wait > 0 ? c.warning : c.textDim),
      ),
    );
  }
}

Future<T?> _gtPanel<T>(BuildContext context, String title, Widget child) {
  final isLight = context.nym.isLight;
  return showNymSheet<T>(
    context,
    (_) => GtPanelShell(title: title, child: child),
    barrierColor: isLight ? const Color(0x73000000) : const Color(0xBF000000),
  );
}

class GtPanelShell extends StatelessWidget {
  const GtPanelShell({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final size = MediaQuery.of(context).size;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: c.primary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            IconButton(
              tooltip: tr('Close'),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.close, size: 18, color: c.textDim),
            ),
          ],
        ),
        Divider(color: c.glassBorder, height: 16),
        Flexible(child: SingleChildScrollView(child: child)),
      ],
    );
    return nymSheetOr(
      context,
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: body),
      (body) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: size.width * 0.92,
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: size.height * 0.88,
            ),
            decoration: BoxDecoration(
              color: c.bgSecondary,
              borderRadius: NymRadius.rxl,
              border: Border.all(color: c.glassBorder),
            ),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: body,
          ),
        ),
      ),
    );
  }
}

Text _hint(BuildContext context, String text) =>
    Text(text, style: TextStyle(color: context.nym.textDim, fontSize: 12));

GroupToolsService _svc(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false).read(groupToolsProvider);

void _notice(BuildContext context, String text) => showToast(text);

bool _gate(
  BuildContext context,
  String feature,
  String surface, {
  String? peer,
}) {
  return _svc(context).gate(feature, surface, peer: peer).ok;
}

Future<bool> showGtInvitePreview(
  BuildContext context,
  InvitePayload payload,
) async {
  final svc = _svc(context);
  final fields = svc.verifySummary(payload);
  final p = GroupTools.invitePreview(payload, fields);
  final waiting = svc.pendingJoins()[payload.g]?.waiting == true;
  final res = await _gtPanel<bool>(
    context,
    tr('Join group'),
    _InvitePreviewBody(preview: p, waiting: waiting),
  );
  return res == true;
}

class _InvitePreviewBody extends StatefulWidget {
  const _InvitePreviewBody({required this.preview, required this.waiting});

  final InvitePreview preview;
  final bool waiting;

  @override
  State<_InvitePreviewBody> createState() => _InvitePreviewBodyState();
}

class _InvitePreviewBodyState extends State<_InvitePreviewBody> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final p = widget.preview;
    final full = (p.memberCount ?? 0) >= kMaxGroupMembers;
    return Column(
      key: const ValueKey('gtInvitePreview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: NymRadius.rxs,
          child: SizedBox(
            height: 96,
            width: double.infinity,
            child: p.banner.isNotEmpty
                ? Image.network(
                    p.banner,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(color: c.bgTertiary),
                  )
                : ColoredBox(color: c.bgTertiary),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                NymAvatar(
                  seed: p.name,
                  size: 56,
                  imageUrl: p.avatar.isNotEmpty ? p.avatar : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.name,
                    key: const ValueKey('gtInviteName'),
                    style: TextStyle(
                      color: c.textBright,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (p.description.isNotEmpty)
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text(
              p.description,
              key: const ValueKey('gtInviteDesc'),
              maxLines: _expanded ? null : 1,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
          ),
        if (p.memberCount != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _hint(
              context,
              tr('{n}/{max} members', {
                    'n': '${p.memberCount}',
                    'max': '$kMaxGroupMembers',
                  }) +
                  (full ? ' · ${tr('Full')}' : ''),
            ),
          ),
        if (p.admins.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _hint(
              context,
              tr('Admins: {list}', {'list': p.admins.join(', ')}),
            ),
          ),
        if (!p.verified)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _hint(
              context,
              tr(
                'This link has no group details. Ask the sender for a fresh link to see them.',
              ),
            ),
          )
        else if (p.approval)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _hint(
              context,
              tr('An admin approves join requests for this group.'),
            ),
          ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GtButton(
              label: tr('Cancel'),
              onTap: () => Navigator.of(context).pop(false),
            ),
            const SizedBox(width: 8),
            GtButton(
              key: const ValueKey('gtInviteJoin'),
              label: full
                  ? tr('Group is full')
                  : (widget.waiting ? tr('Waiting for approval') : tr('Join')),
              primary: true,
              onTap: widget.waiting || full
                  ? null
                  : () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ],
    );
  }
}

Future<void> showGtJoinRequests(BuildContext context, String groupId) {
  return _gtPanel<void>(
    context,
    tr('Join requests'),
    _JoinRequestsBody(groupId: groupId),
  );
}

class _JoinRequestsBody extends ConsumerWidget {
  const _JoinRequestsBody({required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(groupToolsRevisionProvider);
    ref.watch(appStateProvider);
    final c = context.nym;
    final svc = ref.read(groupToolsProvider);
    final g = ref.read(appStateProvider.notifier).groupById(groupId);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final list = g == null
        ? const <JoinRequest>[]
        : GroupTools.pruneJoinRequests(g.joinRequests, now);
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          tr('No pending join requests.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim, fontStyle: FontStyle.italic),
        ),
      );
    }
    final canDecide = GroupTools.mayApproveJoins(
      svc.role(groupId, ref.read(appStateProvider).selfPubkey),
    );
    final full = g != null && g.members.length >= kMaxGroupMembers;
    final nym = ref.read(nostrControllerProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in list)
          Padding(
            key: ValueKey('gtJoinRow-${r.pubkey}'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                NymAvatar(seed: r.pubkey, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(text: nym.gtNym(r.pubkey)),
                          TextSpan(
                            text: '#${r.pubkey.substring(r.pubkey.length - 4)}',
                            style: nymSuffixStyle(TextStyle(color: c.text)),
                          ),
                        ]),
                        style: TextStyle(color: c.text),
                      ),
                      Text(
                        formatDiscordTimestamp(r.ts, 'R'),
                        style: TextStyle(color: c.textDim, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (canDecide) ...[
                  if (full)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        tr('Full'),
                        key: ValueKey('gtApproveFull-${r.pubkey}'),
                        style: TextStyle(color: c.warning, fontSize: 12),
                      ),
                    ),
                  GtButton(
                    key: ValueKey('gtApprove-${r.pubkey}'),
                    label: tr('Approve'),
                    primary: true,
                    onTap: full
                        ? null
                        : () => svc.decideJoin(groupId, r.pubkey, true),
                  ),
                  const SizedBox(width: 6),
                  GtButton(
                    key: ValueKey('gtDecline-${r.pubkey}'),
                    label: tr('Decline'),
                    onTap: () => svc.decideJoin(groupId, r.pubkey, false),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

Future<bool> showGtSlowmodePicker(BuildContext context, String groupId) async {
  final done = await _gtPanel<bool>(
    context,
    tr('Slowmode'),
    Consumer(
      builder: (context, ref, _) {
        final g = ref.read(appStateProvider.notifier).groupById(groupId);
        final cur = GroupTools.normalizeSlowmode(g?.slowmode ?? 0);
        final c = context.nym;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _hint(
              context,
              tr(
                'Members can send one message per interval. The owner, admins and moderators are not limited.',
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in GroupTools.slowmodeSeconds)
                  OutlinedButton(
                    key: ValueKey('gtSlow-$s'),
                    onPressed: () {
                      Navigator.of(context).pop(true);
                      ref.read(groupToolsProvider).setSlowmode(groupId, s);
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: s == cur ? c.primary : c.text,
                      side: BorderSide(
                        color: s == cur ? c.primary : c.glassBorder,
                      ),
                    ),
                    child: Text(gtSlowmodeLabel(s)),
                  ),
              ],
            ),
          ],
        );
      },
    ),
  );
  return done == true;
}

Future<bool> showGtCreateEvent(BuildContext context, String groupId) async {
  final svc = _svc(context);
  if (svc.hooks.group(groupId) == null) {
    _notice(context, tr('Events can only be created in a group.'));
    return false;
  }
  if (!_gate(context, 'event', 'group')) return false;
  final blocked = svc.sendBlockedReason(groupId, '');
  if (blocked != null) {
    _notice(context, blocked);
    return false;
  }
  final done = await _gtPanel<bool>(
    context,
    tr('New event'),
    _CreateEventBody(groupId: groupId),
  );
  return done == true;
}

class _CreateEventBody extends ConsumerStatefulWidget {
  const _CreateEventBody({required this.groupId});

  final String groupId;

  @override
  ConsumerState<_CreateEventBody> createState() => _CreateEventBodyState();
}

const List<int> kGtTzOffsets = [
  -720,
  -660,
  -600,
  -540,
  -480,
  -420,
  -360,
  -300,
  -240,
  -210,
  -180,
  -120,
  -60,
  0,
  60,
  120,
  180,
  210,
  240,
  270,
  300,
  330,
  345,
  360,
  390,
  420,
  480,
  540,
  570,
  600,
  630,
  660,
  720,
  765,
  780,
  840,
];

class _CreateEventBodyState extends ConsumerState<_CreateEventBody> {
  final _title = TextEditingController();
  final _place = TextEditingController();
  final _note = TextEditingController();
  late DateTime _when;
  late int _offset;
  late int _deviceOffset;

  @override
  void initState() {
    super.initState();
    final d = DateTime.now().add(const Duration(hours: 1));
    _when = DateTime(d.year, d.month, d.day, d.hour);
    _deviceOffset = _when.timeZoneOffset.inMinutes;
    _offset = _deviceOffset;
  }

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      _notice(context, tr('Add a title, date and time.'));
      return;
    }
    final start = GroupTools.wallToUtc(
      _when.year,
      _when.month,
      _when.day,
      _when.hour,
      _when.minute,
      _offset,
    );
    final svc = ref.read(groupToolsProvider);
    final content = GroupTools.buildEventContent(
      id: svc.randomHex(8),
      title: _title.text,
      start: start,
      offset: _offset,
      place: _place.text,
      note: _note.text,
    );
    if (content == null) {
      _notice(context, tr('Add a title, date and time.'));
      return;
    }
    Navigator.of(context).pop(true);
    await ref
        .read(nostrControllerProvider)
        .gtSendGroupContent(widget.groupId, content);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final offs = kGtTzOffsets.contains(_deviceOffset)
        ? kGtTzOffsets
        : ([...kGtTzOffsets, _deviceOffset]..sort());
    String two(int n) => n.toString().padLeft(2, '0');
    final dateLabel = '${_when.year}-${two(_when.month)}-${two(_when.day)}';
    final timeLabel = '${two(_when.hour)}:${two(_when.minute)}';
    InputDecoration deco(String label) => NymField.decoration(c).copyWith(
      labelText: label,
      labelStyle: TextStyle(color: c.textDim, fontSize: 13),
    );
    return NymDiscardGuard(
      isDirty: () =>
          _title.text.trim().isNotEmpty ||
          _place.text.trim().isNotEmpty ||
          _note.text.trim().isNotEmpty,
      child: Column(
        key: const ValueKey('gtEventForm'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('gtEventTitle'),
            controller: _title,
            maxLength: GroupToolsLimits.titleMax,
            decoration: deco(tr('Title')),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('gtEventDate'),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _when,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) {
                      setState(
                        () => _when = DateTime(
                          d.year,
                          d.month,
                          d.day,
                          _when.hour,
                          _when.minute,
                        ),
                      );
                    }
                  },
                  child: Text('${tr('Date')}: $dateLabel'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('gtEventTime'),
                  onPressed: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                        hour: _when.hour,
                        minute: _when.minute,
                      ),
                    );
                    if (t != null) {
                      setState(
                        () => _when = DateTime(
                          _when.year,
                          _when.month,
                          _when.day,
                          t.hour,
                          t.minute,
                        ),
                      );
                    }
                  },
                  child: Text('${tr('Time')}: $timeLabel'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                tr('Time zone'),
                style: TextStyle(color: c.textDim, fontSize: 13),
              ),
              const SizedBox(width: 8),
              DropdownButton<int>(
                key: const ValueKey('gtEventTz'),
                value: _offset,
                dropdownColor: c.bgSecondary,
                items: [
                  for (final o in offs)
                    DropdownMenuItem(
                      value: o,
                      child: Text(
                        o == _deviceOffset
                            ? '${GroupTools.tzLabel(o)} · ${tr('this device')}'
                            : GroupTools.tzLabel(o),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _offset = v ?? _offset),
              ),
            ],
          ),
          TextField(
            key: const ValueKey('gtEventPlace'),
            controller: _place,
            maxLength: GroupToolsLimits.placeMax,
            decoration: deco(tr('Place (optional)')),
          ),
          TextField(
            key: const ValueKey('gtEventNote'),
            controller: _note,
            maxLength: GroupToolsLimits.noteMax,
            decoration: deco(tr('Note (optional)')),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GtButton(
                label: tr('Cancel'),
                onTap: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 8),
              GtButton(
                key: const ValueKey('gtEventCreate'),
                label: tr('Create event'),
                primary: true,
                onTap: _submit,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

const Object _kGtPickOnMap = 'pick';

Future<bool> showGtShareLocation(BuildContext context, GtChat chat) async {
  final a = _svc(context).gate(
    chat.isGroup ? 'location' : 'location',
    chat.isGroup ? 'group' : 'dm',
    peer: chat.isGroup ? null : chat.id,
  );
  if (!a.ok) return false;
  final done = await _gtPanel<Object>(
    context,
    tr('Share location'),
    _ShareLocationBody(chat: chat, mesh: a.mesh),
  );
  if (done == _kGtPickOnMap && context.mounted) {
    return showGtMapPicker(context, chat);
  }
  return done == true;
}

class _ShareLocationBody extends ConsumerWidget {
  const _ShareLocationBody({required this.chat, required this.mesh});

  final GtChat chat;
  final bool mesh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final svc = ref.read(groupToolsProvider);
    final hint =
        tr(
          'Your location is end-to-end encrypted like a message. The card shows how precise it is.',
        ) +
        (mesh ? ' ${tr('It will go over the Bluetooth mesh.')}' : '');
    return Column(
      key: const ValueKey('gtLocationMenu'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _hint(context, hint),
        const SizedBox(height: 10),
        GtButton(
          key: const ValueKey('gtSendCurrent'),
          label: tr('Send current location'),
          primary: true,
          onTap: () async {
            final nav = Navigator.of(context);
            final root = Navigator.of(context, rootNavigator: true).context;
            nav.pop(true);
            final pos = await currentGtPosition();
            if (!root.mounted) return;
            if (pos == null) {
              _notice(
                root,
                tr(
                  "Couldn't get your location. Check the location permission or pick a spot on the map.",
                ),
              );
              return;
            }
            final ok = await showAppConfirm(
              root,
              tr('Send your current location? Accurate to about {d}.', {
                'd': GroupTools.precisionText(pos.acc),
              }),
              title: tr('Share location'),
              okLabel: tr('Send'),
            );
            if (ok) await svc.sendPin(chat, pos);
          },
        ),
        const SizedBox(height: 8),
        GtButton(
          key: const ValueKey('gtPickOnMap'),
          label: tr('Pick on map'),
          onTap: () => Navigator.of(context).pop(_kGtPickOnMap),
        ),
        const SizedBox(height: 12),
        Text(
          tr('Share live location'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in GroupTools.liveDurationsSec)
              GtButton(
                key: ValueKey('gtLive-$s'),
                label: tr(GroupTools.liveDurationLabel(s)),
                onTap: () async {
                  final root = Navigator.of(
                    context,
                    rootNavigator: true,
                  ).context;
                  Navigator.of(context).pop(true);
                  final pos = await currentGtPosition();
                  if (!root.mounted) return;
                  if (pos == null) {
                    _notice(
                      root,
                      tr(
                        "Couldn't get your location. Check the location permission or pick a spot on the map.",
                      ),
                    );
                    return;
                  }
                  final ok = await showAppConfirm(
                    root,
                    tr(
                      'Share your live location for {d}? Accurate to about {acc}. You can stop at any time.',
                      {
                        'd': tr(GroupTools.liveDurationLabel(s)),
                        'acc': GroupTools.precisionText(pos.acc),
                      },
                    ),
                    title: tr('Share live location'),
                    okLabel: tr('Share'),
                  );
                  if (ok) await svc.startLive(chat, s, pos);
                },
              ),
          ],
        ),
        if (svc.liveShare != null) ...[
          const SizedBox(height: 10),
          GtButton(
            label: tr('Stop sharing live location'),
            danger: true,
            onTap: () {
              Navigator.of(context).pop(true);
              svc.stopLive();
            },
          ),
        ],
      ],
    );
  }
}

Future<bool> showGtMapPicker(BuildContext context, GtChat chat) async {
  final done = await _gtPanel<bool>(
    context,
    tr('Pick on map'),
    _MapPickerBody(chat: chat),
  );
  return done == true;
}

class _MapPickerBody extends ConsumerStatefulWidget {
  const _MapPickerBody({required this.chat});

  final GtChat chat;

  @override
  ConsumerState<_MapPickerBody> createState() => _MapPickerBodyState();
}

class _MapPickerBodyState extends ConsumerState<_MapPickerBody> {
  double _lat = 20;
  double _lon = 0;
  double _span = GroupTools.pickStartSpan;

  @override
  Widget build(BuildContext context) {
    final acc = GroupTools.pickAccuracy(_span);
    return Column(
      key: const ValueKey('gtMapPicker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _hint(
          context,
          tr('Tap the map to zoom in on a spot. The pin goes in the middle.'),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, box) {
            return GestureDetector(
              key: const ValueKey('gtPickCanvas'),
              onTapUp: (d) {
                final w = box.maxWidth;
                final h = w / 2;
                final n = GroupTools.pickTap(
                  _lat,
                  _lon,
                  _span,
                  d.localPosition.dx / w,
                  d.localPosition.dy / h,
                );
                setState(() {
                  _lat = n.lat;
                  _lon = n.lon;
                  _span = n.span;
                });
              },
              child: GtMapView(
                minLon: _lon - _span,
                maxLon: _lon + _span,
                minLat: _lat - _span / 2,
                maxLat: _lat + _span / 2,
                pin: (lat: _lat, lon: _lon),
                accDeg: acc / 111320,
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        _hint(
          context,
          '${_lat.toStringAsFixed(4)}, ${_lon.toStringAsFixed(4)} · ${tr('Accurate to about {d}', {'d': GroupTools.precisionText(acc)})}',
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GtButton(
              label: tr('Zoom out'),
              onTap: () =>
                  setState(() => _span = GroupTools.pickZoomOut(_span)),
            ),
            const SizedBox(width: 8),
            GtButton(
              key: const ValueKey('gtPickSend'),
              label: tr('Send this spot'),
              primary: true,
              onTap: () {
                Navigator.of(context).pop(true);
                ref
                    .read(groupToolsProvider)
                    .sendPin(
                      widget.chat,
                      GtPosition(_lat, _lon, acc.toDouble()),
                    );
              },
            ),
          ],
        ),
      ],
    );
  }
}

String gtCallLinkUrl(CallLink link) =>
    '$kNymchatShareHost/#call=${GroupTools.encodeCallLink(link)}';

Future<bool> showGtCreateCallLink(
  BuildContext context, {
  String? groupId,
  String? pubkey,
}) async {
  if (!_gate(context, 'callLink', 'none')) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  if (!(container.read(nostrControllerProvider).relayService?.canSign ??
      false)) {
    _notice(context, tr('Call links need a logged-in account.'));
    return false;
  }
  var name = '';
  if (groupId != null) {
    name =
        container.read(appStateProvider.notifier).groupById(groupId)?.name ??
        '';
  } else if (pubkey != null) {
    name = container.read(nostrControllerProvider).gtNym(pubkey);
  }
  var created = false;
  final done = await _gtPanel<bool>(
    context,
    tr('New call link'),
    _CreateCallLinkBody(
      groupId: groupId,
      pubkey: pubkey,
      name: name.isEmpty ? tr('Call') : name,
      onCreated: () => created = true,
    ),
  );
  return done == true || created;
}

class _CreateCallLinkBody extends ConsumerStatefulWidget {
  const _CreateCallLinkBody({
    this.groupId,
    this.pubkey,
    required this.name,
    this.onCreated,
  });

  final String? groupId;
  final String? pubkey;
  final String name;
  final VoidCallback? onCreated;

  @override
  ConsumerState<_CreateCallLinkBody> createState() =>
      _CreateCallLinkBodyState();
}

class _CreateCallLinkBodyState extends ConsumerState<_CreateCallLinkBody> {
  late final TextEditingController _name = TextEditingController(
    text: GroupTools.sanitizeName(widget.name),
  );
  String _kind = 'audio';
  int _exp = 86400;
  CallLink? _created;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final created = _created;
    if (created != null) {
      final url = gtCallLinkUrl(created);
      final c = context.nym;
      return Column(
        key: const ValueKey('gtCallLinkReady'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: c.glassBorder),
              borderRadius: NymRadius.rxs,
            ),
            child: SelectableText(
              url,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GtButton(
                label: tr('Copy link'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  showToast(tr('Call link copied.'));
                },
              ),
              if (widget.groupId != null || widget.pubkey != null) ...[
                const SizedBox(width: 8),
                GtButton(
                  key: const ValueKey('gtSendCallLink'),
                  label: tr('Send in this chat'),
                  primary: true,
                  onTap: () {
                    Navigator.of(context).pop(true);
                    final ctl = ref.read(nostrControllerProvider);
                    if (widget.groupId != null) {
                      ctl.gtSendGroupContent(widget.groupId!, url);
                    } else {
                      ctl.gtSendPmContent(widget.pubkey!, url);
                    }
                  },
                ),
              ],
            ],
          ),
        ],
      );
    }
    return NymDiscardGuard(
      isDirty: () =>
          _created == null &&
          _name.text != GroupTools.sanitizeName(widget.name),
      child: Column(
        key: const ValueKey('gtCallLinkForm'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            maxLength: GroupToolsLimits.linkNameMax,
            decoration: NymField.decoration(context.nym).copyWith(labelText: tr('Name')),
          ),
          Row(
            children: [
              ChoiceChip(
                key: const ValueKey('gtKindAudio'),
                label: Text(tr('Voice')),
                selected: _kind == 'audio',
                onSelected: (_) => setState(() => _kind = 'audio'),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                key: const ValueKey('gtKindVideo'),
                label: Text(tr('Video')),
                selected: _kind == 'video',
                onSelected: (_) => setState(() => _kind = 'video'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(tr('Expires')),
              const SizedBox(width: 8),
              DropdownButton<int>(
                key: const ValueKey('gtCallLinkExpiry'),
                value: _exp,
                items: [
                  for (final s in GroupTools.callLinkExpirySec)
                    DropdownMenuItem(
                      value: s,
                      child: Text(tr(GroupTools.expiryLabel(s))),
                    ),
                ],
                onChanged: (v) => setState(() => _exp = v ?? _exp),
              ),
            ],
          ),
          _hint(
            context,
            tr(
              'Anyone with the link can ask to join. You admit each person, and you can revoke the link at any time.',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GtButton(
                label: tr('Cancel'),
                onTap: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 8),
              GtButton(
                key: const ValueKey('gtCreateCallLink'),
                label: tr('Create link'),
                primary: true,
                onTap: () {
                  final link = ref
                      .read(groupToolsProvider)
                      .createCallLink(
                        kind: _kind,
                        expirySec: _exp,
                        name: _name.text,
                        groupId: widget.groupId,
                      );
                  widget.onCreated?.call();
                  setState(() => _created = link);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> showGtCallLinks(BuildContext context) {
  return showCallsScreen(context, links: true);
}

class CallLinksBody extends ConsumerWidget {
  const CallLinksBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(groupToolsRevisionProvider);
    final svc = ref.read(groupToolsProvider);
    final c = context.nym;
    final links = svc.callLinks();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final view = ref.read(appStateProvider).view;
    return Column(
      key: const ValueKey('gtCallLinks'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        GtButton(
          key: const ValueKey('gtNewCallLink'),
          label: tr('New call link'),
          primary: true,
          onTap: () {
            final root = Navigator.of(context, rootNavigator: true).context;
            Navigator.of(context).pop();
            showGtCreateCallLink(
              root,
              groupId: view.kind == ViewKind.group ? view.id : null,
              pubkey: view.kind == ViewKind.pm ? view.id : null,
            );
          },
        ),
        const SizedBox(height: 8),
        if (links.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              tr('No call links yet.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textDim, fontStyle: FontStyle.italic),
            ),
          ),
        for (final l in links)
          Builder(
            builder: (context) {
              final st = GroupTools.callLinkState(l, now);
              final stLabel = st == 'active'
                  ? (l.exp > 0
                        ? tr('Active until {time}', {
                            'time': formatDiscordTimestamp(l.exp, 'f'),
                          })
                        : tr('Active, never expires'))
                  : (st == 'revoked' ? tr('Revoked') : tr('Expired'));
              return Padding(
                key: ValueKey('gtLinkRow-${l.id}'),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${l.name} · ${l.kind == 'video' ? tr('Video') : tr('Voice')}',
                            style: TextStyle(
                              color: st == 'active' ? c.text : c.textDim,
                              decoration: st == 'active'
                                  ? null
                                  : TextDecoration.lineThrough,
                            ),
                          ),
                          Text(
                            stLabel,
                            style: TextStyle(color: c.textDim, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    if (st == 'active') ...[
                      GtButton(
                        label: tr('Copy'),
                        onTap: () async {
                          await Clipboard.setData(
                            ClipboardData(text: gtCallLinkUrl(l)),
                          );
                          showToast(tr('Call link copied.'));
                        },
                      ),
                      const SizedBox(width: 6),
                      GtButton(
                        key: ValueKey('gtRevoke-${l.id}'),
                        label: tr('Revoke'),
                        danger: true,
                        onTap: () => svc.revokeCallLink(l.id),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

Future<void> joinCallLinkFlow(BuildContext context, String input) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final svc = container.read(groupToolsProvider);
  final link = GroupTools.parseCallLinkInput(input);
  if (link == null) {
    _notice(context, tr(GroupToolsStrings.refusedInvalid));
    return;
  }
  if (!svc.gate('callLink', 'none').ok) return;
  final self = container.read(appStateProvider).selfPubkey;
  if (link.host == self) {
    await showGtCallLinks(context);
    return;
  }
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (GroupTools.callLinkState(link, now) == 'expired') {
    _notice(context, tr(GroupToolsStrings.refusedExpired));
    return;
  }
  if (!(container.read(nostrControllerProvider).relayService?.canSign ??
      false)) {
    _notice(context, tr('Pick a nym or log in to join this call.'));
    return;
  }
  final calls = container.read(callServiceProvider);
  if (calls.state.value.phase != CallPhase.idle) {
    _notice(context, tr('Already in a call'));
    return;
  }
  final host =
      '${container.read(nostrControllerProvider).gtNym(link.host)}#${link.host.substring(60)}';
  final msg = link.kind == 'video'
      ? tr(
          'Join the video call "{name}" hosted by {host}? The host admits you. Your camera and microphone are used once you join.',
          {'name': link.name, 'host': host},
        )
      : tr(
          'Join the voice call "{name}" hosted by {host}? The host admits you. Your microphone is used once you join.',
          {'name': link.name, 'host': host},
        );
  final ok = await showAppConfirm(
    context,
    msg,
    title: tr('Join call'),
    okLabel: tr('Ask to join'),
  );
  if (!ok) return;
  if (!await calls.probeMedia(link.kind)) return;
  await svc.requestLinkJoin(link);
  showToast(tr('Asked {host} to let you in…', {'host': host}));
  Timer(const Duration(minutes: 2), () {
    final j = svc.pendingLinkJoin;
    if (j != null && j.id == link.id) {
      svc.consumeLinkJoin();
      showToast(tr('The host did not answer. They may be offline.'));
    }
  });
}

class GtMenuItem {
  const GtMenuItem({
    required this.key,
    required this.svg,
    required this.label,
    required this.onTap,
    this.trailing,
    this.disabled = false,
    this.openSheet,
  });

  final String key;
  final String svg;
  final String label;
  final String? trailing;
  final bool disabled;
  final void Function(BuildContext rootContext) onTap;
  final Future<bool> Function(BuildContext rootContext)? openSheet;
}

List<GtMenuItem> gtGroupMenuItems(WidgetRef ref, Group g) {
  final svc = ref.read(groupToolsProvider);
  final self = ref.read(appStateProvider).selfPubkey;
  final role = svc.role(g.id, self);
  final admin = role == 'owner' || role == 'admin';
  final offline = ref.read(appStateProvider).connectedRelays <= 0;
  final out = <GtMenuItem>[];
  void blocked(BuildContext ctx, String reason) => _notice(ctx, tr(reason));
  if (admin) {
    out.add(
      GtMenuItem(
        key: 'gtMenuSlowmode',
        svg: GroupToolIcons.slowmode,
        label: tr('Slowmode'),
        trailing: gtSlowmodeLabel(g.slowmode),
        disabled: offline,
        onTap: (ctx) => offline
            ? blocked(ctx, GroupToolsStrings.groupsNeedNet)
            : showGtSlowmodePicker(ctx, g.id),
        openSheet: offline ? null : (ctx) => showGtSlowmodePicker(ctx, g.id),
      ),
    );
    out.add(
      GtMenuItem(
        key: 'gtMenuApproval',
        svg: g.joinApproval
            ? GroupToolIcons.checkboxOn
            : GroupToolIcons.checkboxOff,
        label: tr('Admins approve join requests'),
        disabled: offline,
        onTap: (ctx) => offline
            ? blocked(ctx, GroupToolsStrings.groupsNeedNet)
            : svc.setJoinApproval(g.id, !g.joinApproval),
      ),
    );
    final n = GroupTools.pruneJoinRequests(
      g.joinRequests,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ).length;
    if (g.joinApproval || n > 0) {
      out.add(
        GtMenuItem(
          key: 'gtMenuJoinRequests',
          svg: GroupToolIcons.requests,
          label: tr('Join requests'),
          trailing: n > 0 ? '$n' : null,
          onTap: (ctx) => showGtJoinRequests(ctx, g.id),
          openSheet: (ctx) async {
            await showGtJoinRequests(ctx, g.id);
            return false;
          },
        ),
      );
    }
  }
  out.add(
    GtMenuItem(
      key: 'gtMenuEvent',
      svg: GroupToolIcons.event,
      label: tr('Create event'),
      disabled: offline,
      onTap: (ctx) => showGtCreateEvent(ctx, g.id),
      openSheet: offline ? null : (ctx) => showGtCreateEvent(ctx, g.id),
    ),
  );
  out.add(
    GtMenuItem(
      key: 'gtMenuLocation',
      svg: GroupToolIcons.location,
      label: tr('Share location'),
      disabled: offline,
      onTap: (ctx) => showGtShareLocation(ctx, GtChat.group(g.id)),
      openSheet: offline
          ? null
          : (ctx) => showGtShareLocation(ctx, GtChat.group(g.id)),
    ),
  );
  out.add(
    GtMenuItem(
      key: 'gtMenuCallLink',
      svg: GroupToolIcons.callLink,
      label: tr('Create call link'),
      disabled: offline,
      onTap: (ctx) => showGtCreateCallLink(ctx, groupId: g.id),
      openSheet: offline
          ? null
          : (ctx) => showGtCreateCallLink(ctx, groupId: g.id),
    ),
  );
  return out;
}

List<GtMenuItem> gtPmMenuItems(String peer) => [
  GtMenuItem(
    key: 'gtMenuLocation',
    svg: GroupToolIcons.location,
    label: tr('Share location'),
    onTap: (ctx) => showGtShareLocation(ctx, GtChat.dm(peer)),
  ),
  GtMenuItem(
    key: 'gtMenuCallLink',
    svg: GroupToolIcons.callLink,
    label: tr('Create call link'),
    onTap: (ctx) => showGtCreateCallLink(ctx, pubkey: peer),
  ),
];

List<String> gtBroadcastSuggestions(WidgetRef ref, String query) {
  final app = ref.read(appStateProvider);
  if (app.view.kind != ViewKind.group) return const [];
  final role = ref.read(groupToolsProvider).role(app.view.id, app.selfPubkey);
  return GroupTools.broadcastSuggestions('group', role, query);
}

List<GtMenuItem> gtSidebarItems(String storageKey) {
  if (storageKey.startsWith('group-')) {
    final gid = storageKey.substring(6);
    return [
      GtMenuItem(
        key: 'gtMenuEvent',
        svg: GroupToolIcons.event,
        label: tr('Create event'),
        onTap: (ctx) => showGtCreateEvent(ctx, gid),
      ),
      GtMenuItem(
        key: 'gtMenuLocation',
        svg: GroupToolIcons.location,
        label: tr('Share location'),
        onTap: (ctx) => showGtShareLocation(ctx, GtChat.group(gid)),
      ),
      GtMenuItem(
        key: 'gtMenuCallLink',
        svg: GroupToolIcons.callLink,
        label: tr('Create call link'),
        onTap: (ctx) => showGtCreateCallLink(ctx, groupId: gid),
      ),
    ];
  }
  if (storageKey.startsWith('pm-')) {
    final peer = storageKey.substring(3);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(peer)) return const [];
    return gtPmMenuItems(peer);
  }
  return const [];
}
