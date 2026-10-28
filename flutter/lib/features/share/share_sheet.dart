import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/nym_icons.dart';
import '../group_tools/group_tools_providers.dart';
import '../i18n/i18n.dart';
import '../identity/modal_chrome.dart';
import 'branded_qr.dart';
import 'share_actions.dart';
import 'share_target.dart';

typedef LiveShareTarget = ShareTarget? Function(WidgetRef ref);

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

ShareTarget? ownProfileShareTarget(WidgetRef ref) {
  final me = ref.watch(appStateProvider.select((s) => (s.selfPubkey, s.selfNym)));
  final pubkey = me.$1.toLowerCase();
  if (!_hex64.hasMatch(pubkey)) return null;
  return ShareTarget.profile(
    pubkey: pubkey,
    displayName: '${me.$2}#${getPubkeySuffix(pubkey)}',
    isOwnProfile: true,
  );
}

ShareTarget? groupShareTarget(WidgetRef ref, String groupId) {
  final key = ref.watch(appStateProvider.select((s) {
    for (final g in s.groups) {
      if (g.id == groupId) {
        return (
          s.selfPubkey,
          g.inviteEnabled,
          g.inviteEpoch,
          g.members.length,
          g.name,
          g.canAddMembers(s.selfPubkey),
        );
      }
    }
    return null;
  }));
  if (key == null) return null;
  final group =
      ref.read(appStateProvider).groups.firstWhere((g) => g.id == groupId);
  return ShareTarget.group(
    group: group,
    self: key.$1,
    summary: ref.read(groupToolsProvider).cachedSummary(groupId),
  );
}

class ShareSheet {
  const ShareSheet._();

  static Color _barrier(BuildContext context) {
    final solidUi =
        ProviderScope.containerOf(context).read(settingsProvider).solidUi;
    final isLight = context.nym.isLight;
    return !solidUi
        ? Colors.black.withValues(alpha: 0.7)
        : isLight
            ? const Color(0x73000000)
            : const Color(0xBF000000);
  }

  static Future<void> show(BuildContext context, Widget body) =>
      showNymSheet<void>(context, (_) => body, barrierColor: _barrier(context));

  static Future<void> open(BuildContext context, ShareTarget target,
          {LiveShareTarget? live}) =>
      show(context, ShareSheetBody(target: target, live: live));

  static Future<void> openChannel(BuildContext context, String channel) =>
      open(context, ShareTarget.channel(channel));

  static Future<void> openProfile(BuildContext context,
          {required String pubkey, required String displayName}) =>
      open(context,
          ShareTarget.profile(pubkey: pubkey, displayName: displayName));

  static Future<void> openOwnProfile(BuildContext context) {
    final ref = ProviderScope.containerOf(context);
    final s = ref.read(appStateProvider);
    final pubkey = s.selfPubkey.toLowerCase();
    if (!_hex64.hasMatch(pubkey)) return Future.value();
    return open(
      context,
      ShareTarget.profile(
        pubkey: pubkey,
        displayName: '${s.selfNym}#${getPubkeySuffix(pubkey)}',
        isOwnProfile: true,
      ),
      live: ownProfileShareTarget,
    );
  }

  static Future<void> openGroup(BuildContext context, String groupId) {
    final ref = ProviderScope.containerOf(context);
    final s = ref.read(appStateProvider);
    final matches = s.groups.where((g) => g.id == groupId);
    if (matches.isEmpty) return Future.value();
    return open(
      context,
      ShareTarget.group(
        group: matches.first,
        self: s.selfPubkey,
        summary: ref.read(groupToolsProvider).cachedSummary(groupId),
      ),
      live: (r) => groupShareTarget(r, groupId),
    );
  }
}

class ShareSheetBody extends ConsumerWidget {
  const ShareSheetBody({super.key, required this.target, this.live});

  final ShareTarget target;
  final LiveShareTarget? live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final t = live?.call(ref) ?? target;
    final actions = t.hasCode
        ? [
            for (final a in ref.watch(shareActionsProvider))
              if (a.isAvailable(ref, t)) a,
          ]
        : const <ShareAction>[];
    final launcher =
        t.isOwnProfile && t.hasCode ? ref.watch(appShareLauncherProvider) : null;
    void close() => Navigator.of(context).maybePop();

    final content = <Widget>[
      if (!t.hasCode) ...[
        Text(
          t.refusal ?? '',
          key: const ValueKey('share-refusal'),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.text, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [ModalChrome.iconButton(c, tr('Close'), close)],
        ),
      ] else ...[
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Color(0xFFFFFFFF),
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            child: BrandedQr(
              data: t.codeLink,
              semanticLabel: tr('QR code for {title}', {'title': t.title}),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          t.title,
          key: const ValueKey('share-title'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: c.text, fontSize: 15, fontWeight: FontWeight.w600),
        ),
        if (t.subtitle.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            t.subtitle,
            key: const ValueKey('share-subtitle'),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: t.kind == ShareKind.group ? c.warning : c.textDim,
                fontSize: 12,
                height: 1.35),
          ),
        ],
        if (t.kind == ShareKind.group) ...[
          const SizedBox(height: 4),
          Text(
            tr('Reset the invite link in group settings to stop old codes and stickers.'),
            key: const ValueKey('share-reset-hint'),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: 11, height: 1.35),
          ),
        ],
        const SizedBox(height: 16),
        _LinkRow(link: t.link),
        const SizedBox(height: 12),
        for (final a in actions)
          ShareActionRow(
            key: ValueKey('share-action-${a.id}'),
            svg: a.icon,
            label: tr(a.label),
            onTap: () => unawaited(a.run(context, ref, t)),
          ),
        if (launcher != null)
          ShareActionRow(
            key: const ValueKey('share-action-app'),
            svg: NymIcons.shareNodes,
            label: tr('Share Nymchat app'),
            onTap: () => unawaited(launcher(context)),
          ),
      ],
    ];

    final body = Stack(
      children: [
        ModalChrome.box(
          c,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ModalChrome.header(c, t.header),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: content,
                ),
              ),
            ],
          ),
        ),
        ModalChrome.closeChip(c, close),
      ],
    );
    return nymSheetOr(
      context,
      SingleChildScrollView(child: body),
      (body) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 820),
          child: SingleChildScrollView(child: body),
        ),
      ),
    );
  }
}

class _LinkRow extends StatefulWidget {
  const _LinkRow({required this.link});
  final String link;

  @override
  State<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends State<_LinkRow> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.link));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color:
                    c.isLight ? const Color(0x0A000000) : const Color(0x0DFFFFFF),
                border: Border.all(
                    color: c.isLight ? const Color(0x1A000000) : c.glassBorder),
                borderRadius: NymRadius.rsm,
              ),
              child: Text(
                widget.link,
                key: const ValueKey('share-link'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: c.text, fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Semantics(
            button: true,
            label: tr('Copy'),
            child: InkWell(
              key: const ValueKey('share-copy'),
              onTap: _copy,
              borderRadius: NymRadius.rsm,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.primaryA(_copied ? 0.2 : 0.1),
                  borderRadius: NymRadius.rsm,
                  border: Border.all(color: c.primaryA(_copied ? 0.5 : 0.3)),
                ),
                child: Text(
                  _copied ? tr('COPIED!') : tr('COPY'),
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ShareActionRow extends StatelessWidget {
  const ShareActionRow({
    super.key,
    required this.svg,
    required this.label,
    required this.onTap,
  });

  final String svg;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rsm,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                NymSvgIcon(svg, size: 20, color: c.primary),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(label,
                      style: TextStyle(color: c.text, fontSize: 14)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
