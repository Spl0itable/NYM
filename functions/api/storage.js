// Cloudflare Pages Function: R2-backed user storage (flair shop + encrypted settings).

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
  validateZapReceipt,
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
  if (!hasVerify && !canNip57) {
    return { error: "Bot Lightning wallet supports neither LUD-21 verification nor NIP-57 zap receipts.", status: 502 };
  }
  return {
    pr: invData.pr,
    verifyMethod: hasVerify ? "lud21" : "nip57",
    verifyUrl: hasVerify ? invData.verify : null,
    providerPubkey: hasVerify ? null : lnurlData.nostrPubkey.toLowerCase()
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
    var recs = await Promise.all(pks.map(function (pk) { return shopGetRecord(env, pk); }));
    var statuses = {};
    pks.forEach(function (pk, idx) {
      statuses[pk] = { active: recs[idx].active, updatedAt: recs[idx].updatedAt };
    });
    return json({ statuses: statuses });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!verifyBotAuth(body.auth, userPubkey)) return json({ error: "Authentication failed" }, 401);

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
      needsReceipt: inv.verifyMethod === "nip57",
      invoiceId: invoiceId
    });
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
    if (pending.verifyMethod === "nip57") {
      var rcptError = validateZapReceipt(body.receipt, pending);
      if (rcptError) return json({ error: rcptError }, 400);
    } else {
      var settled = false;
      try {
        var vr = await fetch(pending.verifyUrl, { headers: { "Accept": "application/json" } });
        var vd = await vr.json();
        settled = !!(vd && (vd.settled || vd.paid));
      } catch (e) {
        return json({ error: "Could not verify the payment." }, 502);
      }
      if (!settled) return json({ error: "Payment not confirmed yet." }, 402);
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
    var crec = await shopGetRecord(env, recipient);
    crec.owned[pending.itemId] = { at: Date.now(), amountSats: pending.amountSats, gift: isGift, code: code };
    await shopPutRecord(env, recipient, crec);
    await env.R2_BUCKET.put("shop-code/" + code, JSON.stringify({ itemId: pending.itemId, owner: recipient, createdAt: Date.now() }));
    await env.R2_BUCKET.put(claimKey, JSON.stringify({ itemId: pending.itemId, pubkey: recipient, paidBy: userPubkey, gift: isGift, code: code, at: Date.now() }));
    await env.R2_BUCKET.delete("shop-pending/" + invoiceId);
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
    var fromRec = await shopGetRecord(env, userPubkey);
    var entry = fromRec.owned[itemId];
    if (!entry) return json({ error: "You do not own this item." }, 403);
    delete fromRec.owned[itemId];
    shopPruneActive(fromRec);
    var toRec = await shopGetRecord(env, toPubkey);
    toRec.owned[itemId] = { at: Date.now(), amountSats: entry.amountSats || 0, gift: true, code: entry.code, transferredFrom: userPubkey };
    await shopPutRecord(env, userPubkey, fromRec);
    await shopPutRecord(env, toPubkey, toRec);
    if (entry.code) {
      try {
        await env.R2_BUCKET.put("shop-code/" + entry.code, JSON.stringify({ itemId: itemId, owner: toPubkey, createdAt: Date.now() }));
      } catch (e) { }
    }
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
    if (prevOwner === userPubkey) {
      var ownRec = await shopGetRecord(env, userPubkey);
      return json({ itemId: redeemItem, owned: ownRec.owned, active: ownRec.active, alreadyOwner: true });
    }
    if (prevOwner && /^[0-9a-f]{64}$/.test(prevOwner)) {
      var prevRec = await shopGetRecord(env, prevOwner);
      if (prevRec.owned[redeemItem]) {
        delete prevRec.owned[redeemItem];
        shopPruneActive(prevRec);
        await shopPutRecord(env, prevOwner, prevRec);
      }
    }
    var rrec = await shopGetRecord(env, userPubkey);
    rrec.owned[redeemItem] = { at: Date.now(), amountSats: 0, gift: false, code: code, redeemed: true };
    await shopPutRecord(env, userPubkey, rrec);
    await env.R2_BUCKET.put("shop-code/" + code, JSON.stringify({ itemId: redeemItem, owner: userPubkey, createdAt: codeData.createdAt || Date.now() }));
    return json({ itemId: redeemItem, owned: rrec.owned, active: rrec.active });
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
  if (!verifyBotAuth(body.auth, userPubkey)) return json({ error: "Authentication failed" }, 401);

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
    var updatedAt = Date.now();
    await env.R2_BUCKET.put("settings/" + userPubkey + "/" + cat, JSON.stringify({ blob: body.blob, updatedAt: updatedAt, v: 2 }));
    return json({ ok: true, category: cat, updatedAt: updatedAt });
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
      return new Response(JSON.stringify({ error: "Server error: " + (e.message || String(e)) }), {
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
      return new Response(JSON.stringify({ error: "Server error: " + (e.message || String(e)) }), {
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
