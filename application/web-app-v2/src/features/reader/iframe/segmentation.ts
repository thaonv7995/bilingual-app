/**
 * Sentence segmentation inside a book-page document — ported verbatim from v1
 * (app.js:3797-3919, 4156-4159). Wraps each sentence in a `.sentence-node` span
 * so the reader can cross-highlight matching sentences across the EN/VI panes.
 */

export const PARAGRAPH_SELECTOR =
  'p, .chapter-start, .no-indent, h1, h2, h3, h4, h5, h6, li, blockquote, .section-title, .action-header, .action-title';

const ABBREVS = new Set([
  'mr', 'mrs', 'dr', 'ms', 'prof', 'sr', 'jr', 'vs', 'etc', 'eg', 'ie', 'al',
  'st', 'av', 'rd', 'capt', 'gen', 'col', 'lt', 'sgt', 'rep', 'sen', 'oct', 'nov', 'dec',
  'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'tp', 'ts', 'ths', 'gs', 'hcm',
]);

export function splitIntoSentences(text: string): string[] {
  if (!text) return [];
  const sentences: string[] = [];
  let currentStart = 0;
  const boundaryRegex = /([.!?])(\s+|$)/g;
  let match: RegExpExecArray | null;

  while ((match = boundaryRegex.exec(text)) !== null) {
    const boundaryIdx = match.index;
    const preceding = text.substring(currentStart, boundaryIdx);
    const lastWordMatch = preceding.match(/(\b\w+)$/);
    const lastWord = lastWordMatch?.[1]?.toLowerCase() ?? '';
    if (ABBREVS.has(lastWord)) continue;

    const sentenceEnd = boundaryIdx + 1 + (match[2] ?? '').length;
    const sentenceText = text.substring(currentStart, sentenceEnd);
    if (sentenceText.length > 0) sentences.push(sentenceText);
    currentStart = sentenceEnd;
  }
  if (currentStart < text.length) {
    const remaining = text.substring(currentStart);
    if (remaining.length > 0) sentences.push(remaining);
  }
  return sentences;
}

function segmentParagraph(pElement: HTMLElement, pIdx: number): void {
  const doc = pElement.ownerDocument;
  const sentences = splitIntoSentences(pElement.textContent || '');

  if (sentences.length <= 1) {
    const span = doc.createElement('span');
    span.className = 'sentence-node';
    span.dataset.sentenceId = `p-${pIdx}-s-0`;
    while (pElement.firstChild) span.appendChild(pElement.firstChild);
    pElement.appendChild(span);
    return;
  }

  const spans = sentences.map((_, sIdx) => {
    const span = doc.createElement('span');
    span.className = 'sentence-node';
    span.dataset.sentenceId = `p-${pIdx}-s-${sIdx}`;
    return span;
  });

  let idx = 0;
  let remaining = sentences[0]!.length;
  const childNodes = Array.from(pElement.childNodes);
  pElement.innerHTML = '';

  childNodes.forEach((node) => {
    if (node.nodeType === 3) {
      let nodeText = node.textContent || '';
      while (nodeText.length > 0 && idx < sentences.length) {
        if (nodeText.length <= remaining) {
          spans[idx]!.appendChild(doc.createTextNode(nodeText));
          remaining -= nodeText.length;
          nodeText = '';
        } else {
          spans[idx]!.appendChild(doc.createTextNode(nodeText.substring(0, remaining)));
          nodeText = nodeText.substring(remaining);
          idx++;
          if (idx < sentences.length) remaining = sentences[idx]!.length;
        }
      }
    } else if (node.nodeType === 1) {
      spans[idx]!.appendChild(node);
      remaining -= (node.textContent || '').length;
      if (remaining <= 0 && idx < sentences.length - 1) {
        idx++;
        remaining = sentences[idx]!.length;
      }
    }
  });

  spans.forEach((span) => {
    if ((span.textContent || '').length > 0) pElement.appendChild(span);
  });
}

export function segmentDocSentences(doc: Document): void {
  const article = doc.querySelector('article') || doc.body;
  if (!article) return;
  article.querySelectorAll<HTMLElement>(PARAGRAPH_SELECTOR).forEach((p, idx) => {
    if (!p.querySelector('.sentence-node')) segmentParagraph(p, idx);
  });
}

export function getParagraphs(doc: Document): HTMLElement[] {
  const article = doc.querySelector('article') || doc.body;
  return Array.from(article.querySelectorAll<HTMLElement>(PARAGRAPH_SELECTOR));
}
