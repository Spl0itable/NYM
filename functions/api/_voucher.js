import { hasD1 } from "./_d1.js";
import {
  hmac,
  sha256,
  secp256k1,
  bytesToHex,
  hexToBytes,
  utf8ToBytes,
  concatBytes,
  randomBytes,
  hkdfExpand
} from "./_shared.js";

var VOUCHER_N = BigInt("0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");
var VOUCHER_DENOMS = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];
var VOUCHER_TIERS = ["standard", "pro"];
var VOUCHER_MAX_OUTPUTS = 32;
var VOUCHER_MAX_AMOUNT = 100000;
var VOUCHER_KDF_SALT = "nymbot-voucher-v1";
var VOUCHER_HTC_DOMAIN = "Nymbot_Voucher_HashToCurve_v1";
var VOUCHER_DLEQ_DOMAIN = "Nymbot_Voucher_DLEQ_v1";
var VOUCHER_REDEEM_CLAIM_PREFIX = "nymbot-voucher-redeem:";
var VOUCHER_CLAIM_RESUME_MS = 60000;

var Point = secp256k1.Point;

function voucherConfigured(env) {
  return !!(env && typeof env.BOT_VOUCHER_KEY === "string" && env.BOT_VOUCHER_KEY.trim().length >= 32);
}

function isDenom(d) {
  return VOUCHER_DENOMS.indexOf(d) >= 0;
}

function isTier(t) {
  return VOUCHER_TIERS.indexOf(t) >= 0;
}

function isHex(s, len) {
  return typeof s === "string" && s.length === len && /^[0-9a-f]+$/i.test(s);
}

function scalarFromBytes(b) {
  var v = BigInt("0x" + bytesToHex(b)) % VOUCHER_N;
  return v;
}

function scalarToHex(v) {
  var h = v.toString(16);
  while (h.length < 64) h = "0" + h;
  return h;
}

function le32(n) {
  return new Uint8Array([n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255]);
}

function voucherHashToCurve(xBytes) {
  var base = sha256(concatBytes(utf8ToBytes(VOUCHER_HTC_DOMAIN), xBytes));
  for (var i = 0; i < 512; i++) {
    var h = sha256(concatBytes(base, le32(i)));
    try {
      return Point.fromHex("02" + bytesToHex(h));
    } catch (e) {}
  }
  throw new Error("hash-to-curve failed");
}

var _voucherKeyCache = { secret: null, keys: null };

function voucherKeyMap(env) {
  var secret = env && env.BOT_VOUCHER_KEY ? String(env.BOT_VOUCHER_KEY).trim() : "";
  if (!secret) throw new Error("voucher key not configured");
  if (_voucherKeyCache.secret === secret) return _voucherKeyCache.keys;
  var prk = hmac(sha256, utf8ToBytes(VOUCHER_KDF_SALT), utf8ToBytes(secret));
  var keys = {};
  for (var t = 0; t < VOUCHER_TIERS.length; t++) {
    var tier = VOUCHER_TIERS[t];
    keys[tier] = {};
    for (var d = 0; d < VOUCHER_DENOMS.length; d++) {
      var denom = VOUCHER_DENOMS[d];
      var k = 0n;
      for (var i = 0; i < 64; i++) {
        k = scalarFromBytes(hkdfExpand(prk, utf8ToBytes(tier + ":" + denom + ":" + i), 32));
        if (k !== 0n) break;
      }
      if (k === 0n) throw new Error("voucher key derivation failed");
      keys[tier][denom] = { k: k, pub: Point.BASE.multiply(k) };
    }
  }
  _voucherKeyCache = { secret: secret, keys: keys };
  return keys;
}

function voucherKeysetPublic(env) {
  var keys = voucherKeyMap(env);
  var out = {};
  var parts = [];
  for (var t = 0; t < VOUCHER_TIERS.length; t++) {
    var tier = VOUCHER_TIERS[t];
    out[tier] = {};
    for (var d = 0; d < VOUCHER_DENOMS.length; d++) {
      var denom = VOUCHER_DENOMS[d];
      var hex = keys[tier][denom].pub.toHex(true);
      out[tier][String(denom)] = hex;
      parts.push(tier + ":" + denom + ":" + hex);
    }
  }
  var id = bytesToHex(sha256(utf8ToBytes(parts.join("|")))).slice(0, 16);
  return { keysetId: id, denoms: VOUCHER_DENOMS.slice(), maxOutputs: VOUCHER_MAX_OUTPUTS, keys: out };
}

function voucherSign(env, tier, denom, blindedHex) {
  var entry = voucherKeyMap(env)[tier][denom];
  var B = Point.fromHex(blindedHex);
  B.assertValidity();
  var C = B.multiply(entry.k);
  var r = 0n;
  while (r === 0n) r = scalarFromBytes(randomBytes(32));
  var R1 = Point.BASE.multiply(r);
  var R2 = B.multiply(r);
  var e = scalarFromBytes(sha256(concatBytes(
    utf8ToBytes(VOUCHER_DLEQ_DOMAIN),
    R1.toBytes(true),
    R2.toBytes(true),
    entry.pub.toBytes(true),
    C.toBytes(true)
  )));
  var s = (r + e * entry.k) % VOUCHER_N;
  return { C: C.toHex(true), e: scalarToHex(e), s: scalarToHex(s) };
}

function voucherTokenValid(env, tier, denom, secretHex, unblindedHex) {
  try {
    var entry = voucherKeyMap(env)[tier][denom];
    var Y = voucherHashToCurve(hexToBytes(secretHex));
    return Y.multiply(entry.k).equals(Point.fromHex(unblindedHex));
  } catch (e) {
    return false;
  }
}

function voucherSpendId(secretHex) {
  return bytesToHex(sha256(utf8ToBytes("spend:" + String(secretHex).toLowerCase())));
}

function voucherNormalizeOutputs(outputs) {
  if (!Array.isArray(outputs) || !outputs.length || outputs.length > VOUCHER_MAX_OUTPUTS) return null;
  var out = [];
  var total = 0;
  for (var i = 0; i < outputs.length; i++) {
    var o = outputs[i];
    if (!o || typeof o !== "object") return null;
    var d = Math.floor(Number(o.d));
    if (!isDenom(d)) return null;
    if (!isHex(o.B, 66)) return null;
    total += d;
    out.push({ d: d, B: String(o.B).toLowerCase() });
  }
  if (total <= 0 || total > VOUCHER_MAX_AMOUNT) return null;
  return { outputs: out, total: total };
}

function voucherNormalizeTokens(tokens) {
  if (!Array.isArray(tokens) || !tokens.length || tokens.length > VOUCHER_MAX_OUTPUTS) return null;
  var out = [];
  var total = 0;
  var seen = {};
  for (var i = 0; i < tokens.length; i++) {
    var t = tokens[i];
    if (!t || typeof t !== "object") return null;
    var d = Math.floor(Number(t.d));
    if (!isDenom(d)) return null;
    if (!isHex(t.x, 64) || !isHex(t.C, 66)) return null;
    var x = String(t.x).toLowerCase();
    if (seen[x]) return null;
    seen[x] = 1;
    total += d;
    out.push({ d: d, x: x, C: String(t.C).toLowerCase() });
  }
  if (total <= 0 || total > VOUCHER_MAX_AMOUNT) return null;
  return { tokens: out, total: total };
}

function voucherIssueClaimId(pubkey, tier, reqId, outputs) {
  var parts = outputs.map(function (o) { return o.d + ":" + o.B; }).join(",");
  return bytesToHex(sha256(utf8ToBytes([pubkey, tier, reqId, parts].join("|"))));
}

function voucherRedeemClaimId(redeemId) {
  return bytesToHex(sha256(utf8ToBytes(VOUCHER_REDEEM_CLAIM_PREFIX + String(redeemId).toLowerCase())));
}

var _voucherTablesReady = false;

async function voucherEnsureTables(db) {
  if (_voucherTablesReady) return true;
  if (!hasD1(db)) return false;
  await db.batch([
    db.prepare("CREATE TABLE IF NOT EXISTS voucher_claim (id TEXT PRIMARY KEY, state TEXT NOT NULL, tier TEXT NOT NULL, amount INTEGER NOT NULL, at INTEGER NOT NULL)"),
    db.prepare("CREATE TABLE IF NOT EXISTS voucher_spent (id TEXT PRIMARY KEY, at INTEGER NOT NULL)"),
    db.prepare("CREATE TABLE IF NOT EXISTS voucher_redeem (id TEXT PRIMARY KEY, pubkey TEXT NOT NULL, tier TEXT NOT NULL, amount INTEGER NOT NULL, state TEXT NOT NULL, at INTEGER NOT NULL)")
  ]);
  _voucherTablesReady = true;
  return true;
}

async function voucherBalance(db, pubkey, tier) {
  try {
    var row = await db.prepare("SELECT balance FROM credits WHERE pubkey = ?")
      .bind(tier === "pro" ? pubkey + "#pro" : pubkey).first();
    return (row && typeof row.balance === "number") ? row.balance : 0;
  } catch (e) { return 0; }
}

async function voucherIssue(env, ledgerCall, args) {
  var db = env && env.DB_CREDITS;
  if (!voucherConfigured(env)) return { error: "Anonymous vouchers are not configured on this server." };
  if (!await voucherEnsureTables(db)) return { error: "Voucher storage is unavailable." };
  var pubkey = String(args.pubkey || "").toLowerCase();
  var tier = args.tier === "pro" ? "pro" : "standard";
  var reqId = String(args.reqId || "").toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(pubkey)) return { error: "Invalid pubkey." };
  if (!/^[0-9a-f]{64}$/.test(reqId)) return { error: "Invalid voucher request id." };
  var norm = voucherNormalizeOutputs(args.outputs);
  if (!norm) return { error: "Invalid voucher outputs." };

  var claimId = voucherIssueClaimId(pubkey, tier, reqId, norm.outputs);
  var now = Date.now();
  var row = await db.prepare("SELECT state, amount, at FROM voucher_claim WHERE id = ?").bind(claimId).first();
  if (!row) {
    var ins = await db.prepare(
      "INSERT OR IGNORE INTO voucher_claim (id, state, tier, amount, at) VALUES (?, 'pending', ?, ?, ?)"
    ).bind(claimId, tier, norm.total, now).run();
    if (!(ins.meta && ins.meta.changes)) {
      row = await db.prepare("SELECT state, amount, at FROM voucher_claim WHERE id = ?").bind(claimId).first();
      if (row && row.state !== "done" && (now - (row.at || 0)) < VOUCHER_CLAIM_RESUME_MS) {
        return { error: "That voucher request is already being issued — try again in a moment." };
      }
    }
  } else if (row.state !== "done" && (now - (row.at || 0)) < VOUCHER_CLAIM_RESUME_MS) {
    return { error: "That voucher request is already being issued — try again in a moment." };
  }

  var signatures;
  try {
    signatures = norm.outputs.map(function (o) {
      return Object.assign({ d: o.d }, voucherSign(env, tier, o.d, o.B));
    });
  } catch (e) {
    return { error: "Voucher signing failed." };
  }

  if (row && row.state === "done") {
    return {
      ok: true, tier: tier, spent: norm.total, replayed: true,
      balance: await voucherBalance(db, pubkey, tier), signatures: signatures
    };
  }

  var spend = await ledgerCall(env, { op: "consume-credits", pubkey: pubkey, cost: norm.total, tier: tier });
  if (spend && spend._noLedger) return { error: "Service temporarily unavailable.", unavailable: true };
  if (!spend || spend.error || !spend.ok) {
    try { await db.prepare("DELETE FROM voucher_claim WHERE id = ? AND state = 'pending'").bind(claimId).run(); } catch (e) {}
    if (spend && spend.error) return { error: spend.error };
    return {
      ok: false, insufficient: true, tier: tier,
      balance: (spend && spend.balance) || 0, required: norm.total
    };
  }
  try { await db.prepare("UPDATE voucher_claim SET state = 'done' WHERE id = ?").bind(claimId).run(); } catch (e) {}
  return { ok: true, tier: tier, spent: norm.total, balance: spend.balance, signatures: signatures };
}

async function voucherRedeem(env, ledgerCall, args) {
  var db = env && env.DB_CREDITS;
  if (!voucherConfigured(env)) return { error: "Anonymous vouchers are not configured on this server." };
  if (!await voucherEnsureTables(db)) return { error: "Voucher storage is unavailable." };
  var pubkey = String(args.pubkey || "").toLowerCase();
  var tier = args.tier === "pro" ? "pro" : "standard";
  var redeemId = String(args.redeemId || "").toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(pubkey)) return { error: "Invalid pubkey." };
  if (!/^[0-9a-f]{64}$/.test(redeemId)) return { error: "Invalid redemption id." };
  var norm = voucherNormalizeTokens(args.tokens);
  if (!norm) return { error: "Invalid vouchers." };

  var claimId = voucherRedeemClaimId(redeemId);
  var row = await db.prepare("SELECT pubkey, tier, amount, state FROM voucher_redeem WHERE id = ?").bind(claimId).first();
  if (row) {
    if (row.pubkey !== pubkey || row.tier !== tier || row.amount !== norm.total) {
      return { error: "That redemption id was already used for a different set of vouchers." };
    }
    if (row.state === "done") {
      return {
        ok: true, credited: row.amount, tier: tier, replayed: true,
        balance: await voucherBalance(db, pubkey, tier)
      };
    }
  } else {
    var ids = [];
    for (var i = 0; i < norm.tokens.length; i++) {
      var t = norm.tokens[i];
      if (!voucherTokenValid(env, tier, t.d, t.x, t.C)) return { error: "A voucher failed verification." };
      ids.push(voucherSpendId(t.x));
    }
    var now2 = Date.now();
    var stmt = db.prepare("INSERT OR IGNORE INTO voucher_spent (id, at) VALUES (?, ?)");
    var res = await db.batch(ids.map(function (id) { return stmt.bind(id, now2); }));
    var taken = [];
    var clash = false;
    for (var j = 0; j < res.length; j++) {
      if (res[j] && res[j].meta && res[j].meta.changes) taken.push(ids[j]);
      else clash = true;
    }
    if (clash) {
      if (taken.length) {
        var ph = taken.map(function () { return "?"; }).join(",");
        try { await db.prepare("DELETE FROM voucher_spent WHERE id IN (" + ph + ")").bind(...taken).run(); } catch (e) {}
      }
      return { error: "These vouchers were already redeemed.", alreadySpent: true };
    }
    await db.prepare(
      "INSERT OR IGNORE INTO voucher_redeem (id, pubkey, tier, amount, state, at) VALUES (?, ?, ?, ?, 'pending', ?)"
    ).bind(claimId, pubkey, tier, norm.total, now2).run();
  }

  var credit = await ledgerCall(env, {
    op: "claim-credits", invoiceId: claimId, creditTo: pubkey, credits: norm.total, tier: tier,
    claimData: { pubkey: pubkey, credits: norm.total, tier: tier, voucher: true }
  });
  if (credit && credit._noLedger) return { error: "Service temporarily unavailable.", unavailable: true };
  if (!credit || (credit.error && !credit.alreadyClaimed)) {
    return { error: (credit && credit.error) || "Could not credit the vouchers." };
  }
  try { await db.prepare("UPDATE voucher_redeem SET state = 'done' WHERE id = ?").bind(claimId).run(); } catch (e) {}
  return {
    ok: true, credited: norm.total, tier: tier,
    balance: typeof credit.balance === "number" ? credit.balance : await voucherBalance(db, pubkey, tier)
  };
}

export {
  VOUCHER_DENOMS,
  VOUCHER_TIERS,
  VOUCHER_MAX_OUTPUTS,
  VOUCHER_MAX_AMOUNT,
  voucherConfigured,
  voucherKeysetPublic,
  voucherSign,
  voucherTokenValid,
  voucherSpendId,
  voucherNormalizeOutputs,
  voucherNormalizeTokens,
  voucherIssueClaimId,
  voucherRedeemClaimId,
  voucherIssue,
  voucherRedeem,
  voucherHashToCurve,
  isTier,
  isDenom
};
