import 'dart:typed_data';

import '../../core/constants/event_kinds.dart';
import '../../core/crypto/keys.dart';
import '../../models/group.dart';
import '../../models/nostr_event.dart';
import '../pms/pm_logic.dart';

/// Max retained previous ephemeral keys per group (post-compromise recovery).
const int kEphemeralPrevKeysMax = 30;

/// An ephemeral keypair (raw 32-byte sk + 64-hex x-only pk).
class EphemeralKey {
  EphemeralKey({required this.sk, required this.pk});
  final Uint8List sk;
  final String pk;

  factory EphemeralKey.generate() {
    final sk = generatePrivateKey();
    return EphemeralKey(sk: sk, pk: getPublicKeyHex(sk));
  }

  /// Serializes to `{sk: <hex>, pk}` for cross-device sync, mirroring the PWA's
  /// `{ sk: this._skToHex(k.sk), pk: k.pk }` (groups.js:196-197).
  Map<String, dynamic> toJson() => {'sk': bytesToHex(sk), 'pk': pk};

  /// Rebuilds a key from its `{sk: <hex>, pk}` sync form (`_hexToSk`,
  /// groups.js:209-210). Returns null when the `sk` isn't a valid hex string.
  static EphemeralKey? tryFromJson(Map<String, dynamic> j) {
    final skHex = j['sk'];
    final pk = j['pk'];
    if (skHex is! String || pk is! String) return null;
    try {
      return EphemeralKey(sk: hexToBytes(skHex), pk: pk);
    } catch (_) {
      return null;
    }
  }
}

/// Per-group rotating ephemeral key state. Mirrors the PWA's
/// `groupEphemeralKeys[groupId] = { self:{current,prev[]}, members:{pk→ephPk},
/// _memberKeyTs:{pk→ts} }` (docs/specs/03 §4.3).
class GroupEphemeralKeys {
  EphemeralKey? selfCurrent;
  final List<EphemeralKey> selfPrev = [];

  /// member real pubkey → their advertised ephemeral pubkey.
  final Map<String, String> members = {};

  /// member real pubkey → timestamp of the advertised key (out-of-order guard).
  final Map<String, int> memberKeyTs = {};

  /// Ensures a current self key exists, generating one if needed.
  EphemeralKey ensureSelf() => selfCurrent ??= EphemeralKey.generate();

  /// Rotates the self key: pushes current → prev (cap 30) and generates a fresh
  /// current. Returns the new current key. (docs/specs/03 §4.3)
  EphemeralKey rotateSelf() {
    if (selfCurrent == null) {
      ensureSelf();
    } else {
      selfPrev.insert(0, selfCurrent!);
      if (selfPrev.length > kEphemeralPrevKeysMax) {
        selfPrev.removeRange(kEphemeralPrevKeysMax, selfPrev.length);
      }
    }
    selfCurrent = EphemeralKey.generate();
    return selfCurrent!;
  }

  /// Updates a member's advertised ephemeral pubkey, ignoring stale (older-ts)
  /// updates.
  void updateMemberKey(String realPubkey, String ephemeralPk, int messageTs) {
    final prevTs = memberKeyTs[realPubkey] ?? 0;
    if (messageTs >= prevTs) {
      members[realPubkey] = ephemeralPk;
      memberKeyTs[realPubkey] = messageTs;
    }
  }

  /// The pubkey to encrypt TO for [realPubkey]: their advertised ephemeral key
  /// if known (or our own current key for the self-copy), else the real pubkey.
  String encryptionPubkeyFor(String realPubkey, String selfPubkey) {
    if (realPubkey == selfPubkey && selfCurrent != null) {
      return selfCurrent!.pk;
    }
    return members[realPubkey] ?? realPubkey;
  }

  /// All ephemeral secret keys we own (current + prev), for unwrap candidates.
  List<Uint8List> selfSecretKeys() => [
        if (selfCurrent != null) selfCurrent!.sk,
        for (final k in selfPrev) k.sk,
      ];

  /// Serializes this entry for the `nymchat-keys-<groupId>` cross-device sync
  /// category, byte-matching the PWA's `_serializeEphemeralKeys` (groups.js:191):
  /// `{ members, memberKeyTs?, self?: { current, prev[] } }`. `memberKeyTs` is
  /// only emitted when non-empty (the PWA gates it on `ek._memberKeyTs`).
  Map<String, dynamic> toSyncJson() {
    final entry = <String, dynamic>{'members': Map<String, String>.from(members)};
    if (memberKeyTs.isNotEmpty) {
      entry['memberKeyTs'] = Map<String, int>.from(memberKeyTs);
    }
    if (selfCurrent != null) {
      entry['self'] = {
        'current': selfCurrent!.toJson(),
        'prev': [for (final k in selfPrev) k.toJson()],
      };
    }
    return entry;
  }

  /// Merges a synced ephemeral-key [entry] (as produced by [toSyncJson] on
  /// another device) into this state, mirroring the PWA's `_mergeEphemeralKeys`
  /// (groups.js:221): member keys keep whichever device saw the more recent
  /// advertisement (by `memberKeyTs`); self keys ACCUMULATE across devices
  /// (deduped by pubkey, prev window capped at [kEphemeralPrevKeysMax]) so either
  /// device can decrypt a gift wrap addressed to any of our ephemeral pubkeys.
  /// The local current key is never replaced — a synced current is folded into
  /// prev — so on a fresh device (no local self) the synced current becomes the
  /// current and immediately unwraps live/backfilled group wraps.
  void mergeSyncJson(Map<String, dynamic> entry) {
    final syncedMembers = entry['members'];
    final syncedTs = entry['memberKeyTs'];
    if (syncedMembers is Map) {
      syncedMembers.forEach((realPk, ephPk) {
        if (realPk is! String || ephPk is! String) return;
        final localTs = memberKeyTs[realPk] ?? 0;
        final remoteTs = (syncedTs is Map && syncedTs[realPk] is num)
            ? (syncedTs[realPk] as num).toInt()
            : 0;
        if (!members.containsKey(realPk) || remoteTs > localTs) {
          members[realPk] = ephPk;
          memberKeyTs[realPk] = remoteTs;
        }
      });
    }

    final self = entry['self'];
    if (self is! Map) return;
    final current = self['current'];
    final syncedCurrent = current is Map
        ? EphemeralKey.tryFromJson(current.cast<String, dynamic>())
        : null;
    final syncedPrev = <EphemeralKey>[];
    final prev = self['prev'];
    if (prev is List) {
      for (final k in prev) {
        if (k is! Map) continue;
        final key = EphemeralKey.tryFromJson(k.cast<String, dynamic>());
        if (key != null) syncedPrev.add(key);
      }
    }

    if (selfCurrent == null) {
      // No local self — adopt the synced keys wholesale (PWA `local.self =
      // synced.self`). The synced current becomes our current so it decrypts.
      selfCurrent = syncedCurrent;
      selfPrev
        ..clear()
        ..addAll(syncedPrev);
    } else {
      final known = <String>{selfCurrent!.pk, for (final k in selfPrev) k.pk};
      if (syncedCurrent != null && !known.contains(syncedCurrent.pk)) {
        selfPrev.add(syncedCurrent);
        known.add(syncedCurrent.pk);
      }
      for (final k in syncedPrev) {
        if (!known.contains(k.pk)) {
          selfPrev.add(k);
          known.add(k.pk);
        }
      }
    }
    if (selfPrev.length > kEphemeralPrevKeysMax) {
      selfPrev.removeRange(kEphemeralPrevKeysMax, selfPrev.length);
    }
  }
}

/// Pure, socket-free group logic: rumor construction, role checks, control
/// event application + stale guard. (docs/specs/03 §4)
class GroupLogic {
  GroupLogic._();

  static String generateGroupId() => PmLogic.generateSharedEventId();

  /// AppState storage key for a group thread (`group-<id>`), matching
  /// `ChatView.group(id)`.
  static String groupStorageKey(String groupId) => 'group-$groupId';

  /// Builds the kind-14 group-message rumor with common tags + the rotated
  /// [ephemeralPk] advertisement (docs/specs/03 §4.2). [nymMessageId] is the
  /// shared id across per-member copies.
  ///
  /// A plain group message carries NO `['type', …]` tag — groups.js
  /// `sendGroupMessage` (1686-1707) pushes only `p`/`g`/`subject`/`x`/meta/
  /// `ephemeral_pk`/`ms` (+ optional emoji/imeta/offer); the inbound filter
  /// treats a null `type` as a message (F04-M4).
  ///
  /// [extraTags] threads the optional NIP-30 custom-emoji, NIP-92 imeta, and
  /// `['offer', JSON]` file-offer tags (groups.js 1699-1707) plus the
  /// `_attachGroupMetaTags` meta piggyback (groups.js 1690); they are appended
  /// after `ms`, matching the PWA push order (F04-M5/L4). The caller builds them
  /// from provider/controller state (e.g. `customEmojiTagsForContent`).
  static UnsignedEvent buildGroupMessageRumor({
    required Group group,
    required String selfPubkey,
    required String content,
    required String nymMessageId,
    required String ephemeralPk,
    List<List<String>> extraTags = const [],
    int? nowSec,
    int? nowMs,
  }) {
    final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final sec = nowSec ?? (ms ~/ 1000);
    final tags = <List<String>>[
      for (final pk in group.members) ['p', pk],
      ['g', group.id],
      if (group.name.isNotEmpty) ['subject', group.name],
      ['x', nymMessageId],
      ['ephemeral_pk', ephemeralPk],
      ['ms', '$ms'],
      ...extraTags,
    ];
    return UnsignedEvent(
      pubkey: selfPubkey,
      createdAt: sec,
      kind: EventKind.dmRumor,
      tags: tags,
      content: content,
    );
  }

  /// Builds the bootstrap `group-invite` rumor for a freshly created group.
  ///
  /// The optional metadata tags (`avatar`, `banner`, `description`) are only
  /// emitted when the group carries a non-empty value, byte-matching groups.js
  /// `createGroup` (which pushes each tag only `if (groupAvatar)` etc., 1382-1384)
  /// so the rumor shape stays identical to the PWA. `allow_invites` /
  /// `invite_enabled` / `invite_epoch` are always present.
  static UnsignedEvent buildGroupInviteRumor({
    required Group group,
    required String selfPubkey,
    required String nymMessageId,
    required String ephemeralPk,
    required String content,
    int? nowSec,
  }) {
    final sec = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final avatar = group.avatar;
    final banner = group.banner;
    final description = group.description;
    final tags = <List<String>>[
      for (final pk in group.members) ['p', pk],
      ['g', group.id],
      if (group.name.isNotEmpty) ['subject', group.name],
      ['type', GroupControlType.invite],
      ['owner', selfPubkey],
      if (avatar != null && avatar.isNotEmpty) ['avatar', avatar],
      if (banner != null && banner.isNotEmpty) ['banner', banner],
      if (description != null && description.isNotEmpty)
        ['description', description],
      ['allow_invites', group.allowMemberInvites ? '1' : '0'],
      ['invite_enabled', group.inviteEnabled ? '1' : '0'],
      ['invite_epoch', '${group.inviteEpoch}'],
      ['x', nymMessageId],
      ['ephemeral_pk', ephemeralPk],
    ];
    return UnsignedEvent(
      pubkey: selfPubkey,
      createdAt: sec,
      kind: EventKind.dmRumor,
      tags: tags,
      content: content,
    );
  }

  /// Builds the owner-issued `group-metadata` rumor that propagates the group's
  /// current name/avatar/banner/description + invite policy to the other members
  /// (groups.js `_broadcastGroupMetadata`, 2102). Content is empty (it's a
  /// control event, never a chat bubble). The banner/avatar/description tags are
  /// always present (empty string clears the field, matching the PWA's
  /// `group.banner || ''`). [createdAtSec] is the group's `metaUpdatedAt` so a
  /// redelivered metadata event keeps its monotonic stamp; [recipients] should be
  /// the other members (self is excluded by the caller).
  static UnsignedEvent buildGroupMetadataRumor({
    required Group group,
    required String selfPubkey,
    required List<String> recipients,
    required String nymMessageId,
    int? createdAtSec,
  }) {
    final sec = createdAtSec ??
        (group.metaUpdatedAt > 0
            ? group.metaUpdatedAt
            : DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final tags = <List<String>>[
      for (final pk in recipients) ['p', pk],
      ['g', group.id],
      ['subject', group.name],
      ['type', GroupControlType.metadata],
      ['banner', group.banner ?? ''],
      ['avatar', group.avatar ?? ''],
      ['description', group.description ?? ''],
      ['allow_invites', group.allowMemberInvites ? '1' : '0'],
      ['invite_enabled', group.inviteEnabled ? '1' : '0'],
      ['invite_epoch', '${group.inviteEpoch}'],
      ['x', nymMessageId],
    ];
    return UnsignedEvent(
      pubkey: selfPubkey,
      createdAt: sec,
      kind: EventKind.dmRumor,
      tags: tags,
      content: '',
    );
  }

  /// Builds a `group-add-member` rumor announcing [group]'s (already-updated)
  /// member list, carrying the full group metadata + owner/mod roster + the
  /// adder's rotated [ephemeralPk] so the new members learn the group's
  /// appearance and key state from the first wrap (groups.js `addMemberToGroup`,
  /// 1457). [content] is the "X was added by Y." system line.
  static UnsignedEvent buildAddMemberRumor({
    required Group group,
    required String selfPubkey,
    required String nymMessageId,
    required String ephemeralPk,
    required String content,
    int? nowSec,
  }) {
    final sec = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final avatar = group.avatar;
    final banner = group.banner;
    final description = group.description;
    final owner = group.createdBy;
    final tags = <List<String>>[
      for (final pk in group.members) ['p', pk],
      ['g', group.id],
      if (group.name.isNotEmpty) ['subject', group.name],
      ['type', GroupControlType.addMember],
      if (owner != null && owner.isNotEmpty) ['owner', owner],
      for (final mod in group.mods) ['mod', mod],
      if (avatar != null && avatar.isNotEmpty) ['avatar', avatar],
      if (banner != null && banner.isNotEmpty) ['banner', banner],
      if (description != null && description.isNotEmpty)
        ['description', description],
      ['allow_invites', group.allowMemberInvites ? '1' : '0'],
      ['invite_enabled', group.inviteEnabled ? '1' : '0'],
      ['invite_epoch', '${group.inviteEpoch}'],
      ['x', nymMessageId],
      ['ephemeral_pk', ephemeralPk],
    ];
    return UnsignedEvent(
      pubkey: selfPubkey,
      createdAt: sec,
      kind: EventKind.dmRumor,
      tags: tags,
      content: content,
    );
  }

  /// Builds a moderation/control rumor of [type] with the supplied [extraTags]
  /// (e.g. `['kick', target]`, `['mod', target]`, `['owner', newOwner]`).
  static UnsignedEvent buildControlRumor({
    required Group group,
    required String selfPubkey,
    required String type,
    required List<List<String>> extraTags,
    required String nymMessageId,
    List<String>? recipients,
    String content = '',
    int? nowSec,
  }) {
    final sec = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final to = recipients ?? group.members;
    final tags = <List<String>>[
      for (final pk in to) ['p', pk],
      ['g', group.id],
      if (group.name.isNotEmpty) ['subject', group.name],
      ['type', type],
      ...extraTags,
      ['x', nymMessageId],
    ];
    return UnsignedEvent(
      pubkey: selfPubkey,
      createdAt: sec,
      kind: EventKind.dmRumor,
      tags: tags,
      content: content,
    );
  }

  // ---- role checks ---------------------------------------------------------

  static bool isOwner(Group g, String pubkey) => g.createdBy == pubkey;
  static bool isMod(Group g, String pubkey) => g.mods.contains(pubkey);
  static bool canModerate(Group g, String pubkey) =>
      isOwner(g, pubkey) || isMod(g, pubkey);
  static bool canAddMembers(Group g, String pubkey) =>
      isOwner(g, pubkey) ||
      (g.members.contains(pubkey) && g.allowMemberInvites);

  // ---- stale guard ---------------------------------------------------------

  /// Rejects an out-of-order moderation rumor: `ts < lastModTs`, or equal ts
  /// with the same recorded event id. (docs/specs/03 §4.5)
  static bool isStaleModEvent(Group g, int ts, String? eventId) {
    final last = g.lastModTs;
    if (ts < last) return true;
    if (ts == last && eventId != null && g.lastModEventId == eventId) {
      return true;
    }
    return false;
  }

  /// Records an applied moderation event's ts/id (clamped to now+300s).
  static void recordModEvent(Group g, int ts, String? eventId) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final clamped = ts < nowSec + 300 ? ts : nowSec + 300;
    if (clamped >= g.lastModTs) {
      g.lastModTs = clamped;
      if (eventId != null) g.lastModEventId = eventId;
    }
  }

  /// Appends a moderation-log entry stamped with the wall-clock receive time
  /// (groups.js `_appendModLog`: `{ ...entry, ts: Math.floor(Date.now()/1000) }`
  /// — the log records when the action was applied, not the event's claimed ts),
  /// capped at the most recent 50 entries.
  static void _modLog(
    Group g, {
    required String type,
    required String actor,
    String? target,
    String? messageId,
  }) {
    g.modLog.add(ModLogEntry(
      type: type,
      actor: actor,
      target: target,
      messageId: messageId,
      ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ));
    if (g.modLog.length > 50) {
      g.modLog.removeRange(0, g.modLog.length - 50);
    }
  }

  /// Reads the first value of tag [name] from a parsed rumor's tag list.
  static String? tagValue(List<List<String>> tags, String name) {
    for (final t in tags) {
      if (t.isNotEmpty && t[0] == name && t.length > 1) return t[1];
    }
    return null;
  }

  static bool _hasTag(List<List<String>> tags, String name, String value) =>
      tags.any((t) => t.length > 1 && t[0] == name && t[1] == value);

  /// Applies a verified group control rumor of [type] to [group] in place,
  /// enforcing role checks and the stale-event guard. Returns the outcome.
  ///
  /// Role rules (docs/specs/03 §4.4–§4.5):
  /// - kick/ban: owner or mod; mods cannot act on the owner or other mods.
  /// - unban / promote / revoke / transfer: owner only.
  /// - leave: the sender removes only themselves (no role required).
  /// - delete-message: owner or mod; mods cannot delete the owner's messages.
  static GroupControlResult applyControlEvent({
    required Group group,
    required String type,
    required List<List<String>> tags,
    required String senderPubkey,
    required int ts,
    String? eventId,
    String selfPubkey = '',
  }) {
    switch (type) {
      case GroupControlType.removeMember:
        final target = tagValue(tags, 'kick');
        if (target == null) return GroupControlResult.invalid;
        if (isStaleModEvent(group, ts, eventId)) {
          return GroupControlResult.stale;
        }
        // A member removing *themselves* is a voluntary leave — always allowed,
        // no role required, and never bans (groups.js `leaveGroup`).
        if (senderPubkey == target) {
          recordModEvent(group, ts, eventId);
          group.members.remove(target);
          group.mods.remove(target);
          _modLog(group, type: 'leave', actor: senderPubkey, target: target);
          return GroupControlResult.applied;
        }
        final ownerAct = isOwner(group, senderPubkey);
        final modAct = isMod(group, senderPubkey);
        if (!ownerAct && !modAct) return GroupControlResult.unauthorized;
        if (!ownerAct) {
          // Mods can't kick the owner or other mods.
          if (group.createdBy == target) return GroupControlResult.unauthorized;
          if (group.mods.contains(target)) {
            return GroupControlResult.unauthorized;
          }
        }
        recordModEvent(group, ts, eventId);
        group.members.remove(target);
        group.mods.remove(target);
        final banned = _hasTag(tags, 'ban', '1');
        if (banned && !group.banned.contains(target)) {
          group.banned.add(target);
        }
        _modLog(group,
            type: banned ? 'ban' : 'kick', actor: senderPubkey, target: target);
        return GroupControlResult.applied;

      case GroupControlType.unban:
        final target = tagValue(tags, 'unban');
        if (target == null) return GroupControlResult.invalid;
        if (isStaleModEvent(group, ts, eventId)) {
          return GroupControlResult.stale;
        }
        if (!isOwner(group, senderPubkey)) {
          return GroupControlResult.unauthorized;
        }
        recordModEvent(group, ts, eventId);
        group.banned.remove(target);
        _modLog(group, type: 'unban', actor: senderPubkey, target: target);
        return GroupControlResult.applied;

      case GroupControlType.promoteMod:
        final target = tagValue(tags, 'mod');
        if (target == null) return GroupControlResult.invalid;
        if (isStaleModEvent(group, ts, eventId)) {
          return GroupControlResult.stale;
        }
        if (!isOwner(group, senderPubkey)) {
          return GroupControlResult.unauthorized;
        }
        recordModEvent(group, ts, eventId);
        if (!group.mods.contains(target)) group.mods.add(target);
        _modLog(group, type: 'promote', actor: senderPubkey, target: target);
        return GroupControlResult.applied;

      case GroupControlType.revokeMod:
        final target = tagValue(tags, 'mod');
        if (target == null) return GroupControlResult.invalid;
        if (isStaleModEvent(group, ts, eventId)) {
          return GroupControlResult.stale;
        }
        if (!isOwner(group, senderPubkey)) {
          return GroupControlResult.unauthorized;
        }
        recordModEvent(group, ts, eventId);
        group.mods.remove(target);
        _modLog(group, type: 'revoke', actor: senderPubkey, target: target);
        return GroupControlResult.applied;

      case GroupControlType.transferOwner:
        final newOwner = tagValue(tags, 'owner');
        if (newOwner == null) return GroupControlResult.invalid;
        if (isStaleModEvent(group, ts, eventId)) {
          return GroupControlResult.stale;
        }
        if (!isOwner(group, senderPubkey)) {
          return GroupControlResult.unauthorized;
        }
        recordModEvent(group, ts, eventId);
        group.createdBy = newOwner;
        group.mods.remove(newOwner);
        _modLog(group, type: 'transfer', actor: senderPubkey, target: newOwner);
        return GroupControlResult.applied;

      case GroupControlType.addMember:
        // Adder must be owner, or a member when member-invites are allowed.
        if (!canAddMembers(group, senderPubkey)) {
          return GroupControlResult.unauthorized;
        }
        final added = <String>[];
        for (final t in tags) {
          if (t.isNotEmpty && t[0] == 'p' && t.length > 1) {
            final pk = t[1];
            if (!group.members.contains(pk)) {
              group.members.add(pk);
              added.add(pk);
            }
            // Re-admitting a banned user clears the ban (owner/mod only).
            if (group.banned.contains(pk) && canModerate(group, senderPubkey)) {
              group.banned.remove(pk);
            }
          }
        }
        if (added.isEmpty) return GroupControlResult.noop;
        return GroupControlResult.applied;

      case GroupControlType.metadata:
        return _applyMetadata(group, tags, senderPubkey, ts)
            ? GroupControlResult.applied
            : GroupControlResult.noop;

      case GroupControlType.leave:
        // A member announcing their own departure (groups.js:765-781). No role
        // required and never bans; the sender removes only themselves. The PWA
        // doesn't stale-guard a leave, so neither do we.
        if (!group.members.contains(senderPubkey)) {
          return GroupControlResult.noop;
        }
        group.members.remove(senderPubkey);
        group.mods.remove(senderPubkey);
        _modLog(group, type: 'leave', actor: senderPubkey, target: senderPubkey);
        return GroupControlResult.applied;

      case GroupControlType.deleteMessage:
        // Owner/mod deletes another member's message (groups.js:1171-1197). The
        // target message id lives in the `e` tag, the original author in
        // `target_pubkey`. Per-message + idempotent, so the PWA applies NO
        // stale-mod-event guard and does NOT advance lastModTs. Returns
        // `applied` when authorized; the actual message removal is performed by
        // the caller (app_state `applyGroupControl`, which owns the message
        // store) by reading the `e` tag and calling `removeMessage`.
        final targetMessageId = tagValue(tags, 'e');
        if (targetMessageId == null) return GroupControlResult.invalid;
        final targetAuthor = tagValue(tags, 'target_pubkey');
        final isOwnerSender = isOwner(group, senderPubkey);
        final isModSender = isMod(group, senderPubkey);
        if (!isOwnerSender && !isModSender) {
          return GroupControlResult.unauthorized;
        }
        // Mods can't delete the owner's messages.
        if (!isOwnerSender &&
            targetAuthor != null &&
            group.createdBy == targetAuthor) {
          return GroupControlResult.unauthorized;
        }
        _modLog(
          group,
          type: 'delete-message',
          actor: senderPubkey,
          target: targetAuthor,
          messageId: targetMessageId,
        );
        return GroupControlResult.applied;

      default:
        return GroupControlResult.ignored;
    }
  }

  static bool _applyMetadata(
      Group g, List<List<String>> tags, String senderPubkey, int ts) {
    if (g.createdBy != senderPubkey) return false; // owner-issued only
    // A falsy/zero metadata timestamp is rejected, mirroring groups.js
    // `_applyGroupMetadataTags`: `if (!metaTs || metaTs < grp.metaUpdatedAt)`.
    if (ts <= 0) return false;
    if (ts < g.metaUpdatedAt) return false;
    var changed = false;
    final subject = tagValue(tags, 'subject');
    if (subject != null && subject.isNotEmpty && subject != g.name) {
      g.name = subject;
      changed = true;
    }
    final avatar = tagValue(tags, 'avatar');
    if (avatar != null && avatar != (g.avatar ?? '')) {
      g.avatar = avatar.isEmpty ? null : avatar;
      changed = true;
    }
    final banner = tagValue(tags, 'banner');
    if (banner != null && banner != (g.banner ?? '')) {
      g.banner = banner.isEmpty ? null : banner;
      changed = true;
    }
    final desc = tagValue(tags, 'description');
    if (desc != null && desc != (g.description ?? '')) {
      g.description = desc.isEmpty ? null : desc;
      changed = true;
    }
    final allow = tagValue(tags, 'allow_invites');
    if (allow != null) {
      final v = allow != '0';
      if (v != g.allowMemberInvites) {
        g.allowMemberInvites = v;
        changed = true;
      }
    }
    final inviteEnabled = tagValue(tags, 'invite_enabled');
    if (inviteEnabled != null) {
      final v = inviteEnabled == '1';
      if (v != g.inviteEnabled) {
        g.inviteEnabled = v;
        changed = true;
      }
    }
    final epoch = tagValue(tags, 'invite_epoch');
    if (epoch != null) {
      final v = int.tryParse(epoch) ?? 0;
      if (v != g.inviteEpoch) {
        g.inviteEpoch = v;
        changed = true;
      }
    }
    if (changed) g.metaUpdatedAt = ts;
    return changed;
  }
}

/// Outcome of applying a group control event.
enum GroupControlResult {
  /// Applied and mutated the group.
  applied,

  /// Valid but produced no change (e.g. duplicate add).
  noop,

  /// Rejected: stale / out-of-order.
  stale,

  /// Rejected: sender lacks the required role.
  unauthorized,

  /// Rejected: malformed (missing required tag).
  invalid,

  /// Not a recognized control type.
  ignored,
}
