import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  clampReaderPage,
  filterAndSortHighlights,
  resolveInitialReferenceViewMode,
  sortHighlights,
} from '../src/features/reader/highlightsList.ts';
import type { Highlight } from '../src/types/api.ts';

function makeHighlight(overrides: Partial<Highlight> & { id: string }): Highlight {
  return {
    page: 1,
    lang: 'en',
    color: '#fde68a',
    text: 'sample text',
    startOffset: 0,
    endOffset: 11,
    paragraphIndex: 0,
    note: '',
    createdAt: 1000,
    ...overrides,
  };
}

describe('highlightsList helpers', () => {
  it('sorts highlights by page ascending then createdAt', () => {
    const items = [
      makeHighlight({ id: 'c', page: 50, createdAt: 200 }),
      makeHighlight({ id: 'a', page: 12, createdAt: 500 }),
      makeHighlight({ id: 'b', page: 50, createdAt: 100 }),
    ];

    const sorted = sortHighlights(items).map((h) => h.id);
    assert.deepEqual(sorted, ['a', 'b', 'c']);
  });

  it('filters to current page only when enabled without mutating original array', () => {
    const items = [
      makeHighlight({ id: 'h1', page: 50 }),
      makeHighlight({ id: 'h2', page: 119 }),
      makeHighlight({ id: 'h3', page: 50 }),
    ];

    const only119 = filterAndSortHighlights(items, { currentPage: 119, onlyCurrentPage: true });
    assert.deepEqual(
      only119.map((h) => h.id),
      ['h2'],
    );
    assert.equal(items.length, 3);
  });

  it('clamps preview page cleanly between 1 and pageCount', () => {
    assert.equal(clampReaderPage(50, 200), 50);
    assert.equal(clampReaderPage(0, 200), 1);
    assert.equal(clampReaderPage(999, 200), 200);
    assert.equal(clampReaderPage(Number.NaN, 200), 1);
  });

  it('keeps split view mode when main reader is split, otherwise uses highlight language', () => {
    assert.equal(resolveInitialReferenceViewMode('split', 'vi'), 'split');
    assert.equal(resolveInitialReferenceViewMode('en', 'vi'), 'vi');
    assert.equal(resolveInitialReferenceViewMode('vi', 'en'), 'en');
  });
});

