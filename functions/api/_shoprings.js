export const SHOP_PACK_ID = "bundle-everything";

export const SHOP_RING_IDS = [
  "ring-satoshi", "ring-glitch", "ring-aurora", "ring-neon", "ring-ghost", "ring-matrix",
  "ring-fire", "ring-ice", "ring-ocean", "ring-sakura", "ring-galaxy", "ring-toxic",
  "ring-midas", "ring-vaporwave", "ring-blood", "ring-royal", "ring-circuit", "ring-prism"
];

function shopPackEntries(owned) {
  const out = [];
  if (!owned || typeof owned !== "object") return out;
  for (const id of Object.keys(owned)) {
    const e = owned[id];
    if (e && typeof e === "object" && e.fromBundle === SHOP_PACK_ID) out.push([id, e]);
  }
  return out;
}

export function shopPackSource(owned) {
  const entries = shopPackEntries(owned);
  if (!entries.length) return null;
  if (entries.some(([id, e]) => e.packRings || SHOP_RING_IDS.includes(id))) return null;
  let first = entries[0][1];
  for (const [, e] of entries) if ((Number(e.at) || 0) < (Number(first.at) || 0)) first = e;
  return first;
}

export function shopPackRings(owned) {
  if (!shopPackSource(owned)) return [];
  return SHOP_RING_IDS.filter((id) => !owned[id]);
}

export function shopPackRingEntry(source) {
  return { at: Number(source.at) || 0, amountSats: 0, gift: !!source.gift, fromBundle: SHOP_PACK_ID };
}

export function shopOwnedView(owned) {
  const source = shopPackSource(owned);
  if (!source) return owned;
  const out = Object.assign({}, owned);
  for (const id of SHOP_RING_IDS) if (!out[id]) out[id] = shopPackRingEntry(source);
  return out;
}

export function shopBundleHasRings(itemId, bundle) {
  if (itemId !== SHOP_PACK_ID || !Array.isArray(bundle)) return false;
  return SHOP_RING_IDS.every((id) => bundle.some((c) => c && c.itemId === id));
}
