// Bridges the Bluetooth mesh into the app's normal chat stores.
//
// Rather than a parallel UI, mesh is just another transport: received mesh
// messages are ingested into [AppState] exactly like Nostr ones (channels via
// [ingestMeshChannelMessage], DMs via [ingestPMMessage]), so they render through
// the canonical ChatPane — same header, composer, message rows, reactions,
// unread badges, and notifications. Outgoing sends from the composer are routed
// back over the mesh when the active conversation is mesh-backed.
//
// Identity mapping: a mesh peer is keyed by a 64-hex pubkey so it slots into the
// PM store. A cryptographically npub-linked peer uses its REAL Nostr pubkey (so
// its Bluetooth DM shares the one thread with its internet DM); an unlinked peer
// uses its 32-byte Noise static key as a stable pseudo-pubkey.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/pms/pm_logic.dart' show ReceiptInfo;
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../models/nostr_event.dart';
import '../../services/mesh/mesh_events.dart';
import '../../services/platform/deep_links.dart' show sanitizeChannelName;
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/mesh_service.dart';
import '../../services/mesh/noise/noise_crypto.dart';
import '../../services/mesh/protocol/mesh_profile.dart';
import '../../core/constants/storage_keys.dart';
import '../../state/settings_provider.dart';
import 'ghost_mode.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'mesh_controller.dart';
import 'mesh_diagnostics.dart';
import 'mesh_outbox.dart';
import '../../services/mesh/protocol/nostr_carrier_packet.dart';

/// The bare storage key of the mesh "Nearby" public channel (renders as
/// `#mesh` — an ordinary channel in the sidebar's Channels list).
const String kMeshNearbyChannel = 'mesh';

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

String _short(String s) => s.length <= 8 ? s : s.substring(0, 8);

/// The stable 64-hex conversation pubkey for a mesh peer, derived purely from
/// its 16-hex peerID — `SHA-256("mesh:" + peerID)`.
///
/// This is the ONLY value available AND unchanging across a peer's whole
/// session: the peerID is present in every packet's senderID, known from first
/// contact (before any handshake, announce, or Noise key). Keying off it — via
/// the resolve-once cache in [MeshBridge._pubkeyForPeerId] — guarantees that
/// opening a DM and receiving its reply land in the IDENTICAL `pm-<pubkey>`
/// thread. (Keying off the Noise key split the thread: opening the DM before
/// the handshake resolved a placeholder while the reply, after the session
/// formed, resolved the real key — the "received but only in the notification"
/// bug.) Hashing gives full 64-hex entropy, so the PM header shows a real
/// `#abcd` suffix and a varied avatar colour instead of the `#0000` a
/// zero-padded peerID produced.
String meshStablePubkeyForPeerId(String peerID) => _hex(NoiseCrypto.sha256(
    Uint8List.fromList(utf8.encode('mesh:${peerID.toLowerCase()}'))));

class MeshBridge {
  MeshBridge({
    required Ref ref,
    required MeshService service,
    required String Function() selfNym,
  })  : _ref = ref,
        _service = service,
        _selfNym = selfNym;

  final Ref _ref;
  final MeshService _service;
  final String Function() _selfNym;

  final List<StreamSubscription<dynamic>> _subs = [];

  /// peerID (16-hex) → 64-hex pubkey used as the PM store key.
  final Map<String, String> _pubkeyByPeerId = {};

  /// pubkey → peerID, for routing an outgoing DM back to the right radio peer.
  final Map<String, String> _peerIdByPubkey = {};

  /// Nym for a peer's pubkey, for building inbound message authors.
  final Map<String, String> _nymByPubkey = {};

  /// Bare channel keys (lowercase) that are mesh-backed — drives the sidebar
  /// Bluetooth glyph and send routing.
  final Set<String> _meshChannelKeys = {kMeshNearbyChannel};

  /// Pubkeys whose PM conversation is mesh-backed.
  final Set<String> _meshPmPubkeys = {};

  /// Pubkeys that are mesh-ONLY — an unlinked peer whose pubkey is a Noise-key
  /// pseudo-pubkey that Nostr can't address, so their DM must always go over the
  /// mesh regardless of internet connectivity. (A verified-linked peer uses its
  /// real Nostr pubkey and is dual-transport: internet when online, mesh when
  /// offline.)
  final Set<String> _meshOnlyPmPubkeys = {};

  AppStateNotifier get _app => _ref.read(appStateProvider.notifier);
  AppState get _appState => _ref.read(appStateProvider);

  // ---- Markers consulted by the sidebar + send router ----------------------

  bool isMeshChannelKey(String key) =>
      _meshChannelKeys.contains(key.toLowerCase());
  bool isMeshPmPubkey(String pubkey) =>
      _meshPmPubkeys.contains(pubkey.toLowerCase());

  Set<String> get meshChannelKeys => _meshChannelKeys;
  Set<String> get meshPmPubkeys => _meshPmPubkeys;

  bool get _online => _appState.connectedRelays > 0;

  /// Whether the mesh CAN carry a send for [view] right now: any channel can be
  /// broadcast; a DM only if the peer is currently in radio range.
  bool _canSendToView(ChatView view) {
    if (view.kind == ViewKind.channel) return true;
    if (view.kind == ViewKind.pm) return peerIdForPubkey(view.id) != null;
    return false;
  }

  /// The transport decision for an outgoing send: use the mesh when there's no
  /// internet (send over Bluetooth instead of Nostr), OR when the DM peer is
  /// mesh-only (a pseudo-pubkey Nostr can't reach). Online sends to real Nostr
  /// identities always go over the internet — so `#mesh` and every other channel
  /// reach the Nostr network when connected, and fall back to Bluetooth when not.
  bool shouldSendOverMesh(ChatView view) {
    if (view.kind == ViewKind.pm) {
      final id = view.id.toLowerCase();
      // Checked BEFORE reachability, unlike everything below. A pinned peer is
      // one we met while ghosted, and they know us only as that ghost. If they
      // are out of radio range the send has to fail, not fall through to Nostr
      // — that path signs with the real key and would tell them the ghost was
      // us. Failing closed costs a message; failing open costs the session.
      if (_ghostPinnedPms.contains(id)) return true;
      if (_canSendToView(view) && _meshOnlyPmPubkeys.contains(id)) return true;
    }
    if (!_canSendToView(view)) return false;
    return !_online;
  }

  /// Peers whose conversation must never traverse Nostr (see
  /// [shouldSendOverMesh]). Persisted: the pin has to outlive the ghost epoch
  /// that created it, and the app restart after it.
  final Set<String> _ghostPinnedPms = {};

  bool isGhostPinned(String pubkey) =>
      _ghostPinnedPms.contains(pubkey.toLowerCase());

  /// True when [view] is pinned to the mesh but the peer is not in radio range,
  /// so a send will sit unsent rather than go out over Nostr. Drives the
  /// composer notice — without it the message just silently stalls.
  bool isAwaitingMeshRange(ChatView view) {
    if (view.kind != ViewKind.pm) return false;
    if (!_ghostPinnedPms.contains(view.id.toLowerCase())) return false;
    return peerIdForPubkey(view.id) == null;
  }

  /// Restores the public history this device carries, and keeps it written.
  ///
  /// This is what makes a phone a town crier rather than a live relay: walk
  /// between two mesh partitions, or relaunch hours later, and the backlog is
  /// still there to hand to whoever missed it. Contents are signed public
  /// broadcasts, already visible to anyone who was in radio range, so they are
  /// stored as-is — nothing private ever reaches this store.
  void _restoreGossipArchive() {
    final kv = _ref.read(keyValueStoreProvider);
    try {
      _service.gossip
          .decodeArchive(kv.getString(StorageKeys.meshGossipArchive));
    } catch (_) {}
    _service.onGossipArchiveChanged = (archive) {
      try {
        kv.setString(StorageKeys.meshGossipArchive, archive);
      } catch (_) {}
    };
  }

  /// Restores this device's one-time prekeys and keeps them written.
  ///
  /// The private halves MUST survive a restart: a sender who picked up our
  /// published bundle before we closed will have sealed mail to one of those
  /// keys, and a courier may hand it over hours later. Losing them turns
  /// forward secrecy into lost mail.
  void _restorePrekeys() {
    final kv = _ref.read(keyValueStoreProvider);
    try {
      _service.prekeys.decode(kv.getString(StorageKeys.meshPrekeys));
    } catch (_) {}
    _service.onPrekeysChanged = (encoded) {
      try {
        kv.setString(StorageKeys.meshPrekeys, encoded);
      } catch (_) {}
    };
  }

  /// A gateway asked us to publish an event, or rebroadcast one it heard.
  ///
  /// Both directions verify before acting: a carried event is signed by its
  /// ORIGINATOR, so a gateway that altered it — or invented it — produces
  /// something the relays would reject and we refuse to show. A gateway is a
  /// postbox, not an author.
  void _onNostrCarrier(NostrCarrierPacket carrier, String fromPeerID) {
    final event = carrier.event();
    if (event == null) return;
    unawaited(_ref
        .read(nostrControllerProvider)
        .handleMeshCarriedEvent(
          event: event,
          geohash: carrier.geohash,
          publish: carrier.direction == NostrCarrierDirection.toGateway ||
              carrier.direction == NostrCarrierDirection.toBridge,
        ));
  }

  void _loadGhostPins() {
    _ghostPinnedPms.addAll(
      _ref
          .read(keyValueStoreProvider)
          .getStringSet(StorageKeys.ghostPinnedPms)
          .map((e) => e.toLowerCase()),
    );
  }

  /// Pins [pubkey] to the mesh when the exchange happened under a ghost
  /// identity. Called on both directions of a mesh DM.
  void _pinIfGhosted(String pubkey) {
    if (!_ref.read(ghostModeProvider).enabled) return;
    if (!_ghostPinnedPms.add(pubkey.toLowerCase())) return;
    // Stored as a JSON array, the same shape getStringSet reads back. Pubkeys
    // are hex, so no escaping is needed.
    _ref.read(keyValueStoreProvider).setString(
          StorageKeys.ghostPinnedPms,
          '[${_ghostPinnedPms.map((e) => '"$e"').join(',')}]',
        );
  }

  // ---- Lifecycle -----------------------------------------------------------

  ProviderSubscription<ChatView>? _viewSub;

  void start() {
    _loadGhostPins();
    _restoreGossipArchive();
    // The courier gates need to know about ghosting, and only the bridge holds
    // that state. Wiring them here keeps the refusal rules ([CourierStore.
    // mayDeposit]) in one place rather than duplicated inside the radio layer.
    _service.isGhostMode = () => _ref.read(ghostModeProvider).enabled;
    _service.isGhostPinned = (staticKeyHex) {
      final pubkey = _pubkeyForNoiseKey(staticKeyHex);
      return pubkey != null && _ghostPinnedPms.contains(pubkey.toLowerCase());
    };
    _restorePrekeys();
    _service.onNostrCarrier = _onNostrCarrier;
    MeshService.debugLog = MeshDiagnostics.instance.log;
    _subs.add(_service.peersStream.listen(_onPeers));
    _subs.add(_service.onPublicMessage.listen(_onPublic));
    _subs.add(_service.onPrivateMessage.listen(_onPrivate));
    _subs.add(_service.onReceipt.listen(_onReceipt));
    _subs.add(_service.onFile.listen(_onFile));
    _subs.add(_service.onTyping.listen(_onTyping));
    _subs.add(_service.onReaction.listen(_onReaction));
    // Register the always-present Nearby channel so it appears immediately.
    _app.addChannel(kMeshNearbyChannel);
    // Send read receipts over the mesh whenever a mesh DM becomes the active
    // conversation (the canonical read-on-open behaviour, restored for mesh).
    _viewSub = _ref.listen<ChatView>(
      appStateProvider.select((s) => s.view),
      (_, view) {
        if (view.kind == ViewKind.pm && isMeshPmPubkey(view.id)) {
          markMeshPmRead(view.id);
        }
      },
      fireImmediately: true,
    );
  }

  Future<void> dispose() async {
    _viewSub?.close();
    _viewSub = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  /// Read receipts we've already sent, keyed by the message id, so we ack each
  /// inbound mesh DM exactly once.
  final Set<String> _readAcked = {};

  /// Sends a read receipt over the mesh for every not-yet-acked inbound message
  /// in [pubkey]'s thread. Idempotent — safe to call on every open/new message.
  void markMeshPmRead(String pubkey) {
    final peerId = peerIdForPubkey(pubkey);
    if (peerId == null) return;
    final list = _appState.messages['pm-${pubkey.toLowerCase()}'];
    if (list == null) return;
    for (final m in list) {
      if (m.isOwn) continue;
      final id = m.nymMessageId ?? m.id;
      if (id.isEmpty || !_readAcked.add(id)) continue;
      unawaited(_service.sendReadReceipt(peerId, id));
    }
  }

  /// Registers a joined mesh group [channel] (e.g. `#crew`) as an app channel.
  void registerChannel(String channel) {
    final name = channel.startsWith('#') ? channel.substring(1) : channel;
    if (name.isEmpty) return;
    _meshChannelKeys.add(name.toLowerCase());
    _app.addChannel(name);
  }

  // ---- Identity mapping ----------------------------------------------------

  /// The 64-hex pubkey used to key [peer]'s PM conversation. Delegates to
  /// [_pubkeyForPeerId] so the proactively-opened DM and an inbound message key
  /// the IDENTICAL thread (same resolve-once cache).
  String pubkeyForPeer(MeshPeer peer) => _pubkeyForPeerId(peer.peerID);

  /// Resolves a peerID to its conversation pubkey — resolve-ONCE and cache.
  ///
  /// The first resolution for a peerID picks the key and the cache pins it for
  /// the rest of the session, so opening a DM and later receiving its reply can
  /// NEVER disagree (the thread-split that made a received message land in a
  /// thread the open view didn't read — "received but only in the
  /// notification"). A verified Nostr link wins at first resolution (the peer
  /// is dual-transport under its real identity); otherwise the stable,
  /// always-available peerID-derived pubkey ([meshStablePubkeyForPeerId]) —
  /// NOT the Noise key, which binds late (after the handshake) and so isn't
  /// known when a DM is opened first.
  /// The conversation pubkey for a peer identified by its 32-byte Noise static
  /// key (hex) — how a courier deposit names its recipient. Null when we have
  /// never met that peer, in which case there is no pinned conversation to
  /// protect and the deposit gate falls through to its other checks.
  String? _pubkeyForNoiseKey(String staticKeyHex) {
    if (staticKeyHex.length != 64) return null;
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      final b =
          int.tryParse(staticKeyHex.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      bytes[i] = b;
    }
    // peerID is the first 16 hex chars of SHA-256 over the static key.
    final peerID = _hex(NoiseCrypto.sha256(bytes)).substring(0, 16);
    return _pubkeyByPeerId[peerID];
  }

  String _pubkeyForPeerId(String peerID) {
    final peer = _service.peerById(peerID);
    final cached = _pubkeyByPeerId[peerID];
    if (cached != null) {
      // Keep the display nym fresh, but NEVER re-key an existing conversation.
      if (peer != null) _nymByPubkey[cached] = peer.displayName;
      return cached;
    }
    final pubkey = (peer != null &&
            peer.nostrLinkVerified &&
            peer.nostrPubkey != null &&
            peer.nostrPubkey!.length == 64)
        ? peer.nostrPubkey!.toLowerCase()
        : meshStablePubkeyForPeerId(peerID);
    _pubkeyByPeerId[peerID] = pubkey;
    _peerIdByPubkey[pubkey] = peerID;
    if (peer != null) _nymByPubkey[pubkey] = peer.displayName;
    return pubkey;
  }

  /// Resolves the radio peerID for an outgoing DM to [pubkey].
  String? peerIdForPubkey(String pubkey) =>
      _peerIdByPubkey[pubkey.toLowerCase()];

  /// Proactively opens a mesh DM with [peer] (from the peers list): registers
  /// the routing, marks the conversation mesh-backed, and ensures the PM row
  /// exists. Returns the pubkey to `switchView(ChatView.pm(pubkey))` to.
  String openPeerDm(MeshPeer peer) {
    final pubkey = pubkeyForPeer(peer);
    _pubkeyByPeerId[peer.peerID] = pubkey;
    _peerIdByPubkey[pubkey] = peer.peerID;
    _nymByPubkey[pubkey] = peer.displayName;
    _classifyPeer(peer, pubkey);
    if (_meshPmPubkeys.add(pubkey)) _refreshMarkers();
    if (peer.nickname != null && peer.nickname!.isNotEmpty) {
      _app.upsertUserNym(pubkey, peer.nickname!);
    }
    _app.ensurePMConversation(pubkey, nym: peer.displayName);
    return pubkey;
  }

  // ---- Inbound -------------------------------------------------------------

  void _onPeers(List<MeshPeer> peers) {
    for (final p in peers) {
      final pubkey = pubkeyForPeer(p);
      _pubkeyByPeerId[p.peerID] = pubkey;
      _peerIdByPubkey[pubkey] = p.peerID;
      _nymByPubkey[pubkey] = p.displayName;
      _classifyPeer(p, pubkey);
      // Seed the user's nym so the PM header/rows show the peer's nickname
      // (not a bare "PM") even before any message is exchanged.
      if (p.nickname != null && p.nickname!.isNotEmpty) {
        _app.upsertUserNym(pubkey, p.nickname!);
      }
    }
  }

  /// A peer with a verified Nostr link is dual-transport — its DM is addressed
  /// by a real Nostr pubkey, so it goes over the internet when online and falls
  /// back to Bluetooth when not. An unlinked peer is keyed by its Noise key,
  /// which Nostr can't address, so its DM is mesh-only.
  void _classifyPeer(MeshPeer p, String pubkey) {
    final linked = p.nostrLinkVerified &&
        p.nostrPubkey != null &&
        p.nostrPubkey!.length == 64;
    if (linked) {
      _meshOnlyPmPubkeys.remove(pubkey);
    } else {
      _meshOnlyPmPubkeys.add(pubkey);
    }
  }

  void _onPublic(MeshPublicMessage msg) {
    // A radio frame names its own channel, and that name went straight into the
    // message with none of the checks the Nostr ingest makes. There is no event
    // kind here to pair a shape against — a mesh frame carries no kind — but the
    // name itself still has to be one the app could have created, so a peer
    // cannot file a message under a channel that could never exist.
    final raw = (msg.channel == null || msg.channel!.isEmpty)
        ? kMeshNearbyChannel
        : (msg.channel!.startsWith('#')
            ? msg.channel!.substring(1)
            : msg.channel!);
    // A name that isn't one falls back to Nearby rather than being dropped:
    // the words were still said over the radio, and an unnamed frame already
    // lands there.
    final sanitized = sanitizeChannelName(raw);
    final key = sanitized.isEmpty ? kMeshNearbyChannel : sanitized;
    final channelName = key;
    if (_meshChannelKeys.add(key)) _refreshMarkers();
    final storageKey = '#$key';
    final isOwn = msg.senderPeerID == _service.myPeerID;
    final pubkey =
        isOwn ? _appState.selfPubkey : _pubkeyForPeerId(msg.senderPeerID);
    final m = Message(
      id: msg.messageId,
      author: isOwn ? _selfNym() : msg.senderNickname,
      pubkey: pubkey,
      content: msg.content,
      createdAt: msg.timestampMs ~/ 1000,
      ms: msg.timestampMs,
      isOwn: isOwn,
      channel: channelName,
      // The kind this channel's messages travel under once they reach Nostr,
      // so a reaction to a mesh message carries the same `k` the relay copy
      // would (a named channel is 23333, not 20000).
      eventKind: channelWire(key).kind,
      deliveryStatus: DeliveryStatus.sent,
      viaMesh: true,
    );
    final before = _appState.messages[storageKey]?.length ?? 0;
    final landed = _app.ingestMeshChannelMessage(m, channelKey: storageKey);
    final after = _appState.messages[storageKey]?.length ?? 0;
    final vis = visibleMessagesFor(_appState, storageKey).length;
    MeshDiagnostics.instance.log(
        '#chan rx peer=${msg.senderPeerID} key=$storageKey store=$before→$after '
        'vis=$vis view=${_appState.view.storageKey} own=$isOwn '
        '${landed ? 'LANDED' : 'DROPPED'}');
    if (landed && !isOwn) _maybeNotifyChannelMention(m, channelName);
  }

  void _onPrivate(MeshPrivateMessage msg) {
    final pubkey = _pubkeyForPeerId(msg.senderPeerID);
    // Classify transport off the live peer: a verified Nostr link makes the DM
    // dual-transport, otherwise it is mesh-only (keyed by a Noise-key /
    // pseudo-pubkey Nostr can't address). A DM can arrive before the sender's
    // announce is processed — then the peer record is absent and it is
    // mesh-only until a linked announce upgrades it.
    final peer = _service.peerById(msg.senderPeerID);
    if (peer != null) {
      _classifyPeer(peer, pubkey);
    } else {
      _meshOnlyPmPubkeys.add(pubkey);
    }
    _pinIfGhosted(pubkey);
    if (_meshPmPubkeys.add(pubkey)) _refreshMarkers();
    final nym = _nymByPubkey[pubkey] ?? 'nym';
    if (nym.isNotEmpty && nym != 'nym') _app.upsertUserNym(pubkey, nym);
    _app.ensurePMConversation(pubkey, nym: nym);
    final m = _pmMessage(
      id: msg.messageId,
      pubkey: pubkey,
      author: nym,
      content: msg.content,
      timestampMs: msg.timestampMs,
      isOwn: false,
    );
    final storeKey = 'pm-$pubkey';
    final before = _appState.messages[storeKey]?.length ?? 0;
    _app.ingestPMMessage(m);
    final after = _appState.messages[storeKey]?.length ?? 0;
    final vis = visibleMessagesFor(_appState, storeKey).length;
    MeshDiagnostics.instance
        .log('PM rx peer=${msg.senderPeerID} id=${_short(msg.messageId)} '
            'key=$storeKey store=$before→$after vis=$vis '
            'view=${_appState.view.storageKey} '
            '${after > before ? 'LANDED' : 'DROPPED'}');
    _notifyPm(pubkey: pubkey, nym: nym, body: msg.content, ts: msg.timestampMs);
    // If this thread is already on-screen, ack it immediately.
    final view = _appState.view;
    if (view.kind == ViewKind.pm && view.id.toLowerCase() == pubkey) {
      markMeshPmRead(pubkey);
    }
  }

  void _onReceipt(MeshReceipt receipt) {
    _app.applyReceipt(ReceiptInfo(
      messageId: receipt.messageId,
      receiptType: receipt.isRead ? 'read' : 'delivered',
    ));
  }

  void _onTyping(MeshTypingEvent e) {
    final pubkey = _pubkeyForPeerId(e.senderPeerID);
    final String storageKey;
    if (e.isDirect) {
      storageKey = 'pm-$pubkey';
    } else {
      final ch = (e.channel == null || e.channel!.isEmpty)
          ? kMeshNearbyChannel
          : (e.channel!.startsWith('#') ? e.channel!.substring(1) : e.channel!);
      storageKey = '#${ch.toLowerCase()}';
    }
    _app.setTyping(
      storageKey: storageKey,
      pubkey: pubkey,
      typing: e.isStart,
      nym: e.nickname,
    );
  }

  void _onReaction(MeshReactionEvent e) {
    if (e.emoji.isEmpty || e.targetId.isEmpty) return;
    // Only apply a reaction to a message we actually hold — never conjure one on
    // a phantom/empty id (guards the intermittent "a sent message auto-gains a
    // reaction" report). The target is canonicalized to the stored Message.id (a
    // DM reaction references the shared id, indexed as the message's
    // nymMessageId).
    final existing = _app.messageById(e.targetId);
    if (existing == null) return;
    final pubkey = _pubkeyForPeerId(e.senderPeerID);
    // Never let an inbound frame apply a reaction as if it were us.
    if (pubkey == _appState.selfPubkey) return;
    _app.applyReaction(
      messageId: existing.id,
      emoji: e.emoji,
      reactor: pubkey,
      removed: e.isRemove,
      reactorNym: e.reactorNick,
    );
  }

  /// Sends an emoji reaction to [targetId] over the mesh for the active [view].
  void sendReaction(ChatView view, String targetId, String emoji,
      {required bool remove}) {
    if (view.kind == ViewKind.channel) {
      unawaited(_service.sendChannelReaction(targetId, emoji, remove));
    } else if (view.kind == ViewKind.pm) {
      final peerId = peerIdForPubkey(view.id);
      if (peerId != null) {
        unawaited(
            _service.sendPrivateReaction(peerId, targetId, emoji, remove));
      }
    }
  }

  /// Sends a typing indicator for the active mesh [view] (throttled by the
  /// composer, and auto-expiring after ~5s on the receiver).
  void sendTyping(ChatView view, bool start) {
    if (view.kind == ViewKind.channel) {
      final ch = view.id.toLowerCase();
      unawaited(_service.sendTyping(
        channel: ch == kMeshNearbyChannel ? null : '#$ch',
        start: start,
      ));
    } else if (view.kind == ViewKind.pm) {
      final peerId = peerIdForPubkey(view.id);
      if (peerId != null) {
        unawaited(_service.sendTyping(toPeerID: peerId, start: start));
      }
    }
  }

  Future<void> _onFile(MeshFileReceived event) async {
    final path = await _saveFile(event.fileName, event.bytes);
    if (path == null) return;
    if (event.isDirect) {
      final pubkey = _pubkeyForPeerId(event.fromPeerID);
      _meshPmPubkeys.add(pubkey);
      final nym = _nymByPubkey[pubkey] ?? 'nym';
      _app.ensurePMConversation(pubkey, nym: nym);
      final m = _pmMessage(
        id: 'file-${DateTime.now().microsecondsSinceEpoch}',
        pubkey: pubkey,
        author: nym,
        content: '',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        isOwn: false,
      )
        ..localMediaPath = path
        ..localMediaMime = event.mimeType
        ..localMediaName = event.fileName;
      _app.ingestPMMessage(m);
      _notifyPm(
          pubkey: pubkey,
          nym: nym,
          body: event.isImage ? '📷 Photo' : '📎 ${event.fileName}',
          ts: m.timestamp);
    } else {
      final channelName = (event.channel == null || event.channel!.isEmpty)
          ? kMeshNearbyChannel
          : (event.channel!.startsWith('#')
              ? event.channel!.substring(1)
              : event.channel!);
      final key = channelName.toLowerCase();
      _meshChannelKeys.add(key);
      final pubkey = _pubkeyForPeerId(event.fromPeerID);
      final m = Message(
        id: 'file-${DateTime.now().microsecondsSinceEpoch}',
        author: event.senderNickname.isNotEmpty ? event.senderNickname : 'nym',
        pubkey: pubkey,
        content: '',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ms: DateTime.now().millisecondsSinceEpoch,
        isOwn: false,
        channel: channelName,
        eventKind: 20000,
        deliveryStatus: DeliveryStatus.sent,
        viaMesh: true,
      )
        ..localMediaPath = path
        ..localMediaMime = event.mimeType
        ..localMediaName = event.fileName;
      _app.ingestMeshChannelMessage(m, channelKey: '#$key');
    }
  }

  Message _pmMessage({
    required String id,
    required String pubkey,
    required String author,
    required String content,
    required int timestampMs,
    required bool isOwn,
  }) {
    return Message(
      id: id,
      author: author,
      pubkey: pubkey,
      content: content,
      createdAt: timestampMs ~/ 1000,
      ms: timestampMs,
      isOwn: isOwn,
      isPM: true,
      conversationKey: 'pm-$pubkey',
      conversationPubkey: pubkey,
      nymMessageId: id,
      eventKind: 1059,
      senderVerified: isOwn ? null : true,
      deliveryStatus: isOwn ? DeliveryStatus.sent : DeliveryStatus.delivered,
      viaMesh: true,
    );
  }

  void _refreshMarkers() {
    _ref.read(meshControllerProvider.notifier).refreshMarkers();
  }

  // ---- Outbound (from the canonical composer) ------------------------------

  /// Routes a composer send for the active mesh [view].
  Future<void> sendFromComposer(ChatView view, String content,
      {String? threadRoot}) async {
    if (view.kind == ViewKind.channel) {
      final echo = _app.sendLocal(content, threadRoot: threadRoot)
        ?..viaMesh = true;
      final channel = '#${view.id.toLowerCase()}';
      final meshId = await _service.sendPublicMessage(
        content,
        channel: view.id.toLowerCase() == kMeshNearbyChannel ? null : channel,
      );
      // The echo stays; the round-trip is deduped in ingestMeshChannelMessage.
      _queueForNostr(
        kind: MeshOutboxKind.channel,
        target: view.id,
        content: content,
        threadRoot: threadRoot,
        echo: echo,
        meshMessageId: meshId,
      );
    } else if (view.kind == ViewKind.pm) {
      _pinIfGhosted(view.id);
      final peerId = peerIdForPubkey(view.id);
      if (peerId == null) {
        // Out of radio range. The echo stays local and the radio publishes
        // nothing — for a pinned peer this is the fail-closed path, NOT a
        // fallback. It can still be queued for Nostr when the peer has a real
        // identity there (the queue applies the same ghost/mesh-only rules), so
        // an out-of-range send is not simply lost.
        final echo = _app.sendLocal(content, threadRoot: threadRoot)
          ?..viaMesh = true;
        _queueForNostr(
          kind: MeshOutboxKind.pm,
          target: view.id,
          content: content,
          threadRoot: threadRoot,
          echo: echo,
        );
        // Last resort: hand a sealed copy to peers who ARE in range, to carry
        // and deliver if they meet the recipient. This is the only path that
        // works when neither side has internet — the outbox above needs relays
        // to come back, and the radio needs the recipient to walk into range.
        unawaited(_depositWithCouriers(view.id, content, echo));
        return;
      }
      final id = await _service.sendPrivateMessage(peerId, content);
      final echo = _app.sendLocal(content,
          nymMessageId: id, threadRoot: threadRoot)
        ?..viaMesh = true;
      _queueForNostr(
        kind: MeshOutboxKind.pm,
        target: view.id,
        content: content,
        threadRoot: threadRoot,
        echo: echo,
        meshMessageId: id,
        nymMessageId: id,
      );
    }
  }

  /// Seals an out-of-range DM to the peer's Noise static key and hands copies
  /// to nearby peers to carry.
  ///
  /// The payload is the SAME Noise transport payload a live session would have
  /// carried, so a message delivered out of a courier's hands behaves exactly
  /// like one that arrived over the air — including its delivery receipt.
  ///
  /// The refusal rules live in [MeshService.depositWithCouriers] /
  /// [CourierStore.mayDeposit]: a ghost-pinned conversation and a ghosted
  /// sender never deposit, because asking a stranger to carry mail is precisely
  /// the link a ghost identity exists to prevent.
  Future<void> _depositWithCouriers(
      String pubkey, String content, Message? echo) async {
    final staticKeyHex = _noiseKeyHexForPubkey(pubkey);
    if (staticKeyHex == null) return;
    try {
      final payload = MeshService.privateMessagePayload(
        messageId: echo?.nymMessageId ?? echo?.id ?? '',
        content: content,
      );
      if (payload == null) return;
      final handed = await _service.depositWithCouriers(
        recipientStaticKeyHex: staticKeyHex,
        payload: payload,
      );
      MeshDiagnostics.instance.log('courier deposit for '
          '${_short(pubkey)}: $handed carrier(s)');
    } catch (_) {
      // Best-effort: a refused deposit leaves the message no worse off.
    }
  }

  /// The Noise static key we last saw for a conversation pubkey, or null when
  /// that peer has never been met over the radio (nothing to seal to).
  String? _noiseKeyHexForPubkey(String pubkey) {
    for (final entry in _pubkeyByPeerId.entries) {
      if (entry.value.toLowerCase() != pubkey.toLowerCase()) continue;
      final hex = _service.noiseKeyHexForPeer(entry.key);
      if (hex != null && hex.length == 64) return hex;
    }
    return null;
  }

  /// Retains a mesh-carried send so it reaches Nostr once relays return.
  ///
  /// The radio delivers to whoever is in range NOW; everyone else — another
  /// room, another device, anyone who reads this later — only ever sees the
  /// message if it also reaches the relays. [NostrController.flushMeshOutbox]
  /// publishes it on the next reconnect.
  ///
  /// Three things are never queued, and the exclusions matter more than the
  /// feature:
  ///  * a GHOST-PINNED PM. The peer met us as a ghost and knows us only as
  ///    that; the Nostr copy signs with the real key and would hand them the
  ///    link. `shouldSendOverMesh` fails such a send closed rather than falling
  ///    through to Nostr for exactly this reason — the queue must not undo it.
  ///  * a MESH-ONLY peer. Its pubkey is a local `sha256("mesh:<peerID>")`
  ///    placeholder, not an identity anyone can receive at, so a gift wrap to
  ///    it would encrypt to nothing and leak the conversation's existence for
  ///    no delivery.
  ///  * a send made while ONLINE. The composer already published it to Nostr
  ///    directly, so queueing it would publish the same message twice.
  void _queueForNostr({
    required MeshOutboxKind kind,
    required String target,
    required String content,
    required Message? echo,
    String? threadRoot,
    String? meshMessageId,
    String? nymMessageId,
  }) {
    if (echo == null) return;
    if (_online) return;
    final id = target.toLowerCase();
    if (kind == MeshOutboxKind.pm) {
      if (_ghostPinnedPms.contains(id)) return;
      if (_meshOnlyPmPubkeys.contains(id)) return;
    }
    try {
      _ref.read(nostrControllerProvider).enqueueMeshOutbox(
            MeshOutboxEntry(
              kind: kind,
              target: target,
              content: content,
              // The queue replays with the time the user actually sent, so the
              // message keeps its place in the conversation.
              createdAtSec: echo.createdAt,
              localId: echo.id,
              threadRoot: threadRoot,
              meshMessageId: meshMessageId,
              nymMessageId: nymMessageId,
            ),
          );
    } catch (_) {
      // Best-effort: a queue failure must never cost the radio send that
      // already went out.
    }
    // Now sign the event this send would have published, and let BOTH delivery
    // paths carry that same one: a gateway may publish it in a moment, and our
    // own outbox may publish it hours later. Identical bytes mean an identical
    // event id, so the relays treat the second as a duplicate rather than a
    // second message.
    //
    // Deliberately after the enqueue rather than before it: signing mines proof
    // of work, and the message must be durably queued the instant the radio
    // carried it — not once the mining finishes.
    unawaited(_signAndOfferToGateways(
      kind: kind,
      target: target,
      content: content,
      echo: echo,
      threadRoot: threadRoot,
      meshMessageId: meshMessageId,
    ));
  }

  Future<void> _signAndOfferToGateways({
    required MeshOutboxKind kind,
    required String target,
    required String content,
    required Message echo,
    String? threadRoot,
    String? meshMessageId,
  }) async {
    final signed = await _buildOutboxEvent(
      kind: kind,
      target: target,
      content: content,
      echo: echo,
      threadRoot: threadRoot,
      meshMessageId: meshMessageId,
    );
    if (signed == null) return;
    try {
      _ref
          .read(nostrControllerProvider)
          .attachMeshOutboxSignedEvent(echo.id, signed.toJson());
    } catch (_) {
      // The entry replays the ordinary way without it.
    }
    // Ask anyone nearby who still has a signal to publish it now. The outbox
    // waits for OUR internet; this does not have to. It stays a shortcut and
    // never the only copy — the entry is queued either way, because nothing
    // on the wire tells us whether a gateway succeeded.
    await _askGateways(target, signed);
  }

  /// Builds and signs the event this send would have published, without
  /// publishing it.
  ///
  /// Channels only. A PM replays as a gift wrap addressed to one pubkey, and
  /// handing that to a stranger to post tells them we are talking to that
  /// person — the same disclosure the courier gate exists to refuse. It also
  /// returns null while ghosted: the event signs with the REAL key, so
  /// publishing it would tie the epoch straight back to the npub.
  Future<NostrEvent?> _buildOutboxEvent({
    required MeshOutboxKind kind,
    required String target,
    required String content,
    required Message echo,
    String? threadRoot,
    String? meshMessageId,
  }) async {
    if (kind != MeshOutboxKind.channel) return null;
    if (_ref.read(ghostModeProvider).enabled) return null;
    // No signed copy is not a failure: the outbox still replays this the
    // ordinary way once our own internet returns.
    return _ref.read(nostrControllerProvider).buildMeshOutboxEvent(
          channelKey: target,
          content: content,
          createdAtSec: echo.createdAt,
          threadRoot: threadRoot,
          meshMessageId: meshMessageId,
        );
  }

  /// Asks nearby peers to publish [event] for us.
  ///
  /// Verified peers only: an unverified one is a radio claiming a name, and
  /// handing it our traffic tells a stranger we are here. The ask goes to all
  /// of them rather than picking one, because nothing on the wire says which
  /// peer has internet — a peer that has none simply declines.
  Future<void> _askGateways(String geohash, NostrEvent event) async {
    if (!_service.isRunning) return;
    var asked = 0;
    for (final peer in _service.peers) {
      if (!peer.isVerified) continue;
      final ok = await _service.carryToGateway(
        gatewayPeerID: peer.peerID,
        geohash: geohash,
        event: event.toJson(),
      );
      if (ok) asked++;
    }
    if (asked > 0) {
      MeshDiagnostics.instance.log('asked $asked peer(s) to publish for us');
    }
  }

  /// Sends a file/media attachment over the mesh for the active [view].
  /// Sniffs the real image MIME from the content's magic bytes. bitchat drops a
  /// file whose declared MIME isn't in its allowlist (image/jpeg|png|gif|webp,
  /// audio, pdf — NO video) OR whose bytes don't match the MIME's signature, so
  /// a mislabeled pick (e.g. the picker handing us a bare octet-stream) must be
  /// corrected to the true type or bitchat rejects it. Returns the sniffed MIME,
  /// else the caller's fallback (which bitchat may still reject — notably iOS
  /// HEIC photos and any video, neither of which bitchat accepts).
  static String _sniffMime(Uint8List b, String fallback) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (b.length >= 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'image/png';
    }
    if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return 'image/gif';
    }
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'image/webp';
    }
    return fallback;
  }

  Future<void> sendFileFromComposer(
    ChatView view,
    String fileName,
    String mimeTypeIn,
    Uint8List bytes,
  ) async {
    final mimeType = _sniffMime(bytes, mimeTypeIn);
    final path = await _saveFile(fileName, bytes);
    if (view.kind == ViewKind.channel) {
      final name = view.id.toLowerCase();
      await _service.sendFileBroadcast(fileName, mimeType, bytes);
      final m = Message(
        id: 'file-${DateTime.now().microsecondsSinceEpoch}',
        author: _selfNym(),
        pubkey: _appState.selfPubkey,
        content: '',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ms: DateTime.now().millisecondsSinceEpoch,
        isOwn: true,
        channel: name,
        eventKind: 20000,
        deliveryStatus: DeliveryStatus.sent,
        viaMesh: true,
      )
        ..localMediaPath = path
        ..localMediaMime = mimeType
        ..localMediaName = fileName;
      _app.ingestMeshChannelMessage(m, channelKey: '#$name');
    } else if (view.kind == ViewKind.pm) {
      final peerId = peerIdForPubkey(view.id);
      if (peerId != null) {
        await _service.sendFileToPeer(peerId, fileName, mimeType, bytes);
      }
      final m = _pmMessage(
        id: 'file-${DateTime.now().microsecondsSinceEpoch}',
        pubkey: view.id,
        author: _selfNym(),
        content: '',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        isOwn: true,
      )
        ..localMediaPath = path
        ..localMediaMime = mimeType
        ..localMediaName = fileName;
      _app.ingestPMMessage(m);
    }
  }

  // ---- Notifications -------------------------------------------------------

  void _notifyPm({
    required String pubkey,
    required String nym,
    required String body,
    required int ts,
  }) {
    _ref.read(nostrControllerProvider).dispatchMeshNotification(
          title: nym,
          body: body,
          senderPubkey: pubkey,
          isMention: false,
          historyType: 'pm',
          route: pubkey,
          tsMs: ts,
          eventId: 'mesh-pm-$ts-$pubkey',
        );
  }

  void _maybeNotifyChannelMention(Message m, String channelName) {
    final nym = _selfNym().toLowerCase();
    if (nym.isEmpty) return;
    final body = m.content.toLowerCase();
    if (!body.contains('@$nym') && !body.contains(nym)) return;
    _ref.read(nostrControllerProvider).dispatchMeshNotification(
          title: '#$channelName',
          body: m.content,
          senderPubkey: m.pubkey,
          isMention: true,
          historyType: 'mention',
          route: channelName,
          tsMs: m.timestamp,
          eventId: 'mesh-mention-${m.id}',
          contextLabel: '#$channelName',
        );
  }

  // ---- Disk ----------------------------------------------------------------

  Future<String?> _saveFile(String fileName, Uint8List bytes) async {
    try {
      final dir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/mesh_files');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = '${dir.path}/${stamp}_$safe';
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }
}

/// Exposes a peer's rich profile to the bridge/registry (avatar bytes) — reused
/// by the controller's profile-transfer path.
typedef MeshProfileSink = void Function(String peerID, MeshProfile profile);
