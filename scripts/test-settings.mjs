// Settings durability tests.
//
// The bug these cover: "the load failed" and "the account has nothing stored"
// were the same answer, so a settings-get that never landed left the session
// running on defaults and the next save wrote those defaults over the rows it
// had failed to read. Every device then read the defaults back, and the user's
// settings were gone for good.
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { loadNym, root } from './pq-harness.mjs';

const { NostrTools } = loadNym();

const store = new Map();
globalThis.localStorage = {
    getItem: k => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: k => store.delete(k),
};
globalThis.window = globalThis;
function NYM() { }
globalThis.NYM = NYM;
for (const rel of ['js/modules/pq.js', 'js/modules/settings.js']) {
    vm.runInThisContext(fs.readFileSync(path.join(root, rel), 'utf8'), { filename: rel });
}
globalThis.isNostrLoggedIn = () => false;
globalThis.applyNostrSettings = async () => { };
globalThis.applyNostrSettingsAdditive = async () => { };

const CAT = 'nymchat-settings-appearance';
const sk = NostrTools.generateSecretKey();
const pk = NostrTools.getPublicKey(sk);

let D1 = new Map();
function client({ getThrows = false, privkey = sk, pubkey = pk } = {}) {
    const n = new NYM();
    n.privkey = privkey;
    n.pubkey = pubkey;
    n.pqKeys = new Map();
    n.useRelayProxy = true;
    n._getApiHost = () => 'https://storage.invalid';
    n._d1Category = async (dTag) => dTag;
    n._storageApiRequest = async (op, body) => {
        if (op === 'settings-get') {
            if (getThrows) throw new Error('network');
            const categories = {};
            for (const [k, v] of D1) categories[k] = { blob: v, updatedAt: 1 };
            return { categories };
        }
        if (op === 'settings-set') { D1.set(body.category, body.blob); return { ok: true }; }
        return {};
    };
    return n;
}

let failed = 0;
// _saveSettingsBlobToD1 embeds the real category inside the blob, so the
// cleartext D1 column can be an opaque hash. Reads come back with it.
const withCat = (json, cat = CAT) => JSON.stringify({ ...JSON.parse(json), __cat: cat });

const eq = (name, got, want) => {
    const ok = got === want;
    if (!ok) failed++;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : ` — got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

// A settings-get that never answered must not be mistaken for an empty account,
// and must never let this session's defaults overwrite the stored rows.
{
    D1 = new Map(); store.clear();
    const writer = client();
    const real = JSON.stringify({ v: 2, theme: 'midnight', textSize: 'large' });
    await writer._saveSettingsBlobToD1(CAT, real);

    store.clear(); // a different device: no local content-hash record
    const boot = client({ getThrows: true });
    eq('failed read reports failure', await boot.settingsLoadFromD1(), 'failed');

    // settingsLoad() blocks saving for the session once its retries run out.
    boot._settingsRestoreUnreadable = true;
    await boot._saveSettingsBlobToD1(CAT, JSON.stringify({ v: 2, theme: 'dark' }));
    eq('stored settings survive a failed read', await writer._decryptSettingsBlob(D1.get(CAT)), withCat(real));
}

// A genuinely empty account is not a failure — a fresh device has to be able to
// save, or its first change is lost on reload.
{
    D1 = new Map(); store.clear();
    const n = client();
    eq('empty account reports empty', await n.settingsLoadFromD1(), 'empty');
    eq('empty account may save', !!n._settingsRestoreUnreadable, false);
    const want = JSON.stringify({ v: 2, theme: 'amber' });
    await n._saveSettingsBlobToD1(CAT, want);
    eq('fresh save lands', await n._decryptSettingsBlob(D1.get(CAT)), withCat(want));
}

// Rows sealed to a key this identity cannot derive are dead, not precious.
// Refusing to overwrite them strands the account forever.
{
    D1 = new Map(); store.clear();
    const foreignSk = NostrTools.generateSecretKey();
    const foreign = client({ privkey: foreignSk, pubkey: NostrTools.getPublicKey(foreignSk) });
    await foreign._saveSettingsBlobToD1(CAT, JSON.stringify({ v: 2, theme: 'ghost' }));
    store.clear();

    const n = client();
    eq('unopenable rows report empty', await n.settingsLoadFromD1(), 'empty');
    eq('unopenable rows do not block saving', !!n._settingsRestoreUnreadable, false);
    const want = JSON.stringify({ v: 2, theme: 'matrix' });
    await n._saveSettingsBlobToD1(CAT, want);
    eq('account recovers on the next save', await n._decryptSettingsBlob(D1.get(CAT)), withCat(want));
}

// ...but under a signer we do not control, the same symptom is transient — a
// locked or slow signer looks identical — so those rows stay untouched.
{
    D1 = new Map(); store.clear();
    const foreignSk = NostrTools.generateSecretKey();
    const foreign = client({ privkey: foreignSk, pubkey: NostrTools.getPublicKey(foreignSk) });
    await foreign._saveSettingsBlobToD1(CAT, JSON.stringify({ v: 2, theme: 'ghost' }));
    const before = D1.get(CAT);
    store.clear();

    const n = client({ privkey: null });
    eq('signer login reports failure', await n.settingsLoadFromD1(), 'failed');
    eq('signer login blocks saving', !!n._settingsRestoreUnreadable, true);
    await n._saveSettingsBlobToD1(CAT, JSON.stringify({ v: 2, theme: 'matrix' }));
    eq('signer login leaves rows intact', D1.get(CAT), before);
}

// The block is for as long as the condition lasts, not for the session. It used
// to latch permanently, so one transient failure disabled saving until reload.
{
    D1 = new Map(); store.clear();
    const n = client();
    n._settingsRestoreUnreadable = true;
    await n._saveSettingsBlobToD1(CAT, JSON.stringify({ v: 2, theme: 'x' }));
    eq('blocked session writes nothing', D1.size, 0);
    await n.settingsLoadFromD1();
    eq('a successful load clears the block', !!n._settingsRestoreUnreadable, false);
    await n._saveSettingsBlobToD1(CAT, JSON.stringify({ v: 2, theme: 'x' }));
    eq('saving resumes', D1.size, 1);
}

// The orchestration in app.js is where the loss actually happened: it armed the
// 10s hydration net on EVERY outcome, so a load that never answered declared
// the session's defaults loaded and the next save wrote them over D1.
{
    const appJs = fs.readFileSync(path.join(root, 'js/app.js'), 'utf8');
    const m = appJs.match(/const SETTINGS_LOAD_MAX_RETRIES[\s\S]*?\nasync function settingsLoad[\s\S]*?\n}\n/)
        || appJs.match(/\nasync function settingsLoad[\s\S]*?\n}\n/);
    if (!m) {
        console.log('FAIL could not extract settingsLoad from app.js');
        failed++;
    } else {
        D1 = new Map(); store.clear();
        const writer = client();
        const real = JSON.stringify({ v: 2, theme: 'midnight', textSize: 'large' });
        await writer._saveSettingsBlobToD1(CAT, real);
        store.clear();

        globalThis.nym = client({ getThrows: true });
        globalThis.nostrSettingsLoad = () => { };
        // Run the retries back-to-back rather than over ~30s of real time.
        const realSetTimeout = globalThis.setTimeout;
        globalThis.setTimeout = (fn, _ms) => realSetTimeout(fn, 0);
        const settingsLoad = vm.runInThisContext(`(() => { ${m[0]}; return settingsLoad; })()`,
            { filename: 'app.js#settingsLoad' });

        await settingsLoad();
        await new Promise(r => realSetTimeout(r, 200));
        globalThis.setTimeout = realSetTimeout;

        eq('a load that never answers does not hydrate', !!globalThis.nym._settingsHydrated, false);
        eq('a load that never answers blocks saving', !!globalThis.nym._settingsRestoreUnreadable, true);

        await globalThis.nym._saveSettingsBlobToD1(CAT, JSON.stringify({ v: 2, theme: 'dark' }));
        eq('boot with no answer leaves D1 intact',
            await writer._decryptSettingsBlob(D1.get(CAT)), withCat(real));
    }
}

console.log(failed ? `\n${failed} failing` : '\nall settings tests passed');
process.exit(failed ? 1 : 0);
