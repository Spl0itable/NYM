// NIP-19 reference cards: a pasted nevent/note/naddr/npub/nprofile (or a bare
// 64-hex event id) unfurls into a display card under the message, the way a
// pasted URL unfurls into a link preview.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/channel.dart';
import '../../models/nostr_event.dart';
import '../../services/relay/relay_message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/chat/message_row.dart' show formatRelativeTime;
import 'format/message_content.dart';
import '../../widgets/common/nym_avatar.dart';
import '../i18n/i18n.dart';

/// What a resolved reference renders as.
class NostrRefCardData {
  const NostrRefCardData({
    required this.kind,
    this.id = '',
    this.pubkey = '',
    this.author = '',
    this.body = '',
    this.channel = '',
    this.createdAt = 0,
    this.eventKind = 0,
    this.local = false,
  });

  final NostrRefKind kind;
  final String id;
  final String pubkey;
  final String author;

  /// The event's text, or a profile's about.
  final String body;

  /// `#geohash` / `#name` for a channel message; empty otherwise.
  final String channel;
  final int createdAt;
  final int eventKind;

  /// True when this client already held the referenced message, so the card
  /// can offer to jump to it.
  final bool local;
}

/// Resolves NIP-19 references to card content: the local message store first,
/// then one bounded relay query. Results and misses are both remembered for the
/// session, and concurrent callers for the same reference share one lookup.
class NostrRefResolver {
  NostrRefResolver(this._ref);

  final Ref _ref;

  static const Duration _queryTimeout = Duration(seconds: 4);

  /// Bounded like the translation cache: a busy channel would otherwise hold
  /// one entry per reference for the life of the process.
  static const int _max = 200;

  final Map<String, Future<NostrRefCardData?>> _entries = {};

  /// The settled result, so a rebuilt row paints immediately instead of
  /// showing a frame of nothing for a lookup that is long done.
  final Map<String, NostrRefCardData?> _settled = {};

  bool hasSettled(String key) => _settled.containsKey(key);

  NostrRefCardData? settled(String key) => _settled[key];

  Future<NostrRefCardData?> resolve(NostrRef ref) {
    final key = ref.key;
    final local = _local(ref);
    if (local != null) return Future.value(local);
    if (_settled.containsKey(key)) return Future.value(_settled[key]);
    final existing = _entries[key];
    if (existing != null) return existing;

    final future = _fetch(ref).then((data) {
      _settled[key] = data;
      return data;
    }).catchError((Object _) {
      _settled[key] = null;
      return null;
    }).whenComplete(() => _entries.remove(key));
    _entries[key] = future;
    while (_settled.length > _max) {
      _settled.remove(_settled.keys.first);
    }
    return future;
  }

  /// A card built from what this client already holds — no network.
  NostrRefCardData? _local(NostrRef ref) {
    final state = _ref.read(appStateProvider);
    if (ref.kind == NostrRefKind.profile) {
      final user = state.users[ref.pubkey];
      final profile = user?.profile;
      final nym = user?.nym ?? '';
      final about = profile?.about ?? '';
      if (nym.isEmpty && about.isEmpty) return null;
      return NostrRefCardData(
        kind: NostrRefKind.profile,
        pubkey: ref.pubkey,
        author: nym,
        body: about,
        local: true,
      );
    }
    if (ref.kind != NostrRefKind.event) return null;
    for (final list in state.messages.values) {
      for (final m in list) {
        if (m.id != ref.id && m.nymMessageId != ref.id) continue;
        return NostrRefCardData(
          kind: NostrRefKind.event,
          id: m.id,
          pubkey: m.pubkey,
          author: m.author,
          body: m.content,
          channel: m.geohash != null && m.geohash!.isNotEmpty
              ? '#${m.geohash}'
              : (m.channel != null && m.channel!.isNotEmpty
                  ? '#${m.channel}'
                  : ''),
          createdAt: m.createdAt,
          eventKind: m.eventKind,
          local: true,
        );
      }
    }
    return null;
  }

  Future<NostrRefCardData?> _fetch(NostrRef ref) async {
    final NostrFilter filter;
    switch (ref.kind) {
      case NostrRefKind.event:
        filter = NostrFilter(ids: [ref.id], limit: 1);
      case NostrRefKind.addr:
        final kind = ref.eventKind;
        if (kind == null || ref.pubkey.isEmpty) return null;
        filter = NostrFilter(
          kinds: [kind],
          authors: [ref.pubkey],
          limit: 1,
          tags: {
            'd': [ref.identifier]
          },
        );
      case NostrRefKind.profile:
        filter = NostrFilter(kinds: [0], authors: [ref.pubkey], limit: 1);
    }

    final event = await _queryOne(filter);
    if (event == null) return null;

    if (ref.kind == NostrRefKind.profile) {
      // A kind 0 lands in the store through the usual ingest path; read the
      // profile back from there rather than re-parsing its JSON here.
      final user = _ref.read(appStateProvider).users[ref.pubkey];
      final nym = user?.nym ?? '';
      final about = user?.profile?.about ?? '';
      if (nym.isEmpty && about.isEmpty) return null;
      return NostrRefCardData(
        kind: NostrRefKind.profile,
        pubkey: ref.pubkey,
        author: nym,
        body: about,
      );
    }

    final nymTag = event.tagValue('n');
    final stored = _ref.read(appStateProvider).users[event.pubkey];
    final author = (nymTag != null && nymTag.isNotEmpty)
        ? stripPubkeySuffix(nymTag)
        : (stored?.nym ?? getNymFromPubkey('nym', event.pubkey));
    final channelTag = event.tagValue('g') ?? event.tagValue('d');
    return NostrRefCardData(
      kind: NostrRefKind.event,
      id: event.id,
      pubkey: event.pubkey,
      author: author,
      body: event.content,
      channel: isValidChannelTag(channelTag) ? '#$channelTag' : '',
      createdAt: event.createdAt,
      eventKind: event.kind,
    );
  }

  /// One-shot kind 0 for the author of a referenced event.
  ///
  /// The whole point of a shared nevent is that it came from somewhere else, so
  /// its author is very often somebody this client has never seen and D1 has
  /// never heard of — D1 only ever holds a profile its own owner mirrored
  /// there. Nothing on the event path asked for their kind 0 (only the profile
  /// branch did), so the card named them by the bare `nym#xxxx` fallback
  /// forever. The event lands in the store through the usual ingest path, so
  /// this returns nothing: the card watches `usersProvider` and repaints
  /// itself. Attempted once per pubkey per session.
  Future<void> ensureAuthor(String pubkey) async {
    if (pubkey.isEmpty || !_authorAttempted.add(pubkey)) return;
    if (_ref.read(appStateProvider).users[pubkey] != null) return;
    await _queryOne(NostrFilter(kinds: [0], authors: [pubkey], limit: 1));
  }

  final Set<String> _authorAttempted = {};

  /// One bounded query across the pool for a single event. Returns the newest
  /// match, or null when nothing answers in time.
  Future<NostrEvent?> _queryOne(NostrFilter filter) async {
    final service = _ref.read(nostrControllerProvider).relayService;
    if (service == null) return null;
    final sub = service.pool.subscribe([filter]);
    NostrEvent? best;
    final listener = sub.events.listen((e) {
      if (best == null || e.createdAt > best!.createdAt) best = e;
    });
    try {
      await sub.eose.timeout(_queryTimeout, onTimeout: () => null);
      // The relay sends EOSE after the stored event, but delivery of the event
      // itself is a separate microtask; give it one turn to arrive.
      await Future<void>.delayed(Duration.zero);
    } catch (_) {
      // A relay that never answers is a normal outcome here.
    } finally {
      await listener.cancel();
      sub.close();
    }
    return best;
  }
}

final nostrRefResolverProvider =
    Provider<NostrRefResolver>((ref) => NostrRefResolver(ref));

/// Human label for the referenced event's kind.
String nostrRefKindLabel(int kind) => switch (kind) {
      0 => tr('Profile'),
      1 => tr('Note'),
      7 => tr('Reaction'),
      20000 || 23333 => tr('Channel message'),
      30023 => tr('Article'),
      1059 || 1060 => tr('Private message'),
      _ => tr('Event'),
    };

/// The card under a message for one NIP-19 reference in it. Renders nothing
/// while the lookup is out and nothing at all if it comes back empty, so an
/// unresolvable reference costs the row no height.
class NostrRefCard extends ConsumerStatefulWidget {
  const NostrRefCard({
    super.key,
    required this.token,
    this.onJump,
    this.onOpenProfile,
    this.blurImages = false,
  });

  /// The reference as pasted, scheme already stripped by the formatter.
  final String token;

  /// Invoked with the event id when the user taps a card for a message this
  /// client holds.
  final void Function(String eventId)? onJump;

  /// Invoked with the pubkey when the user taps a PROFILE card. A shared npub
  /// is a person, so the card offers what tapping that person anywhere else in
  /// the app offers: their context menu.
  final void Function(String pubkey, String nym)? onOpenProfile;

  /// Blur media in the referenced body behind a tap-to-reveal, under the same
  /// others'-images setting the surrounding message obeys.
  final bool blurImages;

  @override
  ConsumerState<NostrRefCard> createState() => _NostrRefCardState();
}

class _NostrRefCardState extends ConsumerState<NostrRefCard> {
  NostrRefCardData? _data;
  bool _resolved = false;
  Timer? _dwell;

  @override
  void initState() {
    super.initState();
    final ref0 = decodeNostrRef(widget.token);
    if (ref0 == null) {
      _resolved = true;
      return;
    }
    final resolver = ref.read(nostrRefResolverProvider);
    if (resolver.hasSettled(ref0.key)) {
      _data = resolver.settled(ref0.key);
      _resolved = true;
      return;
    }
    // DWELL before querying, like [LinkPreviewCard]: rows mount while flinging
    // through history, and a query each would burst subscriptions for messages
    // the user scrolls straight past.
    _dwell = Timer(const Duration(milliseconds: 300), () {
      _dwell = null;
      if (mounted) _load(ref0);
    });
  }

  @override
  void dispose() {
    _dwell?.cancel();
    super.dispose();
  }

  Future<void> _load(NostrRef ref0) async {
    final resolver = ref.read(nostrRefResolverProvider);
    final data = await resolver.resolve(ref0);
    if (!mounted) return;
    setState(() {
      _data = data;
      _resolved = true;
    });
    // The head reads the author's nym and avatar out of `usersProvider`, so a
    // kind 0 that lands later repaints the card with no further work here.
    if (data != null && data.pubkey.isNotEmpty) {
      unawaited(resolver.ensureAuthor(data.pubkey));
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (!_resolved || data == null) return const SizedBox.shrink();
    final c = context.nym;

    final users = ref.watch(usersProvider);
    // Prefer whatever the store knows now: `data.author` was resolved when the
    // card first painted, and `ensureAuthor` may have brought their kind 0 in
    // since. Both sides can already carry `#xxxx` — a stored nym, a
    // `getNymFromPubkey` fallback and a stored message's author all do — so
    // strip before re-adding or the suffix printed twice.
    final knownNym = users[data.pubkey]?.nym ?? '';
    final baseNym =
        stripPubkeySuffix(knownNym.isNotEmpty ? knownNym : data.author);
    final openProfileCb = widget.onOpenProfile;
    final nymText = Text(
      data.pubkey.isEmpty ? baseNym : '$baseNym#${getPubkeySuffix(data.pubkey)}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style:
          TextStyle(color: c.text, fontSize: 12, fontWeight: FontWeight.w600),
    );

    final headRow = Row(
      children: [
        if (data.pubkey.isNotEmpty) ...[
          NymAvatar(
            seed: data.pubkey,
            size: 20,
            imageUrl: users[data.pubkey]?.profile?.picture,
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The person named in the card opens their menu, like a tapped
              // nym anywhere else. Nested inside the head's own tap target, so
              // it wins the gesture arena and the rest of the head still jumps.
              if (baseNym.isNotEmpty)
                if (openProfileCb != null && data.pubkey.isNotEmpty)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => openProfileCb(data.pubkey, baseNym),
                    child: nymText,
                  )
                else
                  nymText,
              if (data.channel.isNotEmpty)
                Text(data.channel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textDim, fontSize: 10)),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          data.kind == NostrRefKind.profile
              ? tr('Profile')
              : nostrRefKindLabel(data.eventKind),
          style: TextStyle(color: c.textDim, fontSize: 10, letterSpacing: 0.3),
        ),
        if (data.createdAt > 0) ...[
          const SizedBox(width: 6),
          Text(
            formatRelativeTime(
                DateTime.fromMillisecondsSinceEpoch(data.createdAt * 1000)),
            style: TextStyle(color: c.textDim, fontSize: 10),
          ),
        ],
      ],
    );

    // The HEAD is the jump/profile affordance, not the whole card: the body
    // below is real message content now — links, media, the Read more toggle —
    // and a tap target wrapped around all of it would compete with every one
    // of them.
    final jump = widget.onJump;
    final VoidCallback? onTap;
    if (data.kind == NostrRefKind.profile) {
      onTap = (openProfileCb != null && data.pubkey.isNotEmpty)
          ? () => openProfileCb(data.pubkey, baseNym)
          : null;
    } else {
      onTap = (data.local && data.id.isNotEmpty && jump != null)
          ? () => jump(data.id)
          : null;
    }
    final head = onTap == null
        ? headRow
        : InkWell(onTap: onTap, child: headRow);

    final body = data.body.trim();
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        border: Border(left: BorderSide(color: c.primary, width: 2)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(NymRadius.xs),
          bottomRight: Radius.circular(NymRadius.xs),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          head,
          const SizedBox(height: 4),
          if (body.isEmpty)
            Text(tr('No text content'),
                style: TextStyle(
                    color: c.textDim,
                    fontSize: 12,
                    fontStyle: FontStyle.italic))
          else
            // The referenced event's body renders as a message body: media,
            // code, mentions, emoji, link previews, and the same height-based
            // "Read more" clamp. A hard-truncated excerpt could not show any of
            // it, and a referenced event is often exactly the media it carries.
            // Keyed on the event's own id so an expansion sticks, and with
            // reference cards off — a card inside a card, and again inside
            // that one, is not a thread of context.
            MessageContent(
              content: body,
              hostMessageId: data.id.isNotEmpty ? 'nostrcard-${data.id}' : null,
              fontSize: 12,
              blurImages: widget.blurImages,
              nostrRefCards: false,
            ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: card,
      ),
    );
  }
}
