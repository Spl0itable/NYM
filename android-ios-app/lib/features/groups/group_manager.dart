import 'dart:typed_data';

import '../../models/group.dart';
import '../../services/nostr/nostr_service.dart';
import 'group_logic.dart';

/// Holds per-group rotating ephemeral key state and drives the gift-wrapped
/// group send / control paths via [NostrService]. Pure-ish: all crypto is
/// delegated to the service; this class owns the key bookkeeping
/// (docs/specs/03 §4.3).
class GroupManager {
  GroupManager(this._service);

  final NostrService _service;

  /// groupId → rotating ephemeral key state.
  final Map<String, GroupEphemeralKeys> _keys = {};

  GroupEphemeralKeys keysFor(String groupId) =>
      _keys.putIfAbsent(groupId, GroupEphemeralKeys.new);

  /// All registered ephemeral secret keys (current + previous) across groups,
  /// for the service's unwrap candidates / `#p` subscriptions.
  List<Uint8List> allEphemeralSecretKeys() {
    final out = <Uint8List>[];
    for (final ek in _keys.values) {
      out.addAll(ek.selfSecretKeys());
    }
    return out;
  }

  /// All advertised self ephemeral pubkeys (current + prev) for `#p` subs.
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

  void _refreshServiceKeys() {
    _service.setEphemeralKeys(allEphemeralSecretKeys());
  }

  /// Records a peer member's advertised ephemeral pubkey (out-of-order guarded).
  void recordMemberKey(
      String groupId, String memberPubkey, String ephemeralPk, int messageTs) {
    keysFor(groupId).updateMemberKey(memberPubkey, ephemeralPk, messageTs);
  }

  /// Creates a group: generates the id + first ephemeral key, returns a [Group]
  /// owned by [selfPubkey] and publishes the bootstrap `group-invite`.
  Future<Group?> createGroup({
    required String selfPubkey,
    required String name,
    required List<String> memberPubkeys,
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    if (!_service.canSign) return null;
    final members = <String>{...memberPubkeys, selfPubkey}.toList();
    final groupId = GroupLogic.generateGroupId();
    final group = Group(
      id: groupId,
      name: name.trim(),
      members: members,
      createdBy: selfPubkey,
      lastMessageTime: DateTime.now().millisecondsSinceEpoch,
    );

    final eph = keysFor(groupId).ensureSelf();
    _refreshServiceKeys();

    final rumor = GroupLogic.buildGroupInviteRumor(
      group: group,
      selfPubkey: selfPubkey,
      nymMessageId: GroupLogic.generateGroupId(),
      ephemeralPk: eph.pk,
      content: 'You\'ve been added to group "${group.name}".',
    );

    // First invite always uses real pubkeys (no member keys established yet).
    await _service.publishGroupMessage(
      rumor: rumor,
      recipients: members,
      encryptTo: (pk) => pk,
      settings: settings,
    );
    return group;
  }

  /// Sends a group message: rotates the self ephemeral key, builds the rumor
  /// advertising the new key, and gift-wraps to each member's encryption key.
  /// Returns the shared nymMessageId, or null if we can't send.
  Future<String?> sendGroupMessage({
    required Group group,
    required String selfPubkey,
    required String content,
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
    );
    final ok = await _service.publishGroupMessage(
      rumor: rumor,
      recipients: group.members,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      settings: settings,
    );
    return ok ? nymMessageId : null;
  }

  /// Sends a control event of [type] with [extraTags] (role checks are the
  /// caller's responsibility — see [GroupLogic.canModerate]).
  Future<bool> sendControl({
    required Group group,
    required String selfPubkey,
    required String type,
    required List<List<String>> extraTags,
    List<String>? recipients,
    String content = '',
  }) async {
    if (!_service.canSign) return false;
    final ek = keysFor(group.id);
    final rumor = GroupLogic.buildControlRumor(
      group: group,
      selfPubkey: selfPubkey,
      type: type,
      extraTags: extraTags,
      nymMessageId: GroupLogic.generateGroupId(),
      recipients: recipients,
      content: content,
    );
    final to = recipients ?? group.members;
    return _service.publishGroupMessage(
      rumor: rumor,
      recipients: to,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
    );
  }
}
