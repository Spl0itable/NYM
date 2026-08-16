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
import '../../models/message.dart';
import '../../services/mesh/mesh_events.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/mesh_service.dart';
import '../../services/mesh/noise/noise_crypto.dart';
import '../../services/mesh/protocol/mesh_profile.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'mesh_controller.dart';
import 'mesh_diagnostics.dart';

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
String meshStablePubkeyForPeerId(String peerID) => _hex(
    NoiseCrypto.sha256(Uint8List.fromList(utf8.encode('mesh:${peerID.toLowerCase()}'))));

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

  bool isMeshChannelKey(String key) => _meshChannelKeys.contains(key.toLowerCase());
  bool isMeshPmPubkey(String pubkey) => _meshPmPubkeys.contains(pubkey.toLowerCase());

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
    if (!_canSendToView(view)) return false;
    if (view.kind == ViewKind.pm &&
        _meshOnlyPmPubkeys.contains(view.id.toLowerCase())) {
      return true;
    }
    return !_online;
  }

  // ---- Lifecycle -----------------------------------------------------------

  ProviderSubscription<ChatView>? _viewSub;

  void start() {
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
  String? peerIdForPubkey(String pubkey) => _peerIdByPubkey[pubkey.toLowerCase()];

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
    final channelName = (msg.channel == null || msg.channel!.isEmpty)
        ? kMeshNearbyChannel
        : (msg.channel!.startsWith('#')
            ? msg.channel!.substring(1)
            : msg.channel!);
    final key = channelName.toLowerCase();
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
      eventKind: 20000,
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
    MeshDiagnostics.instance.log(
        'PM rx peer=${msg.senderPeerID} id=${_short(msg.messageId)} '
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
          : (e.channel!.startsWith('#')
              ? e.channel!.substring(1)
              : e.channel!);
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
        unawaited(_service.sendPrivateReaction(peerId, targetId, emoji, remove));
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
  Future<void> sendFromComposer(ChatView view, String content) async {
    if (view.kind == ViewKind.channel) {
      _app.sendLocal(content)?.viaMesh = true;
      final channel = '#${view.id.toLowerCase()}';
      await _service.sendPublicMessage(
        content,
        channel: view.id.toLowerCase() == kMeshNearbyChannel ? null : channel,
      );
      // The echo stays; the round-trip is deduped in ingestMeshChannelMessage.
    } else if (view.kind == ViewKind.pm) {
      final peerId = peerIdForPubkey(view.id);
      if (peerId == null) {
        _app.sendLocal(content)?.viaMesh = true;
        return;
      }
      final id = await _service.sendPrivateMessage(peerId, content);
      _app.sendLocal(content, nymMessageId: id)?.viaMesh = true;
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
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'image/png';
    }
    if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return 'image/gif';
    }
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
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
