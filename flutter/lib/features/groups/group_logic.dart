import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

import '../../core/constants/event_kinds.dart';
import '../../core/crypto/keys.dart';
import '../../models/group.dart';
import '../group_tools/group_tools.dart';
import '../../models/nostr_event.dart';
import '../pms/pm_logic.dart';

/// Max retained previous ephemeral keys per group, for post-compromise recovery.
const int kEphemeralPrevKeysMax = 30;

/// Every group message costs one gift wrap per member, so membership is bounded.
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

/// After this long offline, members' stored ephemeral keys may have expired off relays, so re-exchange them.
const int kGroupResyncOfflineGapSec = 3 * 24 * 60 * 60;

/// Per-group cooldown between key-resync requests.
const int kGroupResyncCooldownSec = 24 * 60 * 60;

/// Ephemeral keypair: raw 32-byte sk plus 64-hex x-only pk.
class EphemeralKey {
  EphemeralKey({required this.sk, required this.pk});
  final Uint8List sk;
  final String pk;

  factory EphemeralKey.generate() {
    final sk = generatePrivateKey();
    return EphemeralKey(sk: sk, pk: getPublicKeyHex(sk));
  }

  /// `{sk: <hex>, pk}` for cross-device sync.
  Map<String, dynamic> toJson() => {'sk': bytesToHex(sk), 'pk': pk};

  /// Rebuilds from `{sk: <hex>, pk}`; null when `sk` isn't valid hex.
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

/// Per-group rotating ephemeral key state: self current/prev and members' advertised keys.
class GroupEphemeralKeys {
  EphemeralKey? selfCurrent;
  final List<EphemeralKey> selfPrev = [];

  /// member real pubkey -> advertised ephemeral pubkey.
  final Map<String, String> members = {};

  /// member real pubkey -> advertised key timestamp (out-of-order guard).
  final Map<String, int> memberKeyTs = {};

  EphemeralKey ensureSelf() => selfCurrent ??= EphemeralKey.generate();

  /// Pushes current to prev (cap 30) and generates a fresh current.
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

  /// Ignores stale (older-timestamp) updates.
  void updateMemberKey(String realPubkey, String ephemeralPk, int messageTs) {
    final prevTs = memberKeyTs[realPubkey] ?? 0;
    if (messageTs >= prevTs) {
      members[realPubkey] = ephemeralPk;
      memberKeyTs[realPubkey] = messageTs;
    }
  }

  /// Their advertised ephemeral key if known (our own current for the self-copy), else the real pubkey.
  String encryptionPubkeyFor(String realPubkey, String selfPubkey) {
    if (realPubkey == selfPubkey && selfCurrent != null) {
      return selfCurrent!.pk;
    }
    return members[realPubkey] ?? realPubkey;
  }

  /// Every ephemeral secret key we own, for unwrap candidates.
  List<Uint8List> selfSecretKeys() => [
        if (selfCurrent != null) selfCurrent!.sk,
        for (final k in selfPrev) k.sk,
      ];

  /// `nymchat-keys-<groupId>` sync form, byte-matching the PWA; `memberKeyTs` only when non-empty.
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

  /// Member keys keep the newest advertisement; self keys accumulate across devices.
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
      // No local self: adopt the synced keys wholesale so the synced current decrypts.
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

/// Pure, socket-free group logic: rumors, role checks, control events and the stale guard.
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

  /// Storage key matching `ChatView.group(id)`.
  static String groupStorageKey(String groupId) => 'group-$groupId';

  /// Kind-14 group message rumor advertising [ephemeralPk]; no `type` tag, and [extraTags] follow `ms` in PWA order.
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

  /// Owner metadata as tags on every owner message, the only way other members (e.g. D1-archive rehydrators) converge on it.
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
      ...groupToolsMetaTags(g),
    ];
  }

  static List<List<String>> groupToolsMetaTags(Group g) {
    final slow = GroupTools.normalizeSlowmode(g.slowmode);
    return [
      ['slowmode', '$slow'],
      ['slowmode_since', '${slow > 0 ? g.slowmodeSince : 0}'],
      ['join_approval', g.joinApproval ? '1' : '0'],
    ];
  }

  static bool applyGroupToolsMeta(
      Group g, List<List<String>> tags, int metaTs) {
    var changed = false;
    final slowRaw = tagValue(tags, 'slowmode');
    if (slowRaw != null) {
      final v = GroupTools.normalizeSlowmode(slowRaw);
      final claimed = int.tryParse(tagValue(tags, 'slowmode_since') ?? '') ?? 0;
      final since =
          v > 0 ? ((claimed > 0 && claimed <= metaTs) ? claimed : metaTs) : 0;
      if (v != GroupTools.normalizeSlowmode(g.slowmode) ||
          (v > 0 && since != g.slowmodeSince)) {
        g.slowmode = v;
        g.slowmodeSince = since;
        changed = true;
      }
    }
    final ap = tagValue(tags, 'join_approval');
    if (ap != null) {
      final v = ap == '1';
      if (v != g.joinApproval) {
        g.joinApproval = v;
        changed = true;
      }
    }
    return changed;
  }

  /// Bootstrap `group-invite` rumor; avatar/banner/description only when non-empty, invite-policy tags always.
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

  /// Owner-issued `group-metadata` control rumor; empty values clear fields and [createdAtSec] keeps the monotonic stamp.
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
      ...groupToolsMetaTags(group),
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

  /// `group-add-member` rumor with full metadata, roster and the adder's rotated [ephemeralPk].
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
      ...groupToolsMetaTags(group),
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

  /// Moderation/control rumor of [type] with [extraTags] like `['kick', target]`.
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

  static bool isOwner(Group g, String pubkey) => g.createdBy == pubkey;
  static bool isAdmin(Group g, String pubkey) => g.admins.contains(pubkey);
  static bool isMod(Group g, String pubkey) => g.mods.contains(pubkey);

  static bool isMember(Group g, String pubkey) =>
      pubkey.isNotEmpty &&
      (isOwner(g, pubkey) ||
          isAdmin(g, pubkey) ||
          isMod(g, pubkey) ||
          g.members.contains(pubkey));

  static bool acceptsFromNonMember(String type) =>
      type == GroupControlType.invite ||
      type == GroupControlType.joinRequest ||
      type == GroupControlType.roster;

  static bool mayRewriteInviteIdentity(Group g, String sender,
      {String? claimedOwner, bool? genesis, String? genesisOwner}) {
    if (sender.isEmpty) return false;
    final owner = g.createdBy;
    if (owner != null && owner.isNotEmpty) return owner == sender;
    if (claimedOwner != sender) return false;
    if (genesis == true) return genesisOwner == sender;
    return isMember(g, sender);
  }

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

  /// Dedup id for a moderation rumor: the shared `x` tag, else the local wrap [eventId].
  static String? modEventKey(List<List<String>> tags, String? eventId) =>
      tagValue(tags, 'x') ?? eventId;

  /// Orders moderation per target pubkey so out-of-order relay delivery isn't dropped.
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

  /// Records an applied moderation event (ts clamped to now+300s) for dedup, the target clock and the global watermark.
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

  /// Also used on re-add so a replayed older kick can't remove them again; keeps the latest 200 targets.
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

  /// Log entries are stamped with receive time, not the claimed ts; latest 50 kept.
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

  static String? tagValue(List<List<String>> tags, String name) {
    for (final t in tags) {
      if (t.isNotEmpty && t[0] == name && t.length > 1) return t[1];
    }
    return null;
  }

  static bool _hasTag(List<List<String>> tags, String name, String value) =>
      tags.any((t) => t.length > 1 && t[0] == name && t[1] == value);

  /// Applies a verified control rumor in place with role checks and the stale guard.
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
        // Removing yourself is a voluntary leave: always allowed, never bans.
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
        // Ownership transfers keep global ordering.
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
        // Adder must be owner, or a member when member invites are allowed.
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
        // Advance each re-added member's clock so a replayed older kick can't remove them.
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
        // Self-announced departure: no role needed, never bans, not stale-guarded.
        if (!group.members.contains(senderPubkey)) {
          return GroupControlResult.noop;
        }
        group.members.remove(senderPubkey);
        group.mods.remove(senderPubkey);
        _modLog(group,
            type: 'leave', actor: senderPubkey, target: senderPubkey);
        return GroupControlResult.applied;

      case GroupControlType.deleteMessage:
        // Idempotent per message, so no stale guard or lastModTs bump; the caller removes the message.
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
    // A zero metadata timestamp is rejected.
    if (ts <= 0) return false;
    var changed = false;
    // Ownerless shell from a backfilled message: adopt the owner-only metadata sender as owner (deliberately looser than the PWA).
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
    if (applyGroupToolsMeta(g, tags, ts)) changed = true;
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

  /// Valid but changed nothing (e.g. duplicate add).
  noop,

  /// Rejected as stale or out of order.
  stale,

  /// Rejected: sender lacks the required role.
  unauthorized,

  /// Rejected: missing a required tag.
  invalid,

  /// Not a recognized control type.
  ignored,
}
