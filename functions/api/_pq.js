// _pq.js — hybrid post-quantum (ML-KEM-768) support for the Nymbot worker.

import { ml_kem768 } from "./_mlkem.js";
import {
  getPublicKey,
  getEventHash,
  signEvent,
  nip44ConversationKey,
  nip44Encrypt,
  nip44Decrypt,
  hkdfExpand,
  randomTimestampNow,
  bytesToHex,
  hexToBytes,
  utf8ToBytes,
  concatBytes,
  randomBytes,
  hmac,
  sha256,
  secp256k1,
  schnorr
} from "./_shared.js";

var PQ_PREFIX = "pq1.";
var PQ2_PREFIX = "pq2.";
var PQ_COMBINER_SALT = "nymchat-pq-v1";
var PQ2_SALT = "nymchat-pq2-v1";
var PQ2_LABEL = "nymchat-pq2";
var PQ_ROOT_SEED_SALT = "nym-pq-root-v2";
var PQ_ROOT_HRP = "nympq";
var PQ_ROOT_LEN = 32;
var PQ_KEM_CT_LEN = 1088;
var PQ_KEM_PK_LEN = 1184;
var PQ_D_TAG = "nym-pq";
var PQ_ALG = "mlkem768";
var PQ_TTL_SEC = 7 * 24 * 3600;

// ---------------------------------------------------------------------------
// base64url
// ---------------------------------------------------------------------------

function b64uEncode(bytes) {
  var s = "";
  for (var i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64uDecode(str) {
  var s = String(str).replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  var bin = atob(s);
  var out = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ---------------------------------------------------------------------------
// bech32 (BIP-173) — decoding the `nympq1…` root code. nip19-style helpers are
// not available server-side, so this is the same plain decoder the client
// carries for the custom HRP.
// ---------------------------------------------------------------------------

var BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

function bech32Polymod(values) {
  var GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (var i = 0; i < values.length; i++) {
    var top = chk >>> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ values[i];
    for (var j = 0; j < 5; j++) if ((top >>> j) & 1) chk ^= GEN[j];
  }
  return chk >>> 0;
}

function bech32HrpExpand(hrp) {
  var out = [];
  for (var i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) >>> 5);
  out.push(0);
  for (var j = 0; j < hrp.length; j++) out.push(hrp.charCodeAt(j) & 31);
  return out;
}

function bech32Decode(str) {
  if (typeof str !== "string") throw new Error("bech32: not a string");
  var s = str.trim();
  if (s.length < 8 || s.length > 2000) throw new Error("bech32: bad length");
  var lower = s.toLowerCase();
  if (s !== lower && s !== s.toUpperCase()) throw new Error("bech32: mixed case");
  var sep = lower.lastIndexOf("1");
  if (sep < 1 || sep + 7 > lower.length) throw new Error("bech32: no separator");
  var hrp = lower.slice(0, sep);
  for (var i = 0; i < hrp.length; i++) {
    var c = hrp.charCodeAt(i);
    if (c < 33 || c > 126) throw new Error("bech32: bad hrp");
  }
  var words = [];
  for (var k = sep + 1; k < lower.length; k++) {
    var v = BECH32_CHARSET.indexOf(lower[k]);
    if (v < 0) throw new Error("bech32: bad character");
    words.push(v);
  }
  if (bech32Polymod(bech32HrpExpand(hrp).concat(words)) !== 1) {
    throw new Error("bech32: bad checksum");
  }
  return { prefix: hrp, words: words.slice(0, words.length - 6) };
}

function bech32FromWords(words) {
  var acc = 0, bits = 0;
  var out = [];
  for (var i = 0; i < words.length; i++) {
    var w = words[i];
    if (!Number.isInteger(w) || w < 0 || w > 31) throw new Error("bech32: bad word");
    acc = ((acc << 5) | w) >>> 0;
    bits += 5;
    while (bits >= 8) { bits -= 8; out.push((acc >>> bits) & 0xff); }
  }
  if (bits >= 5 || ((acc << (8 - bits)) & 0xff) !== 0) throw new Error("bech32: bad padding");
  return new Uint8Array(out);
}

/// Decodes a `nympq1…` code to its 32 root bytes; throws on anything
/// malformed — a bad checksum must never surface as key material.
function pqRootDecode(code) {
  var d = bech32Decode(code);
  if (d.prefix !== PQ_ROOT_HRP) throw new Error("not a " + PQ_ROOT_HRP + " code");
  var bytes = bech32FromWords(d.words);
  if (bytes.length !== PQ_ROOT_LEN) throw new Error("bad " + PQ_ROOT_HRP + " length");
  return bytes;
}

// ---------------------------------------------------------------------------
// Key derivation (spec §2)
// ---------------------------------------------------------------------------

// RFC 5869: PRK = HMAC-Hash(salt, IKM). The client's _hkdfExtract has the
// same (ikm, salt) → hmac(salt, ikm) shape.
function hkdfExtract(saltBytes, ikm) {
  return hmac(sha256, saltBytes, ikm);
}

function pqRootDeriveSeed(rootBytes, epoch) {
  if (!(rootBytes instanceof Uint8Array) || rootBytes.length !== PQ_ROOT_LEN) {
    throw new Error("bad pq root");
  }
  var prk = hkdfExtract(utf8ToBytes(PQ_ROOT_SEED_SALT), rootBytes);
  return hkdfExpand(prk, utf8ToBytes("mlkem768/epoch/" + (epoch >>> 0)), 64);
}

function pqKeypairFromRoot(rootBytes, epoch) {
  var kp = ml_kem768.keygen(pqRootDeriveSeed(rootBytes, epoch));
  return { publicKey: kp.publicKey, secretKey: kp.secretKey };
}

// ---------------------------------------------------------------------------
// pq1 — the combined construction
// ---------------------------------------------------------------------------

// secp256k1 ECDH exactly as NIP-44 does it: lift the x-only pubkey to the
// even-y point and take the 32-byte big-endian x of the shared point.
function ecdhSharedX(skHex, pubHex) {
  var shared = secp256k1.getSharedSecret(hexToBytes(skHex), hexToBytes("02" + pubHex));
  return shared.slice(1, 33);
}

function pqConversationKey(ecdhX, kemSs, kemCt, recipKemPk, senderPkHex, recipPkHex) {
  var ikm = concatBytes(
    ecdhX, kemSs, kemCt, recipKemPk,
    hexToBytes(senderPkHex), hexToBytes(recipPkHex)
  );
  return hkdfExtract(utf8ToBytes(PQ_COMBINER_SALT), ikm);
}

function isPq1Payload(content) {
  return typeof content === "string" && content.startsWith(PQ_PREFIX);
}

function pq1Encrypt(plaintext, senderSkHex, recipPubHex, recipKemPk) {
  if (!(recipKemPk instanceof Uint8Array) || recipKemPk.length !== PQ_KEM_PK_LEN) {
    throw new Error("bad ml-kem public key");
  }
  var enc = ml_kem768.encapsulate(recipKemPk);
  var ck = pqConversationKey(
    ecdhSharedX(senderSkHex, recipPubHex), enc.sharedSecret, enc.cipherText,
    recipKemPk, getPublicKey(senderSkHex), recipPubHex
  );
  return PQ_PREFIX + b64uEncode(enc.cipherText) + "." + nip44Encrypt(plaintext, ck);
}

/// `self` is { skHex, kemSk, kemPk }. Throws on anything malformed or not for
/// us, exactly like nip44Decrypt.
function pq1Decrypt(content, senderPubHex, self) {
  if (!isPq1Payload(content)) throw new Error("not a pq payload");
  var dot = content.indexOf(".", PQ_PREFIX.length);
  if (dot < 0) throw new Error("malformed pq payload");
  var cipherText = b64uDecode(content.slice(PQ_PREFIX.length, dot));
  if (cipherText.length !== PQ_KEM_CT_LEN) throw new Error("bad ml-kem ciphertext");
  var sharedSecret = ml_kem768.decapsulate(cipherText, self.kemSk);
  var ck = pqConversationKey(
    ecdhSharedX(self.skHex, senderPubHex), sharedSecret, cipherText, self.kemPk,
    senderPubHex, getPublicKey(self.skHex)
  );
  return nip44Decrypt(content.slice(dot + 1), ck);
}

// ---------------------------------------------------------------------------
// ChaCha20-Poly1305 (RFC 8439) — the pq2 outer AEAD. The vendored crypto in
// _shared.js carries the raw ChaCha20 stream for NIP-44 but not the Poly1305
// authenticator, so both live here, validated against the RFC vectors by
// scripts/test-bot-pq.mjs.
// ---------------------------------------------------------------------------

function chachaRotl(x, n) { return ((x << n) | (x >>> (32 - n))) >>> 0; }
function chachaQR(x, a, b, c, d) {
  x[a] = (x[a] + x[b]) >>> 0; x[d] = chachaRotl(x[d] ^ x[a], 16);
  x[c] = (x[c] + x[d]) >>> 0; x[b] = chachaRotl(x[b] ^ x[c], 12);
  x[a] = (x[a] + x[b]) >>> 0; x[d] = chachaRotl(x[d] ^ x[a], 8);
  x[c] = (x[c] + x[d]) >>> 0; x[b] = chachaRotl(x[b] ^ x[c], 7);
}
function readLE32(b, i) {
  return (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;
}

function chachaBlock(key, nonce, counter) {
  var state = new Uint32Array(16);
  state[0] = 0x61707865; state[1] = 0x3320646e;
  state[2] = 0x79622d32; state[3] = 0x6b206574;
  for (var i = 0; i < 8; i++) state[4 + i] = readLE32(key, i * 4);
  state[12] = counter >>> 0;
  state[13] = readLE32(nonce, 0);
  state[14] = readLE32(nonce, 4);
  state[15] = readLE32(nonce, 8);
  var x = state.slice();
  for (var r = 0; r < 10; r++) {
    chachaQR(x, 0, 4, 8, 12); chachaQR(x, 1, 5, 9, 13);
    chachaQR(x, 2, 6, 10, 14); chachaQR(x, 3, 7, 11, 15);
    chachaQR(x, 0, 5, 10, 15); chachaQR(x, 1, 6, 11, 12);
    chachaQR(x, 2, 7, 8, 13); chachaQR(x, 3, 4, 9, 14);
  }
  var out = new Uint8Array(64);
  for (var j = 0; j < 16; j++) {
    var v = (x[j] + state[j]) >>> 0;
    out[j * 4] = v & 0xff; out[j * 4 + 1] = (v >>> 8) & 0xff;
    out[j * 4 + 2] = (v >>> 16) & 0xff; out[j * 4 + 3] = (v >>> 24) & 0xff;
  }
  return out;
}

function chacha20Xor(key, nonce, data, initialCounter) {
  var out = new Uint8Array(data.length);
  var counter = initialCounter >>> 0;
  for (var off = 0; off < data.length; off += 64) {
    var block = chachaBlock(key, nonce, counter++);
    var end = Math.min(64, data.length - off);
    for (var k = 0; k < end; k++) out[off + k] = data[off + k] ^ block[k];
  }
  return out;
}

// Poly1305 over 16-bit limbs (the donna construction, as vendored ecosystems
// ship it). One-shot: poly1305(keyBlock32, message) -> 16-byte tag.
function poly1305(key, msg) {
  var t = new Uint16Array(8);
  for (var i = 0; i < 8; i++) t[i] = key[i * 2] | (key[i * 2 + 1] << 8);
  var r = new Uint16Array(10);
  r[0] = t[0] & 0x1fff;
  r[1] = ((t[0] >>> 13) | (t[1] << 3)) & 0x1fff;
  r[2] = ((t[1] >>> 10) | (t[2] << 6)) & 0x1f03;
  r[3] = ((t[2] >>> 7) | (t[3] << 9)) & 0x1fff;
  r[4] = ((t[3] >>> 4) | (t[4] << 12)) & 0x00ff;
  r[5] = (t[4] >>> 1) & 0x1ffe;
  r[6] = ((t[4] >>> 14) | (t[5] << 2)) & 0x1fff;
  r[7] = ((t[5] >>> 11) | (t[6] << 5)) & 0x1f81;
  r[8] = ((t[6] >>> 8) | (t[7] << 8)) & 0x1fff;
  r[9] = (t[7] >>> 5) & 0x007f;

  var h = new Uint16Array(10);
  var pad = new Uint16Array(8);
  for (var p = 0; p < 8; p++) pad[p] = key[16 + p * 2] | (key[16 + p * 2 + 1] << 8);

  var buffer = new Uint8Array(16);
  var leftover = 0;
  var fin = 0;

  function blocks(m, mpos, bytes) {
    var hibit = fin ? 0 : (1 << 11);
    var h0 = h[0], h1 = h[1], h2 = h[2], h3 = h[3], h4 = h[4];
    var h5 = h[5], h6 = h[6], h7 = h[7], h8 = h[8], h9 = h[9];
    var r0 = r[0], r1 = r[1], r2 = r[2], r3 = r[3], r4 = r[4];
    var r5 = r[5], r6 = r[6], r7 = r[7], r8 = r[8], r9 = r[9];
    while (bytes >= 16) {
      var t0 = m[mpos + 0] | (m[mpos + 1] << 8);
      var t1 = m[mpos + 2] | (m[mpos + 3] << 8);
      var t2 = m[mpos + 4] | (m[mpos + 5] << 8);
      var t3 = m[mpos + 6] | (m[mpos + 7] << 8);
      var t4 = m[mpos + 8] | (m[mpos + 9] << 8);
      var t5 = m[mpos + 10] | (m[mpos + 11] << 8);
      var t6 = m[mpos + 12] | (m[mpos + 13] << 8);
      var t7 = m[mpos + 14] | (m[mpos + 15] << 8);

      h0 += t0 & 0x1fff;
      h1 += ((t0 >>> 13) | (t1 << 3)) & 0x1fff;
      h2 += ((t1 >>> 10) | (t2 << 6)) & 0x1fff;
      h3 += ((t2 >>> 7) | (t3 << 9)) & 0x1fff;
      h4 += ((t3 >>> 4) | (t4 << 12)) & 0x1fff;
      h5 += (t4 >>> 1) & 0x1fff;
      h6 += ((t4 >>> 14) | (t5 << 2)) & 0x1fff;
      h7 += ((t5 >>> 11) | (t6 << 5)) & 0x1fff;
      h8 += ((t6 >>> 8) | (t7 << 8)) & 0x1fff;
      h9 += (t7 >>> 5) | hibit;

      var c = 0;
      var d0 = c;
      d0 += h0 * r0; d0 += h1 * (5 * r9); d0 += h2 * (5 * r8); d0 += h3 * (5 * r7); d0 += h4 * (5 * r6);
      c = d0 >>> 13; d0 &= 0x1fff;
      d0 += h5 * (5 * r5); d0 += h6 * (5 * r4); d0 += h7 * (5 * r3); d0 += h8 * (5 * r2); d0 += h9 * (5 * r1);
      c += d0 >>> 13; d0 &= 0x1fff;

      var d1 = c;
      d1 += h0 * r1; d1 += h1 * r0; d1 += h2 * (5 * r9); d1 += h3 * (5 * r8); d1 += h4 * (5 * r7);
      c = d1 >>> 13; d1 &= 0x1fff;
      d1 += h5 * (5 * r6); d1 += h6 * (5 * r5); d1 += h7 * (5 * r4); d1 += h8 * (5 * r3); d1 += h9 * (5 * r2);
      c += d1 >>> 13; d1 &= 0x1fff;

      var d2 = c;
      d2 += h0 * r2; d2 += h1 * r1; d2 += h2 * r0; d2 += h3 * (5 * r9); d2 += h4 * (5 * r8);
      c = d2 >>> 13; d2 &= 0x1fff;
      d2 += h5 * (5 * r7); d2 += h6 * (5 * r6); d2 += h7 * (5 * r5); d2 += h8 * (5 * r4); d2 += h9 * (5 * r3);
      c += d2 >>> 13; d2 &= 0x1fff;

      var d3 = c;
      d3 += h0 * r3; d3 += h1 * r2; d3 += h2 * r1; d3 += h3 * r0; d3 += h4 * (5 * r9);
      c = d3 >>> 13; d3 &= 0x1fff;
      d3 += h5 * (5 * r8); d3 += h6 * (5 * r7); d3 += h7 * (5 * r6); d3 += h8 * (5 * r5); d3 += h9 * (5 * r4);
      c += d3 >>> 13; d3 &= 0x1fff;

      var d4 = c;
      d4 += h0 * r4; d4 += h1 * r3; d4 += h2 * r2; d4 += h3 * r1; d4 += h4 * r0;
      c = d4 >>> 13; d4 &= 0x1fff;
      d4 += h5 * (5 * r9); d4 += h6 * (5 * r8); d4 += h7 * (5 * r7); d4 += h8 * (5 * r6); d4 += h9 * (5 * r5);
      c += d4 >>> 13; d4 &= 0x1fff;

      var d5 = c;
      d5 += h0 * r5; d5 += h1 * r4; d5 += h2 * r3; d5 += h3 * r2; d5 += h4 * r1;
      c = d5 >>> 13; d5 &= 0x1fff;
      d5 += h5 * r0; d5 += h6 * (5 * r9); d5 += h7 * (5 * r8); d5 += h8 * (5 * r7); d5 += h9 * (5 * r6);
      c += d5 >>> 13; d5 &= 0x1fff;

      var d6 = c;
      d6 += h0 * r6; d6 += h1 * r5; d6 += h2 * r4; d6 += h3 * r3; d6 += h4 * r2;
      c = d6 >>> 13; d6 &= 0x1fff;
      d6 += h5 * r1; d6 += h6 * r0; d6 += h7 * (5 * r9); d6 += h8 * (5 * r8); d6 += h9 * (5 * r7);
      c += d6 >>> 13; d6 &= 0x1fff;

      var d7 = c;
      d7 += h0 * r7; d7 += h1 * r6; d7 += h2 * r5; d7 += h3 * r4; d7 += h4 * r3;
      c = d7 >>> 13; d7 &= 0x1fff;
      d7 += h5 * r2; d7 += h6 * r1; d7 += h7 * r0; d7 += h8 * (5 * r9); d7 += h9 * (5 * r8);
      c += d7 >>> 13; d7 &= 0x1fff;

      var d8 = c;
      d8 += h0 * r8; d8 += h1 * r7; d8 += h2 * r6; d8 += h3 * r5; d8 += h4 * r4;
      c = d8 >>> 13; d8 &= 0x1fff;
      d8 += h5 * r3; d8 += h6 * r2; d8 += h7 * r1; d8 += h8 * r0; d8 += h9 * (5 * r9);
      c += d8 >>> 13; d8 &= 0x1fff;

      var d9 = c;
      d9 += h0 * r9; d9 += h1 * r8; d9 += h2 * r7; d9 += h3 * r6; d9 += h4 * r5;
      c = d9 >>> 13; d9 &= 0x1fff;
      d9 += h5 * r4; d9 += h6 * r3; d9 += h7 * r2; d9 += h8 * r1; d9 += h9 * r0;
      c += d9 >>> 13; d9 &= 0x1fff;

      c = ((c << 2) + c) | 0;
      c = (c + d0) | 0;
      d0 = c & 0x1fff;
      c = c >>> 13;
      d1 += c;

      h0 = d0; h1 = d1; h2 = d2; h3 = d3; h4 = d4;
      h5 = d5; h6 = d6; h7 = d7; h8 = d8; h9 = d9;

      mpos += 16;
      bytes -= 16;
    }
    h[0] = h0; h[1] = h1; h[2] = h2; h[3] = h3; h[4] = h4;
    h[5] = h5; h[6] = h6; h[7] = h7; h[8] = h8; h[9] = h9;
  }

  function update(m) {
    var mpos = 0;
    var bytes = m.length;
    if (leftover) {
      var want = 16 - leftover;
      if (want > bytes) want = bytes;
      for (var i2 = 0; i2 < want; i2++) buffer[leftover + i2] = m[mpos + i2];
      bytes -= want;
      mpos += want;
      leftover += want;
      if (leftover < 16) return;
      blocks(buffer, 0, 16);
      leftover = 0;
    }
    if (bytes >= 16) {
      var want2 = bytes - (bytes % 16);
      blocks(m, mpos, want2);
      mpos += want2;
      bytes -= want2;
    }
    if (bytes) {
      for (var i3 = 0; i3 < bytes; i3++) buffer[leftover + i3] = m[mpos + i3];
      leftover += bytes;
    }
  }

  update(msg);

  if (leftover) {
    buffer[leftover++] = 1;
    for (var z = leftover; z < 16; z++) buffer[z] = 0;
    fin = 1;
    blocks(buffer, 0, 16);
  }

  var carry = h[1] >>> 13;
  h[1] &= 0x1fff;
  for (var i4 = 2; i4 < 10; i4++) {
    h[i4] += carry;
    carry = h[i4] >>> 13;
    h[i4] &= 0x1fff;
  }
  h[0] += carry * 5;
  carry = h[0] >>> 13;
  h[0] &= 0x1fff;
  h[1] += carry;
  carry = h[1] >>> 13;
  h[1] &= 0x1fff;
  h[2] += carry;

  var g = new Uint16Array(10);
  carry = 5;
  for (var i5 = 0; i5 < 10; i5++) {
    g[i5] = h[i5] + carry;
    carry = g[i5] >>> 13;
    g[i5] &= 0x1fff;
  }
  g[9] -= 1 << 13;
  g[9] &= 0xffff;

  var mask = (carry ^ 1) - 1;
  mask &= 0xffff;
  for (var i6 = 0; i6 < 10; i6++) g[i6] &= mask;
  var imask = ~mask & 0xffff;
  for (var i7 = 0; i7 < 10; i7++) h[i7] = (h[i7] & imask) | g[i7];

  h[0] = (h[0] | (h[1] << 13)) & 0xffff;
  h[1] = ((h[1] >>> 3) | (h[2] << 10)) & 0xffff;
  h[2] = ((h[2] >>> 6) | (h[3] << 7)) & 0xffff;
  h[3] = ((h[3] >>> 9) | (h[4] << 4)) & 0xffff;
  h[4] = ((h[4] >>> 12) | (h[5] << 1) | (h[6] << 14)) & 0xffff;
  h[5] = ((h[6] >>> 2) | (h[7] << 11)) & 0xffff;
  h[6] = ((h[7] >>> 5) | (h[8] << 8)) & 0xffff;
  h[7] = ((h[8] >>> 8) | (h[9] << 5)) & 0xffff;

  var f = (h[0] + pad[0]) | 0;
  h[0] = f & 0xffff;
  for (var i8 = 1; i8 < 8; i8++) {
    f = (((h[i8] + pad[i8]) | 0) + (f >>> 16)) | 0;
    h[i8] = f & 0xffff;
  }

  var tag = new Uint8Array(16);
  for (var i9 = 0; i9 < 8; i9++) {
    tag[i9 * 2] = h[i9] & 0xff;
    tag[i9 * 2 + 1] = h[i9] >>> 8;
  }
  return tag;
}

function pad16Len(n) { return (16 - (n % 16)) % 16; }

function le64(n) {
  var out = new Uint8Array(8);
  var lo = n >>> 0;
  var hi = Math.floor(n / 0x100000000);
  out[0] = lo & 0xff; out[1] = (lo >>> 8) & 0xff; out[2] = (lo >>> 16) & 0xff; out[3] = (lo >>> 24) & 0xff;
  out[4] = hi & 0xff; out[5] = (hi >>> 8) & 0xff; out[6] = (hi >>> 16) & 0xff; out[7] = (hi >>> 24) & 0xff;
  return out;
}

function poly1305AeadTag(polyKey, aad, ct) {
  var macData = concatBytes(
    aad, new Uint8Array(pad16Len(aad.length)),
    ct, new Uint8Array(pad16Len(ct.length)),
    le64(aad.length), le64(ct.length)
  );
  return poly1305(polyKey, macData);
}

function constEq(a, b) {
  if (a.length !== b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/// RFC 8439 ChaCha20-Poly1305 seal: returns ciphertext || 16-byte tag.
function chacha20poly1305Encrypt(key, nonce, plaintext, aad) {
  var polyKey = chachaBlock(key, nonce, 0).subarray(0, 32);
  var ct = chacha20Xor(key, nonce, plaintext, 1);
  var tag = poly1305AeadTag(polyKey, aad, ct);
  return concatBytes(ct, tag);
}

/// RFC 8439 open; throws on a bad tag.
function chacha20poly1305Decrypt(key, nonce, sealed, aad) {
  if (sealed.length < 16) throw new Error("aead: too short");
  var ct = sealed.subarray(0, sealed.length - 16);
  var tag = sealed.subarray(sealed.length - 16);
  var polyKey = chachaBlock(key, nonce, 0).subarray(0, 32);
  var expect = poly1305AeadTag(polyKey, aad, ct);
  if (!constEq(tag, expect)) throw new Error("aead: bad tag");
  return chacha20Xor(key, nonce, ct, 1);
}

// ---------------------------------------------------------------------------
// pq2 — the layered construction (spec addendum A2)
// ---------------------------------------------------------------------------

function isPq2Payload(content) {
  return typeof content === "string" && content.startsWith(PQ2_PREFIX);
}

function pq2LayerKeys(ss, kemCt, recipKemPk, senderPkHex, recipPkHex) {
  var info = concatBytes(
    utf8ToBytes(PQ2_LABEL), hexToBytes(senderPkHex), hexToBytes(recipPkHex),
    kemCt, recipKemPk
  );
  var prk = hkdfExtract(utf8ToBytes(PQ2_SALT), ss);
  return {
    key: hkdfExpand(prk, concatBytes(info, utf8ToBytes("key")), 32),
    nonce: hkdfExpand(prk, concatBytes(info, utf8ToBytes("nonce")), 12),
    aad: info
  };
}

function pq2Seal(inner, senderPkHex, recipPubHex, recipKemPk) {
  if (!(recipKemPk instanceof Uint8Array) || recipKemPk.length !== PQ_KEM_PK_LEN) {
    throw new Error("bad ml-kem public key");
  }
  if (typeof inner !== "string" || !inner) throw new Error("bad inner payload");
  var enc = ml_kem768.encapsulate(recipKemPk);
  var k = pq2LayerKeys(enc.sharedSecret, enc.cipherText, recipKemPk, senderPkHex, recipPubHex);
  var outer = chacha20poly1305Encrypt(k.key, k.nonce, utf8ToBytes(inner), k.aad);
  return PQ2_PREFIX + b64uEncode(enc.cipherText) + "." + b64uEncode(outer);
}

function pq2Open(content, senderPkHex, recipPkHex, self) {
  if (!isPq2Payload(content)) throw new Error("not a pq2 payload");
  var dot = content.indexOf(".", PQ2_PREFIX.length);
  if (dot < 0) throw new Error("malformed pq2 payload");
  var cipherText = b64uDecode(content.slice(PQ2_PREFIX.length, dot));
  if (cipherText.length !== PQ_KEM_CT_LEN) throw new Error("bad ml-kem ciphertext");
  var sharedSecret = ml_kem768.decapsulate(cipherText, self.kemSk);
  var k = pq2LayerKeys(sharedSecret, cipherText, self.kemPk, senderPkHex, recipPkHex);
  var outer = b64uDecode(content.slice(dot + 1));
  var pt = chacha20poly1305Decrypt(k.key, k.nonce, outer, k.aad);
  return new TextDecoder().decode(pt);
}

function pq2Encrypt(plaintext, senderSkHex, recipPubHex, recipKemPk) {
  var inner = nip44Encrypt(plaintext, nip44ConversationKey(senderSkHex, recipPubHex));
  return pq2Seal(inner, getPublicKey(senderSkHex), recipPubHex, recipKemPk);
}

/// `self` is { skHex, kemSk, kemPk }.
function pq2Decrypt(content, senderPubHex, self) {
  var recipPkHex = getPublicKey(self.skHex);
  var inner = pq2Open(content, senderPubHex, recipPkHex, self);
  return nip44Decrypt(inner, nip44ConversationKey(self.skHex, senderPubHex));
}

/// One decrypt for any Nymchat DM payload the bot can meet: pq2, pq1, or
/// plain NIP-44. `self` is { skHex, kemSk|null, kemPk|null }.
function pqAwareDecrypt(content, senderPubHex, self) {
  if (isPq2Payload(content)) {
    if (!self.kemSk) throw new Error("pq2 payload without a KEM key");
    return pq2Decrypt(content, senderPubHex, self);
  }
  if (isPq1Payload(content)) {
    if (!self.kemSk) throw new Error("pq1 payload without a KEM key");
    return pq1Decrypt(content, senderPubHex, self);
  }
  return nip44Decrypt(content, nip44ConversationKey(self.skHex, senderPubHex));
}

// ---------------------------------------------------------------------------
// Capability announcements (kind 30078, d-tag `nym-pq`)
// ---------------------------------------------------------------------------

/// Parses a peer's announcement event into { pk1, pk2, rootSeeded, epoch,
/// exp } with Uint8Array keys, or null when it is not a live, valid
/// announcement. Mirrors the client's handlePqAnnouncement rules: a malformed
/// key or an expired/retracted payload leaves the peer classical.
function parsePqAnnouncement(event, nowSec) {
  try {
    if (!event || !event.content) return null;
    var payload = JSON.parse(event.content);
    if (!payload || payload.alg !== PQ_ALG) return null;
    if (payload.retracted) return null;
    var exp = parseInt(payload.exp, 10) || 0;
    if (exp <= (nowSec || Math.floor(Date.now() / 1000))) return null;
    var readKey = function (raw) {
      if (raw == null) return undefined;
      var k;
      try { k = b64uDecode(raw); } catch (_) { return null; }
      return (k instanceof Uint8Array && k.length === PQ_KEM_PK_LEN) ? k : null;
    };
    var pk1 = readKey(payload.pk);
    var pk2 = readKey(payload.pk2);
    if (pk1 === null || pk2 === null) return null;
    return {
      pk1: pk1 || null,
      pk2: pk2 || null,
      rootSeeded: payload.v === 2 && payload.src === "root",
      epoch: parseInt(payload.epoch, 10) || 0,
      exp: exp
    };
  } catch (_) {
    return null;
  }
}

/// Builds the bot's signed announcement. The worker holds both the bot's nsec
/// (BOT_PRIVKEY) and its root (PQ_CODE), so it may advertise `pk` (either
/// format) alongside `pk2` (spec A3) — older clients seal pq1 to `pk`, current
/// ones seal pq2 to `pk2`, and both open here.
// The bot's post-quantum identity from the PQ_CODE binding (its own nympq1
// root, epoch 0). Memoized per isolate; a missing or malformed binding yields
// null so every caller stays classical rather than broken.
var _botPqCache = { code: null, self: null };
function botPqSelfFromEnv(env) {
  var code = env && env.PQ_CODE ? String(env.PQ_CODE).trim() : "";
  if (!code) return null;
  if (_botPqCache.code === code) return _botPqCache.self;
  var self = null;
  try {
    var kp = pqKeypairFromRoot(pqRootDecode(code), 0);
    self = { kemSk: kp.secretKey, kemPk: kp.publicKey };
  } catch (e) {
    self = null;
  }
  _botPqCache = { code: code, self: self };
  return self;
}

// Newest signed, id-valid announcement authored by `author` from a pile of
// fetched events — relays are never trusted for key material.
function verifiedAnnouncementFrom(events, author) {
  var newest = null;
  for (var i = 0; i < (events || []).length; i++) {
    var evt = events[i];
    if (!evt || evt.pubkey !== author || evt.kind !== 30078 || !evt.sig) continue;
    if (newest && evt.created_at <= newest.created_at) continue;
    try {
      if (getEventHash(evt) !== evt.id) continue;
      if (!schnorr.verify(evt.sig, evt.id, evt.pubkey)) continue;
    } catch (e) { continue; }
    newest = evt;
  }
  return newest;
}

// A user's announced KEM key as { pk, fmt: 'pq2'|'pq1' } (layered preferred),
// or null, from fetched events.
function userPqRecordFromEvents(events, userPubkey) {
  var newest = verifiedAnnouncementFrom(events, userPubkey);
  var parsed = newest ? parsePqAnnouncement(newest, Math.floor(Date.now() / 1000)) : null;
  if (!parsed) return null;
  if (parsed.pk2) return { pk: parsed.pk2, fmt: "pq2" };
  if (parsed.pk1) return { pk: parsed.pk1, fmt: "pq1" };
  return null;
}

// Self-contained relay fetch of a user's `nym-pq` announcement key, for callers
// (storage.js) that carry no relay client of their own. `relays` is a list of
// wss URLs. Returns { pk, fmt } or null; never throws.
function fetchPqAnnouncementKey(userPubkey, relays, timeoutMs) {
  var filter = { kinds: [30078], authors: [userPubkey], "#d": [PQ_D_TAG], limit: 3 };
  function fromRelay(url) {
    return new Promise(function (resolve) {
      var out = [];
      var done = false;
      function finish() {
        if (done) return;
        done = true;
        try { ws.close(); } catch (e) {}
        resolve(out);
      }
      var ws;
      try { ws = new WebSocket(url); } catch (e) { resolve(out); return; }
      var timer = setTimeout(finish, timeoutMs || 2500);
      ws.addEventListener("open", function () {
        try { ws.send(JSON.stringify(["REQ", "pq-" + Math.random().toString(36).slice(2, 8), filter])); }
        catch (e) { finish(); }
      });
      ws.addEventListener("message", function (msg) {
        try {
          var data = JSON.parse(msg.data);
          if (Array.isArray(data)) {
            if (data[0] === "EVENT" && data[2]) out.push(data[2]);
            else if (data[0] === "EOSE") { clearTimeout(timer); finish(); }
          }
        } catch (e) {}
      });
      ws.addEventListener("error", function () { clearTimeout(timer); finish(); });
      ws.addEventListener("close", function () { clearTimeout(timer); finish(); });
    });
  }
  return Promise.all((relays || []).map(fromRelay)).then(function (lists) {
    var all = [];
    for (var i = 0; i < lists.length; i++) all = all.concat(lists[i]);
    try { return userPqRecordFromEvents(all, userPubkey); } catch (e) { return null; }
  }).catch(function () { return null; });
}

// D1-first announcement lookup. Clients publish their `nym-pq` announcement
// through the relay proxy, which archives it into the channel events table
// (relay-pool.js keeps kind-30078 `d=nym-pq` rows), and they resolve peers'
// keys from that archive first — the worker's own relay list may never carry
// the event at all. `db` is the (replica'd) DB_CHANNELS binding, or null to
// skip straight to the caller's relay fallback. Rows are only a transport:
// userPqRecordFromEvents still verifies id + signature before any key is
// trusted.
async function pqAnnouncementEventsFromD1(db, pubkey) {
  if (!db) return null;
  try {
    var floorSec = Math.floor(Date.now() / 1000) - PQ_TTL_SEC;
    var rows = (await db.prepare(
      "SELECT json FROM events WHERE channel = ? AND pubkey = ? AND created_at >= ? ORDER BY created_at DESC LIMIT 3"
    ).bind(PQ_D_TAG, pubkey, floorSec).all()).results || [];
    var events = [];
    for (var i = 0; i < rows.length; i++) {
      try { var e = JSON.parse(rows[i].json); if (e) events.push(e); } catch (_) { }
    }
    return events.length ? events : null;
  } catch (e) {
    return null;
  }
}

function buildBotPqAnnouncement(botPrivkeyHex, botPubkey, kemPk, appVersion) {
  var nowSec = Math.floor(Date.now() / 1000);
  var exp = nowSec + PQ_TTL_SEC;
  var pkB64 = b64uEncode(kemPk);
  var payload = {
    v: 2,
    src: "root",
    alg: PQ_ALG,
    nym: 1,
    epoch: 0,
    pk: pkB64,
    pk2: pkB64,
    exp: exp,
    devices: [
      { id: "nymbot-worker", ver: appVersion || "", ts: nowSec, pq: 1, pq2: 1 }
    ]
  };
  var event = {
    kind: 30078,
    created_at: nowSec,
    tags: [
      ["d", PQ_D_TAG],
      ["t", PQ_D_TAG],
      // NIP-40 so relays can drop a stale announcement on their own.
      ["expiration", String(exp)]
    ],
    content: JSON.stringify(payload),
    pubkey: botPubkey
  };
  signEvent(event, botPrivkeyHex);
  return event;
}

// ---------------------------------------------------------------------------
// Bot reply gift wraps — the pq-aware siblings of _shared.js's
// buildGiftWrappedDM/Pair. `recipKem` is { pk: Uint8Array, fmt: 'pq2'|'pq1' }
// or null for classical; each layer of each leg is sealed independently, so a
// post-quantum user copy and a post-quantum bot self-copy never share key
// material.
// ---------------------------------------------------------------------------

function sealContentFor(json, senderSkHex, recipientPubkey, recipKem) {
  if (recipKem && recipKem.fmt === "pq2") {
    return pq2Encrypt(json, senderSkHex, recipientPubkey, recipKem.pk);
  }
  if (recipKem && recipKem.fmt === "pq1") {
    return pq1Encrypt(json, senderSkHex, recipientPubkey, recipKem.pk);
  }
  return nip44Encrypt(json, nip44ConversationKey(senderSkHex, recipientPubkey));
}

function wrapDMTo(rumor, botPrivkeyHex, botPubkey, targetPubkey, targetKem) {
  var seal = {
    kind: 13,
    created_at: randomTimestampNow(),
    tags: [],
    content: sealContentFor(JSON.stringify(rumor), botPrivkeyHex, targetPubkey, targetKem),
    pubkey: botPubkey
  };
  signEvent(seal, botPrivkeyHex);
  var ephSk = bytesToHex(randomBytes(32));
  var ephPk = getPublicKey(ephSk);
  var wrap = {
    kind: 1059,
    created_at: randomTimestampNow(),
    tags: [["p", targetPubkey]],
    content: sealContentFor(JSON.stringify(seal), ephSk, targetPubkey, targetKem),
    pubkey: ephPk
  };
  signEvent(wrap, ephSk);
  return wrap;
}

// The first value of a named rumor tag, or null. Rumor tags are inside the
// encrypted payload, so they only exist on messages this worker has unwrapped.
function rumorTagValue(rumor, name) {
  var tags = rumor && Array.isArray(rumor.tags) ? rumor.tags : [];
  for (var i = 0; i < tags.length; i++) {
    var t = tags[i];
    if (Array.isArray(t) && t[0] === name && typeof t[1] === "string" && t[1]) {
      return t[1];
    }
  }
  return null;
}

// Whether an unwrapped rumor belongs to one conversation scope. With a thread
// root the scope is that nested discussion only: the root message itself (its
// shared `x` id) plus the replies marked with the same `nymthread`. Without
// one it is the top-level conversation, which excludes thread replies the
// same way the clients' flat views hide them — so a thread stays an isolated
// context in both directions.
function rumorInThreadScope(rumor, threadRoot) {
  var marked = rumorTagValue(rumor, "nymthread");
  if (threadRoot) {
    return marked === threadRoot || rumorTagValue(rumor, "x") === threadRoot;
  }
  return !marked;
}

// `opts.threadRoot`: the shared id of the thread this reply belongs to (the
// user's message carried it in its `nymthread` tag), echoed back so clients
// file the reply inside the same thread.
function botDMRumor(plaintext, botPubkey, recipientPubkey, opts) {
  var threadRoot = opts && opts.threadRoot ? String(opts.threadRoot) : null;
  var rumor = {
    kind: 14,
    created_at: Math.floor(Date.now() / 1000),
    // The `x` tag is the client-side shared message id (same 32-byte-hex shape
    // as the clients' _generateSharedEventId): without it a bot reply has no
    // cross-recipient id, so clients could never anchor a thread on one. Bot
    // replies only travel the Nymchat NIP-17 leg, so the bitchat tag
    // restriction never applies here.
    tags: [
      ["p", recipientPubkey],
      ["x", bytesToHex(randomBytes(32))],
      ["ms", String(Date.now())],
      ["bot", "nymchat"]
    ],
    content: plaintext,
    pubkey: botPubkey
  };
  if (threadRoot) rumor.tags.push(["nymthread", threadRoot]);
  rumor.id = getEventHash(rumor);
  return rumor;
}

/// A single DM wrap to `recipientPubkey`, post-quantum when they announced a
/// usable key.
function buildPqGiftWrappedDM(plaintext, botPrivkeyHex, botPubkey, recipientPubkey, recipKem, opts) {
  var rumor = botDMRumor(plaintext, botPubkey, recipientPubkey, opts);
  return wrapDMTo(rumor, botPrivkeyHex, botPubkey, recipientPubkey, recipKem);
}

/// A reply wrap to the user plus the bot's self-addressed copy (the copy the
/// worker itself re-reads for thread history). `selfKem` is the bot's own
/// { pk, fmt } so its archive is never the weakest link. Both legs share ONE
/// rumor, so the user copy and the self copy agree on the `x` id and thread
/// marker.
function buildPqGiftWrappedDMPair(plaintext, botPrivkeyHex, botPubkey, recipientPubkey, recipKem, selfKem, opts) {
  var rumor = botDMRumor(plaintext, botPubkey, recipientPubkey, opts);
  return {
    event: wrapDMTo(rumor, botPrivkeyHex, botPubkey, recipientPubkey, recipKem),
    selfEvent: wrapDMTo(rumor, botPrivkeyHex, botPubkey, botPubkey, selfKem)
  };
}

export {
  PQ_D_TAG,
  PQ_KEM_PK_LEN,
  b64uEncode,
  b64uDecode,
  pqRootDecode,
  pqRootDeriveSeed,
  pqKeypairFromRoot,
  isPq1Payload,
  isPq2Payload,
  pq1Encrypt,
  pq1Decrypt,
  pq2Encrypt,
  pq2Decrypt,
  pq2Seal,
  pq2Open,
  pqAwareDecrypt,
  chacha20poly1305Encrypt,
  chacha20poly1305Decrypt,
  parsePqAnnouncement,
  botPqSelfFromEnv,
  verifiedAnnouncementFrom,
  userPqRecordFromEvents,
  fetchPqAnnouncementKey,
  pqAnnouncementEventsFromD1,
  buildBotPqAnnouncement,
  rumorTagValue,
  rumorInThreadScope,
  buildPqGiftWrappedDM,
  buildPqGiftWrappedDMPair
};
