const BRIDGE_NICK = 'radio-bridge';
const BRIDGE_CLIENT_MARK = 'meshtastic';
const BRIDGE_PROXY_PROTOCOL = 'meshtastic';
const RX_BRIDGE_NICK_SUFFIX = /#[0-9a-f]{4}$/;
const RX_BRIDGE_UPPER = /[A-Z]+/g;
const RX_BRIDGE_FRAME_HINT = /radio-bridge|meshtastic|\\u/i;
function bridgeAsciiLower(s) {
  return s.replace(RX_BRIDGE_UPPER, (m) => m.toLowerCase());
}
function isBridgeNick(v) {
  return typeof v === 'string' && bridgeAsciiLower(v.trim()).replace(RX_BRIDGE_NICK_SUFFIX, '') === BRIDGE_NICK;
}
function isBridgeTag(t) {
  if (!Array.isArray(t) || typeof t[0] !== 'string') return false;
  if (t[0] === 'n') return isBridgeNick(t[1]);
  if (t[0] === 'client') return typeof t[1] === 'string' && bridgeAsciiLower(t[1]).includes(BRIDGE_CLIENT_MARK);
  if (t[0] === 'proxy') return typeof t[2] === 'string' && bridgeAsciiLower(t[2].trim()) === BRIDGE_PROXY_PROTOCOL;
  return false;
}
function isBridgeBlockedTags(tags) {
  return Array.isArray(tags) && tags.some(isBridgeTag);
}
function isBridgeBlockedEvent(ev) {
  return !!ev && typeof ev === 'object' && isBridgeBlockedTags(ev.tags);
}
function isBridgeBlockedFrame(raw) {
  if (typeof raw !== 'string' || !RX_BRIDGE_FRAME_HINT.test(raw)) return false;
  let v;
  try { v = JSON.parse(raw); } catch { return false; }
  if (Array.isArray(v)) v = v.find((x) => !!x && typeof x === 'object' && !Array.isArray(x));
  return isBridgeBlockedEvent(v);
}
export { isBridgeNick, isBridgeTag, isBridgeBlockedTags, isBridgeBlockedEvent, isBridgeBlockedFrame };
