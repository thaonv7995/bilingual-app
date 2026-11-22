import test from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeClientRects,
  parseHighlightAnchor,
  resolveBookFormat,
  serializeHighlightAnchor,
} from '../src/features/reader/documentAnchors.ts';

test('PDF highlight anchor serializes and parses normalized rects cleanly', () => {
  const raw = serializeHighlightAnchor({
    kind: 'pdf',
    rects: [
      { x: 0.123456, y: 0.2, w: 0.5, h: 0.025 },
      { x: 0.1, y: 0.2, w: 0, h: 0.02 }, // zero-width dropped
    ],
    prefix: 'before text',
    suffix: 'after text',
  });
  const parsed = parseHighlightAnchor(raw);
  assert.ok(parsed && parsed.kind === 'pdf');
  assert.equal(parsed.rects.length, 1);
  assert.deepEqual(parsed.rects[0], { x: 0.1235, y: 0.2, w: 0.5, h: 0.025 });
  assert.equal(parsed.prefix, 'before text');
  assert.equal(parsed.suffix, 'after text');
});

test('EPUB highlight anchor round-trips CFI and chapter metadata', () => {
  const cfi = 'epubcfi(/6/8!/4/2/10,/1:5,/1:42)';
  const raw = serializeHighlightAnchor({
    kind: 'epub',
    cfi,
    chapterTitle: 'Chapter 3',
  });
  const parsed = parseHighlightAnchor(raw);
  assert.ok(parsed && parsed.kind === 'epub');
  assert.equal(parsed.cfi, cfi);
  assert.equal(parsed.chapterTitle, 'Chapter 3');
});

test('normalizeClientRects normalizes and merges adjacent same-line boxes', () => {
  const pageBox = { left: 100, top: 200, width: 500, height: 1000 };
  const rects = [
    { left: 150, top: 300, width: 100, height: 20 },
    { left: 252, top: 300, width: 80, height: 20 },
    { left: 150, top: 340, width: 200, height: 20 },
  ];
  const out = normalizeClientRects(rects, pageBox);
  assert.equal(out.length, 2);
  assert.deepEqual(out[0], { x: 0.1, y: 0.1, w: 0.364, h: 0.02 });
  assert.deepEqual(out[1], { x: 0.1, y: 0.14, w: 0.4, h: 0.02 });
});

test('resolveBookFormat defaults safely to bkb', () => {
  assert.equal(resolveBookFormat('pdf'), 'pdf');
  assert.equal(resolveBookFormat('epub'), 'epub');
  assert.equal(resolveBookFormat('bkb'), 'bkb');
  assert.equal(resolveBookFormat(undefined), 'bkb');
  assert.equal(resolveBookFormat('unknown'), 'bkb');
});
