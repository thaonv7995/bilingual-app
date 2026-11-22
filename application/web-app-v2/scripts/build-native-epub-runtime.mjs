import { build } from 'esbuild';
import { copyFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(__dirname, '..');
const entry = resolve(webRoot, 'epub-native/bridge.js');
const htmlSrc = resolve(webRoot, 'epub-native/epub-reader.html');

const targets = [
  resolve(webRoot, '../mobile_macos/Resources/EpubReader'),
  resolve(webRoot, '../mobile_ios/Resources/EpubReader'),
];

for (const outDir of targets) {
  mkdirSync(outDir, { recursive: true });
}

const primaryOut = resolve(targets[0], 'epub-native-runtime.js');

await build({
  entryPoints: [entry],
  bundle: true,
  format: 'iife',
  target: ['safari16'],
  minify: true,
  outfile: primaryOut,
  define: {
    'process.env.NODE_ENV': '"production"',
  },
});

for (const outDir of targets) {
  if (outDir !== targets[0]) {
    copyFileSync(primaryOut, resolve(outDir, 'epub-native-runtime.js'));
  }
  copyFileSync(htmlSrc, resolve(outDir, 'epub-reader.html'));
}

console.log('Built offline EPUB native runtime for macOS & iOS:', targets);
