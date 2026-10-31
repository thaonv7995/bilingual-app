import test from 'node:test';
import assert from 'node:assert/strict';

import {
  getReaderFont,
  parseThemeDescriptor,
  resolveEffectiveBookAppearance,
  serializeThemeDescriptor,
} from '../src/features/reader/readerAppearance.ts';

test('uses original book default ("default") when neither book default nor user override is set', () => {
  const res = resolveEffectiveBookAppearance({
    slug: 'animal-farm',
  });
  assert.equal(res.effectiveFontId, 'default');
  assert.equal(res.effectiveThemeId, 'default');
  assert.equal(res.hasUserFontOverride, false);
  assert.equal(res.hasUserThemeOverride, false);
});

test('uses per-book configured default when user has not overridden', () => {
  const res = resolveEffectiveBookAppearance({
    slug: 'animal-farm',
    defaultFont: 'literata',
    defaultTheme: 'paper-sepia',
    readerFont: '',
    readerTheme: '',
  });
  assert.equal(res.effectiveFontId, 'literata');
  assert.equal(res.effectiveThemeId, 'paper-sepia');
  assert.equal(res.bookDefaultFontId, 'literata');
  assert.equal(res.bookDefaultThemeId, 'paper-sepia');
  assert.equal(res.hasUserFontOverride, false);
  assert.equal(res.hasUserThemeOverride, false);
});

test('prioritizes user override while reading over book default', () => {
  const res = resolveEffectiveBookAppearance(
    {
      slug: 'animal-farm',
      defaultFont: 'literata',
      defaultTheme: 'paper-sepia',
      readerFont: 'inter',
      readerTheme: 'paper-dark',
    },
    {
      readerFont: 'patrick-hand',
      readerTheme: 'paper-sage;tex=linen;ink=#143323;scale=115;lh=1.5;margin=compact',
    },
  );
  assert.equal(res.effectiveFontId, 'patrick-hand');
  assert.equal(getReaderFont(res.effectiveFontId).category, 'handwriting');
  assert.equal(
    res.effectiveThemeId,
    'paper-sage;ink=#143323;tex=linen;scale=115;lh=1.5;margin=compact',
  );
  assert.equal(res.effectiveDescriptor.textureId, 'linen');
  assert.equal(res.effectiveDescriptor.inkColor, '#143323');
  assert.equal(res.effectiveDescriptor.fontScale, 115);
  assert.equal(res.effectiveDescriptor.lineHeight, '1.5');
  assert.equal(res.effectiveDescriptor.pageMargin, 'compact');
});

test('round-trips custom paper hex color, ink color, texture, scale, line-height, and margin', () => {
  const serialized = serializeThemeDescriptor({
    themeId: 'custom',
    customPaperColor: '#F5EBD6',
    inkColor: '#3B2818',
    textureId: 'parchment',
    fontScale: 110,
    lineHeight: '1.65',
    pageMargin: 'wide',
  });
  assert.equal(
    serialized,
    'custom;paper=#f5ebd6;ink=#3b2818;tex=parchment;scale=110;lh=1.65;margin=wide',
  );
  const parsed = parseThemeDescriptor(serialized);
  assert.equal(parsed.themeId, 'custom');
  assert.equal(parsed.customPaperColor, '#f5ebd6');
  assert.equal(parsed.inkColor, '#3b2818');
  assert.equal(parsed.textureId, 'parchment');
  assert.equal(parsed.fontScale, 110);
  assert.equal(parsed.lineHeight, '1.65');
  assert.equal(parsed.pageMargin, 'wide');
});
