export var GIFT_TTL_MS = 30 * 24 * 60 * 60 * 1000;
export var GIFT_MIN = { standard: 10, pro: 1 };
export var GIFT_MAX = 10000000;
export var GIFT_MAX_OPEN = 20;
export var GIFT_LIST_MAX = 50;
export var GIFT_SWEEP_MAX = 25;
export var GIFT_CODE_RE = /^GIFT-[0-9A-F]{32}$/;

export function giftTier(t) {
  return t === "pro" ? "pro" : "standard";
}

export function giftCode(raw) {
  var s = String(raw == null ? "" : raw).trim();
  var at = s.search(/gift=/i);
  if (at !== -1) s = s.slice(at + 5);
  s = s.split(/[&\s]/)[0];
  try { s = decodeURIComponent(s); } catch (e) { }
  s = s.trim().toUpperCase();
  return GIFT_CODE_RE.test(s) ? s : "";
}

export function giftNewCode() {
  var b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return "GIFT-" + Array.from(b).map(function (x) { return x.toString(16).padStart(2, "0"); }).join("").toUpperCase();
}

export async function giftId(code) {
  var bytes = new TextEncoder().encode("nymbot-gift:" + code);
  var digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest).map(function (x) { return x.toString(16).padStart(2, "0"); }).join("");
}

export function giftAmount(raw, tier) {
  var n = Number(raw);
  if (!Number.isFinite(n) || Math.floor(n) !== n) return { error: "A gift is a whole number of credits." };
  var min = GIFT_MIN[giftTier(tier)];
  if (n < min) return { error: "A gift is at least " + min + " " + (giftTier(tier) === "pro" ? "Pro " : "") + "credit" + (min === 1 ? "" : "s") + "." };
  if (n > GIFT_MAX) return { error: "That gift is too large." };
  return { amount: n };
}

export function giftPublic(row, viewer) {
  return {
    id: row.id,
    tier: row.tier,
    amount: Number(row.amount) || 0,
    state: row.state,
    createdAt: Number(row.created) || 0,
    expiresAt: Number(row.exp) || 0,
    doneAt: Number(row.done_at) || 0,
    own: !!viewer && row.owner === viewer
  };
}
