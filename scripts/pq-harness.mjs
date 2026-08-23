// Shared loader for the PQ scripts: evaluates the shipped browser bundles
// (nostr-tools, vendored ML-KEM, nym-crypto) in THIS realm so the exact bytes
// users run are what the vectors and tests exercise.
//
// Single realm matters: noble's primitives use `instanceof Uint8Array`, which
// fails across vm contexts.
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function loadNym() {
    globalThis.btoa = (b) => Buffer.from(b, 'binary').toString('base64');
    globalThis.atob = (a) => Buffer.from(a, 'base64').toString('binary');
    globalThis.self = globalThis;
    for (const rel of ['js/nostr-tools.js', 'js/vendor/ml-kem.js', 'js/nym-crypto.js']) {
        vm.runInThisContext(fs.readFileSync(path.join(root, rel), 'utf8'), { filename: rel });
    }
    return { NostrTools: globalThis.NostrTools, NymCrypto: globalThis.NymCrypto };
}

export const hex = (b) => Buffer.from(b).toString('hex');
export const unhex = (h) => new Uint8Array(Buffer.from(h, 'hex'));
