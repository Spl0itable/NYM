// Cloudflare Pages Function: D1-backed user storage (flair shop, encrypted
// settings, profile mirror, PM gift-wrap archive, public channel archive).

import { ledgerCall } from "./_ledger.js";
export { NymLedger } from "./_ledger.js";
import {
  hasD1,
  replica,
  shopGet,
  shopPut,
  shopGetActiveMany,
  invoiceGet,
  invoiceHas,
  invoicePut,
  codeGet
} from "./_d1.js";
import {
  getPublicKey,
  getEventHash,
  signEvent,
  serializeEvent,
  nip44ConversationKey,
  nip44Encrypt,
  nip44Decrypt,
  botBase64Encode,
  botBase64Decode,
  hkdfExpand,
  nip44PaddedLen,
  randomTimestampNow,
  buildGiftWrappedDM,
  buildGiftWrappedDMPair,
  verifyClientAuth,
  parseNwcUri,
  invoicePaymentConfirmed,
  sanitizeInput,
  bytesToHex,
  hexToBytes,
  utf8ToBytes,
  concatBytes,
  randomBytes,
  hmac,
  sha256,
  secp256k1,
  schnorr,
  BOT_LIGHTNING_ADDRESS,
  CLIENT_CORS_HEADERS,
  isNymchatClient
} from "./_shared.js";

var SHOP_CATALOG = {
  "style-satoshi": { price: 21420, type: "message-style", tier: "legendary" },
  "style-glitch": { price: 10101, type: "message-style" },
  "style-aurora": { price: 2424, type: "message-style" },
  "style-neon": { price: 1984, type: "message-style" },
  "style-ghost": { price: 666, type: "message-style" },
  "style-matrix": { price: 1337, type: "message-style", tier: "legendary" },
  "style-fire": { price: 911, type: "message-style" },
  "style-ice": { price: 777, type: "message-style" },
  "style-rainbow": { price: 2222, type: "message-style" },
  "style-ocean": { price: 1500, type: "message-style" },
  "style-sakura": { price: 3000, type: "message-style" },
  "style-galaxy": { price: 4444, type: "message-style" },
  "style-toxic": { price: 1300, type: "message-style" },
  "style-gold": { price: 8888, type: "message-style" },
  "style-vapor": { price: 1995, type: "message-style" },
  "style-blood": { price: 1313, type: "message-style" },
  "style-royal": { price: 6000, type: "message-style" },
  "style-circuit": { price: 2048, type: "message-style" },
  "flair-crown": { price: 5000, type: "nickname-flair" },
  "flair-diamond": { price: 10000, type: "nickname-flair", tier: "legendary" },
  "flair-skull": { price: 1666, type: "nickname-flair" },
  "flair-star": { price: 2500, type: "nickname-flair" },
  "flair-lightning": { price: 2100, type: "nickname-flair" },
  "flair-heart": { price: 1111, type: "nickname-flair" },
  "flair-mask": { price: 4200, type: "nickname-flair", tier: "legendary" },
  "flair-rocket": { price: 2300, type: "nickname-flair" },
  "flair-shield": { price: 1900, type: "nickname-flair" },
  "flair-flame": { price: 1200, type: "nickname-flair" },
  "flair-snowflake": { price: 1400, type: "nickname-flair" },
  "flair-moon": { price: 1600, type: "nickname-flair" },
  "flair-sun": { price: 1500, type: "nickname-flair" },
  "flair-leaf": { price: 900, type: "nickname-flair" },
  "flair-music": { price: 1100, type: "nickname-flair" },
  "flair-eye": { price: 1800, type: "nickname-flair" },
  "flair-anchor": { price: 1000, type: "nickname-flair" },
  "flair-gem": { price: 3300, type: "nickname-flair" },
  "supporter-badge": { price: 42069, type: "supporter" },
  "cosmetic-aura-gold": { price: 3500, type: "cosmetic" },
  "cosmetic-redacted": { price: 2800, type: "cosmetic" },
  "cosmetic-aura-neon": { price: 3200, type: "cosmetic" },
  "cosmetic-aura-rainbow": { price: 11000, type: "cosmetic", tier: "legendary" },
  "cosmetic-frost": { price: 2600, type: "cosmetic" },
  "cosmetic-aura-cosmic": { price: 5000, type: "cosmetic" },
  // Legendary tier — premium animated cosmetics
  "cosmetic-aura-phoenix": { price: 12000, type: "cosmetic", tier: "legendary" },
  "cosmetic-bubble-hologram": { price: 13500, type: "cosmetic", tier: "legendary" },
  // Limited numbered editions
  "flair-genesis": { price: 25000, type: "nickname-flair", tier: "legendary", maxSupply: 100 },
  "style-eclipse": { price: 9000, type: "message-style", maxSupply: 1000, startsAt: 1735689600000, endsAt: 1798761600000 },
  "style-crt": { price: 12000, type: "message-style", tier: "legendary", maxSupply: 250, startsAt: 1735689600000, endsAt: 1798761600000 },
  // Bundles (granted as their component items, at a discount)
  "bundle-starter": { price: 3000, type: "bundle", bundle: ["flair-flame", "style-ice", "cosmetic-frost"] },
  "bundle-legendary": { price: 30000, type: "bundle", bundle: ["cosmetic-aura-phoenix", "cosmetic-aura-rainbow", "cosmetic-bubble-hologram"] },
  // Everything Pack: components filled in below from the full catalog.
  "bundle-everything": { price: 149999, type: "bundle", bundle: [] }
};

// The Everything Pack grants every non-limited, non-bundle item. Derive its
// component list from the catalog so it can never drift out of sync.
SHOP_CATALOG["bundle-everything"].bundle = Object.keys(SHOP_CATALOG).filter(function (id) {
  var c = SHOP_CATALOG[id];
  return c.type !== "bundle" && !c.maxSupply;
});

// Availability for a catalog entry given the current time. Returns null when
// purchasable, or an { error, status } describing why it is not.
function shopItemAvailability(cat, now) {
  if (!cat) return { error: "Unknown shop item.", status: 400 };
  if (typeof cat.startsAt === "number" && now < cat.startsAt) {
    return { error: "This item isn't available yet.", status: 409 };
  }
  if (typeof cat.endsAt === "number" && now > cat.endsAt) {
    return { error: "This limited drop has ended.", status: 409 };
  }
  return null;
}


function shopGenerateCode() {
  return "NYM-" + bytesToHex(randomBytes(16)).toUpperCase();
}

// Generate a BOLT11 invoice from the bot's Lightning address (LUD-21).
async function botGenerateInvoice(env, sats, zapRequest, comment) {
  var lnAddr = (env.BOT_LIGHTNING_ADDRESS || BOT_LIGHTNING_ADDRESS).split("@");
  if (lnAddr.length !== 2) return { error: "Bot Lightning address misconfigured.", status: 500 };
  var lnurlData;
  try {
    var lnRes = await fetch("https://" + lnAddr[1] + "/.well-known/lnurlp/" + lnAddr[0], { headers: { "Accept": "application/json" } });
    lnurlData = await lnRes.json();
  } catch (e) {
    return { error: "Could not reach the bot's Lightning wallet.", status: 502 };
  }
  if (!lnurlData || !lnurlData.callback) return { error: "Bot Lightning wallet returned an invalid response.", status: 502 };
  var milli = sats * 1000;
  if (milli < (lnurlData.minSendable || 0) || milli > (lnurlData.maxSendable || Infinity)) {
    return { error: "Item price is outside the bot wallet's accepted range.", status: 400 };
  }
  var cbUrl;
  try {
    cbUrl = new URL(lnurlData.callback);
    cbUrl.searchParams.set("amount", String(milli));
    if (zapRequest && lnurlData.allowsNostr && lnurlData.nostrPubkey) {
      cbUrl.searchParams.set("nostr", JSON.stringify(zapRequest));
    }
    if (comment && lnurlData.commentAllowed) {
      cbUrl.searchParams.set("comment", String(comment).slice(0, lnurlData.commentAllowed));
    }
  } catch (e) {
    return { error: "Bot Lightning wallet callback is invalid.", status: 502 };
  }
  var invData;
  try {
    var invRes = await fetch(cbUrl.toString(), { headers: { "Accept": "application/json" } });
    invData = await invRes.json();
  } catch (e) {
    return { error: "Could not generate a Lightning invoice.", status: 502 };
  }
  if (!invData || !invData.pr) return { error: (invData && invData.reason) || "Bot wallet did not return an invoice.", status: 502 };
  var hasVerify = invData.verify && /^https:\/\//i.test(invData.verify);
  var canNip57 = zapRequest && lnurlData.allowsNostr &&
    typeof lnurlData.nostrPubkey === "string" && /^[0-9a-f]{64}$/i.test(lnurlData.nostrPubkey);
  var hasNwc = !!(env.BOT_NWC_URI && parseNwcUri(env.BOT_NWC_URI));
  if (!hasVerify && !canNip57 && !hasNwc) {
    return { error: "Bot Lightning wallet supports neither LUD-21 verification nor NIP-57 zap receipts.", status: 502 };
  }
  return {
    pr: invData.pr,
    verifyMethod: hasVerify ? "lud21" : (canNip57 ? "nip57" : "nwc"),
    verifyUrl: hasVerify ? invData.verify : null,
    providerPubkey: canNip57 ? lnurlData.nostrPubkey.toLowerCase() : null,
    serverVerify: hasNwc
  };
}

// Private-action auth gate. Over the /api WebSocket the connection is
// authenticated once and its pubkey is pinned to context._wsAuthedPubkey, so
// per-request signatures are skipped. The HTTP path verifies each request.
function clientAuthOk(context, body, userPubkey) {
  if (context && context._wsAuthedPubkey) return context._wsAuthedPubkey === userPubkey;
  return clientAuthOk(context, body, userPubkey);
}

async function handleShopAction(context, body, botPrivkey, botPubkey) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_SHOP)) return json({ error: "Shop is not configured (missing DB_SHOP binding)." }, 503);

  // Public: look up other users' active items so clients can show their
  // flair/style without a Nostr REQ. No auth — read-only and non-sensitive.
  if (body.action === "shop-status") {
    var rawPks = Array.isArray(body.pubkeys) ? body.pubkeys.slice(0, 100) : [];
    var pks = [];
    for (var i = 0; i < rawPks.length; i++) {
      var pk = rawPks[i];
      if (typeof pk === "string" && /^[0-9a-f]{64}$/i.test(pk)) pks.push(pk.toLowerCase());
    }
    var forceFresh = new Set();
    if (Array.isArray(body.fresh)) {
      body.fresh.forEach(function (pk) {
        if (typeof pk === "string" && /^[0-9a-f]{64}$/i.test(pk)) forceFresh.add(pk.toLowerCase());
      });
    }
    var statuses = {};
    var cacheLookups = await Promise.all(pks.map(async function (pk) {
      if (forceFresh.has(pk)) return [pk, null];
      return [pk, await readCacheGet("/shop-status/" + pk)];
    }));
    var misses = [];
    cacheLookups.forEach(function (pair) {
      if (pair[1] && pair[1].st) statuses[pair[0]] = pair[1].st;
      else misses.push(pair[0]);
    });
    if (misses.length) {
      var actives = await shopGetActiveMany(replica(env.DB_SHOP), misses);
      misses.forEach(function (pk) {
        var st = { active: actives[pk].active, updatedAt: actives[pk].updatedAt };
        statuses[pk] = st;
        readCachePut(context, "/shop-status/" + pk, { st: st }, SHOP_READ_TTL);
      });
    }
    return json({ statuses: statuses });
  }

  // Public: remaining supply for limited (maxSupply) items so clients can show
  // "X left" / "Sold out". No auth — read-only and non-sensitive.
  if (body.action === "shop-supply") {
    var wantIds = Array.isArray(body.itemIds) ? body.itemIds.slice(0, 50) : [];
    var limitedIds = [];
    wantIds.forEach(function (id) {
      var c = SHOP_CATALOG[String(id)];
      if (c && c.maxSupply) limitedIds.push(String(id));
    });
    var supply = {};
    if (limitedIds.length) {
      var sup = await ledgerCall(env, { op: "shop-supply", itemIds: limitedIds });
      var counts = (sup && sup.counts) || {};
      limitedIds.forEach(function (id) {
        var max = SHOP_CATALOG[id].maxSupply;
        var c = counts[id] || { minted: 0, reserved: 0 };
        var used = (c.minted || 0) + (c.reserved || 0);
        supply[id] = {
          max: max,
          minted: c.minted || 0,
          remaining: Math.max(0, max - used)
        };
      });
    }
    return json({ supply: supply });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) {
    return json({ error: "Authentication failed" }, 401);
  }
  // The replay nonce protects per-request HTTP auth. Over the WebSocket the
  // connection is authenticated once, so there is no per-request nonce; the
  // Ledger Durable Object enforces double-spend safety server-side instead.
  var SHOP_MONEY_ACTIONS = { "shop-buy-invoice": 1, "shop-claim": 1, "shop-transfer": 1, "shop-redeem": 1 };
  if (!context._wsAuthedPubkey && SHOP_MONEY_ACTIONS[body.action]) {
    var rp = await ledgerCall(env, { op: "replay", id: body.auth && body.auth.id, ttl: 130 });
    if (rp && rp._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
    if (!rp || !rp.fresh) return json({ error: "This authorization was already used. Please retry." }, 401);
  }

  if (body.action === "shop-get") {
    var rec = await shopGet(env.DB_SHOP, userPubkey);
    return json({ owned: rec.owned, active: rec.active, updatedAt: rec.updatedAt });
  }

  if (body.action === "shop-set-active") {
    var rec = await shopGet(env.DB_SHOP, userPubkey);
    var want = (body.active && typeof body.active === "object") ? body.active : {};
    var nextStyle = null;
    if (typeof want.style === "string" && rec.owned[want.style] &&
      SHOP_CATALOG[want.style] && SHOP_CATALOG[want.style].type === "message-style") {
      nextStyle = want.style;
    }
    var nextFlair = Array.isArray(want.flair) ? want.flair.filter(function (id) {
      return rec.owned[id] && SHOP_CATALOG[id] && SHOP_CATALOG[id].type === "nickname-flair";
    }) : [];
    var nextCos = Array.isArray(want.cosmetics) ? want.cosmetics.filter(function (id) {
      return rec.owned[id] && SHOP_CATALOG[id] && SHOP_CATALOG[id].type === "cosmetic";
    }) : [];
    // Authoritative edition numbers (from owned entries) for any active
    // numbered-edition item, so other clients can render e.g. Genesis #42.
    var nextEditions = {};
    [nextStyle].concat(nextFlair).forEach(function (id) {
      if (id && rec.owned[id] && rec.owned[id].edition) nextEditions[id] = rec.owned[id].edition;
    });
    rec.active = {
      style: nextStyle,
      flair: nextFlair,
      cosmetics: nextCos,
      supporter: !!want.supporter && !!rec.owned["supporter-badge"],
      editions: nextEditions
    };
    await shopPut(env.DB_SHOP, userPubkey, rec);
    readCachePut(context, "/shop-status/" + userPubkey, { st: { active: rec.active, updatedAt: rec.updatedAt } }, SHOP_READ_TTL);
    return json({ active: rec.active, updatedAt: rec.updatedAt });
  }

  if (body.action === "shop-buy-invoice") {
    var itemId = String(body.itemId || "");
    var cat = SHOP_CATALOG[itemId];
    if (!cat) return json({ error: "Unknown shop item." }, 400);
    var availErr = shopItemAvailability(cat, Date.now());
    if (availErr) return json({ error: availErr.error }, availErr.status);
    var giftTo = null;
    if (body.recipientPubkey && /^[0-9a-f]{64}$/i.test(body.recipientPubkey)) {
      giftTo = body.recipientPubkey.toLowerCase();
    }
    var inv = await botGenerateInvoice(env, cat.price, body.zapRequest, body.comment);
    if (inv.error) return json({ error: inv.error }, inv.status || 502);
    var invoiceId = bytesToHex(sha256(utf8ToBytes(inv.pr)));
    // Limited editions: hold a supply slot for this invoice. The reservation
    // expires (and frees the slot) if the invoice is never paid.
    if (cat.maxSupply) {
      var resv = await ledgerCall(env, { op: "shop-reserve", itemId: itemId, max: cat.maxSupply, invoiceId: invoiceId, user: userPubkey, ttl: 1800 });
      if (resv && resv._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
      if (resv && resv.soldOut) return json({ error: "This limited edition is sold out." }, 409);
      if (!resv || resv.error) return json({ error: (resv && resv.error) || "Could not reserve this item." }, 400);
    }
    await invoicePut(env.DB_INVOICES, "shop", "pending", invoiceId, {
      pubkey: userPubkey,
      recipientPubkey: giftTo,
      itemId: itemId,
      amountSats: cat.price,
      pr: inv.pr,
      verifyMethod: inv.verifyMethod,
      verifyUrl: inv.verifyUrl,
      providerPubkey: inv.providerPubkey,
      createdAt: Date.now()
    });
    return json({
      pr: inv.pr,
      verify: inv.verifyMethod === "lud21" ? inv.verifyUrl : null,
      serverVerify: !!inv.serverVerify,
      needsReceipt: inv.verifyMethod === "nip57" && !inv.serverVerify,
      invoiceId: invoiceId
    });
  }

  if (body.action === "shop-check") {
    var scId = String(body.invoiceId || "");
    if (!/^[0-9a-f]{64}$/i.test(scId)) return json({ error: "Invalid invoice reference." }, 400);
    if (await invoiceHas(env.DB_INVOICES, "shop", "claimed", scId)) return json({ paid: true, claimed: true });
    var scRec = await invoiceGet(env.DB_INVOICES, "shop", "pending", scId);
    if (!scRec) return json({ error: "Unknown or expired invoice." }, 404);
    if (scRec.pubkey !== userPubkey) return json({ error: "This invoice belongs to a different user." }, 403);
    return json({ paid: await invoicePaymentConfirmed(env, scRec, body.receipt) });
  }

  if (body.action === "shop-claim") {
    var invoiceId = String(body.invoiceId || "");
    if (!/^[0-9a-f]{64}$/i.test(invoiceId)) return json({ error: "Invalid invoice reference." }, 400);
    var prevClaim = await invoiceGet(env.DB_INVOICES, "shop", "claimed", invoiceId);
    if (prevClaim) {
      return json({ itemId: prevClaim.itemId, code: prevClaim.code, gift: prevClaim.gift, recipient: prevClaim.pubkey, alreadyClaimed: true });
    }
    var pending = await invoiceGet(env.DB_INVOICES, "shop", "pending", invoiceId);
    if (!pending) return json({ error: "Unknown or expired invoice." }, 404);
    if (pending.pubkey !== userPubkey) return json({ error: "This invoice belongs to a different user." }, 403);
    if (!await invoicePaymentConfirmed(env, pending, body.receipt)) {
      return json({ error: "Payment not confirmed yet." }, 402);
    }
    var claimCat = SHOP_CATALOG[pending.itemId];
    if (!claimCat) return json({ error: "Unknown shop item." }, 400);
    var recipient = userPubkey;
    var isGift = false;
    if (pending.recipientPubkey && /^[0-9a-f]{64}$/i.test(pending.recipientPubkey) &&
      pending.recipientPubkey !== userPubkey) {
      recipient = pending.recipientPubkey.toLowerCase();
      isGift = true;
    }
    // Bundles grant each component item, each with its own recovery code.
    var bundleItems = null;
    if (Array.isArray(claimCat.bundle) && claimCat.bundle.length) {
      bundleItems = claimCat.bundle
        .filter(function (bid) { return SHOP_CATALOG[bid]; })
        .map(function (bid) { return { itemId: bid, code: shopGenerateCode() }; });
    }
    var code = shopGenerateCode();
    // Atomic claim-and-grant via the ledger DO (single-use invoice gate).
    var claimRes = await ledgerCall(env, {
      op: "shop-claim", invoiceId: invoiceId, recipient: recipient, itemId: pending.itemId,
      code: code, amountSats: pending.amountSats, gift: isGift,
      bundle: bundleItems,
      edition: claimCat.maxSupply ? { max: claimCat.maxSupply } : null,
      claimData: { paidBy: userPubkey, gift: isGift }
    });
    if (claimRes && claimRes._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
    if (claimRes && claimRes.alreadyClaimed) {
      var prev = claimRes.prev;
      if (prev) return json({ itemId: prev.itemId, code: prev.code, gift: prev.gift, recipient: prev.pubkey, alreadyClaimed: true });
      return json({ error: "This payment was already claimed." }, 409);
    }
    if (!claimRes || claimRes.error) return json({ error: (claimRes && claimRes.error) || "Claim failed." }, 400);
    var crec = { owned: claimRes.owned, active: claimRes.active };
    var giftEvent = null;
    if (isGift) {
      var gifterName = typeof body.gifterNym === "string" ? sanitizeInput(body.gifterNym).slice(0, 64) : "";
      var giftMsg = (gifterName ? gifterName + " gifted you " : "You've been gifted ") +
        "a Nymchat shop item. Open the Flair Shop to find it in your inventory.";
      try {
        giftEvent = buildGiftWrappedDM(giftMsg, botPrivkey, botPubkey, recipient);
      } catch (e) {
        giftEvent = null;
      }
    }
    return json({
      itemId: pending.itemId, code: code, gift: isGift, recipient: recipient, giftEvent: giftEvent,
      edition: claimRes.edition || null,
      bundle: bundleItems || null,
      owned: isGift ? undefined : crec.owned, active: isGift ? undefined : crec.active
    });
  }

  if (body.action === "shop-transfer") {
    var itemId = String(body.itemId || "");
    var toPubkey = String(body.toPubkey || "").toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(toPubkey)) return json({ error: "Invalid recipient pubkey." }, 400);
    if (toPubkey === userPubkey) return json({ error: "Cannot transfer to yourself." }, 400);
    // Atomic transfer of the item between two shop records via the ledger DO.
    var xfer = await ledgerCall(env, { op: "shop-transfer", from: userPubkey, to: toPubkey, itemId: itemId });
    if (xfer && xfer._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
    if (!xfer || xfer.error) return json({ error: (xfer && xfer.error) || "Transfer failed." }, 403);
    var fromRec = { owned: xfer.owned, active: xfer.active };
    readCacheDelete(context, "/shop-status/" + userPubkey);
    var transferEvent = null;
    try {
      var tName = typeof body.gifterNym === "string" ? sanitizeInput(body.gifterNym).slice(0, 64) : "";
      var tMsg = (tName ? tName + " transferred you " : "You've been transferred ") +
        "a Nymchat shop item. Open the Flair Shop to find it in your inventory.";
      transferEvent = buildGiftWrappedDM(tMsg, botPrivkey, botPubkey, toPubkey);
    } catch (e) {
      transferEvent = null;
    }
    return json({ ok: true, itemId: itemId, owned: fromRec.owned, active: fromRec.active, giftEvent: transferEvent });
  }

  if (body.action === "shop-redeem") {
    var code = String(body.code || "").trim().toUpperCase();
    if (!/^NYM-[0-9A-F]{32}$/.test(code)) return json({ error: "Invalid recovery code." }, 400);
    var codeData = await codeGet(env.DB_CODES, code);
    if (!codeData) return json({ error: "Unknown recovery code." }, 404);
    var redeemItem = codeData.itemId;
    if (!SHOP_CATALOG[redeemItem]) return json({ error: "Unknown shop item." }, 400);
    var prevOwner = (codeData.owner || "").toLowerCase();
    // Atomic redeem (move item from prevOwner to redeemer) via the ledger DO.
    var redeemRes = await ledgerCall(env, {
      op: "shop-redeem", code: code, itemId: redeemItem, user: userPubkey,
      prevOwner: prevOwner, createdAt: codeData.createdAt || Date.now()
    });
    if (redeemRes && redeemRes._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
    if (!redeemRes || redeemRes.error) return json({ error: (redeemRes && redeemRes.error) || "Redeem failed." }, 400);
    if (prevOwner && prevOwner !== userPubkey && /^[0-9a-f]{64}$/.test(prevOwner)) {
      readCacheDelete(context, "/shop-status/" + prevOwner);
    }
    if (redeemRes.alreadyOwner) {
      return json({ itemId: redeemItem, owned: redeemRes.owned, active: redeemRes.active, alreadyOwner: true });
    }
    return json({ itemId: redeemItem, owned: redeemRes.owned, active: redeemRes.active });
  }

  return json({ error: "Unknown action" }, 400);
}

// Encrypted user settings storage. The client encrypts each settings category
// to itself (NIP-44) before upload, so the worker only ever stores opaque
// ciphertext keyed by pubkey.
// Categories are validated by prefix/charset so the client can split data into
// many sub-category and per-group gift wraps (e.g. nymchat-settings-appearance,
// nymchat-keys-<groupId>) without enumerating each one here.
// Bound covers the longest dynamic category: nymchat-history-<64-hex groupId>-<YYYYMM>-<shard>.
var SETTINGS_CATEGORY_RE = /^nymchat-[a-z0-9-]{1,120}$/i;
// Effectively unlimited: time-bucketed group history accumulates one category
// per group per month, so the full backlog can span many thousands of wraps.
// A very high ceiling is kept only as an abuse backstop.
var SETTINGS_MAX_CATEGORIES = 50000;
var SETTINGS_MAX_BLOB = 512 * 1024;
function isValidSettingsCategory(cat) { return SETTINGS_CATEGORY_RE.test(cat); }

async function handleSettingsAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_SETTINGS)) return json({ error: "Settings storage is not configured (missing DB_SETTINGS binding)." }, 503);

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) return json({ error: "Authentication failed" }, 401);

  if (body.action === "settings-get") {
    var categories = {};
    try {
      var rs = await env.DB_SETTINGS.prepare("SELECT category, blob, updated_at FROM settings WHERE pubkey = ?").bind(userPubkey).all();
      (rs.results || []).forEach(function (r) {
        if (isValidSettingsCategory(r.category) && typeof r.blob === "string") {
          categories[r.category] = { blob: r.blob, updatedAt: r.updated_at || 0 };
        }
      });
    } catch (e) { }
    return json({ categories: categories });
  }

  if (body.action === "settings-set") {
    var cat = String(body.category || "");
    if (!isValidSettingsCategory(cat)) return json({ error: "Unknown settings category." }, 400);
    if (typeof body.blob !== "string" || !body.blob) return json({ error: "Missing settings blob." }, 400);
    if (body.blob.length > SETTINGS_MAX_BLOB) return json({ error: "Settings payload too large." }, 413);
    var contentHash = (typeof body.contentHash === "string" && /^[0-9a-f]{64}$/i.test(body.contentHash))
      ? body.contentHash.toLowerCase() : null;
    var prevDoc = null;
    try {
      prevDoc = await env.DB_SETTINGS.prepare("SELECT content_hash, updated_at FROM settings WHERE pubkey = ? AND category = ?").bind(userPubkey, cat).first();
    } catch (e) { }
    if (contentHash && prevDoc && prevDoc.content_hash === contentHash) {
      return json({ ok: true, category: cat, updatedAt: prevDoc.updated_at || 0, unchanged: true });
    }
    // Cap distinct categories per user to bound storage from runaway splitting.
    if (!prevDoc) {
      try {
        var cntRow = await env.DB_SETTINGS.prepare("SELECT COUNT(*) AS n FROM settings WHERE pubkey = ?").bind(userPubkey).first();
        if (cntRow && (cntRow.n || 0) >= SETTINGS_MAX_CATEGORIES) {
          return json({ error: "Too many settings categories." }, 429);
        }
      } catch (e) { }
    }
    var updatedAt = Date.now();
    await env.DB_SETTINGS.prepare(
      "INSERT INTO settings (pubkey, category, blob, content_hash, updated_at) VALUES (?, ?, ?, ?, ?) " +
      "ON CONFLICT(pubkey, category) DO UPDATE SET blob = excluded.blob, content_hash = excluded.content_hash, updated_at = excluded.updated_at"
    ).bind(userPubkey, cat, body.blob, contentHash, updatedAt).run();
    return json({ ok: true, category: cat, updatedAt: updatedAt });
  }

  return json({ error: "Unknown action" }, 400);
}

// Public Nostr kind 0 profile mirror. Stored as the signed event so clients can
// verify it and reconcile against live relay updates by created_at.
var PROFILE_MAX_EVENT = 64 * 1024;

function profileIsValidEvent(ev, pubkey) {
  try {
    if (!ev || typeof ev !== "object") return false;
    if (ev.kind !== 0 || ev.pubkey !== pubkey) return false;
    if (typeof ev.content !== "string" || typeof ev.id !== "string" || typeof ev.sig !== "string") return false;
    if (getEventHash(ev) !== ev.id) return false;
    return schnorr.verify(ev.sig, ev.id, ev.pubkey);
  } catch (e) {
    return false;
  }
}

async function handleProfileAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_PROFILES)) return json({ error: "Profile storage is not configured (missing DB_PROFILES binding)." }, 503);

  // Public batch read so clients can fetch profiles without a Nostr REQ.
  // Per-pubkey edge cache: hits skip D1, misses read from a replica.
  if (body.action === "profile-get") {
    var rawPks = Array.isArray(body.pubkeys) ? body.pubkeys.slice(0, 100) : [];
    var pks = [];
    for (var i = 0; i < rawPks.length; i++) {
      var pk = rawPks[i];
      if (typeof pk === "string" && /^[0-9a-f]{64}$/i.test(pk)) pks.push(pk.toLowerCase());
    }
    var cacheLookups = await Promise.all(pks.map(async function (pk) {
      var cached = await readCacheGet("/profile/" + pk);
      return [pk, cached];
    }));
    var cachedRecs = {};
    var misses = [];
    cacheLookups.forEach(function (pair) {
      if (pair[1] !== null) cachedRecs[pair[0]] = pair[1].rec || null;
      else misses.push(pair[0]);
    });
    var freshRecs = {};
    if (misses.length) {
      try {
        var ph = misses.map(function () { return "?"; }).join(",");
        var rs = await replica(env.DB_PROFILES).prepare("SELECT pubkey, event, updated_at FROM profiles WHERE pubkey IN (" + ph + ")").bind(...misses).all();
        (rs.results || []).forEach(function (r) {
          var ev = null;
          try { ev = JSON.parse(r.event); } catch (e) { ev = null; }
          if (ev) freshRecs[r.pubkey] = { event: ev, updatedAt: r.updated_at || 0 };
        });
      } catch (e) { }
    }
    var profEncoder = new TextEncoder();
    var profStream = new ReadableStream({
      start(controller) {
        pks.forEach(function (pk) {
          var rec;
          if (Object.prototype.hasOwnProperty.call(cachedRecs, pk)) {
            rec = cachedRecs[pk];
          } else {
            rec = freshRecs[pk] || null;
            readCachePut(context, "/profile/" + pk, { rec: rec }, PROFILE_READ_TTL);
          }
          controller.enqueue(profEncoder.encode(JSON.stringify([pk, rec]) + "\n"));
        });
        try { controller.close(); } catch (_) { }
      }
    });
    return new Response(profStream, {
      status: 200,
      headers: { "Content-Type": "application/x-ndjson", ...CLIENT_CORS_HEADERS }
    });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) return json({ error: "Authentication failed" }, 401);

  if (body.action === "profile-set") {
    var ev = body.event;
    if (!profileIsValidEvent(ev, userPubkey)) return json({ error: "Invalid profile event." }, 400);
    if (JSON.stringify(ev).length > PROFILE_MAX_EVENT) return json({ error: "Profile too large." }, 413);
    // Keep only the newest profile, ordered by the event's own created_at.
    try {
      var prev = await env.DB_PROFILES.prepare("SELECT created_at, updated_at FROM profiles WHERE pubkey = ?").bind(userPubkey).first();
      if (prev && (prev.created_at || 0) >= (ev.created_at || 0)) {
        return json({ ok: true, updatedAt: prev.updated_at || 0, stale: true });
      }
    } catch (e) { }
    var updatedAt = Date.now();
    await env.DB_PROFILES.prepare(
      "INSERT INTO profiles (pubkey, created_at, updated_at, event) VALUES (?, ?, ?, ?) " +
      "ON CONFLICT(pubkey) DO UPDATE SET created_at = excluded.created_at, updated_at = excluded.updated_at, event = excluded.event"
    ).bind(userPubkey, ev.created_at || 0, updatedAt, JSON.stringify(ev)).run();
    // Refresh the edge cache so the new profile is served immediately.
    readCachePut(context, "/profile/" + userPubkey, { rec: { event: ev, updatedAt: updatedAt } }, PROFILE_READ_TTL);
    return json({ ok: true, updatedAt: updatedAt });
  }

  return json({ error: "Unknown action" }, 400);
}

var PM_EVENT_MAX = 96 * 1024;
var CHANNEL_EVENT_MAX = 64 * 1024;
var CHANNEL_TTL_MS = 24 * 60 * 60 * 1000;
var ZAP_EVENT_MAX = 32 * 1024;

// Read-through edge cache for PUBLIC reads (channel-get, profile-get) so many
// stateless workers serve them from the per-colo cache instead of hitting D1.
var READ_CACHE_HOST = "https://nymchat-read.invalid";
var CHANNEL_READ_TTL = 45;
var PROFILE_READ_TTL = 300;
var SHOP_READ_TTL = 300;
function readCacheRequest(path) {
  return new Request(READ_CACHE_HOST + path, { method: "GET" });
}
async function readCacheGet(path) {
  try {
    var hit = await caches.default.match(readCacheRequest(path));
    if (!hit) return null;
    return await hit.json();
  } catch (e) { return null; }
}
function readCachePut(context, path, obj, ttlSeconds) {
  try {
    var headers = new Headers();
    headers.set("Content-Type", "application/json");
    headers.set("Cache-Control", "public, max-age=" + (ttlSeconds || 60));
    var op = caches.default.put(readCacheRequest(path), new Response(JSON.stringify(obj), { headers: headers }));
    if (context && context.waitUntil) context.waitUntil(op);
  } catch (e) { }
}
async function readCacheGetRaw(path) {
  try {
    var hit = await caches.default.match(readCacheRequest(path));
    if (!hit) return null;
    return await hit.text();
  } catch (e) { return null; }
}
function readCachePutRaw(context, path, bodyText, contentType, ttlSeconds) {
  try {
    var headers = new Headers();
    headers.set("Content-Type", contentType || "text/plain");
    headers.set("Cache-Control", "public, max-age=" + (ttlSeconds || 60));
    var op = caches.default.put(readCacheRequest(path), new Response(bodyText, { headers: headers }));
    if (context && context.waitUntil) context.waitUntil(op);
  } catch (e) { }
}
function readCacheDelete(context, path) {
  try {
    var op = caches.default.delete(readCacheRequest(path));
    if (context && context.waitUntil) context.waitUntil(op);
  } catch (e) { }
}

// Channel names become D1 row keys; keep them to a safe, bounded charset.
function archiveSanitizeChannel(name) {
  if (typeof name !== "string") return "";
  return name.trim().toLowerCase().replace(/[^\p{L}\p{N}_\-.]/gu, "").slice(0, 80);
}

// A gift wrap is storable for a user only if it is a kind 1059/1060 event that
// is cryptographically valid and addressed to that user via a `p` tag.
function pmIsValidWrapForUser(ev, pubkey) {
  try {
    if (!ev || typeof ev !== "object") return false;
    if (ev.kind !== 1059 && ev.kind !== 1060) return false;
    if (typeof ev.id !== "string" || typeof ev.sig !== "string" || typeof ev.pubkey !== "string") return false;
    if (typeof ev.content !== "string" || !Array.isArray(ev.tags)) return false;
    if (ev.tags.some(function (t) { return Array.isArray(t) && t[0] === "d"; })) return false;
    var addressed = ev.tags.some(function (t) {
      return Array.isArray(t) && t[0] === "p" && typeof t[1] === "string" && t[1].toLowerCase() === pubkey;
    });
    if (!addressed) return false;
    if (getEventHash(ev) !== ev.id) return false;
    return schnorr.verify(ev.sig, ev.id, ev.pubkey);
  } catch (e) { return false; }
}

async function handlePmAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_PM)) return json({ error: "PM storage is not configured (missing DB_PM binding)." }, 503);

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) return json({ error: "Authentication failed" }, 401);

  // Upload one or more gift wraps addressed to the authenticated user. The
  // primary key (pubkey, id) makes re-uploads free no-ops via INSERT OR IGNORE.
  if (body.action === "pm-put") {
    var events = Array.isArray(body.events) ? body.events.slice(0, 100)
      : (body.event ? [body.event] : []);
    var now = Date.now();
    var stmt = env.DB_PM.prepare("INSERT OR IGNORE INTO pm (pubkey, id, created_at, event, stored_at) VALUES (?, ?, ?, ?, ?)");
    var batch = [];
    for (var i = 0; i < events.length; i++) {
      var ev = events[i];
      if (!pmIsValidWrapForUser(ev, userPubkey)) continue;
      if (JSON.stringify(ev).length > PM_EVENT_MAX) continue;
      batch.push(stmt.bind(userPubkey, ev.id, ev.created_at || 0, JSON.stringify(ev), now));
    }
    var added = 0;
    if (batch.length) {
      var res = await env.DB_PM.batch(batch);
      res.forEach(function (r) { added += (r.meta && r.meta.changes) || 0; });
    }
    return json({ ok: true, added: added });
  }

  if (body.action === "pm-get") {
    var since = Number(body.since) || 0;
    var before = Number(body.before) || 0;
    var limit = Number(body.limit);
    if (!Number.isFinite(limit) || limit <= 0) limit = 1000;
    if (limit > 1000) limit = 1000;
    var sql = "SELECT event FROM pm WHERE pubkey = ? AND created_at >= ?";
    var binds = [userPubkey, since];
    if (before) { sql += " AND created_at < ?"; binds.push(before); }
    sql += " ORDER BY created_at DESC LIMIT ?";
    binds.push(limit);
    var rows = [];
    try { rows = (await replica(env.DB_PM).prepare(sql).bind(...binds).all()).results || []; } catch (e) { rows = []; }
    var hasMore = rows.length >= limit;
    var pmEncoder = new TextEncoder();
    var pmStream = new ReadableStream({
      start(controller) {
        for (var j = 0; j < rows.length; j++) {
          controller.enqueue(pmEncoder.encode(rows[j].event + "\n"));
        }
        try { controller.close(); } catch (_) { }
      }
    });
    return new Response(pmStream, {
      status: 200,
      headers: {
        "Content-Type": "application/x-ndjson",
        "X-Has-More": hasMore ? "1" : "0",
        "Access-Control-Expose-Headers": "X-Has-More",
        ...CLIENT_CORS_HEADERS
      }
    });
  }

  // Delete the user's own stored wraps (e.g. after a NIP-09 kind 5). Rows live
  // under the authenticated user's own pubkey, so ownership is implicit.
  if (body.action === "pm-delete") {
    var delIds = Array.isArray(body.ids) ? body.ids.slice(0, 200) : [];
    var clean = [];
    for (var k = 0; k < delIds.length; k++) {
      var did = delIds[k];
      if (typeof did === "string" && /^[0-9a-f]{64}$/i.test(did)) clean.push(did.toLowerCase());
    }
    var removed = 0;
    if (clean.length) {
      var ph2 = clean.map(function () { return "?"; }).join(",");
      try {
        var dr = await env.DB_PM.prepare("DELETE FROM pm WHERE pubkey = ? AND id IN (" + ph2 + ")").bind(userPubkey, ...clean).run();
        removed = (dr.meta && dr.meta.changes) || 0;
      } catch (e) { }
    }
    return json({ ok: true, removed: removed });
  }

  return json({ error: "Unknown action" }, 400);
}

async function handleChannelAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_CHANNELS)) return json({ error: "Channel storage is not configured (missing DB_CHANNELS binding)." }, 503);

  // Public read: hydrate a channel's recent history. No auth (channels are
  // public); the worker's origin gate already limits this to Nymchat clients.
  if (body.action === "channel-get") {
    var name = archiveSanitizeChannel(body.channel);
    if (!name) return json({ error: "Invalid channel." }, 400);
    var minTsSec = Math.floor((Date.now() - CHANNEL_TTL_MS) / 1000);
    var since = Number(body.since) || 0;
    var floorSec = since > minTsSec ? since : minTsSec;
    var ndjsonHeaders = { "Content-Type": "application/x-ndjson", ...CLIENT_CORS_HEADERS };
    if (!since) {
      var cachedBody = await readCacheGetRaw("/channel/" + name);
      if (cachedBody !== null) {
        return new Response(cachedBody, { status: 200, headers: ndjsonHeaders });
      }
    }
    var rows = [];
    try {
      rows = (await replica(env.DB_CHANNELS).prepare(
        "SELECT id, kind, json FROM events WHERE channel = ? AND created_at >= ? ORDER BY created_at DESC LIMIT 500"
      ).bind(name, floorSec).all()).results || [];
    } catch (e) { rows = []; }
    var zapRows = [];
    if (rows.length) {
      var targetIds = rows.filter(function (r) {
        return (r.kind === 20000 || r.kind === 23333) && typeof r.id === "string";
      }).map(function (r) { return r.id; });
      if (targetIds.length) {
        try {
          var zph = targetIds.map(function () { return "?"; }).join(",");
          zapRows = (await replica(env.DB_CHANNELS).prepare(
            "SELECT json FROM zaps WHERE target_id IN (" + zph + ") ORDER BY created_at DESC LIMIT 1000"
          ).bind(...targetIds).all()).results || [];
        } catch (e) { zapRows = []; }
      }
    }
    var encoder = new TextEncoder();
    var cacheBuf = !since ? [] : null;
    var stream = new ReadableStream({
      start(controller) {
        for (var i = 0; i < rows.length; i++) {
          var line = rows[i].json + "\n";
          controller.enqueue(encoder.encode(line));
          if (cacheBuf) cacheBuf.push(line);
        }
        for (var z = 0; z < zapRows.length; z++) {
          var zline = zapRows[z].json + "\n";
          controller.enqueue(encoder.encode(zline));
          if (cacheBuf) cacheBuf.push(zline);
        }
        try { controller.close(); } catch (_) { }
        if (cacheBuf) {
          readCachePutRaw(context, "/channel/" + name, cacheBuf.join(""), "application/x-ndjson", CHANNEL_READ_TTL);
        }
      }
    });
    return new Response(stream, { status: 200, headers: ndjsonHeaders });
  }

  // Public read: lightweight recent-activity counts for many channels at once.
  if (body.action === "channel-activity") {
    var reqNames = Array.isArray(body.channels) ? body.channels : [];
    var wanted = [];
    var seenNames = new Set();
    for (var ai = 0; ai < reqNames.length && wanted.length < 200; ai++) {
      var anm = archiveSanitizeChannel(reqNames[ai]);
      if (!anm || seenNames.has(anm)) continue;
      seenNames.add(anm);
      wanted.push(anm);
    }
    var activity = {};
    if (wanted.length === 0) return json({ activity: activity });
    var nowSecA = Math.floor(Date.now() / 1000);
    var minTsA = nowSecA - 24 * 3600;
    var misses = [];
    await Promise.all(wanted.map(async function (anm) {
      var cachedA = await readCacheGet("/channel-activity/" + anm);
      if (cachedA && Array.isArray(cachedA.b) && cachedA.b.length === 24) activity[anm] = cachedA.b;
      else misses.push(anm);
    }));
    if (misses.length) {
      var buckets = {};
      misses.forEach(function (anm) { buckets[anm] = new Array(24).fill(0); });
      try {
        var ph3 = misses.map(function () { return "?"; }).join(",");
        var rsA = await replica(env.DB_CHANNELS).prepare(
          "SELECT channel, CAST((? - created_at) / 3600 AS INTEGER) AS age, COUNT(*) AS c " +
          "FROM events WHERE channel IN (" + ph3 + ") AND created_at >= ? GROUP BY channel, age"
        ).bind(nowSecA, ...misses, minTsA).all();
        (rsA.results || []).forEach(function (r) {
          var ageH = r.age;
          if (ageH >= 0 && ageH < 24 && buckets[r.channel]) buckets[r.channel][ageH] = r.c || 0;
        });
      } catch (e) { }
      misses.forEach(function (anm) {
        activity[anm] = buckets[anm];
        readCachePut(context, "/channel-activity/" + anm, { b: buckets[anm] }, CHANNEL_READ_TTL);
      });
    }
    return json({ activity: activity });
  }

  // NIP-09 deletion: the signed kind 5 event IS the authorization. We only
  // delete an archived event when its author matches the deletion's signer.
  if (body.action === "channel-delete") {
    var name2 = archiveSanitizeChannel(body.channel);
    var del = body.deletionEvent;
    if (!name2) return json({ error: "Invalid channel." }, 400);
    if (!del || del.kind !== 5 || typeof del.id !== "string" || typeof del.sig !== "string"
      || typeof del.pubkey !== "string" || !Array.isArray(del.tags)) {
      return json({ error: "Invalid deletion event." }, 400);
    }
    try {
      if (getEventHash(del) !== del.id || !schnorr.verify(del.sig, del.id, del.pubkey)) {
        return json({ error: "Deletion event failed verification." }, 400);
      }
    } catch (e) { return json({ error: "Deletion event failed verification." }, 400); }
    var targets = del.tags.filter(function (t) { return Array.isArray(t) && t[0] === "e" && typeof t[1] === "string"; })
      .map(function (t) { return t[1].toLowerCase(); }).filter(function (t) { return /^[0-9a-f]{64}$/.test(t); }).slice(0, 100);
    var removed = 0;
    if (targets.length) {
      var ph4 = targets.map(function () { return "?"; }).join(",");
      try {
        var dr2 = await env.DB_CHANNELS.prepare(
          "DELETE FROM events WHERE channel = ? AND pubkey = ? AND id IN (" + ph4 + ")"
        ).bind(name2, del.pubkey, ...targets).run();
        removed = (dr2.meta && dr2.meta.changes) || 0;
      } catch (e) { }
    }
    if (removed) readCacheDelete(context, "/channel/" + name2);
    return json({ ok: true, removed: removed });
  }

  return json({ error: "Unknown action" }, 400);
}

var EMOJI_READ_TTL = 300;

// Sserve the deduped NIP-30 emoji set (kind 30030 packs)
async function handleEmojiAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_CHANNELS)) return json({ error: "Emoji storage is not configured (missing DB_CHANNELS binding)." }, 503);

  if (body.action === "emoji-get") {
    var ndjsonHeaders = { "Content-Type": "application/x-ndjson", ...CLIENT_CORS_HEADERS };
    var userPk = (typeof body.pubkey === "string" && /^[0-9a-f]{64}$/i.test(body.pubkey)) ? body.pubkey.toLowerCase() : null;

    var packsBody = await readCacheGetRaw("/emoji-packs");
    if (packsBody === null) {
      var packRows = [];
      try {
        packRows = (await replica(env.DB_CHANNELS).prepare(
          "SELECT json FROM emoji_packs WHERE kind = 30030 ORDER BY created_at DESC LIMIT 500"
        ).all()).results || [];
      } catch (e) { packRows = []; }
      packsBody = packRows.map(function (r) { return r.json; }).join("\n");
      if (packsBody) packsBody += "\n";
      readCachePutRaw(context, "/emoji-packs", packsBody, "application/x-ndjson", EMOJI_READ_TTL);
    }

    var userLine = "";
    if (userPk) {
      try {
        var urow = await replica(env.DB_CHANNELS).prepare(
          "SELECT json FROM emoji_packs WHERE coord = ?"
        ).bind("10030:" + userPk + ":").first();
        if (urow && urow.json) userLine = urow.json + "\n";
      } catch (e) { userLine = ""; }
    }

    return new Response((packsBody || "") + userLine, { status: 200, headers: ndjsonHeaders });
  }

  return json({ error: "Unknown action" }, 400);
}

function zapIsValidReceipt(ev) {
  try {
    if (!ev || typeof ev !== "object") return false;
    if (ev.kind !== 9735) return false;
    if (typeof ev.id !== "string" || typeof ev.sig !== "string" || typeof ev.pubkey !== "string") return false;
    if (typeof ev.content !== "string" || !Array.isArray(ev.tags)) return false;
    if (getEventHash(ev) !== ev.id) return false;
    return schnorr.verify(ev.sig, ev.id, ev.pubkey);
  } catch (e) { return false; }
}

function zapTargetId(ev) {
  var tags = ev.tags || [];
  var e = tags.find(function (t) {
    return Array.isArray(t) && t[0] === "e" && typeof t[1] === "string" && /^[0-9a-f]{64}$/i.test(t[1]);
  });
  if (e) return e[1].toLowerCase();
  var d = tags.find(function (t) { return Array.isArray(t) && t[0] === "description" && typeof t[1] === "string"; });
  if (d) {
    try {
      var req = JSON.parse(d[1]);
      if (req && Array.isArray(req.tags)) {
        var re = req.tags.find(function (t) {
          return Array.isArray(t) && t[0] === "e" && typeof t[1] === "string" && /^[0-9a-f]{64}$/i.test(t[1]);
        });
        if (re) return re[1].toLowerCase();
      }
    } catch (e2) { }
  }
  return null;
}

function zapScopeFromDescription(ev) {
  var d = (ev.tags || []).find(function (t) { return Array.isArray(t) && t[0] === "description" && typeof t[1] === "string"; });
  if (!d) return null;
  var req;
  try { req = JSON.parse(d[1]); } catch (e) { return null; }
  if (!req || !Array.isArray(req.tags)) return null;
  var k = req.tags.find(function (t) { return Array.isArray(t) && t[0] === "k"; });
  if (!k || typeof k[1] !== "string") return null;
  if (k[1] === "20000" || k[1] === "23333") return "channel";
  if (k[1] === "1059") return "pm";
  return null;
}

function zapClassify(ev) {
  var scope = zapScopeFromDescription(ev);
  if (!scope) return null;
  var targetId = zapTargetId(ev);
  if (!targetId) return null;
  return { scope: scope, targetId: targetId };
}

async function zapInsert(db, rows, now) {
  if (!hasD1(db) || rows.length === 0) return 0;
  var stmt = db.prepare("INSERT OR IGNORE INTO zaps (id, target_id, pubkey, created_at, json, stored_at) VALUES (?, ?, ?, ?, ?, ?)");
  var batch = rows.map(function (r) {
    return stmt.bind(r.ev.id, r.targetId, typeof r.ev.pubkey === "string" ? r.ev.pubkey : null, r.ev.created_at || 0, JSON.stringify(r.ev), now);
  });
  var added = 0;
  try {
    var res = await db.batch(batch);
    res.forEach(function (x) { added += (x.meta && x.meta.changes) || 0; });
  } catch (e) { }
  return added;
}

async function handleZapAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };

  if (body.action === "zap-get") {
    var scope = body.scope === "pm" ? "pm" : "channel";
    var db = scope === "pm" ? env.DB_PM : env.DB_CHANNELS;
    var rawIds = Array.isArray(body.ids) ? body.ids : [];
    var ids = [];
    var seen = new Set();
    for (var i = 0; i < rawIds.length && ids.length < 500; i++) {
      var id = rawIds[i];
      if (typeof id === "string" && /^[0-9a-f]{64}$/i.test(id)) {
        var lo = id.toLowerCase();
        if (!seen.has(lo)) { seen.add(lo); ids.push(lo); }
      }
    }
    var rows = [];
    if (ids.length && hasD1(db)) {
      try {
        var ph = ids.map(function () { return "?"; }).join(",");
        rows = (await replica(db).prepare(
          "SELECT json FROM zaps WHERE target_id IN (" + ph + ") ORDER BY created_at DESC LIMIT 1000"
        ).bind(...ids).all()).results || [];
      } catch (e) { rows = []; }
    }
    var zapEncoder = new TextEncoder();
    var zapStream = new ReadableStream({
      start(controller) {
        for (var j = 0; j < rows.length; j++) {
          controller.enqueue(zapEncoder.encode(rows[j].json + "\n"));
        }
        try { controller.close(); } catch (_) { }
      }
    });
    return new Response(zapStream, {
      status: 200,
      headers: { "Content-Type": "application/x-ndjson", ...CLIENT_CORS_HEADERS }
    });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) return json({ error: "Authentication failed" }, 401);

  if (body.action === "zap-put") {
    var events = Array.isArray(body.events) ? body.events.slice(0, 100)
      : (body.event ? [body.event] : []);
    var now = Date.now();
    var chan = [];
    var pm = [];
    for (var n = 0; n < events.length; n++) {
      var ev = events[n];
      if (!zapIsValidReceipt(ev)) continue;
      if (JSON.stringify(ev).length > ZAP_EVENT_MAX) continue;
      var info = zapClassify(ev);
      if (!info) continue;
      if (info.scope === "channel") chan.push({ ev: ev, targetId: info.targetId });
      else if (info.scope === "pm") pm.push({ ev: ev, targetId: info.targetId });
    }
    var added = 0;
    added += await zapInsert(env.DB_CHANNELS, chan, now);
    added += await zapInsert(env.DB_PM, pm, now);
    return json({ ok: true, added: added });
  }

  return json({ error: "Unknown action" }, 400);
}

// Dispatch a parsed body to the matching action handler. Shared by the HTTP
// endpoint and the /api WebSocket worker (which sets context._wsAuthedPubkey).
async function routeStorageAction(context, body) {
  if (body && typeof body.action === "string" && body.action.indexOf("settings-") === 0) {
    try {
      return await handleSettingsAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("profile-") === 0) {
    try {
      return await handleProfileAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("pm-") === 0) {
    try {
      return await handlePmAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("channel-") === 0) {
    try {
      return await handleChannelAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("emoji-") === 0) {
    try {
      return await handleEmojiAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("zap-") === 0) {
    try {
      return await handleZapAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("shop-") === 0) {
    const privkey = context.env.BOT_PRIVKEY;
    let pubkey = null;
    if (privkey) {
      try { pubkey = getPublicKey(privkey); } catch (e) { pubkey = null; }
    }
    try {
      return await handleShopAction(context, body, privkey, pubkey);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  return new Response(JSON.stringify({ error: "Unknown action" }), {
    status: 400, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
  });
}

async function onRequest(context) {
  const { request } = context;

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CLIENT_CORS_HEADERS });
  }
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST required" }), {
      status: 405, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  }
  if (!isNymchatClient(request)) {
    return new Response(JSON.stringify({ error: "Forbidden" }), {
      status: 403, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  }

  return await routeStorageAction(context, body);
}

export {
  onRequest,
  routeStorageAction
};
