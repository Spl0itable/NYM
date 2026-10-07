import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/bech32_codec.dart' show encodeNsecBytes;
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../core/utils/secret_screen.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../identity/modal_chrome.dart';
import '../toasts/toast_center.dart';
import 'account_host.dart';
import 'account_logic.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_tooltip.dart';

String accountMethodLabel(String method) {
  switch (method) {
    case 'nsec':
      return 'nsec';
    case 'extension':
      return tr('Extension (NIP-07)');
    case 'nip46':
      return tr('Bunker (NIP-46)');
    case 'anonymous':
      return tr('Anonymous');
    case 'ephemeral':
      return tr('Ephemeral');
  }
  return tr('Setting up');
}

String accountDisplayName(AccountEntry a) {
  if (a.pubkey.isEmpty) return tr('New identity');
  return getNymFromPubkey(a.nym.isEmpty ? 'nym' : a.nym, a.pubkey);
}

class AccountSwitchButton extends ConsumerStatefulWidget {
  const AccountSwitchButton({super.key});

  @override
  ConsumerState<AccountSwitchButton> createState() =>
      _AccountSwitchButtonState();
}

class _AccountSwitchButtonState extends ConsumerState<AccountSwitchButton> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(accountsProvider);
    if (api == null) return const SizedBox.shrink();
    final c = context.nym;
    final lit = _hover || _focus;
    final fg = lit ? c.primary : c.textDim;
    final label = tr('Manage Identities');
    final row = InkWell(
      key: const ValueKey('accountSwitchBtn'),
      borderRadius: NymRadius.rsm,
      onTap: () => showAccountSwitcher(context),
      onHover: (v) => setState(() => _hover = v),
      onFocusChange: (v) => setState(() => _focus = v),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: lit
              ? (c.isLight
                  ? Colors.black.withValues(alpha: 0.05)
                  : c.primaryA(0.1))
              : Colors.transparent,
          borderRadius: NymRadius.rsm,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            NymSvgIcon(NymIcons.accountSwitch, size: 18, color: fg),
            ValueListenableBuilder<AccountIndex>(
              valueListenable: api.changes,
              builder: (context, index, _) {
                final unread = index.accounts
                    .any((a) => a.id != index.active && a.unread > 0);
                if (!unread) return const SizedBox.shrink();
                return Positioned(
                  top: -7,
                  right: -7,
                  child: Container(
                    key: const ValueKey('accountSwitchUnreadDot'),
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: c.danger,
                      shape: BoxShape.circle,
                      border: Border.all(color: c.bg, width: 2),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
    return Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: () => showAccountSwitcher(context),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            NymTooltip(message: label, child: row),
            if (_focus && FocusManager.instance.highlightMode ==
                FocusHighlightMode.traditional)
              Positioned(
                left: -3,
                top: -3,
                right: -3,
                bottom: -3,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: c.secondary, width: 2),
                      borderRadius: NymRadius.rsm,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> showAccountSwitcher(BuildContext context) {
  return showNymSheet<void>(context, (ctx) {
    final panel = AccountSwitcherPanel(sheet: NymSheetScope.of(ctx));
    return nymSheetOr(
      ctx,
      panel,
      (panel) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ModalChrome.box(ctx.nym, child: panel),
        ),
      ),
    );
  });
}

class AccountSwitcherPanel extends ConsumerStatefulWidget {
  const AccountSwitcherPanel({super.key, required this.sheet});

  final bool sheet;

  @override
  ConsumerState<AccountSwitcherPanel> createState() =>
      _AccountSwitcherPanelState();
}

class _AccountSwitcherPanelState extends ConsumerState<AccountSwitcherPanel> {
  AccountsController? _api;

  @override
  void initState() {
    super.initState();
    _api = ref.read(accountsProvider);
  }

  void _close() {
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  Future<void> _switch(AccountEntry a) async {
    final api = _api;
    if (api == null) return;
    _close();
    await api.switchTo(a.id);
  }

  Future<void> _add() async {
    final api = _api;
    if (api == null) return;
    if (api.changes.value.accounts.length >= AccountLogic.maxAccounts) {
      showToast(tr(
          'You can keep up to {n} identities on this device. Remove one to add '
          'another.',
          {'n': AccountLogic.maxAccounts}));
      return;
    }
    _close();
    final err = await api.add();
    if (err == 'pending') {
      showToast(tr('Finish setting up the new identity first.'));
    } else if (err == 'cap') {
      showToast(tr(
          'You can keep up to {n} identities on this device. Remove one to add '
          'another.',
          {'n': AccountLogic.maxAccounts}));
    }
  }

  Future<String?> _nsecFor(AccountEntry a) async {
    final api = _api;
    if (api == null) return null;
    if (a.id == api.changes.value.active) {
      try {
        final sk = ref.read(nostrControllerProvider).identity?.privkey;
        if (sk != null) return encodeNsecBytes(sk);
      } catch (_) {}
    }
    return api.storedNsec(a.id);
  }

  Future<void> _remove(AccountEntry a) async {
    final api = _api;
    if (api == null) return;
    final nsec = await _nsecFor(a);
    if (!mounted) return;
    final index = api.changes.value;
    final next = a.id == index.active
        ? AccountLogic.plan(index, RemoveAccountOp(a.id)).index.activeAccount
        : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _RemoveAccountDialog(
        name: accountDisplayName(a),
        nsec: nsec,
        signerHeld: a.method == 'nip46' || a.method == 'extension',
        next: next == null ? null : accountDisplayName(next),
      ),
    );
    if (ok != true) return;
    final active = a.id == api.changes.value.active;
    if (active && mounted) _close();
    await api.remove(a.id);
  }

  Future<void> _logoutAll() async {
    final api = _api;
    if (api == null) return;
    final ok = await showAppConfirm(
      context,
      tr('Log out of all {n} identities? Every identity and its data on this '
          'device is deleted. Back up any nsec you need first.',
          {'n': api.changes.value.accounts.length}),
      title: tr('Log out of all identities'),
      okLabel: tr('Log out of all identities'),
      danger: true,
    );
    if (!ok || !mounted) return;
    _close();
    await api.logoutAll();
  }

  Future<void> _toggleNotify(AccountEntry a) async {
    final api = _api;
    if (api == null) return;
    if (a.notifyInactive) {
      await api.setNotify(a.id, false);
      return;
    }
    final ok = await showAppConfirm(
      context,
      tr('This can let the server see that these identities share a device.'),
      title: tr('Notify me for this identity while it\'s not active'),
      okLabel: tr('Turn on'),
    );
    if (!ok) return;
    final err = await api.setNotify(a.id, true);
    if (err == 'unsupported') {
      showToast(tr('Anonymous and unfinished identities can\'t get notifications '
          'while inactive.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    final c = context.nym;
    if (api == null) return const SizedBox.shrink();
    return ValueListenableBuilder<AccountIndex>(
      valueListenable: api.changes,
      builder: (context, index, _) {
        final full = index.accounts.length >= AccountLogic.maxAccounts;
        return ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 60,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 56, 8),
                        child: Text(
                          tr('Identities').toUpperCase(),
                          style: TextStyle(
                            color: c.primary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                    ),
                    ModalChrome.closeChip(c, _close),
                  ],
                ),
              ),
              if (index.accounts.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(tr('No saved identities yet.'),
                      style: TextStyle(color: c.textDim, fontSize: 13)),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final a in index.accounts)
                      _AccountRow(
                        key: ValueKey('accountRow-${a.id}'),
                        account: a,
                        active: a.id == index.active,
                        onTap: a.id == index.active ? null : () => _switch(a),
                        onRemove: () => _remove(a),
                        onToggleNotify: () => _toggleNotify(a),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _FooterButton(
                        key: const ValueKey('accountAddBtn'),
                        label: tr('Add identity'),
                        icon: NymIcons.plus,
                        enabled: !full,
                        onTap: _add,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _FooterButton(
                        key: const ValueKey('accountLogoutAllBtn'),
                        label: tr('Log out of all identities'),
                        icon: NymIcons.logout,
                        danger: true,
                        enabled: index.accounts.isNotEmpty,
                        onTap: _logoutAll,
                      ),
                    ),
                  ],
                ),
              ),
              if (full)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                  child: Text(
                    tr('You can keep up to {n} identities on this device.',
                        {'n': AccountLogic.maxAccounts}),
                    style: TextStyle(color: c.textDim, fontSize: 12),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    super.key,
    required this.account,
    required this.active,
    required this.onTap,
    required this.onRemove,
    required this.onToggleNotify,
  });

  final AccountEntry account;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback onRemove;
  final VoidCallback onToggleNotify;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final a = account;
    final canNotify = a.pubkey.isNotEmpty && a.method != 'anonymous';
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: active ? c.primaryA(0.08) : null,
        child: Row(
          children: [
            NymAvatar(
              seed: a.pubkey.isEmpty ? a.id : a.pubkey,
              size: 36,
              imageUrl: a.avatar.isEmpty ? null : a.avatar,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    accountDisplayName(a),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.text,
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: c.glassBorder),
                      borderRadius: NymRadius.rxs,
                    ),
                    child: Text(
                      accountMethodLabel(a.method),
                      style: TextStyle(color: c.textDim, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            if (!active && a.unread > 0)
              Container(
                key: ValueKey('accountUnread-${a.id}'),
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: c.primary,
                  borderRadius: const BorderRadius.all(Radius.circular(10)),
                ),
                child: Text(
                  a.unread > 99 ? '99+' : '${a.unread}',
                  style: TextStyle(
                    color: c.bg,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            if (active)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: NymTooltip(
                  message: tr('Active identity'),
                  child: Icon(Icons.check,
                      key: const ValueKey('accountActiveCheck'),
                      size: 18,
                      color: c.primary),
                ),
              ),
            if (canNotify)
              IconButton(
                key: ValueKey('accountNotify-${a.id}'),
                tooltip: tr('Notify me for this identity while it\'s not active'),
                onPressed: onToggleNotify,
                icon: NymSvgIcon(
                  a.notifyInactive ? NymIcons.bell : NymIcons.bellOff,
                  size: 16,
                  color: a.notifyInactive ? c.primary : c.textDim,
                ),
              ),
            IconButton(
              key: ValueKey('accountRemove-${a.id}'),
              tooltip: tr('Remove identity'),
              onPressed: onRemove,
              icon: NymSvgIcon(NymIcons.close, size: 16, color: c.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

class _FooterButton extends StatelessWidget {
  const _FooterButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.danger = false,
  });

  final String label;
  final String icon;
  final VoidCallback onTap;
  final bool enabled;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final fg = !enabled ? c.textDim : (danger ? c.danger : c.text);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: NymRadius.rxs,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: c.glassBorder),
            borderRadius: NymRadius.rxs,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              NymSvgIcon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: fg, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoveAccountDialog extends StatelessWidget {
  const _RemoveAccountDialog({
    required this.name,
    required this.nsec,
    required this.signerHeld,
    this.next,
  });

  final String name;
  final String? nsec;
  final bool signerHeld;
  final String? next;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final key = nsec;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: ModalChrome.box(
          c,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr('Remove identity'),
                  style: TextStyle(
                    color: c.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  [
                    tr('Remove {nym} from this device? Its messages, settings '
                        'and caches on this device are deleted.',
                        {'nym': name}),
                    signerHeld
                        ? tr('Its key stays in your signer; you can add it '
                            'again later.')
                        : tr('Its key is stored only on this device: back up '
                            'the nsec first or you lose this identity.'),
                    if (next != null) tr('You will switch to {nym}.', {'nym': next}),
                  ].join(' '),
                  style: TextStyle(color: c.textDim, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (key != null)
                      TextButton(
                        key: const ValueKey('accountCopyNsecBtn'),
                        onPressed: () {
                          unawaited(SecretScreen.copy(key));
                          showToast(tr('Private key copied'));
                        },
                        child: Text(tr('Copy nsec'),
                            style: TextStyle(color: c.primary)),
                      ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(tr('Cancel'),
                          style: TextStyle(color: c.textDim)),
                    ),
                    TextButton(
                      key: const ValueKey('accountRemoveConfirmBtn'),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(tr('Remove'),
                          style: TextStyle(
                              color: c.danger, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
