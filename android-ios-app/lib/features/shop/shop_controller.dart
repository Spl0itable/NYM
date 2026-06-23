import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../services/api/api_client.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';
import 'shop_catalog.dart';
import 'shop_models.dart';

/// The identity bits the shop needs to authenticate mutating `/api/storage`
/// calls (NIP-98 kind-27235). Supplied by the caller (the shop modal reads the
/// nostr controller's [Identity]); kept out of [ShopController]'s constructor so
/// the controller stays free of a nostr_controller dependency.
class ShopIdentity {
  const ShopIdentity({required this.pubkey, required this.privkey});

  /// 64-hex identity public key.
  final String pubkey;

  /// 32-byte identity secret key (null when signing is delegated — then real
  /// shop purchases can't be authed and fall back to the local stub).
  final Uint8List? privkey;
}

/// Immutable snapshot of the user's shop state (owned items + active cosmetics).
class ShopState {
  const ShopState({
    this.owned = const {},
    this.active = const ActiveItems(),
  });

  final Map<String, OwnedItem> owned;
  final ActiveItems active;

  bool owns(String itemId) => owned.containsKey(itemId);

  ShopState copyWith({
    Map<String, OwnedItem>? owned,
    ActiveItems? active,
  }) =>
      ShopState(
        owned: owned ?? this.owned,
        active: active ?? this.active,
      );
}

/// Persistence + cosmetic-application logic for the flair shop, ported from
/// `js/modules/shop.js` (docs/specs/04 §3.3). Backed by [KeyValueStore]:
///
/// * `nym_purchases_cache` — the full `{owned, active}` record (JSON).
/// * `nym_active_style`     — the active message style id (mirrors the PWA key).
/// * `nym_active_flair`     — the active nickname flair id.
///
/// The backend purchase/claim/redeem network calls are stubbed (see
/// [ShopController.claimAfterPayment] / [redeemCode]); everything that persists
/// or applies cosmetics is real so owned/active state round-trips correctly.
class ShopController extends StateNotifier<ShopState> {
  ShopController(this._kv, {ApiClient? api})
      : _api = api ?? ApiClient(),
        super(const ShopState()) {
    _load();
  }

  final KeyValueStore _kv;
  final ApiClient _api;

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

  /// Toggle a message style. Only one is active at a time (`activateMessageStyle`).
  Future<void> toggleStyle(String styleId) async {
    if (!state.owns(styleId)) return;
    final active = state.active;
    final next = active.style == styleId
        ? active.copyWith(clearStyle: true)
        : active.copyWith(style: styleId);
    state = state.copyWith(active: next);
    await _persist();
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
  }

  /// Toggle a cosmetic. Multiple cosmetics may be active (`activateCosmetic`).
  Future<void> toggleCosmetic(String cosmeticId) async {
    if (!state.owns(cosmeticId)) return;
    final active = state.active;
    final list = List<String>.from(active.cosmetics);
    if (list.contains(cosmeticId)) {
      list.remove(cosmeticId);
    } else {
      list.add(cosmeticId);
    }
    state = state.copyWith(active: active.copyWith(cosmetics: list));
    await _persist();
  }

  /// Toggle the supporter badge (`activateSupporter`).
  Future<void> toggleSupporter() async {
    if (!state.owns('supporter-badge')) return;
    state = state.copyWith(
      active: state.active.copyWith(supporter: !state.active.supporter),
    );
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // Purchase / claim / redeem / gift / transfer (real /api/storage, shop.js)
  // ---------------------------------------------------------------------------

  /// Builds the NIP-98 `auth` map for a mutating shop [action] bound to the
  /// `/api/storage` URL. Returns null when [identity] has no signable privkey.
  Map<String, dynamic>? _auth(String action, ShopIdentity identity) {
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
    final auth = _auth('shop-buy-invoice', identity);
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
    return ShopInvoice(
      pr: pr,
      verify: data['verify']?.toString(),
      serverVerify: data['serverVerify'] == true,
      needsReceipt: data['needsReceipt'] == true,
      invoiceId: (data['invoiceId'] ?? '').toString(),
      itemId: itemId,
      isGift: isGift,
    );
  }

  /// `shop-check` — true when the invoice is settled (shop.js `_checkShopInvoicePaid`).
  Future<bool> checkPaid(
    String invoiceId, {
    required ShopIdentity identity,
  }) async {
    try {
      final auth = _auth('shop-check', identity);
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
        final auth = _auth('shop-claim', identity);
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
    _applyShopClaim(data);
    return data;
  }

  /// Applies a `shop-claim` result locally (shop.js `_applyShopClaim`): for a
  /// self-purchase reconciles `{owned, active}`; gifts grant nothing locally.
  void _applyShopClaim(Map<String, dynamic> data) {
    if (data['gift'] == true) return; // gift → recipient gets it, not us
    if (data['owned'] is Map && data['active'] is Map) {
      applyOwnRecord(data);
    } else {
      // Older/edge response without the full record — grant from the fields.
      final itemId = data['itemId']?.toString();
      if (itemId == null) return;
      final edition = data['edition'];
      grant(
        itemId,
        code: data['code']?.toString(),
        edition: edition is Map ? (edition['n'] as num?)?.toInt() : null,
        editionMax: edition is Map ? (edition['max'] as num?)?.toInt() : null,
      );
    }
  }

  /// `shop-redeem {code}` (shop.js `restorePurchases` → `_applyOwnShopRecord`).
  /// Returns the redeemed item id, or null when the code is invalid/unknown.
  ///
  /// TODO(verify): live `/api/storage` host unreachable here; format-validates
  /// then submits the real request, tolerating transport failure.
  Future<String?> redeem(
    String code, {
    required ShopIdentity identity,
  }) async {
    final trimmed = code.trim().toUpperCase();
    if (!isValidRecoveryCode(trimmed)) return null;
    final auth = _auth('shop-redeem', identity);
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
    final auth = _auth('shop-transfer', identity);
    final data = await _api.storageAction({
      'action': 'shop-transfer',
      'pubkey': identity.pubkey,
      'itemId': itemId,
      'toPubkey': toPubkey,
      if (gifterNym != null) 'gifterNym': gifterNym,
      if (auth != null) 'auth': auth,
    });
    applyOwnRecord(data);
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

  /// Local-only optimistic grant used when the backend is unreachable in this
  /// environment (e.g. the "I've paid" manual confirmation in the modal stub).
  ///
  /// TODO(verify): real grants come from `claim`/`redeem` server responses;
  /// this keeps the UI usable offline. Mirrors the previous stub behaviour.
  Future<void> claimAfterPayment(String itemId) async {
    final item = ShopCatalog.byId(itemId);
    if (item == null) return;
    int? edition;
    if (item.maxSupply != null) {
      edition = (item.maxSupply! -
              (DateTime.now().millisecondsSinceEpoch % item.maxSupply!))
          .clamp(1, item.maxSupply!);
    }
    await grant(
      itemId,
      code: _stubCode(),
      edition: edition,
      editionMax: item.maxSupply,
    );
  }

  /// Back-compat shim: format-validate a recovery code (the modal's offline
  /// fallback). Prefer [redeem] for the real server round-trip.
  Future<bool> redeemCode(String code) async =>
      isValidRecoveryCode(code.trim().toUpperCase());

  static final RegExp _codeRe = RegExp(r'^NYM-[0-9A-F]{32}$');

  /// True when [code] matches the recovery-code format `NYM-[0-9A-F]{32}`.
  static bool isValidRecoveryCode(String code) =>
      _codeRe.hasMatch(code.trim().toUpperCase());

  String _stubCode() {
    final n = DateTime.now().microsecondsSinceEpoch;
    final hex = n.toRadixString(16).toUpperCase().padLeft(32, '0');
    return 'NYM-${hex.substring(hex.length - 32)}';
  }
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
