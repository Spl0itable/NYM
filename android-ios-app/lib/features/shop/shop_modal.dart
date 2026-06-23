import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/api/api_client.dart';
import '../../state/nostr_controller.dart';
import 'shop_catalog.dart';
import 'shop_controller.dart';
import 'shop_models.dart';
import 'shop_widgets.dart';

/// Reads the live [ShopIdentity] from the nostr controller (pubkey + signable
/// privkey), or null when there is no live signer.
ShopIdentity? _shopIdentity(WidgetRef ref) {
  final id = ref.read(nostrControllerProvider).identity;
  if (id == null) return null;
  return ShopIdentity(pubkey: id.pubkey, privkey: id.privkey);
}

/// The flair shop (`#shopModal`, docs/specs/04 §3). Tabs: Message Styles /
/// Nickname Flair / Special Items / Limited & Bundles / My Items. Each item is
/// a card with a cosmetic preview, price, and a Buy / Activate action. Buy opens
/// a Lightning-invoice QR flow (backend stubbed). A recovery-code field restores
/// purchases.
class ShopModal extends ConsumerStatefulWidget {
  const ShopModal({super.key});

  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const ShopModal(),
    );
  }

  @override
  ConsumerState<ShopModal> createState() => _ShopModalState();
}

class _ShopModalState extends ConsumerState<ShopModal> {
  ShopTab _tab = ShopTab.styles;
  final _recoveryController = TextEditingController();

  @override
  void dispose() {
    _recoveryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(c),
                    _tabs(c),
                    Flexible(child: _body(c)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'FLAIR',
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Get addon packs to change the styling of your messages '
                      'and nickname that others will see across all channels '
                      '(only in the Nymchat app).',
                      style: TextStyle(color: c.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, color: c.textDim),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _recoveryRow(c),
        ],
      ),
    );
  }

  Widget _recoveryRow(NymColors c) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _recoveryController,
            style: TextStyle(color: c.text, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Recovery code',
              hintStyle: TextStyle(color: c.textDim, fontSize: 13),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: NymRadius.rxs,
                borderSide: BorderSide(color: c.glassBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: NymRadius.rxs,
                borderSide: BorderSide(color: c.glassBorder),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _restore,
          style: TextButton.styleFrom(
            backgroundColor: c.primaryA(0.10),
            shape: RoundedRectangleBorder(
              borderRadius: NymRadius.rxs,
              side: BorderSide(color: c.primaryA(0.30)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          ),
          child: Text('Restore', style: TextStyle(color: c.primary)),
        ),
      ],
    );
  }

  Future<void> _restore() async {
    final code = _recoveryController.text.trim();
    if (!ShopController.isValidRecoveryCode(code)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid recovery code.')),
      );
      return;
    }
    final identity = _shopIdentity(ref);
    final ctrl = ref.read(shopControllerProvider.notifier);
    String message;
    if (identity == null) {
      message = 'Sign in to restore purchases.';
    } else {
      try {
        // Real `shop-redeem` round-trip (shop.js restorePurchases).
        final itemId = await ctrl.redeem(code, identity: identity);
        message = itemId != null
            ? 'Purchase restored!'
            : 'Unknown recovery code.';
      } catch (_) {
        // Backend host unreachable in this environment — tolerate gracefully.
        // TODO(verify): live `/api/storage` redeem.
        message = 'Could not reach the server. Try again later.';
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _tabs(NymColors c) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.1),
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final t in ShopTab.values) _tabButton(c, t),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(NymColors c, ShopTab t) {
    final active = _tab == t;
    return GestureDetector(
      onTap: () => setState(() => _tab = t),
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: active ? c.primaryA(0.06) : Colors.transparent,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(NymRadius.xs),
            topRight: Radius.circular(NymRadius.xs),
          ),
          border: Border(
            bottom: BorderSide(
              color: active ? c.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          t.label,
          style: TextStyle(
            color: active ? c.primary : c.textDim,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _body(NymColors c) {
    final state = ref.watch(shopControllerProvider);
    final items = _itemsForTab(_tab, state);
    if (_tab == ShopTab.inventory && items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          'You don\'t own any items yet. Buy flair to see it here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(20),
      shrinkWrap: true,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 230,
        mainAxisExtent: 220,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => _ShopItemCard(
        item: items[i],
        owned: state.owns(items[i].id),
        active: _isActive(items[i], state.active),
        inventory: _tab == ShopTab.inventory,
        onBuy: () => _buy(items[i]),
        onActivate: () => _activate(items[i]),
        onGift: () => _gift(items[i]),
        onTransfer: () => _transfer(items[i]),
      ),
    );
  }

  List<ShopItem> _itemsForTab(ShopTab tab, ShopState state) {
    switch (tab) {
      case ShopTab.styles:
        return ShopCatalog.styles;
      case ShopTab.flair:
        return ShopCatalog.flair;
      case ShopTab.special:
        return ShopCatalog.special;
      case ShopTab.limited:
        return [...ShopCatalog.limited, ...ShopCatalog.bundles];
      case ShopTab.inventory:
        return state.owned.keys
            .map(ShopCatalog.byId)
            .whereType<ShopItem>()
            .toList();
    }
  }

  bool _isActive(ShopItem item, ActiveItems active) {
    switch (item.type) {
      case 'message-style':
        return active.style == item.id;
      case 'nickname-flair':
        return active.flair.contains(item.id);
      case 'cosmetic':
        return active.cosmetics.contains(item.id);
      case 'supporter':
        return active.supporter;
      default:
        return false;
    }
  }

  Future<void> _activate(ShopItem item) async {
    final ctrl = ref.read(shopControllerProvider.notifier);
    switch (item.type) {
      case 'message-style':
        await ctrl.toggleStyle(item.id);
      case 'nickname-flair':
        await ctrl.toggleFlair(item.id);
      case 'cosmetic':
        await ctrl.toggleCosmetic(item.id);
      case 'supporter':
        await ctrl.toggleSupporter();
    }
  }

  Future<void> _buy(ShopItem item) async {
    final identity = _shopIdentity(ref);
    final granted = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => _InvoiceDialog(item: item, identity: identity),
    );
    if (granted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${item.name} unlocked!')),
      );
    }
  }

  /// Gift [item] to another user (shop.js `promptGiftShopItem` →
  /// `executeGiftShopItem`): prompt for a recipient hex pubkey, then settle the
  /// gift via the normal buy→claim with `recipientPubkey` set.
  Future<void> _gift(ShopItem item) async {
    final identity = _shopIdentity(ref);
    final recipient = await _promptRecipientPubkey(
      title: 'Gift Item',
      item: item,
      description:
          "Enter the recipient's hex pubkey (64 characters). You pay for the "
          'item and it lands directly in their inventory.',
      selfPubkey: identity?.pubkey,
      selfMessage: 'Use Buy to purchase an item for yourself.',
    );
    if (recipient == null || !mounted) return;
    await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => _InvoiceDialog(
        item: item,
        identity: identity,
        recipientPubkey: recipient,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gift sent: ${item.name}')),
      );
    }
  }

  /// Transfer an owned [item] to another user (shop.js `promptTransferShopItem`
  /// → `executeTransferShopItem`): prompt for a recipient hex pubkey, then
  /// `shop-transfer` — revoking it locally and assigning it to the recipient.
  Future<void> _transfer(ShopItem item) async {
    final identity = _shopIdentity(ref);
    if (identity == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to transfer items.')),
      );
      return;
    }
    final recipient = await _promptRecipientPubkey(
      title: 'Transfer Item',
      item: item,
      description:
          "Enter the recipient's hex pubkey (64 characters). The item will be "
          'revoked from your inventory and assigned to theirs.',
      selfPubkey: identity.pubkey,
      selfMessage: 'You already own this item.',
    );
    if (recipient == null || !mounted) return;
    try {
      await ref
          .read(shopControllerProvider.notifier)
          .transfer(item.id, recipient, identity: identity);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${item.name} transferred.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transfer failed: $e')),
        );
      }
    }
  }

  /// Shared recipient-pubkey prompt for gift/transfer. Validates the 64-hex
  /// format and rejects the self pubkey, mirroring the PWA's gift/transfer
  /// modals. Returns the lowercased pubkey, or null on cancel.
  Future<String?> _promptRecipientPubkey({
    required String title,
    required ShopItem item,
    required String description,
    String? selfPubkey,
    required String selfMessage,
  }) {
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => _RecipientPubkeyDialog(
        title: title,
        item: item,
        description: description,
        selfPubkey: selfPubkey,
        selfMessage: selfMessage,
      ),
    );
  }
}

class _ShopItemCard extends StatelessWidget {
  const _ShopItemCard({
    required this.item,
    required this.owned,
    required this.active,
    required this.inventory,
    required this.onBuy,
    required this.onActivate,
    required this.onGift,
    required this.onTransfer,
  });

  final ShopItem item;
  final bool owned;
  final bool active;

  /// True when rendered inside the inventory ("My Items") tab — owned items
  /// there expose a Transfer action (shop.js inventory render).
  final bool inventory;
  final VoidCallback onBuy;
  final VoidCallback onActivate;
  final VoidCallback onGift;
  final VoidCallback onTransfer;

  /// Bundles can't be gifted/transferred in the PWA (no recovery code per
  /// component on the client); only single items expose gift/transfer.
  bool get _giftable => item.type != 'bundle';

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final legendary = item.isLegendary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: owned ? c.secondaryA(0.04) : Colors.white.withValues(alpha: 0.03),
        border: Border.all(
          color: legendary
              ? const Color(0x80FFC440)
              : (owned ? c.secondaryA(0.20) : c.glassBorder),
        ),
        borderRadius: NymRadius.rmd,
        boxShadow: legendary
            ? const [BoxShadow(color: Color(0x2EFFB428), blurRadius: 18)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShopSvgIcon(
            svg: item.icon,
            size: 32,
            color: legendary ? const Color(0xFFFFC440) : c.text,
          ),
          const SizedBox(height: 8),
          Text(
            item.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.text,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            alignment: Alignment.center,
            constraints: const BoxConstraints(minHeight: 44),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: c.glassBorder),
              borderRadius: NymRadius.rsm,
            ),
            child: ShopItemPreview(item: item),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt, size: 13, color: Color(0xFFF7931A)),
                  const SizedBox(width: 2),
                  Text(
                    '${item.price}',
                    style: const TextStyle(
                      color: Color(0xFFF7931A),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (owned)
                    _ActivateButton(
                        active: active, onTap: onActivate, item: item)
                  else ...[
                    if (_giftable) ...[
                      _PillButton(label: 'Gift', onTap: onGift),
                      const SizedBox(width: 6),
                    ],
                    _BuyButton(onTap: onBuy),
                  ],
                  // Owned items in the inventory tab can be transferred away.
                  if (owned && inventory && _giftable) ...[
                    const SizedBox(width: 6),
                    _PillButton(label: 'Transfer', onTap: onTransfer),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small outlined pill action (Gift / Transfer), styled like the Bitcoin-orange
/// Buy button but in the muted secondary accent.
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: c.secondaryA(0.4)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: c.secondary,
            fontWeight: FontWeight.w500,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// The recipient-pubkey prompt shared by gift/transfer (shop.js gift/transfer
/// modals): a 64-hex pubkey field with inline validation.
class _RecipientPubkeyDialog extends StatefulWidget {
  const _RecipientPubkeyDialog({
    required this.title,
    required this.item,
    required this.description,
    required this.selfPubkey,
    required this.selfMessage,
  });

  final String title;
  final ShopItem item;
  final String description;
  final String? selfPubkey;
  final String selfMessage;

  @override
  State<_RecipientPubkeyDialog> createState() => _RecipientPubkeyDialogState();
}

class _RecipientPubkeyDialogState extends State<_RecipientPubkeyDialog> {
  final _controller = TextEditingController();
  static final _hexRe = RegExp(r'^[0-9a-f]{64}$');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pk = _controller.text.trim().toLowerCase();
    if (!_hexRe.hasMatch(pk)) {
      setState(() => _error = 'Invalid pubkey. Must be 64 hex characters.');
      return;
    }
    if (widget.selfPubkey != null && pk == widget.selfPubkey) {
      setState(() => _error = widget.selfMessage);
      return;
    }
    Navigator.of(context).pop(pk);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: c.bgSecondary,
              borderRadius: NymRadius.rxl,
              border: Border.all(color: c.glassBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ShopSvgIcon(svg: widget.item.icon, size: 24, color: c.text),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.item.name,
                        style: TextStyle(
                          color: c.text,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Text(
                      '${widget.item.price} sats',
                      style: const TextStyle(
                        color: Color(0xFFF7931A),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  widget.description,
                  style: TextStyle(color: c.textDim, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  style: TextStyle(color: c.text, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Recipient hex pubkey (64 chars)',
                    hintStyle: TextStyle(color: c.textDim),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: c.glassBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: c.secondaryA(0.5)),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _submit,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: c.secondaryA(0.18),
                            border: Border.all(color: c.secondaryA(0.4)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('Continue',
                              style: TextStyle(color: c.secondary)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: c.glassBorder),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('Cancel',
                            style: TextStyle(color: c.textDim)),
                      ),
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

class _BuyButton extends StatelessWidget {
  const _BuyButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x26F7931A), Color(0x14F7931A)],
          ),
          border: Border.all(color: const Color(0x59F7931A)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'Buy',
          style: TextStyle(
            color: Color(0xFFF7931A),
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _ActivateButton extends StatelessWidget {
  const _ActivateButton({
    required this.active,
    required this.onTap,
    required this.item,
  });
  final bool active;
  final VoidCallback onTap;
  final ShopItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Bundles aren't toggleable; show an owned chip instead.
    if (item.type == 'bundle') {
      return Text('Owned',
          style: TextStyle(color: c.secondary, fontSize: 12));
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? c.secondaryA(0.18) : Colors.transparent,
          border: Border.all(color: c.secondaryA(0.4)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          active ? 'Active' : 'Activate',
          style: TextStyle(color: c.secondary, fontSize: 12),
        ),
      ),
    );
  }
}

/// The Lightning-invoice dialog shown when buying. Fetches a real
/// `shop-buy-invoice` bolt11 (shop.js `generateShopPaymentInvoice`), shows its
/// QR + copy + open-wallet, then polls `shop-check` (2s × 180) and on payment
/// runs `shop-claim` to grant the item, mirroring `handleShopPaymentSuccess`.
///
/// TODO(verify): the live `/api/storage` host is unreachable in this
/// environment, so the network call may fail — the dialog surfaces the error
/// and offers a manual "I've paid" fallback that grants locally.
class _InvoiceDialog extends ConsumerStatefulWidget {
  const _InvoiceDialog({
    required this.item,
    required this.identity,
    this.recipientPubkey,
  });

  final ShopItem item;
  final ShopIdentity? identity;

  /// When set, this is a gift purchase — the item lands in [recipientPubkey]'s
  /// inventory instead of the buyer's (shop.js `purchaseItem(id, recipient)`).
  final String? recipientPubkey;

  @override
  ConsumerState<_InvoiceDialog> createState() => _InvoiceDialogState();
}

enum _BuyPhase { generating, invoice, claiming, paid, error }

class _InvoiceDialogState extends ConsumerState<_InvoiceDialog> {
  final _api = ApiClient();
  _BuyPhase _phase = _BuyPhase.generating;
  String _status = '';
  ShopInvoice? _invoice;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  ShopController get _ctrl => ref.read(shopControllerProvider.notifier);

  Future<void> _generate() async {
    final identity = widget.identity;
    if (identity == null) {
      setState(() {
        _phase = _BuyPhase.error;
        _status = 'Sign in to buy flair.';
      });
      return;
    }
    try {
      final inv = await _ctrl.buy(
        widget.item.id,
        identity: identity,
        recipientPubkey: widget.recipientPubkey,
      );
      if (!mounted) return;
      setState(() {
        _invoice = inv;
        _phase = _BuyPhase.invoice;
      });
      _startPolling(inv, identity);
    } catch (e) {
      if (!mounted) return;
      // Backend unreachable in this environment — fall back to the manual
      // confirmation path. TODO(verify): live `/api/storage` shop-buy-invoice.
      setState(() {
        _phase = _BuyPhase.error;
        _status = 'Could not reach the server.';
      });
    }
  }

  void _startPolling(ShopInvoice inv, ShopIdentity identity) {
    if (inv.invoiceId.isEmpty) return;
    var checks = 0;
    // shop.js checkShopPaymentViaServer: every 2s, up to 180 (~6 min).
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      checks++;
      final paid = await _ctrl.checkPaid(inv.invoiceId, identity: identity);
      if (!mounted) return;
      if (paid) {
        t.cancel();
        await _claim(inv, identity);
      } else if (checks >= 180) {
        t.cancel();
        setState(() {
          _phase = _BuyPhase.error;
          _status = 'Payment timeout - please check your wallet';
        });
      }
    });
  }

  Future<void> _claim(ShopInvoice inv, ShopIdentity identity) async {
    setState(() => _phase = _BuyPhase.claiming);
    try {
      await _ctrl.claim(inv.invoiceId, identity: identity);
      if (!mounted) return;
      setState(() => _phase = _BuyPhase.paid);
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted) Navigator.of(context).pop(true);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _BuyPhase.error;
        _status = 'Claim failed - your payment is safe, try restoring later.';
      });
    }
  }

  Future<void> _copy() async {
    final pr = _invoice?.pr;
    if (pr != null) await Clipboard.setData(ClipboardData(text: pr));
  }

  Future<void> _openWallet() async {
    final pr = _invoice?.pr;
    if (pr == null) return;
    final uri = Uri.parse(
        pr.toLowerCase().startsWith('lightning:') ? pr : 'lightning:$pr');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: pr));
    }
  }

  /// Offline fallback for the unreachable-backend case: grant locally. Gifts
  /// land in the recipient's inventory, so a gift purchase grants nothing here.
  Future<void> _manualConfirm() async {
    if (widget.recipientPubkey == null) {
      await _ctrl.claimAfterPayment(widget.item.id);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Material(
            color: c.bgSecondary,
            borderRadius: NymRadius.rxl,
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Purchasing ${widget.item.name}',
                    style: TextStyle(
                      color: c.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${widget.item.price} sats',
                      style: TextStyle(color: c.textDim, fontSize: 13)),
                  const SizedBox(height: 16),
                  ..._phaseBody(c),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _phaseBody(NymColors c) {
    switch (_phase) {
      case _BuyPhase.generating:
        return [
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text('Generating invoice...',
              style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(height: 8),
          _cancelButton(c),
        ];
      case _BuyPhase.claiming:
        return [
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text('Payment received — unlocking...',
              style: TextStyle(color: c.textDim, fontSize: 12)),
        ];
      case _BuyPhase.paid:
        return [
          const SizedBox(height: 8),
          const Text('⚡', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 4),
          Text('Purchase complete!', style: TextStyle(color: c.primary)),
        ];
      case _BuyPhase.error:
        return [
          const SizedBox(height: 12),
          Text(_status,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.text, fontSize: 13)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text('Close', style: TextStyle(color: c.textDim)),
                ),
              ),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: c.primary),
                  // TODO(verify): manual grant fallback while the live backend
                  // is unreachable here.
                  onPressed: _manualConfirm,
                  child: const Text("I've paid"),
                ),
              ),
            ],
          ),
        ];
      case _BuyPhase.invoice:
        final pr = _invoice!.pr;
        return [
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: QrImageView(
                data: pr, size: 200, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 12),
          Text('Scan with a Lightning wallet to pay.',
              style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _copy,
                  child: Text('Copy', style: TextStyle(color: c.primary)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _openWallet,
                  child:
                      Text('Open Wallet', style: TextStyle(color: c.primary)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _cancelButton(c),
        ];
    }
  }

  Widget _cancelButton(NymColors c) => TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text('Cancel', style: TextStyle(color: c.textDim)),
      );
}
