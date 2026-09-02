import test from 'node:test';
import assert from 'node:assert/strict';

import { resolveBookBackground } from '../src/features/reader/iframe/readerStyles.ts';

function fakeDocument(bodyColor: string, sheetColor: string, htmlColor = 'rgba(0, 0, 0, 0)'): Document {
  const body = {};
  const sheet = {};
  const html = {};
  const colors = new Map<object, string>([
    [body, bodyColor],
    [sheet, sheetColor],
    [html, htmlColor],
  ]);

  return {
    body,
    documentElement: html,
    querySelector: () => sheet,
    defaultView: {
      getComputedStyle: (element: object) => ({ backgroundColor: colors.get(element) ?? 'transparent' }),
    },
  } as unknown as Document;
}

test('BKB body paper color controls the iframe background', () => {
  const doc = fakeDocument('rgb(244, 241, 234)', 'rgb(255, 253, 248)');
  assert.equal(resolveBookBackground(doc), 'rgb(244, 241, 234)');
});

test('transparent body falls back to the BKB sheet color', () => {
  const doc = fakeDocument('rgba(0, 0, 0, 0)', 'rgb(255, 253, 248)');
  assert.equal(resolveBookBackground(doc), 'rgb(255, 253, 248)');
});

test('fully transparent BKB stays transparent instead of receiving a reader color', () => {
  const doc = fakeDocument('transparent', 'rgba(0, 0, 0, 0)');
  assert.equal(resolveBookBackground(doc), 'transparent');
});
