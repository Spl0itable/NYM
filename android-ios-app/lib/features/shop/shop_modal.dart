import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/relays.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/identity/modal_chrome.dart';
import '../../services/api/api_client.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import 'cosmetics.dart' show CosmeticAura, cosmeticAuraFor;
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

/// The `nym#suffix` gifter tag attached to shop-claim / shop-transfer so the
/// recipient's notification DM names the gifter (shop.js:1329, 1745).
String? _gifterNym(WidgetRef ref) {
  final id = ref.read(nostrControllerProvider).identity;
  if (id == null) return null;
  return '${stripPubkeySuffix(id.nym)}#${getPubkeySuffix(id.pubkey)}';
}

/// A human-readable backend error: the server `{error}` from an [ApiException]
/// body, else the exception text (mirrors the PWA surfacing `e.message`).
String _errorMessage(Object e) {
  if (e is ApiException) {
    try {
      final j = jsonDecode(e.body);
      if (j is Map && j['error'] is String && (j['error'] as String).isNotEmpty) {
        return j['error'] as String;
      }
    } catch (_) {}
    return 'Request failed (${e.statusCode})';
  }
  return e.toString();
}

/// The flair shop (`#shopModal`, docs/specs/04 §3). Tabs: Message Styles /
/// Nickname Flair / Special Items / Limited & Bundles / My Items. Each item is
/// a card with a cosmetic preview, price, and a Buy / Activate action. Buy opens
/// the real Lightning-invoice QR flow (`shop-buy-invoice` → detection →
/// `shop-claim`). A recovery-code field restores purchases via `shop-redeem`.
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
  void initState() {
    super.initState();
    // Refresh the authoritative record on EVERY open so gifted/transferred/
    // redeemed items appear (shop.js `openShop` → `loadShopFromServer`,
    // shop.js:659-674 — fire-and-forget; the cached record renders meanwhile).
    // Also settle any pending purchase that was paid while the app was closed
    // (shop.js `reconcilePendingPurchases`, run on foreground in the PWA).
    final identity = _shopIdentity(ref);
    if (identity != null) {
      final ctrl = ref.read(shopControllerProvider.notifier);
      unawaited(ctrl.loadFromServer(identity));
      unawaited(
        ctrl.reconcilePendingPurchases(identity, gifterNym: _gifterNym(ref)),
      );
    }
  }

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
                child: Stack(
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _header(c),
                        _tabs(c),
                        Flexible(child: _body(c)),
                      ],
                    ),
                    // `.shop-close`: 32×32 glass ✕ chip, absolute top-right
                    // (14,14), z-index 10 — the shared modal-close chrome.
                    ModalChrome.closeChip(c, () => Navigator.of(context).pop()),
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
    // `.shop-header` resolves to a COLUMN, not a row: the base rule
    // (styles-features.css:18-24, `display:flex; justify-content:space-between;
    // align-items:center`) is OVERRIDDEN later in the same stylesheet by
    // `.shop-header { flex-direction: column; align-items: flex-start; gap: 15px }`
    // (styles-features.css:1497-1501). So the title/subtitle block stacks ABOVE a
    // full-width `.shop-recovery` (`.shop-recovery { width: 100%; margin-left: 0 }`,
    // styles-features.css:1503-1506) — NOT a left-title / right-field row. The
    // close ✕ is the separate absolute `.shop-close` chip (added in build); the
    // header keeps the PWA's symmetric 24px padding and lets the short FLAIR title
    // / wrapping subtitle clear the chip.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        // `body.light-mode .shop-header { background: rgba(0,0,0,0.02) }`
        // (styles-themes-responsive.css:644-646); no fill in dark mode.
        color: c.isLight ? const Color(0x05000000) : null,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
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
          // `.shop-title .nm-h-16` subtitle: 12px, `--text-dim`, and it INHERITS
          // the `.shop-title { font-weight: 700 }` (the `.nm-h-16` rules only set
          // size + colour) — so the subtitle is bold too. Reserve right room for
          // the absolute ✕ chip so the first wrapped line clears it.
          Padding(
            padding: const EdgeInsets.only(right: 28),
            child: Text(
              'Get addon packs to change the styling of your messages '
              'and nickname that others will see across all channels '
              '(only in the Nymchat app).',
              style: TextStyle(
                color: c.textDim,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          // `gap: 15px` between the title block and the recovery row.
          const SizedBox(height: 15),
          _recoveryRow(c),
        ],
      ),
    );
  }

  Widget _recoveryRow(NymColors c) {
    // `.shop-recovery` is full-width (`width: 100%`); its input + Restore button
    // flow inline. The input takes the remaining width, the button hugs its label.
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
    // No client-side format gate and NO case-folding: the PWA sends any
    // trimmed non-empty code to the server verbatim (shop.js:1662-1669).
    final code = _recoveryController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a recovery code')),
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
        await ctrl.redeem(code, identity: identity);
        message = '✅ Shop item restored successfully!';
      } catch (e) {
        message = '❌ Restore failed: ${_errorMessage(e)}';
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _tabs(NymColors c) {
    // `.shop-tabs { display:flex; background: rgba(0,0,0,.1); padding: 6px 6px 0;
    // gap: 4px }` with `.shop-tab { flex: 1 }` (styles-features.css:73-94) — the 5
    // tabs share the row width equally (no horizontal scroll), each filling 1/5.
    const tabs = ShopTab.values;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.1),
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: 4), // `gap: 4px`
            Expanded(child: _tabButton(c, tabs[i])),
          ],
        ],
      ),
    );
  }

  void _selectTab(ShopTab t) {
    setState(() => _tab = t);
    // Entering the limited tab kicks off the public supply fetch (F5).
    if (t == ShopTab.limited) {
      final ids = ShopCatalog.limited
          .where((i) => i.maxSupply != null)
          .map((i) => i.id)
          .toList();
      if (ids.isNotEmpty) {
        ref.read(shopControllerProvider.notifier).fetchSupply(ids);
      }
    }
  }

  Widget _tabButton(NymColors c, ShopTab t) {
    final active = _tab == t;
    return GestureDetector(
      onTap: () => _selectTab(t),
      child: Container(
        // `.shop-tab { padding: 12px 10px }` — the 4px inter-tab gap is the
        // parent Row's SizedBox, not a per-tab margin (the tab fills its flex:1).
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
        // Equal-width tabs: centre the label and ellipsize if a narrow modal
        // can't fit it (the PWA's `flex:1` tabs likewise shrink their text).
        child: Text(
          t.label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
    if (_tab == ShopTab.inventory) {
      return _inventoryBody(c, state);
    }
    if (_tab == ShopTab.limited) {
      return _limitedBody(c, state);
    }
    final items = _itemsForTab(_tab, state);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _cardWrap(c, state, items),
    );
  }

  /// A wrapping row of item cards (PWA `.shop-items` flex-wrap). [cardBuilder]
  /// customises the card (limited availability / inventory variants); defaults
  /// to the plain shop card.
  Widget _cardWrap(
    NymColors c,
    ShopState state,
    List<ShopItem> items, {
    Widget Function(ShopItem item)? cardBuilder,
  }) {
    // PWA `.shop-items { grid-template-columns: repeat(auto-fill,
    // minmax(200px,1fr)); gap: 20px }` (styles-features.css:116-121): as many
    // >=200px columns as fit the width, each stretching to share the row equally
    // — a fluid grid, not fixed 214px cards with a ragged right edge. The SAME
    // grid renders every tab (limited/bundles/inventory included).
    const gap = 20.0;
    const minCard = 200.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final fit = ((w + gap) / (minCard + gap)).floor();
        final cols = fit < 1 ? 1 : fit;
        final cardW = (w - (cols - 1) * gap) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in items)
              SizedBox(
                width: cardW,
                child: cardBuilder != null
                    ? cardBuilder(item)
                    : _card(c, state, item),
              ),
          ],
        );
      },
    );
  }

  Widget _card(
    NymColors c,
    ShopState state,
    ShopItem item, {
    bool inventory = false,
    ShopAvailability? availability,
  }) {
    return _ShopItemCard(
      item: item,
      owned: state.owns(item.id),
      active: _isActive(item, state.active),
      inventory: inventory,
      // The user's live chat layout drives whether the message-style / cosmetic
      // / supporter demos render as bubbles or flat IRC rows (shop.js demos reuse
      // the real `.message` classes, styled by `body.chat-bubbles`).
      bubble: ref.watch(settingsProvider.select((s) => s.useBubbles)),
      ownedItem: inventory ? state.owned[item.id] : null,
      availability: availability,
      // Stamp a sample Genesis edition (#69) only on the unowned preview; the
      // inventory shows the owner's real edition via ShopEditionNumber instead.
      sampleEdition:
          (!inventory && item.id == 'flair-genesis') ? 69 : null,
      onBuy: () => _buy(item),
      onActivate: () => _activate(item),
      onGift: () => _gift(item),
      onTransfer: () => _transfer(item),
    );
  }

  /// The Limited & Bundles tab (F5/F6): limited drops with supply badges +
  /// soldout/soon/ended gating, then bundles with content chips + savings. The
  /// supply fetch is kicked off when the tab is selected (`_selectTab`).
  Widget _limitedBody(NymColors c, ShopState state) {
    final ctrl = ref.read(shopControllerProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Each section title renders only when its list is non-empty
          // (shop.js:920/927 — `if (limited.length)` / `if (bundles.length)`).
          if (ShopCatalog.limited.isNotEmpty) ...[
            _categoryTitle(c, 'Limited Editions'),
            const SizedBox(height: 12),
            _cardWrap(
              c,
              state,
              ShopCatalog.limited,
              cardBuilder: (item) =>
                  _card(c, state, item, availability: ctrl.availability(item)),
            ),
            const SizedBox(height: 24),
          ],
          if (ShopCatalog.bundles.isNotEmpty) ...[
            _categoryTitle(c, 'Bundles'),
            const SizedBox(height: 12),
            _cardWrap(c, state, ShopCatalog.bundles),
          ],
        ],
      ),
    );
  }

  /// The My Items (inventory) tab (F9): a live self-message preview, the
  /// active-items summary blocks, then every purchased item with its edition #,
  /// acquired date, recovery code and Transfer action.
  Widget _inventoryBody(NymColors c, ShopState state) {
    final owned = state.owned.keys
        .map(ShopCatalog.byId)
        .whereType<ShopItem>()
        .toList();
    if (owned.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          'No items purchased yet',
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim),
        ),
      );
    }
    final active = state.active;
    final activeStyle = active.style != null
        ? ShopCatalog.byId(active.style!)
        : null;
    final activeFlairs = active.flair
        .map(ShopCatalog.byId)
        .whereType<ShopItem>()
        .toList();
    final activeCosmetics = active.cosmetics
        .map(ShopCatalog.byId)
        .whereType<ShopItem>()
        .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _categoryTitle(c, 'My Items'),
          const SizedBox(height: 12),
          _ActiveItemsPreview(active: active),
          if (activeStyle != null)
            _ActiveSummaryBlock(
              title: 'Active Message Style',
              // `Active Message Style` chip is name-only (shop.js:984).
              chips: [_ActiveChip(name: activeStyle.name)],
            ),
          if (activeFlairs.isNotEmpty)
            _ActiveSummaryBlock(
              title: 'Active Nickname Flair',
              // `${f.name} ${f.icon}` — name then trailing icon (shop.js:993).
              chips: [
                for (final f in activeFlairs)
                  _ActiveChip(name: f.name, icon: f.icon, iconLeading: false),
              ],
            ),
          if (activeCosmetics.isNotEmpty)
            _ActiveSummaryBlock(
              title: 'Active Special Items',
              // `${it.icon} ${it.name}` — leading icon then name (shop.js:1003).
              chips: [
                for (final x in activeCosmetics)
                  _ActiveChip(name: x.name, icon: x.icon, iconLeading: true),
              ],
            ),
          const SizedBox(height: 8),
          _categoryTitle(c, 'All Purchased Items'),
          const SizedBox(height: 12),
          _cardWrap(
            c,
            state,
            owned,
            cardBuilder: (item) => _card(c, state, item, inventory: true),
          ),
        ],
      ),
    );
  }

  /// The `.shop-category-title`: primary, 18px 700, bottom hairline.
  Widget _categoryTitle(NymColors c, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: c.primary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
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
    // Push the new active set to D1 so other clients render it via shop-status
    // (shop.js `publishActiveShopItems`). Best-effort; no-ops without a signer.
    final identity = _shopIdentity(ref);
    if (identity != null) await ctrl.publishActiveItems(identity);
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
      // shop.js:1650 — the exact self-gift rejection copy.
      selfMessage: 'Use GET to buy an item for yourself.',
      // Gift modal: "Continue" CTA + price row (shop.js:1620, 1630).
      ctaLabel: 'Continue',
      showPrice: true,
    );
    if (recipient == null || !mounted) return;
    final granted = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => _InvoiceDialog(
        item: item,
        identity: identity,
        recipientPubkey: recipient,
      ),
    );
    // Only a settled claim confirms the gift (the PWA's "Gift sent!" comes from
    // `_renderShopSuccess` after shop-claim, shop.js:1579) — a cancelled or
    // failed payment must NOT report success.
    if (granted == true && mounted) {
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
      // shop.js:1731 — the exact self-transfer rejection copy.
      selfMessage: 'Cannot transfer to yourself.',
      // Transfer modal: "Confirm" CTA + no price (shop.js:1698-1702, 1711).
      ctaLabel: 'Confirm',
      showPrice: false,
    );
    if (recipient == null || !mounted) return;
    try {
      await ref.read(shopControllerProvider.notifier).transfer(
            item.id,
            recipient,
            identity: identity,
            gifterNym: _gifterNym(ref),
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${item.name} transferred to ${recipient.substring(0, 8)}...',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transfer failed: ${_errorMessage(e)}')),
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
    required String ctaLabel,
    required bool showPrice,
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
        ctaLabel: ctaLabel,
        showPrice: showPrice,
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
    required this.bubble,
    required this.onBuy,
    required this.onActivate,
    required this.onGift,
    required this.onTransfer,
    this.ownedItem,
    this.availability,
    this.sampleEdition,
  });

  final ShopItem item;
  final bool owned;
  final bool active;

  /// The user's current chat layout (chat-bubbles vs IRC); threaded into the
  /// live message-style / cosmetic / supporter demos so the card preview matches
  /// how the cosmetic would render in the user's layout.
  final bool bubble;

  /// True when rendered inside the inventory ("My Items") tab — owned items
  /// there expose a Transfer action (shop.js inventory render).
  final bool inventory;
  final VoidCallback onBuy;
  final VoidCallback onActivate;
  final VoidCallback onGift;
  final VoidCallback onTransfer;

  /// The owned record (inventory tab) — surfaces edition #, acquired date and
  /// recovery code (F9).
  final OwnedItem? ownedItem;

  /// Limited-tab availability — supply badge + soldout/soon/ended gating (F5).
  final ShopAvailability? availability;

  /// Sample edition stamped on a flair preview (e.g. Genesis #69 in the
  /// limited tab); only affects the preview, not real ownership.
  final int? sampleEdition;

  bool get _isBundle => item.type == 'bundle';

  /// True when a limited item is not currently buyable (soon/ended/soldout) —
  /// the Buy button is replaced with the status label (F5).
  bool get _blockedByAvailability =>
      availability != null && !availability!.isAvailable;

  /// Whether the limited-tab supply badge row renders (F5).
  bool get _showsSupplyBadge =>
      availability != null && availability!.label.isNotEmpty;

  /// Whether the preview region starts with the `.shop-item-preview` box
  /// (flair / supporter nym rows) rather than a bare `.shop-msg-demo`.
  bool get _boxedPreview =>
      item.type == 'nickname-flair' || item.type == 'supporter';

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final legendary = item.isLegendary;
    final card = Container(
      // `.shop-item { padding: 18px }` (styles-features.css:123-132).
      padding: const EdgeInsets.all(18),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // `.shop-item-legendary { background: linear-gradient(160deg,
        // rgba(255,196,64,.06), rgba(255,120,200,.04)) }` — a faint gold→pink
        // wash (styles-features.css:1306-1310). Non-legendary cards keep the
        // flat owned/base fill.
        color: legendary
            ? null
            : (owned
                ? c.secondaryA(0.04)
                : Colors.white.withValues(alpha: 0.03)),
        gradient: legendary
            ? const LinearGradient(
                begin: Alignment(-0.342, -0.940), // CSS 160deg
                end: Alignment(0.342, 0.940),
                colors: [Color(0x0FFFC440), Color(0x0AFF78C8)],
              )
            : null,
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
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.shop-item-icon` uses currentColor (= var(--text)) for legendary and
          // non-legendary alike — there is no `.shop-item-legendary .shop-item-icon`
          // override in the PWA (styles-features.css:161-165). Always tint c.text.
          ShopSvgIcon(
            svg: item.icon,
            size: 32,
            color: c.text,
          ),
          // `.shop-item-icon { margin-bottom: 10px }`.
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  item.name,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // Inventory: gold edition number after the name (F9).
              if (ownedItem?.edition != null) ...[
                const SizedBox(width: 6),
                ShopEditionNumber(
                  edition: ownedItem!.edition!,
                  editionMax: ownedItem!.editionMax,
                ),
              ],
            ],
          ),
          // Per-card description — the PWA renders `.shop-item-description` on
          // EVERY card type (styles/flair/special/limited/bundle/inventory;
          // shop.js:737,757,800,877,908,1022). `.shop-item-description` has NO
          // text-align rule → left-aligned (only icon/name centre).
          // `.shop-item-name { margin-bottom: 5px }`.
          const SizedBox(height: 5),
          Text(
            item.description,
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
          // Inventory: acquired date (F9) — `.nm-shop-4` is left-aligned too.
          if (inventory && ownedItem != null) ...[
            const SizedBox(height: 10),
            Text(
              'Acquired: ${_formatDate(ownedItem!.timestamp)}',
              style: TextStyle(color: c.textDim, fontSize: 10),
            ),
          ],
          // Limited-tab supply badge (F5): an inline-block div in the card's
          // LEFT-aligned flow (`.shop-supply-badge`, styles-features.css:1332),
          // not centered. Its CSS `margin: 6px 0` collapses with the
          // description's 10px bottom margin → a 10px gap above.
          if (_showsSupplyBadge) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: ShopSupplyBadge(availability: availability!),
            ),
          ],
          // Preview region: bundle chips (F6) or the standard item preview
          // (F4). Only the flair / supporter nym rows sit in the
          // `.shop-item-preview` box — style/cosmetic demos and bundle chips
          // render BARE in the card (shop.js `_shopStyleDemo` /
          // `_shopCosmeticDemo` / `_renderBundleCard`). Inventory cards render
          // NO preview (renderInventoryTab shows only icon/name/description/
          // acquired/button/code/transfer) EXCEPT the supporter card's badge
          // row (shop.js:1048), which follows the acquired line with no gap
          // (`.nm-shop-4` has no bottom margin, the box no top margin).
          if (!inventory || item.type == 'supporter') ...[
            // Collapsed CSS gaps above the preview: description mb 10 vs demo
            // mt 10 / box mt 0 → 10; after a supply badge (mb 6): 10 to a
            // bare demo, 6 to a `.shop-item-preview` box.
            if (_showsSupplyBadge)
              SizedBox(height: _boxedPreview ? 6 : 10)
            else if (!inventory)
              const SizedBox(height: 10),
            _previewRegion(c),
          ],
          if (inventory) ...[
            // Inventory has NO price footer (shop.js:1008-1067): a full-width
            // ACTIVATE (`.shop-buy-btn nm-shop-5` — the orange buy pill at
            // `width:100%; margin-top:10px`), then the recovery code, then
            // TRANSFER TO PUBKEY for EVERY purchase (bundles included).
            if (item.type != 'bundle') ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: _OrangePillButton(
                  label: active ? 'DEACTIVATE' : 'ACTIVATE',
                  onTap: onActivate,
                ),
              ),
            ],
            if (ownedItem?.code != null && ownedItem!.code!.isNotEmpty)
              RecoveryCodeRow(code: ownedItem!.code!),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: _TransferButton(onTap: onTransfer),
            ),
          ] else
            // `.shop-item-price`: the footer bar under a 1px glass hairline
            // (`margin-top:10px; padding-top:10px; border-top:1px solid
            // var(--glass-border)`, styles-features.css:195-202), children
            // spread by `justify-content: space-between`.
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.glassBorder)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: _footerChildren(c),
              ),
            ),
        ],
      ),
    );
    if (!legendary && !owned) return card;
    // Overlays: the legendary 45deg corner ribbon (F14, clipped to the card's
    // rounded corner — PWA `.shop-item { overflow:hidden }` — while the card
    // keeps its outer gold glow a whole-stack clip would crop), and/or the
    // `✓ OWNED` corner pill on purchased cards (`.shop-item.purchased::after`).
    return Stack(
      children: [
        card,
        if (legendary)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: NymRadius.rmd,
              child: const Stack(children: [ShopLegendaryRibbon()]),
            ),
          ),
        if (owned) const Positioned(top: 8, left: 8, child: _OwnedBadge()),
      ],
    );
  }

  /// The `.shop-item-price` footer children, spread space-between. PWA order
  /// (shop.js:704-719): price, then BUY, then GIFT — GIFT reuses the same
  /// orange `.shop-buy-btn` styling as BUY.
  List<Widget> _footerChildren(NymColors c) {
    // Limited soon/ended/soldout: only the availability label, styled like the
    // price (`<span class="shop-price-amount">${avail.label}</span>`,
    // shop.js:871) — lightning orange 16px bold, no buttons.
    if (_blockedByAvailability) {
      return [
        Text(
          availability!.label,
          style: const TextStyle(
            color: Color(0xFFF7931A),
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ];
    }
    // `.shop-price-amount`: ⚡ {price} sats — lightning, 16px bold
    // (styles-features.css:204-208). Flexible + scale-down so a long price
    // shrinks (the PWA flex row does the same) instead of overflowing.
    final price = Flexible(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          '⚡ ${item.price} sats',
          style: const TextStyle(
            color: Color(0xFFF7931A),
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ),
    );
    if (owned && !_isBundle) {
      // `_shopItemOwnedHtml(item, allowGift)`: regular owned → price + GIFT
      // (allowGift true); limited owned → price only (allowGift false,
      // shop.js:869).
      return [
        price,
        if (availability == null) _OrangePillButton(label: 'GIFT', onTap: onGift),
      ];
    }
    // Not owned (and every bundle): price, BUY, GIFT (`_shopItemActionsHtml`).
    return [
      price,
      _OrangePillButton(label: 'BUY', onTap: onBuy),
      _OrangePillButton(label: 'GIFT', onTap: onGift),
    ];
  }

  /// The card's preview region, mirroring the PWA's box-vs-bare markup.
  Widget _previewRegion(NymColors c) {
    // Bundle chips render bare (`.shop-bundle-contents` — no box).
    if (_isBundle) return ShopBundlePreview(item: item);
    // Limited-tab flair with a stamped sample edition (Genesis #69): the boxed
    // `.shop-item-preview` nym row (`_renderLimitedCard`, shop.js:864).
    if (sampleEdition != null && item.type == 'nickname-flair') {
      return ShopPreviewBox(child: _flairSamplePreview(c));
    }
    // The inventory supporter card shows a single boxed supporter-badge row
    // (shop.js:1048), not the full special preview.
    if (inventory && item.type == 'supporter') {
      return const ShopPreviewBox(child: SupporterBadge());
    }
    return ShopItemPreview(item: item, bubble: bubble);
  }

  /// The flair preview with a stamped sample edition (Genesis #69), used in the
  /// limited tab (`_renderLimitedCard`, shop.js:864): `<strong>Your_Nick</strong>`
  /// (bold, unlike the flair tab's regular-weight nym) + the badge.
  Widget _flairSamplePreview(NymColors c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Your_Nick ', style: TextStyle(fontWeight: FontWeight.bold)),
        FlairBadge(flairId: item.id, edition: sampleEdition),
      ],
    );
  }

  /// Locale-formatted acquired date (`new Date(ts*1000).toLocaleDateString()`,
  /// shop.js:1024).
  static String _formatDate(int msEpoch) =>
      DateFormat.yMd().format(DateTime.fromMillisecondsSinceEpoch(msEpoch));
}

/// The `✓ OWNED` corner pill on a purchased card (`.shop-item.purchased::after`,
/// styles-features.css:147-159): secondary text, 10px 500, `secondary@.1` bg,
/// `secondary@.25` border, radius 20, padding `3px 8px`.
class _OwnedBadge extends StatelessWidget {
  const _OwnedBadge();

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.secondaryA(0.10),
        border: Border.all(color: c.secondaryA(0.25)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '✓ OWNED',
        style: TextStyle(
          color: c.secondary,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// The `.shop-buy-btn` orange pill (styles-features.css:210-224): gradient
/// `rgba(247,147,26,.15)→.08`, border `rgba(247,147,26,.35)`, lightning text,
/// radius 20, padding `6px 16px`. BUY, GIFT and the inventory ACTIVATE all use
/// this exact styling in the PWA (GIFT's `.shop-gift-btn` adds no rules).
class _OrangePillButton extends StatelessWidget {
  const _OrangePillButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x26F7931A), Color(0x14F7931A)],
          ),
          border: Border.all(color: const Color(0x59F7931A)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFFF7931A),
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

/// The `TRANSFER TO PUBKEY` button (`.shop-buy-btn .shop-transfer-btn
/// .nm-shop-8`, no-inline.css:115): full width, green gradient
/// `rgba(0,255,170,.12)→.05`, border `rgba(0,255,170,.3)`, bright text.
class _TransferButton extends StatelessWidget {
  const _TransferButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x1F00FFAA), Color(0x0D00FFAA)],
          ),
          border: Border.all(color: const Color(0x4D00FFAA)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          'TRANSFER TO PUBKEY',
          style: TextStyle(
            color: c.textBright,
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

/// The live "Preview" self-message at the top of the inventory tab
/// (`_renderActiveItemsPreview`): your nym with the active style + flair +
/// supporter + cosmetics, over "This is how your messages look." Built locally
/// from [ShopCatalog] visuals + the shop's badge widgets.
class _ActiveItemsPreview extends ConsumerWidget {
  const _ActiveItemsPreview({required this.active});

  final ActiveItems active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final supporter = active.supporter;
    final cosmetics =
        active.cosmetics.where((x) => x != 'cosmetic-redacted').toList();
    final redacted = active.cosmetics.contains('cosmetic-redacted');
    final hasActive = active.style != null ||
        supporter ||
        cosmetics.isNotEmpty ||
        active.flair.isNotEmpty;
    if (!hasActive) return const SizedBox.shrink();

    final id = ref.watch(nostrControllerProvider).identity;
    final nym = id != null ? stripPubkeySuffix(id.nym) : 'You';
    final suffix = id != null ? getPubkeySuffix(id.pubkey) : '';
    final flairId = active.flair.isNotEmpty ? active.flair.last : null;
    final isGenesis = flairId == 'flair-genesis';
    final edition = flairId != null ? active.editions[flairId] : null;

    // The active-items "Preview" renders a real `.message.self.shop-preview-message`
    // (shop.js:944-965), which the PWA styles by the user's layout — so the
    // demo content switches between the bubble and IRC treatments too.
    final bubble = ref.watch(settingsProvider.select((s) => s.useBubbles));

    // Author line (shop.js:963): `<nym<span nym-suffix>#sfx</span>${flairHtml}
    // ${supporterBadge}<nym-bracket>&gt;` — the flair + supporter badges sit
    // INSIDE the brackets, before the closing `>`. Brackets are hidden in
    // chat-bubbles mode (`body.chat-bubbles .nym-bracket { display:none }`).
    // The author carries the USER colour class — the self author colour (the
    // theme primary; the bitchat self class is likewise the theme orange), not
    // the secondary accent. Genesis bolds the nym (suffix stays w400); redacted
    // dims the author (`.message-author.cosmetic-redacted`).
    final authorColor = redacted
        ? (c.isLight ? const Color(0xBF1A1A1A) : const Color(0xCCFFFFFF))
        : c.primary;
    final author = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                text: '${bubble ? '' : '<'}$nym',
                style: TextStyle(
                  color: authorColor,
                  fontWeight: isGenesis ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              TextSpan(
                text: '#$suffix',
                style: TextStyle(color: authorColor, fontWeight: FontWeight.w400),
              ),
            ]),
          ),
        ),
        if (flairId != null)
          // `.flair-badge` = 20px (the PWA renders the preview nym's flair at the
          // standard size, styles-features.css:316-320).
          FlairBadge(flairId: flairId, edition: edition),
        if (supporter) const SupporterBadge(),
        if (!bubble)
          Text('>',
              style:
                  TextStyle(color: authorColor, fontWeight: FontWeight.w400)),
      ],
    );

    // Content bubble: active style's text treatment + cosmetic auras.
    Widget content;
    if (redacted) {
      content = ShopCosmeticBubblePreview(
        cosmeticId: 'cosmetic-redacted',
        bubble: bubble,
      );
    } else if (active.style != null &&
        ShopCatalog.styleVisuals.containsKey(active.style)) {
      content = ShopStyleBubblePreview(
        styleId: active.style!,
        text: 'This is how your messages look.',
        bubble: bubble,
        // The active-items block puts the text directly in `.message-content`
        // (a bare body node, shop.js:964) — NOT wrapped in a `<span>` like the
        // item-card demo — so satoshi shows its white/brown container body colour.
        sampleIsChild: false,
      );
    } else if (supporter) {
      content = _SupporterContentLine(bubble: bubble);
    } else {
      content = Text(
        'This is how your messages look.',
        style: TextStyle(color: c.text, fontSize: 12),
      );
    }
    // Compose ALL active aura cosmetics onto the preview (the PWA stacks every
    // `cosmetic-X` class on the message): gradients, rings, prism/hologram and
    // the frost/cosmic watermark tiles — the same mode-aware auras the chat
    // bubble uses (only gold has a PWA light override).
    final auras = <CosmeticAura>[
      for (final x in cosmetics)
        if (cosmeticAuraFor(x, isLight: c.isLight) != null)
          cosmeticAuraFor(x, isLight: c.isLight)!,
    ];
    if (auras.isNotEmpty) {
      content = ShopAuraBubble(
        auras: auras,
        bubble: bubble,
        // The style/supporter content already draws its own bubble surface.
        defaultFill: active.style == null && !supporter && !redacted,
        padding: const EdgeInsets.all(2),
        child: content,
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.secondaryA(0.04),
        border: Border.all(color: c.secondaryA(0.20)),
        borderRadius: NymRadius.rsm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Preview',
              style: TextStyle(color: c.secondary, fontSize: 14)),
          const SizedBox(height: 10),
          author,
          const SizedBox(height: 6),
          Align(alignment: Alignment.centerLeft, child: content),
        ],
      ),
    );
  }
}

/// The supporter content line ("This is how your messages look." in gold),
/// rendered over the layout-appropriate supporter surface: a gold wash + left
/// bar in IRC, a flat gold fill on a rounded bubble in chat-bubbles mode
/// (matches the supporter demo bubble). Light mode: text `#8a6d00`, no glow;
/// wash `rgba(180,140,0,.06→.02)` + `#b8960a` bar; bubble `rgba(180,150,0,.08)`
/// (styles-themes-responsive.css:934-947, 1421).
class _SupporterContentLine extends StatelessWidget {
  const _SupporterContentLine({this.bubble = true});

  final bool bubble;

  @override
  Widget build(BuildContext context) {
    final isLight = context.nym.isLight;
    final text = Text(
      'This is how your messages look.',
      style: TextStyle(
        color: isLight ? const Color(0xFF8A6D00) : const Color(0xFFFFD700),
        fontSize: 12,
        shadows: isLight
            ? null
            : const [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
      ),
    );
    if (!bubble) {
      // IRC: the wash + 3px gold bar sit on the BLOCK `.message` row
      // (`body:not(.chat-bubbles) .message.supporter-style`), spanning the
      // preview panel's width; the text stays left-aligned.
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isLight
                ? const [Color(0x0FB48C00), Color(0x05B48C00)] // .06 → .02
                : const [Color(0x0DFFD700), Color(0x05FFD700)], // .05 → .02
          ),
          border: Border(
            left: BorderSide(
              color: isLight
                  ? const Color(0xFFB8960A)
                  : const Color(0xFFFFD700),
              width: 3,
            ),
          ),
        ),
        child: text,
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: isLight
            ? const Color(0x14B49600) // rgba(180,150,0,.08)
            : const Color(0x1FFFD700), // gold@.12
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      child: text,
    );
  }
}

/// One `.shop-active-item` chip: a name and (for flair / special items) the
/// item's inline SVG icon, ordered to match the PWA (`iconLeading` = special
/// items `${icon} ${name}`; trailing = flair `${name} ${icon}`).
class _ActiveChip {
  const _ActiveChip({required this.name, this.icon, this.iconLeading = true});

  final String name;
  final String? icon;
  final bool iconLeading;
}

/// An active-items summary block (`.shop-active-items`): a secondary-tinted
/// panel with a title + a row of pill chips (F9).
class _ActiveSummaryBlock extends StatelessWidget {
  const _ActiveSummaryBlock({required this.title, required this.chips});

  final String title;
  final List<_ActiveChip> chips;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.secondaryA(0.04),
        border: Border.all(color: c.secondaryA(0.20)),
        borderRadius: NymRadius.rsm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: c.secondary, fontSize: 14)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final chip in chips)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: c.secondaryA(0.10),
                    border: Border.all(color: c.secondary),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (chip.icon != null && chip.iconLeading) ...[
                        ShopSvgIcon(svg: chip.icon!, size: 14, color: c.text),
                        const SizedBox(width: 5),
                      ],
                      Text(chip.name,
                          style: TextStyle(color: c.text, fontSize: 12)),
                      if (chip.icon != null && !chip.iconLeading) ...[
                        const SizedBox(width: 5),
                        ShopSvgIcon(svg: chip.icon!, size: 14, color: c.text),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ],
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
    required this.ctaLabel,
    required this.showPrice,
  });

  final String title;
  final ShopItem item;
  final String description;
  final String? selfPubkey;
  final String selfMessage;

  /// CTA verb — "Continue" for the gift modal (shop.js:1630), "Confirm" for the
  /// transfer modal (shop.js:1711).
  final String ctaLabel;

  /// The gift modal shows the price row (shop.js:1620); the transfer modal shows
  /// only icon+name with no price (shop.js:1698-1702).
  final bool showPrice;

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
                    if (widget.showPrice)
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
                          child: Text(widget.ctaLabel,
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

/// The Lightning-invoice dialog shown when buying. Fetches a real
/// `shop-buy-invoice` bolt11 (shop.js `generateShopPaymentInvoice`), shows its
/// QR + copy + open-wallet, detects payment (LUD-21 verify poll / `shop-check`
/// / receipt window — see [_InvoiceDialogState._startPolling]) and on payment
/// runs `shop-claim`, mirroring `handleShopPaymentSuccess`. The item is never
/// granted client-side: the "I've paid" fallback re-verifies via `shop-check`.
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

  // Purchase-success details revealed in the `paid` phase (F10).
  bool _isGift = false;
  String? _successCode;
  int? _successEdition;
  int? _successEditionMax;

  /// Per-component recovery codes for a bundle purchase: (name, code).
  List<({String name, String code})> _bundleCodes = const [];

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    // Close any pending NIP-57 receipt REQ (shop.js `_clearShopReceiptWait`,
    // fired whenever the zap modal goes away).
    ref.read(nostrControllerProvider).clearShopReceiptWait();
    // Release the invoice back to the reconciliation path (a payment settled
    // after this dialog dies is claimed on the next foreground/shop open).
    ref.read(shopControllerProvider.notifier).activeInvoiceId = null;
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
      // The invoice/zap comment ('Nickname flair: Crown (gift)') + the signed
      // NIP-57 zap request riding the payment (shop.js:1211-1216).
      final comment = ShopController.purchaseComment(
        widget.item,
        gift: widget.recipientPubkey != null,
      );
      final zapRequest = ShopController.buildShopZapRequest(
        identity: identity,
        botPubkey: NostrController.nymbotPubkey,
        relays: RelayConfig.defaultRelays,
        amountSats: widget.item.price,
        comment: comment,
      );
      final inv = await _ctrl.buy(
        widget.item.id,
        identity: identity,
        recipientPubkey: widget.recipientPubkey,
        comment: comment,
        zapRequest: zapRequest,
      );
      if (!mounted) return;
      _ctrl.activeInvoiceId = inv.invoiceId;
      setState(() {
        _invoice = inv;
        _phase = _BuyPhase.invoice;
      });
      _startPolling(inv, identity);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _BuyPhase.error;
        _status = 'Failed: ${_errorMessage(e)}';
      });
    }
  }

  /// Payment detection, branch-for-branch with shop.js:1235-1240:
  ///   * LUD-21 `verify` URL → poll it directly every 1s × 180
  ///     (`checkShopPayment`),
  ///   * `serverVerify` → poll `shop-check` every 2s × 180
  ///     (`checkShopPaymentViaServer`),
  ///   * neither → wait for the NIP-57 kind-9735 receipt on relays, matched by
  ///     bolt11 (`_listenForShopReceipt`, shop.js:1483-1511 + zaps.js:1181-1189;
  ///     180s timeout).
  void _startPolling(ShopInvoice inv, ShopIdentity identity) {
    final verify = inv.verify;
    if (verify != null && verify.isNotEmpty) {
      var checks = 0;
      _pollTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
        checks++;
        var paid = false;
        try {
          final res = await _api.proxiedJsonFetch(verify);
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          paid = data is Map && (data['settled'] == true || data['paid'] == true);
        } catch (_) {
          // keep polling (shop.js:1280)
        }
        if (!mounted || _settling) return;
        if (paid) {
          t.cancel();
          await _claim(inv, identity);
        } else if (checks >= 180) {
          t.cancel();
          setState(() {
            _phase = _BuyPhase.error;
            _status = '⏱️ Payment timeout - please check your wallet';
          });
        }
      });
      return;
    }
    if (inv.serverVerify) {
      if (inv.invoiceId.isEmpty) return;
      var checks = 0;
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
        checks++;
        final paid = await _ctrl.checkPaid(inv.invoiceId, identity: identity);
        if (!mounted || _settling) return;
        if (paid) {
          t.cancel();
          await _claim(inv, identity);
        } else if (checks >= 180) {
          t.cancel();
          setState(() {
            _phase = _BuyPhase.error;
            _status = 'Payment not detected yet — if you paid, tap "I\'ve '
                'paid" or reopen the shop shortly.';
          });
        }
      });
      return;
    }
    // Receipt mode (no verify, no serverVerify): subscribe to the bot's zap
    // receipts and auto-claim when one matches this invoice's bolt11
    // (shop.js `_listenForShopReceipt` → zaps.js:1181-1189 →
    // `handleShopPaymentSuccess`); false = the 180s timeout fired, then the
    // PWA's receipt-timeout copy (shop.js:1499-1510).
    //
    // PARITY GAP (needs nostr_controller.dart): `listenForShopReceipt`
    // completes with a bare bool, so the matched kind-9735 event can't be
    // forwarded into `_claim(receipt: …)` the way the PWA sends `inv.receipt`
    // with shop-claim (shop.js:1189 `currentShopInvoice.receipt = event`,
    // :1545). Once it surfaces the event JSON, pass it here.
    unawaited(() async {
      final detected = await ref
          .read(nostrControllerProvider)
          .listenForShopReceipt(inv.pr);
      if (!mounted || _settling) return;
      if (detected) {
        await _claim(inv, identity);
      } else {
        setState(() {
          _phase = _BuyPhase.error;
          _status =
              'Payment not detected yet — if you paid, reopen the shop shortly.';
        });
      }
    }());
  }

  /// True once a claim is under way / settled — late poll ticks must not
  /// overwrite the claiming/success view.
  bool get _settling =>
      _phase == _BuyPhase.claiming || _phase == _BuyPhase.paid;

  /// [receipt] is the matched NIP-57 kind-9735 receipt event when the
  /// receipt-mode listener detected the payment — the PWA attaches it to
  /// shop-claim (`_claimShopPurchase(inv.invoiceId, inv.receipt)`,
  /// shop.js:1545); the verify/serverVerify/manual paths claim without one.
  Future<void> _claim(
    ShopInvoice inv,
    ShopIdentity identity, {
    Map<String, dynamic>? receipt,
  }) async {
    // Stop any detection loop still running (e.g. the manual "I've paid" path
    // confirms while the periodic poll is live), and close a pending receipt
    // REQ (shop.js `handleShopPaymentSuccess` → `_clearShopReceiptWait()`).
    _pollTimer?.cancel();
    ref.read(nostrControllerProvider).clearShopReceiptWait();
    setState(() {
      _phase = _BuyPhase.claiming;
      _status = 'Confirming purchase...';
    });
    try {
      final data = await _ctrl.claim(
        inv.invoiceId,
        identity: identity,
        receipt: receipt,
        gifterNym: _gifterNym(ref),
      );
      if (!mounted) return;
      _captureSuccess(data);
      // A limited purchase changes remaining supply; force a refresh next view.
      if (widget.item.maxSupply != null) _ctrl.invalidateSupply();
      // The success view NEVER auto-dismisses — the PWA waits for the Close
      // button so a recovery code can be saved (`_renderShopSuccess`).
      setState(() => _phase = _BuyPhase.paid);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _BuyPhase.error;
        _status = 'Purchase confirmation failed: ${_errorMessage(e)}';
      });
    }
  }

  /// "I've paid": immediately re-check the invoice server-side and, if the bot
  /// wallet confirms payment, finalize the claim — the PWA's
  /// `manualCheckPayment` (zaps.js:707-736). NEVER grants without the server.
  Future<void> _manualCheck() async {
    final identity = widget.identity;
    final inv = _invoice;
    if (identity == null || inv == null || inv.invoiceId.isEmpty) return;
    setState(() {
      _phase = _BuyPhase.claiming;
      _status = 'Checking payment...';
    });
    try {
      final paid = await _ctrl.checkPaid(inv.invoiceId, identity: identity);
      if (!mounted) return;
      if (paid) {
        await _claim(inv, identity);
        return;
      }
      setState(() {
        _phase = _BuyPhase.error;
        _status =
            'Not paid yet — complete the payment in your wallet, then tap again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _BuyPhase.error;
        _status = 'Could not check yet — try again in a moment.';
      });
    }
  }

  /// Extracts the recovery code / edition / bundle codes from a `shop-claim`
  /// response (shop.js `_renderShopSuccess`).
  void _captureSuccess(Map<String, dynamic> data) {
    _isGift = data['gift'] == true;
    final edition = data['edition'];
    if (edition is Map) {
      _successEdition = (edition['n'] as num?)?.toInt();
      _successEditionMax = (edition['max'] as num?)?.toInt();
    }
    final bundle = data['bundle'];
    if (!_isGift && bundle is List) {
      _bundleCodes = [
        for (final b in bundle)
          if (b is Map && b['code'] != null)
            (
              name: ShopCatalog.byId(b['itemId']?.toString() ?? '')?.name ??
                  (b['itemId']?.toString() ?? ''),
              code: b['code'].toString(),
            ),
      ];
    }
    // Single-item recovery code (not shown for gifts).
    if (!_isGift && _bundleCodes.isEmpty) {
      _successCode = data['code']?.toString();
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

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final recipient = widget.recipientPubkey;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Material(
            color: c.bgSecondary,
            borderRadius: NymRadius.rxl,
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // `${recipientPubkey ? 'Gifting' : 'Purchasing'}:
                    // <strong>${item.name}</strong>` (shop.js:1172-1174).
                    Text(
                      '${recipient != null ? 'Gifting' : 'Purchasing'}: '
                      '${widget.item.name}',
                      style: TextStyle(
                        color: c.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // `Price: N sats — gift to <pk8>...` (`.nm-shop-9`:
                    // 12px, warning colour).
                    Text(
                      'Price: ${widget.item.price} sats'
                      '${recipient != null ? ' — gift to ${recipient.substring(0, 8)}...' : ''}',
                      style: TextStyle(color: c.warning, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    ..._phaseBody(c),
                  ],
                ),
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
          // 'Confirming purchase...' (handleShopPaymentSuccess) or the manual
          // check's 'Checking payment...' (manualCheckPayment).
          Text(_status.isNotEmpty ? _status : 'Confirming purchase...',
              style: TextStyle(color: c.textDim, fontSize: 12)),
        ];
      case _BuyPhase.paid:
        return [
          const SizedBox(height: 8),
          // `.nm-shop-10 { font-size: 24px }` — the ✅ glyph.
          const Text('✅', style: TextStyle(fontSize: 24)),
          const SizedBox(height: 8),
          Text(
            _isGift ? 'Gift sent!' : 'Purchase successful!',
            style: TextStyle(color: c.text, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(widget.item.name,
              style: TextStyle(color: c.textBright, fontSize: 16)),
          // Edition number (F10): "Edition #n of max".
          if (_successEdition != null) ...[
            const SizedBox(height: 10),
            Text(
              'Edition #$_successEdition of ${_successEditionMax ?? '?'}',
              style: TextStyle(color: c.text, fontSize: 16),
            ),
          ],
          // Recovery code reveal (F10): single or per-bundle-component.
          if (_bundleCodes.isNotEmpty)
            _recoveryWarningBlock(
              c,
              title: '⚠️ SAVE YOUR RECOVERY CODES',
              children: [
                for (final b in _bundleCodes)
                  RecoveryCodeRow(code: b.code, label: b.name),
              ],
            )
          else if (_successCode != null && _successCode!.isNotEmpty)
            _recoveryWarningBlock(
              c,
              title: '⚠️ SAVE YOUR RECOVERY CODE',
              children: [
                Text(
                  'Use this code to restore this item on another pubkey:',
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
                RecoveryCodeRow(code: _successCode!, label: ''),
              ],
            ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.primary),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Close'),
            ),
          ),
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
              // "I've paid" re-verifies via shop-check → shop-claim
              // (manualCheckPayment) — the item is NEVER granted client-side.
              // Only offered when an invoice actually exists.
              if (_invoice != null && _invoice!.invoiceId.isNotEmpty)
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: c.primary),
                    onPressed: _manualCheck,
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
          // The zap modal footer: Cancel + the revealed "I've paid" action
          // (zaps.js:964-969) for a manual server-side re-check.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _cancelButton(c),
              if (_invoice!.invoiceId.isNotEmpty)
                TextButton(
                  onPressed: _manualCheck,
                  child: Text("I've paid", style: TextStyle(color: c.primary)),
                ),
            ],
          ),
        ];
    }
  }

  Widget _cancelButton(NymColors c) => TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text('Cancel', style: TextStyle(color: c.textDim)),
      );

  /// The prominent "SAVE YOUR RECOVERY CODE(S)" panel (`.nm-shop-12/.nm-shop-13`,
  /// `no-inline.css:119-122`): a warning-bordered tertiary box (F10).
  Widget _recoveryWarningBlock(
    NymColors c, {
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(15),
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.bgTertiary,
        border: Border.all(color: c.warning),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: c.warning,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}
