/**
 * Full stylesheet injected into each book-page iframe — ported from v1's
 * injectHighlightCSS (app.js:3921-4153): selectable sentence nodes, highlight
 * marks + note dot, the highlight toolbar, and the sticky-note editor. Book
 * fonts, colors, backgrounds, borders, and decorative styles remain owned by
 * the BKB page stylesheet.
 * The voca lookup-panel CSS (v1 appended getVocaLookupPanelCss()) is added in
 * Phase 5 via `vocaPanelCss`.
 */
import {
  PAGE_MARGIN_OPTIONS,
  getReaderFont,
  getReaderTheme,
  isHexColorDark,
  parseThemeDescriptor,
  type PaperTextureId,
} from '../readerAppearance.ts';

const STYLE_ID = 'bilingual-highlight-style';
const APPEARANCE_STYLE_ID = 'bilingual-appearance-style';
const APPEARANCE_FONT_LINK_ID = 'bilingual-appearance-font-link';

const SVG_NOISE_DATA_URI = `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.82' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.065'/%3E%3C/svg%3E")`;

function buildTextureCss(textureId: PaperTextureId, isDark: boolean): string {
  if (textureId === 'default') return '';
  const lineAlpha = isDark ? 'rgba(255, 255, 255, 0.055)' : 'rgba(60, 42, 24, 0.075)';
  const dotAlpha = isDark ? 'rgba(255, 255, 255, 0.10)' : 'rgba(60, 42, 24, 0.14)';

  let bgImage = '';
  let bgSize = '';
  let boxShadow = '';

  switch (textureId) {
    case 'paper-grain':
      bgImage = SVG_NOISE_DATA_URI;
      bgSize = '160px 160px';
      break;
    case 'vintage':
      bgImage = `radial-gradient(ellipse at center, transparent 52%, ${
        isDark ? 'rgba(0, 0, 0, 0.42)' : 'rgba(120, 82, 38, 0.16)'
      } 100%), ${SVG_NOISE_DATA_URI}`;
      bgSize = '100% 100%, 160px 160px';
      boxShadow = isDark
        ? 'inset 0 0 36px rgba(0, 0, 0, 0.48)'
        : 'inset 0 0 38px rgba(110, 74, 32, 0.18)';
      break;
    case 'linen':
      bgImage = `
        repeating-linear-gradient(0deg, ${lineAlpha} 0px, ${lineAlpha} 1px, transparent 1px, transparent 4px),
        repeating-linear-gradient(90deg, ${lineAlpha} 0px, ${lineAlpha} 1px, transparent 1px, transparent 4px)
      `;
      bgSize = '4px 4px';
      break;
    case 'parchment':
      bgImage = `
        radial-gradient(circle at 20% 25%, ${
          isDark ? 'rgba(255, 215, 150, 0.04)' : 'rgba(180, 130, 65, 0.10)'
        } 0%, transparent 55%),
        radial-gradient(circle at 80% 75%, ${
          isDark ? 'rgba(0, 0, 0, 0.35)' : 'rgba(145, 98, 42, 0.13)'
        } 0%, transparent 60%),
        ${SVG_NOISE_DATA_URI}
      `;
      bgSize = '100% 100%, 100% 100%, 160px 160px';
      boxShadow = isDark
        ? 'inset 0 0 42px rgba(0, 0, 0, 0.5)'
        : 'inset 0 0 42px rgba(120, 80, 30, 0.18)';
      break;
    case 'dot-grid':
      bgImage = `radial-gradient(${dotAlpha} 1.1px, transparent 1.1px)`;
      bgSize = '18px 18px';
      break;
    case 'ruled':
      bgImage = `repeating-linear-gradient(to bottom, transparent 0px, transparent 25px, ${lineAlpha} 25px, ${lineAlpha} 26px)`;
      bgSize = '100% 26px';
      break;
  }

  return `
    .book-page::before {
      content: '';
      position: absolute;
      inset: 0;
      pointer-events: none;
      z-index: 1;
      background-image: ${bgImage} !important;
      ${bgSize ? `background-size: ${bgSize} !important;` : ''}
      ${boxShadow ? `box-shadow: ${boxShadow} !important;` : ''}
    }
    .prose-page, .toc-page {
      position: relative;
      z-index: 2;
    }
  `;
}

let vocaPanelCss = '';
/** Phase 5 registers the voca lookup-panel CSS here so it's included on inject. */
export function setVocaPanelCss(css: string): void {
  vocaPanelCss = css;
}

/** Resolve the BKB-owned paper color used around its A4 sheet. */
export function resolveBookBackground(doc: Document): string {
  const view = doc.defaultView;
  if (!view) return 'transparent';

  const candidates = [doc.body, doc.querySelector<HTMLElement>('.book-page'), doc.documentElement];
  for (const element of candidates) {
    if (!element) continue;
    const color = view.getComputedStyle(element).backgroundColor;
    if (!color || color === 'transparent') continue;

    const rgba = color.match(/^rgba\([^)]*[,/]\s*([\d.]+)\s*\)$/i);
    if (rgba && Number(rgba[1]) <= 0) continue;
    return color;
  }
  return 'transparent';
}

export function injectReaderStyles(doc: Document, isEnglish: boolean): void {
  if (doc.getElementById(STYLE_ID)) return;
  const highlightColor = isEnglish ? 'rgba(56, 189, 248, 0.18)' : 'rgba(250, 204, 21, 0.20)';
  const hoverColor = isEnglish ? 'rgba(56, 189, 248, 0.08)' : 'rgba(250, 204, 21, 0.08)';

  const style = doc.createElement('style');
  style.id = STYLE_ID;
  style.textContent = `
    .sentence-node { transition: background-color 0.2s ease; border-radius: 3px; cursor: pointer; display: inline; }
    .sentence-node:hover { background-color: ${hoverColor}; }
    .sentence-node.highlight-sync { background-color: ${highlightColor} !important; }
    mark.reader-highlight {
      border-radius: 3px; padding: 0 1px; cursor: pointer; position: relative; color: inherit;
      box-decoration-break: clone; -webkit-box-decoration-break: clone;
    }
    mark.reader-highlight[data-has-note="true"]::after {
      content: ''; position: absolute; top: -3px; right: -3px; width: 6px; height: 6px;
      border-radius: 50%; background: #2563eb; border: 1px solid #fff;
    }
    mark.reader-highlight--pulse { animation: readerHighlightPulse 1.2s ease; }
    @keyframes readerHighlightPulse {
      0%, 100% { box-shadow: 0 0 0 0 rgba(37, 99, 235, 0); }
      50% { box-shadow: 0 0 0 4px rgba(37, 99, 235, 0.35); }
    }
    .reader-highlight-toolbar {
      position: fixed; z-index: 2147482999; transform: translate(-50%, -100%);
      display: flex; align-items: center; gap: 7px; padding: 8px 10px;
      background: #ffffff !important; background-image: none !important;
      border: 1px solid rgba(15, 23, 42, 0.16); border-radius: 12px;
      box-shadow: 0 16px 34px rgba(15, 23, 42, 0.24), 0 0 0 1px rgba(255, 255, 255, 0.92) inset;
      animation: readerToolbarIn 0.15s ease; isolation: isolate; opacity: 1 !important;
      overflow: hidden; backdrop-filter: none !important; -webkit-backdrop-filter: none !important;
    }
    .reader-highlight-toolbar::before {
      content: ''; position: absolute; inset: 0; z-index: -1; border-radius: inherit;
      background: #ffffff; pointer-events: none;
    }
    .reader-highlight-toolbar__colors { display: flex; gap: 7px; }
    .reader-highlight-toolbar__color {
      width: 24px; height: 24px; border-radius: 50%; border: 2px solid rgba(15, 23, 42, 0.18);
      box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.75), 0 1px 2px rgba(15, 23, 42, 0.16);
      cursor: pointer; padding: 0; flex-shrink: 0;
      transition: transform 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease;
    }
    .reader-highlight-toolbar__color:hover {
      transform: scale(1.1); border-color: rgba(15, 23, 42, 0.34);
      box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.85), 0 2px 5px rgba(15, 23, 42, 0.22);
    }
    .reader-highlight-toolbar__icon {
      width: 31px; height: 31px; border-radius: 8px; border: 1px solid rgba(15, 23, 42, 0.14);
      background: #f8fafc; color: #0f172a; line-height: 1; cursor: pointer; padding: 0;
      display: inline-flex; align-items: center; justify-content: center;
      box-shadow: 0 1px 2px rgba(15, 23, 42, 0.08); flex-shrink: 0;
      transition: background 0.15s ease, border-color 0.15s ease, transform 0.15s ease;
    }
    .reader-highlight-toolbar__icon:hover { background: #e0f2fe; border-color: rgba(2, 132, 199, 0.24); transform: translateY(-1px); }
    .reader-highlight-toolbar__icon svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
    .reader-highlight-toolbar__icon--danger { color: #b91c1c; }
    .reader-highlight-toolbar__icon--danger:hover { background: #fee2e2; border-color: rgba(239, 68, 68, 0.28); }
    .reader-highlight-sticky {
      position: fixed; z-index: 9999; width: 168px; min-height: 68px;
      background: linear-gradient(160deg, #fef9c3 0%, #fde68a 55%, #fcd34d 100%);
      border: 1px solid rgba(180, 130, 0, 0.35); border-radius: 1px 1px 1px 0;
      box-shadow: 1px 2px 0 rgba(180, 130, 0, 0.15), 3px 5px 12px rgba(0, 0, 0, 0.2);
      padding: 8px 8px 4px; transform: rotate(-1.5deg); animation: readerStickyIn 0.2s ease;
    }
    .reader-highlight-sticky__input {
      width: 100%; min-height: 48px; background: transparent; border: none; resize: none;
      font-family: 'Segoe Print', 'Comic Sans MS', cursive, sans-serif; font-size: 12px;
      line-height: 1.45; color: #422006; outline: none; padding: 0;
    }
    .reader-highlight-sticky__input::placeholder { color: rgba(66, 32, 6, 0.45); }
    .reader-highlight-sticky__footer { display: flex; justify-content: flex-end; gap: 2px; margin-top: 2px; }
    .reader-highlight-sticky__btn {
      background: transparent; border: none; width: 20px; height: 20px; border-radius: 4px;
      font-size: 11px; color: rgba(66, 32, 6, 0.55); cursor: pointer; padding: 0;
    }
    .reader-highlight-sticky__btn:hover { background: rgba(66, 32, 6, 0.08); color: #422006; }
    .reader-highlight-sticky__btn--save { font-weight: 700; color: rgba(66, 32, 6, 0.75); }
    @keyframes readerToolbarIn {
      from { opacity: 0; transform: translate(-50%, calc(-100% + 4px)); }
      to { opacity: 1; transform: translate(-50%, -100%); }
    }
    @keyframes readerStickyIn {
      from { opacity: 0; transform: rotate(-1.5deg) scale(0.92); }
      to { opacity: 1; transform: rotate(-1.5deg) scale(1); }
    }
    .prose-page p, .prose-page li, .prose-page blockquote,
    .prose-page .section-title, .prose-page .action-header, .prose-page .action-title,
    .prose-page h1, .prose-page h2, .prose-page h3, .prose-page h4, .prose-page h5, .prose-page h6,
    .sentence-node { user-select: text; -webkit-user-select: text; }
    ${vocaPanelCss}
  `;
  (doc.head || doc.documentElement).appendChild(style);
}

/**
 * Detect whether the rendered prose/content inside a book iframe overflows
 * the fixed A4 sheet (either exceeding scrollHeight or colliding with the
 * bottom edge / footer folio).
 */
export function doesDocOverflowA4(doc: Document | null | undefined): boolean {
  if (!doc) return false;
  const view = doc.defaultView;
  const pageEl = doc.querySelector<HTMLElement>('.book-page') || doc.body;
  const flowEl =
    doc.querySelector<HTMLElement>('.prose-page, .toc-page, .sheet-flow') || pageEl;
  if (!flowEl || !pageEl) return false;

  // 1. Standard box scrollHeight overflow check
  if (flowEl.scrollHeight > flowEl.clientHeight + 2) return true;
  if (pageEl.scrollHeight > pageEl.clientHeight + 2) return true;

  // 2. Geometric bottom boundary check inside the A4 sheet
  const pageRect = pageEl.getBoundingClientRect();
  if (pageRect.height <= 0) return false;

  let safeBottomY = pageRect.bottom - 16;

  // Account for any visible absolute-positioned footer or folio at the bottom of the page
  const footers = flowEl.querySelectorAll<HTMLElement>(
    '.book-footer, .page-folio, .preface-folio, .toc-folio',
  );
  footers.forEach((footer) => {
    const cs = view ? view.getComputedStyle(footer) : null;
    if (!cs || cs.display === 'none' || cs.visibility === 'hidden') return;
    if (cs.position !== 'absolute' && cs.position !== 'fixed') return;
    const hasText = Boolean(footer.textContent && footer.textContent.trim().length > 0);
    const hasBorder = (parseFloat(cs.borderTopWidth || '0') || 0) > 0;
    if (!hasText && !hasBorder) return;
    const fRect = footer.getBoundingClientRect();
    if (fRect.height > 0 && fRect.top > pageRect.top + pageRect.height * 0.72) {
      safeBottomY = Math.min(safeBottomY, fRect.top - 4);
    }
  });

  // Measure the lowest in-flow content element inside flowEl
  const candidates = flowEl.querySelectorAll<HTMLElement>(
    'p, li, pre, table, figure, blockquote, h1, h2, h3, h4, h5, h6, .convention-item, .toc-row, .exercise-block',
  );
  for (let i = candidates.length - 1; i >= 0; i--) {
    const el = candidates[i]!;
    if (
      el.classList.contains('page-folio') ||
      el.classList.contains('preface-folio') ||
      el.classList.contains('toc-folio') ||
      el.closest('.book-footer, .page-nav')
    ) {
      continue;
    }
    const cs = view ? view.getComputedStyle(el) : null;
    if (cs && (cs.position === 'absolute' || cs.position === 'fixed' || cs.display === 'none')) {
      continue;
    }
    const rect = el.getBoundingClientRect();
    if (rect.height <= 0 && rect.width <= 0) continue;
    if (rect.bottom > safeBottomY + 1.5) {
      return true;
    }
  }

  return false;
}

export interface ApplyAppearanceResult {
  /** The effective fontScale (%) actually applied after A4 overflow clamping. */
  appliedFontScale: number;
  /** True when the requested settings had to be clamped down to prevent A4 overflow. */
  clampedByA4: boolean;
  /** True when increasing fontScale by +5% would overflow the A4 page. */
  atMaxA4Scale: boolean;
}

/**
 * Dynamically apply (or remove when 'default') font, book size, ink color,
 * paper color, and paper texture overrides inside a book page iframe without reloading.
 * Automatically clamps font scale if the chosen size/font/spacing would overflow the A4 sheet.
 */
export function applyBookAppearance(
  doc: Document | null | undefined,
  iframeEl: HTMLIFrameElement | null | undefined,
  options: { fontId: string; themeId: string; measureMaxScale?: boolean },
): ApplyAppearanceResult {
  const desc = parseThemeDescriptor(options.themeId);
  const defaultResult: ApplyAppearanceResult = {
    appliedFontScale: desc.fontScale || 100,
    clampedByA4: false,
    atMaxA4Scale: (desc.fontScale || 100) >= 140,
  };
  if (!doc) return defaultResult;
  const head = doc.head || doc.documentElement;
  if (!head) return defaultResult;

  const font = getReaderFont(options.fontId);
  const theme = getReaderTheme(options.themeId);
  const hasCustomPaper = desc.themeId !== 'default';
  const hasCustomInk = Boolean(desc.inkColor && desc.inkColor !== 'auto');
  const effectiveInk = hasCustomInk ? desc.inkColor : theme.ink;
  const isDarkSurface = hasCustomPaper
    ? theme.isDark
    : hasCustomInk
      ? !isHexColorDark(desc.inkColor)
      : false;

  // 1. Manage Google Font <link> inside iframe head
  let fontLink = doc.getElementById(APPEARANCE_FONT_LINK_ID) as HTMLLinkElement | null;
  if (font.id !== 'default' && font.googleFontUrl) {
    if (!fontLink) {
      fontLink = doc.createElement('link');
      fontLink.id = APPEARANCE_FONT_LINK_ID;
      fontLink.rel = 'stylesheet';
      head.appendChild(fontLink);
    }
    if (fontLink.href !== font.googleFontUrl) {
      fontLink.href = font.googleFontUrl;
    }
  } else if (fontLink) {
    fontLink.remove();
  }

  const buildCssForScale = (
    scalePct: number,
    lineHeightVal: string,
    marginVal: string,
  ): string[] => {
    const cssBlocks: string[] = [];

    if (font.id !== 'default' && font.family) {
      cssBlocks.push(`
        :root {
          --font-display: ${font.family} !important;
          --font-ui: ${font.family} !important;
        }
        body,
        .book-page,
        .prose-page,
        .toc-page,
        .prose-page p,
        .prose-page li,
        .prose-page blockquote,
        .prose-page td,
        .prose-page th,
        .prose-page figcaption,
        .prose-page h1,
        .prose-page h2,
        .prose-page h3,
        .prose-page h4,
        .prose-page h5,
        .prose-page h6,
        .prose-page .running-head,
        .prose-page .section-title,
        .prose-page .section-number,
        .prose-page .chapter-opener,
        .prose-page .chapter-title,
        .prose-page .preface-title,
        .prose-page .exercise-instruction,
        .prose-page .exercises-title,
        .title-book,
        .subtitle-book,
        .author-book,
        .toc-title,
        .toc-row {
          font-family: ${font.family} !important;
        }
        /* Keep code, ASCII diagrams, and math formulas in their original font */
        .prose-page pre,
        .prose-page code,
        .prose-page pre *,
        .prose-page code *,
        .prose-page .code-block,
        .prose-page .ascii-figure {
          font-family: var(--font-mono, "Courier New", Courier, monospace) !important;
        }
        .prose-page .math,
        .prose-page .formula,
        .prose-page .formula-display {
          font-family: "Times New Roman", Times, serif !important;
        }
      `);
    }

    if (scalePct !== 100) {
      const ratio = (scalePct / 100).toFixed(3);
      cssBlocks.push(`
        .prose-page {
          font-size: calc(11pt * ${ratio}) !important;
        }
        .prose-page p,
        .prose-page li,
        .prose-page blockquote,
        .prose-page .exercise-instruction,
        .toc-page .toc-row {
          font-size: calc(11pt * ${ratio}) !important;
        }
      `);
    }

    if (lineHeightVal && lineHeightVal !== 'default') {
      cssBlocks.push(`
        .prose-page,
        .prose-page p,
        .prose-page li,
        .prose-page blockquote,
        .prose-page .exercise-instruction {
          line-height: ${lineHeightVal} !important;
        }
      `);
    }

    if (marginVal && marginVal !== 'default') {
      const marginOpt = PAGE_MARGIN_OPTIONS.find((m) => m.id === marginVal);
      if (marginOpt?.mm) {
        cssBlocks.push(`
          :root {
            --book-margin-x: ${marginOpt.mm} !important;
          }
          .prose-page,
          .toc-page {
            padding-left: ${marginOpt.mm} !important;
            padding-right: ${marginOpt.mm} !important;
          }
        `);
      }
    }

    if (hasCustomPaper || hasCustomInk) {
      cssBlocks.push(`
        :root {
          ${
            hasCustomPaper
              ? `
            --book-paper: ${theme.paper} !important;
            --paper: ${theme.paper} !important;
            --muted: ${theme.muted} !important;
            --book-accent: ${theme.accent} !important;
            --accent: ${theme.accent} !important;
            --book-rule: ${theme.rule} !important;
            --rule: ${theme.rule} !important;
          `
              : ''
          }
          --book-ink: ${effectiveInk} !important;
          --ink: ${effectiveInk} !important;
        }
        ${
          hasCustomPaper
            ? `
          html,
          body,
          body.book-standalone,
          .book-page,
          .book-page.book-page--sheet {
            background-color: ${theme.paper} !important;
            background: ${theme.paper} !important;
            color: ${effectiveInk} !important;
          }
          .book-page--sheet::after {
            background: linear-gradient(
              to bottom,
              transparent 0%,
              color-mix(in srgb, ${theme.paper} 60%, transparent) 40%,
              ${theme.paper} 75%
            ) !important;
          }
          .prose-page .running-head,
          .prose-page .running-head span,
          .prose-page .page-folio,
          .prose-page .preface-folio,
          .toc-page .toc-folio,
          .prose-page figcaption,
          .prose-page .footnotes {
            color: ${theme.muted} !important;
          }
          .prose-page a,
          .prose-page .accent-word,
          .prose-page .exercises-title,
          .prose-page .exercise-number {
            color: ${theme.accent} !important;
          }
          .prose-page pre.code-block,
          .prose-page pre.ascii-figure {
            color: ${effectiveInk} !important;
            background-color: ${theme.codeBg} !important;
            border-radius: 4px;
          }
          .prose-page table.data-table th {
            background-color: ${theme.codeBg} !important;
            color: ${effectiveInk} !important;
            border-color: ${theme.rule} !important;
          }
          .prose-page table.data-table td {
            border-color: ${theme.rule} !important;
          }
          .prose-page .footnotes,
          .toc-page .toc-row .label::after,
          .title-page-border {
            border-color: ${theme.rule} !important;
          }
        `
            : ''
        }
        .prose-page,
        .toc-page,
        .prose-page p,
        .prose-page li,
        .prose-page blockquote,
        .prose-page td,
        .prose-page h1,
        .prose-page h2,
        .prose-page h3,
        .prose-page h4,
        .prose-page h5,
        .prose-page h6,
        .prose-page .section-number,
        .prose-page .section-title,
        .prose-page .chapter-opener,
        .prose-page .chapter-title,
        .prose-page .preface-title,
        .prose-page .drop-cap,
        .title-book,
        .subtitle-book,
        .author-book,
        .toc-title,
        .toc-row {
          color: ${effectiveInk} !important;
        }
        ${
          isDarkSurface
            ? `
          mark.reader-highlight {
            color: #0f172a !important;
          }
          mark.reader-highlight * {
            color: #0f172a !important;
          }
        `
            : ''
        }
      `);
    }

    if (desc.textureId && desc.textureId !== 'default') {
      cssBlocks.push(buildTextureCss(desc.textureId, isDarkSurface));
    }

    return cssBlocks;
  };

  const writeCss = (blocks: string[]) => {
    let styleEl = doc.getElementById(APPEARANCE_STYLE_ID) as HTMLStyleElement | null;
    if (blocks.length > 0) {
      if (!styleEl) {
        styleEl = doc.createElement('style');
        styleEl.id = APPEARANCE_STYLE_ID;
        head.appendChild(styleEl);
      }
      styleEl.textContent = blocks.join('\n');
    } else if (styleEl) {
      styleEl.remove();
    }
  };

  const requestedScale = desc.fontScale || 100;
  let appliedScale = requestedScale;
  let appliedLineHeight = desc.lineHeight || 'default';
  let appliedMargin = desc.pageMargin || 'default';
  let clampedByA4 = false;

  writeCss(buildCssForScale(appliedScale, appliedLineHeight, appliedMargin));

  // A4 Overflow Guard: if typography customization caused the page to overflow A4,
  // step down scale (and if needed, line-height / wide margin) until it fits the A4 page.
  const hasTypographyChange =
    appliedScale > 100 ||
    font.id !== 'default' ||
    appliedLineHeight !== 'default' ||
    appliedMargin === 'wide';

  if (hasTypographyChange && doesDocOverflowA4(doc)) {
    const minScale = font.id !== 'default' ? 85 : 100;
    while (appliedScale > minScale && doesDocOverflowA4(doc)) {
      appliedScale = Math.max(minScale, appliedScale - 2);
      clampedByA4 = true;
      writeCss(buildCssForScale(appliedScale, appliedLineHeight, appliedMargin));
    }
    if (doesDocOverflowA4(doc) && appliedLineHeight !== 'default') {
      appliedLineHeight = 'default';
      clampedByA4 = true;
      writeCss(buildCssForScale(appliedScale, appliedLineHeight, appliedMargin));
    }
    if (doesDocOverflowA4(doc) && appliedMargin === 'wide') {
      appliedMargin = 'default';
      clampedByA4 = true;
      writeCss(buildCssForScale(appliedScale, appliedLineHeight, appliedMargin));
    }
  }

  // Probe whether +5% fontScale would overflow A4 only when the appearance
  // popover is open (measureMaxScale === true), avoiding 2 extra full-page
  // synchronous reflows on every single page turn while reading normally.
  let atMaxA4Scale = appliedScale >= 140 || clampedByA4;
  if (options.measureMaxScale && !atMaxA4Scale) {
    writeCss(buildCssForScale(appliedScale + 5, appliedLineHeight, appliedMargin));
    if (doesDocOverflowA4(doc)) {
      atMaxA4Scale = true;
    }
    // Restore the actual applied CSS
    writeCss(buildCssForScale(appliedScale, appliedLineHeight, appliedMargin));
  }

  if (iframeEl) {
    iframeEl.style.backgroundColor = hasCustomPaper
      ? theme.paper
      : resolveBookBackground(doc);
  }

  return {
    appliedFontScale: appliedScale,
    clampedByA4,
    atMaxA4Scale,
  };
}
