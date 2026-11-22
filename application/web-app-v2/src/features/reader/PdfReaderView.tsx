import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import * as pdfjsLib from 'pdfjs-dist';
import type { PDFDocumentProxy } from 'pdfjs-dist';
import pdfWorkerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url';
import { ProfileMenu } from '@/components/ProfileMenu';
import { ensureFreshAccessToken, getAccessToken } from '@/lib/api-client';
import { readJSON, readString, writeJSON, writeString } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import { removeVocaLookupPanel, syncVocaCards } from '@/lib/voca';
import { ChatSidebar } from '@/features/chat/ChatSidebar';
import { SettingsModal } from '@/features/settings/SettingsModal';
import { useAuthStore } from '@/features/auth/authStore';
import { useUpdateBookState } from '@/features/library/useBooks';
import type { Book, Highlight } from '@/types/api';
import { HighlightsSidebar } from './HighlightsSidebar';
import {
  DocumentSelectionPopover,
  ensureHostVocaStyles,
  type SelectionPopoverState,
} from './DocumentSelectionPopover';
import {
  normalizeClientRects,
  parseHighlightAnchor,
  serializeHighlightAnchor,
  type NormalizedRect,
} from './documentAnchors';
import { registerReaderPageContextProvider } from './iframe/pageContext';
import { getLocalProgress, saveLocalProgress } from './localProgress';
import { resolveProgressOnOpen } from './progressSync';
import { clampReaderZoom, formatReaderZoom, READER_ZOOM_STEP, type ZoomMode } from './readerConstants';
import { useHighlights } from './useHighlights';
import { useSaveProgress, useServerProgress } from './useReaderProgress';
import './reader.css';
import './documentReader.css';

pdfjsLib.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;

type PdfLayoutMode = 'single' | 'spread';
type PdfPaperFilter = 'original' | 'warm' | 'dark';

interface PdfOutlineItem {
  title: string;
  page: number;
  level: number;
}

interface PendingPdfSelection {
  page: number;
  text: string;
  rects: NormalizedRect[];
  anchorRect: DOMRect;
}

export function PdfReaderView({
  book,
  initialPageParam,
}: {
  book: Book;
  initialPageParam?: string;
}) {
  const navigate = useNavigate();
  const user = useAuthStore((s) => s.user);
  const logout = useAuthStore((s) => s.logout);
  const updateBookState = useUpdateBookState();

  const local = useMemo(() => getLocalProgress(book.slug), [book.slug]);
  const hadExplicitPageRef = useRef(initialPageParam != null);

  const [pdfDoc, setPdfDoc] = useState<PDFDocumentProxy | null>(null);
  const [totalPages, setTotalPages] = useState<number>(() => Math.max(1, book.pageCount || 1));
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [page, setPage] = useState<number>(() => {
    const fromUrl = initialPageParam ? parseInt(initialPageParam, 10) : NaN;
    const initial = !isNaN(fromUrl) ? fromUrl : (local?.page ?? 1);
    return Math.max(1, Math.min(book.pageCount || 1, initial));
  });
  const [draftPage, setDraftPage] = useState(() => String(page));

  const [layoutMode, setLayoutMode] = useState<PdfLayoutMode>('single');
  const [paperFilter, setPaperFilter] = useState<PdfPaperFilter>('original');
  const [zoomMode, setZoomMode] = useState<ZoomMode>(
    () => (readString(STORAGE_KEYS.zoomMode) as ZoomMode) || 'fit-page',
  );
  const [manualZoom, setManualZoom] = useState<number>(
    () => parseFloat(readString(STORAGE_KEYS.zoomScale) || '') || 1,
  );
  const [displayedZoom, setDisplayedZoom] = useState(1);

  const [drawerOpen, setDrawerOpen] = useState(false);
  const [drawerTab, setDrawerTab] = useState<'toc' | 'thumbs'>('toc');
  const [outline, setOutline] = useState<PdfOutlineItem[]>([]);

  const [highlightsOpen, setHighlightsOpen] = useState(false);
  const [pulsingHighlightId, setPulsingHighlightId] = useState<string | null>(null);
  const [popover, setPopover] = useState<SelectionPopoverState | null>(null);
  const pendingSelectionRef = useRef<PendingPdfSelection | null>(null);

  const [chatOpen, setChatOpen] = useState<boolean>(() => readJSON(STORAGE_KEYS.chatOpen, false));
  const [chatWidth, setChatWidth] = useState<number>(
    () => parseInt(readString(STORAGE_KEYS.chatWidth) || '', 10) || 400,
  );
  const [settingsOpen, setSettingsOpen] = useState(false);

  const stageRef = useRef<HTMLDivElement>(null);
  const pageTextCacheRef = useRef<Map<number, string>>(new Map());
  const userNavigatedRef = useRef(false);
  const appliedServerRef = useRef(false);

  const saveProgress = useSaveProgress(book.slug);
  const { data: serverProgress, isFetching: progressFetching } = useServerProgress(book.slug);
  const { highlights, createDocumentHighlight, updateHighlight, deleteHighlight } = useHighlights(
    book.slug,
    page,
  );

  useEffect(() => {
    ensureHostVocaStyles();
    void syncVocaCards().catch(() => {});
  }, []);

  useEffect(() => {
    setDraftPage(String(page));
  }, [page]);

  // Load PDF document via authenticated endpoint with Range Request support
  useEffect(() => {
    let cancelled = false;
    let loadingTask: pdfjsLib.PDFDocumentLoadingTask | null = null;
    let loadedDoc: PDFDocumentProxy | null = null;

    setLoading(true);
    setLoadError(null);
    pageTextCacheRef.current.clear();

    void (async () => {
      try {
        try {
          await ensureFreshAccessToken();
        } catch {
          /* continue with existing cookie/token */
        }
        const token = getAccessToken();
        const url = `/books/${encodeURIComponent(book.slug)}/source`;
        loadingTask = pdfjsLib.getDocument({
          url,
          withCredentials: true,
          httpHeaders: token ? { Authorization: `Bearer ${token}` } : undefined,
          rangeChunkSize: 65536,
        });
        const doc = await loadingTask.promise;
        if (cancelled) {
          void doc.destroy();
          return;
        }
        loadedDoc = doc;
        setPdfDoc(doc);
        setTotalPages(doc.numPages);
        setPage((prev) => Math.max(1, Math.min(doc.numPages, prev)));
        setLoading(false);

        // Parse PDF Outline / Table of Contents in the background
        try {
          const rawOutline = await doc.getOutline();
          if (rawOutline && !cancelled) {
            const flat: PdfOutlineItem[] = [];
            const walk = async (items: typeof rawOutline, level: number) => {
              for (const item of items) {
                if (flat.length >= 600) return;
                let destPage = 1;
                try {
                  let dest = item.dest;
                  if (typeof dest === 'string') {
                    dest = await doc.getDestination(dest);
                  }
                  if (Array.isArray(dest) && dest[0]) {
                    const idx = await doc.getPageIndex(dest[0] as Parameters<typeof doc.getPageIndex>[0]);
                    destPage = idx + 1;
                  }
                } catch {
                  destPage = 1;
                }
                flat.push({ title: item.title || 'Untitled', page: destPage, level });
                if (item.items?.length) {
                  await walk(item.items, level + 1);
                }
              }
            };
            await walk(rawOutline, 0);
            if (!cancelled) setOutline(flat);
          }
        } catch {
          /* outline optional */
        }
      } catch (err) {
        if (!cancelled) {
          setLoadError(err instanceof Error ? err.message : 'Không thể mở tệp PDF.');
          setLoading(false);
        }
      }
    })();

    return () => {
      cancelled = true;
      void loadingTask?.destroy();
      void loadedDoc?.destroy();
    };
  }, [book.slug]);

  // Visible pages (1 in single mode, up to 2 in spread mode)
  const visiblePages = useMemo(() => {
    if (layoutMode === 'spread' && page < totalPages) {
      return [page, page + 1];
    }
    return [page];
  }, [layoutMode, page, totalPages]);

  // Pre-extract text for visible pages so AI Companion Chat always has exact page context
  useEffect(() => {
    if (!pdfDoc) return;
    let cancelled = false;
    for (const pNum of visiblePages) {
      if (pageTextCacheRef.current.has(pNum)) continue;
      void pdfDoc
        .getPage(pNum)
        .then((p) => p.getTextContent())
        .then((tc) => {
          if (cancelled) return;
          const text = tc.items
            .map((item) => ('str' in item ? item.str : ''))
            .join(' ')
            .replace(/\s+/g, ' ')
            .trim();
          pageTextCacheRef.current.set(pNum, text);
        })
        .catch(() => {});
    }
    return () => {
      cancelled = true;
    };
  }, [pdfDoc, visiblePages]);

  // Register AI Companion page context provider
  useEffect(() => {
    registerReaderPageContextProvider({
      getPageText: (p) => {
        const parts: string[] = [];
        const targets = layoutMode === 'spread' && p < totalPages ? [p, p + 1] : [p];
        for (const num of targets) {
          const txt = pageTextCacheRef.current.get(num);
          if (txt) parts.push(`=== PDF PAGE ${num} ===\n${txt}`);
        }
        return parts.join('\n\n');
      },
      getSelectedText: () => {
        const sel = window.getSelection()?.toString().trim();
        if (sel) return `[Selected PDF text]:\n${sel}`;
        if (pendingSelectionRef.current?.text) {
          return `[Selected PDF text]:\n${pendingSelectionRef.current.text}`;
        }
        return '';
      },
    });
    return () => registerReaderPageContextProvider(null);
  }, [layoutMode, totalPages]);

  const goToPage = useCallback(
    (target: number) => {
      const clamped = Math.max(1, Math.min(totalPages, Math.trunc(target) || 1));
      if (clamped === page) return;
      userNavigatedRef.current = true;
      setPopover(null);
      removeVocaLookupPanel(document);
      setPage(clamped);
      stageRef.current?.scrollTo({ top: 0, left: 0 });
    },
    [page, totalPages],
  );

  const stepPage = useCallback(
    (delta: number) => {
      const step = layoutMode === 'spread' ? delta * 2 : delta;
      goToPage(page + step);
    },
    [layoutMode, page, goToPage],
  );

  // URL sync
  useEffect(() => {
    const target = `/read/${encodeURIComponent(book.slug)}/page/${page}`;
    if (window.location.pathname !== target) navigate(target, { replace: true });
  }, [book.slug, page, navigate]);

  // Progress save on user page navigation
  useEffect(() => {
    if (!userNavigatedRef.current) return;
    const progression = totalPages > 0 ? Math.min(1, page / totalPages) : 0;
    saveProgress(page, 'en', undefined, { progression });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page, totalPages]);

  // Progress reconciliation on open
  useEffect(() => {
    if (appliedServerRef.current || !serverProgress || progressFetching) return;
    appliedServerRef.current = true;
    if (hadExplicitPageRef.current || userNavigatedRef.current) return;

    const resolution = resolveProgressOnOpen(local, serverProgress);
    if (resolution.action === 'adopt') {
      const target = Math.max(1, Math.min(totalPages, resolution.progress.page));
      setPage(target);
      saveLocalProgress(book.slug, {
        page: target,
        viewMode: 'en',
        progression: resolution.progress.progression ?? target / Math.max(1, totalPages),
        lastRead: resolution.lastReadMs,
      });
    } else if (resolution.action === 'pushLocal') {
      saveProgress(resolution.progress.page, 'en', resolution.lastReadMs, {
        progression: resolution.progress.progression,
      });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverProgress, progressFetching, totalPages]);

  // Keyboard shortcuts
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === 'INPUT' ||
          target.tagName === 'TEXTAREA' ||
          target.tagName === 'SELECT' ||
          target.isContentEditable)
      ) {
        return;
      }
      if (e.ctrlKey || e.metaKey) {
        if (e.key === '+' || e.key === '=') {
          e.preventDefault();
          const next = clampReaderZoom(Math.round((displayedZoom + READER_ZOOM_STEP) * 100) / 100);
          setZoomMode('custom');
          setManualZoom(next);
          writeString(STORAGE_KEYS.zoomMode, 'custom');
          writeString(STORAGE_KEYS.zoomScale, String(next));
          return;
        }
        if (e.key === '-') {
          e.preventDefault();
          const next = clampReaderZoom(Math.round((displayedZoom - READER_ZOOM_STEP) * 100) / 100);
          setZoomMode('custom');
          setManualZoom(next);
          writeString(STORAGE_KEYS.zoomMode, 'custom');
          writeString(STORAGE_KEYS.zoomScale, String(next));
          return;
        }
        if (e.key === '0') {
          e.preventDefault();
          setZoomMode('fit-page');
          writeString(STORAGE_KEYS.zoomMode, 'fit-page');
          return;
        }
        return;
      }
      const k = e.key.toLowerCase();
      if (e.key === 'ArrowLeft' || e.key === 'PageUp' || k === 'k') {
        e.preventDefault();
        stepPage(-1);
      } else if (e.key === 'ArrowRight' || e.key === 'PageDown' || k === 'j') {
        e.preventDefault();
        stepPage(1);
      } else if (k === 'f') {
        e.preventDefault();
        const nextMode: ZoomMode = zoomMode === 'fit-page' ? 'fit-width' : 'fit-page';
        setZoomMode(nextMode);
        writeString(STORAGE_KEYS.zoomMode, nextMode);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [displayedZoom, stepPage, zoomMode]);

  const handlePageTextSelection = useCallback(
    (pageNum: number, pageEl: HTMLElement) => {
      const sel = window.getSelection();
      const text = sel?.toString().trim() || '';
      if (!sel || sel.isCollapsed || text.length < 1) return;
      const range = sel.getRangeAt(0);
      if (!pageEl.contains(range.commonAncestorContainer)) return;

      const pageBox = pageEl.getBoundingClientRect();
      const clientRects = Array.from(range.getClientRects());
      const normalized = normalizeClientRects(clientRects, pageBox);
      if (normalized.length === 0) return;

      const anchorRect = range.getBoundingClientRect();
      pendingSelectionRef.current = { page: pageNum, text, rects: normalized, anchorRect };
      setPopover({ mode: 'create', text, rect: anchorRect });
    },
    [],
  );

  const handleClickExistingHighlight = useCallback((hl: Highlight, anchorRect: DOMRect) => {
    pendingSelectionRef.current = null;
    setPopover({
      mode: 'edit',
      text: hl.text,
      rect: anchorRect,
      highlightId: hl.id,
      color: hl.color,
      note: hl.note,
    });
  }, []);

  const handleSelectHighlightColor = useCallback(
    (color: string) => {
      if (!popover) return;
      if (popover.mode === 'edit' && popover.highlightId) {
        updateHighlight(popover.highlightId, { color });
        setPopover(null);
        return;
      }
      const pending = pendingSelectionRef.current;
      if (!pending) return;
      const anchorJson = serializeHighlightAnchor({ kind: 'pdf', rects: pending.rects });
      createDocumentHighlight({
        page: pending.page,
        lang: 'pdf',
        color,
        text: pending.text,
        anchorJson,
      });
      window.getSelection()?.removeAllRanges();
      pendingSelectionRef.current = null;
      setPopover(null);
    },
    [popover, createDocumentHighlight, updateHighlight],
  );

  const handleSaveHighlightNote = useCallback(
    (color: string, note: string) => {
      if (!popover) return;
      if (popover.mode === 'edit' && popover.highlightId) {
        updateHighlight(popover.highlightId, { color, note });
        setPopover(null);
        return;
      }
      const pending = pendingSelectionRef.current;
      if (!pending) return;
      const anchorJson = serializeHighlightAnchor({ kind: 'pdf', rects: pending.rects });
      createDocumentHighlight({
        page: pending.page,
        lang: 'pdf',
        color,
        text: pending.text,
        anchorJson,
        note,
      });
      window.getSelection()?.removeAllRanges();
      pendingSelectionRef.current = null;
      setPopover(null);
    },
    [popover, createDocumentHighlight, updateHighlight],
  );

  const handleOpenHighlightFromSidebar = useCallback(
    (hl: Highlight) => {
      if (hl.page !== page) {
        goToPage(hl.page);
      }
      setPulsingHighlightId(hl.id);
      window.setTimeout(() => setPulsingHighlightId(null), 1600);
    },
    [page, goToPage],
  );

  const commitDraftPage = () => {
    const parsed = parseInt(draftPage, 10);
    if (isNaN(parsed)) {
      setDraftPage(String(page));
      return;
    }
    goToPage(parsed);
  };

  const adjustZoom = (dir: number) => {
    const next = clampReaderZoom(Math.round((displayedZoom + dir * READER_ZOOM_STEP) * 100) / 100);
    setZoomMode('custom');
    setManualZoom(next);
    writeString(STORAGE_KEYS.zoomMode, 'custom');
    writeString(STORAGE_KEYS.zoomScale, String(next));
  };

  const toggleChat = () => {
    setChatOpen((v) => {
      const next = !v;
      writeJSON(STORAGE_KEYS.chatOpen, next);
      if (next) setHighlightsOpen(false);
      return next;
    });
  };

  return (
    <div
      className="reader-view"
      onMouseDown={() => {
        setPopover(null);
        removeVocaLookupPanel(document);
      }}
    >
      <div className="reader-topbar">
        <div className="reader-topbar__left">
          <button className="btn-action" onClick={() => navigate('/')} title="Về thư viện">
            🏠 Library
          </button>
          <button
            className={`btn-icon ${drawerOpen ? 'active' : ''}`}
            onClick={() => setDrawerOpen((v) => !v)}
            title="Mục lục & Trang thu nhỏ"
            aria-label="Mục lục"
          >
            ☰
          </button>
          <span className="reader-topbar__title" title={book.title}>
            {book.title}
          </span>
        </div>

        <div className="reader-topbar__center">
          <div className="reader-nav">
            <button
              className="nav-btn page-nav__arrow"
              disabled={page <= 1}
              onClick={() => stepPage(-1)}
              aria-label="Trang trước"
            >
              ‹
            </button>
            <span className="page-indicator">
              <input
                className="page-input"
                type="number"
                min={1}
                max={totalPages}
                value={draftPage}
                onChange={(e) => setDraftPage(e.target.value)}
                onBlur={commitDraftPage}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault();
                    commitDraftPage();
                    e.currentTarget.blur();
                  }
                }}
                aria-label="Số trang hiện tại"
              />
              <span className="page-total">/ {totalPages}</span>
            </span>
            <button
              className="nav-btn page-nav__arrow"
              disabled={page >= totalPages}
              onClick={() => stepPage(1)}
              aria-label="Trang sau"
            >
              ›
            </button>
          </div>

          <div className="reader-zoom-toolbar" role="group" aria-label="Thu phóng PDF">
            <button className="zoom-step-btn" onClick={() => adjustZoom(-1)} aria-label="Thu nhỏ">
              −
            </button>
            <span className="zoom-level">{formatReaderZoom(displayedZoom)}</span>
            <button className="zoom-step-btn" onClick={() => adjustZoom(1)} aria-label="Phóng to">
              +
            </button>
            <button
              className={`zoom-fit-btn ${zoomMode === 'fit-page' ? 'active' : ''}`}
              onClick={() => {
                setZoomMode('fit-page');
                writeString(STORAGE_KEYS.zoomMode, 'fit-page');
              }}
              title="Vừa trang"
            >
              Fit
            </button>
            <button
              className={`zoom-fit-btn ${zoomMode === 'fit-width' ? 'active' : ''}`}
              onClick={() => {
                setZoomMode('fit-width');
                writeString(STORAGE_KEYS.zoomMode, 'fit-width');
              }}
              title="Vừa chiều rộng"
            >
              ↔
            </button>
          </div>
        </div>

        <div className="reader-topbar__right">
          {page >= totalPages && (
            <button
              className={`reader-complete-btn ${book.isFinished ? 'is-complete' : ''}`}
              onClick={() =>
                updateBookState.mutate({
                  slug: book.slug,
                  patch: { isFinished: !book.isFinished },
                })
              }
              disabled={updateBookState.isPending}
            >
              <span>{book.isFinished ? '✓ Đã đọc' : 'Hoàn thành'}</span>
            </button>
          )}

          <div className="doc-mode-group" title="Bố cục trang PDF">
            <button
              type="button"
              className={`doc-mode-btn ${layoutMode === 'single' ? 'active' : ''}`}
              onClick={() => setLayoutMode('single')}
            >
              1 trang
            </button>
            <button
              type="button"
              className={`doc-mode-btn ${layoutMode === 'spread' ? 'active' : ''}`}
              onClick={() => setLayoutMode('spread')}
            >
              2 trang
            </button>
          </div>

          <div className="doc-mode-group" title="Chế độ màu giấy PDF">
            <button
              type="button"
              className={`doc-mode-btn ${paperFilter === 'original' ? 'active' : ''}`}
              onClick={() => setPaperFilter('original')}
            >
              Gốc
            </button>
            <button
              type="button"
              className={`doc-mode-btn ${paperFilter === 'warm' ? 'active' : ''}`}
              onClick={() => setPaperFilter('warm')}
            >
              Ấm
            </button>
            <button
              type="button"
              className={`doc-mode-btn ${paperFilter === 'dark' ? 'active' : ''}`}
              onClick={() => setPaperFilter('dark')}
            >
              Đêm
            </button>
          </div>

          <button
            className={`btn-icon reader-highlight-badge-btn ${highlightsOpen ? 'active' : ''}`}
            onClick={() => {
              setHighlightsOpen((v) => {
                const next = !v;
                if (next) setChatOpen(false);
                return next;
              });
            }}
            title="Ghi chú & Đánh dấu"
          >
            🖍
            {highlights.length > 0 && (
              <span className="reader-highlight-badge">
                {highlights.length > 99 ? '99+' : highlights.length}
              </span>
            )}
          </button>

          <button
            className={`btn-icon ${chatOpen ? 'active' : ''}`}
            onClick={toggleChat}
            title="Companion Reader Agent"
          >
            💬
          </button>

          <ProfileMenu
            variant="reader"
            username={user?.username ?? ''}
            isAdmin={user?.is_admin ?? false}
            onOpenSettings={() => setSettingsOpen(true)}
            onLogout={logout}
          />
        </div>
      </div>

      <div className={`doc-reader-workspace ${chatOpen ? 'chat-open' : ''}`}>
        <aside className={`doc-nav-drawer ${drawerOpen ? 'is-open' : ''}`}>
          <div className="doc-nav-drawer__header">
            <div className="doc-nav-drawer__tabs">
              <button
                type="button"
                className={`doc-nav-drawer__tab ${drawerTab === 'toc' ? 'is-active' : ''}`}
                onClick={() => setDrawerTab('toc')}
              >
                Mục lục
              </button>
              <button
                type="button"
                className={`doc-nav-drawer__tab ${drawerTab === 'thumbs' ? 'is-active' : ''}`}
                onClick={() => setDrawerTab('thumbs')}
              >
                Trang ({totalPages})
              </button>
            </div>
            <button className="nav-btn" onClick={() => setDrawerOpen(false)} aria-label="Đóng">
              ✕
            </button>
          </div>

          <div className="doc-nav-drawer__body">
            {drawerTab === 'toc' ? (
              outline.length === 0 ? (
                <div className="doc-drawer-empty">
                  Tài liệu PDF này không có mục lục nhúng. Chuyển sang tab <strong>Trang</strong> để
                  duyệt nhanh.
                </div>
              ) : (
                <ul className="doc-toc-list">
                  {outline.map((item, idx) => (
                    <li key={`${item.page}-${idx}`}>
                      <button
                        type="button"
                        className={`doc-toc-item ${item.page === page ? 'is-active' : ''}`}
                        style={{ paddingLeft: `${10 + Math.min(item.level, 4) * 14}px` }}
                        onClick={() => goToPage(item.page)}
                      >
                        <span>{item.title}</span>
                        <span className="doc-toc-item__page">{item.page}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              )
            ) : (
              <div className="pdf-thumbs-grid">
                {pdfDoc &&
                  Array.from({ length: totalPages }, (_, i) => i + 1).map((pNum) => (
                    <PdfThumbnailItem
                      key={pNum}
                      pdfDoc={pdfDoc}
                      pageNum={pNum}
                      active={visiblePages.includes(pNum)}
                      onSelect={() => goToPage(pNum)}
                    />
                  ))}
              </div>
            )}
          </div>
        </aside>

        <div className="doc-reader-main">
          <div
            ref={stageRef}
            className={`pdf-stage-scroll ${layoutMode === 'spread' ? 'is-spread' : ''}`}
            data-pdf-filter={paperFilter}
          >
            {pdfDoc &&
              visiblePages.map((pNum) => (
                <PdfPageCanvas
                  key={`${book.slug}-${pNum}`}
                  pdfDoc={pdfDoc}
                  pageNum={pNum}
                  stageRef={stageRef}
                  spreadCount={visiblePages.length}
                  zoomMode={zoomMode}
                  manualZoom={manualZoom}
                  highlights={highlights.filter((h) => h.page === pNum)}
                  pulsingHighlightId={pulsingHighlightId}
                  onScaleMeasured={pNum === visiblePages[0] ? setDisplayedZoom : undefined}
                  onTextSelected={handlePageTextSelection}
                  onClickHighlight={handleClickExistingHighlight}
                />
              ))}

            {loading && (
              <div className="doc-status-overlay">
                <div className="doc-spinner" />
                <span>Đang mở tài liệu PDF…</span>
              </div>
            )}
            {loadError && (
              <div className="doc-status-overlay">
                <strong>Không thể hiển thị PDF</strong>
                <span>{loadError}</span>
              </div>
            )}
          </div>

          <div className="doc-bottom-bar">
            <span className="doc-bottom-bar__chapter">{book.title}</span>
            <input
              type="range"
              className="doc-bottom-bar__slider"
              min={1}
              max={Math.max(1, totalPages)}
              value={page}
              onChange={(e) => goToPage(parseInt(e.target.value, 10))}
              aria-label="Thanh tua trang PDF"
            />
            <span className="doc-bottom-bar__meta">
              Trang {page} / {totalPages} ({Math.round((page / Math.max(1, totalPages)) * 100)}%)
            </span>
          </div>
        </div>

        <HighlightsSidebar
          open={highlightsOpen}
          currentPage={page}
          highlights={highlights}
          bookFormat="pdf"
          onOpenReference={handleOpenHighlightFromSidebar}
          onDeleteHighlight={deleteHighlight}
          onClose={() => setHighlightsOpen(false)}
        />

        <ChatSidebar
          book={book}
          page={page}
          highlights={highlights}
          open={chatOpen}
          chatWidth={chatWidth}
          onClose={toggleChat}
          onWidthChange={(w) => {
            setChatWidth(w);
            writeString(STORAGE_KEYS.chatWidth, String(w));
          }}
          onResizing={() => {}}
        />
      </div>

      {popover && (
        <DocumentSelectionPopover
          state={popover}
          onSelectColor={handleSelectHighlightColor}
          onSaveNote={handleSaveHighlightNote}
          onDelete={
            popover.mode === 'edit' && popover.highlightId
              ? () => {
                  deleteHighlight(popover.highlightId!);
                  setPopover(null);
                }
              : undefined
          }
          onAskAi={() => {
            setChatOpen(true);
            setHighlightsOpen(false);
          }}
          onClose={() => setPopover(null)}
        />
      )}

      {settingsOpen && <SettingsModal onClose={() => setSettingsOpen(false)} />}
    </div>
  );
}

function PdfPageCanvas({
  pdfDoc,
  pageNum,
  stageRef,
  spreadCount,
  zoomMode,
  manualZoom,
  highlights,
  pulsingHighlightId,
  onScaleMeasured,
  onTextSelected,
  onClickHighlight,
}: {
  pdfDoc: PDFDocumentProxy;
  pageNum: number;
  stageRef: React.RefObject<HTMLDivElement | null>;
  spreadCount: number;
  zoomMode: ZoomMode;
  manualZoom: number;
  highlights: Highlight[];
  pulsingHighlightId: string | null;
  onScaleMeasured?: (scale: number) => void;
  onTextSelected: (pageNum: number, pageEl: HTMLElement) => void;
  onClickHighlight: (hl: Highlight, rect: DOMRect) => void;
}) {
  const shellRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const textLayerRef = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState<{ width: number; height: number }>({ width: 640, height: 900 });
  const [resizeTick, setResizeTick] = useState(0);

  useEffect(() => {
    const el = stageRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    let raf = 0;
    const ro = new ResizeObserver(() => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => setResizeTick((t) => t + 1));
    });
    ro.observe(el);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, [stageRef]);

  useEffect(() => {
    let cancelled = false;
    let renderTask: pdfjsLib.RenderTask | null = null;
    let textLayerInstance: pdfjsLib.TextLayer | null = null;

    void (async () => {
      try {
        const pdfPage = await pdfDoc.getPage(pageNum);
        if (cancelled) return;

        const unscaled = pdfPage.getViewport({ scale: 1 });
        const stageEl = stageRef.current;
        const gapPadding = spreadCount > 1 ? 68 : 48;
        const availW = Math.max(240, ((stageEl?.clientWidth ?? 900) - gapPadding) / spreadCount);
        const availH = Math.max(300, (stageEl?.clientHeight ?? 800) - 48);

        let scale = manualZoom;
        if (zoomMode === 'fit-width') {
          scale = availW / unscaled.width;
        } else if (zoomMode === 'fit-page') {
          scale = Math.min(availW / unscaled.width, availH / unscaled.height);
        }
        scale = clampReaderZoom(scale, 0.35);
        onScaleMeasured?.(scale);

        const viewport = pdfPage.getViewport({ scale });
        setSize({ width: Math.round(viewport.width), height: Math.round(viewport.height) });

        const canvas = canvasRef.current;
        if (!canvas || cancelled) return;
        const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
        canvas.width = Math.floor(viewport.width * dpr);
        canvas.height = Math.floor(viewport.height * dpr);
        canvas.style.width = `${viewport.width}px`;
        canvas.style.height = `${viewport.height}px`;

        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

        renderTask = pdfPage.render({ canvasContext: ctx, viewport, canvas });
        await renderTask.promise;
        if (cancelled) return;

        // Render selectable PDF.js TextLayer
        const textContainer = textLayerRef.current;
        if (textContainer) {
          textContainer.innerHTML = '';
          textContainer.style.setProperty('--scale-factor', String(viewport.scale));
          const textContent = await pdfPage.getTextContent();
          if (cancelled) return;
          textLayerInstance = new pdfjsLib.TextLayer({
            textContentSource: textContent,
            container: textContainer,
            viewport,
          });
          await textLayerInstance.render();
        }
      } catch {
        /* ignore canceled render tasks */
      }
    })();

    return () => {
      cancelled = true;
      renderTask?.cancel();
      textLayerInstance?.cancel();
    };
  }, [pdfDoc, pageNum, spreadCount, zoomMode, manualZoom, resizeTick, stageRef, onScaleMeasured]);

  const parsedHighlights = useMemo(
    () =>
      highlights
        .map((hl) => ({ hl, anchor: parseHighlightAnchor(hl.anchorJson) }))
        .filter((x) => x.anchor?.kind === 'pdf'),
    [highlights],
  );

  return (
    <div
      ref={shellRef}
      className="pdf-page-shell"
      style={{ width: `${size.width}px`, height: `${size.height}px` }}
      onMouseUp={() => {
        if (shellRef.current) onTextSelected(pageNum, shellRef.current);
      }}
    >
      <canvas ref={canvasRef} className="pdf-page-canvas" />
      <div ref={textLayerRef} className="pdf-text-layer" />
      <div className="pdf-highlight-layer">
        {parsedHighlights.map(({ hl, anchor }) => {
          if (anchor?.kind !== 'pdf') return null;
          return anchor.rects.map((rect, idx) => (
            <div
              key={`${hl.id}-${idx}`}
              className={`pdf-highlight-rect ${pulsingHighlightId === hl.id ? 'is-pulsing' : ''}`}
              data-has-note={idx === 0 && hl.note ? 'true' : undefined}
              title={hl.note || hl.text}
              style={{
                left: `${rect.x * 100}%`,
                top: `${rect.y * 100}%`,
                width: `${rect.w * 100}%`,
                height: `${rect.h * 100}%`,
                backgroundColor: hl.color,
              }}
              onMouseDown={(e) => e.stopPropagation()}
              onClick={(e) => {
                e.stopPropagation();
                onClickHighlight(hl, e.currentTarget.getBoundingClientRect());
              }}
            />
          ));
        })}
      </div>
    </div>
  );
}

function PdfThumbnailItem({
  pdfDoc,
  pageNum,
  active,
  onSelect,
}: {
  pdfDoc: PDFDocumentProxy;
  pageNum: number;
  active: boolean;
  onSelect: () => void;
}) {
  const cardRef = useRef<HTMLButtonElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const renderedRef = useRef(false);

  useEffect(() => {
    const el = cardRef.current;
    if (!el || renderedRef.current) return;

    const renderThumb = async () => {
      if (renderedRef.current) return;
      renderedRef.current = true;
      try {
        const p = await pdfDoc.getPage(pageNum);
        const vp1 = p.getViewport({ scale: 1 });
        const scale = Math.min(0.45, 120 / Math.max(vp1.width, 1));
        const vp = p.getViewport({ scale });
        const canvas = canvasRef.current;
        if (!canvas) return;
        canvas.width = Math.floor(vp.width);
        canvas.height = Math.floor(vp.height);
        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        await p.render({ canvasContext: ctx, viewport: vp, canvas }).promise;
      } catch {
        /* ignore */
      }
    };

    if (typeof IntersectionObserver === 'undefined') {
      void renderThumb();
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          observer.disconnect();
          void renderThumb();
        }
      },
      { rootMargin: '120px' },
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, [pdfDoc, pageNum]);

  return (
    <button
      ref={cardRef}
      type="button"
      className={`pdf-thumb-card ${active ? 'is-active' : ''}`}
      onClick={onSelect}
    >
      <canvas ref={canvasRef} className="pdf-thumb-canvas" width={110} height={150} />
      <span className="pdf-thumb-label">{pageNum}</span>
    </button>
  );
}
