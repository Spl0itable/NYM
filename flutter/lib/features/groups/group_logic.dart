import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

import '../../core/constants/event_kinds.dart';
import '../../core/crypto/keys.dart';
import '../../models/group.dart';
import '../../models/nostr_event.dart';
import '../pms/pm_logic.dart';

/// Max retained previous ephemeral keys per group (post-compromise recovery).
const int kEphemeralPrevKeysMax = 30;

/// Membership cap: every group message costs one gift wrap per member, so
/// membership is bounded to keep per-message fan-out (encrypt + publish work)
const int kMaxGroupMembers = 100;

const int kPmDepositQueueMax =
    kMaxGroupMembers * 3 > 600 ? kMaxGroupMembers * 3 : 600;

const int kPmDepositFlushMs = 4000;

const int kPmDepositFlushJitterMs = 1500;

const int kPmDepositBacklogMs = 600;

const int kPmDepositBatchMin = 40;

const int kPmDepositBatchMax = 100;

const int kGroupAdmitBackoffMs = 4000;

const int kGroupRosterRepairCooldownMs = 300000;

const int kGroupReactionBatchMs = 1500;

/// Key-resync heartbeat: after being offline this long, our stored view of
/// other members' rotating ephemeral keys may have expired off relays, so we
/// proactively re-exchange current keys (PWA `GROUP_RESYNC_OFFLINE_GAP_SEC`).
const int kGroupResyncOfflineGapSec = 3 * 24 * 60 * 60;

/// Per-group cooldown between key-resync requests (PWA
/// `GROUP_RESYNC_COOLDOWN_SEC`).
const int kGroupResyncCooldownSec = 24 * 60 * 60;

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
    final entry = <String, dynamic>{
      'members': Map<String, String>.from(members)
    };
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
class GroupRoleSpec {
  const GroupRoleSpec({
    required this.tag,
    required this.list,
    required this.grant,
    required this.ownerOnly,
    required this.log,
  });

  final String tag;
  final String list;
  final bool grant;
  final bool ownerOnly;
  final String log;
}

const Map<String, GroupRoleSpec> groupRoleEvents = {
  GroupControlType.promoteAdmin: GroupRoleSpec(
      tag: 'admin',
      list: 'admins',
      grant: true,
      ownerOnly: true,
      log: 'promote-admin'),
  GroupControlType.revokeAdmin: GroupRoleSpec(
      tag: 'admin',
      list: 'admins',
      grant: false,
      ownerOnly: true,
      log: 'revoke-admin'),
  GroupControlType.promoteMod: GroupRoleSpec(
      tag: 'mod', list: 'mods', grant: true, ownerOnly: false, log: 'promote'),
  GroupControlType.revokeMod: GroupRoleSpec(
      tag: 'mod', list: 'mods', grant: false, ownerOnly: false, log: 'revoke'),
};

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
      ['rh', rosterHash(group.id, group.members)],
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

  /// The owner's current group metadata as message tags — the PWA's
  /// `_attachGroupMetaTags` piggyback (groups.js). Appended to outbound group
  /// messages so a member who missed the ephemeral `group-metadata` control
  /// event still converges on the custom name/avatar/banner/description + invite
  /// policy. This is the ONLY carrier that reaches a DIFFERENT member: the
  /// per-account `nymchat-groups` D1 sync restores your OWN devices' group state
  /// but can never cross into another member's account, so in relay-proxy mode a
  /// member who rehydrates the group backlog from the D1 gift-wrap archive gets
  /// the custom avatar solely from these tags on the archived messages (their
  /// absence is the reported "group avatar not coming from D1" symptom). The
  /// inbound side already reads it ([_applyMetadata] via the `meta_ts`
  /// piggyback handler). Only the OWNER attaches it, and only once metadata has
  /// been set (`metaUpdatedAt > 0`); `meta_ts` is the group's real metadata
  /// timestamp so the inbound monotonic guard makes re-application idempotent.
  /// Rides EVERY owner message: the PWA gates on a `GROUP_META_PIGGYBACK_WINDOW`,
  /// but that constant is never actually defined in the PWA source — so
  /// `now - metaTs > undefined` is always false and the window is a dead no-op,
  /// i.e. the PWA piggybacks unconditionally too (owner + metaTs). Tag order
  /// mirrors `_attachGroupMetaTags` (groups.js:2135-2141): meta_ts, banner,
  /// avatar, description, allow_invites, invite_enabled, invite_epoch.
  static List<List<String>> groupMetaPiggybackTags(Group g, String selfPubkey) {
    if (!canAdminister(g, selfPubkey) || g.metaUpdatedAt <= 0) return const [];
    if (g.metaUpdatedBy != null && g.metaUpdatedBy != selfPubkey) return const [];
    return [
      ['meta_ts', '${g.metaUpdatedAt}'],
      ['banner', g.banner ?? ''],
      ['avatar', g.avatar ?? ''],
      ['description', g.description ?? ''],
      ['allow_invites', g.allowMemberInvites ? '1' : '0'],
      ['invite_enabled', g.inviteEnabled ? '1' : '0'],
      ['invite_epoch', '${g.inviteEpoch}'],
      ['share_history', g.shareHistory ? '1' : '0'],
    ];
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
      if (group.genesisOwner != null) ['gowner', group.genesisOwner!],
      if (group.genesisNonce != null) ['gnonce', group.genesisNonce!],
      if (avatar != null && avatar.isNotEmpty) ['avatar', avatar],
      if (banner != null && banner.isNotEmpty) ['banner', banner],
      if (description != null && description.isNotEmpty)
        ['description', description],
      ['allow_invites', group.allowMemberInvites ? '1' : '0'],
      ['invite_enabled', group.inviteEnabled ? '1' : '0'],
      ['invite_epoch', '${group.inviteEpoch}'],
      ['share_history', group.shareHistory ? '1' : '0'],
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
      ['share_history', group.shareHistory ? '1' : '0'],
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
      if (group.genesisOwner != null) ['gowner', group.genesisOwner!],
      if (group.genesisNonce != null) ['gnonce', group.genesisNonce!],
      for (final mod in group.mods) ['mod', mod],
      for (final admin in group.admins) ['admin', admin],
      if (avatar != null && avatar.isNotEmpty) ['avatar', avatar],
      if (banner != null && banner.isNotEmpty) ['banner', banner],
      if (description != null && description.isNotEmpty)
        ['description', description],
      ['allow_invites', group.allowMemberInvites ? '1' : '0'],
      ['invite_enabled', group.inviteEnabled ? '1' : '0'],
      ['invite_epoch', '${group.inviteEpoch}'],
      ['share_history', group.shareHistory ? '1' : '0'],
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
  static bool isAdmin(Group g, String pubkey) => g.admins.contains(pubkey);
  static bool isMod(Group g, String pubkey) => g.mods.contains(pubkey);

  static bool canAdminister(Group g, String pubkey) =>
      isOwner(g, pubkey) || isAdmin(g, pubkey);

  static bool canModerate(Group g, String pubkey) =>
      canAdminister(g, pubkey) || isMod(g, pubkey);

  static bool canAddMembers(Group g, String pubkey) =>
      canModerate(g, pubkey) ||
      (g.members.contains(pubkey) && g.allowMemberInvites);

  static int roleRank(Group g, String pubkey) {
    if (isOwner(g, pubkey)) return 0;
    if (isAdmin(g, pubkey)) return 1;
    if (isMod(g, pubkey)) return 2;
    return 3;
  }

  static bool outranks(Group g, String actor, String target) =>
      roleRank(g, actor) < roleRank(g, target);

  static bool roleEventAuthorized(
      Group g, GroupRoleSpec spec, String actor, String target) {
    if (spec.ownerOnly) return isOwner(g, actor);
    if (!canAdminister(g, actor)) return false;
    if (isOwner(g, target)) return false;
    if (spec.grant && isAdmin(g, target)) return false;
    return isOwner(g, actor) || outranks(g, actor, target) || isMod(g, target);
  }

  static List<List<String>> buildRosterReplyTags(Group g, String requester) {
    return <List<String>>[
      for (final pk in g.members) ['p', pk],
      ['g', g.id],
      if (g.name.isNotEmpty) ['subject', g.name],
      ['type', GroupControlType.roster],
      if (g.createdBy != null) ['owner', g.createdBy!],
      for (final pk in g.admins) ['admin', pk],
      for (final pk in g.mods) ['mod', pk],
      for (final pk in g.banned) ['ban', pk],
    ];
  }

  static bool isBareShell(Group g, String selfPubkey) =>
      (g.createdBy == null || g.createdBy!.isEmpty) &&
      g.members.where((pk) => pk != selfPubkey).isEmpty;

  static bool applyRoster(
      Group g, List<List<String>> tags, String senderPubkey, String selfPubkey) {
    final bootstrap = isBareShell(g, selfPubkey);
    if (!bootstrap && !canModerate(g, senderPubkey)) return false;
    List<String> tagged(String k) => [
          for (final t in tags)
            if (t.length > 1 && t[0] == k) t[1]
        ];
    final members = tagged('p');
    if (members.isEmpty) return false;
    final banned = tagged('ban').toSet();
    final next = members.where((pk) => !banned.contains(pk)).toSet().toList();
    if (!next.contains(selfPubkey)) return false;
    final admins =
        tagged('admin').where((pk) => next.contains(pk)).toSet().toList();
    final mods = tagged('mod')
        .where((pk) => next.contains(pk) && !admins.contains(pk))
        .toSet()
        .toList();
    if (bootstrap) {
      final owner = tagValue(tags, 'owner');
      if (owner != null && owner.isNotEmpty) g.createdBy = owner;
    }
    g.members
      ..clear()
      ..addAll(next);
    g.banned
      ..clear()
      ..addAll(banned);
    g.admins
      ..clear()
      ..addAll(admins);
    g.mods
      ..clear()
      ..addAll(mods);
    return true;
  }

  static String rosterHash(String groupId, Iterable<String> members) {
    final sorted = members.toSet().toList()..sort();
    final digest =
        sha256.convert(utf8.encode('nym-roster-v1:$groupId:${sorted.join(',')}'));
    return hex.encode(digest.bytes.sublist(0, 8));
  }

  static String genesisId(String genesisOwner, String nonceHex) => hex.encode(
      sha256.convert(utf8.encode('nym-group-v1:$genesisOwner:$nonceHex')).bytes);

  static int joinAdmitRank(Group g, String selfPubkey, String joinerPubkey) {
    final candidates =
        g.members.where((pk) => canAddMembers(g, pk)).toList(growable: false);
    if (!candidates.contains(selfPubkey)) return -1;
    String score(String pk) => hex.encode(sha256
        .convert(utf8.encode('${g.id}:$joinerPubkey:$pk'))
        .bytes
        .sublist(0, 8));
    final ordered = candidates.toList()
      ..sort((a, b) {
        final c = score(a).compareTo(score(b));
        return c != 0 ? c : a.compareTo(b);
      });
    return ordered.indexOf(selfPubkey);
  }

  static bool? verifyGenesis(String groupId, String? owner, String? nonce) {
    if (owner == null || nonce == null) return null;
    final hexRe = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
    if (!hexRe.hasMatch(owner) || !hexRe.hasMatch(nonce)) return null;
    return genesisId(owner, nonce) == groupId;
  }

  // ---- stale guard ---------------------------------------------------------

  /// Stable identifier for a moderation rumor, used for exact-replay dedup.
  /// Prefers the shared `x` tag id (identical across every member's wrap),
  /// falling back to the local wrap [eventId].
  static String? modEventKey(List<List<String>> tags, String? eventId) =>
      tagValue(tags, 'x') ?? eventId;

  /// Rejects an out-of-order moderation rumor.
  ///
  /// Moderation events are ordered PER TARGET pubkey, not globally: relays can
  /// deliver distinct mod events out of order (promote A @100 after kick B
  /// @105) and a single global timestamp gate silently drops the older one
  /// even though it was never seen. Exact replays are caught by the seen-id
  /// set. Events without a target ([targetPubkey] null — ownership transfers)
  /// keep the global gate, since authority for later events was already
  /// derived from the current owner.
  static bool isStaleModEvent(Group g, int ts, String? modKey,
      {String? targetPubkey}) {
    if (modKey != null && g.modSeenIds.contains(modKey)) return true;
    if (targetPubkey != null) {
      return ts < (g.modTsByTarget[targetPubkey] ?? 0);
    }
    final last = g.lastModTs;
    if (ts < last) return true;
    if (ts == last && modKey != null && g.lastModEventId == modKey) {
      return true;
    }
    return false;
  }

  /// Records an applied moderation event's ts/id (clamped to now+300s):
  /// seen-id dedup, the target's moderation clock, and the global watermark.
  static void recordModEvent(Group g, int ts, String? modKey,
      {String? targetPubkey}) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final clamped = ts < nowSec + 300 ? ts : nowSec + 300;
    if (modKey != null && !g.modSeenIds.contains(modKey)) {
      g.modSeenIds.add(modKey);
      if (g.modSeenIds.length > 100) {
        g.modSeenIds.removeRange(0, g.modSeenIds.length - 100);
      }
    }
    if (targetPubkey != null) bumpModTargetTs(g, targetPubkey, clamped);
    if (clamped >= g.lastModTs) {
      g.lastModTs = clamped;
      if (modKey != null) g.lastModEventId = modKey;
    }
  }

  /// Advances a target's moderation clock (also used when a member is
  /// re-added, so a replayed pre-re-add kick can't remove them again).
  /// Bounded to the most recent 200 targets.
  static void bumpModTargetTs(Group g, String targetPubkey, int ts) {
    if (targetPubkey.isEmpty) return;
    if (ts >= (g.modTsByTarget[targetPubkey] ?? 0)) {
      g.modTsByTarget[targetPubkey] = ts;
    }
    if (g.modTsByTarget.length > 200) {
      final keys = g.modTsByTarget.keys.toList()
        ..sort((a, b) => g.modTsByTarget[a]!.compareTo(g.modTsByTarget[b]!));
      for (final k in keys.take(g.modTsByTarget.length - 200)) {
        g.modTsByTarget.remove(k);
      }
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
    final modKey = modEventKey(tags, eventId);
    switch (type) {
      case GroupControlType.removeMember:
        final target = tagValue(tags, 'kick');
        if (target == null) return GroupControlResult.invalid;
        if (isStaleModEvent(group, ts, modKey, targetPubkey: target)) {
          return GroupControlResult.stale;
        }
        // A member removing *themselves* is a voluntary leave — always allowed,
        // no role required, and never bans (groups.js `leaveGroup`).
        if (senderPubkey == target) {
          recordModEvent(group, ts, modKey, targetPubkey: target);
          group.members.remove(target);
          group.mods.remove(target);
          group.admins.remove(target);
          _modLog(group, type: 'leave', actor: senderPubkey, target: target);
          return GroupControlResult.applied;
        }
        if (!canModerate(group, senderPubkey)) {
          return GroupControlResult.unauthorized;
        }
        if (!isOwner(group, senderPubkey) &&
            !outranks(group, senderPubkey, target)) {
          return GroupControlResult.unauthorized;
        }
        recordModEvent(group, ts, modKey, targetPubkey: target);
        group.members.remove(target);
        group.mods.remove(target);
        group.admins.remove(target);
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
        if (isStaleModEvent(group, ts, modKey, targetPubkey: target)) {
          return GroupControlResult.stale;
        }
        if (!canModerate(group, senderPubkey)) {
          return GroupControlResult.unauthorized;
        }
        recordModEvent(group, ts, modKey, targetPubkey: target);
        group.banned.remove(target);
        _modLog(group, type: 'unban', actor: senderPubkey, target: target);
        return GroupControlResult.applied;

      case GroupControlType.promoteMod:
      case GroupControlType.revokeMod:
      case GroupControlType.promoteAdmin:
      case GroupControlType.revokeAdmin:
        final spec = groupRoleEvents[type]!;
        final target = tagValue(tags, spec.tag);
        if (target == null) return GroupControlResult.invalid;
        if (isStaleModEvent(group, ts, modKey, targetPubkey: target)) {
          return GroupControlResult.stale;
        }
        if (!roleEventAuthorized(group, spec, senderPubkey, target)) {
          return GroupControlResult.unauthorized;
        }
        recordModEvent(group, ts, modKey, targetPubkey: target);
        final list = spec.list == 'admins' ? group.admins : group.mods;
        if (spec.grant) {
          if (!list.contains(target)) list.add(target);
          if (spec.list == 'admins') group.mods.remove(target);
        } else {
          list.remove(target);
        }
        _modLog(group, type: spec.log, actor: senderPubkey, target: target);
        return GroupControlResult.applied;

      case GroupControlType.transferOwner:
        final newOwner = tagValue(tags, 'owner');
        if (newOwner == null) return GroupControlResult.invalid;
        // Ownership transfers keep GLOBAL ordering (no targetPubkey): later
        // events' authority was already derived from the current owner.
        if (isStaleModEvent(group, ts, modKey)) {
          return GroupControlResult.stale;
        }
        if (!isOwner(group, senderPubkey)) {
          return GroupControlResult.unauthorized;
        }
        recordModEvent(group, ts, modKey);
        final priorOwner = group.createdBy;
        group.createdBy = newOwner;
        group.mods.remove(newOwner);
        group.admins.remove(newOwner);
        if (priorOwner != null &&
            group.members.contains(priorOwner) &&
            !group.admins.contains(priorOwner)) {
          group.admins.add(priorOwner);
        }
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
        // Advance each (re-)added member's moderation clock so a replayed
        // pre-re-add kick arriving later can't remove them again.
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final addTs = ts < nowSec + 300 ? ts : nowSec + 300;
        for (final pk in added) {
          bumpModTargetTs(group, pk, addTs);
        }
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
        _modLog(group,
            type: 'leave', actor: senderPubkey, target: senderPubkey);
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
        if (!canModerate(group, senderPubkey)) {
          return GroupControlResult.unauthorized;
        }
        if (!isOwner(group, senderPubkey) &&
            targetAuthor != null &&
            !outranks(group, senderPubkey, targetAuthor)) {
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
    // A falsy/zero metadata timestamp is rejected, mirroring groups.js
    // `_applyGroupMetadataTags`: `if (!metaTs || metaTs < grp.metaUpdatedAt)`.
    if (ts <= 0) return false;
    var changed = false;
    // BARE-SHELL HEAL: a member who learned this group from a backfilled MESSAGE
    // (relay-proxy / D1 gift-wrap archive) has no known owner — `mergeGroupFromMessage`
    // plants `createdBy: null`. The owner metadata (a `group-metadata` control OR
    // the `meta_ts` piggyback, both attached ONLY by the owner on the wire — see
    // [groupMetaPiggybackTags]) is the sole signal that can establish the owner
    // for such a member, so on a still-ownerless group adopt the sender as owner
    // and let the appearance converge. This is the documented purpose of the
    // piggyback (the "group avatar not coming from D1" symptom): without it a
    // D1-only member's custom avatar/banner stays stuck on the stacked-member
    // default forever. It intentionally diverges from the PWA's strict
    // `createdBy === senderPubkey` reject, which leaves that member broken.
    if (g.createdBy == null || g.createdBy!.isEmpty) {
      g.createdBy = senderPubkey;
      changed = true;
    } else if (!canAdminister(g, senderPubkey)) {
      return false; // owner- or admin-issued only
    }
    if (ts < g.metaUpdatedAt) return changed;
    if (ts == g.metaUpdatedAt &&
        (g.metaUpdatedBy ?? '').compareTo(senderPubkey) > 0) {
      return changed;
    }
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
    final shareHist = tagValue(tags, 'share_history');
    if (shareHist != null) {
      final v = shareHist == '1';
      if (v != g.shareHistory) {
        g.shareHistory = v;
        changed = true;
      }
    }
    if (changed) {
      g.metaUpdatedAt = ts;
      g.metaUpdatedBy = senderPubkey;
    }
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
