// App attestation

import {
  schnorr,
  sha256,
  hmac,
  bytesToHex,
  hexToBytes,
  utf8ToBytes,
  concatBytes,
  randomBytes,
  botBase64Encode,
  botBase64Decode,
  getPublicKey
} from "./_shared.js";
import { APPLE_APP_ATTEST_ROOT_CA_PEM } from "./_apple-root.js";

const BADGE_VERSION = "1";
const BADGE_TAG = "nymattest";
// A badge outlives a normal upgrade cycle but not an abandoned device.
const BADGE_TTL_DAYS = 45;
const DAY_MS = 86400000;
// Long enough for App Attest and Play Integrity round trips on a slow network,
// short enough that a captured challenge is worthless by the time it is read.
const CHALLENGE_TTL_MS = 300000;
// One device may back a handful of identities — a random-keypair-per-session
// user churns through them legitimately — but not a farm of them.
const MAX_PUBKEYS_PER_DEVICE = 8;
const DEVICE_WINDOW_MS = 30 * DAY_MS;

const PLATFORMS = new Set(["ios", "android", "web"]);
// Only the platforms whose proof a third party cannot mint. `web` enrolls at
// the `origin` tier: a browser cannot attest itself, and no amount of
// server-side checking changes that.
const ATTESTED_PLATFORMS = new Set(["ios", "android"]);

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

function base64UrlEncode(bytes) {
  return botBase64Encode(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(str) {
  let s = String(str || "").replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return botBase64Decode(s);
}

function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function isHex64(s) {
  return typeof s === "string" && /^[0-9a-f]{64}$/.test(s);
}

// ---------------------------------------------------------------------------
// Authority key
// ---------------------------------------------------------------------------

// The order of the secp256k1 group. A private key must be in [1, n-1]; outside
// that range the curve math is undefined.
const SECP256K1_N = BigInt(
  "0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");

// bech32 (BIP-173), enough of it to read an `nsec1…`. The authority key is
// normally created in the app, and what the app shows you is an nsec — so
// requiring hex here means every operator hand-converts a secret key, which is
// both a chore and the sort of step that ends with the wrong 64 characters in
// production. The checksum is the reason to decode it properly rather than
// slicing the payload: a typo in an nsec fails loudly, where a typo in hex is
// just a different, valid-looking key.
const BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

function bech32Polymod(values) {
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const top = chk >>> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let j = 0; j < 5; j++) if ((top >>> j) & 1) chk ^= GEN[j];
  }
  return chk >>> 0;
}

function bech32HrpExpand(hrp) {
  const out = [];
  for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) >>> 5);
  out.push(0);
  for (let i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) & 31);
  return out;
}

// Returns the 32-byte payload of a bech32 string with the given prefix, or
// null. Never throws and never returns a partial decode: a caller that gets
// bytes back has a checksummed payload of exactly the right length.
function bech32Decode32(str, expectedHrp) {
  if (typeof str !== "string") return null;
  const s = str.trim().toLowerCase();
  // 1 (hrp) + 1 (separator) + 52 (32 bytes as 5-bit words) + 6 (checksum).
  if (s.length < 8 || s.length > 200) return null;
  const sep = s.lastIndexOf("1");
  if (sep < 1 || sep + 7 > s.length) return null;
  if (s.slice(0, sep) !== expectedHrp) return null;

  const words = [];
  for (let i = sep + 1; i < s.length; i++) {
    const v = BECH32_CHARSET.indexOf(s[i]);
    if (v < 0) return null;
    words.push(v);
  }
  if (bech32Polymod(bech32HrpExpand(expectedHrp).concat(words)) !== 1) return null;

  const data = words.slice(0, words.length - 6);
  let acc = 0, bits = 0;
  const out = [];
  for (const w of data) {
    acc = ((acc << 5) | w) >>> 0;
    bits += 5;
    while (bits >= 8) { bits -= 8; out.push((acc >>> bits) & 0xff); }
  }
  // Reject a payload whose leftover bits are not zero padding; otherwise two
  // distinct strings decode to the same key.
  if (bits >= 5 || ((acc << (8 - bits)) & 0xff) !== 0) return null;
  if (out.length !== 32) return null;
  return bytesToHex(new Uint8Array(out));
}

// The authority secret signs badges and nothing else. Keeping it off the key
// that runs the bot means a compromise of either does not hand over the other.
//
// Accepts the key as 64 hex characters or as an `nsec1…`; they are the same
// 32 bytes and the app only ever shows the second.
//
// The range check is not theater about `openssl rand` returning something
// invalid — that is a 1-in-2^128 event. It is about the values a human
// actually pastes: a row of zeros, a placeholder, half a key. Those are all
// 64 hex characters, and without this they reach schnorr.sign, which throws,
// and every enrollment becomes an unexplained 500 instead of the honest
// "attestation not configured".
function authoritySecret(env) {
  const raw = env && typeof env.ATTEST_AUTHORITY_SECRET === "string"
    ? env.ATTEST_AUTHORITY_SECRET.trim().toLowerCase() : "";
  const hex = isHex64(raw) ? raw : bech32Decode32(raw, "nsec");
  if (!hex) return null;
  let n;
  try { n = BigInt("0x" + hex); } catch (_) { return null; }
  if (n <= 0n || n >= SECP256K1_N) return null;
  return hex;
}

// The counterpart for the value pasted into PINNED_AUTHORITY: an operator who
// takes the secret from the app takes the public half from there too, and that
// is an npub.
function normalizeAuthorityPubkey(value) {
  const raw = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (isHex64(raw)) return raw;
  return bech32Decode32(raw, "npub");
}

function authorityPubkey(env) {
  const sec = authoritySecret(env);
  if (!sec) return null;
  try { return getPublicKey(sec); } catch (_) { return null; }
}

// ---------------------------------------------------------------------------
// Badges
// ---------------------------------------------------------------------------

// What the badge signature covers. The pubkey is in the message, so lifting a
// badge off someone else's event and pasting it onto your own fails: the event
// is signed by your key, and the badge names theirs.
function badgeDigest(pubkey, expDay, tier) {
  return bytesToHex(sha256(utf8ToBytes(`nymattest:${BADGE_VERSION}:${pubkey}:${expDay}:${tier}`)));
}

function dayOf(ms) {
  return Math.floor(ms / DAY_MS);
}

function issueBadge(env, pubkey, tier) {
  const sec = authoritySecret(env);
  if (!sec) return null;
  const expDay = dayOf(Date.now()) + BADGE_TTL_DAYS;
  const sig = schnorr.sign(badgeDigest(pubkey, expDay, tier), sec);
  return `${BADGE_VERSION}.${tier}.${expDay.toString(36)}.${base64UrlEncode(sig)}`;
}

// Mirrored verbatim by the PWA and the Flutter client; keep the three in step.
function verifyBadge(badge, pubkey, expectedAuthorityPubkey, nowMs) {
  if (typeof badge !== "string" || !isHex64(pubkey) || !isHex64(expectedAuthorityPubkey)) return null;
  const parts = badge.split(".");
  if (parts.length !== 4 || parts[0] !== BADGE_VERSION) return null;
  const tier = parts[1];
  // `attested` is hardware-backed and unmintable by a third party.
  // `challenged` is a browser that solved a domain-bound challenge for this
  // enrollment — a real cost, but a transferable one, so it is named apart.
  // `origin` is a browser and nothing more, which is what web was before the
  // challenge existed and what it falls back to if the challenge is off.
  if (tier !== "attested" && tier !== "challenged" && tier !== "origin") return null;
  const expDay = parseInt(parts[2], 36);
  if (!Number.isFinite(expDay) || expDay <= 0) return null;
  if (dayOf(typeof nowMs === "number" ? nowMs : Date.now()) > expDay) return null;
  let sig;
  try { sig = base64UrlDecode(parts[3]); } catch (_) { return null; }
  if (sig.length !== 64) return null;
  try {
    if (!schnorr.verify(bytesToHex(sig), badgeDigest(pubkey, expDay, tier), expectedAuthorityPubkey)) return null;
  } catch (_) { return null; }
  return { tier, expDay };
}

// ---------------------------------------------------------------------------
// Challenges
// ---------------------------------------------------------------------------

// Stateless: the MAC binds the nonce to the pubkey and an expiry, so a
// challenge needs no row and no round trip to check. The secret falls back to
// the authority key so a deployment has one fewer thing to set.
function challengeKey(env) {
  const raw = env && typeof env.ATTEST_CHALLENGE_SECRET === "string"
    ? env.ATTEST_CHALLENGE_SECRET.trim() : "";
  if (raw) return utf8ToBytes(raw);
  const sec = authoritySecret(env);
  return sec ? hexToBytes(sec) : null;
}

function issueChallenge(env, pubkey) {
  const key = challengeKey(env);
  if (!key || !isHex64(pubkey)) return null;
  const nonce = bytesToHex(randomBytes(16));
  const exp = Date.now() + CHALLENGE_TTL_MS;
  const mac = bytesToHex(hmac(sha256, key, utf8ToBytes(`${nonce}:${exp}:${pubkey}`)));
  return { challenge: `${nonce}.${exp}.${mac}`, expiresAt: exp };
}

// ---------------------------------------------------------------------------
// Enrollment proof of work
// ---------------------------------------------------------------------------

// Nymchat already mines every public channel message to 16 bits, and this is
// not that. The two tax different things, and only one of them is the problem.
//
// Per-message work taxes VOLUME: a sender pays per message, and a fresh key
// costs nothing. That is exactly backwards for the attack the badge filter
// exists to stop, which is a new key per message. Left free, a bot enrolls
// each throwaway key, gets a real badge, pays its 65k hashes for the message,
// and sails through "any verified Nymchat client" — the filter defeated by
// the one thing it was built for.
//
// Per-enrollment work taxes IDENTITIES: once per key per badge term. And the
// budget is completely different. Message work has to stay cheap because
// every user pays it on every message while waiting to see it send; 16 bits
// is about the ceiling. Enrollment work happens once every 38 days in the
// background, with nothing waiting on it, so it can cost hundreds of times
// more. A thousand fake identities stop being a thousand HTTP requests.
//
// The work is carried by the NIP-98 auth event that already accompanies an
// enrollment, so there is no extra field on the wire: that event is signed by
// the enrolling key and carries the server's challenge in a tag, so the work
// cannot be precomputed before the challenge is issued, cannot be spent on a
// second pubkey, and is already hashed here to check the signature.
//
// Unlike a captcha, the cost is identical on Tor, a VPN, or a fibre line.
const ENROLL_POW_DEFAULT_BITS = 22;
const ENROLL_POW_MAX_BITS = 28;

function enrollPowBits(env) {
  const raw = env && env.ATTEST_POW_BITS;
  if (raw === undefined || raw === null || raw === "") return ENROLL_POW_DEFAULT_BITS;
  const n = parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 0) return ENROLL_POW_DEFAULT_BITS;
  return Math.min(ENROLL_POW_MAX_BITS, n);
}

// Leading zero bits of a hex id, the NIP-13 way.
function powBitsForId(id) {
  if (typeof id !== "string") return 0;
  let bits = 0;
  for (const ch of id) {
    const v = parseInt(ch, 16);
    if (!Number.isFinite(v)) return bits;
    if (v === 0) { bits += 4; continue; }
    bits += Math.clz32(v) - 28;
    break;
  }
  return bits;
}

// No commitment check here, unlike the message filter. There the sender picks
// the target, so a cheap target plus luck has to be refused; here the server
// picks it, and an id with this many zeros costs the same expected work
// however the caller got there.
function enrollPowOk(env, auth) {
  const need = enrollPowBits(env);
  if (need <= 0) return true;
  return powBitsForId(auth && auth.id) >= need;
}

// ---------------------------------------------------------------------------
// Build proof — the floor under the web tier
// ---------------------------------------------------------------------------

// A browser cannot attest itself, and nothing here changes that: the bundle is
// public, so every input to this proof is public, and a determined script can
// fetch the same files and hash them the same way. What it is worth is narrower
// and still real.
//
// The server names a few asset paths per enrollment, derived from that
// enrollment's own challenge, and the caller must return their current hashes.
// Be precise about what that costs an attacker: not one fetch per enrollment,
// because a farm can scrape every asset hash once and answer any probe from
// the table. It costs a re-scrape of the bundle on every deploy, and it means
// the answer is never a single constant that can be hardcoded. So this is the
// difference between free and cheap — not between forgeable and unforgeable,
// which is why the tier it earns is `challenged` and never `attested`.
//
// The browser pays nothing for it: these are the files it just loaded, so the
// fetches come out of its own cache.
const BUILD_MANIFEST_PATH = "/build-manifest.json";
const BUILD_PROBE_COUNT = 4;
const BUILD_MANIFEST_TTL_MS = 300000;

let buildManifestCache = null;

// The manifest the running deployment serves. Same origin, so this is the
// deployment describing itself — which is the right comparison here: we are
// asking "did the caller load THIS build", not "is this build official". The
// About dialog answers the second question, against GitHub's attestations.
async function buildManifestFiles(origin) {
  const now = Date.now();
  if (buildManifestCache && buildManifestCache.origin === origin
    && now - buildManifestCache.at < BUILD_MANIFEST_TTL_MS) {
    return buildManifestCache.files;
  }
  try {
    const res = await fetch(origin + BUILD_MANIFEST_PATH, { cf: { cacheTtl: 300 } });
    if (!res.ok) return null;
    const manifest = await res.json();
    const files = manifest && manifest.files;
    if (!files || typeof files !== "object") return null;
    buildManifestCache = { origin, at: now, files };
    return files;
  } catch (_) {
    return null;
  }
}

// Which paths to ask for, derived from the challenge so nothing has to be
// stored between issuing it and verifying the answer. The challenge is already
// HMAC'd, so a caller cannot steer the selection toward paths it has cached.
function buildProbePaths(files, challenge, count) {
  const paths = Object.keys(files).sort();
  if (!paths.length) return [];
  const digest = sha256(utf8ToBytes(`nymbuildprobe:${challenge}`));
  const out = [];
  const used = new Set();
  for (let i = 0; i + 1 < digest.length && out.length < count; i += 2) {
    const idx = ((digest[i] << 8) | digest[i + 1]) % paths.length;
    if (used.has(idx)) continue;
    used.add(idx);
    out.push(paths[idx]);
  }
  return out;
}

async function verifyBuildProof(origin, challenge, proof) {
  const files = await buildManifestFiles(origin);
  // Fail closed. The manifest is a static file on our own origin, so this is
  // an outage rather than an attack — but a badge issued without the check is
  // a badge that means nothing.
  if (!files) return { ok: false, reason: "build-manifest-unavailable" };
  const want = buildProbePaths(files, challenge, BUILD_PROBE_COUNT);
  if (!want.length) return { ok: false, reason: "build-no-probe" };
  if (!proof || typeof proof !== "object") return { ok: false, reason: "build-missing" };
  for (const path of want) {
    if (typeof proof[path] !== "string" || proof[path] !== files[path]) {
      return { ok: false, reason: "build-mismatch" };
    }
  }
  return { ok: true, probed: want.length };
}

function verifyChallenge(env, pubkey, challenge) {
  const key = challengeKey(env);
  if (!key || !isHex64(pubkey) || typeof challenge !== "string") return false;
  const parts = challenge.split(".");
  if (parts.length !== 3) return false;
  const [nonce, expStr, mac] = parts;
  const exp = Number(expStr);
  if (!Number.isFinite(exp) || Date.now() > exp) return false;
  const want = bytesToHex(hmac(sha256, key, utf8ToBytes(`${nonce}:${exp}:${pubkey}`)));
  return timingSafeEqual(mac, want);
}

// Both platforms bind their proof to a hash of the challenge rather than the
// challenge itself: Play Integrity as requestHash, App Attest as clientDataHash.
function challengeHash(challenge) {
  return sha256(utf8ToBytes(challenge));
}

// ---------------------------------------------------------------------------
// Minimal CBOR (App Attest objects only: maps, arrays, byte/text strings, ints)
// ---------------------------------------------------------------------------

function cborDecode(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let pos = 0;

  function need(n) {
    if (pos + n > bytes.length) throw new Error("cbor truncated");
  }

  function readLength(info) {
    if (info < 24) return info;
    if (info === 24) { need(1); return bytes[pos++]; }
    if (info === 25) { need(2); const v = view.getUint16(pos); pos += 2; return v; }
    if (info === 26) { need(4); const v = view.getUint32(pos); pos += 4; return v; }
    if (info === 27) {
      need(8);
      const hi = view.getUint32(pos), lo = view.getUint32(pos + 4);
      pos += 8;
      const v = hi * 4294967296 + lo;
      if (!Number.isSafeInteger(v)) throw new Error("cbor length too large");
      return v;
    }
    throw new Error("cbor indefinite length");
  }

  function readItem() {
    need(1);
    const initial = bytes[pos++];
    const major = initial >> 5;
    const info = initial & 0x1f;
    switch (major) {
      case 0: return readLength(info);
      case 1: return -1 - readLength(info);
      case 2: {
        const len = readLength(info);
        need(len);
        const out = bytes.slice(pos, pos + len);
        pos += len;
        return out;
      }
      case 3: {
        const len = readLength(info);
        need(len);
        const out = new TextDecoder().decode(bytes.subarray(pos, pos + len));
        pos += len;
        return out;
      }
      case 4: {
        const len = readLength(info);
        const arr = [];
        for (let i = 0; i < len; i++) arr.push(readItem());
        return arr;
      }
      case 5: {
        const len = readLength(info);
        const map = new Map();
        for (let i = 0; i < len; i++) {
          const k = readItem();
          map.set(typeof k === "string" ? k : String(k), readItem());
        }
        return map;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        throw new Error("cbor unsupported simple value");
      default:
        throw new Error("cbor unsupported major type");
    }
  }

  const value = readItem();
  return value;
}

// ---------------------------------------------------------------------------
// Minimal DER / X.509
// ---------------------------------------------------------------------------

// Returns { tag, headerLen, len, start, end, content } for the TLV at `pos`.
function derRead(bytes, pos) {
  if (pos + 2 > bytes.length) throw new Error("der truncated");
  const tag = bytes[pos];
  let i = pos + 1;
  let len = bytes[i++];
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4) throw new Error("der bad length");
    if (i + n > bytes.length) throw new Error("der truncated");
    len = 0;
    for (let k = 0; k < n; k++) len = (len << 8) | bytes[i++];
  }
  const start = i;
  const end = start + len;
  if (end > bytes.length) throw new Error("der truncated");
  return { tag, headerLen: start - pos, len, start, end, content: bytes.subarray(start, end) };
}

function derChildren(bytes) {
  const out = [];
  let pos = 0;
  while (pos < bytes.length) {
    const tlv = derRead(bytes, pos);
    out.push({ ...tlv, raw: bytes.subarray(pos, tlv.end) });
    pos = tlv.end;
  }
  return out;
}

// Pulls out everything App Attest needs to check a certificate: the exact bytes
// the issuer signed, the signature, the SPKI, and the extensions by OID.
function parseCertificate(der) {
  const cert = derRead(der, 0);
  if (cert.tag !== 0x30) throw new Error("cert not a sequence");
  const top = derChildren(der.subarray(cert.start, cert.end));
  if (top.length < 3) throw new Error("cert too short");
  const tbsRaw = top[0].raw;
  const sigAlgOid = derAlgorithmOid(top[1]);
  const sigBitString = top[2];
  if (sigBitString.tag !== 0x03 || sigBitString.len < 1) throw new Error("cert bad signature");
  const signature = sigBitString.content.subarray(1);

  const tbs = derChildren(tbsRaw.subarray(top[0].headerLen));
  let idx = 0;
  if (tbs[0] && tbs[0].tag === 0xa0) idx = 1;       // [0] EXPLICIT version
  const serial = tbs[idx];                           // serialNumber
  const issuer = tbs[idx + 2];                       // issuer Name
  const validity = tbs[idx + 3];
  const subject = tbs[idx + 4];                      // subject Name
  const spki = tbs[idx + 5];                         // SubjectPublicKeyInfo
  if (!serial || !issuer || !subject || !spki) throw new Error("cert missing fields");

  const extensions = new Map();
  for (let i = idx + 6; i < tbs.length; i++) {
    if (tbs[i].tag !== 0xa3) continue;               // [3] EXPLICIT extensions
    const seq = derRead(tbs[i].raw, tbs[i].headerLen);
    for (const ext of derChildren(seq.content)) {
      const parts = derChildren(ext.content);
      if (!parts.length || parts[0].tag !== 0x06) continue;
      const oid = derOidToString(parts[0].content);
      const value = parts[parts.length - 1];
      if (value.tag === 0x04) extensions.set(oid, value.content);
    }
  }

  return {
    der,
    tbsRaw,
    signature,
    sigAlgOid,
    spkiDer: spki.raw,
    issuerRaw: issuer.raw,
    subjectRaw: subject.raw,
    validityRaw: validity ? validity.raw : null,
    extensions
  };
}

function derOidToString(content) {
  if (!content.length) return "";
  const parts = [Math.floor(content[0] / 40), content[0] % 40];
  let value = 0;
  for (let i = 1; i < content.length; i++) {
    value = value * 128 + (content[i] & 0x7f);
    if (!(content[i] & 0x80)) { parts.push(value); value = 0; }
  }
  return parts.join(".");
}

// The OID of an AlgorithmIdentifier SEQUENCE.
function derAlgorithmOid(tlv) {
  if (!tlv || tlv.tag !== 0x30) return "";
  const parts = derChildren(tlv.raw.subarray(tlv.headerLen));
  return parts.length && parts[0].tag === 0x06 ? derOidToString(parts[0].content) : "";
}

// The uncompressed EC point (0x04 || X || Y) inside a SubjectPublicKeyInfo.
function ecPointFromSpki(spkiDer) {
  const seq = derRead(spkiDer, 0);
  const children = derChildren(spkiDer.subarray(seq.start, seq.end));
  const bitString = children[children.length - 1];
  if (!bitString || bitString.tag !== 0x03 || bitString.len < 2) throw new Error("spki bad bit string");
  return bitString.content.subarray(1);
}

const CURVE_OIDS = { "1.2.840.10045.3.1.7": "P-256", "1.3.132.0.34": "P-384", "1.3.132.0.35": "P-521" };
const HASH_OIDS = {
  "1.2.840.10045.4.3.2": "SHA-256",
  "1.2.840.10045.4.3.3": "SHA-384",
  "1.2.840.10045.4.3.4": "SHA-512"
};
const CURVE_SIZES = { "P-256": 32, "P-384": 48, "P-521": 66 };

// Which curve the KEY is on, read from the SPKI's own parameters. Apple's chain
// mixes sizes, so neither end of a link may be assumed from the other.
function curveFromSpki(spkiDer) {
  const seq = derRead(spkiDer, 0);
  const children = derChildren(spkiDer.subarray(seq.start, seq.end));
  if (!children.length || children[0].tag !== 0x30) return null;
  const alg = derChildren(children[0].raw.subarray(children[0].headerLen));
  if (alg.length < 2 || alg[1].tag !== 0x06) return null;
  return CURVE_OIDS[derOidToString(alg[1].content)] || null;
}

// WebCrypto wants r||s; X.509 carries a DER SEQUENCE of two INTEGERs.
function derSignatureToRaw(sig, size) {
  const seq = derRead(sig, 0);
  const [r, s] = derChildren(sig.subarray(seq.start, seq.end));
  if (!r || !s || r.tag !== 0x02 || s.tag !== 0x02) throw new Error("bad ecdsa signature");
  const out = new Uint8Array(size * 2);
  const put = (tlv, offset) => {
    let v = tlv.content;
    while (v.length > 1 && v[0] === 0) v = v.subarray(1);
    if (v.length > size) throw new Error("ecdsa component too long");
    out.set(v, offset + size - v.length);
  };
  put(r, 0);
  put(s, size);
  return out;
}

async function verifyCertSignature(child, issuerSpkiDer) {
  const curve = curveFromSpki(issuerSpkiDer);
  const hash = HASH_OIDS[child.sigAlgOid];
  if (!curve || !hash) return false;
  let key;
  try {
    key = await crypto.subtle.importKey(
      "spki", issuerSpkiDer, { name: "ECDSA", namedCurve: curve }, false, ["verify"]
    );
  } catch (_) {
    return false;
  }
  let raw;
  try { raw = derSignatureToRaw(child.signature, CURVE_SIZES[curve]); } catch (_) { return false; }
  return crypto.subtle.verify({ name: "ECDSA", hash }, key, raw, child.tbsRaw).catch(() => false);
}

function pemToDer(pem) {
  const body = String(pem || "").replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  // atob is lenient about length in some runtimes, so a non-base64 string can
  // come back as bytes rather than throwing. Reject the shape up front, or a
  // pasted-wrong root reads as a parse failure three checks later instead of
  // naming itself.
  if (!body || body.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(body)) return null;
  try { return botBase64Decode(body); } catch (_) { return null; }
}

// ---------------------------------------------------------------------------
// Apple App Attest
// ---------------------------------------------------------------------------

const APPLE_NONCE_OID = "1.2.840.113635.100.8.2";

// The bundled root is the default, and it is bundled rather than configured
// because the chain is the entire proof: an operator who forgot an env var
// would otherwise find iOS attestation silently off, and one who pasted the
// wrong PEM would get a check that passes for the wrong root. What makes
// bundling safe is that no human typed it — .github/workflows/apple-attest-root.yml
// fetched it from Apple on a runner, asserted the subject and the self-signature,
// and committed it in the run that fetched it.
//
// APPLE_APP_ATTEST_ROOT_CA still overrides, for a rotation that has to ship
// faster than a deploy.
function appleRootDer(env) {
  return pemToDer((env && env.APPLE_APP_ATTEST_ROOT_CA) || APPLE_APP_ATTEST_ROOT_CA_PEM);
}

async function verifyAppAttest(env, { keyId, attestation, challenge }) {
  const teamId = (env && env.APPLE_TEAM_ID) || "";
  const bundleId = (env && env.APPLE_BUNDLE_ID) || "";
  const rootDer = appleRootDer(env);
  if (!teamId || !bundleId) return { ok: false, reason: "ios-not-configured" };
  // The root is read BEFORE the attestation. A root that will not parse is a
  // configuration mistake, and it should be reported as one rather than as
  // whichever attestation check happens to fail first behind it.
  let root = null;
  if (rootDer) { try { root = parseCertificate(rootDer); } catch (_) { root = null; } }
  if (!root) return { ok: false, reason: "ios-root-invalid" };
  if (typeof keyId !== "string" || typeof attestation !== "string") {
    return { ok: false, reason: "malformed" };
  }

  let obj, keyIdBytes;
  try {
    obj = cborDecode(base64UrlDecode(attestation));
    keyIdBytes = base64UrlDecode(keyId);
  } catch (_) {
    return { ok: false, reason: "malformed" };
  }
  if (!(obj instanceof Map) || obj.get("fmt") !== "apple-appattest") {
    return { ok: false, reason: "bad-format" };
  }
  const attStmt = obj.get("attStmt");
  const authData = obj.get("authData");
  if (!(attStmt instanceof Map) || !(authData instanceof Uint8Array)) {
    return { ok: false, reason: "bad-format" };
  }
  const x5c = attStmt.get("x5c");
  if (!Array.isArray(x5c) || x5c.length < 2) return { ok: false, reason: "bad-chain" };

  let credCert, chain;
  try {
    chain = x5c.map((c) => parseCertificate(c));
    credCert = chain[0];
  } catch (_) {
    return { ok: false, reason: "bad-chain" };
  }

  // Chain: each certificate signed by the next, the last by Apple's root.
  for (let i = 0; i < chain.length; i++) {
    const issuerSpki = i + 1 < chain.length ? chain[i + 1].spkiDer : root.spkiDer;
    if (!(await verifyCertSignature(chain[i], issuerSpki))) {
      return { ok: false, reason: "chain-signature" };
    }
  }
  if (bytesToHex(chain[chain.length - 1].issuerRaw) !== bytesToHex(root.subjectRaw)) {
    return { ok: false, reason: "chain-root-mismatch" };
  }

  // The nonce Apple's extension carries is sha256(authData || sha256(challenge)),
  // which is what ties this certificate to THIS enrollment rather than a replay
  // of an attestation the device produced earlier for someone else.
  const expectedNonce = sha256(concatBytes(authData, challengeHash(challenge)));
  const ext = credCert.extensions.get(APPLE_NONCE_OID);
  if (!ext) return { ok: false, reason: "nonce-missing" };
  let extNonce;
  try {
    const seq = derRead(ext, 0);
    const inner = derChildren(seq.content);
    const tagged = inner.find((c) => c.tag === 0xa1) || inner[0];
    const octet = derChildren(tagged.content).find((c) => c.tag === 0x04);
    extNonce = octet ? octet.content : null;
  } catch (_) {
    return { ok: false, reason: "nonce-malformed" };
  }
  if (!extNonce || bytesToHex(extNonce) !== bytesToHex(expectedNonce)) {
    return { ok: false, reason: "nonce-mismatch" };
  }

  // keyId is the digest of the attested key, so this is what stops one device
  // from presenting a certificate and then asserting with a different key.
  let publicKeyPoint;
  try { publicKeyPoint = ecPointFromSpki(credCert.spkiDer); } catch (_) {
    return { ok: false, reason: "bad-key" };
  }
  if (bytesToHex(sha256(publicKeyPoint)) !== bytesToHex(keyIdBytes)) {
    return { ok: false, reason: "keyid-mismatch" };
  }

  // authData: rpIdHash(32) || flags(1) || counter(4) || aaguid(16) || credIdLen(2) || credId
  if (authData.length < 55) return { ok: false, reason: "authdata-short" };
  const rpIdHash = authData.subarray(0, 32);
  if (bytesToHex(rpIdHash) !== bytesToHex(sha256(utf8ToBytes(`${teamId}.${bundleId}`)))) {
    return { ok: false, reason: "app-mismatch" };
  }
  const counter = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
  if (counter !== 0) return { ok: false, reason: "counter-not-zero" };
  const aaguid = new TextDecoder().decode(authData.subarray(37, 53)).replace(/\0+$/, "");
  const allowDevelopment = env && env.APPLE_APP_ATTEST_ALLOW_DEVELOPMENT === "1";
  if (aaguid !== "appattest" && !(allowDevelopment && aaguid === "appattestdevelop")) {
    return { ok: false, reason: "environment-mismatch" };
  }
  const credIdLen = (authData[53] << 8) | authData[54];
  const credId = authData.subarray(55, 55 + credIdLen);
  if (credIdLen !== keyIdBytes.length || bytesToHex(credId) !== bytesToHex(keyIdBytes)) {
    return { ok: false, reason: "credid-mismatch" };
  }

  return { ok: true, deviceId: bytesToHex(sha256(keyIdBytes)) };
}

// ---------------------------------------------------------------------------
// Google Play Integrity
// ---------------------------------------------------------------------------

async function googleAccessToken(env) {
  const email = env && env.PLAY_INTEGRITY_SA_EMAIL;
  const pem = env && env.PLAY_INTEGRITY_SA_KEY;
  if (!email || !pem) return null;
  const der = pemToDer(pem);
  if (!der) return null;
  let key;
  try {
    key = await crypto.subtle.importKey(
      "pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]
    );
  } catch (_) {
    return null;
  }
  const now = Math.floor(Date.now() / 1000);
  const header = base64UrlEncode(utf8ToBytes(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const claims = base64UrlEncode(utf8ToBytes(JSON.stringify({
    iss: email,
    scope: "https://www.googleapis.com/auth/playintegrity",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600
  })));
  const signingInput = `${header}.${claims}`;
  const sig = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", key, utf8ToBytes(signingInput)
  ));
  const assertion = `${signingInput}.${base64UrlEncode(sig)}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion
    })
  });
  if (!res.ok) return null;
  const body = await res.json().catch(() => null);
  return body && typeof body.access_token === "string" ? body.access_token : null;
}

async function verifyPlayIntegrity(env, { token, challenge }) {
  const packageName = env && env.ANDROID_PACKAGE_NAME;
  const certDigests = String((env && env.ANDROID_CERT_SHA256) || "")
    .split(",").map((s) => s.trim()).filter(Boolean);
  if (!packageName || certDigests.length === 0) return { ok: false, reason: "android-not-configured" };
  if (typeof token !== "string" || !token) return { ok: false, reason: "malformed" };

  const accessToken = await googleAccessToken(env);
  if (!accessToken) return { ok: false, reason: "android-credentials" };

  const res = await fetch(
    `https://playintegrity.googleapis.com/v1/${encodeURIComponent(packageName)}:decodeIntegrityToken`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
      body: JSON.stringify({ integrity_token: token })
    }
  );
  if (!res.ok) return { ok: false, reason: "decode-failed" };
  const body = await res.json().catch(() => null);
  const payload = body && body.tokenPayloadExternal;
  if (!payload) return { ok: false, reason: "decode-failed" };

  const details = payload.requestDetails || {};
  if (details.requestPackageName !== packageName) return { ok: false, reason: "package-mismatch" };
  // requestHash is the only part of the verdict we control, so it is the part
  // that makes this verdict about this enrollment.
  if (details.requestHash !== base64UrlEncode(challengeHash(challenge))) {
    return { ok: false, reason: "challenge-mismatch" };
  }
  const issuedMs = Number(details.timestampMillis);
  if (!Number.isFinite(issuedMs) || Math.abs(Date.now() - issuedMs) > CHALLENGE_TTL_MS) {
    return { ok: false, reason: "stale-verdict" };
  }

  const app = payload.appIntegrity || {};
  if (app.appRecognitionVerdict !== "PLAY_RECOGNIZED") return { ok: false, reason: "app-not-recognized" };
  if (app.packageName !== packageName) return { ok: false, reason: "package-mismatch" };
  const digests = Array.isArray(app.certificateSha256Digest) ? app.certificateSha256Digest : [];
  if (!digests.some((d) => certDigests.includes(d))) return { ok: false, reason: "signature-mismatch" };

  const device = payload.deviceIntegrity || {};
  const verdicts = Array.isArray(device.deviceRecognitionVerdict) ? device.deviceRecognitionVerdict : [];
  if (!verdicts.includes("MEETS_DEVICE_INTEGRITY")) return { ok: false, reason: "device-integrity" };

  // Play Integrity hands back a per-app-install stable id when the developer
  // enables it; without one the enrollment cap falls back to the token digest,
  // which is per-request and so caps nothing. That is why the cap is a
  // secondary defense and the verdict is the primary one.
  const account = payload.accountDetails || {};
  const stable = (device.recentDeviceActivity && device.recentDeviceActivity.deviceActivityLevel)
    || account.appLicensingVerdict || "";
  return { ok: true, deviceId: bytesToHex(sha256(utf8ToBytes(`android:${packageName}:${stable}:${token.slice(0, 64)}`))) };
}

// ---------------------------------------------------------------------------
// D1 ledger
// ---------------------------------------------------------------------------

let schemaReady = false;

async function ensureAttestSchema(db) {
  if (schemaReady) return;
  await db.batch([
    db.prepare(
      "CREATE TABLE IF NOT EXISTS app_attestations (" +
      "pubkey TEXT PRIMARY KEY, platform TEXT NOT NULL, tier TEXT NOT NULL, " +
      "device_id TEXT, attested_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, " +
      "revoked_at INTEGER NOT NULL DEFAULT 0)"
    ),
    db.prepare("CREATE INDEX IF NOT EXISTS app_attestations_device ON app_attestations (device_id, attested_at)"),
    db.prepare("CREATE INDEX IF NOT EXISTS app_attestations_at ON app_attestations (attested_at)")
  ]);
  schemaReady = true;
}

function attestDb(env) {
  const db = env && env.DB_CHANNELS;
  return db && typeof db.prepare === "function" ? db : null;
}

async function deviceAtCap(db, deviceId, pubkey) {
  if (!deviceId) return false;
  const since = Date.now() - DEVICE_WINDOW_MS;
  const row = await db.prepare(
    "SELECT COUNT(*) AS n FROM app_attestations WHERE device_id = ? AND pubkey != ? AND attested_at > ? AND revoked_at = 0"
  ).bind(deviceId, pubkey, since).first();
  return !!row && Number(row.n) >= MAX_PUBKEYS_PER_DEVICE;
}

async function recordAttestation(db, { pubkey, platform, tier, deviceId, expiresAt }) {
  const now = Date.now();
  await db.prepare(
    "INSERT INTO app_attestations (pubkey, platform, tier, device_id, attested_at, expires_at, revoked_at) " +
    "VALUES (?, ?, ?, ?, ?, ?, 0) ON CONFLICT(pubkey) DO UPDATE SET " +
    "platform = excluded.platform, tier = excluded.tier, device_id = excluded.device_id, " +
    "attested_at = excluded.attested_at, expires_at = excluded.expires_at, revoked_at = 0"
  ).bind(pubkey, platform, tier, deviceId || null, now, expiresAt).run();
}

async function lookupAttestations(db, pubkeys) {
  if (!Array.isArray(pubkeys) || pubkeys.length === 0) return [];
  const clean = pubkeys.filter(isHex64).slice(0, 200);
  if (clean.length === 0) return [];
  const ph = clean.map(() => "?").join(",");
  const res = await db.prepare(
    "SELECT pubkey, platform, tier, expires_at FROM app_attestations " +
    `WHERE pubkey IN (${ph}) AND revoked_at = 0 AND expires_at > ?`
  ).bind(...clean, Date.now()).all();
  return (res && res.results) || [];
}

// Revocations are the short list, so that is the list clients pull. A badge
// stays valid for its whole term otherwise, which is the point of it.
async function listRevoked(db, since) {
  const res = await db.prepare(
    "SELECT pubkey, revoked_at FROM app_attestations WHERE revoked_at > ? ORDER BY revoked_at ASC LIMIT 5000"
  ).bind(Number.isFinite(since) ? since : 0).all();
  return (res && res.results) || [];
}

async function revokeAttestation(db, pubkey) {
  await db.prepare("UPDATE app_attestations SET revoked_at = ? WHERE pubkey = ? AND revoked_at = 0")
    .bind(Date.now(), pubkey).run();
}

async function isRevoked(db, pubkey) {
  const row = await db.prepare("SELECT revoked_at FROM app_attestations WHERE pubkey = ?")
    .bind(pubkey).first();
  return !!row && Number(row.revoked_at) > 0;
}

export {
  BADGE_TAG,
  BADGE_TTL_DAYS,
  PLATFORMS,
  ATTESTED_PLATFORMS,
  MAX_PUBKEYS_PER_DEVICE,
  authoritySecret,
  authorityPubkey,
  normalizeAuthorityPubkey,
  issueBadge,
  verifyBadge,
  issueChallenge,
  verifyChallenge,
  enrollPowBits,
  enrollPowOk,
  powBitsForId,
  buildManifestFiles,
  buildProbePaths,
  verifyBuildProof,
  challengeHash,
  verifyAppAttest,
  verifyPlayIntegrity,
  attestDb,
  ensureAttestSchema,
  deviceAtCap,
  recordAttestation,
  lookupAttestations,
  listRevoked,
  revokeAttestation,
  isRevoked,
  base64UrlEncode,
  base64UrlDecode,
  cborDecode,
  parseCertificate,
  derSignatureToRaw,
  ecPointFromSpki,
  curveFromSpki,
  verifyCertSignature,
  pemToDer
};
