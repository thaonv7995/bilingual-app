/**
 * Full stylesheet injected into each book-page iframe — ported from v1's
 * injectHighlightCSS (app.js:3921-4153): selectable sentence nodes, highlight
 * marks + note dot, the highlight toolbar, and the sticky-note editor. Book
 * fonts, colors, backgrounds, borders, and decorative styles remain owned by
 * the BKB page stylesheet.
 * The voca lookup-panel CSS (v1 appended getVocaLookupPanelCss()) is added in
 * Phase 5 via `vocaPanelCss`.
 */
const STYLE_ID = 'bilingual-highlight-style';

let vocaPanelCss = '';
/** Phase 5 registers the voca lookup-panel CSS here so it's included on inject. */
export function setVocaPanelCss(css: string): void {
  vocaPanelCss = css;
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
