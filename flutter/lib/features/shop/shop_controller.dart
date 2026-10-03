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

/// Identity for NIP-98 auth of shop writes, passed in so the controller doesn't depend on nostr_controller.
class ShopIdentity {
  const ShopIdentity(
      {required this.pubkey, required this.privkey, this.signer});

  /// 64-hex identity public key.
  final String pubkey;

  /// 32-byte secret key; null when signing is delegated.
  final Uint8List? privkey;

  /// Active signer (local or NIP-46) for NIP-98 auth; [privkey] is the fallback without one.
  final EventSigner? signer;
}

/// Immutable shop state: owned items and active cosmetics.
class ShopState {
  const ShopState({
    this.owned = const {},
    this.active = const ActiveItems(),
    this.supply = const {},
  });

  final Map<String, OwnedItem> owned;
  final ActiveItems active;

  /// Remaining supply per limited item id; empty until fetched.
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

/// Shop persistence and cosmetic activation; purchases are granted only after server confirmation.
class ShopController extends StateNotifier<ShopState> {
  ShopController(this._kv, {ApiClient? api})
      : _api = api ?? ApiClient(),
        super(const ShopState()) {
    _load();
  }

  final KeyValueStore _kv;
  final ApiClient _api;

  /// Publishes the server's pre-signed gift DM so the recipient learns immediately; null drops it.
  void Function(Map<String, dynamic> giftEvent)? giftEventPublisher;

  /// System chat line sink, e.g. for reconciled purchases.
  void Function(String message)? onSystemMessage;

  /// Broadcasts the `shop-update` presence after the active set changes.
  void Function()? onActiveItemsPublished;

  /// Invoice shown in the buy dialog, which reconciliation leaves to the dialog.
  String? activeInvoiceId;

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

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
        // Corrupt cache: start empty rather than throw.
      }
    }
    // The single-active style/flair keys are the source of truth for those two.
    final styleKey = _kv.getString(StorageKeys.activeStyle);
    final flairKey = _kv.getString(StorageKeys.activeFlair);
    active = active.copyWith(
      style: styleKey != null && styleKey.isNotEmpty ? styleKey : null,
      clearStyle: styleKey == null || styleKey.isEmpty,
      flair:
          flairKey != null && flairKey.isNotEmpty ? [flairKey] : active.flair,
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

  /// Records ownership of [itemId] and any bundle components.
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
      // Bundles grant each component under the bundle's single code.
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

  /// Emits `Activated <name>` / `Deactivated <name>` after a toggle.
  void _announceToggle(String itemId, {required bool deactivated}) {
    final name = ShopCatalog.byId(itemId)?.name ?? itemId;
    onSystemMessage
        ?.call(deactivated ? 'Deactivated $name' : 'Activated $name');
  }

  /// Only one style is active at a time.
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

  /// Only one flair is active at a time.
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

  /// Multiple cosmetics may be active.
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

  Future<void> toggleSupporter() async {
    if (!state.owns('supporter-badge')) return;
    final deactivated = state.active.supporter;
    state = state.copyWith(
      active: state.active.copyWith(supporter: !state.active.supporter),
    );
    await _persist();
    // The supporter line names the badge in full.
    onSystemMessage?.call(deactivated
        ? 'Deactivated Nymchat Supporter badge'
        : 'Activated Nymchat Supporter badge');
  }

  /// Money actions signed fresh every time instead of using the 90s auth cache.
  static const Set<String> _sensitiveActions = {
    'shop-buy-invoice',
    'shop-claim',
    'shop-transfer',
    'shop-redeem',
  };

  /// NIP-98 auth for a shop [action] via the signer, else the raw privkey; null when neither can sign.
  Future<Map<String, dynamic>?> _auth(String action, ShopIdentity identity,
      [String? payload]) async {
    final signer = identity.signer;
    if (signer != null) {
      final auth = await Nip98Auth.buildSigned(
        action: action,
        url: _api.storageUrl,
        signer: signer,
        sensitive: payload != null || _sensitiveActions.contains(action),
        extraTags: payload == null
            ? const <List<String>>[]
            : <List<String>>[
                ['payload', payload]
              ],
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
      payload: payload,
    );
  }

  /// Creates a bolt11 invoice; the server prices [itemId], and [recipientPubkey] makes it a gift.
  Future<ShopInvoice> buy(
    String itemId, {
    required ShopIdentity identity,
    String? recipientPubkey,
    String? comment,
    Map<String, dynamic>? zapRequest,
  }) async {
    final isGift = recipientPubkey != null &&
        recipientPubkey.isNotEmpty &&
        recipientPubkey != identity.pubkey;
    final body = <String, dynamic>{
      'action': 'shop-buy-invoice',
      'pubkey': identity.pubkey,
      'itemId': itemId,
      'comment': ?comment,
      if (isGift) 'recipientPubkey': recipientPubkey,
      'zapRequest': ?zapRequest,
    };
    final auth = await _auth(
        'shop-buy-invoice', identity, Nip98Auth.payloadHashHex(body));
    if (auth != null) body['auth'] = auth;
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
    // Persist so a payment settled while the app is killed is still claimed on return.
    addPendingPurchase({
      'kind': 'shop',
      'invoiceId': invoice.invoiceId,
      'itemId': itemId,
      'isGift': isGift,
    });
    return invoice;
  }

  /// True when the invoice is settled.
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
        'auth': ?auth,
      });
      return data['paid'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Claims a paid invoice, retrying up to 6x every 2s on HTTP 402; returns the raw claim map.
  Future<Map<String, dynamic>> claim(
    String invoiceId, {
    required ShopIdentity identity,
    Map<String, dynamic>? receipt,
    String? gifterNym,
  }) async {
    Map<String, dynamic>? data;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final body = <String, dynamic>{
          'action': 'shop-claim',
          'pubkey': identity.pubkey,
          'invoiceId': invoiceId,
          'receipt': ?receipt,
          'gifterNym': ?gifterNym,
        };
        final auth = await _auth(
            'shop-claim', identity, Nip98Auth.payloadHashHex(body));
        if (auth != null) body['auth'] = auth;
        data = await _api.storageAction(body);
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

  /// Gifts publish the recipient's DM; self-purchases reconcile the record, and a bought cosmetic activates at once.
  Future<void> _applyShopClaim(
    Map<String, dynamic> data,
    ShopIdentity identity,
  ) async {
    if (data['gift'] == true) {
      // Gifts go to the recipient, not us; broadcast the notification DM.
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
      // Older response without the full record: grant from the fields.
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
    // A bought cosmetic turns on immediately and the active set is pushed.
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

  /// Sends any trimmed code verbatim (case kept); the server judges its shape. Throws on failure.
  Future<String?> redeem(
    String code, {
    required ShopIdentity identity,
  }) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return null;
    final body = <String, dynamic>{
      'action': 'shop-redeem',
      'pubkey': identity.pubkey,
      'code': trimmed,
    };
    final auth = await _auth(
        'shop-redeem', identity, Nip98Auth.payloadHashHex(body));
    if (auth != null) body['auth'] = auth;
    final data = await _api.storageAction(body);
    applyOwnRecord(data);
    return data['itemId']?.toString();
  }

  /// Transfers [itemId]; returns the sender's updated record plus the recipient's gift event.
  Future<Map<String, dynamic>> transfer(
    String itemId,
    String toPubkey, {
    required ShopIdentity identity,
    String? gifterNym,
  }) async {
    final body = <String, dynamic>{
      'action': 'shop-transfer',
      'pubkey': identity.pubkey,
      'itemId': itemId,
      'toPubkey': toPubkey,
      'gifterNym': ?gifterNym,
    };
    final auth = await _auth(
        'shop-transfer', identity, Nip98Auth.payloadHashHex(body));
    if (auth != null) body['auth'] = auth;
    final data = await _api.storageAction(body);
    // Publish the recipient's notification DM.
    final giftEvent = data['giftEvent'];
    if (giftEvent is Map) {
      try {
        giftEventPublisher?.call(giftEvent.cast<String, dynamic>());
      } catch (_) {}
    }
    await applyOwnRecord(data);
    // The item may have been active, so re-push the active set.
    await publishActiveItems(identity);
    return data;
  }

  /// Gifting is a buy invoice with a recipient; the gift is delivered on claim.
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

  /// Rebuilds owned items and active cosmetics from a server `{owned, active}` record.
  Future<void> applyOwnRecord(Map<String, dynamic> data) async {
    final ownedJson = data['owned'];
    final activeJson = data['active'];
    if (ownedJson is! Map && activeJson is! Map) return;

    var owned = state.owned;
    if (ownedJson is Map) {
      final next = <String, OwnedItem>{};
      ownedJson.forEach((id, info) {
        final m =
            info is Map ? info.cast<String, dynamic>() : <String, dynamic>{};
        next[id.toString()] = OwnedItem(
          itemId: id.toString(),
          // Server `at` is ms epoch.
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
        // Keep only the last flair.
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

  /// Authenticated `shop-get` of the user's own record at boot or identity switch; no-op if nothing can sign.
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
      // Keep cached state.
    }
  }

  /// Pushes active items to D1 so others can render them; the server filters to owned items and echoes the result.
  Future<void> publishActiveItems(ShopIdentity identity) async {
    final a = state.active;
    final payload = <String, dynamic>{
      'style': a.style,
      'flair': a.flair,
      'cosmetics': a.cosmetics,
      // Supporter only counts when owned.
      'supporter': state.owns('supporter-badge') && a.supporter,
    };
    final body = <String, dynamic>{
      'action': 'shop-set-active',
      'pubkey': identity.pubkey,
      'active': payload,
    };
    final auth = await _auth(
        'shop-set-active', identity, Nip98Auth.payloadHashHex(body));
    if (auth == null) return;
    body['auth'] = auth;
    try {
      final data = await _api.storageAction(body);
      // Re-apply the server's authoritative active record.
      if (data['active'] is Map) {
        await applyOwnRecord({'active': data['active']});
      }
      // Broadcast `shop-update` so peers bust their cache.
      onActiveItemsPublished?.call();
    } catch (_) {
      // Best-effort.
    }
  }

  /// Last supply fetch time (ms), throttling refetches to 30s.
  int _supplyTs = 0;
  bool _supplyFetching = false;

  /// Public supply fetch merged into state, throttled to 30s unless [force]; failures keep the last value.
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
      // Keep the last known supply.
    } finally {
      _supplyFetching = false;
    }
  }

  /// Limited-item availability from dates and live supply; pure.
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

  /// Locale-formatted short date.
  static String _shortDate(DateTime d) => DateFormat.yMd().format(d);

  /// Reset the supply throttle after a limited purchase.
  void invalidateSupply() => _supplyTs = 0;

  // Pending purchases persist so payments settled while the app was killed are claimed on the next foreground.

  static const String _pendingKey = 'nym_pending_purchases';

  /// 2h TTL for a pending entry.
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
      // Keep the 20 most recent.
      final capped = arr.length > 20 ? arr.sublist(arr.length - 20) : arr;
      _kv.setString(_pendingKey, jsonEncode(capped));
    } catch (_) {}
  }

  /// Records a pending purchase, replacing any prior entry for the same invoice.
  void addPendingPurchase(Map<String, dynamic> entry) {
    final invoiceId = entry['invoiceId']?.toString();
    if (invoiceId == null || invoiceId.isEmpty) return;
    final arr = _loadPendingPurchases()
        .where((e) => e['invoiceId'] != invoiceId)
        .toList();
    arr.add({...entry, 'createdAt': DateTime.now().millisecondsSinceEpoch});
    _savePendingPurchases(arr);
  }

  /// Non-expired pending entries of [kind], dropping expired ones along the way.
  List<Map<String, dynamic>> pendingPurchasesOfKind(String kind) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <Map<String, dynamic>>[];
    for (final e in _loadPendingPurchases()) {
      final invoiceId = e['invoiceId']?.toString();
      if (invoiceId == null || invoiceId.isEmpty) continue;
      if (now - ((e['createdAt'] as num?)?.toInt() ?? 0) > _pendingTtlMs) {
        removePendingPurchase(invoiceId);
        continue;
      }
      if (e['kind'] == kind) out.add(e);
    }
    return out;
  }

  void removePendingPurchase(String invoiceId) {
    if (invoiceId.isEmpty) return;
    _savePendingPurchases(_loadPendingPurchases()
        .where((e) => e['invoiceId'] != invoiceId)
        .toList());
  }

  /// Finalizes pending shop purchases that settled while closed; drops entries over 2h and ignores credit entries.
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
          // Leave for the next foreground.
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
    // The live buy dialog owns its own invoice.
    if (activeInvoiceId == invoiceId) return;
    if (!await checkPaid(invoiceId, identity: identity)) return;
    final itemId = entry['itemId']?.toString() ?? '';
    final item = ShopCatalog.byId(itemId);
    // claim() applies the record, publishes any gift, and removes the pending entry.
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

  /// Purchase description used as the invoice/zap comment.
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

  /// Signs the purchase's NIP-57 zap request via the signer or privkey; null if signing fails (buy proceeds without it).
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

  /// Display heuristic for the historical `NYM-[0-9A-F]{32}` shape; not a redeem gate.
  static bool isValidRecoveryCode(String code) =>
      _codeRe.hasMatch(code.trim().toUpperCase());
}

/// A resolved shop bolt11 invoice.
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

/// Malformed or empty backend response.
class ShopException implements Exception {
  const ShopException(this.message);
  final String message;
  @override
  String toString() => message;
}

final shopControllerProvider =
    StateNotifierProvider<ShopController, ShopState>((ref) {
  return ShopController(ref.watch(keyValueStoreProvider));
});

/// Persisted cache of other users' active items, fetched in debounced `shop-status` batches.
class OtherUsersShopController
    extends StateNotifier<Map<String, ShopStatusActive>> {
  OtherUsersShopController(this._kv, {ApiClient? api})
      : _api = api ?? ApiClient(),
        super(const {}) {
    _restore();
  }

  final KeyValueStore _kv;
  final ApiClient _api;

  /// Persisted cache key for other users' items.
  static const String _cacheKey = 'nym_shop_active_cache';

  /// 24h persisted-cache TTL.
  static const int _cacheMaxAgeMs = 24 * 60 * 60 * 1000;

  /// Pubkeys fetched within 10 minutes aren't re-queued.
  static const int _freshMs = 600000;

  /// Debounce before a queued batch flushes.
  static const Duration _debounce = Duration(milliseconds: 600);

  /// Never fetch our own status; the owner reads its record via [ShopController.loadFromServer].
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

  /// Cached items for [pubkey], or null; never triggers a fetch.
  ShopStatusActive? itemsFor(String pubkey) => state[pubkey.toLowerCase()];

  /// Queues a batched `shop-status` lookup (≤100 per request), skipping self, invalid, in-flight and fresh pubkeys.
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

  /// Drops [pubkey]'s entry and refetches so changes show before the cache expires.
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
      // `shop-status` is a public read.
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
          // Skip the re-render when the record is unchanged.
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
      // Best-effort; keep cached items.
    } finally {
      for (final pk in pubkeys) {
        _inFlight.remove(pk);
      }
    }
  }

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
        restored[key] =
            ShopStatusActive.fromJson(items.cast<String, dynamic>());
        _updatedAt[key] = (entry['updatedAt'] as num?)?.toInt() ?? 0;
      });
      if (restored.isNotEmpty) state = restored;
    } catch (_) {
      // Corrupt cache: ignore.
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

final otherUsersShopProvider = StateNotifierProvider<OtherUsersShopController,
    Map<String, ShopStatusActive>>((ref) {
  return OtherUsersShopController(ref.watch(keyValueStoreProvider));
});
