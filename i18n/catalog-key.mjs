export const CATALOG_PLACEHOLDER = "const NYM_I18N_CATALOG = '00000000';";

export function catalogHash(strings) {
  const list = [...new Set(strings.map(String))].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  let h = 0x811c9dc5;
  for (const b of new TextEncoder().encode(list.join('\n'))) {
    h = (h ^ b) >>> 0;
    h = (h * 0x193 + (h & 0xff) * 0x1000000) % 0x100000000;
  }
  return h.toString(16).padStart(8, '0');
}

export function cacheKey(hash, build) {
  return 'c' + hash + (build == null ? '' : '.b' + build);
}

export function stampCatalog(source, hash) {
  if (!/^[0-9a-f]{8}$/.test(hash)) throw new Error('catalog hash must be 8 hex digits: ' + hash);
  if (!source.includes(CATALOG_PLACEHOLDER)) throw new Error('js/modules/i18n.js has no catalog placeholder');
  return source.replace(CATALOG_PLACEHOLDER, "const NYM_I18N_CATALOG = '" + hash + "';");
}
