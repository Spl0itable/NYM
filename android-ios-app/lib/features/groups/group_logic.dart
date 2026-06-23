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
  static UnsignedEvent buildGroupMessageRumor({
    required Group group,
    required String selfPubkey,
    required String content,
    required String nymMessageId,
    required String ephemeralPk,
    int? nowSec,
    int? nowMs,
  }) {
    final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final sec = nowSec ?? (ms ~/ 1000);
    final tags = <List<String>>[
      for (final pk in group.members) ['p', pk],
      ['g', group.id],
      if (group.name.isNotEmpty) ['subject', group.name],
      ['type', GroupControlType.message],
      ['x', nymMessageId],
      ['ephemeral_pk', ephemeralPk],
      ['ms', '$ms'],
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
  static UnsignedEvent buildGroupInviteRumor({
    required Group group,
    required String selfPubkey,
    required String nymMessageId,
    required String ephemeralPk,
    required String content,
    int? nowSec,
  }) {
    final sec = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = <List<String>>[
      for (final pk in group.members) ['p', pk],
      ['g', group.id],
      if (group.name.isNotEmpty) ['subject', group.name],
      ['type', GroupControlType.invite],
      ['owner', selfPubkey],
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
  }) {
    g.modLog.add(ModLogEntry(
      type: type,
      actor: actor,
      target: target,
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
