import {
  READER_PAGE_HEIGHT,
  READER_PAGE_WIDTH,
  READER_VIEWPORT_PADDING,
  padPage,
} from '../readerConstants.ts';
import { getParagraphs, segmentDocSentences } from './segmentation.ts';

const INTERLINEAR_LAYOUT_STYLE_ID = 'bilingual-interlinear-layout-style';

const INTERLINEAR_LAYOUT_CSS = `
  html.bilingual-interlinear-doc,
  html.bilingual-interlinear-doc body,
  html.bilingual-interlinear-doc body.book-standalone {
    height: auto !important;
    min-height: 0 !important;
    max-height: none !important;
    overflow: hidden !important;
    display: block !important;
  }
  html.bilingual-interlinear-doc .book-page,
  html.bilingual-interlinear-doc .book-page.book-page--sheet {
    height: auto !important;
    min-height: 297mm !important;
    max-height: none !important;
    overflow: visible !important;
    margin: 0 auto !important;
    padding-bottom: 0 !important;
  }
  html.bilingual-interlinear-doc .book-page--sheet::after,
  html.bilingual-interlinear-doc .book-page::after {
    display: none !important;
    content: none !important;
  }
  html.bilingual-interlinear-doc .sheet-flow,
  html.bilingual-interlinear-doc .prose-page,
  html.bilingual-interlinear-doc .prose-page.chapter-page,
  html.bilingual-interlinear-doc .prose-page.chapter-body-page,
  html.bilingual-interlinear-doc .prose-page.manning-chapter-page,
  html.bilingual-interlinear-doc .prose-page.ocp-chapter-page,
  html.bilingual-interlinear-doc .prose-page.copy,
  html.bilingual-interlinear-doc .prose-page.preface-page,
  html.bilingual-interlinear-doc .sheet-flow.prose-page,
  html.bilingual-interlinear-doc .toc-page,
  html.bilingual-interlinear-doc .unit-page,
  html.bilingual-interlinear-doc article.sheet-flow,
  html.bilingual-interlinear-doc article.prose-page {
    height: auto !important;
    min-height: 297mm !important;
    max-height: none !important;
    overflow: visible !important;
    padding-bottom: 24mm !important;
  }
  html.bilingual-interlinear-doc .prose-content,
  html.bilingual-interlinear-doc .toc-columns-container,
  html.bilingual-interlinear-doc .copy-content {
    height: auto !important;
    max-height: none !important;
    overflow: visible !important;
  }
`;

function syncInterlinearLayoutStyle(doc: Document, enabled: boolean): void {
  const existing = doc.getElementById(INTERLINEAR_LAYOUT_STYLE_ID) as HTMLStyleElement | null;
  if (!enabled) {
    existing?.remove();
    return;
  }
  const head = doc.head || doc.documentElement;
  if (!head) return;
  const styleEl = existing ?? doc.createElement('style');
  styleEl.id = INTERLINEAR_LAYOUT_STYLE_ID;
  styleEl.textContent = INTERLINEAR_LAYOUT_CSS;
  if (!existing) {
    head.appendChild(styleEl);
  }
}

export function measureInterlinearPageHeight(doc: Document | null | undefined): number {
  if (!doc || !doc.documentElement.classList.contains('bilingual-interlinear-doc')) {
    return READER_PAGE_HEIGHT;
  }
  const bookPage = doc.querySelector<HTMLElement>('.book-page');
  const flowEl = doc.querySelector<HTMLElement>('.prose-page, .toc-page, .sheet-flow');
  const measured = Math.ceil(
    Math.max(
      READER_PAGE_HEIGHT,
      bookPage?.offsetHeight ?? 0,
      bookPage?.scrollHeight ?? 0,
      flowEl?.offsetHeight ?? 0,
      flowEl?.scrollHeight ?? 0,
    ),
  );
  return Math.max(READER_PAGE_HEIGHT, measured);
}

function syncContainingIframeHeight(doc: Document): void {
  const iframe = doc.defaultView?.frameElement as HTMLIFrameElement | null;
  if (!iframe) return;
  const stage = iframe.parentElement;
  const wrapper = stage?.parentElement;
  const scale = parseFloat(wrapper?.dataset.zoomScale || '1') || 1;
  const pageHeight = measureInterlinearPageHeight(doc);

  iframe.style.width = `${READER_PAGE_WIDTH}px`;
  iframe.style.height = `${pageHeight}px`;
  if (stage) {
    const scaledHeight = pageHeight * scale;
    stage.style.width = `${READER_PAGE_WIDTH * scale}px`;
    stage.style.height = `${scaledHeight}px`;
    if (wrapper) {
      const availableHeight = Math.max(wrapper.clientHeight - READER_VIEWPORT_PADDING, 100);
      if (scaledHeight < availableHeight) {
        stage.style.marginTop = `${Math.floor((availableHeight - scaledHeight) / 2)}px`;
        stage.style.marginBottom = '0px';
      } else {
        stage.style.marginTop = '0px';
        stage.style.marginBottom = '24px';
      }
    }
  }
}

export interface WordLineToken {
  sentenceIndex: number;
  weight: number;
}

export interface VisualLineDescriptor {
  tokens: WordLineToken[];
  totalWeight: number;
}

export interface IndexedOppositeParagraphs {
  paragraphs: Map<number, string[]>;
}

const oppositeIndexCache = new Map<string, IndexedOppositeParagraphs>();
const inFlightRequests = new Map<string, Promise<IndexedOppositeParagraphs | null>>();

/**
 * Distribute an array of words across buckets proportionally to `weights`
 * using cumulative rounding so every word appears once in order.
 */
export function distributeWordsByWeights(words: string[], weights: number[]): string[] {
  if (weights.length === 0) return [];
  if (words.length === 0) return weights.map(() => '');
  if (weights.length === 1) return [words.join(' ')];

  const safeWeights = weights.map((w) => Math.max(1, w));
  const totalWeight = safeWeights.reduce((acc, w) => acc + w, 0);
  const totalWords = words.length;

  const out: string[] = [];
  let cumWeight = 0;
  let prevWordIdx = 0;

  for (let i = 0; i < safeWeights.length; i++) {
    cumWeight += safeWeights[i]!;
    const nextWordIdx =
      i === safeWeights.length - 1
        ? totalWords
        : Math.max(prevWordIdx, Math.min(totalWords, Math.round((cumWeight / totalWeight) * totalWords)));
    out.push(words.slice(prevWordIdx, nextWordIdx).join(' '));
    prevWordIdx = nextWordIdx;
  }

  return out;
}

/**
 * Allocate opposite-language sentences onto the measured visual lines of a paragraph.
 * Locks strictly to sentence boundaries when source and target sentence counts match,
 * and falls back to paragraph-wide proportional word distribution otherwise.
 */
export function allocateTargetToVisualLines(
  lines: VisualLineDescriptor[],
  targetSentences: string[],
): string[] {
  if (lines.length === 0) return [];
  const cleanedSentences = targetSentences.map((s) => s.replace(/\s+/g, ' ').trim()).filter(Boolean);
  if (cleanedSentences.length === 0) return lines.map(() => '');
  if (lines.length === 1) {
    return [cleanedSentences.join(' ')];
  }

  let maxSentenceIndex = 0;
  for (const line of lines) {
    for (const token of line.tokens) {
      if (token.sentenceIndex > maxSentenceIndex) {
        maxSentenceIndex = token.sentenceIndex;
      }
    }
  }
  const sourceSentenceCount = maxSentenceIndex + 1;

  if (sourceSentenceCount === cleanedSentences.length) {
    const lineBuckets: string[][] = lines.map(() => []);

    for (let sIdx = 0; sIdx < sourceSentenceCount; sIdx++) {
      const sentenceWords = cleanedSentences[sIdx]!.split(/\s+/).filter(Boolean);
      if (sentenceWords.length === 0) continue;

      const matchingLineIndices: number[] = [];
      const matchingWeights: number[] = [];

      lines.forEach((line, lIdx) => {
        let weightForSentence = 0;
        for (const t of line.tokens) {
          if (t.sentenceIndex === sIdx) {
            weightForSentence += t.weight;
          }
        }
        if (weightForSentence > 0) {
          matchingLineIndices.push(lIdx);
          matchingWeights.push(weightForSentence);
        }
      });

      if (matchingLineIndices.length === 0) continue;
      const slices = distributeWordsByWeights(sentenceWords, matchingWeights);
      matchingLineIndices.forEach((lIdx, idx) => {
        const piece = slices[idx];
        if (piece) lineBuckets[lIdx]!.push(piece);
      });
    }

    return lineBuckets.map((parts) => parts.join(' ').trim());
  }

  const allWords = cleanedSentences.join(' ').split(/\s+/).filter(Boolean);
  const lineWeights = lines.map((l) => Math.max(1, l.totalWeight));
  return distributeWordsByWeights(allWords, lineWeights);
}

export function indexOppositeDocument(doc: Document): IndexedOppositeParagraphs {
  segmentDocSentences(doc);
  const paragraphs = new Map<number, string[]>();
  const pNodes = getParagraphs(doc);

  pNodes.forEach((p, pIdx) => {
    const sentenceSpans = Array.from(p.querySelectorAll<HTMLElement>('.sentence-node'));
    const list: string[] = [];
    sentenceSpans.forEach((span) => {
      const text = (span.textContent || '').replace(/\s+/g, ' ').trim();
      if (text) list.push(text);
    });
    if (list.length === 0) {
      const fallback = (p.textContent || '').replace(/\s+/g, ' ').trim();
      if (fallback) list.push(fallback);
    }
    if (list.length > 0) {
      paragraphs.set(pIdx, list);
    }
  });

  return { paragraphs };
}

export async function fetchOppositeInterlinearIndex(
  slug: string,
  page: number,
  targetLang: 'en' | 'vi',
): Promise<IndexedOppositeParagraphs | null> {
  const key = `${slug}:${page}:${targetLang}`;
  const cached = oppositeIndexCache.get(key);
  if (cached) return cached;

  const existing = inFlightRequests.get(key);
  if (existing) return existing;

  const url = `/books/${encodeURIComponent(slug)}/output/${targetLang}/page_${padPage(page)}.html`;
  const promise = (async () => {
    try {
      const res = await fetch(url, { credentials: 'include' });
      if (!res.ok) return null;
      const html = await res.text();
      if (!html) return null;
      const parser = new DOMParser();
      const parsedDoc = parser.parseFromString(html, 'text/html');
      const indexed = indexOppositeDocument(parsedDoc);
      if (oppositeIndexCache.size > 60) {
        const firstKey = oppositeIndexCache.keys().next().value;
        if (firstKey) oppositeIndexCache.delete(firstKey);
      }
      oppositeIndexCache.set(key, indexed);
      return indexed;
    } catch {
      return null;
    } finally {
      inFlightRequests.delete(key);
    }
  })();

  inFlightRequests.set(key, promise);
  return promise;
}

/**
 * Remove all injected `.bilingual-subline` nodes and merge split text nodes back together.
 */
export function clearInterlinearFromDoc(doc: Document | null | undefined): void {
  if (!doc) return;
  const sublines = doc.querySelectorAll('.bilingual-subline');
  if (sublines.length === 0) return;

  const parentsToNormalize = new Set<Node>();
  sublines.forEach((el) => {
    if (el.parentNode) parentsToNormalize.add(el.parentNode);
    el.remove();
  });
  parentsToNormalize.forEach((parent) => {
    try {
      parent.normalize();
    } catch {
      /* ignore */
    }
  });
}

interface MeasuredWordToken {
  node: Text;
  start: number;
  end: number;
  trailingEnd: number;
  weight: number;
  sentenceIndex: number;
}

interface MeasuredVisualLine extends VisualLineDescriptor {
  top: number;
  lastToken: MeasuredWordToken;
}

function extractSentenceIndex(node: Text): number {
  const span = node.parentElement?.closest<HTMLElement>('.sentence-node');
  const id = span?.dataset.sentenceId;
  if (!id) return 0;
  const m = /^p-\d+-s-(\d+)$/.exec(id);
  return m ? parseInt(m[1]!, 10) : 0;
}

function measureVisualLinesInElement(doc: Document, p: HTMLElement): MeasuredVisualLine[] {
  if (p.closest('pre, code, .code-block, .ascii-figure, .math, .formula, .formula-display')) {
    return [];
  }

  const walker = doc.createTreeWalker(p, NodeFilter.SHOW_TEXT);
  const wordTokens: MeasuredWordToken[] = [];

  while (walker.nextNode()) {
    const textNode = walker.currentNode as Text;
    const parentEl = textNode.parentElement;
    if (!parentEl) continue;
    if (parentEl.closest('.bilingual-subline, pre, .code-block, .ascii-figure')) continue;

    const raw = textNode.nodeValue || '';
    if (!raw.trim()) continue;

    const sIdx = extractSentenceIndex(textNode);
    const wordRegex = /\S+/g;
    let match: RegExpExecArray | null;
    while ((match = wordRegex.exec(raw)) !== null) {
      const start = match.index;
      const end = start + match[0].length;
      let trailingEnd = end;
      while (trailingEnd < raw.length && (raw[trailingEnd] === ' ' || raw[trailingEnd] === '\t')) {
        trailingEnd++;
      }
      wordTokens.push({
        node: textNode,
        start,
        end,
        trailingEnd,
        weight: Math.max(1, match[0].length),
        sentenceIndex: sIdx,
      });
    }
  }

  if (wordTokens.length === 0) return [];

  const range = doc.createRange();
  const lines: MeasuredVisualLine[] = [];

  for (const token of wordTokens) {
    try {
      range.setStart(token.node, token.start);
      range.setEnd(token.node, token.end);
      const rect = range.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) continue;

      const currentLine = lines[lines.length - 1];
      if (!currentLine || Math.abs(rect.top - currentLine.top) > 6) {
        lines.push({
          top: rect.top,
          tokens: [{ sentenceIndex: token.sentenceIndex, weight: token.weight }],
          totalWeight: token.weight,
          lastToken: token,
        });
      } else {
        currentLine.tokens.push({ sentenceIndex: token.sentenceIndex, weight: token.weight });
        currentLine.totalWeight += token.weight;
        currentLine.lastToken = token;
      }
    } catch {
      /* ignore invalid range */
    }
  }

  range.detach?.();
  return lines;
}

/**
 * Render True Line-by-Line interlinear translations across all prose paragraphs in `doc`.
 */
export async function applyInterlinearToDoc(
  doc: Document | null | undefined,
  options: {
    slug: string;
    page: number;
    sourceLang: 'en' | 'vi';
    enabled: boolean;
    onLayoutUpdated?: () => void;
  },
): Promise<void> {
  if (!doc) return;
  clearInterlinearFromDoc(doc);

  if (!options.enabled) {
    doc.documentElement.classList.remove('bilingual-interlinear-doc');
    syncInterlinearLayoutStyle(doc, false);
    syncContainingIframeHeight(doc);
    options.onLayoutUpdated?.();
    return;
  }

  doc.documentElement.classList.add('bilingual-interlinear-doc');
  syncInterlinearLayoutStyle(doc, true);
  const targetLang: 'en' | 'vi' = options.sourceLang === 'en' ? 'vi' : 'en';
  const index = await fetchOppositeInterlinearIndex(options.slug, options.page, targetLang);
  if (!index || !doc.defaultView) {
    syncContainingIframeHeight(doc);
    options.onLayoutUpdated?.();
    return;
  }

  // Re-clear in case another call raced while awaiting fetch
  clearInterlinearFromDoc(doc);
  if (!doc.documentElement.classList.contains('bilingual-interlinear-doc')) {
    return;
  }
  syncInterlinearLayoutStyle(doc, true);

  const paragraphs = getParagraphs(doc);
  const view = doc.defaultView;

  paragraphs.forEach((p, pIdx) => {
    const targetSentences = index.paragraphs.get(pIdx);
    if (!targetSentences || targetSentences.length === 0) return;

    const sourceFull = (p.textContent || '').replace(/\s+/g, ' ').trim();
    const targetFull = targetSentences.join(' ').replace(/\s+/g, ' ').trim();
    if (!sourceFull || !targetFull) return;
    if (sourceFull.toLowerCase() === targetFull.toLowerCase()) return;

    const lines = measureVisualLinesInElement(doc, p);
    if (lines.length === 0) return;

    const subTexts = allocateTargetToVisualLines(lines, targetSentences);
    const computedIndent = view ? parseFloat(view.getComputedStyle(p).textIndent || '0') : 0;
    const hasFirstLineIndent = computedIndent > 4;

    // Insert from the last visual line back to the first so earlier text node offsets stay valid
    for (let i = lines.length - 1; i >= 0; i--) {
      const subText = (subTexts[i] || '').trim();
      if (!subText) continue;

      const sub = doc.createElement('span');
      sub.className =
        i === 0 && hasFirstLineIndent
          ? 'bilingual-subline bilingual-subline--indented'
          : 'bilingual-subline';
      sub.setAttribute('data-bilingual-sub', '1');
      sub.setAttribute('data-subtext', subText);
      sub.setAttribute('aria-hidden', 'true');

      if (i === lines.length - 1) {
        p.appendChild(sub);
      } else {
        const lastToken = lines[i]!.lastToken;
        try {
          const insertRange = doc.createRange();
          const safeOffset = Math.min(
            lastToken.trailingEnd,
            (lastToken.node.nodeValue || '').length,
          );
          insertRange.setStart(lastToken.node, safeOffset);
          insertRange.collapse(true);
          insertRange.insertNode(sub);
        } catch {
          p.appendChild(sub);
        }
      }
    }
  });

  syncContainingIframeHeight(doc);
  options.onLayoutUpdated?.();
}

