/** Extract reading context from the book iframes for the AI companion —
 * ported from v1 (app.js:1828-1868). Same-origin access works because the
 * iframes are sandboxed with allow-same-origin. */

export function getIframePageText(page: number): string {
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
  const panes = [
    { selector: '.en-pane-iframe', label: 'English' },
    { selector: '.vi-pane-iframe', label: 'Vietnamese' },
  ];
  for (const pane of panes) {
    const iframe = document.querySelector<HTMLIFrameElement>(pane.selector);
    const text = iframe?.contentWindow?.getSelection?.()?.toString().trim();
    if (text) return `[${pane.label} selected text]:\n${text}`;
  }
  return '';
}
