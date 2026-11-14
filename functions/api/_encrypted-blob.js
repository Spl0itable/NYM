const BLOB_CHANNEL_KINDS = [20000, 23333];
const RX_BLOB_PREFIX = /^v\d{1,2}:/;
const RX_BLOB_STANDARD = /^[A-Za-z0-9+/]+={0,2}$/;
const RX_BLOB_URL_SAFE = /^[A-Za-z0-9_-]+={0,2}$/;
const RX_BLOB_HEX = /^[0-9a-f]+$/i;
const BLOB_MAX_SEGMENTS = 8;
const BLOB_IV_BYTES = [12, 16];
const BLOB_MIN_PAYLOAD_BYTES = 16;
function blobSegmentBytes(seg) {
  if (!seg || !(RX_BLOB_STANDARD.test(seg) || RX_BLOB_URL_SAFE.test(seg))) return -1;
  const body = seg.replace(/=+$/, '').length;
  if (body !== seg.length && seg.length % 4 !== 0) return -1;
  if (body % 4 === 1) return -1;
  return Math.floor(body * 3 / 4);
}
function isEncryptedBlobContent(content) {
  if (typeof content !== 'string' || !content) return false;
  const segs = content.trim().replace(RX_BLOB_PREFIX, '').split(':');
  if (segs.length < 2 || segs.length > BLOB_MAX_SEGMENTS) return false;
  if (RX_BLOB_HEX.test(segs[segs.length - 1])) return false;
  const sizes = segs.map(blobSegmentBytes);
  if (sizes.some((n) => n < 0)) return false;
  if (sizes[sizes.length - 1] < BLOB_MIN_PAYLOAD_BYTES) return false;
  return sizes.slice(0, -1).some((n) => BLOB_IV_BYTES.includes(n));
}
function isEncryptedBlobChannelEvent(ev) {
  return !!ev && typeof ev === 'object' && BLOB_CHANNEL_KINDS.includes(ev.kind) && isEncryptedBlobContent(ev.content);
}
export { BLOB_CHANNEL_KINDS as CHANNEL_KINDS, isEncryptedBlobContent, isEncryptedBlobChannelEvent };
