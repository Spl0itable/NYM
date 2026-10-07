import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../../widgets/common/keyboard_inset_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/crypto/key_format.dart' show normalizePubkeyInput;
import '../toasts/toast_center.dart';
import 'shop_purchase_policy.dart';
import '../../core/constants/relays.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/identity/modal_chrome.dart';
import '../../services/api/api_client.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../i18n/i18n.dart';
import '../nymbot/bot_credits_modal.dart' show kBotCreditsBuyNotice;
import '../nymbot/nymbot_models.dart' show CreditTier;
import '../nymbot/nymbot_providers.dart'
    show botBuyRequestProvider, botChatControllerProvider;
import 'cosmetics.dart' show CosmeticAura, cosmeticAuraFor;
import 'shop_catalog.dart';
import 'shop_controller.dart';
import 'shop_models.dart';
import 'shop_widgets.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_field.dart';

/// Live shop identity: pubkey, active signer (local or NIP-46) and privkey fallback; null when logged out.
ShopIdentity? _shopIdentity(WidgetRef ref) {
  final controller = ref.read(nostrControllerProvider);
  final id = controller.identity;
  if (id == null) return null;
  return ShopIdentity(
    pubkey: id.pubkey,
    privkey: id.privkey,
    signer: controller.signer,
  );
}

/// `nym#suffix` gifter tag so the recipient's DM names the gifter.
String? _gifterNym(WidgetRef ref) {
  final id = ref.read(nostrControllerProvider).identity;
  if (id == null) return null;
  return '${stripPubkeySuffix(id.nym)}#${getPubkeySuffix(id.pubkey)}';
}

/// The server's `{error}` from an [ApiException] body, else the exception text.
String _errorMessage(Object e) {
  if (e is ApiException) {
    try {
      final j = jsonDecode(e.body);
      if (j is Map &&
          j['error'] is String &&
          (j['error'] as String).isNotEmpty) {
        return j['error'] as String;
      }
    } catch (_) {}
    return tr('Request failed ({code})', {'code': e.statusCode});
  }
  return e.toString();
}

const String kShopCreditsText =
    'Credits pay for private messages with Nymbot. Standard and Pro credits '
    'are charged on the tokens each reply uses.';

/// Flair shop with tabbed item cards and a real Lightning invoice flow; recovery codes restore purchases.
class ShopModal extends ConsumerStatefulWidget {
  const ShopModal({super.key, this.initialTab = ShopTab.styles});

  final ShopTab initialTab;

  static Future<void> open(BuildContext context,
      {ShopTab tab = ShopTab.styles}) {
    return showNymSheet<void>(
      context,
      (_) => ShopModal(initialTab: tab),
      barrierColor: Colors.black.withValues(alpha: 0.7),
    );
  }

  @override
  ConsumerState<ShopModal> createState() => _ShopModalState();
}

class _ShopModalState extends ConsumerState<ShopModal> {
  late ShopTab _tab = widget.initialTab;
  final Map<ShopTab, GlobalKey> _tabKeys = {
    for (final t in ShopTab.values) t: GlobalKey(),
  };
  final _recoveryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealTab());
    // Refresh the authoritative record on every open, and settle purchases paid while closed.
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
    final bigText = MediaQuery.textScalerOf(context).scale(10) > 15;
    final body = Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bigText)
              Flexible(child: SingleChildScrollView(child: _header(c)))
            else
              _header(c),
            _tabs(c),
            Flexible(flex: bigText ? 2 : 1, child: _body(c)),
          ],
        ),
        ModalChrome.closeChip(c, () => Navigator.of(context).pop()),
      ],
    );
    return NymDiscardGuard(
      isDirty: () => _recoveryController.text.trim().isNotEmpty,
      child: nymSheetOr(
        context,
        body,
        (body) => KeyboardInsetDialog(
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
                    child: body,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    // Header is a column: title block above a full-width recovery row; the close chip floats separately.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: c.isLight ? const Color(0x05000000) : null,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FitWordsText(
            tr('Shop').toUpperCase(),
            textKey: const ValueKey('shopTitle'),
            style: TextStyle(
              color: c.primary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          // Where purchases happen when selling here isn't possible; a statement with no tap target.
          if (shopPurchasesDisabled) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: c.insetFill,
                border: Border.all(color: c.insetBorder),
                borderRadius: NymRadius.rsm,
              ),
              child: Text(
                tr('Flair cannot be purchased in this app. Items are bought '
                    'from the Nymchat web app in your browser. Anything you '
                    'already own works here as usual.'),
                style: TextStyle(color: c.textDim, fontSize: 12, height: 1.45),
              ),
            ),
          ],
          // Subtitle inherits the bold title weight; right room reserved for the close chip.
          Padding(
            padding: const EdgeInsets.only(right: 28),
            child: Text(
              tr('Get addon packs to change the styling of your messages '
                  'and nickname that others will see across all channels '
                  '(only in the Nymchat app).'),
              key: const ValueKey('shopSubtitle'),
              style: TextStyle(
                color: c.textDim,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 15),
          _recoveryRow(c),
        ],
      ),
    );
  }

  Widget _recoveryRow(NymColors c) {
    // The input takes the remaining width; the button hugs its label.
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _recoveryController,
            style: TextStyle(color: c.inputText, fontSize: 13),
            decoration: NymField.decoration(c,
              hint: tr('Recovery code'),
              fontSize: 13,
              radius: NymRadius.rxs,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9)),
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
          child: Text(tr('Restore'), style: TextStyle(color: c.primary)),
        ),
      ],
    );
  }

  Future<void> _restore() async {
    // No client-side format check or case-folding; the server judges the code.
    final code = _recoveryController.text.trim();
    if (code.isEmpty) {
      showToast(tr('Enter a recovery code'));
      return;
    }
    final identity = _shopIdentity(ref);
    final ctrl = ref.read(shopControllerProvider.notifier);
    String message;
    if (identity == null) {
      message = tr('Sign in to restore purchases.');
    } else {
      try {
        await ctrl.redeem(code, identity: identity);
        message = tr('✅ Shop item restored successfully!');
      } catch (e) {
        message = tr('❌ Restore failed: {error}', {'error': _errorMessage(e)});
      }
    }
    if (!mounted) return;
    showToast(message);
  }

  Widget _tabs(NymColors c) {
    // Tabs scroll horizontally at natural width so labels never shrink on phones.
    const tabs = ShopTab.values;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.1),
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      child: ScrollConfiguration(
        // No scrollbar under the tabs.
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                _tabButton(c, tabs[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _revealTab() {
    final ctx = _tabKeys[_tab]?.currentContext;
    if (!mounted || ctx == null) return;
    Scrollable.ensureVisible(ctx,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
  }

  void _selectTab(ShopTab t) {
    setState(() => _tab = t);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealTab());
    // Entering the limited tab starts the supply fetch.
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
      key: _tabKeys[t],
      onTap: () => _selectTab(t),
      child: Container(
        key: ValueKey('shopTab-${t.name}'),
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
        // Full-size label, never truncated or scaled.
        child: Text(
          t.label,
          maxLines: 1,
          softWrap: false,
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
    if (_tab == ShopTab.credits) {
      return _creditsBody(c);
    }
    final items = _itemsForTab(_tab, state);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _cardWrap(c, state, items),
    );
  }

  /// Wrapping grid of item cards; [cardBuilder] customizes the card.
  Widget _cardWrap(
    NymColors c,
    ShopState state,
    List<ShopItem> items, {
    Widget Function(ShopItem item)? cardBuilder,
  }) {
    // Fluid grid of ≥200px columns sharing each row equally, used on every tab.
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
      // The chat layout decides whether demos render as bubbles or IRC rows.
      bubble: ref.watch(settingsProvider.select((s) => s.useBubbles)),
      ownedItem: inventory ? state.owned[item.id] : null,
      availability: availability,
      // Sample Genesis edition only on the unowned preview; inventory shows the real one.
      sampleEdition: (!inventory && item.id == 'flair-genesis') ? 69 : null,
      onBuy: () => _buy(item),
      onActivate: () => _activate(item),
      onGift: () => _gift(item),
      onTransfer: () => _transfer(item),
    );
  }

  Widget _creditsBody(NymColors c) {
    final text = TextStyle(color: c.textDim, fontSize: 14, height: 1.5);
    return SingleChildScrollView(
      key: const ValueKey('shopCredits'),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _categoryTitle(c, tr('Nymbot Credits')),
          const SizedBox(height: 15),
          if (botCreditPurchasesDisabled)
            Text(tr(kBotCreditsBuyNotice), style: text)
          else ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Text(tr(kShopCreditsText), style: text),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: IntrinsicWidth(
                key: const ValueKey('shopBuyCredits'),
                child: _OrangePillButton(
                    label: tr('BUY'), onTap: _buyCredits),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _buyCredits() {
    final pro = ref.read(botChatControllerProvider).isPro;
    ref
        .read(botBuyRequestProvider.notifier)
        .request(pro ? CreditTier.pro : CreditTier.standard);
  }

  /// Limited drops with supply gating, then bundles with chips and savings.
  Widget _limitedBody(NymColors c, ShopState state) {
    final ctrl = ref.read(shopControllerProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Each section title renders only when its list is non-empty.
          if (ShopCatalog.limited.isNotEmpty) ...[
            _categoryTitle(c, tr('Limited Editions')),
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
            _categoryTitle(c, tr('Bundles')),
            const SizedBox(height: 12),
            _cardWrap(c, state, ShopCatalog.bundles),
          ],
        ],
      ),
    );
  }

  /// Inventory: live self preview, active-item summaries, then every owned item.
  Widget _inventoryBody(NymColors c, ShopState state) {
    final owned =
        state.owned.keys.map(ShopCatalog.byId).whereType<ShopItem>().toList();
    if (owned.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          tr('No items purchased yet'),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim),
        ),
      );
    }
    final active = state.active;
    final activeStyle =
        active.style != null ? ShopCatalog.byId(active.style!) : null;
    final activeFlairs =
        active.flair.map(ShopCatalog.byId).whereType<ShopItem>().toList();
    final activeCosmetics =
        active.cosmetics.map(ShopCatalog.byId).whereType<ShopItem>().toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _categoryTitle(c, tr('My Items')),
          const SizedBox(height: 12),
          _ActiveItemsPreview(active: active),
          if (activeStyle != null)
            _ActiveSummaryBlock(
              title: tr('Active Message Style'),
              // Style chip is name-only.
              chips: [_ActiveChip(name: activeStyle.name)],
            ),
          if (activeFlairs.isNotEmpty)
            _ActiveSummaryBlock(
              title: tr('Active Nickname Flair'),
              // Flair chip: name, then icon.
              chips: [
                for (final f in activeFlairs)
                  _ActiveChip(name: f.name, icon: f.icon, iconLeading: false),
              ],
            ),
          if (activeCosmetics.isNotEmpty)
            _ActiveSummaryBlock(
              title: tr('Active Special Items'),
              // Special chip: icon, then name.
              chips: [
                for (final x in activeCosmetics)
                  _ActiveChip(name: x.name, icon: x.icon, iconLeading: true),
              ],
            ),
          const SizedBox(height: 8),
          _categoryTitle(c, tr('All Purchased Items')),
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
      case ShopTab.credits:
        return const [];
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
    // Push the new active set to D1; best-effort, no-op without a signer.
    final identity = _shopIdentity(ref);
    if (identity != null) await ctrl.publishActiveItems(identity);
  }

  Future<void> _buy(ShopItem item) async {
    final identity = _shopIdentity(ref);
    final granted = await showNymSheet<bool>(
      context,
      (_) => _InvoiceDialog(item: item, identity: identity),
      barrierColor: Colors.black.withValues(alpha: 0.7),
    );
    if (granted == true && mounted) {
      showToast(tr('{name} unlocked!', {'name': item.name}));
    }
  }

  /// Gifts [item] by buying it with `recipientPubkey` set.
  Future<void> _gift(ShopItem item) async {
    final identity = _shopIdentity(ref);
    final recipient = await _promptRecipientPubkey(
      title: tr('Gift Item'),
      item: item,
      description: tr(
          "Enter the recipient's public key — an npub or a 64-character hex "
          'pubkey. You pay for the item and it lands directly in their '
          'inventory.'),
      selfPubkey: identity?.pubkey,
      selfMessage: tr('Use GET to buy an item for yourself.'),
      ctaLabel: tr('Continue'),
      showPrice: true,
    );
    if (recipient == null || !mounted) return;
    final granted = await showNymSheet<bool>(
      context,
      (_) => _InvoiceDialog(
        item: item,
        identity: identity,
        recipientPubkey: recipient,
      ),
      barrierColor: Colors.black.withValues(alpha: 0.7),
    );
    // Only a settled claim confirms the gift.
    if (granted == true && mounted) {
      showToast(tr('Gift sent: {name}', {'name': item.name}));
    }
  }

  /// Transfers an owned [item] to a recipient via `shop-transfer`.
  Future<void> _transfer(ShopItem item) async {
    final identity = _shopIdentity(ref);
    if (identity == null) {
      showToast(tr('Sign in to transfer items.'));
      return;
    }
    final recipient = await _promptRecipientPubkey(
      title: tr('Transfer Item'),
      item: item,
      description: tr(
          "Enter the recipient's public key — an npub or a 64-character hex "
          'pubkey. The item will be revoked from your inventory and assigned '
          'to theirs.'),
      selfPubkey: identity.pubkey,
      selfMessage: tr('Cannot transfer to yourself.'),
      ctaLabel: tr('Confirm'),
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
        showToast(tr('{name} transferred to {pk}...', {
          'name': item.name,
          'pk': recipient.substring(0, 8),
        }));
      }
    } catch (e) {
      if (mounted) {
        showToast(tr('Transfer failed: {error}', {'error': _errorMessage(e)}));
      }
    }
  }

  /// Recipient prompt validating 64-hex and rejecting self; returns the lowercased pubkey or null.
  Future<String?> _promptRecipientPubkey({
    required String title,
    required ShopItem item,
    required String description,
    String? selfPubkey,
    required String selfMessage,
    required String ctaLabel,
    required bool showPrice,
  }) {
    return showNymSheet<String>(
      context,
      (_) => _RecipientPubkeyDialog(
        title: title,
        item: item,
        description: description,
        selfPubkey: selfPubkey,
        selfMessage: selfMessage,
        ctaLabel: ctaLabel,
        showPrice: showPrice,
      ),
      barrierColor: Colors.black.withValues(alpha: 0.7),
    );
  }
}

class _ShopItemCard extends StatelessWidget {
  _ShopItemCard({
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
    bool? purchasesDisabled,
  }) : purchasesDisabled = purchasesDisabled ?? shopPurchasesDisabled;

  /// Hides BUY and GIFT where this platform can't sell; injectable for tests.

  final bool purchasesDisabled;

  final ShopItem item;
  final bool owned;
  final bool active;

  /// The user's chat layout, so previews match it.
  final bool bubble;

  /// Inventory cards expose a Transfer action.
  final bool inventory;
  final VoidCallback onBuy;
  final VoidCallback onActivate;
  final VoidCallback onGift;
  final VoidCallback onTransfer;

  /// Owned record for edition, acquired date and recovery code.
  final OwnedItem? ownedItem;

  /// Supply badge and soon/ended/sold-out gating.
  final ShopAvailability? availability;

  /// Sample edition on a flair preview; display only.
  final int? sampleEdition;

  bool get _isBundle => item.type == 'bundle';

  /// Not currently buyable, so BUY becomes the status label.
  bool get _blockedByAvailability =>
      availability != null && !availability!.isAvailable;

  bool get _showsSupplyBadge =>
      availability != null && availability!.label.isNotEmpty;

  /// Flair and supporter rows sit in the preview box; other demos render bare.
  bool get _boxedPreview =>
      item.type == 'nickname-flair' || item.type == 'supporter';

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final legendary = item.isLegendary;
    final card = Container(
      padding: const EdgeInsets.all(18),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // Legendary cards get a faint gold-to-pink wash.
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
          // Always tinted `--text`, legendary included.
          ShopSvgIcon(
            svg: item.icon,
            size: 32,
            color: c.text,
          ),
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
              if (ownedItem?.edition != null) ...[
                const SizedBox(width: 6),
                ShopEditionNumber(
                  edition: ownedItem!.edition!,
                  editionMax: ownedItem!.editionMax,
                ),
              ],
            ],
          ),
          // Every card type shows a left-aligned description.
          const SizedBox(height: 5),
          Text(
            item.description,
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
          if (inventory && ownedItem != null) ...[
            const SizedBox(height: 10),
            Text(
              tr('Acquired: {date}',
                  {'date': _formatDate(ownedItem!.timestamp)}),
              style: TextStyle(color: c.textDim, fontSize: 10),
            ),
          ],
          // Left-aligned in the card flow; its margin collapses to a 10px gap.
          if (_showsSupplyBadge) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: ShopSupplyBadge(availability: availability!),
            ),
          ],
          // Bundles show chips, others a preview; inventory shows none except the supporter badge row.
          if (!inventory || item.type == 'supporter') ...[
            // Collapsed CSS gaps: 10 after the description, 6 to a box after a supply badge.
            if (_showsSupplyBadge)
              SizedBox(height: _boxedPreview ? 6 : 10)
            else if (!inventory)
              const SizedBox(height: 10),
            _previewRegion(c),
          ],
          if (inventory) ...[
            // Inventory has no price footer: full-width ACTIVATE, recovery code, then TRANSFER for every purchase.
            if (item.type != 'bundle') ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: _OrangePillButton(
                  label: active ? tr('DEACTIVATE') : tr('ACTIVATE'),
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
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.glassBorder)),
              ),
              child: MediaQuery.textScalerOf(context).scale(10) > 15
                  ? Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: _footerChildren(c, wrap: true),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: _footerChildren(c),
                    ),
            ),
        ],
      ),
    );
    if (!legendary && !owned) return card;
    // Legendary ribbon clipped to the card corner (keeping the outer glow) and the OWNED pill.
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

  /// Footer order: price, BUY, GIFT.
  List<Widget> _footerChildren(NymColors c, {bool wrap = false}) {
    // Scales down so a long price never overflows.
    final priceText = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        tr('⚡ {price} sats', {'price': item.price}),
        style: const TextStyle(
          color: Color(0xFFF7931A),
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
      ),
    );
    final Widget price = wrap ? priceText : Flexible(child: priceText);
    // Owned wins over the availability label.
    if (owned && !_isBundle) {
      // Regular owned items can be gifted; limited owned items can't.
      return [
        price,
        // GIFT is a purchase too, so it goes with BUY where selling is off.
        if (availability == null && !purchasesDisabled)
          _OrangePillButton(label: tr('GIFT'), onTap: onGift),
      ];
    }
    // Unavailable limited items show only the status label.
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
    // The price still shows where selling is off.
    if (purchasesDisabled) return [price];
    return [
      price,
      _OrangePillButton(label: tr('BUY'), onTap: onBuy),
      _OrangePillButton(label: tr('GIFT'), onTap: onGift),
    ];
  }

  /// Preview region: boxed or bare, per item type.
  Widget _previewRegion(NymColors c) {
    if (_isBundle) return ShopBundlePreview(item: item);
    // Limited flair with a sample edition in a boxed row.
    if (sampleEdition != null && item.type == 'nickname-flair') {
      return ShopPreviewBox(child: _flairSamplePreview(c));
    }
    // Inventory supporter card shows a single boxed badge row.
    if (inventory && item.type == 'supporter') {
      return const ShopPreviewBox(child: SupporterBadge());
    }
    return ShopItemPreview(item: item, bubble: bubble);
  }

  /// Limited-tab flair preview with a bold nym and stamped edition.
  Widget _flairSamplePreview(NymColors c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Your_Nick ', style: TextStyle(fontWeight: FontWeight.bold)),
        FlairBadge(flairId: item.id, edition: sampleEdition),
      ],
    );
  }

  /// Locale-formatted acquired date.
  static String _formatDate(int msEpoch) =>
      DateFormat.yMd().format(DateTime.fromMillisecondsSinceEpoch(msEpoch));
}

/// `✓ OWNED` corner pill on purchased cards.
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
        tr('✓ OWNED'),
        style: TextStyle(
          color: c.secondary,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Orange pill used for BUY, GIFT and ACTIVATE.
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

/// Full-width green TRANSFER TO PUBKEY button.
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
          tr('TRANSFER TO PUBKEY'),
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

/// Live inventory preview of your nym with all active items over "This is how your messages look."
class _ActiveItemsPreview extends ConsumerWidget {
  const _ActiveItemsPreview({required this.active});

  final ActiveItems active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final supporter = active.supporter;
    // Redacted only dims the author, so it's excluded from the message cosmetics.
    final cosmetics =
        active.cosmetics.where((x) => x != 'cosmetic-redacted').toList();
    final redacted = active.cosmetics.contains('cosmetic-redacted');
    // Counts every active cosmetic, redacted included.
    final hasActive = active.style != null ||
        supporter ||
        active.cosmetics.isNotEmpty ||
        active.flair.isNotEmpty;
    if (!hasActive) return const SizedBox.shrink();

    final id = ref.watch(nostrControllerProvider).identity;
    final nym = id != null ? stripPubkeySuffix(id.nym) : tr('You');
    final suffix = id != null ? getPubkeySuffix(id.pubkey) : '';
    final flairId = active.flair.isNotEmpty ? active.flair.last : null;
    final isGenesis = flairId == 'flair-genesis';
    final edition = flairId != null ? active.editions[flairId] : null;

    // The preview follows the user's chat layout.
    final bubble = ref.watch(settingsProvider.select((s) => s.useBubbles));

    // Flair and supporter sit inside the brackets (hidden in bubbles); self color; Genesis bolds; redacted dims.
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
                style:
                    TextStyle(color: authorColor, fontWeight: FontWeight.w400),
              ),
            ]),
          ),
        ),
        if (flairId != null)
          FlairBadge(flairId: flairId, edition: edition),
        if (supporter) const SupporterBadge(),
        if (!bubble)
          Text('>',
              style:
                  TextStyle(color: authorColor, fontWeight: FontWeight.w400)),
      ],
    );

    // Redacted never blanks the sample text.
    Widget content;
    if (active.style != null &&
        ShopCatalog.styleVisuals.containsKey(active.style)) {
      content = ShopStyleBubblePreview(
        styleId: active.style!,
        text: tr('This is how your messages look.'),
        bubble: bubble,
        // Bare body text, so satoshi shows its container color.
        sampleIsChild: false,
      );
    } else if (supporter) {
      content = _SupporterContentLine(bubble: bubble);
    } else {
      content = Text(
        tr('This is how your messages look.'),
        style: TextStyle(color: c.text, fontSize: 12),
      );
    }
    // Stack every active aura, like the chat bubble.
    final auras = <CosmeticAura>[
      for (final x in cosmetics)
        if (cosmeticAuraFor(x, isLight: c.isLight) != null)
          cosmeticAuraFor(x, isLight: c.isLight)!,
    ];
    if (auras.isNotEmpty) {
      content = ShopAuraBubble(
        auras: auras,
        bubble: bubble,
        // Style or supporter content already draws its own surface.
        defaultFill: active.style == null && !supporter,
        // An active style drops some aura layers, as in the chat bubble.
        styleActive: active.style?.startsWith('style-') ?? false,
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
          Text(tr('Preview'),
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

/// Gold supporter text over a wash and bar (IRC) or a gold-tinted bubble.
class _SupporterContentLine extends StatelessWidget {
  const _SupporterContentLine({this.bubble = true});

  final bool bubble;

  @override
  Widget build(BuildContext context) {
    final isLight = context.nym.isLight;
    final text = Text(
      tr('This is how your messages look.'),
      style: TextStyle(
        color: isLight ? const Color(0xFF8A6D00) : const Color(0xFFFFD700),
        fontSize: 12,
        shadows: isLight
            ? null
            : const [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
      ),
    );
    if (!bubble) {
      // IRC wash and bar span the panel; text stays left-aligned.
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isLight
                ? const [Color(0x0FB48C00), Color(0x05B48C00)]
                : const [Color(0x0DFFD700), Color(0x05FFD700)],
          ),
          border: Border(
            left: BorderSide(
              color:
                  isLight ? const Color(0xFFB8960A) : const Color(0xFFFFD700),
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
            ? const Color(0x14B49600)
            : const Color(0x1FFFD700),
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

/// Active-item chip; special items lead with the icon, flair trails it.
class _ActiveChip {
  const _ActiveChip({required this.name, this.icon, this.iconLeading = true});

  final String name;
  final String? icon;
  final bool iconLeading;
}

/// Secondary-tinted panel with a title and chips.
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

/// Gift/transfer recipient prompt with inline 64-hex validation.
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

  /// "Continue" for gifts, "Confirm" for transfers.
  final String ctaLabel;

  /// Gifts show the price row; transfers don't.
  final bool showPrice;

  @override
  State<_RecipientPubkeyDialog> createState() => _RecipientPubkeyDialogState();
}

class _RecipientPubkeyDialogState extends State<_RecipientPubkeyDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    // npub or hex.
    final pk = normalizePubkeyInput(_controller.text);
    if (pk == null) {
      setState(() => _error = tr(
          'Invalid public key. Paste an npub or a 64-character hex pubkey.'));
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
    final body = Column(
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
                tr('{price} sats', {'price': widget.item.price}),
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
          style: TextStyle(color: c.inputText, fontSize: 13),
          decoration: NymField.decoration(c, hint: tr('Recipient npub or hex pubkey')),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style:
                const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12),
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
                child: Text(tr('Cancel'),
                    style: TextStyle(color: c.textDim)),
              ),
            ),
          ],
        ),
      ],
    );
    return NymDiscardGuard(
      isDirty: () => _controller.text.trim().isNotEmpty,
      child: nymSheetOr(
        context,
        SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), child: body),
        (body) => KeyboardInsetDialog(
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
                child: body,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Real bolt11 invoice with QR, copy and wallet; detects payment and claims; never grants client-side.
class _InvoiceDialog extends ConsumerStatefulWidget {
  const _InvoiceDialog({
    required this.item,
    required this.identity,
    this.recipientPubkey,
  });

  final ShopItem item;
  final ShopIdentity? identity;

  /// When set, a gift into [recipientPubkey]'s inventory.
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

  // Success details revealed once paid.
  bool _isGift = false;
  String? _successCode;
  int? _successEdition;
  int? _successEditionMax;

  /// Per-component recovery codes for a bundle: (name, code).
  List<({String name, String code})> _bundleCodes = const [];

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    // Close any pending NIP-57 receipt subscription.
    ref.read(nostrControllerProvider).clearShopReceiptWait();
    // Release the invoice to reconciliation, which claims late payments on the next foreground.
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
        _status = tr('Sign in to buy flair.');
      });
      return;
    }
    try {
      // Invoice comment plus the signed NIP-57 zap request.
      final comment = ShopController.purchaseComment(
        widget.item,
        gift: widget.recipientPubkey != null,
      );
      final zapRequest = await ShopController.buildShopZapRequest(
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
        _status = tr('Failed: {error}', {'error': _errorMessage(e)});
      });
    }
  }

  /// Detection: LUD-21 verify every 1s, else `shop-check` every 2s (180 tries each), else wait up to 180s for a NIP-57 receipt.
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
          paid =
              data is Map && (data['settled'] == true || data['paid'] == true);
        } catch (_) {
          // Keep polling.
        }
        if (!mounted || _settling) return;
        if (paid) {
          t.cancel();
          await _claim(inv, identity);
        } else if (checks >= 180) {
          t.cancel();
          setState(() {
            _phase = _BuyPhase.error;
            _status = tr('⏱️ Payment timeout - please check your wallet');
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
            _status = tr('Payment not detected yet — if you paid, tap "I\'ve '
                'paid" or reopen the shop shortly.');
          });
        }
      });
      return;
    }
    // Receipt mode: claim when a matching kind-9735 arrives, sending the receipt, which the worker requires.
    unawaited(() async {
      // Forwards either the matched event JSON or a legacy `true`.
      final Object detected =
          await ref.read(nostrControllerProvider).listenForShopReceipt(inv.pr);
      if (!mounted || _settling) return;
      final receipt =
          detected is Map ? Map<String, dynamic>.from(detected) : null;
      if (receipt != null || detected == true) {
        await _claim(inv, identity, receipt: receipt);
      } else {
        setState(() {
          _phase = _BuyPhase.error;
          _status = tr(
              'Payment not detected yet — if you paid, reopen the shop shortly.');
        });
      }
    }());
  }

  /// True once a claim is under way, so late poll ticks can't overwrite the view.
  bool get _settling =>
      _phase == _BuyPhase.claiming || _phase == _BuyPhase.paid;

  /// [receipt] is the matched kind-9735 event in receipt mode; other paths claim without one.
  Future<void> _claim(
    ShopInvoice inv,
    ShopIdentity identity, {
    Map<String, dynamic>? receipt,
  }) async {
    // Stop polling and close any pending receipt subscription.
    _pollTimer?.cancel();
    ref.read(nostrControllerProvider).clearShopReceiptWait();
    setState(() {
      _phase = _BuyPhase.claiming;
      _status = tr('Confirming purchase...');
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
      // A limited purchase changes supply; refresh next view.
      if (widget.item.maxSupply != null) _ctrl.invalidateSupply();
      // Never auto-dismiss, so the recovery code can be saved.
      setState(() => _phase = _BuyPhase.paid);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _BuyPhase.error;
        _status = tr('Purchase confirmation failed: {error}',
            {'error': _errorMessage(e)});
      });
    }
  }

  /// Re-checks server-side and claims if paid; never grants without the server.
  Future<void> _manualCheck() async {
    final identity = widget.identity;
    final inv = _invoice;
    if (identity == null || inv == null || inv.invoiceId.isEmpty) return;
    setState(() {
      _phase = _BuyPhase.claiming;
      _status = tr('Checking payment...');
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
        _status = tr(
            'Not paid yet — complete the payment in your wallet, then tap again.');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _BuyPhase.error;
        _status = tr('Could not check yet — try again in a moment.');
      });
    }
  }

  /// Extracts recovery code, edition and bundle codes from a claim response.
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
    // Single-item recovery code, not shown for gifts.
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
    final body = SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            recipient != null
                ? tr('Gifting: {name}', {'name': widget.item.name})
                : tr(
                    'Purchasing: {name}', {'name': widget.item.name}),
            style: TextStyle(
              color: c.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            recipient != null
                ? tr('Price: {price} sats — gift to {pk}...', {
                    'price': widget.item.price,
                    'pk': recipient.substring(0, 8),
                  })
                : tr('Price: {price} sats',
                    {'price': widget.item.price}),
            style: TextStyle(color: c.warning, fontSize: 12),
          ),
          const SizedBox(height: 16),
          ..._phaseBody(c),
        ],
      ),
    );
    return nymSheetOr(
      context,
      body,
      (body) => KeyboardInsetDialog(
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
                child: body,
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
          Text(tr('Generating invoice...'),
              style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(height: 8),
          _cancelButton(c),
        ];
      case _BuyPhase.claiming:
        return [
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(_status.isNotEmpty ? _status : tr('Confirming purchase...'),
              style: TextStyle(color: c.textDim, fontSize: 12)),
        ];
      case _BuyPhase.paid:
        return [
          const SizedBox(height: 8),
          const Text('✅', style: TextStyle(fontSize: 24)),
          const SizedBox(height: 8),
          Text(
            _isGift ? tr('Gift sent!') : tr('Purchase successful!'),
            style: TextStyle(color: c.text, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(widget.item.name,
              style: TextStyle(color: c.textBright, fontSize: 16)),
          if (_successEdition != null) ...[
            const SizedBox(height: 10),
            Text(
              tr('Edition #{n} of {max}', {
                'n': _successEdition,
                'max': _successEditionMax ?? '?',
              }),
              style: TextStyle(color: c.text, fontSize: 16),
            ),
          ],
          if (_bundleCodes.isNotEmpty)
            _recoveryWarningBlock(
              c,
              title: tr('⚠️ SAVE YOUR RECOVERY CODES'),
              children: [
                for (final b in _bundleCodes)
                  RecoveryCodeRow(code: b.code, label: b.name),
              ],
            )
          else if (_successCode != null && _successCode!.isNotEmpty)
            _recoveryWarningBlock(
              c,
              title: tr('⚠️ SAVE YOUR RECOVERY CODE'),
              children: [
                Text(
                  tr('Use this code to restore this item on another pubkey:'),
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
              child: Text(tr('Close')),
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
                  child: Text(tr('Close'), style: TextStyle(color: c.textDim)),
                ),
              ),
              // Only offered when an invoice exists; re-verifies server-side.
              if (_invoice != null && _invoice!.invoiceId.isNotEmpty)
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: c.primary),
                    onPressed: _manualCheck,
                    child: Text(tr("I've paid")),
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
            child:
                QrImageView(data: pr, size: 200, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 12),
          Text(tr('Scan with a Lightning wallet to pay.'),
              style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _copy,
                  child: Text(tr('Copy'), style: TextStyle(color: c.primary)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _openWallet,
                  child: Text(tr('Open Wallet'),
                      style: TextStyle(color: c.primary)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _cancelButton(c),
              if (_invoice!.invoiceId.isNotEmpty)
                TextButton(
                  onPressed: _manualCheck,
                  child:
                      Text(tr("I've paid"), style: TextStyle(color: c.primary)),
                ),
            ],
          ),
        ];
    }
  }

  Widget _cancelButton(NymColors c) => TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(tr('Cancel'), style: TextStyle(color: c.textDim)),
      );

  /// Prominent "save your recovery code" warning panel.
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
