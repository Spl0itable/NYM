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

  /// Serialized per-group ephemeral key state for the `nymchat-keys-<gid>`
  /// cross-device sync categories (`gid → _serializeEphemeralKeys(ek)`, the map
  /// the PWA iterates in `_publishEncryptedSettings`, settings.js:435-461).
  Map<String, Map<String, dynamic>> ephemeralKeysForSync() {
    final out = <String, Map<String, dynamic>>{};
    _keys.forEach((groupId, ek) => out[groupId] = ek.toSyncJson());
    return out;
  }

  /// Merges a synced ephemeral-key [entry] for [groupId] into the local state
  /// (cross-device restore; `_mergeEphemeralKeys`, groups.js:221). Creates the
  /// per-group entry if absent, then accumulates the synced keys. Returns true
  /// when at least one previously-unknown self ephemeral pubkey was added — the
  /// controller uses this to know it must re-arm decryption / backfill history.
  bool mergeEphemeralKeys(String groupId, Map<String, dynamic> entry) {
    final ek = keysFor(groupId);
    final before = _selfPkCount(ek);
    ek.mergeSyncJson(entry);
    return _selfPkCount(ek) > before;
  }

  int _selfPkCount(GroupEphemeralKeys ek) =>
      (ek.selfCurrent != null ? 1 : 0) + ek.selfPrev.length;

  /// Records a peer member's advertised ephemeral pubkey (out-of-order guarded).
  void recordMemberKey(
      String groupId, String memberPubkey, String ephemeralPk, int messageTs) {
    keysFor(groupId).updateMemberKey(memberPubkey, ephemeralPk, messageTs);
  }

  /// Creates a group: generates the id + first ephemeral key, returns a [Group]
  /// owned by [selfPubkey] and publishes the bootstrap `group-invite`.
  ///
  /// The optional [avatar] / [banner] / [description] / [allowMemberInvites]
  /// extras mirror groups.js `createGroup(name, memberPubkeys, opts)` (1355):
  /// they are stamped onto the [Group] and threaded into the invite rumor's
  /// metadata tags so members learn the group's appearance + invite policy from
  /// the first wrap. [allowMemberInvites] defaults to true (PWA
  /// `opts.allowMemberInvites !== false`).
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
    final groupId = GroupLogic.generateGroupId();
    final group = Group(
      id: groupId,
      name: name.trim(),
      members: members,
      createdBy: selfPubkey,
      avatar: (avatar != null && avatar.isNotEmpty) ? avatar : null,
      banner: (banner != null && banner.isNotEmpty) ? banner : null,
      description:
          (description != null && description.isNotEmpty) ? description : null,
      allowMemberInvites: allowMemberInvites,
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
  ///
  /// [extraTags] threads the optional NIP-30 custom-emoji, NIP-92 imeta, and
  /// `['offer', JSON]` file-offer tags that groups.js `sendGroupMessage`
  /// (1699-1707) pushes after `ms`. They are forwarded verbatim into
  /// [GroupLogic.buildGroupMessageRumor], mirroring the channel send path where
  /// the caller supplies the already-built tag list (`publishChannelMessage`'s
  /// `emojiTags`). The caller owns the provider state needed to build them
  /// (`LiveCustomEmojiNotifier.emojiTagsForContent`, the imeta builder, and
  /// `fileOfferTag`), so the manager stays free of provider lookups (F04-M5).
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
    final ok = await _service.publishGroupMessage(
      rumor: rumor,
      recipients: group.members,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      settings: settings,
    );
    return ok ? nymMessageId : null;
  }

  /// Broadcasts the owner-issued `group-metadata` control to the other members
  /// (self excluded; groups.js `_broadcastGroupMetadata`). The group must already
  /// carry the updated metadata + `metaUpdatedAt`. No-op (returns false) when
  /// there are no other members. Role checks are the caller's responsibility
  /// (owner-only).
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
      recipients: others,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      settings: settings,
    );
  }

  /// Sends the NIP-17 `group-leave` notification to the remaining members
  /// (self excluded; groups.js `leaveGroup`). No-op (returns false) when there
  /// are no other members. [content] is the "{nym} left the group." line.
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
      recipients: others,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      settings: settings,
    );
  }

  /// Announces a `group-add-member` to every member of [group] (the [group]'s
  /// `members` list must already include the new pubkeys; groups.js
  /// `addMemberToGroup`). Advertises the self ephemeral key (current, not
  /// rotated) so existing members and the new joiners learn it. [content] is the
  /// "{nym} was added by {nym}." line. Newly-added members have no ephemeral key
  /// yet, so their wrap targets their real pubkey via [encryptionPubkeyFor].
  Future<bool> addMembers({
    required Group group,
    required String selfPubkey,
    required String content,
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    if (!_service.canSign) return false;
    final ek = keysFor(group.id);
    final eph = ek.ensureSelf();
    _refreshServiceKeys();
    final rumor = GroupLogic.buildAddMemberRumor(
      group: group,
      selfPubkey: selfPubkey,
      nymMessageId: GroupLogic.generateGroupId(),
      ephemeralPk: eph.pk,
      content: content,
    );
    return _service.publishGroupMessage(
      rumor: rumor,
      recipients: group.members,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, selfPubkey),
      settings: settings,
    );
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
