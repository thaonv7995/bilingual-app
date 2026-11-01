import test from 'node:test';
import assert from 'node:assert/strict';

import {
  allocateTargetToVisualLines,
  distributeWordsByWeights,
  type VisualLineDescriptor,
} from '../src/features/reader/iframe/interlinearDom.ts';
import {
  parseThemeDescriptor,
  serializeThemeDescriptor,
} from '../src/features/reader/readerAppearance.ts';

test('distributeWordsByWeights preserves all words in order across lines', () => {
  const words = ['Mỗi', 'buổi', 'sáng', 'trước', 'khi', 'thế', 'giới', 'ồn', 'ào'];
  const slices = distributeWordsByWeights(words, [10, 10, 10]);
  assert.equal(slices.length, 3);
  assert.equal(slices.join(' '), words.join(' '));
});

test('allocateTargetToVisualLines locks to sentence boundaries when sentence counts match', () => {
  // Paragraph with 2 sentences across 3 visual lines:
  // Line 0: first half of sentence 0 (weight 30)
  // Line 1: second half of sentence 0 (weight 20) + first half of sentence 1 (weight 20)
  // Line 2: second half of sentence 1 (weight 30)
  const lines: VisualLineDescriptor[] = [
    {
      tokens: [{ sentenceIndex: 0, weight: 30 }],
      totalWeight: 30,
    },
    {
      tokens: [
        { sentenceIndex: 0, weight: 20 },
        { sentenceIndex: 1, weight: 20 },
      ],
      totalWeight: 40,
    },
    {
      tokens: [{ sentenceIndex: 1, weight: 30 }],
      totalWeight: 30,
    },
  ];

  const targetSentences = [
    'Mỗi buổi sáng tâm trí bạn rất minh mẫn.',
    'Cách bạn dùng giờ đầu tiên quyết định cả ngày.',
  ];

  const allocated = allocateTargetToVisualLines(lines, targetSentences);
  assert.equal(allocated.length, 3);
  // Every word from both target sentences appears in order across the 3 lines
  assert.equal(allocated.join(' '), targetSentences.join(' '));
  // Line 0 only contains words from sentence 0, and Line 2 ends with sentence 1
  assert.ok(allocated[0]!.startsWith('Mỗi buổi sáng'));
  assert.ok(allocated[2]!.endsWith('quyết định cả ngày.'));
});

test('parseThemeDescriptor and serializeThemeDescriptor round-trip interlinear settings', () => {
  const raw = 'paper-sepia;scale=110;il=1;ilop=35';
  const parsed = parseThemeDescriptor(raw);
  assert.equal(parsed.themeId, 'paper-sepia');
  assert.equal(parsed.fontScale, 110);
  assert.equal(parsed.interlinear, true);
  assert.equal(parsed.interlinearOpacity, 35);

  const reserialized = serializeThemeDescriptor(parsed);
  assert.equal(reserialized, 'paper-sepia;scale=110;il=1;ilop=35');
});

