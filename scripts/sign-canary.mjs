import { readFileSync, writeFileSync } from 'fs';
import { finalizeEvent } from 'nostr-tools/pure';
import { SimplePool } from 'nostr-tools/pool';
import { nip19 } from 'nostr-tools';

const KIND = 30078;
const D_TAG = 'warrant-canary';
const DEFAULT_RELAYS = [
    'wss://sendit.nosflare.com',
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
    'wss://relay.snort.social',
];

function secretKey() {
    const k = process.env.NOSTR_NSEC;
    if (!k) throw new Error('Set NOSTR_NSEC to the operator nsec (or hex private key)');
    if (k.startsWith('nsec1')) {
        const { type, data } = nip19.decode(k);
        if (type !== 'nsec') throw new Error('NOSTR_NSEC is not a valid nsec');
        return data;
    }
    return Uint8Array.from(Buffer.from(k, 'hex'));
}

async function fetchTip(base) {
    const height = Number((await (await fetch(base + '/blocks/tip/height')).text()).trim());
    const hash = (await (await fetch(base + '/blocks/tip/hash')).text()).trim();
    if (!Number.isFinite(height) || !/^[0-9a-f]{64}$/.test(hash)) throw new Error('bad tip from ' + base);
    return { height, hash };
}

async function btcTip() {
    let err;
    for (const base of ['https://mempool.space/api', 'https://blockstream.info/api']) {
        try { return await fetchTip(base); } catch (e) { err = e; }
    }
    throw new Error('could not fetch BTC tip: ' + (err && err.message || err));
}

function isoInDays(days) {
    return new Date(Date.now() + days * 86400000).toISOString();
}

async function broadcast(event) {
    if (process.env.CANARY_NO_BROADCAST === '1') return;
    if (typeof WebSocket === 'undefined') throw new Error('no global WebSocket; use Node 20+ to broadcast');
    const relays = (process.env.CANARY_RELAYS || DEFAULT_RELAYS.join(',')).split(',').map((r) => r.trim()).filter(Boolean);
    const pool = new SimplePool();
    const withTimeout = (p) => {
        let t;
        return Promise.race([p, new Promise((_, rej) => { t = setTimeout(() => rej(new Error('timeout')), 8000); })])
            .finally(() => clearTimeout(t));
    };
    const results = await Promise.allSettled(pool.publish(relays, event).map(withTimeout));
    relays.forEach((r, i) => console.log((results[i].status === 'fulfilled' ? '  published ' : '  failed    ') + r));
    pool.close(relays);
}

async function main() {
    let base = {};
    try {
        const doc = JSON.parse(readFileSync('canary.json', 'utf8'));
        base = typeof doc.content === 'string' ? JSON.parse(doc.content) : doc;
    } catch (_) { }

    const interval = Number(process.env.CANARY_INTERVAL_DAYS || 90);
    const payload = {
        statement: process.env.CANARY_STATEMENT || base.statement || '',
        allClear: process.env.CANARY_ALLCLEAR ? process.env.CANARY_ALLCLEAR === 'true' : base.allClear !== false,
        updatedAt: new Date().toISOString(),
        nextUpdateBy: process.env.CANARY_NEXT || isoInDays(interval),
        signedBy: process.env.CANARY_SIGNEDBY || base.signedBy || '',
        btcBlock: await btcTip(),
    };

    const event = finalizeEvent({
        kind: KIND,
        created_at: Math.floor(Date.now() / 1000),
        tags: [['d', D_TAG]],
        content: JSON.stringify(payload),
    }, secretKey());

    writeFileSync('canary.json', JSON.stringify(event, null, 2) + '\n');
    const nevent = nip19.neventEncode({ id: event.id, author: event.pubkey, relays: DEFAULT_RELAYS.slice(0, 3) });
    console.log('Signed canary by ' + event.pubkey);
    console.log('Event id ' + event.id);
    console.log('Anchored to BTC block ' + payload.btcBlock.height);
    console.log('Next update by ' + payload.nextUpdateBy);
    console.log('View: https://njump.me/' + nevent);
    await broadcast(event);
}

main().then(() => process.exit(0)).catch((e) => { console.error(e.message || e); process.exit(1); });
