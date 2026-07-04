import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';
import '../../services/api/api_client.dart';
import '../../services/api/storage_sync.dart' show ShopStatus, ShopStatusActive;
import '../../services/nostr/event_signer.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';
import 'shop_catalog.dart';
import 'shop_models.dart';

/// The identity bits the shop needs to authenticate mutating `/api/storage`
/// calls (NIP-98 kind-27235). Supplied by the caller (the shop modal reads the
/// nostr controller's [Identity]); kept out of [ShopController]'s constructor so
/// the controller stays free of a nostr_controller dependency.
class ShopIdentity {
  const ShopIdentity({required this.pubkey, required this.privkey, this.signer});

  /// 64-hex identity public key.
  final String pubkey;

  /// 32-byte identity secret key (null when signing is delegated).
  final Uint8List? privkey;

  /// The active [EventSigner] (local key OR NIP-46 remote signer). When set,
  /// NIP-98 auth is signed through it — the PWA's `_signBotAuth` goes through
  /// the generic `signEvent` dispatch (pms.js:1649-1679), so remote-signer
  /// accounts authenticate shop writes exactly like a local key. [privkey]
  /// remains as a fallback for callers without a signer (tests).
  final EventSigner? signer;
}

/// Immutable snapshot of the user's shop state (owned items + active cosmetics).
class ShopState {
  const ShopState({
    this.owned = const {},
    this.active = const ActiveItems(),
    this.supply = const {},
  });

  final Map<String, OwnedItem> owned;
  final ActiveItems active;

  /// Live remaining supply per limited item id (`shop-supply` response), keyed
  /// by item id → remaining count. Empty until the limited tab fetches it.
  final Map<String, int> supply;

  bool owns(String itemId) => owned.containsKey(itemId);

  ShopState copyWith({
    Map<String, OwnedItem>? owned,
    ActiveItems? active,
    Map<String, int>? supply,
  }) =>
      ShopState(
        owned: owned ?? this.owned,
        active: active ?? this.active,
        supply: supply ?? this.supply,
      );
}

/// Persistence + cosmetic-application logic for the flair shop, ported from
/// `js/modules/shop.js` (docs/specs/04 §3.3). Backed by [KeyValueStore]:
///
/// * `nym_purchases_cache` — the full `{owned, active}` record (JSON).
/// * `nym_active_style`     — the active message style id (mirrors the PWA key).
/// * `nym_active_flair`     — the active nickname flair id.
///
/// The backend purchase/claim/redeem network calls are real `/api/storage`
/// round-trips ([buy]/[checkPaid]/[claim]/[redeem]/[transfer]); nothing is ever
/// granted client-side without server confirmation (matching the PWA).
class ShopController extends StateNotifier<ShopState> {
  ShopController(this._kv, {ApiClient? api})
      : _api = api ?? ApiClient(),
        super(const ShopState()) {
    _load();
  }

  final KeyValueStore _kv;
  final ApiClient _api;

  /// Publishes the server's pre-signed `giftEvent` DM to the DM relays so a
  /// gift/transfer recipient learns of the item immediately (shop.js
  /// `_applyShopClaim` / `executeTransferShopItem`:
  /// `sendDMToRelays(['EVENT', data.giftEvent])`). Wired by the nostr layer;
  /// null until then (the event is then dropped exactly like a PWA relay miss).
  void Function(Map<String, dynamic> giftEvent)? giftEventPublisher;

  /// Emits a system chat line (`displaySystemMessage`) — used by the pending-
  /// purchase reconciliation's "Purchase completed: …" messages. Wired by the
  /// nostr layer; null falls back to silence.
  void Function(String message)? onSystemMessage;

  /// Broadcasts the one-off `nym-presence` carrying `['shop-update','1']` after
  /// the active set changes (shop.js `publishActiveShopItems` →
  /// `publishShopUpdate`, nostr-core.js:2876). Wired by the nostr layer.
  void Function()? onActiveItemsPublished;

  /// The invoice currently on screen in the buy dialog. Reconciliation skips it
  /// so the live dialog keeps ownership of that claim (shop.js
  /// `_reconcileShopEntry` checks `this.currentShopInvoice`).
  String? activeInvoiceId;

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Load / persist
  // ---------------------------------------------------------------------------

  void _load() {
    final raw = _kv.getString(StorageKeys.purchasesCache);
    Map<String, OwnedItem> owned = {};
    ActiveItems active = const ActiveItems();
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final ownedJson = (j['owned'] as Map?)?.cast<String, dynamic>() ?? {};
        owned = ownedJson.map(
          (id, v) => MapEntry(
            id,
            OwnedItem.fromJson(id, (v as Map).cast<String, dynamic>()),
          ),
        );
        active = ActiveItems.fromJson(
          (j['active'] as Map?)?.cast<String, dynamic>(),
        );
      } catch (_) {
        // Corrupt cache — start empty rather than throw.
      }
    }
    // The single-active style/flair keys are the source of truth for those two
    // (they can be set independently of the cache), so reconcile them.
    final styleKey = _kv.getString(StorageKeys.activeStyle);
    final flairKey = _kv.getString(StorageKeys.activeFlair);
    active = active.copyWith(
      style: styleKey != null && styleKey.isNotEmpty ? styleKey : null,
      clearStyle: styleKey == null || styleKey.isEmpty,
      flair: flairKey != null && flairKey.isNotEmpty ? [flairKey] : active.flair,
    );
    state = ShopState(owned: owned, active: active);
  }

  Future<void> _persist() async {
    final ownedJson = {
      for (final e in state.owned.entries) e.key: e.value.toJson(),
    };
    final record = {
      'owned': ownedJson,
      'active': state.active.toJson(),
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    await _kv.setString(StorageKeys.purchasesCache, jsonEncode(record));

    // Mirror the two single-active keys the rest of the app reads.
    final style = state.active.style;
    if (style != null && style.isNotEmpty) {
      await _kv.setString(StorageKeys.activeStyle, style);
    } else {
      await _kv.remove(StorageKeys.activeStyle);
    }
    final flair = state.active.flair.isNotEmpty ? state.active.flair.first : '';
    if (flair.isNotEmpty) {
      await _kv.setString(StorageKeys.activeFlair, flair);
    } else {
      await _kv.remove(StorageKeys.activeFlair);
    }
  }

  // ---------------------------------------------------------------------------
  // Ownership (grant on claim / redeem)
  // ---------------------------------------------------------------------------

  /// Records ownership of [itemId] (and any bundle components). Returns the
  /// updated state. Mirrors `_applyShopClaim`.
  Future<void> grant(
    String itemId, {
    String? code,
    int? edition,
    int? editionMax,
    bool gift = false,
  }) async {
    final item = ShopCatalog.byId(itemId);
    if (item == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final owned = Map<String, OwnedItem>.from(state.owned);

    void add(String id, {String? c, int? ed, int? edMax}) {
      owned[id] = OwnedItem(
        itemId: id,
        timestamp: now,
        amountSats: ShopCatalog.byId(id)?.price ?? 0,
        code: c,
        gift: gift,
        edition: ed,
        editionMax: edMax,
      );
    }

    if (item.type == 'bundle') {
      // Bundles grant each component (each with its own code on the server; we
      // stub a single code on the bundle entry).
      add(itemId, c: code);
      for (final comp in ShopCatalog.bundleComponents(itemId)) {
        if (!owned.containsKey(comp)) add(comp);
      }
    } else {
      add(itemId, c: code, ed: edition, edMax: editionMax ?? item.maxSupply);
    }
    state = state.copyWith(owned: owned);
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // Activation (apply/persist nym_active_style / nym_active_flair)
  // ---------------------------------------------------------------------------

  /// Emits the PWA's `Activated <name>` / `Deactivated <name>` system chat line
  /// after a toggle (shop.js `activateCosmetic`/`activateMessageStyle`/
  /// `activateFlair`, :588-628 — every branch calls `displaySystemMessage`).
  void _announceToggle(String itemId, {required bool deactivated}) {
    final name = ShopCatalog.byId(itemId)?.name ?? itemId;
    onSystemMessage?.call(deactivated ? 'Deactivated $name' : 'Activated $name');
  }

  /// Toggle a message style. Only one is active at a time (`activateMessageStyle`).
  Future<void> toggleStyle(String styleId) async {
    if (!state.owns(styleId)) return;
    final active = state.active;
    final deactivated = active.style == styleId;
    final next = deactivated
        ? active.copyWith(clearStyle: true)
        : active.copyWith(style: styleId);
    state = state.copyWith(active: next);
    await _persist();
    _announceToggle(styleId, deactivated: deactivated);
  }

  /// Toggle a nickname flair. Only one is active at a time (`activateFlair`).
  Future<void> toggleFlair(String flairId) async {
    if (!state.owns(flairId)) return;
    final active = state.active;
    final isActive = active.flair.contains(flairId);
    state = state.copyWith(
      active: active.copyWith(flair: isActive ? const [] : [flairId]),
    );
    await _persist();
    _announceToggle(flairId, deactivated: isActive);
  }

  /// Toggle a cosmetic. Multiple cosmetics may be active (`activateCosmetic`).
  Future<void> toggleCosmetic(String cosmeticId) async {
    if (!state.owns(cosmeticId)) return;
    final active = state.active;
    final list = List<String>.from(active.cosmetics);
    final deactivated = list.contains(cosmeticId);
    if (deactivated) {
      list.remove(cosmeticId);
    } else {
      list.add(cosmeticId);
    }
    state = state.copyWith(active: active.copyWith(cosmetics: list));
    await _persist();
    _announceToggle(cosmeticId, deactivated: deactivated);
  }

  /// Toggle the supporter badge (`activateSupporter`).
  Future<void> toggleSupporter() async {
    if (!state.owns('supporter-badge')) return;
    final deactivated = state.active.supporter;
    state = state.copyWith(
      active: state.active.copyWith(supporter: !state.active.supporter),
    );
    await _persist();
    // shop.js:639/642 — the supporter line names the badge in full.
    onSystemMessage?.call(deactivated
        ? 'Deactivated Nymchat Supporter badge'
        : 'Activated Nymchat Supporter badge');
  }

  // ---------------------------------------------------------------------------
  // Purchase / claim / redeem / gift / transfer (real /api/storage, shop.js)
  // ---------------------------------------------------------------------------

  /// Shop actions the worker treats as single-use money ops — signed FRESH
  /// every time instead of reusing the 90s auth cache (`_signBotAuth`'s MONEY
  /// set, pms.js:1654-1658; `shop-check`/`shop-get`/`shop-set-active` are
  /// routine and cacheable).
  static const Set<String> _sensitiveActions = {
    'shop-buy-invoice',
    'shop-claim',
    'shop-transfer',
    'shop-redeem',
  };

  /// Builds the NIP-98 `auth` map for a mutating shop [action] bound to the
  /// `/api/storage` URL. Signs through the identity's [EventSigner] when one is
  /// present (the PWA's `_signBotAuth` → generic `signEvent` dispatch,
  /// pms.js:1649-1679 — so NIP-46 remote signers authenticate too), falling
  /// back to the raw privkey. Returns null only when neither can sign.
  Future<Map<String, dynamic>?> _auth(
      String action, ShopIdentity identity) async {
    final signer = identity.signer;
    if (signer != null) {
      final auth = await Nip98Auth.buildSigned(
        action: action,
        url: _api.storageUrl,
        signer: signer,
        sensitive: _sensitiveActions.contains(action),
      );
      if (auth != null) return auth;
    }
    final sk = identity.privkey;
    if (sk == null) return null;
    return Nip98Auth.build(
      action: action,
      url: _api.storageUrl,
      privkey: sk,
      pubkey: identity.pubkey,
    );
  }

  /// `shop-buy-invoice` → real bolt11 invoice (shop.js `generateShopPaymentInvoice`).
  ///
  /// Returns the [ShopInvoice] for the modal to render as a QR; the server looks
  /// up the price by [itemId] (the client never sends an amount). [recipientPubkey]
  /// (non-null + != self) makes it a gift. Throws [ApiException] / [ArgumentError]
  /// on failure; the modal tolerates this (host may be unreachable here).
  ///
  /// TODO(verify): exercise against the live `/api/storage` host (unreachable in
  /// this environment) — request/response shapes mirror shop.js byte-for-byte.
  Future<ShopInvoice> buy(
    String itemId, {
    required ShopIdentity identity,
    String? recipientPubkey,
    String? comment,
    Map<String, dynamic>? zapRequest,
  }) async {
    final auth = await _auth('shop-buy-invoice', identity);
    final isGift = recipientPubkey != null &&
        recipientPubkey.isNotEmpty &&
        recipientPubkey != identity.pubkey;
    final body = <String, dynamic>{
      'action': 'shop-buy-invoice',
      'pubkey': identity.pubkey,
      'itemId': itemId,
      if (comment != null) 'comment': comment,
      if (isGift) 'recipientPubkey': recipientPubkey,
      if (zapRequest != null) 'zapRequest': zapRequest,
      if (auth != null) 'auth': auth,
    };
    final data = await _api.storageAction(body);
    final pr = data['pr']?.toString();
    if (pr == null || pr.isEmpty) {
      throw const ShopException('Invoice unavailable');
    }
    final invoice = ShopInvoice(
      pr: pr,
      verify: data['verify']?.toString(),
      serverVerify: data['serverVerify'] == true,
      needsReceipt: data['needsReceipt'] == true,
      invoiceId: (data['invoiceId'] ?? '').toString(),
      itemId: itemId,
      isGift: isGift,
    );
    // Persist the pending purchase so a payment settled while the app is
    // killed is still reconciled + claimed on return (shop.js:1231).
    addPendingPurchase({
      'kind': 'shop',
      'invoiceId': invoice.invoiceId,
      'itemId': itemId,
      'isGift': isGift,
    });
    return invoice;
  }

  /// `shop-check` — true when the invoice is settled (shop.js `_checkShopInvoicePaid`).
  Future<bool> checkPaid(
    String invoiceId, {
    required ShopIdentity identity,
  }) async {
    try {
      final auth = await _auth('shop-check', identity);
      final data = await _api.storageAction({
        'action': 'shop-check',
        'pubkey': identity.pubkey,
        'invoiceId': invoiceId,
        if (auth != null) 'auth': auth,
      });
      return data['paid'] == true;
    } catch (_) {
      return false;
    }
  }

  /// `shop-claim` once paid (shop.js `_claimShopPurchase` → `_applyShopClaim`).
  ///
  /// Retries up to 6× / 2s on "not confirmed" (HTTP 402) exactly like the PWA.
  /// Applies the returned `{owned, active}` for a self-purchase. Returns the raw
  /// claim map (caller reads `code`/`edition`/`giftEvent`).
  Future<Map<String, dynamic>> claim(
    String invoiceId, {
    required ShopIdentity identity,
    Map<String, dynamic>? receipt,
    String? gifterNym,
  }) async {
    Map<String, dynamic>? data;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final auth = await _auth('shop-claim', identity);
        data = await _api.storageAction({
          'action': 'shop-claim',
          'pubkey': identity.pubkey,
          'invoiceId': invoiceId,
          if (receipt != null) 'receipt': receipt,
          if (gifterNym != null) 'gifterNym': gifterNym,
          if (auth != null) 'auth': auth,
        });
        break;
      } on ApiException catch (e) {
        final notConfirmed = e.statusCode == 402 ||
            RegExp('not confirmed', caseSensitive: false).hasMatch(e.body);
        if (notConfirmed && attempt < 5) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        rethrow;
      }
    }
    data ??= const {};
    await _applyShopClaim(data, identity);
    removePendingPurchase(invoiceId);
    return data;
  }

  /// Applies a `shop-claim` result locally (shop.js `_applyShopClaim`): a gift
  /// publishes the server's pre-signed `giftEvent` DM so the recipient is
  /// notified (nothing is granted to us); a self-purchase reconciles
  /// `{owned, active}`. A purchased COSMETIC additionally activates on the spot
  /// and pushes the new active set (shop.js:1356-1360).
  Future<void> _applyShopClaim(
    Map<String, dynamic> data,
    ShopIdentity identity,
  ) async {
    if (data['gift'] == true) {
      // gift → recipient gets it, not us; broadcast the notification DM
      // (shop.js:1349 `sendDMToRelays(['EVENT', data.giftEvent])`).
      final giftEvent = data['giftEvent'];
      if (giftEvent is Map) {
        try {
          giftEventPublisher?.call(giftEvent.cast<String, dynamic>());
        } catch (_) {}
      }
      return;
    }
    if (data['owned'] is Map && data['active'] is Map) {
      await applyOwnRecord(data);
    } else {
      // Older/edge response without the full record — grant from the fields.
      final itemId = data['itemId']?.toString();
      if (itemId != null) {
        final edition = data['edition'];
        await grant(
          itemId,
          code: data['code']?.toString(),
          edition: edition is Map ? (edition['n'] as num?)?.toInt() : null,
          editionMax: edition is Map ? (edition['max'] as num?)?.toInt() : null,
        );
      }
    }
    // A bought cosmetic turns on immediately: `activeCosmetics.add(itemId);
    // publishActiveShopItems(); applyShopStylesToOwnMessages()` (shop.js:
    // 1356-1360) — here the state change re-renders, and the push mirrors
    // publishActiveShopItems (D1 shop-set-active + the shop-update presence).
    final itemId = data['itemId']?.toString();
    if (itemId != null && ShopCatalog.byId(itemId)?.type == 'cosmetic') {
      final active = state.active;
      if (!active.cosmetics.contains(itemId)) {
        state = state.copyWith(
          active: active.copyWith(cosmetics: [...active.cosmetics, itemId]),
        );
        await _persist();
      }
      await publishActiveItems(identity);
    }
  }

  /// `shop-redeem {code}` (shop.js `restorePurchases` → `_applyOwnShopRecord`).
  ///
  /// The PWA performs NO client-side format validation and preserves case: any
  /// trimmed non-empty code goes to the server verbatim (shop.js:1663-1669) —
  /// the server is the only judge of code shape. Throws on failure so the
  /// caller can surface `Restore failed: <msg>`.
  Future<String?> redeem(
    String code, {
    required ShopIdentity identity,
  }) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return null;
    final auth = await _auth('shop-redeem', identity);
    final data = await _api.storageAction({
      'action': 'shop-redeem',
      'pubkey': identity.pubkey,
      'code': trimmed,
      if (auth != null) 'auth': auth,
    });
    applyOwnRecord(data);
    return data['itemId']?.toString();
  }

  /// `shop-transfer {itemId, toPubkey}` (shop.js `executeTransferShopItem`).
  /// The server returns the sender's post-transfer `{owned, active}` (item
  /// removed) plus a `giftEvent` for the recipient. Returns the raw map.
  Future<Map<String, dynamic>> transfer(
    String itemId,
    String toPubkey, {
    required ShopIdentity identity,
    String? gifterNym,
  }) async {
    final auth = await _auth('shop-transfer', identity);
    final data = await _api.storageAction({
      'action': 'shop-transfer',
      'pubkey': identity.pubkey,
      'itemId': itemId,
      'toPubkey': toPubkey,
      if (gifterNym != null) 'gifterNym': gifterNym,
      if (auth != null) 'auth': auth,
    });
    // Publish the recipient's notification DM (shop.js:1748-1750).
    final giftEvent = data['giftEvent'];
    if (giftEvent is Map) {
      try {
        giftEventPublisher?.call(giftEvent.cast<String, dynamic>());
      } catch (_) {}
    }
    await applyOwnRecord(data);
    // The transferred item may have been active — re-push the active set
    // (shop.js:1752 `publishActiveShopItems()`).
    await publishActiveItems(identity);
    return data;
  }

  /// Gifts [itemId] to [targetPubkey]: this is a `shop-buy-invoice` with
  /// `recipientPubkey` set (the PWA has no separate `shop-gift` action — gifting
  /// is settled via the normal buy→claim with a recipient). Returns the invoice
  /// to pay; the gift is delivered on `claim`.
  Future<ShopInvoice> gift(
    String itemId,
    String targetPubkey, {
    required ShopIdentity identity,
    String? comment,
    Map<String, dynamic>? zapRequest,
  }) =>
      buy(
        itemId,
        identity: identity,
        recipientPubkey: targetPubkey,
        comment: comment,
        zapRequest: zapRequest,
      );

  /// Reconciles local state from a server `{owned, active}` record (shop.js
  /// `_applyOwnShopRecord`): rebuilds [ShopState.owned] from `owned[id]` and
  /// applies the active style/flair/cosmetics/supporter.
  Future<void> applyOwnRecord(Map<String, dynamic> data) async {
    final ownedJson = data['owned'];
    final activeJson = data['active'];
    if (ownedJson is! Map && activeJson is! Map) return;

    var owned = state.owned;
    if (ownedJson is Map) {
      final next = <String, OwnedItem>{};
      ownedJson.forEach((id, info) {
        final m = info is Map ? info.cast<String, dynamic>() : <String, dynamic>{};
        next[id.toString()] = OwnedItem(
          itemId: id.toString(),
          // Server `at` is ms epoch; OwnedItem stores ms (toJson writes `at`).
          timestamp: (m['at'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
          amountSats: (m['amountSats'] as num?)?.toInt() ?? 0,
          code: m['code']?.toString(),
          gift: m['gift'] == true,
          edition: (m['edition'] as num?)?.toInt(),
          editionMax: (m['editionMax'] as num?)?.toInt(),
        );
      });
      owned = next;
    }

    var active = state.active;
    if (activeJson is Map) {
      final a = activeJson.cast<String, dynamic>();
      final flairArr = (a['flair'] as List?)?.cast<String>() ?? const [];
      active = ActiveItems(
        style: a['style']?.toString(),
        // PWA keeps only the last flair (shop.js:399).
        flair: flairArr.isNotEmpty ? [flairArr.last] : const [],
        cosmetics: (a['cosmetics'] as List?)?.cast<String>() ?? const [],
        supporter: a['supporter'] == true,
        editions: (a['editions'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), (v as num).toInt()),
            ) ??
            const {},
      );
    }

    state = state.copyWith(owned: owned, active: active);
    await _persist();
  }

  /// Pulls the authoritative `{owned, active}` shop record for the current
  /// identity from D1 (`shop-get`, storage.js:283) and applies it via
  /// [applyOwnRecord], so the user's own purchased flairs/cosmetics/style render
  /// on a fresh device (or after switching identity). Mirrors shop.js
  /// `loadShopFromServer` (shop.js:358) — an AUTHENTICATED read, signed via the
  /// identity's signer (local OR NIP-46); when nothing can sign it no-ops and
  /// the cached record stays. Best-effort: transport failure keeps local state.
  ///
  /// Call this once the identity is known at boot (see the nostr_controller
  /// wiring in the task report). The PWA invokes it on login and on identity
  /// switch (`applyCachedShopItemsToNewIdentity`, shop.js:366).
  Future<void> loadFromServer(ShopIdentity identity) async {
    final auth = await _auth('shop-get', identity);
    if (auth == null) return; // nothing can sign; keep cached record.
    try {
      final data = await _api.storageAction({
        'action': 'shop-get',
        'pubkey': identity.pubkey,
        'auth': auth,
      });
      await applyOwnRecord(data);
    } catch (_) {
      // Keep cached state (shop.js swallows and keeps the cached record).
    }
  }

  /// Pushes the user's current active items to D1 (`shop-set-active`,
  /// storage.js:288) so OTHER clients can read them via `shop-status` and render
  /// the user's flair/style/cosmetics on their messages. Mirrors shop.js
  /// `publishActiveShopItems` (shop.js:423) — call it after any activation
  /// toggle. The server filters the payload to owned items and echoes the
  /// authoritative `{active, updatedAt}`, which is re-applied locally. The PWA
  /// then also broadcasts a presence `shop-update` so others bust their cache
  /// (wire that in the controller, see the task report). AUTHENTICATED (local
  /// key or NIP-46 signer); no-ops only when nothing can sign. Best-effort.
  Future<void> publishActiveItems(ShopIdentity identity) async {
    final auth = await _auth('shop-set-active', identity);
    if (auth == null) return;
    final a = state.active;
    final payload = <String, dynamic>{
      'style': a.style,
      'flair': a.flair,
      'cosmetics': a.cosmetics,
      // supporter only counts when owned (server re-checks; mirrors shop.js:418).
      'supporter': state.owns('supporter-badge') && a.supporter,
    };
    try {
      final data = await _api.storageAction({
        'action': 'shop-set-active',
        'pubkey': identity.pubkey,
        'active': payload,
        'auth': auth,
      });
      // Re-apply the server's authoritative active record (with edition numbers).
      if (data['active'] is Map) {
        await applyOwnRecord({'active': data['active']});
      }
      // Broadcast the one-off `['shop-update','1']` presence so peers bust
      // their cached record (shop.js:428 → publishShopUpdate).
      onActiveItemsPublished?.call();
    } catch (_) {
      // Best-effort (shop.js swallows).
    }
  }

  // ---------------------------------------------------------------------------
  // Other users' active cosmetics (shop-status, public/no-auth; shop.js:445-483)
  // ---------------------------------------------------------------------------

  /// Last `shop-supply` fetch time (ms epoch); throttles refetches to 30s like
  /// the PWA's `_maybeFetchSupply`.
  int _supplyTs = 0;
  bool _supplyFetching = false;

  /// Fetches remaining supply for [itemIds] via the public `shop-supply` action
  /// (no auth) and merges it into [ShopState.supply] (shop.js `fetchShopSupply`).
  /// Tolerates transport failure (keeps the last known supply). Throttled to one
  /// fetch per 30s unless [force] is set.
  ///
  /// TODO(verify): live `/api/storage` host is unreachable in this environment.
  Future<void> fetchSupply(List<String> itemIds, {bool force = false}) async {
    if (itemIds.isEmpty || _supplyFetching) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && _supplyTs != 0 && now - _supplyTs < 30000) return;
    _supplyFetching = true;
    try {
      final data = await _api.storageAction({
        'action': 'shop-supply',
        'itemIds': itemIds,
      });
      final s = data['supply'];
      if (s is Map) {
        final next = Map<String, int>.from(state.supply);
        s.forEach((id, info) {
          final remaining = info is Map ? (info['remaining'] as num?) : null;
          if (remaining != null) next[id.toString()] = remaining.toInt();
        });
        state = state.copyWith(supply: next);
      }
      _supplyTs = DateTime.now().millisecondsSinceEpoch;
    } catch (_) {
      // Keep last known supply.
    } finally {
      _supplyFetching = false;
    }
  }

  /// Resolves the availability `{state,label}` of a limited [item] from its
  /// `startsAt`/`endsAt`/`maxSupply` + live [ShopState.supply]
  /// (shop.js `_shopItemAvailability`). Pure; safe to call from `build`.
  ShopAvailability availability(ShopItem item) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final startsAt = item.startsAt;
    if (startsAt != null && now < startsAt) {
      final d = DateTime.fromMillisecondsSinceEpoch(startsAt);
      return ShopAvailability(
        ShopAvailabilityState.soon,
        'Starts ${_shortDate(d)}',
      );
    }
    final endsAt = item.endsAt;
    if (endsAt != null && now > endsAt) {
      return const ShopAvailability(ShopAvailabilityState.ended, 'Drop ended');
    }
    final max = item.maxSupply;
    if (max != null) {
      final remaining = state.supply[item.id];
      if (remaining != null) {
        if (remaining <= 0) {
          return const ShopAvailability(
              ShopAvailabilityState.soldout, 'Sold out');
        }
        return ShopAvailability(
          ShopAvailabilityState.available,
          '$remaining / $max left',
        );
      }
      return ShopAvailability(
          ShopAvailabilityState.available, 'Limited · $max');
    }
    return const ShopAvailability(ShopAvailabilityState.available, '');
  }

  /// Locale-formatted short date (JS `toLocaleDateString()`, shop.js:816 —
  /// locale-dependent, not hardwired M/D/YYYY).
  static String _shortDate(DateTime d) => DateFormat.yMd().format(d);

  /// Invalidate the supply-fetch throttle so the next [fetchSupply] re-queries
  /// the server — called after a limited purchase changes remaining supply
  /// (shop.js sets `_shopSupplyTs = 0` post-claim).
  void invalidateSupply() => _supplyTs = 0;

  // ---------------------------------------------------------------------------
  // Pending purchases (`nym_pending_purchases`, shop.js:1364-1446): every
  // generated invoice is persisted so a payment settled while the app was
  // killed is reconciled (shop-check → shop-claim) on the next foreground.
  // ---------------------------------------------------------------------------

  /// Key the PWA persists pending purchases under (shop.js:1368).
  static const String _pendingKey = 'nym_pending_purchases';

  /// 2h TTL for a pending entry (shop.js:1403).
  static const int _pendingTtlMs = 2 * 60 * 60 * 1000;

  bool _reconciling = false;

  List<Map<String, dynamic>> _loadPendingPurchases() {
    try {
      final raw = _kv.getString(_pendingKey);
      if (raw == null || raw.isEmpty) return [];
      final arr = jsonDecode(raw);
      if (arr is! List) return [];
      return [
        for (final e in arr)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (_) {
      return [];
    }
  }

  void _savePendingPurchases(List<Map<String, dynamic>> arr) {
    try {
      // 20-entry cap, keeping the most recent (shop.js:1375 `.slice(-20)`).
      final capped = arr.length > 20 ? arr.sublist(arr.length - 20) : arr;
      _kv.setString(_pendingKey, jsonEncode(capped));
    } catch (_) {}
  }

  /// Records `{kind, invoiceId, itemId, isGift, createdAt}` (shop.js
  /// `_addPendingPurchase`). Replaces any prior entry for the same invoice.
  void addPendingPurchase(Map<String, dynamic> entry) {
    final invoiceId = entry['invoiceId']?.toString();
    if (invoiceId == null || invoiceId.isEmpty) return;
    final arr = _loadPendingPurchases()
        .where((e) => e['invoiceId'] != invoiceId)
        .toList();
    arr.add({...entry, 'createdAt': DateTime.now().millisecondsSinceEpoch});
    _savePendingPurchases(arr);
  }

  /// Drops the pending entry for [invoiceId] (shop.js `_removePendingPurchase`).
  void removePendingPurchase(String invoiceId) {
    if (invoiceId.isEmpty) return;
    _savePendingPurchases(_loadPendingPurchases()
        .where((e) => e['invoiceId'] != invoiceId)
        .toList());
  }

  /// Re-checks every persisted pending SHOP purchase against `shop-check` and
  /// finalizes any that settled while the app was closed (shop.js
  /// `reconcilePendingPurchases` → `_reconcileShopEntry`). Call on foreground /
  /// shop open. Entries older than 2h are dropped; `kind: 'credit'` entries
  /// belong to the Nymbot-credit domain and are left untouched here.
  Future<void> reconcilePendingPurchases(
    ShopIdentity identity, {
    String? gifterNym,
  }) async {
    if (_reconciling) return;
    final pending = _loadPendingPurchases();
    if (pending.isEmpty) return;
    _reconciling = true;
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      for (final entry in pending) {
        final invoiceId = entry['invoiceId']?.toString();
        if (invoiceId == null || invoiceId.isEmpty) continue;
        if (now - ((entry['createdAt'] as num?)?.toInt() ?? 0) >
            _pendingTtlMs) {
          removePendingPurchase(invoiceId);
          continue;
        }
        if (entry['kind'] != 'shop') continue; // credit entries: other domain
        try {
          await _reconcileShopEntry(entry, invoiceId, identity, gifterNym);
        } catch (_) {
          // Leave for the next foreground (shop.js:1412).
        }
      }
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _reconcileShopEntry(
    Map<String, dynamic> entry,
    String invoiceId,
    ShopIdentity identity,
    String? gifterNym,
  ) async {
    // The live buy dialog owns its own invoice (shop.js:1420).
    if (activeInvoiceId == invoiceId) return;
    if (!await checkPaid(invoiceId, identity: identity)) return;
    final itemId = entry['itemId']?.toString() ?? '';
    final item = ShopCatalog.byId(itemId);
    // claim() applies the record, publishes any giftEvent and removes the
    // pending entry (shop.js `_claimShopPurchase` → `_applyShopClaim`).
    final data =
        await claim(invoiceId, identity: identity, gifterNym: gifterNym);
    if (data['alreadyClaimed'] == true) return;
    final name = item?.name ?? 'item';
    if (data['gift'] == true) {
      onSystemMessage?.call('Gift purchase completed: $name.');
    } else {
      var msg = 'Purchase completed: $name';
      final edition = data['edition'];
      if (edition is Map && edition['n'] != null) {
        msg += ' #${edition['n']}/${edition['max']}';
      }
      msg += '.';
      final bundle = data['bundle'];
      if (bundle is List && bundle.isNotEmpty) {
        msg += ' Unlocked ${bundle.length} items.';
      } else if (data['code'] != null) {
        msg += ' Recovery code: ${data['code']}';
      }
      onSystemMessage?.call(msg);
    }
  }

  // ---------------------------------------------------------------------------
  // Purchase comment + zap request (shop.js:1448-1479).
  // ---------------------------------------------------------------------------

  /// Human-readable description of a shop purchase, used as the invoice/zap
  /// comment (shop.js `_shopPurchaseComment`).
  static String purchaseComment(ShopItem? item, {bool gift = false}) {
    if (item == null) return 'Nymchat shop purchase';
    final kind = switch (item.type) {
      'message-style' => 'Message style',
      'nickname-flair' => 'Nickname flair',
      'supporter' => 'Supporter badge',
      'cosmetic' => 'Cosmetic',
      _ => 'Shop item',
    };
    var label = '$kind: ${item.name}';
    if (gift) label += ' (gift)';
    return label;
  }

  /// Signs the NIP-57 kind-9734 zap request riding a shop purchase (shop.js
  /// `_buildShopZapRequest`): tags `['p', botPubkey]`, `['amount', msats]`,
  /// `['relays', ...first5]`; content = the purchase comment. Signed through
  /// the identity's [EventSigner] when present (the PWA signs via the generic
  /// `signEvent` dispatch, shop.js:1475 — NIP-46 included), else the raw
  /// privkey. Returns the signed event JSON, or null when signing is
  /// unavailable/fails (the PWA likewise returns null and buys without a zap
  /// request).
  static Future<Map<String, dynamic>?> buildShopZapRequest({
    required ShopIdentity identity,
    required String botPubkey,
    required List<String> relays,
    required int amountSats,
    required String comment,
  }) async {
    try {
      final unsigned = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 9734,
        tags: [
          ['p', botPubkey],
          ['amount', '${amountSats * 1000}'],
          ['relays', ...relays.take(5)],
        ],
        content: comment,
      );
      final signer = identity.signer;
      if (signer != null) return (await signer.sign(unsigned)).toJson();
      final sk = identity.privkey;
      if (sk == null) return null;
      return schnorr.finalizeEvent(unsigned, sk).toJson();
    } catch (_) {
      return null;
    }
  }

  static final RegExp _codeRe = RegExp(r'^NYM-[0-9A-F]{32}$');

  /// True when [code] matches the historical `NYM-[0-9A-F]{32}` recovery-code
  /// shape. NOT used as a redeem gate (the PWA sends any trimmed code verbatim,
  /// shop.js:1662-1669) — kept only as a display heuristic/test surface.
  static bool isValidRecoveryCode(String code) =>
      _codeRe.hasMatch(code.trim().toUpperCase());
}

/// A resolved shop bolt11 invoice (`shop-buy-invoice` response).
class ShopInvoice {
  const ShopInvoice({
    required this.pr,
    this.verify,
    this.serverVerify = false,
    this.needsReceipt = false,
    required this.invoiceId,
    required this.itemId,
    this.isGift = false,
  });

  final String pr;
  final String? verify;
  final bool serverVerify;
  final bool needsReceipt;
  final String invoiceId;
  final String itemId;
  final bool isGift;
}

/// Thrown by shop settlement helpers on a malformed/empty backend response.
class ShopException implements Exception {
  const ShopException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Provides the [ShopController] backed by the app key/value store.
final shopControllerProvider =
    StateNotifierProvider<ShopController, ShopState>((ref) {
  return ShopController(ref.watch(keyValueStoreProvider));
});

/// Cache + debounced fetch of OTHER users' active shop items from D1
/// (`shop-status`), so flairs/styles/cosmetics render on their messages and
/// nyms without a Nostr REQ — the authoritative source the PWA uses
/// (`getUserShopItems(pubkey)` → `_queueShopStatusFetch` → `_flushShopStatusQueue`,
/// shop.js:434-483). This is the canonical per-user cosmetics source; a presence
/// `shop-update` tag is only a cache-bust trigger that should call [invalidate].
///
/// The state is a `Map<pubkey, ShopStatusActive>` (`otherUsersShopItems`,
/// shop.js:268). Persisted across sessions in [StorageKeys] so cosmetics show
/// immediately on the next launch (`nym_shop_active_cache`, shop.js:290).
class OtherUsersShopController extends StateNotifier<Map<String, ShopStatusActive>> {
  OtherUsersShopController(this._kv, {ApiClient? api})
      : _api = api ?? ApiClient(),
        super(const {}) {
    _restore();
  }

  final KeyValueStore _kv;
  final ApiClient _api;

  /// localStorage key the PWA persists the other-users cache under (shop.js:271).
  static const String _cacheKey = 'nym_shop_active_cache';

  /// 24h persisted-cache TTL (shop.js:275).
  static const int _cacheMaxAgeMs = 24 * 60 * 60 * 1000;

  /// 10-minute in-memory freshness gate per pubkey (shop.js:437) — a pubkey
  /// fetched within this window isn't re-queued.
  static const int _freshMs = 600000;

  /// 600ms debounce before a queued batch flushes (shop.js:442).
  static const Duration _debounce = Duration(milliseconds: 600);

  /// The self pubkey, so we never fetch our own status (the owner reads its own
  /// record via [ShopController.loadFromServer]). Set by the wiring layer.
  String? selfPubkey;

  final Set<String> _queue = <String>{};
  final Set<String> _inFlight = <String>{};
  final Set<String> _forceFresh = <String>{};
  final Map<String, int> _fetchedAt = {};
  final Map<String, int> _updatedAt = {};
  Timer? _timer;

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

  @override
  void dispose() {
    _timer?.cancel();
    _api.dispose();
    super.dispose();
  }

  /// Active items for [pubkey] from the cache, or null when unknown. Pure — does
  /// NOT trigger a fetch (call [queue] from a side-effecting hook instead). Used
  /// by the cosmetics provider.
  ShopStatusActive? itemsFor(String pubkey) => state[pubkey.toLowerCase()];

  /// Queues [pubkey] for a batched `shop-status` lookup (shop.js
  /// `_queueShopStatusFetch`). Skips self, invalid pubkeys, in-flight pubkeys
  /// and anyone with a fresh (<10min) entry. Debounced 600ms; the flush batches
  /// up to 100 pubkeys per request.
  void queue(String pubkey) {
    final pk = pubkey.toLowerCase();
    if (pk == selfPubkey || !_hex64.hasMatch(pk)) return;
    final at = _fetchedAt[pk];
    if (at != null && DateTime.now().millisecondsSinceEpoch - at < _freshMs) {
      return;
    }
    if (_inFlight.contains(pk)) return;
    _queue.add(pk);
    _timer ??= Timer(_debounce, _flush);
  }

  /// Drops the cached entry for [pubkey] and re-queues a fresh fetch so a flair
  /// or style change shows up before the 10-minute cache expires — the PWA's
  /// `invalidateShopCache` (shop.js:302), driven by a presence `shop-update`.
  void invalidate(String pubkey) {
    final pk = pubkey.toLowerCase();
    if (pk == selfPubkey || !_hex64.hasMatch(pk)) return;
    _fetchedAt.remove(pk);
    _inFlight.remove(pk);
    _forceFresh.add(pk);
    if (state.containsKey(pk)) {
      final next = Map<String, ShopStatusActive>.from(state)..remove(pk);
      state = next;
    }
    _persistRemove(pk);
    queue(pk);
  }

  Future<void> _flush() async {
    _timer = null;
    final pubkeys = _queue.toList();
    _queue.clear();
    if (pubkeys.isEmpty) return;
    for (final pk in pubkeys) {
      _inFlight.add(pk);
    }
    final fresh = <String>[];
    for (final pk in pubkeys) {
      if (_forceFresh.remove(pk)) fresh.add(pk);
    }
    try {
      // shop-status is a PUBLIC read (withAuth === false, shop.js:457).
      final data = await _api.storageAction({
        'action': 'shop-status',
        'pubkeys': pubkeys.take(100).toList(),
        if (fresh.isNotEmpty) 'fresh': fresh,
      });
      final statuses = data['statuses'];
      if (statuses is Map) {
        final next = Map<String, ShopStatusActive>.from(state);
        final now = DateTime.now().millisecondsSinceEpoch;
        var changed = false;
        statuses.forEach((pk, st) {
          if (pk is! String || st is! Map) return;
          final key = pk.toLowerCase();
          final status = ShopStatus.fromJson(st.cast<String, dynamic>());
          _fetchedAt[key] = now;
          // Skip the re-render when the record is unchanged (shop.js:471).
          if (_updatedAt[key] == status.updatedAt && next.containsKey(key)) {
            return;
          }
          _updatedAt[key] = status.updatedAt;
          next[key] = status.active;
          _persistPut(key, status.active, status.updatedAt);
          changed = true;
        });
        if (changed) state = next;
      }
    } catch (_) {
      // Best-effort (shop.js swallows and keeps cached items).
    } finally {
      for (final pk in pubkeys) {
        _inFlight.remove(pk);
      }
    }
  }

  // --- Persistence (nym_shop_active_cache, shop.js:269-298) ------------------

  void _restore() {
    final raw = _kv.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final cache = jsonDecode(raw);
      if (cache is! Map) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final restored = <String, ShopStatusActive>{};
      cache.forEach((pk, entry) {
        if (entry is! Map) return;
        final ts = (entry['ts'] as num?)?.toInt() ?? 0;
        if (now - ts >= _cacheMaxAgeMs) return;
        final items = entry['items'];
        if (items is! Map) return;
        final key = pk.toString().toLowerCase();
        restored[key] = ShopStatusActive.fromJson(items.cast<String, dynamic>());
        _updatedAt[key] = (entry['updatedAt'] as num?)?.toInt() ?? 0;
      });
      if (restored.isNotEmpty) state = restored;
    } catch (_) {
      // Corrupt cache — ignore.
    }
  }

  Map<String, dynamic> _readCache() {
    final raw = _kv.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final c = jsonDecode(raw);
      return c is Map ? c.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  void _persistPut(String pubkey, ShopStatusActive items, int updatedAt) {
    final cache = _readCache();
    cache[pubkey] = {
      'items': {
        'style': items.style,
        'flair': items.flair,
        'cosmetics': items.cosmetics,
        'supporter': items.supporter,
        'editions': items.editions,
      },
      'ts': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': updatedAt,
    };
    _kv.setString(_cacheKey, jsonEncode(cache));
  }

  void _persistRemove(String pubkey) {
    final cache = _readCache();
    if (cache.remove(pubkey) != null) {
      _kv.setString(_cacheKey, jsonEncode(cache));
    }
  }
}

/// Provides the [OtherUsersShopController] (other users' active shop items,
/// fetched from D1 `shop-status`). Cosmetics widgets read it via
/// [userCosmeticsProvider]; the presence/render layer calls [queue]/[invalidate].
final otherUsersShopProvider = StateNotifierProvider<OtherUsersShopController,
    Map<String, ShopStatusActive>>((ref) {
  return OtherUsersShopController(ref.watch(keyValueStoreProvider));
});
