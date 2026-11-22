import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useToast } from '@/components/Toast';
import { AuthRefreshError, ensureFreshAccessToken } from '@/lib/api-client';
import type { Book, Highlight, HighlightLang, ViewMode } from '@/types/api';
import {
  clearAllHighlights,
  registerIframeHighlightListeners,
  removeReaderHighlightUI,
  scrollAndPulseHighlightInWrapper,
  type HighlightContext,
  type SelectionInfo,
} from './iframe/highlightDom';
import {
  IFRAME_AUTH_ERROR_MARKERS,
  handleReaderVocaLookup,
  prepareBookIframeDocument,
  scaleIframeWrappers,
} from './iframe/pageFrameUtils';
import {
  READER_ZOOM_STEP,
  clampReaderZoom,
  formatReaderZoom,
  padPage,
  type ZoomMode,
} from './readerConstants';
import { clampReaderPage, resolveInitialReferenceViewMode } from './highlightsList';

const REF_IFRAME_SELECTOR = '.ref-en-pane-iframe, .ref-vi-pane-iframe';

/**
 * Independent modal viewer for inspecting a highlight or note on its own page
 * without mutating the main reader's current page, view mode, URL, or progress.
 */
export function HighlightReferenceModal({
  book,
  mainPage,
  mainViewMode,
  layoutMode,
  effectiveFontId,
  effectiveThemeId,
  initialHighlight,
  highlights,
  createHighlight,
  updateHighlight,
  deleteHighlight,
  onClose,
}: {
  book: Book;
  mainPage: number;
  mainViewMode: ViewMode;
  layoutMode: string;
  effectiveFontId: string;
  effectiveThemeId: string;
  initialHighlight: Highlight;
  highlights: Highlight[];
  createHighlight: (info: SelectionInfo, lang: HighlightLang, color: string, note?: string) => void;
  updateHighlight: (id: string, updates: Partial<Highlight>) => void;
  deleteHighlight: (id: string) => void;
  onClose: () => void;
}) {
  const toast = useToast();
  const modalRootRef = useRef<HTMLDivElement>(null);
  const enIframeRef = useRef<HTMLIFrameElement | null>(null);
  const viIframeRef = useRef<HTMLIFrameElement | null>(null);
  const enWrapperRef = useRef<HTMLDivElement | null>(null);
  const viWrapperRef = useRef<HTMLDivElement | null>(null);
  const observersRef = useRef<{ en?: ResizeObserver; vi?: ResizeObserver }>({});
  const authRetriesRef = useRef<Set<string>>(new Set());
  const pulsedInitialRef = useRef(false);

  const [previewPage, setPreviewPage] = useState(() =>
    clampReaderPage(initialHighlight.page, book.pageCount),
  );
  const [previewViewMode, setPreviewViewMode] = useState<ViewMode>(() =>
    resolveInitialReferenceViewMode(mainViewMode, initialHighlight.lang),
  );
  const [zoomMode, setZoomMode] = useState<ZoomMode>('fit-width');
  const [manualZoom, setManualZoom] = useState(1);
  const [displayedZoom, setDisplayedZoom] = useState(1);

  const zoomModeRef = useRef(zoomMode);
  const manualZoomRef = useRef(manualZoom);
  const currentZoomRef = useRef(manualZoom);
  zoomModeRef.current = zoomMode;
  manualZoomRef.current = manualZoom;

  const liveHighlight = useMemo(
    () => highlights.find((h) => h.id === initialHighlight.id) ?? null,
    [highlights, initialHighlight.id],
  );
  const displayHighlight = liveHighlight ?? initialHighlight;

  const scaleModalIframes = useCallback(() => {
    const root = modalRootRef.current;
    if (!root) return;
    const scale = scaleIframeWrappers(root, {
      zoomMode: zoomModeRef.current,
      manualZoom: manualZoomRef.current,
      wrapperSelector: '.ref-iframe-wrapper',
      iframeSelector: '.ref-reader-iframe',
      stageSelector: '.ref-iframe-stage',
    });
    if (scale !== null) {
      currentZoomRef.current = scale;
      setDisplayedZoom(scale);
    }
  }, []);

  const stepPreviewPage = useCallback(
    (delta: number) => {
      setPreviewPage((prev) => clampReaderPage(prev + delta, book.pageCount));
    },
    [book.pageCount],
  );

  const modalContextRef = useRef<HighlightContext | null>(null);
  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      const target = (e.target as HTMLElement | null) ?? (document.activeElement as HTMLElement | null);
      if (
        target &&
        (target.tagName === 'INPUT' ||
          target.tagName === 'TEXTAREA' ||
          target.tagName === 'SELECT' ||
          target.isContentEditable)
      ) {
        return;
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        onClose();
      } else if (e.key === 'ArrowLeft' || e.key === 'PageUp') {
        e.preventDefault();
        stepPreviewPage(-1);
      } else if (e.key === 'ArrowRight' || e.key === 'PageDown') {
        e.preventDefault();
        stepPreviewPage(1);
      }
    },
    [onClose, stepPreviewPage],
  );

  modalContextRef.current = {
    slug: book.slug,
    page: previewPage,
    createHighlight,
    updateHighlight,
    deleteHighlight,
    onLookup: handleReaderVocaLookup,
    onKeyDown: handleKeyDown,
  };

  useEffect(() => {
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [handleKeyDown]);

  useEffect(() => {
    const observers = observersRef.current;
    return () => {
      observers.en?.disconnect();
      observers.vi?.disconnect();
    };
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(scaleModalIframes, 40);
    return () => window.clearTimeout(timer);
  }, [previewPage, previewViewMode, zoomMode, manualZoom, layoutMode, scaleModalIframes]);

  useEffect(() => {
    window.addEventListener('resize', scaleModalIframes);
    return () => window.removeEventListener('resize', scaleModalIframes);
  }, [scaleModalIframes]);

  const pulseTargetHighlight = useCallback(() => {
    const isEn = initialHighlight.lang === 'en';
    const iframeEl = isEn ? enIframeRef.current : viIframeRef.current;
    const wrapperEl = isEn ? enWrapperRef.current : viWrapperRef.current;
    if (!iframeEl) return;
    scrollAndPulseHighlightInWrapper(iframeEl, wrapperEl, initialHighlight.id);
  }, [initialHighlight.id, initialHighlight.lang]);

  // Isolated EN/VI scroll sync for the reference modal panes
  useEffect(() => {
    const enW = enWrapperRef.current;
    const viW = viWrapperRef.current;
    if (!enW || !viW) return;
    let lockEn = false;
    let lockVi = false;
    const onEn = () => {
      if (lockEn) return;
      lockVi = true;
      viW.scrollTop = enW.scrollTop;
      viW.scrollLeft = enW.scrollLeft;
      window.setTimeout(() => (lockVi = false), 20);
    };
    const onVi = () => {
      if (lockVi) return;
      lockEn = true;
      enW.scrollTop = viW.scrollTop;
      enW.scrollLeft = viW.scrollLeft;
      window.setTimeout(() => (lockEn = false), 20);
    };
    enW.addEventListener('scroll', onEn);
    viW.addEventListener('scroll', onVi);
    return () => {
      enW.removeEventListener('scroll', onEn);
      viW.removeEventListener('scroll', onVi);
    };
  }, [previewViewMode, previewPage]);

  const handleModalIframeLoad = useCallback(
    (lang: HighlightLang, e: React.SyntheticEvent<HTMLIFrameElement>) => {
      const iframeEl = e.currentTarget;
      scaleModalIframes();

      try {
        const doc = iframeEl.contentDocument;
        if (!doc) return;
        const bodyText = doc.body?.textContent || '';
        const isAuthError = IFRAME_AUTH_ERROR_MARKERS.some((m) => bodyText.includes(m));
        const retryKey = `ref:${book.slug}:${previewPage}:${lang}`;

        if (isAuthError) {
          if (!authRetriesRef.current.has(retryKey)) {
            authRetriesRef.current.add(retryKey);
            ensureFreshAccessToken(true)
              .then(() => iframeEl.contentWindow?.location.reload())
              .catch((err) => {
                if (!(err instanceof AuthRefreshError && err.terminal)) {
                  toast.show('Không tải được trang tham chiếu.', 'danger');
                }
              });
          }
          return;
        }
        authRetriesRef.current.delete(retryKey);

        const paneKey: 'en' | 'vi' = lang === 'vi' ? 'vi' : 'en';
        const prep = prepareBookIframeDocument(iframeEl, {
          slug: book.slug,
          lang: paneKey,
          page: previewPage,
          fontId: effectiveFontId,
          themeId: effectiveThemeId,
          onScale: scaleModalIframes,
          previousObserver: observersRef.current[paneKey],
          onBindHighlights: (win, boundDoc) =>
            registerIframeHighlightListeners(win, boundDoc, paneKey, {
              iframeSelector: REF_IFRAME_SELECTOR,
              getContext: () => modalContextRef.current,
            }),
        });
        if (prep?.resizeObserver) observersRef.current[paneKey] = prep.resizeObserver;

        if (!pulsedInitialRef.current && previewPage === initialHighlight.page && lang === initialHighlight.lang) {
          pulsedInitialRef.current = true;
          window.setTimeout(() => {
            scaleModalIframes();
            const wrapperEl = lang === 'en' ? enWrapperRef.current : viWrapperRef.current;
            scrollAndPulseHighlightInWrapper(iframeEl, wrapperEl, initialHighlight.id);
          }, 120);
        }
      } catch (err) {
        console.warn('[HighlightReferenceModal] failed preparing iframe:', err);
      }
    },
    [
      book.slug,
      effectiveFontId,
      effectiveThemeId,
      initialHighlight.id,
      initialHighlight.lang,
      initialHighlight.page,
      previewPage,
      scaleModalIframes,
      toast,
    ],
  );

  const showEn = previewViewMode === 'en' || previewViewMode === 'split';
  const showVi = previewViewMode === 'vi' || previewViewMode === 'split';
  const enPageUrl = `/books/${encodeURIComponent(book.slug)}/output/en/page_${padPage(previewPage)}.html`;
  const viPageUrl = `/books/${encodeURIComponent(book.slug)}/output/vi/page_${padPage(previewPage)}.html`;

  const handleAdjustZoom = (direction: number) => {
    const next = clampReaderZoom(
      Math.round((currentZoomRef.current + direction * READER_ZOOM_STEP) * 100) / 100,
    );
    zoomModeRef.current = 'custom';
    manualZoomRef.current = next;
    currentZoomRef.current = next;
    setZoomMode('custom');
    setManualZoom(next);
  };

  const handleSetPreviewMode = (mode: ViewMode) => {
    clearAllHighlights(REF_IFRAME_SELECTOR);
    if (enIframeRef.current?.contentDocument) removeReaderHighlightUI(enIframeRef.current.contentDocument);
    if (viIframeRef.current?.contentDocument) removeReaderHighlightUI(viIframeRef.current.contentDocument);
    setPreviewViewMode(mode);
  };

  const isOnTargetPage = previewPage === initialHighlight.page;

  return (
    <div
      className="ref-reader-backdrop"
      onMouseDown={onClose}
      role="dialog"
      aria-modal="true"
      aria-label="Cửa sổ xem tham chiếu ghi chú"
    >
      <div
        ref={modalRootRef}
        className="ref-reader-modal"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="ref-reader-header">
          <div className="ref-reader-header__left">
            <span className="ref-reader-title">
              <span className="highlight-card__dot" style={{ backgroundColor: displayHighlight.color }} />
              <span>Xem ghi chú</span>
            </span>
            <span
              className="ref-keep-pill"
              title="Trang đọc chính và tiến độ đọc của bạn vẫn được giữ nguyên"
            >
              Trang đọc chính: {mainPage}
            </span>
          </div>

          <div className="ref-reader-header__center">
            <div className="reader-nav">
              <button
                type="button"
                className="nav-btn"
                disabled={previewPage <= 1}
                onClick={() => stepPreviewPage(-1)}
                aria-label="Trang trước"
              >
                ‹
              </button>
              <span className="page-indicator" style={{ padding: '0 6px', fontSize: 12, fontWeight: 700, color: '#f8fafc' }}>
                Trang {previewPage} / {book.pageCount}
              </span>
              <button
                type="button"
                className="nav-btn"
                disabled={previewPage >= book.pageCount}
                onClick={() => stepPreviewPage(1)}
                aria-label="Trang sau"
              >
                ›
              </button>
            </div>

            <button
              type="button"
              className="ref-jump-highlight-btn"
              onClick={() => {
                if (!isOnTargetPage) {
                  pulsedInitialRef.current = false;
                  setPreviewPage(clampReaderPage(initialHighlight.page, book.pageCount));
                } else {
                  if (previewViewMode !== 'split' && previewViewMode !== initialHighlight.lang) {
                    setPreviewViewMode(initialHighlight.lang === 'vi' ? 'vi' : 'en');
                  }
                  pulseTargetHighlight();
                }
              }}
            >
              {isOnTargetPage ? 'Cuộn tới highlight' : `Về trang ${initialHighlight.page}`}
            </button>
          </div>

          <div className="ref-reader-header__right">
            <div className="reader-zoom-toolbar">
              <button type="button" className="zoom-step-btn" onClick={() => handleAdjustZoom(-1)} aria-label="Thu nhỏ">
                −
              </button>
              <span className="zoom-level">{formatReaderZoom(displayedZoom)}</span>
              <button type="button" className="zoom-step-btn" onClick={() => handleAdjustZoom(1)} aria-label="Phóng to">
                +
              </button>
              <button
                type="button"
                className={`zoom-fit-btn ${zoomMode === 'fit-width' ? 'active' : ''}`}
                onClick={() => setZoomMode('fit-width')}
                title="Vừa chiều rộng"
              >
                W
              </button>
              <button
                type="button"
                className={`zoom-fit-btn ${zoomMode === 'fit-page' ? 'active' : ''}`}
                onClick={() => setZoomMode('fit-page')}
                title="Vừa trang"
              >
                P
              </button>
            </div>

            <div className="view-modes">
              {(['en', 'vi', 'split'] as const).map((m) => (
                <button
                  key={m}
                  type="button"
                  className={`mode-btn ${previewViewMode === m ? 'active' : ''}`}
                  onClick={() => handleSetPreviewMode(m)}
                >
                  {m === 'split' ? 'Song Ngữ' : m.toUpperCase()}
                </button>
              ))}
            </div>

            <button type="button" className="ref-close-btn" onClick={onClose}>
              Đóng
            </button>
          </div>
        </div>

        {isOnTargetPage && (
          <div className="ref-context-banner">
            <span className="ref-context-banner__bar" style={{ backgroundColor: displayHighlight.color }} />
            <div className="ref-context-banner__body">
              <div className="ref-context-banner__quote">“{displayHighlight.text}”</div>
              {displayHighlight.note?.trim() && (
                <div className="ref-context-banner__note">Ghi chú: {displayHighlight.note.trim()}</div>
              )}
            </div>
            {liveHighlight === null && <span className="ref-deleted-pill">Đã xoá</span>}
          </div>
        )}

        <div className={`ref-reader-panes layout-${layoutMode}`}>
          {showEn && (
            <div className="ref-reader-pane">
              <span className="pane-label">EN</span>
              <div ref={enWrapperRef} className="ref-iframe-wrapper">
                <div className="ref-iframe-stage">
                  <iframe
                    ref={enIframeRef}
                    className="ref-reader-iframe ref-en-pane-iframe"
                    data-reader-page={previewPage}
                    src={enPageUrl}
                    onLoad={(e) => handleModalIframeLoad('en', e)}
                    scrolling="no"
                    sandbox="allow-same-origin"
                    title="Reference English page"
                  />
                </div>
              </div>
            </div>
          )}

          {showVi && (
            <div className="ref-reader-pane">
              <span className="pane-label">VI</span>
              <div ref={viWrapperRef} className="ref-iframe-wrapper">
                <div className="ref-iframe-stage">
                  <iframe
                    ref={viIframeRef}
                    className="ref-reader-iframe ref-vi-pane-iframe"
                    data-reader-page={previewPage}
                    src={viPageUrl}
                    onLoad={(e) => handleModalIframeLoad('vi', e)}
                    scrolling="no"
                    sandbox="allow-same-origin"
                    title="Reference Vietnamese page"
                  />
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

