// Tests the hybrid post-quantum crypto in js/nym-crypto.js.
//
//   npm run test:pq
//
// Two halves:
//   1. Behavioural — round-trips, negative cases, and regression checks that
//      the classical NIP-44 and bitchat transports are untouched.
//   2. Vectors — test/pq-vectors.json, the same file the Flutter port's tests
//      read. If these pass in both repos the two implementations interoperate.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { loadNym, root, hex, unhex } from './pq-harness.mjs';

const { NostrTools: T, NymCrypto: NC } = loadNym();
const kem = globalThis.NymMlKem.ml_kem768;

let pass = 0, fail = 0;
const eq = (a, b) => Buffer.from(a).equals(Buffer.from(b));
function chk(name, cond) {
    if (cond) { pass++; }
    else { fail++; console.log(`  FAIL  ${name}`); }
}
function section(s) { console.log(`\n${s}`); }

// ---------------------------------------------------------------- behavioural
section('behavioural');
chk('ML-KEM is available', NC.pqAvailable());

const aliceSk = T.generateSecretKey(), alicePk = T.getPublicKey(aliceSk);
const bobSk = T.generateSecretKey(), bobPk = T.getPublicKey(bobSk);
const bobKem = NC.pqKeypairFromPrivkey(bobSk, 0);
const self = { sk: bobSk, kemSk: bobKem.secretKey, kemPk: bobKem.publicKey };

chk('nsec-derived key is identical across devices sharing an nsec',
    eq(NC.pqKeypairFromPrivkey(bobSk, 0).publicKey, bobKem.publicKey));
chk('epoch bump rotates the key',
    !eq(NC.pqKeypairFromPrivkey(bobSk, 1).publicKey, bobKem.publicKey));
chk('ML-KEM sizes are FIPS 203 ML-KEM-768',
    bobKem.publicKey.length === 1184 && bobKem.secretKey.length === 2400);

const msg = 'hello quantum world \u{1F510}';
const ct = NC.pqEncrypt(msg, aliceSk, bobPk, bobKem.publicKey);
chk('payload carries the pq1. prefix', NC.isPqPayload(ct));
chk('round-trips', NC.pqDecrypt(ct, alicePk, self) === msg);
chk('every message gets a fresh KEM encapsulation',
    NC.pqEncrypt(msg, aliceSk, bobPk, bobKem.publicKey).split('.')[1] !== ct.split('.')[1]);

const throws = (fn) => { try { fn(); return false; } catch (_) { return true; } };
const malSk = T.generateSecretKey(), malKem = NC.pqKeypairFromPrivkey(malSk, 0);
chk('wrong recipient cannot decrypt',
    throws(() => NC.pqDecrypt(ct, alicePk, { sk: malSk, kemSk: malKem.secretKey, kemPk: malKem.publicKey })));
chk('wrong claimed sender is rejected (classical leg is bound)',
    throws(() => NC.pqDecrypt(ct, T.getPublicKey(malSk), self)));
{
    // Corrupting the KEM ciphertext yields a different decapsulated secret, so
    // the derived conversation key differs and the NIP-44 HMAC must reject.
    const parts = ct.split('.');
    const raw = NC._b64uDecode(parts[1]);
    raw[0] ^= 1;
    chk('flipped KEM ciphertext bit is rejected',
        throws(() => NC.pqDecrypt(`pq1.${NC._b64uEncode(raw)}.${parts[2]}`, alicePk, self)));
}
chk('a substituted recipient KEM key changes the transcript and fails',
    throws(() => NC.pqDecrypt(ct, alicePk, { sk: bobSk, kemSk: bobKem.secretKey, kemPk: malKem.publicKey })));
chk('malformed payloads are rejected, not crashed on',
    throws(() => NC.pqDecrypt('pq1.', alicePk, self)) &&
    throws(() => NC.pqDecrypt('pq1.zzz.zzz', alicePk, self)) &&
    throws(() => NC.pqDecrypt('not-pq', alicePk, self)));

section('gift wrap');
const rumor = { kind: 14, created_at: 1700000000, tags: [['p', bobPk], ['x', 'ABC']], content: 'sealed pq message' };
const wrap = NC.pqNip59Wrap(rumor, aliceSk, bobPk, bobKem.publicKey, null);
chk('wrap is a valid signed kind 1059', wrap.kind === 1059 && T.verifyEvent(wrap));
chk('wrap tags stay vanilla NIP-17 (p tag only, no PQ tag leaked)',
    JSON.stringify(wrap.tags) === JSON.stringify([['p', bobPk]]));
chk('wrap is authored by an ephemeral key, not the sender', wrap.pubkey !== alicePk);
chk('expiration tag is honoured',
    JSON.stringify(NC.pqNip59Wrap(rumor, aliceSk, bobPk, bobKem.publicKey, 1800000000).tags)
    === JSON.stringify([['p', bobPk], ['expiration', '1800000000']]));

const got = NC.unwrapGiftWrap(wrap, [{ sk: bobSk, bitchat: false, kemSk: bobKem.secretKey, kemPk: bobKem.publicKey }]);
chk('unwrap succeeds and flags isPq', !!got && got.isPq === true);
chk('rumor survives the round trip', got && got.rumor.content === 'sealed pq message');
chk('seal is authored and signed by the real sender',
    got && got.seal.pubkey === alicePk && T.verifyEvent(got.seal));
chk('both layers are hybridized', got && NC.isPqPayload(got.seal.content));
chk('a classical-only candidate skips a pq wrap cleanly (no throw)',
    NC.unwrapGiftWrap(wrap, [{ sk: bobSk, bitchat: false }]) === null);
chk('candidate ordering is reported',
    NC.unwrapGiftWrap(wrap, [{ sk: malSk, bitchat: false, kemSk: malKem.secretKey, kemPk: malKem.publicKey },
                             { sk: bobSk, bitchat: false, kemSk: bobKem.secretKey, kemPk: bobKem.publicKey }])?.idx === 1);

section('regression: classical transports unchanged');
{
    const cw = NC.nip59Wrap(rumor, aliceSk, bobPk, null);
    const cgot = NC.unwrapGiftWrap(cw, [{ sk: bobSk, bitchat: false }]);
    chk('classical NIP-44 wrap still round-trips', !!cgot && cgot.rumor.content === rumor.content);
    chk('classical wrap reports isPq false', cgot && cgot.isPq === false);
    const bw = NC.bitchatWrap(rumor, aliceSk, bobPk);
    const bgot = NC.unwrapGiftWrap(bw, [{ sk: bobSk, bitchat: true }]);
    chk('bitchat wrap still round-trips', !!bgot && bgot.isBitchat === true);
    chk('bitchat wrap reports isPq false', bgot && bgot.isPq === false);
    // A PQ-capable candidate must not break the classical transports.
    const both = [{ sk: bobSk, bitchat: true, kemSk: bobKem.secretKey, kemPk: bobKem.publicKey }];
    chk('a PQ-capable candidate still decrypts classical wraps',
        NC.unwrapGiftWrap(cw, both)?.rumor.content === rumor.content);
    chk('a PQ-capable candidate still decrypts bitchat wraps',
        NC.unwrapGiftWrap(bw, both)?.isBitchat === true);
}

section('wrap-only hybrid (the transport a signer login can build)');
{
    // What an extension / NIP-46 login produces: the seal is plain NIP-44 —
    // the signer returns a finished payload — inside a hybrid wrap, whose
    // ephemeral key we generated ourselves.
    const eph = T.generateSecretKey();
    const seal = T.finalizeEvent({
        kind: 13,
        content: T.nip44.encrypt(JSON.stringify(rumor), T.nip44.getConversationKey(aliceSk, bobPk)),
        created_at: 1735689600,
        tags: [],
    }, aliceSk);
    const wrap = T.finalizeEvent({
        kind: 1059,
        content: NC.pqEncrypt(JSON.stringify(seal), eph, bobPk, bobKem.publicKey),
        created_at: 1735689600,
        tags: [['p', bobPk]],
    }, eph);

    const got = NC.unwrapGiftWrap(wrap, [self]);
    chk('a hybrid wrap around a classical seal opens', !!got);
    chk('and yields the original rumor', got && got.rumor.content === rumor.content);
    chk('and reports itself as post-quantum, which it is for the threat',
        got && got.isPq === true);

    // The point of the whole exercise: what a relay stores needs ML-KEM to
    // open, so a recorder who breaks secp256k1 later gets nothing. The seal's
    // classical layer is only reachable by someone already through the
    // post-quantum one.
    chk('the stored event is a pq payload', NC.isPqPayload(wrap.content));
    chk('a classical-only holder of the recipient key cannot open it',
        NC.unwrapGiftWrap(wrap, [{ sk: bobSk, bitchat: false }]) === null);
    chk('nor can the wrong ml-kem key',
        NC.unwrapGiftWrap(wrap, [{ sk: bobSk, bitchat: false, kemSk: malKem.secretKey, kemPk: malKem.publicKey }]) === null);
}

section('settings blob (self-encrypted, js/modules/settings.js)');
{
    // The D1 settings blob is encrypted to ourselves, so both halves use our
    // own key. It carries the conversation list, the group keys and the history
    // categories — left classical it would be the weakest thing we store.
    const self = { sk: bobSk, kemSk: bobKem.secretKey, kemPk: bobKem.publicKey };
    const plaintext = JSON.stringify({ theme: 'matrix', groupEphemeralKeys: { g1: { self: { prev: [] } } } });
    const ct = NC.pqEncrypt(plaintext, bobSk, bobPk, bobKem.publicKey);
    chk('a self-encrypted blob is a pq payload', NC.isPqPayload(ct));
    chk('a self-encrypted blob round-trips', NC.pqDecrypt(ct, bobPk, self) === plaintext);
    chk('another identity cannot read it',
        (() => { try { NC.pqDecrypt(ct, bobPk, { sk: malSk, kemSk: malKem.secretKey, kemPk: malKem.publicKey }); return false; } catch (_) { return true; } })());
    // Blobs written before this device had a PQ key stay readable: the prefix
    // is what picks the path, so no migration is needed.
    const legacy = T.nip44.encrypt(plaintext, T.nip44.getConversationKey(bobSk, bobPk));
    chk('a legacy NIP-44 blob is not mistaken for a pq one', !NC.isPqPayload(legacy));
    chk('a legacy NIP-44 blob still decrypts',
        T.nip44.decrypt(legacy, T.nip44.getConversationKey(bobSk, bobPk)) === plaintext);
    // The size headroom the settings publisher has to budget for.
    chk('the hybrid costs under 2 KB a layer', ct.length - legacy.length < 2048);
}

// -------------------------------------------------------------------- vectors
section('vectors (test/pq-vectors.json — shared with the Flutter port)');
const V = JSON.parse(fs.readFileSync(path.join(root, 'test', 'pq-vectors.json'), 'utf8'));

for (const [i, v] of V.seedDerivation.entries()) {
    chk(`seedDerivation[${i}]`, hex(NC.pqDeriveSeed(unhex(v.privkey), v.epoch)) === v.seed);
}
for (const [i, v] of V.keygen.entries()) {
    const kp = kem.keygen(unhex(v.seed));
    chk(`keygen[${i}].publicKey`, hex(kp.publicKey) === v.publicKey);
    chk(`keygen[${i}].secretKey`, hex(kp.secretKey) === v.secretKey);
}
for (const [i, v] of V.decapsulate.entries()) {
    const kp = kem.keygen(unhex(v.keySeed));
    chk(`decapsulate[${i}] (${v.note})`,
        hex(kem.decapsulate(unhex(v.cipherText), kp.secretKey)) === v.sharedSecret);
}
for (const [i, v] of V.conversationKey.entries()) {
    chk(`conversationKey[${i}]`, hex(NC.pqConversationKey(
        unhex(v.ecdhSharedX), unhex(v.kemSharedSecret), unhex(v.kemCipherText),
        unhex(v.recipKemPublicKey), v.senderSecpPubkey, v.recipSecpPubkey)) === v.conversationKey);
}
for (const [i, v] of V.endToEnd.entries()) {
    const kp = kem.keygen(unhex(v.recipKemSeed));
    chk(`endToEnd[${i}] decrypts`, NC.pqDecrypt(v.payload, v.senderPubkey,
        { sk: unhex(v.recipPrivkey), kemSk: kp.secretKey, kemPk: kp.publicKey }) === v.plaintext);
    // Re-derive the payload from the pinned randomness and require exact bytes.
    const e = kem.encapsulate(kp.publicKey, unhex(v.encapsulationRandomness));
    const ecdhX = T._secp256k1.getSharedSecret(unhex(v.senderPrivkey), '02' + v.recipPubkey).subarray(1, 33);
    const ck = NC.pqConversationKey(ecdhX, e.sharedSecret, e.cipherText, kp.publicKey, v.senderPubkey, v.recipPubkey);
    chk(`endToEnd[${i}] conversation key matches`, hex(ck) === v.conversationKey);
    chk(`endToEnd[${i}] payload is byte-identical`,
        `pq1.${NC._b64uEncode(e.cipherText)}.${T.nip44.encrypt(v.plaintext, ck, unhex(v.nip44Nonce))}` === v.payload);
}

section('gift wrap vector (the layering contract with the Flutter port)');
{
    const g = V.giftWrap;
    const kp = kem.keygen(unhex(g.recipKemSeed));
    chk('wrap event signature verifies', T.verifyEvent(g.wrap));
    chk('wrap is kind 1059 with only a p tag',
        g.wrap.kind === 1059 && JSON.stringify(g.wrap.tags) === JSON.stringify([['p', g.recipPubkey]]));
    const r = NC.unwrapGiftWrap(g.wrap, [
        { sk: unhex(g.recipPrivkey), bitchat: false, kemSk: kp.secretKey, kemPk: kp.publicKey },
    ]);
    chk('gift wrap unwraps', !!r && r.isPq === true);
    chk('recovered rumor matches', r && JSON.stringify(r.rumor) === JSON.stringify(g.rumor));
    chk('recovered seal matches', r && r.seal.id === g.seal.id && T.verifyEvent(r.seal));
    chk('seal author is the sender', r && r.seal.pubkey === g.senderPubkey);
    chk('wrap author is ephemeral', g.wrap.pubkey !== g.senderPubkey);
}

// -------------------------------------------------- announcement + discovery
// js/modules/pq.js decides WHO gets post-quantum. Its validation and expiry
// rules are security-relevant (a forged or stale announcement must never
// attract PQ traffic), so exercise them against a minimal host object.
section('announcement + discovery (js/modules/pq.js)');
{
    const store = new Map();
    globalThis.localStorage = {
        getItem: (k) => (store.has(k) ? store.get(k) : null),
        setItem: (k, v) => store.set(k, String(v)),
        removeItem: (k) => store.delete(k),
    };
    globalThis.window = globalThis;
    globalThis.NYM = function NYM() { };
    vm.runInThisContext(fs.readFileSync(path.join(root, 'js/modules/pq.js'), 'utf8'),
        { filename: 'js/modules/pq.js' });

    const mkNym = (privkey) => {
        const n = new globalThis.NYM();
        n.privkey = privkey;
        n.pubkey = T.getPublicKey(privkey);
        n.connected = true;
        n.pqKeys = new Map();
        n.sent = [];
        n.sendToRelay = (m) => n.sent.push(m);
        n.signEvent = async (e) => T.finalizeEvent(e, privkey);
        return n;
    };

    const skA = T.generateSecretKey();
    const a = mkNym(skA);

    chk('ML-KEM is detected as supported', a.pqSupported());
    chk('a local key makes us capable', a.pqCapable());

    // Sending and receiving are separate questions, and the difference is the
    // whole of what an extension / NIP-46 login can and cannot do.
    //
    // A NIP-17 message is a SEAL under the identity key inside a WRAP under a
    // throwaway key we generate ourselves. Only the seal needs the signer, so
    // such a login can still hybridize the wrap — and the wrap is the layer a
    // recorder stores, so that already defeats harvest-now-decrypt-later.
    // Receiving is a different matter: the ML-KEM keypair derives from the
    // nsec, and opening a message means decapsulating with its secret half.
    {
        const ext = mkNym(skA);
        ext.privkey = null; // extension / NIP-46: signs, never reveals the key
        chk('a signer login can send post-quantum', ext.pqSendCapable() && ext.pqEnabled());
        chk('a signer login cannot receive it', !ext.pqCapable());
        chk('and so announces no key of its own', !ext.pqSelfEnabled());
        chk('and derives no keypair', ext.pqSelfKeys() === null);
        chk('and offers no unwrap candidates', ext.pqUnwrapCandidates([skA]).length === 0);

        // The lock-out hazard: a SECOND device holding the nsec may already
        // have announced a key for this npub. Encapsulating our own settings
        // and history to it from here would make them unreadable on this
        // device, permanently — it cannot derive the secret half.
        const selfKeys = window.NymCrypto.pqKeypairFromPrivkey(skA, 0);
        ext.pqKeys.set(ext.pubkey, { pk: selfKeys.publicKey, exp: 2000000000, ts: 1700000000 });
        chk('a peer key is still usable for sending', !!ext.pqKeyFor(ext.pubkey));
        chk('but our own copies stay classical, so we can still read them',
            ext.pqSelfKeyFor() === null);

        const local = mkNym(skA);
        local.pqKeys.set(local.pubkey, { pk: selfKeys.publicKey, exp: 2000000000, ts: 1700000000 });
        chk('an nsec login does encrypt its own copies post-quantum',
            !!local.pqSelfKeyFor());
    }

    // The escape hatch still turns everything off, on either kind of login.
    store.set('nym_pq_mode', 'off');
    {
        const ext = mkNym(skA);
        ext.privkey = null;
        chk('the escape hatch disables sending too', !ext.pqEnabled());
        chk('and self copies', !a.pqSelfEnabled());
    }
    store.delete('nym_pq_mode');

    // Upgrade path: an existing install must default to OFF, because an older
    // device on the same nsec would be locked out by a silent switch.
    // No user setting: post-quantum is on for anyone who can do it.
    store.delete('nym_pq_mode');
    chk('post-quantum is on with no setting to enable', a.pqEnabled());

    // Upgrades get a one-time notice; fresh installs have no older device on
    // the same npub to strand, so they get none.
    store.set('nym_last_online_ts', '1700000000');
    store.delete('nym_pq_upgrade_notice');
    store.delete('nym_pq_upgrade_seen');
    {
        const up = mkNym(skA);
        up._pqMarkUpgradeIfNeeded();
        chk('an upgrade raises a one-time notice, since an older device on the '
            + 'same npub would stop receiving messages', up.pqUpgradeNoticePending());
        chk('post-quantum is on regardless', up.pqEnabled());
        up.dismissPqUpgradeNotice();
        chk('the notice is dismissible and stays dismissed', !up.pqUpgradeNoticePending());
        up._pqMarkUpgradeIfNeeded();
        chk('the notice never comes back', !up.pqUpgradeNoticePending());
    }
    store.delete('nym_last_online_ts');
    store.delete('nym_pq_upgrade_notice');
    store.delete('nym_pq_upgrade_seen');
    {
        const fresh = mkNym(skA);
        fresh._pqMarkUpgradeIfNeeded();
        chk('a fresh install raises no notice', !fresh.pqUpgradeNoticePending());
        chk('a fresh install still has post-quantum on', fresh.pqEnabled());
    }

    // The undocumented escape hatch, for defusing a field bug without an
    // emergency release. Nothing in the app writes it.
    store.set('nym_pq_mode', 'off');
    chk('the storage escape hatch disables post-quantum', !mkNym(skA).pqEnabled());
    store.delete('nym_pq_mode');
    chk('and removing it restores the default', mkNym(skA).pqEnabled());

    // Extension / NIP-46 logins have no local secret key, so they can wrap a
    // hybrid message but never open one.
    const ext = mkNym(skA);
    ext.privkey = null;
    chk('no local key means we cannot receive', !ext.pqCapable());
    chk('but we can still send', ext.pqEnabled());

    chk('self keys derive and are cached', (() => {
        const k1 = a.pqSelfKeys(), k2 = a.pqSelfKeys();
        return k1 && k1.publicKey.length === 1184 && k1 === k2;
    })());

    await a.publishPqAnnouncement();
    const ann = a.sent.length ? a.sent[a.sent.length - 1][1] : null;
    chk('announcement is published', !!ann && ann.kind === 30078);
    chk('announcement signature verifies (binds the KEM key to the identity)',
        ann && T.verifyEvent(ann));
    chk('announcement carries d/t = nym-pq and a NIP-40 expiration', ann &&
        ann.tags.some(t => t[0] === 'd' && t[1] === 'nym-pq') &&
        ann.tags.some(t => t[0] === 't' && t[1] === 'nym-pq') &&
        ann.tags.some(t => t[0] === 'expiration'));
    chk('publishing records our own key for self-addressed wraps',
        !!a.pqKeyFor(a.pubkey));

    // A second identity ingesting the announcement.
    const b = mkNym(T.generateSecretKey());
    store.set('nym_pq_mode', 'on');
    b.handlePqAnnouncement(ann);
    chk('peer ingests the announced key', (() => {
        const pk = b.pqKeyFor(a.pubkey);
        return pk instanceof Uint8Array && pk.length === 1184;
    })());
    chk('the ingested key is the sender\'s real ML-KEM key',
        Buffer.from(b.pqKeyFor(a.pubkey)).equals(Buffer.from(a.pqSelfKeys().publicKey)));

    chk('an unknown peer yields null (falls back to classical)',
        b.pqKeyFor(T.getPublicKey(T.generateSecretKey())) === null);

    // Expiry and malformed input.
    const mutate = (fn) => {
        const p = JSON.parse(ann.content);
        fn(p);
        return T.finalizeEvent({ ...ann, content: JSON.stringify(p), id: undefined, sig: undefined }, skA);
    };
    const c = mkNym(T.generateSecretKey());
    c.handlePqAnnouncement(mutate(p => { p.exp = Math.floor(Date.now() / 1000) - 1; }));
    chk('an expired announcement is ignored', c.pqKeyFor(a.pubkey) === null);

    const d = mkNym(T.generateSecretKey());
    d.handlePqAnnouncement(mutate(p => { p.pk = NC._b64uEncode(new Uint8Array(32)); }));
    chk('a wrong-length ML-KEM key is rejected', d.pqKeyFor(a.pubkey) === null);

    const e2 = mkNym(T.generateSecretKey());
    e2.handlePqAnnouncement(mutate(p => { p.alg = 'kyber512'; }));
    chk('an unknown algorithm is rejected', e2.pqKeyFor(a.pubkey) === null);

    const f = mkNym(T.generateSecretKey());
    f.handlePqAnnouncement({ ...ann, content: 'not json' });
    chk('malformed content is ignored, not thrown on', f.pqKeyFor(a.pubkey) === null);

    // Retraction: a peer that turns PQ off must stop attracting PQ traffic.
    b.handlePqAnnouncement(mutate(p => { p.retracted = true; delete p.pk; }));
    chk('a retraction drops the peer key', b.pqKeyFor(a.pubkey) === null);

    // Key rotation keeps older epochs decryptable.
    chk('rotation changes the advertised key and keeps prior epochs openable', (() => {
        const before = a.pqSelfKeys().publicKey;
        store.set('nym_pq_epoch', '1');
        a._pqSelfCache = null;
        const after = a.pqSelfKeys().publicKey;
        const cands = a.pqSelfCandidates();
        const hasOld = cands.some(c2 => Buffer.from(c2.kemPk).equals(Buffer.from(before)));
        const hasNew = cands.some(c2 => Buffer.from(c2.kemPk).equals(Buffer.from(after)));
        return !Buffer.from(before).equals(Buffer.from(after)) && hasOld && hasNew;
    })());

    // Device roster.
    store.set('nym_pq_epoch', '0');
    a._pqSelfCache = null;
    const roster = a.pqDeviceRoster();
    chk('the device roster lists this device', roster.length >= 1 && roster.some(r => r.isSelf));

    // --- send-path routing (pqPmPlan) ---------------------------------------
    // The rule both PM send paths share. Getting this wrong is how a message
    // ends up ALSO sent classically, silently voiding the post-quantum
    // guarantee while the UI still claims it.
    section('send-path routing (pqPmPlan)');
    {
        const n = mkNym(skA);
        store.set('nym_pq_mode', 'on');
        const peer = T.getPublicKey(T.generateSecretKey());
        const kem2 = NC.pqKeypairFromPrivkey(T.generateSecretKey(), 0);
        const withKey = () => { n._pqRecord(peer, kem2.publicKey, Math.floor(Date.now() / 1000) + 3600, 0); };
        const reset = () => { n.pqKeys = new Map(); n.bitchatUsers = new Set(); n.nymUsers = new Set(); };

        reset();
        let p2 = n.pqPmPlan(peer);
        chk('unknown peer, no PQ key: bitchat + classical nym (unchanged today)',
            !p2.pq && p2.bitchat && p2.nym);

        reset(); n.bitchatUsers.add(peer);
        p2 = n.pqPmPlan(peer);
        chk('known bitchat peer: bitchat only, never post-quantum',
            !p2.pq && p2.bitchat && !p2.nym);

        reset(); n.nymUsers.add(peer);
        p2 = n.pqPmPlan(peer);
        chk('known nym peer without a key: classical nym only',
            !p2.pq && !p2.bitchat && p2.nym);

        reset(); withKey();
        p2 = n.pqPmPlan(peer);
        chk('unknown peer WITH a key: post-quantum, and no bitchat copy',
            p2.pq && p2.nym && !p2.bitchat);

        reset(); n.nymUsers.add(peer); withKey();
        p2 = n.pqPmPlan(peer);
        chk('known nym peer with a key: post-quantum, no bitchat copy',
            p2.pq && p2.nym && !p2.bitchat);

        // The dangerous case: a peer we believe uses bitchat who has also
        // announced. Sending both would leak the plaintext to the weaker copy.
        reset(); n.bitchatUsers.add(peer); withKey();
        p2 = n.pqPmPlan(peer);
        chk('a bitchat-flagged peer WITH a key gets no classical copy alongside',
            p2.pq && !p2.bitchat);

        chk('the plan carries the recipient key it decided with',
            p2.kemPk && Buffer.from(p2.kemPk).equals(Buffer.from(kem2.publicKey)));

        // Turning post-quantum off stops PQ, but the peer is still a PROVEN
        // Nymchat client, so Auto still has no reason to send them a Bitchat
        // wrap. That is the point of splitting the two signals.
        reset(); withKey();
        store.set('nym_pq_mode', 'off');
        p2 = n.pqPmPlan(peer);
        chk('with PQ off, no post-quantum wrap is sent',
            !p2.pq && p2.kemPk === null && p2.nym);
        chk('with PQ off, a proven Nymchat peer still gets no Bitchat wrap',
            !p2.bitchat && p2.provenNym);
        store.set('nym_pq_mode', 'on');

        // An expired announcement must fall back, not fail.
        reset();
        n._pqRecord(peer, kem2.publicKey, Math.floor(Date.now() / 1000) - 1, 0);
        p2 = n.pqPmPlan(peer);
        chk('an expired key falls back to the classical route',
            !p2.pq && p2.bitchat && p2.nym);

        // --- capability announcements without a key --------------------------
        // The case that motivates splitting the signals: a Nymchat user who has
        // post-quantum off, or is on an extension login that cannot do it at
        // all. They are provably not on Bitchat, so the Bitchat wrap is waste.
        const live = () => Math.floor(Date.now() / 1000) + 3600;
        reset();
        n._pqRecord(peer, null, live(), 0);
        p2 = n.pqPmPlan(peer);
        chk('a KEM-less announcement still proves the peer runs Nymchat', p2.provenNym);
        chk('a KEM-less announcement suppresses the Bitchat wrap', !p2.bitchat);
        chk('a KEM-less announcement does not claim post-quantum', !p2.pq && p2.nym);
        chk('a KEM-less peer is not counted as a post-quantum peer',
            !n.pqKnownPeers().includes(peer));

        reset();
        chk('no announcement means not proven, so dual-send is kept',
            !n.pqPmPlan(peer).provenNym && n.pqPmPlan(peer).bitchat);

        // --- Bitchat wrap suppression ---------------------------------------
        // No setting: a live announcement proves the peer is not on Bitchat,
        // so the extra copy is dropped. Anyone we cannot prove gets exactly
        // what they got before post-quantum existed.
        section('Bitchat wrap suppression');

        reset(); n._pqRecord(peer, null, live(), 0);
        chk('a proven Nymchat peer gets no Bitchat wrap', !n.pqPmPlan(peer).bitchat);

        reset(); withKey();
        p2 = n.pqPmPlan(peer);
        chk('a post-quantum wrap is never paired with a Bitchat copy',
            p2.pq && !p2.bitchat);

        reset(); n.bitchatUsers.add(peer);
        chk('a known Bitchat peer with no announcement still gets one',
            n.pqPmPlan(peer).bitchat);

        reset(); n.bitchatUsers.add(peer); n._pqRecord(peer, null, live(), 0);
        chk('an announcement overrides a stale bitchat flag',
            !n.pqPmPlan(peer).bitchat);

        reset(); n.nymUsers.add(peer);
        chk('a known nym peer gets no Bitchat wrap', !n.pqPmPlan(peer).bitchat);

        reset();
        chk("an unknown peer keeps the pre-existing dual-send",
            n.pqPmPlan(peer).bitchat && n.pqPmPlan(peer).nym);

        // A message must always leave in SOME format, whatever the peer state.
        for (const setup of [
            () => { reset(); },
            () => { reset(); n.bitchatUsers.add(peer); },
            () => { reset(); n.nymUsers.add(peer); },
            () => { reset(); n._pqRecord(peer, null, live(), 0); },
            () => { reset(); withKey(); },
        ]) {
            setup();
            const pl = n.pqPmPlan(peer);
            if (!(pl.bitchat || pl.nym)) chk('a message is always sent in some format', false);
        }
        chk('every peer state produces at least one transport', true);
    }

    // --- group fan-out ------------------------------------------------------
    section('group fan-out');
    {
        const n = mkNym(skA);
        store.set('nym_pq_mode', 'on');
        n.pqKeys = new Map();

        // Decrypt-candidate ordering. A group wrap's classical leg goes to a
        // rotating EPHEMERAL key while its KEM leg uses the identity key, so a
        // candidate pairs one of each. Ordering matters: mispaired candidates
        // cost a full ML-KEM decapsulation each.
        const ephSk = T.generateSecretKey();
        const cands = n.pqUnwrapCandidates([ephSk, n.privkey]);
        chk('candidates pair a secp key with our ML-KEM keypair',
            cands.length > 0 && cands[0].kemSk && cands[0].kemPk && cands[0].sk);
        chk('the first candidate uses the leading secp key (the p-tag match)',
            Buffer.from(cands[0].sk).equals(Buffer.from(ephSk)));
        chk('the first candidate uses the current ML-KEM epoch',
            Buffer.from(cands[0].kemPk).equals(Buffer.from(n.pqSelfKeys().publicKey)));
        chk('pairing is bounded so a group wrap costs one decapsulation, not dozens',
            cands.length <= n.PQ_SK_PAIRING_LIMIT * n.pqSelfCandidates().length);
        chk('a long ephemeral history does not blow up the candidate list',
            n.pqUnwrapCandidates(new Array(30).fill(0).map(() => T.generateSecretKey())).length
                <= n.PQ_SK_PAIRING_LIMIT * n.pqSelfCandidates().length);

        // An end-to-end group-shaped wrap: classical leg to the ephemeral key,
        // KEM leg to the identity key.
        const ephPk = T.getPublicKey(ephSk);
        const selfKem = n.pqSelfKeys();
        const gWrap = NC.pqNip59Wrap(
            { kind: 14, created_at: 1700000000, tags: [['g', 'grp']], content: 'group pq' },
            T.generateSecretKey(), ephPk, selfKem.publicKey, null);
        const got = NC.unwrapGiftWrap(gWrap, n.pqUnwrapCandidates([ephSk, n.privkey]));
        chk('a group wrap (ephemeral secp + identity KEM) decrypts',
            !!got && got.isPq === true && got.rumor.content === 'group pq');
        chk('the winning candidate is the first one tried', got && got.idx === 0);

        // Coverage: partial must NOT read as protected.
        n._recordGroupPqCoverage('MSG1', 10, 10);
        n._recordGroupPqCoverage('MSG2', 8, 10);
        n._recordGroupPqCoverage('MSG3', 0, 10);
        const cov = (id) => n.pqGroupCoverageFor(id);
        chk('full coverage is recorded', cov('MSG1').pq === 10 && cov('MSG1').total === 10);
        chk('partial coverage is recorded exactly', cov('MSG2').pq === 8 && cov('MSG2').total === 10);
        const isProtected = (id) => { const c = cov(id); return !!c && c.total > 0 && c.pq === c.total; };
        chk('only full coverage counts as post-quantum', isProtected('MSG1'));
        chk('partial coverage does NOT count — one classical copy is enough for an attacker',
            !isProtected('MSG2'));
        chk('zero coverage does not count', !isProtected('MSG3'));
        chk('an unknown message has no coverage', cov('NOPE') === null);
        chk('coverage map is bounded', (() => {
            for (let i = 0; i < 2100; i++) n._recordGroupPqCoverage('M' + i, 1, 1);
            return n.pqGroupCoverage.size <= 2000;
        })());

        // Per-member routing: a mixed group must fan out both transports.
        const m1 = T.getPublicKey(T.generateSecretKey());
        const m2 = T.getPublicKey(T.generateSecretKey());
        n.pqKeys = new Map();
        n._pqRecord(m1, selfKem.publicKey, Math.floor(Date.now() / 1000) + 3600, 0);
        chk('a member who announced resolves to a key', !!n.pqGroupKeyFor(m1));
        chk('a member who did not stays classical', n.pqGroupKeyFor(m2) === null);
    }

    section('announcement + discovery (js/modules/pq.js), continued');
    // Kind 30078 is addressable, so each publish REPLACES the last. Relays
    // break a created_at tie by keeping the lexically-lower event id, so two
    // publishes in the same second can silently lose one — a rotation landing
    // right after a boot publish would leave peers on a stale key.
    {
        const m = mkNym(skA);
        m.connected = true;
        await m.publishPqAnnouncement();
        await m.publishPqAnnouncement();
        await m.publishPqAnnouncement();
        const evs = m.sent.map(x => x[1]);
        chk('every announcement targets the same replaceable address', evs.every(e =>
            e.kind === 30078 && e.tags.some(t => t[0] === 'd' && t[1] === 'nym-pq')));
        chk('rapid republishes never tie on created_at', (() => {
            for (let i = 1; i < evs.length; i++) {
                if (evs[i].created_at <= evs[i - 1].created_at) return false;
            }
            return true;
        })());
        chk('the expiration tracks the bumped timestamp', evs.every(e => {
            const exp = parseInt(e.tags.find(t => t[0] === 'expiration')[1], 10);
            return exp === e.created_at + 7 * 24 * 3600;
        }));
    }

    // The escape hatch republishes without a key rather than retracting, so
    // peers stop encapsulating to us immediately but keep knowing we are a
    // Nymchat client — otherwise we would look like a Bitchat user again and
    // start attracting pointless Bitchat wraps.
    store.set('nym_pq_mode', 'off');
    {
        const off = mkNym(skA);
        off.connected = true;
        await off.publishPqAnnouncement();
        const last = JSON.parse(off.sent[off.sent.length - 1][1].content);
        chk('with post-quantum off, we still announce', last.nym === 1);
        chk('with post-quantum off, we advertise no ML-KEM key', last.pk === undefined);
        chk('with post-quantum off, we do not retract', last.retracted !== true);
        chk('pqKeyFor returns null while off', off.pqKeyFor(off.pubkey) === null);
        chk('but we still register as a Nymchat client',
            off.isKnownNymchatClient(off.pubkey));
    }
    store.delete('nym_pq_mode');
}

// ------------------------------------------------------------------- badge
// The badge must never overstate protection. Partial group coverage is the
// case that matters: if even one member got a classical copy of the same
// plaintext, breaking secp256k1 reveals the message, so it must not render as
// protected.
section('on-demand announcement discovery');
{
    // The gap this closes: the standing subscription for announcements is built
    // once at connect, from the conversation list as it exists then. A peer we
    // start talking to afterwards was never asked about, so we held no key for
    // them and every message went classical with no shield — which on a fresh
    // login, where the list starts empty, meant every peer.
    const mkPeer = () => T.getPublicKey(T.generateSecretKey());
    const live = () => Math.floor(Date.now() / 1000) + 3600;
    // D1 is asked first and answers asynchronously (with nothing, in these
    // tests — no API host is configured), so the relay request it falls back
    // to lands a microtask later than it used to.
    const tick = () => new Promise((r) => setTimeout(r, 0));

    // mkNym is scoped to the block above; the prototype itself is global.
    const mkFetcher = () => {
        const sk = T.generateSecretKey();
        const n = new globalThis.NYM();
        n.privkey = sk;
        n.pubkey = T.getPublicKey(sk);
        n.connected = true;
        n.pqKeys = new Map();
        n.reqs = [];
        n._subscriptionHandlers = new Map();
        n._isNostrHex64 = (v) => typeof v === 'string' && /^[0-9a-f]{64}$/.test(v);
        n.closeFewRelaysSub = () => { };
        n.sendRequestToFewRelays = (req) => n.reqs.push(req);
        return n;
    };

    {
        const n = mkFetcher();
        const peer = mkPeer();
        n.ensurePqAnnouncement(peer);
        await tick();
        chk('a peer we hold no key for is asked about', n.reqs.length === 1);
        const f = n.reqs[0][2];
        chk('the lookup is scoped to that peer',
            f.kinds[0] === 30078 && f['#t'][0] === 'nym-pq'
            && f.authors.length === 1 && f.authors[0] === peer);
    }

    {
        // A key ends the search.
        const n = mkFetcher();
        const peer = mkPeer();
        const kem = NC.pqKeypairFromPrivkey(T.generateSecretKey(), 0);
        n._pqRecord(peer, kem.publicKey, live(), 0);
        n.ensurePqAnnouncement(peer);
        await tick();
        chk('a peer we already hold a KEY for is not re-asked', n.reqs.length === 0);
    }
    {
        // A KEYLESS entry does not. It says "this was a Nymchat client with no
        // post-quantum key" — true when recorded, and recorded for a week. A
        // peer who was on an older build, or signed in with an extension, and
        // has since switched to their nsec would go on getting classical
        // messages for the rest of that week if this stopped here.
        const n = mkFetcher();
        const peer = mkPeer();
        n._pqRecord(peer, null, live(), 0);
        n.ensurePqAnnouncement(peer);
        await tick();
        chk('a peer we hold a KEYLESS entry for is asked again', n.reqs.length === 1);
        // ...but not on every send: the re-check is rate-limited like a miss.
        const subId = n.reqs[0][1];
        n._subscriptionHandlers.get(subId)('EOSE', [subId]);
        n.ensurePqAnnouncement(peer);
        await tick();
        chk('and not re-asked again straight away', n.reqs.length === 1);
    }

    {
        // Two sends racing for the same new peer must not open two lookups.
        const n = mkFetcher();
        const peer = mkPeer();
        const a = n.ensurePqAnnouncement(peer);
        const b = n.ensurePqAnnouncement(peer);
        await tick();
        chk('concurrent lookups share one subscription', n.reqs.length === 1);
        chk('concurrent lookups share one promise', a === b);
    }

    {
        // Answering resolves the wait and records the key, so the very first
        // message to a new peer can still be post-quantum.
        const n = mkFetcher();
        const peerSk = T.generateSecretKey();
        const peer = T.getPublicKey(peerSk);
        const peerKem = NC.pqKeypairFromPrivkey(peerSk, 0);
        const waiting = n.ensurePqAnnouncement(peer);
        await tick();
        const subId = n.reqs[0][1];
        const handler = n._subscriptionHandlers.get(subId);
        chk('a handler is registered for the lookup', typeof handler === 'function');
        const exp = live();
        handler('EVENT', [subId, {
            kind: 30078, pubkey: peer,
            tags: [['d', 'nym-pq'], ['t', 'nym-pq'], ['expiration', String(exp)]],
            content: JSON.stringify({
                v: 1, alg: 'mlkem768', nym: 1, epoch: 0,
                pk: NC._b64uEncode(peerKem.publicKey), exp
            })
        }]);
        const got = await waiting;
        chk('the answer resolves the wait', !!got);
        chk('the key is recorded', !!n.pqKeyFor(peer));
        chk('and it is the key that was announced',
            eq(n.pqKeyFor(peer), peerKem.publicKey));
        chk('the send plan now goes post-quantum', n.pqPmPlan(peer).pq === true);
        chk('the lookup is closed out', !n._subscriptionHandlers.has(subId));
    }

    {
        // A peer with no announcement is normal, not an error: resolve, and do
        // not re-ask on every keystroke's worth of send-path checks.
        const n = mkFetcher();
        const peer = mkPeer();
        const waiting = n.ensurePqAnnouncement(peer);
        await tick();
        const subId = n.reqs[0][1];
        n._subscriptionHandlers.get(subId)('EOSE', [subId]);
        chk('an absent announcement resolves rather than hanging',
            (await waiting) === null);
        n.ensurePqAnnouncement(peer);
        await tick();
        chk('a miss is not immediately re-asked', n.reqs.length === 1);
    }

    {
        // The race that kept two post-quantum users messaging classically. The
        // request fans out to several relays; the ones WITHOUT the announcement
        // are the ones that answer instantly, and finishing on that first EOSE
        // ended the wait before the relay that had the key could deliver it.
        const n = mkFetcher();
        const peerSk = T.generateSecretKey();
        const peer = T.getPublicKey(peerSk);
        const peerKem = NC.pqKeypairFromPrivkey(peerSk, 0);
        const waiting = n.ensurePqAnnouncement(peer);
        await tick();
        const subId = n.reqs[0][1];
        const handler = n._subscriptionHandlers.get(subId);

        // Relay 1 has nothing and says so first.
        handler('EOSE', [subId]);
        chk('one relay\'s EOSE does not end the search',
            !n._pqFetches.get(peer) || !!n._pqFetches.get(peer).promise);

        // Relay 2 answers a moment later, as a slower relay does.
        const exp = live();
        handler('EVENT', [subId, {
            kind: 30078, pubkey: peer,
            tags: [['d', 'nym-pq'], ['t', 'nym-pq'], ['expiration', String(exp)]],
            content: JSON.stringify({
                v: 1, alg: 'mlkem768', nym: 1, epoch: 0,
                pk: NC._b64uEncode(peerKem.publicKey), exp,
            }),
        }]);
        chk('a later relay\'s answer is still taken', (await waiting) !== null);
        chk('and the key is the one it announced',
            !!n.pqKeyFor(peer) && eq(n.pqKeyFor(peer), peerKem.publicKey));
        chk('so the send plan goes post-quantum', n.pqPmPlan(peer).pq === true);
    }

    {
        // ...and an EOSE when the answer is already in ends it at once, rather
        // than making every successful lookup wait out the grace period.
        const n = mkFetcher();
        const peerSk = T.generateSecretKey();
        const peer = T.getPublicKey(peerSk);
        const peerKem = NC.pqKeypairFromPrivkey(peerSk, 0);
        const waiting = n.ensurePqAnnouncement(peer);
        await tick();
        const subId = n.reqs[0][1];
        const handler = n._subscriptionHandlers.get(subId);
        const exp = live();
        handler('EVENT', [subId, {
            kind: 30078, pubkey: peer,
            tags: [['d', 'nym-pq'], ['t', 'nym-pq'], ['expiration', String(exp)]],
            content: JSON.stringify({
                v: 1, alg: 'mlkem768', nym: 1, epoch: 0,
                pk: NC._b64uEncode(peerKem.publicKey), exp,
            }),
        }]);
        chk('an event resolves immediately', (await waiting) !== null);
    }

    {
        const n = mkFetcher();
        n.prefetchPqAnnouncements([mkPeer(), mkPeer(), mkPeer()]);
        await tick();
        chk('opening a conversation warms every member', n.reqs.length === 3);
        const n2 = mkFetcher();
        n2.prefetchPqAnnouncements(Array.from({ length: 200 }, mkPeer));
        await tick();
        chk('a large group does not fire one subscription per member',
            n2.reqs.length === 60);
        const n3 = mkFetcher();
        n3.prefetchPqAnnouncements(['not-a-pubkey', '', null]);
        await tick();
        chk('junk pubkeys are skipped', n3.reqs.length === 0);
    }
}

section('D1 is asked first, and is not trusted');
{
    const mkPeer2 = () => T.generateSecretKey();
    const live2 = () => Math.floor(Date.now() / 1000) + 3600;

    /// A nym whose D1 read returns `events` and whose signature check answers
    /// `verified`.
    const mkD1 = (events, verified = true) => {
        const sk = T.generateSecretKey();
        const n = new globalThis.NYM();
        n.privkey = sk;
        n.pubkey = T.getPublicKey(sk);
        n.connected = true;
        n.pqKeys = new Map();
        n.reqs = [];
        n._subscriptionHandlers = new Map();
        n._isNostrHex64 = (v) => typeof v === 'string' && /^[0-9a-f]{64}$/.test(v);
        n.closeFewRelaysSub = () => { };
        n.sendRequestToFewRelays = (r) => n.reqs.push(r);
        n._getApiHost = () => 'https://example.test';
        n.d1Calls = [];
        n._storageApiStream = async (action, extra) => {
            n.d1Calls.push({ action, extra });
            return { events };
        };
        n._readNdjsonStream = async (resp, onItem) => {
            for (const e of resp.events) onItem(e);
        };
        n._verifyRelayEventAsync = async () => verified;
        return n;
    };

    const announcement = (sk, { withKey = true } = {}) => {
        const pub = T.getPublicKey(sk);
        const kem = NC.pqKeypairFromPrivkey(sk, 0);
        const exp = live2();
        return T.finalizeEvent({
            kind: 30078,
            created_at: Math.floor(Date.now() / 1000),
            tags: [['d', 'nym-pq'], ['t', 'nym-pq'], ['expiration', String(exp)]],
            content: JSON.stringify({
                v: 1, alg: 'mlkem768', nym: 1, epoch: 0, exp,
                ...(withKey ? { pk: NC._b64uEncode(kem.publicKey) } : {}),
            }),
        }, sk);
    };

    {
        const peerSk = mkPeer2(), peer = T.getPublicKey(peerSk);
        const n = mkD1([announcement(peerSk)]);
        const entry = await n.ensurePqAnnouncement(peer);
        chk('D1 is asked', n.d1Calls.length === 1);
        chk('...for the right channel and author',
            n.d1Calls[0].extra.channel === 'nym-pq'
            && n.d1Calls[0].extra.authors[0] === peer);
        chk('and its answer is used', !!entry && !!entry.pk);
        // The point of the whole change: no relay race when D1 has it.
        chk('no relay request is made when D1 answers', n.reqs.length === 0);
        chk('the send plan goes post-quantum', n.pqPmPlan(peer).pq === true);
    }

    {
        // D1 is a cache, not an authority. An event whose signature does not
        // check out is worth less than nothing: the ML-KEM key inside is what
        // peers encapsulate to, so accepting a forged one would hand whoever
        // served it the plaintext.
        const peerSk = mkPeer2(), peer = T.getPublicKey(peerSk);
        const n = mkD1([announcement(peerSk)], false);
        await n.ensurePqAnnouncement(peer);
        chk('an unverified D1 event is refused', !n.pqKeyFor(peer));
        chk('and the relays are asked instead', n.reqs.length === 1);
    }

    {
        const peerSk = mkPeer2(), peer = T.getPublicKey(peerSk);
        const n = mkD1([]);
        await n.ensurePqAnnouncement(peer);
        chk('an empty D1 answer falls back to the relays', n.reqs.length === 1);
    }

    {
        // A keyless announcement in D1 is not the answer either — the lookup
        // exists to find a KEY.
        const peerSk = mkPeer2(), peer = T.getPublicKey(peerSk);
        const n = mkD1([announcement(peerSk, { withKey: false })]);
        await n.ensurePqAnnouncement(peer);
        chk('a keyless D1 answer still tries the relays', n.reqs.length === 1);
    }

    {
        // An event for someone else must never satisfy a lookup.
        const peerSk = mkPeer2(), peer = T.getPublicKey(peerSk);
        const otherSk = mkPeer2();
        const n = mkD1([announcement(otherSk)]);
        await n.ensurePqAnnouncement(peer);
        chk('an announcement from a different pubkey is ignored', !n.pqKeyFor(peer));
        chk('and does not end the search', n.reqs.length === 1);
    }
}

section('the registry survives a reload');
{
    // A cached key is a HINT, never the final word — and the difference
    // matters more here than for the other caches, because this is a key we
    // ENCRYPT TO. A wrong one does not degrade a message to classical, it
    // makes it unreadable: the recipient has no secret half to decapsulate
    // with and the text never opens for them.
    const src = fs.readFileSync(path.join(root, 'js/modules/persistence.js'), 'utf8');
    const at = src.indexOf('        async _hydratePqKeys(');
    let depth = 0, i = src.indexOf('{', at);
    for (; i < src.length; i++) {
        if (src[i] === '{') depth++;
        else if (src[i] === '}') { depth--; if (depth === 0) break; }
    }
    const META = /const META_PQ_KEYS = '([^']+)'/.exec(src)[1];
    const { _hydratePqKeys } = new Function('META_PQ_KEYS',
        `return { ${src.slice(at, i + 1)} };`)(META);

    const n = new globalThis.NYM();
    n.pqKeys = new Map();
    n._hydratePqKeys = _hydratePqKeys;
    const nowSec = Math.floor(Date.now() / 1000);
    const kem = NC.pqKeypairFromPrivkey(T.generateSecretKey(), 0);
    const pk = (n2) => T.getPublicKey(T.generateSecretKey());
    const liveKey = pk(), expired = pk(), keyless = pk();

    await n._hydratePqKeys([{ key: META, entries: [
        [liveKey, NC._b64uEncode(kem.publicKey), nowSec + 3600, 0],
        [expired, NC._b64uEncode(kem.publicKey), nowSec - 10, 0],
        [keyless, null, nowSec + 3600, 0],
    ] }]);

    chk('a live key comes back', !!n.pqKeys.get(liveKey));
    chk('...byte for byte', eq(n.pqKeys.get(liveKey).pk, kem.publicKey));
    // The bound that keeps a stale key from making a message unreadable.
    chk('an EXPIRED entry is dropped rather than restored', !n.pqKeys.get(expired));
    chk('a keyless entry restores as keyless', 
        !!n.pqKeys.get(keyless) && n.pqKeys.get(keyless).pk === null);

    await n._hydratePqKeys([{ key: META, entries: [
        ['a'.repeat(64), '!!!not-base64!!!', nowSec + 60, 0],
        ['b'.repeat(64), NC._b64uEncode(new Uint8Array(32)), nowSec + 60, 0],
        ['c'.repeat(64), NC._b64uEncode(kem.publicKey), 'not-a-number', 0],
    ] }]);
    chk('undecodable stored data is skipped', !n.pqKeys.get('a'.repeat(64)));
    chk('a wrong-sized key is skipped', !n.pqKeys.get('b'.repeat(64)));
    chk('a malformed expiry is skipped', !n.pqKeys.get('c'.repeat(64)));
}

section('badge state');
{
    globalThis.NYM = globalThis.NYM || function NYM() { };
    const M = {};
    // Pull just the two pure helpers out of messages.js without loading the
    // whole UI module (which needs a DOM).
    const src = fs.readFileSync(path.join(root, 'js/modules/messages.js'), 'utf8');
    const grab = (name) => {
        const start = src.indexOf(`    ${name}(`);
        if (start < 0) throw new Error('missing ' + name);
        let depth = 0, i = src.indexOf('{', start);
        const from = i;
        for (; i < src.length; i++) {
            if (src[i] === '{') depth++;
            else if (src[i] === '}') { depth--; if (depth === 0) break; }
        }
        return src.slice(start, i + 1);
    };
    // eslint-disable-next-line no-new-func
    const factory = new Function(`return { ${grab('_pqBadgeState')}, ${grab('_pqBadgeSpan')} };`);
    Object.assign(M, factory());

    // Every case carries isPM/isGroup, because whether the message is
    // ENCRYPTED at all decides whether a shield belongs on it. The earlier
    // version of these tests passed bare {pqEncrypted:...} objects, so it
    // agreed with any answer the public-message branch happened to give.
    const pm = (m) => ({ isPM: true, ...m });
    const group = (m) => ({ isGroup: true, ...m });

    chk('a classical PM says so rather than showing nothing',
        M._pqBadgeState(pm({ pqEncrypted: false })) === 'classical');
    chk('a post-quantum PM shows the full shield',
        M._pqBadgeState(pm({ pqEncrypted: true })) === 'full');
    chk('a fully covered group shows the full shield',
        M._pqBadgeState(group({ pqCoverage: { pq: 10, total: 10 } })) === 'full');
    chk('a partly covered group shows the PARTIAL shield, not the full one',
        M._pqBadgeState(group({ pqCoverage: { pq: 8, total: 10 } })) === 'partial');
    chk('a group no member could receive post-quantum says classical',
        M._pqBadgeState(group({ pqCoverage: { pq: 0, total: 10 } })) === 'classical');
    chk('coverage overrides an optimistic pqEncrypted flag',
        M._pqBadgeState(group({ pqEncrypted: true, pqCoverage: { pq: 8, total: 10 } })) === 'partial');

    // A public channel message is plaintext on the relay. A shield of any
    // kind would imply an encryption it does not have.
    chk('a public message shows no shield at all',
        M._pqBadgeState({ pqEncrypted: false }) === '');
    chk('...not even one claiming to be classical',
        M._pqBadgeState({ pqCoverage: { pq: 0, total: 10 } }) === '');
    chk('a null message is handled', M._pqBadgeState(null) === '');

    chk('no markup when there is no state', M._pqBadgeSpan('', 'x') === '');
    const full = M._pqBadgeSpan('full', 'crypto-lock-irc');
    const part = M._pqBadgeSpan('partial', 'crypto-lock-irc');
    const clas = M._pqBadgeSpan('classical', 'crypto-lock-irc');
    chk('the shield is its own badge, not part of the verification lock',
        full.includes('crypto-pq-badge') && !full.includes('crypto-verified-badge'));
    chk('the badge is tappable for details', full.includes('data-action="showPqInfo"'));
    chk('partial is visually distinct', part.includes('partial') && !full.includes(' partial'));
    chk('classical is visually distinct from both',
        clas.includes('classical') && !full.includes(' classical') && !part.includes(' classical'));
    chk('all three are tappable', clas.includes('data-action="showPqInfo"')
        && part.includes('data-action="showPqInfo"'));
    chk('titles do not overstate partial coverage',
        part.includes('Partly quantum-resistant') && full.includes('Quantum-resistant encryption'));
    chk('the classical title says plainly that it is not',
        clas.includes('Not quantum-resistant'));
    // The orbit inside the shield IS the post-quantum part, so the classical
    // badge must not carry one — the states have to be told apart at 12px.
    chk('classical drops the orbit and takes a slash',
        !clas.includes('<ellipse') && clas.includes('<line'));
    chk('the protected states keep the orbit',
        full.includes('<ellipse') && part.includes('<ellipse'));
    chk('the glyph is language-neutral (no letterforms)',
        !/>[A-Za-z]</.test(full) && !/>[A-Za-z]</.test(clas));
    chk('the badge carries its layout class', full.includes('crypto-lock-irc')
        && clas.includes('crypto-lock-irc'));
}

// ------------------------------------------------- announcement is published
// Two defects, each of which alone made every message classical on both ends
// while everything downstream looked healthy. Neither was catchable from the
// crypto or the discovery code: the key was simply never anywhere to be found.
section('announcement reaches peers');
{
    const relaysSrc = fs.readFileSync(path.join(root, 'js/modules/relays.js'), 'utf8');
    const pmsSrc = fs.readFileSync(path.join(root, 'js/modules/pms.js'), 'utf8');

    // Defect 1: publishing hung off retryPendingDMsOnReconnect, and every one
    // of that function's call sites is a RE-connect. A client that logged in
    // and stayed connected never announced, so a brand new account could not
    // be found by anyone however well discovery worked.
    const connectFn = relaysSrc.slice(
        relaysSrc.indexOf('async connectToRelays()'),
        relaysSrc.indexOf('async connectToRelays()') + 20000);
    const announcesOnConnect =
        (connectFn.match(/schedulePqAnnouncement\(\)/g) || []).length;
    chk('the FIRST connect announces, not only reconnects', announcesOnConnect >= 2);
    chk('the reconnect path announces too',
        pmsSrc.includes('schedulePqAnnouncement()'));
    chk('publishing is not reachable ONLY from a reconnect handler',
        !/retryPendingDMsOnReconnect[\s\S]{0,2000}publishPqAnnouncement\(\)/.test(pmsSrc));

    // Defect 2: the worker archived nym-pq on the INBOUND path only, so
    // publishing wrote nothing to D1 — leaving the archive empty exactly in
    // the window right after a publish, when a peer is most likely to look up.
    const workerSrc = fs.readFileSync(path.join(root, 'functions/api/relay-pool.js'), 'utf8');
    const outFn = workerSrc.slice(
        workerSrc.indexOf('function archiveOutgoingEvent('),
        workerSrc.indexOf('function archiveEventValid('));
    const inFn = workerSrc.slice(
        workerSrc.indexOf('function archiveInboundEvent('),
        workerSrc.indexOf('function deleteArchivedFromDeletion('));
    chk('publishing an announcement archives it to D1', outFn.includes("'nym-pq'"));
    chk('receiving one archives it too', inFn.includes("'nym-pq'"));
    // The two allowlists drifting apart IS the bug, so hold them together.
    const tagsOf = (src) => (src.match(/t !== '([a-z-]+)'/g) || []).sort().join(',');
    chk('the inbound and outbound allowlists stay identical',
        tagsOf(outFn) === tagsOf(inFn) && tagsOf(outFn).length > 0);
}

// ------------------------------------------------ self-addressed copies
// Settings, the archive and self-wraps are sealed to OUR OWN key. Getting that
// key from the wrong place is silent and permanent: the blob is simply
// unreadable ever after, and a client that cannot read its settings falls back
// to defaults and then saves those over the rows it could not open.
section('the key we seal our own copies to');
{
    const relaysSrc = fs.readFileSync(path.join(root, 'js/modules/relays.js'), 'utf8');
    const pqSrc = fs.readFileSync(path.join(root, 'js/modules/pq.js'), 'utf8');
    const settingsSrc = fs.readFileSync(path.join(root, 'js/modules/settings.js'), 'utf8');

    const selfFn = pqSrc.slice(pqSrc.indexOf('pqSelfKeyFor() {'),
        pqSrc.indexOf('pqSelfKeyFor() {') + 1200);
    chk('it is DERIVED from our own epoch, not read from the registry',
        selfFn.includes('this.pqSelfKeys()') && !/return this\.pqKeyFor\(this\.pubkey\)/.test(selfFn));
    chk('and still refuses when we cannot decapsulate',
        selfFn.includes('if (!this.pqSelfEnabled()) return null;'));

    // Deriving is what guarantees encrypt and decrypt agree: pqSelfKeys() IS
    // the first entry pqSelfCandidates() walks.
    const app = new NYM();
    app.privkey = bobSk;
    app.pubkey = bobPk;
    app.pqKeys = new Map();
    app._persistDedupSets = () => { };
    const sealTo = app.pqSelfKeyFor();
    chk('a self key exists before any announcement has been published', !!sealTo);
    const cands = app.pqUnwrapCandidates([app.privkey]);
    chk('the key we seal to is one we hold the secret half of',
        cands.some(c => c.kemPk && eq(c.kemPk, sealTo)));

    // The case that broke settings: another device on this nsec announced a
    // key from an epoch this device has never held.
    const foreign = NC.pqKeypairFromPrivkey(bobSk, 9);
    app._pqRecord(app.pubkey, foreign.publicKey, Math.floor(Date.now() / 1000) + 604800, 9);
    const afterForeign = app.pqSelfKeyFor();
    chk("another device's announced epoch cannot hijack our own seal key",
        eq(afterForeign, sealTo) && !eq(afterForeign, foreign.publicKey));

    // Settings must never be written over rows we could not read.
    chk('an unreadable restore disables saving rather than overwriting',
        settingsSrc.includes('_settingsRestoreUnreadable'));
    chk('the D1 write honours it too',
        /_saveSettingsBlobToD1[\s\S]{0,400}_settingsRestoreUnreadable/.test(settingsSrc));

    // Under D1 every filter is a live tail; history comes from the archive.
    const pqStart = relaysSrc.indexOf('if (this.pubkey && typeof this.pqEnabled');
    const pqFilter = relaysSrc.slice(pqStart, pqStart + 2200);
    chk('the announcement filter is a live tail under D1, not a backfill',
        /d1Available[\s\S]{0,400}since: nowSec, limit: 1/.test(pqFilter));
    chk('and still backfills by author in direct mode',
        /else[\s\S]{0,300}authors,[\s\S]{0,80}limit: authors\.length/.test(pqFilter));
}

// ------------------------------------------------ live badge updates
// A group's coverage is only known after the fan-out, and a PM's hybrid copy
// can arrive after its classical one — so the shield has to update in place,
// the way the verification lock already does.
section('the shield updates in place');
{
    const messagesSrc = fs.readFileSync(path.join(root, 'js/modules/messages.js'), 'utf8');
    const pmsSrc = fs.readFileSync(path.join(root, 'js/modules/pms.js'), 'utf8');
    const groupsSrc = fs.readFileSync(path.join(root, 'js/modules/groups.js'), 'utf8');

    const refresh = messagesSrc.slice(
        messagesSrc.indexOf('refreshMessagePqBadge(nymMessageId) {'),
        messagesSrc.indexOf('refreshMessagePqBadge(nymMessageId) {') + 1400);
    // _findMessageById returns { msg, convKey, store }. Handing the wrapper to
    // _pqBadgeState read isPM/isGroup/pqCoverage off an object with none of
    // them, so it answered '' and the badge was DELETED instead of updated.
    chk('the lookup wrapper is unwrapped before the state is read',
        /_pqBadgeState\(found && found\.msg\)/.test(refresh));
    chk('and never passes the wrapper straight in',
        !/_pqBadgeState\(\s*this\._findMessageById/.test(refresh));

    // The popup reads the same lookup and made the same mistake.
    const popup = messagesSrc.slice(
        messagesSrc.indexOf("title = 'Partly quantum-resistant'") - 700,
        messagesSrc.indexOf("title = 'Partly quantum-resistant'"));
    chk('the badge popup unwraps it too', /hit && hit\.msg/.test(popup));

    // Parity with the lock: both dedup paths already flip the lock in place.
    chk('a PM upgraded to post-quantum refreshes its shield',
        /isPqWrap && !dupMsg\.pqEncrypted[\s\S]{0,400}refreshMessagePqBadge/.test(pmsSrc));
    chk('a group message does too',
        /isPqWrap && !dupGroupMsg\.pqEncrypted[\s\S]{0,400}refreshMessagePqBadge/.test(groupsSrc));
    chk('and the group send refreshes once coverage is known',
        /pqGroupCoverageFor\(nymMessageId\)[\s\S]{0,500}refreshMessagePqBadge/.test(groupsSrc));
}

// ------------------------------------------------------ settings durability
// "Change a setting, reload, it reverts" had three independent causes, all of
// them silent. Each is a data-loss bug: the user's change is simply gone.
section('a saved setting stays saved');
{
    const settingsSrc = fs.readFileSync(path.join(root, 'js/modules/settings.js'), 'utf8');
    const dartSrc = fs.readFileSync(
        '/home/user/flutter-app/lib/services/api/storage_sync.dart', 'utf8');

    // 1. The section was marked published BEFORE the write, and never rolled
    //    back — so a failed write counted as done and every later save in the
    //    session short-circuited on it, never retrying.
    const gate = settingsSrc.slice(
        settingsSrc.indexOf('async _publishCategoryWrap('),
        settingsSrc.indexOf('async _publishEncryptedSettings('));
    chk('a section is marked published only after the write succeeds',
        /const ok = await this\._publishWrappedNostrEvent[\s\S]{0,200}if \(!ok\)/.test(gate));
    chk('and a failed write leaves it dirty so the next save retries',
        /delete this\._publishedSectionJson\[dTag\]/.test(gate));

    // 2. The publish has to REPORT whether it landed, and "landed" means the
    //    source the restore reads back from — D1 under the proxy pool.
    chk('the publisher reports durability', /const durable = \(\) =>/.test(settingsSrc));
    chk('and the D1 write is awaited rather than fire-and-forget',
        /d1Ok = await this\._saveSettingsBlobToD1/.test(settingsSrc));

    // 3. A write replaces the whole category, so keys the OTHER client owns
    //    have to be carried forward or they are deleted.
    chk('unknown keys are carried forward on write (PWA)',
        settingsSrc.includes('_mergeUnknownSectionKeys'));
    chk('unknown keys are carried forward on write (Flutter)',
        dartSrc.includes('_mergeUnknownSectionKeys'));
    chk('and the inbound payload is stashed to carry them from',
        /_lastInboundSections\[realCat\]/.test(settingsSrc));

    // The two clients must file the same key in the same category, or the same
    // setting lives in two rows and whichever was written last wins.
    const secMap = (src, start) => {
        const block = src.slice(start, src.indexOf('};', start));
        const out = {};
        for (const m of block.matchAll(/'?([\w-]+)'?\s*:\s*\[([^\]]*)\]/g)) {
            out[m[1]] = [...m[2].matchAll(/'([\w-]+)'/g)].map(x => x[1]);
        }
        return out;
    };
    const appSrc = fs.readFileSync(path.join(root, 'js/app.js'), 'utf8');
    const pwaMap = secMap(appSrc, appSrc.indexOf('NYM_SETTINGS_SECTION_KEYS'));
    const dartMap = secMap(dartSrc, dartSrc.indexOf('syncedSectionKeys = {'));
    const drift = [];
    for (const [sec, keys] of Object.entries(pwaMap)) {
        for (const k of keys) {
            for (const [ds, dk] of Object.entries(dartMap)) {
                if (dk.includes(k) && ds !== sec) drift.push(`${k}: ${sec} vs ${ds}`);
            }
        }
    }
    chk('the two clients file every key in the same section', drift.length === 0, drift.join('; '));
    const allDart = new Set(Object.values(dartMap).flat());
    const unmapped = Object.values(pwaMap).flat().filter(k => !allDart.has(k));
    chk('and Flutter knows every section key the PWA does', unmapped.length === 0,
        unmapped.join(', '));
}

// -------------------------------------------- what each login type gets
// An extension or remote signer holds the nsec and will not do ML-KEM, so it
// cannot derive the secret half and cannot decapsulate. Its self-addressed
// copies -- settings, the archive -- MUST stay classical NIP-44, or they become
// permanently unreadable to the device that wrote them.
section('extension and remote-signer logins stay classical');
{
    const settingsSrc = fs.readFileSync(path.join(root, 'js/modules/settings.js'), 'utf8');
    const dartSync = fs.readFileSync(
        '/home/user/flutter-app/lib/services/api/storage_sync.dart', 'utf8');

    const withKey = (privkey) => {
        const a = new NYM();
        a.pubkey = bobPk;
        a.privkey = privkey;
        a.pqKeys = new Map();
        a._persistDedupSets = () => { };
        // The tempting case: ANOTHER device on this nsec announced a key.
        a._pqRecord(bobPk, NC.pqKeypairFromPrivkey(bobSk, 0).publicKey,
            Math.floor(Date.now() / 1000) + 604800, 0);
        return a;
    };
    const local = withKey(bobSk);
    const remote = withKey(null);

    chk('a local key can receive post-quantum', local.pqCapable() === true);
    chk('a signer login cannot', remote.pqCapable() === false);
    chk('a local key seals its own copies post-quantum', !!local.pqSelfKeyFor());
    chk('a signer login gets NO self key, even with one announced for this npub',
        remote.pqSelfKeyFor() === null);

    // Sending is the weaker requirement and stays available to both: only the
    // seal needs the signer, and the recipient is the one who decapsulates.
    chk('both can still SEND post-quantum to peers',
        local.pqSendCapable() === true && remote.pqSendCapable() === true);

    // The encrypt paths must be gated on holding the key, not on the policy
    // flag alone.
    chk('the PWA settings blob only goes hybrid with a local key',
        /if \(this\.privkey\) \{[\s\S]{0,300}pqSelfKeyFor/.test(settingsSrc));
    chk('and the gift wrap does too',
        /if \(this\.privkey\) \{[\s\S]{0,2000}const selfKemPk/.test(settingsSrc));
    chk('Flutter gates on the signer being a local key',
        /signer is LocalSigner && selfKem != null/.test(dartSync));
    chk('and otherwise falls through to NIP-44',
        /return await signer\.nip44Encrypt\(_pubkey, plaintext\)/.test(dartSync));

    // Reading must accept both shapes forever: a blob written before this
    // device had a key, or by a signer login, is plain NIP-44.
    chk('the reader dispatches on the payload, not the login type',
        /isPqPayload\(ciphertext\)/.test(settingsSrc));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
