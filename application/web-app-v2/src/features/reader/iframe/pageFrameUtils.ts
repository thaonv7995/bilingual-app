import type { HighlightLang } from '@/types/api';
import {
  cleanWord,
  lookupWord,
  showVocaError,
  showVocaLookupResults,
  showVocaNotFoundPanel,
} from '@/lib/voca';
import {
  READER_PAGE_HEIGHT,
  READER_PAGE_WIDTH,
  READER_VIEWPORT_PADDING,
  clampReaderZoom,
  type ZoomMode,
} from '../readerConstants';
import { parseThemeDescriptor } from '../readerAppearance';
import { applyStoredHighlights } from './highlightDom';
import { applyInterlinearToDoc, measureInterlinearPageHeight } from './interlinearDom';
import { applyBookAppearance, injectReaderStyles, resolveBookBackground } from './readerStyles';
import { segmentDocSentences } from './segmentation';

export const IFRAME_AUTH_ERROR_MARKERS = [
  'Access Denied: Please log in first',
  'Not authenticated',
  'Invalid or expired JWT',
];

export interface A4MeasuredStatus {
  appliedFontScale: number;
  clampedByA4: boolean;
  atMaxA4Scale: boolean;
}

export function scaleIframeWrappers(
  root: Document | HTMLElement,
  options: {
    zoomMode: ZoomMode;
    manualZoom: number;
    wrapperSelector?: string;
    iframeSelector?: string;
    stageSelector?: string;
  },
): number | null {
  const wrapperSelector = options.wrapperSelector ?? '.iframe-wrapper';
  const iframeSelector = options.iframeSelector ?? '.reader-iframe';
  const stageSelector = options.stageSelector ?? '.iframe-stage';

  const wrappers = root.querySelectorAll<HTMLElement>(wrapperSelector);
  let displayedScale: number | null = null;

  wrappers.forEach((wrapper) => {
    const iframe = wrapper.querySelector<HTMLIFrameElement>(iframeSelector);
    const stage = wrapper.querySelector<HTMLElement>(stageSelector);
    if (!iframe || !stage) return;

    const availableWidth = Math.max(wrapper.clientWidth - READER_VIEWPORT_PADDING, 100);
    const availableHeight = Math.max(wrapper.clientHeight - READER_VIEWPORT_PADDING, 100);
    const fitWidthScale = availableWidth / READER_PAGE_WIDTH;
    const fitPageScale = Math.min(fitWidthScale, availableHeight / READER_PAGE_HEIGHT);

    let scale = options.manualZoom;
    if (options.zoomMode === 'fit-page') scale = fitPageScale;
    if (options.zoomMode === 'fit-width') scale = fitWidthScale;
    scale = clampReaderZoom(scale, 0.2);

    const pageHeight = measureInterlinearPageHeight(iframe.contentDocument);
    const scaledHeight = pageHeight * scale;

    iframe.style.transform = `scale(${scale})`;
    iframe.style.width = `${READER_PAGE_WIDTH}px`;
    iframe.style.height = `${pageHeight}px`;
    stage.style.width = `${READER_PAGE_WIDTH * scale}px`;
    stage.style.height = `${scaledHeight}px`;
    if (scaledHeight < availableHeight) {
      stage.style.marginTop = `${Math.floor((availableHeight - scaledHeight) / 2)}px`;
      stage.style.marginBottom = '0px';
    } else {
      stage.style.marginTop = '0px';
      stage.style.marginBottom = '24px';
    }
    wrapper.dataset.zoomScale = String(scale);
    if (displayedScale === null) displayedScale = scale;
  });

  return displayedScale;
}

export function prepareBookIframeDocument(
  iframeEl: HTMLIFrameElement,
  options: {
    slug: string;
    lang: HighlightLang;
    page: number;
    fontId: string;
    themeId: string;
    measureMaxScale?: boolean;
    onScale: () => void;
    onBindHighlights: (win: Window, doc: Document) => void;
    previousObserver?: ResizeObserver;
  },
): { measured: A4MeasuredStatus; resizeObserver?: ResizeObserver } | null {
  const doc = iframeEl.contentDocument;
  if (!doc) return null;

  doc.documentElement.style.overflow = 'hidden';
  if (doc.body) doc.body.style.overflow = 'hidden';
  const nav = doc.querySelector<HTMLElement>('.page-nav');
  if (nav) nav.style.display = 'none';

  iframeEl.style.backgroundColor = resolveBookBackground(doc);
  injectReaderStyles(doc, options.lang === 'en');

  const measured = applyBookAppearance(doc, iframeEl, {
    fontId: options.fontId,
    themeId: options.themeId,
    measureMaxScale: options.measureMaxScale,
  });

  segmentDocSentences(doc);
  applyStoredHighlights(doc, options.slug, options.page, options.lang);

  const currentDesc = parseThemeDescriptor(options.themeId);
  if (options.lang === 'en' || options.lang === 'vi') {
    void applyInterlinearToDoc(doc, {
      slug: options.slug,
      page: options.page,
      sourceLang: options.lang,
      enabled: currentDesc.interlinear,
      onLayoutUpdated: options.onScale,
    });
  }

  options.previousObserver?.disconnect();
  let resizeObserver: ResizeObserver | undefined;
  if (typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(() => options.onScale());
    const bookPageEl = doc.querySelector<HTMLElement>('.book-page');
    const flowEl = doc.querySelector<HTMLElement>('.prose-page, .toc-page, .sheet-flow');
    if (bookPageEl) resizeObserver.observe(bookPageEl);
    if (flowEl && flowEl !== bookPageEl) resizeObserver.observe(flowEl);
    if (doc.body) resizeObserver.observe(doc.body);
  }

  const win = iframeEl.contentWindow;
  if (win) options.onBindHighlights(win, doc);

  return { measured, resizeObserver };
}

export async function handleReaderVocaLookup(
  text: string,
  doc: Document,
  anchorRect: DOMRect,
): Promise<void> {
  const word = cleanWord(text);
  if (!word) return;
  try {
    const result = await lookupWord(word);
    if (result.found) showVocaLookupResults(doc, anchorRect, word, result);
    else showVocaNotFoundPanel(doc, anchorRect, word);
  } catch (err) {
    showVocaError(err instanceof Error ? err.message : 'Tra cứu thất bại.');
  }
}

