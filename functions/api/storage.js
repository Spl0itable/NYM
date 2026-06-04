// Cloudflare Pages Function: R2-backed user storage (flair shop + encrypted settings).

import { ledgerCall } from "./_ledger.js";
export { NymLedger } from "./_ledger.js";
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
  verifyBotAuth,
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
  BOT_CORS_HEADERS,
  NYMCHAT_APP_ORIGINS,
  isNymchatBotClient
} from "./_shared.js";

// Shop: message styles, nickname flair, cosmetics and the supporter badge
var SHOP_CATALOG = {
  "style-satoshi": { price: 21420, type: "message-style" },
  "style-glitch": { price: 10101, type: "message-style" },
  "style-aurora": { price: 2424, type: "message-style" },
  "style-neon": { price: 1984, type: "message-style" },
  "style-ghost": { price: 666, type: "message-style" },
  "style-matrix": { price: 1337, type: "message-style" },
  "style-fire": { price: 911, type: "message-style" },
  "style-ice": { price: 777, type: "message-style" },
  "style-rainbow": { price: 2222, type: "message-style" },
  "flair-crown": { price: 5000, type: "nickname-flair" },
  "flair-diamond": { price: 10000, type: "nickname-flair" },
  "flair-skull": { price: 1666, type: "nickname-flair" },
  "flair-star": { price: 2500, type: "nickname-flair" },
  "flair-lightning": { price: 2100, type: "nickname-flair" },
  "flair-heart": { price: 1111, type: "nickname-flair" },
  "flair-mask": { price: 4200, type: "nickname-flair" },
  "flair-rocket": { price: 2300, type: "nickname-flair" },
  "flair-shield": { price: 1900, type: "nickname-flair" },
  "supporter-badge": { price: 42069, type: "supporter" },
  "cosmetic-aura-gold": { price: 3500, type: "cosmetic" },
  "cosmetic-redacted": { price: 2800, type: "cosmetic" }
};

function shopBlankRecord() {
  return { owned: {}, active: { style: null, flair: [], cosmetics: [], supporter: false }, updatedAt: 0 };
}
async function shopGetRecord(env, pubkey) {
  if (!env.R2_BUCKET) return shopBlankRecord();
  try {
    var obj = await env.R2_BUCKET.get("shop/" + pubkey);
    if (!obj) return shopBlankRecord();
    var d = await obj.json();
    if (!d || typeof d !== "object" || typeof d.owned !== "object" || !d.owned) return shopBlankRecord();
    if (!d.active || typeof d.active !== "object") d.active = { style: null, flair: [], cosmetics: [], supporter: false };
    if (!Array.isArray(d.active.flair)) d.active.flair = [];
    if (!Array.isArray(d.active.cosmetics)) d.active.cosmetics = [];
    return d;
  } catch (e) {
    return shopBlankRecord();
  }
}
async function shopPutRecord(env, pubkey, data) {
  data.updatedAt = Date.now();
  await env.R2_BUCKET.put("shop/" + pubkey, JSON.stringify(data));
}
// Drop active selections that point at items the user no longer owns.
function shopPruneActive(rec) {
  var a = rec.active;
  if (a.style && !rec.owned[a.style]) a.style = null;
  a.flair = a.flair.filter(function (id) { return !!rec.owned[id]; });
  a.cosmetics = a.cosmetics.filter(function (id) { return !!rec.owned[id]; });
  if (a.supporter && !rec.owned["supporter-badge"]) a.supporter = false;
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
  // Prefer LUD-21 server-side verification; fall back to the NIP-57 zap
  // receipt (kind 9735) signed by the wallet's Nostr identity.
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

async function handleShopAction(context, body, botPrivkey, botPubkey) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
    });
  };
  if (!env.R2_BUCKET) return json({ error: "Shop is not configured (missing R2_BUCKET binding)." }, 503);

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
    var recs = await Promise.all(misses.map(function (pk) { return shopGetRecord(env, pk); }));
    misses.forEach(function (pk, idx) {
      var st = { active: recs[idx].active, updatedAt: recs[idx].updatedAt };
      statuses[pk] = st;
      readCachePut(context, "/shop-status/" + pk, { st: st }, SHOP_READ_TTL);
    });
    return json({ statuses: statuses });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!verifyBotAuth(body.auth, userPubkey, { url: context.request.url, action: body.action })) {
    return json({ error: "Authentication failed" }, 401);
  }
  var SHOP_MONEY_ACTIONS = { "shop-buy-invoice": 1, "shop-claim": 1, "shop-transfer": 1, "shop-redeem": 1 };
  if (SHOP_MONEY_ACTIONS[body.action]) {
    var rp = await ledgerCall(env, { op: "replay", id: body.auth && body.auth.id, ttl: 130 });
    if (rp && rp._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
    if (!rp || !rp.fresh) return json({ error: "This authorization was already used. Please retry." }, 401);
  }

  if (body.action === "shop-get") {
    var rec = await shopGetRecord(env, userPubkey);
    return json({ owned: rec.owned, active: rec.active, updatedAt: rec.updatedAt });
  }

  if (body.action === "shop-set-active") {
    var rec = await shopGetRecord(env, userPubkey);
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
    rec.active = {
      style: nextStyle,
      flair: nextFlair,
      cosmetics: nextCos,
      supporter: !!want.supporter && !!rec.owned["supporter-badge"]
    };
    await shopPutRecord(env, userPubkey, rec);
    readCachePut(context, "/shop-status/" + userPubkey, { st: { active: rec.active, updatedAt: rec.updatedAt } }, SHOP_READ_TTL);
    return json({ active: rec.active, updatedAt: rec.updatedAt });
  }

  if (body.action === "shop-buy-invoice") {
    var itemId = String(body.itemId || "");
    var cat = SHOP_CATALOG[itemId];
    if (!cat) return json({ error: "Unknown shop item." }, 400);
    var giftTo = null;
    if (body.recipientPubkey && /^[0-9a-f]{64}$/i.test(body.recipientPubkey)) {
      giftTo = body.recipientPubkey.toLowerCase();
    }
    var inv = await botGenerateInvoice(env, cat.price, body.zapRequest, body.comment);
    if (inv.error) return json({ error: inv.error }, inv.status || 502);
    var invoiceId = bytesToHex(sha256(utf8ToBytes(inv.pr)));
    await env.R2_BUCKET.put("shop-pending/" + invoiceId, JSON.stringify({
      pubkey: userPubkey,
      recipientPubkey: giftTo,
      itemId: itemId,
      amountSats: cat.price,
      pr: inv.pr,
      verifyMethod: inv.verifyMethod,
      verifyUrl: inv.verifyUrl,
      providerPubkey: inv.providerPubkey,
      createdAt: Date.now()
    }));
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
    if (await env.R2_BUCKET.get("shop-claimed/" + scId)) return json({ paid: true, claimed: true });
    var scPending = await env.R2_BUCKET.get("shop-pending/" + scId);
    if (!scPending) return json({ error: "Unknown or expired invoice." }, 404);
    var scRec;
    try { scRec = await scPending.json(); } catch (e) { return json({ error: "Corrupt invoice record." }, 500); }
    if (scRec.pubkey !== userPubkey) return json({ error: "This invoice belongs to a different user." }, 403);
    return json({ paid: await invoicePaymentConfirmed(env, scRec, body.receipt) });
  }

  if (body.action === "shop-claim") {
    var invoiceId = String(body.invoiceId || "");
    if (!/^[0-9a-f]{64}$/i.test(invoiceId)) return json({ error: "Invalid invoice reference." }, 400);
    var claimKey = "shop-claimed/" + invoiceId;
    var already = await env.R2_BUCKET.get(claimKey);
    if (already) {
      var prevClaim = await already.json().catch(function () { return null; });
      if (prevClaim) {
        return json({ itemId: prevClaim.itemId, code: prevClaim.code, gift: prevClaim.gift, recipient: prevClaim.pubkey, alreadyClaimed: true });
      }
      return json({ error: "This payment was already claimed." }, 409);
    }
    var pendingObj = await env.R2_BUCKET.get("shop-pending/" + invoiceId);
    if (!pendingObj) return json({ error: "Unknown or expired invoice." }, 404);
    var pending;
    try {
      pending = await pendingObj.json();
    } catch (e) {
      return json({ error: "Corrupt invoice record." }, 500);
    }
    if (pending.pubkey !== userPubkey) return json({ error: "This invoice belongs to a different user." }, 403);
    if (!await invoicePaymentConfirmed(env, pending, body.receipt)) {
      return json({ error: "Payment not confirmed yet." }, 402);
    }
    if (!SHOP_CATALOG[pending.itemId]) return json({ error: "Unknown shop item." }, 400);
    var recipient = userPubkey;
    var isGift = false;
    if (pending.recipientPubkey && /^[0-9a-f]{64}$/i.test(pending.recipientPubkey) &&
      pending.recipientPubkey !== userPubkey) {
      recipient = pending.recipientPubkey.toLowerCase();
      isGift = true;
    }
    var code = shopGenerateCode();
    // Atomic claim-and-grant via the ledger DO (single-use invoice gate).
    var claimRes = await ledgerCall(env, {
      op: "shop-claim", invoiceId: invoiceId, recipient: recipient, itemId: pending.itemId,
      code: code, amountSats: pending.amountSats, gift: isGift,
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
    var codeObj = await env.R2_BUCKET.get("shop-code/" + code);
    if (!codeObj) return json({ error: "Unknown recovery code." }, 404);
    var codeData;
    try {
      codeData = await codeObj.json();
    } catch (e) {
      return json({ error: "Corrupt code record." }, 500);
    }
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
var SETTINGS_CATEGORIES = ["nymchat-settings", "nymchat-keys", "nymchat-groups", "nymchat-history", "nymchat-notifications"];
var SETTINGS_MAX_BLOB = 512 * 1024;

async function handleSettingsAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
    });
  };
  if (!env.R2_BUCKET) return json({ error: "Settings storage is not configured (missing R2_BUCKET binding)." }, 503);

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!verifyBotAuth(body.auth, userPubkey, { url: context.request.url, action: body.action })) return json({ error: "Authentication failed" }, 401);

  if (body.action === "settings-get") {
    var results = await Promise.all(SETTINGS_CATEGORIES.map(async function (cat) {
      try {
        var obj = await env.R2_BUCKET.get("settings/" + userPubkey + "/" + cat);
        if (!obj) return [cat, null];
        var d = await obj.json();
        if (!d || typeof d.blob !== "string") return [cat, null];
        return [cat, { blob: d.blob, updatedAt: d.updatedAt || 0 }];
      } catch (e) {
        return [cat, null];
      }
    }));
    var categories = {};
    results.forEach(function (r) { categories[r[0]] = r[1]; });
    return json({ categories: categories });
  }

  if (body.action === "settings-set") {
    var cat = String(body.category || "");
    if (SETTINGS_CATEGORIES.indexOf(cat) === -1) return json({ error: "Unknown settings category." }, 400);
    if (typeof body.blob !== "string" || !body.blob) return json({ error: "Missing settings blob." }, 400);
    if (body.blob.length > SETTINGS_MAX_BLOB) return json({ error: "Settings payload too large." }, 413);
    var contentHash = (typeof body.contentHash === "string" && /^[0-9a-f]{64}$/i.test(body.contentHash))
      ? body.contentHash.toLowerCase() : null;
    var settingsKey = "settings/" + userPubkey + "/" + cat;
    if (contentHash) {
      try {
        var prevObj = await env.R2_BUCKET.get(settingsKey);
        if (prevObj) {
          var prevDoc = await prevObj.json();
          if (prevDoc && prevDoc.contentHash === contentHash) {
            return json({ ok: true, category: cat, updatedAt: prevDoc.updatedAt || 0, unchanged: true });
          }
        }
      } catch (e) { }
    }
    var updatedAt = Date.now();
    await env.R2_BUCKET.put(settingsKey, JSON.stringify({ blob: body.blob, updatedAt: updatedAt, contentHash: contentHash, v: 2 }));
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
      headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
    });
  };
  if (!env.R2_BUCKET) return json({ error: "Profile storage is not configured (missing R2_BUCKET binding)." }, 503);

  // Public batch read so clients can fetch profiles without a Nostr REQ.
  // Per-pubkey edge cache: hits skip R2, misses GET then populate the cache.
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
    var profEncoder = new TextEncoder();
    var profStream = new ReadableStream({
      start(controller) {
        var misses = [];
        cacheLookups.forEach(function (pair) {
          var pk = pair[0], cached = pair[1];
          if (cached !== null) {
            controller.enqueue(profEncoder.encode(JSON.stringify([pk, cached.rec || null]) + "\n"));
          } else {
            misses.push(pk);
          }
        });
        var pending = misses.map(async function (pk) {
          var rec = null;
          try {
            var obj = await env.R2_BUCKET.get("profile/" + pk);
            if (obj) {
              var d = await obj.json();
              if (d && d.event) rec = { event: d.event, updatedAt: d.updatedAt || 0 };
            }
          } catch (e) { }
          readCachePut(context, "/profile/" + pk, { rec: rec }, PROFILE_READ_TTL);
          controller.enqueue(profEncoder.encode(JSON.stringify([pk, rec]) + "\n"));
        });
        Promise.all(pending).then(function () {
          try { controller.close(); } catch (_) { }
        }).catch(function (e) {
          try { controller.error(e); } catch (_) { }
        });
      }
    });
    return new Response(profStream, {
      status: 200,
      headers: { "Content-Type": "application/x-ndjson", ...BOT_CORS_HEADERS }
    });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!verifyBotAuth(body.auth, userPubkey, { url: context.request.url, action: body.action })) return json({ error: "Authentication failed" }, 401);

  if (body.action === "profile-set") {
    var ev = body.event;
    if (!profileIsValidEvent(ev, userPubkey)) return json({ error: "Invalid profile event." }, 400);
    if (JSON.stringify(ev).length > PROFILE_MAX_EVENT) return json({ error: "Profile too large." }, 413);
    // Keep only the newest profile, ordered by the event's own created_at.
    try {
      var existing = await env.R2_BUCKET.get("profile/" + userPubkey);
      if (existing) {
        var prev = await existing.json();
        if (prev && prev.event && (prev.event.created_at || 0) >= (ev.created_at || 0)) {
          return json({ ok: true, updatedAt: prev.updatedAt || 0, stale: true });
        }
      }
    } catch (e) { }
    var updatedAt = Date.now();
    await env.R2_BUCKET.put("profile/" + userPubkey, JSON.stringify({ event: ev, updatedAt: updatedAt }));
    // Refresh the edge cache so the new profile is served immediately.
    readCachePut(context, "/profile/" + userPubkey, { rec: { event: ev, updatedAt: updatedAt } }, PROFILE_READ_TTL);
    return json({ ok: true, updatedAt: updatedAt });
  }

  return json({ error: "Unknown action" }, 400);
}

var PM_EVENT_MAX = 96 * 1024;
var PM_INDEX_CAP = 4000;
var CHANNEL_EVENT_MAX = 64 * 1024;
var CHANNEL_INDEX_CAP = 2000;
var CHANNEL_TTL_MS = 24 * 60 * 60 * 1000;
var ARCHIVE_DEDUP_HOST = "https://nymchat-archive.invalid";

function archiveDedupRequest(eventId) {
  return new Request(ARCHIVE_DEDUP_HOST + "/handled/" + eventId, { method: "GET" });
}
async function archiveAlreadyHandled(eventId) {
  try { return !!(await caches.default.match(archiveDedupRequest(eventId))); }
  catch (e) { return false; }
}
function archiveMarkHandled(context, eventId, ttlSeconds) {
  try {
    var headers = new Headers();
    headers.set("Cache-Control", "public, max-age=" + (ttlSeconds || 3600));
    var op = caches.default.put(archiveDedupRequest(eventId), new Response("1", { headers: headers }));
    if (context && context.waitUntil) context.waitUntil(op);
  } catch (e) { }
}

// Read-through edge cache for PUBLIC reads (channel-get, profile-get) so many
// stateless workers serve them from the per-colo cache instead of hitting R2.
// Stores the JSON payload only; never used for private (settings/PM) reads.
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

// Small JSON index: { v:1, items: [[id, created_at], ...] } newest-first.
async function archiveReadIndex(env, key) {
  try {
    var obj = await env.R2_BUCKET.get(key);
    if (!obj) return { v: 1, items: [] };
    var d = await obj.json();
    if (!d || !Array.isArray(d.items)) return { v: 1, items: [] };
    return d;
  } catch (e) { return { v: 1, items: [] }; }
}
async function archiveWriteIndex(env, key, idx) {
  try { await env.R2_BUCKET.put(key, JSON.stringify({ v: 1, items: idx.items })); }
  catch (e) { }
}
// Merge new [id, ts] entries, drop anything older than minTs, cap to `cap`.
function archiveMergeIndex(idx, additions, cap, minTs) {
  var seen = new Set();
  var merged = [];
  var all = additions.concat(idx.items);
  for (var i = 0; i < all.length; i++) {
    var it = all[i];
    if (!Array.isArray(it) || typeof it[0] !== "string") continue;
    if (seen.has(it[0])) continue;
    if (minTs && (it[1] || 0) * 1000 < minTs) continue;
    seen.add(it[0]);
    merged.push([it[0], it[1] || 0]);
  }
  merged.sort(function (a, b) { return (b[1] || 0) - (a[1] || 0); });
  if (merged.length > cap) merged = merged.slice(0, cap);
  idx.items = merged;
  return idx;
}

// Channel names become R2 key segments; keep them to a safe, bounded charset.
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
      headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
    });
  };
  if (!env.R2_BUCKET) return json({ error: "PM storage is not configured (missing R2_BUCKET binding)." }, 503);

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!verifyBotAuth(body.auth, userPubkey, { url: context.request.url, action: body.action })) return json({ error: "Authentication failed" }, 401);

  // Upload one or more gift wraps addressed to the authenticated user. Already
  // stored events are skipped (edge cache, then a Class B existence check).
  if (body.action === "pm-put") {
    var events = Array.isArray(body.events) ? body.events.slice(0, 100)
      : (body.event ? [body.event] : []);
    var idxKey = "pm-index/" + userPubkey;
    var idx = await archiveReadIndex(env, idxKey);
    var added = [];
    for (var i = 0; i < events.length; i++) {
      var ev = events[i];
      if (!pmIsValidWrapForUser(ev, userPubkey)) continue;
      if (JSON.stringify(ev).length > PM_EVENT_MAX) continue;
      if (await archiveAlreadyHandled(ev.id)) continue;
      var key = "pm/" + userPubkey + "/" + ev.id;
      var exists = false;
      try { exists = !!(await env.R2_BUCKET.head(key)); } catch (e) { exists = false; }
      if (exists) { archiveMarkHandled(context, ev.id, 86400); continue; }
      await env.R2_BUCKET.put(key, JSON.stringify(ev));
      archiveMarkHandled(context, ev.id, 86400);
      added.push([ev.id, ev.created_at || 0]);
    }
    if (added.length) {
      archiveMergeIndex(idx, added, PM_INDEX_CAP, 0);
      await archiveWriteIndex(env, idxKey, idx);
    }
    return json({ ok: true, added: added.length, stored: idx.items.length });
  }

  if (body.action === "pm-get") {
    var since = Number(body.since) || 0;
    var before = Number(body.before) || 0;
    var limit = Number(body.limit);
    if (!Number.isFinite(limit) || limit <= 0) limit = 1000;
    if (limit > 1000) limit = 1000;
    var idx2 = await archiveReadIndex(env, "pm-index/" + userPubkey);
    var ids = [];
    for (var j = 0; j < idx2.items.length; j++) {
      var it = idx2.items[j];
      var ts = it[1] || 0;
      if (ts < since) continue;
      if (before && ts >= before) continue;
      ids.push(it[0]);
      if (ids.length >= limit) break;
    }
    var hasMore = ids.length >= limit;
    var pmEncoder = new TextEncoder();
    var pmStream = new ReadableStream({
      start(controller) {
        var pending = ids.map(async function (id) {
          try {
            var o = await env.R2_BUCKET.get("pm/" + userPubkey + "/" + id);
            if (!o) return;
            var ev = await o.json();
            if (!ev) return;
            controller.enqueue(pmEncoder.encode(JSON.stringify(ev) + "\n"));
          } catch (e) { }
        });
        Promise.all(pending).then(function () {
          try { controller.close(); } catch (_) { }
        }).catch(function (e) {
          try { controller.error(e); } catch (_) { }
        });
      }
    });
    return new Response(pmStream, {
      status: 200,
      headers: {
        "Content-Type": "application/x-ndjson",
        "X-Has-More": hasMore ? "1" : "0",
        "Access-Control-Expose-Headers": "X-Has-More",
        ...BOT_CORS_HEADERS
      }
    });
  }

  // Delete the user's own stored wraps (e.g. after a NIP-09 kind 5). Objects
  // live under the authenticated user's own prefix, so ownership is implicit.
  if (body.action === "pm-delete") {
    var delIds = Array.isArray(body.ids) ? body.ids.slice(0, 200) : [];
    var removed = 0;
    var rmSet = new Set();
    for (var k = 0; k < delIds.length; k++) {
      var did = delIds[k];
      if (typeof did !== "string" || !/^[0-9a-f]{64}$/i.test(did)) continue;
      did = did.toLowerCase();
      try { await env.R2_BUCKET.delete("pm/" + userPubkey + "/" + did); removed++; rmSet.add(did); } catch (e) { }
    }
    if (rmSet.size) {
      var idx3 = await archiveReadIndex(env, "pm-index/" + userPubkey);
      idx3.items = idx3.items.filter(function (it) { return !rmSet.has(it[0]); });
      await archiveWriteIndex(env, "pm-index/" + userPubkey, idx3);
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
      headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
    });
  };
  if (!env.R2_BUCKET) return json({ error: "Channel storage is not configured (missing R2_BUCKET binding)." }, 503);

  // Public read: hydrate a channel's recent history. No auth (channels are
  // public); the worker's origin gate already limits this to Nymchat clients.
  if (body.action === "channel-get") {
    var name = archiveSanitizeChannel(body.channel);
    if (!name) return json({ error: "Invalid channel." }, 400);
    var minTs = Date.now() - CHANNEL_TTL_MS;
    var since = Number(body.since) || 0;
    var ndjsonHeaders = { "Content-Type": "application/x-ndjson", ...BOT_CORS_HEADERS };
    if (!since) {
      var cachedBody = await readCacheGetRaw("/channel/" + name);
      if (cachedBody !== null) {
        return new Response(cachedBody, { status: 200, headers: ndjsonHeaders });
      }
    }
    var idx = await archiveReadIndex(env, "channel-index/" + name);
    var ids = [];
    for (var i = 0; i < idx.items.length; i++) {
      var it = idx.items[i];
      var tsMs = (it[1] || 0) * 1000;
      if (tsMs < minTs) continue;
      if ((it[1] || 0) < since) continue;
      ids.push(it[0]);
      if (ids.length >= 500) break;
    }
    var encoder = new TextEncoder();
    var cacheBuf = !since ? [] : null;
    var stream = new ReadableStream({
      start(controller) {
        var pending = ids.map(async function (id) {
          try {
            var o = await env.R2_BUCKET.get("channel/" + name + "/" + id);
            if (!o) return;
            var ev = await o.json();
            if (!ev) return;
            var line = JSON.stringify(ev) + "\n";
            controller.enqueue(encoder.encode(line));
            if (cacheBuf) cacheBuf.push(line);
          } catch (e) { }
        });
        Promise.all(pending).then(function () {
          try { controller.close(); } catch (_) { }
          if (cacheBuf) {
            readCachePutRaw(context, "/channel/" + name, cacheBuf.join(""), "application/x-ndjson", CHANNEL_READ_TTL);
          }
        }).catch(function (e) {
          try { controller.error(e); } catch (_) { }
        });
      }
    });
    return new Response(stream, { status: 200, headers: ndjsonHeaders });
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
      .map(function (t) { return t[1].toLowerCase(); }).slice(0, 100);
    var removedSet = new Set();
    for (var d = 0; d < targets.length; d++) {
      var tid = targets[d];
      if (!/^[0-9a-f]{64}$/.test(tid)) continue;
      try {
        var o2 = await env.R2_BUCKET.get("channel/" + name2 + "/" + tid);
        if (!o2) continue;
        var ev2 = await o2.json();
        if (ev2 && ev2.pubkey === del.pubkey) {
          await env.R2_BUCKET.delete("channel/" + name2 + "/" + tid);
          removedSet.add(tid);
        }
      } catch (e) { }
    }
    if (removedSet.size) {
      var cidx = await archiveReadIndex(env, "channel-index/" + name2);
      cidx.items = cidx.items.filter(function (it) { return !removedSet.has(it[0]); });
      await archiveWriteIndex(env, "channel-index/" + name2, cidx);
      // Purge the cached channel read so the deletion isn't served stale.
      readCacheDelete(context, "/channel/" + name2);
    }
    return json({ ok: true, removed: removedSet.size });
  }

  return json({ error: "Unknown action" }, 400);
}

async function onRequest(context) {
  const { request } = context;

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: BOT_CORS_HEADERS });
  }
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST required" }), {
      status: 405, headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
    });
  }
  if (!isNymchatBotClient(request)) {
    return new Response(JSON.stringify({ error: "Forbidden" }), {
      status: 403, headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
    });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400, headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
    });
  }

  if (body && typeof body.action === "string" && body.action.indexOf("settings-") === 0) {
    try {
      return await handleSettingsAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("profile-") === 0) {
    try {
      return await handleProfileAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("pm-") === 0) {
    try {
      return await handlePmAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("channel-") === 0) {
    try {
      return await handleChannelAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
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
        status: 500, headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
      });
    }
  }

  return new Response(JSON.stringify({ error: "Unknown action" }), {
    status: 400, headers: { "Content-Type": "application/json", ...BOT_CORS_HEADERS }
  });
}

export {
  onRequest
};
