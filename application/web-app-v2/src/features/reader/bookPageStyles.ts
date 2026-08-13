/**
 * Styles injected into each book-page iframe document. Ported from v1's
 * `injectHighlightCSS` (app.js:3921+), split so Phase 3 owns the base "paper"
 * theme and Phase 4 will add the highlight/sentence-node rules.
 *
 * The parent injects this because the iframe is sandboxed (`allow-same-origin`,
 * no `allow-scripts`): book content can't run JS, but the same-origin parent can
 * still style and annotate the document.
 */
const BASE_STYLE_ID = 'bilingual-reader-base-style';

export function injectReaderPageStyles(doc: Document): void {
  if (doc.getElementById(BASE_STYLE_ID)) return;
  const style = doc.createElement('style');
  style.id = BASE_STYLE_ID;
  style.textContent = `
    html {
      background-color: #F9F7F1 !important;
    }
    body, body.book-standalone {
      background-color: #F9F7F1 !important;
      color: #333333 !important;
    }
    main, article, .prose-page {
      background-color: transparent !important;
      color: inherit !important;
    }
    .book-page, .book-page--sheet, .sheet-flow {
      background-color: transparent !important;
    }
    main div, main p, main h1, main h2, main h3, main h4, main h5, main h6, main ul, main ol, main li,
    article div, article p, article h1, article h2, article h3, article h4, article h5, article h6, article ul, article ol, article li,
    .prose-page div, .prose-page p, .prose-page h1, .prose-page h2, .prose-page h3, .prose-page h4, .prose-page h5, .prose-page h6, .prose-page ul, .prose-page ol, .prose-page li {
      background-color: transparent !important;
      color: inherit !important;
    }
  `;
  (doc.head || doc.documentElement).appendChild(style);
}
