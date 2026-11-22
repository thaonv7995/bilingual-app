/** Extract reading context from the active reader (BKB iframes, PDF.js, or EPUB foliate-js)
 * for the AI companion. */

export interface ReaderPageContextProvider {
  getPageText: (page: number) => string;
  getSelectedText: () => string;
}

let activeProvider: ReaderPageContextProvider | null = null;

export function registerReaderPageContextProvider(
  provider: ReaderPageContextProvider | null,
): void {
  activeProvider = provider;
}

export function getIframePageText(page: number): string {
  if (activeProvider) {
    const custom = activeProvider.getPageText(page)?.trim();
    if (custom) return custom;
  }
  let text = '';
  const en = document.querySelector<HTMLIFrameElement>('.en-pane-iframe');
  const enTxt = en?.contentDocument?.body?.innerText.trim();
  if (enTxt) text += `=== ENGLISH PAGE ${page} ===\n${enTxt}\n\n`;
  const vi = document.querySelector<HTMLIFrameElement>('.vi-pane-iframe');
  const viTxt = vi?.contentDocument?.body?.innerText.trim();
  if (viTxt) text += `=== VIETNAMESE PAGE ${page} ===\n${viTxt}\n\n`;
  return text.trim();
}

export function getSelectedReaderText(): string {
  if (activeProvider) {
    const custom = activeProvider.getSelectedText()?.trim();
    if (custom) return custom;
  }
  const panes = [
    { selector: '.en-pane-iframe', label: 'English' },
    { selector: '.vi-pane-iframe', label: 'Vietnamese' },
  ];
  for (const pane of panes) {
    const iframe = document.querySelector<HTMLIFrameElement>(pane.selector);
    const text = iframe?.contentWindow?.getSelection?.()?.toString().trim();
    if (text) return `[${pane.label} selected text]:\n${text}`;
  }
  const hostSel = window.getSelection?.()?.toString().trim();
  if (hostSel) return `[Selected text]:\n${hostSel}`;
  return '';
}
