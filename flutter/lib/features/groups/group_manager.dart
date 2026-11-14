import 'dart:typed_data';

import '../../models/group.dart';
import '../../models/nostr_event.dart';
import '../../services/nostr/nostr_service.dart';
import '../../services/nostr/event_signer.dart';
import 'control_answers.dart';
import 'group_logic.dart';
import 'group_invited.dart';
import 'group_invites.dart';

const int kKeyGivenWindowMs = 300000;

/// Owns per-group rotating ephemeral keys and drives gift-wrapped group sends; crypto is delegated to the service.
class GroupManager {
  GroupManager(this._service);

  final NostrService _service;

  /// Member's announced ML-KEM key by real pubkey, or null; unset leaves every send classical.
  Uint8List? Function(String memberPubkey)? kemKeyFor;

  /// Whether a member's key is root-seeded; unset reads as legacy, the safe default for a badge.
  bool Function(String memberPubkey)? rootSeededFor;

  /// Whether a member accepts the layered format; unset keeps the combined format.
  bool Function(String memberPubkey)? layeredFor;

  void Function(NostrEvent wrap)? onWrap;

  void Function(NostrEvent wrap)? _depositFor(UnsignedEvent rumor) =>
      rumor.kind == 14 || rumor.kind == 7 ? onWrap : null;

  /// Per-message post-quantum coverage; a message counts as protected only if every member got a PQ wrap.
  final Map<String, ({int pq, int total})> _pqCoverage = {};

  ({int pq, int total})? pqCoverageFor(String nymMessageId) =>
      _pqCoverage[nymMessageId];

  /// Whether the whole fan-out went to root-seeded keys.
  final Map<String, bool> _pqAllRoot = {};

  bool pqAllRootFor(String nymMessageId) => _pqAllRoot[nymMessageId] ?? false;

  void _recordCoverage(String nymMessageId, int pq, int total, int root) {
    _pqCoverage[nymMessageId] = (pq: pq, total: total);
    _pqAllRoot[nymMessageId] = total > 0 && pq == total && root == total;
    while (_pqCoverage.length > 2000) {
      _pqAllRoot.remove(_pqCoverage.keys.first);
      _pqCoverage.remove(_pqCoverage.keys.first);
    }
  }

  /// groupId -> rotating ephemeral key state.
  final Map<String, GroupEphemeralKeys> _keys = {};

  GroupEphemeralKeys keysFor(String groupId) =>
      _keys.putIfAbsent(groupId, GroupEphemeralKeys.new);

  /// Every ephemeral secret key (current and previous) across groups, for unwrap candidates.
  List<Uint8List> allEphemeralSecretKeys() {
    final out = <Uint8List>[];
    for (final ek in _keys.values) {
      out.addAll(ek.selfSecretKeys());
    }
    return out;
  }

  /// Every self ephemeral pubkey (current and previous), for `#p` subscriptions.
  List<String> allEphemeralPubkeys() {
    final out = <String>[];
    for (final ek in _keys.values) {
      if (ek.selfCurrent != null) out.add(ek.selfCurrent!.pk);
      for (final p in ek.selfPrev) {
        out.add(p.pk);
      }
    }
    return out;
  }

  void Function()? onSelfKeysChanged;

  void _refreshServiceKeys() {
    _service.setEphemeralKeys(allEphemeralSecretKeys());
    onSelfKeysChanged?.call();
  }

  /// Deletes a left group's keys and re-arms unwrap candidates so they stop riding subscriptions and sync.
  void removeGroup(String groupId) {
    answerMinted.remove(groupId);
    answerMintedAt.remove(groupId);
    if (_keys.remove(groupId) == null) return;
    _refreshServiceKeys();
  }

  /// Per-group ephemeral key state for the `nymchat-keys-<gid>` sync categories.
  Map<String, Map<String, dynamic>> ephemeralKeysForSync() {
    final out = <String, Map<String, dynamic>>{};
    _keys.forEach((groupId, ek) => out[groupId] = ek.toSyncJson());
    return out;
  }

  /// Merges synced keys for [groupId]; true when a new self pubkey was added, meaning decryption must re-arm.
  bool mergeEphemeralKeys(String groupId, Map<String, dynamic> entry) {
    final ek = keysFor(groupId);
    final before = _selfPkCount(ek);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var minted = answerMinted[groupId];
    var meta = answerMintedAt[groupId];
    if (minted != null && meta == null) {
      meta = {'at': now, 'repaired': false};
      answerMintedAt[groupId] = meta;
    }
    if (minted != null && !GroupInvites.settleOpen(meta, now)) {
      answerMinted.remove(groupId);
      answerMintedAt.remove(groupId);
      minted = null;
    }
    final settle = minted != null && minted == ek.selfCurrent?.pk;
    ek.mergeSyncJson(entry, settle: settle);
    final cur = ek.selfCurrent?.pk;
    if (settle && cur != null) {
      answerMinted[groupId] = cur;
      final self = entry['self'];
      final row = self is Map && self['current'] is Map
          ? {
              'current': (self['current'] as Map)['pk'],
              'prev': [
                if (self['prev'] is List)
                  for (final k in self['prev'] as List)
                    if (k is Map) k['pk'],
              ],
            }
          : null;
      if (meta != null && GroupInvites.settleDue(meta, row, minted, cur, now)) {
        meta['repaired'] = true;
        repairDue.add(groupId);
      }
    }
    return _selfPkCount(ek) > before;
  }

  Map<String, Map<String, dynamic>> ephemeralKeysForStore([int? now]) {
    final t = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final out = ephemeralKeysForSync();
    out.forEach((gid, e) {
      final pk = answerMinted[gid];
      if (pk == null) return;
      final keep =
          GroupInvites.settleKeep({'pk': pk, ...?answerMintedAt[gid]}, t);
      if (keep != null) e['settle'] = keep;
    });
    return out;
  }

  void restoreSettle(String groupId, Object? m, [int? now]) {
    final keep = GroupInvites.settleKeep(
        m, now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (keep == null || answerMinted.containsKey(groupId)) return;
    answerMinted[groupId] = keep['pk'] as String;
    answerMintedAt[groupId] = {
      'at': keep['at'] as int,
      'repaired': keep['repaired'] == true,
    };
  }

  void noteMinted(String groupId, String pk, {int? at}) {
    answerMinted[groupId] = pk;
    answerMintedAt[groupId] = {
      'at': at ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'repaired': false,
    };
  }

  final Map<String, String> answerMinted = {};

  final Map<String, Map<String, Object>> answerMintedAt = {};

  final Set<String> repairDue = {};

  final Map<String, ({String current, Set<String> pks})> d1Self = {};

  void noteD1Self(String groupId, Map<String, dynamic> entry) {
    final self = entry['self'];
    if (self is! Map) return;
    final cur = self['current'];
    final pk = cur is Map ? cur['pk'] : null;
    if (pk is! String) return;
    final prev = self['prev'];
    d1Self[groupId] = (
      current: pk,
      pks: {
        pk,
        if (prev is List)
          for (final k in prev)
            if (k is Map && k['pk'] is String) k['pk'] as String,
      },
    );
  }

  Set<String> heldSelfKeys(String groupId) {
    final ek = keysFor(groupId);
    return {
      if (ek.selfCurrent != null) ek.selfCurrent!.pk,
      for (final k in ek.selfPrev) k.pk,
    };
  }

  bool wasAnswered(String groupId, String x) =>
      _keys[groupId]?.answered.containsKey(x) ?? false;

  void noteAnswered(String groupId, String x, int ts, int nowSec) {
    final ek = keysFor(groupId);
    final next = ControlAnswers.noteAnswered(ek.answered, x, ts, nowSec);
    ek.answered
      ..clear()
      ..addAll(next);
  }

  int _selfPkCount(GroupEphemeralKeys ek) =>
      (ek.selfCurrent != null ? 1 : 0) + ek.selfPrev.length;

  final Map<String, ({String eph, String to, int atMs})> _keyGiven = {};

  void noteKeyGiven(String groupId, Iterable<String> pubkeys, String ephPk,
      String Function(String pk) to,
      {int? nowMs}) {
    if (ephPk.isEmpty) return;
    final at = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    for (final pk in pubkeys) {
      if (pk.isNotEmpty) {
        _keyGiven['$groupId:$pk'] = (eph: ephPk, to: to(pk), atMs: at);
      }
    }
  }

  bool keyAlreadyGiven(String groupId, String pubkey,
      {String? announced, int? nowMs}) {
    final given = _keyGiven['$groupId:$pubkey'];
    final cur = _keys[groupId]?.selfCurrent?.pk;
    if (given == null || cur == null || given.eph != cur) return false;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (now - given.atMs > kKeyGivenWindowMs || now < given.atMs) return false;
    return given.to == pubkey ||
        (announced != null && announced.isNotEmpty && given.to == announced);
  }

  bool isOwnEphemeralPk(String groupId, String? pk) {
    if (pk == null || pk.isEmpty) return false;
    final ek = _keys[groupId];
    if (ek == null) return false;
    if (ek.selfCurrent?.pk == pk) return true;
    return ek.selfPrev.any((k) => k.pk == pk);
  }

  Map<String, int> memberKeyTsOf(String groupId) =>
      _keys[groupId]?.memberKeyTs ?? const <String, int>{};

  /// Records a member's advertised ephemeral pubkey, guarding against out-of-order updates.
  void recordMemberKey(
      String groupId, String memberPubkey, String ephemeralPk, int messageTs) {
    keysFor(groupId).updateMemberKey(memberPubkey, ephemeralPk, messageTs);
  }

  /// Creates a group and publishes the bootstrap `group-invite` carrying its metadata; [allowMemberInvites] defaults to true.
  Future<Group?> createGroup({
    required String selfPubkey,
    required String name,
    required List<String> memberPubkeys,
    String? avatar,
    String? banner,
    String? description,
    bool allowMemberInvites = true,
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    if (!_service.canSign) return null;
    final members = <String>{...memberPubkeys, selfPubkey}.toList();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final groupNonce = GroupLogic.generateGroupId();
    final groupId = GroupLogic.genesisId(selfPubkey, groupNonce);
    final group = Group(
      id: groupId,
      genesisOwner: selfPubkey,
      genesisNonce: groupNonce,
      name: name.trim(),
      members: members,
      createdBy: selfPubkey,
      avatar: (avatar != null && avatar.isNotEmpty) ? avatar : null,
      banner: (banner != null && banner.isNotEmpty) ? banner : null,
      description:
          (description != null && description.isNotEmpty) ? description : null,
      allowMemberInvites: allowMemberInvites,
      lastMessageTime: DateTime.now().millisecondsSinceEpoch,
      memberAt: {for (final pk in members) pk: nowSec},
      invited: GroupInvited.mark(null, members, nowSec, selfPubkey),
    );

    final eph = keysFor(groupId).ensureSelf();
    _refreshServiceKeys();

    final rumor = GroupLogic.buildGroupInviteRumor(
      group: group,
      selfPubkey: selfPubkey,
      nymMessageId: GroupLogic.generateGroupId(),
      ephemeralPk: eph.pk,
      content: 'You\'ve been added to group "${group.name}".',
      nowSec: nowSec,
    );

    // The first invite uses real pubkeys; no member keys exist yet.
    final sent = await _service.publishGroupMessage(
      rumor: rumor,
      onWrap: _depositFor(rumor),
      recipients: members,
      encryptTo: (pk) => pk,
      settings: settings,
      kemKeyFor: kemKeyFor,
      rootSeededFor: rootSeededFor,
      layeredFor: layeredFor,
    );
    if (sent) noteKeyGiven(groupId, members, eph.pk, (pk) => pk);
    return group;
  }

  /// Rotates the self ephemeral key and gift-wraps to each member; [extraTags] come prebuilt from the caller. Null if unsendable.
  Future<String?> sendGroupMessage({
    required Group group,
    required String selfPubkey,
    required String content,
    List<List<String>> extraTags = const [],
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    if (!_service.canSign) return null;
    final ek = keysFor(group.id);
    final next = ek.rotateSelf();
    _refreshServiceKeys();

    final nymMessageId = GroupLogic.generateGroupId();
    final rumor = GroupLogic.buildGroupMessageRumor(
      group: group,
      selfPubkey: selfPubkey,
      content: content,
      nymMessageId: nymMessageId,
      ephemeralPk: next.pk,
      extraTags: extraTags,
    );
    String to(String pk) => ek.encryptionPubkeyFor(pk, selfPubkey);
    final ok = await _service.publishGroupMessage(
      rumor: rumor,
      onWrap: _depositFor(rumor),
      recipients: group.members,
      encryptTo: to,
      settings: settings,
      kemKeyFor: kemKeyFor,
      rootSeededFor: rootSeededFor,
      layeredFor: layeredFor,
      onCoverage: (pq, total, root) =>
          _recordCoverage(nymMessageId, pq, total, root),
    );
    if (ok) noteKeyGiven(group.id, group.members, next.pk, to);
    return ok ? nymMessageId : null;
  }

  /// Broadcasts owner-issued `group-metadata` to other members; false when there are none. Callers check roles.
  Future<bool> sendMetadata({
    required Group group,
    required String selfPubkey,
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    if (!_service.canSign) return false;
    final others = group.members.where((pk) => pk != selfPubkey).toList();
    if (others.isEmpty) return false;
    final ek = keysFor(group.id);
    final rumor = GroupLogic.buildGroupMetadataRumor(
      group: group,
      selfPubkey: selfPubkey,
      recipients: others,
      nymMessageId: GroupLogic.generateGroupId(),
    );
    return _service.publishGroupMessage(
      rumor: rumor,
      onWrap: _depositFor(rumor),
      recipients: others,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      settings: settings,
      kemKeyFor: kemKeyFor,
      rootSeededFor: rootSeededFor,
      layeredFor: layeredFor,
    );
  }

  /// Sends `group-leave` to remaining members; false when there are none.
  Future<bool> sendLeave({
    required Group group,
    required String selfPubkey,
    required String content,
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    if (!_service.canSign) return false;
    final others = group.members.where((pk) => pk != selfPubkey).toList();
    if (others.isEmpty) return false;
    final ek = keysFor(group.id);
    final rumor = GroupLogic.buildControlRumor(
      group: group,
      selfPubkey: selfPubkey,
      type: GroupControlType.leave,
      extraTags: const [],
      nymMessageId: GroupLogic.generateGroupId(),
      recipients: others,
      content: content,
    );
    return _service.publishGroupMessage(
      rumor: rumor,
      onWrap: _depositFor(rumor),
      recipients: others,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      settings: settings,
      kemKeyFor: kemKeyFor,
      rootSeededFor: rootSeededFor,
      layeredFor: layeredFor,
    );
  }

  /// Announces `group-add-member` to all members; new joiners have no ephemeral key yet, so they get real-pubkey wraps.
  Future<bool> addMembers({
    required Group group,
    required String selfPubkey,
    required String content,
    MessagingSettings settings = const MessagingSettings(),
    int? nowSec,
    List<String> newMembers = const [],
    String? nymMessageId,
  }) async {
    if (!_service.canSign) return false;
    final ek = keysFor(group.id);
    final eph = ek.ensureSelf();
    _refreshServiceKeys();
    final rumor = GroupLogic.buildAddMemberRumor(
      group: group,
      selfPubkey: selfPubkey,
      nymMessageId: nymMessageId ?? GroupLogic.generateGroupId(),
      ephemeralPk: eph.pk,
      content: content,
      nowSec: nowSec,
    );
    String to(String pk) =>
        newMembers.contains(pk) ? pk : ek.encryptionPubkeyFor(pk, selfPubkey);
    final ok = await _service.publishGroupMessage(
      rumor: rumor,
      onWrap: _depositFor(rumor),
      recipients: group.members,
      encryptTo: to,
      newMembers: newMembers,
      settings: settings,
      kemKeyFor: kemKeyFor,
      rootSeededFor: rootSeededFor,
      layeredFor: layeredFor,
    );
    if (ok) noteKeyGiven(group.id, group.members, eph.pk, to);
    return ok;
  }

  /// Key-resync request wrapped to members' real pubkeys, since our stored ephemeral keys are what's suspect.
  Future<bool> sendKeyResyncRequest({
    required Group group,
    required String selfPubkey,
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    if (!_service.canSign) return false;
    final others = group.members.where((pk) => pk != selfPubkey).toList();
    if (others.isEmpty) return false;
    final eph = keysFor(group.id).ensureSelf();
    _refreshServiceKeys();
    final rumor = GroupLogic.buildControlRumor(
      group: group,
      selfPubkey: selfPubkey,
      type: GroupControlType.keyResync,
      extraTags: [
        ['resync_req', '1'],
        ['ephemeral_pk', eph.pk],
      ],
      nymMessageId: GroupLogic.generateGroupId(),
      recipients: others,
    );
    return _service.publishGroupMessage(
      rumor: rumor,
      onWrap: _depositFor(rumor),
      recipients: others,
      encryptTo: (pk) => pk,
      settings: settings,
      kemKeyFor: kemKeyFor,
      rootSeededFor: rootSeededFor,
      layeredFor: layeredFor,
    );
  }

  /// Replies to a resync with our current key, wrapped to the key they advertised; callers rate-limit.
  Future<bool> sendKeyResyncReply({
    required Group group,
    required String selfPubkey,
    required String requesterPubkey,
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    if (!_service.canSign) return false;
    final ek = keysFor(group.id);
    final eph = ek.ensureSelf();
    _refreshServiceKeys();
    final rumor = GroupLogic.buildControlRumor(
      group: group,
      selfPubkey: selfPubkey,
      type: GroupControlType.keyResync,
      extraTags: [
        ['ephemeral_pk', eph.pk],
      ],
      nymMessageId: GroupLogic.generateGroupId(),
      recipients: [requesterPubkey],
    );
    return _service.publishGroupMessage(
      rumor: rumor,
      onWrap: _depositFor(rumor),
      recipients: [requesterPubkey],
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      settings: settings,
      kemKeyFor: kemKeyFor,
      rootSeededFor: rootSeededFor,
      layeredFor: layeredFor,
    );
  }

  /// Sends a control event; callers check roles.
  Future<bool> sendControl({
    required Group group,
    required String selfPubkey,
    required String type,
    required List<List<String>> extraTags,
    List<String>? recipients,
    String content = '',
    String? nymMessageId,
    int? nowSec,
  }) async {
    if (!_service.canSign) return false;
    final ek = keysFor(group.id);
    final rumor = GroupLogic.buildControlRumor(
      group: group,
      selfPubkey: selfPubkey,
      type: type,
      extraTags: extraTags,
      nymMessageId: nymMessageId ?? GroupLogic.generateGroupId(),
      recipients: recipients,
      content: content,
      nowSec: nowSec,
    );
    final to = recipients ?? group.members;
    return _service.publishGroupMessage(
      rumor: rumor,
      onWrap: _depositFor(rumor),
      recipients: to,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      kemKeyFor: kemKeyFor,
      rootSeededFor: rootSeededFor,
      layeredFor: layeredFor,
    );
  }

  Future<bool> sendRumor({
    required Group group,
    required String selfPubkey,
    required UnsignedEvent rumor,
    required List<String> recipients,
    EventSigner? signerOverride,
  }) async {
    if (!_service.canSign || recipients.isEmpty) return false;
    final ek = keysFor(group.id);
    return _service.publishGroupMessage(
      signerOverride: signerOverride,
      rumor: rumor,
      onWrap: _depositFor(rumor),
      recipients: recipients,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      kemKeyFor: kemKeyFor,
      rootSeededFor: rootSeededFor,
      layeredFor: layeredFor,
    );
  }
}
