import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/bech32_codec.dart' show encodeNpub;
import '../../services/platform/deep_link_target.dart';
import '../../services/platform/deep_links.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/context_menu_panel.dart';
import '../groups/group_invite_confirm.dart';
import 'share_links.dart';
import 'share_preview.dart';

enum InboundSource { scan, photo, nfc, nearby, deepLink }

typedef ProfileOpener = Future<void> Function(
    BuildContext context, String pubkey, String nym, bool isSelf);

class InboundShareHandler {
  InboundShareHandler(this._ref, {ProfileOpener? openProfile})
      : _openProfile = openProfile ?? _defaultOpenProfile;

  final Ref _ref;
  final ProfileOpener _openProfile;

  static Future<void> _defaultOpenProfile(
          BuildContext context, String pubkey, String nym, bool isSelf) =>
      ContextMenuPanel.show(
        context,
        target: CtxTarget(
            pubkey: pubkey, nym: nym, isSelf: isSelf, profileOnly: true),
      );

  DeepLinkTarget _target(BuildContext context) =>
      NostrControllerDeepLinkTarget(
        _ref.read(nostrControllerProvider),
        confirmInvite: (token) => context.mounted
            ? confirmGroupInviteJoin(context, token)
            : Future.value(false),
      );

  Future<ShareParseResult> handle(
    BuildContext context,
    String raw, {
    required InboundSource source,
    String? fromLabel,
  }) async {
    final r = parseShareInput(raw);
    if (!context.mounted) return r;
    switch (r.kind) {
      case ShareParseKind.invalid:
        if (source != InboundSource.nearby &&
            source != InboundSource.deepLink) {
          await showNotNymchatCode(context);
        }
        return r;
      case ShareParseKind.appLink:
        await showAppLinkNotice(context);
        return r;
      case ShareParseKind.profile:
        await openProfilePreview(context, r.pubkey, fromLabel: fromLabel);
        return r;
      case ShareParseKind.channel:
        if (await showChannelSharePreview(context, r, fromLabel: fromLabel) &&
            context.mounted) {
          dispatchNymLink(_channelLink(r), _target(context));
        }
        return r;
      case ShareParseKind.groupInvite:
        final invite = parseGroupInvite(r.token);
        if (invite != null) {
          await confirmAndJoinGroupInvite(_target(context), invite);
        }
        return r;
    }
  }

  Future<bool> openProfilePreview(BuildContext context, String pubkey,
      {String? fromLabel}) async {
    final state = _ref.read(appStateProvider);
    final nym = state.users[pubkey]?.nym ?? '';
    final label = nym.isNotEmpty ? nym : shortNpub(encodeNpub(pubkey));
    final ok = await showProfileSharePreview(context,
        label: label, fromLabel: fromLabel);
    if (!ok || !context.mounted) return false;
    await _openProfile(context, pubkey, nym, pubkey == state.selfPubkey);
    return true;
  }

  NymLink _channelLink(ShareParseResult r) {
    if (r.refPrefix.isNotEmpty) return NymLink.channelRef(r.refPrefix, r.channel);
    return r.geohash ? NymLink.geohash(r.channel) : NymLink.channel(r.channel);
  }
}

final inboundShareProvider =
    Provider<InboundShareHandler>((ref) => InboundShareHandler(ref));
