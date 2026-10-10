// NIP-19 reference cards: a pasted nevent/note/naddr/npub/nprofile or bare event id unfurls into a card.

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
import '../../widgets/common/nym_label.dart';
import '../i18n/i18n.dart';

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

  /// `#geohash` or `#name` for a channel message; empty otherwise.
  final String channel;
  final int createdAt;
  final int eventKind;

  /// True when this client holds the referenced message, so the card can jump to it.
  final bool local;
}

/// Resolves references from the local store, then one bounded relay query; results and misses are cached per session.
class NostrRefResolver {
  NostrRefResolver(this._ref);

  final Ref _ref;

  static const Duration _queryTimeout = Duration(seconds: 4);

  /// Bounded so a busy channel doesn't grow this forever.
  static const int _max = 200;

  final Map<String, Future<NostrRefCardData?>> _entries = {};

  /// Settled results, so a rebuilt row paints immediately.
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

  /// A card from what this client already holds, without network.
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
      // Read the profile from the store rather than re-parsing kind-0 JSON.
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
    final author = !isPlaceholderNym(nymTag)
        ? stripPubkeySuffix(nymTag!)
        : pickDisplayNym(stored?.nym, getNymFromPubkey('nym', event.pubkey));
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

  /// Fetches the referenced author's kind 0 once per session; the card repaints via `usersProvider`.
  Future<void> ensureAuthor(String pubkey) async {
    if (pubkey.isEmpty || !_authorAttempted.add(pubkey)) return;
    if (_ref.read(appStateProvider).users[pubkey] != null) return;
    await _queryOne(NostrFilter(kinds: [0], authors: [pubkey], limit: 1));
  }

  final Set<String> _authorAttempted = {};

  /// Newest match for one bounded pool query, or null on timeout.
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
      // The event arrives in a separate microtask from EOSE; give it one turn.
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

String nostrRefKindLabel(int kind) => switch (kind) {
      0 => tr('Profile'),
      1 => tr('Note'),
      7 => tr('Reaction'),
      20000 || 23333 => tr('Channel message'),
      30023 => tr('Article'),
      1059 || 1060 => tr('Private message'),
      _ => tr('Event'),
    };

/// Card for one NIP-19 reference; renders nothing while loading or if empty, costing no height.
class NostrRefCard extends ConsumerStatefulWidget {
  const NostrRefCard({
    super.key,
    required this.token,
    this.onJump,
    this.onOpenProfile,
    this.blurImages = false,
  });

  /// The pasted reference, scheme already stripped.
  final String token;

  /// Called with the event id when tapping a card for a held message.
  final void Function(String eventId)? onJump;

  /// Called when tapping a profile card, to open that person's context menu.
  final void Function(String pubkey, String nym)? onOpenProfile;

  /// Blur media in the referenced body under the same setting as the surrounding message.
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
    // Dwell before querying so rows flung past don't burst subscriptions.
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
    // The head reads nym and avatar from `usersProvider`, so a late kind 0 repaints it.
    if (data != null && data.pubkey.isNotEmpty) {
      unawaited(resolver.ensureAuthor(data.pubkey));
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (!_resolved || data == null) return const SizedBox.shrink();
    final hidden = ref.watch(appStateProvider.select((s) => s.isRefHidden(
          pubkey: data.pubkey,
          author: data.author,
          body: data.body,
          channel: data.channel,
          profile: data.kind == NostrRefKind.profile,
        )));
    if (hidden) return const SizedBox.shrink();
    final c = context.nym;

    final users = ref.watch(usersProvider);
    // Prefer the store's current nym; strip any `#xxxx` before re-adding so the suffix isn't doubled.
    final baseNym = pickDisplayNym(users[data.pubkey]?.nym, data.author);
    final openProfileCb = widget.onOpenProfile;
    final nymText = data.pubkey.isEmpty
        ? Text(
            baseNym,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: c.text, fontSize: 12, fontWeight: FontWeight.w600),
          )
        : NymLabel(
            baseNym,
            pubkey: data.pubkey,
            style: TextStyle(
                color: c.text, fontSize: 12, fontWeight: FontWeight.w600),
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
              // Nested in the head's tap target, so it wins the gesture arena.
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

    // Only the head is the tap target, so it doesn't compete with links and media in the body.
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
            // Rendered as a full message body keyed on the event id, with reference cards off to avoid nesting.
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
