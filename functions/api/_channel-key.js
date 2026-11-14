import { sha256, bytesToHex, utf8ToBytes } from "./_shared.js";

export const ARCHIVE_KEY_MAX = 80;

export function archiveChannelKey(clean) {
  if (clean.length <= ARCHIVE_KEY_MAX) return clean;
  const unit = clean.charCodeAt(47);
  const cut = unit >= 0xd800 && unit <= 0xdbff ? 47 : 48;
  return clean.slice(0, cut) + ":" + bytesToHex(sha256(utf8ToBytes(clean))).slice(0, 31);
}

export function legacyArchiveChannelKey(clean) {
  return clean.length > ARCHIVE_KEY_MAX ? clean.slice(0, ARCHIVE_KEY_MAX) : "";
}
