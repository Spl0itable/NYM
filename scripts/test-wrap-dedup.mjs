// Gift-wrap decrypt dedup.
//
// A wrap that arrived over a relay comes down again in the D1 archive, and the
// archive replay is deliberately exempt from processedPMEventIds — that set
// persists across sessions, so honouring it would restore no backlog at all on
// a fresh boot. The cost was re-running the unwrap (an ML-KEM decapsulation and
// a NIP-44 decrypt) to arrive at bytes already in memory.
//
// The session-scoped set fixes that without touching the boot case, which is
// what these check: skipped within a session, still restored on a fresh one.
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { loadNym, root } from './pq-harness.mjs';

const { NostrTools, NymCrypto } = loadNym();
const store = new Map();
globalThis.localStorage = {
    getItem: k => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k),
};
globalThis.window = globalThis;
function NYM() {}
globalThis.NYM = NYM;
for (const rel of ['js/modules/pq.js', 'js/modules/pms.js'])
    vm.runInThisContext(fs.readFileSync(path.join(root, rel), 'utf8'), { filename: rel });

const sk = NostrTools.generateSecretKey();
const pk = NostrTools.getPublicKey(sk);
const peerSk = NostrTools.generateSecretKey();
const peerPk = NostrTools.getPublicKey(peerSk);

// A real NIP-17 wrap addressed to us.
const rumor = { kind: 14, pubkey: peerPk, created_at: Math.floor(Date.now()/1000),
                tags: [['p', pk]], content: 'hello', id: 'r1' };
const ckSeal = NostrTools.nip44.getConversationKey(peerSk, pk);
const seal = NostrTools.finalizeEvent(
    { kind: 13, content: NostrTools.nip44.encrypt(JSON.stringify(rumor), ckSeal),
      created_at: rumor.created_at, tags: [] }, peerSk);
const ephSk = NostrTools.generateSecretKey();
const wrap = NostrTools.finalizeEvent(
    { kind: 1059, created_at: rumor.created_at, tags: [['p', pk]],
      content: NostrTools.nip44.encrypt(JSON.stringify(seal),
                 NostrTools.nip44.getConversationKey(ephSk, pk)) }, ephSk);

let unwraps = 0;
function session(persistedIds = []) {
    const n = new NYM();
    n.privkey = sk; n.pubkey = pk;
    n.pqKeys = new Map();
    n.processedPMEventIds = new Set(persistedIds);   // persistence.js restores these
    n._decryptedWrapIds = new Set();                  // session-scoped, never persisted
    n.lastPMSyncTime = 0;
    n._persistLastPMSyncTime = () => {};
    n.persistDedupSets = () => {};
    n._ephemeralCandidateSks = () => [];
    n._cryptoCall = async (_fn, args, fallback) => { unwraps++; return fallback(); };
    n._giftWrapIsForMe = (ev) => (ev.tags || []).some(t => t[0] === 'p' && t[1] === pk);
    // Stop after the unwrap — everything past it is UI/store wiring.
    n._archivePMEvent = () => {};
    return n;
}

// 1. Relay delivery, then the same wrap again from the D1 archive.
let n = session();
unwraps = 0;
await n.handleGiftWrapDM(wrap).catch(() => {});
const afterRelay = unwraps;
await n.handleGiftWrapDM(wrap, { fromD1: true }).catch(() => {});
let failed = 0;
const eq = (name, got, want) => {
    const ok = got === want;
    if (!ok) failed++;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : ` — got ${got}, want ${want}`}`);
};

eq('a relay delivery decrypts once', afterRelay, 1);
eq('the same wrap from the archive does not decrypt again', unwraps - afterRelay, 0);

// 2. A FRESH session whose persisted dedup set already holds the id must still
//    decrypt the archive copy, or the user boots with no backlog.
n = session([wrap.id]);
unwraps = 0;
await n.handleGiftWrapDM(wrap, { fromD1: true }).catch(() => {});
eq('a fresh boot still restores the archive', unwraps, 1);

// 3. ...and a relay redelivery in that fresh session is still deduped.
const before = unwraps;
await n.handleGiftWrapDM(wrap).catch(() => {});
eq('a relay redelivery after a restore is deduped', unwraps - before, 0);

console.log(failed ? `\n${failed} failing` : '\nall wrap dedup tests passed');
process.exit(failed ? 1 : 0);
