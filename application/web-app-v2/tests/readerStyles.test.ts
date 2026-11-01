import test from 'node:test';
import assert from 'node:assert/strict';

import {
  applyBookAppearance,
  doesDocOverflowA4,
  resolveBookBackground,
} from '../src/features/reader/iframe/readerStyles.ts';

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

test('doesDocOverflowA4 detects when prose scrollHeight exceeds A4 sheet clientHeight', () => {
  const overflowingFlow = {
    scrollHeight: 1180,
    clientHeight: 1122,
    getBoundingClientRect: () => ({ top: 0, bottom: 1122, height: 1122, width: 794 }),
    querySelectorAll: () => [],
  };
  const fittingFlow = {
    scrollHeight: 1122,
    clientHeight: 1122,
    getBoundingClientRect: () => ({ top: 0, bottom: 1122, height: 1122, width: 794 }),
    querySelectorAll: () => [],
  };

  const docOverflow = {
    body: overflowingFlow,
    querySelector: () => overflowingFlow,
  } as unknown as Document;

  const docFit = {
    body: fittingFlow,
    querySelector: () => fittingFlow,
  } as unknown as Document;

  assert.equal(doesDocOverflowA4(docOverflow), true);
  assert.equal(doesDocOverflowA4(docFit), false);
});

test('applyBookAppearance skips +5% overflow probe unless measureMaxScale is true', () => {
  let styleWriteCount = 0;
  let currentCss = '';
  const elementsById = new Map<string, { id: string; textContent: string; remove: () => void }>();

  const head = {
    appendChild: (el: { id: string; textContent: string; remove: () => void }) => {
      elementsById.set(el.id, el);
    },
  };

  // Overflows only when scale reaches 105% (i.e. 1.050 ratio in CSS)
  const flowEl = {
    get scrollHeight() {
      return currentCss.includes('1.050') ? 1180 : 1122;
    },
    clientHeight: 1122,
    getBoundingClientRect: () => ({ top: 0, bottom: 1122, height: 1122, width: 794 }),
    querySelectorAll: () => [],
  };

  const doc = {
    head,
    body: flowEl,
    documentElement: head,
    getElementById: (id: string) => elementsById.get(id) ?? null,
    createElement: () => {
      const el = {
        id: '',
        get textContent() {
          return currentCss;
        },
        set textContent(val: string) {
          styleWriteCount++;
          currentCss = val;
        },
        remove() {
          elementsById.delete(el.id);
          currentCss = '';
        },
      };
      return el;
    },
    querySelector: () => flowEl,
    defaultView: {
      getComputedStyle: () => ({ backgroundColor: 'rgb(255, 253, 248)' }),
    },
  } as unknown as Document;

  // Normal page turn (measureMaxScale omitted): no +5% probe reflow
  const normalRes = applyBookAppearance(doc, null, {
    fontId: 'default',
    themeId: 'paper-sepia',
  });
  assert.equal(normalRes.atMaxA4Scale, false);
  assert.equal(styleWriteCount, 1);

  // Appearance popover open (measureMaxScale: true): runs +5% probe and restores CSS
  styleWriteCount = 0;
  const probedRes = applyBookAppearance(doc, null, {
    fontId: 'default',
    themeId: 'paper-sepia',
    measureMaxScale: true,
  });
  assert.equal(probedRes.atMaxA4Scale, true);
  assert.equal(styleWriteCount, 3);
});
