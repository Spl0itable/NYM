// Regenerates js/vendor/ml-kem.js from @noble/post-quantum.

import { build } from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const entry = path.join(root, 'scripts', '.mlkem-entry.mjs');
const out = path.join(root, 'js', 'vendor', 'ml-kem.js');

await fs.writeFile(entry,
    "export { ml_kem768 } from '@noble/post-quantum/ml-kem.js';\n");

try {
    const res = await build({
        entryPoints: [entry],
        bundle: true,
        minify: true,
        format: 'iife',
        globalName: 'NymMlKem',
        legalComments: 'none',
        target: 'es2020',
        write: false,
    });

    const pkg = JSON.parse(await fs.readFile(
        path.join(root, 'node_modules', '@noble', 'post-quantum', 'package.json'), 'utf8'));

    const header =
        '// ml-kem.js — ML-KEM-768 (FIPS 203) for Nymchat hybrid post-quantum key agreement.\n' +
        `// Bundled from @noble/post-quantum v${pkg.version} (${pkg.license}, Paul Miller) via esbuild.\n` +
        '// Exposes: NymMlKem.ml_kem768 { keygen(seed?), encapsulate(pk), decapsulate(ct, sk) }.\n' +
        '// Sizes: pk 1184B, sk 2400B, ciphertext 1088B, shared secret 32B.\n' +
        '// Regenerate with scripts/build-mlkem.mjs — do not hand-edit.\n';

    await fs.writeFile(out, header + res.outputFiles[0].text);
    const bytes = (await fs.stat(out)).size;
    console.log(`wrote ${path.relative(root, out)} (${bytes} bytes) from @noble/post-quantum v${pkg.version}`);
} finally {
    await fs.rm(entry, { force: true });
}
