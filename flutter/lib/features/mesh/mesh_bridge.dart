// Ingests Bluetooth mesh traffic into the normal chat stores and routes sends for mesh-backed conversations back over the mesh.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../identity/panic_wipe.dart';
import '../chat_tools/chat_tools.dart' show meshKeepId, parseMeshKeepId;
import '../chat_tools/chat_tools_providers.dart';
import '../media_notes/media_note_stores.dart';
import '../media_notes/media_notes.dart';
import '../i18n/i18n.dart';
import 'ghost_mode.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'mesh_controller.dart';
import 'mesh_diagnostics.dart';
import 'mesh_outbox.dart';
import '../../services/mesh/protocol/nostr_carrier_packet.dart';
import '../../services/storage/at_rest_cipher.dart';
import '../../services/storage/mesh_file_store.dart';
import '../../services/storage/sealed_key_value.dart';

/// Storage key of the mesh "Nearby" channel (`#mesh`).
const String kMeshNearbyChannel = 'mesh';

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

String _short(String s) => s.length <= 8 ? s : s.substring(0, 8);

/// Stable conversation pubkey `SHA-256("mesh:" + peerID)`, so opened DMs and replies share one thread.
String meshStablePubkeyForPeerId(String peerID) => _hex(NoiseCrypto.sha256(
    Uint8List.fromList(utf8.encode('mesh:${peerID.toLowerCase()}'))));

class MeshBridge {
  MeshBridge({
    required this._ref,
    required this._service,
    required this._selfNym,
    this._cipher,
  });

  final Ref _ref;
  final AtRestCipher? _cipher;
  final MeshService _service;
  final String Function() _selfNym;

  final List<StreamSubscription<dynamic>> _subs = [];

  /// peerID (16-hex) -> 64-hex PM store key.
  final Map<String, String> _pubkeyByPeerId = {};

  /// pubkey -> peerID, for routing outgoing DMs.
  final Map<String, String> _peerIdByPubkey = {};

  /// Nym per peer pubkey, for inbound message authors.
  final Map<String, String> _nymByPubkey = {};

  /// Lowercase mesh-backed channel keys, for the sidebar glyph and send routing.
  final Set<String> _meshChannelKeys = {kMeshNearbyChannel};

  /// Pubkeys whose PM conversation is mesh-backed.
  final Set<String> _meshPmPubkeys = {};

  /// Unlinked peers whose pseudo-pubkey Nostr can't address, so their DMs always go over the mesh.
  final Set<String> _meshOnlyPmPubkeys = {};

  AppStateNotifier get _app => _ref.read(appStateProvider.notifier);
  AppState get _appState => _ref.read(appStateProvider);

  bool isMeshChannelKey(String key) =>
      _meshChannelKeys.contains(key.toLowerCase());
  bool isMeshPmPubkey(String pubkey) =>
      _meshPmPubkeys.contains(pubkey.toLowerCase());

  Set<String> get meshChannelKeys => _meshChannelKeys;
  Set<String> get meshPmPubkeys => _meshPmPubkeys;

  bool get _online => _appState.connectedRelays > 0;

  /// Channels can always broadcast; a DM needs the peer in radio range.
  bool _canSendToView(ChatView view) {
    if (view.kind == ViewKind.channel) return true;
    if (view.kind == ViewKind.pm) return peerIdForPubkey(view.id) != null;
    return false;
  }

  /// Mesh when offline or for mesh-only peers; online sends to real Nostr identities go over the internet.
  bool shouldSendOverMesh(ChatView view) {
    if (view.kind == ViewKind.pm) {
      final id = view.id.toLowerCase();
      // Checked before reachability: a ghost-pinned send fails closed, since Nostr would sign with the real key.
      if (_ghostPinnedPms.contains(id)) return true;
      if (_canSendToView(view) && _meshOnlyPmPubkeys.contains(id)) return true;
    }
    if (!_canSendToView(view)) return false;
    return !_online;
  }

  /// Conversations that must never traverse Nostr; persisted beyond the ghost epoch and restarts.
  final Set<String> _ghostPinnedPms = {};

  bool isMeshOnlyPubkey(String pubkey) =>
      _meshOnlyPmPubkeys.contains(pubkey.toLowerCase());

  bool isGhostPinned(String pubkey) =>
      _ghostPinnedPms.contains(pubkey.toLowerCase());

  /// Mesh-pinned view with the peer out of range, so sends stall; drives the composer notice.
  bool isAwaitingMeshRange(ChatView view) {
    if (view.kind != ViewKind.pm) return false;
    if (!_ghostPinnedPms.contains(view.id.toLowerCase())) return false;
    return peerIdForPubkey(view.id) == null;
  }

  SealedKeyValue? _sealedStore;
  bool _gossipLocked = false;
  bool _prekeysLocked = false;
  bool _retryingLocked = false;

  SealedKeyValue get _sealed {
    final kv = _ref.read(keyValueStoreProvider);
    final existing = _sealedStore;
    if (existing != null && identical(existing.kv, kv)) return existing;
    return _sealedStore = SealedKeyValue(kv,
        cipher: _cipher, blocked: () => PanicWipe.inProgress);
  }

  Future<void> _restoreGossipArchive() async {
    try {
      final read = await _sealed.readDetailed(StorageKeys.meshGossipArchive);
      _gossipLocked = read.locked;
      _service.gossip.decodeArchive(read.value);
    } catch (_) {}
    _service.onGossipArchiveChanged = (archive) {
      if (_gossipLocked) {
        unawaited(_retryLockedStores());
        return;
      }
      try {
        _sealed.write(StorageKeys.meshGossipArchive, archive);
      } catch (_) {}
    };
  }

  Future<void> _restorePrekeys() async {
    try {
      final read = await _sealed.readDetailed(StorageKeys.meshPrekeys);
      _prekeysLocked = read.locked;
      _service.prekeys.decode(read.value);
    } catch (_) {
      _prekeysLocked = true;
      _service.prekeys.clear();
    }
    _service.prekeysReady = () {
      if (_prekeysLocked) unawaited(_retryLockedStores());
      return !_prekeysLocked;
    };
    _service.onPrekeysChanged = (encoded) {
      if (_prekeysLocked) {
        unawaited(_retryLockedStores());
        return;
      }
      try {
        _sealed.write(StorageKeys.meshPrekeys, encoded);
      } catch (_) {}
    };
  }

  Future<void> _retryLockedStores() async {
    if (_retryingLocked || !(_gossipLocked || _prekeysLocked)) return;
    _retryingLocked = true;
    try {
      if (_gossipLocked) {
        final read = await _sealed.readDetailed(StorageKeys.meshGossipArchive);
        if (!read.locked) {
          _service.gossip.decodeArchive(read.value);
          _gossipLocked = false;
          _sealed.write(
              StorageKeys.meshGossipArchive, _service.gossip.encodeArchive());
        }
      }
      if (_prekeysLocked) {
        final read = await _sealed.readDetailed(StorageKeys.meshPrekeys);
        if (!read.locked) {
          _service.prekeys.decode(read.value);
          _prekeysLocked = false;
          unawaited(_service.publishPrekeyBundle());
        }
      }
    } catch (_) {
    } finally {
      _retryingLocked = false;
    }
  }

  /// Verifies a gateway-carried event against its originator's signature before acting; gateways can't author.
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

  /// Pins [pubkey] to the mesh when the exchange happened while ghosted.
  void _pinIfGhosted(String pubkey) {
    if (!_ref.read(ghostModeProvider).enabled) return;
    if (!_ghostPinnedPms.add(pubkey.toLowerCase())) return;
    // JSON array of hex pubkeys, as getStringSet reads back.
    _ref.read(keyValueStoreProvider).setString(
          StorageKeys.ghostPinnedPms,
          '[${_ghostPinnedPms.map((e) => '"$e"').join(',')}]',
        );
  }

  ProviderSubscription<ChatView>? _viewSub;

  Future<void> start() async {
    _loadGhostPins();
    await _restoreGossipArchive();
    // Courier gates need the ghost state, which only the bridge holds.
    _service.isGhostMode = () => _ref.read(ghostModeProvider).enabled;
    _service.isGhostPinned = (staticKeyHex) {
      final pubkey = _pubkeyForNoiseKey(staticKeyHex);
      return pubkey != null && _ghostPinnedPms.contains(pubkey.toLowerCase());
    };
    await _restorePrekeys();
    _service.onNostrCarrier = _onNostrCarrier;
    MeshService.debugLog = MeshDiagnostics.instance.log;
    _subs.add(_service.peersStream.listen(_onPeers));
    _subs.add(_service.onPublicMessage.listen(_onPublic));
    _subs.add(_service.onPrivateMessage.listen(_onPrivate));
    _subs.add(_service.onReceipt.listen(_onReceipt));
    _subs.add(_service.onFile.listen(_onFile));
    _subs.add(_service.onTyping.listen(_onTyping));
    _subs.add(_service.onReaction.listen(_onReaction));
    // Register the always-present Nearby channel.
    _app.addChannel(kMeshNearbyChannel);
    // Send mesh read receipts when a mesh DM becomes active.
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

  /// Message ids already acked, so each inbound DM is acked once.
  final Set<String> _readAcked = {};

  /// Acks every not-yet-acked inbound message in [pubkey]'s thread; idempotent.
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

  /// Registers a joined mesh group [channel] as an app channel.
  void registerChannel(String channel) {
    final name = channel.startsWith('#') ? channel.substring(1) : channel;
    if (name.isEmpty) return;
    _meshChannelKeys.add(name.toLowerCase());
    _app.addChannel(name);
  }

  /// Same resolve-once cache as inbound messages, so both key the identical thread.
  String pubkeyForPeer(MeshPeer peer) => _pubkeyForPeerId(peer.peerID);

  /// Conversation pubkey for a Noise static key, or null if never met (the courier gate then falls through).
  String? _pubkeyForNoiseKey(String staticKeyHex) {
    if (staticKeyHex.length != 64) return null;
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      final b =
          int.tryParse(staticKeyHex.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      bytes[i] = b;
    }
    // peerID is the first 16 hex of SHA-256 over the static key.
    final peerID = _hex(NoiseCrypto.sha256(bytes)).substring(0, 16);
    return _pubkeyByPeerId[peerID];
  }

  String _pubkeyForPeerId(String peerID) {
    final peer = _service.peerById(peerID);
    final cached = _pubkeyByPeerId[peerID];
    if (cached != null) {
      // Refresh the nym but never re-key an existing conversation.
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

  /// Radio peerID for an outgoing DM to [pubkey].
  String? peerIdForPubkey(String pubkey) =>
      _peerIdByPubkey[pubkey.toLowerCase()];

  /// Opens a mesh DM with [peer] and returns the pubkey to switch to.
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

  void _onPeers(List<MeshPeer> peers) {
    if (_prekeysLocked || _gossipLocked) unawaited(_retryLockedStores());
    for (final p in peers) {
      final pubkey = pubkeyForPeer(p);
      _pubkeyByPeerId[p.peerID] = pubkey;
      _peerIdByPubkey[pubkey] = p.peerID;
      _nymByPubkey[pubkey] = p.displayName;
      _classifyPeer(p, pubkey);
      // Seed the nym so the PM header shows the peer's nickname before any message.
      if (p.nickname != null && p.nickname!.isNotEmpty) {
        _app.upsertUserNym(pubkey, p.nickname!);
      }
    }
  }

  /// Verified Nostr link means dual-transport; unlinked peers are mesh-only.
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
    // Validate the frame's channel name like the Nostr ingest, so peers can't file under impossible channels.
    final raw = (msg.channel == null || msg.channel!.isEmpty)
        ? kMeshNearbyChannel
        : (msg.channel!.startsWith('#')
            ? msg.channel!.substring(1)
            : msg.channel!);
    // Invalid names fall back to Nearby rather than being dropped.
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
      // The channel's Nostr kind, so reactions carry the same `k` as the relay copy.
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
        'vis=$vis view=${_appState.view.kind == ViewKind.pm ? 'pm' : _appState.view.storageKey} own=$isOwn '
        '${landed ? 'LANDED' : 'DROPPED'}');
    if (landed && !isOwn) _maybeNotifyChannelMention(m, channelName);
  }

  void _onPrivate(MeshPrivateMessage msg) {
    final pubkey = _pubkeyForPeerId(msg.senderPeerID);
    // Mesh-only until a linked announce upgrades the peer, since a DM can precede its announce.
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
    // Ack immediately if this thread is on screen.
    final view = _appState.view;
    if (view.kind == ViewKind.pm && view.id.toLowerCase() == pubkey) {
      markMeshPmRead(pubkey);
    }
  }

  void _onReceipt(MeshReceipt receipt) {
    if (parseMeshKeepId(receipt.messageId) != null) {
      if (receipt.isRead) {
        _ref.read(chatToolsProvider).handleMeshKeep(
            receipt.messageId, _pubkeyForPeerId(receipt.fromPeerID));
      }
      return;
    }
    final onceId = parseMeshOnceReceiptId(receipt.messageId);
    if (onceId.isNotEmpty) {
      if (receipt.isRead &&
          _ref
              .read(onceStoreProvider)
              .markRemoteOpened(onceId, 'mesh:${receipt.fromPeerID}')) {
        _ref.read(onceRevisionProvider.notifier).state++;
      }
      return;
    }
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
    // Only react to a message we hold, canonicalized to its stored id.
    final existing = _app.messageById(e.targetId);
    if (existing == null) return;
    final pubkey = _pubkeyForPeerId(e.senderPeerID);
    // Never apply an inbound reaction as if it were ours.
    if (pubkey == _appState.selfPubkey) return;
    _app.applyReaction(
      messageId: existing.id,
      emoji: e.emoji,
      reactor: pubkey,
      removed: e.isRemove,
      reactorNym: e.reactorNick,
    );
  }

  /// Sends an emoji reaction to [targetId] over the mesh.
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

  /// Typing indicator for the active mesh view; the receiver expires it after ~5s.
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
      final note = parseMeshFileName(event.fileName, event.mimeType);
      _notifyPm(
          pubkey: pubkey,
          nym: nym,
          body: note != null
              ? plainLabel(note, tr)
              : (event.isImage ? '📷 Photo' : '📎 ${event.fileName}'),
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
      // The echo stays; the round trip is deduped on ingest.
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
        // Out of range: keep the local echo and queue for Nostr where allowed; for pinned peers this fails closed.
        final echo = _app.sendLocal(content, threadRoot: threadRoot)
          ?..viaMesh = true;
        _queueForNostr(
          kind: MeshOutboxKind.pm,
          target: view.id,
          content: content,
          threadRoot: threadRoot,
          echo: echo,
        );
        // Last resort: sealed copies to in-range peers to carry, the only path when neither side has internet.
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

  /// Seals an out-of-range DM to the peer's Noise key for couriers; ghosted senders and pinned conversations never deposit.
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

  /// Last Noise static key seen for a pubkey, or null if never met.
  String? _noiseKeyHexForPubkey(String pubkey) {
    for (final entry in _pubkeyByPeerId.entries) {
      if (entry.value.toLowerCase() != pubkey.toLowerCase()) continue;
      final hex = _service.noiseKeyHexForPeer(entry.key);
      if (hex != null && hex.length == 64) return hex;
    }
    return null;
  }

  /// Queues a mesh send for Nostr on reconnect, except ghost-pinned PMs, mesh-only peers, and sends made online.
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
              // Replay with the original send time so the message keeps its place.
              createdAtSec: echo.createdAt,
              localId: echo.id,
              threadRoot: threadRoot,
              meshMessageId: meshMessageId,
              nymMessageId: nymMessageId,
            ),
          );
    } catch (_) {
      // Best-effort: a queue failure must never cost the radio send.
    }
    // Sign once so gateway and outbox publish identical bytes (same id); after enqueue so mining can't delay queueing.
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
    // Gateways may publish sooner; the entry stays queued either way.
    await _askGateways(target, signed);
  }

  /// Channels only (a PM wrap would reveal who we talk to); null while ghosted, since it signs with the real key.
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
    // No signed copy isn't a failure; the outbox replays it later.
    return _ref.read(nostrControllerProvider).buildMeshOutboxEvent(
          channelKey: target,
          content: content,
          createdAtSec: echo.createdAt,
          threadRoot: threadRoot,
          meshMessageId: meshMessageId,
        );
  }

  /// Asks every verified nearby peer to publish [event]; peers without internet decline.
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

  /// Sniffs the real image MIME from magic bytes, since bitchat rejects mislabeled or unsupported types.
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

  Future<bool> sendKeep(String pubkey, String nid, bool kept) async {
    final peerId = peerIdForPubkey(pubkey);
    if (peerId == null) return false;
    await _service.sendReadReceipt(peerId, meshKeepId(nid, kept));
    return true;
  }

  Future<void> sendOnceOpened(String senderPubkey, String onceId) async {
    final peerId = peerIdForPubkey(senderPubkey);
    if (peerId == null) return;
    await _service.sendReadReceipt(peerId, meshOnceReceiptId(onceId));
  }

  bool fileFits(ChatView view, String fileName, String mimeType, Uint8List bytes) {
    if (view.kind == ViewKind.pm) {
      final peerId = peerIdForPubkey(view.id);
      return _service.fileFits(fileName, mimeType, bytes, peerID: peerId ?? '00');
    }
    return _service.fileFits(fileName, mimeType, bytes);
  }

  Future<bool> sendFileFromComposer(
    ChatView view,
    String fileName,
    String mimeTypeIn,
    Uint8List bytes,
  ) async {
    final mimeType = _sniffMime(bytes, mimeTypeIn);
    if (!meshSizeCheck(bytes.length).ok || !fileFits(view, fileName, mimeType, bytes)) {
      return false;
    }
    final path = await _saveFile(fileName, bytes);
    if (view.kind == ViewKind.channel) {
      final name = view.id.toLowerCase();
      if (!await _service.sendFileBroadcast(fileName, mimeType, bytes)) {
        return false;
      }
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
      if (peerId != null &&
          !await _service.sendFileToPeer(peerId, fileName, mimeType, bytes)) {
        return false;
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
    return true;
  }

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

  Future<String?> _saveFile(String fileName, Uint8List bytes) =>
      MeshFileStore.instance.save(fileName, bytes);
}

/// Exposes a peer's rich profile (avatar bytes) to the bridge.
typedef MeshProfileSink = void Function(String peerID, MeshProfile profile);
